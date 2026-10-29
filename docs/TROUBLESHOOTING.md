# Troubleshooting

Start with the health check and a short log slice:

```bash
~/.local/bin/howdy-lock-verify

journalctl -t pam_howdy \
           -t howdy-attempt-watch \
           -t howdy-attempt-capture \
           -t howdy-attempt-telegram \
           --since "15 min ago" -o cat
```

The lock-screen decisions are logged by the patched QML as `howdy-error`,
`howdy-locked-out`, `howdy-paused`, etc. Read the current shell log:

```bash
journalctl --user -t quickshell -t omarchy-shell --since "15 min ago" -o cat
```

## The face icon or `howdy:true` is missing

```bash
omarchy-shell lock status
~/.local/bin/howdy-lock-verify
```

The lock screen only enables face unlock when all of these are true:

| Check | Expected |
| --- | --- |
| `/etc/pam.d/omarchy-lock-howdy` | exists, root-owned, mode 0644, references `pam_howdy.so` |
| `/usr/lib/security/pam_howdy.so` | exists, root-owned, not group/world-writable |
| `/etc/howdy/models/$USER.dat` | exists, root-owned, not group/world-writable |
| `/etc/howdy/config.ini` | readable and not disabled |
| `omarchy-shell lock status` | `"faceUnlock": true, "howdy": true` |

Fix the usual suspects:

```bash
sudo ls -l /etc/pam.d/omarchy-lock-howdy \
            /usr/lib/security/pam_howdy.so \
            /etc/howdy/models/"$USER".dat

sudo howdy test
sudo howdy add          # if the model is missing

# If another tool put a partial PAM file in place:
sudo install -Dm644 pam/omarchy-lock-howdy /etc/pam.d/omarchy-lock-howdy
```

Then restart the shell:

```bash
omarchy-restart-shell
```

## "Too many face attempts" before three real scans

A real scan takes roughly one second or longer. The patched QML ignores results
that return in under one second and pauses face auth instead of counting them.
That covers a closed lid, a camera still held by another process, and PAM start
errors. Mouse/keyboard activity resumes face auth but does **not** refill the
attempt budget.

Check the shell log:

```bash
journalctl --user -t quickshell -t omarchy-shell --since "10 min ago" -o cat |
  grep -E 'howdy-(error|locked-out|paused|attempt|enabled)'
```

Expected on a normal third failure:

```text
howdy-locked-out: attempts=3
```

If `attempts` is less than 3:

- Confirm the live QML contains the fixes:
  ```bash
  grep -nE 'howdyAttemptStartedAt|maxFaceAttempts|elapsed < 1000|onError' \
    ~/.config/omarchy/plugins/grantabell.lock-fingerprint-on-enter/Service.qml
  ```
