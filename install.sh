#!/usr/bin/env bash
# Kindle for Linux: sets up the real Kindle Android app in Waydroid, tuned to open fast and stay small.
# No Google account, no Play Store, nothing to register: the Kindle app is downloaded directly and
# checked against Amazon's signing certificate before it's installed. Kindle's window is scrcpy,
# showing a virtual Android screen that resizes with the window.
#
#   ./install.sh                 run as your normal user, in a terminal inside your desktop session
#   ./install.sh --apk FILE      install Kindle from an APK you already have (still checked)
#   ./install.sh --check         only run the compatibility checks; change nothing
#
# It asks for your password once. Safe to rerun: finished steps are skipped.
set -euo pipefail

here=$(dirname "$(readlink -f "$0")")
# shellcheck source=lib.sh
source "$here/lib.sh"

# ARM translation for x86_64 machines comes from waydroid_script, pinned to a reviewed commit.
WAYDROID_SCRIPT_REV=4a50dabd97fcb632a608b1421105258862a5b994
WAYDROID_SCRIPT_SHA256=786a95136b8cb8f79646ed74ea11835a35148eba76e8f14a71363e3f6349a114

# Android itself: LineageOS 20 without Google (VANILLA). Pinned to the spring 2026 images, because
# the 2026-09-27 images make SurfaceFlinger crash whenever an app window opens or closes
# (https://github.com/waydroid/waydroid/issues/2436). Unpin once that is fixed upstream.
IMAGES_VERSION=system-20260403-VANILLA+vendor-20260428-MAINLINE
SF=https://sourceforge.net/projects/waydroid/files/images
SYSTEM_ZIP_x86_64=lineage-20.0-20260403-VANILLA-waydroid_x86_64-system.zip
SYSTEM_URL_x86_64=$SF/system/lineage/waydroid_x86_64/$SYSTEM_ZIP_x86_64/download
SYSTEM_SHA256_x86_64=2e343b14c649a685853e7957ac34feb1ca110425d78a47ebad764caae24116a8
VENDOR_ZIP_x86_64=lineage-20.0-20260428-MAINLINE-waydroid_x86_64-vendor.zip
VENDOR_URL_x86_64=$SF/vendor/waydroid_x86_64/$VENDOR_ZIP_x86_64/download
VENDOR_SHA256_x86_64=cba35433ffca73ed349e096b1daec495b3204e01c0e541c4203671e6d648e874
IMAGES_DIR=/etc/waydroid-extra/images # Waydroid boots from images here instead of downloading its own

# scrcpy's official Linux build (x86_64), which includes its own adb. Virtual screens that follow
# the window (--flex-display) need scrcpy 4.1 or newer; ARM64 takes the distro's scrcpy.
SCRCPY_VERSION=5.0.1
SCRCPY_URL_x86_64=https://github.com/Genymobile/scrcpy/releases/download/v$SCRCPY_VERSION/scrcpy-linux-x86_64-v$SCRCPY_VERSION.tar.gz
SCRCPY_SHA256_x86_64=9f969d30cc574816077edecda65719c1c70b0aee1df1ba5fa00779ac07b8fd6e

# The certificate Amazon signs the Kindle app with (SHA-256). Android refuses an APK whose
# signatures don't verify against the certificate inside it, so matching this proves who made it.
AMAZON_KINDLE_CERT=2f19adeb284eb36f7f07786152b9a1d14b21653203ad0b04ebbf9c73ab6d7625
KINDLE_APK_URL="https://d.apkpure.com/b/APK/$KINDLE_PKG?version=latest"
CACHE_DIR=${XDG_CACHE_HOME:-$HOME/.cache}/kindle-for-linux

apk_arg=""
check_only=0
while (($#)); do
  case $1 in
    --check) check_only=1 ;;
    --apk)
      apk_arg=$(readlink -f "${2:?--apk needs a file}")
      shift
      ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

mkdir -p "$STATE_DIR"
LOG=$STATE_DIR/install.log
exec > >(tee -a "$LOG") 2>&1
printf '\n===== install.sh, %s =====\n' "$(date -Is)"

# --- Preflight ---------------------------------------------------------------------------------

[[ $EUID -ne 0 ]] || die "Run this as your normal user, not with sudo. It asks for your password when it needs it."
[[ -z $apk_arg || -f $apk_arg ]] || die "No such file: $apk_arg"

