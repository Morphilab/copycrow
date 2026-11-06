# Changelog

All notable changes to copycrow are documented here.

## 1.3.1 — 2026-11-06

Reliability hardening for publication: two real concurrency/configuration
bugs fixed with deterministic regression tests, a docs-truthfulness pass
(README badge, `on_failure_cmd` semantics, `help --version`), and expanded
test coverage (`init`, TUI temp cleanup).

A follow-up full audit added a real-borg end-to-end suite and closed the
remaining reliability and validation gaps: lock-release ordering, TUI
locking, `sources` option-injection defense, strict retention grammar,
best-effort logging and systemd unit escaping.

A post-audit follow-up closed the gaps that review left open: `%` escaping in
`ExecStart`, lock failures that no longer pass for a busy job, install-wide
notices emitted once instead of per unit, and hermetic borg state in the
integration suites.

### Fixed
- **fix(timers)**: re-installing timers from a shell without `BORG_PASSCOMMAND`
  no longer strips `EnvironmentFile` from the generated units. The previously
  persisted `~/.config/copycrow/borg.env` (deliberate, non-secret state) is
  reused and referenced again, so automatic backups can no longer silently
  lose their passphrase wiring while the env file sits unused on disk.
- **fix(safety)**: closed the classic unlink race on job lock files. A process
  that opened the lock file just before a holder released it (unlock + rm)
  could flock the orphaned inode while the path was being recreated — two
  simultaneous "holders" on one job. A post-flock inode recheck now detects
  the swap and retries on the current file (bounded); when the check cannot
  run (no `/proc`), locking fails open exactly as before.
- **fix(parser)**: unrecognized config lines abort loading (fail-fast) instead
  of being silently dropped; `config_validate` returns an explicit boolean —
  an error count of 256 used to wrap modulo 256 into apparent success.
- **fix(core)**: multi-repo archive lookup no longer leaks a stale exit code;
  extraction runs in a subshell (no `cd`/`umask` leak into the caller); the
  delete prompt of `open` requires an explicit `y` (Enter keeps the files).
- **fix(tui)**: `COPYCROW_CONF` is honored in every guard, load and status
  view; ESC/cancel can no longer kill the menu loop under `errexit`; temp
  output lives under the configured mount dir and is registered for
  signal-safe cleanup.
- **fix(cloud-sync)**: files that vanish mid-walk (concurrent compaction) are
  skipped with a warning instead of killing the sync; the manifest stays
  consistent and the next run retries.
- **fix(ops)**: `migrate` runs on headless minimal systems (no whiptail
  requirement); orphan-timer cleanup concludes with `daemon-reload`.
- **docs**: README test badge and `on_failure_cmd` examples corrected (the
  hook runs without a shell — quotes are NOT interpreted, word-split only);
  `help` now documents `--version`.
- **docs**: README documents previously implicit behavior — `verify-all` skips
  busy jobs with a warning (never a failure), `COPYCROW_CONF` overrides the
  config path for every command that reads configuration (`init` remains the
  bootstrap exception), the TUI offers no `init`/`verify-all`/`auto`, and the
  Borg versions the end-to-end suite is verified against (1.2.4, 1.4.4).
  `help` lists the `--help`/`-h` and `-V` aliases.
- **docs**: corrected remaining docs-vs-code drift: `verify`/`dryrun` no
  longer claim to write nothing, Bash requirement raised to 4.2+, `verify`
  documents that it does not pass `--verify-data`, completion documents its
  real config resolution, and `SECURITY.md` scopes passphrase/validation/
  locking claims to actual behavior.
- **fix(safety)**: lock release removes the lock file BEFORE unlocking and
  closing the fd, on top of the inode recheck: a late acquirer can no longer
  flock an orphaned inode whose path is about to be recreated. The fd close
  no longer silences the process stderr for the rest of the run
  (`exec {fd}>&- 2>/dev/null` is an exec-with-redirections).
- **fix(tui)**: backup and verify actions run under the same per-job `flock`
  as the CLI, so TUI runs can no longer interleave with a timer on the same
  job.
- **fix(parser)**: `sources` tokens starting with `-` are rejected (Borg
  option injection); `retention` accepts every value shape `borg prune`
  supports — including `--keep-last N` and `--keep-within <int><char>` —
  while still failing fast on dangling flags, bare values and bad intervals.
