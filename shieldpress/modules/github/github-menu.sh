#!/bin/bash
BASE_DIR=/opt/shieldpress
source "$BASE_DIR/core/ui.sh"
while true; do
    clear
    sp_header 'GitHub' 'Read-only deployment by domain'
    sp_menu_grid \
        '1|Configure SSH key / Connect|green' \
        '2|Pull domain updates|cyan' \
        '3|Show public key / Guide|blue' \
        '0|Back|white'
    sp_prompt choice || break
    case "$choice" in
        1) bash "$BASE_DIR/modules/github/github-deploy.sh" setup ;;
        2) bash "$BASE_DIR/modules/github/github-deploy.sh" pull ;;
        3) bash "$BASE_DIR/modules/github/github-deploy.sh" key ;;
        0) break ;;
        *) sp_invalid ;;
    esac
    read -r -p 'Press Enter to continue...' || break
done
