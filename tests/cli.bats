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

@test "onboarding: setup texts never recommend exporting BORG_PASSPHRASE" {
    # Timers cannot answer prompts: recommending `export BORG_PASSPHRASE` as a
    # setup step sets users up for failure. Only BORG_PASSCOMMAND may appear.
    ! grep -rn "export BORG_PASSPHRASE" \
        "${COPYCROW_ROOT}/copycrow.sh" \
        "${COPYCROW_ROOT}/copycrow.conf.example"
    grep -q "BORG_PASSCOMMAND" "${COPYCROW_ROOT}/copycrow.conf.example"
}

@test "--version: prints VERSION file content" {
    run "${COPYCROW_ROOT}/copycrow.sh" --version
    [ "$status" -eq 0 ]
    [ "$output" == "$(cat "${COPYCROW_ROOT}/VERSION")" ]

    run "${COPYCROW_ROOT}/copycrow.sh" -V
    [ "$status" -eq 0 ]
    [ "$output" == "$(cat "${COPYCROW_ROOT}/VERSION")" ]
}

@test "backup: rejects extra arguments" {
    run "${COPYCROW_ROOT}/copycrow.sh" backup dry_job extra_arg
    [ "$status" -ne 0 ]
    [[ "$output" == *"Too many arguments"* ]]
}

@test "open: rejects more than two arguments" {
    run "${COPYCROW_ROOT}/copycrow.sh" open host arch surplus
    [ "$status" -ne 0 ]
    [[ "$output" == *"Too many arguments"* ]]
}

@test "arity: no-operand commands reject surplus arguments" {
    # P2-11: el claim de aridad era selectivo; init/migrate/install/uninstall/
    # status ignoraban argumentos sobrantes en silencio.
    local cmd
    for cmd in status install uninstall init; do
        run "${COPYCROW_ROOT}/copycrow.sh" "$cmd" SURPLUS_ARG
        [ "$status" -ne 0 ] || { echo "command '$cmd' accepted surplus"; return 1; }
        [[ "$output" == *"Too many arguments"* ]] || { echo "'$cmd' wrong message"; return 1; }
    done
}

@test "status: honors COPYCROW_CONF override" {
    # P2-12: cmd_status comprobaba ${COPYCROW_ROOT}/copycrow.conf hardcodeado.
    run env COPYCROW_CONF="$COPYCROW_CONF" "${COPYCROW_ROOT}/copycrow.sh" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"dry_job"* ]]
}

# ───────────────────────────────────────────────────────────────────────────────
# verify / verify-all (roadmap P3-19)
# ───────────────────────────────────────────────────────────────────────────────

_make_borg_recorder() {
    local rc="${1:-0}"
    export BORG_ARGS_LOG="${COPYCROW_TEST_SANDBOX}/borg-args.log"
    : > "$BORG_ARGS_LOG"
    mkdir -p "${COPYCROW_TEST_SANDBOX}/bin"
    cat > "${COPYCROW_TEST_SANDBOX}/bin/borg" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$BORG_ARGS_LOG"
exit ${rc}
EOF
    chmod +x "${COPYCROW_TEST_SANDBOX}/bin/borg"
    export PATH="${COPYCROW_TEST_SANDBOX}/bin:${PATH}"
}

_verify_conf_fixture() {
    cat > "$COPYCROW_CONF" << 'EOF'
[global]

[v1]
type = manual
sources = /home
host = local
remote_path = /tmp/copycrow-ver-repo
EOF
}

@test "verify: requires a job argument" {
    run "${COPYCROW_ROOT}/copycrow.sh" verify
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage"* ]]
}

@test "verify: unknown job errors" {
    _verify_conf_fixture
    run "${COPYCROW_ROOT}/copycrow.sh" verify no_such_job
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}

@test "verify: runs borg check against the job repository" {
    _make_borg_recorder 0
    _verify_conf_fixture
    run "${COPYCROW_ROOT}/copycrow.sh" verify v1
    [ "$status" -eq 0 ]
    grep -q '^check --info /tmp/copycrow-ver-repo$' "$BORG_ARGS_LOG"
}

