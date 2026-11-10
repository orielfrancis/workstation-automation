# Workstation automation (Bluefin DX)

[![ShellCheck](https://github.com/orielfrancis/workstation-automation/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/orielfrancis/workstation-automation/actions/workflows/shellcheck.yml)

Scripts and systemd user units that keep my Bluefin DX workstation
(Fedora Atomic / Universal Blue) healthy. Everything runs as my user: no root,
nothing installed into the immutable OS image. The two exceptions are
applied by hand with sudo: `bluefin/auth/` (PAM) and `bluefin/uupd/config.json`.

```
.devcontainer/
├── Dockerfile                dev container image (authoring and linting only)
└── devcontainer.json         VS Code Dev Containers settings
bluefin/
├── auth/
│   └── README.md             lid-aware fingerprint + YubiKey sudo (manual, system-level)
├── scripts/
│   ├── health-check.sh       nightly read-only health report
│   ├── clean-to-delete.sh    reminder + cleanup for ~/ai/_to_delete
│   └── lid-is-open.sh        PAM lid check (installed to /usr/local/bin/lid-is-open)
├── systemd/
│   ├── bluefin-health.service / .timer
│   ├── brew-update.service    / .timer
│   ├── brew-upgrade.service   / .timer
│   ├── clean-to-delete.service / .timer
│   └── uresourced.service.d/restart.conf   drop-in: restart Fedora's uresourced user service after a crash
└── uupd/
    └── config.json           turns off uupd's brew module (installed to /etc/uupd/config.json; system-level, needs sudo)
```

## Automations

| Timer | Schedule | What it does |
|---|---|---|
| `brew-update.timer` | Daily 04:30 | `brew update`: refreshes package lists, installs nothing |
| `bluefin-health.timer` | Daily 04:45 | Read-only health report |
| `brew-upgrade.timer` | Sundays 05:15 | `brew upgrade --formula` |
| `clean-to-delete.timer` | Daily 10:00 | Reminds about, then deletes, old files in `~/ai/_to_delete` |

All four timers use `Persistent=true`: a run missed because the machine was
off or asleep runs at the next boot or login.

### bluefin-health: nightly health report

Runs after Bluefin's own updater (`uupd.timer`, about 04:00–04:15), so the
report shows the result of that night's update.

1. **Collect.** Runs read-only commands, with no sudo and a 180-second limit
   each: `hostnamectl`, `rpm-ostree status`, disk, memory, failed system and
   user units, journal errors for the last 24 hours (grouped and counted),
   recent boots and shutdowns, power profile (`tuned-adm`), temperatures,
   battery, pending Flatpak / Homebrew / firmware updates, Tailscale status,
   the pCloud client, top memory users, and the Claude Code version.
   Homebrew's package lists are fresh because `brew-update.timer` runs at
   04:30. The health check itself never runs `brew update`, so it stays
   read-only. It also checks the 1Password cask: the installed version, whether the
   program file exists, and whether an update is waiting.
   Saved to `~/ai/sysadmin/health/raw/bluefin-YYYY-MM-DD.txt` (local only).
2. **Summarize.** Sends the raw data, plus the previous report for comparison,
   to Claude Code in headless mode (`claude -p`) with no write tools (Bash,
   Edit, Write, NotebookEdit, WebFetch and WebSearch are blocked). The prompt
   lists the known harmless noise and sets the "Attention" thresholds.
3. **Write.** Saves the report to `~/ai/notes/health/bluefin-YYYY-MM-DD.md`.
   If the AI step fails, it writes a fallback report that holds the raw data
   and is marked `Status: Attention`.
4. **1Password alert.** If 1Password is missing, or an update is waiting, the
   script itself adds a `## 1Password` section to the report. The section
   holds the exact command (`brew upgrade --cask 1password-gui-linux`). The
   script also sends a separate "1Password needs attention" notification.
   This step doesn't depend on the AI summary.
5. **Notify.** Sends a desktop notification with the status line.

Service limits: `Nice=10`, 20-minute timeout.
Run it now: `systemctl --user start bluefin-health.service`

### brew-update: daily Homebrew metadata refresh

Runs `brew update --quiet` at 04:30. It refreshes the package lists and taps,
and installs nothing. uupd used to do this nightly, until its brew module was
turned off (see below). Without this refresh, the 04:45 health check would see
a new 1Password version only after Sunday's `brew-upgrade` run.
Service limits: `Nice=10`, 15-minute timeout.
Log: `journalctl --user -u brew-update`

### brew-upgrade: weekly Homebrew upgrade

This timer runs `brew upgrade --formula` to install new versions of formulae.
Casks are skipped: the 1Password cask (`ublue-os/tap/1password-gui-linux`)
needs sudo to upgrade, so an unattended run fails. Upgrade casks
manually with `brew upgrade --cask <name>`.

**uupd's brew module is turned off** with `bluefin/uupd/config.json`, which
is installed to `/etc/uupd/config.json`. uupd 1.5.2 runs `brew upgrade -y`,
which includes casks, not only `brew update`. On 2026-11-08 that unattended
run waited about 38 hours for a sudo prompt on the 1Password cask. It then
failed partway, and Homebrew's rollback removed 1Password completely. Check
the setting with `uupd config-dump | grep -A2 '"brew"'`.
Service limits: `Nice=10`, 45-minute timeout.
Log: `journalctl --user -u brew-upgrade`

### clean-to-delete: two-stage cleanup of ~/ai/_to_delete

`~/ai/_to_delete` is a holding area: files are moved there instead of being
deleted.

- **Day 14:** one desktop reminder per file (urgent notification, up to 10
  file names listed).
- **Day 21:** the file is deleted, but only if its reminder went out at least
  7 days earlier. A file can never be deleted without a week's warning, even
  if the timer didn't run for a while.
- Empty folders inside `_to_delete` are removed.

Age is measured from when the file **arrived** in the folder (ctime), not from
its modified time; `mv` keeps the old modified time.

State and log: `~/.local/state/clean-to-delete/` (`notified` and `deleted.log`).
Preview without changing anything:

```bash
~/bin/clean-to-delete.sh --dry-run
```

## Authentication

Lid-aware fingerprint and YubiKey taps for `sudo` and polkit prompts, set up
through a custom authselect profile. Unlike the timers above, this part
changes system PAM files and is applied by hand, not by an installer.

- Lid closed (docked): no fingerprint wait; YubiKey tap or password.
- Lid open: fingerprint works as before.
- Login and lock screens: password (plus fingerprint with the lid open),
  no YubiKey.

Steps, tests and rollbacks: [bluefin/auth/README.md](bluefin/auth/README.md).

### uresourced drop-in: restart after a crash

`uresourced` is part of Fedora, not this repo. Its user service gives apps
that are playing or recording audio a priority boost. Version 0.5.4 (Fedora
44) sometimes segfaults while reading a PipeWire node: five times between
Oct 28 and Nov 8, 2026, with the stack ending in `node_event_info` →
`strtoll`. The stock unit has no `Restart=`, so one crash leaves it stopped
until the next login. The drop-in adds `Restart=on-failure` (10-second
delay). It works around the crash but doesn't fix it.
Check: `systemctl --user show uresourced -p Restart -p NRestarts`.
Crash history: `coredumpctl list uresourced`.

## Requirements

- Bluefin DX (or another Fedora Atomic desktop) with systemd user sessions.
- **All:** `notify-send` (part of the GNOME desktop) for notifications.
- **bluefin-health:**
  - Claude Code at `~/.local/bin/claude`, signed in.
  - Homebrew at `/home/linuxbrew/.linuxbrew/bin/brew`.
  - Already on Bluefin: `rpm-ostree`, `flatpak`, `fwupdmgr`, `tailscale`,
    `upower`, `tuned-adm`.
  - Optional: `sensors` (lm_sensors) for temperatures; the section says
    "not installed" without it.
- **brew-upgrade:** Homebrew at `/home/linuxbrew/.linuxbrew/bin/brew`.
- **clean-to-delete:** nothing extra.

User timers run only while the user's systemd instance is running (that is,
while logged in), unless lingering is on (`loginctl enable-linger $USER`).

## Install

```bash
# Scripts (install -D creates the target folders)
install -Dm755 bluefin/scripts/health-check.sh    ~/ai/sysadmin/health/health-check.sh
install -Dm755 bluefin/scripts/clean-to-delete.sh ~/bin/clean-to-delete.sh

# Units
install -Dm644 -t ~/.config/systemd/user bluefin/systemd/*.service bluefin/systemd/*.timer
install -Dm644 -t ~/.config/systemd/user/uresourced.service.d bluefin/systemd/uresourced.service.d/restart.conf
systemctl --user daemon-reload
systemctl --user enable --now brew-update.timer bluefin-health.timer brew-upgrade.timer clean-to-delete.timer

# Check
systemctl --user list-timers brew-update.timer bluefin-health.timer brew-upgrade.timer clean-to-delete.timer

# System-level (needs sudo): turn off uupd's brew module. Back up the current file first.
sudo cp -a /etc/uupd/config.json /etc/uupd/config.json.bak-$(date +%F)
sudo cp bluefin/uupd/config.json /etc/uupd/config.json   # plain cp keeps the file's owner and SELinux label
uupd config-dump | grep -A2 '"brew"'                     # expect "disable": true
# Undo: sudo cp /etc/uupd/config.json.bak-<date> /etc/uupd/config.json
```

To install just one automation, copy its script (if any) and its two unit
files, then enable only that timer.

## Uninstall

```bash
systemctl --user disable --now brew-update.timer bluefin-health.timer brew-upgrade.timer clean-to-delete.timer

# Move the files to the holding folder instead of deleting them
mkdir -p ~/ai/_to_delete
mv ~/.config/systemd/user/{brew-update,bluefin-health,brew-upgrade,clean-to-delete}.{service,timer} ~/ai/_to_delete/
mv ~/ai/sysadmin/health/health-check.sh ~/bin/clean-to-delete.sh ~/ai/_to_delete/
mv ~/.config/systemd/user/uresourced.service.d ~/ai/_to_delete/uresourced.service.d-$(date +%F)
systemctl --user daemon-reload
```

Reports in `~/ai/notes/health/`, raw data in `~/ai/sysadmin/health/raw/` and
the state in `~/.local/state/clean-to-delete/` are left in place.

**If you uninstall `clean-to-delete`, nothing empties `~/ai/_to_delete`
anymore**, including the files just moved there.

## Development

`.devcontainer/` holds a dev container for editing and linting this repo.
It is for **authoring and linting only**: the scripts and units target the
Bluefin host, so don't run them, `systemctl`, `brew` or `flatpak` inside it.

What the container provides:

- **Base image** `mcr.microsoft.com/devcontainers/base:ubuntu-24.04`, pinned
  to the Ubuntu 24.04 tag so it can't move to a new release without notice.
- **ShellCheck** v0.11.0, pinned from the upstream GitHub release and checked
  against a SHA256 hash per architecture (amd64 and arm64). CI builds this
  same container and runs ShellCheck inside it.
- **Claude Code**, installed with Anthropic's native installer as the
  non-root `vscode` user, so the binary in `~/.local/bin` is user-owned and
  auto-update works.
- **VS Code extensions:** ShellCheck (`timonwong.shellcheck`) and Claude Code
  (`anthropic.claude-code`).
- **A named volume** mounted at `/home/vscode/.claude` that keeps the Claude
  Code login and settings across container rebuilds.

Requirements: Docker and the VS Code Dev Containers extension
(`ms-vscode-remote.remote-containers`). On Bluefin DX, run `ujust dx-groups`
first so your user is in the `docker` group.

Open it: in VS Code, run **Dev Containers: Reopen in Container** from the
Command Palette. After each build the container runs `shellcheck --version`
and `claude --version` to confirm both tools work.

Lint before proposing a script change:

```bash
shellcheck -S warning bluefin/scripts/*.sh
```

Commit, sign and push from the host, not the container: the GPG key isn't
available inside it.

## License

MIT. See [LICENSE](LICENSE).
