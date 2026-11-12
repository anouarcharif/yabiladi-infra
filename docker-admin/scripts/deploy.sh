#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Déploiement de la stack docker-admin — et d'elle seule.
#
#   bash docker-admin/scripts/deploy.sh            # depuis la racine du dépôt
#   ./scripts/deploy.sh                            # depuis docker-admin/
#   bash docker-admin/scripts/deploy.sh --dry-run  # config rendue, rien de touché
#
# Ce que la règle de la pile interdit ici : piloter un autre projet. Ce script
# ne fait donc NI « git pull », NI « docker compose up » sur ../compose.yaml, NI
# redémarrage de Traefik, de Dagu ou de la console de sauvegarde. Il ne crée et
# ne démarre que les trois conteneurs déclarés par docker-admin/compose.yaml.
#
# Ce qu'il fait malgré tout, et pourquoi c'est sans risque :
#   - « docker volume create yabiladi_portainer_data » si le volume manque : un
#     volume existant n'est jamais touché (la commande ne fait rien dans ce cas) ;
#   - l'ouverture des droits du volume pour le groupe 33 de la console de
#     sauvegarde, depuis LE PROPRE CONTENEUR DE PORTAINER : sans elle, chaque
#     nuit, le job « portainer-volume-backup » sauterait la base Bolt en 0600 et
#     se dirait « partiel ». Même geste que « open_acme_to_backup » et
#     « open_grafana_data_to_backup » dans ../deploy.sh, sur la donnée de cette
#     stack.
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


log "── docker-admin : déploiement de la console d'administration Docker ──"

# --- Préconditions ----------------------------------------------------------

command -v docker >/dev/null 2>&1 || die "docker introuvable dans le PATH"
docker info >/dev/null 2>&1 || die "démon Docker injoignable — Docker Desktop lancé, sur ce poste ?"
compose version >/dev/null 2>&1 || die "« docker compose » indisponible (v2 minimum)"
[ -f "$REPO_DIR/.env" ] || die "$REPO_DIR/.env absent : ce dépôt porte les valeurs partagées, il doit être déployé avec"
[ -f "$ADMIN_DIR/compose.yaml" ] || die "compose.yaml introuvable à côté de ce script"

# Le réseau porté par l'infrastructure. Cette stack le déclare « external » :
# Compose refuserait de démarrer sans lui, mais le dire avant vaut mieux qu'un
# message de Compose.
docker network inspect yabiladi_app >/dev/null 2>&1 \
    || die "le réseau « yabiladi_app » n'existe pas : déployer d'abord l'infrastructure (« bash deploy.sh » à la racine du dépôt)"

# Traefik en écoute. Sans lui, les labels ne servent à rien : la stack
# démarrerait, serait en bonne santé, et aucune URL ne répondrait — le pire des
# états, parce qu'il a l'air d'un succès.
TRAEFIK_ID="$(docker ps -q --filter label=com.docker.compose.project=yabiladi-infra --filter label=com.docker.compose.service=traefik | head -1)"
[ -n "$TRAEFIK_ID" ] \
    || die "aucun conteneur Traefik démarré dans le projet « yabiladi-infra » : les deux URL resteraient muettes — déployer l'infrastructure d'abord"

# Le fichier de comptes que lisent déjà Dagu, Grafana, la console de sauvegarde
# et le tableau de bord Traefik. On ne le crée pas, on ne le modifie pas, on ne
# l'affiche pas : « ../deploy.sh » le repose depuis le coffre.
HTPASSWD="$REPO_DIR/docker/traefik/htpasswd/user_yabiladi"
[ -f "$HTPASSWD" ] \
    || die "aucun fichier de comptes « $HTPASSWD » : sans lui, les deux routeurs renverront 401 à tout le monde, y compris au bon mot de passe. Le reposer : « bash deploy.sh » à la racine (matérialisation du coffre)"
grep -q '\$2[aby]\$' "$HTPASSWD" \
    || die "« $HTPASSWD » ne porte aucun hash bcrypt : Traefik v3 refuse silencieusement les formats Apache (apr1, MD5) et aucun mot de passe ne passerait"

# --- Configuration ----------------------------------------------------------

log "  lecture de la configuration…"
if [ "$DRY_RUN" -eq 1 ]; then
    compose config
    log "  (--dry-run : rien n'est créé, rien n'est démarré)"
    exit 0
fi
compose config -q || die "compose.yaml refusé par Compose — corriger avant de démarrer"

# --- Volume -----------------------------------------------------------------

# Le volume des données de Portainer est partagé avec la console de sauvegarde,
# qui le déclare « external » dans ../compose.yaml : il doit exister AVANT le
# premier « up -d » des deux côtés. Jamais destructif : un volume en place garde
# son contenu, et cette commande ne le regarde pas.
if ! docker volume inspect yabiladi_portainer_data >/dev/null 2>&1; then
    log "  création du volume yabiladi_portainer_data (absent)"
    docker volume create yabiladi_portainer_data >/dev/null \
        || die "« docker volume create yabiladi_portainer_data » a échoué"
