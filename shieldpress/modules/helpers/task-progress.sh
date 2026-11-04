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
    local interactive=0
    [ -t 1 ] && interactive=1
    if [ "$interactive" -eq 1 ]; then
        :  # One in-place status line below; no header lines.
    elif [ -n "$estimate" ]; then
        echo "[PROGRESS] $label: estimated duration ${estimate}s (previous successful run)."
    else
        echo "[PROGRESS] $label: estimating on first run; elapsed time updates every 10s."
    fi
    trap '[ -z "$monitor" ] || { kill "$monitor" 2>/dev/null || true; wait "$monitor" 2>/dev/null || true; }' EXIT
    (
        trap 'exit 0' TERM INT HUP
        local frames='|/-\' index=0 tick=0 text
        while true; do
            sleep 1 &
            local sleeper=$!
            trap 'kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null; exit 0' TERM INT HUP
            wait "$sleeper" || exit
            tick=$((tick + 1))
            elapsed=$((SECONDS - started))
            if [ -n "$estimate" ] && [ "$elapsed" -lt "$estimate" ]; then
                text="${elapsed}s elapsed, ~$((estimate - elapsed))s left"
            elif [ -n "$estimate" ]; then
                text="${elapsed}s elapsed, taking longer than the previous run"
            else
                text="${elapsed}s elapsed, ETA not available yet"
            fi
            if [ "$interactive" -eq 1 ]; then
                printf '\r\033[K[%s] %s: %s' "${frames:index++%4:1}" "$label" "$text"
            elif [ $((tick % 10)) -eq 0 ]; then
                echo "[PROGRESS] $label: running, $text."
            fi
        done
    ) &
    monitor=$!
    if "$@"; then status=0; else status=$?; fi
    kill "$monitor" 2>/dev/null || true
    wait "$monitor" 2>/dev/null || true
    monitor=""
    elapsed=$((SECONDS - started))
    [ "$interactive" -eq 0 ] || printf '\r\033[K'
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

# Use a spinner for non-interactive stages; keep the command in the foreground.
run_with_loading() (
    local label="$1" history="$2" fallback="$3"
    shift 3
    local estimate="$fallback" basis="rough estimate" monitor status started=$SECONDS
    if [ -f "$history" ]; then
        local previous
        read -r previous < "$history"
        if [[ "$previous" =~ ^[1-9][0-9]*$ ]]; then
            estimate="$previous"
            basis="previous successful run"
        fi
    fi
    echo "[PROGRESS] $label: estimated duration ~${estimate}s ($basis)."
    trap '[ -z "$monitor" ] || { kill "$monitor" 2>/dev/null || true; wait "$monitor" 2>/dev/null || true; }' EXIT
    (
        local frames='|/-\' index=0 remaining
        trap 'exit 0' TERM INT HUP
        while true; do
            remaining=$((estimate - (SECONDS - started)))
            if [ -t 1 ]; then
                if [ "$remaining" -gt 0 ]; then
                    printf '\r\033[K[%s] %s — ETA ~%ss' "${frames:index++%4:1}" "$label" "$remaining"
                else
                    printf '\r\033[K[%s] %s — taking longer than estimated; still running' "${frames:index++%4:1}" "$label"
                fi
            fi
            sleep 0.2 &
            local sleeper=$!
            trap 'kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null; exit 0' TERM INT HUP
            wait "$sleeper" || exit
        done
    ) &
    monitor=$!
    if "$@"; then status=0; else status=$?; fi
    kill "$monitor" 2>/dev/null || true
    wait "$monitor" 2>/dev/null || true
    monitor=""
    [ ! -t 1 ] || printf '\r\033[K'
    echo "[PROGRESS] $label: finished (exit $status)."
    if [ "$status" -eq 0 ]; then
        local elapsed=$((SECONDS - started)) timing_file
        if timing_file=$(mktemp "${history}.XXXXXX" 2>/dev/null); then
            printf '%s\n' "$((elapsed > 0 ? elapsed : 1))" > "$timing_file"
            mv -fT -- "$timing_file" "$history" 2>/dev/null || rm -f -- "$timing_file"
        fi
    fi
    return "$status"
)
