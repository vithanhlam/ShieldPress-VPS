#!/usr/bin/env python3
"""Create disposable source websites backed by actual MariaDB/PostgreSQL services."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess

spec = importlib.util.spec_from_file_location('migration', '/opt/shieldpress/modules/tools/server-migration.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
e = m.Engine()
e.initialize()
run = lambda args, **kw: subprocess.run(args, check=True, **kw)
for stack in ('wordpress', 'php', 'laravel', 'nodejs'):
    folder = stack + '_test'
    domain = stack + '.test'
    home = e.domains / folder
    app = home / 'public_html'
    for path in (app, home / 'config', home / 'backup', home / 'logs', home / 'tmp/sessions'):
        path.mkdir(parents=True)
    run(['useradd', '-M', '-d', str(home), '-s', '/sbin/nologin', folder])
    engine = 'pgsql' if stack == 'laravel' else 'none' if stack == 'php' else 'mysql'
    values = {'DOMAIN': domain, 'CLEAN_DOMAIN': folder, 'SYSTEM_USER': folder, 'APP_TYPE': stack,
              'DB_CONNECTION': engine, 'DB_NAME': folder + '_db' if engine != 'none' else '',
              'DB_USER': folder + '_user' if engine != 'none' else '', 'DB_PASS': 'copyOnlyPassword123' if engine != 'none' else '',
              'PHP_VERSION': '8.5' if stack != 'nodejs' else '', 'NODE_APP_PORT': '3301' if stack == 'nodejs' else '',
              'NODE_ENTRY': 'app.js' if stack == 'nodejs' else '', 'ROOT': str(app / 'public') if stack == 'laravel' else str(app)}
    if stack == 'php':
        values['SSL_TYPE'] = 'cloudflare'
    e.write_settings(values)
    if engine != 'none':
        e.create_database(values)
        sql = f"CREATE TABLE marker (message varchar(100)); INSERT INTO marker VALUES ('{stack}-database-copied');"
        if engine == 'mysql':
            e.sql(engine, f'USE `{values["DB_NAME"]}`; ' + sql)
        else:
            run(['runuser', '-u', 'postgres', '--', 'psql', '-d', values['DB_NAME'], '-c', sql])
            run(['runuser', '-u', 'postgres', '--', 'psql', '-d', values['DB_NAME'], '-c', f'GRANT SELECT ON marker TO "{values["DB_USER"]}";'])
    (app / '.env').write_text(f'DB_HOST=127.0.0.1\nDB_DATABASE={values["DB_NAME"]}\nDB_USERNAME={values["DB_USER"]}\nDB_PASSWORD={values["DB_PASS"]}\nAPP_KEY=base64:fixture-key-kept\n')
    (app / 'uploads').mkdir()
    (app / 'uploads/keep.txt').write_text(stack + '-uploads-kept')
    (app / 'link').symlink_to(app / 'uploads', target_is_directory=True)
    if stack == 'wordpress':
        (app / 'wp-config.php').write_text("<?php\n" + ''.join("define('%s', '%s');\n" % item for item in (
            ('DB_NAME', values['DB_NAME']), ('DB_USER', values['DB_USER']), ('DB_PASSWORD', values['DB_PASS']), ('DB_HOST', 'localhost'))))
        (app / 'index.php').write_text("<?php require 'wp-config.php'; $db = new mysqli(DB_HOST, DB_USER, DB_PASSWORD, DB_NAME); echo $db->query('SELECT message FROM marker')->fetch_row()[0];")
    elif stack == 'php':
        (app / 'index.php').write_text('<?php echo "php-files-copied";')
    elif stack == 'laravel':
        (app / 'public').mkdir()
        (app / 'storage').mkdir()
        (app / 'bootstrap/cache').mkdir(parents=True)
        (app / 'public/index.php').write_text(f'<?php $db = new PDO("pgsql:host=127.0.0.1;dbname={values["DB_NAME"]}", "{values["DB_USER"]}", "{values["DB_PASS"]}"); echo $db->query("SELECT message FROM marker")->fetchColumn();')
        (app / 'artisan').write_text('<?php echo "artisan fixture completed\\n";')
        (app / 'composer.json').write_text('{"name":"shieldpress/migration-fixture","require":{}}')
    else:
        (app / 'package.json').write_text(json.dumps({'name': 'migration-fixture', 'version': '1.0.0', 'scripts': {'start': 'node app.js', 'build': 'node -e "console.log(\'build complete\')"'}}))
        (app / 'app.js').write_text("require('http').createServer((req,res)=>res.end('nodejs-files-copied')).listen(Number(process.env.PORT), '127.0.0.1');")
        (app / '.env.production').write_text(f'migration=kept\nDATABASE_URL="mysql://{values["DB_USER"]}:{values["DB_PASS"]}@127.0.0.1:3306/{values["DB_NAME"]}"\n')
    run(['chown', '-hR', f'{folder}:{folder}', str(app), str(home / 'tmp')])
    run(['chown', 'nginx:nginx', str(home / 'logs')])
    root = values['ROOT']
    config = f'server {{ listen 80; server_name {domain}; root {root}; index index.php;\n'
    if stack == 'nodejs':
        config += 'location / { proxy_pass http://127.0.0.1:3301; }\n'
    else:
        pool = Path(f'/etc/opt/remi/php85/php-fpm.d/{folder}.conf')
        pool.write_text(f'[{folder}]\nuser={folder}\ngroup={folder}\nlisten=/var/opt/remi/php85/run/php-fpm/{folder}.sock\nlisten.owner=nginx\nlisten.group=nginx\nlisten.mode=0660\npm=ondemand\npm.max_children=5\n')
        config += f'location / {{ try_files $uri $uri/ /index.php?$args; }}\nlocation ~ \\.php$ {{ include /etc/nginx/fastcgi_params; fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name; fastcgi_pass unix:/var/opt/remi/php85/run/php-fpm/{folder}.sock; }}\n'
    config += '}\n'
    if stack == 'php':
        certdir = Path('/etc/nginx/ssl')
        run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(certdir / 'fixture-ca.key'), '-out', str(certdir / 'fixture-ca.crt'), '-days', '2', '-subj', '/CN=ShieldPress migration test CA'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        run(['openssl', 'req', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(certdir / 'php.key'), '-out', str(certdir / 'php.csr'), '-subj', '/CN=php.test'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        (certdir / 'extensions').write_text('subjectAltName=DNS:php.test\nbasicConstraints=CA:FALSE\n')
        run(['openssl', 'x509', '-req', '-in', str(certdir / 'php.csr'), '-CA', str(certdir / 'fixture-ca.crt'), '-CAkey', str(certdir / 'fixture-ca.key'), '-CAcreateserial', '-out', str(certdir / 'php.crt'), '-days', '2', '-extfile', str(certdir / 'extensions')], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        options = Path('/etc/letsencrypt/options-ssl-nginx.conf')
        options.parent.mkdir(parents=True, exist_ok=True)
        options.write_text('ssl_session_timeout 1d;\n')
        snippets = Path('/etc/nginx/snippets')
        snippets.mkdir(exist_ok=True)
        (snippets / 'migration-shared.conf').write_text('ssl_dhparam /etc/nginx/ssl/shared-dhparam.pem;\n')
        run(['openssl', 'genpkey', '-genparam', '-algorithm', 'DH', '-pkeyopt', 'group:ffdhe2048', '-out', '/etc/nginx/ssl/shared-dhparam.pem'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        auth = Path('/etc/nginx/auth/php_test.htpasswd')
        auth.parent.mkdir(exist_ok=True)
        password = subprocess.check_output(['openssl', 'passwd', '-apr1', 'fixture-password']).decode().strip()
        auth.write_text('fixture-user:' + password + '\n')
        auth.chmod(0o640)
        run(['chown', 'root:nginx', str(auth)])
        meta = Path('/var/shieldpress/data/auth/php_test.auth')
        meta.parent.mkdir(exist_ok=True)
        meta.write_text('MODE=url\nURL=/private\nAUTH_USER=fixture-user\nAUTH_PASS=fixture-password\nSTATUS=on\n')
        meta.chmod(0o600)
        location = f'location = /private {{ auth_basic "migration fixture"; auth_basic_user_file {auth}; alias {app}/uploads/keep.txt; }}\n'
        config = config.rsplit('}', 1)[0] + location + '}\n'
        config += config.replace('listen 80;', 'listen 443 ssl; ssl_certificate /etc/nginx/ssl/php.crt; ssl_certificate_key /etc/nginx/ssl/php.key; ssl_client_certificate /etc/nginx/ssl/fixture-ca.crt; include /etc/letsencrypt/options-ssl-nginx.conf; include /etc/nginx/snippets/migration-shared.conf;')
    Path(f'/etc/nginx/conf.d/{folder}.conf').write_text(config)
subprocess.run(['crontab', '-'], input=b'*/5 * * * * /home/domains/wordpress_test/public_html/task.sh\n', check=True)
run(['nginx', '-t'])
run(['systemctl', 'reload', 'nginx'])
print('Created four isolated source fixtures')
