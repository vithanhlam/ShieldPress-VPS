#!/usr/bin/python3
"""Repository advisory checks and conservative, same-branch RPM updates."""
import argparse
import configparser
from contextlib import contextmanager
import fnmatch
import gzip
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
from datetime import datetime

BASE = Path('/opt/shieldpress')
DATA = Path('/var/shieldpress/data')


@contextmanager
def stage(label, estimate=60):
    print(f'[STAGE] {label}: approximate duration ~{estimate}s.', flush=True)
    stop = threading.Event()
    monitor = None
    if sys.stdout.isatty() or os.environ.get('SHIELDPRESS_UPDATE_TTY') == '1':
        def animate():
            started = time.monotonic()
            frames = '|/-\\'
            index = 0
            while not stop.wait(0.2):
                remaining = estimate - int(time.monotonic() - started)
                eta = f'ETA ~{remaining}s' if remaining > 0 else 'taking longer than estimated; still running'
                print(f'\r\033[K[{frames[index % 4]}] {label}: {eta}', end='', flush=True)
                index += 1
        monitor = threading.Thread(target=animate, daemon=True)
        monitor.start()
    try:
        yield
    finally:
        stop.set()
        if monitor:
            monitor.join()
            print('\r\033[K', end='', flush=True)


def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def family(name):
    if not name:
        return None
    lower = name.lower()
    if lower == 'nginx' or lower.startswith('nginx-'):
        return 'nginx'
    if lower == 'mariadb' or lower.startswith('mariadb-'):
        return 'mariadb'
    if re.fullmatch(r'postgresql(?:\d+)?(?:-.*)?', lower):
        return 'postgresql'
    if lower in ('nodejs', 'npm', 'libnode') or lower.startswith('nodejs-'):
        return 'nodejs'
    if lower == 'php' or lower.startswith('php-'):
        return 'php-system'
    match = re.match(r'php(\d{2})-', name)
    return 'php' + match[1] if match else None


def branch(service, version):
    match = re.fullmatch(r'([0-9]+(?:\.[0-9]+)+)(?:[~^]?[A-Za-z][A-Za-z0-9._~^]*)?', version)
    if not match:
        raise RuntimeError('Unrecognized RPM version: ' + version)
    parts = match[1].split('.')
    # PostgreSQL 10+ retains on-disk compatibility within one major.
    count = 1 if service == 'postgresql' and int(parts[0]) >= 10 else 2
    return '.'.join(parts[:count])


def allowed(service, version):
    policy = {}
    for line in (BASE / 'config/upgrade-policy.conf').read_text().splitlines():
        match = re.fullmatch(r'([A-Z_]+)="([^"]*)"', line.strip())
        if match:
            policy[match[1]] = match[2].split()
    key = ('PHP' if service.startswith('php') else service.upper())
    if any(fnmatch.fnmatchcase(version, p) for p in policy.get(key + '_BLOCKED', [])):
        return False
    return any(fnmatch.fnmatchcase(version, p) for p in policy.get(key + '_ALLOWED', []))


def package_version_allowed(service, pkg, previous, anchor):
    # Independently versioned modules follow the server's branch policy.
    # Package family checks and DNF dependencies enforce runtime compatibility.
    if service == 'nginx' and pkg.name.startswith(('nginx-mod-', 'nginx-module-')):
        return allowed(service, anchor.version)
    if service.startswith('php') and pkg.name.startswith(service + '-php-pecl-'):
        return allowed(service, anchor.version)
    return (branch(service, pkg.version) == branch(service, (previous or anchor).version)
            and allowed(service, pkg.version))


def row(pkg):
    return {'name': pkg.name, 'arch': pkg.arch, 'epoch': str(pkg.epoch),
            'version': pkg.version, 'release': pkg.release, 'repo': pkg.reponame}


def show_plan(plan):
    def version(pkg):
        return pkg['epoch'] + ':' + pkg['version'] + '-' + pkg['release']
    print('\nInstalled packages:')
    for pkg in plan['installed']:
        print(f"  {pkg['name']}.{pkg['arch']}: {version(pkg)}")
    print('\nProposed transaction (including dependencies):')
    for pkg in plan['install']:
        print(f"  {pkg['name']}.{pkg['arch']} -> {version(pkg)} [{pkg['repo']}]")
    if not plan['install']:
        print('  No eligible same-branch updates. Check repository coverage and the configured upgrade policy.')
    print(flush=True)


