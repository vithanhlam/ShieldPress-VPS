#!/bin/bash
# =====================================================
# ShieldPress Core - Release signature verification
#
# Every release package must carry a manifest signed with the maintainer's
# offline Ed25519 key. Servers trust only the public keys stored in
# /etc/shieldpress/release-keys; checksums alone are never enough, because
# anyone who controls the GitHub repository can publish matching checksums.
#
# The signed manifest is:
#   shieldpress-release
#   version=<x.y.z>
#   sha256=<sha256 of shieldpress.tar.gz>
# =====================================================

SP_RELEASE_KEYS_DIR="${SHIELDPRESS_RELEASE_KEYS_DIR:-/etc/shieldpress/release-keys}"
SP_TREE_KEYS_DIR="${SHIELDPRESS_TREE_KEYS_DIR:-${BASE_DIR:-/opt/shieldpress}/core/release-keys}"

# Succeeds when the file is a valid public key.
sp_release_key_valid(){
    openssl pkey -pubin -in "$1" -noout >/dev/null 2>&1
}

sp_release_key_count(){
    local n=0 f
    for f in "$SP_RELEASE_KEYS_DIR"/*.pem; do
        [ -f "$f" ] && sp_release_key_valid "$f" && n=$((n + 1))
    done
    echo "$n"
}

# Copy valid keys from a source directory without replacing existing ones.
# Usage: sp_release_keys_copy <dir>
sp_release_keys_copy(){
    local src="$1" f name
    mkdir -p "$SP_RELEASE_KEYS_DIR" || return 1
    chmod 755 "$SP_RELEASE_KEYS_DIR" 2>/dev/null || true
    for f in "$src"/*.pem; do
        [ -f "$f" ] || continue
        sp_release_key_valid "$f" || continue
        name=$(basename "$f")
        [ -e "$SP_RELEASE_KEYS_DIR/$name" ] && continue
        install -m 644 "$f" "$SP_RELEASE_KEYS_DIR/$name" || return 1
    done
}

# First use: trust the keys that shipped with the INSTALLED source tree (never
# the freshly downloaded package). Returns 1 when no key is available.
sp_release_keys_bootstrap(){
    [ "$(sp_release_key_count)" -gt 0 ] && return 0
    sp_release_keys_copy "$SP_TREE_KEYS_DIR" || return 1
    [ "$(sp_release_key_count)" -gt 0 ]
}

# After a package has been verified and installed, accept any new keys it ships
# (key rotation). Existing keys are kept.
sp_release_keys_sync(){
    sp_release_keys_copy "$SP_TREE_KEYS_DIR"
}

sp_release_manifest_url(){
    echo "https://github.com/${SHIELDPRESS_GITHUB_REPO}/releases/download/v${1}/shieldpress.manifest"
}

sp_release_signature_url(){
    echo "https://github.com/${SHIELDPRESS_GITHUB_REPO}/releases/download/v${1}/shieldpress.sig"
}

# Verify <manifest> against <signature> with any trusted key.
sp_verify_signature(){
    local manifest="$1" sig="$2" key
    for key in "$SP_RELEASE_KEYS_DIR"/*.pem; do
        [ -f "$key" ] || continue
        if openssl pkeyutl -verify -pubin -inkey "$key" -rawin -in "$manifest" -sigfile "$sig" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

# Verify that <package> is exactly the release <version> signed by the maintainer.
# Usage: sp_verify_release <package> <version> <manifest> <signature>
# Returns: 0 valid, 2 no trusted key, 3 manifest/signature missing,
#          4 bad signature, 5 manifest does not match the package/version
sp_verify_release(){
    local package="$1" version="$2" manifest="$3" sig="$4" actual
    command -v openssl >/dev/null 2>&1 || return 2
    sp_release_keys_bootstrap || return 2
    [ -s "$manifest" ] && [ -s "$sig" ] || return 3
    sp_verify_signature "$manifest" "$sig" || return 4

    # Only signed data is parsed below.
    [ "$(sed -n 1p "$manifest")" = "shieldpress-release" ] || return 5
    [ "$(sed -n 's/^version=//p' "$manifest" | head -1)" = "$version" ] || return 5
    actual=$(sha256sum "$package" | awk '{print $1}')
    [ "$(sed -n 's/^sha256=//p' "$manifest" | head -1)" = "$actual" ] || return 5
    return 0
}

sp_verify_release_message(){
    case "$1" in
        0) echo "Release signature verified" ;;
        2) echo "No trusted release key is installed" ;;
        3) echo "Release signature is missing" ;;
        4) echo "Release signature is NOT valid for any trusted key" ;;
        5) echo "Signed manifest does not match this package or version" ;;
        *) echo "Release verification failed" ;;
    esac
}
