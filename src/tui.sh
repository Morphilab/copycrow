#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# copycrow — tui.sh
# Terminal user interface with whiptail
# ═══════════════════════════════════════════════════════════════════════════════
# shellcheck disable=SC2086,SC2090
# SC2086/SC2090: $jobs and $hosts_list are intentionally expanded for
#                whiptail --menu which expects "key" "desc" "key" "desc" pairs.
set -euo pipefail

COPYCROW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "${CONFIG_LOADED:-}" ]]; then
    source "${COPYCROW_ROOT}/src/config-parser.sh"
    # Honor the COPYCROW_CONF override (config-parser normalized it): the
    # active conf may live anywhere, mirroring the CLI contract.
    if [[ -f "${COPYCROW_CONF}" ]]; then
        if config_load; then
            CONFIG_LOADED="1"
        fi
    fi
fi

# ───────────────────────────────────────────────────────────────────────────────
# tui_main
# Main copycrow menu
# ───────────────────────────────────────────────────────────────────────────────
tui_main() {
    # Same config contract as the CLI: the active conf is $COPYCROW_CONF.
    if [[ ! -f "${COPYCROW_CONF}" ]]; then
        whiptail --title "copycrow" --msgbox \
            "Configuration not found: ${COPYCROW_CONF}\n\nRun first: ./copycrow.sh init" 10 60
        return 1
    fi

    # The conf may have appeared (or failed to parse) after this TUI started:
    # (re)load when the source-time load did not run or did not succeed.
    if [[ -z "${CONFIG_LOADED:-}" ]]; then
        local load_out="" load_rc=0
        load_out="$(config_load 2>&1)" || load_rc=$?
        if (( load_rc != 0 )); then
            whiptail --title "copycrow — Configuration errors" --scrolltext --msgbox \
                "${load_out}\n\nFix the configuration and relaunch." 22 70
            return 1
        fi
        CONFIG_LOADED="1"
    fi

    # Same validation contract as the CLI: refuse to operate on a broken conf.
    local val_out rc=0
    val_out="$(config_validate 2>&1)" || rc=$?
    if (( rc != 0 )); then
        whiptail --title "copycrow — Configuration errors" --scrolltext --msgbox \
            "${val_out}\n\nFix copycrow.conf and relaunch." 22 70
        return 1
    fi

    # Backend calls made from this menu must never show raw interactive
    # prompts over the whiptail UI.
    export COPYCROW_UNDER_TUI=1

    while true; do
        local option
        # Convention-compliant capture: ESC/cancel (rc != 0) must fall through
        # to the "" case, not kill the whole TUI via errexit.
        option=$(whiptail --title "copycrow — Main Menu" \
            --menu "Select an option:" 22 70 12 \
            "1" "Create manual backup" \
            "2" "Dry-run backup (simulate)" \
            "3" "View configured jobs" \
            "4" "List backups" \
            "5" "Open container" \
            "6" "View system status" \
            "7" "Health check (doctor)" \
            "8" "Manage timers" \
            "9" "SSH configuration info" \
            "m" "Migrate legacy configuration" \
            "v" "Verify repository integrity" \
            "s" "Sync job to Proton Drive" \
            "0" "Exit" \
            3>&1 1>&2 2>&3) || option=""

        case "$option" in
            # Handlers report failures through dialogs and may return nonzero;
            # `|| true` keeps the menu loop alive.
            1) tui_create_backup || true ;;
            2) tui_dryrun_backup || true ;;
            3) tui_list_jobs || true ;;
            4) tui_list_backups || true ;;
            5) tui_open_container || true ;;
            6) tui_view_status || true ;;
            7) tui_health_check || true ;;
            8) tui_manage_timers || true ;;
            9) tui_ssh_info || true ;;
            m) tui_migrate_config || true ;;
            v) tui_verify_repo || true ;;
            s) tui_sync_job || true ;;
            0|"")
                # Cosmetic only: a missing/usable-less TERM must not turn the
                # clean exit into an errexit crash.
                clear 2>/dev/null || true
                break
                ;;
        esac
    done
}

