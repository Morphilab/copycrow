#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# copycrow — cloud-sync.sh
# Offsite replication of LOCAL borg repositories to Proton Drive through the
# OFFICIAL `proton-drive` CLI (v0.8+, browser OAuth + OS keyring session).
# ═══════════════════════════════════════════════════════════════════════════════
# Contract:
#   * Opt-in per job via `cloud_remote`; [global] cloud_cli_path overrides PATH.
#   * Incremental upload driven ONLY by the local manifest
#     (${XDG_CACHE_HOME:-~/.cache}/copycrow/cloud/<job>.manifest):
#       unchanged (size+mtime) → skipped · rewritten → strategy "replace"
#       new                    → strategy "skip"
#     A failed run NEVER updates the manifest → next run retries everything.
#   * Requires config-parser.sh + backup-core.sh sourced beforehand (backup_log,
#     _run_capture, config_* accessors).
set -euo pipefail

declare -gA _CLOUD_SEEN       # relpath -> "size mtime" (last known uploaded)
declare -gA _CLOUD_DIRS_MADE  # remote dirs ensured during the current run

# ───────────────────────────────────────────────────────────────────────────────
# _cloud_cache_dir / _cloud_manifest_path
# Local state location. Directory best-effort 0700, manifest 0600 (paths/sizes only —
# no secrets ever live here).
# ───────────────────────────────────────────────────────────────────────────────
_cloud_cache_dir() {
    printf '%s\n' "${XDG_CACHE_HOME:-${HOME}/.cache}/copycrow/cloud"
}

_cloud_manifest_path() {
    printf '%s/%s.manifest' "$(_cloud_cache_dir)" "$1"
}

