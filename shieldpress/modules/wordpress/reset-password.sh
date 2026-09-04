#!/bin/bash

source /opt/shieldpress/modules/wordpress/helpers.sh
source "$BASE_DIR/core/paths.sh"

LOG_FILE="$LOG_DIR/wp-reset.log"
mkdir -p "$LOG_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"
}

generate_pass() {
    tr -dc 'A-Za-z0-9!@#$%&*' </dev/urandom | head -c 16
}

# ==========================
# SELECT DOMAIN
# ==========================

select_domain || exit 1

_ENV="$DOMAIN_PATH/config/domain.env"
DOMAIN=$(grep "^DOMAIN=" "$_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
PHP_VERSION=$(grep "^PHP_VERSION=" "$_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
_CLEAN=$(grep "^CLEAN_DOMAIN=" "$_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
[ -n "$_CLEAN" ] && CLEAN_DOMAIN="$_CLEAN"

if [ ! -f "$ROOT/wp-config.php" ]; then
    echo "WordPress not installed!"
    exit 1
fi

PHP_SHORT=$(echo "$PHP_VERSION" | tr -d '.')
PHP_BIN="/opt/remi/php${PHP_SHORT}/root/usr/bin/php"

if [ ! -x "$PHP_BIN" ]; then
    echo "PHP binary not found!"
    exit 1
fi

WP_CMD=(sudo -u "$CLEAN_DOMAIN" "$PHP_BIN" -d error_reporting="E_ALL & ~E_DEPRECATED & ~E_USER_DEPRECATED" -d display_errors=0 /usr/local/bin/wp)

# ==========================
# GET ADMIN LIST
# ==========================

echo ""
echo "Fetching administrator accounts..."
echo ""

ADMIN_USERS=()
while IFS= read -r USER_LOGIN; do
    [ -n "$USER_LOGIN" ] || continue
    [[ "$USER_LOGIN" =~ ^[A-Za-z0-9._@-]+$ ]] || continue
    ADMIN_USERS+=("$USER_LOGIN")
done < <("${WP_CMD[@]}" user list --role=administrator --field=user_login --path="$ROOT" 2>>"$LOG_FILE")

if [ ${#ADMIN_USERS[@]} -eq 0 ]; then
    echo "No administrator found!"
    exit 1
fi

if [ ${#ADMIN_USERS[@]} -eq 1 ]; then
    SELECTED_USER="${ADMIN_USERS[0]}"
    echo "Only one admin found: $SELECTED_USER"
else
    echo "Available Admin Users:"
    echo "--------------------------------"
    for i in "${!ADMIN_USERS[@]}"; do
        echo "$((i+1))) ${ADMIN_USERS[$i]}"
    done
    echo "--------------------------------"

    read -p "Select user number: " USER_CHOICE
    INDEX=$((USER_CHOICE-1))

    if [ -z "${ADMIN_USERS[$INDEX]}" ]; then
        echo "Invalid selection!"
        exit 1
    fi

    SELECTED_USER="${ADMIN_USERS[$INDEX]}"
fi

echo ""
read -p "Confirm reset password for '$SELECTED_USER'? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-y}"
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 1; }

# ==========================
# RESET PASSWORD
# ==========================

NEW_PASS=$(generate_pass)

echo ""
echo "Resetting password..."
echo ""

"${WP_CMD[@]}" user update "$SELECTED_USER" \
--user_pass="$NEW_PASS" \
--path="$ROOT" >> "$LOG_FILE" 2>&1

if [ $? -ne 0 ]; then
    echo "Password reset failed!"
    exit 1
fi

# ==========================
# SAVE TO DB.TXT
# ==========================

cat >> "$DOMAIN_PATH/db.txt" <<EOF

----------------------------
Password Reset:
User: $SELECTED_USER
New Password: $NEW_PASS
Reset At: $(date '+%Y-%m-%d %H:%M:%S')
EOF
chmod 600 "$DOMAIN_PATH/db.txt"

# ==========================
# OUTPUT
# ==========================

echo "======================================"
echo "Password Reset Successfully!"
echo "--------------------------------------"
echo "Domain : $SELECTED_DOMAIN"
echo "User   : $SELECTED_USER"
echo "New Pass: $NEW_PASS"
echo "======================================"

log "Password reset for $SELECTED_DOMAIN - User: $SELECTED_USER"

read -p "Press Enter..."
