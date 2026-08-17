#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
source "$BASE_DIR/core/helpers.sh"

LOG_FILE="$LOG_DIR/database.log"
DOMAINS_ROOT="/home/domains"
TMP_BACKUP="$DATA_DIR_TMP_BACKUPS"

mkdir -p "$LOG_DIR"
mkdir -p "$TMP_BACKUP"

pause() {
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
echo "              IMPORT TO DOMAIN DB"
echo "===================================================="

# ==========================
# LIST DOMAINS
# ==========================

echo ""
echo "Available Domains:"
echo "--------------------------------"

i=1
declare -A DOMAIN_MAP

for d in "$DOMAINS_ROOT"/*; do
    [ -d "$d" ] || continue
    if [ -f "$d/config/domain.env" ]; then
        source "$d/config/domain.env"
        echo "$i) $DOMAIN"
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

source "$DOMAIN_PATH/config/domain.env"

echo ""
echo "Domain   : $DOMAIN"
echo "Database : $DB_NAME"
echo "DB User  : $DB_USER"

# ==========================
# TEST DB CONNECTION
# ==========================

mysql -u"$DB_USER" -p"$DB_PASS" -e "USE $DB_NAME;" &>/dev/null

if [[ $? -ne 0 ]]; then
    echo "❌ Database connection failed!"
    pause
    exit 1
fi

echo "✔ Database connection successful."

# ==========================
# SHOW DB SIZE
# ==========================

DB_SIZE=$(mysql -N -e "
SELECT ROUND(SUM(data_length + index_length)/1024/1024,2)
FROM information_schema.tables
WHERE table_schema='$DB_NAME';
")

DB_SIZE=${DB_SIZE:-0}

echo "Current DB Size: ${DB_SIZE} MB"

# ==========================
# SELECT FILE
# ==========================

echo ""
read -p "Enter full path to .sql or .sql.gz file: " FILE

if [[ ! -f "$FILE" ]]; then
    echo "❌ File not found!"
    pause
    exit 1
fi

FILE_SIZE=$(du -h "$FILE" | awk '{print $1}')
echo "File size: $FILE_SIZE"

# ==========================
# BACKUP BEFORE IMPORT
# ==========================

echo ""
read -p "Backup current DB before import? (y/n): " BACKUP_CONFIRM

if [[ "$BACKUP_CONFIRM" == "y" ]]; then
    BACKUP_FILE="$TMP_BACKUP/${DB_NAME}_before_import_$(date +%Y%m%d_%H%M%S).sql"

    echo "Creating backup..."
    mysqldump --single-transaction --quick --routines --triggers \
        -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" > "$BACKUP_FILE"

    if [[ $? -ne 0 ]]; then
        echo "❌ Backup failed!"
        pause
        exit 1
    fi

    echo "✔ Backup saved: $BACKUP_FILE"
fi

# ==========================
# CONFIRM IMPORT
# ==========================

echo ""
echo -e "\e[31mWARNING: This will overwrite all data in database '$DB_NAME'!\e[0m"
read -p "Continue? (y/n): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "❌ Import cancelled."
    pause
    exit 1
fi

FILE_SIZE_BYTES=$(stat -c '%s' "$FILE" 2>/dev/null || echo 0)
FILE_SIZE_MB=$((FILE_SIZE_BYTES / 1024 / 1024))
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

# Increase packet size temporarily
mysql -e "SET GLOBAL max_allowed_packet=1073741824;" 2>/dev/null

# ==========================
# IMPORT LOGIC
# ==========================

IMPORT_OK=0

if [[ "$FILE" == *.gz ]]; then
    if command -v pv >/dev/null 2>&1; then
        pv -s "$FILE_SIZE_BYTES" -p -t -e -r "$FILE" | gunzip | mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME"
        IMPORT_OK=$?
    else
        gunzip < "$FILE" | mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" &
        IMPORT_PID=$!
        import_spinner $IMPORT_PID
        wait $IMPORT_PID
        IMPORT_OK=$?
    fi
else
    if command -v pv >/dev/null 2>&1; then
        pv -s "$FILE_SIZE_BYTES" -p -t -e -r "$FILE" | mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME"
        IMPORT_OK=$?
    else
        mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$FILE" &
        IMPORT_PID=$!
        import_spinner $IMPORT_PID
        wait $IMPORT_PID
        IMPORT_OK=$?
    fi
fi

if [[ $IMPORT_OK -ne 0 ]]; then
    echo "❌ Import failed!"
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

echo "✔ Import completed in ${DUR_FMT}"

# ==========================
# VERIFY DB AFTER IMPORT
# ==========================

NEW_SIZE=$(mysql -N -e "
SELECT ROUND(SUM(data_length + index_length)/1024/1024,2)
FROM information_schema.tables
WHERE table_schema='$DB_NAME';
")

NEW_SIZE=${NEW_SIZE:-0}

echo "New DB Size: ${NEW_SIZE} MB"

# ==========================
# CHECK TABLE PREFIX (WordPress)
# ==========================

WP_CONFIG="$DOMAIN_PATH/public_html/wp-config.php"

if [[ -f "$WP_CONFIG" ]]; then
    # Get table_prefix from wp-config.php
    WP_PREFIX=$(grep -oP "^\s*\\\$table_prefix\s*=\s*['\"]\\K[^'\"]*" "$WP_CONFIG" 2>/dev/null)

    if [[ -n "$WP_PREFIX" ]]; then
        # Detect prefix from imported DB (find *_options table)
        DB_PREFIX=$(mysql -u"$DB_USER" -p"$DB_PASS" -N -e "
            SELECT REPLACE(table_name, 'options', '')
            FROM information_schema.tables
            WHERE table_schema='$DB_NAME'
              AND table_name LIKE '%_options'
            LIMIT 1;
        " 2>/dev/null)

        if [[ -n "$DB_PREFIX" && "$DB_PREFIX" != "$WP_PREFIX" ]]; then
            echo ""
            echo "⚠ TABLE PREFIX MISMATCH DETECTED!"
            echo "  wp-config.php : \$table_prefix = '$WP_PREFIX'"
            echo "  Imported DB   : tables use prefix '$DB_PREFIX'"
            echo ""
            echo "  1) Update wp-config.php to '$DB_PREFIX' (recommended)"
            echo "  2) Rename DB tables from '${DB_PREFIX}' to '${WP_PREFIX}'"
            echo "  3) Skip - do nothing"
            echo ""
            read -p "  Select option (1/2/3): " PREFIX_ACTION

            case "$PREFIX_ACTION" in
                1)
                    # Backup wp-config.php
                    cp "$WP_CONFIG" "${WP_CONFIG}.bak.$(date +%Y%m%d_%H%M%S)"
                    sed -i "s/\$table_prefix\s*=\s*['\"][^'\"]*['\"];/\$table_prefix = '${DB_PREFIX}';/" "$WP_CONFIG"
                    echo "  ✔ wp-config.php updated: \$table_prefix = '$DB_PREFIX'"
                    ;;
                2)
                    echo "  Renaming tables..."
                    TABLES=$(mysql -u"$DB_USER" -p"$DB_PASS" -N -e "
                        SELECT table_name FROM information_schema.tables
                        WHERE table_schema='$DB_NAME'
                          AND table_name LIKE '${DB_PREFIX}%';
                    " 2>/dev/null)

                    RENAME_OK=0
                    while IFS= read -r tbl; do
                        [[ -z "$tbl" ]] && continue
                        NEW_TBL="${WP_PREFIX}${tbl#$DB_PREFIX}"
                        mysql -u"$DB_USER" -p"$DB_PASS" -e "RENAME TABLE \`$DB_NAME\`.\`$tbl\` TO \`$DB_NAME\`.\`$NEW_TBL\`;" 2>/dev/null
                        if [[ $? -ne 0 ]]; then
                            echo "  ❌ Failed to rename: $tbl → $NEW_TBL"
                            RENAME_OK=1
                        fi
                    done <<< "$TABLES"

                    if [[ $RENAME_OK -eq 0 ]]; then
                        # Also update prefix references in options and usermeta tables
                        mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
                            UPDATE \`${WP_PREFIX}options\`
                            SET option_name = REPLACE(option_name, '${DB_PREFIX}', '${WP_PREFIX}')
                            WHERE option_name LIKE '${DB_PREFIX}%';
                        " 2>/dev/null
                        mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
                            UPDATE \`${WP_PREFIX}usermeta\`
                            SET meta_key = REPLACE(meta_key, '${DB_PREFIX}', '${WP_PREFIX}')
                            WHERE meta_key LIKE '${DB_PREFIX}%';
                        " 2>/dev/null
                        echo "  ✔ All tables renamed from '${DB_PREFIX}' to '${WP_PREFIX}'"
                    else
                        echo "  ⚠ Some tables failed to rename. Check manually."
                    fi
                    ;;
                *)
                    echo "  Skipped."
                    ;;
            esac
        else
            [[ -n "$DB_PREFIX" ]] && echo "✔ Table prefix matches wp-config.php: '$WP_PREFIX'"
        fi
    fi
fi

# ==========================
# CLEAR CACHE (WordPress)
# ==========================

WP_CONFIG="${WP_CONFIG:-$DOMAIN_PATH/public_html/wp-config.php}"
if [[ -f "$WP_CONFIG" ]]; then
    purge_wp_cache
fi

# ==========================
# LOG
# ==========================

echo "$(date '+%Y-%m-%d %H:%M:%S') - Imported $FILE into $DB_NAME (Domain: $DOMAIN) - Duration $DUR_FMT" >> "$LOG_FILE"

echo ""
echo "========================================"
echo " 🎉 IMPORT SUCCESSFUL"
echo "----------------------------------------"
echo " Domain   : $DOMAIN"
echo " Database : $DB_NAME"
echo " File     : $FILE_SIZE"
echo " Duration : $DUR_FMT"
echo "========================================"

pause
exit 0