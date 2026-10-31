#!/bin/sh
# lid-is-open: exit 0 if the laptop lid is open (or no lid sensor exists), else exit 1.
# Used by PAM (pam_exec) to skip fingerprint auth when the lid is closed (docked).
# Uses only shell built-ins: PAM runs it with a minimal environment.
for f in /proc/acpi/button/lid/*/state; do
  [ -r "$f" ] || exit 0              # no lid sensor: allow fingerprint
  read -r _ state < "$f"             # file reads like: "state:      open"
  [ "$state" = "open" ] && exit 0
done
exit 1
