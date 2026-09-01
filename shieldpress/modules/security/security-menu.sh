#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
DOMAINS_ROOT="/home/domains"
LOG_FILE="$LOG_DIR/security.log"
source "$BASE_DIR/core/ui.sh"

IP_HISTORY_FILE="$LOG_DIR/ip-block-history.log"

mkdir -p "$LOG_DIR"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
BOLD="\e[1m"
DIM="\e[2m"
RESET="\e[0m"

log(){  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"; }
ok(){   echo -e "${GREEN}[OK]${RESET} $1";       log "[OK] $1"; }
fail(){ echo -e "${RED}[FAILED]${RESET} $1";     log "[FAILED] $1"; }
warn(){ echo -e "${YELLOW}[WARNING]${RESET} $1"; log "[WARNING] $1"; }
info(){ echo -e "${CYAN}[INFO]${RESET} $1"; }

# ==================================================
# IP BLOCK HISTORY LOGGING
# ==================================================

log_ip_event(){
    local ACTION="$1"   # BLOCKED | WHITELISTED | UNBLOCKED | BANNED | UNBANNED
    local IP="$2"
    local REASON="${3:-manual}"
    local SOURCE="${4:-user}"  # user | fail2ban | geo-block
    # Strip newlines and pipe chars to prevent log injection
    IP=$(tr -d '\n\r|' <<< "$IP")
    REASON=$(tr -d '\n\r|' <<< "$REASON")
    SOURCE=$(tr -d '\n\r|' <<< "$SOURCE")
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $ACTION | $IP | $REASON | $SOURCE" >> "$IP_HISTORY_FILE"
}

# ==================================================
# ENSURE SERVICES
# ==================================================

ensure_firewall(){
    if ! command -v firewall-cmd &>/dev/null; then
        dnf install -y firewalld
    fi
    systemctl enable firewalld >/dev/null
    systemctl start  firewalld >/dev/null
}

ensure_fail2ban(){
    if ! command -v fail2ban-client &>/dev/null; then
        dnf install -y fail2ban
    fi
    systemctl enable fail2ban >/dev/null
    systemctl restart fail2ban >/dev/null
}

# ==================================================
# SECURITY DASHBOARD
# ==================================================

security_dashboard(){

    ensure_firewall
    ensure_fail2ban

    LOG_PATH="/var/log/nginx/domains/*/access.log"

    MY_IP=$(curl -s ifconfig.me 2>/dev/null)

    BLOCKED=$(firewall-cmd --list-rich-rules 2>/dev/null | grep -c reject || echo 0)
    WHITE=$(firewall-cmd --list-rich-rules   2>/dev/null | grep -c accept || echo 0)
    PORTS=$(ss -tuln | awk 'NR>1 {print $5}' | grep -oP '(?<=:)\d+$' | sort -n | uniq | tr '\n' ' ')
    FAIL2BAN=$(fail2ban-client status 2>/dev/null | grep "Jail list" | cut -d: -f2 | xargs)

    F2B_STATUS=$(systemctl is-active fail2ban 2>/dev/null)
    FW_STATUS=$(systemctl is-active firewalld 2>/dev/null)

    # ============================
    # 🔥 LIVE ATTACK (FIX DOMAIN)
    # ============================
    LIVE_ATTACK=$(awk '
    {
        ip=$1
        domain=FILENAME
        sub(".*/domains/","",domain)
        sub("/access.log","",domain)

        print ip "|" domain
    }' $LOG_PATH 2>/dev/null | sort | uniq -c | sort -nr | head -5)

    # ============================
    # 🎯 TOP URL (FIX DOMAIN)
    # ============================
    TOP_URL=$(awk '
    {
        url=$7
        domain=FILENAME
        sub(".*/domains/","",domain)
        sub("/access.log","",domain)

        print url "|" domain
    }' $LOG_PATH 2>/dev/null | sort | uniq -c | sort -nr | head -5)

    # ============================
    # 🚨 WP ATTACK (FIX DOMAIN)
    # ============================
    WP_ATTACK=$(awk '
    /wp-login|xmlrpc/ {
        ip=$1
        domain=FILENAME
        sub(".*/domains/","",domain)
        sub("/access.log","",domain)

        print ip "|" domain
    }' $LOG_PATH 2>/dev/null | sort | uniq -c | sort -nr | head -5)

    REQ_SEC=$(awk 'END{print NR}' $LOG_PATH 2>/dev/null)

    echo ""
    echo "======================================"
    echo -e "${CYAN}  SECURITY DASHBOARD PRO${RESET}"
    echo "======================================"

    echo "Firewall    : $FW_STATUS"
    echo "Fail2ban    : $F2B_STATUS"
    echo "Blocked IPs : $BLOCKED"
    echo "Whitelist   : $WHITE"
    echo "Fail2ban    : ${FAIL2BAN:-None}"
    echo "Open Ports  : $PORTS"

    echo "--------------------------------------"
    echo -e "${YELLOW}🔥 LIVE ATTACKERS${RESET}"

    echo "$LIVE_ATTACK" | while read count data; do
        IP=$(echo $data | cut -d'|' -f1)
        DOMAIN=$(echo $data | cut -d'|' -f2)

        if [ "$IP" = "$MY_IP" ]; then
            echo "$count $IP (me) → $DOMAIN"
        else
            echo "$count $IP → $DOMAIN"
        fi
    done

    echo "--------------------------------------"
    echo -e "${YELLOW}🎯 TOP REQUEST URL${RESET}"

    echo "$TOP_URL" | while read count data; do
        URL=$(echo $data | cut -d'|' -f1)
        DOMAIN=$(echo $data | cut -d'|' -f2)
        echo "$count $URL → $DOMAIN"
    done

    echo "--------------------------------------"
    echo -e "${RED}🚨 WP ATTACK${RESET}"

    echo "$WP_ATTACK" | while read count data; do
        IP=$(echo $data | cut -d'|' -f1)
        DOMAIN=$(echo $data | cut -d'|' -f2)

        if [ "$IP" = "$MY_IP" ]; then
            echo "$count $IP (me) → $DOMAIN"
        else
            echo "$count $IP → $DOMAIN"
        fi
    done

    echo "--------------------------------------"
    echo -e "${CYAN}⚡ Total Requests: $REQ_SEC${RESET}"

    echo "======================================"
    echo ""
}

security_dashboard_compact(){

    ensure_firewall
    ensure_fail2ban

    BLOCKED=$(firewall-cmd --list-rich-rules 2>/dev/null | grep -c reject || echo 0)
    WHITE=$(firewall-cmd --list-rich-rules 2>/dev/null | grep -c accept || echo 0)
    PORT_COUNT=$(ss -tuln | awk 'NR>1 {print $5}' | grep -oP '(?<=:)\d+$' | sort -n | uniq | wc -l)
    FAIL2BAN=$(fail2ban-client status 2>/dev/null | grep "Jail list" | cut -d: -f2 | xargs)
    JAIL_COUNT=$(echo "$FAIL2BAN" | tr ',' '\n' | awk 'NF' | wc -l)

    F2B_STATUS=$(systemctl is-active fail2ban 2>/dev/null)
    FW_STATUS=$(systemctl is-active firewalld 2>/dev/null)

    RECENT_TOTAL=$(find /var/log/nginx/domains -name access.log -mmin -10 -print0 2>/dev/null | xargs -0 awk 'END{print NR}' 2>/dev/null | awk '{s+=$1} END{print s+0}')
    RECENT_4XX=$(find /var/log/nginx/domains -name access.log -mmin -10 -print0 2>/dev/null | xargs -0 awk '$9 ~ /^4/ {c++} END{print c+0}' 2>/dev/null | awk '{s+=$1} END{print s+0}')
    WP_HITS=$(find /var/log/nginx/domains -name access.log -mmin -10 -print0 2>/dev/null | xargs -0 awk '/wp-login|xmlrpc/ {c++} END{print c+0}' 2>/dev/null | awk '{s+=$1} END{print s+0}')

    DB_PUBLIC="no"
    if ss -tuln | grep -Eq '0\.0\.0\.0:3306|\*:3306|\[::\]:3306|:::3306|0\.0\.0\.0:5432|\*:5432|\[::\]:5432|:::5432'; then
        DB_PUBLIC="yes"
    fi

    SSH_WARN="no"
    if grep -Eiq "^[[:space:]]*PermitRootLogin[[:space:]]+yes|^[[:space:]]*PasswordAuthentication[[:space:]]+yes" /etc/ssh/sshd_config 2>/dev/null; then
        SSH_WARN="yes"
    fi

    HEALTH_COLOR="$GREEN"
    HEALTH_TEXT="OK"
    [ "$FW_STATUS" = "active" ] || { HEALTH_COLOR="$RED"; HEALTH_TEXT="CHECK"; }
    [ "$F2B_STATUS" = "active" ] || { HEALTH_COLOR="$RED"; HEALTH_TEXT="CHECK"; }
    [ "$DB_PUBLIC" = "yes" ] && { HEALTH_COLOR="$RED"; HEALTH_TEXT="CHECK"; }

    echo ""
    echo "===================================================="
    echo -e "  SECURITY CENTER                         ${HEALTH_COLOR}${HEALTH_TEXT}${RESET}"
    echo "===================================================="
    printf "  %-13s %s\n" "Firewall" "$FW_STATUS"
    printf "  %-13s %s (%s jail%s)\n" "Fail2ban" "$F2B_STATUS" "$JAIL_COUNT" "$([ "$JAIL_COUNT" = "1" ] || echo s)"
    printf "  %-13s blocked: %s | whitelist: %s\n" "IP rules" "$BLOCKED" "$WHITE"
    printf "  %-13s %s listening\n" "Ports" "$PORT_COUNT"
    echo "----------------------------------------------------"
    printf "  %-13s requests: %s | 4xx: %s | wp-login/xmlrpc: %s\n" "Last 10 min" "$RECENT_TOTAL" "$RECENT_4XX" "$WP_HITS"

    # Auto-Guard status
    if systemctl is-active --quiet sp-auto-guard.timer 2>/dev/null; then
        echo -e "  ${GREEN}Auto-Guard  : ENABLED${RESET} (auto-block khi vượt ngưỡng)"
    else
        echo -e "  ${DIM}Auto-Guard  : off${RESET}"
    fi

    ALERTS=0
    [ "$DB_PUBLIC" = "yes" ] && { echo -e "  ${RED}ALERT${RESET} Database port is public"; ALERTS=$((ALERTS+1)); }
    [ "$SSH_WARN" = "yes" ] && { echo -e "  ${YELLOW}WARN ${RESET} SSH root/password login enabled"; ALERTS=$((ALERTS+1)); }
    [ "$F2B_STATUS" = "active" ] || { echo -e "  ${RED}ALERT${RESET} Fail2ban is not active"; ALERTS=$((ALERTS+1)); }
    [ "$FW_STATUS" = "active" ] || { echo -e "  ${RED}ALERT${RESET} Firewalld is not active"; ALERTS=$((ALERTS+1)); }
    [ "$ALERTS" -eq 0 ] && echo -e "  ${GREEN}No critical alerts${RESET}"

    echo "===================================================="
    echo ""
}

# ==================================================
# FIREWALL STATUS
# ==================================================

firewall_status(){
    ensure_firewall
    echo ""
    echo "======================================"
    echo "  FIREWALL STATUS"
    echo "======================================"
    echo "Default zone : $(firewall-cmd --get-default-zone)"
    echo ""
    echo "Open services:"
    firewall-cmd --list-services
    echo ""
    echo "Open ports:"
    firewall-cmd --list-ports
    echo ""
    echo "Rich rules:"
    firewall-cmd --list-rich-rules
    echo "======================================"
}

security_audit(){
    echo ""
    echo "======================================"
    echo "  SECURITY AUDIT"
    echo "======================================"

    ensure_firewall
    ensure_fail2ban

    systemctl is-active --quiet firewalld && ok "Firewalld is running" || fail "Firewalld is not running"
    systemctl is-active --quiet fail2ban && ok "Fail2ban is running" || warn "Fail2ban is not running"

    if nginx -t >/dev/null 2>&1; then
        ok "Nginx config is valid"
    else
        fail "Nginx config has errors"
        nginx -t
    fi

    SSHD_CONF="/etc/ssh/sshd_config"
    if grep -Eiq "^[[:space:]]*PermitRootLogin[[:space:]]+yes" "$SSHD_CONF" 2>/dev/null; then
        warn "SSH root login is enabled"
    else
        ok "SSH root login is not explicitly enabled"
    fi

    if grep -Eiq "^[[:space:]]*PasswordAuthentication[[:space:]]+yes" "$SSHD_CONF" 2>/dev/null; then
        warn "SSH password authentication is enabled"
    else
        ok "SSH password authentication is not explicitly enabled"
    fi

    if ss -tuln | grep -Eq '0\.0\.0\.0:3306|\*:3306|\[::\]:3306|:::3306'; then
        fail "MariaDB is listening publicly on 3306"
    else
        ok "MariaDB is not listening publicly"
    fi

    if ss -tuln | grep -Eq '0\.0\.0\.0:5432|\*:5432|\[::\]:5432|:::5432'; then
        fail "PostgreSQL is listening publicly on 5432"
    else
        ok "PostgreSQL is not listening publicly"
    fi

    if firewall-cmd --list-ports 2>/dev/null | grep -Eq '(^| )3306/tcp( |$)|(^| )5432/tcp( |$)'; then
        fail "Database port is open in firewall"
    else
        ok "Database ports are not open in firewall"
    fi

    for env in "$DOMAINS_ROOT"/*/config/domain.env; do
        [ -f "$env" ] || continue
        APP_TYPE=$(grep "^APP_TYPE=" "$env" | cut -d= -f2)
        SYSTEM_USER=$(grep "^SYSTEM_USER=" "$env" | cut -d= -f2)
        DOMAIN=$(grep "^DOMAIN=" "$env" | cut -d= -f2)

        if [ "$APP_TYPE" = "nodejs" ]; then
            if systemctl is-active --quiet "${SYSTEM_USER}-node.service"; then
                ok "Node.js service running: $DOMAIN"
            else
                warn "Node.js service not running: $DOMAIN"
            fi
        fi
    done

    echo "======================================"
}

# ==================================================
# OPEN / CLOSE PORT
# ==================================================

open_port(){
    ensure_firewall
    read -p "Port to open: " PORT

    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        fail "Invalid port number"; return
    fi

    ZONE=$(firewall-cmd --get-default-zone)

    if firewall-cmd --zone="$ZONE" --list-ports | grep -q "${PORT}/tcp"; then
        warn "Port $PORT already open"; return
    fi

    firewall-cmd --zone="$ZONE" --permanent --add-port="${PORT}/tcp" >/dev/null 2>&1 && \
    firewall-cmd --reload >/dev/null 2>&1

    firewall-cmd --zone="$ZONE" --list-ports | grep -q "${PORT}/tcp" && \
        ok "Port $PORT opened" || fail "Failed to open port $PORT"
}

close_port(){
    ensure_firewall
    read -p "Port to close: " PORT

    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        fail "Invalid port number"; return
    fi

    ZONE=$(firewall-cmd --get-default-zone)

    if ! firewall-cmd --zone="$ZONE" --list-ports | grep -q "${PORT}/tcp"; then
        warn "Port $PORT is not open"; return
    fi

    firewall-cmd --zone="$ZONE" --permanent --remove-port="${PORT}/tcp" >/dev/null 2>&1 && \
    firewall-cmd --reload >/dev/null 2>&1

    firewall-cmd --zone="$ZONE" --list-ports | grep -q "${PORT}/tcp" && \
        fail "Port $PORT still open" || ok "Port $PORT closed"
}

# ==================================================
# IP BLOCK / WHITELIST / UNBLOCK
# ==================================================

validate_ip(){
    local ip="$1"
    # Must match IPv4 format with optional CIDR
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || return 1
    # Validate each octet is 0-255
    local ip_part="${ip%%/*}"
    local IFS='.'
    local -a octets
    read -r -a octets <<< "$ip_part"
    local o
    for o in "${octets[@]}"; do
        [ "$o" -ge 0 ] && [ "$o" -le 255 ] || return 1
    done
    # If CIDR suffix present, validate prefix length 0-32
    if [[ "$ip" == */* ]]; then
        local prefix="${ip##*/}"
        [ "$prefix" -ge 0 ] && [ "$prefix" -le 32 ] || return 1
    fi
    return 0
}

# Get current SSH client IP (the IP you're connecting from)
get_my_ssh_ip(){
    echo "$SSH_CLIENT" | awk '{print $1}'
}

# Get server's public IP
get_server_ip(){
    curl -s --connect-timeout 5 ifconfig.me 2>/dev/null
}

# Check if IP is protected (own IP, localhost, private ranges, known CDN)
is_protected_ip(){
    local CHECK_IP="$1"
    local BARE_IP="${CHECK_IP%%/*}"

    # Localhost
    [[ "$BARE_IP" == "127."* ]] && return 0

    # Private ranges
    [[ "$BARE_IP" == "10."* ]] && return 0
    [[ "$BARE_IP" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && return 0
    [[ "$BARE_IP" == "192.168."* ]] && return 0

    # Cloudflare IP ranges (proxy — blocking these breaks all CF-proxied sites)
    [[ "$BARE_IP" =~ ^(103\.21\.244\.|103\.22\.200\.|103\.31\.4\.|104\.16\.|104\.17\.|104\.18\.|104\.19\.|104\.20\.|104\.21\.|108\.162\.192\.|131\.0\.72\.|141\.101\.64\.|162\.158\.|172\.64\.|172\.65\.|172\.66\.|172\.67\.|173\.245\.48\.|188\.114\.96\.|190\.93\.240\.|197\.234\.240\.|198\.41\.128\.) ]] && return 0

    # Google crawlers / services
    [[ "$BARE_IP" =~ ^(66\.249\.|64\.233\.|72\.14\.|209\.85\.|216\.239\.|74\.125\.) ]] && return 0

    # Current SSH session IP (most critical — blocking this = lockout)
    local MY_SSH_IP
    MY_SSH_IP=$(get_my_ssh_ip)
    if [ -n "$MY_SSH_IP" ] && [ "$BARE_IP" = "$MY_SSH_IP" ]; then
        return 0
    fi

    # Server's own public IP
    local SERVER_IP
    SERVER_IP=$(get_server_ip)
    if [ -n "$SERVER_IP" ] && [ "$BARE_IP" = "$SERVER_IP" ]; then
        return 0
    fi

    # Check if CIDR range contains our SSH IP
    if [[ "$CHECK_IP" == *"/"* ]] && [ -n "$MY_SSH_IP" ]; then
        if command -v python3 >/dev/null 2>&1; then
            python3 -c "
import ipaddress, sys
try:
    net = ipaddress.ip_network('$CHECK_IP', strict=False)
    ip = ipaddress.ip_address('$MY_SSH_IP')
    sys.exit(0 if ip in net else 1)
except: sys.exit(1)
" 2>/dev/null && return 0
        fi
    fi

    return 1
}

block_ip(){
    ensure_firewall
    read -p "IP to block (e.g. 1.2.3.4 or 1.2.3.0/24): " IP

    if ! validate_ip "$IP"; then
        fail "Invalid IP address"; return
    fi

    # Safety check: prevent blocking own IP or critical IPs
    if is_protected_ip "$IP"; then
        local MY_SSH_IP
        MY_SSH_IP=$(get_my_ssh_ip)
        echo ""
        fail "BLOCKED: Cannot block this IP!"
        echo ""
        if [ "${IP%%/*}" = "$MY_SSH_IP" ]; then
            echo -e "  ${RED}This is YOUR current SSH IP ($MY_SSH_IP)${RESET}"
            echo -e "  ${RED}Blocking it would lock you out of the server!${RESET}"
        elif [[ "${IP%%/*}" == "127."* ]] || [[ "${IP%%/*}" == "10."* ]] || [[ "${IP%%/*}" == "192.168."* ]] || [[ "${IP%%/*}" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]]; then
            echo -e "  ${RED}This is a localhost/private IP range${RESET}"
        else
            echo -e "  ${RED}This is the server's own public IP${RESET}"
        fi
        echo ""
        log_ip_event "PREVENTED" "$IP" "block prevented: protected IP" "safety"
        return
    fi

    ZONE=$(firewall-cmd --get-default-zone)

    if firewall-cmd --zone="$ZONE" --list-rich-rules | grep -q "\"$IP\""; then
        warn "IP $IP already has a rule"; return
    fi

    # Confirmation before blocking
    local MY_SSH_IP
    MY_SSH_IP=$(get_my_ssh_ip)
    echo ""
    echo -e "  ${YELLOW}About to block: $IP${RESET}"
    [ -n "$MY_SSH_IP" ] && echo -e "  Your SSH IP  : $MY_SSH_IP"
    echo ""
    read -p "Confirm block this IP? [y/N]: " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Cancelled."; return; }

    firewall-cmd --zone="$ZONE" --permanent \
        --add-rich-rule="rule family='ipv4' source address='$IP' reject" && \
    firewall-cmd --reload && { ok "IP $IP blocked"; log_ip_event "BLOCKED" "$IP" "manual block" "user"; } || fail "Failed to block IP $IP"
}

whitelist_ip(){
    ensure_firewall
    read -p "IP to whitelist (e.g. 1.2.3.4): " IP

    if ! validate_ip "$IP"; then
        fail "Invalid IP address"; return
    fi

    ZONE=$(firewall-cmd --get-default-zone)

    if firewall-cmd --zone="$ZONE" --list-rich-rules | grep -q "\"$IP\""; then
        warn "IP $IP already has a rule"; return
    fi

    firewall-cmd --zone="$ZONE" --permanent \
        --add-rich-rule="rule family='ipv4' source address='$IP' accept" && \
    firewall-cmd --reload && { ok "IP $IP whitelisted"; log_ip_event "WHITELISTED" "$IP" "manual whitelist" "user"; } || fail "Failed to whitelist IP $IP"
}

list_blocked_ips(){
    ensure_firewall
    echo ""
    echo "======================================"
    echo "  BLOCKED / WHITELISTED IPs"
    echo "======================================"
    RULES=$(firewall-cmd --list-rich-rules 2>/dev/null)
    if [ -z "$RULES" ]; then
        echo "  No rules found."
    else
        echo "$RULES" | while read rule; do
            echo "  $rule"
        done
    fi
    echo "======================================"
}

unblock_ip(){
    ensure_firewall
    echo ""
    echo "Current rich rules:"
    firewall-cmd --list-rich-rules
    echo ""
    read -p "IP to unblock/remove: " IP

    if ! validate_ip "$IP"; then
        fail "Invalid IP address"; return
    fi

    ZONE=$(firewall-cmd --get-default-zone)

    # Xóa cả reject lẫn accept rule
    firewall-cmd --zone="$ZONE" --permanent \
        --remove-rich-rule="rule family='ipv4' source address='$IP' reject" 2>/dev/null
    firewall-cmd --zone="$ZONE" --permanent \
        --remove-rich-rule="rule family='ipv4' source address='$IP' accept" 2>/dev/null

    firewall-cmd --reload && { ok "IP $IP rule removed"; log_ip_event "UNBLOCKED" "$IP" "manual unblock" "user"; } || fail "Failed to remove rule"
}

fail2ban_ssh(){

    ensure_fail2ban

    echo "Configuring Fail2ban SSH protection..."

    # =========================
    # AUTO DETECT LOG PATH
    # =========================
    if [ -f /var/log/secure ]; then
        LOGPATH="/var/log/secure"
    elif [ -f /var/log/auth.log ]; then
        LOGPATH="/var/log/auth.log"
    else
        fail "Cannot detect SSH log file"
        return
    fi

    # =========================
    # JAIL CONFIG (FIXED)
    # =========================
    # Auto-detect current SSH IP to whitelist
    local MY_SSH_IP
    MY_SSH_IP=$(get_my_ssh_ip)
    local IGNORE_IP="127.0.0.1/8 ::1"
    if [ -n "$MY_SSH_IP" ]; then
        IGNORE_IP="$IGNORE_IP $MY_SSH_IP"
        info "Your SSH IP ($MY_SSH_IP) will be whitelisted in fail2ban"
    fi

    cat > /etc/fail2ban/jail.d/sshd.conf <<EOF
[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = $LOGPATH
backend  = auto

# ===== PROTECTION =====
maxretry = 5
findtime = 60
bantime  = 3600

# ===== WHITELIST (prevent self-lockout) =====
ignoreip = $IGNORE_IP

# ===== ACTION =====
banaction = firewallcmd-ipset
EOF

    # =========================
    # TEST CONFIG TRƯỚC KHI START
    # =========================
    fail2ban-client -t

    if [ $? -ne 0 ]; then
        fail "Fail2ban config error"
        return
    fi

    systemctl restart fail2ban

    sleep 1

    if systemctl is-active --quiet fail2ban; then
        ok "Fail2ban SSH protection enabled"
    else
        fail "Fail2ban failed to start"
        echo ""
        echo "👉 Debug log:"
        journalctl -u fail2ban --no-pager -n 20
    fi
}



# ==================================================
# FAIL2BAN WORDPRESS
# ==================================================

enable_wp_bruteforce(){
    ensure_fail2ban

    # Auto-detect current SSH IP to whitelist
    local MY_SSH_IP
    MY_SSH_IP=$(get_my_ssh_ip)
    local IGNORE_IP="127.0.0.1/8 ::1"
    if [ -n "$MY_SSH_IP" ]; then
        IGNORE_IP="$IGNORE_IP $MY_SSH_IP"
        info "Your IP ($MY_SSH_IP) will be whitelisted in WP jail"
    fi

    cat > /etc/fail2ban/jail.d/wordpress.conf <<EOF
[wordpress]
enabled  = true
port     = http,https
filter   = wordpress
logpath  = /var/log/nginx/domains/*/access.log
maxretry = 5
findtime = 600
bantime  = 3600
ignoreip = $IGNORE_IP
EOF

    cat > /etc/fail2ban/filter.d/wordpress.conf <<'EOF'
[Definition]
failregex = ^<HOST> -.*"(POST /wp-login\.php|POST /xmlrpc\.php)
ignoreregex =
EOF

    systemctl restart fail2ban && \
        ok "WordPress bruteforce protection enabled" || \
        fail "fail2ban restart failed"
}

block_bot_countries_real(){

    ensure_firewall

    echo "Downloading country IP list (CN, RU)..."

    TMP_DIR="/tmp/shieldpress-geo"
    mkdir -p "$TMP_DIR"

    curl -s https://www.ipdeny.com/ipblocks/data/countries/cn.zone -o "$TMP_DIR/cn.zone"
    curl -s https://www.ipdeny.com/ipblocks/data/countries/ru.zone -o "$TMP_DIR/ru.zone"

    echo "Preparing ipset (fast mode)..."

    # create kernel ipset
    ipset create shieldpress_geo hash:net -exist
    ipset flush shieldpress_geo 2>/dev/null

    # import nhanh (KHÔNG loop firewall)
    {
        echo "create shieldpress_geo hash:net -exist"
        sed 's/^/add shieldpress_geo /' "$TMP_DIR/cn.zone"
        sed 's/^/add shieldpress_geo /' "$TMP_DIR/ru.zone"
    } | ipset restore

    echo "Scanning logs → block only bot behavior..."
    echo "(Your IP and server IP are protected from blocking)"

    BLOCK_COUNT=0
    MY_SSH_IP=$(get_my_ssh_ip)
    SERVER_IP=$(get_server_ip)

    grep -E "wp-login|xmlrpc|wp-admin" /var/log/nginx/domains/*/access.log 2>/dev/null | \
    awk '{print $1}' | sort | uniq -c | sort -nr | \
    while read count ip; do

        if [ "$count" -gt 30 ]; then

            # Safety: skip own IP and server IP
            if is_protected_ip "$ip"; then
                echo "Skipped (protected): $ip ($count hits)"
                log_ip_event "PREVENTED" "$ip" "geo-block skipped: protected IP ($count hits)" "safety"
                continue
            fi

            # chỉ block nếu IP thuộc CN/RU
            ipset test shieldpress_geo "$ip" &>/dev/null

            if [ $? -eq 0 ]; then
                firewall-cmd --permanent \
                    --add-rich-rule="rule family='ipv4' source address='$ip' reject" 2>/dev/null

                echo "Blocked BOT: $ip ($count hits)"
                log_ip_event "BLOCKED" "$ip" "geo-bot: $count hits on wp-login/xmlrpc" "geo-block"
                BLOCK_COUNT=$((BLOCK_COUNT+1))
            fi
        fi

    done

    firewall-cmd --reload

    ok "SMART Geo block applied (only bots, not users)"
}

unblock_bot_countries_real(){

    ensure_firewall

    echo "Removing Geo bot block..."

    # Only remove rules that reference the shieldpress_geo ipset (geo-block rules)
    # Do NOT remove user's manually blocked IPs
    firewall-cmd --list-rich-rules | while read -r rule; do
        if echo "$rule" | grep -q "shieldpress_geo"; then
            firewall-cmd --permanent --remove-rich-rule="$rule" 2>/dev/null
        fi
    done

    # Also remove rules that were created by geo-bot blocking (IPs from ipset)
    if ipset list shieldpress_geo &>/dev/null; then
        ipset list shieldpress_geo | awk '/^[0-9]/{print $1}' | while read -r ip; do
            firewall-cmd --permanent --remove-rich-rule="rule family='ipv4' source address='$ip' reject" 2>/dev/null
        done
    fi

    firewall-cmd --reload

    # xoá ipset kernel
    ipset destroy shieldpress_geo 2>/dev/null

    # xoá temp
    rm -rf /tmp/shieldpress-geo

    ok "Geo bot block removed completely"
}

view_ip_block_history(){
    echo ""
    echo "======================================"
    echo "  IP BLOCK HISTORY"
    echo "======================================"

    if [ ! -f "$IP_HISTORY_FILE" ] || [ ! -s "$IP_HISTORY_FILE" ]; then
        echo "  No history records found."
        echo "======================================"
        return
    fi

    local TOTAL=$(wc -l < "$IP_HISTORY_FILE")
    echo "  Total events: $TOTAL"
    echo ""

    # Summary by action
    echo -e "  ${BOLD}Summary:${RESET}"
    echo "  ─────────────────────────────────────"
    local BLOCKED_COUNT=$(grep -c "| BLOCKED |" "$IP_HISTORY_FILE" 2>/dev/null || echo 0)
    local WHITELISTED_COUNT=$(grep -c "| WHITELISTED |" "$IP_HISTORY_FILE" 2>/dev/null || echo 0)
    local UNBLOCKED_COUNT=$(grep -c "| UNBLOCKED |" "$IP_HISTORY_FILE" 2>/dev/null || echo 0)
    local BANNED_COUNT=$(grep -c "| BANNED |" "$IP_HISTORY_FILE" 2>/dev/null || echo 0)
    local UNBANNED_COUNT=$(grep -c "| UNBANNED |" "$IP_HISTORY_FILE" 2>/dev/null || echo 0)

    printf "  ${RED}%-12s${RESET} %s\n" "Blocked" "$BLOCKED_COUNT"
    printf "  ${GREEN}%-12s${RESET} %s\n" "Whitelisted" "$WHITELISTED_COUNT"
    printf "  ${YELLOW}%-12s${RESET} %s\n" "Unblocked" "$UNBLOCKED_COUNT"
    printf "  ${RED}%-12s${RESET} %s\n" "Banned" "$BANNED_COUNT"
    printf "  ${GREEN}%-12s${RESET} %s\n" "Unbanned" "$UNBANNED_COUNT"

    # Top blocked IPs
    echo ""
    echo -e "  ${BOLD}Top Blocked IPs:${RESET}"
    echo "  ─────────────────────────────────────"
    grep "| BLOCKED |" "$IP_HISTORY_FILE" 2>/dev/null | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}' | sort | uniq -c | sort -nr | head -10 | while read count ip; do
        printf "  ${RED}%-6s${RESET} %s\n" "${count}x" "$ip"
    done

    # Recent events
    echo ""
    echo -e "  ${BOLD}Recent Events (last 20):${RESET}"
    echo "  ─────────────────────────────────────"
    printf "  ${DIM}%-20s %-12s %-18s %-12s %s${RESET}\n" "Date" "Action" "IP" "Source" "Reason"
    echo "  ─────────────────────────────────────"
    tail -20 "$IP_HISTORY_FILE" | tac | while IFS='|' read DATE ACTION IP REASON SOURCE; do
        DATE=$(echo "$DATE" | xargs)
        ACTION=$(echo "$ACTION" | xargs)
        IP=$(echo "$IP" | xargs)
        REASON=$(echo "$REASON" | xargs)
        SOURCE=$(echo "$SOURCE" | xargs)

        local COLOR="$RESET"
        case "$ACTION" in
            BLOCKED|BANNED) COLOR="$RED" ;;
            WHITELISTED|UNBANNED) COLOR="$GREEN" ;;
            UNBLOCKED) COLOR="$YELLOW" ;;
        esac

        printf "  %-20s ${COLOR}%-12s${RESET} %-18s %-12s %s\n" "$DATE" "$ACTION" "$IP" "$SOURCE" "$REASON"
    done

    echo "======================================"
}

fail2ban_ssh_manager(){

    ensure_fail2ban

    while true; do
        echo ""
        echo "======================================"
        echo "   FAIL2BAN SSH MANAGER"
        echo "======================================"
        echo " 1) List banned IP"
        echo " 2) Unban IP"
        echo " 0) Back"
        echo "--------------------------------------"

        read -p "Select: " sub

        case $sub in

            1)
                echo ""
                echo "===== BANNED IP LIST ====="
                fail2ban-client status sshd
                ;;

            2)
                read -p "Enter IP to unban: " IP

                if [ -z "$IP" ]; then
                    fail "IP cannot be empty"
                    continue
                fi

                if ! validate_ip "$IP"; then
                    fail "Invalid IP address format"
                    continue
                fi

                fail2ban-client set sshd unbanip "$IP"

                if [ $? -eq 0 ]; then
                    ok "Unbanned $IP"
                    log_ip_event "UNBANNED" "$IP" "manual unban from fail2ban SSH" "fail2ban"
                else
                    fail "Failed or IP not found"
                fi
                ;;

            0)
                break
                ;;

            *)
                echo "Invalid option"
                ;;
        esac

        echo ""
        read -p "Press Enter..."

    done
}


