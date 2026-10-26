#!/usr/bin/env python3
"""Real-engine, isolated report-only YARA regression checks."""
import hashlib
import contextlib
import io
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1] / 'shieldpress'
spec = importlib.util.spec_from_file_location('scanner', ROOT / 'modules/security/yara-scan.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class ScanTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = patch.multiple(m, BASE=ROOT, DOMAINS=self.root / 'domains',
                                  REPORTS=self.root / 'logs/yara', CONFIG=self.root / 'etc/yara.json',
                                  UNITS=self.root / 'units', RULES=ROOT / 'modules/security/yara-rules/webshell.yar')
        self.env.start()
        self.addCleanup(self.env.stop)
        m.UNITS.mkdir()
        for stack in ('wordpress', 'php', 'laravel', 'nodejs'):
            domain = m.DOMAINS / stack
            (domain / 'config').mkdir(parents=True)
            (domain / 'config/domain.env').write_text(f'DOMAIN={stack}.example\nAPP_TYPE={stack}\n')
            (domain / 'public_html').mkdir()
            (domain / 'public_html/index.txt').write_text('normal application content')
        self.config = dict(m.DEFAULTS)

    @unittest.skipUnless(shutil.which('yara') and shutil.which('yarac'), 'real YARA CLI required')
    def test_indirect_loaders_and_benign_data_handling(self):
        # Text-only fixtures: these samples are scanned, never passed to PHP.
        cases = [
            ('<?php $d=str_rot13("fixture"); eval($d($data));', 'SP_PHP_Indirect_Encoded_Execution'),
            ('<?php $d="bas e64 _de cod e"; eval($code);', 'SP_PHP_Indirect_Encoded_Execution'),
            ('<?php $content=file_get_contents("https://invalid.example/fixture"); eval($content);', 'SP_PHP_Remote_Code_Execution'),
            ('<?php fseek($f,__COMPILER_HALT_OFFSET__); $x=gzinflate($blob); $t=tmpfile(); include $path; __halt_compiler();fixture', 'SP_PHP_Appended_Payload_Loader'),
            ('<?php $x=base64_decode($_POST["fixture"]); $_SESSION["data"]=$x; eval("comment".$code);', 'SP_PHP_Session_Payload_Execution'),
            ('<?php echo base64_decode("ordinary data");', ''),
            ('<?php echo file_get_contents("https://invalid.example/data");', ''),
        ]
        for index, (text, expected) in enumerate(cases):
            path = self.root / f'fixture-{index}.php'
            path.write_text(text)
            result = subprocess.run(['yara', str(m.RULES), str(path)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            if expected:
                self.assertIn(expected, result.stdout)
            else:
                self.assertEqual(result.stdout, '')

    def report(self):
        return json.loads(sorted(m.REPORTS.glob('scan-*.json'))[-1].read_text())

    @unittest.skipUnless(shutil.which('yara') and shutil.which('yarac'), 'real YARA CLI required')
    def test_rules_stacks_and_no_file_changes(self):
        samples = {
            'encoded.php': '<?php eval(base64_decode("not executable test data"));',
            'request.php': '<?php system($_GET["test"]);',
            'eicar.txt': 'EICAR-STANDARD-ANTIVIRUS-TEST-FILE!',
            'normal.php': '<?php echo base64_decode("ordinary data");',
            'name\nwith newline.txt': 'normal file name test',
        }
        source = m.DOMAINS / 'wordpress/public_html'
        for name, content in samples.items():
            (source / name).write_text(content)
        (source / 'large.bin').write_bytes(b'x' * (1024 * 1024 + 1))
        (source / 'external').symlink_to(self.root / 'outside')
        (self.root / 'outside').write_text('EICAR-STANDARD-ANTIVIRUS-TEST-FILE!')
        os.mkfifo(source / 'pipe')
        before = {name: hashlib.sha256((source / name).read_bytes()).hexdigest() for name in samples}
        self.config['max_file_mb'] = 1
        self.assertEqual(m.scan('all', self.config), 1)
        report = self.report()
        self.assertEqual(report['status'], 'FINDINGS')
        self.assertEqual(report['matches'], 3)
        self.assertEqual(len(report['domains']), 4)
        self.assertEqual(report['skipped'], 3)
        after = {name: hashlib.sha256((source / name).read_bytes()).hexdigest() for name in samples}
        self.assertEqual(before, after)
        self.assertEqual((sorted(m.REPORTS.glob('scan-*.json'))[-1].stat().st_mode & 0o777), 0o600)

    @unittest.skipUnless(shutil.which('yara') and shutil.which('yarac'), 'real YARA CLI required')
    def test_clean_and_invalid_rules(self):
        self.assertEqual(m.scan('nodejs', self.config), 0)
        self.assertEqual(self.report()['status'], 'NO_MATCHES')
        bad_rules = self.root / 'invalid.yar'
        bad_rules.write_text('not valid YARA')
        with patch.object(m, 'RULES', bad_rules):
            self.assertEqual(m.scan('all', self.config), 2)
        self.assertEqual(self.report()['status'], 'INCOMPLETE')

    def test_engine_failure_never_reports_clean(self):
        with patch.object(m.shutil, 'which', return_value='/mock/yara'), patch.object(
                m, 'run_engine', side_effect=[(0, '', ''), (124, '', 'YARA timeout')]):
            self.assertEqual(m.scan('nodejs', self.config), 2)
        self.assertEqual(self.report()['status'], 'INCOMPLETE')

    def test_missing_engine_retention_and_unknown_domain(self):
        self.config['report_retention'] = 1
        with patch.object(m.shutil, 'which', return_value=None):
            self.assertEqual(m.scan('all', self.config), 2)
        self.assertEqual(m.scan('../outside', self.config), 2)
        self.assertEqual(len(list(m.REPORTS.glob('scan-*.json'))), 1)
        self.assertEqual(self.report()['status'], 'INCOMPLETE')

    def test_timer_configuration_repeat_disable_and_preservation(self):
        args = type('Args', (), dict(schedule='daily', hour=3, notify=False))()
        with patch.object(m.subprocess, 'run') as run, patch.object(m.shutil, 'which', return_value='/bin/yara'):
            m.configure(args)
            original = (m.UNITS / 'shieldpress-yara.service').read_text()
            m.configure(args)
            self.assertEqual((m.UNITS / 'shieldpress-yara.service').read_text(), original)
            self.assertIn('ProtectSystem=strict', original)
            self.assertIn('CPUQuota=25%', original)
            self.assertIn('MemoryMax=384M', original)
            self.assertFalse(json.loads(m.CONFIG.read_text())['notify'])
            args.schedule = 'off'
            m.configure(args)
            self.assertIn('disable', run.call_args.args[0])
        # Source updates do not replace /etc settings, systemd units or reports.
        self.assertEqual(m.load_config(), self.config)

    def test_concurrent_scan_is_rejected(self):
        m.REPORTS.mkdir(parents=True)
        with (m.REPORTS / '.scan.lock').open('w') as lock:
            m.fcntl.flock(lock, m.fcntl.LOCK_EX | m.fcntl.LOCK_NB)
            self.assertEqual(m.scan('all', self.config), 2)
        self.assertFalse(list(m.REPORTS.glob('scan-*.json')))

    def test_changed_files_are_incomplete(self):
        target = m.DOMAINS / 'nodejs/public_html/index.txt'
        def engine(args, *unused):
            if '-C' in args:
                target.write_text('changed during scanning')
            return 0, '', ''
        with patch.object(m.shutil, 'which', return_value='/mock/yara'), patch.object(m, 'run_engine', side_effect=engine):
            self.assertEqual(m.scan('nodejs', self.config), 2)
        self.assertIn('file changed', str(self.report()))

    def test_live_counts_and_partial_report_on_interrupt(self):
        output = io.StringIO()
        with patch.object(m.shutil, 'which', return_value='/mock/yara'), patch.object(
                m, 'run_engine', side_effect=[(0, '', ''), KeyboardInterrupt()]), contextlib.redirect_stdout(output):
            self.assertEqual(m.scan('nodejs', self.config), 2)
        self.assertEqual(self.report()['status'], 'INCOMPLETE')
        self.assertIn('interrupted by user', self.report()['error'])
        self.assertIn('Processed 1/1 candidate files', output.getvalue())
        self.assertIn('ETA:', output.getvalue())
        self.assertIsNone(m.ACTIVE_PROGRESS)

    def test_engine_timeout_is_bounded(self):
        with patch.object(m, 'ACTIVE_PROGRESS', m.ScanProgress()):
            code, _, error = m.run_engine(
                ['bash', '-c', 'sleep 2'], 128, 0.1)
        self.assertEqual(code, 124)
        self.assertIn('timeout', error)

    def test_scan_outcomes_keep_menu_open_with_errexit(self):
        source = (ROOT / 'modules/security/yara-menu.sh').read_text()
        source = source.replace('source "$BASE_DIR/core/paths.sh"', ':')
        for status in (1, 2, 137):
            with self.subTest(status=status):
                script = f'python3() {{ return {status}; }};\n' + source
                # Domain listing may fail, but selecting all still invokes scan.
                result = subprocess.run(['bash', '-e', '-c', script],
                                        input='2\n0\n\n0\n', text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertGreaterEqual(result.stdout.count('YARA MALWARE SCAN'), 2)
                self.assertIn('[WARN]', result.stdout)

    def test_config_rejects_invalid_limits(self):
        m.CONFIG.parent.mkdir()
        m.CONFIG.write_text('{"memory_mb": 0}')
        with self.assertRaises(ValueError):
            m.load_config()

    def test_notification_summary_is_opt_in(self):
        report = dict(status='NO_MATCHES', matches=0, scanned=1, skipped=0, errors=0)
        m.REPORTS.mkdir(parents=True)
        with patch.object(m.subprocess, 'run') as run:
            m.save_report(report, self.config)
            run.assert_not_called()
            self.config['notify'] = True
            run.return_value.returncode = 0
            m.save_report(report, self.config)
            self.assertIn('security_alert', run.call_args.args[0])
            self.assertNotIn('index.txt', str(run.call_args))


if __name__ == '__main__':
    unittest.main()
