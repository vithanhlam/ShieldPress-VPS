#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"

DOMAINS_ROOT="/home/domains"
LOG_FILE="$LOG_DIR/isolation.log"
source "$BASE_DIR/core/ui.sh"

mkdir -p "$LOG_DIR"

log(){  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"; }
ok(){   echo "[OK] $1";     log "[OK] $1"; }
fail(){ echo "[FAILED] $1"; log "[FAILED] $1"; }
warn(){ echo "[WARN] $1";   log "[WARN] $1"; }

# =========================================
# 1) FIX PERMISSIONS ALL DOMAINS
# =========================================

fix_permissions_all(){

    echo "Fixing permissions for all domains..."
    echo ""
    COUNT=0

    for d in "$DOMAINS_ROOT"/*; do
        [ -d "$d" ] || continue
        [ -f "$d/config/domain.env" ] || continue

        # Đọc thẳng từ file tránh variable leak giữa các domain
        DOMAIN=$(grep    "^DOMAIN="      "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
        SYSUSER=$(grep   "^SYSTEM_USER=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')

        if [ -z "$SYSUSER" ]; then
            warn "$DOMAIN: SYSTEM_USER not found in domain.env, skipping"
            continue
        fi

        # Validate SYSTEM_USER — chỉ cho phép ký tự an toàn, tránh path traversal
        if ! [[ "$SYSUSER" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; then
            warn "$DOMAIN: SYSTEM_USER contains invalid characters, skipping"
            continue
        fi

        echo "  Processing: $DOMAIN ($SYSUSER)..."

        # Domain root
        chown "$SYSUSER:$SYSUSER" "$d"
        chmod 755 "$d"

        # public_html - files 644, dirs 755
        # node_modules/.bin và .git không đổi permission (giữ nguyên execute bit)
        if [ -d "$d/public_html" ]; then
            chown -R "$SYSUSER:$SYSUSER" "$d/public_html"
            find "$d/public_html" -type d \
                -not -path "*/node_modules/*" -not -path "*/vendor/*" -not -path "*/.git/*" \
                -exec chmod 755 {} \;
            find "$d/public_html" -type f \
                -not -path "*/node_modules/*" -not -path "*/vendor/*" -not -path "*/.git/*" \
                -exec chmod 644 {} \;
            # wp-config.php bảo mật hơn
            [ -f "$d/public_html/wp-config.php" ] && chmod 600 "$d/public_html/wp-config.php"
        fi

        # backup folder - private
        if [ -d "$d/backup" ]; then
            chown -R "$SYSUSER:$SYSUSER" "$d/backup"
            chmod 750 "$d/backup"
        fi

        # config/ — chỉ root đọc được (chứa domain.env với DB_PASS, SFTP_PASS)
        if [ -d "$d/config" ]; then
            chown root:root "$d/config"
            chmod 700 "$d/config"
        fi
        if [ -f "$d/config/domain.env" ]; then
            chown root:root "$d/config/domain.env"
            chmod 600 "$d/config/domain.env"
        fi

        ok "$DOMAIN"
        COUNT=$((COUNT+1))
    done

    echo ""
    echo "Fixed $COUNT domains."
}

# =========================================
# 2) APPLY OPEN_BASEDIR ALL
# =========================================

apply_open_basedir_all(){

    echo "Applying open_basedir to all PHP pools..."
    echo ""
    COUNT=0

    for d in "$DOMAINS_ROOT"/*; do
        [ -d "$d" ] || continue
        [ -f "$d/config/domain.env" ] || continue

        DOMAIN=$(grep    "^DOMAIN="      "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
        SYSUSER=$(grep   "^SYSTEM_USER=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
        PHP_VER=$(grep   "^PHP_VERSION=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')

        if [ -z "$SYSUSER" ] || [ -z "$PHP_VER" ]; then
            warn "$DOMAIN: missing SYSTEM_USER or PHP_VERSION, skipping"
            continue
        fi

        # Validate SYSTEM_USER — tránh path traversal khi dùng trong đường dẫn pool
        if ! [[ "$SYSUSER" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; then
            warn "$DOMAIN: SYSTEM_USER contains invalid characters, skipping"
            continue
        fi

        PHP_SHORT=$(echo "$PHP_VER" | tr -d '.')

        # Pool file tên theo SYSTEM_USER (domain-specific pool)
        POOL_FILE="/etc/opt/remi/php${PHP_SHORT}/php-fpm.d/${SYSUSER}.conf"

        if [ ! -f "$POOL_FILE" ]; then
            warn "$DOMAIN: pool file not found ($POOL_FILE), skipping"
            continue
        fi

        if grep -q "open_basedir" "$POOL_FILE"; then
            # Nếu đang dùng /tmp chung (cũ) → cập nhật sang per-domain tmp
            if grep -q "open_basedir.*:/tmp" "$POOL_FILE" || grep -q "open_basedir.* /tmp" "$POOL_FILE"; then
                sed -i "s|php_admin_value\[open_basedir\].*|php_admin_value[open_basedir] = $d:$d/tmp:/usr/share/php|" "$POOL_FILE"
                systemctl restart php${PHP_SHORT}-php-fpm 2>/dev/null && \
                    ok "$DOMAIN: open_basedir updated (removed shared /tmp)" || \
                    warn "$DOMAIN: PHP-FPM restart failed"
            else
                echo "  $DOMAIN: open_basedir already set (OK)"
            fi
            continue
        fi

        # Tạo thư mục tmp riêng nếu chưa có
        mkdir -p "$d/tmp/sessions"
        chown -R "$SYSUSER:$SYSUSER" "$d/tmp" 2>/dev/null
        chmod 700 "$d/tmp" 2>/dev/null

        cat >> "$POOL_FILE" <<EOF

; Isolation - added by ShieldPress
php_admin_value[open_basedir] = $d:$d/tmp:/usr/share/php
php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen,pcntl_exec
EOF

        systemctl restart php${PHP_SHORT}-php-fpm 2>/dev/null && \
            ok "$DOMAIN: open_basedir applied" || \
            warn "$DOMAIN: PHP-FPM restart failed"

        COUNT=$((COUNT+1))
    done

    echo ""
    echo "Applied to $COUNT domains."
}

# =========================================
# 3) AUDIT ISOLATION STATUS
# =========================================

audit_isolation(){

    echo ""
    echo "===================================================="
    echo "              ISOLATION AUDIT"
    echo "===================================================="
    printf "%-25s %-12s %-6s %-6s %-10s %-8s %-8s\n" \
        "Domain" "Owner" "Perm" "PHP" "Socket" "OpenBase" "Config"
    echo "--------------------------------------------------------------"

    for d in "$DOMAINS_ROOT"/*; do
        [ -d "$d" ] || continue
        [ -f "$d/config/domain.env" ] || continue

        DOMAIN=$(grep    "^DOMAIN="      "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
        SYSUSER=$(grep   "^SYSTEM_USER=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
        PHP_VER=$(grep   "^PHP_VERSION=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')

        OWNER=$(stat -c "%U" "$d")
        PERM=$(stat -c "%a" "$d")

        PHP_SHORT=$(echo "$PHP_VER" | tr -d '.')
        SOCKET="/var/opt/remi/php${PHP_SHORT}/run/php-fpm/${SYSUSER}.sock"
        POOL_FILE="/etc/opt/remi/php${PHP_SHORT}/php-fpm.d/${SYSUSER}.conf"

        # Socket status
        [ -S "$SOCKET" ] && SOCK_ST="OK" || SOCK_ST="Missing"

        # open_basedir status — cũng kiểm tra có /tmp chung không
        if [ -f "$POOL_FILE" ] && grep -q "open_basedir" "$POOL_FILE"; then
            if grep -q "open_basedir.*:/tmp" "$POOL_FILE" || grep -q "open_basedir.* /tmp" "$POOL_FILE"; then
                OB_ST="OLD(!)"
            else
                OB_ST="ON"
            fi
        else
            OB_ST="OFF(!)"
        fi

        # config/ permission (phải là root:root 700)
        if [ -d "$d/config" ]; then
            CFG_OWNER=$(stat -c "%U" "$d/config")
            CFG_PERM=$(stat -c "%a" "$d/config")
            if [ "$CFG_OWNER" = "root" ] && [ "$CFG_PERM" = "700" ]; then
                CFG_ST="OK"
            else
                CFG_ST="${CFG_OWNER}:${CFG_PERM}(!)"
            fi
        else
            CFG_ST="missing(!)"
        fi

        # Highlight vấn đề
        if [ "$OWNER" != "$SYSUSER" ]; then
            OWNER="${OWNER}(!)"
        fi
        if [ "$PERM" != "755" ]; then
            PERM="${PERM}(!)"
        fi

        printf "%-25s %-12s %-6s %-6s %-10s %-8s %-8s\n" \
            "$DOMAIN" "$OWNER" "$PERM" "$PHP_VER" "$SOCK_ST" "$OB_ST" "$CFG_ST"
    done

    echo "======================================================================"
    echo ""
    echo "Legend: (!) = issue detected | OLD = open_basedir has shared /tmp (run Repair All)"
}

# =========================================
# 4) REPAIR ISOLATION
# =========================================

repair_isolation(){
    echo "Repairing isolation for all domains..."
    echo ""
    fix_permissions_all
    echo ""
    apply_open_basedir_all
    echo ""
    ok "Isolation repair completed"
}

# =========================================
# MENU
# =========================================

while true; do

    clear
    sp_header "Domain Isolation" "Permissions and PHP boundaries"
    sp_menu_grid \
        "1|Fix All Permissions|green" \
        "2|Apply open_basedir|yellow" \
        "3|Audit Isolation Status|cyan" \
        "4|Repair All|magenta" \
        "0|Back|white"

    sp_prompt choice

    case $choice in
        1) fix_permissions_all;  echo ""; read -p "Press Enter..." ;;
        2) apply_open_basedir_all; echo ""; read -p "Press Enter..." ;;
        3) audit_isolation;      echo ""; read -p "Press Enter..." ;;
        4) repair_isolation;     echo ""; read -p "Press Enter..." ;;
        0) break ;;
        *) sp_invalid ;;
    esac

done
