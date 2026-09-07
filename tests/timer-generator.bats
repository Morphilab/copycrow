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
    grep -q "ExecStart=${COPYCROW_ROOT}/copycrow.sh auto timer_job" \
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

@test "timer_remove_all: deletes the credential env file" {
    mkdir -p "$HOME/.config/copycrow"
    : > "$HOME/.config/copycrow/borg.env"
    run timer_remove_all
    [ "$status" -eq 0 ]
    [ ! -f "$HOME/.config/copycrow/borg.env" ]
}
