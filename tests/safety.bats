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

    # Oráculo independiente (flock sobre serial.lock): puede haber varios
    # ganadores SECUENCIALES legítimos (cada lock se libera al salir), pero
    # NUNCA dos holders simultáneos.
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

    # PID muerto real (reaped): el lock es indiscutiblemente huérfano.
    bash -c 'exit 0' &
    local dead_pid=$!
    wait "$dead_pid"
    printf '%s\n' "$dead_pid" > "${dir}/copycrow-stale_job.lock"

    # Puerta de salida: los 25 corredores compiten en el mismo instante.
    # Oráculo de solapamiento INDEPENDIENTE del mecanismo del producto:
    # cada ganador toma flock exclusivo sobre serial.lock; si dos ganadores
    # se solapan, flock -n falla y queda registrado. Llegadas tardías tras
    # un release legítimo serializan sin falsos positivos.
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
