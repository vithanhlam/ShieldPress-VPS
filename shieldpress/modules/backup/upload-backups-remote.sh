#!/bin/bash

BASE_DIR="/opt/shieldpress"
DOMAINS_ROOT="/home/domains"
source "$BASE_DIR/modules/backup/_backup_helper.sh"

pause(){ echo ""; read -p "Press Enter..."; }

clear
echo "===================================================="
echo "            UPLOAD EXISTING BACKUPS TO REMOTE"
echo "===================================================="

load_remote_config
if [ "$REMOTE_ENABLED" != "1" ] || [ -z "$RCLONE_REMOTES" ]; then
    echo "Remote backup is not enabled. Configure it first."
    pause; exit 1
fi

command -v rclone >/dev/null 2>&1 || { echo "rclone is not installed"; pause; exit 1; }

COUNT=0
START_TIME=$(date +%s)

# Count first so the user can distinguish a slow upload from a hung process.
# Include domain DB/files/full archives, standalone MariaDB/PostgreSQL dumps,
# and PostgreSQL Manager dumps.
TOTAL_FILES=0
for d in "$DOMAINS_ROOT"/*/; do
    [ -d "$d" ] || continue
    [ -f "$d/config/domain.env" ] || continue
    for type in db files full; do
        DIR="$d/backup/$type"
        [ -d "$DIR" ] || continue
        for file in "$DIR"/*; do [ -f "$file" ] && TOTAL_FILES=$((TOTAL_FILES + 1)); done
    done
done
STANDALONE_DB_DIR="$BASE_DIR/backup/standalone-db"
if [ -d "$STANDALONE_DB_DIR" ]; then
    for file in "$STANDALONE_DB_DIR"/*; do [ -f "$file" ] && TOTAL_FILES=$((TOTAL_FILES + 1)); done
fi
PG_BACKUP_ROOT="/home/backup-all/laravel-postgresql"
for db_dir in "$PG_BACKUP_ROOT"/*/; do
    [ -d "$db_dir" ] || continue
    for file in "$db_dir"/*.sql.gz; do [ -f "$file" ] && TOTAL_FILES=$((TOTAL_FILES + 1)); done
done

echo "Files queued: $TOTAL_FILES (progress is printed every 10s while each file uploads)"
for d in "$DOMAINS_ROOT"/*/; do
    [ -d "$d" ] || continue
    [ -f "$d/config/domain.env" ] || continue
    load_domain_info "$d"

    for type in db files full; do
        DIR="$d/backup/$type"
        [ -d "$DIR" ] || continue
        for file in "$DIR"/*; do
            [ -f "$file" ] || continue
            COUNT=$((COUNT + 1))
            REMOTE_UPLOAD_INDEX="$COUNT"
            REMOTE_UPLOAD_TOTAL="$TOTAL_FILES"
            remote_upload_backup "$file" "$type"
        done
    done
done

# Standalone database dumps created when a MariaDB/PostgreSQL database is not
# linked to a domain. They use a stable remote scope instead of the last domain.
DOMAIN="standalone"
if [ -d "$STANDALONE_DB_DIR" ]; then
    for file in "$STANDALONE_DB_DIR"/*; do
        [ -f "$file" ] || continue
        COUNT=$((COUNT + 1))
        REMOTE_UPLOAD_INDEX="$COUNT"
        REMOTE_UPLOAD_TOTAL="$TOTAL_FILES"
        remote_upload_backup "$file" "db"
    done
fi

# PostgreSQL Manager backups are stored centrally rather than below a domain.
# Use the database name as the remote scope so multiple databases stay isolated.
PG_BACKUP_ROOT="/home/backup-all/laravel-postgresql"
for db_dir in "$PG_BACKUP_ROOT"/*/; do
    [ -d "$db_dir" ] || continue
    DOMAIN=$(basename "$db_dir")
    for file in "$db_dir"/*.sql.gz; do
        [ -f "$file" ] || continue
        COUNT=$((COUNT + 1))
        REMOTE_UPLOAD_INDEX="$COUNT"
        REMOTE_UPLOAD_TOTAL="$TOTAL_FILES"
        remote_upload_backup "$file" "db"
    done
done

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo ""
echo "[OK] Upload finished. Files processed: $COUNT | Total time: ${ELAPSED}s"
pause
