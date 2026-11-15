# Dépannage

Du symptôme visible à la cause mesurée. Chaque cause citée a été observée sur
cette pile, avec sa commande de vérification ; ce qui reste théorique est écrit
comme tel.

## Portainer

### `https://portainer.yabiladi.com` répond 307, l'API 303, et rien ne s'ouvre

La fenêtre d'initialisation du compte administrateur est fermée. Portainer refuse
de démarrer sans administrateur et **l'offre pendant cinq minutes** après chaque
démarrage du conteneur ; passé ce délai, la racine rend `307` et chaque appel
d'API `303`, jusqu'au prochain redémarrage. Mesuré sur 2.45.3.

```bash
docker exec <cid> sh -c 'wget -S -O- --timeout=5 http://127.0.0.1:9000/ 2>&1 | grep -oE "HTTP/1.[01] [0-9]{3}"'
# 307 = fenêtre fermée, 200 = compte en place ou fenêtre ouverte
```

C'est aussi pour cela qu'un `401` sur `/api/endpoints` **ne prouve pas** le
compte administrateur : mesuré identique avec un compte en place et sans aucun
compte, tant que la fenêtre est ouverte — la porte basicauth de Traefik répond
avant lui.

**Remède** : `docker compose --env-file ../.env -f compose.yaml restart portainer`
puis créer le compte dans les cinq minutes, dans le navigateur. Le mot de passe
ne se saisit nulle part ailleurs : pas dans ce dépôt, pas dans une ligne de
commande, pas dans un journal.

### Le routeur disparaît du tableau de bord Traefik, `logs`/`portainer` passent en 404

Un middleware n'existe que le temps de vie du conteneur qui le déclare.
`portainer-htpasswd`, `portainer-ipallow` (et leurs jumeaux `dozzle-*`) sont
portés par les labels de **cette** pile : si le conteneur est supprimé ou jamais
démarré, Traefik perd à la fois le routeur et ses portes.

```bash
docker exec <cid-traefik> sh -c 'wget -q -O- http://127.0.0.1:8080/api/http/routers' | tr ',' '\n' | grep -iE "portainer|dozzle"
```

**Remède** : `bash scripts/deploy.sh`. Aucun redémarrage de Traefik n'est
nécessaire — son fournisseur Docker lit les évènements et le routeur revient à la
seconde (mesuré).

### La sonde de santé passe au vert puis échoue

`/` est le seul témoin de vie qui marche dans **les deux** états de l'instance :
200 quand la fenêtre est ouverte ou le compte en place, 307 sinon — et 307 est
une réponse, donc une vie. `/api/ping` répond `404` dans tous les cas (mesuré,
sur 2.45.3) : s'en servir comme sonde rendrait le conteneur éternellement
`unhealthy`.

## Dozzle

### `Could not connect to any Docker Engine`, deux lignes `fatal` au démarrage, puis rien

Le cas joué au premier déploiement : Dozzle interroge la socket pendant le
démarrage d'HAProxy et **meurt** — il ne réessaie pas. Le `depends_on:
condition: service_healthy` du `compose.yaml` est là pour ça.

```bash
docker logs <cid-dozzle> 2>&1 | grep -i fatal
docker inspect -f '{{.State.Health.Status}}' <cid-proxy>
```

**Remède** : `docker compose --env-file ../.env -f compose.yaml up -d dozzle`,
après un proxy revenu en `healthy`. Si le proxy lui-même tombe, voir plus bas.

### La liste des conteneurs est vide alors que l'interface s'ouvre

Deux causes, dans cet ordre de probabilité.

1. **Le mandataire est passé en `OOM`** : la limite est 48 MiB et HAProxy tenait
   21,76 MiB à vide, mais Dozzle garde le flux `/events` ouvert en permanence.
   Un mandataire tué par l'OOM rend Dozzle muet sans rien expliquer du côté
   navigateur.
   `docker inspect -f '{{.State.OOMKilled}} {{.RestartCount}}' <cid-proxy>`.
2. **Le filtre a changé d'avis** : la liste se lit dans la page servie par Dozzle
   (bloc `config__json`), pas par une API — mesuré, v11.4.2 ne rend **aucune**
   route JSON de liste de conteneurs (`/api/v2/container` et consorts répondent
   404).

```bash
docker exec <cid-dozzle> sh -c 'wget -q -O- --timeout=10 http://127.0.0.1:8080/' \
  | grep -oE '"hosts":\[[^]]*\]'
