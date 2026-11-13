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

### `canAddHosts` est à `true` dans la configuration servie

Ce n'est pas un réglage oublié : **aucun drapeau de Dozzle ne l'éteint**, mesuré
sur v11.4.2 en lisant sa propre page. La portée réelle est une **sortie** — la
possibilité de proposer au navigateur une adresse d'hôte Docker à interroger —
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

### `504` sur une console, alors que le conteneur répond en interne

Joué ici, sur `https://www.yabiladi.com/` (le site, pas cette pile) : `504` par
Traefik pendant qu'un `curl` direct sur nginx, avec l'en-tête `Host`, rend `200
en 0.21 s`. Le 504 de Traefik est un timeout de 30 s sur le **chemin d'accès**,
pas un diagnostic de l'application.

Le réflexe est de relancer Traefik. **Ne pas le faire** : cette pile ne le
redémarre jamais, et un `docker restart` de Traefik coupe toutes les consoles à
la fois. `validate.sh` rend exactement cette comparaison dans sa ligne
d'avertissement, et la section « non-régression » rappelle la date de démarrage
du conteneur pour prouver qu'il n'a pas été touché.

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
main), et l'« Add host » de Dozzle (il se lit, ne se referme pas).

Une ligne `https://www.yabiladi.com/ → 000` en échec, elle, se lit avec son
second nombre : si nginx répond `200` en direct sur la même ligne, le site est
vivant et c'est le chemin d'entrée qui a trouvé une adresse périmée — la fenêtre
d'un `recreate` d'un conteneur du site, pas une panne de cette pile (ci-dessus,
« Un contrôle HTTP rend… »). Un nom d'hôte que ce poste ne résout pas du tout
rendrait la même valeur, et la ligne le dirait aussi : c'est le DNS local, pas le
service.
