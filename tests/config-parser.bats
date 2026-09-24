#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════════════════════
# Tests for config-parser.sh
# Dependency: bats-core (https://github.com/bats-core/bats-core)
# Usage: bats tests/
# ═══════════════════════════════════════════════════════════════════════════════

setup() {
    export COPYCROW_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    source "${COPYCROW_ROOT}/src/config-parser.sh"
}

teardown() {
    rm -f /tmp/copycrow-test-*.conf
}

# ───────────────────────────────────────────────────────────────────────────────
# config_load — basic cases
# ───────────────────────────────────────────────────────────────────────────────

@test "config_load: loads a valid file" {
    cat > /tmp/copycrow-test-1.conf << 'EOF'
[global]
retention_default = --keep-daily 7
compression = lz4

[my_job]
type = automatic
sources = /home
host = nas-backup
remote_path = /backups/test
schedule = daily
EOF

    run config_load /tmp/copycrow-test-1.conf
    [ "$status" -eq 0 ]
}

@test "config_load: fails if file does not exist" {
    run config_load /tmp/copycrow-test-no-exist.conf
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}

@test "config_load: ignores comments and blank lines" {
    cat > /tmp/copycrow-test-2.conf << 'EOF'
# Comment
[global]

# Another comment
retention_default = --keep-daily 7
EOF

    config_load /tmp/copycrow-test-2.conf
    [ "$(config_get_global retention_default)" = "--keep-daily 7" ]
}

@test "config_load: parses multiple sections" {
    cat > /tmp/copycrow-test-3.conf << 'EOF'
[global]
compression = lz4

[job_a]
type = automatic
host = server1
remote_path = /a

[job_b]
type = manual
host = server2
remote_path = /b
EOF

    config_load /tmp/copycrow-test-3.conf
    [ "$(config_get_var job_a host)" = "server1" ]
    [ "$(config_get_var job_b host)" = "server2" ]
}

@test "config_load: strips quotes from values" {
    cat > /tmp/copycrow-test-4.conf << 'EOF'
[global]
compression = "lz4"
EOF

    config_load /tmp/copycrow-test-4.conf
    [ "$(config_get_global compression)" = "lz4" ]
}

# ───────────────────────────────────────────────────────────────────────────────
# config_get_var_or_global
# ───────────────────────────────────────────────────────────────────────────────

@test "config_get_var_or_global: uses job value if present" {
    cat > /tmp/copycrow-test-5.conf << 'EOF'
[global]
compression = lz4

[job_a]
compression = zstd
EOF

    config_load /tmp/copycrow-test-5.conf
    [ "$(config_get_var_or_global job_a compression)" = "zstd" ]
}

@test "config_get_var_or_global: falls back to global if absent in job" {
    cat > /tmp/copycrow-test-6.conf << 'EOF'
[global]
compression = lz4

[job_a]
EOF

    config_load /tmp/copycrow-test-6.conf
    [ "$(config_get_var_or_global job_a compression)" = "lz4" ]
}

# ───────────────────────────────────────────────────────────────────────────────
# config_validate_value — security
# ───────────────────────────────────────────────────────────────────────────────

@test "config_validate_value: rejects dangerous characters in host" {
    run config_validate_value "host" 'server;rm -rf /'
    [ "$status" -ne 0 ]
}

@test "config_validate_value: rejects path traversal in paths" {
    run config_validate_value "remote_path" '/backups/../etc'
    [ "$status" -ne 0 ]
}

@test "remote_path: must be absolute" {
    run config_validate_value "remote_path" "backups/daily"
    [ "$status" -ne 0 ]
    [[ "$output" == *"absolute"* ]]

    run config_validate_value "remote_path" "/backups/daily"
    [ "$status" -eq 0 ]
}

@test "mount_dir: must stay relative to project root" {
    run config_validate_value "mount_dir" ".mnt"
    [ "$status" -eq 0 ]

    run config_validate_value "mount_dir" "/etc"
    [ "$status" -ne 0 ]
    [[ "$output" == *"relative"* ]]
}

