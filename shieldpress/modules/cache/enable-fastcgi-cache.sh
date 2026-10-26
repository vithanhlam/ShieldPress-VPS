#!/bin/bash

source /opt/shieldpress/modules/wordpress/helpers.sh
select_domain || exit 1
source "$BASE_DIR/modules/helpers/task-progress.sh"
TIMING_DIR="/var/shieldpress/data/runtime-policy-timing"
install -d -m 700 "$TIMING_DIR" || exit 1
echo "[INFO] Enable WordPress cache for $SELECTED_DOMAIN (usually a few seconds)..."
run_with_loading "WordPress cache policy" "$TIMING_DIR/wordpress-cache" 10 python3 "$BASE_DIR/modules/helpers/wordpress-cache.py" --domain "$CLEAN_DOMAIN"
status=$?
read -r -p "Press Enter..."
exit "$status"
