#!/usr/bin/env python3
"""Regression coverage for shared budgets, cache migration and transactional repair."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / f'shieldpress/modules/helpers/{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


php = load('php-budget')
cache = load('wordpress-cache')
schedule = load('warmup-schedule')


def branch(root, name, count):
    directory = root / f'etc/opt/remi/{name}'
    pools = directory / 'php-fpm.d'
    pools.mkdir(parents=True)
    (directory / 'php-fpm.conf').write_text('[global]\n; process.max = 0\ninclude=php-fpm.d/*.conf\n')
    for i in range(count):
        (pools / f'pool{i}.conf').write_text(f'[pool{i}]\nuser = site{i}\nlisten = /run/{name}-{i}.sock\npm = ondemand\npm.max_children = 50\n')
    return directory


with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    a = branch(root, 'php84', 36)
    b = branch(root, 'php83', 2)
    changes, services = php.plan(root, 7680, 140, 4)
    assert sum(services.values()) <= 24
    assert sum(services.values()) <= (int(7680 * .4) - 512) // 140
    assert services['php84'] > services['php83'] >= 1
    for path, text in changes.items():
        if path.parent.name == 'php-fpm.d':
            assert 'user = site' in text and 'pm = ondemand' in text
        path.write_text(text)
    assert not php.plan(root, 7680, 140, 4)[0]
    pool = a / 'php-fpm.d/pool0.conf'
    pool.write_text('[custom]\npm = dynamic\npm.max_children = 2\npm.start_servers = 2\npm.min_spare_servers = 1\npm.max_spare_servers = 2\n')
    changes, services = php.plan(root, 1024, 256, 1)
    assert sum(services.values()) >= 2
    assert 'pm.max_children = 1' in changes[pool]
    assert 'pm.start_servers = 1' in changes[pool]
    original = pool.read_text()
    for fail_at in ('test', 'reload'):
        def run(command, **kwargs):
            if (fail_at == 'test' and '-t' in command) or (fail_at == 'reload' and 'reload' in command and kwargs.get('check')):
                raise subprocess.CalledProcessError(1, command)
            return subprocess.CompletedProcess(command, 0)
        with patch.object(php.subprocess, 'run', side_effect=run):
            try:
                php.apply({pool: changes[pool]}, services)
            except subprocess.CalledProcessError:
                pass
            else:
                raise AssertionError('Apply failure must propagate')
        assert pool.read_text() == original

legacy = '''server {
    location ~ \\.php$ {
        fastcgi_pass unix:/run/php.sock;
        set $skip_cache 0;
        if ($request_method = POST) { set $skip_cache 1; }
        fastcgi_cache_bypass $skip_cache;
        fastcgi_no_cache $skip_cache;
        fastcgi_cache SHIELDPRESS_wp_test;
        fastcgi_cache_key "$scheme$request_method$host$request_uri";
        fastcgi_cache_valid 200 301 302 6h;
        fastcgi_cache_lock on;
        add_header X-Powered-By "ShieldPress VPS" always;
        add_header X-Cache $upstream_cache_status;
    }
}
'''
updated = cache.rewrite(legacy, 'wp_test')
assert '$skip_cache' not in updated and 'sp-v2:' in updated
assert cache.rewrite(updated, 'wp_test') == updated
assert cache.SNIPPET in updated
assert 'fastcgi_cache' not in cache.rewrite(updated, 'wp_test', True)
disabled_legacy = 'server {\nlocation ~ \\.php$ {\nfastcgi_pass unix:/run/php.sock;\nfastcgi_cache_lock on;\nfastcgi_cache_lock_timeout 10s;\n}\n}\n'
assert 'fastcgi_cache_lock on;' not in cache.rewrite(disabled_legacy, 'wp_test')
custom = legacy.replace('        fastcgi_cache_lock on;', '        fastcgi_ignore_headers Set-Cookie;\n        proxy_pass http://custom;')
try:
    cache.rewrite(custom, 'wp_test')
except ValueError:
    pass
else:
    raise AssertionError('Custom blocks must require review')

with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    (root / 'var/cache').mkdir(parents=True)
    conf = root / 'etc/nginx/conf.d/wp_test.conf'
    conf.parent.mkdir(parents=True)
    conf.write_text(legacy)
    for name, kind in [('wp_test', 'wordpress'), ('laravel_test', 'laravel'), ('node_test', 'nodejs'), ('php_test', 'php')]:
        domain = root / f'home/domains/{name}/config'
        domain.mkdir(parents=True)
        (domain / 'domain.env').write_text(f'APP_TYPE={kind}\n')
        if name != 'wp_test':
            try:
                cache.build(root, [name])
            except ValueError:
                pass
            else:
                raise AssertionError(f'Page cache must not be enabled for {kind}')
    changes = cache.build(root, ['wp_test'])
    for path, text in changes.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    assert not cache.build(root, ['wp_test'])
    extra = root / 'etc/nginx/snippets/new.conf'
    original = conf.read_text()
    for fail_at in ('test', 'reload'):
        def run(command, **kwargs):
            if kwargs.get('check') and ((fail_at == 'test' and command == ['nginx', '-t']) or (fail_at == 'reload' and 'reload' in command)):
                # Fail once, allowing restored configuration validation/reload.
                run.failed = getattr(run, 'failed', False)
                if not run.failed:
                    run.failed = True
                    raise subprocess.CalledProcessError(1, command)
            return subprocess.CompletedProcess(command, 0)
        with patch.object(cache.subprocess, 'run', side_effect=run):
            try:
                cache.apply({conf: 'invalid', extra: 'new'})
            except subprocess.CalledProcessError:
                pass
            else:
                raise AssertionError('Cache failures must propagate')
        assert conf.read_text() == original and not extra.exists()

cron = '0 0 * * * bash /opt/shieldpress/modules/cache/warmup-cache.sh --auto wp.test\n15 3 * * * bash /custom/job\n'
staggered = schedule.stagger(cron)
assert staggered != cron and '15 3 * * * bash /custom/job' in staggered
assert schedule.stagger(staggered) == staggered
# Old updaters call the installed patches script; failures remain pending, retries mark once.
patches = (ROOT / 'shieldpress/modules/patches/patches-menu.sh').read_text()
function = 'patch_shared_runtime_budget(){' + patches.split('patch_shared_runtime_budget(){', 1)[1].split('\n}\n', 1)[0] + '\n}\n'
subprocess.run(['bash', '-c', '''
BASE_DIR=/opt/shieldpress
ready=0; marked=0; calls=0
patch_applied(){ [ "$marked" = 1 ]; }
patch_mark_done(){ marked=1; }
info(){ :; }; ok(){ :; }; fail(){ :; }
python3(){ calls=$((calls+1)); [ "$ready" = 1 ]; }
''' + function + '''
if patch_shared_runtime_budget; then exit 1; fi
[ "$marked" = 0 ] || exit 2
ready=1
patch_shared_runtime_budget || exit 3
patch_shared_runtime_budget || exit 4
[ "$marked" = 1 ]
'''], check=True)
assert '30 patch_shared_runtime_budget || ssl_status=$?' in patches
warmup = (ROOT / 'shieldpress/modules/cache/warmup-cache.sh').read_text()
guard = 'set -e\nLOCK_DIR=' + warmup.split('LOCK_DIR=', 1)[1].split('WP_CONFIG=', 1)[0]
with tempfile.TemporaryDirectory() as temp:
    base = Path(temp)
    mem = base / 'meminfo'
    load = base / 'loadavg'
    mem.write_text('MemTotal: 8000000 kB\nMemAvailable: 2000000 kB\n')
    load.write_text('0.1 0.1 0.1 1/100 1\n')
    script = guard.replace('/run/shieldpress/cache-warmup', str(base / 'locks')).replace('/proc/meminfo', str(mem)).replace('/proc/loadavg', str(load))
    first = subprocess.Popen(['bash', '-c', script + '\necho READY; read -r release'], stdout=subprocess.PIPE, stdin=subprocess.PIPE, text=True)
    assert first.stdout.readline().strip() == 'READY'
    second = subprocess.run(['bash', '-c', script], capture_output=True, text=True)
    assert second.returncode == 0 and 'Another cache warmup' in second.stdout
    first.communicate('release\n', timeout=5)
    mem.write_text('MemTotal: 8000000 kB\nMemAvailable: 100000 kB\n')
    assert subprocess.run(['bash', '-c', script], capture_output=True).returncode == 1
    mem.write_text('MemTotal: 8000000 kB\nMemAvailable: 2000000 kB\n')
    load.write_text('9999 9999 9999 1/100 1\n')
    assert subprocess.run(['bash', '-c', script], capture_output=True).returncode == 1
print('PASS: cross-branch budgets, preserved custom limits, dynamic pools, cache migration, stack isolation, rollback, schedules and old-updater retry')
