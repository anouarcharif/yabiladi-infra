#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Rétrogradation de Portainer ou Dozzle — sans jamais toucher une donnée.
#
#   bash docker-admin/scripts/rollback.sh --list
#   bash docker-admin/scripts/rollback.sh --portainer 2.45.2-alpine
#   bash docker-admin/scripts/rollback.sh --dozzle v11.4.1-alpine
#   bash docker-admin/scripts/rollback.sh --portainer 2.45.2-alpine --dry-run
#
# Ce script ne pilote que les conteneurs de cette stack. Ni « git pull », ni
# Traefik, ni la console de sauvegarde, ni une application du projet voisin.
#
# Deux choses distinguent un rollback d'une mise à jour, et le script les traite
# toutes les deux :
#
#   1. La base de Portainer n'est pas réversible. Portainer migre le schéma de
#      son fichier Bolt au démarrage ; redémarrer une version ANTERIEURE sur une
#      base migrée donne un conteneur qui échoue, ou qui démarre en lisant mal
#      ses données. D'où, avant toute rétrogradation de Portainer : une copie du
#      volume sur un volume dédié, et retour automatique à l'image ET à la copie
#      si le service ne revient pas en bonne santé. Aucun écrasement n'est
#      aveugle : l'état laissé par la version qui a échoué est copié lui aussi,
#      avant d'être remplacé.
#
#   2. Le tag ne doit pas être inventé. « --list » rend la version réellement en
#      service, telle que l'annonce l'image du conteneur vivant, et les
#      suggestions viennent des tags réellement publiés sur le registre.
#
# La version visée passe par les variables d'interpolation du compose
# (ADMIN_PORTAINER_IMAGE, ADMIN_DOZZLE_IMAGE) posées par ce script dans
# l'environnement du « docker compose up » : elles priment sur le défaut écrit
# dans compose.yaml, ce qui évite de réécrire un fichier versionné pour une
# décision d'exploitation. Le script rend les lignes à reporter dans ../.env
# pour que le choix survive au prochain déploiement ordinaire.
# ============================================================================

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ADMIN_DIR="$(dirname -- "$SCRIPT_DIR")"
REPO_DIR="$(dirname -- "$ADMIN_DIR")"

SERVICE_PORTAINER="portainer"
SERVICE_DOZZLE="dozzle"
VOLUME="yabiladi_portainer_data"
SNAPSHOT_VOLUME="yabiladi_portainer_data_rollback"
# Horodaté : une copie d'un échec ne remplace jamais la précédente, et aucune
# sauvegarde n'est écrasée même quand le rollback tourne en boucle.
FAILED_VOLUME="yabiladi_portainer_data_echec-$(date +%Y%m%dT%H%M%S)"
HEALTH_TIMEOUT="${ROLLBACK_HEALTH_TIMEOUT:-180}"

TARGET_PORTAINER=""
TARGET_DOZZLE=""
DRY_RUN=0
DO_LIST=0
NO_SNAPSHOT=0

usage() {
    sed -n '4,37p' "$0"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --portainer) [ $# -ge 2 ] || { printf 'ERREUR: « --portainer » attend un tag, ex. 2.45.2-alpine\n' >&2; exit 2; }
            TARGET_PORTAINER="$2"; shift 2 ;;
        --dozzle)    [ $# -ge 2 ] || { printf 'ERREUR: « --dozzle » attend un tag, ex. v11.4.1-alpine\n' >&2; exit 2; }
            TARGET_DOZZLE="$2"; shift 2 ;;
        --list)      DO_LIST=1; shift ;;
        --no-snapshot) NO_SNAPSHOT=1; shift ;;
        --dry-run | --config) DRY_RUN=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) printf 'ERREUR: option inconnue « %s » — « --help » rend la liste\n' "$1" >&2; exit 2 ;;
    esac
done

# Git Bash transforme /vers en W:/vers dans les arguments passés à docker.
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

log() { printf '%s\n' "$*"; }
die() { printf 'ERREUR: %s\n' "$*" >&2; exit 1; }

cd "$ADMIN_DIR"   # chemins relatifs à la pile : voir compose() en dessous