@test "config_validate_value: rejects invalid compression" {
    run config_validate_value "compression" "rm -rf"
    [ "$status" -ne 0 ]
}

@test "config_validate_value: accepts valid compression algorithms" {
    for comp in lz4 zstd zlib lzma none; do
        run config_validate_value "compression" "$comp"
        [ "$status" -eq 0 ]
    done
}

@test "config_validate_value: rejects invalid type" {
    run config_validate_value "type" "remote"
    [ "$status" -ne 0 ]
}

@test "config_validate_value: accepts valid types" {
    run config_validate_value "type" "automatic"
    [ "$status" -eq 0 ]
    run config_validate_value "type" "manual"
    [ "$status" -eq 0 ]
}

@test "config_validate_value: validates custom schedule format" {
    run config_validate_value "schedule" "minutesbad"
    [ "$status" -ne 0 ]

    run config_validate_value "schedule" "minutes23:59"
    [ "$status" -eq 0 ]

    run config_validate_value "schedule" "minutes00:00"
    [ "$status" -eq 0 ]

    # Out-of-range values would be rejected by systemd OnCalendar at runtime
    run config_validate_value "schedule" "minutes24:00"
    [ "$status" -ne 0 ]

    run config_validate_value "schedule" "minutes10:60"
    [ "$status" -ne 0 ]
}

# ───────────────────────────────────────────────────────────────────────────────
# config_get_auto_jobs / config_get_manual_jobs
# ───────────────────────────────────────────────────────────────────────────────

@test "config_get_auto_jobs: filters by type" {
    cat > /tmp/copycrow-test-7.conf << 'EOF'
[global]

[job_auto]
type = automatic

[job_manual]
type = manual
EOF

    config_load /tmp/copycrow-test-7.conf
    local autos=$(config_get_auto_jobs)
    [[ "$autos" == *"job_auto"* ]]
    [[ "$autos" != *"job_manual"* ]]
}

# ───────────────────────────────────────────────────────────────────────────────
# config_validate — integration
# ───────────────────────────────────────────────────────────────────────────────

@test "config_validate: fails with empty config" {
    cat > /tmp/copycrow-test-empty.conf << 'EOF'
[global]
EOF

    config_load /tmp/copycrow-test-empty.conf
    run config_validate
    [ "$status" -ne 0 ]
}

@test "config_validate: fails if type is missing" {
    cat > /tmp/copycrow-test-8.conf << 'EOF'
[global]

[job_x]
sources = /home
host = server
remote_path = /b
EOF

    config_load /tmp/copycrow-test-8.conf
    run config_validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"type"* ]]
}

@test "config_validate: fails if host is missing" {
    cat > /tmp/copycrow-test-9.conf << 'EOF'
[global]

[job_x]
type = automatic
sources = /home
remote_path = /b
EOF

    config_load /tmp/copycrow-test-9.conf
    run config_validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"host"* ]]
}

@test "config_validate: rejects remote_path traversal at load time" {
    cat > /tmp/copycrow-test-10.conf << 'EOF'
[global]

[job_x]
type = automatic
sources = /home
host = server
remote_path = /backups/../etc
EOF

    run config_load /tmp/copycrow-test-10.conf
    [ "$status" -ne 0 ]
}

@test "config_validate: rejects invalid schedule at load time" {
    cat > /tmp/copycrow-test-11.conf << 'EOF'
[global]

[job_x]
type = automatic
sources = /home
host = server
remote_path = /b
schedule = every_5_minutes
EOF

    run config_load /tmp/copycrow-test-11.conf
    [ "$status" -ne 0 ]
    [[ "$output" == *"schedule"* ]]
}

@test "config_validate: rejects invalid compression at load time" {
    cat > /tmp/copycrow-test-12.conf << 'EOF'
[global]
compression = no_such

[job_x]
type = automatic
sources = /home
host = server
remote_path = /b
EOF

    run config_load /tmp/copycrow-test-12.conf
    [ "$status" -ne 0 ]
    [[ "$output" == *"compression"* ]]
}

