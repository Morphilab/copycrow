#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# Tests for completions/copycrow.bash (pure functions; no terminal needed).
# ═══════════════════════════════════════════════════════════════════════════════

setup() {
    export COPYCROW_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export COPYCROW_TEST_SANDBOX="$(mktemp -d /tmp/copycrow-comp-XXXXXX)"
    export COPYCROW_CONF="${COPYCROW_TEST_SANDBOX}/test.conf"
    cat > "$COPYCROW_CONF" << 'EOF'
[global]

[daily_job]
type = automatic
host = nas
remote_path = /b/d

[weekly_job]
type = manual
host = other
remote_path = /b/w

[extra_job]
type = manual
host = nas
remote_path = /b/x
EOF
    source "${COPYCROW_ROOT}/completions/copycrow.bash"
}

teardown() {
    rm -rf "$COPYCROW_TEST_SANDBOX"
}

@test "_copycrow_commands: covers the full dispatcher surface" {
    local want
    for want in init backup manual auto dryrun list open migrate install \
                uninstall status verify verify-all doctor help --version; do
        grep -qx "$want" < <(_copycrow_commands) || return 1
    done
}

@test "_copycrow_jobs: parses sections from active conf, excluding global" {
    run _copycrow_jobs
    [ "$status" -eq 0 ]
    [[ "$output" == *"daily_job"* ]]
    [[ "$output" == *"weekly_job"* ]]
    [[ "$output" == *"extra_job"* ]]
    ! grep -qx "global" <<< "$output"
}

@test "_copycrow_hosts: distinct hosts only" {
    run _copycrow_hosts
    # nas (x2) + other → dedup leaves 2
    [ "$(grep -c . <<< "$output")" -eq 2 ]
    grep -qx "nas" <<< "$output"
    grep -qx "other" <<< "$output"
}

@test "COMPREPLY: completes commands by prefix" {
    COMP_WORDS=(copycrow ver)
    COMP_CWORD=1
    COMP_LINE="copycrow ver"
    COMP_POINT=${#COMP_LINE}
    COMPREPLY=()
    _copycrow
    [ "${#COMPREPLY[@]}" -eq 2 ]
    [[ " ${COMPREPLY[*]} " == *" verify "* ]]
    [[ " ${COMPREPLY[*]} " == *" verify-all "* ]]
}
