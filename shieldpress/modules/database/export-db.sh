#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
source "$BASE_DIR/modules/helpers/custom.sh"

DATA_FILE="$DATA_DIR/databases.list"
EXPORT_DIR="$DATA_DIR/exports"
LOG_FILE="$LOG_DIR/database.log"

mkdir -p "$EXPORT_DIR"
mkdir -p "$LOG_DIR"

get_field(){
    local line="$1"
    local key="$2"
    echo "$line" | tr '|' '\n' | sed 's/^ *//;s/ *$//' | grep "^${key}=" | head -n1 | cut -d'=' -f2-
}

database_exists(){
    local db="$1"
    [ "$(mysql -N -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${db}';" 2>/dev/null)" = "$db" ]
}

db_size_mb(){
    local db="$1"
    mysql -N -e "
SELECT COALESCE(ROUND(SUM(data_length + index_length)/1024/1024,2),0)
FROM information_schema.tables
WHERE table_schema='${db}';
" 2>/dev/null
}

format_duration(){
    local secs="$1"
    if [ "$secs" -ge 3600 ]; then
        printf "%dh %dm %ds" $((secs/3600)) $((secs%3600/60)) $((secs%60))
    elif [ "$secs" -ge 60 ]; then
        printf "%dm %ds" $((secs/60)) $((secs%60))
    else
        printf "%ds" "$secs"
    fi
}

clear
echo "===================================================="
echo "                  EXPORT DATABASE"
echo "===================================================="

if [ ! -s "$DATA_FILE" ]; then
    echo "No database data file found: $DATA_FILE"
    pause
    exit 1
fi

declare -A DB_LINES

printf "%-4s %-32s %-20s %-10s %s\n" "No" "Database" "User" "Status" "Domain"
echo "--------------------------------------------------------------------------------"

idx=1
while IFS= read -r line; do
    DB_NAME=$(get_field "$line" "DB_NAME")
    DB_USER=$(get_field "$line" "DB_USER")
    DOMAIN=$(get_field "$line" "DOMAIN")
    [ -n "$DB_NAME" ] || continue

    if database_exists "$DB_NAME"; then
        STATUS="exists"
    else
        STATUS="missing"
    fi

    printf "%-4s %-32s %-20s %-10s %s\n" "$idx" "$DB_NAME" "${DB_USER:-"-"}" "$STATUS" "${DOMAIN:-"-"}"
    DB_LINES["$DB_NAME"]="$line"
    idx=$((idx + 1))
done < "$DATA_FILE"

echo "--------------------------------------------------------------------------------"

if [ "$idx" -eq 1 ]; then
    echo "No databases found in data file."
    pause
    exit 1
fi

read -p "Enter database name to export: " DB_NAME
DB_NAME=$(echo "$DB_NAME" | tr -d '[:space:]')

if [ -z "$DB_NAME" ]; then
    echo "Database name cannot be empty."
    pause
    exit 1
fi

if [[ "$DB_NAME" =~ ^(mysql|sys|information_schema|performance_schema)$ ]]; then
    echo "System database cannot be exported from this tool."
    pause
    exit 1
fi

SELECTED_LINE="${DB_LINES[$DB_NAME]}"
if [ -z "$SELECTED_LINE" ]; then
    echo "Database is not listed in $DATA_FILE."
    pause
    exit 1
fi

if ! database_exists "$DB_NAME"; then
    echo "Database does not exist on this server: $DB_NAME"
    pause
    exit 1
fi

DB_USER=$(get_field "$SELECTED_LINE" "DB_USER")
DB_PASS=$(get_field "$SELECTED_LINE" "DB_PASS")
DB_SIZE_MB=$(db_size_mb "$DB_NAME")
DB_SIZE_MB="${DB_SIZE_MB:-0}"
DB_SIZE_BYTES=${DB_SIZE_MB%.*}
DB_SIZE_BYTES=$((DB_SIZE_BYTES * 1024 * 1024))
DATE=$(date +%Y%m%d_%H%M%S)
OUT_FILE="$EXPORT_DIR/${DB_NAME}_${DATE}.sql.gz"

echo ""
echo "Database : $DB_NAME"
echo "User     : ${DB_USER:-root/default}"
echo "Size     : ${DB_SIZE_MB} MB"
echo "Output   : $OUT_FILE"
echo ""
read -p "Confirm export? (y/n): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    pause
    exit 0
fi

echo ""
echo "Exporting..."
START_TIME=$(date +%s)

if [ -n "$DB_USER" ] && [ -n "$DB_PASS" ]; then
    # Dùng defaults-extra-file thay vì -p trực tiếp — tránh lộ password qua `ps aux`
    _MYCNF=$(mktemp /tmp/sp_mycnf_XXXXXX)
    chmod 600 "$_MYCNF"
    printf '[client]\nuser=%s\npassword=%s\n' "$DB_USER" "$DB_PASS" > "$_MYCNF"

    if command -v pv >/dev/null 2>&1 && [ "$DB_SIZE_BYTES" -gt 0 ]; then
        ( set -o pipefail; mysqldump --defaults-extra-file="$_MYCNF" --single-transaction --quick --routines --triggers "$DB_NAME" | pv -s "$DB_SIZE_BYTES" -p -t -e -r | gzip > "$OUT_FILE" )
    else
        ( set -o pipefail; mysqldump --defaults-extra-file="$_MYCNF" --single-transaction --quick --routines --triggers "$DB_NAME" | gzip > "$OUT_FILE" )
    fi

    rm -f "$_MYCNF"
else
    if command -v pv >/dev/null 2>&1 && [ "$DB_SIZE_BYTES" -gt 0 ]; then
        ( set -o pipefail; mysqldump --single-transaction --quick --routines --triggers "$DB_NAME" | pv -s "$DB_SIZE_BYTES" -p -t -e -r | gzip > "$OUT_FILE" )
    else
        ( set -o pipefail; mysqldump --single-transaction --quick --routines --triggers "$DB_NAME" | gzip > "$OUT_FILE" )
    fi
fi

STATUS=$?
rm -f "$_MYCNF" 2>/dev/null  # Xóa temp credentials file (nếu có) dù thành công hay thất bại
if [ "$STATUS" -ne 0 ]; then
    rm -f "$OUT_FILE"
    echo ""
    echo "Export failed."
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Export failed: $DB_NAME" >> "$LOG_FILE"
    pause
    exit 1
fi

END_TIME=$(date +%s)
DURATION_FMT=$(format_duration $((END_TIME - START_TIME)))
SIZE=$(du -h "$OUT_FILE" | awk '{print $1}')

echo ""
echo "========================================"
echo " Database Exported Successfully"
echo "----------------------------------------"
echo " Database : $DB_NAME"
echo " File     : $OUT_FILE"
echo " Size     : $SIZE"
echo " Duration : $DURATION_FMT"
echo "========================================"

echo "$(date '+%Y-%m-%d %H:%M:%S') - Exported DB: $DB_NAME - File: $OUT_FILE - Duration $DURATION_FMT" >> "$LOG_FILE"

pause
