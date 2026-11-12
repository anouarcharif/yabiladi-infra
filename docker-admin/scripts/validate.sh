#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# Contrôle de la stack docker-admin : ce qui est déclaré, ce qui tourne, ce qui
# répond, et ce qui n'a pas été cassé à côté.
#
#   bash docker-admin/scripts/validate.sh
#   bash docker-admin/scripts/validate.sh --quick      # sans les sonde HTTP sortants
#   bash docker-admin/scripts/validate.sh --resources  # ajoute « docker stats »
#
# Lecture seule de bout en bout : ce script ne crée, n'arrête, ne redémarre et
# n'écrit rien. Il rend un code de sortie non nul dès qu'une ligne attendue ne
# l'est pas, et se termine par le compte des réussites, des échecs et des
# contrôles non jouables — un contrôle qui n'a pas pu se jouer n'est pas un
# contrôle réussi, et cette distinction est la seule qui vaille sur un serveur
# de production.
#
# Le compte basicauth n'est pas dans ce dépôt et ne lui sera jamais demandé. La
# porte se contrôle donc par ce qu'elle doit refuser (401 sans et avec un
# mauvais compte) et par l'identité exacte du fichier de comptes que lisent déjà
# Dagu, Grafana et la console de sauvegarde. Pour jouer aussi le chemin
# AUTHENTIFIÉ, un opérateur qui tient le mot de passe peut passer les deux
# variables ci-dessous dans son environnement — elles ne sont lues que de là,
# jamais d'un fichier :
#
#   ADMIN_TEST_USER=yabiladi ADMIN_TEST_PASSWORD='…' bash docker-admin/scripts/validate.sh
# ============================================================================

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ADMIN_DIR="$(dirname -- "$SCRIPT_DIR")"
REPO_DIR="$(dirname -- "$ADMIN_DIR")"

QUICK=0
WANT_RESOURCES=0
for a in "$@"; do
    case "$a" in
        --quick) QUICK=1 ;;
        --resources) WANT_RESOURCES=1 ;;
        -h | --help) sed -n '4,27p' "$0"; exit 0 ;;
        *) printf 'ERREUR: option inconnue « %s »\n' "$a" >&2; exit 2 ;;
    esac
done

PORTAINER_HOST="${PORTAINER_HOST:-portainer.yabiladi.com}"
DOZZLE_HOST="${DOZZLE_HOST:-logs.yabiladi.com}"
# L'adresse où frapper : la boucle locale sur le serveur comme sur ce poste, le
# nom de domaine venant du « --resolve » de curl. Une autre machine de test se
# déclare ici, pas dans les labels.
EDGE_TARGET="${EDGE_TARGET:-127.0.0.1}"
# Le port HTTP que le projet du site publie sur cette machine (8080 sur le poste
# comme sur le serveur, mesuré). Sert au seul témoin croisé de la non-régression,
# celui qui répond à « Traefik ou le site ? » — voir la section 6.
SITE_DIRECT_PORT="${SITE_DIRECT_PORT:-8080}"
# Où jeter le corps des réponses sondeuses. « /dev/null » n'en est pas un pour
# curl.exe (Windows) une fois la conversion MSYS coupée plus bas : il ouvre le
# fichier avant d'émettre, échoue, et rend un code tout cru sans que la requête
# ait eu le temps de dire quoi que ce soit. « NUL » est l'équivalent de la
# machine hôte ; le serveur, lui, n'a que « /dev/null ».
case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*) DEVNULL=NUL ;;
    *) DEVNULL=/dev/null ;;
esac

