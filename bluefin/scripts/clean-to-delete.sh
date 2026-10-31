#!/usr/bin/env bash
# Daily cleanup of ~/ai/_to_delete.
#   Day 14: one-time desktop reminder per file.
#   Day 21: delete, but only if the reminder went out 7+ days earlier.
# Age = ctime (when the file arrived in the folder). mv and cp -p keep the
# old mtime, so mtime would make freshly moved files look old.
# Usage: clean-to-delete.sh [--dry-run]
set -euo pipefail
DIR="$HOME/ai/_to_delete"
STATE="$HOME/.local/state/clean-to-delete"
NOTIFIED="$STATE/notified"   # lines: <epoch-notified><TAB><path>
LOG="$STATE/deleted.log"
DRY=0; [[ "${1:-}" == --dry-run ]] && DRY=1
mkdir -p "$STATE"; touch "$NOTIFIED"
[[ -d "$DIR" ]] || exit 0
now=$(date +%s)

notified_at() { awk -F'\t' -v p="$1" '$2 == p {print $1; exit}' "$NOTIFIED"; }

# 1. Delete files 21+ days in the folder whose reminder is 7+ days old
deleted=0
while IFS= read -r -d '' f; do
  t=$(notified_at "$f")
  [[ -n "$t" ]] && (( now - t >= 7*86400 - 3600 )) || continue
  if (( DRY )); then echo "would delete: $f"; else
    printf '%s deleted %s\n' "$(date -Is)" "$f" >> "$LOG"; rm -f -- "$f"; fi
  deleted=$((deleted + 1))
done < <(find "$DIR" -mindepth 1 -type f -ctime +20 -print0)
(( DRY )) || find "$DIR" -mindepth 1 -type d -empty -delete
if (( deleted && ! DRY )); then
  notify-send -i user-trash-full "_to_delete cleanup" \
    "Deleted $deleted file(s) that were in _to_delete for 21+ days."
fi

# 2. One-time reminder for files 14+ days in the folder
new=()
while IFS= read -r -d '' f; do
  [[ -n "$(notified_at "$f")" ]] && continue
  new+=("$f")
  (( DRY )) || printf '%s\t%s\n' "$now" "$f" >> "$NOTIFIED"
done < <(find "$DIR" -mindepth 1 -type f -ctime +13 -print0)
if (( ${#new[@]} )); then
  list=$(printf '%s\n' "${new[@]##*/}" | head -10)
  if (( DRY )); then printf 'would remind:\n%s\n' "$list"; else
    notify-send -u critical -i user-trash "_to_delete: review within 7 days" \
      "${#new[@]} file(s) will be deleted in about 7 days:
$list"; fi
fi

# 3. Forget reminders for files that no longer exist
if (( ! DRY )); then
  awk -F'\t' 'system("test -e \"" $2 "\"") == 0' "$NOTIFIED" > "$NOTIFIED.tmp"
  mv "$NOTIFIED.tmp" "$NOTIFIED"
fi
exit 0
