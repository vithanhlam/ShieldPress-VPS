#!/bin/bash

if [ "$EUID" -ne 0 ]; then
    echo "[INFO] Not running as root. Trying sudo..."
    exec sudo bash "$0" "$@"
    exit $?
fi

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh" 2>/dev/null || true
source "$BASE_DIR/core/update-source.sh" 2>/dev/null || true
MODULE_DIR="$BASE_DIR/modules"
SHIELDPRESS_ACTION=""

# Ensure runtime directories exist on startup
ensure_shieldpress_dirs 2>/dev/null || true

# Auto-migrate from old paths on first run after update
if [ -d "$BASE_DIR/logs" ] && [ ! -L "$BASE_DIR/logs" ]; then
    create_compat_symlinks 2>/dev/null || true
fi

# Handle arguments
case "$1" in
    menu|--menu)       SHIELDPRESS_ACTION="menu" ;;
    update|--update)   SHIELDPRESS_ACTION="update" ;;
    cache|--cache)     SHIELDPRESS_ACTION="cache" ;;
    domain|--domain)   SHIELDPRESS_ACTION="domain" ;;
    ssl|--ssl)         SHIELDPRESS_ACTION="ssl" ;;
    backup|--backup)   SHIELDPRESS_ACTION="backup" ;;
    help|--help|-h)    SHIELDPRESS_ACTION="help" ;;
esac

# ===== COLORS =====
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
MAGENTA="\e[35m"
WHITE="\e[97m"
BLUE="\e[34m"
BOLD="\e[1m"
DIM="\e[2m"
RESET="\e[0m"

BAR_WIDTH=30

VERSION_FILE="$BASE_DIR/version.txt"
UPDATE_VERSION_URL="${SHIELDPRESS_VERSION_URL:-https://raw.githubusercontent.com/vithanhlam/ShieldPress-VPS/main/shieldpress/version.txt}"

if [ -f "$VERSION_FILE" ]; then
    SHIELDPRESS_VERSION=$(tr -d '[:space:]' < "$VERSION_FILE")
else
    SHIELDPRESS_VERSION="dev"
fi

REMOTE_SHIELDPRESS_VERSION=""
UPDATE_AVAILABLE=0
UPDATE_CHECK_STATUS="not_checked"

check_shieldpress_update(){
    UPDATE_CHECK_STATUS="checking"

    if ! command -v curl >/dev/null 2>&1; then
        UPDATE_CHECK_STATUS="curl_missing"
        UPDATE_AVAILABLE=0
        return
    fi

    REMOTE_SHIELDPRESS_VERSION=$(curl -fsS --connect-timeout 3 --max-time 5 "$UPDATE_VERSION_URL" 2>/dev/null | tr -d '[:space:]')

    if [ -z "$REMOTE_SHIELDPRESS_VERSION" ]; then
        UPDATE_CHECK_STATUS="failed"
        UPDATE_AVAILABLE=0
        return
    fi

    if [ "$REMOTE_SHIELDPRESS_VERSION" != "$SHIELDPRESS_VERSION" ]; then
        UPDATE_CHECK_STATUS="available"
        UPDATE_AVAILABLE=1
    else
        UPDATE_CHECK_STATUS="latest"
        UPDATE_AVAILABLE=0
    fi
}

show_update_status(){
    case "$UPDATE_CHECK_STATUS" in
        available)
            echo -e "Update: ${YELLOW}New version ${REMOTE_SHIELDPRESS_VERSION} available${RESET} (installed ${SHIELDPRESS_VERSION})"
            ;;
        latest)
            echo -e "Update: ${GREEN}Latest version${RESET} (${SHIELDPRESS_VERSION})"
            ;;
        failed)
            echo -e "Update: ${YELLOW}Unable to check update server${RESET}"
            ;;
        curl_missing)
            echo -e "Update: ${YELLOW}curl is not installed${RESET}"
            ;;
        *)
            echo -e "Update: ${YELLOW}Not checked${RESET}"
            ;;
    esac
}