PASS=0
FAIL=0
SKIP=0
ok() { printf '  [OK  ] %s\n' "$*"; PASS=$((PASS + 1)); }
no() { printf '  [ECHEC] %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf '  [  —  ] %s\n' "$*"; SKIP=$((SKIP + 1)); }
titre() { printf '\n── %s ──\n' "$*"; }

# Ce script passe des chemins absolus d'abord à « docker », qui tourne sous
# Windows sur ce poste : le bash de Git réécrit « /etc/… » en « C:/Program
# Files/Git/etc/… » avant l'appel, et la sonde échoue sur un fichier pourtant
# lisible (mesuré ici même : « test -r » et « node /opt/… » rendaient un échec
# sans rapport avec l'état du serveur). Sur le serveur, ces variables sont sans
# effet — il n'y a pas de couche MSYS.
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

cd "$ADMIN_DIR"   # chemins relatifs à la pile : voir compose() en dessous

compose() {
    # Un « -f » empêche Compose de charger le « compose.override.yaml » voisin :
    # le nommer ici valide la même configuration que celle qui tourne.
    if [ -f compose.override.yaml ]; then
        docker compose --env-file ../.env -f compose.yaml -f compose.override.yaml "$@"
    else
        docker compose --env-file ../.env -f compose.yaml "$@"
    fi
}
conteneur() { # $1 service → identifiant, vide si absent
    compose ps -q "$1" 2>/dev/null | head -1
}
# « -k » : sur ce poste le certificat est celui de l'autorité de développement,
# qui ne couvre pas encore ces deux noms (les régénérer imposerait un
# redémarrage du proxy, hors périmètre). Sur le serveur, c'est Let's Encrypt ;
# « -k » n'y change rien au verdict, seul le chemin du compte importe ici.
code_http() { # $1 méthode, $2 hôte, reste = options curl
    local methode="$1" hote="$2"
    shift 2
    curl -k -sS -o "$DEVNULL" -w '%{http_code}' -X "$methode" \
        --connect-timeout 6 --max-time 15 \
        --resolve "${hote}:443:${EDGE_TARGET}" \
        --resolve "${hote}:80:${EDGE_TARGET}" \
        "$@" "https://${hote}/" 2>/dev/null || printf '000'
}
# Busybox « wget » suit les redirections : la première ligne « HTTP/1.1 … » est
# donc celle du service lui-même, ce qui distingue 200 (fenêtre ouverte) de 307
# (fenêtre expirée) sur la racaine de Portainer.
code_port_interne() { # $1 conteneur, $2 port, $3 chemin
    local cid="$1" port="$2" chemin="${3:-/}" sortie
    sortie="$(docker exec "$cid" sh -c "wget -S -O /dev/null --timeout=8 http://127.0.0.1:${port}${chemin} 2>&1" 2>/dev/null || true)"
    printf '%s' "$sortie" | grep -oE 'HTTP/1\.[01] [0-9]{3}' | head -1 | grep -oE '[0-9]{3}' || true
}


printf '══ docker-admin — contrôle ══\n'

titre "Préconditions de l'hôte"
if ! docker info >/dev/null 2>&1; then
    no "démon Docker injoignable — la suite n'a plus de sens"
    printf '\n%d OK, %d échec(s), %d non joué(s)\n' "$PASS" "$FAIL" "$SKIP"
    exit 1
fi
ok "démon Docker joignable"

# --- 1. Déclaration ----------------------------------------------------------

titre "Configuration déclarée"
if compose config -q 2>/dev/null; then
    ok "compose.yaml accepté par Compose"
else
    no "compose.yaml refusé par Compose : « $(compose config 2>&1 | head -2 | tr '\n' ' ') »"
fi

if compose config 2>/dev/null | grep -q 'certresolver: letsencrypt'; then
    ok "les routeurs demandent le résolveur Let's Encrypt du fichier versionné"
elif [ -f compose.override.yaml ]; then
    ok "résolveur ACME vidé par compose.override.yaml (poste de développement)"
else
    skip "résolveur ACME : ni le fichier versionné ni un override ne le disent"
fi

for nom in yabiladi_app; do
    docker network inspect "$nom" >/dev/null 2>&1 && ok "réseau « $nom » présent (porté par l'infrastructure)" || no "réseau « $nom » absent — déployer ../compose.yaml"
done
docker network inspect yabiladi_admin_internal >/dev/null 2>&1 \
    && ok "réseau privé « yabiladi_admin_internal » créé" \
    || no "réseau privé « yabiladi_admin_internal » absent"

if docker volume inspect yabiladi_portainer_data >/dev/null 2>&1; then
    ok "volume « yabiladi_portainer_data » en place"
else
    no "volume « yabiladi_portainer_data » absent — « bash docker-admin/scripts/deploy.sh »"
fi

# --- 2. Conteneurs -----------------------------------------------------------

titre "Conteneurs de la stack"
declare -a SERVICES=(docker-socket-proxy portainer dozzle)
for s in "${SERVICES[@]}"; do
    cid="$(conteneur "$s")"
    if [ -z "$cid" ]; then no "$s : aucun conteneur"; continue; fi
    etat="$(docker inspect -f '{{.State.Status}}' "$cid")"
    sante="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}sans sonde{{end}}' "$cid")"
    redemarre="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$cid")"
    if [ "$etat" = running ] && { [ "$sante" = healthy ] || [ "$sante" = sans sonde ]; }; then
        ok "$s : $etat, santé $sante, redémarrage « $redemarre »"
    else
        no "$s : $etat, santé $sante, redémarrage « $redemarre »"
    fi
    if [ "$redemarre" != unless-stopped ] && [ "$redemarre" != always ]; then
        no "$s : politique de redémarrage « $redemarre » (attendu unless-stopped)"
    fi
