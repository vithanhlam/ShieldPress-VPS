#!/usr/bin/env python3
"""Bounded, report-only YARA scans of registered domain source directories."""
import argparse
import datetime as dt
import fcntl
import errno
import json
import os
from pathlib import Path
import resource
import shutil
import stat
import subprocess
import sys
import tempfile
import time

BASE = Path(os.environ.get('BASE_DIR', '/opt/shieldpress'))
DOMAINS = Path(os.environ.get('DOMAINS_ROOT', '/home/domains'))
REPORTS = Path(os.environ.get('LOG_DIR', '/var/shieldpress/logs')) / 'yara'
CONFIG = Path(os.environ.get('ETC_DIR', '/etc/shieldpress')) / 'yara.json'
UNITS = Path(os.environ.get('YARA_UNIT_DIR', '/etc/systemd/system'))
RULES = BASE / 'modules/security/yara-rules/webshell.yar'
ACTIVE_PROGRESS = None


class ScanProgress:
    def __init__(self):
        self.started = time.monotonic()
        self.last = 0
        self.total = 0
        self.done = 0
        self.stage = "Preparing scan"
        self.frame = 0

    def tick(self, force=False):
        now = time.monotonic()
        interactive = sys.stdout.isatty()
        if not force and now - self.last < (0.2 if interactive else 10):
            return
        self.last = now
        elapsed = now - self.started
        eta = (f"~{max(0, round(elapsed / self.done * (self.total - self.done)))}s"
               if self.done and self.total else "estimating as files are processed")
        frame = "|/-" + chr(92)
        text = (f"[{frame[self.frame % 4]}] {self.stage} | "
                f"Processed: {self.done}/{self.total or '?'} files | ETA: {eta}")
        self.frame += 1
        print(("\r\033[K" if interactive else "") + text,
              end="" if interactive else "\n", flush=True)

    def clear(self):
        if sys.stdout.isatty():
            print("\r\033[K", end="", flush=True)


DEFAULTS = dict(max_file_mb=16, memory_mb=256, timeout_seconds=900,
                per_file_seconds=5, report_retention=30, notify=False)


def load_config():
    config = dict(DEFAULTS)
    if CONFIG.exists():
        config.update(json.loads(CONFIG.read_text()))
    for key, low, high in [('max_file_mb', 1, 128), ('memory_mb', 128, 1024),
                           ('timeout_seconds', 10, 7200), ('per_file_seconds', 1, 30),
                           ('report_retention', 1, 365)]:
        if type(config[key]) is not int or not low <= config[key] <= high:
            raise ValueError(f'Invalid {key}: expected {low}..{high}')
    if type(config['notify']) is not bool:
        raise ValueError('Invalid notify: expected true or false')
    return config


def domains():
    result = {}
    for path in sorted(DOMAINS.iterdir()):
        if path.is_symlink() or not path.is_dir():
            continue
        env = path / 'config/domain.env'
        if not env.is_file():
            continue
        values = {}
        for line in env.read_text(errors='replace').splitlines():
            key, sep, value = line.partition('=')
            if sep and key in ('DOMAIN', 'APP_TYPE'):
                values[key] = value.strip().strip('"\'')
        if values.get('DOMAIN'):
            result[path.name] = (path, values['DOMAIN'], values.get('APP_TYPE', 'unknown'))
    return result


def limits(memory_mb):
    def apply():
        memory = memory_mb * 1024 * 1024
        resource.setrlimit(resource.RLIMIT_AS, (memory, memory))
        resource.setrlimit(resource.RLIMIT_FSIZE, (1024 * 1024, 1024 * 1024))
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        os.nice(15)
    return apply


