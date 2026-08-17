#!/bin/bash

BASE_DIR="/opt/shieldpress"
source "$BASE_DIR/core/paths.sh"
MODULE_DIR="$BASE_DIR/modules/optimize"
LOG_FILE="$LOG_DIR/optimize.log"
source "$BASE_DIR/core/ui.sh"
mkdir -p "$LOG_DIR"

log(){ echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"; }

while true; do
clear
sp_header "Optimization Center" "Performance tuning"
sp_menu_grid \
    "1|Fix Domain Permissions|yellow" \
    "2|Optimize Valkey/Redis|green" \
    "3|Full Auto Optimize|magenta" \
    "0|Back|white"
sp_prompt CHOICE

case $CHOICE in
    1)  bash "$MODULE_DIR/permission-fix.sh" ;;
    2)  bash "$MODULE_DIR/redis-optimize.sh" ;;
    3)
        log "FULL AUTO OPTIMIZE started"
        bash "$MODULE_DIR/php-optimize.sh"
        bash "$MODULE_DIR/nginx-optimize.sh"
        bash "$MODULE_DIR/php-jit.sh"
        bash "$MODULE_DIR/app-nginx-tune.sh"
        bash "$MODULE_DIR/permission-fix.sh"
        log "FULL AUTO OPTIMIZE completed"
        echo ""
        echo "============================"
        echo "FULL OPTIMIZATION COMPLETE!"
        echo "============================"
        read -p "Press Enter..."
        ;;
    0)  break ;;
    *)  sp_invalid ;;
esac
done
