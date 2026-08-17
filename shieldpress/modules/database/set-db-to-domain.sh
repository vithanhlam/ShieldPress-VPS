#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
source "$BASE_DIR/modules/helpers/custom.sh"

DATA_FILE="$DATA_DIR/databases.list"
DOMAINS_ROOT="/home/domains"

clear

echo "===================================================="
echo "           SET DATABASE TO WEBSITE"
echo "===================================================="

# =========================================
# CHECK DATABASE LIST
# =========================================

if [ ! -f "$DATA_FILE" ]; then
    echo "Database list not found!"
    pause
    exit
fi


# =========================================
# LOAD DATABASE LIST
# =========================================

mapfile -t DB_LINES < "$DATA_FILE"

if [ ${#DB_LINES[@]} -eq 0 ]; then
    echo "No databases available!"
    pause
    exit
fi


# =========================================
# SHOW DATABASE MENU
# =========================================

echo ""
echo "Available Databases"
echo "----------------------------------------"

for i in "${!DB_LINES[@]}"; do

LINE="${DB_LINES[$i]}"

DB_NAME=$(echo "$LINE" | awk -F'|' '{print $1}' | cut -d'=' -f2 | xargs)
DB_USER=$(echo "$LINE" | awk -F'|' '{print $2}' | cut -d'=' -f2 | xargs)

printf "%s) %s (%s)\n" "$((i+1))" "$DB_NAME" "$DB_USER"

done


echo ""
read -p "Select database: " DB_SELECT

# validate
if ! [[ "$DB_SELECT" =~ ^[0-9]+$ ]] || \
   [ "$DB_SELECT" -lt 1 ] || \
   [ "$DB_SELECT" -gt "${#DB_LINES[@]}" ]; then

    echo "Invalid database selection!"
    pause
    exit
fi


# =========================================
# GET SELECTED DATABASE
# =========================================

LINE="${DB_LINES[$((DB_SELECT-1))]}"

DB_NAME=$(echo "$LINE" | grep -o 'DB_NAME=[^|]*' | cut -d'=' -f2 | xargs)
DB_USER=$(echo "$LINE" | grep -o 'DB_USER=[^|]*' | cut -d'=' -f2 | xargs)
DB_PASS=$(echo "$LINE" | grep -o 'DB_PASS=[^|]*' | cut -d'=' -f2 | xargs)



# =========================================
# LOAD DOMAIN LIST
# =========================================

DOMAIN_PATHS=()
DOMAIN_NAMES=()

for d in $DOMAINS_ROOT/*; do

    [ -d "$d" ] || continue

    ENV_FILE="$d/config/domain.env"

    if [ -f "$ENV_FILE" ]; then

        DOMAIN=$(grep "^DOMAIN=" "$ENV_FILE" | cut -d'=' -f2)

		DOMAIN_PATHS+=("$d")
		DOMAIN_NAMES+=("$DOMAIN")

    fi

done


if [ ${#DOMAIN_PATHS[@]} -eq 0 ]; then
    echo "No domains found!"
    pause
    exit
fi


# =========================================
# SHOW DOMAIN MENU
# =========================================

echo ""
echo "Available Domains"
echo "----------------------------------------"

for i in "${!DOMAIN_NAMES[@]}"; do

printf "%s) %s\n" "$((i+1))" "${DOMAIN_NAMES[$i]}"

done


echo ""
read -p "Select domain: " DOMAIN_SELECT

# validate
if ! [[ "$DOMAIN_SELECT" =~ ^[0-9]+$ ]] || \
   [ "$DOMAIN_SELECT" -lt 1 ] || \
   [ "$DOMAIN_SELECT" -gt "${#DOMAIN_PATHS[@]}" ]; then

    echo "Invalid domain selection!"
    pause
    exit
fi


# =========================================
# GET SELECTED DOMAIN
# =========================================

DOMAIN_PATH="${DOMAIN_PATHS[$((DOMAIN_SELECT-1))]}"
DOMAIN="${DOMAIN_NAMES[$((DOMAIN_SELECT-1))]}"

ENV_FILE="$DOMAIN_PATH/config/domain.env"
WP_CONFIG="$DOMAIN_PATH/public_html/wp-config.php"


# =========================================
# CHECK WORDPRESS
# =========================================

if [ ! -f "$WP_CONFIG" ]; then
    echo "wp-config.php not found!"
    pause
    exit
fi


# =========================================
# UPDATE WP-CONFIG
# =========================================

echo ""
echo "Updating wp-config.php..."

sed -i "s/define( *'DB_NAME'.*/define( 'DB_NAME', '$DB_NAME' );/" "$WP_CONFIG"
sed -i "s/define( *'DB_USER'.*/define( 'DB_USER', '$DB_USER' );/" "$WP_CONFIG"
sed -i "s/define( *'DB_PASSWORD'.*/define( 'DB_PASSWORD', '$DB_PASS' );/" "$WP_CONFIG"


# =========================================
# UPDATE DOMAIN.ENV
# =========================================

echo "Updating domain.env..."

sed -i '/^DB_NAME=/d' "$ENV_FILE"
sed -i '/^DB_USER=/d' "$ENV_FILE"
sed -i '/^DB_PASS=/d' "$ENV_FILE"

echo "DB_NAME=$DB_NAME" >> "$ENV_FILE"
echo "DB_USER=$DB_USER" >> "$ENV_FILE"
echo "DB_PASS=$DB_PASS" >> "$ENV_FILE"


# =========================================
# DONE
# =========================================

echo ""
echo "========================================"
echo " Database Connected Successfully"
echo "----------------------------------------"
echo " Domain : $DOMAIN"
echo " DB Name: $DB_NAME"
echo " DB User: $DB_USER"
echo "========================================"

pause