def run_engine(args, memory_mb, timeout, pass_fds=()):
    # Temporary files cap scanner output without accumulating it in RAM.
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        try:
            proc = subprocess.Popen(args, stdout=out, stderr=err,
                                    pass_fds=pass_fds, preexec_fn=limits(memory_mb))
            end = time.monotonic() + timeout
            try:
                while proc.poll() is None:
                    if ACTIVE_PROGRESS:
                        ACTIVE_PROGRESS.tick()
                    remaining = end - time.monotonic()
                    if remaining <= 0:
                        raise subprocess.TimeoutExpired(args, timeout)
                    try:
                        proc.wait(timeout=min(0.2, remaining))
                    except subprocess.TimeoutExpired:
                        pass
            except BaseException:
                proc.kill()
                proc.wait()
                raise
        except subprocess.TimeoutExpired:
            return 124, '', 'YARA timeout'
        out.seek(0)
        err.seek(0)
        return proc.returncode, out.read(1024 * 1024).decode(errors='replace'), err.read(4096).decode(errors='replace')


def save_report(report, config):
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
    path = REPORTS / f'scan-{stamp}.json'
    path.write_text(json.dumps(report, indent=2) + '\n')
    path.chmod(0o600)
    # Delete only this scanner's own reports, never target files.
    previous = sorted(REPORTS.glob('scan-*.json'), reverse=True)
    for old in previous[config['report_retention']:]:
        old.unlink()
    print(f"[REPORT] {path}")
    print(f"[{report['status']}] Matches: {report['matches']} | Scanned: {report['scanned']} | "
          f"Skipped: {report['skipped']} | Errors: {report['errors']}")
    if config['notify']:
        body = (f"Status: {report['status']} | Matches: {report['matches']} | "
                f"Scanned: {report['scanned']} | Skipped: {report['skipped']} | Errors: {report['errors']}\n"
                f"Local report: {path}\nReview findings locally; no files were modified.")
        notifier = BASE / 'modules/notification/telegram-notify.sh'
        try:
            result = subprocess.run(['bash', str(notifier), 'send', 'security_alert',
                                     'YARA scan report', body], timeout=25, capture_output=True)
            if result.returncode:
                print('[WARN] Notification delivery failed; local report retained.', file=sys.stderr)
        except (OSError, subprocess.TimeoutExpired):
            print('[WARN] Notification delivery failed; local report retained.', file=sys.stderr)
    return path


