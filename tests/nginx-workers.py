#!/usr/bin/env python3
"""Regression checks for large-host allocation and upgrade rollback."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('workers', ROOT / 'shieldpress/modules/helpers/nginx-workers.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
legacy = 'worker_processes auto;\nevents {\n    worker_connections 786432;\n}\nhttp { include conf.d/*.conf; }\n'
for cpu, workers, connections in [(1, 1, 4096), (2, 2, 8192), (4, 4, 16384), (16, 16, 16384), (192, 16, 16384)]:
    result = m.tune(legacy, cpu)
    assert f'worker_processes {workers};' in result
    assert f'worker_connections {connections};' in result
    assert 'http { include conf.d/*.conf; }' in result
    assert m.tune(result, cpu) == result
small = legacy.replace('auto', '2').replace('786432', '1024')
assert m.tune(small, 192, True) == small
with tempfile.TemporaryDirectory() as directory:
    config = Path(directory) / 'nginx.conf'
    config.write_text(legacy)
    with patch.object(m.subprocess, 'run') as run:
        m.apply(config, 192, True, True)
        assert run.call_count == 2
        m.apply(config, 192, True, True)
        assert run.call_count == 2
    for failure in ('test', 'reload'):
        config.write_text(legacy)
        effects = [subprocess.CalledProcessError(1, 'nginx')] if failure == 'test' else [None, subprocess.CalledProcessError(1, 'systemctl')]
        with patch.object(m.subprocess, 'run', side_effect=effects):
            try:
                m.apply(config, 192, True, True)
            except subprocess.CalledProcessError:
                pass
            else:
                raise AssertionError('Failure must propagate for migration retry')
        assert config.read_text() == legacy
# An old updater invokes the newly installed patches script with --auto.
patches = (ROOT / 'shieldpress/modules/patches/patches-menu.sh').read_text()
function = 'patch_nginx_worker_limits(){' + patches.split('patch_nginx_worker_limits(){', 1)[1].split('\n}\n', 1)[0] + '\n}\n'
subprocess.run(['bash', '-c', '''
BASE_DIR=/opt/shieldpress
ready=0; marked=0; calls=0
patch_applied(){ [ "$marked" = 1 ]; }
patch_mark_done(){ marked=1; }
info(){ :; }; ok(){ :; }; fail(){ :; }; skip(){ :; }
python3(){ calls=$((calls+1)); [ "$2" = --clamp ] && [ "$3" = --reload ] && [ "$ready" = 1 ]; }
''' + function.replace('[ ! -f /etc/nginx/nginx.conf ]', '[ 1 = 0 ]') + '''
if patch_nginx_worker_limits; then exit 1; fi
[ "$marked" = 0 ] || exit 2
ready=1
patch_nginx_worker_limits || exit 3
patch_nginx_worker_limits || exit 4
[ "$calls" = 2 ] && [ "$marked" = 1 ]
'''], check=True)
assert '    patch_nginx_worker_limits || ssl_status=$?' in patches
print('PASS: CPU limits, custom limits, idempotence, validation/reload rollback and migration retry')
