#!/bin/bash
set -uo pipefail
trap 'release_lock' EXIT
trap 'echo ""; echo "ERROR at line $LINENO (code $?)"; read -p "Press Enter to continue..."' ERR

source /opt/shieldpress/modules/wordpress/helpers.sh
source "$BASE_DIR/core/paths.sh"

LOG_FILE="$LOG_DIR/staging.log"
BACKUP_DIR="$DATA_DIR_TMP_BACKUPS"
LOCK_FILE="/tmp/shieldpress_staging.lock"

mkdir -p "$LOG_DIR"
mkdir -p "$BACKUP_DIR"

log(){
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"
}

# =============================
# GLOBAL DEPENDENCIES
# =============================

install_if_missing(){
    if ! command -v "$1" >/dev/null 2>&1; then
        dnf install -y "$2" >/dev/null 2>&1
    fi
}

install_if_missing rsync rsync

# [FIX] Verify WP-CLI checksum trước khi cài
if ! command -v wp >/dev/null 2>&1; then
    echo "Installing WP-CLI..."
    curl -sL "https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar" -o /tmp/wp-cli.phar
    curl -sL "https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar.sha512" -o /tmp/wp-cli.phar.sha512

    cd /tmp
    if sha512sum -c wp-cli.phar.sha512 --status 2>/dev/null; then
        chmod +x wp-cli.phar
        mv wp-cli.phar /usr/local/bin/wp
        echo "WP-CLI installed and verified."
    else
        echo "WP-CLI checksum mismatch! Aborting install."
        rm -f /tmp/wp-cli.phar /tmp/wp-cli.phar.sha512
        exit 1
    fi
    cd - >/dev/null
fi

WP_BIN=$(command -v wp || true)
[ -z "$WP_BIN" ] && { echo "WP-CLI not available!"; exit 1; }

# =============================
# LOCK SYSTEM
# =============================

acquire_lock(){
    if ! mkdir "$LOCK_FILE" 2>/dev/null; then
        echo "Another deploy is running. Try again later."
        exit 1
    fi
}

release_lock(){
    rm -rf "$LOCK_FILE"
}

# =============================
# HELPER ENTERPRISE (SAFE)
# =============================

get_wp_cmd(){
    PHP_SHORT=$(echo "$PHP_VERSION" | tr -d '.')
    PHP_BIN="/opt/remi/php${PHP_SHORT}/root/usr/bin/php"
    echo "sudo -u $CLEAN_DOMAIN $PHP_BIN /usr/local/bin/wp"
}

snapshot_files(){
    SNAP="$BACKUP_DIR/${CLEAN_DOMAIN}_files_$(date +%Y%m%d_%H%M%S).tar.gz"
    tar -czf "$SNAP" -C "$DOMAIN_PATH" public_html 2>/dev/null || true
}

