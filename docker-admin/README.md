# docker-admin — l'administration de Docker et la lecture des journaux

Deux interfaces, trois conteneurs, un seul dépôt : celui de l'infrastructure.
Portainer répond à « qu'est-ce qui tourne, et je le change comment ? », Dozzle à
« que dit ce conteneur, maintenant ? ». Ni l'une ni l'autre ne remplace ce qui
existe déjà : Loki et Grafana gardent l'historique sur trente jours, Dagu garde
l'ordonnancement, et `deploy.sh` de chaque projet garde la main sur ses conteneurs.

La pile est indépendante : son `compose.yaml`, ses scripts, son volume. Elle se
déploie sans toucher aux trois projets applicatifs, et aucun de ses scripts ne
pilote autre chose qu'elle-même.

## Ce qui tourne

| Service | Image (épinglée) | Rôle | Socket Docker |
| --- | --- | --- | --- |
| `portainer` | `portainer/portainer-ce:2.45.3-alpine` | administration complète de l'hôte | montée en **écriture** |
| `docker-socket-proxy` | `tecnativa/docker-socket-proxy:v0.5.0` | filtre devant la socket pour Dozzle | montée en **lecture seule**, et rien ne passe sans y être nommé |
| `dozzle` | `amir20/dozzle:v11.4.2-alpine` | journaux temps réel | **aucune** — elle parle au mandataire |

Les variantes `-alpine` sont un choix mesuré, pas un goût : à partir de 2.45,
l'image standard de Portainer est sans shell — donc sans sonde de santé possible,
et sans moyen d'ouvrir les droits de son volume à la console de sauvegarde, ni à
l'installation ni par son propre `entrypoint`.

## Où ça s'ouvre

| Adresse | Derrière |
| --- | --- |
| `https://portainer.yabiladi.com` | plage d'adresses `DAGU_ALLOWED_IPS`, puis le compte basicauth de Dagu, puis le compte administrateur propre à Portainer |
| `https://logs.yabiladi.com` | plage d'adresses, puis le même compte basicauth |

Aucun des trois conteneurs ne publie de port sur l'hôte (vérifié par
`scripts/validate.sh` : « aucun port publié sur l'hôte », trois fois). Le seul
chemin jusqu'à eux passe par Traefik, l'unique proxy de la machine.

Le fichier de comptes est celui des cinq autres interfaces d'administration
(`docker/traefik/htpasswd/user_yabiladi`, matérialisé depuis le coffre) : mêmes
identifiants partout, aucun mot de passe de plus à connaître, aucune copie de
hash à maintenir. Les deux barrières ajoutées — liste d'adresses puis compte —
sont exactement celles de Grafana, dans le même ordre.

## Comment on agit dessus

```bash
bash docker-admin/scripts/deploy.sh      # déployer ou mettre à jour CETTE pile, et elle seule
bash docker-admin/scripts/validate.sh    # 77 contrôles, lecture seule, code de sortie qui dit vrai
bash docker-admin/scripts/backup.sh      # sauvegarder les données de Portainer maintenant, et le prouver
bash docker-admin/scripts/rollback.sh --list   # versions en service et tags publiés, avant de rétrograder
```

Chacun rend `--help`. Aucun ne fait `git pull`, aucun ne redémarre Traefik,
aucun n'appelle `docker system prune`, aucun ne touche un conteneur d'un autre
projet.

`../deploy.sh` — celui de l'infrastructure — enchaîne le premier à la fin de son
parcours : un seul geste le jour de la mise en production. Rien ici ne pilote
l'inverse, et le script reste jouable seul.

## Sauvegarde

Le volume `yabiladi_portainer_data` est monté en lecture seule sous
`/backup/portainer` dans le conteneur de la console DBackup, et le job
`portainer-volume-backup` (planification `40 4 * * *`, la dernière minute libre
de la série du matin) l'archive chaque nuit. Le pourquoi du montage plutôt que
du connecteur « volume Docker » de la console, le rituel des droits et la
procédure de restauration jouée pour de vrai sont dans
[docs/backup-restore.md](docs/backup-restore.md).

## Documentation

- [docs/installation.md](docs/installation.md) — d'un dépôt vierge à la console ouverte, premier compte compris.
- [docs/security.md](docs/security.md) — ce qui protège quoi, et ce qui reste ouvert.
- [docs/maintenance.md](docs/maintenance.md) — montée de version, rollback, mesures réelles de CPU et de RAM.
- [docs/backup-restore.md](docs/backup-restore.md) — le job, l'archive, la restauration.
- [docs/troubleshooting.md](docs/troubleshooting.md) — symptôme, cause mesurée, remède.
