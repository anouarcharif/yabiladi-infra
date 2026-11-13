#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Sauvegarde des données de Portainer, dans les clous de la console DBackup.
#
#   bash docker-admin/scripts/backup.sh                 # chaud : droits + job + preuve
#   bash docker-admin/scripts/backup.sh --grant-only    # les seuls droits (utilisé par deploy.sh)
#   bash docker-admin/scripts/backup.sh --quiesce       # froid : Portainer arrêté le temps de l'archive
#   bash docker-admin/scripts/backup.sh --check         # relire la dernière archive, sans rien lancer
#
# Le périmètre n'est pas décidé ici : c'est ../compose.yaml qui monte le volume
# « yabiladi_portainer_data » en lecture seule sous « /backup/portainer », et
# tools/backup/jobs.json qui déclare le job. Ce script ne fait que trois choses.
#
#  1. OUVRE LES DROITS — en rappel. Portainer écrit en root, sa base
#     « portainer.db » sort en 0600 root:root, et la console refuse de tourner en
#     root : son utilisateur 1001, groupe 33 (PGID de ../compose.yaml) ne lirait
#     rien. Le geste est fait DEPUIS le conteneur de Portainer — cette stack ne
#     touche donc que sa propre donnée, jamais un dossier de l'hôte. Il est déjà
#     fait à chaque démarrage par l'« entrypoint » du service (avec « umask 027 »
#     et les dossiers en « 2750 », pour que les fichiers nés en cours de route
#     soient archivables à la minute) : cette passe-ci est le filet, pas le
#     mécanisme. Sans lui, le job du soir saute la seule pièce qui ne se rejoue
#     pas.
#
#  2. DÉCLENCHE le job, si on le lui demande. La passe de nuit est réglée dans
#     la console (« 40 4 * * * », la dernière minute libre de la série) : ici,
#     c'est la preuve immédiate, ou la sauvegarde qu'on veut avant une retouche.
#
#  3. VÉRIFIE. Pas le statut vert de l'interface : le manifeste posé à côté du
#     TAR. Mesuré le 2026-11-12 sur cette console, une archive de 0 fichier est
#     déclarée « Success ». Un compte à zéro n'est donc pas un succès ici.
#
# CHAUD OU FROID. La passe de nuit est à chaud : Portainer n'est jamais arrêté
# par la sauvegarde, et sa base Bolt se relit telle quelle dans 99 cas sur 100.
# Le trou de cohérence est réel mais étroit — Bolt écrit par pages mmapées et
# garde deux méta-pages, dont une valide en cas de copie interrompue. « --quiesce »
# ferme complètement ce trou : « docker compose stop portainer », archive,
# « start » — dix secondes d'interface indisponible, aucun autre conteneur
# touché, et un « trap » qui remet Portainer debout même si l'archive échoue.
# À jouer avant une mise à jour de version, et au moins une fois pour valider la
# procédure.
# ============================================================================

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ADMIN_DIR="$(dirname -- "$SCRIPT_DIR")"
REPO_DIR="$(dirname -- "$ADMIN_DIR")"

JOB_NAME="portainer-volume-backup"
VOLUME="yabiladi_portainer_data"
COMPOSE_SERVICE="portainer"

GRANT_ONLY=0
QUIESCE=0
CHECK_ONLY=0
for a in "$@"; do
    case "$a" in
        --grant-only) GRANT_ONLY=1 ;;
        --quiesce) QUIESCE=1 ;;
        --check) CHECK_ONLY=1 ;;
        -h | --help) sed -n '4,43p' "$0"; exit 0 ;;
        *) printf 'ERREUR: option inconnue « %s »\n' "$a" >&2; exit 2 ;;
    esac
done

# Git Bash transforme /data en C:/data dans les arguments passés à docker exec.
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

log() { printf '%s\n' "$*"; }
die() { printf 'ERREUR: %s\n' "$*" >&2; exit 1; }

cd "$ADMIN_DIR"   # chemins relatifs à la pile : voir compose() en dessous

compose() {
    # Un « -f » empêche Compose de charger le « compose.override.yaml » voisin :
    # le nommer ici garde les mêmes conteneurs que deploy.sh.
    if [ -f compose.override.yaml ]; then
        docker compose --env-file ../.env -f compose.yaml -f compose.override.yaml "$@"
    else
        docker compose --env-file ../.env -f compose.yaml "$@"
    fi
}

# La console de sauvegarde vit dans l'autre projet du dépôt. Ce script ne la
# démarre pas, ne la recrée pas, ne la redémarre pas : il lui demande un job,
# par son conteneur courant, trouvé par étiquette Compose (jamais par un nom écrit
# en dur — « yabiladi-infra-dbackup-1 » changerait au premier changement de nom
# de projet, et la sonde se tairait).
conteneur_console() {
    docker ps -q \
        --filter label=com.docker.compose.service=dbackup \
        --filter status=running | head -1
}

# --- 1. Droits ---------------------------------------------------------------

