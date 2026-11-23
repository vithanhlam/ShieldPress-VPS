#!/usr/bin/env python3
"""Deleting a domain must stop Certbot renewing its certificate (nothing removed)."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'shieldpress/modules/domain/helpers.sh').read_text()
FUNCTION = 'retire_domain_certs(){' + SOURCE.split('retire_domain_certs(){', 1)[1].split('\ndelete_configs(){', 1)[0]


def make_cert(directory, names):
    san = ','.join('DNS:' + n for n in names)
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2',
                    '-subj', '/CN=' + names[0], '-addext', 'subjectAltName=' + san,
                    '-keyout', str(directory / 'privkey.pem'), '-out', str(directory / 'cert.pem')],
                   check=True, capture_output=True)


class RetireCerts(unittest.TestCase):
    def setup_le(self, root, name, sans):
        for part in ('renewal', 'live/' + name, 'archive/' + name):
            (root / part).mkdir(parents=True, exist_ok=True)
        (root / 'renewal' / (name + '.conf')).write_text('# conf ' + name + '\n')
        make_cert(root / 'live' / name, sans)
        (root / 'archive' / name / 'x.pem').write_text('x')

    def run_retire(self, root, domain):
        env = dict(os.environ, LETSENCRYPT_DIR=str(root), CLEAN_DOMAIN=domain)
        return subprocess.run(['bash', '-c', 'warn(){ echo "WARN $*"; };\n' + FUNCTION + '\nretire_domain_certs'],
                              env=env, capture_output=True, text=True)

    def test_deleted_domain_is_retired_not_removed(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            self.setup_le(root, 'gone.test', ['gone.test', 'www.gone.test'])
            self.setup_le(root, 'keep.test', ['keep.test'])
            result = self.run_retire(root, 'gone.test')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((root / 'renewal/gone.test.conf').exists())
            self.assertFalse((root / 'live/gone.test').exists())
            self.assertFalse((root / 'archive/gone.test').exists())
            moved = list((root / 'retired').glob('*/gone.test'))
            self.assertEqual(len(moved), 1)
            self.assertTrue((moved[0] / 'renewal.conf').is_file())
            self.assertTrue((moved[0] / 'live/cert.pem').is_file())
            self.assertTrue((moved[0] / 'archive/x.pem').is_file())
            # Other domains are untouched.
            self.assertTrue((root / 'renewal/keep.test.conf').is_file())
            self.assertTrue((root / 'live/keep.test/cert.pem').is_file())

    def test_www_named_lineage_is_retired(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            self.setup_le(root, 'www.gone.test', ['www.gone.test', 'gone.test'])
            self.run_retire(root, 'gone.test')
            self.assertFalse((root / 'renewal/www.gone.test.conf').exists())
            self.assertEqual(len(list((root / 'retired').glob('*/www.gone.test/renewal.conf'))), 1)

    def test_certificate_shared_with_other_host_is_kept(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            self.setup_le(root, 'gone.test', ['gone.test', 'shop.other.test'])
            result = self.run_retire(root, 'gone.test')
            self.assertIn('WARN', result.stdout)
            self.assertTrue((root / 'renewal/gone.test.conf').is_file())
            self.assertTrue((root / 'live/gone.test/cert.pem').is_file())
            self.assertFalse((root / 'retired').exists())

    def test_domain_without_certificate_is_a_noop(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / 'renewal').mkdir()
            result = self.run_retire(root, 'none.test')
            self.assertEqual(result.returncode, 0)
            self.assertFalse((root / 'retired').exists())

    def test_hook_is_called_by_delete_configs(self):
        body = SOURCE.split('\ndelete_configs(){', 1)[1].split('\n}\n', 1)[0]
        self.assertIn('retire_domain_certs', body)


if __name__ == '__main__':
    unittest.main()
