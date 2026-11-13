#!/usr/bin/env bash
# Contrôle en lecture seule de la cible, avant le premier « ./deploy.sh ».
#
# Rien n'est créé, rien n'est chowné, rien n'est lancé : le script lit les
# « .env » versionnés des quatre clones, les compare aux dossiers réels de la
# machine, et dit à l'avance ce qui fera mal au déploiement. Les chemins ne
# sont pas recopiés ici — ils se relisent à leur source de vérité, pour que la
# liste ne puisse pas dériver du dépôt.
#
# Code de sortie : 1 si un garde bloquant manque (clone absent, clé age, bloc
# scellé, valeur divergente entre deux projets, port déjà publié). Un dossier
# absent n'est PAS bloquant : les « deploy.sh » les créent et posent leurs
# droits. Joué sans être root, le relevé est incomplet (les « stat » échouent
# sur les 0750) mais jamais faux.
#
#   sudo bash /opt/yabiladi-infra/tools/pre-flight.sh
set -uo pipefail

R_INFRA="${R_INFRA:-/opt/yabiladi-infra}"
R_SITE="${R_SITE:-/opt/yabiladi-symfony}"
R_FACTU="${R_FACTU:-/opt/yabiladi-facturation}"
R_MKIT="${R_MKIT:-/opt/yabiladi-mediakit}"

blocking=0
warn=0

hdr() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok() { printf '  OK         %-46s %s\n' "$1" "$2"; }
note() { printf '  NOTE       %-46s %s\n' "$1" "$2"; warn=$((warn + 1)); }
bad() { printf '  BLOQUANT   %-46s %s\n' "$1" "$2"; blocking=$((blocking + 1)); }

