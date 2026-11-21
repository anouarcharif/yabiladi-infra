#!/usr/bin/env bash

# Identify the production node from its public IPv4 address and export the
# per-node administration hostnames consumed by the Infra, Symfony, and
# docker-admin stacks.
resolve_yabiladi_node() {
    local addresses expected

    if [ "${YABILADI_NODE:-}" = local ]; then
        if command -v ip >/dev/null 2>&1; then
            addresses="$(ip -o -4 addr show scope global | awk '{sub(/\/.*/, "", $4); print $4}')"
            case " $addresses " in
                *" 57.128.22.220 "* | *" 57.128.22.216 "*)
                    printf 'ERREUR: le profil local est interdit sur une IP de production (%s).\n' "$addresses" >&2
                    return 1
                    ;;
            esac
        fi
        export YABILADI_NODE=local
        export DAGU_HOSTNAME=dagu.yabiladi.com
        export DAGU_ALLOWED_HOSTS=dagu.yabiladi.com
        export DBACKUP_HOSTNAME=backups.yabiladi.com
        export DBACKUP_PUBLIC_URL=https://backups.yabiladi.com
        export GRAFANA_HOSTNAME=grafana.yabiladi.com
        export GRAFANA_ROOT_URL=https://grafana.yabiladi.com/
        export TRAEFIK_HOSTNAME=traefik.yabiladi.com
        export KOMODO_HOSTNAME=komodo.yabiladi.com
        export RADIO_NODE_ROLE=source
        export RADIO_RELAY_SERVER=
        return 0
    fi

    command -v ip >/dev/null 2>&1 || {
        printf 'ERREUR: iproute2 requis pour détecter le serveur.\n' >&2
        return 1
    }
    addresses="$(ip -o -4 addr show scope global | awk '{sub(/\/.*/, "", $4); print $4}')"

    case " $addresses " in
        *" 57.128.22.220 "*)
            YABILADI_NODE=tarourt
            expected=57.128.22.220
                RADIO_NODE_ROLE=source
                RADIO_RELAY_SERVER=
            ;;
        *" 57.128.22.216 "*)
            YABILADI_NODE=imouzzer
            expected=57.128.22.216
                RADIO_NODE_ROLE=relay
                RADIO_RELAY_SERVER=57.128.22.220
            ;;
        *)
            printf 'ERREUR: IP publique Yabiladi non reconnue (%s). Définir YABILADI_NODE=local uniquement pour un poste de développement.\n' "${addresses:-aucune}" >&2
            return 1
            ;;
    esac

    export YABILADI_NODE
    export DAGU_HOSTNAME="dagu-${YABILADI_NODE}.yabiladi.com"
    export DAGU_ALLOWED_HOSTS="$DAGU_HOSTNAME"
    export DBACKUP_HOSTNAME="backups-${YABILADI_NODE}.yabiladi.com"
    export DBACKUP_PUBLIC_URL="https://${DBACKUP_HOSTNAME}"
    export GRAFANA_HOSTNAME="grafana-${YABILADI_NODE}.yabiladi.com"
    export GRAFANA_ROOT_URL="https://${GRAFANA_HOSTNAME}/"
    export TRAEFIK_HOSTNAME="traefik-${YABILADI_NODE}.yabiladi.com"
    export KOMODO_HOSTNAME="komodo-${YABILADI_NODE}.yabiladi.com"
    export RADIO_NODE_ROLE RADIO_RELAY_SERVER DAGU_START_MODE
    DAGU_START_MODE=server
    printf 'Nœud détecté : %s (%s)\n' "$YABILADI_NODE" "$expected"
    printf 'Consoles : Dagu=%s DBackup=%s Grafana=%s Traefik=%s Komodo=%s\n' \
        "$DAGU_HOSTNAME" "$DBACKUP_HOSTNAME" "$GRAFANA_HOSTNAME" "$TRAEFIK_HOSTNAME" \
        "$KOMODO_HOSTNAME"
}
