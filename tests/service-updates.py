#!/usr/bin/env python3
"""Unit regressions plus optional real DNF tests in a disposable container."""
import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
sys.dont_write_bytecode = True
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('service_updates', ROOT / 'shieldpress/modules/upgrade/service-updates.py')
u = importlib.util.module_from_spec(spec)
spec.loader.exec_module(u)
u.BASE = ROOT / 'shieldpress'


def pkg(name, version, release='1.fixture', epoch=0):
    return SimpleNamespace(name=name, version=version, release=release, epoch=epoch, arch='noarch', reponame='fixture')


class Guards(unittest.TestCase):
    def test_missing_and_custom_versionlock_config(self):
        with tempfile.TemporaryDirectory() as directory:
            conf = SimpleNamespace(pluginconfpath=[directory])
            self.assertIsNone(u.locklist_path(conf, required=False))
            with self.assertRaisesRegex(RuntimeError, 'configuration is missing'):
                u.locklist_path(conf)
            config = Path(directory) / 'versionlock.conf'
            config.write_text('[other]\nretain=yes\n')
            self.assertIsNone(u.locklist_path(conf, required=False))
            custom = Path(directory) / 'custom.list'
            config.write_text('[main]\nlocklist=' + str(custom) + '\n')
            self.assertIsNone(u.locklist_path(conf, required=False))
            with self.assertRaisesRegex(RuntimeError, 'list is missing'):
                u.locklist_path(conf)
            custom.write_text('!nginx-0:1.26.99-*.noarch\n')
            self.assertEqual(u.locklist_path(conf), custom)

    def test_versionlock_repair_preserves_rules_and_repeats(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / 'versionlock.conf'
            config.write_text('[other]\nretain=yes\n')
            rules = Path(directory) / 'versionlock.list'
            original = '!nginx-0:1.26.99-*.noarch\ncustom-0:1-1.*\n'
            rules.write_text(original)
            base = MagicMock()
            base.__enter__.return_value = base
            base.conf.pluginconfpath = [directory]
            dnf = SimpleNamespace(Base=lambda: base)
            with patch.dict(sys.modules, {'dnf': dnf}), patch.object(u.os, 'geteuid', return_value=0), \
                 patch.object(u.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)), patch.object(u, 'run'):
                u.repair_versionlock()
                content = config.read_text()
                u.repair_versionlock()
                self.assertEqual(config.read_text(), content)
            self.assertEqual(rules.read_text(), original)
            self.assertIn('retain = yes', content)

    def test_progress_stops_before_returning_to_prompts(self):
        output = io.StringIO()
        with patch.dict(u.os.environ, {'SHIELDPRESS_UPDATE_TTY': '1'}), contextlib.redirect_stdout(output):
            with self.assertRaisesRegex(RuntimeError, 'stage error'):
                with u.stage('fixture stage', 1):
                    time.sleep(0.25)
                    raise RuntimeError('stage error')
            finished = output.getvalue()
            time.sleep(0.25)
            self.assertEqual(output.getvalue(), finished)
        self.assertIn('ETA ~', finished)

    def test_branches_and_policy(self):
        self.assertEqual(u.branch('nginx', '1.26.2'), '1.26')
        self.assertEqual(u.branch('mariadb', '10.11.9'), '10.11')
        self.assertEqual(u.branch('postgresql', '15.12'), '15')
        self.assertEqual(u.branch('postgresql', '9.6.2'), '9.6')
        self.assertEqual(u.branch('php84', '8.4.27'), '8.4')
        self.assertTrue(u.allowed('php84', '8.4.27'))
        self.assertFalse(u.allowed('php84', '8.5.1'))
        self.assertEqual(u.family('MariaDB-server'), 'mariadb')
        self.assertEqual(u.family('postgresql16-server'), 'postgresql')
        with self.assertRaises(RuntimeError):
            u.branch('nginx', 'unknown')

    def test_transaction_guards(self):
        old = pkg('nginx', '1.26.2')
        def check(new, removed=None):
            tx = SimpleNamespace(install_set=new, remove_set=[old] if removed is None else removed)
            u.validate_transaction(tx, [old], 'nginx', old)
        with patch.object(u, 'compare', return_value=1):
            check([pkg('nginx', '1.26.3')])
            for items in [[], [pkg('nginx', '1.28.1')], [pkg('nginx', '1.26.3'), pkg('mariadb-server', '10.11.2')],
                          [pkg('nginx', '1.26.3'), pkg('nodejs', '26.12.1')]]:
                with self.assertRaises(RuntimeError):
                    check(items)
        with patch.object(u, 'compare', return_value=-1):
            with self.assertRaises(RuntimeError):
                check([pkg('nginx', '1.26.1')])

    def test_empty_advisory_scope_is_rejected(self):
        with patch.object(u, 'run') as run:
            with self.assertRaises(RuntimeError):
                u.audit('nginx', [])
            run.assert_not_called()

    def test_php_source_override(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / 'php-source-84'
            state.mkdir()
            (state / 'active').touch()
            with patch.object(u, 'DATA', Path(directory)):
                with self.assertRaises(RuntimeError):
                    u.check_source_override('php84')
                u.check_source_override('php83')

    def test_backup_failure_and_private_recovery(self):
        # Exercise the actual gzip pipeline, using a failing dump subprocess.
        with tempfile.TemporaryDirectory() as directory:
            original_path = u.Path
            def remap(name):
                if str(name) == '/var/shieldpress/backups/service-updates':
                    return original_path(directory)
                return original_path(name)
            real_popen = subprocess.Popen
            def failed_dump(args, **kwargs):
                return real_popen([sys.executable, '-c', "print('partial SQL'); raise SystemExit(7)"], **kwargs)
            with patch.object(u, 'Path', side_effect=remap), patch.object(u.subprocess, 'Popen', side_effect=failed_dump):
                with self.assertRaisesRegex(RuntimeError, 'Database backup failed'):
                    u.backup('mariadb', pkg('mariadb-server', '10.11.1'))
            recovery = next(Path(directory).iterdir())
            self.assertEqual(recovery.stat().st_mode & 0o777, 0o700)
            self.assertTrue((recovery / 'config.tar.gz').exists())

    def test_service_menu_wiring(self):
        for file, service in [('nginx/nginx-menu.sh', 'nginx'), ('php/php-menu.sh', 'php'),
                              ('database/mariadb-menu.sh', 'mariadb'), ('database/pg-menu.sh', 'postgresql')]:
            text = (ROOT / 'shieldpress/modules' / file).read_text()
            self.assertIn('Version & Security Updates', text)
            self.assertIn('service-updates.sh" ' + service, text)
            wrapper = (ROOT / 'shieldpress/modules/upgrade' / ('upgrade-' + service + '.sh')).read_text()
            self.assertIn('exec bash "$BASE_DIR/modules/upgrade/service-updates.sh" ' + service, wrapper)

    def test_apply_failures_and_service_recovery(self):
        old, new = pkg('nginx', '1.26.2'), pkg('nginx', '1.26.3')
        plan = {'service': 'nginx', 'security_only': False, 'installed': [u.row(old)],
                'install': [u.row(new)], 'remove': [u.row(old)]}
        for scenario in ['cancel', 'backup', 'signature', 'transaction', 'interrupt', 'locks', 'restart', 'inactive', 'success']:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as directory:
                base = MagicMock()
                base.__enter__.return_value = base
                base.transaction.install_set = [new]
                base.sack.query.return_value.installed.return_value = [old]
                base.package_signature_check.return_value = (2, 'Bad signature') if scenario == 'signature' else (0, '')
                if scenario == 'transaction':
                    base.do_transaction.side_effect = RuntimeError('Transaction failed')
                if scenario == 'interrupt':
                    base.do_transaction.side_effect = KeyboardInterrupt()
                calls = []
                def fake_run(args, **kwargs):
                    calls.append(args)
                    if scenario == 'restart' and args[:2] == ['systemctl', 'restart']:
                        raise RuntimeError('Restart failed')
                    if args[:2] == ['rpm', '-qa']:
                        return subprocess.CompletedProcess(args, 0, stdout='nginx|noarch|0|1.26.2|1.fixture\n')
                    return subprocess.CompletedProcess(args, 0, stdout='0:1.26.3-1.fixture')
                with patch.object(u, 'open_base', return_value=base), patch.object(u, 'resolve', return_value=(plan, old)), \
                     patch.object(u, 'backup', return_value=Path(directory)) as backup, \
                     patch.object(u, 'refresh_locks') as locks, patch.object(u, 'run', side_effect=fake_run), \
                     patch.object(u.subprocess, 'run', return_value=subprocess.CompletedProcess([], 3 if scenario == 'inactive' else 0)), \
                     patch('builtins.input', return_value='n' if scenario == 'cancel' else 'y'), \
                     contextlib.redirect_stdout(io.StringIO()):
                    if scenario == 'backup':
                        backup.side_effect = RuntimeError('Backup failed')
                    if scenario == 'locks':
                        locks.side_effect = RuntimeError('Lock failed')
                    if scenario in ['backup', 'signature', 'transaction', 'interrupt', 'locks', 'restart']:
                        with self.assertRaises(RuntimeError):
                            u.apply('nginx', False)
                    else:
                        u.apply('nginx', False)
                    if scenario in ['cancel', 'backup', 'signature']:
                        base.do_transaction.assert_not_called()
                        locks.assert_not_called()
                    else:
                        base.do_transaction.assert_called_once()
                        locks.assert_called_once()
                    restarts = [call for call in calls if call[:2] == ['systemctl', 'restart']]
                    self.assertEqual(bool(restarts), scenario in ['transaction', 'interrupt', 'locks', 'restart', 'success'])

    def test_migration_handoff_and_repeat(self):
        text = (ROOT / 'shieldpress/modules/patches/patches-menu.sh').read_text()
        function = text.split('patch_service_security_updates(){', 1)[1].split('\n}\n', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            commands = '''
set -e
BASE_DIR="$1"
REGISTRY="$BASE_DIR/registry"
touch "$REGISTRY"
patch_applied(){ grep -qxF "$1" "$REGISTRY"; }
patch_mark_done(){ echo "$1" >> "$REGISTRY"; }
ok(){ echo "$1"; }
fail(){ echo "$1"; }
'''
            commands += 'patch_service_security_updates(){' + function + '\n}\n'
            commands += '''
if patch_service_security_updates; then exit 1; fi
[ ! -s "$REGISTRY" ]
cp -a "$2/modules" "$BASE_DIR/"
patch_service_security_updates
patch_service_security_updates
[ "$(wc -l < "$REGISTRY")" = 1 ]
'''
            subprocess.run(['bash', '-c', commands, '_', str(base), str(ROOT / 'shieldpress')], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def test_versionlock_migration_pending_then_repeat(self):
        text = (ROOT / 'shieldpress/modules/patches/patches-menu.sh').read_text()
        function = text.split('patch_service_versionlock_repair(){', 1)[1].split('\n}\n', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            commands = '''
set -e
BASE_DIR="$1"
REGISTRY="$BASE_DIR/registry"
touch "$REGISTRY"
patch_applied(){ grep -qxF "$1" "$REGISTRY"; }
patch_mark_done(){ echo "$1" >> "$REGISTRY"; }
ok(){ echo "$1"; }
fail(){ echo "$1"; }
ready=0
python3(){ [ "$2" = --repair-versionlock ]; [ "$ready" = 1 ]; }
'''
            commands += 'patch_service_versionlock_repair(){' + function + '\n}\n'
            commands += '''
if patch_service_versionlock_repair; then exit 1; fi
[ ! -s "$REGISTRY" ]
ready=1
patch_service_versionlock_repair
patch_service_versionlock_repair
[ "$(wc -l < "$REGISTRY")" = 1 ]
'''
            subprocess.run(['bash', '-c', commands, '_', directory], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


class RealDnf(unittest.TestCase):
    def test_missing_protection_checks_and_repair(self):
        config = Path('/etc/dnf/plugins/versionlock.conf')
        original_config = config.read_bytes()
        locks = Path('/etc/dnf/plugins/versionlock.list')
        original_locks = locks.read_bytes()
        before = subprocess.check_output(['rpm', '-qa'])
        script = str(ROOT / 'shieldpress/modules/upgrade/service-updates.py')
        try:
            config.unlink()
            for service in ['nginx', 'php', 'mariadb', 'postgresql']:
                result = subprocess.run([sys.executable, script, service, 'check'], input='1\n' if service == 'php' else '',
                                        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('Installed packages:', result.stdout)
                self.assertIn('Checks remain read-only', result.stdout)
                self.assertFalse(config.exists())
                self.assertEqual(locks.read_bytes(), original_locks)
                with self.assertRaisesRegex(RuntimeError, 'configuration is missing'):
                    u.apply('php84' if service == 'php' else service, False)
            self.assertEqual(subprocess.check_output(['rpm', '-qa']), before)
            u.repair_versionlock()
            repaired = config.read_bytes()
            self.assertEqual(locks.read_bytes(), original_locks)
            u.repair_versionlock()
            self.assertEqual(config.read_bytes(), repaired)
            # A configured but missing list has the same read-only behavior.
            locks.unlink()
            for service in ['nginx', 'php84', 'mariadb', 'postgresql']:
                with u.open_base(service) as base:
                    plan, _ = u.resolve(base, service, False)
                    self.assertTrue(plan['installed'])
                self.assertFalse(locks.exists())
            u.repair_versionlock()
            self.assertIn('php84-php-fpm-0:', locks.read_text())
        finally:
            config.write_bytes(original_config)
            locks.write_bytes(original_locks)

    def test_all_stacks_and_security_metadata(self):
        if not Path('/.dockerenv').exists():
            self.fail('Real DNF tests require a disposable container')
        with u.open_base('nginx') as base:
            plan, _ = u.resolve(base, 'nginx', True)
            library = list(base.sack.query().available().filter(name='shieldpress-test-library'))
            self.assertTrue(library)
            self.assertTrue(all(p.release == '1.fixture' for p in library))
            self.assertEqual([(p['version'], p['release']) for p in plan['install']], [('1.26.2', '2.fixture')])
        with u.open_base('php84') as base:
            plan, _ = u.resolve(base, 'php84', True)
            self.assertEqual(plan['install'], [])
        advisory = subprocess.run(['dnf', '--disableplugin=versionlock', 'updateinfo', 'info', '--available', '--security', 'nginx'], check=True, stdout=subprocess.PIPE, text=True).stdout
        self.assertIn('CVE-2099-0001', advisory)
        real_run = subprocess.run
        calls = []
        def simulate_services(args, **kwargs):
            if args[0] == 'systemctl' or args[0] in ('nginx', 'mysqladmin', 'sudo') or args[0].endswith('php-fpm'):
                calls.append(args)
                return subprocess.CompletedProcess(args, 0, stdout='')
            return real_run(args, **kwargs)
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(u.subprocess, 'run', side_effect=simulate_services), patch.object(u, 'backup', return_value=Path(directory)) as backup, patch('builtins.input', return_value='y'):
                for service in ['nginx', 'php84', 'mariadb', 'postgresql']:
                    before = real_run(['rpm', '-q', 'nginx', 'php84-php-fpm', 'mariadb-server', 'postgresql-server'], check=True, stdout=subprocess.PIPE, text=True).stdout.splitlines()
                    u.apply(service, service == 'nginx')
                    self.assertEqual(backup.call_args.args[0], service)
                    after = real_run(['rpm', '-q', 'nginx', 'php84-php-fpm', 'mariadb-server', 'postgresql-server'], check=True, stdout=subprocess.PIPE, text=True).stdout.splitlines()
                    changed = [n for n, pair in enumerate(zip(before, after)) if pair[0] != pair[1]]
                    self.assertEqual(changed, [['nginx', 'php84', 'mariadb', 'postgresql'].index(service)])
                    with u.open_base(service) as base:
                        plan, _ = u.resolve(base, service, False)
                        self.assertEqual(plan['install'], [])
            locks = real_run(['dnf', 'versionlock', 'list'], check=True, stdout=subprocess.PIPE, text=True).stdout
            self.assertIn('!nginx-0:1.26.99-*.noarch', locks)
            self.assertIn('shieldpress-test-library-0:1.0-1.fixture', locks)
            for name in ['nginx', 'php84-php-fpm', 'mariadb-server', 'postgresql-server']:
                self.assertRegex(locks, name + r'-0:[^\n]*-2.fixture')
        self.assertEqual(len([call for call in calls if call[:2] == ['systemctl', 'restart']]), 4)


if __name__ == '__main__':
    mode = '--dnf' in sys.argv
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(RealDnf if mode else Guards)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(not result.wasSuccessful())
