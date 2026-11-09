#!/usr/bin/env bash
#
# Outil du coffre de Yabiladi (SOPS + Age).
#
# Il tourne DANS l'image yabiladi/secrets (docker/secrets/Dockerfile), construite
# par Yabiladi-Infra : le dépôt de l'infrastructure est monté en /w — donc le
# manifeste, les blocs chiffrés et ce script —, la clé privée age en
# /keys/keys.txt, et, quand le projet dont on déploie les secrets n'est pas
# l'infrastructure, LE DEPOT DE CE PROJET est monté en plus en /app.
#
# Depuis l'hôte, on ne l'appelle jamais directement — passer par un deploy.sh
# garantit le montage de la clé, le « --network none », le bon umask et, donc, la
# valeur de TARGET_PROJECT.
#
# Verbes :
#   encrypt      clair → deploy/secrets/*.sops.*   (poste de dev, après édition d'un secret)
#   materialize  deploy/secrets/*.sops.* → clair   (serveur, à chaque déploiement)
#   verify       round-trip octet pour octet, sans jamais écrire le clair
#   status       ce qui est chiffré, ce qui manque — sans ouvrir les valeurs
#
# Une seule table (deploy/secrets.manifest) pour les quatre projets de la pile,
# et une colonne 8 qui dit à qui appartient chaque entrée : c'est le filtre de ce
# script. Voir les commentaires de la colonne 8 dans le manifeste pour le pourquoi
# — un deploy.sh ne déchiffre jamais le secret d'un autre dépôt.
set -euo pipefail

cd /w
MANIFEST=deploy/secrets.manifest
[ -f "$MANIFEST" ] || { echo "ERREUR: $MANIFEST introuvable" >&2; exit 1; }

# Le projet dont on traite les secrets. Passé par le deploy.sh appelant :
#   TARGET_PROJECT=infra       (CE dépôt — default, et cas où /w est la cible)
#   TARGET_PROJECT=site
#   TARGET_PROJECT=facturation
#   TARGET_PROJECT=mediakit
TARGET_PROJECT="${TARGET_PROJECT:-infra}"

# Racine du dépôt cible DANS le conteneur. L'appelant monte le dépôt du projet en
# /app et passe donc TARGET_PROJECT_DIR=/app. Le défaut « /w » couvre le cas du
# déploiement d'infrastructure, où cible et coffre sont le même dépôt : rien à
# monter de plus, rien à changer aux comportements mesurés d'avant la séparation.
TARGET_PROJECT_DIR="${TARGET_PROJECT_DIR:-/w}"

fail() { echo "ERREUR: $*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage: deploy/secrets.sh <encrypt|materialize|verify|status>   (dans le conteneur, /w = dépôt du coffre)

  encrypt      chiffre les fichiers clairs des dépôts vers deploy/secrets/
  materialize  déchiffre deploy/secrets/ vers les emplacements réels attendus par compose
  verify       contrôle que ce qui sort du coffre est identique octet pour octet au clair
  status       liste l'état des deux côtés, sans ouvrir les valeurs

  TARGET_PROJECT=<infra|site|facturation|mediakit>  projet dont on traite les
  secrets ; défaut « infra ». Les lignes du manifeste dont la colonne 8 porte un
  autre nom ne sont ni relues ni écrites (sauf au verbe « status », qui les montre).

  TARGET_PROJECT_DIR=<chemin>  racine, dans le conteneur, du dépôt du projet cité.
  Défaut « /w » — le dépôt du coffre, donc le cas « infra ». Un deploy.sh qui
  déploie un autre projet le monte en /app et passe TARGET_PROJECT_DIR=/app : la
  colonne 2 du manifeste est alors résolue sous ce chemin, pas sous /w.

  SECRETS_ONLY=<fragment[,fragment]> limite ENCORE le verbe aux entrées dont le
  chemin contient l'un des fragments (ex. SECRETS_ONLY=htpasswd, ou la liste des
  blocs d'un dépôt). Réservé à la rotation ciblée : le filtre principal est
  TARGET_PROJECT, pas celui-ci.
USAGE
    exit 2
}

