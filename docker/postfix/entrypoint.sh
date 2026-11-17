#!/bin/sh
set -eu

# ---------------------------------------------------------------------------
# Valeurs de la machine. Elles viennent du .env versionné (cible) ou du
# compose.override.yaml (poste de développement) via compose.yaml ; celles que
# porte l'image ne sont qu'un repli pour un « docker run » nu.
# ---------------------------------------------------------------------------
: "${POSTFIX_MYHOSTNAME:=imouzzer.yabiladi.com}"
: "${POSTFIX_RELAY_NETWORKS:=}"
: "${OPENDKIM_DOMAIN:=yabiladi.com}"
: "${OPENDKIM_SELECTOR:=mail}"
# Où compose.yaml monte, en lecture seule, le dossier de clés de l'hôte
# (mêmes fichiers que ceux que le conteneur php du site lit déjà). Ce n'est PAS
# /run/opendkim : ce dernier doit rester inscriptible, le démon y écrit son pid
# après avoir quitté root, et un montage « :ro » sur ce chemin ferait échouer
# l'entrée « install -d » ci-dessous — donc tout le démarrage.
: "${OPENDKIM_KEYS_MOUNT:=/opt/dkim-keys}"
# La machine déclare-t-elle que CE relais est son seul expéditeur ? Sur la
# cible, oui : le Postfix Debian de l'autre machine est retiré, et tout le
# courrier du domaine sort d'ici. Un poste de développement laisse la valeur à
# 0, sinon son absence de clé — normale ici — crierait une fausse alerte à chaque
# démarrage.
: "${POSTFIX_DKIM_REQUIRED:=0}"
export POSTFIX_MYHOSTNAME

envsubst '${POSTFIX_MYHOSTNAME}' < /etc/postfix/main.cf.template > /etc/postfix/main.cf

# L'ordre des deux lignes ci-dessous n'est pas une préférence : le tas est un
# volume persistant et ses dossiers portent les uid/gid NUMÉRIQUES du compte
# « postfix » de l'image qui les a créés. Ces numéros bougent quand le contenu de
# l'image change — mesuré le 2026-11-17, l'ajout d'opendkim a déplacé « postfix »
# de 100 à 101 et a donné le 100 (l'ancien propriétaire de « defer ») à
# « opendkim » : « postfix check » échouait alors en boucle (« postsuper: fatal:
# scan_dir_push: open directory defer: Permission denied ») et « set -e » tuait le
# conteneur avant tout démarrage. « set-permissions » relit la table des comptes
# et rend chaque dossier à son propriétaire ACTUEL (mesuré : « defer »,
# « deferred » et « maildrop » repassés de opendkim à postfix, check revenu à 0) ;
# il doit donc précéder toute commande qui touche au tas.
postfix set-permissions
postfix check

# Sans chroot : le conteneur isole déjà, et une chroot imposerait de recopier
# resolv.conf, nsswitch.conf et la trousse de CA dans /var/spool/postfix.
postconf -F 'smtp/inet/chroot=n'
postconf -F 'smtp/unix/chroot=n'

# ---------------------------------------------------------------------------
# Clients autorisés. Postfix sait décrire les sous-réseaux de ses interfaces
# (mynetworks_style = subnet) : c'est cette liste, lue avant d'être écrasée,
# qui est complétée par les machines extérieures. Le CIDR du réseau Docker
# n'est pas connu à l'écriture du dépôt, donc rien n'est codé en dur ici.
# ---------------------------------------------------------------------------
set -f
trusted="$(postconf -h mynetworks) ${POSTFIX_RELAY_NETWORKS}"
set +f
trusted="$(printf '%s\n' "$trusted" | tr -s '[:space:]' ' ' | sed 's|^ ||; s| $||')"

postconf -e "mynetworks = ${trusted}"

# ---------------------------------------------------------------------------
# Signature DKIM. Sans clé montée (poste de développement), le relais démarre
# et remet sans signature, comme avant. Avec une clé refusée par le démon, le
# courrier passe encore — il reste aligné au SPF, donc au DMARC — mais le
# conteneur devient unhealthy et la ligne « fatal: » réveille l'alerte Grafana
# déjà branchée sur les journaux de ce service.
# ---------------------------------------------------------------------------
key_source="${OPENDKIM_KEYS_MOUNT}/${OPENDKIM_DOMAIN}/${OPENDKIM_SELECTOR}.private"
key_installed="/etc/opendkim/keys/${OPENDKIM_DOMAIN}/${OPENDKIM_SELECTOR}.private"
state_file=/run/opendkim.state
opendkim_state=off

