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

@test "backup_build_repo_url: remote host builds ABSOLUTE ssh URL (double slash)" {
    # borg treats ssh://host/path as RELATIVE to the remote home; absolute
    # requires the double slash (validation demands /abs paths, so the
    # URL must preserve absoluteness).
    run backup_build_repo_url "nas-backup" "/backups/copycrow/daily"
    [ "$output" = "ssh://nas-backup//backups/copycrow/daily" ]
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
# backup_get_repo_urls_for_host (all repos per host, not just the first)
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
    [[ "$output" == *"ssh://nas//backups/daily"* ]]
    [[ "$output" == *"ssh://nas//backups/weekly"* ]]
    [[ "$output" != *"ssh://nas//backups/daily"*"ssh://nas//backups/daily"* ]]
    [[ "$output" != *"/elsewhere"* ]]
}

@test "backup_list: filters archives by prefix literally (regex metachars in names are safe)" {
    # Put the stub dir on PATH first (generic stub), then override with a
    # listing-specific fake.
    _stub_borg 0
    cat > "${PATH_STUB_DIR}/borg" << 'STUB'
#!/usr/bin/env bash
if [ "$1" = "list" ]; then
    printf '%s\n' "auto-20260101-000000" "manual-20260101-000000" "auto-(weird)-name" "other"
fi
exit 0
STUB
    chmod +x "${PATH_STUB_DIR}/borg"

    _load_conf << EOF
[global]
logs_dir = ${COPYCROW_TEST_SANDBOX}/logs-sandbox
auto_prefix = auto-
manual_prefix = manual-

[list_job]
type = manual
sources = /home
host = local
remote_path = ${COPYCROW_TEST_SANDBOX}/repo
EOF

    run backup_list "local" "auto"
    [ "$status" -eq 0 ]
    [[ "$output" == *"auto-20260101-000000"* ]]
    [[ "$output" == *"auto-(weird)-name"* ]]
    [[ "$output" != *"manual-"* ]]
}

# ───────────────────────────────────────────────────────────────────────────────
# Failure-path handling: borg failures must never kill the process.
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

@test "_run_capture: registers its tempfile with safety_add_temp (signal-safe cleanup)" {
    run bash -c '
        source "'"${COPYCROW_ROOT}"'/src/safety.sh"
        source "'"${COPYCROW_ROOT}"'/src/backup-core.sh"
        out=""
        _run_capture out true || true
        printf "%s\n" "${TEMP_FILES[@]:-}"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *copycrow-cap.* ]]
}

# ───────────────────────────────────────────────────────────────────────────────
# Log retention
# ───────────────────────────────────────────────────────────────────────────────

_make_old_log() {
    mkdir -p "${COPYCROW_TEST_SANDBOX}/logs-sandbox"
    touch -d '2020-01-01' "${COPYCROW_TEST_SANDBOX}/logs-sandbox/copycrow-20200101.log"
}

@test "backup_purge_old_logs: deletes old copycrow logs only (default 30 days)" {
    _load_conf << EOF
[global]
logs_dir = ${COPYCROW_TEST_SANDBOX}/logs-sandbox

[j]
type = manual
sources = /home
host = local
remote_path = /tmp/repo
EOF
    _make_old_log
    : > "${COPYCROW_TEST_SANDBOX}/logs-sandbox/other-tool.log"
    : > "${COPYCROW_TEST_SANDBOX}/logs-sandbox/copycrow-today.log"

    run backup_purge_old_logs
    [ "$status" -eq 0 ]
    [ ! -e "${COPYCROW_TEST_SANDBOX}/logs-sandbox/copycrow-20200101.log" ]
    [ -e "${COPYCROW_TEST_SANDBOX}/logs-sandbox/other-tool.log" ]
    [ -e "${COPYCROW_TEST_SANDBOX}/logs-sandbox/copycrow-today.log" ]
}