# attendre "available":true
docker exec <cid-dozzle> sh -c 'wget -q -O- --timeout=8 "http://docker-socket-proxy:2375/containers/json?all=0"' | head -c 200
```

Le second appel est la preuve directe : s'il rend du JSON et que la liste reste
vide, c'est Dozzle ; s'il rend `403`, c'est le mandataire.

### Les journaux d'un conteneur apparaissent vides dans l'interface

Deux particularités du moteur et de Dozzle, toutes deux mesurées ici :

- **Docker Engine 29** rend `400` sur `/containers/{id}/logs` si aucun flux
  n'est demandé. Une sonde qui omet `stdout`/`stderr` ne prouve rien.
- **Dozzle écrit ses propres journaux sur stderr** : `?stdout=1` seul donne
  0 octet, `?stdout=1&stderr=1&tail=20` donne le texte.

### `canAddHosts` change de valeur d'une passe à l'autre

Ce n'est pas un réglage oublié, et ce n'est pas non plus une constante : **aucun
drapeau de Dozzle ne le commande**, mesuré sur `--help` de v11.4.2 en lisant sa
propre page. La valeur servie a été relevée `true` sur deux démarrages distincts
les 12 et 13 novembre, puis `false` le 15 novembre — même image
`v11.4.2-alpine`, même `command:` sans drapeau, même `DOCKER_HOST`, `/data` vide.
Rien ici n'explique le basculement, et le croire stable serait une erreur de
diagnostic : `validate.sh` rend la valeur lue à la passe, pas une promesse.

Ce qui ne dépend pas de la valeur, c'est la portée. Ce champ est une **sortie** —
la possibilité de proposer au navigateur une adresse d'hôte Docker à interroger —
pas un droit d'administration local : les verbes d'écriture restent refusés par
le mandataire (`POST` renvoie 403, mesuré) et Dozzle n'a pas la socket.

Ce qui le ferme vraiment est réseau : la pile est derrière `ipallowlist` puis
basicauth, et `yabiladi_admin_internal` est `internal: true`, donc rien ne sort.
`validate.sh` le signale en **non joué**, pas en réussite.

## Traefik et les portes

### `403` au lieu de la fenêtre d'authentification

C'est l'`ipallowlist` qui parle, avant toute question de compte — le comportement
voulu. Elle compare l'adresse du **pair TCP**, donc la variable `DAGU_ALLOWED_IPS`
doit couvrir le réseau du VPN ou du bureau depuis lequel on écrit.

```bash
grep -n DAGU_ALLOWED_IPS ../.env
docker exec <cid-traefik> sh -c 'wget -q -O- http://127.0.0.1:8080/api/http/middlewares' | tr ',' '\n' | grep -A2 ipallow
```

### `401` alors que le compte est bon, ou `401` par intermittence

Le fichier de comptes est celui de Dagu, monté dans Traefik
(`/etc/traefik/htpasswd/user_yabiladi`), matérialisé par `../deploy.sh` depuis
`deploy/secrets/htpasswd_user_yabiladi.sops.bin`. Deux causes mesurées ailleurs
dans la maison : un `htpasswd` régénéré sans redéployer Traefik, et 25 échecs
rapprochés qui verrouillent — le second concerne Grafana, pas Traefik, mais il
vaut la peine de vérifier l'ordre des tentatives avant de toucher au fichier.

```bash
docker exec <cid-traefik> test -r /etc/traefik/htpasswd/user_yabiladi && echo lisible
```

Ne jamais éditer ce fichier à la main : la vérité est dans le coffre, et le
re-sceller est le seul geste qui ne casse pas les quatre consoles qui le partagent.

### `Certificate` en échec au premier `up`, ou `too many certificates` dans les journaux Traefik

Sur un poste de développement, ni Let's Encrypt ne peut joindre la machine ni son
certificat ne couvre ces noms. Le geste maison : vider le résolveur dans un
fichier ignoré par git.

```bash
cp docker-admin/compose.override.yaml.example docker-admin/compose.override.yaml
docker compose --env-file ../.env -f compose.yaml -f compose.override.yaml up -d
```

Sans lui, `up` reste bloqué sur une demande de certificat. C'est le même réglage
que pour `grafana`, `dbackup` et le tableau de bord Traefik.

### Aucun prompt d'identification sur `logs` ou `portainer`, alors qu'un `curl -k` rend `401`

Cause mesurée le 2026-11-15 : le nom manquait de la liste SAN du certificat de
poste. Un nom que le certificat local ne porte pas ne fait tomber Traefik dans
aucune erreur — il répond sur le 443 avec son certificat par défaut
(`CN=TRAEFIK DEFAULT CERT`, CA inconnue du navigateur), et le handshake se coupe
**avant** la porte basicauth. Ce jour-là `logs`, `portainer` et `pub` avaient
pourtant leur routeur et leur `401` en interne, et `dagu` — lui dans la liste —
s'ouvrait sans difficulté : la fenêtre d'identification n'a jamais eu à se
justifier, c'est le TLS qui parlait. Ce contrôle est invisible dans
`validate.sh` tel qu'il est écrit : ses sondes HTTP passent par `curl -k`
(ligne 108), donc un `401` y ressemble à une porte saine même servi sur le
mauvais certificat.

```bash
for h in logs portainer pub dagu; do
  printf '%-10s ' "$h"
  echo | openssl s_client -connect 127.0.0.1:443 -servername "$h.yabiladi.com" 2>/dev/null \
    | openssl x509 -noout -subject | sed 's/subject=CN=//'
