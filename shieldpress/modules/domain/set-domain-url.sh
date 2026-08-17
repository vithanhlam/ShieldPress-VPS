#!/bin/bash

source /opt/shieldpress/modules/domain/helpers.sh

LOG_FILE="$LOG_DIR/domain-url.log"
mkdir -p "$LOG_DIR"

log(){  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"; }
pause(){ echo ""; read -p "Press Enter..."; }

select_domain || exit 1

ROOT="$DOMAIN_PATH/public_html"
ENV_FILE="$DOMAIN_PATH/config/domain.env"
PHP_SHORT=$(echo "$PHP_VERSION" | tr -d '.')
PHP_BIN="/opt/remi/php${PHP_SHORT}/root/usr/bin/php"
WP_CMD="sudo -u $SYSTEM_USER $PHP_BIN /usr/local/bin/wp"

if [ ! -f "$ROOT/wp-config.php" ]; then
    echo "WordPress not found at $ROOT"
    pause; exit 1
fi

if [ ! -x "$PHP_BIN" ]; then
    echo "PHP binary not found: $PHP_BIN"
    pause; exit 1
fi

# Read DB credentials from wp-config.php (authoritative source)
read_wpconfig_value(){
    local key="$1"
    grep -oP "define\s*\(\s*['\"]${key}['\"]\s*,\s*['\"]\\K[^'\"]*" "$ROOT/wp-config.php" | head -1
}

WP_DB_NAME=$(read_wpconfig_value "DB_NAME")
WP_DB_USER=$(read_wpconfig_value "DB_USER")
WP_DB_PASS=$(read_wpconfig_value "DB_PASSWORD")
WP_DB_HOST=$(read_wpconfig_value "DB_HOST")
WP_DB_HOST="${WP_DB_HOST:-localhost}"

if [ -z "$WP_DB_NAME" ] || [ -z "$WP_DB_USER" ]; then
    echo "Could not read DB credentials from wp-config.php"
    pause; exit 1
fi

echo ""
echo "Domain  : $SELECTED_DOMAIN"
echo "DB Name : $WP_DB_NAME (from wp-config.php)"
echo ""

read -p "Enter NEW domain or URL (e.g. example.com or https://example.com): " NEW_DOMAIN
[ -z "$NEW_DOMAIN" ] && { echo "Cannot be empty!"; pause; exit 1; }

# Normalize
NEW_DOMAIN=$(echo "$NEW_DOMAIN" | sed 's|/*$||')
[[ "$NEW_DOMAIN" =~ ^http ]] || NEW_DOMAIN="https://$NEW_DOMAIN"

echo ""
echo "New URL: $NEW_DOMAIN"
echo ""

read -p "Confirm update siteurl + home + full search-replace? (y/n): " CONFIRM
[ "$CONFIRM" != "y" ] && { echo "Cancelled."; exit 0; }

# Get old URL
OLD_URL=$($WP_CMD option get siteurl --path="$ROOT" 2>/dev/null)
[ -z "$OLD_URL" ] && { echo "Could not detect old siteurl!"; pause; exit 1; }

echo ""
echo "Old URL : $OLD_URL"
echo "New URL : $NEW_DOMAIN"
echo ""

# Temporary backup in /tmp (auto-deleted on success)
BFILE="/tmp/${WP_DB_NAME}_url_change_$(date +%Y%m%d_%H%M%S).sql"
echo "Creating temporary backup..."
mysqldump --single-transaction --quick -h "$WP_DB_HOST" -u "$WP_DB_USER" -p"$WP_DB_PASS" "$WP_DB_NAME" > "$BFILE"
[ $? -ne 0 ] && { echo "Backup failed!"; rm -f "$BFILE"; pause; exit 1; }
echo "[OK] Backup: $BFILE"

$WP_CMD option update siteurl "$NEW_DOMAIN" --path="$ROOT"
$WP_CMD option update home    "$NEW_DOMAIN" --path="$ROOT"

if [ $? -ne 0 ]; then
    echo "Failed to update siteurl/home"
    echo "Backup kept at: $BFILE"
    pause; exit 1
fi

echo "Running search-replace..."
$WP_CMD search-replace "$OLD_URL" "$NEW_DOMAIN" \
    --skip-columns=guid \
    --all-tables \
    --path="$ROOT"

if [ $? -ne 0 ]; then
    echo "Search-replace failed!"
    echo "Backup kept at: $BFILE"
    pause; exit 1
fi

# Flush cache
$WP_CMD cache flush --path="$ROOT" 2>/dev/null

# All done — remove temporary backup
rm -f "$BFILE"

echo ""
echo "[OK] Domain URL updated: $OLD_URL → $NEW_DOMAIN"
log "Domain $SELECTED_DOMAIN: $OLD_URL → $NEW_DOMAIN"

pause
