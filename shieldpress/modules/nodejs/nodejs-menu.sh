#!/bin/bash

BASE_DIR="/opt/shieldpress"
DOMAIN_MODULE="$BASE_DIR/modules/domain"
DOMAINS_ROOT="/home/domains"

source "$DOMAIN_MODULE/helpers.sh"
source "$BASE_DIR/core/ui.sh"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
RESET="\e[0m"

ok(){ echo -e "${GREEN}[OK]${RESET} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $1"; }
fail(){ echo -e "${RED}[FAIL]${RESET} $1"; }
pause(){ echo ""; read -p "Press Enter..."; }

confirm_action(){
    local prompt="$1"
    echo -e "${RED}WARNING: ${prompt}${RESET}"
    read -p "Continue? (y/n): " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { warn "Cancelled"; return 1; }
}

ensure_pm2(){
    if ! command -v pm2 >/dev/null 2>&1; then
        echo "PM2 not installed. Installing..."
        npm install -g pm2 || { fail "Failed to install PM2"; return 1; }
        pm2 startup 2>/dev/null || true
        ok "PM2 installed"
    fi
    return 0
}

backup_node_app(){
    select_node_domain || return
    backup_selected_node_app
}

backup_selected_node_app(){
    local backup_root="$BACKUP_GLOBAL_DIR/nodejs/$CLEAN_DOMAIN"
    local ts
    local backup_file
    ts=$(date +%Y%m%d-%H%M%S)
    backup_file="$backup_root/${CLEAN_DOMAIN}-${ts}.tar.gz"

    mkdir -p "$backup_root"

    tar -czf "$backup_file" \
        --exclude="public_html/node_modules" \
        --exclude="public_html/.next/cache" \
        -C "$DOMAIN_PATH" public_html config \
        -C /etc/nginx/conf.d "${CLEAN_DOMAIN}.conf" 2>/dev/null || {
            fail "Backup failed"
            return 1
        }

    LAST_NODE_BACKUP_FILE="$backup_file"
    ok "Backup created: $backup_file"
}

install_node_runtime(){
    install_shieldpress_nodejs
}

