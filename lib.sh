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
#   emulator  Google's Android emulator (KVM), for NVIDIA-only computers or VMs without a 3D GPU.
#             It runs Google's "Google APIs" Android 15 image: the Google-free images have no ARM
#             translation, and Kindle is ARM-only.
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

# key=value state that install.sh records and uninstall.sh/kindle read back.
# Pure bash with atomic rename so concurrent readers/writers never race or spawn sed/tail.
state_get() {
  [[ -f $STATE_FILE ]] || return 0
  local line val=""
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line != "$1="* ]] || val=${line#*=}
  done <"$STATE_FILE"
  [[ -z $val ]] || printf '%s\n' "$val"
}
state_set() {
  mkdir -p "$STATE_DIR"
  local line tmp=$STATE_DIR/.state.$$
  {
    if [[ -f $STATE_FILE ]]; then
      while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == "$1="* ]] || printf '%s\n' "$line"
      done <"$STATE_FILE"
    fi
    [[ -z $2 ]] || printf '%s=%s\n' "$1" "$2"
  } >"$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

BACKEND=${KINDLE_BACKEND:-$(state_get backend)}
BACKEND=${BACKEND:-waydroid}

# --- Hardware & VM detection ------------------------------------------------------------------

in_vm() {
  if command -v systemd-detect-virt >/dev/null; then
    systemd-detect-virt -vq 2>/dev/null
  else
    grep -q '^flags[[:space:]]*:.* hypervisor' /proc/cpuinfo 2>/dev/null
  fi
}

# Resolve a DRM sysfs node's real driver name (following virtio-pci -> child virtioN/uevent on
# QEMU virtio-vga) and print "<driver> <virtio_features_file_or_empty>".
_drm_node_info() { # $1 = /sys/class/drm/cardN or renderDN
  local dev=$1/device line drv="" feat="" vsub
  [[ -r $dev/uevent ]] || return 1
  while IFS= read -r line; do
    [[ $line != DRIVER=* ]] || drv=${line#DRIVER=}
  done <"$dev/uevent"
  if [[ $drv == virtio-pci ]]; then
    for vsub in "$dev"/virtio*; do
      [[ -r $vsub/uevent ]] || continue
      while IFS= read -r line; do
        [[ $line != DRIVER=* ]] || drv=${line#DRIVER=}
      done <"$vsub/uevent"
      [[ ! -r $vsub/features ]] || feat=$vsub/features
      break
    done
  elif [[ -r $dev/features ]]; then
    feat=$dev/features
  fi
  [[ -n $drv ]] && printf '%s %s\n' "$drv" "$feat"
}

# True when a virtio_gpu render node has 3D acceleration (VirGL) enabled on the host.
virtio_has_3d() {
  local node drv feat
  for node in /sys/class/drm/renderD*; do
    read -r drv feat <<<"$(_drm_node_info "$node" || true)"
    [[ $drv == virtio_gpu || $drv == virtio-pci ]] || continue
    # Linux's virtio core exposes negotiated feature bits (LSB-first) in sysfs; bit 0 is
    # VIRTIO_GPU_F_VIRGL (3D acceleration). World-readable, no render-group or Python needed.
    if [[ -n $feat && -r $feat ]]; then
      [[ $(<"$feat") == 1* ]] && return 0
      continue
    fi
    command -v python3 >/dev/null || continue
    python3 -c '
import ctypes, fcntl, os, struct, sys
try:
    fd = os.open(sys.argv[1], os.O_RDWR)
    try:
        val = ctypes.c_int(0)
        buf = bytearray(struct.pack("QQ", 1, ctypes.addressof(val))) # VIRTGPU_PARAM_3D_FEATURES
        fcntl.ioctl(fd, 0xc0106443, buf)                             # DRM_IOCTL_VIRTGPU_GETPARAM
        sys.exit(0 if val.value else 1)
    finally:
        os.close(fd)
except OSError:
    sys.exit(1)
' "/dev/dri/${node##*/}" 2>/dev/null && return 0
  done
  return 1
}

# True when a virtio_gpu render node exposes Vulkan context-init (Venus / Rutabaga, feature bit 4).
virtio_has_vulkan() {
  local node drv feat bits
  for node in /sys/class/drm/renderD*; do
    read -r drv feat <<<"$(_drm_node_info "$node" || true)"
    [[ $drv == virtio_gpu || $drv == virtio-pci ]] || continue
    [[ -n $feat && -r $feat ]] || continue
    bits=$(<"$feat")
    [[ ${bits:4:1} == 1 ]] && return 0
  done
  return 1
}

# All DRM drivers present on render or display nodes (for diagnostics, including 2D VM framebuffers).
gpu_drivers_list() {
  local node drv seen=" " drvs=()
  for node in /sys/class/drm/renderD* /sys/class/drm/card[0-9]*; do
    read -r drv _ <<<"$(_drm_node_info "$node" || true)"
    [[ -n $drv ]] || continue
    if [[ $seen != *" $drv "* ]]; then
      seen+="$drv "
      drvs+=("$drv")
    fi
  done
  echo "${drvs[*]}"
}

# First render-node GPU driver that Waydroid's Android (Mesa GBM/EGL) can hardware-render on.
waydroid_gpu_driver() {
  local node drv
  for node in /sys/class/drm/renderD*; do
    read -r drv _ <<<"$(_drm_node_info "$node" || true)"
    [[ -n $drv ]] || continue
    case $drv in
      nvidia | nouveau | vmwgfx | bochs | bochs-drm | cirrus | qxl | vboxvideo | simpledrm | vkms | udl | evdi | vgem | hyperv_drm | ast | mgag200 | gm12u320 | gud | repaper | virtio-pci) continue ;;
      virtio_gpu) virtio_has_3d || continue ;;
    esac
    echo "$drv"
    return 0
  done
}

