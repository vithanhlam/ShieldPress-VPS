#!/bin/bash
# Rotate the WordPress database password and/or the salts/keys of wp-config.php
# for a selected domain.

source /opt/shieldpress/modules/wordpress/helpers.sh
source "$BASE_DIR/core/paths.sh"

LOG_FILE="$LOG_DIR/wp-rotate-secrets.log"
mkdir -p "$LOG_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"
}

# Alphanumeric only: safe inside SQL, PHP single quotes and domain.env.
generate_db_pass() {
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
}

generate_salt() {
    tr -dc 'A-Za-z0-9!@#%^&*()_+=,.:;<>?~-' </dev/urandom | head -c 64
}

pause() { read -p "Press Enter..." _; }

select_domain || { pause; exit 1; }

_ENV="$DOMAIN_PATH/config/domain.env"
DOMAIN=$(grep "^DOMAIN=" "$_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
PHP_VERSION=$(grep "^PHP_VERSION=" "$_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
_CLEAN=$(grep "^CLEAN_DOMAIN=" "$_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
[ -n "$_CLEAN" ] && CLEAN_DOMAIN="$_CLEAN"
D_DB_NAME=$(grep "^DB_NAME=" "$_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
D_DB_USER=$(grep "^DB_USER=" "$_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
D_DB_CONN=$(grep "^DB_CONNECTION=" "$_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
D_DB_CONN="${D_DB_CONN:-mysql}"
WP_CONFIG="$ROOT/wp-config.php"

if [ ! -f "$WP_CONFIG" ]; then
    echo "wp-config.php not found for $DOMAIN!"
    pause; exit 1
fi

PHP_SHORT=$(echo "$PHP_VERSION" | tr -d '.')
PHP_BIN="/opt/remi/php${PHP_SHORT}/root/usr/bin/php"
if [ ! -x "$PHP_BIN" ]; then
    PHP_BIN="$(command -v php 2>/dev/null)"
fi
if [ -z "$PHP_BIN" ] || [ ! -x "$PHP_BIN" ]; then
    echo "PHP binary not found!"
    pause; exit 1
fi

echo ""
echo "===================================================="
echo "   WP-CONFIG SECRETS: $DOMAIN"
echo "===================================================="
echo "  1) Change database password"
echo "  2) Regenerate salts / security keys"
echo "  3) Both"
echo "  0) Cancel"
echo "----------------------------------------------------"
read -p "Select option: " OPT

DO_DB=0; DO_SALT=0
case "$OPT" in
    1) DO_DB=1 ;;
    2) DO_SALT=1 ;;
    3) DO_DB=1; DO_SALT=1 ;;
    *) echo "Cancelled."; exit 0 ;;
esac

if [ "$DO_DB" -eq 1 ] && [ "$D_DB_CONN" != "mysql" ]; then
    echo "Database password change supports MariaDB/MySQL only (this domain uses: $D_DB_CONN)."
    [ "$DO_SALT" -eq 1 ] || { pause; exit 1; }
    DO_DB=0
fi
if [ "$DO_DB" -eq 1 ] && { [ -z "$D_DB_USER" ] || [ -z "$D_DB_NAME" ]; }; then
    echo "DB_NAME / DB_USER missing in domain.env!"
    pause; exit 1
fi

echo ""
[ "$DO_DB" -eq 1 ]   && echo " - New random DB password for user '$D_DB_USER' (MariaDB, domain.env, wp-config.php)"
[ "$DO_SALT" -eq 1 ] && echo " - New salts/keys (all logged-in users will be logged out)"
read -p "Continue? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

# ==========================
# BACKUP
# ==========================

BACKUP_FILE="$WP_CONFIG.bak_$(date +%Y%m%d_%H%M%S)"
cp -p "$WP_CONFIG" "$BACKUP_FILE" || { echo "Backup failed!"; pause; exit 1; }
chmod 600 "$BACKUP_FILE"
echo "✔ Backup created: $BACKUP_FILE"

restore_config() {
    cp -p "$BACKUP_FILE" "$WP_CONFIG"
    echo "↩ wp-config.php restored from backup."
}

# Replace/append define() constants. Values arrive through the environment so
# no special character can break the shell or PHP quoting.
update_defines() {
    WPC_FILE="$WP_CONFIG" "$PHP_BIN" -r '
        $f = getenv("WPC_FILE");
        $c = file_get_contents($f);
        if ($c === false) { exit(1); }
        $keys = explode(",", getenv("WPC_KEYS"));
        foreach ($keys as $k) {
            $v = getenv("WPC_V_" . $k);
            if ($v === false || $v === "") { exit(2); }
            $line = "define( \x27" . $k . "\x27, \x27" . addcslashes($v, "\x27\\") . "\x27 );";
            $re = "/^[ \t]*define\s*\(\s*([\x27\"])" . $k . "\\1\s*,.*?\)\s*;[ \t]*$/m";
            if (preg_match($re, $c)) {
                $c = preg_replace_callback($re, function () use ($line) { return $line; }, $c, 1);
            } else {
                // Only salts/keys may be added; the DB password constant must already exist.
                if ($k === "DB_PASSWORD") { exit(3); }
                $marker = "/* That\x27s all, stop editing!";
                $p = strpos($c, $marker);
                if ($p === false) { $p = strpos($c, "require_once"); }
                if ($p === false) { $p = strpos($c, "\$table_prefix"); }
                if ($p === false) { exit(3); }
                $c = substr($c, 0, $p) . $line . "\n" . substr($c, $p);
            }
        }
        $tmp = $f . ".tmp" . getmypid();
        if (file_put_contents($tmp, $c) === false) { exit(4); }
        rename($tmp, $f);
    '
}

validate_config() {
    "$PHP_BIN" -l "$WP_CONFIG" >/dev/null 2>&1
}

# ==========================
# DATABASE PASSWORD
# ==========================

NEW_DB_PASS=""
if [ "$DO_DB" -eq 1 ]; then
    NEW_DB_PASS=$(generate_db_pass)
    [ -n "$NEW_DB_PASS" ] || { echo "Password generation failed!"; pause; exit 1; }

    OLD_DB_PASS=$(grep "^DB_PASS=" "$_ENV" | cut -d'=' -f2- | tr -d '[:space:]')

    # Every host entry of this user (localhost, 127.0.0.1, ...)
    mapfile -t DB_HOSTS < <(mysql -N -e "SELECT Host FROM mysql.user WHERE User='$D_DB_USER';")
    if [ ${#DB_HOSTS[@]} -eq 0 ]; then
        echo "❌ MariaDB user '$D_DB_USER' not found!"
        restore_config; pause; exit 1
    fi

    SQL=""
    for h in "${DB_HOSTS[@]}"; do
        SQL+="ALTER USER '$D_DB_USER'@'$h' IDENTIFIED BY '$NEW_DB_PASS'; "
    done
    SQL+="FLUSH PRIVILEGES;"

    if ! mysql -e "$SQL"; then
        echo "❌ Password change failed in MariaDB!"
        restore_config; pause; exit 1
    fi
    echo "✔ Password updated in MariaDB."

    export WPC_V_DB_PASSWORD="$NEW_DB_PASS"
    if ! mysql -u"$D_DB_USER" -p"$NEW_DB_PASS" -e "USE \`$D_DB_NAME\`;" &>/dev/null; then
        echo "❌ Connection test failed - reverting."
        if [ -n "$OLD_DB_PASS" ]; then
            mysql -e "$(for h in "${DB_HOSTS[@]}"; do echo "ALTER USER '$D_DB_USER'@'$h' IDENTIFIED BY '$OLD_DB_PASS';"; done) FLUSH PRIVILEGES;"
        fi
        restore_config; pause; exit 1
    fi
    echo "✔ Connection test successful."
fi

# ==========================
# WP-CONFIG UPDATE
# ==========================

KEYS=()
[ "$DO_DB" -eq 1 ] && KEYS+=("DB_PASSWORD")
if [ "$DO_SALT" -eq 1 ]; then
    for k in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
        KEYS+=("$k")
        export "WPC_V_$k=$(generate_salt)"
    done
fi
export WPC_KEYS
WPC_KEYS=$(IFS=,; echo "${KEYS[*]}")

update_defines
RC=$?
if [ $RC -ne 0 ] || ! validate_config; then
    echo "❌ Failed to update wp-config.php (code $RC)."
    restore_config
    if [ "$DO_DB" -eq 1 ] && [ -n "$OLD_DB_PASS" ]; then
        mysql -e "$(for h in "${DB_HOSTS[@]}"; do echo "ALTER USER '$D_DB_USER'@'$h' IDENTIFIED BY '$OLD_DB_PASS';"; done) FLUSH PRIVILEGES;"
        echo "↩ MariaDB password reverted."
    fi
    log "FAILED rotate for $DOMAIN (rc=$RC)"
    pause; exit 1
fi

chown "$CLEAN_DOMAIN:$CLEAN_DOMAIN" "$WP_CONFIG" 2>/dev/null
chmod 600 "$WP_CONFIG"
echo "✔ wp-config.php updated."

if [ "$DO_DB" -eq 1 ]; then
    sed -i "s|^DB_PASS=.*|DB_PASS=$NEW_DB_PASS|" "$_ENV"
    chown root:root "$_ENV"; chmod 600 "$_ENV"
    echo "✔ domain.env updated."

    cat >> "$DOMAIN_PATH/db.txt" <<EOT

----------------------------
DB Password Changed:
User: $D_DB_USER
New Password: $NEW_DB_PASS
Changed At: $(date '+%Y-%m-%d %H:%M:%S')
EOT
    chmod 600 "$DOMAIN_PATH/db.txt"
fi

# Drop cached pages/opcache so the new config is used immediately.
if command -v systemctl >/dev/null 2>&1; then
    systemctl reload "php${PHP_SHORT}-php-fpm" 2>/dev/null || systemctl reload "php-fpm" 2>/dev/null || true
fi

log "Rotated for $DOMAIN: db_password=$DO_DB salts=$DO_SALT"

echo ""
echo "======================================"
echo " Done: $DOMAIN"
[ "$DO_DB" -eq 1 ]   && echo " DB User    : $D_DB_USER" && echo " New DB Pass: $NEW_DB_PASS"
[ "$DO_SALT" -eq 1 ] && echo " Salts/keys regenerated (users must log in again)"
echo " Backup     : $BACKUP_FILE"
echo "======================================"
pause
