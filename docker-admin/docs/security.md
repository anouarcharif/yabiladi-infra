# Sécurité

Ce qui protège quoi, mesuré le 2026-11-12 sur cette machine, et ce qui reste
ouvert. La phrase à garder en tête : **Portainer tient la socket Docker en
écriture, donc il tient la racine de l'hôte.** Tout le reste de ce fichier
décrit les portes qu'il faut franchir avant lui, et les deux seuils qui ne
peuvent pas se fermer depuis cette image.

## Les trois portes, dans l'ordre

| Porte | Qui la pose | Ce qu'elle refuse | Vérifié par |
| --- | --- | --- | --- |
| plage d'adresses | Traefik, middleware `*-ipallow` | une adresse hors plage ne reçoit **pas 401 mais 404** : la console ne dit pas qu'elle existe | `validate.sh` lit la chaîne de middlewares telle que rendue à Traefik |
| compte basicauth | Traefik, middleware `*-htpasswd` | `401` sans compte et avec un mauvais compte, sur les deux noms, en HTTPS | six sondes HTTP dans `validate.sh` |
| capacité d'action | le mandataire pour Dozzle ; le compte interne à Portainer | `403` sur tout verbe d'écriture et sur quatre groupes de lecture | sondes d'API en interne |

Les deux premières portent la source unique `DAGU_ALLOWED_IPS` et le fichier de
compartiment `docker/traefik/htpasswd/user_yabiladi` — un seul compte pour les
sept interfaces d'administration de la machine, bcrypt, 0600 root dans le
conteneur Traefik, et **hors du dépôt** : il est scellé dans
`deploy/secrets/htpasswd_user_yabiladi.sops.bin` et matérialisé par `../deploy.sh`.
`removeheader: true` descend partout : l'en-tête `Authorization` ne parvient ni à
Portainer ni à Dozzle.

Aucun des trois conteneurs ne publie de port (mesuré : `docker port` rend une
ligne vide trois fois). Sans Traefik, il n'y a pas de porte — et Traefik n'est pas
sur le réseau privé du mandataire.

## Portainer : assumé privilégié

Montage `rw` sur `/var/run/docker.sock`, et c'est voulu : administrer Docker
passe par les verbes `POST` de l'API. Ce qui est autour :