@test "verify: fails nonzero when borg check fails" {
    _make_borg_recorder 3
    _verify_conf_fixture
    run "${COPYCROW_ROOT}/copycrow.sh" verify v1
    [ "$status" -ne 0 ]
    [[ "$output" == *"verification FAILED"* ]]
}

@test "verify-all: verifies every job; aggregates failures" {
    _make_borg_recorder 0
    cat > "$COPYCROW_CONF" << 'EOF'
[global]

[v1]
type = manual
sources = /home
host = local
remote_path = /tmp/r1

[v2]
type = manual
sources = /home
host = local
remote_path = /tmp/r2
EOF
    run "${COPYCROW_ROOT}/copycrow.sh" verify-all
    [ "$status" -eq 0 ]
    grep -q '/tmp/r1' "$BORG_ARGS_LOG"
    grep -q '/tmp/r2' "$BORG_ARGS_LOG"

    _make_borg_recorder 2
    run "${COPYCROW_ROOT}/copycrow.sh" verify-all
    [ "$status" -ne 0 ]
    [[ "$output" == *"failed verification"* ]]
}

# ───────────────────────────────────────────────────────────────────────────────
# cloud chaining (ProtonDrive offsite)
# ───────────────────────────────────────────────────────────────────────────────

_make_proton_recorder() {
    export PROTON_ARGS_LOG="${COPYCROW_TEST_SANDBOX}/proton-args.log"
    export PROTON_UPLOADS_LOG="${COPYCROW_TEST_SANDBOX}/uploads.log"
    : > "$PROTON_ARGS_LOG"
    : > "$PROTON_UPLOADS_LOG"
    export HOME="${COPYCROW_TEST_SANDBOX}/home"
    mkdir -p "$HOME"
    export XDG_CACHE_HOME="${HOME}/.cache"
    export COPYCROW_CLOUD_WRAP="none"
    export PROTON_STATE="${COPYCROW_TEST_SANDBOX}/drive"
    mkdir -p "$PROTON_STATE"
    cat > "${COPYCROW_TEST_SANDBOX}/bin/proton-drive" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${PROTON_ARGS_LOG:?}"
sub="${1:-}"; shift || true
case "$sub" in
    filesystem)
        cmd="${1:-}"; shift || true
        case "$cmd" in
            info)
                p="${*: -1}"
                [[ -e "${PROTON_STATE:?}${p}" ]] && exit 0
                exit 1
                ;;
            create-folder)
                mkdir -p "${PROTON_STATE:?}${1}/${2}"
                exit 0
                ;;
            upload)
                local_file="$1"; parent="$2"
                strategy="skip"
                [[ "${3:-}" == "--conflict-strategy" ]] && strategy="$4"
                printf 'upload %s %s %s\n' "$local_file" "$parent" "$strategy" >> "${PROTON_UPLOADS_LOG:?}"
                exit 0
                ;;
        esac
        ;;
esac
exit 0
STUB
    chmod +x "${COPYCROW_TEST_SANDBOX}/bin/proton-drive"
    export PATH="${COPYCROW_TEST_SANDBOX}/bin:${PATH}"
}

_cloud_fixture() {
    cat > "$COPYCROW_CONF" << EOF
[global]
logs_dir = ${COPYCROW_TEST_SANDBOX}/logs

[cjob]
type = manual
sources = /home
host = local
remote_path = ${COPYCROW_TEST_SANDBOX}/repo
cloud_remote = /Backups/cjob
EOF
    mkdir -p "${COPYCROW_TEST_SANDBOX}/repo" "${COPYCROW_TEST_SANDBOX}/logs"
    echo data > "${COPYCROW_TEST_SANDBOX}/repo/blob"
}

@test "backup: chains ProtonDrive sync after a successful backup" {
    _make_borg_recorder 0
    _make_proton_recorder
    _cloud_fixture
    run "${COPYCROW_ROOT}/copycrow.sh" backup cjob
    [ "$status" -eq 0 ]
    [[ "$output" == *"ProtonDrive sync:"* ]]
    grep -qF "upload ${COPYCROW_TEST_SANDBOX}/repo/blob /Backups/cjob skip" "$PROTON_UPLOADS_LOG"
}

