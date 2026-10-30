#!/bin/bash
# ShieldPress VPS — installer
#
# Works in two modes:
#   1. From a git clone:  sudo bash install.sh
#   2. Downloaded from a URL, then reviewed/executed locally.
#   3. Piped: curl -fsSL https://install.shieldpress.net | bash
#
# The source and version always come from GitHub, so a domain only needs to
# serve this bootstrap script.
#
# SHIELDPRESS_INSTALL_STACK=yes|no answers the "install server stack now"
# question for unattended runs (default: ask on a terminal, skip otherwise).

set -euo pipefail

SHIELDPRESS_GITHUB_REPO="${SHIELDPRESS_GITHUB_REPO:-vithanhlam/ShieldPress-VPS}"
SHIELDPRESS_GITHUB_BRANCH="${SHIELDPRESS_GITHUB_BRANCH:-main}"
TARGET_DIR="/opt/shieldpress"
CONF_DIR="/etc/shieldpress"

echo "========================================="
echo "        Installing ShieldPress VPS"
echo "========================================="

# True when the controlling terminal can be used for prompts (also when piped).
tty_available(){
    { : </dev/tty; } 2>/dev/null && [ -w /dev/tty ]
}

if [ "$EUID" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || {
        echo "[ERROR] Root is required. Log in as root and run the installer again."
        exit 1
    }
    SELF="${BASH_SOURCE[0]:-}"
    if [ -n "$SELF" ] && [ -f "$SELF" ]; then
        echo "[INFO] Not running as root. Re-running with sudo..."
        exec sudo -E bash "$(cd "$(dirname "$SELF")" && pwd)/$(basename "$SELF")" "$@"
    fi
    # Piped from curl: there is no script file to re-run, so fetch this
    # bootstrap from the configured GitHub source and run it with sudo.
    echo "[INFO] Not running as root. Re-running the installer with sudo..."
    SELF=$(mktemp /tmp/shieldpress-install.XXXXXX)
    curl -fsSL --connect-timeout 10 --max-time 30 \
        "https://raw.githubusercontent.com/${SHIELDPRESS_GITHUB_REPO}/${SHIELDPRESS_GITHUB_BRANCH}/install.sh" -o "$SELF" \
        || { rm -f "$SELF"; echo "[ERROR] Cannot download the installer. Run: curl -fsSL https://install.shieldpress.net | sudo bash"; exit 1; }
    chmod 644 "$SELF"
    # The re-run reads prompts from the terminal, not from the curl pipe.
    if tty_available; then
        sudo -E bash "$SELF" "$@" </dev/tty && status=0 || status=$?
    else
        sudo -E bash "$SELF" "$@" && status=0 || status=$?
    fi
    rm -f "$SELF"
    exit "$status"
fi

# Animated stage indicator on interactive terminals; output and exit status are preserved.
run_stage(){
    local label="$1" estimate="$2" pid status=0 frames='|/-\' index=0 started=$SECONDS remaining
    shift 2
    echo "[PROGRESS] $label: estimated duration ~${estimate}s (approximate)."
    "$@" &
    pid=$!
    if [ -t 1 ]; then
        while kill -0 "$pid" 2>/dev/null; do
            remaining=$((estimate - (SECONDS - started)))
            if [ "$remaining" -gt 0 ]; then
                printf '\r\033[K[%s] %s — ETA ~%ss' "${frames:index++%4:1}" "$label" "$remaining"
            else
                printf '\r\033[K[%s] %s — taking longer than estimated; still running' "${frames:index++%4:1}" "$label"
            fi
            sleep 0.2
        done
        printf '\r\033[K'
    fi
    wait "$pid" || status=$?
    return "$status"
}


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

    VERSION_URL="https://raw.githubusercontent.com/${SHIELDPRESS_GITHUB_REPO}/${SHIELDPRESS_GITHUB_BRANCH}/shieldpress/version.txt"
    SOURCE_VERSION=$(curl -fsSL --connect-timeout 10 --max-time 30 "$VERSION_URL" | tr -d '[:space:]')
    [ -n "$SOURCE_VERSION" ] || { echo "[ERROR] Cannot determine source version"; exit 1; }

    TARBALL="https://github.com/${SHIELDPRESS_GITHUB_REPO}/releases/download/v${SOURCE_VERSION}/shieldpress.tar.gz"
    CHECKSUM_URL="https://github.com/${SHIELDPRESS_GITHUB_REPO}/releases/download/v${SOURCE_VERSION}/shieldpress.sha256"
    curl -fsSL --connect-timeout 10 --max-time 30 "$CHECKSUM_URL" -o "$WORK_DIR/source.sha256" \
        || true
    run_stage "Downloading ShieldPress ${SOURCE_VERSION}" 15 \
        curl -fsSL --connect-timeout 10 --max-time 300 "$TARBALL" -o "$WORK_DIR/source.tar.gz" \
        || { echo "[ERROR] Cannot download $TARBALL"; exit 1; }

    EXPECTED_SHA=$(awk 'NF {print $1; exit}' "$WORK_DIR/source.sha256" 2>/dev/null || true)
    if ! [[ "$EXPECTED_SHA" =~ ^[0-9a-fA-F]{64}$ ]]; then
        RELEASE_API="https://api.github.com/repos/${SHIELDPRESS_GITHUB_REPO}/releases/tags/v${SOURCE_VERSION}"
        EXPECTED_SHA=$(curl -fsSL --connect-timeout 10 --max-time 30 "$RELEASE_API" 2>/dev/null \
            | awk '
                /"name"[[:space:]]*:/ {
                    current = index($0, "\"name\":\"shieldpress.tar.gz\"") || \
                              index($0, "\"name\": \"shieldpress.tar.gz\"")
                }
                current && /"digest"[[:space:]]*:[[:space:]]*"sha256:/ {
                    sub(/^.*"digest"[[:space:]]*:[[:space:]]*"sha256:/, "")
                    sub(/".*$/, "")
                    print
                    exit
                }
            ')
    fi
    [[ "$EXPECTED_SHA" =~ ^[0-9a-fA-F]{64}$ ]] \
        || { echo "[ERROR] Release checksum unavailable; refusing unverified install"; exit 1; }
    ACTUAL_SHA=$(sha256sum "$WORK_DIR/source.tar.gz" | awk '{print $1}')
    [ -n "$EXPECTED_SHA" ] && [ "$EXPECTED_SHA" = "$ACTUAL_SHA" ] \
        || { echo "[ERROR] Source checksum mismatch; refusing install"; exit 1; }

    mkdir -p "$WORK_DIR/extract"
    run_stage "Extracting package" 5 tar --no-same-owner -xzf "$WORK_DIR/source.tar.gz" -C "$WORK_DIR/extract" \
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

# Secure copied code before invoking its root installer.
chown -hR root:root "$TARGET_DIR"
find "$TARGET_DIR" -type d -exec chmod go-w {} +
find "$TARGET_DIR" -type f -exec chmod go-w {} +

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

# ------------------------------------------------
# SERVER STACK (Nginx, PHP, MariaDB, Valkey, ...)
# ------------------------------------------------
if [ -f "$CONF_DIR/.stack_installed" ]; then
    echo "[OK] Server stack already installed"
    echo "Run: shieldpress"
    exit 0
fi

STACK_ANSWER="${SHIELDPRESS_INSTALL_STACK:-}"
if [ -z "$STACK_ANSWER" ] && tty_available; then
    echo "" >/dev/tty
    echo "The server stack (Nginx, PHP, MariaDB, Valkey, firewall) is not installed yet." >/dev/tty
    echo "It checks AlmaLinux 9/10, RAM and disk first. Approximate duration: 10-20 minutes." >/dev/tty
    printf "Install the server stack now? [Y/n]: " >/dev/tty
    read -r STACK_ANSWER </dev/tty || STACK_ANSWER="n"
    STACK_ANSWER="${STACK_ANSWER:-Y}"
fi

case "$STACK_ANSWER" in
    [Yy]|[Yy][Ee][Ss])
        echo "[INFO] Installing server stack..."
        # Keep the curl pipe away from the stack installer's input.
        if tty_available; then
            bash "$TARGET_DIR/modules/install/install-stack.sh" </dev/tty && status=0 || status=$?
        else
            bash "$TARGET_DIR/modules/install/install-stack.sh" </dev/null && status=0 || status=$?
        fi
        if [ "$status" -ne 0 ]; then
            echo "[ERROR] Server stack installation failed (exit $status)."
            echo "Fix the reported problem, then run: shieldpress -> [1] Install Stack"
            exit "$status"
        fi
        echo "[OK] Server stack installed"
        echo "Run: shieldpress"
        ;;
    *)
        echo "[INFO] Server stack not installed yet."
        echo "Run: shieldpress -> [1] Install Stack"
        echo "(Unattended: curl -fsSL https://install.shieldpress.net | SHIELDPRESS_INSTALL_STACK=yes bash)"
        ;;
esac