compose() {
    # Un « -f » empêche Compose de charger le « compose.override.yaml » voisin :
    # le nommer ici évite de recréer le conteneur sans le surcharge du poste.
    if [ -f compose.override.yaml ]; then
        docker compose --env-file ../.env -f compose.yaml -f compose.override.yaml "$@"
    else
        docker compose --env-file ../.env -f compose.yaml "$@"
    fi
}

# Le conteneur en service d'un service de cette stack, par label Compose.
# Jamais un nom codé en dur : le préfixe change selon le projet et le poste.
conteneur_de() {
    docker ps -a --filter "label=com.docker.compose.project=yabiladi-docker-admin" \
                --filter "label=com.docker.compose.service=$1" \
                --format '{{.Names}}' | head -n 1
}

image_en_service() {
    local nom; nom="$(conteneur_de "$1")"
    [ -n "$nom" ] || return 1
    docker inspect --format '{{.Config.Image}}' "$nom" 2>/dev/null
}

# Liste des tags réellement publiés, pour suggérer sans inventer. Le registre
# public répond en JSON ; node est déjà la seule JS de ce dépôt (tools/backup).
tags_publiés() {
    local repo="$1" filtre="$2"
    node -e '
const https = require("https");
const [repo, filtre] = process.argv.slice(1);
const re = new RegExp(filtre);
(async () => {
    const noms = [];
    let url = `/v2/repositories/${repo}/tags?page_size=100`;
    for (let page = 0; page < 4 && url; page++) {
        const json = await new Promise((res, rej) => {
            https.get({ host: "hub.docker.com", path: url, headers: { "User-Agent": "docker-admin-rollback" } },
                r => { let d = ""; r.on("data", c => d += c); r.on("end", () => res(JSON.parse(d))); }).on("error", rej);
        });
        for (const t of json.results) if (re.test(t.name)) noms.push(t.name);
        url = json.next ? new URL(json.next).pathname : null;
    }
    const cle = v => v.replace(/[^0-9.]/g, "").split(".").map(Number);
    noms.sort((a, b) => { const x = cle(a), y = cle(b); for (let i = 0; i < 3; i++) if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) - (y[i] || 0); return 0; });
    console.log([...new Set(noms)].slice(-4).join(" "));
})().catch(e => { console.error("registre injoignable: " + e.message); process.exit(1); });
' "$repo" "$filtre"
}

attendre_sante() {
    local service="$1" delai="$HEALTH_TIMEOUT" nom sante
    nom="$(conteneur_de "$service")"
    [ -n "$nom" ] || { log "  ! aucun conteneur pour « $service »"; return 1; }
    local fin=$(( $(date +%s) + delai ))
    while [ "$(date +%s)" -lt "$fin" ]; do
        sante="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$nom" 2>/dev/null || echo inconnu)"
        case "$sante" in
            healthy|running) [ "$sante" = healthy ] && { log "  ✓ $service: $sante"; return 0; } ;;
            exited|dead)   log "  ✗ $service: $sante"; return 1 ;;
        esac
        sleep 4
    done
    log "  ✗ $service: toujours « $sante » après ${delai}s"
    return 1
}

# --- Garde-fou : la copie du volume avant toute rétrogradation --------------

capturer_volume() {
    local source="$1" dest="$2"
    # Le volume de secours est créé par CE script et porte sa étiquette : s'il
    # existe sous un autre nom d'auteur, on s'arrête plutôt que d'écraser.
    if docker volume inspect "$dest" >/dev/null 2>&1; then
        role="$(docker volume inspect --format '{{ index .Labels "com.docker.admin.role" }}' "$dest")"
        [ "$role" = rollback-snapshot ] \
            || die "volume « $dest » existe mais n'est pas une copie de ce script (étiquette « ${role:-absente} ») : rollback annulé, rien n'est écrasé"
        docker volume rm "$dest" >/dev/null || die "suppression de la copie sortante « $dest » refusée par le démon"
    fi
    docker volume create --label "com.docker.admin.stack=yabiladi-docker-admin" \
                         --label "com.docker.admin.role=rollback-snapshot" "$dest" >/dev/null
    # Copie par un conteneur éphémère : ni install sur l'hôte, ni chemin hôte
    # à deviner. « docker cp » ne sait pas lire un volume nommé. « tar -p » en
    # root conserve modes et propriétaires, c'est ce qu'on veut retrouver ici.
    docker run --rm --entrypoint sh --volume "$source:/de:ro" --volume "$dest:/vers" alpine:3 \
        -c 'tar -C /de -cf - . | tar -C /vers -xpf - && echo copié' \
        >/dev/null || return 1
}

