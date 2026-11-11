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

