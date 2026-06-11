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
    run config_validate_value "schedule" "minutes99:99"
    [ "$status" -eq 0 ]

    run config_validate_value "schedule" "minutesbad"
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

@test "config_validate: fails if remote_path is invalid" {
    cat > /tmp/copycrow-test-10.conf << 'EOF'
[global]

[job_x]
type = automatic
sources = /home
host = server
remote_path = /backups/../etc
EOF

    config_load /tmp/copycrow-test-10.conf
    run config_validate
    [ "$status" -ne 0 ]
}

@test "config_validate: fails if schedule is invalid" {
    cat > /tmp/copycrow-test-11.conf << 'EOF'
[global]

[job_x]
type = automatic
sources = /home
host = server
remote_path = /b
schedule = every_5_minutes
EOF

    config_load /tmp/copycrow-test-11.conf
    run config_validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"schedule"* ]]
}

@test "config_validate: fails if compression is invalid" {
    cat > /tmp/copycrow-test-12.conf << 'EOF'
[global]
compression = no_such

[job_x]
type = automatic
sources = /home
host = server
remote_path = /b
EOF

    config_load /tmp/copycrow-test-12.conf
    run config_validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"compression"* ]]
}

@test "config_validate: fails if host contains dangerous characters" {
    cat > /tmp/copycrow-test-13.conf << 'EOF'
[global]

[job_x]
type = automatic
sources = /home
host = 'server;rm -rf /'
remote_path = /b
EOF

    config_load /tmp/copycrow-test-13.conf
    run config_validate
    [ "$status" -ne 0 ]
}

@test "config_validate: fails if source contains path traversal" {
    cat > /tmp/copycrow-test-14.conf << 'EOF'
[global]

[job_x]
type = automatic
sources = /home/../etc
host = server
remote_path = /b
EOF

    config_load /tmp/copycrow-test-14.conf
    run config_validate
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
# config_migrate — legacy config conversion
# ───────────────────────────────────────────────────────────────────────────────

@test "config_migrate: converts Spanish keys to English" {
    cat > "${COPYCROW_ROOT}/copycrow.conf" << 'EOF'
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

    config_load "${COPYCROW_ROOT}/copycrow.conf"

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

    rm -f "${COPYCROW_ROOT}/copycrow.conf" "${COPYCROW_ROOT}/copycrow.conf.bak"
}

@test "config_migrate: backup is created" {
    cat > "${COPYCROW_ROOT}/copycrow.conf" << 'EOF'
[global]
compresion = lz4
EOF

    config_migrate
    [ -f "${COPYCROW_ROOT}/copycrow.conf.bak" ]

    rm -f "${COPYCROW_ROOT}/copycrow.conf" "${COPYCROW_ROOT}/copycrow.conf.bak"
}

@test "config_migrate: reports if already in English" {
    cat > "${COPYCROW_ROOT}/copycrow.conf" << 'EOF'
[global]
compression = lz4
EOF

    run config_migrate
    [ "$status" -eq 0 ]
    [[ "$output" == *"already in English"* ]]

    rm -f "${COPYCROW_ROOT}/copycrow.conf"
}
