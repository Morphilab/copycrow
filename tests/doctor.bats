#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# Tests for doctor.sh — external tools STUBBED via PATH (deterministic).
# COPYCROW_ROOT is redirected into the sandbox AFTER sourcing so permission/
# disk probes never touch the real project directories.
# ═══════════════════════════════════════════════════════════════════════════════

setup() {
    export COPYCROW_TEST_SANDBOX="$(mktemp -d /tmp/copycrow-doctor-XXXXXX)"
    export HOME="${COPYCROW_TEST_SANDBOX}/home"
    mkdir -p "$HOME"

    # Sandbox project root: doctor's relative-path resolution lands here.
    export PROJ_ROOT="${COPYCROW_TEST_SANDBOX}/projroot"
    mkdir -p "${PROJ_ROOT}/.mnt" "${PROJ_ROOT}/logs"
    chmod 700 "${PROJ_ROOT}/.mnt" "${PROJ_ROOT}/logs"

    # Existing source path for disk probes (inside the sandbox).
    : > "${PROJ_ROOT}/datafile"

    export COPYCROW_CONF="${COPYCROW_TEST_SANDBOX}/test.conf"
    cat > "$COPYCROW_CONF" << EOF
[global]
compression = lz4
mount_dir = .mnt

[local_job]
type = manual
sources = ${PROJ_ROOT}/datafile
host = local
remote_path = ${PROJ_ROOT}/repo
EOF

    source "${COPYCROW_ROOT:-$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)}/src/config-parser.sh"
    source "${COPYCROW_ROOT:-$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)}/src/backup-core.sh"
    source "${COPYCROW_ROOT:-$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)}/src/doctor.sh"

    # Redirect the module-level root INTO the sandbox (runtime lookups).
    COPYCROW_ROOT="$PROJ_ROOT"

    # ── Stubs ────────────────────────────────────────────────────────────────
    export STUB_BIN="${COPYCROW_TEST_SANDBOX}/bin"
    mkdir -p "$STUB_BIN"

    cat > "${STUB_BIN}/ssh" << 'STUB'
#!/usr/bin/env bash
for a in "$@"; do
    if [[ "$a" == "borg --version" ]]; then
        [[ -n "${STUB_REMOTE_BORG:-x}" ]] && printf '%s\n' "${STUB_REMOTE_BORG}"
        exit 0
    fi
done
exit "${STUB_SSH_RC:-0}"
STUB

    cat > "${STUB_BIN}/systemctl" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "${STUB_SYSTEMD_STATE:-running}"
exit 0
STUB

    cat > "${STUB_BIN}/loginctl" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "${STUB_LINGER:-yes}"
exit 0
STUB

    cat > "${STUB_BIN}/df" << 'STUB'
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted-on"
echo "/dev/sda1 999999999 9999 ${STUB_DF_AVAIL_KIB:-99999999} 1% /mnt"
STUB

    cat > "${STUB_BIN}/whiptail" << 'STUB'
#!/usr/bin/env bash
exit 0
STUB

    # borg is stubbed like every other external: the binary check must not
    # depend on what the host happens to have installed.
    cat > "${STUB_BIN}/borg" << 'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    printf 'borg %s\n' "${STUB_BORG_VERSION:-1.2.8}"
fi
exit 0
STUB

    chmod +x "${STUB_BIN}/"* 2>/dev/null
    export PATH="${STUB_BIN}:${PATH}"

    unset BORG_PASSPHRASE BORG_PASSCOMMAND
}

teardown() {
    rm -rf "$COPYCROW_TEST_SANDBOX"
}

@test "doctor_run: healthy environment exits 0 with zero failures" {
    run doctor_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"[ OK ]"* ]]
    [[ "$output" == *"0 failure(s)"* ]]
}

@test "doctor_run: missing configuration fails with init hint" {
    COPYCROW_CONF="${COPYCROW_TEST_SANDBOX}/ghost.conf"
    run doctor_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"[FAIL] configuration not found"* ]]
    [[ "$output" == *"./copycrow.sh init"* ]]
}

