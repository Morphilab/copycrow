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

    local tmp
    for tmp in "${TEMP_FILES[@]:-}"; do
        if [[ -f "$tmp" ]]; then
            rm -f "$tmp" 2>/dev/null || true
        fi
    done

    # Release job lock (unlocks kernel flock, closes fd, removes file).
    if declare -F safety_lock_release >/dev/null 2>&1; then
        safety_lock_release
    elif [[ -n "${COPYCROW_LOCK_FILE:-}" ]] && [[ -f "${COPYCROW_LOCK_FILE}" ]]; then
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
    trap 'echo "Hangup: session closed." >&2; exit 129' HUP
}

# ───────────────────────────────────────────────────────────────────────────────
# safety_add_temp
# Registers a temporary file for automatic cleanup
# ───────────────────────────────────────────────────────────────────────────────
safety_add_temp() {
    TEMP_FILES+=("$1")
}

# ───────────────────────────────────────────────────────────────────────────────
# _lock_inode_matches
# True when the open fd still refers to the file currently at <path>.
# Guards the classic unlink race: a releaser unlinks the path AFTER
# unlocking, so an acquirer that opened the old inode before that and only
# flocked after it would hold an ORPHANED file while the path gets recreated
# for the next acquirer — two simultaneous holders on one job.
# If the fd itself cannot be resolved (no /proc), fail OPEN: the check is a
# hardening extra, not a prerequisite for locking. A vanished path IS a
# mismatch: the acquire retry recreates and relocks it.
# ───────────────────────────────────────────────────────────────────────────────
_lock_inode_matches() {
    local path="$1" fd="$2" fd_ino path_ino
    fd_ino="$(stat -Lc %i "/proc/self/fd/${fd}" 2>/dev/null)" || return 0
    path_ino="$(stat -c %i -- "$path" 2>/dev/null)" || return 1
    [[ "$fd_ino" == "$path_ino" ]]
}

# ───────────────────────────────────────────────────────────────────────────────
# safety_lock_acquire
# Acquires an exclusive lock for a job (non-blocking) via flock(1).
# The lock lives as long as the file descriptor is open, so the KERNEL
# releases it when the holder dies — there are no stale locks to recover and
# no check-then-act window on the flock itself: flock is atomic. The one gap
# flock cannot cover is the unlink-after-release of the lock FILE; the
# post-flock inode recheck below closes it (see _lock_inode_matches).
# Returns 0 if acquired, 1 if already locked.
# Requires: flock (util-linux, present on all supported Debian/Ubuntu targets).
# ───────────────────────────────────────────────────────────────────────────────
safety_lock_acquire() {
    local job="$1"
    local lock_file="${LOCK_DIR}/copycrow-${job}.lock"

    # Dynamic fd allocation (bash 4.1+): fd number lands in COPYCROW_LOCK_FD.
    # Opened read-write WITHOUT truncation so a concurrent holder's content
    # stays intact; children inherit the fd, keeping the lock for the whole
    # backup duration even across exec'd tools.
    if ! command -v flock >/dev/null 2>&1; then
        echo "ERROR: flock not found (util-linux). Cannot lock job '$job'." >&2
        return 1
    fi

    local attempt
    for attempt in 1 2 3; do
        : >> "$lock_file" 2>/dev/null || return 1
        exec {COPYCROW_LOCK_FD}>> "$lock_file" || return 1

        if ! flock -n "${COPYCROW_LOCK_FD}" 2>/dev/null; then
            exec {COPYCROW_LOCK_FD}>&-
            unset COPYCROW_LOCK_FD
            return 1
        fi

        if _lock_inode_matches "$lock_file" "${COPYCROW_LOCK_FD}"; then
            break
        fi

        # Our exclusive lock protects a replaced (orphaned) inode: drop it
        # and retry on whatever the path holds now. Bounded: if the file
        # keeps changing, refuse rather than risk a duplicate run.
        exec {COPYCROW_LOCK_FD}>&-
        unset COPYCROW_LOCK_FD
        if [[ "$attempt" == 3 ]]; then
            echo "ERROR: lock file '$lock_file' kept changing during acquire; refusing a possible duplicate run." >&2
            return 1
        fi
    done

    # Diagnostic only — never used for liveness decisions.
    printf '%s\n' "$$" > "$lock_file"
    COPYCROW_LOCK_FILE="$lock_file"
    return 0
}

# ───────────────────────────────────────────────────────────────────────────────
# safety_lock_release
# Releases the current lock (unlocks, closes the fd, removes the file)
# ───────────────────────────────────────────────────────────────────────────────
safety_lock_release() {
    if [[ -n "${COPYCROW_LOCK_FD:-}" ]]; then
        flock -u "${COPYCROW_LOCK_FD}" 2>/dev/null || true
        exec {COPYCROW_LOCK_FD}>&- 2>/dev/null || true
        unset COPYCROW_LOCK_FD
    fi
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

    # Convention-compliant capture: explicit rc so a failing command cannot
    # abort the function before the lock is released.
    local rc=0
    "$@" || rc=$?
    safety_lock_release
    return $rc
}
