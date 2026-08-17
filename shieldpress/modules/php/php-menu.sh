#!/bin/bash

BASE_DIR="/opt/shieldpress"
MODULE_DIR="$BASE_DIR/modules/php"
OPTIMIZE_DIR="$BASE_DIR/modules/optimize"
CACHE_DIR="$BASE_DIR/modules/cache"
DOMAIN_DIR="$BASE_DIR/modules/domain"
TOOLS_DIR="$BASE_DIR/modules/tools"
source "$BASE_DIR/core/ui.sh"

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

ok(){ echo -e "${GREEN}[OK]${RESET} $1"; }
fail(){ echo -e "${RED}[FAIL]${RESET} $1"; }
warn(){ echo -e "${YELLOW}[WARNING]${RESET} $1"; }
pause(){ echo ""; read -p "Press Enter..."; }

# =================================================
# EDIT PHP POOL CONFIG (per-domain)
# =================================================

edit_php(){
    source "$DOMAIN_DIR/helpers.sh"
    select_domain || return

    echo ""
    echo "Selected domain: $SELECTED_DOMAIN"
    echo "PHP version    : $PHP_VERSION"
    echo ""

    PHP_SHORT=$(echo "$PHP_VERSION" | tr -d '.')
    POOL_FILE="/etc/opt/remi/php${PHP_SHORT}/php-fpm.d/${CLEAN_DOMAIN}.conf"

    if [ ! -f "$POOL_FILE" ]; then
        fail "PHP pool config not found: $POOL_FILE"
        return
    fi

    echo "Opening PHP-FPM pool config:"
    echo "$POOL_FILE"
    echo ""

    if command -v nano &>/dev/null; then
        nano "$POOL_FILE"
    elif command -v vim &>/dev/null; then
        vim "$POOL_FILE"
    else
        vi "$POOL_FILE"
    fi

    echo ""
    read -p "Reload PHP-FPM now? (y/n): " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        systemctl restart php${PHP_SHORT}-php-fpm \
            && ok "PHP-FPM reloaded" \
            || fail "PHP-FPM reload failed"
    fi
}

# =================================================
# SHOW PHP MODULES
# =================================================

show_php_modules(){
    echo ""
    echo "Select PHP version:"
    for php in 81 82 83 84; do
        BIN="/opt/remi/php${php}/root/usr/bin/php"
        [ -x "$BIN" ] && echo "  $((php-80))) PHP 8.${php:1}"
    done
    echo ""
    read -p "Choose: " v
    case $v in
        1) BIN="/opt/remi/php81/root/usr/bin/php" ;;
        2) BIN="/opt/remi/php82/root/usr/bin/php" ;;
        3) BIN="/opt/remi/php83/root/usr/bin/php" ;;
        4) BIN="/opt/remi/php84/root/usr/bin/php" ;;
        *) warn "Invalid"; return ;;
    esac
    [ -x "$BIN" ] && "$BIN" -m || fail "PHP binary not found"
}

# =================================================
# INSTALL IONCUBE
# =================================================

