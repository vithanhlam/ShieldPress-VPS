#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
LOG_FILE="$LOG_DIR/auto-backup.log"
source "$BASE_DIR/modules/backup/_backup_helper.sh"
mkdir -p "$LOG_DIR"

pause(){ echo ""; read -p "Press Enter..."; }

clear
echo "===================================================="
echo "              AUTO FULL BACKUP"
echo "===================================================="

declare -a FOLDERS=()
i=1
for d in "$DOMAINS_ROOT"/*/; do
    [ -d "$d" ] || continue
    [ -f "$d/config/domain.env" ] || continue
    DN=$(grep "^DOMAIN=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
    [ -z "$DN" ] && continue
    DB_SCRIPT="$ETC_DIR/jobs/$(basename "${d%/}")-backup-db.sh"
    FILE_SCRIPT="$ETC_DIR/jobs/$(basename "${d%/}")-backup-files.sh"
    FULL_SCRIPT="$ETC_DIR/jobs/$(basename "${d%/}")-backup-full.sh"
    DB_STATUS="No Backup"
    FILE_STATUS="No Backup"
    FULL_STATUS="No Backup"
    [ -f "$DB_SCRIPT" ] && crontab -l 2>/dev/null | grep -Fq "$DB_SCRIPT" && DB_STATUS="AUTO Backup conf"
    [ -f "$FILE_SCRIPT" ] && crontab -l 2>/dev/null | grep -Fq "$FILE_SCRIPT" && FILE_STATUS="AUTO Backup conf"
    [ -f "$FULL_SCRIPT" ] && crontab -l 2>/dev/null | grep -Fq "$FULL_SCRIPT" && FULL_STATUS="AUTO Backup conf"
    echo "$i) $DN | DB: $DB_STATUS | Files: $FILE_STATUS | Full: $FULL_STATUS"
    FOLDERS[$i]=$(basename "$d")
    ((i++))
done

echo "--------------------------------------------------"
read -p "Select domain number: " choice
FOLDER="${FOLDERS[$choice]}"
[ -z "$FOLDER" ] && { echo "Invalid selection!"; pause; exit 1; }

DOMAIN_PATH="$DOMAINS_ROOT/$FOLDER"
load_domain_info "$DOMAIN_PATH" || { echo "[FAIL] Untrusted domain configuration" >&2; exit 1; }
echo ""
echo "Domain     : $DOMAIN"
echo "App type   : $APP_TYPE"
echo "DB         : ${DB_NAME:-none} ($DB_CONNECTION)"
echo "Source root: $DOMAIN_PATH/public_html"
echo ""

while true; do
    read -p "Keep how many local full backups? (1-30): " RETENTION
    [[ "$RETENTION" =~ ^[0-9]+$ ]] && [ "$RETENTION" -ge 1 ] && [ "$RETENTION" -le 30 ] && break
    echo "Enter a number between 1 and 30"
done

while true; do
    read -p "Backup hour (0-23): " HOUR
    [[ "$HOUR" =~ ^[0-9]+$ ]] && [ "$HOUR" -ge 0 ] && [ "$HOUR" -le 23 ] && break
    echo "Enter a valid hour (0-23)"
done

echo ""
echo "Frequency:"
echo "1) Daily"
echo "2) Weekly"
echo "3) Monthly"
read -p "Select: " FREQ

BACKUP_MODE="full"

case $FREQ in
    1)
        CRON_TIME="15 $HOUR * * *"
        echo ""
        echo "Full website packages include complete source for safe restore."
        ;;
    2)
        while true; do
            read -p "Day of week (0=Sun, 6=Sat): " DOW
            [[ "$DOW" =~ ^[0-6]$ ]] && break
            echo "Enter 0-6"
        done
        CRON_TIME="15 $HOUR * * $DOW"
        ;;
    3)
        while true; do
            read -p "Day of month (1-28): " DOM
            [[ "$DOM" =~ ^[0-9]+$ ]] && [ "$DOM" -ge 1 ] && [ "$DOM" -le 28 ] && break
            echo "Enter 1-28"
        done
        CRON_TIME="15 $HOUR $DOM * *"
        ;;
    *) echo "Invalid option"; pause; exit 1 ;;
esac

sp_secure_domain_control "$DOMAIN_PATH" || exit 1
sp_write_backup_job "${DOMAIN_PATH##*/}" full "$BACKUP_MODE" "$RETENTION" || exit 1

chmod 700 "$AUTO_SCRIPT"

(crontab -l 2>/dev/null | grep -vF "$AUTO_SCRIPT" | grep -vF "$DOMAIN_PATH/config/auto-backup-full.sh"; echo "$CRON_TIME $AUTO_SCRIPT") | crontab -

echo ""
echo "===================================================="
echo "  AUTO FULL BACKUP SCHEDULED"
echo "===================================================="
echo "  Domain   : $DOMAIN"
echo "  App type : $APP_TYPE"
echo "  DB       : ${DB_NAME:-none} ($DB_CONNECTION) - always full dump"
echo "  Mode     : $BACKUP_MODE"
if [ "$BACKUP_MODE" = "incremental" ]; then
    case "$APP_TYPE" in
        laravel)  echo "  Strategy : DB full + only files changed in 24h" ;;
        nodejs)   echo "  Strategy : DB full + only files changed in 24h" ;;
        *)        echo "  Strategy : DB full + only themes/plugins/uploads" ;;
    esac
fi
echo "  Schedule : $CRON_TIME"
echo "  Keep     : $RETENTION backups"
echo "  Script   : $AUTO_SCRIPT"
echo "===================================================="

pause
