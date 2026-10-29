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
source "$BASE_DIR/modules/helpers/task-progress.sh"

# Keep patch state in the persistent runtime data directory. The updater
# atomically replaces /opt/shieldpress, so a registry stored in the source
# tree can otherwise disappear and cause every update to rescan all domains.
PATCH_REGISTRY="${DATA_DIR:-/var/shieldpress/data}/patches-applied.txt"
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

# Ensure one persistent SELinux fcontext rule without making semanage try to
# add an existing rule first.  The old add-then-modify pattern prints a noisy
# "already defined, modifying instead" warning for every domain on every
# migration run.  Cache the rule list once because semanage is comparatively
# expensive on servers with many domains.
SELINUX_FCONTEXT_LIST=""
selinux_fcontext_ensure(){
    local type="$1"
    local pattern="$2"
    local current

    if [ -z "$SELINUX_FCONTEXT_LIST" ]; then
        SELINUX_FCONTEXT_LIST=$(semanage fcontext -l 2>/dev/null || true)
    fi

    current=$(printf '%s\n' "$SELINUX_FCONTEXT_LIST" | awk -v pattern="$pattern" '$1 == pattern {print $NF; exit}')
    if [ "$current" = "$type" ]; then
        return 0
    elif [ -n "$current" ]; then
        semanage fcontext -m -t "$type" "$pattern" >/dev/null 2>&1 || true
    else
        semanage fcontext -a -t "$type" "$pattern" >/dev/null 2>&1 || true
    fi
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

    selinux_fcontext_ensure httpd_log_t "$LOG_DIR_PHP_SLOW(/.*)?"
    restorecon -Rv "$LOG_DIR_PHP_SLOW" >/dev/null 2>&1 || true

    for d in "$DOMAINS_ROOT"/*/; do
        [ -d "$d" ] || continue
        local DOMAIN_PATH="${d%/}"

        selinux_fcontext_ensure httpd_sys_content_t "$DOMAIN_PATH(/.*)?"
        selinux_fcontext_ensure httpd_sys_rw_content_t "$DOMAIN_PATH/logs(/.*)?"
        selinux_fcontext_ensure httpd_sys_rw_content_t "$DOMAIN_PATH/tmp(/.*)?"
        selinux_fcontext_ensure httpd_sys_rw_content_t "$DOMAIN_PATH/public_html/wp-content(/.*)?"
        selinux_fcontext_ensure httpd_sys_rw_content_t "$DOMAIN_PATH/public_html/storage(/.*)?"
        selinux_fcontext_ensure httpd_sys_rw_content_t "$DOMAIN_PATH/public_html/bootstrap/cache(/.*)?"
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
        info "Fix: Node.js Manager > 14) Migrate root PM2 to user (brief restart of that app)"
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
# Legacy entrypoint delegates to the shared budget so old upgrades cannot
# overwrite lower custom pool limits after the new migration has run.
patch_1331_resize_php_pools(){
    local ID="SP_1331_RESIZE_PHP_POOLS"
    patch_applied "$ID" && return 0
    if python3 "$BASE_DIR/modules/helpers/php-budget.py" --apply; then
        patch_mark_done "$ID"
        ok "Legacy PHP pool sizing repaired with the shared runtime budget"
    else
        fail "Legacy PHP pool sizing remains pending"
        return 1
    fi
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

# Also runs after an upgrade launched by the old updater, whose config copy
# still nests files before this new source is installed.
patch_recover_backup_config(){
    local ID="SP_RECOVER_UPDATE_BACKUP_CONFIG" legacy_config
    patch_applied "$ID" && return 0
    mkdir -p "$BASE_DIR/config" || return 1
    legacy_config="$BASE_DIR/config/config"
    while [ -d "$legacy_config" ]; do
        rsync -a --ignore-existing --exclude=/config "$legacy_config/" "$BASE_DIR/config/" || return 1
        legacy_config="$legacy_config/config"
    done
    chmod +x "$BASE_DIR/bin/laravel-pg-backup" || return 1
    patch_mark_done "$ID"
    ok "Recovered nested backup settings and enabled PostgreSQL backup runner"
}

# Existing cron scripts live in persistent config directories, so replacing
# the packaged generators alone does not repair their restricted cron PATH.
patch_backup_scheduled_jobs(){
    local ID="SP_20260928_BACKUP_JOBS" script count=0
    patch_applied "$ID" && return 0

    for script in "$BASE_DIR"/config/auto-backup/auto-backup-db-*.sh \
                  "$BASE_DIR"/config/auto-backup/auto-backup-full-db-batch.sh \
                  "$DOMAINS_ROOT"/*/config/auto-backup-db.sh; do
        [ -f "$script" ] || continue
        if grep -qx 'set -o pipefail' "$script" && ! grep -q '^export PATH=' "$script"; then
            sed -i '/^set -o pipefail$/a export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' "$script" || return 1
        fi
        if grep -Fq 'ls -1t "$BACKUP_DIR"/*.gz' "$script"; then
            sed -i '/ls -1t "\$BACKUP_DIR"\/\*\.gz/c\    source "$BASE_DIR/modules/backup/_backup_helper.sh"; prune_local_backups "$BACKUP_DIR" "$RETENTION" "${DB_NAME}_*.sql.gz"' "$script" || return 1
        fi
        if [ "${script##*/}" = auto-backup-full-db-batch.sh ] &&
           ! grep -Fq 'exec 2>>"$RUN_LOG_FILE"' "$script"; then
            sed -i '/^RUN_LOG_FILE=.*auto-backup.log.*$/a exec 2>>"$RUN_LOG_FILE"' "$script" || return 1
        fi
        bash -n "$script" || return 1
        count=$((count + 1))
    done

    patch_mark_done "$ID"
    ok "Repaired cron PATH and database-specific backup retention ($count jobs)"
}

