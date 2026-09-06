#!/bin/bash

# ==================================================
# ShieldPress VPS — Migration Patches
# ==================================================
# Pattern: each patch has a unique PATCH_ID.
# Applied patches are tracked in PATCH_REGISTRY.
# Running a patch twice is safe — it self-skips.
# To retire a patch: comment out its body and the
# call in apply_all_patches(), keep the function stub
# so old PATCH_IDs stay in the registry correctly.
# ==================================================

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
source "$BASE_DIR/core/ui.sh" 2>/dev/null

PATCH_REGISTRY="$BASE_DIR/data/patches-applied.txt"
DOMAINS_ROOT="/home/domains"

mkdir -p "$(dirname "$PATCH_REGISTRY")"
touch "$PATCH_REGISTRY"

GREEN="\e[32m"; YELLOW="\e[33m"; RED="\e[31m"; CYAN="\e[36m"; DIM="\e[2m"; RESET="\e[0m"

ok()   { echo -e "  ${GREEN}[OK]${RESET}   $1"; }
skip() { echo -e "  ${DIM}[SKIP]${RESET} $1"; }
fail() { echo -e "  ${RED}[FAIL]${RESET} $1"; }
info() { echo -e "  ${CYAN}[INFO]${RESET} $1"; }

patch_applied(){
    grep -qxF "$1" "$PATCH_REGISTRY" 2>/dev/null
}

patch_mark_done(){
    echo "$1" >> "$PATCH_REGISTRY"
    sort -u "$PATCH_REGISTRY" -o "$PATCH_REGISTRY"
}

# ==================================================
# PATCH LIST
# ==================================================
# Naming: patch_VER_SHORT_DESCRIPTION
# Each patch must call patch_applied / patch_mark_done
# To retire: replace body with a single "return 0" stub
# ==================================================

# --------------------------------------------------
# v1.3.4 — Fix execute permissions stripped from
#           node_modules/.bin and vendor/bin by
#           isolation Repair All / Fix Permissions.
# --------------------------------------------------
patch_134_fix_bin_perms(){
    local ID="SP_134_FIX_BIN_PERMS"
    local DESC="Restore execute bits on node_modules/.bin and vendor/bin"

    if patch_applied "$ID"; then
        skip "$DESC"
        return 0
    fi

    echo "  Applying: $DESC..."
    local COUNT=0

    for d in "$DOMAINS_ROOT"/*/; do
        [ -d "$d" ] || continue
        local FIXED=0

        if [ -d "$d/public_html/node_modules/.bin" ]; then
            find -L "$d/public_html/node_modules/.bin" -type f -exec chmod u+x {} \; 2>/dev/null && FIXED=1
        fi

        if [ -d "$d/public_html/vendor/bin" ]; then
            find -L "$d/public_html/vendor/bin" -type f -exec chmod u+x {} \; 2>/dev/null && FIXED=1
        fi

        [ "$FIXED" -eq 1 ] && COUNT=$((COUNT+1))
    done

    patch_mark_done "$ID"
    ok "$DESC ($COUNT domains fixed)"
}

# --------------------------------------------------
# v1.3.4 — Lock down config/ to root:root 700 and
#           domain.env to root:root 600 for all
#           existing domains (security hardening).
# --------------------------------------------------
patch_134_secure_config_dir(){
    local ID="SP_134_SECURE_CONFIG_DIR"
    local DESC="Lock config/ to root:root 700 and domain.env to root:root 600"

    if patch_applied "$ID"; then
        skip "$DESC"
        return 0
    fi

    echo "  Applying: $DESC..."
    local COUNT=0

    for d in "$DOMAINS_ROOT"/*/; do
        [ -d "$d" ] || continue

        local CHANGED=0

        if [ -d "$d/config" ]; then
            chown root:root "$d/config" 2>/dev/null
            chmod 700 "$d/config" 2>/dev/null && CHANGED=1
        fi

        if [ -f "$d/config/domain.env" ]; then
            chown root:root "$d/config/domain.env" 2>/dev/null
            chmod 600 "$d/config/domain.env" 2>/dev/null && CHANGED=1
        fi

        [ "$CHANGED" -eq 1 ] && COUNT=$((COUNT+1))
    done

    patch_mark_done "$ID"
    ok "$DESC ($COUNT domains)"
}