def identity(pkg):
    return pkg.name, pkg.arch


def compare(left, right):
    import rpm
    return rpm.labelCompare((str(left.epoch), left.version, left.release),
                            (str(right.epoch), right.version, right.release))


def locklist_path(conf, required=True):
    config = configparser.RawConfigParser()
    config.read([str(Path(p) / 'versionlock.conf') for p in conf.pluginconfpath])
    if not config.has_option('main', 'locklist'):
        if required:
            raise RuntimeError('DNF versionlock configuration is missing. Run service-updates.py --repair-versionlock as root, then retry')
        return None
    path = Path(config.get('main', 'locklist'))
    if not path.is_absolute():
        raise RuntimeError('DNF versionlock locklist must use an absolute path')
    if not path.is_file():
        if required:
            raise RuntimeError('DNF versionlock list is missing: ' + str(path) + '. Run --repair-versionlock as root')
        return None
    return path.resolve(strict=True)


def repair_versionlock():
    if os.geteuid() != 0:
        raise RuntimeError('Root is required to repair package protection')
    os.umask(0o077)
    if subprocess.run(['rpm', '-q', 'python3-dnf-plugin-versionlock'], stdout=subprocess.DEVNULL).returncode:
        with stage('Installing the DNF versionlock dependency', 120):
            run(['dnf', 'install', '-y', 'python3-dnf-plugin-versionlock'])
    import dnf
    with dnf.Base() as base:
        base.conf.read()
        directories = [Path(p) for p in base.conf.pluginconfpath]
        if not directories:
            raise RuntimeError('DNF has no plugin configuration directory; restore the system DNF configuration')
        config = configparser.RawConfigParser()
        files = [directory / 'versionlock.conf' for directory in directories]
        config.read([str(p) for p in files])
        if config.has_option('main', 'enabled') and not config.getboolean('main', 'enabled'):
            raise RuntimeError('Versionlock is explicitly disabled; review its configuration before enabling package updates')
        if not config.has_option('main', 'locklist'):
            directory = directories[-1]
            directory.mkdir(parents=True, exist_ok=True)
            path = directory / 'versionlock.list'
            destination = files[-1]
            # Retain existing sections and rules; add only the missing setting.
            local = configparser.RawConfigParser()
            local.read(str(destination))
            if not local.has_section('main'):
                local.add_section('main')
            local.set('main', 'locklist', str(path))
            handle, temporary = tempfile.mkstemp(prefix='.versionlock-', dir=directory)
            try:
                with os.fdopen(handle, 'w') as output:
                    local.write(output)
                os.chmod(temporary, 0o644)
                os.replace(temporary, destination)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
        else:
            path = Path(config.get('main', 'locklist'))
            if not path.is_absolute():
                raise RuntimeError('Custom versionlock list must use an absolute path')
        path.parent.mkdir(parents=True, exist_ok=True)
        # Exclusive creation never truncates retained administrator rules.
        try:
            versions = run(['rpm', '-qa', '--qf', '%{NAME}|%{NAME}-%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\n'],
                           stdout=subprocess.PIPE, text=True).stdout.splitlines()
            rules = [line.split('|', 1)[1] for line in versions if '|' in line and family(line.split('|', 1)[0])]
            with path.open('x') as output:
                output.write('\n'.join(rules) + ('\n' if rules else ''))
            print('[INFO] Missing lock list initialized from installed service RPMs')
        except FileExistsError:
            pass
    with stage('Verifying package protection'):
        run(['dnf', '-q', 'versionlock', 'list'])
    print('[OK] DNF package protection is ready; existing rules retained')


def service_lock(rule, service, names):
    import dnf.subject
    import hawkey
    if not rule or rule.startswith(('#', '!')):
        return False
    possibilities = dnf.subject.Subject(rule).get_nevra_possibilities(
        forms=[hawkey.FORM_NEVRA, hawkey.FORM_NEVR, hawkey.FORM_NEV, hawkey.FORM_NA, hawkey.FORM_NAME])
    return any(family(n.name) == service and any(fnmatch.fnmatchcase(name, n.name) for name in names)
               for n in possibilities)