# --- Waydroid backend -------------------------------------------------------------------------

# "RUNNING", "FROZEN" or "STOPPED" (from `waydroid status`, whose lines are "Key:<tab>Value").
session_state() { timeout 10 waydroid status 2>/dev/null | awk -F':[ \t]+' '$1 == "Session" { print $2 }'; }
container_state() { timeout 10 waydroid status 2>/dev/null | awk -F':[ \t]+' '$1 == "Container" { print $2 }'; }
# Find Waydroid's LXC cgroup v2 directory (direct or nested under systemd's slice).
wd_cgroup_dir() {
  local p
  for p in /sys/fs/cgroup/lxc.payload.waydroid \
    /sys/fs/cgroup/system.slice/waydroid-container.service/lxc.payload.waydroid; do
    [[ -r $p/cgroup.events ]] && { echo "$p"; return 0; }
  done
  p=$(find /sys/fs/cgroup -maxdepth 3 -type d -name 'lxc.payload.waydroid' 2>/dev/null | awk 'NR == 1 { print; exit }')
  [[ -n $p && -r $p/cgroup.events ]] && echo "$p"
}
# The same as one word, fast: Android's container is an LXC cgroup whose cgroup.events says
# whether it's populated and frozen, which takes no time, while each `waydroid status` takes ~0.4 s.
wd_state() { # RUNNING, FROZEN or STOPPED
  local cg k v pop=0 frz=0
  cg=$(wd_cgroup_dir || true)
  if [[ -n $cg ]]; then
    while read -r k v; do
      case $k in
        populated) pop=$v ;;
        frozen) frz=$v ;;
      esac
    done <"$cg/cgroup.events"
    if ((pop == 0)); then
      echo STOPPED
    elif ((frz == 1)); then
      echo FROZEN
    else
      echo RUNNING
    fi
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

