#!/bin/bash

# Keep the command in the foreground so prompts, output and exit status survive.
run_with_progress() (
    local label="$1" history="$2"
    shift 2
    local started=$SECONDS estimate="" monitor="" status elapsed timing_file
    if [ -f "$history" ]; then
        read -r estimate < "$history"
        [[ "$estimate" =~ ^[1-9][0-9]*$ ]] || estimate=""
    fi
    if [ -n "$estimate" ]; then
        echo "[PROGRESS] $label: estimated duration ${estimate}s (previous successful run)."
    else
        echo "[PROGRESS] $label: estimating on first run; elapsed time updates every 10s."
    fi
    trap '[ -z "$monitor" ] || { kill "$monitor" 2>/dev/null || true; wait "$monitor" 2>/dev/null || true; }' EXIT
    (
        trap 'exit 0' TERM INT HUP
        while true; do
            sleep 10 &
            local sleeper=$!
            trap 'kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null; exit 0' TERM INT HUP
            wait "$sleeper" || exit
            elapsed=$((SECONDS - started))
            if [ -n "$estimate" ] && [ "$elapsed" -lt "$estimate" ]; then
                echo "[PROGRESS] $label: running, elapsed ${elapsed}s; estimated remaining $((estimate - elapsed))s."
            elif [ -n "$estimate" ]; then
                echo "[PROGRESS] $label: running, elapsed ${elapsed}s; taking longer than the previous run."
            else
                echo "[PROGRESS] $label: running, elapsed ${elapsed}s; ETA not available yet."
            fi
        done
    ) &
    monitor=$!
    if "$@"; then status=0; else status=$?; fi
    kill "$monitor" 2>/dev/null || true
    wait "$monitor" 2>/dev/null || true
    monitor=""
    elapsed=$((SECONDS - started))
    echo "[PROGRESS] $label: finished in ${elapsed}s (exit $status)."
    # Timing is advisory. Failure to save must never fail a deployment.
    if [ "$status" -eq 0 ] && [ -d "$(dirname "$history")" ]; then
        timing_file=$(mktemp "${history}.XXXXXX" 2>/dev/null) || return "$status"
        if printf '%s\n' "$((elapsed > 0 ? elapsed : 1))" > "$timing_file"; then
            mv -fT -- "$timing_file" "$history" 2>/dev/null || rm -f -- "$timing_file"
        else
            rm -f -- "$timing_file"
        fi
    fi
    return "$status"
)
