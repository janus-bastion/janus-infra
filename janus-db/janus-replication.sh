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

# Help function
show_help() {
    echo -e "${BLUE}Janus Database Replication Manager${NC}"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Available commands:"
    echo "  setup              - Initial configuration (triggers + replica container)"
    echo "  sync               - One-time manual synchronization"
    echo "  auto-sync          - Continuous automatic synchronization"
    echo "  backup [name]      - Quick backup"
    echo "  restore <file>     - Restoration"
    echo "  status             - Replication status"
    echo "  cleanup            - Clean triggers and log tables"
    echo "  help               - Show this help"
    echo ""
    echo "Optional environment variables:"
    echo "  SOURCE_CONTAINER   - Source container (default: janus-mysql)"
    echo "  TARGET_CONTAINER   - Target container (default: janus-mysql-replica)"
    echo "  SYNC_INTERVAL      - Sync interval in seconds (default: 10)"
    echo ""
    echo "Examples:"
    echo "  $0 setup                    # Complete configuration"
    echo "  $0 auto-sync               # Start automatic synchronization"
    echo "  $0 backup my_backup         # Create a backup"
    echo "  $0 status                   # Check status"
}

# Function to execute MySQL commands
mysql_exec() {
    local container=$1
    local user=$2
    local password=$3
    local database=$4
    local query=$5
    
    docker exec "$container" mysql -u "$user" -p"$password" "$database" -e "$query" 2>/dev/null
}

# Container verification function
check_containers() {
    if ! docker ps | grep -q "$SOURCE_CONTAINER"; then
        echo -e "${RED}ERROR: Source container '$SOURCE_CONTAINER' not found${NC}"
        exit 1
    fi
    
    if ! docker ps -a --format "table {{.Names}}" | grep -q "^$TARGET_CONTAINER$"; then
        echo -e "${YELLOW}Creating target container '$TARGET_CONTAINER'...${NC}"
        docker run -d \
            --name "$TARGET_CONTAINER" \
            --network janus-infra_janus-prod-net \
            -e MYSQL_ROOT_PASSWORD="$TARGET_PASSWORD" \
            -e MYSQL_DATABASE="$TARGET_DB" \
            -p 3307:3306 \
            mysql:latest
        
        echo -e "${YELLOW}Waiting for MySQL startup...${NC}"
        sleep 30
        
        for i in {1..30}; do
            if docker exec "$TARGET_CONTAINER" mysql -u "$TARGET_USER" -p"$TARGET_PASSWORD" -e "SELECT 1;" > /dev/null 2>&1; then
                break
            fi
            echo "Waiting for MySQL... ($i/30)"
            sleep 2
        done
        
        # Complete initial synchronization of existing data
        echo -e "${BLUE}Initial synchronization of existing data...${NC}"
        TEMP_INIT_FILE="/tmp/janus_initial_sync_$(date +%s).sql"
        docker exec "$SOURCE_CONTAINER" mysqldump -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" \
            --single-transaction --no-create-db \
            "$SOURCE_DB" > "$TEMP_INIT_FILE" 2>/dev/null
        
        docker exec -i "$TARGET_CONTAINER" mysql -u "$TARGET_USER" -p"$TARGET_PASSWORD" "$TARGET_DB" < "$TEMP_INIT_FILE" 2>/dev/null
        rm -f "$TEMP_INIT_FILE"
        echo -e "${GREEN}Initial synchronization completed${NC}"
    else
        docker start "$TARGET_CONTAINER" 2>/dev/null || true
        sleep 5
    fi
}

