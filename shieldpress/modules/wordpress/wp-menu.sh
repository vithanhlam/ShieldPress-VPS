#!/bin/bash

MODULE_DIR="/opt/shieldpress/modules/wordpress"
source "/opt/shieldpress/core/ui.sh"

while true; do
clear
sp_header "WordPress Manager" "Install, secure, optimize"
sp_menu_grid \
    "1|Install WordPress|green" \
    "2|Update WordPress|yellow" \
    "3|Security Hardening|red" \
    "4|Performance Optimize|green" \
    "5|Security + Optimize|magenta" \
    "6|Staging Tools|blue" \
    "7|WP-Cron to System Cron|cyan" \
    "8|Malware Scan|red" \
    "9|Reset Admin Password|yellow" \
    "10|Auto-Recovery (500 Fix)|green" \
    "0|Back|white"
sp_prompt choice

case $choice in
    1) bash $MODULE_DIR/install-wp.sh ;;
    2) bash $MODULE_DIR/update-wp.sh ;;
    3) bash $MODULE_DIR/secure-wp.sh ;;
    4) bash $MODULE_DIR/optimize-wp.sh ;;
    5) bash $MODULE_DIR/security-optimize-wp.sh ;;
    6) bash $MODULE_DIR/staging.sh ;;
    7) bash $MODULE_DIR/wp-cron-manager.sh ;;
    8) bash $MODULE_DIR/malware-scan.sh ;;
    9) bash $MODULE_DIR/reset-password.sh ;;
    10) bash $MODULE_DIR/wp-auto-recovery.sh ;;
    0) break ;;
    *) sp_invalid ;;
esac
done
