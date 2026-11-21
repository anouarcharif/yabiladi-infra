# Maintenance de Komodo

## Conteneurs et volumes

| Service | Rôle | Données persistantes |
| --- | --- | --- |
| `komodo-core` | API et interface web | clés sous `yabiladi_komodo_keys` |
| `komodo-mongo` | base Komodo | `yabiladi_komodo_mongo_data`, `yabiladi_komodo_mongo_config` |
| `komodo-periphery` | accès Docker et collecte sur le nœud | clé partagée avec Core |

`yabiladi_komodo_backups` contient les sauvegardes générées par Komodo. DBackup
le monte en lecture seule. Ces volumes sont externes ; le déploiement ne les
supprime jamais. Ne pas utiliser `docker compose down -v` pour mettre à jour
Komodo.

## Mettre à jour

Les images sont épinglées dans `docker-admin/compose.yaml`. Après avoir changé
un tag :

```bash
bash docker-admin/scripts/deploy.sh --dry-run
bash docker-admin/scripts/deploy.sh
bash docker-admin/scripts/validate.sh
```

Le déploiement racine met aussi à jour l'infrastructure et matérialise les
secrets avant d'enchaîner docker-admin. Le script docker-admin autonome ne fait
pas de `git pull` et ne redémarre pas les services d'un autre projet.

## Mesures et journaux

Komodo affiche les journaux et mesures des conteneurs via Periphery. La collecte
CPU/mémoire est réglée à cinq secondes avec
`PERIPHERY_CONTAINER_STATS_POLLING_RATE`. Les statistiques système du Periphery
restent à leur valeur par défaut Komodo (cinq secondes).

Periphery utilise la socket Docker de l'hôte pour l'administration. Les
terminaux hôte et conteneur sont désactivés dans Compose ; ne pas exposer le
port du Periphery ou le socket Docker sur un réseau externe.

## Migration depuis l'ancien projet infra

`docker-admin/scripts/deploy.sh` retire uniquement les anciens conteneurs
Komodo étiquetés avec le projet `yabiladi-infra`, puis crée les mêmes services
sous `yabiladi-docker-admin`. Les volumes existants ne sont ni recréés ni
effacés. `docker compose up --remove-orphans` dans le projet docker-admin retire
Dozzle et `docker-socket-proxy`, remplacés par les fonctions de journaux et de
mesure de Komodo.