restaurer_copie() {
    local source="$1" dest="$2"
    # Écrase UNIQUEMENT le volume de production par la copie prise deux minutes
    # avant : c'est le seul cas où une écriture est voulue. Portainer doit être
    # arrêté, sinon la base se réécrit pendant la recopie.
    docker run --rm --entrypoint sh --volume "$source:/de:ro" --volume "$dest:/vers" alpine:3 \
        -c 'find /vers -mindepth 1 -maxdepth 1 -exec rm -rf {} + && tar -C /de -cf - . | tar -C /vers -xpf -' >/dev/null
}

# --- --list : l'état réel, rien d'autre -------------------------------------

if [ "$DO_LIST" = 1 ]; then
    log "── versions réellement en service (stack yabiladi-docker-admin) ──"
    for s in "$SERVICE_PORTAINER" "$SERVICE_DOZZLE"; do
        if img="$(image_en_service "$s")"; then
            log "  $s -> $img"
        else
            log "  $s -> aucun conteneur (pile non déployée ?)"
        fi
    done
    log ""
    log "── tags publiés (les quatre plus récents) ──"
    log "  portainer-ce : $(tags_publiés portainer/portainer-ce '^[0-9]+\.[0-9]+\.[0-9]+-alpine$' 2>/dev/null || echo '?')"
    log "  dozzle       : $(tags_publiés amir20/dozzle '^v[0-9]+\.[0-9]+\.[0-9]+-alpine$' 2>/dev/null || echo '?')"
    exit 0
fi

[ -n "$TARGET_PORTAINER$TARGET_DOZZLE" ] || {
    printf 'ERREUR: rien à rétrograder. Donnez « --portainer <tag> » et/ou « --dozzle <tag> », ou « --list ».\n' >&2
    exit 2
}

command -v docker >/dev/null 2>&1 || die "docker introuvable dans le PATH"
docker info >/dev/null 2>&1 || die "démon Docker injoignable — Docker Desktop lancé, sur ce poste ?"
[ -f "$REPO_DIR/.env" ] || die "$REPO_DIR/.env absent"

if [ "$DRY_RUN" = 1 ]; then
    log "── rollback (simulation) ──"
    [ -n "$TARGET_PORTAINER" ] && log "  portainer -> portainer/portainer-ce:$TARGET_PORTAINER"
    [ -n "$TARGET_DOZZLE" ] && log "  dozzle    -> amir20/dozzle:$TARGET_DOZZLE"
    log "  rien n'est arrêté, rien n'est recopié : « --dry-run » s'arrête ici."
    exit 0
fi

# Le volume de données doit exister avant d'y toucher.
docker volume inspect "$VOLUME" >/dev/null 2>&1 \
    || die "volume « $VOLUME » absent : il n'y a rien à protéger. Déployez d'abord (« scripts/deploy.sh »)."

# Le tag visé doit exister localement ou être téléchargeable : le vérifier avant
# d'arrêter quoi que ce soit évite de rester sur un service inopérant.
verifier_image() {
    local img="$1"
    docker image inspect "$img" >/dev/null 2>&1 && return 0
    log "  … $img absente du cache local, téléchargement"
    docker pull --quiet "$img" >/dev/null || return 1
}

if [ -n "$TARGET_PORTAINER" ]; then
    verifier_image "portainer/portainer-ce:$TARGET_PORTAINER" \
        || die "image « portainer/portainer-ce:$TARGET_PORTAINER » injoignable : rollback annulé, rien n'a été arrêté"
fi
if [ -n "$TARGET_DOZZLE" ]; then
    verifier_image "amir20/dozzle:$TARGET_DOZZLE" \
        || die "image « amir20/dozzle:$TARGET_DOZZLE » injoignable : rollback annulé, rien n'a été arrêté"
fi

PREV_PORTAINER="$(image_en_service "$SERVICE_PORTAINER" 2>/dev/null || true)"
PREV_DOZZLE="$(image_en_service "$SERVICE_DOZZLE" 2>/dev/null || true)"

