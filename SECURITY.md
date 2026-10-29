# Security policy

## What this project touches

- A user-owned Quickshell lock-screen plugin under
  `~/.config/omarchy/plugins/grantabell.lock-fingerprint-on-enter/`.
- A dedicated PAM service at `/etc/pam.d/omarchy-lock-howdy`.
- A few keys in `/etc/howdy/config.ini`.
- An optional systemd **user** service and an optional Telegram bot token.

It does not modify `/usr/share/omarchy`, does not add passwordless sudo rules,
and does not wire face authentication into `sudo` or polkit.

## Biometric data

Captured frames are greyscale infrared images of whoever is in front of the
screen. They are sensitive personal data even when they stay local.

- Local photos are written with mode `0600` in a `0700` directory.
- Only the newest 100 files are retained.
- Telegram delivery is optional and uploads the frame plus a hostname/timestamp
  caption to Telegram's cloud. Do not enable it without the consent of people
  who use the machine.
- The bot token is stored outside the repository in a `0600` file. Treat it like
  a password: anyone with it can control the bot.

## Reporting a vulnerability

Please do not publish real bot tokens, chat IDs, face images or hostnames in an
issue. Open a minimal report describing the affected script and the behaviour,
or contact the repository owner privately if a private channel is listed.

Include:

- the affected file and version/commit;
- steps to reproduce without real credentials or photos;
- whether the issue can expose photos, the bot token, or PAM authentication.

## Before publishing a fork

- Remove `.git` history if you ever committed a real `telegram.env`, token or
  photo. Rotate the bot token with @BotFather immediately.
- Do not commit `~/.config/howdy-attempt-capture/telegram.env`,
  `~/.local/state/`, or `~/Pictures/lock-attempts/`.
- Review the patcher diff before trusting a lock-screen change.
