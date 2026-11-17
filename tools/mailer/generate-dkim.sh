#!/usr/bin/env bash
# Génère la clé privée d'UN SéLECTEUR DKIM pour le relais conteneurisé, et
# imprime l'enregistrement DNS TXT à publier en face.
#
# Depuis le 2026-11-17, le seul signeuse du domaine est le milter OpenDKIM du
# service « postfix » de ce dépôt : le signer applicatif Symfony est retiré, il
# produisait une seconde signature sur les mêmes messages. Ce script écrit donc
# là où CE conteneur lit ses clés — le dossier de l'hôte désigné par
# OPENDKIM_KEYS_DIR — et nulle part dans un var/ d'application.
#
# Usage (sur la machine du relais, avec le droit d'écrire dans le dossier) :
#   ./tools/mailer/generate-dkim.sh mail            # le sélecteur déjà publié
#   ./tools/mailer/generate-dkim.sh mail2           # une rotation
#
# Le script ne publie rien et ne redémarre rien : il refuse d'écraser une clé
# existante, parce que remplacer une clé sans avoir publié son TXT casse toute
# la signature du domaine en silence.
set -euo pipefail

SELECTEUR="${1:-}"
DOMAINE="${2:-yabiladi.com}"
[[ -n "$SELECTEUR" ]] || { printf 'Usage : %s <sélecteur> [domaine]\n' "$0" >&2; exit 1; }

RACINE="$(cd "$(dirname "$0")/../.." && pwd)"
# La même lecture que compose.yaml : la dernière affectation du .env versionné
# gagne, sinon le défaut d'hôte d'OpenDKIM.
CLE_DIR="$(grep -E '^OPENDKIM_KEYS_DIR=' "$RACINE/.env" 2>/dev/null | tail -1 | cut -d= -f2-)"
CLE_DIR="${CLE_DIR:-/etc/opendkim/keys}"
CHEMIN="$CLE_DIR/$DOMAINE/$SELECTEUR.private"

if [[ -e "$CHEMIN" ]]; then
    printf 'Refus : %s existe déjà.\n' "$CHEMIN" >&2
    printf 'Changer une clé sans avoir publié son TXT casse la signature de tout le domaine.\n' >&2
    exit 1
fi

# 2048 bits : le DNS du domaine publie encore une clé RSA 1024 héritée du V1, et
# la mise à niveau fait partie de la recette de bascule (beaucoup de destinataires
# la jugent faible ; la rotation se joue au moment où le TXT est remplacé).
mkdir -p "$CLE_DIR/$DOMAINE"
umask 077
openssl genrsa -out "$CHEMIN" 2048 2>/dev/null
chmod 0600 "$CHEMIN"

PUBLIQUE="$(openssl rsa -in "$CHEMIN" -pubout -outform DER 2>/dev/null | openssl base64 -A)"

printf 'Clé privée : %s\n\n' "$CHEMIN"
printf 'Enregistrement DNS à publier :\n'
printf '%s._domainkey.%s. 3600 IN TXT "v=DKIM1; k=rsa; p=%s"\n\n' "$SELECTEUR" "$DOMAINE" "$PUBLIQUE"
printf 'Après la propagation du TXT :\n'
printf "  1. OPENDKIM_SELECTOR=%s dans %s/.env (un commit : c'est une valeur de dépôt, pas de machine)\n" "$SELECTEUR" "$RACINE"
printf '  2. docker compose up -d --force-recreate postfix\n'
printf '  3. vérifier : docker compose exec postfix cat /run/opendkim.state   # « on »\n'
printf '     et     : docker compose exec postfix postconf -h smtpd_milters   # inet:127.0.0.1:8891\n'
printf '\nLa vérification du TXT est À FAIRE DE HORS EN DEDANS : « opendkim -n » ne lit pas le\n'
printf 'DNS (mesuré le 2026-11-17 — un sélecteur absent de la zone sort 0), et cette build ne\n'
printf 'porte ni « opendkim-genkey » ni « opendkim-testkey ». Comparer le « p= » publié :\n'
printf '  dig TXT %s._domainkey.%s +short\n' "$SELECTEUR" "$DOMAINE"
printf "à la ligne imprimée ci-dessus (ou depuis n'importe quel résolveur). Un sélecteur non\n"
printf "publié laisse le relais signer de bon cœur une clé que personne ne peut vérifier : les\n"
printf "journaux du conteneur ne diront rien, seul le destinataire constatera l'échec.\n"