@test "doctor_run: invalid configuration quotes the parser error" {
    cat >> "$COPYCROW_CONF" << 'EOF'

[bad_job]
type = manual
unknown_key = oops
EOF
    run doctor_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"[FAIL] configuration INVALID"* ]]
    [[ "$output" == *"unknown_key"* ]]
    ! grep -q "\[FAIL\] ssh" <<< "$output"
}

@test "doctor_run: unreachable remote host reports FAIL with hints" {
    cat > "$COPYCROW_CONF" << EOF
[global]

[nas_job]
type = automatic
sources = ${PROJ_ROOT}/datafile
host = nas
remote_path = /backups/x
schedule = daily
EOF
    export STUB_SSH_RC=255
    run doctor_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"[FAIL] ssh nas: UNREACHABLE"* ]]
}

@test "doctor_run: reachable host without remote borg fails" {
    cat > "$COPYCROW_CONF" << EOF
[global]

[nas_job]
type = automatic
sources = ${PROJ_ROOT}/datafile
host = nas
remote_path = /backups/x
schedule = daily
EOF
    export STUB_REMOTE_BORG=""
    run doctor_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"ssh nas: borg NOT installed remotely"* ]]
}

@test "doctor_run: absent passphrase mechanism is WARN, not FAIL" {
    run doctor_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"[WARN] no passphrase mechanism"* ]]
}

@test "doctor_run: linger states map to warn/pass" {
    export STUB_LINGER=no
    run doctor_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"[WARN] linger DISABLED"* ]]
    [[ "$output" == *"loginctl enable-linger"* ]]

    export STUB_LINGER=yes
    run doctor_run
    [[ "$output" == *"[ OK ] linger enabled"* ]]
}

@test "doctor_run: low local disk space fails; healthy space passes" {
    export STUB_DF_AVAIL_KIB=50000
    run doctor_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"[FAIL] disk"* ]]
    [[ "$output" == *"(<100MiB)"* ]]

    export STUB_DF_AVAIL_KIB=5000000
    run doctor_run
    [[ "$output" == *"[ OK ] disk"* ]]
}

@test "doctor_run: world-writable extraction dir fails; 700 passes" {
    chmod 777 "${PROJ_ROOT}/.mnt"
    run doctor_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"WORLD-WRITABLE"* ]]

    chmod 700 "${PROJ_ROOT}/.mnt"
    run doctor_run
    [[ "$output" == *"[ OK ] permissions ok"* ]]
}

# ───────────────────────────────────────────────────────────────────────────────
# cloud (ProtonDrive) checks
# ───────────────────────────────────────────────────────────────────────────────

@test "doctor: no mention of Proton when no job uses cloud_remote" {
    run doctor_run
    [ "$status" -eq 0 ]
    ! grep -q "Proton" <<< "$output"
}

@test "doctor: flags missing proton-drive CLI when a cloud job exists" {
    cat > "$COPYCROW_CONF" << EOF
[global]
compression = lz4
mount_dir = .mnt

[cloudfob]
type = manual
sources = ${PROJ_ROOT}/datafile
host = local
remote_path = ${PROJ_ROOT}/repo
cloud_remote = /Backups/cloudfob
EOF
    config_load "$COPYCROW_CONF"
    run doctor_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"proton-drive CLI not found"* ]]
}

@test "doctor: healthy cloud setup passes binary, wrapper and session probes" {
    cat > "${STUB_BIN}/proton-drive" << 'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "${STUB_BIN}/proton-drive"
    export COPYCROW_CLOUD_WRAP="none"
    cat > "$COPYCROW_CONF" << EOF
[global]
compression = lz4
mount_dir = .mnt

[cloudok]
type = manual
sources = ${PROJ_ROOT}/datafile
host = local
remote_path = ${PROJ_ROOT}/repo
cloud_remote = /Backups/cloudok
EOF
    config_load "$COPYCROW_CONF"
    run doctor_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"proton-drive CLI:"* ]]
    [[ "$output" == *"Proton Drive session alive"* ]]
}
