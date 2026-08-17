#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
DOMAIN_MODULE="$BASE_DIR/modules/domain"
LARAVEL_DB_DIR="$DATA_DIR_LARAVEL_DB"
LARAVEL_BACKUP_DIR="$BACKUP_GLOBAL_DIR/laravel-postgresql"
LARAVEL_BIN_DIR="$BASE_DIR/bin"
LARAVEL_PG_BACKUP_SCRIPT="$LARAVEL_BIN_DIR/laravel-pg-backup"

source "$DOMAIN_MODULE/helpers.sh"
source "$BASE_DIR/core/ui.sh"

mkdir -p "$LARAVEL_DB_DIR" "$LARAVEL_BACKUP_DIR" "$LARAVEL_BIN_DIR"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
RESET="\e[0m"

ok(){ echo -e "${GREEN}[OK]${RESET} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $1"; }
fail(){ echo -e "${RED}[FAIL]${RESET} $1"; }
pause(){ echo ""; read -p "Press Enter..."; }

ensure_pg_backup_script(){
    cat > "$LARAVEL_PG_BACKUP_SCRIPT" <<'EOF'
#!/bin/bash
set -e

DB_NAME="$1"
BASE_DIR="/opt/shieldpress"
DB_META="/var/shieldpress/data/laravel-databases/${DB_NAME}.env"
BACKUP_DIR="/home/backup-all/laravel-postgresql/${DB_NAME}"

[ -n "$DB_NAME" ] || { echo "Usage: laravel-pg-backup <db_name>"; exit 1; }
[ -f "$DB_META" ] || { echo "Database metadata not found: $DB_META"; exit 1; }

mkdir -p "$BACKUP_DIR"
BACKUP_FILE="$BACKUP_DIR/${DB_NAME}_$(date '+%Y%m%d_%H%M%S').sql.gz"

cd /tmp && runuser -u postgres -- pg_dump "$DB_NAME" | gzip > "$BACKUP_FILE"
chmod 600 "$BACKUP_FILE"

find "$BACKUP_DIR" -type f -name "${DB_NAME}_*.sql.gz" -mtime +14 -delete
echo "$BACKUP_FILE"
EOF
    chmod +x "$LARAVEL_PG_BACKUP_SCRIPT"
}

postgresql_ready(){
    command -v psql >/dev/null 2>&1 &&
        systemctl is-active --quiet postgresql &&
        [ -f /var/lib/pgsql/data/PG_VERSION ]
}

configure_shieldpress_postgresql(){
    local PG_CONF="/var/lib/pgsql/data/postgresql.conf"
    local PG_HBA="/var/lib/pgsql/data/pg_hba.conf"
    local TOTAL_RAM PG_SHARED_BUFFERS PG_EFFECTIVE_CACHE PG_WORK_MEM PG_MAINT_WORK_MEM

    if [ ! -f /var/lib/pgsql/data/PG_VERSION ]; then
        postgresql-setup --initdb || return 1
    fi

    if [ -f "$PG_CONF" ]; then
        sed -i '/^# SHIELDPRESS PostgreSQL tuning/,$d' "$PG_CONF"
        sed -i "s/^[#[:space:]]*listen_addresses[[:space:]]*=.*/listen_addresses = '127.0.0.1'/" "$PG_CONF"
        grep -q "^listen_addresses = '127.0.0.1'" "$PG_CONF" || echo "listen_addresses = '127.0.0.1'" >> "$PG_CONF"
        sed -i '/^[#[:space:]]*password_encryption[[:space:]]*=/d' "$PG_CONF"
        echo "password_encryption = 'scram-sha-256'" >> "$PG_CONF"
    fi

    if [ -f "$PG_HBA" ] && ! grep -q "SHIELDPRESS PostgreSQL auth" "$PG_HBA"; then
        {
            echo "# SHIELDPRESS PostgreSQL auth"
            echo "host all all 127.0.0.1/32 scram-sha-256"
            echo "host all all ::1/128 scram-sha-256"
            cat "$PG_HBA"
        } > "${PG_HBA}.tmp"
        mv "${PG_HBA}.tmp" "$PG_HBA"
        chown postgres:postgres "$PG_HBA"
    fi

    TOTAL_RAM=$(free -m | awk '/Mem:/ {print $2}')
    PG_SHARED_BUFFERS=$((TOTAL_RAM * 20 / 100))
    PG_EFFECTIVE_CACHE=$((TOTAL_RAM * 50 / 100))
    PG_WORK_MEM=$((TOTAL_RAM / 256))
    PG_MAINT_WORK_MEM=$((TOTAL_RAM / 16))

    [ "$PG_SHARED_BUFFERS" -lt 128 ] && PG_SHARED_BUFFERS=128
    [ "$PG_SHARED_BUFFERS" -gt 2048 ] && PG_SHARED_BUFFERS=2048
    [ "$PG_EFFECTIVE_CACHE" -lt 512 ] && PG_EFFECTIVE_CACHE=512
    [ "$PG_EFFECTIVE_CACHE" -gt 8192 ] && PG_EFFECTIVE_CACHE=8192
    [ "$PG_WORK_MEM" -lt 4 ] && PG_WORK_MEM=4
    [ "$PG_WORK_MEM" -gt 32 ] && PG_WORK_MEM=32
    [ "$PG_MAINT_WORK_MEM" -lt 64 ] && PG_MAINT_WORK_MEM=64
    [ "$PG_MAINT_WORK_MEM" -gt 512 ] && PG_MAINT_WORK_MEM=512

    if [ -f "$PG_CONF" ]; then
        cat >> "$PG_CONF" <<EOF

# SHIELDPRESS PostgreSQL tuning
shared_buffers = ${PG_SHARED_BUFFERS}MB
effective_cache_size = ${PG_EFFECTIVE_CACHE}MB
work_mem = ${PG_WORK_MEM}MB
maintenance_work_mem = ${PG_MAINT_WORK_MEM}MB
max_connections = 100
checkpoint_completion_target = 0.9
wal_buffers = 16MB
random_page_cost = 1.1
EOF
    fi
}

