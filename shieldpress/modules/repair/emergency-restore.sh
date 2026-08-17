#!/bin/bash
# ====================================================
# ShieldPress Emergency Restore
# Khôi phục nhanh khi bị tấn công hoặc lỗi nghiêm trọng
# ====================================================

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
SNAPSHOT_DIR="$BASE_DIR/snapshots"
LOG_FILE="$LOG_DIR/emergency.log"
DOMAINS_ROOT="/home/domains"

mkdir -p "$LOG_DIR"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
BOLD="\e[1m"
RESET="\e[0m"

ok(){ echo -e "${GREEN}[OK]${RESET} $1"; }
fail(){ echo -e "${RED}[FAIL]${RESET} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $1"; }
log(){ echo "$(date '+%F %T') | $1" >> "$LOG_FILE"; }

# ====================================================
# 1. Khôi phục Nginx từ scratch nếu bị xóa sạch config
# ====================================================

rebuild_nginx_base(){
    echo ""
    echo -e "${BOLD}Rebuilding Nginx base configuration...${RESET}"
    echo "----------------------------------------------------"

    # Check if nginx is installed
    if ! command -v nginx &>/dev/null; then
        fail "Nginx not installed! Run Install Stack first."
        return 1
    fi

    # Rebuild main config if missing
    if [ ! -f /etc/nginx/nginx.conf ]; then
        warn "nginx.conf missing, rebuilding..."
        local CPU=$(nproc)

        cat > /etc/nginx/nginx.conf <<'NGINX_MAIN'
worker_rlimit_nofile 100000;
worker_processes auto;

events {
    use epoll;
    worker_connections 4096;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;

    log_format main '$remote_addr - $remote_user [$time_local] '
                    '"$request" $status $body_bytes_sent '
                    '"$http_referer" "$http_user_agent"';

    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log;

    include /etc/nginx/conf.d/*.conf;
}
NGINX_MAIN
        ok "nginx.conf rebuilt"
        log "REBUILT nginx.conf"
    fi

    # Ensure directories exist
    mkdir -p /etc/nginx/conf.d /etc/nginx/snippets /etc/nginx/ssl /var/log/nginx
    ok "Nginx directories verified"

    # Rebuild performance config if missing
    if [ ! -f /etc/nginx/conf.d/shieldpress-performance.conf ]; then
        warn "Performance config missing, rebuilding..."
        bash "$BASE_DIR/modules/optimize/nginx-optimize.sh" 2>/dev/null
        ok "Performance config rebuilt via optimizer"
    fi

    # Rebuild SSL hardening snippet if missing
    if [ ! -f /etc/nginx/snippets/ssl-hardening.conf ]; then
        warn "SSL hardening snippet missing, rebuilding..."
        cat > /etc/nginx/snippets/ssl-hardening.conf <<'SSL_SNIPPET'
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384';
ssl_prefer_server_ciphers on;
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 1d;
ssl_session_tickets off;
ssl_stapling on;
ssl_stapling_verify on;
resolver 1.1.1.1 8.8.8.8 valid=300s;
resolver_timeout 5s;
SSL_SNIPPET
        ok "SSL hardening snippet rebuilt"
    fi

    # Test and reload
    if nginx -t 2>/dev/null; then
        systemctl reload nginx 2>/dev/null && ok "Nginx reloaded"
    else
        fail "Nginx config still broken after rebuild"
        nginx -t 2>&1 | sed 's/^/  /'
    fi
}

# ====================================================
# 2. Khôi phục PHP-FPM pools cho tất cả domain
# ====================================================

rebuild_php_pools(){
    echo ""
    echo -e "${BOLD}Rebuilding PHP-FPM pools for all domains...${RESET}"
    echo "----------------------------------------------------"

    local REBUILT=0

    for d in "$DOMAINS_ROOT"/*/config/domain.env; do
        [ -f "$d" ] || continue

        local DN=$(grep "^DOMAIN=" "$d" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
        local SYSUSER=$(grep "^SYSTEM_USER=" "$d" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
        local PHP_VER=$(grep "^PHP_VERSION=" "$d" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')

        [ -z "$DN" ] || [ -z "$SYSUSER" ] || [ -z "$PHP_VER" ] && continue

        local PHP_SHORT=$(echo "$PHP_VER" | tr -d '.')
        local POOL_FILE="/etc/opt/remi/php${PHP_SHORT}/php-fpm.d/${SYSUSER}.conf"
        local SOCK_DIR="/var/opt/remi/php${PHP_SHORT}/run/php-fpm"

        if [ -f "$POOL_FILE" ]; then
            continue
        fi

        warn "Missing pool for $DN ($SYSUSER @ PHP $PHP_VER), rebuilding..."

        mkdir -p "$SOCK_DIR"

        # Calculate pm.max_children
        local TOTAL_RAM=$(free -m 2>/dev/null | awk '/Mem:/ {print $2}')
        local PM_MAX=$((TOTAL_RAM / 40))
        [ "$PM_MAX" -lt 5 ] && PM_MAX=5
        [ "$PM_MAX" -gt 50 ] && PM_MAX=50

        cat > "$POOL_FILE" <<POOL_EOF
[$SYSUSER]
user = $SYSUSER
group = $SYSUSER
listen = $SOCK_DIR/${SYSUSER}.sock
listen.owner = nginx
listen.group = nginx
listen.mode = 0660

pm = ondemand
pm.max_children = $PM_MAX
pm.process_idle_timeout = 10s
pm.max_requests = 500
request_terminate_timeout = 300

chdir = /

php_admin_value[error_log] = /var/opt/remi/php${PHP_SHORT}/log/php-fpm/${SYSUSER}-error.log
php_admin_flag[log_errors] = on

slowlog = /var/shieldpress/logs/php-slow/${SYSUSER}-slow.log
request_slowlog_timeout = 5
POOL_EOF

        mkdir -p "$LOG_DIR_PHP_SLOW"
        ok "Pool rebuilt: $DN ($SYSUSER)"
        ((REBUILT++))
        log "REBUILT PHP pool: $DN ($SYSUSER @ PHP $PHP_VER)"
    done

    if [ "$REBUILT" -gt 0 ]; then
        echo ""
        echo "Restarting all PHP-FPM services..."
        for v in 81 82 83 84; do
            SVC="php${v}-php-fpm"
            systemctl list-unit-files 2>/dev/null | grep -q "$SVC" || continue
            systemctl restart "$SVC" 2>/dev/null && ok "$SVC restarted" || warn "$SVC restart failed"
        done
    else
        ok "All PHP pools are intact"
    fi
}

# ====================================================
# 3. Khôi phục Nginx vhost cho domain (basic)
# ====================================================

rebuild_nginx_vhosts(){
    echo ""
    echo -e "${BOLD}Checking Nginx vhost configs for all domains...${RESET}"
    echo "----------------------------------------------------"

    local REBUILT=0

    for d in "$DOMAINS_ROOT"/*/config/domain.env; do
        [ -f "$d" ] || continue

        local DN=$(grep "^DOMAIN=" "$d" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
        local SYSUSER=$(grep "^SYSTEM_USER=" "$d" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
        local PHP_VER=$(grep "^PHP_VERSION=" "$d" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
        local DOCROOT=$(grep "^DOCUMENT_ROOT=" "$d" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')

        [ -z "$DN" ] || [ -z "$SYSUSER" ] || [ -z "$PHP_VER" ] && continue

        local CLEAN=$(echo "$DN" | sed 's/[^a-zA-Z0-9.-]/_/g')
        local NGINX_CONF="/etc/nginx/conf.d/${CLEAN}.conf"

        if [ -f "$NGINX_CONF" ]; then
            continue
        fi

        warn "Missing vhost for $DN, rebuilding basic config..."

        local PHP_SHORT=$(echo "$PHP_VER" | tr -d '.')
        local SOCK_DIR="/var/opt/remi/php${PHP_SHORT}/run/php-fpm"
        local WEB_ROOT="${DOCROOT:-/home/domains/$SYSUSER/public_html}"
        local LOG_DIR="/var/log/nginx/domains/$CLEAN"

        mkdir -p "$LOG_DIR"

        # Check if SSL cert exists
        local USE_SSL=0
        local CERT="/etc/letsencrypt/live/$DN/fullchain.pem"
        local KEY="/etc/letsencrypt/live/$DN/privkey.pem"
        [ -f "$CERT" ] && [ -f "$KEY" ] && USE_SSL=1

        cat > "$NGINX_CONF" <<VHOST_EOF
# ShieldPress Emergency Rebuild - $DN
server {
    listen 80;
    server_name $DN www.$DN;

    root $WEB_ROOT;
    index index.php index.html;

    access_log $LOG_DIR/access.log;
    error_log  $LOG_DIR/error.log;

    client_max_body_size 512M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_pass unix:$SOCK_DIR/${SYSUSER}.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 300;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
    }

    location ~ /\. {
        deny all;
    }
}
VHOST_EOF

        # Add SSL block if cert exists
        if [ "$USE_SSL" -eq 1 ]; then
            cat >> "$NGINX_CONF" <<SSL_VHOST_EOF

server {
    listen 443 ssl http2;
    server_name $DN www.$DN;

    ssl_certificate $CERT;
    ssl_certificate_key $KEY;
    include /etc/nginx/snippets/ssl-hardening.conf;

    root $WEB_ROOT;
    index index.php index.html;

    access_log $LOG_DIR/access.log;
    error_log  $LOG_DIR/error.log;

    client_max_body_size 512M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_pass unix:$SOCK_DIR/${SYSUSER}.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 300;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
    }

    location ~ /\. {
        deny all;
    }
}
SSL_VHOST_EOF
        fi

        ok "Vhost rebuilt: $DN"
        ((REBUILT++))
        log "REBUILT vhost: $DN (ssl=$USE_SSL)"
    done

    if [ "$REBUILT" -gt 0 ]; then
        echo ""
        if nginx -t 2>/dev/null; then
            systemctl reload nginx && ok "Nginx reloaded with rebuilt vhosts"
        else
            fail "Nginx config test failed after rebuild"
            nginx -t 2>&1 | sed 's/^/  /'
        fi
    else
        ok "All vhost configs are intact"
    fi
}

# ====================================================
# 4. Khôi phục permissions bị sai
# ====================================================

fix_permissions(){
    echo ""
    echo -e "${BOLD}Fixing domain permissions...${RESET}"
    echo "----------------------------------------------------"

    for d in "$DOMAINS_ROOT"/*/; do
        [ -d "$d" ] || continue
        local ENV_FILE="$d/config/domain.env"
        [ -f "$ENV_FILE" ] || continue

        local DN=$(grep "^DOMAIN=" "$ENV_FILE" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
        local SYSUSER=$(grep "^SYSTEM_USER=" "$ENV_FILE" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
        [ -z "$SYSUSER" ] && continue

        # Check if user exists
        if ! id "$SYSUSER" &>/dev/null; then
            warn "User $SYSUSER missing for $DN, recreating..."
            useradd -r -s /sbin/nologin -d "$d" "$SYSUSER" 2>/dev/null
            ok "User $SYSUSER recreated"
            log "REBUILT user: $SYSUSER for $DN"
        fi

        # Fix ownership
        chown -R "$SYSUSER:$SYSUSER" "$d" 2>/dev/null

        # Fix directory permissions
        find "$d" -type d \
            -not -path "*/node_modules/*" -not -path "*/vendor/*" -not -path "*/.git/*" \
            -exec chmod 755 {} \; 2>/dev/null

        # Fix file permissions
        find "$d" -type f \
            -not -path "*/node_modules/*" -not -path "*/vendor/*" -not -path "*/.git/*" \
            -exec chmod 644 {} \; 2>/dev/null

        # wp-config.php should be more restrictive
        [ -f "$d/public_html/wp-config.php" ] && chmod 600 "$d/public_html/wp-config.php"

        ok "Permissions fixed: $DN"
    done

    # Fix Nginx ownership
    chown -R root:root /etc/nginx/ 2>/dev/null
    chmod -R 644 /etc/nginx/conf.d/*.conf 2>/dev/null

    ok "All permissions fixed"
    log "FIXED all domain permissions"
}

# ====================================================
# 5. Full Emergency Recovery
# ====================================================

full_emergency(){
    echo ""
    echo -e "${RED}${BOLD}=====================================================${RESET}"
    echo -e "${RED}${BOLD}  EMERGENCY FULL RECOVERY${RESET}"
    echo -e "${RED}${BOLD}=====================================================${RESET}"
    echo ""
    echo "This will:"
    echo "  1. Try to restore from latest snapshot"
    echo "  2. Rebuild missing Nginx configs"
    echo "  3. Rebuild missing PHP-FPM pools"
    echo "  4. Fix all permissions"
    echo "  5. Restart all services"
    echo "  6. Validate everything"
    echo ""

    read -p "Proceed with emergency recovery? (yes/no): " confirm
    [ "$confirm" = "yes" ] || { warn "Cancelled (type 'yes' to confirm)"; return; }

    log "EMERGENCY RECOVERY started"

    # Step 1: Try snapshot restore
    echo ""
    echo -e "${BOLD}Step 1: Checking snapshots...${RESET}"
    local LATEST_SNAP=$(ls -1t "$SNAPSHOT_DIR"/*.tar.gz 2>/dev/null | head -1)
    if [ -n "$LATEST_SNAP" ]; then
        echo "Latest snapshot: $(basename "$LATEST_SNAP")"
        read -p "Restore from this snapshot first? (y/n): " snap_confirm
        if [[ "$snap_confirm" =~ ^[yY]$ ]]; then
            bash "$BASE_DIR/modules/repair/config-snapshot.sh" auto "pre-emergency" 2>/dev/null

            local TEMP_DIR=$(mktemp -d)
            local SNAP_NAME=$(basename "$LATEST_SNAP" .tar.gz)
            tar -xzf "$LATEST_SNAP" -C "$TEMP_DIR" 2>/dev/null

            if [ -d "$TEMP_DIR/$SNAP_NAME/etc/nginx" ]; then
                cp -af "$TEMP_DIR/$SNAP_NAME/etc/nginx/"* /etc/nginx/ 2>/dev/null
                ok "Nginx configs restored from snapshot"
            fi

            for v in 81 82 83 84; do
                local PHP_SNAP="$TEMP_DIR/$SNAP_NAME/etc/opt/remi/php${v}"
                if [ -d "$PHP_SNAP" ]; then
                    cp -af "$PHP_SNAP/"* "/etc/opt/remi/php${v}/" 2>/dev/null
                    ok "PHP $v configs restored from snapshot"
                fi
            done

            rm -rf "$TEMP_DIR"
        fi
    else
        warn "No snapshots available, rebuilding from scratch..."
    fi

    # Step 2: Rebuild Nginx
    echo ""
    echo -e "${BOLD}Step 2: Rebuilding Nginx...${RESET}"
    rebuild_nginx_base
    rebuild_nginx_vhosts

    # Step 3: Rebuild PHP pools
    echo ""
    echo -e "${BOLD}Step 3: Rebuilding PHP pools...${RESET}"
    rebuild_php_pools

    # Step 4: Fix permissions
    echo ""
    echo -e "${BOLD}Step 4: Fixing permissions...${RESET}"
    fix_permissions

    # Step 5: Restart everything
    echo ""
    echo -e "${BOLD}Step 5: Restarting all services...${RESET}"
    systemctl restart nginx 2>/dev/null && ok "Nginx restarted" || fail "Nginx failed"
    systemctl restart mariadb 2>/dev/null && ok "MariaDB restarted" || warn "MariaDB not running"
    systemctl restart postgresql 2>/dev/null && ok "PostgreSQL restarted" || warn "PostgreSQL not running"
    systemctl restart valkey 2>/dev/null && ok "Valkey restarted" || warn "Valkey not running"
    systemctl restart firewalld 2>/dev/null && ok "Firewall restarted" || warn "Firewall not running"
    systemctl restart fail2ban 2>/dev/null && ok "Fail2ban restarted" || warn "Fail2ban not running"
    for v in 81 82 83 84; do
        SVC="php${v}-php-fpm"
        systemctl list-unit-files 2>/dev/null | grep -q "$SVC" || continue
        systemctl restart "$SVC" 2>/dev/null && ok "$SVC restarted" || warn "$SVC failed"
    done

    # Step 6: Validate
    echo ""
    echo -e "${BOLD}Step 6: Validating...${RESET}"
    bash "$BASE_DIR/modules/repair/system-integrity.sh" auto-fix 2>/dev/null

    echo ""
    echo -e "${GREEN}${BOLD}=====================================================${RESET}"
    echo -e "${GREEN}${BOLD}  EMERGENCY RECOVERY COMPLETE${RESET}"
    echo -e "${GREEN}${BOLD}=====================================================${RESET}"

    log "EMERGENCY RECOVERY completed"

    # Notify
    if [ -f "$BASE_DIR/modules/notification/telegram-notify.sh" ]; then
        bash "$BASE_DIR/modules/notification/telegram-notify.sh" send "security_alert" \
            "Emergency Recovery" "Full emergency recovery completed on $(hostname)" 2>/dev/null
    fi
}

# ====================================================
# MENU
# ====================================================

while true; do
    clear
    echo -e "${RED}${BOLD}=====================================================${RESET}"
    echo -e "${RED}${BOLD}          EMERGENCY RESTORE${RESET}"
    echo -e "${RED}${BOLD}=====================================================${RESET}"
    echo ""
    echo "  1) Rebuild Nginx Base Config"
    echo "  2) Rebuild All Nginx Vhosts"
    echo "  3) Rebuild All PHP-FPM Pools"
    echo "  4) Fix All Permissions"
    echo "  5) Full Emergency Recovery (ALL)"
    echo "  0) Back"
    echo "----------------------------------------------------"
    read -p "Select: " opt

    case "$opt" in
        1) rebuild_nginx_base ;;
        2) rebuild_nginx_vhosts ;;
        3) rebuild_php_pools ;;
        4) fix_permissions ;;
        5) full_emergency ;;
        0) break ;;
        *) warn "Invalid" ;;
    esac

    echo ""
    read -p "Press Enter..."
done
