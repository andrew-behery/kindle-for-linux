#!/usr/bin/env bash
# Check a Kindle for Linux install and measure what it costs.
#   ./verify.sh           checks, disk use, memory and idle CPU (asks for your password to size
#                         Android's files, which belong to Android's own users)
#   ./verify.sh --bench   also times opening Kindle (cold, and from frozen), resizes the window,
#                         closes and reopens it 3 times, and counts Android crashes meanwhile
#                         (needs Hyprland, which it asks for window positions)
set -euo pipefail

here=$(dirname "$(readlink -f "$0")")
# shellcheck source=lib.sh
source "$here/lib.sh"

bench=0
[[ ${1:-} == --bench ]] && bench=1
fails=0
ok() { printf '  \033[32mok\033[0m    %s\n' "$*"; }
bad() {
  printf '  \033[31mFAIL\033[0m  %s\n' "$*"
  fails=$((fails + 1))
}
info() { printf '  ·     %s\n' "$*"; }

say "Install"
if command -v waydroid >/dev/null; then ok "$(waydroid --version 2>/dev/null | head -n1 || echo waydroid)"; else bad "waydroid isn't installed"; fi
if grep -qw binder /proc/filesystems || modinfo binder_linux >/dev/null 2>&1; then ok "kernel has binder"; else bad "kernel has no binder"; fi
if systemctl is-active -q waydroid-container.service; then ok "waydroid-container.service is running"; else bad "waydroid-container.service isn't running"; fi
# Root only sharpens the disk sizes (some of Android's files belong to its own users); skip it
# when there's no terminal to ask for a password in (e.g. over SSH).
R=()
if sudo -n true 2>/dev/null || { [[ -t 0 ]] && sudo -v; }; then R=(sudo); fi
if [[ -f $WAYDROID_CFG ]]; then
  images_path=$(sed -n 's/^images_path = //p' "$WAYDROID_CFG")
  if [[ $images_path == /etc/waydroid-extra/images && -f $images_path/kindle-for-linux.version ]]; then
    ok "Android images: $(<"$images_path/kindle-for-linux.version") (pinned, no Google)"
  else
    bad "Android images aren't the pinned ones (images_path = ${images_path:-?}); rerun install.sh"
  fi
  if [[ $(uname -m) == x86_64 ]]; then
    bridge=$(sed -n 's/^ro.dalvik.vm.native.bridge = //p' "$WAYDROID_CFG")
    if [[ -n $bridge ]]; then ok "ARM translation: $bridge"; else bad "no ARM translation (Kindle won't run)"; fi
  fi
  egl=$(sed -n 's/^ro.hardware.egl=//p' /var/lib/waydroid/waydroid_base.prop 2>/dev/null || true)
  case $egl in
    swiftshader) info "Android draws on the CPU (SwiftShader): no GPU it can use" ;;
    mesa) info "Android draws on the GPU (Mesa)" ;;
    *) info "Android's renderer: ${egl:-unknown}" ;;
  esac
else
  bad "Waydroid isn't initialized ($WAYDROID_CFG missing)"
fi
if [[ -x $APP_DIR/kindle && -f $DESKTOP_FILE ]]; then ok "launcher and menu entry installed"; else bad "launcher or menu entry missing"; fi
if [[ -n $(scrcpy_bin) ]]; then ok "$("$(scrcpy_bin)" --version 2>/dev/null | head -n1 | cut -d' ' -f1-2) ($(scrcpy_bin))"; else bad "scrcpy missing (Kindle's window)"; fi
if [[ -f $ADB_HOME/.android/adbkey ]]; then ok "adb key for Android in $ADB_HOME"; else bad "no adb key (rerun install.sh)"; fi
if [[ ! -f $WAYDROID_DESKTOP ]] || grep -q '^NoDisplay=true' "$WAYDROID_DESKTOP"; then
  ok "Waydroid's own Kindle entry is hidden (no duplicate in the menu)"
else
  bad "Waydroid's own Kindle entry is visible too"
fi

say "Android"
state=$(session_state)
info "session: ${state:-unknown}, container: $(container_state)"
if [[ $state == RUNNING ]]; then
  was_frozen=0
  if [[ $(container_state) == FROZEN ]]; then
    was_frozen=1
    container_call Unfreeze || true
  fi
  if serial=$(android_connect 20); then
    ok "adb reaches Android ($serial)"
    if [[ $(kfl_adb -s "$serial" shell pm path "$KINDLE_PKG" 2>/dev/null) == package:* ]]; then
      ok "Kindle is installed ($(kfl_adb -s "$serial" shell dumpsys package "$KINDLE_PKG" | sed -n 's/^ *versionName=//p' | head -n1))"
    else
      bad "Kindle isn't installed"
    fi
    info "screen sleep: $(kfl_adb -s "$serial" shell settings get system screen_off_timeout) ms, density $(kfl_adb -s "$serial" shell wm density | sed -n 's/.*: //p' | head -n1)"
  else
    bad "adb can't reach Android"
  fi
  for prop in persist.waydroid.multi_windows persist.waydroid.suspend; do
    info "$prop = $(timeout 15 waydroid prop get "$prop" 2>/dev/null)"
  done
  ((was_frozen)) && container_call Freeze
fi

