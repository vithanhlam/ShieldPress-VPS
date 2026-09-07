#!/usr/bin/env python3
"""Isolated regression checks; never connects to a real database."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1] / 'shieldpress'
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    for d in ('bin', 'core', 'data/laravel-databases', 'logs', 'backups'):
        (root / d).mkdir(parents=True)
    (root / 'core/paths.sh').write_text(f'''DATA_DIR_LARAVEL_DB='{root}/data/laravel-databases'
LOG_DIR='{root}/logs'
BACKUP_GLOBAL_DIR='{root}/backups'
''')
    (root / 'data/laravel-databases/demo.env').touch()
    mock = root / 'bin/runuser'
    mock.write_text('#!/bin/bash\nprintf "partial or complete SQL\\n"\nexit "${DUMP_EXIT:-0}"\n')
    mock.chmod(0o755)
    runner = root / 'bin/laravel-pg-backup'
    runner.write_text((ROOT / 'bin/laravel-pg-backup').read_text().replace(
        'export PATH=', f'export PATH={root}/bin:'))
    runner.chmod(0o755)
    dest = root / 'backups/laravel-postgresql/demo'
    dest.mkdir(parents=True)
    old = dest / 'demo_20000101_000000.sql.gz'
    old.write_bytes(b'previous backup')
    failed = subprocess.run([str(runner), 'demo', '1'], env={**os.environ, 'DUMP_EXIT': '1'}, capture_output=True)
    assert failed.returncode != 0
    assert list(dest.glob('*.sql.gz')) == [old]
    assert not list(dest.glob('.partial.*'))
    assert '[FAIL]' in (root / 'logs/postgresql-backup.log').read_text()
    good = subprocess.run([str(runner), 'demo', '1'], capture_output=True, text=True)
    assert good.returncode == 0, good.stderr
    assert Path(good.stdout.strip()).is_file()
    assert not old.exists()
    subprocess.run(['gzip', '-t', good.stdout.strip()], check=True)
    # Execute only the updater's staging preservation block in a sandbox fixture.
    oldroot, newroot = root / 'old', root / 'new'
    (oldroot / 'config/config').mkdir(parents=True)
    (newroot / 'config').mkdir(parents=True)
    (oldroot / 'config/config/backup-remote.env').write_text('REMOTE_ENABLED=1\n')
    (oldroot / 'bin').mkdir()
    (oldroot / 'bin/laravel-pg-backup').write_text('#!/bin/bash\nKEEP=13\n')
    (oldroot / 'config/active.env').write_text('live\n')
    (oldroot / 'config/config/active.env').write_text('stale\n')
    updater = (ROOT / 'modules/update/updater.sh').read_text()
    block = updater.split('# Copy directory contents,', 1)[1].split('# preserve persistent directories', 1)[0]
    block = block.split('\n', 1)[1]
    subprocess.run(['bash', '-ec', 'fail(){ echo "$*" >&2; exit 1; };\n' + block],
                   env={**os.environ, 'BASE_DIR': str(oldroot), 'NEW_DIR': str(newroot)}, check=True)
    assert (newroot / 'config/backup-remote.env').read_text() == 'REMOTE_ENABLED=1\n'
    assert (newroot / 'config/active.env').read_text() == 'live\n'
    assert (newroot / 'config/pg-backup-retention').read_text() == '13\n'
    # Updating repeatedly must preserve the active remote config and cron scripts.
    (newroot / 'config/backup-remote.env').write_text('REMOTE_ENABLED=0\n')
    (newroot / 'config/auto-backup').mkdir()
    (newroot / 'config/auto-backup/job.sh').write_text('#!/bin/bash\nexit 0\n')
    for i in range(3):
        nextroot = root / f'update-{i}'
        (nextroot / 'config').mkdir(parents=True)
        subprocess.run(['bash', '-ec', 'fail(){ exit 1; };\n' + block],
                       env={**os.environ, 'BASE_DIR': str(newroot), 'NEW_DIR': str(nextroot)}, check=True)
        assert (nextroot / 'config/backup-remote.env').read_text() == 'REMOTE_ENABLED=0\n'
        assert (nextroot / 'config/auto-backup/job.sh').is_file()
        assert (nextroot / 'config/pg-backup-retention').read_text() == '13\n'
        newroot = nextroot
    # First upgrade is launched by the OLD updater: new migration must repair it.
    migration = (ROOT / 'modules/patches/patches-menu.sh').read_text()
    function = 'patch_recover_backup_config(){' + migration.split('patch_recover_backup_config(){', 1)[1].split('\n}\n', 1)[0] + '\n}\n'
    migrated = root / 'migration'
    (migrated / 'config/config/config').mkdir(parents=True)
    (migrated / 'bin').mkdir()
    (migrated / 'bin/laravel-pg-backup').touch()
    (migrated / 'config/config/config/backup-remote.env').write_text('REMOTE_ENABLED=1\n')
    (migrated / 'config/active.env').write_text('current\n')
    (migrated / 'config/config/active.env').write_text('stale\n')
    subprocess.run(['bash', '-ec', 'patch_applied(){ return 1; }; patch_mark_done(){ :; }; ok(){ :; };\n' + function + 'patch_recover_backup_config\npatch_recover_backup_config'],
                   env={**os.environ, 'BASE_DIR': str(migrated)}, check=True)
    assert (migrated / 'config/backup-remote.env').read_text() == 'REMOTE_ENABLED=1\n'
    assert (migrated / 'config/active.env').read_text() == 'current\n'
    assert os.access(migrated / 'bin/laravel-pg-backup', os.X_OK)
print('PASS: failed dump cleanup, success/retention, nested config recovery')
