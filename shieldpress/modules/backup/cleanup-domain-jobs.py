#!/usr/bin/env python3
"""Remove managed schedules without evaluating generated shell scripts."""
import argparse
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile


def atomic_write(path, content):
    fd, temp = tempfile.mkstemp(dir=path.parent)
    try:
        os.fchmod(fd, path.stat().st_mode & 0o777)
        with os.fdopen(fd, 'w') as stream:
            stream.write(content)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def tokens(line):
    return shlex.split(line, comments=True)


def cleanup(base, domains, domain=None, db='', engine='', etc=Path('/etc/shieldpress')):
    domain = str(Path(domain)) if domain else ''
    removed = set()
    updates = {}
    directory = base / 'config/auto-backup'
    for script in directory.glob('*.sh'):
        content = script.read_text()
        lines = content.splitlines(keepends=True)
        if script.name in ('auto-backup-full-db-batch.sh', 'auto-backup-file-batch.sh'):
            inside = False
            kept = []
            count = 0
            changed = False
            for line in lines:
                if line.strip() == 'JOBS=(':
                    inside = True
                elif inside and line.strip() == ')':
                    inside = False
                elif inside:
                    values = tokens(line)
                    if len(values) != 1:
                        raise ValueError(f'Unrecognized batch entry in {script}')
                    fields = values[0].split('|')
                    is_db = script.name == 'auto-backup-full-db-batch.sh'
                    if len(fields) != 3:
                        raise ValueError(f'Unrecognized batch entry in {script}')
                    path = fields[2] if is_db else fields[0]
                    matches = bool(domain and path and str(Path(path)) == domain)
                    matches |= bool(is_db and db and fields[:2] == [engine, db])
                    stale = bool(path and Path(path).is_relative_to(domains) and not (Path(path) / 'config/domain.env').is_file())
                    if matches or stale:
                        changed = True
                        continue
                    count += 1
                kept.append(line)
            if changed:
                if count:
                    updates[script] = ''.join(kept)
                else:
                    removed.add(script)
        elif domain:
            settings = {}
            for line in lines:
                if re.match(r'^(DB_NAME|DB_CONNECTION|DOMAIN|BACKUP_DIR)=', line):
                    value = tokens(line)
                    if len(value) == 1:
                        key, val = value[0].split('=', 1)
                        settings[key] = val
            saved_engine = settings.get('DB_CONNECTION', '')
            saved_engine = {'mariadb': 'mysql', 'postgres': 'pgsql', 'postgresql': 'pgsql'}.get(saved_engine, saved_engine)
            backup_path = settings.get('BACKUP_DIR', '')
            if (backup_path and (backup_path == domain or backup_path.startswith(domain + '/'))) or (db and settings.get('DB_NAME') == db and saved_engine == engine):
                removed.add(script)

    # Centralized domain wrappers contain no embedded credentials or site code.
    for script in (etc / 'jobs').glob('*-backup-*.sh'):
        match = re.fullmatch(r'([A-Za-z0-9_][A-Za-z0-9_-]*)-backup-(db|files|full)\.sh', script.name)
        if not match:
            continue
        home = domains / match[1]
        if (domain and str(home) == domain) or not (home / 'config/domain.env').is_file():
            removed.add(script)

    cron = subprocess.run(['crontab', '-l'], capture_output=True, text=True)
    if cron.returncode and 'no crontab for' not in cron.stderr.lower():
        raise RuntimeError(f'Cannot read crontab: {cron.stderr.strip()}')
    kept = []
    for line in cron.stdout.splitlines(keepends=True):
        words = tokens(line)
        drop = any(str(script) in words for script in removed)
        for word in words:
            # Compare complete path components, so similarly named domains survive.
            if domain and (word == domain or word.startswith(domain + '/')):
                drop = True
            if word.startswith(str(domains) + '/'):
                relative = word[len(str(domains)) + 1:]
                home = domains / relative.split('/')[0]
                if not (home / 'config/domain.env').is_file():
                    drop = True
        runner = str(base / 'bin/laravel-pg-backup')
        if domain and db and engine == 'pgsql' and runner in words:
            index = words.index(runner)
            if words[index + 1:index + 2] == [db]:
                drop = True
        if not drop:
            kept.append(line)
    # Install the filtered cron first; abort deletion if installation fails.
    if ''.join(kept) != cron.stdout:
        subprocess.run(['crontab', '-'], input=''.join(kept), text=True, check=True)
    for script, content in updates.items():
        atomic_write(script, content)
    for script in removed:
        script.unlink()
    print(f'[OK] Backup cleanup: {len(updates)} batch job(s) updated, {len(removed)} script(s) removed; stale domain cron entries removed.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--base', type=Path, required=True)
    parser.add_argument('--domains', type=Path, required=True)
    parser.add_argument('--domain')
    parser.add_argument('--etc', type=Path, default=Path(os.environ.get('ETC_DIR', '/etc/shieldpress')))
    parser.add_argument('--db', default='')
    parser.add_argument('--engine', default='')
    args = parser.parse_args()
    try:
        cleanup(args.base, args.domains, args.domain, args.db, args.engine, args.etc)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'[FAIL] Backup cleanup: {error}\n')
