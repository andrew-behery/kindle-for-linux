# Shared by install.sh, uninstall.sh, verify.sh and the kindle launcher. Sourced, not run.
# shellcheck shell=bash
# shellcheck disable=SC2034

KINDLE_PKG=com.amazon.kindle
DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
APP_DIR=$DATA_HOME/kindle-for-linux
PKG_DIR=/usr/share/kindle-for-linux
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/kindle-for-linux
STATE_FILE=$STATE_DIR/state
APPS_DIR=$DATA_HOME/applications
BIN_DIR=$HOME/.local/bin
DESKTOP_FILE=$APPS_DIR/kindle-for-linux.desktop
WAYDROID_DESKTOP=$APPS_DIR/waydroid.$KINDLE_PKG.desktop
WAYDROID_DATA=$DATA_HOME/waydroid
WAYDROID_CFG=/var/lib/waydroid/waydroid.cfg
# Kindle's icon: the one the installer saved from the APK, else Waydroid's copy, else the package SVG.
KINDLE_ICON=$APP_DIR/kindle.png
[[ -f $KINDLE_ICON ]] || KINDLE_ICON=$APP_DIR/kindle.webp
[[ -f $KINDLE_ICON ]] || KINDLE_ICON=$WAYDROID_DATA/data/icons/$KINDLE_PKG.png
[[ -f $KINDLE_ICON ]] || KINDLE_ICON=/usr/share/icons/hicolor/scalable/apps/kindle-for-linux.svg
# Kindle's window is scrcpy showing a virtual Android screen that follows the window's size.
# x86_64 gets scrcpy's official build (with its own adb) in SCRCPY_DIR; ARM64 uses the distro's.
SCRCPY_DIR=$APP_DIR/scrcpy
ADB_HOME=$APP_DIR/adb       # adb's home directory: holds the key Android trusts (.android/adbkey)
WINDOW_ID=kindle-for-linux  # the window's app ID; matches kindle-for-linux.desktop
# Our own adb server on its own port, so it never clashes with an adb you run yourself.
export ANDROID_ADB_SERVER_PORT=5039

# Android runs in one of two ways ("backends"):
#   waydroid  a container on the host's kernel, drawing with an AMD, Intel or ARM GPU. Light.
#   emulator  Google's Android emulator (KVM), for NVIDIA-only computers, whose GPU Waydroid's
#             Android can't use. It runs Google's "Google APIs" Android 15 image: the Google-free
#             images have no ARM translation, and Kindle is ARM-only.
EMU_SDK=$APP_DIR/sdk        # the emulator and its system image
EMU_AVD_HOME=$APP_DIR/avd
EMU_AVD=Kindle             # also the emulator window's title (seen when signing in)
EMU_CONSOLE_PORT=5590       # adb on 5591: outside 5554-5585, where other emulators and adbs look
EMU_SERIAL=emulator-$EMU_CONSOLE_PORT
# ...so our adb server looks there too.
export ADB_LOCAL_TRANSPORT_MAX_PORT=$((EMU_CONSOLE_PORT + 1))
# Forward adbd's TCP port (5555) over QEMU's user-mode network: the emulator's default
# virtio-vsock adb link (AdbVsockPipe) can drop mid-session under scrcpy load.
EMU_ADB_TCP_PORT=$((EMU_CONSOLE_PORT + 2))
EMU_ADB_TCP=127.0.0.1:$EMU_ADB_TCP_PORT

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

BACKEND=${KINDLE_BACKEND:-$(state_get backend)}
BACKEND=${BACKEND:-waydroid}

