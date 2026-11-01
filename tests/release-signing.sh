#!/bin/bash
# Unprivileged tests for release signature verification and the signing helper.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/shieldpress"
FAIL=0
pass(){ echo "[PASS] $1"; }
fail(){ echo "[FAIL] $1"; FAIL=1; }
check(){ local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
rc_is(){ local want="$1"; shift; "$@"; [ "$?" -eq "$want" ]; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/etc/keys" "$WORK/tree/keys" "$WORK/other"

# Maintainer key (unencrypted for the test) and an attacker key.
openssl genpkey -algorithm ED25519 -out "$WORK/good.key" 2>/dev/null
openssl pkey -in "$WORK/good.key" -pubout -out "$WORK/good.pem"
openssl genpkey -algorithm ED25519 -out "$WORK/evil.key" 2>/dev/null
openssl pkey -in "$WORK/evil.key" -pubout -out "$WORK/evil.pem"
cp "$WORK/good.pem" "$WORK/tree/keys/release-good.pem"

export SHIELDPRESS_RELEASE_KEYS_DIR="$WORK/etc/keys" SHIELDPRESS_TREE_KEYS_DIR="$WORK/tree/keys"
# shellcheck disable=SC1091
source "$SRC/core/release-verify.sh"

printf 'package v1' > "$WORK/pkg.tar.gz"
SHA=$(sha256sum "$WORK/pkg.tar.gz" | awk '{print $1}')
sign(){ # key version sha out-prefix
    printf 'shieldpress-release\nversion=%s\nsha256=%s\n' "$2" "$3" > "$4.manifest"
    openssl pkeyutl -sign -inkey "$1" -rawin -in "$4.manifest" -out "$4.sig"
}
sign "$WORK/good.key" 1.3.134 "$SHA" "$WORK/ok"

check "no key installed yet" test "$(sp_release_key_count)" = "0"
check "valid signature is accepted (key bootstrapped from installed tree)" \
    sp_verify_release "$WORK/pkg.tar.gz" 1.3.134 "$WORK/ok.manifest" "$WORK/ok.sig"
check "key was copied to the trusted directory" test "$(sp_release_key_count)" = "1"

check "tampered package is rejected" bash -c "
    source '$SRC/core/release-verify.sh'; printf 'package v1 + malware' > '$WORK/bad.tar.gz'
    sp_verify_release '$WORK/bad.tar.gz' 1.3.134 '$WORK/ok.manifest' '$WORK/ok.sig'; [ \$? -eq 5 ]"

sign "$WORK/evil.key" 1.3.134 "$SHA" "$WORK/evil"
check "signature from another key is rejected" bash -c "
    source '$SRC/core/release-verify.sh'
    sp_verify_release '$WORK/pkg.tar.gz' 1.3.134 '$WORK/evil.manifest' '$WORK/evil.sig'; [ \$? -eq 4 ]"

check "missing signature is rejected" bash -c "
    source '$SRC/core/release-verify.sh'
    sp_verify_release '$WORK/pkg.tar.gz' 1.3.134 '$WORK/ok.manifest' '$WORK/does-not-exist.sig'; [ \$? -eq 3 ]"

check "valid signature for a different version is rejected (replay)" bash -c "
    source '$SRC/core/release-verify.sh'
    sp_verify_release '$WORK/pkg.tar.gz' 1.3.200 '$WORK/ok.manifest' '$WORK/ok.sig'; [ \$? -eq 5 ]"

check "edited manifest breaks the signature" bash -c "
    source '$SRC/core/release-verify.sh'
    sed 's/1.3.134/1.3.999/' '$WORK/ok.manifest' > '$WORK/edit.manifest'
    sp_verify_release '$WORK/pkg.tar.gz' 1.3.999 '$WORK/edit.manifest' '$WORK/ok.sig'; [ \$? -eq 4 ]"

check "no trusted key means refusal" bash -c "
    export SHIELDPRESS_RELEASE_KEYS_DIR='$WORK/empty-etc' SHIELDPRESS_TREE_KEYS_DIR='$WORK/empty-tree'
    source '$SRC/core/release-verify.sh'
    sp_verify_release '$WORK/pkg.tar.gz' 1.3.134 '$WORK/ok.manifest' '$WORK/ok.sig'; [ \$? -eq 2 ]"

# Key rotation: a new key shipped by a verified package is added, never replaced.
cp "$WORK/evil.pem" "$WORK/tree/keys/release-next.pem"
echo "tampered" > "$WORK/tree/keys/release-good.pem.bad"
sp_release_keys_sync
check "rotation adds the new key" test "$(sp_release_key_count)" = "2"
echo "not a key" > "$WORK/tree/keys/release-junk.pem"
sp_release_keys_sync
check "invalid key files are ignored" test "$(sp_release_key_count)" = "2"
check "existing key is not overwritten" cmp -s "$WORK/good.pem" "$SHIELDPRESS_RELEASE_KEYS_DIR/release-good.pem"

# Repository wiring.
check "updater verifies the signature before extraction" bash -c "
    v=\$(grep -n 'sp_verify_release shieldpress.tar.gz' '$SRC/modules/update/updater.sh' | head -1 | cut -d: -f1)
    x=\$(grep -n 'tar --no-same-owner -xzf shieldpress.tar.gz' '$SRC/modules/update/updater.sh' | head -1 | cut -d: -f1)
    [ -n \"\$v\" ] && [ -n \"\$x\" ] && [ \"\$v\" -lt \"\$x\" ]"
check "updater refuses downgrades" grep -q 'Refusing to downgrade' "$SRC/modules/update/updater.sh"
check "updater still verifies checksums" grep -q 'Integrity verified' "$SRC/modules/update/updater.sh"
check "bootstrap installer verifies the signature" grep -q 'Release signature verified' "$ROOT/install.sh"
check "scripts have valid syntax" bash -c "for f in '$SRC/core/release-verify.sh' '$ROOT/tools/sign-release.sh' '$SRC/modules/update/updater.sh' '$ROOT/install.sh'; do bash -n \"\$f\" || exit 1; done"
check "private key patterns are ignored by git" bash -c "cd '$ROOT' && git check-ignore -q release.key"

exit "$FAIL"
