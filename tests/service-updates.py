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

    def test_nginx_mainline_policy_and_diagnostics(self):
        old = pkg('nginx', '1.31.4', epoch=2)
        new = pkg('nginx', '1.31.8', epoch=2)
        other = pkg('nginx', '1.29.8', epoch=2)
        self.assertTrue(u.package_version_allowed('nginx', new, old, old))
        self.assertFalse(u.package_version_allowed('nginx', other, old, old))
        base = MagicMock()
        base.sack.query.return_value.installed.return_value = [old]
        base.sack.query.return_value.available.return_value = [new, other]
        base.transaction.install_set = [new]
        base.transaction.remove_set = [old]
        with patch.object(u, 'compare', return_value=1):
            plan, _ = u.resolve(base, 'nginx', False)
        self.assertEqual(plan['install'][0]['epoch'], '2')
        self.assertEqual(base.sack.add_excludes.call_args.args[0], [other])
        base.transaction.install_set = []
        base.transaction.remove_set = []
        with patch.object(u, 'allowed', return_value=False), patch.object(u, 'compare', return_value=1), contextlib.redirect_stdout(io.StringIO()) as output:
            u.resolve(base, 'nginx', False)
        self.assertIn('1.31.8 is blocked by config/upgrade-policy.conf', output.getvalue())

    def test_mainline_policy_migration_repeats_and_retains_custom_rules(self):
        text = (ROOT / 'shieldpress/modules/patches/patches-menu.sh').read_text()
        function = text.split('patch_nginx_mainline_policy(){', 1)[1].split('\n}\n', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'config').mkdir()
            policy = root / 'config/upgrade-policy.conf'
            script = 'BASE_DIR="$1"\npatch_applied(){ return 1; }\npatch_mark_done(){ :; }\nok(){ :; }\nfail(){ return 1; }\n'
            script += 'patch_nginx_mainline_policy(){' + function + '\n}\npatch_nginx_mainline_policy\npatch_nginx_mainline_policy\n'
            for original, expected in [('NGINX_ALLOWED="1.26.* 1.28.*"', 'NGINX_ALLOWED="1.26.* 1.28.* 1.31.*"'),
                                       ('NGINX_ALLOWED="1.28.*"', 'NGINX_ALLOWED="1.28.*"')]:
                policy.write_text(original + '\nNGINX_BLOCKED="1.31.7"\n')
                subprocess.run(['bash', '-ec', script, '_', directory], check=True)
                self.assertEqual(policy.read_text(), expected + '\nNGINX_BLOCKED="1.31.7"\n')

    def test_os_audit_preserves_repository_errors(self):
        source = (ROOT / 'shieldpress/modules/security/os-security-patch.sh').read_text()
        source = '\n'.join(line for line in source.splitlines() if not line.startswith('source '))
        source = source.split('if [[ "${BASH_SOURCE[0]}"', 1)[0]
        for status, output, expected in [(1, '', 'security status is unknown'),
                                         (0, '', 'does not prove'),
                                         (0, 'ALSA-test security postfix', 'advisories pending')]:
            script = 'LOG_DIR=/tmp\nDATA_DIR=/tmp\n' + source + '\nvalkey_version(){ return 1; }\ndnf(){ echo "$AUDIT_OUTPUT"; return "$AUDIT_STATUS"; }\nos_security_main --audit\n'
            import os
            env = dict(os.environ, AUDIT_OUTPUT=output, AUDIT_STATUS=str(status))
            result = subprocess.run(['bash', '-c', script], env=env, text=True, capture_output=True)
            self.assertIn(expected, result.stdout)
            self.assertEqual(result.returncode, 0 if status == 0 and not output else 1)

    def test_kernel_updates_without_advisories_and_repeat(self):
        source = (ROOT / 'shieldpress/modules/security/os-security-patch.sh').read_text()
        function = source.split('update_kernel_packages(){', 1)[1].split('\n}\n', 1)[0]
        for scenario in ['success', 'failed', 'container', 'bootfail']:
            script = """
DATA_DIR=/tmp
MANAGED_EXCLUDES=(--exclude=nginx --exclude=php8*-*)
rpm(){ [ "$SCENARIO" != container ] || return 1; echo '5.14.0-fixed.x86_64'; }
uname(){ echo '5.14.0-old.x86_64'; }
grubby(){ [ "$SCENARIO" != bootfail ] || return 1; echo '/boot/vmlinuz-5.14.0-fixed.x86_64'; }
run_with_loading(){ shift 3; "$@"; }
logged(){ printf 'COMMAND'; printf ' <%s>' "$@"; echo; [ "$SCENARIO" != failed ]; }
show_log_tail(){ :; }
"""
            script += 'update_kernel_packages(){' + function + '\n}\n'
            script += 'update_kernel_packages || exit $?\nupdate_kernel_packages\n'
            import os
            result = subprocess.run(['bash', '-uc', script], env=dict(os.environ, SCENARIO=scenario), text=True, capture_output=True)
            if scenario == 'failed':
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('remediation remains pending', result.stdout)
            elif scenario == 'bootfail':
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Cannot verify the default boot kernel', result.stdout)
            elif scenario == 'container':
                self.assertEqual(result.returncode, 0)
                self.assertNotIn('COMMAND', result.stdout)
            else:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.count('<upgrade> <kernel*>'), 2)
                self.assertIn('--setopt=skip_if_unavailable=false', result.stdout)
                self.assertIn('no automatic reboot', result.stdout)
                self.assertNotIn('<--security>', result.stdout)
        hook = (ROOT / 'shieldpress/modules/patches/patches-menu.sh').read_text()
        self.assertIn('os-security-patch.sh" --apply', hook)
        self.assertIn('update_kernel_packages || status=1', source)
        self.assertLess(source.index('if ! os_security_enabled;'), source.index('update_kernel_packages || status=1'))

    def test_kernel_audit_without_advisory_metadata(self):
        source = (ROOT / 'shieldpress/modules/security/os-security-patch.sh').read_text()
        source = '\n'.join(line for line in source.splitlines() if not line.startswith('source '))
        source = source.split('if [[ "${BASH_SOURCE[0]}"', 1)[0]
        for status, expected in [(100, 'Kernel updates are pending'), (1, 'Kernel update query failed'), (0, 'Verify the running kernel')]:
            script = 'LOG_DIR=/tmp\nDATA_DIR=/tmp\n' + source + """
valkey_version(){ return 1; }
rpm(){ return 0; }
dnf(){ case " $* " in *' check-update '*) return "$KERNEL_STATUS" ;; *) return 0 ;; esac; }
os_security_main --audit
"""
            import os
            result = subprocess.run(['bash', '-uc', script], env=dict(os.environ, KERNEL_STATUS=str(status)), text=True, capture_output=True)
            self.assertIn(expected, result.stdout)
            self.assertEqual(result.returncode, 0 if status == 0 else 1)

    def test_kernel_migration_handoff_and_repeat(self):
        text = (ROOT / 'shieldpress/modules/patches/patches-menu.sh').read_text()
        function = text.split('patch_kernel_update_fallback(){', 1)[1].split('\n}\n', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            script = """
set -e
BASE_DIR="$1"
REGISTRY="$BASE_DIR/registry"
touch "$REGISTRY"
patch_applied(){ grep -qxF "$1" "$REGISTRY"; }
patch_mark_done(){ echo "$1" >> "$REGISTRY"; }
ok(){ :; }
fail(){ :; }
"""
            script += 'patch_kernel_update_fallback(){' + function + '\n}\n'
            script += """
if patch_kernel_update_fallback; then exit 1; fi
[ ! -s "$REGISTRY" ]
mkdir -p "$BASE_DIR/modules/security"
cp "$2/modules/security/os-security-patch.sh" "$BASE_DIR/modules/security/"
patch_kernel_update_fallback
patch_kernel_update_fallback
[ "$(wc -l < "$REGISTRY")" = 1 ]
"""
            subprocess.run(['bash', '-c', script, '_', directory, str(ROOT / 'shieldpress')], check=True, capture_output=True)

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

    def test_rpm_suffixes_and_php_extensions(self):
        for version in ['2.0.6~RC1', '2.0.6RC1', '2.0.6^git20261027']:
            self.assertEqual(u.branch('php84', version), '2.0')
        for version in ['unknown', '2', '2..0', '2.0!RC1']:
            with self.assertRaises(RuntimeError):
                u.branch('php84', version)
        anchor = pkg('php84-php-fpm', '8.4.27')
        old = pkg('php84-php-pecl-example', '2.0.5')
        new = pkg(old.name, '2.0.6~RC1')
        base = MagicMock()
        base.sack.query.return_value.installed.return_value = [anchor, old]
        base.sack.query.return_value.available.return_value = [new, pkg(anchor.name, '8.5.1')]
        base.transaction.install_set = [new]
        base.transaction.remove_set = [old]
        with patch.object(u, 'compare', return_value=1):
            for _ in range(2):
                plan, _ = u.resolve(base, 'php84', False)
                self.assertEqual(plan['install'], [u.row(new)])
                excluded = base.sack.add_excludes.call_args.args[0]
                self.assertEqual([p.version for p in excluded], ['8.5.1'])
            with self.assertRaises(RuntimeError):
                u.validate_transaction(SimpleNamespace(install_set=[pkg('php83-php-pecl-example', '2.0.6')],
                                                       remove_set=[]), [anchor, old], 'php84', anchor)
        with patch.object(u, 'compare', return_value=-1):
            with self.assertRaisesRegex(RuntimeError, 'downgrade'):
                u.validate_transaction(base.transaction, [anchor, old], 'php84', anchor)

    def test_nginx_independent_module_versions(self):
        self.assertEqual(u.branch('nginx', '1.0.0~rc'), '1.0')
        anchor = pkg('nginx', '1.26.2')
        old = pkg('nginx-mod-brotli', '1.0.0~rc')
        new = pkg(old.name, '1.0.0')
        core = pkg('nginx-core', '1.26.3')
        wrong_branch = pkg('nginx-core', '1.28.1')
        base = MagicMock()
        base.sack.query.return_value.installed.return_value = [anchor, old]
        base.sack.query.return_value.available.return_value = [new, core, wrong_branch]
        base.transaction.install_set = [new, core]
        base.transaction.remove_set = [old]
        with patch.object(u, 'compare', return_value=1):
            for _ in range(2):
                plan, _ = u.resolve(base, 'nginx', False)
                self.assertEqual(len(plan['install']), 2)
                self.assertEqual(base.sack.add_excludes.call_args.args[0], [wrong_branch])
            base.transaction.install_set = [new, wrong_branch]
            with self.assertRaisesRegex(RuntimeError, 'Branch migration'):
                u.validate_transaction(base.transaction, [anchor, old], 'nginx', anchor)
        for name in ['nginx-mod-brotli', 'nginx-module-njs']:
            self.assertTrue(u.package_version_allowed('nginx', pkg(name, '1.0.0~rc'), old, anchor))
            self.assertFalse(u.package_version_allowed('nginx', pkg(name, '1.0.0~rc'), old,
                                                     pkg('nginx', '1.30.0')))
        base.transaction.install_set = [new]
        with patch.object(u, 'compare', return_value=-1):
            with self.assertRaisesRegex(RuntimeError, 'downgrade'):
                u.validate_transaction(base.transaction, [anchor, old], 'nginx', anchor)

    def test_rpm_version_migration_handoff_and_repeat(self):
        text = (ROOT / 'shieldpress/modules/patches/patches-menu.sh').read_text()
        function = text.split('patch_service_rpm_versions(){', 1)[1].split('\n}\n', 1)[0]
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
'''
            commands += 'patch_service_rpm_versions(){' + function + '\n}\n'
            commands += '''
if patch_service_rpm_versions; then exit 1; fi
[ ! -s "$REGISTRY" ]
cp -a "$2/modules" "$BASE_DIR/"
patch_service_rpm_versions
patch_service_rpm_versions
[ "$(wc -l < "$REGISTRY")" = 1 ]
'''
            subprocess.run(['bash', '-c', commands, '_', directory, str(ROOT / 'shieldpress')],
                           check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

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