run_shieldpress_update(){
    if [ "$UPDATE_AVAILABLE" != "1" ]; then
        echo "No ShieldPress VPS update is available."
        sleep 1
        return
    fi

    clear
    echo "======================================"
    echo "        ShieldPress VPS Update"
    echo "======================================"
    echo "Installed : $SHIELDPRESS_VERSION"
    echo "Latest    : $REMOTE_SHIELDPRESS_VERSION"
    echo ""
    read -p "Update now? (y/n): " CONFIRM

    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
        echo "Update cancelled."
        sleep 1
        return
    fi

    if ! SHIELDPRESS_TARGET_VERSION="$REMOTE_SHIELDPRESS_VERSION" bash "$MODULE_DIR/update/updater.sh"; then
        echo ""
        echo "[ERROR] Update failed. Check $LOG_DIR/update.log"
        read -p "Press Enter to quit..."
        exit 1
    fi
    UPDATED_VERSION=$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null || echo "unknown")
    echo ""
    if [ "$UPDATED_VERSION" = "$REMOTE_SHIELDPRESS_VERSION" ]; then
        echo "Update complete. Installed version: $UPDATED_VERSION"
        echo ""
        # Auto-apply migration patches after successful update
        if [ -f "$MODULE_DIR/patches/patches-menu.sh" ]; then
            echo "Applying migration patches..."
            bash "$MODULE_DIR/patches/patches-menu.sh" --auto
        fi
        echo ""
        echo "Run shieldpress again to load the new version."
    else
        echo "Update finished but version.txt is still: $UPDATED_VERSION"
        echo "Expected version: $REMOTE_SHIELDPRESS_VERSION"
        echo "Check $LOG_DIR/update.log"
    fi
    read -p "Press Enter to quit..."
    exit 0
}

# ===== OPCACHE CHECK =====
check_opcache() {
local PHP_BIN="$1"
if command -v "$PHP_BIN" &>/dev/null; then
if "$PHP_BIN" -i 2>/dev/null | grep -q "opcache.enable => On"; then
echo -e "${GREEN}● Enabled${RESET}"
else
echo -e "${YELLOW}● Disabled${RESET}"
fi
else
echo -e "${RED}● N/A${RESET}"
fi
}

# ===== PHP JIT CHECK =====
check_php_jit() {
local PHP_BIN="$1"
if command -v "$PHP_BIN" &>/dev/null; then
if "$PHP_BIN" -i 2>/dev/null | grep -q "JIT => On"; then
echo -e "${GREEN}● Enabled${RESET}"
else
echo -e "${YELLOW}● Disabled${RESET}"
fi
else
echo -e "${RED}● N/A${RESET}"
fi
}

# ===== FASTCGI CACHE CHECK =====
check_nginx_cache() {

if [ -d /var/cache/nginx ] && [ "$(find /var/cache/nginx -type f 2>/dev/null | head -n 1)" ]; then
    echo -e "${GREEN}● Enabled (Active)${RESET}"
else
    echo -e "${YELLOW}● Disabled${RESET}"
fi

}

# ===== HTTP3 CHECK =====
check_http3() {
if nginx -V 2>&1 | grep -q http_v3_module; then
echo -e "${GREEN}● Enabled${RESET}"
else
echo -e "${YELLOW}● Disabled${RESET}"
fi
}



# ===== SERVICE CHECK =====
check_service() {
if systemctl is-active --quiet "$1" 2>/dev/null; then
echo -e "${GREEN}● Running${RESET}"
else
echo -e "${RED}● Stopped${RESET}"
fi
}

# ===== ASCII BAR =====
draw_bar() {
PERCENT=$1
FILLED=$((PERCENT * BAR_WIDTH / 100))
EMPTY=$((BAR_WIDTH - FILLED))

printf "["
for ((i=0;i<FILLED;i++)); do printf "█"; done
for ((i=0;i<EMPTY;i++)); do printf " "; done
printf "] %s%%" "$PERCENT"
}

# ===== LIVE METRICS =====

get_nginx_connections(){
if [ -f /var/run/nginx.pid ]; then
ss -s | awk '/TCP:/ {print $2}'
else
echo "0"
fi
}

