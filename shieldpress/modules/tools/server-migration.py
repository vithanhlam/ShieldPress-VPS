#!/usr/bin/env python3
"""Copy ShieldPress websites between servers without replacing existing resources."""
import argparse
import contextlib
import datetime
import fcntl
import grp
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import pwd
import re
import shlex
import shutil
import socket
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid

sys.dont_write_bytecode = True
PROTOCOL = 2
LOG_PATH = None
BASE = Path(__file__).resolve().parents[2]
DOMAIN_RE = re.compile(r'(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\Z')
NAME_RE = re.compile(r'[A-Za-z_][A-Za-z0-9_-]{0,29}\Z')
DB_RE = re.compile(r'[A-Za-z0-9_][A-Za-z0-9_]{0,62}\Z')


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


security = module('migration_security', BASE / 'core/domain-security.py')
archives = module('migration_archives', BASE / 'modules/backup/validate-archive.py')


def run(args, *, data=None, capture=True, env=None, timeout=120, stream_errors=False):
    result = subprocess.run([str(x) for x in args], input=data, stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture and not stream_errors else None, env=env, timeout=timeout)
    if result.returncode:
        if LOG_PATH:
            with open(LOG_PATH, 'ab') as log:
                log.write(f'[{datetime.datetime.now().isoformat()}] {Path(str(args[0])).name} failed\n'.encode())
                log.write((result.stdout or b'') + (result.stderr or b'') + b'\n')
        # Commands can contain database passwords. Never include argv or SQL in errors.
        detail = ''
        if Path(str(args[0])).name == 'nginx' and result.stderr:
            detail = ': ' + result.stderr.decode(errors='replace').strip()[-2000:]
        raise ValueError(f'{Path(str(args[0])).name} failed (exit {result.returncode}){detail}; inspect the private migration log.')
    return result.stdout or b''