patch_ssl_auto_renew(){
    local ID="SP_20261001_SSL_AUTO_RENEW"
    patch_applied "$ID" && { skip "SSL auto-renew migration already applied"; return 0; }
    if ! command -v certbot >/dev/null; then
        skip "Certbot is not installed; SSL auto-renew migration remains pending"
        return 0
    fi
    if bash "$BASE_DIR/modules/ssl/setup-auto-renew.sh"; then
        patch_mark_done "$ID"
        ok "SSL auto-renew schedule and legacy mail authentication repaired"
    else
        fail "SSL auto-renew migration incomplete; remains pending for retry"
        return 1
    fi
}

patch_wp_recovery_output(){
    local ID="SP_20261005_WP_RECOVERY_SCAN_LOCK"
    local unit="shieldpress-wp-recovery.service"
    local dropin="/etc/systemd/system/${unit}.d"
    patch_applied "$ID" && return 0
    if [ ! -f "/etc/systemd/system/$unit" ]; then
        skip "WordPress recovery service is not installed; migration remains pending"
        return 0
    fi
    if ! mkdir -p "$dropin"; then
        fail "Cannot create WordPress recovery service override"
        return 1
    fi
    if ! cat > "$dropin/10-recovery-output.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=/bin/bash /opt/shieldpress/modules/wordpress/wp-auto-recovery.sh --daemon
StandardOutput=journal
StandardError=journal
WorkingDirectory=/opt/shieldpress
EOF
    then
        fail "Cannot write WordPress recovery service override"
        return 1
    fi
    if ! systemctl daemon-reload; then
        fail "Cannot reload WordPress recovery service; migration remains pending"
        return 1
    fi
    if systemctl is-enabled --quiet "$unit" || systemctl is-active --quiet "$unit"; then
        if ! systemctl restart "$unit"; then
            fail "WordPress recovery restart failed; migration remains pending"
            return 1
        fi
        sleep 2
        if ! systemctl is-active --quiet "$unit"; then
            fail "WordPress recovery is not running; migration remains pending"
            return 1
        fi
    fi
    patch_mark_done "$ID"
    ok "WordPress recovery service output repaired"
}

