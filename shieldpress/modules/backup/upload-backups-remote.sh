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
for d in "$DOMAINS_ROOT"/*/; do
    [ -d "$d" ] || continue
    [ -f "$d/config/domain.env" ] || continue
    load_domain_info "$d"

    for type in db files full; do
        DIR="$d/backup/$type"
        [ -d "$DIR" ] || continue
        for file in "$DIR"/*; do
            [ -f "$file" ] || continue
            remote_upload_backup "$file" "$type"
            COUNT=$((COUNT + 1))
        done
    done
done

# PostgreSQL Manager backups are stored centrally rather than below a domain.
# Use the database name as the remote scope so multiple databases stay isolated.
PG_BACKUP_ROOT="/home/backup-all/laravel-postgresql"
for db_dir in "$PG_BACKUP_ROOT"/*/; do
    [ -d "$db_dir" ] || continue
    DOMAIN=$(basename "$db_dir")
    for file in "$db_dir"/*.sql.gz; do
        [ -f "$file" ] || continue
        remote_upload_backup "$file" "db"
        COUNT=$((COUNT + 1))
    done
done

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo ""
echo "[OK] Upload finished. Files processed: $COUNT | Total time: ${ELAPSED}s"
pause
