#!/usr/bin/env bash
set -euo pipefail

# Rotation des logs Docker au niveau de L'HÔTE (/etc/docker/daemon.json).
#
# Ce que fait ce script, et ce qu'il ne fait pas :
#   - il FUSIONNE les trois clés « log-driver » / « log-opts » dans le fichier
#     existant, il n'écrase jamais le reste (data-root, hosts, default-address-
#     pools, features… sont préservés tels quels) ;
#   - il NE REDÉMARRE PAS le démon Docker : un redémarrage coupe tous les
#     conteneurs, y compris MariaDB physique, Traefik et le site. Cette
#     décision appartient à un humain, à un créneau choisi ;
#   - il NE RECRÉE AUCUN conteneur. Docker applique la rotation par défaut à la
#     CRÉATION : les conteneurs déjà en place gardent leurs anciens réglages
#     jusqu'à leur prochaine recréation (redéploiement, docker compose up -d
#     qui détecte un changement, ou reboot avec un conteneur supprimé).
#
# Deux couches à ne pas confondre :
#   - cette rotation borne les FICHIERS locaux du json-file de Docker
#     (3 fichiers de 10 Mo = 30 Mo par conteneur, écrasés en anneaux) ;
#   - la rétention de 30 jours des logs CENTRALISÉS se fait dans Loki
#     (docker/loki/config.yaml), qui ne lit pas ces fichiers mais le flux de
#     l'API Docker. L'une ne remplace pas l'autre, et Loki ne protège pas le
#     disque du serveur.
#
# Usage :
#   tools/logging/docker-log-rotation.sh              # comparaison, aucune écriture
#   sudo tools/logging/docker-log-rotation.sh --apply # sauvegarde + écriture
#
# Le chemin comparé peut être déplacé pour le test (« DAEMON_JSON=/tmp/dj.json
# tools/logging/docker-log-rotation.sh ») : c'est ainsi que la fusion est validée
# hors serveur, et que le bloc « retour arrière » ci-dessous est exécuté pour de
# vrai avant d'être écrit dans la documentation.
#
# Retour arrière : la sauvegarde horodatée est imprimée ; « sudo cp <sauvegarde>
# /etc/docker/daemon.json » la remet en place, sans redémarrage non plus.

APPLY=0
case "${1:-}" in
  --apply) APPLY=1 ;;
  -h | --help)
    # N'imprimer que l'en-tête de commentaires. Deux pièges : « sed 1,40p »
    # montrerait du code et sa borne change à chaque ligne ajoutée ; et
    # s'arrêter à la première ligne non commentée couperait avant l'en-tête,
    # car « set -euo pipefail » précède ici le bloc de documentation.
    awk 'NR == 1 { next }
         /^#/                  { sub(/^# ?/, ""); print; seen = 1; next }
         /^[[:space:]]*$/      { if (seen) exit; next }
         { if (seen) exit; next }' "$0"
    exit 0
    ;;
  '') : ;;
  *) printf 'Option inconnue : %s (utiliser --apply, ou rien pour comparer)\n' "$1" >&2; exit 2 ;;
esac

DAEMON_JSON="${DAEMON_JSON:-/etc/docker/daemon.json}"
MAX_SIZE="${DOCKER_LOG_MAX_SIZE:-10m}"
MAX_FILE="${DOCKER_LOG_MAX_FILE:-3}"

# Le mode comparaison n'écrit nulle part : il n'exige pas les droits root.
if [[ $APPLY -eq 1 && $EUID -ne 0 ]]; then
  printf 'Ce script écrit dans %s : le lancer avec sudo.\n' "$DAEMON_JSON" >&2
  exit 1
fi

command -v python3 >/dev/null 2>&1 || {
  printf 'python3 est nécessaire pour fusionner le JSON sans écrasement.\n' >&2
  printf 'Sinon, éditer %s à la main et y ajouter, SANS supprimer les autres clés :\n' "$DAEMON_JSON" >&2
  printf '  "log-driver": "json-file",\n  "log-opts": {"max-size": "%s", "max-file": "%s"}\n' "$MAX_SIZE" "$MAX_FILE" >&2
  exit 1
}

# Le répertoire doit exister (Docker l'installe toujours) ; on teste le répertoire
# du chemin visé et non « /etc/docker » en dur, pour que la fusion puisse être
# exécutée pour de vrai sur un chemin de test avant le serveur.
daemon_dir="$(dirname "$DAEMON_JSON")"
[[ -d "$daemon_dir" ]] || { printf '%s introuvable : Docker est-il installé ?\n' "$daemon_dir" >&2; exit 1; }

if [[ -f "$DAEMON_JSON" ]]; then
  printf 'Fichier existant : %s (%s octets, propriétaire %s)\n' \
    "$DAEMON_JSON" "$(stat -c %s "$DAEMON_JSON")" "$(stat -c '%U:%G' "$DAEMON_JSON")"
  # Le contenu n'est PAS affiché : daemon.json peut porter des clés sensibles
  # (auth, chemins d'enregistrements privés). Seuls les noms de clés sont cités.
  python3 - "$DAEMON_JSON" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except json.JSONDecodeError as exc:
    print(f"  [BLOQUANT] JSON invalide : {exc}")
    print("  Aucun fichier ne sera touché tant que daemon.json ne se relit pas.")
    sys.exit(2)
except FileNotFoundError:
    data = {}