# ==================================================
# FAIL2BAN NGINX PROTECTION
# ==================================================

fail2ban_nginx(){
    ensure_fail2ban

    echo ""
    echo "======================================"
    echo "  FAIL2BAN NGINX PROTECTION"
    echo "======================================"
    echo ""
    echo "This will block IPs with excessive bad requests:"
    echo "  - 403/404 errors (scanners, bots)"
    echo "  - 5xx errors (exploit attempts)"
    echo ""

    # Auto-detect current SSH IP to whitelist
    local MY_SSH_IP
    MY_SSH_IP=$(get_my_ssh_ip)
    local IGNORE_IP="127.0.0.1/8 ::1"
    if [ -n "$MY_SSH_IP" ]; then
        IGNORE_IP="$IGNORE_IP $MY_SSH_IP"
        info "Your IP ($MY_SSH_IP) will be whitelisted"
    fi

    # Jail 1: Nginx 403/404 abuse
    cat > /etc/fail2ban/jail.d/nginx-badbots.conf <<EOF
[nginx-badbots]
enabled  = true
port     = http,https
filter   = nginx-badbots
logpath  = /var/log/nginx/domains/*/access.log
maxretry = 30
findtime = 60
bantime  = 3600
ignoreip = $IGNORE_IP
banaction = firewallcmd-ipset
EOF

    cat > /etc/fail2ban/filter.d/nginx-badbots.conf <<'EOF'
[Definition]
failregex = ^<HOST> -.*" (403|404) [0-9]+ "
ignoreregex = \.(css|js|jpg|jpeg|png|gif|ico|svg|woff|woff2|ttf|eot)
EOF

    # Jail 2: Nginx 5xx exploit
    cat > /etc/fail2ban/jail.d/nginx-5xx.conf <<EOF
[nginx-5xx]
enabled  = true
port     = http,https
filter   = nginx-5xx
logpath  = /var/log/nginx/domains/*/access.log
maxretry = 15
findtime = 120
bantime  = 7200
ignoreip = $IGNORE_IP
banaction = firewallcmd-ipset
EOF

    cat > /etc/fail2ban/filter.d/nginx-5xx.conf <<'EOF'
[Definition]
failregex = ^<HOST> -.*" (500|502|503|504) [0-9]+ "
ignoreregex =
EOF

    # Test config
    if ! fail2ban-client -t 2>/dev/null; then
        fail "Fail2ban config error"
        echo ""
        echo "Debug:"
        fail2ban-client -t
        return
    fi

    systemctl restart fail2ban
    sleep 1

    if systemctl is-active --quiet fail2ban; then
        ok "Nginx protection enabled:"
        echo "  - nginx-badbots: 30 errors/60s → ban 1h"
        echo "  - nginx-5xx: 15 errors/120s → ban 2h"
    else
        fail "Fail2ban failed to start"
        journalctl -u fail2ban --no-pager -n 10
    fi
}

