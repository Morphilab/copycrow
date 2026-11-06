#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════════════════════
# Integration tests: the full CLI backup lifecycle against REAL borg.
# The unit suite stubs borg, which can mask argument bugs (repo URL shape,
# `--` before sources, prune flags, auto-initialized encryption). These tests
# drive the real binary end to end. Skipped when borg is not installed.
#
# Isolation: sources are COPIED into the sandbox so COPYCROW_ROOT (locks,
# logs, mount_dir) resolves inside /tmp — never the real project tree.
# BORG_PASSPHRASE is exported for the test process only; nothing is persisted.
# ═══════════════════════════════════════════════════════════════════════════════

setup() {
    if ! command -v borg >/dev/null 2>&1; then
        skip "borg not installed (integration tests require it)"
    fi

    export COPYCROW_TEST_SANDBOX="$(mktemp -d /tmp/copycrow-integ-XXXXXX)"
    local proj="${COPYCROW_TEST_SANDBOX}/proj"
    mkdir -p "$proj"

    # Copy sources so COPYCROW_ROOT points at the sandbox.
    cp -r "$(dirname "$BATS_TEST_FILENAME")/../src" "$proj/"
    cp "$(dirname "$BATS_TEST_FILENAME")/../copycrow.sh" "$proj/"
    export COPYCROW_ROOT="$proj"

    # Deterministic, non-interactive borg environment: sandboxed cache,
    # config and security state (borg writes a per-repo dir under the
    # security dir; leaving it unset pollutes the real ~/.config/borg of
    # whoever runs the suite) and passphrase supplied via env (standard borg
    # mechanism, never on disk).
    export BORG_CACHE_DIR="${COPYCROW_TEST_SANDBOX}/borgcache"
    export BORG_CONFIG_DIR="${COPYCROW_TEST_SANDBOX}/borgconfig"
    export BORG_SECURITY_DIR="${COPYCROW_TEST_SANDBOX}/borgsecurity"
    export BORG_PASSPHRASE="integ-pass"

    mkdir -p "${COPYCROW_TEST_SANDBOX}/data" "${COPYCROW_TEST_SANDBOX}/logs"
    printf 'integration-fixture\n' > "${COPYCROW_TEST_SANDBOX}/data/archivo.txt"

    export COPYCROW_CONF="${COPYCROW_TEST_SANDBOX}/test.conf"
    cat > "$COPYCROW_CONF" << EOF
[global]
compression = lz4
mount_dir = .mnt
logs_dir = ${COPYCROW_TEST_SANDBOX}/logs
manual_prefix = manual-

[integ_job]
type = manual
sources = ${COPYCROW_TEST_SANDBOX}/data
host = local
remote_path = ${COPYCROW_TEST_SANDBOX}/repo
retention = --keep-last 1
EOF

    # Module functions (backup_extract) run in-process, like the extract suite.
    source "${COPYCROW_ROOT}/src/config-parser.sh"
    source "${COPYCROW_ROOT}/src/safety.sh"
    source "${COPYCROW_ROOT}/src/backup-core.sh"
    config_load "$COPYCROW_CONF" 2>/dev/null
}

teardown() {
    rm -rf "${COPYCROW_TEST_SANDBOX:-}"
}

@test "E2E: backup initializes an encrypted repo and creates the archive" {
    run "${COPYCROW_ROOT}/copycrow.sh" backup integ_job
    [ "$status" -eq 0 ]
    [[ "$output" == *"Backup created: manual-"* ]]

    # Real repo, real archive, exactly one (--keep-last 1 already pruned).
    run borg list --short "${COPYCROW_TEST_SANDBOX}/repo"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [[ "$output" == manual-* ]]
}

@test "E2E: retention prunes older archives down to --keep-last 1" {
    run "${COPYCROW_ROOT}/copycrow.sh" backup integ_job
    [ "$status" -eq 0 ]
    sleep 1 # archive names have second granularity

    run "${COPYCROW_ROOT}/copycrow.sh" backup integ_job
    [ "$status" -eq 0 ]

    run borg list --short "${COPYCROW_TEST_SANDBOX}/repo"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
}

@test "E2E: list, verify and verify-all operate on the real repository" {
    run "${COPYCROW_ROOT}/copycrow.sh" backup integ_job
    [ "$status" -eq 0 ]

    run "${COPYCROW_ROOT}/copycrow.sh" list integ_job
    [ "$status" -eq 0 ]
    [[ "$output" == *manual-* ]]

    run "${COPYCROW_ROOT}/copycrow.sh" verify integ_job
    [ "$status" -eq 0 ]
    [[ "$output" == *"Repository OK"* ]]

    run "${COPYCROW_ROOT}/copycrow.sh" verify-all
    [ "$status" -eq 0 ]
    [[ "$output" == *"All repositories verified OK."* ]]
}

@test "E2E: backup_extract unpacks an archive created by the CLI" {
    run "${COPYCROW_ROOT}/copycrow.sh" backup integ_job
    [ "$status" -eq 0 ]

    local archive
    archive="$(borg list --short "${COPYCROW_TEST_SANDBOX}/repo" | head -1)"
    [ -n "$archive" ]

    run backup_extract "local" "$archive"
    [ "$status" -eq 0 ]

    # Absolute sources are archived without the leading slash: locate the
    # fixture instead of hardcoding the reproduced directory layout.
    local found
    found="$(find "${COPYCROW_ROOT}/.mnt/${archive}" -name archivo.txt -print -quit)"
    [ -n "$found" ]
}

@test "E2E: a wrong passphrase fails cleanly (nonzero, never hangs)" {
    run "${COPYCROW_ROOT}/copycrow.sh" backup integ_job
    [ "$status" -eq 0 ]

    run timeout 60 env BORG_PASSPHRASE="wrong-pass" \
        "${COPYCROW_ROOT}/copycrow.sh" backup integ_job </dev/null
    [ "$status" -ne 0 ]
    [ "$status" -ne 124 ] # 124 = timeout killed a hung (prompting) process
    [[ "$output" != *"Backup created:"* ]]
    # The repository EXISTS: the failure must point at the credentials, not
    # send the operator to initialize anything.
    [[ "$output" != *"Could not initialize repository"* ]]
    [[ "$output" == *"cannot be opened"* ]]
}

@test "E2E: borg state dirs stay inside the sandbox (no HOME pollution)" {
    local var value
    for var in BORG_CACHE_DIR BORG_CONFIG_DIR BORG_SECURITY_DIR; do
        value="${!var:-}"
        [ -n "$value" ]
        [[ "$value" == "${COPYCROW_TEST_SANDBOX}/"* ]]
    done
}
