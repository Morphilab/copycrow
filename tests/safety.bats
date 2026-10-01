#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════════════════════
# Tests for safety.sh
# Dependency: bats-core
# ═══════════════════════════════════════════════════════════════════════════════

setup() {
    export COPYCROW_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    source "${COPYCROW_ROOT}/src/safety.sh"
    export LOCK_DIR="/tmp/copycrow-test-locks"
    rm -rf "$LOCK_DIR"
    mkdir -p "$LOCK_DIR"
}

teardown() {
    rm -rf /tmp/copycrow-test-locks
}

# ───────────────────────────────────────────────────────────────────────────────
# safety_lock_acquire / release
# ───────────────────────────────────────────────────────────────────────────────

@test "safety_lock_acquire: acquires a free lock" {
    run safety_lock_acquire "test_job"
    [ "$status" -eq 0 ]
    [ -f "${LOCK_DIR}/copycrow-test_job.lock" ]
}

@test "safety_lock_acquire: fails if lock is already active" {
    safety_lock_acquire "test_job" || true
    run safety_lock_acquire "test_job"
    [ "$status" -ne 0 ]
}

@test "safety_lock_acquire: succeeds over a stale lock file (PID is diagnostic only)" {
    echo "99999" > "${LOCK_DIR}/copycrow-test_job.lock"
    run safety_lock_acquire "test_job"
    [ "$status" -eq 0 ]
}

@test "safety_lock_release: removes the lock" {
    safety_lock_acquire "test_job" || true
    safety_lock_release
    [ ! -f "${LOCK_DIR}/copycrow-test_job.lock" ]
}

@test "safety_lock_run: executes under lock" {
    run safety_lock_run "test_job" bash -c 'echo "ran"; exit 0'
    [ "$status" -eq 0 ]
    [[ "$output" == *"ran"* ]]
}

@test "safety_lock_run: rejects if already locked" {
    safety_lock_acquire "test_job" || true
    run safety_lock_run "test_job" true
    [ "$status" -ne 0 ]
    [[ "$output" == *"already in progress"* ]]
}

@test "safety_lock_run: survives failing command under set -e and releases lock" {
    local dir="/tmp/copycrow-test-lockrun-$$"
    run bash -c '
        set -euo pipefail
        source "'"$COPYCROW_ROOT"'/src/safety.sh"
        LOCK_DIR="'"$dir"'"
        mkdir -p "$LOCK_DIR"
        safety_lock_run "rc_job" bash -c "exit 7" || rc=$?
        echo "rc=$rc"
        [ ! -e "$LOCK_DIR/copycrow-rc_job.lock" ] && echo "lock-released"
        rm -rf "$LOCK_DIR"
    '
    rm -rf "$dir"
    [ "$status" -eq 0 ]
    [[ "$output" == *"rc=7"* ]]
    [[ "$output" == *"lock-released"* ]]
}

@test "safety_lock_acquire: concurrent acquirers never overlap" {
    local dir="/tmp/copycrow-race-$$"
    rm -rf "$dir"
    mkdir -p "$dir"
    : > "$dir/winners"
    : > "$dir/overlaps"
    export LOCK_DIR="$dir"

    # Independent oracle (flock on serial.lock): several SEQUENTIAL winners
    # are legitimate (each lock is released on exit), but NEVER two
    # simultaneous holders.
    local i
    for i in {1..20}; do
        (
            if safety_lock_acquire "race_job" >/dev/null 2>&1; then
                echo W >> "$dir/winners"
                exec 9>"${dir}/serial.lock"
                if ! flock -n 9 2>/dev/null; then
                    echo OVL >> "$dir/overlaps"
                fi
                sleep 0.2
                flock -u 9 2>/dev/null || true
                exec 9>&-
                safety_lock_release 2>/dev/null || true
            fi
        ) &
    done
    wait

    local overlaps
    overlaps=$(grep -c OVL "$dir/overlaps" || true)
    rm -rf "$dir"
    [ "$overlaps" -eq 0 ]
}

