#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# Tests for cloud-sync.sh — proton-drive CLI STUBBED via PATH (deterministic).
# HOME/XDG_CACHE_HOME are redirected so manifests never touch the real user's
# cache. COPYCROW_CLOUD_WRAP=none disables the headless dbus wrapper here.
# ═══════════════════════════════════════════════════════════════════════════════

setup() {
    export COPYCROW_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export COPYCROW_TEST_SANDBOX="$(mktemp -d /tmp/copycrow-cloud-XXXXXX)"
    export COPYCROW_CONF="${COPYCROW_TEST_SANDBOX}/test.conf"

    # Isolate manifest/cache state completely.
    export HOME="${COPYCROW_TEST_SANDBOX}/home"
    mkdir -p "$HOME"
    export XDG_CACHE_HOME="${HOME}/.cache"

    # Deterministic wrapper: never depend on DISPLAY/dbus availability.
    export COPYCROW_CLOUD_WRAP="none"

    export PROTON_ARGS_LOG="${COPYCROW_TEST_SANDBOX}/proton-args.log"
    export PROTON_UPLOADS_LOG="${COPYCROW_TEST_SANDBOX}/uploads.log"
    : > "$PROTON_ARGS_LOG"
    : > "$PROTON_UPLOADS_LOG"

    export FAKE_REPO="${COPYCROW_TEST_SANDBOX}/repo"
    export PROTON_STATE="${COPYCROW_TEST_SANDBOX}/drive"
    mkdir -p "$FAKE_REPO/data/0" "$PROTON_STATE"
    echo segmentA > "$FAKE_REPO/data/0/segments-a"
    echo configdata > "$FAKE_REPO/config"
    echo readme > "$FAKE_REPO/README"
    mkdir -p "$FAKE_REPO/lock"
    echo lockpid > "$FAKE_REPO/lock/host.pid"

    cat > "$COPYCROW_CONF" << EOF
[global]
logs_dir = ${COPYCROW_TEST_SANDBOX}/logs

[cloud_job]
type = manual
sources = /home
host = local
remote_path = ${FAKE_REPO}
cloud_remote = /Backups/cloud_job
EOF

    mkdir -p "${COPYCROW_TEST_SANDBOX}/bin"
    cat > "${COPYCROW_TEST_SANDBOX}/bin/proton-drive" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${PROTON_ARGS_LOG:?}"
if [[ -n "${PROTON_FAIL_ON:-}" && "$*" == *"${PROTON_FAIL_ON}"* ]]; then
    exit 42
fi
sub="${1:-}"; shift || true
case "$sub" in
    filesystem)
        cmd="${1:-}"; shift || true
        case "$cmd" in
            info)
                p="${*: -1}"
                if [[ -e "${PROTON_STATE:?}${p}" ]]; then exit 0; fi
                exit 1
                ;;
            create-folder)
                mkdir -p "${PROTON_STATE:?}${1}/${2}"
                exit 0
                ;;
            upload)
                local_file="$1"; parent="$2"
                strategy="skip"
                if [[ "${3:-}" == "--conflict-strategy" ]]; then strategy="$4"; fi
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

    source "${COPYCROW_ROOT}/src/config-parser.sh"
    config_load "$COPYCROW_CONF"
    source "${COPYCROW_ROOT}/src/backup-core.sh"
    source "${COPYCROW_ROOT}/src/cloud-sync.sh"
}

teardown() {
    rm -rf "$COPYCROW_TEST_SANDBOX"
}

@test "cloud_resolve_cli: resolves binary from PATH" {
    run cloud_resolve_cli
    [ "$status" -eq 0 ]
    [[ "$output" == *"proton-drive" ]]
}

@test "cloud_resolve_cli: honors absolute cloud_cli_path override" {
    cat > "${COPYCROW_TEST_SANDBOX}/override.conf" << EOF
[global]
logs_dir = ${COPYCROW_TEST_SANDBOX}/logs
cloud_cli_path = ${COPYCROW_TEST_SANDBOX}/bin/proton-drive

[cloud_job]
type = manual
sources = /home
host = local
remote_path = ${FAKE_REPO}
cloud_remote = /Backups/cloud_job
EOF
    config_load "${COPYCROW_TEST_SANDBOX}/override.conf"
    run cloud_resolve_cli
    [ "$status" -eq 0 ]
    [ "$output" = "${COPYCROW_TEST_SANDBOX}/bin/proton-drive" ]
}

@test "cloud_resolve_cli: fails when binary absent" {
    local saved_path="$PATH"
    PATH="/usr/bin:/bin"
    run cloud_resolve_cli
    PATH="$saved_path"
    [ "$status" -ne 0 ]
}