def open_base(service=None, require_locks=False, refresh=True):
    import dnf
    base = dnf.Base()
    base.conf.read()
    # Native versionlock filtering remains active for dependencies and other
    # stacks. Override only the selected service's positive locks in a private
    # temporary plugin configuration, leaving persistent configuration intact.
    if service:
        locklist = locklist_path(base.conf, required=require_locks)
        if locklist is None:
            print('[WARN] Package protection is not configured. Checks remain read-only; updates require versionlock repair.', flush=True)
        names = run(['rpm', '-qa', '--qf', '%{NAME}\n'], stdout=subprocess.PIPE, text=True).stdout.splitlines()
        temporary = tempfile.TemporaryDirectory(prefix='shieldpress-service-locks-')
        base._shieldpress_lock_config = temporary
        filtered = []
        for rule in (locklist.read_text().splitlines() if locklist else []):
            rule = rule.strip()
            if not rule or rule.startswith('#'):
                continue
            if not service_lock(rule, service, names):
                filtered.append(rule)
        private = Path(temporary.name)
        (private / 'versionlock.list').write_text('\n'.join(filtered) + '\n')
        (private / 'versionlock.conf').write_text('[main]\nlocklist=' + str(private / 'versionlock.list') + '\n')
        base.conf.pluginconfpath = list(base.conf.pluginconfpath) + [str(private)]
        base.conf.excludepkgs = [p for p in base.conf.excludepkgs if family(p) != service]
    base.conf.install_weak_deps = False
    base.conf.best = True
    base.init_plugins()
    base.pre_configure_plugins()
    base.read_all_repos()
    base.configure_plugins()
    for repo in base.repos.iter_enabled():
        if service:
            repo.excludepkgs = [p for p in repo.excludepkgs if family(p) != service]
        repo.skip_if_unavailable = False
        if refresh:
            repo.metadata_expire = 0
    with stage('Refreshing repository metadata and reading installed RPMs'):
        base.fill_sack()
    return base


def resolve(base, service, security):
    installed = list(base.sack.query().installed())
    targets = [p for p in installed if family(p.name) == service]
    if not targets:
        raise RuntimeError('No managed RPM installation found for ' + service)
    servers = [p for p in targets if p.name.endswith('-server') or
               p.name.endswith('-php-fpm') or p.name == 'nginx']
    if service == 'postgresql' and len(servers) > 1:
        raise RuntimeError('Multiple PostgreSQL server RPM branches found; review each cluster separately before updating')
    anchor = next(iter(servers), None)
    if anchor is None:
        raise RuntimeError('Managed server package not found; client-only installations are not updated')
    old = {identity(p): p for p in installed}
    blocked = []
    policy_blocked = set()
    for pkg in base.sack.query().available():
        kind = family(pkg.name)
        if kind and kind != service:
            blocked.append(pkg)
        elif kind == service:
            previous = old.get(identity(pkg))
            if not package_version_allowed(service, pkg, previous, anchor):
                blocked.append(pkg)
                if (previous and branch(service, pkg.version) == branch(service, previous.version)
                        and not allowed(service, pkg.version) and compare(pkg, previous) > 0):
                    policy_blocked.add((pkg.name, pkg.version))
    for name, version in sorted(policy_blocked):
        print(f'[WARN] Repository update {name} {version} is blocked by config/upgrade-policy.conf; review the allowed/blocked patterns.', flush=True)
    base.sack.add_excludes(blocked)
    if security:
        base.add_security_filters('gte', types=['security'])
    for name in sorted({p.name for p in targets}):
        base.upgrade(name)
    base.resolve(allow_erasing=False)
    validate_transaction(base.transaction, installed, service, anchor)
    plan = {'service': service, 'security_only': security,
            'installed': sorted((row(p) for p in targets), key=lambda r: (r['name'], r['arch'])),
            'install': sorted((row(p) for p in base.transaction.install_set), key=lambda r: (r['name'], r['arch'])),
            'remove': sorted((row(p) for p in base.transaction.remove_set), key=lambda r: (r['name'], r['arch'])),
            'policy_blocked': [name + ' ' + version for name, version in sorted(policy_blocked)]}
    return plan, anchor


