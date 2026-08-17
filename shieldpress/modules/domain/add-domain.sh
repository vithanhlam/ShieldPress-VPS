#!/bin/bash
set -e
set -o pipefail
source /opt/shieldpress/modules/domain/helpers.sh

read -p "Enter domain (shieldpress.net): " DOMAIN
DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

if [[ -z "$DOMAIN" || ${#DOMAIN} -gt 253 || ! "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
    echo "Invalid domain. Enter a hostname such as shieldpress.net (without http:// or paths)."
    read -p "Press Enter..."
    exit 1
fi

CLEAN_DOMAIN=$(clean_domain_name "$DOMAIN")
[ -n "$CLEAN_DOMAIN" ] || { echo "Unable to derive a safe system name from domain."; exit 1; }
DOMAIN_PATH="$DOMAINS_ROOT/$CLEAN_DOMAIN"

check_domain_exists || {
echo ""
if [ -d "$DOMAIN_PATH" ] && [ ! -f "$DOMAIN_PATH/config/domain.env" ]; then
    echo "Domain appears to be partially created: $DOMAIN_PATH"
    read -p "Remove partial domain data and retry? [y/N]: " CLEAN_PARTIAL
    if [[ "$CLEAN_PARTIAL" =~ ^[Yy]$ ]]; then
        rollback_domain
        check_domain_exists || {
            echo "Domain still exists in system."
            read -p "Press Enter..."
            exit
        }
    else
        echo "Domain already exists in system."
        read -p "Press Enter..."
        exit
    fi
else
    echo "Domain already exists in system."
    read -p "Press Enter..."
    exit
fi
}



APP_TYPE="${ADD_DOMAIN_APP:-}"

if [ -z "$APP_TYPE" ]; then
    echo ""
    echo "Select application type:"
    echo "  1) WordPress"
    echo "  2) PHP site"
    echo "  3) Laravel 13"
    echo "  4) Node.js app"
    echo ""
    read -p "Choose [1]: " APP_OPT
    APP_OPT="${APP_OPT:-1}"

    case "$APP_OPT" in
        1) APP_TYPE="wordpress" ;;
        2) APP_TYPE="php" ;;
        3) APP_TYPE="laravel" ;;
        4) APP_TYPE="nodejs" ;;
        *) echo "Invalid option"; exit 1 ;;
    esac
fi

case "$APP_TYPE" in
    wordpress)
        PHP_VERSION="$DEFAULT_PHP_VERSION"
        DB_CONNECTION="mysql"
        DEFAULT_CREATE_DB="Y"
        ;;
    php)
        PHP_VERSION="$DEFAULT_PHP_VERSION"
        DB_CONNECTION="mysql"
        DEFAULT_CREATE_DB="N"
        ;;
    laravel|laravel13)
        APP_TYPE="laravel"
        PHP_VERSION="8.4"
        if postgresql_ready; then
            DB_CONNECTION="pgsql"
        else
            DB_CONNECTION="mysql"
            echo "[INFO] PostgreSQL is not installed or not running. Laravel domain will use MySQL."
        fi
        DEFAULT_CREATE_DB="Y"
        ;;
    node|nodejs)
        APP_TYPE="nodejs"
        PHP_VERSION=""
        DB_CONNECTION="mysql"
        DEFAULT_CREATE_DB="N"
        NODE_APP_PORT=$(find_free_node_port)
        NODE_ENTRY="app.js"
        echo "Default Node.js app port: $NODE_APP_PORT"
        read -p "Change Node.js app port? [y/N]: " CHANGE_NODE_PORT
        if [[ "$CHANGE_NODE_PORT" =~ ^[Yy]$ ]]; then
            read -p "Node.js app port: " NODE_APP_PORT
        fi
        ;;
    *)
        echo "Invalid application type: $APP_TYPE"
        exit 1
        ;;
esac

if [ "${DEFAULT_CREATE_DB:-N}" = "Y" ]; then
    read -p "Create database for this domain? [Y/n]: " CREATE_DB_CONFIRM
    CREATE_DB_CONFIRM="${CREATE_DB_CONFIRM:-Y}"
