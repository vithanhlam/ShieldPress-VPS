#!/bin/bash

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
BOLD="\e[1m"
DIM="\e[2m"
RESET="\e[0m"

ok(){ echo -e "${GREEN}[OK]${RESET} $1"; }
fail(){ echo -e "${RED}[FAIL]${RESET} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $1"; }

# =================================================
# Full extension list: "display_name|module_name|package_suffix"
#   display_name  = shown in menu
#   module_name   = name reported by php -m (lowercase)
#   package_suffix = dnf package name after php${VER}- prefix
# =================================================

EXTENSIONS=(
    # ---- Database ----
    "MySQLnd|mysqlnd|php-mysqlnd"
    "PostgreSQL|pgsql|php-pgsql"
    "MongoDB|mongodb|php-pecl-mongodb"
    "SQLite3|sqlite3|php-sqlite3"
    "PDO MySQL|pdo_mysql|php-mysqlnd"
    "PDO PostgreSQL|pdo_pgsql|php-pgsql"
    # ---- Cache ----
    "Redis|redis|php-pecl-redis"
    "Memcached|memcached|php-pecl-memcached"
    "APCu|apcu|php-pecl-apcu"
    "OPcache|Zend OPcache|php-opcache"
    # ---- Image ----
    "GD|gd|php-gd"
    "Imagick|imagick|php-pecl-imagick"
    # ---- Text / XML ----
    "XML|xml|php-xml"
    "DOM|dom|php-xml"
    "SimpleXML|SimpleXML|php-xml"
    "XMLWriter|xmlwriter|php-xml"
    "XMLReader|xmlreader|php-xml"
    "Mbstring|mbstring|php-mbstring"
    "Intl|intl|php-intl"
    "JSON|json|php-json"
    # ---- Network ----
    "cURL|curl|php-curl"
    "SOAP|soap|php-soap"
    "LDAP|ldap|php-ldap"
    "FTP|ftp|php-ftp"
    "Sockets|sockets|php-sockets"
    # ---- Security ----
    "Sodium|sodium|php-sodium"
    "OpenSSL|openssl|php-openssl"
    # ---- Archive ----
    "Zip|zip|php-zip"
    "Bz2|bz2|php-bz2"
    "Zlib|zlib|php-common"
    "Phar|Phar|php-phar"
    # ---- Math ----
    "BCMath|bcmath|php-bcmath"
    "GMP|gmp|php-gmp"
    # ---- Development ----
    "Xdebug|xdebug|php-pecl-xdebug"
    "Xhprof|xhprof|php-pecl-xhprof"
    # ---- Performance ----
    "Swoole|swoole|php-pecl-swoole"
    # ---- Other ----
    "YAML|yaml|php-pecl-yaml"
    "Tidy|tidy|php-tidy"
    "IMAP|imap|php-imap"
    "Exif|exif|php-exif"
    "Fileinfo|fileinfo|php-fileinfo"
    "Calendar|calendar|php-calendar"
    "Gettext|gettext|php-gettext"
    "PCNTL|pcntl|php-process"
    "Posix|posix|php-process"
    "Readline|readline|php-readline"
    "UUID|uuid|php-pecl-uuid"
    "CSV|csv|php-pecl-csv"
    "ionCube Loader|ionCube Loader|ioncube"
)