if [ -f "$key_source" ]; then
    # La clé appartient au compte opendkim de l'hôte, dont l'uid n'est pas
    # celui du conteneur : root la lit et la redonne au démon, qui ne relit
    # jamais le montage.
    install -d -m 0700 -o opendkim -g opendkim /run/opendkim
    install -D -m 0400 -o opendkim -g opendkim "$key_source" "$key_installed"

    OPENDKIM_KEYFILE="$key_installed"
    # Les réseaux signés sont exactement ceux acceptés par Postfix. OpenDKIM ne
    # les accepte que par fichier (« InternalHosts », jamais la forme en ligne
    # « InternalNetworks », mesurée refusée par cette build) : la liste issue de
    # « postconf -h mynetworks » devient donc un fichier, une ligne par CIDR.
    printf '%s\n' "$trusted" | tr ' ' '\n' | sed '/^$/d' > /etc/opendkim/internal_hosts
    export OPENDKIM_DOMAIN OPENDKIM_SELECTOR OPENDKIM_KEYFILE
    envsubst '${OPENDKIM_DOMAIN} ${OPENDKIM_SELECTOR} ${OPENDKIM_KEYFILE}' \
        < /etc/opendkim.conf.template > /etc/opendkim.conf

    # « -n » = vérifier la configuration et la clé puis sortir : c'est ce
    # contrôle qui attrape une clé lisible mais mal formée, ou un sélecteur qui
    # ne correspond à rien, avant que le démon ne tourne. (« -t » ne fait PAS
    # cela : c'est « évaluer un message de test contenu dans le fichier passé en
    # argument » — mesuré sur --help de 2.11.0, et l'option exige cet argument.)
    /usr/sbin/opendkim -n -x /etc/opendkim.conf || opendkim_state=broken

    if [ "$opendkim_state" != broken ]; then
        # « -f » : ne pas s'arracher du terminal. Le démon reste donc enfant de
        # ce shell et garde erreur/sortie branchés sur les journaux du conteneur,
        # donc sur Loki sous service="postfix" — avec « Syslog no » dans
        # opendkim.conf, c'est le seul endroit où ses lignes existent. Le « & »
        # est ce qui permet au script d'aller jusqu'au « exec postfix » : lancé
        # au premier plan, il bloquerait l'entrée du conteneur pour toujours.
        # « -A » : repartir seul s'il tombe — un milter mort ne doit pas être
        # une panne silencieuse.
        /usr/sbin/opendkim -f -A -x /etc/opendkim.conf &
    fi

    if [ "$opendkim_state" != broken ]; then
        # Le pid ne se lit qu'après la preuve de vie : le démon l'écrit APRÈS
        # avoir quitté root (UserID opendkim:opendkim), donc dans un dossier que
        # l'« install -d » ci-dessus a dû lui donner. Attendre le fichier puis
        # « kill -0 » évite de déclarer le Milter vivant sur un pid jamais écrit.
        tries=0
        while [ "$tries" -lt 50 ] && { [ ! -s /run/opendkim/opendkim.pid ] \
            || ! kill -0 "$(cat /run/opendkim/opendkim.pid 2>/dev/null || echo 0)" 2>/dev/null; }
        do
            tries=$((tries + 1))
            sleep 0.2
        done
        if [ "$tries" -ge 50 ]; then
            opendkim_state=broken
        fi
    fi

    if [ "$opendkim_state" = broken ]; then
        echo "postfix/entrypoint: fatal: OpenDKIM n'a pas démarré, le courrier partira sans signature DKIM (clé $key_source)" >&2
    else
        postconf -e \
            "smtpd_milters = inet:127.0.0.1:8891" \
            "non_smtpd_milters = inet:127.0.0.1:8891"
        opendkim_state=on
        echo "postfix/entrypoint: OpenDKIM actif — sélecteur ${OPENDKIM_SELECTOR} de ${OPENDKIM_DOMAIN}, réseaux signés ${trusted}"
    fi
else
    if [ "$POSTFIX_DKIM_REQUIRED" = 1 ]; then
        # La machine a déclaré que le relais est son seul expéditeur. Sans clé,
        # le courrier partirait quand même — aligné au SPF, donc au DMARC — mais
        # sans la signature que le destinataire peut rejeter à lui seul, et sans
        # aucune trace dans les journaux de Postfix. Le « fatal: » est ici pour
        # réveiller l'alerte Grafana déjà branchée sur ce service (règle
        # container-postfix-crash) ; la file tourne quand même.
        echo "postfix/entrypoint: fatal: aucune clé DKIM à $key_source alors que POSTFIX_DKIM_REQUIRED=1 — le courrier part sans signature (montage du dossier de clés de l'hôte à contrôler)" >&2
        opendkim_state=unsigned
    else
        echo "postfix/entrypoint: aucune clé DKIM montée ($key_source) — relais non signé, attendu sur un poste de développement"
    fi
fi

printf '%s\n' "$opendkim_state" > "$state_file"

exec postfix start-fg