fail2ban_nginx_manager(){
    ensure_fail2ban

    while true; do
        echo ""
        echo "======================================"
        echo "  FAIL2BAN NGINX MANAGER"
        echo "======================================"

        local JAILS=("nginx-badbots" "nginx-5xx")
        for jail in "${JAILS[@]}"; do
            if fail2ban-client status "$jail" &>/dev/null; then
                local BANNED=$(fail2ban-client status "$jail" 2>/dev/null | grep "Banned IP" | cut -d: -f2 | xargs)
                local COUNT=$(fail2ban-client status "$jail" 2>/dev/null | grep "Currently banned" | grep -oP '[0-9]+')
                printf "  %-16s: %s banned\n" "$jail" "${COUNT:-0}"
            else
                printf "  %-16s: not active\n" "$jail"
            fi
        done

        echo "--------------------------------------"
        echo "  1) Show banned IPs"
        echo "  2) Unban IP"
        echo "  3) Disable Nginx jails"
        echo "  0) Back"
        echo "--------------------------------------"
        read -p "Select: " sub

        case $sub in
            1)
                for jail in "${JAILS[@]}"; do
                    echo ""
                    echo "=== $jail ==="
                    fail2ban-client status "$jail" 2>/dev/null || echo "  Not active"
                done
                ;;
            2)
                read -p "IP to unban: " IP
                [ -z "$IP" ] && { fail "IP required"; continue; }
                local FOUND=0
                for jail in "${JAILS[@]}"; do
                    if fail2ban-client set "$jail" unbanip "$IP" 2>/dev/null; then
                        ok "Unbanned $IP from $jail"
                        log_ip_event "UNBANNED" "$IP" "manual unban from $jail" "fail2ban"
                        FOUND=1
                    fi
                done
                [ "$FOUND" -eq 0 ] && warn "IP not found in any Nginx jail"
                ;;
            3)
                rm -f /etc/fail2ban/jail.d/nginx-badbots.conf
                rm -f /etc/fail2ban/jail.d/nginx-5xx.conf
                systemctl restart fail2ban
                ok "Nginx fail2ban jails disabled"
                ;;
            0) break ;;
            *) echo "Invalid" ;;
        esac

        echo ""
        read -p "Press Enter..."
    done
}