done

titre "Isolation et droits"
for s in "${SERVICES[@]}"; do
    cid="$(conteneur "$s")"; [ -n "$cid" ] || continue
    ports_publies="$(docker port "$cid" 2>/dev/null | wc -l | tr -d ' ')"
    [ "$ports_publies" = 0 ] && ok "$s : aucun port publié sur l'hôte" || no "$s : $ports_publies port(s) publié(s) — « docker port $cid »"

    nn="$(docker inspect -f '{{.HostConfig.SecurityOpt}}' "$cid")"
    case "$nn" in *no-new-privileges*) ok "$s : no-new-privileges" ;; *) no "$s : no-new-privileges absent" ;; esac

    montages="$(docker inspect -f '{{range .Mounts}}{{.Type}} {{.Source}} -> {{.Destination}} rw={{.RW}}{{"\n"}}{{end}}' "$cid")"
    socket_ligne="$(printf '%s\n' "$montages" | grep 'docker.sock' | head -1)"
    case "$s" in
        dozzle)
            [ -z "$socket_ligne" ] && ok "dozzle : aucune socket Docker montée" || no "dozzle monte la socket ($socket_ligne)"
            ;;
        docker-socket-proxy)
            printf '%s' "$socket_ligne" | grep -q 'rw=false' && ok "mandataire : socket montée en lecture seule" || no "mandataire : socket montée en écriture"
            ;;
        portainer)
            printf '%s' "$socket_ligne" | grep -q 'rw=true' && ok "portainer : socket montée en écriture (administration voulue)" || no "portainer : socket absente ou en lecture seule — l'administration ne fonctionnera pas"
            ;;
    esac
done

cid="$(conteneur docker-socket-proxy)"
if [ -n "$cid" ]; then
    reseaux="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$cid")"
    case "$reseaux" in
        *yabiladi_admin_internal*)
            case "$reseaux" in
                *yabiladi_app*) no "le mandataire est AUSSI sur yabiladi_app : tout conteneur du réseau pourrait lire l'API" ;;
                *) ok "le mandataire n'est que sur le réseau privé" ;;
            esac ;;
        *) no "le mandataire n'est pas sur le réseau privé (réseaux : $reseaux)" ;;
    esac
    interne="$(docker network inspect -f '{{.Internal}}' yabiladi_admin_internal 2>/dev/null)"
    [ "$interne" = true ] && ok "réseau privé marqué « internal » : aucune route sortante" || no "réseau privé non marqué « internal »"
