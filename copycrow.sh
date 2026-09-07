#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# copycrow — Borg Backup System
# Main entry point
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# Project root directory
COPYCROW_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Load modules
source "${COPYCROW_ROOT}/src/config-parser.sh"
source "${COPYCROW_ROOT}/src/safety.sh"
source "${COPYCROW_ROOT}/src/backup-core.sh"

safety_init

# ───────────────────────────────────────────────────────────────────────────────
# _load_and_validate
# Loads the configuration and enforces FULL validation before any command does
# real work. Per-value security checks already ran inside config_load
# (fail-fast); this adds required-field completeness (type/sources/host/path).
# ───────────────────────────────────────────────────────────────────────────────
_load_and_validate() {
    config_load || return 1
    if ! config_validate; then
        echo "ERROR: Configuration validation failed. Fix the issues above and retry." >&2
        return 1
    fi
}

# ───────────────────────────────────────────────────────────────────────────────
# Help function
# ───────────────────────────────────────────────────────────────────────────────
show_help() {
    cat << 'EOF'
copycrow — Borg Backup System
══════════════════════════════

Usage: ./copycrow.sh [command] [options]

Commands:
  (no arguments)    Open interactive menu (TUI)
  init              Create initial configuration
  backup <job>      Create a manual backup for a job
  manual <job>      Alias for backup
  auto <job>        Create an automatic backup (used by timers)
  dryrun <job>      Show what would be done without executing
  list [job]        List backups
  open <host> <arch> Open a backup container
  verify <job>      Check repository integrity (borg check)
  verify-all        Verify every configured job's repository
  migrate           Convert legacy config to English format
  install           Install systemd timers
  uninstall         Remove systemd timers
  status            Show timer status and last backups
  doctor            Run a system health check
  help              Show this help

Examples:
  ./copycrow.sh                       # Open TUI menu
  ./copycrow.sh init                  # First-time setup
  ./copycrow.sh backup daily_job      # Manual backup
  ./copycrow.sh dryrun daily_job      # Simulate backup (writes nothing)
  ./copycrow.sh auto daily_job        # Automatic backup
   ./copycrow.sh list                  # List all backups
   ./copycrow.sh verify daily_job      # Integrity check (writes nothing)
  ./copycrow.sh migrate               # Convert old config
  ./copycrow.sh install               # Install timers

EOF
}

# Minimum example config (fallback if the .example file doesn't exist)
read -r -d '' COPYCROW_EXAMPLE_FALLBACK << 'EXAMPLE' || true
# ═══════════════════════════════════════════════════════════════════════════════
# copycrow — Configuration
# Edit this file with your real values
# ═══════════════════════════════════════════════════════════════════════════════

[global]
retention_default = --keep-daily 7 --keep-weekly 4 --keep-monthly 6
compression = lz4
auto_prefix = auto-
manual_prefix = manual-
mount_dir = .mnt
logs_dir = logs

[example_job]
type = automatic
sources = /home /etc
host = my-server
remote_path = /backups/copycrow/example
schedule = daily
retention = --keep-daily 7 --keep-weekly 4
EXAMPLE

