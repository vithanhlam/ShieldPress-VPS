#!/usr/bin/env python3
"""Move one tracked, single-instance root PM2 app to its domain account."""
import argparse
import fcntl
import http.client
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import signal
import subprocess
import tempfile
import time


LOG_FILE = None


def run(argv, env=None, timeout=60):
    result = subprocess.run(argv, env=env, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=timeout, cwd='/tmp')
    if LOG_FILE:
        with LOG_FILE.open('a') as log:
            log.write(json.dumps(argv) + '\n' + result.stdout + result.stderr + '\n')
    if result.returncode:
        # PM2 output can contain application secrets; never echo it to the menu.
        raise RuntimeError('Command failed: ' + ' '.join(argv[:3]))
    return result.stdout


def pm2_apps(output):
    # A first invocation can print a daemon startup banner before the JSON.
    for i, char in enumerate(output):
        if char == '[':
            try:
                value, _ = json.JSONDecoder().raw_decode(output[i:])
                if isinstance(value, list) and all(isinstance(a, dict) for a in value):
                    return value
            except ValueError:
                pass
    raise RuntimeError('PM2 returned an invalid process list.')


def ecosystem(app, name, home=None):
    e = app['pm2_env']
    if e.get('exec_mode') != 'fork_mode' or e.get('instances', 1) not in (None, 1):
        raise RuntimeError('Only single-instance fork apps can be migrated automatically.')
    if e.get('watch'):
        raise RuntimeError('Disable PM2 watch before migrating this app.')
    config = {'name': name, 'script': e['pm_exec_path'], 'cwd': e['pm_cwd'],
              'exec_mode': 'fork', 'instances': 1}
    for key in ('args', 'node_args', 'interpreter_args', 'autorestart', 'max_memory_restart',
                'restart_delay', 'exp_backoff_restart_delay', 'min_uptime', 'max_restarts',
                'kill_timeout', 'listen_timeout', 'wait_ready', 'shutdown_with_message',
                'merge_logs', 'time', 'log_date_format'):
        if key in e:
            config[key] = e[key]
    config['interpreter'] = e.get('exec_interpreter', 'node')
    config['env'] = dict(e.get('env', {}))
    if home:
        for key in list(config['env']):
            if key.startswith('PM2_') or key in ('SUDO_USER', 'SUDO_UID', 'SUDO_GID', 'SUDO_COMMAND'):
                config['env'].pop(key)
        config['env'].update(HOME=home, USER=name, LOGNAME=name)
    else:
        for src, dst in (('pm_out_log_path', 'out_file'), ('pm_err_log_path', 'error_file')):
            if e.get(src):
                config[dst] = e[src]
    return {'apps': [config]}


def http_status(port, host):
    conn = http.client.HTTPConnection('127.0.0.1', port, timeout=3)
    try:
        conn.request('GET', '/', headers={'Host': host})
        return conn.getresponse().status
    finally:
        conn.close()


