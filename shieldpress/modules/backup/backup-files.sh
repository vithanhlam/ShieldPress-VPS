#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
LOG_FILE="$LOG_DIR/backup.log"
MIN_FREE_MB=300
source "$BASE_DIR/modules/backup/_backup_helper.sh"

mkdir -p "$LOG_DIR"
log(){  echo "$(date '+%F %T') | $1" >> "$LOG_FILE"; }
pause(){ echo ""; read -p "Press Enter..."; }

clear
echo "===================================================="
echo "              BACKUP SOURCE FILES"
echo "===================================================="

# List domains
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

# Disk check
FREE_MB=$(df -m / | awk 'NR==2 {print $4}')
SOURCE_MB=$(du -sm "$DOMAIN_PATH/public_html" 2>/dev/null | awk '{print $1}')
SOURCE_MB=${SOURCE_MB:-0}

if [ "$FREE_MB" -lt "$MIN_FREE_MB" ]; then
    echo "Not enough disk space! (${FREE_MB}MB free)"
    log "FAILED backup FILES: $DOMAIN - Low disk"
    pause; exit 1
fi

if [ "$FREE_MB" -lt "$SOURCE_MB" ]; then
    echo "Disk free (${FREE_MB}MB) < source size (${SOURCE_MB}MB)"
    log "FAILED backup FILES: $DOMAIN - Not enough space"
    pause; exit 1
fi

mkdir -p "$DOMAIN_PATH/backup/files"

DATE=$(date +%F_%H-%M-%S)
FILE="$DOMAIN_PATH/backup/files/files_${DATE}.tar.gz"

EST_SEC=$(estimate_seconds "$SOURCE_MB" "tar_gz")
EST_FMT=$(format_duration "$EST_SEC")

# Show what will be excluded per app type
EXCLUDE_INFO=""
case "$APP_TYPE" in
    laravel)
        EXCLUDE_INFO="vendor/, node_modules/, .git/, bootstrap/cache/, storage/logs|cache|sessions|views/"
        ;;
    nodejs)
        EXCLUDE_INFO="node_modules/, .next/, .nuxt/, dist/, build/, .cache/, .turbo/, .git/"
        ;;
    *)
        EXCLUDE_INFO="none"
        ;;
esac

echo ""
echo "Domain      : $DOMAIN"
echo "App type    : $APP_TYPE"
echo "Source size : ${SOURCE_MB}MB"
echo "Excluding   : $EXCLUDE_INFO"
if [ -n "$BK_CUSTOM_EXCLUDE" ]; then
    echo "+ Custom    : $BK_CUSTOM_EXCLUDE"
fi
if [ -n "$BK_CUSTOM_PATHS" ]; then
    echo "Custom paths: $BK_CUSTOM_PATHS"
fi
echo "Est. time   : ~${EST_FMT}"
echo "Output      : $FILE"
echo "Config      : $DOMAIN_PATH/config/backup.env"
echo ""

log "START backup FILES: $DOMAIN ($APP_TYPE) | Size: ${SOURCE_MB}MB"

START_TIME=$(date +%s)
archive_source_to_file "$FILE"

if [ $? -ne 0 ]; then
    echo "[FAIL] Backup failed!"
    log "FAILED backup FILES: $DOMAIN"
    shieldpress_notify_event "backup_fail" "Source backup failed" "$DOMAIN ($APP_TYPE)"
    rm -f "$FILE"
    pause; exit 1
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
DURATION_FMT=$(format_duration "$DURATION")
SIZE=$(du -h "$FILE" | awk '{print $1}')

# Auto-encrypt if enabled
FILE=$(maybe_encrypt_backup "$FILE")

echo ""
echo "===================================================="
echo "  FILES BACKUP COMPLETED"
echo "===================================================="
echo "  Domain   : $DOMAIN"
echo "  App Type : $APP_TYPE"
echo "  File     : $FILE"
echo "  Size     : $SIZE"
echo "  Duration : $DURATION_FMT"
echo "===================================================="

TOTAL_FILES=$(find "$DOMAIN_PATH/backup/files" -type f \( -name "*.gz" -o -name "*.enc" \) 2>/dev/null | wc -l)
TOTAL_FILES_SIZE=$(du -sh "$DOMAIN_PATH/backup/files" 2>/dev/null | awk '{print $1}')
echo ""
echo "  Total file backups: $TOTAL_FILES files ($TOTAL_FILES_SIZE)"
echo ""

log "SUCCESS backup FILES: $DOMAIN ($APP_TYPE) | Size: $SIZE | Duration: $DURATION_FMT"
shieldpress_notify_event "backup_success" "Source backup completed" "$DOMAIN ($APP_TYPE) | Size: $SIZE"
remote_upload_backup "$FILE" "files"

pause