# ───────────────────────────────────────────────────────────────────────────────
# init — Initial configuration
# ───────────────────────────────────────────────────────────────────────────────
cmd_init() {
    echo "copycrow — Initialization"
    echo "══════════════════════════"

    mkdir -p "${COPYCROW_ROOT}/.mnt"
    mkdir -p "${COPYCROW_ROOT}/logs"

    local example_dest="${COPYCROW_ROOT}/copycrow.conf.example"
    if [[ ! -f "$example_dest" ]]; then
        printf '%s\n' "$COPYCROW_EXAMPLE_FALLBACK" > "$example_dest"
        echo "Created: copycrow.conf.example"
    fi

    if [[ ! -f "${COPYCROW_ROOT}/copycrow.conf" ]]; then
        if [[ -f "$example_dest" ]]; then
            cp "$example_dest" "${COPYCROW_ROOT}/copycrow.conf"
        else
            printf '%s\n' "$COPYCROW_EXAMPLE_FALLBACK" > "${COPYCROW_ROOT}/copycrow.conf"
        fi
        echo "Created: copycrow.conf"
        echo ""
        echo "Next steps:"
        echo "  1. Edit copycrow.conf with your real values"
        echo "  2. Configure SSH hosts in ~/.ssh/config"
        echo "  3. Store the Borg passphrase with pass (timers cannot prompt):"
        echo "       sudo apt install pass && pass insert copycrow/borg"
        echo "       export BORG_PASSCOMMAND='pass show copycrow/borg'"
        echo "     (add that export line to ~/.bashrc)"
        echo "  4. Run: ./copycrow.sh"
    else
        echo "Already exists: copycrow.conf"
    fi
}

# ───────────────────────────────────────────────────────────────────────────────
# backup — Manual backup
# ───────────────────────────────────────────────────────────────────────────────
cmd_backup() {
    local job="${1:-}"

    if [[ -z "$job" ]]; then
        echo "ERROR: You must specify a job" >&2
        echo "Usage: ./copycrow.sh backup <job>" >&2
        return 1
    fi

    if [[ -n "${2:-}" ]]; then
        echo "ERROR: Too many arguments (expected one <job>)" >&2
        echo "Usage: ./copycrow.sh backup <job>" >&2
        return 1
    fi

    if ! _load_and_validate; then
        return 1
    fi

    local type=$(config_get_var "$job" "type")
    if [[ -z "$type" ]]; then
        echo "ERROR: Job '$job' not found" >&2
        return 1
    fi

    safety_lock_run "$job" backup_create "$job" "manual"
}

# ───────────────────────────────────────────────────────────────────────────────
# manual — Alias for backup
# ───────────────────────────────────────────────────────────────────────────────
cmd_manual() {
    cmd_backup "$@"
}

# ───────────────────────────────────────────────────────────────────────────────
# auto — Automatic backup
# ───────────────────────────────────────────────────────────────────────────────
cmd_auto() {
    local job="${1:-}"

    if [[ -z "$job" ]]; then
        echo "ERROR: You must specify a job" >&2
        echo "Usage: ./copycrow.sh auto <job>" >&2
        return 1
    fi

    if [[ -n "${2:-}" ]]; then
        echo "ERROR: Too many arguments (expected one <job>)" >&2
        echo "Usage: ./copycrow.sh auto <job>" >&2
        return 1
    fi

    if ! _load_and_validate; then
        return 1
    fi

    local type=$(config_get_var "$job" "type")
    if [[ -z "$type" ]]; then
        echo "ERROR: Job '$job' not found" >&2
        return 1
    fi

    safety_lock_run "$job" backup_create "$job" "auto"
}

# ───────────────────────────────────────────────────────────────────────────────
# dryrun — Simulate backup (executes nothing)
# ───────────────────────────────────────────────────────────────────────────────
cmd_dryrun() {
    local job="${1:-}"

    if [[ -z "$job" ]]; then
        echo "ERROR: You must specify a job" >&2
        echo "Usage: ./copycrow.sh dryrun <job>" >&2
        return 1
    fi

    if [[ -n "${2:-}" ]]; then
        echo "ERROR: Too many arguments (expected one <job>)" >&2
        echo "Usage: ./copycrow.sh dryrun <job>" >&2
        return 1
    fi

    if ! _load_and_validate; then
        return 1
    fi

    local type=$(config_get_var "$job" "type")
    if [[ -z "$type" ]]; then
        echo "ERROR: Job '$job' not found" >&2
        return 1
    fi

    backup_create "$job" "manual" "true"
}

