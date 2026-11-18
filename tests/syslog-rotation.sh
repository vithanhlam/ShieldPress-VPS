#!/bin/bash
# Disposable ShieldPress test server only (AlmaLinux 9 with logrotate; fail2ban
# for the jail check). Run as root with the repository copied to /tmp/sp-repo:
#   bash /tmp/sp-repo/tests/syslog-rotation.sh
# Covers: the SP_20261118_SYSLOG_ROTATION migration on a server where the time
# rule never fires (oversized log is rotated by size, rerun changes nothing, an
# existing size rule is left alone, a rejected edit is rolled back) and the
# stricter Fail2ban SSH jail written by the menu (with rollback on error).
set -uo pipefail
REPO=/tmp/sp-repo
PATCHES="$REPO/shieldpress/modules/patches/patches-menu.sh"
MENU="$REPO/shieldpress/modules/security/security-menu.sh"
[ "$EUID" -eq 0 ] && [ -f "$PATCHES" ] || { echo 'Requires root and the repository in /tmp/sp-repo.' >&2; exit 1; }
FAIL=0
pass(){ echo "[PASS] $1"; }
bad(){ echo "[FAIL] $1"; FAIL=1; }
W=$(mktemp -d /tmp/sp-syslog.XXXXXX)
PATCH_REGISTRY="$W/patches.txt"; : > "$PATCH_REGISTRY"
export SP_LOGROTATE_RSYSLOG="$W/rsyslog.conf" SP_LOGROTATE_STATE="$W/state" DATA_DIR="$W/data"
JAIL=/etc/fail2ban/jail.d/sshd.conf
[ -f "$JAIL" ] && cp -a "$JAIL" "$W/jail.orig"
cleanup(){
    if [ -f "$W/jail.orig" ]; then cp -a "$W/jail.orig" "$JAIL"; else rm -f "$JAIL"; fi
    systemctl is-active --quiet fail2ban && fail2ban-client reload >/dev/null 2>&1
    rm -rf "$W"
}
trap cleanup EXIT

eval "$(sed -n '/^patch_applied(){/,/^}/p;/^patch_mark_done(){/,/^}/p;/^patch_syslog_rotation(){/,/^}/p' "$PATCHES")"
ok(){ echo "[OK] $*"; }; fail(){ echo "[FAIL] $*" >&2; }; skip(){ echo "[SKIP] $*"; }
run_with_loading(){ shift 3; "$@"; }

# 1. Broken legacy state: no size rule, no state, 150M log (like /var/log/secure)
mkdir -p "$W/log"
truncate -s 150M "$W/log/secure"; echo "tiny" > "$W/log/messages"
cat > "$SP_LOGROTATE_RSYSLOG" <<CONF
$W/log/secure
$W/log/messages
{
    weekly
    rotate 4
    dateext
    create 0600 root root
    missingok
    sharedscripts
    postrotate
        /bin/true
    endscript
}
CONF
logrotate -s "$SP_LOGROTATE_STATE" "$SP_LOGROTATE_RSYSLOG" >/dev/null 2>&1
ls "$W/log" | grep -q 'secure-' && bad "legacy config rotated without the fix" || pass "legacy config does not rotate the oversized log (bug reproduced)"
patch_syslog_rotation && pass "migration run 1 succeeded" || bad "migration run 1 failed"
grep -c '^[[:space:]]*maxsize 100M' "$SP_LOGROTATE_RSYSLOG" | grep -qx 1 && pass "one size rule added" || bad "size rule missing or duplicated"
ls "$W/log" | grep -q '^secure-' && pass "oversized log rotated immediately" || bad "oversized log not rotated"
[ "$(stat -c %s "$W/log/secure")" -lt 1000000 ] && pass "new log file is small" || bad "log still large"
[ -f "$W/log/messages" ] && ! ls "$W/log" | grep -q '^messages-' && pass "small log left alone" || bad "small log was rotated"
ls "$SP_LOGROTATE_RSYSLOG".bak_sp_* >/dev/null 2>&1 && pass "configuration backed up" || bad "no backup"
[ "$(grep -cx SP_20261118_SYSLOG_ROTATION "$PATCH_REGISTRY")" = 1 ] && pass "patch registered" || bad "registry entry wrong"
sum1=$(md5sum "$SP_LOGROTATE_RSYSLOG" | cut -d' ' -f1); n1=$(ls "$W/log" | wc -l)
patch_syslog_rotation && pass "migration run 2 succeeded" || bad "migration run 2 failed"
[ "$sum1" = "$(md5sum "$SP_LOGROTATE_RSYSLOG" | cut -d' ' -f1)" ] && [ "$n1" = "$(ls "$W/log" | wc -l)" ] && pass "repeat run changes nothing" || bad "repeat run changed files"
[ "$(grep -cx SP_20261118_SYSLOG_ROTATION "$PATCH_REGISTRY")" = 1 ] && pass "patch registered once" || bad "registry duplicated"

