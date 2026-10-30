#!/bin/bash
# Disposable AlmaLinux 9 only. Run with the repository mounted at /repo:
#   docker run --rm -v "$PWD":/repo:ro almalinux:9 bash /repo/tests/bootstrap-install.sh
# Covers the piped bootstrap (curl ... | bash): root and sudo re-execution,
# the server stack prompt on a terminal, unattended answers and no-tty runs.
# The full stack install itself is not run here (needs systemd).
set -uo pipefail
if [ ! -f /.dockerenv ] || [ ! -f /etc/almalinux-release ] || [ ! -f /repo/install.sh ]; then
    echo 'Requires a disposable AlmaLinux container and a /repo mount.' >&2
    exit 1
fi
FAIL=0
pass(){ echo "[PASS] $1"; }
bad(){ echo "[FAIL] $1"; FAIL=1; }
dnf install -y -q rsync sudo util-linux procps-ng >/dev/null 2>&1 || { echo 'prep failed'; exit 1; }
cp /repo/install.sh /tmp/bootstrap.sh
reset_install(){ rm -rf /opt/shieldpress /etc/shieldpress /usr/bin/shieldpress; }

# 1. Piped as root, no terminal: installs toolkit, skips stack with guidance
reset_install
out=$(setsid bash -c 'cat /tmp/bootstrap.sh | bash' </dev/null 2>&1); rc=$?
[ $rc -eq 0 ] && [ -x /opt/shieldpress/shieldpress.sh ] && pass "piped root install (no tty)" || { bad "piped root install rc=$rc"; echo "$out" | tail -20; }
echo "$out" | grep -q "Install Stack" && pass "no-tty run explains how to install the stack" || bad "no stack guidance"
echo "$out" | grep -q "\[PROGRESS\] Downloading ShieldPress" && pass "download stage reported" || bad "no download stage"
[ "$(stat -c %U /opt/shieldpress/shieldpress.sh)" = root ] && pass "installed code owned by root" || bad "ownership"

# 2. Piped on a terminal, answer "n" to the stack prompt
reset_install
out=$(printf 'n\n' | script -qec 'cat /tmp/bootstrap.sh | bash' /dev/null 2>&1); rc=$?
echo "$out" | grep -q "Install the server stack now?" && pass "stack prompt shown on terminal while piped" || { bad "no prompt"; echo "$out" | tail -20; }
echo "$out" | grep -q "Server stack not installed yet" && [ $rc -eq 0 ] && pass "answer n skips the stack" || bad "answer n rc=$rc"

# 3. Stack already installed: no prompt
mkdir -p /etc/shieldpress && touch /etc/shieldpress/.stack_installed
out=$(printf 'n\n' | script -qec 'cat /tmp/bootstrap.sh | bash' /dev/null 2>&1)
echo "$out" | grep -q "already installed" && ! echo "$out" | grep -q "Install the server stack now?" && pass "existing stack is not reinstalled" || bad "existing stack prompt"
rm -f /etc/shieldpress/.stack_installed

# 4. Unattended answer "no" via environment on the bash side of the pipe
reset_install
out=$(printf '' | script -qec 'cat /tmp/bootstrap.sh | SHIELDPRESS_INSTALL_STACK=no bash' /dev/null 2>&1)
! echo "$out" | grep -q "Install the server stack now?" && echo "$out" | grep -q "not installed yet" && pass "SHIELDPRESS_INSTALL_STACK=no skips prompt" || bad "env answer"

# 5. Piped as a non-root sudo user: re-runs as root
reset_install
useradd -m tester 2>/dev/null; echo 'tester ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/tester
out=$(setsid su tester -c 'cat /tmp/bootstrap.sh | SHIELDPRESS_INSTALL_STACK=no bash' </dev/null 2>&1); rc=$?
echo "$out" | grep -q "Re-running the installer with sudo" && [ $rc -eq 0 ] && [ -x /opt/shieldpress/shieldpress.sh ] && pass "piped non-root run re-executes with sudo" || { bad "sudo re-exec rc=$rc"; echo "$out" | tail -20; }

# 6. Non-root without sudo: clear error
reset_install
rm -f /etc/sudoers.d/tester; mv /usr/bin/sudo /usr/bin/sudo.off
out=$(setsid su tester -c 'cat /tmp/bootstrap.sh | bash' </dev/null 2>&1); rc=$?
mv /usr/bin/sudo.off /usr/bin/sudo
[ $rc -ne 0 ] && echo "$out" | grep -q "Root is required" && pass "no sudo: clear root error" || bad "no sudo rc=$rc"

[ "$FAIL" -eq 0 ] && echo "All bootstrap checks passed." || { echo "Some checks failed."; exit 1; }