# ───────────────────────────────────────────────────────────────────────────────
# list — List backups
# ───────────────────────────────────────────────────────────────────────────────
cmd_list() {
    local job="${1:-}"

    if [[ -n "${2:-}" ]]; then
        echo "ERROR: Too many arguments (expected optional <job>)" >&2
        echo "Usage: ./copycrow.sh list [job]" >&2
        return 1
    fi

    if ! _load_and_validate; then
        return 1
    fi

    if [[ -n "$job" ]]; then
        local host=$(config_get_var "$job" "host")
        if [[ -z "$host" ]]; then
            echo "ERROR: Job '$job' not found" >&2
            return 1
        fi
        echo "Backups for job '$job':"
        echo "─────────────────────"
        backup_list "$host" "all"
    else
        declare -A hosts_seen
        local section
        for section in $(config_get_sections); do
            local host=$(config_get_var "$section" "host")
            if [[ -n "$host" && -z "${hosts_seen[$host]:-}" ]]; then
                hosts_seen[$host]=1
                echo "Host: $host"
                echo "──────"
                backup_list "$host" "all"
                echo ""
            fi
        done
    fi
}

# ───────────────────────────────────────────────────────────────────────────────
# open — Open container
# ───────────────────────────────────────────────────────────────────────────────
cmd_open() {
    local host="${1:-}"
    local archive="${2:-}"

    if [[ -z "$host" || -z "$archive" ]]; then
        echo "ERROR: You must specify host and archive" >&2
        echo "Usage: ./copycrow.sh open <host> <archive>" >&2
        return 1
    fi

    if [[ -n "${3:-}" ]]; then
        echo "ERROR: Too many arguments (expected <host> <archive>)" >&2
        echo "Usage: ./copycrow.sh open <host> <archive>" >&2
        return 1
    fi

    if ! _load_and_validate; then
        return 1
    fi

    backup_open "$host" "$archive"
}

# ───────────────────────────────────────────────────────────────────────────────
# verify — Repository integrity check (borg check)
# ───────────────────────────────────────────────────────────────────────────────
cmd_verify() {
    local job="${1:-}"

    if [[ -z "$job" ]]; then
        echo "ERROR: You must specify a job" >&2
        echo "Usage: ./copycrow.sh verify <job>" >&2
        return 1
    fi

    if [[ -n "${2:-}" ]]; then
        echo "ERROR: Too many arguments (expected one <job>)" >&2
        echo "Usage: ./copycrow.sh verify <job>" >&2
        return 1
    fi

    if ! _load_and_validate; then
        return 1
    fi

    local type
    type="$(config_get_var "$job" "type")"
    if [[ -z "$type" ]]; then
        echo "ERROR: Job '$job' not found" >&2
        return 1
    fi

    # Same per-job lock as backups: verify cannot interleave with a running
    # backup of the same job.
    safety_lock_run "$job" backup_verify "$job"
}

# ───────────────────────────────────────────────────────────────────────────────
# verify-all — Verify every configured repository
# ───────────────────────────────────────────────────────────────────────────────
cmd_verify_all() {
    if [[ -n "${1:-}" ]]; then
        echo "ERROR: Too many arguments (expected none)" >&2
        echo "Usage: ./copycrow.sh verify-all" >&2
        return 1
    fi

    if ! _load_and_validate; then
        return 1
    fi

    backup_verify_all
}

# ───────────────────────────────────────────────────────────────────────────────
# migrate — Convert legacy configuration to English
# ───────────────────────────────────────────────────────────────────────────────
cmd_migrate() {
    if ! command -v whiptail &>/dev/null; then
        echo "ERROR: whiptail is not installed" >&2
        return 1
    fi

    config_migrate
}

# ───────────────────────────────────────────────────────────────────────────────
# install — Install timers
# ───────────────────────────────────────────────────────────────────────────────
cmd_install() {
    source "${COPYCROW_ROOT}/src/timer-generator.sh"

    if ! _load_and_validate; then
        return 1
    fi

    timer_generate_all
}

