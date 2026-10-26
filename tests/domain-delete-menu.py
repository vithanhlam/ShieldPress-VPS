#!/usr/bin/env python3
"""Exercise delete prompts and stages with isolated command stubs."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / 'shieldpress/modules/domain/delete-domain.sh').read_text()
PROGRESS = ROOT / 'shieldpress/modules/helpers/task-progress.sh'


class DeleteMenu(unittest.TestCase):
    def run_menu(self, option, answer, fail=False):
        with tempfile.TemporaryDirectory() as directory:
            stubs = f'''
DATA_DIR={directory}
BASE_DIR={directory}
select_domain() {{ SELECTED_DOMAIN=example.test; CLEAN_DOMAIN=example_test; DB_CONNECTION=none; }}
source "{PROGRESS}"
python3() {{ echo SCHEDULES; }}
gpasswd() {{ return 0; }}
delete_database() {{ echo DATABASE; }}
delete_source() {{ echo SOURCE; }}
delete_configs() {{ echo CONFIGS; }}
'''
            script = SCRIPT.replace('source "$BASE_DIR/modules/domain/helpers.sh"', stubs)
            script = script.replace('source "$BASE_DIR/modules/helpers/task-progress.sh"', '')
            start = script.index('backup_domain_before_delete(){')
            end = script.index('\nselect_domain || exit', start)
            script = script[:start] + f'backup_domain_before_delete() {{ echo BACKUP; return {int(fail)}; }}\n' + script[end:]
            return subprocess.run(['bash', '-c', script], input=f'{option}\ny\n{answer}\n\n',
                                  text=True, capture_output=True, timeout=10)

    def test_default_and_explicit_yes_back_up(self):
        for option in (1, 2):
            for answer in ('', 'y', 'Y'):
                with self.subTest(option=option, answer=answer):
                    result = self.run_menu(option, answer)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('\nBACKUP\n', result.stdout)
                    self.assertIn('SOURCE', result.stdout)
                    self.assertIn('estimated duration', result.stdout)

    def test_no_skips_backup(self):
        for option in (1, 2):
            for answer in ('n', 'N'):
                result = self.run_menu(option, answer)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn('\nBACKUP\n', result.stdout)
                self.assertIn('Backup skipped', result.stdout)
                self.assertIn('SOURCE', result.stdout)

    def test_backup_failure_stops_deletion(self):
        result = self.run_menu(1, '', fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('SOURCE', result.stdout)
        self.assertNotIn('DATABASE', result.stdout)

    def test_database_only_reports_progress(self):
        result = self.run_menu(3, '')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Deleting database: estimated duration', result.stdout)
        self.assertNotIn('\nBACKUP\n', result.stdout)


if __name__ == '__main__':
    unittest.main()