@test "_cloud_wrap_prefix: explicit none disables wrapper" {
    COPYCROW_CLOUD_WRAP="none" run _cloud_wrap_prefix
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "_cloud_wrap_prefix: custom wrap passes through" {
    COPYCROW_CLOUD_WRAP="dbus-run-session --" run _cloud_wrap_prefix
    [ "$status" -eq 0 ]
    [ "$output" = "dbus-run-session --" ]
}

@test "_cloud_wrap_prefix: rejects metacharacters" {
    COPYCROW_CLOUD_WRAP='foo;rm' run _cloud_wrap_prefix
    [ "$status" -ne 0 ]
    [[ "$output" == *"forbidden characters"* ]]
}

@test "_cloud_wrap_prefix: headless default is dbus-run-session" {
    local saved_wrap="${COPYCROW_CLOUD_WRAP:-}"
    unset COPYCROW_CLOUD_WRAP DISPLAY WAYLAND_DISPLAY
    run _cloud_wrap_prefix
    local rc=$?
    export COPYCROW_CLOUD_WRAP="$saved_wrap"
    [ "$rc" -eq 0 ]
    [ "$output" = "dbus-run-session --" ]
}

@test "_cloud_exec: applies wrapper so wrapped context reaches the CLI" {
    cat > "${COPYCROW_TEST_SANDBOX}/bin/proton-drive" << 'STUB'
#!/usr/bin/env bash
printf 'args:%s\n' "$*" >> "${PROTON_ARGS_LOG:?}"
printf 'CC_TEST=%s\n' "${CC_TEST:-unset}" >> "${PROTON_ARGS_LOG:?}"
exit 0
STUB
    chmod +x "${COPYCROW_TEST_SANDBOX}/bin/proton-drive"
    COPYCROW_CLOUD_WRAP="/usr/bin/env CC_TEST=1" _cloud_exec out filesystem info "/Backups" || true
    grep -q "^args:filesystem info /Backups$" "$PROTON_ARGS_LOG"
    grep -q "^CC_TEST=1$" "$PROTON_ARGS_LOG"
}

@test "_cloud_exec: fails with clear message when CLI missing" {
    local saved_path="$PATH"
    PATH="/usr/bin:/bin"
    run _cloud_exec out version
    PATH="$saved_path"
    [ "$status" -ne 0 ]
    [[ "$output" == *"proton-drive CLI not found"* ]]
}

@test "_cloud_manifest_save/_load: roundtrip preserves entries with 0600 perms" {
    declare -gA _CLOUD_SEED
    _CLOUD_SEED=( ["README"]="7 1700000000" ["data/0/segments-a"]="9 1700000001" )
    _CLOUD_SEEN=()
    local k
    for k in "${!_CLOUD_SEED[@]}"; do _CLOUD_SEEN["$k"]="${_CLOUD_SEED[$k]}"; done
    _cloud_manifest_save "cloud_job"
    local mf="${XDG_CACHE_HOME}/copycrow/cloud/cloud_job.manifest"
    [ "$(stat -c %a "$mf")" = "600" ]
    _CLOUD_SEEN=()
    _cloud_manifest_load "cloud_job"
    [ "${_CLOUD_SEEN[README]}" = "7 1700000000" ]
    [ "${_CLOUD_SEEN[data/0/segments-a]}" = "9 1700000001" ]
}

@test "_cloud_manifest_save: failed sort leaves prior manifest byte-identical" {
    _CLOUD_SEEN=( ["README"]="7 1700000000" )
    _cloud_manifest_save "cloud_job"
    local mf="${XDG_CACHE_HOME}/copycrow/cloud/cloud_job.manifest"
    cp -- "$mf" "${mf}.expected"

    # Stub sort to fail AFTER consuming stdin (simulates crash mid-save).
    mkdir -p "${COPYCROW_TEST_SANDBOX}/failing-bin"
    cat > "${COPYCROW_TEST_SANDBOX}/failing-bin/sort" << 'STUB'
#!/usr/bin/env bash
cat >/dev/null
exit 1
STUB
    chmod +x "${COPYCROW_TEST_SANDBOX}/failing-bin/sort"
    local saved_path="$PATH"
    PATH="${COPYCROW_TEST_SANDBOX}/failing-bin:${PATH}"

    _CLOUD_SEEN=( ["README"]="7 1700000000" ["data/0/segments-a"]="9 1" )
    run _cloud_manifest_save "cloud_job"
    PATH="$saved_path"

    [ "$status" -ne 0 ]
    cmp -s "${mf}" "${mf}.expected"
}

@test "_cloud_wrap_prefix: rejects embedded newlines" {
    COPYCROW_CLOUD_WRAP=$'foo\nrm -rf /' run _cloud_wrap_prefix
    [ "$status" -ne 0 ]
    [[ "$output" == *"forbidden characters"* ]]
}

# ───────────────────────────────────────────────────────────────────────────────
# cloud_sync_job — engine
# ───────────────────────────────────────────────────────────────────────────────

@test "cloud_sync_job: uploads new files with skip strategy, excluding lock*" {
    run cloud_sync_job cloud_job
    [ "$status" -eq 0 ]
    grep -qF "upload ${FAKE_REPO}/README /Backups/cloud_job skip" "$PROTON_UPLOADS_LOG"
    grep -qF "upload ${FAKE_REPO}/config /Backups/cloud_job skip" "$PROTON_UPLOADS_LOG"
    grep -qF "upload ${FAKE_REPO}/data/0/segments-a /Backups/cloud_job/data/0 skip" "$PROTON_UPLOADS_LOG"
    ! grep -q "lock" "$PROTON_UPLOADS_LOG"
    # Folder chain was ensured bottom-up in the simulated Drive.
    [ -d "$PROTON_STATE/Backups/cloud_job" ]
    [ -d "$PROTON_STATE/Backups/cloud_job/data/0" ]
    # Success JSON log landed in the sandboxed logs dir.
    grep -q '"action":"cloud_sync","files":"3"' "${COPYCROW_TEST_SANDBOX}/logs/"copycrow-*.log
}

@test "cloud_sync_job: second run skips everything unchanged" {
    cloud_sync_job cloud_job >/dev/null 2>&1
    local before after
    before="$(wc -l < "$PROTON_UPLOADS_LOG")"
    run cloud_sync_job cloud_job
    [ "$status" -eq 0 ]
    after="$(wc -l < "$PROTON_UPLOADS_LOG")"
    [ "$after" -eq "$before" ]
}

@test "cloud_sync_job: rewritten files go up with replace strategy" {
    cloud_sync_job cloud_job >/dev/null 2>&1
    touch -m -d '@2000000000' "$FAKE_REPO/config"
    : > "$PROTON_UPLOADS_LOG"
    run cloud_sync_job cloud_job
    [ "$status" -eq 0 ]
    grep -qF "upload ${FAKE_REPO}/config /Backups/cloud_job replace" "$PROTON_UPLOADS_LOG"
    [ "$(wc -l < "$PROTON_UPLOADS_LOG")" -eq 1 ]
}

@test "cloud_sync_job: failing upload aborts, manifest stays pristine" {
    export PROTON_FAIL_ON="segments-a"
    run cloud_sync_job cloud_job
    unset PROTON_FAIL_ON
    [ "$status" -ne 0 ]
    [[ ! -f "${XDG_CACHE_HOME}/copycrow/cloud/cloud_job.manifest" ]]
    grep -qF "upload ${FAKE_REPO}/config /Backups/cloud_job skip" "$PROTON_UPLOADS_LOG"
    # The stub exits BEFORE logging failed uploads to UPLOADS_LOG; the attempt
    # itself (argv) is always recorded in PROTON_ARGS_LOG.
    grep -qF "filesystem upload ${FAKE_REPO}/data/0/segments-a" "$PROTON_ARGS_LOG"
    grep -q '"action":"cloud_sync".*"file":"data/0/segments-a"' "${COPYCROW_TEST_SANDBOX}/logs/"copycrow-*.log
}

@test "cloud_sync_job: retries pending work on next run after a failure" {
    export PROTON_FAIL_ON="segments-a"
    cloud_sync_job cloud_job >/dev/null 2>&1 || true
    unset PROTON_FAIL_ON
    : > "$PROTON_UPLOADS_LOG"
    run cloud_sync_job cloud_job
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$PROTON_UPLOADS_LOG")" -eq 3 ]
}

