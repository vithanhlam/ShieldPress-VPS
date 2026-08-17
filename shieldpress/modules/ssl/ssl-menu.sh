#!/bin/bash

BASE_DIR="/opt/shieldpress"
MODULE_DIR="$BASE_DIR/modules/ssl"
DOMAINS_ROOT="/home/domains"
source "$BASE_DIR/core/ui.sh"

DOMAIN_FOLDERS=()

select_domain(){
    DOMAIN_FOLDERS=()
    echo ""
    echo "Available Domains:"
    echo "--------------------------------"

    local i=1
    for d in "$DOMAINS_ROOT"/*/; do
        [ -d "$d" ] || continue
        [ -f "$d/config/domain.env" ] || continue
        local DNAME
        DNAME=$(grep "^DOMAIN=" "$d/config/domain.env" | cut -d'=' -f2 | tr -d '[:space:]')
        [ -z "$DNAME" ] && continue
        echo "  $i) $DNAME"
        DOMAIN_FOLDERS[$i]=$(basename "$d")
        ((i++))
    done

    echo "--------------------------------"
    read -p "Select domain: " CHOICE
    local FOLDER="${DOMAIN_FOLDERS[$CHOICE]}"

    if [ -z "$FOLDER" ]; then
        echo "Invalid selection"
        return 1
    fi

    DOMAIN_PATH="$DOMAINS_ROOT/$FOLDER"
    return 0
}

while true; do
    clear
    sp_header "SSL Manager" "Certificates and HTTPS"
    sp_menu_grid \
        "1|Install Free SSL (Let's Encrypt)|green" \
        "2|Install Free SSL (ZeroSSL)|green" \
        "3|Install Custom SSL (Paid)|blue" \
        "4|Install Cloudflare Origin SSL|yellow" \
        "5|Renew SSL|yellow" \
        "6|Remove SSL|red" \
        "7|Check SSL Status|cyan" \
        "8|Auto SSL (Wildcard)|blue" \
        "0|Back|white"
    sp_prompt opt

    case $opt in
        1)
            bash "$MODULE_DIR/install-ssl.sh"
            read -p "Press Enter..."
            ;;
        2)
            bash "$MODULE_DIR/install-ssl-zerossl.sh"
            read -p "Press Enter..."
            ;;
        3)
            select_domain || continue
            bash "$MODULE_DIR/install-ssl-custom.sh" "$DOMAIN_PATH"
            read -p "Press Enter..."
            ;;
        4)
            select_domain || continue
            bash "$MODULE_DIR/install-ssl-cloudflare.sh" "$DOMAIN_PATH"
            read -p "Press Enter..."
            ;;
        5)
            select_domain || continue
            bash "$MODULE_DIR/renew-ssl.sh" "$DOMAIN_PATH"
            read -p "Press Enter..."
            ;;
        6)
            select_domain || continue
            bash "$MODULE_DIR/remove-ssl.sh" "$DOMAIN_PATH"
            read -p "Press Enter..."
            ;;
        7)
            bash "$MODULE_DIR/check-ssl-status.sh"
            read -p "Press Enter..."
            ;;
        8)
            bash "$MODULE_DIR/auto-ssl.sh"
            ;;
        0) break ;;
        *) sp_invalid ;;
    esac
done