# 2. Existing size rule: left untouched
: > "$PATCH_REGISTRY"
printf '%s\n{\n    size 50M\n    rotate 2\n}\n' "$W/log/secure" > "$SP_LOGROTATE_RSYSLOG"; sum=$(md5sum "$SP_LOGROTATE_RSYSLOG" | cut -d' ' -f1)
patch_syslog_rotation >/dev/null && [ "$sum" = "$(md5sum "$SP_LOGROTATE_RSYSLOG" | cut -d' ' -f1)" ] && pass "existing size rule is not modified" || bad "existing rule modified"

# 3. Rejected edit is rolled back and stays pending
: > "$PATCH_REGISTRY"
printf '%s\n{\n    weekly\n    rotate notanumber\n}\n' "$W/log/secure" > "$SP_LOGROTATE_RSYSLOG"; sum=$(md5sum "$SP_LOGROTATE_RSYSLOG" | cut -d' ' -f1)
patch_syslog_rotation >/dev/null 2>&1 && bad "invalid configuration reported success" || pass "invalid configuration makes the migration fail"
[ "$sum" = "$(md5sum "$SP_LOGROTATE_RSYSLOG" | cut -d' ' -f1)" ] && pass "configuration restored after the failure" || bad "configuration not restored"
[ ! -s "$PATCH_REGISTRY" ] && pass "failed migration stays pending" || bad "failed migration marked done"

# 4. Missing configuration: nothing to repair, marked done
: > "$PATCH_REGISTRY"; rm -f "$SP_LOGROTATE_RSYSLOG"
patch_syslog_rotation >/dev/null && grep -qx SP_20261118_SYSLOG_ROTATION "$PATCH_REGISTRY" && pass "no rsyslog configuration: nothing to do" || bad "missing configuration mishandled"

# 5. Fail2ban SSH jail written by the menu
if command -v fail2ban-client >/dev/null 2>&1; then
    eval "$(sed -n '/^fail2ban_ssh(){/,/^}/p' "$MENU")"
    ensure_fail2ban(){ :; }; get_my_ssh_ip(){ echo 203.0.113.9; }; info(){ :; }
    out=$(fail2ban_ssh 2>&1)
    grep -q '^findtime = 1h' "$JAIL" && grep -q '^bantime.increment = true' "$JAIL" && grep -q '^mode     = aggressive' "$JAIL" && pass "stricter SSH jail written" || bad "jail settings wrong"
    grep -q '^ignoreip = .*203.0.113.9' "$JAIL" && pass "current SSH IP whitelisted" || bad "whitelist missing"
    systemctl is-active --quiet fail2ban && fail2ban-client status sshd >/dev/null 2>&1 && pass "sshd jail active" || bad "sshd jail not active: $out"
    echo '# previous-marker' >> "$JAIL"
    ( fail2ban-client(){ [ "$1" = "-t" ] && return 1; command fail2ban-client "$@"; }; fail2ban_ssh >/dev/null 2>&1 )
    grep -q '^# previous-marker' "$JAIL" && pass "rejected jail restored the previous file" || bad "rollback missing"
else
    echo "[INFO] fail2ban not installed; jail checks skipped"
fi

[ "$FAIL" = 0 ] && echo "ALL PASSED" || { echo "FAILURES"; exit 1; }