# "RUNNING", "FROZEN" or "STOPPED" (from `waydroid status`, whose lines are "Key:<tab>Value").
session_state() { timeout 10 waydroid status 2>/dev/null | awk -F':[ \t]+' '$1 == "Session" { print $2 }'; }
container_state() { timeout 10 waydroid status 2>/dev/null | awk -F':[ \t]+' '$1 == "Container" { print $2 }'; }
# The same as one word, fast: Android's container is an LXC cgroup whose cgroup.events says
# whether it's frozen, which takes no time, while each `waydroid status` takes ~0.4 s. Falls back
# to Waydroid where the cgroup lives elsewhere.
WAYDROID_CGROUP=/sys/fs/cgroup/lxc.payload.waydroid
wd_state() { # RUNNING, FROZEN or STOPPED
  if [[ -r $WAYDROID_CGROUP/cgroup.events ]]; then
    if grep -qx 'frozen 1' "$WAYDROID_CGROUP/cgroup.events"; then echo FROZEN; else echo RUNNING; fi
  elif [[ $(session_state) == RUNNING ]]; then
    container_state
  else
    echo STOPPED
  fi
}
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

# Connect our adb to Waydroid's Android and print its serial. $1 = seconds to keep trying.
# Android's address rarely changes, so the last one is tried first (asking Waydroid takes ~0.4 s).
wd_connect() {
  local serial st try deadline=$((SECONDS + ${1:-20})) cache=$STATE_DIR/android.serial
  kfl_adb start-server >/dev/null 2>&1 || return 1
  serial=$(cat "$cache" 2>/dev/null || true)
  while :; do
    if [[ $serial =~ ^[0-9.]+:5555$ ]]; then
      for try in 1 2; do
        st=$(HOME=$ADB_HOME timeout 5 "$(adb_bin)" -s "$serial" get-state 2>/dev/null 9>&- || true)
        if [[ $st == device ]]; then
          [[ $(cat "$cache" 2>/dev/null) == "$serial" ]] || { mkdir -p "$STATE_DIR" && echo "$serial" >"$cache"; }
          echo "$serial"
          return 0
        fi
        ((try == 1)) || break
        [[ $st != offline ]] || kfl_adb disconnect "$serial" >/dev/null 2>&1 || true
        HOME=$ADB_HOME timeout 5 "$(adb_bin)" connect "$serial" >/dev/null 2>&1 9>&- || true
      done
    fi
    ((SECONDS < deadline)) || return 1
    sleep 0.5
    serial=$(android_ip):5555
  done
}

