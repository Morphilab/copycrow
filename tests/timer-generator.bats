#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# Tests for timer-generator.sh — runs with a SANDBOXED $HOME.
# No real systemd units are touched; systemctl failures are tolerated.
# ═══════════════════════════════════════════════════════════════════════════════

setup() {
    export COPYCROW_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export COPYCROW_TEST_SANDBOX="$(mktemp -d /tmp/copycrow-timer-XXXXXX)"
    export HOME="${COPYCROW_TEST_SANDBOX}/home"
    mkdir -p "$HOME"
    # CI runners export XDG_CONFIG_HOME globally; pin it into the sandbox so
    # generated units land where the assertions look, on every machine.
    export XDG_CONFIG_HOME="${HOME}/.config"
    unset BORG_PASSPHRASE BORG_PASSCOMMAND SSH_AUTH_SOCK

    source "${COPYCROW_ROOT}/src/config-parser.sh"
    source "${COPYCROW_ROOT}/src/timer-generator.sh"

    _load_timer_conf() {
        local conf="${COPYCROW_TEST_SANDBOX}/test.conf"
        cat > "$conf"
        config_load "$conf" 2>/dev/null
    }
    _load_timer_conf << 'EOF'
[global]

[timer_job]
type = automatic
sources = /home
host = local
remote_path = /tmp/repo
schedule = daily
EOF
}

teardown() {
    unset XDG_CONFIG_HOME
    rm -rf "$COPYCROW_TEST_SANDBOX"
}

@test "timer_convert_schedule: maps schedules to OnCalendar" {
    [ "$(timer_convert_schedule daily)" = "*-*-* 02:00:00" ]
    [ "$(timer_convert_schedule weekly)" = "Mon *-*-* 02:00:00" ]
    [ "$(timer_convert_schedule monthly)" = "*-*-01 02:00:00" ]
    [ "$(timer_convert_schedule minutes06:30)" = "*-*-* 06:30:00" ]
}

@test "timer_generate: creates service+timer units in \$HOME" {
    run timer_generate "timer_job"
    [ "$status" -eq 0 ]
    [ -f "$HOME/.config/systemd/user/copycrow-timer_job.service" ]
    [ -f "$HOME/.config/systemd/user/copycrow-timer_job.timer" ]
    grep -qF "ExecStart=\"${COPYCROW_ROOT}/copycrow.sh\" auto timer_job" \
        "$HOME/.config/systemd/user/copycrow-timer_job.service"
}

@test "timer_generate: NEVER persists BORG_PASSPHRASE (no plaintext secrets)" {
    export BORG_PASSPHRASE="SUPERSECRET-PASS-123"
    run timer_generate "timer_job"
    [ "$status" -eq 0 ]
    # The env file must not exist at all when there is nothing safe to store.
    [ ! -f "$HOME/.config/copycrow/borg.env" ]
    # Belt and suspenders: the secret appears nowhere under sandbox HOME.
    ! grep -rq "SUPERSECRET-PASS-123" "$HOME"
    [[ "$output" == *"will NOT be stored"* ]]
}

@test "timer_generate: persists BORG_PASSCOMMAND with 0600 (command string, no secret)" {
    export BORG_PASSCOMMAND="pass show copycrow/borg"
    run timer_generate "timer_job"
    [ "$status" -eq 0 ]
    local env_file="$HOME/.config/copycrow/borg.env"
    [ -f "$env_file" ]
    grep -q "^BORG_PASSCOMMAND=pass show copycrow/borg$" "$env_file"
    [ "$(stat -c %a "$env_file")" = "600" ]
    ! grep -q "PASSPHRASE" "$env_file"
    grep -q "EnvironmentFile=${env_file}" \
        "$HOME/.config/systemd/user/copycrow-timer_job.service"
}

@test "timer_generate: honors timeout_start_sec=infinity" {
    _load_timer_conf << EOF
[global]
timeout_start_sec = infinity

[timer_job]
type = automatic
sources = /home
host = local
remote_path = /tmp/repo
schedule = daily
EOF
    run timer_generate "timer_job"
    [ "$status" -eq 0 ]
    grep -q "TimeoutStartSec=infinity" \
        "$HOME/.config/systemd/user/copycrow-timer_job.service"
}