_KFL_SCRCPY=""
_KFL_ADB=""
scrcpy_bin() {
  if [[ -x $SCRCPY_DIR/scrcpy ]]; then
    echo "$SCRCPY_DIR/scrcpy"
    return 0
  fi
  [[ -n $_KFL_SCRCPY ]] || _KFL_SCRCPY=$(command -v scrcpy || true)
  [[ -n $_KFL_SCRCPY ]] && echo "$_KFL_SCRCPY"
}
adb_bin() {
  if [[ -x $SCRCPY_DIR/adb ]]; then
    echo "$SCRCPY_DIR/adb"
    return 0
  fi
  [[ -n $_KFL_ADB ]] || _KFL_ADB=$(command -v adb || true)
  [[ -n $_KFL_ADB ]] && echo "$_KFL_ADB"
}
# adb with our key: a server it starts reads $ADB_HOME/.android/adbkey.
# Time-limited: adb waits forever on an Android that is frozen. `9>&-` (here and wherever a
# background process may start) keeps the launcher's window lock out of long-lived processes
# such as the adb server, which would otherwise hold it after the window closes.
kfl_adb() {
  local bin=$SCRCPY_DIR/adb
  if [[ ! -x $bin ]]; then
    [[ -n $_KFL_ADB ]] || _KFL_ADB=$(command -v adb)
    bin=$_KFL_ADB
  fi
  HOME=$ADB_HOME timeout "${ADB_TIMEOUT:-30}" "$bin" "$@" 9>&-
}

# Connect our adb to Waydroid's Android and print its serial. $1 = seconds to keep trying.
# Android's address rarely changes, so the last one is tried first (asking Waydroid takes ~0.4 s).
wd_connect() {
  local serial st try deadline=$((SECONDS + ${1:-20})) cache=$STATE_DIR/android.serial adb
  adb=$(adb_bin) || return 1
  serial=$(<"$cache" 2>/dev/null) || serial=""
  while :; do
    if [[ $serial =~ ^[0-9.]+:5555$ ]]; then
      for try in 1 2; do
        st=$(HOME=$ADB_HOME timeout 5 "$adb" -s "$serial" get-state 2>/dev/null 9>&- || true)
        if [[ $st == device ]]; then
          [[ $(<"$cache" 2>/dev/null) == "$serial" ]] || { mkdir -p "$STATE_DIR" && echo "$serial" >"$cache"; }
          echo "$serial"
          return 0
        fi
        ((try == 1)) || break
        [[ $st != offline ]] || kfl_adb disconnect "$serial" >/dev/null 2>&1 || true
        HOME=$ADB_HOME timeout 5 "$adb" connect "$serial" >/dev/null 2>&1 9>&- || true
      done
    fi
    ((SECONDS < deadline)) || return 1
    sleep 0.3
    serial=$(android_ip):5555
  done
}

