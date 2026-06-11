#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# copycrow — config-parser.sh
# INI configuration parser for copycrow
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# Project root directory
COPYCROW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Configuration file
COPYCROW_CONF="${COPYCROW_ROOT}/copycrow.conf"

# Associative arrays for config storage
declare -gA CONFIG_GLOBAL
declare -gA CONFIG_JOBS

# List of sections (jobs) found
CONFIG_SECTIONS=()

# ───────────────────────────────────────────────────────────────────────────────
# config_load
# Loads copycrow.conf and parses all sections
# ───────────────────────────────────────────────────────────────────────────────
config_load() {
    local file="${1:-$COPYCROW_CONF}"

    if [[ ! -f "$file" ]]; then
        echo "ERROR: Configuration file not found: $file" >&2
        echo "Run: ./copycrow.sh init" >&2
        return 1
    fi

    local current_section=""
    local line

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        [[ -z "$line" || "$line" == \#* ]] && continue

        if [[ "$line" =~ ^\[([a-zA-Z0-9_-]+)\]$ ]]; then
            current_section="${BASH_REMATCH[1]}"
            if [[ "$current_section" == "global" ]]; then
                continue
            fi
            CONFIG_SECTIONS+=("$current_section")
            continue
        fi

        if [[ "$line" =~ ^([a-zA-Z0-9_-]+)[[:space:]]*=[[:space:]]*(.+)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"

            value="${value#\"}"
            value="${value%\"}"
            value="${value#\'}"
            value="${value%\'}"

            if [[ "$current_section" == "global" ]]; then
                CONFIG_GLOBAL["${key}"]="$value"
            elif [[ -n "$current_section" ]]; then
                CONFIG_JOBS["${current_section}_${key}"]="$value"
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
# Falls back to [global] if not found in the job
# Usage: config_get_var "daily_job" "host"
# ───────────────────────────────────────────────────────────────────────────────
config_get_var() {
    local section="$1"
    local variable="$2"
    local compound_key="${section}_${variable}"

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
    local compound_key="${section}_${variable}"

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
# Checks that a config value does not contain dangerous characters
# (anti command injection / path traversal)
# ───────────────────────────────────────────────────────────────────────────────
config_validate_value() {
    local key="$1"
    local value="$2"

    if [[ -z "$value" ]]; then
        return 0
    fi

    case "$key" in
        host|remote_path|sources|mount_dir|logs_dir|compression)
            if [[ "$value" =~ [\;\&\|\$\`\<\>\\] ]]; then
                echo "ERROR: [$key] contains forbidden characters" >&2
                return 1
            fi
            if [[ "$key" == "host" && "$value" != "local" ]]; then
                if ! [[ "$value" =~ ^[a-zA-Z0-9._-]+$ ]]; then
                    echo "ERROR: [host] '$value' is not a valid SSH alias" >&2
                    return 1
                fi
            fi
            if [[ "$key" == "remote_path" || "$key" == "sources" || "$key" == "mount_dir" || "$key" == "logs_dir" ]]; then
                if [[ "$value" == *".."* ]]; then
                    echo "ERROR: [$key] must not contain '..'" >&2
                    return 1
                fi
            fi
            if [[ "$key" == "compression" ]]; then
                case "$value" in
                    lz4|zstd|zlib|lzma|none) ;;
                    *)
                        echo "ERROR: [compression] '$value' is not valid (lz4, zstd, zlib, lzma, none)" >&2
                        return 1
                        ;;
                esac
            fi
            ;;
        type)
            case "$value" in
                automatic|manual) ;;
                *)
                    echo "ERROR: [type] '$value' is not valid" >&2
                    return 1
                    ;;
            esac
            ;;
        schedule)
            case "$value" in
                daily|weekly|monthly|minutes*)
                    if [[ "$value" == minutes* ]]; then
                        local clock="${value#minutes}"
                        if ! [[ "$clock" =~ ^[0-9]{2}:[0-9]{2}$ ]]; then
                            echo "ERROR: [schedule] '$value' invalid format (use minutesHH:MM)" >&2
                            return 1
                        fi
                    fi
                    ;;
                *)
                    echo "ERROR: [schedule] '$value' is not valid" >&2
                    return 1
                    ;;
            esac
            ;;
    esac

    return 0
}

# ───────────────────────────────────────────────────────────────────────────────
# config_validate
# Validates that the configuration is correct and complete
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
        local compression=$(config_get_var_or_global "$section" "compression")

        config_validate_value "type" "$type" || ((errors++))
        config_validate_value "host" "$host" || ((errors++))
        config_validate_value "remote_path" "$remote_path" || ((errors++))
        config_validate_value "schedule" "$schedule" || ((errors++))
        config_validate_value "compression" "$compression" || ((errors++))

        if [[ -n "$sources" ]]; then
            local source
            for source in $sources; do
                config_validate_value "sources" "$source" || ((errors++))
            done
        fi

        if [[ -z "$type" ]]; then
            echo "ERROR: [$section] missing variable 'type'" >&2
            ((errors++))
        elif [[ "$type" != "automatic" && "$type" != "manual" ]]; then
            echo "ERROR: [$section] type '$type' is not valid (use: automatic | manual)" >&2
            ((errors++))
        fi

        if [[ -z "$sources" ]]; then
            echo "ERROR: [$section] missing variable 'sources'" >&2
            ((errors++))
        fi

        if [[ -z "$host" ]]; then
            echo "ERROR: [$section] missing variable 'host'" >&2
            ((errors++))
        fi

        if [[ -z "$remote_path" ]]; then
            echo "ERROR: [$section] missing variable 'remote_path'" >&2
            ((errors++))
        fi

        if [[ "$type" == "manual" && -n "$schedule" ]]; then
            echo "WARNING: [$section] is manual but has 'schedule' defined (ignored)" >&2
        fi

        if [[ "$type" == "automatic" && -z "$schedule" ]]; then
            echo "WARNING: [$section] is automatic but has no 'schedule' (will use 'daily')" >&2
        fi

        if [[ -n "$sources" ]]; then
            local source
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
    unset CONFIG_GLOBAL CONFIG_JOBS CONFIG_SECTIONS
    declare -gA CONFIG_GLOBAL
    declare -gA CONFIG_JOBS
    CONFIG_SECTIONS=()

    config_load "$COPYCROW_CONF"
}

# ───────────────────────────────────────────────────────────────────────────────
# config_migrate
# Converts a legacy (Spanish-key) copycrow.conf to the English-key format.
# Creates a backup at copycrow.conf.bak before writing.
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
    echo "  Backup saved: copycrow.conf.bak"

    local tmp_file="${conf_file}.migrated"

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
    if grep -qE '(automatico|^diario$|^semanal$|^mensual$|^minutos[0-9])' "$tmp_file" 2>/dev/null; then
        needs_value_migration=true
    fi

    if [[ "$needs_value_migration" == "true" ]]; then
        local tmp_file2="${conf_file}.migrated2"
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*[a-zA-Z_]+[[:space:]]*=[[:space:]]*automatico[[:space:]]*$ ]]; then
                line="${line/automatico/automatic}"
            elif [[ "$line" =~ ^[[:space:]]*[a-zA-Z_]+[[:space:]]*=[[:space:]]*diario[[:space:]]*$ ]]; then
                line="${line/diario/daily}"
            elif [[ "$line" =~ ^[[:space:]]*[a-zA-Z_]+[[:space:]]*=[[:space:]]*semanal[[:space:]]*$ ]]; then
                line="${line/semanal/weekly}"
            elif [[ "$line" =~ ^[[:space:]]*[a-zA-Z_]+[[:space:]]*=[[:space:]]*mensual[[:space:]]*$ ]]; then
                line="${line/mensual/monthly}"
            elif [[ "$line" =~ ^[[:space:]]*[a-zA-Z_]+[[:space:]]*=[[:space:]]*minutos ]]; then
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
