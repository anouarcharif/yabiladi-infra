#!/bin/bash
# ============================================================================
# Script de génération de la clé SSH pour la récupération des backups MariaDB
# ============================================================================
# Ce script génère une clé SSH sur l'hôte et affiche les instructions pour
# la copier sur le serveur MariaDB.
#
# Usage :
#   bash tools/backup/generate-ssh-key.sh [email]
#
# Exemple :
#   bash tools/backup/generate-ssh-key.sh backup@yabiladi.com
#
# Ce script :
#   1. Génère une clé SSH RSA 4096 bits dans deploy/secrets/id_rsa_mariadb
#   2. Affiche la clé publique
#   3. Affiche les instructions pour la copier sur le serveur MariaDB
#
# Prérequis :
#   - ssh-keygen installé
#   - Le répertoire deploy/secrets/ doit exister
# ============================================================================

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
KEY_DIR="deploy/secrets"
KEY_NAME="id_rsa_mariadb"
KEY_PATH="${KEY_DIR}/${KEY_NAME}"
EMAIL="${1:-backup@yabiladi.com}"

# ============================================================================
# Fonctions
# ============================================================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
    log "ERREUR: $*"
    exit 1
}

check_prerequisites() {
    if ! command -v ssh-keygen &> /dev/null; then
        die "ssh-keygen non installé"
    fi
    
    if [[ ! -d "$KEY_DIR" ]]; then
        log "Création du répertoire: ${KEY_DIR}"
        mkdir -p "$KEY_DIR"
        chmod 700 "$KEY_DIR"
    fi
}

generate_key() {
    if [[ -f "$KEY_PATH" ]]; then
        log "Clé déjà présente: ${KEY_PATH}"
        log "Pour la régénérer: rm ${KEY_PATH}* et relancer ce script"
        return 0
    fi
    
    log "Génération de la clé SSH..."
    log "Email: ${EMAIL}"
    log "Chemin: ${KEY_PATH}"
    
    ssh-keygen -t rsa -b 4096 -f "$KEY_PATH" -N "" -C "$EMAIL"
    
    chmod 600 "$KEY_PATH"
    chmod 644 "${KEY_PATH}.pub"
    
    log "Clé générée avec succès"
}

print_public_key() {
    log ""
    log "=========================================="
    log "CLÉ PUBLIQUE SSH"
    log "=========================================="
    log ""
    cat "${KEY_PATH}.pub"
    log ""
}