# Extract "scale" from a JSON list of monitor objects (POSIX awk, works on minified or pretty JSON).
# $1 = object brace depth (1 for top-level array, 2 for {"outputs":[...]}), $2 = required regex, $3 = preferred regex.
json_monitor_scale() {
  awk -v target_d="$1" -v req="$2" -v pref="$3" '
    {
      gsub(/[{},]/, "\n&\n")
      n = split($0, tok, "\n")
      for (i = 1; i <= n; i++) {
        t = tok[i]
        if (t == "{") {
          d++
          if (d == target_d) { sc = ""; ok = (req == ""); best = 0 }
        } else if (t == "}") {
          if (d == target_d && ok && sc != "") {
            if (first == "") first = sc
            if (best && chosen == "") chosen = sc
          }
          d--
        } else if (d == target_d) {
          if (t ~ /"scale"[[:space:]]*:/) {
            sub(/.*"scale"[[:space:]]*:[[:space:]]*/, "", t)
            sub(/[^0-9.].*/, "", t)
            sc = t
          } else if (req != "" && t ~ req) {
            ok = 1
          } else if (pref != "" && t ~ pref) {
            best = 1
          }
        }
      }
    }
    END { if (chosen != "") print chosen; else if (first != "") print first }
  '
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
  elif [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] && command -v hyprctl >/dev/null; then
    s=$(hyprctl monitors -j 2>/dev/null | json_monitor_scale 1 '' '"focused"[[:space:]]*:[[:space:]]*true' || true)
  elif [[ -n ${SWAYSOCK:-} ]] && command -v swaymsg >/dev/null; then
    s=$(swaymsg -t get_outputs -r 2>/dev/null | json_monitor_scale 1 '"active"[[:space:]]*:[[:space:]]*true' '"focused"[[:space:]]*:[[:space:]]*true' || true)
  elif [[ ${XDG_CURRENT_DESKTOP:-} == *KDE* ]] && command -v kscreen-doctor >/dev/null; then
    s=$(kscreen-doctor -j 2>/dev/null | json_monitor_scale 2 '"enabled"[[:space:]]*:[[:space:]]*true' '"priority"[[:space:]]*:[[:space:]]*1([^0-9]|$)' || true)
  elif [[ ${XDG_CURRENT_DESKTOP:-} == *GNOME* ]] && command -v gdbus >/dev/null; then
    # Mutter's logical monitors are (x, y, scale, transform, primary, ...): take the primary's.
    s=$(gdbus call --session --dest org.gnome.Mutter.DisplayConfig --object-path /org/gnome/Mutter/DisplayConfig \
      --method org.gnome.Mutter.DisplayConfig.GetCurrentState 2>/dev/null |
      sed 's/)/\n/g' |
      sed -n 's/.*(-*[0-9][0-9]*, -*[0-9][0-9]*, \([0-9.][0-9.]*\), uint32 [0-9][0-9]*, \(true\|false\).*/\2 \1/p' |
      awk 'NR == 1 { first = $2 } $1 == "true" { print $2; found = 1; exit } END { if (!found && first != "") print first }' || true)
  elif command -v wlr-randr >/dev/null; then
    s=$(wlr-randr --json 2>/dev/null | json_monitor_scale 1 '"enabled"[[:space:]]*:[[:space:]]*true' '' || true)
  fi
  [[ -n $s ]] || s=${GDK_SCALE:-${QT_SCALE_FACTOR:-}}
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
# when the desktop's preference differs from what was last set. $1 = adb serial, [$2 = yes|no].
match_color_scheme() {
  local want=${2:-}
  if [[ -z $want ]]; then
    case $(desktop_color_scheme) in
      dark) want=yes ;;
      light) want=no ;;
      *) return 0 ;;
    esac
  fi
  [[ $(state_get "night_$BACKEND") != "$want" ]] || return 0
  if kfl_adb -s "$1" shell cmd uimode night "$want" >/dev/null 2>&1; then state_set "night_$BACKEND" "$want"; fi
}

# While Kindle's window is open, follow the desktop switching between light and dark (the portal
# announces it). Runs until killed. $1 = adb serial.
follow_color_scheme() {
  command -v gdbus >/dev/null || return 0
  local mpid="" fd="" line
  # shellcheck disable=SC2329
  _stop_monitor() {
    [[ -z $mpid ]] || kill "$mpid" 2>/dev/null || true
    [[ -z $fd ]] || exec {fd}<&- 2>/dev/null || true
  }
  trap _stop_monitor EXIT
  trap 'exit 0' INT TERM HUP
  exec {fd}< <(exec gdbus monitor "${PORTAL[@]}" 2>/dev/null)
  mpid=$!
  while IFS= read -r -u "$fd" line; do
    [[ $line == *SettingChanged*org.freedesktop.appearance*color-scheme* ]] || continue
    case $line in
      *"uint32 1"*) match_color_scheme "$1" yes ;;
      *"uint32 2"*) match_color_scheme "$1" no ;;
      *) match_color_scheme "$1" ;;
    esac
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
    sleep 0.5
  done
}

# --- The emulator backend ---------------------------------------------------------------------