install_postgresql_stack(){
    echo "Installing PostgreSQL..."
    dnf install -y postgresql-server postgresql-contrib || return 1
    configure_shieldpress_postgresql || return 1
    systemctl enable postgresql >/dev/null 2>&1
    systemctl restart postgresql || return 1
    ok "PostgreSQL installed and configured with scram-sha-256"
}

install_laravel_runtime(){
    local php_ok=0 composer_ok=0 node_ok=0 missing=()
    local node_major

    [ -x /opt/remi/php84/root/usr/bin/php ] && php_ok=1
    command -v composer >/dev/null 2>&1 && composer_ok=1
    node_major=$(node -p "process.versions.node.split('.')[0]" 2>/dev/null || echo 0)
    [ "$node_major" -ge 20 ] && node_ok=1

    [ "$php_ok" = "1" ] || missing+=("PHP 8.4")
    [ "$composer_ok" = "1" ] || missing+=("Composer")
    [ "$node_ok" = "1" ] || missing+=("Node.js 20+")

    if [ ${#missing[@]} -eq 0 ]; then
        ok "Laravel runtime already installed. No setup needed."
        echo "PHP      : $(/opt/remi/php84/root/usr/bin/php -r 'echo PHP_VERSION;' 2>/dev/null)"
        echo "Composer : $(composer --version 2>/dev/null)"
        echo "Node.js  : $(node -v 2>/dev/null)"
        echo "Postgres : $(postgresql_ready && echo active || echo not-installed)"
        return 0
    fi

    warn "Missing runtime: ${missing[*]}"
    read -p "Install missing Laravel runtime components now? [y/N]: " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { warn "Cancelled"; return 0; }

    echo "Installing missing Laravel 13 runtime components..."

    dnf install -y dnf-plugins-core curl unzip git firewalld policycoreutils-python-utils || return 1
    dnf config-manager --set-enabled crb >/dev/null 2>&1 || true

    if ! rpm -q remi-release >/dev/null 2>&1; then
        source /etc/os-release
        ALMA_VERSION=$(echo "$VERSION_ID" | cut -d'.' -f1)
        dnf install -y "https://rpms.remirepo.net/enterprise/remi-release-${ALMA_VERSION}.rpm" || return 1
    fi

    ensure_php_version_installed "8.4" || return 1

    install_shieldpress_nodejs || return 1

    PHP84_BIN="/opt/remi/php84/root/usr/bin/php"
    if [ -x "$PHP84_BIN" ]; then
        ln -sf "$PHP84_BIN" /usr/local/bin/php
    fi

    if ! command -v composer >/dev/null 2>&1; then
        COMPOSER_SETUP="/tmp/composer-setup.php"
        EXPECTED_SIGNATURE=$(curl -fsSL https://composer.github.io/installer.sig)
        curl -fsSL https://getcomposer.org/installer -o "$COMPOSER_SETUP"
        ACTUAL_SIGNATURE=$(php -r "echo hash_file('sha384', '$COMPOSER_SETUP');")

        if [ "$EXPECTED_SIGNATURE" = "$ACTUAL_SIGNATURE" ]; then
            php "$COMPOSER_SETUP" --install-dir=/usr/local/bin --filename=composer
            chmod +x /usr/local/bin/composer
        else
            rm -f "$COMPOSER_SETUP"
            fail "Composer installer signature mismatch"
            return 1
        fi

        rm -f "$COMPOSER_SETUP"
    fi

    mkdir -p /etc/shieldpress
    cat > /etc/shieldpress/laravel-runtime.env <<EOF
INSTALLED=1
PHP_VERSION=8.4
NODE_MAJOR=$(node -p "process.versions.node.split('.')[0]" 2>/dev/null || echo 0)
UPDATED=$(date '+%Y-%m-%d %H:%M:%S')
EOF

    ok "Laravel runtime ready: PHP $(php -r 'echo PHP_VERSION;' 2>/dev/null), Composer $(composer --version 2>/dev/null | awk '{print $3}'), Node $(node -v 2>/dev/null)"
}

select_laravel_domain(){
    DOMAIN_CHOICES=()
    local i=1

    echo ""
    echo "Laravel Domains:"
    echo "--------------------------------"
    for env in "$DOMAINS_ROOT"/*/config/domain.env; do
        [ -f "$env" ] || continue
        APP_TYPE=$(grep "^APP_TYPE=" "$env" | cut -d= -f2)
        [ "$APP_TYPE" = "laravel" ] || continue
        DOMAIN=$(grep "^DOMAIN=" "$env" | cut -d= -f2)
        echo "$i) $DOMAIN"
        DOMAIN_CHOICES[$i]=$(dirname "$(dirname "$env")")
        ((i++))
    done

    [ $i -eq 1 ] && { warn "No Laravel domains found"; return 1; }

    read -p "Select: " choice
    DOMAIN_PATH="${DOMAIN_CHOICES[$choice]}"
    [ -n "$DOMAIN_PATH" ] || { fail "Invalid selection"; return 1; }

    ENV_FILE="$DOMAIN_PATH/config/domain.env"
    DOMAIN=$(grep "^DOMAIN=" "$ENV_FILE" | cut -d= -f2)
    CLEAN_DOMAIN=$(basename "$DOMAIN_PATH")
    ROOT=$(grep "^ROOT=" "$ENV_FILE" | cut -d= -f2)
    PHP_VERSION=$(grep "^PHP_VERSION=" "$ENV_FILE" | cut -d= -f2)
    PHP_SHORT=$(php_version_to_short "$PHP_VERSION")
    return 0
}

list_laravel_domains(){
    echo ""
    echo "Laravel Domains:"
    echo "--------------------------------"
    for env in "$DOMAINS_ROOT"/*/config/domain.env; do
        [ -f "$env" ] || continue
        APP_TYPE=$(grep "^APP_TYPE=" "$env" | cut -d= -f2)
        [ "$APP_TYPE" = "laravel" ] || continue
        DOMAIN=$(grep "^DOMAIN=" "$env" | cut -d= -f2)
        ROOT=$(grep "^ROOT=" "$env" | cut -d= -f2)
        DB_NAME=$(grep "^DB_NAME=" "$env" | cut -d= -f2)
        PHP_VERSION=$(grep "^PHP_VERSION=" "$env" | cut -d= -f2)
        echo "$DOMAIN | PHP $PHP_VERSION | DB $DB_NAME | root $ROOT"
    done
}

create_laravel_domain(){
    ADD_DOMAIN_APP=laravel bash "$DOMAIN_MODULE/add-domain.sh"
}

create_pg_database_only(){
    if ! postgresql_ready; then
        warn "PostgreSQL is not installed or not running."
        warn "Use Laravel Manager -> Install PostgreSQL first."
        return 1
    fi

    read -p "Database name: " DB_NAME
    DB_NAME=$(echo "$DB_NAME" | tr -cd 'A-Za-z0-9_')
    [ -n "$DB_NAME" ] || { fail "Database name required"; return 1; }
    if [[ "$DB_NAME" =~ ^[0-9] ]]; then
        DB_NAME="db_${DB_NAME}"
    fi

    DB_USER="${DB_NAME}_user"
    DB_USER=$(echo "$DB_USER" | cut -c1-60)
    DB_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
    DB_META="$LARAVEL_DB_DIR/${DB_NAME}.env"

    if [ -f "$DB_META" ]; then
        fail "Database is already tracked: $DB_NAME"
        return 1
    fi

    systemctl start postgresql >/dev/null 2>&1 || return 1
    cd /tmp
    runuser -u postgres -- psql -c "SET password_encryption = 'scram-sha-256';" >/dev/null 2>&1 || true
    runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1 || \
        runuser -u postgres -- psql -c "CREATE USER \"${DB_USER}\" WITH PASSWORD '${DB_PASS}';" >/dev/null
    runuser -u postgres -- psql -c "SET password_encryption = 'scram-sha-256'; ALTER USER \"${DB_USER}\" WITH PASSWORD '${DB_PASS}';" >/dev/null
    runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 || \
        runuser -u postgres -- createdb -O "$DB_USER" "$DB_NAME"

    cat > "$DB_META" <<EOF
DB_CONNECTION=pgsql
DB_HOST=127.0.0.1
DB_PORT=5432
DB_DATABASE=$DB_NAME
DB_USERNAME=$DB_USER
DB_PASSWORD=$DB_PASS
CREATED=$(date '+%Y-%m-%d %H:%M:%S')
EOF
    chmod 600 "$DB_META"

    ok "PostgreSQL DB created and saved"
    echo "DB_DATABASE=$DB_NAME"
    echo "DB_USERNAME=$DB_USER"
    echo "DB_PASSWORD=$DB_PASS"
}

list_pg_databases(){
    echo ""
    echo "Tracked Laravel PostgreSQL Databases:"
    echo "--------------------------------"
    local found=0
    for meta in "$LARAVEL_DB_DIR"/*.env; do
        [ -f "$meta" ] || continue
        found=1
        DB_NAME=$(grep "^DB_DATABASE=" "$meta" | cut -d= -f2)
        DB_USER=$(grep "^DB_USERNAME=" "$meta" | cut -d= -f2)
        CREATED=$(grep "^CREATED=" "$meta" | cut -d= -f2-)
        echo "$DB_NAME | user $DB_USER | created $CREATED"
    done

    [ "$found" = "0" ] && warn "No tracked Laravel DB found"
}

select_pg_database(){
    DB_CHOICES=()
    local i=1

    echo ""
    echo "Tracked Laravel PostgreSQL Databases:"
    echo "--------------------------------"
    for meta in "$LARAVEL_DB_DIR"/*.env; do
        [ -f "$meta" ] || continue
        DB_NAME=$(grep "^DB_DATABASE=" "$meta" | cut -d= -f2)
        echo "$i) $DB_NAME"
        DB_CHOICES[$i]="$meta"
        ((i++))
    done

    [ $i -eq 1 ] && { warn "No tracked Laravel DB found"; return 1; }

    read -p "Select: " choice
    DB_META="${DB_CHOICES[$choice]}"
    [ -n "$DB_META" ] || { fail "Invalid selection"; return 1; }

    DB_NAME=$(grep "^DB_DATABASE=" "$DB_META" | cut -d= -f2)
    DB_USER=$(grep "^DB_USERNAME=" "$DB_META" | cut -d= -f2)
    DB_PASS=$(grep "^DB_PASSWORD=" "$DB_META" | cut -d= -f2)
    return 0
}

view_pg_database(){
    select_pg_database || return
    echo ""
    echo "Database info:"
    echo "--------------------------------"
    cat "$DB_META"
}

delete_pg_database(){
    select_pg_database || return
    echo ""
    echo -e "\e[31mWARNING: This will permanently drop database '$DB_NAME' and user '$DB_USER'!\e[0m"
    read -p "Continue? (y/n): " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { warn "Cancelled"; return; }

    cd /tmp
    runuser -u postgres -- dropdb --if-exists "$DB_NAME" 2>/dev/null || true
    runuser -u postgres -- dropuser --if-exists "$DB_USER" 2>/dev/null || true
    rm -f "$DB_META"
    ok "Database deleted: $DB_NAME"
}

change_pg_database_password(){
    select_pg_database || return

    if ! postgresql_ready; then
        warn "PostgreSQL is not installed or not running."
        return 1
    fi

    echo ""
    read -p "Generate random password? [Y/n]: " RANDOM_PASS
    RANDOM_PASS="${RANDOM_PASS:-Y}"

    if [[ "$RANDOM_PASS" =~ ^[Yy]$ ]]; then
        NEW_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
    else
        read -s -p "New password: " NEW_PASS
        echo ""
        read -s -p "Confirm password: " CONFIRM_PASS
        echo ""
        [ "$NEW_PASS" = "$CONFIRM_PASS" ] || { fail "Password confirmation does not match"; return 1; }
        [ -n "$NEW_PASS" ] || { fail "Password cannot be empty"; return 1; }
    fi

    cd /tmp
    runuser -u postgres -- psql -c "SET password_encryption = 'scram-sha-256'; ALTER USER \"${DB_USER}\" WITH PASSWORD '${NEW_PASS}';" >/dev/null || {
        fail "Failed to change PostgreSQL password"
        return 1
    }

    if grep -q "^DB_PASSWORD=" "$DB_META"; then
        sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=$NEW_PASS/" "$DB_META"
    else
        echo "DB_PASSWORD=$NEW_PASS" >> "$DB_META"
    fi

    chmod 600 "$DB_META"
    ok "PostgreSQL password changed"
    echo "DB_DATABASE=$DB_NAME"
    echo "DB_USERNAME=$DB_USER"
    echo "DB_PASSWORD=$NEW_PASS"
}

backup_pg_database(){
    select_pg_database || return
    ensure_pg_backup_script
    BACKUP_FILE=$("$LARAVEL_PG_BACKUP_SCRIPT" "$DB_NAME") || {
        fail "Backup failed"
        return 1
    }

    ok "Backup created: $BACKUP_FILE"
}

configure_pg_auto_backup(){
    select_pg_database || return
    read -p "Backup time HH:MM [02:30]: " BACKUP_TIME
    BACKUP_TIME="${BACKUP_TIME:-02:30}"

    if ! [[ "$BACKUP_TIME" =~ ^[0-9]{2}:[0-9]{2}$ ]]; then
        fail "Invalid time format"
        return 1
    fi

    HOUR="${BACKUP_TIME%%:*}"
    MINUTE="${BACKUP_TIME##*:}"
    CRON_TAG="SHIELDPRESS_LARAVEL_PG_BACKUP_${DB_NAME}"
    ensure_pg_backup_script
    CRON_CMD="$MINUTE $HOUR * * * $LARAVEL_PG_BACKUP_SCRIPT '$DB_NAME' >/dev/null 2>&1 # $CRON_TAG"

    (crontab -l 2>/dev/null | grep -v "$CRON_TAG"; echo "$CRON_CMD") | crontab -
    ok "Auto backup enabled for $DB_NAME at $BACKUP_TIME daily"
}

list_pg_backups(){
    echo ""
    echo "Laravel PostgreSQL Backups:"
    echo "--------------------------------"
    find "$LARAVEL_BACKUP_DIR" -type f -name "*.sql.gz" 2>/dev/null | sort
}

import_pg_database(){
    if ! postgresql_ready; then
        warn "PostgreSQL is not installed or not running."
        return 1
    fi

    select_pg_database || return

    echo ""
    echo "Import SQL into PostgreSQL database: $DB_NAME"
    echo "--------------------------------"
    read -p "Enter full path to .sql or .sql.gz file: " FILE

    if [[ ! -f "$FILE" ]]; then
        fail "File not found: $FILE"
        return 1
    fi

    FILE_SIZE=$(du -h "$FILE" | awk '{print $1}')
    echo "File size: $FILE_SIZE"

    echo ""
    read -p "Backup database before import? (y/n): " BACKUP_CONFIRM
    if [[ "$BACKUP_CONFIRM" == "y" ]]; then
        echo "Creating backup..."
        ensure_pg_backup_script
        BACKUP_FILE=$("$LARAVEL_PG_BACKUP_SCRIPT" "$DB_NAME") || {
            fail "Backup failed"
            return 1
        }
        ok "Backup saved: $BACKUP_FILE"
    fi

    echo ""
    read -p "Confirm import into '$DB_NAME'? This may overwrite data (y/n): " CONFIRM
    [[ "$CONFIRM" == "y" ]] || { warn "Cancelled"; return; }

    echo ""
    echo "Starting import..."

    local START_TIME=$(date +%s)

    if [[ "$FILE" == *.gz ]]; then
        if command -v pv >/dev/null 2>&1; then
            pv "$FILE" | gunzip | PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -q
        else
            gunzip < "$FILE" | PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -q
        fi
    else
        if command -v pv >/dev/null 2>&1; then
            pv "$FILE" | PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -q
        else
            PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -q < "$FILE"
        fi
    fi

    if [[ $? -ne 0 ]]; then
        fail "Import failed"
        return 1
    fi

    local END_TIME=$(date +%s)
    local DURATION=$((END_TIME - START_TIME))

    echo ""
    ok "Import Completed Successfully!"
    echo "  Database : $DB_NAME"
    echo "  File     : $FILE"
    echo "  Duration : ${DURATION}s"
}

edit_laravel_env(){
    select_laravel_domain || return
    ENV="$DOMAIN_PATH/public_html/.env"
    [ -f "$ENV" ] || { fail ".env not found: $ENV"; return 1; }
    ${EDITOR:-nano} "$ENV"
}

run_artisan(){
    select_laravel_domain || return
    read -p "Artisan command (example: migrate --force): php artisan " ARTISAN_CMD
    [ -n "$ARTISAN_CMD" ] || return
    cd "$DOMAIN_PATH/public_html" || return
    php artisan $ARTISAN_CMD
}

run_laravel_command(){
    select_laravel_domain || return
    cd "$DOMAIN_PATH/public_html" || return

    case "$1" in
        migrate) php artisan migrate --force ;;
        rollback)
            echo -e "\e[31mWARNING: This can revert production schema!\e[0m"
            read -p "Continue? (y/n): " CONFIRM
            [[ "$CONFIRM" =~ ^[Yy]$ ]] || { warn "Cancelled"; return; }
            php artisan migrate:rollback
            ;;
        seed)
            echo -e "\e[31mWARNING: This can change production data!\e[0m"
            read -p "Continue? (y/n): " CONFIRM
            [[ "$CONFIRM" =~ ^[Yy]$ ]] || { warn "Cancelled"; return; }
            php artisan db:seed --force
            ;;
        storage) php artisan storage:link ;;
        key) php artisan key:generate ;;
        clear)
            php artisan optimize:clear
            ok "Laravel cache cleared"
            ;;
        optimize)
            php artisan config:cache
            php artisan route:cache
            php artisan view:cache
            ok "Laravel cache optimized"
            ;;
        queue-once) php artisan queue:work --once ;;
        queue-restart) php artisan queue:restart ;;
        schedule) php artisan schedule:run ;;
        about) php artisan about ;;
        routes) php artisan route:list ;;
        npm-install) npm install ;;
        npm-build) npm install && npm run build ;;
        composer-install) COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader ;;
        *) warn "Unknown Laravel command" ;;
    esac
}

install_laravel_components(){
    select_laravel_domain || return
    cd "$DOMAIN_PATH/public_html" || return

    echo "Installing Laravel components..."

    if [ -f composer.json ]; then
        COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader || {
            fail "Composer install failed"
            return 1
        }
        ok "Composer packages installed"
    else
        warn "composer.json not found, skipping"
    fi

    if [ -f package.json ]; then
        npm install || {
            fail "npm install failed"
            return 1
        }
        ok "npm packages installed"
    else
        warn "package.json not found, skipping"
    fi

    ok "Components installed"
}

npm_run_build(){
    select_laravel_domain || return
    cd "$DOMAIN_PATH/public_html" || return

    if [ ! -f package.json ]; then
        fail "package.json not found"
        return 1
    fi

    npm run build || {
        fail "npm run build failed"
        return 1
    }
    ok "npm run build completed"
}

deploy_laravel_production(){
    select_laravel_domain || return
    cd "$DOMAIN_PATH/public_html" || return

    echo "=== Deploy / Build Production ==="
    echo ""

    # 1. Composer install
    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader || return

    # 2. npm install + build
    if [ -f package.json ]; then
        npm install || return
        npm run build || return
    fi

    # 3. Migration
    php artisan migrate --force || {
        warn "Migration failed or skipped"
    }

    # 4. Clear & optimize cache
    php artisan optimize:clear
    php artisan config:cache
    php artisan route:cache
    php artisan view:cache

    ok "Laravel production deploy/build completed (composer + npm + migrate + cache)"
}

fix_laravel_permissions(){
    FIX_APP_TYPE=laravel bash "$DOMAIN_MODULE/fix-permission.sh"
}

# =================================================
# REDIS / VALKEY CACHE FOR LARAVEL
# =================================================

install_laravel_redis(){
    echo ""
    echo "========================================="
    echo "  INSTALL REDIS (VALKEY) FOR LARAVEL"
    echo "========================================="
    echo ""

    # 1. Install Valkey server
    if ! command -v valkey-cli >/dev/null 2>&1; then
        echo "Installing Valkey server..."
        dnf install -y valkey || { fail "Valkey installation failed"; return 1; }
        systemctl enable valkey >/dev/null 2>&1
        systemctl start valkey || { fail "Valkey start failed"; return 1; }
        ok "Valkey server installed"
    else
        ok "Valkey server already installed"
        if ! systemctl is-active --quiet valkey 2>/dev/null; then
            systemctl start valkey
            ok "Valkey started"
        fi
    fi

    # 2. Install phpredis extension for PHP 8.4
    PHP84_BIN="/opt/remi/php84/root/usr/bin/php"
    if [ -x "$PHP84_BIN" ]; then
        if ! "$PHP84_BIN" -m 2>/dev/null | grep -qi redis; then
            echo "Installing PHP 8.4 redis extension..."
            dnf install -y php84-php-pecl-redis >/dev/null 2>&1 || {
                fail "phpredis installation failed"
                return 1
            }
            systemctl restart php84-php-fpm 2>/dev/null
            ok "PHP 8.4 redis extension installed"
        else
            ok "PHP 8.4 redis extension already installed"
        fi
    else
        warn "PHP 8.4 not found, skipping phpredis"
    fi

    # 3. Verify connection
    if valkey-cli ping 2>/dev/null | grep -qi pong; then
        ok "Valkey is responding (PONG)"
    else
        fail "Valkey not responding"
        return 1
    fi

    echo ""
    ok "Redis (Valkey) ready for Laravel"
    echo ""
    echo "  Host : 127.0.0.1"
    echo "  Port : 6379"
    echo "  Use  : REDIS_HOST=127.0.0.1 in your .env"
}

configure_laravel_redis(){
    select_laravel_domain || return

    local ENV="$DOMAIN_PATH/public_html/.env"
    [ -f "$ENV" ] || { fail ".env not found: $ENV"; return 1; }

    if ! command -v valkey-cli >/dev/null 2>&1 || ! systemctl is-active --quiet valkey 2>/dev/null; then
        warn "Valkey is not installed or not running."
        read -p "Install Valkey now? [Y/n]: " INSTALL_CONFIRM
        INSTALL_CONFIRM="${INSTALL_CONFIRM:-Y}"
        if [[ "$INSTALL_CONFIRM" =~ ^[Yy]$ ]]; then
            install_laravel_redis || return 1
        else
            warn "Cancelled. Install Valkey first."
            return 1
        fi
    fi

    echo ""
    echo "Configure Redis cache for: $DOMAIN"
    echo "================================="
    echo ""
    echo "Select cache driver to configure:"
    echo "1) Session + Cache + Queue (all Redis)"
    echo "2) Cache only"
    echo "3) Session only"
    echo "4) Queue only"
    echo "5) Custom (choose individually)"
    echo "0) Cancel"
    read -p "Select: " REDIS_OPT

    local SET_CACHE=0 SET_SESSION=0 SET_QUEUE=0

    case $REDIS_OPT in
        1) SET_CACHE=1; SET_SESSION=1; SET_QUEUE=1 ;;
        2) SET_CACHE=1 ;;
        3) SET_SESSION=1 ;;
        4) SET_QUEUE=1 ;;
        5)
            read -p "  Enable Redis for CACHE? [Y/n]: " C
            [[ "${C:-Y}" =~ ^[Yy]$ ]] && SET_CACHE=1
            read -p "  Enable Redis for SESSION? [Y/n]: " S
            [[ "${S:-Y}" =~ ^[Yy]$ ]] && SET_SESSION=1
            read -p "  Enable Redis for QUEUE? [Y/n]: " Q
            [[ "${Q:-Y}" =~ ^[Yy]$ ]] && SET_QUEUE=1
            ;;
        0) return ;;
        *) fail "Invalid option"; return ;;
    esac

    read -p "Redis prefix [${CLEAN_DOMAIN}_]: " REDIS_PREFIX
    REDIS_PREFIX="${REDIS_PREFIX:-${CLEAN_DOMAIN}_}"

    # Backup .env
    cp "$ENV" "${ENV}.bak.$(date '+%Y%m%d%H%M%S')"

    # Update REDIS connection settings
    update_env_var "$ENV" "REDIS_HOST" "127.0.0.1"
    update_env_var "$ENV" "REDIS_PASSWORD" "null"
    update_env_var "$ENV" "REDIS_PORT" "6379"
    update_env_var "$ENV" "REDIS_CLIENT" "phpredis"
    update_env_var "$ENV" "REDIS_PREFIX" "${REDIS_PREFIX}"

    if [ "$SET_CACHE" = "1" ]; then
        update_env_var "$ENV" "CACHE_STORE" "redis"
        ok "CACHE_STORE=redis"
    fi

    if [ "$SET_SESSION" = "1" ]; then
        update_env_var "$ENV" "SESSION_DRIVER" "redis"
        ok "SESSION_DRIVER=redis"
    fi

    if [ "$SET_QUEUE" = "1" ]; then
        update_env_var "$ENV" "QUEUE_CONNECTION" "redis"
        ok "QUEUE_CONNECTION=redis"
    fi

    echo ""
    ok "Redis configured for $DOMAIN"
    echo ""
    echo "  REDIS_HOST     = 127.0.0.1"
    echo "  REDIS_PORT     = 6379"
    echo "  REDIS_CLIENT   = phpredis"
    echo "  REDIS_PREFIX   = $REDIS_PREFIX"
    [ "$SET_CACHE" = "1" ]   && echo "  CACHE_STORE    = redis"
    [ "$SET_SESSION" = "1" ] && echo "  SESSION_DRIVER = redis"
    [ "$SET_QUEUE" = "1" ]   && echo "  QUEUE_CONNECTION = redis"
}

update_env_var(){
    local FILE="$1" KEY="$2" VAL="$3"
    if grep -q "^${KEY}=" "$FILE" 2>/dev/null; then
        sed -i "s|^${KEY}=.*|${KEY}=${VAL}|" "$FILE"
    else
        echo "${KEY}=${VAL}" >> "$FILE"
    fi
}

laravel_redis_status(){
    echo ""
    echo "========================================="
    echo "  REDIS / VALKEY STATUS"
    echo "========================================="
    echo ""

    # Valkey server status
    if command -v valkey-cli >/dev/null 2>&1; then
        local STATE=$(systemctl is-active valkey 2>/dev/null)
        if [ "$STATE" = "active" ]; then
            echo -e "  ${GREEN}●${RESET} Valkey Server : active"
        else
            echo -e "  ${RED}●${RESET} Valkey Server : $STATE"
        fi

        if valkey-cli ping 2>/dev/null | grep -qi pong; then
            local MEM=$(valkey-cli info memory 2>/dev/null | grep "used_memory_human" | cut -d: -f2 | tr -d '[:space:]')
            local KEYS=$(valkey-cli dbsize 2>/dev/null | grep -oP '\d+')
            local CONNS=$(valkey-cli info clients 2>/dev/null | grep "connected_clients" | cut -d: -f2 | tr -d '[:space:]')
            echo "  Memory       : ${MEM:-N/A}"
            echo "  Keys         : ${KEYS:-0}"
            echo "  Connections  : ${CONNS:-N/A}"
        fi
    else
        echo -e "  ${RED}●${RESET} Valkey : not installed"
    fi

    # phpredis extension status
    echo ""
    for php in 81 82 83 84; do
        BIN="/opt/remi/php${php}/root/usr/bin/php"
        [ -x "$BIN" ] || continue
        VER_DOT="${php:0:1}.${php:1}"
        if "$BIN" -m 2>/dev/null | grep -qi redis; then
            echo -e "  ${GREEN}●${RESET} PHP ${VER_DOT} phpredis : installed"
        else
            echo -e "  ${RED}●${RESET} PHP ${VER_DOT} phpredis : not installed"
        fi
    done

    # Show Laravel domains with Redis config
    echo ""
    echo "  Laravel domains with Redis:"
    echo "  --------------------------------"
    local found=0
    for env in "$DOMAINS_ROOT"/*/config/domain.env; do
        [ -f "$env" ] || continue
        APP_TYPE=$(grep "^APP_TYPE=" "$env" | cut -d= -f2)
        [ "$APP_TYPE" = "laravel" ] || continue
        DOMAIN=$(grep "^DOMAIN=" "$env" | cut -d= -f2)
        DPATH=$(dirname "$(dirname "$env")")
        LENV="$DPATH/public_html/.env"
        if [ -f "$LENV" ] && grep -q "REDIS_HOST" "$LENV"; then
            CACHE=$(grep "^CACHE_STORE=" "$LENV" 2>/dev/null | cut -d= -f2)
            SESSION=$(grep "^SESSION_DRIVER=" "$LENV" 2>/dev/null | cut -d= -f2)
            QUEUE=$(grep "^QUEUE_CONNECTION=" "$LENV" 2>/dev/null | cut -d= -f2)
            echo "  $DOMAIN | cache=$CACHE session=$SESSION queue=$QUEUE"
            found=1
        fi
    done
    [ "$found" = "0" ] && echo "  No Laravel domains with Redis configured"
}

laravel_redis_menu(){
    while true; do
        clear
        sp_header "Laravel Redis Cache" "Valkey configuration"
        sp_menu_grid \
            "1|Install Redis (Valkey)|green" \
            "2|Configure Redis for Domain|blue" \
            "3|Redis Status|cyan" \
            "4|Flush Redis Cache|yellow" \
            "5|Restart Valkey|yellow" \
            "0|Back|white"
        sp_prompt opt

        case $opt in
            1) install_laravel_redis ;;
            2) configure_laravel_redis ;;
            3) laravel_redis_status ;;
            4)
                if command -v valkey-cli >/dev/null 2>&1; then
                    echo -e "\e[31mWARNING: This will flush ALL Redis/Valkey data!\e[0m"
                    read -p "Continue? (y/n): " CONFIRM
                    [[ "$CONFIRM" =~ ^[Yy]$ ]] && valkey-cli FLUSHALL && ok "Redis cache flushed" || warn "Cancelled"
                else
                    fail "Valkey not installed"
                fi
                ;;
            5)
                if systemctl restart valkey 2>/dev/null; then
                    ok "Valkey restarted"
                else
                    fail "Valkey restart failed"
                fi
                ;;
            0) break ;;
            *) sp_invalid ;;
        esac

        pause
    done
}

