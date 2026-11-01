#!/bin/bash
# Unprivileged tests for Auto-Update settings, schedule rendering and quick commands.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/shieldpress"
FAIL=0
pass(){ echo "[PASS] $1"; }
fail(){ echo "[FAIL] $1"; FAIL=1; }
check(){ local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
export BASE_DIR="$SRC" ETC_DIR="$WORK/etc" DATA_DIR="$WORK/data"
mkdir -p "$ETC_DIR" "$DATA_DIR"
# shellcheck disable=SC1091
source "$SRC/core/autoupdate.sh"
AU_CRON_FILE="$WORK/cron"

au_load
check "defaults: off, daily 03:00" test "$AU_ENABLED$AU_FREQUENCY$AU_TIME" = "0daily03:00"
check "time normalizes 3:5" test "$(au_normalize_time 3:5)" = "03:05"
check "time rejects 24:00" bash -c "source '$SRC/core/autoupdate.sh'; ! au_normalize_time 24:00"
check "time rejects 12:60" bash -c "source '$SRC/core/autoupdate.sh'; ! au_normalize_time 12:60"

AU_ENABLED=1; AU_FREQUENCY=weekly; AU_TIME=04:30; AU_WEEKDAY=1
au_save && au_load
check "config round-trips" test "$AU_ENABLED$AU_FREQUENCY$AU_TIME$AU_WEEKDAY" = "1weekly04:301"
check "weekly cron fields" test "$(au_cron_fields)" = "30 4 * * 1"
AU_FREQUENCY=monthly; AU_MONTHDAY=15
check "monthly cron fields" test "$(au_cron_fields)" = "30 4 15 * *"
AU_FREQUENCY=daily
check "daily cron fields" test "$(au_cron_fields)" = "30 4 * * *"

systemctl(){ return 0; }
au_apply
check "enabled writes cron entry" grep -q "^30 4 \* \* \* root $AU_RUNNER" "$AU_CRON_FILE"
AU_ENABLED=0; au_apply
check "disabled removes cron entry" test ! -e "$AU_CRON_FILE"

printf 'AUTO_UPDATE_TIME="99:99"\nAUTO_UPDATE_FREQUENCY="hourly"\n$(touch %s/pwned)\n' "$WORK" > "$AU_CONF"
au_load
check "invalid config falls back to defaults" test "$AU_FREQUENCY$AU_TIME" = "daily03:00"
check "config is never executed" test ! -e "$WORK/pwned"

out=$(source "$SRC/core/quick-commands.sh"; sp_quick_commands_print)
for c in "shieldpress menu (1)" "shieldpress update (2)" "shieldpress cache (3)" "shieldpress domain (4)" "shieldpress ssl (5)" "shieldpress backup (6)" "shieldpress autoupdate"; do
    check "quick commands list: $c" grep -qF "$c" <<<"$out"
done

check "scripts have valid syntax" bash -c "for f in '$SRC/core/autoupdate.sh' '$SRC/core/quick-commands.sh' '$SRC/bin/shieldpress-autoupdate' '$SRC/modules/update/autoupdate-menu.sh'; do bash -n \"\$f\" || exit 1; done"
check "new files are English-only" bash -c "! grep -nP '[^\x00-\x7F]' '$SRC/core/autoupdate.sh' '$SRC/bin/shieldpress-autoupdate' '$SRC/modules/update/autoupdate-menu.sh' | grep -v '—' | grep ."

exit "$FAIL"
