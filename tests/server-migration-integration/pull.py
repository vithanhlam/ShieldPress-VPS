#!/usr/bin/env python3
"""Test successful selected-site pull and offline import against the same source."""
import importlib.util
from pathlib import Path
from unittest import mock
import os

spec = importlib.util.spec_from_file_location('migration', '/opt/shieldpress/modules/tools/server-migration.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
os.umask(0o077)
e = m.Engine()
e.initialize()
remote = m.Remote('migration-source', role='source')
remote.prepare()
m.shutil.copyfile('/root/.ssh/known_hosts', remote.known)
remote.setup(method='1')
sites = remote.call('inventory')['sites']
selection = ','.join(str(i) for i, row in enumerate(sites, 1) if row.get('app') in ('laravel', 'wordpress'))
answers = iter(['1', selection, 'y', 'y', 'y'])
with mock.patch('builtins.input', side_effect=lambda _: next(answers)):
    m.wizard(e, 'pull')
batch = m.read_json(next(e.reports.glob('batch-*.json')))
assert len(batch['results']) == 2 and all(row['status'] == 'COPIED_PENDING_CUTOVER' for row in batch['results']), batch
assert not (e.domains / 'nodejs_test').exists()
assert not (e.domains / 'php_test').exists()
# Fetch a package, then exercise the actual offline import menu with TLS validation.
exported = remote.call('export', 'php_test')
package = e.packages / Path(exported['package']).name
remote.transfer(package, exported['package'], download=True)
package.with_name(package.name + '.sha256').write_text(exported['sha256'] + '\n')
index = sorted(e.packages.glob('*.spm.tar.gz')).index(package) + 1
answers = iter(['4', str(index), 'y', '', '0'])
with mock.patch('builtins.input', side_effect=lambda _: next(answers)):
    m.menu(e)
assert e.verify('php_test', tls=True)['ready']
assert not (e.domains / 'nodejs_test').exists()
print('PASS: selected-site pull over SSH, unselected website exclusion, offline import menu and certificate-validated HTTPS')
