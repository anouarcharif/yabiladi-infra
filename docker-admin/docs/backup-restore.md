# Sauvegarde et restauration

Ce qui est archivé, comment la console y a accès, ce que « Success » veut dire,
et comment rendre une base Portainer — avec les commandes telles qu'elles ont été
jouées le 2026-11-12 et leurs sorties réelles.

## Le job, déclaré une seule fois et pas ici

| | |
| --- | --- |
| Nom | `portainer-volume-backup` |
| Description | `Sauvegarde quotidienne des données persistantes de Portainer CE.` |
| Horaire | `40 4 * * *` — 04:40 Europe/Paris, la dernière minute libre de la série de nuit |
| Source | `/backup/portainer`, lecture seule |
| Rétention | `retention-gvs-default`, celle de tous les jobs de fichiers de la console |

La ligne est dans `tools/backup/jobs.json`, à la racine du dépôt, et c'est la
seule déclaration qui existe :

```json
{"name":"portainer-volume-backup","path":"portainer","label":"Sauvegarde quotidienne des données persistantes de Portainer CE.","schedule":"40 4 * * *"}
```

`scripts/backup.sh` ne crée donc aucun job : il ouvre les droits, joue le job sur
demande, et relit la preuve. Le périmètre non plus ne se décide pas ici — c'est
`../compose.yaml` qui monte le volume :

```yaml
- portainer_data:/backup/portainer:ro
```

**Pourquoi le volume se monte au lieu d'archiver par la socket Docker.** La
console tourne en uid 1001 ; le connecteur `docker-volume` de DBackup demande un
`GET /volumes/<nom>` à travers la socket, et mesuré ici il meurt en
`EACCES` (`docs/security.md`, tableau du mandataire : `/volumes` répond 403). Le
montage est le seul chemin qui marche sans donner à la sauvegarde les droits de
l'administration — et sans toucher à la socket de qui que ce soit.

**Nom du job, et écart assumé.** La maison nomme ses jobs de fichiers
`Fichiers - <chose>`. Ici le nom imposé par la mission est `portainer-volume-backup`,
joué tel quel ; c'est le seul écart de nomenclature de cette pile, et il est
volontaire.

## Ce que contient le volume, mesuré

`docker exec` dans le conteneur Portainer, `ls -laR /data`, le 2026-11-12 :

| Fichier | Octets | Rôle |
| --- | --- | --- |
| `portainer.db` | 1 048 576 (569 344 réellement alloués — Bolt écrit creux) | la base : environnements, comptes, équipes, rôles, réglages, identifiants de registres et de webhooks |
| `portainer.key` | 227 | la clé privée RSA de la session |
| `portainer.pub` | 190 | sa publique |
| `certs/cert.pem` | 518 | le certificat auto-signé interne |
| `certs/key.pem` | 227 | sa clé |
| `chisel/private-key.pem` | 227 | la clé du tunnel Agent/Edge |
| `bin/`, `compose/`, `tls/` | 0 | dossiers vides |

Six fichiers, 1 049 965 octets logiques. Rien de tout cela ne se rejoue :
`deploy.sh` reconstruit un conteneur, pas une configuration. C'est exactement pour
ça que le job existe.

## Les droits, c'est le job

Portainer écrit en root : le fichier sort en `0600 root:root`, et l'utilisateur
1001 / groupe 33 de la console ne lirait **rien**. Mesuré le 2026-11-12 : une
archive de 0 fichier est déclarée « Success » par la console. Un vert d'interface
ne prouve donc pas une sauvegarde ici — c'est la ligne la plus importante de ce
fichier.

Deux passes, qui ne couvrent pas la même chose :

**1. Le service se les donne à lui-même, à chaque démarrage.** L'`entrypoint` de
`compose.yaml` enveloppe le binaire :

```sh
umask 027
chgrp -R 33 /data
find /data -type d -exec chmod 2750 {} +
find /data -type f -exec chmod 0640 {} +
exec /portainer "$@"
```

Le `umask 027` et le bit **setgid** sur les dossiers sont le morceau qui compte :
ils font qu'un fichier né *pendant* que Portainer tourne — un stack sauvegardée,
une clé, un certificat — apparaît déjà en `root:33 0640`, archivable à la minute,
là où la passe précédente, jouée au démarrage, laissait filer tout ce qui venait
après elle. Mesuré après coup : le fichier témoin créé dans le conteneur en
cours de service sort `640 root:33`.

