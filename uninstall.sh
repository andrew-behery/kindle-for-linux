#!/usr/bin/env bash
# Remove what install.sh set up. Run as your normal user:  ./uninstall.sh
# If Waydroid was already on this computer before install.sh, it stays: only Kindle and this tool go.
set -euo pipefail

here=$(dirname "$(readlink -f "$0")")
# shellcheck source=lib.sh
source "$here/lib.sh"

[[ $EUID -ne 0 ]] || die "Run this as your normal user, not with sudo."

preexisting=$(state_get waydroid_preexisting)
echo "This removes Kindle for Linux."
if [[ $preexisting == 1 ]]; then
  echo "Waydroid was here before it, so Waydroid stays. Kindle and its downloaded books are removed."
else
  echo "That includes Waydroid, the Android system and everything inside it, including downloaded books."
fi
read -rp "Continue? [y/N] " ans
[[ $ans == [yY]* ]] || exit 0
sudo -v

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

if [[ $preexisting == 1 ]]; then
  say "Removing Kindle from Waydroid"
  if start_android 180; then
    sudo waydroid shell -- pm uninstall "$KINDLE_PKG" >/dev/null || true
  else
    warn "Android didn't start, so Kindle couldn't be removed from it."
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
    sudo firewall-cmd --runtime-to-permanent 2>/dev/null || true
  fi

  pkgs=()
  [[ -n $(state_get waydroid_installed_by_us) ]] && pkgs+=(waydroid)
  [[ -n $(state_get cage_installed_by_us) ]] && pkgs+=(cage)
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

say "Removing the Kindle launcher"
cmd=$(state_get command)
if [[ -n $cmd && $(readlink -f "$BIN_DIR/$cmd" 2>/dev/null) == "$APP_DIR/kindle" ]]; then
  rm -f "$BIN_DIR/$cmd"
fi
rm -f "$DESKTOP_FILE"
update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
sudo rm -rf "$APP_DIR" # the waydroid_script venv may hold root-owned caches
rm -rf "$STATE_DIR"

echo "Done."
