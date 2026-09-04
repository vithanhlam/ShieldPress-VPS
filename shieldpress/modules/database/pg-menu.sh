#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
MODULE_DIR="$BASE_DIR/modules/database"
source "$BASE_DIR/core/ui.sh"

PG_DB_DIR="$DATA_DIR_LARAVEL_DB"
PG_BACKUP_DIR="$BACKUP_GLOBAL_DIR/laravel-postgresql"
PG_BACKUP_SCRIPT="$BASE_DIR/bin/laravel-pg-backup"

if ! mkdir -p "$PG_DB_DIR" "$PG_BACKUP_DIR" "$BASE_DIR/bin"; then
    echo "[FAIL] Unable to create PostgreSQL data directories"
    exit 1
fi

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
RESET="\e[0m"

ok(){ echo -e "${GREEN}[OK]${RESET} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $1"; }
fail(){ echo -e "${RED}[FAIL]${RESET} $1"; }

postgresql_ready(){
    command -v psql >/dev/null 2>&1 &&
        systemctl is-active --quiet postgresql &&
        [ -f /var/lib/pgsql/data/PG_VERSION ]
}

configure_shieldpress_postgresql(){
    local PG_CONF="/var/lib/pgsql/data/postgresql.conf"
    local PG_HBA="/var/lib/pgsql/data/pg_hba.conf"
    local TOTAL_RAM PG_SHARED_BUFFERS PG_EFFECTIVE_CACHE PG_WORK_MEM PG_MAINT_WORK_MEM

    if [ ! -f /var/lib/pgsql/data/PG_VERSION ]; then
        postgresql-setup --initdb || return 1
    fi

    if [ -f "$PG_CONF" ]; then
        sed -i '/^# SHIELDPRESS PostgreSQL tuning/,$d' "$PG_CONF"
        sed -i "s/^[#[:space:]]*listen_addresses[[:space:]]*=.*/listen_addresses = '127.0.0.1'/" "$PG_CONF"
        grep -q "^listen_addresses = '127.0.0.1'" "$PG_CONF" || echo "listen_addresses = '127.0.0.1'" >> "$PG_CONF"
        sed -i '/^[#[:space:]]*password_encryption[[:space:]]*=/d' "$PG_CONF"
        echo "password_encryption = 'scram-sha-256'" >> "$PG_CONF"
    fi

    if [ -f "$PG_HBA" ] && ! grep -q "SHIELDPRESS PostgreSQL auth" "$PG_HBA"; then
        {
            echo "# SHIELDPRESS PostgreSQL auth"
            echo "host all all 127.0.0.1/32 scram-sha-256"
            echo "host all all ::1/128 scram-sha-256"
            cat "$PG_HBA"
        } > "${PG_HBA}.tmp"
        mv "${PG_HBA}.tmp" "$PG_HBA"
        chown postgres:postgres "$PG_HBA"
        restorecon "$PG_HBA" >/dev/null 2>&1 || true
    fi

    TOTAL_RAM=$(free -m | awk '/Mem:/ {print $2}')
    PG_SHARED_BUFFERS=$((TOTAL_RAM * 20 / 100))
    PG_EFFECTIVE_CACHE=$((TOTAL_RAM * 50 / 100))
    PG_WORK_MEM=$((TOTAL_RAM / 256))
    PG_MAINT_WORK_MEM=$((TOTAL_RAM / 16))

    [ "$PG_SHARED_BUFFERS" -lt 128 ] && PG_SHARED_BUFFERS=128
    [ "$PG_SHARED_BUFFERS" -gt 2048 ] && PG_SHARED_BUFFERS=2048
    [ "$PG_EFFECTIVE_CACHE" -lt 512 ] && PG_EFFECTIVE_CACHE=512
    [ "$PG_EFFECTIVE_CACHE" -gt 8192 ] && PG_EFFECTIVE_CACHE=8192
    [ "$PG_WORK_MEM" -lt 4 ] && PG_WORK_MEM=4
    [ "$PG_WORK_MEM" -gt 32 ] && PG_WORK_MEM=32
    [ "$PG_MAINT_WORK_MEM" -lt 64 ] && PG_MAINT_WORK_MEM=64
    [ "$PG_MAINT_WORK_MEM" -gt 512 ] && PG_MAINT_WORK_MEM=512

    if [ -f "$PG_CONF" ]; then
        cat >> "$PG_CONF" <<EOF

# SHIELDPRESS PostgreSQL tuning
shared_buffers = ${PG_SHARED_BUFFERS}MB
effective_cache_size = ${PG_EFFECTIVE_CACHE}MB
work_mem = ${PG_WORK_MEM}MB
maintenance_work_mem = ${PG_MAINT_WORK_MEM}MB
max_connections = 100
checkpoint_completion_target = 0.9
wal_buffers = 16MB
random_page_cost = 1.1
EOF
    fi
}