# Deux mesures de SOPS 3.13.3 conditionnent ces deux fonctions :
#   1. le format n'est deviné que derrière .sops.env et .sops.bin — d'où les types
#      explicites du manifeste ;
#   2. en déchiffrement, « --input-type » ne suffit PAS (testé : il échoue sur un
#      fichier .age alors que le même contenu nommé *.sops.env se lit). C'est le
#      nom de fichier qui pilote le parseur, donc tout fichier temporaire est
#      déchiffré avec --filename-override pointant vers le nom du manifeste.
sops_encrypt() { # $1=clair  $2=destination chiffrée  $3=type  $4=nom du coffre
    local out_type=dotenv
    [ "$3" = binary ] && out_type=binary
    # --filename-override est indispensable ici aussi, pour deux raisons mesurées :
    # sops dérive le format MAIS AUSSI la règle de création de .sops.yaml du NOM du
    # fichier. Le nom réel (« .env.local », « admin_password ») ne correspond à
    # aucune règle : sans cet override, sops répond « no matching creation rules ».
    # C'est donc le nom du coffre qui décide qui pourra relire, pas la ligne de commande.
    sops --encrypt --input-type="$3" --output-type="$out_type" --filename-override "$4" "$1" > "$2"
}

sops_decrypt() { # $1=fichier chiffré à lire  $2=nom pilote pour le parseur (*.sops.env / *.sops.bin)
    sops --decrypt --filename-override "$2" "$1"
}

count_vars() { grep -cE '^[A-Za-z_][A-Za-z0-9_]*=' "$1" || true; }

verb="${1:-}"
[ -n "$verb" ] || usage

# Ce script manipule du CLAIR dans des fichiers temporaires (mktemp). Un arrêt en
# cours de route — erreur sops, Ctrl-C, commande qui avorte sous « set -e » — les
# laissait sur le disque : mesuré le 2026-11-01, trois résidus traînaient dans le
# dépôt après des « --verify » interrompus (verify.XXXXXX et chk.XXXXXX à la
# racine, et un admin_password.tmp.XXXXXX hérité d'une ancienne ligne du
# manifeste). Le trap couvre toutes les sorties, succès comme échec.
cleanup_tmp() {
    [ -n "${tmp:-}" ] && rm -f "$tmp"
    [ -n "${chk:-}" ] && rm -f "$chk"
    return 0
}
trap cleanup_tmp EXIT INT TERM

# Le dépôt du projet est-il monté ? Un montage Docker dont la source n'existe pas
# côté hôte donne un répertoire VIDE côté conteneur — et un répertoire vide, pour
# « encrypt », ne se distingue pas d'un projet sans secret : le script chiffrerait
# un absent, ou mourrait sur un « introuvable » qui ferait accuser le coffre alors
# que c'est l'appelant qui a oublié le « -v ». Le contrôle est donc fait ici, une
# fois par ligne concernée, et dit explicitement ce qui manque.
require_target_repo() {
    [ "$TARGET_PROJECT" = infra ] && return 0
    [ -d "$TARGET_PROJECT_DIR" ] || fail "le dépôt du projet « $TARGET_PROJECT » n'est pas monté ($TARGET_PROJECT_DIR introuvable dans le conteneur) : l'appelant doit passer TARGET_PROJECT_DIR=/app et le -v correspondant"
}