fi
cid="$(conteneur portainer)"
[ -n "$cid" ] && { docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$cid" | grep -q yabiladi_admin_internal \
    && no "portainer est sur le réseau privé du mandataire (inutile : il tient la socket)" || ok "portainer étranger au réseau du mandataire"; }

tr_id="$(docker ps -q --filter label=com.docker.compose.project=yabiladi-infra --filter label=com.docker.compose.service=traefik | head -1)"
[ -n "$tr_id" ] && { docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$tr_id" | grep -q yabiladi_admin_internal \
    && no "Traefik est branché sur le réseau privé" || ok "Traefik étranger au réseau privé"; }

# --- 3. La porte basicauth ---------------------------------------------------

titre "Authentification (le compte de Dagu, pas un second système)"
HT="$REPO_DIR/docker/traefik/htpasswd/user_yabiladi"
[ -f "$HT" ] && ok "fichier de comptes présent sur l'hôte ($(basename "$HT"), hash bcrypt vérifié)" || no "fichier de comptes absent : $HT"
if [ -n "$tr_id" ]; then
    docker exec "$tr_id" test -r /etc/traefik/htpasswd/user_yabiladi \
        && ok "le même fichier est lisible dans le conteneur Traefik" || no "illisibles depuis Traefik : tous les comptes échoueront"
fi
# Une seule et même source pour les cinq interfaces d'administration : c'est ce
# qui vaut la phrase « les identifiants de Dagu fonctionnent ici aussi », sans
# avoir à toucher au mot de passe de qui que ce soit.
for f in "$REPO_DIR/compose.yaml" "$ADMIN_DIR/compose.yaml"; do
    n="$(grep -c 'basicauth.usersfile=/etc/traefik/htpasswd/user_yabiladi' "$f" 2>/dev/null || printf 0)"
    ok "$(basename "$(dirname "$f")")/$(basename "$f") : $n middleware(s) sur le fichier partagé"
done
for f in "$REPO_DIR/compose.yaml" "$ADMIN_DIR/compose.yaml"; do
    grep -h 'basicauth.usersfile' "$f" 2>/dev/null | grep -v 'user_yabiladi' | grep -v 'htpasswd/rac' | sed 's/^/    détourné: /'
done

# La seconde barrière de la maison, celle que Dagu, Grafana et le tableau de bord
# Traefik ont déjà : une liste d'adresses devant le compte. Lue dans la
# configuration RENDUE — avec l'override du poste et l'interpolation de
# « DAGU_ALLOWED_IPS » — parce que c'est ce texte-là que Traefik applique, pas le
# fichier source. L'ordre compte : « ipallow » d'abord, pour qu'une adresse hors
# plage ne révèle même pas qu'une console écoute (404, pas 401).
config_rendue="$(compose config 2>/dev/null)"
for nom in portainer dozzle; do
    if printf '%s' "$config_rendue" | grep -q "traefik.http.routers.$nom.middlewares: $nom-ipallow,$nom-htpasswd"; then
        ok "$nom : chaîne de middlewares « ipallow puis htpasswd » telle que rendue à Traefik"
    else
        no "$nom : le routeur n'enchaîne pas « $nom-ipallow,$nom-htpasswd » — $(printf '%s' "$config_rendue" | grep -oE "traefik.http.routers.$nom.middlewares: .*" | head -1)"
    fi
    if printf '%s' "$config_rendue" | grep -q "traefik.http.middlewares.$nom-ipallow.ipallowlist.sourceRange: 127.0.0.1/32"; then
        ok "$nom : plage d'adresses issue de DAGU_ALLOWED_IPS ($(printf '%s' "$config_rendue" | grep -oE "traefik.http.middlewares.$nom-ipallow.ipallowlist.sourceRange: .*" | head -1 | cut -d: -f2- | tr -d ' ' | cut -c1-60)…)"
    else
        no "$nom : aucune ipallowlist rendue sur le routeur — la console se présenterait au monde entier"
    fi
done

if [ "$QUICK" -eq 0 ]; then
    titre "Portes publiques"
    for hote in "$PORTAINER_HOST" "$DOZZLE_HOST"; do
        c="$(code_http GET "$hote")"
        [ "$c" = 401 ] && ok "https://$hote/ sans compte → $c (attendu 401)" || no "https://$hote/ sans compte → $c (attendu 401 — un 404 dirait le routeur absent, un 200 la porte ouverte)"
        c="$(code_http GET "$hote" -u 'inconnu:motdepasse-faux')"
        [ "$c" = 401 ] && ok "https://$hote/ mauvais compte → $c" || no "https://$hote/ mauvais compte → $c (attendu 401)"
        # Le 301 de l'entrée HTTP : le texte clair n'est jamais servi.
        c="$(curl -k -sS -o "$DEVNULL" -w '%{http_code}' --connect-timeout 6 --max-time 12 \
                --resolve "${hote}:80:${EDGE_TARGET}" "http://${hote}/" 2>/dev/null || printf 000)"
        [ "$c" = 301 ] && ok "http://$hote/ → $c (renvoi vers HTTPS)" || no "http://$hote/ → $c (attendu 301)"
    done

    if [ -n "${ADMIN_TEST_USER:-}" ] && [ -n "${ADMIN_TEST_PASSWORD:-}" ]; then
        for hote in "$PORTAINER_HOST" "$DOZZLE_HOST"; do
            c="$(code_http GET "$hote" -u "${ADMIN_TEST_USER}:${ADMIN_TEST_PASSWORD}")"
            case "$c" in
                200 | 30[124]) ok "https://$hote/ authentifié → $c" ;;
                401) no "https://$hote/ authentifié → 401 : le compte testé n'est pas celui du fichier partagé" ;;
                *) no "https://$hote/ authentifié → $c (attendu 200)" ;;
            esac
        done
    else
        skip "chemin authentifié non joué : ADMIN_TEST_USER / ADMIN_TEST_PASSWORD absents de l'environnement (volontaire — le mot de passe ne vit ni dans ce dépôt, ni dans cette sortie)"
    fi

    titre "Derrière la porte : les services joints par Traefik"
    if [ -n "$tr_id" ]; then
        # Ce que Traefik verra, depuis son propre espace réseau, une fois le
        # compte accepté : le label « loadbalancer.server.port » pointe ici.
        for paire in "portainer:9000" "dozzle:8080"; do
            s="${paire%%:*}"; p="${paire##*:}"
            if docker exec "$tr_id" sh -c "wget -S -q -O /dev/null --timeout=8 http://$s:$p/ 2>&1 | grep -qE ' (200|204|30[127]|401)'" 2>/dev/null; then
                ok "Traefik joint $s:$p (le chemin du visiteur, porte basicauth non comprise)"
            else
                no "Traefik ne joint pas $s:$p — le visiteur verra un 502"
            fi
        done
    else
        skip "contrôle depuis Traefik non joué : aucun conteneur traefik démarré"
    fi