def validate_transaction(transaction, installed, service, anchor):
    old = {identity(p): p for p in installed}
    incoming = {identity(p): p for p in transaction.install_set}
    for pkg in transaction.remove_set:
        if identity(pkg) not in incoming:
            raise RuntimeError('Package removal blocked: ' + str(pkg))
    for pkg in transaction.install_set:
        previous = old.get(identity(pkg))
        if previous and compare(pkg, previous) < 0:
            raise RuntimeError('Package downgrade blocked: ' + str(pkg))
        kind = family(pkg.name)
        if kind and kind != service:
            raise RuntimeError('Changing another managed stack is blocked: ' + str(pkg))
        if kind == service:
            if not package_version_allowed(service, pkg, previous, anchor):
                raise RuntimeError('Branch migration or unapproved version blocked: ' + str(pkg))


def service_info(service, anchor):
    if service == 'nginx':
        return 'nginx', ['nginx', '-t']
    if service.startswith('php'):
        v = service[3:]
        return f'php{v}-php-fpm', [f'/opt/remi/php{v}/root/usr/sbin/php-fpm', '-t']
    if service == 'mariadb':
        return 'mariadb', ['mysqladmin', 'ping']
    match = re.match(r'postgresql(\d+)-server$', anchor.name)
    suffix = '-' + match[1] if match else ''
    prefix = '/usr/pgsql-' + match[1] + '/bin/' if match else ''
    return 'postgresql' + suffix, ['sudo', '-u', 'postgres', prefix + 'psql', '-v', 'ON_ERROR_STOP=1', '-c', 'SELECT 1;']


def check_source_override(service):
    if service.startswith('php') and (DATA / ('php-source-' + service[3:]) / 'active').exists():
        raise RuntimeError('A managed PHP source security build is active. Use its dedicated security repair; RPM updates would replace its entrypoints')


def backup(service, anchor):
    root = Path('/var/shieldpress/backups/service-updates')
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory = Path(tempfile.mkdtemp(prefix=service + '-' + datetime.now().strftime('%Y%m%d-%H%M%S-'), dir=root))
    print('[INFO] Recovery files: ' + str(directory), flush=True)
    paths = {'nginx': ['/etc/nginx'], 'mariadb': ['/etc/my.cnf', '/etc/my.cnf.d'],
             'postgresql': ['/var/lib/pgsql/data/postgresql.conf', '/var/lib/pgsql/data/pg_hba.conf', '/etc/sysconfig/pgsql']}
    configs = paths.get(service, ['/etc/opt/remi/' + service]) + ['/etc/systemd/system']
    if service == 'postgresql':
        # Query the actual cluster location, including PGDG installations.
        _, health = service_info(service, anchor)
        command = health[:-4] + ['-At', '-c', 'SHOW config_file;']
        config = run(command, stdout=subprocess.PIPE, text=True).stdout.strip()
        command = health[:-4] + ['-At', '-c', 'SHOW hba_file;']
        hba = run(command, stdout=subprocess.PIPE, text=True).stdout.strip()
        configs += [config, hba]
    with tarfile.open(directory / 'config.tar.gz', 'w:gz') as archive:
        for name in dict.fromkeys(configs):
            if name and Path(name).exists():
                archive.add(name, arcname=name.lstrip('/'))
    if service in ('mariadb', 'postgresql'):
        if service == 'mariadb':
            command = ['mysqldump', '--all-databases', '--lock-all-tables', '--routines', '--events', '--triggers']
        else:
            _, health = service_info(service, anchor)
            command = health[:-5] + [str(Path(health[3]).with_name('pg_dumpall'))]
        output = directory / 'databases.sql.gz'
        with subprocess.Popen(command, stdout=subprocess.PIPE) as process:
            with gzip.open(output, 'wb') as dump:
                shutil.copyfileobj(process.stdout, dump)
            if process.wait() != 0:
                raise RuntimeError('Database backup failed; package update cancelled. Recovery files: ' + str(directory))
        with gzip.open(output, 'rb') as dump:
            if not dump.read(1):
                raise RuntimeError('Empty database backup; update cancelled')
    return directory


def audit(service, targets):
    if not targets:
        raise RuntimeError('No managed RPM installation found for ' + service)
    print('[WARN] Advisory coverage depends on enabled repositories. Empty results do not prove there are no CVEs. Vendor backports are identified by full RPM versions, including release numbers.', flush=True)
    print('[INFO] Available repository security advisories and referenced CVEs:', flush=True)
    names = sorted({p.name for p in targets})
    with stage('Checking repository security advisories'):
        run(['dnf', '--refresh', '--disableplugin=versionlock', '--disableexcludes=all',
             'updateinfo', 'info', '--available', '--security'] + names)


