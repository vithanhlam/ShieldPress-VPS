#!/bin/bash
# ShieldPress Shared Logger
# Source this file to get consistent log/ok/fail/warn/pause functions
# Set LOG_FILE before sourcing to direct log output to a file

BASE_DIR="${BASE_DIR:-/opt/shieldpress}"
[ -f "$BASE_DIR/core/paths.sh" ] && source "$BASE_DIR/core/paths.sh"
LOG_DIR="${LOG_DIR:-/var/shieldpress/logs}"

[ -z "$LOG_FILE" ] && LOG_FILE="$LOG_DIR/shieldpress.log"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null

sp_log(){  echo "$(date '+%F %T') | $1" | tee -a "$LOG_FILE"; }
sp_ok(){   echo "[OK] $1";   sp_log "[OK] $1"; }
sp_fail(){ echo "[FAIL] $1"; sp_log "[FAIL] $1"; }
sp_warn(){ echo "[WARN] $1"; sp_log "[WARN] $1"; }
sp_pause(){ echo ""; read -p "Press Enter..."; }

# Aliases for backward compatibility (scripts that use log/ok/fail/warn/pause)
# Only define if not already defined by the calling script
if ! declare -f log >/dev/null 2>&1; then
    log(){ sp_log "$@"; }
fi
if ! declare -f ok >/dev/null 2>&1; then
    ok(){ sp_ok "$@"; }
fi
if ! declare -f fail >/dev/null 2>&1; then
    fail(){ sp_fail "$@"; }
fi
if ! declare -f warn >/dev/null 2>&1; then
    warn(){ sp_warn "$@"; }
fi
if ! declare -f pause >/dev/null 2>&1; then
    pause(){ sp_pause; }
fi