Trois capacités rendent le geste possible sous `cap_drop: ALL` — `CHOWN`
(`chgrp`), `FOWNER` (`chmod`), et `FSETID`. La troisième s'est imposée par la
mesure : sans elle, le `chmod 2750` de busybox **échoue sans rien dire** — code
de sortie 0, dossier resté en `750`, le bit setgid absent. Le même `chmod` sous
le jeu de capacités par défaut de Docker, lui, passe. C'est exactement le genre
d'échec muet que cette section existe à décrire, et `validate.sh` le contrôle
désormais par son nom (« CAP_FSETID au catalogue ») en plus de l'état posé.

**2. La passe du script, avant chaque archive.** Un filet, plus le mécanisme :

```bash
bash docker-admin/scripts/backup.sh --grant-only     # deploy.sh l'appelle à l'étape 4
```

Elle est tombée dans son propre piège pendant sa mise au point : elle faisait
`chmod 0750` sur les dossiers, c'est-à-dire qu'**effaçait le bit setgid à chaque
passe** et ramenait précisément la dérive qu'elle croyait corriger. Elle pose
désormais `2750`, comme l'entrypoint.

Le geste se fait **depuis le propre conteneur de Portainer** — `docker exec
--user root` sur `/data` pour la passe du script, le PID 1 du service pour la
sienne — jamais par un `chmod` sur l'hôte : cette stack ne touche que sa donnée.
Deux autres pièges, traités dans le script et détaillés dans `troubleshooting.md`
: un dossier sans bit d'exécution devient invisible pour la console, qui archive
moins sans le dire — d'où le `find -type d` / `find -type f` séparé plutôt qu'un
`chmod -R g+rX`, le `X` de GNU n'existant pas chez busybox.

Contrôlé côté console, donc en 1001:33 et pas en root :

```
· volume lisible par la console : 6 fichier(s) sur 6 en uid 1001, groupe 33
```

Et contrôlé dans l'autre sens, en semant la dérive à la main (`chown 0:0`,
dossiers `0700`, fichiers `0600`) puis en jouant un simple
`docker compose restart portainer` : `2750` sur les dossiers, `0640 root:33` sur
les fichiers, santé `healthy`, `restarts=0`, `HTTP/1.1 200`. Un redémarrage
suffit à résorber un écart — c'est ce que valait cette expérience.

**Pourquoi l'entrypoint et pas une passe planifiée.** Une correction qui se
rejoue toute seule était la demande ; le planificateur, lui, n'avait pas de
chemin jusqu'au volume. Mesuré sur le conteneur Dagu : pas de binaire `docker`
(`command -v docker` → vide), pas de `setfacl` ni de `getfacl` — non plus que
dans `php`, `grafana` ni `dbackup` — et surtout aucun montage de
`yabiladi_portainer_data` dans sa liste de volumes. Le rejoindre aurait voulu
dire monter la socket Docker dans Dagu, c'est-à-dire ouvrir à l'ordonnanceur une
mainmise sur toute la machine pour un `chmod`. L'entrypoint fait le même
travail avec zéro planification, zéro dépendance entre projets et un déclencheur
qui ne rate pas : le démarrage du conteneur, donc aussi chaque redémarrage après
une mise à jour ou un `up -d`. Le seul trou qui reste est un fichier créé *pendant*
que le service tourne avec un umask autre que `027` — et c'est exactement ce que
couvre le bit setgid.

## Chaud la nuit, froid avant une mise à jour

**Chaud** (le comportement par défaut, et celui du job de 04:40) : Portainer ne
s'arrête pas. Sa base Bolt s'écrit par pages mmapées et garde deux méta-pages,
dont une valide si la copie tombe en plein milieu. Le trou de cohérence est réel
mais étroit ; c'est le compromis de toute sauvegarde à chaud d'une base clef-en-
main, et il est assumé pour la nuit.

**Froid** (`--quiesce`) : `docker compose stop portainer`, archive, `start`.
Dix secondes d'interface indisponible, aucun autre conteneur touché, et un `trap`
qui remet Portainer debout même si l'archive échoue. À jouer avant toute montée
de version, et au moins une fois par trimestre pour que la preuve reste fraîche.

Sortie réelle du jeu d'essai du 2026-11-12 :