TOTAL_EXT=${#EXTENSIONS[@]}

# =================================================
# Select PHP version
# =================================================

select_php_version(){
    PHP_INSTALLED=()
    for php in 81 82 83 84; do
        BIN="/opt/remi/php${php}/root/usr/bin/php"
        [ -x "$BIN" ] && PHP_INSTALLED+=("$php")
    done

    if [ ${#PHP_INSTALLED[@]} -eq 0 ]; then
        fail "No PHP versions found"
        return 1
    fi

    if [ ${#PHP_INSTALLED[@]} -eq 1 ]; then
        SELECTED_PHP="${PHP_INSTALLED[0]}"
        VER_DOT="${SELECTED_PHP:0:1}.${SELECTED_PHP:1}"
        echo "  Auto-selected PHP $VER_DOT (only version installed)"
        return 0
    fi

    echo "Select PHP version:"
    local IDX=1
    declare -gA _VER_MAP
    for php in "${PHP_INSTALLED[@]}"; do
        VER_DOT="${php:0:1}.${php:1}"
        STATE=$(systemctl is-active "php${php}-php-fpm" 2>/dev/null)
        if [ "$STATE" = "active" ]; then
            echo -e "  $IDX) PHP $VER_DOT  ${GREEN}●${RESET}"
        else
            echo -e "  $IDX) PHP $VER_DOT  ${RED}●${RESET}"
        fi
        _VER_MAP[$IDX]=$php
        ((IDX++))
    done
    echo "  0) Cancel"
    echo ""
    read -p "Choose: " VC

    [ "$VC" = "0" ] && return 1
    SELECTED_PHP="${_VER_MAP[$VC]}"
    [ -z "$SELECTED_PHP" ] && { fail "Invalid"; return 1; }
    return 0
}

# =================================================
# Check if a module is loaded in given PHP version
# =================================================

is_module_loaded(){
    local PHP_SHORT="$1"
    local MODULE_NAME="$2"
    local BIN="/opt/remi/php${PHP_SHORT}/root/usr/bin/php"

    "$BIN" -m 2>/dev/null | grep -qi "^${MODULE_NAME}$"
}

# =================================================
# Check if an extension ini is disabled (.disabled)
# =================================================

is_ini_disabled(){
    local PHP_SHORT="$1"
    local MODULE_NAME="$2"
    local INI_DIR="/etc/opt/remi/php${PHP_SHORT}/php.d"

    # Look for .disabled files matching this module
    local LOWER=$(echo "$MODULE_NAME" | tr '[:upper:]' '[:lower:]')
    ls "$INI_DIR"/*"${LOWER}"*.disabled "$INI_DIR"/*"${LOWER}"*.ini.bak 2>/dev/null | head -1
}

# =================================================
# Enable extension (install if missing, enable if disabled)
# =================================================

enable_extension(){
    local PHP_SHORT="$1"
    local MODULE_NAME="$2"
    local PKG_SUFFIX="$3"
    local DISPLAY_NAME="$4"
    local VER_DOT="${PHP_SHORT:0:1}.${PHP_SHORT:1}"
    local INI_DIR="/etc/opt/remi/php${PHP_SHORT}/php.d"
    local BIN="/opt/remi/php${PHP_SHORT}/root/usr/bin/php"

    # Skip ionCube (managed separately via PHP Manager)
    if [ "$PKG_SUFFIX" = "ioncube" ]; then
        warn "ionCube is managed via PHP Manager > Install ionCube"
        return
    fi

    echo ""
    echo "Enabling $DISPLAY_NAME for PHP $VER_DOT..."

    # Case 1: ini file is disabled → re-enable it
    local LOWER=$(echo "$MODULE_NAME" | tr '[:upper:]' '[:lower:]')
    local DISABLED_INI=$(ls "$INI_DIR"/*"${LOWER}"*.disabled 2>/dev/null | head -1)

    if [ -n "$DISABLED_INI" ]; then
        local ENABLED_INI="${DISABLED_INI%.disabled}"
        mv "$DISABLED_INI" "$ENABLED_INI"
        systemctl restart "php${PHP_SHORT}-php-fpm" 2>/dev/null

        if is_module_loaded "$PHP_SHORT" "$MODULE_NAME"; then
            ok "$DISPLAY_NAME enabled"
        else
            warn "File restored but module not detected"
        fi
        return
    fi

    # Case 2: not installed → install via dnf
    echo "  Package not found locally, installing..."

    local PKG="php${PHP_SHORT}-${PKG_SUFFIX}"
    dnf install -y "$PKG" 2>/dev/null
    if [ $? -ne 0 ]; then
        # Try alternative naming
        local ALT_PKG="php${PHP_SHORT}-php-${PKG_SUFFIX#php-}"
        dnf install -y "$ALT_PKG" 2>/dev/null
        if [ $? -ne 0 ]; then
            fail "Could not install $DISPLAY_NAME (tried $PKG, $ALT_PKG)"
            return
        fi
    fi

    systemctl restart "php${PHP_SHORT}-php-fpm" 2>/dev/null

    if is_module_loaded "$PHP_SHORT" "$MODULE_NAME"; then
        ok "$DISPLAY_NAME installed and enabled"
    else
        warn "Package installed but module not detected in php -m"
    fi
}

# =================================================
# Disable extension (rename ini to .disabled)
# =================================================

disable_extension(){
    local PHP_SHORT="$1"
    local MODULE_NAME="$2"
    local PKG_SUFFIX="$3"
    local DISPLAY_NAME="$4"
    local VER_DOT="${PHP_SHORT:0:1}.${PHP_SHORT:1}"
    local INI_DIR="/etc/opt/remi/php${PHP_SHORT}/php.d"

    # Skip ionCube
    if [ "$PKG_SUFFIX" = "ioncube" ]; then
        warn "ionCube is managed via PHP Manager > Remove ionCube"
        return
    fi

    # Core modules that should not be disabled
    local CORE_MODULES="json date pcre spl standard"
    local LOWER=$(echo "$MODULE_NAME" | tr '[:upper:]' '[:lower:]')
    if echo "$CORE_MODULES" | grep -qw "$LOWER"; then
        fail "$DISPLAY_NAME is a core module and cannot be disabled"
        return
    fi

    echo ""
    echo "Disabling $DISPLAY_NAME for PHP $VER_DOT..."

    # Find the ini file that loads this module
    local INI_FILE=""

    # Search by module name in ini files
    for f in "$INI_DIR"/*.ini; do
        [ -f "$f" ] || continue
        if grep -qi "${LOWER}" "$f" 2>/dev/null; then
            INI_FILE="$f"
            break
        fi
    done

    if [ -z "$INI_FILE" ]; then
        # Try by package name
        for f in "$INI_DIR"/*.ini; do
            [ -f "$f" ] || continue
            local FNAME=$(basename "$f" | tr '[:upper:]' '[:lower:]')
            if echo "$FNAME" | grep -q "${LOWER}"; then
                INI_FILE="$f"
                break
            fi
        done
    fi

    if [ -n "$INI_FILE" ] && [[ "$INI_FILE" != *.disabled ]]; then
        mv "$INI_FILE" "${INI_FILE}.disabled"
        systemctl restart "php${PHP_SHORT}-php-fpm" 2>/dev/null

        if ! is_module_loaded "$PHP_SHORT" "$MODULE_NAME"; then
            ok "$DISPLAY_NAME disabled"
        else
            warn "INI disabled but module still loaded (may be compiled-in)"
            # Restore
            mv "${INI_FILE}.disabled" "$INI_FILE"
        fi
    else
        warn "Cannot find INI config for $DISPLAY_NAME"
        echo ""
        read -p "  Remove package instead? (y/n): " confirm
        if [[ "$confirm" =~ ^[yY]$ ]]; then
            for PKG_PATTERN in "php${PHP_SHORT}-php-pecl-${LOWER}" "php${PHP_SHORT}-php-${LOWER}" "php${PHP_SHORT}-${PKG_SUFFIX}"; do
                if rpm -q "$PKG_PATTERN" &>/dev/null; then
                    dnf remove -y "$PKG_PATTERN" 2>/dev/null && {
                        systemctl restart "php${PHP_SHORT}-php-fpm" 2>/dev/null
                        ok "$DISPLAY_NAME removed"
                        return
                    }
                fi
            done
            fail "Package not found for removal"
        fi
    fi
}

# =================================================
# Main extension list with toggle
# =================================================

show_extensions(){
    local PHP_SHORT="$1"
    local VER_DOT="${PHP_SHORT:0:1}.${PHP_SHORT:1}"
    local BIN="/opt/remi/php${PHP_SHORT}/root/usr/bin/php"

    # Get all loaded modules once
    local LOADED_MODULES
    LOADED_MODULES=$("$BIN" -m 2>/dev/null | tr '[:upper:]' '[:lower:]')

    local PAGE_SIZE=20
    local OFFSET=${2:-0}
    local END=$((OFFSET + PAGE_SIZE))
    [ "$END" -gt "$TOTAL_EXT" ] && END=$TOTAL_EXT

    clear
    echo "===================================================="
    echo -e "  PHP $VER_DOT EXTENSIONS  ${DIM}(${OFFSET}-$((END-1)) of $((TOTAL_EXT-1)))${RESET}"
    echo "===================================================="
    echo -e "  ${GREEN}● ON${RESET}  ${RED}● OFF${RESET}  ${YELLOW}● Not installed${RESET}"
    echo "----------------------------------------------------"

    local IDX=$OFFSET
    while [ $IDX -lt $END ]; do
        local ENTRY="${EXTENSIONS[$IDX]}"
        local DISPLAY=$(echo "$ENTRY" | cut -d'|' -f1)
        local MODULE=$(echo "$ENTRY" | cut -d'|' -f2)
        local PKG=$(echo "$ENTRY" | cut -d'|' -f3)
        local MODULE_LOWER=$(echo "$MODULE" | tr '[:upper:]' '[:lower:]')
        local INI_DIR="/etc/opt/remi/php${PHP_SHORT}/php.d"

        # Determine status
        local STATUS_ICON
        if echo "$LOADED_MODULES" | grep -q "^${MODULE_LOWER}$"; then
            STATUS_ICON="${GREEN}●${RESET}"
        elif ls "$INI_DIR"/*"${MODULE_LOWER}"*.disabled &>/dev/null 2>&1; then
            STATUS_ICON="${RED}●${RESET}"
        else
            # Check if package is installed but module not loaded
            local FOUND_PKG=0
            for P in "php${PHP_SHORT}-${PKG}" "php${PHP_SHORT}-php-${PKG#php-}"; do
                rpm -q "$P" &>/dev/null 2>&1 && { FOUND_PKG=1; break; }
            done
            if [ "$FOUND_PKG" = "1" ]; then
                STATUS_ICON="${RED}●${RESET}"
            else
                STATUS_ICON="${YELLOW}●${RESET}"
            fi
        fi

        printf "  %b %-3s %-25s\n" "$STATUS_ICON" "$((IDX+1)))" "$DISPLAY"
        ((IDX++))
    done

    echo "----------------------------------------------------"

    # Navigation
    local NAV=""
    [ "$OFFSET" -gt 0 ] && NAV="${NAV}  P) Previous page"
    [ "$END" -lt "$TOTAL_EXT" ] && NAV="${NAV}  N) Next page"
    [ -n "$NAV" ] && echo "$NAV"

    echo "  0) Back"
    echo "----------------------------------------------------"
    echo "  Enter number to toggle ON/OFF"
    echo ""
}

manage_extensions(){
    select_php_version || return

    local OFFSET=0
    local PAGE_SIZE=20

    while true; do
        show_extensions "$SELECTED_PHP" "$OFFSET"

        read -p "Select: " INPUT

        case "$INPUT" in
            0) return ;;
            [pP])
                OFFSET=$((OFFSET - PAGE_SIZE))
                [ "$OFFSET" -lt 0 ] && OFFSET=0
                continue
                ;;
            [nN])
                local MAX_OFFSET=$(( (TOTAL_EXT - 1) / PAGE_SIZE * PAGE_SIZE ))
                OFFSET=$((OFFSET + PAGE_SIZE))
                [ "$OFFSET" -gt "$MAX_OFFSET" ] && OFFSET=$MAX_OFFSET
                continue
                ;;
        esac

        # Validate number
        if ! [[ "$INPUT" =~ ^[0-9]+$ ]]; then
            warn "Invalid input"
            read -p "Press Enter..."
            continue
        fi

        local SEL=$((INPUT - 1))
        if [ "$SEL" -lt 0 ] || [ "$SEL" -ge "$TOTAL_EXT" ]; then
            warn "Out of range (1-$TOTAL_EXT)"
            read -p "Press Enter..."
            continue
        fi

        local ENTRY="${EXTENSIONS[$SEL]}"
        local DISPLAY=$(echo "$ENTRY" | cut -d'|' -f1)
        local MODULE=$(echo "$ENTRY" | cut -d'|' -f2)
        local PKG=$(echo "$ENTRY" | cut -d'|' -f3)
        local MODULE_LOWER=$(echo "$MODULE" | tr '[:upper:]' '[:lower:]')
        local BIN="/opt/remi/php${SELECTED_PHP}/root/usr/bin/php"

        # Check current state → toggle
        if "$BIN" -m 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -q "^${MODULE_LOWER}$"; then
            # Currently ON → disable
            disable_extension "$SELECTED_PHP" "$MODULE" "$PKG" "$DISPLAY"
        else
            # Currently OFF or not installed → enable (auto-install)
            enable_extension "$SELECTED_PHP" "$MODULE" "$PKG" "$DISPLAY"
        fi

        read -p "Press Enter..."
    done
}

# =================================================
# Quick bulk enable: install all common extensions
# =================================================

install_all_common(){
    select_php_version || return

    local VER_DOT="${SELECTED_PHP:0:1}.${SELECTED_PHP:1}"
    local COMMON_PKGS="php-fpm php-mysqlnd php-pgsql php-opcache php-gd php-curl php-zip php-cli php-mbstring php-xml php-intl php-bcmath php-pecl-imagick php-pecl-redis php-soap php-sodium php-exif php-fileinfo"

    echo ""
    echo "Installing all common extensions for PHP $VER_DOT..."
    echo ""

    for pkg in $COMMON_PKGS; do
        local FULL_PKG="php${SELECTED_PHP}-${pkg}"
        echo -n "  $pkg... "
        if rpm -q "$FULL_PKG" &>/dev/null 2>&1; then
            echo -e "${DIM}already installed${RESET}"
        else
            dnf install -y "$FULL_PKG" &>/dev/null
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}installed${RESET}"
            else
                echo -e "${YELLOW}skipped${RESET}"
            fi
        fi
    done

    systemctl restart "php${SELECTED_PHP}-php-fpm" 2>/dev/null
    ok "Done! PHP $VER_DOT FPM restarted"
}

# =================================================
# MENU
# =================================================

while true; do
    clear
    echo "===================================================="
    echo "          PHP EXTENSION MANAGER"
    echo "===================================================="
    echo ""
    echo "  1) Manage Extensions (toggle ON/OFF)"
    echo "  2) Install All Common Extensions"
    echo "  0) Back"
    echo "----------------------------------------------------"
    read -p "Select: " opt

    case "$opt" in
        1) manage_extensions ;;
        2) install_all_common ;;
        0) break ;;
        *) warn "Invalid option" ;;
    esac

    echo ""
    read -p "Press Enter..."
done
