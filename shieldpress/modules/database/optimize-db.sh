#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"

LOG_FILE="$LOG_DIR/database.log"
DOMAINS_ROOT="/home/domains"
LOCK_DIR="/tmp/shieldpress_db_optimize.lock"

mkdir -p "$LOG_DIR"

pause() {
    echo ""
    read -p "Press Enter to continue..." dummy
}

# ==========================
# LOCK MECHANISM
# ==========================

if [ -d "$LOCK_DIR" ]; then
    echo "❌ Another optimization is running!"
    pause
    exit 1
fi

mkdir "$LOCK_DIR"

cleanup() {
    rm -rf "$LOCK_DIR"
}
trap cleanup EXIT

clear

echo "===================================================="
echo "          ENTERPRISE DATABASE OPTIMIZER"
echo "===================================================="
echo ""
echo "1) Optimize by Domain"
echo "2) Optimize by Database Name"
echo "0) Back"
echo "--------------------------------"
read -p "Select option: " MODE

if [[ "$MODE" == "0" ]]; then
    exit 0
fi

# ==========================
# SELECT DATABASE
# ==========================

if [[ "$MODE" == "1" ]]; then

    echo ""
    echo "Available Domains:"
    echo "--------------------------------"

    i=1
    declare -A DOMAIN_MAP

    for d in "$DOMAINS_ROOT"/*; do
        [ -d "$d" ] || continue
        if [ -f "$d/config/domain.env" ]; then
            local_DN=$(grep "^DOMAIN=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
            [ -z "$local_DN" ] && continue
            echo "$i) $local_DN"
            DOMAIN_MAP[$i]="$d"
            ((i++))
        fi
    done

    echo "--------------------------------"
    read -p "Select domain number: " choice

    DOMAIN_PATH="${DOMAIN_MAP[$choice]}"
    [[ -z "$DOMAIN_PATH" ]] && echo "❌ Invalid selection." && pause && exit 1

    _ENV="$DOMAIN_PATH/config/domain.env"
    DOMAIN=$(grep "^DOMAIN=" "$_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    DB_NAME=$(grep "^DB_NAME=" "$_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    DB_USER=$(grep "^DB_USER=" "$_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    DB_PASS=$(grep "^DB_PASS=" "$_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    DB_CONNECTION=$(grep "^DB_CONNECTION=" "$_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    DB_CONNECTION="${DB_CONNECTION:-mysql}"

else

    echo ""
    echo "Available Databases:"
    echo "--------------------------------"

    declare -A OPT_DB_MAP
    opt_i=1
    while IFS= read -r db; do
        [ -z "$db" ] && continue
        echo "  $opt_i) $db"
        OPT_DB_MAP[$opt_i]="$db"
        ((opt_i++))
    done < <(mysql -N -e "SHOW DATABASES;" | grep -Ev "(information_schema|performance_schema|mysql|sys)")

    echo "--------------------------------"

    if [ "$opt_i" -eq 1 ]; then
        echo "❌ No databases found."
        pause
        exit 1
    fi

    read -p "Select database number: " OPT_CHOICE
    DB_NAME="${OPT_DB_MAP[$OPT_CHOICE]}"

    [[ -z "$DB_NAME" ]] && echo "❌ Invalid selection." && pause && exit 1

    DB_USER=$(mysql -N -e "SELECT User FROM mysql.db WHERE Db='$DB_NAME' LIMIT 1;")
    [[ -z "$DB_USER" ]] && echo "❌ Could not detect DB user." && pause && exit 1

    read -s -p "Enter password for $DB_USER: " DB_PASS
    echo ""
fi

# ==========================
# TEST CONNECTION
# ==========================

mysql -u"$DB_USER" -p"$DB_PASS" -e "USE $DB_NAME;" &>/dev/null
[[ $? -ne 0 ]] && echo "❌ DB connection failed." && pause && exit 1

echo "✔ Connection OK"

# ==========================
# THRESHOLD INPUT
# ==========================

echo ""
read -p "Only optimize tables larger than X MB (default 5): " THRESHOLD
THRESHOLD=${THRESHOLD:-5}

echo "Using threshold: ${THRESHOLD} MB"

# ==========================
# SHOW DB STATS
# ==========================

DB_SIZE_BEFORE=$(mysql -N -e "
SELECT ROUND(SUM(data_length+index_length)/1024/1024,2)
FROM information_schema.tables
WHERE table_schema='$DB_NAME';
")

echo ""
echo "Database Size Before: ${DB_SIZE_BEFORE} MB"

# ==========================
# GET TABLES + FRAGMENTATION
# ==========================

TABLES=$(mysql -u"$DB_USER" -p"$DB_PASS" -N -e "
SELECT table_name,
ROUND((data_length+index_length)/1024/1024,2) AS size_mb,
ROUND(data_free/(data_length+index_length)*100,2) AS frag_percent
FROM information_schema.tables
WHERE table_schema='$DB_NAME';
")

echo ""
echo "Table | Size(MB) | Fragmentation(%)"
echo "----------------------------------------"

OPT_TABLES=()

while read -r TABLE SIZE FRAG; do

    [[ -z "$TABLE" ]] && continue

    printf "%-25s %-10s %-10s\n" "$TABLE" "$SIZE" "$FRAG"

    SIZE_INT=${SIZE%.*}

    if (( SIZE_INT >= THRESHOLD )); then
        OPT_TABLES+=("$TABLE")
    fi

done <<< "$TABLES"

echo ""
echo "Tables to optimize: ${#OPT_TABLES[@]}"

echo -e "\e[31mWARNING: This will optimize ${#OPT_TABLES[@]} table(s). Tables may be locked briefly.\e[0m"
read -p "Continue? (y/n): " CONFIRM
[[ ! "$CONFIRM" =~ ^[Yy]$ ]] && echo "❌ Cancelled." && pause && exit 1

echo ""
echo "Starting optimization (Parallel)..."

START_TIME=$(date +%s)
FAIL_COUNT=0

# ==========================
# PARALLEL OPTIMIZE
# ==========================

for TABLE in "${OPT_TABLES[@]}"; do
(
    mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "OPTIMIZE TABLE \`$TABLE\`;" >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        echo "Failed: $TABLE"
        exit 1
    fi
    mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "ANALYZE TABLE \`$TABLE\`;" >/dev/null 2>&1
) &
done

wait

# ==========================
# CHECK FAILURES
# ==========================

# Quick recheck for safety
mysql -u"$DB_USER" -p"$DB_PASS" -e "USE $DB_NAME;" &>/dev/null
[[ $? -ne 0 ]] && FAIL_COUNT=5

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# ==========================
# SIZE AFTER
# ==========================

DB_SIZE_AFTER=$(mysql -N -e "
SELECT ROUND(SUM(data_length+index_length)/1024/1024,2)
FROM information_schema.tables
WHERE table_schema='$DB_NAME';
")

echo ""
echo "----------------------------------------"
echo "Database Size After : ${DB_SIZE_AFTER} MB"
echo "Time Taken          : ${DURATION}s"
echo "----------------------------------------"

# ==========================
# AUTO RESTART IF FAIL
# ==========================

if (( FAIL_COUNT >= 3 )); then
    echo "⚠ Multiple failures detected. Restarting MariaDB..."
    systemctl restart mariadb
    sleep 3
    echo "✔ MariaDB restarted."
fi

# ==========================
# LOG
# ==========================

echo "$(date '+%Y-%m-%d %H:%M:%S') - Enterprise Optimize: $DB_NAME - Duration ${DURATION}s - Before ${DB_SIZE_BEFORE}MB - After ${DB_SIZE_AFTER}MB - Threshold ${THRESHOLD}MB" >> "$LOG_FILE"

echo ""
echo "========================================"
echo " 🎉 ENTERPRISE OPTIMIZATION COMPLETED"
echo "========================================"

pause
exit 0