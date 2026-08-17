#!/bin/bash
# ====================================================
# ShieldPress System Integrity Check & Repair
# Kiểm tra toàn bộ hệ thống, phát hiện & sửa lỗi
# ====================================================

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
LOG_FILE="$LOG_DIR/integrity.log"
DOMAINS_ROOT="/home/domains"

mkdir -p "$LOG_DIR"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
BOLD="\e[1m"
RESET="\e[0m"

TOTAL_CHECKS=0
TOTAL_PASS=0
TOTAL_WARN=0
TOTAL_FAIL=0
TOTAL_FIXED=0

log(){ echo "$(date '+%F %T') | $1" >> "$LOG_FILE"; }

check_pass(){
    echo -e "  ${GREEN}✓${RESET} $1"
    ((TOTAL_PASS++))
    ((TOTAL_CHECKS++))
}

check_warn(){
    echo -e "  ${YELLOW}!${RESET} $1"
    ((TOTAL_WARN++))
    ((TOTAL_CHECKS++))
}

check_fail(){
    echo -e "  ${RED}✗${RESET} $1"
    ((TOTAL_FAIL++))
    ((TOTAL_CHECKS++))
    log "FAIL: $1"
}

check_fixed(){
    echo -e "  ${GREEN}↻${RESET} $1 ${GREEN}(auto-fixed)${RESET}"
    ((TOTAL_FIXED++))
    ((TOTAL_CHECKS++))
    log "FIXED: $1"
}

AUTO_FIX="${1:-ask}"  # "yes" = auto-fix, "no" = report only, "ask" = ask each time

try_fix(){
    local DESC="$1"
    local FIX_CMD="$2"

    if [ "$AUTO_FIX" = "yes" ]; then
        eval "$FIX_CMD" 2>/dev/null && check_fixed "$DESC" || check_fail "$DESC (fix failed)"
        return $?
    elif [ "$AUTO_FIX" = "no" ]; then
        check_fail "$DESC"
        return 1
    else
        echo -e "    ${YELLOW}→ Fix: $FIX_CMD${RESET}"
        read -p "    Apply fix? (y/n): " confirm
        if [[ "$confirm" =~ ^[yY]$ ]]; then
            eval "$FIX_CMD" 2>/dev/null && check_fixed "$DESC" || check_fail "$DESC (fix failed)"
            return $?
        else
            check_fail "$DESC (skipped)"
            return 1
        fi
    fi
}

# ====================================================
# 1. NGINX CHECKS
# ====================================================

