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
        echo "Daily backup mode for FILES (DB is always full dump):"
        case "$APP_TYPE" in
            laravel)
                echo "  1) Full (entire project, skip vendor/node_modules)"
                echo "  2) Incremental (DB full + only files changed in 24h)"
                ;;
            nodejs)
                echo "  1) Full (entire project, skip node_modules)"
                echo "  2) Incremental (DB full + only files changed in 24h)"
                ;;
            *)
                echo "  1) Full (entire public_html)"
                echo "  2) Smart (DB full + only themes/plugins/uploads)"
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

AUTO_SCRIPT="$DOMAIN_PATH/config/auto-backup-full.sh"

# ==============================
# GENERATE CRON SCRIPT
# ==============================

# --- DB dump section (same for both modes - always full) ---
DB_SECTION=""
if [ -n "$DB_NAME" ] && [ "$DB_CONNECTION" != "none" ]; then
    case "$DB_CONNECTION" in
        mysql|mariadb)
            DB_SECTION='
if [ -n "$DB_NAME" ] && [ "$DB_CONNECTION" != "none" ]; then
    mysqldump --single-transaction --quick --routines --triggers \
        -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" | gzip > "$TMP/db.sql.gz"
    if [ $? -ne 0 ]; then
        echo "$(date '"'"'+%F %T'"'"') | FAILED: $DOMAIN full backup DB step" >> "$LOG_FILE"
        rm -rf "$TMP"; exit 1
    fi
else
    echo "No database configured" > "$TMP/db.skipped"
fi'
            ;;
        pgsql|postgres|postgresql)
            DB_SECTION='
if [ -n "$DB_NAME" ] && [ "$DB_CONNECTION" != "none" ]; then
    PGPASSWORD="$DB_PASS" pg_dump -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" \
        --no-owner --no-privileges | gzip > "$TMP/db.sql.gz"
    if [ $? -ne 0 ]; then
        echo "$(date '"'"'+%F %T'"'"') | FAILED: $DOMAIN full backup DB step" >> "$LOG_FILE"
        rm -rf "$TMP"; exit 1
    fi
else
    echo "No database configured" > "$TMP/db.skipped"
fi'
            ;;
    esac
fi

# Start writing the script
cat > "$AUTO_SCRIPT" << 'SCRIPT_HEAD'
#!/bin/bash
set -o pipefail
SCRIPT_HEAD

cat >> "$AUTO_SCRIPT" << SCRIPT_VARS
BASE_DIR="$BASE_DIR"
DOMAIN_PATH="$DOMAIN_PATH"
DOMAIN="$DOMAIN"
DB_NAME="$DB_NAME"
DB_USER="$DB_USER"
DB_PASS="$DB_PASS"
DB_CONNECTION="$DB_CONNECTION"
APP_TYPE="$APP_TYPE"
RETENTION=$RETENTION
LOG_FILE="$LOG_FILE"
BACKUP_MODE="$BACKUP_MODE"
SCRIPT_VARS

if [ "$BACKUP_MODE" = "incremental" ]; then

    # --- INCREMENTAL MODE: DB full + files smart ---
    cat >> "$AUTO_SCRIPT" << 'SCRIPT_BODY'

DATE=$(date +%F_%H-%M-%S)
BACKUP_DIR="$DOMAIN_PATH/backup/full"
TMP=$(mktemp -d /tmp/fullbak_incr_XXXXXX)
FINAL="$BACKUP_DIR/full_incr_$DATE.tar.gz"
mkdir -p "$BACKUP_DIR"

trap 'rm -rf "$TMP"' EXIT INT TERM

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

# Build extra find excludes
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

# Step 1: DB dump (always full)
if [ -n "$DB_NAME" ] && [ "$DB_CONNECTION" != "none" ]; then
    case "$DB_CONNECTION" in
        mysql|mariadb)
            mysqldump --single-transaction --quick --routines --triggers \
                -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" | gzip > "$TMP/db.sql.gz"
            ;;
        pgsql|postgres|postgresql)
            PGPASSWORD="$DB_PASS" pg_dump -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" \
                --no-owner --no-privileges | gzip > "$TMP/db.sql.gz"
            ;;
    esac
    if [ $? -ne 0 ]; then
        echo "$(date '+%F %T') | FAILED: $DOMAIN full-incr backup DB step" >> "$LOG_FILE"
        if [ -f "$BASE_DIR/modules/backup/_backup_helper.sh" ]; then
            source "$BASE_DIR/modules/backup/_backup_helper.sh"
            shieldpress_notify_event "backup_fail" "Auto full-incr backup failed" "$DOMAIN DB step"
        fi
        exit 1
    fi
