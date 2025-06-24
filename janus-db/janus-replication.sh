#!/usr/bin/env bash

# Janus Database Replication Manager
# Script unique pour gérer la réplication de base de données Janus
# Usage: ./janus-replication.sh <command> [options]

set -e

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

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

msg() {
    local level="$1"
    local color msg
    shift

    case "$level" in
        INFO) color=$BLUE ;;
        WARN) color=$YELLOW ;;
        SUCCESS) color=$GREEN ;;
        ERROR) color=$RED ;;
        *) color=$NC ;;
    esac

    printf "%b[%s]%b %s\n" "$color" "$level" "$NC" "$*"
}

show_help() {
    msg INFO "Janus Database Replication Manager"
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
    echo "  $0 setup"
    echo "  $0 auto-sync"
    echo "  $0 backup my_backup"
    echo "  $0 status"
}

mysql_exec() {
    local container=$1 user=$2 password=$3 database=$4 query=$5
    docker exec "$container" mysql -u "$user" -p"$password" "$database" -e "$query" 2>/dev/null
}

check_containers() {
    if ! docker ps | grep -q "$SOURCE_CONTAINER"; then
        msg ERROR "Source container '$SOURCE_CONTAINER' not found"
        exit 1
    fi

    if ! docker ps -a --format "table {{.Names}}" | grep -q "^$TARGET_CONTAINER$"; then
        msg WARN "Creating target container '$TARGET_CONTAINER'..."
        docker run -d \
            --name "$TARGET_CONTAINER" \
            --network janus-infra_janus-prod-net \
            -e MYSQL_ROOT_PASSWORD="$TARGET_PASSWORD" \
            -e MYSQL_DATABASE="$TARGET_DB" \
            -p 3307:3306 \
            mysql:latest

        msg INFO "Waiting for MySQL startup..."
        sleep 30

        for i in {1..30}; do
            if docker exec "$TARGET_CONTAINER" mysql -u "$TARGET_USER" -p"$TARGET_PASSWORD" -e "SELECT 1;" > /dev/null 2>&1; then
                break
            fi
            msg INFO "Waiting for MySQL... ($i/30)"
            sleep 2
        done

        msg INFO "Initial synchronization of existing data..."
        TEMP_INIT_FILE="/tmp/janus_initial_sync_$(date +%s).sql"
        docker exec "$SOURCE_CONTAINER" mysqldump -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" \
            --single-transaction --no-create-db \
            "$SOURCE_DB" > "$TEMP_INIT_FILE" 2>/dev/null

        docker exec -i "$TARGET_CONTAINER" mysql -u "$TARGET_USER" -p"$TARGET_PASSWORD" "$TARGET_DB" < "$TEMP_INIT_FILE" 2>/dev/null
        rm -f "$TEMP_INIT_FILE"
        msg SUCCESS "Initial synchronization completed"
    else
        docker start "$TARGET_CONTAINER" 2>/dev/null || true
        sleep 5
    fi
}

