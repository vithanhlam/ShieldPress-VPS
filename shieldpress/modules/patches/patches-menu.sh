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
