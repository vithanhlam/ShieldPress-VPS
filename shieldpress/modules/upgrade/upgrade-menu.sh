#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
MODULE_DIR="$BASE_DIR/modules/upgrade"
source "$BASE_DIR/core/ui.sh"

while true; do
    clear
    sp_header "Upgrade Manager" "Controlled software upgrades"
    sp_menu_grid \
        "1|Upgrade Nginx|green" \
        "2|Upgrade PHP|green" \
        "3|Upgrade MariaDB|yellow" \
        "4|Upgrade PostgreSQL|yellow" \
        "5|Upgrade Node.js|green" \
        "6|Package Lock Manager|blue" \
        "7|View Upgrade Policy|cyan" \
        "8|View Upgrade Log|magenta" \
        "0|Back|white"
    sp_prompt choice

    case $choice in
        1) bash "$MODULE_DIR/upgrade-nginx.sh" ;;
        2) bash "$MODULE_DIR/upgrade-php.sh" ;;
        3) bash "$MODULE_DIR/upgrade-mariadb.sh" ;;
        4) bash "$MODULE_DIR/upgrade-postgresql.sh" ;;
        5) bash "$MODULE_DIR/upgrade-nodejs.sh" ;;
        6) bash "$MODULE_DIR/package-lock.sh" ;;
        7)
            clear
            echo "===================================================="
            echo "          UPGRADE POLICY"
            echo "===================================================="
            echo ""
            cat "$BASE_DIR/config/upgrade-policy.conf" 2>/dev/null | sed 's/^/  /'
            echo ""
            read -p "Press Enter..."
            ;;
        8)
            clear
            echo "===================================================="
            echo "          UPGRADE LOG"
            echo "===================================================="
            echo ""
            if [ -f "$LOG_DIR/upgrade.log" ]; then
                tail -50 "$LOG_DIR/upgrade.log" | sed 's/^/  /'
            else
                echo "  No upgrade log yet"
            fi
            echo ""
            read -p "Press Enter..."
            ;;
        0) break ;;
        *) sp_invalid ;;
    esac
done
