#!/bin/bash
# =====================================================
# ShieldPress VPS - release signing (run on the maintainer's own machine)
#
#   tools/sign-release.sh keygen            create the signing key (once)
#   tools/sign-release.sh sign <version>    sign the published release v<version>
#   tools/sign-release.sh verify <version>  check a published release like a server does
#   tools/sign-release.sh fingerprint       show the public key fingerprint
#
# The private key never leaves ${SHIELDPRESS_SIGNING_DIR:-~/.shieldpress-signing}.
# Never run this in CI and never commit the private key.
# =====================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYS_DIR="$REPO_ROOT/shieldpress/core/release-keys"
BOOTSTRAP="$REPO_ROOT/install.sh"
GITHUB_REPO="${SHIELDPRESS_GITHUB_REPO:-vithanhlam/ShieldPress-VPS}"
SIGN_DIR="${SHIELDPRESS_SIGNING_DIR:-$HOME/.shieldpress-signing}"
PRIVATE_KEY="$SIGN_DIR/release.key"
WORK=""

die(){ echo "[ERROR] $*" >&2; exit 1; }
cleanup(){ [ -z "$WORK" ] || rm -rf "$WORK"; }
trap cleanup EXIT

need(){ command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }
need openssl

pub_fingerprint(){
    openssl pkey -pubin -in "$1" -outform DER 2>/dev/null | sha256sum | awk '{print $1}'
}

cmd_keygen(){
    [ ! -e "$PRIVATE_KEY" ] || die "A signing key already exists at $PRIVATE_KEY. Refusing to overwrite it."
    { : </dev/tty; } 2>/dev/null \
        || die "No terminal available for the passphrase prompt. Run this in a normal terminal window, not through a tool or pipe."
    mkdir -p "$SIGN_DIR" && chmod 700 "$SIGN_DIR"
    echo "Choose a strong passphrase for the private key. It is asked on every signing."
    if ! openssl genpkey -algorithm ED25519 -aes-256-cbc -out "$PRIVATE_KEY"; then
        rm -f "$PRIVATE_KEY"
        die "Key generation failed; no key was created"
    fi
    chmod 600 "$PRIVATE_KEY"

    local pub fp name
    pub=$(mktemp); openssl pkey -in "$PRIVATE_KEY" -pubout -out "$pub"
    fp=$(pub_fingerprint "$pub")
    name="release-${fp:0:16}.pem"
    mkdir -p "$KEYS_DIR"
    install -m 644 "$pub" "$KEYS_DIR/$name"; rm -f "$pub"
    embed_bootstrap_key "$KEYS_DIR/$name"

    echo ""
    echo "[OK] Private key : $PRIVATE_KEY   (BACK IT UP offline, in two places)"
    echo "[OK] Public key  : $KEYS_DIR/$name"
    echo "[OK] Embedded in : $BOOTSTRAP"
    echo "     Fingerprint : $fp"
    echo "Commit the public key and install.sh, then publish a release and run: tools/sign-release.sh sign <version>"
}

# Put the public key between the markers in the bootstrap installer.
embed_bootstrap_key(){
    local key="$1" tmp
    tmp=$(mktemp)
    awk -v keyfile="$key" '
        /^# BEGIN RELEASE PUBLIC KEY/ { print; while ((getline line < keyfile) > 0) print line; skipping=1; next }
        /^# END RELEASE PUBLIC KEY/ { skipping=0 }
        !skipping { print }
    ' "$BOOTSTRAP" > "$tmp"
    cat "$tmp" > "$BOOTSTRAP"; rm -f "$tmp"
}

