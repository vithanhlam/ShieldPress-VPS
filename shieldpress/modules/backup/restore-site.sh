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
echo "                 RESTORE WEBSITE"
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
SYSUSER="$SYSTEM_USER"

BACKUP_DIR="$DOMAIN_PATH/backup/full"

if [ ! -d "$BACKUP_DIR" ]; then
    echo "No full backups found in $BACKUP_DIR"
    pause; exit 1
fi

# List both .tar.gz and .enc files
HAS_FILES=0
for f in "$BACKUP_DIR"/*.tar.gz "$BACKUP_DIR"/*.enc; do
    [ -f "$f" ] && { HAS_FILES=1; break; }
done
if [ "$HAS_FILES" -eq 0 ]; then
    echo "No full backups found in $BACKUP_DIR"
    pause; exit 1
fi

echo ""
echo "Available Full Backups for $DOMAIN:"
echo "--------------------------------------------------"
declare -a FILES=()
j=1
for f in "$BACKUP_DIR"/*.tar.gz "$BACKUP_DIR"/*.enc; do
    [ -f "$f" ] || continue
    SIZE=$(du -h "$f" | awk '{print $1}')
    DATE_STR=$(stat -c '%y' "$f" | cut -d'.' -f1)
    LABEL=""
    [[ "$f" == *.enc ]] && LABEL=" [ENCRYPTED]"
    echo "$j) $(basename "$f")  [$SIZE]  $DATE_STR$LABEL"
    FILES[$j]=$(basename "$f")
    ((j++))
done

echo "--------------------------------------------------"
read -p "Select backup number: " file_choice
BFILE="${FILES[$file_choice]}"
[ -z "$BFILE" ] && { echo "Invalid selection!"; pause; exit 1; }
FULL_PATH="$BACKUP_DIR/$BFILE"

# Disk check
FREE_MB=$(df -m / | awk 'NR==2 {print $4}')
if [ "$FREE_MB" -lt "$MIN_FREE_MB" ]; then
    echo "Not enough disk space! (${FREE_MB}MB free)"
    pause; exit 1
fi

echo ""
echo "===================================================="
echo "  RESTORE SUMMARY"
echo "===================================================="
echo "  Domain  : $DOMAIN"
echo "  Backup  : $BFILE"
echo "  DB      : ${DB_NAME:-none} ($DB_CONNECTION)"
echo "===================================================="
echo ""
echo -e "\e[31mWARNING: This will OVERWRITE current files and database!\e[0m"
echo "A rollback backup will be created automatically."
echo ""
read -p "Continue? (y/n): " CONFIRM
[[ ! "$CONFIRM" =~ ^[Yy]$ ]] && { echo "Cancelled."; pause; exit 0; }

DATE=$(date +%F_%H-%M-%S)
TMP=$(mktemp -d /tmp/restore_${FOLDER}_XXXXXX)
ROLLBACK_DIR="$DOMAIN_PATH/backup/rollback_${DATE}"

mkdir -p "$ROLLBACK_DIR"

BACKUP_SIZE_MB=$(du -sm "$FULL_PATH" 2>/dev/null | awk '{print $1}')
BACKUP_SIZE_MB=${BACKUP_SIZE_MB:-0}
BACKUP_SIZE_BYTES=$(stat -c '%s' "$FULL_PATH" 2>/dev/null || echo 0)
EST_SEC=$(estimate_seconds "$((BACKUP_SIZE_MB * 3))" "extract")
EST_FMT=$(format_duration "$EST_SEC")

echo ""
echo "Backup size : ${BACKUP_SIZE_MB}MB"
echo "Est. time   : ~${EST_FMT}"
echo ""

log "START RESTORE: $DOMAIN from $BFILE | Size: ${BACKUP_SIZE_MB}MB"

RESTORE_START=$(date +%s)

# Decrypt if encrypted
if [[ "$FULL_PATH" == *.enc ]]; then
    echo "[Step 0] Decrypting backup..."
    DECRYPTED=$(decrypt_for_restore "$FULL_PATH")
    if [ $? -ne 0 ] || [ -z "$DECRYPTED" ]; then
        echo "[FAIL] Decryption failed! Cannot restore."
        pause; exit 1
    fi
    FULL_PATH="$DECRYPTED"
    BACKUP_SIZE_BYTES=$(stat -c '%s' "$FULL_PATH" 2>/dev/null || echo 0)
    echo "[OK] Decrypted successfully"
    echo ""
fi

# Auto rollback backup
echo "[Step 1/4] Creating rollback snapshot..."
tar -czf "$ROLLBACK_DIR/files_rollback.tar.gz" -C "$DOMAIN_PATH" public_html 2>/dev/null
if [ -n "$DB_NAME" ] && [ "$DB_CONNECTION" != "none" ]; then
    backup_db_to_file "$ROLLBACK_DIR/db_rollback.sql.gz" >/dev/null 2>&1
fi
echo "[OK] Rollback snapshot created at $ROLLBACK_DIR"

# Extract backup
echo ""
echo "[Step 2/4] Extracting backup..."
if command -v pv >/dev/null 2>&1 && [ "$BACKUP_SIZE_BYTES" -gt 0 ]; then
    pv -s "$BACKUP_SIZE_BYTES" -p -t -e -r "$FULL_PATH" | tar -xzf - -C "$TMP"
else
    tar -xzf "$FULL_PATH" -C "$TMP"
fi
if [ $? -ne 0 ]; then
    echo "[FAIL] Failed to extract backup!"
    log "FAILED RESTORE (extract): $DOMAIN"
    rm -rf "$TMP"; pause; exit 1
fi

# Restore files
echo ""
echo "[Step 3/4] Restoring files..."
if [ ! -f "$TMP/files.tar.gz" ]; then
    echo "[FAIL] files.tar.gz not found in backup! Aborting to protect existing site."
    log "FAILED RESTORE (no files.tar.gz): $DOMAIN"
    rm -rf "$TMP"; pause; exit 1
fi

# Detect archive type: does it contain "public_html/" (WP/PHP) or "./" (Laravel/Node.js)?
ARCHIVE_HAS_PUBLIC=$(tar -tzf "$TMP/files.tar.gz" 2>/dev/null | head -5 | grep -c "^public_html/")

rm -rf "$DOMAIN_PATH/public_html"
mkdir -p "$DOMAIN_PATH/public_html"

FILES_SIZE_BYTES=$(stat -c '%s' "$TMP/files.tar.gz" 2>/dev/null || echo 0)

if [ "$ARCHIVE_HAS_PUBLIC" -gt 0 ]; then
    # WordPress/PHP backup: archive contains public_html/ directory
    if command -v pv >/dev/null 2>&1 && [ "$FILES_SIZE_BYTES" -gt 0 ]; then
        pv -s "$FILES_SIZE_BYTES" -p -t -e -r "$TMP/files.tar.gz" | tar -xzf - -C "$DOMAIN_PATH"
    else
        tar -xzf "$TMP/files.tar.gz" -C "$DOMAIN_PATH"
    fi
else
    # Laravel/Node.js backup: archive contains ./ (app root files directly)
    if command -v pv >/dev/null 2>&1 && [ "$FILES_SIZE_BYTES" -gt 0 ]; then
        pv -s "$FILES_SIZE_BYTES" -p -t -e -r "$TMP/files.tar.gz" | tar -xzf - -C "$DOMAIN_PATH/public_html"
    else
        tar -xzf "$TMP/files.tar.gz" -C "$DOMAIN_PATH/public_html"
    fi
fi
if [ $? -ne 0 ]; then
    echo "[FAIL] File restore failed! Rolling back..."
    tar -xzf "$ROLLBACK_DIR/files_rollback.tar.gz" -C "$DOMAIN_PATH"
    log "FAILED RESTORE (files) + rollback: $DOMAIN"
    rm -rf "$TMP"; pause; exit 1
fi
echo "[OK] Files restored"

# Restore DB
echo ""
echo "[Step 4/4] Restoring database..."
if [ -f "$TMP/db.sql.gz" ]; then
    gzip -dc "$TMP/db.sql.gz" > "$TMP/db.restore.sql"
elif [ -f "$TMP/db.sql" ]; then
    cp "$TMP/db.sql" "$TMP/db.restore.sql"
fi

if [ -f "$TMP/db.restore.sql" ] && [ -n "$DB_NAME" ] && [ "$DB_CONNECTION" != "none" ]; then
    restore_db_from_sql "$TMP/db.restore.sql"
    if [ $? -ne 0 ]; then
        echo "[FAIL] Database restore failed! Rolling back DB..."
        if [ -f "$ROLLBACK_DIR/db_rollback.sql.gz" ]; then
            gzip -dc "$ROLLBACK_DIR/db_rollback.sql.gz" > "$TMP/db_rollback.restore.sql"
            restore_db_from_sql "$TMP/db_rollback.restore.sql"
        elif [ -f "$ROLLBACK_DIR/db_rollback.sql" ]; then
            restore_db_from_sql "$ROLLBACK_DIR/db_rollback.sql"
        fi
        log "FAILED RESTORE (DB) + rollback: $DOMAIN"
        rm -rf "$TMP"; pause; exit 1
    fi
    echo "[OK] Database restored"
else
    echo "[INFO] No database payload found; skipped"
fi

# Fix permissions
[ -n "$SYSUSER" ] && chown -R "$SYSUSER:$SYSUSER" "$DOMAIN_PATH/public_html"

# Post-restore: rebuild dependencies for Laravel/Node.js
APP_TYPE=$(grep "^APP_TYPE=" "$DOMAIN_PATH/config/domain.env" 2>/dev/null | cut -d'=' -f2 | tr -d '[:space:]')
APP_TYPE="${APP_TYPE:-wordpress}"

case "$APP_TYPE" in
    laravel)
        echo ""
        echo "[POST] Rebuilding Laravel dependencies..."
        if [ -f "$DOMAIN_PATH/public_html/composer.json" ]; then
            cd "$DOMAIN_PATH/public_html" && sudo -u "$SYSUSER" composer install --no-dev --optimize-autoloader 2>/dev/null && echo "[OK] composer install" || echo "[WARN] composer install failed (run manually)"
        fi
        if [ -f "$DOMAIN_PATH/public_html/package.json" ]; then
            cd "$DOMAIN_PATH/public_html" && sudo -u "$SYSUSER" npm install 2>/dev/null && echo "[OK] npm install" || echo "[WARN] npm install failed (run manually)"
        fi
        ;;
    nodejs)
        echo ""
        echo "[POST] Rebuilding Node.js dependencies..."
        if [ -f "$DOMAIN_PATH/public_html/package.json" ]; then
            cd "$DOMAIN_PATH/public_html" && sudo -u "$SYSUSER" npm install 2>/dev/null && echo "[OK] npm install" || echo "[WARN] npm install failed (run manually)"
        fi
        # Restart PM2 process if exists
        PM2_NAME=$(grep "^PM2_NAME=" "$DOMAIN_PATH/config/domain.env" 2>/dev/null | cut -d'=' -f2 | tr -d '[:space:]')
        if [ -n "$PM2_NAME" ] && command -v pm2 >/dev/null 2>&1; then
            sudo -u "$SYSUSER" pm2 restart "$PM2_NAME" 2>/dev/null && echo "[OK] PM2 restarted" || echo "[WARN] PM2 restart failed"
        fi
        ;;
esac

rm -rf "$TMP"

RESTORE_END=$(date +%s)
RESTORE_DURATION=$((RESTORE_END - RESTORE_START))
RESTORE_FMT=$(format_duration "$RESTORE_DURATION")

log "SUCCESS RESTORE: $DOMAIN ($APP_TYPE) from $BFILE | Duration: $RESTORE_FMT"

echo ""
echo "[OK] Restore completed successfully!"
echo "Duration : $RESTORE_FMT"
echo "Rollback : $ROLLBACK_DIR"

pause
