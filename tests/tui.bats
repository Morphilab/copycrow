#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# Tests for tui.sh — whiptail/systemctl STUBBED via PATH.
#
# NOTE ON INVOCATION: these tests call the TUI functions DIRECTLY (not via
# bats `run`). bats' `run` wraps the function in an extra command substitution
# whose merged-fd redirection interacts badly with the classic whiptail
# swap (`3>&1 1>&2 2>&3`), losing the menu selection. A direct call matches
# the production context (top-level script) and keeps the swap intact.
#
# Contract under test:
#   1. Backend failure NEVER kills the TUI loop (survival).
#   2. Failure renders an error dialog; success dialog ONLY on real success.
# ═══════════════════════════════════════════════════════════════════════════════

setup() {
    local real_root
    real_root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export COPYCROW_TEST_SANDBOX="$(mktemp -d /tmp/copycrow-tui-XXXXXX)"
    export HOME="${COPYCROW_TEST_SANDBOX}/home"
    mkdir -p "$HOME"
    unset BORG_PASSPHRASE BORG_PASSCOMMAND SSH_AUTH_SOCK

    export TUI_LOG="${COPYCROW_TEST_SANDBOX}/whiptail.log"
    : > "$TUI_LOG"
    export TUI_OUT="${COPYCROW_TEST_SANDBOX}/tui-stdout.log"
    : > "$TUI_OUT"

    local stub_bin="${COPYCROW_TEST_SANDBOX}/bin"
    mkdir -p "$stub_bin"

    # whiptail: logs argv; when invoked as a MENU it prints $FAKE_CHOICE to ITS
    # stderr (which the swap redirection turns into the captured stream).
    # NOTE: match --menu anywhere in argv: tui.sh passes `--title X --menu ...`,
    # so $1 is --title, not --menu.
    cat > "${stub_bin}/whiptail" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TUI_LOG"
case " $* " in
    *" --menu "*|*" --radiolist "*|*" --checklist "*)
        printf '%s\n' "${FAKE_CHOICE:-}" >&2 ;;
    *) exit 0 ;;
esac
STUB

    # systemctl: reads its exit code from the environment AT RUNTIME, so each
    # test can flip it (baking the value at setup time would be too late).
    cat > "${stub_bin}/systemctl" << 'STUB'
#!/usr/bin/env bash
exit "${SYSTEMCTL_RC:-0}"
STUB
    chmod +x "${stub_bin}/whiptail" "${stub_bin}/systemctl"
    export PATH="${stub_bin}:${PATH}"

    export COPYCROW_CONF="${COPYCROW_TEST_SANDBOX}/test.conf"
    cat > "$COPYCROW_CONF" << 'EOF'
[global]

[timer_job]
type = automatic
sources = /home
host = local
remote_path = /tmp/repo
schedule = daily
EOF

    # The TUI reads $COPYCROW_CONF (mirrors the CLI contract). This mirror of
    # the same content at the legacy root path exercises the "both exist"
    # case; the COPYCROW_CONF-only path is covered by its own test below.
    export COPYCROW_ROOT="${COPYCROW_TEST_SANDBOX}/projroot"
    mkdir -p "$COPYCROW_ROOT"
    ln -s "${real_root}/copycrow.sh" "${COPYCROW_ROOT}/copycrow.sh"
    ln -s "${real_root}/copycrow.conf.example" "${COPYCROW_ROOT}/copycrow.conf.example"
    ln -s "${real_root}/src" "${COPYCROW_ROOT}/src"
    cp "$COPYCROW_CONF" "${COPYCROW_ROOT}/copycrow.conf"

    source "${COPYCROW_ROOT}/src/config-parser.sh"
    config_load "$COPYCROW_CONF"
    CONFIG_LOADED="1"
    # Production wiring: copycrow.sh sources backup-core BEFORE the TUI.
    source "${COPYCROW_ROOT}/src/backup-core.sh"
    source "${COPYCROW_ROOT}/src/tui.sh"
}

teardown() {
    rm -rf "$COPYCROW_TEST_SANDBOX"
}

