#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
LOG_FILE="$LOG_DIR/backup.log"
MIN_FREE_MB=200
source "$BASE_DIR/modules/backup/_backup_helper.sh"

mkdir -p "$LOG_DIR"
log(){  echo "$(date '+%F %T') | $1" >> "$LOG_FILE"; }
pause(){ echo ""; read -p "Press Enter..."; }

clear
echo "===================================================="
echo "                BACKUP DATABASE"
echo "===================================================="
echo ""
echo "Select database by:"
echo "  1) Domain (read from domain config)"
echo "  2) Database name (list from MariaDB)"
echo "  3) Database name (list from PostgreSQL)"
echo "--------------------------------------------------"
read -p "Select mode: " SELECT_MODE

case "$SELECT_MODE" in

# ==============================
# MODE 1: By Domain
# ==============================
1)
    declare -a FOLDERS=()
    i=1
    for d in "$DOMAINS_ROOT"/*/; do
        [ -d "$d" ] || continue
        [ -f "$d/config/domain.env" ] || continue
        DN=$(grep "^DOMAIN=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
        DB=$(grep "^DB_NAME=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
        DBC=$(grep "^DB_CONNECTION=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
        [ -z "$DN" ] && continue
        [ -z "$DB" ] && continue
        echo "$i) $DN  →  $DB (${DBC:-mysql})"
        FOLDERS[$i]=$(basename "$d")
        ((i++))
    done

    [ $i -eq 1 ] && { echo "No domains with databases found."; pause; exit 1; }

    echo "--------------------------------------------------"
    read -p "Select domain number: " choice
    FOLDER="${FOLDERS[$choice]}"
    [ -z "$FOLDER" ] && { echo "Invalid selection!"; pause; exit 1; }

    DOMAIN_PATH="$DOMAINS_ROOT/$FOLDER"
    load_domain_info "$DOMAIN_PATH"

    if [ -z "$DB_NAME" ] || [ "$DB_CONNECTION" = "none" ]; then
        echo "This domain has no database configured."
        pause; exit 0
    fi

    BACKUP_DIR="$DOMAIN_PATH/backup/db"
    BACKUP_LABEL="$DOMAIN"
    ;;

# ==============================
# MODE 2: From MariaDB directly
# ==============================
2)
    if ! systemctl is-active --quiet mariadb 2>/dev/null; then
        echo "MariaDB is not running!"; pause; exit 1
    fi

    echo ""
    echo "MariaDB Databases:"
    echo "--------------------------------------------------"

    declare -A DB_MAP
    db_i=1
    while IFS= read -r db; do
        [ -z "$db" ] && continue
        SIZE=$(mysql -N -e "SELECT ROUND(SUM(data_length+index_length)/1024/1024,1) FROM information_schema.tables WHERE table_schema='$db';" 2>/dev/null)
        SIZE="${SIZE:-0}"
        printf "  %2d) %-30s %6s MB\n" "$db_i" "$db" "$SIZE"
        DB_MAP[$db_i]="$db"
        ((db_i++))
    done < <(mysql -N -e "SHOW DATABASES;" 2>/dev/null | grep -Ev "^(information_schema|performance_schema|mysql|sys)$")

    [ $db_i -eq 1 ] && { echo "No databases found."; pause; exit 1; }

    echo "--------------------------------------------------"
    read -p "Select database number: " choice
    DB_NAME="${DB_MAP[$choice]}"
    [ -z "$DB_NAME" ] && { echo "Invalid selection!"; pause; exit 1; }

    # Auto-detect user for this DB
    DB_USER=$(mysql -N -e "SELECT User FROM mysql.db WHERE Db='$DB_NAME' LIMIT 1;" 2>/dev/null)
    [ -z "$DB_USER" ] && DB_USER="root"
    DB_PASS=""
    DB_CONNECTION="mysql"

    # Try to find linked domain
    DOMAIN=""
    DOMAIN_PATH=""
    for d in "$DOMAINS_ROOT"/*/config/domain.env; do
        [ -f "$d" ] || continue
        ENV_DB=$(grep "^DB_NAME=" "$d" | cut -d'=' -f2 | tr -d '[:space:]')
        if [ "$ENV_DB" = "$DB_NAME" ]; then
            DOMAIN_PATH="$(dirname "$(dirname "$d")")"
            DOMAIN=$(grep "^DOMAIN=" "$d" | cut -d'=' -f2 | tr -d '[:space:]')
            DB_USER=$(grep "^DB_USER=" "$d" | cut -d'=' -f2 | tr -d '[:space:]')
            DB_PASS=$(grep "^DB_PASS=" "$d" | cut -d'=' -f2 | tr -d '[:space:]')
            break
        fi
    done

    if [ -n "$DOMAIN_PATH" ]; then
        BACKUP_DIR="$DOMAIN_PATH/backup/db"
        BACKUP_LABEL="$DOMAIN ($DB_NAME)"
    else
        # Standalone DB - save to central backup dir
        BACKUP_DIR="$BASE_DIR/backup/standalone-db"
        BACKUP_LABEL="$DB_NAME (standalone)"
        DOMAIN="standalone"
    fi
    ;;