# Deterministic reproduction of the unlink race: an acquirer that opens the
# lock file BEFORE a holder releases (flock+rm) and only flocks AFTER, ends
# up holding an ORPHANED inode while the path has been recreated — a third
# process then locks the new file and two "holders" coexist on one job.
# The shim freezes the racing acquirer between open and flock, so the
# interleaving is exact, not probabilistic.
_setup_race_shim() {
    local shim_dir="$1"
    mkdir -p "$shim_dir"
    cat > "$shim_dir/flock" << SHIM
#!/usr/bin/env bash
if [[ "\${1:-}" == "-n" && "\${2:-}" =~ ^[0-9]+\$ && -z "\${SHIM_DONE:-}" && ! -e "\${SHIM_DIR}/intercepted" ]]; then
    export SHIM_DONE=1
    : > "\${SHIM_DIR}/intercepted"
    : > "\${SHIM_DIR}/b-opened"
    local_i=0
    while [[ ! -e "\${SHIM_DIR}/release-done" ]] && (( local_i < 400 )); do
        sleep 0.05
        local_i=\$((local_i + 1))
    done
fi
exec "\${REAL_FLOCK}" "\$@"
SHIM
    chmod +x "$shim_dir/flock"
}

_wait_for_marker() {
    local f="$1" i
    for i in {1..400}; do
        [[ -e "$f" ]] && return 0
        sleep 0.05
    done
    echo "TIMEOUT waiting for marker: $f" >&2
    return 1
}

@test "safety_lock_acquire: unlink race never yields two simultaneous holders" {
    local dir="/tmp/copycrow-unlink-race-$$"
    rm -rf "$dir"
    mkdir -p "$dir/locks" "$dir/shim"
    export LOCK_DIR="$dir/locks"
    local lock_file="${LOCK_DIR}/copycrow-race_job.lock"

    # REAL_FLOCK resolved before the shim shadows PATH.
    local real_flock
    real_flock="$(command -v flock)"
    export REAL_FLOCK="$real_flock" SHIM_DIR="$dir/shim"
    _setup_race_shim "$dir/shim"

    # Holder A: takes the lock and waits for the signal to release.
    (
        bash -c '
            source "'"$COPYCROW_ROOT"'/src/safety.sh"
            LOCK_DIR="'"$LOCK_DIR"'"
            safety_lock_acquire race_job
            : > "'"$dir"'/a-held"
            until [[ -e "'"$dir"'/a-stop" ]]; do :; done
            safety_lock_release
            : > "'"$dir"'/a-released"
        '
    ) &
    local pid_a=$!
    _wait_for_marker "$dir/a-held"

    # Racer B: opens the lock fd while A still holds it; the shim parks it
    # there until A has unlocked, removed and the path has been recreated.
    # B then HOLDS whatever it acquired until C has tried: the invariant is
    # that a live holder must exclude every other acquirer.
    (
        bash -c '
            export PATH="'"$dir"'/shim:$PATH"
            source "'"$COPYCROW_ROOT"'/src/safety.sh"
            LOCK_DIR="'"$LOCK_DIR"'"
            brc=0
            safety_lock_acquire race_job >/dev/null 2>&1 || brc=$?
            echo "$brc" > "'"$dir"'/b-rc"
            if [[ "$brc" == "0" ]]; then
                : > "'"$dir"'/b-holding"
                i=0
                until [[ -e "'"$dir"'/c-done" ]] || (( ++i >= 400 )); do sleep 0.05; done
            fi
        '
    ) &
    local pid_b=$!
    _wait_for_marker "$dir/shim/b-opened"

    # A releases: unlock + rm of the inode B is parked on.
    : > "$dir/a-stop"
    _wait_for_marker "$dir/a-released"
    : > "$lock_file"   # a later acquirer recreates the path (new inode)

    # B un-parks: flocks the ORPHANED inode and stays alive holding it.
    : > "$dir/shim/release-done"
    _wait_for_marker "$dir/b-holding"

    # C: a plain acquirer, locking the freshly created file, while B lives.
    (
        bash -c '
            source "'"$COPYCROW_ROOT"'/src/safety.sh"
            LOCK_DIR="'"$LOCK_DIR"'"
            crc=0
            safety_lock_acquire race_job >/dev/null 2>&1 || crc=$?
            echo "$crc" > "'"$dir"'/c-rc"
        '
    ) &
    local pid_c=$!
    wait "$pid_c"
    : > "$dir/c-done"
    wait "$pid_b"
    wait "$pid_a"

    local b_rc c_rc
    b_rc="$(cat "$dir/b-rc")"
    c_rc="$(cat "$dir/c-rc")"
    rm -rf "$dir"

    echo "b_rc=$b_rc c_rc=$c_rc"
    [ "$b_rc" -eq 0 ]   # the race precondition: B believes it holds the job
    [ "$c_rc" -ne 0 ]   # the invariant: C must be rejected while B lives and holds
}

