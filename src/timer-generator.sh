#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# copycrow — timer-generator.sh
# systemd timer generator for automatic backups
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# Project root directory
COPYCROW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# systemd user directory (resolved per call: honors XDG_CONFIG_HOME, which
# systemd itself uses to locate user units — hardcoding $HOME/.config broke
# installs for users with a custom XDG config home)
_systemd_user_dir() {
    printf '%s\n' "${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
}

# copycrow timer prefix
TIMER_PREFIX="copycrow"

# ───────────────────────────────────────────────────────────────────────────────
# timer_convert_schedule
# Converts a human-readable schedule to systemd OnCalendar format
# ───────────────────────────────────────────────────────────────────────────────
timer_convert_schedule() {
    local schedule="$1"

    case "$schedule" in
        daily)   echo "*-*-* 02:00:00" ;;
        weekly)  echo "Mon *-*-* 02:00:00" ;;
        monthly) echo "*-*-01 02:00:00" ;;
        minutes*)
            local clock="${schedule#minutes}"
            if [[ -n "$clock" ]]; then
                echo "*-*-* ${clock}:00"
            else
                echo "*-*-* 02:00:00"
            fi
            ;;
        *)       echo "*-*-* 02:00:00" ;;
    esac
}

# ───────────────────────────────────────────────────────────────────────────────
# timer_generate
# Generates .service and .timer files for a job
# ───────────────────────────────────────────────────────────────────────────────
timer_generate() {
    local section="$1"

    local schedule=$(config_get_var "$section" "schedule")
    if [[ -z "$schedule" ]]; then
        echo "WARNING: [$section] has no schedule, defaulting to daily"
        schedule="daily"
    fi

    local timer_name="${TIMER_PREFIX}-${section}"
    local on_calendar
    on_calendar=$(timer_convert_schedule "$schedule")

    local sdir; sdir="$(_systemd_user_dir)"
    mkdir -p "$sdir"

    # TimeoutStartSec from config (validated at load: number or 'infinity').
    local timeout_sec
    timeout_sec="$(config_get_global 'timeout_start_sec')"
    timeout_sec="${timeout_sec:-3600}"

    local env_dir="${HOME}/.config/copycrow"
    local env_file="${env_dir}/borg.env"
    local env_line=""

    # ── SECURITY INVARIANT ────────────────────────────────────────────────────
    # BORG_PASSPHRASE is a SECRET: it is NEVER written to disk.
    # Only BORG_PASSCOMMAND (a command *string*, not the secret itself) is
    # persisted, in a 0600 file inside a 0700 directory, removed by `uninstall`.
    # NOTE: SSH_AUTH_SOCK is deliberately NOT persisted — its path changes
    # between sessions, so baking it into the env file guarantees stale-agent
    # failures after a reboot. For keys with a passphrase, expose an agent to
    # the user systemd session instead (see README troubleshooting).
    # ──────────────────────────────────────────────────────────────────────────
    if [[ -n "${BORG_PASSPHRASE:-}" && -z "${BORG_PASSCOMMAND:-}" ]]; then
        echo "  ⚠  WARNING: BORG_PASSPHRASE detected, but it will NOT be stored on disk."
        echo "     Automatic backups cannot answer interactive passphrase prompts;"
        echo "     they will fail until you configure BORG_PASSCOMMAND instead."
        echo ""
        echo "     Recommended (via pass):"
        echo "       sudo apt install pass"
        echo "       pass insert copycrow/borg"
        echo "       export BORG_PASSCOMMAND='pass show copycrow/borg'"
        echo ""
    fi

    if [[ -n "${BORG_PASSCOMMAND:-}" ]]; then
        mkdir -p "$env_dir"
        chmod 700 "$env_dir"
        {
            echo "# copycrow — environment for automatic backups"
            echo "# Auto-generated. Contains NO secrets:"
            echo "#   BORG_PASSCOMMAND is a command string, not the secret itself."
            printf 'BORG_PASSCOMMAND=%s\n' "${BORG_PASSCOMMAND}"
        } > "$env_file"
        chmod 600 "$env_file"
        env_line="EnvironmentFile=${env_file}"
    fi

    # If the config lives outside the default location, bake its path into
    # the unit: timers must read the SAME conf the user installed from.
    # Quoted per systemd Environment= syntax so spaces/% stay literal.
    local conf_env_line=""
    if [[ -n "${COPYCROW_CONF:-}" && "${COPYCROW_CONF}" != "${COPYCROW_ROOT}/copycrow.conf" ]]; then
        conf_env_line="Environment=\"COPYCROW_CONF=${COPYCROW_CONF}\""
    fi

    cat > "${sdir}/${timer_name}.service" << EOF
[Unit]
Description=copycrow automatic backup - ${section}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart="${COPYCROW_ROOT}/copycrow.sh" auto ${section}
WorkingDirectory=${COPYCROW_ROOT}
${conf_env_line}
${env_line}
StandardOutput=journal
StandardError=journal
TimeoutStartSec=${timeout_sec}

[Install]
WantedBy=default.target
EOF

    cat > "${sdir}/${timer_name}.timer" << EOF
[Unit]
Description=Timer copycrow - ${section} (${schedule})

[Timer]
OnCalendar=${on_calendar}
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

    echo "Generated: ${timer_name}.service + ${timer_name}.timer"
    echo "  OnCalendar: ${on_calendar}"

    if [[ -z "${BORG_PASSPHRASE:-}" && -z "${BORG_PASSCOMMAND:-}" ]]; then
        echo "  ⚠  WARNING: Neither BORG_PASSPHRASE nor BORG_PASSCOMMAND is set."
        echo "     Automatic backups will fail."
        echo ""
        echo "     Recommended (via pass):"
        echo "       sudo apt install pass"
        echo "       pass insert copycrow/borg"
        echo "       export BORG_PASSCOMMAND='pass show copycrow/borg'"
    fi
}