get_requests_per_sec(){
local LOG="/var/log/nginx/access.log"
if [ -f "$LOG" ]; then
tail -n 200 "$LOG" | wc -l
else
echo "0"
fi
}

get_mysql_queries(){
mysqladmin status 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="Queries") print $(i+1)}'
}

get_valkey_memory(){
if command -v valkey-cli >/dev/null; then
valkey-cli info memory 2>/dev/null | grep used_memory_human | cut -d: -f2
else
echo "N/A"
fi
}

# ===== SYSTEM INFO =====
get_system_info() {

DISK_PERCENT=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
DISK_USED=$(df -h / | awk 'NR==2 {print $3}')
DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')

RAM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
RAM_USED=$(free -m | awk '/Mem:/ {print $3}')
[ "$RAM_TOTAL" -gt 0 ] 2>/dev/null && RAM_PERCENT=$((RAM_USED*100/RAM_TOTAL)) || RAM_PERCENT=0

SWAP_TOTAL=$(free -m | awk '/Swap:/ {print $2}')
SWAP_USED=$(free -m | awk '/Swap:/ {print $3}')

CPU_LOAD=$(uptime | awk -F'load average:' '{ print $2 }' | cut -d, -f1)

DOMAIN_COUNT=$(find "$DOMAINS_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)

NGINX_STATUS=$(check_service nginx)
DB_STATUS=$(check_service mariadb)
PG_STATUS=$(check_service postgresql)
VALKEY_STATUS=$(check_service valkey)


PHP81_STATUS=$(check_service php81-php-fpm)
PHP82_STATUS=$(check_service php82-php-fpm)
PHP83_STATUS=$(check_service php83-php-fpm)
PHP84_STATUS=$(check_service php84-php-fpm)

OPCACHE81=$(check_opcache php81)
OPCACHE82=$(check_opcache php82)
OPCACHE83=$(check_opcache php83)
OPCACHE84=$(check_opcache php84)

JIT81=$(check_php_jit php81)
JIT82=$(check_php_jit php82)
JIT83=$(check_php_jit php83)
JIT84=$(check_php_jit php84)

NGINX_CACHE=$(check_nginx_cache)
HTTP3_STATUS=$(check_http3)


NGINX_CONN=$(get_nginx_connections)
REQ_SEC=$(get_requests_per_sec)
MYSQL_Q=$(get_mysql_queries)
VALKEY_MEM=$(get_valkey_memory)

OPEN_PORTS=$(ss -tuln | awk 'NR>1 {print $5}' | cut -d: -f2 | sort -n | uniq | tr '\n' ' ')
}

# ===== DASHBOARD =====
svc_state(){
    systemctl is-active --quiet "$1" 2>/dev/null && echo "OK" || echo "DOWN"
}

svc_badge(){
    if [ "$1" = "OK" ]; then
        echo -e "${GREEN}[ OK ]${RESET}"
    else
        echo -e "${RED}[DOWN]${RESET}"
    fi
}

hr(){ echo -e "${CYAN}+----------------------------------------------------------------------------+${RESET}"; }

section_title(){
    printf "${CYAN}|${RESET} ${BOLD}%-74s${RESET} ${CYAN}|${RESET}\n" "$1"
}

status_badge(){
    local STATE="$1"
    local TEXT="$2"
    case "$STATE" in
        ok) echo -e "${GREEN}[ OK ]${RESET} $TEXT" ;;
        warn) echo -e "${YELLOW}[WARN]${RESET} $TEXT" ;;
        danger) echo -e "${RED}[FAIL]${RESET} $TEXT" ;;
        *) echo -e "${WHITE}[INFO]${RESET} $TEXT" ;;
    esac
}

metric_bar(){
    local LABEL="$1"
    local PERCENT="$2"
    local DETAIL="$3"
    local COLOR="$GREEN"

    [ "$PERCENT" -ge 85 ] && COLOR="$YELLOW"
    [ "$PERCENT" -ge 95 ] && COLOR="$RED"

    local FILLED=$((PERCENT * BAR_WIDTH / 100))
    local EMPTY=$((BAR_WIDTH - FILLED))

    printf "  %-8s ${COLOR}[" "$LABEL"
    for ((i=0;i<FILLED;i++)); do printf "#"; done
    for ((i=0;i<EMPTY;i++)); do printf " "; done
    printf "]${RESET} %3s%%  %s\n" "$PERCENT" "$DETAIL"
}

