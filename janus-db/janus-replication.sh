#!/bin/bash

# Janus Database Replication Manager
# Unified script to manage Janus database replication
# Usage: ./janus-replication.sh <command> [options]

set -e

# Default configuration
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

# Color output
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
    echo "  restore <file>     - Restore a backup file"
    echo "  status             - Show replication status"
    echo "  cleanup            - Remove triggers and replication log table"
    echo "  help               - Show this help"
    echo ""
    echo "Optional environment variables:"
    echo "  SOURCE_CONTAINER   - Source container (default: janus-mysql)"
    echo "  TARGET_CONTAINER   - Target container (default: janus-mysql-replica)"
    echo "  SYNC_INTERVAL      - Synchronization interval in seconds (default: 10)"
    echo ""
    echo "Examples:"
    echo "  $0 setup                    # Full setup"
    echo "  $0 auto-sync               # Start automatic sync"
    echo "  $0 backup my_backup        # Create a backup"
    echo "  $0 status                  # Check sync status"
}

# Execute MySQL command in container
mysql_exec() {
    local container=$1
    local user=$2
    local password=$3
    local database=$4
    local query=$5

    docker exec "$container" mysql -u "$user" -p"$password" "$database" -e "$query" 2>/dev/null
}

# Check Docker containers
check_containers() {
    if ! docker ps | grep -q "$SOURCE_CONTAINER"; then
        echo -e "${RED}Source container '$SOURCE_CONTAINER' not found${NC}"
        exit 1
    fi

    if ! docker ps -a --format "table {{.Names}}" | grep -q "^$TARGET_CONTAINER$"; then
        echo -e "${YELLOW}Creating target container '$TARGET_CONTAINER'...${NC}"
        docker run -d \
            --name "$TARGET_CONTAINER" \
            -e MYSQL_ROOT_PASSWORD="$TARGET_PASSWORD" \
            -e MYSQL_DATABASE="$TARGET_DB" \
            -p 3307:3306 \
            mysql:latest

        echo -e "${YELLOW}Waiting for MySQL to start...${NC}"
        sleep 30

        for i in {1..30}; do
            if docker exec "$TARGET_CONTAINER" mysql -u "$TARGET_USER" -p"$TARGET_PASSWORD" -e "SELECT 1;" > /dev/null 2>&1; then
                break
            fi
            echo "Waiting for MySQL... ($i/30)"
            sleep 2
        done
    else
        docker start "$TARGET_CONTAINER" 2>/dev/null || true
        sleep 5
    fi
}

# Install triggers on all tables
install_triggers() {
    echo -e "${BLUE}Installing triggers on all tables${NC}"

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

    echo "Detected tables:"
    echo "$TABLES" | while read table; do
        echo "   - $table"
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
            DELIMITER ;" 2>/dev/null || echo "INSERT trigger skipped for $table"

            docker exec "$SOURCE_CONTAINER" mysql -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" "$SOURCE_DB" -e "
            DELIMITER $$
            CREATE TRIGGER ${table}_update_trigger
                AFTER UPDATE ON \`$table\`
                FOR EACH ROW
            BEGIN
                INSERT INTO $CHANGE_LOG_TABLE (table_name, operation, record_id)
                VALUES ('$table', 'UPDATE', COALESCE(NEW.id, OLD.id, 0));
            END$$
            DELIMITER ;" 2>/dev/null || echo "UPDATE trigger skipped for $table"

            docker exec "$SOURCE_CONTAINER" mysql -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" "$SOURCE_DB" -e "
            DELIMITER $$
            CREATE TRIGGER ${table}_delete_trigger
                AFTER DELETE ON \`$table\`
                FOR EACH ROW
            BEGIN
                INSERT INTO $CHANGE_LOG_TABLE (table_name, operation, record_id)
                VALUES ('$table', 'DELETE', COALESCE(OLD.id, 0));
            END$$
            DELIMITER ;" 2>/dev/null || echo "DELETE trigger skipped for $table"
        fi
    done

    echo -e "${GREEN}Triggers successfully installed${NC}"
}

# Sync function
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

        local changes
        changes=$(mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "$SOURCE_DB" "SELECT COUNT(*) FROM $CHANGE_LOG_TABLE WHERE synced = FALSE;" | tail -1)

        if [ "$changes" -gt 0 ]; then
            echo -e "${YELLOW}$changes changes detected, syncing...${NC}"

            TEMP_FILE="/tmp/janus_sync_$(date +%s).sql"
            docker exec "$SOURCE_CONTAINER" mysqldump -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" \
                --single-transaction --no-create-db \
                --ignore-table="$SOURCE_DB.$CHANGE_LOG_TABLE" \
                "$SOURCE_DB" > "$TEMP_FILE" 2>/dev/null

            docker exec -i "$TARGET_CONTAINER" mysql -u "$TARGET_USER" -p"$TARGET_PASSWORD" "$TARGET_DB" < "$TEMP_FILE" 2>/dev/null

            mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "$SOURCE_DB" "UPDATE $CHANGE_LOG_TABLE SET synced = TRUE WHERE synced = FALSE;"

            rm -f "$TEMP_FILE"
            echo -e "${GREEN}Synchronization complete${NC}"

            local source_count target_count
            source_count=$(mysql_exec "$SOURCE_CONTAINER" "$SOURCE_USER" "$SOURCE_PASSWORD" "$SOURCE_DB" "SELECT COUNT(*) FROM users;" | tail -1)
            target_count=$(mysql_exec "$TARGET_CONTAINER" "$TARGET_USER" "$TARGET_PASSWORD" "$TARGET_DB" "SELECT COUNT(*) FROM users;" | tail -1)
            echo "Users - Source: $source_count, Target: $target_count"
        else
            if [ "$mode" = "auto" ]; then
                echo "No changes"
            else
                echo -e "${GREEN}No changes to sync${NC}"
            fi
        fi

        if [ "$mode" != "auto" ]; then
            break
        fi

        sleep "$SYNC_INTERVAL"
    done
}