else
    read -p "Create database for this domain? [y/N]: " CREATE_DB_CONFIRM
    CREATE_DB_CONFIRM="${CREATE_DB_CONFIRM:-N}"
fi

if [[ ! "$CREATE_DB_CONFIRM" =~ ^[Yy]$ ]]; then
    DB_CONNECTION="none"
fi

if [ "$APP_TYPE" != "nodejs" ]; then
    PHP_SHORT=$(php_version_to_short "$PHP_VERSION")
else
    PHP_SHORT=""
fi

if [ "$APP_TYPE" = "laravel" ] && ! declare -F create_laravel_nginx_config >/dev/null 2>&1; then
    echo "[FAIL] Laravel domain helper is missing. Please update /opt/shieldpress/modules/domain/helpers.sh"
    exit 1
fi

if [ "$APP_TYPE" = "nodejs" ] && ! declare -F create_nodejs_nginx_config >/dev/null 2>&1; then
    echo "[FAIL] Node.js domain helper is missing. Please update /opt/shieldpress/modules/domain/helpers.sh"
    exit 1
fi

if [ "$APP_TYPE" != "nodejs" ]; then
    echo "Default PHP version: $PHP_VERSION"
    read -p "Change PHP version? [y/N]: " CHANGE_PHP

    if [[ "$CHANGE_PHP" =~ ^[Yy]$ ]]; then
        select_php_version || exit
    fi
fi

create_linux_user || exit
create_directory_structure || exit
if [ "$DB_CONNECTION" = "none" ]; then
    DB_NAME=""
    DB_USER=""
    DB_PASS=""
elif [ "$DB_CONNECTION" = "pgsql" ]; then
    create_postgresql_database || exit
else
    create_database || exit
fi
if [ "$APP_TYPE" != "nodejs" ]; then
    create_php_pool || exit
fi
if [ "$APP_TYPE" = "laravel" ]; then
    ROOT="$DOMAIN_PATH/public_html/public"
    create_laravel_nginx_config || exit
elif [ "$APP_TYPE" = "nodejs" ]; then
    ROOT="$DOMAIN_PATH/public_html"
    create_nodejs_service || exit
    create_nodejs_nginx_config || exit
else
    ROOT="$DOMAIN_PATH/public_html"
    create_nginx_config || exit
fi
create_domain_env || exit
create_backup_env

# ===============================
# OPTIONAL LARAVEL INSTALL / DEFAULT PAGE
# ===============================

WEB_ROOT="$ROOT"
mkdir -p "$WEB_ROOT"

SERVER_IP=$(curl -s ifconfig.me || curl -s api.ipify.org)
SERVER_HOSTNAME=$(hostname)

if [ "$APP_TYPE" = "laravel" ]; then
read -p "Install fresh Laravel 13 now? [Y/n]: " INSTALL_LARAVEL
INSTALL_LARAVEL="${INSTALL_LARAVEL:-Y}"