def scan(selection, config):
    global ACTIVE_PROGRESS
    REPORTS.mkdir(parents=True, exist_ok=True, mode=0o700)
    REPORTS.chmod(0o700)
    with (REPORTS / '.scan.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('[WARN] A YARA scan is already running.', file=sys.stderr)
            return 2
        report = dict(started=dt.datetime.now(dt.timezone.utc).isoformat(), status='INCOMPLETE',
                      scanned=0, skipped=0, errors=0, matches=0, domains=[],
                      scope='Registered public_html trees; regular files only; no archive extraction',
                      warning='No matches does not prove a website is clean. Starter rules have limited coverage.')
        progress = ScanProgress()
        ACTIVE_PROGRESS = progress
        progress.tick(force=True)
        started = time.monotonic()
        deadline = started + config['timeout_seconds']
        try:
            available = domains()
            if selection != 'all' and selection not in available:
                raise ValueError('Unknown domain selection')
            selected = available if selection == 'all' else {selection: available[selection]}
            if not selected:
                raise ValueError('No registered domains found')
            yara, yarac = shutil.which('yara'), shutil.which('yarac')
            if not yara or not yarac:
                raise ValueError('YARA is not installed. Use Install YARA in the Security menu.')
            progress.stage = 'Counting candidate files (no file contents read)'
            progress.tick(force=True)
            for path, _, _ in selected.values():
                root = path / 'public_html'
                if root.is_symlink() or not root.is_dir():
                    continue
                for _, _, files in os.walk(root, followlinks=False):
                    if time.monotonic() >= deadline:
                        raise TimeoutError('Overall scan time limit reached while counting files')
                    progress.total += len(files)
                    progress.tick()
            progress.stage = 'Validating YARA rules'
            progress.tick(force=True)
            with tempfile.TemporaryDirectory(prefix='.rules-', dir=REPORTS) as tmp:
                compiled = str(Path(tmp) / 'rules.bin')
                code, _, error = run_engine([yarac, str(RULES), compiled], config['memory_mb'], 15)
                if code or error:
                    raise ValueError(f'Rule validation failed: {error or code}')
                for folder, (path, name, stack) in selected.items():
                    item = dict(domain=name, app=stack, scanned=0, skipped=0, skipped_examples=[], errors=[], findings=[])
                    report['domains'].append(item)
                    progress.clear()
                    print(f'[SCAN] {name} ({stack})', flush=True)
                    progress.stage = f'Scanning {name} ({stack})'
                    progress.started = time.monotonic() if not progress.done else progress.started
                    progress.tick(force=True)
                    root = path / 'public_html'
                    if root.is_symlink() or not root.is_dir():
                        item['errors'].append('Source directory is missing or is a symlink')
                        continue
                    # fwalk and dir_fd prevent directory symlink swaps from escaping scope.
                    def walk_error(error):
                        item['errors'].append(str(error))
                    def skip_file(relative, reason):
                        item['skipped'] += 1
                        if len(item['skipped_examples']) < 100:
                            item['skipped_examples'].append(dict(file=relative, reason=reason))
                    for current, dirs, files, directory_fd in os.fwalk(root, follow_symlinks=False, onerror=walk_error):
                        if time.monotonic() >= deadline:
                            raise TimeoutError('Overall scan time limit reached; remaining directories were not scanned')
                        for directory in list(dirs):
                            try:
                                if stat.S_ISLNK(os.stat(directory, dir_fd=directory_fd, follow_symlinks=False).st_mode):
                                    dirs.remove(directory)
                                    skip_file(str(Path(current, directory).relative_to(root)), 'symlink directory')
                            except OSError as error:
                                item['errors'].append(str(error))
                        for entry in files:
                            if time.monotonic() >= deadline:
                                raise TimeoutError('Overall scan time limit reached; remaining files were not scanned')
                            relative = str(Path(current, entry).relative_to(root))
                            fd = None
                            try:
                                initial = os.stat(entry, dir_fd=directory_fd, follow_symlinks=False)
                                if not stat.S_ISREG(initial.st_mode):
                                    skip_file(relative, 'symlink or non-regular file')
                                    continue
                                fd = os.open(entry, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory_fd)
                                before = os.fstat(fd)
                                if not stat.S_ISREG(before.st_mode) or before.st_size > config['max_file_mb'] * 1024 * 1024:
                                    skip_file(relative, 'non-regular file or file exceeds size limit')
                                    continue
                                code, output, error = run_engine(
                                    [yara, '-C', '-a', str(config['per_file_seconds']), compiled, f'/proc/self/fd/{fd}'],
                                    config['memory_mb'], min(config['per_file_seconds'] + 1, max(.1, deadline - time.monotonic())), (fd,))
                                after = os.fstat(fd)
                                if code or error:
                                    item['errors'].append(f'{relative}: {error or "engine exit " + str(code)}')
                                elif (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                                    item['errors'].append(f'{relative}: file changed during scanning; retry required')
                                else:
                                    item['scanned'] += 1
                                for line in output.splitlines():
                                    item['findings'].append(dict(file=relative, rule=line.split(' ', 1)[0]))
                            except OSError as error:
                                if error.errno == errno.ELOOP:
                                    skip_file(relative, 'symlink file')
                                else:
                                    item['errors'].append(f'{relative}: {error}')
                            finally:
                                if fd is not None:
                                    os.close(fd)
                                progress.done += 1
                                progress.tick()
        except KeyboardInterrupt:
            report['error'] = 'Scan interrupted by user; partial results retained'
        except (OSError, ValueError, TimeoutError) as error:
            report['error'] = str(error)
        progress.clear()
        ACTIVE_PROGRESS = None
        print(f'[PROGRESS] Processed {progress.done}/{progress.total} candidate files.', flush=True)
        for item in report['domains']:
            report['scanned'] += item['scanned']
            report['skipped'] += item['skipped']
            report['errors'] += len(item['errors'])
            report['matches'] += len(item['findings'])
        if 'error' in report:
            report['errors'] += 1
        report['status'] = 'INCOMPLETE' if report['errors'] else ('FINDINGS' if report['matches'] else 'NO_MATCHES')
        report['duration_seconds'] = round(time.monotonic() - started, 2)
        if 'error' in report:
            print(f"[FAIL] {report['error']}", flush=True)
        for item in report['domains']:
            for error in item['errors'][:5]:
                print(f"[WARN] {item['domain']}: {error}", flush=True)
        save_report(report, config)
        return 2 if report['errors'] else (1 if report['matches'] else 0)


def configure(args):
    config = load_config()
    config['notify'] = args.notify
    CONFIG.parent.mkdir(parents=True, exist_ok=True)
    CONFIG.write_text(json.dumps(config, indent=2) + '\n')
    CONFIG.chmod(0o600)
    unit = UNITS / 'shieldpress-yara.service'
    timer = UNITS / 'shieldpress-yara.timer'
    if args.schedule == 'off':
        if timer.exists():
            subprocess.run(['systemctl', 'disable', '--now', timer.name], check=True)
        # Leave the service installed for inspection; disabling the timer is idempotent.
        print('[OK] Automatic YARA scanning disabled.')
        return
    if not shutil.which('yara') or not shutil.which('yarac'):
        raise ValueError('Install YARA before enabling scheduled scans')
    calendar = f'*-*-* {args.hour:02d}:00:00' if args.schedule == 'daily' else f'Sun *-*-* {args.hour:02d}:00:00'
    unit.write_text(f'''[Unit]
Description=ShieldPress report-only YARA scan
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 {BASE}/modules/security/yara-scan.py scan all
Nice=15
IOSchedulingClass=idle
CPUQuota=25%
MemoryMax=384M
TimeoutStartSec=20min
SuccessExitStatus=1
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths={REPORTS.parent}
PrivateTmp=true
''')
    REPORTS.mkdir(parents=True, exist_ok=True, mode=0o700)
    timer.write_text(f'''[Unit]
Description=Scheduled ShieldPress YARA scan
[Timer]
OnCalendar={calendar}
RandomizedDelaySec=10min
Persistent=true
[Install]
WantedBy=timers.target
''')
    subprocess.run(['systemctl', 'daemon-reload'], check=True)
    subprocess.run(['systemctl', 'enable', '--now', timer.name], check=True)
    print(f'[OK] {args.schedule} scanning configured at {args.hour:02d}:00 server time (+ up to 10 minutes jitter).')
    print('[INFO] Local reports are always saved. Telegram summaries follow the selected notification preference and global Security Alert settings.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('list')
    scan_parser = sub.add_parser('scan')
    scan_parser.add_argument('domain', help='Registered domain folder name or all')
    config_parser = sub.add_parser('configure')
    config_parser.add_argument('schedule', choices=['off', 'daily', 'weekly'])
    config_parser.add_argument('--hour', type=int, choices=range(24), default=3)
    config_parser.add_argument('--notify', action='store_true')
    sub.add_parser('report')
    args = parser.parse_args()
    try:
        if args.command == 'list':
            for folder, (_, name, stack) in domains().items():
                print(f'{folder}\t{name}\t{stack}')
        elif args.command == 'scan':
            return scan(args.domain, load_config())
        elif args.command == 'configure':
            configure(args)
        else:
            reports = sorted(REPORTS.glob('scan-*.json'))
            print(reports[-1].read_text() if reports else 'No YARA scan reports yet.')
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f'[FAIL] {error}', file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