select_node_domain(){
    DOMAIN_CHOICES=()
    local i=1

    echo ""
    echo "Node.js Domains:"
    echo "--------------------------------"
    for env in "$DOMAINS_ROOT"/*/config/domain.env; do
        [ -f "$env" ] || continue
        APP_TYPE=$(grep "^APP_TYPE=" "$env" | cut -d= -f2)
        [ "$APP_TYPE" = "nodejs" ] || continue
        DOMAIN=$(grep "^DOMAIN=" "$env" | cut -d= -f2)
        NODE_APP_PORT=$(grep "^NODE_APP_PORT=" "$env" | cut -d= -f2)
        echo "  $i) $DOMAIN (port ${NODE_APP_PORT:-N/A})"
        DOMAIN_CHOICES[$i]=$(dirname "$(dirname "$env")")
        ((i++))
    done

    [ $i -eq 1 ] && { warn "No Node.js domains found"; return 1; }

    read -p "Select: " choice
    DOMAIN_PATH="${DOMAIN_CHOICES[$choice]}"
    [ -n "$DOMAIN_PATH" ] || { fail "Invalid selection"; return 1; }

    ENV_FILE="$DOMAIN_PATH/config/domain.env"
    DOMAIN=$(grep "^DOMAIN=" "$ENV_FILE" | cut -d= -f2)
    CLEAN_DOMAIN=$(basename "$DOMAIN_PATH")
    NODE_APP_PORT=$(grep "^NODE_APP_PORT=" "$ENV_FILE" | cut -d= -f2)
    NODE_APP_PORT="${NODE_APP_PORT:-3000}"
    NODE_ENTRY=$(grep "^NODE_ENTRY=" "$ENV_FILE" | cut -d= -f2)
    NODE_ENTRY="${NODE_ENTRY:-app.js}"
    return 0
}

create_node_domain(){
    install_node_runtime || return 1
    ADD_DOMAIN_APP=nodejs bash "$DOMAIN_MODULE/add-domain.sh"
}

list_node_domains(){
    echo ""
    echo "Node.js Domains:"
    echo "--------------------------------"
    local found=0
    for env in "$DOMAINS_ROOT"/*/config/domain.env; do
        [ -f "$env" ] || continue
        APP_TYPE=$(grep "^APP_TYPE=" "$env" | cut -d= -f2)
        [ "$APP_TYPE" = "nodejs" ] || continue
        found=1
        DOMAIN=$(grep "^DOMAIN=" "$env" | cut -d= -f2)
        ROOT=$(grep "^ROOT=" "$env" | cut -d= -f2)
        NODE_APP_PORT=$(grep "^NODE_APP_PORT=" "$env" | cut -d= -f2)
        local pm2_name=$(basename "$(dirname "$(dirname "$env")")")
        local pm2_state="unknown"
        if command -v pm2 >/dev/null 2>&1; then
            pm2_state=$(pm2 jlist 2>/dev/null | python3 -c "
import sys,json
try:
    apps=json.load(sys.stdin)
    for a in apps:
        if a['name']=='$pm2_name':
            print(a['pm2_env']['status'])
            sys.exit()
    print('not running')
except: print('unknown')
" 2>/dev/null || echo "unknown")
        fi
        echo "  $DOMAIN | port $NODE_APP_PORT | PM2: $pm2_state | root $ROOT"
    done
    [ "$found" = "0" ] && warn "No Node.js domains found"
}

list_running_node_apps(){
    echo ""
    echo "Running Node.js Apps (PM2):"
    echo "--------------------------------"
    if command -v pm2 >/dev/null 2>&1; then
        pm2 status
    else
        warn "PM2 is not installed"
    fi
}

# ==========================================
# PM2 START APP
# ==========================================

start_node_app(){
    select_node_domain || return
    ensure_pm2 || return
    cd "$DOMAIN_PATH/public_html" || return

    local pm2_name="$CLEAN_DOMAIN"

    # Stop old systemd service if exists (migration)
    local old_service="${CLEAN_DOMAIN}-node.service"
    if systemctl is-active --quiet "$old_service" 2>/dev/null; then
        warn "Stopping old systemd service (migrating to PM2)..."
        systemctl stop "$old_service" 2>/dev/null
        systemctl disable "$old_service" 2>/dev/null
    fi

    echo ""
    echo "Start mode:"
    echo "  1) npm start (recommended for Next.js, etc.)"
    echo "  2) node $NODE_ENTRY"
    echo "  3) Next.js standalone (node .next/standalone/server.js)"
    echo ""
    read -p "Select mode [1]: " PM2_MODE
    PM2_MODE="${PM2_MODE:-1}"

    # Stop existing PM2 process if any
    pm2 delete "$pm2_name" 2>/dev/null || true

    case "$PM2_MODE" in
        1)
            PORT=${NODE_APP_PORT} pm2 start npm --name "$pm2_name" -- start || {
                fail "PM2 start failed"
                return 1
            }
            ;;
        2)
            if [ ! -f "$DOMAIN_PATH/public_html/$NODE_ENTRY" ]; then
                fail "Entry file not found: $NODE_ENTRY"
                return 1
            fi
            PORT=${NODE_APP_PORT} pm2 start "$NODE_ENTRY" --name "$pm2_name" || {
                fail "PM2 start failed"
                return 1
            }
            ;;
        3)
            if [ ! -f ".next/standalone/server.js" ]; then
                fail ".next/standalone/server.js not found. Run Deploy/Build first."
                return 1
            fi
            PORT=${NODE_APP_PORT} pm2 start ".next/standalone/server.js" --name "$pm2_name" || {
                fail "PM2 start failed"
                return 1
            }
            ;;
        *)
            fail "Invalid mode"
            return 1
            ;;
    esac

    pm2 save || true
    ok "App started with PM2: $pm2_name (PORT=$NODE_APP_PORT)"
    echo ""
    pm2 status "$pm2_name"
}

# ==========================================
# PM2 STOP APP
# ==========================================

stop_node_app(){
    select_node_domain || return
    ensure_pm2 || return

    local pm2_name="$CLEAN_DOMAIN"
    confirm_action "Stopping will take this app offline." || return
    pm2 stop "$pm2_name" 2>/dev/null && ok "PM2 app stopped: $pm2_name" || fail "PM2 app not found: $pm2_name"
}

# ==========================================
# PM2 RESTART APP
# ==========================================

