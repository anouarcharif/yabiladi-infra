#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Déploiement de la stack docker-admin (Komodo) — et d'elle seule.
#
#   bash docker-admin/scripts/deploy.sh            # depuis la racine du dépôt
#   ./scripts/deploy.sh                            # depuis docker-admin/
#   bash docker-admin/scripts/deploy.sh --dry-run  # config rendue, rien de touché
#
# Ce que la règle de la pile interdit ici : piloter un autre projet. Ce script
# ne fait donc NI « git pull », NI « docker compose up » sur ../compose.yaml, NI
# redémarrage de Traefik, de Dagu ou de la console de sauvegarde. Il ne crée et
# ne démarre que les services déclarés par docker-admin/compose.yaml.
#
# Traefik n'a pas besoin d'un redémarrage : son fournisseur Docker écoute les
# évènements, un routeur déclaré par un conteneur qui démarre apparaît à la
# seconde (les comptes basicauth, eux, se relisent au chargement — mais ce
# déploiement ne les touche pas).
# ============================================================================

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ADMIN_DIR="$(dirname -- "$SCRIPT_DIR")"
REPO_DIR="$(dirname -- "$ADMIN_DIR")"

DRY_RUN=0
for a in "$@"; do
    case "$a" in
        --dry-run | --config) DRY_RUN=1 ;;
        -h | --help)
            sed -n '4,26p' "$0"
            exit 0
            ;;
        *) printf 'ERREUR: option inconnue « %s » — « --help » rend la liste\n' "$a" >&2; exit 2 ;;
    esac
done

# Git Bash transforme /var/run/docker.sock en C:/... dans les arguments docker.
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

log() { printf '%s\n' "$*"; }
die() { printf 'ERREUR: %s\n' "$*" >&2; exit 1; }
native_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$1"
    else
        printf '%s' "$1"
    fi
}

node_profile="$REPO_DIR/deploy/node-profile.sh"
[ -f "$node_profile" ] || die "profil serveur introuvable : $node_profile"
# shellcheck source=../../deploy/node-profile.sh
. "$node_profile"
resolve_yabiladi_node || die "impossible d'identifier le nœud Yabiladi"

# Une seule source d'interpolation pour les deux projets du dépôt : le « .env »
# versionné racine. Compose ne lit pas le « .env » d'un autre répertoire que le
# sien, d'où le drapeau — sans lui, « docker-admin/compose.yaml » n'interpolerait
# rien du tout et prendrait silencieusement les défauts écrits dans le fichier.
cd "$ADMIN_DIR"   # chemins relatifs à la pile : voir compose() en dessous

compose() {
    # Un « -f » empêche Compose de charger lui-même le « compose.override.yaml »
    # voisin (mesuré sur v5.6.1 : absent du rendu tant qu'on ne le nomme pas).
    # Le surcharge du poste — ici, le resolver Let's Encrypt vidé — doit donc
    # être ajouté à la main pour retrouver le comportement du projet racine.
    if [ -f compose.override.yaml ]; then
        docker compose --env-file ../.env -f compose.yaml -f compose.override.yaml "$@"
    else
        docker compose --env-file ../.env -f compose.yaml "$@"
    fi
}