log "── rollback de la console d'administration Docker ──"
log "  en service : ${PREV_PORTAINER:-portainer: aucun}"
log "               ${PREV_DOZZLE:-dozzle: aucun}"

if [ -n "$TARGET_PORTAINER" ] && [ "$PREV_PORTAINER" = "portainer/portainer-ce:$TARGET_PORTAINER" ]; then
    log "  portainer: déjà à la version demandée, rien à faire"
    TARGET_PORTAINER=""
fi
if [ -n "$TARGET_DOZZLE" ] && [ "$PREV_DOZZLE" = "amir20/dozzle:$TARGET_DOZZLE" ]; then
    log "  dozzle: déjà à la version demandée, rien à faire"
    TARGET_DOZZLE=""
fi

if [ -z "$TARGET_PORTAINER$TARGET_DOZZLE" ]; then
    log "  aucune opération : la pile est déjà à l'état demandé."
    exit 0
fi

# 1. Copie du volume, uniquement si Portainer change de version.
if [ -n "$TARGET_PORTAINER" ] && [ "$NO_SNAPSHOT" = 0 ]; then
    log "  … copie du volume $VOLUME vers $SNAPSHOT_VOLUME"
    capturer_volume "$VOLUME" "$SNAPSHOT_VOLUME" \
        || die "copie du volume impossible : rollback annulé. « --no-snapshot » n'est pas une réponse — une base non copiée ne se rétrograde pas."
    log "  ✓ copie obtenue ($(docker run --rm -v "$SNAPSHOT_VOLUME:/s:ro" alpine:3 sh -c 'du -sh /s | cut -f1' 2>/dev/null || echo "?"))"
elif [ -n "$TARGET_PORTAINER" ]; then
    log "  ! rétrogradation SANS copie (--no-snapshot) : en cas d'échec, la base Bolt migrée ne sera pas récupérable par ce script."
fi

# 2. Rétrogradation proprement dite, une seule variable d'environnement posée
#    par service visé ; l'autre service garde son image courante.
export ADMIN_PORTAINER_IMAGE="${TARGET_PORTAINER:+portainer/portainer-ce:$TARGET_PORTAINER}"
export ADMIN_DOZZLE_IMAGE="${TARGET_DOZZLE:+amir20/dozzle:$TARGET_DOZZLE}"
[ -n "$ADMIN_PORTAINER_IMAGE" ] || export ADMIN_PORTAINER_IMAGE="${PREV_PORTAINER:-portainer/portainer-ce:2.45.3-alpine}"
[ -n "$ADMIN_DOZZLE_IMAGE" ] || export ADMIN_DOZZLE_IMAGE="${PREV_DOZZLE:-amir20/dozzle:v11.4.2-alpine}"

log "  … « compose up -d --no-deps » sur les seuls services visés"
compose up -d --no-deps ${TARGET_PORTAINER:+--force-recreate} "$SERVICE_PORTAINER" >/dev/null 2>&1 || true
compose up -d --no-deps ${TARGET_DOZZLE:+--force-recreate} "$SERVICE_DOZZLE" >/dev/null 2>&1 || true

# 3. Santé. Un échec sur Portainer déclenche le retour à l'image ET à la copie.
ECHEC=0
if [ -n "$TARGET_PORTAINER" ]; then
    attendre_sante "$SERVICE_PORTAINER" || ECHEC=1
fi
if [ -n "$TARGET_DOZZLE" ]; then
    attendre_sante "$SERVICE_DOZZLE" || ECHEC=1
fi

