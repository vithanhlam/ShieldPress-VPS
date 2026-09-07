#!/usr/bin/env python3
"""Unit regression checks for PM2 migration serialization and file boundaries."""
import importlib.util
from pathlib import Path
import tempfile
import socket
import os
import unittest

spec = importlib.util.spec_from_file_location('migration', Path(__file__).resolve().parents[1] / 'shieldpress/modules/nodejs/migrate-root-pm2.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class MigrationTests(unittest.TestCase):
    def app(self):
        return {'pm2_env': {'exec_mode': 'fork_mode', 'pm_exec_path': '/usr/bin/npm',
                           'pm_cwd': '/home/domains/example/public_html',
                           'args': ['start', '--', '--port', '3001'],
                           'node_args': ['--max-old-space-size=512'],
                           'env': {'PORT': '3001', 'TOKEN': 'example-secret',
                                   'HOME': '/root', 'PM2_HOME': '/root/.pm2'},
                           'pm_out_log_path': '/root/.pm2/logs/example-out.log'}}

    def test_preserves_start_and_app_environment(self):
        app = self.app()
        migrated = m.ecosystem(app, 'example', '/home/domains/example')['apps'][0]
        self.assertEqual(migrated['args'], app['pm2_env']['args'])
        self.assertEqual(migrated['node_args'], ['--max-old-space-size=512'])
        self.assertEqual(migrated['env']['TOKEN'], 'example-secret')
        self.assertEqual(migrated['env']['PORT'], '3001')
        self.assertEqual(migrated['env']['HOME'], '/home/domains/example')
        self.assertNotIn('PM2_HOME', migrated['env'])
        self.assertNotIn('out_file', migrated)
        self.assertEqual(app['pm2_env']['env']['HOME'], '/root')
        original = m.ecosystem(app, 'example')['apps'][0]
        self.assertEqual(original['out_file'], '/root/.pm2/logs/example-out.log')

    def test_rejects_cluster_and_watch(self):
        for key, value in [('exec_mode', 'cluster_mode'), ('instances', 2), ('watch', True)]:
            app = self.app()
            app['pm2_env'][key] = value
            with self.assertRaises(RuntimeError):
                m.ecosystem(app, 'example', '/home/domains/example')

    def test_daemon_banner(self):
        self.assertEqual(m.pm2_apps('[PM2] Spawning daemon\n[{"name":"example"}]'), [{'name': 'example'}])
        self.assertEqual(m.pm2_apps('[]'), [])
        with self.assertRaises(RuntimeError):
            m.pm2_apps('[PM2] connection failed')

    def test_listener_belongs_to_process(self):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen()
            port = listener.getsockname()[1]
            self.assertTrue(m.owns_listener(os.getpid(), port))
            self.assertFalse(m.owns_listener(0, port))
            self.assertFalse(m.owns_listener(999999999, port))

    def test_internal_symlinks_and_external_boundary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'app.js').write_text('test')
            (root / 'bin').mkdir()
            (root / 'bin/start').symlink_to('../app.js')
            records = m.ownership(root)
            self.assertIn(str(root / 'app.js'), [r[0] for r in records])
            self.assertNotIn(str(root / 'bin/start'), [r[0] for r in records])
            (root / 'outside').symlink_to('/etc/passwd')
            with self.assertRaises(RuntimeError):
                m.ownership(root)


if __name__ == '__main__':
    unittest.main()