prepare_komodo() {
    local envfile="$REPO_DIR/docker/legacy/komodo.env" line key value
    local onboarding_key_file onboarding_public_key_file

    if [ -f "$envfile" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in '' | \#*) continue ;; esac
            [ "$line" != "${line%%=*}" ] || continue
            key="${line%%=*}"
            value="${line#*=}"
            value="${value%\r}"
            value="${value%\"}"
            value="${value#\"}"
            case "$key" in [0-9]* | *[!A-Za-z0-9_]*) continue ;; esac
            export "$key=$value"
        done < "$envfile"
    fi

    unset PERIPHERY_ONBOARDING_KEY KOMODO_TAROURT_ONBOARDING_KEY
    onboarding_key_file="$REPO_DIR/docker/legacy/komodo-onboarding-${YABILADI_NODE}.key"
    onboarding_public_key_file="$REPO_DIR/docker/legacy/komodo-onboarding-${YABILADI_NODE}.pub"
    export KOMODO_ONBOARDING_KEY_FILE="$(native_path "$onboarding_key_file")"
    export KOMODO_ONBOARDING_PUBLIC_KEY_FILE="$(native_path "$onboarding_public_key_file")"
    export KOMODO_ONBOARDING_KEY_NAME="Yabiladi ${YABILADI_NODE}"

    case "$YABILADI_NODE" in
        tarourt)
            export COMPOSE_PROFILES=komodo-periphery
            export KOMODO_CERT_RESOLVER=letsencrypt
            export KOMODO_API_ADDRESS="https://komodo-imouzzer.yabiladi.com"
            export PERIPHERY_CORE_ADDRESS="wss://komodo-imouzzer.yabiladi.com"
            export PERIPHERY_CONNECT_AS=Tarourt
            export PERIPHERY_SERVER_ENABLED=false
            log "  Komodo : Periphery Tarourt configuré en mode sortant"
            ;;
        imouzzer)
            [ -f "$envfile" ] || die "docker/legacy/komodo.env absent sur Imouzzer"
            export COMPOSE_PROFILES=komodo-core,komodo-periphery
            export KOMODO_HOST="https://${KOMODO_HOSTNAME}"
            export KOMODO_API_ADDRESS="http://127.0.0.1:9120"
            export KOMODO_FIRST_SERVER_NAME="${KOMODO_FIRST_SERVER_NAME:-Imouzzer}"
            export KOMODO_CERT_RESOLVER=letsencrypt
            export PERIPHERY_CORE_ADDRESS="ws://komodo-core:9120"
            export PERIPHERY_CONNECT_AS="$KOMODO_FIRST_SERVER_NAME"
            export PERIPHERY_SERVER_ENABLED=false
            log "  Komodo : Core, MongoDB et Periphery Imouzzer"
            ;;
        local)
            export COMPOSE_PROFILES=komodo-core,komodo-periphery
            export KOMODO_HOST="https://${KOMODO_HOSTNAME}"
            export KOMODO_API_ADDRESS="http://127.0.0.1:9120"
            export KOMODO_FIRST_SERVER_NAME="${KOMODO_FIRST_SERVER_NAME:-Local}"
            export KOMODO_DATABASE_USERNAME="${KOMODO_DATABASE_USERNAME:-komodo_local}"
            export KOMODO_DATABASE_PASSWORD="${KOMODO_DATABASE_PASSWORD:-komodo_local_password}"
            export KOMODO_INIT_ADMIN_USERNAME="${KOMODO_INIT_ADMIN_USERNAME:-admin}"
            export KOMODO_INIT_ADMIN_PASSWORD="${KOMODO_INIT_ADMIN_PASSWORD:-changeme_local}"
            export KOMODO_LOCAL_AUTH=true
            export KOMODO_CERT_RESOLVER=
            export PERIPHERY_CORE_ADDRESS="ws://komodo-core:9120"
            export PERIPHERY_CONNECT_AS="$KOMODO_FIRST_SERVER_NAME"
            export PERIPHERY_SERVER_ENABLED=false
            log "  Komodo : profil local Core, MongoDB et Periphery actif"
            ;;
        *)
            die "profil Yabiladi non pris en charge pour Komodo : $YABILADI_NODE"
            ;;
    esac
}

prepare_komodo

log "── docker-admin : déploiement de la console d'administration Docker ──"

# --- Préconditions ----------------------------------------------------------

command -v docker >/dev/null 2>&1 || die "docker introuvable dans le PATH"
docker info >/dev/null 2>&1 || die "démon Docker injoignable — Docker Desktop lancé, sur ce poste ?"
compose version >/dev/null 2>&1 || die "« docker compose » indisponible (v2 minimum)"
PYTHON_BIN="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"
[ -n "$PYTHON_BIN" ] || die "Python 3 requis pour créer automatiquement la clé d'onboarding Komodo"
"$PYTHON_BIN" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' \
    || die "Python 3.8 minimum requis pour l'amorçage automatique Komodo"
[ -f "$REPO_DIR/.env" ] || die "$REPO_DIR/.env absent : ce dépôt porte les valeurs partagées, il doit être déployé avec"
[ -f "$ADMIN_DIR/compose.yaml" ] || die "compose.yaml introuvable à côté de ce script"

# Le réseau porté par l'infrastructure. Cette stack le déclare « external » :
# Compose refuserait de démarrer sans lui, mais le dire avant vaut mieux qu'un
# message de Compose.
docker network inspect yabiladi_app >/dev/null 2>&1 \
    || die "le réseau « yabiladi_app » n'existe pas : déployer d'abord l'infrastructure (« bash deploy.sh » à la racine du dépôt)"

# Traefik en écoute. Sans lui, les labels ne servent à rien : la stack
# démarrerait, et aucune URL ne répondrait — le pire des
# états, parce qu'il a l'air d'un succès.
TRAEFIK_ID="$(docker ps -q --filter label=com.docker.compose.project=yabiladi-infra --filter label=com.docker.compose.service=traefik | head -1)"
[ -n "$TRAEFIK_ID" ] \
    || die "aucun conteneur Traefik démarré dans le projet « yabiladi-infra » : l'URL Komodo resterait muette — déployer l'infrastructure d'abord"

# Le fichier de comptes partagé par les consoles. On ne le crée pas, on ne le
# modifie pas, on ne l'affiche pas : « ../deploy.sh » le repose depuis le coffre.
HTPASSWD="$REPO_DIR/docker/traefik/htpasswd/user_yabiladi"
[ -f "$HTPASSWD" ] \
    || die "aucun fichier de comptes « $HTPASSWD » : sans lui, Komodo renverra 401 à tout le monde. Le reposer : « bash deploy.sh » à la racine (matérialisation du coffre)"
