#!/usr/bin/env python3
"""Lock control ancestors and rebuild legacy cron jobs from data, never code."""
import argparse
import importlib.util
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import tempfile


def atomic_write(path, content, mode=0o700):
    fd, temp = tempfile.mkstemp(dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, 'w') as stream:
            stream.write(content)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def migrate(base, domains, etc, uid=0, gid=0):
    spec = importlib.util.spec_from_file_location('domain_security', base / 'core/domain-security.py')
    security = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(security)
    pending = []
    if etc.is_symlink() or etc.resolve() != etc.absolute():
        raise ValueError('Configuration directory contains a symlink')
    etc.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not security.trusted(etc.stat(), uid):
        raise ValueError('Untrusted global configuration directory')
    jobs = etc / 'jobs'
    if jobs.is_symlink():
        raise ValueError('Job directory is a symlink')
    jobs.mkdir(mode=0o700, exist_ok=True)
    if not security.trusted(jobs.stat(), uid):
        raise ValueError('Untrusted job directory')
    safe = set()
    for home in sorted(domains.iterdir()):
        if home.is_symlink() or not home.is_dir():
            pending.append(f'Invalid domain directory: {home.name}')
            continue
        # Deployment workspaces are not active domain registry entries.
        # Leave them untouched and never include them in trusted backup jobs.
        if re.fullmatch(r'\.deploy-[A-Za-z0-9_][A-Za-z0-9_-]*-[0-9]{8}-[0-9]{6}', home.name):
            print(f'[SKIP] Deployment staging directory: {home.name}')
            continue
        try:
            security.domain_control(domains, home.name, True, uid, gid)
            security.read_settings(home / 'config/domain.env')
            safe.add(home.name)
        except (OSError, ValueError) as error:
            pending.append(f'{home.name}: {error}')

    cron = subprocess.run(['crontab', '-l'], capture_output=True, text=True)
    if cron.returncode and 'no crontab for' not in cron.stderr.lower():
        raise RuntimeError(f'Cannot read root crontab: {cron.stderr.strip()}')
    saved = etc / 'crontab-before-domain-boundary.txt'
    if not saved.exists():
        atomic_write(saved, cron.stdout, 0o600)
    pattern = re.compile(re.escape(str(domains)) + r'/([A-Za-z0-9_][A-Za-z0-9_-]{0,63})/config/auto-backup-(db|files|full)\.sh')
    lines = []
    for line in cron.stdout.splitlines(keepends=True):
        if line.startswith('# ShieldPress disabled unsafe legacy backup: '):
            original = line.removeprefix('# ShieldPress disabled unsafe legacy backup: ').rstrip('\n')
            old_match = pattern.search(original)
            if not old_match:
                lines.append(line)
                continue
            folder, kind = old_match.groups()
            try:
                words = shlex.split(original, comments=True)
                if folder not in safe or len(words) != 6 or words[5] != old_match.group(0):
                    raise ValueError('Disabled legacy job still needs reconfiguration')
                if any(not re.fullmatch(r'[0-9*/,-]+', word) for word in words[:5]):
                    raise ValueError('Invalid cron schedule')
                old = domains / folder / 'config' / f'auto-backup-{kind}.sh'
                text = old.read_text()
                keep = re.search(r'^RETENTION=([0-9]+)$', text, re.M)
                keep = int(keep[1]) if keep else 1
                if not 1 <= keep <= 60:
                    raise ValueError('Invalid retention')
                mode = re.search(r'^BACKUP_MODE=["\x27]?(full|incremental)["\x27]?$', text, re.M)
                mode = mode[1] if mode else 'full'
                target = jobs / f'{folder}-backup-{kind}.sh'
                command = ['/bin/bash', str(base / 'bin/domain-backup'), folder, kind, mode, str(keep)]
                atomic_write(target, '#!/bin/bash\nexec ' + shlex.join(command) + '\n')
                lines.append(' '.join(words[:5]) + ' ' + shlex.quote(str(target)) + '\n')
            except (OSError, ValueError) as error:
                pending.append(f'{folder}/{kind}: {error}; reconfigure this schedule')
                lines.append(line)
            continue
        if line.lstrip().startswith('#'):
            lines.append(line)
            continue
        match = pattern.search(line)
        if not match:
            lines.append(line)
            continue
        folder, kind = match.groups()
        try:
            words = shlex.split(line, comments=True)
            if folder not in safe or len(words) != 6 or words[5] != match.group(0):
                raise ValueError('Unrecognized or unsafe legacy schedule')
            if any(not re.fullmatch(r'[0-9*/,\-]+', word) for word in words[:5]):
                raise ValueError('Invalid cron schedule')
            old = domains / folder / 'config' / f'auto-backup-{kind}.sh'
            # Parse only these literal settings; do not source or copy old code.
            text = old.read_text()
            keep = re.search(r'^RETENTION=([0-9]+)$', text, re.M)
            keep = int(keep[1]) if keep else 1
            if not 1 <= keep <= 60:
                raise ValueError('Invalid retention')
            mode = re.search(r'^BACKUP_MODE=[\"\x27]?(full|incremental)[\"\x27]?$', text, re.M)
            mode = mode[1] if mode else 'full'
            target = jobs / f'{folder}-backup-{kind}.sh'
            command = ['/bin/bash', str(base / 'bin/domain-backup'), folder, kind, mode, str(keep)]
            atomic_write(target, '#!/bin/bash\nexec ' + shlex.join(command) + '\n')
            lines.append(' '.join(words[:5]) + ' ' + shlex.quote(str(target)) + '\n')
        except (OSError, ValueError) as error:
            # Fail closed: an unsupported job must not keep running site code as root.
            lines.append('# ShieldPress disabled unsafe legacy backup: ' + line.rstrip() + '\n')
            pending.append(f'{folder}/{kind}: {error}; reconfigure this schedule')
    updated = ''.join(lines)
    if updated != cron.stdout:
        result = subprocess.run(['crontab', '-'], input=updated, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(f'Cannot update root crontab: {result.stderr.strip()}')
    atomic_write(etc / 'domain-boundary-pending.txt', ''.join(p + '\n' for p in pending), 0o600)
    for message in pending:
        print(f'[PENDING] {message}', file=sys.stderr)
    if not pending:
        print('[OK] Domain control directories locked; legacy scheduled jobs rebuilt safely')
    return not pending


NGINX_GUARDS = r'''    # ShieldPress application source boundary
    location ~* /(?:\.|wp-config\.php|composer\.(?:json|lock)) { deny all; }
    location ~* ^/wp-content/(?:uploads|cache)/.*\.(?:php[0-9]*|phtml|phar)(?:/|$) { deny all; }

'''


def harden_nginx(directory, uid=0):
    if directory.is_symlink() or directory.resolve() != directory.absolute():
        raise ValueError("Nginx configuration directory is a symlink")
    parent = directory.stat()
    if parent.st_uid != uid or parent.st_mode & 0o022:
        raise ValueError('Untrusted Nginx configuration directory')
    changed = {}
    for path in directory.glob('*.conf'):
        if path.is_symlink():
            raise ValueError(f'Nginx configuration is a symlink: {path.name}')
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd) as stream:
            current = os.fstat(stream.fileno())
            if current.st_uid != uid or not stat.S_ISREG(current.st_mode) or current.st_nlink != 1:
                raise ValueError(f'Untrusted Nginx configuration: {path.name}')
            # Legacy root-owned vhosts can retain mode 666. Lock the opened
            # regular file before reading it; never follow links or change owners.
            if current.st_mode & 0o022:
                os.fchmod(stream.fileno(), stat.S_IMODE(current.st_mode) & 0o755)
                print(f'[OK] Removed group/other write access from Nginx configuration: {path.name}')
            text = stream.read()
        if 'ShieldPress application source boundary' in text or '/public_html' not in text:
            continue
        handler = re.search(r'(?m)^\s*location ~ \\\.php\$ \{', text)
        if not handler:
            continue
        changed[path] = text
        atomic_write(path, text[:handler.start()] + '\n' + NGINX_GUARDS + text[handler.start():], 0o644)
    if not changed:
        return
    result = subprocess.run(['nginx', '-t'], capture_output=True, text=True)
    if result.returncode:
        for path, content in changed.items():
            atomic_write(path, content, 0o644)
        raise RuntimeError('Nginx source protection validation failed; original configurations restored')
    result = subprocess.run(['systemctl', 'reload', 'nginx'], capture_output=True, text=True)
    if result.returncode:
        for path, content in changed.items():
            atomic_write(path, content, 0o644)
        raise RuntimeError('Nginx reload failed; original configurations restored; migration remains pending')
    print(f'[OK] Protected executable uploads and sensitive source paths in {len(changed)} vhost(s)')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', type=Path, default=Path('/opt/shieldpress'))
    parser.add_argument('--domains', type=Path, default=Path('/home/domains'))
    parser.add_argument('--etc', type=Path, default=Path('/etc/shieldpress'))
    parser.add_argument('--nginx', type=Path, default=Path('/etc/nginx/conf.d'))
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise ValueError('Migration requires root')
    complete = migrate(args.base, args.domains, args.etc)
    if complete:
        harden_nginx(args.nginx)
    return 0 if complete else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError) as error:
        print(f'[FAIL] Domain boundary migration remains pending: {error}', file=sys.stderr)
        sys.exit(1)