# --------------------------------------------------
# v1.3.4 — Remove shared /tmp from open_basedir in
#           existing PHP-FPM pools. Prevents cross-
#           domain reads via /tmp.
# --------------------------------------------------
patch_134_fix_open_basedir_tmp(){
    local ID="SP_134_FIX_OPEN_BASEDIR_TMP"
    local DESC="Remove shared /tmp from open_basedir in PHP-FPM pools"

    if patch_applied "$ID"; then
        skip "$DESC"
        return 0
    fi

    echo "  Applying: $DESC..."
    local COUNT=0

    for d in "$DOMAINS_ROOT"/*/; do
        [ -d "$d" ] || continue
        [ -f "$d/config/domain.env" ] || continue

        local SYSUSER PHP_VER PHP_SHORT POOL_FILE
        SYSUSER=$(grep "^SYSTEM_USER=" "$d/config/domain.env" | cut -d= -f2 | tr -d '[:space:]')
        PHP_VER=$(grep "^PHP_VERSION=" "$d/config/domain.env" | cut -d= -f2 | tr -d '[:space:]')

        [ -z "$SYSUSER" ] || [ -z "$PHP_VER" ] && continue
        ! [[ "$SYSUSER" =~ ^[a-zA-Z0-9_-]{1,32}$ ]] && continue

        PHP_SHORT=$(echo "$PHP_VER" | tr -d '.')
        POOL_FILE="/etc/opt/remi/php${PHP_SHORT}/php-fpm.d/${SYSUSER}.conf"

        [ -f "$POOL_FILE" ] || continue

        # Check for old pattern: open_basedir that includes :/tmp or  /tmp
        if grep -q "open_basedir" "$POOL_FILE"; then
            if grep -q "open_basedir.*:/tmp\|open_basedir.* /tmp" "$POOL_FILE"; then
                sed -i "s|php_admin_value\[open_basedir\].*|php_admin_value[open_basedir] = $d:${d}tmp:/usr/share/php|" "$POOL_FILE"
                systemctl restart php${PHP_SHORT}-php-fpm 2>/dev/null
                COUNT=$((COUNT+1))
            fi
        fi
    done

    patch_mark_done "$ID"
    ok "$DESC ($COUNT pools updated)"
}

# --------------------------------------------------
# v1.3.4 — Ensure php-slow log directory exists.
#           PHP-FPM crashes with status=78/CONFIG if
#           the slowlog directory is missing.
# --------------------------------------------------
patch_134_ensure_php_slow_dir(){
    local ID="SP_134_ENSURE_PHP_SLOW_DIR"
    local DESC="Ensure PHP slow log directory exists"

    if patch_applied "$ID"; then
        skip "$DESC"
        return 0
    fi

    echo "  Applying: $DESC..."

    # Create under both old and new paths (handles pre/post migration servers)
    mkdir -p /opt/shieldpress/logs/php-slow 2>/dev/null
    mkdir -p /var/shieldpress/logs/php-slow  2>/dev/null

    # Restart all PHP-FPM versions that are enabled but not running due to this
    for VER in 81 82 83 84; do
        if systemctl is-enabled --quiet php${VER}-php-fpm 2>/dev/null; then
            if ! systemctl is-active --quiet php${VER}-php-fpm 2>/dev/null; then
                systemctl restart php${VER}-php-fpm 2>/dev/null && \
                    info "php${VER}-php-fpm restarted"
            fi
        fi
    done

    patch_mark_done "$ID"
    ok "$DESC"
}

# --------------------------------------------------
# v1.3.8 — Fix Roundcube SMTP config error.
#   Bug 1: smtp_host had port embedded ('tls://localhost:587')
#           AND smtp_port = 587 set separately → conflict.
#   Bug 2: smtp_conn_options / imap_conn_options missing
#           allow_self_signed => true → PHP rejects Postfix
#           self-signed cert on STARTTLS even with verify_peer=false.
# --------------------------------------------------
patch_138_fix_webmail_smtp(){
    local ID="SP_138_FIX_WEBMAIL_SMTP"
    local DESC="Fix Roundcube SMTP config error (allow_self_signed + smtp_host)"
    local RC_CONFIG="/var/www/webmail/config/config.inc.php"

    if patch_applied "$ID"; then
        skip "$DESC"
        return 0
    fi

    # Skip if webmail not installed
    if [ ! -f "$RC_CONFIG" ]; then
        skip "$DESC (webmail not installed)"
        patch_mark_done "$ID"
        return 0
    fi

    echo "  Applying: $DESC..."

    # Fix smtp_host: remove embedded port, keep scheme only
    sed -i "s|\(\\\$config\['smtp_host'\]\s*=\s*\)'tls://localhost:[0-9]*'|\1'tls://localhost'|" "$RC_CONFIG"

    # Ensure smtp_port = 587 (add if missing)
    if ! grep -q "\$config\['smtp_port'\]" "$RC_CONFIG"; then
        sed -i "/\\\$config\['smtp_host'\]/a \\\$config['smtp_port'] = 587;" "$RC_CONFIG"
    else
        sed -i "s|\(\\\$config\['smtp_port'\]\s*=\s*\)[0-9]*|\1587|" "$RC_CONFIG"
    fi

    # Add allow_self_signed to both IMAP and SMTP conn_options blocks
    # Strategy: insert after each 'verify_peer_name' line if allow_self_signed not already present
    if ! grep -q "allow_self_signed" "$RC_CONFIG"; then
        sed -i "/'verify_peer_name'\s*=>/a\\        'allow_self_signed' => true," "$RC_CONFIG"
    fi

    # Remove redundant default_host / default_port if present
    sed -i "/\\\$config\['default_host'\]/d" "$RC_CONFIG" 2>/dev/null || true
    sed -i "/\\\$config\['default_port'\]/d" "$RC_CONFIG" 2>/dev/null || true

    patch_mark_done "$ID"
    ok "$DESC"
}

# --------------------------------------------------
# v1.3.31 — SELinux fcontext cho domain đã tồn tại.
#           Trước bản vá này, chỉ domain TẠO MỚI mới
#           được gán context; domain cũ (kể cả php-slow
#           log dùng chung) vẫn bị denied trên máy
#           SELinux Enforcing -> PHP-FPM crash cả server.
# --------------------------------------------------
patch_1331_selinux_domain_context(){
    local ID="SP_1331_SELINUX_DOMAIN_CONTEXT"
    local DESC="Apply SELinux fcontext to existing domains + shared php-slow log dir"

    if patch_applied "$ID"; then
        skip "$DESC"
        return 0
    fi

    if ! command -v semanage >/dev/null 2>&1; then
        skip "$DESC (SELinux/semanage not present)"
        patch_mark_done "$ID"
        return 0
    fi

    echo "  Applying: $DESC..."
    local COUNT=0

    semanage fcontext -a -t httpd_log_t "$LOG_DIR_PHP_SLOW(/.*)?" 2>/dev/null || \
        semanage fcontext -m -t httpd_log_t "$LOG_DIR_PHP_SLOW(/.*)?" 2>/dev/null || true
    restorecon -Rv "$LOG_DIR_PHP_SLOW" >/dev/null 2>&1 || true

    for d in "$DOMAINS_ROOT"/*/; do
        [ -d "$d" ] || continue
        local DOMAIN_PATH="${d%/}"

        semanage fcontext -a -t httpd_sys_content_t "$DOMAIN_PATH(/.*)?" 2>/dev/null || \
            semanage fcontext -m -t httpd_sys_content_t "$DOMAIN_PATH(/.*)?" 2>/dev/null || true
        semanage fcontext -a -t httpd_sys_rw_content_t "$DOMAIN_PATH/logs(/.*)?" 2>/dev/null || \
            semanage fcontext -m -t httpd_sys_rw_content_t "$DOMAIN_PATH/logs(/.*)?" 2>/dev/null || true
        semanage fcontext -a -t httpd_sys_rw_content_t "$DOMAIN_PATH/tmp(/.*)?" 2>/dev/null || \
            semanage fcontext -m -t httpd_sys_rw_content_t "$DOMAIN_PATH/tmp(/.*)?" 2>/dev/null || true
        semanage fcontext -a -t httpd_sys_rw_content_t "$DOMAIN_PATH/public_html/wp-content(/.*)?" 2>/dev/null || \
            semanage fcontext -m -t httpd_sys_rw_content_t "$DOMAIN_PATH/public_html/wp-content(/.*)?" 2>/dev/null || true
        semanage fcontext -a -t httpd_sys_rw_content_t "$DOMAIN_PATH/public_html/storage(/.*)?" 2>/dev/null || \
            semanage fcontext -m -t httpd_sys_rw_content_t "$DOMAIN_PATH/public_html/storage(/.*)?" 2>/dev/null || true
        semanage fcontext -a -t httpd_sys_rw_content_t "$DOMAIN_PATH/public_html/bootstrap/cache(/.*)?" 2>/dev/null || \
            semanage fcontext -m -t httpd_sys_rw_content_t "$DOMAIN_PATH/public_html/bootstrap/cache(/.*)?" 2>/dev/null || true
        restorecon -Rv "$DOMAIN_PATH" >/dev/null 2>&1 || true
        COUNT=$((COUNT+1))
    done

    patch_mark_done "$ID"
    ok "$DESC ($COUNT domains)"
}

