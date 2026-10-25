#!/usr/bin/env python3
"""Pairing policy, scoped gateway, trust, idempotence and revocation regressions."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time
from unittest import mock

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('pair', ROOT / 'shieldpress/modules/tools/migration-ssh.py')
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)
os.umask(0o077)


def denied(action):
    try:
        action()
    except (OSError, ValueError):
        return
    raise AssertionError('Unsafe SSH operation accepted')


# Application errors and transport errors carry different operator guidance.
with mock.patch.object(s.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, b'', b'[FAILED] nginx configuration invalid\n')):
    try:
        s.checked(['ssh'])
    except ValueError as error:
        assert 'nginx configuration invalid' in str(error) and 'SSH connection failed' not in str(error)
    else:
        raise AssertionError('Remote failure was ignored')
with mock.patch.object(s.subprocess, 'run', return_value=subprocess.CompletedProcess([], 255, b'', b'')):
    try:
        s.checked(['ssh'])
    except ValueError as error:
        assert 'SSH connection failed' in str(error)
    else:
        raise AssertionError('SSH failure was ignored')
with mock.patch('builtins.input', side_effect=['COPY 1', 'no']):
    assert not s.confirm('Create destination?')
with mock.patch('builtins.input', return_value='Y'):
    assert s.confirm('Create destination?')
with mock.patch('builtins.input', return_value=''):
    assert not s.confirm('Create destination?')

with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    original_directory = s.private_directory
    s.private_directory = lambda path: original_directory(path, boundary=root)
    state, home = root / 'state', root / 'home'
    peer = s.Remote('destination.test', role='destination', storage=root / 'connections')
    encoded, fingerprint = peer.prepare()
    private = peer.key.read_bytes()
    assert peer.prepare() == (encoded, fingerprint)
    assert peer.key.read_bytes() == private
    assert peer.key.stat().st_mode & 0o777 == 0o600
    assert peer.folder.stat().st_mode & 0o777 == 0o700
    assert peer.key != s.Remote('destination.test', role='source', storage=root / 'connections').key
    assert peer.key != s.Remote('other.test', storage=root / 'connections').key
    grants, authorized = s.grant_paths(state, home)
    admin = 'ssh-ed25519 AAAA-administrator-key administrator\n'
    authorized.write_text(admin)
    permission = s.authorize(encoded, 'destination', state, home)
    s.authorize(encoded, 'destination', state, home)
    content = authorized.read_text()
    assert content.startswith(admin)
    assert content.count('shieldpress-migration-v2:') == 1
    assert 'restrict,command="/usr/bin/python3 ' in content
    assert fingerprint in content
    assert private not in content.encode()
    assert authorized.stat().st_mode & 0o777 == 0o600
    assert 6 * 86400 < permission['expires'] - time.time() <= 7 * 86400
    record = json.loads((grants / (fingerprint + '.json')).read_text())
    packages = state / 'packages'
    s.private_directory(packages)
    identity = shlex.join(['python3', s.ENGINE, 'identity'])
    assert s.gateway_request(identity, record, state=state) == ('rpc', ['identity'])
    assert s.gateway_request(shlex.join(['python3', s.ENGINE, 'verify', 'demo_test', '--tls']), record, state=state) == ('rpc', ['verify', 'demo_test', '--tls'])
    for command in ('id', 'bash', 'sftp', 'scp -t /etc', identity + '; reboot',
                    shlex.join(['python3', s.ENGINE, 'authorize', encoded, 'source']),
                    shlex.join(['python3', s.ENGINE, 'export', 'demo_test']),
                    'migration-download ' + str(packages / 'demo.spm.tar.gz'),
                    'migration-upload /etc/authorized_keys.partial',
                    'migration-upload ' + str(packages / '../outside.spm.tar.gz.partial')):
        denied(lambda command=command: s.gateway_request(command, record, state=state))
    upload = packages / 'upload.spm.tar.gz.partial'
    assert s.gateway_request('migration-upload ' + str(upload), record, state=state)[0] == 'upload'
    read_permission = {**record, 'role': 'source'}
    assert s.gateway_request(shlex.join(['python3', s.ENGINE, 'export', 'demo_test']), read_permission, state=state)[0] == 'rpc'
    denied(lambda: s.gateway_request('migration-upload ' + str(upload), read_permission, state=state))
    denied(lambda: s.gateway_request(shlex.join(['python3', s.ENGINE, 'import', str(packages / 'x.spm.tar.gz'), 'a'*64, 'b'*64]), read_permission, state=state))
    denied(lambda: s.gateway_request(identity, {**record, 'expires': 0}, state=state))
    assert s.gateway_request('migration-revoke', {**record, 'expires': 0}, state=state) == ('revoke', [])
    denied(lambda: s.gateway_request('migration-revoke ' + 'f'*64, record, state=state))
    # Managed grants cannot silently share an unrestricted administrator key.
    unrestricted = root / 'unrestricted'
    g2, a2 = s.grant_paths(unrestricted, root / 'other-home')
    a2.write_text(s.public_key(encoded)[0] + '\n')
    denied(lambda: s.authorize(encoded, 'destination', unrestricted, root / 'other-home'))
    # Never follow key/control-file links or fall back to another SSH identity.
    bad = s.Remote('bad.test', storage=root / 'connections')
    s.private_directory(bad.folder)
    bad.key.symlink_to(peer.key)
    denied(bad.prepare)
    missing = s.Remote('missing.test', storage=root / 'connections')
    with mock.patch.object(s, 'checked') as execute:
        denied(lambda: missing.raw(identity))
        execute.assert_not_called()
    # Server ID and managed-grant fingerprint are pinned independently of host-key checking.
    server = {'id': 'a'*64, 'hostname': 'destination', 'protocol': 2, 'migration_ssh': record}
    profile = {'host': peer.host, 'port': peer.port, 'role': peer.role, 'server': server,
               'fingerprint': fingerprint, 'expires': permission['expires']}
    s.atomic(peer.profile, json.dumps(profile).encode())
    with mock.patch.object(peer, 'raw', return_value=json.dumps(server).encode()):
        assert peer.call('identity')['id'] == 'a'*64
    with mock.patch.object(peer, 'raw', return_value=json.dumps({**server, 'id': 'b'*64}).encode()):
        denied(lambda: peer.call('identity'))
    with mock.patch.object(peer, 'raw', return_value=json.dumps({**server, 'migration_ssh': {**record, 'fingerprint': 'c'*64}}).encode()):
        denied(lambda: peer.call('identity'))
    engine = mock.Mock(state=root)
    engine.identity.return_value = {'hostname': 'local-client', 'id': 'd'*64}
    # Saved selection avoids hostname, port and key prompts.
    with mock.patch('builtins.input', return_value='1') as prompt:
        chosen = s.choose_remote(engine, 'push')
        assert chosen.host == peer.host and chosen.port == peer.port
        assert prompt.call_count == 1
    s.revoke(fingerprint, state, home)
    s.revoke(fingerprint, state, home)
    assert authorized.read_text() == admin
    assert not (grants / (fingerprint + '.json')).exists()
    unrelated = peer.folder / 'unrelated.txt'
    unrelated.write_text('retain')
    peer.forget()
    assert unrelated.read_text() == 'retain' and not peer.key.exists() and not peer.profile.exists()
print('PASS: per-peer/direction keys, private permissions, idempotent restricted authorization, preserved admin keys, command/path/direction restrictions, expiry, identity pinning, saved selection, revocation and no SSH identity fallback')
