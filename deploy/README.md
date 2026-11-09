# Coffre à secrets du dépôt

**But** : qu'un `git pull` sur le serveur suffise à déployer, secrets compris, sans qu'aucune
valeur ne soit lisible dans git ni dans son historique.

Ce n'est pas un coffre-fort réseau. C'est un fichier chiffré commité, et une seule clé privée
hors du dépôt. Les trois propriétés qui comptent : le dépôt cloné sans la clé ne donne **rien**
d'exploitable ; un `git log -p` ne montre jamais une valeur ; la rotation d'un secret est un
commit, et `git pull` le diffuse.

## Ce qui est dedans

| Bloc chiffré (versionné)                     | Posé sur la machine                 | Qui le lit                                    |
|----------------------------------------------|-------------------------------------|-----------------------------------------------|
| `deploy/secrets/env.local.sops.bin`          | `.env.local` (0644)                 | Symfony (Dotenv), dans le conteneur php       |
| `deploy/secrets/credentials.sops.bin`        | `docker/legacy/credentials.env` (0600) | démon docker, via `env_file` des services  |
| `deploy/secrets/dbackup.sops.bin`            | `docker/legacy/dbackup.env` (0600)    | démon docker (`env_file` du service `dbackup`) — clés internes de la console et compte admin |
| `deploy/secrets/htpasswd_user_yabiladi.sops.bin` | `docker/traefik/htpasswd/user_yabiladi` (0600) | Traefik (`basicauth` de dagu, grafana, dbackup, tableau de bord) |
| `deploy/secrets/htpasswd_rac.sops.bin`       | `docker/traefik/htpasswd/rac` (0600) | Traefik (`basicauth` du routeur `rac`)     |
| `deploy/secrets/facturation.env.sops.bin`    | `docker/facturation/.env.local` (0644) | Symfony, dans le conteneur `facturation-php` — **optionnel** tant qu'il n'est pas scellé (colonne 7 du manifeste) |

Les noms de variables de chaque bloc sont documentés dans `deploy/secrets/env.local.example`,
`docker/facturation/.env.local.example` et
`docker/legacy/credentials.env.example` — les blobs étant chiffrés en mode binaire, c'est là
qu'on lit ce que contient le coffre. Les comptes htpasswd n'ont pas de variables : leur forme
(`nom:<hash bcrypt>`) est dans `docker/traefik/htpasswd/*.example`, qui restent versionnés alors
que le clair est hors git.

