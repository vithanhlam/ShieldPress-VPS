#!/usr/bin/env python3
"""Exercise registry cleanup without touching a real MySQL server."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'shieldpress/modules/domain/helpers.sh').read_text()
FUNCTION = 'delete_database(){' + SOURCE.split('delete_database(){', 1)[1].split('\n# ===============================', 1)[0]


class RegistryCleanup(unittest.TestCase):
    def run_delete(self, *, fail=False, connection='mysql'):
        with tempfile.TemporaryDirectory() as directory:
            registry = Path(directory) / 'databases.list'
            original = ('DB_NAME=sample_db | DOMAIN=sample.test\n'
                        'DB_NAME=sample_db_extra | DOMAIN=other.test\n')
            registry.write_text(original)
            registry.chmod(0o600)
            env = dict(os.environ, DATA_DIR=directory, DB_NAME='sample_db',
                       DB_USER='sample_user', DB_CONNECTION=connection,
                       MYSQL_FAIL='1' if fail else '0')
            result = subprocess.run(['bash', '-c',
                                     'mysql(){ [ "$MYSQL_FAIL" = 0 ]; };\n'
                                     + FUNCTION + '\ndelete_database'], env=env,
                                    capture_output=True, text=True)
            return result.returncode, registry.read_text(), registry.stat().st_mode & 0o777

    def test_success_removes_only_deleted_database(self):
        status, data, mode = self.run_delete()
        self.assertEqual(status, 0)
        self.assertEqual(data, 'DB_NAME=sample_db_extra | DOMAIN=other.test\n')
        self.assertEqual(mode, 0o600)

    def test_mysql_failure_keeps_registry(self):
        status, data, _ = self.run_delete(fail=True)
        self.assertNotEqual(status, 0)
        self.assertIn('DB_NAME=sample_db |', data)

    def test_domain_without_database_keeps_registry(self):
        status, data, _ = self.run_delete(connection='none')
        self.assertEqual(status, 0)
        self.assertIn('DB_NAME=sample_db |', data)


if __name__ == '__main__':
    unittest.main()
