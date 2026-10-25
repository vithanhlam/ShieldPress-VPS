#!/usr/bin/env python3
"""Reconnect restored WordPress files to the verified, managed local database."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile


def settings(path):
    values = {}
    for line in path.read_text().splitlines():
        if '=' in line and not line.lstrip().startswith('#'):
            key, value = line.split('=', 1)
            values[key.strip()] = value.strip()
    return values


def connects(values):
    if not values.get('DB_NAME') or not values.get('DB_USER'):
        return False
    def quote(value):
        return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\r', '\\r') + '"'
    with tempfile.NamedTemporaryFile(mode='w', prefix='shieldpress-restore-') as cnf:
        cnf.write('[client]\nhost=localhost\n')
        cnf.write('user=' + quote(values['DB_USER']) + '\npassword=' + quote(values.get('DB_PASS', '')) + '\n')
        cnf.flush()
        result = subprocess.run(['mysql', '--defaults-file=' + cnf.name, '--connect-timeout=5',
                                 '--database=' + values['DB_NAME'], '-Nse', 'SELECT 1'],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return result.returncode == 0


def definition(key):
    # Only rewrite literal definitions. Dynamic configs need manual review.
    return re.compile(r"(?m)^[ \t]*define\s*\(\s*(['\"])" + key +
                      r"\1\s*,\s*(['\"])((?:\\.|(?!\2).)*)\2\s*\)\s*;[^\n]*")


def repair(domain, migration=False, check=False):
    values = settings(domain / 'config/domain.env')
    if values.get('APP_TYPE', 'wordpress') != 'wordpress':
        return
    if values.get('DB_CONNECTION', 'mysql') not in ('mysql', 'mariadb'):
        raise ValueError('WordPress requires a managed MySQL/MariaDB connection')
    if not connects(values):
        raise ValueError('Managed database authentication failed; configuration was not changed')
    if check:
        print('[OK] Managed WordPress database connection verified')
        return
    config = domain / 'public_html/wp-config.php'
    if config.is_symlink() or not config.is_file():
        raise ValueError('Expected a regular wp-config.php file')
    original = config.read_text()
    targets = {'DB_NAME': values['DB_NAME'], 'DB_USER': values['DB_USER'],
               'DB_PASSWORD': values.get('DB_PASS', ''), 'DB_HOST': 'localhost'}
    matches = {key: list(definition(key).finditer(original)) for key in targets}
    if any(len(items) != 1 for items in matches.values()):
        raise ValueError('Unsupported or duplicate WordPress DB definitions; manual review required')
    if migration:
        current = {key: matches[key][0].group(3) for key in targets}
        current['DB_PASS'] = current.pop('DB_PASSWORD')
        # Do not redirect working databases or external database hosts.
        if current['DB_HOST'] not in ('localhost', '127.0.0.1') or connects(current):
            print('[SKIP] WordPress database is working or uses an external host')
            return
    updated = original
    for key, value in targets.items():
        literal = value.replace('\\', '\\\\').replace("'", "\\'")
        updated = definition(key).sub(lambda m: "define('" + key + "', '" + literal + "');", updated)
    if updated != original:
        backup = domain / 'config/wp-config.before-db-repair.php'
        if not backup.exists():
            fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'w') as stream:
                stream.write(original)
        stat = config.stat()
        fd, name = tempfile.mkstemp(prefix='.wp-config-', dir=config.parent)
        try:
            with os.fdopen(fd, 'w') as stream:
                stream.write(updated)
            lint = subprocess.run(['php', '-l', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if lint.returncode != 0:
                raise ValueError('Updated WordPress configuration failed PHP syntax validation')
            os.chmod(name, stat.st_mode & 0o777)
            os.chown(name, stat.st_uid, stat.st_gid)
            os.replace(name, config)
        finally:
            if os.path.exists(name):
                os.unlink(name)
    print('[OK] WordPress DB configuration synchronized; database connection verified')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('domain', type=Path)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--migrate', action='store_true')
    args = parser.parse_args()
    try:
        repair(args.domain, args.migrate, args.check)
    except (OSError, ValueError, subprocess.SubprocessError):
        print('[FAIL] WordPress database repair failed; check managed credentials and literal DB definitions')
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