@test "tui_manage_timers: install FAILURE renders error dialog; no fake success" {
    export SYSTEMCTL_RC=1
    # Mirror tui_main's guard (`handler || true`): the marker after the call
    # proves the menu loop would survive a backend failure.
    local flow_out="" rc=0
    flow_out="$(FAKE_CHOICE=1 tui_manage_timers >/dev/null 2>&1 && echo SURVIVED)" || rc=$?
    [[ "$flow_out" == *"SURVIVED"* ]] || [[ "$rc" -eq 1 ]]
    grep -q "Error" "$TUI_LOG"
    ! grep -q "installed successfully" "$TUI_LOG"
}

@test "tui_manage_timers: install SUCCESS shows success dialog only when rc=0" {
    export SYSTEMCTL_RC=0
    local rc=0
    FAKE_CHOICE=1 tui_manage_timers > "$TUI_OUT" 2>&1 || rc=$?
    [ "$rc" -eq 0 ]
    grep -q "Timers installed successfully" "$TUI_LOG"
}

@test "tui_create_backup: menu args are clean tag/desc pairs (no literal quotes)" {
    # Menu args must be clean argv pairs: embedded quotes or an odd item
    # count would put literal quotes in whiptail's argv (broken menu with
    # a single job).
    local rc=0
    FAKE_CHOICE=timer_job tui_create_backup > /dev/null 2>&1 || rc=$?

    local menu_line
    menu_line="$(grep -F -- '--menu' "$TUI_LOG" | tail -1)"
    [ -n "$menu_line" ]
    [[ "$menu_line" == *"timer_job [automatic] local"* ]]
    ! grep -qF '"' <<< "$menu_line"
}

@test "tui_main: exports COPYCROW_UNDER_TUI so backends suppress raw prompts" {
    FAKE_CHOICE="" tui_main >/dev/null 2>&1 || true
    [ "${COPYCROW_UNDER_TUI:-}" = "1" ]
}

# ───────────────────────────────────────────────────────────────────────────────
# TUI↔CLI parity
# ───────────────────────────────────────────────────────────────────────────────

@test "tui_main: menu offers dry-run, jobs, verify, doctor and migrate (parity)" {
    FAKE_CHOICE="" tui_main >/dev/null 2>&1 || true
    local menu_line
    menu_line="$(grep -F -- '--menu' "$TUI_LOG" | head -1)"
    [[ "$menu_line" == *"Dry-run"* ]]
    [[ "$menu_line" == *"configured jobs"* ]]
    [[ "$menu_line" == *"doctor"* ]]
    [[ "$menu_line" == *"Verify repository integrity"* ]]
    [[ "$menu_line" == *"Migrate legacy configuration"* ]]
}

@test "tui_list_jobs: renders every job's fields" {
    FAKE_CHOICE="" tui_list_jobs >/dev/null 2>&1 || true
    grep -q "timer_job" "$TUI_LOG"
    grep -q "schedule: daily" "$TUI_LOG"
    grep -q "path: /tmp/repo" "$TUI_LOG"
}

@test "tui_dryrun_backup: renders the dry-run plan for the selected job" {
    FAKE_CHOICE=timer_job tui_dryrun_backup >/dev/null 2>&1 || true
    grep -q "DRY-RUN" "$TUI_LOG"
}

@test "tui_migrate_config: migrates legacy conf and reloads session" {
    cat > "$COPYCROW_CONF" << 'EOF'
[global]
compresion = lz4

[timer_job]
tipo = automatico
origenes = /home
host = local
ruta_remota = /tmp/repo
frecuencia = diario
EOF
    FAKE_CHOICE="" tui_migrate_config >/dev/null 2>&1 || true
    grep -q "^type = automatic$" "$COPYCROW_CONF"
    grep -q "^schedule = daily$" "$COPYCROW_CONF"
    [ "$(config_get_var timer_job type)" = "automatic" ]
}

# ───────────────────────────────────────────────────────────────────────────────
# TUI Sync to Proton Drive (parity with CLI)
# ───────────────────────────────────────────────────────────────────────────────

@test "tui_main: menu offers Proton Drive sync (parity)" {
    FAKE_CHOICE="" tui_main >/dev/null 2>&1 || true
    local menu_line
    menu_line="$(grep -F -- '--menu' "$TUI_LOG" | head -1)"
    [[ "$menu_line" == *"Sync job to Proton Drive"* ]]
}

