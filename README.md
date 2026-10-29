# Omarchy Face Unlock Capture

Three-attempt Howdy face unlock for the [GrantAbell fingerprint lock screen][grantabell], with an infrared photo after the final failed attempt and optional Telegram delivery.

> **Not an official Omarchy project.** It patches a user-owned lock-screen plugin and installs a dedicated PAM service. Read [Privacy and security](#privacy-and-security) before using the photo feature.

## Features

- **Howdy face unlock on the GrantAbell lock screen** — the stock `omarchy.lock` stays untouched.
- **Three real face attempts per lock** — after the third failed scan the lock screen falls back to password/fingerprint.
- **Quick PAM errors do not burn attempts** — a closed lid, a busy camera or a PAM-level error pauses face auth instead of consuming the budget.
- **One IR frame after the last failure** — the capture runs only after Howdy has stopped retrying, so it cannot steal the third attempt from the shared IR camera.
- **Optional Telegram delivery** — a bot sends the frame with a hostname/timestamp caption. Without Telegram the photo stays local.
- **Bounded local retention** — newest 100 JPEGs under `~/Pictures/lock-attempts/`, files mode `0600`, directory `0700`.
- **Runtime switches** — disable face unlock with a marker file; disable Telegram by renaming one config file; disable capture with systemd.
- **Installer and uninstaller** — detects the IR camera, configures Howdy, patches the lock plugin, and verifies the result.

## How it works

```text
Omarchy shell
└── grantabell.lock-fingerprint-on-enter (patched Service.qml)
    ├── PamContext "omarchy-lock-howdy" ──> pam_howdy.so ──> IR camera
    │   └── after 3 real failures: "Too many face attempts" + journal lines
    └── fingerprint / password paths unchanged

howdy-attempt-capture.service (systemd --user)
└── howdy-attempt-watch
    └── tails the journal for pam_howdy(omarchy-lock-howdy:auth) failures
        └── after the 3rd failure: howdy-attempt-capture
            ├── ffmpeg one GREY frame from the Howdy camera
            ├── chmod 600, rotate to newest 100
            └── howdy-attempt-telegram (optional)
```

The lock screen counts a delay of at least one second as a real scan. Results that come back almost immediately (closed lid, camera busy, PAM start failure) are treated as "not a face attempt": face auth pauses until the next mouse/keyboard activity.

The watcher uses the same three-failure window as the lock screen. The photo trigger is deliberately placed after the **final** failure, not the second one, because Howdy and the capture use the same IR device.

## Requirements

| Component | Notes |
| --- | --- |
| Omarchy 4 / Quattro | Uses `omarchy`, `omarchy-shell`, Quickshell PAM contexts and systemd user services. |
| [GrantAbell lock plugin][grantabell] | The installer adds and enables it if missing. Tested with commit `e887095`. |
| Howdy | `pam_howdy.so` plus an enrolled face. Tested with `howdy-next 3.4.2`; `howdy-git` should work if its journal lines match. |
| IR camera | A V4L2 node that advertises only the `GREY` pixel format. The installer prefers a stable `/dev/v4l/by-id/` path. |
| `fprintd` | Baseline for the GrantAbell fingerprint lock screen. |
| `ffmpeg`, `v4l-utils`, `jq`, `curl`, `python3` | Capture, camera detection, Telegram and patching. |
| Telegram bot | Optional. Requires a bot token and a chat ID. |

Face unlock only works with the lid **open** on a laptop: the IR camera is physically in the lid. Howdy is configured with `abort_if_lid_closed = true`.

## Install

Run as your normal user. The installer asks for `sudo` only for system files:

```bash
git clone https://github.com/mumunikita/omarchy-face-unlock-capture.git
cd omarchy-face-unlock-capture
./install.sh
```

Options:

```text
-y, --yes          accept safe defaults (does not configure Telegram)
    --skip-deps    do not install packages or Howdy
    --force-pam    replace an existing non-Howdy PAM service
    --telegram     run the interactive Telegram setup
    --no-telegram  never ask about Telegram
    --enroll       run `sudo howdy add` if the face model is missing
    --no-enroll    never enroll a face
    --no-restart   do not restart the Omarchy shell
```

### What the installer changes

- Installs `fprintd`, `ffmpeg`, `v4l-utils`, `jq`, `curl`, `python` and `git` with `pacman`.
- If Howdy is missing, offers to install `howdy-next` (falling back to `howdy-git`) with `yay`/`paru`.
- Adds/enables `grantabell.lock-fingerprint-on-enter`.
- Backs up `Service.qml` to `~/.local/state/howdy-face-unlock/backups/` and applies the Howdy patch.
- Creates `/etc/pam.d/omarchy-lock-howdy` if missing (or leaves an existing file that already references `pam_howdy.so`). The file is root-owned and mode `0644`.
- Detects the IR camera, sets `device_path`, `timeout = 4` and `abort_if_lid_closed = true` in `/etc/howdy/config.ini`, and keeps a timestamped backup. Other Howdy settings and comments are preserved.
- Optionally enrolls a face with `sudo howdy add`.
- Installs the user service, starts the watcher, and optionally runs the Telegram setup.
- Restarts the Omarchy shell.

### Howdy without an AUR helper

If the installer cannot find `yay` or `paru`, install Howdy first and rerun:

```bash
yay -S howdy-next       # or: yay -S howdy-git
sudo howdy add
sudo howdy test
./install.sh --skip-deps
```

Some cameras also need `linux-enable-ir-emitter` from the AUR. It is not installed automatically; try `sudo howdy test` first.

### Telegram (optional)

1. Open [@BotFather](https://t.me/BotFather), run `/newbot`, and copy the token.
2. Send any message to your new bot.
3. Run:

```bash
~/.local/bin/howdy-attempt-telegram-setup
```

The setup hides token input, detects the latest chat, writes
`~/.config/howdy-attempt-capture/telegram.env` with mode `0600`, and sends a
test message.

The config file supports an optional `TELEGRAM_API_IP`. Some networks return a
Telegram API address that is blackholed by the ISP/firewall while another Bot
API address still works. The setup tries normal DNS first, then pins
`149.154.167.220` if needed:

```dotenv
TELEGRAM_BOT_TOKEN=123456:replace-me
TELEGRAM_CHAT_ID=123456789
TELEGRAM_API_IP=149.154.167.220
```

If Telegram is blocked entirely, use your own VPN/proxy. Do not send a bot
token through a public third-party proxy.

## Verify

```bash
~/.local/bin/howdy-lock-verify
```

A healthy install reports:

```text
  ok    plugin enabled
  ok    Service.qml has the Howdy integration
  ok    face attempt limit is 3
  ok    PAM service runs pam_howdy.so
  ok    howdy-attempt-capture.service is active
  ok    faceUnlock and howdy are available
```

Also check:

```bash
omarchy-shell lock status
systemctl --user status howdy-attempt-capture.service
```

Then lock the screen and fail three **real** face scans (about four seconds each). After the third one, the lock screen shows the fallback message and one IR photo is saved. If Telegram is configured, it should arrive there too.

## Configuration

### Change the attempt count

The count lives in two places and they must match:

- `maxFaceAttempts` in
  `~/.config/omarchy/plugins/grantabell.lock-fingerprint-on-enter/Service.qml`
- `attempts=3` in `~/.local/bin/howdy-attempt-watch`

The watcher captures after the final failure. Setting the watcher lower than the
lock screen would capture while Howdy may still be scanning; keep them equal.
After changing the QML, run `omarchy-restart-shell`; after changing the watcher,
run `systemctl --user restart howdy-attempt-capture.service`.

The uninstaller restores the QML backup. Reapply the patch with:

```bash
~/.local/bin/grantabell-howdy-patch
omarchy-restart-shell
```

### Photo location and retention

The default is `~/Pictures/lock-attempts/`. Override it without editing the
script:

```bash
mkdir -p ~/.config/howdy-attempt-capture
cp config/capture.env.example ~/.config/howdy-attempt-capture/capture.env
# edit HOWDY_ATTEMPT_PHOTO_DIR
systemctl --user restart howdy-attempt-capture.service
```

The newest 100 `*.jpg` files are kept. Files are `0600`; the directory is
`0700`.

### Turn features off

**Face unlock only** (fingerprint and the lock appearance stay):

```bash
touch ~/.config/omarchy/face-unlock-disabled
# re-enable:
rm -f ~/.config/omarchy/face-unlock-disabled
```

The marker is checked at the next lock. `omarchy-shell lock status` exposes the
result as `faceUnlock`.

**Telegram only** (photos remain local):

```bash
mv ~/.config/howdy-attempt-capture/telegram.env \
   ~/.config/howdy-attempt-capture/telegram.env.off
# re-enable:
mv ~/.config/howdy-attempt-capture/telegram.env.off \
   ~/.config/howdy-attempt-capture/telegram.env
```

No service restart is needed; the sender reads the file on each capture.

**Photo capture entirely:**

```bash
systemctl --user disable --now howdy-attempt-capture.service
# re-enable:
systemctl --user enable --now howdy-attempt-capture.service
```

### Plugin updates

`omarchy plugin update grantabell.lock-fingerprint-on-enter` refuses to update
while `Service.qml` is locally modified. That is intentional: a silent update
would drop the face unlock and the three-attempt logic.

To update the plugin deliberately, restore `Service.qml` from git, update, then
reapply the patch:

```bash
cd ~/.config/omarchy/plugins/grantabell.lock-fingerprint-on-enter
git checkout -- Service.qml
omarchy plugin update grantabell.lock-fingerprint-on-enter
~/.local/bin/grantabell-howdy-patch
omarchy-restart-shell
```

If the upstream file changed too much, the patcher aborts without writing and
prints which anchor no longer matches.

## Privacy and security

This project captures a biometric image of whoever is in front of the screen
after three failed face attempts. That is sensitive by default.

- Photos are one greyscale IR frame, not video or audio.
- Local files are `0600`, the directory is `0700`, and only the newest 100 are kept.
- Telegram delivery uploads the frame and its caption to Telegram's cloud. Disable it if that is unacceptable.
- The Telegram bot token and chat ID live in a `0600` file outside the repository. Never commit that file.
- The caption includes the hostname and timestamp. Edit `howdy-attempt-telegram` if you do not want that.
- The PAM service is dedicated to the lock screen. This project does not wire face auth into `sudo` or polkit.
- The GrantAbell plugin's health check validates that `/etc/pam.d/omarchy-lock-howdy`, the face model and `pam_howdy.so` are root-owned and not group/world-writable.
- The installer uses interactive `sudo`; it never assumes passwordless sudo.
- Inform anyone who uses the machine that failed face attempts can be photographed and, if enabled, sent to Telegram.

The project patches a **user-owned** plugin under `~/.config/omarchy/plugins/`. It does not modify `/usr/share/omarchy`, so an Omarchy update cannot silently overwrite the QML patch. Howdy's PAM service and config are system files and are backed up.

If you find a security issue, please open a private report or a minimal issue without tokens, chat IDs or photos. See [SECURITY.md](SECURITY.md).

## Troubleshooting

Start with:

```bash
~/.local/bin/howdy-lock-verify
journalctl -t pam_howdy -t howdy-attempt-watch -t howdy-attempt-capture -t howdy-attempt-telegram --since "10 min ago" -o cat
```

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for detailed cases.

Common ones:

- **"Too many face attempts" after fewer than three scans.** Check for `howdy-locked-out: attempts=N` in the shell log. Quick PAM errors and skipped lid-closed scans should pause, not count. If the lid is closed, face unlock cannot work; use password/fingerprint.
- **No face icon / `howdy:false`.** Run `~/.local/bin/howdy-lock-verify`; check the PAM file, `/etc/howdy/models/$USER.dat`, `pam_howdy.so`, and `sudo howdy test`.
- **No photo.** Check `systemctl --user status howdy-attempt-capture.service`, then `journalctl -t howdy-attempt-watch -t howdy-attempt-capture -n 50`. The camera may still be held by Howdy, or the watcher may not be able to read the journal.
- **Telegram fails.** Run `howdy-attempt-telegram-setup` again and read `journalctl -t howdy-attempt-telegram`. `Connection timed out` usually means the API IP is blocked; see `TELEGRAM_API_IP` above.
- **Fingerprint times out after resume.** Wait a couple of seconds; the patch retries fprintd's "Cannot run while suspended" error. Press Enter with an empty password field to restart fingerprint manually.

## Uninstall

```bash
./uninstall.sh
```

This stops and removes the watcher, helper scripts, our PAM service (only if it
carries the project marker), and restores `Service.qml` from the installer's
backup. It leaves Howdy, the enrolled face model, fprintd and the GrantAbell
plugin in place.

`./uninstall.sh --purge` also deletes the Telegram config, patch backups and
captured photos. `--restore-howdy-config` restores the most recent Howdy config
backup.

To remove the plugin itself:

```bash
omarchy plugin remove grantabell.lock-fingerprint-on-enter
```

## Project layout

```text
bin/
  howdy-attempt-watch          journal watcher (systemd user service)
  howdy-attempt-capture        one IR frame + retention
  howdy-attempt-telegram       optional Telegram sender
  howdy-attempt-telegram-setup interactive bot/chat setup
  grantabell-howdy-patch       idempotent QML patcher
  howdy-lock-verify            installation health check
pam/
  omarchy-lock-howdy           dedicated PAM service
scripts/
  detect-ir-camera             find the GREY-only V4L2 node
  configure-howdy.py           update only the needed Howdy keys
systemd/
  howdy-attempt-capture.service.in
config/
  capture.env.example
  telegram.env.example
  howdy-config.example.ini
docs/
  TROUBLESHOOTING.md
```

## Credits

- [GrantAbell/Omarchy-Lock-Fingerprint-on-Enter][grantabell] — the lock screen this project extends. MIT.
- [tslove923/omarchy-howdy-face-unlock][howdy-plugin] — Howdy integration approach and IR camera detection. MIT.
- [Howdy][howdy] — face recognition and `pam_howdy`.
- [Omarchy][omarchy] — the desktop and plugin system.

Third-party license texts are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

This project was developed with AI assistance. Review the scripts and the PAM/QML changes before trusting them with your lock screen.

## License

MIT. See [LICENSE](LICENSE).

[grantabell]: https://github.com/GrantAbell/Omarchy-Lock-Fingerprint-on-Enter
[howdy-plugin]: https://github.com/tslove923/omarchy-howdy-face-unlock
[howdy]: https://github.com/boltgolt/howdy
[omarchy]: https://omarchy.org/
