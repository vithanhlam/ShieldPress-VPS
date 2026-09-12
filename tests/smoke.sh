#!/bin/bash
# Smoke tests for ShieldPress VPS repository layout and script syntax.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; FAIL=1; }

require_file() {
    if [ -f "$1" ]; then
        pass "exists: ${1#$ROOT/}"
    else
        fail "missing: ${1#$ROOT/}"
    fi
}

require_dir() {
    if [ -d "$1" ]; then
        pass "exists: ${1#$ROOT/}/"
    else
        fail "missing: ${1#$ROOT/}/"
    fi
}

echo "== ShieldPress VPS smoke tests =="
echo "Root: $ROOT"
echo

require_file "$ROOT/README.md"
require_file "$ROOT/CHANGELOG.md"
require_file "$ROOT/LICENSE"
require_file "$ROOT/SECURITY.md"
require_file "$ROOT/install.sh"
require_file "$ROOT/shieldpress/shieldpress.sh"
require_file "$ROOT/shieldpress/install.sh"
require_file "$ROOT/shieldpress/version.txt"
require_file "$ROOT/shieldpress/core/update-source.sh"
require_file "$ROOT/shieldpress/bin/laravel-pg-backup"
require_dir  "$ROOT/shieldpress/core"
require_dir  "$ROOT/shieldpress/modules"
require_dir  "$ROOT/tests"

if [ -f "$ROOT/LICENSE" ] \
    && grep -q "All Rights Reserved" "$ROOT/LICENSE" \
    && grep -q "ShieldPress Source-Available Software License" "$ROOT/LICENSE"; then
    pass "LICENSE is source-available"
else
    fail "source-available LICENSE is missing or invalid"
fi

if grep -qi 'Co-authored-by:' "$ROOT"/README.md "$ROOT"/SECURITY.md 2>/dev/null; then
    fail "docs contain co-author attribution"
else
    pass "docs contain no co-author attribution"
fi

if grep -q 'previous_next="\.next.deploy-backup\.\$\$"' "$ROOT/shieldpress/modules/nodejs/nodejs-menu.sh" \
    && grep -q 'Previous \.next build restored' "$ROOT/shieldpress/modules/nodejs/nodejs-menu.sh"; then
    pass "Node.js deploy restores previous Next.js build on failure"
else
    fail "Node.js deploy rollback protection is missing"
fi

if grep -q 'proxy_hide_header Cache-Control' "$ROOT/shieldpress/modules/domain/helpers.sh" \
    && grep -q 'location \^~ /_next/static/' "$ROOT/shieldpress/modules/domain/helpers.sh"; then
    pass "Node.js Nginx cache policy protects Next.js deployments"
else
    fail "Node.js Nginx cache policy is missing"
fi

PACKAGE_TEST_DIR=$(mktemp -d)
trap 'rm -rf "$PACKAGE_TEST_DIR"' EXIT
tar -czf "$PACKAGE_TEST_DIR/shieldpress.tar.gz" -C "$ROOT" .
tar -tzf "$PACKAGE_TEST_DIR/shieldpress.tar.gz" > "$PACKAGE_TEST_DIR/package.list"
if grep -qE '(^|/)shieldpress/modules/nodejs/nodejs-menu\.sh$' "$PACKAGE_TEST_DIR/package.list" \
    && grep -qE '(^|/)shieldpress/modules/domain/helpers\.sh$' "$PACKAGE_TEST_DIR/package.list"; then
    pass "release package contains Node.js deploy fixes"
else
    fail "release package does not contain Node.js deploy fixes"
fi

if (
    # shellcheck disable=SC1091
    source "$ROOT/shieldpress/core/update-source.sh" 2>/dev/null \
        && [ -n "$SHIELDPRESS_VERSION_URL" ] \
        && sp_package_urls "1.0.0" | grep -q '^https://github.com/'
); then
    pass "update source resolves to GitHub"
else
    fail "update source does not resolve to GitHub"
fi

echo
echo "== bash -n syntax checks =="
while IFS= read -r -d '' script; do
    if bash -n "$script"; then
        pass "syntax: ${script#$ROOT/}"
    else
        fail "syntax: ${script#$ROOT/}"
    fi
done < <(find "$ROOT/shieldpress" "$ROOT/install.sh" "$ROOT/tests" -type f \( -name '*.sh' -o -name 'process-purge-signals' -o -name 'purge-fastcgi-cache' -o -name 'laravel-pg-backup' \) -print0 | sort -z)

echo
if [ "$FAIL" -ne 0 ]; then
    echo "Smoke tests failed."
    exit 1
fi

echo "All smoke tests passed."
