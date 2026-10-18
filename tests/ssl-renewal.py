#!/usr/bin/env python3
"""Behavioral SSL regressions with isolated fake Certbot/systemd/Nginx.

No network, root privileges, production /etc files, or real ACME issuance.
Run: python3 shieldpress/tests/ssl-renewal.py
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1] / "shieldpress"
HELPER = ROOT / "modules/ssl/ssl-renewal.sh"
MOCK = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
cmd = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as f:
    f.write(json.dumps([cmd] + args) + '\n')
le = Path(os.environ['SSL_LE_DIR'])
conf = Path(os.environ['CONF'])
domain = os.environ['DOMAIN']
state = Path(os.environ['STATE'])
def install():
    cert = 'wrong.example' if os.environ.get('WRONG_CERT') else domain
    existing = conf.read_text()
    if '# BEGIN ShieldPress HTTP-01' in existing:
        conf.write_text(existing.replace('listen 80;', 'listen 443 ssl;\n'
            + '    ssl_certificate ' + str(le / 'live' / cert / 'fullchain.pem') + ';\n'
            + '    ssl_certificate_key ' + str(le / 'live' / cert / 'privkey.pem') + ';'))
        return
    conf.write_text('server {\n    server_name ' + domain + ';\n    listen 443 ssl;\n'
        + '    ssl_certificate ' + str(le / 'live' / cert / 'fullchain.pem') + ';\n'
        + '    ssl_certificate_key ' + str(le / 'live' / cert / 'privkey.pem') + ';\n}\n')
if cmd == 'systemctl':
    unit = args[-1]
    if args[0] == 'list-unit-files':
        if unit == os.environ.get('NATIVE_TIMER'):
            print(unit + ' disabled')
    elif args[0] == 'enable':
        if os.environ.get('ENABLE_FAIL'):
            sys.exit(1)
        state.write_text(unit)
    elif args[0] in ('is-active', 'is-enabled'):
        if unit in ('nginx', 'postfix', 'dovecot'):
            sys.exit(0)
        sys.exit(0 if state.exists() and state.read_text() == unit else 1)
elif cmd == 'curl':
    if os.environ.get('HTTP_UNREACHABLE'):
        sys.exit(7)
    url = args[-1]
    host = url.split('/')[2]
    probe = Path(os.environ['SSL_ACME_ROOT']) / '.well-known/acme-challenge' / url.rsplit('/', 1)[-1]
    response = Path(args[args.index('--output') + 1])
    attempt_file = Path(os.environ['SSL_ACME_ROOT']) / 'curl-attempts'
    attempt = int(attempt_file.read_text()) + 1 if attempt_file.exists() else 1
    attempt_file.write_text(str(attempt))
    fail = (os.environ.get('HTTP_FAIL_HOST') == host
            or (os.environ.get('HTTP_FAIL_FIRST') and attempt == 1))
    response.write_text('Application error' if fail else
                        'wrong token' if os.environ.get('HTTP_WRONG_TOKEN') else probe.read_text())
    print('500' if fail else '200', end='')
elif cmd == 'nginx':
    if os.environ.get('NGINX_FAIL'):
        sys.exit(1)
elif cmd == 'certbot':
    if args[0] == 'plugins':
        print('nginx')
    elif args[0] == 'reconfigure':
        if os.environ.get('MIGRATE_FAIL'):
            sys.exit(1)
        p = le / 'renewal' / (domain + '.conf')
        p.write_text(p.read_text().replace('standalone', 'nginx'))
    elif args[0] == 'renew':
        if os.environ.get('RENEW_FAIL'):
            sys.exit(1)
        if os.environ.get('DUE'):
            (le / 'live' / domain / 'fullchain.pem').write_text('renewed')
    elif args[0] in ('install', '--nginx', 'run'):
        install()
        if os.environ.get('ISSUE_FAIL'):
            sys.exit(1)
    elif args[0] == 'certonly':
        if os.environ.get('ISSUE_FAIL'):
            sys.exit(1)
        (le / 'live' / domain).mkdir(parents=True, exist_ok=True)
        (le / 'live' / domain / 'fullchain.pem').write_text('new')
        (le / 'renewal' / (domain + '.conf')).write_text('authenticator = nginx\n')
    else:
        sys.exit('Unexpected Certbot operation: ' + repr(args))
elif cmd in ('postconf', 'doveconf'):
    cert = os.environ.get('MAIL_CERT', str(le / 'live' / domain / 'fullchain.pem'))
    print(('<' if cmd == 'doveconf' else '') + cert)
'''


class SSLRegression(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.d = Path(self.tmp.name)
        self.le = self.d / 'letsencrypt'
        self.nginx = self.d / 'nginx'
        self.nginx.mkdir()
        (self.le / 'renewal').mkdir(parents=True)
        self.domain = 'upload.example.com'
        self.conf = self.nginx / 'upload_example_com.conf'
        self.original = 'server {\n    listen 80;\n    server_name upload.example.com;\n}\n'
        self.conf.write_text(self.original)
        self.bin = self.d / 'bin'
        self.bin.mkdir()
        for name in ('certbot', 'systemctl', 'nginx', 'postconf', 'doveconf', 'dig', 'curl'):
            p = self.bin / name
            p.write_text(MOCK)
            p.chmod(0o755)
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}',
                        BASE_DIR=str(ROOT), LOG_DIR=str(self.d / 'logs'),
                        SSL_LE_DIR=str(self.le), SSL_SYSTEMD_DIR=str(self.d / 'systemd'),
                        SSL_NGINX_DIR=str(self.nginx), CONF=str(self.conf),
                        SSL_ACME_ROOT=str(self.d / 'webroot'),
                        SSL_HTTP01_RETRIES='2',
                        CALLS=str(self.d / 'calls'), STATE=str(self.d / 'state'),
                        DOMAIN=self.domain, NATIVE_TIMER='certbot-renew.timer')

    def run_shell(self, code, ok=True):
        result = subprocess.run(['bash', '-c', f'source "{HELPER}"; {code}'],
                                env=self.env, text=True, capture_output=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def calls(self, cmd=None):
        p = self.d / 'calls'
        calls = [json.loads(line) for line in p.read_text().splitlines()] if p.exists() else []
        return [c for c in calls if not cmd or c[0] == cmd]

    def lineage(self, auth='nginx'):
        (self.le / 'live' / self.domain).mkdir(parents=True)
        (self.le / 'live' / self.domain / 'fullchain.pem').write_text('valid-current')
        (self.le / 'renewal' / f'{self.domain}.conf').write_text(
            f'authenticator = {auth}\nserver = https://acme-v02.api.letsencrypt.org/directory\n')

    def test_rhel_and_debian_native_timers(self):
        for timer in ('certbot-renew.timer', 'certbot.timer', 'snap.certbot.renew.timer'):
            self.env['NATIVE_TIMER'] = timer
            self.run_shell('ensure_ssl_auto_renew')
            self.assertEqual((self.d / 'state').read_text(), timer)
        self.assertFalse((self.d / 'systemd').exists())

    def test_missing_native_timer_creates_one_idempotent_fallback(self):
        self.env['NATIVE_TIMER'] = ''
        self.run_shell('ensure_ssl_auto_renew; ensure_ssl_auto_renew')
        units = list((self.d / 'systemd').iterdir())
        self.assertEqual(len(units), 2)
        self.assertIn('Persistent=true', (self.d / 'systemd/shieldpress-certbot-renew.timer').read_text())
        self.assertIn('renew --non-interactive --quiet', (self.d / 'systemd/shieldpress-certbot-renew.service').read_text())

    def test_failed_timer_activation_is_failure(self):
        self.env['ENABLE_FAIL'] = '1'
        result = self.run_shell('ensure_ssl_auto_renew', ok=False)
        self.assertNotIn('SSL auto-renew enabled:', result.stdout)

    def test_new_install_and_wrong_certificate_detection(self):
        self.run_shell('ssl_install_nginx "$DOMAIN" "$CONF" -d "$DOMAIN" -m admin@example.com')
        self.assertIn('listen 443 ssl;', self.conf.read_text())
        self.conf.write_text(self.original)
        self.env['WRONG_CERT'] = '1'
        self.run_shell('ssl_install_nginx "$DOMAIN" "$CONF" -d "$DOMAIN"', ok=False)
        self.assertEqual(self.conf.read_text(), self.original)

    def test_issuance_failure_restores_configuration_and_keeps_certificate(self):
        self.lineage()
        self.env['ISSUE_FAIL'] = '1'
        self.run_shell('ssl_install_nginx "$DOMAIN" "$CONF" -d "$DOMAIN"', ok=False)
        self.assertEqual(self.conf.read_text(), self.original)
        self.assertEqual((self.le / 'live' / self.domain / 'fullchain.pem').read_text(), 'valid-current')
        self.assertFalse(any('delete' in c for c in self.calls('certbot')))

    def test_http_500_blocks_acme_request_and_restores_nginx(self):
        self.env['HTTP_FAIL_HOST'] = 'www.' + self.domain
        result = self.run_shell('ssl_install_nginx "$DOMAIN" "$CONF" -d "$DOMAIN" -d "www.$DOMAIN"', ok=False)
        self.assertIn('HTTP 500', result.stderr)
        self.assertEqual(len(self.calls('curl')), 3)
        self.assertFalse(self.calls('certbot'))
        self.assertEqual(self.conf.read_text(), self.original)
        self.assertFalse(list((self.d / 'webroot/.well-known/acme-challenge').iterdir()))

    def test_http01_retries_transient_old_worker_500_after_reload(self):
        self.env['HTTP_FAIL_FIRST'] = '1'
        result = self.run_shell('ssl_install_nginx "$DOMAIN" "$CONF" -d "$DOMAIN"')
        self.assertEqual(len(self.calls('curl')), 2)
        self.assertIn('HTTP-01 ready: ' + self.domain, result.stdout)
        certbot = self.calls('certbot')[0]
        self.assertEqual(certbot[1], 'run')
        self.assertIn('listen 443 ssl;', self.conf.read_text())

    def test_http_200_wrong_body_also_blocks_acme_request(self):
        self.env['HTTP_WRONG_TOKEN'] = '1'
        self.run_shell('ssl_install_nginx "$DOMAIN" "$CONF" -d "$DOMAIN"', ok=False)
        self.assertFalse(self.calls('certbot'))
        self.assertEqual(self.conf.read_text(), self.original)

    def test_unreachable_http_blocks_acme_request_and_cleans_probe(self):
        self.env['HTTP_UNREACHABLE'] = '1'
        self.run_shell('ssl_install_nginx "$DOMAIN" "$CONF" -d "$DOMAIN"', ok=False)
        self.assertFalse(self.calls('certbot'))
        self.assertEqual(self.conf.read_text(), self.original)
        self.assertFalse(list((self.d / 'webroot/.well-known/acme-challenge').iterdir()))

    def test_http01_configuration_is_persistent_and_idempotent(self):
        self.run_shell('ssl_prepare_http01 "$CONF"; ssl_prepare_http01 "$CONF"')
        text = self.conf.read_text()
        self.assertEqual(text.count('location ^~ /.well-known/acme-challenge/'), 1)
        self.assertIn('try_files $uri =404;', text)
        self.assertIn('auth_basic off;', text)
        self.assertIn('listen 80;', text)

    def test_existing_custom_acme_location_is_preserved(self):
        original = self.original.replace('    listen 80;',
            '    listen 80;\n    location ^~ /.well-known/acme-challenge/ { return 403; }')
        self.conf.write_text(original)
        self.run_shell('ssl_install_nginx "$DOMAIN" "$CONF" -d "$DOMAIN"', ok=False)
        self.assertEqual(self.conf.read_text(), original)
        self.assertFalse(self.calls('certbot'))

    def test_webroot_authentication_keeps_nginx_installer_and_provider(self):
        self.run_shell('ssl_install_nginx "$DOMAIN" "$CONF" -d "$DOMAIN" --server https://acme.example/directory')
        call = self.calls('certbot')[0]
        self.assertEqual(call[1], 'run')
        self.assertEqual(call[call.index('--authenticator') + 1], 'webroot')
        self.assertEqual(call[call.index('--installer') + 1], 'nginx')
        self.assertEqual(call[call.index('--server') + 1], 'https://acme.example/directory')
        self.assertEqual(call[call.index('--webroot-path') + 1], self.env['SSL_ACME_ROOT'])
        self.assertIn('location ^~ /.well-known/acme-challenge/', self.conf.read_text())

    def test_existing_certificate_is_reused_and_missing_https_repaired(self):
        self.lineage()
        self.run_shell('ssl_renew_nginx "$DOMAIN" "$CONF"')
        self.assertIn('listen 443 ssl;', self.conf.read_text())
        self.assertEqual((self.le / 'live' / self.domain / 'fullchain.pem').read_text(), 'valid-current')
        self.assertEqual([c[1] for c in self.calls('certbot')], ['renew', 'install'])
        self.assertFalse(any('--force-renewal' in c for c in self.calls('certbot')))

    def test_due_certificate_is_renewed(self):
        self.lineage()
        self.env['DUE'] = '1'
        self.run_shell('ssl_renew_nginx "$DOMAIN" "$CONF"')
        self.assertEqual((self.le / 'live' / self.domain / 'fullchain.pem').read_text(), 'renewed')

    def test_failed_renewal_preserves_current_configuration(self):
        self.lineage()
        self.env['RENEW_FAIL'] = '1'
        self.run_shell('ssl_renew_nginx "$DOMAIN" "$CONF"', ok=False)
        self.assertEqual(self.conf.read_text(), self.original)
        self.assertFalse(any(c[1] == 'install' for c in self.calls('certbot')))

    def test_mail_migrates_standalone_even_when_not_due_without_stopping_nginx(self):
        self.lineage('standalone')
        self.run_shell('ssl_install_mail "$DOMAIN" postmaster@example.com')
        self.assertEqual([c[1] for c in self.calls('certbot')], ['reconfigure', 'renew'])
        self.assertIn('authenticator = nginx', (self.le / 'renewal' / f'{self.domain}.conf').read_text())
        self.assertFalse(any(c[1] in ('stop', 'restart') for c in self.calls('systemctl')))

    def test_mail_failed_migration_blocks_renewal(self):
        self.lineage('standalone')
        self.env['MIGRATE_FAIL'] = '1'
        self.run_shell('ssl_install_mail "$DOMAIN" postmaster@example.com', ok=False)
        self.assertEqual([c[1] for c in self.calls('certbot')], ['reconfigure'])

    def test_new_mail_uses_nginx_and_sets_scheduler(self):
        self.run_shell('ssl_install_mail "$DOMAIN" postmaster@example.com')
        self.assertIn('--nginx', self.calls('certbot')[0])
        self.assertEqual((self.d / 'state').read_text(), 'certbot-renew.timer')

    def test_existing_server_migration_and_failed_migration_retry(self):
        self.lineage('standalone')
        script = ROOT / 'modules/ssl/setup-auto-renew.sh'
        self.env['MIGRATE_FAIL'] = '1'
        failed = subprocess.run(['bash', str(script)], env=self.env, capture_output=True, text=True)
        self.assertNotEqual(failed.returncode, 0)
        renewal = self.le / 'renewal' / f'{self.domain}.conf'
        self.assertIn('standalone', renewal.read_text())
        self.env.pop('MIGRATE_FAIL')
        success = subprocess.run(['bash', str(script)], env=self.env, capture_output=True, text=True)
        self.assertEqual(success.returncode, 0, success.stdout + success.stderr)
        self.assertIn('authenticator = nginx', renewal.read_text())
        (self.d / 'calls').write_text('')
        again = subprocess.run(['bash', str(script)], env=self.env, capture_output=True, text=True)
        self.assertEqual(again.returncode, 0)
        self.assertFalse(any(c[1] == 'reconfigure' for c in self.calls('certbot')))

    def test_existing_install_does_not_claim_success_when_timer_fails(self):
        self.lineage()
        self.env['ENABLE_FAIL'] = '1'
        domain_path = self.d / 'domain'
        (domain_path / 'config').mkdir(parents=True)
        (domain_path / 'config/domain.env').write_text(f'DOMAIN={self.domain}\nSSL=disabled\n')
        result = subprocess.run(['bash', str(ROOT / 'modules/ssl/install-ssl.sh'), str(domain_path)],
                                env=self.env, stdin=subprocess.DEVNULL, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('Auto-renew enabled for', result.stdout)

    def test_hook_reloads_only_matching_mail_services_even_if_nginx_test_fails(self):
        self.run_shell('ensure_ssl_auto_renew')
        self.env['RENEWED_LINEAGE'] = str(self.le / 'live' / self.domain)
        hook = self.le / 'renewal-hooks/deploy/50-shieldpress-reload'
        result = subprocess.run(['bash', str(hook)], env=self.env, capture_output=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn(['systemctl', 'reload', 'postfix'], self.calls())
        self.assertIn(['systemctl', 'reload', 'dovecot'], self.calls())
        (self.d / 'calls').write_text('')
        self.env['NGINX_FAIL'] = '1'
        result = subprocess.run(['bash', str(hook)], env=self.env, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(['systemctl', 'reload', 'postfix'], self.calls())
        (self.d / 'calls').write_text('')
        self.env['MAIL_CERT'] = '/other/fullchain.pem'
        subprocess.run(['bash', str(hook)], env=self.env, capture_output=True)
        self.assertNotIn(['systemctl', 'reload', 'postfix'], self.calls())
        self.assertNotIn(['systemctl', 'reload', 'dovecot'], self.calls())

    def test_install_menus_route_existing_lineage_to_renewal_without_prompts(self):
        self.lineage()
        domain_path = self.d / 'domain'
        (domain_path / 'config').mkdir(parents=True)
        env_file = domain_path / 'config/domain.env'
        for installer in ('install-ssl.sh', 'install-ssl-zerossl.sh'):
            env_file.write_text(f'DOMAIN={self.domain}\nSSL=disabled\n')
            (self.d / 'calls').write_text('')
            result = subprocess.run(['bash', str(ROOT / 'modules/ssl' / installer), str(domain_path)],
                                    env=self.env, stdin=subprocess.DEVNULL, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual([c[1] for c in self.calls('certbot')], ['plugins', 'plugins', 'renew', 'install'])
            self.assertIn('SSL=enabled', env_file.read_text())
            self.assertNotIn('Include www', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