# ───────────────────────────────────────────────────────────────────────────────
# timer_enable
# Enables a specific timer
# ───────────────────────────────────────────────────────────────────────────────
timer_enable() {
    local section="$1"
    local timer_name="${TIMER_PREFIX}-${section}"

    systemctl --user daemon-reload

    if systemctl --user enable --now "${timer_name}.timer" 2>/dev/null; then
        echo "Timer enabled: ${timer_name}"
    else
        echo "ERROR: Could not enable ${timer_name}" >&2
        return 1
    fi
}

# ───────────────────────────────────────────────────────────────────────────────
# timer_disable
# Disables a specific timer
# ───────────────────────────────────────────────────────────────────────────────
timer_disable() {
    local section="$1"
    local timer_name="${TIMER_PREFIX}-${section}"

    systemctl --user stop "${timer_name}.timer" 2>/dev/null || true
    systemctl --user disable "${timer_name}.timer" 2>/dev/null || true

    echo "Timer disabled: ${timer_name}"
}

# ───────────────────────────────────────────────────────────────────────────────
# timer_generate_verify
# Optional integrity timer: when [global] verify_schedule is set, generates
# ONE extra copycrow-verify.{service,timer} running `copycrow.sh verify-all`.
# Unset schedule = feature disabled (no units written, rc 0).
# ───────────────────────────────────────────────────────────────────────────────
timer_generate_verify() {
    local schedule
    schedule="$(config_get_global 'verify_schedule')"
    if [[ -z "$schedule" ]]; then
        return 0
    fi

    local timer_name="${TIMER_PREFIX}-verify"
    local on_calendar
    on_calendar=$(timer_convert_schedule "$schedule")

    local sdir
    sdir="$(_systemd_user_dir)"
    mkdir -p "$sdir"

    # Same conf-propagation rule as job units (B4): timers must read the SAME
    # conf they were installed from.
    local conf_env_line=""
    if [[ -n "${COPYCROW_CONF:-}" && "${COPYCROW_CONF}" != "${COPYCROW_ROOT}/copycrow.conf" ]]; then
        conf_env_line="Environment=\"COPYCROW_CONF=${COPYCROW_CONF}\""
    fi

    cat > "${sdir}/${timer_name}.service" << EOF
[Unit]
Description=copycrow repository integrity check (borg check)

[Service]
Type=oneshot
ExecStart="${COPYCROW_ROOT}/copycrow.sh" verify-all
WorkingDirectory=${COPYCROW_ROOT}
${conf_env_line}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

    cat > "${sdir}/${timer_name}.timer" << EOF
[Unit]
Description=Timer copycrow - repository verification (${schedule})

[Timer]
OnCalendar=${on_calendar}
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

    echo "Generated: ${timer_name}.service + ${timer_name}.timer"
    echo "  OnCalendar: ${on_calendar}"

    systemctl --user daemon-reload
    if systemctl --user enable --now "${timer_name}.timer" 2>/dev/null; then
        echo "Timer enabled: ${timer_name}"
        return 0
    fi
    echo "ERROR: Could not enable ${timer_name}" >&2
    return 1
}