# Repair only previously restored WordPress sites whose local DB login is broken.
# Working sites and non-WordPress applications are left alone.
patch_restored_wordpress_db(){
    local ID="SP_20261025_RESTORE_WORDPRESS_DB" d domain pending=0
    if patch_applied "$ID"; then
        skip "Restored WordPress database configuration"
        return 0
    fi
    for d in "$DOMAINS_ROOT"/*; do
        [ -f "$d/config/domain.env" ] || continue
        domain=$(sed -n 's/^DOMAIN=//p' "$d/config/domain.env")
        [ -n "$domain" ] || continue
        grep -Fq "SUCCESS RESTORE: $domain (wordpress)" "$LOG_DIR/backup.log" 2>/dev/null || continue
        python3 "$BASE_DIR/modules/backup/restore-wordpress-db.py" "$d" --migrate || pending=1
    done
    if [ "$pending" -ne 0 ]; then
        fail "Restored WordPress DB repair remains pending; review managed credentials and retry"
        return 1
    fi
    patch_mark_done "$ID"
    ok "Restored WordPress database configuration checked"
}

patch_domain_privilege_boundary(){
    local ID="SP_20261025_DOMAIN_PRIVILEGE_BOUNDARY"
    patch_applied "$ID" && return 0
    # Also protect the first upgrade launched by an older updater that preserved
    # archive owner IDs. The new release archive uses numeric root ownership.
    chown -hR root:root "$BASE_DIR" || return 1
    find "$BASE_DIR" -type d -exec chmod go-w {} + || return 1
    find "$BASE_DIR" -type f -exec chmod go-w {} + || return 1
    if python3 "$BASE_DIR/modules/security/domain-boundary-migration.py" --base "$BASE_DIR" --domains "$DOMAINS_ROOT" --etc "$ETC_DIR"; then
        patch_mark_done "$ID"
        ok "Protected domain control directories and rebuilt domain backup schedules"
    else
        return 1
    fi
}

patch_server_migration_storage(){
    local ID="SP_20261025_SERVER_MIGRATION_STORAGE_V2"
    patch_applied "$ID" && return 0
    if python3 "$BASE_DIR/modules/tools/server-migration.py" upgrade; then
        patch_mark_done "$ID"
        ok "Server Migration storage prepared; legacy packages and orphan recovery artifacts preserved"
    else
        fail "Server Migration storage preparation remains pending; review storage permissions, recovery details and Nginx health before retrying"
        return 1
    fi
}

patch_nodejs_same_branch_updates(){
    local ID="SP_20261026_NODEJS_SAME_BRANCH_UPDATES"
    patch_applied "$ID" && return 0
    # The source updater installs the repair; no runtime or repository change
    # is needed until the administrator explicitly confirms an update.
    if bash -n "$BASE_DIR/modules/helpers/nodejs-runtime.sh" &&
        bash -c 'source "$1" && declare -F update_shieldpress_nodejs_current_branch >/dev/null' \
            _ "$BASE_DIR/modules/helpers/nodejs-runtime.sh"; then
        patch_mark_done "$ID"
        ok "Same-branch Node.js updates enabled; installed runtime and repositories retained"
    else
        fail "Same-branch Node.js update repair remains pending; reinstall the updated source"
        return 1
    fi
}

patch_service_security_updates(){
    local ID="SP_20261026_SERVICE_SECURITY_UPDATES"
    patch_applied "$ID" && return 0
    local menu
    # Source replacement is the repair. Do not apply package updates, restart
    # services or modify existing policies during the migration itself.
    if ! bash -n "$BASE_DIR/modules/upgrade/service-updates.sh" ||
        ! python3 -c 'import ast, pathlib, sys; ast.parse(pathlib.Path(sys.argv[1]).read_text())' \
            "$BASE_DIR/modules/upgrade/service-updates.py"; then
        fail "Service security update menus remain pending; reinstall the updated source"
        return 1
    fi
    for menu in nginx/nginx-menu.sh php/php-menu.sh database/mariadb-menu.sh database/pg-menu.sh; do
        if ! grep -q 'service-updates.sh' "$BASE_DIR/modules/$menu"; then
            fail "Service security update menu remains pending: $menu"
            return 1
        fi
    done
    patch_mark_done "$ID"
    ok "Version and security update menus enabled for Nginx, PHP, MariaDB and PostgreSQL"
}

patch_service_rpm_versions(){
    local ID="SP_20261027_SERVICE_RPM_VERSIONS"
    patch_applied "$ID" && return 0
    # Source replacement installs the repair without changing server packages.
    if ! python3 - "$BASE_DIR/modules/upgrade/service-updates.py" <<'PYTHON'
import runpy
import sys
module = runpy.run_path(sys.argv[1])
assert module['branch']('php84', '8.4.0~RC1') == '8.4'
assert module['branch']('nginx', '1.0.0~rc') == '1.0'
assert callable(module['package_version_allowed'])
PYTHON
    then
        fail "Service RPM version repair remains pending; reinstall the updated source"
        return 1
    fi
    patch_mark_done "$ID"
    ok "Service RPM version, PHP extension and Nginx module checks repaired"
}

patch_shared_runtime_budget(){
    local ID="SP_20261026_CACHE_ACCESS_LOG_REPAIR"
    patch_applied "$ID" && return 0
    info "Applying shared PHP budget and WordPress cache policy (usually under a minute)..."
    python3 "$BASE_DIR/modules/helpers/php-budget.py" --apply || {
        fail "Shared PHP budget repair remains pending"
        return 1
    }
    if [ -f /etc/nginx/nginx.conf ]; then
        python3 "$BASE_DIR/modules/helpers/wordpress-cache.py" --migrate || {
            fail "WordPress cache policy repair remains pending"
            return 1
        }
    fi
    python3 "$BASE_DIR/modules/helpers/warmup-schedule.py" || {
        fail "Warmup schedule repair remains pending"
        return 1
    }
    patch_mark_done "$ID"
    ok "Shared runtime budget and enabled WordPress caches repaired"
}

patch_nginx_worker_limits(){
    local ID="SP_20261026_NGINX_WORKER_LIMITS"
    patch_applied "$ID" && return 0
    if [ ! -f /etc/nginx/nginx.conf ]; then
        skip "Nginx configuration missing; worker limit repair remains pending"
        return 0
    fi
    info "Bounding Nginx worker allocation (usually a few seconds)..."
    if python3 "$BASE_DIR/modules/helpers/nginx-workers.py" --clamp --reload; then
        patch_mark_done "$ID"
        ok "Nginx worker allocation bounded"
    else
        fail "Nginx worker limit repair remains pending; review Nginx configuration and retry"
        return 1
    fi
}

patch_service_versionlock_repair(){
    local ID="SP_20261026_SERVICE_VERSIONLOCK_REPAIR"
    patch_applied "$ID" && return 0
    if python3 "$BASE_DIR/modules/upgrade/service-updates.py" --repair-versionlock; then
        patch_mark_done "$ID"
        ok "Service update package protection repaired; existing rules retained"
    else
        fail "Service update package protection repair remains pending; use Repair Package Protection in the service update menu"
        return 1
    fi
}

apply_all_patches(){
    local ssl_status=0
    echo ""
    echo "======================================"
    echo "  ShieldPress Migration Patches"
    echo "======================================"
    echo ""

    # Fail closed before older migrations inspect any per-domain control data.
    if ! patch_domain_privilege_boundary; then
        fail "Domain privilege boundary repair remains pending; older patches were not run"
        return 1
    fi

    # Retry safely on every update, including orphaned schedules from older deletes.
    if ! python3 "$BASE_DIR/modules/backup/cleanup-domain-jobs.py" --base "$BASE_DIR" --domains "$DOMAINS_ROOT"; then
        fail "Orphaned backup schedule cleanup remains pending"
        ssl_status=1
    fi
    # The running updater may be from the previous release. Repair the shortcut
    # from the newly installed source and retry failures on subsequent runs.
    if source "$BASE_DIR/core/update-shortcut.sh" && sp_install_update_shortcut; then
        ok "Update shortcut installed: 2 (shieldpress update)"
    else
        fail "Update shortcut repair remains pending"
        ssl_status=1
    fi
    patch_recover_backup_config
    patch_server_migration_storage || ssl_status=$?
    patch_nodejs_same_branch_updates || ssl_status=$?
    patch_service_security_updates || ssl_status=$?
    patch_service_versionlock_repair || ssl_status=$?
    patch_service_rpm_versions || ssl_status=$?
    patch_nginx_worker_limits || ssl_status=$?
    local policy_timing="${DATA_DIR:-/var/shieldpress/data}/runtime-policy-timing"
    if install -d -m 700 "$policy_timing"; then
        run_with_loading "Shared runtime policy migration" "$policy_timing/migration" 30 patch_shared_runtime_budget || ssl_status=$?
    else
        fail "Cannot create runtime policy timing directory; migration remains pending"
        ssl_status=1
    fi
    patch_restored_wordpress_db || ssl_status=$?
    patch_backup_scheduled_jobs
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
    patch_1331_resize_php_pools || ssl_status=$?
    patch_ssl_auto_renew || ssl_status=$?
    patch_wp_recovery_output || ssl_status=$?

    # Add new patch calls here ↑

    echo ""
    echo "======================================"
    ok "All patches processed"
    echo "======================================"
    return "$ssl_status"
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

    _status "SP_20261025_DOMAIN_PRIVILEGE_BOUNDARY" "Protect root control paths and rebuild domain jobs"
    _status "SP_20261026_NODEJS_SAME_BRANCH_UPDATES" "Enable same-branch Node.js updates"
    _status "SP_20261026_SERVICE_SECURITY_UPDATES" "Enable service version and security updates"
    _status "SP_20261026_SERVICE_VERSIONLOCK_REPAIR" "Repair service update package protection"
    _status "SP_20261026_NGINX_WORKER_LIMITS" "Bound Nginx worker memory allocation"
    _status "SP_20261025_RESTORE_WORDPRESS_DB" "Repair restored WordPress database configuration"
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
    _status "SP_20261026_CACHE_ACCESS_LOG_REPAIR" "Shared PHP budget, WordPress cache and warmup schedules"
    _status "SP_1331_RESIZE_PHP_POOLS"            "v1.3.31 Resize pm.max_children (prevent RAM overcommit)"
    _status "SP_20260928_BACKUP_JOBS"             "Repair existing database backup schedules"
    _status "SP_20261001_SSL_AUTO_RENEW"          "Repair SSL auto-renew and standalone mail certificates"
    _status "SP_20261005_WP_RECOVERY_OUTPUT"      "Repair WordPress recovery daemon startup output"
    _status "SP_20261005_WP_RECOVERY_SCAN_LOCK"   "Restart WordPress recovery with scan-scoped locking"

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
    patch_status=$?

    # The updater process may still be executing the old release's code after
    # atomically switching /opt/shieldpress. Run this hook from the newly
    # installed migration script so PHP security updates also run on that first
    # upgrade, including upgrades from releases without the updater hook.
    echo ""
    info "Applying PHP security updates..."
    if bash "$BASE_DIR/modules/security/php-security-patch.sh" --apply; then
        ok "PHP security update step completed"
    else
        fail "PHP security update remains pending; review the output and retry"
        patch_status=1
    fi

    exit "$patch_status"
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
