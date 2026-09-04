#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"

DATA_FILE="$DATA_DIR/databases.list"
LOG_FILE="$LOG_DIR/database.log"
BACKUP_DIR="$DATA_DIR_TMP_BACKUPS"

mkdir -p $BACKUP_DIR

pause(){
    echo ""
    read -p "Press Enter to continue..." dummy
}

# Simple spinner for when pv is not available
import_spinner(){
    local pid=$1
    local delay=0.5
    local spinstr='|/-\'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i+1) % 4 ))
        printf "\r  Importing... %s " "${spinstr:$i:1}"
        sleep $delay
    done
    printf "\r                    \r"
}

clear
echo "===================================================="
echo "                 IMPORT DATABASE"
echo "===================================================="

# -----------------------
# CHỌN DATABASE (numbered)
# -----------------------

echo ""
echo "Available Databases:"
echo "--------------------------------"

declare -A DB_MAP
i=1
while IFS= read -r db; do
    [ -z "$db" ] && continue
    echo "  $i) $db"
    DB_MAP[$i]="$db"
    ((i++))
done < <(mysql -N -e "SHOW DATABASES;" | grep -Ev "(information_schema|performance_schema|mysql|sys)")

echo "--------------------------------"

if [ "$i" -eq 1 ]; then
    echo "No databases found."
    pause
    exit 1
fi

read -p "Select database number: " DB_CHOICE

DB_NAME="${DB_MAP[$DB_CHOICE]}"

if [[ -z "$DB_NAME" ]]; then
    echo "Invalid selection!"
    pause
    exit 1
fi

echo ""
echo "Selected: $DB_NAME"

# -----------------------
# CHỌN FILE
# -----------------------

echo ""
read -p "Enter full path to .sql or .sql.gz file: " FILE

if [[ ! -f "$FILE" ]]; then
    echo "File not found!"
    pause
    exit 1
fi

FILE_SIZE=$(du -h "$FILE" | awk '{print $1}')
echo "File size: $FILE_SIZE"

echo ""
read -p "Backup database before import? [Y/n]: " BACKUP_CONFIRM
BACKUP_CONFIRM="${BACKUP_CONFIRM:-y}"

if [[ "$BACKUP_CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Creating backup..."

    BACKUP_FILE="$BACKUP_DIR/${DB_NAME}_before_import_$(date +%Y%m%d_%H%M%S).sql"

    mysqldump --single-transaction --quick --routines --triggers $DB_NAME > $BACKUP_FILE

    if [[ $? -ne 0 ]]; then
        echo "Backup failed!"
        pause
        exit 1
    fi

    echo "Backup saved: $BACKUP_FILE"
fi

echo ""
read -p "Confirm import into '$DB_NAME'? This may overwrite data (y/n): " CONFIRM

if [[ "$CONFIRM" != "y" ]]; then
    echo "Cancelled."
    pause
    exit 0
fi

FILE_SIZE_BYTES=$(stat -c '%s' "$FILE" 2>/dev/null || echo 0)
FILE_SIZE_MB=$((FILE_SIZE_BYTES / 1024 / 1024))
# Compressed files expand ~5x, estimate based on uncompressed size for import speed
if [[ "$FILE" == *.gz ]]; then
    EST_DATA_MB=$((FILE_SIZE_MB * 5))
else
    EST_DATA_MB=$FILE_SIZE_MB
fi
EST_SPEED=20
EST_SEC=$((EST_DATA_MB / EST_SPEED))
[ "$EST_SEC" -lt 1 ] && EST_SEC=1

if [ "$EST_SEC" -ge 3600 ]; then
    EST_FMT=$(printf "%dh %dm %ds" $((EST_SEC/3600)) $((EST_SEC%3600/60)) $((EST_SEC%60)))
elif [ "$EST_SEC" -ge 60 ]; then
    EST_FMT=$(printf "%dm %ds" $((EST_SEC/60)) $((EST_SEC%60)))
else
    EST_FMT="${EST_SEC}s"
fi

echo ""
echo "Starting import..."
echo "File size : $FILE_SIZE"
echo "Est. time : ~${EST_FMT}"
echo ""

START_TIME=$(date +%s)

# -----------------------
# IMPORT LOGIC
# -----------------------

# Tăng max_allowed_packet tạm thời
mysql -e "SET GLOBAL max_allowed_packet=1073741824;" 2>/dev/null

IMPORT_OK=0

if [[ "$FILE" == *.gz ]]; then
    if command -v pv >/dev/null 2>&1; then
        pv -s "$FILE_SIZE_BYTES" -p -t -e -r "$FILE" | gunzip | mysql --max_allowed_packet=1G $DB_NAME
        IMPORT_OK=$?
    else
        gunzip < "$FILE" | mysql --max_allowed_packet=1G $DB_NAME &
        IMPORT_PID=$!
        import_spinner $IMPORT_PID
        wait $IMPORT_PID
        IMPORT_OK=$?
    fi
else
    if command -v pv >/dev/null 2>&1; then
        pv -s "$FILE_SIZE_BYTES" -p -t -e -r "$FILE" | mysql --max_allowed_packet=1G $DB_NAME
        IMPORT_OK=$?
    else
        mysql --max_allowed_packet=1G $DB_NAME < "$FILE" &
        IMPORT_PID=$!
        import_spinner $IMPORT_PID
        wait $IMPORT_PID
        IMPORT_OK=$?
    fi
fi

if [[ $IMPORT_OK -ne 0 ]]; then
    echo ""
    echo "========================================"
    echo " Import FAILED!"
    echo "========================================"
    pause
    exit 1
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
if [ "$DURATION" -ge 3600 ]; then
    DUR_FMT=$(printf "%dh %dm %ds" $((DURATION/3600)) $((DURATION%3600/60)) $((DURATION%60)))
elif [ "$DURATION" -ge 60 ]; then
    DUR_FMT=$(printf "%dm %ds" $((DURATION/60)) $((DURATION%60)))
else
    DUR_FMT="${DURATION}s"
fi

echo ""
echo "========================================"
echo " Import Completed Successfully!"
echo "----------------------------------------"
echo " Database : $DB_NAME"
echo " File     : $FILE"
echo " Size     : $FILE_SIZE"
echo " Duration : $DUR_FMT"
echo "========================================"

echo "$(date '+%Y-%m-%d %H:%M:%S') - Imported $FILE into $DB_NAME - Duration $DUR_FMT" >> $LOG_FILE

pause