# [FIX] Nginx staging an toàn:
#   - HTTP Basic Auth (htpasswd) để block public access
#   - Deny wp-config.php, .env, composer.json
#   - Thêm X-Robots-Tag: noindex để Google không index staging
#   - Dùng fastcgi_params thay vì fastcgi.conf (chuẩn hơn)
#   - Thêm các security header cơ bản
create_nginx_staging(){
    CONF="/etc/nginx/conf.d/${CLEAN_DOMAIN}-staging.conf"
    HTPASSWD_FILE="/etc/nginx/.staging_${CLEAN_DOMAIN}"

    [ -f "$CONF" ] && return

    PHP_SHORT=$(echo "$PHP_VERSION" | tr -d '.')

    # Tạo HTTP Basic Auth
    echo ""
    echo "Set password to protect staging site (HTTP Basic Auth):"
    read -rp "Username [staging]: " STAGING_AUTH_USER </dev/tty
    STAGING_AUTH_USER="${STAGING_AUTH_USER:-staging}"

    read -rsp "Password (blank = auto-generate): " STAGING_AUTH_PASS </dev/tty
    echo ""

    if [ -z "$STAGING_AUTH_PASS" ]; then
        STAGING_AUTH_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
        echo "Auto-generated password: $STAGING_AUTH_PASS"
    fi

    # Cài httpd-tools nếu chưa có
    if ! command -v htpasswd >/dev/null 2>&1; then
        dnf install -y httpd-tools >/dev/null 2>&1
    fi

    htpasswd -cb "$HTPASSWD_FILE" "$STAGING_AUTH_USER" "$STAGING_AUTH_PASS"
    chown root:nginx "$HTPASSWD_FILE"
    chmod 640 "$HTPASSWD_FILE"

    # Lưu thông tin auth vào staging.env để xem lại được
    {
        echo "STAGING_AUTH_USER=$STAGING_AUTH_USER"
        echo "STAGING_AUTH_PASS=$STAGING_AUTH_PASS"
    } >> "$DOMAIN_PATH/config/staging.env"

    cat > "$CONF" <<EOF
server {
    listen 80;
    server_name staging.${SELECTED_DOMAIN};

    root $DOMAIN_PATH/staging;
    index index.php index.html;

    # Không cho Google/bot index staging
    add_header X-Robots-Tag "noindex, nofollow" always;

    # Security headers cơ bản
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;

    # HTTP Basic Auth — block public access
    auth_basic "Staging - Restricted";
    auth_basic_user_file ${HTPASSWD_FILE};

    # Deny các file nhạy cảm
    location ~* /(wp-config\.php|\.env|composer\.json|composer\.lock) {
        deny all;
        return 404;
    }

    location ~ /\.git { deny all; }

    location ~ /\. { deny all; }

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        try_files \$uri =404;

        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_pass unix:/var/opt/remi/php${PHP_SHORT}/run/php-fpm/${CLEAN_DOMAIN}.sock;
        fastcgi_index index.php;
    }

    access_log /var/log/nginx/domains/${CLEAN_DOMAIN}/staging-access.log;
    error_log  /var/log/nginx/domains/${CLEAN_DOMAIN}/staging-error.log;
}
EOF

    if nginx -t; then
        systemctl reload nginx
        log "Staging nginx config created for ${SELECTED_DOMAIN}"
    else
        echo "Nginx config error! Rolling back..."
        rm -f "$CONF" "$HTPASSWD_FILE"
        nginx -t
        return 1
    fi

    echo ""
    echo "========================================"
    echo " Staging Auth Info"
    echo "----------------------------------------"
    echo " URL      : http://staging.${SELECTED_DOMAIN}"
    echo " Username : $STAGING_AUTH_USER"
    echo " Password : $STAGING_AUTH_PASS"
    echo "========================================"
}

# ======================================
# CREATE STAGING
# ======================================