def digest(path):
    value = hashlib.sha256()
    with open(path, 'rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def extract_validated(tar, destination, members=None):
    # Archive validation runs first; use the explicit safe filter when supplied
    # by upstream Python or the AlmaLinux security backport.
    options = {'filter': 'data'} if hasattr(tarfile, 'data_filter') else {}
    tar.extractall(destination, members=members, **options)


def write_json(path, value):
    temp = path.with_name(path.name + '.tmp')
    with open(temp, 'w', encoding='utf-8') as stream:
        os.chmod(temp, 0o600)
        json.dump(value, stream, indent=2)
        stream.write('\n')
    os.replace(temp, path)


def read_json(path):
    return json.loads(path.read_text())


def exists(path):
    return path.exists() or path.is_symlink()


def has_http_auth(text):
    text = re.sub(r'(?m)^\s*#.*$', '', text)
    return any(value.strip().strip('\"\'') != 'off' for value in re.findall(r'\bauth_basic\s+([^;]+);', text))


IPV6_LISTEN = re.compile(r'(?m)^([ \t]*listen[ \t]+)(\[::\](?::[0-9]+)?)([^;\n]*);')


def portable_ipv6_listeners(text):
    # ipv6only=on is Nginx's default, but specifying it twice for one shared
    # socket is an error. Leave the source and existing destination files intact.
    def portable(match):
        options = re.sub(r'(?<!\S)ipv6only=on(?!\S)', '', match[3])
        return match[1] + match[2] + options.rstrip() + ';'
    return IPV6_LISTEN.sub(portable, text)


def nginx_probe(text, identifier):
    text = re.sub(r'(?ms)^[ \t]*# ShieldPress migration probe BEGIN\n.*?^[ \t]*# ShieldPress migration probe END\n?', '', text)
    positions = []
    index, quote, comment = 0, None, False
    while index < len(text):
        char = text[index]
        if comment:
            comment = char != '\n'
        elif quote:
            if char == '\\':
                index += 1
            elif char == quote:
                quote = None
        elif char == '#':
            comment = True
        elif char in '\"\'':
            quote = char
        elif char.isalpha() or char == '_':
            end = index + 1
            while end < len(text) and (text[end].isalnum() or text[end] == '_'):
                end += 1
            if text[index:end] == 'server':
                brace = end
                while brace < len(text) and text[brace].isspace():
                    brace += 1
                if brace < len(text) and text[brace] == '{':
                    positions.append(brace + 1)
            index = end - 1
        index += 1
    if not positions:
        raise ValueError('No Nginx server block found for destination identity verification')
    location = f'''
# ShieldPress migration probe BEGIN
    location = /.well-known/shieldpress-migration-{identifier} {{
        if ($remote_addr != 127.0.0.1) {{ return 404; }}
        auth_basic off;
        default_type text/plain;
        return 200 "{identifier}";
    }}
# ShieldPress migration probe END
'''
    for position in reversed(positions):
        text = text[:position] + location + text[position:]
    return text


def exclusive_file(path, payload, mode=0o600, group=None):
    descriptor, name = tempfile.mkstemp(prefix='.migration-', suffix='.tmp', dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(payload)
        os.chmod(temporary, mode)
        if group:
            shutil.chown(temporary, user='root', group=group)
        # Hard-link publication is atomic and refuses an existing destination.
        os.link(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


@contextlib.contextmanager
def working_directory(path):
    previous = Path.cwd()
    try:
        os.chdir(path)
        yield
    finally:
        os.chdir(previous)


class Engine:
    def __init__(self, root=Path('/')):
        self.root = Path(root)
        self.domains = self.path('/home/domains')
        self.state = self.path('/var/shieldpress/data/server-migration')
        self.packages = self.state / 'packages'
        self.reports = self.state / 'reports'

    def path(self, absolute):
        return self.root / str(absolute).lstrip('/')

    def initialize(self):
        for parent in (self.state.parent, *self.state.parent.parents):
            if parent.exists():
                current = parent.stat()
                if parent.is_symlink() or current.st_uid != os.geteuid() or current.st_mode & 0o022:
                    raise ValueError('Migration storage has an untrusted parent directory')
            if parent == self.root:
                break
        for path in (self.state, self.packages, self.reports):
            if path.is_symlink():
                raise ValueError('Migration storage must not be a symlink')
            if path.exists():
                current = path.stat()
                if current.st_uid != os.geteuid() or current.st_mode & 0o022:
                    raise ValueError('Migration storage is writable by an untrusted account')
            path.mkdir(mode=0o700, parents=True, exist_ok=True)
            os.chmod(path, 0o700)

    def upgrade_storage(self):
        self.initialize()
        legacy = self.packages / 'legacy'
        copied = 0
        for source in (self.path('/opt/shieldpress/migrate'), self.path('/opt/shieldpress_old/migrate')):
            if not source.exists():
                continue
            if source.is_symlink() or source.stat().st_uid != os.geteuid() or source.stat().st_mode & 0o022:
                raise ValueError('Legacy migration storage is untrusted; automatic preservation remains pending')
            for package in source.iterdir():
                if not package.name.endswith(('.tar.gz', '.tar.gz.enc')):
                    continue
                if package.is_symlink() or not package.is_file() or package.stat().st_uid != os.geteuid():
                    raise ValueError('Untrusted legacy package; automatic preservation remains pending')
                legacy.mkdir(mode=0o700, exist_ok=True)
                checksum = digest(package)
                target = legacy / f'{checksum}-{package.name}'
                if target.exists():
                    if digest(target) != checksum:
                        raise ValueError('Previously preserved legacy package checksum changed')
                    continue
                temp = target.with_suffix('.partial')
                shutil.copyfile(package, temp)
                os.chmod(temp, 0o600)
                if digest(temp) != checksum:
                    raise ValueError('Legacy package preservation failed; source retained')
                os.replace(temp, target)
                copied += 1
        return {'copied': copied, 'legacy': str(legacy),
                'note': 'Legacy packages are preserved for recovery. Re-export using Server Migration v2 before importing.'}

    @contextlib.contextmanager
    def lock(self):
        self.initialize()
        with open(self.state / 'migration.lock', 'a') as stream:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise ValueError('Another migration is running on this VPS') from error
            yield

    def identity(self):
        machine = self.path('/etc/machine-id')
        return {'id': hashlib.sha256(machine.read_bytes().strip()).hexdigest(),
                'hostname': socket.gethostname(), 'protocol': PROTOCOL,
                'version': (BASE / 'version.txt').read_text().strip()}

    def settings(self, folder):
        if not NAME_RE.fullmatch(folder):
            raise ValueError('Unsupported domain directory name')
        security.domain_control(self.domains, folder, uid=os.geteuid())
        values = security.read_settings(self.domains / folder / 'config/domain.env')
        values = {key: value for key, value in values.items() if key not in ('SFTP_PASS', 'SFTP_USER', 'SFTP_PORT')}
        values.setdefault('APP_TYPE', 'wordpress')
        values.setdefault('DB_CONNECTION', 'none')
        if not DOMAIN_RE.fullmatch(values.get('DOMAIN', '')):
            raise ValueError('Invalid domain hostname')
        user = values.get('SYSTEM_USER') or folder
        if not NAME_RE.fullmatch(user) or user in ('root', 'nginx', 'postgres', 'mysql'):
            raise ValueError('Unsupported application account')
        values['SYSTEM_USER'] = user
        if values['APP_TYPE'] != 'nodejs' and not re.fullmatch(r'8\.[2-5]', values.get('PHP_VERSION', '')):
            raise ValueError('Migration supports PHP 8.2 through 8.5; update the source runtime first')
        if values['DB_CONNECTION'] != 'none':
            for key in ('DB_NAME', 'DB_USER'):
                if not DB_RE.fullmatch(values.get(key, '')):
                    raise ValueError(f'Unsupported database identifier: {key}')
            if not values.get('DB_PASS'):
                raise ValueError('Managed database password is missing')
        if values['APP_TYPE'] == 'nodejs':
            port = values.get('NODE_APP_PORT') or values.get('NODE_PORT', '')
            if not port.isdigit() or not 1024 <= int(port) <= 65535:
                raise ValueError('Invalid source Node.js port')
            values['NODE_APP_PORT'] = port
            entry = values.get('NODE_ENTRY') or 'app.js'
            if PurePosixPath(entry).is_absolute() or '..' in PurePosixPath(entry).parts or not re.fullmatch(r'[A-Za-z0-9_./-]+', entry):
                raise ValueError('Unsupported Node.js entry path')
            values['NODE_ENTRY'] = entry
        return values

    def inventory(self):
        sites = []
        for path in sorted(self.domains.glob('*/config/domain.env')):
            folder = path.parent.parent.name
            try:
                values = self.settings(folder)
                sites.append({'folder': folder, 'domain': values['DOMAIN'], 'app': values['APP_TYPE']})
            except (OSError, ValueError) as error:
                sites.append({'folder': folder, 'error': str(error)})
        return {'server': self.identity(), 'sites': sites}

    def source_nginx(self, folder):
        main = f'/etc/nginx/conf.d/{folder}.conf'
        pending = [main]
        for prefix in ('cache-zone-', 'cache-zones-'):
            extra = f'/etc/nginx/conf.d/{prefix}{folder}.conf'
            if self.path(extra).is_file():
                pending.append(extra)
        files = {}
        certs = {}
        has_tls = False
        while pending:
            name = pending.pop()
            if name in files:
                continue
            path = self.path(name)
            # Shared configuration is trusted root control data, never app-owned code.
            resolved = path.resolve(strict=True)
            if not resolved.is_relative_to(self.root):
                raise ValueError(f'Nginx dependency escapes the server root: {name}')
            for parent in (resolved, *resolved.parents):
                if parent == self.root.parent:
                    break
                st = parent.stat()
                if st.st_uid != os.geteuid() or st.st_mode & 0o022:
                    raise ValueError(f'Untrusted Nginx dependency: {name}')
                if parent == self.root:
                    break
            data = path.read_bytes()
            if len(data) > 4 * 1024 * 1024:
                raise ValueError(f'Nginx dependency is too large: {name}')
            files[name] = data
            # Extract file dependencies without evaluating configuration as shell code.
            text = re.sub(r'(?m)^\s*#.*$', '', data.decode())
            for directive, raw in re.findall(r'\b(include|ssl_certificate|ssl_certificate_key|ssl_trusted_certificate|ssl_client_certificate|ssl_crl|ssl_dhparam|auth_basic_user_file)\s+([^;]+);', text):
                tokens = shlex.split(raw)
                if len(tokens) != 1 or '$' in tokens[0]:
                    raise ValueError(f'Unsupported dynamic Nginx dependency in {name}')
                item = tokens[0]
                if not item.startswith('/'):
                    item = '/etc/nginx/' + item
                if '..' in PurePosixPath(item).parts:
                    raise ValueError('Nginx dependency contains parent traversal')
                if directive == 'ssl_certificate':
                    has_tls = True
                if directive in ('ssl_certificate', 'ssl_certificate_key', 'ssl_trusted_certificate', 'ssl_client_certificate'):
                    if item not in certs:
                        certs[item] = self.path(item).read_bytes()
                    continue
                if not item.startswith(('/etc/nginx/', '/etc/letsencrypt/', '/etc/ssl/')):
                    raise ValueError(f'Unsupported dependency path: {item}; move it under /etc/nginx first')
                if not item.startswith('/etc/nginx/') and any(char in item for char in '*?['):
                    raise ValueError('Wildcard includes outside /etc/nginx require a reviewed portable configuration')
                matches = sorted(self.root.glob(item.lstrip('/')))
                if not matches and not any(char in item for char in '*?['):
                    raise ValueError(f'Missing Nginx dependency: {item}')
                pending.extend('/' + str(p.relative_to(self.root)) for p in matches)
        # Keep copied certificates separate from Certbot's renewal/account state.
        replacements = {}
        for index, (original, data) in enumerate(sorted(certs.items())):
            target = f'/etc/nginx/ssl/migration-{folder}/cert-{index}.pem'
            replacements[original] = target
            files[target] = data
        private_prefix = f'/etc/nginx/ssl/migration-{folder}/'
        dependencies = [name for name in files if not name.startswith(private_prefix) and
                        (not name.startswith('/etc/nginx/') or name.startswith(('/etc/nginx/snippets/', '/etc/nginx/ssl/')))]
        for index, original in enumerate(sorted(dependencies)):
            suffix = PurePosixPath(original).suffix or '.conf'
            target = private_prefix + f'dependency-{index}{suffix}'
            replacements[original] = target
            files[target] = files.pop(original)
        for name in list(files):
            if not name.endswith('.pem'):
                text = files[name].decode()
                def include(match):
                    tokens = shlex.split(match.group(1))
                    if len(tokens) != 1:
                        raise ValueError('Unsupported Nginx include')
                    pattern = tokens[0] if tokens[0].startswith('/') else '/etc/nginx/' + tokens[0]
                    matches = ['/' + str(path.relative_to(self.root)) for path in sorted(self.root.glob(pattern.lstrip('/')))]
                    return ' '.join('include ' + replacements.get(item, item) + ';' for item in matches)
                text = re.sub(r'\binclude\s+([^;]+);', include, text)
                for original, target in sorted(replacements.items(), key=lambda row: -len(row[0])):
                    text = text.replace(original, target)
                files[name] = text.encode()
        return files, has_tls

    def supplemental(self, folder, values):
        notes = []
        for user in ('root', values['SYSTEM_USER']):
            result = subprocess.run(['crontab', '-u', user, '-l'], capture_output=True)
            if result.returncode == 0:
                lines = [line for line in result.stdout.decode().splitlines()
                         if line.strip() and not line.lstrip().startswith('#') and
                         (user != 'root' or folder in line or values['DOMAIN'] in line)]
                if lines:
                    notes.append({'kind': 'cron', 'user': user, 'content': '\n'.join(lines) + '\n'})
        for parent in ('/etc/supervisord.d', '/etc/supervisor/conf.d', '/etc/cron.d', '/etc/systemd/system'):
            directory = self.path(parent)
            for path in directory.glob('*'):
                if path.is_file() and not path.is_symlink() and path.suffix in ('.ini', '.conf', '.service', '.timer', ''):
                    text = path.read_text(errors='replace')
                    if f'/home/domains/{folder}' in text:
                        if path.name == f'pm2-{values["SYSTEM_USER"]}.service':
                            continue
                        notes.append({'kind': 'service', 'path': parent + '/' + path.name, 'content': text})
        return notes

    def dump_database(self, values, output):
        engine = values['DB_CONNECTION']
        if engine == 'none':
            return
        env = dict(os.environ)
        if engine in ('mysql', 'mariadb'):
            binary = shutil.which('mariadb-dump') or shutil.which('mysqldump')
            if not binary:
                raise ValueError('MariaDB dump client is missing')
            args = [binary, '--single-transaction', '--quick', '--routines', '--triggers', '--events', values['DB_NAME']]
        else:
            env['PGPASSWORD'] = values['DB_PASS']
            args = ['pg_dump', '-h', '127.0.0.1', '-U', values['DB_USER'], '-d', values['DB_NAME'], '--no-owner', '--no-privileges']
        # Spool stderr privately and stream dumps without buffering the database in RAM.
        with tempfile.TemporaryFile() as errors, gzip.open(output, 'wb') as target:
            process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=errors, env=env)
            try:
                shutil.copyfileobj(process.stdout, target, 1024 * 1024)
            finally:
                process.stdout.close()
                status = process.wait()
            if status:
                raise ValueError('Database dump failed; no package was published')
        with gzip.open(output, 'rb') as source:
            if not source.read(1):
                raise ValueError('Database dump is empty')

    def php_modules(self, values):
        short = values['PHP_VERSION'].replace('.', '')
        output = run([self.path(f'/opt/remi/php{short}/root/usr/bin/php'), '-m']).decode()
        return sorted(line.strip() for line in output.splitlines() if line.strip() and not line.startswith('['))

    def source_database_settings(self, values, source):
        if values['APP_TYPE'] == 'wordpress':
            if values['DB_CONNECTION'] not in ('mysql', 'mariadb'):
                raise ValueError('WordPress requires a managed local MySQL/MariaDB database')
            repair = module('migration_wp_source', BASE / 'modules/backup/restore-wordpress-db.py')
            config = source / 'wp-config.php'
            if config.is_symlink() or not config.is_file():
                raise ValueError('WordPress requires a regular wp-config.php')
            text = config.read_text()
            for key, expected in (('DB_NAME', values['DB_NAME']), ('DB_USER', values['DB_USER'])):
                matches = list(repair.definition(key).finditer(text))
                if len(matches) != 1 or matches[0].group(3) != expected:
                    raise ValueError('WordPress database identity differs from domain.env or uses dynamic definitions')
            hosts = list(repair.definition('DB_HOST').finditer(text))
            if len(hosts) != 1 or hosts[0].group(3) not in ('localhost', '127.0.0.1'):
                raise ValueError('External/dynamic WordPress database hosts require a separate reviewed migration')
        if values['APP_TYPE'] in ('laravel', 'nodejs', 'php'):
            from urllib.parse import urlsplit
            for name in ('.env', '.env.production', '.env.local', '.env.production.local'):
                path = source / name
                if not path.is_file():
                    continue
                settings = {}
                for line in path.read_text().splitlines():
                    if '=' in line and not line.lstrip().startswith('#'):
                        key, value = line.split('=', 1)
                        settings[key.strip()] = value.strip().strip('\"\'')
                if settings.get('DB_HOST', 'localhost') not in ('localhost', '127.0.0.1', '::1'):
                    raise ValueError('External application database hosts require a separate reviewed migration')
                for key, managed in (('DB_DATABASE', 'DB_NAME'), ('DB_USERNAME', 'DB_USER')):
                    if settings.get(key) and settings[key] != values.get(managed):
                        raise ValueError(f'Application {key} differs from the managed database')
                for key in ('DATABASE_URL', 'DIRECT_URL'):
                    if settings.get(key):
                        url = urlsplit(settings[key])
                        if values['DB_CONNECTION'] == 'none' or url.hostname not in ('localhost', '127.0.0.1', '::1') or url.path.lstrip('/') != values.get('DB_NAME'):
                            raise ValueError('Application database URL is external or not tracked in domain.env')

    def export(self, folder):
        values = self.settings(folder)
        source = self.domains / folder / 'public_html'
        if not source.is_dir() or source.is_symlink():
            raise ValueError('Website root is missing or is a symlink')
        self.source_database_settings(values, source)
        nginx, tls = self.source_nginx(folder)
        supplemental = self.supplemental(folder, values)
        self.initialize()
        source_bytes = int(run(['du', '--summarize', '--apparent-size', '--count-links', '--block-size=1', source]).split()[0])
        db_bytes_estimate = 0
        if values['DB_CONNECTION'] in ('mysql', 'mariadb'):
            db_bytes_estimate = int(self.sql(values['DB_CONNECTION'], f"SELECT COALESCE(SUM(data_length+index_length),0) FROM information_schema.tables WHERE table_schema='{values['DB_NAME']}';"))
        elif values['DB_CONNECTION'] != 'none':
            db_bytes_estimate = int(self.sql(values['DB_CONNECTION'], f"SELECT pg_database_size('{values['DB_NAME']}');"))
        if shutil.disk_usage(self.state).free < (source_bytes + db_bytes_estimate) * 2 + 512 * 1024 * 1024:
            raise ValueError('Insufficient source scratch space for a safe export; review retained packages before retrying')
        job = uuid.uuid4().hex
        output = self.packages / f'{folder}-{job}.spm.tar.gz'
        with tempfile.TemporaryDirectory(dir=self.state, prefix='export-') as tmp:
            stage = Path(tmp)
            files = stage / 'files.tar.gz'
            total = 0
            print(f'[EXPORT] {values["DOMAIN"]}: copying complete application files...', file=sys.stderr, flush=True)
            with tarfile.open(files, 'w:gz', dereference=False) as tar:
                def add(parent_fd, name, relative):
                    nonlocal total
                    current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
                    info = tarfile.TarInfo(str(relative))
                    info.mode = stat.S_IMODE(current.st_mode) & 0o777
                    info.mtime = current.st_mtime
                    path = source / relative
                    if stat.S_ISLNK(current.st_mode):
                        info.type = tarfile.SYMTYPE
                        resolved = path.resolve(strict=True)
                        if not resolved.is_relative_to(source.resolve()):
                            raise ValueError(f'Website symlink escapes source: {relative}')
                        info.linkname = os.path.relpath(resolved, path.parent)
                        tar.addfile(info)
                        return
                    if not (stat.S_ISREG(current.st_mode) or stat.S_ISDIR(current.st_mode)):
                        raise ValueError(f'Unsupported special website file: {relative}')
                    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
                    if stat.S_ISDIR(current.st_mode):
                        flags |= os.O_DIRECTORY
                    descriptor = os.open(name, flags, dir_fd=parent_fd)
                    try:
                        opened = os.fstat(descriptor)
                        if (opened.st_dev, opened.st_ino, opened.st_mode) != (current.st_dev, current.st_ino, current.st_mode):
                            raise ValueError('Website changed during export; pause writes and retry')
                        if stat.S_ISDIR(opened.st_mode):
                            info.type = tarfile.DIRTYPE
                            tar.addfile(info)
                            for child in sorted(os.listdir(descriptor)):
                                add(descriptor, child, relative / child)
                        else:
                            info.size = opened.st_size
                            total += info.size
                            with os.fdopen(os.dup(descriptor), 'rb') as stream:
                                tar.addfile(info, stream)
                            after = os.fstat(descriptor)
                            if (after.st_size, after.st_mtime_ns) != (opened.st_size, opened.st_mtime_ns):
                                raise ValueError('Website file changed during export; pause writes and retry')
                    finally:
                        os.close(descriptor)
                root_fd = os.open(source, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                try:
                    for child in sorted(os.listdir(root_fd)):
                        add(root_fd, child, PurePosixPath(child))
                finally:
                    os.close(root_fd)
            archives.validate(files)
            if values['APP_TYPE'] != 'nodejs':
                short = values['PHP_VERSION'].replace('.', '')
                pool = self.path(f'/etc/opt/remi/php{short}/php-fpm.d/{folder}.conf')
                if pool.is_symlink() or pool.stat().st_uid != os.geteuid() or pool.stat().st_mode & 0o022:
                    raise ValueError('Untrusted source PHP-FPM pool')
                (stage / 'php-pool.conf').write_bytes(pool.read_bytes())
            auth_metadata = self.path(f'/var/shieldpress/data/auth/{folder}.auth')
            if exists(auth_metadata):
                current = auth_metadata.stat()
                parent = auth_metadata.parent.stat()
                if auth_metadata.is_symlink() or auth_metadata.parent.is_symlink() or current.st_uid != os.geteuid() or current.st_mode & 0o022 or parent.st_uid != os.geteuid() or parent.st_mode & 0o022:
                    raise ValueError('Untrusted HTTP authentication metadata')
                (stage / 'auth-meta').write_bytes(auth_metadata.read_bytes())
            print(f'[EXPORT] {values["DOMAIN"]}: dumping managed database...', file=sys.stderr, flush=True)
            self.dump_database(values, stage / 'database.sql.gz')
            db_bytes = 0
            if (stage / 'database.sql.gz').exists():
                with gzip.open(stage / 'database.sql.gz', 'rb') as stream:
                    for block in iter(lambda: stream.read(1024 * 1024), b''):
                        db_bytes += len(block)
            config = stage / 'nginx'
            for name, payload in nginx.items():
                target = config / name.lstrip('/')
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(payload)
            manifest = {'protocol': PROTOCOL, 'id': job, 'source': self.identity(), 'folder': folder,
                        'settings': values, 'created': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                        'files_bytes': total, 'db_bytes': db_bytes, 'tls': tls, 'supplemental': supplemental,
                        'node_version': run(['node', '--version']).decode().strip() if values['APP_TYPE'] == 'nodejs' else '',
                        'php_modules': self.php_modules(values) if values['APP_TYPE'] != 'nodejs' else [],
                        'checksums': {str(p.relative_to(stage)): digest(p) for p in stage.rglob('*') if p.is_file()}}
            write_json(stage / 'manifest.json', manifest)
            partial = output.with_suffix('.partial')
            print(f'[EXPORT] {values["DOMAIN"]}: packaging and calculating SHA-256...', file=sys.stderr, flush=True)
            try:
                with tarfile.open(partial, 'w:gz') as tar:
                    for child in sorted(stage.iterdir()):
                        tar.add(child, child.name)
                os.chmod(partial, 0o600)
                os.replace(partial, output)
            finally:
                partial.unlink(missing_ok=True)
        output.with_name(output.name + '.sha256').write_text(digest(output) + '\n')
        return {'package': str(output), 'sha256': digest(output), 'bytes': output.stat().st_size,
                'manifest': manifest}

    def validate_manifest(self, manifest):
        if manifest.get('protocol') != PROTOCOL or not re.fullmatch('[a-f0-9]{32}', manifest.get('id', '')):
            raise ValueError('Unsupported migration package; export again using the current Server Migration')
        folder = manifest.get('folder', '')
        values = manifest.get('settings', {})
        if not isinstance(manifest.get('source'), dict) or not re.fullmatch('[a-f0-9]{64}', manifest['source'].get('id', '')):
            raise ValueError('Invalid source server identity')
        if not NAME_RE.fullmatch(folder) or not DOMAIN_RE.fullmatch(values.get('DOMAIN', '')):
            raise ValueError('Invalid package domain identity')
        if values.get('APP_TYPE') not in ('wordpress', 'php', 'laravel', 'nodejs'):
            raise ValueError('Unsupported package application stack')
        user = values.get('SYSTEM_USER', '')
        if not NAME_RE.fullmatch(user) or user in ('root', 'nginx', 'postgres', 'mysql'):
            raise ValueError('Invalid package application account')
        if set(values) - security.KEYS or any(not isinstance(v, str) or any(ord(c) < 32 for c in v) for v in values.values()):
            raise ValueError('Invalid package settings')
        if values.get('DB_CONNECTION') not in ('none', 'mysql', 'mariadb', 'pgsql', 'postgres', 'postgresql'):
            raise ValueError('Unsupported package database')
        if values['DB_CONNECTION'] != 'none':
            if any(not DB_RE.fullmatch(values.get(key, '')) for key in ('DB_NAME', 'DB_USER')) or not values.get('DB_PASS'):
                raise ValueError('Invalid package database credentials')
        if values['APP_TYPE'] != 'nodejs' and not re.fullmatch(r'8\.[2-5]', values.get('PHP_VERSION', '')):
            raise ValueError('Unsupported package PHP runtime')
        if values['APP_TYPE'] == 'nodejs':
            port = values.get('NODE_APP_PORT', '')
            if not port.isdigit() or not 1024 <= int(port) <= 65535:
                raise ValueError('Invalid package Node.js port')
            entry = values.get('NODE_ENTRY', '')
            if not re.fullmatch(r'[A-Za-z0-9_./-]+', entry) or entry.startswith('/') or '..' in PurePosixPath(entry).parts:
                raise ValueError('Invalid package Node.js entry')
        if not isinstance(manifest.get('files_bytes'), int) or manifest['files_bytes'] < 0:
            raise ValueError('Invalid package size')
        if not isinstance(manifest.get('db_bytes'), int) or manifest['db_bytes'] < 0:
            raise ValueError('Invalid database size')
        if values.get('CLEAN_DOMAIN', folder) != folder:
            raise ValueError('Package folder metadata does not match its domain')
        root = values.get('ROOT', f'/home/domains/{folder}/public_html')
        expected_root = PurePosixPath(f'/home/domains/{folder}/public_html')
        if '..' in PurePosixPath(root).parts or not PurePosixPath(root).is_relative_to(expected_root):
            raise ValueError('Package document root escapes its website')
        if not isinstance(manifest.get('supplemental', []), list):
            raise ValueError('Invalid supplemental configuration')
        modules = manifest.get('php_modules', [])
        if not isinstance(modules, list) or any(not isinstance(name, str) or not re.fullmatch(r'[A-Za-z0-9_ +.-]+', name) for name in modules):
            raise ValueError('Invalid PHP extension metadata')
        return manifest

    @contextlib.contextmanager
    def unpack(self, package, expected):
        package = Path(package)
        if not re.fullmatch('[a-f0-9]{64}', expected) or digest(package) != expected:
            raise ValueError('Package SHA-256 mismatch; import was not started')
        archives.validate(package)
        self.initialize()
        with tempfile.TemporaryDirectory(dir=self.state, prefix='inspect-') as tmp:
            stage = Path(tmp)
            with tarfile.open(package, 'r:gz') as tar:
                members = tar.getmembers()
                if any(not (m.isfile() or m.isdir()) for m in members):
                    raise ValueError('Links are not allowed in the outer migration package')
                if sum(m.size for m in members) > shutil.disk_usage(stage).free - 128 * 1024 * 1024:
                    raise ValueError('Insufficient disk space to inspect the package')
                extract_validated(tar, stage, members)
            manifest = self.validate_manifest(read_json(stage / 'manifest.json'))
            checksums = manifest.get('checksums', {})
            actual = {str(p.relative_to(stage)) for p in stage.rglob('*') if p.is_file()} - {'manifest.json'}
            main_config = f'nginx/etc/nginx/conf.d/{manifest["folder"]}.conf'
            if actual != set(checksums) or 'files.tar.gz' not in checksums or main_config not in checksums:
                raise ValueError('Package payload does not match its manifest')
            server_names = re.findall(r'\bserver_name\s+([^;]+);', (stage / main_config).read_text())
            if not any(manifest['settings']['DOMAIN'] in shlex.split(names) for names in server_names):
                raise ValueError('Nginx config does not serve the selected domain')
            for name, checksum in checksums.items():
                if name not in ('files.tar.gz', 'database.sql.gz', 'php-pool.conf', 'auth-meta') and not name.startswith('nginx/etc/nginx/'):
                    raise ValueError('Unsupported package payload path')
                if digest(stage / name) != checksum:
                    raise ValueError('Package payload checksum mismatch')
            has_db = manifest['settings']['DB_CONNECTION'] != 'none'
            if has_db != ('database.sql.gz' in checksums):
                raise ValueError('Database payload is missing or unexpected')
            if manifest['settings']['APP_TYPE'] != 'nodejs' and 'php-pool.conf' not in checksums:
                raise ValueError('PHP-FPM pool is missing')
            archives.validate(stage / 'files.tar.gz')
            with tarfile.open(stage / 'files.tar.gz') as tar:
                if sum(m.size for m in tar.getmembers()) != manifest['files_bytes']:
                    raise ValueError('Website size does not match manifest')
            if has_db:
                total = 0
                with gzip.open(stage / 'database.sql.gz', 'rb') as stream:
                    for block in iter(lambda: stream.read(1024 * 1024), b''):
                        total += len(block)
                        if total > manifest['db_bytes']:
                            raise ValueError('Database payload exceeds its declared size')
                if not total or total != manifest['db_bytes']:
                    raise ValueError('Database payload is empty or does not match its declared size')
            yield stage, manifest

    def sql(self, engine, statement):
        if engine in ('mysql', 'mariadb'):
            return run(['mysql', '-N', '-B'], data=statement.encode()).decode().strip()
        return run(['runuser', '-u', 'postgres', '--', 'psql', '-X', '-v', 'ON_ERROR_STOP=1', '-At'], data=statement.encode()).decode().strip()

    def preflight(self, manifest, stage=None):
        self.validate_manifest(manifest)
        values, folder = manifest['settings'], manifest['folder']
        errors, pending = [], []
        for parent in (self.domains, *self.domains.parents):
            if parent.exists():
                current = parent.stat()
                if parent.is_symlink() or current.st_uid != os.geteuid() or current.st_mode & 0o022:
                    errors.append('Destination domain registry has an untrusted parent')
            if parent == self.root:
                break
        if manifest['source']['id'] == self.identity()['id']:
            errors.append('Source and destination are the same VPS')
        user = values['SYSTEM_USER']
        paths = [self.domains / folder, self.path(f'/etc/nginx/conf.d/{folder}.conf'),
                 self.path(f'/etc/nginx/conf.d/cache-zone-{folder}.conf'),
                 self.path(f'/etc/nginx/ssl/migration-{folder}'), self.path(f'/etc/systemd/system/pm2-{user}.service'),
                 self.path(f'/var/log/nginx/domains/{folder}'), self.path(f'/var/cache/nginx/{folder}')]
        if values['APP_TYPE'] != 'nodejs':
            short = values['PHP_VERSION'].replace('.', '')
            paths.append(self.path(f'/etc/opt/remi/php{short}/php-fpm.d/{folder}.conf'))
            if not self.path(f'/opt/remi/php{short}/root/usr/sbin/php-fpm').is_file():
                errors.append(f'PHP {values["PHP_VERSION"]} is missing; install it through PHP Manager first')
            else:
                try:
                    missing = sorted(set(manifest.get('php_modules', [])) - set(self.php_modules(values)))
                    if missing:
                        errors.append('Missing destination PHP extensions: ' + ', '.join(missing))
                except (OSError, ValueError):
                    errors.append('Destination PHP CLI/modules could not be inspected')
        else:
            if not shutil.which('node') or not shutil.which('npm') or not shutil.which('pm2'):
                errors.append('Node.js, npm and PM2 must be installed through Node.js Manager first')
            elif run(['node', '--version']).decode().split('.')[0] != manifest.get('node_version', '').split('.')[0]:
                errors.append('Source and destination Node.js major versions differ')
            port = values['NODE_APP_PORT']
            if re.search(rf':{port}\s', run(['ss', '-ltn']).decode()):
                errors.append(f'Node.js port {port} is already listening')
            for env in self.domains.glob('*/config/domain.env'):
                settings = security.read_settings(env)
                if port in (settings.get('NODE_APP_PORT'), settings.get('NODE_PORT')):
                    errors.append(f'Node.js port {port} is reserved by another domain')
        for path in paths:
            if exists(path):
                errors.append(f'Destination resource already exists: {path}')
        try:
            pwd.getpwnam(user)
            errors.append(f'Destination account already exists: {user}')
        except KeyError:
            pass
        try:
            grp.getgrnam(user)
            errors.append(f'Destination group already exists: {user}')
        except KeyError:
            pass
        for path in self.domains.glob('*/config/domain.env'):
            if security.read_settings(path).get('DOMAIN') == values['DOMAIN']:
                errors.append('Domain hostname is already registered on this VPS')
        engine = values['DB_CONNECTION']
        if engine != 'none':
            if engine not in ('mysql', 'mariadb'):
                metadata = self.path(f'/var/shieldpress/data/laravel-databases/{values["DB_NAME"]}.env')
                if exists(metadata):
                    errors.append('Destination PostgreSQL management metadata already exists')
            try:
                if engine in ('mysql', 'mariadb'):
                    query = f"SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='{values['DB_NAME']}'; SELECT User FROM mysql.user WHERE User='{values['DB_USER']}';"
                else:
                    query = f"SELECT datname FROM pg_database WHERE datname='{values['DB_NAME']}'; SELECT rolname FROM pg_roles WHERE rolname='{values['DB_USER']}';"
                if self.sql(engine, query):
                    errors.append('Destination database or database account already exists')
            except (ValueError, OSError):
                errors.append('Destination database service/admin login is unavailable')
        for command in ('nginx', 'curl', 'systemctl', 'useradd', 'runuser'):
            if not shutil.which(command):
                errors.append(f'Required command is missing: {command}')
        try:
            run(['nginx', '-t'])
            run(['systemctl', 'is-active', '--quiet', 'nginx'])
        except (OSError, ValueError):
            errors.append('Existing destination Nginx configuration/service is unhealthy')
        free = shutil.disk_usage(self.domains if self.domains.exists() else self.domains.parent).free
        if free < (manifest['files_bytes'] + manifest['db_bytes']) * 2 + 512 * 1024 * 1024:
            errors.append('Insufficient destination disk space (two website/database copies plus 512 MB required)')
        if stage:
            config_text = (stage / f'nginx/etc/nginx/conf.d/{folder}.conf').read_text()
            ipv6 = list(IPV6_LISTEN.finditer(config_text))
            if ipv6:
                try:
                    active = run(['nginx', '-T']).decode(errors='replace')
                    dual_stack = {match[2] for match in IPV6_LISTEN.finditer(active) if 'ipv6only=off' in match[3].split()}
                    if any('ipv6only=off' in match[3].split() or match[2] in dual_stack for match in ipv6):
                        errors.append('Non-default IPv6 dual-stack listen policy requires review before copying')
                except (OSError, ValueError):
                    errors.append('Cannot inspect destination IPv6 listen policy')
            if 'auth-meta' in manifest['checksums'] and exists(self.path(f'/var/shieldpress/data/auth/{folder}.auth')):
                errors.append('Destination HTTP authentication management metadata already exists')
            if has_http_auth(config_text):
                pending.append('HTTP authentication is preserved; check protected pages with the existing credentials before DNS cutover')
            for listen in re.findall(r'\blisten\s+([^;\s]+)', config_text):
                if ':' in listen and not listen.startswith(('[::]:', '*:', '127.0.0.1:')):
                    errors.append('Source Nginx binds an explicit IP address; make its listen directives portable first')
            for dependency in (stage / 'nginx').rglob('*'):
                if not dependency.is_file() or not dependency.name.endswith('.conf'):
                    continue
                text = re.sub(r'(?m)^\s*#.*$', '', dependency.read_text())
                for raw in re.findall(r'(?:^|[;{}])\s*(?:root|alias)\s+([^;]+);', text):
                    names = shlex.split(raw)
                    if len(names) != 1 or '$' in names[0] or not PurePosixPath(names[0]).is_relative_to(PurePosixPath(f'/home/domains/{folder}')) or '..' in PurePosixPath(names[0]).parts:
                        errors.append('Nginx document/alias paths outside the selected website require review')
                if values['APP_TYPE'] == 'nodejs':
                    allowed = {f'127.0.0.1:{values["NODE_APP_PORT"]}', f'localhost:{values["NODE_APP_PORT"]}', f'[::1]:{values["NODE_APP_PORT"]}'}
                    upstreams = re.findall(r'\bproxy_pass\s+https?://([^/;\s]+)', text)
                    if any(upstream not in allowed for upstream in upstreams):
                        errors.append('Node.js proxy upstream is not the selected local application; review it before copying')
                else:
                    expected = f'unix:/var/opt/remi/php{values["PHP_VERSION"].replace(".", "")}/run/php-fpm/{folder}.sock'
                    if any(upstream.strip() != expected for upstream in re.findall(r'\bfastcgi_pass\s+([^;]+);', text)):
                        errors.append('PHP upstream does not use this website\'s isolated local PHP-FPM pool')
            for source in (stage / 'nginx').rglob('*'):
                if not source.is_file():
                    continue
                name = '/' + str(source.relative_to(stage / 'nginx'))
                target = self.path(name)
                # Shared include files may be reused only if byte-for-byte identical.
                if exists(target) and (target.is_symlink() or not target.is_file() or digest(source) != digest(target)):
                    errors.append(f'Nginx dependency conflict: {name}')
                for parent in target.parents:
                    if parent.is_symlink():
                        errors.append(f'Nginx dependency parent is a symlink: {name}')
                        break
        if manifest.get('tls'):
            pending.append('Copied TLS certificates need renewal setup after DNS cutover (SSL Manager)')
        if manifest.get('supplemental'):
            pending.append('Cron/queue/custom services are staged for review and remain disabled to avoid duplicate jobs')
        if values.get('SFTP') == 'enabled':
            pending.append('Configure fresh SFTP access on the destination; source login credentials are not duplicated')
        if values['APP_TYPE'] == 'laravel' and not shutil.which('composer'):
            errors.append('Composer is missing; install it before copying Laravel')
        return {'domain': values['DOMAIN'], 'errors': sorted(set(errors)), 'pending': pending,
                'destination': self.identity(), 'ready': not errors, 'free_bytes': free}

    def account_command(self, values, args, *, capture=True, timeout=1800, extra=None):
        home = f'/home/domains/{values["CLEAN_DOMAIN"]}'
        env = {'HOME': home, 'PM2_HOME': home + '/.pm2', 'NODE_ENV': 'production',
               'PATH': '/usr/local/bin:/usr/bin:/bin', 'PORT': values.get('NODE_APP_PORT', '')}
        env.update(extra or {})
        return run(['runuser', '-u', values['SYSTEM_USER'], '--', 'env',
                    *[f'{key}={value}' for key, value in env.items()], *args], capture=capture, timeout=timeout)

    def create_database(self, values):
        engine = values['DB_CONNECTION']
        if engine == 'none':
            return
        name, user, password = (values[key] for key in ('DB_NAME', 'DB_USER', 'DB_PASS'))
        literal = "'" + password.replace("'", "''") + "'"
        if engine in ('mysql', 'mariadb'):
            self.sql(engine, f"SET SESSION sql_mode='NO_BACKSLASH_ESCAPES'; CREATE DATABASE `{name}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; CREATE USER '{user}'@'localhost' IDENTIFIED BY {literal}; GRANT ALL PRIVILEGES ON `{name}`.* TO '{user}'@'localhost';")
        else:
            self.sql(engine, f'CREATE ROLE "{user}" LOGIN PASSWORD {literal};')
            run(['runuser', '-u', 'postgres', '--', 'createdb', '-O', user, name])

    def import_database(self, values, stage):
        if values['DB_CONNECTION'] == 'none':
            return
        env = dict(os.environ)
        with tempfile.TemporaryDirectory(dir=self.state) as tmp:
            if values['DB_CONNECTION'] in ('mysql', 'mariadb'):
                config = Path(tmp) / 'client.cnf'
                password = values['DB_PASS'].replace('\\', '\\\\').replace('"', '\\"')
                config.write_text(f'[client]\nuser={values["DB_USER"]}\npassword="{password}"\nhost=localhost\n')
                os.chmod(config, 0o600)
                args = ['mysql', f'--defaults-extra-file={config}', '--local-infile=0', values['DB_NAME']]
            else:
                env['PGPASSWORD'] = values['DB_PASS']
                args = ['psql', '-X', '-v', 'ON_ERROR_STOP=1', '--single-transaction', '-h', '127.0.0.1',
                        '-U', values['DB_USER'], '-d', values['DB_NAME']]
            with gzip.open(stage / 'database.sql.gz', 'rb') as source, tempfile.TemporaryFile() as errors:
                process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=errors, stderr=errors, env=env)
                try:
                    shutil.copyfileobj(source, process.stdin, 1024 * 1024)
                    process.stdin.close()
                except BaseException:
                    process.kill()
                    process.wait()
                    raise
                if process.wait():
                    raise ValueError('Database import failed; destination copy retained for recovery')

    def database_login(self, values):
        if values['DB_CONNECTION'] == 'none':
            return
        if values['DB_CONNECTION'] in ('mysql', 'mariadb'):
            with tempfile.TemporaryDirectory(dir=self.state) as tmp:
                config = Path(tmp) / 'client.cnf'
                password = values['DB_PASS'].replace('\\', '\\\\').replace('"', '\\"')
                config.write_text(f'[client]\nuser={values["DB_USER"]}\npassword="{password}"\nhost=localhost\n')
                os.chmod(config, 0o600)
                run(['mysql', f'--defaults-extra-file={config}', '-N', '-e', 'SELECT 1', values['DB_NAME']])
        else:
            run(['psql', '-X', '-v', 'ON_ERROR_STOP=1', '-h', '127.0.0.1', '-U', values['DB_USER'],
                 '-d', values['DB_NAME'], '-Atc', 'SELECT 1'], env={**os.environ, 'PGPASSWORD': values['DB_PASS']})

    def register_database(self, values):
        if values['DB_CONNECTION'] in ('none', 'mysql', 'mariadb'):
            # MySQL Manager discovers managed domain databases from domain.env.
            return
        path = self.path(f'/var/shieldpress/data/laravel-databases/{values["DB_NAME"]}.env')
        if path.parent.is_symlink():
            raise ValueError('PostgreSQL management directory must not be a symlink')
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        current = path.parent.stat()
        if current.st_uid != os.geteuid() or current.st_mode & 0o022:
            raise ValueError('PostgreSQL management directory is untrusted')
        metadata = {'DB_CONNECTION': 'pgsql', 'DB_HOST': '127.0.0.1', 'DB_PORT': '5432',
                    'DB_DATABASE': values['DB_NAME'], 'DB_USERNAME': values['DB_USER'],
                    'DB_PASSWORD': values['DB_PASS'], 'DOMAIN': values['DOMAIN'], 'CREATED': 'server-migration'}
        with open(path, 'x') as stream:
            stream.write(''.join(f'{key}={value}\n' for key, value in metadata.items()))
        os.chmod(path, 0o600)

    def write_settings(self, values):
        config = self.domains / values['CLEAN_DOMAIN'] / 'config/domain.env'
        config.write_text(''.join(f'{key}={value}\n' for key, value in values.items() if key in security.KEYS))
        os.chmod(config, 0o600)
        security.domain_control(self.domains, values['CLEAN_DOMAIN'], repair=True)

    def reconnect_app(self, values):
        app = self.domains / values['CLEAN_DOMAIN'] / 'public_html'
        if values['DB_CONNECTION'] == 'none':
            return
        if values['APP_TYPE'] == 'wordpress':
            repair = module('migration_wp_repair', BASE / 'modules/backup/restore-wordpress-db.py')
            repair.repair(app.parent)
        # Keep the original DB identity/password, reconnect conventional app settings locally.
        # Dynamic/custom connection schemes need an explicit review instead of guessing.
        replacements = {'DB_HOST': '127.0.0.1', 'DB_PORT': '3306' if values['DB_CONNECTION'] in ('mysql', 'mariadb') else '5432',
                        'DB_DATABASE': values['DB_NAME'], 'DB_USERNAME': values['DB_USER'],
                        'DB_PASSWORD': '"' + values['DB_PASS'].replace('\\', '\\\\').replace('"', '\\"').replace('$', '\\$') + '"'}
        for name in ('.env', '.env.production', '.env.local', '.env.production.local'):
            path = app / name
            if path.is_file():
                if path.is_symlink():
                    raise ValueError('Application environment must be a regular file')
                text = path.read_text()
                for key, value in replacements.items():
                    text = re.sub(rf'(?m)^{key}=.*$', lambda _: f'{key}={value}', text)
                # URLs keep credentials and query parameters but use the managed local database.
                from urllib.parse import urlsplit, urlunsplit, quote
                def local_url(match):
                    raw = match.group(2).strip().strip('"\'')
                    parsed = urlsplit(raw)
                    if parsed.scheme not in ('mysql', 'mysql2', 'postgres', 'postgresql'):
                        raise ValueError('Unsupported application database URL')
                    auth = quote(values['DB_USER'], safe='') + ':' + quote(values['DB_PASS'], safe='')
                    netloc = auth + '@127.0.0.1:' + replacements['DB_PORT']
                    return match.group(1) + '=' + urlunsplit((parsed.scheme, netloc, '/' + values['DB_NAME'], parsed.query, parsed.fragment))
                text = re.sub(r'(?m)^(DATABASE_URL|DIRECT_URL)=(.*)$', local_url, text)
                path.write_text(text)
                os.chmod(path, 0o600)
                account = pwd.getpwnam(values['SYSTEM_USER'])
                os.chown(path, account.pw_uid, account.pw_gid)

    def php_pool(self, values, stage):
        folder, user = values['CLEAN_DOMAIN'], values['SYSTEM_USER']
        short = values['PHP_VERSION'].replace('.', '')
        target = self.path(f'/etc/opt/remi/php{short}/php-fpm.d/{folder}.conf')
        home = f'/home/domains/{folder}'
        text = (stage / 'php-pool.conf').read_text()
        for directive, expected in (('user', user), ('group', user),
                                     ('listen', f'/var/opt/remi/php{short}/run/php-fpm/{folder}.sock')):
            matches = re.findall(rf'(?m)^\s*{directive}\s*=\s*([^;\n]+)', text)
            if len(matches) != 1 or matches[0].strip() != expected:
                raise ValueError('Source PHP-FPM identity/socket is not portable; review the source pool')
        for name in re.findall(r'(?m)^\s*(?:slowlog|php_admin_value\[error_log\])\s*=\s*([^;\n]+)', text):
            name = name.strip()
            allowed = (f'{home}/logs/', '/var/shieldpress/logs/php-slow/', '/opt/shieldpress/logs/php-slow/')
            if not name.startswith(allowed) or '..' in PurePosixPath(name).parts:
                raise ValueError('Unsupported PHP-FPM log path')
            self.path(name).parent.mkdir(parents=True, exist_ok=True)
        exclusive_file(target, text.encode())
        try:
            run([self.path(f'/opt/remi/php{short}/root/usr/sbin/php-fpm'), '-t'])
            run(['systemctl', 'reload-or-restart', f'php{short}-php-fpm'])
            run(['systemctl', 'is-active', '--quiet', f'php{short}-php-fpm'])
        except BaseException:
            target.unlink()
            subprocess.run(['systemctl', 'reload-or-restart', f'php{short}-php-fpm'], capture_output=True)
            raise
        return target

    def build_app(self, values):
        folder = values['CLEAN_DOMAIN']
        app = self.domains / folder / 'public_html'
        with working_directory(app):
            if values['APP_TYPE'] == 'laravel':
                php = f'/opt/remi/php{values["PHP_VERSION"].replace(".", "")}/root/usr/bin/php'
                composer = shutil.which('composer')
                if not composer:
                    raise ValueError('Composer is missing on the destination')
                self.account_command(values, [php, composer, 'install', '--no-dev', '--prefer-dist', '--optimize-autoloader', '--no-interaction'])
                # The database was copied; never run application schema migrations here.
                for command in ('config:clear', 'route:clear', 'view:clear', 'config:cache', 'view:cache'):
                    self.account_command(values, [php, 'artisan', command])
            if values['APP_TYPE'] in ('laravel', 'nodejs') and (app / 'package.json').is_file():
                package = read_json(app / 'package.json')
                manager = package.get('packageManager', '').split('@')[0]
                if not manager:
                    manager = 'pnpm' if (app / 'pnpm-lock.yaml').exists() else 'yarn' if (app / 'yarn.lock').exists() else 'npm'
                if manager not in ('npm', 'pnpm', 'yarn') or not shutil.which(manager):
                    raise ValueError(f'Required package manager is unavailable: {manager}')
                install = [manager, 'ci' if (app / 'package-lock.json').exists() else 'install', '--include=dev'] if manager == 'npm' else [manager, 'install', '--frozen-lockfile']
                self.account_command(values, install, extra={'NODE_ENV': 'development'})
                if 'build' in package.get('scripts', {}):
                    self.account_command(values, [manager, 'run', 'build'])
            if values['APP_TYPE'] == 'nodejs':
                if (app / 'prisma/schema.prisma').is_file():
                    self.account_command(values, ['npx', '--no-install', 'prisma', 'generate'])
                name = values.get('PM2_NAME') or folder
                if not re.fullmatch(r'[A-Za-z0-9_.-]{1,64}', name):
                    raise ValueError('Unsupported PM2 application name')
                ecosystem = next((p for p in ('ecosystem.config.cjs', 'ecosystem.config.js') if (app / p).is_file()), None)
                if ecosystem:
                    command = ['pm2', 'start', ecosystem, '--only', name]
                elif (app / 'package.json').exists() and 'start' in read_json(app / 'package.json').get('scripts', {}):
                    command = ['pm2', 'start', 'npm', '--name', name, '--', 'start']
                else:
                    if not (app / values['NODE_ENTRY']).is_file():
                        raise ValueError('Node.js entry is missing and package.json has no start script')
                    command = ['pm2', 'start', values['NODE_ENTRY'], '--name', name]
                self.account_command(values, command)
                self.account_command(values, ['pm2', 'save'])
                self.account_command(values, ['pm2', 'kill'])
                service = self.path(f'/etc/systemd/system/pm2-{values["SYSTEM_USER"]}.service')
                pm2 = shutil.which('pm2')
                service.write_text(f'''[Unit]
Description=ShieldPress migrated application {values['DOMAIN']}
After=network.target
[Service]
Type=simple
User={values['SYSTEM_USER']}
WorkingDirectory=/home/domains/{folder}/public_html
Environment=HOME=/home/domains/{folder}
Environment=PM2_HOME=/home/domains/{folder}/.pm2
Environment=PATH=/usr/local/bin:/usr/bin:/bin
ExecStart={pm2} resurrect --no-daemon
Restart=on-failure
[Install]
WantedBy=multi-user.target
''')
                run(['systemctl', 'daemon-reload'])
                run(['systemctl', 'enable', '--now', service.name])
                run(['systemctl', 'is-active', '--quiet', service.name])

    def selinux(self, folder):
        if shutil.which('semanage'):
            home = f'/home/domains/{folder}'
            for suffix, label in (('(/.*)?', 'httpd_sys_content_t'), ('/logs(/.*)?', 'httpd_log_t'),
                                  ('/tmp(/.*)?', 'httpd_sys_rw_content_t'), ('/sessions(/.*)?', 'httpd_sys_rw_content_t'),
                                  ('/public_html/wp-content(/.*)?', 'httpd_sys_rw_content_t'),
                                  ('/public_html/storage(/.*)?', 'httpd_sys_rw_content_t'),
                                  ('/public_html/bootstrap/cache(/.*)?', 'httpd_sys_rw_content_t')):
                result = subprocess.run(['semanage', 'fcontext', '-a', '-t', label, home + suffix], capture_output=True)
                if result.returncode:
                    run(['semanage', 'fcontext', '-m', '-t', label, home + suffix])
            run(['restorecon', '-R', home], timeout=600)

    def verify(self, folder, tls=False):
        values = self.settings(folder)
        receipt_path = self.domains / folder / 'config/migration.json'
        receipt = read_json(receipt_path) if receipt_path.is_file() else {}
        tls = tls or receipt.get('tls', False)
        checks = []
        def check(name, action):
            try:
                detail = action()
                checks.append({'check': name, 'ok': True, 'detail': detail if isinstance(detail, str) else ''})
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                checks.append({'check': name, 'ok': False, 'detail': str(error)})
        check('nginx configuration', lambda: run(['nginx', '-t']) and '')
        check('nginx service', lambda: run(['systemctl', 'is-active', '--quiet', 'nginx']) and '')
        check('managed database login', lambda: self.database_login(values))
        def paths():
            root = Path(values.get('ROOT') or f'/home/domains/{folder}/public_html')
            if not root.is_dir():
                raise ValueError('Configured document root is missing')
            if values['APP_TYPE'] != 'nodejs':
                self.account_command(values, ['test', '-w', f'/home/domains/{folder}/tmp/sessions'])
            return 'domain control paths and application document root verified'
        check('domain paths and runtime permissions', paths)
        if values['APP_TYPE'] == 'nodejs':
            check('application service', lambda: run(['systemctl', 'is-active', '--quiet', f'pm2-{values["SYSTEM_USER"]}.service']) and '')
        else:
            check('PHP-FPM service', lambda: run(['systemctl', 'is-active', '--quiet', f'php{values["PHP_VERSION"].replace(".", "")}-php-fpm']) and '')
        def request(scheme, path='/', identity=False, host=None):
            host = host or values['DOMAIN']
            port = '443' if scheme == 'https' else '80'
            # No redirect following: a redirect must never send a destination probe back to the source.
            command = ['curl', '--noproxy', '*', '--silent', '--show-error', '--connect-timeout', '5', '--max-time', '20',
                          '--resolve', f'{host}:{port}:127.0.0.1',
                          f'{scheme}://{host}{path}']
            if not identity:
                command[1:1] = ['-o', '/dev/null', '-w', '%{http_code}']
            if scheme == 'https' and values.get('SSL_TYPE') == 'cloudflare':
                text = self.path(f'/etc/nginx/conf.d/{folder}.conf').read_text()
                ca = re.search(r'\bssl_client_certificate\s+([^;]+);', text)
                if ca:
                    command[1:1] = ['--cacert', ca.group(1).strip().strip('\"\'')]
            result = run(command).decode().strip()
            if identity:
                if not receipt.get('id') or result != receipt['id']:
                    raise ValueError('Destination vhost identity does not match; check the saved local probe and Nginx reload')
                return 'unique local-only website probe verified'
            if result == '401':
                text = self.path(f'/etc/nginx/conf.d/{folder}.conf').read_text()
                if has_http_auth(text):
                    return '401 (authentication challenge; verify protected pages with credentials before cutover)'
            if not result.isdigit() or not 200 <= int(result) < 400:
                raise ValueError(f'{scheme.upper()} returned {result}; check destination application logs')
            return result
        def identity():
            for host in receipt.get('hosts', [values['DOMAIN']]):
                try:
                    return request('https' if tls else 'http', '/.well-known/shieldpress-migration-' + receipt.get('id', 'missing'), identity=True, host=host)
                except (OSError, ValueError, subprocess.SubprocessError):
                    continue
            raise ValueError('Destination vhost identity is not ready; inspect its local probe and Nginx reload')
        check('destination virtual host identity', identity)
        check('destination HTTP', lambda: request('http'))
        if tls:
            check('destination HTTPS and certificate', lambda: request('https'))
        return {'domain': values['DOMAIN'], 'ready': all(row['ok'] for row in checks), 'checks': checks}

    def import_package(self, package, checksum, destination_id):
        if self.identity()['id'] != destination_id:
            raise ValueError('Destination identity changed; inspect the plan again')
        with self.lock(), self.unpack(package, checksum) as (stage, manifest):
            plan = self.preflight(manifest, stage)
            if plan['errors']:
                raise ValueError('; '.join(plan['errors']))
            folder, values = manifest['folder'], dict(manifest['settings'])
            values['CLEAN_DOMAIN'] = folder
            values['SFTP'] = 'disabled'
            home = f'/home/domains/{folder}'
            values['ROOT'] = values.get('ROOT') or home + '/public_html' + ('/public' if values['APP_TYPE'] == 'laravel' else '')
            target = self.domains / folder
            report_path = self.reports / f'{manifest["id"]}.json'
            report = {'id': manifest['id'], 'source': manifest['source'], 'destination': self.identity(),
                      'created': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                      'domain': values['DOMAIN'], 'folder': folder, 'status': 'COPYING', 'completed': [],
                      'pending': plan['pending'], 'supplemental': manifest.get('supplemental', []),
                      'package': str(package), 'sha256': checksum, 'tls': manifest.get('tls', False)}
            write_json(report_path, report)
            new_nginx = []
            pool = None
            def completed(step):
                report['completed'].append(step)
                write_json(report_path, report)
                print(f'[OK] {values["DOMAIN"]}: {step}', file=sys.stderr, flush=True)
            try:
                # mkdir without exist_ok reserves the domain before creating anything else.
                target.mkdir(mode=0o755)
                os.chmod(target, 0o755)
                run(['useradd', '--no-create-home', '--home-dir', home, '--shell', '/sbin/nologin', values['SYSTEM_USER']])
                for name in ('public_html', 'config', 'backup/db', 'backup/files', 'backup/full', 'logs', 'tmp/sessions', 'sessions', '.pm2', '.npm', '.cache', '.config', '.local', '.composer'):
                    (target / name).mkdir(parents=True, exist_ok=True)
                os.chmod(target / 'public_html', 0o755)
                run(['chown', '-hR', f'{values["SYSTEM_USER"]}:{values["SYSTEM_USER"]}',
                     *[target / name for name in ('.npm', '.cache', '.config', '.local', '.composer')]])
                self.write_settings(values)
                completed('domain and isolated account created')
                self.create_database(values)
                self.import_database(values, stage)
                self.database_login(values)
                self.register_database(values)
                completed('database imported and login verified')
                with tarfile.open(stage / 'files.tar.gz') as tar:
                    for member in tar.getmembers():
                        member.mode &= 0o777
                    extract_validated(tar, target / 'public_html')
                    # Python 3.14's default data filter leaves directory modes unset.
                    # Restore validated, non-privileged modes despite the private process umask.
                    for member in reversed(tar.getmembers()):
                        if member.isdir() or member.isfile():
                            os.chmod(target / 'public_html' / member.name, member.mode & 0o777)
                run(['chown', '-hR', f'{values["SYSTEM_USER"]}:{values["SYSTEM_USER"]}', target / 'public_html', target / 'tmp', target / 'sessions', target / '.pm2'])
                run(['chown', 'nginx:nginx', target / 'logs'])
                old_log = self.path(f'/var/log/nginx/domains/{folder}')
                old_log.parent.mkdir(parents=True, exist_ok=True)
                old_log.symlink_to(home + '/logs', target_is_directory=True)
                os.chmod(target / 'tmp/sessions', 0o700)
                os.chmod(target / 'sessions', 0o700)
                self.reconnect_app(values)
                self.selinux(folder)
                completed('complete website files copied and credentials connected')
                if values['APP_TYPE'] != 'nodejs':
                    pool = self.php_pool(values, stage)
                self.build_app(values)
                completed('application runtime prepared')
                main_config = stage / f'nginx/etc/nginx/conf.d/{folder}.conf'
                server_names = re.findall(r'\bserver_name\s+([^;]+);', main_config.read_text())
                hosts = [values['DOMAIN']]
                www = 'www.' + values['DOMAIN']
                if any(www in shlex.split(names) for names in server_names):
                    hosts.append(www)
                main_config.write_text(nginx_probe(portable_ipv6_listeners(main_config.read_text()), manifest['id']))
                write_json(target / 'config/migration.json', {'id': manifest['id'], 'tls': manifest.get('tls', False), 'hosts': hosts})
                # Install files exclusively; preflight never authorizes replacement of existing files.
                for source in sorted((stage / 'nginx').rglob('*')):
                    if not source.is_file():
                        continue
                    name = '/' + str(source.relative_to(stage / 'nginx'))
                    dest = self.path(name)
                    if exists(dest):
                        if not dest.is_file() or dest.is_symlink() or digest(dest) != digest(source):
                            raise ValueError(f'Dependency changed after preflight: {name}')
                        continue
                    new_parent = not dest.parent.exists()
                    dest.parent.mkdir(mode=0o700 if '/ssl/' in name else 0o755, parents=True, exist_ok=True)
                    if new_parent and '/auth/' in name:
                        os.chmod(dest.parent, 0o755)
                    mode = 0o600 if '/ssl/' in name else 0o640 if '/auth/' in name else 0o644
                    exclusive_file(dest, source.read_bytes(), mode, 'nginx' if '/auth/' in name else None)
                    new_nginx.append((dest, digest(dest)))
                if (stage / 'auth-meta').is_file():
                    auth = self.path(f'/var/shieldpress/data/auth/{folder}.auth')
                    auth.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                    current = auth.parent.stat()
                    if auth.parent.is_symlink() or current.st_uid != os.geteuid() or current.st_mode & 0o022:
                        raise ValueError('Destination HTTP authentication management directory is untrusted')
                    with open(auth, 'xb') as stream:
                        stream.write((stage / 'auth-meta').read_bytes())
                    os.chmod(auth, 0o600)
                for source in (stage / 'nginx').rglob('*.conf'):
                    for auth in re.findall(r'\bauth_basic_user_file\s+([^;]+);', source.read_text()):
                        run(['runuser', '-u', 'nginx', '--', 'test', '-r', auth.strip().strip('\"\'')])
                cache = self.path(f'/var/cache/nginx/{folder}')
                cache.mkdir(parents=True, exist_ok=True)
                run(['chown', 'nginx:nginx', cache])
                run(['nginx', '-t'])
                run(['systemctl', 'reload', 'nginx'])
                completed('Nginx configuration and TLS installed')
                deadline = time.monotonic() + 90
                checks = self.verify(folder, manifest.get('tls', False))
                # Nginx reloads asynchronously; an old default vhost must never count as ready.
                if not checks['ready']:
                    print(f'[CHECK] {values["DOMAIN"]}: waiting for the destination vhost/application (up to 90 seconds)...', file=sys.stderr, flush=True)
                while not checks['ready'] and time.monotonic() < deadline:
                    time.sleep(2)
                    checks = self.verify(folder, manifest.get('tls', False))
                report['verification'] = checks
                if not checks['ready']:
                    raise ValueError('Destination checks failed; DNS must remain on the source VPS')
                report['status'] = 'COPIED_PENDING_CUTOVER'
                completed('destination service, database and HTTP/HTTPS checks passed')
            except BaseException as error:
                # Remove only config files this attempt created and that nobody has since changed.
                # Website/database copies are retained. Never delete source or pre-existing data.
                for path, checksum_before in reversed(new_nginx):
                    if path.is_file() and not path.is_symlink() and digest(path) == checksum_before:
                        path.unlink()
                if pool and pool.is_file():
                    pool.unlink()
                    subprocess.run(['systemctl', 'reload-or-restart', f'php{values["PHP_VERSION"].replace(".", "")}-php-fpm'], capture_output=True)
                subprocess.run(['nginx', '-t'], capture_output=True)
                subprocess.run(['systemctl', 'reload', 'nginx'], capture_output=True)
                report['status'] = 'FAILED_RETAINED'
                report['error'] = str(error)
                report['recovery'] = 'Destination copy retained. Review this report and repair it before using Domain Manager to remove any failed copy. Existing sites and the source remain intact.'
                write_json(report_path, report)
                raise ValueError(f'Migration failed: {error}\nPrivate recovery report: {report_path}') from error
            write_json(report_path, report)
            return {'report': str(report_path), 'status': report['status'], 'verification': report['verification'], 'pending': report['pending']}


ssh_support = module('migration_ssh', BASE / 'modules/tools/migration-ssh.py')
Remote = ssh_support.Remote


def choose_sites(inventory):
    sites = inventory['sites']
    ssh_support.show_menu('Step 3: Select Websites', 'Original websites on A', [], clear=False)
    for index, site in enumerate(sites, 1):
        print(f'  [{index:2}] {site.get("domain", site["folder"])} [{site.get("app", "BLOCKED")}]' +
              (f' — {site["error"]}' if 'error' in site else ''))
    if not sites:
        raise ValueError('No registered websites were found')
    raw = input('Select website numbers (example: 1,3,4), or ALL; Enter cancels: ').strip()
    if not raw:
        return []
    if raw.upper() == 'ALL':
        selected = list(sites)
    else:
        parts = re.split(r'[ ,]+', raw)
        if not all(re.fullmatch('[1-9][0-9]*', item) and int(item) <= len(sites) for item in parts):
            raise ValueError('Invalid selection; no website was copied')
        selected = [sites[index - 1] for index in dict.fromkeys(map(int, parts))]
    if any('error' in site for site in selected):
        raise ValueError('Selection includes a blocked website; repair its configuration before migrating')
    return selected


def show_route(route):
    local = route['client']
    details = [f'CLIENT / this VPS: {local["hostname"]} [{route["client_role"]}], ID {local["id"][:12]}']
    for key, label in (('source', 'A / SOURCE (original websites)'), ('destination', 'B / DESTINATION (new copies)')):
        server = route[key]
        endpoint = route[key + '_label']
        host = f'{endpoint} / {server["hostname"]}' if endpoint != server['hostname'] else endpoint
        details.append(f'{label}: {host}, ID {server["id"][:12]}')
    details.extend(['WEBSITE DATA: A -> B', f'SSH: Client -> {route["ssh_server"]} [{route["ssh_role"]}]'])
    ssh_support.show_menu('Step 2: Copy Direction', 'Check both VPS identities', [], details, clear=False)


def show_migration_menu(identity):
    ssh_support.show_menu('Server Migration', 'Copy websites from A to B', [
        '1|Send to VPS B (this VPS = A)|green',
        '2|Pull from A (this VPS = B)|cyan',
        '3|Export package (on A)|blue',
        '4|Import package (on B)|blue',
        '5|SSH connections / revoke|yellow',
        '6|Reports / verify copies|magenta',
        '0|Back|white',
    ], [f'Client: {identity["hostname"][:43]} | ID: {identity["id"][:12]}',
        'A = original source VPS | B = destination VPS',
        'This VPS controls the copy. Source data is retained.'])


def summary_plan(manifests, destination, source_label, destination_label, route=None):
    print('\nCOPY PLAN')
    if route:
        show_route(route)
    else:
        print(f'  CLIENT / this VPS = DESTINATION B: {destination["hostname"]}')
        print(f'  A / SOURCE (package origin): {source_label}')
        print(f'  B / DESTINATION: {destination_label} ({destination["hostname"]}, server ID {destination["id"][:12]})')
        print(f'  WEBSITE DATA: A -> B | {source_label} -> {destination_label} (offline import)')
    print(f'  Websites    : {len(manifests)}')
    for manifest in manifests:
        values = manifest['settings']
        print(f'    {values["DOMAIN"]} [{values["APP_TYPE"]}]  DB: {values.get("DB_NAME") or "none"}')
    print('Source websites, databases, SSH settings and DNS records will be preserved.')
    print('Existing destination websites, accounts and databases cannot be overwritten.')
    print('This is a point-in-time copy. Pause source writes before the final copy to avoid missing later orders/uploads.')
    print('Keep cron jobs and queue workers disabled on the destination until DNS cutover.')
    print(ssh_support.message('WARNING: creates accounts, databases and web configuration on destination B.', 'yellow'))
    return ssh_support.confirm('Create and verify this destination copy?')


def wizard(engine, direction):
    remote = ssh_support.choose_remote(engine, direction)
    if remote is None:
        return
    try:
        remote_identity = remote.call('identity')
    except (OSError, ValueError):
        previous = remote.saved()
        if previous and previous['expires'] > time.time():
            raise ValueError('Saved connection failed. Verify the endpoint and fingerprint in Server Connections before pairing again.')
        remote_identity = remote.setup()
        if remote_identity is None:
            return
    if remote_identity['protocol'] != PROTOCOL:
        raise ValueError('Update ShieldPress on both VPSs before migrating')
    if remote_identity['id'] == engine.identity()['id']:
        raise ValueError('Source and destination are the same VPS; operation refused')
    local_identity = engine.identity()
    source_label = local_identity['hostname'] if direction == 'push' else remote.host
    destination_label = remote.host if direction == 'push' else local_identity['hostname']
    destination = remote_identity if direction == 'push' else local_identity
    route = {'client': local_identity, 'client_role': 'SOURCE A' if direction == 'push' else 'DESTINATION B',
             'source': local_identity if direction == 'push' else remote_identity, 'destination': destination,
             'source_label': source_label, 'destination_label': destination_label,
             'ssh_server': f'root@{remote.host}, SSH port {remote.port}',
             'ssh_role': 'DESTINATION B' if direction == 'push' else 'SOURCE A'}
    show_route(route)
    print(f'\nSelect original websites on SOURCE A: {source_label}')
    inventory = engine.inventory() if direction == 'push' else remote.call('inventory')
    selection = choose_sites(inventory)
    if not selection:
        return
    print(f'\nSelected {len(selection)} website(s): {source_label} -> {destination_label}')
    for index, site in enumerate(selection, 1):
        print(f'  [{index:2}] {site["domain"]}')
    print(ssh_support.message('WARNING: pause source writes before the final copy. Change DNS only after destination checks pass.', 'yellow'))
    print('Each website is exported, transferred, checked and imported before the next starts.')
    if not ssh_support.confirm('Continue with these websites?'):
        return
    ssh_support.show_menu('Step 4: Copy Websites', 'One website at a time', [],
                          [f'A: {source_label}', f'B: {destination_label}'], clear=False)
    results = []
    batch = engine.reports / f'batch-{uuid.uuid4().hex}.json'
    def save_batch():
        write_json(batch, {'source': source_label, 'destination': destination_label, 'results': results,
                          'not_started': [site['domain'] for site in selection[len(results):]]})
    save_batch()
    for index, site in enumerate(selection, 1):
        manifest = None
        print(ssh_support.message(f'\nWEBSITE {index}/{len(selection)}: {site["domain"]}', 'cyan'), flush=True)
        try:
            print('[1/4] Export application files and database from A', flush=True)
            exported = engine.export(site['folder']) if direction == 'push' else remote.call('export', site['folder'])
            manifest = exported['manifest']
            print('[2/4] Transfer package to B and verify SHA-256', flush=True)
            if direction == 'push':
                incoming = remote.call('incoming', manifest['id'])['path']
                remote.transfer(exported['package'], incoming)
                package = remote.call('receive', manifest['id'], exported['sha256'])['package']
                print('[3/4] Check destination conflicts and available resources', flush=True)
                plan = remote.call('inspect', package, exported['sha256'])
            else:
                package = engine.packages / Path(exported['package']).name
                partial = package.with_name(package.name + '.partial')
                remote.transfer(partial, exported['package'], download=True)
                if digest(partial) != exported['sha256']:
                    raise ValueError('Download checksum mismatch; no import started')
                os.replace(partial, package)
                package.with_name(package.name + '.sha256').write_text(exported['sha256'] + '\n')
                print('[3/4] Check destination conflicts and available resources', flush=True)
                with engine.unpack(package, exported['sha256']) as (stage, unpacked):
                    plan = engine.preflight(unpacked, stage)
            for error in plan['errors']:
                print(ssh_support.message('[BLOCKED] ' + error, 'red'))
            for pending in plan['pending']:
                print(ssh_support.message('[ACTION AFTER COPY] ' + pending, 'yellow'))
            if plan['errors']:
                raise ValueError('Destination preflight failed; this website was not imported. Its package is retained.')
            if not summary_plan([manifest], destination, source_label, destination_label):
                results.append({'domain': site['domain'], 'status': 'SKIPPED'})
                save_batch()
                print(ssh_support.message('[SKIPPED] No destination import was started.', 'yellow'))
                continue
            print('[4/4] Create destination website and verify database, runtime and HTTP/HTTPS', flush=True)
            result = remote.call('import', str(package), exported['sha256'], destination['id']) if direction == 'push' else engine.import_package(package, exported['sha256'], destination['id'])
            results.append({'domain': site['domain'], **result})
            save_batch()
            print(ssh_support.message('[OK] Website copy verified. DNS cutover is still required.', 'green'))
            print('  Private report: ' + result['report'])
        except (OSError, ValueError, subprocess.SubprocessError, tarfile.TarError) as error:
            print(ssh_support.message(f'[FAILED] {site["domain"]}: {error}', 'red'))
            if manifest:
                print('  Destination recovery report: /var/shieldpress/data/server-migration/reports/' + manifest['id'] + '.json')
            results.append({'domain': site['domain'], 'status': 'FAILED', 'error': str(error)})
            save_batch()
            print(ssh_support.message('Failed destination data is retained. Keep DNS on A for this website.', 'yellow'))
            if index < len(selection) and ssh_support.confirm('Continue with the next website?'):
                continue
            break
    print('\nCopy results:')
    for index, result in enumerate(results, 1):
        color = 'green' if result['status'] == 'COPIED_PENDING_CUTOVER' else 'red' if result['status'] == 'FAILED' else 'yellow'
        print(ssh_support.message(f'  [{index:2}] {result["domain"]}: {result["status"]}', color))
    remaining = selection[len(results):]
    if remaining:
        print('Not started: ' + ', '.join(site['domain'] for site in remaining))
    print('Batch report: ' + str(batch))
    if any(result['status'] == 'COPIED_PENDING_CUTOVER' for result in results):
        print(ssh_support.message('For verified copies: review the websites, then change DNS, configure certificate renewal and enable reviewed jobs.', 'yellow'))
    else:
        print(ssh_support.message('No destination copy passed checks. Keep DNS on the source VPS.', 'yellow'))


def menu(engine):
    while True:
        show_migration_menu(engine.identity())
        try:
            choice = input('Select: ').strip()
            if choice == '0' or not choice:
                return
            if choice in ('1', '2'):
                wizard(engine, 'push' if choice == '1' else 'pull')
            elif choice == '3':
                for site in choose_sites(engine.inventory()):
                    print(f'Exporting {site["domain"]}...', flush=True)
                    result = engine.export(site['folder'])
                    print(f'Package: {result["package"]}\nSHA-256: {result["sha256"]}')
                print('Use the guided server copy, or transfer packages and .sha256 files with an administrator SSH/SCP login. Packages contain private credentials and certificates.')
            elif choice == '4':
                packages = sorted(engine.packages.glob('*.spm.tar.gz'))
                for index, package in enumerate(packages, 1):
                    print(f'  {index}) {package.name}')
                print('Place packages and .sha256 files in ' + str(engine.packages))
                raw = input('Select package number; Enter cancels: ').strip()
                if not raw:
                    continue
                if not raw.isdigit() or not 1 <= int(raw) <= len(packages):
                    raise ValueError('Invalid package number')
                package = packages[int(raw) - 1]
                checksum = package.with_name(package.name + '.sha256').read_text().strip()
                with engine.unpack(package, checksum) as (stage, manifest):
                    plan = engine.preflight(manifest, stage)
                for message in plan['errors'] + plan['pending']:
                    print('  ' + message)
                if plan['errors']:
                    raise ValueError('Import blocked by destination preflight')
                destination = engine.identity()
                if summary_plan([manifest], destination, manifest['source']['hostname'], destination['hostname']):
                    result = engine.import_package(package, checksum, destination['id'])
                    print('Destination copy passed checks. Report: ' + result['report'])
            elif choice == '5':
                ssh_support.manage(engine)
            elif choice == '6':
                reports = sorted(engine.reports.glob('*.json'))
                for index, report in enumerate(reports, 1):
                    item = read_json(report)
                    print(f'  {index}) {item.get("domain", "Batch")} — {item.get("status", report.name)}')
                raw = input('Select report to verify; Enter cancels: ').strip()
                if not raw:
                    continue
                if not raw.isdigit() or not 1 <= int(raw) <= len(reports):
                    raise ValueError('Invalid report number')
                path = reports[int(raw) - 1]
                report = read_json(path)
                if 'folder' not in report:
                    print(json.dumps(report, indent=2))
                    continue
                print(f'{report["domain"]}: {report["status"]}')
                for pending in report.get('pending', []):
                    print('[ACTION] ' + pending)
                print('Private job/service definitions and recovery details: ' + str(path))
                if input('Run destination service/database/HTTP checks now? [y/N]: ').lower() == 'y':
                    result = engine.verify(report['folder'], report.get('tls', False))
                    for check in result['checks']:
                        print(('[OK] ' if check['ok'] else '[FAILED] ') + check['check'] + ': ' + check['detail'])
                    report['last_verification'] = result
                    if result['ready']:
                        report['status'] = 'COPIED_PENDING_CUTOVER'
                    write_json(path, report)
            else:
                print('Invalid option.')
        except (OSError, ValueError, subprocess.SubprocessError, tarfile.TarError) as error:
            print('[FAILED] ' + str(error), file=sys.stderr)
        input('Press Enter to return to Server Migration...')


def main():
    global LOG_PATH
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', nargs='?', default='menu', choices=('menu', 'identity', 'inventory', 'export', 'inspect', 'import', 'verify', 'incoming', 'receive', 'upgrade'))
    parser.add_argument('arguments', nargs='*')
    parser.add_argument('--tls', action='store_true')
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error('Server Migration requires root')
    os.umask(0o077)
    engine = Engine()
    engine.initialize()
    LOG_PATH = engine.state / 'commands.log'
    if args.action == 'menu':
        menu(engine)
        return 0
    try:
        with contextlib.redirect_stdout(sys.stderr):
            if args.action == 'identity':
                result = engine.identity()
            elif args.action == 'upgrade':
                result = engine.upgrade_storage()
            elif args.action == 'inventory':
                result = engine.inventory()
            elif args.action == 'export':
                with engine.lock():
                    result = engine.export(args.arguments[0])
            elif args.action == 'inspect':
                with engine.unpack(*args.arguments) as (stage, manifest):
                    result = engine.preflight(manifest, stage)
            elif args.action == 'import':
                result = engine.import_package(*args.arguments)
            elif args.action == 'verify':
                result = engine.verify(args.arguments[0], args.tls)
            elif args.action in ('incoming', 'receive'):
                job = args.arguments[0]
                if not re.fullmatch('[a-f0-9]{32}', job):
                    raise ValueError('Invalid upload ID')
                path = engine.packages / f'{job}.spm.tar.gz.partial'
                if args.action == 'incoming':
                    result = {'path': str(path)}
                else:
                    checksum = args.arguments[1]
                    if not re.fullmatch('[a-f0-9]{64}', checksum) or digest(path) != checksum:
                        raise ValueError('Upload checksum mismatch; no import was started')
                    target = path.with_suffix('')
                    os.replace(path, target)
                    os.chmod(target, 0o600)
                    target.with_name(target.name + '.sha256').write_text(checksum + '\n')
                    result = {'package': str(target)}
        print(json.dumps(result))
        return 0
    except (OSError, ValueError, IndexError, TypeError, subprocess.SubprocessError, tarfile.TarError) as error:
        print('[FAILED] ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (KeyboardInterrupt, EOFError):
        print('\nCancelled. Source data and completed destination copies are retained.', file=sys.stderr)
        raise SystemExit(130)
    except (OSError, ValueError, tarfile.TarError) as error:
        print('[FAILED] ' + str(error), file=sys.stderr)
        raise SystemExit(1)