# --------------------------------------------------
# v1.3.31 — Bật SELinux boolean cho phép nginx proxy
#           tới Node.js app (502) và php-fpm kết nối
#           MySQL/PostgreSQL qua TCP (500) - trước bản
#           vá này chỉ được set lúc cài PHP mặc định
#           ban đầu, domain xin thêm PHP version khác
#           không có, gây lỗi ngẫu nhiên tuỳ version.
# --------------------------------------------------
patch_1331_selinux_network_booleans(){
    local ID="SP_1331_SELINUX_NETWORK_BOOLEANS"
    local DESC="Enable httpd_can_network_connect(_db) SELinux booleans"

    if patch_applied "$ID"; then
        skip "$DESC"
        return 0
    fi

    if ! command -v setsebool >/dev/null 2>&1; then
        skip "$DESC (SELinux/setsebool not present)"
        patch_mark_done "$ID"
        return 0
    fi

    echo "  Applying: $DESC..."
    setsebool -P httpd_can_network_connect 1 2>/dev/null || true
    setsebool -P httpd_can_network_connect_db 1 2>/dev/null || true

    patch_mark_done "$ID"
    ok "$DESC"
}

# --------------------------------------------------
# v1.3.31 — Retrofit Nginx Security Headers snippet vào
#           domain đã tồn tại. Trước bản vá này, chỉ
#           domain TẠO MỚI mới tự include snippet; domain
#           cũ cần chạy lại "Fix Permissions"/tạo lại config
#           - patch này làm việc đó tự động, an toàn (kiểm
#           tra nginx -t trước khi reload, rollback file nào
#           lỡ làm hỏng test).
# --------------------------------------------------
patch_1331_retrofit_security_headers(){
    local ID="SP_1331_RETROFIT_SECURITY_HEADERS"
    local DESC="Include security headers snippet in existing domain nginx configs"
    local SNIPPET="/etc/nginx/snippets/shieldpress-security-headers.conf"

    if patch_applied "$ID"; then
        skip "$DESC"
        return 0
    fi

    if ! command -v nginx >/dev/null 2>&1; then
        skip "$DESC (nginx not present)"
        patch_mark_done "$ID"
        return 0
    fi

    echo "  Applying: $DESC..."
    mkdir -p "$(dirname "$SNIPPET")"
    [ -f "$SNIPPET" ] || cat > "$SNIPPET" <<'EOF'
# Managed by ShieldPress VPS - Nginx > Security Headers menu.
# Empty by default; populated when "Enable Security Headers" is run.
EOF

    local COUNT=0
    local CONF
    for CONF in /etc/nginx/conf.d/*.conf; do
        [ -f "$CONF" ] || continue
        case "$(basename "$CONF")" in
            shieldpress-*|cache-zone-*|default.conf) continue ;;
        esac
        grep -q "include $SNIPPET;" "$CONF" && continue
        grep -q "add_header" "$CONF" || continue

        local BAK
        BAK=$(mktemp "/tmp/spatch_$(basename "$CONF").XXXXXX")
        cp -a "$CONF" "$BAK"

        # Chèn include ngay sau dòng add_header CUỐI CÙNG trong file.
        local LAST_LINE
        LAST_LINE=$(grep -n "add_header" "$CONF" | tail -1 | cut -d: -f1)
        if [ -n "$LAST_LINE" ]; then
            sed -i "${LAST_LINE}a\\    include $SNIPPET;" "$CONF"
            if nginx -t >/dev/null 2>&1; then
                COUNT=$((COUNT+1))
            else
                fail "nginx -t failed after patching $(basename "$CONF") - reverted"
                cp -a "$BAK" "$CONF"
            fi
        fi
        rm -f "$BAK"
    done

    if [ "$COUNT" -gt 0 ]; then
        systemctl reload nginx 2>/dev/null || true
    fi

    patch_mark_done "$ID"
    ok "$DESC ($COUNT domain configs updated)"
}

# --------------------------------------------------
# v1.3.31 — Cài logrotate cho log nội bộ ShieldPress
#           (trước bản vá này log phình to vô hạn).
# --------------------------------------------------
patch_1331_install_logrotate(){
    local ID="SP_1331_INSTALL_LOGROTATE"
    local DESC="Install logrotate config for ShieldPress logs"

    if patch_applied "$ID"; then
        skip "$DESC"
        return 0
    fi

    if ! command -v logrotate >/dev/null 2>&1; then
        skip "$DESC (logrotate not present)"
        patch_mark_done "$ID"
        return 0
    fi

    echo "  Applying: $DESC..."
    install_logrotate_config

    patch_mark_done "$ID"
    ok "$DESC"
}

# --------------------------------------------------
# v1.3.31 — Cảnh báo (không tự restart) domain Node.js
#           vẫn còn chạy PM2 dưới quyền root (trước bản
#           vá này TẤT CẢ domain Node.js chạy chung 1 PM2
#           daemon root - lỗ hổng RCE=root). Không tự động
#           migrate ở đây vì cần dừng/khởi động lại app
#           đang chạy (gây gián đoạn ngắn) - để admin chủ
#           động chọn thời điểm qua Node.js Menu > Migrate.
# --------------------------------------------------
patch_1331_warn_node_root_pm2(){
    local ID="SP_1331_WARN_NODE_ROOT_PM2"
    local DESC="Warn about Node.js domains still running under root PM2"

    if patch_applied "$ID"; then
        skip "$DESC"
        return 0
    fi

    if ! command -v pm2 >/dev/null 2>&1; then
        patch_mark_done "$ID"
        return 0
    fi

    local FOUND=""
    local d env clean domain
    for env in "$DOMAINS_ROOT"/*/config/domain.env; do
        [ -f "$env" ] || continue
        grep -q "^APP_TYPE=nodejs" "$env" || continue
        d=$(dirname "$(dirname "$env")")
        clean=$(basename "$d")
        if pm2 jlist 2>/dev/null | grep -q "\"name\":\"$clean\""; then
            domain=$(grep "^DOMAIN=" "$env" | cut -d= -f2 | tr -d '[:space:]')
            FOUND="$FOUND $domain"
        fi
    done

    if [ -n "$FOUND" ]; then
        fail "Domain(s) still running Node.js as root:$FOUND"
        info "Fix: Node.js Menu > Migrate to per-user PM2 (brief restart of that app)"
    else
        ok "$DESC (none found)"
    fi

    patch_mark_done "$ID"
}