def refresh_locks(names):
    import dnf
    with dnf.Base() as base:
        base.conf.read()
        path = locklist_path(base.conf)
    services = {family(name) for name in names}
    installed = run(['rpm', '-qa', '--qf', '%{NAME}\n'], stdout=subprocess.PIPE, text=True).stdout.splitlines()
    names = sorted({name for name in installed if family(name) in services})
    if not names:
        raise RuntimeError('No service packages remain installed; package protection requires review')
    before = path.read_text()
    # Preserve explicit negative rules and every unrelated lock. Replace the
    # selected positive rules atomically, so failed writes leave old locks.
    lines = [line for line in before.splitlines()
             if not any(service_lock(line.strip(), service, names) for service in services)]
    versions = run(['rpm', '-q', '--qf', '%{NAME}-%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\n'] + names,
                   stdout=subprocess.PIPE, text=True).stdout.splitlines()
    lines += versions
    handle, temporary = tempfile.mkstemp(prefix='.shieldpress-locks-', dir=path.parent)
    try:
        with os.fdopen(handle, 'w') as output:
            output.write('\n'.join(lines) + '\n')
            output.flush()
            os.fsync(output.fileno())
        stat = path.stat()
        os.chmod(temporary, stat.st_mode & 0o777)
        os.chown(temporary, stat.st_uid, stat.st_gid)
        if path.read_text() != before:
            raise RuntimeError('Versionlock configuration changed concurrently; retry package protection')
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def apply(service, security):
    check_source_override(service)
    with open_base(service, require_locks=True) as base:
        plan, anchor = resolve(base, service, security)
        show_plan(plan)
        if not plan['install']:
            print('[INFO] No eligible same-branch updates in the configured repositories. This is not a complete CVE assessment.')
            if security:
                print('[INFO] Security-only mode installs only updates labelled by repository advisories (updateinfo). '
                      'Repositories without that metadata, such as nginx.org, never qualify even when a release fixes CVEs. '
                      "Use 'Apply All Same-Branch Updates' (option 3) to install same-branch releases.", flush=True)
            return
        unit, health = service_info(service, anchor)
        active = subprocess.run(['systemctl', 'is-active', '--quiet', unit]).returncode == 0
        if service in ('mariadb', 'postgresql') and not active:
            raise RuntimeError('Start the managed database service and verify its health before updating')
        run(health)
        run(['dnf', 'versionlock', 'list'], stdout=subprocess.DEVNULL)
        if shutil.disk_usage('/').free < 500 * 1024 * 1024:
            raise RuntimeError('At least 500 MiB of free space is required')
        print('[WARN] Active services will restart; dependent websites may briefly be unavailable. Database major migrations are blocked.')
        if service == 'mariadb':
            print('[WARN] The full database backup locks table writes until the dump completes.')
        if input('Apply this exact transaction? [y/N]: ').lower() != 'y':
            return
        # Package and metadata locks are acquired by DNF during the transaction.
        with stage('Saving configuration and database recovery files', 180):
            recovery = backup(service, anchor)
        (recovery / 'plan.json').write_text(json.dumps(plan, indent=2))
        with stage('Downloading packages', 120):
            base.download_packages(list(base.transaction.install_set))
        for pkg in base.transaction.install_set:
            result, message = base.package_signature_check(pkg)
            if result:
                raise RuntimeError('RPM signature verification failed: ' + message)
        # Ensure the installed RPM database did not change after plan creation.
        actual = run(['rpm', '-qa', '--qf', '%{NAME}|%{ARCH}|%{EPOCHNUM}|%{VERSION}|%{RELEASE}\n'], stdout=subprocess.PIPE, text=True).stdout
        before = {(p.name, p.arch, str(p.epoch), p.version, p.release) for p in base.sack.query().installed()}
        # DNF omits RPM's pseudo-packages used to store imported signing keys.
        current = {tuple(line.split('|')) for line in actual.splitlines() if not line.startswith('gpg-pubkey|')}
        if current != before:
            raise RuntimeError('Installed packages changed during confirmation; check updates again')
        failure = None
        try:
            with stage('Applying the resolved package transaction', 120):
                base.do_transaction()
        except (Exception, KeyboardInterrupt) as error:
            failure = error if str(error) else RuntimeError('Package transaction interrupted')
        # Always attempt package protection and service recovery after a partial
        # transaction. Do not restore live database dumps or downgrade packages.
        try:
            with stage('Refreshing package protection', 15):
                refresh_locks(sorted({p['name'] for p in plan['installed']}))
        except Exception as error:
            failure = failure or error
            print('[FAIL] Package locks require repair: ' + str(error), flush=True)
        if active:
            try:
                print('[STAGE] Restarting the previously active service and validating health...', flush=True)
                # Nginx/PHP configuration must pass before restarting workers.
                if service == 'nginx' or service.startswith('php'):
                    run(health)
                with stage('Restarting ' + unit, 30):
                    run(['systemctl', 'restart', unit])
                run(['systemctl', 'is-active', '--quiet', unit])
                run(health)
            except Exception as error:
                failure = failure or error
                print('[FAIL] Service recovery requires attention: ' + str(error), flush=True)
        else:
            try:
                if service == 'nginx' or service.startswith('php'):
                    run(health)
                if subprocess.run(['systemctl', 'is-active', '--quiet', unit]).returncode == 0:
                    run(['systemctl', 'stop', unit])
            except Exception as error:
                failure = failure or error
        for expected in plan['install']:
            got = run(['rpm', '-q', expected['name'] + '.' + expected['arch'], '--qf', '%{EPOCHNUM}:%{VERSION}-%{RELEASE}'], stdout=subprocess.PIPE, text=True).stdout
            if got != expected['epoch'] + ':' + expected['version'] + '-' + expected['release']:
                failure = failure or RuntimeError('Installed version verification failed: ' + expected['name'])
        if failure:
            raise RuntimeError(f'Update requires attention: {failure}. Recovery files retained at {recovery}; no automatic database restore was attempted')
        print('[OK] Package versions, service health and package protection verified. Recovery files: ' + str(recovery))
        return True


