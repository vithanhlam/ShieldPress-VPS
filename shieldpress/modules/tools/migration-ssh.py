#!/usr/bin/env python3
"""Pair trusted migration peers using expiring, direction-specific SSH keys."""
import argparse
import base64
import contextlib
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
STATE = Path('/var/shieldpress/data/server-migration')
PROGRAM = '/opt/shieldpress/modules/tools/migration-ssh.py'
ENGINE = '/opt/shieldpress/modules/tools/server-migration.py'
LIFETIME = 7 * 24 * 60 * 60
ROLES = ('source', 'destination')


def server_role(role):
    return 'SSH SERVER A / SOURCE' if role == 'source' else 'SSH SERVER B / DESTINATION'


def checked(args, *, interactive=False, timeout=120):
    result = subprocess.run(list(map(str, args)), stdout=subprocess.PIPE,
                            stderr=None if interactive else subprocess.PIPE, timeout=timeout)
    if result.returncode:
        raise ValueError('SSH migration connection failed. Check the endpoint, host fingerprint, key expiry and remote ShieldPress version.')
    return result.stdout


def trusted(path, directory=False):
    info = path.lstat()
    expected = stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode) and info.st_nlink == 1
    if not expected or info.st_uid != os.geteuid() or info.st_mode & 0o022:
        raise ValueError('Untrusted SSH migration path: ' + str(path))


def private_directory(path, boundary=None):
    # Validate existing ancestors before mkdir; never repair app-owned SSH material.
    for parent in (path, *path.parents):
        if parent.exists() or parent.is_symlink():
            trusted(parent, directory=True)
        if parent == boundary:
            break
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path, 0o700)