@test "timer_generate: default TimeoutStartSec is 3600" {
    run timer_generate "timer_job"
    grep -q "TimeoutStartSec=3600" \
        "$HOME/.config/systemd/user/copycrow-timer_job.service"
}

@test "timer_generate: propagates non-default COPYCROW_CONF via Environment=" {
    export COPYCROW_CONF="/custom/location/my.conf"
    run timer_generate "timer_job"
    [ "$status" -eq 0 ]
    grep -qF "Environment=\"COPYCROW_CONF=/custom/location/my.conf\"" \
        "$HOME/.config/systemd/user/copycrow-timer_job.service"
    unset COPYCROW_CONF
}

@test "timer_generate: omits Environment=COPYCROW_CONF when default path" {
    unset COPYCROW_CONF
    run timer_generate "timer_job"
    ! grep -q "Environment=COPYCROW_CONF" \
        "$HOME/.config/systemd/user/copycrow-timer_job.service"
}

@test "timer_generate: never persists ephemeral SSH_AUTH_SOCK" {
    export SSH_AUTH_SOCK="/run/user/1000/agent-42/socket"
    run timer_generate "timer_job"
    [ "$status" -eq 0 ]
    # The socket path changes between sessions: baking it into the env file
    # guarantees stale-agent failures after a reboot.
    if [ -f "$HOME/.config/copycrow/borg.env" ]; then
        ! grep -q "SSH_AUTH_SOCK" "$HOME/.config/copycrow/borg.env"
    fi
}

@test "timer_remove_all: deletes the credential env file" {
    mkdir -p "$HOME/.config/copycrow"
    : > "$HOME/.config/copycrow/borg.env"
    run timer_remove_all
    [ "$status" -eq 0 ]
    [ ! -f "$HOME/.config/copycrow/borg.env" ]
}

@test "timer_generate: honors XDG_CONFIG_HOME for user unit directory" {
    export XDG_CONFIG_HOME="${COPYCROW_TEST_SANDBOX}/xdg"
    mkdir -p "$XDG_CONFIG_HOME"

    run timer_generate "timer_job"
    [ "$status" -eq 0 ]

    # Units must land under the user's XDG dir, not a hardcoded $HOME/.config.
    [ -f "${XDG_CONFIG_HOME}/systemd/user/copycrow-timer_job.service" ]
    [ ! -e "${HOME}/.config/systemd/user/copycrow-timer_job.service" ]
}

@test "timer_generate: quotes Environment=COPYCROW_CONF value (spaces/%-safe)" {
    export COPYCROW_CONF="${COPYCROW_TEST_SANDBOX}/my conf.conf"
    : > "$COPYCROW_CONF"
    export BORG_PASSCOMMAND="pass show copycrow/borg"

    run timer_generate "timer_job"
    [ "$status" -eq 0 ]

    local unit
    unit="$(printf '%s/systemd/user/copycrow-timer_job.service' "${XDG_CONFIG_HOME:-$HOME/.config}")"
    grep -qF 'Environment="COPYCROW_CONF=' "$unit"
}

# ───────────────────────────────────────────────────────────────────────────────
# Programmable verify timer
# ───────────────────────────────────────────────────────────────────────────────

_stub_systemctl() {
    local rc="${1:-0}"
    mkdir -p "${COPYCROW_TEST_SANDBOX}/bin"
    cat > "${COPYCROW_TEST_SANDBOX}/bin/systemctl" << EOF
#!/usr/bin/env bash
exit ${rc}
EOF
    chmod +x "${COPYCROW_TEST_SANDBOX}/bin/systemctl"
    export PATH="${COPYCROW_TEST_SANDBOX}/bin:${PATH}"
}

_verify_timer_conf() {
    _load_timer_conf << EOF
[global]
verify_schedule = monthly

[timer_job]
type = automatic
sources = /home
host = local
remote_path = /tmp/repo
schedule = daily
EOF
    # timer_generate_all loads THIS conf when CONFIG_LOADED is unset.
    export COPYCROW_CONF="${COPYCROW_TEST_SANDBOX}/test.conf"
}

