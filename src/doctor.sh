#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# copycrow — doctor.sh
# One-shot health check: ✓/✗ report with actionable hints.
# Exit: 0 healthy-or-warnings · 1 at least one FAILURE.
# External tools (borg/ssh/systemctl/loginctl/df) invoked normally → tests can
# stub them via PATH. Requires config-parser.sh (and backup-core.sh for
# _backup_logs_dir) sourced beforehand by the caller.
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# Load cloud-sync.sh for proton-drive health checks
source "${COPYCROW_ROOT}/src/cloud-sync.sh"

DOCTOR_OK=0
DOCTOR_WARN=0
DOCTOR_FAIL=0

_doctor_pass() { echo "[ OK ] $*"; DOCTOR_OK=$((DOCTOR_OK + 1)); }
_doctor_warn() { echo "[WARN] $*"; DOCTOR_WARN=$((DOCTOR_WARN + 1)); }
_doctor_fail() { echo "[FAIL] $*"; DOCTOR_FAIL=$((DOCTOR_FAIL + 1)); }

# Available KiB on the filesystem holding $1 (single responsibility: stubbable).
_doctor_disk_avail_kib() {
    df -Pk -- "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}

_doctor_check_binaries() {
    if command -v borg >/dev/null 2>&1; then
        local v=""
        v="$(borg --version 2>/dev/null | head -1)" || v=""
        _doctor_pass "borg: ${v:-present}"
    else
        _doctor_fail "borg not installed — sudo apt install borgbackup"
    fi
    if command -v whiptail >/dev/null 2>&1; then
        _doctor_pass "whiptail present"
    else
        _doctor_warn "whiptail missing (TUI unavailable) — sudo apt install whiptail"
    fi
}

_doctor_check_conf() {
    local active_conf="${COPYCROW_CONF:-${COPYCROW_ROOT}/copycrow.conf}"
    if [[ ! -f "$active_conf" ]]; then
        _doctor_fail "configuration not found: ${active_conf} — run: ./copycrow.sh init"
        return 1
    fi

    # Bare loads (CONFIG_* state must survive for every check below); stderr
    # goes to a temp file because $( ) would run the loader in a SUBSHELL and
    # silently discard the loaded configuration.
    local err_file
    err_file="$(mktemp "${TMPDIR:-/tmp}/copycrow-doctor.XXXXXX")"
    if declare -F safety_add_temp >/dev/null 2>&1; then
        safety_add_temp "$err_file"
    fi

    local rc=0
    config_load "$active_conf" 2> "$err_file" || rc=$?
    if (( rc == 0 )); then
        : > "$err_file"
        config_validate 2> "$err_file" || rc=$?
    fi

    if (( rc != 0 )); then
        _doctor_fail "configuration INVALID (${active_conf}):"
        local line
        while IFS= read -r line; do
            [[ -n "$line" ]] && echo "       ${line}"
        done < "$err_file"
        rm -f "$err_file"
        return 1
    fi
    rm -f "$err_file"
    _doctor_pass "configuration valid (${active_conf})"
    return 0
}

_doctor_check_hosts() {
    local section host seen=""
    # Word-splitting intentional: sections list.
    for section in $(config_get_sections); do
        host="$(config_get_var "$section" host)"
        [[ -n "$host" && "$host" != "local" ]] || continue
        [[ " $seen " != *" $host "* ]] || continue
        seen+=" ${host}"

        if ssh -o ConnectTimeout=5 -o BatchMode=yes "$host" "exit" 2>/dev/null; then
            local rborg=""
            rborg="$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$host" "borg --version" 2>/dev/null | head -1)" || true
            if [[ -n "$rborg" ]]; then
                _doctor_pass "ssh ${host}: reachable (${rborg})"
            else
                _doctor_fail "ssh ${host}: borg NOT installed remotely — ssh ${host} 'sudo apt install borgbackup'"
            fi
        else
            _doctor_fail "ssh ${host}: UNREACHABLE — check ~/.ssh/config IdentityFile, authorized_keys, ssh-add"
        fi
    done
}

_doctor_check_passphrase() {
    if [[ -n "${BORG_PASSCOMMAND:-}" ]]; then
        _doctor_pass "BORG_PASSCOMMAND set (${BORG_PASSCOMMAND})"
    elif [[ -n "${BORG_PASSPHRASE:-}" ]]; then
        _doctor_warn "BORG_PASSPHRASE set, but it is NEVER persisted: timers cannot use it — prefer BORG_PASSCOMMAND via pass (README)"
    else
        _doctor_warn "no passphrase mechanism detected: automatic backups fail until BORG_PASSCOMMAND is set (README: pass)"
    fi
}

_doctor_check_linger() {
    local linger=""
    linger="$(loginctl show-user "${USER:-$(id -un)}" --property=Linger --value 2>/dev/null)" || linger=""
    case "$linger" in
        yes) _doctor_pass "linger enabled (timers run without an active login)" ;;
        no)  _doctor_warn "linger DISABLED: timers only run while logged in — fix: loginctl enable-linger" ;;
        *)   _doctor_warn "could not query linger (loginctl unavailable?) — consider: loginctl enable-linger" ;;
    esac
}

_doctor_check_systemd() {
    local state=""
    state="$(systemctl --user is-system-running 2>/dev/null)" || state=""
    case "$state" in
        running|degraded) _doctor_pass "systemd user session: ${state}" ;;
        *)                _doctor_warn "systemd user session not usable (state='${state:-unknown}') — timers stay inactive here" ;;
    esac
}