# --------------------------------------------------
# v1.3.31 — MariaDB/PostgreSQL/PHP-FPM không tự phục
#           hồi sau khi bị OOM-killer giết (mặc định
#           RHEL: mariadb Restart=on-abort không bắt
#           SIGKILL, postgresql/php-fpm Restart=no) -
#           server "hay down" kéo dài dù OOM chỉ xảy
#           ra 1 lần. Ghi systemd drop-in override để
#           tự restart (có giới hạn số lần/300s tránh
#           restart loop che giấu lỗi thật).
# --------------------------------------------------
patch_1331_service_resilience(){
    local ID="SP_1331_SERVICE_RESILIENCE"
    local DESC="Auto-restart MariaDB/PostgreSQL/PHP-FPM after crash/OOM-kill"

    if patch_applied "$ID"; then
        skip "$DESC"
        return 0
    fi

    echo "  Applying: $DESC..."
    local COUNT=0

    apply_systemd_resilience mariadb -500 && COUNT=$((COUNT+1))
    apply_systemd_resilience postgresql && COUNT=$((COUNT+1))

    for VER in 81 82 83 84; do
        apply_systemd_resilience "php${VER}-php-fpm" && COUNT=$((COUNT+1))
    done

    patch_mark_done "$ID"
    ok "$DESC ($COUNT service(s) covered)"
}

