#!/usr/bin/env bash
#
# Déploiement de l'infrastructure commune : proxy (Traefik), relais SMTP
# (Postfix), géolocalisation (geoipupdate), console de sauvegarde (DBackup) et
# les deux piles de mesure (Loki/Alloy/Grafana, Prometheus/node_exporter/cAdvisor).
#
# Ce script ne pilote AUCUN autre projet. Il ne fait le « git pull » de personne
# d'autre, ne démarre pas le site, la facturation, le médiakit, la radio ou Dagu,
# et ne contrôle aucune URL d'application. L'ordre d'implantation sur une machine
# neuve est : ici d'abord (réseaux, proxy, coffre), puis « ./deploy.sh » dans
# chaque dépôt d'application — chacun tirant son propre code et ses propres
# conteneurs.
#
# Ce que ce dépôt fournit aux autres, et donc ce qu'il doit tenir avant eux :
#   - les réseaux yabiladi_app et yabiladi_logging, qu'il crée lui-même (les
#     projets les déclarent « external » et échoueraient sinon) ;
#   - l'image yabiladi/secrets:1, que les deploy.sh des projets réutilisent ;
#   - le coffre SOPS (deploy/secrets/, deploy/secrets.manifest, deploy/secrets.sh),
#     d'où la colonne « project » qui dit à qui appartient chaque entrée.
#
# Aucune valeur de secret n'est jamais demandée, affichée ni stockée ailleurs que
# dans le coffre chiffré du dépôt. Le seul objet hors dépôt est la clé age privée,
# posée une fois pour toutes en /root/.config/age/keys.txt.
#
# Why `--network none` sur le conteneur qui déchiffre : cette étape n'a besoin
# d'aucun réseau. La coupure est la seule garantie mesurable qu'aucune valeur
# déchiffrée ne peut quitter la machine par un binaire qu'on ne relit pas.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO"

# Nom du projet dans la table du coffre (deploy/secrets.manifest, colonne 8).
# Un « deploy.sh » qui appelle deploy/secrets.sh passe le sien : « site »,
# « facturation », « mediakit ». Rien ici ne déchiffre un secret d'application —
# la ligne « site » du manifeste est matérialisée par le script du site.
TARGET_PROJECT="${TARGET_PROJECT:-infra}"

AGE_KEY_FILE="${AGE_KEY_FILE:-$HOME/.config/age/keys.txt}"
SECRETS_IMAGE="${SECRETS_IMAGE:-yabiladi/secrets:1}"

# Git Bash transforme /w en W:/ dans les arguments passés à docker.
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

log() { printf '%s\n' "$*"; }
die() { printf 'ERREUR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Déploiement de l'infrastructure commune : Traefik, Postfix, geoipupdate,
DBackup, Loki/Alloy/Grafana, Prometheus/node_exporter/cAdvisor.

  ./deploy.sh                  pull + secrets + dossiers + up -d + contrôles infra
  ./deploy.sh --build          idem, en rebuildant les images (docker/postfix,
                               docker/secrets modifiés)
  ./deploy.sh --secrets        re-matérialise seul les entrées du coffre dont la
                               colonne « project » vaut « infra »
  ./deploy.sh --encrypt        poste de dev : chiffre les clairs vers deploy/secrets/
  ./deploy.sh --verify         poste de dev : round-trip octet pour octet, sans rien écrire

TARGET_PROJECT=<nom> fixe le projet dont on relit les secrets (par défaut « infra »).
TARGET_PROJECT_DIR=<chemin d'hôte> désigne le dépôt de ce projet, pour « --encrypt »
et « --verify » d'un projet qui n'est pas celui-ci : le dépôt se monte en /app et le
coffre y écrit (et y relit) les clairs. Exemple, sceller une entrée du site depuis ce
dépôt :
  TARGET_PROJECT=site TARGET_PROJECT_DIR=../Yabiladi-V2-Symfony \
    SECRETS_ONLY=ui-sync ./deploy.sh --encrypt
SECRETS_ONLY=<fragment[,fragment]> restreint encore la liste aux entrées dont le
chemin contient l'un des fragments — c'est l'ancienne façon de faire, gardée pour
la rotation ciblée d'une seule entrée (« SECRETS_ONLY=htpasswd » par exemple).
USAGE
}

# --- Utilitaires de chemin et d'environnement -------------------------------

