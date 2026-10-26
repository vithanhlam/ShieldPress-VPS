#!/bin/bash
BASE_DIR="${BASE_DIR:-/opt/shieldpress}"
source "$BASE_DIR/modules/helpers/task-progress.sh"
TIMING_DIR="/var/shieldpress/data/runtime-policy-timing"
install -d -m 700 "$TIMING_DIR" || exit 1
echo "[INFO] Calculating shared PHP-FPM budget (usually a few seconds)..."
run_with_loading "PHP-FPM shared budget" "$TIMING_DIR/php-budget" 10 python3 "$BASE_DIR/modules/helpers/php-budget.py" --apply
status=$?
read -r -p "Press Enter..."
exit "$status"
