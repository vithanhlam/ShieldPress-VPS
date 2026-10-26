#!/usr/bin/env python3
"""Protect control files from application users; never evaluate domain settings."""
import argparse
import os
from pathlib import Path
import re
import pwd
import stat
import sys

KEYS = set('DOMAIN CLEAN_DOMAIN SYSTEM_USER APP_TYPE ROOT DB_CONNECTION DB_NAME DB_USER DB_PASS PHP_VERSION NODE_APP_PORT NODE_ENTRY SSL SSL_TYPE CREATED SFTP SFTP_PORT SFTP_USER SFTP_PASS NODE_PORT PM2_NAME NODE_VERSION NODE_START_COMMAND NODE_PACKAGE_MANAGER NODE_ENV DOCUMENT_ROOT'.split())
# Written by the managed Meilisearch key menu on existing installations.
KEYS.update('MEILI_HOST MEILI_INDEX MEILI_KEY MEILI_KEY_UID MEILI_KEY_EXPIRES_AT'.split())


def directory(path):
    return os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)


def trusted(st, uid=0):
    return st.st_uid == uid and not st.st_mode & 0o022


def control_tree(fd, repair=False, uid=0, gid=0):
    if repair:
        os.fchown(fd, uid, gid)
        os.fchmod(fd, 0o700)
    if not trusted(os.fstat(fd), uid):
        raise ValueError('Control directory is writable by an application user')
    for name in os.listdir(fd):
        st = os.stat(name, dir_fd=fd, follow_symlinks=False)
        if stat.S_ISDIR(st.st_mode):
            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            try:
                control_tree(child, repair, uid, gid)
            finally:
                os.close(child)
        elif stat.S_ISREG(st.st_mode) and st.st_nlink == 1:
            child = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
            try:
                current = os.fstat(child)
                if (st.st_dev, st.st_ino) != (current.st_dev, current.st_ino) or current.st_nlink != 1:
                    raise ValueError('Control file changed during validation')
                if repair:
                    os.fchown(child, uid, gid)
                    os.fchmod(child, 0o700 if name.endswith('.sh') else 0o600)
                elif not trusted(current, uid):
                    raise ValueError(f'Untrusted control file: {name}')
            finally:
                os.close(child)
        else:
            raise ValueError(f'Symlink, hardlink or special file in control tree: {name}')


def domain_control(root, folder, repair=False, uid=0, gid=0):
    if not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_-]{0,63}', folder):
        raise ValueError('Invalid domain directory name')
    if root.is_symlink() or root.resolve() != root.absolute():
        raise ValueError('Domain registry must not contain symlinks')
    parent = directory(root)
    try:
        if not trusted(os.fstat(parent), uid):
            raise ValueError('Untrusted domain registry directory')
        fd = os.open(folder, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
        try:
            if repair:
                os.fchown(fd, uid, gid)
                os.fchmod(fd, 0o755)
            elif not trusted(os.fstat(fd), uid):
                raise ValueError('Domain parent is writable by the application user')
            for name in ('config', 'backup'):
                if repair:
                    try:
                        os.mkdir(name, 0o700, dir_fd=fd)
                    except FileExistsError:
                        pass
                child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                try:
                    if repair or name == "config":
                        control_tree(child, repair, uid, gid)
                    elif not trusted(os.fstat(child), uid):
                        raise ValueError("Backup directory is writable by the application user")
                finally:
                    os.close(child)
        finally:
            os.close(fd)
    finally:
        os.close(parent)


def read_settings(path):
    result = {}
    for number, line in enumerate(path.read_text().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        key, sep, value = line.partition('=')
        if not sep or key not in KEYS:
            if sep and re.fullmatch(r'[A-Z_][A-Z0-9_]{0,63}', key):
                raise ValueError(f'Unsupported setting {key} at line {number}')
            raise ValueError(f'Unsupported setting at line {number}')
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if any(ord(c) < 32 for c in value) or key in result:
            raise ValueError(f'Invalid or duplicate setting: {key}')
        result[key] = value
    user = result.get('SYSTEM_USER', '')
    # Legacy domain creation uses CLEAN_DOMAIN, which can start with a digit.
    # Reject numeric-only names so account tools cannot interpret them as UIDs.
    if user and (not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_-]{0,31}', user)
                 or user.isdigit() or user == 'root'):
        raise ValueError('Invalid application user')
    if user:
        try:
            if pwd.getpwnam(user).pw_uid == 0:
                raise ValueError('Application user must not have UID zero')
        except KeyError:
            pass  # Missing users are handled by the account repair workflow.
    domain = result.get('DOMAIN', '')
    if domain and (not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]*', domain) or '..' in domain):
        raise ValueError('Invalid domain name')
    if result.get('CLEAN_DOMAIN') and result['CLEAN_DOMAIN'] != path.parent.parent.name:
        raise ValueError('Domain directory metadata does not match its location')
    if result.get('APP_TYPE', '') not in ('', 'wordpress', 'laravel', 'nodejs', 'php'):
        raise ValueError('Unsupported application stack')
    if result.get('DB_CONNECTION', '') not in ('', 'none', 'mysql', 'mariadb', 'pgsql', 'postgres', 'postgresql'):
        raise ValueError('Unsupported database engine')
    if result.get('SSL_TYPE', '') not in ('', 'letsencrypt', 'zerossl', 'cloudflare', 'custom'):
        raise ValueError('Unsupported SSL provider')
    if result.get('PHP_VERSION') and not re.fullmatch(r'[0-9]+\.[0-9]+', result['PHP_VERSION']):
        raise ValueError('Invalid PHP version')
    if result.get('ROOT'):
        app = path.parent.parent / 'public_html'
        if app.is_symlink() or not Path(result['ROOT']).is_absolute() or not Path(result['ROOT']).resolve().is_relative_to(app.resolve()):
            raise ValueError('Document root escapes the application directory')
    for key in ('DB_NAME', 'DB_USER'):
        if result.get(key) and not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.@-]*', result[key]):
            raise ValueError(f'Invalid database identifier: {key}')
    return result


def backup_targets(root, csv):
    root = root.resolve(strict=True)
    result = []
    for item in csv.split(','):
        item = item.strip()
        if not item:
            continue
        path = Path(item)
        if path.is_absolute() or '..' in path.parts or item.startswith('-') or '\n' in item or '\0' in item:
            raise ValueError('Backup path escapes the application directory')
        resolved = (root / path).resolve(strict=True)
        if not resolved.is_relative_to(root):
            raise ValueError('Backup path follows a symlink outside the application directory')
        result.append(item)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('repair', 'check', 'env', 'targets'))
    parser.add_argument('root', type=Path)
    parser.add_argument('value')
    args = parser.parse_args()
    if args.action == 'targets':
        values = backup_targets(args.root, args.value)
    else:
        domain_control(args.root, args.value, args.action == 'repair')
        values = []
        if args.action == 'env':
            settings = read_settings(args.root / args.value / 'config/domain.env')
            for key in sorted(KEYS):
                values.extend((key, settings.get(key, '')))
    for value in values:
        sys.stdout.buffer.write(value.encode() + b'\0')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as error:
        print(f'[FAIL] Domain security: {error}', file=sys.stderr)
        sys.exit(1)
