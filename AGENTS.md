# Rules for AI agents

This repo automates a Bluefin DX workstation. Read README.md first.
These rules are mandatory.

## The OS is immutable
- Never run `dnf install`, `rpm-ostree install`, or edit anything under `/usr`.
  Install software with Flatpak (GUI apps), Homebrew (CLI tools) or Distrobox.
- Never run `ujust update` or `rpm-ostree reset`. Layered packages make bootc
  refuse the update, and reset would remove them. For manual OS updates use
  `rpm-ostree upgrade`, `flatpak update`, `brew upgrade`.
- Never suggest these commands in code, docs or AI prompts either.

## The health check stays read-only
- `bluefin/scripts/health-check.sh` may only *observe* the system. No sudo, no
  installs, no service restarts, no config changes, no deleting.
- It may write only its own output: the raw file, the temp file and the report.
- New checks must be read-only commands wrapped in `run` (180-second timeout).
- The Claude call must keep write and network tools blocked (`--disallowedTools`).

## Scripts must pass ShellCheck
- Run `shellcheck -S warning bluefin/scripts/*.sh` before proposing a change.
  No warnings or errors; `info` notes are fine when the code is intentional.
- Bash scripts: `#!/usr/bin/env bash`; quote variables.
- Exception: `bluefin/scripts/lid-is-open.sh` is intentionally POSIX `sh`
  with `#!/bin/sh` and shell built-ins only, because PAM (`pam_exec`) runs it
  with a minimal environment. Don't convert it to bash.

## Authentication (PAM) changes
- Change PAM only through the custom authselect profile
  (`/etc/authselect/custom/lid-aware-fp/`), never by editing `/etc/pam.d`
  directly. See `bluefin/auth/README.md`.
- Every `authselect select` or `apply-changes` uses a named `--backup=...`.
- A root shell (`sudo -i`) must be open in a second terminal before any PAM
  change, and stay open until the tests pass.

## systemd units use full paths
- `ExecStart=` and every path in a unit must be absolute, or use a systemd
  specifier such as `%h` (home folder). No `~`, no `$HOME`, no relying on `PATH`.
- These are **user** units (`~/.config/systemd/user`, `systemctl --user`).
  Don't turn them into system units.
- Keep `Persistent=true` on timers.

## No secrets or personal data
- Never commit tokens, passwords, keys, `.env` files, raw health data (`raw/`),
  report contents, IP addresses or Tailscale names.
- Never commit `u2f_keys` or any other key material (YubiKey registrations,
  private keys, recovery codes).
- Check the diff for personal details before every commit.

## Never delete files
- Don't use `rm`. Move files to `~/ai/_to_delete/` instead; `clean-to-delete`
  removes them after 21 days, with a reminder at day 14.
- The deletion inside `clean-to-delete.sh` is the one designed exception. Don't
  widen what it deletes, shorten its delays, or run it without `--dry-run`
  while testing.

## Don't touch the live system without asking
- Don't install, enable, disable or restart units, or copy files into place,
  unless the owner asks. Show the exact commands and how to undo them first.
- Don't change, duplicate or "fix" the existing automations (`uupd.timer`,
  `bluefin-health.timer`, `brew-upgrade.timer`, `clean-to-delete.timer`,
  `logrotate.timer`) without asking.

## Git workflow
- Never commit directly to `main`. Create a branch (`fix/...`, `feat/...`,
  `docs/...`) and propose changes through a pull request.
- In the PR description, say what changed, why, how it was tested
  (ShellCheck output, `--dry-run`, a manual service run), and how to undo it.
- Keep README.md in sync when behavior, schedules or paths change.
