#!/usr/bin/env bash
# Bluefin nightly health check (READ-ONLY).
# Collects system facts, then asks Claude Code (headless, no tools) to write a short report.
# Install location: ~/ai/sysadmin/health/health-check.sh
# Run by:           ~/.config/systemd/user/bluefin-health.timer (daily 04:45, after uupd)
# Raw data:         ~/ai/sysadmin/health/raw/bluefin-YYYY-MM-DD.txt   (local only, not synced)
# Report:           ~/ai/notes/health/bluefin-YYYY-MM-DD.md           (synced via pCloud)
# Undo:             systemctl --user disable --now bluefin-health.timer

set -u
DATE=$(date +%F)
RAW_DIR="$HOME/ai/sysadmin/health/raw"
OUT_DIR="$HOME/ai/notes/health"
RAW="$RAW_DIR/bluefin-$DATE.txt"
OUT="$OUT_DIR/bluefin-$DATE.md"
TMP="$RAW_DIR/summary.tmp"   # overwritten each run; nothing is deleted
CLAUDE="$HOME/.local/bin/claude"
BREW="/home/linuxbrew/.linuxbrew/bin/brew"
mkdir -p "$RAW_DIR" "$OUT_DIR"

section() { printf '\n===== %s =====\n' "$1"; }
run() { local title="$1"; shift; section "$title"; timeout 180 "$@" 2>&1 </dev/null || echo "(exit code $?)"; }

# ---------- 1. Collect (read-only commands, no sudo) ----------
{
  echo "Bluefin health raw data - $(date)"
  run "Host and uptime"                 bash -c 'hostnamectl; echo; uptime'
  run "OS deployments (rpm-ostree)"     rpm-ostree status
  run "Disk usage"                      df -h -x tmpfs -x devtmpfs -x efivarfs -x overlay
  run "Memory and swap"                 free -h
  run "Failed system units"             systemctl --failed --no-pager
  run "Failed user units"               systemctl --user --failed --no-pager
  run "Journal errors, last 24h, grouped (count, most frequent first; digits shown as N)" bash -c 'journalctl -p 3 --since "24 hours ago" --no-pager -q -o cat | sed -E "s/[0-9]+/N/g" | sort | uniq -c | sort -rn | head -n 40'
  run "Journal errors, last 24h, total count" bash -c 'journalctl -p 3 --since "24 hours ago" --no-pager -q | wc -l'
  run "Journal errors, last 24h, newest 15 with timestamps" bash -c 'journalctl -p 3 --since "24 hours ago" --no-pager -q | tail -n 15'
  run "Recent boots (last 5)"           bash -c 'journalctl --list-boots --no-pager -q | tail -n 5'
  run "Shutdown/reboot history (clean shutdowns are logged)" bash -c 'last -x -F reboot shutdown 2>/dev/null | head -n 12'
  run "Previous boot: last 15 log lines before it ended" bash -c 'journalctl -b -1 -n 15 --no-pager -q 2>&1'
  run "Power profile (tuned-ppd; powerprofilesctl is not installed)" bash -c 'tuned-adm active; echo "firmware platform_profile: $(cat /sys/firmware/acpi/platform_profile 2>/dev/null)"'
  run "Temperatures"                    bash -c 'command -v sensors >/dev/null && sensors || echo "lm_sensors not installed"'
  run "Battery"                         bash -c 'b=$(upower -e | grep -m1 BAT); [ -n "$b" ] && upower -i "$b" || echo "no battery found"'
  run "Flatpak updates available"       flatpak remote-ls --updates
  run "Homebrew outdated"               bash -c "[ -x $BREW ] && $BREW outdated || echo 'brew not found'"
  run "Firmware updates (fwupd)"        fwupdmgr get-updates --no-unreported-check
  run "Tailscale"                       tailscale status
  run "pCloud processes (should be exactly one client)" bash -c 'ps -eo pid,etime,stat,args | grep -i "[p]cloud" || echo "NO sync client process found"'
  run "pCloud autostart entries"        bash -c 'ls -1 ~/.config/autostart 2>/dev/null | grep -i "[c]loud" || echo "none"'
  run "Top 10 processes by memory"      bash -c 'ps -eo pid,comm,%mem,%cpu --sort=-%mem | head -n 11'
  run "Claude Code version"             "$CLAUDE" --version
} > "$RAW" 2>&1

