#!/usr/bin/env python3
"""Exercise update selection and failure isolation without touching real sites."""
import os
from pathlib import Path
import subprocess
import tempfile

SCRIPT = Path(__file__).resolve().parents[1] / 'shieldpress/modules/wordpress/update-wp.sh'


def run(body, **extra):
    result = subprocess.run(
        ['bash', '-c', 'source "$UPDATE_SCRIPT"\nset -o pipefail\n' + body],
        env={**os.environ, 'UPDATE_SCRIPT': str(SCRIPT), **extra},
        capture_output=True, text=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout


MOCKS = r'''
load_site() {
    DOMAIN_PATH="$1"
    ROOT="$1/public_html"
    SELECTED_DOMAIN="${1##*/}"
}
wp() {
    printf '%s: %s\n' "$SELECTED_DOMAIN" "$*" >> "$COMMANDS"
    case "$*" in
        'plugin list '*)
            printf 'name,status\ncommon,active\n'
            case "$SELECTED_DOMAIN" in
                alpha) printf 'alpha-only,inactive\nmu-file,must-use\nobject-cache.php,dropin\n' ;;
                beta) printf 'beta-only,active-network\n' ;;
            esac
            ;;
        'core update') return "${CORE_FAIL:-0}" ;;
        'core update-db'*) return "${DB_FAIL:-0}" ;;
        'eval '*) printf '%s\n' "${MULTISITE:-no}" ;;
    esac
    return 0
}
backup_site() {
    echo "$SELECTED_DOMAIN: backup" >> "$COMMANDS"
    PRE_UPDATE_BACKUP="/backup/$SELECTED_DOMAIN"
    return "${BACKUP_FAIL:-0}"
}
purge_site_cache() { :; }
'''

with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    commands = root / 'commands'
    common = {'COMMANDS': str(commands)}

    # Discover only real WordPress installations, including legacy configs.
    for name, app, has_wp in [('alpha', 'wordpress', True), ('legacy', '', True),
                              ('laravel', 'laravel', True), ('empty', 'wordpress', False)]:
        site = root / 'domains' / name
        (site / 'config').mkdir(parents=True)
        (site / 'public_html').mkdir()
        (site / 'config/domain.env').write_text(f'DOMAIN={name}.test\nAPP_TYPE={app}\n')
        if has_wp:
            (site / 'public_html/wp-config.php').touch()
    run(r'''
DOMAINS_ROOT="$FIXTURE/domains"
find_sites
[[ "${SITE_NAMES[*]}" == 'alpha.test legacy.test' ]] || exit 1
choose_sites <<< $'2' || exit 1
[[ "${TARGET_PATHS[*]}" == "${SITE_PATHS[*]}" ]] || exit 1
choose_sites <<< $'1\n2' || exit 1
[[ "${TARGET_NAMES[*]}" == 'legacy.test' ]] || exit 1
! valid_number '0' 3 || exit 1
! valid_number '-1' 3 || exit 1
! valid_number '999999999999999999' 3 || exit 1
! valid_number 'x[$(touch /tmp/should-not-run)]' 3 || exit 1
''', FIXTURE=tmp)

    # The combined catalog excludes drop-ins/MU plugins; numbers are validated,
    # duplicate choices are collapsed, and cancellation cannot choose --all.
    run(MOCKS + r'''
ACTION=2
TARGET_PATHS=(alpha beta)
choose_plugins <<< $'2\n1,3,1' || exit 1
[[ "${PLUGIN_CATALOG[*]}" == 'common alpha-only beta-only' ]] || exit 1
[[ "$PLUGIN_MODE" == selected && "${SELECTED_PLUGINS[*]}" == 'common beta-only' ]] || exit 1
! choose_plugins <<< $'2\n-1' || exit 1
! choose_plugins <<< $'2\n0' || exit 1
''', **common)

    commands.write_text('')
    run(MOCKS + r'''
ACTION=2; PLUGIN_MODE=selected
SELECTED_PLUGINS=(common beta-only)
update_site alpha || exit 1
update_site beta || exit 1
''', **common)
    lines = commands.read_text().splitlines()
    assert 'alpha: plugin update common' in lines
    assert 'beta: plugin update common beta-only' in lines
    assert not any('--all' in line for line in lines)
    assert lines.index('alpha: backup') < lines.index('alpha: plugin update common')

    commands.write_text('')
    run(MOCKS + r'''
ACTION=4; PLUGIN_MODE=selected; SELECTED_PLUGINS=(common)
update_site alpha || exit 1
''', **common)
    text = commands.read_text()
    assert 'alpha: core update\n' in text
    assert 'alpha: core update-db\n' in text
    assert 'alpha: plugin update common\n' in text
    assert 'alpha: plugin update --all' not in text
    assert 'alpha: theme update --all' in text

    commands.write_text('')
    run(MOCKS + r'''
ACTION=2; PLUGIN_MODE=all; SELECTED_PLUGINS=()
update_site alpha || exit 1
''', **common)
    assert 'alpha: plugin update --all' in commands.read_text()

    commands.write_text('')
    output = run(MOCKS + r'''
ACTION=2; PLUGIN_MODE=selected; SELECTED_PLUGINS=(beta-only)
TARGET_PATHS=(alpha beta); LOG_FILE=/test/log
run_updates || exit 1
''', **common)
    assert '1 successful, 0 failed, 1 skipped' in output
    assert 'alpha: backup' not in commands.read_text()

    # A backup failure must prevent *every* mutating update command.
    commands.write_text('')
    run(MOCKS + r'''
ACTION=4; PLUGIN_MODE=all; SELECTED_PLUGINS=(); BACKUP_FAIL=1
! update_site alpha || exit 1
''', **common)
    assert not any(': core update' in line or ': plugin update' in line or ': theme update' in line
                   for line in commands.read_text().splitlines())

    # Core update runs a database migration; multisite uses --network.
    commands.write_text('')
    run(MOCKS + r'''
ACTION=1; PLUGIN_MODE=all; SELECTED_PLUGINS=(); MULTISITE=yes
update_site alpha || exit 1
DB_FAIL=1
! update_site beta || exit 1
CORE_FAIL=1
! update_site gamma || exit 1
''', **common)
    text = commands.read_text()
    assert 'alpha: core update-db --network' in text
    assert 'beta: core update-db --network' in text
    assert 'gamma: core update-db' not in text

    # Failure of one website does not stop successful/skip results afterwards.
    output = run(r'''
TARGET_PATHS=(bad good absent)
LOG_FILE=/test/log
update_site() {
    echo "visited $1"
    case "$1" in bad) return 1;; absent) return 2;; *) return 0;; esac
}
! run_updates || exit 1
''')
    assert all(f'visited {name}' in output for name in ('bad', 'good', 'absent'))
    assert '1 successful, 1 failed, 1 skipped' in output

    # Invalid official-download checksums must never reach installation.
    run(r'''
type() { echo "$FIXTURE/missing-wp"; }
PHP_BIN=/bin/true
curl() { printf 'invalid-download\n' > "${@: -1}"; }
install() { touch "$FIXTURE/should-not-install"; }
! ensure_wpcli || exit 1
[[ ! -e "$FIXTURE/should-not-install" ]] || exit 1
''', FIXTURE=tmp)

    # Exercise the real backup pipeline: a failed SQL export remains a failure
    # even when gzip succeeds. Successful archives contain full core + content.
    run(r'''
DOMAIN_PATH="$FIXTURE/backup-fixture"
ROOT="$DOMAIN_PATH/public_html"
SELECTED_DOMAIN=backup.test; ACTION=4; SELECTED_PLUGINS=()
mkdir -p "$ROOT/wp-content"
printf 'core data\n' > "$ROOT/wp-load.php"
printf 'plugin data\n' > "$ROOT/wp-content/plugin.php"
wp() { echo 'partial SQL'; return 1; }
! backup_site || exit 1
[[ ! -f "$PRE_UPDATE_BACKUP/wordpress.tar.gz" ]] || exit 1
wp() { echo 'complete SQL'; }
backup_site || exit 1
[[ "$(stat -c %a "$PRE_UPDATE_BACKUP")" == 700 ]] || exit 1
[[ "$(gzip -dc "$PRE_UPDATE_BACKUP/database.sql.gz")" == 'complete SQL' ]] || exit 1
tar -tzf "$PRE_UPDATE_BACKUP/wordpress.tar.gz" | grep -Fx './wp-load.php' || exit 1
tar -tzf "$PRE_UPDATE_BACKUP/wordpress.tar.gz" | grep -Fx './wp-content/plugin.php' || exit 1
''', FIXTURE=tmp)

print('WordPress update regression checks passed.')