restart_node_app(){
    select_node_domain || return
    ensure_pm2 || return

    local pm2_name="$CLEAN_DOMAIN"
    pm2 restart "$pm2_name" 2>/dev/null && ok "PM2 app restarted: $pm2_name" || fail "PM2 app not found: $pm2_name"
}

# ==========================================
# DEPLOY / BUILD (with Prisma support)
# ==========================================

deploy_node_app(){
    select_node_domain || return
    ensure_pm2 || return
    cd "$DOMAIN_PATH/public_html" || return

    if [ ! -f package.json ]; then
        warn "package.json not found"
        return
    fi

    local pm2_name="$CLEAN_DOMAIN"
    local deploy_backup_file=""

    confirm_action "This will install deps, build, and restart the app." || return
    backup_selected_node_app || return
    deploy_backup_file="$LAST_NODE_BACKUP_FILE"

    echo ""
    echo "Step 1: Installing dependencies..."
    npm install || { fail "npm install failed"; return 1; }
    ok "Dependencies installed"

    # Run Prisma if prisma is in dependencies
    if grep -q '"prisma"' package.json 2>/dev/null; then
        echo ""
        echo "Step 2: Running Prisma DB push..."
        npx prisma db push || { warn "Prisma db push failed (non-fatal)"; }
        npx prisma generate || true
        ok "Prisma schema synced"
    fi

    # Build if build script exists
    if npm run 2>/dev/null | grep -q " build"; then
        echo ""
        echo "Step 3: Building for production..."

        # Clean .next cache for Next.js projects
        if [ -d ".next" ]; then
            echo "Cleaning .next cache..."
            rm -rf .next
        fi

        npm run build || { fail "Build failed"; return 1; }

        # Next.js standalone: copy public + static into standalone
        if [ -d ".next/standalone" ]; then
            echo "Detected Next.js standalone output, copying assets..."
            [ -d "public" ] && cp -r public .next/standalone/
            [ -d ".next/static" ] && mkdir -p .next/standalone/.next && cp -r .next/static .next/standalone/.next/
            ok "Copied public + static into .next/standalone"
        fi

        ok "Build completed"
    fi

    # Restart via PM2
    echo ""
    echo "Step 4: Restarting app via PM2..."

    if pm2 describe "$pm2_name" >/dev/null 2>&1; then
        pm2 restart "$pm2_name" && ok "App restarted via PM2"
    else
        echo "App not yet running in PM2. Starting now..."
        echo ""
        echo "Start mode:"
        echo "  1) npm start (recommended)"
        echo "  2) node $NODE_ENTRY"
        echo "  3) Next.js standalone"
        echo ""
        read -p "Select mode [1]: " PM2_MODE
        PM2_MODE="${PM2_MODE:-1}"

        case "$PM2_MODE" in
            1) PORT=${NODE_APP_PORT} pm2 start npm --name "$pm2_name" -- start || { fail "PM2 start failed"; return 1; } ;;
            2) PORT=${NODE_APP_PORT} pm2 start "$NODE_ENTRY" --name "$pm2_name" || { fail "PM2 start failed"; return 1; } ;;
            3) PORT=${NODE_APP_PORT} pm2 start ".next/standalone/server.js" --name "$pm2_name" || { fail "PM2 start failed"; return 1; } ;;
            *) fail "Invalid mode"; return 1 ;;
        esac

        pm2 save || true
        ok "App started with PM2: $pm2_name (PORT=$NODE_APP_PORT)"
    fi

    echo ""
    pm2 status "$pm2_name"

    # Fix permissions after deploy
    echo ""
    echo "Step 5: Fixing permissions..."
    local sysuser
    sysuser=$(grep "^SYSTEM_USER=" "$ENV_FILE" | cut -d= -f2)
    sysuser="${sysuser:-$CLEAN_DOMAIN}"
    local app_root="$DOMAIN_PATH/public_html"

    chown root:root "$DOMAIN_PATH"
    chmod 755 "$DOMAIN_PATH"
    [ -d "$DOMAIN_PATH/config" ] && chown -R "$sysuser:$sysuser" "$DOMAIN_PATH/config" && chmod 750 "$DOMAIN_PATH/config"
    [ -f "$DOMAIN_PATH/config/domain.env" ] && chmod 640 "$DOMAIN_PATH/config/domain.env"

    chown -R "$sysuser:$sysuser" "$app_root"
    find "$app_root" -path "$app_root/node_modules" -prune -o -path "$app_root/vendor" -prune -o -type d -exec chmod 755 {} \;
    find "$app_root" -path "$app_root/node_modules" -prune -o -path "$app_root/vendor" -prune -o -type f -exec chmod 644 {} \;

    [ -f "$app_root/.env" ] && chmod 600 "$app_root/.env"
    [ -f "$app_root/package.json" ] && chmod 644 "$app_root/package.json"
    [ -f "$app_root/package-lock.json" ] && chmod 644 "$app_root/package-lock.json"

    if [ -d "$app_root/node_modules" ]; then
        chown -R "$sysuser:$sysuser" "$app_root/node_modules"
        find "$app_root/node_modules" -type d -exec chmod 755 {} \;
        [ -d "$app_root/node_modules/.bin" ] && find -L "$app_root/node_modules/.bin" -type f -exec chmod 755 {} \;
    fi

    [ -d "$DOMAIN_PATH/backup" ] && chown -R "$sysuser:$sysuser" "$DOMAIN_PATH/backup" && chmod 750 "$DOMAIN_PATH/backup"
    [ -d "$DOMAIN_PATH/tmp" ] && chown -R "$sysuser:$sysuser" "$DOMAIN_PATH/tmp" && chmod 755 "$DOMAIN_PATH/tmp"

    ok "Permissions fixed (owner: $sysuser)"

    if [ -n "$deploy_backup_file" ] && [ -f "$deploy_backup_file" ]; then
        rm -f "$deploy_backup_file"
        ok "Deploy succeeded, temporary backup removed: $deploy_backup_file"
    fi
}

