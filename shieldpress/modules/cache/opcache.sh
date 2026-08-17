#!/bin/bash

PHP_VERSIONS=("81" "82" "83" "84")

while true; do
    clear
    echo "===================================================="
    echo "                OPCACHE MANAGER"
    echo "===================================================="
    echo "1) Clear OPcache (restart PHP-FPM)"
    echo "2) Enable OPcache"
    echo "3) Disable OPcache"
    echo "4) OPcache Status"
    echo "0) Back"
    echo "----------------------------------------------------"
    read -p "Select: " opt

    case $opt in
    1)
        echo "Clearing OPcache..."
        for v in "${PHP_VERSIONS[@]}"; do
            SVC="php${v}-php-fpm"
            systemctl list-unit-files 2>/dev/null | grep -q "$SVC" || continue
            systemctl restart "$SVC" 2>/dev/null && echo "[OK] php${v}-php-fpm restarted"
        done
        read -p "Press Enter..."
        ;;
    2)
        echo "Enabling OPcache..."
        for v in "${PHP_VERSIONS[@]}"; do
            CONF="/etc/opt/remi/php${v}/php.d/10-opcache.ini"
            [ -f "$CONF" ] || continue
            sed -i 's/^opcache\.enable=0/opcache.enable=1/' "$CONF"
            sed -i 's/^opcache\.enable_cli=0/opcache.enable_cli=1/' "$CONF"
            systemctl restart php${v}-php-fpm 2>/dev/null
            echo "[OK] OPcache enabled PHP${v}"
        done
        read -p "Press Enter..."
        ;;
    3)
        echo "Disabling OPcache..."
        for v in "${PHP_VERSIONS[@]}"; do
            CONF="/etc/opt/remi/php${v}/php.d/10-opcache.ini"
            [ -f "$CONF" ] || continue
            sed -i 's/^opcache\.enable=1/opcache.enable=0/' "$CONF"
            sed -i 's/^opcache\.enable_cli=1/opcache.enable_cli=0/' "$CONF"
            systemctl restart php${v}-php-fpm 2>/dev/null
            echo "[OK] OPcache disabled PHP${v}"
        done
        read -p "Press Enter..."
        ;;
    4)
        echo ""
        echo "OPcache Status"
        echo "--------------------------------"
        for v in "${PHP_VERSIONS[@]}"; do
            BIN="/opt/remi/php${v}/root/usr/bin/php"
            [ -x "$BIN" ] || continue
            if "$BIN" -i 2>/dev/null | grep -q "opcache.enable => On"; then
                echo "PHP${v} : ON"
            else
                echo "PHP${v} : OFF"
            fi
        done
        read -p "Press Enter..."
        ;;
    0) break ;;
    *) echo "Invalid option"; sleep 1 ;;
    esac
done
