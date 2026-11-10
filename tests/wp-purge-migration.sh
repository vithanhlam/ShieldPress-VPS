#!/bin/bash
# Disposable TEST.MD VPS only. Verify an installed legacy plugin is refreshed.
set -euo pipefail
BASE_DIR=/opt/shieldpress
REPO=/tmp/sp-repo
DIR=${1:-ramfixtest_local}
MU=/home/domains/$DIR/public_html/wp-content/mu-plugins/shieldpress-cache-purge.php
PATCH_REGISTRY=$(mktemp /tmp/sp-purge-patches.XXXXXX)
trap 'rm -f "$PATCH_REGISTRY"' EXIT
mkdir -p "$(dirname "$MU")"
printf '<?php // Legacy purge plugin\n' > "$MU"
cp "$REPO/shieldpress/modules/cache/auto-purge.sh" "$BASE_DIR/modules/cache/"
cp "$REPO/shieldpress/templates/wp-mu-plugins/shieldpress-cache-purge.php" "$BASE_DIR/templates/wp-mu-plugins/"
# Load only registry helpers and this migration, without opening the menu.
eval "$(sed -n '/^patch_applied(){/,/^}/p;/^patch_mark_done(){/,/^}/p;/^patch_wp_purge_worker(){/,/^}/p' "$REPO/shieldpress/modules/patches/patches-menu.sh")"
ok(){ echo "[OK] $*"; }
fail(){ echo "[FAIL] $*" >&2; }
for run in 1 2; do
    patch_wp_purge_worker
    cmp "$MU" "$BASE_DIR/templates/wp-mu-plugins/shieldpress-cache-purge.php"
    grep -qx SP_20261110_WP_PURGE_WORKER "$PATCH_REGISTRY"
    [ ! -f /etc/sudoers.d/shieldpress-cache-purge ]
    systemctl is-active --quiet crond
    grep -q process-purge-signals /etc/cron.d/shieldpress-cache-purge
    echo "PASS: legacy plugin and missing worker migration (run $run)"
done
[ "$(grep -c SP_20261110_WP_PURGE_WORKER "$PATCH_REGISTRY")" = 1 ]