# ==========================================
# PM2 LOGS
# ==========================================

node_logs(){
    select_node_domain || return
    ensure_pm2 || return
    local pm2_name="$CLEAN_DOMAIN"
    pm2 logs "$pm2_name"
}

# ==========================================
# PM2 STATUS (ALL)
# ==========================================

pm2_status_all(){
    ensure_pm2 || return
    pm2 status
}

# ==========================================
# ADVANCED TOOLS
# ==========================================

fix_node_permissions(){
    FIX_APP_TYPE=nodejs bash "$DOMAIN_MODULE/fix-permission.sh"
}

change_node_port(){
    select_node_domain || return
    read -p "New local app port: " NEW_PORT

    if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
        fail "Invalid port"
        return 1
    fi

    if [ "$NEW_PORT" != "$NODE_APP_PORT" ] && ss -tuln 2>/dev/null | grep -q ":${NEW_PORT} "; then
        fail "Port $NEW_PORT is already in use"
        return 1
    fi

    ENV_FILE="$DOMAIN_PATH/config/domain.env"
    NGINX_CONF="/etc/nginx/conf.d/${CLEAN_DOMAIN}.conf"
    ENV_TMP="/tmp/${CLEAN_DOMAIN}.domain.env.$$"
    NGINX_TMP="/tmp/${CLEAN_DOMAIN}.nginx.conf.$$"

    confirm_action "Changing port updates Nginx and restarts the app." || return
    backup_selected_node_app || return

    cp "$ENV_FILE" "$ENV_TMP" || return
    cp "$NGINX_CONF" "$NGINX_TMP" || return

    sed -i "s/^NODE_APP_PORT=.*/NODE_APP_PORT=$NEW_PORT/" "$ENV_FILE"
    sed -i "s/127\.0\.0\.1:${NODE_APP_PORT}/127.0.0.1:${NEW_PORT}/g" "$NGINX_CONF"

    if nginx -t; then
        systemctl reload nginx

        # Restart PM2 app with new port
        if command -v pm2 >/dev/null 2>&1; then
            local pm2_name="$CLEAN_DOMAIN"
            pm2 delete "$pm2_name" 2>/dev/null || true
            cd "$DOMAIN_PATH/public_html" || return
            PORT=${NEW_PORT} pm2 start npm --name "$pm2_name" -- start 2>/dev/null || true
            pm2 save || true
        fi

        ok "Node.js port changed to $NEW_PORT"
    else
        fail "Nginx config invalid after port change"
        cp "$ENV_TMP" "$ENV_FILE"
        cp "$NGINX_TMP" "$NGINX_CONF"
        systemctl reload nginx 2>/dev/null || true
        warn "Port change rolled back."
    fi

    rm -f "$ENV_TMP" "$NGINX_TMP"
}