ouvre_les_droits() {
    local cid
    cid="$(compose ps -q "$COMPOSE_SERVICE" 2>/dev/null | head -1)"
    [ -n "$cid" ] || { log "  · Portainer non démarré : rien à ouvrir"; return 1; }

    # « -type d » puis « -type f » plutôt qu'un « chmod -R g+rX » : le « X » de
    # GNU n'est pas garanti dans busybox, et un dossier sans bit d'exécution
    # devient invisible pour la console — qui ne le dit pas, elle archive moins.
    #
    # « 2750 », pas « 0750 » : le bit setgid est ce qui fait naître un fichier
    # NOUVEAU (une stack rangée dans « compose/ ») dans le groupe 33, donc
    # archivable dès la nuit suivante sans attendre un redémarrage. C'est le même
    # réglage que dans « compose.yaml » (l'entrée de Portainer se met elle-même
    # en état à chaque démarrage) ; écrit ici en 0750, il l'effacerait à chaque
    # passe — les deux gestes doivent dire la même chose.
    docker exec --user root "$cid" sh -c '
        base=/data
        chgrp -R 33 "$base" 2>/dev/null || exit 1
        find "$base" -type d -exec chmod 2750 {} + 2>/dev/null || exit 1
        find "$base" -type f -exec chmod 0640 {} + 2>/dev/null || exit 1
        ls -ld "$base"' >/dev/null || { log "  · ouverture des droits refusée dans le conteneur"; return 1; }

    # Contrôle, côté console : c'est elle qui lira, pas root. « docker exec »
    # sans « --user » tombe sur l'utilisateur de l'image — root ici — et ne prouverait
    # donc rien : le job, lui, lit en 1001:33 (PUID/PGID du service).
    local cid_console
    cid_console="$(conteneur_console)"
    if [ -n "$cid_console" ]; then
        lus="$(docker exec --user 1001:33 "$cid_console" sh -c 'find /backup/portainer -type f -readable 2>/dev/null | wc -l' 2>/dev/null || true)"
        total="$(docker exec --user 1001:33 "$cid_console" sh -c 'find /backup/portainer -type f 2>/dev/null | wc -l' 2>/dev/null || true)"
        if [ -n "$lus" ] && [ "$lus" -gt 0 ] 2>/dev/null; then
            log "  · volume lisible par la console : $lus fichier(s) sur ${total:-?} en uid 1001, groupe 33"
            [ "$lus" = "$total" ] || log "  ATTENTION : ${total:-?} fichier(s) dans le volume, ${lus:-0} seulement lisibles par la console — la part non lisible ne sera pas archivée"
        else
            log "  ATTENTION : « /backup/portainer » n'est pas monté ou pas lisible dans la console — ../compose.yaml a-t-il été redéployé depuis l'ajout du montage ? (« docker compose up -d dbackup » à la racine du dépôt)"
            return 1
        fi
    else
        log "  · console de sauvegarde non démarrée : contrôle de lecture reporté"
    fi
}

# --- 2. Job ------------------------------------------------------------------

lance_job() {
    local cid_console
    cid_console="$(conteneur_console)"
    [ -n "$cid_console" ] \
        || die "aucun conteneur « dbackup » en marche : la console de sauvegarde doit tourner avant de jouer un job"
    docker exec "$cid_console" test -f /opt/backup-tools/run-job.mjs \
        || die "« /opt/backup-tools/run-job.mjs » absent dans la console : relancer « bash deploy.sh » à la racine du dépôt (le montage suit le dépôt, mais la console doit être démarrée)"

    # « docker exec -i » sans terminal : le script node écrit sa progression sur
    # stderr, le résultat reste lisible ici.
    docker exec -i "$cid_console" node /opt/backup-tools/run-job.mjs "$JOB_NAME"
}

verifie_job() {
    local cid_console
    cid_console="$(conteneur_console)"
    [ -n "$cid_console" ] || die "aucune console de sauvegarde en marche"
    docker exec -i "$cid_console" node /opt/backup-tools/run-job.mjs --check "$JOB_NAME"
}

# --- parcours ----------------------------------------------------------------

# Le piège du mode froid, c'est l'échec au milieu : une console injoignable ou
# une archive en échec laisserait Portainer arrêté après coup. « trap » couvre
# la sortie, qu'elle soit propre ou non.
redemarre_portainer() {
    if [ "$PORTAINER_STOPPE" -eq 1 ]; then
        PORTAINER_STOPPE=0
        log "  remise en marche de Portainer…"
        if compose start "$COMPOSE_SERVICE" >/dev/null 2>&1; then
            log "  Portainer redémarré"
        else
            log "  ÉCHEC du redémarrage automatique — jouer : bash docker-admin/scripts/deploy.sh"
        fi
    fi
}
PORTAINER_STOPPE=0
trap redemarre_portainer EXIT


if [ "$CHECK_ONLY" -eq 1 ]; then
    log "── dernière archive de « $JOB_NAME » ──"
    verifie_job
    exit 0
fi

log "── sauvegarde des données de Portainer ──"
log "  droits du volume…"
ouvre_les_droits || die "sans droits ouverts, l'archive du soir ne contiendrait rien"

if [ "$GRANT_ONLY" -eq 1 ]; then
    log "  (--grant-only : aucun job déclenché)"
    exit 0
fi

if [ "$QUIESCE" -eq 1 ]; then
    log "  mode froid : Portainer s'arrête pour la durée de l'archive, rien d'autre"
    compose stop "$COMPOSE_SERVICE" >/dev/null
    PORTAINER_STOPPE=1
    log "  Portainer arrêté, archivage…"
    lance_job
    redemarre_portainer
else
    log "  passe à chaud (Portainer continue de répondre)…"
    lance_job
fi

log "  archive vérifiée."