@test "config_validate: rejects dangerous host at load time" {
    cat > /tmp/copycrow-test-13.conf << 'EOF'
[global]

[job_x]
type = automatic
sources = /home
host = 'server;rm -rf /'
remote_path = /b
EOF

    run config_load /tmp/copycrow-test-13.conf
    [ "$status" -ne 0 ]
}

@test "config_validate: rejects source path traversal at load time" {
    cat > /tmp/copycrow-test-14.conf << 'EOF'
[global]

[job_x]
type = automatic
sources = /home/../etc
host = server
remote_path = /b
EOF

    run config_load /tmp/copycrow-test-14.conf
    [ "$status" -ne 0 ]
}

@test "config_validate: accepts complete valid config" {
    cat > /tmp/copycrow-test-15.conf << 'EOF'
[global]
compression = lz4

[daily_job]
type = automatic
sources = /home /etc
host = nas-backup
remote_path = /backups/daily
schedule = daily
retention = --keep-daily 7
EOF

    config_load /tmp/copycrow-test-15.conf
    run config_validate
    [ "$status" -eq 0 ]
}

@test "config_validate: accepts host 'local' (special case)" {
    cat > /tmp/copycrow-test-16.conf << 'EOF'
[global]

[job_local]
type = manual
sources = /home/user/docs
host = local
remote_path = /mnt/usb/backups
EOF

    config_load /tmp/copycrow-test-16.conf
    run config_validate
    [ "$status" -eq 0 ]
}

# ───────────────────────────────────────────────────────────────────────────────
# Input hardening — host regex, retention whitelist, key whitelist, fail-fast
# ───────────────────────────────────────────────────────────────────────────────

@test "host: rejects leading dash (SSH option injection)" {
    run config_validate_value "host" "-oProxyCommand=evil"
    [ "$status" -ne 0 ]
}

@test "host: accepts well-formed aliases and 'local'" {
    for h in nas-backup my.server.local local 192.168.1.100; do
        run config_validate_value "host" "$h"
        [ "$status" -eq 0 ] || return 1
    done
}

@test "retention: accepts only --keep-* flag/number pairs" {
    run config_validate_value "retention" "--keep-daily 7 --keep-weekly 4"
    [ "$status" -eq 0 ]

    run config_validate_value "retention_default" "--keep-monthly 6"
    [ "$status" -eq 0 ]

    run config_validate_value "retention" "--prefix evil"
    [ "$status" -ne 0 ]

    run config_validate_value "retention" "; rm -rf /"
    [ "$status" -ne 0 ]
}

@test "timeout_start_sec: numeric or infinity only" {
    run config_validate_value "timeout_start_sec" "3600"
    [ "$status" -eq 0 ]
    run config_validate_value "timeout_start_sec" "infinity"
    [ "$status" -eq 0 ]
    run config_validate_value "timeout_start_sec" "one-hour"
    [ "$status" -ne 0 ]
}

@test "prefixes: accept archive-name charset only" {
    for p in "auto-" "manual_" "snap." "A1-b_c.d"; do
        run config_validate_value "auto_prefix" "$p"
        [ "$status" -eq 0 ] || return 1
    done
    for bad in "auto(x)" "-lead" "a;b" "x y" 'a$b'; do
        run config_validate_value "auto_prefix" "$bad"
        [ "$status" -ne 0 ] || return 1
    done
    run config_validate_value "manual_prefix" "auto-(nuevo)"
    [ "$status" -ne 0 ]
}

@test "config_load: rejects unknown keys (whitelist)" {
    cat > /tmp/copycrow-test-wl.conf << 'EOF'
[global]
compression = lz4

[job_x]
type = manual
sourcez = /home
EOF
    run config_load /tmp/copycrow-test-wl.conf
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown key"* ]]
}