# ==============================
# MODE 3: From PostgreSQL directly
# ==============================
3)
    if ! systemctl is-active --quiet postgresql 2>/dev/null; then
        echo "PostgreSQL is not running!"; pause; exit 1
    fi

    echo ""
    echo "PostgreSQL Databases:"
    echo "--------------------------------------------------"

    declare -A PG_MAP
    pg_i=1
    while IFS= read -r db; do
        [ -z "$db" ] && continue
        SIZE=$(runuser -u postgres -- psql -tAc "SELECT pg_size_pretty(pg_database_size('$db'));" 2>/dev/null)
        SIZE="${SIZE:-?}"
        printf "  %2d) %-30s %10s\n" "$pg_i" "$db" "$SIZE"
        PG_MAP[$pg_i]="$db"
        ((pg_i++))
    done < <(runuser -u postgres -- psql -tAc "SELECT datname FROM pg_database WHERE datistemplate=false AND datname NOT IN ('postgres');" 2>/dev/null)

    [ $pg_i -eq 1 ] && { echo "No databases found."; pause; exit 1; }

    echo "--------------------------------------------------"
    read -p "Select database number: " choice
    DB_NAME="${PG_MAP[$choice]}"
    [ -z "$DB_NAME" ] && { echo "Invalid selection!"; pause; exit 1; }

    DB_CONNECTION="pgsql"

    # Try to find linked domain
    DOMAIN=""
    DOMAIN_PATH=""
    for d in "$DOMAINS_ROOT"/*/config/domain.env; do
        [ -f "$d" ] || continue
        ENV_DB=$(grep "^DB_NAME=" "$d" | cut -d'=' -f2 | tr -d '[:space:]')
        if [ "$ENV_DB" = "$DB_NAME" ]; then
            DOMAIN_PATH="$(dirname "$(dirname "$d")")"
            DOMAIN=$(grep "^DOMAIN=" "$d" | cut -d'=' -f2 | tr -d '[:space:]')
            DB_USER=$(grep "^DB_USER=" "$d" | cut -d'=' -f2 | tr -d '[:space:]')
            DB_PASS=$(grep "^DB_PASS=" "$d" | cut -d'=' -f2 | tr -d '[:space:]')
            break
        fi
    done

    if [ -z "$DB_USER" ]; then
        # Get owner from PostgreSQL
        DB_USER=$(runuser -u postgres -- psql -tAc "SELECT pg_catalog.pg_get_userbyid(d.datdba) FROM pg_catalog.pg_database d WHERE d.datname='$DB_NAME';" 2>/dev/null)
        DB_USER="${DB_USER:-postgres}"
        DB_PASS=""
    fi

    if [ -n "$DOMAIN_PATH" ]; then
        BACKUP_DIR="$DOMAIN_PATH/backup/db"
        BACKUP_LABEL="$DOMAIN ($DB_NAME)"
    else
        BACKUP_DIR="$BASE_DIR/backup/standalone-db"
        BACKUP_LABEL="$DB_NAME (standalone)"
        DOMAIN="standalone"
    fi
    ;;

*)
    echo "Invalid mode!"; pause; exit 1
    ;;
esac

# ==============================
# BACKUP EXECUTION (shared)
# ==============================

# Disk check
FREE_MB=$(df -m / | awk 'NR==2 {print $4}')
if [ "$FREE_MB" -lt "$MIN_FREE_MB" ]; then
    echo "Not enough disk space! (${FREE_MB}MB free)"
    log "FAILED backup DB: $BACKUP_LABEL - Low disk"
    pause; exit 1
fi

mkdir -p "$BACKUP_DIR"

DATE=$(date +%F_%H-%M-%S)
GZ_FILE="$BACKUP_DIR/${DB_NAME}_${DATE}.sql.gz"

# Get DB size
DB_SIZE_MB=0
case "$DB_CONNECTION" in
    mysql|mariadb)
        DB_SIZE_MB=$(mysql -N -e "SELECT ROUND(SUM(data_length+index_length)/1024/1024,0) FROM information_schema.tables WHERE table_schema='$DB_NAME';" 2>/dev/null)
        ;;
    pgsql|postgres|postgresql)
        if [ -n "$DB_PASS" ]; then
            DB_SIZE_MB=$(PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT ROUND(pg_database_size('$DB_NAME')/1024/1024);" 2>/dev/null)
        else
            DB_SIZE_MB=$(runuser -u postgres -- psql -tAc "SELECT ROUND(pg_database_size('$DB_NAME')/1024/1024);" 2>/dev/null)
        fi
        ;;
esac
DB_SIZE_MB="${DB_SIZE_MB:-0}"

EST_SEC=$(estimate_seconds "$DB_SIZE_MB" "db_dump")
EST_FMT=$(format_duration "$EST_SEC")

echo ""
echo "Target   : $BACKUP_LABEL"
echo "Database : $DB_NAME"
echo "Engine   : $DB_CONNECTION"
echo "DB User  : $DB_USER"
echo "DB Size  : ${DB_SIZE_MB}MB"
echo "Est.time : ~${EST_FMT}"
echo "Output   : $GZ_FILE"
echo ""

log "START backup DB: $BACKUP_LABEL ($DB_NAME) | Size: ${DB_SIZE_MB}MB"

START_TIME=$(date +%s)

# Execute backup
case "$DB_CONNECTION" in
    mysql|mariadb)
        MYSQL_CNF=$(mktemp /tmp/shieldpress_mycnf_XXXXXX)
        chmod 600 "$MYSQL_CNF"
        if [ -n "$DB_PASS" ]; then
            cat > "$MYSQL_CNF" <<CNFEOF
[client]
user=$DB_USER
password=$DB_PASS
CNFEOF
        else
            cat > "$MYSQL_CNF" <<CNFEOF
[client]
user=$DB_USER
CNFEOF
        fi

        if command -v pv >/dev/null 2>&1; then
            ( set -o pipefail; mysqldump --defaults-extra-file="$MYSQL_CNF" --single-transaction --quick --routines --triggers \
                "$DB_NAME" | pv -p -t -e -r | gzip > "$GZ_FILE" )
        else
            ( set -o pipefail; mysqldump --defaults-extra-file="$MYSQL_CNF" --single-transaction --quick --routines --triggers \
                "$DB_NAME" | gzip > "$GZ_FILE" )
        fi
        STATUS=$?
        rm -f "$MYSQL_CNF"
        ;;

    pgsql|postgres|postgresql)
        if [ -n "$DB_PASS" ]; then
            if command -v pv >/dev/null 2>&1; then
                ( set -o pipefail; PGPASSWORD="$DB_PASS" pg_dump -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" \
                    --no-owner --no-privileges | pv -p -t -e -r | gzip > "$GZ_FILE" )
            else
                ( set -o pipefail; PGPASSWORD="$DB_PASS" pg_dump -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" \
                    --no-owner --no-privileges | gzip > "$GZ_FILE" )
            fi
        else
            # Use postgres system user (for standalone DBs)
            if command -v pv >/dev/null 2>&1; then
                ( set -o pipefail; runuser -u postgres -- pg_dump -d "$DB_NAME" \
                    --no-owner --no-privileges | pv -p -t -e -r | gzip > "$GZ_FILE" )
            else
                ( set -o pipefail; runuser -u postgres -- pg_dump -d "$DB_NAME" \
                    --no-owner --no-privileges | gzip > "$GZ_FILE" )
            fi
        fi
        STATUS=$?
        ;;

    *)
        echo "[FAIL] Unsupported DB engine: $DB_CONNECTION"
        pause; exit 1
        ;;
esac

if [ "$STATUS" -ne 0 ]; then
    echo "[FAIL] Backup failed!"
    log "FAILED backup DB: $BACKUP_LABEL ($DB_NAME)"
    shieldpress_notify_event "backup_fail" "Database backup failed" "$BACKUP_LABEL ($DB_CONNECTION/$DB_NAME)"
    rm -f "$GZ_FILE"
    pause; exit 1
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
DURATION_FMT=$(format_duration "$DURATION")
SIZE=$(du -h "$GZ_FILE" | awk '{print $1}')

# Auto-encrypt if enabled
GZ_FILE=$(maybe_encrypt_backup "$GZ_FILE")

echo ""
echo "===================================================="
echo "  DATABASE BACKUP COMPLETED"
echo "===================================================="
echo "  Target   : $BACKUP_LABEL"
echo "  Database : $DB_NAME ($DB_CONNECTION)"
echo "  File     : $GZ_FILE"
echo "  Size     : $SIZE"
echo "  Duration : $DURATION_FMT"
echo "===================================================="

TOTAL_DB=$(find "$BACKUP_DIR" -type f \( -name "*.gz" -o -name "*.enc" \) 2>/dev/null | wc -l)
TOTAL_DB_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')
echo ""
echo "  Total DB backups in dir: $TOTAL_DB files ($TOTAL_DB_SIZE)"
echo ""

log "SUCCESS backup DB: $BACKUP_LABEL ($DB_NAME) | Size: $SIZE | Duration: $DURATION_FMT"
shieldpress_notify_event "backup_success" "Database backup completed" "$BACKUP_LABEL ($DB_CONNECTION/$DB_NAME) | Size: $SIZE"

# Remote upload if domain is linked
[ -n "$DOMAIN_PATH" ] && remote_upload_backup "$GZ_FILE" "db"

pause