while IFS='|' read -r enc clair type mode grp minvars opt project; do
    # Le manifeste est commenté : ligne vide ou débutant par « # » ne se déploie pas.
    case "$enc" in ''|'#'*) continue ;; esac

    # Colonne 8. Une table d'avant la séparation n'en avait que sept : le projet
    # par défaut est donc celui du dépôt du coffre, ce qui reproduit exactement
    # l'ancien comportement — aucune ligne oubliée, aucune ligne de trop.
    project="${project:-infra}"

    # Filtre principal : le projet que nous sommes. Les lignes des autres
    # dépôts ne sont ni relues, ni déchiffrées, ni écrites. « status » les
    # montre quand même, pour qu'un coffre complet se lise d'un coup d'œil :
    # c'est le verbe de contrôle, pas le verbe de déploiement.
    if [ "$project" != "$TARGET_PROJECT" ]; then
        if [ "$verb" = status ]; then
            printf '  %-46s %-12s  (projet %s, hors de portée de %s)\n' \
                "$enc" "autre" "$project" "$TARGET_PROJECT"
        fi
        continue
    fi

    # La colonne 2 est relative au dépôt du projet. Pour « infra », c'est CE
    # dépôt — donc /w, où le script travaille déjà, et les chemins restent
    # écrits tels quels. Pour les trois autres, le clair est sous
    # TARGET_PROJECT_DIR (monté en /app par l'appelant), et les « . » de tête
    # d'un chemin relatif n'ont plus rien à faire dans /w.
    if [ "$project" = infra ]; then
        C="$clair"
    else
        case "$clair" in
            /*) C="$clair" ;;
            ./*) C="$TARGET_PROJECT_DIR/${clair#./}" ;;
            *) C="$TARGET_PROJECT_DIR/$clair" ;;
        esac
    fi

    # Rotation ciblée : « SECRETS_ONLY=mediakit » ne touche que l'entrée dont le
    # chemin contient ce fragment. Une liste « a,b,c » (les blocs d'une pile qui
    # héberge aussi d'autres applications) retient l'union des fragments, sans
    # réécrire les autres blocs du coffre. Depuis la séparation, ce filtre se
    # applique APRES celui de la colonne 8 : il ne peut que restreindre, jamais
    # ouvrir une entrée d'un autre projet.
    if [ -n "${SECRETS_ONLY:-}" ]; then
        retenu=0
        IFS=',' read -ra fragments <<< "$SECRETS_ONLY"
        for fragment in "${fragments[@]}"; do
            [ -n "$fragment" ] || continue
            case "$enc" in *"$fragment"*) retenu=1; break ;; esac
            case "$C" in *"$fragment"*) retenu=1; break ;; esac
        done
        [ "$retenu" -eq 1 ] || continue
    fi

    # Colonne 7 « oui » : secret d'une application pas encore livrée (l'intranet
    # de facturation). L'absence est tolérée UNIQUEMENT si le clair manque aussi :
    # un clair présent sans bloc chiffré reste une erreur, sinon un fichier
    # supprimé du coffre passerait inaperçu au déploiement suivant.
    optional() { [ "${opt:-}" = oui ]; }

    case "$verb" in
        encrypt)
            [ -f /keys/keys.txt ] || fail "clé age absente (/keys/keys.txt) : sans elle, rien ne sera relisible"
            require_target_repo
            if [ ! -f "$C" ]; then
                if optional; then
                    echo "  ignoré (pas encore créé) : $C"
                    continue
                fi
                fail "secret en clair introuvable: $C"
            fi
            mkdir -p "$(dirname "$enc")"
            tmp="$(mktemp "${enc}.tmp.XXXXXX")"
            sops_encrypt "$C" "$tmp" "$type" "$enc" || { rm -f "$tmp"; fail "chiffrement impossible pour $C"; }

            # Le bloc fraîchement chiffré est relu ET comparé octet pour octet avant
            # remplacement : c'est ici, pas sur le serveur, qu'on découvre qu'un
            # format reformate le fichier (commentaires perdus, guillemets ajoutés).
            chk="$(mktemp "chk.XXXXXX")"
            if ! sops_decrypt "$tmp" "$enc" > "$chk" 2>/dev/null; then
                rm -f "$tmp" "$chk"
                fail "$enc: le bloc fraîchement chiffré ne se relit pas"
            fi
            if ! cmp -s "$chk" "$C"; then
                echo "  Le déchiffré ne reproduit pas le clair. S'il ne manque que des"
                echo "  commentaires ou des guillemets, passer cette entrée en type"
                echo "  « binary » (fidélité octet garantie, noms de variables opaques)."
                diff <(cat "$C") <(cat "$chk") | grep -oE '^[<>] [A-Za-z_]+=' | head -10
                rm -f "$tmp" "$chk"
                fail "$enc: round-trip non fidèle, chiffrement abandonné"
            fi
            rm -f "$chk"
            mv "$tmp" "$enc"
            chmod 0644 "$enc"
            echo "  chiffré : $C → $(basename "$enc")"
            ;;

        materialize)
            [ -f /keys/keys.txt ] || fail "clé age absente (/keys/keys.txt) : vérifiez AGE_KEY_FILE"
            require_target_repo
            if [ ! -f "$enc" ]; then
                if optional && [ ! -f "$C" ]; then
                    echo "  absent (facultatif, pas encore scellé) : $(basename "$enc")"
                    continue
                fi
                die_hint=""
                if optional; then
                    die_hint=" — clair présent mais bloc chiffré absent : lancer « ./deploy.sh --encrypt » depuis le poste de dev"
                fi
                fail "secret chiffré manquant: $enc$die_hint"
            fi
            mkdir -p "$(dirname "$C")"
            umask 077
            tmp="$(mktemp "$C.tmp.XXXXXX")"
            sops_decrypt "$enc" "$enc" > "$tmp" || { rm -f "$tmp"; fail "déchiffrement impossible pour $enc (clé age invalide ou fichier corrompu)"; }
            # Deux garde-fous, indépendants du type de chiffrement : un blob vide
            # n'est jamais posé sur un fichier qui marche, et un déchiffrage tronqué
            # (cle age partiellement differente, disque plein, montage deplace) est
            # rejete au compte de variables.
            [ -s "$tmp" ] || { rm -f "$tmp"; fail "$enc: contenu déchiffré vide, l'ancien fichier est conservé"; }
            if [ "$minvars" -gt 0 ]; then
                n=$(count_vars "$tmp")
                [ "$n" -ge "$minvars" ] || { rm -f "$tmp"; fail "$C: $n variables déchiffrées, $minvars attendues (l'ancien fichier est conservé)"; }
            fi
            # Pose : on ne passe pas par « install » (mesuré : il refuse avec
            # « File exists » sur un bind mount Docker Desktop dont le répertoire
            # est déjà vue, alors que le fichier cible n'existe plus). mv remplace
            # inconditionnellement, et on n'arrive ici qu'avec un contenu déchiffré
            # complet en main — l'ancien fichier n'est donc jamais perdu pour rien.
            mv -f "$tmp" "$C"
            chmod "$mode" "$C"
            if [ "$grp" != "-" ]; then
                chgrp "$grp" "$C" 2>/dev/null || \
                    echo "  (groupe $grp non applicable sur ce système de fichiers — sur le serveur Debian, il le sera)"
            fi
            rm -f "$tmp"
            echo "  matérialisé : $(basename "$enc") → $C ($mode)"
            ;;

        verify)
            require_target_repo
            if [ ! -f "$enc" ]; then
                if optional && [ ! -f "$C" ]; then
                    echo "  ABSENT    $enc (facultatif, pas encore scellé)"
                    continue
                fi
                echo "  ABSENT    $enc"; VERDICT=1; continue
            fi
            tmp="$(mktemp "verify.XXXXXX")"
            if ! sops_decrypt "$enc" "$enc" > "$tmp" 2>/dev/null; then
                echo "  ILISIBLE  $enc (mauvaise clé age ?)"
                rm -f "$tmp"; VERDICT=1; continue
            fi
            if cmp -s "$tmp" "$C"; then
                echo "  FIDÈLE    $(basename "$enc") == $C (octet pour octet)"
            else
                # Comparaison nominale uniquement : les valeurs ne sont jamais affichées.
                echo "  DIFFÉRENT $(basename "$enc") != $C ($( [ -f "$C" ] && count_vars "$C" || echo 0) variables claires, $(count_vars "$tmp") déchiffrées)"
                # « || true » : diff sort en 1 quand les fichiers diffèrent, et « set -euo
                # pipefail » tuerait la boucle au premier écart — les entrées suivantes
                # ne seraient plus contrôlées, et une absente du coffre passerait inaperçue.
                diff <( [ -f "$C" ] && grep -oE '^[A-Za-z_]+' "$C" || true) <(grep -oE '^[A-Za-z_]+' "$tmp" || true) | head -20 || true
                rm -f "$tmp"; VERDICT=1; continue
            fi
            rm -f "$tmp"
            ;;

        status)
            e=absent; c=absent
            [ -f "$enc" ] && e=chiffré
            [ -f "$C" ] && c=présent
            if optional && [ "$e" = absent ] && [ "$c" = absent ]; then
                e='facultatif'
            fi
            printf '  %-46s %-9s   %-44s %s\n' "$enc" "$e" "$C" "$c"
            ;;

        *) usage ;;
    esac
done < "$MANIFEST"

case "$verb" in
    encrypt) echo "Le coffre est à jour : git add deploy/secrets && git commit pour le diffuser." ;;
    verify)  [ "${VERDICT:-0}" -eq 0 ] || fail "au moins un secret ne round-trippe pas" ;;
esac