laravel_logs(){
    select_laravel_domain || return
    LOG_FILE="$DOMAIN_PATH/public_html/storage/logs/laravel.log"
    [ -f "$LOG_FILE" ] || { warn "Laravel log not found"; return; }
    tail -f "$LOG_FILE"
}

laravel_status(){
    echo ""
    echo "Runtime:"
    echo "PHP      : $(php -v 2>/dev/null | head -1)"
    echo "Composer : $(composer --version 2>/dev/null)"
    echo "Node     : $(node -v 2>/dev/null)"
    echo "npm      : $(npm -v 2>/dev/null)"
    echo "Postgres : $(systemctl is-active postgresql 2>/dev/null)"
    list_laravel_domains
}

laravel_database_menu(){
    while true; do
        clear
        sp_header "Laravel Databases" "PostgreSQL management"
        sp_menu_grid \
            "1|Create PostgreSQL DB|green" \
            "2|List PostgreSQL DBs|cyan" \
            "3|View PostgreSQL DB Info|blue" \
            "4|Delete PostgreSQL DB|red" \
            "5|Change PostgreSQL Password|yellow" \
            "0|Back|white"
        sp_prompt opt

        case $opt in
            1) create_pg_database_only ;;
            2) list_pg_databases ;;
            3) view_pg_database ;;
            4) delete_pg_database ;;
            5) change_pg_database_password ;;
            0) break ;;
            *) sp_invalid ;;
        esac

        pause
    done
}

