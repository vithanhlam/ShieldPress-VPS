#!/usr/bin/env python3
"""Manual uploads require explicit opt-in after successful local backup."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1] / 'shieldpress/modules/backup'
helper = (ROOT / '_backup_helper.sh').read_text()
function = 'confirm_remote_upload_backup(){' + helper.split('confirm_remote_upload_backup(){', 1)[1].split('\n}\n', 1)[0] + '\n}\n'
for enabled, remotes, answer, upload in [
    ('1', 'drive,sftp:', '\n', False),
    ('1', 'drive,sftp:', '', False),
    ('1', 'drive,sftp:', 'n\n', False),
    ('1', 'drive,sftp:', 'invalid\n', False),
    ('1', 'drive,sftp:', 'y\n', True),
    ('1', 'drive,sftp:', 'YeS\n', True),
    ('0', 'drive', 'y\n', False),
    ('1', '', 'y\n', False),
]:
    script = f'''load_remote_config() {{ REMOTE_ENABLED={enabled}; RCLONE_REMOTES='{remotes}'; RCLONE_PATH=backups; }}
remote_upload_backup() {{ printf 'UPLOAD:%s:%s:%s\\n' "$1" "$2" "$3"; return "${{UPLOAD_STATUS:-0}}"; }}
{function}
confirm_remote_upload_backup /tmp/local.tar.gz full example.com
'''
    result = subprocess.run(['bash', '-c', script], input=answer, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    assert ('UPLOAD:/tmp/local.tar.gz:full:example.com' in result.stdout) == upload
    if enabled == '1' and remotes:
        assert 'drive:backups/example.com/full' in result.stdout
    if upload:
        failure = subprocess.run(['bash', '-c', 'UPLOAD_STATUS=1\n' + script], input=answer,
                                 text=True, capture_output=True)
        assert failure.returncode == 1
for name in ('backup-full.sh', 'backup-files.sh', 'backup-db.sh'):
    text = (ROOT / name).read_text()
    assert text.index('BACKUP COMPLETED') < text.index('confirm_remote_upload_backup "')
    assert '\nremote_upload_backup "' not in text
assert 'confirm_remote_upload_backup' not in (ROOT / 'auto-backup-full.sh').read_text()
print('PASS: default no, EOF, rejection, affirmative answers, configured destinations, failure status, post-backup prompts')
