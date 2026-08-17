#!/bin/bash

MODULE_DIR="/opt/shieldpress/modules/cache"
source "/opt/shieldpress/core/ui.sh"

while true; do
    clear
    sp_header "Cache Manager" "Valkey/Redis & Object Cache"
    sp_menu_grid \
        "1|Valkey Server Manager|blue" \
        "2|Optimize Valkey/Redis|green" \
        "3|WP Object Cache|green" \
        "4|Cache Hit Ratio|cyan" \
        "5|Purge Domain Cache|yellow" \
        "6|Warmup Domain Cache|cyan" \
        "7|Clear All Cache|red" \
        "8|Smart Cache Status|cyan" \
        "9|Auto Purge (mu-plugin)|green" \
        "10|Remove Valkey|red" \
        "0|Back|white"
    sp_prompt choice

    case $choice in
        1)  bash "$MODULE_DIR/valkey-server.sh" ;;
        2)  bash "/opt/shieldpress/modules/optimize/redis-optimize.sh" ;;
        3)  bash "$MODULE_DIR/wp-valkey.sh" ;;
        4)  bash "$MODULE_DIR/cache-hit.sh" ;;
        5)  bash "$MODULE_DIR/purge-domain-cache.sh" ;;
        6)  bash "$MODULE_DIR/warmup-cache.sh" ;;
        7)  bash "$MODULE_DIR/clear-all-cache.sh" ;;
        8)  bash "$MODULE_DIR/cache-status.sh" ;;
        9)  bash "$MODULE_DIR/auto-purge.sh" ;;
        10) bash "$MODULE_DIR/remove-cache-engine.sh" ;;
        0)  break ;;
        *)  sp_invalid ;;
    esac
done
