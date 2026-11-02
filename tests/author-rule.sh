#!/usr/bin/env bash
# Regression: the author-enumeration rule must not match post_author, and the
# migration must rewrite old rules idempotently and revert on nginx -t failure.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCHES="$ROOT/shieldpress/modules/patches/patches-menu.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail=0
check(){ if eval "$2"; then echo "[PASS] $1"; else echo "[FAIL] $1"; fail=1; fi; }

# Rule semantics (nginx uses PCRE; ERE is equivalent for this expression).
rule='(^|&)author='
for q in 'author=1' 'a=b&author=1'; do
    check "blocks $q" "printf '%s' '$q' | grep -Eqi '$rule'"
done
for q in 'post_author=-1' 'x=1&post_author=-1' 'coauthor=2'; do
    check "allows $q" "! printf '%s' '$q' | grep -Eqi '$rule'"
done

# Migration against mock configs with a fake nginx.
mkdir -p "$WORK/bin" "$WORK/snippets" "$WORK/conf.d"
printf '#!/bin/sh\n[ -f "%s/fail" ] && exit 1\nexit 0\n' "$WORK" > "$WORK/bin/nginx"; chmod +x "$WORK/bin/nginx"
printf '%s\n' 'location ~* /(\.|wp-config\.php|readme\.html|license\.txt) { deny all; }' \
    'if ($args ~* "author=") { return 403; }' > "$WORK/snippets/security-wp.conf"
printf '%s\n' 'server {' 'if ($args ~* "author=") { return 403; }' '}' > "$WORK/conf.d/a.conf"
cp "$WORK/conf.d/a.conf" "$WORK/a.orig"

run(){
    {
        echo 'patch_applied(){ return 1; }; patch_mark_done(){ :; }; ok(){ :; }; fail(){ echo "FAIL $*"; }; skip(){ :; }'
        sed -n '/^patch_20261102_author_rule_anchor(){/,/^}/p' "$PATCHES" |
            sed "s#/etc/nginx/snippets#$WORK/snippets#; s#/etc/nginx/conf.d#$WORK/conf.d#; s#systemctl reload nginx#true#"
        echo patch_20261102_author_rule_anchor
    } > "$WORK/run.sh"
    PATH="$WORK/bin:$PATH" bash "$WORK/run.sh"
}

touch "$WORK/fail"; run >/dev/null 2>&1; rc=$?
check "failing nginx -t reverts the config and reports pending" "[ $rc -ne 0 ] && cmp -s '$WORK/conf.d/a.conf' '$WORK/a.orig'"
rm -f "$WORK/fail"; run >/dev/null 2>&1
check "vhost rule anchored" "grep -Fq '(^|&)author=' '$WORK/conf.d/a.conf'"
check "snippet rule anchored" "grep -Fq '(^|&)author=' '$WORK/snippets/security-wp.conf'"
check "snippet keeps /.well-known/ reachable" "grep -Fq 'well-known/' '$WORK/snippets/security-wp.conf'"
cp "$WORK/snippets/security-wp.conf" "$WORK/once"; run >/dev/null 2>&1
check "second run changes nothing" "cmp -s '$WORK/once' '$WORK/snippets/security-wp.conf'"
exit $fail