create_staging(){

    select_domain || return

    STAGING_PATH="$DOMAIN_PATH/staging"
    STAGING_ENV="$DOMAIN_PATH/config/staging.env"

    STAGING_DB="${DB_NAME}_staging"
    STAGING_USER="${DB_USER}_stg"
    STAGING_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c16)
    STAGING_URL="staging.${SELECTED_DOMAIN}"

    WP_CMD=$(get_wp_cmd)

    if [ -d "$STAGING_PATH" ]; then
        echo "Staging already exists!"
        return
    fi

    mkdir -p "$STAGING_PATH"
    rsync -a "$ROOT/" "$STAGING_PATH/"

    mysql -e "CREATE DATABASE \`$STAGING_DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    mysql -e "CREATE USER '$STAGING_USER'@'localhost' IDENTIFIED BY '$STAGING_PASS';"
    mysql -e "GRANT ALL PRIVILEGES ON \`$STAGING_DB\`.* TO '$STAGING_USER'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"

    mysqldump "$DB_NAME" | mysql "$STAGING_DB"

    sed -i "s/define(['\"]DB_NAME['\"].*/define('DB_NAME', '$STAGING_DB');/" "$STAGING_PATH/wp-config.php"
    sed -i "s/define(['\"]DB_USER['\"].*/define('DB_USER', '$STAGING_USER');/" "$STAGING_PATH/wp-config.php"
    sed -i "s/define(['\"]DB_PASSWORD['\"].*/define('DB_PASSWORD', '$STAGING_PASS');/" "$STAGING_PATH/wp-config.php"

    # [FIX] Thêm DISALLOW_INDEXING và disable WP cron trên staging
    if ! grep -q "DISALLOW_INDEXING" "$STAGING_PATH/wp-config.php"; then
        sed -i "/\/\* That's all/i define('DISALLOW_INDEXING', true);\ndefine('DISABLE_WP_CRON', true);" \
            "$STAGING_PATH/wp-config.php"
    fi

    $WP_CMD search-replace "$SELECTED_DOMAIN" "$STAGING_URL" \
    --skip-columns=guid --path="$STAGING_PATH" --quiet

    $WP_CMD option update siteurl "http://$STAGING_URL" --path="$STAGING_PATH" --quiet
    $WP_CMD option update home "http://$STAGING_URL" --path="$STAGING_PATH" --quiet

    # [FIX] Disable all emails trên staging để tránh gửi nhầm
    $WP_CMD plugin install disable-emails --activate --path="$STAGING_PATH" --quiet 2>/dev/null || true

    chown -R "$CLEAN_DOMAIN:$CLEAN_DOMAIN" "$STAGING_PATH"

    # Tạo staging.env trước khi gọi create_nginx_staging
    # (create_nginx_staging sẽ append auth info vào file này)
    cat > "$STAGING_ENV" <<EOF
STAGING_DB=$STAGING_DB
STAGING_USER=$STAGING_USER
STAGING_PASS=$STAGING_PASS
STAGING_URL=$STAGING_URL
CREATED="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
    chmod 600 "$STAGING_ENV"

    create_nginx_staging

    log "Staging created for $SELECTED_DOMAIN"
    echo ""
    echo "Staging created successfully!"
}

# ======================================
# DELETE STAGING
# ======================================

