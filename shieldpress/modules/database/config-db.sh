#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"

DOMAINS_ROOT="/home/domains"
LOG_FILE="$LOG_DIR/database.log"

mkdir -p "$LOG_DIR"

pause() {
    echo ""
    read -p "Press Enter to continue..." dummy
}

clear

echo "===================================================="
echo "            DOMAIN DB CONFIGURATION"
echo "===================================================="

# ==========================
# SELECT DOMAIN
# ==========================

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

if [[ -z "$DOMAIN_PATH" ]]; then
    echo "❌ Invalid selection."
    pause
    exit 1
fi

_ENV="$DOMAIN_PATH/config/domain.env"
DOMAIN=$(grep "^DOMAIN=" "$_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
DB_NAME=$(grep "^DB_NAME=" "$_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
DB_USER=$(grep "^DB_USER=" "$_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
DB_PASS=$(grep "^DB_PASS=" "$_ENV" | cut -d'=' -f2 | tr -d '[:space:]')

echo ""
echo "Domain   : $DOMAIN"
echo "Database : $DB_NAME"
echo ""

# ==========================
# SHOW CURRENT MYSQL VALUES
# ==========================

echo "Current MariaDB Values:"
echo "--------------------------------"

mysql -e "
SHOW VARIABLES WHERE Variable_name IN (
'innodb_buffer_pool_size',
'max_connections',
'tmp_table_size',
'max_heap_table_size'
);"

# Convert buffer pool to MB
CURRENT_BUFFER=$(mysql -N -e "SELECT @@innodb_buffer_pool_size/1024/1024;")

TOTAL_RAM=$(free -m | awk '/Mem:/ {print $2}')

MIN_BUFFER=$((TOTAL_RAM * 20 / 100))
MAX_BUFFER=$((TOTAL_RAM * 60 / 100))

echo ""
echo "--------------------------------"
echo "Detected RAM: ${TOTAL_RAM} MB"
echo "Recommended innodb_buffer_pool_size:"
echo "Min: ${MIN_BUFFER} MB"
echo "Max: ${MAX_BUFFER} MB"
echo "Current: ${CURRENT_BUFFER} MB"
echo "--------------------------------"

# ==========================
# INPUT NEW VALUES
# ==========================

echo ""
read -p "Enter new innodb_buffer_pool_size (MB): " NEW_BUFFER
read -p "Enter new max_connections (default 200): " NEW_CONN
read -p "Enter new tmp_table_size (MB, default 128): " NEW_TMP

NEW_CONN=${NEW_CONN:-200}
NEW_TMP=${NEW_TMP:-128}

if [[ -z "$NEW_BUFFER" ]]; then
    echo "❌ Buffer size required."
    pause
    exit 1
fi

if (( NEW_BUFFER < MIN_BUFFER || NEW_BUFFER > MAX_BUFFER )); then
    echo "⚠ Warning: Value outside recommended range."
fi

echo ""
read -p "Apply changes? (y/n): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "❌ Cancelled."
    pause
    exit 1
fi

# ==========================
# APPLY LIVE (NO RESTART)
# ==========================

mysql -e "SET GLOBAL innodb_buffer_pool_size=${NEW_BUFFER}*1024*1024;"
mysql -e "SET GLOBAL max_connections=${NEW_CONN};"
mysql -e "SET GLOBAL tmp_table_size=${NEW_TMP}*1024*1024;"
mysql -e "SET GLOBAL max_heap_table_size=${NEW_TMP}*1024*1024;"

if [[ $? -ne 0 ]]; then
    echo "❌ Failed to apply settings."
    pause
    exit 1
fi

echo "✔ Settings applied live."

# ==========================
# SAVE DOMAIN CONFIG FILE
# ==========================

DOMAIN_DB_CONF="$DOMAIN_PATH/config/db-tuning.cnf"

cat > "$DOMAIN_DB_CONF" <<EOF
# Domain DB tuning for $DOMAIN
innodb_buffer_pool_size=${NEW_BUFFER}M
max_connections=${NEW_CONN}
tmp_table_size=${NEW_TMP}M
max_heap_table_size=${NEW_TMP}M
EOF

chown "$SYSTEM_USER:$SYSTEM_USER" "$DOMAIN_DB_CONF" 2>/dev/null

echo "✔ Domain config saved:"
echo "$DOMAIN_DB_CONF"

# ==========================
# LOG
# ==========================

echo "$(date '+%Y-%m-%d %H:%M:%S') - Domain DB tuned: $DOMAIN - Buffer ${NEW_BUFFER}MB - Conn ${NEW_CONN}" >> "$LOG_FILE"

echo ""
echo "========================================"
echo "   DOMAIN DB CONFIG UPDATED SUCCESS"
echo "========================================"

pause
exit 0