host_path() { # chemin lisible par le demon, selon l'hote
    if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

env_value() { # $1 clé, $2 défaut — même source que « docker compose » : .env
    local raw
    raw="$(sed -n "s/^$1=//p" "$REPO/.env" | tail -1)"
    raw="${raw%\"}"; raw="${raw#\"}"
    printf '%s' "${raw:-$2}"
}

# Valeur effective d'une clé de composition, dans l'ordre de priorité réel de
# Docker Compose : environnement du shell, puis .env versionné. « env_value » ne
# lit que .env ; s'en contenter ferait préparer ici un dossier différent de celui
# que le service monte réellement sur le serveur.
#
# .env.local n'est PAS dans cette liste : Compose n'interpole « ${CLE} » qu'à
# partir de son shell et du .env placé à côté de son fichier (mesuré : une clé
# posée dans .env.local laisse « docker compose config » rendu sur la valeur de
# .env, et le schéma de la 5.6.1 refuse un « env_file » de premier niveau qui
# l'y autoriserait). C'est « export_machine_env » ci-dessous qui donne au
# fichier machine son effet sur les montages, en publiant ses clés au shell.
compose_value() { # $1 clé, $2 défaut
    local raw
    [ -n "${!1:-}" ] && { printf '%s' "${!1}"; return; }
    if [ -f "$REPO/.env.local" ]; then
        raw="$(sed -n "s/^$1=//p" "$REPO/.env.local" | tail -1)"
        raw="${raw%\"}"; raw="${raw#\"}"
        [ -n "$raw" ] && { printf '%s' "$raw"; return; }
    fi
    env_value "$1" "$2"
}

# Publier au shell les clés du fichier propre à la machine, pour que Compose
# les voie. C'est la seule voie qui existe : l'ordre réel d'interpolation de
# Compose est « shell, puis .env » (mesuré, et son schéma refuse un
# « env_file » de premier niveau). Sans ce bloc, le serveur qui déclarerait
# DBACKUP_DEST_HOST_PATH, SITE_MEDIA_HOST_PATH ou LOGGING_HOST_DATA_PATH dans
# son .env.local monterait les replis du .env versionné — et
# « prepare_backups » irait préparer des dossiers que personne ne regarde.
#
# Lecture ligne à ligne, jamais « source » : une valeur de DSN contient « ? »,
# « # », des « & » et des guillemets ; le shell l'évaluerait ou casserait sur
# elle. Seule la forme « CLE=valeur » est retenue, débarrassée de ses
# guillemets comme le fait « compose_value » — les deux calculs doivent tomber
# d'accord, c'est tout l'objet de ce bloc.
export_machine_env() {
    [ -f "$REPO/.env.local" ] || return 0
    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in '' | \#*) continue ;; esac
        [ "$line" != "${line%%=*}" ] || continue
        key="${line%%=*}"
        value="${line#*=}"
        value="${value%\"}"; value="${value#\"}"
        # « export » refuse un nom bancal ; « set -e » aurait sinon tué le
        # déploiement sur la première ligne de commentaire particulière.
        case "$key" in [0-9]* | *[!A-Za-z0-9_]*) continue ;; esac
        [ -n "$key" ] || continue
        [ -z "${!key:-}" ] || continue
        export "$key=$value" >/dev/null 2>&1 || continue
    done < "$REPO/.env.local"
}

# --- Coffre de secrets -------------------------------------------------------

# Le conteneur qui déchiffre monte CE dépôt en /w : c'est là que vivent le
# manifeste, les blocs chiffrés et deploy/secrets.sh. Le dépôt de l'application
# concernée, quand ce n'est pas celui-ci, est monté en plus sous /app : la même
# table du coffre sert aux quatre projets, chaque deploy.sh n'en déploie que les
# lignes qui sont les siennes. L'appelant désigne ce dépôt par TARGET_PROJECT_DIR,
# en chemin d'hôte ; le conteneur ne le voit jamais que sous /app.
run_secrets_tool() { # $@ = verbe du conteneur
    [ -f "$AGE_KEY_FILE" ] || die "clé age introuvable: $AGE_KEY_FILE
Ce serveur (ou ce poste) ne peut pas lire le coffre. Une seule façon de le lui
faire : poser la clé privée age à ce chemin, en 0600. Elle n'existe que dans
l'espace de stockage chiffré où vous l'avez gardée."
    local montages=(-v "$(host_path "$AGE_KEY_FILE"):/keys/keys.txt:ro"
                    -v "$(host_path "$REPO")":/w)
    # Le dépôt d'un autre projet n'est monté que si ce script en déploie un :
    # « --encrypt »/« --verify » sur « infra » n'ont rien à écrire ailleurs.
    #
    # TARGET_PROJECT_DIR a DEUX sens selon celui qui la pose, et c'est ici qu'ils
    # se séparent : pour l'appelant, un CHEMIN D'HÔTE (c'est le « -v » qui en a
    # besoin) ; pour deploy/secrets.sh, le CHEMIN DANS LE CONTENEUR, toujours /app
    # puisque c'est là que le montage atterrit. Confondre les deux rendait
    # l'encryption croisée impossible : mesuré le 2026-11-11, « TARGET_PROJECT=site
    # TARGET_PROJECT_DIR=/c/Yabiladi_Upgrade/Yabiladi-V2-Symfony ./deploy.sh
    # --encrypt » montait bien le dépôt en /app mais faisait chercher au coffre le
    # même chemin dans le conteneur, d'où « le dépôt du projet « site » n'est pas
    # monté (… introuvable dans le conteneur) ». Le site, lui, pose déjà /app : son
    # « -v » et son « -e » sont deux lignes séparées (deploy.sh du site, fonction
    # materialize_secrets) — le contrat est donc respecté ici plutôt que subi.
    local cible_conteneur=/w
    if [ -n "${TARGET_PROJECT_DIR:-}" ]; then
        montages+=(-v "$(host_path "$TARGET_PROJECT_DIR"):/app")
        cible_conteneur=/app
    fi
    docker run --rm --network none \
        "${montages[@]}" \
        -w /w \
        -e SOPS_AGE_KEY_FILE=/keys/keys.txt \
        -e TARGET_PROJECT="$TARGET_PROJECT" \
        -e TARGET_PROJECT_DIR="$cible_conteneur" \
        -e SECRETS_ONLY="${SECRETS_ONLY:-}" \
        --entrypoint bash "$SECRETS_IMAGE" /w/deploy/secrets.sh "$@"
}

# L'image du coffre se construit ici, et une seule fois : les deploy.sh des
# projets réutilisent « yabiladi/secrets:1 » sans la rebuild (ils ne montent que
# leur dépôt et le dépôt d'infra). Le Dockerfile est court mais télécharge sops
# et vérifie son empreinte sha256 — c'est le seul prérequis réseau du déploiement.
build_secrets_image() {
    docker build -q -t "$SECRETS_IMAGE" docker/secrets >/dev/null
}

# --- Comptes basicauth Traefik ----------------------------------------------

# Empreinte des comptes basicauth Traefik, hors les gabarits *.example.
hta_fingerprint() {
    find docker/traefik/htpasswd -maxdepth 1 -type f ! -name '*.example' -exec cat {} + 2>/dev/null | md5sum
}

