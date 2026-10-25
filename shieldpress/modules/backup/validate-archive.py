#!/usr/bin/env python3
"""Validate restore archives before extracting or replacing application files."""
import argparse
from pathlib import PurePosixPath
import posixpath
import sys
import tarfile


def normalized(name):
    if name.startswith('/') or '\\' in name or any(ord(c) < 32 for c in name):
        raise ValueError('Absolute or ambiguous archive path')
    parts = PurePosixPath(name).parts
    if '..' in parts:
        raise ValueError('Parent traversal in archive path')
    return posixpath.normpath(name)


def validate(path, scope=None):
    with tarfile.open(path, 'r:*') as archive:
        links = set()
        members = archive.getmembers()
        seen = set()
        for member in members:
            name = normalized(member.name)
            if name == '.' and member.isdir():
                continue
            if name in seen:
                raise ValueError(f'Duplicate archive entry: {name}')
            seen.add(name)
            if scope and name != scope and not name.startswith(scope + '/'):
                raise ValueError(f'Archive entry outside {scope}: {name}')
            if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
                raise ValueError(f'Special device or FIFO in archive: {name}')
            if member.mode & 0o6000:
                raise ValueError(f'Privileged executable mode in archive: {name}')
            if member.issym() or member.islnk():
                raw = member.linkname
                if raw.startswith('/') or '\\' in raw or any(ord(c) < 32 for c in raw):
                    raise ValueError(f'Unsafe link: {name}')
                target = posixpath.normpath(posixpath.join(posixpath.dirname(name), raw) if member.issym() else raw)
                if target == '..' or target.startswith('../') or (scope and target != scope and not target.startswith(scope + '/')):
                    raise ValueError(f'Link escapes restore directory: {name}')
                links.add(name)
        for member in members:
            name = normalized(member.name)
            if any(str(parent) in links for parent in PurePosixPath(name).parents):
                raise ValueError(f'Archive writes through a link: {name}')
    return True


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive')
    parser.add_argument('--scope')
    args = parser.parse_args()
    try:
        validate(args.archive, args.scope)
    except (OSError, ValueError, tarfile.TarError) as error:
        print(f'[FAIL] Unsafe restore archive: {error}', file=sys.stderr)
        sys.exit(1)