# ---------- 2. Find previous report for comparison ----------
PREV=""
for f in "$OUT_DIR"/bluefin-*.md; do
  [ -e "$f" ] || continue        # no reports yet: the glob stays unexpanded
  [ "$f" = "$OUT" ] && continue  # skip today's report
  PREV="$f"                      # glob is sorted, so the last one kept is the newest
done

PROMPT="You are a Linux systems engineer reviewing nightly health data for the owner's Bluefin DX laptop \
(Dell XPS 15 9530, Fedora Atomic / immutable, docked with lid closed, always on). \
The raw data is on stdin. Write a concise Markdown report. \
Line 1: '# Bluefin health - $DATE'. \
Line 3: 'Status: OK' or 'Status: Attention' or 'Status: Action needed', followed by one sentence. \
Then a table: Check | Result | Status. \
Then 'Action items': exact commands for the owner to run, what each does, and whether it needs sudo. \
Never suggest dnf or rpm-ostree install; use flatpak, brew or distrobox. Never suggest ujust update or rpm-ostree reset: layered packages (brave-origin-nightly, espanso) make bootc refuse and reset would remove them. For OS updates suggest rpm-ostree upgrade (uupd already falls back to it nightly). \
Flag: any filesystem above 80 percent, failed units, repeated journal errors, a staged rpm-ostree deployment waiting for reboot, \
firmware updates, battery full-charge capacity below 80 percent of design, high temperatures, Tailscale logged out or stopped, pCloud not running. \
The owner sometimes reboots on purpose (updates, maintenance). Treat a reboot as deliberate and OK when the shutdown history or the previous boot's last log lines show an orderly shutdown; \
flag a reboot only when it looks unclean (no shutdown record, crash, panic, watchdog, power loss). \
Known noise to list as Info, not Attention: SELinux denials for lsblk under bootupd_t (logged only, permissive) and chcon mac_admin under tuned_t (Fedora policy gap), \
udev 'Unknown group' lines in early boot, ACPI BIOS symbol errors, and the firewalld 'docker-forwarding' NAME_CONFLICT. \
Fans: idle fans of about 4000-4700 RPM with the lid closed are a known, still-open issue (Balanced idle baseline on Oct 27: 4274/4000 RPM, CPU 64 C, RAM 48.8/46.8 C). Report fan speeds and temperatures with the change since the last report; flag Attention only if fans or temperatures rise clearly above that baseline or RAM exceeds 52 C. \
Power mode is managed by tuned-ppd: powerprofilesctl is NOT installed, so never suggest it; to view use tuned-adm active, to change use GNOME Quick Settings > Power Mode. \
Power mode is Balanced (tuned balanced, firmware balanced). A Power Saver test on Oct 27-28 did not lower idle fan speed, so do not recommend power-profile changes; report the active profile and flag it only if it is not balanced. \
Bluetooth SCO or hands-free messages mean a headset was in call/voice mode; list them as Info unless the headset disconnects repeatedly. \
Bluefin auto-updates nightly via uupd at about 4:00-4:15 AM, before this report; a staged rpm-ostree deployment just means reboot when convenient (Info, not Attention). \
Journal errors are given as grouped counts across the full 24 hours (digits replaced by N): summarize them by count and source, and call out anything new compared with the previous report. \
Do not invent data. If a section errored or is missing, say so. Output only the report."
if [ -n "$PREV" ]; then
  PROMPT="$PROMPT A previous report follows the raw data; add a short 'Changes since last report' section."
fi

# ---------- 3. Summarize with Claude Code (no tools allowed) ----------
{
  cat "$RAW"
  if [ -n "$PREV" ]; then echo; echo "===== PREVIOUS REPORT ($(basename "$PREV")) ====="; cat "$PREV"; fi
} | timeout 600 "$CLAUDE" -p "$PROMPT" \
      --disallowedTools "Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch" \
      > "$TMP" 2>&1
RC=$?

if [ $RC -eq 0 ] && [ -s "$TMP" ]; then
  cp -f "$TMP" "$OUT"
else
  {
    echo "# Bluefin health - $DATE"
    echo
    echo "Status: Attention - the AI summary failed (exit code $RC). Raw data below."
    echo
    echo '```'
    cat "$TMP" 2>/dev/null
    echo
    cat "$RAW"
    echo '```'
  } > "$OUT"
fi

# ---------- 4. Desktop notification (harmless if no session) ----------
STATUS=$(grep -m1 -i 'status:' "$OUT" | sed 's/[*#]//g' | cut -c1-200)
command -v notify-send >/dev/null && notify-send -a "Health check" "Bluefin health $DATE" "${STATUS:-Report ready}" 2>/dev/null || true

exit 0