delete_staging(){

    select_domain || return

    STAGING_ENV="$DOMAIN_PATH/config/staging.env"
    STAGING_PATH="$DOMAIN_PATH/staging"
    HTPASSWD_FILE="/etc/nginx/.staging_${CLEAN_DOMAIN}"

    [ ! -f "$STAGING_ENV" ] && { echo "No staging found!"; return; }

    STAGING_DB=$(grep "^STAGING_DB=" "$STAGING_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    STAGING_USER=$(grep "^STAGING_USER=" "$STAGING_ENV" | cut -d'=' -f2 | tr -d '[:space:]')

    echo -e "\e[31mWARNING: This will permanently delete the staging environment!\e[0m"
    read -p "Continue? [y/N]: " CONFIRM
    CONFIRM="${CONFIRM:-n}"
    [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && return

    rm -rf "$STAGING_PATH"
    mysql -e "DROP DATABASE IF EXISTS \`$STAGING_DB\`;"
    mysql -e "DROP USER IF EXISTS '$STAGING_USER'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"
    rm -f "$STAGING_ENV"

    # [FIX] Xóa nginx config + htpasswd khi delete staging
    STAGING_CONF="/etc/nginx/conf.d/${CLEAN_DOMAIN}-staging.conf"
    rm -f "$STAGING_CONF" "$HTPASSWD_FILE"

    if nginx -t; then
        systemctl reload nginx
    fi

    log "Staging deleted for $SELECTED_DOMAIN"
    echo "Staging removed completely!"
}

# ======================================
# SYNC MENU
# ======================================

sync_menu(){

    select_domain || return

    STAGING_ENV="$DOMAIN_PATH/config/staging.env"
    STAGING_PATH="$DOMAIN_PATH/staging"

    [ ! -f "$STAGING_ENV" ] && { echo "No staging configuration found!"; return; }
    [ ! -d "$STAGING_PATH" ] && { echo "Staging folder not found!"; return; }

    STAGING_DB=$(grep "^STAGING_DB=" "$STAGING_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    STAGING_USER=$(grep "^STAGING_USER=" "$STAGING_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    STAGING_PASS=$(grep "^STAGING_PASS=" "$STAGING_ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    STAGING_URL=$(grep "^STAGING_URL=" "$STAGING_ENV" | cut -d'=' -f2- | tr -d '[:space:]')

    WP_CMD=$(get_wp_cmd)

    echo ""
    echo "1) Sync DB → Live"
    echo "2) Sync DB → Staging"
    echo "3) Sync Plugins + Themes"
    echo "4) Sync Uploads"
    echo "5) Full Deploy (Staging → Live)"
    echo "0) Back"
    read -p "Select: " opt

    case $opt in

    5)
        acquire_lock

        snapshot_files

        BACKUP="$BACKUP_DIR/${DB_NAME}_before_full_$(date +%Y%m%d_%H%M%S).sql"
        mysqldump "$DB_NAME" > "$BACKUP"

        $WP_CMD maintenance-mode activate --path="$ROOT" || true

        if rsync -a --delete --exclude="wp-config.php" "$STAGING_PATH/" "$ROOT/" &&
           mysqldump "$STAGING_DB" | mysql "$DB_NAME"; then

            $WP_CMD search-replace "$STAGING_URL" "$SELECTED_DOMAIN" \
            --skip-columns=guid --path="$ROOT" --quiet

            $WP_CMD cache flush --path="$ROOT" --quiet
            redis-cli -h 127.0.0.1 FLUSHALL >/dev/null 2>&1 || true

            echo "Deploy success."
            log "Full deploy success: $SELECTED_DOMAIN"
        else
            echo "Deploy failed. Rolling back..."
            mysql "$DB_NAME" < "$BACKUP"
            echo "Rollback completed."
            log "Deploy failed, rollback executed: $SELECTED_DOMAIN"
        fi

        $WP_CMD maintenance-mode deactivate --path="$ROOT" || true
        chown -R "$CLEAN_DOMAIN:$CLEAN_DOMAIN" "$ROOT"

        release_lock
        ;;

    1)
        BACKUP="$BACKUP_DIR/${DB_NAME}_before_sync_$(date +%Y%m%d_%H%M%S).sql"
        mysqldump "$DB_NAME" > "$BACKUP"
        mysqldump "$STAGING_DB" | mysql "$DB_NAME"
        $WP_CMD cache flush --path="$ROOT" --quiet
        redis-cli -h 127.0.0.1 FLUSHALL >/dev/null 2>&1 || true
        echo "DB synced to live."
        ;;

    2)
        mysqldump "$DB_NAME" | mysql "$STAGING_DB"
        echo "DB synced to staging."
        ;;

    3)
        rsync -a "$STAGING_PATH/wp-content/plugins/" "$ROOT/wp-content/plugins/"
        rsync -a "$STAGING_PATH/wp-content/themes/" "$ROOT/wp-content/themes/"
        echo "Plugins + Themes synced."
        ;;

    4)
        rsync -a "$STAGING_PATH/wp-content/uploads/" "$ROOT/wp-content/uploads/"
        echo "Uploads synced."
        ;;

    0) return ;;
    *) echo "Invalid option" ;;
    esac
}

# ======================================
# MAIN MENU
# ======================================

while true; do
clear
echo "========================================"
echo "         STAGING MANAGER"
echo "========================================"
echo "1) Create Staging"
echo "2) Sync Tools"
echo "3) Delete Staging"
echo "0) Back"
echo "----------------------------------------"

read -p "Select: " choice

case $choice in
1) create_staging; read -p "Press Enter..." ;;
2) sync_menu; read -p "Press Enter..." ;;
3) delete_staging; read -p "Press Enter..." ;;
0) break ;;
*) echo "Invalid option"; sleep 1 ;;
esac

done