@test "backup_purge_old_logs: honors configured logs_retention_days" {
    _load_conf << EOF
[global]
logs_dir = ${COPYCROW_TEST_SANDBOX}/logs-sandbox
logs_retention_days = 36500

[j]
type = manual
sources = /home
host = local
remote_path = /tmp/repo
EOF
    _make_old_log
    run backup_purge_old_logs
    [ "$status" -eq 0 ]
    [ -e "${COPYCROW_TEST_SANDBOX}/logs-sandbox/copycrow-20200101.log" ]
}

@test "backup_create: purges old logs on success AND on failure" {
    _load_conf << EOF
[global]
logs_dir = ${COPYCROW_TEST_SANDBOX}/logs-sandbox
retention_default = --keep-daily 7

[purge_job]
type = manual
sources = /home
host = local
remote_path = ${COPYCROW_TEST_SANDBOX}/repo
EOF
    _stub_borg 0
    _make_old_log
    run backup_create purge_job manual
    [ "$status" -eq 0 ]
    [ ! -e "${COPYCROW_TEST_SANDBOX}/logs-sandbox/copycrow-20200101.log" ]

    _stub_borg 2 "simulated failure"
    _make_old_log
    run backup_create purge_job manual
    [ "$status" -ne 0 ]
    [ ! -e "${COPYCROW_TEST_SANDBOX}/logs-sandbox/copycrow-20200101.log" ]
}

# ───────────────────────────────────────────────────────────────────────────────
# Dry-run prints a single Retention line; multi-repo listing is deduplicated
# ───────────────────────────────────────────────────────────────────────────────

@test "dryrun: exactly one Retention line — job override wins" {
    _load_conf << EOF
[global]
retention_default = --keep-daily 7

[dry_ret_job]
type = manual
sources = /home
host = local
remote_path = /tmp/repo
retention = --keep-weekly 4
EOF
    run backup_create dry_ret_job manual true
    [ "$status" -eq 0 ]
    [ "$(grep -c 'Retention:' <<< "$output")" -eq 1 ]
    [[ "$output" == *"--keep-weekly 4"* ]]
}

@test "dryrun: exactly one Retention line — global default when job has none" {
    _load_conf << EOF
[global]
retention_default = --keep-daily 7

[dry_def_job]
type = manual
sources = /home
host = local
remote_path = /tmp/repo
EOF
    run backup_create dry_def_job manual true
    [ "$status" -eq 0 ]
    [ "$(grep -c 'Retention:' <<< "$output")" -eq 1 ]
    [[ "$output" == *"(default: --keep-daily 7)"* ]]
}

@test "backup_list: deduplicates archives present in several repos of one host" {
    _stub_borg 0
    cat > "${PATH_STUB_DIR}/borg" << 'STUB'
#!/usr/bin/env bash
if [ "$1" = "list" ]; then
    printf '%s\n' "auto-20260101-000000" "shared-archive" "auto-20260102-000000"
fi
exit 0
STUB
    chmod +x "${PATH_STUB_DIR}/borg"

    _load_conf << EOF
[global]
auto_prefix = auto-

[r1]
type = manual
sources = /home
host = multi
remote_path = /backups/r1

[r2]
type = manual
sources = /home
host = multi
remote_path = /backups/r2
EOF

    run backup_list "multi" "all"
    [ "$status" -eq 0 ]
    [ "$(grep -cx 'auto-20260101-000000' <<< "$output")" -eq 1 ]
    [ "$(grep -cx 'shared-archive' <<< "$output")" -eq 1 ]
    [ "$(grep -cx 'auto-20260102-000000' <<< "$output")" -eq 1 ]
}

# ───────────────────────────────────────────────────────────────────────────────
# B10: prompts crudos prohibidos bajo la TUI
# ───────────────────────────────────────────────────────────────────────────────

@test "_interactive_stdin_available: false when COPYCROW_UNDER_TUI is set" {
    run bash -c '
        source "'"${COPYCROW_ROOT}"'/src/backup-core.sh"
        declare -F _interactive_stdin_available >/dev/null || { echo MISSING; exit 1; }
        export COPYCROW_UNDER_TUI=1
        if _interactive_stdin_available; then echo ON; else echo OFF; fi
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"OFF"* ]]
}

