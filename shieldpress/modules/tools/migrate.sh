#!/bin/bash
# Copy one, several or all websites between ShieldPress servers.
# The Python engine validates packages and refuses existing destination resources.
set -euo pipefail
BASE_DIR="/opt/shieldpress"
if [ "$EUID" -ne 0 ]; then
    echo "[FAIL] Server Migration requires root." >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "[FAIL] Python 3.9 or newer is required. Update the ShieldPress stack first." >&2
    exit 1
fi
if [ "${1:-}" = "--export-auto" ]; then
    echo "[FAIL] Legacy remote export is retired. Update ShieldPress on both VPSs and use Server Migration." >&2
    exit 1
fi
exec python3 "$BASE_DIR/modules/tools/server-migration.py" "$@"