laravel_backup_menu(){
    while true; do
        clear
        sp_header "Laravel DB Backup" "PostgreSQL backups"
        sp_menu_grid \
            "1|Backup PostgreSQL Now|green" \
            "2|Import SQL to PostgreSQL|blue" \
            "3|Configure Auto Backup|yellow" \
            "4|List DB Backups|cyan" \
            "0|Back|white"
        sp_prompt opt

        case $opt in
            1) backup_pg_database ;;
            2) import_pg_database ;;
            3) configure_pg_auto_backup ;;
            4) list_pg_backups ;;
            0) break ;;
            *) sp_invalid ;;
        esac

        pause
    done
}

laravel_advanced_menu(){
    while true; do
        clear
        sp_header "Laravel Advanced" "Artisan operations"
        sp_menu_grid \
            "1|migrate --force|green" \
            "2|migrate:rollback|red" \
            "3|db:seed --force|yellow" \
            "4|key:generate|yellow" \
            "5|about|cyan" \
            "6|route:list|cyan" \
            "7|Custom Artisan Command|magenta" \
            "0|Back|white"
        sp_prompt opt

        case $opt in
            1) run_laravel_command migrate ;;
            2) run_laravel_command rollback ;;
            3) run_laravel_command seed ;;
            4) run_laravel_command key ;;
            5) run_laravel_command about ;;
            6) run_laravel_command routes ;;
            7) run_artisan ;;
            0) break ;;
            *) sp_invalid ;;
        esac

        pause
    done
}

