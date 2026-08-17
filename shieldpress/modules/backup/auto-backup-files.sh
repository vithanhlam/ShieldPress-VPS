#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
LOG_FILE="$LOG_DIR/auto-backup.log"
source "$BASE_DIR/modules/backup/_backup_helper.sh"
mkdir -p "$LOG_DIR"

pause(){ echo ""; read -p "Press Enter..."; }

clear
echo "===================================================="
echo "            AUTO BACKUP SOURCE FILES"
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
SOURCE_MB=$(du -sm "$DOMAIN_PATH/public_html" 2>/dev/null | awk '{print $1}')
echo ""
echo "Domain     : $DOMAIN"
echo "App type   : $APP_TYPE"
echo "Source root: $DOMAIN_PATH/public_html"
echo "Source size: ${SOURCE_MB:-?}MB"
echo ""

while true; do
    read -p "Keep how many local source backups? (1-30): " RETENTION
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
        CRON_TIME="30 $HOUR * * *"
        echo ""
        echo "Daily backup mode:"
        case "$APP_TYPE" in
            laravel)
                echo "  1) Full backup (entire project, skip vendor/node_modules)"
                echo "  2) Incremental (only files changed in last 24h)"
                ;;
            nodejs)
                echo "  1) Full backup (entire project, skip node_modules)"
                echo "  2) Incremental (only files changed in last 24h)"
                ;;
            *)
                echo "  1) Full backup (entire public_html)"
                echo "  2) Smart (only themes + plugins + uploads, skip WP core)"
                ;;
        esac
        read -p "Select (1-2) [2]: " DAILY_MODE
        case $DAILY_MODE in
            1) BACKUP_MODE="full" ;;
            *) BACKUP_MODE="incremental" ;;
        esac
        ;;
    2)
        while true; do
            read -p "Day of week (0=Sun, 6=Sat): " DOW
            [[ "$DOW" =~ ^[0-6]$ ]] && break
            echo "Enter 0-6"
        done
        CRON_TIME="30 $HOUR * * $DOW"
        ;;
    3)
        while true; do
            read -p "Day of month (1-28): " DOM
            [[ "$DOM" =~ ^[0-9]+$ ]] && [ "$DOM" -ge 1 ] && [ "$DOM" -le 28 ] && break
            echo "Enter 1-28"
        done
        CRON_TIME="30 $HOUR $DOM * *"
        ;;
    *) echo "Invalid option"; pause; exit 1 ;;
esac

AUTO_SCRIPT="$DOMAIN_PATH/config/auto-backup-files.sh"

# ==============================
# GENERATE CRON SCRIPT
# ==============================

if [ "$BACKUP_MODE" = "incremental" ]; then

    # --- INCREMENTAL SCRIPT ---
    cat > "$AUTO_SCRIPT" << 'SCRIPT_HEAD'
#!/bin/bash
SCRIPT_HEAD

    cat >> "$AUTO_SCRIPT" << SCRIPT_VARS
BASE_DIR="$BASE_DIR"
DOMAIN_PATH="$DOMAIN_PATH"
DOMAIN="$DOMAIN"
APP_TYPE="$APP_TYPE"
RETENTION=$RETENTION
LOG_FILE="$LOG_FILE"
SCRIPT_VARS

    cat >> "$AUTO_SCRIPT" << 'SCRIPT_BODY'

DATE=$(date +%F_%H-%M-%S)
BACKUP_DIR="$DOMAIN_PATH/backup/files"
mkdir -p "$BACKUP_DIR"