if [[ "$INSTALL_LARAVEL" =~ ^[Yy]$ ]]; then
    if command -v composer >/dev/null 2>&1; then
        find "$DOMAIN_PATH/public_html" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
        COMPOSER_ALLOW_SUPERUSER=1 composer create-project laravel/laravel "$DOMAIN_PATH/public_html" "^13.0" --no-interaction

        ENV_FILE="$DOMAIN_PATH/public_html/.env"
        if [ -f "$ENV_FILE" ]; then
            if [ "$DB_CONNECTION" = "pgsql" ]; then
                DB_PORT="5432"
            elif [ "$DB_CONNECTION" = "mysql" ]; then
                DB_PORT="3306"
            fi

            if [ "$DB_CONNECTION" != "none" ]; then
                sed -i "s/^DB_CONNECTION=.*/DB_CONNECTION=$DB_CONNECTION/" "$ENV_FILE"
                sed -i "s/^# DB_HOST=.*/DB_HOST=127.0.0.1/" "$ENV_FILE"
                sed -i "s/^# DB_PORT=.*/DB_PORT=$DB_PORT/" "$ENV_FILE"
                sed -i "s/^# DB_DATABASE=.*/DB_DATABASE=$DB_NAME/" "$ENV_FILE"
                sed -i "s/^# DB_USERNAME=.*/DB_USERNAME=$DB_USER/" "$ENV_FILE"
                sed -i "s/^# DB_PASSWORD=.*/DB_PASSWORD=$DB_PASS/" "$ENV_FILE"
                sed -i "s/^DB_HOST=.*/DB_HOST=127.0.0.1/" "$ENV_FILE"
                sed -i "s/^DB_PORT=.*/DB_PORT=$DB_PORT/" "$ENV_FILE"
                sed -i "s/^DB_DATABASE=.*/DB_DATABASE=$DB_NAME/" "$ENV_FILE"
                sed -i "s/^DB_USERNAME=.*/DB_USERNAME=$DB_USER/" "$ENV_FILE"
                sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=$DB_PASS/" "$ENV_FILE"
            fi
        fi

        if [ -f "$DOMAIN_PATH/public_html/package.json" ] && command -v npm >/dev/null 2>&1; then
            (cd "$DOMAIN_PATH/public_html" && npm install && npm run build) || warn "npm build failed"
        fi

        if [ "$DB_CONNECTION" != "none" ]; then
            (cd "$DOMAIN_PATH/public_html" && php artisan migrate --force) || warn "Laravel migrate failed"
        fi
        (cd "$DOMAIN_PATH/public_html" && php artisan config:cache && php artisan route:cache && php artisan view:cache) || true
    else
        warn "Composer not found, creating placeholder only"
    fi
fi

if [ ! -f "$WEB_ROOT/index.php" ]; then
cat > "$WEB_ROOT/index.php" <<EOF
<?php

echo 'Laravel 13 domain is ready. Deploy your Laravel project to $DOMAIN_PATH/public_html and keep the web root at public/.';
EOF
fi
elif [ "$APP_TYPE" = "nodejs" ]; then
    :
else

if [ "$APP_TYPE" = "wordpress" ]; then
    FOOTER_TEXT="You can now install WordPress or deploy your source code."
else
    FOOTER_TEXT="You can now deploy your PHP source code."
fi

cat > "$WEB_ROOT/index.html" <<EOF
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>Domain Added Successfully - ShieldPress VPS</title>
<style>
body {
    font-family: Arial, sans-serif;
    background: #0f172a;
    color: #ffffff;
    text-align: center;
    padding-top: 120px;
}
h1 { color: #22c55e; }
.box {
    max-width: 700px;
    margin: auto;
}
.info {
    margin-top: 30px;
    color: #cbd5e1;
}
.footer {
    margin-top: 60px;
    font-size: 13px;
    color: #64748b;
}
</style>
</head>
<body>
<div class="box">
<h1>Domain Added Successfully</h1>
<p>The domain <strong>$DOMAIN</strong> has been successfully created on this server.</p>

<div class="info">
<p><strong>Server IP:</strong> $SERVER_IP</p>
<p><strong>Hostname:</strong> $SERVER_HOSTNAME</p>
<p><strong>Platform:</strong> ShieldPress VPS Stack</p>
</div>

<div class="footer">
$FOOTER_TEXT<br>
Powered by ShieldPress VPS
</div>
</div>
</body>
</html>
EOF
fi

chown -R "$CLEAN_DOMAIN:$CLEAN_DOMAIN" "$DOMAIN_PATH/public_html"

echo ""
echo "================================"
echo " DOMAIN CREATED SUCCESSFULLY"
echo "================================"
echo "Domain : $DOMAIN"
echo "Path   : $DOMAIN_PATH"
echo "App    : $APP_TYPE"
echo "Root   : $ROOT"
echo "DB Type: $DB_CONNECTION"
echo "DB     : $DB_NAME"
echo "PHP    : $PHP_VERSION"
if [ "$APP_TYPE" = "nodejs" ]; then
    echo "Node Port: $NODE_APP_PORT"
    echo "Service  : ${CLEAN_DOMAIN}-node.service"
fi
echo "================================"

echo ""
read -p "Press Enter to continue..."
