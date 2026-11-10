#!/bin/bash
# Exercise the complete menu handoff without modifying the host runtime.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/shieldpress/modules/helpers/nodejs-runtime.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
BASE_DIR="$TEST_DIR/base"
mkdir -p "$BASE_DIR/modules/upgrade"
touch "$BASE_DIR/modules/upgrade/package-lock.sh"
STATE="$TEST_DIR/version" CALLS="$TEST_DIR/calls"
shieldpress_nodejs_runtime_lock(){ [[ ${BUSY:-0} == 0 ]]; }
node(){ cat "$STATE"; }
npm(){ echo 11.0.0; }
rpm(){ cat "$STATE"; }
uname(){ echo x86_64; }
bash(){
    if [[ "$1" == */package-lock.sh ]]; then
        echo "$2 $3" >> "$CALLS"
        [[ ${LOCK_FAIL:-0} == 0 ]]
    else
        command bash "$@"
    fi
}
run_with_loading(){ shift 3; "$@"; }
shieldpress_nodejs_save_major_repo(){ echo "save-repo $1 $2" >> "$CALLS"; [[ ${SAVE_FAIL:-0} == 0 ]]; }
dnf(){
    if [[ "$*" == *repoquery* ]]; then
        [[ ${QUERY_FAIL:-0} == 0 ]] || return 1
        printf '%s\n' "${AVAILABLE:-$'24.22.2\n26.13.0\n27.1.0'}"
    else
        echo "$*" >> "$CALLS"
        [[ ${UPDATE_FAIL:-0} == 0 ]] || return "$UPDATE_FAIL"
        printf '%s\n' "${RESULT:-26.13.0}" > "$STATE"
    fi
}
reset_case(){ echo 22.23.4 > "$STATE"; : > "$CALLS"; }
reset_case
upgrade_shieldpress_nodejs_major 26 <<< YES
grep -q 'install -y nodejs-26.13.0-\*' "$CALLS"
grep -q 'pub_26.x/nodistro/nodejs/x86_64' "$CALLS"
grep -q 'gpgcheck=1' "$CALLS"
[[ $(tail -3 "$CALLS") == $'unlock nodejs\nlock nodejs\nsave-repo 26 x86_64' ]]
! grep -qE 'allowerasing|systemctl|pm2|npm@latest' "$CALLS"
: > "$CALLS"
if upgrade_shieldpress_nodejs_major 26 <<< YES; then exit 1; fi
if upgrade_shieldpress_nodejs_major 24 <<< YES; then exit 1; fi
[[ ! -s $CALLS ]]
reset_case
upgrade_shieldpress_nodejs_major 26 <<< NO
[[ ! -s $CALLS && $(cat "$STATE") == 22.23.4 ]]
BUSY=1
if upgrade_shieldpress_nodejs_major 26 <<< YES; then exit 1; fi
unset BUSY
[[ ! -s $CALLS ]]
if upgrade_shieldpress_nodejs_major 27 <<< YES; then exit 1; fi
[[ ! -s $CALLS ]]
echo invalid > "$STATE"
if upgrade_shieldpress_nodejs_major 26 <<< YES; then exit 1; fi
[[ ! -s $CALLS ]]
reset_case
rpm(){ echo 20.0.0; }
if upgrade_shieldpress_nodejs_major 26 <<< YES; then exit 1; fi
[[ ! -s $CALLS ]]
rpm(){ cat "$STATE"; }
QUERY_FAIL=1
if upgrade_shieldpress_nodejs_major 26 <<< YES; then exit 1; fi
unset QUERY_FAIL
[[ ! -s $CALLS ]]
AVAILABLE=27.1.0
if upgrade_shieldpress_nodejs_major 26 <<< YES; then exit 1; fi
unset AVAILABLE
[[ ! -s $CALLS ]]
UPDATE_FAIL=42
status=0
upgrade_shieldpress_nodejs_major 26 <<< YES || status=$?
[[ $status == 42 && $(tail -2 "$CALLS") == $'unlock nodejs\nlock nodejs' ]]
! grep -q save-repo "$CALLS"
unset UPDATE_FAIL
reset_case
RESULT=27.1.0
if upgrade_shieldpress_nodejs_major 26 <<< YES; then exit 1; fi
! grep -q save-repo "$CALLS"
unset RESULT
reset_case
LOCK_FAIL=1
if upgrade_shieldpress_nodejs_major 26 <<< YES; then exit 1; fi
! grep -q save-repo "$CALLS"
unset LOCK_FAIL
reset_case
SAVE_FAIL=1
if upgrade_shieldpress_nodejs_major 26 <<< YES; then exit 1; fi
[[ $(cat "$STATE") == 26.13.0 ]]
unset SAVE_FAIL
reset_case
RESULT=24.22.2
upgrade_shieldpress_nodejs_major 24 <<< YES
grep -q 'save-repo 24 x86_64' "$CALLS"
unset RESULT
# Menu stays accessible even when the old repository check fails.
check_shieldpress_nodejs(){ return 1; }
reset_case
nodejs_runtime_manager <<< $'4\n2\nYES'
[[ $(cat "$STATE") == 26.13.0 ]]
echo '[PASS] Major upgrade menu, branch selection, cancellation, failures, locks and downgrade guards'
