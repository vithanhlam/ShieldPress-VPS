#!/bin/bash
# Runtime checks use mocks; no system packages or repositories are changed.
set -euo pipefail
source "$(dirname "$0")/../shieldpress/modules/helpers/nodejs-runtime.sh"
node(){ printf '%s\n' "$TEST_CURRENT"; }
dnf(){
    if [[ "$*" == *repoquery* ]]; then
        [ "${TEST_QUERY_FAIL:-0}" = 0 ] || return 1
        printf '%s\n' "$TEST_AVAILABLE"
    else
        echo 'Unexpected package mutation' >&2
        return 99
    fi
}
TEST_CURRENT=26.7.0
TEST_AVAILABLE=22.23.4
output=$(check_shieldpress_nodejs)
[[ "$output" == *'Automatic downgrade is blocked'* ]]
if install_shieldpress_nodejs; then
    echo 'FAIL: accepted downgrade' >&2
    exit 1
fi
# Repeat execution must also stop before setup, locks, or DNF mutations.
if install_shieldpress_nodejs; then exit 1; fi
TEST_CURRENT=22.23.3
output=$(check_shieldpress_nodejs)
[[ "$output" == *'A newer repository version is available'* ]]
TEST_CURRENT=22.23.4
output=$(check_shieldpress_nodejs)
[[ "$output" == *'Already running the latest version'* ]]
TEST_AVAILABLE=22.9.0
output=$(check_shieldpress_nodejs)
[[ "$output" == *'Automatic downgrade is blocked'* ]]
TEST_QUERY_FAIL=1
if check_shieldpress_nodejs; then exit 1; fi
unset TEST_QUERY_FAIL
TEST_CURRENT=''
output=$(check_shieldpress_nodejs)
[[ "$output" == *'Not installed'* ]]
shieldpress_nodejs_newer 22.23.4 22.9.0
if shieldpress_nodejs_newer 22.9.0 22.23.4; then exit 1; fi
if shieldpress_nodejs_newer invalid 22.23.4; then exit 1; fi
echo '[PASS] Node.js runtime checks and downgrade protection'
