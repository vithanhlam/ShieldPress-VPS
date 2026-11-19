#!/usr/bin/python3
"""Disk Manager reports: filesystems, largest files and backup storage (read-only)."""
import argparse
from contextlib import contextmanager
from datetime import datetime
import heapq
import os
from pathlib import Path
import shutil
import subprocess
import sys
import textwrap
import threading
import time

WIDTH = 78
TTY = sys.stdout.isatty()
PSEUDO = {'tmpfs', 'devtmpfs', 'overlay', 'squashfs', 'proc', 'sysfs', 'cgroup', 'cgroup2', 'devpts', 'mqueue',
          'debugfs', 'tracefs', 'securityfs', 'pstore', 'bpf', 'configfs', 'fusectl', 'hugetlbfs', 'autofs',
          'rpc_pipefs', 'selinuxfs', 'binfmt_misc', 'efivarfs', 'nsfs', 'ramfs', 'fuse.portal', 'fuse.gvfsd-fuse'}
# Database dumps first: `.sql.gz` must not be classified as a plain archive.
KINDS = [(('.sql', '.sql.gz', '.sql.zst', '.dump'), 'db dump'),
         (('.zip', '.tar', '.tar.gz', '.tgz', '.gz', '.bz2', '.xz', '.zst', '.7z', '.rar', '.wpress'), 'archive'),
         (('.log',), 'log'),
         (('.mp4', '.mov', '.mkv', '.avi', '.webm'), 'video'),
         (('.iso', '.img', '.bin'), 'image')]


def c(code, text):
    return f'\033[{code}m{text}\033[0m'


def size(value):
    value = float(value)
    for unit in ('B', 'K', 'M', 'G', 'T', 'P'):
        if value < 1024 or unit == 'P':
            if unit == 'B':
                return f'{int(value)}B'
            return f'{value:.1f}{unit}' if value < 10 else f'{value:.0f}{unit}'
        value /= 1024


def level(percent):
    return '31' if percent >= 85 else '33' if percent >= 70 else '32'


def bar(percent, width=30, color=None):
    filled = max(0, min(width, round(percent * width / 100)))
    if percent >= 0.5 and filled == 0:
        filled = 1
    return c(color or level(percent), '█' * filled) + c('2', '░' * (width - filled))


def section(title, note=''):
    print()
    line = '  ' + c('1;36', '▸ ' + title.upper())
    if note:
        line += ' ' * max(1, WIDTH - 4 - len(title) - len(note)) + c(2, note)
    print(line)
    print('  ' + c(2, '─' * (WIDTH - 4)))