@test "backup: cloud failure NEVER fails the backup itself" {
    _make_borg_recorder 0
    _make_proton_recorder
    # Stub variant that always fails on uploads:
    cat > "${COPYCROW_TEST_SANDBOX}/bin/proton-drive" << 'STUB'
#!/usr/bin/env bash
case "$*" in
    *"filesystem upload"*) echo "simulated outage" >&2; exit 42 ;;
    *) exit 0 ;;
esac
STUB
    chmod +x "${COPYCROW_TEST_SANDBOX}/bin/proton-drive"
    _cloud_fixture
    run "${COPYCROW_ROOT}/copycrow.sh" backup cjob
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING: ProtonDrive sync FAILED"* ]]
    [[ "$output" == *"./copycrow.sh sync cjob"* ]]
}

@test "backup: jobs without cloud_remote produce no cloud activity" {
    _make_borg_recorder 0
    _make_proton_recorder
    cat > "$COPYCROW_CONF" << EOF
[global]
logs_dir = ${COPYCROW_TEST_SANDBOX}/logs

[plain]
type = manual
sources = /home
host = local
remote_path = ${COPYCROW_TEST_SANDBOX}/repo
EOF
    mkdir -p "${COPYCROW_TEST_SANDBOX}/repo" "${COPYCROW_TEST_SANDBOX}/logs"
    run "${COPYCROW_ROOT}/copycrow.sh" backup plain
    [ "$status" -eq 0 ]
    [[ "$output" != *"ProtonDrive"* ]]
    [ ! -s "$PROTON_UPLOADS_LOG" ]
}

@test "dryrun: reports pending cloud files without touching the CLI" {
    _make_borg_recorder 0
    _make_proton_recorder
    _cloud_fixture
    run "${COPYCROW_ROOT}/copycrow.sh" dryrun cjob
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cloud:"* ]]
    [[ "$output" == *"1 pending file(s)"* ]]
    [ ! -s "$PROTON_UPLOADS_LOG" ]
}

# ───────────────────────────────────────────────────────────────────────────────
# sync command
# ───────────────────────────────────────────────────────────────────────────────

@test "sync: requires a job argument" {
    run "${COPYCROW_ROOT}/copycrow.sh" sync
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage"* ]]
}

@test "sync: rejects extra arguments" {
    run "${COPYCROW_ROOT}/copycrow.sh" sync cjob surplus
    [ "$status" -ne 0 ]
    [[ "$output" == *"Too many arguments"* ]]
}

@test "sync: unknown job errors" {
    _make_borg_recorder 0
    run "${COPYCROW_ROOT}/copycrow.sh" sync nope
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}

@test "sync: job without cloud_remote errors clearly" {
    _make_borg_recorder 0
    cat > "$COPYCROW_CONF" << 'EOF'
[global]

[plain_job]
type = manual
sources = /home
host = local
remote_path = /tmp/plain-repo
EOF
    run "${COPYCROW_ROOT}/copycrow.sh" sync plain_job
    [ "$status" -ne 0 ]
    [[ "$output" == *"no 'cloud_remote'"* ]]
}

@test "sync: performs locked cloud replication" {
    _make_borg_recorder 0
    _make_proton_recorder
    _cloud_fixture
    echo blob2 > "${COPYCROW_TEST_SANDBOX}/repo/blob2"
    run "${COPYCROW_ROOT}/copycrow.sh" sync cjob
    [ "$status" -eq 0 ]
    [[ "$output" == *"ProtonDrive sync:"* ]]
    grep -qF "upload ${COPYCROW_TEST_SANDBOX}/repo/blob /Backups/cjob skip" "$PROTON_UPLOADS_LOG"
    grep -qF "upload ${COPYCROW_TEST_SANDBOX}/repo/blob2 /Backups/cjob skip" "$PROTON_UPLOADS_LOG"
}

@test "help documents sync" {
    run "${COPYCROW_ROOT}/copycrow.sh" help
    [[ "$output" == *"sync <job>"* ]]
}
