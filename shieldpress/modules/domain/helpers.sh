#!/bin/bash

BASE_DIR="${BASE_DIR:-/opt/shieldpress}"
source "$BASE_DIR/core/paths.sh"

LOG_FILE="$LOG_DIR/domain.log"
SLOW_LOG_DIR="$LOG_DIR_PHP_SLOW"
DEFAULT_PHP_VERSION="8.4"
mkdir -p "$LOG_DIR" "$SLOW_LOG_DIR"

log(){  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"; }
ok(){   echo "[OK] $1";   log "[OK] $1"; }
fail(){ echo "[FAIL] $1"; log "[FAIL] $1"; }
warn(){ echo "[WARN] $1"; log "[WARN] $1"; }

if [ -f "$BASE_DIR/modules/helpers/nodejs-runtime.sh" ]; then
    source "$BASE_DIR/modules/helpers/nodejs-runtime.sh"
fi

php_version_to_short(){
    echo "$1" | tr -d '.'
}

postgresql_ready(){
    command -v psql >/dev/null 2>&1 &&
        systemctl is-active --quiet postgresql &&
        [ -f /var/lib/pgsql/data/PG_VERSION ]
}

ensure_php_version_installed(){
    local version="$1"
    local version_short
    local package_name
    local service_name
    local opcache_ini
    local pool_conf
    local php_fpm_bin
    local total_ram
    local pm_max_children

    version_short=$(php_version_to_short "$version")
    package_name="php${version_short}-php-fpm"
    service_name="php${version_short}-php-fpm"

    if rpm -q "$package_name" >/dev/null 2>&1 && [ -d "/etc/opt/remi/php${version_short}" ]; then
        systemctl enable "$service_name" >/dev/null 2>&1 || true
        systemctl restart "$service_name" >/dev/null 2>&1 || true
        return 0
    fi

    echo "[INFO] PHP ${version} is not installed. Installing now..."

    dnf install -y \
        "php${version_short}" \
        "php${version_short}-php-fpm" \
        "php${version_short}-php-mysqlnd" \
        "php${version_short}-php-pgsql" \
        "php${version_short}-php-opcache" \
        "php${version_short}-php-gd" \
        "php${version_short}-php-curl" \
        "php${version_short}-php-zip" \
        "php${version_short}-php-cli" \
        "php${version_short}-php-mbstring" \
        "php${version_short}-php-xml" \
        "php${version_short}-php-intl" \
        "php${version_short}-php-bcmath" || return 1

    if dnf install -y "php${version_short}-php-pecl-imagick" --enablerepo=remi >/dev/null 2>&1; then
        :
    elif dnf install -y "php${version_short}-php-pecl-imagick-im6" --enablerepo=remi >/dev/null 2>&1; then
        :
    else
        warn "PHP ${version} imagick not available, skipping"
    fi

    systemctl enable "$service_name" >/dev/null 2>&1 || return 1

    opcache_ini="/etc/opt/remi/php${version_short}/php.d/10-opcache.ini"
    if [ -f "$opcache_ini" ]; then
        sed -i '/^opcache\.memory_consumption/d'     "$opcache_ini"
        sed -i '/^opcache\.max_accelerated_files/d'  "$opcache_ini"
        sed -i '/^opcache\.validate_timestamps/d'    "$opcache_ini"
        sed -i '/^opcache\.revalidate_freq/d'        "$opcache_ini"
        sed -i '/^opcache\.jit_buffer_size/d'        "$opcache_ini"
        sed -i '/^opcache\.jit=/d'                   "$opcache_ini"
        sed -i '/^opcache\.enable=/d'                "$opcache_ini"

        cat >> "$opcache_ini" <<EOF
opcache.enable=1
opcache.memory_consumption=256
opcache.max_accelerated_files=100000
opcache.validate_timestamps=1
opcache.revalidate_freq=2
opcache.jit_buffer_size=128M
opcache.jit=1255
EOF
    fi

    pool_conf="/etc/opt/remi/php${version_short}/php-fpm.d/www.conf"
    total_ram=$(free -m | awk '/Mem:/ {print $2}')
    pm_max_children=$((total_ram / 50))
    [ "$pm_max_children" -lt 5 ] && pm_max_children=5
    [ "$pm_max_children" -gt 100 ] && pm_max_children=100

    mkdir -p "/var/opt/remi/php${version_short}/run/php-fpm"

    cat > "$pool_conf" <<EOF
[www]
user = nginx
group = nginx
listen = /var/opt/remi/php${version_short}/run/php-fpm/www.sock
listen.owner = nginx
listen.group = nginx
listen.mode = 0660

pm = ondemand
pm.max_children = ${pm_max_children}
pm.process_idle_timeout = 10s
pm.max_requests = 500

chdir = /
EOF

    if command -v setsebool >/dev/null 2>&1; then
        setsebool -P httpd_execmem 1 2>/dev/null || true
    fi

    if command -v semanage >/dev/null 2>&1; then
        semanage permissive -a httpd_t 2>/dev/null || true
    fi

    php_fpm_bin="/opt/remi/php${version_short}/root/usr/sbin/php-fpm"
    if [ -x "$php_fpm_bin" ] && "$php_fpm_bin" -t 2>&1 | grep -q "ERROR"; then
        "$php_fpm_bin" -t 2>&1
        return 1
    fi

    systemctl restart "$service_name" >/dev/null 2>&1 || return 1
    ok "PHP ${version} installed"
    return 0
}

# ===============================
# CLEAN DOMAIN NAME
# ===============================

clean_domain_name(){
    echo "$1" | sed 's/[^a-zA-Z0-9]/_/g' | cut -c1-30
}

# ===============================
# SELECT DOMAIN - đọc thẳng từ file, không source
# ===============================

select_domain(){
    local _PATHS=()
    local _NAMES=()

    echo ""
    echo "Available Domains:"
    echo "--------------------------------"

    local i=1
    for d in "$DOMAINS_ROOT"/*/; do
        [ -d "$d" ] || continue
        [ -f "$d/config/domain.env" ] || continue
        local DN
        DN=$(grep "^DOMAIN=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
        [ -z "$DN" ] && continue
        echo "$i) $DN"
        _PATHS[$i]="$d"
        ((i++))
    done

    [ $i -eq 1 ] && { echo "No domains found."; return 1; }

    echo "--------------------------------"
    read -p "Select domain number: " choice

    DOMAIN_PATH="${_PATHS[$choice]}"
    [ -z "$DOMAIN_PATH" ] && { echo "Invalid selection"; return 1; }

    local ENV="$DOMAIN_PATH/config/domain.env"
    DOMAIN=$(grep      "^DOMAIN="      "$ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    SYSTEM_USER=$(grep "^SYSTEM_USER=" "$ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    DB_NAME=$(grep     "^DB_NAME="     "$ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    DB_USER=$(grep     "^DB_USER="     "$ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    DB_PASS=$(grep     "^DB_PASS="     "$ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    DB_CONNECTION=$(grep "^DB_CONNECTION=" "$ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    APP_TYPE=$(grep    "^APP_TYPE="    "$ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    ROOT=$(grep        "^ROOT="        "$ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    PHP_VERSION=$(grep "^PHP_VERSION=" "$ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    SSL=$(grep         "^SSL="         "$ENV" | cut -d'=' -f2 | tr -d '[:space:]')
    DB_CONNECTION="${DB_CONNECTION:-mysql}"
    APP_TYPE="${APP_TYPE:-wordpress}"
    ROOT="${ROOT:-$DOMAIN_PATH/public_html}"

    SELECTED_DOMAIN="$DOMAIN"
    CLEAN_DOMAIN=$(clean_domain_name "$DOMAIN")
    PHP_SHORT=$(echo "$PHP_VERSION" | tr -d '.')
    return 0
}

find_free_node_port(){
    local port
    for port in $(seq 3000 3999); do
        ss -tuln 2>/dev/null | grep -q ":${port} " || {
            echo "$port"
            return 0
        }
    done

    return 1
}

# ===============================
# SELECT PHP VERSION
# ===============================

select_php_version(){
    echo "Select PHP version:"
    echo "1) PHP 8.1"
    echo "2) PHP 8.2"
    echo "3) PHP 8.3"
    echo "4) PHP 8.4"
    read -p "Choose [4]: " opt
    opt="${opt:-4}"

    case $opt in
        1) PHP_VERSION="8.1" ;;
        2) PHP_VERSION="8.2" ;;
        3) PHP_VERSION="8.3" ;;
        4) PHP_VERSION="8.4" ;;
        *) echo "Invalid option"; return 1 ;;
    esac

    PHP_SHORT=$(php_version_to_short "$PHP_VERSION")
    return 0
}

# ===============================
# CREATE LINUX USER
# ===============================

create_linux_user(){
    local C="$CLEAN_DOMAIN"
    local DOMAIN_HOME="$DOMAIN_PATH"

    if id "$C" &>/dev/null; then
        DOMAIN_USER_CREATED=0
        echo "[INFO] Reusing existing user: $C"

        # ===== CHECK HOME DIR =====
        EXIST_HOME=$(getent passwd "$C" | cut -d: -f6)

        if [ "$EXIST_HOME" != "$DOMAIN_HOME" ]; then
            warn "User home mismatch ($EXIST_HOME → $DOMAIN_HOME) → fixing"
            usermod -d "$DOMAIN_HOME" "$C"
        fi

    else
        useradd -m -d "$DOMAIN_HOME" -s /sbin/nologin "$C"
        DOMAIN_USER_CREATED=1
        ok "Linux user created: $C"
    fi
}

# ===============================
# CREATE DIRECTORY STRUCTURE
# ===============================

create_directory_structure(){

    # ===== DOMAIN STRUCTURE =====
    mkdir -p "$DOMAIN_PATH"/{public_html,backup/db,backup/files,backup/full,config,logs,tmp/sessions} || return 1

    chown -R "$CLEAN_DOMAIN:$CLEAN_DOMAIN" "$DOMAIN_PATH" || return 1
    chmod 755 "$DOMAIN_PATH" || return 1
    chmod 755 "$DOMAIN_PATH/public_html" || return 1
    chmod 750 "$DOMAIN_PATH/backup" || return 1

    # config/ chỉ root đọc được — chứa domain.env với DB_PASS, SFTP_PASS
    chown root:root "$DOMAIN_PATH/config"
    chmod 700 "$DOMAIN_PATH/config"

    # tmp + sessions (quan trọng cho PHP)
    chmod -R 755 "$DOMAIN_PATH/tmp" || return 1
    chmod -R 700 "$DOMAIN_PATH/tmp/sessions" || return 1

    # ===== PER-DOMAIN LOGS (nginx access/error) =====
    local DOMAIN_LOG_DIR="$DOMAIN_PATH/logs"
    chown nginx:nginx "$DOMAIN_LOG_DIR"
    chmod 755 "$DOMAIN_LOG_DIR"

    # Backward compat symlink: /var/log/nginx/domains/{domain} → /home/domains/{domain}/logs
    mkdir -p /var/log/nginx/domains 2>/dev/null
    if [ ! -L "/var/log/nginx/domains/$CLEAN_DOMAIN" ]; then
        rm -rf "/var/log/nginx/domains/$CLEAN_DOMAIN" 2>/dev/null
        ln -sfn "$DOMAIN_LOG_DIR" "/var/log/nginx/domains/$CLEAN_DOMAIN"
    fi

    # ===== GLOBAL LOGS =====
    mkdir -p "$LOG_DIR_PHP_SLOW"

    SLOWLOG="$LOG_DIR_PHP_SLOW/${CLEAN_DOMAIN}-slow.log"

    [ ! -f "$SLOWLOG" ] && touch "$SLOWLOG"

    chown nginx:nginx "$SLOWLOG"
    chmod 644 "$SLOWLOG"

    # đảm bảo folder logs OK
    chown -R nginx:nginx "$LOG_DIR"
    chmod -R 755 "$LOG_DIR"
}

# ===============================
# CREATE DATABASE
# ===============================

create_database(){
    local db_check user_check mysql_error
    DB_NAME="${CLEAN_DOMAIN}_db"
    DB_USER="${CLEAN_DOMAIN}_user"
    DB_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)
    DB_CONNECTION="${DB_CONNECTION:-mysql}"
    local SP_DATA_DIR="$DATA_DIR"
    local DATA_FILE="$SP_DATA_DIR/databases.list"

    [ "${#DB_PASS}" -ge 16 ] || { fail "Unable to generate MySQL password"; return 1; }
    if grep -q "^DB_NAME=$DB_NAME[[:space:]]*|" "$DATA_FILE" 2>/dev/null; then
        fail "MySQL database is already tracked: $DB_NAME"
        return 1
    fi

    db_check=$(mysql -N -B -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='$DB_NAME';" 2>&1) || {
        fail "Unable to check MySQL database: $db_check"
        return 1
    }
    user_check=$(mysql -N -B -e "SELECT User FROM mysql.user WHERE User='$DB_USER' AND Host='localhost';" 2>&1) || {
        fail "Unable to check MySQL user: $user_check"
        return 1
    }
    [ -n "$db_check" ] && { fail "MySQL database already exists: $DB_NAME"; return 1; }
    [ -n "$user_check" ] && { fail "MySQL user already exists: $DB_USER"; return 1; }

    if ! mysql_error=$(mysql -e "CREATE DATABASE \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>&1); then
        fail "MySQL database creation failed: $mysql_error"
        return 1
    fi
    if ! mysql_error=$(mysql -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';" 2>&1); then
        mysql -e "DROP DATABASE IF EXISTS \`$DB_NAME\`;" 2>/dev/null
        fail "MySQL user creation failed: $mysql_error"
        return 1
    fi
    if ! mysql_error=$(mysql -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost'; FLUSH PRIVILEGES;" 2>&1); then
        mysql -e "DROP USER IF EXISTS '$DB_USER'@'localhost'; DROP DATABASE IF EXISTS \`$DB_NAME\`;" 2>/dev/null
        fail "Granting MySQL privileges failed: $mysql_error"
        return 1
    fi

    mkdir -p "$SP_DATA_DIR" || {
        mysql -e "DROP USER IF EXISTS '$DB_USER'@'localhost'; DROP DATABASE IF EXISTS \`$DB_NAME\`;" 2>/dev/null
        fail "Unable to create MySQL metadata directory"
        return 1
    }
    if ! printf 'DB_NAME=%s | DB_USER=%s | DB_PASS=%s | DOMAIN=%s | CREATED=%s\n' \
        "$DB_NAME" "$DB_USER" "$DB_PASS" "$DOMAIN" "$(date '+%Y-%m-%d %H:%M:%S')" >> "$DATA_FILE"; then
        mysql -e "DROP USER IF EXISTS '$DB_USER'@'localhost'; DROP DATABASE IF EXISTS \`$DB_NAME\`;" 2>/dev/null
        fail "Unable to save MySQL metadata"
        return 1
    fi
    if ! chmod 600 "$DATA_FILE"; then
        sed -i "/^DB_NAME=$DB_NAME[[:space:]]*|/d" "$DATA_FILE" 2>/dev/null
        mysql -e "DROP USER IF EXISTS '$DB_USER'@'localhost'; DROP DATABASE IF EXISTS \`$DB_NAME\`;" 2>/dev/null
        fail "Unable to secure MySQL metadata"
        return 1
    fi
}

create_postgresql_database(){
    local role_check db_check pg_error
    DB_NAME="${CLEAN_DOMAIN}_db"
    DB_USER="${CLEAN_DOMAIN}_user"
    DB_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
    DB_CONNECTION="pgsql"
    local pg_hba="/var/lib/pgsql/data/pg_hba.conf"
    local laravel_db_dir="$DATA_DIR_LARAVEL_DB"
    local db_meta="$laravel_db_dir/${DB_NAME}.env"

    [ "${#DB_PASS}" -eq 24 ] || { fail "Unable to generate PostgreSQL password"; return 1; }

    systemctl enable postgresql >/dev/null 2>&1 || true
    systemctl start postgresql >/dev/null 2>&1 || return 1

    if [ -f "$pg_hba" ] && ! grep -q "ShieldPress PostgreSQL auth" "$pg_hba"; then
        {
            echo "# ShieldPress PostgreSQL auth"
            echo "host all all 127.0.0.1/32 scram-sha-256"
            echo "host all all ::1/128 scram-sha-256"
            cat "$pg_hba"
        } > "${pg_hba}.tmp"
        mv "${pg_hba}.tmp" "$pg_hba"
        chown postgres:postgres "$pg_hba"
        systemctl reload postgresql >/dev/null 2>&1 || systemctl restart postgresql >/dev/null 2>&1 || true
    fi

    role_check=$(runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" 2>&1) || {
        fail "Unable to check PostgreSQL role: $role_check"
        return 1
    }
    db_check=$(runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" 2>&1) || {
        fail "Unable to check PostgreSQL database: $db_check"
        return 1
    }
    [ "$role_check" = "1" ] && { fail "PostgreSQL role already exists: $DB_USER"; return 1; }
    [ "$db_check" = "1" ] && { fail "PostgreSQL database already exists: $DB_NAME"; return 1; }

    if ! pg_error=$(runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "SET password_encryption = 'scram-sha-256'; CREATE USER \"${DB_USER}\" WITH PASSWORD '${DB_PASS}';" 2>&1); then
        fail "PostgreSQL role creation failed: $pg_error"
        return 1
    fi
    if ! pg_error=$(runuser -u postgres -- createdb -O "$DB_USER" "$DB_NAME" 2>&1); then
        runuser -u postgres -- dropuser --if-exists "$DB_USER" >/dev/null 2>&1
        fail "PostgreSQL database creation failed: $pg_error"
        return 1
    fi

    mkdir -p "$laravel_db_dir" || {
        runuser -u postgres -- dropdb --if-exists "$DB_NAME" >/dev/null 2>&1
        runuser -u postgres -- dropuser --if-exists "$DB_USER" >/dev/null 2>&1
        fail "Unable to create PostgreSQL metadata directory"
        return 1
    }
    if ! cat > "$db_meta" <<EOF
DB_CONNECTION=pgsql
DB_HOST=127.0.0.1
DB_PORT=5432
DB_DATABASE=$DB_NAME
DB_USERNAME=$DB_USER
DB_PASSWORD=$DB_PASS
DOMAIN=$DOMAIN
CREATED=$(date '+%Y-%m-%d %H:%M:%S')
EOF
    then
        runuser -u postgres -- dropdb --if-exists "$DB_NAME" >/dev/null 2>&1
        runuser -u postgres -- dropuser --if-exists "$DB_USER" >/dev/null 2>&1
        fail "Unable to save PostgreSQL metadata"
        return 1
    fi
    if ! chmod 600 "$db_meta"; then
        rm -f "$db_meta"
        runuser -u postgres -- dropdb --if-exists "$DB_NAME" >/dev/null 2>&1
        runuser -u postgres -- dropuser --if-exists "$DB_USER" >/dev/null 2>&1
        fail "Unable to secure PostgreSQL metadata"
        return 1
    fi
}

# ===============================
# CREATE PHP POOL (pm=ondemand)
# ===============================

create_php_pool(){
    local POOL_DIR="/etc/opt/remi/php${PHP_SHORT}/php-fpm.d"
    PHP_SOCKET="/var/opt/remi/php${PHP_SHORT}/run/php-fpm/${CLEAN_DOMAIN}.sock"
    local PHP_SVC="php${PHP_SHORT}-php-fpm"

    ensure_php_version_installed "$PHP_VERSION" || return 1

    mkdir -p "/var/opt/remi/php${PHP_SHORT}/run/php-fpm"
    mkdir -p "$SLOW_LOG_DIR"

    local TOTAL_RAM PHP_MAX
    TOTAL_RAM=$(free -m | awk '/Mem:/ {print $2}')
    PHP_MAX=$((TOTAL_RAM / 50))
    [ "$PHP_MAX" -lt 5  ] && PHP_MAX=5
    [ "$PHP_MAX" -gt 50 ] && PHP_MAX=50

    cat > "$POOL_DIR/${CLEAN_DOMAIN}.conf" << POOL
[$CLEAN_DOMAIN]
user  = $CLEAN_DOMAIN
group = $CLEAN_DOMAIN
listen       = $PHP_SOCKET
listen.owner = nginx
listen.group = nginx
listen.mode  = 0660

pm = ondemand
pm.max_children         = $PHP_MAX
pm.process_idle_timeout = 10s
pm.max_requests         = 500

; Kill process treo sau 300s - tránh zombie ăn RAM
request_terminate_timeout = 300

; Slow log - log request chậm hơn 5s để debug
slowlog = ${SLOW_LOG_DIR}/${CLEAN_DOMAIN}-slow.log
request_slowlog_timeout = 5

chdir = /

; ---- PHP VALUES (tối ưu cho WordPress nặng) ----
php_admin_value[memory_limit]        = 1024M
php_admin_value[upload_max_filesize] = 1024M
php_admin_value[post_max_size]       = 1024M
php_admin_value[max_execution_time]  = 300
php_admin_value[max_input_vars]      = 10000
php_admin_value[max_input_time]      = 300

; ---- PERFORMANCE ----
; Cache đường dẫn file - giảm stat() calls cho site nhiều file/plugin
php_admin_value[realpath_cache_size] = 4096K
php_admin_value[realpath_cache_ttl]  = 600

php_admin_value[open_basedir]        = $DOMAIN_PATH:$DOMAIN_PATH/tmp:/usr/share/php
php_admin_value[upload_tmp_dir]      = $DOMAIN_PATH/tmp
php_admin_value[sys_temp_dir]        = $DOMAIN_PATH/tmp
php_admin_value[temp_dir]            = $DOMAIN_PATH/tmp
php_admin_value[session.save_path]   = $DOMAIN_PATH/tmp/sessions

; Tắt các hàm nguy hiểm hay dùng trong webshell/malware
php_admin_value[disable_functions]   = exec,passthru,shell_exec,system,proc_open,popen,pcntl_exec
POOL

    # Tạo thư mục tmp riêng cho domain
    mkdir -p "$DOMAIN_PATH/tmp/sessions" || exit 1

    chmod 700 "$DOMAIN_PATH/tmp"
    chmod 700 "$DOMAIN_PATH/tmp/sessions"

    chown -R "$CLEAN_DOMAIN:$CLEAN_DOMAIN" "$DOMAIN_PATH/tmp"

    # SELinux
    if command -v semanage &>/dev/null; then
        semanage fcontext -a -t httpd_sys_rw_content_t "$DOMAIN_PATH/tmp(/.*)?"
        restorecon -Rv $DOMAIN_PATH/tmp
    fi

    systemctl restart "$PHP_SVC" 2>/dev/null
    sleep 1
}

# ===============================
# CREATE NGINX CONFIG
# ===============================

create_nginx_config(){
    PHP_SOCKET="/var/opt/remi/php${PHP_SHORT}/run/php-fpm/${CLEAN_DOMAIN}.sock"
    NGINX_CONF="/etc/nginx/conf.d/${CLEAN_DOMAIN}.conf"

    # --- Per-domain FastCGI cache ---
    local CACHE_DIR="/var/cache/nginx/${CLEAN_DOMAIN}"
    local CACHE_ZONE="SHIELDPRESS_${CLEAN_DOMAIN}"
    local CACHE_ZONE_CONF="/etc/nginx/conf.d/cache-zone-${CLEAN_DOMAIN}.conf"

    # Tạo thư mục cache riêng cho domain
    mkdir -p "$CACHE_DIR"
    chown nginx:nginx "$CACHE_DIR"
    chmod 755 "$CACHE_DIR"

    # Tính max_size theo RAM
    local TOTAL_RAM CACHE_MAX
    TOTAL_RAM=$(free -m | awk '/Mem:/ {print $2}')
    CACHE_MAX=$((TOTAL_RAM / 4))
    [ "$CACHE_MAX" -lt 512  ] && CACHE_MAX=512
    [ "$CACHE_MAX" -gt 2048 ] && CACHE_MAX=2048

    # Tạo cache zone riêng cho domain
    cat > "$CACHE_ZONE_CONF" << ZEOF
# Cache zone for: $DOMAIN
fastcgi_cache_path ${CACHE_DIR} levels=1:2 keys_zone=${CACHE_ZONE}:10m inactive=60m max_size=${CACHE_MAX}m;
ZEOF

cat > "$NGINX_CONF" << NGEOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;

    root  $DOMAIN_PATH/public_html;
    index index.php index.html;

    access_log $DOMAIN_PATH/logs/access.log;
    error_log  $DOMAIN_PATH/logs/error.log;


    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";

    client_max_body_size 1024M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        try_files \$uri =404;

        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;

        fastcgi_pass  unix:$PHP_SOCKET;
        fastcgi_index index.php;

        fastcgi_connect_timeout 300;
        fastcgi_send_timeout    300;
        fastcgi_read_timeout    300;

        fastcgi_buffers     32 32k;
        fastcgi_buffer_size 64k;

        # =========================
        # SKIP CACHE
        # =========================
        set \$skip_cache 0;

        if (\$request_method = POST) { set \$skip_cache 1; }

        # search / filter / biến thể
        if (\$query_string != "") { set \$skip_cache 1; }

        if (\$request_uri ~* "/wp-admin/") { set \$skip_cache 1; }
        if (\$request_uri ~* "/wp-login.php") { set \$skip_cache 1; }

        # user + session (QUAN TRỌNG)
        if (\$http_cookie ~* "wordpress_logged_in") { set \$skip_cache 1; }
        if (\$http_cookie ~* "woocommerce_items_in_cart") { set \$skip_cache 1; }
        if (\$http_cookie ~* "wp-postpass") { set \$skip_cache 1; }

        # =========================
        # CACHE
        # =========================
        fastcgi_cache_bypass \$skip_cache;
        fastcgi_no_cache     \$skip_cache;

        fastcgi_cache        ${CACHE_ZONE};
        fastcgi_cache_key    "\$scheme\$request_method\$host\$request_uri";

        fastcgi_cache_valid  200 301 302 6h;

        fastcgi_cache_use_stale updating;
        fastcgi_cache_background_update on;

        fastcgi_cache_lock on;
        fastcgi_cache_lock_timeout 10s;
        add_header X-Powered-By "ShieldPress VPS" always;
        add_header X-Cache \$upstream_cache_status;
    }

    location ~ /\.                                    { deny all; }
    location ~* /(wp-config\.php|\.env|composer\.json) { deny all; }
    location ~ /\.git                                 { deny all; }

    location ~* \.(jpg|jpeg|png|gif|webp|css|js|svg|woff|woff2|ttf|ico)\$ {
        expires 30d;
        access_log off;
        add_header Cache-Control "public, immutable";
    }

    location = /robots.txt {
        allow all;
        log_not_found off;
        access_log off;
    }
}
NGEOF

    if nginx -t 2>/dev/null; then
        systemctl reload nginx
    else
        fail "Nginx config error! Rolling back..."
        nginx -t
        rollback_domain
        return 1
    fi
}

# ===============================
# CREATE LARAVEL NGINX CONFIG
# ===============================

create_laravel_nginx_config(){
    PHP_SOCKET="/var/opt/remi/php${PHP_SHORT}/run/php-fpm/${CLEAN_DOMAIN}.sock"
    NGINX_CONF="/etc/nginx/conf.d/${CLEAN_DOMAIN}.conf"
    LARAVEL_PUBLIC="$DOMAIN_PATH/public_html/public"

    mkdir -p "$LARAVEL_PUBLIC"

cat > "$NGINX_CONF" << NGEOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;

    root $LARAVEL_PUBLIC;
    index index.php;

    access_log $DOMAIN_PATH/logs/access.log;
    error_log  $DOMAIN_PATH/logs/error.log;

    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;

    client_max_body_size 1024M;
    client_body_timeout 300s;
    client_header_timeout 60s;
    send_timeout 300s;
    keepalive_timeout 65s;

    location ^~ /media-file/ {
        try_files \$uri /index.php?\$query_string;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        try_files \$uri =404;

        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT \$realpath_root;

        fastcgi_pass unix:$PHP_SOCKET;
        fastcgi_index index.php;
        fastcgi_param HTTPS \$https if_not_empty;
        fastcgi_param HTTP_PROXY "";

        fastcgi_connect_timeout 300;
        fastcgi_send_timeout    300;
        fastcgi_read_timeout    300;
        fastcgi_buffer_size 32k;
        fastcgi_buffers 16 16k;
        fastcgi_busy_buffers_size 64k;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }

    location ~* /(composer\.json|composer\.lock|package\.json|package-lock\.json|vite\.config\..*|artisan|\.env|phpunit\.xml|server\.php) {
        deny all;
    }

    location ~* ^/(app|bootstrap/cache|config|database|resources|routes|storage|tests|vendor)/ {
        deny all;
    }

    location = /favicon.ico {
        access_log off;
        log_not_found off;
    }

    location = /robots.txt {
        access_log off;
        log_not_found off;
    }

    location ~* \.(jpg|jpeg|png|gif|webp|avif|css|js|mjs|map|svg|woff|woff2|ttf|eot|ico)\$ {
        expires 30d;
        access_log off;
        add_header Cache-Control "public, immutable";
    }
}
NGEOF

    if nginx -t 2>/dev/null; then
        systemctl reload nginx
    else
        fail "Nginx config error! Rolling back..."
        nginx -t
        rollback_domain
        return 1
    fi
}

# ===============================
# CREATE NODE.JS NGINX CONFIG
# ===============================

create_nodejs_nginx_config(){
    NGINX_CONF="/etc/nginx/conf.d/${CLEAN_DOMAIN}.conf"
    NODE_APP_PORT="${NODE_APP_PORT:-$(find_free_node_port)}"

    if ! [[ "$NODE_APP_PORT" =~ ^[0-9]+$ ]] || [ "$NODE_APP_PORT" -lt 1 ] || [ "$NODE_APP_PORT" -gt 65535 ]; then
        fail "Invalid Node.js app port"
        return 1
    fi

cat > "$NGINX_CONF" << NGEOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;

    access_log $DOMAIN_PATH/logs/access.log;
    error_log  $DOMAIN_PATH/logs/error.log;

    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;

    client_max_body_size 1024M;
    client_body_timeout 300s;
    client_header_timeout 60s;
    send_timeout 300s;
    keepalive_timeout 65s;

    location / {
        proxy_pass http://127.0.0.1:${NODE_APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_set_header X-Forwarded-Server \$host;
        proxy_cache_bypass \$http_upgrade;

        proxy_connect_timeout 60s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_redirect off;
        proxy_max_temp_file_size 0;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }

    location ~* /(package\.json|package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|\.env|\.git|\.svn) {
        deny all;
    }
}
NGEOF

    if nginx -t 2>/dev/null; then
        systemctl reload nginx
    else
        fail "Nginx config error! Rolling back..."
        nginx -t
        rollback_domain
        return 1
    fi
}

create_nodejs_service(){
    NODE_APP_PORT="${NODE_APP_PORT:-$(find_free_node_port)}"
    NODE_ENTRY="${NODE_ENTRY:-app.js}"

    if ! command -v node >/dev/null 2>&1 && declare -F install_shieldpress_nodejs >/dev/null 2>&1; then
        install_shieldpress_nodejs || true
    fi

    if ! command -v node >/dev/null 2>&1; then
        fail "Node.js is not installed"
        return 1
    fi

    # Install PM2 if not present
    if ! command -v pm2 >/dev/null 2>&1; then
        npm install -g pm2 || { fail "Failed to install PM2"; return 1; }
        pm2 startup 2>/dev/null || true
    fi

    mkdir -p "$DOMAIN_PATH/public_html"

    if [ ! -f "$DOMAIN_PATH/public_html/$NODE_ENTRY" ]; then
        cat > "$DOMAIN_PATH/public_html/$NODE_ENTRY" <<EOF
const http = require('http');

const port = Number(process.env.PORT || ${NODE_APP_PORT});

http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
  res.end('Node.js app is ready for ${DOMAIN}\\n');
}).listen(port, '127.0.0.1');
EOF
    fi

    chown -R "$CLEAN_DOMAIN:$CLEAN_DOMAIN" "$DOMAIN_PATH/public_html"

    local pm2_name="$CLEAN_DOMAIN"
    pm2 delete "$pm2_name" 2>/dev/null || true
    cd "$DOMAIN_PATH/public_html" || return 1
    PORT=${NODE_APP_PORT} pm2 start npm --name "$pm2_name" -- start 2>/dev/null || \
    PORT=${NODE_APP_PORT} pm2 start "$NODE_ENTRY" --name "$pm2_name" || return 1
    pm2 save || true
}

# ===============================
# CREATE DOMAIN ENV
# ===============================

create_domain_env(){
    APP_TYPE="${APP_TYPE:-wordpress}"
    DB_CONNECTION="${DB_CONNECTION:-mysql}"
    ROOT="${ROOT:-$DOMAIN_PATH/public_html}"

    cat > "$DOMAIN_PATH/config/domain.env" << EOF
DOMAIN=$DOMAIN
CLEAN_DOMAIN=$CLEAN_DOMAIN
SYSTEM_USER=$CLEAN_DOMAIN
APP_TYPE=$APP_TYPE
ROOT=$ROOT
DB_CONNECTION=$DB_CONNECTION
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASS=$DB_PASS
PHP_VERSION=$PHP_VERSION
NODE_APP_PORT=${NODE_APP_PORT:-}
NODE_ENTRY=${NODE_ENTRY:-}
SSL=disabled
CREATED=$(date '+%Y-%m-%d')
EOF
    # Chỉ root đọc được — file chứa DB password
    chown root:root "$DOMAIN_PATH/config/domain.env"
    chmod 600 "$DOMAIN_PATH/config/domain.env"
}

# ===============================
# CREATE BACKUP ENV (per-domain)
# ===============================

create_backup_env(){
    local BENV="$DOMAIN_PATH/config/backup.env"

    # Don't overwrite if exists
    [ -f "$BENV" ] && return 0

    local BK_PATHS=""
    local BK_EXCLUDE=""
    local BK_INCR_EXCLUDE=""

    case "${APP_TYPE:-wordpress}" in
        wordpress)
            BK_PATHS=""
            BK_EXCLUDE=""
            BK_INCR_EXCLUDE=""
            # WP incremental defaults: only themes+plugins+uploads
            # Full backup: entire public_html (no custom paths)
            cat > "$BENV" << BKEOF
# ShieldPress Backup Config for $DOMAIN
# App type: WordPress
#
# BACKUP_PATHS : comma-separated paths to backup (relative to public_html)
#   Leave empty = backup entire public_html (default for full backup)
#   Example: wp-content/themes,wp-content/plugins,wp-content/uploads
#
# BACKUP_EXCLUDE : comma-separated dirs/patterns to exclude from backup
#   Example: cache,tmp,*.log
#
# INCR_EXCLUDE : extra excludes for incremental/daily backup (added to defaults)
#
# BACKUP_ENABLED : set to 0 to skip this domain in backups
#
# BACKUP_RETENTION : override global retention for this domain (number of backups)

BACKUP_ENABLED=1
BACKUP_PATHS=
BACKUP_EXCLUDE=
INCR_EXCLUDE=
BACKUP_RETENTION=
BKEOF
            ;;
        laravel)
            cat > "$BENV" << BKEOF
# ShieldPress Backup Config for $DOMAIN
# App type: Laravel
#
# Default excludes (always applied):
#   vendor, node_modules, .git, bootstrap/cache,
#   storage/logs, storage/framework/cache|sessions|views
#
# BACKUP_PATHS : leave empty = backup entire project (default)
#   Example: app,config,database,routes,resources
#
# BACKUP_EXCLUDE : additional dirs to exclude (comma-separated)
#   Example: public/build,public/hot,*.compiled.php
#
# INCR_EXCLUDE : extra excludes for incremental/daily mode
#
# BACKUP_ENABLED : set to 0 to skip this domain

BACKUP_ENABLED=1
BACKUP_PATHS=
BACKUP_EXCLUDE=
INCR_EXCLUDE=
BACKUP_RETENTION=
BKEOF
            ;;
        nodejs)
            cat > "$BENV" << BKEOF
# ShieldPress Backup Config for $DOMAIN
# App type: Node.js
#
# Default excludes (always applied):
#   node_modules, .git, .next, .nuxt, dist, build, .cache, .turbo
#
# BACKUP_PATHS : leave empty = backup entire project (default)
#   Example: src,public,config
#
# BACKUP_EXCLUDE : additional dirs to exclude (comma-separated)
#   Example: coverage,test-results,*.map
#
# INCR_EXCLUDE : extra excludes for incremental/daily mode
#
# BACKUP_ENABLED : set to 0 to skip this domain

BACKUP_ENABLED=1
BACKUP_PATHS=
BACKUP_EXCLUDE=
INCR_EXCLUDE=
BACKUP_RETENTION=
BKEOF
            ;;
        *)
            cat > "$BENV" << BKEOF
# ShieldPress Backup Config for $DOMAIN
# App type: PHP
#
# BACKUP_PATHS : comma-separated paths to backup (relative to public_html)
#   Leave empty = backup entire public_html
#
# BACKUP_EXCLUDE : comma-separated dirs/patterns to exclude
#   Example: cache,tmp,vendor,node_modules
#
# BACKUP_ENABLED : set to 0 to skip this domain

BACKUP_ENABLED=1
BACKUP_PATHS=
BACKUP_EXCLUDE=
INCR_EXCLUDE=
BACKUP_RETENTION=
BKEOF
            ;;
    esac

    chmod 600 "$BENV"
}

# ===============================
# DELETE DATABASE
# ===============================

delete_database(){
    DB_CONNECTION="${DB_CONNECTION:-mysql}"

    if [ "$DB_CONNECTION" = "none" ]; then
        return 0
    fi

    if [ "$DB_CONNECTION" = "pgsql" ]; then
        runuser -u postgres -- dropdb --if-exists "$DB_NAME" 2>/dev/null || true
        runuser -u postgres -- dropuser --if-exists "$DB_USER" 2>/dev/null || true
        return 0
    fi

    mysql -e "DROP DATABASE IF EXISTS \`$DB_NAME\`;"
    mysql -e "DROP USER IF EXISTS '$DB_USER'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"
}

# ===============================
# DELETE SOURCE
# ===============================

delete_source(){
    rm -rf "$DOMAIN_PATH/public_html"
}

# ===============================
# DELETE CONFIGS
# ===============================

delete_configs(){
    local PS=$(echo "$PHP_VERSION" | tr -d '.')
    local POOL_DIR="/etc/opt/remi/php${PS}/php-fpm.d"

    rm -f "/etc/nginx/conf.d/${CLEAN_DOMAIN}.conf"
    rm -f "$POOL_DIR/${CLEAN_DOMAIN}.conf"
    systemctl disable --now "${CLEAN_DOMAIN}-node.service" 2>/dev/null || true
    rm -f "/etc/systemd/system/${CLEAN_DOMAIN}-node.service"
    systemctl daemon-reload 2>/dev/null || true

    # Xóa cache zone config và cache data riêng của domain
    rm -f "/etc/nginx/conf.d/cache-zone-${CLEAN_DOMAIN}.conf"
    rm -rf "/var/cache/nginx/${CLEAN_DOMAIN}"

    [ -n "$PHP_VERSION" ] && systemctl restart "php${PS}-php-fpm" 2>/dev/null
    systemctl reload  nginx              2>/dev/null

    # chỉ xoá user nếu không còn domain nào dùng
    if [ -d "$DOMAINS_ROOT/$CLEAN_DOMAIN" ]; then
        # vẫn còn domain → không xoá user
        warn "User still in use → skip delete"
    else
        userdel -r "$CLEAN_DOMAIN" 2>/dev/null
    fi

    rm -rf "$DOMAIN_PATH"
}

# ===============================
# TOGGLE DOMAIN ON/OFF
# ===============================

toggle_domain(){
    local CONF="/etc/nginx/conf.d/${CLEAN_DOMAIN}.conf"

    if [ -f "$CONF" ]; then
        mv "$CONF" "$CONF.disabled"
        echo "Domain disabled: $DOMAIN"
    elif [ -f "$CONF.disabled" ]; then
        mv "$CONF.disabled" "$CONF"
        echo "Domain enabled: $DOMAIN"
    else
        echo "Nginx config not found for $DOMAIN"
        return 1
    fi

    nginx -t 2>/dev/null && systemctl reload nginx
}

# ===============================
# CHECK DOMAIN EXISTS
# ===============================

check_domain_exists(){
    local C="$CLEAN_DOMAIN"

    # 1. Domain folder
    if [ -d "/home/domains/$C" ]; then
        warn "Domain folder already exists"
        return 1
    fi

    # 2. Nginx config
    if [ -f "/etc/nginx/conf.d/$C.conf" ]; then
        warn "Nginx config already exists"
        return 1
    fi

    # 3. Database
    if mysql -e "SHOW DATABASES LIKE '${C}_db';" 2>/dev/null | grep -q "${C}_db"; then
        warn "Database already exists"
        return 1
    fi

    if command -v psql >/dev/null 2>&1 && systemctl is-active --quiet postgresql 2>/dev/null; then
        if runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='${C}_db'" 2>/dev/null | grep -q 1; then
            warn "PostgreSQL database already exists"
            return 1
        fi
    fi

    # 4. Linux user (KHÔNG fail nữa)
    if id "$C" &>/dev/null; then
        warn "Linux user already exists → will reuse"
        USER_EXISTS=1
    else
        USER_EXISTS=0
    fi

    return 0
}

# ===============================
# ROLLBACK DOMAIN
# ===============================

rollback_domain(){
    echo "Rolling back domain creation..."

    if [ -z "${CLEAN_DOMAIN:-}" ] || [ -z "${DOMAIN_PATH:-}" ] || \
       [ "$DOMAIN_PATH" = "$DOMAINS_ROOT" ] || [ "$DOMAIN_PATH" = "$DOMAINS_ROOT/" ] || \
       [[ "$DOMAIN_PATH" != "$DOMAINS_ROOT/"* ]]; then
        fail "Unsafe rollback path refused: ${DOMAIN_PATH:-<empty>}"
        return 1
    fi

    rm -rf "$DOMAIN_PATH"
    rm -f "/etc/nginx/conf.d/${CLEAN_DOMAIN}.conf"
    rm -f "/etc/nginx/conf.d/cache-zone-${CLEAN_DOMAIN}.conf"
    rm -rf "/var/cache/nginx/${CLEAN_DOMAIN}"
    mysql -e "DROP DATABASE IF EXISTS \`${CLEAN_DOMAIN}_db\`;" 2>/dev/null
    mysql -e "DROP USER IF EXISTS '${CLEAN_DOMAIN}_user'@'localhost';" 2>/dev/null
    if command -v psql >/dev/null 2>&1 && systemctl is-active --quiet postgresql 2>/dev/null; then
        runuser -u postgres -- dropdb --if-exists "${CLEAN_DOMAIN}_db" 2>/dev/null || true
        runuser -u postgres -- dropuser --if-exists "${CLEAN_DOMAIN}_user" 2>/dev/null || true
    fi
    rm -f "$DATA_DIR_LARAVEL_DB/${CLEAN_DOMAIN}_db.env"
    if [ "${DOMAIN_USER_CREATED:-0}" = "1" ]; then
        userdel -r "$CLEAN_DOMAIN" 2>/dev/null
    fi
    echo "Rollback completed"
}