def fit(text, width):
    """Shorten in the middle so the file name stays visible."""
    if len(text) <= width:
        return text
    keep = width - 1
    return text[:keep // 3] + '…' + text[-(keep - keep // 3):]


def fit_path(path, width):
    """Keep the first directory (the domain) and as much of the end as fits."""
    if len(path) <= width:
        return path
    head, _, rest = path.partition('/')
    if rest and len(head) + 14 <= width:
        return head + '/…' + rest[-(width - len(head) - 2):]
    return fit(path, width)


def plural(count, word):
    return f'{count:,} {word}' + ('' if count == 1 else 's')


def kind(name):
    lower = name.lower()
    for suffixes, label in KINDS:
        if lower.endswith(suffixes):
            return label
    return ''


def age(timestamp):
    days = int((time.time() - timestamp) // 86400)
    return 'today' if days <= 0 else '1 day ago' if days == 1 else f'{days} days ago'


@contextmanager
def stage(label, key, fallback):
    """Animated stage with an estimate from the previous successful run."""
    history = Path(os.environ.get('DATA_DIR', '/var/shieldpress/data')) / 'disk-timing' / key
    estimate, basis = fallback, 'approximate'
    try:
        previous = int(history.read_text().strip())
        if previous > 0:
            estimate, basis = previous, 'previous run'
    except (OSError, ValueError):
        pass
    stop = threading.Event()
    started = time.monotonic()

    def animate():
        frames, index = '⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏', 0
        while not stop.wait(0.1):
            remaining = estimate - int(time.monotonic() - started)
            eta = f'ETA ~{remaining}s ({basis})' if remaining > 0 else 'taking longer than estimated; still running'
            print(f'\r\033[K  {c(36, frames[index % len(frames)])} {label} {c(2, "· " + eta)}', end='', flush=True)
            index += 1

    monitor = None
    if TTY:
        monitor = threading.Thread(target=animate, daemon=True)
        monitor.start()
    else:
        print(f'[PROGRESS] {label}: estimated ~{estimate}s ({basis})', flush=True)
    try:
        yield
    finally:
        stop.set()
        if monitor:
            monitor.join()
            print('\r\033[K', end='', flush=True)
    elapsed = max(1, round(time.monotonic() - started))
    try:
        history.parent.mkdir(parents=True, exist_ok=True)
        history.write_text(f'{elapsed}\n')
    except OSError:
        pass


def du(path):
    """Allocated bytes like `du -sx`; None when the path cannot be read."""
    try:
        out = subprocess.run(['du', '-sxB1', '--', str(path)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             text=True, timeout=1800).stdout.split()
        return int(out[0]) if out else None
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def mounts():
    seen, rows = set(), []
    try:
        lines = Path('/proc/self/mounts').read_text().splitlines()
    except OSError:
        lines = []
    for line in lines:
        parts = line.split()
        if len(parts) < 3:
            continue
        device, point, fstype = parts[0], parts[1].replace('\\040', ' '), parts[2]
        if fstype in PSEUDO or point.startswith(('/proc', '/sys', '/dev', '/run')):
            continue
        try:
            st = os.statvfs(point)
            dev = os.stat(point).st_dev
        except OSError:
            continue
        if st.f_blocks == 0 or dev in seen:
            continue
        seen.add(dev)
        total = st.f_blocks * st.f_frsize
        free = st.f_bavail * st.f_frsize
        used = total - st.f_bfree * st.f_frsize
        percent = round(used * 100 / (used + free)) if used + free else 0
        inodes = (st.f_files - st.f_ffree, st.f_files)
        rows.append({'point': point, 'device': device, 'type': fstype, 'total': total, 'used': used,
                     'free': free, 'percent': percent, 'inodes': inodes, 'dev': dev})
    rows.sort(key=lambda r: (r['point'] != '/', r['point']))
    return rows


def largest(root, count=20):
    heap, files, total = [], 0, 0
    for directory, dirs, names in os.walk(root, onerror=lambda error: None):
        for name in names:
            path = os.path.join(directory, name)
            try:
                st = os.lstat(path)
            except OSError:
                continue
            if not (st.st_mode & 0o170000 == 0o100000):
                continue
            files += 1
            total += st.st_size
            item = (st.st_size, st.st_mtime, path)
            if len(heap) < count:
                heapq.heappush(heap, item)
            elif item > heap[0]:
                heapq.heapreplace(heap, item)
    return sorted(heap, reverse=True), files, total


def file_table(items, base, show_domain=False):
    if not items:
        print('  ' + c(2, 'No files found.'))
        return
    path_width = WIDTH - 2 - 4 - 9 - 12 - 9
    print('  ' + c(2, f"{'#':>2}  {'SIZE':>7}  {'MODIFIED':<10}  {'FILE':<{path_width}} {'TYPE':>7}"))
    for number, (bytes_, mtime, path) in enumerate(items, 1):
        relative = os.path.relpath(path, base)
        label = kind(path)
        color = '1;33' if label in ('archive', 'db dump') else '1'
        print(f"  {c(2, f'{number:>2}')}  {c(color, f'{size(bytes_):>7}')}  "
              f"{datetime.fromtimestamp(mtime):%Y-%m-%d}  {fit_path(relative, path_width):<{path_width}} {c(2, f'{label:>7}')}")


def ranked(rows, reference, label_width=24):
    """rows: (label, bytes or None). Bars are relative to the reference size."""
    rows = sorted(rows, key=lambda r: -(r[1] or 0))
    for label, value in rows:
        if value is None:
            print(f"  {fit(label, label_width):<{label_width}} {c(2, '   n/a  (not readable)')}")
            continue
        percent = value * 100 / reference if reference else 0
        print(f"  {fit(label, label_width):<{label_width}} {c(1, f'{size(value):>7}')}  "
              f"{bar(percent, 26, '36')} {c(2, f'{percent:>4.0f}%')}")


def advice(lines):
    if lines:
        print()
        for color, text in lines:
            for index, line in enumerate(textwrap.wrap(text, WIDTH - 6)):
                print('  ' + c(color, ('⚠ ' if index == 0 else '  ') + line))


def overview(args):
    rows = mounts()
    root = next((r for r in rows if r['point'] == '/'), rows[0] if rows else None)
    if root:
        state = ('31', '✖ Critical') if root['percent'] >= 85 else ('33', '⚠ Warning') if root['percent'] >= 70 else ('32', '● Healthy')
        print(f"\n  {c('1;' + state[0], state[1])}  {c(2, 'root filesystem')} {c(1, str(root['percent']) + '% used')}"
              f"{c(2, ' · ' + size(root['free']) + ' free of ' + size(root['total']))}")
    section('Filesystems')
    for r in rows:
        point = f"{fit(r['point'], 14):<14}"
        percent = f"{r['percent']:>3}%"
        print(f"  {c(1, point)} {bar(r['percent'], 34)} {c('1;' + level(r['percent']), percent)}  {c(2, r['type'])}")
        detail = f"{size(r['used'])} used · {size(r['free'])} free · {size(r['total'])} total · {r['device']}"
        print(f"  {'':<14} {c(2, fit(detail, WIDTH - 17))}")
    section('Inodes')
    for r in rows:
        used, total = r['inodes']
        if not total:
            continue
        percent = round(used * 100 / total)
        print(f"  {fit(r['point'], 14):<14} {bar(percent, 34)} {c('1;' + level(percent), f'{percent:>3}%')}"
              f"  {c(2, f'{used:,} of {total:,}')}")
    directories = [d for d in [args.domains, args.base, '/var/log', '/var/lib/mysql', '/var/lib/pgsql', args.backups,
                               '/var/cache/nginx', '/tmp'] if d and os.path.isdir(d)]
    with stage('Measuring key directories', 'overview', 15):
        sizes = [(d, du(d)) for d in dict.fromkeys(directories)]
    reference = root['used'] if root else 0
    section('Key directories', f'share of {size(reference)} used on /' if root else '')
    ranked(sizes, reference)
    tips = []
    if root and root['percent'] >= 70:
        tips.append(('33', f"Disk is {root['percent']}% full. Find large files with option 3, review old backups with option 4."))
    if any(r['inodes'][1] and r['inodes'][0] * 100 / r['inodes'][1] >= 80 for r in rows):
        tips.append(('33', 'Inode usage is high: many small files (cache, sessions, node_modules) can fill a disk with free space.'))
    advice(tips)


def files(args):
    root = args.path
    if not os.path.isdir(root):
        print('\n  ' + c(31, '[FAIL] Directory not found: ' + root))
        return 1
    if args.all:
        domains = []
        for entry in sorted(Path(root).iterdir()) if os.path.isdir(root) else []:
            if entry.is_dir() and not entry.is_symlink():
                name = entry.name
                try:
                    for line in (entry / 'config/domain.env').read_text().splitlines():
                        if line.startswith('DOMAIN='):
                            name = line.split('=', 1)[1].strip() or name
                except OSError:
                    pass
                domains.append((name, entry))
        with stage('Measuring ' + plural(len(domains), 'domain'), 'domains', 20):
            sizes = [(name, du(path)) for name, path in domains]
        total = sum(v for _, v in sizes if v)
        print(f"\n  {c(1, plural(len(domains), 'domain'))}  {c(2, '·')} {c(1, size(total))} {c(2, 'on disk in ' + root)}")
        section('Domains by size')
        ranked(sizes, total) if sizes else print('  ' + c(2, 'No domains found.'))
    with stage('Finding the largest files', 'files-all' if args.all else 'files-domain', 30 if args.all else 10):
        items, count, total = largest(root, 20)
    if not args.all:
        print(f"\n  {c(1, args.label or root)}  {c(2, '·')} {c(1, plural(count, 'file'))} {c(2, '·')} "
              f"{c(1, size(total))} {c(2, 'in ' + root)}")
    section('Largest files', f'top {len(items)}')
    file_table(items, root)
    heavy = [i for i in items if kind(i[2]) in ('archive', 'db dump')]
    if heavy:
        advice([('33', f'{len(heavy)} of these are archives or database dumps ({size(sum(i[0] for i in heavy))}). '
                       'Backups kept inside a site are public-risk and waste space; move or delete them.')])


def backups(args):
    root = args.path
    if not os.path.isdir(root):
        print('\n  ' + c(33, '[WARN] Backup directory not found: ' + root))
        return 1
    categories = [p for p in sorted(Path(root).iterdir()) if p.is_dir() and not p.is_symlink()]
    with stage('Measuring backup storage', 'backups', 15):
        total = du(root)
        stats = []
        oldest = newest = None
        count = 0
        for directory, _, names in os.walk(root, onerror=lambda error: None):
            for name in names:
                try:
                    st = os.lstat(os.path.join(directory, name))
                except OSError:
                    continue
                count += 1
                oldest = st.st_mtime if oldest is None else min(oldest, st.st_mtime)
                newest = st.st_mtime if newest is None else max(newest, st.st_mtime)
        for path in categories:
            files_ = sum(len(n) for _, _, n in os.walk(path, onerror=lambda error: None))
            stats.append((path.name, du(path), files_))
        other = [(f'{label:<8}{path}', du(path)) for label, path in (('Logs', args.logs), ('Data', args.data), ('Source', args.base))
                 if path and os.path.isdir(path)]
    free = shutil.disk_usage(root).free
    print(f"\n  {c(1, size(total or 0))} {c(2, 'in')} {c(1, plural(count, 'file'))} {c(2, '· ' + root + ' · ' + size(free) + ' free on this disk')}")
    if newest:
        days = (time.time() - newest) / 86400
        color = '32' if days < 2 else '33' if days < 8 else '31'
        print(f"  {c(2, 'Newest')} {c(color, datetime.fromtimestamp(newest).strftime('%Y-%m-%d %H:%M') + ' (' + age(newest) + ')')}"
              f"   {c(2, 'Oldest')} {datetime.fromtimestamp(oldest):%Y-%m-%d} {c(2, '(' + age(oldest) + ')')}")
    section('By category', 'size · files')
    if stats:
        for name, value, files_ in sorted(stats, key=lambda s: -(s[1] or 0)):
            percent = (value or 0) * 100 / total if total else 0
            print(f"  {fit(name, 24):<24} {c(1, f'{size(value or 0):>7}')}  {bar(percent, 26, '36')} "
                  f"{c(2, f'{percent:>4.0f}%')}  {c(2, plural(files_, 'file'))}")
    else:
        print('  ' + c(2, 'No backup categories yet.'))
    section('Other ShieldPress storage')
    for label, value in other:
        print(f"  {fit(label, 44):<44} {c(1, f'{size(value or 0):>7}')}")
    tips = []
    if newest and (time.time() - newest) / 86400 >= 2:
        tips.append(('33', f'The newest backup is {age(newest)}. Check the backup schedule in Backup & Restore.'))
    if total and total > free:
        tips.append(('33', 'Backups use more space than is still free on this disk. Consider off-server storage or shorter retention.'))
    advice(tips)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='report', required=True)
    o = sub.add_parser('overview')
    o.add_argument('--domains')
    o.add_argument('--base')
    o.add_argument('--backups')
    f = sub.add_parser('files')
    f.add_argument('path')
    f.add_argument('--label')
    f.add_argument('--all', action='store_true')
    b = sub.add_parser('backups')
    b.add_argument('path')
    b.add_argument('--logs')
    b.add_argument('--data')
    b.add_argument('--base')
    args = parser.parse_args()
    try:
        return {'overview': overview, 'files': files, 'backups': backups}[args.report](args) or 0
    except KeyboardInterrupt:
        print('\n  ' + c(33, 'Cancelled.'))
        return 130


if __name__ == '__main__':
    sys.exit(main())
