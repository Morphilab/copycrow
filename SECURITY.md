# Security Policy

## Supported Versions

| Version | Supported     |
|---------|---------------|
| 1.3.x   | ✅ Active     |
| < 1.3   | ❌ End of life|

## Reporting a Vulnerability

If you discover a security vulnerability in copycrow, please **DO NOT open a public issue**. Send a private report via:

- **GitHub Security Advisories**: [Report a vulnerability](https://github.com/morphilab/copycrow/security/advisories/new)

You will receive a response within 72 hours.

## Security Model

copycrow is designed with the following principles:

1. **No credentials in code** — user configuration (`copycrow.conf`) is gitignored. All authentication is delegated to:
   - The system's `~/.ssh/config` for SSH
   - `pass` (GPG-encrypted) for the Borg passphrase, consumed via `BORG_PASSCOMMAND`

2. **Secrets never touch disk** — `BORG_PASSPHRASE` is **never** written anywhere by copycrow. Automation persists only non-secret data (the `BORG_PASSCOMMAND` command string) in `~/.config/copycrow/borg.env` with `0600` permissions inside a `0700` directory. The file is removed by `./copycrow.sh uninstall`. For SSH keys protected by a passphrase, expose an agent to the user systemd session instead (e.g. a user-level `ssh-agent.service` or `AddKeysToAgent yes` in `~/.ssh/config`); the ephemeral `SSH_AUTH_SOCK` path is deliberately not persisted because it goes stale after a reboot.

3. **Input validation, enforced end-to-end** — every configuration value is validated while loading (fail-fast): shell metacharacters are rejected, path traversal is blocked, `host` must be a well-formed SSH alias **without a leading dash** (blocking SSH option injection such as `-oProxyCommand=`), `retention` is restricted to `borg prune --keep-*` flag/number pairs, and `compression` / `type` / `schedule` are whitelist-checked. Required fields (`type`, `sources`, `host`, `remote_path`) are verified before any command performs work.

4. **Encryption at rest** — Borg repositories use `repokey` (key derived from passphrase) by default.

5. **Safe restores** — extracted archives require a sanitized archive name (charset-restricted, no traversal) and the target directory is resolved with `realpath` and contained inside the project mount directory. Extraction runs in a hardened context (`umask 077` plus a post-extract `chmod -R go-rwx`), so archived files with permissive modes never become group/world readable.

6. **Concurrent-safe** — job locking uses kernel `flock`: the lock lives as long as the holder's file descriptor, so it is released by the OS even if the process crashes, and no two runs of the same job can interleave (verified by concurrency stress tests).

7. **User isolation** — timers use `systemd --user`, no root elevation.

8. **Failure hook runs without a shell** — the optional `[global] on_failure_cmd` value is charset-validated at load time (metacharacters `; & | $ \` < > \` are rejected, same class as other keys) and executed via plain word-splitting, never through `eval` or a shell. Failure context reaches the hook only through environment variables (`COPYCROW_FAILED_JOB`, `COPYCROW_FAILURE_ARCHIVE`, `COPYCROW_FAILURE_EXIT_CODE`). A failing hook is logged but cannot alter the backup's result.

9. **SSH hardening recommendation** — the documentation suggests a dedicated passphrase-less SSH key with `command="borg serve --restrict-to-path ..."` in the server's `authorized_keys` (see README).

## Scope

copycrow is a **wrapper on top of Borg Backup** for home users and individual sysadmins. It is **not audited** for use in enterprise or multi-tenant production environments.

## Acknowledgments

We appreciate responsible reports. Contributors who report valid vulnerabilities will be credited in the CHANGELOG (with their permission).