STATUS = DATA / 'service-updates-status.json'
STALE_SECONDS = 3 * 86400
MENU = {'nginx': ('Nginx', '3 Nginx Manager -> 16'),
        'mariadb': ('MariaDB', '10 Database Manager -> 1 MariaDB -> 14'),
        'postgresql': ('PostgreSQL', '10 Database Manager -> 2 PostgreSQL -> 14')}


def describe(service):
    if service in MENU:
        return MENU[service]
    # php83 -> PHP 8.3; the PHP menu asks for the branch after option 14.
    return 'PHP ' + service[3] + '.' + service[4:], '4 PHP Manager -> 14 -> ' + service + '-php-fpm'


def installed_services():
    names = set(run(['rpm', '-qa', '--qf', '%{NAME}\n'], stdout=subprocess.PIPE, text=True).stdout.split())
    services = []
    if 'nginx' in names:
        services.append('nginx')
    services += sorted(family(n) for n in names if re.fullmatch(r'php\d{2}-php-fpm', n))
    if 'mariadb-server' in names:
        services.append('mariadb')
    if any(re.fullmatch(r'postgresql\d*-server', n) for n in names):
        services.append('postgresql')
    return services


def advisories(base, transaction, installed):
    """Advisories published for any release between the installed and the proposed package."""
    import hawkey
    old = {identity(p): p for p in installed}
    found = {}
    for pkg in transaction.install_set:
        previous = old.get(identity(pkg))
        candidates = base.sack.query().available().filter(name=pkg.name, arch=pkg.arch)
        for candidate in candidates:
            if compare(candidate, pkg) > 0 or (previous and compare(candidate, previous) <= 0):
                continue
            for advisory in candidate.get_advisories(hawkey.EQ):
                if advisory.type != hawkey.ADVISORY_SECURITY:
                    continue
                entry = found.setdefault(advisory.id, {'id': advisory.id, 'severity': advisory.severity or '', 'cves': set()})
                entry['cves'].update(ref.id for ref in advisory.references if ref.type == hawkey.REFERENCE_CVE)
    return [dict(a, cves=sorted(a['cves'])) for a in sorted(found.values(), key=lambda a: a['id'])]


