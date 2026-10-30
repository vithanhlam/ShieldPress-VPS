#!/bin/bash
# Disposable ShieldPress test server only (AlmaLinux 9, nginx + PHP-FPM, one
# WordPress domain with FastCGI cache). Run as root with the repository copied
# to /tmp/sp-repo:
#   bash /tmp/sp-repo/tests/wp-cache-recovery.sh [domain_dir] [domain] [php_short]
# Covers: error page served from FastCGI cache while PHP is healthy, PHP-FPM
# restart after a 502 purging cache, and the old-version-to-new-version
# migration (idempotent).
set -uo pipefail
REPO=/tmp/sp-repo
DIR="${1:-ramfixtest_local}"; DOM="${2:-ramfixtest.local}"; PHP="${3:-84}"
[ "$EUID" -eq 0 ] && [ -f "$REPO/shieldpress/version.txt" ] && [ -d "/home/domains/$DIR/public_html" ] || {
    echo 'Requires root, the repository in /tmp/sp-repo and an existing WordPress test domain.' >&2; exit 1; }
FAIL=0
pass(){ echo "[PASS] $1"; }
bad(){ echo "[FAIL] $1"; FAIL=1; }
DOCROOT="/home/domains/$DIR/public_html"
CACHE="/var/cache/nginx/$DIR"
BASE=/opt/shieldpress
SVC="php${PHP}-php-fpm"
cleanup(){
    rm -f "$DOCROOT/index.php" "$DOCROOT/.fail" "$BASE/bin/php-auto-reload"
    sed -i '/#sp-test/d' /etc/hosts
    crontab -l 2>/dev/null | grep -v SHIELDPRESS_PHP_AUTO_RELOAD | crontab - 2>/dev/null
    systemctl start "$SVC" shieldpress-wp-recovery 2>/dev/null
}
trap cleanup EXIT
fetch(){ curl -s -D- "http://$DOM/${1:-}"; }

cp "$REPO/shieldpress/modules/wordpress/wp-auto-recovery.sh" "$BASE/modules/wordpress/"
cp "$REPO/shieldpress/modules/tools/auto-reload-php.sh" "$BASE/modules/tools/"
echo "127.0.0.1 $DOM #sp-test" >> /etc/hosts
systemctl stop shieldpress-wp-recovery 2>/dev/null
cat > "$DOCROOT/index.php" <<'PHP'
<?php
if (file_exists(__DIR__.'/.fail')) { echo '<html><body><p>There has been a critical error on this website.</p></body></html>'; }
else { echo '<html><body><h1>Site OK</h1></body></html>'; }
PHP
chown "$DIR:$DIR" "$DOCROOT/index.php"

# 1. Error page cached, PHP healthy again: the scan purges only this cache
find "$CACHE" -type f -delete
touch "$DOCROOT/.fail"; fetch >/dev/null; fetch | grep -qi 'X-Cache: HIT' && pass "error page served from cache" || bad "error page not cached"
rm -f "$DOCROOT/.fail"
fetch | grep -q 'critical error' && pass "stale error persists without the fix" || bad "stale state not reproduced"
bash "$BASE/modules/wordpress/wp-auto-recovery.sh" --scan | grep -q "stale error in cache" && pass "scan detects stale error cache" || bad "scan missed stale cache"
out=$(fetch); echo "$out" | grep -q 'Site OK' && echo "$out" | grep -qi 'X-Cache: MISS' && pass "visitor gets a fresh page after purge" || bad "page still stale"
bash "$BASE/modules/wordpress/wp-auto-recovery.sh" --scan | grep -q "stale error in cache" && bad "healthy cached page flagged" || pass "healthy cached page left alone"

# 2. PHP-FPM down (502), auto-reload restarts it and purges cache
BIN=$BASE/bin; SCRIPT_FILE=$BIN/php-auto-reload
eval "$(sed -n '/^install_checker/,/^}/p' "$BASE/modules/tools/auto-reload-php.sh")"; install_checker
fetch >/dev/null
systemctl stop "$SVC"
[ "$(curl -s -o /dev/null -w '%{http_code}' "http://$DOM/?x=$RANDOM")" = 502 ] && pass "502 reproduced" || bad "502 not reproduced"
"$SCRIPT_FILE"; sleep 1
systemctl is-active --quiet "$SVC" && pass "PHP-FPM restarted" || bad "PHP-FPM not restarted"
[ "$(find "$CACHE" -type f | wc -l)" -eq 0 ] && pass "cache purged after restart" || bad "cache kept after restart"

# 3. Migration from the previous release: old checker, pending patch id
printf '#!/bin/bash\n# old checker\n' > "$SCRIPT_FILE"
(crontab -l 2>/dev/null; echo "*/2 * * * * $SCRIPT_FILE >/dev/null 2>&1 # SHIELDPRESS_PHP_AUTO_RELOAD") | crontab -
REG=/tmp/sp-patches-applied.txt
: > "$REG"
# Run only this patch from the newly installed migration code; the full chain
# needs a complete current install.
run_patch(){
    bash -c "BASE_DIR=$BASE; PATCH_REGISTRY=$REG
        ok(){ :; }; fail(){ echo FAIL \"\$1\"; }
        $(sed -n '/^patch_applied(){/,/^}/p;/^patch_mark_done(){/,/^}/p' "$REPO/shieldpress/modules/patches/patches-menu.sh")
        $(sed -n '/^patch_wp_cache_recovery(){/,/^}/p' "$REPO/shieldpress/modules/patches/patches-menu.sh")
        patch_wp_cache_recovery"
}
for run in 1 2; do
    run_patch >/tmp/sp-patch.log 2>&1
    grep -qxF SP_20261030_WP_CACHE_RECOVERY "$REG" && pass "migration registered (run $run)" || { bad "migration pending (run $run)"; tail -5 /tmp/sp-patch.log; }
    grep -q 'FastCGI cache purged' "$SCRIPT_FILE" && pass "checker refreshed (run $run)" || bad "old checker kept (run $run)"
done
crontab -l | grep -c SHIELDPRESS_PHP_AUTO_RELOAD | grep -qx 1 && pass "single cron entry after repeat" || bad "cron entry duplicated or lost"
# A disabled auto-reload must stay disabled
crontab -l | grep -v SHIELDPRESS_PHP_AUTO_RELOAD | crontab -; rm -f "$SCRIPT_FILE"
: > "$REG"
run_patch >/dev/null 2>&1
[ ! -e "$SCRIPT_FILE" ] && ! crontab -l 2>/dev/null | grep -q SHIELDPRESS_PHP_AUTO_RELOAD && pass "disabled auto-reload stays disabled" || bad "migration enabled a disabled auto-reload"

[ $FAIL -eq 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