# Load per-domain backup config
BKENV="$DOMAIN_PATH/config/backup.env"
BK_CUSTOM_EXCLUDE=""
BK_CUSTOM_PATHS=""
BK_INCR_EXCLUDE=""
BK_ENABLED=1
if [ -f "$BKENV" ]; then
    BK_CUSTOM_EXCLUDE=$(grep "^BACKUP_EXCLUDE=" "$BKENV" 2>/dev/null | cut -d'=' -f2-)
    BK_CUSTOM_PATHS=$(grep "^BACKUP_PATHS=" "$BKENV" 2>/dev/null | cut -d'=' -f2-)
    BK_INCR_EXCLUDE=$(grep "^INCR_EXCLUDE=" "$BKENV" 2>/dev/null | cut -d'=' -f2-)
    BK_ENABLED=$(grep "^BACKUP_ENABLED=" "$BKENV" 2>/dev/null | cut -d'=' -f2 | tr -d '[:space:]')
    BK_ENABLED="${BK_ENABLED:-1}"
fi

if [ "$BK_ENABLED" = "0" ]; then
    echo "$(date '+%F %T') | SKIP: $DOMAIN backup disabled" >> "$LOG_FILE"
    exit 0
fi

# Build extra find excludes from backup.env
EXTRA_FIND=""
for csv in "$BK_CUSTOM_EXCLUDE" "$BK_INCR_EXCLUDE"; do
    IFS=','
    for item in $csv; do
        item=$(echo "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$item" ] && continue
        EXTRA_FIND="$EXTRA_FIND -not -path */${item}/*"
    done
    unset IFS
done

# If BACKUP_PATHS is set, use custom targeted backup
if [ -n "$BK_CUSTOM_PATHS" ]; then
    FILE="$BACKUP_DIR/files_custom_$DATE.tar.gz"
    TARGETS=""
    IFS=','
    for p in $BK_CUSTOM_PATHS; do
        p=$(echo "$p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$p" ] && continue
        [ -e "$DOMAIN_PATH/public_html/$p" ] && TARGETS="$TARGETS $p"
    done
    unset IFS

    if [ -z "$TARGETS" ]; then
        echo "$(date '+%F %T') | SKIP: $DOMAIN no valid BACKUP_PATHS" >> "$LOG_FILE"
        exit 0
    fi

    # Build tar excludes
    EXCL_OPTS=""
    for csv in "$BK_CUSTOM_EXCLUDE"; do
        IFS=','
        for item in $csv; do
            item=$(echo "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -z "$item" ] && continue
            EXCL_OPTS="$EXCL_OPTS --exclude=./${item}"
        done
        unset IFS
    done

    tar -czf "$FILE" $EXCL_OPTS -C "$DOMAIN_PATH/public_html" $TARGETS
    STATUS=$?

else

case "$APP_TYPE" in
    laravel)
        # Laravel incremental: only files changed in last 24h
        FILE="$BACKUP_DIR/files_incr_$DATE.tar.gz"
        TMP_LIST=$(mktemp /tmp/sp_incr_XXXXXX)
        eval find "$DOMAIN_PATH/public_html" -mmin -1440 -type f \
            -not -path "*/vendor/*" \
            -not -path "*/node_modules/*" \
            -not -path "*/.git/*" \
            -not -path "*/bootstrap/cache/*" \
            -not -path "*/storage/framework/cache/*" \
            -not -path "*/storage/framework/sessions/*" \
            -not -path "*/storage/framework/views/*" \
            -not -path "*/storage/logs/*" \
            -not -path "*/backup/*" \
            $EXTRA_FIND \
            > "$TMP_LIST" 2>/dev/null

        FILE_COUNT=$(wc -l < "$TMP_LIST" | tr -d '[:space:]')

        if [ "$FILE_COUNT" -eq 0 ]; then
            echo "$(date '+%F %T') | SKIP: $DOMAIN no files changed in 24h" >> "$LOG_FILE"
            rm -f "$TMP_LIST"
            exit 0
        fi

        tar -czf "$FILE" -T "$TMP_LIST" \
            --transform="s|^${DOMAIN_PATH}/public_html/|./|" 2>/dev/null
        STATUS=$?
        rm -f "$TMP_LIST"
        ;;

    nodejs)
        # Node.js incremental: only files changed in last 24h
        FILE="$BACKUP_DIR/files_incr_$DATE.tar.gz"
        TMP_LIST=$(mktemp /tmp/sp_incr_XXXXXX)
        eval find "$DOMAIN_PATH/public_html" -mmin -1440 -type f \
            -not -path "*/node_modules/*" \
            -not -path "*/.git/*" \
            -not -path "*/.next/*" \
            -not -path "*/.nuxt/*" \
            -not -path "*/dist/*" \
            -not -path "*/build/*" \
            -not -path "*/.cache/*" \
            -not -path "*/.turbo/*" \
            -not -path "*/backup/*" \
            $EXTRA_FIND \
            > "$TMP_LIST" 2>/dev/null

        FILE_COUNT=$(wc -l < "$TMP_LIST" | tr -d '[:space:]')

        if [ "$FILE_COUNT" -eq 0 ]; then
            echo "$(date '+%F %T') | SKIP: $DOMAIN no files changed in 24h" >> "$LOG_FILE"
            rm -f "$TMP_LIST"
            exit 0
        fi

        tar -czf "$FILE" -T "$TMP_LIST" \
            --transform="s|^${DOMAIN_PATH}/public_html/|./|" 2>/dev/null
        STATUS=$?
        rm -f "$TMP_LIST"
        ;;

    *)
        # WordPress: only themes + plugins + uploads (skip WP core)
        FILE="$BACKUP_DIR/files_wp-content_$DATE.tar.gz"
        WP_ROOT="$DOMAIN_PATH/public_html/wp-content"
        TARGETS=""
        [ -d "$WP_ROOT/themes" ]  && TARGETS="$TARGETS wp-content/themes"
        [ -d "$WP_ROOT/plugins" ] && TARGETS="$TARGETS wp-content/plugins"
        [ -d "$WP_ROOT/uploads" ] && TARGETS="$TARGETS wp-content/uploads"

        if [ -z "$TARGETS" ]; then
            echo "$(date '+%F %T') | SKIP: $DOMAIN no wp-content dirs found" >> "$LOG_FILE"
            exit 0
        fi

        tar -czf "$FILE" -C "$DOMAIN_PATH/public_html" $TARGETS
        STATUS=$?
        ;;