```
── sauvegarde des données de Portainer ──
  droits du volume…
  · volume lisible par la console : 6 fichier(s) sur 6 en uid 1001, groupe 33
  mode froid : Portainer s'arrête pour la durée de l'archive, rien d'autre
  Portainer arrêté, archivage…
    · maillon de cette exécution : portainer_volume_backup_2026-11-12_21-01-26_inc-004.tar
      (incremental, 1 fichier(s), 1049965 octet(s) logiques)
    · ce que la chaîne sait rendre : 6 fichier(s), 34157 octet(s) logiques au complet (5 maillon(s))
    · sha256 du maillon : 4714bf704447add5… (contrôle native)
  sauvegarde prouvée non vide
  Portainer redémarré
  archive vérifiée.
```

À chaud, le même job archive entre 3 584 et 6 144 octets ; à froid, le maillon
pèse 100 864 octets, parce que l'arrêt fait réécrire la base entière plutôt que
les seules pages sales. Les deux sont complets.

## Une archive, vue de dessous

`/backups/portainer-volume-backup/` — côté serveur, `DBACKUP_DEST_HOST_PATH`
du `.env` racine (`/data/backup/files`), et sur ce poste le même endroit monté
depuis `compose.override.yaml`. La console range chaque suite de maillons dans un
dossier de chaîne, et l'état du 2026-11-12 est celui-là :

```
chain-2026-11-12T20-11-12-341/
  portainer_volume_backup_2026-11-12_21-01-26_inc-004.tar        100864   ← le jeu froid
  portainer_volume_backup_2026-11-12_20-17-43_inc-003.tar          6144
  portainer_volume_backup_2026-11-12_20-17-21_inc-002.tar          3584
  portainer_volume_backup_2026-11-12_20-12-18_inc-001.tar          3584
  portainer_volume_backup_2026-11-12_20-11-12_full-000.tar        11264   ← la base de la chaîne
  (+ .tar.index et .tar.meta.json à côté de chaque .tar)
```

Chaque `.tar` est un TAR **non compressé** (format v2) qui contient trois choses :
un `manifest.json`, un index binaire, et les fichiers eux-mêmes sous
`sources/<uuid-du-source>/<chemin>.gz` — un gzip par fichier. Le `.meta.json` posé
à côté est la preuve lisible ; celui du maillon froid, en entier :

```json
{
  "jobName": "portainer-volume-backup",
  "sourceType": "directory-only",
  "timestamp": "2026-11-12T21:01:26.796Z",
  "originalFileName": "portainer_volume_backup_2026-11-12_21-01-26_inc-004.tar",
  "checksum": "4714bf704447add5b50be03eb86ea606ebdb113667f47a1081c5e7bca0986d7b",
  "archive": { "formatVersion": 2, "indexFile": ".index", "encrypted": false, "compression": "GZIP", "files": 1 },
  "backupType": "incremental",
  "chain": { "id": "a11deeac-5769-4b68-8df5-a2cc6ad4b760", "type": "incremental",
             "base": "portainer_volume_backup_2026-11-12_20-17-43_inc-003.tar", "index": 4 },
  "logicalSize": 1049965,
  "trigger": { "type": "Manual", "actor": "Yabiladi" },
  "verification": { "verifiedAt": "2026-11-12T21:01:26.842Z", "passed": true,
                    "trigger": "post-upload", "method": "native" }
}
```

Deux lectures à faire honnêtement :

- **`encrypted: false`.** Mesuré sur quatre jobs de cette console
  (`portainer-volume-backup`, `Fichiers - traefik-acme`, `Fichiers - traefik-config`,
  `Fichiers - media`) : le chiffrement n'est actif pour aucun. Ce n'est pas un
  réglage de cette pile, et la recommandation est dans `docs/security.md` —
  l'activer d'un coup sur les trois jobs qui portent des clés.
- **`logicalSize` change de sens selon le maillon.** Les quatre premiers marquent
  34 157 (le poids compressé de l'arbre), le maillon froid 1 049 965 (la somme des
  tailles déclarées des six fichiers). C'est mesuré, pas déduit : le champ est
  utile pour comparer deux exécutions d'un même type, pas pour estimer un volume
  à restaurer. Le nombre qui compte ici est `archive.files`.

## Contrôler sans rien lancer

```bash
bash docker-admin/scripts/backup.sh --check
```