arch=$(uname -m)
case $arch in
  x86_64 | aarch64) ;;
  *) die "This needs an x86_64 or ARM64 (aarch64) computer; this one is $arch." ;;
esac

mode=$(display_mode)
[[ $mode != none ]] || die "Run this from a terminal inside your desktop session, not over SSH or a text console."

# Binder is Android's way for its processes to talk to each other. Waydroid needs it in the kernel.
if ! grep -qw binder /proc/filesystems && ! modinfo binder_linux >/dev/null 2>&1; then
  die "Your kernel has no binder support, which Android needs.
  Ubuntu/Debian/Mint: sudo apt install linux-modules-extra-\$(uname -r), then reboot.
  Arch: use the linux-zen kernel (or install binder_linux-dkms), then reboot.
  Then run this again."
fi

if [[ -e /run/ostree-booted ]] && ! command -v waydroid >/dev/null; then
  die "This is an image-based system (Silverblue, Bazzite, SteamOS…), where packages can't be added
  the usual way. Install Waydroid the way your system recommends (Bazzite: ujust setup-waydroid), then rerun."
fi

pm=""
for candidate in pacman apt-get dnf zypper; do
  if command -v "$candidate" >/dev/null; then
    pm=$candidate
    break
  fi
done
if [[ -z $pm ]] && ! command -v waydroid >/dev/null; then
  die "Couldn't find pacman, apt, dnf or zypper. Install Waydroid with your package manager, then rerun."
fi

mem_gb=$(awk '/MemTotal/ { printf "%d", $2 / 1048576 + 0.5 }' /proc/meminfo)
((mem_gb >= 4)) || warn "This computer has ${mem_gb} GB of RAM. Android needs about 1.5 GB of it while Kindle is open."
free_gb=$(df -P /etc | awk 'NR == 2 { printf "%d", $4 / 1048576 }')
((free_gb >= 5)) || die "Android needs about 5 GB free on your system disk; there's ${free_gb} GB."

# Which GPU Android will draw with. Waydroid picks an AMD/Intel/ARM GPU by itself and skips NVIDIA,
# which its Android can't use. With no usable GPU it draws on the CPU, which is fine for reading.
gpu_drivers=$(for f in /sys/class/drm/renderD*/device/uevent; do if [[ -r $f ]]; then sed -n 's/^DRIVER=//p' "$f"; fi; done | sort -u | xargs)
if [[ -z $gpu_drivers ]] || ! grep -qvw nvidia <<<"${gpu_drivers// /$'\n'}"; then
  gpu_note="the CPU (no GPU Android can use: ${gpu_drivers:-none found})"
else
  gpu_note="the GPU ($(grep -vw nvidia <<<"${gpu_drivers// /$'\n'}" | head -n1))"
fi

# Kindle's window is a video stream from Android. With no GPU it can use (NVIDIA-only machines),
# Android draws on the CPU, and its video encoder then crashes, so there's no picture.
if [[ $gpu_note == "the CPU"* ]]; then
  die "This computer has no GPU Android can use (${gpu_drivers:-none found}). Waydroid skips NVIDIA
  GPUs, and without a GPU Kindle's window can't work. NVIDIA-only computers aren't supported yet."
fi

if [[ $arch == x86_64 ]]; then
  # Kindle ships ARM code only, so x86_64 machines need a translation layer. Intel's libhoudini
  # runs best on Intel CPUs; Google's libndk on AMD.
  if grep -q GenuineIntel /proc/cpuinfo; then arm_layer=libhoudini; else arm_layer=libndk; fi
fi

say "Kindle for Linux"
note "Desktop: $mode${pm:+, package manager: ${pm%-get}}"
note "Android will draw with $gpu_note"
[[ $arch == x86_64 ]] && note "ARM translation: $arm_layer (Kindle is ARM-only)"
note "Log: $LOG"
[[ $mode == x11 ]] && warn "X11 support is experimental (Android runs in a hidden cage compositor). Please report how it goes."
if ((check_only)); then
  note "(--check: stopping before any change)"
  exit 0
fi

# Root is only needed for system changes. The password is asked the first time one is needed, then
# kept alive through the long downloads; a rerun with nothing left to change needs no password.
root_ready=0
root() {
  if ((!root_ready)); then
    if ! sudo -n true 2>/dev/null; then
      [[ -t 0 ]] || die "This step needs your password: run ./install.sh in a terminal on this computer."
      sudo -v || die "Couldn't get administrator rights."
    fi
    while true; do
      sudo -n true
      sleep 50
      kill -0 "$$" 2>/dev/null || exit
    done 2>/dev/null &
    sudo_keepalive=$!
    trap 'kill "$sudo_keepalive" 2>/dev/null || true' EXIT
    root_ready=1
  fi
  sudo "$@"
}

# --- Packages ----------------------------------------------------------------------------------

add_waydroid_apt_repo() {
  # The same two steps as Waydroid's official https://repo.waydro.id script.
  local codename
  codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${DEBIAN_CODENAME:-${VERSION_CODENAME:-}}}")
  [[ -n $codename ]] || die "Couldn't tell which Debian/Ubuntu release this is."
  note "Adding Waydroid's apt repository for '$codename'"
  root curl -fsS --proto '=https' https://repo.waydro.id/waydroid.gpg -o /usr/share/keyrings/waydroid.gpg
  echo "deb [signed-by=/usr/share/keyrings/waydroid.gpg] https://repo.waydro.id/ $codename main" |
    root tee /etc/apt/sources.list.d/waydroid.list >/dev/null
  root apt-get update ||
    die "Waydroid has no packages for '$codename'. Supported: Debian 11-13, Ubuntu 20.04 and newer, and distros based on them."
  state_set apt_repo_added 1
}