def atomic(path, data):
    descriptor, temporary = tempfile.mkstemp(prefix='.pair-', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(data)
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def public_key(encoded):
    try:
        text = base64.b64decode(encoded, validate=True).decode('ascii')
        if '\n' in text or '\r' in text:
            raise ValueError('Multiline key')
        fields = text.split()
        raw = base64.b64decode(fields[1], validate=True)
        prefix = b'\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20'
        if fields[0] != 'ssh-ed25519' or not raw.startswith(prefix) or len(raw) != len(prefix) + 32:
            raise ValueError('Invalid Ed25519 key')
    except (ValueError, IndexError, UnicodeError) as error:
        raise ValueError('Expected one Ed25519 public key, never a private key') from error
    return 'ssh-ed25519 ' + fields[1], hashlib.sha256(raw).hexdigest()


def grant_paths(state=STATE, home=Path('/root')):
    grants = state / 'ssh-grants'
    ssh = home / '.ssh'
    private_directory(grants)
    private_directory(ssh)
    return grants, ssh / 'authorized_keys'


@contextlib.contextmanager
def authorization_lock(grants):
    lock = grants / 'authorized-keys.lock'
    if lock.exists() or lock.is_symlink():
        trusted(lock)
    with open(lock, 'a') as stream:
        os.chmod(lock, 0o600)
        fcntl.flock(stream, fcntl.LOCK_EX)
        yield


def authorize(encoded, role, state=STATE, home=Path('/root')):
    if role not in ROLES:
        raise ValueError('Choose source or destination migration permission')
    key, fingerprint = public_key(encoded)
    grants, authorized = grant_paths(state, home)
    marker = 'shieldpress-migration-v2:' + fingerprint
    command = shlex.join(['/usr/bin/python3', PROGRAM, 'gateway', fingerprint])
    entry = 'restrict,command="' + command + '" ' + key + ' ' + marker
    expires = int(time.time()) + LIFETIME
    with authorization_lock(grants):
        if authorized.exists() or authorized.is_symlink():
            trusted(authorized)
            original = authorized.read_text()
        else:
            original = ''
        lines = original.splitlines()
        blob = key.split()[1]
        for line in lines:
            if blob in line.split() and not line.endswith(' ' + marker):
                raise ValueError('This key already has authorization outside migration. Use a new dedicated key.')
        lines = [line for line in lines if not line.endswith(' ' + marker)]
        lines.append(entry)
        grant = grants / (fingerprint + '.json')
        if grant.exists() or grant.is_symlink():
            trusted(grant)
        atomic(grant, json.dumps({'fingerprint': fingerprint, 'role': role, 'expires': expires}).encode())
        atomic(authorized, ('\n'.join(lines) + '\n').encode())
    return {'fingerprint': fingerprint, 'role': role, 'expires': expires}


def revoke(fingerprint, state=STATE, home=Path('/root')):
    if not re.fullmatch('[a-f0-9]{64}', fingerprint):
        raise ValueError('Invalid managed key fingerprint')
    grants, authorized = grant_paths(state, home)
    marker = 'shieldpress-migration-v2:' + fingerprint
    with authorization_lock(grants):
        if authorized.exists() or authorized.is_symlink():
            trusted(authorized)
            lines = authorized.read_text().splitlines()
            atomic(authorized, ('\n'.join(line for line in lines if not line.endswith(' ' + marker)) + '\n').encode())
        grant = grants / (fingerprint + '.json')
        if grant.exists() or grant.is_symlink():
            trusted(grant)
            grant.unlink()
    return {'revoked': fingerprint}


def package_path(value, state=STATE, upload=False):
    path = Path(value)
    parent = state / 'packages'
    pattern = r'[A-Za-z0-9_-]+\.spm\.tar\.gz' + (r'\.partial' if upload else '')
    if path.parent != parent or not re.fullmatch(pattern, path.name):
        raise ValueError('Transfer is limited to migration package files')
    private_directory(parent)
    if path.exists() or path.is_symlink():
        trusted(path)
    return path


def gateway_request(command, grant, now=None, state=STATE):
    """Validate the forced command without passing any client text to a shell."""
    words = shlex.split(command)
    if words == ['migration-revoke']:
        return 'revoke', []
    if grant['expires'] <= (time.time() if now is None else now):
        raise ValueError('Migration key expired. Pair this server again to renew access.')
    if len(words) == 2 and words[0] in ('migration-upload', 'migration-download'):
        upload = words[0] == 'migration-upload'
        expected_role = 'destination' if upload else 'source'
        if grant['role'] != expected_role:
            raise ValueError('Key does not authorize this transfer direction')
        return ('upload' if upload else 'download'), [package_path(words[1], state, upload)]
    if len(words) < 3 or words[:2] != ['python3', ENGINE]:
        raise ValueError('This key permits migration commands only; shell, SCP/SFTP and forwarding are disabled')
    action, args = words[2], words[3:]
    common = {'identity': 0}
    allowed = {**common, **({'inventory': 0, 'export': 1} if grant['role'] == 'source' else
                            {'incoming': 1, 'receive': 2, 'inspect': 2, 'import': 3, 'verify': 1})}
    count = 2 if action == 'verify' and args[-1:] == ['--tls'] else allowed.get(action)
    if action not in allowed or len(args) != count:
        raise ValueError('Command is outside this key\'s migration permission')
    if action in ('export', 'verify') and not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_-]{0,29}', args[0]):
        raise ValueError('Invalid website directory')
    if action in ('incoming', 'receive') and not re.fullmatch('[a-f0-9]{32}', args[0]):
        raise ValueError('Invalid upload ID')
    if action in ('inspect', 'import'):
        package_path(args[0], state)
    if action in ('inspect', 'import', 'receive') and not re.fullmatch('[a-f0-9]{64}', args[1]):
        raise ValueError('Invalid checksum')
    if action == 'import' and not re.fullmatch('[a-f0-9]{64}', args[2]):
        raise ValueError('Invalid destination identity')
    return 'rpc', [action, *args]


