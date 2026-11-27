#!/usr/bin/env bash
# Check a Kindle for Linux install and measure what it costs.
#   ./verify.sh           checks, disk use, memory and idle CPU (asks for your password to size
#                         Android's files, which belong to Android's own users)
#   ./verify.sh --bench   also times opening Kindle (cold, and from frozen), closes and reopens it
#                         3 times, and counts Android crashes meanwhile. On Hyprland it also
#                         fullscreens the window and checks Kindle fills it each time.
set -euo pipefail

here=$(dirname "$(readlink -f "$0")")
# shellcheck source=lib.sh
source "$here/lib.sh"

bench=0
while (($#)); do
  case $1 in
    --bench) bench=1 ;;
    --help | -h)
      printf 'Usage: %s [--bench]\n' "${0##*/}"
      exit 0
      ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done
fails=0
ok() { printf '  \033[32mok\033[0m    %s\n' "$*"; }
bad() {
  printf '  \033[31mFAIL\033[0m  %s\n' "$*"
  fails=$((fails + 1))
}
info() { printf '  ·     %s\n' "$*"; }

say "Install ($BACKEND)"
# Root only sharpens Waydroid's disk sizes (some of Android's files belong to its own users); skip
# it when there's no terminal to ask for a password in (e.g. over SSH).
R=()
if [[ $BACKEND == waydroid ]]; then
  if command -v waydroid >/dev/null; then ok "$(waydroid --version 2>/dev/null | head -n1 || echo waydroid)"; else bad "waydroid isn't installed"; fi
  if grep -qw binder /proc/filesystems || modinfo binder_linux >/dev/null 2>&1; then ok "kernel has binder"; else bad "kernel has no binder"; fi
  if systemctl is-active -q waydroid-container.service; then ok "waydroid-container.service is running"; else bad "waydroid-container.service isn't running"; fi
  if sudo -n true 2>/dev/null || { [[ -t 0 ]] && sudo -v; }; then R=(sudo); fi
  if [[ -f $WAYDROID_CFG ]]; then
    images_path=$(sed -n 's/^images_path = //p' "$WAYDROID_CFG")
    if [[ $images_path == /etc/waydroid-extra/images && -f $images_path/kindle-for-linux.version ]]; then
      ok "Android images: $(<"$images_path/kindle-for-linux.version") (pinned, no Google)"
    elif [[ $(uname -m) == aarch64 && -n $images_path ]]; then
      ok "Android images: $images_path (ARM64 VANILLA)"
    else
      bad "Android images aren't the pinned ones (images_path = ${images_path:-?}); rerun install.sh"
    fi
    if [[ $(uname -m) == x86_64 ]]; then
      bridge=$(sed -n 's/^ro.dalvik.vm.native.bridge = //p' "$WAYDROID_CFG")
      if [[ -n $bridge ]]; then ok "ARM translation: $bridge"; else bad "no ARM translation (Kindle won't run)"; fi
    fi
    egl=$(sed -n 's/^ro.hardware.egl=//p' /var/lib/waydroid/waydroid_base.prop 2>/dev/null || true)
    info "Android's renderer: ${egl:-unknown}"
  else
    bad "Waydroid isn't initialized ($WAYDROID_CFG missing)"
  fi
  if [[ ! -f $WAYDROID_DESKTOP ]] || grep -q '^NoDisplay=true' "$WAYDROID_DESKTOP"; then
    ok "Waydroid's own Kindle entry is hidden (no duplicate in the menu)"
  else
    bad "Waydroid's own Kindle entry is visible too"
  fi
else
  if [[ -r /dev/kvm && -w /dev/kvm ]]; then ok "KVM is usable"; else bad "no access to /dev/kvm"; fi
  v=$(cat "$EMU_SDK/emulator/kindle-for-linux.version" 2>/dev/null || true)
  if [[ -n $v ]]; then ok "Android emulator $v"; else bad "Android emulator missing (rerun install.sh)"; fi
  v=$(cat "$EMU_SDK"/system-images/*/*/*/kindle-for-linux.version 2>/dev/null | head -n1 || true)
  if [[ -n $v ]]; then ok "Android image: $v"; else bad "Android system image missing (rerun install.sh)"; fi
  if [[ -f $EMU_AVD_HOME/$EMU_AVD.avd/config.ini ]]; then
    ok "virtual device: $(sed -n 's/^hw.cpu.ncore=//p' "$EMU_AVD_HOME/$EMU_AVD.avd/config.ini") cores, $(sed -n 's/^hw.ramSize=//p' "$EMU_AVD_HOME/$EMU_AVD.avd/config.ini") MB, GPU mode $(emu_gpu)"
  else
    bad "virtual device missing (rerun install.sh)"
  fi
