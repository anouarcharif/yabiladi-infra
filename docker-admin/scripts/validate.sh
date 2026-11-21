#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ADMIN_DIR="$(dirname -- "$SCRIPT_DIR")"
REPO_DIR="$(dirname -- "$ADMIN_DIR")"
errors=0

ok() { printf '  OK  %s\n' "$*"; }
no() { printf '  ERR %s\n' "$*"; errors=$((errors + 1)); }

command -v docker >/dev/null 2>&1 || { echo 'Docker introuvable'; exit 2; }
docker info >/dev/null 2>&1 || { echo 'Démon Docker injoignable'; exit 2; }

node_profile="$REPO_DIR/deploy/node-profile.sh"
[ -f "$node_profile" ] || { echo "Profil serveur introuvable : $node_profile"; exit 2; }
. "$node_profile"
resolve_yabiladi_node || exit 2

cd "$ADMIN_DIR"
compose_args=(--env-file ../.env -f compose.yaml)
[ -f compose.override.yaml ] && compose_args+=(-f compose.override.yaml)

if docker compose "${compose_args[@]}" config -q >/dev/null 2>&1; then
    ok 'Compose docker-admin valide'
else
    no 'Compose docker-admin invalide'
fi

services=(komodo-periphery)
[ "$YABILADI_NODE" = tarourt ] || services=(komodo-mongo komodo-core komodo-periphery)
for service in "${services[@]}"; do
    cid="$(docker ps -q \
        --filter label=com.docker.compose.project=yabiladi-docker-admin \
        --filter "label=com.docker.compose.service=$service" | head -1)"
    [ -n "$cid" ] || { no "$service : conteneur absent"; continue; }

    state="$(docker inspect -f '{{.State.Status}}' "$cid")"
    restart="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$cid")"
    [ "$state" = running ] && ok "$service : running" || no "$service : $state"
    case "$restart" in unless-stopped | always) ok "$service : redémarrage $restart" ;; *) no "$service : redémarrage $restart" ;; esac

    published="$(docker port "$cid" 2>/dev/null || true)"
    if [ "$service" = komodo-core ]; then
        [ "$published" = "9120/tcp -> 127.0.0.1:9120" ] \
            && ok 'Komodo Core : port 9120 limité au loopback' \
            || no "Komodo Core : publication inattendue ($published)"
    else
        [ -z "$published" ] \
            && ok "$service : aucun port publié" \
            || no "$service : port publié ($published)"
    fi
done

periphery="$(docker ps -q \
    --filter label=com.docker.compose.project=yabiladi-docker-admin \
    --filter label=com.docker.compose.service=komodo-periphery | head -1)"
if [ -n "$periphery" ]; then
    envvars="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$periphery")"
    for setting in PERIPHERY_DISABLE_TERMINALS=true \
                   PERIPHERY_DISABLE_CONTAINER_TERMINALS=true \
                   PERIPHERY_CONTAINER_STATS_POLLING_RATE=5-sec \
                   PERIPHERY_ONBOARDING_KEY_FILE=/run/secrets/komodo-onboarding-key; do
        printf '%s\n' "$envvars" | grep -Fxq "$setting" \
            && ok "Periphery : $setting" \
            || no "Periphery : $setting absent"
    done
    if printf '%s\n' "$envvars" | grep -Eq '^(KOMODO_INIT_ADMIN_PASSWORD|PERIPHERY_ONBOARDING_KEY)='; then
        no 'Periphery : secret admin ou clé inline exposé dans les variables'
    else
        ok 'Periphery : aucun mot de passe admin ni onboarding inline'
    fi
    socket_mount="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/run/docker.sock"}}{{.Destination}}{{end}}{{end}}' "$periphery")"
    [ "$socket_mount" = /var/run/docker.sock ] \
        && ok 'Periphery : socket Docker montée' \
        || no 'Periphery : socket Docker absente'

    onboarding_file="$REPO_DIR/docker/legacy/komodo-onboarding-${YABILADI_NODE}.key"
    if [ -f "$onboarding_file" ] && [ -s "$onboarding_file" ]; then
        onboarding_mode="$(stat -c '%a' "$onboarding_file" 2>/dev/null || true)"
        [ "$onboarding_mode" = 600 ] \
            && ok "Cle d'onboarding : fichier present en mode 0600" \
            || no "Cle d'onboarding : mode incorrect (${onboarding_mode:-inconnu})"
    else
        no 'Clé d’onboarding : fichier absent ou vide'
    fi
fi

services_rendered="$(docker compose "${compose_args[@]}" config --services 2>/dev/null || true)"
for removed in dozzle docker-socket-proxy; do
    if printf '%s\n' "$services_rendered" | grep -Fxq "$removed"; then
        no "$removed : service toujours déclaré"
    else
        ok "$removed : retiré"
    fi
done

htpasswd="$REPO_DIR/docker/traefik/htpasswd/user_yabiladi"
if [ -f "$htpasswd" ] && grep -q '\$2[aby]\$' "$htpasswd"; then
    ok 'htpasswd partagé disponible'
else
    no 'htpasswd partagé absent ou invalide'
fi

if [ "$YABILADI_NODE" != tarourt ]; then
    code="$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 10 \
        --resolve "${KOMODO_HOSTNAME}:443:127.0.0.1" "https://${KOMODO_HOSTNAME}/" 2>/dev/null || true)"
    case "$code" in 200 | 301 | 302 | 401) ok "Komodo derrière Traefik : HTTP $code" ;; *) no "Komodo derrière Traefik : HTTP ${code:-000}" ;; esac
fi

if [ "$errors" -eq 0 ]; then
    printf '\nValidation docker-admin : OK\n'
    exit 0
fi

printf '\nValidation docker-admin : %d erreur(s)\n' "$errors"
exit 1