# ───────────────────────────────────────────────────────────────────────────────
# tui_list_jobs
# Shows all configured jobs with their full definition.
# ───────────────────────────────────────────────────────────────────────────────
tui_list_jobs() {
    if [[ ${#CONFIG_SECTIONS[@]} -eq 0 ]]; then
        whiptail --title "Jobs" --msgbox "No jobs configured.\n\nEdit copycrow.conf" 10 60
        return 1
    fi

    local s
    whiptail --title "Configured Jobs" --scrolltext --msgbox \
        "$(for s in $(config_get_sections); do
            printf '[%s]\n' "$s"
            printf '  type: %s\n' "$(config_get_var "$s" type)"
            printf '  host: %s\n' "$(config_get_var "$s" host)"
            printf '  sources: %s\n' "$(config_get_var "$s" sources)"
            printf '  path: %s\n' "$(config_get_var "$s" remote_path)"
            printf '  schedule: %s\n' "$(config_get_var "$s" schedule)"
            printf '\n'
        done)" 22 70
}

# ───────────────────────────────────────────────────────────────────────────────
# tui_dryrun_backup
# Selects a job and shows what a backup would do. Nothing is written.
# ───────────────────────────────────────────────────────────────────────────────
tui_dryrun_backup() {
    local -a menu_args=()
    local section

    for section in $(config_get_sections); do
        local type host
        type="$(config_get_var "$section" "type")"
        host="$(config_get_var "$section" "host")"
        menu_args+=("$section" "[${type}] ${host}")
    done

    if [[ ${#menu_args[@]} -eq 0 ]]; then
        whiptail --title "Error" --msgbox "No jobs configured" 8 50
        return 1
    fi

    local selection
    selection=$(whiptail --title "Dry-Run Backup" \
        --menu "Select the job:" 15 60 8 \
        "${menu_args[@]}" \
        3>&1 1>&2 2>&3) || selection=""

    if [[ -z "$selection" ]]; then
        return 0
    fi

    # Convention-compliant capture: dry-run is quiet and fast, so $( ) with
    # explicit rc keeps the TUI alive on validation errors.
    local out="" rc=0
    out="$(backup_create "$selection" "manual" "true" 2>&1)" || rc=$?
    if (( rc == 0 )); then
        whiptail --title "Dry-Run: $selection" --scrolltext --msgbox "$out" 22 70
    else
        whiptail --title "Dry-Run Failed" --scrolltext --msgbox "$out" 22 70
    fi
}

# ───────────────────────────────────────────────────────────────────────────────
# tui_verify_repo
# Selects a job and runs borg check against its repository.
# ───────────────────────────────────────────────────────────────────────────────
tui_verify_repo() {
    local -a menu_args=()
    local section

    for section in $(config_get_sections); do
        local host rpath
        host="$(config_get_var "$section" "host")"
        rpath="$(config_get_var "$section" "remote_path")"
        menu_args+=("$section" "${host}:${rpath}")
    done

    if [[ ${#menu_args[@]} -eq 0 ]]; then
        whiptail --title "Error" --msgbox "No jobs configured" 8 50
        return 1
    fi

    local selection
    selection=$(whiptail --title "Verify Repository" \
        --menu "Run borg check for:" 16 64 8 \
        "${menu_args[@]}" \
        3>&1 1>&2 2>&3) || selection=""

    if [[ -z "$selection" ]]; then
        return 0
    fi

    # Temp file under the CONFIGURED mount dir (never a hardcoded .mnt).
    local tmp_root="${COPYCROW_ROOT}/$(config_get_global 'mount_dir')"
    mkdir -p "$tmp_root"
    local tmp_out="${tmp_root}/.tui-output"
    # Signal-safe cleanup: a kill mid-verify must not leave the temp behind.
    if declare -F safety_add_temp >/dev/null 2>&1; then
        safety_add_temp "$tmp_out"
    fi

    whiptail --title "Verifying..." --infobox "Running borg check for '$selection'..." 8 55

    if backup_verify "$selection" > "$tmp_out" 2>&1; then
        whiptail --title "Verify OK" --scrolltext --msgbox "$(cat "$tmp_out")" 22 70
    else
        whiptail --title "Verify FAILED" --scrolltext --msgbox "$(cat "$tmp_out")" 22 70
    fi
    rm -f "$tmp_out"
}

# ───────────────────────────────────────────────────────────────────────────────
# tui_health_check
# Runs the doctor preflight and shows the report in a dialog.
# ───────────────────────────────────────────────────────────────────────────────
tui_health_check() {
    source "${COPYCROW_ROOT}/src/doctor.sh"

    local out="" rc=0
    out="$(doctor_run 2>&1)" || rc=$?

    local title="Doctor"
    if (( rc != 0 )); then
        title="Doctor — problems found"
    fi
    whiptail --title "$title" --scrolltext --msgbox "$out" 22 70
    return 0
}

# ───────────────────────────────────────────────────────────────────────────────
# tui_migrate_config
# Converts a legacy (Spanish-key) copycrow.conf via config_migrate, then
# reloads the running session so the rest of the menu sees the new format.
# ───────────────────────────────────────────────────────────────────────────────
tui_migrate_config() {
    if ! whiptail --title "Migrate Configuration" --yesno \
        "Convert copycrow.conf from legacy Spanish keys/values\nto the current English format?\n\nA .bak backup is created automatically." 11 60; then
        return 0
    fi

    local out="" rc=0
    out="$(config_migrate 2>&1)" || rc=$?

    if (( rc == 0 )); then
        # Reload so the session reflects the migrated file.
        if config_reload; then
            CONFIG_LOADED="1"
        fi
        whiptail --title "Migrate Configuration" --scrolltext --msgbox \
            "${out}\n\nVerify with: ./copycrow.sh status" 18 70
    else
        whiptail --title "Migrate Failed" --scrolltext --msgbox "$out" 20 70
        return 1
    fi
}

# ───────────────────────────────────────────────────────────────────────────────
# tui_create_backup
# Selects a job and creates a backup
# ───────────────────────────────────────────────────────────────────────────────
tui_create_backup() {
    local -a menu_args=()
    local section

    for section in $(config_get_sections); do
        local type=$(config_get_var "$section" "type")
        local host=$(config_get_var "$section" "host")
        # Array, no quote-string: literal quotes + unquoted expansion fed
        # whiptail garbled pairs (and an odd count broke the menu entirely).
        menu_args+=("$section" "[${type}] ${host}")
    done

    if [[ ${#menu_args[@]} -eq 0 ]]; then
        whiptail --title "Error" --msgbox "No jobs configured" 8 50
        return 1
    fi

    local selection
    selection=$(whiptail --title "Create Backup" \
        --menu "Select the job:" 15 60 8 \
        "${menu_args[@]}" \
        3>&1 1>&2 2>&3) || selection=""

    if [[ -z "$selection" ]]; then
        return 0
    fi

    if whiptail --title "Confirm" --yesno \
        "Create backup for job '$selection'?" 8 50; then

        # Temp file under the CONFIGURED mount dir (never a hardcoded .mnt).
        local tmp_root="${COPYCROW_ROOT}/$(config_get_global 'mount_dir')"
        mkdir -p "$tmp_root"
        local tmp_out="${tmp_root}/.tui-output"
        # Signal-safe cleanup: a kill mid-backup must not leave the temp behind.
        if declare -F safety_add_temp >/dev/null 2>&1; then
            safety_add_temp "$tmp_out"
        fi

        whiptail --title "Creating..." --infobox "Creating backup for job '$selection'..." 8 50

        if backup_create "$selection" "manual" > "$tmp_out" 2>&1; then
            whiptail --title "Success" --msgbox "Backup created successfully" 8 50
        else
            whiptail --title "Error" --scrolltext --msgbox "$(cat "$tmp_out")" 22 70
        fi

        rm -f "$tmp_out"
    fi
}

# ───────────────────────────────────────────────────────────────────────────────
# tui_list_backups
# Lists backups from all configured hosts
# ───────────────────────────────────────────────────────────────────────────────
tui_list_backups() {
    declare -A hosts_seen
    local -a menu_args=()

    for section in $(config_get_sections); do
        local host=$(config_get_var "$section" "host")
        if [[ -n "$host" && -z "${hosts_seen[$host]:-}" ]]; then
            hosts_seen[$host]=1
            menu_args+=("$host" "")
        fi
    done

    if [[ ${#menu_args[@]} -eq 0 ]]; then
        whiptail --title "Error" --msgbox "No hosts configured" 8 50
        return 1
    fi

    local host_sel
    host_sel=$(whiptail --title "List Backups" \
        --menu "Select host:" 12 50 6 \
        "${menu_args[@]}" \
        3>&1 1>&2 2>&3) || host_sel=""

    if [[ -z "$host_sel" ]]; then
        return 0
    fi

    local listing
    listing=$(backup_list "$host_sel" "all" 2>&1 || true)

    if [[ -z "$listing" ]]; then
        whiptail --title "Backups" --msgbox "No backups found on '$host_sel'" 10 60
        return 0
    fi

    whiptail --title "Backups on $host_sel" --scrolltext --msgbox "$listing" 20 70
}

# ───────────────────────────────────────────────────────────────────────────────
# tui_open_container
# Selects a host, then a backup, and opens it
# ───────────────────────────────────────────────────────────────────────────────
tui_open_container() {
    declare -A hosts_seen
    local -a host_args=()

    for section in $(config_get_sections); do
        local host=$(config_get_var "$section" "host")
        if [[ -n "$host" && -z "${hosts_seen[$host]:-}" ]]; then
            hosts_seen[$host]=1
            host_args+=("$host" "")
        fi
    done

    if [[ ${#host_args[@]} -eq 0 ]]; then
        whiptail --title "Error" --msgbox "No hosts configured" 8 50
        return 1
    fi

    local host_sel
    host_sel=$(whiptail --title "Open Container" \
        --menu "Select host:" 12 50 6 \
        "${host_args[@]}" \
        3>&1 1>&2 2>&3) || host_sel=""

    if [[ -z "$host_sel" ]]; then
        return 0
    fi

    local backups_raw
    backups_raw=$(backup_list "$host_sel" "all" 2>/dev/null || true)

    if [[ -z "$backups_raw" ]]; then
        whiptail --title "Error" --msgbox "No backups found on '$host_sel'" 10 60
        return 1
    fi

    local -a item_args=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        item_args+=("$line" "")
    done <<< "$backups_raw"

    local archive_sel
    archive_sel=$(whiptail --title "Select Backup" \
        --menu "Choose a backup to open:" 18 60 10 \
        "${item_args[@]}" \
        3>&1 1>&2 2>&3) || archive_sel=""

    if [[ -z "$archive_sel" ]]; then
        return 0
    fi

    if whiptail --title "Open Container" --yesno \
        "Extract and open '$archive_sel'?" 8 60; then

        backup_open "$host_sel" "$archive_sel"
    fi
}

# ───────────────────────────────────────────────────────────────────────────────
# tui_view_status
# Displays system status
# ───────────────────────────────────────────────────────────────────────────────
tui_view_status() {
    local status=""

    if [[ ! -f "${COPYCROW_CONF}" ]]; then
        status+="Configuration not found: ${COPYCROW_CONF}\n"
        status+="Run: ./copycrow.sh init\n"
    else
        status+="Configuration: OK\n"
    fi

    if command -v borg &>/dev/null; then
        status+="Borg: $(borg --version 2>/dev/null | head -1)\n"
    else
        status+="Borg: NOT INSTALLED\n"
    fi

    status+="\nConfigured jobs:\n"
    for section in $(config_get_sections); do
        local type=$(config_get_var "$section" "type")
        local host=$(config_get_var "$section" "host")
        status+="  [$section] $type → $host\n"
    done
    status+="\nActive timers:\n"
    local timers
    timers=$(systemctl --user list-timers 'copycrow-*' --no-pager 2>/dev/null | grep "copycrow-" || echo "")
    if [[ -n "$timers" ]]; then
        status+="$timers\n"
    else
        status+="  No timers installed\n"
    fi

    whiptail --title "System Status" --msgbox "$status" 22 70
}

# ───────────────────────────────────────────────────────────────────────────────
# tui_ssh_info
# Displays system SSH configuration information
# ───────────────────────────────────────────────────────────────────────────────
tui_ssh_info() {
    local info=""

    if ! command -v ssh &>/dev/null; then
        whiptail --title "Error" --msgbox "SSH is not installed" 8 50
        return 1
    fi

    info+="System SSH Configuration\n"
    info+="═══════════════════════\n\n"

    if [[ -f "$HOME/.ssh/config" ]]; then
        info+="File: ~/.ssh/config\n\n"

        local ssh_config=""
        local in_host=false
        while IFS= read -r line; do
            if [[ "$line" =~ ^Host[[:space:]]+ ]]; then
                in_host=true
                ssh_config+="${line}\n"
            elif [[ "$in_host" == true ]] && [[ "$line" =~ ^[[:space:]]+ ]]; then
                if [[ "$line" =~ IdentityFile ]]; then
                    ssh_config+="    IdentityFile .ssh/key\n"
                else
                    ssh_config+="${line}\n"
                fi
            elif [[ -z "$line" || "$line" == \#* ]]; then
                ssh_config+="${line}\n"
                in_host=false
            else
                in_host=false
                ssh_config+="${line}\n"
            fi
        done < "$HOME/.ssh/config"
        info+="$ssh_config\n"
    else
        info+="${HOME}/.ssh/config not found\n\n"
        info+="To configure an SSH host:\n"
        info+="  1. ssh-keygen -t ed25519 -C 'copycrow'\n"
        info+="  2. ssh-copy-id user@server\n"
        info+="  3. Add an entry to ~/.ssh/config:\n"
        info+="\n"
        info+="Host my-server\n"
        info+="    HostName 1xx.1xx.1.1xx\n"
        info+="    User backupuser\n"
        info+="    Port 22\n"
    fi

    whiptail --title "SSH Configuration" --scrolltext --msgbox "$info" 22 70
}

# ───────────────────────────────────────────────────────────────────────────────
# tui_manage_timers
# Enables or disables systemd timers
# ───────────────────────────────────────────────────────────────────────────────
tui_manage_timers() {
    source "${COPYCROW_ROOT}/src/timer-generator.sh"

    local option
    option=$(whiptail --title "Manage Timers" \
        --menu "Select an option:" 15 60 5 \
        "1" "Install timers (all automatic jobs)" \
        "2" "Uninstall all timers" \
        "3" "View active timers" \
        "0" "Back" \
        3>&1 1>&2 2>&3) || option=""

    case "$option" in
        1)
            if whiptail --title "Install Timers" --yesno \
                "This will create systemd timers for all jobs\nwith type=automatic.\n\nContinue?" 12 60; then

                # Convention-compliant capture: a bare failing call would kill
                # the whole TUI under set -e. Report through a dialog instead.
                local gen_out="" gen_rc=0
                gen_out="$(timer_generate_all 2>&1)" || gen_rc=$?

                if (( gen_rc == 0 )); then
                    whiptail --title "Install Timers" --msgbox \
                        "Timers installed successfully\n\n${gen_out}" 20 70
                else
                    whiptail --title "Install Timers — Error" --scrolltext --msgbox \
                        "Timer installation FAILED.\n\n${gen_out}\n\nFix the issue and retry." 22 70
                    return 1
                fi
            fi
            ;;
        2)
            if whiptail --title "Uninstall Timers" --yesno \
                "This will remove all copycrow timers.\n\nContinue?" 10 50; then

                local rem_out="" rem_rc=0
                rem_out="$(timer_remove_all 2>&1)" || rem_rc=$?

                if (( rem_rc == 0 )); then
                    whiptail --title "Uninstall Timers" --msgbox "Timers removed" 8 50
                else
                    whiptail --title "Uninstall Timers — Error" --scrolltext --msgbox \
                        "Timer removal FAILED.\n\n${rem_out}" 22 70
                    return 1
                fi
            fi
            ;;
        3)
            local timers
            timers=$(systemctl --user list-timers 'copycrow-*' --no-pager 2>/dev/null || echo "No active timers")
            whiptail --title "Active Timers" --scrolltext --msgbox "$timers" 15 70
            ;;
    esac
}

# ───────────────────────────────────────────────────────────────────────────────
# tui_sync_job
# Picks a cloud-enabled job and replicates it under the job's lock (same
# contract as ./copycrow.sh sync <job>).
# ───────────────────────────────────────────────────────────────────────────────
tui_sync_job() {
    local -a menu_args=()
    local section cr host

    for section in $(config_get_sections); do
        cr="$(config_get_var "$section" "cloud_remote")"
        [[ -n "$cr" ]] || continue
        host="$(config_get_var "$section" "host")"
        menu_args+=("$section" "[${host}] ${cr}")
    done

    if [[ ${#menu_args[@]} -eq 0 ]]; then
        whiptail --title "Sync" --msgbox \
            "No jobs with 'cloud_remote' configured.\n\nAdd e.g.  cloud_remote = /Backups/<name>\nto a [job] section (host must be local)." \
            11 60
        return 1
    fi

    local choice
    # Word-splitting INTENTIONAL: whiptail expects flat key/desc pairs.
    choice=$(whiptail --title "Sync to Proton Drive" --menu "Select job:" \
        18 70 8 "${menu_args[@]}" 3>&1 1>&2 2>&3) || return 0

    [[ -n "$choice" ]] || return 0

    source "${COPYCROW_ROOT}/src/cloud-sync.sh"
    if safety_lock_run "$choice" cloud_sync_job "$choice"; then
        whiptail --title "Sync complete" --msgbox \
            "Job '${choice}' replicated to Proton Drive." 9 55
    else
        whiptail --title "Sync FAILED" --msgbox \
            "Job '${choice}' could not be fully synced.\nThe local backup remains valid.\nRetry: ./copycrow.sh sync ${choice}" \
            10 60
    fi
}
