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

    # Release job lock (removes the file, then unlocks and closes the fd).
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
# Guards the inode/path split inherent to flock on a lock FILE: an acquirer
# can flock an inode that is no longer (or is about to stop being) the one
# the path resolves to — e.g. it opened the old inode just as the previous
# holder released — while the next acquirer locks the recreated path; without
# the recheck both would hold the job simultaneously. Release unlinks BEFORE
# unlocking, and this recheck closes the rest of the window: a vanished or
# swapped path is a mismatch and triggers the acquire retry.
# If the fd itself cannot be resolved (no /proc), fail OPEN: the check is a
# hardening extra, not a prerequisite for locking.
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
# flock cannot cover is that the lock is bound to the FILE'S INODE, not to
# the path; the post-flock inode recheck below closes it
# (see _lock_inode_matches).
# Returns: 0 acquired, 1 already locked (someone else holds the job),
# 2 locking is impossible here (no flock, unusable lock file). Callers that
# may skip work must not treat 2 as "busy": a job nobody holds but nobody can
# lock is an error, not a skip.
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
        return 2
    fi

    local attempt
    for attempt in 1 2 3; do
        if ! : >> "$lock_file" 2>/dev/null; then
            echo "ERROR: cannot create lock file '$lock_file' (job '$job' cannot be locked)." >&2
            return 2
        fi
        if ! exec {COPYCROW_LOCK_FD}>> "$lock_file"; then
            echo "ERROR: cannot open lock file '$lock_file' (job '$job' cannot be locked)." >&2
            return 2
        fi

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
            return 2
        fi
    done

    # Diagnostic only — never used for liveness decisions.
    printf '%s\n' "$$" > "$lock_file"
    COPYCROW_LOCK_FILE="$lock_file"
    return 0
}

# ───────────────────────────────────────────────────────────────────────────────
# safety_lock_release
# Releases the current lock (removes the file, then unlocks and closes the fd)
# ───────────────────────────────────────────────────────────────────────────────
safety_lock_release() {
    # Unlink BEFORE unlocking: a releaser that removed the path only after the
    # unlock would let a late acquirer flock the soon-orphaned inode while the
    # path still resolved to it (passing the inode recheck), and the next
    # acquirer then recreates the path — two simultaneous holders on one job.
    # Removing the file while the lock is still held forces every acquirer
    # past that point onto a fresh inode, which the recheck validates.
    if [[ -n "${COPYCROW_LOCK_FILE:-}" ]] && [[ -f "${COPYCROW_LOCK_FILE}" ]]; then
        rm -f "${COPYCROW_LOCK_FILE}" 2>/dev/null || true
        unset COPYCROW_LOCK_FILE
    fi
    if [[ -n "${COPYCROW_LOCK_FD:-}" ]]; then
        flock -u "${COPYCROW_LOCK_FD}" 2>/dev/null || true
        # `exec` with only redirections would PERSIST them for the whole
        # shell: a 2>/dev/null here would silently swallow every later
        # message of the process. Close the fd bare, guarded for set -e.
        exec {COPYCROW_LOCK_FD}>&- || true
        unset COPYCROW_LOCK_FD
    fi
}

# ───────────────────────────────────────────────────────────────────────────────
# safety_lock_run
# Runs a command under lock, releases when done.
# A busy job (rc 1) is reported as such; an impossible lock (rc 2) keeps its
# own diagnosis instead of masquerading as "already in progress".
# ───────────────────────────────────────────────────────────────────────────────
safety_lock_run() {
    local job="$1"
    shift

    local lock_rc=0
    safety_lock_acquire "$job" || lock_rc=$?
    if (( lock_rc == 1 )); then
        echo "ERROR: '$job' is already in progress (job lock held by another run)" >&2
        return 1
    elif (( lock_rc != 0 )); then
        # safety_lock_acquire already explained the failure on stderr.
        return "$lock_rc"
    fi

    # Convention-compliant capture: explicit rc so a failing command cannot
    # abort the function before the lock is released.
    local rc=0
    "$@" || rc=$?
    safety_lock_release
    return $rc
}
