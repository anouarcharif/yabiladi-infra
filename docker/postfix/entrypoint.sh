#!/bin/sh
set -eu

: "${POSTFIX_MYHOSTNAME:=tarourt.yabiladi.com}"
export POSTFIX_MYHOSTNAME

envsubst '${POSTFIX_MYHOSTNAME}' < /etc/postfix/main.cf.template > /etc/postfix/main.cf

# Le volume de file d'attente arrive vide : Postfix crée les sous-dossiers puis
# rétablit leurs propriétaires (postdrop, maildrop) depuis postfix-files.
postfix check
postfix set-permissions

# Sans chroot : le conteneur isole déjà, et une chroot imposerait de recopier
# resolv.conf, nsswitch.conf et la trousse de CA dans /var/spool/postfix.
postconf -F 'smtp/inet/chroot=n'
postconf -F 'smtp/unix/chroot=n'

exec postfix start-fg