fi
launcher=$APP_DIR/kindle
[[ $(state_get packaged) != 1 && $here != "$PKG_DIR" ]] || launcher=$PKG_DIR/kindle
desktop_entry=$DESKTOP_FILE
[[ -f $desktop_entry ]] || desktop_entry=/usr/share/applications/kindle-for-linux.desktop
if [[ -x $launcher && -f $desktop_entry ]]; then ok "launcher and menu entry installed ($(sed -n 's/^Name=//p' "$desktop_entry" | head -n1))"; else bad "launcher or menu entry missing"; fi
if [[ -f $KINDLE_ICON ]]; then ok "icon: $KINDLE_ICON"; else bad "no icon for Kindle"; fi
if [[ -n $(scrcpy_bin) ]]; then ok "$("$(scrcpy_bin)" --version 2>/dev/null | head -n1 | cut -d' ' -f1-2) ($(scrcpy_bin))"; else bad "scrcpy missing (Kindle's window)"; fi
if [[ $BACKEND == emulator || -f $ADB_HOME/.android/adbkey ]]; then ok "adb key for Android in $ADB_HOME"; else bad "no adb key (rerun setup)"; fi
secure_srv=$here/scrcpy-server/scrcpy-server-secure
[[ -f $secure_srv ]] || secure_srv=$SCRCPY_DIR/scrcpy-server-secure
adb_sys=$here/scrcpy-server/adb-system
[[ -x $adb_sys ]] || adb_sys=$APP_DIR/adb-system
if [[ $BACKEND == waydroid ]]; then
  has_rc=0
  if [[ -f /var/lib/waydroid/overlay/system/etc/init/kfl-scrcpy.rc ]] ||
    { ((${#R[@]})) && "${R[@]}" test -f /var/lib/waydroid/overlay/system/etc/init/kfl-scrcpy.rc 2>/dev/null; } ||
    [[ $(state_get waydroid_signin_service) == 1 ]]; then
    has_rc=1
  fi
  if [[ -f $secure_srv && $has_rc == 1 && -x $adb_sys ]]; then
    ok "sign-in service in Waydroid's overlay (Amazon sign-in shows in Kindle's window)"
  else
    info "no sign-in overlay service: signing in uses a separate window"
  fi
elif [[ -f $secure_srv ]]; then
  ok "patched scrcpy server for signing in inside Kindle's window"
else
  info "no patched scrcpy server: signing in uses a separate window"
fi
if [[ $(state_get "signed_in_$BACKEND") == 1 ]]; then ok "signed in to Amazon"; else info "not signed in yet: opening Kindle shows Amazon's sign-in page"; fi

say "Android"
state=$(android_state)
info "state: $state"
serial=""
if [[ $state != STOPPED ]]; then
  [[ $state != FROZEN ]] || android_wake
  if serial=$(android_connect 20); then
    ok "adb reaches Android ($serial)"
    if [[ $(kfl_adb -s "$serial" shell pm path "$KINDLE_PKG" 2>/dev/null) == package:* ]]; then
      ok "Kindle is installed ($(kfl_adb -s "$serial" shell dumpsys package "$KINDLE_PKG" | awk -F= '/^ *versionName=/ { if (!v) v = $2 } END { print v }'))"
    else
      bad "Kindle isn't installed"
    fi
    overrides=$(kfl_adb -s "$serial" shell dumpsys platform_compat 2>/dev/null |
      grep -cE "(OVERRIDE_ANY_ORIENTATION|OVERRIDE_UNDEFINED_ORIENTATION_TO_NOSENSOR);.*$KINDLE_PKG=true" || true)
    if ((overrides == 2)); then ok "Kindle follows the window's shape (orientation overrides set)"; else bad "orientation overrides missing: Kindle letterboxes in wide windows (rerun install.sh)"; fi
    info "screen sleep: $(kfl_adb -s "$serial" shell settings get system screen_off_timeout | tr -d '\r') ms, Android's own screen $(kfl_adb -s "$serial" shell wm size | tr -d '\r' | tail -n1 | sed 's/.*: //')"
  else
    bad "adb can't reach Android"
  fi
  if [[ $BACKEND == waydroid ]]; then
    for prop in persist.waydroid.multi_windows persist.waydroid.suspend; do
      info "$prop = $(timeout 15 waydroid prop get "$prop" 2>/dev/null)"
    done
  fi
  [[ $state != FROZEN ]] || android_sleep
fi

say "Disk"
if [[ $BACKEND == waydroid ]]; then
  "${R[@]}" du -sh /etc/waydroid-extra/images "$WAYDROID_DATA/data" 2>/dev/null | sed 's/^/  ·     /' || true
  info "total: $("${R[@]}" du -shc /etc/waydroid-extra/images /var/lib/waydroid "$WAYDROID_DATA" "$APP_DIR" 2>/dev/null | tail -n1 | cut -f1)"
  ((${#R[@]})) || info "(sizes without root may miss a few of Android's own files)"
else
  du -sh "$EMU_SDK/emulator" "$EMU_SDK/system-images" "$EMU_AVD_HOME" 2>/dev/null | sed 's/^/  ·     /' || true
  info "total: $(du -shc "$APP_DIR" 2>/dev/null | tail -n1 | cut -f1)"
fi

say "Memory and CPU"
cpu_ticks() { awk '{ print $14 + $15 }' "/proc/$1/stat" 2>/dev/null || echo 0; }
if [[ $BACKEND == waydroid ]]; then
  # Waydroid's container is an LXC payload cgroup: its counters cover all of Android.
  cg=$(wd_cgroup_dir || true)
  if [[ -n $cg && -r $cg/memory.current ]]; then
    # memory.current also counts file cache (Android's images, Kindle's books), which Linux drops
    # whenever it needs the room; anon + kernel is what Android itself holds.
    anon=$(awk '$1 == "anon" || $1 == "kernel" { s += $2 } END { print int(s / 1048576) }' "$cg/memory.stat")
    file=$(awk '$1 == "file" { print int($2 / 1048576) }' "$cg/memory.stat")
    info "Android's memory now: $anon MB, plus $file MB of file cache Linux reclaims when needed"
    u0=$(awk '/^usage_usec/ { print $2 }' "$cg/cpu.stat")
    sleep 10
    u1=$(awk '/^usage_usec/ { print $2 }' "$cg/cpu.stat")
    info "Android's CPU over the last 10 s: $(((u1 - u0) / 100000))% of one core ($(android_state))"
  else
    info "Android isn't running, so it uses no memory or CPU."
  fi
else
  pid=$(emu_pid)
  if [[ -n $pid ]]; then
    info "the emulator's memory now: $(($(awk '/VmRSS/ { print $2 }' "/proc/$pid/status") / 1024)) MB"
    t0=$(cpu_ticks "$pid")
    sleep 10
    info "its CPU over the last 10 s: $((($(cpu_ticks "$pid") - t0) / 10))% of one core ($(android_state))"
  else
    info "Android isn't running, so it uses no memory or CPU."
  fi
fi

if ((bench)); then
  say "Opening speed, resizing, close and reopen"
  bench_launcher=$here/kindle
  [[ -x $bench_launcher ]] || bench_launcher=$launcher
  # On Hyprland the window itself is watched and resized; elsewhere "open" is Kindle's first frame
  # in scrcpy's log, and the resize checks are skipped.
  hypr=0
  [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] && command -v hyprctl >/dev/null && hypr=1
  window() {
    if ((hypr)); then
      hyprctl clients -j | jq -r --arg c "$WINDOW_ID" 'first(.[] | select(.class == $c)) // empty | "\(.address) \(.size | join("x")) \(.stableId)"'
    elif grep -qs 'Texture' "$STATE_DIR/window.log"; then
      echo shown
    fi
  }
  launcher_pid() {
    local p cmd
    for p in $(pgrep -u "$UID" -f "bash " 2>/dev/null || true); do
      cmd=$({ tr '\0' ' ' <"/proc/$p/cmdline"; } 2>/dev/null || true)
      if [[ $cmd == *"/bash $bench_launcher "* || $cmd == "bash $bench_launcher "* ]]; then
        echo "$p"
        return 0
      fi
    done
  }
  # Android's crashes, from its dropbox (Java crashes, native tombstones, watchdog restarts),
  # plus host coredumps on Waydroid (shared kernel) and the emulator quitting on the emulator.
  crashes() {
    local n=0 was
    was=$(android_state)
    [[ $was != FROZEN ]] || android_wake FROZEN
    n=$(kfl_adb -s "$(android_connect 20)" shell dumpsys dropbox 2>/dev/null | tr -d '\r' |
      awk -v since="$bench_start" '$1 " " $2 >= since && $3 ~ /^(system_server_crash|system_server_watchdog|SYSTEM_TOMBSTONE|data_app_crash|data_app_native_crash|system_app_crash)$/' | wc -l)
    [[ $was != FROZEN ]] || android_sleep
    if [[ $BACKEND == waydroid ]]; then
      n=$((n + $(coredumpctl list --since "$bench_start" --no-pager 2>/dev/null | grep -c '/system/\|/vendor/' || true)))
    elif [[ -z $(emu_pid) ]]; then
      n=$((n + 1))
    fi
    echo "$n"
  }
  time_open() {
    local start deadline=$((SECONDS + 240))
    rm -f "$STATE_DIR/window.log"
    start=$(date +%s%N)
    setsid -f "$bench_launcher" >/dev/null 2>&1 </dev/null
    until [[ -n $(window) ]]; do
      ((SECONDS < deadline)) || {
        echo "timeout"
        return
      }
      sleep 0.05
    done
    echo "$((($(date +%s%N) - start) / 1000000)) ms"
  }
  close_kindle() {
    local addr pid
    if ((hypr)); then
      addr=$(window | cut -d' ' -f1)
      [[ -n $addr ]] && { hyprctl dispatch "hl.dsp.window.close({ window = \"address:$addr\" })" >/dev/null 2>&1 || true; }
      [[ -n $addr ]] && { hyprctl dispatch closewindow "address:$addr" >/dev/null 2>&1 || true; } # older Hyprland
    fi
    pid=$(launcher_pid)
    # Elsewhere, ask the launcher's scrcpy to quit (it exits as if the window were closed).
    ((hypr)) || [[ -z $pid ]] || pkill -TERM -P "$pid" -x scrcpy || true
    for _ in $(seq 1 100); do
      # Closed once the launcher has frozen Android and exited.
      [[ -z $(launcher_pid) ]] && return 0
      sleep 0.1
    done
  }
  # Android's virtual screen size, which should follow the window.
  vd_size() {
    kfl_adb -s "$(android_connect 5)" shell dumpsys display 2>/dev/null |
      sed -n 's/.*DisplayDeviceInfo{"scrcpy".* \([0-9]* x [0-9]*\), modeId.*density \([0-9]*\),.*/\1 at density \2/p' |
      awk 'NR == 1 { s = $0 } END { print s }'
  }
  # Kindle's own bounds: smaller than the screen means it's letterboxed.
  kindle_bounds() {
    kfl_adb -s "$(android_connect 5)" shell dumpsys activity activities 2>/dev/null |
      awk -v pkg="$KINDLE_PKG/" '
        !done && index($0, pkg) { in_pkg = 1; n = 40 }
        in_pkg && /mBounds=Rect\(0, 0 - [0-9]+, [0-9]+\)/ {
          s = $0
          sub(/.*mBounds=Rect\(0, 0 - /, "", s)
          sub(/\).*/, "", s)
          sub(/, /, " x ", s)
          out = s; done = 1; in_pkg = 0
        }
        in_pkg && --n <= 0 { in_pkg = 0 }
        END { print out }
      '
  }
  fullscreen() {
    hyprctl dispatch "hl.dsp.focus({ window = \"address:$(window | cut -d' ' -f1)\" })" >/dev/null
    hyprctl dispatch 'hl.dsp.window.fullscreen({ mode = "fullscreen" })' >/dev/null
    sleep 3
  }
  shape() { # label
    local w a k
    w=$(window | cut -d' ' -f2)
    a=$(vd_size)
    k=$(kindle_bounds)
    info "  $1: window $w, Android screen $a, Kindle $k"
    if [[ -n $a && ${a% at *} == "$k" ]]; then ok "  Kindle fills the window"; else bad "  Kindle doesn't fill the window (letterboxed)"; fi
  }

  bench_start=$(date '+%Y-%m-%d %H:%M:%S')
  close_kindle
  "$bench_launcher" --stop
  info "open, Android stopped (cold):  $(time_open)"
  sleep 8
  if ((hypr)); then
    shape "tiled"
    fullscreen
    shape "fullscreen"
    fullscreen
    shape "tiled again"
  else
    info "(resize checks need Hyprland: skipped)"
  fi
  for i in 1 2 3; do
    close_kindle
    sleep 3
    before=$(android_state)
    info "open #$i, Android ${before,,}:       $(time_open)"
    sleep 4
  done
  close_kindle
  sleep 3
  info "after closing: Android $(android_state)"
  n=$(crashes)
  if ((n == 0)); then ok "no Android crashes during the bench"; else bad "$n Android crash record(s) since $bench_start"; fi
fi

echo
if ((fails)); then
  echo "$fails check(s) failed."
  exit 1
fi
echo "All checks passed."
