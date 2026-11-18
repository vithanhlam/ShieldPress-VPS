#!/bin/bash
# Disposable ShieldPress test server only (AlmaLinux 9 with sshd and journald).
# Run as root with the repository copied to /tmp/sp-repo:
#   bash /tmp/sp-repo/tests/ssh-access.sh
# Uses a throw-away local user and a private data directory. Covers: key
# create/add/revoke/restore/delete over a real SSH login, backups, the lockout
# guard, persistent login history (key fingerprint, wtmp import, idempotent
# collection) and command recording with secret masking.
set -uo pipefail
REPO=/tmp/sp-repo
MOD="$REPO/shieldpress/modules/security/ssh-access.sh"
[ "$EUID" -eq 0 ] && [ -f "$MOD" ] || { echo 'Requires root and the repository in /tmp/sp-repo.' >&2; exit 1; }
FAIL=0
pass(){ echo "[PASS] $1"; }
bad(){ echo "[FAIL] $1"; FAIL=1; }
U=spsshtest
WORK=$(mktemp -d /tmp/sp-ssh-test.XXXXXX)
export SA_DIR="$WORK/data" SA_BACKUP="$WORK/backups" IG_KEYS="$WORK/keys.list"
SA="bash $MOD"
SSHOPT=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o LogLevel=ERROR)
cleanup(){
    rm -f /etc/profile.d/zz-shieldpress-ssh-audit.sh
    systemctl disable --now sp-ssh-access.timer >/dev/null 2>&1; rm -f /etc/systemd/system/sp-ssh-access.{timer,service}; systemctl daemon-reload
    pkill -KILL -u "$U" 2>/dev/null; sleep 1; userdel -r "$U" >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT
userdel -r "$U" >/dev/null 2>&1; useradd -m -s /bin/bash "$U" && passwd -l "$U" >/dev/null 2>&1
echo "# seeded" > "$WORK/keys.list"
loginkey(){ ssh "${SSHOPT[@]}" -i "$1" "$U@127.0.0.1" "$2" 2>/dev/null; }

# 1. Create keys: restricted + working
$SA --create "$U" "restricted-test" "10.0.0.0/8" > "$WORK/k_from"
grep -q 'BEGIN OPENSSH PRIVATE KEY' "$WORK/k_from" && pass "create prints a private key" || bad "no private key printed"
AK="/home/$U/.ssh/authorized_keys"
grep -q '^from="10.0.0.0/8" ssh-ed25519 ' "$AK" && pass "from= restriction written" || bad "from= missing"
[ "$(stat -c '%a %U' "$AK")" = "600 $U" ] && [ "$(stat -c '%a %U' "/home/$U/.ssh")" = "700 $U" ] && pass "permissions and ownership correct" || bad "wrong permissions/ownership"
$SA --create "$U" "login-test" > "$WORK/k_ok"; chmod 600 "$WORK/k_ok" "$WORK/k_from"
ls /dev/shm/sp-key.* /tmp/sp-key.* >/dev/null 2>&1 && bad "private key left on disk" || pass "private key not left on the server"
grep -q "$U " "$WORK/keys.list" && pass "Intrusion Guard baseline updated" || bad "baseline not updated"
rows=$($SA --list --tsv | awk -F'\t' -v u="$U" '$2==u'); [ "$(echo "$rows" | wc -l)" = 2 ] && pass "list shows both keys" || bad "list count wrong"
ID_OK=$(echo "$rows" | awk -F'\t' '$10=="login-test"{print $1}'); FP_OK=$(echo "$rows" | awk -F'\t' '$10=="login-test"{print $8}')
out=$($SA --list); grep -q "$ID_OK" <<< "$out" && pass "pretty list prints the key id" || bad "pretty list missing id"

# 2. Real login with the key, persistent history
[ "$(loginkey "$WORK/k_ok" 'echo hello')" = hello ] && pass "SSH login works with the new key" || bad "SSH login failed"
loginkey "$WORK/k_from" 'echo hi' >/dev/null && bad "from= restricted key logged in from 127.0.0.1" || pass "from= restriction enforced"
sleep 1; $SA --collect
grep -q "$FP_OK" "$SA_DIR/logins.tsv" && pass "login recorded with key fingerprint" || bad "login not recorded"
awk -F'\t' -v u="$U" '$3==u && $6=="publickey" && $8=="journal"' "$SA_DIR/logins.tsv" | grep -q . && pass "method and source recorded" || bad "method/source wrong"
grep -q 'wtmp' "$SA_DIR/logins.tsv" && pass "existing wtmp history imported" || echo "[INFO] no wtmp entries to import on this server"
n1=$(wc -l < "$SA_DIR/logins.tsv"); $SA --collect; n2=$(wc -l < "$SA_DIR/logins.tsv")
[ "$n1" = "$n2" ] && pass "repeat collection adds no duplicates" || bad "duplicates after repeat collection ($n1 -> $n2)"
out=$($SA --history "$U" 5); grep -q "$U" <<< "$out" && pass "history view lists the login" || bad "history view empty"
out=$($SA --show "$ID_OK"); grep -q 'Recent logins with this key' <<< "$out" && pass "key details show last use" || bad "details missing last use"
[ "$(stat -c %a "$SA_DIR/logins.tsv")" = 600 ] && pass "history file is mode 600" || bad "history file mode"

# 3. Revoke / restore / delete
$SA --revoke "$ID_OK" >/dev/null; grep -q '^#REVOKED [0-9]* ssh-ed25519' "$AK" && pass "revoke comments the key out" || bad "revoke did not edit the file"
loginkey "$WORK/k_ok" 'echo hello' >/dev/null && bad "revoked key still logs in" || pass "revoked key is refused immediately"
ls "$SA_BACKUP" | grep -q . && pass "backup written before the change" || bad "no backup"
$SA --restore "$ID_OK" >/dev/null; [ "$(loginkey "$WORK/k_ok" 'echo hello')" = hello ] && pass "restored key works again" || bad "restore failed"
$SA --delete "$ID_OK" --force >/dev/null; grep -q "login-test" "$AK" && bad "delete left the key" || pass "delete removes the key line"
[ "$(grep -c 'restricted-test' "$AK")" = 1 ] && pass "other keys untouched by delete" || bad "delete removed the wrong key"
loginkey "$WORK/k_ok" 'echo hello' >/dev/null && bad "deleted key still logs in" || pass "deleted key is refused"

# 4. Add existing public key: validation and duplicates
$SA --add-pub "$U" "not a key" >/dev/null 2>&1 && bad "invalid key accepted" || pass "invalid public key rejected"
PUB=$(ssh-keygen -y -f "$WORK/k_from"); $SA --add-pub "$U" "$PUB" >/dev/null; rc=$?
[ "$rc" = 3 ] && pass "duplicate key is not added twice" || bad "duplicate handling rc=$rc"

# 5. Lockout guard (stubbed: passwords off, one active key left)
(
    source "$MOD"; sshd(){ echo "passwordauthentication no"; }
    sa_list_tsv(){ printf 'aaaa1111\tu\tf\t1\tactive\tED25519\t256\tSHA256:x\t-\tc\n'; }
    sa_lockout_risk aaaa1111 && exit 0 || exit 1
) && pass "lockout guard blocks removing the last key" || bad "lockout guard did not trigger"
(
    source "$MOD"; sshd(){ echo "passwordauthentication yes"; }
    sa_list_tsv(){ printf 'aaaa1111\tu\tf\t1\tactive\tED25519\t256\tSHA256:x\t-\tc\n'; }
    sa_lockout_risk aaaa1111 && exit 1 || exit 0
) && pass "guard allows removal while passwords are on" || bad "guard blocks needlessly"

# 6. Command recording with masking
$SA --enable-activity >/dev/null
[ -f /etc/profile.d/zz-shieldpress-ssh-audit.sh ] && pass "command recording hook installed" || bad "hook missing"
$SA --create "$U" "shell-test" > "$WORK/k_sh"; chmod 600 "$WORK/k_sh"
printf 'echo SP_MARKER_ONE\necho --password=hunter2 DB_PASSWORD=topsecret\ncd /tmp\nexit\n' \
    | ssh -tt "${SSHOPT[@]}" -i "$WORK/k_sh" "$U@127.0.0.1" >/dev/null 2>&1
sleep 2; $SA --collect
grep -q 'SP_MARKER_ONE' "$SA_DIR/commands.tsv" && pass "typed command recorded with user and source" || bad "command not recorded"
grep -q 'hunter2\|topsecret' "$SA_DIR/commands.tsv" && bad "secret stored in clear text" || pass "secrets masked in the stored log"
grep -q 'REDACTED' "$SA_DIR/commands.tsv" && pass "masking marker present" || bad "no masking marker"
out=$($SA --activity "$U" 10); grep -q 'SP_MARKER_ONE' <<< "$out" && pass "activity view shows the command" || bad "activity view empty"
$SA --disable-activity >/dev/null; [ ! -f /etc/profile.d/zz-shieldpress-ssh-audit.sh ] && pass "command recording disabled" || bad "hook not removed"

# 7. Timer lifecycle
$SA --enable-history >/dev/null; systemctl is-enabled --quiet sp-ssh-access.timer && pass "history timer enabled" || bad "timer not enabled"
$SA --enable-history >/dev/null; [ "$(systemctl list-unit-files sp-ssh-access.timer --no-legend | wc -l)" = 1 ] && pass "enable twice is idempotent" || bad "timer duplicated"
$SA --disable-history >/dev/null; systemctl is-enabled --quiet sp-ssh-access.timer 2>/dev/null && bad "timer still enabled" || pass "history timer disabled"

# 8. Migration from an older install: enabled once, idempotent, registry once
install -d /opt/shieldpress/modules/security
cp "$MOD" /opt/shieldpress/modules/security/ssh-access.sh
PATCH_REGISTRY="$WORK/patches.txt"; : > "$PATCH_REGISTRY"; BASE_DIR=/opt/shieldpress
eval "$(sed -n '/^patch_applied(){/,/^}/p;/^patch_mark_done(){/,/^}/p;/^patch_ssh_login_history(){/,/^}/p' "$REPO/shieldpress/modules/patches/patches-menu.sh")"
ok(){ echo "[OK] $*"; }
fail(){ echo "[FAIL] $*" >&2; }
rm -f /etc/systemd/system/sp-ssh-access.timer; systemctl daemon-reload
for run in 1 2; do
    patch_ssh_login_history && pass "migration run $run succeeded" || bad "migration run $run failed"
    systemctl is-enabled --quiet sp-ssh-access.timer && pass "run $run: history timer enabled" || bad "run $run: timer missing"
done
[ "$(grep -cx SP_20261118_SSH_LOGIN_HISTORY "$PATCH_REGISTRY")" = 1 ] && pass "patch registered once" || bad "registry entry count wrong"
[ -s "$SA_DIR/logins.tsv" ] && pass "history available right after migration" || bad "no history after migration"
rm -f /opt/shieldpress/modules/security/ssh-access.sh

[ "$FAIL" = 0 ] && echo "ALL PASSED" || { echo "FAILURES"; exit 1; }