# --------------------------------------------------
# v1.3.31 — Tính lại pm.max_children cho domain ĐÃ TỒN
#           TẠI theo công thức mới (chia thêm cho số
#           domain trên server). Công thức cũ tính độc
#           lập từng domain là nguyên nhân chính gây
#           overcommit RAM -> OOM-killer giết MariaDB/
#           PostgreSQL/PHP-FPM. Domain tạo mới đã tự
#           dùng công thức mới (domain/helpers.sh); patch
#           này áp dụng ngược lại cho domain có từ trước.
#           Chỉ sửa dòng pm.max_children, dùng `reload`
#           (không `restart`) - không rớt request đang xử
#           lý.
# --------------------------------------------------
patch_1331_resize_php_pools(){
    local ID="SP_1331_RESIZE_PHP_POOLS"
    local DESC="Recalculate pm.max_children for existing domains (prevent RAM overcommit)"

    if patch_applied "$ID"; then
        skip "$DESC"
        return 0
    fi

    echo "  Applying: $DESC..."

    local TOTAL_RAM DOMAIN_COUNT PHP_MAX
    TOTAL_RAM=$(free -m | awk '/Mem:/ {print $2}')
    DOMAIN_COUNT=$(find "$DOMAINS_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    [ "$DOMAIN_COUNT" -lt 1 ] && DOMAIN_COUNT=1
    PHP_MAX=$((TOTAL_RAM / 50 / DOMAIN_COUNT))
    [ "$PHP_MAX" -lt 5  ] && PHP_MAX=5
    [ "$PHP_MAX" -gt 50 ] && PHP_MAX=50

    local COUNT=0
    local -A TOUCHED_VERSIONS=()
    local d env sysuser php_ver php_short pool_file current

    for env in "$DOMAINS_ROOT"/*/config/domain.env; do
        [ -f "$env" ] || continue
        sysuser=$(grep "^SYSTEM_USER=" "$env" | cut -d= -f2 | tr -d '[:space:]')
        php_ver=$(grep "^PHP_VERSION=" "$env" | cut -d= -f2 | tr -d '[:space:]')
        [ -z "$sysuser" ] || [ -z "$php_ver" ] && continue
        [[ "$sysuser" =~ ^[a-zA-Z0-9_-]{1,32}$ ]] || continue

        php_short=$(echo "$php_ver" | tr -d '.')
        pool_file="/etc/opt/remi/php${php_short}/php-fpm.d/${sysuser}.conf"
        [ -f "$pool_file" ] || continue

        current=$(grep -oP 'pm\.max_children\s*=\s*\K[0-9]+' "$pool_file" 2>/dev/null)
        [ -z "$current" ] && continue
        [ "$current" = "$PHP_MAX" ] && continue

        sed -i "s/pm\.max_children\s*=\s*[0-9]\+/pm.max_children         = ${PHP_MAX}/" "$pool_file"
        TOUCHED_VERSIONS["$php_short"]=1
        COUNT=$((COUNT+1))
    done

    local ver
    for ver in "${!TOUCHED_VERSIONS[@]}"; do
        systemctl reload "php${ver}-php-fpm" 2>/dev/null || true
    done

    patch_mark_done "$ID"
    ok "$DESC ($COUNT pools resized to pm.max_children=$PHP_MAX for $DOMAIN_COUNT domains)"
}

# --------------------------------------------------
# Add new patches above this line.
# Template:
#
# patch_XXX_short_name(){
#     local ID="SP_XXX_SHORT_NAME"
#     local DESC="Human readable description"
#     patch_applied "$ID" && { skip "$DESC"; return 0; }
#     echo "  Applying: $DESC..."
#     # ... fix logic ...
#     patch_mark_done "$ID"
#     ok "$DESC"
# }
# --------------------------------------------------

# ==================================================
# APPLY ALL — called by auto-apply and menu option 2
# ==================================================

apply_all_patches(){
    echo ""
    echo "======================================"
    echo "  ShieldPress Migration Patches"
    echo "======================================"
    echo ""

    patch_134_fix_bin_perms
    patch_134_secure_config_dir
    patch_134_fix_open_basedir_tmp
    patch_134_ensure_php_slow_dir
    patch_138_fix_webmail_smtp
    patch_1331_selinux_domain_context
    patch_1331_selinux_network_booleans
    patch_1331_retrofit_security_headers
    patch_1331_install_logrotate
    patch_1331_warn_node_root_pm2
    patch_1331_service_resilience
    patch_1331_resize_php_pools

    # Add new patch calls here ↑

    echo ""
    echo "======================================"
    ok "All patches processed"
    echo "======================================"
}

# ==================================================
# STATUS — show applied / pending for each patch
# ==================================================

show_patch_status(){
    echo ""
    echo "======================================"
    echo "  Patch Status"
    echo "======================================"
    printf "  %-42s %s\n" "Patch" "Status"
    echo "  ──────────────────────────────────────────────────────"

    _status(){
        local ID="$1" DESC="$2"
        if patch_applied "$ID"; then
            printf "  %-42s ${GREEN}Applied${RESET}\n" "$DESC"
        else
            printf "  %-42s ${YELLOW}Pending${RESET}\n" "$DESC"
        fi
    }

    _status "SP_134_FIX_BIN_PERMS"          "v1.3.4 Fix node_modules/vendor bin perms"
    _status "SP_134_SECURE_CONFIG_DIR"       "v1.3.4 Secure config/ to root:root 700"
    _status "SP_134_FIX_OPEN_BASEDIR_TMP"   "v1.3.4 Remove /tmp from open_basedir"
    _status "SP_134_ENSURE_PHP_SLOW_DIR"     "v1.3.4 Ensure PHP slow log directory exists"
    _status "SP_138_FIX_WEBMAIL_SMTP"        "v1.3.8 Fix Roundcube SMTP config error"
    _status "SP_1331_SELINUX_DOMAIN_CONTEXT"      "v1.3.31 SELinux fcontext for existing domains"
    _status "SP_1331_SELINUX_NETWORK_BOOLEANS"    "v1.3.31 SELinux network_connect(_db) booleans"
    _status "SP_1331_RETROFIT_SECURITY_HEADERS"   "v1.3.31 Retrofit security headers into nginx configs"
    _status "SP_1331_INSTALL_LOGROTATE"           "v1.3.31 Install logrotate for ShieldPress logs"
    _status "SP_1331_WARN_NODE_ROOT_PM2"          "v1.3.31 Warn about Node.js domains running as root"
    _status "SP_1331_SERVICE_RESILIENCE"          "v1.3.31 Auto-restart MariaDB/PostgreSQL/PHP-FPM after crash"
    _status "SP_1331_RESIZE_PHP_POOLS"            "v1.3.31 Resize pm.max_children (prevent RAM overcommit)"

    echo ""
    echo "  Registry: $PATCH_REGISTRY"
    echo "======================================"
}

# ==================================================
# ENTRY POINT — allow non-interactive auto-apply
# ==================================================

# Called by updater: bash patches-menu.sh --auto
if [ "${1:-}" = "--auto" ]; then
    apply_all_patches
    exit 0
fi

# ==================================================
# MENU
# ==================================================

while true; do

    clear
    sp_header "Migration Patches" "Version upgrade fixes"
    sp_menu_grid \
        "1|Show Patch Status|cyan" \
        "2|Apply All Pending Patches|green" \
        "0|Back|white"

    sp_prompt choice

    case $choice in
        1) show_patch_status; echo ""; read -p "Press Enter..." ;;
        2) apply_all_patches; echo ""; read -p "Press Enter..." ;;
        0) break ;;
        *) sp_invalid ;;
    esac

done