print_instructions() {
    log "=========================================="
    log "INSTRUCTIONS POUR LE SERVEUR MARIA DB"
    log "=========================================="
    log ""
    log "1. Connectez-vous au serveur MariaDB (57.128.22.220)"
    log ""
    log "2. Créez l'utilisateur SSH s'il n'existe pas :"
    log "   sudo useradd -m -s /bin/bash backup_ssh"
    log "   sudo passwd backup_ssh"
    log "   sudo mkdir -p ~backup_ssh/.ssh"
    log "   sudo chmod 700 ~backup_ssh/.ssh"
    log "   sudo chown backup_ssh:backup_ssh ~backup_ssh/.ssh"
    log ""
    log "3. Ajoutez la clé publique dans authorized_keys :"
    log "   sudo nano ~backup_ssh/.ssh/authorized_keys"
    log ""
    log "   Collez la clé publique affichée ci-dessus, ou depuis une machine qui"
    log "   a ssh-copy-id :"
    log "   ssh-copy-id -i ${KEY_PATH}.pub backup_ssh@57.128.22.220"
    log ""
    log "   Sous Windows (pas de ssh-copy-id), en PowerShell :"
    log "   \$key = (Get-Content ${KEY_PATH}.pub -Raw).Trim()"
    log "   ssh backup_ssh@57.128.22.220 \"mkdir -p ~/.ssh; chmod 700 ~/.ssh; echo '\$key' >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys\""
    log ""
    log "4. Configurez les permissions :"
    log "   sudo chmod 600 ~backup_ssh/.ssh/authorized_keys"
    log "   sudo chown backup_ssh:backup_ssh ~backup_ssh/.ssh/authorized_keys"
    log ""
    log "5. Testez la connexion depuis l'hôte :"
    log "   ssh -i ${KEY_PATH} backup_ssh@57.128.22.220"
    log ""
    log "6. Déployez les scripts de backup sur le serveur MariaDB :"
    log "   - mariabackup-daily.sh dans /opt/scripts/"
    log "   - mariabackup-restore.sh dans /opt/scripts/"
    log "   - create-backup-user.sql (à exécuter avec mysql -u root)"
    log ""
    log "7. Créez l'utilisateur MySQL de backup :"
    log "   sudo mysql -u root < create-backup-user.sql"
    log "   (modifiez le mot de passe dans le fichier SQL avant !)"
    log ""
    log "8. Créez le répertoire de backup :"
    log "   sudo mkdir -p /data/backup/files/mariadb"
    log "   sudo chown mysql:mysql /data/backup/files/mariadb"
    log "   sudo chmod 750 /data/backup/files/mariadb"
    log ""
    log "9. Testez le backup sur le serveur MariaDB :"
    log "   sudo /opt/scripts/mariabackup-daily.sh 7"
    log "   ls -lh /data/backup/files/mariadb/"
    log ""
    log "=========================================="
    log "CONFIGURATION DAGU + DBACKUP"
    log "=========================================="
    log ""
    log "1. Renseignez dans docker/legacy/credentials.env (non versionné) :"
    log "   MARIADB_SSH_HOST=57.128.22.220"
    log "   MARIADB_SSH_USER=backup_ssh"
    log "   MARIADB_SSH_PORT=22"
    log "   MARIADB_REMOTE_SCRIPT=/opt/scripts/mariabackup-daily.sh"
    log "   MARIADB_REMOTE_BACKUP_DIR=/data/backup/files/mariadb"
    log "   MARIADB_LOCAL_BACKUP_DIR=/backup/mariadb-backups"
    log "   MARIADB_RETENTION_DAYS=7"
    log ""
    log "   MARIADB_LOCAL_BACKUP_DIR est le chemin DANS le conteneur (volume"
    log "   monté depuis MARIADB_BACKUP_HOST_PATH), pas un chemin hôte."
    log ""
    log "2. La clé privée est montée dans le conteneur Dagu par compose.yaml :"
    log "   ${KEY_PATH} → /run/secrets/mariadb_ssh_key"
    log "   (surcharge possible avec MARIADB_SSH_KEY_PATH dans .env.local)."
    log "   Le DAG en fait une copie 0600 dans /tmp à chaque exécution."
    log ""
    log "3. Rechargez Dagu :"
    log "   docker compose up -d dagu"
    log ""
    log "4. Testez le DAG manuellement :"
    log "   docker compose exec dagu dagu start mariadb_fetch"
    log "   Puis vérifiez les archives :"
    log "   docker compose exec dagu ls -lh /backup/mariadb-backups/"
    log ""
    log "5. Planification : décommentez « schedule: \"0 2 * * *\" » dans"
    log "   docker/dagu/dags/mariadb_fetch.yaml et rechargez Dagu. Il n'y a"
    log "   NI cron hôte NI script à installer : le DAG fait tout."
    log ""
    log "6. Activez le job DBackup dans l'interface :"
    log "   → Jobs → 'Fichiers - mariadb-physical' → Activer"
    log "   → Associez un profil de chiffrement (recommandé)"
    log ""
    log "=========================================="
    log ""
    log "Clé privée : ${KEY_PATH}"
    log "Clé publique : ${KEY_PATH}.pub"
    log ""
    log "⚠️  NE JAMAIS COMMITER LA CLÉ PRIVÉE DANS GIT"
    log "⚠️  Le fichier est déjà exclu dans .gitignore"
    log ""
}

# ============================================================================
# Exécution
# ============================================================================
main() {
    log "=========================================="
    log "Génération de la clé SSH pour MariaDB"
    log "=========================================="
    log ""
    
    check_prerequisites
    generate_key
    print_public_key
    print_instructions
}

main "$@"