@test "config_load: rejects keys before any section header" {
    cat > /tmp/copycrow-test-pre.conf << 'EOF'
type = manual
sources = /home

[job_a]
type = manual
sources = /home
host = server
remote_path = /a
EOF
    run config_load /tmp/copycrow-test-pre.conf
    [ "$status" -ne 0 ]
    [[ "$output" == *"appears before any"* ]]
}

@test "config_load: fails fast on invalid values (anti-injection active in load)" {
    cat > /tmp/copycrow-test-ff.conf << 'EOF'
[global]
compression = not-real
EOF
    run config_load /tmp/copycrow-test-ff.conf
    [ "$status" -ne 0 ]
}

@test "config_load: strips trailing inline comments on unquoted values" {
    cat > /tmp/copycrow-test-cm.conf << 'EOF'
[global]
compression = lz4 # fast default
auto_prefix = auto-
EOF
    config_load /tmp/copycrow-test-cm.conf
    [ "$(config_get_global compression)" = "lz4" ]
    [ "$(config_get_global auto_prefix)" = "auto-" ]
}

@test "config_load: duplicate sections are ignored with warning" {
    cat > /tmp/copycrow-test-ds.conf << 'EOF'
[global]
compression = lz4

[job_a]
type = manual

[job_a]
type = automatic
sources = /home
host = server
remote_path = /a
EOF
    # Bare call (stderr → file): keeps array state in THIS shell while
    # still letting us assert on the warning text.
    local warn_file="/tmp/copycrow-ds-warn-$$"
    config_load /tmp/copycrow-test-ds.conf 2> "$warn_file"
    grep -q "duplicate section" "$warn_file"
    # First definition wins; the duplicate body is dropped entirely.
    [ "$(config_get_var job_a type)" = "manual" ]
    [ -z "$(config_get_var job_a sources)" ]
    rm -f "$warn_file"
}

@test "compound keys: near-colliding job names stay independent" {
    cat > /tmp/copycrow-test-cl.conf << 'EOF'
[global]

[my]
type = manual
sources = /home
host = server-a
remote_path = /a

[my_sub]
type = manual
sources = /var
host = server-b
remote_path = /b
EOF
    config_load /tmp/copycrow-test-cl.conf
    [ "$(config_get_var my host)" = "server-a" ]
    [ "$(config_get_var my_sub host)" = "server-b" ]
}

@test "config_load: repeated loads do not accumulate sections" {
    cat > /tmp/copycrow-test-rl.conf << 'EOF'
[global]
compression = lz4

[job_once]
type = manual
sources = /home
host = server
remote_path = /a
EOF
    config_load /tmp/copycrow-test-rl.conf
    config_load /tmp/copycrow-test-rl.conf
    config_load /tmp/copycrow-test-rl.conf
    [ "${#CONFIG_SECTIONS[@]}" -eq 1 ]
}

# ───────────────────────────────────────────────────────────────────────────────
# config_migrate — legacy config conversion (sandboxed: never touches project conf)
# ───────────────────────────────────────────────────────────────────────────────

@test "config_migrate: converts Spanish keys to English" {
    export COPYCROW_CONF="$(mktemp /tmp/copycrow-migrate-XXXXXX.conf)"
    cat > "$COPYCROW_CONF" << 'EOF'
[global]
retencion_default = --keep-daily 7
compresion = lz4
prefijo_automatico = auto-
directorio_montaje = .mnt
directorio_logs = logs

[job_diario]
tipo = automatico
origenes = /home /etc
host = nas-backup
ruta_remota = /backups/diario
frecuencia = diario
retencion = --keep-daily 7 --keep-weekly 4
EOF

    run config_migrate
    [ "$status" -eq 0 ]

    config_load "$COPYCROW_CONF"

    [ "$(config_get_global retention_default)" = "--keep-daily 7" ]
    [ "$(config_get_global compression)" = "lz4" ]
    [ "$(config_get_global auto_prefix)" = "auto-" ]
    [ "$(config_get_global mount_dir)" = ".mnt" ]
    [ "$(config_get_global logs_dir)" = "logs" ]

    [ "$(config_get_var job_diario type)" = "automatic" ]
    [ "$(config_get_var job_diario sources)" = "/home /etc" ]
    [ "$(config_get_var job_diario remote_path)" = "/backups/diario" ]
    [ "$(config_get_var job_diario schedule)" = "daily" ]
    [ "$(config_get_var job_diario retention)" = "--keep-daily 7 --keep-weekly 4" ]

    rm -f "$COPYCROW_CONF" "${COPYCROW_CONF}.bak"
}