grep -q '\$2[aby]\$' "$HTPASSWD" \
    || die "« $HTPASSWD » ne porte aucun hash bcrypt : Traefik v3 refuse silencieusement les formats Apache (apr1, MD5)"

ensure_volumes() {
    local volume
    for volume in yabiladi_komodo_mongo_data yabiladi_komodo_mongo_config \
                  yabiladi_komodo_backups yabiladi_komodo_keys; do
        docker volume inspect "$volume" >/dev/null 2>&1 && continue
        log "  création du volume $volume"
        docker volume create "$volume" >/dev/null \
            || die "impossible de créer le volume $volume"
    done
}

retire_legacy_infra_komodo() {
    local service ids
    for service in komodo-mongo komodo-core komodo-periphery; do
        ids="$(docker ps -aq \
            --filter label=com.docker.compose.project=yabiladi-infra \
            --filter "label=com.docker.compose.service=$service")"
        [ -n "$ids" ] || continue
        log "  retrait de l'ancien conteneur infra/$service"
        # Container IDs returned by Docker contain no whitespace.
        # shellcheck disable=SC2086
        docker rm -f $ids >/dev/null || die "impossible de retirer infra/$service"
    done
}

# --- Configuration ----------------------------------------------------------

log "  lecture de la configuration…"
if [ "$DRY_RUN" -eq 1 ]; then
    compose config
    log "  (--dry-run : rien n'est créé, rien n'est démarré)"
    exit 0
fi
compose config -q || die "compose.yaml refusé par Compose — corriger avant de démarrer"
ensure_volumes
retire_legacy_infra_komodo

# Core must be available before the admin API can provision the Periphery key.
if [ "$YABILADI_NODE" != tarourt ]; then
    log "  démarrage de Komodo Core avant l'appairage…"
    compose up -d komodo-mongo komodo-core \
        || die "impossible de démarrer MongoDB et Komodo Core avant l'appairage"
fi

log "  création/vérification de la clé d'onboarding…"
bootstrap_script="$(native_path "$SCRIPT_DIR/bootstrap_onboarding.py")"
bootstrap_status="$("$PYTHON_BIN" "$bootstrap_script")" \
    || die "amorçage automatique de la clé d'onboarding impossible"
case "$bootstrap_status" in
    created) log "  clé d'onboarding : créée et stockée localement (0600)" ;;
    ready) log "  clé d'onboarding : valide et active" ;;
    *) die "résultat inattendu de l'amorçage Komodo" ;;
esac

# --- Démarrage --------------------------------------------------------------

log "  démarrage des services Komodo…"
compose up -d --remove-orphans \
    || die "« compose up -d » a échoué — « docker compose -f docker-admin/compose.yaml logs »"
# « --remove-orphans » est borné à CE projet : il ne peut emporter qu'un
# conteneur étiqueté « yabiladi-docker-admin » sans service correspondant dans
# ce fichier, jamais un conteneur d'un autre projet.

# --- Attente de démarrage ---------------------------------------------------

log "  attente du démarrage des services…"
services_actifs=(komodo-periphery)
[ "$YABILADI_NODE" = tarourt ] || services_actifs=(komodo-mongo komodo-core komodo-periphery)
services_running() {
    local cid etat
    for service in "${services_actifs[@]}"; do
        cid="$(compose ps -q "$service" 2>/dev/null | head -1)"
        [ -n "$cid" ] || return 1
        etat="$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || echo inconnu)"
        [ "$etat" = running ] || { printf '%s=%s ' "$service" "$etat"; return 1; }
    done
    return 0
}
attendu=0
until (services_running); do
    attendu=$((attendu + 5))
    if [ "$attendu" -ge 180 ]; then
        log "  ATTENTION : services Komodo non démarrés au bout de 180 s — journaux :"
        compose ps
        compose logs --tail 20 || true
        die "la stack Komodo n'est pas démarrée"
    fi
    sleep 5
done
log "  services Komodo : démarrés"

# --- Contrôles --------------------------------------------------------------

sonde_depuis_traefik() { # $1 nom de service, $2 port
    if docker exec "$TRAEFIK_ID" wget -S -q -O /dev/null --timeout=8 "http://$1:$2/" 2>&1 | grep -qE ' (200|204|30[127]|401)'; then
        log "  traefik → $1:$2               : joint"
        return 0
    fi
    log "  ATTENTION : Traefik n'atteint pas $1:$2 — routeur en 502, vérifier le réseau du conteneur"
    return 1
}

if [ "$YABILADI_NODE" != tarourt ]; then
    sonde_depuis_traefik komodo-core 9120 || true
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        "http://127.0.0.1:9120/" 2>/dev/null || true)"
    log "  komodo loopback :9120 → HTTP ${code:-aucune réponse}"
fi

log ""
log "── déployé ──"
if [ "$YABILADI_NODE" = tarourt ]; then
    log "  Periphery Tarourt connectée au Core Imouzzer"
else
    log "  Komodo : https://${KOMODO_HOSTNAME} (compte basicauth partagé)"
fi
log ""
