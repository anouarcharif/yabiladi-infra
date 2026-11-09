#!/usr/bin/env bash
set -euo pipefail

# État des lieux NON destructif avant le déploiement de la pile de logs
# (Loki + Alloy + Grafana).
#
# Ce script LIT et ne modifie rien : aucun mkdir, aucun chown, aucun écriture,
# aucun redémarrage. Il répond aux questions que compose.yaml ne peut pas
# poser tout seul depuis l'intérieur d'un conteneur :
#   - le disque désigné par LOGGING_HOST_DATA_PATH est-il bien le SSD/NVMe, et
#     reste-t-il assez de place pour 30 jours de logs ;
#   - le socket Docker et son groupe ;
#   - les réseaux, ports et pilotes de logs déjà en place ;
#   - le nom réel du réseau de Traefik (les labels « traefik.docker.network »
#     doivent le citer exactement) ;
#   - les middlewares et le résolveur ACME existants, pour ne pas en inventer ;
#   - la protection de Dagu (existence du fichier, utilisateur, hash JAMAIS
#     affiché) ;
#   - DNS et certificat de grafana.yabiladi.com.
#
# Aucun secret n'est lu ni affiché : les fichiers d'authentification ne sont
# testés qu'avec -s (existe ?), et les variables d'environnement ne sont
# contrôlées que par leur nom.
#
# Usage :
#   tools/logging/preflight.sh              # rapport complet
#   tools/logging/preflight.sh --strict     # sort en 1 si un blocage est détecté
# Sur le serveur, depuis la racine du dépôt déployé.

STRICT=0
[[ "${1:-}" == "--strict" ]] && STRICT=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT_DIR"

BLOCKERS=0
WARNINGS=0

say()  { printf '%s\n' "$*"; }
# « echo » serait cherché dans le PATH et ferait échouer toute la substitution
# de commande sur un « PATH » volontairement incomplet ; « printf » est un
# builtin. Les couleurs ne sortent que sur un terminal, jamais dans un rapport
# enregistré dans un fichier.
if [[ -t 1 ]]; then
  sect() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
else
  sect() { printf '\n== %s\n' "$*"; }
fi
ok()   { printf '  [ok]      %s\n' "$*"; }
note() { printf '  [note]    %s\n' "$*"; }
warn() { printf '  [ATTENTION] %s\n' "$*"; WARNINGS=$((WARNINGS + 1)); }
bad()  { printf '  [BLOQUANT] %s\n' "$*"; BLOCKERS=$((BLOCKERS + 1)); }

# Le script tourne sous « set -euo pipefail » : une commande absente dans une
# substitution de commande ferait AVORTER le rapport, et la synthèse finale ne
# serait jamais imprimée. « have » teste l'existence avant d'appeler ; « read_or »
# rend le résultat ou une mention explicite de l'outil manquant. Le rapport doit
# rester lisible sur une Debian minimale comme sur un poste de développement.
have() { command -v "$1" >/dev/null 2>&1; }

# Une valeur sensible n'est jamais imprimée : on ne teste que sa présence.
present_only() { [[ -s "$1" ]] && printf 'non vide' || printf 'absent ou vide'; }

sect "1. Hôte et noyau"
say "  hostname : $(hostname)"
say "  noyau    : $(uname -sr)"
[[ -r /etc/os-release ]] && . /etc/os-release && say "  système  : ${PRETTY_NAME:-inconnu}"
# « free » n'est pas garanti ; /proc/meminfo l'est sur Linux.
if have free; then
  say "  RAM      : $(free -h | awk '/^Mem:/ {print $2 " total, " $7 " disponible"}')"
elif [[ -r /proc/meminfo ]]; then
  say "  RAM      : $(awk '/MemTotal/ {t=$2} /MemAvailable/ {a=$2} END {printf "%.0f Go total, %.0f Go disponible", t/1048576, a/1048576}' /proc/meminfo)"
else
  note "RAM non mesurable ici (ni « free », ni /proc/meminfo)"
fi
[[ -r /proc/loadavg ]] && say "  charge   : $(awk '{print $1" "$2" "$3}' /proc/loadavg)"
say "  CPU      : $(nproc 2>/dev/null || echo inconnu) cœur(s)"

sect "2. Docker"
if ! docker version >/dev/null 2>&1; then
  bad "Le démon Docker ne répond pas pour cet utilisateur (groupe « docker » ?)."