@test "config_migrate: backup is created" {
    export COPYCROW_CONF="$(mktemp /tmp/copycrow-migrate-XXXXXX.conf)"
    cat > "$COPYCROW_CONF" << 'EOF'
[global]
compresion = lz4
EOF

    config_migrate
    [ -f "${COPYCROW_CONF}.bak" ]

    rm -f "$COPYCROW_CONF" "${COPYCROW_CONF}.bak"
}

@test "config_migrate: migrates values when fixture has NO 'automatico'" {
    export COPYCROW_CONF="$(mktemp /tmp/copycrow-migrate-XXXXXX.conf)"
    cat > "$COPYCROW_CONF" << 'EOF'
[global]
compresion = lz4

[solo_diario]
tipo = manual
origenes = /home
host = nas
ruta_remota = /backups/diario
frecuencia = diario
EOF

    run config_migrate
    [ "$status" -eq 0 ]

    config_load "$COPYCROW_CONF"
    [ "$(config_get_var solo_diario type)" = "manual" ]
    [ "$(config_get_var solo_diario schedule)" = "daily" ]

    rm -f "$COPYCROW_CONF" "${COPYCROW_CONF}.bak"
}

@test "config_migrate: reports if already in English" {
    export COPYCROW_CONF="$(mktemp /tmp/copycrow-migrate-XXXXXX.conf)"
    cat > "$COPYCROW_CONF" << 'EOF'
[global]
compression = lz4
EOF

    run config_migrate
    [ "$status" -eq 0 ]
    [[ "$output" == *"already in English"* ]]

    rm -f "$COPYCROW_CONF" "${COPYCROW_CONF}.bak"
}

@test "config_migrate: migrates legacy minutesHH:MM schedule value" {
    export COPYCROW_CONF="$(mktemp /tmp/copycrow-migrate-XXXXXX.conf)"
    cat > "$COPYCROW_CONF" << 'CONF'
[job_min]
tipo = automatic
origenes = /home
host = nas
ruta_remota = /backups/min
frecuencia = minutos08:30
CONF

    run config_migrate
    [ "$status" -eq 0 ]

    # After migration the config must load cleanly.
    # Bare call (not `run`): state must survive into this shell for config_get_var.
    config_load "$COPYCROW_CONF"
    [ "$?" -eq 0 ]
    [ "$(config_get_var job_min schedule)" = "minutes08:30" ]

    rm -f "$COPYCROW_CONF" "${COPYCROW_CONF}.bak"
}

@test "config_load: strips UTF-8 BOM instead of failing with misleading error" {
    # Windows editors prepend a BOM; the parser used to treat it as junk
    # and fail with "key appears before any section".
    local conf="/tmp/copycrow-bom-$$.conf"
    printf '\xef\xbb\xbf[job_bom]\ntype = manual\nsources = /home\nhost = server\nremote_path = /a\n' > "$conf"
    config_load "$conf"
    [ "$?" -eq 0 ]
    [ "$(config_get_var job_bom host)" = "server" ]
    rm -f "$conf"
}

@test "config_load: a section literally named __duplicate_ignored__ is a normal job" {
    # The internal duplicate sentinel must not collide with a section of
    # this name: discarding ALL its keys would yield a useless zombie job.
    local conf="/tmp/copycrow-sent-$$.conf"
    cat > "$conf" << 'CONF'
[__duplicate_ignored__]
type = manual
sources = /home
host = server
remote_path = /a
CONF
    config_load "$conf"
    [ "$?" -eq 0 ]
    [ "$(config_get_var __duplicate_ignored__ type)" = "manual" ]
    rm -f "$conf"
}

