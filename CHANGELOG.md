# Changelog

All notable changes to copycrow are documented here.

## 1.3.0 — 2026-09-04

Offsite replication to Proton Drive, plus a documentation and comment
hygiene round.

### Added
- **sync <job>**: replicate LOCAL repositories (`host = local`) to
  [Proton Drive](https://proton.me/drive) via the official `proton-drive`
  CLI. Opt-in per job with `cloud_remote`; `[global] cloud_cli_path`
  overrides the binary location.
- Incremental upload engine driven by a local manifest
  (`~/.cache/copycrow/cloud/<job>.manifest`): unchanged files (size+mtime)
  are skipped, rewritten files use "replace"; a failed run never updates
  the manifest, so the next run retries everything.
- Headless support: CLI calls are wrapped in `dbus-run-session` when no
  graphical session exists; `COPYCROW_CLOUD_WRAP` overrides the wrapper
  (deterministic runs/tests).
- **doctor**: Proton Drive checks (binary, D-Bus wrapper, session).
- TUI: "Sync job to Proton Drive" entry (CLI parity).

### Changed
- Comments and test names cleaned for release: internal audit round IDs,
  commit hashes and process narration removed; test comments unified to
  English per the language policy.
- `.gitignore` repaired: `logs/.gitkeep` is now actually tracked; local
  tooling files (`opencode.json`, `.zcode/`) are ignored by the versioned
  `.gitignore`, not just machine-local excludes.

### Fixed
- README accuracy: log purge glob is `copycrow-*.log` (not `.json`),
  `src/cloud-sync.sh` added to the project structure, test badge count,
  and the usage section now lists `manual`, `sync` and `--version`.
- Help text alignment in the CLI.

## 1.2.0 — 2026-08-24

Roadmap round from the full project audit: reliability ("gold standard"
backup practices) plus complete CLI↔TUI parity.

### Added
- **verify <job> / verify-all**: repository integrity via `borg check`;
  optional `[global] verify_schedule` (daily|weekly|monthly) installs a
  `copycrow-verify.timer`. Verification failures fire the failure hook too.
- **doctor**: one-shot health check — borg local/remote, SSH reachability,
  passphrase strategy, linger, systemd session, disk space and directory
  permissions, with actionable ✓/✗ output.
- **on_failure_cmd** ([global]): user hook fired when a backup or verification
  fails. Context via env vars `COPYCROW_FAILED_JOB`,
  `COPYCROW_FAILURE_ARCHIVE`, `COPYCROW_FAILURE_EXIT_CODE`. Charset-validated
  at load; executed without a shell (no eval).
- **logs_retention_days** ([global], default 30): automatic JSON log purge
  after each backup.
- **schedule `at HH:MM`** alias ("daily at HH:MM"), canonicalized internally
  to the existing `minutesHH:MM`.
- bash-completion for commands, job names and hosts (`completions/copycrow.bash`).

### Fixed
- `dryrun` printed a duplicated/empty Retention line when the job had no
  retention of its own.
- `list` showed duplicate archives when one archive existed in two repos of
  the same host.
- Raw interactive prompts can never appear over the TUI anymore:
  backend helpers consult a `COPYCROW_UNDER_TUI` flag set by the menu loop.

### Changed
- TUI now exposes dry-run, configured-jobs detail, verify, doctor and migrate
  (extended CLI↔TUI parity; previously dead `tui_list_jobs` is wired in).
- CI lints the completion script and runs dryrun+status smokes per build.
- Language policy codified: public artifacts (UI strings, README, SECURITY)
  stay in English; internal development docs remain Spanish.
- Test suite grown from 99 to 145 tests.

## 1.1.0 — 2026-08-24

Logic fixes and robustness round from a full project audit.

### Fixed (logic)
- **fix(parser)**: keys placed before any `[section]` header are now rejected
  with an explicit error; they used to be silently stored and lost.
- **fix(parser)**: `migrate` now detects inline legacy values
  (`frecuencia = diario`, etc.) regardless of an `automatico` being present;
  migrated configs are always valid under the new parser.
- **fix(safety)**: `safety_lock_run` captures the command exit code per the
  project convention; lock release no longer depends on the EXIT trap.
- **fix(tui)**: backend failures render error dialogs instead of killing the
  TUI; success dialogs reflect the real result.
- **fix(timers)**: `timer_generate_all` tracks per-job failures explicitly and
  reports them instead of returning success with broken timers.
- **fix(parser,core)**: `auto_prefix`/`manual_prefix` are charset-validated;
  listing filters archives by literal prefix (regex-safe).
- **fix(parser)**: `remote_path` must be absolute — prevents malformed
  `ssh://` repository URLs.
- **fix(core)**: `_run_capture` temporals are registered for signal-safe cleanup.

### Changed / Robustness
- **fix(timers)**: non-default `COPYCROW_CONF` is propagated into generated
  service units (`Environment=`), so timers read the conf they were installed from.
- **fix(timers)**: `SSH_AUTH_SOCK` is no longer persisted (stale after reboot);
  agent alternatives documented in README/SECURITY.
- **fix(parser)**: absolute `mount_dir` is rejected, keeping extractions
  contained under the project root; `logs_dir` keeps supporting absolute paths.
- **feat(cli)**: new `--version`/`-V`; surplus arguments are rejected per
  command arity instead of being ignored.
- **docs(onboarding)**: all setup paths recommend `pass` + `BORG_PASSCOMMAND`;
  `BORG_PASSPHRASE` is never suggested as a setup step anymore.

## 1.0.1 — 2026-08-22

Security and robustness release from a full code audit.

### Security
- **fix(core)**: `open <host> <archive>` / extraction paths are now safe —
  archive names are charset-validated (no traversal, no separators, no
  metacharacters) and the target directory is resolved with `realpath` and
  contained inside the project mount directory. Extractions run under
  `umask 077`. *(critical)*
- **feat(cli)**: full configuration validation is enforced on every command
  (`backup/auto/dryrun/list/open/install/status` and the TUI). The
  anti-injection controls are no longer optional dead code. *(high)*
- **fix(parser)**: `host` values cannot start with a dash — blocks SSH option
  injection such as `-oProxyCommand=`. *(high)*
- **fix(timers)**: `BORG_PASSPHRASE` is **never** written to disk anymore.
  `~/.config/copycrow/borg.env` holds only non-secret data
  (`BORG_PASSCOMMAND`, `SSH_AUTH_SOCK`) and is deleted by `uninstall`.
  SECURITY.md updated accordingly. *(high)*
- **fix(parser)**: unknown keys fail configuration loading (typo-proof key
  whitelist); `retention` accepts only `borg prune --keep-*` flag/number pairs;
  `schedule minutesHH:MM` enforces HH 00-23 / MM 00-59; duplicate sections and
  inline comments handled deterministically.

### Robustness
- **fix(core)**: borg failures can no longer kill the process before being
  logged (`_run_capture`). Automated backups that fail now leave JSON ERROR
  entries and a clear console message instead of dying silently.
- **fix(safety)**: job locks use atomic create-fail-if-exists (no TOCTOU race)
  and SIGHUP is trapped for terminal-close cleanup.
- **fix(parser)**: compound config keys use a collision-free separator, so two
  jobs can never overwrite each other's settings.
- **fix(core)**: `list`/`open` now see **every** repository configured for a
  host, not just the first one.
- **fix(timers)**: `TimeoutStartSec` configurable via global
  `timeout_start_sec` (number or `infinity`; default 3600).

### Tests & tooling
- bats suite grown from 34 to 69 tests: parser hardening, safety concurrency,
  core failure paths (with stubbed `borg`), timer generation in sandboxed
  `$HOME`, and CLI dispatcher integration via `COPYCROW_CONF` override.
- Migration tests no longer overwrite the project's real `copycrow.conf`.
- GitHub Actions CI: ShellCheck + bats on push/PR.
- `.gitignore`: anchored `backup-*` to root so project sources are never ignored.

## 1.0.0 — 2026-06-11

Initial public release.
