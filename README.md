# Yabiladi-Infra

Infrastructure commune de la pile : Traefik, Postfix, geoipupdate, DBackup,
Loki/Alloy/Grafana, Prometheus/node_exporter/cAdvisor. Se déploie en premier
(`git pull` puis `./deploy.sh`), chaque projet — site, facturation, médiakit —
tenant ensuite ses propres conteneurs avec son propre script. Ordre complet,
chemins attendus sur la machine et migration des volumes et réseaux existants :
[MIGRATION.md](../MIGRATION.md).

## L'adresse du visiteur arrive jusqu'ici

Deux lignes du `compose.yaml` de Traefik — une par entrée, `web` et `websecure` —
portent `forwardedHeaders.trustedIPs=${TRAEFIK_TRUSTED_PROXY_IPS}`. Sans elles,
Traefik remplace le `X-Forwarded-For` reçu par l'adresse de son pair TCP et la
vraie adresse du visiteur meurt avant d'atteindre nginx, qui ne peut plus la
reconstituer. `TRAEFIK_TRUSTED_PROXY_IPS` se compose dans le `.env` versionné :
les plages publiées par Cloudflare (`CLOUDFLARE_TRUSTED_IPS`) plus les trois
réseaux privés Docker, parce que le pair direct de Traefik est son propre conteneur.

Ces deux listes ne vivent pas ici seules : le projet du site tient le fichier
`docker/nginx/snippets/cloudflare-real-ip.conf` avec les mêmes plages, et une
seule commande les régénère ensemble (`app:edge:cloudflare-ranges`, dans
`Yabiladi-V2-Symfony`). Le DAG mensuel `cloudflare_ranges` les compare à l'API et
sort en échec sur un écart — il ne recharge rien, faute de socket Docker et de
dépôt à portée. Quand il échoue, les deux dépôts se mettent à jour et s'exécutent
`./deploy.sh` l'un après l'autre : `git pull` ici et là, rien à décommenter.

Enfin, les consoles `dagu`, `grafana`, `backups`, `traefik` et `navidrome` restent
en **DNS only** chez Cloudflare (nuage gris). Leurs barrières —
`ipallowlist.sourceRange` sur `DAGU_ALLOWED_IPS` ici et dans
`docker/traefik/dynamic.yml` — comparent l'adresse du pair TCP : proxifiées, elles
jugeraient une sortie de datacenter partagée avec des millions de visiteurs.

## Les retouches d'interface rentrent dans git toutes seules