if [ "$ECHEC" = 1 ]; then
    log ""
    log "✗ la version visée ne tient pas. Retour à l'état précédent."
    if [ -n "$TARGET_PORTAINER" ] && [ -n "$PREV_PORTAINER" ]; then
        if [ "$NO_SNAPSHOT" = 0 ]; then
            log "  … arrêt de Portainer"
            compose stop "$SERVICE_PORTAINER" >/dev/null 2>&1 || true
            # Rien n'est écrasé sans copie : l'état laissé par la version qui a
            # échoué est lui aussi copié, pour qu'on puisse encore relire la
            # base migrée après coup. La règle « ne jamais écraser un volume
            # sans sauvegarde préalable » vaut y compris pour un échec.
            log "  … copie de l'état défaillant vers $FAILED_VOLUME"
            capturer_volume "$VOLUME" "$FAILED_VOLUME" \
                || log "  ! copie de l'état défaillant impossible : on restaure malgré tout la copie saine"
            log "  … restauration de la copie saine dans $VOLUME"
            restaurer_copie "$SNAPSHOT_VOLUME" "$VOLUME" \
                || log "  ! restauration refusée : la copie saine reste dans « $SNAPSHOT_VOLUME », voir docs/troubleshooting.md"
        fi
        export ADMIN_PORTAINER_IMAGE="$PREV_PORTAINER"
        compose up -d --no-deps --force-recreate "$SERVICE_PORTAINER" >/dev/null 2>&1
        if attendre_sante "$SERVICE_PORTAINER"; then
            log "  ✓ Portainer revenu sur $PREV_PORTAINER"
        else
            log "  ✗ Portainer toujours défaillant : copie saine dans « $SNAPSHOT_VOLUME », état migré dans « $FAILED_VOLUME », voir docs/troubleshooting.md"
        fi
    fi
    if [ -n "$TARGET_DOZZLE" ] && [ -n "$PREV_DOZZLE" ]; then
        export ADMIN_DOZZLE_IMAGE="$PREV_DOZZLE"
        compose up -d --no-deps --force-recreate "$SERVICE_DOZZLE" >/dev/null 2>&1
        if attendre_sante "$SERVICE_DOZZLE"; then
            log "  ✓ Dozzle revenu sur $PREV_DOZZLE"
        else
            log "  ✗ Dozzle toujours défaillant sur $PREV_DOZZLE"
        fi
    fi
    log ""
    log "Le rollback est annulé ; la copie de secours est conservée dans « $SNAPSHOT_VOLUME »."
    exit 1
fi

# 4. Vérification fonctionnelle minimale après changement de version.
if [ -n "$TARGET_PORTAINER" ]; then
    nom="$(conteneur_de "$SERVICE_PORTAINER")"
    if docker exec "$nom" sh -c "wget -S -O /dev/null http://127.0.0.1:9000/ 2>&1 | grep -qE 'HTTP/1.[01] [23]'"; then
        log "  ✓ interface Portainer servie sur la racaine"
    else
        log "  ! Portainer ne sert rien sur :9000 — « docker logs $(conteneur_de "$SERVICE_PORTAINER") »"
    fi
    # Les droits du volume doivent rester ouverts à la console de sauvegarde :
    # une nouvelle version recrée des fichiers en 0600. backup.sh le refait ;
    # le rappeler ici évite une nuit de job « partiel ».
    bash "$SCRIPT_DIR/backup.sh" --grant-only >/dev/null 2>&1 \
        && log "  ✓ droits du volume réouverts pour le groupe 33 de la console" \
        || log "  ! ouverture des droits échouée : relancer « scripts/backup.sh --grant-only »"
fi
if [ -n "$TARGET_DOZZLE" ]; then
    nom="$(conteneur_de "$SERVICE_DOZZLE")"
    if docker exec "$nom" /dozzle healthcheck >/dev/null 2>&1; then
        log "  ✓ healthcheck interne de Dozzle OK"
    else
        log "  ! healthcheck de Dozzle muet : à contrôler"
    fi
fi

# 5. Rendre le choix durable : une rétrogradation portée uniquement par
#    l'environnement disparaît au prochain « deploy.sh », qui relit compose.yaml.
#    Ce script ne réécrit pas un fichier versionné à la place de l'exploitant ;
#    il rend les deux lignes à reporter dans ../.env.
log ""
log "Pour rendre la version durable, reporter dans $REPO_DIR/.env :"
[ -n "$TARGET_PORTAINER" ] && log "  ADMIN_PORTAINER_IMAGE=portainer/portainer-ce:$TARGET_PORTAINER"
[ -n "$TARGET_DOZZLE" ] && log "  ADMIN_DOZZLE_IMAGE=amir20/dozzle:$TARGET_DOZZLE"

log ""
log "── état final ──"
compose ps
log ""
log "Contrôle complet : bash docker-admin/scripts/validate.sh"
log "Si la copie de secours n'est plus utile : docker volume rm $SNAPSHOT_VOLUME"