# Traefik charge le « basicauth.usersfile » à la construction du middleware, pas à
# la requête. Mesuré le 2026-11-01 : un compte ajouté au fichier en place rend
# toujours 401 ; après « docker compose restart traefik », le même compte passe à
# 200 et un mauvais mot de passe reste à 401. Or un fichier reposé par le coffre ne
# change aucun label : le hash de configuration du service ne bouge pas, donc
# « up -d » ne recrée pas le proxy. Sans cette reprise, une rotation déployée
# n'aurait aucun effet sur un serveur qui ne fait que « up -d ».
reapply_htpasswd() { # $1 = empreinte relevée avant la matérialisation
    local now
    now="$(hta_fingerprint)"
    [ "$now" != "$1" ] || return 0
    if docker compose restart traefik >/dev/null 2>&1; then
        log "     comptes basicauth modifiés : Traefik redémarré (le fichier se charge à la config)"
    else
        log "     comptes modifiés mais Traefik non redémarré : faire « docker compose restart traefik »"
    fi
}

# --- Réseaux ----------------------------------------------------------------

# Les deux réseaux portent un nom physique figé dans compose.yaml, et les
# projets voisins les déclarent « external: true » : ils ne peuvent donc pas
# les créer eux-mêmes. D'où ce bloc, appelé avant toute commande Compose : il
# crée ce qui manque (un « docker network prune » nocturne, une machine neuve,
# un « compose down » malheureux) et meurt si le réseau refuse de se créer —
# mieux vaut un déploiement d'infrastructure qui échoue ici qu'un déploiement de
# site qui échoue trois minutes plus tard sur un « network external not found »,
# avec les conteneurs applicatifs à moitié démarrés.
ensure_networks() {
    local net
    for net in yabiladi_app yabiladi_logging; do
        docker network inspect "$net" >/dev/null 2>&1 && continue
        log "     création du réseau $net (absent — les projets voisins le déclarent « external »)"
        docker network create "$net" >/dev/null \
            || die "impossible de créer $net — un objet du même nom existe déjà dans un autre contexte (« docker network ls », « docker network rm $net »)"
    done
    docker network inspect yabiladi_app >/dev/null 2>&1 \
        || die "yabiladi_app reste inexistant après sa création : arrêter ici, l'infrastructure n'est pas déployable"
}

# --- Volumes -----------------------------------------------------------------

# Six volumes appartiennent à l'infrastructure et portent un nom physique figé
# dans compose.yaml ; les quatre compose (infra + site + factu + mediakit) les
# déclarent tous « external: true », donc Compose refuse de les créer. Sur une
# machine neuve — ou après un « docker volume prune » malheureux — c'est ici
# qu'ils renaissent, avant le premier « up -d ». Un volume déjà présent n'est
# jamais touché : la liste est exhaustive, pas destructive.
ensure_volumes() {
    local vol
    for vol in yabiladi_postfix_spool yabiladi_traefik_acme yabiladi_geoip_data \
               yabiladi_dbackup_data yabiladi_dbackup_tmp yabiladi_alloy_data; do
        docker volume inspect "$vol" >/dev/null 2>&1 && continue
        log "     création du volume $vol (absent — les quatre projets le déclarent « external »)"
        docker volume create "$vol" >/dev/null \
            || die "impossible de créer $vol — un objet du même nom existe déjà dans un autre contexte (« docker volume ls »)"
    done
}

# --- Droits et dossiers ------------------------------------------------------

ensure_owner() { # $1 dossier, $2 uid, $3 gid, $4 mode (0750 par défaut)
    local dir="$1" mode="${4:-0750}"
    install -d -m "$mode" -o "$2" -g "$3" "$dir" \
        || die "impossible de préparer $dir (racine requise : Loki et Grafana ne tournent pas en root)"
    # Récursif seulement si la racine n'a pas déjà le bon propriétaire : un
    # magasin de plusieurs Go ne retraverse pas son arbre à chaque déploiement.
    if [ "$(stat -c %u "$dir")" != "$2" ] || [ "$(stat -c %g "$dir")" != "$3" ]; then
        chown -R "$2:$3" "$dir" || die "chown -R $2:$3 $dir a échoué"
    fi
}