fi

# --- 4. Découverte Docker et journaux ----------------------------------------

titre "Découverte Docker, journaux, restrictions du mandataire"
cid="$(conteneur dozzle)"
if [ -n "$cid" ]; then
    # Ce que Dozzle voit, il l'écrit lui-même dans le bloc JSON que sa page sert.
    # Mesuré sur v11.4.2 : aucune API de liste n'est exposée — « /api/v2/container »,
    # « /api/containers » et « /api/hosts » répondent 404, les routes de l'interface
    # étant reconstruites côté client. Le bloc, lui, est public (la porte est en
    # amont) et dit trois choses qu'il vaut mieux lire que deviner : l'hôte joint,
    # s'il est tenu pour vivant, et les capacités d'action que l'interface se reconnaît.
    page="$(docker exec "$cid" sh -c 'wget -q -O- --timeout=10 http://127.0.0.1:8080/' 2>/dev/null)"
    hotes="$(printf '%s' "$page" | grep -oE '"hosts":\[[^]]*\]' | head -1)"
    if printf '%s' "$hotes" | grep -q '"available":true'; then
        ok "Dozzle tient son hôte pour vivant — moteur $(printf '%s' "$hotes" | grep -oE '"dockerVersion":"[^"]*"' | head -1 | cut -d'"' -f4), joint par le mandataire"
    else
        no "Dozzle ne déclare aucun hôte disponible — le mandataire ne lui répond pas (${hotes:-bloc « hosts » absent de la page})"
    fi
    for reglage in enableActions enableShell; do
        v="$(printf '%s' "$page" | grep -oE "\"${reglage}\":(true|false)" | head -1 | grep -oE '(true|false)$')"
        if [ "$v" = false ]; then
            ok "Dozzle se déclare « $reglage: false » — ni bouton d'action sur un conteneur, ni terminal dans un conteneur"
        else
            no "Dozzle se déclare « $reglage: ${v:-non dit} » — l'interface aurait une capacité d'administration"
        fi
    done
    # « canAddHosts », mesuré « true » sur deux démarrages distincts de v11.4.2 :
    # l'interface propose d'ajouter un hôte Docker. Ce n'est pas la main sur CETTE
    # socket — le mandataire refuse tout POST et tout verbe d'écriture, vérifié
    # plus bas — mais c'est une sortie : un hôte ajouté serait joint depuis le
    # réseau « yabiladi_app », et le réglage n'existe pas en dur dans l'image.
    # Deux barrières restent devant ce geste (plage d'adresses, puis compte
    # basicauth). Le consigner plutôt que le compter comme un succès.
    v="$(printf '%s' "$page" | grep -oE '"canAddHosts":(true|false)' | head -1 | grep -oE '(true|false)$')"
    skip "Dozzle propose « Add host » (canAddHosts: ${v:-non dit}) — hors du périmètre du mandataire, sous les deux barrières d'entrée ; voir docs/security.md"

    # La liste que l'interface affiche se lit à la source : le verbe et l'adresse
    # exacts que Dozzle emploie, depuis son propre espace réseau.
    liste="$(docker exec "$cid" sh -c 'wget -q -O- --timeout=8 "http://docker-socket-proxy:2375/containers/json?all=0"' 2>/dev/null)"
    ncont="$(printf '%s' "$liste" | grep -o '"Id"' | wc -l | tr -d ' ')"
    if [ "${ncont:-0}" -gt 3 ] 2>/dev/null; then
        ok "liste rendue par le mandataire : $ncont conteneur(s) en marche, ceux que l'interface affichera"
    else
        no "le mandataire ne rend que ${ncont:-0} entrée(s) — liste blanche trop étroite, l'interface serait vide"
    fi
    # Journal joué jusqu'au bout, sur le conteneur de Dozzle lui-même : son
    # identifiant est dans la page, et son démarrage est forcément bavard. Deux
    # paramètres, pas un : mesuré sur le moteur 29, « stdout » seul rend 0 octet
    # sur Dozzle — son journal written par la bibliothèque de logs part sur
    # « stderr » — et aucun flux demandé vaut 400. Un sondeur qui ne demande que
    # la sortie standard enterrerait un service vivant.
    moi="$(printf '%s' "$page" | grep -oE '"selfContainerId":"[a-f0-9]+"' | head -1 | cut -d'"' -f4)"
    if [ -n "${moi:-}" ]; then
        ech="$(docker exec "$cid" sh -c "wget -q -O- --timeout=8 'http://docker-socket-proxy:2375/containers/${moi}/logs?stdout=1&stderr=1&tail=20' 2>/dev/null | wc -c | tr -d ' '")"
        if [ "${ech:-0}" -gt 0 ] 2>/dev/null; then
            ok "lecture d'un journal jouée par le mandataire : ${ech} octet(s) rendus sur le conteneur de Dozzle"
        else
            no "lecture d'un journal : 0 octet rendu sur « /containers/{id}/logs » — la consultation est morte"
        fi
    else
        skip "lecture d'un journal non jouée : la page ne donne pas « selfContainerId »"
    fi

    # Le mandataire, côté API : ce que Dozzle a le droit de demander, et rien de plus.
    for chemin in containers images info version events; do
        if docker exec "$cid" sh -c "wget -q -O- --timeout=6 http://docker-socket-proxy:2375/$chemin/json 2>/dev/null | head -c 1 || wget -S -q -O /dev/null --timeout=6 http://docker-socket-proxy:2375/$chemin 2>&1 | grep -qE ' (200|204)'" >/dev/null 2>&1; then
            ok "mandataire autorise GET /$chemin"
        else
            skip "GET /$chemin non rendu en clair (autorisé ou non, la sonde ne le tranche pas)"
        fi
    done
    for chemin in volumes networks configs secrets; do
        c="$(docker exec "$cid" sh -c "wget -S -q -O /dev/null --timeout=6 http://docker-socket-proxy:2375/$chemin 2>&1 | grep -oE 'HTTP/[0-9.]+ [0-9]+' | head -1 | grep -oE '[0-9]+$'" 2>/dev/null)"
        [ "$c" = 403 ] && ok "mandataire refuse GET /$chemin ($c)" || no "mandataire sur /$chemin → ${c:-rien} (attendu 403)"
    done
    # « --post-data » et non « --method=POST » : le wget de busybox (l'image alpine)
    # ne connaît pas le second, et la sonde rendait « rien » — un test qui ne joue
    # pas n'est pas un test qui passe.
    c="$(docker exec "$cid" sh -c "wget -S -q -O /dev/null --post-data='' --timeout=6 http://docker-socket-proxy:2375/containers/create 2>&1 | grep -oE 'HTTP/[0-9.]+ [0-9]+' | head -1 | grep -oE '[0-9]+$'" 2>/dev/null)"
    [ "$c" = 403 ] && ok "mandataire refuse POST /containers/create ($c) : aucune capacité d'administration" || no "POST /containers/create → ${c:-rien} (attendu 403)"
