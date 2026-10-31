# Authentication: lid-aware fingerprint and YubiKey `sudo`

Unlike the rest of this repo, this part changes **system** files (PAM, under
`/etc` and `/usr/local`). It is not automated: these are the steps used to set
it up by hand, kept here so they can be repeated, checked and undone. Nothing
is layered into the OS image.

Proven on Bluefin DX (Fedora 44 base, GNOME) on a laptop that is usually
docked with the lid closed. Every machine differs, so run Part 0 first.

Goals:
- **Lid closed (docked):** no fingerprint wait. `sudo` and graphical prompts
  go straight to a YubiKey tap or the password.
- **Lid open:** the fingerprint still works.
- **YubiKey tap** works for `sudo` and graphical admin (polkit) prompts
  **only**, not the login or lock screen (see C4b for why). The password
  always remains the fallback.

Final authentication order:
- `sudo` and polkit (`system-auth`): lid check → fingerprint (lid open only)
  → YubiKey tap → password
- Login and lock screen (GNOME, `password-auth`): **password**, with the
  fingerprint offered alongside when the lid is open. **No YubiKey.**
- **First login after every reboot: use the password.** A tap or fingerprint
  login leaves the GNOME login keyring locked (see C4b).

Files involved:

| File | Where it comes from |
|---|---|
| `/usr/local/bin/lid-is-open` | [`bluefin/scripts/lid-is-open.sh`](../scripts/lid-is-open.sh) |
| `/etc/authselect/custom/lid-aware-fp/` | Custom authselect profile (B3, B4, C4b) |
| `~/.config/Yubico/u2f_keys` | YubiKey registrations (C2, C3). **Never commit.** |

---

## Part 0: Pre-flight checks (read-only; run on every new machine)

Shell notes for Bluefin-style setups:
- `cat` may be aliased to `bat`, `grep` to `ugrep`, and `ls` to `eza`.
- Use `\cat`, `command grep` and `\ls` for plain output that copies cleanly.
- Use `grep -F` for literal patterns.

```bash
echo "== OS =="; rpm-ostree status --booted | head -5
echo "== authselect =="; authselect current
echo "== sudo/polkit PAM =="; \cat /etc/pam.d/sudo; \cat /etc/pam.d/polkit-1 2>/dev/null || \cat /usr/lib/pam.d/polkit-1
echo "== auth lines =="; command grep -n '^auth' /etc/pam.d/system-auth
echo "== lid sensor =="; \cat /proc/acpi/button/lid/*/state
echo "== u2f packages =="; rpm -q pam-u2f pamu2fcfg
echo "== sudo vs run0 =="; command -v sudo; command -v run0
```

What to confirm before continuing:

| Check | Bluefin result | If it's different |
|---|---|---|
| `authselect current` | `sssd` + `with-fingerprint`, `with-mdns4`, `with-silent-lastlog` | Note the **profile ID** and **every feature**. You'll base the custom profile on them. |
| `sudo` / `polkit-1` | Both `auth include system-auth` | If not, the change must go into whatever file they include |
| `auth` lines | `pam_fprintd.so sufficient`, with no jumps (`[...=N]`) **above** it | If jump lines sit above the fingerprint line, recount before inserting anything |
| Lid sensor | `state: closed` or `open` | If there's no lid path, the script allows fingerprint (exit 0), so the change is harmless |
| `pam-u2f` / `pamu2fcfg` | Installed in the image | If missing, don't layer. Look for a distro-native option first. |

---

## Part B: Lid-aware fingerprint (custom authselect profile + `pam_exec`)

**Design:**
- A tiny script exits 0 only when the lid is **open**.
- A new PAM line just before `pam_fprintd.so`:
  `[success=ignore default=1] pam_exec.so quiet /usr/local/bin/lid-is-open`
  - Lid open: carry on to the fingerprint step.
  - Lid closed, or any error: skip exactly 1 line, the fingerprint step.
- **Fail-safe:** if the check breaks, you just get the password prompt. In
  PAM, a jump during authentication skips lines without recording a failure.
- One change covers both `sudo` and polkit, because both include `system-auth`.
- The script is POSIX `sh` using only shell built-ins, because PAM runs it
  with a minimal environment.

Interim workaround (no changes): in terminal `sudo`, press **Ctrl+C** at
"Place your finger…" to go straight to the password prompt.

### B1. Safety net: open a root shell and keep it open until done
In a **second terminal**: `sudo -i`, then `whoami` should print `root`.
Don't use it unless something breaks.

### B2. Install the lid-check script (from the repo root)
```bash
sudo install -m0755 bluefin/scripts/lid-is-open.sh /usr/local/bin/lid-is-open
sudo restorecon -v /usr/local/bin/lid-is-open
\ls -lZ /usr/local/bin/lid-is-open        # expect root root … bin_t
/usr/local/bin/lid-is-open; echo "exit=$?" # lid closed → exit=1, open → exit=0
```