# Ce que Docker ne fait pas seul pour la pile de journaux : les dossiers que
# ses conteneurs non-root écrivent, et le secret Grafana (hors coffre parce
# qu'il n'est généré qu'une fois par machine — le rejouer n'aurait aucun effet).
#
# Sans cette étape, un « git pull » suivi de « up -d » donne deux conteneurs
# morts : Loki (10001) sur son WAL et Grafana (472) sur SQLITE_CANTOPEN, dans
# des dossiers que Docker vient de créer en root:root ; et Grafana refuse de
# démarrer sans son fichier de mot de passe.
#
# Périmètre : les trois magasins (loki, grafana, prometheus) et rien d'autre.
# Les dossiers d'écriture du site — public/files, var/, les caches — relèvent de
# son propre deploy.sh : l'infrastructure ne connaît que ses conteneurs, et une
# console de sauvegarde qui préparait la data d'un autre projet se retrouverait
# à poser des droits sur une arborescence qu'elle n'a pas le droit de toucher.
prepare_logging() {
    # Ordre de priorité identique à Compose : environnement du shell, puis .env.
    local root="${LOGGING_HOST_DATA_PATH:-$(env_value LOGGING_HOST_DATA_PATH /data/logging)}"
    local secret="${GRAFANA_ADMIN_PASSWORD_FILE:-$(env_value GRAFANA_ADMIN_PASSWORD_FILE docker/grafana/secrets/admin_password)}"
    local smtp_secret="${GRAFANA_SMTP_PASSWORD_FILE:-$(env_value GRAFANA_SMTP_PASSWORD_FILE docker/grafana/secrets/smtp_password)}"

    # Poste de développement : compose.override.yaml remplace ces montages par
    # des volumes nommés, et /data n'a pas à exister.
    case "$(uname -s)" in
        MINGW* | MSYS*) return 0 ;;
    esac

    [[ "$secret" = /* ]] || secret="$REPO/${secret#./}"
    [[ "$smtp_secret" = /* ]] || smtp_secret="$REPO/${smtp_secret#./}"

    ensure_owner "$root/loki" 10001 10001
    ensure_owner "$root/grafana" 472 472
    # 65534 = « nobody », l'utilisateur sous lequel l'image prom/prometheus tourne
    # déjà (vérifié avec « docker run --entrypoint /bin/sh … -c id » : aucun « user: »
    # n'est posé dans compose.yaml, ce serait répéter une décision de l'image). Sans
    # ce chemin, le premier démarrage meurt en écrivant son WAL :
    #   open /prometheus/wal: permission denied
    # et le conteneur redémarre en boucle sans que « docker compose ps » n'affiche
    # autre chose que « restarting ».
    ensure_owner "$root/prometheus" 65534 65534

    if [ ! -s "$secret" ]; then
        "$REPO/tools/logging/bootstrap-grafana-admin.sh" >/dev/null \
            || die "création du secret Grafana impossible ($secret)"
        log "     secret Grafana créé (valeur jamais affichée)"
    fi
    # GID 472 = utilisateur « grafana » de l'image ; un 0400 root:root serait
    # illisible par lui, et le conteneur échouerait sur « could not read
    # password from file ».
    chgrp 472 "$secret" || die "chgrp 472 $secret a échoué"
    chmod 0640 "$secret" || die "chmod 0640 $secret a échoué"

    # Secret SMTP : le mot de passe est dérivé de BOT_MONITOR_MAILER_DSN, qui
    # vit dans le .env.local du coffre — celui de l'infrastructure ici, déchiffré
    # par la ligne « infra » du manifeste. Même régime que le secret admin :
    # fichier hors git, jamais affiché, 0640 root:472. Sans ce fichier, Grafana
    # ne peut pas authentifier son relais Resend et les alertes partent en spam
    # ou n'arrivent jamais.
    #
    # Le DSN est partagé avec l'application — une seule clé Resend pour la
    # machine, et non deux entrées de coffre finissant par diverger. Son absence
    # ici arrête le déploiement plutôt qu'elle ne le signale : un Grafana qui
    # n'envoie rien est une supervision muette, ce qui est pire qu'une interface
    # cassée que quelqu'un remarque.
    local dsn
    dsn="$(compose_value BOT_MONITOR_MAILER_DSN "")"
    if [ -z "$dsn" ]; then
        die "BOT_MONITOR_MAILER_DSN absent de $REPO/.env.local : impossible de dériver le secret SMTP Grafana (le DSN Resend se déclare dans le .env.local scellé sous deploy/secrets/env.local.sops.bin, colonne project = infra)"
    fi
    # Format attendu : smtp://user:password@host:port
    # Le mot de passe est entre le premier « : » après « // » et le dernier « @ ».
    local body="${dsn#smtp://}"
    local creds="${body%@*}"
    local password="${creds#*:}"
    if [ -z "$password" ] || [ "$password" = "$creds" ]; then
        die "BOT_MONITOR_MAILER_DSN mal formé (pas de mot de passe entre user@ et host)"
    fi
    # Décodage URL : les caractères spéciaux dans le DSN sont percent-encodés.
    # Les clés API Resend sont en base62 (re_xxxx), mais le décodage ne coûte rien.
    password="$(printf '%b' "${password//%/\\x}")"
    mkdir -p "$(dirname "$smtp_secret")"
    # Écriture directe, sans interpolation : le mot de passe peut contenir « $ ».
    printf '%s' "$password" >"$smtp_secret"
    password=""
    chgrp 472 "$smtp_secret" || die "chgrp 472 $smtp_secret a échoué"
    chmod 0640 "$smtp_secret" || die "chmod 0640 $smtp_secret a échoué"
    log "     secret SMTP Grafana dérivé du DSN Resend (valeur jamais affichée)"
}

# Ce que Docker ne fait pas seul pour la console de sauvegarde : le dossier de
# destination, et le contrôle que ses clés sont bien arrivées.
#
# DBackup tourne en uid 1001 (l'image refuse expressément root, mesuré : « Running
# as root (PUID/PGID=0) is not supported »). Sans cette ligne, « up -d » crée le
# point de montage en root:root sur le NFS, et chaque job s'arrête sur une
# erreur d'écriture — silencieusement, dans l'interface, la nuit.
prepare_backups() {
    local secret_file="$REPO/docker/legacy/dbackup.env"
    local missing=0 k
    # Le coffre pose quatre clés ; la garde du manifeste (deploy/secrets.manifest)
    # compte déjà les variables, mais elle ne s'applique qu'au fichier qu'il
    # déclare. Un déploiement sur une machine qui n'a pas encore reçu la ligne
    # serait passé ici sans rien remarquer.
    for k in ENCRYPTION_KEY BETTER_AUTH_SECRET DBACKUP_ADMIN_EMAIL DBACKUP_ADMIN_PASSWORD; do
        grep -q "^$k=..*" "$secret_file" 2>/dev/null || missing=1
    done
    [ "$missing" = 0 ] || die "docker/legacy/dbackup.env incomplet (4 clés attendues) — appliquer « ./deploy.sh --secrets » après avoir scellé deploy/secrets/dbackup.sops.bin"

    case "$(uname -s)" in
        # Poste de développement : compose.override.yaml et le dossier du projet
        # suffisent, les permissions y sont simulées par le VM Docker.
        MINGW* | MSYS*) return 0 ;;
    esac

    # Les trois chemins où la sauvegarde écrit portent, dans le .env versionné, un
    # défaut de poste de travail : « ./backup/archives », « ./backup/restore »,
    # « ./backup/mariadb ». Sur une machine, la valeur vient de .env.local — le
    # fichier propre à la machine, déchiffré du coffre — et rien, jusqu'ici, n'y
    # déclarait ces clés : une machine neuve écrivait donc ses archives, son
    # atelier de restauration et ses 15 Go de mariabackup sur le disque de
    # l'application, dans un dossier du dépôt. La destination des archives tue :
    # la déplacer après coup orpheline ses chaînes, la rétention étant attachée au
    # job et au dossier. Les deux ateliers préviennent seulement — un dépôt
    # deploy.sh ne doit pas se refuser pour un disque un peu juste.
    #
    # Depuis la séparation, « le dépôt » est celui de l'infrastructure : le garde
    # ne protège plus le code du site, mais la règle reste la même — une archive
    # ne se range pas dans un dépôt.
    local cle valeur cible
    for cle in DBACKUP_DEST_HOST_PATH DBACKUP_RESTORE_HOST_PATH MARIADB_BACKUP_HOST_PATH; do
        valeur="$(compose_value "$cle" "")"
        case "$valeur" in
            /*) cible="$valeur" ;;
            ?*) cible="$REPO/${valeur#./}" ;;
            *) cible="$REPO" ;;
        esac
        case "$cible" in
            "$REPO" | "$REPO"/*)
                if [ "$cle" = "DBACKUP_DEST_HOST_PATH" ]; then
                    die "$cle = « ${valeur:-<défaut du .env>} » : les archives sortiraient dans le dépôt ($cible). Poser le répertoire du NFS de sauvegarde dans .env.local (gabarit : deploy/secrets/env.local.example), re-sceller le coffre, puis relancer."
                fi
                log "  · ATTENTION : $cle = « ${valeur:-<défaut du .env>} » tombe dans le dépôt ($cible) — désigner un disque qui a la place dans .env.local."
                ;;
        esac
    done

    # Les racines hors de CE dépôt que la console archive : les deux dépôts
    # voisins, les données du site et le contenu des antennes. Elles peuvent
    # manquer légitimement — une application pas encore basculée, des médias dont
    # l'arbre vit ailleurs sur cette machine —, mais un montage dont la source
    # manque est créé vide par Docker : le job n'archiverait rien et se dirait
    # « réussi ». D'où l'avertissement plutôt que l'erreur, avec la clé à poser.
    local app cle_app
    for cle_app in MEDIAKIT_HOST_DIR FACTURATION_HOST_DIR RADIO_CONTENT_HOST_PATH \
                   SITE_MEDIA_HOST_PATH SITE_EDITOR_IMAGES_HOST_PATH; do
        app="$(compose_value "$cle_app" "")"
        [ -n "$app" ] || continue
        case "$app" in
            /*) ;;
            ./*) app="$REPO/${app#./}" ;;
            *) app="$REPO/$app" ;;
        esac
        [ -d "$app" ] || log "  · ATTENTION : $cle_app = « $app » n'existe pas — déclarer l'emplacement réel dans .env.local (gabarit : deploy/secrets/env.local.example), re-sceller le coffre, puis relancer. Les jobs qui lisent cette racine n'archiveront rien."
    done

    # « media » et « editor-images » ne désignent pas le dépôt du site : depuis la
    # bascule, les écritures de PHP — médias et dossier de l'éditeur TinyMCE —
    # restent sous le webroot V1, toujours en service, que le site relaie par deux
    # bind mounts. Un chemin qui se termine par « public/files » ou « public/img »
    # est le repli de développement : la console archiverait alors des fichiers
    # versionnés, jamais les données des membres.
    local media editor
    media="$(compose_value SITE_MEDIA_HOST_PATH /home/yabiladi/www/app/webroot/files)"
    editor="$(compose_value SITE_EDITOR_IMAGES_HOST_PATH /home/yabiladi/www/app/webroot/img)"
    case "$media" in */public/files)
        log "  · ATTENTION : SITE_MEDIA_HOST_PATH = « $media » est l'arbre du dépôt, pas le webroot V1 — le job « media » archiverait les fichiers gitignorés du site, pas les médias des membres." ;;
    esac
    case "$editor" in */public/img)
        log "  · ATTENTION : SITE_EDITOR_IMAGES_HOST_PATH = « $editor » est l'arbre du dépôt, pas le webroot V1 — le job « editor-images » raterait les images publiées par l'éditeur." ;;
    esac

    local dest
    dest="$(compose_value DBACKUP_DEST_HOST_PATH ./backup/archives)"
    [[ "$dest" = /* ]] || dest="$REPO/${dest#./}"
    # 1001:33, pas 1001:1001 — ce sont les credentials que prend le processus de
    # la console (PGID 33 dans compose.yaml, le groupe des fichiers écrits
    # 0640/0750 par www-data dans les dossiers sauvegardés). Un dossier du NFS
    # créé par « up -d » serait root:root et aucun archive n'y entrerait.
    ensure_owner "$dest" 1001 33

    # Cible des restaurations : même propriétaire, parce que c'est la console
    # qui y écrit. Pas de 0770 ici : ensure_owner prend 0750 par défaut, et une
    # restauration recrée des sous-dossiers sous l'identité 1001:33, donc le
    # groupe www-data les relit comme les sources.
    local restore
    restore="$(compose_value DBACKUP_RESTORE_HOST_PATH ./backup/restore)"
    [[ "$restore" = /* ]] || restore="$REPO/${restore#./}"
    ensure_owner "$restore" 1001 33
}

# Amorçage de la console : compte administrateur, adaptateurs et les jobs
# préconfigurés — un par dossier sauvegardé plus celui de la base —, par l'API de
# DBackup (tools/backup/dbackup-bootstrap.mjs).
# Idempotent — relancé sur une console déjà réglée, il ne change rien et se
# contente de le dire. Après « up -d » donc, le conteneur devant être en vie.
bootstrap_backups() {
    docker compose exec -T dbackup node /opt/backup-tools/dbackup-bootstrap.mjs \
        || die "amorçage de la console de sauvegarde a échoué — « docker compose logs dbackup »"
}

# Le magasin ACME (certificats Let's Encrypt) est écrit par Traefik en 0600
# root:root dans le volume nommé traefik_acme, que la console monte en lecture
# seule. L'image de sauvegarde refuse de tourner en root (mesuré : « Running as
# root (PUID/PGID=0) is not supported ») : sans cette ouverture, le fichier
# manque à l'archive chaque nuit et le job se déclare « partiel ».
#
# C'est le seul fichier du périmètre qu'on rend lisible exprès : un renouvellement
# de certificat rate, une réémission compte dans les quotas Let's Encrypt, et
# contrairement aux comptes htpasswd — écartés du job, leur source de vérité est
# le coffre — il n'existe nulle part ailleurs. 0640 root:33 : le groupe de la
# console lit (PGID 33 dans compose.yaml), seul root écrit. Si Traefik recrée le
# fichier (mode 0600), la sauvegarde du soir le redit et ce déploiement le corrige
# au passage suivant.
open_acme_to_backup() {
    docker compose exec -T --user root traefik sh -c \
        'chgrp 33 /letsencrypt/acme.json 2>/dev/null; chmod 0640 /letsencrypt/acme.json 2>/dev/null; true' \
        >/dev/null 2>&1 || log "     acme.json non rendu lisible (Traefik arrêté ?) : le job de sauvegarde le signalera"
}

# Migration de la console de sauvegarde (novembre 2026) : Backrest a été retiré de
# compose.yaml au profit de DBackup. Or « up -d » ne supprime pas le conteneur d'un
# service qui n'existe plus — il resterait actif avec ses labels Traefik, donc à
# disputer « backups.yabiladi.com » à la nouvelle console.
#
# Retirer ce seul conteneur, et non passer « --remove-orphans » : ce dernier
# emporterait aussi les orphelins légitimes d'un autre chantier posés sur le même
# projet (mesuré sur le poste de développement : le MySQL jetable de test en fait
# partie). « docker compose ps -a » ne liste que les conteneurs étiquetés de CE
# projet, la recherche est donc bornée d'elle-même — et, depuis la séparation, un
# backrest encore porté par le dépôt du site n'a rien à faire ici : ce dépôt ne
# retire que ce qu'il déclare.
retire_old_backup_console() {
    local orphelins
    orphelins="$(docker compose ps -a --format '{{.Name}}' 2>/dev/null | grep -i backrest || true)"
    [ -n "$orphelins" ] || return 0
    log "     retrait de l'ancienne console : $orphelins"
    # shellcheck disable=SC2086 # un nom par ligne, volontairement non protégé
    docker rm -f $orphelins >/dev/null || die "retrait de l'ancienne console de sauvegarde impossible"
}

# Vérifie si les montages des conteneurs grafana/loki correspondent à la
# configuration attendue. Si compose.override.yaml a changé les montages
# (bind mount -> volume nommé ou inverse), Docker Compose ne recrée pas
# automatiquement les conteneurs car le hash de configuration peut ne pas
# changer. Cette fonction détecte le décalage et force la recréation.
#
# Le nom de conteneur n'est plus écrit en dur : il porte le nom du projet, et
# celui-ci est passé de « yabiladi » à « yabiladi-infra » au déménagement. Un
# « yabiladi-grafana-1 » codé en dur aurait rendu ce contrôle muet sur chaque
# machine — et muet, ici, veut dire « le conteneur continue de lire un bind 9p
# que plus personne n'attend », exactement le cas que la fonction sait détecter.
# « docker compose ps -q » donne l'identifiant sans supposer rien du nom.
ensure_logging_mounts() {
    local service cid expected_source expected_type current_type
    for service in grafana loki prometheus; do
        cid="$(docker compose ps -q "$service" 2>/dev/null || true)"
        [ -n "$cid" ] || continue

        # Obtenir la source du montage attendu depuis la configuration
        expected_source=$(docker compose config "$service" 2>/dev/null \
            | grep -A 2 "volumes:" | grep "source:" | head -1 | awk '{print $2}' || true)
        [ -n "$expected_source" ] || continue

        # Déterminer le type attendu (volume ou bind)
        expected_type="volume"
        if [[ "$expected_source" == /* ]] || [[ "$expected_source" == ./* ]] || [[ "$expected_source" == ~* ]]; then
            expected_type="bind"
        fi

        # Obtenir le type de montage actuel, sur le point de montage de la
        # donnée (« /var/lib/grafana », « /loki », « /prometheus ») — pas sur les
        # fichiers de configuration montés par-dessus, qui sont toujours des bind.
        case "$service" in
            grafana) current_type="$(docker inspect "$cid" --format '{{range .Mounts}}{{if eq .Destination "/var/lib/grafana"}}{{.Type}}{{end}}{{end}}' 2>/dev/null || true)" ;;
            loki) current_type="$(docker inspect "$cid" --format '{{range .Mounts}}{{if eq .Destination "/loki"}}{{.Type}}{{end}}{{end}}' 2>/dev/null || true)" ;;
            *) current_type="$(docker inspect "$cid" --format '{{range .Mounts}}{{if eq .Destination "/prometheus"}}{{.Type}}{{end}}{{end}}' 2>/dev/null || true)" ;;
        esac

        # Si les types diffèrent, forcer la recréation
        if [ -n "$current_type" ] && [ "$current_type" != "$expected_type" ]; then
            log "     $service: montage $current_type détecté, $expected_type attendu — recréation"
            docker compose up -d --force-recreate "$service" >/dev/null 2>&1 \
                || log "     ($service: recréation échouée, redémarrage manuel requis)"
        fi
    done
}

# --- Contrôles ---------------------------------------------------------------

# Ce que ce déploiement vérifie, et ce qu'il ne vérifie plus : uniquement les
# services déclarés par ce dépôt. Les URL du site, les antennes radio et Dagu
# sont contrôlés par leurs propres scripts — un déploiement d'infrastructure qui
# échouerait parce que le site n'est pas encore tiré serait un faux message : le
# proxy, lui, fonctionne.
#
# Tout est en non-blocking : un contrôle qui échoue se dit, il ne tue pas le
# déploiement. A ce stade les conteneurs sont démarrés et les volumes en place ;
# « set -e » transformerait une sonde trop rapide en retour arrière.
checks_infra() {
    local code crt hb res h entry nom cible

    log "  table des services…"
    docker compose ps --format 'table {{.Name}}\t{{.Status}}' | sed -n '1,30p'

    # Le port 443, par le nom que le navigateur taperait : le DNS public et le
    # fichier hosts du poste ne décident pas de ce que cette ligne mesure. Les
    # trois noms servis par CE dépôt (grafana, tableau de bord Traefik, console
    # de sauvegarde) portent le résolveur ACME dans le fichier versionné : sur
    # le serveur, la réponse attendue au premier passage est un certificat
    # Let's Encrypt. Un CN auto-signé ici veut dire soit que le nom ne pointe
    # pas encore vers cette machine, soit que le compose.override.yaml du poste
    # de développement a atterri sur le serveur — ses labels « certresolver »
    # vides, ACME ne se déclenche jamais seul, et rien n'avertit personne.
    for h in grafana.yabiladi.com traefik.yabiladi.com backups.yabiladi.com; do
        crt=$(echo | openssl s_client -connect 127.0.0.1:443 -servername "$h" 2>/dev/null \
                  | openssl x509 -noout -issuer -enddate 2>/dev/null | tr '\n' ' ')
        printf '  tls %-24s %s\n' "$h" "${crt:-aucun certificat}"
    done

    # Le 80 ne rend rien d'autre qu'une redirection : c'est tout son rôle
    # (--entrypoints.web.http.redirections), et un 200 ici voudrait dire qu'un
    # routeur sans TLS s'est glissé dans la pile.
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:80/ 2>/dev/null) || code='000'
    log "  traefik :80   → HTTP $code (301 attendu)"

    # Les trois consoles publiées en loopback : leurs ports ne quittent jamais
    # 127.0.0.1, c'est Traefik qui sert le public. Une réponse ici prouve que le
    # conteneur vivant répond, pas que le routeur TLS est correct — les deux
    # lignes se lisent ensemble.
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$(compose_value GRAFANA_HTTP_PORT 8088)/api/health" 2>/dev/null) || code='000'
    log "  grafana       → HTTP $code (loopback)"

    # La console de sauvegarde en loopback (le port publié, pas Traefik) : son
    # propre endpoint de santé répond aussi « database: connected », ce qui est
    # la seule façon de voir ici que sa base SQLite a survécu à la recréation du
    # conteneur. L'accès public, lui, se contrôle avec le TLS plus haut.
    hb=$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$(compose_value DBACKUP_HTTP_PORT 8087)/api/health" 2>/dev/null) || hb='000'
    log "  dbackup       → HTTP $hb (loopback)"

    # Les sondes internes au réseau « logging ». Elles se font DEPUIS un
    # conteneur de ce réseau, par son nom de service : Loki, Prometheus,
    # node_exporter et cAdvisor ne publient rien sur l'hôte et n'ont pas vocation
    # à le faire — le poste qui les atteindrait en 127.0.0.1 aurait un trou, pas
    # un gain de confort. Grafana est le conteneur le plus bienveillant à
    # embarquer un wget (image alpine, healthcheck inclus) et il est branché sur
    # les deux réseaux.
    for entry in "loki|http://loki:3100/ready" \
                 "prometheus|http://prometheus:9090/-/healthy" \
                 "node-exporter|http://node-exporter:9100/metrics" \
                 "cadvisor|http://cadvisor:8080/healthz"; do
        nom="${entry%%|*}"; cible="${entry#*|}"
        res=$(docker compose exec -T grafana wget -q -O - --timeout=10 "$cible" 2>/dev/null \
                  | head -c 40 | tr -d '\n' || true)
        [ -n "$res" ] || res='aucune réponse'
        printf '  %-14s → %s (%s)\n' "$nom" "$res" "$cible"
    done

    # Alloy n'a aucune interface joignable depuis le réseau : son écoute est en
    # loopback interne au conteneur (127.0.0.1:12345), et c'est voulu — ni UI
    # d'administration publique, ni /-/reload exposé. Le seul contrôle possible
    # sans publier un port est donc une sonde dans le conteneur lui-même ; si
    # l'image n'a pas de wget, le log dira où regarder plutôt que de mentir.
    if docker compose exec -T alloy sh -c 'wget -q -O /dev/null http://127.0.0.1:12345/-/healthy' 2>/dev/null; then
        log "  alloy          → healthy (sonde interne)"
    else
        log "  alloy          → sonde interne indisponible : voir « docker compose logs alloy » et l'absence d'erreurs d'envoi vers Loki"
    fi

    # Postfix : l'état du démon, puis la longueur de la file. Un nombre qui ne
    # descend pas entre deux déploiements veut dire que le relais upstream refuse
    # (SPF, DMARC, quota) — ce n'est pas une panne de l'infrastructure, mais
    # c'est ici que ça se lit, parce que c'est ici que la file vit.
    res=$(docker compose exec -T postfix postqueue -p 2>/dev/null \
              | awk 'NR>1 && /^[0-9A-F][0-9A-F]*/ {n++} END {print n+0}' || true)
    log "  postfix        → ${res:-illisible} message(s) en file d'attente"
}

# --- Points d'entrée ---------------------------------------------------------

# Avant n'importe quelle commande Compose de ce script : les montages et le
# calibrage se décident à l'interpolation, donc dans le shell, pas dans
# l'application.
export_machine_env

verbe=deploy
while [ $# -gt 0 ]; do
    case "$1" in
        --build) verbe=build; shift ;;
        --secrets|--encrypt|--verify) verbe="${1#--}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "option inconnue : $1" ;;
    esac
