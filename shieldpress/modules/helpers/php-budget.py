#!/usr/bin/env python3
"""Share a conservative PHP child budget across all installed Remi branches."""
import argparse
import datetime
import fcntl
import math
from pathlib import Path
import re
import shutil
import subprocess


def setting(text, key, value):
    pattern = r'(?m)^[ \t]*' + re.escape(key) + r'\s*=.*$'
    if re.search(pattern, text):
        return re.sub(pattern, f'{key} = {value}', text)
    return text.rstrip() + f'\n{key} = {value}\n'


def memory_profile(proc=Path('/proc')):
    info = (proc / 'meminfo').read_text()
    total = int(re.search(r'MemTotal:\s+(\d+)', info)[1]) // 1024
    samples = []
    for entry in proc.glob('[0-9]*'):
        try:
            if (entry / 'comm').read_text().strip() == 'php-fpm':
                status = (entry / 'status').read_text()
                samples.append(int(re.search(r'VmRSS:\s+(\d+)', status)[1]) / 1024)
        except (OSError, TypeError):
            continue
    # Reserve shared runtime memory separately; use a conservative observed peak.
    worker = max(128, math.ceil(max(samples, default=128)))
    return total, worker


def plan(root, total_mb, worker_mb, cpus):
    branches = []
    for config in sorted((root / 'etc/opt/remi').glob('php[0-9]*/php-fpm.conf')):
        pools = sorted(p for p in config.with_name('php-fpm.d').glob('*.conf')
                       if re.search(r'(?m)^\s*\[(?!global\])[^]]+\]', p.read_text()))
        if pools:
            branches.append((config, pools))
    if not branches:
        return {}, {}
    budget_mb = max(128, int(total_mb * .40) - len(branches) * 256)
    total_children = max(len(branches), min(max(1, cpus) * 6, budget_mb // max(128, worker_mb)))
    # At least one child per installed branch; distribute the remainder by pool count.
    limits = [1] * len(branches)
    for _ in range(total_children - len(branches)):
        index = max(range(len(branches)), key=lambda i: len(branches[i][1]) / limits[i])
        limits[index] += 1
    changes, services = {}, {}
    for (config, pools), limit in zip(branches, limits):
        text = config.read_text()
        section = re.search(r'(?m)^\s*\[global\]\s*$', text)
        if not section:
            raise ValueError(f'Missing [global] section: {config}')
        following = re.search(r'(?m)^\s*\[', text[section.end():])
        end = section.end() + following.start() if following else len(text)
        global_text = text[section.end():end]
        current = re.search(r'(?m)^\s*process.max\s*=\s*(\d+)', global_text)
        if current and int(current[1]) > 0:
            limit = min(limit, int(current[1]))
        # Includes can change FPM's active section to the last loaded pool.
        # Place global directives before includes, never append after them.
        global_text = re.sub(r'(?m)^[ \t]*process\.max\s*=.*\n?', '', global_text)
        changes[config] = text[:section.end()] + f'\nprocess.max = {limit}\n' + global_text.lstrip('\n') + text[end:]
        pool_cap = max(1, min(8, limit))
        for pool in pools:
            original = pool.read_text()
            if len(re.findall(r'(?m)^\s*\[[^]]+\]', original)) != 1:
                raise ValueError(f'Multiple pool sections require manual review: {pool}')
            current = re.search(r'(?m)^\s*pm.max_children\s*=\s*(\d+)', original)
            if not current:
                raise ValueError(f'Missing pm.max_children: {pool}')
            cap = min(int(current[1]), pool_cap)
            updated = setting(original, 'pm.max_children', cap)
            # Keep custom dynamic/static pools valid while reducing their maximum.
            for key in ('pm.start_servers', 'pm.min_spare_servers', 'pm.max_spare_servers'):
                match = re.search(r'(?m)^\s*' + re.escape(key) + r'\s*=\s*(\d+)', updated)
                if match:
                    updated = setting(updated, key, min(int(match[1]), cap))
            changes[pool] = updated
        branch = config.parent.name
        services[branch] = limit
    return {p: text for p, text in changes.items() if p.read_text() != text}, services


def apply(changes, services, reload=True):
    stamp = datetime.datetime.now().strftime('%Y%m%d%H%M%S%f')
    backups = {}
    active = []
    for branch in services:
        if subprocess.run(['systemctl', 'is-active', '--quiet', f'{branch}-php-fpm']).returncode == 0:
            active.append(branch)
    try:
        for path, text in changes.items():
            backup = path.with_name(path.name + '.before-php-budget.' + stamp)
            shutil.copy2(path, backup)
            backups[path] = backup
            path.write_text(text)
        for branch in services:
            subprocess.run([f'/opt/remi/{branch}/root/usr/sbin/php-fpm', '-t'], check=True)
        if reload and changes:
            for branch in active:
                subprocess.run(['systemctl', 'reload', f'{branch}-php-fpm'], check=True)
    except Exception:
        for path, backup in backups.items():
            shutil.copy2(backup, path)
        if reload:
            for branch in active:
                subprocess.run(['systemctl', 'reload', f'{branch}-php-fpm'])
        raise
    for branch, limit in services.items():
        print(f'[OK] {branch}: process.max={limit}; lower custom limits retained')
    print(f'[OK] PHP budget: {len(changes)} changed files; backups retained beside configuration')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--no-reload', action='store_true')
    args = parser.parse_args()
    try:
        if args.apply:
            lock_dir = Path('/run/shieldpress/runtime-policy')
            lock_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
            lock_stream = (lock_dir / 'configuration.lock').open('a')
            fcntl.flock(lock_stream, fcntl.LOCK_EX)
        import os
        total, worker = memory_profile()
        changes, services = plan(Path('/'), total, worker, len(os.sched_getaffinity(0)))
        print(f'[INFO] RAM={total} MiB, worker estimate={worker} MiB; applying shared PHP budget')
        if args.apply:
            apply(changes, services, not args.no_reload)
        else:
            print(f'[PLAN] Branch child limits: {services}; files to update: {len(changes)}')
    except Exception as error:
        parser.exit(1, f'[FAIL] PHP budget repair pending: {error}\n')