check_nginx(){
    echo ""
    echo -e "${BOLD}[NGINX]${RESET}"
    echo "----------------------------------------------------"

    # Service running
    if systemctl is-active --quiet nginx 2>/dev/null; then
        check_pass "Nginx service running"
    else
        try_fix "Nginx service stopped" "systemctl start nginx"
    fi

    # Service enabled at boot
    if systemctl is-enabled --quiet nginx 2>/dev/null; then
        check_pass "Nginx enabled at boot"
    else
        try_fix "Nginx not enabled at boot" "systemctl enable nginx"
    fi

    # Config syntax
    if nginx -t 2>/dev/null; then
        check_pass "Nginx config syntax OK"
    else
        check_fail "Nginx config syntax ERROR"
        echo -e "    ${RED}$(nginx -t 2>&1)${RESET}"
    fi

    # Main config exists
    if [ -f /etc/nginx/nginx.conf ]; then
        check_pass "nginx.conf exists"
    else
        check_fail "nginx.conf MISSING"
    fi

    # Performance config
    if [ -f /etc/nginx/conf.d/shieldpress-performance.conf ]; then
        check_pass "Performance config exists"
    else
        check_warn "Performance config missing (run Optimize Nginx to recreate)"
    fi

    # SSL hardening snippet
    if [ -f /etc/nginx/snippets/ssl-hardening.conf ]; then
        check_pass "SSL hardening snippet exists"
    else
        check_warn "SSL hardening snippet missing"
    fi

    # DH params
    if [ -f /etc/nginx/ssl/dhparam.pem ]; then
        check_pass "DH parameters exist"
    else
        check_warn "DH parameters missing (SSL may use weaker defaults)"
    fi

    # Check each domain has nginx config
    for d in "$DOMAINS_ROOT"/*/config/domain.env; do
        [ -f "$d" ] || continue
        local DN=$(grep "^DOMAIN=" "$d" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
        [ -z "$DN" ] && continue
        local CLEAN=$(echo "$DN" | sed 's/[^a-zA-Z0-9.-]/_/g')
        local NGINX_CONF="/etc/nginx/conf.d/${CLEAN}.conf"

        if [ -f "$NGINX_CONF" ]; then
            check_pass "Nginx config: $DN"
        else
            check_fail "Nginx config MISSING: $DN ($NGINX_CONF)"
        fi
    done

    # Check worker_processes
    local WORKERS=$(grep "^worker_processes" /etc/nginx/nginx.conf 2>/dev/null | awk '{print $2}' | tr -d ';')
    if [ "$WORKERS" = "auto" ] || [ -n "$WORKERS" ]; then
        check_pass "Worker processes configured ($WORKERS)"
    else
        check_warn "Worker processes not set"
    fi

    # Check error log exists and is writable
    local ELOG="/var/log/nginx/error.log"
    if [ -w "$ELOG" ] || [ -w "$(dirname "$ELOG")" ]; then
        check_pass "Nginx error log writable"
    else
        try_fix "Nginx error log not writable" "mkdir -p /var/log/nginx && touch $ELOG && chmod 644 $ELOG"
    fi
}

# ====================================================
# 2. PHP-FPM CHECKS
# ====================================================

check_php(){
    echo ""
    echo -e "${BOLD}[PHP-FPM]${RESET}"
    echo "----------------------------------------------------"

    local PHP_FOUND=0

    for v in 81 82 83 84; do
        local BIN="/opt/remi/php${v}/root/usr/bin/php"
        local FPM="/opt/remi/php${v}/root/usr/sbin/php-fpm"
        local SVC="php${v}-php-fpm"
        local VER_DOT="${v:0:1}.${v:1}"

        [ -x "$BIN" ] || continue
        PHP_FOUND=1

        # Service running
        if systemctl is-active --quiet "$SVC" 2>/dev/null; then
            check_pass "PHP $VER_DOT FPM running"
        else
            if systemctl list-unit-files 2>/dev/null | grep -q "$SVC"; then
                try_fix "PHP $VER_DOT FPM stopped" "systemctl start $SVC"
            fi
        fi

        # Service enabled at boot
        if systemctl is-enabled --quiet "$SVC" 2>/dev/null; then
            check_pass "PHP $VER_DOT FPM enabled at boot"
        else
            try_fix "PHP $VER_DOT FPM not enabled at boot" "systemctl enable $SVC"
        fi

        # FPM config test
        if $FPM -t 2>/dev/null; then
            check_pass "PHP $VER_DOT FPM config OK"
        else
            check_fail "PHP $VER_DOT FPM config ERROR"
        fi

        # php.ini exists
        local PHP_INI="/etc/opt/remi/php${v}/php.ini"
        if [ -f "$PHP_INI" ]; then
            check_pass "PHP $VER_DOT php.ini exists"
        else
            check_fail "PHP $VER_DOT php.ini MISSING"
        fi

        # OPcache
        if $BIN -m 2>/dev/null | grep -qi opcache; then
            check_pass "PHP $VER_DOT OPcache loaded"
        else
            check_warn "PHP $VER_DOT OPcache not loaded"
        fi

        # Check domain pools exist
        for d in "$DOMAINS_ROOT"/*/config/domain.env; do
            [ -f "$d" ] || continue
            local DPHP=$(grep "^PHP_VERSION=" "$d" 2>/dev/null | cut -d= -f2 | tr -d '[:space:].')
            [ "$DPHP" = "$v" ] || continue
            local SYSUSER=$(grep "^SYSTEM_USER=" "$d" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
            local DN=$(grep "^DOMAIN=" "$d" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
            [ -z "$SYSUSER" ] && continue

            local POOL="/etc/opt/remi/php${v}/php-fpm.d/${SYSUSER}.conf"
            if [ -f "$POOL" ]; then
                check_pass "PHP $VER_DOT pool: $DN"
            else
                check_fail "PHP $VER_DOT pool MISSING: $DN ($POOL)"
            fi

            # Check socket directory exists
            local SOCK_DIR="/var/opt/remi/php${v}/run/php-fpm"
            if [ -d "$SOCK_DIR" ]; then
                check_pass "PHP $VER_DOT socket dir exists"
            else
                try_fix "PHP $VER_DOT socket dir missing" "mkdir -p $SOCK_DIR && chown root:root $SOCK_DIR"
            fi
        done
    done

    [ "$PHP_FOUND" -eq 0 ] && check_fail "No PHP versions installed"
}

# ====================================================
# 3. DATABASE CHECKS
# ====================================================

check_database(){
    echo ""
    echo -e "${BOLD}[DATABASE]${RESET}"
    echo "----------------------------------------------------"

    # MariaDB
    if systemctl is-active --quiet mariadb 2>/dev/null; then
        check_pass "MariaDB running"
    else
        if systemctl list-unit-files 2>/dev/null | grep -q "mariadb"; then
            try_fix "MariaDB stopped" "systemctl start mariadb"
        else
            check_warn "MariaDB not installed"
        fi
    fi

    # PostgreSQL
    if systemctl is-active --quiet postgresql 2>/dev/null; then
        check_pass "PostgreSQL running"
    else
        if systemctl list-unit-files 2>/dev/null | grep -q "postgresql"; then
            try_fix "PostgreSQL stopped" "systemctl start postgresql"
        else
            check_warn "PostgreSQL not installed"
        fi
    fi

    # Valkey/Redis
    if systemctl is-active --quiet valkey 2>/dev/null; then
        check_pass "Valkey running"
    else
        if systemctl list-unit-files 2>/dev/null | grep -q "valkey"; then
            try_fix "Valkey stopped" "systemctl start valkey"
        fi
    fi

    # Check DB config
    if [ -f /etc/my.cnf ] || [ -d /etc/my.cnf.d ]; then
        check_pass "MariaDB config exists"
    else
        check_warn "MariaDB config missing"
    fi
}

# ====================================================
# 4. DOMAIN INTEGRITY
# ====================================================

check_domains(){
    echo ""
    echo -e "${BOLD}[DOMAINS]${RESET}"
    echo "----------------------------------------------------"

    local DOMAIN_COUNT=0

    for d in "$DOMAINS_ROOT"/*/; do
        [ -d "$d" ] || continue
        local DNAME=$(basename "$d")
        local ENV_FILE="$d/config/domain.env"

        # domain.env exists
        if [ -f "$ENV_FILE" ]; then
            check_pass "domain.env: $DNAME"
        else
            check_fail "domain.env MISSING: $DNAME"
            continue
        fi

        local DN=$(grep "^DOMAIN=" "$ENV_FILE" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
        local SYSUSER=$(grep "^SYSTEM_USER=" "$ENV_FILE" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
        local DOCROOT=$(grep "^DOCUMENT_ROOT=" "$ENV_FILE" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')

        # System user exists
        if id "$SYSUSER" &>/dev/null; then
            check_pass "System user: $SYSUSER ($DN)"
        else
            check_fail "System user MISSING: $SYSUSER ($DN)"
        fi

        # Document root exists
        local WEBROOT="${DOCROOT:-$d/public_html}"
        if [ -d "$WEBROOT" ]; then
            check_pass "Document root: $DN"
        else
            try_fix "Document root MISSING: $DN" "mkdir -p $WEBROOT && chown $SYSUSER:$SYSUSER $WEBROOT"
        fi

        # Permissions
        local OWNER=$(stat -c '%U' "$d" 2>/dev/null)
        if [ "$OWNER" = "$SYSUSER" ]; then
            check_pass "Ownership OK: $DN"
        else
            try_fix "Wrong ownership: $DN (is $OWNER, should be $SYSUSER)" \
                "chown -R $SYSUSER:$SYSUSER $d"
        fi

        ((DOMAIN_COUNT++))
    done

    [ "$DOMAIN_COUNT" -eq 0 ] && check_warn "No domains found"
}

# ====================================================
# 5. SECURITY CHECKS
# ====================================================

check_security(){
    echo ""
    echo -e "${BOLD}[SECURITY]${RESET}"
    echo "----------------------------------------------------"

    # Firewall
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        check_pass "Firewall running"
    else
        try_fix "Firewall stopped" "systemctl start firewalld"
    fi

    # Fail2ban
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        check_pass "Fail2ban running"
    else
        if systemctl list-unit-files 2>/dev/null | grep -q "fail2ban"; then
            try_fix "Fail2ban stopped" "systemctl start fail2ban"
        else
            check_warn "Fail2ban not installed"
        fi
    fi

    # SSH config
    if [ -f /etc/ssh/sshd_config ]; then
        check_pass "SSH config exists"

        # Check root login disabled
        if grep -q "^PermitRootLogin no" /etc/ssh/sshd_config 2>/dev/null; then
            check_pass "Root SSH login disabled"
        else
            check_warn "Root SSH login may be enabled"
        fi
    else
        check_fail "SSH config MISSING"
    fi

    # Check open ports
    local MYSQL_EXPOSED=$(ss -tlnp 2>/dev/null | grep ":3306" | grep -v "127.0.0.1" | grep -v "::1")
    if [ -n "$MYSQL_EXPOSED" ]; then
        check_fail "MariaDB port 3306 exposed to public!"
    else
        check_pass "MariaDB port not publicly exposed"
    fi

    local PG_EXPOSED=$(ss -tlnp 2>/dev/null | grep ":5432" | grep -v "127.0.0.1" | grep -v "::1")
    if [ -n "$PG_EXPOSED" ]; then
        check_fail "PostgreSQL port 5432 exposed to public!"
    else
        check_pass "PostgreSQL port not publicly exposed"
    fi
}

# ====================================================
# 6. FILESYSTEM CHECKS
# ====================================================

check_filesystem(){
    echo ""
    echo -e "${BOLD}[FILESYSTEM]${RESET}"
    echo "----------------------------------------------------"

    # Disk usage
    local DISK_USAGE=$(df / 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')
    if [ -n "$DISK_USAGE" ]; then
        if [ "$DISK_USAGE" -lt 80 ]; then
            check_pass "Disk usage: ${DISK_USAGE}%"
        elif [ "$DISK_USAGE" -lt 90 ]; then
            check_warn "Disk usage: ${DISK_USAGE}% (getting full)"
        else
            check_fail "Disk usage: ${DISK_USAGE}% (CRITICAL)"
        fi
    fi

    # Inode usage
    local INODE_USAGE=$(df -i / 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')
    if [ -n "$INODE_USAGE" ]; then
        if [ "$INODE_USAGE" -lt 80 ]; then
            check_pass "Inode usage: ${INODE_USAGE}%"
        else
            check_warn "Inode usage: ${INODE_USAGE}% (high)"
        fi
    fi

    # ShieldPress directories
    for dir in "$LOG_DIR" "$BASE_DIR/config" "$BASE_DIR/snapshots" "$BASE_DIR/bin"; do
        if [ -d "$dir" ]; then
            check_pass "Directory: $dir"
        else
            try_fix "Directory missing: $dir" "mkdir -p $dir"
        fi
    done

    # Log directory writable
    if [ -w "$LOG_DIR" ]; then
        check_pass "Log directory writable"
    else
        try_fix "Log directory not writable" "chmod 755 $LOG_DIR"
    fi
}

# ====================================================
# 7. SSL CHECKS
# ====================================================

check_ssl(){
    echo ""
    echo -e "${BOLD}[SSL/TLS]${RESET}"
    echo "----------------------------------------------------"

    for d in "$DOMAINS_ROOT"/*/config/domain.env; do
        [ -f "$d" ] || continue
        local DN=$(grep "^DOMAIN=" "$d" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
        [ -z "$DN" ] && continue

        local CERT="/etc/letsencrypt/live/$DN/fullchain.pem"
        if [ -f "$CERT" ]; then
            # Check expiry
            local EXPIRY=$(openssl x509 -enddate -noout -in "$CERT" 2>/dev/null | cut -d= -f2)
            local EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null)
            local NOW_EPOCH=$(date +%s)
            local DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))

            if [ "$DAYS_LEFT" -gt 30 ]; then
                check_pass "SSL $DN (${DAYS_LEFT} days left)"
            elif [ "$DAYS_LEFT" -gt 7 ]; then
                check_warn "SSL $DN expiring soon (${DAYS_LEFT} days)"
            elif [ "$DAYS_LEFT" -gt 0 ]; then
                check_fail "SSL $DN EXPIRING in ${DAYS_LEFT} days!"
            else
                check_fail "SSL $DN EXPIRED!"
            fi
        else
            check_warn "SSL cert not found: $DN (HTTP only?)"
        fi
    done

    # Certbot timer
    if systemctl is-active --quiet certbot-renew.timer 2>/dev/null || \
       crontab -l 2>/dev/null | grep -q "certbot"; then
        check_pass "SSL auto-renewal configured"
    else
        check_warn "SSL auto-renewal may not be configured"
    fi
}