esac

fi

if [ ${STATUS:-1} -eq 0 ] && [ -f "$FILE" ]; then
    SIZE=$(du -h "$FILE" | awk '{print $1}')
    echo "$(date '+%F %T') | SUCCESS: $DOMAIN incr backup $FILE ($SIZE)" >> "$LOG_FILE"
    # Prune old incremental backups
    ls -1t "$BACKUP_DIR"/files_incr_*.tar.gz "$BACKUP_DIR"/files_wp-content_*.tar.gz 2>/dev/null \
        | tail -n +$((RETENTION+1)) | xargs -r rm -f
    if [ -f "$BASE_DIR/modules/backup/_backup_helper.sh" ]; then
        source "$BASE_DIR/modules/backup/_backup_helper.sh"
        shieldpress_notify_event "backup_success" "Auto incremental backup" "$DOMAIN: $FILE ($SIZE)"
        remote_upload_backup "$FILE" "files"
    fi
else
    echo "$(date '+%F %T') | FAILED: $DOMAIN incr backup" >> "$LOG_FILE"
    if [ -f "$BASE_DIR/modules/backup/_backup_helper.sh" ]; then
        source "$BASE_DIR/modules/backup/_backup_helper.sh"
        shieldpress_notify_event "backup_fail" "Auto incremental backup failed" "$DOMAIN"
    fi
    rm -f "$FILE"
fi
SCRIPT_BODY

else

    # --- FULL BACKUP SCRIPT (existing) ---
    cat > "$AUTO_SCRIPT" << 'SCRIPT_HEAD'
