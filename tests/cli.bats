#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# Integration tests for copycrow.sh dispatcher.
# Uses COPYCROW_CONF env override so the project's real conf is NEVER touched.
# No borg execution happens here: only parsing/validation/dry-run paths.
# ═══════════════════════════════════════════════════════════════════════════════

setup() {
    export COPYCROW_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export COPYCROW_TEST_SANDBOX="$(mktemp -d /tmp/copycrow-cli-XXXXXX)"
    export COPYCROW_CONF="${COPYCROW_TEST_SANDBOX}/test.conf"
    cat > "$COPYCROW_CONF" << 'EOF'
[global]
retention_default = --keep-daily 7
compression = lz4
manual_prefix = manual-
auto_prefix = auto-

[dry_job]
type = manual
sources = /home
host = local
remote_path = /tmp/copycrow-cli-repo
EOF
}

teardown() {
    rm -rf "$COPYCROW_TEST_SANDBOX"
}

@test "help: exits 0 and shows usage" {
    run "${COPYCROW_ROOT}/copycrow.sh" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]]
}

@test "dryrun: prints the plan without executing anything" {
    run "${COPYCROW_ROOT}/copycrow.sh" dryrun dry_job
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN"* ]]
    [[ "$output" == *"borg create"* ]]
    [[ "$output" == *"::manual-"* ]]
}

@test "dryrun: fails fast when a value fails validation" {
    cat > "$COPYCROW_CONF" << 'EOF'
[global]
compression = nope

[job_x]
type = manual
sources = /home
host = local
remote_path = /tmp/r
EOF
    run "${COPYCROW_ROOT}/copycrow.sh" dryrun job_x
    [ "$status" -ne 0 ]
    [[ "$output" == *"compression"* ]]
}

@test "dryrun: fails fast when required fields are missing" {
    cat > "$COPYCROW_CONF" << 'EOF'
[global]

[job_x]
type = manual
sources = /home
EOF
    run "${COPYCROW_ROOT}/copycrow.sh" dryrun job_x
    [ "$status" -ne 0 ]
    [[ "$output" == *"host"* ]]
}

@test "backup: unknown job fails clearly" {
    run "${COPYCROW_ROOT}/copycrow.sh" backup no_such_job
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}

@test "auto: requires a job argument" {
    run "${COPYCROW_ROOT}/copycrow.sh" auto
    [ "$status" -ne 0 ]
    [[ "$output" == *"must specify a job"* ]]
}

@test "unknown command: errors with hint" {
    run "${COPYCROW_ROOT}/copycrow.sh" frobnicate
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown command"* ]]
}