else
    log "  volume yabiladi_portainer_data : déjà en place (données conservées)"
fi

# --- Démarrage --------------------------------------------------------------

log "  démarrage des trois conteneurs de la stack…"
compose up -d --remove-orphans \
    || die "« compose up -d » a échoué — « docker compose -f docker-admin/compose.yaml logs »"
# « --remove-orphans » est borné à CE projet : il ne peut emporter qu'un
# conteneur étiqueté « yabiladi-docker-admin » sans service correspondant dans
# ce fichier, jamais un conteneur d'un autre projet.

# --- Attente en bonne santé -------------------------------------------------

log "  attente de la santé des services…"
en_sante() {
    local cid etat
    for service in docker-socket-proxy portainer dozzle; do
        cid="$(compose ps -q "$service" 2>/dev/null | head -1)"
        [ -n "$cid" ] || return 1
        etat="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || echo inconnu)"
        case "$etat" in
            healthy | running) ;;
            *) printf '%s=%s ' "$service" "$etat"; return 1 ;;
        esac
    done
    return 0
}
attendu=0
until (en_sante); do
    attendu=$((attendu + 5))
    if [ "$attendu" -ge 180 ]; then
        log "  ATTENTION : santé jamais atteinte au bout de 180 s — journaux :"
        compose ps
        compose logs --tail 20 || true
        die "la stack n'est pas en bonne santé"
    fi
    sleep 5
done
log "  docker-socket-proxy, portainer et dozzle : en écoute"

# --- Droits pour la console de sauvegarde -----------------------------------

bash "$SCRIPT_DIR/backup.sh" --grant-only || log "  ATTENTION : droits du volume non ouverts — le job « portainer-volume-backup » se signalera « partiel »"

# --- Contrôles --------------------------------------------------------------

log "  contrôles HTTP…"
# Trois sondeurs, trois questions différentes :
#   - chaque service répond-il chez lui ;
#   - Traefik l'atteint-il par le nom de service, sur « yabiladi_app » — le
#     chemin exact qu'empruntera le visiteur, porte basicauth non compris ;
#   - la porte basicauth est-elle bien fermée (contrôlée par « validate.sh »,
#     qui seul voit l'URL publique).
port_de() {
    case "$1" in
        portainer) printf '9000' ;;
        dozzle) printf '8080' ;;
        docker-socket-proxy) printf '2375' ;;
    esac
}
sonde_service() { # $1 service, $2 chemin — depuis le conteneur lui-même
    local service="$1" chemin="$2" port
    port="$(port_de "$service")"
    if [ "$service" = "dozzle" ]; then
        compose exec -T dozzle /dozzle healthcheck >/dev/null 2>&1 && { log "  $service          → localhost:$port/$chemin : OK"; return 0; }
    elif compose exec -T "$service" sh -c "wget -S -q -O /dev/null http://127.0.0.1:$port/$chemin 2>&1 | grep -qE ' (200|204|30[127])'"; then
        log "  $service          → localhost:$port/$chemin : OK"
        return 0
    fi
    if [ "$service" = "dozzle" ]; then
        log "  $service          → localhost:$port/$chemin : PAS de réponse — « compose logs $service »"
        return 1
    fi
    log "  ATTENTION : $service → localhost:$port/$chemin sans réponse — « compose logs $service »"
    return 1
}
sonde_depuis_traefik() { # $1 nom de service, $2 port
    if docker exec "$TRAEFIK_ID" wget -S -q -O /dev/null --timeout=8 "http://$1:$2/" 2>&1 | grep -qE ' (200|204|30[127]|401)'; then
        log "  traefik → $1:$2               : joint"
        return 0
    fi
    log "  ATTENTION : Traefik n'atteint pas $1:$2 — routeur en 502, vérifier le réseau du conteneur"
    return 1
}

sonde_service docker-socket-proxy _ping || true
# La racaine, et non « /api/ping » : mesuré sur 2.45.3, ce chemin répond 404 et
# « /api/* » passe à 303 dès que la fenêtre d'administrateur a expiré.
sonde_service portainer "" || true
sonde_service dozzle "" || true
sonde_depuis_traefik portainer 9000 || true
sonde_depuis_traefik dozzle 8080 || true

log ""
log "── déployé ──"
log "  Portainer : https://portainer.yabiladi.com   (compte basicauth de Dagu)"
log "  Dozzle    : https://logs.yabiladi.com        (compte basicauth de Dagu)"
log "  Les deux portent l'authentification interne de leur outil en plus du"
log "  basicauth : la première visite sur Portainer demande d'y créer le compte"
log "  administrateur. Ce geste ne se joue pas en script : un mot de passe ne"
log "  doit s'écrire ni dans ce dépôt, ni dans un journal, ni dans une commande."
log ""
log "  Sauvegarde : job « portainer-volume-backup » de la console DBackup,"
log "  planification « 40 4 * * * » — vérifier : bash scripts/validate.sh"
