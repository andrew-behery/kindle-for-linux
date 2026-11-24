#!/usr/bin/env bash
# Check a Kindle for Linux install and measure what it costs.
#   ./verify.sh           checks, disk use, memory and idle CPU (asks for your password to size
#                         Android's files, which belong to Android's own users)
#   ./verify.sh --bench   also times opening Kindle: from a cold start and with Android running
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
sudo -v
if sudo test -f "$WAYDROID_CFG"; then
  images_path=$(sudo sed -n 's/^images_path = //p' "$WAYDROID_CFG")
  if [[ $images_path == /etc/waydroid-extra/images ]] && sudo test -f "$images_path/kindle-for-linux.version"; then
    ok "Android images: $(sudo cat "$images_path/kindle-for-linux.version") (pinned, no Google)"
  else
    bad "Android images aren't the pinned ones (images_path = ${images_path:-?}); rerun install.sh"
  fi
  if python3 -c 'import pyclip' 2>/dev/null; then ok "clipboard sharing (pyclip) installed"; else info "no clipboard sharing (pyclip missing)"; fi
  if [[ $(uname -m) == x86_64 ]]; then
    bridge=$(sudo sed -n 's/^ro.dalvik.vm.native.bridge = //p' "$WAYDROID_CFG")
    if [[ -n $bridge ]]; then ok "ARM translation: $bridge"; else bad "no ARM translation (Kindle won't run)"; fi
  fi
  egl=$(sudo sed -n 's/^ro.hardware.egl=//p' /var/lib/waydroid/waydroid_base.prop 2>/dev/null || true)
  case $egl in
    swiftshader) info "Android draws on the CPU (SwiftShader): no GPU it can use" ;;
    mesa) info "Android draws on the GPU (Mesa)" ;;
    *) info "Android's renderer: ${egl:-unknown}" ;;
  esac
else
  bad "Waydroid isn't initialized ($WAYDROID_CFG missing)"
fi
if [[ -x $APP_DIR/kindle && -f $DESKTOP_FILE ]]; then ok "launcher and menu entry installed"; else bad "launcher or menu entry missing"; fi
if [[ ! -f $WAYDROID_DESKTOP ]] || grep -q '^NoDisplay=true' "$WAYDROID_DESKTOP"; then
  ok "Waydroid's own Kindle entry is hidden (no duplicate in the menu)"
else
  bad "Waydroid's own Kindle entry is visible too"
fi

say "Android"
state=$(session_state)
info "session: ${state:-unknown}, container: $(container_state)"
if [[ $state == RUNNING ]]; then
  if kindle_installed; then ok "Kindle is installed"; else bad "Kindle isn't installed"; fi
  for prop in persist.waydroid.multi_windows persist.waydroid.suspend; do
    info "$prop = $(waydroid prop get "$prop" 2>/dev/null)"
  done
fi

say "Disk"
sudo du -sh /var/lib/waydroid/images "$WAYDROID_DATA/data" 2>/dev/null | sed 's/^/  ·     /'
for app in "$KINDLE_PKG" com.google.android.gms com.android.vending; do
  size=$(sudo du -sh "$WAYDROID_DATA/data/data/$app" 2>/dev/null | cut -f1 || true)
  [[ -n $size ]] && info "  of which $app: $size"
done
info "total: $(sudo du -shc /var/lib/waydroid "$WAYDROID_DATA" "$APP_DIR" 2>/dev/null | tail -n1 | cut -f1)"

# Waydroid's container is an LXC payload cgroup: its memory and CPU counters cover all of Android.
cg=$(find /sys/fs/cgroup -maxdepth 3 -type d -name 'lxc.payload.waydroid' 2>/dev/null | head -n1)
say "Memory and CPU"
if [[ -n $cg && -r $cg/memory.current ]]; then
  info "Android's memory now: $(($(cat "$cg/memory.current") / 1048576)) MB (peak $(($(cat "$cg/memory.peak" 2>/dev/null || echo 0) / 1048576)) MB)"
  u0=$(awk '/^usage_usec/ { print $2 }' "$cg/cpu.stat")
  sleep 10
  u1=$(awk '/^usage_usec/ { print $2 }' "$cg/cpu.stat")
  info "Android's CPU over the last 10 s: $(((u1 - u0) / 100000))% of one core ($(container_state))"
else
  info "Android isn't running, so it uses no memory or CPU."
fi

if ((bench)); then
  say "Opening speed"
  command -v hyprctl >/dev/null || die "--bench needs Hyprland."
  launcher=$APP_DIR/kindle
  kindle_window() { hyprctl clients -j | jq -e --arg c "waydroid.$KINDLE_PKG" 'any(.[]; .class == $c)' >/dev/null; }
  time_open() {
    local t0=$SECONDS start=$(date +%s%N)
    "$launcher" >/dev/null 2>&1 &
    until kindle_window; do
      ((SECONDS - t0 < 240)) || {
        echo "timeout"
        return
      }
      sleep 0.1
    done
    echo "$((($(date +%s%N) - start) / 1000000)) ms"
  }
  close_kindle() {
    sudo waydroid shell -- am force-stop "$KINDLE_PKG" >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do kindle_window || return 0; sleep 0.1; done
  }

  close_kindle
  "$launcher" --stop
  info "cold (Android stopped):            $(time_open)"
  sleep 5
  close_kindle
  sleep 3
  info "Android running, Kindle closed:     $(time_open)"
fi

echo
if ((fails)); then
  echo "$fails check(s) failed."
  exit 1
fi
echo "All checks passed."