done
grep -n 'subjectAltName' ../docker/traefik/generate-cert.sh
```

**Remède** : ajouter le nom à la liste de `../docker/traefik/generate-cert.sh`,
rejouer `sh docker/traefik/generate-cert.sh`, puis `docker compose restart
traefik` — c'est le geste rejoué et mesuré ici ; le fournisseur de fichiers ne
relit un certificat que s'il voit bouger son fichier de configuration, et
`dynamic.yml`, lui, ne change pas. Le dossier `docker/traefik/certs/` est ignoré
par git : les octets générés ne se committent pas, seule la liste de noms se
commite.

Ce `restart` laisse un témoin, et il faut le connaître avant de crier à la
régression : dans les quinze minutes qui le suivent, `validate.sh` rend sa ligne
Traefik en **non joué** — « créé le … donc non recréé, mais démarré il y a N
min ». C'est voulu. La phrase que cette ligne portait avant aujourd'hui
affirmait « ce déploiement ne l'a ni recréé ni redémarré » sans rien comparer, et
elle l'a affirmé pendant que ce redémarrage-là venait d'avoir lieu ; elle calcule
désormais les deux dates et s'interdit la conclusion quand le démarrage est
récent. `RestartCount`, lui, reste à `0` (mesuré) : il ne compte que les reprises
voulues par la politique de relance, pas un `docker restart` manuel.

Une conséquence à connaître avant d'appeler cela « réglé » : le certificat de
poste n'était **porté par aucun magasin Windows** (mesuré le 2026-11-15 au matin,
`Root`, `TrustedPeople`, `AuthRoot`, `My` en `LocalMachine` et `CurrentUser` :
zéro entrée `yabiladi`/`TRAEFIK`, et la sonde Schannel rendait `UntrustedRoot`
pour les sept noms). Ce qui changeait ce jour-là, c'est seulement que `logs`,
`portainer` et `pub` présentaient désormais le même certificat stable que les
cinq consoles en place, au lieu de celui que Traefik régénère à chaque démarrage.

### Supprimer l'avertissement du navigateur sur un poste de développement

Rendre ce certificat digne de confiance est un geste **sur la machine**, pas dans
ce dépôt, et Windows le rappelle : toute écriture dans un magasin « Racines
approuvées » ouvre une fenêtre « Avertissement de sécurité » que seul un humain
valide. Joué le 2026-11-15 sur ce poste, pour le compte courant :

```powershell
Import-Certificate -FilePath 'C:\Yabiladi_Upgrade\Yabiladi-Infra\docker\traefik\certs\yabiladi.com.crt' `
  -CertStoreLocation 'Cert:\CurrentUser\Root'      # la fenêtre de consentement fait partie du geste
```