say "Disk"
"${R[@]}" du -sh /etc/waydroid-extra/images "$WAYDROID_DATA/data" 2>/dev/null | sed 's/^/  ·     /' || true
for app in "$KINDLE_PKG"; do
  size=$("${R[@]}" du -sh "$WAYDROID_DATA/data/data/$app" 2>/dev/null | cut -f1 || true)
  if [[ -n $size && $size != 0 ]]; then info "  of which $app: $size"; fi
done
info "total: $("${R[@]}" du -shc /etc/waydroid-extra/images /var/lib/waydroid "$WAYDROID_DATA" "$APP_DIR" 2>/dev/null | tail -n1 | cut -f1)${R:+}"
((${#R[@]})) || info "(sizes without root may miss a few of Android's own files)"

# Waydroid's container is an LXC payload cgroup: its memory and CPU counters cover all of Android.
cg=$(find /sys/fs/cgroup -maxdepth 3 -type d -name 'lxc.payload.waydroid' 2>/dev/null | head -n1 || true)
say "Memory and CPU"
if [[ -n $cg && -r $cg/memory.current ]]; then
  # memory.current also counts file cache (Android's images, Kindle's books), which Linux drops
  # whenever it needs the room; anon + kernel is what Android itself holds.
  anon=$(awk '$1 == "anon" || $1 == "kernel" { s += $2 } END { print int(s / 1048576) }' "$cg/memory.stat")
  file=$(awk '$1 == "file" { print int($2 / 1048576) }' "$cg/memory.stat")
  info "Android's memory now: $anon MB, plus $file MB of file cache Linux reclaims when needed"
  u0=$(awk '/^usage_usec/ { print $2 }' "$cg/cpu.stat")
  sleep 10
  u1=$(awk '/^usage_usec/ { print $2 }' "$cg/cpu.stat")
  info "Android's CPU over the last 10 s: $(((u1 - u0) / 100000))% of one core ($(container_state))"
else
  info "Android isn't running, so it uses no memory or CPU."
fi

if ((bench)); then
  say "Opening speed, resizing, close and reopen"
  command -v hyprctl >/dev/null || die "--bench needs Hyprland."
  launcher=$APP_DIR/kindle
  window() { hyprctl clients -j | jq -r --arg c "$WINDOW_ID" '.[] | select(.class == $c) | "\(.address) \(.size | join("x")) \(.stableId)"' | head -n1; }
  # Android's crashes: native ones land in the host's coredumps (shared kernel), Java ones and
  # watchdog restarts in Android's dropbox.
  crashes() {
    local n=0 d=$WAYDROID_DATA/data/system/dropbox
    n=$(coredumpctl list --since "$bench_start" --no-pager 2>/dev/null | grep -c '/system/\|/vendor/' || true)
    if [[ -r $d ]]; then
      n=$((n + $(find "$d" -newermt "$bench_start" \( -name 'system_server_crash@*' -o -name 'system_server_watchdog@*' -o -name 'SYSTEM_TOMBSTONE@*' -o -name 'data_app_crash@*' \) | wc -l)))
    fi
    echo "$n"
  }
  time_open() {
    local start=$(date +%s%N) deadline=$((SECONDS + 240))
    setsid -f "$launcher" >/dev/null 2>&1 </dev/null
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
    local addr
    addr=$(window | cut -d' ' -f1)
    [[ -n $addr ]] && { hyprctl dispatch "hl.dsp.window.close({ window = \"address:$addr\" })" >/dev/null 2>&1 || true; }
    [[ -n $addr ]] && { hyprctl dispatch closewindow "address:$addr" >/dev/null 2>&1 || true; } # older Hyprland
    for _ in $(seq 1 100); do
      # Closed once the window is gone and the launcher has frozen Android.
      [[ -z $(window) ]] && ! pgrep -u "$UID" -f "$APP_DIR/kindle\$" >/dev/null && return 0
      sleep 0.1
    done
  }
  # Android's virtual screen size, which should follow the window.
  vd_size() {
    kfl_adb -s "$(android_ip):5555" shell dumpsys display 2>/dev/null |
      sed -n 's/.*DisplayDeviceInfo{"scrcpy".* \([0-9]* x [0-9]*\), modeId.*density \([0-9]*\),.*/\1 at density \2/p' | head -n1
  }
  fullscreen() {
    hyprctl dispatch "hl.dsp.focus({ window = \"address:$(window | cut -d' ' -f1)\" })" >/dev/null
    hyprctl dispatch 'hl.dsp.window.fullscreen({ mode = "fullscreen" })' >/dev/null
    sleep 2
  }

  bench_start=$(date '+%Y-%m-%d %H:%M:%S')
  close_kindle
  "$launcher" --stop
  info "open, Android stopped (cold):  $(time_open)"
  sleep 8
  info "  window $(window | cut -d' ' -f2), Android screen $(vd_size)"
  fullscreen
  info "  fullscreen: window $(window | cut -d' ' -f2), Android screen $(vd_size)"
  fullscreen
  info "  back: window $(window | cut -d' ' -f2), Android screen $(vd_size)"
  for i in 1 2 3; do
    close_kindle
    sleep 3
    before=$(container_state)
    info "open #$i, Android ${before,,}:       $(time_open)"
    sleep 4
  done
  close_kindle
  sleep 3
  info "after closing: container $(container_state)"
  n=$(crashes)
  if ((n == 0)); then ok "no Android crashes during the bench"; else bad "$n Android crash record(s) since $bench_start"; fi
fi

echo
if ((fails)); then
  echo "$fails check(s) failed."
  exit 1
fi
echo "All checks passed."
