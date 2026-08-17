#!/bin/bash
# =====================================================
# ShieldPress Server Migration Tool
# Export/Import domains between ShieldPress servers
# Supports: WordPress, Laravel, Node.js, PHP
# =====================================================

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
DOMAINS_ROOT="/home/domains"
MIGRATE_DIR="$BASE_DIR/migrate"
LOG_FILE="$LOG_DIR/migrate.log"

source "$BASE_DIR/core/ui.sh"
source "$BASE_DIR/modules/backup/_backup_helper.sh"

mkdir -p "$MIGRATE_DIR" "$LOG_DIR"

log(){ echo "$(date '+%F %T') | $1" | tee -a "$LOG_FILE"; }
ok(){  echo "[OK] $1"; log "[OK] $1"; }
fail(){ echo "[FAIL] $1"; log "[FAIL] $1"; }

# =====================================================
# EXPORT DOMAIN
# =====================================================

export_domain(){
    echo ""
    echo "======================================"
    echo "  EXPORT DOMAIN FOR MIGRATION"
    echo "======================================"

    # Select domain
    declare -a FOLDERS=()
    local i=1
    for d in "$DOMAINS_ROOT"/*/; do
        [ -d "$d" ] || continue
        [ -f "$d/config/domain.env" ] || continue
        local DN AT
        DN=$(grep "^DOMAIN=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
        AT=$(grep "^APP_TYPE=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
        [ -z "$DN" ] && continue
        echo "$i) $DN [${AT:-wordpress}]"
        FOLDERS[$i]=$(basename "$d")
        ((i++))
    done

    [ $i -eq 1 ] && { echo "No domains found."; return 1; }

    echo "--------------------------------"
    read -p "Select domain number: " choice
    local FOLDER="${FOLDERS[$choice]}"
    [ -z "$FOLDER" ] && { echo "Invalid selection!"; return 1; }

    local DOMAIN_PATH="$DOMAINS_ROOT/$FOLDER"
    load_domain_info "$DOMAIN_PATH"

    echo ""
    echo "Exporting: $DOMAIN"
    echo "  App Type    : $APP_TYPE"
    echo "  DB Engine   : $DB_CONNECTION"
    echo "  Database    : ${DB_NAME:-none}"
    echo "  PHP Version : ${PHP_VERSION:-N/A}"
    echo ""

    read -p "Continue? (y/n): " CONFIRM
    [ "$CONFIRM" != "y" ] && { echo "Cancelled."; return; }

    local DATE EXPORT_DIR EXPORT_FILE EXPORT_START
    DATE=$(date +%F_%H-%M-%S)
    EXPORT_DIR=$(mktemp -d "$MIGRATE_DIR/export_${FOLDER}_XXXXXX")
    EXPORT_FILE="$MIGRATE_DIR/${DOMAIN}_migrate_${DATE}.tar.gz"
    EXPORT_START=$(date +%s)

    trap 'rm -rf "$EXPORT_DIR"' EXIT

    # ── Step 1: Config ──
    echo "[Step 1/6] Exporting configuration..."
    mkdir -p "$EXPORT_DIR/config"
    cp "$DOMAIN_PATH/config/domain.env" "$EXPORT_DIR/config/"
    [ -f "$DOMAIN_PATH/config/staging.env" ] && cp "$DOMAIN_PATH/config/staging.env" "$EXPORT_DIR/config/"
    # Auto-backup scripts
    for f in "$DOMAIN_PATH/config/auto-backup"*.sh; do
        [ -f "$f" ] && cp "$f" "$EXPORT_DIR/config/"
    done
    ok "Configuration exported"

    # ── Step 2: Database ──
    echo ""
    echo "[Step 2/6] Exporting database..."
    if [ -n "$DB_NAME" ] && [ "$DB_CONNECTION" != "none" ]; then
        if database_exists_for_backup; then
            backup_db_to_file "$EXPORT_DIR/database.sql.gz"
            if [ $? -eq 0 ]; then
                ok "Database exported ($DB_CONNECTION: $DB_NAME)"
            else
                fail "Database export failed!"
                rm -rf "$EXPORT_DIR"; return 1
            fi
        else
            echo "[INFO] Database $DB_NAME does not exist, skipping"
            echo "skipped" > "$EXPORT_DIR/database.skipped"
        fi
    else
        echo "[INFO] No database configured"
        echo "none" > "$EXPORT_DIR/database.skipped"
    fi

    # ── Step 3: Files ──
    echo ""
    echo "[Step 3/6] Exporting files ($APP_TYPE)..."
    if [ -d "$DOMAIN_PATH/public_html" ]; then
        archive_source_to_file "$EXPORT_DIR/files.tar.gz"
        if [ $? -eq 0 ]; then
            ok "Files exported"
        else
            fail "Files export failed!"
            rm -rf "$EXPORT_DIR"; return 1
        fi
    else
        echo "[INFO] No public_html directory"
    fi

    # ── Step 4: SSL ──
    echo ""
    echo "[Step 4/6] Exporting SSL certificates..."
    local CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
    local CF_CERT="/etc/nginx/ssl/${FOLDER}"
    local CUSTOM_CERT="/etc/nginx/ssl/${FOLDER}.crt"
    if [ -d "$CERT_DIR" ]; then
        mkdir -p "$EXPORT_DIR/ssl"
        cp -rL "$CERT_DIR"/* "$EXPORT_DIR/ssl/" 2>/dev/null
        echo "SSL_TYPE=letsencrypt" > "$EXPORT_DIR/ssl/ssl-info.env"
        ok "Let's Encrypt SSL exported"
    elif [ -d "$CF_CERT" ]; then
        mkdir -p "$EXPORT_DIR/ssl"
        cp -r "$CF_CERT"/* "$EXPORT_DIR/ssl/" 2>/dev/null
        echo "SSL_TYPE=cloudflare" > "$EXPORT_DIR/ssl/ssl-info.env"
        ok "Cloudflare SSL exported"
    elif [ -f "$CUSTOM_CERT" ]; then
        mkdir -p "$EXPORT_DIR/ssl"
        cp /etc/nginx/ssl/${FOLDER}.* "$EXPORT_DIR/ssl/" 2>/dev/null
        echo "SSL_TYPE=custom" > "$EXPORT_DIR/ssl/ssl-info.env"
        ok "Custom SSL exported"
    else
        echo "[INFO] No SSL certificates found"
    fi

    # ── Step 5: Nginx config ──
    echo ""
    echo "[Step 5/6] Exporting Nginx config..."
    local NGINX_CONF="/etc/nginx/conf.d/${FOLDER}.conf"
    if [ -f "$NGINX_CONF" ]; then
        mkdir -p "$EXPORT_DIR/nginx"
        cp "$NGINX_CONF" "$EXPORT_DIR/nginx/"
        ok "Nginx config exported"
    else
        echo "[INFO] No Nginx config found"
    fi

    # ── Step 6: Cron + App-specific ──
    echo ""
    echo "[Step 6/6] Exporting app-specific data..."

    # Cron jobs
    local CRON_JOBS
    CRON_JOBS=$(crontab -l 2>/dev/null | grep "$FOLDER" || true)
    if [ -n "$CRON_JOBS" ]; then
        echo "$CRON_JOBS" > "$EXPORT_DIR/crontab.txt"
        ok "Cron jobs exported"
    fi

    # Node.js: PM2 ecosystem + port
    if [ "$APP_TYPE" = "nodejs" ]; then
        local NODE_PORT PM2_NAME
        NODE_PORT=$(grep "^NODE_PORT=" "$DOMAIN_PATH/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
        PM2_NAME=$(grep "^PM2_NAME=" "$DOMAIN_PATH/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')

        # Export PM2 ecosystem file if exists
        for ef in "$DOMAIN_PATH/public_html/ecosystem.config.js" "$DOMAIN_PATH/public_html/ecosystem.config.cjs"; do
            [ -f "$ef" ] && { mkdir -p "$EXPORT_DIR/app-config"; cp "$ef" "$EXPORT_DIR/app-config/"; }
        done

        # Export .env if exists (Next.js, Nuxt, custom)
        [ -f "$DOMAIN_PATH/public_html/.env" ] && { mkdir -p "$EXPORT_DIR/app-config"; cp "$DOMAIN_PATH/public_html/.env" "$EXPORT_DIR/app-config/dotenv"; }
        [ -f "$DOMAIN_PATH/public_html/.env.production" ] && { mkdir -p "$EXPORT_DIR/app-config"; cp "$DOMAIN_PATH/public_html/.env.production" "$EXPORT_DIR/app-config/dotenv.production"; }

        ok "Node.js config exported (port: ${NODE_PORT:-auto})"
    fi

    # Laravel: .env file
    if [ "$APP_TYPE" = "laravel" ]; then
        if [ -f "$DOMAIN_PATH/public_html/.env" ]; then
            mkdir -p "$EXPORT_DIR/app-config"
            cp "$DOMAIN_PATH/public_html/.env" "$EXPORT_DIR/app-config/dotenv"
            ok "Laravel .env exported"
        fi
    fi

    # ── Metadata ──
    local SYS_USER_EXPORT
    SYS_USER_EXPORT=$(grep "^SYSTEM_USER=" "$DOMAIN_PATH/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')

    cat > "$EXPORT_DIR/migrate-info.env" <<METAEOF
SHIELDPRESS_VERSION=$(cat "$BASE_DIR/version.txt" 2>/dev/null | tr -d '[:space:]')
EXPORT_DATE=$(date '+%Y-%m-%d %H:%M:%S')
EXPORT_SERVER=$(hostname -f 2>/dev/null || hostname)
EXPORT_SERVER_IP=$(curl -s --connect-timeout 3 --max-time 5 ifconfig.me 2>/dev/null || echo "unknown")
DOMAIN=$DOMAIN
APP_TYPE=$APP_TYPE
DB_CONNECTION=$DB_CONNECTION
DB_NAME=$DB_NAME
PHP_VERSION=$PHP_VERSION
SYSTEM_USER=$SYS_USER_EXPORT
METAEOF

    # ── Package ──
    echo ""
    echo "Creating migration package..."
    tar -czf "$EXPORT_FILE" -C "$EXPORT_DIR" .
    rm -rf "$EXPORT_DIR"
    trap - EXIT

    EXPORT_FILE=$(maybe_encrypt_backup "$EXPORT_FILE")

    local EXPORT_END DURATION DURATION_FMT SIZE
    EXPORT_END=$(date +%s)
    DURATION=$((EXPORT_END - EXPORT_START))
    DURATION_FMT=$(format_duration "$DURATION")
    SIZE=$(du -h "$EXPORT_FILE" | awk '{print $1}')

    echo ""
    echo "======================================"
    echo "  EXPORT COMPLETED"
    echo "======================================"
    echo "  Domain   : $DOMAIN ($APP_TYPE)"
    echo "  File     : $EXPORT_FILE"
    echo "  Size     : $SIZE"
    echo "  Duration : $DURATION_FMT"
    echo "======================================"
    echo ""
    echo "Transfer to new server:"
    echo "  scp \"$EXPORT_FILE\" root@NEW_SERVER:$MIGRATE_DIR/"
    echo ""

    log "EXPORT SUCCESS: $DOMAIN ($APP_TYPE) | Size: $SIZE | Duration: $DURATION_FMT"
}

# =====================================================
# IMPORT DOMAIN
# =====================================================

import_domain(){
    echo ""
    echo "======================================"
    echo "  IMPORT DOMAIN FROM MIGRATION"
    echo "======================================"

    # List packages
    local FILES=()
    local i=1
    for f in "$MIGRATE_DIR"/*_migrate_*.tar.gz "$MIGRATE_DIR"/*_migrate_*.tar.gz.enc; do
        [ -f "$f" ] || continue
        local SIZE DATE_STR
        SIZE=$(du -h "$f" | awk '{print $1}')
        DATE_STR=$(stat -c '%y' "$f" 2>/dev/null | cut -d'.' -f1)
        echo "$i) $(basename "$f")  [$SIZE]  $DATE_STR"
        FILES[$i]="$f"
        ((i++))
    done

    [ $i -eq 1 ] && { echo "No migration packages found in $MIGRATE_DIR"; return 1; }

    echo "--------------------------------"
    read -p "Select package number: " choice
    local PACKAGE="${FILES[$choice]}"
    [ -z "$PACKAGE" ] && { echo "Invalid selection!"; return 1; }

    # Decrypt if needed
    if [[ "$PACKAGE" == *.enc ]]; then
        echo "Decrypting..."
        PACKAGE=$(decrypt_for_restore "$PACKAGE")
        [ $? -ne 0 ] && return 1
    fi

    # Extract
    local IMPORT_DIR
    IMPORT_DIR=$(mktemp -d "$MIGRATE_DIR/import_XXXXXX")
    trap 'rm -rf "$IMPORT_DIR"' EXIT

    echo "Extracting..."
    tar -xzf "$PACKAGE" -C "$IMPORT_DIR"
    [ $? -ne 0 ] && { fail "Extract failed!"; rm -rf "$IMPORT_DIR"; return 1; }

    [ ! -f "$IMPORT_DIR/migrate-info.env" ] && { fail "Invalid package (no metadata)!"; rm -rf "$IMPORT_DIR"; return 1; }

    # Read metadata
    local M_DOMAIN M_APP_TYPE M_DB_CONNECTION M_DB_NAME M_PHP_VERSION M_EXPORT_SERVER M_SYSTEM_USER
    M_DOMAIN=$(grep "^DOMAIN=" "$IMPORT_DIR/migrate-info.env" | cut -d'=' -f2)
    M_APP_TYPE=$(grep "^APP_TYPE=" "$IMPORT_DIR/migrate-info.env" | cut -d'=' -f2)
    M_DB_CONNECTION=$(grep "^DB_CONNECTION=" "$IMPORT_DIR/migrate-info.env" | cut -d'=' -f2)
    M_DB_NAME=$(grep "^DB_NAME=" "$IMPORT_DIR/migrate-info.env" | cut -d'=' -f2)
    M_PHP_VERSION=$(grep "^PHP_VERSION=" "$IMPORT_DIR/migrate-info.env" | cut -d'=' -f2)
    M_EXPORT_SERVER=$(grep "^EXPORT_SERVER=" "$IMPORT_DIR/migrate-info.env" | cut -d'=' -f2)
    M_SYSTEM_USER=$(grep "^SYSTEM_USER=" "$IMPORT_DIR/migrate-info.env" | cut -d'=' -f2)
    M_APP_TYPE="${M_APP_TYPE:-wordpress}"
    M_DB_CONNECTION="${M_DB_CONNECTION:-mysql}"

    echo ""
    echo "Migration Package:"
    echo "  Domain     : $M_DOMAIN"
    echo "  App Type   : $M_APP_TYPE"
    echo "  DB Engine  : $M_DB_CONNECTION"
    echo "  Database   : ${M_DB_NAME:-none}"
    echo "  PHP Version: ${M_PHP_VERSION:-N/A}"
    echo "  From Server: $M_EXPORT_SERVER"
    echo ""

    local CLEAN_FOLDER
    CLEAN_FOLDER=$(echo "$M_DOMAIN" | sed 's/[^a-zA-Z0-9]/_/g' | cut -c1-30)
    local TARGET_PATH="$DOMAINS_ROOT/$CLEAN_FOLDER"
    local SYSUSER="${M_SYSTEM_USER:-$CLEAN_FOLDER}"
    local HAS_NGINX_EXPORT=0
    [ -d "$IMPORT_DIR/nginx" ] && HAS_NGINX_EXPORT=1

    if [ -d "$TARGET_PATH" ]; then
        echo -e "\e[33mWARNING: $M_DOMAIN already exists! Will OVERWRITE.\e[0m"
        read -p "Continue? (yes/no): " CONFIRM
        [ "$CONFIRM" != "yes" ] && { rm -rf "$IMPORT_DIR"; return; }
    fi

    read -p "Start import? (y/n): " CONFIRM
    [ "$CONFIRM" != "y" ] && { rm -rf "$IMPORT_DIR"; return; }

    local IMPORT_START
    IMPORT_START=$(date +%s)

    # ── Step 1: Domain structure ──
    echo ""
    echo "[Step 1/6] Creating domain structure..."
    if ! id "$SYSUSER" &>/dev/null; then
        useradd -r -d "$TARGET_PATH" -s /sbin/nologin "$SYSUSER" 2>/dev/null || true
    fi
    mkdir -p "$TARGET_PATH"/{config,public_html,logs,backup/{db,files,full},tmp,sessions}
    chown "$SYSUSER:$SYSUSER" "$TARGET_PATH"
    ok "Domain structure ready"

    # ── Step 2: Config ──
    echo ""
    echo "[Step 2/6] Restoring configuration..."
    if [ -f "$IMPORT_DIR/config/domain.env" ]; then
        cp "$IMPORT_DIR/config/domain.env" "$TARGET_PATH/config/"
        chmod 640 "$TARGET_PATH/config/domain.env"
        # Update SYSTEM_USER in case username differs
        sed -i "s/^SYSTEM_USER=.*/SYSTEM_USER=$SYSUSER/" "$TARGET_PATH/config/domain.env"
        ok "Configuration restored"
    fi

    # ── Step 3: Database ──
    echo ""
    echo "[Step 3/6] Restoring database ($M_DB_CONNECTION)..."
    if [ -f "$IMPORT_DIR/database.sql.gz" ] && [ -n "$M_DB_NAME" ]; then
        local I_DB_NAME I_DB_USER I_DB_PASS
        I_DB_NAME=$(grep "^DB_NAME=" "$TARGET_PATH/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
        I_DB_USER=$(grep "^DB_USER=" "$TARGET_PATH/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
        I_DB_PASS=$(grep "^DB_PASS=" "$TARGET_PATH/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')

        case "$M_DB_CONNECTION" in
            mysql|mariadb)
                if systemctl is-active --quiet mariadb 2>/dev/null; then
                    mysql -e "CREATE DATABASE IF NOT EXISTS \`$I_DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null
                    mysql -e "CREATE USER IF NOT EXISTS '$I_DB_USER'@'localhost' IDENTIFIED BY '$I_DB_PASS';" 2>/dev/null
                    mysql -e "GRANT ALL PRIVILEGES ON \`$I_DB_NAME\`.* TO '$I_DB_USER'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null

                    # Use defaults-extra-file for import
                    local MYCNF
                    MYCNF=$(mktemp /tmp/shieldpress_mycnf_XXXXXX)
                    chmod 600 "$MYCNF"
                    cat > "$MYCNF" <<CNFEOF
[client]
user=$I_DB_USER
password=$I_DB_PASS
CNFEOF
                    gzip -dc "$IMPORT_DIR/database.sql.gz" | mysql --defaults-extra-file="$MYCNF" "$I_DB_NAME"
                    [ $? -eq 0 ] && ok "MariaDB database restored" || fail "MariaDB restore failed"
                    rm -f "$MYCNF"
                else
                    fail "MariaDB is not running!"
                fi
                ;;
            pgsql|postgres|postgresql)
                if systemctl is-active --quiet postgresql 2>/dev/null; then
                    runuser -u postgres -- createuser "$I_DB_USER" 2>/dev/null || true
                    runuser -u postgres -- createdb -O "$I_DB_USER" "$I_DB_NAME" 2>/dev/null || true
                    runuser -u postgres -- psql -c "ALTER USER \"$I_DB_USER\" PASSWORD '$I_DB_PASS';" 2>/dev/null
                    gzip -dc "$IMPORT_DIR/database.sql.gz" | PGPASSWORD="$I_DB_PASS" psql -h 127.0.0.1 -U "$I_DB_USER" -d "$I_DB_NAME" 2>/dev/null
                    [ $? -eq 0 ] && ok "PostgreSQL database restored" || fail "PostgreSQL restore failed"
                else
                    fail "PostgreSQL is not running!"
                fi
                ;;
            *)
                echo "[INFO] Unknown DB engine: $M_DB_CONNECTION, skipping"
                ;;
        esac
    elif [ -f "$IMPORT_DIR/database.skipped" ]; then
        echo "[INFO] No database in package"
    fi

    # ── Step 4: Files ──
    echo ""
    echo "[Step 4/6] Restoring files ($M_APP_TYPE)..."
    if [ -f "$IMPORT_DIR/files.tar.gz" ]; then
        # Detect archive format
        local ARCHIVE_HAS_PUBLIC
        ARCHIVE_HAS_PUBLIC=$(tar -tzf "$IMPORT_DIR/files.tar.gz" 2>/dev/null | head -5 | grep -c "^public_html/")

        if [ "$ARCHIVE_HAS_PUBLIC" -gt 0 ]; then
            # WordPress/PHP: archive contains public_html/ directory
            rm -rf "$TARGET_PATH/public_html"
            tar -xzf "$IMPORT_DIR/files.tar.gz" -C "$TARGET_PATH"
        else
            # Laravel/Node.js: archive contains ./ (files from inside public_html)
            rm -rf "$TARGET_PATH/public_html"
            mkdir -p "$TARGET_PATH/public_html"
            tar -xzf "$IMPORT_DIR/files.tar.gz" -C "$TARGET_PATH/public_html"
        fi

        chown -R "$SYSUSER:$SYSUSER" "$TARGET_PATH/public_html"
        ok "Files restored"
    else
        echo "[INFO] No files in package"
    fi

    # ── Step 5: App-specific post-import ──
    echo ""
    echo "[Step 5/6] Post-import setup ($M_APP_TYPE)..."

    # Restore app-specific config files
    if [ -d "$IMPORT_DIR/app-config" ]; then
        [ -f "$IMPORT_DIR/app-config/dotenv" ] && cp "$IMPORT_DIR/app-config/dotenv" "$TARGET_PATH/public_html/.env"
        [ -f "$IMPORT_DIR/app-config/dotenv.production" ] && cp "$IMPORT_DIR/app-config/dotenv.production" "$TARGET_PATH/public_html/.env.production"
        [ -f "$IMPORT_DIR/app-config/ecosystem.config.js" ] && cp "$IMPORT_DIR/app-config/ecosystem.config.js" "$TARGET_PATH/public_html/"
        [ -f "$IMPORT_DIR/app-config/ecosystem.config.cjs" ] && cp "$IMPORT_DIR/app-config/ecosystem.config.cjs" "$TARGET_PATH/public_html/"
        chown -R "$SYSUSER:$SYSUSER" "$TARGET_PATH/public_html/.env"* 2>/dev/null
        ok "App config files restored"
    fi

    case "$M_APP_TYPE" in
        wordpress)
            # Fix wp-config.php permissions
            [ -f "$TARGET_PATH/public_html/wp-config.php" ] && chmod 640 "$TARGET_PATH/public_html/wp-config.php"
            ok "WordPress ready"
            ;;

        laravel)
            echo "  Rebuilding Laravel..."
            cd "$TARGET_PATH/public_html" || true

            # Composer install
            if [ -f "composer.json" ]; then
                sudo -u "$SYSUSER" composer install --no-dev --optimize-autoloader --no-interaction 2>/dev/null \
                    && ok "composer install" || echo "  [WARN] composer install failed (run manually)"
            fi

            # NPM install
            if [ -f "package.json" ]; then
                sudo -u "$SYSUSER" npm install 2>/dev/null \
                    && ok "npm install" || echo "  [WARN] npm install failed (run manually)"
                # Build if script exists
                if grep -q '"build"' package.json 2>/dev/null; then
                    sudo -u "$SYSUSER" npm run build 2>/dev/null \
                        && ok "npm run build" || echo "  [WARN] npm build failed (run manually)"
                fi
            fi

            # Storage link
            if [ ! -L "public/storage" ]; then
                local PHP_SHORT_L=$(echo "$M_PHP_VERSION" | tr -d '.')
                local PHP_BIN_L="/opt/remi/php${PHP_SHORT_L}/root/usr/bin/php"
                [ -x "$PHP_BIN_L" ] && sudo -u "$SYSUSER" "$PHP_BIN_L" artisan storage:link 2>/dev/null && ok "storage:link"
            fi

            # Key generate (only if APP_KEY is empty)
            if grep -q "^APP_KEY=$" "$TARGET_PATH/public_html/.env" 2>/dev/null; then
                [ -x "$PHP_BIN_L" ] && sudo -u "$SYSUSER" "$PHP_BIN_L" artisan key:generate --force 2>/dev/null && ok "key:generate"
            fi

            # Cache
            [ -x "$PHP_BIN_L" ] && sudo -u "$SYSUSER" "$PHP_BIN_L" artisan config:cache 2>/dev/null
            [ -x "$PHP_BIN_L" ] && sudo -u "$SYSUSER" "$PHP_BIN_L" artisan route:cache 2>/dev/null
            [ -x "$PHP_BIN_L" ] && sudo -u "$SYSUSER" "$PHP_BIN_L" artisan view:cache 2>/dev/null

            chmod -R 775 "$TARGET_PATH/public_html/storage" "$TARGET_PATH/public_html/bootstrap/cache" 2>/dev/null
            ok "Laravel setup complete"
            ;;

        nodejs)
            echo "  Rebuilding Node.js app..."
            cd "$TARGET_PATH/public_html" || true

            # NPM install
            if [ -f "package.json" ]; then
                sudo -u "$SYSUSER" npm install 2>/dev/null \
                    && ok "npm install" || echo "  [WARN] npm install failed (run manually)"

                # Build
                if grep -q '"build"' package.json 2>/dev/null; then
                    sudo -u "$SYSUSER" npm run build 2>/dev/null \
                        && ok "npm run build" || echo "  [WARN] npm build failed (run manually)"
                fi
            fi

            # Prisma generate (if exists)
            if [ -f "prisma/schema.prisma" ]; then
                sudo -u "$SYSUSER" npx prisma generate 2>/dev/null && ok "prisma generate"
            fi

            # PM2 setup
            local PM2_NAME_I
            PM2_NAME_I=$(grep "^PM2_NAME=" "$TARGET_PATH/config/domain.env" 2>/dev/null | cut -d'=' -f2 | tr -d '[:space:]')
            if [ -n "$PM2_NAME_I" ] && command -v pm2 >/dev/null 2>&1; then
                # Try ecosystem file first
                if [ -f "$TARGET_PATH/public_html/ecosystem.config.js" ] || [ -f "$TARGET_PATH/public_html/ecosystem.config.cjs" ]; then
                    local ECO=$(ls "$TARGET_PATH/public_html"/ecosystem.config.* 2>/dev/null | head -1)
                    sudo -u "$SYSUSER" pm2 start "$ECO" 2>/dev/null && ok "PM2 started (ecosystem)"
                else
                    # Detect entry file
                    local ENTRY_FILE=""
                    for ef in server.js index.js app.js .output/server/index.mjs; do
                        [ -f "$TARGET_PATH/public_html/$ef" ] && { ENTRY_FILE="$ef"; break; }
                    done
                    # Next.js standalone
                    [ -f "$TARGET_PATH/public_html/.next/standalone/server.js" ] && ENTRY_FILE=".next/standalone/server.js"

                    if [ -n "$ENTRY_FILE" ]; then
                        local NODE_PORT_I
                        NODE_PORT_I=$(grep "^NODE_PORT=" "$TARGET_PATH/config/domain.env" 2>/dev/null | cut -d'=' -f2 | tr -d '[:space:]')
                        NODE_PORT_I="${NODE_PORT_I:-3000}"
                        sudo -u "$SYSUSER" PORT=$NODE_PORT_I pm2 start "$TARGET_PATH/public_html/$ENTRY_FILE" --name "$PM2_NAME_I" 2>/dev/null \
                            && ok "PM2 started ($ENTRY_FILE on port $NODE_PORT_I)" \
                            || echo "  [WARN] PM2 start failed (run manually)"
                    else
                        echo "  [WARN] No entry file found, PM2 not started"
                    fi
                fi
                sudo -u "$SYSUSER" pm2 save 2>/dev/null
            else
                echo "  [INFO] PM2 not configured or not installed"
            fi

            ok "Node.js setup complete"
            ;;

        *)
            ok "PHP app - no special setup needed"
            ;;
    esac

    # ── Step 6: Nginx + PHP-FPM ──
    echo ""
    echo "[Step 6/6] Restoring server config..."

    # Nginx
    if [ "$HAS_NGINX_EXPORT" -eq 1 ]; then
        cp "$IMPORT_DIR/nginx/"*.conf /etc/nginx/conf.d/ 2>/dev/null
        if nginx -t 2>/dev/null; then
            systemctl reload nginx
            ok "Nginx config restored"
        else
            fail "Nginx config has errors! Fix manually."
        fi
    else
        echo "[INFO] No Nginx config in package - set up via Domain Manager"
    fi

    # PHP-FPM pool (for PHP/WordPress/Laravel)
    if [ "$M_APP_TYPE" != "nodejs" ] && [ -n "$M_PHP_VERSION" ]; then
        local PHP_SHORT_P=$(echo "$M_PHP_VERSION" | tr -d '.')
        local POOL_DIR="/etc/opt/remi/php${PHP_SHORT_P}/php-fpm.d"
        local POOL_FILE="$POOL_DIR/${CLEAN_FOLDER}.conf"

        if [ -d "$POOL_DIR" ] && [ ! -f "$POOL_FILE" ]; then
            local TOTAL_RAM=$(free -m | awk '/Mem:/ {print $2}')
            local PM_MAX=$((TOTAL_RAM / 50))
            [ "$PM_MAX" -lt 5 ] && PM_MAX=5
            [ "$PM_MAX" -gt 100 ] && PM_MAX=100

            cat > "$POOL_FILE" <<POOLEOF