else
  say "  démon    : $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  say "  compose  : $(docker compose version --short 2>/dev/null || echo inconnu)"
  # Pilote de logs PAR DÉFAUT de l'hôte : c'est lui qui s'applique aux
  # conteneurs créés après coup, pas le bloc « logging: » de compose.yaml.
  log_driver="$(docker info --format '{{.LoggingDriver}}' 2>/dev/null)"
  say "  pilote de logs par défaut : $log_driver"
  say "  stockage                  : $(docker info --format '{{.Driver}}') sur $(docker info --format '{{.DockerRootDir}}')"
  # Le plafond « max-size/max-file » est propre à json-file. Si l'hôte a choisi
  # un autre pilote, tools/logging/docker-log-rotation.sh refuse d'écrire (et il
  # a raison : ces clés feraient refuser le démarrage au démon).
  case "$log_driver" in
    json-file)
      ok "pilote json-file : la rotation par plafond de fichiers s'applique bien"
      ;;
    journald)
      warn "pilote journald : la borne se règle dans /etc/journald.conf (SystemMaxUse), pas dans daemon.json"
      ;;
    *)
      warn "pilote « $log_driver » : vérifier comment CE pilote borne le volume de logs ; le script de rotation refusera d'écrire"
      ;;
  esac
fi

# Le script de rotation fusionne daemon.json avec python3 ; ni « jq » ni « php »
# ne sont garantis sur l'hôte. Mieux vaut l'apprendre ici que le jour où le disque
# monte en température.
#
# « command -v python3 » NE SUFFIT PAS : sous Windows, le lanceur du Microsoft
# Store est un exécutable fantôme — présent dans le PATH, il affiche « Python est
# introuvable » et sort sur 49. Mesuré ici même. On lance donc réellement
# l'interpréteur.
if python3 -c 'import json, sys' >/dev/null 2>&1; then
  ok "python3 fonctionnel : tools/logging/docker-log-rotation.sh pourra fusionner daemon.json"
else
  warn "python3 inutilisable : la fusion automatique est impossible, éditer /etc/docker/daemon.json à la main (le script de rotation imprime les deux clés à ajouter et refuse toute écriture)"
fi

# Groupe et permissions du socket : Alloy doit pouvoir l'ouvrir.
if [[ -S /var/run/docker.sock ]]; then
  sock_stat="$(stat -c '%U:%G %a' /var/run/docker.sock)"
  say "  socket Docker : $sock_stat"
  note "Un montage « :ro » n'est PAS une isolation : l'API Docker permet de créer"
  note "un conteneur montant / de l'hôte. Le risque est documenté dans"
  note "docs/logging/README.md, section « Socket Docker »."
