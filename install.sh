#!/bin/bash
# ShieldPress VPS — repository installer
# Copies source from ./shieldpress into /opt/shieldpress and finishes setup.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$REPO_ROOT/shieldpress"
TARGET_DIR="/opt/shieldpress"

echo "========================================="
echo "   ShieldPress VPS — Local Install"
echo "========================================="

if [ "$EUID" -ne 0 ]; then
    echo "[INFO] Not running as root. Trying sudo..."
    exec sudo bash "$0" "$@"
fi

if [ ! -f "$SOURCE_DIR/shieldpress.sh" ]; then
    echo "[ERROR] Missing $SOURCE_DIR/shieldpress.sh"
    echo "Clone the full repository, then run this script from the repo root."
    exit 1
fi

if [ ! -f "$SOURCE_DIR/install.sh" ]; then
    echo "[ERROR] Missing $SOURCE_DIR/install.sh"
    exit 1
fi

mkdir -p "$TARGET_DIR"
if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete \
        --exclude '.git/' \
        --exclude '.agents/' \
        --exclude 'update-backups/' \
        "$SOURCE_DIR/" "$TARGET_DIR/"
else
    find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    cp -a "$SOURCE_DIR"/. "$TARGET_DIR"/
fi

bash "$TARGET_DIR/install.sh"

echo ""
echo "[OK] ShieldPress VPS installed to $TARGET_DIR"
echo "Run: shieldpress"