[$CLEAN_FOLDER]
user = $SYSUSER
group = $SYSUSER
listen = /var/opt/remi/php${PHP_SHORT_P}/run/php-fpm/${CLEAN_FOLDER}.sock
listen.owner = nginx
listen.group = nginx
listen.mode = 0660

pm = ondemand
pm.max_children = $PM_MAX
pm.process_idle_timeout = 10s
pm.max_requests = 500

chdir = /

php_admin_value[open_basedir] = $TARGET_PATH:/tmp:/usr/local/bin
php_admin_value[session.save_path] = $TARGET_PATH/sessions
php_admin_value[upload_tmp_dir] = $TARGET_PATH/tmp
php_admin_value[error_log] = $TARGET_PATH/logs/php-error.log
POOLEOF
            systemctl restart "php${PHP_SHORT_P}-php-fpm" 2>/dev/null
            ok "PHP-FPM pool created (php$PHP_SHORT_P)"
        elif [ -f "$POOL_FILE" ]; then
            ok "PHP-FPM pool already exists"
        fi
    fi

    # Cleanup
    rm -rf "$IMPORT_DIR"
    trap - EXIT

    local IMPORT_END DURATION DURATION_FMT
    IMPORT_END=$(date +%s)
    DURATION=$((IMPORT_END - IMPORT_START))
    DURATION_FMT=$(format_duration "$DURATION")

    echo ""
    echo "======================================"
    echo "  IMPORT COMPLETED"
    echo "======================================"
    echo "  Domain   : $M_DOMAIN ($M_APP_TYPE)"
    echo "  Path     : $TARGET_PATH"
    echo "  Duration : $DURATION_FMT"
    echo "======================================"
    echo ""
    echo "Next steps:"
    echo "  1. Point DNS for $M_DOMAIN to this server"
    [ "$HAS_NGINX_EXPORT" -eq 0 ] && echo "  2. Create Nginx config (Domain Manager → Add Domain)"
    echo "  3. Install SSL certificate"
    echo "  4. Test the site: https://$M_DOMAIN"
    echo ""

    log "IMPORT SUCCESS: $M_DOMAIN ($M_APP_TYPE) | Duration: $DURATION_FMT"
}