elif [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
  note "Poste Windows : le démon n'expose pas /var/run/docker.sock (tuyau nommé"
  note "« \\\\.\pipe\docker_engine »). Ce test et ceux qui lisent /proc ou /sys ne"
  note "prennent effet que sur l'hôte Debian ; exécuter ce script sur le serveur."
else
  warn "/var/run/docker.sock introuvable ici : Alloy ne pourra pas découvrir les conteneurs."
fi

sect "3. Fichiers de la stack applicative"
for f in compose.yaml compose.override.yaml .env .env.local; do
  if [[ -f "$f" ]]; then
    # Le contenu d'un .env est sensible : seuls des NOMS de variables sont
    # cités, jamais une valeur.
    if [[ "$f" == .env* ]]; then
      say "  $f présent ($(wc -l <"$f" | tr -d ' ') lignes, valeurs non lues)"
      if [[ "$f" == .env ]]; then
        for v in LOGGING_HOST_DATA_PATH GRAFANA_HOST GRAFANA_ROOT_URL \
                 GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD_FILE \
                 LOG_HOSTNAME LOGGING_TZ DAGU_ALLOWED_IPS TRAEFIK_ACME_EMAIL; do
          grep -qE "^${v}=" "$f" || warn "$f ne déclare pas $v (valeur par défaut de compose.yaml appliquée)"
        done
      fi
    else
      say "  $f présent ($(wc -l <"$f" | tr -d ' ') lignes)"
    fi
  else
    [[ "$f" == .env.local || "$f" == compose.override.yaml ]] \
      && note "$f absent (normal en production si tout est dans .env)" \
      || bad "$f absent"
  fi
done

sect "4. Protection existante de Dagu (réutilisée pour Grafana)"
HTPASSWD_DIR="docker/traefik/htpasswd"
if [[ -d "$HTPASSWD_DIR" ]]; then
  for acct in "$HTPASSWD_DIR"/*; do
    [[ -f "$acct" ]] || continue
    # Les gabarits *.example sont versionnés (la forme du fichier, pas un compte) :
    # ils ne sont lus par aucun middleware et ne se jugent pas comme des comptes.
    case "$acct" in *.example) continue ;; esac
    # Seul le nom d'utilisateur est lu ; le hash bcrypt n'est jamais imprimé.
    user="$(cut -d: -f1 "$acct" | head -1)"
    perm="$(stat -c '%a %U:%G' "$acct")"
    if grep -qE '^\$2[aby]\$' "$acct" 2>/dev/null || cut -d: -f2 "$acct" | grep -q '^\$2'; then
      ok "compte « $(basename "$acct") » utilisateur=$user format=bcrypt perms=$perm"
    else
      bad "compte « $(basename "$acct") » utilisateur=$user : hash non bcrypt — Traefik v3 n'accepte QUE \$2a/\$2b/\$2x/\$2y et refusera silencieusement"
    fi
  done
  # Permissions trop ouvertes : le clair sort du coffre à chaque déploiement, il n'a
  # aucune raison d'être lisible par « others » sur le disque.
  find "$HTPASSWD_DIR" -maxdepth 1 -type f -perm /077 ! -name '*.sh' ! -name '*.example' | grep -q . \
    && warn "des fichiers de $HTPASSWD_DIR sont lisibles par « others » (deploy.sh les repose en 0600)" \
    || ok "permissions des comptes : aucune lecture « others »"
else
  bad "$HTPASSWD_DIR absent : le middleware basicauth n'a rien à lire, Grafana serait exposé. Ce dossier n'est plus à remplir à la main — « bash deploy.sh --secrets » sort les comptes du coffre."
fi

if docker compose config --format json >/tmp/preflight.compose.json 2>/dev/null; then
  say "  compose : syntaxe validée"
  # Les middlewares réellement déclarés dans la stack, pour ne pas en inventer.
  # « || true » : sous « set -euo pipefail », un grep qui ne trouve rien ferait
  # avorter le rapport au lieu de laisser la ligne « aucun » s'afficher.
  mw="$(grep -oE 'traefik\.http\.middlewares\.[a-z0-9-]+' compose.yaml | sed 's/.*middlewares\.//' | sort -u | tr '\n' ' ' || true)"
  say "  middlewares Traefik déclarés : ${mw:-aucun}"
  rt="$(grep -oE 'traefik\.http\.routers\.[a-z0-9-]+' compose.yaml | sed 's/.*routers\.//' | sort -u | tr '\n' ' ' || true)"
  say "  routeurs Traefik déclarés    : ${rt:-aucun}"
  grep -q 'certificatesresolvers.letsencrypt' compose.yaml \
    && ok "résolveur ACME « letsencrypt » présent (réutilisé, ne pas en créer un second)" \
    || bad "aucun résolveur ACME trouvé dans compose.yaml"
  for m in dagu-ipallow dagu-htpasswd; do
    grep -q "middlewares\.$m\." compose.yaml && ok "middleware $m réutilisable pour Grafana" || bad "middleware $m introuvable"
  done
  # Chaque middleware CITÉ par un routeur Grafana doit être déclaré PAR LE
  # CONTENEUR GRAFANA. Un middleware déclaré par un autre service (dagu, la
  # console de sauvegarde) n'existe que pendant la vie de ce conteneur : mesuré le
  # 2026-10-29, pendant une recréation de dagu Traefik répondait
  # « middleware "dagu-htpasswd@docker" does not exist » sur le routeur grafana,
  # donc la barrière d'accès dépendait d'un service sans rapport.
  grafana_refs="$(grep -oE 'traefik\.http\.routers\.grafana[a-z-]*\.middlewares=[^"]+' compose.yaml | sed 's/.*=//' | tr ',' ' ' | sort -u || true)"
  grafana_block="$(sed -n '/^  grafana:/,/^  [a-z][a-z-]*:/p' compose.yaml)"
  for ref in $grafana_refs; do
    if printf '%s\n' "$grafana_block" | grep -q "middlewares\.$ref\."; then
      ok "middleware « $ref » : déclaré par le conteneur grafana lui-même (survit aux recréations de dagu)"
    elif grep -q "middlewares\.$ref\." compose.yaml; then
      bad "middleware « $ref » cité par un routeur Grafana n'est porté que par un autre conteneur : barrière perdue quand celui-ci est recréé"
    else
      bad "middleware « $ref » cité par un routeur Grafana n'est déclaré nulle part : Traefik met le routeur en erreur (503)"
    fi
  done
else
  bad "docker compose config échoue : corriger compose.yaml avant tout déploiement"
fi

sect "5. Réseaux et ports"
if docker network ls >/dev/null 2>&1; then
  say "  réseaux Docker existants :"
  docker network ls --format '    {{.Name}}  ({{.Driver}})' | grep -E 'app|logging|bridge' || docker network ls --format '    {{.Name}}'
  # Nom RÉEL du réseau de Traefik : les labels « traefik.docker.network » doivent
  # porter ce nom préfixé par le projet, pas le nom court du fichier compose.
  real_app="$(docker network ls --format '{{.Name}}' | grep -E '_app$' | head -1 || true)"
  if [[ -n "$real_app" ]]; then
    ok "nom réel du réseau applicatif : $real_app"
    if grep -q "traefik.docker.network=$real_app" compose.yaml; then
      ok "le label traefik.docker.network cite bien ce nom"
    else
      warn "le label traefik.docker.network ne cite pas « $real_app » : à corriger dans compose.yaml"
    fi
  fi
  if docker network inspect "$real_app" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null | grep -qw traefik; then
    ok "Traefik est branché sur $real_app"
  else
    warn "Traefik n'est pas visible sur $real_app : vérifier avant d'exposer Grafana"
  fi
fi
say "  ports en écoute sur l'hôte (nmap ne remplace pas cette lecture) :"
# « ss -ltnH » : -H sans en-tête, -t TCP, -n sans résolution. La colonne 4 est
# l'adresse locale « hôte:port ». Ce que la mission interdit, c'est une exposition
# sur une interface OTHER que la boucle : un port lié sur 127.0.0.1 est un
# contournement de développement assumé, pas un blocage.
if have ss; then
  ss -ltnH 2>/dev/null | awk '{print $4}' | sort -u | sed 's/^/    /' | head -30
  # Les trois ports de la pile de mesures sont contrôlés ici parce qu'ils
  # valent un accès en lecture à l'état du serveur : « 9090 » (API HTTP de
  # Prometheus) donne les mêmes mesures que Grafana, « 9100 » (node_exporter)
  # la table de montage et l'état TCP de l'hôte, « 8080 » (cAdvisor) l'inventaire
  # des conteneurs. Seuls « 8089 », le mappage voulu, doit exister — et sur la
  # boucle. « 3000 » et « 8088 » sont Grafana, « 3100 »/« 9095 » Loki,
  # « 12345 » l'UI d'Alloy, « 3110 »/« 3999 » les ports du poste.
  for p in 3100 3000 12345 8088 3110 3999 8089 9090 9100; do
    listeners="$(ss -ltnH "( sport = :$p )" 2>/dev/null | awk '{print $4}' | sort -u)"
    [[ -z "$listeners" ]] && continue
    # Le motif glob « *:$p » correspondrait aussi à « 127.0.0.1:$p » : on isole
    # l'adresse en retirant le suffixe « :port », puis on classe chaque adresse.
    has_all=0 has_other=0
    for tok in $listeners; do
      addr="${tok%:*}"
      case "$addr" in
        127.* | ::1 | "[::1]") : ;;
        0.0.0.0 | "*" | "::" | "[::]") has_all=1 ;;
        *) has_other=1 ;;
      esac
    done
    shown="$(printf '%s\n' "$listeners" | tr '\n' ' ')"
    if [[ $has_all == 1 ]]; then
      bad "port $p lié sur TOUTES les interfaces ($shown) : la pile de logs ne doit rien exposer au domaine public"
    elif [[ $has_other == 1 ]]; then
      warn "port $p lié sur une interface non boucle ($shown) : à passer derrière Traefik ou à retirer"
    else
      note "port $p lié sur la boucle uniquement ($shown) : jamais joignable depuis l'extérieur"
    fi
  done
else
  note "« ss » indisponible : contrôler l'exposition sur l'hôte Debian (« ss -ltn », « docker ps --format » avec la colonne Ports)"
fi

sect "6. Disque de rétention"
# LOGGING_HOST_DATA_PATH porte la valeur du serveur (/data/logging). Sur le
# poste de développement, compose.override.yaml remplace ces deux montages par
# les volumes Docker nommés loki_data et grafana_data : la mesure du disque n'a
# donc de sens que sur l'hôte Debian.
data_path="${LOGGING_HOST_DATA_PATH:-/data/logging}"
case "$data_path" in
  /*) : ;;
  *)  data_path="$ROOT_DIR/${data_path#./}" ;;
esac
say "  chemin déclaré : $data_path"
resolved="$(dirname "$data_path")"
is_dev_box=0
[[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]] && is_dev_box=1
if [[ -d "$data_path" ]]; then
  resolved="$data_path"
elif [[ $is_dev_box -eq 1 ]]; then
  # Sur ce poste, compose.override.yaml remplace le bind par les volumes nommés
  # loki_data / grafana_data : l'absence de /data/logging n'a rien de bloquant.
  note "poste Windows : « $data_path » n'est pas utilisé ici, les données locales sont dans les volumes Docker (« docker volume ls », « docker stats »)"
else
  # Sur le serveur, un bind mount dont la source n'existe pas est créé par Docker
  # « en root:root, mode 755 » : Grafana (472:472) n'y peut rien écrire et la
  # base SQLite échoue au premier démarrage. D'où l'avertissement.
  warn "$data_path n'existe pas sur cet hôte : créer les trois sous-répertoires avant « docker compose up -d loki grafana prometheus » (mkdir -p $data_path/loki $data_path/grafana $data_path/prometheus, puis les chown — voir docs/logging/README.md)"
fi
# « || true » : avec « set -euo pipefail », un df qui échoue (montage absent)
# ferait avorter tout le rapport au lieu de laisser la ligne suivante s'adapter.
df_out="$(df -h "$resolved" 2>/dev/null | tail -1 || true)"
if [[ -n "$df_out" ]]; then
  say "  montage        : $(echo "$df_out" | awk '{print $1 " -> " $6}')"
  say "  espace         : $(echo "$df_out" | awk '{print $2 " total, " $4 " libre, " $5 " utilisé"}')"
else
  note "montage illisible depuis cet hôte : mesurer avec « df -h $data_path » sur le serveur"
fi
avail_kb="$(df -Pk "$resolved" 2>/dev/null | tail -1 | awk '{print $4}' || true)"
if [[ -n "${avail_kb:-}" ]]; then
  avail_gb=$((avail_kb / 1024 / 1024))
  # Ordre de grandeur documenté : Loki compresse (sz/snappy/zstd) et retient
  # environ 0,1 à 0,3 Mo par Mo de texte brut selon la répétabilité des lignes.
  # Un débit de 50 Mo/jour tient donc dans ~5 Go pour 30 jours ; 500 Mo/jour
  # demande ~30 Go. Ces chiffres sont des estimations, pas des garanties.
  if [[ $avail_gb -lt 20 ]]; then
    warn "moins de 20 Go libres : la rétention de 30 jours tiendra seulement si le volume de logs reste faible ; mesurer après une semaine"
  else
    ok "${avail_gb} Go libres pour 30 jours de logs"
  fi
fi
# SSD ou rotationnel ? /sys/block/*/queue/rotational : 0 = SSD/NVMe.
dev_src="$(echo "$df_out" | awk '{print $1}')"
if [[ -n "$dev_src" && -e /sys/block ]]; then
  rot="$(basename "${dev_src%%[0-9]*}")"
  if [[ -r "/sys/block/$rot/queue/rotational" ]]; then
    r="$(cat "/sys/block/$rot/queue/rotational")"
    [[ "$r" == "0" ]] && ok "/sys/block/$rot : rotational=0 → support non mécanique (SSD/NVMe)" \
      || bad "/sys/block/$rot : rotational=1 → disque mécanique, à confirmer avant d'écrire 30 jours de logs dessus"
  else
    note "rotational illisible pour « $rot » (LVM/md/chiffrement ?) : vérifier manuellement"
  fi
fi
# Les trois sous-répertoires de la pile d'observabilité, avec l'utilisateur qui
# écrit dedans : « 65534 » est « nobody », déjà l'utilisateur de l'image
# prom/prometheus (aucun « user: » n'est posé dans compose.yaml), et un WAL non
# writable fait mourir le conteneur au premier démarrage.
for sub in loki grafana prometheus; do
  d="$data_path/$sub"
  if [[ -d "$d" ]]; then
    own="$(stat -c '%U:%G %a' "$d")"
    note "$d existe ($own)"
  else
    note "$d n'existe pas encore : à créer avec le chown indiqué par docs/logging/README.md (Grafana écrit en 472:472, Prometheus en 65534:65534)"
  fi
done

sect "7. DNS et TLS de grafana.yabiladi.com"
target_host="${GRAFANA_PUBLIC_DNS_CHECK:-grafana.yabiladi.com}"
# « getent » (libc-bin) est l'outil de référence sur Debian ; « dig » appartient à
# bind-tools, facultatif. « nslookup » est volontairement écarté : sa sortie
# mélange l'adresse du SERVEUR DNS et celle de la réponse, et selon les
# localisations le préfixe n'est pas le même — un faux positif vaut moins qu'un
# « je ne sais pas » explicite.
resolve_v4() {
  if have getent; then getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}'
  elif have dig; then dig +short -4 A "$1" 2>/dev/null
  fi
}
ips="$( { resolve_v4 "$target_host" || true; } | { grep -E '^[0-9.]+$' || true; } | sort -u | tr '\n' ' ')"
if [[ -n "$ips" ]]; then
  # Une résolution n'est pas une bonne nouvelle en soi : sur un poste de
  # développement, une entrée « hosts » (Windows) ou /etc/hosts peut faire
  # résoudre le nom vers la boucle. Le test qui compte — le nom pointe-t-il vers
  # CE serveur public — ne se valide que depuis l'hôte Debian.
  if printf '%s' "$ips" | grep -qE '(^|[[:space:]])127\.'; then
    warn "DNS $target_host -> $ips : adresse de boucle. Sur un poste de travail, c'est une entrée « hosts » locale, pas la zone publique. Le contrôle réel se fait sur le serveur."
  else
    say "  DNS $target_host -> $ips"
  fi
  if have hostname; then
    note "adresses de cet hôte : $( { hostname -I 2>/dev/null || true; } | tr ' ' '\n' | { grep -E '^[0-9.]+' || true; } | sort -u | tr '\n' ' ')"
  fi
  note "Comparer : le domaine doit résoudre vers CE serveur, sinon Let's Encrypt"
  note "échouera sur le challenge HTTP et aucun certificat ne sera émis."
