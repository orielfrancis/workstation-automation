#!/usr/bin/env bash
# Weekly / monthly briefs (READ-ONLY apart from its own output).
# Collects short facts from health reports, session notes and git history,
# then asks Claude Code (headless, no tools) for a SHORT brief: a heading and
# one or two sentences per item.
#
# Usage:            brief.sh weekly | monthly   [--out DIR]   (--out is for testing)
# Install location: ~/ai/sysadmin/briefs/brief.sh
# Run by:           brief-weekly.timer (Sun 18:00) and brief-monthly.timer (1st, 09:00),
#                   both via brief@.service
# Output:           ~/ai/notes/briefs/  (pCloud-synced; mirrored into the AI-Vault)
#                   + a copy in ~/Documents/syncshared/ai-notes/briefs/ (Syncthing)
# Weekly window:    the last full Sunday-Saturday week.  Monthly: the previous calendar month.

set -u
MODE="${1:-}"
OUT_DIR="$HOME/ai/notes/briefs"
COPY_DIR="$HOME/Documents/syncshared/ai-notes/briefs"
if [ "${2:-}" = "--out" ] && [ -n "${3:-}" ]; then OUT_DIR="$3"; COPY_DIR=""; fi
NOTES="$HOME/ai/notes"
VAULT_SESSIONS="$HOME/Documents/AI-Vault/40-Sessions"
DEV="$HOME/dev"
CLAUDE="$HOME/.local/bin/claude"
mkdir -p "$OUT_DIR"

case "$MODE" in
  weekly)
    END=$(date -d 'last saturday' +%F)        # on Sunday: yesterday
    START=$(date -d "$END -6 days" +%F)
    LABEL="$(date -d "$START" '+%b %-d') – $(date -d "$END" '+%b %-d, %Y')"
    OUT="$OUT_DIR/weekly-$START.md"
    TITLE="# Weekly brief: $LABEL"
    LIMIT="at most 8 items"
    ;;
  monthly)
    START=$(date -d "$(date +%Y-%m-01) -1 month" +%F)
    END=$(date -d "$(date +%Y-%m-01) -1 day" +%F)
    LABEL="$(date -d "$START" '+%B %Y')"
    OUT="$OUT_DIR/monthly-$(date -d "$START" +%Y-%m).md"
    TITLE="# Monthly brief: $LABEL"
    LIMIT="at most 10 items"
    ;;
  *) echo "usage: $0 weekly|monthly [--out DIR]" >&2; exit 2 ;;
esac
SINCE="$START 00:00"; UNTIL="$END 23:59:59"
TMP="$OUT_DIR/.brief.tmp"

in_window() {  # file modified inside the window?
  local m; m=$(date -r "$1" +%F); [[ "$m" > "$START" || "$m" == "$START" ]] && [[ "$m" < "$END" || "$m" == "$END" ]]
}

