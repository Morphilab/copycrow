#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# copycrow — safety.sh
# Signal handling, file locking, and cleanup
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

COPYCROW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LOCK_DIR="${COPYCROW_ROOT}/.locks"
TEMP_FILES=()

mkdir -p "$LOCK_DIR" 2>/dev/null || true

# ───────────────────────────────────────────────────────────────────────────────
# _cleanup
# Cleans up temporary files and releases locks
# ───────────────────────────────────────────────────────────────────────────────
_cleanup() {
    local exit_code=$?

    for tmp in "${TEMP_FILES[@]:-}"; do
        if [[ -f "$tmp" ]]; then
            rm -f "$tmp" 2>/dev/null || true
        fi
    done

    if [[ -n "${COPYCROW_LOCK_FILE:-}" ]] && [[ -f "${COPYCROW_LOCK_FILE}" ]]; then
        rm -f "${COPYCROW_LOCK_FILE}" 2>/dev/null || true
    fi

    exit $exit_code
}

# ───────────────────────────────────────────────────────────────────────────────
# safety_init
# Registers signal traps and sets up automatic cleanup
# ───────────────────────────────────────────────────────────────────────────────
safety_init() {
    trap _cleanup EXIT
    trap 'echo ""; echo "Interrupted by user." >&2; exit 130' INT
    trap 'echo "Terminated." >&2; exit 143' TERM
}

# ───────────────────────────────────────────────────────────────────────────────
# safety_add_temp
# Registers a temporary file for automatic cleanup
# ───────────────────────────────────────────────────────────────────────────────
safety_add_temp() {
    TEMP_FILES+=("$1")
}

# ───────────────────────────────────────────────────────────────────────────────
# safety_lock_acquire
# Acquires an exclusive lock for a job (non-blocking)
# Returns 0 if acquired, 1 if already locked
# ───────────────────────────────────────────────────────────────────────────────
safety_lock_acquire() {
    local job="$1"
    local lock_file="${LOCK_DIR}/copycrow-${job}.lock"

    if [[ -f "$lock_file" ]]; then
        local pid
        pid=$(cat "$lock_file" 2>/dev/null || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            return 1
        fi
        rm -f "$lock_file"
    fi

    echo "$$" > "$lock_file"
    COPYCROW_LOCK_FILE="$lock_file"
    return 0
}

# ───────────────────────────────────────────────────────────────────────────────
# safety_lock_release
# Releases the current lock
# ───────────────────────────────────────────────────────────────────────────────
safety_lock_release() {
    if [[ -n "${COPYCROW_LOCK_FILE:-}" ]] && [[ -f "${COPYCROW_LOCK_FILE}" ]]; then
        rm -f "${COPYCROW_LOCK_FILE}"
        unset COPYCROW_LOCK_FILE
    fi
}

# ───────────────────────────────────────────────────────────────────────────────
# safety_lock_run
# Runs a command under lock, releases when done
# ───────────────────────────────────────────────────────────────────────────────
safety_lock_run() {
    local job="$1"
    shift

    if ! safety_lock_acquire "$job"; then
        echo "ERROR: A backup is already in progress for '$job'" >&2
        return 1
    fi

    "$@"
    local rc=$?
    safety_lock_release
    return $rc
}
