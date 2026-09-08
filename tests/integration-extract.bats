#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════════════════════
# Integration tests: backup_extract against REAL borg.
# The unit suite stubs borg, which can mask argument bugs.
# These tests exercise the actual binary. Skipped when borg is not installed.
#
# Isolation: modules are COPIED into the sandbox so COPYCROW_ROOT (and hence
# the extraction mount_dir) resolves inside /tmp — never the real project tree.
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
    source "${COPYCROW_ROOT}/src/config-parser.sh"
    source "${COPYCROW_ROOT}/src/safety.sh"
    source "${COPYCROW_ROOT}/src/backup-core.sh"

    # Deterministic borg environment (no cache pollution, no interactive prompt).
    export BORG_CACHE_DIR="${COPYCROW_TEST_SANDBOX}/borgcache"
    export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes

    mkdir -p "${COPYCROW_TEST_SANDBOX}/data" "${COPYCROW_TEST_SANDBOX}/repo" "${COPYCROW_ROOT}/logs"
    printf 'integration-fixture\n' > "${COPYCROW_TEST_SANDBOX}/data/archivo.txt"

    borg init --encryption=none "${COPYCROW_TEST_SANDBOX}/repo" 2>/dev/null
    # Relative source path: the archive stores `data/...`, so extraction lands
    # directly under .mnt/<archive>/data/archivo.txt.
    ( cd "$COPYCROW_TEST_SANDBOX" && borg create "${COPYCROW_TEST_SANDBOX}/repo::manual-20260101-000000" data )

    local conf="${COPYCROW_TEST_SANDBOX}/test.conf"
    cat > "$conf" << EOF
[global]
compression = lz4
mount_dir = .mnt
logs_dir = ${COPYCROW_TEST_SANDBOX}/logs-sandbox

[integ_job]
type = manual
sources = ${COPYCROW_TEST_SANDBOX}/data
host = local
remote_path = ${COPYCROW_TEST_SANDBOX}/repo
EOF
    config_load "$conf" 2>/dev/null
}

teardown() {
    rm -rf "${COPYCROW_TEST_SANDBOX:-}"
}

@test "backup_extract: extracts archive contents with real borg" {
    run backup_extract "local" "manual-20260101-000000"
    [ "$status" -eq 0 ]
    [ -f "${COPYCROW_ROOT}/.mnt/manual-20260101-000000/data/archivo.txt" ]
}

@test "backup_extract: extracted files are not world-readable (umask 077 end-to-end)" {
    run backup_extract "local" "manual-20260101-000000"
    [ "$status" -eq 0 ]
    local f="${COPYCROW_ROOT}/.mnt/manual-20260101-000000/data/archivo.txt"
    [ -f "$f" ]
    local mode
    mode="$(stat -c '%a' "$f")"
    # No read bit for "others" in the file's octal mode.
    (( (8#$mode & 8#4) == 0 ))
}
