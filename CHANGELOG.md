# Changelog

All notable changes to copycrow are documented here.

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