install_triggers() {
    msg INFO "Installing triggers on all tables"

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

    TABLES=$(docker exec "$SOURCE_CONTAINER" mysql -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" "$SOURCE_DB" -e "SHOW TABLES;" 2>/dev/null | grep -v "Tables_in_$SOURCE_DB" | grep -v "$CHANGE_LOG_TABLE" || true)

    msg INFO "Detected tables:"
    echo "$TABLES" | while read table; do
        printf "   - %s\n" "$table"
    done

    echo "$TABLES" | while read table; do
        if [ -n "$table" ]; then
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
            DELIMITER ;" 2>/dev/null || msg WARN "INSERT trigger for $table ignored"

            docker exec "$SOURCE_CONTAINER" mysql -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" "$SOURCE_DB" -e "
            DELIMITER $$
            CREATE TRIGGER ${table}_update_trigger
                AFTER UPDATE ON \`$table\`
                FOR EACH ROW
            BEGIN
                INSERT INTO $CHANGE_LOG_TABLE (table_name, operation, record_id)
                VALUES ('$table', 'UPDATE', COALESCE(NEW.id, OLD.id, 0));
            END$$
            DELIMITER ;" 2>/dev/null || msg WARN "UPDATE trigger for $table ignored"

            docker exec "$SOURCE_CONTAINER" mysql -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" "$SOURCE_DB" -e "
            DELIMITER $$
            CREATE TRIGGER ${table}_delete_trigger
                AFTER DELETE ON \`$table\`
                FOR EACH ROW
            BEGIN
                INSERT INTO $CHANGE_LOG_TABLE (table_name, operation, record_id)
                VALUES ('$table', 'DELETE', COALESCE(OLD.id, 0));
            END$$
            DELIMITER ;" 2>/dev/null || msg WARN "DELETE trigger for $table ignored"
        fi
    done

    msg SUCCESS "Triggers installed successfully"
}

sync_data() {
    local mode=${1:-"manual"}

    if [ "$mode" = "auto" ]; then
        msg INFO "Automatic synchronization started"
        printf "Press Ctrl+C to stop\n"
        trap 'msg INFO "Stopping synchronization..."; exit 0' INT TERM
    fi

    while true; do
        [ "$mode" = "auto" ] && printf "Checking... %s\n" "$(date '+%H:%M:%S')"

        local changes
        changes=$(mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "$SOURCE_DB" "SELECT COUNT(*) FROM $CHANGE_LOG_TABLE WHERE synced = FALSE;" | tail -1)

        if [ "$changes" -gt 0 ]; then
            msg WARN "$changes changes detected, synchronizing..."
            TEMP_FILE="/tmp/janus_sync_$(date +%s).sql"

            docker exec "$SOURCE_CONTAINER" mysqldump -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" \
                --single-transaction --no-create-db \
                --ignore-table="$SOURCE_DB.$CHANGE_LOG_TABLE" \
                "$SOURCE_DB" > "$TEMP_FILE" 2>/dev/null

            docker exec -i "$TARGET_CONTAINER" mysql -u "$TARGET_USER" -p"$TARGET_PASSWORD" "$TARGET_DB" < "$TEMP_FILE" 2>/dev/null

            mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "$SOURCE_DB" "UPDATE $CHANGE_LOG_TABLE SET synced = TRUE WHERE synced = FALSE;"
            rm -f "$TEMP_FILE"

            msg SUCCESS "Synchronization completed"

            local source_count target_count
            source_count=$(mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "$SOURCE_DB" "SELECT COUNT(*) FROM users;" | tail -1)
            target_count=$(mysql_exec "$TARGET_CONTAINER" "$TARGET_USER" "$TARGET_PASSWORD" "$TARGET_DB" "SELECT COUNT(*) FROM users;" | tail -1)
            printf "Users - Source: %s, Target: %s\n" "$source_count" "$target_count"
        else
            [ "$mode" = "auto" ] && printf "No changes\n" || msg SUCCESS "No changes to synchronize"
        fi

        [ "$mode" != "auto" ] && break
        sleep "$SYNC_INTERVAL"
    done
}

backup_db() {
    local backup_name="${1:-janus_backup_$(date +%Y%m%d_%H%M%S)}"
    local backup_file="${backup_name}.sql"

    msg INFO "Database backup"
    printf "File: %s\n" "$backup_file"

    docker exec "$SOURCE_CONTAINER" mysqldump -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" \
        --single-transaction --routines --triggers \
        "$SOURCE_DB" > "$backup_file" 2>/dev/null

    gzip "$backup_file"
    local backup_size=$(du -h "${backup_file}.gz" | cut -f1)
    msg SUCCESS "Backup completed: ${backup_file}.gz ($backup_size)"
}

restore_db() {
    local backup_file="$1"
    local target_db="${2:-janus_db_restored}"

    if [ -z "$backup_file" ]; then
        msg ERROR "You must specify the backup file"
        return 1
    fi

    if [ ! -f "$backup_file" ]; then
        msg ERROR "File not found: $backup_file"
        return 1
    fi

    msg INFO "Database restoration"
    printf "File: %s\n" "$backup_file"
    printf "Target database: %s\n" "$target_db"

    mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "" "DROP DATABASE IF EXISTS $target_db; CREATE DATABASE $target_db;"

    if [[ "$backup_file" == *.gz ]]; then
        gunzip -c "$backup_file" | docker exec -i "$SOURCE_CONTAINER" mysql -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" "$target_db" 2>/dev/null
    else
        docker exec -i "$SOURCE_CONTAINER" mysql -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" "$target_db" < "$backup_file" 2>/dev/null
    fi

    msg SUCCESS "Restoration completed in '$target_db'"
}

show_status() {
    msg INFO "Janus Replication Status"
    echo ""

    printf "Containers:\n"
    docker ps | grep -q "$SOURCE_CONTAINER" && printf "   OK Source: %s\n" "$SOURCE_CONTAINER" || printf "   ERROR Source: %s (stopped)\n" "$SOURCE_CONTAINER"
    docker ps | grep -q "$TARGET_CONTAINER" && printf "   OK Target: %s\n" "$TARGET_CONTAINER" || {
        printf "   ERROR Target: %s (stopped)\n" "$TARGET_CONTAINER"
        return
    }

    local source_users target_users
    source_users=$(mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "$SOURCE_DB" "SELECT COUNT(*) FROM users;" | tail -1)
    target_users=$(mysql_exec "$TARGET_CONTAINER" "$TARGET_USER" "$TARGET_PASSWORD" "$TARGET_DB" "SELECT COUNT(*) FROM users;" | tail -1)

    echo ""
    printf "Users:\n"
    printf "   Source: %s\n" "$source_users"
    printf "   Target: %s\n" "$target_users"

    [ "$source_users" = "$target_users" ] && msg SUCCESS "OK Synchronized" || msg WARN "WARNING Difference detected"

    local pending_changes
    pending_changes=$(mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "$SOURCE_DB" "SELECT COUNT(*) FROM $CHANGE_LOG_TABLE WHERE synced = FALSE;" 2>/dev/null | tail -1 || echo "0")

    echo ""
    printf "Pending changes: %s\n" "$pending_changes"

    echo ""
    printf "Recent changes:\n"
    mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "$SOURCE_DB" "SELECT CONCAT('  ', table_name, ' (', operation, ') - ', timestamp) FROM $CHANGE_LOG_TABLE ORDER BY timestamp DESC LIMIT 5;" 2>/dev/null || printf "   No changes recorded\n"
}

cleanup() {
    msg INFO "Cleaning replication system"

    local triggers
    triggers=$(mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "$SOURCE_DB" "SELECT TRIGGER_NAME FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = '$SOURCE_DB';" | tail -n +2)

    if [ -n "$triggers" ]; then
        echo "$triggers" | while read trigger; do
            [ -n "$trigger" ] && mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "$SOURCE_DB" "DROP TRIGGER IF EXISTS \`$trigger\`;"
        done
    fi

    mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "$SOURCE_DB" "DROP TABLE IF EXISTS $CHANGE_LOG_TABLE;"
    msg SUCCESS "Cleanup completed"
}

case "${1:-}" in
    "setup")
        msg INFO "Complete Janus replication configuration"
        check_containers
        install_triggers
        echo ""
        msg SUCCESS "Configuration completed!"
        printf "To start automatic synchronization:\n   $0 auto-sync\n"
        ;;
    "sync") check_containers; sync_data "manual" ;;
    "auto-sync") check_containers; sync_data "auto" ;;
    "backup") backup_db "$2" ;;
    "restore") restore_db "$2" "$3" ;;
    "status") show_status ;;
    "cleanup") cleanup ;;
    "help"|"-h"|"--help"|"") show_help ;;
    *) msg ERROR "Unknown command: $1"; echo ""; show_help; exit 1 ;;
esac

