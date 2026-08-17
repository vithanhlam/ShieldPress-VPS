#!/bin/bash
# ShieldPress VPS — installer
#
# Works in two modes:
#   1. From a git clone:  sudo bash install.sh
#   2. Piped from a URL:  curl -fsSL https://install.shieldpress.net | bash
#
# The source and version always come from GitHub, so a domain only needs to
# serve this bootstrap script.

set -euo pipefail

SHIELDPRESS_GITHUB_REPO="${SHIELDPRESS_GITHUB_REPO:-vithanhlam/ShieldPress-VPS}"
SHIELDPRESS_GITHUB_BRANCH="${SHIELDPRESS_GITHUB_BRANCH:-main}"
TARGET_DIR="/opt/shieldpress"
CONF_DIR="/etc/shieldpress"

echo "========================================="
echo "        Installing ShieldPress VPS"
echo "========================================="

if [ "$EUID" -ne 0 ]; then
    echo "[INFO] Not running as root. Trying sudo..."
    exec sudo -E bash "$0" "$@"
fi

for cmd in curl tar; do
    command -v "$cmd" >/dev/null 2>&1 || dnf install -y "$cmd" >/dev/null 2>&1 || true
done

SOURCE_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    [ -f "$REPO_ROOT/shieldpress/shieldpress.sh" ] && SOURCE_DIR="$REPO_ROOT/shieldpress"
fi

WORK_DIR=""
cleanup(){ [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR"; }
trap cleanup EXIT

if [ -z "$SOURCE_DIR" ]; then
    echo "[INFO] Downloading source from github.com/$SHIELDPRESS_GITHUB_REPO ..."
    WORK_DIR=$(mktemp -d)

    TARBALL="https://github.com/${SHIELDPRESS_GITHUB_REPO}/archive/refs/heads/${SHIELDPRESS_GITHUB_BRANCH}.tar.gz"
    curl -fsSL --connect-timeout 10 --max-time 300 "$TARBALL" -o "$WORK_DIR/source.tar.gz" \
        || { echo "[ERROR] Cannot download $TARBALL"; exit 1; }

    mkdir -p "$WORK_DIR/extract"
    tar -xzf "$WORK_DIR/source.tar.gz" -C "$WORK_DIR/extract" \
        || { echo "[ERROR] Cannot extract downloaded package"; exit 1; }

    SOURCE_DIR=$(find "$WORK_DIR/extract" -maxdepth 3 -type f -name shieldpress.sh -printf '%h\n' 2>/dev/null | sort | head -1)

    if [ -z "$SOURCE_DIR" ] || [ ! -d "$SOURCE_DIR/core" ] || [ ! -d "$SOURCE_DIR/modules" ]; then
        echo "[ERROR] Downloaded package does not contain the ShieldPress source"
        exit 1
    fi
fi

echo "[INFO] Installing into $TARGET_DIR ..."
mkdir -p "$TARGET_DIR"

if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete \
        --exclude 'update-backups/' \
        "$SOURCE_DIR/" "$TARGET_DIR/"
else
    find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    cp -a "$SOURCE_DIR"/. "$TARGET_DIR"/
fi

mkdir -p "$CONF_DIR"
cat > "$CONF_DIR/update.conf" <<CONF_EOF
# ShieldPress VPS update source.
# Version checks and packages are fetched from this GitHub repository.
SHIELDPRESS_GITHUB_REPO="$SHIELDPRESS_GITHUB_REPO"
SHIELDPRESS_GITHUB_BRANCH="$SHIELDPRESS_GITHUB_BRANCH"
CONF_EOF
chmod 644 "$CONF_DIR/update.conf"

bash "$TARGET_DIR/install.sh"

echo ""
echo "[OK] ShieldPress VPS installed to $TARGET_DIR"
echo "[OK] Updates will be pulled from github.com/$SHIELDPRESS_GITHUB_REPO"
echo "Run: shieldpress"
