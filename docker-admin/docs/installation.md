# Installation

D'un dépôt fraîchement cloné à une console utilisable. Sur le serveur comme sur le
poste de développement, à une différence près, signalée en son temps.

## Ce qui doit déjà être en place

La pile suppose l'infrastructure déployée, parce qu'elle y emprunte trois choses
et n'en crée aucune :

| Emprunté | Où il est créé | Vérifié par |
| --- | --- | --- |
| le réseau `yabiladi_app` | `../compose.yaml` | `validate.sh`, « réseau « yabiladi_app » présent » |
| le fichier de comptes `/etc/traefik/htpasswd/user_yabiladi` monté dans Traefik | `../compose.yaml`, matérialisé par `../deploy.sh` depuis `deploy/secrets/htpasswd_user_yabiladi.sops.bin` | `validate.sh`, « le même fichier est lisible dans le conteneur Traefik » |
| la console de sauvegarde DBackup, pour le job de nuit | `../compose.yaml` | `validate.sh`, section « Sauvegarde » |

Le volume `yabiladi_portainer_data` est le seul objet que cette pile exige sans
le trouver : `scripts/deploy.sh` le crée s'il manque (`docker volume create` ne
touche jamais un volume existant), et `../deploy.sh` le pose aussi, car le service
`dbackup` le monte. Un `compose.yaml` qui démarre sur un volume absent refuse de
partir plutôt que d'en créer un neuf et vide — c'est voulu.

Ordre sur une machine neuve :

```bash
cd /opt/yabiladi-infra && ./deploy.sh          # l'infrastructure : Traefik, DBackup, Loki…
cd docker-admin && bash scripts/deploy.sh      # cette pile
```

## Le réglage de la machine

Deux lignes dans le `.env` **versionné** de la racine — c'est là que les quatre
projets lisent, et cette pile n'a pas son propre fichier d'environnement :

```
ADMIN_TZ=Europe/Paris
# ADMIN_PORTAINER_IMAGE=portainer/portainer-ce:2.45.3-alpine
# ADMIN_DOZZLE_IMAGE=amir20/dozzle:v11.4.2-alpine
```

Les deux lignes commentées ne servent qu'à **figer** une version : après un
rollback, ou pour attendre la prochaine mouture avant de la monter sur le
serveur. Absentes, c'est le défaut écrit dans `compose.yaml` qui s'applique.

Sur un poste de développement, un troisième fichier — ignoré par git — vide le
résolveur ACME, puisque ni Let's Encrypt ne peut joindre cette machine ni son
certificat ne couvre ces noms :

```bash
cp docker-admin/compose.override.yaml.example docker-admin/compose.override.yaml
```

C'est le même geste que pour `grafana`, `dbackup` et le tableau de bord Traefik.
Sans lui, le premier `up` reste bloqué sur une demande de certificat qui aboutira
de toute façon sur le serveur, pas ici.

## Déployer

```bash
bash docker-admin/scripts/deploy.sh            # puis, pour ne lire que la configuration :
bash docker-admin/scripts/deploy.sh --dry-run
```

Ce que la commande fait, dans l'ordre :

1. contrôle la présence du volume et du réseau, crée le volume si absent ;
2. `docker compose up -d` **sur les trois services de ce fichier** ;
3. attend la santé de chacun (`/_ping` du mandataire, `:9000/` de Portainer,
   `healthcheck` de Dozzle) ;
4. ouvre les droits du volume pour le groupe 33 de la console de sauvegarde,
   depuis le propre conteneur de Portainer ;
5. sonde les deux services en interne, puis depuis le réseau de Traefik.

Ce qu'elle ne fait pas : `git pull`, un `up` sur `../compose.yaml`, un redémarrage
de Traefik, de Dagu ou de la console. Traefik n'en a pas besoin : son fournisseur
Docker lit les évènements, et un routeur porté par un conteneur qui démarre
apparaît à la seconde.

## Le job de sauvegarde n'est pas créé ici

Il est déclaré une ligne plus haut que tout le monde, dans
`tools/backup/jobs.json` :

```json
{"name":"portainer-volume-backup","path":"portainer","label":"Sauvegarde quotidienne des données persistantes de Portainer CE.","schedule":"40 4 * * *"}
```

C'est `../deploy.sh` qui le pose dans la console, par
`tools/backup/dbackup-bootstrap.mjs` (idempotent : il crée ce qui manque, ne
déclare jamais un second adaptateur, ne réécrit pas un horaire changé à la souris).
Après avoir ajouté la ligne, le déploiement de l'infrastructure est donc requis :

```bash
cd /opt/yabiladi-infra && ./deploy.sh
```

Vérification, côté console, sans ouvrir l'interface :

```bash
docker compose exec -T dbackup node /opt/backup-tools/run-job.mjs --list | grep portainer
# · portainer-volume-backup  activé   schedule « 40 4 * * * »  dernière : Success le …
```

## Première visite : le compte administrateur de Portainer

C'est la seule étape qui ne se joue pas en script, et elle a une fenêtre.

Portainer refuse de démarrer sans compte administrateur et **l'offre pendant cinq
minutes** après chaque démarrage du conteneur. Passé ce délai, la racine répond
`307`, chaque appel d'API `303`, et l'interface reste close jusqu'à un
redémarrage (mesuré sur 2.45.3, et c'est bien `adminmonitor` qui l'écrit dans ses
journaux). Le mot de passe ne s'écrit donc ni dans ce dépôt, ni dans une ligne de
commande, ni dans un journal : il se frappe dans un navigateur.

```bash
# 1. rouvrir la fenêtre
cd /opt/yabiladi-infra/docker-admin
docker compose --env-file ../.env -f compose.yaml restart portainer
# 2. dans les cinq minutes : https://portainer.yabiladi.com  (compte basicauth, puis formulaire)
```

Sur le serveur, il faut aussi que les deux noms existent chez Cloudflare, en
**DNS only** (nuage gris) comme `dagu`, `grafana`, `backups`, `traefik` et
`navidrome` : la liste d'adresses compare l'adresse du pair TCP, et un passage par
le réseau de Cloudflare la ferait juger une sortie de datacenter partagée avec des
millions de visiteurs.

## Contrôler

```bash
bash docker-admin/scripts/validate.sh --resources
```

Lecture seule de bout en bout. Le script se termine par le compte des réussites,
des échecs et **des contrôles non jouables** — un contrôle qui n'a pas pu se jouer
n'est pas un contrôle réussi. Sur ce poste, le 2026-11-12 : 68 réussites, 0 échec,
3 non joués, les trois étant volontairement hors de portée d'un script — le chemin
authentifié (il faudrait le mot de passe), le compte administrateur de Portainer
(à créer à la main, ci-dessus) et l'« Add host » de Dozzle, qui se lit mais ne se
referme pas depuis l'image (voir docs/security.md).

Pour jouer quand même le chemin authentifié, un opérateur qui tient le mot de
passe peut passer deux variables dans son environnement — jamais dans un fichier :

```bash
ADMIN_TEST_USER=yabiladi ADMIN_TEST_PASSWORD='…' bash docker-admin/scripts/validate.sh
```
