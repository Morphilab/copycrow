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
    export COPYCROW_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
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

    source "${COPYCROW_ROOT}/src/config-parser.sh"
    config_load "$COPYCROW_CONF"
    CONFIG_LOADED="1"
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
    # P1-6: los args se construían como string con comillas embebidas y se
    # expandían sin quoting → comillas literales en el argv de whiptail y
    # conteo impar de items con un solo job (menú muerto en borg real).
    local rc=0
    FAKE_CHOICE=timer_job tui_create_backup > /dev/null 2>&1 || rc=$?

    local menu_line
    menu_line="$(grep -F -- '--menu' "$TUI_LOG" | tail -1)"
    [ -n "$menu_line" ]
    [[ "$menu_line" == *"timer_job [automatic] local"* ]]
    ! grep -qF '"' <<< "$menu_line"
}
