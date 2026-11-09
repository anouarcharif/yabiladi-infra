#!/usr/bin/env bash
set -euo pipefail

# Génère un compte basicauth pour Traefik dans docker/traefik/htpasswd/<compte>.
# <compte> est le NOM DU FICHIER que lit le middleware (« basicauth.usersfile »),
# pas un nom d'utilisateur : « user_yabiladi » sert dagu, grafana, dbackup et le
# tableau de bord ; « rac » sert le bac à sable.
#
# Le clair ne va pas dans git, et ne se pose plus à la main sur le serveur : la
# source de vérité est le coffre (deploy/secrets.manifest). Le parcours complet,
# depuis le poste de développement :
#
#   bash docker/traefik/generate-htpasswd.sh --force user_yabiladi <nom> <mdp>
#   bash deploy.sh --encrypt
#   git add deploy/secrets/htpasswd_user_yabiladi.sops.bin && git commit && git push
#   # serveur : bash deploy.sh — matérialise le compte, puis redémarre Traefik si
#   # l'empreinte des fichiers a changé.
#
# Un compte écrit à la main sur le serveur est écrasé au déploiement suivant : ce
# n'est plus l'endroit où ça se joue.
#
# Traefik v3 ne connaît QUE bcrypt ($2y$) : htpasswd sans -B, « openssl passwd
# -1 » et les hash MD5/apr1 d'un .htpasswd Apache classique sont refusés en
# silence — aucun mot de passe ne passe alors. Après écriture, redémarrer
# Traefik : le fichier est lu au chargement de la configuration, pas à chaque
# requête (mesuré le 2026-11-01).
#
# Usage :
#   bash docker/traefik/generate-htpasswd.sh user_yabiladi yabiladi 'motdepasse'
#   bash docker/traefik/generate-htpasswd.sh --force user_yabiladi yabiladi 'nouveau'
#   bash docker/traefik/generate-htpasswd.sh rac admin 'motdepasse'
#   bash docker/traefik/generate-htpasswd.sh          # = user_yabiladi / admin / mot de passe de dev

HTPASSWD_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/htpasswd"

FORCE=0
if [[ "${1:-}" == "--force" ]]; then
    FORCE=1
    shift
fi

ACCOUNT="${1:-user_yabiladi}"
HTUSER="${2:-admin}"
# Valeur de repli pour un poste de développement, jamais pour un serveur : le mot
# de passe réel se passe en troisième argument, et ne s'écrit nulle part d'autre
# que dans le fichier scellé ensuite par « deploy.sh --encrypt ».
#
# La chaîne porte le nom de l'ancien outil et y reste : aucun des deux comptes
# scellés n'a été haché depuis ce repli (vérifié le 2026-11-01 par
# password_verify sur les deux fichiers), donc la renommer ne ferait que casser
# les hashes de test déjà posés sur les postes.
HTPASSWORD="${3:-backrest_dev_only}"

if [[ "$ACCOUNT" == */* || "$ACCOUNT" == *..* ]]; then
    echo "Nom de compte invalide : $ACCOUNT" >&2
    exit 2
fi

TARGET="$HTPASSWD_DIR/$ACCOUNT"
if [[ -e "$TARGET" && "$FORCE" -ne 1 ]]; then
    echo "$TARGET existe déjà. Relancer avec --force pour remplacer le compte." >&2
    exit 1
fi

mkdir -p "$HTPASSWD_DIR"

# Deux fournisseurs de bcrypt, dans l'ordre de préférence : la toolbox Apache si
# elle est installée, sinon le PHP de la stack (le conteneur php tourne déjà).
if command -v htpasswd >/dev/null 2>&1; then
    LINE="$(htpasswd -nbB "$HTUSER" "$HTPASSWORD" | tr -d '\r')"
else
    HASH="$(docker compose exec -T -e HT_PWD="$HTPASSWORD" php php -r \
        'echo password_hash(getenv("HT_PWD"), PASSWORD_BCRYPT, ["cost" => 12]), PHP_EOL;')"
    LINE="$HTUSER:$HASH"
fi

# Le hash bcrypt contient des « $ » : écriture directe, sans interpolation.
# « 0640 » = lisible par l'équipe de ce poste ; deploy.sh repose le fichier scellé
# en « 0600 » (voir deploy/secrets.manifest), l'utilisateur du fichier compte plus
# que son mode sur la machine cible.
printf '%s\n' "$LINE" >"$TARGET"
chmod 640 "$TARGET"

printf 'Compte écrit : %s (utilisateur %s)\n' "$TARGET" "$HTUSER"
printf 'Sur ce poste  : docker compose restart traefik\n'
printf 'Pour le serveur : bash deploy.sh --encrypt, puis commit + push du bloc\n'