# ==================================================
# SSH HARDENING
# ==================================================

ssh_hardening(){
    local SSHD_CONF="/etc/ssh/sshd_config"

    if [ ! -f "$SSHD_CONF" ]; then
        fail "sshd_config not found"
        return
    fi

    while true; do
        echo ""
        echo "======================================"
        echo "  SSH HARDENING"
        echo "======================================"

        # Current status
        local CURRENT_PORT=$(grep -E "^[[:space:]]*Port[[:space:]]" "$SSHD_CONF" 2>/dev/null | awk '{print $2}' | head -1)
        CURRENT_PORT="${CURRENT_PORT:-22}"
        local PASS_AUTH=$(grep -Ei "^[[:space:]]*PasswordAuthentication[[:space:]]" "$SSHD_CONF" 2>/dev/null | awk '{print $2}' | head -1)
        PASS_AUTH="${PASS_AUTH:-yes}"
        local ROOT_LOGIN=$(grep -Ei "^[[:space:]]*PermitRootLogin[[:space:]]" "$SSHD_CONF" 2>/dev/null | awk '{print $2}' | head -1)
        ROOT_LOGIN="${ROOT_LOGIN:-yes}"

        local KEY_COUNT=$(cat /root/.ssh/authorized_keys 2>/dev/null | grep -c "^ssh-" || echo 0)

        echo ""
        echo "  Current SSH config:"
        echo "  ─────────────────────────────────────"
        printf "  SSH Port              : %s\n" "$CURRENT_PORT"
        printf "  Password Auth         : %s\n" "$PASS_AUTH"
        printf "  Root Login            : %s\n" "$ROOT_LOGIN"
        printf "  Authorized Keys       : %s key(s)\n" "$KEY_COUNT"
        echo "  ─────────────────────────────────────"
        echo ""
        echo "  1) Change SSH Port"
        echo "  2) Disable Password Auth (key-only)"
        echo "  3) Enable Password Auth"
        echo "  0) Back"
        echo ""
        read -p "Select: " sub

        case $sub in
            1) ssh_change_port "$CURRENT_PORT" ;;
            2) ssh_disable_password "$KEY_COUNT" ;;
            3) ssh_enable_password ;;
            0) break ;;
            *) echo "Invalid" ;;
        esac

        echo ""
        read -p "Press Enter..."
    done
}

