#!/usr/bin/env python3
"""Create and repair managed WordPress cache rules with transactional reload."""
import argparse
import datetime
import fcntl
from pathlib import Path
import pwd
import re
import shutil
import subprocess

SNIPPET = '/etc/nginx/snippets/shieldpress-wordpress-cache.conf'
HTTP = '/etc/nginx/conf.d/00-shieldpress-cache-policy.conf'
POLICY = r'''# Managed WordPress cache policy. Preserve upstream Cache-Control and Set-Cookie.
map $request_method $sp_cache_method { default 1; GET 0; HEAD 0; }
map $args $sp_cache_query { default 1; "" 0; }
map $http_authorization $sp_cache_auth { default 1; "" 0; }
map $http_cookie $sp_cache_cookie {
    default 0;
    ~*(wordpress_logged_in|wordpress_sec_|comment_author|wp-postpass|woocommerce_|wp_woocommerce_session_|PHPSESSID|laravel_session) 1;
}
map $request_uri $sp_cache_uri {
    default 0;
    ~*^/(wp-admin|wp-login\.php|wp-cron\.php|wp-json|xmlrpc\.php|cart|checkout|my-account|gio-hang|thanh-toan|tai-khoan)(/|\?|$) 1;
}
map "$sp_cache_method$sp_cache_query$sp_cache_auth$sp_cache_cookie$sp_cache_uri" $sp_cache_skip {
    default 1;
    "00000" 0;
}
log_format shieldpress_perf '$remote_addr - $remote_user [$time_local] "$request" '
    '$status $body_bytes_sent "$http_referer" "$http_user_agent" '
    'host=$host rt=$request_time urt=$upstream_response_time cache=$upstream_cache_status';
'''
RULES = '''# Shared WordPress cache policy; the vhost supplies its own zone and key.
fastcgi_cache_bypass $sp_cache_skip;
fastcgi_no_cache $sp_cache_skip;
fastcgi_cache_valid 200 1h;
fastcgi_cache_lock on;
fastcgi_cache_lock_timeout 5s;
fastcgi_cache_lock_age 5s;
fastcgi_cache_use_stale updating;
fastcgi_cache_background_update on;
add_header X-Cache $upstream_cache_status always;
'''


def block(domain):
    return (f'        fastcgi_cache SHIELDPRESS_{domain};\n'
            '        fastcgi_cache_key "sp-v2:$scheme$request_method$host$request_uri";\n'
            f'        include {SNIPPET};')


def rewrite(text, domain, disable=False):
    # Recognize only ShieldPress's generated legacy or shared block. Refuse custom rules.
    shared = (r'(?m)^[ \t]*fastcgi_cache\s+SHIELDPRESS_' + re.escape(domain) +
              r';\s*\n[ \t]*fastcgi_cache_key[^\n]*\n[ \t]*include ' + re.escape(SNIPPET) + r';')
    legacy = r'(?ms)^[ \t]*set \$skip_cache 0;.*?^[ \t]*add_header X-Cache[^\n]*;'
    replacement = '' if disable else block(domain)
    if re.search(shared, text):
        return re.sub(shared, lambda _: replacement, text)
    if re.search(legacy, text):
        candidate = re.search(legacy, text)[0]
        if not re.search(r'fastcgi_cache\s+SHIELDPRESS_' + re.escape(domain) + r';', candidate):
            raise ValueError('Unrecognized cache zone in legacy block')
        # Reject unexpected statements between known generated cache directives.
        for line in candidate.splitlines():
            line = line.strip()
            if line and not line.startswith(('#', 'set $skip_cache', 'if (', 'fastcgi_', 'add_header X-')):
                raise ValueError('Custom cache block requires manual review')
        return re.sub(legacy, lambda _: replacement, text)
    if re.search(r'(?m)^\s*(fastcgi_cache\s|include .*shieldpress-wordpress-cache)', text):
        raise ValueError('Custom cache configuration requires manual review')
    if disable:
        return text
    matches = list(re.finditer(r'(?m)^[ \t]*fastcgi_pass[^\n]*;', text))
    if len(matches) != 1:
        raise ValueError('Expected exactly one PHP upstream')
    # Older Disable Cache left these generated directives behind. Remove only
    # the exact known defaults before inserting the shared include.
    text = re.sub(r'(?m)^[ \t]*fastcgi_cache_(?:lock on|lock_timeout 10s|use_stale updating|background_update on);[ \t]*\n?', '', text)
    matches = list(re.finditer(r'(?m)^[ \t]*fastcgi_pass[^\n]*;', text))
    match = matches[0]
    return text[:match.end()] + '\n' + block(domain) + text[match.end():]


def wordpress(path):
    env = path / 'config/domain.env'
    values = dict(re.findall(r'(?m)^([A-Z_]+)=[\"\x27]?([^\n\"\x27]*)', env.read_text())) if env.exists() else {}
    app = values.get('APP_TYPE', '')
    return app == 'wordpress' or (not app and (path / 'public_html/wp-config.php').is_file())