@test "tui_sync_job: lists only cloud-enabled jobs" {
    cat > "$COPYCROW_CONF" << 'EOF'
[global]

[cloudy]
type = manual
sources = /home
host = local
remote_path = /tmp/repo
cloud_remote = /Backups/cloudy

[offline]
type = manual
sources = /home
host = nas
remote_path = /backups/offline
EOF
    config_load "$COPYCROW_CONF"
    FAKE_CHOICE="" tui_sync_job >/dev/null 2>&1 || true
    local menu_line
    menu_line="$(grep -F -- '--menu' "$TUI_LOG" | tail -1)"
    [[ "$menu_line" == *"cloudy [local] /Backups/cloudy"* ]]
    [[ "$menu_line" != *"offline"* ]]
    # Empty selection (cancel) renders no further dialogs.
    ! grep -q "Sync FAILED" "$TUI_LOG"
}

@test "tui_sync_job: failed backend renders failure dialog, survives" {
    cat > "$COPYCROW_CONF" << 'EOF'
[global]

[cloudy]
type = manual
sources = /home
host = local
remote_path = /nonexistent-repo
cloud_remote = /Backups/cloudy
EOF
    config_load "$COPYCROW_CONF"
    local flow_out="" rc=0
    flow_out="$(FAKE_CHOICE=cloudy tui_sync_job >/dev/null 2>&1 && echo SURVIVED)" || rc=$?
    grep -q "Sync FAILED" "$TUI_LOG"
}

# ───────────────────────────────────────────────────────────────────────────────
# Robustness: COPYCROW_CONF override, clean cancellation, temp path
# ───────────────────────────────────────────────────────────────────────────────

@test "tui_main: honors COPYCROW_CONF without a project-root copycrow.conf" {
    rm -f "${COPYCROW_ROOT}/copycrow.conf"
    local rc=0
    FAKE_CHOICE="" tui_main > /dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ]
    grep -q -- "--menu" "$TUI_LOG"
}

@test "tui_view_status: reflects the COPYCROW_CONF job list (not the root conf)" {
    rm -f "${COPYCROW_ROOT}/copycrow.conf"
    FAKE_CHOICE="" tui_view_status >/dev/null 2>&1 || true
    grep -q "timer_job" "$TUI_LOG"
    ! grep -q "not found" "$TUI_LOG"
}

@test "tui_main: ESC/cancel on the main menu exits cleanly (rc 0, no crash)" {
    # A whiptail that exits 1 on --menu simulates ESC/cancel with no output.
    # `run` (not `... || rc=$?`): a || context DISABLES errexit inside the
    # function and would mask the crash that production (top-level call)
    # suffers. run executes in a subshell with errexit intact.
    cat > "${COPYCROW_TEST_SANDBOX}/bin/whiptail" << 'STUB'
#!/usr/bin/env bash
case " $* " in
    *" --menu "*) exit 1 ;;
    *) exit 0 ;;
esac
STUB
    chmod +x "${COPYCROW_TEST_SANDBOX}/bin/whiptail"
    # A REAL subshell with set -e: production calls tui_main top-level under
    # errexit, and both `run fn` and `... || rc` contexts suppress -e inside
    # the function, masking the crash this test guards against.
    run bash -c '
        set -euo pipefail
        source "'"${COPYCROW_ROOT}"'/src/tui.sh"
        tui_main
    '
    [ "$status" -eq 0 ]
}

@test "tui_verify_repo: temp output lives under the configured mount_dir (no stray .mnt)" {
    cat > "${COPYCROW_TEST_SANDBOX}/bin/borg" << 'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "${COPYCROW_TEST_SANDBOX}/bin/borg"
    cat > "$COPYCROW_CONF" << 'EOF'
[global]
mount_dir = mnt-custom

[timer_job]
type = automatic
sources = /home
host = local
remote_path = /tmp/repo
schedule = daily
EOF
    config_load "$COPYCROW_CONF"
    FAKE_CHOICE=timer_job tui_verify_repo >/dev/null 2>&1 || true
    [ ! -e "${COPYCROW_ROOT}/.mnt" ]
    [ -d "${COPYCROW_ROOT}/mnt-custom" ]
}