change_node_entry(){
    select_node_domain || return

    echo ""
    echo "Current entry: ${NODE_ENTRY:-app.js}"
    echo "Files in public_html:"
    find "$DOMAIN_PATH/public_html" -maxdepth 1 -type f \( -name "*.js" -o -name "*.mjs" -o -name "*.cjs" \) -printf " - %f\n" 2>/dev/null
    echo ""
    read -p "New entry file [server.js]: " NEW_ENTRY
    NEW_ENTRY="${NEW_ENTRY:-server.js}"

    if [[ "$NEW_ENTRY" == /* ]] || [[ "$NEW_ENTRY" == *".."* ]] || [[ "$NEW_ENTRY" == *"/"* ]]; then
        fail "Entry must be a file name inside public_html"
        return 1
    fi

    if [ ! -f "$DOMAIN_PATH/public_html/$NEW_ENTRY" ]; then
        fail "Entry file not found: $DOMAIN_PATH/public_html/$NEW_ENTRY"
        return 1
    fi

    ENV_FILE="$DOMAIN_PATH/config/domain.env"

    confirm_action "Changing entry will restart the app." || return
    backup_selected_node_app || return

    if grep -q "^NODE_ENTRY=" "$ENV_FILE"; then
        sed -i "s|^NODE_ENTRY=.*|NODE_ENTRY=$NEW_ENTRY|" "$ENV_FILE"
    else
        echo "NODE_ENTRY=$NEW_ENTRY" >> "$ENV_FILE"
    fi

    # Restart PM2 with new entry
    if command -v pm2 >/dev/null 2>&1; then
        local pm2_name="$CLEAN_DOMAIN"
        pm2 delete "$pm2_name" 2>/dev/null || true
        cd "$DOMAIN_PATH/public_html" || return
        PORT=${NODE_APP_PORT} pm2 start "$NEW_ENTRY" --name "$pm2_name" || {
            fail "PM2 restart failed"
            return 1
        }
        pm2 save || true
    fi

    ok "Node.js entry changed to $NEW_ENTRY"
}

node_health_check(){
    select_node_domain || return

    local nginx_conf="/etc/nginx/conf.d/${CLEAN_DOMAIN}.conf"
    local pm2_name="$CLEAN_DOMAIN"
    local status_code

    echo ""
    echo "Health check: $DOMAIN"
    echo "--------------------------------"
    echo "PM2 name: $pm2_name"
    echo "Entry   : ${NODE_ENTRY:-app.js}"
    echo "Port    : ${NODE_APP_PORT:-N/A}"

    # Check PM2 process
    if command -v pm2 >/dev/null 2>&1; then
        if pm2 describe "$pm2_name" >/dev/null 2>&1; then
            ok "PM2 process found"
            local pm2_status
            pm2_status=$(pm2 jlist 2>/dev/null | python3 -c "
import sys,json
try:
    apps=json.load(sys.stdin)
    for a in apps:
        if a['name']=='$pm2_name':
            print(a['pm2_env']['status'])
            sys.exit()
    print('stopped')
except: print('unknown')
" 2>/dev/null || echo "unknown")
            if [ "$pm2_status" = "online" ]; then
                ok "PM2 status: online"
            else
                fail "PM2 status: $pm2_status"
            fi
        else
            fail "PM2 process not found: $pm2_name"
        fi
    else
        fail "PM2 is not installed"
    fi

    # Check port
    if ss -ltn 2>/dev/null | grep -qE "127\.0\.0\.1:${NODE_APP_PORT}[[:space:]]|0\.0\.0\.0:${NODE_APP_PORT}[[:space:]]|:::${NODE_APP_PORT}[[:space:]]"; then
        ok "Port ${NODE_APP_PORT} is listening"
    else
        fail "Port ${NODE_APP_PORT} is not listening"
        return 1
    fi

    # Check HTTP response
    status_code=$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 8 "http://127.0.0.1:${NODE_APP_PORT}/" 2>/dev/null || echo "000")

    if [[ "$status_code" =~ ^2|3|4 ]]; then
        ok "Local app responded with HTTP $status_code"
    else
        fail "Local app did not respond on http://127.0.0.1:${NODE_APP_PORT}/"
        return 1
    fi

    # Check Nginx
    if [ -f "$nginx_conf" ] && grep -q "127.0.0.1:${NODE_APP_PORT}" "$nginx_conf"; then
        ok "Nginx proxy points to 127.0.0.1:${NODE_APP_PORT}"
    else
        warn "Nginx config may not point to port ${NODE_APP_PORT}: $nginx_conf"
    fi
}

node_status(){
    echo ""
    echo "Runtime:"
    echo "Node.js : $(node -v 2>/dev/null || echo N/A)"
    echo "npm     : $(npm -v 2>/dev/null || echo N/A)"
    echo "PM2     : $(pm2 -v 2>/dev/null || echo 'Not installed')"
    list_node_domains
}

migrate_systemd_to_pm2(){
    echo ""
    echo "Migrating systemd Node.js services to PM2..."
    echo "--------------------------------"

    ensure_pm2 || return

    local migrated=0
    for env in "$DOMAINS_ROOT"/*/config/domain.env; do
        [ -f "$env" ] || continue
        APP_TYPE=$(grep "^APP_TYPE=" "$env" | cut -d= -f2)
        [ "$APP_TYPE" = "nodejs" ] || continue

        local dpath=$(dirname "$(dirname "$env")")
        local clean=$(basename "$dpath")
        local port=$(grep "^NODE_APP_PORT=" "$env" | cut -d= -f2)
        local domain=$(grep "^DOMAIN=" "$env" | cut -d= -f2)
        local old_service="${clean}-node.service"
        port="${port:-3000}"

        if systemctl is-active --quiet "$old_service" 2>/dev/null; then
            echo ""
            echo "Migrating: $domain ($old_service -> PM2)"
            systemctl stop "$old_service" 2>/dev/null
            systemctl disable "$old_service" 2>/dev/null

            cd "$dpath/public_html" || continue
            pm2 delete "$clean" 2>/dev/null || true
            PORT=${port} pm2 start npm --name "$clean" -- start || {
                warn "Failed to start $clean via PM2, check manually"
                continue
            }
            ok "$domain migrated to PM2"
            ((migrated++))
        fi
    done

    if [ "$migrated" -eq 0 ]; then
        echo "No systemd Node.js services found to migrate."
    else
        pm2 save || true
        ok "$migrated app(s) migrated to PM2"
    fi
}

node_advanced_menu(){
    while true; do
        clear
        sp_header "Node.js Advanced" "Port, entry, diagnostics"
        sp_menu_grid \
            "1|Change App Port|yellow" \
            "2|Change Entry File|blue" \
            "3|Health Check / 502|green" \
            "4|Migrate systemd to PM2|cyan" \
            "0|Back|white"
        sp_prompt opt

        case $opt in
            1) change_node_port ;;
            2) change_node_entry ;;
            3) node_health_check ;;
            4) migrate_systemd_to_pm2 ;;
            0) break ;;
            *) sp_invalid ;;
        esac

        pause
    done
}

