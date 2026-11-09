# Yabiladi-Infra

Infrastructure commune de la pile : Traefik, Postfix, geoipupdate, DBackup,
Loki/Alloy/Grafana, Prometheus/node_exporter/cAdvisor. Se déploie en premier
(`git pull` puis `./deploy.sh`), chaque projet — site, facturation, médiakit —
tenant ensuite ses propres conteneurs avec son propre script. Ordre complet,
chemins attendus sur la machine et migration des volumes et réseaux existants :
[MIGRATION.md](../MIGRATION.md).
