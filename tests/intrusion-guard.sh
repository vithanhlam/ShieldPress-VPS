#!/bin/bash
# Regression test for the Intrusion Guard log-event parser, alert filtering and
# the SSH option setter. Runs unprivileged: it sources the module up to its entry
# point, redirects all state to a temp directory and replaces the Telegram sender.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOD="$ROOT/shieldpress/modules/security/intrusion-guard.sh"
SEC="$ROOT/shieldpress/modules/security/security-menu.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; FAIL=1; }

sed '/^# Entry/,$d' "$MOD" > "$TMP/lib.sh"

export LOG_DIR="$TMP/log" DATA_DIR="$TMP/data" ETC_DIR="$TMP/etc" BASE_DIR="$TMP/none"
# shellcheck disable=SC1091
source "$TMP/lib.sh"
load_ig_conf
OUT="$TMP/out"
tg_send() { printf '=== %s\n%s\n' "$1" "$2" >> "$OUT"; }

# Baseline that contains only the current user
save_baseline
ME="$(id -un)"

: > "$OUT"
watch_handle_line "Accepted publickey for $ME from 203.0.113.9 port 51234 ssh2: ED25519 SHA256:abcDEF123"
grep -q "Source IP: 203.0.113.9" "$OUT" && grep -q "NEW IP" "$OUT" \
    && pass "known user from a new IP is reported with source details" || fail "known user login alert"

: > "$OUT"
watch_handle_line "Accepted password for systemctl from 79.124.56.242 port 4000 ssh2"
grep -q "UNKNOWN USER" "$OUT" && grep -q "PASSWORD" "$OUT" \
    && pass "unknown user password login flagged" || fail "unknown user login alert"

: > "$OUT"
watch_handle_line "pam_unix(login:session): session opened for user systemctl(uid=1036) by LOGIN(uid=0)"
grep -q "CONSOLE login" "$OUT" \
    && pass "console login flagged" || fail "console login alert"

: > "$OUT"
LOGIN_ALERT_ALL=0
watch_handle_line "Accepted publickey for $ME from 203.0.113.9 port 51235 ssh2"
[ ! -s "$OUT" ] && pass "LOGIN_ALERT_ALL=0 silences a known user from a known IP" || fail "login filter"
LOGIN_ALERT_ALL=1

: > "$OUT"
watch_handle_line "new user: name=evil, UID=1037, GID=1037, home=/home/evil, shell=/bin/bash"
grep -q "NEW USER CREATED" "$OUT" && pass "useradd reported" || fail "useradd alert"

: > "$OUT"
watch_handle_line "add 'evil' to group 'wheel'"
grep -q "privileged group" "$OUT" && pass "wheel membership change reported" || fail "group alert"

: > "$OUT"
watch_handle_line "$ME : TTY=pts/0 ; PWD=/root ; USER=root ; COMMAND=/usr/sbin/useradd evil"
grep -q "Dir  : /root" "$OUT" && grep -q "useradd evil" "$OUT" \
    && pass "sensitive sudo command reported" || fail "sudo alert"

: > "$OUT"
watch_handle_line "$ME : TTY=pts/0 ; PWD=/root ; USER=root ; COMMAND=/usr/bin/ls"
[ ! -s "$OUT" ] && pass "harmless sudo from a known user is not reported" || fail "sudo noise"

# SSH option setter
SSHD_CONF="$TMP/sshd_config"
sed -n '/^_ssh_set_opt(){/,/^}/p' "$SEC" > "$TMP/setopt.sh"
# shellcheck disable=SC1091
source "$TMP/setopt.sh"
printf '#PermitRootLogin prohibit-password\nPasswordAuthentication yes\n' > "$SSHD_CONF"
_ssh_set_opt PermitRootLogin yes
_ssh_set_opt PasswordAuthentication no
if grep -qx 'PermitRootLogin yes' "$SSHD_CONF" && grep -qx 'PasswordAuthentication no' "$SSHD_CONF" \
    && [ "$(grep -c PermitRootLogin "$SSHD_CONF")" = 1 ]; then
    pass "SSH option setter updates commented and active options once"
else
    fail "SSH option setter"
fi

# Scan runs and writes a state flag without privileges
run_checks
report >/dev/null 2>&1
[ -s "$IG_FLAG" ] && pass "scan completes and writes the alert flag" || fail "scan flag"

# English-only guard for the new module
if grep -nP '[ăâđêôơưạảấầẩẫậắằẳẵặẹẻẽếềểễệỉịọỏốồổỗộớờởỡợụủứừửữựỳỵỷỹ]' "$MOD" >/dev/null; then
    fail "intrusion-guard.sh contains non-English text"
else
    pass "intrusion-guard.sh is English only"
fi

exit "$FAIL"