else
    echo "No database configured" > "$TMP/db.skipped"
fi

# Step 2: Files (incremental per app type)
# Custom paths from backup.env override app-type defaults
if [ -n "$BK_CUSTOM_PATHS" ]; then
    TARGETS=""
    IFS=','
    for p in $BK_CUSTOM_PATHS; do
        p=$(echo "$p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$p" ] && continue
        [ -e "$DOMAIN_PATH/public_html/$p" ] && TARGETS="$TARGETS $p"
    done
    unset IFS
    if [ -n "$TARGETS" ]; then
        EXCL_OPTS=""
        IFS=','
        for item in $BK_CUSTOM_EXCLUDE; do
            item=$(echo "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -z "$item" ] && continue
            EXCL_OPTS="$EXCL_OPTS --exclude=./${item}"
        done
        unset IFS
        tar -czf "$TMP/files.tar.gz" $EXCL_OPTS -C "$DOMAIN_PATH/public_html" $TARGETS
    else
        echo "No valid BACKUP_PATHS" > "$TMP/files.skipped"
    fi
else

case "$APP_TYPE" in
    laravel)
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
        if [ "$FILE_COUNT" -gt 0 ]; then
            tar -czf "$TMP/files.tar.gz" -T "$TMP_LIST" \
                --transform="s|^${DOMAIN_PATH}/public_html/|./|" 2>/dev/null
        else
            echo "No files changed" > "$TMP/files.skipped"
        fi
        rm -f "$TMP_LIST"
        ;;

    nodejs)
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
        if [ "$FILE_COUNT" -gt 0 ]; then
            tar -czf "$TMP/files.tar.gz" -T "$TMP_LIST" \
                --transform="s|^${DOMAIN_PATH}/public_html/|./|" 2>/dev/null
        else
            echo "No files changed" > "$TMP/files.skipped"
        fi
        rm -f "$TMP_LIST"
        ;;

    *)
        WP_ROOT="$DOMAIN_PATH/public_html/wp-content"
        TARGETS=""
        [ -d "$WP_ROOT/themes" ]  && TARGETS="$TARGETS wp-content/themes"
        [ -d "$WP_ROOT/plugins" ] && TARGETS="$TARGETS wp-content/plugins"
        [ -d "$WP_ROOT/uploads" ] && TARGETS="$TARGETS wp-content/uploads"

        if [ -n "$TARGETS" ]; then
            tar -czf "$TMP/files.tar.gz" -C "$DOMAIN_PATH/public_html" $TARGETS
        else
            echo "No wp-content dirs" > "$TMP/files.skipped"
        fi
        ;;
esac

fi

# Step 3: Package
tar -czf "$FINAL" -C "$TMP" .
STATUS=$?

if [ $STATUS -eq 0 ]; then
    SIZE=$(du -h "$FINAL" | awk '{print $1}')
    echo "$(date '+%F %T') | SUCCESS: $DOMAIN full-incr backup $FINAL ($SIZE)" >> "$LOG_FILE"
    ls -1t "$BACKUP_DIR"/full_incr_*.tar.gz 2>/dev/null | tail -n +$((RETENTION+1)) | xargs -r rm -f
    if [ -f "$BASE_DIR/modules/backup/_backup_helper.sh" ]; then
        source "$BASE_DIR/modules/backup/_backup_helper.sh"
        shieldpress_notify_event "backup_success" "Auto full-incr backup" "$DOMAIN: $FINAL ($SIZE)"
        remote_upload_backup "$FINAL" "full"
    fi
else
    echo "$(date '+%F %T') | FAILED: $DOMAIN full-incr backup" >> "$LOG_FILE"
    if [ -f "$BASE_DIR/modules/backup/_backup_helper.sh" ]; then
        source "$BASE_DIR/modules/backup/_backup_helper.sh"
        shieldpress_notify_event "backup_fail" "Auto full-incr backup failed" "$DOMAIN"
    fi
    rm -f "$FINAL"
fi
SCRIPT_BODY

else

    # --- FULL MODE (existing) ---
    cat >> "$AUTO_SCRIPT" << 'SCRIPT_BODY'