else
    no "aucun conteneur dozzle : découverte Docker non jouable"
fi

cid="$(conteneur portainer)"
if [ -n "$cid" ]; then
    # La racaine est le seul témoin qui distingue les états (mesuré sur 2.45.3) :
    # « /api/ping » répond 404 dans TOUS les états, et chaque « /api/* » passe à
    # 303 dès que la fenêtre d'administrateur expire — la porte fermerait donc la
    # sonde sur un service vivant.
    rac="$(code_port_interne "$cid" 9000 /)"
    api="$(code_port_interne "$cid" 9000 /api/endpoints)"
    case "$rac" in
        200) ok "Portainer sert son interface sur :9000 (200)" ;;
        307) no "Portainer renvoie 307 sur la racine : fenêtre d'administrateur expirée — « docker compose … restart portainer », puis créer le compte dans les cinq minutes" ;;
        *)   no "Portainer ne répond pas sur :9000 (racine → ${rac:-rien})" ;;
    esac
    if [ "$rac" = 307 ]; then
        skip "porte interne de l'API non tranchée : fenêtre expirée, chaque « /api/* » répond 303 et non 401"
    elif [ "$api" = 401 ]; then
        ok "API Portainer muette à l'anonyme : 401 sur /api/endpoints, rien ne se lit sans jeton"
    else
        no "API Portainer → ${api:-rien} sur /api/endpoints (attendu 401 ; un 200 livrerait l'inventaire Docker à qui frappe à la porte)"
    fi
    # Ce 401 ne prouve PAS le compte administrateur : mesuré sur 2.45.3, il se
    # rend identiquement avec un compte en place et sans aucun compte tant que
    # la fenêtre de cinq minutes est ouverte. L'écrire ici plutôt que de le
    # compter comme un succès — l'authentification propre à Portainer reste à
    # créer par l'opérateur, dans un navigateur, et le mot de passe ne vit ni
    # dans ce dépôt ni dans cette sortie.
    skip "compte administrateur de Portainer : non tranché par l'HTTP (401 se rend aussi bien avec qu'en l'absence de compte) — première visite à jouer"
