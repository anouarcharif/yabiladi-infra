# Maintenance

Monter une version, redescendre, lire les mesures, entendre ce que la pile ne fera
jamais.

## Ce qui vit où

| Objet | Nom | Qui le crée | Qui le détruit |
| --- | --- | --- | --- |
| volume des données Portainer | `yabiladi_portainer_data` | `scripts/deploy.sh` (et `../deploy.sh`, pour le montage `/backup`) | personne, jamais par un script de cette pile |
| réseau privé | `yabiladi_admin_internal` (`internal: true`) | Compose, à partir de `compose.yaml` | un `down` de cette pile uniquement |
| volume de copie avant rollback | `yabiladi_portainer_data_rollback` | `scripts/rollback.sh` | `rollback.sh` le recrée à chaque passe ; `docker volume rm` reste un geste humain |
| archive de sauvegarde | `/backups/portainer-volume-backup/chain-…/` | la console DBackup | la rétention de la console (`retention-gvs-default`) |

## Mesures réelles

Prises sur ce poste (Docker Desktop / WSL2, hôte de développement de 8 Go
d'équivalent, moteur 29.9.2) :

| Conteneur | Limite posée | Mémoire mesurée | CPU mesuré |
| --- | --- | --- | --- |
| `portainer` | 384M / 0.50 | 18 → 26 Mio | 0.00 % |
| `docker-socket-proxy` | 48M / 0.10 | 21.5 → 26 Mio | 0.00 → 2.2 % |
| `dozzle` | 128M / 0.25 | 12.9 → 14.7 Mio | **0.07 % au calme, 25 % sous chasse d'évènements** |
| **total** | 560M / 0.85 | **≈ 55 Mio, soit ~0,7 % des 8 Go** | — |

Le jeu final de `validate.sh --resources`, le 2026-11-12 au soir, rend le même
ordre de grandeur avec la charge d'évènements qui tournait encore : `portainer`
18,69 Mio / 0,00 %, `docker-socket-proxy` 23,25 Mio / 0,71 %, `dozzle` 19,88 Mio /
0,39 %, soit **≈ 62 Mio, ~0,8 % des 8 Go**. La dispersion d'un jeu à l'autre tient
toute aux fichiers journaux que Dozzle relit, pas à un état qui grossirait.

Le dernier chiffre mérite son explication, parce qu'il est le seul qui n'est pas
négligeable. Dozzle tient le flux `/events` ouvert pour ne pas avoir à sonder. Sur
une machine qui fait tourner des suites de tests, des sondes de santé toutes les
30 secondes et des DAGs Dagu, le flot d'évènements `exec_create` / `exec_start` /
`exec_die` est continu — mesuré ici : **43 évènements en 15 secondes**, tous des
`exec` d'autres conteneurs. À ce rythme Dozzle recalcule son inventaire sans
relâche et vient buter contre sa limite de 0,25 CPU, où il reste : il ne prend pas
plus, c'est exactement ce que la limite sert à faire. Sur une machine au repos, le
même conteneur est tombé à 0,07–0,12 %.

Trois conséquences exploitables :

1. **le plafond protège le serveur, pas l'interface** : sous chasse, la page de
   Dozzle peut devenir lente à se dessiner. Les journaux restent justes.
2. si la lenteur devient le problème un jour, l'escape-batoire existe dans
   l'outil : `--filter` (drapeau documenté dans `dozzle --help`) restreint
   l'inventaire aux conteneurs qui intéressent, donc les recalculs.
3. ne pas confondre ce 25 % avec une fuite : la mémoire, elle, ne bouge pas
   (12,9 → 14,7 Mio sur la soirée).

La sonde est dans la suite :

```bash
bash docker-admin/scripts/validate.sh --resources
```

## Monter une version

Les images sont épinglées par tag, jamais `latest` : un `latest` ferait évoluer la
liste des chemins autorisés du mandataire sans que personne ne l'ait décidé.

```bash
# 1. lire les tags réellement publiés, pas ceux qu'on croit connaître
bash docker-admin/scripts/rollback.sh --list
# 2. fixer la version visée dans le .env de la racine (ligne déjà commentée là-bas)
ADMIN_PORTAINER_IMAGE=portainer/portainer-ce:2.46.0-alpine
# 3. déployer, puis contrôler
bash docker-admin/scripts/deploy.sh && bash docker-admin/scripts/validate.sh
```

Avant une montée de Portainer, jouer une passe froide de la sauvegarde — le
schéma du fichier Bolt migre au démarrage, et c'est le seul objet de cette pile qui
ne se rejoue pas :

```bash
bash docker-admin/scripts/backup.sh --quiesce
```

## Redescendre

`scripts/rollback.sh` est écrit pour ça, et pour ne toucher qu'à cette pile :

```bash
bash docker-admin/scripts/rollback.sh --list                    # en service + tags publiés
bash docker-admin/scripts/rollback.sh --portainer 2.45.2-alpine  # avec copie préalable
bash docker-admin/scripts/rollback.sh --dozzle v11.4.1-alpine
bash docker-admin/scripts/rollback.sh --portainer 2.45.2-alpine --dry-run
```

Trois règles le distinguent d'un `up` avec un autre tag :

- **le volume est copié avant**, sur `yabiladi_portainer_data_rollback`. Une
  base migrée par une version plus récente n'est pas lue par une plus ancienne,
  et ce n'est pas réversible par la seule image.
- **un échec remet les deux en place** : si le service ne revient pas en santé,
  l'état laissé par la version qui a échoué est copié à son tour (jamais écrasé
  à l'aveugle), puis la copie saine est restaurée et l'image précédente relancée.
- **le tag ne s'invente pas** : la version en service est lue sur le conteneur
  vivant, les suggestions viennent du registre.

La rétrogradation n'est durable que si la ligne `ADMIN_*_IMAGE` est reportée dans
`.env` — le script l'affiche à la fin, parce que le contraire d'un rollback réussi
est un rollback effacé par le déploiement suivant.

## Redémarrer, arrêter, sans débordement

```bash
cd docker-admin
docker compose --env-file ../.env -f compose.yaml restart portainer
docker compose --env-file ../.env -f compose.yaml stop dozzle
```

Jamais `down -v` (le `-v` détruirait le volume des données), jamais
`docker system prune` sur la machine, jamais un `up` sur un autre projet que
celui-ci. Ces trois phrases sont la raison pour laquelle chaque script de ce
répertoire construit son `docker compose` avec `-f compose.yaml` explicite,
restreint au projet.

Un redémarrage de Portainer referme aussi sa fenêtre d'administrateur : cinq
minutes, voir installation.md. Il fait une autre chose, utile : son `entrypoint`
repose les droits du volume (`2750` sur les dossiers, `0640 root:33` sur les
fichiers, `umask 027` pour la suite). Un `docker compose restart portainer`
suffit donc à résorber une dérive — joué pour de vrai, après en avoir semé une à
la main, et le contrôle « aucun écart de droits sur /data » de `validate.sh` l'a
confirmé. C'est aussi pour ça qu'aucune tâche planifiée ne tourne pour ça : voir
`docs/backup-restore.md`.

## Ce que ces scripts ne feront jamais

- `git pull`, ni un déploiement d'un autre projet — chaque dépôt a son
  `deploy.sh`, et l'infra ne pilote pas le site, pas plus que l'inverse.
- redémarrer Traefik, Dagu, Grafana, la console de sauvegarde ou un conteneur
  applicatif. La seule recréation provoquée par ce travail, sur toute la pile, a
  été `dbackup` (pour son montage `/backup/portainer`) — un service de
  sauvegarde, pas une application.
- supprimer un volume, une archive, un job ou un adaptateur existant.
- écrire un mot de passe dans un fichier, une commande ou une sortie.

## Non-régression : comment lire le résultat

`validate.sh` termine par trois nombres. Le troisième — les contrôles non joués —
n'est pas un succès de complaisance : un contrôle qui n'a pas pu se jouer est écrit
comme tel, avec la raison. Les trois attendus sur ce poste : le chemin
authentifié (mot de passe hors du dépôt), le compte administrateur de Portainer
(à créer à la main), l'« Add host » de Dozzle (se lit, ne se ferme pas).

Un cas à ne pas mal lire : `https://www.yabiladi.com/ → 504` **pendant que la
ligne voisine dit que nginx répond en 0,2 s en direct**. Le témoin croisé est là
pour ça : le chemin d'accès est en cause, pas cette pile ni le site. Voir
troubleshooting.md, ligne « 504 sur un service existant après un recreate ».
