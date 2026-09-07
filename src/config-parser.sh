#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# copycrow — config-parser.sh
# INI configuration parser for copycrow
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# Project root directory
COPYCROW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Configuration file (overridable via environment for sandboxes/tests)
COPYCROW_CONF="${COPYCROW_CONF:-${COPYCROW_ROOT}/copycrow.conf}"

# Associative arrays for config storage
declare -gA CONFIG_GLOBAL
declare -gA CONFIG_JOBS

# List of sections (jobs) found
CONFIG_SECTIONS=()

# Seen-section registry (duplicate protection)
declare -gA CONFIG_SECTION_SEEN

# ───────────────────────────────────────────────────────────────────────────────
# _config_key_allowed
# Whitelist of accepted configuration keys.
# Unknown keys make config_load FAIL — typos can never create silent holes.
# ───────────────────────────────────────────────────────────────────────────────
_config_key_allowed() {
    local scope="$1"
    local key="$2"

    case "${scope}:${key}" in
        global:retention_default|global:compression|global:auto_prefix|\
global:manual_prefix|global:mount_dir|global:logs_dir|global:timeout_start_sec|\
global:logs_retention_days|global:verify_schedule|global:on_failure_cmd|\
global:cloud_cli_path|\
job:type|job:sources|job:host|job:remote_path|job:schedule|job:retention|\
job:compression|job:cloud_remote)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# ───────────────────────────────────────────────────────────────────────────────
# config_load
# Loads copycrow.conf and parses all sections.
# Fail-fast: unknown keys or values failing config_validate_value abort loading,
# so anti-injection checks cannot be bypassed downstream.
# ───────────────────────────────────────────────────────────────────────────────
config_load() {
    local file="${1:-$COPYCROW_CONF}"

    if [[ ! -f "$file" ]]; then
        echo "ERROR: Configuration file not found: $file" >&2
        echo "Run: ./copycrow.sh init" >&2
        return 1
    fi

    # Reset state so repeated loads never accumulate stale entries.
    CONFIG_GLOBAL=()
    CONFIG_JOBS=()
    CONFIG_SECTIONS=()
    CONFIG_SECTION_SEEN=()

    local current_section=""
    local section_skip=0
    local line

    while IFS= read -r line || [[ -n "$line" ]]; do
        # UTF-8 BOM (Windows editors): strip it or the first section header
        # becomes invisible and every key "appears before any section".
        line="${line#$'\xEF\xBB\xBF'}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        [[ -z "$line" || "$line" == \#* ]] && continue

        if [[ "$line" =~ ^\[([a-zA-Z0-9_-]+)\]$ ]]; then
            current_section="${BASH_REMATCH[1]}"
            if [[ "$current_section" == "global" ]]; then
                continue
            fi
            if [[ -n "${CONFIG_SECTION_SEEN[$current_section]:-}" ]]; then
                echo "WARNING: [$file] duplicate section '$current_section' ignored (first definition wins)" >&2
                # Boolean flag, NOT a sentinel section name: any name the user
                # can write must remain usable as a normal job.
                section_skip=1
                continue
            fi
            CONFIG_SECTION_SEEN["$current_section"]=1
            CONFIG_SECTIONS+=("$current_section")
            section_skip=0
            continue
        fi

        if [[ "$line" =~ ^([a-zA-Z0-9_-]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"

            # Explicit empty values (`key =`) are accepted and stored as "" so
            # downstream fallbacks behave and errors stay accurate. Only
            # non-empty values need comment stripping / quote handling.
            if [[ -n "$value" ]]; then
                # Strip trailing inline comments BEFORE quote handling.
                # Limitation: a quoted value containing ' #' will be truncated;
                # no whitelisted key legitimately contains such a sequence.
                value="${value%%[[:space:]]'#'*}"
                # Re-trim trailing whitespace left by the comment cut.
                value="${value%"${value##*[![:space:]]}"}"

                value="${value#\"}"
                value="${value%\"}"
                value="${value#\'}"
                value="${value%\'}"
            fi

            # `at HH:MM` is the friendly alias for "daily at HH:MM";
            # normalize to the canonical internal form (minutesHH:MM) so
            # validation and timer conversion keep a single code path.
            if [[ "$key" == "schedule" && "$value" =~ ^at[[:space:]]+([0-9]{2}:[0-9]{2})$ ]]; then
                value="minutes${BASH_REMATCH[1]}"
            fi

            if [[ "$section_skip" == "1" ]]; then
                continue
            fi

            # A key before any [section] header would be stored under an
            # empty section name and silently lost. Fail fast instead.
            if [[ -z "$current_section" ]]; then
                echo "ERROR: [$file] key '$key' appears before any [section] header" >&2
                echo "       Move it inside [global] or a job section." >&2
                return 1
            fi

            local scope="job"
            [[ "$current_section" == "global" ]] && scope="global"

            if ! _config_key_allowed "$scope" "$key"; then
                echo "ERROR: [$file] unknown key '$key' in section '${current_section:-<none>}'" >&2
                echo "       See copycrow.conf.example for accepted keys." >&2
                return 1
            fi

            if ! config_validate_value "$key" "$value"; then
                return 1
            fi

            if [[ "$scope" == "global" ]]; then
                CONFIG_GLOBAL["$key"]="$value"
            else
                # ':' separator: section names cannot contain ':', so
                # <section>:<key> collisions are structurally impossible.
                CONFIG_JOBS["${current_section}:${key}"]="$value"
            fi
        fi
    done < "$file"

    return 0
}

# ───────────────────────────────────────────────────────────────────────────────
# config_get_sections
# Returns the list of jobs found in the configuration
# ───────────────────────────────────────────────────────────────────────────────
config_get_sections() {
    printf '%s\n' "${CONFIG_SECTIONS[@]}"
}

# ───────────────────────────────────────────────────────────────────────────────
# config_get_var
# Returns the value of a variable from a specific job
# Usage: config_get_var "daily_job" "host"
# ───────────────────────────────────────────────────────────────────────────────
config_get_var() {
    local section="$1"
    local variable="$2"
    local compound_key="${section}:${variable}"

    printf '%s' "${CONFIG_JOBS[$compound_key]:-}"
}

# ───────────────────────────────────────────────────────────────────────────────
# config_get_var_or_global
# Returns the value of a variable from a job, with fallback to [global]
# Usage: config_get_var_or_global "daily_job" "compression"
# ───────────────────────────────────────────────────────────────────────────────
config_get_var_or_global() {
    local section="$1"
    local variable="$2"
    local compound_key="${section}:${variable}"

    if [[ -n "${CONFIG_JOBS[$compound_key]:-}" ]]; then
        printf '%s' "${CONFIG_JOBS[$compound_key]}"
    else
        printf '%s' "${CONFIG_GLOBAL[$variable]:-}"
    fi
}

# ───────────────────────────────────────────────────────────────────────────────
# config_get_global
# Returns the value of a variable from the [global] section
# Usage: config_get_global "retention_default"
# ───────────────────────────────────────────────────────────────────────────────
config_get_global() {
    local variable="$1"
    printf '%s' "${CONFIG_GLOBAL[$variable]:-}"
}

# ───────────────────────────────────────────────────────────────────────────────
# config_get_auto_jobs
# Returns only jobs with type=automatic
# ───────────────────────────────────────────────────────────────────────────────
config_get_auto_jobs() {
    local section
    for section in "${CONFIG_SECTIONS[@]}"; do
        if [[ "$(config_get_var "$section" "type")" == "automatic" ]]; then
            echo "$section"
        fi
    done
}

# ───────────────────────────────────────────────────────────────────────────────
# config_get_manual_jobs
# Returns only jobs with type=manual
# ───────────────────────────────────────────────────────────────────────────────
config_get_manual_jobs() {
    local section
    for section in "${CONFIG_SECTIONS[@]}"; do
        if [[ "$(config_get_var "$section" "type")" == "manual" ]]; then
            echo "$section"
        fi
    done
}

# ───────────────────────────────────────────────────────────────────────────────
# config_validate_value
# Checks that a config value does not contain dangerous characters or payloads.
# (anti command injection / path traversal / argument injection)
# Called automatically by config_load (fail-fast).
# ───────────────────────────────────────────────────────────────────────────────
config_validate_value() {
    local key="$1"
    local value="$2"

    # mount_dir must never be empty: an empty value would resolve the
    # extraction root to the project root itself.
    if [[ "$key" == "mount_dir" && -z "$value" ]]; then
        echo "ERROR: [mount_dir] must not be empty (extractions would land in the project root)" >&2
        return 1
    fi

    if [[ -z "$value" ]]; then
        return 0
    fi

    # Shell metacharacters are forbidden everywhere.
    case "$key" in
        host|remote_path|sources|mount_dir|logs_dir|compression|retention|retention_default|auto_prefix|manual_prefix|on_failure_cmd|cloud_remote|cloud_cli_path)
            if [[ "$value" =~ [\;\&\|\$\`\<\>\\] ]]; then
                echo "ERROR: [$key] contains forbidden characters" >&2
                return 1
            fi
            ;;
    esac

    case "$key" in
        host)
            if [[ "$value" != "local" ]]; then
                # No leading dash: blocks SSH option injection (-oProxyCommand=...)
                if ! [[ "$value" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]]; then
                    echo "ERROR: [host] '$value' is not a valid SSH alias" >&2
                    return 1
                fi
            fi
            ;;
        remote_path)
            # A relative path would build a malformed ssh:// URL (the host and
            # path get concatenated): require absolute from the start.
            if [[ "$value" != /* ]]; then
                echo "ERROR: [remote_path] '$value' must be an absolute path starting with '/'" >&2
                return 1
            fi
            if [[ "$value" == *".."* ]]; then
                echo "ERROR: [$key] must not contain '..'" >&2
                return 1
            fi
            ;;
        mount_dir)
            # Extractions and their cleanup are contained under
            # ${COPYCROW_ROOT}/<mount_dir>: an absolute value would silently
            # resolve elsewhere. Keep it relative, by contract.
            # NOTE: must precede the generic path case below (first match wins).
            if [[ "$value" == /* ]]; then
                echo "ERROR: [mount_dir] must be relative to the project root (got '$value')" >&2
                return 1
            fi
            if [[ "$value" == *".."* ]]; then
                echo "ERROR: [$key] must not contain '..'" >&2
                return 1
            fi
            ;;
        cloud_remote)
            # Destination folder INSIDE Proton Drive: absolute-style path,
            # restricted charset, no traversal components.
            if [[ "$value" != /* ]]; then
                echo "ERROR: [cloud_remote] '$value' must start with '/' (path inside Proton Drive)" >&2
                return 1
            fi
            if ! [[ "$value" =~ ^/[A-Za-z0-9._/-]*$ ]]; then
                echo "ERROR: [cloud_remote] '$value' is not a valid Drive path (letters, digits, . _ / -)" >&2
                return 1
            fi
            if [[ "$value" == *".."* ]]; then
                echo "ERROR: [$key] must not contain '..'" >&2
                return 1
            fi
            if [[ "$value" == */ || "$value" == *"//"* ]]; then
                echo "ERROR: [cloud_remote] '$value' must not end with '/' or contain '//'" >&2
                return 1
            fi
            ;;
        cloud_cli_path)
            # Executable location: generous but option-safe charset (spaces OK,
            # metacharacters already banned above); '..' never allowed.
            if [[ "$value" == -* ]]; then
                echo "ERROR: [cloud_cli_path] '$value' must not start with '-'" >&2
                return 1
            fi
            if ! [[ "$value" =~ ^[A-Za-z0-9._/[:space:]-]+$ ]]; then
                echo "ERROR: [cloud_cli_path] '$value' is not a valid executable path" >&2
                return 1
            fi
            if [[ "$value" == *".."* ]]; then
                echo "ERROR: [$key] must not contain '..'" >&2
                return 1
            fi
            ;;
        logs_dir|sources)
            if [[ "$value" == *".."* ]]; then
                echo "ERROR: [$key] must not contain '..'" >&2
                return 1
            fi
            ;;
        compression)
            case "$value" in
                lz4|zstd|zlib|lzma|none) ;;
                *)
                    echo "ERROR: [compression] '$value' is not valid (lz4, zstd, zlib, lzma, none)" >&2
                    return 1
                    ;;
            esac
            ;;
        retention|retention_default)
            # Only borg prune --keep-* flags followed by numbers.
            # Word-splitting is intentional: retention is a flag list.
            local token
            for token in $value; do
                case "$token" in
                    --keep-secondly|--keep-minutely|--keep-hourly|--keep-daily|\
--keep-weekly|--keep-monthly|--keep-yearly)
                        ;;
                    *[!0-9]*)
                        echo "ERROR: [$key] invalid token '$token' (use e.g. --keep-daily 7)" >&2
                        return 1
                        ;;
                esac
            done
            ;;
        type)
            case "$value" in
                automatic|manual) ;;
                *)
                    echo "ERROR: [type] '$value' is not valid (automatic | manual)" >&2
                    return 1
                    ;;
            esac
            ;;
        auto_prefix|manual_prefix)
            # Prefixes become archive names AND are used for literal prefix
            # matching when listing: keep them regex/option-safe by charset.
            if ! [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
                echo "ERROR: [$key] '$value' is not a valid prefix (letters, digits, . _ -; must not start with a dash)" >&2
                return 1
            fi
            ;;
        schedule)
            case "$value" in
                daily|weekly|monthly) ;;
                minutes*)
                    local clock="${value#minutes}"
                    if [[ "$clock" =~ ^[0-9]{2}:[0-9]{2}$ ]]; then
                        local hh="${clock%%:*}"
                        local mm="${clock##*:}"
                        if (( 10#$hh > 23 || 10#$mm > 59 )); then
                            echo "ERROR: [schedule] '$value' out of range (HH 00-23, MM 00-59)" >&2
                            return 1
                        fi
                    else
                        echo "ERROR: [schedule] '$value' invalid format (use HH:MM as 'minutesHH:MM' or 'at HH:MM')" >&2
                        return 1
                    fi
                    ;;
                *)
                    echo "ERROR: [schedule] '$value' is not valid (daily | weekly | monthly | minutesHH:MM | at HH:MM)" >&2
                    return 1
                    ;;
            esac
            ;;
        logs_retention_days)
            if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
                echo "ERROR: [logs_retention_days] '$value' must be a positive number of days" >&2
                return 1
            fi
            ;;
        verify_schedule)
            case "$value" in
                daily|weekly|monthly) ;;
                *)
                    echo "ERROR: [verify_schedule] '$value' is not valid (daily | weekly | monthly; unset disables scheduled repo verification)" >&2
                    return 1
                    ;;
            esac
            ;;
        timeout_start_sec)
            if [[ "$value" != "infinity" ]] && ! [[ "$value" =~ ^[0-9]+$ ]]; then
                echo "ERROR: [timeout_start_sec] must be a number of seconds or 'infinity'" >&2
                return 1
            fi
            ;;
    esac

    return 0
}

# ───────────────────────────────────────────────────────────────────────────────
# config_validate
# Validates that every job has its required fields complete.
# Per-value security validation already happened in config_load (fail-fast).
# ───────────────────────────────────────────────────────────────────────────────
config_validate() {
    local errors=0

    if [[ ${#CONFIG_SECTIONS[@]} -eq 0 ]]; then
        echo "ERROR: No jobs found in configuration" >&2
        return 1
    fi

    local section
    for section in "${CONFIG_SECTIONS[@]}"; do
        local type=$(config_get_var "$section" "type")
        local sources=$(config_get_var "$section" "sources")
        local host=$(config_get_var "$section" "host")
        local remote_path=$(config_get_var "$section" "remote_path")
        local schedule=$(config_get_var "$section" "schedule")

        if [[ -z "$type" ]]; then
            echo "ERROR: [$section] missing variable 'type'" >&2
            errors=$((errors + 1))
        elif [[ "$type" != "automatic" && "$type" != "manual" ]]; then
            echo "ERROR: [$section] type '$type' is not valid (use: automatic | manual)" >&2
            errors=$((errors + 1))
        fi

        if [[ -z "$sources" ]]; then
            echo "ERROR: [$section] missing variable 'sources'" >&2
            errors=$((errors + 1))
        fi

        if [[ -z "$host" ]]; then
            echo "ERROR: [$section] missing variable 'host'" >&2
            errors=$((errors + 1))
        fi

        if [[ -z "$remote_path" ]]; then
            echo "ERROR: [$section] missing variable 'remote_path'" >&2
            errors=$((errors + 1))
        fi

        if [[ "$type" == "manual" && -n "$schedule" ]]; then
            echo "WARNING: [$section] is manual but has 'schedule' defined (ignored)" >&2
        fi

        if [[ "$type" == "automatic" && -z "$schedule" ]]; then
            echo "WARNING: [$section] is automatic but has no 'schedule' (will use 'daily')" >&2
        fi

        local cloud_remote
        cloud_remote="$(config_get_var "$section" "cloud_remote")"
        if [[ -n "$cloud_remote" && "$host" != "local" ]]; then
            echo "WARNING: [$section] has 'cloud_remote' but host='$host': cloud sync only supports host=local (ignored)" >&2
        fi

        if [[ -n "$sources" ]]; then
            local source
            # Word-splitting intentional: sources is a space-separated path list.
            for source in $sources; do
                if [[ ! -e "$source" ]]; then
                    echo "WARNING: [$section] source does not exist: $source" >&2
                fi
            done
        fi
    done

    return $errors
}

# ───────────────────────────────────────────────────────────────────────────────
# config_example_exists
# Checks if copycrow.conf.example exists
# ───────────────────────────────────────────────────────────────────────────────
config_example_exists() {
    [[ -f "${COPYCROW_ROOT}/copycrow.conf.example" ]]
}

# ───────────────────────────────────────────────────────────────────────────────
# config_reload
# Reloads the configuration from the file
# ───────────────────────────────────────────────────────────────────────────────
config_reload() {
    unset CONFIG_GLOBAL CONFIG_JOBS CONFIG_SECTIONS CONFIG_SECTION_SEEN
    declare -gA CONFIG_GLOBAL
    declare -gA CONFIG_JOBS
    declare -gA CONFIG_SECTION_SEEN
    CONFIG_SECTIONS=()

    config_load "$COPYCROW_CONF"
}

# ───────────────────────────────────────────────────────────────────────────────
# config_migrate
# Converts a legacy (Spanish-key) copycrow.conf to the English-key format.
# Creates a backup at copycrow.conf.bak before writing.
# Legacy Spanish keys/values are intentionally allowed here WITHOUT the
# whitelist check (that is exactly what this command migrates).
# ───────────────────────────────────────────────────────────────────────────────
config_migrate() {
    local conf_file="${COPYCROW_CONF}"

    if [[ ! -f "$conf_file" ]]; then
        echo "No copycrow.conf found in project root." >&2
        echo "Run: ./copycrow.sh init" >&2
        return 1
    fi

    echo "Migrating copycrow.conf to English v1.0.0 format..."
    cp "$conf_file" "${conf_file}.bak"
    echo "  Backup saved: $(basename "$conf_file").bak"

    local tmp_file
    tmp_file="$(mktemp "${conf_file}.migrated.XXXXXX")"

    sed -e '/^[[:space:]]*#/b' -e '/^[[:space:]]*$/b' \
        -e 's/\(^[[:space:]]*\)retencion_default\([[:space:]]*=[[:space:]]*\)/\1retention_default\2/' \
        -e 's/\(^[[:space:]]*\)compresion\([[:space:]]*=[[:space:]]*\)/\1compression\2/' \
        -e 's/\(^[[:space:]]*\)prefijo_automatico\([[:space:]]*=[[:space:]]*\)/\1auto_prefix\2/' \
        -e 's/\(^[[:space:]]*\)prefijo_manual\([[:space:]]*=[[:space:]]*\)/\1manual_prefix\2/' \
        -e 's/\(^[[:space:]]*\)directorio_montaje\([[:space:]]*=[[:space:]]*\)/\1mount_dir\2/' \
        -e 's/\(^[[:space:]]*\)directorio_logs\([[:space:]]*=[[:space:]]*\)/\1logs_dir\2/' \
        -e 's/\(^[[:space:]]*\)tipo\([[:space:]]*=[[:space:]]*\)/\1type\2/' \
        -e 's/\(^[[:space:]]*\)origenes\([[:space:]]*=[[:space:]]*\)/\1sources\2/' \
        -e 's/\(^[[:space:]]*\)ruta_remota\([[:space:]]*=[[:space:]]*\)/\1remote_path\2/' \
        -e 's/\(^[[:space:]]*\)frecuencia\([[:space:]]*=[[:space:]]*\)/\1schedule\2/' \
        -e 's/\(^[[:space:]]*\)retencion\([[:space:]]*=[[:space:]]*\)/\1retention\2/' \
        "$conf_file" > "$tmp_file"

    local needs_value_migration=false
    # Unanchored on purpose: values appear inline (`frecuencia = diario`), so
    # ^...$ anchors missed them and left invalid Spanish values behind after
    # migration. False positives are harmless: the second pass only rewrites
    # lines whose ENTIRE value is one of the legacy words.
    if grep -qE '(automatico|diario|semanal|mensual|minutos[0-9])' "$tmp_file" 2>/dev/null; then
        needs_value_migration=true
    fi

    if [[ "$needs_value_migration" == "true" ]]; then
        local tmp_file2
        tmp_file2="$(mktemp "${conf_file}.migrated.XXXXXX")"
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*[a-zA-Z_]+[[:space:]]*=[[:space:]]*automatico[[:space:]]*$ ]]; then
                line="${line/automatico/automatic}"
            elif [[ "$line" =~ ^[[:space:]]*[a-zA-Z_]+[[:space:]]*=[[:space:]]*diario[[:space:]]*$ ]]; then
                line="${line/diario/daily}"
            elif [[ "$line" =~ ^[[:space:]]*[a-zA-Z_]+[[:space:]]*=[[:space:]]*semanal[[:space:]]*$ ]]; then
                line="${line/semanal/weekly}"
            elif [[ "$line" =~ ^[[:space:]]*[a-zA-Z_]+[[:space:]]*=[[:space:]]*mensual[[:space:]]*$ ]]; then
                line="${line/mensual/monthly}"
            elif [[ "$line" =~ minutos[[:space:]]*=|^minutos ]]; then
                line="${line/minutos/minutes}"
            elif [[ "$line" =~ ^[[:space:]]*[a-zA-Z_]+[[:space:]]*=[[:space:]]*minutos[0-9]{2}:[0-9]{2}[[:space:]]*$ ]]; then
                # P0-2: the key rename pass turns `frecuencia = minutos08:30`
                # into `schedule = minutos08:30`, which the generic branch
                # above never matched (no '=' right after 'minutos') and the
                # whitelist then rejected. Rewrite the whole inline value.
                line="${line/minutos/minutes}"
            fi
            printf '%s\n' "$line"
        done < "$tmp_file" > "$tmp_file2"
        mv "$tmp_file2" "$tmp_file"
    fi

    # Check if any changes were actually made
    if diff -q "$conf_file" "$tmp_file" &>/dev/null; then
        echo "  Configuration is already in English format. Nothing to migrate."
        rm -f "$tmp_file"
        rm -f "${conf_file}.bak"
        return 0
    fi

    mv "$tmp_file" "$conf_file"
    echo "  Configuration migrated successfully."
    echo ""
    echo "To verify: ./copycrow.sh status"
    return 0
}