# ───────────────────────────────────────────────────────────────────────────────
# uninstall — Remove timers
# ───────────────────────────────────────────────────────────────────────────────
cmd_uninstall() {
    source "${COPYCROW_ROOT}/src/timer-generator.sh"

    timer_remove_all
}

# ───────────────────────────────────────────────────────────────────────────────
# doctor — System health check
# ───────────────────────────────────────────────────────────────────────────────
cmd_doctor() {
    source "${COPYCROW_ROOT}/src/doctor.sh"
    doctor_run
}

# ───────────────────────────────────────────────────────────────────────────────
# status — System status
# ───────────────────────────────────────────────────────────────────────────────
cmd_status() {
    echo "copycrow — System Status"
    echo "══════════════════════════"

    # Honor the COPYCROW_CONF override like every other command (the old
    # hardcoded ROOT path broke status for custom conf locations).
    local active_conf="${COPYCROW_CONF:-${COPYCROW_ROOT}/copycrow.conf}"
    if [[ ! -f "$active_conf" ]]; then
        echo ""
        echo "Configuration not found: $active_conf"
        echo "Run: ./copycrow.sh init"
        return 1
    fi

    if ! _load_and_validate; then
        return 1
    fi

    echo ""
    echo "Configured jobs:"
    for section in $(config_get_sections); do
        local type=$(config_get_var "$section" "type")
        local host=$(config_get_var "$section" "host")
        echo "  [$section] type=$type host=$host"
    done

    echo ""
    echo "systemd timers:"
    if systemctl --user list-timers 'copycrow-*' --no-pager 2>/dev/null | grep -q "copycrow-"; then
        systemctl --user list-timers 'copycrow-*' --no-pager 2>/dev/null
    else
        echo "  No timers installed"
        echo "  To install: ./copycrow.sh install"
    fi
}

# ───────────────────────────────────────────────────────────────────────────────
# Main entry point
# ───────────────────────────────────────────────────────────────────────────────
main() {
    local command="${1:-}"

    case "$command" in
        init|migrate|install|uninstall|status|doctor)
            # Uniform arity: these take no operands (commit b6e7694 covered
            # only operand-taking commands).
            if [[ $# -gt 1 ]]; then
                echo "ERROR: Too many arguments (command '$command' takes none)" >&2
                return 1
            fi
            case "$command" in
                init)     cmd_init ;;
                migrate)  cmd_migrate ;;
                install)  cmd_install ;;
                uninstall) cmd_uninstall ;;
                status)   cmd_status ;;
                doctor)   cmd_doctor ;;
            esac
            ;;
        backup)
            shift
            cmd_backup "$@"
            ;;
        manual)
            shift
            cmd_manual "$@"
            ;;
        auto)
            shift
            cmd_auto "$@"
            ;;
        dryrun)
            shift
            cmd_dryrun "$@"
            ;;
        list)
            shift
            cmd_list "$@"
            ;;
        open)
            shift
            cmd_open "$@"
            ;;
        verify)
            shift
            cmd_verify "$@"
            ;;
        verify-all)
            shift
            cmd_verify_all "$@"
            ;;
        help|--help|-h)
            if [[ $# -gt 1 ]]; then
                echo "ERROR: Too many arguments (command '$command' takes none)" >&2
                return 1
            fi
            show_help
            ;;
        --version|-V)
            if [[ $# -gt 1 ]]; then
                echo "ERROR: Too many arguments (command '$command' takes none)" >&2
                return 1
            fi
            cat "${COPYCROW_ROOT}/VERSION"
            ;;
        "")
            source "${COPYCROW_ROOT}/src/tui.sh"
            tui_main
            ;;
        *)
            echo "ERROR: Unknown command: $command" >&2
            echo "Run: ./copycrow.sh help" >&2
            return 1
            ;;
    esac
}

main "$@"
