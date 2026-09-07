#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# copycrow — backup-core.sh
# Borg Backup wrapper with detailed JSON logs
# ═══════════════════════════════════════════════════════════════════════════════
# shellcheck disable=SC2086,SC2090
# SC2086/SC2090: $sources, $retention and $encryption are intentionally
#                expanded unquoted (word-splitting) so borg receives multiple
#                paths/flags as separate arguments.
set -euo pipefail

# Project root directory
COPYCROW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ───────────────────────────────────────────────────────────────────────────────
# _json_escape
# Escapes special characters for valid JSON
# ───────────────────────────────────────────────────────────────────────────────
_json_escape() {
    local val="$1"
    val="${val//\\/\\\\}"
    val="${val//\"/\\\"}"
    val="${val//$'\n'/\\n}"
    val="${val//$'\r'/\\r}"
    val="${val//$'\t'/\\t}"
    printf '%s' "$val"
}

# ───────────────────────────────────────────────────────────────────────────────
# _run_capture
# Captures combined stdout+stderr of a command into a variable WITHOUT letting
# a non-zero exit status kill the caller under `set -e`.
#
# Usage:
#   local out="" rc=0
#   _run_capture out borg list "$repo" || rc=$?
#
# Implementation note: mktemp + redirection instead of $( ) so that the
# assignment itself can never abort the shell before the rc is captured.
# ───────────────────────────────────────────────────────────────────────────────
_run_capture() {
    local __out_var="$1"
    shift

    local __tmp __rc=0
    __tmp="$(mktemp "${TMPDIR:-/tmp}/copycrow-cap.XXXXXX")"
    # Register with the global cleanup net when safety.sh is loaded, so a
    # signal arriving between mktemp and rm cannot orphan the capture file.
    if declare -F safety_add_temp >/dev/null 2>&1; then
        safety_add_temp "$__tmp"
    fi
    "$@" > "$__tmp" 2>&1 || __rc=$?
    printf -v "$__out_var" '%s' "$(cat "$__tmp")"
    rm -f "$__tmp"
    return $__rc
}

