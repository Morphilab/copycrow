#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════════════════════
# Tests for backup-core.sh
# Dependency: bats-core
# borg is STUBBED via PATH for failure-path tests (no real backups here).
# ═══════════════════════════════════════════════════════════════════════════════

setup() {
    export COPYCROW_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    source "${COPYCROW_ROOT}/src/config-parser.sh"
    source "${COPYCROW_ROOT}/src/backup-core.sh"

    export COPYCROW_TEST_SANDBOX="$(mktemp -d /tmp/copycrow-core-XXXXXX)"
    export PATH_STUB_DIR="$COPYCROW_TEST_SANDBOX/bin"
    mkdir -p "$PATH_STUB_DIR"
}

teardown() {
    rm -rf "$COPYCROW_TEST_SANDBOX"
}

# Write a conf inside the sandbox and load it (state survives: bare call).
# Heredoc is UNQUOTED on purpose: fixtures may expand $COPYCROW_TEST_SANDBOX.
_load_conf() {
    local conf="${COPYCROW_TEST_SANDBOX}/test.conf"
    cat > "$conf"
    config_load "$conf" 2>"${COPYCROW_TEST_SANDBOX}/load.err"
}

_stub_borg() {
    # $1 = exit code for create/prune/extract, $2 = optional stderr text
    local fail_code="${1:-0}"
    local fail_msg="${2:-}"
    cat > "${PATH_STUB_DIR}/borg" << EOF
#!/usr/bin/env bash
case "\$1" in
    info) exit 0 ;;
esac
if [ -n "${fail_msg}" ]; then printf '%s\n' '${fail_msg}' >&2; fi
exit ${fail_code}
EOF
    chmod +x "${PATH_STUB_DIR}/borg"
    export PATH="${PATH_STUB_DIR}:${PATH}"
}

# ───────────────────────────────────────────────────────────────────────────────
# _json_escape
# ───────────────────────────────────────────────────────────────────────────────

@test "_json_escape: escapes quotes, backslashes and newlines" {
    run _json_escape 'say "hi"\new'
    [ "$output" = 'say \"hi\"\\new' ]
}

@test "_json_escape: passes plain values untouched" {
    run _json_escape '/backups/copycrow'
    [ "$output" = '/backups/copycrow' ]
}

# ───────────────────────────────────────────────────────────────────────────────
# backup_build_repo_url / backup_safe_archive_name
# ───────────────────────────────────────────────────────────────────────────────

@test "backup_build_repo_url: local host returns raw path" {
    run backup_build_repo_url "local" "/mnt/disk/repo"
    [ "$output" = "/mnt/disk/repo" ]
}

@test "backup_build_repo_url: remote host builds ssh URL" {
    run backup_build_repo_url "nas-backup" "/backups/copycrow/daily"
    [ "$output" = "ssh://nas-backup/backups/copycrow/daily" ]
}

@test "backup_safe_archive_name: accepts timestamped archive names" {
    run backup_safe_archive_name "auto-20260603-153000"
    [ "$status" -eq 0 ]
    run backup_safe_archive_name "manual-20260603_153000.tar.gz"
    [ "$status" -eq 0 ]
}

@test "backup_safe_archive_name: rejects traversal and shell metacharacters" {
    for bad in "../../etc" "a/b" ".." ".hidden" "-oProxyCommand" 'x;y' 'x$y' '`id`' ""; do
        run backup_safe_archive_name "$bad"
        [ "$status" -ne 0 ] || return 1
    done
}

# ───────────────────────────────────────────────────────────────────────────────
# backup_get_repo_urls_for_host (M3: all repos per host, not just the first)
# ───────────────────────────────────────────────────────────────────────────────

@test "backup_get_repo_urls_for_host: returns every distinct repo of a host" {
    _load_conf << 'EOF'
[global]

[daily]
type = automatic
sources = /home
host = nas
remote_path = /backups/daily

[weekly]
type = automatic
sources = /home
host = nas
remote_path = /backups/weekly

[other]
type = manual
sources = /home
host = other-host
remote_path = /elsewhere

[dupe]
type = manual
sources = /home
host = nas
remote_path = /backups/daily
EOF

    run backup_get_repo_urls_for_host "nas"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ssh://nas/backups/daily"* ]]
    [[ "$output" == *"ssh://nas/backups/weekly"* ]]
    [[ "$output" != *"ssh://nas/backups/daily"*"ssh://nas/backups/daily"* ]]
    [[ "$output" != *"/elsewhere"* ]]
}

# ───────────────────────────────────────────────────────────────────────────────
# Failure-path handling (H4): borg failures must never kill the process.
# ───────────────────────────────────────────────────────────────────────────────

@test "backup_prune: borg failure is logged and non-fatal" {
    _stub_borg 2 "simulated prune failure"

    _load_conf << EOF
[global]
logs_dir = ${COPYCROW_TEST_SANDBOX}/logs-sandbox

[prune_job]
type = manual
sources = /home
host = local
remote_path = ${COPYCROW_TEST_SANDBOX}/repo
retention = --keep-daily 7
EOF

    run backup_prune "prune_job"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Retention policy application failed"* ]]
}

@test "_run_capture: captures output and exit code without killing set -e" {
    run bash -c '
        source "'"${COPYCROW_ROOT}"'/src/backup-core.sh"
        f() {
            local out="" rc=0
            _run_capture out false || rc=$?
            printf "%s|%s" "$rc" "$out"
        }
        f
    '
    # `false` produces empty output with code 1 — and the shell SURVIVES.
    [ "$status" -eq 0 ]
    [[ "$output" == "1|"* ]]
}
