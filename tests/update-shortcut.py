#!/usr/bin/env python3
"""Verify numeric update dispatch and repair from newly installed source."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as directory:
    temp = Path(directory)
    (temp / 'usr/bin').mkdir(parents=True)
    (temp / 'usr/local/bin').mkdir(parents=True)
    base = temp / 'opt/shieldpress'
    (base / 'core').mkdir(parents=True)
    runner = base / 'shieldpress.sh'
    runner.write_text('#!/bin/bash\nprintf "%s\\n" "$@"\nexit 7\n')
    runner.chmod(0o755)
    helper = (ROOT / 'shieldpress/core/update-shortcut.sh').read_text()
    helper = helper.replace('/usr/bin/2', str(temp / 'usr/bin/2')).replace('/usr/local/bin/2', str(temp / 'usr/local/bin/2'))
    helper = helper.replace('/opt/shieldpress', str(base))
    (base / 'core/update-shortcut.sh').write_text(helper)
    patches = (ROOT / 'shieldpress/modules/patches/patches-menu.sh').read_text()
    hook = patches.split('    # The running updater may be from the previous release.')[1].split('    patch_recover_backup_config')[0]
    hook = '# Old updater handoff.' + hook
    harness = f'BASE_DIR="{base}"\nssl_status=0\nok(){{ :; }}\nfail(){{ :; }}\nrestorecon(){{ return 0; }}\n' + hook + '\nexit "$ssl_status"\n'
    # Simulate first upgrade executed by an old updater, then repeated repair.
    for _ in range(2):
        subprocess.run(['bash', '-c', harness], check=True)
        for path in [temp / 'usr/bin/2', temp / 'usr/local/bin/2']:
            assert os.access(path, os.X_OK)
            result = subprocess.run([str(path), '--test-argument'], capture_output=True, text=True)
            assert result.returncode == 7
            assert result.stdout == 'update\n--test-argument\n'
    # A failed repair stays pending instead of being marked complete.
    (base / 'core/update-shortcut.sh').write_text('sp_install_update_shortcut(){ return 1; }\n')
    assert subprocess.run(['bash', '-c', harness]).returncode == 1
    installer = (ROOT / 'shieldpress/install.sh').read_text()
    updater = (ROOT / 'shieldpress/modules/update/updater.sh').read_text()
    for source in [installer, updater]:
        assert 'source "$BASE_DIR/core/update-shortcut.sh"' in source
        assert 'sp_install_update_shortcut ||' in source
    assert 'for NUM in 3 4 5 6' in installer
print('[PASS] Update shortcut dispatch, arguments, exit status, old-updater handoff, repeat repair and pending failure')
