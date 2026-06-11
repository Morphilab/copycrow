#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# copycrow — tui.sh
# Terminal user interface with whiptail
# ═══════════════════════════════════════════════════════════════════════════════
# shellcheck disable=SC2086,SC2090
# SC2086/SC2090: $jobs and $hosts_list are intentionally expanded for
#                whiptail --menu which expects "key" "desc" "key" "desc" pairs.
set -euo pipefail

# Project root directory
COPYCROW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load configuration only if the file exists
if [[ -z "${CONFIG_LOADED:-}" ]]; then
    source "${COPYCROW_ROOT}/src/config-parser.sh"
    if [[ -f "${COPYCROW_ROOT}/copycrow.conf" ]]; then
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
    if [[ ! -f "${COPYCROW_ROOT}/copycrow.conf" ]]; then
        whiptail --title "copycrow" --msgbox \
            "copycrow.conf not found\n\nRun first: ./copycrow.sh init" 10 60
        return 1
    fi

    while true; do
        local option
        option=$(whiptail --title "copycrow — Main Menu" \
            --menu "Select an option:" 20 70 12 \
            "1" "Create manual backup" \
            "2" "List backups" \
            "3" "Open container" \
            "4" "View system status" \
            "5" "Manage timers" \
            "6" "SSH configuration info" \
            "0" "Exit" \
            3>&1 1>&2 2>&3)

        case "$option" in
            1) tui_create_backup ;;
            2) tui_list_backups ;;
            3) tui_open_container ;;
            4) tui_view_status ;;
            5) tui_manage_timers ;;
            6) tui_ssh_info ;;
            0|"")
                clear
                break
                ;;
        esac
    done
}

# ───────────────────────────────────────────────────────────────────────────────
# tui_list_jobs
# Shows all configured jobs
# ───────────────────────────────────────────────────────────────────────────────
tui_list_jobs() {
    local jobs=""
    local section

    for section in $(config_get_sections); do
        local type=$(config_get_var "$section" "type")
        local host=$(config_get_var "$section" "host")
        local sources=$(config_get_var "$section" "sources")
        jobs+="\"$section\" \"type=$type host=$host\" "
    done

    if [[ -z "$jobs" ]]; then
        whiptail --title "Jobs" --msgbox "No jobs configured.\n\nEdit copycrow.conf" 10 60
        return 1
    fi

    whiptail --title "Configured Jobs" --msgbox \
        "$(for s in $(config_get_sections); do
            echo "[$s]"
            echo "  type: $(config_get_var "$s" "type")"
            echo "  host: $(config_get_var "$s" "host")"
            echo "  sources: $(config_get_var "$s" "sources")"
            echo "  path: $(config_get_var "$s" "remote_path")"
            echo ""
        done)" 20 70
}

# ───────────────────────────────────────────────────────────────────────────────
# tui_create_backup
# Selects a job and creates a backup
# ───────────────────────────────────────────────────────────────────────────────
tui_create_backup() {
    local jobs=""
    local section

    for section in $(config_get_sections); do
        local type=$(config_get_var "$section" "type")
        local host=$(config_get_var "$section" "host")
        jobs+="\"$section\" \"[$type] $host\" "
    done

    if [[ -z "$jobs" ]]; then
        whiptail --title "Error" --msgbox "No jobs configured" 8 50
        return 1
    fi

    local selection
    selection=$(whiptail --title "Create Backup" \
        --menu "Select the job:" 15 60 8 \
        $jobs \
        3>&1 1>&2 2>&3)

    if [[ -z "$selection" ]]; then
        return 0
    fi

    if whiptail --title "Confirm" --yesno \
        "Create backup for job '$selection'?" 8 50; then

        local tmp_out="${COPYCROW_ROOT}/.mnt/.tui-output"

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
    local hosts_list=""

    for section in $(config_get_sections); do
        local host=$(config_get_var "$section" "host")
        if [[ -n "$host" && -z "${hosts_seen[$host]:-}" ]]; then
            hosts_seen[$host]=1
            hosts_list+="\"$host\" \"\" "
        fi
    done

    if [[ -z "$hosts_list" ]]; then
        whiptail --title "Error" --msgbox "No hosts configured" 8 50
        return 1
    fi

    local host_sel
    host_sel=$(whiptail --title "List Backups" \
        --menu "Select host:" 12 50 6 \
        $hosts_list \
        3>&1 1>&2 2>&3)

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
    local hosts_list=""

    for section in $(config_get_sections); do
        local host=$(config_get_var "$section" "host")
        if [[ -n "$host" && -z "${hosts_seen[$host]:-}" ]]; then
            hosts_seen[$host]=1
            hosts_list+="\"$host\" \"\" "
        fi
    done

    if [[ -z "$hosts_list" ]]; then
        whiptail --title "Error" --msgbox "No hosts configured" 8 50
        return 1
    fi

    local host_sel
    host_sel=$(whiptail --title "Open Container" \
        --menu "Select host:" 12 50 6 \
        $hosts_list \
        3>&1 1>&2 2>&3)

    if [[ -z "$host_sel" ]]; then
        return 0
    fi

    local backups_raw
    backups_raw=$(backup_list "$host_sel" "all" 2>/dev/null || true)

    if [[ -z "$backups_raw" ]]; then
        whiptail --title "Error" --msgbox "No backups found on '$host_sel'" 10 60
        return 1
    fi

    local items=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        items+="\"$line\" \"\" "
    done <<< "$backups_raw"

    local archive_sel
    archive_sel=$(whiptail --title "Select Backup" \
        --menu "Choose a backup to open:" 18 60 10 \
        $items \
        3>&1 1>&2 2>&3)

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

    if [[ ! -f "${COPYCROW_ROOT}/copycrow.conf" ]]; then
        status+="copycrow.conf not found\nRun: ./copycrow.sh init\n"
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
        3>&1 1>&2 2>&3)

    case "$option" in
        1)
            if whiptail --title "Install Timers" --yesno \
                "This will create systemd timers for all jobs\nwith type=automatic.\n\nContinue?" 12 60; then

                timer_generate_all
                whiptail --title "Success" --msgbox "Timers installed successfully" 8 50
            fi
            ;;
        2)
            if whiptail --title "Uninstall Timers" --yesno \
                "This will remove all copycrow timers.\n\nContinue?" 10 50; then

                timer_remove_all
                whiptail --title "Success" --msgbox "Timers removed" 8 50
            fi
            ;;
        3)
            local timers
            timers=$(systemctl --user list-timers 'copycrow-*' --no-pager 2>/dev/null || echo "No active timers")
            whiptail --title "Active Timers" --scrolltext --msgbox "$timers" 15 70
            ;;
    esac
}
