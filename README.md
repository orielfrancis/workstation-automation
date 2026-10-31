# Workstation automation (Bluefin DX)

Scripts and systemd user units that keep my Bluefin DX workstation
(Fedora Atomic / Universal Blue) healthy. Everything runs as my user: no root,
nothing installed into the immutable OS image.

```
bluefin/
├── scripts/
│   ├── health-check.sh       nightly read-only health report
│   └── clean-to-delete.sh    reminder + cleanup for ~/ai/_to_delete
└── systemd/
    ├── bluefin-health.service / .timer
    ├── brew-upgrade.service   / .timer
    └── clean-to-delete.service / .timer
```

## Automations

| Timer | Schedule | What it does |
|---|---|---|
| `bluefin-health.timer` | Daily 04:45 | Read-only health report |
| `brew-upgrade.timer` | Sundays 05:15 | `brew upgrade --formula` |
| `clean-to-delete.timer` | Daily 10:00 | Reminds about, then deletes, old files in `~/ai/_to_delete` |

All three timers use `Persistent=true`: a run missed because the machine was
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
   Saved to `~/ai/sysadmin/health/raw/bluefin-YYYY-MM-DD.txt` (local only).
2. **Summarize.** Sends the raw data, plus the previous report for comparison,
   to Claude Code in headless mode (`claude -p`) with no write tools (Bash,
   Edit, Write, NotebookEdit, WebFetch and WebSearch are blocked). The prompt
   lists the known harmless noise and sets the "Attention" thresholds.
3. **Write.** Saves the report to `~/ai/notes/health/bluefin-YYYY-MM-DD.md`.
   If the AI step fails, it writes a fallback report that holds the raw data
   and is marked `Status: Attention`.
4. **Notify.** Sends a desktop notification with the status line.

Service limits: `Nice=10`, 20-minute timeout.
Run it now: `systemctl --user start bluefin-health.service`

### brew-upgrade: weekly Homebrew upgrade

`uupd` only runs `brew update` (it refreshes the package list); this timer
runs `brew upgrade --formula` to actually install new versions of formulae.
Casks are skipped: the 1Password cask (`ublue-os/tap/1password-gui-linux`)
needs sudo to upgrade, so an unattended run would fail. Upgrade casks
manually with `brew upgrade --cask <name>`.
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
systemctl --user daemon-reload
systemctl --user enable --now bluefin-health.timer brew-upgrade.timer clean-to-delete.timer

# Check
systemctl --user list-timers bluefin-health.timer brew-upgrade.timer clean-to-delete.timer
```

To install just one automation, copy its script (if any) and its two unit
files, then enable only that timer.

## Uninstall

```bash
systemctl --user disable --now bluefin-health.timer brew-upgrade.timer clean-to-delete.timer

# Move the files to the holding folder instead of deleting them
mkdir -p ~/ai/_to_delete
mv ~/.config/systemd/user/{bluefin-health,brew-upgrade,clean-to-delete}.{service,timer} ~/ai/_to_delete/
mv ~/ai/sysadmin/health/health-check.sh ~/bin/clean-to-delete.sh ~/ai/_to_delete/
systemctl --user daemon-reload
```

Reports in `~/ai/notes/health/`, raw data in `~/ai/sysadmin/health/raw/` and
the state in `~/.local/state/clean-to-delete/` are left in place.

**If you uninstall `clean-to-delete`, nothing empties `~/ai/_to_delete`
anymore**, including the files just moved there.

## License

MIT. See [LICENSE](LICENSE).