ssh_change_port(){
    local OLD_PORT="${1:-22}"
    local SSHD_CONF="/etc/ssh/sshd_config"

    echo ""
    echo "Current SSH port: $OLD_PORT"
    read -p "New SSH port (1024-65535) [2222]: " NEW_PORT
    NEW_PORT="${NEW_PORT:-2222}"

    # Validate
    if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1024 ] || [ "$NEW_PORT" -gt 65535 ]; then
        fail "Invalid port. Use 1024-65535"
        return
    fi

    # Check if port is already in use
    if ss -tuln | grep -q ":${NEW_PORT} "; then
        fail "Port $NEW_PORT is already in use"
        return
    fi

    echo ""
    warn "IMPORTANT: After changing SSH port, you must connect with:"
    echo "  ssh -p $NEW_PORT root@your-server"
    echo ""
    echo "  Old port $OLD_PORT will be closed."
    echo "  New port $NEW_PORT will be opened in firewall."
    echo ""
    read -p "Confirm change? (yes/no): " CONFIRM
    [ "$CONFIRM" = "yes" ] || { echo "Cancelled."; return; }

    # Backup sshd_config
    cp "$SSHD_CONF" "${SSHD_CONF}.bak.$(date +%s)"

    # Update port in sshd_config
    if grep -qE "^[[:space:]]*Port[[:space:]]" "$SSHD_CONF"; then
        sed -i "s/^[[:space:]]*Port[[:space:]].*/Port $NEW_PORT/" "$SSHD_CONF"
    elif grep -qE "^[[:space:]]*#[[:space:]]*Port[[:space:]]" "$SSHD_CONF"; then
        sed -i "s/^[[:space:]]*#[[:space:]]*Port[[:space:]].*/Port $NEW_PORT/" "$SSHD_CONF"
    else
        echo "Port $NEW_PORT" >> "$SSHD_CONF"
    fi

    # Update SELinux if present
    if command -v semanage &>/dev/null; then
        semanage port -a -t ssh_port_t -p tcp "$NEW_PORT" 2>/dev/null || \
        semanage port -m -t ssh_port_t -p tcp "$NEW_PORT" 2>/dev/null
    fi

    # Update firewall: open new port FIRST, then close old
    ensure_firewall
    local ZONE=$(firewall-cmd --get-default-zone)
    firewall-cmd --zone="$ZONE" --permanent --add-port="${NEW_PORT}/tcp" >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1

    # Test sshd config before restart
    if ! sshd -t 2>/dev/null; then
        fail "sshd config test failed! Reverting..."
        cp "${SSHD_CONF}.bak."* "$SSHD_CONF" 2>/dev/null
        firewall-cmd --zone="$ZONE" --permanent --remove-port="${NEW_PORT}/tcp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        return
    fi

    # Restart sshd
    systemctl restart sshd

    if systemctl is-active --quiet sshd; then
        # Close old port (only if different)
        if [ "$OLD_PORT" != "$NEW_PORT" ]; then
            firewall-cmd --zone="$ZONE" --permanent --remove-service=ssh 2>/dev/null
            firewall-cmd --zone="$ZONE" --permanent --remove-port="${OLD_PORT}/tcp" 2>/dev/null
            firewall-cmd --reload >/dev/null 2>&1
        fi

        # Update fail2ban SSH jail port if exists
        if [ -f /etc/fail2ban/jail.d/sshd.conf ]; then
            sed -i "s/^port[[:space:]]*=.*/port = $NEW_PORT/" /etc/fail2ban/jail.d/sshd.conf
            systemctl restart fail2ban 2>/dev/null
        fi

        ok "SSH port changed: $OLD_PORT → $NEW_PORT"
        echo ""
        echo -e "  ${YELLOW}${BOLD}Connect with: ssh -p $NEW_PORT root@your-server${RESET}"
        log "SSH port changed from $OLD_PORT to $NEW_PORT"
    else
        fail "sshd failed to restart! Reverting..."
        cp "${SSHD_CONF}.bak."* "$SSHD_CONF" 2>/dev/null
        systemctl restart sshd
        firewall-cmd --zone="$ZONE" --permanent --remove-port="${NEW_PORT}/tcp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
}