@test "cloud_sync_job: rejects remote-repository jobs" {
    cat > "${COPYCROW_TEST_SANDBOX}/remote.conf" << EOF
[global]
logs_dir = ${COPYCROW_TEST_SANDBOX}/logs

[r_job]
type = manual
sources = /home
host = nas
remote_path = /backups/r
cloud_remote = /Backups/r
EOF
    config_load "${COPYCROW_TEST_SANDBOX}/remote.conf"
    run cloud_sync_job r_job
    [ "$status" -ne 0 ]
    [[ "$output" == *"supports local repositories only"* ]]
}

@test "cloud_pending_count: pure-local diff, never touches the CLI" {
    local before
    before="$(wc -l < "$PROTON_ARGS_LOG")"
    run cloud_pending_count cloud_job
    [ "$status" -eq 0 ]
    [ "$output" = "3" ]
    [ "$(wc -l < "$PROTON_ARGS_LOG")" -eq "$before" ]

    cloud_sync_job cloud_job >/dev/null 2>&1
    run cloud_pending_count cloud_job
    [ "$output" = "0" ]

    touch -m -d '@2000000000' "$FAKE_REPO/README"
    run cloud_pending_count cloud_job
    [ "$output" = "1" ]
}

@test "cloud_sync_job: manifest-save failure fails the run with ERROR log" {
    mkdir -p "${COPYCROW_TEST_SANDBOX}/failing-bin"
    cat > "${COPYCROW_TEST_SANDBOX}/failing-bin/sort" << 'STUB'
#!/usr/bin/env bash
cat >/dev/null
exit 1
STUB
    chmod +x "${COPYCROW_TEST_SANDBOX}/failing-bin/sort"
    local saved_path="$PATH"
    PATH="${COPYCROW_TEST_SANDBOX}/failing-bin:${PATH}"
    run cloud_sync_job cloud_job
    PATH="$saved_path"
    [ "$status" -ne 0 ]
    [[ "$output" == *"could not persist cloud manifest"* ]]
    grep -q '"stage":"manifest_save"' "${COPYCROW_TEST_SANDBOX}/logs/"copycrow-*.log
    [[ "$output" != *"ProtonDrive sync:"* ]]
}