menu_button(){
    local NUM="$1"
    local LABEL="$2"
    local COLOR="$3"
    printf "${COLOR}[%2s]${RESET} %-28s" "$NUM" "$LABEL"
}

collect_dashboard_metrics(){
    DISK_PERCENT=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
    DISK_USED=$(df -h / | awk 'NR==2 {print $3}')
    DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')

    RAM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
    RAM_USED=$(free -m | awk '/Mem:/ {print $3}')
    [ "$RAM_TOTAL" -gt 0 ] 2>/dev/null && RAM_PERCENT=$((RAM_USED*100/RAM_TOTAL)) || RAM_PERCENT=0
    SWAP_TOTAL=$(free -m | awk '/Swap:/ {print $2}')
    SWAP_USED=$(free -m | awk '/Swap:/ {print $3}')
    CPU_LOAD=$(uptime | awk -F'load average:' '{ print $2 }' | cut -d, -f1 | xargs)

    DOMAIN_COUNT=$(find "$DOMAINS_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    WP_COUNT=$(grep -R "^APP_TYPE=wordpress" "$DOMAINS_ROOT"/*/config/domain.env 2>/dev/null | wc -l)
    LARAVEL_COUNT=$(grep -R "^APP_TYPE=laravel" "$DOMAINS_ROOT"/*/config/domain.env 2>/dev/null | wc -l)
    NODE_COUNT=$(grep -R "^APP_TYPE=nodejs" "$DOMAINS_ROOT"/*/config/domain.env 2>/dev/null | wc -l)

    NGINX_STATE=$(svc_state nginx)
    DB_STATE=$(svc_state mariadb)
    PG_STATE=$(svc_state postgresql)
    VALKEY_STATE=$(svc_state valkey)
    FIREWALL_STATE=$(svc_state firewalld)
    FAIL2BAN_STATE=$(svc_state fail2ban)

    HTTP3_STATUS=$(check_http3)
    NGINX_CACHE=$(check_nginx_cache)
    NGINX_CONN=$(get_nginx_connections)
    REQ_SEC=$(get_requests_per_sec)
    VALKEY_MEM=$(get_valkey_memory)
    OPEN_PORT_COUNT=$(ss -tuln | awk 'NR>1 {print $5}' | grep -oE '[0-9]+$' | sort -n | uniq | wc -l)

    DB_PUBLIC="no"
    ALERTS=0
    [ "$DISK_PERCENT" -ge 85 ] && ALERTS=$((ALERTS+1))
    [ "$RAM_PERCENT" -ge 90 ] && ALERTS=$((ALERTS+1))
    [ "$NGINX_STATE" = "OK" ] || ALERTS=$((ALERTS+1))
    [ "$FIREWALL_STATE" = "OK" ] || ALERTS=$((ALERTS+1))
    if ss -tuln | grep -Eq '0\.0\.0\.0:3306|\*:3306|\[::\]:3306|:::3306|0\.0\.0\.0:5432|\*:5432|\[::\]:5432|:::5432'; then
        DB_PUBLIC="yes"
        ALERTS=$((ALERTS+1))
    fi
}

show_dashboard(){

collect_dashboard_metrics
clear

HEALTH_COLOR="$GREEN"
HEALTH_TEXT="OK"
[ "$ALERTS" -gt 0 ] && { HEALTH_COLOR="$YELLOW"; HEALTH_TEXT="CHECK"; }
if [ "$DISK_PERCENT" -ge 95 ] || [ "$RAM_PERCENT" -ge 95 ] || [ "$NGINX_STATE" != "OK" ]; then HEALTH_COLOR="$RED"; HEALTH_TEXT="DANGER"; fi

hr
printf "${CYAN}|${RESET} ${BOLD}${WHITE}%-36s${RESET} ${DIM}%-20s${RESET} ${HEALTH_COLOR}%-15s${RESET} ${CYAN}|${RESET}\n" \
    "ShieldPress VPS v${SHIELDPRESS_VERSION}" "Control Dashboard" "Status: $HEALTH_TEXT"
hr
printf "  Load: %-18s Ports: %-5s Alerts: ${HEALTH_COLOR}%-3s${RESET} Domains: %-4s\n" \
    "$CPU_LOAD" "$OPEN_PORT_COUNT" "$ALERTS" "$DOMAIN_COUNT"
printf "  "
show_update_status
echo ""

section_title "Resource Usage"
metric_bar "Disk" "$DISK_PERCENT" "$DISK_USED/$DISK_TOTAL"
metric_bar "RAM" "$RAM_PERCENT" "${RAM_USED}MB/${RAM_TOTAL}MB"
printf "  %-8s ${BLUE}[%-30s]${RESET}      %s/%s MB\n" "Swap" "" "$SWAP_USED" "$SWAP_TOTAL"

hr
section_title "Services"
printf "  %-12s %b   %-12s %b   %-12s %b\n" "Nginx" "$(svc_badge "$NGINX_STATE")" "MariaDB" "$(svc_badge "$DB_STATE")" "PostgreSQL" "$(svc_badge "$PG_STATE")"
printf "  %-12s %b   %-12s %b   %-12s %b\n" "Valkey" "$(svc_badge "$VALKEY_STATE")" "Firewall" "$(svc_badge "$FIREWALL_STATE")" "Fail2ban" "$(svc_badge "$FAIL2BAN_STATE")"

hr
section_title "Applications & Traffic"
printf "  WordPress: %-4s  Laravel: %-4s  Node.js: %-4s\n" "$WP_COUNT" "$LARAVEL_COUNT" "$NODE_COUNT"
printf "  HTTP/3   : %-20b  FastCGI Cache: %b\n" "$HTTP3_STATUS" "$NGINX_CACHE"
printf "  Nginx TCP: %-12s  Request sample: %-8s  Valkey memory: %s\n" "$NGINX_CONN" "$REQ_SEC" "$VALKEY_MEM"

if [ "$ALERTS" -gt 0 ]; then
    hr
    section_title "Active Alerts"
    [ "$DISK_PERCENT" -ge 85 ] && echo -e "  $(status_badge warn "Disk usage is high (${DISK_PERCENT}%)")"
    [ "$RAM_PERCENT" -ge 90 ] && echo -e "  $(status_badge warn "RAM usage is high (${RAM_PERCENT}%)")"
    [ "$NGINX_STATE" = "OK" ] || echo -e "  $(status_badge danger "Nginx is down")"
    [ "$FIREWALL_STATE" = "OK" ] || echo -e "  $(status_badge danger "Firewalld is down")"
    [ "$DB_PUBLIC" = "yes" ] && echo -e "  $(status_badge danger "Database port is public")"
fi

hr
section_title "Quick Actions"
printf "  "; menu_button 1 "Admin Menu" "$CYAN"; menu_button 2 "Update" "$YELLOW"; echo ""
printf "  "; menu_button 3 "Clear All Cache" "$MAGENTA"; menu_button 4 "Add Domain" "$GREEN"; echo ""
printf "  "; menu_button 5 "Install SSL" "$BLUE"; menu_button 6 "Backup" "$CYAN"; echo ""
printf "  "; menu_button 7 "Exit" "$RED"; echo ""
hr

}

# ===== HANDLE DIRECT ACTIONS =====
if [ -n "$SHIELDPRESS_ACTION" ]; then
    case "$SHIELDPRESS_ACTION" in
        help)
            echo ""
            echo -e "${BOLD}${WHITE}ShieldPress VPS - Quick Commands${RESET}"
            echo -e "${CYAN}──────────────────────────────────────${RESET}"
            echo -e "  ${CYAN}[ 1]${RESET} Admin Menu              ${YELLOW}[ 2]${RESET} Update"
            echo -e "  ${MAGENTA}[ 3]${RESET} Clear All Cache         ${GREEN}[ 4]${RESET} Add Domain"
            echo -e "  ${BLUE}[ 5]${RESET} Install SSL             ${CYAN}[ 6]${RESET} Backup"
            echo -e "  ${RED}[ 7]${RESET} Exit"
            echo -e "${CYAN}──────────────────────────────────────${RESET}"

            # Check for new version and notify
            check_shieldpress_update
            if [ "$UPDATE_AVAILABLE" = "1" ]; then
                echo ""
                echo -e "  ${BOLD}${YELLOW}╔══════════════════════════════════════╗${RESET}"
                echo -e "  ${BOLD}${YELLOW}║  New version ${REMOTE_SHIELDPRESS_VERSION} available!          ║${RESET}"
                echo -e "  ${BOLD}${YELLOW}║  Current: ${SHIELDPRESS_VERSION}                        ║${RESET}"
                echo -e "  ${BOLD}${YELLOW}║  Run: shieldpress update             ║${RESET}"
                echo -e "  ${BOLD}${YELLOW}╚══════════════════════════════════════╝${RESET}"
            fi

            echo ""
            echo -e "  ${DIM}Type a number in terminal to quick access${RESET}"
            echo -e "  ${DIM}Type 'shieldpress' for full dashboard${RESET}"
            echo ""
            exit 0
            ;;
        menu)   ;; # fall through to menu below
        update) check_shieldpress_update; run_shieldpress_update; exit 0 ;;
        cache)  bash "$MODULE_DIR/cache/clear-all-cache.sh"; exit 0 ;;
        domain) bash "$MODULE_DIR/domain/add-domain.sh"; exit 0 ;;
        ssl)    bash "$MODULE_DIR/ssl/install-ssl.sh"; exit 0 ;;
        backup) bash "$MODULE_DIR/backup/backup-menu.sh"; exit 0 ;;
    esac
