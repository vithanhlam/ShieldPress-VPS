#!/usr/bin/env python3
"""Local-only security regressions; no VPS, real databases or payload execution."""
import importlib.util
import http.client
import io
import os
from pathlib import Path
import shutil
import shlex
import socket
import subprocess
import tarfile
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1] / 'shieldpress'


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


security = module('security', ROOT / 'core/domain-security.py')
migration = module('migration', ROOT / 'modules/security/domain-boundary-migration.py')
archives = module('archives', ROOT / 'modules/backup/validate-archive.py')
signals = module('signals', ROOT / 'core/purge-signals.py')
job_cleanup = module('job_cleanup', ROOT / 'modules/backup/cleanup-domain-jobs.py')


class SecurityBoundaries(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.domains = self.root / 'domains'
        self.domains.mkdir(mode=0o755)
        self.domains.chmod(0o755)
        self.home = self.domains / 'example_com'
        for name in ('config', 'backup/db', 'public_html', 'tmp'):
            (self.home / name).mkdir(parents=True, exist_ok=True)
        self.env = self.home / 'config/domain.env'
        self.env.write_text('DOMAIN=example.com\nSYSTEM_USER=example_com\nAPP_TYPE=wordpress\nDB_NAME=example_db\nDB_USER=example_user\nDB_PASS=literal$(touch SHOULD_NOT_EXIST)\nSSL=enabled\nSSL_TYPE=letsencrypt\n')

    def repair(self):
        security.domain_control(self.domains, self.home.name, True, os.getuid(), os.getgid())

    def test_control_ancestors_and_repeat_repair(self):
        source = self.home / 'public_html/index.php'
        source.write_text('<?php echo "hello";')
        source.chmod(0o644)
        old = self.home / 'config/auto-backup-db.sh'
        old.write_text('#!/bin/bash\nRETENTION=3\n')
        for _ in range(2):
            self.repair()
            security.domain_control(self.domains, self.home.name, False, os.getuid(), os.getgid())
        self.assertEqual(self.home.stat().st_mode & 0o777, 0o755)
        for name in ('config', 'backup', 'backup/db'):
            self.assertEqual((self.home / name).stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.env.stat().st_mode & 0o777, 0o600)
        self.assertEqual(source.stat().st_mode & 0o777, 0o644)
        self.assertEqual(source.read_text(), '<?php echo "hello";')

    def test_repair_rejects_symlinks_and_hardlinks(self):
        outside = self.root / 'outside'
        outside.write_text('unchanged')
        outside.chmod(0o644)
        link = self.home / 'config/link'
        link.symlink_to(outside)
        with self.assertRaises(ValueError):
            self.repair()
        self.assertEqual(outside.stat().st_mode & 0o777, 0o644)
        link.unlink()
        os.link(outside, link)
        with self.assertRaises(ValueError):
            self.repair()
        self.assertEqual(outside.read_text(), 'unchanged')

    def test_settings_are_literal_and_privileged_users_rejected(self):
        settings = security.read_settings(self.env)
        self.assertEqual(settings['DB_PASS'], 'literal$(touch SHOULD_NOT_EXIST)')
        for text in ('SYSTEM_USER=root\n', 'DOMAIN=x\nDOMAIN=y\n', 'DB_NAME=--all-databases\n', 'PATH=/malicious\n', 'touch /tmp/payload\n',
                     'ROOT=/etc\n', 'PHP_VERSION=../../bin\n', 'CLEAN_DOMAIN=other_domain\n'):
            self.env.write_text(text)
            with self.assertRaises(ValueError):
                security.read_settings(self.env)
        self.env.write_text('SYSTEM_USER=alias\n')
        with patch.object(security.pwd, 'getpwnam', return_value=type('Account', (), {'pw_uid': 0})()):
            with self.assertRaises(ValueError):
                security.read_settings(self.env)

    def test_backup_target_scope_and_spaces(self):
        app = self.home / 'public_html'
        (app / 'normal directory').mkdir()
        (app / 'escape').symlink_to(self.root)
        self.assertEqual(security.backup_targets(app, 'normal directory'), ['normal directory'])
        for bad in ('../config', '/etc', 'escape', '-C', 'normal directory,../../outside'):
            with self.assertRaises((ValueError, OSError)):
                security.backup_targets(app, bad)

    def test_legacy_digit_leading_application_users(self):
        self.env.write_text('SYSTEM_USER=1618art_com\n')
        with patch.object(security.pwd, 'getpwnam', return_value=type('Account', (), {'pw_uid': 1001})()):
            self.assertEqual(security.read_settings(self.env)['SYSTEM_USER'], '1618art_com')
        with patch.object(security.pwd, 'getpwnam', return_value=type('Account', (), {'pw_uid': 0})()):
            with self.assertRaisesRegex(ValueError, 'UID zero'):
                security.read_settings(self.env)
        for user in ('0', '1001', '-1618art', '1618art;id', '1618art/name', '1618art name'):
            self.env.write_text(f'SYSTEM_USER={user}\n')
            with self.assertRaisesRegex(ValueError, 'Invalid application user'):
                security.read_settings(self.env)

    def test_digit_leading_domain_migration_recovers_and_repeats(self):
        renamed = self.domains / '1618art_com'
        self.home.rename(renamed)
        self.home = renamed
        self.env = renamed / 'config/domain.env'
        self.env.write_text('DOMAIN=1618art.com\nCLEAN_DOMAIN=1618art_com\nSYSTEM_USER=1618art_com\nAPP_TYPE=wordpress\n')
        original_settings = self.env.read_text()
        old = renamed / 'config/auto-backup-db.sh'
        old.write_text('RETENTION=3\n')
        cron = [f'# ShieldPress disabled unsafe legacy backup: 0 2 * * * {old}\n']

        def run(argv, **kwargs):
            if argv == ['crontab', '-l']:
                return subprocess.CompletedProcess(argv, 0, cron[0], '')
            self.assertEqual(argv, ['crontab', '-'])
            cron[0] = kwargs['input']
            return subprocess.CompletedProcess(argv, 0, '', '')

        etc = self.root / 'etc'
        etc.mkdir(mode=0o700)
        (etc / 'domain-boundary-pending.txt').write_text('1618art_com: Invalid application user\n')
        with patch.object(migration.subprocess, 'run', side_effect=run):
            for _ in range(2):
                self.assertTrue(migration.migrate(ROOT, self.domains, etc, os.getuid(), os.getgid()))
                self.assertEqual((etc / 'domain-boundary-pending.txt').read_text(), '')
                self.assertEqual(self.env.read_text(), original_settings)
        self.assertIn(str(etc / 'jobs/1618art_com-backup-db.sh'), cron[0])
        self.assertNotIn('disabled unsafe legacy', cron[0])

    def test_legacy_jobs_rebuilt_without_executing_or_copying_old_code(self):
        # Older installations may already have keys saved by the search menu.
        with self.env.open('a') as stream:
            stream.write('MEILI_HOST=http://127.0.0.1:7700\nMEILI_INDEX=products_example_com\n'
                         'MEILI_KEY=literal$(touch SHOULD_NOT_EXIST)\nMEILI_KEY_UID=test-uid\n'
                         'MEILI_KEY_EXPIRES_AT=2036-10-26T00:00:00Z\n')
        original = self.env.read_text()
        self.assertEqual(security.read_settings(self.env)['MEILI_KEY'], 'literal$(touch SHOULD_NOT_EXIST)')
        old = self.home / 'config/auto-backup-db.sh'
        marker = self.root / 'executed'
        old.write_text(f'#!/bin/bash\nRETENTION=5\ntouch {marker}\n')
        cron = [f'0 23 * * * {old}\n']
        calls = []

        def run(argv, **kwargs):
            calls.append(argv)
            if argv == ['crontab', '-l']:
                return subprocess.CompletedProcess(argv, 0, cron[0], '')
            self.assertEqual(argv, ['crontab', '-'])
            cron[0] = kwargs['input']
            return subprocess.CompletedProcess(argv, 0, '', '')

        etc = self.root / 'etc'
        with patch.object(migration.subprocess, 'run', side_effect=run):
            for _ in range(2):
                self.assertTrue(migration.migrate(ROOT, self.domains, etc, os.getuid(), os.getgid()))
        job = etc / 'jobs/example_com-backup-db.sh'
        self.assertIn('bin/domain-backup', job.read_text())
        self.assertNotIn('touch', job.read_text())
        self.assertIn('db full 5', job.read_text())
        self.assertFalse(marker.exists())
        self.assertIn(str(job), cron[0])
        self.assertNotIn(str(old), cron[0])
        self.assertTrue((etc / 'crontab-before-domain-boundary.txt').is_file())
        self.assertEqual(self.env.read_text(), original)

    def test_unknown_setting_diagnostics_do_not_expose_values(self):
        self.env.write_text('UNKNOWN_SETTING=private-secret\n')
        with self.assertRaisesRegex(ValueError, '^Unsupported setting UNKNOWN_SETTING at line 1$'):
            security.read_settings(self.env)
        self.env.write_text('private-secret\n')
        with self.assertRaisesRegex(ValueError, '^Unsupported setting at line 1$'):
            security.read_settings(self.env)

    def test_unsupported_legacy_schedule_stays_pending(self):
        old = self.home / 'config/auto-backup-files.sh'
        old.write_text('RETENTION=5\n')
        cron = [f'0 23 * * * {old} unexpected-argument\n']

        def run(argv, **kwargs):
            if argv[-1] == '-l':
                return subprocess.CompletedProcess(argv, 0, cron[0], '')
            cron[0] = kwargs['input']
            return subprocess.CompletedProcess(argv, 0, '', '')

        with patch.object(migration.subprocess, 'run', side_effect=run):
            for _ in range(2):
                self.assertFalse(migration.migrate(ROOT, self.domains, self.root / 'etc', os.getuid(), os.getgid()))
        self.assertTrue(cron[0].startswith('# ShieldPress disabled'))

    def test_disabled_legacy_job_recovers_after_metadata_compatibility_fix(self):
        old = self.home / 'config/auto-backup-db.sh'
        old.write_text('RETENTION=7\nBACKUP_MODE="incremental"\n')
        original = f'15 3 * * 1 {old}'
        cron = [f'# ShieldPress disabled unsafe legacy backup: {original}\n']

        def run(argv, **kwargs):
            if argv[-1] == '-l':
                return subprocess.CompletedProcess(argv, 0, cron[0], '')
            cron[0] = kwargs['input']
            return subprocess.CompletedProcess(argv, 0, '', '')

        with patch.object(migration.subprocess, 'run', side_effect=run):
            self.assertTrue(migration.migrate(ROOT, self.domains, self.root / 'etc', os.getuid(), os.getgid()))
        job = self.root / 'etc/jobs/example_com-backup-db.sh'
        self.assertIn('15 3 * * 1', cron[0])
        self.assertIn(str(job), cron[0])
        self.assertNotIn('disabled unsafe legacy', cron[0])
        self.assertIn('db incremental 7', job.read_text())

    def test_ssl_provider_metadata_is_supported_and_validated(self):
        self.env.write_text(self.env.read_text().replace('letsencrypt', 'cloudflare'))
        self.assertEqual(security.read_settings(self.env)['SSL_TYPE'], 'cloudflare')
        self.env.write_text(self.env.read_text().replace('cloudflare', 'arbitrary-command'))
        with self.assertRaisesRegex(ValueError, 'SSL provider'):
            security.read_settings(self.env)

    def test_all_stack_legacy_schedules_preserve_schedule_and_mode(self):
        lines = []
        for stack in ('wordpress', 'laravel', 'nodejs', 'php'):
            home = self.domains / f'{stack}_com'
            for name in ('config', 'backup', 'public_html'):
                (home / name).mkdir(parents=True, exist_ok=True)
            (home / 'config/domain.env').write_text(f'DOMAIN={stack}.com\nAPP_TYPE={stack}\n')
            for kind in ('db', 'files', 'full'):
                old = home / f'config/auto-backup-{kind}.sh'
                old.write_text('RETENTION=2\nBACKUP_MODE="incremental"\nexit 99\n')
                lines.append(f'15 3 * * 1 {old}\n')
        cron = [''.join(lines)]

        def run(argv, **kwargs):
            if argv[-1] == '-l':
                return subprocess.CompletedProcess(argv, 0, cron[0], '')
            cron[0] = kwargs['input']
            return subprocess.CompletedProcess(argv, 0, '', '')

        with patch.object(migration.subprocess, 'run', side_effect=run):
            self.assertTrue(migration.migrate(ROOT, self.domains, self.root / 'etc', os.getuid(), os.getgid()))
        jobs = list((self.root / 'etc/jobs').glob('*.sh'))
        self.assertEqual(len(jobs), 12)
        self.assertTrue(all('incremental 2' in job.read_text() and 'exit 99' not in job.read_text() for job in jobs))
        self.assertTrue(all(line.startswith('15 3 * * 1 ') for line in cron[0].splitlines()))

    def archive(self, entries):
        path = self.root / 'test.tar.gz'
        with tarfile.open(path, 'w:gz') as output:
            for name, kind, target in entries:
                member = tarfile.TarInfo(name)
                member.type = kind
                member.linkname = target
                if kind == tarfile.REGTYPE:
                    member.size = 1
                    output.addfile(member, io.BytesIO(b'x'))
                else:
                    output.addfile(member)
        return path

    def test_restore_rejects_escape_and_control_tree_overwrite(self):
        for entries, scope in [
            ([('../outside', tarfile.REGTYPE, '')], None),
            ([('/etc/cron.d/evil', tarfile.REGTYPE, '')], None),
            ([('public_html/index.php', tarfile.REGTYPE, ''), ('config/domain.env', tarfile.REGTYPE, '')], 'public_html'),
            ([('link', tarfile.SYMTYPE, '/etc')], None),
            ([('link', tarfile.SYMTYPE, '../../etc')], None),
            ([('link', tarfile.SYMTYPE, 'inside'), ('link/write', tarfile.REGTYPE, '')], None),
            ([('device', tarfile.CHRTYPE, '')], None),
        ]:
            with self.assertRaises(ValueError):
                archives.validate(self.archive(entries), scope)

    def test_valid_restore_shapes_for_supported_stacks(self):
        for names, scope in [
            (['public_html/index.php', 'public_html/wp-content/test.txt'], 'public_html'),
            (['artisan', 'app/Http/test.php'], None),
            (['package.json', 'src/index.js'], None),
            (['index.php', 'assets/style.css'], None),
        ]:
            self.assertTrue(archives.validate(self.archive([(name, tarfile.REGTYPE, '') for name in names]), scope))

    def test_purge_signal_own_domain_bounded_and_no_symlink_follow(self):
        signal = self.home / 'tmp/.purge-cache'
        with patch.object(signals.subprocess, 'run') as run:
            for value in ('other_domain', 'x' * 10000):
                signal.write_text(value)
                signals.consume(self.domains, Path('/trusted/purge'))
                run.assert_not_called()
            signal.unlink()
            outside = self.root / 'outside-signal'
            outside.write_text('example_com')
            signal.symlink_to(outside)
            signals.consume(self.domains, Path('/trusted/purge'))
            run.assert_not_called()
            signal.unlink()
            signal.write_text('example_com\n')
            signals.consume(self.domains, Path('/trusted/purge'))
            run.assert_called_once_with(['/trusted/purge', 'example_com'], check=True)
            self.assertFalse(signal.exists())
            self.assertEqual(outside.read_text(), 'example_com')

    def test_nginx_migration_repeat_and_rollback(self):
        configs = self.root / 'nginx'
        configs.mkdir(mode=0o755)
        path = configs / 'example.conf'
        original = 'server {\n root /home/domains/example_com/public_html;\n location ~ \\.php$ { return 200; }\n}\n'
        path.write_text(original)
        path.chmod(0o644)
        with patch.object(migration.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as run:
            migration.harden_nginx(configs, os.getuid())
            first = path.read_text()
            migration.harden_nginx(configs, os.getuid())
            self.assertEqual(first, path.read_text())
            self.assertEqual(run.call_count, 2)
            self.assertLess(first.index('ShieldPress application source boundary'), first.index('location ~ \\.php$'))
        path.write_text(original)
        path.chmod(0o644)
        with patch.object(migration.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)):
            with self.assertRaises(RuntimeError):
                migration.harden_nginx(configs, os.getuid())
        self.assertEqual(path.read_text(), original)

    def test_nginx_legacy_writable_configuration_repair_and_retry(self):
        configs = self.root / 'nginx'
        configs.mkdir(mode=0o755)
        path = configs / '1618art_com.conf'
        original = 'server {\n root /home/domains/1618art_com/public_html;\n location ~ \\.php$ { return 200; }\n}\n'
        path.write_text(original)
        path.chmod(0o666)
        with patch.object(migration.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)):
            with self.assertRaises(RuntimeError):
                migration.harden_nginx(configs, os.getuid())
        self.assertEqual(path.read_text(), original)
        self.assertEqual(path.stat().st_mode & 0o777, 0o644)
        with patch.object(migration.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as run:
            migration.harden_nginx(configs, os.getuid())
            first = path.read_text()
            migration.harden_nginx(configs, os.getuid())
            self.assertEqual(run.call_count, 2)
            self.assertEqual(first, path.read_text())
        self.assertIn('ShieldPress application source boundary', first)
        self.assertEqual(path.stat().st_mode & 0o777, 0o644)

    def test_nginx_permission_repair_rejects_links_owners_and_writable_directory(self):
        configs = self.root / 'nginx'
        configs.mkdir(mode=0o755)
        outside = self.root / 'outside.conf'
        outside.write_text('unchanged')
        outside.chmod(0o666)
        path = configs / 'example.conf'
        with patch.object(migration.subprocess, 'run') as run:
            path.symlink_to(outside)
            with self.assertRaises(ValueError):
                migration.harden_nginx(configs, os.getuid())
            path.unlink()
            os.link(outside, path)
            with self.assertRaises(ValueError):
                migration.harden_nginx(configs, os.getuid())
            path.unlink()
            path.write_text('unchanged')
            with self.assertRaises(ValueError):
                migration.harden_nginx(configs, os.getuid() + 1)
            account_stat = list(path.stat())
            account_stat[4] = os.getuid() + 1
            with patch.object(migration.os, 'fstat', return_value=os.stat_result(account_stat)):
                with self.assertRaises(ValueError):
                    migration.harden_nginx(configs, os.getuid())
            path.unlink()
            os.mkfifo(path)
            with self.assertRaises(ValueError):
                migration.harden_nginx(configs, os.getuid())
            configs.chmod(0o777)
            with self.assertRaises(ValueError):
                migration.harden_nginx(configs, os.getuid())
            run.assert_not_called()
        self.assertEqual(outside.read_text(), 'unchanged')
        self.assertEqual(outside.stat().st_mode & 0o777, 0o666)

    def test_real_archive_helpers_preserve_names_and_do_not_evaluate_settings(self):
        app = self.home / 'public_html'
        for name in ('wp-content/themes/demo/style.css', 'wp-content/plugins/demo/main.php',
                     'wp-content/uploads/name\nwith newline.txt', 'src/file with spaces.js', 'artisan', 'index.php'):
            path = app / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('application data')
        helper = self.root / 'helper.sh'
        helper.write_text((ROOT / 'modules/backup/_backup_helper.sh').read_text().replace(
            'BASE_DIR="/opt/shieldpress"', f'BASE_DIR={str(ROOT)!r}').replace(
            'DOMAINS_ROOT="/home/domains"', f'DOMAINS_ROOT={str(self.domains)!r}'))
        marker = self.root / 'executed'
        for stack in ('wordpress', 'laravel', 'nodejs', 'php'):
            for mode in ('full', 'incremental'):
                output = self.root / f'{stack}-{mode}.tar.gz'
                command = '''
source "$HELPER"
backup_progress_available(){ return 1; }
show_operation_eta(){ :; }
show_elapsed(){ :; }
DOMAIN_PATH="$SITE"
BK_ENABLED=1
BK_CUSTOM_PATHS=''
BK_CUSTOM_EXCLUDE='$(touch NEVER_EXECUTE),dummy --checkpoint=1 --checkpoint-action=exec=ignored'
BK_CUSTOM_INCR_EXCLUDE='$(touch NEVER_EXECUTE)'
if [ "$MODE" = full ]; then archive_source_to_file "$OUTPUT"; else archive_source_incremental "$OUTPUT" 24; fi
'''
                result = subprocess.run(['bash', '-c', command], capture_output=True, text=True,
                    env={**os.environ, 'HELPER': str(helper), 'SITE': str(self.home),
                         'APP_TYPE': stack, 'MODE': mode, 'OUTPUT': str(output),
                         'LOG_DIR': str(self.root / 'logs'), 'DATA_DIR': str(self.root / 'data')}, cwd=self.root)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                with tarfile.open(output) as archive:
                    names = archive.getnames()
                    if stack == 'wordpress' or mode == 'full':
                        self.assertTrue(any('name\nwith newline.txt' in name for name in names))
                    self.assertTrue(all(not name.startswith('/') and '..' not in Path(name).parts for name in names), names)
        self.assertFalse(marker.exists())
        self.assertFalse((self.root / 'NEVER_EXECUTE').exists())

    @unittest.skipUnless(shutil.which('nginx'), 'local nginx binary required')
    def test_nginx_guard_syntax(self):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        config = self.root / 'nginx.conf'
        config.write_text(f'pid {self.root}/nginx.pid;\nerror_log stderr;\nevents {{}}\nhttp {{\n access_log off;\n server {{ listen 127.0.0.1:{port};\n' +
                          migration.NGINX_GUARDS + '\n location ~ \\.php$ { return 200; }\n }\n}\n')
        result = subprocess.run(['nginx', '-t', '-p', str(self.root), '-c', str(config)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        process = subprocess.Popen(['nginx', '-p', str(self.root), '-c', str(config), '-g', 'daemon off;'], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            ready = False
            for _ in range(50):
                try:
                    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=1)
                    connection.request('GET', '/index.php')
                    response = connection.getresponse()
                    ready = response.status == 200
                    response.read()
                    connection.close()
                    if ready:
                        break
                except OSError:
                    time.sleep(0.02)
            self.assertTrue(ready, 'Local Nginx fixture did not start')
            for path, expected in [('/index.php', 200), ('/wp-config.php', 403), ('/hidden/.secret.php', 403),
                                   ('/wp-content/uploads/test.php', 403), ('/wp-content/cache/test.PHP', 403)]:
                connection = http.client.HTTPConnection('127.0.0.1', port, timeout=2)
                connection.request('GET', path)
                response = connection.getresponse()
                self.assertEqual(response.status, expected, path)
                response.read()
                connection.close()
        finally:
            process.terminate()
            process.communicate(timeout=5)

    def test_fixed_job_runner_failure_cleanup_and_restore_package(self):
        # Mock only DB/network/control dependencies, and exercise the actual runner.
        base = self.root / 'runtime'
        for name in ('core', 'modules/backup', 'logs'):
            (base / name).mkdir(parents=True, exist_ok=True)
        (base / 'core/paths.sh').write_text(f'DOMAINS_ROOT={str(self.domains)!r}\nLOG_DIR={str(base / "logs")!r}\n')
        (base / 'core/domain-security.sh').write_text('''
sp_domain_control(){ return 0; }
sp_load_domain_env(){ DOMAIN=example.com; DB_NAME=demo; DB_CONNECTION=mysql; }
''')
        (base / 'modules/backup/_backup_helper.sh').write_text('''
load_domain_info(){ BK_ENABLED=1; DB_BACKUP_ENABLED=1; }
backup_db_to_file(){ [ "${DUMP_FAIL:-0}" = 0 ] || return 1; printf 'fixture SQL' | gzip > "$1"; }
archive_source_to_file(){ tar -czf "$1" -C "$DOMAIN_PATH" public_html; }
archive_source_incremental(){ [ "${NO_CHANGES:-0}" != 1 ] || return 2; archive_source_to_file "$1"; }
prune_local_backups(){ :; }
remote_upload_backup(){ test -f "$1" || return 1; return "${UPLOAD_FAIL:-0}"; }
shieldpress_notify_event(){ :; }
warn(){ printf '%s\\n' "$*"; }
ok(){ printf '%s\\n' "$*"; }
''')
        (self.home / 'public_html/index.php').write_text('application data')
        command = ['bash', str(ROOT / 'bin/domain-backup'), self.home.name]
        env = {**os.environ, 'BASE_DIR': str(base)}
        for kind in ('db', 'files', 'full'):
            result = subprocess.run(command + [kind, 'full', '3'], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        output = next((self.home / 'backup/full').glob('*.tar.gz'))
        self.assertTrue(archives.validate(output))
        with tarfile.open(output) as package:
            self.assertEqual(set(package.getnames()), {'db.sql.gz', 'domain.env', 'files.tar.gz'})
            self.assertIn(b'application data', __import__('gzip').decompress(package.extractfile('files.tar.gz').read()))
        before = set((self.home / 'backup/db').glob('*.gz'))
        failed = subprocess.run(command + ['db', 'full', '3'], env={**env, 'DUMP_FAIL': '1'}, capture_output=True)
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(set((self.home / 'backup/db').glob('*.gz')), before)
        self.assertFalse(list((self.home / 'backup').glob('.job.*')))
        failed_upload = subprocess.run(command + ['db', 'full', '3'], env={**env, 'UPLOAD_FAIL': '1'}, capture_output=True)
        self.assertNotEqual(failed_upload.returncode, 0)
        self.assertGreater(len(list((self.home / 'backup/db').glob('*.gz'))), len(before))
        no_changes = subprocess.run(command + ['files', 'incremental', '3'], env={**env, 'NO_CHANGES': '1'}, capture_output=True, text=True)
        self.assertEqual(no_changes.returncode, 0, no_changes.stderr)
        self.assertIn('backup skipped', no_changes.stdout)
        complete = subprocess.run(command + ['full', 'incremental', '3'], env={**env, 'NO_CHANGES': '1'}, capture_output=True, text=True)
        self.assertEqual(complete.returncode, 0, complete.stderr)
        self.assertIn('full_full_', complete.stdout)

    def test_domain_delete_removes_only_its_central_jobs(self):
        etc = self.root / 'etc'
        jobs = etc / 'jobs'
        jobs.mkdir(parents=True)
        sibling = self.domains / 'example_com_extra'
        (sibling / 'config').mkdir(parents=True)
        (sibling / 'config/domain.env').write_text('DOMAIN=other.example\n')
        current_job = jobs / 'example_com-backup-db.sh'
        other_job = jobs / 'example_com_extra-backup-db.sh'
        for path in (current_job, other_job):
            path.write_text('#!/bin/bash\n')
        cron = [f'0 1 * * * {current_job}\n0 2 * * * {other_job}\n']
        base = self.root / 'base'
        (base / 'config/auto-backup').mkdir(parents=True)

        def run(argv, **kwargs):
            if argv[-1] == '-l':
                return subprocess.CompletedProcess(argv, 0, cron[0], '')
            cron[0] = kwargs['input']
            return subprocess.CompletedProcess(argv, 0, '', '')

        with patch.object(job_cleanup.subprocess, 'run', side_effect=run):
            job_cleanup.cleanup(base, self.domains, str(self.home), etc=etc)
        self.assertFalse(current_job.exists())
        self.assertTrue(other_job.exists())
        self.assertNotIn(str(current_job), cron[0])
        self.assertIn(str(other_job), cron[0])

    def test_release_ownership_and_staging_permissions(self):
        repo = ROOT.parent
        workflow = (repo / '.github/workflows/release.yml').read_text()
        command = next(line.strip() for line in workflow.splitlines() if line.strip().startswith('tar '))
        args = shlex.split(command)
        archive = self.root / 'release.tar.gz'
        args[args.index('/tmp/shieldpress.tar.gz')] = str(archive)
        subprocess.run(args, cwd=repo, check=True, capture_output=True)
        with tarfile.open(archive) as package:
            for member in package:
                self.assertEqual((member.uid, member.gid), (0, 0))
                self.assertEqual(member.mode & 0o022, 0)
        staging = self.root / 'staging'
        staging.mkdir()
        source = staging / 'source.sh'
        source.write_text('#!/bin/bash\n')
        source.chmod(0o777)
        secret = staging / 'secret.env'
        secret.write_text('private')
        secret.chmod(0o600)
        outside = self.root / 'outside'
        outside.write_text('external data')
        outside.chmod(0o666)
        (staging / 'runtime').symlink_to(outside)
        updater = (ROOT / 'modules/update/updater.sh').read_text()
        block = updater.split('# Never activate root-executed code', 1)[1].split('# Ensure symlinks', 1)[0]
        block = block.split('\n', 1)[1]
        subprocess.run(['bash', '-ec', 'chown(){ :; }; fail(){ exit 1; };\n' + block],
                       env={**os.environ, 'NEW_DIR': str(staging)}, check=True)
        self.assertEqual(source.stat().st_mode & 0o777, 0o755)
        self.assertEqual(secret.stat().st_mode & 0o777, 0o600)
        self.assertEqual(outside.stat().st_mode & 0o777, 0o666)

    def test_retention_preserves_newline_names_and_outside_files(self):
        directory = self.root / 'backups'
        directory.mkdir()
        outside = self.root / 'keep-outside.sql.gz'
        outside.write_text('keep outside')
        older = directory / 'old\nname with spaces.sql.gz'
        older.write_text('old')
        os.utime(older, (1, 1))
        newest = directory / 'newest.sql.gz'
        newest.write_text('new')
        text = (ROOT / 'modules/backup/_backup_helper.sh').read_text()
        function = 'prune_local_backups(){' + text.split('prune_local_backups(){', 1)[1].split('\n}\n', 1)[0] + '\n}\n'
        subprocess.run(['bash', '-ec', function + '\nprune_local_backups "$1" 1 "*.sql.gz"', '_', str(directory)], check=True)
        self.assertFalse(older.exists())
        self.assertTrue(newest.exists())
        self.assertEqual(outside.read_text(), 'keep outside')


if __name__ == '__main__':
    unittest.main()