- `cap_drop: ALL`, puis `cap_add: [CHOWN, FOWNER, FSETID]` ** seulement **. Ces
  trois capacités existent pour un seul geste, celui de la sauvegarde : ouvrir le
  groupe 33 sur les fichiers que Portainer écrit en 0600, et poser le bit setgid
  sur ses dossiers pour que ceux d'après naissent déjà lisibles. Mesuré sans
  elles : `chgrp -R 33 /data` échoue et le job du soir n'archiverait que des
  dossiers vides. Sans `FSETID`, plus subtil : le `chmod 2750` de busybox rend
  code de sortie 0 et laisse le dossier en `750` — l'échec est muet, seul le mode
  final le dit (d'où le contrôle « CAP_FSETID au catalogue » dans `validate.sh`).
  Aucune des trois ne permet d'écouter un port privilégié, de charger un module
  ni de toucher la socket d'un autre conteneur.
- l'`entrypoint` enveloppe `/portainer` d'une passe de droits (`umask 027`,
  `chgrp`, `chmod 2750` / `0640`) puis lui rend la main avec `exec … "$@"`. Le
  service se donne donc ses droits à lui-même à chaque démarrage, sans
  planificateur et sans qu'un second conteneur ait à tenir la socket. Mesuré
  après l'ajout : PID 1 toujours `/portainer --host … --data /data`, arguments
  d'origine intacts.
- `no-new-privileges:true`, `networks: [app]` — pas le réseau privé du
  mandataire, dont il n'a que faire puisqu'il a la socket.
- limites `0.50` CPU / `384M`, mesurées à 18–26 Mio.
- pas de `read_only` : l'interface écrit dans `/data` (son volume) et s'y
  fabrique un dossier temporaire. Le durcissement porte sur ce qu'elle peut
  *faire*, pas sur ce qu'elle peut *écrire*.

Ce que l'API rend sans jeton, mesuré sur 2.45.3 une fois l'interface démarrée :
`/api/endpoints` → `401`, `/api/users/admin/init` → `405` (POST seul),
`/api/ping` → `404` (la sonde de santé du dépôt lit donc la racine, pas ce chemin),
et `/api/system/status` → `200`, qui donne la version. Atteignable seulement après
les deux premières portes — mais la version du produit est publique, et cela se
sait.

## Le mandataire, seule façon dont Dozzle voit Docker

`tecnativa/docker-socket-proxy:v0.5.0` (HAProxy 3.4.2), sur le réseau
`yabiladi_admin_internal` marqué `internal: true` : ni route sortante pour lui,
ni entrée depuis `yabiladi_app`. La socket y est montée **en lecture seule**
(`rw=false` vérifié), et l'image ne change pas d'utilisateur — la socket est
`root:docker 0660` sur l'hôte, donc ni `user:` ni `cap_drop: ALL` ne pourraient la
lire. Le durcissement est ailleurs :

| Chemin | Verdict mesuré |
| --- | --- |
| `GET /containers`, `/images`, `/info`, `/version`, `/_ping`, `/events` | autorisés — c'est ce que l'interface consulte |
| `GET /containers/{id}/logs?stdout=1&stderr=1` | autorisé (le moteur 29 répond `400` si aucun flux n'est demandé) |
| `GET /volumes`, `/networks`, `/configs`, `/secrets` | `403` |
| `POST /containers/create` | `403` |

Les six groupes autorisés sont écrits dans `compose.yaml` ; tout le reste des
drapeaux de l'image vaut `0` (EXEC, BUILD, COMMIT, CONFIGS, DISTRIBUTION,
NETWORKS, VOLUMES, SECRETS, SERVICES, SESSION, PLUGINS, NODES, SWARM, SYSTEM,
TASKS, GRPC, AUTH), et `POST: "0"` ferme d'abord le verbe pour tous. `ALLOW_START`,
`ALLOW_STOP`, `ALLOW_RESTARTS` valent `0` exprès : déjà le défaut de l'image, mais
un défaut qui change de version en version ne doit pas passer inaperçu.

## Dozzle : ce qu'il affirme de lui-même

Il n'a **aucun montage de socket** (vérifié dans ses propres mounts). Et l'aveu le
plus solide n'est pas dans un fichier, c'est dans la page qu'il sert — le bloc
`config__json`, lu par `validate.sh` :

```
"enableActions": false      → aucun bouton d'arrêt, de redémarrage ou de suppression
"enableShell": false        → aucun terminal dans un conteneur
"canAddHosts": true         → l'interface propose d'ajouter un hôte Docker
"hosts":[{"available":true}]  → le mandataire lui répond bien
```

Les deux premiers réglages ne sont pas passés en ligne de commande (`--enable-actions`
et `--enable-shell` absents du `command:`), et `--auto-update` comme
`--auto-cleanup` sont éteints *explicitement* : une interface de lecture qui se
mettrait à purger des images et à redéployer des conteneurs chaque nuit serait la
pire des surprises.

**« Add host » reste ouvert, et c'est à connaître.** Aucun réglage de l'image ne
le ferme (il n'existe pas de drapeau, mesuré sur `--help` de v11.4.2). Ce n'est pas
une main sur *cette* socket — le mandataire refuse tout ce qui écrit, tableau
ci-dessus — mais c'est une sortie : un hôte ajouté serait joint par Dozzle depuis
le réseau `yabiladi_app`, qui a une route vers l'extérieur. Deux portes restent
devant ce geste, la plage d'adresses puis le compte. Le vérifier à chaque contrôle,
et non pas le compter comme un succès, est le rôle de la ligne
`Dozzle propose « Add host »…` en sortie de `validate.sh`. Si ce seuil devait
gêner, la fermeture réelle passe par le réseau (ne pas laisser `yabiladi_app`
sortir) et non par Dozzle.

## Chiffrement des archives : l'état réel de la console

La sauvegarde de Portainer archive `portainer.db`, `certs/key.pem` et
`chisel/private-key.pem` — les clés de l'autorité interne et de communication avec
les agents. Le manifeste de la console porte un champ `archive.encrypted` :

| Job relu le 2026-11-12 | `encrypted` |
| --- | --- |
| `portainer-volume-backup` | `false` |
| `Fichiers - traefik-acme` (clés ACME) | `false` |
| `Fichiers - traefik-config` (autorité et certificats) | `false` |
| `Fichiers - media` | `false` |

Le nouveau job n'introduit donc pas un cas particulier : il rejoint une console où
**rien n'est chiffré**, y compris deux jobs qui archivent déjà des clés privées. La
protection des archives est aujourd'hui l'accès au disque de rétention
(`DBACKUP_DEST_HOST_PATH`) et au compte de la console. Activer le chiffrement se
fait dans l'interface — il n'existe aucun chemin scripté pour cela, et ce n'est pas
un oubli de ce dépôt. C'est à décider pour les trois jobs à clés en même temps :
basculer une chaîne existante sur un format chiffré se prépare, et cette mission
interdit de retoucher les jobs des autres.

## Journalisation et disque

`json-file`, 10 Mio par fichier, trois fichiers au maximum par conteneur (l'ancre
`*docker-logs`, la même que le reste de l'infrastructure). Dozzle ne stocke rien :
il relit les fichiers du moteur au moment où on les ouvre, sans base, sans index,
sans rétention propre. Le total des trois limites hautes vaut 560 Mio de RAM ; la
mesure réelle à vide est d'environ 55 Mio (voir maintenance.md).

## Ce qui n'est pas protégé, et pourquoi

- **Le compte administrateur de Portainer n'est pas créé.** C'est un mot de passe
  à choisir par un humain ; le poser par script l'écrirait dans un journal ou dans
  le dépôt. Voir installation.md pour la fenêtre de cinq minutes.
- **Le chemin authentifié n'est pas joué** par la suite de contrôles, pour la même
  raison. Il l'est sur demande, avec deux variables d'environnement.
- **Le mandataire tourne en root** dans son conteneur, et la socket est en
  lecture seule au niveau du montage, pas au niveau du noyau : un HAProxy
  compromis peut lire tout ce que l'API Docker *rend*, mais ne peut pas écrire.
  La liste blanche de chemins est la seconde barrière, mesurée ci-dessus.
- **La mesure n'a pas été faite depuis une attaque** : les contrôles prouvent ce
  que l'API refuse aujourd'hui, sur cette version d'image, avec cette
  configuration. Une montée de version se rejoue (`scripts/validate.sh` après
  chaque changement d'image, et `rollback.sh` garde la copie d'avant).