fi

# ===== MAIN OUTER LOOP =====
while true; do

# Always check for updates on each outer loop iteration
check_shieldpress_update

# ===== REALTIME LOOP =====
if [ "$SHIELDPRESS_ACTION" != "menu" ]; then

while true; do
show_dashboard
key=""
read -t 3 -n 1 key
case "$key" in
1) break ;;
"" ) continue ;;
2)
    if [ "$UPDATE_AVAILABLE" = "1" ]; then
        run_shieldpress_update
    else
        check_shieldpress_update
        if [ "$UPDATE_AVAILABLE" = "1" ]; then
            run_shieldpress_update
        else
            echo "No ShieldPress VPS update is available."
            sleep 1
        fi
    fi
    ;;
3) bash "$MODULE_DIR/cache/clear-all-cache.sh" ;;
4) bash "$MODULE_DIR/domain/add-domain.sh" ;;
5) bash "$MODULE_DIR/ssl/install-ssl.sh" ;;
6) bash "$MODULE_DIR/backup/backup-menu.sh" ;;
7|q|Q|0) exit 0 ;;
esac
done
fi

# Reset action so next outer loop iteration shows dashboard
SHIELDPRESS_ACTION=""

# ===== MENU =====
while true; do

clear
hr
printf "${CYAN}|${RESET} ${BOLD}${WHITE}%-74s${RESET} ${CYAN}|${RESET}\n" "ShieldPress VPS v${SHIELDPRESS_VERSION} Admin Menu"
hr
show_update_status
hr