# La dernière affectation gagne, comme dans un fichier .env.
env_val() { # $1 = dépôt, $2 = clé
    local v
    v="$(grep -E "^$2=" "$1/.env" 2>/dev/null | tail -1)" || return 1
    [ -n "$v" ] || return 1
    v="${v#*=}"
    v="${v%\"}"; v="${v#\"}"
    case "$v" in
        ./*) printf '%s/%s' "$1" "${v#./}" ;;
        "")  printf '' ;;
        *)   printf '%s' "$v" ;;
    esac
}

# Un poste dont l'arborescence diffère de la cible surcharge la clé dans son
# « .env.local » — relire les deux évite de contrôler un chemin que personne
# n'utilise sur cette machine.
env_machine() { # $1 = dépôt, $2 = clé
    local v
    v="$(grep -E "^$2=.+" "$1/.env.local" 2>/dev/null | tail -1)" || return 1
    printf '%s' "${v#*=}"
}

check_path() { # $1 = chemin, $2 = attendu "uid:gid mode", $3 = qui le pose
    local lu
    [ -n "$1" ] || { note "(non déclaré)" "$3 : clé absente du .env"; return; }
    if [ ! -e "$1" ]; then
        note "$1" "ABSENT — pose à créer ($3)"
        return
    fi
    lu="$(stat -c '%u:%g %a' "$1" 2>/dev/null)" || lu="non lisible"
    if [ -n "$2" ] && [ "$lu" != "$2" ]; then
        note "$1" "droits $lu, attendu $2 — repris au déploiement ($3)"
    elif [ -z "$2" ]; then
        note "$1" "$lu — aucun script ne pose ces droits, à relever à la main"
    else
        ok "$1" "$lu"
    fi
}

printf '\033[1mpré-vol de la cible — lecture seule\033[0m  %s\n' "$(date '+%F %T')"

# ---------------------------------------------------------------- 1. les clones
hdr "1. Les quatre clones, le coffre et ses clés"
for d in "$R_INFRA" "$R_SITE" "$R_FACTU" "$R_MKIT"; do
    if git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        ok "$d" "$(git -C "$d" rev-parse --abbrev-ref HEAD) — $(git -C "$d" log -1 --format='%h %ad' --date=short)"
        # « --untracked-files=no » : c'est exactement la garde des quatre
        # « deploy.sh » (infra:817, site:446), qui meurent sur un fichier suivi
        # modifié mais ignorent l'inverse — et les clairs matérialisés du coffre
        # sont justement invendus.
        [ -z "$(git -C "$d" status --untracked-files=no --porcelain)" ] \
            || bad "$d" "fichiers suivis modifiés — « deploy.sh » refuse (git stash -u ou commit)"
    else
        bad "$d" "pas un clone git — « git clone » à jouer avant tout"
    fi
done
AGE_KEY="${AGE_KEY_FILE:-$HOME/.config/age/keys.txt}"
[ -f "$AGE_KEY" ] && ok "clé age ($AGE_KEY)" "présente" \
    || bad "clé age ($AGE_KEY)" "absente — infra/deploy.sh:159 meurt ici"
n_bin=$(ls "$R_INFRA"/deploy/secrets/*.sops.bin 2>/dev/null | wc -l)
[ "$n_bin" -gt 0 ] && ok "blocs scellés de l'infra" "$n_bin fichier(s)" \
    || bad "blocs scellés de l'infra" "aucun .sops.bin dans le clone — le pull n'est pas à jour"
for k in "$R_INFRA/deploy/secrets/id_rsa_mariadb"; do
    if [ -f "$k" ]; then
        case "$(stat -c %a "$k")" in 600|400) ok "$k" "0600" ;; *) note "$k" "mode $(stat -c %a "$k") — ssh refuse au-dessus de 0600" ;; esac
    else
        note "$k" "absent — chaîne MariaDB éteinte de toute façon, mais le DAG la monte en :ro"
    fi
done

# ------------------------------------------------- 2. les chemins et leurs droits
hdr "2. Les chemins de la cible, tels que les .env versionnés les nomment"
check_path "$(env_val "$R_INFRA" LOGGING_HOST_DATA_PATH)/loki" "10001:10001 750" "infra prepare_logging"
check_path "$(env_val "$R_INFRA" LOGGING_HOST_DATA_PATH)/grafana" "472:472 750" "infra prepare_logging"
check_path "$(env_val "$R_INFRA" LOGGING_HOST_DATA_PATH)/prometheus" "65534:65534 750" "infra prepare_logging"
check_path "$(env_val "$R_INFRA" DBACKUP_DEST_HOST_PATH)" "1001:33 750" "infra prepare_backups"
check_path "$(env_val "$R_INFRA" DBACKUP_RESTORE_HOST_PATH)" "1001:33 750" "infra prepare_backups"
check_path "$(env_val "$R_SITE" MARIADB_BACKUP_HOST_PATH)" "33:33 750" "site prepare_write_dirs"
check_path "$(env_val "$R_SITE" RADIO_CONTENT_HOST_PATH)" "" "ni l'un ni l'autre : la discothèque vient du V1"
check_path "$(env_val "$R_SITE" SITE_MEDIA_HOST_PATH)" "33:33 755" "site (monte public/files)"
check_path "$(env_val "$R_SITE" SITE_EDITOR_IMAGES_HOST_PATH)" "33:33 755" "site (monte public/img)"
check_path "$(env_val "$R_SITE" OPENDKIM_KEYS_DIR)" "" "site : l'entrypoint php copie les clés"
check_path "$(env_val "$R_SITE" PRAYER_PDF_HOST_DIR)" "" "site : sous son propre clone par défaut"

# Les quatre clés lues par deux projets : « le même » veut dire la même valeur
# absolue, sinon un projet écrit dans un arbre et l'autre archive le voisin vide.
hdr "3. Les valeurs partagées entre deux projets (divergence = archive vide annoncée « réussi »)"
for cle in SITE_MEDIA_HOST_PATH SITE_EDITOR_IMAGES_HOST_PATH RADIO_CONTENT_HOST_PATH MARIADB_BACKUP_HOST_PATH; do
    a="$(env_val "$R_INFRA" "$cle")"; b="$(env_val "$R_SITE" "$cle")"
    [ -z "$a" ] && [ -z "$b" ] && continue
    if [ "$a" = "$b" ]; then ok "$cle" "$a"; else bad "$cle" "infra=« $a » site=« $b » — deux arbres différents, l'un sera archivé vide"; fi
    for d in "$R_INFRA" "$R_SITE"; do
        m="$(env_machine "$d" "$cle" 2>/dev/null || true)"
        [ -n "$m" ] && [ "$m" != "$a" ] && note "$cle" "$d/.env.local surcharge en « $m »"
    done
done

# ------------------------------------------------------- 4. montages et capacité
# df et findmnt ignorent un dossier qui n'existe pas encore : on remonte à son
# premier ancêtre existant, c'est lui qui porte le point de montage et la place.
up_to() {
    local d="$1"
    while [ -n "$d" ] && [ ! -e "$d" ]; do d="$(dirname "$d")"; done
    printf '%s' "${d:-/}"
}

hdr "4. Montages, place libre et mesures"
cibles=""
for c in "$(env_val "$R_INFRA" DBACKUP_DEST_HOST_PATH)" "$(env_val "$R_INFRA" DBACKUP_RESTORE_HOST_PATH)" \
         "$(env_val "$R_INFRA" LOGGING_HOST_DATA_PATH)" "$(env_val "$R_INFRA" RADIO_CONTENT_HOST_PATH)" \
         "$(env_val "$R_SITE" SITE_MEDIA_HOST_PATH)" "$(env_val "$R_SITE" SITE_EDITOR_IMAGES_HOST_PATH)" \
         "$R_INFRA" /var/lib/docker; do
    [ -n "$c" ] && cibles="$cibles
$(up_to "$c")"
done
cibles="$(printf '%s\n' "$cibles" | sed '/^$/d' | sort -u)"
if command -v findmnt >/dev/null 2>&1; then
    while IFS= read -r c; do
        printf '  %-26s monté sur %-22s %s\n' "$c" "$(findmnt -T "$c" -no TARGET 2>/dev/null)" "$(findmnt -T "$c" -no SOURCE,FSTYPE 2>/dev/null)"
    done <<< "$cibles"
else
    note "findmnt" "outil absent — seul « df » parle ici"
fi
df -h --output=source,fstype,size,pcent,avail $cibles 2>/dev/null | sed 's/^/  /'

# Le seul contrôle de ce fichier qu'aucun « deploy.sh » ne fait. La destination
# des archives est annoncée comme le NFS de sauvegarde (infra/.env:138), mais
# « prepare_backups » ne fait qu'un « install -d » : sans montage, il crée le
# dossier sur le disque de la machine sauvegardée et la console y écrit en
# disant « Success ».
dest_archives="$(env_val "$R_INFRA" DBACKUP_DEST_HOST_PATH)"
if command -v findmnt >/dev/null 2>&1 && [ -n "$dest_archives" ]; then
    monte="$(findmnt -T "$dest_archives" -no TARGET 2>/dev/null)"
    fstype="$(findmnt -T "$dest_archives" -no FSTYPE 2>/dev/null)"
    src_nfs="$(findmnt -T "$dest_archives" -no SOURCE 2>/dev/null)"
    if [ "$monte" != "$dest_archives" ]; then
        bad "NFS des archives" "$dest_archives n'est pas un point de montage (résolu sur « ${monte:-rien} »)"
    elif [ "${fstype#nfs}" = "$fstype" ]; then
        bad "NFS des archives" "$dest_archives est un montage local ($fstype) — les archives resteraient sur le disque qu'elles sauvegardent"
    else
        ok "NFS des archives" "$dest_archives — $src_nfs"
    fi
fi

for c in "$(env_val "$R_SITE" SITE_MEDIA_HOST_PATH)" "$(env_val "$R_SITE" SITE_EDITOR_IMAGES_HOST_PATH)" \
         "$(env_val "$R_INFRA" RADIO_CONTENT_HOST_PATH)" "$(env_val "$R_INFRA" DBACKUP_DEST_HOST_PATH)" \
         "$(env_val "$R_INFRA" LOGGING_HOST_DATA_PATH)"; do
    [ -d "$c" ] || continue
    note "$c" "$(du -sh "$c" 2>/dev/null | cut -f1)"
done
cat <<'ARITH'
  Ce que les dépôts annoncent, à confronter aux chiffres ci-dessus :
    repli MariaDB         28,52 GB de lignes quittent le serveur par nuit
                            (mesure du 2026-11-13) ; l'archive compressée n'a
                            pas encore de nuit mesurée — la peser au réveil,
                            puis multiplier par 7 pour la rotation
    archives              la SOMME des sources, une seconde fois (rétention
                            7/4/12/2) — et le repli vit SOUS cette racine
                            depuis le 2026-11-13, les deux comptes se tiennent
                            sur le même disque
    atelier restauration  la plus grosse source seule (l'arbre média du V1)
    discothèque           ~9 Go de MP3 (infra/.env:132)
    fragments de prière   162 Mo mesurés, mais recréés par le DAG
ARITH
hote_db="$(grep -hE '^MARIADB_SSH_HOST=' "$R_SITE/docker/legacy/credentials.env" "$R_SITE/docker/legacy/credentials.env.example" 2>/dev/null | tail -1 | cut -d= -f2)"
note "NFS commun ?" "à lever des deux côtés, même commande des deux machines : « findmnt -T $(env_val "$R_INFRA" DBACKUP_DEST_HOST_PATH) -no SOURCE,FSTYPE » ici, puis là-bas après « ssh ${MARIADB_SSH_USER:-backup_ssh}@${hote_db:-<serveur de base>} ». Un SOURCE identique veut dire que le repli du DAG et le dossier d'écriture de la base sont un seul répertoire : la reprise du DAG (« déjà présent », docker/dagu/dags/mariadb_fetch.yaml:402) validerait sans rien transférer, et les chmod du DAG s'exerceraient sur les originaux."

# ------------------------------------------------------------------ 5. Docker
hdr "5. Réseaux et volumes externes déclarés par les quatre projets"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    for net in yabiladi_app yabiladi_logging; do
        docker network inspect "$net" >/dev/null 2>&1 && ok "$net" "réseau présent" \
            || note "$net" "absent — infra/deploy.sh le crée (ensure_networks)"
    done
    have=$(docker volume ls --format '{{.Name}}' | grep -c '^yabiladi_')
    note "volumes yabiladi_*" "$have trouvés — 16 déclarés « external » par les quatre projets, les deploy.sh créent les manquants"
    orphelins=$(docker volume ls --format '{{.Name}}' | grep -E '^yabiladi_(backrest|db_data|grafana_data|loki_data|prometheus_data|php_(vendor|var_cache|var_share))' | tr '\n' ' ')
    [ -n "$orphelins" ] && note "orphelins du dépôt unique" "$orphelins— aucun projet ne les déclare, ne pas les recréer"
    docker info --format '           stockage : {{.Driver}}  {{.OperatingSystem}}'
else
    note "docker" "démon injoignable (ou pas root) — bloc passé"
fi

# ------------------------------------------------------------------- 6. Ports
# Un port déjà publié fait échouer le « up -d » sur une machine qui tourne encore
# en V1 : c'est le seul point de cette liste que le déploiement ne répare pas.
hdr "6. Les ports que les quatre projets publient"
ports="80 443 $(env_val "$R_SITE" APP_PORT 2>/dev/null || echo 8080) \
$(env_val "$R_SITE" DAGU_HTTP_PORT 2>/dev/null || echo 8086) \
$(env_val "$R_INFRA" DBACKUP_HTTP_PORT 2>/dev/null || echo 8087) \
$(env_val "$R_INFRA" GRAFANA_HTTP_PORT 2>/dev/null || echo 8088) \
$(env_val "$R_INFRA" PROMETHEUS_HTTP_PORT 2>/dev/null || echo 8089) \
$(env_val "$R_FACTU" FACTURATION_APP_PORT 2>/dev/null || echo 8091) \
$(env_val "$R_MKIT" MEDIAKIT_APP_PORT 2>/dev/null || echo 8092) \
$(env_val "$R_SITE" NAVIDROME_HOST_PORT 2>/dev/null || echo 8079) 8000 8100 9000 9100"
if command -v ss >/dev/null 2>&1; then
    for p in $ports; do
        l=$(ss -ltn "sport = :$p" 2>/dev/null | tail -n +2 | head -1)
        [ -n "$l" ] && note ":$p" "déjà publié — $(echo "$l" | awk '{print $1, $4, $5}')" || ok ":$p" "libre"
    done
else
    note "ss" "outil absent — contrôler « sudo lsof -iTCP -sTCP:LISTEN -P » sur la liste : $(echo $ports | tr '\n' ' ')"
fi

# ------------------------------------------------------------------ 7. bilan
hdr "Bilan"
printf '  %s bloquant(s), %s note(s)\n\n' "$blocking" "$warn"
if [ "$blocking" -gt 0 ]; then
    cat <<'FIN'
  Les bloquants se lèvent hors des dépôts (clone, clé age, scellement, valeur
  divergente, port). Les notes sont soit réparées par les « deploy.sh » (dossiers
  absents, droits), soit des mesures à confronter à la place réelle du disque.
FIN
    exit 1
fi
echo "  Rien qui doive être réglé avant de jouer les quatre « ./deploy.sh », dans l'ordre : pile, puis les trois applications (le site en dernier rétablit 33:33 sur le repli MariaDB que la pile a pu balayer)."
