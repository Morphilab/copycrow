# ───────────────────────────────────────────────────────────────────────────────
# copycrow — bash completion
# Ad hoc:     source /path/to/copycrow/completions/copycrow.bash
# Persistent: cp completions/copycrow.bash \
#               ~/.local/share/bash-completion/completions/copycrow
# Job/host names are parsed from the ACTIVE copycrow.conf (honors COPYCROW_CONF).
# ───────────────────────────────────────────────────────────────────────────────

_copycrow_commands() {
    printf '%s\n' init backup manual auto dryrun list open migrate install \
        uninstall status verify verify-all sync doctor help --version
}

_copycrow_jobs() {
    local conf="${COPYCROW_CONF:-./copycrow.conf}"
    [[ -f "$conf" ]] || return 0
    # Section headers minus brackets; 'global' is settings, not a job.
    sed -nE 's/^\[([a-zA-Z0-9_-]+)\][[:space:]]*$/\1/p' "$conf" | grep -vx global
}

_copycrow_hosts() {
    local conf="${COPYCROW_CONF:-./copycrow.conf}"
    [[ -f "$conf" ]] || return 0
    # shellcheck disable=SC2016  # sed pattern is literal, no expansion needed
    sed -nE 's/^[[:space:]]*host[[:space:]]*=[[:space:]]*([^[:space:]#]+)[[:space:]]*$/\1/p' "$conf" \
        | awk '!seen[$0]++'
}

_copycrow() {
    local cur
    cur="${COMP_WORDS[COMP_CWORD]}"

    if (( COMP_CWORD <= 1 )); then
        # Word-splitting INTENTIONAL: compgen -W expects a whitespace list.
        # shellcheck disable=SC2207
        COMPREPLY=($(compgen -W "$(_copycrow_commands)" -- "$cur"))
        return 0
    fi

    local cmd="${COMP_WORDS[1]}"
    case "$cmd" in
        backup|manual|auto|dryrun|verify|sync|list)
            # Word-splitting INTENTIONAL (compgen -W contract). See above.
            # shellcheck disable=SC2207
            COMPREPLY=($(compgen -W "$(_copycrow_jobs)" -- "$cur"))
            ;;
        open)
            if (( COMP_CWORD == 2 )); then
                # Word-splitting INTENTIONAL (compgen -W contract). See above.
                # shellcheck disable=SC2207
                COMPREPLY=($(compgen -W "$(_copycrow_hosts)" -- "$cur"))
            fi
            ;;
    esac
    return 0
}

complete -F _copycrow copycrow copycrow.sh 2>/dev/null || true