Mesuré après coup, dans cet ordre : `CurrentUser\Root` 47 entrées dont 1 avec
l'empreinte du jour ; `LocalMachine\Root` 46 entrées, aucune (l'import par
compte ne couvre ni les autres comptes ni les processus élevés) ; la sonde
Schannel rend « aucune alerte » sur `logs`, `portainer`, `dagu`, `grafana`,
`backups`, `pub`, `www` ; Chrome, en instance `--headless` avec un profil jetable
et donc sans toucher au navigateur de l'opérateur, rend sur ces sept noms soit
`net::ERR_INVALID_AUTH_CREDENTIALS` — les cinq consoles, c'est la porte basicauth
qui répond après un TLS accepté — soit un DOM complet pour `pub` et `www`.

Le contrôle qui empêche de lire ces sept réussites comme une vérification
désactivée : `radio` et `sirwa`, absents de la liste SAN et donc servis par le
certificat par défaut de Traefik, rendent toujours `net::ERR_CERT_AUTHORITY_INVALID`.

Deux pièges restent :

- **il faut réimporter après chaque régénération.** `sh docker/traefik/generate-cert.sh`
  produit une empreinte nouvelle ; le magasin, lui, garde l'ancienne, et Chrome
  retombe sur `ERR_CERT_AUTHORITY_INVALID` sans que rien n'ait changé ailleurs. Le
  contrôle se fait par empreinte, pas par sujet :

  ```powershell
  Get-ChildItem Cert:\CurrentUser\Root | Where-Object { $_.Subject -like '*yabiladi*' } |
    Select-Object Thumbprint, NotAfter
  ```

- une entrée déjà présente ne se remplace pas : `Import-Certificate` ajoute, il ne
  met pas à jour. Retirer l'ancienne avant, ou la laisser comme vestige tant
  qu'elle n'est plus servie.

L'alternative propre, si ce manège se reproduit, est de séparer l'autorité du
certificat serveur (une racine qui ne bouge plus, un certificat signé par elle et
régénéré à volonté — ce que fait `mkcert`) : la liste SAN cesserait d'être un
prérequis du magasin. Ce n'est pas joué ici, et cela touche
`docker/traefik/generate-cert.sh` et `dynamic.yml`.

