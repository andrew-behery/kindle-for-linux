# Shared by install.sh, uninstall.sh, verify.sh and the kindle launcher. Sourced, not run.
# shellcheck shell=bash

KINDLE_PKG=com.amazon.kindle
DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
APP_DIR=$DATA_HOME/kindle-for-linux
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/kindle-for-linux
STATE_FILE=$STATE_DIR/state
APPS_DIR=$DATA_HOME/applications
BIN_DIR=$HOME/.local/bin
DESKTOP_FILE=$APPS_DIR/kindle-for-linux.desktop
WAYDROID_DESKTOP=$APPS_DIR/waydroid.$KINDLE_PKG.desktop
WAYDROID_DATA=$DATA_HOME/waydroid
WAYDROID_CFG=/var/lib/waydroid/waydroid.cfg
KINDLE_ICON=$WAYDROID_DATA/data/icons/$KINDLE_PKG.png

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    Warning: %s\033[0m\n' "$*" >&2; }
die() {
  printf '\n\033[1;31mError: %s\033[0m\n' "$*" >&2
  exit 1
}

# key=value state that install.sh records and uninstall.sh reads back.
state_get() { if [[ -f $STATE_FILE ]]; then sed -n "s/^$1=//p" "$STATE_FILE" | tail -n1; fi; }
state_set() {
  mkdir -p "$STATE_DIR"
  touch "$STATE_FILE"
  sed -i "/^$1=/d" "$STATE_FILE"
  printf '%s=%s\n' "$1" "$2" >>"$STATE_FILE"
}

# "RUNNING", "FROZEN" or "STOPPED" (from `waydroid status`, whose lines are "Key:<tab>Value").
session_state() { waydroid status 2>/dev/null | awk -F':[ \t]+' '$1 == "Session" { print $2 }'; }
container_state() { waydroid status 2>/dev/null | awk -F':[ \t]+' '$1 == "Container" { print $2 }'; }
android_booted() { [[ $(waydroid prop get sys.boot_completed 2>/dev/null) == 1 ]]; }

# Wayland gives every Android app its own window. Under X11 there is no Wayland compositor to
# draw into, so Android runs inside cage, a minimal Wayland compositor that opens as one X11 window.
display_mode() {
  if [[ -n ${WAYLAND_DISPLAY:-} ]]; then
    echo wayland
  elif [[ -n ${DISPLAY:-} ]]; then
    echo x11
  else
    echo none
  fi
}

# Start Android in the background (if it isn't running) and wait until it has finished booting.
# $1 = seconds to wait. The session outlives this script: it keeps running until logout or
# `kindle --stop`, and Waydroid freezes it while no app is open.
start_android() {
  local timeout=${1:-180} log=$STATE_DIR/session.log
  mkdir -p "$STATE_DIR"
  if [[ $(session_state) != RUNNING ]]; then
    if [[ $(display_mode) == x11 ]]; then
      # Android needs a Wayland display to draw into: cage provides one, as an X11 window.
      setsid -f cage -d -- waydroid session start >"$log" 2>&1 </dev/null
    else
      setsid -f waydroid session start >"$log" 2>&1 </dev/null
    fi
  fi
  local deadline=$((SECONDS + timeout))
  until android_booted; do
    ((SECONDS < deadline)) || return 1
    sleep 0.5
  done
}

stop_android() {
  [[ $(session_state) == RUNNING ]] || return 0
  waydroid session stop >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 30); do
    [[ $(session_state) == RUNNING ]] || return 0
    sleep 1
  done
}

# Output is captured first: `grep -q` quitting early would make a pipefail pipeline report failure.
kindle_installed() {
  local apps
  apps=$(waydroid app list 2>/dev/null) || true
  grep -q "packageName: $KINDLE_PKG\$" <<<"$apps"
}

# Waydroid writes its own Kindle menu entry (Exec=waydroid app launch ...). Ours replaces it,
# so hide Waydroid's. Waydroid keeps an existing NoDisplay key when it rewrites the file.
hide_waydroid_entry() {
  [[ -f $WAYDROID_DESKTOP ]] || return 0
  grep -q '^NoDisplay=true' "$WAYDROID_DESKTOP" && return 0
  sed -i '/^NoDisplay=/d; /^\[Desktop Entry\]/a NoDisplay=true' "$WAYDROID_DESKTOP"
}