pkg_install() {
  case $pm in
    pacman) root pacman -S --needed --noconfirm "$@" ;;
    apt-get) root apt-get install -y "$@" ;;
    dnf) root dnf install -y "$@" ;;
    zypper) root zypper --non-interactive install "$@" ;;
    *) return 1 ;;
  esac
}

install_packages() {
  local pkgs=()
  command -v waydroid >/dev/null || pkgs+=(waydroid)
  [[ $mode == x11 ]] && ! command -v cage >/dev/null && pkgs+=(cage)
  # waydroid_script runs in a Python venv; Debian-based systems ship venv support separately.
  [[ $arch == x86_64 && $pm == apt-get ]] && ! python3 -c 'import ensurepip' 2>/dev/null && pkgs+=(python3-venv)
  # No official scrcpy build for ARM64 Linux: use the distro's.
  if [[ $arch == aarch64 ]]; then
    command -v scrcpy >/dev/null || pkgs+=(scrcpy)
    if ! command -v adb >/dev/null; then
      case $pm in apt-get) pkgs+=(adb) ;; *) pkgs+=(android-tools) ;; esac
    fi
  fi
  if ((${#pkgs[@]})); then
    [[ " ${pkgs[*]} " == *" waydroid "* ]] && state_set waydroid_installed_by_us 1
    [[ " ${pkgs[*]} " == *" cage "* ]] && state_set cage_installed_by_us 1
    [[ " ${pkgs[*]} " == *" scrcpy "* ]] && state_set scrcpy_installed_by_us 1
    if [[ $pm == apt-get && " ${pkgs[*]} " == *" waydroid "* && $(apt-cache policy waydroid 2>/dev/null || true) != *"Candidate: "[0-9]* ]]; then
      add_waydroid_apt_repo
    fi
    pkg_install "${pkgs[@]}" ||
      die "Installing ${pkgs[*]} failed.${pm:+ Update your system first, then rerun.}"
  else
    note "Waydroid is already installed."
  fi
}

say "Installing Waydroid"
waydroid_preexisting=0
command -v waydroid >/dev/null && [[ -z $(state_get waydroid_installed_by_us) ]] && waydroid_preexisting=1
[[ -n $(state_get waydroid_preexisting) ]] || state_set waydroid_preexisting "$waydroid_preexisting"
install_packages
note "$(waydroid --version 2>/dev/null | head -n1)"

# --- Android images ----------------------------------------------------------------------------

images_current() { [[ -r $IMAGES_DIR/kindle-for-linux.version && $(<"$IMAGES_DIR/kindle-for-linux.version") == "$IMAGES_VERSION" ]]; }

fetch_verified() { # url sha256 file
  local url=$1 sum=$2 file=$3
  if [[ -f $file ]] && echo "$sum  $file" | sha256sum -c --quiet - 2>/dev/null; then return 0; fi
  curl -fL --retry 3 --progress-bar "$url" -o "$file.part"
  echo "$sum  $file.part" | sha256sum -c --quiet - || die "$(basename "$file") didn't match its checksum. Try again later."
  mv "$file.part" "$file"
}

if images_current && [[ -f $WAYDROID_CFG ]]; then
  note "Android ($IMAGES_VERSION) is already set up."
else
  if [[ -f $WAYDROID_CFG ]] && [[ $(state_get waydroid_preexisting) == 1 && -z $(state_get images_installed_by_us) ]]; then
    warn "Waydroid is already set up on this computer with other Android images."
    note "Kindle needs Android without Google, on images that don't crash when windows open and close."
    note "Switching keeps your Android apps' data, but apps that depend on Google Play will stop working."
    read -rp "    Switch Waydroid to these images? [y/N] " ans
    [[ $ans == [yY]* ]] || die "Stopped. Nothing was changed."
  fi
  if [[ $arch == x86_64 ]]; then
    say "Downloading Android without Google (about 900 MB, LineageOS 20)"
    mkdir -p "$CACHE_DIR"
    fetch_verified "$SYSTEM_URL_x86_64" "$SYSTEM_SHA256_x86_64" "$CACHE_DIR/$SYSTEM_ZIP_x86_64"
    fetch_verified "$VENDOR_URL_x86_64" "$VENDOR_SHA256_x86_64" "$CACHE_DIR/$VENDOR_ZIP_x86_64"
    stop_android
    root systemctl stop waydroid-container.service 2>/dev/null || true
    root mkdir -p "$IMAGES_DIR"
    root unzip -oq "$CACHE_DIR/$SYSTEM_ZIP_x86_64" -d "$IMAGES_DIR"
    root unzip -oq "$CACHE_DIR/$VENDOR_ZIP_x86_64" -d "$IMAGES_DIR"
    echo "$IMAGES_VERSION" | root tee "$IMAGES_DIR/kindle-for-linux.version" >/dev/null
    rm -f "$CACHE_DIR/$SYSTEM_ZIP_x86_64" "$CACHE_DIR/$VENDOR_ZIP_x86_64" # the unpacked images are all Waydroid needs
    state_set images_installed_by_us 1
    say "Setting up Android"
    root waydroid init -f
    # Images Waydroid downloaded earlier (e.g. the Google Play ones) are no longer used.
    if [[ $(state_get waydroid_preexisting) != 1 ]] && [[ -e /var/lib/waydroid/images/system.img ]]; then
      root rm -f /var/lib/waydroid/images/system.img /var/lib/waydroid/images/vendor.img
      note "Removed the old Android images Waydroid no longer uses."
    fi
  else
    # No pinned ARM64 images yet: take Waydroid's current Google-free images.
    warn "ARM64: using Waydroid's latest images, which may have the window crash described above."
    say "Downloading Android without Google"
    root waydroid init -f -s VANILLA
  fi
fi

# Google apps that updated themselves while an earlier Google Play image was in use stay in
# Android's app storage. Without Google's system image they lose their privileges, and Play
# Services then crashes Android's core on every boot. Move them aside (kept, not deleted).
list_google_leftovers() {
  local dir=$WAYDROID_DATA/data/app
  if [[ -r $dir && -x $dir ]]; then
    find "$dir" -mindepth 2 -maxdepth 2 \( -name 'com.google.android.*' -o -name 'com.android.vending-*' \) 2>/dev/null || true
  elif [[ -d $dir ]]; then
    root find "$dir" -mindepth 2 -maxdepth 2 \( -name 'com.google.android.*' -o -name 'com.android.vending-*' \) 2>/dev/null || true
  fi
}
leftovers=$(list_google_leftovers)
if [[ -n $leftovers ]]; then
  say "Moving leftover Google apps out of Android's way"
  stop_android
  backup=$STATE_DIR/google-leftovers
  while IFS= read -r app; do
    root mkdir -p "$backup/$(basename "$(dirname "$app")")"
    root mv "$app" "$backup/$(basename "$(dirname "$app")")/"
    root rmdir "$(dirname "$app")" 2>/dev/null || true
    note "${app##*/}"
  done <<<"$leftovers"
  note "(kept in $backup)"
fi

# Firewalls drop traffic routed through Waydroid's bridge, which leaves Android offline.
ufw_status=""
if command -v ufw >/dev/null && systemctl is-active -q ufw 2>/dev/null && [[ -z $(state_get ufw_ok) ]]; then
  ufw_status=$(root ufw status 2>/dev/null || true)
fi
if [[ -n $(state_get ufw_ok) ]]; then
  note "Firewall (ufw) already lets Android online."
elif [[ $ufw_status == *"Status: active"* ]]; then
  if [[ $ufw_status == *waydroid0* ]]; then
    note "Firewall (ufw) already lets Android online."
  else
    say "Letting Android through the firewall (ufw)"
    root ufw allow in on waydroid0 to any port 53 comment 'waydroid dns'
    root ufw allow in on waydroid0 to any port 67 proto udp comment 'waydroid dhcp'
    root ufw route allow in on waydroid0 comment 'waydroid outbound'
    root ufw route allow out on waydroid0 comment 'waydroid return'
    state_set ufw_rules_added 1
  fi
  state_set ufw_ok 1
elif [[ -n $(state_get firewalld_ok) ]]; then
  note "Firewall (firewalld) already lets Android online."
elif command -v firewall-cmd >/dev/null && systemctl is-active -q firewalld 2>/dev/null; then
  if root firewall-cmd --zone=trusted --query-interface=waydroid0 >/dev/null 2>&1; then
    note "Firewall (firewalld) already lets Android online."
  else
    say "Letting Android through the firewall (firewalld)"
    root firewall-cmd --zone=trusted --add-interface=waydroid0
    root firewall-cmd --zone=trusted --add-port=53/udp --add-port=67/udp
    root firewall-cmd --zone=trusted --add-forward
    root firewall-cmd --runtime-to-permanent
    state_set firewalld_rules_added 1
  fi
  state_set firewalld_ok 1
fi

if systemctl is-enabled -q waydroid-container.service 2>/dev/null && systemctl is-active -q waydroid-container.service; then
  note "Waydroid's background service is running."
else
  say "Starting Waydroid's background service"
  root systemctl enable --now waydroid-container.service
fi

# --- ARM translation (x86_64 only) -------------------------------------------------------------

# `waydroid init` clears Waydroid's overlay, where the translation libraries live, so check both
# the setting and the files.
if [[ $arch == x86_64 ]]; then
  if grep -q 'native.bridge' "$WAYDROID_CFG" 2>/dev/null &&
    find /var/lib/waydroid/overlay/system -name 'libhoudini.so' -o -name 'libndk_translation.so' 2>/dev/null | grep -q .; then
    note "ARM translation is already installed."
  else
    say "Adding ARM translation ($arm_layer)"
    ws=$APP_DIR/waydroid_script
    if [[ ! -x $ws/venv/bin/python3 ]]; then
      rm -rf "$ws"
      mkdir -p "$ws"
      tarball=$(mktemp)
      curl -fsSL "https://github.com/casualsnek/waydroid_script/archive/$WAYDROID_SCRIPT_REV.tar.gz" -o "$tarball"
      echo "$WAYDROID_SCRIPT_SHA256  $tarball" | sha256sum -c --quiet - ||
        die "The waydroid_script download didn't match its checksum."
      tar -xzf "$tarball" -C "$ws" --strip-components=1
      rm -f "$tarball"
      python3 -m venv "$ws/venv"
      "$ws/venv/bin/pip" install --quiet --disable-pip-version-check -r "$ws/requirements.txt"
    fi
    stop_android
    (cd "$ws" && root "$ws/venv/bin/python3" -W ignore main.py install "$arm_layer")
    grep -q 'native.bridge' "$WAYDROID_CFG" || die "ARM translation didn't install. See $LOG"
    state_set arm_layer "$arm_layer"
  fi
fi

# --- Kindle's window (scrcpy) ------------------------------------------------------------------

say "Kindle's window (scrcpy)"
if [[ $arch == x86_64 ]]; then
  if [[ -x $SCRCPY_DIR/scrcpy && $(cat "$SCRCPY_DIR/kindle-for-linux.version" 2>/dev/null) == "$SCRCPY_VERSION" ]]; then
    note "scrcpy $SCRCPY_VERSION is already installed."
  else
    note "Downloading scrcpy $SCRCPY_VERSION (official build, checksum-verified)"
    mkdir -p "$CACHE_DIR"
    tarball=$CACHE_DIR/scrcpy-linux-x86_64-v$SCRCPY_VERSION.tar.gz
    fetch_verified "$SCRCPY_URL_x86_64" "$SCRCPY_SHA256_x86_64" "$tarball"
    rm -rf "$SCRCPY_DIR"
    mkdir -p "$SCRCPY_DIR"
    tar -xzf "$tarball" -C "$SCRCPY_DIR" --strip-components=1
    echo "$SCRCPY_VERSION" >"$SCRCPY_DIR/kindle-for-linux.version"
    rm -f "$tarball"
  fi
else
  v=$(scrcpy --version 2>/dev/null | awk 'NR == 1 { print $2 }')
  [[ -n $v && $(printf '%s\n' 4.1 "$v" | sort -V | head -n1) == 4.1 ]] ||
    die "Kindle's window needs scrcpy 4.1 or newer; your distro has ${v:-none}. Install a newer scrcpy, then rerun."
  note "scrcpy $v (from your distro)"
fi

# --- Android settings --------------------------------------------------------------------------

say "Starting Android (the first start takes a minute)"
start_android 300 || die "Android didn't start. Details: $STATE_DIR/session.log"

say "Tuning Android for reading"
changed=0
# One display for Android. Per-app windows (multi_windows) are where the crash in waydroid#2436
# lives, and Kindle's window comes from scrcpy anyway.
# (The values found are recorded, so uninstall.sh can put back a Waydroid that was here before.)
for prop in multi_windows suspend; do
  [[ -n $(state_get "prev_$prop") ]] || state_set "prev_$prop" "$(waydroid prop get "persist.waydroid.$prop" 2>/dev/null || true)"
done
if [[ $(waydroid prop get persist.waydroid.multi_windows) != false ]]; then
  waydroid prop set persist.waydroid.multi_windows false
  changed=1
fi
# Waydroid freezes Android whenever its own display has nothing to show, and with Kindle in
# scrcpy's window that is always. So Android doesn't freeze itself; the launcher freezes it
# when Kindle's window closes.
if [[ $(waydroid prop get persist.waydroid.suspend) != false ]]; then
  waydroid prop set persist.waydroid.suspend false
  changed=1
fi
if ((changed)); then
  note "Restarting Android so the changes take effect"
  stop_android
  start_android 180 || die "Android didn't restart. Details: $STATE_DIR/session.log"
fi
[[ $(container_state) != FROZEN ]] || container_call Unfreeze || true

# Our adb talks to Android to set it up and to show Kindle. Android only lets in adb keys listed
# in its adb_keys file, so add ours there (no "Allow USB debugging?" prompt to click).
trust_adb_key() {
  local dir=$WAYDROID_DATA/data/misc/adb run=()
  if [[ ! -f $ADB_HOME/.android/adbkey ]]; then
    mkdir -p "$ADB_HOME/.android"
    kfl_adb keygen "$ADB_HOME/.android/adbkey" >/dev/null 2>&1 || die "Couldn't create an adb key."
  fi
  # Android's files belong to its system user (uid 1000): writing them needs root unless that's us.
  [[ -w $dir ]] || run=(root)
  "${run[@]}" bash -c '
    f=$1/adb_keys key=$(<"$2")
    grep -qsF "${key%% *}" "$f" && exit 0
    if [[ -s $f && -n $(tail -c1 "$f") ]]; then echo >>"$f"; fi # adb writes keys without a newline
    printf "%s\n" "$key" >>"$f"
    chmod 640 "$f"
    chown 1000:2000 "$f" 2>/dev/null || true' _ "$dir" "$ADB_HOME/.android/adbkey.pub"
}
trust_adb_key
serial=$(android_connect 60) || die "Couldn't connect to Android with adb. Details: $LOG"
adb_shell() { kfl_adb -s "$serial" shell "$@"; }

# These live in Android's data, so they survive restarts and image switches: set them once.
# No window animations (pages and menus appear at once), dark mode (Kindle follows it), and no
# screen sleep, which would blank the page you're reading (Android is frozen whenever Kindle's
# window is closed, so this costs nothing).
if [[ $(state_get android_tuned) != 2 ]]; then
  for key in window_animation_scale transition_animation_scale animator_duration_scale; do
    adb_shell settings put global "$key" 0 || warn "Couldn't set $key."
  done
  adb_shell settings put system screen_off_timeout 2147483647 || warn "Couldn't turn off screen sleep."
  adb_shell cmd uimode night yes >/dev/null || warn "Couldn't turn on dark mode."
  state_set android_tuned 2
fi
note "One display, frozen while Kindle is closed, no animations, dark mode, no screen sleep."

# --- Kindle ------------------------------------------------------------------------------------

if [[ $(adb_shell pm path "$KINDLE_PKG" 2>/dev/null) == package:* && -z $apk_arg ]]; then
  note "Kindle is already installed."
else
  mkdir -p "$CACHE_DIR"
  apk=$apk_arg
  if [[ -z $apk ]]; then
    say "Downloading the Kindle app"
    apk=$CACHE_DIR/kindle.apk
    curl -fL --retry 3 --progress-bar -A "Mozilla/5.0 (X11; Linux x86_64)" "$KINDLE_APK_URL" -o "$apk" ||
      die "Couldn't download Kindle. Try again later, or pass an APK you have with --apk FILE."
  fi
  say "Checking it's genuinely Amazon's"
  if python3 "$here/apkcert.py" "$apk" --expect "$AMAZON_KINDLE_CERT"; then
    note "Signed with Amazon's Kindle certificate."
  else
    die "$(basename "$apk") is NOT signed by Amazon's Kindle certificate. Not installing it."
  fi
  say "Installing Kindle (Android prepares the app under ARM translation, which takes a minute)"
  # -r keeps an installed Kindle's data (your sign-in and books) when replacing it.
  out=$(timeout 600 env HOME="$ADB_HOME" "$(adb_bin)" -s "$serial" install -r "$apk" 2>&1) || true
  [[ -n $apk_arg ]] || rm -f "$apk"
  [[ $out == *Success* ]] || die "Kindle didn't install: ${out##*$'\n'}"
  note "Installed."
fi

# Kindle's phone layout (used when the window is under 600 px tall, or narrow) locks itself to
# portrait, which leaves a wide window letterboxed: Kindle in a strip down the middle. Android's
# compatibility overrides make it follow the window instead: whatever orientation Kindle asks
# for becomes "the screen's own". They belong to Kindle's install, so set them every run.
for change in OVERRIDE_ANY_ORIENTATION OVERRIDE_UNDEFINED_ORIENTATION_TO_NOSENSOR; do
  adb_shell am compat enable "$change" "$KINDLE_PKG" >/dev/null ||
    warn "Couldn't set $change: Kindle may show black bars in wide windows."
done

# --- Launcher ----------------------------------------------------------------------------------

say "Adding Kindle to your app menu"
mkdir -p "$APP_DIR" "$BIN_DIR" "$APPS_DIR"
install -m 755 "$here/kindle" "$APP_DIR/kindle"
install -m 644 "$here/lib.sh" "$APP_DIR/lib.sh"
install -m 644 "$here/apkcert.py" "$APP_DIR/apkcert.py"

# Don't clobber a different `kindle` command or a "Kindle" entry from another setup.
cmd_name=kindle
if [[ -e $BIN_DIR/kindle && $(readlink -f "$BIN_DIR/kindle") != "$APP_DIR/kindle" ]]; then
  cmd_name=kindle-waydroid
fi
ln -sfn "$APP_DIR/kindle" "$BIN_DIR/$cmd_name"
state_set command "$cmd_name"
entry_name=Kindle
if grep -lsx 'Name=Kindle' "$APPS_DIR"/*.desktop | grep -qvF -e "$DESKTOP_FILE" -e "$WAYDROID_DESKTOP"; then
  entry_name="Kindle (Waydroid)"
fi
cat >"$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=$entry_name
GenericName=E-book reader
Comment=The Kindle Android app, running in Waydroid
Exec=$APP_DIR/kindle
Icon=$KINDLE_ICON
Terminal=false
Categories=Office;Viewer;
Keywords=ebook;books;reader;amazon;
StartupWMClass=$WINDOW_ID
EOF
hide_waydroid_entry
update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
note "Menu entry \"$entry_name\", command: $cmd_name"
[[ :$PATH: == *":$BIN_DIR:"* ]] || note "($BIN_DIR isn't on your PATH, so run it as $BIN_DIR/$cmd_name)"

say "Done"
note "Open Kindle from your app menu (\"$entry_name\") or with: $cmd_name"
note "The first time, sign in to your Amazon account inside Kindle."
setsid -f "$APP_DIR/kindle" >/dev/null 2>&1 </dev/null