**Volontairement dehors** (et pourquoi) : `deploy/secrets.manifest`, section finale — mot de passe
admin Grafana (regénéré sur la machine, sans effet après l'initialisation de la base), clé DKIM
(montée depuis `/etc/opendkim/keys` du V1), `compose.override.yaml` (configuration par machine,
aucun secret dedans).

## Une machine neuve : une seule opération, une seule fois

```bash
# 1. cloner et équiper
git clone <dépôt> && cd Yabiladi-V2-Symfony
cp compose.override.yaml.example compose.override.yaml   # puis l'éditer : c'est le seul fichier par machine

# 2. poser la clé privée age (le seul objet qui n'est pas dans git)
install -d -m 700 /root/.config/age
# copier keys.txt dedans, puis :
chmod 600 /root/.config/age/keys.txt

# 3. déployer
bash deploy.sh --build
```

Sans la clé, `deploy.sh` s'arrête sur un message explicite et **ne touche à aucun fichier déjà
en place** (vérifié avec un `HOME` vidé et avec une clé d'une autre machine).

## Chaque projet a son point d'entrée

Chaque dépôt a son `deploy.sh` autonome. Celui de la pile ne touche qu'à la pile : il ne tire
pas les dépôts voisins, ne matérialise pas leurs secrets et ne crée ni ne recrée leurs
conteneurs — les deux applications vivent sous leur propre profil Compose, activé par leur
seul script.

| Depuis | Ce qui est déployé |
|---|---|
| `Yabiladi-V2-Symfony/` | site principal, forum, radio, Traefik, journalisation, console de sauvegarde |
| `Yabiladi-Mediakit-V2/` | `pub.yabiladi.com` : secret, dossiers, `mediakit-php`/`-nginx`, cache, PDF, contrôles |
| `Yabiladi-Facturation-V2/` | `ws.yabiladi.com` : secret, dossiers, `facturation-php`/`-nginx`, cache, contrôles |

```bash
cd ../Yabiladi-Mediakit-V2 && bash deploy.sh          # médiakit seulement
cd ../Yabiladi-Facturation-V2 && bash deploy.sh       # intranet seulement
cd ../Yabiladi-V2-Symfony && bash deploy.sh           # pile seulement
```

Les trois acceptent `--build` et `--secrets`. Chacun ne matérialise que ses propres blocs du
coffre : la pile restreint `SECRETS_ONLY` aux entrées du site et de l'infrastructure, chaque
application au sien. La pile est attendue à côté du dépôt applicatif ; `YABILADI_STACK_DIR`
désigne un autre emplacement.

## Faire tourner un secret

```bash
nano .env.local                    # ou docker/legacy/credentials.env
bash deploy.sh --encrypt           # chiffre, relit, compare octet pour octet, puis remplace le bloc
bash deploy.sh --verify            # preuve que le coffre rend bien le clair
git add deploy/secrets && git commit -m "chore(secrets): rotation <quoi> — <pourquoi>"
git push
```

Sur le serveur : `bash deploy.sh`. Le service dont l'`env_file` a changé est recréé par
`docker compose up -d` seul — mesuré : une variable ajoutée à `credentials.env` change le hash
de configuration du service `php`. Pour un secret d'application (facturation, médiakit), les
mêmes commandes se lancent depuis son dépôt : c'est lui qui restreint le coffre à son bloc.

Les comptes htpasswd tournent autrement : leur contenu n'entre dans aucun label, donc le hash de
configuration de Traefik ne bouge pas et `up -d` ne recrée pas le proxy — alors que Traefik charge
le `usersfile` à la construction du middleware, pas à la requête. `deploy.sh` compare donc
l'empreinte des fichiers avant et après la matérialisation et redémarre Traefik si elle a changé
(mesuré le 2026-11-01 : compte ajouté au fichier en place → encore `401` ; après restart → `200`,
et `401` avec un mauvais mot de passe).

## Comment ça marche, et les pièges mesurés

* **SOPS + Age**, dans une image construite par le dépôt (`docker/secrets/Dockerfile`). Debian 12
  fournit `age` mais **pas** `sops` : installer l'outil à la main sur le serveur rendrait un
  déploiement dépendant d'un miroir. Le binaire sops est épinglé par sa somme sha256, vérifiée à
  la construction.
* Le conteneur qui déchiffre tourne avec `--network none` : cette étape n'a besoin d'aucun réseau,
  et c'est la seule garantie mesurable qu'aucune valeur déchiffrée ne peut sortir de la machine.
* **`--filename-override` est obligatoire**, dans les deux sens. SOPS dérive le format *et* la
  règle de création de `.sops.yaml` du **nom du fichier** : chiffrer `.env.local` tout seul répond
  « no matching creation rules found », et déchiffrer un fichier temporaire répond une erreur de
  parseur même avec `--input-type` (testé). C'est donc le nom du bloc dans `deploy/secrets/` qui
  décide qui peut relire.
* **Modes et groupes ne sont pas décoratifs** : `.env.local` en 0600 root:root = écran blanc, car
  php-fpm le lit en `www-data` dans le conteneur. D'où la pose en racine **dans** le conteneur
  (Linux réel), jamais depuis l'hôte de dev (un bind mount Windows rend de faux droits).
* **`install` ne marche pas sur un bind mount Docker Desktop** (« File exists » alors que le
  fichier cible a été supprimé) ; `mv` + `chmod` + `chgrp` marche, et le `chgrp 472` a été
  vérifié effectif.
* **Le cache se vide en `www-data`, jamais en root.** `docker compose exec php bin/console
  cache:clear` tourne sous root (l'utilisateur par défaut du conteneur) et grave des fichiers
  `root:www-data` dans `var/cache/dev` ; le premier visitor qui suit répond alors « Unable to
  write in the "cache" directory », un 500 observé sur ce poste après un tel nettoyage. La
  commande porte donc `--user www-data`.
* **`--env=prod` n'est pas la vérité d'une machine.** Le `.env` versionné dit `APP_ENV=dev`,
  `APP_DEBUG=1`, et rien dans le dépôt ne dit au serveur d'être autre chose que ce que sa machine
  déclare (`APP_ENV` dans le `.env.local` scellé, ou la variable d'environnement du conteneur).
  Vider le cache d'un environnement que l'application n'utilise pas laisse croire au rafraîchissement
  sans le produire. `deploy.sh` vide l'environnement résolu et **l'affiche** avant le contrôle HTTP.

## Perdre la clé

Sans `/root/.config/age/keys.txt`, le coffre est une brique d'octets inutilisables : c'est le
principe, pas un bug. C'est pourquoi la clé privée vit aussi dans un espace de stockage chiffré
hors du poste (coffre de mots de passe), et pourquoi `deploy.sh` refuse d'aller plus tôt plutôt
que de poser des fichiers vides.

**Clé perdue de façon définitive** : la procédure est celle d'une machine neuve.

```bash
# 1. paire neuve
docker run --rm --entrypoint age-keygen yabiladi/secrets:1 -o /tmp/keys.txt
# 2. publier la clé publique (la ligne « # public key: ») dans .sops.yaml
# 3. re-sceller depuis une machine qui tient encore les clairs — le serveur de production,
#    ou le poste de dev :
bash deploy.sh --encrypt
```

**Clé volée mais toujours valide** : les secrets eux-mêmes ne sont pas compromis par la clé
d'une machine perdue, et rien n'oblige à les changer. On remplace seulement la liste des
destinataires age dans `.sops.yaml`, puis `bash deploy.sh --encrypt` re-chiffre tout le coffre.

**Secret compromis** (un mot de passe lu à l'écran, un ex-employé, une fuite V1) : éditer le
fichier clair, `bash deploy.sh --encrypt`, commit, et le `git push` + `git pull` font le reste.
C'est la raison d'être du montage : la rotation ne demande plus d'accéder au serveur.