@test "_lock_inode_matches: matches fd and path on the same inode" {
    local f="/tmp/copycrow-inode-$$"
    printf 'x' > "$f"
    exec 8>> "$f"
    run _lock_inode_matches "$f" 8
    exec 8>&-
    rm -f "$f"
    [ "$status" -eq 0 ]
}

@test "_lock_inode_matches: detects a swapped path (orphaned fd)" {
    local d="/tmp/copycrow-inode-swap-$$"
    mkdir -p "$d"
    printf 'a' > "$d/f"
    exec 8>> "$d/f"
    rm -f "$d/f"        # the fd now points at an unlinked inode
    printf 'b' > "$d/f" # a new inode sits at the path
    run _lock_inode_matches "$d/f" 8
    exec 8>&-
    rm -rf "$d"
    [ "$status" -ne 0 ]
}

@test "_lock_inode_matches: vanished path is a mismatch (retry recreates it)" {
    local d="/tmp/copycrow-inode-gone-$$"
    mkdir -p "$d"
    printf 'a' > "$d/f"
    exec 8>> "$d/f"
    rm -f "$d/f"
    run _lock_inode_matches "$d/f" 8
    exec 8>&-
    rm -rf "$d"
    [ "$status" -ne 0 ]
}

@test "safety_init: registers SIGHUP handler" {
    run bash -c 'source "'"$COPYCROW_ROOT"'/src/safety.sh"; safety_init; trap -p HUP'
    [ "$status" -eq 0 ]
    [[ "$output" == *HUP* ]]
}

@test "safety_lock_acquire: stale recovery is atomic over a dead-PID lock" {
    local dir="/tmp/copycrow-stale-$$"
    rm -rf "$dir"
    mkdir -p "$dir"
    : > "$dir/winners"
    : > "$dir/overlaps"
    export LOCK_DIR="$dir"

    # Real reaped dead PID: the lock is undeniably orphaned.
    bash -c 'exit 0' &
    local dead_pid=$!
    wait "$dead_pid"
    printf '%s\n' "$dead_pid" > "${dir}/copycrow-stale_job.lock"

    # Start gate: all 25 racers compete at the same instant.
    # Overlap oracle INDEPENDENT of the product's mechanism: each winner
    # takes an exclusive flock on serial.lock; if two winners overlap,
    # flock -n fails and gets recorded. Late arrivals after a legitimate
    # release serialize without false positives.
    local gate_go="${dir}.go"
    rm -f "$gate_go"
    local i
    for i in {1..25}; do
        (
            until [[ -e "$gate_go" ]]; do :; done
            if safety_lock_acquire "stale_job" >/dev/null 2>&1; then
                echo W >> "$dir/winners"
                exec 9>"${dir}/serial.lock"
                if ! flock -n 9 2>/dev/null; then
                    echo OVL >> "$dir/overlaps"
                fi
                sleep 0.3
                flock -u 9 2>/dev/null || true
                exec 9>&-
                safety_lock_release 2>/dev/null || true
            fi
        ) &
    done
    touch "$gate_go"
    wait

    local winners overlaps
    winners=$(grep -c W "$dir/winners" || true)
    overlaps=$(grep -c OVL "$dir/overlaps" || true)
    rm -rf "$dir" "$gate_go"
    [ "$overlaps" -eq 0 ]
    [ "$winners" -ge 1 ]
}