En production, rien de tout cela ne se rejoue : le label
`tls.certresolver=letsencrypt` de chaque routeur demande son propre certificat
(HTTP-01 sur l'entrée `web`, `../compose.yaml:228-230`), et le seul prérequis
reste l'enregistrement DNS du nom plus le port 80 joignable.

### `504` sur une console, alors que le conteneur répond en interne

Joué ici, sur `https://www.yabiladi.com/` (le site, pas cette pile) : `504` par
Traefik pendant qu'un `curl` direct sur nginx, avec l'en-tête `Host`, rend `200
en 0.21 s`. Le 504 de Traefik est un timeout de 30 s sur le **chemin d'accès**,
pas un diagnostic de l'application.

Le réflexe est de relancer Traefik. **Ne pas le faire** : cette pile ne le
redémarre jamais, et un `docker restart` de Traefik coupe toutes les consoles à
la fois. `validate.sh` rend exactement cette comparaison dans sa ligne
d'avertissement, et sa ligne Traefik rend les deux dates qui permettent de s'y
retrouver — `Created` (recréé ?) et `StartedAt` (redémarré depuis quand ?).

## Sauvegarde

### Le job dit `Success` et l'archive fait 0 fichier

Cause mesurée, et c'est la plus fréquente : les droits du volume. Portainer écrit
en root, `portainer.db` sort en `0600 root:root`, la console lit en uid 1001
groupe 33 et ne voit rien — elle archive ce qu'elle peut, ici rien, et le
compteur à zéro reste un succès dans l'interface.

```bash
bash docker-admin/scripts/backup.sh --grant-only
bash docker-admin/scripts/backup.sh --check
```

Le premier geste est donc de regarder ce que la console voit, pas ce que le job
a rendu :

```bash
cid=$(docker ps -q --filter label=com.docker.compose.service=dbackup | head -1)
docker exec --user 1001:33 "$cid" sh -c 'find /backup/portainer -type f -readable | wc -l'
```

Un fichier sur six, c'est six moins un à la restauration. `validate.sh` rend les
deux nombres côte à côte (« 6 fichier(s) lisible(s) sur 6 ») pour que l'écart ne
puisse pas se cacher dans un libellé.

### Le fichier d'après la passe n'est pas dans l'archive

La passe de droits ne vaut que pour l'instant où elle se joue : tout ce que
Portainer crée ensuite ressort en `0600 root:root`. C'est le trou que ferme
l'`entrypoint` du service — `umask 027` et les dossiers en `2750` (setgid), pour
qu'un fichier nouveau-né hérite du groupe 33 et du mode `0640` sans qu'aucun
planificateur n'intervienne.

À contrôler dans l'ordre, parce que deux échecs différents se ressemblent :

```bash
cid=$(docker ps -q --filter label=com.docker.compose.service=portainer | head -1)
docker exec "$cid" sh -c 'ls -ld /data; sed -n "s/^Umask:[[:space:]]*//p" /proc/1/status'
docker inspect -f '{{.HostConfig.CapAdd}}' "$cid"
```

- `Umask` autre que `0027`, ou `/data` en `750` et non `2750` → l'entrypoint n'a
  pas tourné : le conteneur a été créé avant le changement. Un `up -d
  --force-recreate --no-deps portainer` ne touche que ce service.
- l'entrypoint tourne mais `/data` reste `750`, **sans message d'erreur** : c'est
  `CAP_FSETID` qui manque. Mesuré — busybox `chmod 2750` rend 0 et ne pose pas le
  bit ; le même `chmod` avec le jeu de capacités par défaut de Docker, lui, le
  pose. Le `cap_add` de `compose.yaml` doit donc porter `CHOWN, FOWNER, FSETID`.
- `chmod 2750` présent mais éphémère : la passe du script, `backup.sh`, faisait
  `chmod 0750` sur les dossiers et **effaçait le setgid à chaque archive**. Les
  deux endroits doivent écrire `2750`, et c'est le cas.

### `chgrp: Operation not permitted` pendant l'ouverture des droits

Le geste se joue `docker exec --user root`, donc avec les capacités du service
reprises telles quelles : `cap_drop: ALL` plus
`cap_add: [CHOWN, FOWNER, FSETID]`. Ces trois-là sont exactement ce qu'il faut,
mesuré. Si l'erreur vient quand même :

- le conteneur a été créé avant l'ajout des `cap_add` → `up -d --force-recreate
  --no-deps portainer`, qui ne touche que ce service ;
- un `--user` non root a été ajouté au service → il annule le `--user root` de
  la commande.

### `ERREUR: aucun conteneur « dbackup » en marche`

La console de sauvegarde vit dans l'autre projet du dépôt. `backup.sh` ne la
démarre jamais, ne la recrée jamais, ne la redémarre jamais : il la trouve par
étiquette Compose.

```bash
docker ps --filter label=com.docker.compose.service=dbackup
```

Absente, le remède est à la racine du dépôt (`docker compose up -d dbackup`), pas
dans `docker-admin`.

### `« /backup/portainer » n'est pas monté ou pas lisible dans la console`

Le montage est déclaré dans `../compose.yaml`, pas ici : la ligne
`portainer_data:/backup/portainer:ro` du service `dbackup`. Un `docker-admin`
déployé sans redéployer l'infrastructure a le volume, mais pas la fenêtre dessus.

### Le maillon d'un soir ne contient qu'un fichier

Normal un jour sans changement : un incrémental à 0 ou 1 fichier est la trace
qu'il n'y avait rien à dire. Ce qui ne l'est pas, c'est un **full** à 0 fichier
(voir plus haut), ou une chaîne dont le `--check` ne sait plus dire combien de
fichiers elle sait rendre.

## Git Bash sur un poste Windows

Deux artefacts de la machine, pas de la pile. Les deux sont traités dans les
scripts — ils reviennent si on les retire.

### `test: /etc/traefik/...: No such file or directory` alors que le fichier existe

Git-Bash réécrit les arguments en cours de route : un chemin `/etc/...` passé à
`docker.exe` (binaire Windows) part en `C:/Program Files/Git/etc/...`. Deux
parades, dans l'ordre de préférence :

```bash
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'   # en tête de script
docker exec "$cid" sh -c 'test -r /etc/traefik/htpasswd/user_yabiladi'   # chemin dans une string « sh -c »
```

### Un contrôle HTTP rend `401000`, `000000` ou `200000`

Deux causes, à distinguer avant d'appeler cela une panne.

**La première est un artefact de Git Bash**, conséquence de la parade ci-dessus :
avec `MSYS_NO_PATHCONV`, le `-o /dev/null` de `curl` ne passe plus (Windows ne
connaît pas `/dev/null`) et le trou noir s'écrit `NUL`. `validate.sh` choisit
selon le système :

```bash
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) DEVNULL=NUL ;; *) DEVNULL=/dev/null ;; esac
```

Le reste du chiffre vient du script lui-même, et c'est corrigé : la sonde
faisait `curl … || printf '000'`, or `curl -w '%{http_code}'` écrit déjà `000`
quand la requête part en échec avant de sortir en non nul. Deux `000` collés ne
ressemblaient plus à rien de ce que le contrôle sait lire — un `000000` tombait
dans la branche générique au lieu de la branche qui compare aux deux chemins. La
valeur se relève maintenant dans une variable, un repli ne s'ajoute que si elle
est vide, et `000` redevient `000`.

**La seconde cause est une fenêtre de déploiement.** Un `000` rendu sur
`https://www.yabiladi.com/` alors que le même `curl` dix secondes plus tard rend
`200` : le backend se faisait recréer pendant la sonde (mesuré ici, nginx recréé
à 21:49 puis php à 21:55, la sonde étant tombée entre les deux). Ce nom est le
seul de la section « non-régression » dont la réponse traverse un conteneur
applicatif, c'est le seul aussi qui puisse bouger sous la main de qui déploie le
site.

C'est à cela que sert le second nombre de la ligne. Le contrôle compare deux
chemins : Traefik (`https://…`, le chemin du visiteur) et nginx en direct
(`http://127.0.0.1:8080/` avec l'en-tête `Host`, le chemin du serveur). Les
quatre autres consoles s'arrêtent à la porte basicauth et leur `401` ne dit rien
de leurs backends ; celui-ci, si.

- les deux en échec → **le site est en panne pour son propre compte**, cette pile
  n'y change rien ;
- `000` ou `504` par Traefik et `200` en direct → **chemin d'accès**, ou
  connexions périmées que Traefik garde sur une adresse qui a changé : il retombe
  sur ses pieds au deuxième ou troisième essai. Rejouer la sonde, et ne surtout
  pas relancer Traefik pour autant.

### `docker compose ps` ne liste rien alors que les conteneurs tournent

Le nom de projet vient du **dossier**, et `docker-admin` n'est pas le projet
`yabiladi-infra`. Les scripts nomment toujours le fichier, et le second fichier
seulement s'il existe :

```bash
docker compose --env-file ../.env -f compose.yaml [-f compose.override.yaml] …
```

Un `up -d` lancé depuis la racine du dépôt, lui, ne démarrera jamais ces trois
services-là.

## Comment lire `validate.sh`

Le script termine sur trois nombres : réussites, échecs, **non joués** — leur
somme fait les 77 contrôles du jeu. Un contrôle non jouable n'est pas un contrôle
réussi : c'est la raison pour laquelle les trois exclus du compte de réussite sont
écrits en toutes lettres dans `installation.md` — le chemin authentifié (il
faudrait le mot de passe), le compte administrateur de Portainer (à créer à la
main), et le réglage `canAddHosts` de Dozzle (il se lit à chaque passe, ne se
commande pas). S'y ajoutent deux lignes **conditionnelles**, qui basculent selon
l'heure et non selon une décision de conception : l'empreinte au sol
(`docker stats`, seulement avec `--resources`) et la ligne Traefik, en non joué
pendant les quinze minutes qui suivent un redémarrage de celui-ci.

Une ligne `https://www.yabiladi.com/ → 000` en échec, elle, se lit avec son
second nombre : si nginx répond `200` en direct sur la même ligne, le site est
vivant et c'est le chemin d'entrée qui a trouvé une adresse périmée — la fenêtre
d'un `recreate` d'un conteneur du site, pas une panne de cette pile (ci-dessus,
« Un contrôle HTTP rend… »). Un nom d'hôte que ce poste ne résout pas du tout
rendrait la même valeur, et la ligne le dirait aussi : c'est le DNS local, pas le
service.
