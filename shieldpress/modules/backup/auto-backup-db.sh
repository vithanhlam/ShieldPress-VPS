#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
LOG_FILE="$LOG_DIR/auto-backup.log"
source "$BASE_DIR/modules/backup/_backup_helper.sh"
mkdir -p "$LOG_DIR"

pause(){ echo ""; read -p "Press Enter..."; }

clear
echo "===================================================="
echo "              AUTO BACKUP DATABASE"
echo "===================================================="
echo ""
echo "Select database by:"
echo "  1) Domain (read from domain config)"
echo "  2) Database name (list from MariaDB)"
echo "  3) Database name (list from PostgreSQL)"
echo "--------------------------------------------------"
read -p "Select mode: " SELECT_MODE

# Variables to be set by selection
DB_NAME=""
DB_USER=""
DB_PASS=""
DB_CONNECTION=""
DOMAIN=""
DOMAIN_PATH=""
BACKUP_DIR=""

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
        echo "No database configured for $DOMAIN"
        pause; exit 1
    fi

    BACKUP_DIR="$DOMAIN_PATH/backup/db"
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

    DB_CONNECTION="mysql"

    # Try to find linked domain for credentials + backup path
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
        DB_USER=$(mysql -N -e "SELECT User FROM mysql.db WHERE Db='$DB_NAME' LIMIT 1;" 2>/dev/null)
        [ -z "$DB_USER" ] && DB_USER="root"
        DB_PASS=""
    fi

    if [ -n "$DOMAIN_PATH" ]; then
        BACKUP_DIR="$DOMAIN_PATH/backup/db"
    else
        BACKUP_DIR="$BASE_DIR/backup/standalone-db"
        DOMAIN="$DB_NAME"
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
        DB_USER=$(runuser -u postgres -- psql -tAc "SELECT pg_catalog.pg_get_userbyid(d.datdba) FROM pg_catalog.pg_database d WHERE d.datname='$DB_NAME';" 2>/dev/null)
        DB_USER="${DB_USER:-postgres}"
        DB_PASS=""
    fi

    if [ -n "$DOMAIN_PATH" ]; then
        BACKUP_DIR="$DOMAIN_PATH/backup/db"
    else
        BACKUP_DIR="$BASE_DIR/backup/standalone-db"
        DOMAIN="$DB_NAME"
    fi
    ;;

*)
    echo "Invalid mode!"; pause; exit 1
    ;;
esac

# ==============================
# SCHEDULE SETTINGS
# ==============================

echo ""
echo "Database : $DB_NAME ($DB_CONNECTION)"
echo "User     : $DB_USER"
[ -n "$DOMAIN" ] && echo "Domain   : $DOMAIN"
echo "Backup to: $BACKUP_DIR"
echo ""

while true; do
    read -p "Keep how many local DB backups? (1-60): " RETENTION
    [[ "$RETENTION" =~ ^[0-9]+$ ]] && [ "$RETENTION" -ge 1 ] && [ "$RETENTION" -le 60 ] && break
    echo "Enter a number between 1 and 60"
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

case $FREQ in
    1) CRON_TIME="0 $HOUR * * *" ;;
    2)
        while true; do
            read -p "Day of week (0=Sun, 6=Sat): " DOW
            [[ "$DOW" =~ ^[0-6]$ ]] && break
            echo "Enter 0-6"
        done
        CRON_TIME="0 $HOUR * * $DOW"
        ;;
    3)
        while true; do
            read -p "Day of month (1-28): " DOM
            [[ "$DOM" =~ ^[0-9]+$ ]] && [ "$DOM" -ge 1 ] && [ "$DOM" -le 28 ] && break
            echo "Enter 1-28"
        done
        CRON_TIME="0 $HOUR $DOM * *"
        ;;
    *) echo "Invalid option"; pause; exit 1 ;;
esac

# ==============================
# GENERATE AUTO-BACKUP SCRIPT
# ==============================

mkdir -p "$BACKUP_DIR"

# Script location: domain config dir or central
if [ -n "$DOMAIN_PATH" ]; then
    AUTO_SCRIPT="$DOMAIN_PATH/config/auto-backup-db.sh"
else
    mkdir -p "$BASE_DIR/config/auto-backup"
    SAFE_NAME=$(echo "$DB_NAME" | sed 's/[^a-zA-Z0-9]/_/g')
    AUTO_SCRIPT="$BASE_DIR/config/auto-backup/auto-backup-db-${SAFE_NAME}.sh"
fi