print("  clés présentes :", ", ".join(sorted(data)) or "(aucune)")
PY
else
  printf 'Aucun %s : le démon utilise ses valeurs par défaut (json-file, sans plafond).\n' "$DAEMON_JSON"
fi

TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_OUT"' EXIT

# « || merge_rc=$? » sur la même ligne que le heredoc : sous « set -e », une
# affectation seule ne capture rien (le script part avant), et un bloc « || { … }
# » étalé sur plusieurs lignes serait lu comme le début du corps Python. Le code
# de retour est affiché, aucune écriture n'a eu lieu dans ce cas.
merge_rc=0
python3 - "$DAEMON_JSON" "$TMP_OUT" "$MAX_SIZE" "$MAX_FILE" <<'PY' || merge_rc=$?
import json, os, sys

src, dst, max_size, max_file = sys.argv[1:5]

try:
    with open(src, encoding="utf-8") as fh:
        data = json.load(fh)
except FileNotFoundError:
    data = {}
except json.JSONDecodeError:
    # Volontaire : ne jamais réécrire par-dessus un fichier illisible.
    print("daemon.json illisible : fusion abandonnée.")
    sys.exit(2)

if not isinstance(data, dict):
    print("daemon.json ne contient pas un objet JSON : fusion abandonnée.")
    sys.exit(2)

before = {k: data.get(k) for k in ("log-driver", "log-opts")}

# NE JAMAIS imposer « json-file » : si l'hôte a choisi un autre pilote (journald,
# awslogs, fluentd…), « max-size » et « max-file » ne sont pas des options de ce
# pilote, et le démon refuse alors de démarrer — c'est-à-dire que tout le site
# tombe. La rotation s'arrête là et un humain décide.
current_driver = data.get("log-driver")
if current_driver not in (None, "json-file"):
    print(f"  [BLOQUANT] log-driver existant = {current_driver!r}, et non json-file.")
    print("  Ces deux options sont propres à json-file ; les ajouter ferait refuser")
    print("  le démarrage au démon. Borne de rotation à régler dans l'autre pilote")
    print("  (pour journald : SystemMaxUse dans /etc/journald.conf), pas ici.")
    sys.exit(3)
data["log-driver"] = "json-file"

# Fusion, pas remplacement : un log-opts existant avec d'autres options (tag,
# compress, syslog-address…) doit survivre.
opts = dict(data.get("log-opts") or {})
opts["max-size"] = max_size
opts["max-file"] = max_file
data["log-opts"] = opts

with open(dst, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
    fh.write("\n")

print("comparison :")
for key in ("log-driver", "log-opts"):
    print(f"  {key} : {before.get(key)!r} -> {data.get(key)!r}")
print(f"  autres clés conservées : {sorted(set(data) - {'log-driver', 'log-opts'})}")
PY

if [[ $merge_rc -ne 0 ]]; then
  printf 'Fusion interrompue (code %s) : rien n'"'"'est écrit dans %s.\n' "$merge_rc" "$DAEMON_JSON" >&2
  exit "$merge_rc"
fi

if [[ $APPLY -ne 1 ]]; then
  printf '\nAucune écriture (mode comparaison). Pour appliquer :\n'
  printf '  sudo %s --apply\n' "$0"
  exit 0
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
if [[ -f "$DAEMON_JSON" ]]; then
  BACKUP="$DAEMON_JSON.bak.$STAMP"
  cp -p "$DAEMON_JSON" "$BACKUP"
  printf 'Sauvegarde : %s (permissions %s)\n' "$BACKUP" "$(stat -c '%a %U:%G' "$DAEMON_JSON")"
else
  BACKUP=""
  printf 'Pas de fichier précédent : rien à sauvegarder.\n'
fi

# Écriture atomique : le fichier temporaire est validé AVANT remplacement, pour
# ne jamais laisser un daemon.json tronqué ou illisible (Docker refuserait alors
# tout simplement de démarrer).
cp "$TMP_OUT" "$DAEMON_JSON.tmp"
python3 -m json.tool "$DAEMON_JSON.tmp" >/dev/null
mv -f "$DAEMON_JSON.tmp" "$DAEMON_JSON"
chmod 0644 "$DAEMON_JSON"

printf 'Écrit : %s\n' "$DAEMON_JSON"
printf '\nÀ FAIRE MANUELLEMENT, À UN CRÉNEAU CHOISI :\n'
printf "  1. Redémarrer le démon pour que la valeur par défaut s'applique :\n"
printf '       sudo systemctl restart docker\n'
printf '     Ce geste INTERROMPT tous les conteneurs, Traefik et le site inclus.\n'
printf '     La pile de logs a un restart: unless-stopped ; les services\n'
printf "     applicatifs n'en ont pas : les relancer explicitement après.\n"
printf '  2. Contrôler sans redémarrer, sur un conteneur neuf :\n'
printf '       docker inspect --format "{{.HostConfig.LogConfig.Type}} {{.HostConfig.LogConfig.Config}}" <nom>\n'
printf '     Les conteneurs déjà en place gardent leurs anciens fichiers\n'
printf "     jusqu'à leur recréation : c'est le comportement de Docker, pas un\n"
printf '     échec de ce script.\n'
if [[ -n "$BACKUP" ]]; then
  printf '  Retour arrière : sudo cp %s %s && sudo systemctl restart docker\n' "$BACKUP" "$DAEMON_JSON"
fi
