#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Install face unlock + IR attempt capture for the GrantAbell Omarchy lock
# screen. Run as your normal user; sudo is used only for system files.
set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ID="grantabell.lock-fingerprint-on-enter"
PLUGIN_URL="https://github.com/GrantAbell/Omarchy-Lock-Fingerprint-on-Enter.git"
PLUGIN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$PLUGIN_ID"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/howdy-attempt-capture"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/howdy-face-unlock"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
HOWDY_CONFIG="/etc/howdy/config.ini"
PAM_FILE="/etc/pam.d/omarchy-lock-howdy"
HOWDY_MODEL="/etc/howdy/models/${USER}.dat"
SERVICE="howdy-attempt-capture.service"
PHOTO_DIR="${HOWDY_ATTEMPT_PHOTO_DIR:-$HOME/Pictures/lock-attempts}"

ASSUME_YES=0
SKIP_DEPS=0
SKIP_HOWDY_CONFIG=0
FORCE_PAM=0
NO_RESTART=0
ENROLL=ask
TELEGRAM=ask

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
Usage: ./install.sh [options]

Options:
  -y, --yes          Accept safe defaults (does not configure Telegram)
      --skip-deps    Do not install packages or Howdy
      --skip-howdy-config
                     Do not edit /etc/howdy/config.ini
      --force-pam    Replace an existing non-Howdy /etc/pam.d/omarchy-lock-howdy
      --telegram     Run the interactive Telegram setup
      --no-telegram  Never ask about Telegram
      --enroll       Run `sudo howdy add` if the face model is missing
      --no-enroll    Do not enroll a face
      --no-restart   Do not restart the Omarchy shell
  -h, --help         Show this help

Run as your normal user, not as root. The installer uses sudo interactively
for /etc/pam.d, /etc/howdy/config.ini and optional face enrollment.
EOF
}

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  [[ -t 0 ]] || return 1
  local answer
  read -r -p "$1 [y/N] " answer
  [[ $answer == [yY] || $answer == [yY][eE][sS] ]]
}

confirm_yes() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  [[ -t 0 ]] || return 1
  local answer
  read -r -p "$1 [Y/n] " answer
  [[ -z $answer || $answer == [yY] || $answer == [yY][eE][sS] ]]
}

while (($#)); do
  case "$1" in
    -y|--yes) ASSUME_YES=1 ;;
    --skip-deps) SKIP_DEPS=1 ;;
    --skip-howdy-config) SKIP_HOWDY_CONFIG=1 ;;
    --force-pam) FORCE_PAM=1 ;;
    --telegram) TELEGRAM=1 ;;
    --no-telegram) TELEGRAM=0 ;;
    --enroll) ENROLL=1 ;;
    --no-enroll) ENROLL=0 ;;
    --no-restart) NO_RESTART=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

if [[ $EUID -eq 0 ]]; then
  die "run as your normal user, not root (sudo is invoked where needed)"
fi
[[ -n ${USER:-} ]] || die "USER is not set"
for cmd in omarchy systemctl journalctl sudo pacman; do
  command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
done
if ! systemctl --user show-environment >/dev/null 2>&1; then
  die "no user systemd session; run this from your desktop session"
fi
[[ -f $REPO_DIR/bin/howdy-attempt-watch ]] || die "run install.sh from the repository"
[[ -f $REPO_DIR/bin/grantabell-howdy-patch ]] || die "repository is incomplete"

howdy_ready() {
  command -v howdy >/dev/null 2>&1 &&
    { [[ -f /usr/lib/security/pam_howdy.so ]] || [[ -f /lib/security/pam_howdy.so ]]; }
}

