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
    parts = version.split('.')
    if not all(p.isdigit() for p in parts) or len(parts) < 2:
        raise RuntimeError('Unrecognized RPM version: ' + version)
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


def open_base(service=None, require_locks=False):
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
    for pkg in base.sack.query().available():
        kind = family(pkg.name)
        if kind and kind != service:
            blocked.append(pkg)
        elif kind == service:
            previous = old.get(identity(pkg), anchor)
            if (branch(service, pkg.version) != branch(service, previous.version)
                    or not allowed(service, pkg.version)):
                blocked.append(pkg)
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
            'remove': sorted((row(p) for p in base.transaction.remove_set), key=lambda r: (r['name'], r['arch']))}
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
            if branch(service, pkg.version) != branch(service, (previous or anchor).version):
                raise RuntimeError('Branch migration blocked: ' + str(pkg))
            if not allowed(service, pkg.version):
                raise RuntimeError('Version is not approved by the configured policy: ' + str(pkg))


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


def main():
    if sys.argv[1:] == ['--repair-versionlock']:
        repair_versionlock()
        return
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
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.action == 'check':
            with open_base(args.service) as base:
                audit(args.service, [p for p in base.sack.query().installed() if family(p.name) == args.service])
                plan, _ = resolve(base, args.service, False)
                show_plan(plan)
                if args.service.startswith('php'):
                    check_source_override(args.service)
        else:
            apply(args.service, args.action == 'security')


if __name__ == '__main__':
    try:
        main()
    except (Exception, KeyboardInterrupt) as error:
        print('[FAIL] ' + (str(error) or 'Operation interrupted'), file=sys.stderr, flush=True)
        sys.exit(1)