def owns_listener(pid, port):
    """Verify the HTTP port belongs to this PM2 process or one of its children."""
    if not pid:
        return False
    parents = {}
    for proc in Path('/proc').glob('[0-9]*'):
        try:
            parents[int(proc.name)] = int((proc / 'stat').read_text().rsplit(') ', 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            continue
    descendants = {pid}
    while True:
        found = {child for child, parent in parents.items() if parent in descendants}
        if found.issubset(descendants):
            break
        descendants.update(found)
    sockets = set()
    for table in ('tcp', 'tcp6'):
        for line in Path('/proc/net', table).read_text().splitlines()[1:]:
            fields = line.split()
            if fields[3] == '0A' and int(fields[1].split(':')[1], 16) == port:
                sockets.add('socket:[' + fields[9] + ']')
    for child in descendants:
        for fd in Path('/proc', str(child), 'fd').glob('*'):
            try:
                if os.readlink(fd) in sockets:
                    return True
            except OSError:
                pass
    return False


def ownership(root):
    paths = [root]
    for directory, dirs, files in os.walk(root, followlinks=False):
        paths.extend(Path(directory) / name for name in dirs + files)
    records = []
    for path in paths:
        st = path.lstat()
        # Do not touch linked files or files shared through hard links.
        if path.is_symlink():
            if not path.resolve().is_relative_to(root.resolve()):
                raise RuntimeError('App has a symlink outside public_html; review permissions manually.')
            continue
        if path.is_file() and st.st_nlink > 1:
            raise RuntimeError('App has hardlinked files; review permissions manually.')
        records.append((str(path), st.st_uid, st.st_gid, st.st_mode & 0o7777))
    return records


def migrate(name, port, host, yes=False):
    if os.geteuid() != 0:
        raise RuntimeError('Run this migration as root.')
    user = pwd.getpwnam(name)
    home = Path('/home/domains') / name
    appdir = home / 'public_html'
    if user.pw_uid == 0 or Path(user.pw_dir) != home or home.is_symlink() or appdir.is_symlink():
        raise RuntimeError('Domain account/home mismatch; fix the domain account first.')
    if not appdir.is_dir():
        raise RuntimeError('Domain application directory is missing.')
    pm2 = shutil.which('pm2')
    if not pm2:
        raise RuntimeError('PM2 is not installed.')
    env = {'PATH': os.environ.get('PATH', '/usr/local/bin:/usr/bin:/bin'),
           'HOME': '/root', 'PM2_HOME': '/root/.pm2'}
    target_env = dict(env, HOME=str(home), USER=name, LOGNAME=name, PM2_HOME=str(home / '.pm2'))

    def root_pm2(*args):
        return run([pm2, *args], env)

    def user_pm2(*args):
        return run(['runuser', '-u', name, '--', pm2, *args], target_env,
                   timeout=5 if args == ('jlist',) else 60)

    def matches(output):
        return [a for a in pm2_apps(output) if a.get('name') == name]

    source_list = root_pm2('jlist')
    source = matches(source_list)
    if not source:
        print('[OK] No root PM2 app with this domain name; nothing to migrate.')
        return
    if len(source) != 1 or source[0]['pm2_env'].get('status') != 'online':
        raise RuntimeError('Expected one online root PM2 process; check Running Apps first.')
    source = source[0]
    if Path(source['pm2_env']['pm_cwd']).resolve() != appdir.resolve():
        raise RuntimeError('Root PM2 working directory does not match the selected domain.')
    target = ecosystem(source, name, str(home))
    original = ecosystem(source, name)
    if not owns_listener(source.get('pid', 0), port):
        raise RuntimeError('Configured HTTP port does not belong to the selected root PM2 app.')
    baseline = http_status(port, host)
    if baseline >= 500:
        raise RuntimeError('Existing app returns HTTP 5xx; fix its health before migration.')
    records = ownership(appdir)
    pmhome = home / '.pm2'
    if pmhome.is_symlink():
        raise RuntimeError('PM2 home must not be a symlink.')
    pmhome.mkdir(mode=0o700, exist_ok=True)
    if pmhome.stat().st_uid not in (0, user.pw_uid):
        raise RuntimeError('PM2 home belongs to another account.')
    os.chown(pmhome, user.pw_uid, user.pw_gid)
    if pm2_apps(user_pm2('jlist')):
        raise RuntimeError('Target user already has PM2 apps; nothing was stopped.')
    print(f'Migrate {host}: root PM2 -> {name}. The app will briefly restart.')
    if not yes and input('Continue? [y/N]: ').strip().lower() != 'y':
        print('Cancelled.')
        return
    backup_root = Path('/var/shieldpress/data/pm2-migrations')
    backup_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    backup = Path(tempfile.mkdtemp(prefix=name + '-', dir=backup_root))
    global LOG_FILE
    LOG_FILE = backup / 'commands.log'
    (backup / 'root-jlist.json').write_text(source_list)
    (backup / 'original.json').write_text(json.dumps(original))
    (backup / 'ownership.json').write_text(json.dumps(records))
    target_path = pmhome / ('shieldpress-migrate-' + backup.name + '.json')
    # Exclusive creation avoids overwriting or following user-controlled paths.
    with target_path.open('x') as f:
        json.dump(target, f)
    os.chown(target_path, user.pw_uid, user.pw_gid)
    os.chmod(target_path, 0o600)
    def wait_healthy():
        stable = 0
        last_pid = None
        for _ in range(30):
            try:
                apps = matches(user_pm2('jlist'))
            except (RuntimeError, subprocess.TimeoutExpired):
                stable = 0
                time.sleep(1)
                continue
            if len(apps) == 1:
                a = apps[0]
                pid = a.get('pid', 0)
                try:
                    healthy = (a['pm2_env'].get('status') == 'online' and pid > 0
                               and Path(f'/proc/{pid}').stat().st_uid == user.pw_uid
                               and owns_listener(pid, port)
                               and http_status(port, host) == baseline)
                except (OSError, http.client.HTTPException):
                    healthy = False
                stable = stable + 1 if healthy and pid == last_pid else 0
                last_pid = pid
                if stable >= 3:
                    break
            else:
                stable = 0
            time.sleep(1)
        else:
            raise RuntimeError('App did not remain healthy under the domain user.')

    stopped = False
    committed = False
    service = f'pm2-{name}.service'
    was_enabled = subprocess.run(['systemctl', 'is-enabled', '--quiet', service], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    startup_attempted = False
    dropin = Path('/etc/systemd/system') / (service + '.d') / 'shieldpress-foreground.conf'
    previous_dropin = dropin.read_bytes() if dropin.exists() else None
    unit = Path('/etc/systemd/system') / service
    previous_unit = unit.read_bytes() if unit.exists() else None
    try:
        # Capture root PM2's original reboot list before changing anything.
        root_pm2('save', '--force')
        stopped = True
        root_pm2('stop', name)
        root_pm2('save', '--force')
        for path, uid, gid, mode in records:
            os.chown(path, user.pw_uid, user.pw_gid, follow_symlinks=False)
        user_pm2('start', str(target_path), '--only', name)
        wait_healthy()
        user_pm2('save', '--force')
        startup_attempted = True
        root_pm2('startup', 'systemd', '-u', name, '--hp', str(home))
        # Foreground supervision avoids SELinux-denied PID files in user homes.
        # No other apps exist in this user's daemon (checked before migration).
        dropin.parent.mkdir(parents=True, exist_ok=True)
        dropin.write_text('[Service]\nType=simple\nPIDFile=\nExecStart=\n'
                          + 'ExecStart=' + str(Path(pm2).resolve()) + ' resurrect --no-daemon\n')
        run(['systemctl', 'daemon-reload'])
        user_pm2('kill')
        run(['systemctl', 'reset-failed', service])
        run(['systemctl', 'restart', service])
        run(['systemctl', 'is-active', '--quiet', service])
        run(['systemctl', 'is-enabled', '--quiet', service])
        wait_healthy()
        root_pm2('delete', name)
        root_pm2('save', '--force')
        committed = True
        print(f'[OK] {host} now runs as {name}; HTTP health and startup persistence verified.')
    except BaseException:
        print('[WARN] Migration failed; restoring root PM2 app...')
        # Continue all rollback steps even if one fails; report incomplete recovery.
        errors = []
        def restore(action):
            try:
                action()
            except Exception as error:
                errors.append(str(error))
        if startup_attempted:
            restore(lambda: run(['systemctl', 'stop', service]))
        def remove_target():
            if matches(user_pm2('jlist')):
                user_pm2('delete', name)
        restore(remove_target)
        restore(lambda: user_pm2('save', '--force'))
        for path, uid, gid, mode in records:
            if os.path.lexists(path):
                restore(lambda p=path, u=uid, g=gid: os.chown(p, u, g, follow_symlinks=False))
                restore(lambda p=path, m=mode: os.chmod(p, m, follow_symlinks=False))
        if stopped:
            def restart_original():
                if matches(root_pm2('jlist')):
                    root_pm2('restart', name)
                else:
                    root_pm2('start', str(backup / 'original.json'), '--only', name)
                root_pm2('save', '--force')
                for _ in range(20):
                    try:
                        if http_status(port, host) == baseline:
                            return
                    except (OSError, http.client.HTTPException):
                        pass
                    time.sleep(1)
                raise RuntimeError('Original app failed HTTP recovery check')
            restore(restart_original)
        if startup_attempted:
            if previous_dropin is None:
                restore(lambda: dropin.unlink(missing_ok=True))
            else:
                restore(lambda: dropin.write_bytes(previous_dropin))
            if previous_unit is not None:
                restore(lambda: unit.write_bytes(previous_unit))
            restore(lambda: run(['systemctl', 'daemon-reload']))
            if not was_enabled:
                restore(lambda: run(['systemctl', 'disable', service]))
        if errors:
            (backup / 'rollback-errors.txt').write_text('\n'.join(errors))
            print('[FAIL] Rollback needs attention. Recovery files: ' + str(backup))
        else:
            print('[OK] Original root PM2 app restored. Recovery files: ' + str(backup))
        raise
    finally:
        target_path.unlink(missing_ok=True)
        (backup / 'result.txt').write_text('success\n' if committed else 'failed; inspect rollback output\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('user')
    parser.add_argument('port', type=int)
    parser.add_argument('domain')
    parser.add_argument('--yes', action='store_true')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_-]*', args.user) or not 1024 <= args.port <= 65535:
        parser.error('Invalid domain user or port (must be 1024-65535).')
    os.umask(0o077)
    # Serialize migrations: root PM2's saved list is shared by all domains.
    with open('/run/shieldpress-pm2-migrate.lock', 'w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Another PM2 migration is running.')
        signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
        migrate(args.user, args.port, args.domain, args.yes)


if __name__ == '__main__':
    try:
        main()
    except (Exception, KeyboardInterrupt) as error:
        print('[FAIL] ' + str(error))
        raise SystemExit(1)