install_ioncube(){
    echo "========================================="
    echo "       IONCUBE INSTALLER (SAFE)"
    echo "========================================="
    echo ""

    [ "$EUID" -ne 0 ] && { fail "Run as root"; return 1; }

    LOCK_FILE="/tmp/shieldpress_ioncube.lock"
    [ -f "$LOCK_FILE" ] && { warn "Another process running"; return 1; }
    touch "$LOCK_FILE"

    cd /tmp || return 1

    PHP_INSTALLED=()
    for php in 81 82 83 84; do
        BIN="/opt/remi/php${php}/root/usr/bin/php"
        [ -x "$BIN" ] && PHP_INSTALLED+=("$php")
    done

    if [ ${#PHP_INSTALLED[@]} -eq 0 ]; then
        rm -f "$LOCK_FILE"
        fail "No PHP versions found"
        return 1
    fi

    echo "Select PHP version:"
    INDEX=1
    declare -A MAP
    for php in "${PHP_INSTALLED[@]}"; do
        VER_DOT="${php:0:1}.${php:1}"
        echo "$INDEX) PHP $VER_DOT"
        MAP[$INDEX]=$php
        ((INDEX++))
    done

    echo "A) ALL | 0) Cancel"
    read -p "Select: " CHOICE

    TARGETS=()
    if [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
        [ "$CHOICE" = "0" ] && { rm -f "$LOCK_FILE"; return; }
        TARGETS=("${MAP[$CHOICE]}")
    elif [[ "$CHOICE" =~ ^[aA]$ ]]; then
        TARGETS=("${PHP_INSTALLED[@]}")
    else
        rm -f "$LOCK_FILE"
        fail "Invalid selection"
        return 1
    fi

    echo "Downloading ionCube..."
    wget -q https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz -O ioncube.tar.gz \
        || { fail "Download failed"; rm -f "$LOCK_FILE"; return 1; }

    tar -xzf ioncube.tar.gz || { fail "Extract failed"; rm -f "$LOCK_FILE"; return 1; }

    IONCUBE_DIR="/tmp/ioncube"

    for php in "${TARGETS[@]}"; do
        PHP_BIN="/opt/remi/php${php}/root/usr/bin/php"
        PHP_FPM="/opt/remi/php${php}/root/usr/sbin/php-fpm"
        VER_DOT="${php:0:1}.${php:1}"

        SO_FILE="${IONCUBE_DIR}/ioncube_loader_lin_${VER_DOT}.so"
        INI_DIR="/etc/opt/remi/php${php}/php.d"
        INI_FILE="${INI_DIR}/00-ioncube.ini"

        [ ! -f "$SO_FILE" ] && { warn "Loader missing for PHP ${VER_DOT}"; continue; }
        mkdir -p "$INI_DIR"

        EXT_DIR=$($PHP_BIN -r "echo ini_get('extension_dir');")
        [ ! -d "$EXT_DIR" ] && { fail "extension_dir not found"; continue; }

        echo "Installing for PHP $VER_DOT..."
        [ -f "$INI_FILE" ] && cp "$INI_FILE" "${INI_FILE}.bak"

        cp "$SO_FILE" "$EXT_DIR/" || { fail "Copy failed"; continue; }

        cat > "$INI_FILE" <<EOF
zend_extension=${EXT_DIR}/ioncube_loader_lin_${VER_DOT}.so
EOF

        JIT_FILE="${INI_DIR}/99-ioncube-jit-disable.ini"
        cat > "$JIT_FILE" <<EOF
opcache.jit=0
opcache.jit_buffer_size=0
EOF

        $PHP_FPM -t >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            fail "Config fail → rollback"
            rm -f "$INI_FILE" "$JIT_FILE" "${EXT_DIR}/ioncube_loader_lin_${VER_DOT}.so"
            [ -f "${INI_FILE}.bak" ] && mv "${INI_FILE}.bak" "$INI_FILE"
            continue
        fi

        systemctl restart php${php}-php-fpm

        if $PHP_BIN -m | grep -qi ionCube; then
            ok "ionCube OK for PHP ${VER_DOT}"
        else
            warn "Installed but not loaded"
        fi
    done

    rm -rf /tmp/ioncube*
    rm -f "$LOCK_FILE"
    ok "ionCube installation complete"
}

# =================================================
# REMOVE IONCUBE
# =================================================

remove_ioncube(){
    echo "========================================="
    echo "       REMOVE IONCUBE"
    echo "========================================="
    echo ""

    [ "$EUID" -ne 0 ] && { fail "Run as root"; return 1; }

    for php in 81 82 83 84; do
        PHP_BIN="/opt/remi/php${php}/root/usr/bin/php"
        [ ! -x "$PHP_BIN" ] && continue

        VER_DOT="${php:0:1}.${php:1}"
        EXT_DIR=$($PHP_BIN -r "echo ini_get('extension_dir');")

        INI_DIR="/etc/opt/remi/php${php}/php.d"
        INI_FILE="${INI_DIR}/00-ioncube.ini"
        JIT_FILE="${INI_DIR}/99-ioncube-jit-disable.ini"

        echo "Removing from PHP $VER_DOT..."
        rm -f "$INI_FILE" "$JIT_FILE" "${EXT_DIR}/ioncube_loader_lin_${VER_DOT}.so"

        systemctl restart php${php}-php-fpm

        if ! $PHP_BIN -m | grep -qi ionCube; then
            ok "Removed ionCube PHP ${VER_DOT}"
        else
            warn "Still detected ionCube in PHP ${VER_DOT}"
        fi
    done

    ok "ionCube removed completely"
}

# =================================================
# RELOAD PHP-FPM
# =================================================

reload_php_fpm(){
    echo ""
    echo "========================================="
    echo "  RELOAD PHP-FPM"
    echo "========================================="
    echo ""

    PHP_INSTALLED=()
    for php in 81 82 83 84; do
        SVC="php${php}-php-fpm"
        systemctl list-unit-files 2>/dev/null | grep -q "$SVC" && PHP_INSTALLED+=("$php")
    done

    if [ ${#PHP_INSTALLED[@]} -eq 0 ]; then
        fail "No PHP-FPM versions found"
        return 1
    fi

    echo "Installed PHP-FPM versions:"
    local INDEX=1
    declare -A PHP_MAP
    for php in "${PHP_INSTALLED[@]}"; do
        VER_DOT="${php:0:1}.${php:1}"
        STATE=$(systemctl is-active "php${php}-php-fpm" 2>/dev/null)
        if [ "$STATE" = "active" ]; then
            echo -e "  $INDEX) PHP ${VER_DOT}-FPM  ${GREEN}●${RESET} $STATE"
        else
            echo -e "  $INDEX) PHP ${VER_DOT}-FPM  ${RED}●${RESET} $STATE"
        fi
        PHP_MAP[$INDEX]=$php
        ((INDEX++))
    done

    echo ""
    echo "  A) Reload ALL PHP-FPM"
    echo "  0) Cancel"
    echo ""
    read -p "Select: " CHOICE

    case $CHOICE in
        [0-9])
            [ "$CHOICE" = "0" ] && return
            local TARGET="${PHP_MAP[$CHOICE]}"
            [ -z "$TARGET" ] && { fail "Invalid selection"; return 1; }
            local VER_DOT="${TARGET:0:1}.${TARGET:1}"
            echo "Reloading PHP ${VER_DOT}-FPM..."
            systemctl restart "php${TARGET}-php-fpm" 2>/dev/null \
                && ok "php${TARGET}-php-fpm restarted" \
                || fail "php${TARGET}-php-fpm restart failed"
            ;;
        [aA])
            echo "Reloading ALL PHP-FPM services..."
            for php in "${PHP_INSTALLED[@]}"; do
                systemctl restart "php${php}-php-fpm" 2>/dev/null \
                    && ok "php${php}-php-fpm restarted" \
                    || warn "php${php}-php-fpm restart failed"
            done
            ;;
        *) fail "Invalid option" ;;
    esac
}

# =================================================
# MENU
# =================================================

while true; do
    clear
    sp_header "PHP Manager" "Versions, extensions & optimization"
    sp_menu_grid \
        "1|Optimize PHP-FPM|green" \
        "2|Enable PHP JIT|yellow" \
        "3|OPcache Manager|blue" \
        "4|Change PHP Version|cyan" \
        "5|Install/Remove PHP Version|cyan" \
        "6|PHP Extension Manager|green" \
        "7|Install ionCube|green" \
        "8|Remove ionCube|red" \
        "9|Show PHP Modules|cyan" \
        "10|PHP Info Viewer|blue" \
        "11|Edit PHP Pool Config|yellow" \
        "12|Auto-Reload PHP-FPM|green" \
        "13|Reload PHP-FPM|yellow" \
        "0|Back|white"
    sp_prompt choice

    case $choice in
        1)  bash "$OPTIMIZE_DIR/php-optimize.sh" ;;
        2)  bash "$OPTIMIZE_DIR/php-jit.sh" ;;
        3)  bash "$CACHE_DIR/opcache.sh" ;;
        4)  bash "$DOMAIN_DIR/change-php.sh" ;;
        5)  bash "$MODULE_DIR/php-version-manager.sh" ;;
        6)  bash "$MODULE_DIR/php-extensions.sh" ;;
        7)  install_ioncube ;;
        8)  remove_ioncube ;;
        9)  show_php_modules ;;
        10) bash "$MODULE_DIR/php-info.sh" ;;
        11) edit_php ;;
        12) bash "$TOOLS_DIR/auto-reload-php.sh" ;;
        13) reload_php_fpm ;;
        0)  break ;;
        *)  sp_invalid ;;
    esac

    pause
done