def scan_service(service, refresh):
    label, menu = describe(service)
    entry = {'service': service, 'label': label, 'menu': menu}
    if service.startswith('php') and (DATA / ('php-source-' + service[3:]) / 'active').exists():
        # Source builds are patched by their own repair; RPM updates do not apply.
        return None
    with open_base(service, refresh=refresh) as base:
        installed = list(base.sack.query().installed())
        plan, anchor = resolve(base, service, False)
        entry['installed'] = anchor.version + '-' + anchor.release
        entry['policy_blocked'] = plan['policy_blocked']
        if not plan['install']:
            return entry
        target = next((p for p in plan['install'] if (p['name'], p['arch']) == identity(anchor)), plan['install'][0])
        entry['available'] = target['version'] + '-' + target['release']
        entry['packages'] = len(plan['install'])
        try:
            entry['advisories'] = advisories(base, base.transaction, installed)
        except Exception as error:
            entry['advisories'] = None
            entry['advisory_error'] = str(error) or type(error).__name__
    return entry


def read_status():
    try:
        return json.loads(STATUS.read_text())
    except (OSError, ValueError):
        return None


def write_status(status):
    DATA.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(prefix='.service-updates-status-', dir=DATA)
    try:
        with os.fdopen(handle, 'w') as output:
            json.dump(status, output, indent=2)
        os.replace(temporary, STATUS)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def pending_key(entry):
    return entry['service'] + ' ' + entry['available']


