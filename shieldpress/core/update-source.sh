#!/bin/bash
# =====================================================
# ShieldPress Core - Update Source Resolution
# Version checks and source packages come from GitHub.
# Override values in /etc/shieldpress/update.conf.
# =====================================================

SHIELDPRESS_GITHUB_REPO="${SHIELDPRESS_GITHUB_REPO:-vithanhlam/ShieldPress-VPS}"
SHIELDPRESS_GITHUB_BRANCH="${SHIELDPRESS_GITHUB_BRANCH:-main}"

if [ -f /etc/shieldpress/update.conf ]; then
    # shellcheck disable=SC1091
    source /etc/shieldpress/update.conf
fi

SHIELDPRESS_RAW_BASE="https://raw.githubusercontent.com/${SHIELDPRESS_GITHUB_REPO}/${SHIELDPRESS_GITHUB_BRANCH}"
SHIELDPRESS_VERSION_URL="${SHIELDPRESS_VERSION_URL:-${SHIELDPRESS_RAW_BASE}/shieldpress/version.txt}"
SHIELDPRESS_RELEASE_API="https://api.github.com/repos/${SHIELDPRESS_GITHUB_REPO}/releases/latest"

# Latest version string, without a leading "v".
# Falls back to the newest published release tag when version.txt is unreachable.
sp_remote_version(){
    local version

    version=$(curl -fsSL --connect-timeout 5 --max-time 10 "$SHIELDPRESS_VERSION_URL" 2>/dev/null | tr -d '[:space:]')

    if [ -z "$version" ]; then
        version=$(curl -fsSL --connect-timeout 5 --max-time 10 "$SHIELDPRESS_RELEASE_API" 2>/dev/null \
            | grep -m1 '"tag_name"' \
            | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v?([^"]+)".*/\1/')
    fi

    [ -n "$version" ] || return 1
    printf '%s\n' "${version#v}"
}

# Candidate package URLs, most specific first.
# Usage: sp_package_urls "1.3.9"
sp_package_urls(){
    local version="${1:-}"

    if [ -n "$version" ]; then
        echo "https://github.com/${SHIELDPRESS_GITHUB_REPO}/releases/download/v${version}/shieldpress.tar.gz"
        echo "https://github.com/${SHIELDPRESS_GITHUB_REPO}/archive/refs/tags/v${version}.tar.gz"
    fi

    echo "https://github.com/${SHIELDPRESS_GITHUB_REPO}/archive/refs/heads/${SHIELDPRESS_GITHUB_BRANCH}.tar.gz"
}

# Checksum published alongside a release asset. Empty when no version is known.
sp_checksum_url(){
    local version="${1:-}"
    [ -n "$version" ] || return 0
    echo "https://github.com/${SHIELDPRESS_GITHUB_REPO}/releases/download/v${version}/shieldpress.sha256"
}

# Locate the directory holding the runtime source inside an extracted archive.
# Handles both release payloads and GitHub repository tarballs.
sp_find_source_root(){
    local extract_dir="$1" candidate

    while IFS= read -r candidate; do
        if [ -d "$candidate/core" ] && [ -d "$candidate/modules" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done < <(find "$extract_dir" -maxdepth 3 -type f -name shieldpress.sh -printf '%h\n' 2>/dev/null | sort)

    return 1
}