@test "_interactive_stdin_available: false on plain non-TTY stdin" {
    run bash -c '
        source "'"${COPYCROW_ROOT}"'/src/backup-core.sh"
        declare -F _interactive_stdin_available >/dev/null || { echo MISSING; exit 1; }
        if _interactive_stdin_available; then echo ON; else echo OFF; fi
    ' < /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"OFF"* ]]
}

# ───────────────────────────────────────────────────────────────────────────────
# on_failure_cmd hook
# ───────────────────────────────────────────────────────────────────────────────

_make_hook_recorder() {
    export HOOK_LOG="${COPYCROW_TEST_SANDBOX}/hook.log"
    : > "$HOOK_LOG"
    cat > "${PATH_STUB_DIR}/onfail-recorder" << REC
#!/usr/bin/env bash
printf '%s|%s|%s\n' "\$COPYCROW_FAILED_JOB" "\$COPYCROW_FAILURE_ARCHIVE" "\$COPYCROW_FAILURE_EXIT_CODE" >> "\$HOOK_LOG"
REC
    chmod +x "${PATH_STUB_DIR}/onfail-recorder"
}

@test "backup_notify_failure: runs hook with failure-context env vars" {
    _make_hook_recorder
    _load_conf << EOF
[global]
on_failure_cmd = ${PATH_STUB_DIR}/onfail-recorder

[j]
type = manual
sources = /home
host = local
remote_path = /tmp/repo
EOF
    run backup_notify_failure myjob auto-X 2
    [ "$status" -eq 0 ]
    [ "$(cat "$HOOK_LOG")" = "myjob|auto-X|2" ]
}

@test "backup_notify_failure: failing hook is logged WARN but never propagates" {
    _make_hook_recorder
    cat > "${PATH_STUB_DIR}/onfail-recorder" << 'REC'
#!/usr/bin/env bash
exit 9
REC
    chmod +x "${PATH_STUB_DIR}/onfail-recorder"
    _load_conf << EOF
[global]
logs_dir = ${COPYCROW_TEST_SANDBOX}/logs-sandbox
on_failure_cmd = ${PATH_STUB_DIR}/onfail-recorder

[j]
type = manual
sources = /home
host = local
remote_path = /tmp/repo
EOF
    run backup_notify_failure myjob auto-X 3
    [ "$status" -eq 0 ]
    grep -q '"action":"notify"' "${COPYCROW_TEST_SANDBOX}/logs-sandbox/"copycrow-*.log
    grep -q '"status":"failed"' "${COPYCROW_TEST_SANDBOX}/logs-sandbox/"copycrow-*.log
}

@test "backup_create: fires on_failure_cmd when borg fails; silent on success" {
    _make_hook_recorder
    _load_conf << EOF
[global]
logs_dir = ${COPYCROW_TEST_SANDBOX}/logs-sandbox
on_failure_cmd = ${PATH_STUB_DIR}/onfail-recorder

[hook_job]
type = manual
sources = /home
host = local
remote_path = ${COPYCROW_TEST_SANDBOX}/repo
EOF
    _stub_borg 2 "boom"
    run backup_create hook_job manual
    [ "$status" -ne 0 ]
    grep -q '^hook_job|' "$HOOK_LOG"

    rm -f "$HOOK_LOG"; : > "$HOOK_LOG"
    _stub_borg 0
    run backup_create hook_job manual
    [ "$status" -eq 0 ]
    [ ! -s "$HOOK_LOG" ]
}

@test "backup_create: fires hook when prerequisites fail (no sources exist)" {
    _make_hook_recorder
    _load_conf << EOF
[global]
logs_dir = ${COPYCROW_TEST_SANDBOX}/logs-sandbox
on_failure_cmd = ${PATH_STUB_DIR}/onfail-recorder

[hookp_job]
type = manual
sources = /nonexistent-path-xyz
host = local
remote_path = ${COPYCROW_TEST_SANDBOX}/repo
EOF
    _stub_borg 0
    run backup_create hookp_job manual
    [ "$status" -ne 0 ]
    grep -q '^hookp_job|' "$HOOK_LOG"
}