# The desktop's scale factor (e.g. 1.6), asked of the compositor (or X11's Xft.dpi); nothing if it
# can't be found. Waydroid on Wayland knows it by itself; the emulator and X11 need it to draw
# Kindle at the right size and sharpness.
display_scale() {
  local s=""
  if [[ $(display_mode) == x11 ]]; then
    if command -v xrdb >/dev/null; then
      s=$(xrdb -query 2>/dev/null | awk '/^Xft\.dpi:/ { if ($2 > 0) printf "%.3f\n", $2 / 96; exit }')
    fi
    [[ -n $s ]] || s=${GDK_SCALE:-${QT_SCALE_FACTOR:-}}
  elif [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] && command -v hyprctl >/dev/null; then
    s=$(hyprctl monitors -j 2>/dev/null | python3 -c 'import json, sys
m = json.load(sys.stdin); f = [x for x in m if x.get("focused")] or m
print(f[0]["scale"])' 2>/dev/null)
  elif [[ -n ${SWAYSOCK:-} ]] && command -v swaymsg >/dev/null; then
    s=$(swaymsg -t get_outputs -r 2>/dev/null | python3 -c 'import json, sys
m = [x for x in json.load(sys.stdin) if x.get("active")]; f = [x for x in m if x.get("focused")] or m
print(f[0]["scale"])' 2>/dev/null)
  elif [[ ${XDG_CURRENT_DESKTOP:-} == *KDE* ]] && command -v kscreen-doctor >/dev/null; then
    s=$(kscreen-doctor -j 2>/dev/null | python3 -c 'import json, sys
m = [x for x in json.load(sys.stdin)["outputs"] if x.get("enabled")]; f = [x for x in m if x.get("priority") == 1] or m
print(f[0]["scale"])' 2>/dev/null)
  elif [[ ${XDG_CURRENT_DESKTOP:-} == *GNOME* ]] && command -v gdbus >/dev/null; then
    # Mutter's logical monitors are (x, y, scale, transform, primary, ...): take the primary's.
    s=$(gdbus call --session --dest org.gnome.Mutter.DisplayConfig --object-path /org/gnome/Mutter/DisplayConfig \
      --method org.gnome.Mutter.DisplayConfig.GetCurrentState 2>/dev/null | python3 -c 'import re, sys
m = re.findall(r"\(-?\d+, -?\d+, ([\d.]+), uint32 \d+, (true|false)", sys.stdin.read())
f = [x for x in m if x[1] == "true"] or m
print(f[0][0])' 2>/dev/null)
  elif command -v wlr-randr >/dev/null; then
    s=$(wlr-randr --json 2>/dev/null | python3 -c 'import json, sys
m = [x for x in json.load(sys.stdin) if x.get("enabled")]
print(m[0]["scale"])' 2>/dev/null)
  fi
  [[ $s =~ ^[0-9]+(\.[0-9]+)?$ ]] && echo "$s"
}

# The desktop's light/dark preference: "dark", "light", or nothing if it can't tell. Asked of the
# XDG desktop portal first, which GNOME, KDE, Hyprland, Sway, Cinnamon and others all answer
# (color-scheme: 1 = prefer dark, 2 = prefer light, 0 = no preference), then of GNOME's and
# KDE's own settings.
PORTAL=(--session --dest org.freedesktop.portal.Desktop --object-path /org/freedesktop/portal/desktop)
desktop_color_scheme() {
  local v="" k nopref=""
  if command -v gdbus >/dev/null; then
    v=$(timeout 3 gdbus call "${PORTAL[@]}" --method org.freedesktop.portal.Settings.ReadOne \
      org.freedesktop.appearance color-scheme 2>/dev/null ||
      timeout 3 gdbus call "${PORTAL[@]}" --method org.freedesktop.portal.Settings.Read \
        org.freedesktop.appearance color-scheme 2>/dev/null || true)
    case $v in
      *"uint32 1"*) echo dark && return ;;
      *"uint32 2"*) echo light && return ;;
      *"uint32 0"*) nopref=1 ;;
    esac
  fi
  if command -v gsettings >/dev/null; then
    v=$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null || true)
    case $v in
      *dark*) echo dark && return ;;
      *light*) echo light && return ;;
      *default*) nopref=1 ;;
    esac
    v=$(gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null || true)
    if [[ ${v,,} == *dark* ]]; then echo dark && return; fi
  fi
  for k in kreadconfig6 kreadconfig5; do
    command -v "$k" >/dev/null || continue
    v=$("$k" --group General --key ColorScheme 2>/dev/null || true)
    if [[ ${v,,} == *dark* ]]; then echo dark && return; fi
    if [[ -n $v ]]; then echo light && return; fi
  done
  # "No preference" and nothing dark anywhere: that's a light desktop.
  [[ -z $nopref ]] || echo light
}

# Kindle follows Android's dark mode; make Android's match the desktop. Android is only asked
# when the desktop's preference differs from what was last set. $1 = adb serial.
match_color_scheme() {
  local want
  want=$(desktop_color_scheme)
  case $want in
    dark) want=yes ;;
    light) want=no ;;
    *) return 0 ;;
  esac
  [[ $(state_get "night_$BACKEND") != "$want" ]] || return 0
  if kfl_adb -s "$1" shell cmd uimode night "$want" >/dev/null 2>&1; then state_set "night_$BACKEND" "$want"; fi
}

