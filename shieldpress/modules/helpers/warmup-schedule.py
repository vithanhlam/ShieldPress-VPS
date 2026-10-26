#!/usr/bin/env python3
"""Stagger only legacy generated daily root cache warmup schedules."""
import datetime
import os
from pathlib import Path
import re
import subprocess
import zlib


def stagger(text):
    pattern = r'(?m)^0 0 \* \* \* (bash /opt/shieldpress/modules/cache/warmup-cache\.sh --auto ([A-Za-z0-9.-]+))$'
    def replace(match):
        seed = zlib.crc32(match[2].encode())
        return f'{seed % 60} {(seed // 60) % 6} * * * {match[1]}'
    return re.sub(pattern, replace, text)


def main():
    result = subprocess.run(['crontab', '-l'], capture_output=True, text=True, env={**os.environ, 'LC_ALL': 'C'})
    if result.returncode:
        if 'no crontab for' in result.stderr.lower():
            print('[OK] No root warmup schedules to stagger')
            return
        raise RuntimeError(result.stderr.strip() or 'Cannot read root crontab')
    updated = stagger(result.stdout)
    if updated == result.stdout:
        print('[OK] Warmup schedules already staggered or customized')
        return
    backup_dir = Path('/var/shieldpress/backups/warmup-schedule')
    backup_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    backup = backup_dir / datetime.datetime.now().strftime('root-crontab-%Y%m%d%H%M%S%f')
    backup.touch(mode=0o600)
    backup.write_text(result.stdout)
    subprocess.run(['crontab', '-'], input=updated, text=True, check=True)
    print(f'[OK] Generated daily warmup schedules staggered; backup: {backup}')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        raise SystemExit(f'[FAIL] Warmup schedule repair pending: {error}')