cmd_fingerprint(){
    local f
    for f in "$KEYS_DIR"/*.pem; do
        [ -f "$f" ] && echo "$(basename "$f")  $(pub_fingerprint "$f")"
    done
}

download_release(){
    local version="$1"
    need gh; need git
    WORK=$(mktemp -d)
    gh release download "v$version" --repo "$GITHUB_REPO" --dir "$WORK" \
        -p shieldpress.tar.gz -p shieldpress.sha256 >/dev/null \
        || die "Cannot download release v$version. Has the release workflow finished?"
}

cmd_sign(){
    local version="${1:-}" want actual
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Usage: sign <version>, for example 1.3.134"
    [ -f "$PRIVATE_KEY" ] || die "No signing key. Run: tools/sign-release.sh keygen"
    download_release "$version"

    actual=$(sha256sum "$WORK/shieldpress.tar.gz" | awk '{print $1}')
    want=$(awk 'NF {print $1; exit}' "$WORK/shieldpress.sha256")
    [ "$actual" = "$want" ] || die "Downloaded package does not match shieldpress.sha256"

    # The package must be exactly what is in YOUR tag, not whatever the build produced.
    git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/v$version" >/dev/null || die "Local tag v$version not found"
    local local_commit remote_commit
    local_commit=$(git -C "$REPO_ROOT" rev-list -n1 "v$version")
    remote_commit=$(git -C "$REPO_ROOT" ls-remote origin "refs/tags/v$version^{}" | awk '{print $1}')
    [ -n "$remote_commit" ] || remote_commit=$(git -C "$REPO_ROOT" ls-remote origin "refs/tags/v$version" | awk '{print $1}')
    [ "$local_commit" = "$remote_commit" ] || die "Tag v$version differs between this machine and GitHub; investigate before signing"
    mkdir -p "$WORK/built" "$WORK/local"
    tar -xzf "$WORK/shieldpress.tar.gz" -C "$WORK/built"
    git -C "$REPO_ROOT" archive "v$version" AGENTS.md shieldpress | tar -x -C "$WORK/local"
    diff -r "$WORK/built" "$WORK/local" >/dev/null \
        || die "The published package differs from your local tag v$version. NOT signing. Investigate (possible tampering)."
    echo "[OK] Published package is identical to local tag v$version"

    printf 'shieldpress-release\nversion=%s\nsha256=%s\n' "$version" "$actual" > "$WORK/shieldpress.manifest"
    echo "Signing release v$version (enter the key passphrase)..."
    openssl pkeyutl -sign -inkey "$PRIVATE_KEY" -rawin -in "$WORK/shieldpress.manifest" -out "$WORK/shieldpress.sig"

    # Self-check with the public keys that servers will trust.
    local ok=0 key
    for key in "$KEYS_DIR"/*.pem; do
        openssl pkeyutl -verify -pubin -inkey "$key" -rawin -in "$WORK/shieldpress.manifest" -sigfile "$WORK/shieldpress.sig" >/dev/null 2>&1 && ok=1
    done
    [ "$ok" = 1 ] || die "Signature does not verify with any key in $KEYS_DIR"

    gh release upload "v$version" "$WORK/shieldpress.manifest" "$WORK/shieldpress.sig" --repo "$GITHUB_REPO"
    echo "[OK] Release v$version signed and published"
}

cmd_verify(){
    local version="${1:-}"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Usage: verify <version>"
    download_release "$version"
    gh release download "v$version" --repo "$GITHUB_REPO" --dir "$WORK" -p shieldpress.manifest -p shieldpress.sig >/dev/null \
        || die "Release v$version has no signature"
    export SHIELDPRESS_RELEASE_KEYS_DIR="$KEYS_DIR" SHIELDPRESS_TREE_KEYS_DIR="$KEYS_DIR"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/shieldpress/core/release-verify.sh"
    local rc=0
    sp_verify_release "$WORK/shieldpress.tar.gz" "$version" "$WORK/shieldpress.manifest" "$WORK/shieldpress.sig" || rc=$?
    echo "$(sp_verify_release_message "$rc")"
    return "$rc"
}

case "${1:-}" in
    keygen) cmd_keygen ;;
    sign) shift; cmd_sign "$@" ;;
    verify) shift; cmd_verify "$@" ;;
    fingerprint) cmd_fingerprint ;;
    *) sed -n 2,10p "${BASH_SOURCE[0]}"; exit 1 ;;
esac
