#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/ui.sh"

while true; do
    clear
    sp_header "Domains & SSL" "Domain and certificate management"
    sp_menu_grid \
        "1|Domain Manager|green" \
        "2|SSL Manager|blue" \
        "0|Back|white"
    sp_prompt opt

    case "$opt" in
        1) bash "$BASE_DIR/modules/domain/domain-menu.sh" ;;
        2) bash "$BASE_DIR/modules/ssl/ssl-menu.sh" ;;
        0) break ;;
        *) sp_invalid ;;
    esac
done
