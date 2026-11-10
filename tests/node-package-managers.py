#!/usr/bin/env python3
"""Check package-manager selection, Node engines and deployment commands."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'shieldpress/modules/helpers/node-project.js'
SHELL = ROOT / 'shieldpress/modules/helpers/node-packages.sh'


class PackageManagerTests(unittest.TestCase):
    def inspect(self, pkg, files=()):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'package.json').write_text(json.dumps(pkg))
            for name in files:
                (root / name).write_text('')
            return subprocess.run(['node', str(HELPER), directory, shutil.which('npm')],
                                  capture_output=True, text=True)

    def test_pnpm_pin_and_workspace_take_priority_over_stale_npm_lock(self):
        result = self.inspect({'packageManager': 'pnpm@10.11.0'}, ['pnpm-workspace.yaml', 'package-lock.json'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'pnpm\n10.11.0\n')

    def test_script_and_lockfile_detection(self):
        for pkg, files in [({'scripts': {'build': 'pnpm -r --filter "./apps/*" build'}}, []),
                           ({}, ['pnpm-lock.yaml']), ({}, ['pnpm-workspace.yaml'])]:
            result = self.inspect(pkg, files)
            self.assertEqual(result.stdout, 'pnpm\n\n', result.stderr)

    def test_npm_projects_preserved(self):
        for files in [[], ['package-lock.json'], ['npm-shrinkwrap.json']]:
            self.assertEqual(self.inspect({}, files).stdout, 'npm\n\n')

    def test_unsupported_engines_stop_before_install(self):
        result = self.inspect({'engines': {'node': '>=999'}})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('current runtime', result.stderr)
        self.assertEqual(self.inspect({'engines': {'node': '>=18 <999'}}).returncode, 0)
        self.assertEqual(self.inspect({'engines': {'node': '^22 || >=24'}}).returncode, 0)

    def test_invalid_or_conflicting_metadata(self):
        for pkg, files in [({'packageManager': 'pnpm@latest'}, []),
                           ({'packageManager': 'npm@10.9.9'}, ['pnpm-workspace.yaml']),
                           ({'engines': {'node': 'banana'}}, []),
                           ({}, ['yarn.lock'])]:
            self.assertNotEqual(self.inspect(pkg, files).returncode, 0)

    def install_command(self, manager, files, status=0):
        with tempfile.TemporaryDirectory() as directory:
            for name in files:
                (Path(directory) / name).touch()
            script = '''source "$1"
run_with_progress(){ shift 2; "$@"; }
run_pm2(){ printf '%s\\n' "$*"; return "$TEST_STATUS"; }
install_node_project_dependencies testuser
'''
            env = dict(os.environ, NODE_PACKAGE_MANAGER=manager, DOMAIN_PATH=directory, TEST_STATUS=str(status))
            return subprocess.run(['bash', '-c', script, '_', str(SHELL)], cwd=directory,
                                  env=env, capture_output=True, text=True)

    def test_install_command_preserves_lockfiles_and_propagates_failure(self):
        self.assertIn('pnpm install --prod=false --frozen-lockfile', self.install_command('pnpm', ['pnpm-lock.yaml', 'package-lock.json']).stdout)
        self.assertIn('npm ci --include=dev', self.install_command('npm', ['package-lock.json']).stdout)
        self.assertIn('npm install --include=dev', self.install_command('npm', []).stdout)
        self.assertEqual(self.install_command('pnpm', ['pnpm-lock.yaml'], 42).returncode, 42)


if __name__ == '__main__':
    unittest.main()
