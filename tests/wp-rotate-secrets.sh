#!/bin/bash
# Disposable ShieldPress test server only (AlmaLinux 9, one WordPress domain
# with MariaDB). Run as root with the repository copied to /tmp/sp-repo:
#   bash /tmp/sp-repo/tests/wp-rotate-secrets.sh [domain_dir] [domain]
# Covers WordPress Manager > Change DB Password / Salt Keys: DB password only,
# salts only, both, wp-config.php syntax/permissions, domain.env sync, MariaDB
# login with the new password, and rollback when wp-config.php cannot be edited.
set -uo pipefail
REPO=/tmp/sp-repo
DIR="${1:-ramfixtest_local}"; DOM="${2:-ramfixtest.local}"
BASE=/opt/shieldpress
D="/home/domains/$DIR"; WPC="$D/public_html/wp-config.php"; ENVF="$D/config/domain.env"
[ "$EUID" -eq 0 ] && [ -f "$WPC" ] && [ -f "$REPO/shieldpress/modules/wordpress/rotate-secrets.sh" ] || {
    echo 'Requires root, the repository in /tmp/sp-repo and an existing WordPress test domain.' >&2; exit 1; }
FAIL=0
pass(){ echo "[PASS] $1"; }
bad(){ echo "[FAIL] $1"; FAIL=1; }
cp "$REPO/shieldpress/modules/wordpress/rotate-secrets.sh" "$BASE/modules/wordpress/"
cp "$REPO/shieldpress/modules/wordpress/wp-menu.sh" "$BASE/modules/wordpress/"
grep -q 'rotate-secrets.sh' "$BASE/modules/wordpress/wp-menu.sh" && pass "menu entry wired" || bad "menu entry missing"

choose_domain(){  # print the list index of the test domain
    local i=1 d
    for d in /home/domains/*; do
        [ -f "$d/config/domain.env" ] || continue
        [ -n "$(grep '^DOMAIN=' "$d/config/domain.env" | cut -d= -f2)" ] || continue
        [ "$d" = "$D" ] && { echo "$i"; return; }
        i=$((i+1))
    done
}
IDX=$(choose_domain)
run(){ printf '%s\ny\n%s\ny\n\n' "$IDX" "$1" | bash "$BASE/modules/wordpress/rotate-secrets.sh" >/tmp/rotate.out 2>&1; }
const(){ php -r 'define("ABSPATH","/");$c=file_get_contents($argv[1]);preg_match("/define\(\s*\x27".$argv[2]."\x27\s*,\s*\x27((?:[^\x27\\\\]|\\\\.)*)\x27/",$c,$m);echo $m[1]??"";' "$WPC" "$1"; }

DBU=$(grep '^DB_USER=' "$ENVF" | cut -d= -f2); DBN=$(grep '^DB_NAME=' "$ENVF" | cut -d= -f2)
cp -p "$WPC" /tmp/wpc.orig; cp -p "$ENVF" /tmp/env.orig
OLD_PASS=$(const DB_PASSWORD); OLD_KEY=$(const AUTH_KEY)

# 1. DB password only
run 1
NEW_PASS=$(const DB_PASSWORD)
[ -n "$NEW_PASS" ] && [ "$NEW_PASS" != "$OLD_PASS" ] && pass "wp-config DB_PASSWORD changed" || { bad "wp-config DB_PASSWORD unchanged"; cat /tmp/rotate.out; }
[ "$(const AUTH_KEY)" = "$OLD_KEY" ] && pass "salts untouched by DB-only run" || bad "salts changed by DB-only run"
[ "$(grep '^DB_PASS=' "$ENVF" | cut -d= -f2)" = "$NEW_PASS" ] && pass "domain.env synced" || bad "domain.env not synced"
mysql -u"$DBU" -p"$NEW_PASS" -e "USE \`$DBN\`;" 2>/dev/null && pass "MariaDB accepts the new password" || bad "MariaDB login failed"
mysql -u"$DBU" -p"$OLD_PASS" -e "USE \`$DBN\`;" 2>/dev/null && bad "old password still works" || pass "old password rejected"
php -l "$WPC" >/dev/null && pass "wp-config.php syntax valid" || bad "wp-config.php syntax error"
[ "$(stat -c %a "$WPC")" = 600 ] && pass "wp-config.php mode 600" || bad "wp-config.php mode $(stat -c %a "$WPC")"
[ "$(stat -c %U "$WPC")" = "$DIR" ] && pass "wp-config.php owner kept" || bad "wp-config.php owner $(stat -c %U "$WPC")"
ls "$D"/public_html/wp-config.php.bak_* >/dev/null 2>&1 && pass "backup created" || bad "no backup"

# 2. Salts only
run 2
[ "$(const AUTH_KEY)" != "$OLD_KEY" ] && [ -n "$(const NONCE_SALT)" ] && pass "salts regenerated" || bad "salts not regenerated"
[ "$(const DB_PASSWORD)" = "$NEW_PASS" ] && pass "DB password untouched by salts-only run" || bad "DB password changed by salts-only run"
php -l "$WPC" >/dev/null && pass "syntax valid after salts" || bad "syntax error after salts"
[ "$(grep -cE "^define\( *'(AUTH_KEY|SECURE_AUTH_KEY|LOGGED_IN_KEY|NONCE_KEY|AUTH_SALT|SECURE_AUTH_SALT|LOGGED_IN_SALT|NONCE_SALT)'" "$WPC")" = 8 ] && pass "exactly 8 salt constants" || bad "salt constant count wrong"

# 3. Both, plus missing constants get appended
sed -i "/'NONCE_SALT'/d" "$WPC"
P2=$NEW_PASS; run 3
[ "$(const DB_PASSWORD)" != "$P2" ] && [ -n "$(const NONCE_SALT)" ] && pass "both rotated, missing salt re-added" || bad "option 3 failed"
mysql -u"$DBU" -p"$(const DB_PASSWORD)" -e "USE \`$DBN\`;" 2>/dev/null && pass "login works after option 3" || bad "login failed after option 3"

# 4. Rollback: wp-config.php without any insertion point and DB constant
cp -p "$WPC" /tmp/wpc.good; P3=$(const DB_PASSWORD)
printf "<?php\n// broken\n" > "$WPC"
run 1
[ "$(cat "$WPC")" = "$(printf '<?php\n// broken\n')" ] && pass "wp-config.php restored after failure" || bad "wp-config.php not restored"
mysql -u"$DBU" -p"$P3" -e "USE \`$DBN\`;" 2>/dev/null && pass "MariaDB password rolled back" || bad "MariaDB password not rolled back"
[ "$(grep '^DB_PASS=' "$ENVF" | cut -d= -f2)" = "$P3" ] && pass "domain.env unchanged after failure" || bad "domain.env changed after failure"

# Cleanup: restore a working site state
cp -p /tmp/wpc.good "$WPC"; rm -f "$D"/public_html/wp-config.php.bak_*
echo "Result: $([ $FAIL -eq 0 ] && echo PASS || echo FAIL)"; exit $FAIL
