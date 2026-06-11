# Security Policy

## Supported Versions

| Version | Supported     |
|---------|---------------|
| 1.0.x   | ✅ Active     |
| < 1.0   | ❌ End of life|

## Reporting a Vulnerability

If you discover a security vulnerability in copycrow, please **DO NOT open a public issue**. Send a private report via:

- **Email**: [reports@morphilab.com] 

You will receive a response within 72 hours.

## Security Model

copycrow is designed with the following principles:

1. **No credentials in code** — user configuration (`copycrow.conf`) is gitignored. All authentication is delegated to:
   - The system's `~/.ssh/config` for SSH
   - `pass` (GPG-encrypted) for the Borg passphrase
   - `BORG_PASSCOMMAND` (not persisted to plain disk)

2. **Input validation** — all `.conf` values are validated against dangerous characters (`;`, `&`, `|`, `$`, backticks, redirections) and path traversal (`..`) before use in commands.

3. **Encryption at rest** — Borg repositories use `repokey` (key derived from passphrase) by default. The passphrase is never persisted as plaintext in systemd `.service` files — it is stored in `~/.config/copycrow/borg.env` with `0600` permissions.

4. **User isolation** — timers use `systemd --user`, no root elevation. Extracted files are automatically cleaned up when closing the TUI session.

5. **SSH hardening recommendation** — the documentation suggests a dedicated passphrase-less SSH key with `command="borg serve --restrict-to-path ..."` in the server's `authorized_keys` (see README).

## Scope

copycrow is a **wrapper on top of Borg Backup** for home users and individual sysadmins. It is **not audited** for use in enterprise or multi-tenant production environments.

## Acknowledgments

We appreciate responsible reports. Contributors who report valid vulnerabilities will be credited in the CHANGELOG (with their permission).
