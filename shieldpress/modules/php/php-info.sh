#!/bin/bash

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
BOLD="\e[1m"
RESET="\e[0m"

ok(){ echo -e "${GREEN}[OK]${RESET} $1"; }
fail(){ echo -e "${RED}[FAIL]${RESET} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $1"; }

show_php_info(){
    local PHP_SHORT=$1
    local VER_DOT="${PHP_SHORT:0:1}.${PHP_SHORT:1}"
    local BIN="/opt/remi/php${PHP_SHORT}/root/usr/bin/php"
    local SVC="php${PHP_SHORT}-php-fpm"

    [ ! -x "$BIN" ] && { fail "PHP $VER_DOT not installed"; return; }

    echo ""
    echo -e "${BOLD}=====================================================${RESET}"
    echo -e "${BOLD}  PHP $VER_DOT Information${RESET}"
    echo -e "${BOLD}=====================================================${RESET}"
    echo ""

    # Version
    echo -e "${BOLD}Version:${RESET}"
    "$BIN" -v 2>/dev/null | sed 's/^/  /'
    echo ""

    # FPM Status
    echo -e "${BOLD}PHP-FPM Service:${RESET}"
    STATE=$(systemctl is-active "$SVC" 2>/dev/null)
    if [ "$STATE" = "active" ]; then
        echo -e "  Status  : ${GREEN}● Running${RESET}"
    else
        echo -e "  Status  : ${RED}● $STATE${RESET}"
    fi
    ENABLED=$(systemctl is-enabled "$SVC" 2>/dev/null)
    echo "  Boot    : $ENABLED"
    echo ""

    # Key PHP Settings
    echo -e "${BOLD}Key Settings:${RESET}"
    echo "----------------------------------------------------"

    declare -A SETTINGS
    SETTINGS=(
        ["memory_limit"]="Memory Limit"
        ["max_execution_time"]="Max Execution Time"
        ["max_input_time"]="Max Input Time"
        ["upload_max_filesize"]="Upload Max Filesize"
        ["post_max_size"]="Post Max Size"
        ["max_file_uploads"]="Max File Uploads"
        ["display_errors"]="Display Errors"
        ["error_reporting"]="Error Reporting"
        ["date.timezone"]="Timezone"
        ["session.gc_maxlifetime"]="Session Lifetime"
    )

    for key in memory_limit max_execution_time max_input_time upload_max_filesize post_max_size max_file_uploads display_errors date.timezone; do
        VALUE=$("$BIN" -r "echo ini_get('$key');" 2>/dev/null)
        LABEL="${SETTINGS[$key]:-$key}"
        printf "  %-25s : %s\n" "$LABEL" "$VALUE"
    done
    echo ""

    # OPcache
    echo -e "${BOLD}OPcache:${RESET}"
    echo "----------------------------------------------------"
    OPCACHE_ENABLED=$("$BIN" -r "echo ini_get('opcache.enable');" 2>/dev/null)
    if [ "$OPCACHE_ENABLED" = "1" ]; then
        echo -e "  Status          : ${GREEN}Enabled${RESET}"
        OPCACHE_MEM=$("$BIN" -r "echo ini_get('opcache.memory_consumption');" 2>/dev/null)
        OPCACHE_STRINGS=$("$BIN" -r "echo ini_get('opcache.interned_strings_buffer');" 2>/dev/null)
        OPCACHE_FILES=$("$BIN" -r "echo ini_get('opcache.max_accelerated_files');" 2>/dev/null)
        echo "  Memory          : ${OPCACHE_MEM}MB"
        echo "  String Buffer   : ${OPCACHE_STRINGS}MB"
        echo "  Max Files       : $OPCACHE_FILES"
    else
        echo -e "  Status          : ${RED}Disabled${RESET}"
    fi
    echo ""

    # JIT
    echo -e "${BOLD}JIT:${RESET}"
    echo "----------------------------------------------------"
    JIT=$("$BIN" -r "echo ini_get('opcache.jit');" 2>/dev/null)
    JIT_BUF=$("$BIN" -r "echo ini_get('opcache.jit_buffer_size');" 2>/dev/null)
    if [ -n "$JIT" ] && [ "$JIT" != "0" ] && [ "$JIT" != "off" ]; then
        echo -e "  Status      : ${GREEN}Enabled${RESET}"
        echo "  Mode        : $JIT"
        echo "  Buffer Size : $JIT_BUF"
    else
        echo -e "  Status      : ${YELLOW}Disabled${RESET}"
    fi
    echo ""

    # ionCube
    echo -e "${BOLD}ionCube:${RESET}"
    echo "----------------------------------------------------"
    if "$BIN" -m 2>/dev/null | grep -qi ioncube; then
        echo -e "  Status : ${GREEN}Loaded${RESET}"
    else
        echo -e "  Status : ${YELLOW}Not loaded${RESET}"
    fi
    echo ""

    # Pool files
    echo -e "${BOLD}FPM Pool Configs:${RESET}"
    echo "----------------------------------------------------"
    POOL_DIR="/etc/opt/remi/php${PHP_SHORT}/php-fpm.d"
    if [ -d "$POOL_DIR" ]; then
        for pool in "$POOL_DIR"/*.conf; do
            [ -f "$pool" ] || continue
            POOL_NAME=$(basename "$pool" .conf)
            echo "  - $POOL_NAME ($pool)"
        done
    fi
    echo ""

    # PHP ini location
    echo -e "${BOLD}Configuration Files:${RESET}"
    echo "----------------------------------------------------"
    echo "  php.ini      : /etc/opt/remi/php${PHP_SHORT}/php.ini"
    echo "  php-fpm.conf : /etc/opt/remi/php${PHP_SHORT}/php-fpm.conf"
    echo "  php.d/       : /etc/opt/remi/php${PHP_SHORT}/php.d/"
    echo "  Pool dir     : /etc/opt/remi/php${PHP_SHORT}/php-fpm.d/"
    echo ""
}

generate_phpinfo_html(){
    echo ""
    echo "Select PHP version for phpinfo() output:"

    PHP_INSTALLED=()
    INDEX=1
    declare -A MAP
    for php in 81 82 83 84; do
        BIN="/opt/remi/php${php}/root/usr/bin/php"
        if [ -x "$BIN" ]; then
            VER_DOT="${php:0:1}.${php:1}"
            echo "  $INDEX) PHP $VER_DOT"
            MAP[$INDEX]=$php
            PHP_INSTALLED+=("$php")
            ((INDEX++))
        fi
    done
    echo "  0) Cancel"
    read -p "Choose: " choice

    [ "$choice" = "0" ] && return
    TARGET="${MAP[$choice]}"
    [ -z "$TARGET" ] && { fail "Invalid"; return; }

    VER_DOT="${TARGET:0:1}.${TARGET:1}"
    BIN="/opt/remi/php${TARGET}/root/usr/bin/php"
    OUTPUT="/tmp/phpinfo_${TARGET}.html"

    "$BIN" -r "phpinfo();" > "$OUTPUT" 2>/dev/null

    if [ -f "$OUTPUT" ] && [ -s "$OUTPUT" ]; then
        ok "phpinfo() saved to: $OUTPUT"
        echo "  File size: $(du -h "$OUTPUT" | awk '{print $1}')"
        echo ""
        echo "  View in browser or use: less $OUTPUT"
    else
        fail "Failed to generate phpinfo"
    fi
}

while true; do
    clear
    echo "===================================================="
    echo "             PHP INFO VIEWER"
    echo "===================================================="
    echo ""

    INDEX=1
    declare -A PHP_MAP
    for php in 81 82 83 84; do
        BIN="/opt/remi/php${php}/root/usr/bin/php"
        if [ -x "$BIN" ]; then
            VER_DOT="${php:0:1}.${php:1}"
            STATE=$(systemctl is-active "php${php}-php-fpm" 2>/dev/null)
            if [ "$STATE" = "active" ]; then
                echo -e "  $INDEX) PHP $VER_DOT  ${GREEN}●${RESET}"
            else
                echo -e "  $INDEX) PHP $VER_DOT  ${RED}●${RESET}"
            fi
            PHP_MAP[$INDEX]=$php
            ((INDEX++))
        fi
    done

    echo ""
    echo "  H) Generate phpinfo() HTML"
    echo "  0) Back"
    echo "----------------------------------------------------"
    read -p "Select: " opt

    case "$opt" in
        [0-9])
            [ "$opt" = "0" ] && break
            TARGET="${PHP_MAP[$opt]}"
            [ -z "$TARGET" ] && { warn "Invalid"; read -p "Press Enter..."; continue; }
            show_php_info "$TARGET"
            ;;
        [hH])
            generate_phpinfo_html
            ;;
        *)
            warn "Invalid option"
            ;;
    esac

    echo ""
    read -p "Press Enter..."
done