# ───────────────────────────────────────────────────────────────────────────────
# backup_safe_archive_name
# Validates a user-supplied archive name before it is ever used to build a
# filesystem path. Blocks traversal ('..'), separators, leading dots/dashes and
# shell metacharacters.
# Returns 0 if the name is safe, 1 otherwise.
# ───────────────────────────────────────────────────────────────────────────────
backup_safe_archive_name() {
    local archive="$1"

    [[ -n "$archive" ]] || return 1
    [[ "$archive" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
    [[ "$archive" != *..* ]] || return 1
    return 0
}

# ───────────────────────────────────────────────────────────────────────────────
# _borg_interactive
# True when borg can prompt the user safely (TTY attached AND no passphrase
# variables exported). Single source of truth — this check used to be
# duplicated in create/extract/prune.
# ───────────────────────────────────────────────────────────────────────────────
_borg_interactive() {
    [[ -t 0 ]] && [[ -z "${BORG_PASSPHRASE:-}" && -z "${BORG_PASSCOMMAND:-}" ]]
}

# ───────────────────────────────────────────────────────────────────────────────
# _interactive_stdin_available
# True when a raw `read -p` prompt is safe: REAL tty on stdin AND not running
# under the TUI (whiptail owns the screen there). The TUI exports
# COPYCROW_UNDER_TUI=1 for its whole session; backend helpers consult this.
# ───────────────────────────────────────────────────────────────────────────────
_interactive_stdin_available() {
    [[ -t 0 ]] && [[ -z "${COPYCROW_UNDER_TUI:-}" ]]
}

# ───────────────────────────────────────────────────────────────────────────────
# backup_init
# Verifies borg is installed and creates required directories
# ───────────────────────────────────────────────────────────────────────────────────────
backup_init() {
    if ! command -v borg &>/dev/null; then
        echo "ERROR: borg is not installed. Run: sudo apt install borgbackup" >&2
        return 1
    fi

    if ! command -v whiptail &>/dev/null; then
        echo "ERROR: whiptail is not installed. Run: sudo apt install whiptail" >&2
        return 1
    fi

    mkdir -p "${COPYCROW_ROOT}/$(config_get_global 'mount_dir')"
    mkdir -p "${COPYCROW_ROOT}/$(config_get_global 'logs_dir')"

    return 0
}

# ───────────────────────────────────────────────────────────────────────────────
# _backup_logs_dir
# Resolves the effective log directory: absolute honored verbatim, relative
# under the project root, empty falls back to <root>/logs. Single source of
# truth shared by backup_log and backup_purge_old_logs.
# ───────────────────────────────────────────────────────────────────────────────
_backup_logs_dir() {
    local base_dir
    base_dir="$(config_get_global 'logs_dir')"
    case "$base_dir" in
        /*) printf '%s\n' "$base_dir" ;;
        "") printf '%s\n' "${COPYCROW_ROOT}/logs" ;;
        *)  printf '%s\n' "${COPYCROW_ROOT}/${base_dir}" ;;
    esac
}

# ───────────────────────────────────────────────────────────────────────────────
# backup_purge_old_logs
# Deletes copycrow-*.log older than logs_retention_days ([global], default 30).
# Bounded to the TOP LEVEL of the resolved log dir and to the copycrow log
# name pattern: nothing else is ever touched.
# ───────────────────────────────────────────────────────────────────────────────
backup_purge_old_logs() {
    local days
    days="$(config_get_global 'logs_retention_days')"
    days="${days:-30}"

    local log_dir
    log_dir="$(_backup_logs_dir)"
    [[ -d "$log_dir" ]] || return 0

    find "$log_dir" -maxdepth 1 -type f -name 'copycrow-*.log' -mtime +"$days" -delete
}

# ───────────────────────────────────────────────────────────────────────────────
# backup_log
# Writes a detailed JSON line to today's log file
# Usage: backup_log "INFO" "daily_job" "create" "ok" "archive=name" "duration=45"
# First 4 args: level, job, action, status
# Remaining args: key=value extras
# logs_dir may be absolute (used by tests/sandboxes) or relative to project root.
# ───────────────────────────────────────────────────────────────────────────────
backup_log() {
    local level="$1" job="$2" action="$3" status="$4"
    shift 4

    local ts
    ts=$(date '+%Y-%m-%dT%H:%M:%S')

    local date_log
    date_log=$(date '+%Y%m%d')

    local log_dir
    log_dir="$(_backup_logs_dir)"

    local log_file="${log_dir}/copycrow-${date_log}.log"

    mkdir -p "$log_dir"

    local json="{\"ts\":\"${ts}\",\"level\":\"$(_json_escape "$level")\",\"job\":\"$(_json_escape "$job")\",\"action\":\"$(_json_escape "$action")\""

    while [[ $# -gt 0 ]]; do
        local extra="$1"
        if [[ "$extra" == *=* ]]; then
            local extra_key="$(_json_escape "${extra%%=*}")"
            local extra_val="$(_json_escape "${extra#*=}")"
            json+=",\"${extra_key}\":\"${extra_val}\""
        fi
        shift
    done

    json+=",\"status\":\"$(_json_escape "$status")\"}"

    printf '%s\n' "$json" >> "$log_file"
}

# ───────────────────────────────────────────────────────────────────────────────
# backup_build_repo_url
# Builds the Borg repository URL based on the host
# ───────────────────────────────────────────────────────────────────────────────
backup_build_repo_url() {
    local host="$1"
    local remote_path="$2"

    if [[ "$host" == "local" ]]; then
        echo "$remote_path"
    else
        # Double slash TOTAL: remote_path is validated absolute (leading '/'),
        # so one literal '/' after the host completes ssh://host//abs/path —
        # borg's absolute-location form (single slash would be home-relative).
        echo "ssh://${host}/${remote_path}"
    fi
}

# ───────────────────────────────────────────────────────────────────────────────
# backup_get_repo_urls_for_host
# Lists EVERY distinct repository URL configured for a host across all jobs.
# (Fixes the first-match blind spot where only one repo per host was visible.)
# Word-splitting of config_get_sections output is intentional.
# ───────────────────────────────────────────────────────────────────────────────
backup_get_repo_urls_for_host() {
    local host="$1"
    local section remote_path
    local urls=()

    for section in $(config_get_sections); do
        [[ "$(config_get_var "$section" "host")" == "$host" ]] || continue
        remote_path="$(config_get_var "$section" "remote_path")"
        [[ -n "$remote_path" ]] || continue
        urls+=("$(backup_build_repo_url "$host" "$remote_path")")
    done

    if (( ${#urls[@]} == 0 )); then
        echo "ERROR: No repositories configured for host '$host'" >&2
        return 1
    fi

    printf '%s\n' "${urls[@]}" | awk '!seen[$0]++'
}

# ───────────────────────────────────────────────────────────────────────────────
# backup_find_repo_for_archive
# Locates which repository of a host contains a given archive.
# Prints the repo URL on success; returns 1 if not found anywhere.
# ───────────────────────────────────────────────────────────────────────────────
backup_find_repo_for_archive() {
    local host="$1"
    local archive="$2"

    local url listing rc=0
    while IFS= read -r url; do
        [[ -n "$url" ]] || continue
        listing=""
        _run_capture listing borg list --format '{archive}{NL}' "$url" || rc=$?
        if (( rc == 0 )) && grep -qx -- "$archive" <<< "$listing"; then
            echo "$url"
            return 0
        fi
    done < <(backup_get_repo_urls_for_host "$host")

    echo "ERROR: Archive '$archive' not found in any repository of host '$host'" >&2
    return 1
}

# ───────────────────────────────────────────────────────────────────────────────
# backup_init_repo
# Initializes a Borg repository if it doesn't exist
# ───────────────────────────────────────────────────────────────────────────────
backup_init_repo() {
    local repo_url="$1"
    local section="${2:-unknown}"

    if borg info "$repo_url" &>/dev/null; then
        backup_log "DEBUG" "$section" "init_repo" "skipped" "repo=${repo_url}" "reason=already_exists"
        return 0
    fi

    backup_log "INFO" "$section" "init_repo" "started" "repo=${repo_url}"
    echo "Initializing repository: $repo_url..."

    # Encryption is always repokey; without passphrase vars borg will prompt
    # interactively this once (timers can't, hence the guidance below).
    local encryption="--encryption=repokey"
    if [[ -z "${BORG_PASSPHRASE:-}" && -z "${BORG_PASSCOMMAND:-}" ]]; then
        echo ""
        echo "╔════════════════════════════════════════════════════════════════╗"
        echo "║  No BORG_PASSCOMMAND detected                                  ║"
        echo "║                                                                ║"
        echo "║  The passphrase will be prompted INTERACTIVELY this time.      ║"
        echo "║  Automatic backups (timers) need BORG_PASSCOMMAND:             ║"
        echo "║    sudo apt install pass                                       ║"
        echo "║    pass insert copycrow/borg                                   ║"
        echo "║    export BORG_PASSCOMMAND='pass show copycrow/borg'           ║"
        echo "╚════════════════════════════════════════════════════════════════╝"
        echo ""
    fi

    local stderr_output="" exit_code=0
    _run_capture stderr_output borg init $encryption "$repo_url" || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        backup_log "INFO" "$section" "init_repo" "ok" "repo=${repo_url}"
        echo "Repository initialized: $repo_url"
        return 0
    else
        if echo "$stderr_output" | grep -qi "passphrase\|PASSPHRASE"; then
            backup_log "ERROR" "$section" "init_repo" "failed" \
                "repo=${repo_url}" \
                "exit_code=${exit_code}" \
                "error=missing_passphrase_or_interactive_failed"
            echo "ERROR: A passphrase is needed to encrypt the repository" >&2
            echo "" >&2
            echo "Options (recommended: pass, GPG-encrypted, automation-ready):" >&2
            echo "" >&2
            echo "  sudo apt install pass" >&2
            echo "  gpg --gen-key" >&2
            echo "  pass init 'your-gpg-id'" >&2
            echo "  pass insert copycrow/borg" >&2
            echo "  export BORG_PASSCOMMAND='pass show copycrow/borg'" >&2
            echo "" >&2
            echo "Interactive prompts work this once; timers never will." >&2
            echo "" >&2
            echo "Then run: borg init --encryption=repokey '${repo_url}'" >&2
        else
            backup_log "ERROR" "$section" "init_repo" "failed" \
                "repo=${repo_url}" \
                "exit_code=${exit_code}" \
                "error=${stderr_output}"
            echo "ERROR: Could not initialize repository: $repo_url" >&2
            echo "  $stderr_output" >&2
        fi
        return 1
    fi
}

# ───────────────────────────────────────────────────────────────────────────────
# backup_check_prerequisites
# Pre-flight check: borg installed, sources exist, SSH host reachable
# ───────────────────────────────────────────────────────────────────────────────
backup_check_prerequisites() {
    local section="$1"

    if ! command -v borg &>/dev/null; then
        backup_log "ERROR" "$section" "check" "failed" "error=borg_not_installed"
        echo "ERROR: borg is not installed. Run: sudo apt install borgbackup" >&2
        return 1
    fi

    local sources
    sources="$(config_get_var "$section" "sources")"
    local any_exists=false
    local src
    for src in $sources; do
        if [[ -e "$src" ]]; then
            any_exists=true
            backup_log "DEBUG" "$section" "check" "ok" "source=${src}" "exists=true"
        else
            backup_log "WARN" "$section" "check" "warning" "source=${src}" "exists=false"
            echo "WARNING: Source not found: $src" >&2
        fi
    done

    if [[ "$any_exists" != "true" ]]; then
        backup_log "ERROR" "$section" "check" "failed" "error=no_sources_exist"
        echo "ERROR: None of the sources exist: $sources" >&2
        return 1
    fi

    local host
    host="$(config_get_var "$section" "host")"
    if [[ "$host" != "local" ]]; then
        if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$host" "exit" &>/dev/null; then
            backup_log "ERROR" "$section" "check" "failed" "host=${host}" "ssh=unreachable"
            echo "ERROR: Cannot connect to '$host' via SSH" >&2
            echo "  Verify:" >&2
            echo "  · ~/.ssh/config has the correct IdentityFile for '$host'" >&2
            echo "  · The key is in the server's authorized_keys" >&2
            echo "  · If the key has a passphrase: ssh-add" >&2

            if _interactive_stdin_available; then
                local continue_choice
                read -r -p "  Continue anyway? (y/N): " continue_choice
                if [[ "$continue_choice" == "y" || "$continue_choice" == "Y" ]]; then
                    # Only here can an empty agent matter (BatchMode already
                    # failed). A passing BatchMode check means the key works
                    # without any agent — warning there was pure noise.
                    if ! ssh-add -l &>/dev/null; then
                        backup_log "WARN" "$section" "check" "warning" "ssh_agent=empty"
                        echo "WARNING: ssh-agent has no unlocked keys." >&2
                        echo "  If your key has a passphrase, run: ssh-add" >&2
                    fi
                else
                    return 1
                fi
            else
                return 1
            fi
        else
            backup_log "DEBUG" "$section" "check" "ok" "host=${host}" "ssh=ok"
        fi

        if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$host" "borg --version" &>/dev/null; then
            backup_log "ERROR" "$section" "check" "failed" "host=${host}" "borg_remote=missing"
            echo "ERROR: Borg is not installed on '$host'" >&2
            echo "  Run: ssh $host 'sudo apt install borgbackup'" >&2
            return 1
        fi
    fi

    return 0
}

# ───────────────────────────────────────────────────────────────────────────────
# backup_notify_failure
# Runs the user hook [global] on_failure_cmd when a backup/verification FAILS.
# Contract (README + copycrow.conf.example):
#   * the hook string is word-split UNQUOTED — same intentional policy as
#     sources/retention; charset validation at load time forbids
#     ; & | $ ` < > \ so no shell/injection surface exists;
#   * context is exposed ONLY via environment variables;
#   * a failing hook is logged (WARN) but NEVER changes the backup's result.
# ───────────────────────────────────────────────────────────────────────────────
backup_notify_failure() {
    local section="$1" archive="$2" exit_code="$3"

    local hook
    hook="$(config_get_global 'on_failure_cmd')"
    [[ -n "$hook" ]] || return 0

    backup_log "INFO" "$section" "notify" "started" \
        "hook=${hook}" "archive=${archive}" "exit_code=${exit_code}"

    local out="" rc=0
    # Word-splitting INTENTIONAL: see function header (charset-whitelisted).
    # Capture pattern per AGENTS.md: never a bare `out=$(cmd)` under set -e.
    out=$(
        export COPYCROW_FAILED_JOB="$section" \
               COPYCROW_FAILURE_ARCHIVE="$archive" \
               COPYCROW_FAILURE_EXIT_CODE="$exit_code"
        ${hook}
    ) || rc=$?

    if (( rc == 0 )); then
        backup_log "INFO" "$section" "notify" "ok" "hook=${hook}"
    else
        backup_log "WARN" "$section" "notify" "failed" \
            "hook=${hook}" "exit_code=${rc}" "error=${out:-unknown}"
        echo "WARNING: on_failure_cmd hook failed (code ${rc})" >&2
        [[ -n "$out" ]] && echo "  ${out}" >&2
    fi
    return 0
}

# ───────────────────────────────────────────────────────────────────────────────
# backup_create
# Creates a backup using borg create
# Usage: backup_create "daily_job" "auto" [dry_run]
# ───────────────────────────────────────────────────────────────────────────────
backup_create() {
    local section="$1"
    local mode="${2:-manual}"
    local dry_run="${3:-false}"

    local sources
    sources="$(config_get_var "$section" "sources")"
    local host
    host="$(config_get_var "$section" "host")"
    local remote_path
    remote_path="$(config_get_var "$section" "remote_path")"
    local compression
    compression="$(config_get_var_or_global "$section" "compression")"
    compression="${compression:-lz4}"

    local prefix
    if [[ "$mode" == "auto" ]]; then
        prefix="$(config_get_global 'auto_prefix')"
    else
        prefix="$(config_get_global 'manual_prefix')"
    fi

    local timestamp
    timestamp=$(date '+%Y%m%d-%H%M%S')
    local name="${prefix}${timestamp}"

    local repo_url
    repo_url=$(backup_build_repo_url "$host" "$remote_path")

    if [[ "$dry_run" == "true" || "$dry_run" == "1" ]]; then
        echo "═══ DRY-RUN: nothing will be written ═══"
        echo ""
        echo "  Job:         $section"
        echo "  Mode:        $mode"
        echo "  Compression: $compression"
        echo "  Source:      $sources"
        echo "  Destination: $repo_url"
        echo "  Archive:     $name"
        # Single Retention line always: job override, else the global default
        # (B9: the old pair printed an empty line AND the default line).
        local job_retention
        job_retention="$(config_get_var "$section" "retention")"
        if [[ -n "$job_retention" ]]; then
            echo "  Retention:   $job_retention"
        else
            echo "  Retention:   (default: $(config_get_global retention_default))"
        fi

        local cloud_remote
        cloud_remote="$(config_get_var "$section" 'cloud_remote')"
        if [[ -n "$cloud_remote" && "$host" == "local" ]]; then
            source "${COPYCROW_ROOT}/src/cloud-sync.sh"
            echo "  Cloud:       $(cloud_pending_count "$section") pending file(s) -> ${cloud_remote} (after backup)"
        fi

        echo ""
        echo "Equivalent command (not executed):"
        printf '  borg create --info --stats --dry-run --compression %q %q::%q %s\n' \
            "$compression" "$repo_url" "$name" "$sources"
        return 0
    fi

    local cmd_safe
    cmd_safe=$(printf 'borg create --info --stats --compression %q %q::%q %s' \
        "$compression" "$repo_url" "$name" "$sources")

    backup_log "INFO" "$section" "create" "started" "archive=${name}" "cmd=${cmd_safe}" "repo=${repo_url}"
    echo "Creating backup: ${name}..."
    echo "  Repo:   ${repo_url}"
    echo "  Source: ${sources}"

    local prereq_rc=0
    backup_check_prerequisites "$section" || prereq_rc=$?
    if (( prereq_rc != 0 )); then
        backup_log "ERROR" "$section" "create" "failed" "archive=${name}" "error=prerequisites"
        backup_notify_failure "$section" "$name" "$prereq_rc"
        backup_purge_old_logs || true
        return 1
    fi

    local init_rc=0
    backup_init_repo "$repo_url" "$section" || init_rc=$?
    if (( init_rc != 0 )); then
        backup_log "ERROR" "$section" "create" "failed" "archive=${name}" "error=init_repo_failed"
        backup_notify_failure "$section" "$name" "$init_rc"
        backup_purge_old_logs || true
        return 1
    fi

    local start
    start=$(date +%s)

    local borg_output="" borg_stderr="" exit_code=0 interactive_run=false

    if _borg_interactive; then
        # Interactive: stream output directly to the terminal.
        borg create \
            --info \
            --stats \
            --compression "${compression}" \
            "${repo_url}::${name}" \
            ${sources} || exit_code=$?
        interactive_run=true
    else
        # Non-interactive (timers): capture output but NEVER die on failure.
        _run_capture borg_output borg create \
            --info \
            --stats \
            --compression "${compression}" \
            "${repo_url}::${name}" \
            ${sources} || exit_code=$?
        borg_stderr="$borg_output"
    fi

    local end
    end=$(date +%s)
    local duration=$(( end - start ))

    if [[ $exit_code -eq 0 ]]; then
        backup_log "INFO" "$section" "create" "ok" \
            "archive=${name}" \
            "duration=${duration}" \
            "repo=${repo_url}"

        echo "Backup created: ${name} (${duration}s)"
        if [[ "$interactive_run" != "true" ]]; then
            echo "$borg_output"
        fi

        backup_prune "$section"

        # Offsite replication (opt-in per job). Runs INSIDE this job's flock,
        # so uploads can never interleave with borg writes/prunes. A cloud
        # failure must NEVER invalidate the finished local backup.
        if [[ -n "$(config_get_var "$section" 'cloud_remote')" && "$host" == "local" ]]; then
            source "${COPYCROW_ROOT}/src/cloud-sync.sh"
            local cloud_rc=0
            cloud_sync_job "$section" || cloud_rc=$?
            if (( cloud_rc != 0 )); then
                echo "WARNING: ProtonDrive sync FAILED (code ${cloud_rc}); the local backup remains valid." >&2
                echo "         Retry later with: ./copycrow.sh sync ${section}" >&2
            fi
        fi

        backup_purge_old_logs || true
    else
        backup_log "ERROR" "$section" "create" "failed" \
            "archive=${name}" \
            "duration=${duration}" \
            "exit_code=${exit_code}" \
            "error=${borg_stderr:-unknown}" \
            "cmd=${cmd_safe}"

        echo "ERROR: Failed to create backup ${name}" >&2
        echo "  Code: ${exit_code}" >&2
        if [[ "$interactive_run" != "true" && -n "${borg_stderr:-}" ]]; then
            echo "  ${borg_stderr}" >&2
        fi
        echo "  Cmd:   ${cmd_safe}" >&2
        backup_notify_failure "$section" "$name" "$exit_code"
        backup_purge_old_logs || true
        return 1
    fi
}

# ───────────────────────────────────────────────────────────────────────────────
# backup_list
# Lists backups from EVERY repository configured for a host, filtered by prefix
# Usage: backup_list "nas-backup" "auto"
# ───────────────────────────────────────────────────────────────────────────────
backup_list() {
    local host="$1"
    local mode="${2:-all}"

    local prefix=""
    case "$mode" in
        auto)   prefix="$(config_get_global 'auto_prefix')" ;;
        manual) prefix="$(config_get_global 'manual_prefix')" ;;
    esac

    local url url_out lrc=0 all="" had_error=false any_ok=false
    while IFS= read -r url; do
        [[ -n "$url" ]] || continue
        url_out=""
        lrc=0
        _run_capture url_out borg list --format '{archive}{NL}' "$url" || lrc=$?
        if (( lrc != 0 )); then
            had_error=true
            continue
        fi
        any_ok=true
        all+="${url_out}"
    done < <(backup_get_repo_urls_for_host "$host")

    # The same archive may exist in two repos of one host (re-targeted jobs):
    # dedupe preserving order (C6).
    if [[ -n "$all" ]]; then
        all="$(printf '%s' "$all" | awk '!seen[$0]++')"
    fi

    if [[ "$any_ok" != "true" ]]; then
        echo "ERROR: Repository not accessible for host '$host'" >&2
        return 1
    fi
    if [[ "$had_error" == "true" ]]; then
        echo "WARNING: some repositories of '$host' could not be listed" >&2
    fi

    # Literal prefix matching (no regex): prefixes are charset-validated at
    # load time, but filtering literally keeps listing correct even for
    # archive names containing regex metacharacters.
    # NOTE: `if` instead of `[[ ]] && cmd`: a false condition as the last
    # statement would poison the loop/function exit code.
    if [[ -n "$prefix" ]]; then
        local arch
        while IFS= read -r arch; do
            [[ -z "$arch" ]] && continue
            if [[ "$arch" == "$prefix"* ]]; then
                printf '%s\n' "$arch"
            fi
        done <<< "$all"
    else
        printf '%s' "$all"
    fi
}

# ───────────────────────────────────────────────────────────────────────────────
# backup_extract
# Extracts a backup to .mnt/<name>/ (umask 077, path contained)
# Usage: backup_extract "nas-backup" "auto-20260603-153000"
# ───────────────────────────────────────────────────────────────────────────────
backup_extract() {
    local host="$1"
    local archive="$2"

    # C1 hardening: never build paths from unvalidated names.
    if ! backup_safe_archive_name "$archive"; then
        echo "ERROR: Invalid archive name: '$archive'" >&2
        return 1
    fi

    local repo_url
    repo_url=$(backup_find_repo_for_archive "$host" "$archive") || return 1

    local mount_root mnt_dir real_root real_target
    mount_root="${COPYCROW_ROOT}/$(config_get_global 'mount_dir')"
    mnt_dir="${mount_root}/${archive}"

    real_root="$(realpath -m -- "$mount_root")"
    if ! ( umask 077 && mkdir -p -- "$mnt_dir" ); then
        echo "ERROR: Cannot create extraction directory: $mnt_dir" >&2
        return 1
    fi
    real_target="$(realpath -m -- "$mnt_dir")"
    case "$real_target" in
        "$real_root"|"$real_root"/*) ;;
        *)
            echo "ERROR: Extraction target escapes the mount directory" >&2
            return 1
            ;;
    esac

    local cmd_safe
    cmd_safe=$(printf 'borg extract %q::%q (cwd: %q)' "$repo_url" "$archive" "$mnt_dir")

    backup_log "INFO" "extraction" "extract" "started" "archive=${archive}" "cmd=${cmd_safe}"
    echo "Extracting ${archive}..."

    local start
    start=$(date +%s)

    local exit_code=0 borg_err=""

    # borg 1.x has NO --target option: extraction goes to the current working
    # directory. Run it via a hardened helper (umask 077 + cd into the
    # validated, pre-created mnt_dir) so extracted files are never readable by
    # group/others regardless of the caller's umask.
    _extract_cwd() {
        local dir="$1" spec="$2"
        umask 077
        cd -- "$dir" || return 1
        # NOTE: no `exec` here — in the captured branch this function runs in
        # the CURRENT shell and exec would replace the whole process, skipping
        # the post-extract hardening below.
        borg extract "$spec"
    }
    if _borg_interactive; then
        ( _extract_cwd "$mnt_dir" "${repo_url}::${archive}" ) || exit_code=$?
    else
        _run_capture borg_err _extract_cwd "$mnt_dir" "${repo_url}::${archive}" || exit_code=$?
    fi

    local end
    end=$(date +%s)
    local duration=$(( end - start ))

    if [[ $exit_code -eq 0 ]]; then
        # Honor the documented umask-077 guarantee end-to-end: borg restores
        # the permissions STORED in the archive, which may be more permissive.
        # The extraction dir is 0700 already; this hardens the files too.
        chmod -R go-rwx -- "$mnt_dir" 2>/dev/null || true
        backup_log "INFO" "extraction" "extract" "ok" "archive=${archive}" "duration=${duration}"
        echo "Extracted to: $mnt_dir (${duration}s)"
        return 0
    else
        backup_log "ERROR" "extraction" "extract" "failed" \
            "archive=${archive}" \
            "duration=${duration}" \
            "exit_code=${exit_code}" \
            "error=${borg_err:-unknown}" \
            "cmd=${cmd_safe}"

        echo "ERROR: Failed to extract ${archive} (code ${exit_code})" >&2
        [[ -n "${borg_err:-}" ]] && echo "  ${borg_err}" >&2
        return 1
    fi
}

# ───────────────────────────────────────────────────────────────────────────────
# backup_prune
# Applies retention policy to a repository.
# Prune failures are logged as WARN and are NON-fatal by design: losing old
# archives automatically would be worse than keeping them one more cycle.
# ───────────────────────────────────────────────────────────────────────────────
backup_prune() {
    local section="$1"

    local host
    host="$(config_get_var "$section" "host")"
    local remote_path
    remote_path="$(config_get_var "$section" "remote_path")"
    local retention
    retention="$(config_get_var "$section" "retention")"

    if [[ -z "$retention" ]]; then
        retention="$(config_get_global 'retention_default')"
    fi

    if [[ -z "$retention" ]]; then
        return 0
    fi

    local repo_url
    repo_url=$(backup_build_repo_url "$host" "$remote_path")

    local cmd_safe
    cmd_safe=$(printf 'borg prune --info %s %q' "$retention" "$repo_url")

    backup_log "DEBUG" "$section" "prune" "started" "retention=${retention}" "cmd=${cmd_safe}"
    echo "Applying retention: ${retention}..."

    local exit_code=0 prune_output=""

    if _borg_interactive; then
        borg prune --info $retention "$repo_url" || exit_code=$?
    else
        _run_capture prune_output borg prune --info $retention "$repo_url" || exit_code=$?
    fi

    if [[ $exit_code -eq 0 ]]; then
        backup_log "INFO" "$section" "prune" "ok" "repo=${repo_url}"
        [[ -n "${prune_output:-}" ]] && echo "$prune_output"
        return 0
    else
        backup_log "WARN" "$section" "prune" "failed" \
            "repo=${repo_url}" \
            "exit_code=${exit_code}" \
            "error=${prune_output:-unknown}"

        echo "WARNING: Retention policy application failed (code ${exit_code})" >&2
        [[ -n "${prune_output:-}" ]] && echo "  ${prune_output}" >&2
        return 0
    fi
}

# ───────────────────────────────────────────────────────────────────────────────
# backup_verify
# `borg check` against ONE job's repository: detects silent corruption.
# Interactive sessions stream progress; captured runs (timers) record output.
# Failures fire on_failure_cmd: verification failing silently defeats the
# whole point of running it.
# ───────────────────────────────────────────────────────────────────────────────
backup_verify() {
    local section="$1"

    local host remote_path
    host="$(config_get_var "$section" "host")"
    remote_path="$(config_get_var "$section" "remote_path")"

    local repo_url
    repo_url=$(backup_build_repo_url "$host" "$remote_path")

    backup_log "INFO" "$section" "verify" "started" "repo=${repo_url}"
    echo "Verifying repository integrity: ${repo_url}..."

    local start end duration
    start=$(date +%s)

    local exit_code=0 out=""
    if _borg_interactive; then
        borg check --info "$repo_url" || exit_code=$?
    else
        _run_capture out borg check --info "$repo_url" || exit_code=$?
    fi

    end=$(date +%s)
    duration=$(( end - start ))

    if [[ $exit_code -eq 0 ]]; then
        backup_log "INFO" "$section" "verify" "ok" \
            "repo=${repo_url}" "duration=${duration}"
        echo "Repository OK: ${repo_url} (${duration}s)"
        [[ -n "$out" ]] && echo "$out"
        return 0
    fi

    backup_log "ERROR" "$section" "verify" "failed" \
        "repo=${repo_url}" "duration=${duration}" \
        "exit_code=${exit_code}" "error=${out:-unknown}"
    echo "ERROR: Repository verification FAILED: ${repo_url} (code ${exit_code})" >&2
    [[ -n "$out" ]] && echo "  ${out}" >&2
    backup_notify_failure "$section" "verify:${repo_url}" "$exit_code"
    return 1
}

# ───────────────────────────────────────────────────────────────────────────────
# backup_verify_all
# Verifies EVERY configured job's repository. Attempts all of them even if
# some fail (one broken repo must not hide another); nonzero if any failed.
# Word-splitting of config_get_sections output is intentional.
# ───────────────────────────────────────────────────────────────────────────────
backup_verify_all() {
    local failures=0 section
    for section in $(config_get_sections); do
        backup_verify "$section" || failures=$((failures + 1))
    done

    if (( failures > 0 )); then
        echo "ERROR: ${failures} repository(ies) failed verification" >&2
        return 1
    fi
    echo "All repositories verified OK."
    return 0
}

# ───────────────────────────────────────────────────────────────────────────────
# backup_open
# Extracts a backup, opens it with xdg-open, waits for the user to close
# ───────────────────────────────────────────────────────────────────────────────
backup_open() {
    local host="$1"
    local archive="$2"

    # C1 hardening: validated before any path or rm -rf usage.
    if ! backup_safe_archive_name "$archive"; then
        echo "ERROR: Invalid archive name: '$archive'" >&2
        return 1
    fi

    local mnt_root mnt_dir
    mnt_root="${COPYCROW_ROOT}/$(config_get_global 'mount_dir')"
    mnt_dir="${mnt_root}/${archive}"

    if [[ -d "$mnt_dir" ]] && [[ "$(ls -A "$mnt_dir" 2>/dev/null)" ]]; then
        echo "Existing extraction found for ${archive}"
        read -r -p "Reuse? (y/n): " reuse
        if [[ "$reuse" != "y" && "$reuse" != "Y" ]]; then
            rm -rf "$mnt_dir"
            backup_extract "$host" "$archive" || return 1
        fi
    else
        backup_extract "$host" "$archive" || return 1
    fi

    backup_log "INFO" "extraction" "open" "ok" "archive=${archive}" "path=${mnt_dir}"

    echo "Opening ${mnt_dir}..."

    if command -v xdg-open &>/dev/null; then
        xdg-open "$mnt_dir" &
    elif command -v open &>/dev/null; then
        open "$mnt_dir" &
    else
        echo "Neither xdg-open nor open found."
        echo "Explore manually: $mnt_dir"
    fi

    echo ""
    echo "Press Enter when you are done reviewing the files..."
    read -r -p ""

    read -r -p "Delete extracted files? (y/n): " cleanup
    if [[ "$cleanup" == "y" || "$cleanup" == "Y" || -z "$cleanup" ]]; then
        rm -rf "$mnt_dir"
        backup_log "INFO" "extraction" "cleanup" "ok" "archive=${archive}"
        echo "Files cleaned up."
    else
        echo "Files kept at: $mnt_dir"
    fi
}