# ---------- 1. Collect (read-only) ----------
{
  echo "Window: $START to $END ($MODE)"

  echo; echo "===== HEALTH REPORTS (status line per day) ====="
  for f in "$NOTES"/health/bluefin-*.md "$NOTES"/health/mac-*.md; do
    [ -e "$f" ] || continue
    d=$(basename "$f" .md | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
    [[ "$d" < "$START" || "$d" > "$END" ]] && continue
    printf '%s %s: %s\n' "$(basename "$f" | cut -d- -f1)" "$d" "$(grep -m1 -i '^status:' "$f" | cut -c1-300)"
  done

  echo; echo "===== HEALTH: 'Changes since last report' sections (trimmed) ====="
  for f in "$NOTES"/health/bluefin-*.md "$NOTES"/health/mac-*.md; do
    [ -e "$f" ] || continue
    d=$(basename "$f" .md | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
    [[ "$d" < "$START" || "$d" > "$END" ]] && continue
    echo "--- $(basename "$f")"
    sed -n '/^## Changes since last report/,/^## /p' "$f" | grep -E '^\s*[-*]' | cut -c1-220 | head -n 8
  done

  echo; echo "===== SESSION NOTES / RUNBOOKS created or changed (title + headings) ====="
  for f in "$NOTES"/*.md "$VAULT_SESSIONS"/*.md; do
    [ -e "$f" ] || continue
    case "$(basename "$f")" in README.md) continue ;; esac
    in_window "$f" || continue
    echo "--- $(basename "$f") (modified $(date -r "$f" +%F))"
    grep -E '^#{1,3} ' "$f" | cut -c1-120 | head -n 15
  done

  echo; echo "===== GIT: commits and merged PRs in ~/dev repos ====="
  for r in "$DEV"/*/; do
    [ -d "$r/.git" ] || continue
    log=$(git -C "$r" log --all --since="$SINCE" --until="$UNTIL" --no-merges --format='%cs %s' 2>/dev/null | head -n 30)
    [ -n "$log" ] && { echo "--- $(basename "$r")"; echo "$log"; }
  done

  if [ "$MODE" = monthly ]; then
    echo; echo "===== WEEKLY BRIEFS that overlap this month ====="
    for f in "$OUT_DIR"/weekly-*.md; do
      [ -e "$f" ] || continue
      ws=$(basename "$f" .md); ws=${ws#weekly-}
      we=$(date -d "$ws +6 days" +%F)
      [[ "$we" < "$START" || "$ws" > "$END" ]] && continue
      echo "--- $(basename "$f")"; cat "$f"
    done
  fi
} > "$TMP.in" 2>&1

# ---------- 2. Summarize with Claude Code (no tools allowed) ----------
PROMPT="You write SHORT $MODE briefs for the owner, an experienced sysadmin, who will glance back months later to remember what happened on the machines (Bluefin DX laptop, Mac Mini) and in the AI setup. \
The input is collected facts for $START to $END: health-report status lines and changes, titles and headings of session notes and runbooks created or changed, and git commit subjects. \
Output Markdown only, in this exact shape: \
Line 1: '$TITLE'. Blank line. \
'**Health:**' followed by ONE sentence: how many days were OK vs Attention for each machine, and the main recurring theme. \
Then '## Fixes and troubleshooting', '## Changes and setup', '## Still open'. Under each, items as '### <short heading>' followed by ONE or TWO plain sentences. No bullet lists inside items, no commands, no deep detail. \
Use $LIMIT in total; merge related items; skip routine noise (daily OK reports, version bumps of tools, harmless known warnings). If a section has nothing, write 'Nothing notable.' \
'Still open' lists only unresolved items that the facts show are still open at the end of the period (max 4). \
Use only the facts given; do not invent. Plain English, short sentences."
if [ "$MODE" = monthly ]; then
  PROMPT="$PROMPT For the monthly brief, rely mainly on the weekly briefs when present, and keep only the month's key issues, break-fixes and configuration changes."
fi

timeout 600 "$CLAUDE" -p "$PROMPT" \
    --disallowedTools "Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch" \
    < "$TMP.in" > "$TMP" 2>&1
RC=$?

if [ $RC -eq 0 ] && [ -s "$TMP" ]; then
  cp -f "$TMP" "$OUT"
else
  { echo "$TITLE"; echo; echo "The AI summary failed (exit code $RC). Collected facts below."; echo; echo '```'; cat "$TMP" "$TMP.in" 2>/dev/null; echo '```'; } > "$OUT"
fi
[ -n "$COPY_DIR" ] && { mkdir -p "$COPY_DIR"; cp -f "$OUT" "$COPY_DIR/"; }

# ---------- 3. Desktop notification (harmless if no session) ----------
ITEMS=$(grep -c '^### ' "$OUT")
command -v notify-send >/dev/null && notify-send -a "Briefs" "${MODE^} brief ready: $LABEL" \
  "$ITEMS items. Open: $OUT" 2>/dev/null || true
exit 0