#!/bin/bash
SCRIPT_HEAD

    cat >> "$AUTO_SCRIPT" << SCRIPT_VARS
BASE_DIR="$BASE_DIR"
DOMAIN_PATH="$DOMAIN_PATH"
DOMAIN="$DOMAIN"
APP_TYPE="$APP_TYPE"
RETENTION=$RETENTION
LOG_FILE="$LOG_FILE"
SCRIPT_VARS

    cat >> "$AUTO_SCRIPT" << 'SCRIPT_BODY'

DATE=$(date +%F_%H-%M-%S)
BACKUP_DIR="$DOMAIN_PATH/backup/files"
FILE="$BACKUP_DIR/files_$DATE.tar.gz"
mkdir -p "$BACKUP_DIR"

case "$APP_TYPE" in
    laravel)
        tar -czf "$FILE" \
            --exclude='./vendor' --exclude='./node_modules' --exclude='./.git' --exclude='./backup' \
            --exclude='./bootstrap/cache' \
            --exclude='./storage/logs/*.log' \
            --exclude='./storage/framework/cache/data' \
            --exclude='./storage/framework/sessions' \
            --exclude='./storage/framework/views' \
            -C "$DOMAIN_PATH/public_html" .
        ;;
    nodejs)
        tar -czf "$FILE" \
            --exclude='./node_modules' --exclude='./.git' --exclude='./backup' \
            --exclude='./.next' --exclude='./.nuxt' --exclude='./dist' --exclude='./build' \
            --exclude='./.cache' --exclude='./.turbo' \
            -C "$DOMAIN_PATH/public_html" .
        ;;
    *)
        tar -czf "$FILE" -C "$DOMAIN_PATH" public_html
        ;;
esac

if [ $? -eq 0 ]; then
    echo "$(date '+%F %T') | SUCCESS: $DOMAIN files backup $FILE" >> "$LOG_FILE"
    ls -1t "$BACKUP_DIR"/files_[0-9]*.tar.gz 2>/dev/null | tail -n +$((RETENTION+1)) | xargs -r rm -f
    if [ -f "$BASE_DIR/modules/backup/_backup_helper.sh" ]; then
        source "$BASE_DIR/modules/backup/_backup_helper.sh"
        shieldpress_notify_event "backup_success" "Auto source backup completed" "$DOMAIN: $FILE"
        remote_upload_backup "$FILE" "files"
    fi
else
    echo "$(date '+%F %T') | FAILED: $DOMAIN files backup" >> "$LOG_FILE"
    if [ -f "$BASE_DIR/modules/backup/_backup_helper.sh" ]; then
        source "$BASE_DIR/modules/backup/_backup_helper.sh"
        shieldpress_notify_event "backup_fail" "Auto source backup failed" "$DOMAIN"
    fi
    rm -f "$FILE"
fi
SCRIPT_BODY

fi

chmod 700 "$AUTO_SCRIPT"

(crontab -l 2>/dev/null | grep -v "$AUTO_SCRIPT"; echo "$CRON_TIME $AUTO_SCRIPT") | crontab -

echo ""
echo "===================================================="
echo "  AUTO FILES BACKUP SCHEDULED"
echo "===================================================="
echo "  Domain   : $DOMAIN"
echo "  App type : $APP_TYPE"
echo "  Mode     : $BACKUP_MODE"
if [ "$BACKUP_MODE" = "incremental" ]; then
    case "$APP_TYPE" in
        laravel)  echo "  Strategy : Only files changed in 24h (skip vendor/node_modules/cache)" ;;
        nodejs)   echo "  Strategy : Only files changed in 24h (skip node_modules/build)" ;;
        *)        echo "  Strategy : Only themes + plugins + uploads (skip WP core)" ;;
    esac
fi
echo "  Schedule : $CRON_TIME"
echo "  Keep     : $RETENTION backups"
echo "  Script   : $AUTO_SCRIPT"
echo "===================================================="

pause