```
── dernière archive de « portainer-volume-backup » ──
· chaîne : /backups/portainer-volume-backup/chain-2026-11-12T20-11-12-341 (5 maillon(s))
    - portainer_volume_backup_2026-11-12_21-01-26_inc-004.tar : incremental, 1 fichier(s), 1049965 octet(s) logiques, contrôle passé
    - portainer_volume_backup_2026-11-12_20-17-43_inc-003.tar : incremental, 1 fichier(s), 34157 octet(s) logiques, contrôle passé
    - portainer_volume_backup_2026-11-12_20-17-21_inc-002.tar : incremental, 0 fichier(s), 34157 octet(s) logiques, contrôle passé
    - portainer_volume_backup_2026-11-12_20-12-18_inc-001.tar : incremental, 0 fichier(s), 34157 octet(s) logiques, contrôle passé
    - portainer_volume_backup_2026-11-12_20-11-12_full-000.tar : full, 6 fichier(s), 34157 octet(s) logiques, contrôle passé
  · chaîne sauvegardée et contrôlée : 6 fichier(s), 34157 octet(s) logiques au complet.
```

Un maillon à 0 fichier est normal : c'est un incrémental qui n'a rien vu changer.
Ce qui ne l'est pas, c'est un **full** à 0 fichier — et c'est précisément ce que
produit un volume dont les droits n'ont pas été ouverts.

Ce que cela prouve : chaque maillon est intact et la chaîne se reconstruit à 6
fichiers. Ce que cela ne prouve pas : que la base reconstituée s'ouvre. C'est le
métier du jeu d'essai ci-dessous.

## Restaurer

Règle de la maison, et de la mission : **jamais par-dessus une donnée existante
sans l'avoir archivée avant.** La restauration se joue d'abord à côté.

### 1. Conserver l'état en place

Le plus simple est de hacher ce qui vit, pour pouvoir comparer après coup :

```bash
pc="$(docker ps -q --filter label=com.docker.compose.service=portainer | head -1)"
docker exec "$pc" sh -c 'cd /data && find . -type f | sort | while read -r p; do
    printf "%s %s\n" "$(sha256sum "$p" | cut -c1-16)" "${p#./}"; done'
```

### 2. Reconstituer la chaîne dans un dossier de travail

`/restore` est le dossier de travail de la console (`DBACKUP_RESTORE_HOST_PATH`,
`/data/restore` sur le serveur). La commande ci-dessous étale chaque maillon puis
les applique dans l'ordre — c'est le principe d'un incrémental : le dernier
`sources/<uuid>/<chemin>.gz` gagne.

```bash
export MSYS_NO_PATHCONV=1     # Git-Bash only ; Linux : inutile
docker run --rm -i \
  -v C:/Yabiladi_Upgrade/Yabiladi-Infra/backup/archives:/backups:ro \
  -v C:/Yabiladi_Upgrade/Yabiladi-Infra/backup/restore:/restore \
  alpine:3 sh -s <<'EOF'
set -e
C=/backups/portainer-volume-backup/chain-2026-11-12T20-11-12-341
T=/restore/portainer-drill
rm -rf "$T"; mkdir -p "$T/maillons" "$T/arbre"; cd "$T"
i=0
for a in $(ls "$C"/*.tar | sort); do i=$((i+1)); mkdir -p "maillons/m$i"; tar -C "maillons/m$i" -xf "$a"; done
for d in $(ls -d maillons/m* | sort -V); do
  [ -d "$d/sources" ] || continue
  for u in "$d"/sources/*/; do
    ( cd "$u" && find . -type f -name '*.gz' | while read -r f; do
        rel="${f%.gz}"; rel="${rel#./}"
        mkdir -p "$T/arbre/$(dirname "$rel")"; gunzip -c "$f" > "$T/arbre/$rel"
      done )
  done
done
rm -rf "$T/maillons"
find arbre -type f | sort | while read -r p; do
  printf '%s %8s %s\n' "$(sha256sum "$p" | cut -c1-16)" "$(wc -c < "$p")" "${p#arbre/}"; done
EOF
```

Sortie réelle, jouée deux fois de suite avec le même résultat :

```
6b0ee14c1bfc915f      518 certs/cert.pem
3641fce2ad339456      227 certs/key.pem
638b8505e1536b12      227 chisel/private-key.pem
6ff20c2b910b3a16  1048576 portainer.db
05dd37464f4247a5      227 portainer.key
0bffb4dba71a57da      190 portainer.pub
```