@test "config_load: explicit empty mount_dir fails with clear message" {
    # An empty `mount_dir =` must never silently degrade extraction to the
    # project root: reject it with a clear message.
    local conf="/tmp/copycrow-empty-md-$$.conf"
    printf '[global]\nmount_dir =\n[job_e]\ntype = manual\nsources = /home\nhost = server\nremote_path = /a\n' > "$conf"
    local out="" rc=0
    out="$(config_load "$conf" 2>&1)" || rc=$?
    [ "$rc" -ne 0 ]
    [[ "$out" == *"must not be empty"* ]]
    rm -f "$conf"
}

@test "config_load: explicit empty retention is accepted (falls back to global)" {
    # Legitimate behavior that must NOT break when accepting empty values.
    local conf="/tmp/copycrow-empty-ret-$$.conf"
    printf '[global]\nretention_default = --keep-daily 7\n[job_r]\ntype = manual\nsources = /home\nhost = server\nremote_path = /a\nretention =\n' > "$conf"
    config_load "$conf"
    [ "$?" -eq 0 ]
    [ -z "$(config_get_var job_r retention)" ]
    rm -f "$conf"
}

# ───────────────────────────────────────────────────────────────────────────────
# Newer global keys + schedule alias
# ───────────────────────────────────────────────────────────────────────────────

@test "config_load: accepts logs_retention_days / verify_schedule / on_failure_cmd" {
    cat > /tmp/copycrow-test-newkeys.conf << 'EOF'
[global]
logs_retention_days = 14
verify_schedule = monthly
on_failure_cmd = notify-send copycrow-failure

[j]
type = manual
sources = /home
host = local
remote_path = /tmp/r
EOF
    # Bare call (not `run`): config_* getters below need the loaded state,
    # which a `run` subshell would discard.
    config_load /tmp/copycrow-test-newkeys.conf
    [ "$(config_get_global logs_retention_days)" = "14" ]
    [ "$(config_get_global verify_schedule)" = "monthly" ]
    [ "$(config_get_global on_failure_cmd)" = "notify-send copycrow-failure" ]
}

@test "logs_retention_days: positive integer only" {
    local bad
    for bad in 0 -5 abc 3.5; do
        cat > /tmp/copycrow-test-lrd.conf << EOF
[global]
logs_retention_days = ${bad}

[j]
type = manual
sources = /home
host = local
remote_path = /tmp/r
EOF
        run config_load /tmp/copycrow-test-lrd.conf
        [ "$status" -ne 0 ] || return 1
        [[ "$output" == *"logs_retention_days"* ]] || return 1
    done
}

@test "verify_schedule: accepts daily|weekly|monthly, rejects others" {
    local ok bad
    for ok in daily weekly monthly; do
        cat > /tmp/copycrow-test-vs-ok.conf << EOF
[global]
verify_schedule = ${ok}

[j]
type = manual
sources = /home
host = local
remote_path = /tmp/r
EOF
        run config_load /tmp/copycrow-test-vs-ok.conf
        [ "$status" -eq 0 ] || return 1
    done
    for bad in yearly hourly; do
        cat > /tmp/copycrow-test-vs-bad.conf << EOF
[global]
verify_schedule = ${bad}

[j]
type = manual
sources = /home
host = local
remote_path = /tmp/r
EOF
        run config_load /tmp/copycrow-test-vs-bad.conf
        [ "$status" -ne 0 ] || return 1
        [[ "$output" == *"verify_schedule"* ]] || return 1
    done
}

@test "on_failure_cmd: rejects shell metacharacters (no eval-class payloads)" {
    local bad
    for bad in 'x;y' 'a&b' 'c|d' 'e$f' '`id`' 'a<b'; do
        cat > /tmp/copycrow-test-ofc.conf << EOF
[global]
on_failure_cmd = ${bad}

[j]
type = manual
sources = /home
host = local
remote_path = /tmp/r
EOF
        run config_load /tmp/copycrow-test-ofc.conf
        [ "$status" -ne 0 ] || return 1
    done
}