ssh_disable_password(){
    local KEY_COUNT="${1:-0}"
    local SSHD_CONF="/etc/ssh/sshd_config"

    echo ""

    # Safety: check if user has SSH keys
    if [ "$KEY_COUNT" -eq 0 ]; then
        echo ""
        fail "NO SSH KEYS FOUND!"
        echo ""
        echo -e "  ${RED}You have no authorized_keys configured.${RESET}"
        echo -e "  ${RED}Disabling password auth will LOCK YOU OUT!${RESET}"
        echo ""
        echo "  First add your SSH key:"
        echo "    1. On your LOCAL machine, run: ssh-keygen"
        echo "    2. Copy key to server: ssh-copy-id root@your-server"
        echo "    3. Then come back and disable password auth"
        echo ""
        return
    fi

    echo "  Found $KEY_COUNT SSH key(s) in authorized_keys."
    echo ""
    warn "After this change, you can ONLY login with SSH key."
    echo "  Password login will be completely disabled."
    echo ""
    read -p "Confirm disable password auth? (yes/no): " CONFIRM
    [ "$CONFIRM" = "yes" ] || { echo "Cancelled."; return; }

    # Backup
    cp "$SSHD_CONF" "${SSHD_CONF}.bak.$(date +%s)"

    # Update config
    if grep -qEi "^[[:space:]]*PasswordAuthentication" "$SSHD_CONF"; then
        sed -i 's/^[[:space:]]*PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONF"
    elif grep -qEi "^[[:space:]]*#[[:space:]]*PasswordAuthentication" "$SSHD_CONF"; then
        sed -i 's/^[[:space:]]*#[[:space:]]*PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONF"
    else
        echo "PasswordAuthentication no" >> "$SSHD_CONF"
    fi

    if ! sshd -t 2>/dev/null; then
        fail "sshd config test failed! Reverting..."
        cp "${SSHD_CONF}.bak."* "$SSHD_CONF" 2>/dev/null
        return
    fi

    systemctl restart sshd
    if systemctl is-active --quiet sshd; then
        ok "Password authentication disabled (key-only)"
        log "SSH password auth disabled"
    else
        fail "sshd failed! Reverting..."
        cp "${SSHD_CONF}.bak."* "$SSHD_CONF" 2>/dev/null
        systemctl restart sshd
    fi
}

ssh_enable_password(){
    local SSHD_CONF="/etc/ssh/sshd_config"

    cp "$SSHD_CONF" "${SSHD_CONF}.bak.$(date +%s)"

    if grep -qEi "^[[:space:]]*PasswordAuthentication" "$SSHD_CONF"; then
        sed -i 's/^[[:space:]]*PasswordAuthentication.*/PasswordAuthentication yes/' "$SSHD_CONF"
    else
        echo "PasswordAuthentication yes" >> "$SSHD_CONF"
    fi

    if ! sshd -t 2>/dev/null; then
        fail "sshd config test failed! Reverting..."
        cp "${SSHD_CONF}.bak."* "$SSHD_CONF" 2>/dev/null
        return
    fi

    systemctl restart sshd
    if systemctl is-active --quiet sshd; then
        ok "Password authentication enabled"
        log "SSH password auth enabled"
    else
        fail "sshd failed! Reverting..."
        cp "${SSHD_CONF}.bak."* "$SSHD_CONF" 2>/dev/null
        systemctl restart sshd
    fi
}

# ==================================================
# AUTO-BLOCK ATTACKERS
# ==================================================

auto_block_attackers(){
    ensure_firewall

    echo ""
    echo "======================================"
    echo "  AUTO-BLOCK ATTACKERS"
    echo "======================================"
    echo ""

    local THRESHOLD=200
    local BAN_HOURS=24
    local BLOCKED_COUNT=0
    local SKIPPED_COUNT=0
    local ALREADY_COUNT=0

    read -p "Block threshold (requests/10min) [$THRESHOLD]: " CUSTOM_THRESHOLD
    THRESHOLD="${CUSTOM_THRESHOLD:-$THRESHOLD}"

    echo ""
    echo "Block duration:"
    echo "  1) 1 hour    (recommended for auto-guard)"
    echo "  2) 6 hours"
    echo "  3) 24 hours  (default)"
    echo "  4) Permanent (manual block only)"
    echo ""
    read -p "Select [3]: " BAN_OPT
    case "${BAN_OPT:-3}" in
        1) BAN_HOURS=1 ;;
        2) BAN_HOURS=6 ;;
        3) BAN_HOURS=24 ;;
        4) BAN_HOURS=0 ;;  # 0 = permanent
    esac

    _do_auto_block "$THRESHOLD" "$BAN_HOURS"
}