@test "cloud_sync_job: refuses empty cloud_remote" {
    # NOTE: an EMPTY value is rejected by config_load itself ("must start
    # with '/'"), so the realistic path to remote_root="" here is the key
    # being ABSENT from the section (config_get_var defaults to "").
    cat > "${COPYCROW_TEST_SANDBOX}/empty.conf" << EOF
[global]
logs_dir = ${COPYCROW_TEST_SANDBOX}/logs

[empty_job]
type = manual
sources = /home
host = local
remote_path = ${FAKE_REPO}
EOF
    config_load "${COPYCROW_TEST_SANDBOX}/empty.conf"
    run cloud_sync_job empty_job
    [ "$status" -ne 0 ]
    [[ "$output" == *"empty 'cloud_remote'"* ]]
    [ ! -s "$PROTON_UPLOADS_LOG" ]
}

@test "_cloud_manifest_save: manifest path being a directory fails cleanly" {
    mkdir -p "${XDG_CACHE_HOME}/copycrow/cloud/cloud_job.manifest"
    _CLOUD_SEEN=( ["README"]="7 1700000000" )
    run _cloud_manifest_save "cloud_job"
    [ "$status" -ne 0 ]
    [[ "$output" == *"could not persist manifest"* ]]
}

@test "cloud_sync_job: a file vanishing mid-walk is skipped; sync still completes" {
    # Sorted walk: aaa-early uploads BEFORE zzz-late. The stub deletes zzz
    # during aaa's upload, so zzz's stat() fails when the walk reaches it
    # (TOCTOU). The sync must warn+skip, keep the manifest consistent and
    # return 0 — not die mid-run under set -e.
    echo early > "$FAKE_REPO/aaa-early.txt"
    echo doomed > "$FAKE_REPO/zzz-late.txt"
    cat > "${COPYCROW_TEST_SANDBOX}/bin/proton-drive" << 'STUB'
#!/usr/bin/env bash
sub="${1:-}"; shift || true
case "$sub" in
    filesystem)
        cmd="${1:-}"; shift || true
        case "$cmd" in
            info)
                p="${*: -1}"
                if [[ -e "${PROTON_STATE:?}${p}" ]]; then exit 0; fi
                exit 1
                ;;
            create-folder)
                mkdir -p "${PROTON_STATE:?}${1}/${2}"
                exit 0
                ;;
            upload)
                if [[ "$1" == *"/aaa-early.txt" && -n "${VICTIM_FILE:-}" ]]; then
                    rm -f -- "$VICTIM_FILE"
                fi
                exit 0
                ;;
        esac
        ;;
esac
exit 0
STUB
    chmod +x "${COPYCROW_TEST_SANDBOX}/bin/proton-drive"
    export VICTIM_FILE="${FAKE_REPO}/zzz-late.txt"

    run cloud_sync_job cloud_job
    [ "$status" -eq 0 ]
    [[ "$output" == *"vanished"* ]]
    # aaa was uploaded and the manifest was still persisted.
    grep -q "aaa-early.txt" "${XDG_CACHE_HOME}/copycrow/cloud/cloud_job.manifest"
    ! grep -q "zzz-late.txt" "${XDG_CACHE_HOME}/copycrow/cloud/cloud_job.manifest"
}
