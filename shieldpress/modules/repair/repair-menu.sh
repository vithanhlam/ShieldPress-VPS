#!/bin/bash

BASE_DIR="/opt/shieldpress"
MODULE_DIR="$BASE_DIR/modules/repair"
source "$BASE_DIR/core/ui.sh"

while true; do
    clear
    sp_header "Self-Healing & Repair" "Auto-repair, snapshots, integrity"
    sp_menu_grid \
        "1|System Integrity Check|green" \
        "2|Auto-Repair Daemon|cyan" \
        "3|Config Snapshots|blue" \
        "4|Emergency Restore|red" \
        "0|Back|white"
    sp_prompt choice

    case $choice in
        1) bash "$MODULE_DIR/system-integrity.sh" ;;
        2) bash "$MODULE_DIR/auto-repair.sh" ;;
        3) bash "$MODULE_DIR/config-snapshot.sh" ;;
        4) bash "$MODULE_DIR/emergency-restore.sh" ;;
        0) break ;;
        *) sp_invalid ;;
    esac
done
