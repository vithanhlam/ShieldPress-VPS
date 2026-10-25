#!/usr/bin/env python3
"""Pass archive bytes unchanged and show live input throughput on a terminal."""
import os
import sys
import time


def main():
    total = max(0, int(sys.argv[1]))
    started = updated = time.monotonic()
    transferred = 0
    interactive = sys.stderr.isatty()
    try:
        while True:
            chunk = os.read(sys.stdin.fileno(), 256 * 1024)
            if not chunk:
                break
            view = memoryview(chunk)
            while view:
                written = os.write(sys.stdout.fileno(), view)
                view = view[written:]
            transferred += len(chunk)
            now = time.monotonic()
            if interactive and now - updated >= 1:
                elapsed = now - started
                rate = transferred / elapsed
                # Source size excludes tar headers and may change during backup.
                # Never claim completion or a zero ETA before the stream ends.
                eta = f'~{max(1, int((total - transferred) / rate))}s' if total > transferred else 'finishing'
                percent = f'~{min(99, transferred * 100 // total)}%' if total else 'unknown'
                sys.stderr.write(f'\r\033[K  Input: {transferred / 1048576:.1f} MiB | {percent} | '
                                 f'{rate / 1048576:.1f} MiB/s | Elapsed: {elapsed:.0f}s | ETA: {eta}')
                sys.stderr.flush()
                updated = now
        if interactive:
            sys.stderr.write('\r\033[K')
    except BrokenPipeError:
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
