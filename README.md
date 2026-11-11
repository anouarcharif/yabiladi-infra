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
cinq variables — dont le couple de promotion administrateur de DBackup, lu par
l'export à chaque passe — ne passent par un journal, une ligne de commande ni un
message : le scellement se relit par `./deploy.sh --verify` dans le dépôt du site.