# ==========================================
# MAIN MENU
# ==========================================

while true; do
    clear
    sp_header "Node.js Manager" "Apps, PM2, deployments"
    sp_menu_grid \
        "1|Install/Update Runtime|green" \
        "2|Add Node.js Domain|green" \
        "3|List Node.js Domains|cyan" \
        "4|Running Apps (PM2)|cyan" \
        "5|Backup Node.js App|yellow" \
        "6|Deploy / Build|blue" \
        "7|Start App (PM2)|green" \
        "8|Stop App (PM2)|red" \
        "9|Restart App (PM2)|yellow" \
        "10|View App Logs|magenta" \
        "11|Runtime / Status|cyan" \
        "12|Fix Permissions|green" \
        "13|Advanced Tools|yellow" \
        "0|Back|white"
    sp_prompt opt

    case $opt in
        1) install_node_runtime ;;
        2) create_node_domain ;;
        3) list_node_domains ;;
        4) pm2_status_all ;;
        5) backup_node_app ;;
        6) deploy_node_app ;;
        7) start_node_app ;;
        8) stop_node_app ;;
        9) restart_node_app ;;
        10) node_logs ;;
        11) node_status ;;
        12) fix_node_permissions ;;
        13) node_advanced_menu ;;
        0) break ;;
        *) sp_invalid ;;
    esac

    pause
done