- **fix(core)**: sources are handed to borg as an array (no globbing) and
  after `--`, so a source token can never be parsed as a borg option;
  `on_failure_cmd` tokenizes without pathname expansion too.
- **fix(core)**: `verify-all` takes the per-job lock; a job busy with a
  running backup is skipped with a warning (still rc 0) instead of failing
  spuriously and firing the failure hook.
- **fix(core)**: JSON logging is best-effort: an unwritable log directory
  warns on stderr and never aborts an otherwise successful backup.
- **fix(timers)**: the generated `copycrow-verify` unit now wires the same
  `EnvironmentFile` as job units (scheduled verification of encrypted repos
  no longer dies for lack of a passphrase source); generated unit paths
  escape `%` as `%%` per systemd specifier expansion, and `Environment=`
  values are quoted/escaped per systemd syntax.
- **fix(timers)**: `ExecStart=` gets the same `%` escaping as the other path
  settings — systemd expands specifiers there too, so an install path with a
  literal `%` used to make the timer exec a nonexistent command while
  `WorkingDirectory` resolved correctly.
- **fix(timers)**: the `BORG_PASSPHRASE`-cannot-be-stored and env-file-reuse
  notices are emitted once per install instead of once per generated unit,
  and generating the verify unit alone no longer stays silent about an
  unstorable passphrase.
- **fix(safety)**: `safety_lock_acquire` returns 2 when locking is impossible
  (no `flock`, unusable lock file, lock file changing on every attempt)
  instead of reusing 1, which means "held by another process"; the runner
  keeps that diagnosis rather than announcing "already in progress", and its
  message no longer says "backup" when the action is verify or sync.
- **fix(core)**: `verify-all` counts an untakeable lock as a failure instead
  of reporting it as a busy skip — with rc 0 the integrity timer could
  report success while verifying nothing — and the skip warning is printed
  even when other jobs fail.
- **fix(core)**: a wrong passphrase on an EXISTING repository is reported as
  what it is — the repository exists but the supplied credentials cannot
  open it — instead of falling through to `borg init` and surfacing the
  misleading "A repository already exists / Could not initialize repository".
  Missing repositories still initialize as before.
- **docs**: audit pass over public documentation and code comments — `help`
  no longer claims `status` lists last backups, `list <job>` documents that it
  scopes by the job's host (archive names carry no job identifier), the
  troubleshooting headings quote the real messages, and the Proton wrapper is
  described as headless-only.
- **repo**: `.gitignore` covers `copycrow.conf.migrated.*` leftovers.

### Changed
- **docs**: Spanish translation of the README (`README.es.md`) with a language
  selector on both files; English (`README.md`) remains the default.
- Hermetic test fixtures for CI parity (doctor borg stub, timer XDG pin, TUI
  sandbox root); `init` now covered by tests in a sandboxed root.
- Real-borg end-to-end suite (`tests/integration-borg.bats`): repo init →
  backup → list → verify → verify-all → extract → prune, plus the
  wrong-passphrase path (validation grammar is covered by the unit suites).
  CI installs `borgbackup` so the integration suites run there; verified
  against borg 1.2.4 (Ubuntu LTS) and 1.4.4.
- Integration suites sandbox borg's own state (`BORG_CACHE_DIR`,
  `BORG_CONFIG_DIR`, `BORG_SECURITY_DIR`): running them no longer leaves
  entries in the caller's `~/.config/borg`.
- `sources` documented as **literal** paths (no wildcard/`~` expansion) in
  `copycrow.conf.example` and the README.
- Dead code removed: `backup_init` had no callers since the project's origin
  (and its log-directory handling was wrong for an absolute `logs_dir`).
- `SECURITY.md` input-validation wording updated: `sources` leading-dash
  rejection and the retention flag/value grammar.
- **repo**: `.gitignore` now contains only portable public rules. Local tooling
  and internal development docs live in `.git/info/exclude` and are never
  published.
- **tests**: CLI/TUI/backup-core fixtures pin `logs_dir` to their sandbox, so
  the suite no longer writes into the project's `logs/` directory.

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
  tooling files were ignored by the versioned `.gitignore` at that time
  (later moved to machine-local excludes; see 1.3.1).

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
  permissions, with actionable [ OK ]/[WARN]/[FAIL] output.
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
