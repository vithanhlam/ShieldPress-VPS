#!/bin/bash
# Source fallback for the PHP 8.4 security release. Existing branches stay intact.
set -euo pipefail
version=8.4.27
prefix=/opt/shieldpress-php/$version
state=/var/shieldpress/data/php-source-84
vendor=/opt/remi/php84/root/usr
base=/opt/shieldpress
mkdir -p "$state"
chmod 700 "$state"
exec 8>"$state/lock"
flock -n 8 || { echo '[FAIL] PHP 8.4 source patch already running'; exit 1; }
[ "$EUID" -eq 0 ] || { echo '[FAIL] Root is required'; exit 1; }
[ -x "$vendor/bin/php" ] || { echo '[INFO] PHP 8.4 is not installed'; exit 0; }

current=$("$vendor/bin/php" -r 'echo PHP_VERSION;')
if [ "$current" != "$version" ] && [ "$(printf '%s\n' "$version" "$current" | sort -V | head -1)" = "$version" ]; then
    echo "[FAIL] PHP $current is newer than this source fallback; refusing to downgrade. Review the source override before returning to vendor packages."
    exit 1
fi

# Only this same-branch fallback is currently supported and validated.
if [ ! -x "$prefix/bin/php" ]; then
    bash "$base/modules/security/build-php84-security.sh"
fi
[ "$("$prefix/bin/php" -n -r 'echo PHP_VERSION;')" = "$version" ] || exit 1
# Verify the complete extension set before changing any entrypoints.
"$vendor/bin/php" -r 'echo json_encode(get_loaded_extensions());' > "$state/extensions-before.json"
mkdir -p "$prefix/etc/php.d" "$state/wrappers"
python3 - "$prefix" <<'PY'
import pathlib,re,sys,json,subprocess,os
prefix=pathlib.Path(sys.argv[1]); src=pathlib.Path('/etc/opt/remi/php84'); dst=prefix/'etc'
# Retain all runtime settings while omitting duplicate built-in load directives.
for p in [src/'php.ini', *sorted((src/'php.d').glob('*.ini'))]:
    out=dst/'php.ini' if p.name=='php.ini' else dst/'php.d'/p.name
    out.write_text(re.sub(r'(?m)^\s*(?:zend_extension|extension|extension_dir)\s*=.*$', '; Source runtime module loading is managed by ShieldPress.', p.read_text()))
ext=subprocess.check_output([str(prefix/'bin/php'),'-n','-r','echo ini_get("extension_dir");'],text=True)
(dst/'php.d/00-source-opcache.ini').write_text('zend_extension='+ext+'/opcache.so\n')
# Match the vendor build's MySQL socket defaults. Source builds otherwise use
# /tmp/mysql.sock, which makes WordPress fail when MariaDB listens elsewhere.
vendor_bin='/opt/remi/php84/root/usr/bin/php'
socket_lines=[]
for key in ('mysqli.default_socket','pdo_mysql.default_socket'):
    value=subprocess.check_output([vendor_bin,'-r',f'echo ini_get("{key}");'],text=True).strip()
    if value:
        socket_lines.append(f'{key}="{value}"\n')
if socket_lines:
    (dst/'php.d/99-vendor-runtime-defaults.ini').write_text(''.join(socket_lines))
env=dict(os.environ,PHP_INI_SCAN_DIR=str(dst/'php.d'))
before=json.loads(pathlib.Path('/var/shieldpress/data/php-source-84/extensions-before.json').read_text())
loaded=json.loads(subprocess.check_output([str(prefix/'bin/php'),'-c',str(dst/'php.ini'),'-r','echo json_encode(get_loaded_extensions());'],env=env,text=True))
missing=sorted(set(before)-set(loaded))
if missing:
    vendor_bin=pathlib.Path('/opt/remi/php84/root/usr/bin/php')
    vendor_ext=pathlib.Path(subprocess.check_output([str(vendor_bin),'-n','-r','echo ini_get("extension_dir");'],text=True))
    configured={}
    for ini in sorted((src/'php.d').glob('*.ini')):
        for kind,value in re.findall(r'(?m)^\s*(zend_extension|extension)\s*=\s*["\']?([^"\'\s;]+)',ini.read_text()):
            configured[pathlib.Path(value).name.removesuffix('.so').lower()]=(kind,value)
    lines=[]; unresolved=[]
    for module in missing:
        entry=configured.get(module.lower())
        if not entry:
            unresolved.append(module); continue
        kind,value=entry
        filename=pathlib.Path(value).name
        candidate=pathlib.Path(value) if '/' in value else vendor_ext/filename
        if not candidate.is_file():
            unresolved.append(module); continue
        lines.append(f'{kind}={candidate}\n')
    if unresolved: raise SystemExit('Missing extensions; promotion refused: '+', '.join(unresolved))
    (dst/'php.d/10-vendor-extensions.ini').write_text(''.join(lines))
    loaded=json.loads(subprocess.check_output([str(prefix/'bin/php'),'-c',str(dst/'php.ini'),'-r','echo json_encode(get_loaded_extensions());'],env=env,text=True))
    unresolved=sorted(set(before)-set(loaded))
    if unresolved: raise SystemExit('Existing extensions failed to load: '+', '.join(unresolved))