### B3. Create the custom profile (not active yet)
Use the **base profile from `authselect current`**: `sssd` on Bluefin,
possibly `local` elsewhere.
```bash
sudo authselect create-profile lid-aware-fp -b sssd --symlink-meta --symlink-nsswitch --symlink-dconf
\ls -l /etc/authselect/custom/lid-aware-fp/
command grep -n 'pam_fprintd' /etc/authselect/custom/lid-aware-fp/system-auth   # expect exactly ONE auth line
```
If an option is rejected, run it again without `--symlink-dconf`.

### B4. Insert the lid-check line (keep the original copy)
```bash
F=/etc/authselect/custom/lid-aware-fp/system-auth
sudo cp -a "$F" "$F.orig"
sudo sed -i '/^auth.*pam_fprintd\.so/i auth        [success=ignore default=1]                   pam_exec.so quiet /usr/local/bin/lid-is-open           {include if "with-fingerprint"}' "$F"
sudo restorecon -v "$F" "$F.orig"
command grep -n -B1 -A1 'pam_fprintd' "$F"
diff "$F.orig" "$F"        # must show exactly ONE added line
```

### B5. Dress rehearsal (writes nothing)
List **all your current features**:
```bash
sudo authselect test -s custom/lid-aware-fp with-fingerprint with-mdns4 with-silent-lastlog | command grep -n '^auth'
```
**Expect:** the original `auth` lines, plus the `pam_exec … lid-is-open` line
directly above `pam_fprintd.so`.

### B6. Switch to the new profile, with a named backup
```bash
sudo authselect select custom/lid-aware-fp with-fingerprint with-mdns4 with-silent-lastlog --backup=pre-lid-aware-fp
authselect current
authselect backup-list
command grep -n '^auth' /etc/pam.d/system-auth
```
- If it refuses because the configuration was modified outside authselect,
  **stop** and investigate. Don't use `--force` blindly.
- A note about SSSD being configured is informational.

### B7. Tests (lid closed)
| Test | Command | Expect |
|---|---|---|
| No fingerprint wait | `sudo -k; sudo true; echo "exit=$?"` | Password prompt immediately → `exit=0` |
| Wrong password rejected | Same; type a wrong password first | `Sorry, try again.`, then `exit=0` with the right one |
| Graphical prompt | `pkexec true; echo "exit=$?"` | Password field ready immediately → `exit=0` |
| Real-world | Any app that unlocks with system authentication | Password asked right away |
| Lid open (later) | `sudo -k; sudo true` | "Place your finger…" appears |

### B8. Rollback (one command; run from the root shell if `sudo` is broken)
```bash
authselect backup-restore pre-lid-aware-fp      # or: authselect select sssd <your features>
```
If Part C is also in place, undo it first (C4b, then C4), in reverse order.

---

## Part C: YubiKey tap for `sudo` and polkit prompts (`pam_u2f`), not the login or lock screen

The `sssd` template already contains
`auth sufficient pam_u2f.so cue {include if "with-pam-u2f"}` **right after**
the fingerprint line in `system-auth`. So turning on the feature in the custom
profile gives:

> lid check → fingerprint → YubiKey → password

**Why you can't be locked out:** the YubiKey line is `sufficient`. A missing
key or a failed tap is ignored, and PAM moves on to your password. (On
Bluefin, `nouserok` doesn't appear in the rendered line, so `sufficient` is
what provides the fallback.)

**Important:** turning on `with-pam-u2f` **also** adds the YubiKey to
`password-auth`, the login and lock screens. **Do Step C4b straight after C4**
to take it back out. Why:
- A tap login never types your password, so the **GNOME login keyring stays
  locked**. You get an "Unlock Login Keyring" prompt, and GNOME Online
  Accounts and password managers' system unlock fail until you unlock it.
- At the login screen the key is asked first, and the password field only
  becomes available after a timeout, or if you unplug the key.
- A key that **stays plugged into the laptop** would let anyone holding the
  laptop unlock the lock screen with one tap.

Keep the root shell open while you do this.

### C1. Detect the key
```bash
lsusb | grep -i -F yubico
```

### C2. Register the primary key (no `sudo`)
```bash
mkdir -p ~/.config/Yubico
pamu2fcfg > ~/.config/Yubico/u2f_keys      # enter the FIDO2 PIN if set; touch the key when it blinks
chmod 600 ~/.config/Yubico/u2f_keys
restorecon -Rv ~/.config/Yubico
cut -d: -f1 ~/.config/Yubico/u2f_keys                                  # expect your username
awk -F: '{print NF-1 " key(s) registered"}' ~/.config/Yubico/u2f_keys  # expect 1
```
- The file holds **public** key data and key references only. Still, never
  commit it or paste it anywhere. The repo's `.gitignore` blocks `u2f_keys`
  as a safeguard.
- Registrations are tied to the machine's **hostname**. Re-register if the
  hostname changes.