`allowUiUpdates: true` dans
`docker/grafana/provisioning/dashboards/logging.yaml` rend l'enregistrement
possible depuis l'IHM Grafana — et écrit dans la **base** Grafana, pas dans les
JSON versionnés. Le retour vers git se fait par un export API lu avec le compte de
service Viewer `synchro-ihm` (`tools/sync/export-grafana.mjs`, qui régénère les
dashboards du provisioning), et le même mouvement pour la console de sauvegarde
(`tools/backup/dbackup-bootstrap.mjs --export` régénère `tools/backup/jobs.json`
depuis les dix jobs en place, en croisant chaque chemin avec les montages
`/backup` de `compose.yaml` pour signaler un job qui n'a plus rien à archiver).

Le conducteur, lui, est de l'autre côté : `docker/dagu/ui-git-sync.sh` dans le
dépôt du site, appelé par le DAG `synchro_ihm_git` toutes les quinze minutes. Il
clone les deux dépôts dans son propre volume et **lit les exporteurs ci-dessus
dans le clone de l'infra** — c'est pour ça que les scripts restent ici et que le
conducteur n'y est pas : un DAG qui appelle un script de ce dépôt le trouve en
`tools/`, à côté des autres outils, et non en `docker/`.

Le coffre centralise la table mais pas les fichiers : la ligne
`deploy/secrets/ui-sync.sops.bin` de `deploy/secrets.manifest` est marquée
`site`, et c'est le `deploy.sh` du site qui la matérialise en
`docker/legacy/ui-sync.env` (0600, `env_file` du seul conteneur `dagu`). Les
six variables — dont le couple de promotion administrateur de DBackup, lu par
l'export à chaque passe — ne passent par un journal, une ligne de commande ni un
message : le scellement se relit par `./deploy.sh --verify` dans le dépôt du site.

La sixième, `GRAFANA_ADMIN_PASSWORD`, est la recopie du fichier brut scellé sous
`deploy/secrets/grafana-admin.sops.bin` (ligne `infra` du manifeste) :
`docker/grafana/secrets/admin_password`, que `prepare_logging` posait jusqu'ici
au hasard sur chaque machine. Il voyage désormais depuis le coffre, pour une seule
raison mesurée : une clé de compte de service appartient à la base Grafana qui
l'a émise, et rien en 13.3.0 OSS n'en fixe une d'avance (`provisioning/access`
n'est pas lu, `[security] admin_api_key` a disparu de `conf/defaults.ini`). Sur
une instance neuve, `export-grafana.mjs` sort donc 3 (« PAS DE CREDIT ») et le
conducteur appelle `tools/sync/bootstrap-grafana-sync-token.mjs --out …`, qui
crée le compte Viewer et écrit la clé dans le volume `dagu_data` — jamais
re-scellée, jamais affichée. L'administrateur ne sert qu'à cette fabrication :
`export-grafana.mjs` ne l'accepte plus même en repli, et une rotation du mot de
passe faite dans l'interface demande de re-sceller `grafana-admin` puis `ui-sync`,
dans cet ordre.

## La base Grafana est sauvegardée, elle aussi

Ce que l'IHM retouche vit dans `grafana.db`, et la synchro ci-dessus ne passe que
toutes les quinze minutes : entre deux passes, une retouche n'est nulle part.
`compose.yaml` monte donc le dossier seul — `${LOGGING_HOST_DATA_PATH}/grafana`,
jamais `/data/logging` en bloc, Loki et Prometheus restant hors du périmètre — et
`tools/backup/jobs.json` déclare le job « Fichiers - grafana » à 04:04. Mesuré le
2026-11-12 sur ce dossier : 579,7 Mio, dont 573,8 Mio sous `plugins/` que huit
montages parcourent sans jamais le lire ; le job l'exclut (`**/plugins/**`) et
archive les 5,2 Mio qui comptent.

Le montage est en lecture seule, encore faut-il que le conteneur puisse lire. Le
processus DBackup tourne avec `PGID=33` ; `prepare_logging` pose des fichiers que
Grafana détient en propre, d'où `open_grafana_data_to_backup` dans `deploy.sh` :
`chgrp 33` et `chmod g+rx` sur le dossier, `g+rX` sur son contenu, `plugins*`
laissés tranquilles puisqu'exclus.

Deux dérivations mesurées ce jour-là, toutes deux gardées dans le code :

- l'adaptateur SOURCE avait un `basePath` à `/backups` depuis le 2026-11-01. Les
  jobs de fichiers archivaient donc 0 octet en se disant « Success » — `files: 0`
  dans leur manifeste, sur les dix. `dbackup-bootstrap.mjs` compare désormais le
  `basePath` à ce que porte le montage et le corrige par `PUT` ; après correction,
  le job Grafana rend 5 fichiers pour 5,41 Mio.
- `docker compose up -d` joué à la main sur le poste ne publie pas `.env.local` :
  Compose n'interpole ses variables qu'auprès de son shell et du `.env` versionné,
  et `deploy.sh` fait le reste avec `export_machine_env`. Sauter cette étape remonte
  les replis du `.env` — des chemins de production — et la console archive un
  dossier vide sans erreur. Le `up -d` passe par `./deploy.sh`.

Reste, à jouer une fois par machine et non par le code : associer un profil de
chiffrement aux jobs (l'API ne le permet pas) et supprimer le job agrégé « Données
de l'application et volumes Docker », que les jobs par dossier remplacent.
L'amorçage le rappelle à chaque passe tant que ces deux états durent. C'est ainsi
que « Fichiers - logs » a été signalé puis retiré de la déclaration : un job effacé
dans l'IHM laisse son dossier d'archives derrière lui, que plus aucune rétention ne
purge.

