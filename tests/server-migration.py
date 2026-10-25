#!/usr/bin/env python3
"""Isolated package, preflight, failure recovery and update-handoff regressions."""
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
from unittest import mock

os.umask(0o077)
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('migration', ROOT / 'shieldpress/modules/tools/server-migration.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


# Exercise the real wizard up to website selection in both directions. The
# SSH client changes data role; the inventory must always come from source A.
for direction in ('push', 'pull'):
    local = {'hostname': 'local-vps', 'id': 'a'*64, 'protocol': 2}
    remote = {'hostname': 'remote-vps', 'id': 'b'*64, 'protocol': 2}
    local_inventory, remote_inventory = {'sites': ['local-originals']}, {'sites': ['remote-originals']}
    engine = mock.Mock()
    engine.identity.return_value = local
    engine.inventory.return_value = local_inventory
    peer = mock.Mock(host='remote.example', port=2222)
    peer.call.side_effect = lambda action: remote if action == 'identity' else remote_inventory
    output = io.StringIO()
    with mock.patch.object(m.ssh_support, 'choose_remote', return_value=peer), \
         mock.patch.object(m, 'choose_sites', return_value=[]) as picker, contextlib.redirect_stdout(output):
        m.wizard(engine, direction)
    assert picker.call_args.args[0] is (local_inventory if direction == 'push' else remote_inventory)
    text = output.getvalue()
    client_line = next(line for line in text.splitlines() if 'CLIENT / this VPS' in line)
    source_line = next(line for line in text.splitlines() if 'A / SOURCE (original websites)' in line)
    destination_line = next(line for line in text.splitlines() if 'B / DESTINATION (new copies)' in line)
    assert 'local-vps' in client_line
    assert ('[SOURCE A]' if direction == 'push' else '[DESTINATION B]') in client_line
    assert ('local-vps' if direction == 'push' else 'remote-vps') in source_line
    assert ('remote-vps' if direction == 'push' else 'local-vps') in destination_line
    assert 'A -> B' in text and 'SSH port 2222' in text
    engine.export.assert_not_called()
    engine.import_package.assert_not_called()


def blocked(action, message=None):
    try:
        action()
    except (ValueError, OSError, tarfile.TarError) as error:
        if message:
            assert message in str(error), str(error)
        return
    raise AssertionError('Unsafe operation was accepted')


def fixture(root, stack='php', folder='demo_test'):
    engine = m.Engine(root)
    (root / 'etc').mkdir(parents=True)
    (root / 'etc/machine-id').write_text(str(root))
    engine.domains.mkdir(parents=True)
    target = engine.domains / folder
    (target / 'public_html').mkdir(parents=True)
    (target / 'config').mkdir()
    (target / 'backup').mkdir()
    (target / 'config/domain.env').write_text(f'DOMAIN=demo.test\nCLEAN_DOMAIN={folder}\nSYSTEM_USER={folder}\nAPP_TYPE={stack}\nDB_CONNECTION=none\nPHP_VERSION=8.5\nNODE_APP_PORT=3301\nNODE_ENTRY=app.js\n')
    app = target / 'public_html'
    (app / '.env').write_text('SECRET=kept\n')
    (app / 'index.php').write_text('<?php echo "migration";')
    (app / 'storage').mkdir()
    (app / 'storage/item').write_text('uploads')
    (app / 'public').mkdir()
    (app / 'public/storage').symlink_to(app / 'storage', target_is_directory=True)
    nginx = root / 'etc/nginx/conf.d'
    nginx.mkdir(parents=True)
    (nginx / f'{folder}.conf').write_text('server { listen 80; server_name demo.test; root /home/domains/demo_test/public_html; }\n')
    pool = root / f'etc/opt/remi/php85/php-fpm.d/{folder}.conf'
    pool.parent.mkdir(parents=True)
    pool.write_text(f'[{folder}]\nuser={folder}\ngroup={folder}\nlisten=/var/opt/remi/php85/run/php-fpm/{folder}.sock\n')
    binary = root / 'opt/remi/php85/root/usr/bin/php'
    binary.parent.mkdir(parents=True)
    binary.write_text('#!/bin/sh\nexit 0\n')
    binary.chmod(0o755)
    return engine


with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    source = fixture(root / 'source')
    source.initialize()
    original = (source.domains / 'demo_test/public_html/index.php').read_bytes()
    atomic = root / 'atomic.conf'
    m.exclusive_file(atomic, b'original')
    blocked(lambda: m.exclusive_file(atomic, b'replacement'))
    assert atomic.read_bytes() == b'original'
    assert not list(root.glob('.migration-*.tmp'))
    assert not m.has_http_auth('auth_basic    off;')
    assert m.has_http_auth('auth_basic "Private";')
    sample = '# server { ignored\nserver { set $x "server {"; } server { }\n'
    probed = m.nginx_probe(sample, 'a' * 32)
    assert probed.count('# ShieldPress migration probe BEGIN') == 2
    refreshed = m.nginx_probe(probed, 'b' * 32)
    assert 'a' * 32 not in refreshed and refreshed.count('# ShieldPress migration probe BEGIN') == 2
    # A default vhost returning HTTP 200 cannot masquerade as the copied website.
    nonce = 'c' * 32
    m.write_json(source.domains / 'demo_test/config/migration.json', {'id': nonce, 'tls': False, 'hosts': ['demo.test']})
    values = source.settings('demo_test')
    values['ROOT'] = str(source.domains / 'demo_test/public_html')
    with mock.patch.object(source, 'settings', return_value=values), mock.patch.object(m, 'run', return_value=b'200'):
        result = source.verify('demo_test')
        assert not result['ready']
        assert not next(row for row in result['checks'] if row['check'] == 'destination virtual host identity')['ok']
    def verified_request(args, **kwargs):
        if '--resolve' in args:
            return nonce.encode() if str(args[-1]).endswith(nonce) else b'200'
        return b''
    with mock.patch.object(source, 'settings', return_value=values), mock.patch.object(m, 'run', side_effect=verified_request):
        assert source.verify('demo_test')['ready']
    with mock.patch.object(m.shutil, 'disk_usage', return_value=mock.Mock(free=0)), mock.patch.object(source, 'supplemental', return_value=[]):
        blocked(lambda: source.export('demo_test'), 'source scratch space')
    with mock.patch.object(source, 'supplemental', return_value=[]):
        exported = source.export('demo_test')
    package = Path(exported['package'])
    assert package.stat().st_mode & 0o777 == 0o600
    assert source.state.stat().st_mode & 0o777 == 0o700
    assert (source.domains / 'demo_test/public_html/index.php').read_bytes() == original
    with source.unpack(package, exported['sha256']) as (stage, manifest):
        assert manifest['files_bytes'] > 0
        with tarfile.open(stage / 'files.tar.gz') as tar:
            assert '.env' in tar.getnames()
            assert tar.getmember('public/storage').linkname == '../storage'
    blocked(lambda: source.unpack(package, '0' * 64).__enter__(), 'SHA-256')
    def repack(change):
        changed = root / 'changed.spm.tar.gz'
        with source.unpack(package, exported['sha256']) as (stage, details):
            change(stage, details)
            m.write_json(stage / 'manifest.json', details)
            with tarfile.open(changed, 'w:gz') as tar:
                for child in stage.iterdir():
                    tar.add(child, child.name)
        return changed
    changed = repack(lambda stage, details: (stage / 'files.tar.gz').write_bytes(b'corrupt payload'))
    blocked(lambda: source.unpack(changed, m.digest(changed)).__enter__(), 'checksum')
    def missing_database(stage, details):
        details['settings'].update(DB_CONNECTION='mysql', DB_NAME='missing_db', DB_USER='missing_user', DB_PASS='private')
        details['db_bytes'] = 100
    changed = repack(missing_database)
    blocked(lambda: source.unpack(changed, m.digest(changed)).__enter__(), 'Database payload')
    # Path traversal, root paths, missing databases, forged payloads and account IDs.
    for change in ({'folder': '../outside'}, {'settings': {**manifest['settings'], 'SYSTEM_USER': 'root'}},
                   {'settings': {**manifest['settings'], 'ROOT': '/etc'}}, {'protocol': 1}, {'db_bytes': -1}):
        invalid = copy.deepcopy(manifest)
        invalid.update(change)
        blocked(lambda: source.validate_manifest(invalid))
    unsafe = root / 'traversal.tar.gz'
    with tarfile.open(unsafe, 'w:gz') as tar:
        info = tarfile.TarInfo('../../outside')
        info.size = 1
        tar.addfile(info, io.BytesIO(b'x'))
    blocked(lambda: source.unpack(unsafe, m.digest(unsafe)).__enter__(), 'traversal')
    outside = source.domains / 'demo_test/public_html/outside'
    outside.symlink_to('/etc/passwd')
    with mock.patch.object(source, 'supplemental', return_value=[]):
        blocked(lambda: source.export('demo_test'), 'escapes source')
    outside.unlink()
    # File-descriptor traversal refuses a file swapped for an external symlink.
    actual_open = os.open
    raced = False
    index = source.domains / 'demo_test/public_html/index.php'
    secret = root / 'outside-secret'
    secret.write_text('must-not-be-archived')
    def race_open(name, flags, *args, **kwargs):
        global raced
        if name == 'index.php' and kwargs.get('dir_fd') is not None and not raced:
            raced = True
            index.unlink()
            index.symlink_to(secret)
        return actual_open(name, flags, *args, **kwargs)
    with mock.patch.object(source, 'supplemental', return_value=[]), mock.patch.object(m.os, 'open', side_effect=race_open):
        blocked(lambda: source.export('demo_test'))
    assert raced
    index.unlink()
    index.write_bytes(original)
    # No source changes after export errors; no new package published.
    assert len(list(source.packages.glob('*.spm.tar.gz'))) == 1
    assert (source.domains / 'demo_test/public_html/index.php').read_bytes() == original
    # A failed DB dump must never create a valid migration package.
    with mock.patch.object(source, 'supplemental', return_value=[]), mock.patch.object(source, 'dump_database', side_effect=ValueError('dump failed')):
        blocked(lambda: source.export('demo_test'), 'dump failed')
    assert len(list(source.packages.glob('*.spm.tar.gz'))) == 1
    destination = m.Engine(root / 'destination')
    destination.path('/etc').mkdir(parents=True)
    destination.path('/etc/machine-id').write_text('different-machine')
    destination.domains.mkdir(parents=True)
    destination.path('/opt/remi/php85/root/usr/sbin').mkdir(parents=True)
    destination.path('/opt/remi/php85/root/usr/sbin/php-fpm').touch()
    with mock.patch.object(m, 'run', return_value=b''), mock.patch.object(m.shutil, 'which', return_value='/usr/bin/tool'), \
         mock.patch.object(m.pwd, 'getpwnam', side_effect=KeyError), mock.patch.object(m.grp, 'getgrnam', side_effect=KeyError):
        plan = destination.preflight(manifest)
        assert plan['ready'], plan
        (destination.domains / 'demo_test').mkdir()
        assert not destination.preflight(manifest)['ready']
        (destination.domains / 'demo_test').rmdir()
        with mock.patch.object(destination, 'identity', return_value=manifest['source']):
            assert 'same VPS' in ' '.join(destination.preflight(manifest)['errors'])
        # PHP and source account/resource preservation on runtime failure.
        with mock.patch.object(destination, 'write_settings') as settings, \
             mock.patch.object(destination, 'create_database'), mock.patch.object(destination, 'import_database'), \
             mock.patch.object(destination, 'database_login'), mock.patch.object(destination, 'reconnect_app'), \
             mock.patch.object(destination, 'selinux'), mock.patch.object(destination, 'php_pool', side_effect=ValueError('bad FPM')), \
             mock.patch.object(m.subprocess, 'run', return_value=mock.Mock(returncode=0)):
            blocked(lambda: destination.import_package(package, exported['sha256'], destination.identity()['id']), 'private recovery report')
            report = m.read_json(destination.reports / (manifest['id'] + '.json'))
            assert report['status'] == 'FAILED_RETAINED'
            assert (destination.domains / 'demo_test/public_html/index.php').read_bytes() == original
            assert (source.domains / 'demo_test/public_html/index.php').read_bytes() == original
            assert not destination.path('/etc/nginx/conf.d/demo_test.conf').exists()
    # Selection parsing rejects expression injection and supports multi-select/all.
    inventory = {'sites': [{'folder': 'a', 'domain': 'a.test', 'app': 'php'}, {'folder': 'b', 'domain': 'b.test', 'app': 'nodejs'}]}
    for answer, count in [('ALL', 2), ('2,1,2', 2), ('1', 1), ('', 0)]:
        with mock.patch('builtins.input', return_value=answer), contextlib.redirect_stdout(io.StringIO()):
            assert len(m.choose_sites(inventory)) == count
    for answer in ('0', '-1', '3', '1;reboot', '$(touch /tmp/pwned)'):
        with mock.patch('builtins.input', return_value=answer), contextlib.redirect_stdout(io.StringIO()):
            blocked(lambda: m.choose_sites(inventory))
    for host in ('-oProxyCommand=sh', 'root@host;reboot', 'user@host', 'a b'):
        blocked(lambda: m.Remote(host))
    # Actual automatic storage handoff preserves old packages, retries and is idempotent.
    old = destination.path('/opt/shieldpress_old/migrate')
    old.mkdir(parents=True)
    (old / 'demo_migrate_old.tar.gz').write_bytes(b'legacy-private-package')
    assert destination.upgrade_storage()['copied'] == 1
    assert destination.upgrade_storage()['copied'] == 0
    assert (old / 'demo_migrate_old.tar.gz').read_bytes() == b'legacy-private-package'
    legacy = next((destination.packages / 'legacy').iterdir())
    legacy.write_bytes(b'corrupt')
    blocked(destination.upgrade_storage, 'checksum changed')
    legacy.write_bytes(b'legacy-private-package')
    # Run the exact hook from the new patch script, as called by an older updater.
    patch = (ROOT / 'shieldpress/modules/patches/patches-menu.sh').read_text()
    function = 'patch_server_migration_storage(){' + patch.split('patch_server_migration_storage(){', 1)[1].split('\n}\n', 1)[0] + '\n}\n'
    fake = root / 'fake/modules/tools'
    fake.mkdir(parents=True)
    (fake / 'server-migration.py').write_text('import os,sys\nsys.exit(int(os.getenv("UPGRADE_FAIL", "0")))\n')
    registry = root / 'registry'
    runner = '''patch_applied(){ grep -qxF "$1" "$REGISTRY" 2>/dev/null; }
patch_mark_done(){ echo "$1" >> "$REGISTRY"; }
skip(){ :; }; ok(){ :; }; fail(){ :; }
''' + function + '\npatch_server_migration_storage\npatch_server_migration_storage\n'
    env = {**os.environ, 'BASE_DIR': str(root / 'fake'), 'REGISTRY': str(registry)}
    assert subprocess.run(['bash', '-ec', runner], env={**env, 'UPGRADE_FAIL': '1'}).returncode != 0
    assert not registry.exists()
    subprocess.run(['bash', '-ec', runner], env=env, check=True)
    assert registry.read_text().count('SERVER_MIGRATION_STORAGE') == 1
    updater = (ROOT / 'shieldpress/modules/update/updater.sh').read_text()
    gate = updater.split('if [ -f "$NEW_DIR/modules/tools/server-migration.py" ]; then', 1)[1].split('\nfi', 1)[0]
    gate = 'if [ -f "$NEW_DIR/modules/tools/server-migration.py" ]; then' + gate + '\nfi\n'
    switched = root / 'switched'
    handoff = 'fail(){ exit 1; };\n' + gate + '\ntouch "$SWITCHED"\n'
    switch_env = {**env, 'NEW_DIR': str(root / 'fake'), 'SWITCHED': str(switched)}
    assert subprocess.run(['bash', '-ec', handoff], env={**switch_env, 'UPGRADE_FAIL': '1'}).returncode != 0
    assert not switched.exists()
    subprocess.run(['bash', '-ec', handoff], env=switch_env, check=True)
    assert switched.exists()
print('PASS: package integrity, complete files, internal/external symlinks, no source deletion, failed dump/import recovery, conflicts, same-server guard, selection/SSH input validation, legacy storage retry and update handoff')
