#!/usr/bin/env python3
"""Bound Nginx connection allocation independently of host CPU count."""
import argparse
import datetime
import os
from pathlib import Path
import re
import shutil
import subprocess


def tune(text, cpu, clamp=False):
    workers = min(max(cpu, 1), 16)
    connections = min(max(cpu, 1) * 4096, 16384)
    def worker(match):
        value = match[2]
        count = min(int(value), workers) if clamp and value.isdigit() else workers
        return f'{match[1]}worker_processes {count};'
    text, count = re.subn(r'(?m)^([ \t]*)worker_processes\s+(auto|[1-9][0-9]*)\s*;', worker, text)
    if count != 1:
        raise ValueError('Expected exactly one worker_processes directive')
    def events(match):
        body = match[2]
        def connection(item):
            value = min(int(item[2]), connections) if clamp else connections
            return f'{item[1]}worker_connections {value};'
        body, count = re.subn(r'(?m)^([ \t]*)worker_connections\s+([1-9][0-9]*)\s*;', connection, body)
        if count != 1:
            raise ValueError('Expected exactly one worker_connections directive in events')
        return match[1] + body + '}'
    text, count = re.subn(r'(?m)^([ \t]*events\s*\{)([^{}]*)\}', events, text)
    if count != 1:
        raise ValueError('Expected exactly one events block')
    return text


def apply(path, cpu, clamp=False, reload=False):
    original = path.read_text()
    updated = tune(original, cpu, clamp)
    if updated == original:
        print('[OK] Nginx worker limits already bounded')
        return
    backup = path.with_name(path.name + '.before-worker-limits.' + datetime.datetime.now().strftime('%Y%m%d%H%M%S%f'))
    shutil.copy2(path, backup)
    try:
        path.write_text(updated)
        subprocess.run(['nginx', '-t'], check=True)
        if reload:
            subprocess.run(['systemctl', 'reload', 'nginx'], check=True)
    except Exception:
        shutil.copy2(backup, path)
        raise
    print(f'[OK] Nginx worker limits applied; backup: {backup}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--clamp', action='store_true', help='Preserve lower existing limits')
    parser.add_argument('--reload', action='store_true')
    args = parser.parse_args()
    try:
        apply(Path('/etc/nginx/nginx.conf'), len(os.sched_getaffinity(0)), args.clamp, args.reload)
    except Exception as error:
        parser.exit(1, f'[FAIL] Nginx worker tuning pending: {error}\n')