# Internal function — dùng cả cho manual và Auto-Guard
_do_auto_block(){
    local THRESHOLD="${1:-200}"
    local BAN_HOURS="${2:-1}"
    local BLOCKED_COUNT=0
    local SKIPPED_COUNT=0
    local ALREADY_COUNT=0

    # Cutoff timestamp: 10 phút trước, định dạng nginx log (dd/Mon/yyyy:HH:MM)
    local CUTOFF
    CUTOFF=$(date -d '10 minutes ago' '+%d/%b/%Y:%H:%M' 2>/dev/null)

    echo ""
    echo "Analyzing last 10 minutes of traffic..."
    echo "Threshold : $THRESHOLD requests/10min"
    if [ "$BAN_HOURS" -eq 0 ] 2>/dev/null; then
        echo "Ban type  : PERMANENT"
    else
        echo "Ban type  : ${BAN_HOURS}h (auto-unblock after ${BAN_HOURS} hours)"
    fi
    echo "----------------------------------------------------"

    # Chỉ đọc log files được ghi trong 15 phút gần nhất
    local LOG_FILES
    LOG_FILES=$(find /var/log/nginx/domains -name access.log -mmin -15 2>/dev/null)
    [ -z "$LOG_FILES" ] && { ok "No recent log activity"; return; }

    # Đếm IP theo thời gian thực — lọc theo cutoff timestamp
    local ABUSIVE_IPS
    ABUSIVE_IPS=$(echo "$LOG_FILES" | xargs awk -v cutoff="$CUTOFF" '
    {
        # Nginx log format: IP - - [dd/Mon/yyyy:HH:MM:SS +zone] ...
        # So sánh timestamp phần HH:MM với cutoff
        match($4, /\[([^]]+)\]/, a)
        ts = substr(a[1], 1, 17)  # dd/Mon/yyyy:HH:MM
        if (ts >= cutoff) {
            total[$1]++
            if ($9 ~ /^4/) bad[$1]++
        }
    }
    END {
        for (ip in total) {
            if (total[ip] >= '"$THRESHOLD"' || bad[ip] >= 50)
                printf "%s %s %s\n", total[ip], bad[ip], ip
        }
    }' 2>/dev/null | sort -rn)

    if [ -z "$ABUSIVE_IPS" ]; then
        ok "No abusive IPs in last 10 minutes"
        return
    fi

    local ZONE
    ZONE=$(firewall-cmd --get-default-zone)
    local EXISTING_RULES
    EXISTING_RULES=$(firewall-cmd --zone="$ZONE" --list-rich-rules 2>/dev/null)

    echo ""
    printf "  %-8s %-8s %-18s %s\n" "TOTAL" "4xx" "IP" "ACTION"
    echo "  ─────────────────────────────────────────────"

    while read -r HITS BAD IP; do
        [ -z "$IP" ] && continue

        # Skip protected IPs (SSH, private, Cloudflare, Google...)
        if is_protected_ip "$IP"; then
            printf "  %-8s %-8s %-18s ${GREEN}skip (protected)${RESET}\n" "$HITS" "$BAD" "$IP"
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
            continue
        fi

        # Skip already blocked
        if echo "$EXISTING_RULES" | grep -q "\"$IP\""; then
            printf "  %-8s %-8s %-18s ${DIM}already blocked${RESET}\n" "$HITS" "$BAD" "$IP"
            ALREADY_COUNT=$((ALREADY_COUNT + 1))
            continue
        fi

        printf "  %-8s %-8s %-18s ${RED}→ BLOCK${RESET}\n" "$HITS" "$BAD" "$IP"

        if [ "$BAN_HOURS" -eq 0 ] 2>/dev/null; then
            # Block vĩnh viễn — chỉ dùng khi người dùng chọn thủ công
            firewall-cmd --zone="$ZONE" --permanent \
                --add-rich-rule="rule family='ipv4' source address='$IP' reject" 2>/dev/null
            log_ip_event "BLOCKED" "$IP" "auto-block: ${HITS}req/${BAD}4xx (permanent)" "auto-scan"
        else
            # Block tạm thời — dùng rich-rule có timeout (giây)
            local BAN_SECS=$(( BAN_HOURS * 3600 ))
            firewall-cmd --zone="$ZONE" \
                --add-rich-rule="rule family='ipv4' source address='$IP' reject" \
                --timeout="$BAN_SECS" 2>/dev/null
            log_ip_event "BLOCKED" "$IP" "auto-block: ${HITS}req/${BAD}4xx (${BAN_HOURS}h TTL)" "auto-scan"
        fi

        BLOCKED_COUNT=$((BLOCKED_COUNT + 1))
    done <<< "$ABUSIVE_IPS"

    # Reload chỉ cần thiết cho --permanent
    if [ "$BAN_HOURS" -eq 0 ] && [ "$BLOCKED_COUNT" -gt 0 ] 2>/dev/null; then
        firewall-cmd --reload >/dev/null 2>&1
    fi

    echo ""
    echo "  ─────────────────────────────────────────────"
    echo "  Blocked: $BLOCKED_COUNT | Skipped: $SKIPPED_COUNT | Already: $ALREADY_COUNT"
    echo "======================================"

    if [ "$BLOCKED_COUNT" -gt 0 ] 2>/dev/null; then
        ok "Auto-block: $BLOCKED_COUNT IPs blocked"
        log "AUTO-BLOCK: $BLOCKED_COUNT IPs (threshold:${THRESHOLD}, ban:${BAN_HOURS}h)"
        if [ -f "$BASE_DIR/modules/notification/telegram-notify.sh" ]; then
            bash "$BASE_DIR/modules/notification/telegram-notify.sh" send "security_alert" \
                "Auto-block" "$BLOCKED_COUNT IPs blocked on $(hostname) (${BAN_HOURS}h)" 2>/dev/null
        fi
    else
        ok "No new IPs to block"
    fi
}

# ==================================================
# AUTO-GUARD — TỰ ĐỘNG BLOCK KHI VƯỢT NGƯỠNG
# ==================================================

AUTO_GUARD_CONF="/opt/shieldpress/config/auto-guard.conf"
AUTO_GUARD_SCRIPT="/opt/shieldpress/bin/auto-guard-check.sh"
AUTO_GUARD_TIMER="/etc/systemd/system/sp-auto-guard.timer"
AUTO_GUARD_SERVICE="/etc/systemd/system/sp-auto-guard.service"

auto_guard_status(){
    if systemctl is-active --quiet sp-auto-guard.timer 2>/dev/null; then
        echo -e "  Auto-Guard : ${GREEN}ENABLED${RESET}"
        if [ -f "$AUTO_GUARD_CONF" ]; then
            local T_REQ T_4XX T_WP
            T_REQ=$(grep "^THRESHOLD_TOTAL=" "$AUTO_GUARD_CONF" | cut -d= -f2)
            T_4XX=$(grep "^THRESHOLD_4XX="   "$AUTO_GUARD_CONF" | cut -d= -f2)
            T_WP=$(grep  "^THRESHOLD_WP="    "$AUTO_GUARD_CONF" | cut -d= -f2)
            echo "  Thresholds : requests>${T_REQ} | 4xx>${T_4XX} | wp-login>${T_WP} (per 10 min)"
        fi
    else
        echo -e "  Auto-Guard : ${DIM}DISABLED${RESET}"
    fi
}

enable_auto_guard(){
    echo ""
    echo "===================================================="
    echo "  AUTO-GUARD — TỰ ĐỘNG BLOCK ATTACKER"
    echo "===================================================="
    echo ""
    echo "Khi traffic trong 10 phút vượt ngưỡng, hệ thống sẽ:"
    echo "  1. Tự động block các IP tấn công nhiều nhất"
    echo "  2. Ghi log vào ip-block-history.log"
    echo "  3. Gửi thông báo (nếu Telegram đã cài)"
    echo ""
    echo "Cài đặt ngưỡng (để trống = dùng mặc định):"
    echo ""
    read -p "  Total requests / 10 min [50000]: " T_REQ
    read -p "  4xx errors / 10 min      [5000]:  " T_4XX
    read -p "  wp-login/xmlrpc / 10 min [1000]:  " T_WP
    read -p "  Kiểm tra mỗi (phút)      [5]:     " T_INTERVAL

    T_REQ="${T_REQ:-50000}"
    T_4XX="${T_4XX:-5000}"
    T_WP="${T_WP:-1000}"
    T_INTERVAL="${T_INTERVAL:-5}"

    # Validate: phải là số
    if ! [[ "$T_REQ" =~ ^[0-9]+$ ]] || ! [[ "$T_4XX" =~ ^[0-9]+$ ]] || \
       ! [[ "$T_WP" =~ ^[0-9]+$ ]]  || ! [[ "$T_INTERVAL" =~ ^[0-9]+$ ]]; then
        fail "Ngưỡng phải là số nguyên"; return
    fi

    mkdir -p "$(dirname "$AUTO_GUARD_CONF")"

    # Lưu config
    cat > "$AUTO_GUARD_CONF" <<EOF
THRESHOLD_TOTAL=$T_REQ
THRESHOLD_4XX=$T_4XX
THRESHOLD_WP=$T_WP
CHECK_INTERVAL_MIN=$T_INTERVAL
EOF

    # Tạo check script
    mkdir -p "$(dirname "$AUTO_GUARD_SCRIPT")"
    cat > "$AUTO_GUARD_SCRIPT" <<'SCRIPT'
#!/bin/bash
# ShieldPress Auto-Guard — chạy bởi systemd timer
BASE_DIR="/opt/shieldpress"

CONF="/opt/shieldpress/config/auto-guard.conf"
LOG="/opt/shieldpress/logs/auto-guard.log"
mkdir -p "$(dirname "$LOG")"

[ -f "$CONF" ] || exit 0

THRESHOLD_TOTAL=$(grep "^THRESHOLD_TOTAL=" "$CONF" | cut -d= -f2)
THRESHOLD_4XX=$(grep   "^THRESHOLD_4XX="   "$CONF" | cut -d= -f2)
THRESHOLD_WP=$(grep    "^THRESHOLD_WP="    "$CONF" | cut -d= -f2)

# Đọc stats 10 phút gần nhất — dùng proper cutoff timestamp
CUTOFF=$(date -d '10 minutes ago' '+%d/%b/%Y:%H:%M' 2>/dev/null)

_count_total_and_4xx(){
    find /var/log/nginx/domains -name access.log -mmin -15 -print0 2>/dev/null \
    | xargs -0 awk -v cutoff="$CUTOFF" '
    {
        match($4, /\[([^]]+)\]/, a)
        ts = substr(a[1], 1, 17)
        if (ts >= cutoff) {
            total++
            if ($9 ~ /^4/) bad++
        }
    }
    END { print total+0, bad+0 }' 2>/dev/null | awk '{t+=$1; b+=$2} END{print t+0, b+0}'
}