# =====================================================
# PULL FROM REMOTE
# =====================================================

pull_from_remote(){
    echo ""
    echo "======================================"
    echo "  PULL DOMAIN FROM REMOTE SERVER"
    echo "======================================"
    echo ""
    echo "Connect to remote ShieldPress server via SSH,"
    echo "export a domain, download and import it here."
    echo ""

    read -p "Remote server (user@host): " REMOTE_HOST
    [ -z "$REMOTE_HOST" ] && { echo "Cancelled."; return; }

    read -p "Remote domain to migrate: " REMOTE_DOMAIN
    [ -z "$REMOTE_DOMAIN" ] && { echo "Cancelled."; return; }

    echo ""
    echo "Testing SSH connection..."
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$REMOTE_HOST" "echo ok" &>/dev/null; then
        fail "Cannot connect to $REMOTE_HOST"
        echo "  1. Set up SSH key: ssh-copy-id $REMOTE_HOST"
        echo "  2. Check server is reachable"
        return 1
    fi
    ok "SSH connected"

    if ! ssh "$REMOTE_HOST" "[ -f /opt/shieldpress/modules/tools/migrate.sh ]" 2>/dev/null; then
        fail "Migration tool not found on remote! Update ShieldPress first."
        return 1
    fi
    ok "Remote ShieldPress found"

    local REMOTE_CLEAN
    REMOTE_CLEAN=$(echo "$REMOTE_DOMAIN" | sed 's/[^a-zA-Z0-9]/_/g' | cut -c1-30)
    if ! ssh "$REMOTE_HOST" "[ -d /home/domains/$REMOTE_CLEAN ]" 2>/dev/null; then
        fail "Domain $REMOTE_DOMAIN not found on remote!"
        return 1
    fi
    ok "Domain found"

    read -p "Start migration? (y/n): " CONFIRM
    [ "$CONFIRM" != "y" ] && return

    echo ""
    echo "Exporting on remote..."
    local REMOTE_EXPORT
    REMOTE_EXPORT=$(ssh "$REMOTE_HOST" "bash /opt/shieldpress/modules/tools/migrate.sh --export-auto $REMOTE_DOMAIN 2>/dev/null | tail -1")

    if [ -z "$REMOTE_EXPORT" ] || ! ssh "$REMOTE_HOST" "[ -f '$REMOTE_EXPORT' ]" 2>/dev/null; then
        fail "Remote export failed!"
        return 1
    fi
    ok "Remote export: $(basename "$REMOTE_EXPORT")"

    echo "Downloading..."
    local LOCAL_FILE="$MIGRATE_DIR/$(basename "$REMOTE_EXPORT")"
    scp "$REMOTE_HOST:$REMOTE_EXPORT" "$LOCAL_FILE"
    [ $? -ne 0 ] && { fail "Download failed!"; return 1; }
    ok "Downloaded: $(du -h "$LOCAL_FILE" | awk '{print $1}')"

    ssh "$REMOTE_HOST" "rm -f '$REMOTE_EXPORT'" 2>/dev/null

    echo ""
    echo "Starting import..."
    import_domain
}

