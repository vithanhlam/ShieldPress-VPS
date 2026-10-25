#!/usr/bin/env python3
"""Exercise restricted SSH package transfer, both DB engines, application processes and local probes."""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
from unittest import mock

spec = importlib.util.spec_from_file_location('migration', '/opt/shieldpress/modules/tools/server-migration.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
e = m.Engine()
e.initialize()
remote = m.Remote('migration-destination')
remote.prepare()
m.shutil.copyfile('/root/.ssh/known_hosts', remote.known)
remote.setup(method='1')
admin_options = ['-F', '/dev/null', '-i', '/root/.ssh/id_ed25519', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes']
probe = subprocess.run(['ssh', '-T', '-p', '22', *admin_options, 'root@migration-destination',
                        'python3 /opt/shieldpress/modules/tools/server-migration.py identity'], capture_output=True, text=True)
assert probe.returncode == 0, probe.stderr
before = {str(p): m.digest(p) for p in e.domains.rglob('*') if p.is_file() and not p.is_symlink()}
answers = iter(['1', 'ALL', 'y', 'COPY 4 TO migration-destination'])
with mock.patch('builtins.input', side_effect=lambda _: next(answers)):
    m.wizard(e, 'push')
batch = m.read_json(next(e.reports.glob('batch-*.json')))
assert len(batch['results']) == 4, batch
assert all(row['status'] == 'COPIED_PENDING_CUTOVER' for row in batch['results']), batch
assert not batch['not_started']
for stack, expected in [('wordpress', 'wordpress-database-copied'), ('php', 'php-files-copied'),
                        ('laravel', 'laravel-database-copied'), ('nodejs', 'nodejs-files-copied')]:
    folder = stack + '_test'
    report = remote.call('verify', folder, *(['--tls'] if stack == 'php' else []))
    assert report['ready'], report
    command = ['curl', '--noproxy', '*', '--silent', '--fail', '--resolve', f'{stack}.test:80:127.0.0.1', f'http://{stack}.test/']
    output = m.run(['ssh', '-T', '-p', '22', *admin_options, 'root@migration-destination', m.shlex.join(command)]).decode()
    assert output == expected, (stack, output)
    upload = m.run(['ssh', '-T', '-p', '22', *admin_options, 'root@migration-destination', f'cat /home/domains/{folder}/public_html/uploads/keep.txt']).decode()
    assert upload == stack + '-uploads-kept'
assert all(m.digest(Path(path)) == checksum for path, checksum in before.items())
assert 'wordpress-database-copied' in e.sql('mysql', 'SELECT message FROM wordpress_test_db.marker;')
cron = subprocess.run(['crontab', '-l'], capture_output=True, check=True).stdout
assert b'wordpress_test' in cron
private = m.run(['ssh', '-T', '-p', '22', *admin_options, 'root@migration-destination',
                 "curl --noproxy '*' --silent --fail --resolve php.test:80:127.0.0.1 -u fixture-user:fixture-password http://php.test/private"])
assert private == b'php-uploads-kept', private
assert b'AUTH_USER=fixture-user' in m.run(['ssh', '-T', '-p', '22', *admin_options, 'root@migration-destination',
                                         'grep ^AUTH_USER= /var/shieldpress/data/auth/php_test.auth'])
shared = m.run(['ssh', '-T', '-p', '22', *admin_options, 'root@migration-destination',
                'cat /etc/nginx/snippets/migration-shared.conf /etc/nginx/ssl/shared-dhparam.pem'])
assert shared == b'# Existing destination policy\nexisting-destination-dhparam\n', shared
# All pre-existing destination resources must block a second batch without changing files.
answers = iter(['migration-destination', '22', '1,3', 'y'])
try:
    with mock.patch('builtins.input', side_effect=lambda _: next(answers)):
        m.wizard(e, 'push')
    raise AssertionError('Existing destination websites were overwritten')
except ValueError as error:
    assert 'no website was imported' in str(error), error
assert all(m.digest(Path(path)) == checksum for path, checksum in before.items())
# Transport failures/checksum failures cannot activate any files.
try:
    remote.call('inspect', '/var/shieldpress/data/server-migration/packages/missing.spm.tar.gz', '0' * 64)
    raise AssertionError('Missing package accepted')
except ValueError:
    pass
print('PASS: four-stack batch over restricted SSH package transfer, real MariaDB/PostgreSQL imports, PHP-FPM/PM2, Nginx HTTP/HTTPS, hidden files/uploads/internal links, no source modification, duplicate copy refusal and retained cron jobs')
# A newly imported invalid Nginx config must roll back without breaking existing copies.
folder = 'broken_test'
home = e.domains / folder
for path in (home / 'public_html', home / 'config', home / 'backup'):
    path.mkdir(parents=True)
values = {'DOMAIN': 'broken.test', 'CLEAN_DOMAIN': folder, 'SYSTEM_USER': folder, 'APP_TYPE': 'php',
          'DB_CONNECTION': 'none', 'DB_NAME': '', 'DB_USER': '', 'DB_PASS': '', 'PHP_VERSION': '8.5'}
e.write_settings(values)
(home / 'public_html/index.php').write_text('<?php echo "retained-failed-copy";')
Path('/etc/opt/remi/php85/php-fpm.d/broken_test.conf').write_text(Path('/etc/opt/remi/php85/php-fpm.d/php_test.conf').read_text().replace('php_test', folder))
Path('/etc/nginx/conf.d/broken_test.conf').write_text('server { listen 80; server_name broken.test; invalid_migration_test_directive on; }')
exported = e.export(folder)
incoming = remote.call('incoming', exported['manifest']['id'])['path']
remote.transfer(exported['package'], incoming)
received = remote.call('receive', exported['manifest']['id'], exported['sha256'])
assert remote.call('inspect', received['package'], exported['sha256'])['ready']
try:
    remote.call('import', received['package'], exported['sha256'], remote.call('identity')['id'])
    raise AssertionError('Invalid Nginx configuration accepted')
except ValueError:
    pass
command = f'cat /var/shieldpress/data/server-migration/reports/{exported["manifest"]["id"]}.json'
failed = json.loads(m.run(['ssh', '-T', '-p', '22', *admin_options, 'root@migration-destination', command]))
assert failed['status'] == 'FAILED_RETAINED', failed
assert remote.call('verify', 'php_test')['ready']
check = m.run(['ssh', '-T', '-p', '22', *admin_options, 'root@migration-destination',
               'test ! -e /etc/nginx/conf.d/broken_test.conf && test ! -e /etc/opt/remi/php85/php-fpm.d/broken_test.conf && cat /home/domains/broken_test/public_html/index.php'])
assert b'retained-failed-copy' in check
print('PASS: real Nginx failure removes only new configuration, restores shared services and retains the failed website for recovery')
# A fully password-protected website remains protected and can still pass guarded readiness checks.
folder = 'authfull_test'
home = e.domains / folder
for path in (home / 'public_html', home / 'config', home / 'backup'):
    path.mkdir(parents=True)
values.update(DOMAIN='authfull.test', CLEAN_DOMAIN=folder, SYSTEM_USER=folder)
e.write_settings(values)
(home / 'public_html/index.php').write_text('<?php echo "protected-copy";')
Path('/etc/opt/remi/php85/php-fpm.d/authfull_test.conf').write_text(Path('/etc/opt/remi/php85/php-fpm.d/php_test.conf').read_text().replace('php_test', folder))
Path('/etc/nginx/conf.d/authfull_test.conf').write_text('server { listen 80; server_name authfull.test; root /home/domains/authfull_test/public_html; index index.php; auth_basic "Protected"; auth_basic_user_file /etc/nginx/auth/php_test.htpasswd; location ~ \\.php$ { include /etc/nginx/fastcgi_params; fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name; fastcgi_pass unix:/var/opt/remi/php85/run/php-fpm/authfull_test.sock; } }')
exported = e.export(folder)
incoming = remote.call('incoming', exported['manifest']['id'])['path']
remote.transfer(exported['package'], incoming)
received = remote.call('receive', exported['manifest']['id'], exported['sha256'])
assert remote.call('inspect', received['package'], exported['sha256'])['ready']
result = remote.call('import', received['package'], exported['sha256'], remote.call('identity')['id'])
assert result['status'] == 'COPIED_PENDING_CUTOVER'
assert '401' in str(result['verification'])
protected = m.run(['ssh', '-T', '-p', '22', *admin_options, 'root@migration-destination',
                  "curl --noproxy '*' --silent --fail --resolve authfull.test:80:127.0.0.1 -u fixture-user:fixture-password http://authfull.test/"])
assert protected == b'protected-copy'
public_probe = m.run(['curl', '--noproxy', '*', '--silent', '-o', '/dev/null', '-w', '%{http_code}',
                      '-H', 'Host: authfull.test', 'http://migration-destination/.well-known/shieldpress-migration-' + exported['manifest']['id']])
assert public_probe == b'404'
print('PASS: password-protected routes and full sites, private auth metadata and isolation from existing destination TLS policies')
# The migration key cannot open a shell or operate in the wrong direction.
for command in ('id', 'bash -c id', 'python3 /opt/shieldpress/modules/tools/server-migration.py export php_test',
                'migration-upload /etc/passwd.partial', 'scp -t /tmp'):
    denied = subprocess.run([*remote.connection_args(), command], capture_output=True)
    assert denied.returncode != 0, command
forward = subprocess.run(['ssh', '-o', 'ClearAllForwardings=no', '-o', 'ExitOnForwardFailure=yes',
                          '-N', '-R', '127.0.0.1:48889:127.0.0.1:80', '-p', '22', *remote.options,
                          'root@migration-destination'], capture_output=True, timeout=10)
assert forward.returncode != 0 and b'forwarding failed' in forward.stderr, forward.stderr
# A lost local migration key can be rotated through administrator pairing without leaving its old grant active.
old_fingerprint = remote.saved()['fingerprint']
remote.key.unlink()
remote.setup(method='1')
assert remote.saved()['fingerprint'] != old_fingerprint
old_grant = '/var/shieldpress/data/server-migration/ssh-grants/' + old_fingerprint + '.json'
m.run(['ssh', '-T', '-p', '22', *admin_options, 'root@migration-destination', 'test ! -e ' + old_grant])
# Enforce server-side expiry, then revoke exactly this grant without removing administrator access.
profile = remote.saved()
code = 'from pathlib import Path; import json; p=Path(' + repr('/var/shieldpress/data/server-migration/ssh-grants/' + profile['fingerprint'] + '.json') + '); value=json.loads(p.read_text()); value["expires"]=0; p.write_text(json.dumps(value))'
m.run(['ssh', '-T', '-p', '22', *admin_options, 'root@migration-destination', m.shlex.join(['python3', '-c', code])])
try:
    remote.call('identity')
    raise AssertionError('Expired migration permission accepted')
except ValueError:
    pass
remote.disconnect()
assert not remote.key.exists() and not remote.profile.exists()
assert m.run(['ssh', '-T', '-p', '22', *admin_options, 'root@migration-destination', 'id -u']).strip() == b'0'
print('PASS: automatic restricted-key pairing, saved connection reuse, shell/direction/path/forwarding denial, expiry and exact grant revocation while administrator SSH remains available')