_doctor_report_disk() {
    local avail
    avail="$(_doctor_disk_avail_kib "$1")"
    case "${avail:-}" in
        ''|*[!0-9]*) _doctor_warn "disk: cannot determine free space for $1"; return ;;
    esac
    if (( avail < 102400 )); then
        _doctor_fail "disk ${1}: only ${avail} KiB free (<100MiB) — backups will fail; free space"
    elif (( avail < 1048576 )); then
        _doctor_warn "disk ${1}: ${avail} KiB free (<1GiB)"
    else
        _doctor_pass "disk ${1}: $(( avail / 1024 )) MiB free"
    fi
}

_doctor_check_disk() {
    local section src mp mounts=""
    for section in $(config_get_sections); do
        # Word-splitting intentional: sources is a space-separated path list.
        for src in $(config_get_var "$section" sources); do
            [[ -e "$src" ]] || continue
            mp="$(df -Pk -- "$src" 2>/dev/null | awk 'NR==2 {print $6}')" || continue
            [[ -n "$mp" ]] || continue
            [[ " $mounts " != *" $mp "* ]] || continue
            mounts+=" ${mp}"
            _doctor_report_disk "$mp"
        done
    done

    # Local repositories consume THIS machine's disk too (when they exist yet).
    local rp
    for section in $(config_get_sections); do
        [[ "$(config_get_var "$section" host)" == "local" ]] || continue
        rp="$(config_get_var "$section" remote_path)"
        [[ -d "$rp" ]] || continue
        mp="$(df -Pk -- "$rp" 2>/dev/null | awk 'NR==2 {print $6}')" || continue
        [[ -n "$mp" ]] || continue
        [[ " $mounts " != *" $mp "* ]] || continue
        mounts+=" ${mp}"
        _doctor_report_disk "$mp"
    done
}

_doctor_check_permissions() {
    local p perms
    for p in "${COPYCROW_ROOT}/$(config_get_global 'mount_dir')" "$(_backup_logs_dir)"; do
        if [[ ! -d "$p" ]]; then
            _doctor_warn "$(basename "$p") directory missing (created on demand): $p"
            continue
        fi
        perms="$(stat -c %a -- "$p" 2>/dev/null)" || perms=""
        [[ "$perms" =~ ^[0-7]+$ ]] || { _doctor_warn "cannot stat permissions: $p"; continue; }
        if (( (8#$perms & 8#0002) != 0 )); then
            _doctor_fail "${p} is WORLD-WRITABLE (${perms}) — fix: chmod o-w ${p}"
        elif (( (8#$perms & 8#0020) != 0 )); then
            _doctor_warn "${p} is group-writable (${perms}) — recommended 700 (extractions are private)"
        else
            _doctor_pass "permissions ok: ${p} (${perms})"
        fi
    done
}

# ───────────────────────────────────────────────────────────────────────────────
# _doctor_check_cloud
# Proton Drive offsite replication health checks.
# Only runs when at least one job defines cloud_remote.
# ───────────────────────────────────────────────────────────────────────────────
_doctor_check_cloud() {
    local section has_cloud=false
    # Word-splitting intentional: sections list.
    for section in $(config_get_sections); do
        [[ -n "$(config_get_var "$section" cloud_remote)" ]] && { has_cloud=true; break; }
    done
    [[ "$has_cloud" == "true" ]] || return 0

    if cloud_resolve_cli >/dev/null 2>&1; then
        _doctor_pass "proton-drive CLI: $(cloud_resolve_cli)"
    else
        _doctor_fail "proton-drive CLI not found — download from https://proton.me/download/drive/cli or set [global] cloud_cli_path"
        return 0
    fi

    if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]] && ! command -v dbus-run-session >/dev/null 2>&1; then
        _doctor_fail "headless session without dbus-run-session — sudo apt install dbus-x11 (Proton CLI keyring access)"
    else
        _doctor_pass "D-Bus wrapper available for the Proton CLI"
    fi

    local out rc=0
    out=""
    _cloud_exec out filesystem info "/" || rc=$?
    if (( rc == 0 )); then
        _doctor_pass "Proton Drive session alive (keyring auth)"
    else
        _doctor_fail "Proton Drive session NOT usable — authenticate once interactively:"
        echo "       dbus-run-session -- proton-drive auth login"
    fi
}

# ───────────────────────────────────────────────────────────────────────────────
# doctor_run
# Orchestrates all checks; config-dependent ones are skipped when conf is broken.
# ───────────────────────────────────────────────────────────────────────────────
doctor_run() {
    echo "copycrow — doctor"
    echo "═════════════════"

    DOCTOR_OK=0
    DOCTOR_WARN=0
    DOCTOR_FAIL=0

    _doctor_check_binaries

    local conf_ok=true
    _doctor_check_conf || conf_ok=false

    if [[ "$conf_ok" == "true" ]]; then
        _doctor_check_hosts
        _doctor_check_passphrase
        _doctor_check_linger
        _doctor_check_systemd
        _doctor_check_disk
        _doctor_check_permissions
        _doctor_check_cloud
    fi

    echo ""
    echo "Summary: ${DOCTOR_OK} ok · ${DOCTOR_WARN} warning(s) · ${DOCTOR_FAIL} failure(s)"

    if (( DOCTOR_FAIL == 0 )); then
        return 0
    fi
    return 1
}