# =====================================================
# NON-INTERACTIVE EXPORT (for remote pull)
# =====================================================

if [ "$1" = "--export-auto" ] && [ -n "$2" ]; then
    DOMAIN_NAME="$2"
    CLEAN_FOLDER=$(echo "$DOMAIN_NAME" | sed 's/[^a-zA-Z0-9]/_/g' | cut -c1-30)
    DOMAIN_PATH="$DOMAINS_ROOT/$CLEAN_FOLDER"

    [ ! -d "$DOMAIN_PATH" ] && { echo "FAIL: Domain not found"; exit 1; }

    load_domain_info "$DOMAIN_PATH"

    DATE=$(date +%F_%H-%M-%S)
    EXPORT_DIR=$(mktemp -d "$MIGRATE_DIR/export_XXXXXX")
    EXPORT_FILE="$MIGRATE_DIR/${DOMAIN}_migrate_${DATE}.tar.gz"

    # Config
    mkdir -p "$EXPORT_DIR/config"
    cp "$DOMAIN_PATH/config/domain.env" "$EXPORT_DIR/config/"

    # Database
    if [ -n "$DB_NAME" ] && [ "$DB_CONNECTION" != "none" ] && database_exists_for_backup; then
        backup_db_to_file "$EXPORT_DIR/database.sql.gz" >/dev/null 2>&1
    fi

    # Files
    if [ -d "$DOMAIN_PATH/public_html" ]; then
        archive_source_to_file "$EXPORT_DIR/files.tar.gz" >/dev/null 2>&1
    fi

    # Nginx
    NGINX_CONF="/etc/nginx/conf.d/${CLEAN_FOLDER}.conf"
    [ -f "$NGINX_CONF" ] && { mkdir -p "$EXPORT_DIR/nginx"; cp "$NGINX_CONF" "$EXPORT_DIR/nginx/"; }

    # App-specific
    if [ "$APP_TYPE" = "nodejs" ] || [ "$APP_TYPE" = "laravel" ]; then
        mkdir -p "$EXPORT_DIR/app-config"
        [ -f "$DOMAIN_PATH/public_html/.env" ] && cp "$DOMAIN_PATH/public_html/.env" "$EXPORT_DIR/app-config/dotenv"
        [ -f "$DOMAIN_PATH/public_html/.env.production" ] && cp "$DOMAIN_PATH/public_html/.env.production" "$EXPORT_DIR/app-config/dotenv.production"
        for ef in "$DOMAIN_PATH/public_html"/ecosystem.config.*; do
            [ -f "$ef" ] && cp "$ef" "$EXPORT_DIR/app-config/"
        done
    fi

    # Metadata
    cat > "$EXPORT_DIR/migrate-info.env" <<METAEOF
