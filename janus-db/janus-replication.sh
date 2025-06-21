#!/bin/bash

# Janus Database Replication Manager
# Script unique pour gérer la réplication de base de données Janus
# Usage: ./janus-replication.sh <command> [options]

set -e

# Configuration par défaut
SOURCE_CONTAINER="${SOURCE_CONTAINER:-janus-mysql}"
SOURCE_USER="${SOURCE_USER:-root}"
SOURCE_PASSWORD="${SOURCE_PASSWORD:-root}"
SOURCE_DB="${SOURCE_DB:-janus_db}"

TARGET_CONTAINER="${TARGET_CONTAINER:-janus-mysql-replica}"
TARGET_USER="${TARGET_USER:-root}"
TARGET_PASSWORD="${TARGET_PASSWORD:-replica_password}"
TARGET_DB="${TARGET_DB:-janus_db}"

SYNC_INTERVAL="${SYNC_INTERVAL:-10}"
CHANGE_LOG_TABLE="replication_log"

# Couleurs pour l'affichage
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Fonction d'aide
show_help() {
    echo -e "${BLUE}🔧 Janus Database Replication Manager${NC}"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commandes disponibles:"
    echo "  setup              - Configuration initiale (triggers + conteneur réplique)"
    echo "  sync               - Synchronisation manuelle unique"
    echo "  auto-sync          - Synchronisation automatique continue"
    echo "  backup [name]      - Sauvegarde rapide"
    echo "  restore <file>     - Restauration"
    echo "  status             - Statut de la réplication"
    echo "  cleanup            - Nettoyer les triggers et tables de log"
    echo "  help               - Afficher cette aide"
    echo ""
    echo "Variables d'environnement (optionnelles):"
    echo "  SOURCE_CONTAINER   - Conteneur source (défaut: janus-mysql)"
    echo "  TARGET_CONTAINER   - Conteneur cible (défaut: janus-mysql-replica)"
    echo "  SYNC_INTERVAL      - Intervalle de synchronisation en secondes (défaut: 10)"
    echo ""
    echo "Exemples:"
    echo "  $0 setup                    # Configuration complète"
    echo "  $0 auto-sync               # Démarrer la synchronisation automatique"
    echo "  $0 backup ma_sauvegarde    # Créer une sauvegarde"
    echo "  $0 status                  # Vérifier l'état"
}

# Fonction pour exécuter des commandes MySQL
mysql_exec() {
    local container=$1
    local user=$2
    local password=$3
    local database=$4
    local query=$5
    
    docker exec "$container" mysql -u "$user" -p"$password" "$database" -e "$query" 2>/dev/null
}

# Fonction de vérification des conteneurs
check_containers() {
    if ! docker ps | grep -q "$SOURCE_CONTAINER"; then
        echo -e "${RED}❌ Conteneur source '$SOURCE_CONTAINER' non trouvé${NC}"
        exit 1
    fi
    
    if ! docker ps -a --format "table {{.Names}}" | grep -q "^$TARGET_CONTAINER$"; then
        echo -e "${YELLOW}📦 Création du conteneur cible '$TARGET_CONTAINER'...${NC}"
        docker run -d \
            --name "$TARGET_CONTAINER" \
            -e MYSQL_ROOT_PASSWORD="$TARGET_PASSWORD" \
            -e MYSQL_DATABASE="$TARGET_DB" \
            -p 3307:3306 \
            mysql:latest
        
        echo -e "${YELLOW}⏳ Attente du démarrage de MySQL...${NC}"
        sleep 30
        
        for i in {1..30}; do
            if docker exec "$TARGET_CONTAINER" mysql -u "$TARGET_USER" -p"$TARGET_PASSWORD" -e "SELECT 1;" > /dev/null 2>&1; then
                break
            fi
            echo "⏳ Attente MySQL... ($i/30)"
            sleep 2
        done
    else
        docker start "$TARGET_CONTAINER" 2>/dev/null || true
        sleep 5
    fi
}