# ───────────────────────────────────────────────────────────────────────────────
# timer_generate_all
# Generates and enables timers for all automatic jobs
# ───────────────────────────────────────────────────────────────────────────────
timer_generate_all() {
    if [[ -z "${CONFIG_LOADED:-}" ]]; then
        source "${COPYCROW_ROOT}/src/config-parser.sh"
        if config_load; then
            CONFIG_LOADED="1"
        else
            echo "ERROR: Could not load configuration" >&2
            return 1
        fi
    fi

    local auto_jobs
    auto_jobs=$(config_get_auto_jobs)

    # Explicit failure tracking: under an exempted errexit context (callers
    # using the `cmd || rc=$?` pattern) a bare failing statement would NOT
    # stop the loop, and the function would end up returning 0 with broken
    # timers installed. Count failures instead of relying on set -e.
    local failures=0 section
    if [[ -n "$auto_jobs" ]]; then
        echo "Generating timers for automatic jobs..."
        while IFS= read -r section; do
            [[ -z "$section" ]] && continue
            if ! timer_generate "$section"; then
                echo "ERROR: Could not generate units for '$section'" >&2
                failures=$((failures + 1))
                continue
            fi
            if ! timer_enable "$section"; then
                failures=$((failures + 1))
            fi
        done <<< "$auto_jobs"
    else
        echo "No jobs with type=automatic found to install timers"
    fi

    _timer_cleanup_orphans "$auto_jobs"

    # The verify timer is independent of the automatic-job list: a config of
    # manual-only jobs can still want scheduled repo verification.
    if ! timer_generate_verify; then
        failures=$((failures + 1))
    fi

    if (( failures > 0 )); then
        echo "ERROR: ${failures} job(s) could not be fully installed." >&2
        return 1
    fi

    echo ""
    echo "Timers installed. Verify with:"
    echo "  systemctl --user list-timers 'copycrow-*'"
    echo ""
    echo "NOTE: User timers only run when a login session is active."
    echo "For backups without login, run: loginctl enable-linger"
    return 0
}