check_runtime_deps() {
  local missing=()
  local cmd
  for cmd in jq curl ffmpeg v4l2-ctl python3; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if ((${#missing[@]})); then
    die "missing runtime dependencies: ${missing[*]} (rerun without --skip-deps)"
  fi
}

install_packages() {
  if [[ $SKIP_DEPS -eq 1 ]]; then
    warn "skipping package installation (--skip-deps)"
    howdy_ready || die "Howdy is not installed; install howdy-next from the AUR first"
    return
  fi

  info "Installing packages (fprintd, ffmpeg, v4l-utils, jq, curl, python, git)"
  sudo pacman -S --needed --noconfirm \
    fprintd ffmpeg v4l-utils jq curl python git

  if howdy_ready; then
    info "Howdy and pam_howdy.so are already installed"
    return
  fi

  warn "Howdy is not installed (or pam_howdy.so is missing)"
  local helper=""
  local candidate
  for candidate in yay paru; do
    if command -v "$candidate" >/dev/null 2>&1; then
      helper=$candidate
      break
    fi
  done

  if [[ -z $helper ]]; then
    cat >&2 <<'EOF'
Install Howdy from the AUR, then rerun this installer:
  yay -S howdy-next
  # or: yay -S howdy-git
Then enroll a face:
  sudo howdy add
EOF
    die "Howdy is required for face unlock"
  fi

  if ! confirm "Install Howdy from the AUR with $helper? This can take a while."; then
    die "Howdy is required; install it and rerun"
  fi

  if ! "$helper" -S --needed --noconfirm howdy-next; then
    warn "howdy-next failed; trying howdy-git"
    "$helper" -S --needed --noconfirm howdy-git
  fi
  howdy_ready || die "Howdy installed, but pam_howdy.so is still missing"
}

install_plugin() {
  if [[ ! -d $PLUGIN_DIR ]]; then
    info "Installing the GrantAbell fingerprint lock plugin"
    omarchy plugin add "$PLUGIN_URL" --enable --yes
  else
    info "GrantAbell plugin already present"
  fi

  [[ -f $PLUGIN_DIR/Service.qml ]] || die "plugin installed without Service.qml: $PLUGIN_DIR"

  local enabled
  enabled=$(omarchy plugin list --json 2>/dev/null |
    jq -r --arg id "$PLUGIN_ID" '.[] | select(.id == $id) | .enabled' 2>/dev/null || true)
  if [[ $enabled != true ]]; then
    info "Enabling the GrantAbell lock screen"
    omarchy plugin enable "$PLUGIN_ID"
  fi
  enabled=$(omarchy plugin list --json 2>/dev/null |
    jq -r --arg id "$PLUGIN_ID" '.[] | select(.id == $id) | .enabled' 2>/dev/null || true)
  [[ $enabled == true ]] || die "could not enable $PLUGIN_ID"

  if [[ -d $PLUGIN_DIR/.git ]]; then
    local commit
    commit=$(git -C "$PLUGIN_DIR" rev-parse --short HEAD 2>/dev/null || true)
    if [[ $commit != e887095* ]]; then
      warn "plugin commit is ${commit:-unknown}; this patch was tested with e887095"
    fi
  fi
}

patch_plugin() {
  info "Installing the patch helper"
  install -Dm755 "$REPO_DIR/bin/grantabell-howdy-patch" "$BIN_DIR/grantabell-howdy-patch"

  local qml="$PLUGIN_DIR/Service.qml"
  mkdir -p "$STATE_DIR/backups"
  chmod 700 "$STATE_DIR" "$STATE_DIR/backups" 2>/dev/null || true

  if grep -q 'omarchy-lock-howdy' "$qml"; then
    if ! grep -q 'howdyAttemptStartedAt' "$qml"; then
      die "an older Howdy patch is present; restore Service.qml from git and rerun"
    fi
    if ! grep -q 'maxFaceAttempts: 3' "$qml"; then
      info "Updating the existing patch to three face attempts"
      sed -i 's/readonly property int maxFaceAttempts: [0-9][0-9]*/readonly property int maxFaceAttempts: 3/' "$qml"
    fi
    info "Service.qml already patched"
  else
    local backup
    backup="$STATE_DIR/backups/Service.qml.$(date +%Y%m%d-%H%M%S)"
    cp -a "$qml" "$backup"
    info "Backed up Service.qml to $backup"
    if ! "$BIN_DIR/grantabell-howdy-patch" "$qml"; then
      die "patching failed; the original was left in place (backup: $backup)"
    fi
  fi

  grep -q 'maxFaceAttempts: 3' "$qml" || die "patch did not set maxFaceAttempts to 3"
  grep -q 'omarchy-lock-howdy' "$qml" || die "patch did not add the Howdy PAM path"
}

install_pam() {
  info "Configuring the dedicated Howdy PAM service"
  if [[ -f $PAM_FILE ]]; then
    if grep -q 'pam_howdy.so' "$PAM_FILE"; then
      info "$PAM_FILE already references pam_howdy.so; leaving it in place"
    else
      if [[ $FORCE_PAM -ne 1 ]] && ! confirm "Replace existing $PAM_FILE?"; then
        die "refusing to replace $PAM_FILE without --force-pam"
      fi
      sudo cp -a "$PAM_FILE" "$PAM_FILE.bak.$(date +%Y%m%d-%H%M%S)"
      sudo install -Dm644 "$REPO_DIR/pam/omarchy-lock-howdy" "$PAM_FILE"
    fi
  else
    sudo install -Dm644 "$REPO_DIR/pam/omarchy-lock-howdy" "$PAM_FILE"
  fi
  local owner mode
  owner=$(stat -c '%u:%g' "$PAM_FILE" 2>/dev/null || true)
  mode=$(stat -c '%a' "$PAM_FILE" 2>/dev/null || true)
  if [[ $owner != "0:0" ]]; then
    sudo chown root:root "$PAM_FILE"
  fi
  if [[ $mode != "644" ]]; then
    sudo chmod 644 "$PAM_FILE"
  fi
}

configure_howdy() {
  if [[ $SKIP_HOWDY_CONFIG -eq 1 ]]; then
    warn "skipping Howdy config changes (--skip-howdy-config)"
    return
  fi
  if [[ ! -f $HOWDY_CONFIG ]]; then
    warn "$HOWDY_CONFIG is missing; configure Howdy before using face unlock"
    return
  fi

  local ir=""
  ir=$("$REPO_DIR/scripts/detect-ir-camera" 2>/dev/null || true)
  if [[ -n $ir ]]; then
    info "Detected IR camera: $ir"
  else
    warn "no GREY-only IR camera detected; leaving [video] device_path unchanged"
    warn "set it manually with: sudo howdy config   (or edit $HOWDY_CONFIG)"
  fi

  local -a args=(--config "$HOWDY_CONFIG" --timeout 4)
  if [[ -n $ir ]]; then
    args+=(--device "$ir")
  fi
  sudo python3 "$REPO_DIR/scripts/configure-howdy.py" "${args[@]}"
}

enroll_face() {
  if [[ -f $HOWDY_MODEL ]]; then
    info "Face model already enrolled: $HOWDY_MODEL"
    return
  fi
  if [[ $ENROLL == 0 ]]; then
    warn "no face model at $HOWDY_MODEL; face unlock will stay off until you run: sudo howdy add"
    return
  fi
  if [[ $ENROLL == ask ]] && ! confirm_yes "No face model for $USER. Enroll now with sudo howdy add?"; then
    warn "skipping enrollment; run 'sudo howdy add' later"
    return
  fi
  if [[ ! -t 0 ]]; then
    warn "not a terminal; run 'sudo howdy add' manually"
    return
  fi
  sudo howdy add || warn "howdy add failed; run it manually and check the camera"
  [[ -f $HOWDY_MODEL ]] || warn "model still missing after enrollment: $HOWDY_MODEL"
}

install_watcher() {
  info "Installing runtime scripts and the user service"
  install -Dm755 "$REPO_DIR/bin/howdy-attempt-watch" "$BIN_DIR/howdy-attempt-watch"
  install -Dm755 "$REPO_DIR/bin/howdy-attempt-capture" "$BIN_DIR/howdy-attempt-capture"
  install -Dm755 "$REPO_DIR/bin/howdy-attempt-telegram" "$BIN_DIR/howdy-attempt-telegram"
  install -Dm755 "$REPO_DIR/bin/howdy-attempt-telegram-setup" "$BIN_DIR/howdy-attempt-telegram-setup"
  install -Dm755 "$REPO_DIR/bin/howdy-lock-verify" "$BIN_DIR/howdy-lock-verify"

  mkdir -p "$CONFIG_DIR" "$PHOTO_DIR"
  chmod 700 "$CONFIG_DIR" "$PHOTO_DIR" 2>/dev/null || true

  local unit_tmp
  unit_tmp=$(mktemp)
  sed -e "s|@BIN_DIR@|$BIN_DIR|g" \
      -e "s|@CONFIG_DIR@|$CONFIG_DIR|g" \
      "$REPO_DIR/systemd/howdy-attempt-capture.service.in" > "$unit_tmp"
  install -Dm644 "$unit_tmp" "$UNIT_DIR/$SERVICE"
  rm -f "$unit_tmp"

  systemctl --user daemon-reload
  systemctl --user enable "$SERVICE"
  systemctl --user restart "$SERVICE"
  if systemctl --user is-active --quiet "$SERVICE"; then
    info "$SERVICE is active"
  else
    warn "$SERVICE did not start; inspect: journalctl --user -u $SERVICE -n 50"
  fi
}

configure_telegram() {
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR" 2>/dev/null || true

  if [[ $TELEGRAM == 0 ]]; then
    info "Telegram delivery disabled (photos stay local)"
    return
  fi
  if [[ -r $CONFIG_DIR/telegram.env ]]; then
    info "Telegram is already configured: $CONFIG_DIR/telegram.env"
    return
  fi
  if [[ $TELEGRAM == ask ]]; then
    if ! confirm "Configure Telegram delivery now? (optional, requires a bot token)"; then
      info "Telegram not configured; photos stay local"
      return
    fi
  fi
  if [[ ! -t 0 ]]; then
    warn "not a terminal; run howdy-attempt-telegram-setup manually"
    return
  fi
  "$BIN_DIR/howdy-attempt-telegram-setup"
}

restart_shell() {
  if [[ $NO_RESTART -eq 1 ]]; then
    info "Skipping shell restart (--no-restart); run: omarchy-restart-shell"
    return
  fi
  info "Restarting the Omarchy shell"
  omarchy-restart-shell >/dev/null 2>&1 || warn "could not restart the shell; run: omarchy-restart-shell"
}

summary() {
  cat <<EOF

${C_BOLD}Installed.${C_RESET}

  Lock screen plugin : $PLUGIN_ID
  Face attempts      : 3 (real scans; quick PAM skips do not count)
  Photos             : $PHOTO_DIR (newest 100, mode 600)
  Watcher            : systemctl --user status $SERVICE
  Verify             : $BIN_DIR/howdy-lock-verify
  Telegram           : $CONFIG_DIR/telegram.env (optional)

  Disable face unlock: touch ~/.config/omarchy/face-unlock-disabled
  Re-enable face      : rm -f ~/.config/omarchy/face-unlock-disabled
  Pause Telegram      : mv $CONFIG_DIR/telegram.env $CONFIG_DIR/telegram.env.off
  Stop photo capture  : systemctl --user disable --now $SERVICE

  If the GrantAbell plugin is updated, reapply the patch with:
    $BIN_DIR/grantabell-howdy-patch

  Lock the screen once and fail three real face scans to test the photo.
EOF
}

install_packages
check_runtime_deps
install_plugin
patch_plugin
install_pam
configure_howdy
enroll_face
install_watcher
configure_telegram
restart_shell
summary