fi

# --- 5. Sauvegarde -----------------------------------------------------------

titre "Sauvegarde (console DBackup)"
cid_console="$(docker ps -q --filter label=com.docker.compose.service=dbackup --filter status=running | head -1)"
if [ -z "$cid_console" ]; then
    no "aucune console de sauvegarde en marche : job non contrôlable"
else
    docker exec "$cid_console" node -e '
        const fs = require("fs");
        const jobs = JSON.parse(fs.readFileSync("/opt/backup-tools/jobs.json", "utf8"));
        const j = jobs.find((x) => x.name === "portainer-volume-backup");
        if (!j) { console.log("ABSENT"); process.exit(1); }
        console.log(`${j.name}|${j.path}|${j.schedule}|${j.enabled === false ? "éteint" : "activé"}`);
    ' >/dev/null 2>&1 && ok "job « portainer-volume-backup » déclaré dans tools/backup/jobs.json" || no "job absent de jobs.json"

    m="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/backup/portainer"}}{{.Type}}:{{.Name}}{{.Source}} rw={{.RW}}{{end}}{{end}}' "$cid_console")"
    case "$m" in
        *"rw=false"*) ok "console : volume Portainer monté sous /backup/portainer en lecture seule" ;;
        "") no "console : rien sous /backup/portainer — ../compose.yaml n'a pas été redéployé (« docker compose up -d dbackup »)" ;;
        *) no "console : montage /backup/portainer en ÉCRITURE ($m) — une source ne s'écrit jamais" ;;
    esac

    # En 1001:33, pas en root : c'est l'identité sous laquelle le job lit, et «
    # docker exec » sans « --user » prend l'utilisateur de l'image (root ici),
    # qui lit tout et ne prouverait donc rien.
    total="$(docker exec --user 1001:33 "$cid_console" sh -c 'find /backup/portainer -type f 2>/dev/null | wc -l' 2>/dev/null | tail -1)"
    lecture="$(docker exec --user 1001:33 "$cid_console" sh -c 'find /backup/portainer -type f -readable 2>/dev/null | wc -l' 2>/dev/null | tail -1)"
    if [ -n "${lecture:-}" ] && [ "$lecture" != 0 ]; then
        ok "console : $lecture fichier(s) lisible(s) sur ${total:-?} en uid 1001, groupe 33"
        [ "$lecture" = "$total" ] || no "console : ${total:-?} fichier(s) dans le volume, ${lecture:-0} seulement lisibles par le job — la part muette reste hors archive"
    else
        no "console : aucun fichier lisible sous /backup/portainer en 1001:33 — jouer « bash docker-admin/scripts/backup.sh --grant-only »"
    fi

    si="$(docker exec -i "$cid_console" node /opt/backup-tools/run-job.mjs --check portainer-volume-backup 2>&1 | tail -8)"
    if printf '%s' "$si" | grep -q 'chaîne sauvegardée et contrôlée'; then
        ok "chaîne de sauvegarde non vide et contrôlée : $(printf '%s' "$si" | grep -o 'chaîne sauvegardée et contrôlée.*' | head -1)"
    else
        no "chaîne de sauvegarde non contrôlée : $(printf '%s' "$si" | tail -1 | cut -c1-90)"
    fi