done

# Deux filtres, dans cet ordre : la colonne « project » du manifeste retient les
# entrées de l'infrastructure, puis SECRETS_ONLY — s'il est posé — n'en garde que
# les fragments cités. Sans SECRETS_ONLY, TOUTES les lignes « infra » se
# déploient : env.local (le fichier machine de CE dépôt), dbackup (les quatre
# clés de la console), geoip (la clé MaxMind du téléchargement GeoLite2), les deux
# fichiers htpasswd lus par les middlewares, et grafana-admin (le mot de passe
# qu'une machine neuve doit connaître pour que la synchro des IHM puisse se
# fabriquer sa clé Viewer).
#
# La liste est écrite alors que « vide = tout » rendrait le même service : une
# machine qui n'a pas encore reçu un des clairs (geoip.env sur un poste qui ne
# télécharge pas la base, par exemple) doit pouvoir faire « ./deploy.sh
# --encrypt » sans que le coffre meure sur l'absent. CONTREPARTIE À TENIR :
# chaque nouvelle ligne « infra » du manifeste doit rejoindre cette liste, sinon
# elle ne se matérialise plus au déploiement — et le « --verify » de CE dépôt ne
# le voit pas, puisqu'il filtre pareil. C'est exactement comment « ui-sync »
# s'est retrouvé hors de la portée du site (voir le deploy.sh de CE projet).
if [ -z "${SECRETS_ONLY:-}" ]; then
    SECRETS_ONLY='env.local,dbackup,geoip,htpasswd,grafana-admin'
