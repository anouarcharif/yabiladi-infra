#!/bin/sh
# Sonde de santé du relais.
#
# Deux choses sont contrôlées, et aucune n'écrit dans les journaux :
#   - « postqueue -p » parle au démon showq par la socket du tas, ce qui prouve
#     que le maître Postfix sert vraiment. « postfix status » rendait le même
#     verdict, mais écrivait une ligne syslog à chaque appel — 2 880 lignes par
#     jour dans Loki, mesuré.
#   - le démon de signature, quand une clé lui a été confiée. Sa mort ne doit
#     pas couper le courrier (il partirait non signé, ce qui reste reçu au titre
#     du SPF aligné), mais elle doit rendre le conteneur unhealthy et sauter aux
#     yeux. Trois états sortent de entrypoint.sh : « on », « broken » (le démon
#     n'est pas là) et « unsigned » (aucune clé alors que la machine a déclaré
#     POSTFIX_DKIM_REQUIRED=1) — les deux derniers sont des échecs. « off » ne
#     l'est pas : c'est le poste de développement, sans clé par construction.
postqueue -p >/dev/null 2>&1 || exit 1

state="$(cat /run/opendkim.state 2>/dev/null || echo off)"

if [ "$state" = broken ] || [ "$state" = unsigned ]; then
    exit 1
fi

if [ "$state" = on ]; then
    pid="$(cat /run/opendkim/opendkim.pid 2>/dev/null || echo 0)"
    kill -0 "$pid" 2>/dev/null || exit 1
fi

exit 0
