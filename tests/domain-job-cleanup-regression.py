#!/usr/bin/env python3
"""Exercise cleanup with a mock crontab and disposable domains."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile

source = Path(__file__).resolve().parents[1] / 'shieldpress/modules/backup/cleanup-domain-jobs.py'
spec = importlib.util.spec_from_file_location('cleanup', source)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    domains = root / 'domains'
    base = root / 'base'
    scripts = base / 'config/auto-backup'
    scripts.mkdir(parents=True)
    for name in ('demo', 'demo-other'):
        (domains / name / 'config').mkdir(parents=True)
        (domains / name / 'config/domain.env').touch()
    domain = domains / 'demo'
    other = domains / 'demo-other'
    batch = scripts / 'auto-backup-full-db-batch.sh'
    batch.write_text(f'JOBS=(\n  mysql\\|demo_db\\|{domain}\n  mysql\\|other_db\\|{other}\n)\n')
    standalone = scripts / 'auto-backup-db-mysql-demo_db.sh'
    standalone.write_text('DB_NAME="demo_db"\nDB_CONNECTION="mysql"\n')
    cron = root / 'cron'
    original = f'0 23 * * * {domain}/config/auto-backup-db.sh\n0 23 * * * {other}/config/auto-backup-db.sh\n0 23 * * * {batch}\n0 23 * * * {standalone}\n0 1 * * * /usr/bin/true\n'
    cron.write_text(original)
    bin_dir = root / 'bin'
    bin_dir.mkdir()
    command = bin_dir / 'crontab'
    command.write_text('#!/bin/bash\nif [ "$1" = -l ]; then cat "$TEST_CRON"; else [ "${FAIL_WRITE:-0}" = 0 ] || exit 1; cat > "$TEST_CRON"; fi\n')
    command.chmod(0o755)
    os.environ.update(PATH=f'{bin_dir}:{os.environ["PATH"]}', TEST_CRON=str(cron), FAIL_WRITE='1')
    try:
        module.cleanup(base, domains, str(domain), 'demo_db', 'mysql')
        raise AssertionError('Expected cron installation failure')
    except subprocess.CalledProcessError:
        pass
    assert standalone.exists() and 'demo_db' in batch.read_text()
    os.environ['FAIL_WRITE'] = '0'
    module.cleanup(base, domains, str(domain), 'demo_db', 'mysql')
    assert not standalone.exists()
    assert 'demo_db' not in batch.read_text() and 'other_db' in batch.read_text()
    assert f'{domain}/config' not in cron.read_text()
    assert f'{other}/config' in cron.read_text() and '/usr/bin/true' in cron.read_text()
    stable = cron.read_text(), batch.read_text()
    module.cleanup(base, domains, str(domain), 'demo_db', 'mysql')
    assert stable == (cron.read_text(), batch.read_text())
    # Old installations: retry orphan repair and preserve healthy domains.
    (other / 'config/domain.env').unlink()
    module.cleanup(base, domains)
    assert not batch.exists() and str(other) not in cron.read_text()
    module.cleanup(base, domains)
print('Domain schedule cleanup regression passed')