while true; do
    clear
    sp_header "Laravel 13 Manager" "Deploy, backup, artisan"
    sp_menu_grid \
        "1|Install Laravel Runtime|green" \
        "2|Add Laravel Domain|green" \
        "3|List Laravel Domains|cyan" \
        "4|Backup Manager|yellow" \
        "5|Redis Cache Manager|blue" \
        "6|Install Components|green" \
        "7|npm run build|blue" \
        "8|Deploy / Build Prod|blue" \
        "9|Edit Laravel .env|yellow" \
        "10|storage:link|cyan" \
        "11|optimize:clear|yellow" \
        "12|optimize cache|green" \
        "13|Queue restart|yellow" \
        "14|Scheduler run|cyan" \
        "15|View Laravel Log|magenta" \
        "16|Runtime / Status|cyan" \
        "17|Fix Permissions|green" \
        "18|Advanced Artisan|magenta" \
        "0|Back|white"
    sp_prompt opt

    case $opt in
        1) install_laravel_runtime ;;
        2) create_laravel_domain ;;
        3) list_laravel_domains ;;
        4) laravel_backup_menu ;;
        5) laravel_redis_menu ;;
        6) install_laravel_components ;;
        7) npm_run_build ;;
        8) deploy_laravel_production ;;
        9) edit_laravel_env ;;
        10) run_laravel_command storage ;;
        11) run_laravel_command clear ;;
        12) run_laravel_command optimize ;;
        13) run_laravel_command queue-restart ;;
        14) run_laravel_command schedule ;;
        15) laravel_logs ;;
        16) laravel_status ;;
        17) fix_laravel_permissions ;;
        18) laravel_advanced_menu ;;
        0) break ;;
        *) sp_invalid ;;
    esac

    pause
done
