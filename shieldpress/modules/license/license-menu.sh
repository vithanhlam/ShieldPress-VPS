#!/bin/bash

source /opt/shieldpress/modules/license/license-core.sh
source /opt/shieldpress/core/ui.sh

while true; do
clear
sp_header "License Manager" "Activation status"

if check_license_local; then
    echo -e "  ${SP_GREEN}[ OK ]${SP_RESET} Status : ACTIVE"
else
    echo -e "  ${SP_RED}[FAIL]${SP_RESET} Status : NOT ACTIVE"
fi

echo ""
sp_menu_grid \
    "1|Activate License|green" \
    "2|Remove License|red" \
    "0|Back|white"

sp_prompt CHOICE

case $CHOICE in
    1) activate_license ;;
    2) deactivate_license ;;
    0) break ;;
    *) sp_invalid ;;
esac

read -p "Press Enter..."
done
