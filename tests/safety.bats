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

@test "safety_lock_acquire: detects stale lock (dead PID)" {
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

@test "safety_lock_acquire: only one of 20 concurrent acquirers wins" {
    local dir="/tmp/copycrow-race-$$"
    rm -rf "$dir"
    mkdir -p "$dir"
    : > "$dir/winners"
    export LOCK_DIR="$dir"

    local i
    for i in {1..20}; do
        (
            if safety_lock_acquire "race_job" >/dev/null 2>&1; then
                echo W >> "$dir/winners"
            fi
        ) &
    done
    wait

    local count
    count=$(grep -c W "$dir/winners" || true)
    rm -rf "$dir"
    [ "$count" -le 1 ]
}

@test "safety_init: registers SIGHUP handler" {
    run bash -c 'source "'"$COPYCROW_ROOT"'/src/safety.sh"; safety_init; trap -p HUP'
    [ "$status" -eq 0 ]
    [[ "$output" == *HUP* ]]
}
