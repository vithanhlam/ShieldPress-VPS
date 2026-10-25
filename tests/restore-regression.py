#!/usr/bin/env python3
"""Isolated restore, DB synchronization and upgrade regression tests."""
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1] / 'shieldpress'
spec = importlib.util.spec_from_file_location('repair', ROOT / 'modules/backup/restore-wordpress-db.py')
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)
with tempfile.TemporaryDirectory() as tmp:
    base = Path(tmp)
    domain = base / 'domains/demo'
    (domain / 'config').mkdir(parents=True)
    (domain / 'public_html').mkdir()
    env = domain / 'config/domain.env'
    config = domain / 'public_html/wp-config.php'
    original = "<?php\n" + '\n'.join("define('%s', '%s');" % pair for pair in
        [('DB_NAME', 'old'), ('DB_USER', 'old'), ('DB_PASSWORD', 'old'), ('DB_HOST', 'localhost')]) + '\n'
    password = "quote'\\= space"
    env.write_text('DOMAIN=demo.test\nAPP_TYPE=wordpress\nDB_NAME=live\nDB_USER=live\nDB_PASS=' + password + '\n')
    config.write_text(original)
    repair.connects = lambda values: values.get('DB_NAME') == 'live'
    repair.repair(domain, migration=True)
    assert "define('DB_NAME', 'live');" in config.read_text()
    assert "quote\\'\\\\= space" in config.read_text()
    assert (domain / 'config/wp-config.before-db-repair.php').read_text() == original
    first = config.read_text()
    repair.repair(domain, migration=True)
    assert config.read_text() == first
    repair.connects = lambda values: False
    try:
        repair.repair(domain)
        raise AssertionError('Invalid managed login accepted')
    except ValueError:
        pass
    assert config.read_text() == first
    repair.connects = lambda values: True
    config.write_text(original.replace("'old'", "getenv('DB_NAME')", 1))
    try:
        repair.repair(domain)
        raise AssertionError('Dynamic definition accepted')
    except ValueError:
        pass
    # Run actual menu script with a sandbox helper and archive fixtures.
    (base / 'core').mkdir()
    (base / 'modules/backup').mkdir(parents=True)
    (base / 'modules/backup/validate-archive.py').write_text((ROOT / 'modules/backup/validate-archive.py').read_text())
    (base / 'logs').mkdir()
    (base / 'core/paths.sh').write_text(f'DOMAINS_ROOT="{base}/domains"\nLOG_DIR="{base}/logs"\n')
    (base / 'modules/backup/_backup_helper.sh').write_text('''
load_domain_info(){
    source "$1/config/domain.env"
    DB_CONNECTION=mysql
    SYSTEM_USER=""
}
estimate_seconds(){ echo 1; }
format_duration(){ echo 1s; }
backup_db_to_file(){ printf old-db | gzip > "$1"; return "${SNAPSHOT_FAIL:-0}"; }
restore_db_from_sql(){ return "${IMPORT_FAIL:-0}"; }
''')
    (base / 'modules/backup/restore-wordpress-db.py').write_text('import os,sys\nsys.exit(int(os.environ.get("SYNC_FAIL", "0")) if "--check" not in sys.argv else 0)\n')
    script = base / 'restore.sh'
    script.write_text((ROOT / 'modules/backup/restore-site.sh').read_text().replace('BASE_DIR="/opt/shieldpress"', f'BASE_DIR="{base}"'))
    backup = domain / 'backup/full'
    backup.mkdir(parents=True)
    def archive(stack, corrupt=False):
        inner = io.BytesIO()
        with tarfile.open(fileobj=inner, mode='w:gz') as tar:
            payload = b'restored-content'
            info = tarfile.TarInfo('public_html/index.php' if stack in ('wordpress', 'php') else './index.php')
            info.size = len(payload)
            tar.addfile(info, io.BytesIO(payload))
        with tarfile.open(backup / 'full.tar.gz', 'w:gz') as tar:
            for name, payload in [('files.tar.gz', inner.getvalue()), ('db.sql.gz', b'bad-gzip' if corrupt else __import__('gzip').compress(b'SELECT 1;'))]:
                info = tarfile.TarInfo(name)
                info.size = len(payload)
                tar.addfile(info, io.BytesIO(payload))
    def run(stack='wordpress', delete=False, **options):
        env.write_text(f'DOMAIN=demo.test\nAPP_TYPE={stack}\nDB_NAME=live\nDB_USER=live\nDB_PASS=secret\n')
        (domain / 'public_html/index.php').write_text('previous-content')
        archive(stack, options.pop('corrupt', False))
        result = subprocess.run(['bash', str(script)], input='1\n1\ny\n' + ('y' if delete else '') + '\n\n',
            env={**os.environ, 'TERM': 'xterm', **options}, capture_output=True, text=True)
        return result
    for stack in ('wordpress', 'php', 'laravel', 'nodejs'):
        result = run(stack)
        assert result.returncode == 0, result.stdout + result.stderr
        assert (domain / 'public_html/index.php').read_text() == 'restored-content'
        assert 'Rollback snapshot retained' in result.stdout
    result = run(delete=True)
    assert result.returncode == 0 and 'Rollback snapshot deleted' in result.stdout
    for options in ({'SNAPSHOT_FAIL': '1'}, {'IMPORT_FAIL': '1'}, {'SYNC_FAIL': '1'}, {'corrupt': True}):
        result = run(**options)
        assert result.returncode != 0, result.stdout
        assert 'Restore completed successfully' not in result.stdout
        assert 'Delete this restore' not in result.stdout
        assert (domain / 'public_html/index.php').read_text() == 'previous-content', result.stdout
    # Exercise migration from the new patch script, as invoked by an old updater,
    # and confirm repeat execution skips already completed work.
    patch = (ROOT / 'modules/patches/patches-menu.sh').read_text()
    function = 'patch_restored_wordpress_db(){' + patch.split('patch_restored_wordpress_db(){', 1)[1].split('\n}\n', 1)[0] + '\n}\n'
    registry = base / 'registry'
    runner = '''patch_applied(){ grep -qxF "$1" "$REGISTRY" 2>/dev/null; }
patch_mark_done(){ echo "$1" >> "$REGISTRY"; }
skip(){ :; }; ok(){ :; }; fail(){ :; }
''' + function + '\npatch_restored_wordpress_db\npatch_restored_wordpress_db\n'
    registry_env = {**os.environ, 'BASE_DIR': str(base), 'DOMAINS_ROOT': str(base / 'domains'), 'LOG_DIR': str(base / 'logs'), 'REGISTRY': str(registry)}
    failed = subprocess.run(['bash', '-ec', runner], env={**registry_env, 'SYNC_FAIL': '1'})
    assert failed.returncode != 0 and not registry.exists()
    subprocess.run(['bash', '-ec', runner], env=registry_env, check=True)
    assert registry.read_text().count('SP_20261025') == 1
print('PASS: WordPress DB repair, migration retry/idempotence, four stacks, rollback retention/deletion, snapshot/import/config/archive failures')
