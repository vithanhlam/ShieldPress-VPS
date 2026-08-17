#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"

LOG_FILE="$LOG_DIR/database.log"
DOMAINS_ROOT="/home/domains"

mkdir -p "$LOG_DIR"

pause() {
    echo ""
    read -p "Press Enter to continue..." dummy
}

clear

echo "===================================================="
echo "        CHANGE DATABASE PASSWORD (SAFE MODE)"
echo "===================================================="

echo ""
echo "Available Databases:"
echo "--------------------------------"

declare -A PASS_DB_MAP
pass_i=1
while IFS= read -r db; do
    [ -z "$db" ] && continue
    echo "  $pass_i) $db"
    PASS_DB_MAP[$pass_i]="$db"
    ((pass_i++))
done < <(mysql -N -e "SHOW DATABASES;" | grep -Ev "(information_schema|performance_schema|mysql|sys)")

echo "--------------------------------"

if [ "$pass_i" -eq 1 ]; then
    echo "❌ No databases found!"
    pause
    exit 1
fi

read -p "Select database number: " PASS_CHOICE
DB_NAME="${PASS_DB_MAP[$PASS_CHOICE]}"

if [[ -z "$DB_NAME" ]]; then
    echo "❌ Invalid selection!"
    pause
    exit 1
fi

# ==========================
# CHECK DB EXISTS
# ==========================

DB_CHECK=$(mysql -N -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='$DB_NAME';")

if [[ "$DB_CHECK" != "$DB_NAME" ]]; then
    echo "❌ Database does not exist!"
    pause
    exit 1
fi

# ==========================
# SHOW DB SIZE
# ==========================

DB_SIZE=$(mysql -N -e "
SELECT ROUND(SUM(data_length + index_length)/1024/1024,2)
FROM information_schema.tables
WHERE table_schema='$DB_NAME';
")

DB_SIZE=${DB_SIZE:-0}

# ==========================
# DETECT USER
# ==========================

DB_USER=$(mysql -N -e "SELECT User FROM mysql.db WHERE Db='$DB_NAME' LIMIT 1;")

if [[ -z "$DB_USER" ]]; then
    echo "⚠ Could not auto-detect DB user!"
    read -p "Enter DB User manually: " DB_USER
    [[ -z "$DB_USER" ]] && pause && exit 1
fi

# ==========================
# DETECT DOMAIN USING DB
# ==========================

USING_DOMAIN=""
DOMAIN_PATH=""
SYSTEM_USER=""

for d in "$DOMAINS_ROOT"/*; do
    [ -d "$d" ] || continue
    if [ -f "$d/config/domain.env" ]; then
        local_DN=$(grep "^DB_NAME=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
        if [[ "$local_DN" == "$DB_NAME" ]]; then
            USING_DOMAIN=$(grep "^DOMAIN=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
            DOMAIN_PATH="$d"
            SYSTEM_USER=$(grep "^SYSTEM_USER=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
            break
        fi
    fi
done

echo ""
echo "----------------------------------------"
echo "Database : $DB_NAME"
echo "Size     : ${DB_SIZE} MB"
echo "DB User  : $DB_USER"
echo "Domain   : ${USING_DOMAIN:-Not linked}"
echo "----------------------------------------"

# ==========================
# GENERATE PASSWORD
# ==========================

NEW_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)

echo ""
echo "Suggested New Password: $NEW_PASS"
echo ""

read -p "Use suggested password? (y/n): " USE_AUTO

if [[ "$USE_AUTO" != "y" ]]; then
    read -s -p "Enter New Password: " NEW_PASS
    echo ""
    [[ -z "$NEW_PASS" ]] && pause && exit 1
fi

# ==========================
# CONFIRM
# ==========================

echo ""
echo -e "\e[31mWARNING: This will change the password for user '$DB_USER' on database '$DB_NAME'!\e[0m"
read -p "Continue? (y/n): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "❌ Password change cancelled."
    pause
    exit 1
fi

# ==========================
# CHANGE PASSWORD
# ==========================

mysql -e "ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$NEW_PASS'; FLUSH PRIVILEGES;"

if [[ $? -ne 0 ]]; then
    echo "❌ Password change failed in MariaDB!"
    pause
    exit 1
fi

echo "✔ Password updated in MariaDB."

# ==========================
# TEST CONNECTION
# ==========================

mysql -u"$DB_USER" -p"$NEW_PASS" -e "USE \`$DB_NAME\`;" &>/dev/null

if [[ $? -ne 0 ]]; then
    echo "❌ Connection test failed!"
    pause
    exit 1
fi

echo "✔ Connection test successful."

# ==========================
# UPDATE domain.env
# ==========================

if [[ -n "$DOMAIN_PATH" && -f "$DOMAIN_PATH/config/domain.env" ]]; then
    sed -i "s/^DB_PASS=.*/DB_PASS=$NEW_PASS/" "$DOMAIN_PATH/config/domain.env"
    [[ -n "$SYSTEM_USER" ]] && chown "$SYSTEM_USER:$SYSTEM_USER" "$DOMAIN_PATH/config/domain.env" 2>/dev/null
    echo "✔ domain.env updated."
fi

# ==========================
# BACKUP + UPDATE wp-config
# ==========================

if [[ -n "$DOMAIN_PATH" ]]; then
    WP_CONFIG="$DOMAIN_PATH/public_html/wp-config.php"

    if [[ -f "$WP_CONFIG" ]]; then

        BACKUP_FILE="$WP_CONFIG.bak_$(date +%Y%m%d_%H%M%S)"
        cp "$WP_CONFIG" "$BACKUP_FILE"

        [[ -n "$SYSTEM_USER" ]] && chown "$SYSTEM_USER:$SYSTEM_USER" "$BACKUP_FILE" 2>/dev/null

        echo "✔ Backup created: $BACKUP_FILE"

        sed -i "s/define( *'DB_PASSWORD'.*/define('DB_PASSWORD', '$NEW_PASS');/" "$WP_CONFIG"

        [[ -n "$SYSTEM_USER" ]] && chown "$SYSTEM_USER:$SYSTEM_USER" "$WP_CONFIG" 2>/dev/null

        echo "✔ wp-config.php updated."
    else
        echo "⚠ wp-config.php not found."
    fi
fi

# ==========================
# LOG
# ==========================

echo "$(date '+%Y-%m-%d %H:%M:%S') - Changed DB password: $DB_NAME - User: $DB_USER - Domain: ${USING_DOMAIN:-none}" >> "$LOG_FILE"

echo ""
echo "========================================"
echo " 🎉 Password Changed Successfully!"
echo "----------------------------------------"
echo " Database : $DB_NAME"
echo " User     : $DB_USER"
echo " Domain   : ${USING_DOMAIN:-none}"
echo " Size     : ${DB_SIZE} MB"
echo "========================================"

pause
exit 0