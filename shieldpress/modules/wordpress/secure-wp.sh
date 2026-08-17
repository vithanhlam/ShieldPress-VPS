#!/bin/bash
source /opt/shieldpress/modules/wordpress/helpers.sh

select_domain || exit 1

ROOT="$DOMAIN_PATH/public_html"
ENV_FILE="$DOMAIN_PATH/config/domain.env"
PHP_VERSION=$(grep "^PHP_VERSION=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
SYSTEM_USER=$(grep "^SYSTEM_USER=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
PHP_SHORT=$(echo "$PHP_VERSION" | tr -d '.')
PHP_BIN="/opt/remi/php${PHP_SHORT}/root/usr/bin/php"
WP_CMD="sudo -u $SYSTEM_USER $PHP_BIN /usr/local/bin/wp"

WP_CONFIG="$ROOT/wp-config.php"
NGINX_CONF="/etc/nginx/conf.d/${CLEAN_DOMAIN}.conf"

if [ ! -f "$WP_CONFIG" ]; then
    echo "ERROR: wp-config.php not found at $ROOT"
    read -p "Press Enter..."; exit 1
fi

clear
echo "===================================================="
echo "     WORDPRESS SECURITY - $SELECTED_DOMAIN"
echo "===================================================="
echo ""
echo "1) Quick Harden (safe defaults)"
echo "2) Full Security Audit + Harden"
echo "3) Regenerate Security Keys (Salt)"
echo "4) Disable Author Enumeration"
echo "5) Security Status Check"
echo "0) Cancel"
echo "----------------------------------------------------"
read -p "Select: " OPT

# Helper: thêm define vào wp-config.php nếu chưa có
add_wp_define(){
    local KEY=$1 VAL=$2
    if ! grep -q "define('$KEY'" "$WP_CONFIG" 2>/dev/null; then
        sed -i "/That's all, stop editing/i define('$KEY', $VAL);" "$WP_CONFIG" 2>/dev/null || \
        sed -i "/table_prefix/a define('$KEY', $VAL);" "$WP_CONFIG"
        echo "[OK] Added: $KEY = $VAL"
    else
        echo "[INFO] Already set: $KEY"
    fi
}

case $OPT in

# ================================================
# 1) QUICK HARDEN
# ================================================
1)
    echo ""
    echo "Applying WordPress security hardening..."
    echo ""

    # --- wp-config.php defines ---
    add_wp_define "DISALLOW_FILE_EDIT"    "true"
    add_wp_define "DISALLOW_FILE_MODS"    "false"
    add_wp_define "WP_AUTO_UPDATE_CORE"   "'minor'"
    add_wp_define "DISABLE_WP_CRON"       "true"
    add_wp_define "WP_POST_REVISIONS"     "5"
    add_wp_define "EMPTY_TRASH_DAYS"      "7"
    add_wp_define "FORCE_SSL_ADMIN"       "true"
    add_wp_define "CONCATENATE_SCRIPTS"   "false"

    # --- Xóa plugin mặc định không dùng ---
    $WP_CMD plugin delete hello --path="$ROOT" 2>/dev/null && echo "[OK] Deleted: Hello Dolly"
    $WP_CMD plugin delete akismet --path="$ROOT" 2>/dev/null && echo "[OK] Deleted: Akismet"

    # --- Xóa theme mặc định thừa (giữ lại theme đang active + 1 default) ---
    ACTIVE_THEME=$($WP_CMD theme list --status=active --field=name --path="$ROOT" 2>/dev/null)
    for theme in twentytwentyone twentytwentytwo twentytwentythree; do
        [ "$theme" = "$ACTIVE_THEME" ] && continue
        $WP_CMD theme delete "$theme" --path="$ROOT" 2>/dev/null && echo "[OK] Deleted theme: $theme"
    done

    # --- File permissions ---
    chmod 600 "$WP_CONFIG"
    echo "[OK] wp-config.php set to 600"

    # Không cho phép truy cập wp-includes trực tiếp
    if [ ! -f "$ROOT/.htaccess.security" ]; then
        cat > "$ROOT/wp-includes/.htaccess" <<'HTEOF'
<IfModule mod_authz_core.c>
    Require all denied
</IfModule>
<IfModule !mod_authz_core.c>
    Order Allow,Deny
    Deny from all
</IfModule>
HTEOF
        echo "[OK] wp-includes protected"
    fi

    # --- Nginx security snippet ---
    SECURITY_SNIPPET="/etc/nginx/snippets/security-wp.conf"
    mkdir -p /etc/nginx/snippets

    cat > "$SECURITY_SNIPPET" <<'EOF'
# Block xmlrpc
location = /xmlrpc.php { deny all; access_log off; log_not_found off; }

# Block access to sensitive files
location ~* /(\.|wp-config\.php|readme\.html|license\.txt) { deny all; }

# Block PHP execution in uploads
location ~* /wp-content/uploads/.*\.php$ { deny all; }

# Block author enumeration
if ($args ~* "author=") { return 403; }

# Security headers
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
add_header X-Powered-By "ShieldPress" always;
EOF

    # Inject vào nginx config nếu chưa có
    if [ -f "$NGINX_CONF" ] && ! grep -q "security-wp.conf" "$NGINX_CONF"; then
        sed -i '/server_name/a\    include /etc/nginx/snippets/security-wp.conf;' "$NGINX_CONF"
        echo "[OK] Security snippet injected into nginx config"
    fi

    # Reload nginx
    if nginx -t 2>/dev/null; then
        systemctl reload nginx
        echo "[OK] Nginx reloaded"
    fi

    # --- Setup system cron thay WP-Cron ---
    CRON_CMD="*/5 * * * * $SYSTEM_USER $PHP_BIN $ROOT/wp-cron.php >/dev/null 2>&1"
    if ! crontab -l 2>/dev/null | grep -q "$ROOT/wp-cron.php"; then
        (crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab -
        echo "[OK] System cron added (every 5 min)"
    else
        echo "[INFO] System cron already exists"
    fi

    echo ""
    echo "[OK] Quick hardening complete!"
    ;;

# ================================================
# 2) FULL SECURITY AUDIT + HARDEN
# ================================================
2)
    echo ""
    echo "Running full security audit..."
    echo ""

    ISSUES=0

    # Check wp-config permissions
    PERM=$(stat -c "%a" "$WP_CONFIG" 2>/dev/null)
    if [ "$PERM" != "600" ]; then
        echo "[WARN] wp-config.php permission: $PERM (should be 600)"
        ISSUES=$((ISSUES+1))
    else
        echo "[OK] wp-config.php permission: 600"
    fi

    # Check debug mode
    if grep -q "WP_DEBUG.*true" "$WP_CONFIG" 2>/dev/null; then
        echo "[WARN] WP_DEBUG is enabled (should be false in production)"
        ISSUES=$((ISSUES+1))
    else
        echo "[OK] WP_DEBUG is off"
    fi

    # Check DB prefix
    PREFIX=$($WP_CMD config get table_prefix --path="$ROOT" 2>/dev/null)
    if [ "$PREFIX" = "wp_" ]; then
        echo "[WARN] Default table prefix 'wp_' (consider changing)"
        ISSUES=$((ISSUES+1))
    else
        echo "[OK] Custom table prefix: $PREFIX"
    fi

    # Check file editing
    if grep -q "DISALLOW_FILE_EDIT.*true" "$WP_CONFIG"; then
        echo "[OK] File editing disabled"
    else
        echo "[WARN] File editing is ALLOWED"
        ISSUES=$((ISSUES+1))
    fi

    # Check PHP in uploads
    UPLOAD_PHP=$(find "$ROOT/wp-content/uploads" -name "*.php" 2>/dev/null | wc -l)
    if [ "$UPLOAD_PHP" -gt 0 ]; then
        echo "[DANGER] $UPLOAD_PHP PHP files in uploads directory!"
        ISSUES=$((ISSUES+1))
    else
        echo "[OK] No PHP files in uploads"
    fi

    # Check 777 permissions
    PERM777=$(find "$ROOT" -perm 777 -type f 2>/dev/null | wc -l)
    if [ "$PERM777" -gt 0 ]; then
        echo "[WARN] $PERM777 files with 777 permissions"
        ISSUES=$((ISSUES+1))
    else
        echo "[OK] No 777 permissions"
    fi

    # Check WordPress version (outdated?)
    WP_VER=$($WP_CMD core version --path="$ROOT" 2>/dev/null)
    echo "[INFO] WordPress version: $WP_VER"

    # Check plugins needing update
    OUTDATED=$($WP_CMD plugin list --update=available --format=count --path="$ROOT" 2>/dev/null)
    if [ -n "$OUTDATED" ] && [ "$OUTDATED" -gt 0 ]; then
        echo "[WARN] $OUTDATED plugins need updating"
        ISSUES=$((ISSUES+1))
    else
        echo "[OK] All plugins up to date"
    fi

    # Check inactive plugins
    INACTIVE=$($WP_CMD plugin list --status=inactive --format=count --path="$ROOT" 2>/dev/null)
    if [ -n "$INACTIVE" ] && [ "$INACTIVE" -gt 0 ]; then
        echo "[WARN] $INACTIVE inactive plugins (should delete)"
        ISSUES=$((ISSUES+1))
    else
        echo "[OK] No inactive plugins"
    fi

    # Check security headers in nginx
    if [ -f "$NGINX_CONF" ]; then
        if grep -q "security-wp.conf" "$NGINX_CONF"; then
            echo "[OK] Security headers snippet active"
        else
            echo "[WARN] Security headers not configured"
            ISSUES=$((ISSUES+1))
        fi

        if grep -q "Strict-Transport-Security" "$NGINX_CONF"; then
            echo "[OK] HSTS enabled"
        else
            echo "[WARN] HSTS not enabled"
            ISSUES=$((ISSUES+1))
        fi
    fi

    echo ""
    echo "===================================================="
    if [ "$ISSUES" -eq 0 ]; then
        echo "  Security audit: ALL PASSED"
    else
        echo "  Security audit: $ISSUES issue(s) found"
        echo ""
        read -p "  Auto-fix with Quick Harden? (y/n): " FIX
        if [ "$FIX" = "y" ]; then
            bash "$0"
        fi
    fi
    echo "===================================================="
    ;;

# ================================================
# 3) REGENERATE SECURITY KEYS
# ================================================
3)
    echo ""
    echo "Regenerating WordPress security keys..."

    # Tải salt mới từ WordPress API
    NEW_SALTS=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/ 2>/dev/null)

    if [ -z "$NEW_SALTS" ]; then
        echo "[FAIL] Cannot fetch new salts from WordPress API"
        echo "Generating locally..."
        for KEY in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
            SALT=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9!@#$%^&*()-_=+' | head -c 64)
            NEW_SALTS="${NEW_SALTS}define('$KEY', '${SALT}');\n"
        done
    fi

    # Backup wp-config
    cp "$WP_CONFIG" "${WP_CONFIG}.bak.$(date +%s)"

    # Xóa salt cũ
    sed -i "/define('AUTH_KEY'/d"         "$WP_CONFIG"
    sed -i "/define('SECURE_AUTH_KEY'/d"  "$WP_CONFIG"
    sed -i "/define('LOGGED_IN_KEY'/d"    "$WP_CONFIG"
    sed -i "/define('NONCE_KEY'/d"        "$WP_CONFIG"
    sed -i "/define('AUTH_SALT'/d"        "$WP_CONFIG"
    sed -i "/define('SECURE_AUTH_SALT'/d" "$WP_CONFIG"
    sed -i "/define('LOGGED_IN_SALT'/d"   "$WP_CONFIG"
    sed -i "/define('NONCE_SALT'/d"       "$WP_CONFIG"

    # Thêm salt mới
    echo "$NEW_SALTS" >> "$WP_CONFIG"

    echo "[OK] Security keys regenerated"
    echo "[INFO] All existing sessions will be invalidated"
    ;;

