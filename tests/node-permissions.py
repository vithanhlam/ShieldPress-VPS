#!/usr/bin/env python3
"""Verify Node permission repair preserves generated output across repeat runs."""
from pathlib import Path
import subprocess
import tempfile
import unittest

MODULES = Path(__file__).resolve().parents[1] / 'shieldpress/modules'


class NodePermissionsTests(unittest.TestCase):
    def test_permission_repair_prunes_generated_trees_from_chown_and_chmod(self):
        node_script = (MODULES / 'nodejs/nodejs-menu.sh').read_text()
        domain_script = (MODULES / 'domain/fix-permission.sh').read_text()
        for source, function, end in [
            (node_script, 'fix_node_app_permissions(){', '\nrepair_selected_node_permissions(){'),
            (domain_script, 'chmod_app_tree(){', '\nfix_wordpress_permissions(){'),
        ]:
            body = source.split(function, 1)[1].split(end, 1)[0]
            self.assertIn('-exec chown', body)
            self.assertIn('.next-release.*', body)
            self.assertNotIn('chown -R "$user:$user" "$app_root"', body)
            self.assertNotIn('chown -R "$SYSUSER:$SYSUSER" "$root"', body)

    def test_deploy_and_manual_repair(self):
        for module, function, following in [
            ('nodejs/nodejs-menu.sh', 'fix_node_app_permissions', 'repair_selected_node_permissions'),
            ('domain/fix-permission.sh', 'chmod_app_tree', 'fix_wordpress_permissions'),
        ]:
            with self.subTest(module=module), tempfile.TemporaryDirectory() as directory:
                domain = Path(directory)
                root = domain / 'public_html'
                source = root / 'src' / 'index.js'
                source.parent.mkdir(parents=True)
                source.write_text('source')
                source.chmod(0o777)
                source.parent.chmod(0o700)
                generated = []
                for folder in ['.next', '.next-release', '.next.candidate.42',
                               '.next.deploy-backup.42', '.next-release.deploy-backup.42', 'vendor']:
                    file = root / folder / 'nested' / 'output'
                    file.parent.mkdir(parents=True)
                    file.write_text('generated')
                    file.chmod(0o700)
                    file.parent.chmod(0o700)
                    generated.append(file)
                text = (MODULES / module).read_text()
                body = function + '(){' + text.split(function + '(){', 1)[1].split('\n' + following + '(){', 1)[0]
                script = 'chown(){ :; }; APP_TYPE=nodejs; SYSUSER=test;\n' + body
                call = f'{function} test "$1"' if function == 'fix_node_app_permissions' else f'{function} "$1/public_html"'
                # Updated scripts repair existing installations on the next deploy or
                # explicit repair, without changing persisted application config.
                script += '\n' + call + '\n' + call
                result = subprocess.run(['bash', '-c', script, '_', directory], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(source.stat().st_mode & 0o777, 0o644)
                self.assertEqual(source.parent.stat().st_mode & 0o777, 0o755)
                for file in generated:
                    self.assertEqual(file.stat().st_mode & 0o777, 0o700, str(file))
                    self.assertEqual(file.parent.stat().st_mode & 0o777, 0o700)


if __name__ == '__main__':
    unittest.main()