- Reapply the patch only after restoring the QML from git; the patcher refuses
  to apply over a partial/older patch. See [Plugin updates](#plugin-updates).
- If the lid is closed, `pam_howdy` logs `Face verification skipped: lid is
  closed`. Face unlock cannot work in that state. Use password or fingerprint.

## No photo after three failures

1. Is the watcher running?
   ```bash
   systemctl --user status howdy-attempt-capture.service
   systemctl --user is-active howdy-attempt-capture.service
   ```
2. Can the user read the journal?
   ```bash
   journalctl -n0 >/dev/null && echo readable
   ```
   If not, add yourself to `systemd-journal` and re-login:
   ```bash
   sudo usermod -aG systemd-journal "$USER"
   ```
3. Did `pam_howdy` log three failures for the lock service?
   ```bash
   journalctl -t pam_howdy --since "10 min ago" -o cat |
     grep 'omarchy-lock-howdy'
   ```
   Lines for `sudo` or polkit are intentionally ignored.
4. Test the capture helper directly:
   ```bash
   HOWDY_ATTEMPT_PHOTO_DIR=/tmp/lock-test \
     ~/.local/bin/howdy-attempt-capture
   ls -l /tmp/lock-test
   ```
   This opens the IR camera. Close the lock screen first; Howdy and the capture
   cannot use the same device at the same time.
5. If `ffmpeg` fails, check the camera path and formats:
   ```bash
   grep -A2 '^\[video\]' /etc/howdy/config.ini
   v4l2-ctl --list-devices
   v4l2-ctl -d /dev/videoN --list-formats-ext
   ```
   Look for a node that advertises only `GREY`. Set it with:
   ```bash
   sudo howdy config
   # or:
   sudo howdy set device_path /dev/v4l/by-id/usb-...
   ```
   Then restart the watcher:
   ```bash
   systemctl --user restart howdy-attempt-capture.service
   ```
6. Check permissions:
   ```bash
   stat -c '%a %U:%G %n' ~/Pictures/lock-attempts ~/Pictures/lock-attempts/*.jpg
   ```
   Files should be `600`; the directory should be `700`.

The capture is triggered only after the **third** failure, not the second, so a
test with two failures correctly produces no new photo.

## Telegram does not deliver

Check the sender log and rerun setup:

```bash
journalctl -t howdy-attempt-telegram --since "15 min ago" -o cat
~/.local/bin/howdy-attempt-telegram-setup
```

The setup sends a test message and writes
`~/.config/howdy-attempt-capture/telegram.env` with mode `0600`. It hides the
token while typing. Common causes:

- **Bot token wrong or revoked.** Create a new token with @BotFather and rerun.
- **No chat started.** Open the bot in Telegram, press Start, send a message,
  then rerun setup so it can find the latest chat ID.
- **Wrong chat ID.** Numeric IDs for private chats; `@channelusername` for a
  channel where the bot is an administrator.
- **`Connection timed out` / TLS timeout.** The DNS answer for
  `api.telegram.org` may be blackholed. The setup tries
  `TELEGRAM_API_IP=149.154.167.220`. If that address is also blocked, use your
  own VPN/proxy; do not send a token through a public third-party relay.
- **Photo exists but no message.** Test the sender directly:
  ```bash
  ~/.local/bin/howdy-attempt-telegram /path/to/photo.jpg
  ```
- **Telegram disabled on purpose.** Check for a renamed file:
  ```bash
  ls -l ~/.config/howdy-attempt-capture/telegram.env*
  ```

Photos are still saved locally when Telegram is disabled or fails.

## Face unlock is slow or unreliable

- Run `sudo howdy test` and watch the IR camera. The face must be visible in
  the dark/IR frame, not just lit by the screen.
- `abort_if_lid_closed = true` is intentional. Face unlock pauses when the lid
  is closed.
- The Howdy config is tuned only for `device_path`, `timeout = 4`, and
  `abort_if_lid_closed`. If recognition is poor, tune Howdy itself, not the
  capture scripts:
  ```bash
  sudo howdy config
  ```
- Some IR cameras need an emitter helper from the AUR:
  ```bash
  yay -S linux-enable-ir-emitter
  ```
  This project does not install or configure it automatically.
- A successful password/fingerprint unlock resets the face budget for the next
  lock session. The watcher's failure counter resets on unlock.

## Fingerprint problems after resume

The patched lock screen keeps the GrantAbell plugin's behaviour: fingerprint
does not auto-restart forever on timeout, and there is a short retry for
fprintd's `Cannot run while suspended` error after resume.

- Wait two or three seconds after wake.
- Press Enter with an empty password field to reactivate the reader.
- Check fprintd:
  ```bash
  fprintd-verify
  systemctl status fprintd
  ```
- The dedicated PAM files are independent:
  ```bash
  cat /etc/pam.d/omarchy-lock-fingerprint
  cat /etc/pam.d/omarchy-lock-howdy
  ```

## Plugin updates

`omarchy plugin update grantabell.lock-fingerprint-on-enter` refuses to update
while `Service.qml` is modified. That is intentional. To update deliberately:

```bash
cd ~/.config/omarchy/plugins/grantabell.lock-fingerprint-on-enter
git checkout -- Service.qml
omarchy plugin update grantabell.lock-fingerprint-on-enter
~/.local/bin/grantabell-howdy-patch
omarchy-restart-shell
```

The patcher is idempotent and all-or-nothing. If an upstream anchor changed, it
prints which patch did not match and leaves the file untouched. Restore from
git and either update the patch or stay on the tested commit `e887095`.

## Shell/PAM debugging

```bash
# What does the lock screen think is available?
omarchy-shell lock status | jq .

# Recent PAM lines, including failures and skips
journalctl -t pam_howdy --since "30 min ago" -o cat

# Watcher and capture, including command failures
journalctl --user -u howdy-attempt-capture.service --since "30 min ago" -o cat

# Check the service file that is actually installed
systemctl --user cat howdy-attempt-capture.service
```

If the lock screen hangs after a bad patch, restore the QML:

```bash
cd ~/.config/omarchy/plugins/grantabell.lock-fingerprint-on-enter
git checkout -- Service.qml
omarchy-restart-shell
```

The installer's pre-patch backup is under
`~/.local/state/howdy-face-unlock/backups/`.