# Fonction d'installation des triggers
install_triggers() {
    echo -e "${BLUE}🔧 Installation des triggers sur toutes les tables${NC}"
    
    # Créer la table de log
    mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "$SOURCE_DB" "
    CREATE TABLE IF NOT EXISTS $CHANGE_LOG_TABLE (
        id INT AUTO_INCREMENT PRIMARY KEY,
        table_name VARCHAR(64) NOT NULL,
        operation ENUM('INSERT', 'UPDATE', 'DELETE') NOT NULL,
        record_id INT NOT NULL,
        timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        synced BOOLEAN DEFAULT FALSE,
        INDEX idx_synced (synced),
        INDEX idx_timestamp (timestamp)
    );"
    
    # Obtenir toutes les tables
    TABLES=$(docker exec "$SOURCE_CONTAINER" mysql -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" "$SOURCE_DB" -e "SHOW TABLES;" 2>/dev/null | grep -v "Tables_in_$SOURCE_DB" | grep -v "$CHANGE_LOG_TABLE" || true)
    
    echo "📊 Tables détectées:"
    echo "$TABLES" | while read table; do
        echo "   - $table"
    done
    
    # Pour chaque table, créer les triggers
    echo "$TABLES" | while read table; do
        if [ -n "$table" ]; then
            # Créer les triggers directement sans utiliser de fichier temporaire
            docker exec "$SOURCE_CONTAINER" mysql -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" "$SOURCE_DB" -e "
            DROP TRIGGER IF EXISTS ${table}_insert_trigger;
            DROP TRIGGER IF EXISTS ${table}_update_trigger;
            DROP TRIGGER IF EXISTS ${table}_delete_trigger;" 2>/dev/null || true
            
            docker exec "$SOURCE_CONTAINER" mysql -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" "$SOURCE_DB" -e "
            DELIMITER $$
            CREATE TRIGGER ${table}_insert_trigger
                AFTER INSERT ON \`$table\`
                FOR EACH ROW
            BEGIN
                INSERT INTO $CHANGE_LOG_TABLE (table_name, operation, record_id)
                VALUES ('$table', 'INSERT', COALESCE(NEW.id, 0));
            END$$
            DELIMITER ;" 2>/dev/null || echo "Trigger INSERT pour $table ignoré"
            
            docker exec "$SOURCE_CONTAINER" mysql -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" "$SOURCE_DB" -e "
            DELIMITER $$
            CREATE TRIGGER ${table}_update_trigger
                AFTER UPDATE ON \`$table\`
                FOR EACH ROW
            BEGIN
                INSERT INTO $CHANGE_LOG_TABLE (table_name, operation, record_id)
                VALUES ('$table', 'UPDATE', COALESCE(NEW.id, OLD.id, 0));
            END$$
            DELIMITER ;" 2>/dev/null || echo "Trigger UPDATE pour $table ignoré"
            
            docker exec "$SOURCE_CONTAINER" mysql -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" "$SOURCE_DB" -e "
            DELIMITER $$
            CREATE TRIGGER ${table}_delete_trigger
                AFTER DELETE ON \`$table\`
                FOR EACH ROW
            BEGIN
                INSERT INTO $CHANGE_LOG_TABLE (table_name, operation, record_id)
                VALUES ('$table', 'DELETE', COALESCE(OLD.id, 0));
            END$$
            DELIMITER ;" 2>/dev/null || echo "Trigger DELETE pour $table ignoré"
        fi
    done
    
    echo -e "${GREEN}✅ Triggers installés avec succès${NC}"
}

# Fonction de synchronisation
sync_data() {
    local mode=${1:-"manual"}
    
    if [ "$mode" = "auto" ]; then
        echo -e "${BLUE}🔄 Synchronisation automatique démarrée${NC}"
        echo "📝 Appuyez sur Ctrl+C pour arrêter"
        trap 'echo -e "\n🛑 Arrêt de la synchronisation..."; exit 0' INT TERM
    fi
    
    while true; do
        if [ "$mode" = "auto" ]; then
            echo "🔍 Vérification... $(date '+%H:%M:%S')"
        fi
        
        # Vérifier les changements
        local changes
        changes=$(mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "$SOURCE_DB" "SELECT COUNT(*) FROM $CHANGE_LOG_TABLE WHERE synced = FALSE;" | tail -1)
        
        if [ "$changes" -gt 0 ]; then
            echo -e "${YELLOW}📊 $changes changements détectés, synchronisation...${NC}"
            
            # Synchronisation
            TEMP_FILE="/tmp/janus_sync_$(date +%s).sql"
            docker exec "$SOURCE_CONTAINER" mysqldump -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" \
                --single-transaction --no-create-db \
                --ignore-table="$SOURCE_DB.$CHANGE_LOG_TABLE" \
                "$SOURCE_DB" > "$TEMP_FILE" 2>/dev/null
            
            docker exec -i "$TARGET_CONTAINER" mysql -u "$TARGET_USER" -p"$TARGET_PASSWORD" "$TARGET_DB" < "$TEMP_FILE" 2>/dev/null
            
            mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "$SOURCE_DB" "UPDATE $CHANGE_LOG_TABLE SET synced = TRUE WHERE synced = FALSE;"
            
            rm -f "$TEMP_FILE"
            echo -e "${GREEN}✅ Synchronisation terminée${NC}"
            
            # Vérification
            local source_count target_count
            source_count=$(mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "$SOURCE_DB" "SELECT COUNT(*) FROM users;" | tail -1)
            target_count=$(mysql_exec "$TARGET_CONTAINER" "$TARGET_USER" "$TARGET_PASSWORD" "$TARGET_DB" "SELECT COUNT(*) FROM users;" | tail -1)
            echo "📊 Utilisateurs - Source: $source_count, Cible: $target_count"
        else
            if [ "$mode" = "auto" ]; then
                echo "💤 Aucun changement"
            else
                echo -e "${GREEN}✅ Aucun changement à synchroniser${NC}"
            fi
        fi
        
        if [ "$mode" != "auto" ]; then
            break
        fi
        
        sleep "$SYNC_INTERVAL"
    done
}

# Fonction de sauvegarde
backup_db() {
    local backup_name="${1:-janus_backup_$(date +%Y%m%d_%H%M%S)}"
    local backup_file="${backup_name}.sql"
    
    echo -e "${BLUE}💾 Sauvegarde de la base de données${NC}"
    echo "📁 Fichier: $backup_file"
    
    docker exec "$SOURCE_CONTAINER" mysqldump -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" \
        --single-transaction --routines --triggers \
        "$SOURCE_DB" > "$backup_file" 2>/dev/null
    
    gzip "$backup_file"
    local backup_size=$(du -h "${backup_file}.gz" | cut -f1)
    echo -e "${GREEN}✅ Sauvegarde terminée: ${backup_file}.gz ($backup_size)${NC}"
}

# Fonction de restauration
restore_db() {
    local backup_file="$1"
    local target_db="${2:-janus_db_restored}"
    
    if [ -z "$backup_file" ]; then
        echo -e "${RED}❌ Vous devez spécifier le fichier de sauvegarde${NC}"
        return 1
    fi
    
    if [ ! -f "$backup_file" ]; then
        echo -e "${RED}❌ Fichier non trouvé: $backup_file${NC}"
        return 1
    fi
    
    echo -e "${BLUE}📥 Restauration de la base de données${NC}"
    echo "📁 Fichier: $backup_file"
    echo "🗄️  Base cible: $target_db"
    
    mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "" "DROP DATABASE IF EXISTS $target_db; CREATE DATABASE $target_db;"
    
    if [[ "$backup_file" == *.gz ]]; then
        gunzip -c "$backup_file" | docker exec -i "$SOURCE_CONTAINER" mysql -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" "$target_db" 2>/dev/null
    else
        docker exec -i "$SOURCE_CONTAINER" mysql -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" "$target_db" < "$backup_file" 2>/dev/null
    fi
    
    echo -e "${GREEN}✅ Restauration terminée dans '$target_db'${NC}"
}

# Fonction de statut
show_status() {
    echo -e "${BLUE}📊 Statut de la réplication Janus${NC}"
    echo ""
    
    # Vérifier les conteneurs
    echo "🐳 Conteneurs:"
    if docker ps | grep -q "$SOURCE_CONTAINER"; then
        echo -e "   ✅ Source: $SOURCE_CONTAINER"
    else
        echo -e "   ❌ Source: $SOURCE_CONTAINER (arrêté)"
    fi
    
    if docker ps | grep -q "$TARGET_CONTAINER"; then
        echo -e "   ✅ Cible: $TARGET_CONTAINER"
    else
        echo -e "   ❌ Cible: $TARGET_CONTAINER (arrêté)"
        return
    fi
    
    # Compter les utilisateurs
    local source_users target_users
    source_users=$(mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "$SOURCE_DB" "SELECT COUNT(*) FROM users;" | tail -1)
    target_users=$(mysql_exec "$TARGET_CONTAINER" "$TARGET_USER" "$TARGET_PASSWORD" "$TARGET_DB" "SELECT COUNT(*) FROM users;" | tail -1)
    
    echo ""
    echo "👥 Utilisateurs:"
    echo "   Source: $source_users"
    echo "   Cible: $target_users"
    
    if [ "$source_users" = "$target_users" ]; then
        echo -e "   ${GREEN}✅ Synchronisées${NC}"
    else
        echo -e "   ${YELLOW}⚠️  Différence détectée${NC}"
    fi
    
    # Changements en attente
    local pending_changes
    pending_changes=$(mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "$SOURCE_DB" "SELECT COUNT(*) FROM $CHANGE_LOG_TABLE WHERE synced = FALSE;" 2>/dev/null | tail -1 || echo "0")
    
    echo ""
    echo "🔄 Changements en attente: $pending_changes"
    
    # Derniers changements
    echo ""
    echo "📋 Derniers changements:"
    mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "$SOURCE_DB" "SELECT CONCAT('  ', table_name, ' (', operation, ') - ', timestamp) FROM $CHANGE_LOG_TABLE ORDER BY timestamp DESC LIMIT 5;" 2>/dev/null || echo "   Aucun changement enregistré"
}

# Fonction de nettoyage
cleanup() {
    echo -e "${BLUE}🧹 Nettoyage du système de réplication${NC}"
    
    # Supprimer tous les triggers
    local triggers
    triggers=$(mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "$SOURCE_DB" "SELECT TRIGGER_NAME FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = '$SOURCE_DB';" | tail -n +2)
    
    if [ -n "$triggers" ]; then
        echo "$triggers" | while read trigger; do
            if [ -n "$trigger" ]; then
                mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "$SOURCE_DB" "DROP TRIGGER IF EXISTS \`$trigger\`;"
            fi
        done
    fi
    
    # Supprimer la table de log
    mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "$SOURCE_DB" "DROP TABLE IF EXISTS $CHANGE_LOG_TABLE;"
    
    echo -e "${GREEN}✅ Nettoyage terminé${NC}"
}

# Programme principal
case "${1:-}" in
    "setup")
        echo -e "${BLUE}🚀 Configuration complète de la réplication Janus${NC}"
        check_containers
        install_triggers
        echo ""
        echo -e "${GREEN}✅ Configuration terminée!${NC}"
        echo "🎯 Pour démarrer la synchronisation automatique:"
        echo "   $0 auto-sync"
        ;;
    
    "sync")
        check_containers
        sync_data "manual"
        ;;
    
    "auto-sync")
        check_containers
        sync_data "auto"
        ;;
    
    "backup")
        backup_db "$2"
        ;;
    
    "restore")
        restore_db "$2" "$3"
        ;;
    
    "status")
        show_status
        ;;
    
    "cleanup")
        cleanup
        ;;
    
    "help"|"-h"|"--help"|"")
        show_help
        ;;
    
    *)
        echo -e "${RED}❌ Commande non reconnue: $1${NC}"
        echo ""
        show_help
        exit 1
        ;;
esac