DATE=$(date +%F_%H-%M-%S)
BACKUP_DIR="$DOMAIN_PATH/backup/full"
TMP="/tmp/$(basename "$DOMAIN_PATH")_fullbak_$DATE"
FINAL="$BACKUP_DIR/full_$DATE.tar.gz"
mkdir -p "$BACKUP_DIR" "$TMP"

trap 'rm -rf "$TMP"' EXIT INT TERM

if [ -n "$DB_NAME" ] && [ "$DB_CONNECTION" != "none" ]; then
    case "$DB_CONNECTION" in
        mysql|mariadb)
            mysqldump --single-transaction --quick --routines --triggers \
                -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" | gzip > "$TMP/db.sql.gz"
            ;;
        pgsql|postgres|postgresql)
            PGPASSWORD="$DB_PASS" pg_dump -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" \
                --no-owner --no-privileges | gzip > "$TMP/db.sql.gz"
            ;;
        *)
            echo "Unsupported DB engine: $DB_CONNECTION" > "$TMP/db.skipped"
            ;;
    esac
    if [ $? -ne 0 ]; then
        echo "$(date '+%F %T') | FAILED: $DOMAIN full backup DB step" >> "$LOG_FILE"
        if [ -f "$BASE_DIR/modules/backup/_backup_helper.sh" ]; then
            source "$BASE_DIR/modules/backup/_backup_helper.sh"
            shieldpress_notify_event "backup_fail" "Auto full backup failed" "$DOMAIN DB step failed"
        fi
        rm -rf "$TMP" "$FINAL"
        exit 1
    fi
else
    echo "No database configured" > "$TMP/db.skipped"
fi

case "$APP_TYPE" in
    laravel)
        tar -czf "$TMP/files.tar.gz" \
            --exclude='./vendor' --exclude='./node_modules' --exclude='./.git' --exclude='./backup' \
            --exclude='./bootstrap/cache' \
            --exclude='./storage/logs/*.log' \
            --exclude='./storage/framework/cache/data' \
            --exclude='./storage/framework/sessions' \
            --exclude='./storage/framework/views' \
            -C "$DOMAIN_PATH/public_html" .
        ;;
    nodejs)
        tar -czf "$TMP/files.tar.gz" \
            --exclude='./node_modules' --exclude='./.git' --exclude='./backup' \
            --exclude='./.next' --exclude='./.nuxt' --exclude='./dist' --exclude='./build' \
            --exclude='./.cache' --exclude='./.turbo' \
            -C "$DOMAIN_PATH/public_html" .
        ;;
    *)
        tar -czf "$TMP/files.tar.gz" -C "$DOMAIN_PATH" public_html
        ;;
esac
if [ $? -ne 0 ]; then
    echo "$(date '+%F %T') | FAILED: $DOMAIN full backup files step" >> "$LOG_FILE"
    if [ -f "$BASE_DIR/modules/backup/_backup_helper.sh" ]; then
        source "$BASE_DIR/modules/backup/_backup_helper.sh"
        shieldpress_notify_event "backup_fail" "Auto full backup failed" "$DOMAIN files step failed"
    fi
    rm -rf "$TMP" "$FINAL"
    exit 1
fi

tar -czf "$FINAL" -C "$TMP" .
STATUS=$?

if [ $STATUS -eq 0 ]; then
    echo "$(date '+%F %T') | SUCCESS: $DOMAIN full backup $FINAL" >> "$LOG_FILE"
    ls -1t "$BACKUP_DIR"/full_[0-9]*.tar.gz 2>/dev/null | tail -n +$((RETENTION+1)) | xargs -r rm -f
    if [ -f "$BASE_DIR/modules/backup/_backup_helper.sh" ]; then
        source "$BASE_DIR/modules/backup/_backup_helper.sh"
        shieldpress_notify_event "backup_success" "Auto full backup completed" "$DOMAIN: $FINAL"
        remote_upload_backup "$FINAL" "full"
    fi
else
    echo "$(date '+%F %T') | FAILED: $DOMAIN full backup final step" >> "$LOG_FILE"
    if [ -f "$BASE_DIR/modules/backup/_backup_helper.sh" ]; then
        source "$BASE_DIR/modules/backup/_backup_helper.sh"
        shieldpress_notify_event "backup_fail" "Auto full backup failed" "$DOMAIN final archive step failed"
    fi
    rm -f "$FINAL"
fi
SCRIPT_BODY

fi

chmod 700 "$AUTO_SCRIPT"

(crontab -l 2>/dev/null | grep -v "$AUTO_SCRIPT"; echo "$CRON_TIME $AUTO_SCRIPT") | crontab -

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