# ================================================
# 4) DISABLE AUTHOR ENUMERATION
# ================================================
4)
    echo ""

    # Nginx level
    if [ -f "$NGINX_CONF" ]; then
        if ! grep -q 'author=' "$NGINX_CONF"; then
            sed -i '/server_name/a\    if ($args ~* "author=") { return 403; }' "$NGINX_CONF"
            nginx -t 2>/dev/null && systemctl reload nginx
            echo "[OK] Author enumeration blocked (nginx)"
        else
            echo "[INFO] Already blocked in nginx"
        fi
    fi

    # WordPress level
    add_wp_define "WP_SITEMAPS_ENABLED" "false"
    echo "[OK] Sitemaps disabled (prevents user enumeration)"
    ;;

# ================================================
# 5) SECURITY STATUS CHECK
# ================================================
5)
    echo ""
    echo "===================================================="
    echo "  SECURITY STATUS - $SELECTED_DOMAIN"
    echo "===================================================="
    echo ""

    # File permissions
    echo "--- FILE PERMISSIONS ---"
    echo "wp-config.php : $(stat -c '%a' "$WP_CONFIG" 2>/dev/null)"
    echo "public_html   : $(stat -c '%a' "$ROOT" 2>/dev/null)"
    echo "Owner         : $(stat -c '%U:%G' "$ROOT" 2>/dev/null)"
    echo ""

    # wp-config defines
    echo "--- WP-CONFIG DEFINES ---"
    for DEF in DISALLOW_FILE_EDIT DISABLE_WP_CRON WP_POST_REVISIONS FORCE_SSL_ADMIN WP_DEBUG WP_AUTO_UPDATE_CORE; do
        VAL=$(grep "define('$DEF'" "$WP_CONFIG" 2>/dev/null | head -1)
        if [ -n "$VAL" ]; then
            echo "  $DEF : $(echo "$VAL" | grep -oP "(?<=, ).*(?=\))")"
        else
            echo "  $DEF : not set"
        fi
    done
    echo ""

    # Nginx security
    echo "--- NGINX SECURITY ---"
    [ -f "$NGINX_CONF" ] && {
        grep -q "security-wp.conf"          "$NGINX_CONF" && echo "  Security snippet : ON" || echo "  Security snippet : OFF"
        grep -q "Strict-Transport-Security" "$NGINX_CONF" && echo "  HSTS             : ON" || echo "  HSTS             : OFF"
        grep -q "ssl-hardening.conf"        "$NGINX_CONF" && echo "  TLS hardening    : ON" || echo "  TLS hardening    : OFF"
        grep -q 'author='                   "$NGINX_CONF" && echo "  Author enum block: ON" || echo "  Author enum block: OFF"
    }
    echo ""

    # PHP isolation
    echo "--- PHP ISOLATION ---"
    POOL="/etc/opt/remi/php${PHP_SHORT}/php-fpm.d/${SYSTEM_USER}.conf"
    if [ -f "$POOL" ]; then
        grep -q "open_basedir"       "$POOL" && echo "  open_basedir     : ON" || echo "  open_basedir     : OFF"
        grep -q "disable_functions"  "$POOL" && echo "  disable_functions: ON" || echo "  disable_functions: OFF"
        grep -q "session.save_path"  "$POOL" && echo "  session isolation: ON" || echo "  session isolation: OFF"
    fi
    echo ""

    echo "===================================================="
    ;;

0) exit 0 ;;
*) echo "Invalid option" ;;
esac

echo ""
read -p "Press Enter..."
