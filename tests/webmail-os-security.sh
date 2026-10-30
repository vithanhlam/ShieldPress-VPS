#!/bin/bash
# Disposable AlmaLinux 9 only. Run with the repository mounted at /repo:
#   docker run --rm -v "$PWD":/repo:ro almalinux:9 bash /repo/tests/webmail-os-security.sh
# Covers Roundcube in-place updates (same branch, repeat, checksum refusal,
# failed-update restore) and the security-only OS update step with Valkey.
set -uo pipefail
if [ ! -f /.dockerenv ] || [ ! -f /etc/almalinux-release ] || [ ! -d /repo/shieldpress ]; then
    echo 'Requires a disposable AlmaLinux container and a /repo mount.' >&2
    exit 1
fi
FAIL=0
pass(){ echo "[PASS] $1"; }
bad(){ echo "[FAIL] $1"; FAIL=1; }

dnf module enable -y -q php:8.2 >/dev/null 2>&1
dnf install -y -q php-cli php-intl php-mbstring php-pdo php-xml rsync sqlite tar >/dev/null 2>&1 || { echo 'prep failed'; exit 1; }
useradd -r nginx 2>/dev/null
mkdir -p /opt/shieldpress /var/shieldpress/logs /var/shieldpress/data
cp -a /repo/shieldpress/. /opt/shieldpress/
UPDATE=/opt/shieldpress/modules/email/update-webmail.sh

seed_roundcube(){
    rm -rf /var/www/webmail /tmp/seed && mkdir -p /tmp/seed /var/www/webmail
    curl -fsSL "https://github.com/roundcube/roundcubemail/releases/download/$1/roundcubemail-$1-complete.tar.gz" | tar -xz -C /tmp/seed
    cp -a "/tmp/seed/roundcubemail-$1/." /var/www/webmail/
    mkdir -p /var/www/webmail/db
    cat > /var/www/webmail/config/config.inc.php <<'CONF'
<?php
$config = [];
$config['db_dsnw'] = 'sqlite:////var/www/webmail/db/roundcube.db?mode=0640';
$config['des_key'] = 'fixture-des-key-000000000';
$config['plugins'] = ['archive', 'zipdownload'];
CONF
    sqlite3 /var/www/webmail/db/roundcube.db < /var/www/webmail/SQL/sqlite.initial.sql
    rm -rf /var/www/webmail/installer
}
rc_ver(){ grep -oE "RCMAIL_VERSION', '[0-9.]+" /var/www/webmail/program/include/iniset.php | grep -oE '[0-9.]+$'; }

# 1. Same-branch auto update keeps config and DB, removes installer
seed_roundcube 1.7.3
bash "$UPDATE" --auto >/tmp/u1.log 2>&1 && [ "$(rc_ver)" = 1.7.5 ] && pass "auto update 1.7.3 -> 1.7.5" || { bad "auto update 1.7.3"; cat /tmp/u1.log; }
grep -q fixture-des-key /var/www/webmail/config/config.inc.php && pass "config preserved" || bad "config lost"
[ "$(stat -c %a /var/www/webmail/db/roundcube.db)" = 640 ] && pass "db permissions 640" || bad "db permissions"
[ ! -e /var/www/webmail/installer ] && pass "installer absent" || bad "installer present"

# 2. Repeat execution is a no-op
bash "$UPDATE" --auto 2>&1 | grep -q "up to date" && pass "repeat run is idempotent" || bad "repeat run"

# 3. Auto mode never crosses branches
seed_roundcube 1.6.18
bash "$UPDATE" --auto >/tmp/u3.log 2>&1
case "$(rc_ver)" in 1.6.*) rc_security_ver=$(rc_ver); pass "1.6 stays on branch ($rc_security_ver)" ;; *) bad "branch crossed: $(rc_ver)"; cat /tmp/u3.log ;; esac

# 4. Failed update restores the previous version
seed_roundcube 1.7.3
mkdir -p /tmp/badphp && printf '#!/bin/sh\nexit 3\n' > /tmp/badphp/php && chmod +x /tmp/badphp/php
PATH=/tmp/badphp:$PATH bash "$UPDATE" --auto >/tmp/u4.log 2>&1
[ $? -ne 0 ] && [ "$(rc_ver)" = 1.7.3 ] && grep -q restored /tmp/u4.log && pass "failed update restored 1.7.3" || { bad "restore"; cat /tmp/u4.log; }

# 5. Checksum mismatch is refused
out=$(bash -c 'source /opt/shieldpress/modules/email/helpers.sh; RC_VERSION=1.7.5; RC_SHA256=$(printf "0%.0s" {1..64}); t=$(mktemp -d); rc_fetch_release "$t"' 2>&1)
[ $? -ne 0 ] && echo "$out" | grep -q "checksum mismatch" && pass "checksum mismatch refused" || bad "checksum not enforced"

# 6. OS security step: apply, repeat, opt-out
dnf install -y -q valkey >/dev/null 2>&1 || { dnf install -y -q epel-release >/dev/null 2>&1; dnf install -y -q valkey >/dev/null 2>&1; }
rpm -q valkey >/dev/null && pass "valkey fixture installed ($(rpm -q valkey))" || bad "valkey install"
before_nginx_excluded=$(grep -c "exclude='nginx'" /opt/shieldpress/modules/security/os-security-patch.sh)
[ "$before_nginx_excluded" -ge 1 ] && pass "managed stacks excluded" || bad "excludes missing"
bash /opt/shieldpress/modules/security/os-security-patch.sh --apply >/tmp/o1.log 2>&1 && pass "OS security apply" || { bad "OS security apply"; cat /tmp/o1.log; }
bash /opt/shieldpress/modules/security/os-security-patch.sh --apply >/tmp/o2.log 2>&1 && pass "OS security repeat" || { bad "OS security repeat"; cat /tmp/o2.log; }
bash /opt/shieldpress/modules/security/os-security-patch.sh --audit >/dev/null 2>&1 && pass "no advisories pending after apply" || bad "advisories still pending"
sed -i 's/^OS_SECURITY_AUTO_UPDATE=.*/OS_SECURITY_AUTO_UPDATE="no"/' /opt/shieldpress/config/upgrade-policy.conf
bash /opt/shieldpress/modules/security/os-security-patch.sh --apply 2>&1 | grep -q "disabled by upgrade policy" && pass "policy opt-out" || bad "policy opt-out"

[ "$FAIL" -eq 0 ] && echo "All webmail/OS security checks passed." || { echo "Some checks failed."; exit 1; }