@test "timer_generate_verify: no-op when verify_schedule unset (rc 0, no units)" {
    run timer_generate_verify
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/.config/systemd/user/copycrow-verify.timer" ]
}

@test "timer_generate_verify: generates + enables monthly verify units" {
    _stub_systemctl 0
    _verify_timer_conf
    run timer_generate_verify
    [ "$status" -eq 0 ]
    grep -q 'OnCalendar=\*-\*-01 02:00:00' "$HOME/.config/systemd/user/copycrow-verify.timer"
    grep -qF 'ExecStart="'"${COPYCROW_ROOT}"'/copycrow.sh" verify-all' \
        "$HOME/.config/systemd/user/copycrow-verify.service"
    grep -qF "Environment=\"COPYCROW_CONF=${COPYCROW_CONF}\"" \
        "$HOME/.config/systemd/user/copycrow-verify.service"
    [[ "$output" == *"Timer enabled: copycrow-verify"* ]]
}

@test "timer_generate_verify: propagates enable failure (rc 1)" {
    _stub_systemctl 1
    _verify_timer_conf
    run timer_generate_verify
    [ "$status" -ne 0 ]
    [[ "$output" == *"Could not enable copycrow-verify"* ]]
}

@test "timer_generate_all: verify timer survives reinstall (orphan-cleanup exempt)" {
    _stub_systemctl 0
    _verify_timer_conf
    timer_generate_all >/dev/null 2>&1 || true
    [ -e "$HOME/.config/systemd/user/copycrow-verify.timer" ]
    timer_generate_all >/dev/null 2>&1 || true
    [ -e "$HOME/.config/systemd/user/copycrow-verify.timer" ]
}

@test "timer_generate_all: counts verify generation failure toward rc" {
    _stub_systemctl 1
    _verify_timer_conf
    run timer_generate_all
    [ "$status" -ne 0 ]
    [[ "$output" == *"Could not enable copycrow-verify"* ]]
}

@test "_timer_cleanup_orphans: daemon-reload after removing orphan units" {
    # stop/disable alone leaves the removed timer loaded until some future
    # daemon-reload; removal must conclude with one when something was removed.
    local sdir="${XDG_CONFIG_HOME}/systemd/user"
    mkdir -p "$sdir"
    printf 'unit\n' > "$sdir/copycrow-ghost.timer"
    printf 'unit\n' > "$sdir/copycrow-ghost.service"

    mkdir -p "${COPYCROW_TEST_SANDBOX}/sysbin"
    cat > "${COPYCROW_TEST_SANDBOX}/sysbin/systemctl" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG:?}"
exit 0
STUB
    chmod +x "${COPYCROW_TEST_SANDBOX}/sysbin/systemctl"
    export SYSTEMCTL_LOG="${COPYCROW_TEST_SANDBOX}/systemctl.log"
    : > "$SYSTEMCTL_LOG"
    export PATH="${COPYCROW_TEST_SANDBOX}/sysbin:${PATH}"

    run _timer_cleanup_orphans ""
    [ "$status" -eq 0 ]
    grep -q "stop copycrow-ghost.timer" "$SYSTEMCTL_LOG"
    [ ! -e "$sdir/copycrow-ghost.timer" ]
    [ ! -e "$sdir/copycrow-ghost.service" ]
    grep -q "daemon-reload" "$SYSTEMCTL_LOG"
}

@test "_timer_cleanup_orphans: no daemon-reload when nothing was removed" {
    mkdir -p "${COPYCROW_TEST_SANDBOX}/sysbin2"
    cat > "${COPYCROW_TEST_SANDBOX}/sysbin2/systemctl" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG2:?}"
exit 0
STUB
    chmod +x "${COPYCROW_TEST_SANDBOX}/sysbin2/systemctl"
    export SYSTEMCTL_LOG2="${COPYCROW_TEST_SANDBOX}/systemctl2.log"
    : > "$SYSTEMCTL_LOG2"
    export PATH="${COPYCROW_TEST_SANDBOX}/sysbin2:${PATH}"

    run _timer_cleanup_orphans ""
    [ "$status" -eq 0 ]
    ! grep -q "daemon-reload" "$SYSTEMCTL_LOG2"
}
