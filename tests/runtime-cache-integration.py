#!/usr/bin/env python3
"""Real Nginx and PHP-FPM cache checks in a disposable integration container."""
import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('cache', ROOT / 'shieldpress/modules/helpers/wordpress-cache.py')
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)
php_binary = next(Path('/usr/sbin').glob('php-fpm[0-9]*'))
budget_spec = importlib.util.spec_from_file_location('budget', ROOT / 'shieldpress/modules/helpers/php-budget.py')
budget = importlib.util.module_from_spec(budget_spec)
budget_spec.loader.exec_module(budget)
from unittest.mock import patch
with tempfile.TemporaryDirectory() as temp:
    base = Path(temp)
    for branch, stacks in [('php84', ['wordpress', 'laravel', 'php']), ('php83', ['legacy'])]:
        directory = base / f'etc/opt/remi/{branch}'
        pools = directory / 'php-fpm.d'
        pools.mkdir(parents=True)
        (directory / 'php-fpm.conf').write_text(f'[global]\nerror_log = {base}/{branch}.log\ninclude = {pools}/*.conf\n')
        for stack in stacks:
            (pools / f'{stack}.conf').write_text(f'[{stack}]\nuser = nginx\ngroup = nginx\nlisten = {base}/{stack}.sock\npm = ondemand\npm.max_children = 50\n')
    changes, services = budget.plan(base, 7680, 140, 4)
    actual_run = subprocess.run
    def run(command, **kwargs):
        if command[0] == 'systemctl':
            assert command[1] == 'is-active', 'Inactive service must not be reloaded'
            return subprocess.CompletedProcess(command, 3)
        branch = Path(command[0]).parts[3]
        return actual_run([str(php_binary), '-t', '-y', str(base / f'etc/opt/remi/{branch}/php-fpm.conf')], **kwargs)
    with patch.object(budget.subprocess, 'run', side_effect=run):
        budget.apply(changes, services)
    assert not budget.plan(base, 7680, 140, 4)[0]
    print('PASS: real PHP-FPM validates shared multi-branch WordPress/Laravel/PHP pools; inactive services remain inactive; repeat repair is unchanged')
processes = []
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    root.chmod(0o755)
    (root / 'cache').mkdir(mode=0o777)
    (root / 'index.php').write_text('''<?php
if ($_SERVER['REQUEST_URI'] === '/session') { setcookie('session', 'private'); }
if ($_SERVER['REQUEST_URI'] === '/private') { header('Cache-Control: private, no-store'); }
else { header('Cache-Control: public, max-age=60'); }
echo uniqid('response-', true);
''')
    fpm = root / 'php-fpm.conf'
    fpm.write_text(f'''[global]
error_log = {root}/php-error.log
process.max = 4
[site]
user = nginx
group = nginx
listen = {root}/php.sock
listen.mode = 0666
pm = ondemand
pm.max_children = 4
pm.process_idle_timeout = 10s
''')
    subprocess.run([str(php_binary), '-t', '-y', str(fpm)], check=True)
    (root / 'rules.conf').write_text(cache.RULES)
    config = root / 'nginx.conf'
    block = cache.block('integration').replace(cache.SNIPPET, str(root / 'rules.conf'))
    config.write_text(cache.performance_logs(f'''user nginx;
worker_processes 1;
pid {root}/nginx.pid;
error_log {root}/nginx-error.log;
events {{ worker_connections 128; }}
http {{
    {cache.POLICY}
    fastcgi_cache_path {root}/cache levels=1:2 keys_zone=SHIELDPRESS_integration:10m;
    access_log {root}/access.log;
    server {{
        listen 127.0.0.1:18080;
        location = /robots.txt {{
            access_log off;
            return 200 "robots";
        }}
        location = /static.css {{
            access_log off;
            return 200 "static";
        }}
        location / {{
            include /etc/nginx/fastcgi_params;
            fastcgi_param SCRIPT_FILENAME {root}/index.php;
            fastcgi_pass unix:{root}/php.sock;
            {block}
        }}
    }}
}}
'''))
    subprocess.run(['nginx', '-t', '-p', str(root), '-c', str(config)], check=True)
    try:
        processes.append(subprocess.Popen([str(php_binary), '-F', '-y', str(fpm)]))
        processes.append(subprocess.Popen(['nginx', '-p', str(root), '-c', str(config), '-g', 'daemon off;']))
        def request(path='/', headers=None, data=None):
            req = urllib.request.Request('http://127.0.0.1:18080' + path, headers=headers or {}, data=data)
            with urllib.request.urlopen(req, timeout=5) as response:
                return response.headers.get('X-Cache'), response.read()
        for _ in range(50):
            if (root / 'php.sock').exists() and (root / 'nginx.pid').exists():
                break
            time.sleep(.1)
        first = request()
        second = request()
        assert first[0] == 'MISS' and second[0] == 'HIT' and first[1] == second[1], (first, second)
        # Exercise a live legacy 10 MiB -> 2 MiB metadata-zone migration.
        config.write_text(config.read_text().replace('SHIELDPRESS_integration:10m', 'SHIELDPRESS_integration:2m'))
        (root / 'rules.conf').write_text(cache.RULES + 'add_header X-Test-Policy migrated always;\n')
        subprocess.run(['nginx', '-t', '-p', str(root), '-c', str(config)], check=True)
        subprocess.run(['nginx', '-s', 'reload', '-p', str(root), '-c', str(config)], check=True)
        for _ in range(50):
            with urllib.request.urlopen('http://127.0.0.1:18080/', timeout=5) as response:
                if response.headers.get('X-Test-Policy') == 'migrated':
                    break
            time.sleep(.1)
        else:
            raise AssertionError('New cache zone policy was not activated by reload')
        assert '[emerg]' not in (root / 'nginx-error.log').read_text()
        for kwargs in [dict(data=b'x=1'), dict(headers={'Authorization': 'Bearer test'}),
                       dict(headers={'Cookie': 'wordpress_logged_in_test=1'}),
                       dict(headers={'Cookie': 'wp_woocommerce_session_test=1'}),
                       dict(headers={'Cookie': 'PHPSESSID=test'})]:
            status, body = request(**kwargs)
            assert (status == 'BYPASS' or ('data' in kwargs and status is None)) and body != first[1], (kwargs, status)
        for path in ('/?search=test', '/cart', '/checkout', '/my-account', '/wp-admin/', '/wp-json/test', '/gio-hang'):
            assert request(path)[0] == 'BYPASS', path
        for path in ('/session', '/private'):
            one, two = request(path), request(path)
            assert one[0] == two[0] == 'MISS' and one[1] != two[1], (path, one, two)
        for _ in range(30):
            if 'cache=HIT' in (root / 'access.log').read_text():
                break
            time.sleep(.1)
        assert 'cache=HIT' in (root / 'access.log').read_text()
        print('PASS: real Nginx/PHP-FPM MISS-to-HIT, authenticated/session/POST/query/checkout bypass, Set-Cookie/private protection and timing logs')
    finally:
        for process in reversed(processes):
            process.terminate()
            process.wait(timeout=10)