# While Kindle's window is open, follow the desktop switching between light and dark (the portal
# announces it). Runs until killed. $1 = adb serial.
follow_color_scheme() {
  command -v gdbus >/dev/null || return 0
  gdbus monitor "${PORTAL[@]}" 2>/dev/null | while read -r line; do
    [[ $line != *SettingChanged*org.freedesktop.appearance*color-scheme* ]] || match_color_scheme "$1"
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

# Start Waydroid's Android in the background (if it isn't running) and wait until it has booted.
# $1 = seconds to wait. The session outlives this script: it keeps running until logout or
# `kindle --stop`, frozen while Kindle's window is closed.
wd_start() {
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

wd_stop() {
  [[ $(session_state) == RUNNING ]] || return 0
  waydroid session stop >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 30); do
    [[ $(session_state) == RUNNING ]] || return 0
    sleep 1
  done
}

# --- The emulator backend ---------------------------------------------------------------------

emu_env() {
  env HOME="$ADB_HOME" ANDROID_SDK_ROOT="$EMU_SDK" ANDROID_HOME="$EMU_SDK" ANDROID_AVD_HOME="$EMU_AVD_HOME" \
    ANDROID_EMULATOR_HOME="$ADB_HOME/.android" "$@"
}
# The emulator's process (the launcher before exec, then QEMU): its path starts with our SDK.
emu_pid() { pgrep -u "$UID" -f "^$EMU_SDK/emulator/(emulator( |$)|qemu/)" | head -n1 || true; }
# Is the running emulator showing its own window (sign-in), rather than running headless?
emu_windowed() {
  local p cmd
  p=$(emu_pid)
  [[ -n $p ]] && cmd=$(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null || true) && [[ -n $cmd && " $cmd " != *" -no-window "* ]]
}
emu_console() { ADB_TIMEOUT=10 kfl_adb -s "$EMU_SERIAL" emu "$@" 2>/dev/null | tr -d '\r'; }
emu_state() {
  [[ -n $(emu_pid) ]] || {
    echo STOPPED
    return
  }
  if [[ $(emu_console avd status) == *stopped* ]]; then echo FROZEN; else echo RUNNING; fi
}
emu_booted() { [[ $(ADB_TIMEOUT=5 kfl_adb -s "$EMU_SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r') == 1 ]]; }
# GPU: software rendering (SwiftShader) on NVIDIA, where the emulator's host-GPU mode has crashed
# in NVIDIA's driver; the host GPU elsewhere. KINDLE_EMULATOR_GPU overrides.
emu_gpu() {
  if [[ -n ${KINDLE_EMULATOR_GPU:-} ]]; then
    echo "$KINDLE_EMULATOR_GPU"
  elif [[ -e /proc/driver/nvidia/version ]]; then
    echo swiftshader_indirect
  else
    echo host
  fi
}
emu_start() { # $1 = seconds to wait for the boot; EMU_WINDOW=1 shows the emulator's own window
  local deadline=$((SECONDS + ${1:-180})) log=$STATE_DIR/emulator.log window=(-no-window) launched=0
  mkdir -p "$STATE_DIR"
  kfl_adb start-server >/dev/null 2>&1 || true
  [[ ${EMU_WINDOW:-} != 1 ]] || window=()
  if [[ -z $(emu_pid) ]]; then
    # A full boot every time: snapshots would have to be saved on every exit, which takes
    # 20-40 s and is cut short at logout. Audio stays on for read-aloud and audiobooks.
    emu_env setsid -f "$EMU_SDK/emulator/emulator" -avd "$EMU_AVD" "${window[@]}" -no-snapshot -no-boot-anim \
      -no-metrics -skip-adb-auth -ports "$EMU_CONSOLE_PORT,$((EMU_CONSOLE_PORT + 1))" -gpu "$(emu_gpu)" \
      -camera-back none -camera-front none >"$log" 2>&1 </dev/null 9>&-
    launched=1
  elif [[ $(emu_state) == FROZEN ]]; then
    emu_console avd start >/dev/null
  fi
  if ((launched)); then
    # setsid -f returns right after fork(), before its child finishes execing the emulator.
    local grace=$((SECONDS + 5))
    while [[ -z $(emu_pid) ]] && ((SECONDS < grace)); do
      sleep 0.05
    done
  fi
  until emu_booted; do
    ((SECONDS < deadline)) || return 1
    [[ -n $(emu_pid) ]] || return 1 # it quit: see emulator.log
    sleep 1
  done
  # Android's own screen is never shown (Kindle has its own): keep it tiny, so whatever is drawn
  # there costs next to nothing. Sign-in shows it at full size.
  if [[ ${EMU_WINDOW:-} == 1 ]]; then
    kfl_adb -s "$EMU_SERIAL" shell wm size reset >/dev/null 2>&1 || true
  else
    kfl_adb -s "$EMU_SERIAL" shell wm size 160x100 >/dev/null 2>&1 || true
  fi
}
# A clean Android power-off (so recent writes, like a sign-in or a reading position, reach the
# disk), then the emulator exits; it's killed only if that doesn't happen within 40 s.
emu_stop() {
  [[ -n $(emu_pid) ]] || return 0
  [[ $(emu_state) != FROZEN ]] || emu_console avd start >/dev/null
  ADB_TIMEOUT=10 kfl_adb -s "$EMU_SERIAL" shell reboot -p >/dev/null 2>&1 || true
  local i pid
  for i in $(seq 1 40); do
    pid=$(emu_pid)
    [[ -n $pid ]] || return 0
    ((i != 30)) || emu_console kill >/dev/null || true
    sleep 1
  done
  kill "$pid" 2>/dev/null || true
}

# --- Either backend ----------------------------------------------------------------------------

# RUNNING, FROZEN (paused: no CPU use) or STOPPED.
android_state() { if [[ $BACKEND == emulator ]]; then emu_state; else wd_state; fi; }
# Start Android if needed and wait until it has booted. $1 = seconds to wait.
start_android() { if [[ $BACKEND == emulator ]]; then emu_start "$@"; else wd_start "$@"; fi; }
stop_android() { if [[ $BACKEND == emulator ]]; then emu_stop; else wd_stop; fi; }
# Pause Android while Kindle's window is closed, and resume it.
android_sleep() {
  if [[ $BACKEND == emulator ]]; then
    [[ -z $(emu_pid) ]] || emu_console avd stop >/dev/null
  else
    container_call Freeze || true
  fi
}
android_wake() {
  if [[ $BACKEND == emulator ]]; then
    [[ $(emu_state) != FROZEN ]] || emu_console avd start >/dev/null
  else
    [[ $(wd_state) != FROZEN ]] || container_call Unfreeze || true
  fi
}
# Connect our adb to Android and print its serial. $1 = seconds to keep trying (default 20).
android_connect() {
  if [[ $BACKEND == emulator ]]; then
    local deadline=$((SECONDS + ${1:-20})) st
    kfl_adb start-server >/dev/null 2>&1 || return 1
    st=$(HOME=$ADB_HOME timeout 5 "$(adb_bin)" -s "$EMU_ADB_TCP" get-state 2>/dev/null 9>&- || true)
    if [[ $st == device ]]; then
      echo "$EMU_ADB_TCP"
      return 0
    fi
    [[ $st != offline ]] || kfl_adb disconnect "$EMU_ADB_TCP" >/dev/null 2>&1 || true
    until [[ $(ADB_TIMEOUT=5 kfl_adb -s "$EMU_SERIAL" get-state 2>/dev/null) == device ]]; do
      ((SECONDS < deadline)) || return 1
      sleep 0.5
    done
    if emu_console redir list | grep -qE "(^|[[:space:]])tcp:${EMU_ADB_TCP_PORT}[[:space:]]" ||
      [[ $(emu_console redir add "tcp:$EMU_ADB_TCP_PORT:5555") == *OK* ]]; then
      HOME=$ADB_HOME timeout 5 "$(adb_bin)" connect "$EMU_ADB_TCP" >/dev/null 2>&1 9>&- || true
      if [[ $(HOME=$ADB_HOME timeout 5 "$(adb_bin)" -s "$EMU_ADB_TCP" get-state 2>/dev/null 9>&- || true) == device ]]; then
        echo "$EMU_ADB_TCP"
        return 0
      fi
    fi
    echo "$EMU_SERIAL"
  else
    wd_connect "$@"
  fi
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
  [[ $BACKEND == waydroid ]] || return 0
  [[ -f $WAYDROID_DESKTOP ]] || return 0
  grep -q '^NoDisplay=true' "$WAYDROID_DESKTOP" && return 0
  sed -i '/^NoDisplay=/d; /^\[Desktop Entry\]/a NoDisplay=true' "$WAYDROID_DESKTOP"
}