_count_wp(){
    find /var/log/nginx/domains -name access.log -mmin -15 -print0 2>/dev/null \
    | xargs -0 awk -v cutoff="$CUTOFF" '
    {
        match($4, /\[([^]]+)\]/, a)
        ts = substr(a[1], 1, 17)
        if (ts >= cutoff && /wp-login|xmlrpc/) c++
    }
    END { print c+0 }' 2>/dev/null | awk '{s+=$1} END{print s+0}'
}

read -r RECENT_TOTAL RECENT_4XX <<< "$(_count_total_and_4xx)"
WP_HITS=$(_count_wp)

TRIGGERED=0
REASON=""

[ "${RECENT_TOTAL:-0}" -gt "${THRESHOLD_TOTAL:-50000}" ] && { TRIGGERED=1; REASON="total:${RECENT_TOTAL}>${THRESHOLD_TOTAL}"; }
[ "${RECENT_4XX:-0}"   -gt "${THRESHOLD_4XX:-5000}" ]   && { TRIGGERED=1; REASON="${REASON} 4xx:${RECENT_4XX}>${THRESHOLD_4XX}"; }
[ "${WP_HITS:-0}"      -gt "${THRESHOLD_WP:-1000}" ]    && { TRIGGERED=1; REASON="${REASON} wp:${WP_HITS}>${THRESHOLD_WP}"; }

echo "$(date '+%Y-%m-%d %H:%M:%S') | CHECK | total=${RECENT_TOTAL} 4xx=${RECENT_4XX} wp=${WP_HITS}" >> "$LOG"

if [ "$TRIGGERED" -eq 1 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') | TRIGGERED | $REASON" >> "$LOG"

    # Gọi _do_auto_block qua argument dispatch — threshold thấp hơn khi bị tấn công, 1h TTL
    # security-menu.sh "_do_auto_block" <threshold> <ban_hours>
    BLOCK_THRESHOLD=$(( ${THRESHOLD_TOTAL:-50000} / 10 ))
    BLOCK_LOG=$(bash "$BASE_DIR/modules/security/security-menu.sh" _do_auto_block "$BLOCK_THRESHOLD" "1" 2>&1)
    echo "$(date '+%Y-%m-%d %H:%M:%S') | AUTO-BLOCK | $BLOCK_LOG" >> "$LOG"

    # Gửi thông báo Telegram
    if [ -f "$BASE_DIR/modules/notification/telegram-notify.sh" ]; then
        bash "$BASE_DIR/modules/notification/telegram-notify.sh" send "security_alert" \
            "Auto-Guard Triggered" "$(hostname): $REASON | auto-blocked attackers" 2>/dev/null
    fi
fi
SCRIPT
    chmod +x "$AUTO_GUARD_SCRIPT"

    # Tạo systemd service
    cat > "$AUTO_GUARD_SERVICE" <<EOF
[Unit]
Description=ShieldPress Auto-Guard Security Check
After=network.target

[Service]
Type=oneshot
ExecStart=$AUTO_GUARD_SCRIPT
User=root
EOF

    # Tạo systemd timer
    cat > "$AUTO_GUARD_TIMER" <<EOF
[Unit]
Description=ShieldPress Auto-Guard Timer
Requires=sp-auto-guard.service

[Timer]
OnBootSec=2min
OnUnitActiveSec=${T_INTERVAL}min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now sp-auto-guard.timer 2>/dev/null

    echo ""
    ok "Auto-Guard ENABLED"
    echo ""
    echo "  Ngưỡng đã cài:"
    echo "  - Total requests > $T_REQ / 10 min → trigger"
    echo "  - 4xx errors     > $T_4XX / 10 min → trigger"
    echo "  - wp-login hits  > $T_WP / 10 min → trigger"
    echo "  - Kiểm tra mỗi  : ${T_INTERVAL} phút"
    echo ""
    echo "  Log: /opt/shieldpress/logs/auto-guard.log"
    log "AUTO-GUARD enabled (total>$T_REQ, 4xx>$T_4XX, wp>$T_WP, every ${T_INTERVAL}min)"
}

disable_auto_guard(){
    echo ""
    if ! systemctl is-active --quiet sp-auto-guard.timer 2>/dev/null; then
        warn "Auto-Guard không đang chạy"
        return
    fi

    read -p "Tắt Auto-Guard? (y/n): " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Cancelled."; return; }

    systemctl disable --now sp-auto-guard.timer 2>/dev/null
    rm -f "$AUTO_GUARD_TIMER" "$AUTO_GUARD_SERVICE"
    systemctl daemon-reload

    ok "Auto-Guard DISABLED"
    log "AUTO-GUARD disabled"
}

manage_auto_guard(){
    while true; do
        clear
        echo "===================================================="
        echo "  AUTO-GUARD — TỰ ĐỘNG BLOCK ATTACKER"
        echo "===================================================="
        echo ""
        auto_guard_status
        echo ""
        echo "  1) Enable / Cấu hình lại Auto-Guard"
        echo "  2) Disable Auto-Guard"
        echo "  3) Xem log Auto-Guard"
        echo "  4) Chạy kiểm tra ngay bây giờ"
        echo "  0) Back"
        echo ""
        read -p "Select: " opt
        case $opt in
            1) enable_auto_guard ;;
            2) disable_auto_guard ;;
            3)
                LOG_FILE="/opt/shieldpress/logs/auto-guard.log"
                if [ -f "$LOG_FILE" ]; then
                    echo ""
                    tail -50 "$LOG_FILE"
                else
                    echo "  Chưa có log"
                fi
                ;;
            4)
                echo ""
                echo "Chạy Auto-Guard check ngay..."
                bash "$AUTO_GUARD_SCRIPT" && ok "Done" || fail "Script not found — enable Auto-Guard trước"
                ;;
            0) break ;;
        esac
        echo ""
        read -p "Press Enter..."
    done
}

# ==================================================
# NON-INTERACTIVE DISPATCH (used by auto-guard / cron)
# ==================================================

# If called with "_do_auto_block <threshold> <ban_hours>" — run blocking and exit
# This avoids sourcing the whole file (which would trigger the interactive menu loop)
if [ "${1:-}" = "_do_auto_block" ]; then
    _do_auto_block "${2:-}" "${3:-1}"
    exit 0
fi

# ==================================================
# MENU
# ==================================================

while true; do

    clear
    security_dashboard_compact

    sp_header "Security Center" "Firewall, Fail2ban, hardening"
    sp_menu_grid \
        "1|Firewall Status|cyan" \
        "2|Open Port|yellow" \
        "3|Close Port|green" \
        "4|Block IP|red" \
        "5|Whitelist IP|green" \
        "6|Remove IP Rule|yellow" \
        "7|List Blocked IPs|cyan" \
        "8|IP Block History|magenta" \
        "9|Enable Fail2ban SSH|green" \
        "10|Fail2ban SSH Manager|blue" \
        "11|Fail2ban Nginx Protection|red" \
        "12|Fail2ban Nginx Manager|blue" \
        "13|WP Bruteforce Protection|red" \
        "14|Block Bot Countries|red" \
        "15|Unblock Bot Countries|yellow" \
        "16|SSH Hardening|yellow" \
        "17|Auto-block Attackers|red" \
        "18|Auto-Guard (Scheduled)|magenta" \
        "19|Security Audit|magenta" \
        "20|CVE / Dependency Audit|red" \
        "0|Back|white"

    sp_prompt choice

    case $choice in
        1)  firewall_status ;;
        2)  open_port ;;
        3)  close_port ;;
        4)  block_ip ;;
        5)  whitelist_ip ;;
        6)  unblock_ip ;;
        7)  list_blocked_ips ;;
        8)  view_ip_block_history ;;
        9)  fail2ban_ssh ;;
        10) fail2ban_ssh_manager ;;
        11) fail2ban_nginx ;;
        12) fail2ban_nginx_manager ;;
        13) enable_wp_bruteforce ;;
        14) block_bot_countries_real ;;
        15) unblock_bot_countries_real ;;
        16) ssh_hardening ;;
        17) auto_block_attackers ;;
        18) manage_auto_guard ;;
        19) security_audit ;;
        20) bash "$BASE_DIR/modules/security/cve-audit.sh" ;;
        0)  break ;;
        *)  sp_invalid; continue ;;
    esac

    echo ""
    read -p "Press Enter to continue..."

done