fi
export SECRETS_ONLY TARGET_PROJECT

case "$verbe" in
    encrypt|verify)
        build_secrets_image
        sub=encrypt
        [ "$verbe" = verify ] && sub=verify
        log "Coffre ($sub, projet $TARGET_PROJECT)…"
        run_secrets_tool "$sub"
        ;;

    secrets)
        ensure_networks
        ensure_volumes
        build_secrets_image
        log "Matérialisation des secrets…"
        hta_before="$(hta_fingerprint)"
        run_secrets_tool materialize
        log "Reprise des services dont l'environnement a changé…"
        prepare_logging
        prepare_backups
        # Mesuré, pas supposé : le contenu d'un env_file entre bien dans le hash de
        # configuration du service (deux hash différents pour une variable ajoutée),
        # donc « up -d » recrée seul ce qui doit l'être et laisse les autres conteneurs
        # en paix — important quand un autre chantier tient grafana ou loki.
        docker compose up -d
        reapply_htpasswd "$hta_before"
        retire_old_backup_console
        open_acme_to_backup
        bootstrap_backups
        ensure_logging_mounts
        checks_infra
        ;;

    deploy|build)
        log "1/5 Dépôt…"
        git status --untracked-files=no --porcelain | grep -q . && \
            die "arborescence modifiée : « git stash -u » ou commit avant de déployer"
        git pull --ff-only

        # Les réseaux avant tout le reste : « up -d » les créerait aussi, mais
        # seulement après la résolution des services, et un projet voisin lancé
        # dans le même mouvement tombe sur « network external not found ».
        ensure_networks
        ensure_volumes

        log "2/5 Secrets du coffre ($TARGET_PROJECT)…"
        build_secrets_image
        hta_before="$(hta_fingerprint)"
        run_secrets_tool materialize

        if [ "$verbe" = build ]; then
            log "     (rebuild des images demandé : docker/postfix et docker/secrets)"
            docker compose build
        fi

        log "3/5 Dossiers de la pile de journaux et coffre de sauvegarde…"
        prepare_logging
        prepare_backups

        log "4/5 Services…"
        docker compose up -d
        # Après « up -d », pas avant : si Traefik devait être recréé, le redémarrage
        # de trop serait fait deux fois ; si il ne l'est pas, c'est ce restart qui
        # donne au nouveau compte sa chance (voir reapply_htpasswd).
        reapply_htpasswd "$hta_before"
        retire_old_backup_console
        open_acme_to_backup
        bootstrap_backups
        ensure_logging_mounts

        # Alloy lit sa configuration au démarrage, et le fichier est un montage :
        # un « git pull » qui le modifie ne change pas la configuration du
        # service, donc « up -d » ne le recrée pas. Le redémarrage ne perd rien :
        # les offsets de lecture vivent dans le volume alloy_data et l'ingestion
        # reprend à l'octet déjà envoyé.
        docker compose restart alloy >/dev/null 2>&1 || log "     (alloy: restart manuel requis)"

        log "5/5 Contrôles…"
        checks_infra
        ;;

    *)
        usage
        exit 2
        ;;
esac
