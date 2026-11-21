# Dépannage Komodo

## Komodo répond 404

Traefik accepte `komodo-imouzzer.yabiladi.com` et `komodo.yabiladi.com`.
En local, les deux noms pointent vers le poste, et l'URL canonique est
`komodo.yabiladi.com` :

```text
127.0.0.1 komodo-imouzzer.yabiladi.com komodo.yabiladi.com
```

Vérifier le nom configuré par `deploy/node-profile.sh` et le label du Core :

```bash
docker inspect --format '{{ index .Config.Labels "traefik.http.routers.komodo.rule" }}' \
  "$(docker ps -q --filter label=com.docker.compose.service=komodo-core | head -1)"
```

Un nom qui n'est pas dans la règle retourne la page Traefik 404, même si le
Core et Traefik fonctionnent. Sur Imouzzer, vérifier aussi que le DNS des deux
noms pointe vers le serveur.

## Le Core ne démarre pas

Sur Imouzzer, le Core attend le secret `docker/legacy/komodo.env`, matérialisé
par le déploiement racine. Lire les journaux sans afficher le fichier secret :

```bash
docker compose --env-file ../.env -f docker-admin/compose.yaml logs --tail 80 komodo-core
docker compose --env-file ../.env -f docker-admin/compose.yaml logs --tail 80 komodo-mongo
```

Ne pas supprimer les volumes `yabiladi_komodo_mongo_data`,
`yabiladi_komodo_mongo_config` ou `yabiladi_komodo_keys` pour tenter une
réparation : ils contiennent l'état du Core et ses clés.

## Periphery n'est pas connectée

Tarourt utilise une connexion sortante vers
`wss://komodo-imouzzer.yabiladi.com`. Vérifier le DNS et la disponibilité du
Core sur Imouzzer, puis consulter :

```bash
docker compose --env-file ../.env -f compose.yaml logs --tail 80 komodo-periphery
```

Le déploiement docker-admin crée et vérifie automatiquement une clé
d'onboarding privilégiée via l'API du Core, avec les identifiants
`KOMODO_INIT_ADMIN_USERNAME` et `KOMODO_INIT_ADMIN_PASSWORD` du secret
matérialisé. Aucune création ni acceptation dans l'interface n'est requise.

La clé privée est stockée sur chaque nœud dans
`docker/legacy/komodo-onboarding-<nœud>.key` avec le mode `0600` sur Linux ou
une ACL limitée au compte courant sur Windows; elle est ignorée par Git et
n'est pas écrasée par la matérialisation SOPS. Si son entrée est révoquée dans
Core, le prochain déploiement la réenregistre. Ne pas supprimer ces fichiers sur
un nœud actif, ni copier leur contenu dans un ticket ou un journal.

Periphery lit la clé publique de Core dans `file:/config/keys/core.pub`. Sur
Tarourt, la première connexion TLS sortante l'épingle automatiquement dans le
volume local `komodo_keys`. Si les journaux indiquent que la clé publique de
Core est invalide, vérifier que `PERIPHERY_CORE_PUBLIC_KEYS` pointe vers ce
fichier, puis relancer `docker-admin/scripts/deploy.sh`. En cas d'échec du
bootstrap, vérifier que les identifiants admin sont présents dans le secret
sans afficher ce fichier, puis consulter les journaux du Core et du Periphery.

## Les mesures ou journaux ne s'actualisent pas

Komodo récupère les journaux et mesures via Periphery. La configuration fixe
`PERIPHERY_CONTAINER_STATS_POLLING_RATE=5-sec`. Vérifier que le Periphery est
connecté dans l'interface et qu'il tourne :

```bash
docker ps --filter label=com.docker.compose.project=yabiladi-docker-admin
docker compose --env-file ../.env -f compose.yaml logs --tail 80 komodo-periphery
```

Le service monte le socket Docker pour ces fonctions ; un Periphery non
connecté ou sans accès à cette socket ne peut ni lister les conteneurs ni
collecter leurs mesures.

## Komodo reste dans l'ancien projet Compose

Le déploiement docker-admin retire précisément les anciens conteneurs
`komodo-core`, `komodo-mongo` et `komodo-periphery` étiquetés
`yabiladi-infra`, puis les recrée sous `yabiladi-docker-admin`. Les volumes
externes restent les mêmes. Vérifier les projets :

```bash
docker ps -a --filter label=com.docker.compose.service=komodo-core \
  --format '{{.Names}} {{.Label "com.docker.compose.project"}}'
```
