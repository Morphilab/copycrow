# CopyCrow

[![Version](https://img.shields.io/badge/version-1.2.0-blue.svg)](https://github.com/morphilab/copycrow)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/bash-4%2B-orange.svg)](https://www.gnu.org/software/bash/)
[![Tests](https://img.shields.io/badge/tests-145%2F145%20passing-brightgreen.svg)](tests/)
[![ShellCheck](https://img.shields.io/badge/shellcheck-0%20issues-brightgreen.svg)](.shellcheckrc)

Automated and manual backup system based on **Borg Backup** with a terminal interface (TUI) and native **systemd** timers.

> 100% Bash. Zero runtime dependencies beyond the standard GNU/Linux ecosystem.

**Developer:** [morphilab](https://github.com/morphilab)

## Features

- **Manual and automatic backups** — local or remote via SSH
- **Client-side encryption** with Borg (`repokey`)
- **Deduplication** — only changes between backups are stored
- **Configurable retention** per job (daily, weekly, monthly)
- **TUI interface** with `whiptail` for browsing and extracting backups
- **Native automation** with `systemd --user timers` (no custom daemon)
- **Detailed JSON logs** with timestamps, exit codes, and executed commands
- **No credentials in code** — uses the system's `~/.ssh/config`
- **Secrets never touch disk** — `BORG_PASSPHRASE` is never persisted; timers only receive `BORG_PASSCOMMAND`
- **File locking (atomic)** — prevents concurrent executions of the same job
- **Signal trapping** — automatic cleanup on Ctrl+C / SIGTERM / SIGHUP
- **Config validation** — enforced fail-fast at load time (anti-injection, whitelists, required fields)
- **Dry-run mode** — `./copycrow.sh dryrun <job>` simulates without writing
- **Repository verification** — `verify <job>` / `verify-all` run `borg check`; optional `verify_schedule` timer detects silent corruption
- **Failure notifications** — optional `[global] on_failure_cmd` hook fired when a backup or verification fails
- **Health check** — `doctor` preflights borg (local/remote), SSH, passphrase strategy, linger, systemd session, disk space and directory permissions
- **Log retention** — `[global] logs_retention_days` auto-purges old JSON logs (default 30)
- **Bash completion** — commands, job names and hosts (`completions/copycrow.bash`)

## ⚠️ AI Disclosure / Divulgación de IA

**English:**  
This project was developed with assistance from artificial intelligence tools. Given the automated nature of some components, users are advised to review and test the code independently before integrating it into their own systems.

**Español:**  
Este proyecto fue desarrollado con asistencia de herramientas de inteligencia artificial. Dada la naturaleza automatizada de algunos componentes, se recomienda que los usuarios revisen y prueben el código independientemente antes de integrarlo en sus propios sistemas.
## Requirements

| Dependency  | Installation                          |
|-------------|---------------------------------------|
| `borgbackup` | `sudo apt install borgbackup`        |
| `whiptail`  | `sudo apt install whiptail`          |
| `bash` 4+   | Included in Ubuntu/Debian            |
| `systemd`   | Included in Ubuntu/Debian            |
| `pass` (recommended) | `sudo apt install pass`       |

## Installation

```bash
git clone https://github.com/morphilab/copycrow.git
cd copycrow
./copycrow.sh init
```

This creates `copycrow.conf` (your configuration) from the example.

## Configuration

### 1. Configure SSH (remote backups only)

Create a dedicated key and configure two aliases:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/copycrow_server -N "" -C "copycrow"
ssh-copy-id -i ~/.ssh/copycrow_server.pub user@1xx.1xx.1.1xx
```

Edit `~/.ssh/config`:

```
Host nas-backup
    HostName 1xx.1xx.1.1xx
    User backupuser
    IdentityFile ~/.ssh/id_ed25519          # your daily key

Host nas-backup-borg
    HostName 1xx.1xx.1.1xx
    User backupuser
    IdentityFile ~/.ssh/copycrow_server     # dedicated key without passphrase
```

In copycrow.conf use `host = nas-backup-borg`. See the [Security](#security) section.

### 2. Configure Borg passphrase

```bash
sudo apt install pass
gpg --gen-key                              # generate GPG key
pass init "your-gpg-id"                    # initialize pass
pass insert copycrow/borg                  # store passphrase
export BORG_PASSCOMMAND="pass show copycrow/borg"
```

Add to `~/.bashrc` for persistence.

### 3. Edit `copycrow.conf`

```conf
[global]
retention_default = --keep-daily 7 --keep-weekly 4 --keep-monthly 6
compression = lz4
mount_dir = .mnt
logs_dir = logs
# timeout_start_sec = infinity        # optional; default 3600 (1 h)

[daily_job]
type = automatic
sources = /home /etc
host = nas-backup-borg
remote_path = /backups/copycrow/daily
schedule = daily
retention = --keep-daily 7 --keep-weekly 4
```

## Security

### Dedicated SSH key for backups

Create a key **without a passphrase** for automation while keeping your daily key with a passphrase. Use two SSH aliases to the same server:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/copycrow_server -N "" -C "copycrow"
ssh-copy-id -i ~/.ssh/copycrow_server.pub user@server
```

In `~/.ssh/config`:

```
Host my-server
    HostName 1xx.1xx.1.1xx
    User user
    IdentityFile ~/.ssh/id_ed25519          # daily key with passphrase

Host my-server-borg
    HostName 1xx.1xx.1.1xx
    User user
    IdentityFile ~/.ssh/copycrow_server     # dedicated key without passphrase
```

In `copycrow.conf` use `host = my-server-borg`.

### Restrict key on the server (recommended)

In the server's `~/.ssh/authorized_keys`, restrict the key to only run borg:

```
command="borg serve --restrict-to-path /path/backups",no-port-forwarding,no-pty ssh-ed25519 AAA...
```

### Borg passphrase with `pass` (recommended)

`pass` encrypts the passphrase with GPG. Avoids plaintext in `~/.bashrc`:

```bash
sudo apt install pass
gpg --gen-key                              # generate GPG key
pass init "your-gpg-id"                    # initialize
pass insert copycrow/borg                  # store passphrase
export BORG_PASSCOMMAND="pass show copycrow/borg"
```

Add to `~/.bashrc` for persistence. Copycrow propagates `BORG_PASSCOMMAND` to timers automatically.

> **Note:** copycrow never writes your passphrase to disk. If only `BORG_PASSPHRASE`
> is set, automatic timers will refuse to persist it and backups will fail until you
> configure `BORG_PASSCOMMAND`. Running `./copycrow.sh uninstall` removes the generated
> environment file.

### ssh-agent for SSH keys with passphrase

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
```

## Usage

```bash
./copycrow.sh                       # Open interactive menu (TUI)
./copycrow.sh init                  # Initial setup
./copycrow.sh backup <job>          # Manual backup of a job
./copycrow.sh auto <job>            # Automatic backup (used by timers)
./copycrow.sh dryrun <job>          # Simulate backup (writes nothing)
./copycrow.sh list [job]            # List backups
./copycrow.sh open <host> <arch>    # Extract and open container
./copycrow.sh verify <job>          # Repository integrity check (borg check)
./copycrow.sh verify-all            # Verify every configured repository
./copycrow.sh doctor                # One-shot system health check
./copycrow.sh migrate               # Convert legacy config to English v1.0.0
./copycrow.sh install               # Install systemd timers
./copycrow.sh uninstall             # Remove timers
./copycrow.sh status                # System status
./copycrow.sh help                  # Help
```

## Health checks & notifications

**Verify repositories (`borg check`):**
```bash
./copycrow.sh verify daily_job      # one-off integrity check
```
Add `verify_schedule = monthly` to `[global]` and run `install` to get a
`copycrow-verify.timer` that checks every configured repository on a schedule.

**Get notified when a backup fails:**
```ini
[global]
on_failure_cmd = notify-send "copycrow FAILED"
```
The hook runs WITHOUT a shell (charset-validated at load; no injection surface)
and receives context via environment variables:
`COPYCROW_FAILED_JOB`, `COPYCROW_FAILURE_ARCHIVE`, `COPYCROW_FAILURE_EXIT_CODE`.
A failing hook is logged but never alters the backup's own result.

**Keep logs under control:** `logs_retention_days = 30` in `[global]` purges
`logs/copycrow-*.json` older than N days automatically after each backup.

## Tab Completion

```bash
# Ad hoc:
source completions/copycrow.bash

# Persistent:
mkdir -p ~/.local/share/bash-completion/completions
cp completions/copycrow.bash ~/.local/share/bash-completion/completions/copycrow
```
Completes commands, job names (from the active conf) and SSH hosts.

## Project Structure

```
copycrow/
├── copycrow.sh              ← entry point
├── copycrow.conf            ← your config (gitignored)
├── copycrow.conf.example    ← example configuration
├── README.md
├── LICENSE
├── CHANGELOG.md
├── SECURITY.md
├── VERSION
├── .gitignore
├── .shellcheckrc
├── src/
│   ├── config-parser.sh     ← INI parser + validation
│   ├── safety.sh            ← traps, locks, cleanup
│   ├── backup-core.sh       ← Borg wrapper + JSON logs
│   ├── timer-generator.sh   ← systemd timers
│   ├── doctor.sh            ← health check
│   └── tui.sh               ← whiptail menus
├── completions/
│   └── copycrow.bash        ← bash completion
├── tests/                   ← bats-core tests
│   ├── backup-core.bats
│   ├── cli.bats
│   ├── completions.bats
│   ├── config-parser.bats
│   ├── doctor.bats
│   ├── safety.bats
│   ├── timer-generator.bats
│   ├── tui.bats
│   └── integration-extract.bats
├── .mnt/                    ← temporary extraction
├── .locks/                  ← mutual exclusion locks
└── logs/                    ← daily JSON logs
```

## Tests

```bash
# Requires: bats-core (https://github.com/bats-core/bats-core)
sudo apt install bats
bats tests/
```

## Linting

```bash
shellcheck -x copycrow.sh src/*.sh
```

## Automatic Timers

```bash
./copycrow.sh install
```

This creates `systemd --user` timers for all jobs with `type=automatic`.

**Important:** User timers only run when a login session is active. For always-on execution (even without login):

```bash
loginctl enable-linger
```

## Troubleshooting

**"Permission denied (publickey)"**
- Verify `~/.ssh/config` has the correct `IdentityFile` for that host
- If using a key with a passphrase, unlock it with `ssh-add`
- Test the key on the server: `ssh user@host "echo ok"`

**"Is borg working on the server?"**
Borg is not installed on the remote server:
```bash
ssh host "sudo apt install borgbackup"
```

**"missing_passphrase" (in automatic timers)**
You need `BORG_PASSCOMMAND` configured — `BORG_PASSPHRASE` alone is never persisted to disk (by design). See the [Security](#security) section.

**"BORG_PASSPHRASE is not set" / passphrase prompts in timers**
Timers cannot answer interactive prompts. Configure the passphrase via `pass` + `BORG_PASSCOMMAND` (see [Security](#security)).

**"Repository does not exist"**
The repo is initialized automatically on the first backup. If it fails, check:
- SSH connection to the host: `ssh host "echo ok"`
- Borg installed on the remote server
- Write permissions on `remote_path`

**"copycrow.conf not found"**
```bash
./copycrow.sh init
```

**Timers not running**
```bash
systemctl --user list-timers 'copycrow-*'
loginctl enable-linger
```

**SSH key with passphrase fails in timers**
Timers run outside your login session: there is no `ssh-agent` and the ephemeral
`SSH_AUTH_SOCK` is not persisted (it goes stale after a reboot). Options:
- Use a dedicated passphrase-less key for backups (see [Security](#security)), or
- Expose an agent to the user systemd session (a user-level `ssh-agent.service`,
  plus `AddKeysToAgent yes` in `~/.ssh/config`).

**"Unknown config keys after upgrading?"**
If you upgraded from an older version with Spanish config keys:
```bash
./copycrow.sh migrate    # Converts config to English v1.0.0 format
```
A backup is saved as `copycrow.conf.bak`.

## License

MIT — See `LICENSE` file.
