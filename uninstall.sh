#!/usr/bin/env bash
# Remove what install.sh set up. Run as your normal user:  ./uninstall.sh
# If Waydroid was already on this computer before install.sh, it stays: only Kindle and this tool go.
# The emulator backend lives entirely in ~/.local/share/kindle-for-linux, so it goes with it.
set -euo pipefail

here=$(dirname "$(readlink -f "$0")")
# shellcheck source=lib.sh
source "$here/lib.sh"

[[ $EUID -ne 0 ]] || die "Run this as your normal user, not with sudo."

yes=0
[[ ${1:-} == --yes || ${1:-} == -y ]] && yes=1

preexisting=$(state_get waydroid_preexisting)
# Did this tool use Waydroid at all? (Not on emulator-only installs.)
used_waydroid=$(state_get images_installed_by_us)$(state_get waydroid_installed_by_us)$(state_get arm_layer)$(state_get waydroid_signin_service)
[[ $(state_get backend) != waydroid ]] || used_waydroid+="1"
echo "This removes Kindle for Linux."
if [[ -n $used_waydroid && $preexisting == 1 ]]; then
  echo "Waydroid was here before it, so Waydroid stays. Kindle and its downloaded books are removed."
elif [[ -n $used_waydroid ]]; then
  echo "That includes Waydroid, the Android system and everything inside it, including downloaded books."
fi
[[ ! -d $EMU_SDK ]] || echo "That includes the Android emulator, its Android and everything inside it, including downloaded books."
if ((!yes)); then
  read -rp "Continue? [y/N] " ans
  [[ $ans == [yY]* ]] || exit 0
fi
[[ -z $used_waydroid ]] || sudo -v

if [[ -d $EMU_SDK ]]; then
  say "Stopping the Android emulator"
  BACKEND=emulator stop_android
fi

pm=""
for candidate in pacman apt-get dnf zypper; do
  if command -v "$candidate" >/dev/null; then
    pm=$candidate
    break
  fi
done
remove_pkgs() {
  (($#)) || return 0
  case $pm in
    pacman) sudo pacman -Rns --noconfirm "$@" ;;
    apt-get) sudo apt-get remove -y "$@" ;;
    dnf) sudo dnf remove -y "$@" ;;
    zypper) sudo zypper --non-interactive remove "$@" ;;
    *) echo "Remove these with your package manager: $*" ;;
  esac
}

kfl_adb kill-server >/dev/null 2>&1 || true
BACKEND=waydroid

if [[ -z $used_waydroid ]]; then
  : # Waydroid was never touched
elif [[ $preexisting == 1 ]]; then
  say "Removing Kindle from Waydroid"
  if start_android 180; then
    [[ $(container_state) != FROZEN ]] || container_call Unfreeze || true
    timeout 30 sudo waydroid shell -- pm uninstall "$KINDLE_PKG" >/dev/null 2>&1 || true
    # Put back the Waydroid settings install.sh changed.
    for prop in multi_windows suspend; do
      prev=$(state_get "prev_$prop")
      [[ -n $prev ]] && timeout 15 waydroid prop set "persist.waydroid.$prop" "$prev" >/dev/null 2>&1 || true
    done
  else
    warn "Android didn't start, so Kindle couldn't be removed from it."
  fi
  # Remove the sign-in overlay service (plus any legacy debugging properties from earlier installs).
  if [[ -n $(state_get waydroid_signin_service) ]]; then
    stop_android
    sudo rm -f /var/lib/waydroid/overlay/system/framework/kfl-scrcpy-server.jar \
      /var/lib/waydroid/overlay/system/bin/kfl-scrcpy-server \
      /var/lib/waydroid/overlay/system/etc/init/kfl-scrcpy.rc
    sudo rmdir /var/lib/waydroid/overlay/system/framework 2>/dev/null || true
  fi
  if [[ -n $(state_get debuggable_set_by_us) ]]; then
    sudo python3 - "$WAYDROID_CFG" <<'PYCFG'
import configparser, sys
cfg = configparser.ConfigParser()
cfg.optionxform = str
cfg.read(sys.argv[1])
for key in ("ro.debuggable", "lineage.service.adb.root"):
    cfg.remove_option("properties", key) if cfg.has_section("properties") else None
