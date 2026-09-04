#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
source "$BASE_DIR/modules/helpers/custom.sh"

DATA_FILE="$DATA_DIR/databases.list"
LOG_FILE="$LOG_DIR/database.log"
BACKUP_DIR="$DATA_DIR_TMP_BACKUPS"
DOMAINS_ROOT="/home/domains"

mkdir -p "$BACKUP_DIR"
mkdir -p "$LOG_DIR"

clear

echo "===================================================="
echo "           DELETE DATABASE (SAFE MODE)"
echo "===================================================="


# =========================================
# ERROR HANDLER
# =========================================

die(){
echo ""
echo "$1"
pause
exit
}

get_field(){
    local line="$1"
    local key="$2"
    echo "$line" | tr '|' '\n' | sed 's/^ *//;s/ *$//' | grep "^${key}=" | head -n1 | cut -d'=' -f2-
}


# =========================================
# LIST ALLOWED DATABASES
# =========================================

echo ""
echo "Allowed Databases (managed by ShieldPress):"
echo "----------------------------------------"

[ ! -f "$DATA_FILE" ] && die "No database list found!"

if [ -n "$1" ]; then
    DB_NAME="$1"
else
    declare -A DEL_DB_MAP
    local_i=1
    while IFS= read -r dbline; do
        dbname=$(get_field "$dbline" "DB_NAME")
        [ -z "$dbname" ] && continue
        echo "  $local_i) $dbname"
        DEL_DB_MAP[$local_i]="$dbname"
        ((local_i++))
    done < "$DATA_FILE"

    echo "----------------------------------------"

    if [ "$local_i" -eq 1 ]; then
        die "No managed databases found!"
    fi

    read -p "Select database number: " DEL_CHOICE
    DB_NAME="${DEL_DB_MAP[$DEL_CHOICE]}"
    [ -z "$DB_NAME" ] && die "Invalid selection!"
fi

PRE_CONFIRMED="$2"

[ -z "$DB_NAME" ] && die "Database name cannot be empty!"


# =========================================
# BLOCK SYSTEM DATABASE
# =========================================

case "$DB_NAME" in
mysql|sys|information_schema|performance_schema)
die "System database cannot be deleted!"
;;
esac


# =========================================
# CHECK DB IN databases.list
# =========================================

grep -q "^DB_NAME=$DB_NAME[[:space:]]*|" "$DATA_FILE"

[ $? -ne 0 ] && die "ERROR: This database is NOT managed by ShieldPress."


# =========================================
# CHECK DB EXISTS
# =========================================

DB_CHECK=$(mysql -N -B -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='$DB_NAME';" 2>&1)
DB_CHECK_STATUS=$?

[ "$DB_CHECK_STATUS" -ne 0 ] && die "Unable to check database: $DB_CHECK"

[ "$DB_CHECK" != "$DB_NAME" ] && die "Database does not exist!"


# =========================================
# CHECK DOMAIN.USAGE
# =========================================

for d in "$DOMAINS_ROOT"/*; do

[ -d "$d" ] || continue

ENV_FILE="$d/config/domain.env"

if [ -f "$ENV_FILE" ]; then

DOMAIN=$(grep "^DOMAIN=" "$ENV_FILE" | cut -d'=' -f2)
DOMAIN_DB=$(grep "^DB_NAME=" "$ENV_FILE" | cut -d'=' -f2)

if [[ "$DOMAIN_DB" == "$DB_NAME" ]]; then
die "ERROR: Database is used by domain: $DOMAIN"
fi

fi

done


# =========================================
# DETECT USER
# =========================================

DB_USER=$(grep "^DB_NAME=$DB_NAME[[:space:]]*|" "$DATA_FILE" | tr '|' '\n' | sed 's/^ *//;s/ *$//' | grep "^DB_USER=" | head -n1 | cut -d'=' -f2-)

if [ -z "$DB_USER" ]; then
DB_USER=$(mysql -N -e "
SELECT user
FROM mysql.db
WHERE Db='$DB_NAME'
LIMIT 1;
")
fi


echo ""
echo "----------------------------------------"
echo "Database : $DB_NAME"
echo "DB User  : ${DB_USER:-N/A}"
echo "----------------------------------------"


# =========================================
# DB SIZE
# =========================================

DB_SIZE=$(mysql -N -e "
SELECT ROUND(SUM(data_length + index_length)/1024/1024,2)
FROM information_schema.tables
WHERE table_schema='$DB_NAME';
")

DB_SIZE=${DB_SIZE:-0}

echo "Size     : ${DB_SIZE} MB"


# =========================================
# BACKUP OPTION
# =========================================

echo ""
read -p "Backup database before deletion? [Y/n]: " BACKUP_CONFIRM
BACKUP_CONFIRM="${BACKUP_CONFIRM:-y}"

if [[ "$BACKUP_CONFIRM" =~ ^[Yy]$ ]]; then

BACKUP_FILE="$BACKUP_DIR/${DB_NAME}_$(date +%Y%m%d_%H%M%S).sql"

echo "Creating backup..."

mysqldump --single-transaction --quick --routines --triggers "$DB_NAME" > "$BACKUP_FILE"

[ $? -ne 0 ] && die "Backup failed!"

echo "Backup saved: $BACKUP_FILE"

fi


# =========================================
# CONFIRM
# =========================================

echo ""
if [ "$PRE_CONFIRMED" = "--confirmed" ]; then
    CONFIRM="y"
else
    echo -e "\e[31mWARNING: This will permanently delete database '$DB_NAME' and its user!\e[0m"
    read -p "Continue? (y/n): " CONFIRM
fi

[[ ! "$CONFIRM" =~ ^[Yy]$ ]] && die "Cancelled."


# =========================================
# DELETE DATABASE
# =========================================

echo ""
echo "Deleting database..."

mysql -e "DROP DATABASE \`$DB_NAME\`;"

[ $? -ne 0 ] && die "Database deletion failed!"

echo "Database deleted."


# =========================================
# DELETE USER
# =========================================

if [[ -n "$DB_USER" ]]; then

USER_EXISTS=$(mysql -N -e "
SELECT user
FROM mysql.user
WHERE user='$DB_USER'
")

if [[ "$USER_EXISTS" == "$DB_USER" ]]; then

mysql -e "DROP USER '$DB_USER'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

echo "User deleted."

fi

fi


# =========================================
# REMOVE FROM databases.list
# =========================================

sed -i "/^DB_NAME=$DB_NAME[[:space:]]*|/d" "$DATA_FILE"


# =========================================
# LOG
# =========================================

echo "$(date '+%Y-%m-%d %H:%M:%S') - Deleted DB: $DB_NAME - User: $DB_USER - Size: ${DB_SIZE}MB" >> "$LOG_FILE"


# =========================================
# DONE
# =========================================

echo ""
echo "========================================"
echo " Database Deleted Successfully"
echo "----------------------------------------"
echo " DB Name : $DB_NAME"
echo " Size    : ${DB_SIZE} MB"
echo "========================================"

pause