# ====================================================
# Run all checks
# ====================================================

run_full_check(){
    echo ""
    echo -e "${BOLD}=====================================================${RESET}"
    echo -e "${BOLD}  SHIELDPRESS SYSTEM INTEGRITY CHECK${RESET}"
    echo -e "${BOLD}=====================================================${RESET}"
    echo -e "  $(date '+%F %T') | Mode: $([ "$AUTO_FIX" = "yes" ] && echo "Auto-fix" || echo "Interactive")"

    TOTAL_CHECKS=0
    TOTAL_PASS=0
    TOTAL_WARN=0
    TOTAL_FAIL=0
    TOTAL_FIXED=0

    check_nginx
    check_php
    check_database
    check_domains
    check_security
    check_filesystem
    check_ssl

    echo ""
    echo -e "${BOLD}=====================================================${RESET}"
    echo -e "${BOLD}  RESULTS${RESET}"
    echo -e "${BOLD}=====================================================${RESET}"
    echo -e "  Total checks : $TOTAL_CHECKS"
    echo -e "  ${GREEN}Passed${RESET}       : $TOTAL_PASS"
    echo -e "  ${YELLOW}Warnings${RESET}     : $TOTAL_WARN"
    echo -e "  ${RED}Failed${RESET}       : $TOTAL_FAIL"
    echo -e "  ${GREEN}Auto-fixed${RESET}   : $TOTAL_FIXED"
    echo ""

    if [ "$TOTAL_FAIL" -eq 0 ] && [ "$TOTAL_WARN" -eq 0 ]; then
        echo -e "  ${GREEN}${BOLD}System is healthy!${RESET}"
    elif [ "$TOTAL_FAIL" -eq 0 ]; then
        echo -e "  ${YELLOW}${BOLD}System OK with warnings${RESET}"
    else
        echo -e "  ${RED}${BOLD}Issues detected - review above${RESET}"
    fi

    log "INTEGRITY CHECK: pass=$TOTAL_PASS warn=$TOTAL_WARN fail=$TOTAL_FAIL fixed=$TOTAL_FIXED"

    # Notify if failures found
    if [ "$TOTAL_FAIL" -gt 0 ] && [ -f "$BASE_DIR/modules/notification/telegram-notify.sh" ]; then
        bash "$BASE_DIR/modules/notification/telegram-notify.sh" send "server_alert" \
            "Integrity Check Alert" \
            "Pass: $TOTAL_PASS | Warn: $TOTAL_WARN | Fail: $TOTAL_FAIL | Fixed: $TOTAL_FIXED" 2>/dev/null
    fi
}

