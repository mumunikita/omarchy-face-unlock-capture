#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Remove the lock-screen face unlock + capture integration. By default the
# GrantAbell plugin itself, Howdy and the enrolled face model are left alone.
set -euo pipefail

PLUGIN_ID="grantabell.lock-fingerprint-on-enter"
PLUGIN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$PLUGIN_ID"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/howdy-attempt-capture"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/howdy-face-unlock"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
PAM_FILE="/etc/pam.d/omarchy-lock-howdy"
SERVICE="howdy-attempt-capture.service"
PHOTO_DIR="${HOWDY_ATTEMPT_PHOTO_DIR:-$HOME/Pictures/lock-attempts}"

PURGE=0
RESTORE_HOWDY_CONFIG=0
NO_RESTART=0
ASSUME_YES=0

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
else
  C_RESET="" C_BOLD="" C_GREEN="" C_YELLOW="" C_RED=""
fi

info() { printf '%s==>%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() {
  printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: ./uninstall.sh [options]

Options:
  -y, --yes                 Do not ask for confirmation
      --purge               Also delete config, state and captured photos
      --restore-howdy-config
                            Restore the most recent Howdy config backup
      --no-restart          Do not restart the Omarchy shell
  -h, --help                Show this help

This removes the watcher service, helper scripts and PAM service, and restores
the GrantAbell Service.qml from the backup made by install.sh. It does not
remove Howdy, the enrolled face model, fprintd or the GrantAbell plugin.
EOF
}

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  [[ -t 0 ]] || return 1
  local answer
  read -r -p "$1 [y/N] " answer
  [[ $answer == [yY] || $answer == [yY][eE][sS] ]]
}

while (($#)); do
  case "$1" in
    -y|--yes) ASSUME_YES=1 ;;
    --purge) PURGE=1 ;;
    --restore-howdy-config) RESTORE_HOWDY_CONFIG=1 ;;
    --no-restart) NO_RESTART=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

if [[ $EUID -eq 0 ]]; then
  die "run as your normal user, not root"
fi
[[ -n ${USER:-} ]] || die "USER is not set"
command -v systemctl >/dev/null 2>&1 || die "systemctl not found"

if [[ $PURGE -eq 1 ]]; then
  warn "purge will delete:"
  warn "  $CONFIG_DIR (Telegram credentials and settings)"
  warn "  $STATE_DIR (patch backups)"
  warn "  $PHOTO_DIR (captured IR photos)"
  if ! confirm "Delete all of that?"; then
    die "cancelled"
  fi
fi

info "Stopping the capture watcher"
systemctl --user disable --now "$SERVICE" >/dev/null 2>&1 || true
rm -f "$UNIT_DIR/$SERVICE"
systemctl --user daemon-reload

info "Removing helper scripts"
rm -f \
  "$BIN_DIR/howdy-attempt-watch" \
  "$BIN_DIR/howdy-attempt-capture" \
  "$BIN_DIR/howdy-attempt-telegram" \
  "$BIN_DIR/howdy-attempt-telegram-setup" \
  "$BIN_DIR/howdy-lock-verify" \
  "$BIN_DIR/grantabell-howdy-patch"

if [[ -f $PLUGIN_DIR/Service.qml ]] && grep -q 'omarchy-lock-howdy' "$PLUGIN_DIR/Service.qml"; then
  info "Restoring the GrantAbell Service.qml"
  latest=""
  if [[ -d $STATE_DIR/backups ]]; then
    latest=$(find "$STATE_DIR/backups" -maxdepth 1 -type f -name 'Service.qml.*' -printf '%T@ %p\n' 2>/dev/null |
      sort -rn | head -1 | cut -d' ' -f2-)
  fi
  if [[ -n $latest && -f $latest ]]; then
    cp -a "$latest" "$PLUGIN_DIR/Service.qml"
    info "Restored from $latest"
  elif [[ -d $PLUGIN_DIR/.git ]]; then
    if confirm "No backup found. Restore Service.qml from git HEAD (discarding local changes)?"; then
      git -C "$PLUGIN_DIR" checkout -- Service.qml
      info "Restored Service.qml from git HEAD"
    else
      warn "left Service.qml patched"
    fi
  else
    warn "no backup and no git checkout; left Service.qml patched"
  fi
fi

if [[ -f $PAM_FILE ]] && sudo grep -q 'managed by omarchy-face-unlock-capture' "$PAM_FILE"; then
  info "Removing our /etc/pam.d/omarchy-lock-howdy"
  latest_pam=$(sudo find /etc/pam.d -maxdepth 1 -type f -name 'omarchy-lock-howdy.bak.*' -printf '%T@ %p\n' 2>/dev/null |
    sort -rn | head -1 | cut -d' ' -f2-)
  sudo rm -f "$PAM_FILE"
  if [[ -n $latest_pam && -f $latest_pam ]]; then
    sudo mv "$latest_pam" "$PAM_FILE"
    info "Restored $PAM_FILE from $latest_pam"
  fi
else
  warn "left $PAM_FILE in place (not created by this project, or missing)"
fi

if [[ $RESTORE_HOWDY_CONFIG -eq 1 ]]; then
  latest_cfg=$(sudo find /etc/howdy -maxdepth 1 -type f -name 'config.ini.omarchy-face-unlock.bak.*' -printf '%T@ %p\n' 2>/dev/null |
    sort -rn | head -1 | cut -d' ' -f2-)
  if [[ -n $latest_cfg && -f $latest_cfg ]]; then
    sudo cp -a "$latest_cfg" /etc/howdy/config.ini
    info "Restored /etc/howdy/config.ini from $latest_cfg"
  else
    warn "no Howdy config backup found"
  fi
fi

rm -f "$HOME/.config/omarchy/face-unlock-disabled" 2>/dev/null || true

if [[ $PURGE -eq 1 ]]; then
  info "Purging config, state and photos"
  rm -rf "$CONFIG_DIR" "$STATE_DIR" "$PHOTO_DIR"
fi

if [[ $NO_RESTART -eq 0 ]]; then
  info "Restarting the Omarchy shell"
  omarchy-restart-shell >/dev/null 2>&1 || warn "run omarchy-restart-shell manually"
fi

cat <<EOF

${C_BOLD}Uninstalled.${C_RESET}

The GrantAbell plugin, Howdy, fprintd and the enrolled face model were left
in place. To remove the plugin itself:
  omarchy plugin remove $PLUGIN_ID

EOF
