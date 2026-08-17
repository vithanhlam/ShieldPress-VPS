#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
LOG_FILE="$LOG_DIR/backup.log"
MIN_FREE_MB=500
source "$BASE_DIR/modules/backup/_backup_helper.sh"

mkdir -p "$LOG_DIR"
log(){  echo "$(date '+%F %T') | $1" >> "$LOG_FILE"; }
pause(){ echo ""; read -p "Press Enter..."; }

clear
echo "===================================================="
echo "            FULL BACKUP (DB + FILES)"
echo "===================================================="

declare -a FOLDERS=()
i=1
for d in "$DOMAINS_ROOT"/*/; do
    [ -d "$d" ] || continue
    [ -f "$d/config/domain.env" ] || continue
    DN=$(grep "^DOMAIN=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
    [ -z "$DN" ] && continue
    echo "$i) $DN"
    FOLDERS[$i]=$(basename "$d")
    ((i++))
done

echo "--------------------------------------------------"
read -p "Select domain number: " choice
FOLDER="${FOLDERS[$choice]}"
[ -z "$FOLDER" ] && { echo "Invalid selection!"; pause; exit 1; }

DOMAIN_PATH="$DOMAINS_ROOT/$FOLDER"
load_domain_info "$DOMAIN_PATH"

FREE_MB=$(df -m / | awk 'NR==2 {print $4}')
SOURCE_MB=$(du -sm "$DOMAIN_PATH/public_html" 2>/dev/null | awk '{print $1}')
SOURCE_MB=${SOURCE_MB:-0}
NEED_MB=$(( SOURCE_MB + 200 ))

if [ "$FREE_MB" -lt "$MIN_FREE_MB" ] || [ "$FREE_MB" -lt "$NEED_MB" ]; then
    echo "Not enough disk space! Free: ${FREE_MB}MB, Need: ~${NEED_MB}MB"
    log "FAILED FULL backup: $DOMAIN - Low disk"
    pause; exit 1
fi

mkdir -p "$DOMAIN_PATH/backup/full"

DATE=$(date +%F_%H-%M-%S)
TMP=$(mktemp -d /tmp/${FOLDER}_fullbak_XXXXXX)
FINAL="$DOMAIN_PATH/backup/full/full_${DATE}.tar.gz"

trap 'rm -rf "$TMP"' EXIT INT TERM

DB_SIZE_MB=$(get_db_size_mb)
TOTAL_MB=$((SOURCE_MB + DB_SIZE_MB))
EST_DB=$(estimate_seconds "$DB_SIZE_MB" "db_dump")
EST_FILES=$(estimate_seconds "$SOURCE_MB" "tar_gz")
EST_TOTAL=$((EST_DB + EST_FILES + 5))
EST_FMT=$(format_duration "$EST_TOTAL")

echo ""
echo "Domain  : $DOMAIN"
echo "App     : $APP_TYPE"
echo "DB      : ${DB_NAME:-none} ($DB_CONNECTION) [${DB_SIZE_MB}MB]"
echo "Source  : ${SOURCE_MB}MB"
echo "Total   : ~${TOTAL_MB}MB"
echo "Est.time: ~${EST_FMT}"
echo ""

log "START FULL backup: $DOMAIN | DB: ${DB_SIZE_MB}MB + Files: ${SOURCE_MB}MB"

FULL_START=$(date +%s)

# 1. DB dump với --single-transaction để không lock bảng
echo "[Step 1/3] Backing up database..."
if [ -n "$DB_NAME" ] && [ "$DB_CONNECTION" != "none" ]; then
    backup_db_to_file "$TMP/db.sql.gz"
    if [ $? -ne 0 ]; then
        echo "[FAIL] Database dump failed!"
        log "FAILED FULL backup (DB): $DOMAIN"
        shieldpress_notify_event "backup_fail" "Full backup failed" "$DOMAIN DB step failed ($DB_CONNECTION/$DB_NAME)"
        rm -rf "$TMP"; pause; exit 1
    fi
    echo "[OK] Database dumped"
else
    echo "No database configured" > "$TMP/db.skipped"
    echo "[INFO] Database skipped"
fi

# 2. Files
echo ""
echo "[Step 2/3] Archiving files..."
archive_source_to_file "$TMP/files.tar.gz"

if [ $? -ne 0 ]; then
    echo "[FAIL] File archive failed!"
    log "FAILED FULL backup (files): $DOMAIN"
    shieldpress_notify_event "backup_fail" "Full backup failed" "$DOMAIN files step failed"
    rm -rf "$TMP"; pause; exit 1
fi
echo "[OK] Files archived"

# 3. Final package
echo ""
echo "[Step 3/3] Creating final archive..."
tar -czf "$FINAL" -C "$TMP" .

if [ $? -ne 0 ]; then
    echo "[FAIL] Final archive failed!"
    log "FAILED FULL backup (final): $DOMAIN"
    shieldpress_notify_event "backup_fail" "Full backup failed" "$DOMAIN final archive step failed"
    rm -rf "$TMP"; pause; exit 1
fi

rm -rf "$TMP"
FULL_END=$(date +%s)
FULL_DURATION=$((FULL_END - FULL_START))
FULL_DURATION_FMT=$(format_duration "$FULL_DURATION")
SIZE=$(du -h "$FINAL" | awk '{print $1}')

# Auto-encrypt if enabled
FINAL=$(maybe_encrypt_backup "$FINAL")

echo ""
echo "===================================================="
echo "  FULL BACKUP COMPLETED"
echo "===================================================="
echo "  Domain   : $DOMAIN"
echo "  App Type : $APP_TYPE"
echo "  Database : ${DB_NAME:-none} ($DB_CONNECTION)"
echo "  File     : $FINAL"
echo "  Size     : $SIZE"
echo "  Duration : $FULL_DURATION_FMT"
echo "===================================================="

TOTAL_FULL=$(find "$DOMAIN_PATH/backup/full" -type f \( -name "*.gz" -o -name "*.enc" \) 2>/dev/null | wc -l)
TOTAL_FULL_SIZE=$(du -sh "$DOMAIN_PATH/backup/full" 2>/dev/null | awk '{print $1}')
echo ""
echo "  Total full backups: $TOTAL_FULL files ($TOTAL_FULL_SIZE)"
echo ""

log "SUCCESS FULL backup: $DOMAIN ($APP_TYPE) | Size: $SIZE | Duration: $FULL_DURATION_FMT"
shieldpress_notify_event "backup_success" "Full backup completed" "$DOMAIN ($APP_TYPE) | Size: $SIZE"
remote_upload_backup "$FINAL" "full"

pause