# ───────────────────────────────────────────────────────────────────────────────
# cloud_resolve_cli
# Prints the usable proton-drive binary path ([global] cloud_cli_path wins),
# or fails when nothing executable can be found.
# ───────────────────────────────────────────────────────────────────────────────
cloud_resolve_cli() {
    local candidate
    candidate="$(config_get_global 'cloud_cli_path')"
    candidate="${candidate:-proton-drive}"
    if [[ "$candidate" == */* ]]; then
        [[ -x "$candidate" ]] || return 1
        printf '%s\n' "$candidate"
        return 0
    fi
    command -v "$candidate"
}

# ───────────────────────────────────────────────────────────────────────────────
# _cloud_wrap_prefix
# Prints the argv prefix required to run the Proton CLI in THIS session:
#   * COPYCROW_CLOUD_WRAP="none"          → nothing (deterministic runs/tests)
#   * COPYCROW_CLOUD_WRAP=<other>         → that command line (word-splitting is
#     INTENTIONAL; same banned-metacharacter rule as on_failure_cmd values)
#   * unset + no graphical session        → "dbus-run-session --" (headless and
#     systemd-user timers have no D-Bus bus: libsecret could not reach the ring)
#   * unset + graphical session           → nothing
# ───────────────────────────────────────────────────────────────────────────────
_cloud_wrap_prefix() {
    if [[ -n "${COPYCROW_CLOUD_WRAP+x}" ]]; then
        if [[ "${COPYCROW_CLOUD_WRAP}" == "none" ]]; then
            return 0
        fi
        if [[ "${COPYCROW_CLOUD_WRAP}" =~ [\;\&\|\$\`\<\>\\] || "${COPYCROW_CLOUD_WRAP}" == *$'\n'* ]]; then
            echo "ERROR: COPYCROW_CLOUD_WRAP contains forbidden characters" >&2
            return 1
        fi
        printf '%s\n' "${COPYCROW_CLOUD_WRAP}"
        return 0
    fi
    if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
        printf '%s\n' "dbus-run-session --"
    fi
    return 0
}

# ───────────────────────────────────────────────────────────────────────────────
# _cloud_exec
# Runs the resolved CLI behind the resolved wrapper, capturing combined output
# WITHOUT dying under set -e.
# Usage: _cloud_exec OUT_VAR <args...>
# ───────────────────────────────────────────────────────────────────────────────
_cloud_exec() {
    local __out_var="$1"
    shift

    local cli="" wrap="" __rc=0
    cli="$(cloud_resolve_cli)" || {
        echo "ERROR: proton-drive CLI not found (install it or set [global] cloud_cli_path)" >&2
        return 1
    }
    wrap="$(_cloud_wrap_prefix)" || return 1

    if [[ -n "$wrap" ]]; then
        local -a wrap_argv=()
        # Split on IFS WITHOUT pathname expansion: a glob in $wrap must never
        # grow filenames into argv (defense-in-depth; parser bans most of it).
        read -r -a wrap_argv <<< "$wrap"
        _run_capture "$__out_var" "${wrap_argv[@]}" "$cli" "$@" || __rc=$?
    else
        _run_capture "$__out_var" "$cli" "$@" || __rc=$?
    fi
    return "$__rc"
}

# ───────────────────────────────────────────────────────────────────────────────
# _cloud_manifest_load / _cloud_manifest_save
# Populate/dump _CLOUD_SEEN atomically. Save rewrites via mktemp+mv so a crash
# mid-write can never truncate previously-known-good state.
# NOTE: TSV cannot represent tab/newline characters inside relpaths; the upload engine must SKIP such files rather than encode them.
# ───────────────────────────────────────────────────────────────────────────────
_cloud_manifest_load() {
    _CLOUD_SEEN=()
    local mf rel size mtime
    mf="$(_cloud_manifest_path "$1")"
    [[ -f "$mf" ]] || return 0
    while IFS=$'\t' read -r rel size mtime; do
        [[ -n "${rel:-}" ]] || continue
        _CLOUD_SEEN["$rel"]="${size} ${mtime}"
    done < "$mf"
}

_cloud_manifest_save() {
    local cache_dir mf tmp rel
    cache_dir="$(_cloud_cache_dir)"
    mkdir -p "$cache_dir"
    chmod 700 "$cache_dir" 2>/dev/null || true
    mf="$(_cloud_manifest_path "$1")"
    tmp="$(mktemp "${cache_dir}/.manifest.XXXXXX")"
    if declare -F safety_add_temp >/dev/null 2>&1; then
        safety_add_temp "$tmp"
    fi
    chmod 600 "$tmp"
    local rc=0
    {
        for rel in "${!_CLOUD_SEEN[@]}"; do
            printf '%s\t%s\t%s\n' "$rel" "${_CLOUD_SEEN[$rel]% *}" "${_CLOUD_SEEN[$rel]#* }"
        done
    } | LC_ALL=C sort > "$tmp" || rc=$?
    if (( rc != 0 )); then
        rm -f "$tmp"
        return "$rc"
    fi
    # -T/--no-target-directory: plain `mv -f src dir` would move the tmpfile
    # INSIDE a directory target with rc=0 (state silently misplaced).
    local mv_rc=0
    mv -fT -- "$tmp" "$mf" || mv_rc=$?
    if (( mv_rc != 0 )); then
        rm -f "$tmp"
        echo "ERROR: could not persist manifest at '$mf'" >&2
        return "$mv_rc"
    fi
}

# ───────────────────────────────────────────────────────────────────────────────
# _cloud_relpath_unsafe
# True when a repo-relative path cannot be represented in the TSV manifest
# (tab or newline). Engine SKIPS those rather than corrupting state.
# ───────────────────────────────────────────────────────────────────────────────
_cloud_relpath_unsafe() {
    [[ "$1" == *$'\t'* || "$1" == *$'\n'* ]]
}

# ───────────────────────────────────────────────────────────────────────────────
# _cloud_ensure_remote_dir
# Ensures a full Drive folder chain exists (/a/b/c), probing each component
# with `filesystem info` (return-code only: NO output parsing, NO jq) and
# creating what is missing. Memoized per run via _CLOUD_DIRS_MADE.
# ───────────────────────────────────────────────────────────────────────────────
_cloud_ensure_remote_dir() {
    local dir_path="$1"
    local rest="$dir_path" part acc="" out rc=0 parent

    while [[ -n "$rest" ]]; do
        part="${rest#/}"
        part="${part%%/*}"
        acc+="/${part}"

        if [[ -z "${_CLOUD_DIRS_MADE[$acc]:-}" ]]; then
            out=""
            rc=0
            _cloud_exec out filesystem info "$acc" || rc=$?
            if (( rc != 0 )); then
                parent="${acc%/*}"
                parent="${parent:-/}"
                out=""
                rc=0
                _cloud_exec out filesystem create-folder "$parent" "$part" || rc=$?
                if (( rc != 0 )); then
                    echo "ERROR: cannot create folder '${acc}' in Proton Drive" >&2
                    [[ -n "$out" ]] && echo "  ${out}" >&2
                    return 1
                fi
            fi
            _CLOUD_DIRS_MADE["$acc"]=1
        fi

        rest="${rest#"/${part}"}"
    done
    return 0
}

# ───────────────────────────────────────────────────────────────────────────────
# _cloud_remote_parent_for_file
# Drive parent folder of a repo-relative file path.
# ───────────────────────────────────────────────────────────────────────────────
_cloud_remote_parent_for_file() {
    local root="$1" rel="$2" rel_dir
    rel_dir="$(dirname "$rel")"
    if [[ "$rel_dir" == "." ]]; then
        printf '%s\n' "$root"
    else
        printf '%s/%s\n' "$root" "$rel_dir"
    fi
}

# ───────────────────────────────────────────────────────────────────────────────
# cloud_pending_count
# How many files WOULD be uploaded right now. Pure local diff (manifest vs
# disk): NEVER invokes the CLI, safe for dry-run.
# ───────────────────────────────────────────────────────────────────────────────
cloud_pending_count() {
    local section="$1"
    local repo
    repo="$(config_get_var "$section" 'remote_path')"
    [[ -d "$repo" ]] || { printf '0\n'; return 0; }

    _cloud_manifest_load "$section"

    local count=0 file rel size mtime seen
    while IFS= read -r -d '' file; do
        rel="${file#"$repo"/}"
        [[ "$rel" == lock* ]] && continue
        _cloud_relpath_unsafe "$rel" && continue
        seen="${_CLOUD_SEEN[$rel]:-}"
        size="$(stat -c %s -- "$file")"
        mtime="$(stat -c %Y -- "$file")"
        if [[ -z "$seen" || "$seen" != "${size} ${mtime}" ]]; then
            count=$((count + 1))
        fi
    done < <(find "$repo" -type f -print0 | LC_ALL=C sort -z)
    printf '%s\n' "$count"
}

# ───────────────────────────────────────────────────────────────────────────────
# cloud_sync_job
# Replicates the LOCAL borg repository of <job> to its [job] cloud_remote
# folder. ANY transfer problem returns nonzero leaving the manifest UNTOUCHED,
# so the next run retries everything still pending (idempotent).
# Caller MUST hold the job's flock (see backup_create / cmd_sync).
# ───────────────────────────────────────────────────────────────────────────────
cloud_sync_job() {
    local section="$1"

    local host repo remote_root
    host="$(config_get_var "$section" 'host')"
    repo="$(config_get_var "$section" 'remote_path')"
    remote_root="$(config_get_var "$section" 'cloud_remote')"

    if [[ "$host" != "local" ]]; then
        echo "ERROR: [$section] cloud sync supports local repositories only (host='$host')" >&2
        return 1
    fi
    if [[ ! -d "$repo" ]]; then
        echo "ERROR: [$section] repository directory not found: $repo" >&2
        return 1
    fi
    if [[ -z "$remote_root" ]]; then
        echo "ERROR: [$section] empty 'cloud_remote' (refusing to write at the Drive root)" >&2
        return 1
    fi

    local start
    start="$(date +%s)"

    _CLOUD_DIRS_MADE=()
    _cloud_manifest_load "$section"

    local uploaded=0 skipped=0 bytes=0
    local file rel size mtime seen strategy parent out rc=0

    # Sorted walk: deterministic order makes failures reproducible in tests
    # and logs. lock* (borg runtime locks and their contents) never leave home;
    # tab/newline relpaths would corrupt the TSV manifest, so they are skipped.
    while IFS= read -r -d '' file; do
        rel="${file#"$repo"/}"
        [[ "$rel" == lock* ]] && continue

        if _cloud_relpath_unsafe "$rel"; then
            echo "WARNING: [$section] skipping path not representable in manifest: ${rel}" >&2
            skipped=$((skipped + 1))
            continue
        fi

        seen="${_CLOUD_SEEN[$rel]:-}"
        size="$(stat -c %s -- "$file")"
        mtime="$(stat -c %Y -- "$file")"

        if [[ -n "$seen" && "$seen" == "${size} ${mtime}" ]]; then
            skipped=$((skipped + 1))
            continue
        fi

        if [[ -n "$seen" ]]; then
            # Same name, different content: borg REWROTE this segment
            # (prune/compact). "skip" would silently preserve a stale remote
            # copy forever — force replacement.
            strategy="replace"
        else
            strategy="skip"
        fi

        parent="$(_cloud_remote_parent_for_file "$remote_root" "$rel")"
        _cloud_ensure_remote_dir "$parent" || return 1

        out=""
        rc=0
        _cloud_exec out filesystem upload "$file" "$parent" --conflict-strategy "$strategy" || rc=$?
        if (( rc != 0 )); then
            backup_log "ERROR" "$section" "cloud_sync" "failed" \
                "file=${rel}" "exit_code=${rc}" "error=${out:-unknown}"
            echo "ERROR: [$section] ProtonDrive upload failed: ${rel}" >&2
            [[ -n "$out" ]] && echo "  ${out}" >&2
            return 1
        fi

        _CLOUD_SEEN["$rel"]="${size} ${mtime}"
        uploaded=$((uploaded + 1))
        bytes=$((bytes + size))
    done < <(find "$repo" -type f -print0 | LC_ALL=C sort -z)

    local save_rc=0
    _cloud_manifest_save "$section" || save_rc=$?
    if (( save_rc != 0 )); then
        backup_log "ERROR" "$section" "cloud_sync" "failed" "stage=manifest_save"
        echo "ERROR: [$section] could not persist cloud manifest (next sync retries everything)" >&2
        return 1
    fi

    local duration end_s
    end_s="$(date +%s)"
    duration=$((end_s - start))

    backup_log "INFO" "$section" "cloud_sync" "ok" \
        "files=${uploaded}" "bytes=${bytes}" "skipped=${skipped}" \
        "duration=${duration}" "remote=${remote_root}"
    echo "ProtonDrive sync: ${uploaded} uploaded (${bytes} bytes), ${skipped} unchanged -> ${remote_root} (${duration}s)"
    return 0
}
