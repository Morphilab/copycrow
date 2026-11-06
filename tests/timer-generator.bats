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

@test "timer_generate: reinstall without BORG_PASSCOMMAND reuses the existing env file" {
    # First install wires the passphrase mechanism in.
    export BORG_PASSCOMMAND="pass show copycrow/borg"
    timer_generate "timer_job" >/dev/null
    local env_file="$HOME/.config/copycrow/borg.env"
    cp "$env_file" "${env_file}.golden"

    # Re-install from a shell that lost the export (cron, new terminal):
    # the persisted env file is deliberate state and must stay referenced,
    # otherwise the regenerated unit silently loses the passphrase wiring
    # while the env file keeps sitting on disk unused.
    unset BORG_PASSCOMMAND
    run timer_generate "timer_job"
    [ "$status" -eq 0 ]
    grep -qF "EnvironmentFile=${env_file}" \
        "$HOME/.config/systemd/user/copycrow-timer_job.service"
    cmp -s "$env_file" "${env_file}.golden"
    [[ "$output" == *"reusing"* ]]
    # The wiring exists, so the "automatic backups will fail" warning is a lie.
    ! grep -q "Automatic backups will fail" <<< "$output"
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

@test "timer_generate: %-escapes the conf path and keeps WorkingDirectory bare" {
    # systemd expands %-specifiers in Environment= (and in the path settings):
    # a literal % in a path must be written %% or the unit is rejected /
    # resolves to the wrong path. WorkingDirectory= takes a BARE path —
    # double quotes are not part of its syntax (quoted => "not absolute").
    export COPYCROW_CONF="${COPYCROW_TEST_SANDBOX}/100% job.conf"
    : > "$COPYCROW_CONF"
    run timer_generate "timer_job"
    [ "$status" -eq 0 ]

    local unit="$HOME/.config/systemd/user/copycrow-timer_job.service"
    grep -qF "Environment=\"COPYCROW_CONF=${COPYCROW_TEST_SANDBOX}/100%% job.conf\"" "$unit"
    grep -qF "WorkingDirectory=${COPYCROW_ROOT}" "$unit"
    ! grep -q 'WorkingDirectory="' "$unit"
}

# Re-source the module from a COPY of the tree at <path> (which contains a
# literal '%'): COPYCROW_ROOT is derived from BASH_SOURCE, so this reproduces
# what an install from such a path actually generates. NOT called in a command
# substitution — the re-sourced module must land in the calling shell.
_timer_pct_root() {
    local pct_root="$1"
    mkdir -p "$pct_root"
    cp -r "${COPYCROW_ROOT}/src" "$pct_root/"
    cp "${COPYCROW_ROOT}/copycrow.sh" "$pct_root/"
    COPYCROW_ROOT="$pct_root"
    source "${pct_root}/src/timer-generator.sh"
}

@test "timer_generate: %-escapes ExecStart when the install root contains %" {
    # systemd expands %-specifiers in ExecStart as well: an unescaped '%' in
    # the install path makes the timer exec a nonexistent command (while
    # WorkingDirectory, already escaped, still points at the right tree).
    local pct_root="${COPYCROW_TEST_SANDBOX}/100%root"
    _timer_pct_root "$pct_root"

    run timer_generate "timer_job"
    [ "$status" -eq 0 ]

    local unit="$HOME/.config/systemd/user/copycrow-timer_job.service"
    ! grep -qF "ExecStart=\"${pct_root}/copycrow.sh\"" "$unit"
    grep -qF "ExecStart=\"${pct_root//%/%%}/copycrow.sh\" auto timer_job" "$unit"

    # Independent oracle: systemd itself must resolve the command to the real
    # path. Only asserted where systemd-analyze exists.
    if command -v systemd-analyze >/dev/null 2>&1; then
        run systemd-analyze verify "$unit"
        [[ "$output" != *"is not executable"* ]]
    fi
}

@test "timer_generate_verify: %-escapes ExecStart when the install root contains %" {
    _stub_systemctl 0
    local pct_root="${COPYCROW_TEST_SANDBOX}/200%root"
    _timer_pct_root "$pct_root"
    _verify_timer_conf

    run timer_generate_verify
    [ "$status" -eq 0 ]

    local unit="$HOME/.config/systemd/user/copycrow-verify.service"
    ! grep -qF "ExecStart=\"${pct_root}/copycrow.sh\"" "$unit"
    grep -qF "ExecStart=\"${pct_root//%/%%}/copycrow.sh\" verify-all" "$unit"
}

@test "timer_generate: emits the BORG_PASSPHRASE warning once per install, not per job" {
    _stub_systemctl 0
    export BORG_PASSPHRASE="secret-not-stored"
    _load_timer_conf << 'EOF'
[global]
verify_schedule = monthly

[job_a]
type = automatic
sources = /home
host = local
remote_path = /tmp/ra
schedule = daily

[job_b]
type = automatic
sources = /home
host = local
remote_path = /tmp/rb
schedule = weekly
EOF
    export COPYCROW_CONF="${COPYCROW_TEST_SANDBOX}/test.conf"

    run timer_generate_all
    [ "$status" -eq 0 ]
    [ "$(grep -c 'BORG_PASSPHRASE detected' <<< "$output")" -eq 1 ]
    ! grep -rq "secret-not-stored" "$HOME"
}

@test "timer_generate_all: emits the env-file reuse notice once per install" {
    # The notice describes install-wide state (the env file is reused), so it
    # belongs once per run — not once per generated unit (job + verify).
    _stub_systemctl 0
    export BORG_PASSCOMMAND="pass show copycrow/borg"
    timer_generate "timer_job" >/dev/null 2>&1 || true
    [ -f "$HOME/.config/copycrow/borg.env" ]
    unset BORG_PASSCOMMAND

    _verify_timer_conf
    run timer_generate_all
    [ "$status" -eq 0 ]
    [ "$(grep -c 'reusing' <<< "$output")" -eq 1 ]
}

@test "timer_generate_verify: warns when BORG_PASSPHRASE cannot be stored" {
    # The verify unit needs the passphrase mechanism as much as job units:
    # generating it must not stay silent about an unstorable passphrase.
    _stub_systemctl 0
    _verify_timer_conf
    export BORG_PASSPHRASE="secret-not-stored"

    run timer_generate_verify
    [ "$status" -eq 0 ]
    [[ "$output" == *"BORG_PASSPHRASE detected"* ]]
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

@test "timer_generate_verify: wires EnvironmentFile and %-escapes the conf path" {
    # `borg check` needs the same passphrase mechanism as backups: without
    # EnvironmentFile every scheduled verification of an encrypted repo
    # fails with a missing-passphrase error.
    _stub_systemctl 0
    _verify_timer_conf
    export BORG_PASSCOMMAND="pass show copycrow/borg"
    export COPYCROW_CONF="${COPYCROW_TEST_SANDBOX}/200% verify.conf"
    run timer_generate_verify
    [ "$status" -eq 0 ]

    local unit="$HOME/.config/systemd/user/copycrow-verify.service"
    local env_file="$HOME/.config/copycrow/borg.env"
    [ -f "$env_file" ]
    grep -qF "EnvironmentFile=${env_file}" "$unit"
    grep -qF "Environment=\"COPYCROW_CONF=${COPYCROW_TEST_SANDBOX}/200%% verify.conf\"" "$unit"
    grep -qF "WorkingDirectory=${COPYCROW_ROOT}" "$unit"
}

@test "timer_generate_verify: reuses the existing env file when PASSCOMMAND is unset" {
    _stub_systemctl 0
    _verify_timer_conf
    export BORG_PASSCOMMAND="pass show copycrow/borg"
    timer_generate_verify >/dev/null 2>&1 || true
    local env_file="$HOME/.config/copycrow/borg.env"
    [ -f "$env_file" ]

    unset BORG_PASSCOMMAND
    run timer_generate_verify
    [ "$status" -eq 0 ]
    grep -qF "EnvironmentFile=${env_file}" \
        "$HOME/.config/systemd/user/copycrow-verify.service"
    [[ "$output" == *"reusing"* ]]
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