print('All existing extensions available, including vendor modules')
PY
export PHP_INI_SCAN_DIR="$prefix/etc/php.d"
"$prefix/sbin/php-fpm" -c "$prefix/etc/php.ini" -y /etc/opt/remi/php84/php-fpm.conf -t

# Snapshot every path before promotion; never overwrite a previous recovery copy.
{
    paths=()
    for tool in php php-cgi phpdbg phpize php-config; do
        [ ! -e "$vendor/bin/$tool" ] || paths+=("${vendor#/}/bin/$tool")
    done
    paths+=("${vendor#/}/sbin/php-fpm")
    for path in /usr/bin/php /usr/local/bin/php /usr/bin/php84 /usr/local/bin/php84; do
        if [ -e "$path" ] || [ -L "$path" ]; then paths+=("${path#/}"); fi
    done
    tar -cpf "$state/entrypoints-current.tar" -C / "${paths[@]}"
    [ -f "$state/entrypoints.tar" ] || cp -a "$state/entrypoints-current.tar" "$state/entrypoints.tar"
}
absent=()
for path in "$vendor/bin/php" "$vendor/bin/php-cgi" "$vendor/bin/phpdbg" "$vendor/bin/phpize" "$vendor/bin/php-config" "$vendor/sbin/php-fpm"; do
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then absent+=("$path"); fi
done
active=0
systemctl is-active --quiet php84-php-fpm && active=1
mkdir -p /etc/systemd/system/php84-php-fpm.service.d
dropin=/etc/systemd/system/php84-php-fpm.service.d/shieldpress-source-security.conf
rm -f "$state/dropin-current.conf"
if [ -f "$dropin" ]; then cp -a "$dropin" "$state/dropin-current.conf"; fi
rollback(){
    code=$?
    if [ "$code" -ne 0 ]; then
        tar -xpf "$state/entrypoints-current.tar" -C /
        for path in "${absent[@]}"; do rm -f "$path"; done
        if [ -f "$state/dropin-current.conf" ]; then
            cp -a "$state/dropin-current.conf" "$dropin"
        else
            rm -f "$dropin"
        fi
        systemctl daemon-reload
        if [ "$active" -eq 1 ]; then systemctl restart php84-php-fpm; fi
        echo '[FAIL] Promotion failed; original entrypoints restored'
    fi
    exit "$code"
}
trap rollback EXIT
if command -v chcon >/dev/null && [ "$(getenforce)" != Disabled ]; then
    chcon --reference="$vendor/sbin/php-fpm" "$prefix/sbin/php-fpm"
fi
for tool in php php-cgi phpdbg phpize php-config php-fpm; do
    case "$tool" in php-fpm) target="$prefix/sbin/$tool"; entry="$vendor/sbin/$tool" ;; *) target="$prefix/bin/$tool"; entry="$vendor/bin/$tool" ;; esac
    [ -x "$target" ] || { echo "[FAIL] Missing $target"; exit 1; }
    wrapper="$state/wrappers/$tool"
    {
        echo '#!/bin/bash'
        echo '# SHIELDPRESS_SOURCE_PHP84'
        printf 'export PHP_INI_SCAN_DIR=%q\n' "$prefix/etc/php.d"
        case "$tool" in
            phpize|php-config) printf 'exec %q "$@"\n' "$target" ;;
            php-fpm) printf 'exec %q -c %q -y /etc/opt/remi/php84/php-fpm.conf "$@"\n' "$target" "$prefix/etc/php.ini" ;;
            *) printf 'exec %q -c %q "$@"\n' "$target" "$prefix/etc/php.ini" ;;
        esac
    } > "$wrapper"
    chmod 755 "$wrapper"
    # Atomic rename replaces the entrypoint, without following an existing symlink.
    cp "$wrapper" "$entry.sp-new"
    chmod 755 "$entry.sp-new"
    if command -v chcon >/dev/null && [ "$(getenforce)" != Disabled ]; then
        reference="$entry"
        [ -e "$reference" ] || reference="$vendor/bin/php"
        chcon --reference="$reference" "$entry.sp-new"
    fi
    mv -f "$entry.sp-new" "$entry"
done
cat > "$dropin" <<UNIT
[Service]
Environment=PHP_INI_SCAN_DIR=$prefix/etc/php.d
ExecStart=
ExecStart=$prefix/sbin/php-fpm -c $prefix/etc/php.ini -y /etc/opt/remi/php84/php-fpm.conf --nodaemonize
UNIT
systemctl daemon-reload
# Existing global aliases that point at this branch follow the updated entrypoint.
# Never switch an existing default from another PHP branch.

"$vendor/bin/php" -r 'if (PHP_VERSION !== "8.4.27") exit(1); echo "Vendor CLI: ",PHP_VERSION,PHP_EOL;'
"$vendor/sbin/php-fpm" -t
if [ "$active" -eq 1 ]; then
    systemctl restart php84-php-fpm
    systemctl is-active --quiet php84-php-fpm
    pid=$(systemctl show php84-php-fpm -p MainPID --value)
    [ "$(readlink "/proc/$pid/exe")" = "$prefix/sbin/php-fpm" ]
fi
touch "$state/active"
echo '[OK] PHP 8.4 source security patch applied to CLI, CGI, phpdbg, build tools and FPM'