if [ ! -f "$ETC_DIR/.stack_installed" ]; then
STACK_LABEL="Install Stack"
STACK_COLOR="$RED"
INSTALL_OPTION=1
else
STACK_LABEL="Dashboard"
STACK_COLOR="$GREEN"
INSTALL_OPTION=0
fi

section_title "Server"
printf "  "; menu_button 1 "$STACK_LABEL" "$STACK_COLOR"; menu_button 2 "Core Server" "$CYAN"; echo ""
printf "  "; menu_button 3 "Nginx Manager" "$GREEN"; menu_button 4 "PHP Manager" "$GREEN"; echo ""
hr
section_title "Applications"
printf "  "; menu_button 5 "Domain Manager" "$GREEN"; menu_button 6 "SSL Manager" "$BLUE"; echo ""
printf "  "; menu_button 7 "WordPress Manager" "$MAGENTA"; menu_button 8 "Laravel Manager" "$MAGENTA"; echo ""
printf "  "; menu_button 9 "Node.js Manager" "$MAGENTA"; menu_button 10 "Database Manager" "$BLUE"; echo ""
hr
section_title "System"
printf "  "; menu_button 11 "Backup & Restore" "$YELLOW"; menu_button 12 "Cache Manager" "$CYAN"; echo ""
printf "  "; menu_button 13 "Security & Firewall" "$RED"; menu_button 14 "Monitoring & Logs" "$YELLOW"; echo ""
printf "  "; menu_button 15 "Upgrade Manager" "$YELLOW"; menu_button 16 "Self-Healing & Repair" "$RED"; echo ""
printf "  "; menu_button 17 "Optimization" "$GREEN"; menu_button 18 "RAM Manager" "$BLUE"; echo ""
printf "  "; menu_button 19 "Disk Manager" "$BLUE"; menu_button 20 "SFTP Manager" "$CYAN"; echo ""
hr
section_title "Settings"
printf "  "; menu_button 21 "Tools & Utilities" "$BLUE"; menu_button 22 "Telegram Notifications" "$GREEN"; echo ""
printf "  "; menu_button 23 "ShieldPress Monitor" "$GREEN"; menu_button 24 "Email Server" "$MAGENTA"; echo ""
printf "  "; menu_button 25 "About Us" "$CYAN"; menu_button 26 "Migration Patches" "$YELLOW"; echo ""
printf "  "; menu_button 0 "Exit" "$RED"; echo ""
hr

