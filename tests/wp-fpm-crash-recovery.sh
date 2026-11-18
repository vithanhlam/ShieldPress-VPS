#!/bin/bash
# Disposable ShieldPress test server only (AlmaLinux 9, nginx + PHP-FPM, one
# WordPress test domain). Run as root with the repository copied to /tmp/sp-repo:
#   bash /tmp/sp-repo/tests/wp-fpm-crash-recovery.sh [domain_dir] [domain] [php_short]
# Covers: a PHP-FPM worker crash loop (workers SIGKILLed, HTTP 502 while the
# service and socket stay healthy) is repaired by a restart, the restart is
# rate limited, and the JIT-off migration is idempotent from an old install.
set -uo pipefail
REPO=/tmp/sp-repo
DIR="${1:-ramfixtest_local}"; DOM="${2:-ramfixtest.local}"; PHP="${3:-84}"
[ "$EUID" -eq 0 ] && [ -f "$REPO/shieldpress/version.txt" ] && [ -d "/home/domains/$DIR/public_html" ] || {
    echo 'Requires root, the repository in /tmp/sp-repo and an existing WordPress test domain.' >&2; exit 1; }
FAIL=0
pass(){ echo "[PASS] $1"; }
bad(){ echo "[FAIL] $1"; FAIL=1; }
DOCROOT="/home/domains/$DIR/public_html"
BASE=/opt/shieldpress
SVC="php${PHP}-php-fpm"
FPM_LOG="/var/opt/remi/php${PHP}/log/php-fpm/error.log"
COOLDOWN=/tmp/shieldpress_recovery
STAMP="$COOLDOWN/.fpm_restart"
REMI_INI="/etc/opt/remi/php${PHP}/php.d/10-opcache.ini"
SRC_INI=$(ls /opt/shieldpress-php/*/etc/php.d/10-opcache.ini 2>/dev/null | head -1)
BACKUP=$(mktemp -d /tmp/sp-fpm-crash.XXXXXX)
PATCH_REGISTRY=$(mktemp /tmp/sp-fpm-crash-patches.XXXXXX)

for f in "$REMI_INI" "$SRC_INI"; do [ -n "$f" ] && [ -f "$f" ] && cp -a "$f" "$BACKUP/$(echo "$f" | tr / _)"; done
cp -a "$BASE/modules/wordpress/wp-auto-recovery.sh" "$BACKUP/wp-auto-recovery.sh.orig"
[ -f "$DOCROOT/index.php" ] && cp -a "$DOCROOT/index.php" "$BACKUP/index.php.orig"

cleanup(){
    rm -f "$DOCROOT/.crash" "$PATCH_REGISTRY" "$STAMP" "$COOLDOWN/$DOM"
    if [ -f "$BACKUP/index.php.orig" ]; then cp -a "$BACKUP/index.php.orig" "$DOCROOT/index.php"; else rm -f "$DOCROOT/index.php"; fi
    for f in "$REMI_INI" "$SRC_INI"; do [ -n "$f" ] && [ -f "$BACKUP/$(echo "$f" | tr / _)" ] && cp -a "$BACKUP/$(echo "$f" | tr / _)" "$f"; done
    sed -i '/#sp-test/d' /etc/hosts
    systemctl restart "$SVC" shieldpress-wp-recovery 2>/dev/null
    rm -rf "$BACKUP"
}
trap cleanup EXIT

http(){ curl -s -o /dev/null -w '%{http_code}' "http://$DOM/?sp=$RANDOM$RANDOM"; }
fpm_pid(){ systemctl show -p MainPID --value "$SVC"; }
crash_count(){ grep -F "[pool $DIR]" "$FPM_LOG" | grep -c 'exited with code 137\|exited on signal'; }
recovery_log(){ tail -n "${1:-40}" /var/shieldpress/logs/wp-auto-recovery.log; }

cp "$REPO/shieldpress/modules/wordpress/wp-auto-recovery.sh" "$BASE/modules/wordpress/"
echo "127.0.0.1 $DOM #sp-test" >> /etc/hosts
systemctl stop shieldpress-wp-recovery 2>/dev/null
mkdir -p "$COOLDOWN"; rm -f "$STAMP" "$COOLDOWN/$DOM"
cat > "$DOCROOT/index.php" <<'PHP'
<?php
if (file_exists(__DIR__.'/.crash')) { posix_kill(getmypid(), 9); }
echo '<html><body><h1>Site OK</h1></body></html>';
PHP
chown "$DIR:$DIR" "$DOCROOT/index.php"
systemctl restart "$SVC"; sleep 2
[ "$(http)" = 200 ] && pass "baseline site is healthy" || bad "baseline site is not healthy"

# 1. Worker crash loop: service and socket stay healthy, requests return 502.
touch "$DOCROOT/.crash"
before=$(crash_count)
for i in 1 2 3; do http >/dev/null; done
sleep 1
after=$(crash_count)
[ "$((after - before))" -ge 3 ] && pass "workers were SIGKILLed ($((after - before)) crashes logged)" || bad "crash loop not reproduced"
systemctl is-active --quiet "$SVC" && pass "PHP-FPM service stays active during the crash loop" || bad "service is not active"
[ "$(http)" = 502 ] && pass "crash loop returns HTTP 502" || bad "HTTP 502 not reproduced"

# The old behavior only reported "healthy; restart skipped". The new daemon
# restarts PHP-FPM once, which rebuilds the OPcache shared memory.
rm -f "$DOCROOT/.crash" "$COOLDOWN/$DOM" "$STAMP"
touch "$DOCROOT/.crash"; for i in 1 2 3; do http >/dev/null; done
pid_before=$(fpm_pid)
bash "$BASE/modules/wordpress/wp-auto-recovery.sh" --scan >/tmp/sp-fpm-crash-scan1.log 2>&1
rm -f "$DOCROOT/.crash"
sleep 2
pid_after=$(fpm_pid)
[ "$pid_before" != "$pid_after" ] && pass "crash loop triggered a PHP-FPM restart" || bad "PHP-FPM was not restarted (see /tmp/sp-fpm-crash-scan1.log)"
recovery_log 60 | grep -q 'Pool workers crashing; restarting PHP-FPM\|Pool workers crashing' && pass "restart reason logged" || bad "restart reason missing from the recovery log"
[ -f "$STAMP" ] && pass "restart rate-limit stamp written" || bad "restart stamp missing"
[ "$(http)" = 200 ] && pass "site serves HTTP 200 after the restart" || bad "site still failing"

# 2. Rate limit: a second crash loop right away must not restart FPM again.
touch "$DOCROOT/.crash"; rm -f "$COOLDOWN/$DOM"
for i in 1 2 3; do http >/dev/null; done
pid_before=$(fpm_pid)
bash "$BASE/modules/wordpress/wp-auto-recovery.sh" --scan >/tmp/sp-fpm-crash-scan2.log 2>&1
pid_after=$(fpm_pid)
[ "$pid_before" = "$pid_after" ] && pass "second restart within 10 minutes is blocked" || bad "rate limit did not hold"
recovery_log 60 | grep -q 'skipping' && pass "rate-limit skip logged" || bad "skip message missing"
rm -f "$DOCROOT/.crash" "$COOLDOWN/$DOM" "$STAMP"
systemctl restart "$SVC"; sleep 2

# 3. Unrelated pool crashes must not trigger a restart for this domain.
eval "$(sed -n '/^pool_workers_crashing(){/,/^}/p' "$REPO/shieldpress/modules/wordpress/wp-auto-recovery.sh")"
domain_to_clean(){ echo "$1" | tr '.-' '__'; }
FPM_CRASH_WINDOW_MIN=3; FPM_CRASH_THRESHOLD=3
T=$(mktemp); now=$(LC_ALL=C date '+%d-%b-%Y %H:%M:%S')
for i in 1 2 3; do echo "[$now] WARNING: [pool other_pool] child $i exited with code 137 after 0.05 seconds from start" >> "$T"; done
pool_workers_crashing "$DOM" "$T" && bad "other pool's crashes flagged" || pass "other pool's crashes ignored"
old=$(LC_ALL=C date -d '30 minutes ago' '+%d-%b-%Y %H:%M:%S')
for i in 1 2 3; do echo "[$old] WARNING: [pool $DIR] child $i exited with code 137 after 0.05 seconds from start" > "$T"; done
pool_workers_crashing "$DOM" "$T" && bad "old crashes flagged" || pass "crashes older than the window ignored"
rm -f "$T"

# 4. Migration from an old install: JIT on -> off, idempotent, registry once.
for f in "$REMI_INI" "$SRC_INI"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    sed -i '/^opcache\.jit=/d;/^opcache\.jit_buffer_size=/d' "$f"
    printf 'opcache.jit_buffer_size=128M\nopcache.jit=1255\n' >> "$f"
done
cp "$REPO/shieldpress/modules/wordpress/wp-auto-recovery.sh" "$BASE/modules/wordpress/"
eval "$(sed -n '/^patch_applied(){/,/^}/p;/^patch_mark_done(){/,/^}/p;/^patch_php_jit_off_fpm_crash_recovery(){/,/^}/p' "$REPO/shieldpress/modules/patches/patches-menu.sh")"
ok(){ echo "[OK] $*"; }
fail(){ echo "[FAIL] $*" >&2; }
systemctl start shieldpress-wp-recovery
pid_first=""
for run in 1 2; do
    patch_php_jit_off_fpm_crash_recovery && pass "migration run $run succeeded" || bad "migration run $run failed"
    for f in "$REMI_INI" "$SRC_INI"; do
        [ -n "$f" ] && [ -f "$f" ] || continue
        [ "$(grep -c '^opcache\.jit=0$' "$f")" = 1 ] && [ "$(grep -c '^opcache\.jit_buffer_size=0$' "$f")" = 1 ] \
            && pass "run $run: JIT off, no duplicate lines in $f" || bad "run $run: JIT lines wrong in $f"
    done
    if [ "$run" = 1 ]; then pid_first=$(fpm_pid); fi
done
[ "$(fpm_pid)" = "$pid_first" ] && pass "repeat migration did not restart PHP-FPM" || bad "repeat migration restarted PHP-FPM"
[ "$(grep -cx SP_20261118_PHP_JIT_OFF_FPM_CRASH_RECOVERY "$PATCH_REGISTRY")" = 1 ] && pass "patch registered once" || bad "registry entry count wrong"
systemctl is-active --quiet shieldpress-wp-recovery && pass "recovery daemon running after migration" || bad "recovery daemon not running"
PFX=$(dirname "$(dirname "$(dirname "$SRC_INI")")")
php_jit=$(PHP_INI_SCAN_DIR="$PFX/etc/php.d" "$PFX/bin/php" -c "$PFX/etc/php.ini" -r 'echo ini_get("opcache.jit");' 2>/dev/null)
[ "$php_jit" = 0 ] && pass "effective opcache.jit is 0" || bad "effective opcache.jit is '$php_jit'"
[ "$(http)" = 200 ] && pass "site healthy after migration" || bad "site unhealthy after migration"

[ "$FAIL" = 0 ] && echo "ALL PASSED" || { echo "FAILURES"; exit 1; }