def notify(entries):
    script = BASE / 'modules/notification/telegram-notify.sh'
    if not entries or not script.exists():
        return
    lines = []
    for entry in entries:
        line = f"{entry['label']}: {entry['installed']} -> {entry['available']}"
        if entry.get('advisories'):
            line += ' | ' + ', '.join(a['id'] + (' ' + a['severity'] if a['severity'] else '') for a in entry['advisories'])
        elif entry.get('advisories') == []:
            line += ' | no repository security advisory (may still fix CVEs)'
        lines.append(line + '\n  shieldpress -> ' + entry['menu'] + ' -> 3 Apply All Same-Branch Updates')
    try:
        subprocess.run(['bash', str(script), 'send', 'security_alert', 'Service updates available', '\n'.join(lines)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
    except (OSError, subprocess.SubprocessError):
        pass


def scan(services=None, refresh=True, send=True):
    """Read-only check of every managed service; never changes packages."""
    previous = read_status() or {}
    full = services is None
    services = installed_services() if full else services
    results, errors = [], []
    for index, service in enumerate(services):
        try:
            entry = scan_service(service, refresh and index == 0)
            if entry:
                results.append(entry)
        except Exception as error:
            label, menu = describe(service)
            errors.append({'service': service, 'label': label, 'menu': menu, 'error': str(error) or type(error).__name__})
    if not full:
        # Keep the other services from the last full check.
        keep = [e for e in previous.get('services', []) if e['service'] not in services]
        results = keep + results
        errors = [e for e in previous.get('errors', []) if e['service'] not in services] + errors
        checked = previous.get('checked', int(time.time()))
    else:
        checked = int(time.time())
    status = {'checked': checked, 'services': results, 'errors': errors,
              'notified': previous.get('notified', [])}
    pending = [e for e in results if e.get('available')]
    keys = sorted(pending_key(e) for e in pending)
    if send and full:
        notify([e for e in pending if pending_key(e) not in status['notified']])
    # Retain only keys that are still pending so a reappearing update notifies again.
    status['notified'] = keys if full else [k for k in status['notified'] if k in keys]
    write_status(status)
    for entry in pending:
        print(f"[WARN] {entry['label']} {entry['installed']} -> {entry['available']} available", flush=True)
    for error in errors:
        print(f"[FAIL] {error['label']} check failed: {error['error']}", flush=True)
    if not pending and not errors:
        print('[OK] No same-branch service updates pending in the configured repositories', flush=True)
    return 1 if errors else 0


def banner():
    """Login summary for root, read from the cached status; never queries repositories."""
    status = read_status()
    if not status:
        return
    color = lambda code, text: f'\033[{code}m{text}\033[0m'
    pending = [e for e in status.get('services', []) if e.get('available')]
    errors = status.get('errors', [])
    age = time.time() - status.get('checked', 0)
    stale = age > STALE_SECONDS
    if not pending and not errors and not stale:
        return
    when = datetime.fromtimestamp(status.get('checked', 0)).strftime('%Y-%m-%d %H:%M')
    print(color(36, '──────────────────────────────────────'))
    if pending:
        print(color('1;33', f'  ⚠ Service updates pending') + color(2, f' (checked {when})'))
        for entry in pending:
            head = f"  {entry['label']:<11} {entry['installed']} → {entry['available']}"
            found = entry.get('advisories')
            if found:
                cves = sorted({c for a in found for c in a['cves']})
                severity = sorted({a['severity'] for a in found if a['severity']})
                text = ', '.join(a['id'] for a in found[:2]) + (f' +{len(found) - 2}' if len(found) > 2 else '')
                if severity:
                    text += ' (' + '/'.join(severity) + ')'
                if cves:
                    text += ': ' + ', '.join(cves[:3]) + (f' +{len(cves) - 3} more' if len(cves) > 3 else '')
                print(color('1;31', head) + '  ' + color(31, text))
            elif found == []:
                print(color(33, head) + '  ' + color(2, 'no repository security advisory; may still fix CVEs'))
            else:
                print(color(33, head) + '  ' + color(2, 'advisory lookup failed; review option 1'))
            print(color(2, f"      Update: shieldpress → {entry['menu'].replace('->', '→')} → 3 Apply All Same-Branch Updates"))
    for error in errors:
        print(color(33, f"  ⚠ {error['label']} update check failed") + color(2, ' (journalctl -u shieldpress-service-updates)'))
    if stale:
        print(color(33, f'  ⚠ Service update check is outdated (last run {when})') +
              color(2, ' (systemctl status shieldpress-service-updates.timer)'))


def main():
    if sys.argv[1:] == ['--repair-versionlock']:
        repair_versionlock()
        return
    if sys.argv[1:] == ['--banner']:
        banner()
        return
    if sys.argv[1:] == ['--scan']:
        if os.geteuid() != 0:
            raise RuntimeError('Root is required for repository checks')
        os.umask(0o077)
        DATA.mkdir(parents=True, exist_ok=True)
        import fcntl
        with (DATA / 'service-updates.lock').open('w') as lock:
            # Wait for an interactive update instead of failing the daily check.
            fcntl.flock(lock, fcntl.LOCK_EX)
            sys.exit(scan())
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('service', choices=['nginx', 'mariadb', 'postgresql', 'php'] + ['php' + str(n) for n in range(81, 86)])
    parser.add_argument('action', choices=['check', 'security', 'update'])
    args = parser.parse_args()
    os.umask(0o077)
    if os.geteuid() != 0:
        raise RuntimeError('Root is required for repository checks and updates')
    if args.service == 'php':
        names = run(['rpm', '-qa', '--qf', '%{NAME}\n'], stdout=subprocess.PIPE, text=True).stdout.splitlines()
        branches = sorted({family(name) for name in names if re.fullmatch(r'php\d{2}-php-fpm', name)})
        if not branches:
            raise RuntimeError('No managed Remi PHP-FPM packages found')
        for i, name in enumerate(branches, 1):
            print(f'{i}) {name}')
        choice = input('Select PHP branch [0 = Back]: ')
        if choice == '0' or not choice:
            return
        if not choice.isdigit() or not 1 <= int(choice) <= len(branches):
            raise RuntimeError('Invalid PHP branch')
        args.service = branches[int(choice) - 1]
    DATA.mkdir(parents=True, exist_ok=True)
    import fcntl
    with (DATA / 'service-updates.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Another service update or the daily update check is running; retry in a few minutes')
        if args.action == 'check':
            with open_base(args.service) as base:
                audit(args.service, [p for p in base.sack.query().installed() if family(p.name) == args.service])
                plan, _ = resolve(base, args.service, False)
                show_plan(plan)
                if args.service.startswith('php'):
                    check_source_override(args.service)
        elif apply(args.service, args.action == 'security'):
            # Clear the login notice for this service; repository metadata was just refreshed.
            try:
                with stage('Refreshing the login update notice', 30):
                    scan([args.service], refresh=False, send=False)
            except Exception as error:
                print('[WARN] Login update notice not refreshed: ' + str(error), flush=True)


if __name__ == '__main__':
    try:
        main()
    except (Exception, KeyboardInterrupt) as error:
        print('[FAIL] ' + (str(error) or 'Operation interrupted'), file=sys.stderr, flush=True)
        sys.exit(1)