# Trigger installation function
install_triggers() {
    echo -e "${BLUE}Installing triggers on all tables${NC}"
    
    # Create log table
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
    
    # Get all tables
    TABLES=$(docker exec "$SOURCE_CONTAINER" mysql -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" "$SOURCE_DB" -e "SHOW TABLES;" 2>/dev/null | grep -v "Tables_in_$SOURCE_DB" | grep -v "$CHANGE_LOG_TABLE" || true)
    
    echo "Detected tables:"
    echo "$TABLES" | while read table; do
        echo "   - $table"
    done
    
    # Create triggers for each table
    echo "$TABLES" | while read table; do
        if [ -n "$table" ]; then
            # Create triggers directly without using temporary files
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
            DELIMITER ;" 2>/dev/null || echo "INSERT trigger for $table ignored"
            
            docker exec "$SOURCE_CONTAINER" mysql -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" "$SOURCE_DB" -e "
            DELIMITER $$
            CREATE TRIGGER ${table}_update_trigger
                AFTER UPDATE ON \`$table\`
                FOR EACH ROW
            BEGIN
                INSERT INTO $CHANGE_LOG_TABLE (table_name, operation, record_id)
                VALUES ('$table', 'UPDATE', COALESCE(NEW.id, OLD.id, 0));
            END$$
            DELIMITER ;" 2>/dev/null || echo "UPDATE trigger for $table ignored"
            
            docker exec "$SOURCE_CONTAINER" mysql -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" "$SOURCE_DB" -e "
            DELIMITER $$
            CREATE TRIGGER ${table}_delete_trigger
                AFTER DELETE ON \`$table\`
                FOR EACH ROW
            BEGIN
                INSERT INTO $CHANGE_LOG_TABLE (table_name, operation, record_id)
                VALUES ('$table', 'DELETE', COALESCE(OLD.id, 0));
            END$$
            DELIMITER ;" 2>/dev/null || echo "DELETE trigger for $table ignored"
        fi
    done
    
    echo -e "${GREEN}Triggers installed successfully${NC}"
}

# Synchronization function
sync_data() {
    local mode=${1:-"manual"}
    
    if [ "$mode" = "auto" ]; then
        echo -e "${BLUE}Automatic synchronization started${NC}"
        echo "Press Ctrl+C to stop"
        trap 'echo -e "\nStopping synchronization..."; exit 0' INT TERM
    fi
    
    while true; do
        if [ "$mode" = "auto" ]; then
            echo "Checking... $(date '+%H:%M:%S')"
        fi
        
        # Check for changes
        local changes
        changes=$(mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "$SOURCE_DB" "SELECT COUNT(*) FROM $CHANGE_LOG_TABLE WHERE synced = FALSE;" | tail -1)
        
        if [ "$changes" -gt 0 ]; then
            echo -e "${YELLOW}$changes changes detected, synchronizing...${NC}"
            
            # Synchronization
            TEMP_FILE="/tmp/janus_sync_$(date +%s).sql"
            docker exec "$SOURCE_CONTAINER" mysqldump -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" \
                --single-transaction --no-create-db \
                --ignore-table="$SOURCE_DB.$CHANGE_LOG_TABLE" \
                "$SOURCE_DB" > "$TEMP_FILE" 2>/dev/null
            
            docker exec -i "$TARGET_CONTAINER" mysql -u "$TARGET_USER" -p"$TARGET_PASSWORD" "$TARGET_DB" < "$TEMP_FILE" 2>/dev/null
            
            mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "$SOURCE_DB" "UPDATE $CHANGE_LOG_TABLE SET synced = TRUE WHERE synced = FALSE;"
            
            rm -f "$TEMP_FILE"
            echo -e "${GREEN}Synchronization completed${NC}"
            
            # Verification
            local source_count target_count
            source_count=$(mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "$SOURCE_DB" "SELECT COUNT(*) FROM users;" | tail -1)
            target_count=$(mysql_exec "$TARGET_CONTAINER" "$TARGET_USER" "$TARGET_PASSWORD" "$TARGET_DB" "SELECT COUNT(*) FROM users;" | tail -1)
            echo "Users - Source: $source_count, Target: $target_count"
        else
            if [ "$mode" = "auto" ]; then
                echo "No changes"
            else
                echo -e "${GREEN}No changes to synchronize${NC}"
            fi
        fi
        
        if [ "$mode" != "auto" ]; then
            break
        fi
        
        sleep "$SYNC_INTERVAL"
    done
}

# Backup function
backup_db() {
    local backup_name="${1:-janus_backup_$(date +%Y%m%d_%H%M%S)}"
    local backup_file="${backup_name}.sql"
    
    echo -e "${BLUE}Database backup${NC}"
    echo "File: $backup_file"
    
    docker exec "$SOURCE_CONTAINER" mysqldump -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" \
        --single-transaction --routines --triggers \
        "$SOURCE_DB" > "$backup_file" 2>/dev/null
    
    gzip "$backup_file"
    local backup_size=$(du -h "${backup_file}.gz" | cut -f1)
    echo -e "${GREEN}Backup completed: ${backup_file}.gz ($backup_size)${NC}"
}

# Restore function
restore_db() {
    local backup_file="$1"
    local target_db="${2:-janus_db_restored}"
    
    if [ -z "$backup_file" ]; then
        echo -e "${RED}ERROR: You must specify the backup file${NC}"
        return 1
    fi
    
    if [ ! -f "$backup_file" ]; then
        echo -e "${RED}ERROR: File not found: $backup_file${NC}"
        return 1
    fi
    
    echo -e "${BLUE}Database restoration${NC}"
    echo "File: $backup_file"
    echo "Target database: $target_db"
    
    mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "" "DROP DATABASE IF EXISTS $target_db; CREATE DATABASE $target_db;"
    
    if [[ "$backup_file" == *.gz ]]; then
        gunzip -c "$backup_file" | docker exec -i "$SOURCE_CONTAINER" mysql -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" "$target_db" 2>/dev/null
    else
        docker exec -i "$SOURCE_CONTAINER" mysql -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" "$target_db" < "$backup_file" 2>/dev/null
    fi
    
    echo -e "${GREEN}Restoration completed in '$target_db'${NC}"
}

# Status function
show_status() {
    echo -e "${BLUE}Janus Replication Status${NC}"
    echo ""
    
    # Check containers
    echo "Containers:"
    if docker ps | grep -q "$SOURCE_CONTAINER"; then
        echo -e "   OK Source: $SOURCE_CONTAINER"
    else
        echo -e "   ERROR Source: $SOURCE_CONTAINER (stopped)"
    fi
    
    if docker ps | grep -q "$TARGET_CONTAINER"; then
        echo -e "   OK Target: $TARGET_CONTAINER"
    else
        echo -e "   ERROR Target: $TARGET_CONTAINER (stopped)"
        return
    fi
    
    # Count users
    local source_users target_users
    source_users=$(mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "$SOURCE_DB" "SELECT COUNT(*) FROM users;" | tail -1)
    target_users=$(mysql_exec "$TARGET_CONTAINER" "$TARGET_USER" "$TARGET_PASSWORD" "$TARGET_DB" "SELECT COUNT(*) FROM users;" | tail -1)
    
    echo ""
    echo "Users:"
    echo "   Source: $source_users"
    echo "   Target: $target_users"
    
    if [ "$source_users" = "$target_users" ]; then
        echo -e "   ${GREEN}OK Synchronized${NC}"
    else
        echo -e "   ${YELLOW}WARNING Difference detected${NC}"
    fi
    
    # Pending changes
    local pending_changes
    pending_changes=$(mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "$SOURCE_DB" "SELECT COUNT(*) FROM $CHANGE_LOG_TABLE WHERE synced = FALSE;" 2>/dev/null | tail -1 || echo "0")
    
    echo ""
    echo "Pending changes: $pending_changes"
    
    # Recent changes
    echo ""
    echo "Recent changes:"
    mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "$SOURCE_DB" "SELECT CONCAT('  ', table_name, ' (', operation, ') - ', timestamp) FROM $CHANGE_LOG_TABLE ORDER BY timestamp DESC LIMIT 5;" 2>/dev/null || echo "   No changes recorded"
}

# Cleanup function
cleanup() {
    echo -e "${BLUE}Cleaning replication system${NC}"
    
    # Remove all triggers
    local triggers
    triggers=$(mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "$SOURCE_DB" "SELECT TRIGGER_NAME FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = '$SOURCE_DB';" | tail -n +2)
    
    if [ -n "$triggers" ]; then
        echo "$triggers" | while read trigger; do
            if [ -n "$trigger" ]; then
                mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "$SOURCE_DB" "DROP TRIGGER IF EXISTS \`$trigger\`;"
            fi
        done
    fi
    
    # Remove log table
    mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "$SOURCE_DB" "DROP TABLE IF EXISTS $CHANGE_LOG_TABLE;"
    
    echo -e "${GREEN}Cleanup completed${NC}"
}

# Main program
case "${1:-}" in
    "setup")
        echo -e "${BLUE}Complete Janus replication configuration${NC}"
        check_containers
        install_triggers
        echo ""
        echo -e "${GREEN}Configuration completed!${NC}"
        echo "To start automatic synchronization:"
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
        echo -e "${RED}ERROR: Unknown command: $1${NC}"
        echo ""
        show_help
        exit 1
        ;;
esac