Cinq des six empreintes sont identiques au volume vivant. `portainer.db` diffère
(`9034812b95f0bedb` en direct contre `6ff20c2b910b3a16` dans l'archive) et c'est
normal : l'archive date de 21:01:26 et la base a été réécrite à 21:06. C'est
justement ce que la comparaison sert à vérifier — une divergence sur un **autre**
fichier que la base, ou sur un fichier absent, serait une vraie anomalie.

Par l'interface, le même travail se joue avec l'adaptateur de destination en
source de type « Restauration (dossier de travail) » pointé sur `/restore` ; le
script ci-dessus ne fait que ce que la console fait, sans attendre l'UI.

### 3. Vers un volume neuf, jamais par-dessus celui en marche

```bash
docker volume create yabiladi_portainer_restore_drill >/dev/null
docker run --rm -i \
  -v yabiladi_portainer_restore_drill:/data \
  -v C:/Yabiladi_Upgrade/Yabiladi-Infra/backup/restore/portainer-drill/arbre:/from:ro \
  alpine:3 sh -c 'cp -a /from/. /data/ && find /data -type f | wc -l'
# 6
```

### 4. Faire parler la base restaurée, hors réseau

```bash
docker run -d --name portainer-drill --network none \
  -v yabiladi_portainer_restore_drill:/data \
  portainer/portainer-ce:2.45.3-alpine --data /data
sleep 18
docker logs portainer-drill 2>&1 | head -20
docker logs portainer-drill 2>&1 | grep -icE 'level=(error|fatal)'   # 0
docker exec portainer-drill sh -c \
  "wget -S -O- --timeout=8 http://127.0.0.1:9000/ 2>&1 | grep -oE 'HTTP/1.[01] [0-9]{3}' | head -1"
```

Ce que les journaux ont dit, mot pour mot, sur les lignes qui comptent :

```
loading PortainerDB
found Chisel private key file on disk
executing post init migration for environment | endpoint_id=1
```

`loading PortainerDB` est la seule ligne qui prouve que le Bolt s'est ouvert.
`--network none` veut que rien ne sorte ni n'entre pendant le jeu : la base est
jugée sur sa propre réponse HTTP, `HTTP/1.1 200` sur `127.0.0.1:9000/`, et zéro
ligne `error` ou `fatal`.

Une ligne d'avertissement apparaît, et elle est vraie aussi sur l'instance de
production — donc ce n'est pas un défaut de l'archive :

```
encryption key file not present | filename=/run/secrets/portainer
```

Portainer ne chiffre rien au repos tant que cette clé n'est pas fournie ; la
restauration n'y change rien et n'a rien à vérifier de ce côté.

### 5. Ranger

```bash
docker rm -f portainer-drill
docker volume rm yabiladi_portainer_restore_drill
docker run --rm -i -v C:/Yabiladi_Upgrade/Yabiladi-Infra/backup/restore:/restore \
  alpine:3 sh -c 'rm -rf /restore/portainer-drill'
docker volume ls | grep -i portainer      # ne doit plus citer que yabiladi_portainer_data
```

Sortie réelle après le ménage : `local yabiladi_portainer_data`, rien d'autre.

### Remettre en place, le jour où il le faudra

Dans l'ordre, et seulement après avoir rejoué `backup.sh --quiesce` sur l'état en
place — c'est lui qui garde une archive du volume que l'on va écraser :

```bash
cd /opt/yabiladi-infra/docker-admin
docker compose --env-file ../.env -f compose.yaml stop portainer
docker run --rm -i -v yabiladi_portainer_data:/data -v <arbre-reconstitué>:/from:ro \
  alpine:3 sh -c 'rm -rf /data/.??* /data/* && cp -a /from/. /data/'
docker compose --env-file ../.env -f compose.yaml start portainer
bash scripts/validate.sh
```

Le `rm -rf` ne cible que `/data` **du conteneur jetable** monté sur ce volume :
c'est le seul cas où écraser est demandé, et uniquement parce que l'état d'avant
vient d'être archivé et vérifié. Si Portainer refuse de démarrer après cela, la
sortie est `scripts/rollback.sh`, pas une seconde écriture dans le volume.

## Ce que cette pile ne sauvegarde pas, et pourquoi c'est voulu

Dozzle n'a aucun volume : son rôle est de relire les journaux à Docker, pas de
les stocker. Les journaux, eux, vivent déjà dans Loki et suivent le job
`Fichiers - grafana` / la rétention du magasin, réglés à l'infrastructure. Le
mandataire de socket n'a pas d'état. Ajouter un volume à Dozzle aurait créé un
objet que la mission interdit de modifier, pour une donnée qui n'existe pas.