# Generate mysqldump/pg_dump command based on engine
case "$DB_CONNECTION" in
    mysql|mariadb)
        if [ -n "$DB_PASS" ]; then
            DUMP_CMD="mysqldump --single-transaction --quick --routines --triggers -u \"\\\$DB_USER\" -p\"\\\$DB_PASS\" \"\\\$DB_NAME\" | gzip > \"\\\$FILE\""
        else
            DUMP_CMD="mysqldump --single-transaction --quick --routines --triggers \"\\\$DB_NAME\" | gzip > \"\\\$FILE\""
        fi
        ;;
    pgsql|postgres|postgresql)
        if [ -n "$DB_PASS" ]; then
            DUMP_CMD="PGPASSWORD=\"\\\$DB_PASS\" pg_dump -h 127.0.0.1 -U \"\\\$DB_USER\" -d \"\\\$DB_NAME\" --no-owner --no-privileges | gzip > \"\\\$FILE\""
        else
            DUMP_CMD="runuser -u postgres -- pg_dump -d \"\\\$DB_NAME\" --no-owner --no-privileges | gzip > \"\\\$FILE\""
        fi
        ;;
esac

cat > "$AUTO_SCRIPT" << SCRIPT
#!/bin/bash
set -o pipefail
BASE_DIR="$BASE_DIR"
BACKUP_DIR="$BACKUP_DIR"
DOMAIN="$DOMAIN"
DB_NAME="$DB_NAME"
DB_USER="$DB_USER"
DB_PASS="$DB_PASS"
DB_CONNECTION="$DB_CONNECTION"
RETENTION=$RETENTION
LOG_FILE="$LOG_FILE"

DATE=\$(date +%F_%H-%M-%S)
FILE="\$BACKUP_DIR/\${DB_NAME}_\$DATE.sql.gz"
mkdir -p "\$BACKUP_DIR"

case "\$DB_CONNECTION" in
    mysql|mariadb)
        mysqldump --single-transaction --quick --routines --triggers \\
            -u "\$DB_USER" -p"\$DB_PASS" "\$DB_NAME" | gzip > "\$FILE"
        ;;
    pgsql|postgres|postgresql)
        if [ -n "\$DB_PASS" ]; then
            PGPASSWORD="\$DB_PASS" pg_dump -h 127.0.0.1 -U "\$DB_USER" -d "\$DB_NAME" --no-owner --no-privileges | gzip > "\$FILE"
        else
            runuser -u postgres -- pg_dump -d "\$DB_NAME" --no-owner --no-privileges | gzip > "\$FILE"
        fi
        ;;
    *)
        echo "\$(date '+%F %T') | FAILED: \$DOMAIN unsupported DB engine \$DB_CONNECTION" >> "\$LOG_FILE"
        exit 1
        ;;
esac

if [ \$? -eq 0 ]; then
    echo "\$(date '+%F %T') | SUCCESS: \$DOMAIN DB backup \$FILE" >> "\$LOG_FILE"
    ls -1t "\$BACKUP_DIR"/*.gz 2>/dev/null | tail -n +\$((RETENTION+1)) | xargs -r rm -f
    if [ -f "\$BASE_DIR/modules/backup/_backup_helper.sh" ]; then
        source "\$BASE_DIR/modules/backup/_backup_helper.sh"
        shieldpress_notify_event "backup_success" "Auto database backup completed" "\$DOMAIN (\$DB_CONNECTION/\$DB_NAME): \$FILE"
        remote_upload_backup "\$FILE" "db"
    fi
else
    echo "\$(date '+%F %T') | FAILED: \$DOMAIN DB backup" >> "\$LOG_FILE"
    if [ -f "\$BASE_DIR/modules/backup/_backup_helper.sh" ]; then
        source "\$BASE_DIR/modules/backup/_backup_helper.sh"
        shieldpress_notify_event "backup_fail" "Auto database backup failed" "\$DOMAIN (\$DB_CONNECTION/\$DB_NAME)"
    fi
    rm -f "\$FILE"
fi
SCRIPT

chmod 700 "$AUTO_SCRIPT"

(crontab -l 2>/dev/null | grep -v "$AUTO_SCRIPT"; echo "$CRON_TIME $AUTO_SCRIPT") | crontab -

echo ""
echo "===================================================="
echo "  AUTO DB BACKUP SCHEDULED"
echo "===================================================="
echo "  Database : $DB_NAME ($DB_CONNECTION)"
echo "  User     : $DB_USER"
[ -n "$DOMAIN" ] && [ "$DOMAIN" != "$DB_NAME" ] && echo "  Domain   : $DOMAIN"
echo "  Schedule : $CRON_TIME"
echo "  Keep     : $RETENTION local backups"
echo "  Backup to: $BACKUP_DIR"
echo "  Script   : $AUTO_SCRIPT"
echo "===================================================="

pause