elif have getent || have dig; then
  bad "$target_host ne résout pas : le challenge ACME échouera et Traefik servira son certificat par défaut tant que la zone DNS n'aura pas basculé (elle ne se modifie pas depuis ce dépôt)"
else
  note "résolution DNS indisponible depuis ce poste (getent/dig absents, nslookup Windows non fiable) : contrôler depuis l'hôte Debian par « getent ahostsv4 $target_host »"
fi
if have openssl; then
  # « timeout » borne la poignée de main ; sans lui, l'appel reste mais ne peut
  # pas bloquer le rapport plus longtemps que le TCP lui-même.
  tls_probe=(openssl s_client -connect "$target_host:443" -servername "$target_host")
  have timeout && tls_probe=(timeout 10 "${tls_probe[@]}")
  tls_out="$( { printf '' | "${tls_probe[@]}"; } 2>/dev/null || true )"
  if [[ "$tls_out" == *'BEGIN CERTIFICATE'* ]]; then
    # Le CN du certificat dit tout : « TRAEFIK DEFAULT CERT » = le domaine arrive
    # bien sur un Traefik, mais aucun certificat ACME n'a encore été émis pour lui
    # (le routeur n'existe pas, ou le challenge n'a pas tourné).
    cn="$(printf '%s\n' "$tls_out" | sed -n 's/^subject=//p' | head -1)"
    if printf '%s' "$tls_out" | grep -qi 'TRAEFIK DEFAULT CERT'; then
      warn "port 443 joignable, certificat = certificat par défaut auto-signé de Traefik (${cn}) : le routeur Grafana avec certresolver n'est pas encore en service"
    else
      note "port 443 joignable, certificat servi : ${cn} (contrôler émetteur et date d'expiration)"
    fi
  else
    note "pas de certificat actuel sur $target_host:443 (normal avant le premier déploiement)"
  fi
fi

sect "Synthèse"
say "  bloquants : $BLOCKERS   avertissements : $WARNINGS"
say "  Ce rapport ne constitue pas une validation de déploiement : les tests"
say "  réels (rétention, ingestion, dashboards, exposition) se conduisent après"
say "  le démarrage, avec la checklist de docs/logging/README.md."
if [[ $BLOCKERS -gt 0 && $STRICT -eq 1 ]]; then
  exit 1
fi
exit 0