### C3. Register a backup key (unplug the primary first)
```bash
pamu2fcfg -n >> ~/.config/Yubico/u2f_keys   # -n = no username; >> APPENDS (never >)
awk -F: '{print NF-1 " key(s) registered"}' ~/.config/Yubico/u2f_keys  # expect 2
```

### C4. Turn on the feature
```bash
sudo authselect enable-feature with-pam-u2f
authselect current
command grep -n '^auth' /etc/pam.d/system-auth      # pam_u2f.so cue right after pam_fprintd.so
command grep -n '^auth' /etc/pam.d/password-auth    # lock/login screen: pam_u2f.so cue too (removed in C4b)
```

**Rollback:** `sudo authselect disable-feature with-pam-u2f`. This returns you
to the Part B state.

### C4b. Take the YubiKey back out of the login and lock screens
Remove the two `pam_u2f` lines from the custom profile's `password-auth`
template, keeping the original copy, then apply with a named backup.
`system-auth` (`sudo`, polkit) keeps the YubiKey.
```bash
F=/etc/authselect/custom/lid-aware-fp/password-auth
command grep -n -F 'pam_u2f' "$F"         # expect exactly TWO auth lines
sudo cp -a "$F" "$F.orig"
sudo sed -i '/^auth.*pam_u2f\.so/d' "$F"
sudo restorecon -v "$F" "$F.orig"
diff "$F.orig" "$F"                       # must show exactly the TWO pam_u2f lines removed
```
Dress rehearsal (writes nothing):
```bash
sudo authselect test -p custom/lid-aware-fp with-fingerprint with-mdns4 with-silent-lastlog with-pam-u2f | command grep -n '^auth'
```
**Expect:** no `pam_u2f` line. Then apply:
```bash
sudo authselect apply-changes --backup=pre-login-no-u2f
authselect current                                     # with-pam-u2f still enabled
authselect backup-list                                 # pre-login-no-u2f listed
command grep -n -F 'pam_u2f' /etc/pam.d/password-auth  # expect nothing
command grep -n -F 'pam_u2f' /etc/pam.d/system-auth    # expect pam_u2f.so cue
```

**Rollback:** restore the template and re-apply:
```bash
sudo cp -a /etc/authselect/custom/lid-aware-fp/password-auth.orig /etc/authselect/custom/lid-aware-fp/password-auth
sudo authselect apply-changes
```
(`authselect backup-restore pre-login-no-u2f` restores only the generated
`/etc/pam.d` files. The edited template would come back on the next
`apply-changes`.)

### C5. Tests (after C4b)
| Test | Expect |
|---|---|
| `sudo -k; sudo true; echo "exit=$?"` with the key plugged in | `Please touch the FIDO authenticator.` → tap → `exit=0` |
| Same, with the key **unplugged** | Password prompt immediately → `exit=0` |
| Same, with **only the backup key** plugged in | Tap → `exit=0` (proves the backup registration) |
| `pkexec true` | Tap prompt → `exit=0` |
| Lock screen (Super+L), key plugged in | Password field ready immediately; the key does **not** blink and a tap does nothing |
| Log out and log in with the password | No "Unlock Login Keyring" prompt |
| To use the password at `sudo` while the key is plugged in | Press Ctrl+C at the tap prompt |

### C6. Stop accidental OTP strings (if you don't use Yubico OTP)
- **Symptom:** touching the key with no prompt types a long `cccccb…` string,
  followed by Enter.
- **Fix (reversible):** turn off the **Yubico OTP application**. Don't delete
  the slot; the factory credential can't be restored.
- **YubiKey 5 series, in the Yubico Authenticator app:**
  1. Open the key menu → **Toggle applications**.
  2. Uncheck **Yubico OTP** under **USB** and **NFC**.
  3. Click **Save**.
- **Command-line alternative:** `ykman config usb --disable OTP`. Undo with
  `--enable OTP`.
- **YubiKey 4 series** (can't toggle individual applications):
  `ykman config mode FIDO+CCID`, with only that key plugged in.
- **Verify:** touching the key with no prompt types nothing, and the `sudo`
  tap still works.

---

## Part D: Maintenance

- **After major OS upgrades** (e.g., Fedora 45): run `authselect check`. Then
  compare the custom templates' original copies with the vendor's, because a
  custom profile doesn't pick up template changes:
  ```bash
  diff /usr/share/authselect/vendor/sssd/system-auth   /etc/authselect/custom/lid-aware-fp/system-auth.orig
  diff /usr/share/authselect/vendor/sssd/password-auth /etc/authselect/custom/lid-aware-fp/password-auth.orig
  ```
  If a vendor file changed, recreate the profile (B3–B6), re-enable
  `with-pam-u2f` (C4) and redo C4b.
- **After changing the script in the repo:** re-run B2 and check that the
  installed copy matches:
  `cmp bluefin/scripts/lid-is-open.sh /usr/local/bin/lid-is-open && echo identical`
- **Files to back up or record:** `/usr/local/bin/lid-is-open` (source in this
  repo) and `/etc/authselect/custom/lid-aware-fp/`. **Not** `u2f_keys` in git.
