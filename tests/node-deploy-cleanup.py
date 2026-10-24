#!/usr/bin/env python3
"""Exercise upgrade cleanup, repeat runs, readiness failures and live output safety."""
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / 'shieldpress/modules/nodejs/nodejs-menu.sh').read_text()
HELPERS = SOURCE.split('cleanup_next_deploy_backups(){', 1)[1].split('\nrun_node_build(){', 1)[0]
HELPERS = 'cleanup_next_deploy_backups(){' + HELPERS


class CleanupTests(unittest.TestCase):
    def test_old_backups_removed_and_live_build_preserved_on_repeat(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ['.next.deploy-backup.123', '.next-release.deploy-backup.456',
                         '.next', '.next-release', '.next.candidate.789',
                         '.next.deploy-backup.manual', 'source']:
                (root / name).mkdir()
                (root / name / 'artifact').write_text(name)
            (root / '.next.deploy-backup.999').symlink_to(root / 'source', target_is_directory=True)
            script = 'ok(){ echo "$*"; };\n' + HELPERS + '\ncleanup_next_deploy_backups "$1"; cleanup_next_deploy_backups "$1"'
            result = subprocess.run(['bash', '-c', script, '_', directory], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('2 removed, 0 pending', result.stdout)
            self.assertIn('0 removed, 0 pending', result.stdout)
            self.assertFalse((root / '.next.deploy-backup.123').exists())
            self.assertFalse((root / '.next-release.deploy-backup.456').exists())
            for name in ['.next', '.next-release', '.next.candidate.789', '.next.deploy-backup.manual', 'source']:
                self.assertTrue((root / name / 'artifact').exists())
            self.assertTrue((root / '.next.deploy-backup.999').is_symlink())

    def test_readiness_and_failure_retention(self):
        for code, expected in [('200', 0), ('404', 0), ('503', 1), ('000', 1)]:
            script = 'curl(){ echo "$CODE"; }; sleep(){ :; };\n' + HELPERS + '\nnext_deploy_http_ready 3000'
            result = subprocess.run(['bash', '-c', 'CODE="$1";\n' + script, '_', code], capture_output=True)
            self.assertEqual(result.returncode, expected)
        deploy = SOURCE.split('deploy_node_app_locked(){', 1)[1].split('\nnode_logs(){', 1)[0]
        self.assertIn('if run_with_progress "Verify deployed app"', deploy)
        self.assertIn('deploy backups retained for recovery', deploy)
        self.assertNotIn('rm -rf "$previous_next"', deploy)


if __name__ == '__main__':
    unittest.main()