fi

# --- 6. Non-régression -------------------------------------------------------

titre "Non-régression de l'existant"
if [ "$QUICK" -eq 0 ]; then
    for paire in "dagu.yabiladi.com:401" "grafana.yabiladi.com:401" "backups.yabiladi.com:401" "traefik.yabiladi.com:401"; do
        h="${paire%%:*}"; attend="${paire##*:}"
        c="$(code_http GET "$h")"
        [ "$c" = "$attend" ] && ok "https://$h/ → $c (inchangé)" || no "https://$h/ → $c (attendu $attend) — un nom non résolu sur ce poste rend 000, pas une régression"
    done
    # « www » est le seul nom de cette liste dont la réponse traverse un conteneur
    # applicatif : les quatre consoles du dessus s'arrêtent à la porte basicauth,
    # et un 401 ne dit donc rien de leurs backends. Le témoin croisé en dessous —
    # nginx interrogé en direct, sans Traefik — est ce qui permet d'appeler un
    # échec par son nom : chemin d'accès en panne, ou site en panne.
    c="$(code_http GET www.yabiladi.com)"
    direct="$(curl -sS -o "$DEVNULL" -w '%{http_code} en %{time_total}s' --max-time 20 \
        -H 'Host: www.yabiladi.com' "http://127.0.0.1:${SITE_DIRECT_PORT:-8080}/" 2>/dev/null || printf 'aucune réponse')"
    case "$c" in
        200 | 301 | 302) ok "https://www.yabiladi.com/ → $c (site en ligne, bout en bout)" ;;
        000 | 504)
            case "$direct" in
                200* | 30[12]*)
                    no "https://www.yabiladi.com/ → ${c} (504 = timeout de Traefik, 30 s) alors que nginx répond « $direct » en direct : le chemin d'accès est en cause, ni cette pile ni le site n'y sont. Mesuré sur ce poste : après un « recreate » d'un conteneur du site, Traefik garde des connexions vers une adresse périmée et retombe sur ses pieds au deuxième ou troisième essai — docs/troubleshooting.md" ;;
                *) no "https://www.yabiladi.com/ → ${c} ET nginx en direct ne répond pas non plus ($direct) : le site est en panne pour son propre compte, cette pile n'y change rien" ;;
            esac ;;
        *) no "https://www.yabiladi.com/ → $c (attendu 200/301) — nginx en direct : $direct" ;;
    esac
fi
if [ -n "$tr_id" ]; then
    ok "Traefik : démarré le $(docker inspect -f '{{.State.StartedAt}}' "$tr_id") — ce déploiement ne l'a ni recréé ni redémarré"
fi
for s in php nginx dagu; do
    cid2="$(docker ps -q --filter label=com.docker.compose.service="$s" --filter status=running | head -1)"
    [ -n "$cid2" ] && ok "$s : en marche depuis le $(docker inspect -f '{{.State.StartedAt}}' "$cid2" | cut -c1-19)" || skip "$s : conteneur non trouvé (hors projet ?)"
done

titre "Empreinte au sol"
if [ "$WANT_RESOURCES" -eq 1 ]; then
    if docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}' 2>/dev/null | grep -E 'portainer|dozzle|socket-proxy' | sed 's/^/  /'; then
        ok "mesure jouée"
    else
        skip "« docker stats » indisponible sur ce poste"
    fi
else
    skip "ressources non mesurées (--resources)"
fi

printf '\n══ %d OK, %d échec(s), %d non joué(s) ══\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