def performance_logs(text):
    """Add timing format only to enabled logs without an explicit format/options."""
    # Repair the exact malformed directive produced by v1.3.118 if retained.
    text = re.sub(r'(?m)^([ \t]*access_log[ \t]+off)[ \t]+shieldpress_perf[ \t]*;', r'\1;', text)
    def replace(match):
        if match[2] == 'off':
            return match[0]
        return f'{match[1]}{match[2]} shieldpress_perf;'
    return re.sub(r'(?m)^([ \t]*access_log[ \t]+)([^;\s]+)[ \t]*;', replace, text)


def build(root, domains, disable=False, creating=False):
    changes = {}
    if not disable:
        changes[root / HTTP.lstrip('/')] = POLICY
        changes[root / SNIPPET.lstrip('/')] = RULES
    domain_root = root / 'home/domains'
    count = max(1, sum(p.is_dir() for p in domain_root.glob('*')))
    # max_size is disk usage, not RAM. Share at most 8 GiB / 10% of filesystem.
    disk_mb = shutil.disk_usage(root / 'var/cache').total // (1024 * 1024)
    size_mb = max(16, min(512, min(8192, disk_mb // 10) // count))
    for domain in domains:
        if not re.fullmatch(r'[A-Za-z0-9_]+', domain):
            raise ValueError('Invalid managed domain identifier')
        path = domain_root / domain
        if not disable and not creating and not wordpress(path):
            raise ValueError(f'{domain}: WordPress metadata not found; page cache not enabled')
        conf = root / f'etc/nginx/conf.d/{domain}.conf'
        original = conf.read_text()
        updated = rewrite(original, domain, disable)
        if not disable:
            updated = performance_logs(updated)
        changes[conf] = updated
        zone = root / f'etc/nginx/conf.d/cache-zone-{domain}.conf'
        if not disable:
            changes[zone] = (f'# Managed cache zone: {domain}\nfastcgi_cache_path /var/cache/nginx/{domain} '
                             f'levels=1:2 keys_zone=SHIELDPRESS_{domain}:2m inactive=60m max_size={size_mb}m;\n')
    return {p: text for p, text in changes.items() if not p.exists() or p.read_text() != text}


def apply(changes):
    stamp = datetime.datetime.now().strftime('%Y%m%d%H%M%S%f')
    backups = {}
    active = subprocess.run(['systemctl', 'is-active', '--quiet', 'nginx']).returncode == 0
    try:
        for path, text in changes.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            backup = path.with_name(path.name + '.before-cache-policy.' + stamp) if path.exists() else None
            if backup:
                shutil.copy2(path, backup)
            backups[path] = backup
            path.write_text(text)
        subprocess.run(['nginx', '-t'], check=True)
        if active and changes:
            subprocess.run(['systemctl', 'reload', 'nginx'], check=True)
    except Exception:
        for path, backup in backups.items():
            if backup:
                shutil.copy2(backup, path)
            else:
                path.unlink(missing_ok=True)
        if active:
            subprocess.run(['nginx', '-t'], check=True)
            subprocess.run(['systemctl', 'reload', 'nginx'], check=True)
        raise
    print(f'[OK] WordPress cache policy: {len(changes)} changed files; configuration backups retained')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--domain')
    parser.add_argument('--migrate', action='store_true')
    parser.add_argument('--disable', action='store_true')
    parser.add_argument('--create-wordpress', action='store_true', help='Called by the WordPress domain creation flow')
    args = parser.parse_args()
    try:
        lock_dir = Path('/run/shieldpress/runtime-policy')
        lock_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        lock_stream = (lock_dir / 'configuration.lock').open('a')
        fcntl.flock(lock_stream, fcntl.LOCK_EX)
        root = Path('/')
        if args.migrate:
            domains = [p.name for p in (root / 'home/domains').glob('*') if p.is_dir() and wordpress(p)
                       and (root / f'etc/nginx/conf.d/{p.name}.conf').exists()
                       and re.search(r'(?m)^\s*fastcgi_cache\s+SHIELDPRESS_',
                                     (root / f'etc/nginx/conf.d/{p.name}.conf').read_text())]
        elif args.domain:
            domains = [args.domain]
        else:
            raise ValueError('Choose --domain or --migrate')
        if not domains:
            print('[OK] No enabled managed WordPress caches require repair')
        else:
            changes = build(root, domains, args.disable, args.create_wordpress)
            if not args.disable:
                owner = pwd.getpwnam('nginx')
                for domain in domains:
                    cache = root / f'var/cache/nginx/{domain}'
                    cache.mkdir(parents=True, exist_ok=True)
                    cache.chmod(0o755)
                    import os
                    os.chown(cache, owner.pw_uid, owner.pw_gid)
            apply(changes)
    except Exception as error:
        parser.exit(1, f'[FAIL] WordPress cache repair pending: {error}\n')