install_postgresql_stack(){
    echo "Installing PostgreSQL..."
    dnf install -y postgresql-server postgresql-contrib || return 1
    configure_shieldpress_postgresql || return 1
    systemctl enable postgresql >/dev/null 2>&1
    systemctl restart postgresql || return 1
    ok "PostgreSQL installed and configured with scram-sha-256"
}

select_pg_database(){
    DB_CHOICES=()
    local i=1

    echo ""
    echo "PostgreSQL Databases:"
    echo "--------------------------------"
    for meta in "$PG_DB_DIR"/*.env; do
        [ -f "$meta" ] || continue
        DB_NAME=$(grep "^DB_DATABASE=" "$meta" | cut -d= -f2)
        echo "$i) $DB_NAME"
        DB_CHOICES[$i]="$meta"
        ((i++))
    done

    [ $i -eq 1 ] && { warn "No tracked PostgreSQL DB found"; return 1; }

    read -p "Select: " choice
    DB_META="${DB_CHOICES[$choice]}"
    [ -n "$DB_META" ] || { fail "Invalid selection"; return 1; }

    DB_NAME=$(grep "^DB_DATABASE=" "$DB_META" | cut -d= -f2)
    DB_USER=$(grep "^DB_USERNAME=" "$DB_META" | cut -d= -f2)
    DB_PASS=$(grep "^DB_PASSWORD=" "$DB_META" | cut -d= -f2)
    return 0
}

ensure_pg_backup_script(){
    local RETENTION="${1:-7}"
    cat > "$PG_BACKUP_SCRIPT" <<BKEOF
#!/bin/bash
set -euo pipefail

DB_NAME="\$1"
KEEP=${RETENTION}
BASE_DIR="/opt/shieldpress"
source "\$BASE_DIR/core/paths.sh"
DB_META="\$DATA_DIR_LARAVEL_DB/\${DB_NAME}.env"
BACKUP_DIR="\$BACKUP_GLOBAL_DIR/laravel-postgresql/\${DB_NAME}"

[ -n "\$DB_NAME" ] || { echo "Usage: laravel-pg-backup <db_name>"; exit 1; }
[ -f "\$DB_META" ] || { echo "Database metadata not found: \$DB_META"; exit 1; }

mkdir -p "\$BACKUP_DIR"
BACKUP_FILE="\$BACKUP_DIR/\${DB_NAME}_\$(date '+%Y%m%d_%H%M%S').sql.gz"

cd /tmp
runuser -u postgres -- pg_dump --no-owner --no-privileges "\$DB_NAME" | gzip > "\$BACKUP_FILE"
[ -s "\$BACKUP_FILE" ] || { echo "Backup file is empty: \$BACKUP_FILE" >&2; exit 1; }
chmod 600 "\$BACKUP_FILE"

cd "\$BACKUP_DIR" && ls -1t \${DB_NAME}_*.sql.gz 2>/dev/null | tail -n +\$((\$KEEP + 1)) | xargs -r rm -f
echo "\$BACKUP_FILE"
BKEOF
    chmod +x "$PG_BACKUP_SCRIPT"
}

# =============================================
# CREATE
# =============================================
pg_create_db(){
    local role_exists db_exists created_role=0 created_db=0 pg_error

    if ! postgresql_ready; then
        warn "PostgreSQL is not installed or not running."
        read -p "Install PostgreSQL now? [y/N]: " CONFIRM
        [[ "$CONFIRM" =~ ^[Yy]$ ]] || return 1
        install_postgresql_stack || return 1
    fi

    read -p "Database name: " DB_NAME
    DB_NAME=$(echo "$DB_NAME" | tr -cd 'A-Za-z0-9_')
    [ -n "$DB_NAME" ] || { fail "Database name required"; return 1; }
    if [[ "$DB_NAME" =~ ^[0-9] ]]; then
        DB_NAME="db_${DB_NAME}"
    fi

    DB_USER="${DB_NAME}_user"
    DB_USER=$(echo "$DB_USER" | cut -c1-60)
    DB_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
    DB_META="$PG_DB_DIR/${DB_NAME}.env"

    [ "${#DB_PASS}" -eq 24 ] || { fail "Unable to generate database password"; return 1; }

    if [ -f "$DB_META" ]; then
        fail "Database is already tracked: $DB_NAME"
        return 1
    fi

    systemctl start postgresql >/dev/null 2>&1 || return 1
    cd /tmp
    runuser -u postgres -- psql -c "SET password_encryption = 'scram-sha-256';" >/dev/null 2>&1 || true

    role_exists=$(runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" 2>&1) || {
        fail "Unable to check PostgreSQL role: $role_exists"
        return 1
    }
    db_exists=$(runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" 2>&1) || {
        fail "Unable to check PostgreSQL database: $db_exists"
        return 1
    }

    [ "$db_exists" = "1" ] && { fail "Database already exists: $DB_NAME"; return 1; }

    if [ "$role_exists" != "1" ]; then
        if ! pg_error=$(runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "CREATE USER \"${DB_USER}\" WITH PASSWORD '${DB_PASS}';" 2>&1); then
            fail "PostgreSQL role creation failed: $pg_error"
            return 1
        fi
        created_role=1
    fi

    if ! pg_error=$(runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "SET password_encryption = 'scram-sha-256'; ALTER USER \"${DB_USER}\" WITH PASSWORD '${DB_PASS}';" 2>&1); then
        [ "$created_role" = "1" ] && runuser -u postgres -- dropuser --if-exists "$DB_USER" >/dev/null 2>&1
        fail "Setting PostgreSQL role password failed: $pg_error"
        return 1
    fi

    if ! pg_error=$(runuser -u postgres -- createdb -O "$DB_USER" "$DB_NAME" 2>&1); then
        [ "$created_role" = "1" ] && runuser -u postgres -- dropuser --if-exists "$DB_USER" >/dev/null 2>&1
        fail "PostgreSQL database creation failed: $pg_error"
        return 1
    fi
    created_db=1

    if ! cat > "$DB_META" <<EOF
DB_CONNECTION=pgsql
DB_HOST=127.0.0.1
DB_PORT=5432
DB_DATABASE=$DB_NAME
DB_USERNAME=$DB_USER
DB_PASSWORD=$DB_PASS
CREATED='$(date '+%Y-%m-%d %H:%M:%S')'
EOF
    then
        [ "$created_db" = "1" ] && runuser -u postgres -- dropdb --if-exists "$DB_NAME" >/dev/null 2>&1
        [ "$created_role" = "1" ] && runuser -u postgres -- dropuser --if-exists "$DB_USER" >/dev/null 2>&1
        fail "Unable to save PostgreSQL metadata"
        return 1
    fi

    if ! chmod 600 "$DB_META"; then
        rm -f "$DB_META"
        runuser -u postgres -- dropdb --if-exists "$DB_NAME" >/dev/null 2>&1
        [ "$created_role" = "1" ] && runuser -u postgres -- dropuser --if-exists "$DB_USER" >/dev/null 2>&1
        fail "Unable to secure PostgreSQL metadata"
        return 1
    fi

    ok "PostgreSQL DB created"
    echo "DB_DATABASE=$DB_NAME"
    echo "DB_USERNAME=$DB_USER"
    echo "DB_PASSWORD=$DB_PASS"
}

# =============================================
# LIST
# =============================================
pg_list_db(){
    echo ""
    echo "PostgreSQL Databases:"
    echo "--------------------------------"
    local found=0
    for meta in "$PG_DB_DIR"/*.env; do
        [ -f "$meta" ] || continue
        found=1
        DB_NAME=$(grep "^DB_DATABASE=" "$meta" | cut -d= -f2)
        DB_USER=$(grep "^DB_USERNAME=" "$meta" | cut -d= -f2)
        CREATED=$(grep "^CREATED=" "$meta" | cut -d= -f2-)
        DB_SIZE=$(cd /tmp && runuser -u postgres -- psql -tAc "SELECT pg_size_pretty(pg_database_size('${DB_NAME}'));" 2>/dev/null || echo "N/A")
        echo "$DB_NAME | $DB_SIZE | user $DB_USER | created $CREATED"
    done

    [ "$found" = "0" ] && warn "No tracked PostgreSQL DB found"
}

# =============================================
# VIEW
# =============================================
pg_view_db(){
    select_pg_database || return
    echo ""
    echo "Database info:"
    echo "--------------------------------"
    cat "$DB_META"
}

# =============================================
# DELETE
# =============================================
pg_delete_db(){
    select_pg_database || return
    echo ""
    echo -e "\e[31mWARNING: This will permanently drop database '$DB_NAME' and user '$DB_USER'!\e[0m"
    read -p "Continue? (y/n): " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { warn "Cancelled"; return; }

    cd /tmp
    if ! PG_ERROR=$(runuser -u postgres -- dropdb --if-exists "$DB_NAME" 2>&1); then
        fail "Database deletion failed: $PG_ERROR"
        return 1
    fi
    if ! PG_ERROR=$(runuser -u postgres -- dropuser --if-exists "$DB_USER" 2>&1); then
        fail "Database was deleted, but role deletion failed: $PG_ERROR"
        return 1
    fi
    rm -f "$DB_META" || { fail "Database deleted, but metadata removal failed"; return 1; }
    ok "Database deleted: $DB_NAME"
}

# =============================================
# CHANGE PASSWORD
# =============================================
pg_change_pass(){
    if ! postgresql_ready; then
        warn "PostgreSQL is not installed or not running."
        return 1
    fi

    select_pg_database || return

    NEW_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
    echo ""
    echo "Suggested New Password: $NEW_PASS"
    read -p "Use suggested password? (y/n): " USE_AUTO

    if [[ "$USE_AUTO" != "y" ]]; then
        read -s -p "Enter New Password: " NEW_PASS
        echo ""
        [ -n "$NEW_PASS" ] || { fail "Password required"; return 1; }
    fi

    cd /tmp
    runuser -u postgres -- psql -c "SET password_encryption = 'scram-sha-256'; ALTER USER \"${DB_USER}\" WITH PASSWORD '${NEW_PASS}';" >/dev/null || {
        fail "Failed to change PostgreSQL password"
        return 1
    }

    if grep -q "^DB_PASSWORD=" "$DB_META"; then
        sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=$NEW_PASS/" "$DB_META"
    else
        echo "DB_PASSWORD=$NEW_PASS" >> "$DB_META"
    fi

    chmod 600 "$DB_META"
    ok "PostgreSQL password changed"
    echo "DB_DATABASE=$DB_NAME"
    echo "DB_USERNAME=$DB_USER"
    echo "DB_PASSWORD=$NEW_PASS"
}

# =============================================
# IMPORT
# =============================================
pg_import_db(){
    if ! postgresql_ready; then
        warn "PostgreSQL is not installed or not running."
        return 1
    fi

    select_pg_database || return

    echo ""
    echo "Import SQL into PostgreSQL database: $DB_NAME"
    echo "--------------------------------"
    read -p "Enter full path to .sql or .sql.gz file: " FILE

    if [[ ! -f "$FILE" ]]; then
        fail "File not found: $FILE"
        return 1
    fi

    FILE_SIZE=$(du -h "$FILE" | awk '{print $1}')
    echo "File size: $FILE_SIZE"

    echo ""
    read -p "Backup database before import? [Y/n]: " BACKUP_CONFIRM
    BACKUP_CONFIRM="${BACKUP_CONFIRM:-y}"
    if [[ "$BACKUP_CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Creating backup..."
        ensure_pg_backup_script 7
        BACKUP_FILE=$("$PG_BACKUP_SCRIPT" "$DB_NAME") || {
            fail "Backup failed"
            return 1
        }
        ok "Backup saved: $BACKUP_FILE"
    fi

    echo ""
    read -p "Confirm import into '$DB_NAME'? This may overwrite data (y/n): " CONFIRM
    [[ "$CONFIRM" == "y" ]] || { warn "Cancelled"; return; }

    echo ""
    echo "Starting import..."

    local START_TIME=$(date +%s)

    if [[ "$FILE" == *.gz ]]; then
        if command -v pv >/dev/null 2>&1; then
            pv "$FILE" | gunzip | PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -q
        else
            gunzip < "$FILE" | PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -q
        fi
    else
        if command -v pv >/dev/null 2>&1; then
            pv "$FILE" | PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -q
        else
            PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -q < "$FILE"
        fi
    fi

    if [[ $? -ne 0 ]]; then
        fail "Import failed"
        return 1
    fi

    local END_TIME=$(date +%s)
    local DURATION=$((END_TIME - START_TIME))

    echo ""
    ok "Import Completed Successfully!"
    echo "  Database : $DB_NAME"
    echo "  File     : $FILE"
    echo "  Duration : ${DURATION}s"
}

# =============================================
# BACKUP
# =============================================
pg_backup_db(){
    if ! postgresql_ready; then
        warn "PostgreSQL is not installed or not running."
        return 1
    fi

    select_pg_database || return
    ensure_pg_backup_script 7
    BACKUP_FILE=$("$PG_BACKUP_SCRIPT" "$DB_NAME") || {
        fail "Backup failed"
        return 1
    }

    ok "Backup created: $BACKUP_FILE"
}

pg_auto_backup(){
    if ! postgresql_ready; then
        warn "PostgreSQL is not installed or not running."
        return 1
    fi

    select_pg_database || return

    # Hour (0-23), default 23
    read -p "Backup hour (0-23) [23]: " BACKUP_HOUR
    BACKUP_HOUR="${BACKUP_HOUR:-23}"
    if ! [[ "$BACKUP_HOUR" =~ ^[0-9]{1,2}$ ]] || [ "$BACKUP_HOUR" -gt 23 ]; then
        fail "Invalid hour. Enter 0-23"
        return 1
    fi

    # Frequency: daily / weekly / monthly, default daily
    echo "Backup frequency:"
    echo "  1) Daily (default)"
    echo "  2) Weekly"
    echo "  3) Monthly"
    read -p "Select [1]: " FREQ_CHOICE
    FREQ_CHOICE="${FREQ_CHOICE:-1}"

    local CRON_SCHEDULE FREQ_LABEL
    case "$FREQ_CHOICE" in
        1|"")
            CRON_SCHEDULE="0 $BACKUP_HOUR * * *"
            FREQ_LABEL="daily"
            ;;
        2)
            CRON_SCHEDULE="0 $BACKUP_HOUR * * 0"
            FREQ_LABEL="weekly (Sunday)"
            ;;
        3)
            CRON_SCHEDULE="0 $BACKUP_HOUR 1 * *"
            FREQ_LABEL="monthly (1st)"
            ;;
        *)
            fail "Invalid selection"
            return 1
            ;;
    esac

    # Retention count, default 7
    read -p "Keep how many backups? [7]: " RETENTION
    RETENTION="${RETENTION:-7}"
    if ! [[ "$RETENTION" =~ ^[0-9]+$ ]] || [ "$RETENTION" -lt 1 ]; then
        fail "Invalid number. Must be >= 1"
        return 1
    fi

    CRON_TAG="SHIELDPRESS_LARAVEL_PG_BACKUP_${DB_NAME}"
    ensure_pg_backup_script "$RETENTION"
    CRON_CMD="$CRON_SCHEDULE $PG_BACKUP_SCRIPT '$DB_NAME' >/dev/null 2>&1 # $CRON_TAG"

    (crontab -l 2>/dev/null | grep -v "$CRON_TAG"; echo "$CRON_CMD") | crontab -
    ok "Auto backup: $DB_NAME | ${BACKUP_HOUR}h | $FREQ_LABEL | keep $RETENTION backups"
}

pg_list_backups(){
    echo ""
    echo "PostgreSQL Backups:"
    echo "--------------------------------"
    find "$PG_BACKUP_DIR" -type f -name "*.sql.gz" 2>/dev/null | sort
}

# =============================================
# MENU
# =============================================
while true; do
    clear
    sp_header "PostgreSQL Manager" "Install, create, import, backup"

    if ! postgresql_ready; then
        echo ""
        warn "PostgreSQL is not installed or not running."
        echo ""
        sp_menu_grid \
            "1|Install PostgreSQL|green" \
            "0|Back|white"
        sp_prompt choice

        case $choice in
            1) install_postgresql_stack ;;
            0) break ;;
            *) sp_invalid ;;
        esac

        echo ""
        read -p "Press Enter..."
        continue
    fi

    sp_menu_grid \
        "1|Create Database + User|green" \
        "2|Database List|cyan" \
        "3|View Database Info|blue" \
        "4|Delete Database + User|red" \
        "5|Change DB Password|yellow" \
        "6|Import SQL|blue" \
        "7|Backup Database|green" \
        "8|Configure Auto Backup|yellow" \
        "9|List Backups|cyan" \
        "10|Streaming Replication|magenta" \
        "0|Back|white"
    sp_prompt choice

    case $choice in
        1) pg_create_db ;;
        2) pg_list_db ;;
        3) pg_view_db ;;
        4) pg_delete_db ;;
        5) pg_change_pass ;;
        6) pg_import_db ;;
        7) pg_backup_db ;;
        8) pg_auto_backup ;;
        9) pg_list_backups ;;
        10) bash "$MODULE_DIR/postgres-replication.sh" ;;
        0) break ;;
        *) sp_invalid ;;
    esac

    echo ""
    read -p "Press Enter..."
done
