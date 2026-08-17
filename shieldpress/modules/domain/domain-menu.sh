#!/bin/bash

MODULE_DIR="/opt/shieldpress/modules/domain"
source "/opt/shieldpress/core/ui.sh"

while true; do
clear
sp_header "Domain Manager" "Provisioning and domain tools"
sp_menu_grid \
    "1|Add Domain|green" \
    "2|List Domains|cyan" \
    "3|Delete Domain|red" \
    "4|Change PHP Version|yellow" \
    "5|Domain Configuration|blue" \
    "6|Set Domain URL|magenta" \
    "7|Lock / Unlock Domain|yellow" \
    "8|Fix Domain Permissions|green" \
    "9|Domain Isolation|yellow" \
    "0|Back|white"
sp_prompt opt

case $opt in
    1) bash $MODULE_DIR/add-domain.sh ;;
    2) bash $MODULE_DIR/list-domain.sh ;;
    3) bash $MODULE_DIR/delete-domain.sh ;;
    4) bash $MODULE_DIR/change-php.sh ;;
    5) bash $MODULE_DIR/config-domain.sh ;;
    6) bash $MODULE_DIR/set-domain-url.sh ;;
    7) bash $MODULE_DIR/lock-domain.sh ;;
    8) bash $MODULE_DIR/fix-permission.sh ;;
    9) bash /opt/shieldpress/modules/isolation/isolation-menu.sh ;;
    0) break ;;
    *) sp_invalid ;;
esac

done