emu_env() {
  local extra=()
  if [[ ${KINDLE_AUDIO:-0} == 1 ]]; then
    [[ ! -f $HOME/.pulse-cookie ]] || extra+=(PULSE_COOKIE="${PULSE_COOKIE:-$HOME/.pulse-cookie}")
    [[ ! -f $HOME/.config/pulse/cookie ]] || extra+=(PULSE_COOKIE="${PULSE_COOKIE:-$HOME/.config/pulse/cookie}")
  fi
  env HOME="$ADB_HOME" ANDROID_SDK_ROOT="$EMU_SDK" ANDROID_HOME="$EMU_SDK" ANDROID_AVD_HOME="$EMU_AVD_HOME" \
    ANDROID_EMULATOR_HOME="$ADB_HOME/.android" "${extra[@]}" "$@"
}
# The emulator's process (the launcher before exec, then QEMU): read QEMU's lockfile first (no
# /proc scan), falling back to pgrep while starting up.
emu_pid() {
  local lock=$EMU_AVD_HOME/$EMU_AVD.avd/hardware-qemu.ini.lock real_emu p="" cmd="" list
  real_emu=$(readlink -f "$EMU_SDK/emulator" 2>/dev/null || echo "$EMU_SDK/emulator")
  if [[ -r $lock ]]; then
    { read -r p _ <"$lock"; } 2>/dev/null || true
    if [[ $p =~ ^[0-9]+$ && -r /proc/$p/cmdline ]]; then
      cmd=$({ tr '\0' ' ' <"/proc/$p/cmdline"; } 2>/dev/null || true)
      if [[ $cmd == "$EMU_SDK/emulator/"* || $cmd == "$real_emu/"* ]]; then
        echo "$p"
        return 0
      fi
    fi
  fi
  list=$(pgrep -u "$UID" -f "/emulator/(emulator( |$)|qemu/)" 2>/dev/null || true)
  for p in $list; do
    cmd=$({ tr '\0' ' ' <"/proc/$p/cmdline"; } 2>/dev/null || true)
    if [[ $cmd == "$EMU_SDK/emulator/"* || $cmd == "$real_emu/"* ]]; then
      echo "$p"
      return 0
    fi
  done
}
# Is the running emulator showing its own window (sign-in), rather than running headless?
emu_windowed() {
  local p cmd
  p=$(emu_pid)
  [[ -n $p ]] && cmd=$({ tr '\0' ' ' <"/proc/$p/cmdline"; } 2>/dev/null || true) && [[ -n $cmd && " $cmd " != *" -no-window "* ]]
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

# Guest RAM size (MB) for the emulator AVD, scaled to host memory so 4 GB VMs don't OOM while
# larger hosts save ~1 GB of RSS compared with Android 15's 2560 MB default.
avd_ram_mb() {
  if [[ ${KINDLE_EMULATOR_RAM:-} =~ ^[0-9]+$ && ${KINDLE_EMULATOR_RAM:-0} -ge 1024 ]]; then
    echo "$KINDLE_EMULATOR_RAM"
    return 0
  fi
  local mem_gb
  mem_gb=$(awk '/^MemTotal:/ { printf "%d", $2 / 1048576 + 0.5 }' /proc/meminfo)
  if ((mem_gb <= 4)); then
    echo 1536
  elif ((mem_gb <= 8)); then
    echo 1792
  else
    echo 1920
  fi
}

# GPU: host hardware Vulkan/GLES when a real, accessible 3D render node exists; SwiftShader
# software rendering on NVIDIA (driver crashes), unaccelerated VMs, VirGL-without-Venus VMs, or
# after a previous `-gpu host` startup failure. KINDLE_EMULATOR_GPU overrides.
emu_gpu() {
  if [[ -n ${KINDLE_EMULATOR_GPU:-} ]]; then
    echo "$KINDLE_EMULATOR_GPU"
    return 0
  fi
  if [[ -e /proc/driver/nvidia/version || $(state_get emu_gpu_fallback) == 1 ]]; then
    echo swiftshader_indirect
    return 0
  fi
  local node dev drv
  for node in /sys/class/drm/renderD*; do
    dev=/dev/dri/${node##*/}
    [[ -r $dev && -w $dev ]] || continue
    read -r drv _ <<<"$(_drm_node_info "$node" || true)"
    [[ -n $drv ]] || continue
    case $drv in
      nvidia | nouveau | vmwgfx | bochs | bochs-drm | cirrus | qxl | vboxvideo | simpledrm | vkms | udl | evdi | vgem | hyperv_drm | ast | mgag200 | gm12u320 | gud | repaper | virtio-pci | virtio_gpu) continue ;;
    esac
    echo host
    return 0
  done
  echo swiftshader_indirect
}

# Switch off Google and AOSP background apps Kindle never uses: saves ~600 MB of guest RSS and
# prevents broadcast wakeups when Android unfreezes. Safe to run repeatedly (guarded by state).
ensure_emulator_trimmed() { # $1 = serial
  [[ $BACKEND == emulator && $(state_get android_trimmed) != 2 ]] || return 0
  # shellcheck disable=SC2016
  kfl_adb -s "$1" shell '
    for pkg in \
      com.google.android.gms com.google.android.gsf com.android.vending \
      com.google.android.googlequicksearchbox com.google.android.apps.wellbeing \
      com.google.android.as com.google.android.as.oss com.google.android.apps.messaging \
      com.google.android.apps.maps com.google.android.apps.photos com.google.android.apps.docs \
      com.google.android.apps.youtube.music com.google.android.gm com.google.android.calendar \
      com.google.android.dialer com.google.android.contacts com.android.chrome \
      com.google.android.apps.restore com.google.android.apps.safetyhub \
      com.google.android.feedback com.google.android.partnersetup \
      com.google.android.tts com.google.android.marvin.talkback \
      com.google.android.settings.intelligence com.google.android.rkpdapp \
      com.android.providers.calendar com.google.android.apps.wallpaper \
      com.google.android.cellbroadcastreceiver com.android.traceur \
      com.google.android.configupdater com.google.android.healthconnect.controller \
      com.android.printspooler com.android.localtransport; do
      pm disable-user --user 0 "$pkg" >/dev/null 2>&1 || true
    done
  ' >/dev/null 2>&1 || return 0
  state_set android_trimmed 2
}

_emu_launch() { # $1 = gpu mode, $2 = ram_mb, $3 = log, rest = window flags
  local gpu=$1 ram_mb=$2 log=$3 audio=(-no-audio)
  shift 3
  [[ ${KINDLE_AUDIO:-0} != 1 ]] || audio=()
  # `-qemu -m` must come last: Android 15's emulator wrapper otherwise bumps guest RAM back up to
  # 2560 MB even when `-memory` and `hw.ramSize` are lower.
  emu_env setsid -f "$EMU_SDK/emulator/emulator" -avd "$EMU_AVD" -memory "$ram_mb" "$@" "${audio[@]}" \
    -no-snapshot -no-boot-anim -no-metrics -crash-report-mode never -no-nested-warnings \
    -no-location-ui -no-sim -no-passive-gps -netfast -skip-adb-auth \
    -ports "$EMU_CONSOLE_PORT,$((EMU_CONSOLE_PORT + 1))" -gpu "$gpu" \
    -camera-back none -camera-front none -qemu -m "$ram_mb" >>"$log" 2>&1 </dev/null 9>&-
  local grace=$((SECONDS + 5))
  while [[ -z $(emu_pid) ]] && ((SECONDS < grace)); do
    sleep 0.05
  done
}

emu_start() { # $1 = seconds to wait for the boot; EMU_WINDOW=1 shows the emulator's own window
  local deadline=$((SECONDS + ${1:-180})) log=$STATE_DIR/emulator.log window=(-no-window) gpu ram_mb cfg
  mkdir -p "$STATE_DIR"
  kfl_adb start-server >/dev/null 2>&1 || true
  [[ ${EMU_WINDOW:-} != 1 ]] || window=()
  gpu=$(emu_gpu)
  ram_mb=$(avd_ram_mb)
  if [[ -z $(emu_pid) ]]; then
    cfg=$EMU_AVD_HOME/$EMU_AVD.avd/config.ini
    if [[ -f $cfg && $(sed -n 's/^hw\.ramSize=//p' "$cfg") != "$ram_mb" ]]; then
      sed -i "s/^hw\\.ramSize=.*/hw.ramSize=$ram_mb/" "$cfg"
    fi
    : >"$log"
    # A full boot every time: snapshots would have to be saved on every exit, which takes
    # 20-40 s and is cut short at logout.
    _emu_launch "$gpu" "$ram_mb" "$log" "${window[@]}"
  elif [[ $(emu_state) == FROZEN ]]; then
    emu_console avd start >/dev/null
  fi
  until emu_booted; do
    ((SECONDS < deadline)) || return 1
    if [[ -z $(emu_pid) ]]; then
      # Self-heal if `-gpu host` failed on a partial/missing Vulkan driver or VM GPU.
      if [[ $gpu == host && -z ${KINDLE_EMULATOR_GPU:-} ]]; then
        printf '\n[kindle] Host GPU rendering failed; retrying with SwiftShader software rendering.\n\n' >>"$log"
        state_set emu_gpu_fallback 1
        gpu=swiftshader_indirect
        _emu_launch "$gpu" "$ram_mb" "$log" "${window[@]}"
        continue
      fi
      return 1 # it quit: see emulator.log
    fi
    sleep 0.3
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
  for i in $(seq 1 80); do
    pid=$(emu_pid)
    [[ -n $pid ]] || return 0
    ((i != 60)) || emu_console kill >/dev/null || true
    sleep 0.5
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
android_wake() { # [$1 = already-known state]
  local cur=${1:-$(android_state)}
  if [[ $BACKEND == emulator ]]; then
    [[ $cur != FROZEN ]] || emu_console avd start >/dev/null
  else
    [[ $cur != FROZEN ]] || container_call Unfreeze || true
  fi
}
# Connect our adb to Android and print its serial. $1 = seconds to keep trying (default 20).
android_connect() {
  if [[ $BACKEND == emulator ]]; then
    local deadline=$((SECONDS + ${1:-20})) st adb
    adb=$(adb_bin) || return 1
    st=$(HOME=$ADB_HOME timeout 5 "$adb" -s "$EMU_ADB_TCP" get-state 2>/dev/null 9>&- || true)
    if [[ $st == device ]]; then
      echo "$EMU_ADB_TCP"
      return 0
    fi
    kfl_adb start-server >/dev/null 2>&1 || return 1
    [[ $st != offline ]] || kfl_adb disconnect "$EMU_ADB_TCP" >/dev/null 2>&1 || true
    until [[ $(ADB_TIMEOUT=5 kfl_adb -s "$EMU_SERIAL" get-state 2>/dev/null) == device ]]; do
      ((SECONDS < deadline)) || return 1
      sleep 0.3
    done
    if emu_console redir list | grep -qE "(^|[[:space:]])tcp:${EMU_ADB_TCP_PORT}[[:space:]]" ||
      [[ $(emu_console redir add "tcp:$EMU_ADB_TCP_PORT:5555") == *OK* ]]; then
      HOME=$ADB_HOME timeout 5 "$adb" connect "$EMU_ADB_TCP" >/dev/null 2>&1 9>&- || true
      if [[ $(HOME=$ADB_HOME timeout 5 "$adb" -s "$EMU_ADB_TCP" get-state 2>/dev/null 9>&- || true) == device ]]; then
        echo "$EMU_ADB_TCP"
        return 0
      fi
      kfl_adb disconnect "$EMU_ADB_TCP" >/dev/null 2>&1 || true
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
