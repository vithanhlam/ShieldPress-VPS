#!/usr/bin/env python3
"""Disk Manager report regressions: formatting, scans and all four reports (read-only)."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'shieldpress/modules/disk/disk-report.py'
spec = importlib.util.spec_from_file_location('disk_report', SCRIPT)
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)
ANSI = re.compile(r'\x1b\[[0-9;]*m')


def plain(function, *args):
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        result = function(*args)
    return ANSI.sub('', output.getvalue()), result


class Formatting(unittest.TestCase):
    def test_sizes_bars_and_paths(self):
        self.assertEqual([d.size(v) for v in (0, 512, 2048, 5 * 1024 ** 3, 47 * 1024 ** 3)], ['0B', '512B', '2.0K', '5.0G', '47G'])
        self.assertEqual(ANSI.sub('', d.bar(84, 10)), '████████░░')
        self.assertEqual(ANSI.sub('', d.bar(0.2, 10)), '░' * 10)
        self.assertEqual(ANSI.sub('', d.bar(0.6, 10)), '█' + '░' * 9)
        self.assertEqual(d.level(84), '33')
        self.assertEqual(d.level(85), '31')
        path = 'laravelfulltest_local/public_html/vendor/laravel/pint/builds/pint'
        short = d.fit_path(path, 41)
        self.assertEqual(len(short), 41)
        self.assertTrue(short.startswith('laravelfulltest_local/…') and short.endswith('/builds/pint'))
        self.assertEqual(d.fit_path('a/b.txt', 41), 'a/b.txt')
        self.assertEqual(d.plural(1, 'file'), '1 file')
        self.assertEqual(d.plural(1200, 'file'), '1,200 files')
        self.assertEqual(d.kind('site/backup.SQL.gz'), 'db dump')
        self.assertEqual(d.kind('x.tar.gz'), 'archive')
        self.assertEqual(d.kind('index.php'), '')

    def test_lines_fit_the_menu_width(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            deep = root / 'averyveryverylongdomainname_example_local/public_html/wp-content/uploads/2026/11'
            deep.mkdir(parents=True)
            (deep / ('x' * 120 + '.zip')).write_bytes(b'0' * 4096)
            os.environ['DATA_DIR'] = str(root / 'data')
            text, _ = plain(d.files, SimpleNamespace(path=str(root), all=True, label=None))
            for line in text.splitlines():
                if not line.startswith('[PROGRESS]'):
                    self.assertLessEqual(len(line), d.WIDTH, line)


class Reports(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        os.environ['DATA_DIR'] = str(self.root / 'data')

    def tearDown(self):
        self.tmp.cleanup()

    def test_largest_files_top_n_skips_symlinks(self):
        for index in range(30):
            (self.root / f'f{index}.bin').write_bytes(b'0' * index)
        (self.root / 'link').symlink_to(self.root / 'f29.bin')
        items, count, total = d.largest(self.root, 5)
        self.assertEqual([i[0] for i in items], [29, 28, 27, 26, 25])
        self.assertEqual(count, 30)
        self.assertEqual(total, sum(range(30)))

    def test_domain_and_all_domain_reports(self):
        site = self.root / 'domains/example_com'
        (site / 'config').mkdir(parents=True)
        (site / 'public_html').mkdir()
        (site / 'config/domain.env').write_text('DOMAIN=example.com\n')
        (site / 'public_html/db-backup.sql').write_bytes(b'0' * 300000)
        (site / 'public_html/index.php').write_text('<?php')
        text, status = plain(d.files, SimpleNamespace(path=str(site / 'public_html'), all=False, label='example.com'))
        self.assertIn('example.com', text)
        self.assertIn('2 files', text)
        self.assertRegex(text, r'1\s+293K\s+\d{4}-\d\d-\d\d\s+db-backup\.sql\s+db dump')
        self.assertIn('1 of these are archives or database dumps', text)
        text, _ = plain(d.files, SimpleNamespace(path=str(self.root / 'domains'), all=True, label=None))
        self.assertIn('1 domain ', text)
        self.assertIn('example.com', text)
        self.assertIn('example_com/public_html/db-backup.sql', text)
        text, status = plain(d.files, SimpleNamespace(path=str(self.root / 'missing'), all=False, label=None))
        self.assertEqual(status, 1)
        self.assertIn('Directory not found', text)

    def test_backup_report_ages_and_categories(self):
        backups = self.root / 'backup-all'
        (backups / 'wordpress').mkdir(parents=True)
        (backups / 'empty').mkdir()
        old = backups / 'wordpress/full.tar.gz'
        old.write_bytes(b'0' * 8192)
        stamp = time.time() - 10 * 86400
        os.utime(old, (stamp, stamp))
        args = SimpleNamespace(path=str(backups), logs=str(self.root), data=None, base=None)
        text, _ = plain(d.backups, args)
        self.assertIn('1 file', text)
        self.assertIn('10 days ago', text)
        self.assertRegex(text, r'wordpress\s+\S+\s+█+')
        self.assertIn('0 files', text)
        self.assertIn('The newest backup is 10 days ago', text)
        text, status = plain(d.backups, SimpleNamespace(path=str(self.root / 'none'), logs=None, data=None, base=None))
        self.assertEqual(status, 1)

    def test_overview_and_estimate_history(self):
        args = SimpleNamespace(domains=str(self.root), base=None, backups=None)
        text, _ = plain(d.overview, args)
        self.assertIn('FILESYSTEMS', text)
        self.assertIn('INODES', text)
        self.assertIn('KEY DIRECTORIES', text)
        self.assertRegex(text, r'(Healthy|Warning|Critical)')
        self.assertTrue((self.root / 'data/disk-timing/overview').read_text().strip().isdigit())
        text, _ = plain(d.overview, args)
        self.assertIn('(previous run)', text)

    def test_menu_wiring_and_cli(self):
        menu = (ROOT / 'shieldpress/modules/disk/disk-menu.sh').read_text()
        for command in ('overview --domains', 'files "$site" --label', 'files "$DOMAINS_ROOT" --all', 'backups "$BACKUP_DIR"'):
            self.assertIn('python3 -I "$REPORT" ' + command, menu)
        subprocess.run(['bash', '-n', str(ROOT / 'shieldpress/modules/disk/disk-menu.sh')], check=True)
        result = subprocess.run([sys.executable, '-I', str(SCRIPT), 'files', str(self.root)], env=dict(os.environ),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('No files found.', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=1)
