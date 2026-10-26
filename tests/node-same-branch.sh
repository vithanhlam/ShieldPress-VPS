#!/bin/bash
# Mock all package operations; no host runtime or repository is changed.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/shieldpress/modules/helpers/nodejs-runtime.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
BASE_DIR="$TEST_DIR/base"
mkdir -p "$BASE_DIR/modules/upgrade" "$BASE_DIR/modules/helpers"
touch "$BASE_DIR/modules/upgrade/package-lock.sh"
STATE="$TEST_DIR/version"
CALLS="$TEST_DIR/calls"
node(){ cat "$STATE"; }
npm(){ echo 11.0.0; }
bash(){
    if [[ "$1" == */package-lock.sh ]]; then
        echo "$2 $3" >> "$CALLS"
        return "${LOCK_FAIL:-0}"
    fi
    command bash "$@"
}
run_with_loading(){ shift 3; "$@"; }
dnf(){
    if [[ "$*" == *repoquery* ]]; then
        [ "${QUERY_FAIL:-0}" = 0 ] || return 1
        printf '%s\n' "$AVAILABLE"
    else
        echo "$*" >> "$CALLS"
        [ "${UPDATE_FAIL:-0}" = 0 ] || return "$UPDATE_FAIL"
        printf '%s\n' "${RESULT:-26.12.1}" > "$STATE"
    fi
}
reset_case(){ printf '%s\n' 26.5.0 > "$STATE"; : > "$CALLS"; }
AVAILABLE=$'22.23.4\n26.9.0\n26.12.1\n27.1.0\ninvalid'
reset_case
update_shieldpress_nodejs_current_branch <<< y
grep -q 'upgrade -y nodejs-26.12.1-\*' "$CALLS"
[[ "$(tail -2 "$CALLS")" == $'unlock nodejs\nlock nodejs' ]]
[[ "$(cat "$STATE")" == 26.12.1 ]]
: > "$CALLS"
update_shieldpress_nodejs_current_branch <<< y
[[ ! -s "$CALLS" ]]
reset_case
update_shieldpress_nodejs_current_branch <<< n
[[ ! -s "$CALLS" ]]
QUERY_FAIL=1
if update_shieldpress_nodejs_current_branch <<< y; then exit 1; fi
unset QUERY_FAIL
[[ ! -s "$CALLS" ]]
AVAILABLE=27.1.0
if update_shieldpress_nodejs_current_branch <<< y; then exit 1; fi
[[ ! -s "$CALLS" ]]
AVAILABLE=26.4.0
update_shieldpress_nodejs_current_branch <<< y
[[ ! -s "$CALLS" ]]
AVAILABLE=26.12.1
UPDATE_FAIL=42
status=0
update_shieldpress_nodejs_current_branch <<< y || status=$?
[[ "$status" == 42 ]]
[[ "$(tail -2 "$CALLS")" == $'unlock nodejs\nlock nodejs' ]]
unset UPDATE_FAIL
reset_case
RESULT=27.0.0
if update_shieldpress_nodejs_current_branch <<< y; then exit 1; fi
unset RESULT
reset_case
printf '22.23.3\n' > "$STATE"
AVAILABLE=$'22.23.4\n26.12.1'
RESULT=22.23.4
update_shieldpress_nodejs_current_branch <<< y
grep -q 'upgrade -y nodejs-22.23.4-\*' "$CALLS"
unset RESULT
AVAILABLE=26.12.1
reset_case
LOCK_FAIL=1
if update_shieldpress_nodejs_current_branch <<< y; then exit 1; fi
unset LOCK_FAIL
reset_case
printf 'unknown\n' > "$STATE"
if update_shieldpress_nodejs_current_branch <<< y; then exit 1; fi
[[ ! -s "$CALLS" ]]
# Test handoff from old installed source, pending failures and repeat migration.
eval "$(sed -n '/^patch_nodejs_same_branch_updates(){/,/^}/p' "$ROOT/shieldpress/modules/patches/patches-menu.sh")"
REGISTRY="$TEST_DIR/registry"
touch "$REGISTRY"
patch_applied(){ grep -qxF "$1" "$REGISTRY"; }
patch_mark_done(){ echo "$1" >> "$REGISTRY"; }
ok(){ echo "[OK] $1"; }
fail(){ echo "[FAIL] $1"; }
printf '#!/bin/bash\n' > "$BASE_DIR/modules/helpers/nodejs-runtime.sh"
if patch_nodejs_same_branch_updates; then exit 1; fi
[[ ! -s "$REGISTRY" ]]
cp "$ROOT/shieldpress/modules/helpers/nodejs-runtime.sh" "$BASE_DIR/modules/helpers/nodejs-runtime.sh"
patch_nodejs_same_branch_updates
patch_nodejs_same_branch_updates
[[ "$(wc -l < "$REGISTRY")" == 1 ]]
[[ ! -s "$CALLS" ]]
echo '[PASS] Same-branch updates, failure handling and migration handoff'
