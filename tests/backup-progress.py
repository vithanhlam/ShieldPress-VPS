#!/usr/bin/env python3
"""Backup progress integrity, calibrated estimates and cross-stack archives."""
from pathlib import Path
import os
import subprocess
import tempfile
import tarfile

ROOT = Path(__file__).resolve().parents[1] / 'shieldpress'
helper = (ROOT / 'modules/backup/_backup_helper.sh').read_text()
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    fixture = root / 'helper.sh'
    fixture.write_text(helper.replace('source "$BASE_DIR/core/paths.sh"', ':').replace(
        'LOG_FILE="$LOG_DIR/backup.log"', f'LOG_DIR="{root}"\nLOG_FILE="$LOG_DIR/backup.log"'))
    payload = os.urandom(2 * 1024 * 1024)
    result = subprocess.run(['python3', str(ROOT / 'modules/backup/stream-progress.py'), str(len(payload))],
                            input=payload, capture_output=True, check=True)
    assert result.stdout == payload and not result.stderr
    script = f'''source "{fixture}"
DATA_DIR="{root}/data"
BASE_DIR="{ROOT}"
DOMAIN_PATH="{root}/domain"
BK_ENABLED=1
BK_CUSTOM_PATHS=""
BK_CUSTOM_EXCLUDE=""
# The new helper is installed by the existing source-directory update handoff.
# No persisted config or one-time marker is needed; repeated loads are safe.
record_backup_timing tar_gz 160 "$(( $(date +%s) - 10 ))"
[ "$(estimate_seconds 320 tar_gz)" = 20 ] || exit 10
source "{fixture}"
BASE_DIR="{ROOT}"
[ "$(estimate_seconds 320 tar_gz)" = 20 ] || exit 11
# Exercise the no-pv path explicitly, independently of host packages.
backup_progress_available() {{ return 0; }}
backup_stream_progress() {{ python3 "$BASE_DIR/modules/backup/stream-progress.py" "$1"; }}
for APP_TYPE in wordpress php laravel nodejs; do
    archive_source_to_file "{root}/$APP_TYPE.tar.gz" || exit 12
done
'''
    (root / 'domain/public_html').mkdir(parents=True)
    (root / 'domain/public_html/content.txt').write_text('backup payload')
    subprocess.run(['bash', '-c', script], check=True, capture_output=True)
    for stack in ('wordpress', 'php', 'laravel', 'nodejs'):
        with tarfile.open(root / f'{stack}.tar.gz') as archive:
            name = 'public_html/content.txt' if stack in ('wordpress', 'php') else './content.txt'
            assert archive.extractfile(name).read() == b'backup payload'
print('PASS: stream integrity, quiet logs, repeat upgrade loads, calibrated ETA, four application stacks')