@test "schedule: 'at HH:MM' alias canonicalizes to minutesHH:MM" {
    cat > /tmp/copycrow-test-at.conf << 'EOF'
[global]

[j]
type = automatic
sources = /home
host = local
remote_path = /tmp/r
schedule = at 08:30
EOF
    # Bare call: state must survive for the getter assertion below.
    config_load /tmp/copycrow-test-at.conf
    [ "$(config_get_var j schedule)" = "minutes08:30" ]
}

@test "schedule: 'at' alias enforces HH 00-23 / MM 00-59 and strict format" {
    cat > /tmp/copycrow-test-at-bad1.conf << 'EOF'
[global]

[j]
type = automatic
sources = /home
host = local
remote_path = /tmp/r
schedule = at 24:00
EOF
    run config_load /tmp/copycrow-test-at-bad1.conf
    [ "$status" -ne 0 ]

    cat > /tmp/copycrow-test-at-bad2.conf << 'EOF'
[global]

[j]
type = automatic
sources = /home
host = local
remote_path = /tmp/r
schedule = at 7:5
EOF
    run config_load /tmp/copycrow-test-at-bad2.conf
    [ "$status" -ne 0 ]
    [[ "$output" == *"schedule"* ]]
}

# ───────────────────────────────────────────────────────────────────────────────
# cloud keys (ProtonDrive offsite sync)
# ───────────────────────────────────────────────────────────────────────────────

@test "config_load: accepts cloud_remote and cloud_cli_path" {
    cat > /tmp/copycrow-test-cloud1.conf << 'EOF'
[global]
cloud_cli_path = /usr/local/bin/proton-drive

[c_job]
type = manual
sources = /home
host = local
remote_path = /tmp/r
cloud_remote = /Backups/c_job
EOF

    # Bare call (not `run`): config_* getters below need the loaded state,
    # which a `run` subshell would discard.
    config_load /tmp/copycrow-test-cloud1.conf
    [ "$?" -eq 0 ]
    [ "$(config_get_var c_job cloud_remote)" = "/Backups/c_job" ]
    [ "$(config_get_global cloud_cli_path)" = "/usr/local/bin/proton-drive" ]
}

@test "config_validate_value: rejects relative cloud_remote" {
    run config_validate_value cloud_remote "Backups/x"
    [ "$status" -ne 0 ]
    [[ "$output" == *"must start with '/'"* ]]
}

@test "config_validate_value: rejects traversal in cloud_remote" {
    run config_validate_value cloud_remote "/Backups/../etc"
    [ "$status" -ne 0 ]
    [[ "$output" == *"'..'"* ]]
}

@test "config_validate_value: rejects charset violation in cloud_remote" {
    run config_validate_value cloud_remote '/Backups/a b'
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a valid Drive path"* ]]
}

@test "config_load: metacharacters in cloud keys are forbidden (generic rule)" {
    cat > /tmp/copycrow-test-cloud2.conf << 'EOF'
[global]
cloud_cli_path = /opt/tool;x
EOF

    run config_load /tmp/copycrow-test-cloud2.conf
    [ "$status" -ne 0 ]
    [[ "$output" == *"forbidden characters"* ]]
}

@test "config_validate_value: rejects bad charset in cloud_cli_path" {
    run config_validate_value cloud_cli_path '/opt/my tool*'
    [ "$status" -ne 0 ]
    [[ "$output" == *"valid executable path"* ]]
}

@test "config_validate: warns when cloud_remote set on a remote-host job" {
    cat > /tmp/copycrow-test-cloud3.conf << 'EOF'
[global]

[r_job]
type = manual
sources = /home
host = nas
remote_path = /backups/r
cloud_remote = /Backups/r
EOF

    config_load /tmp/copycrow-test-cloud3.conf
    run config_validate
    [ "$status" -eq 0 ]
    [[ "$output" == *"only supports host=local"* ]]
}