SHIELDPRESS_VERSION=$(cat "$BASE_DIR/version.txt" 2>/dev/null | tr -d '[:space:]')
EXPORT_DATE=$(date '+%Y-%m-%d %H:%M:%S')
EXPORT_SERVER=$(hostname -f 2>/dev/null || hostname)
DOMAIN=$DOMAIN
APP_TYPE=$APP_TYPE
DB_CONNECTION=$DB_CONNECTION
DB_NAME=$DB_NAME
PHP_VERSION=$PHP_VERSION
SYSTEM_USER=$SYSTEM_USER
METAEOF

    tar -czf "$EXPORT_FILE" -C "$EXPORT_DIR" .
    rm -rf "$EXPORT_DIR"

    echo "$EXPORT_FILE"
    exit 0
fi

# =====================================================
# MENU
# =====================================================

while true; do
    clear
    sp_header "Server Migration" "Export/Import domains between servers"

    PACKAGE_COUNT=$(find "$MIGRATE_DIR" -name "*_migrate_*" -type f 2>/dev/null | wc -l)
    echo "  Migration packages: $PACKAGE_COUNT"
    echo "  Supports: WordPress, Laravel, Node.js, PHP"
    echo ""

    sp_menu_grid \
        "1|Export Domain|green" \
        "2|Import Domain|blue" \
        "3|Pull from Remote (SSH)|magenta" \
        "4|List Packages|cyan" \
        "5|Delete Package|red" \
        "0|Back|white"
    sp_prompt opt

    case $opt in
        1) export_domain; read -p "Enter..." ;;
        2) import_domain; read -p "Enter..." ;;
        3) pull_from_remote; read -p "Enter..." ;;
        4)
            echo ""
            echo "Migration packages in $MIGRATE_DIR:"
            echo "--------------------------------"
            ls -lh "$MIGRATE_DIR"/*_migrate_* 2>/dev/null || echo "No packages found."
            echo ""
            read -p "Enter..."
            ;;
        5)
            echo ""
            PKGS=()
            pi=1
            for f in "$MIGRATE_DIR"/*_migrate_*; do
                [ -f "$f" ] || continue
                echo "$pi) $(basename "$f")  [$(du -h "$f" | awk '{print $1}')]"
                PKGS[$pi]="$f"
                ((pi++))
            done
            [ $pi -eq 1 ] && { echo "No packages."; read -p "Enter..."; continue; }
            read -p "Delete which? " dchoice
            [ -n "${PKGS[$dchoice]}" ] && { rm -f "${PKGS[$dchoice]}"; echo "[OK] Deleted"; } || echo "Invalid"
            read -p "Enter..."
            ;;
        0) break ;;
        *) sp_invalid ;;
    esac
done