with open(sys.argv[1], "w") as f:
    cfg.write(f)
PYCFG
    stop_android
    sudo waydroid upgrade --offline >/dev/null 2>&1 || true
  fi
  # Take our adb key out of the keys Android trusts.
  if [[ -f $ADB_HOME/.android/adbkey.pub ]]; then
    key=$(cut -d' ' -f1 "$ADB_HOME/.android/adbkey.pub")
    sudo sed -i "\|^$key|d" "$WAYDROID_DATA/data/misc/adb/adb_keys" 2>/dev/null || true
  fi
  arm_layer=$(state_get arm_layer)
  if [[ -n $arm_layer && -x $APP_DIR/waydroid_script/venv/bin/python3 ]]; then
    say "Removing the ARM translation this tool added ($arm_layer)"
    stop_android
    (cd "$APP_DIR/waydroid_script" && sudo venv/bin/python3 main.py uninstall "$arm_layer") || true
  fi
else
  say "Removing Waydroid and Android"
  stop_android
  sudo systemctl disable --now waydroid-container.service 2>/dev/null || true

  if [[ -n $(state_get ufw_rules_added) ]]; then
    sudo ufw delete allow in on waydroid0 to any port 53 2>/dev/null || true
    sudo ufw delete allow in on waydroid0 to any port 67 proto udp 2>/dev/null || true
    sudo ufw route delete allow in on waydroid0 2>/dev/null || true
    sudo ufw route delete allow out on waydroid0 2>/dev/null || true
  fi
  if [[ -n $(state_get firewalld_rules_added) ]]; then
    sudo firewall-cmd --zone=trusted --remove-interface=waydroid0 2>/dev/null || true
    sudo firewall-cmd --zone=trusted --remove-port=53/udp --remove-port=67/udp 2>/dev/null || true
    sudo firewall-cmd --zone=trusted --remove-forward 2>/dev/null || true
    sudo firewall-cmd --runtime-to-permanent 2>/dev/null || true
  fi

  pkgs=()
  [[ -n $(state_get waydroid_installed_by_us) ]] && pkgs+=(waydroid)
  [[ -n $(state_get cage_installed_by_us) ]] && pkgs+=(cage)
  [[ -n $(state_get scrcpy_installed_by_us) ]] && pkgs+=(scrcpy)
  remove_pkgs "${pkgs[@]}"
  if [[ -n $(state_get apt_repo_added) ]]; then
    sudo rm -f /etc/apt/sources.list.d/waydroid.list /usr/share/keyrings/waydroid.gpg
  fi

  # Android's files belong to Android's own users, so removing them needs root.
  sudo rm -rf /var/lib/waydroid "$WAYDROID_DATA"
  [[ -n $(state_get images_installed_by_us) ]] && sudo rm -rf /etc/waydroid-extra/images
  sudo rmdir /etc/waydroid-extra 2>/dev/null || true
  rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/kindle-for-linux"
  rm -f "$APPS_DIR"/waydroid.*.desktop
fi

{
  say "Removing the Kindle launcher"
  cmd=$(state_get command)
  for c in "$cmd" kindle kindle-for-linux; do
    [[ -n $c ]] || continue
    target=$(readlink -f "$BIN_DIR/$c" 2>/dev/null || true)
    if [[ $target == "$APP_DIR/kindle" || $target == "$PKG_DIR/kindle" ]]; then
      rm -f "$BIN_DIR/$c"
    fi
  done
  rm -f "$DESKTOP_FILE"
  update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
  if [[ -n $used_waydroid ]]; then
    sudo rm -rf "$APP_DIR" # the waydroid_script venv may hold root-owned caches
  else
    rm -rf "$APP_DIR"
  fi
  [[ -z $(state_get kvm_group_added) ]] || note "(You stay in the kvm group, which other virtual machines may use too.)"
  rm -rf "$STATE_DIR" "${XDG_CACHE_HOME:-$HOME/.cache}/kindle-for-linux"
  if [[ $here == "$PKG_DIR" ]]; then
    note "To also remove the kindle-for-linux package itself, use your package manager (apt, dnf, or pacman)."
  fi
  echo "Done."
  exit 0
}