# ───────────────────────────────────────────────────────────────────────────────
# _timer_cleanup_orphans
# Removes timers for jobs that no longer exist in the configuration
# ───────────────────────────────────────────────────────────────────────────────
_timer_cleanup_orphans() {
    local active_jobs="$1"
    local sdir
    sdir="$(_systemd_user_dir)"

    shopt -s nullglob
    local timer_files=("${sdir}/${TIMER_PREFIX}-"*.timer)
    shopt -u nullglob

    local timer_file
    for timer_file in "${timer_files[@]}"; do
        [[ -f "$timer_file" ]] || continue

        local basename
        basename=$(basename "$timer_file" .timer)

        local job_name="${basename#"${TIMER_PREFIX}"-}"

        # copycrow-verify is infrastructure, not a job: never cleaned here
        # (regenerated by timer_generate_all whenever verify_schedule is set).
        if [[ "$job_name" == "verify" ]]; then
            continue
        fi

        local found=false
        local job
        while IFS= read -r job; do
            if [[ "$job" == "$job_name" ]]; then
                found=true
                break
            fi
        done <<< "$active_jobs"

        if [[ "$found" == "false" ]]; then
            echo "  Cleaning up orphan timer: ${basename}"
            systemctl --user stop "${basename}.timer" 2>/dev/null || true
            systemctl --user disable "${basename}.timer" 2>/dev/null || true
            rm -f "$timer_file"
            rm -f "${sdir}/${basename}.service"
        fi
    done
}

# ───────────────────────────────────────────────────────────────────────────────
# timer_remove
# Removes a timer's files
# ───────────────────────────────────────────────────────────────────────────────
timer_remove() {
    local section="$1"
    local timer_name="${TIMER_PREFIX}-${section}"
    local sdir
    sdir="$(_systemd_user_dir)"

    systemctl --user stop "${timer_name}.timer" 2>/dev/null || true
    systemctl --user disable "${timer_name}.timer" 2>/dev/null || true

    rm -f "${sdir}/${timer_name}.service"
    rm -f "${sdir}/${timer_name}.timer"

    echo "Timer removed: ${timer_name}"
}

# ───────────────────────────────────────────────────────────────────────────────
# timer_remove_all
# Removes all copycrow timers
# ───────────────────────────────────────────────────────────────────────────────
timer_remove_all() {
    local sdir
    sdir="$(_systemd_user_dir)"

    # Always clean persisted credentials, even when no timers exist:
    # uninstalling must leave nothing behind.
    rm -f "${HOME}/.config/copycrow/borg.env"
    rmdir "${HOME}/.config/copycrow" 2>/dev/null || true

    shopt -s nullglob
    local timer_files=("${sdir}/${TIMER_PREFIX}-"*.timer)
    shopt -u nullglob

    if [[ ! -f "${timer_files[0]:-}" ]]; then
        echo "No copycrow timers to remove"
        return 0
    fi

    echo "Removing copycrow timers..."

    local timer_file
    for timer_file in "${timer_files[@]}"; do
        [[ -f "$timer_file" ]] || continue
        local name
        name=$(basename "$timer_file" .timer)

        systemctl --user stop "${name}.timer" 2>/dev/null || true
        systemctl --user disable "${name}.timer" 2>/dev/null || true

        rm -f "$timer_file"
        rm -f "${sdir}/${name}.service"

        echo "  Removed: ${name}"
    done

    systemctl --user daemon-reload
    echo ""
    echo "All copycrow timers have been removed"
}

# ───────────────────────────────────────────────────────────────────────────────
# timer_list
# Lists all active copycrow timers
# ───────────────────────────────────────────────────────────────────────────────
timer_list() {
    echo "copycrow timers:"
    echo "═════════════════"

    local timers
    timers=$(systemctl --user list-timers 'copycrow-*' --no-pager 2>/dev/null || true)

    if echo "$timers" | grep -q "copycrow-"; then
        echo "$timers"
    else
        echo "No timers installed"
    fi
}

# ───────────────────────────────────────────────────────────────────────────────
# timer_status
# Shows detailed status of a timer
# ───────────────────────────────────────────────────────────────────────────────
timer_status() {
    local section="$1"
    local timer_name="${TIMER_PREFIX}-${section}"

    echo "Timer: ${timer_name}"
    echo "════════════════════"

    systemctl --user status "${timer_name}.timer" 2>/dev/null || echo "Not found"

    echo ""
    echo "Last executed service:"
    systemctl --user status "${timer_name}.service" 2>/dev/null || echo "Not found"
}
