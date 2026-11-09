#!/usr/bin/env bash
set -euo pipefail

# Pose le mot de passe d'administration Grafana dans le fichier de secret prévu
# par compose.yaml (bloc « secrets: grafana_admin_password »).
#
# Règles de ce dépôt :
#   - le fichier n'est PAS versionné (.gitignore : /docker/grafana/secrets/), et ne
#     passe pas dans le coffre non plus : il n'a d'effet qu'au tout premier
#     démarrage, là où docker/traefik/htpasswd/, lui, est scellé pour que chaque
#     déploiement le repose ;
#   - la valeur n'est JAMAIS imprimée ici, ni dans un log, ni dans un rapport ;
#   - elle ne transite par aucun argument de ligne de commande visible dans
#     « ps » : lecture sur le terminal masqué (stty -echo) ou génération
#     aléatoire, jamais « ./script.sh 'motdepasse' ».
#
# Le conteneur grafana tourne en 472:472 (USER de l'image) et lit
# /run/secrets/grafana_admin_password au démarrage. Le fichier de l'hôte doit
# donc être lisible par le GID 472 : d'où le chmod 0640 + chgrp 472 ci-dessous.
# Si le GID 472 n'existe pas encore sur l'hôte, la commande de création est
# imprimée (elle demande root) — sans elle, Grafana échouerait à démarrer avec
# « could not read password from file ».
#
# Usage :
#   tools/logging/bootstrap-grafana-admin.sh                  # mot de passe aléatoire
#   tools/logging/bootstrap-grafana-admin.sh --interactive     # saisi au clavier, masquée
#   tools/logging/bootstrap-grafana-admin.sh --force           # remplace un fichier existant
#
# Après le PREMIER démarrage, ce fichier ne change plus le mot de passe : la
# base Grafana a déjà son compte. Voir docs/logging/README.md, section
# « Changer le mot de passe Grafana après initialisation ».

TARGET="${GRAFANA_ADMIN_PASSWORD_FILE:-./docker/grafana/secrets/admin_password}"
MODE="generate"
FORCE=0

for arg in "$@"; do
  case "$arg" in
    --interactive) MODE="prompt" ;;
    --force) FORCE=1 ;;
    -h|--help)
      sed -n '1,32p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      printf 'Option inconnue : %s\n' "$arg" >&2
      printf 'Ce script ne prend PAS le mot de passe en argument, pour ne pas\n' >&2
      printf "le laisser dans l'historique du shell ni dans « ps ».\n" >&2
      exit 2 ;;
  esac
done

# Chemin relatif résolu depuis la racine du dépôt, quel que soit l'appelant.
[[ "$TARGET" = /* ]] || TARGET="$PWD/${TARGET#./}"

if [[ -s "$TARGET" && $FORCE -ne 1 ]]; then
  printf '%s existe déjà. Relancer avec --force pour le remplacer.\n' "$TARGET" >&2
  exit 1
fi

mkdir -p "$(dirname "$TARGET")"
umask 077

SECRET=""
if [[ "$MODE" == "generate" ]]; then
  # 32 octets de forte entropie, en base64 URL-safe : un mot de passe long,
  # unique, et qui ne contient aucun caractère à protéger dans un YAML.
  if command -v openssl >/dev/null 2>&1; then
    SECRET="$(openssl rand -base64 32 | tr -d '\n' | tr '+/' '-_')"
  else
    SECRET="$(head -c 32 /dev/urandom | base64 | tr -d '\n=+/' )"
  fi
else
  # Saisie masquée : rien dans l'historique, rien dans « ps ».
  if [[ -t 0 ]]; then
    OLD_STTY="$(stty -g)"
    stty -echo
    printf 'Mot de passe Grafana (saisie masquée) : ' >&2
    read -r SECRET
    stty "$OLD_STTY"
    printf '\n' >&2
  else
    printf 'Saisie interactive impossible hors terminal : utiliser le mode par défaut.\n' >&2
    exit 2
  fi
fi

if [[ -z "$SECRET" ]]; then
  printf "Aucun mot de passe obtenu : rien n'est écrit.\n" >&2
  exit 1
fi

# Écriture directe, sans interpolation : le secret peut contenir des « $ ».
printf '%s' "$SECRET" >"$TARGET"
SECRET=""
chmod 0640 "$TARGET"

# GID 472 = l'utilisateur « grafana » du conteneur.
if chgrp 472 "$TARGET" 2>/dev/null; then
  printf 'Secret écrit : %s (0640, groupe 472)\n' "$TARGET"
else
  printf 'Secret écrit : %s (0640), MAIS le groupe 472 est inaccessible ici.\n' "$TARGET"
  printf 'Grafana (472:472 dans son conteneur) ne pourra pas le lire. Sur l\u0027hôte, en root :\n'
  printf '  getent group 472 || groupadd -g 472 grafana\n'
  printf '  chgrp 472 %s\n' "$TARGET"
fi

printf 'Le mot de passe n\u0027a pas été affiché. Le retrouver passe par ce fichier.\n'