# ====================================================
# Entry point
# ====================================================

# If called with arguments (from cron/auto-repair)
case "$1" in
    auto-fix)
        AUTO_FIX="yes"
        run_full_check
        exit 0
        ;;
    report)
        AUTO_FIX="no"
        run_full_check
        exit 0
        ;;
esac

# Interactive
while true; do
    clear
    echo "===================================================="
    echo "         SYSTEM INTEGRITY CHECK"
    echo "===================================================="
    echo ""
    echo "  1) Full Check (ask before fixing)"
    echo "  2) Full Check (auto-fix all)"
    echo "  3) Full Check (report only)"
    echo "  4) Check Nginx only"
    echo "  5) Check PHP only"
    echo "  6) Check Domains only"
    echo "  7) Check Security only"
    echo "  8) Check SSL only"
    echo "  0) Back"
    echo "----------------------------------------------------"
    read -p "Select: " opt

    TOTAL_CHECKS=0; TOTAL_PASS=0; TOTAL_WARN=0; TOTAL_FAIL=0; TOTAL_FIXED=0

    case "$opt" in
        1) AUTO_FIX="ask"; run_full_check ;;
        2) AUTO_FIX="yes"; run_full_check ;;
        3) AUTO_FIX="no"; run_full_check ;;
        4) AUTO_FIX="ask"; check_nginx ;;
        5) AUTO_FIX="ask"; check_php ;;
        6) AUTO_FIX="ask"; check_domains ;;
        7) AUTO_FIX="ask"; check_security ;;
        8) AUTO_FIX="ask"; check_ssl ;;
        0) break ;;
        *) warn "Invalid" ;;
    esac

    echo ""
    read -p "Press Enter..."
done