@test "config_load: rejects cloud_remote under [global] (scope enforced)" {
    cat > /tmp/copycrow-test-cloud4.conf << 'EOF'
[global]
cloud_remote = /Backups/nope
EOF

    run config_load /tmp/copycrow-test-cloud4.conf
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown key"* ]]
}

@test "config_load: rejects cloud_cli_path in a job section (scope enforced)" {
    cat > /tmp/copycrow-test-cloud5.conf << 'EOF'
[global]

[j]
type = manual
sources = /home
host = local
remote_path = /tmp/r
cloud_cli_path = /usr/bin/proton-drive
EOF

    run config_load /tmp/copycrow-test-cloud5.conf
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown key"* ]]
}

@test "config_validate_value: rejects traversal in cloud_cli_path" {
    run config_validate_value cloud_cli_path '/opt/../evil'
    [ "$status" -ne 0 ]
    [[ "$output" == *"'..'"* ]]
}

@test "config_validate_value: rejects dash-leading cloud_cli_path" {
    run config_validate_value cloud_cli_path '--help'
    [ "$status" -ne 0 ]
    [[ "$output" == *"must not start with '-'"* ]]
}

@test "config_validate_value: accepts spaces inside cloud_cli_path" {
    run config_validate_value cloud_cli_path '/opt/my tools/proton-drive'
    [ "$status" -eq 0 ]
}

@test "config_validate_value: rejects degenerate slashes in cloud_remote" {
    run config_validate_value cloud_remote '/Backups/x/'
    [ "$status" -ne 0 ]
    [[ "$output" == *"//"* ]]

    run config_validate_value cloud_remote '/Backups//x'
    [ "$status" -ne 0 ]
    [[ "$output" == *"//"* ]]
}

# ───────────────────────────────────────────────────────────────────────────────
# Robustness: fail-fast on malformed lines, error count without modulo wrap
# ───────────────────────────────────────────────────────────────────────────────

@test "config_load: fails fast on a malformed line instead of silently ignoring it" {
    # A mangled line (bad section header, stray text) used to be dropped in
    # silence: keys after it landed in the previous section or vanished.
    cat > /tmp/copycrow-test-badline.conf << 'EOF'
[global]

[my_job]
type = automatic
this line is not INI at all
host = nas-backup
EOF

    run config_load /tmp/copycrow-test-badline.conf
    [ "$status" -ne 0 ]
    [[ "$output" == *"malformed line"* ]]
    [[ "$output" == *"this line is not INI at all"* ]]
}

@test "config_load: a mangled section header fails instead of stranding its keys" {
    cat > /tmp/copycrow-test-badsection.conf << 'EOF'
[global]

[my job]
type = automatic
host = nas-backup
EOF

    run config_load /tmp/copycrow-test-badsection.conf
    [ "$status" -ne 0 ]
    [[ "$output" == *"[my job]"* ]]
}

@test "config_validate: nonzero even when the error count wraps modulo 256" {
    # 256 jobs each missing exactly one required field: `return $errors`
    # wrapped 256 -> 0 and validation silently PASSED.
    : > /tmp/copycrow-test-wrap.conf
    printf '[global]\n\n' >> /tmp/copycrow-test-wrap.conf
    local i
    for ((i = 1; i <= 256; i++)); do
        printf '[broken_%d]\ntype = manual\nsources = /home\nhost = local\n' "$i" >> /tmp/copycrow-test-wrap.conf
    done

    # Bare calls (NOT `run`): `run` executes in a subshell and would discard
    # the loaded state, silently validating an empty config instead.
    local lrc=0 vrc=0
    config_load /tmp/copycrow-test-wrap.conf 2>/dev/null || lrc=$?
    [ "$lrc" -eq 0 ]
    config_validate 2>/dev/null || vrc=$?
    [ "$vrc" -ne 0 ]
}