read -p "Select: " choice

case $choice in
1)
if [ "$INSTALL_OPTION" = "1" ]; then
bash "$MODULE_DIR/install/install-stack.sh"
else
SHIELDPRESS_ACTION=""
break
fi
;;
2) bash "$MODULE_DIR/core/core-menu.sh" ;;
3) bash "$MODULE_DIR/nginx/nginx-menu.sh" ;;
4) bash "$MODULE_DIR/php/php-menu.sh" ;;
5) bash "$MODULE_DIR/domain/domain-menu.sh" ;;
6) bash "$MODULE_DIR/ssl/ssl-menu.sh" ;;
7) bash "$MODULE_DIR/wordpress/wp-menu.sh" ;;
8) bash "$MODULE_DIR/laravel/laravel-menu.sh" ;;
9) bash "$MODULE_DIR/nodejs/nodejs-menu.sh" ;;
10) bash "$MODULE_DIR/database/db-menu.sh" ;;
11) bash "$MODULE_DIR/backup/backup-menu.sh" ;;
12) bash "$MODULE_DIR/cache/cache-menu.sh" ;;
13) bash "$MODULE_DIR/security/security-menu.sh" ;;
14) bash "$MODULE_DIR/monitor/monitor-menu.sh" ;;
15) bash "$MODULE_DIR/upgrade/upgrade-menu.sh" ;;
16) bash "$MODULE_DIR/repair/repair-menu.sh" ;;
17) bash "$MODULE_DIR/optimize/optimize-menu.sh" ;;
18) bash "$MODULE_DIR/ram/ram-manager.sh" ;;
19) bash "$MODULE_DIR/disk/disk-menu.sh" ;;
20) bash "$MODULE_DIR/sftp/sftp-manager.sh" ;;
21) bash "$MODULE_DIR/tools/tools-menu.sh" ;;
22) bash "$MODULE_DIR/notification/notification-menu.sh" ;;
23) bash "$MODULE_DIR/shieldpress/shieldpress-monitor.sh" ;;
24) bash "$MODULE_DIR/email/email-menu.sh" ;;
25) bash "$MODULE_DIR/shieldpress/about.sh" ;;
26) bash "$MODULE_DIR/patches/patches-menu.sh" ;;
0) exit 0 ;;
esac

done
# End outer loop - returns to dashboard
done
