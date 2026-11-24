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
# Kindle's window is scrcpy showing a virtual Android screen that follows the window's size.
# x86_64 gets scrcpy's official build (with its own adb) in SCRCPY_DIR; ARM64 uses the distro's.
SCRCPY_DIR=$APP_DIR/scrcpy
ADB_HOME=$APP_DIR/adb       # adb's home directory: holds the key Android trusts (.android/adbkey)
WINDOW_ID=kindle-for-linux  # the window's app ID; matches kindle-for-linux.desktop
# Our own adb server on its own port, so it never clashes with an adb you run yourself.
export ANDROID_ADB_SERVER_PORT=5039

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
session_state() { timeout 10 waydroid status 2>/dev/null | awk -F':[ \t]+' '$1 == "Session" { print $2 }'; }
container_state() { timeout 10 waydroid status 2>/dev/null | awk -F':[ \t]+' '$1 == "Container" { print $2 }'; }
# `waydroid prop get` and `waydroid app list` retry forever while Android's core is down, so cap them.
android_booted() { [[ $(timeout 15 waydroid prop get sys.boot_completed 2>/dev/null) == 1 ]]; }

android_ip() { timeout 10 waydroid status 2>/dev/null | awk -F':[ \t]+' '$1 == "IP address" { print $2 }'; }

# Freeze or thaw Android through Waydroid's container service, as `waydroid app launch` does
# (no root needed). $1 = Freeze or Unfreeze.
container_call() {
  if command -v gdbus >/dev/null; then
    gdbus call --system --dest id.waydro.Container --object-path /ContainerManager \
      --method "id.waydro.ContainerManager.$1" >/dev/null 2>&1
  else # Waydroid itself depends on python-dbus
    /usr/bin/python3 -c 'import sys, dbus
dbus.Interface(dbus.SystemBus().get_object("id.waydro.Container", "/ContainerManager"),
               "id.waydro.ContainerManager").get_dbus_method(sys.argv[1])()' "$1" >/dev/null 2>&1
  fi
}

scrcpy_bin() { if [[ -x $SCRCPY_DIR/scrcpy ]]; then echo "$SCRCPY_DIR/scrcpy"; else command -v scrcpy; fi; }
adb_bin() { if [[ -x $SCRCPY_DIR/adb ]]; then echo "$SCRCPY_DIR/adb"; else command -v adb; fi; }
# adb with our key: a server it starts reads $ADB_HOME/.android/adbkey.
# Time-limited: adb waits forever on an Android that is frozen. `9>&-` (here and wherever a
# background process may start) keeps the launcher's window lock out of long-lived processes
# such as the adb server, which would otherwise hold it after the window closes.
kfl_adb() { HOME=$ADB_HOME timeout "${ADB_TIMEOUT:-30}" "$(adb_bin)" "$@" 9>&-; }

# Connect our adb to Android and print its serial. $1 = seconds to keep trying (default 20).
android_connect() {
  local serial st deadline=$((SECONDS + ${1:-20}))
  kfl_adb start-server >/dev/null 2>&1 || return 1
  while :; do
    serial=$(android_ip):5555
    if [[ $serial != :5555 ]]; then
      st=$(HOME=$ADB_HOME timeout 5 "$(adb_bin)" -s "$serial" get-state 2>/dev/null 9>&- || true)
      if [[ $st == device ]]; then
        echo "$serial"
        return 0
      fi
      [[ $st == offline ]] && kfl_adb disconnect "$serial" >/dev/null 2>&1
      HOME=$ADB_HOME timeout 5 "$(adb_bin)" connect "$serial" >/dev/null 2>&1 9>&- || true
    fi
    ((SECONDS < deadline)) || return 1
    sleep 0.5
  done
}

# Android needs a Wayland display to draw into, even though Kindle's window comes from scrcpy.
# Under X11 there is none, so Android gets cage, a minimal Wayland compositor, running headless.
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
# `kindle --stop`, frozen while Kindle's window is closed.
start_android() {
  local timeout=${1:-180} log=$STATE_DIR/session.log
  mkdir -p "$STATE_DIR"
  if [[ $(session_state) != RUNNING ]]; then
    if [[ $(display_mode) == x11 ]]; then
      WLR_BACKENDS=headless setsid -f cage -- waydroid session start >"$log" 2>&1 </dev/null 9>&-
    else
      setsid -f waydroid session start >"$log" 2>&1 </dev/null 9>&-
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

# Installed apps as Waydroid reports them, waiting up to $1 seconds (default 60) for Android to
# answer: right after a start, or while Android restarts its core, the list comes back empty.
android_apps() {
  local deadline=$((SECONDS + ${1:-60})) apps
  while :; do
    apps=$(timeout 20 waydroid app list 2>/dev/null) || true
    if [[ -n $apps ]]; then
      printf '%s\n' "$apps"
      return 0
    fi
    ((SECONDS < deadline)) || return 1
    sleep 2
  done
}

# 0 = installed, 1 = not installed, 2 = unknown (Android didn't answer within $1 seconds).
# Output is captured first: `grep -q` quitting early would make a pipefail pipeline report failure.
kindle_installed() {
  local apps
  apps=$(android_apps "${1:-60}") || return 2
  grep -q "packageName: $KINDLE_PKG\$" <<<"$apps"
}

# Waydroid writes its own Kindle menu entry (Exec=waydroid app launch ...). Ours replaces it,
# so hide Waydroid's. Waydroid keeps an existing NoDisplay key when it rewrites the file.
hide_waydroid_entry() {
  [[ -f $WAYDROID_DESKTOP ]] || return 0
  grep -q '^NoDisplay=true' "$WAYDROID_DESKTOP" && return 0
  sed -i '/^NoDisplay=/d; /^\[Desktop Entry\]/a NoDisplay=true' "$WAYDROID_DESKTOP"
}
