#!/usr/bin/env python3
"""Consume bounded, non-symlink cache signals for their originating domain only."""
import os
from pathlib import Path
import re
import stat
import subprocess


def consume(domains, helper):
    for home in domains.iterdir():
        if home.is_symlink() or not home.is_dir() or not re.fullmatch(r'[A-Za-z0-9_]+', home.name):
            continue
        fd = signal = None
        try:
            fd = os.open(home / 'tmp', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            signal = os.open('.purge-cache', os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=fd)
            info = os.fstat(signal)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > 128:
                continue
            content = os.read(signal, 129).decode('ascii').strip()
            os.unlink('.purge-cache', dir_fd=fd)
            if content == home.name:
                subprocess.run([str(helper), home.name], check=True)
        except (OSError, ValueError, subprocess.CalledProcessError):
            continue
        finally:
            if signal is not None:
                os.close(signal)
            if fd is not None:
                os.close(fd)


if __name__ == '__main__':
    consume(Path('/home/domains'), Path('/opt/shieldpress/bin/purge-fastcgi-cache'))