def gateway(fingerprint):
    if not re.fullmatch('[a-f0-9]{64}', fingerprint):
        raise ValueError('Invalid managed key fingerprint')
    grant = STATE / 'ssh-grants' / (fingerprint + '.json')
    trusted(grant.parent, directory=True)
    trusted(grant)
    permission = json.loads(grant.read_text())
    if permission.get('fingerprint') != fingerprint or permission.get('role') not in ROLES:
        raise ValueError('Invalid migration authorization')
    action, args = gateway_request(os.environ.get('SSH_ORIGINAL_COMMAND', ''), permission)
    if action == 'revoke':
        print(json.dumps(revoke(fingerprint)))
    elif action == 'rpc':
        if args == ['identity']:
            output = checked(['/usr/bin/python3', ENGINE, 'identity'])
            identity = json.loads(output)
            identity['migration_ssh'] = permission
            print(json.dumps(identity))
            return 0
        return subprocess.call(['/usr/bin/python3', ENGINE, *args])
    elif action == 'upload':
        # Replace only an incomplete transfer; finished packages are published by receive/SHA-256.
        descriptor = os.open(args[0], os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, 'wb') as stream:
            shutil.copyfileobj(sys.stdin.buffer, stream, 1024 * 1024)
    elif action == 'download':
        descriptor = os.open(args[0], os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(descriptor, 'rb') as stream:
            shutil.copyfileobj(stream, sys.stdout.buffer, 1024 * 1024)
    return 0


class Remote:
    def __init__(self, host, port=22, role='destination', storage=None):
        host = host.removeprefix('root@').lower()
        if not host or not re.fullmatch(r'[a-z0-9][a-z0-9.:-]*', host) or not 1 <= port <= 65535 or role not in ROLES:
            raise ValueError('Enter a hostname/IP and SSH port; the remote account must be root')
        self.host, self.port, self.role = host, port, role
        self.identifier = hashlib.sha256(f'{host}:{port}:{role}'.encode()).hexdigest()[:24]
        self.folder = Path(storage or STATE / 'connections') / self.identifier
        self.key = self.folder / 'id_ed25519'
        self.known = self.folder / 'known_hosts'
        self.profile = self.folder / 'connection.json'
        self.options = ['-F', '/dev/null', '-i', str(self.key), '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
                        '-o', 'StrictHostKeyChecking=yes', '-o', 'UserKnownHostsFile=' + str(self.known),
                        '-o', 'GlobalKnownHostsFile=/dev/null', '-o', 'UpdateHostKeys=no',
                        '-o', 'ForwardAgent=no', '-o', 'ClearAllForwardings=yes', '-o', 'RequestTTY=no',
                        '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=4']

    def saved(self):
        if not self.profile.exists():
            return None
        trusted(self.folder, directory=True)
        trusted(self.profile)
        value = json.loads(self.profile.read_text())
        if (value.get('host'), value.get('port'), value.get('role')) != (self.host, self.port, self.role):
            raise ValueError('Saved SSH connection identity does not match this endpoint')
        return value

    def prepare(self):
        private_directory(self.folder)
        if self.key.exists() or self.key.is_symlink():
            trusted(self.key)
        else:
            public = self.key.with_name(self.key.name + '.pub')
            if public.exists() or public.is_symlink():
                trusted(public)
                public.unlink()
            checked(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', 'shieldpress-migration-' + self.identifier, '-f', self.key])
        trusted(self.key)
        os.chmod(self.key, 0o600)
        if not self.key.with_name(self.key.name + '.pub').exists():
            atomic(self.key.with_name(self.key.name + '.pub'), checked(['ssh-keygen', '-y', '-f', self.key]))
        trusted(self.key.with_name(self.key.name + '.pub'))
        if self.known.exists() or self.known.is_symlink():
            trusted(self.known)
        else:
            atomic(self.known, b'')
        text = self.key.with_name(self.key.name + '.pub').read_text().strip()
        encoded = base64.b64encode(text.encode()).decode()
        _, fingerprint = public_key(encoded)
        return encoded, fingerprint

    def setup(self, method=None):
        if not shutil.which('ssh') or not shutil.which('ssh-keygen'):
            if input('Install the OpenSSH client tools on this VPS? [y/N]: ').lower() != 'y':
                raise ValueError('SSH setup cancelled')
            manager = ['dnf', 'install', '-y', 'openssh-clients'] if shutil.which('dnf') else ['apt-get', 'install', '-y', 'openssh-client']
            checked(manager, interactive=True, timeout=600)
        encoded, fingerprint = self.prepare()
        local_role = 'DESTINATION B' if self.role == 'source' else 'SOURCE A'
        print(f'CLIENT / this VPS: {socket.gethostname()} [{local_role}]')
        print(f'Pair {server_role(self.role)}: root@{self.host}, SSH port {self.port}')
        print('Website data: ' + ('remote A -> this VPS B.' if self.role == 'source' else 'this VPS A -> remote B.'))
        print('A dedicated key is created locally. Only its public key is installed remotely; access expires after 7 days.')
        print('Compare the SSH host fingerprint with the remote VPS console before accepting it.')
        method = method or input('Pair using 1) existing SSH access/password [Enter], or 2) a remote console command: ').strip() or '1'
        authorize_command = shlex.join(['/usr/bin/python3', PROGRAM, 'authorize', encoded, self.role])
        local_id = hashlib.sha256(Path('/etc/machine-id').read_bytes().strip()).hexdigest()
        authorize_command += ' --exclude-id ' + local_id
        previous = self.saved()
        if previous:
            authorize_command += ' --server-id ' + previous['server']['id']
            if previous['fingerprint'] != fingerprint:
                authorize_command += ' --replace-grant ' + previous['fingerprint']
        bootstrap = ['ssh', '-F', '/dev/null', '-T', '-p', self.port, '-o', 'StrictHostKeyChecking=ask',
                     '-o', 'UserKnownHostsFile=' + str(self.known), '-o', 'GlobalKnownHostsFile=/dev/null',
                     '-o', 'UpdateHostKeys=no',
                     '-o', 'ForwardAgent=no', '-o', 'ClearAllForwardings=yes', '-o', 'NumberOfPasswordPrompts=1',
                     '-o', 'ConnectTimeout=10', 'root@' + self.host, authorize_command]
        if method == '1':
            try:
                granted = json.loads(checked(bootstrap, interactive=True, timeout=300))
            except (OSError, ValueError, subprocess.SubprocessError):
                print('Automatic pairing did not complete. Root SSH must already be reachable; use the provider console if password login is disabled.')
                method = '2'
        if method == '2':
            print(f'\nRun this public-key authorization command on {server_role(self.role)} ({self.host}), in its root console:\n\n' + authorize_command + '\n')
            print('Grant fingerprint: SHA256:' + base64.b64encode(bytes.fromhex(fingerprint)).decode().rstrip('='))
            input('After running it on that SSH server, return to this CLIENT and press Enter to verify...')
            # Permit the initial verified host-key prompt, then use strict key-only RPC below.
            options = [value for value in self.options]
            options[options.index('BatchMode=yes')] = 'BatchMode=no'
            options[options.index('StrictHostKeyChecking=yes')] = 'StrictHostKeyChecking=ask'
            checked(['ssh', '-T', '-p', self.port, *options, '-o', 'PasswordAuthentication=no', '-o', 'KbdInteractiveAuthentication=no',
                     'root@' + self.host, shlex.join(['python3', ENGINE, 'identity'])], interactive=True)
            granted = {'fingerprint': fingerprint, 'expires': int(time.time()) + LIFETIME, 'role': self.role}
        elif method != '1':
            raise ValueError('Choose pairing method 1 or 2')
        identity = json.loads(self.raw(shlex.join(['python3', ENGINE, 'identity'])))
        if identity.get('protocol') != 2 or not re.fullmatch('[a-f0-9]{64}', identity.get('id', '')):
            raise ValueError('Update ShieldPress on both VPSs before pairing migration access')
        if previous and identity['id'] != previous['server']['id']:
            raise ValueError('Paired VPS identity changed; no local connection was replaced')
        granted = identity['migration_ssh']
        if granted['fingerprint'] != fingerprint or granted['role'] != self.role:
            raise ValueError('Remote migration permission does not match this connection')
        atomic(self.profile, json.dumps({'host': self.host, 'port': self.port, 'role': self.role,
                                        'server': identity, 'fingerprint': granted['fingerprint'],
                                        'expires': granted['expires'], 'paired': int(time.time())}).encode())
        print(f'[OK] Paired {identity["hostname"]}, server ID {identity["id"][:12]}. Key-only migration access is ready.')
        return identity

    def connection_args(self):
        trusted(self.folder, directory=True)
        trusted(self.key)
        trusted(self.known)
        if self.key.stat().st_mode & 0o077:
            raise ValueError('The migration private key must have mode 600')
        return list(map(str, ['ssh', '-T', '-p', self.port, *self.options, 'root@' + self.host]))

    def raw(self, command, progress=False):
        return checked([*self.connection_args(), command], timeout=7200, interactive=progress)

    def call(self, action, *args):
        output = self.raw(shlex.join(['python3', ENGINE, action, *map(str, args)]), progress=action in ('export', 'import'))
        value = json.loads(output)
        if action == 'identity':
            permission = value.get('migration_ssh', {})
            if permission.get('role') != self.role:
                raise ValueError('This connection is not using the expected restricted migration key; pair it again')
        saved = self.saved()
        if saved and action == 'identity' and permission.get('fingerprint') != saved['fingerprint']:
            raise ValueError('Migration grant fingerprint changed; verify this connection before continuing')
        identity = value if action == 'identity' else value.get('destination')
        if saved and identity and identity.get('id') != saved['server']['id']:
            raise ValueError('Paired VPS identity changed. Stop and verify this server before pairing it again.')
        if saved and action == 'export' and value['manifest']['source']['id'] != saved['server']['id']:
            raise ValueError('Export came from a different VPS than the paired source')
        return value

    def transfer(self, local, remote, download=False):
        command = shlex.join(['migration-download' if download else 'migration-upload', str(remote)])
        args = [*self.connection_args(), command]
        print('[TRANSFER] ' + ('Receiving' if download else 'Sending') + ' package over encrypted migration SSH...', flush=True)
        with open(local, 'wb' if download else 'rb') as stream:
            result = subprocess.run(args, stdin=subprocess.DEVNULL if download else stream, stdout=stream if download else subprocess.DEVNULL, timeout=7200)
        if result.returncode:
            raise ValueError('Encrypted package transfer failed; no import was started')

    def disconnect(self):
        self.raw('migration-revoke')
        self.forget()
        print('[OK] Remote migration permission revoked and this connection\'s local key removed. Other SSH keys are unchanged.')

    def forget(self):
        for path in (self.key, self.key.with_name(self.key.name + '.pub')):
            if path.exists() or path.is_symlink():
                trusted(path)
                path.unlink()
        self.profile.unlink(missing_ok=True)


def profiles(storage=STATE / 'connections', role=None):
    if not Path(storage).exists():
        return []
    trusted(Path(storage), directory=True)
    result = []
    for path in sorted(Path(storage).glob('*/connection.json')):
        trusted(path.parent, directory=True)
        trusted(path)
        item = json.loads(path.read_text())
        if role is None or item['role'] == role:
            result.append(item)
    return result


def choose_remote(engine, direction):
    role = 'destination' if direction == 'push' else 'source'
    local = engine.identity()
    local_role = 'SOURCE A' if direction == 'push' else 'DESTINATION B'
    print(f'\nCLIENT / this VPS: {local["hostname"]} [{local_role}], ID {local["id"][:12]}')
    print('Select ' + server_role(role) + ': ' + ('provides original websites.' if role == 'source' else 'receives website copies.'))
    print('Website data: ' + ('A (this VPS) -> B (remote).' if direction == 'push' else 'A (remote) -> B (this VPS).'))
    storage = engine.state / 'connections'
    saved = profiles(storage, role)
    for index, item in enumerate(saved, 1):
        expiry = datetime.datetime.fromtimestamp(item['expires'], datetime.timezone.utc).strftime('%Y-%m-%d UTC')
        print(f'  {index}) {item["host"]}:{item["port"]} — {item["server"]["hostname"]} [{server_role(role)}], ID {item["server"]["id"][:12]} (key expires {expiry})')
    host = input(f'Choose {server_role(role)} number or enter its hostname/IP; Enter cancels: ').strip()
    if not host:
        return None
    if host.isdigit() and 1 <= int(host) <= len(saved):
        item = saved[int(host) - 1]
        return Remote(item['host'], item['port'], role=role, storage=storage)
    port = input('SSH port [22]: ').strip() or '22'
    if not port.isdigit():
        raise ValueError('Invalid SSH port')
    return Remote(host, int(port), role=role, storage=storage)


def manage(engine):
    print(f'\nCLIENT / this VPS: {engine.identity()["hostname"]}')
    print('  1) This VPS is A: pair SSH SERVER B / DESTINATION (send copies to B)')
    print('  2) This VPS is B: pair SSH SERVER A / SOURCE (read originals from A)')
    print('  3) Revoke a saved SSH server connection')
    choice = input('Choose; Enter cancels: ').strip()
    if choice in ('1', '2'):
        peer = choose_remote(engine, 'push' if choice == '1' else 'pull')
        if peer:
            peer.setup()
    elif choice == '3':
        saved = profiles(engine.state / 'connections')
        for index, item in enumerate(saved, 1):
            print(f'  {index}) {item["host"]}:{item["port"]} [{server_role(item["role"])}], {item["server"]["hostname"]}, ID {item["server"]["id"][:12]}')
        raw = input('Revoke which connection? Enter cancels: ').strip()
        if not raw:
            return
        if not raw.isdigit() or not 1 <= int(raw) <= len(saved):
            raise ValueError('Invalid connection number')
        item = saved[int(raw) - 1]
        if input(f'Revoke access to {server_role(item["role"])} at {item["host"]}:{item["port"]}? [y/N]: ').lower() == 'y':
            peer = Remote(item['host'], item['port'], role=item['role'], storage=engine.state / 'connections')
            try:
                peer.disconnect()
            except (OSError, ValueError, subprocess.SubprocessError):
                print('Remote revocation could not be confirmed. Run this in the remote root console:')
                print(shlex.join(['/usr/bin/python3', PROGRAM, 'revoke', item['fingerprint']]))
                if input('Remove only this local connection/key anyway? [y/N]: ').lower() == 'y':
                    peer.forget()
                    print('[OK] Local key removed. Remote permission was NOT confirmed revoked; it expires automatically.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('authorize', 'gateway', 'revoke'))
    parser.add_argument('value')
    parser.add_argument('role', nargs='?', choices=ROLES)
    parser.add_argument('--server-id')
    parser.add_argument('--exclude-id')
    parser.add_argument('--replace-grant')
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error('Migration pairing requires root')
    os.umask(0o077)
    if args.action == 'gateway':
        return gateway(args.value)
    if args.action == 'authorize':
        identity = hashlib.sha256(Path('/etc/machine-id').read_bytes().strip()).hexdigest()
        if identity == args.exclude_id or (args.server_id and identity != args.server_id):
            raise ValueError('Wrong VPS identity; no migration key was authorized')
    result = authorize(args.value, args.role) if args.action == 'authorize' else revoke(args.value)
    if args.action == 'authorize':
        if args.replace_grant and args.replace_grant != result['fingerprint']:
            revoke(args.replace_grant)
        expires = datetime.datetime.fromtimestamp(result['expires'], datetime.timezone.utc).strftime('%Y-%m-%d %H:%M UTC')
        print(f'[OK] Restricted {result["role"]} migration access expires {expires}.', file=sys.stderr)
        for public in sorted(Path('/etc/ssh').glob('ssh_host_*_key.pub')):
            print('SSH host fingerprint: ' + checked(['ssh-keygen', '-l', '-f', public]).decode().strip(), file=sys.stderr)
    print(json.dumps(result))
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print('[FAILED] ' + str(error), file=sys.stderr)
        raise SystemExit(1)
