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

ALL_VERSIONS=("81" "82" "83" "84")

# Standard extensions to install with each PHP version
PHP_EXTENSIONS="php-fpm php-mysqlnd php-pgsql php-opcache php-gd php-curl php-zip php-cli php-mbstring php-xml php-intl php-bcmath php-pecl-imagick php-soap php-ldap php-pecl-redis"

show_status(){
    echo ""
    echo "===================================================="
    echo "           PHP VERSION STATUS"
    echo "===================================================="
    echo ""

    for php in "${ALL_VERSIONS[@]}"; do
        VER_DOT="${php:0:1}.${php:1}"
        BIN="/opt/remi/php${php}/root/usr/bin/php"
        SVC="php${php}-php-fpm"

        if [ -x "$BIN" ]; then
            FULL_VER=$("$BIN" -v 2>/dev/null | head -1 | awk '{print $2}')
            STATE=$(systemctl is-active "$SVC" 2>/dev/null)

            if [ "$STATE" = "active" ]; then
                echo -e "  ${GREEN}●${RESET} PHP ${VER_DOT} ($FULL_VER) - FPM: ${GREEN}running${RESET}"
            else
                echo -e "  ${YELLOW}●${RESET} PHP ${VER_DOT} ($FULL_VER) - FPM: ${YELLOW}${STATE}${RESET}"
            fi

            # Count domains using this version
            DOMAIN_COUNT=0
            for d in /home/domains/*/config/domain.env; do
                [ -f "$d" ] || continue
                DPHP=$(grep "^PHP_VERSION=" "$d" 2>/dev/null | cut -d= -f2 | tr -d '[:space:].')
                [ "$DPHP" = "$php" ] && ((DOMAIN_COUNT++))
            done
            echo "    Domains using: $DOMAIN_COUNT"
        else
            echo -e "  ${RED}✗${RESET} PHP ${VER_DOT} - Not installed"
        fi
    done

    echo ""

    # Show default CLI PHP
    DEFAULT_PHP=$(php -v 2>/dev/null | head -1 | awk '{print $2}')
    [ -n "$DEFAULT_PHP" ] && echo "  Default CLI PHP: $DEFAULT_PHP"

    echo ""
}

install_version(){
    echo ""
    echo "===================================================="
    echo "         INSTALL PHP VERSION"
    echo "===================================================="
    echo ""

    # Show versions not installed
    NOT_INSTALLED=()
    INDEX=1
    declare -A INSTALL_MAP

    for php in "${ALL_VERSIONS[@]}"; do
        VER_DOT="${php:0:1}.${php:1}"
        BIN="/opt/remi/php${php}/root/usr/bin/php"
        if [ ! -x "$BIN" ]; then
            echo "$INDEX) PHP $VER_DOT"
            INSTALL_MAP[$INDEX]=$php
            NOT_INSTALLED+=("$php")
            ((INDEX++))
        fi
    done

    if [ ${#NOT_INSTALLED[@]} -eq 0 ]; then
        ok "All PHP versions (8.1-8.4) are already installed"
        return
    fi

    echo "0) Cancel"
    echo ""
    read -p "Select version to install: " CHOICE

    [ "$CHOICE" = "0" ] && return

    TARGET="${INSTALL_MAP[$CHOICE]}"
    [ -z "$TARGET" ] && { fail "Invalid selection"; return; }

    VER_DOT="${TARGET:0:1}.${TARGET:1}"

    echo ""
    echo "Installing PHP $VER_DOT with standard extensions..."
    echo ""

    # Ensure Remi repo is available
    if ! dnf repolist 2>/dev/null | grep -q "remi"; then
        warn "Remi repository not found, installing..."
        dnf install -y https://rpms.remirepo.net/enterprise/remi-release-$(rpm -E %{rhel}).rpm 2>/dev/null || {
            fail "Failed to install Remi repo"
            return
        }
    fi

    # Build package list
    PACKAGES=""
    for ext in $PHP_EXTENSIONS; do
        PACKAGES="$PACKAGES php${TARGET}-${ext}"
    done

    # Install
    dnf install -y $PACKAGES 2>&1 | tail -5

    if [ $? -eq 0 ] && [ -x "/opt/remi/php${TARGET}/root/usr/bin/php" ]; then
        ok "PHP $VER_DOT installed"

        # Configure FPM
        PHP_SOCKET="/var/opt/remi/php${TARGET}/run/php-fpm/www.sock"
        mkdir -p "$(dirname $PHP_SOCKET)"

        # Start and enable
        systemctl enable "php${TARGET}-php-fpm" 2>/dev/null
        systemctl start "php${TARGET}-php-fpm" 2>/dev/null && \
            ok "php${TARGET}-php-fpm started" || \
            warn "php${TARGET}-php-fpm start failed"
    else
        fail "PHP $VER_DOT installation failed"
    fi
}

remove_version(){
    echo ""
    echo "===================================================="
    echo "         REMOVE PHP VERSION"
    echo "===================================================="
    echo ""

    INSTALLED=()
    INDEX=1
    declare -A REMOVE_MAP

    for php in "${ALL_VERSIONS[@]}"; do
        VER_DOT="${php:0:1}.${php:1}"
        BIN="/opt/remi/php${php}/root/usr/bin/php"
        if [ -x "$BIN" ]; then
            # Count domains
            DOMAIN_COUNT=0
            for d in /home/domains/*/config/domain.env; do
                [ -f "$d" ] || continue
                DPHP=$(grep "^PHP_VERSION=" "$d" 2>/dev/null | cut -d= -f2 | tr -d '[:space:].')
                [ "$DPHP" = "$php" ] && ((DOMAIN_COUNT++))
            done
            echo "$INDEX) PHP $VER_DOT ($DOMAIN_COUNT domains using)"
            REMOVE_MAP[$INDEX]=$php
            INSTALLED+=("$php")
            ((INDEX++))
        fi
    done

    if [ ${#INSTALLED[@]} -eq 0 ]; then
        warn "No PHP versions installed"
        return
    fi

    echo "0) Cancel"
    echo ""
    read -p "Select version to remove: " CHOICE

    [ "$CHOICE" = "0" ] && return

    TARGET="${REMOVE_MAP[$CHOICE]}"
    [ -z "$TARGET" ] && { fail "Invalid selection"; return; }

    VER_DOT="${TARGET:0:1}.${TARGET:1}"

    # Check if domains are using this version
    DOMAIN_COUNT=0
    DOMAIN_LIST=""
    for d in /home/domains/*/config/domain.env; do
        [ -f "$d" ] || continue
        DPHP=$(grep "^PHP_VERSION=" "$d" 2>/dev/null | cut -d= -f2 | tr -d '[:space:].')
        if [ "$DPHP" = "$TARGET" ]; then
            ((DOMAIN_COUNT++))
            DN=$(grep "^DOMAIN=" "$d" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
            DOMAIN_LIST="$DOMAIN_LIST  - $DN\n"
        fi
    done

    if [ "$DOMAIN_COUNT" -gt 0 ]; then
        echo ""
        warn "$DOMAIN_COUNT domain(s) are using PHP $VER_DOT:"
        echo -e "$DOMAIN_LIST"
        fail "Switch these domains to another PHP version first!"
        return
    fi

    # Check we're not removing the last version
    INSTALLED_COUNT=${#INSTALLED[@]}
    if [ "$INSTALLED_COUNT" -le 1 ]; then
        fail "Cannot remove the last installed PHP version!"
        return
    fi

    echo ""
    read -p "Remove PHP $VER_DOT and all its packages? (y/n): " confirm
    [[ "$confirm" =~ ^[yY]$ ]] || { warn "Cancelled"; return; }

    echo ""
    echo "Stopping PHP $VER_DOT FPM..."
    systemctl stop "php${TARGET}-php-fpm" 2>/dev/null
    systemctl disable "php${TARGET}-php-fpm" 2>/dev/null

    echo "Removing packages..."
    dnf remove -y "php${TARGET}-*" 2>&1 | tail -5

    if [ ! -x "/opt/remi/php${TARGET}/root/usr/bin/php" ]; then
        ok "PHP $VER_DOT removed"
    else
        warn "Some PHP $VER_DOT packages may remain"
    fi
}

while true; do
    clear
    echo "===================================================="
    echo "          PHP VERSION MANAGER"
    echo "===================================================="
    echo ""
    echo "1) Show Status"
    echo "2) Install PHP Version"
    echo "3) Remove PHP Version"
    echo "0) Back"
    echo "----------------------------------------------------"
    read -p "Select: " opt

    case "$opt" in
        1) show_status ;;
        2) install_version ;;
        3) remove_version ;;
        0) break ;;
        *) warn "Invalid option" ;;
    esac

    echo ""
    read -p "Press Enter..."
done
