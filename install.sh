#!/usr/bin/env bash
# Kindle for Linux: sets up the real Kindle Android app, tuned to open fast and stay small. Android
# runs in Waydroid (AMD/Intel/ARM graphics) or, on NVIDIA-only computers, in Google's Android
# emulator. No Google account, no Play Store. The Kindle app (Google Play's build) is downloaded
# and checked against Amazon's signing certificate before it's installed. Kindle's window is
# scrcpy, showing a virtual Android screen that resizes with the window.
#
#   ./install.sh                 run as your normal user, in a terminal inside your desktop session
#   ./install.sh --apk FILE      install Kindle from this APK instead of downloading it (still checked)
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
KINDLE_APK_PAGE=https://www.apkmirror.com/apk/amazon-mobile-llc/amazon-kindle/

# The emulator backend: Google's Android emulator and its Android 15 "Google APIs" image (the
# Google-free images have no ARM translation), pinned and SHA-256 checked. Google's terms apply:
# https://developer.android.com/studio/terms
EMU_VERSION=37.3.10
EMU_ZIP=emulator-linux_x64-16970787.zip
EMU_URL=https://dl.google.com/android/repository/$EMU_ZIP
EMU_SHA256=a4405349d8a9c52136ab7861e5331dc40e85574bd91cb8889a298a2ff4c52e26
EMU_IMAGE_DIR=system-images/android-35/google_apis/x86_64
EMU_IMAGE_VERSION=android-35-google_apis-r09
EMU_IMAGE_ZIP=google_apis-x86_64-35_r09.zip
EMU_IMAGE_URL=https://dl.google.com/android/repository/sys-img/google_apis/x86_64-35_r09.zip
EMU_IMAGE_SHA256=c67b9ba0ff5bc0eb6d046871bfa228af14d4d47b02f0cdae94f048e511b7566e
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

# The Kindle APK. Amazon publishes the app only through Google Play; APKMirror mirrors those
# builds, and getkindle.py downloads the newest. (Other stores carry its Fire tablet build, which
# ordinary Android refuses to install.) --apk FILE replaces the download; if the download fails,
# a suitable APK in the Downloads folder will do. apkcert.py --kindle checks Amazon's certificate
# and that it's the Play build with arm64 code.
kindle_apk_ok() { python3 "$here/apkcert.py" "$1" --kindle "$AMAZON_KINDLE_CERT" 2>/dev/null; }
find_kindle_apk() {
  local dir f
  dir=$(xdg-user-dir DOWNLOAD 2>/dev/null || true)
  [[ -d $dir ]] || dir=$HOME/Downloads
  [[ -d $dir ]] || return 1
  while IFS= read -r f; do
    if kindle_apk_ok "$f"; then
      echo "$f"
      return 0
    fi
  done < <(find "$dir" -maxdepth 2 -type f -iname '*.apk' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n 30 | cut -d' ' -f2-)
  return 1
}
explain_kindle_apk() {
  cat >&2 <<EOF

    The Kindle app couldn't be downloaded automatically. To get it yourself:
    1. Open $KINDLE_APK_PAGE
    2. Pick the newest 8.x version (not 14.x: that's the Fire tablet build), then the
       variant for "arm64-v8a", and download the APK into your Downloads folder.
    3. Run ./install.sh again. The APK is checked against Amazon's signing certificate first.
EOF
}

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

# Which way Android runs (see lib.sh). Waydroid needs binder in the kernel and a GPU its Android
# can draw with: it picks an AMD/Intel/ARM one by itself and skips NVIDIA. Without one, Android
# would draw on the CPU, where its video encoder (which Kindle's window needs) crashes.
has_binder=0
if grep -qw binder /proc/filesystems || modinfo binder_linux >/dev/null 2>&1; then has_binder=1; fi
gpu_drivers=$(for f in /sys/class/drm/renderD*/device/uevent; do if [[ -r $f ]]; then sed -n 's/^DRIVER=//p' "$f"; fi; done | sort -u | xargs)
waydroid_gpu=$(tr ' ' '\n' <<<"$gpu_drivers" | grep -vxe nvidia -e '' | head -n1 || true)
if [[ -n ${KINDLE_BACKEND:-} ]]; then
  BACKEND=$KINDLE_BACKEND
elif [[ -n $waydroid_gpu && $has_binder == 1 ]] || [[ $arch == aarch64 ]]; then
  BACKEND=waydroid
else
  BACKEND=emulator
fi
case $BACKEND in
  waydroid)
    if ((!has_binder)); then
      die "Your kernel has no binder support, which Waydroid's Android needs.
  Ubuntu/Debian/Mint: sudo apt install linux-modules-extra-\$(uname -r), then reboot.
  Arch: use the linux-zen kernel (or install binder_linux-dkms), then reboot.
  Then run this again."
    fi
    [[ -n $waydroid_gpu ]] || die "No GPU Waydroid's Android can draw with (${gpu_drivers:-none found})."
    if [[ -e /run/ostree-booted ]] && ! command -v waydroid >/dev/null; then
      die "This is an image-based system (Silverblue, Bazzite, SteamOS…), where packages can't be added
  the usual way. Install Waydroid the way your system recommends (Bazzite: ujust setup-waydroid), then rerun."
    fi
    ;;
  emulator)
    [[ $arch == x86_64 ]] || die "The Android emulator needs an x86_64 computer."
    [[ -e /dev/kvm ]] || die "The Android emulator needs hardware virtualization (KVM), and /dev/kvm is missing.
  Turn on virtualization (Intel VT-x or AMD-V/SVM) in your firmware settings, then run this again."
    ;;
  *) die "KINDLE_BACKEND must be waydroid or emulator." ;;
esac

pm=""
for candidate in pacman apt-get dnf zypper; do
  if command -v "$candidate" >/dev/null; then
    pm=$candidate
    break
  fi
done
if [[ $BACKEND == waydroid && -z $pm ]] && ! command -v waydroid >/dev/null; then
  die "Couldn't find pacman, apt, dnf or zypper. Install Waydroid with your package manager, then rerun."
fi

mem_gb=$(awk '/MemTotal/ { printf "%d", $2 / 1048576 + 0.5 }' /proc/meminfo)
if [[ $BACKEND == emulator ]]; then
  ((mem_gb >= 8)) || warn "This computer has ${mem_gb} GB of RAM. The emulator holds about 4 GB while Android runs."
  mkdir -p "$DATA_HOME"
  free_gb=$(df -P "$DATA_HOME" | awk 'NR == 2 { printf "%d", $4 / 1048576 }')
  [[ -d $EMU_SDK/emulator ]] || ((free_gb >= 12)) || die "The emulator needs about 12 GB free in $DATA_HOME; there's ${free_gb} GB."
else
  ((mem_gb >= 4)) || warn "This computer has ${mem_gb} GB of RAM. Android needs about 1.5 GB of it while Kindle is open."
  free_gb=$(df -P /etc | awk 'NR == 2 { printf "%d", $4 / 1048576 }')
  ((free_gb >= 5)) || die "Android needs about 5 GB free on your system disk; there's ${free_gb} GB."
fi

if [[ $arch == x86_64 && $BACKEND == waydroid ]]; then
  # Kindle ships ARM code only, so x86_64 machines need a translation layer. Intel's libhoudini
  # runs best on Intel CPUs; Google's libndk on AMD. (The emulator's image has its own.)
  if grep -q GenuineIntel /proc/cpuinfo; then arm_layer=libhoudini; else arm_layer=libndk; fi
fi

say "Kindle for Linux"
note "Desktop: $mode${pm:+, package manager: ${pm%-get}}"
if [[ $BACKEND == waydroid ]]; then
  note "Android: Waydroid, drawing with the GPU ($waydroid_gpu)"
  [[ $arch == x86_64 ]] && note "ARM translation: $arm_layer (Kindle is ARM-only)"
else
  why="no GPU Waydroid can use (${gpu_drivers:-none found})"
  ((has_binder)) || why="no binder support in this kernel"
  [[ -z ${KINDLE_BACKEND:-} ]] || why="KINDLE_BACKEND=emulator"
  if [[ $(emu_gpu) == host ]]; then drawing="the GPU"; else drawing="the CPU (SwiftShader)"; fi
  note "Android: Google's Android emulator ($why), drawing with $drawing"
fi
note "Log: $LOG"
if [[ -n $apk_arg ]]; then
  note "Kindle app: $apk_arg"
else
  note "Kindle app: Google Play's build, from APKMirror (checked) if it isn't installed yet"
fi
[[ $BACKEND != waydroid || $mode != x11 ]] || note "X11 desktop: Waydroid will run in a hidden cage compositor."
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
      [[ -t 0 ]] || die "This step needs your password: run setup in a terminal on this computer."
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

# Download to a file unless it's already there, and check its SHA-256 either way.
fetch_verified() { # url sha256 file
  local url=$1 sum=$2 file=$3
  if [[ -f $file ]] && echo "$sum  $file" | sha256sum -c --quiet - 2>/dev/null; then return 0; fi
  curl -fL --retry 3 --progress-bar "$url" -o "$file.part"
  echo "$sum  $file.part" | sha256sum -c --quiet - || die "$(basename "$file") didn't match its checksum. Try again later."
  mv "$file.part" "$file"
}

state_set backend "$BACKEND"

if [[ $BACKEND == waydroid ]]; then # --- Waydroid: up to "Kindle's window" ---------------------

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

fi # --- end of the Waydroid-only part --------------------------------------------------------

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
  # The same scrcpy server, patched to show Amazon's sign-in page in Kindle's window (see
  # scrcpy-server/build.sh). It only pairs with this exact scrcpy version.
  install -m 644 "$here/scrcpy-server/scrcpy-server-secure" "$SCRCPY_DIR/scrcpy-server-secure"
else
  v=$(scrcpy --version 2>/dev/null | awk 'NR == 1 { print $2 }')
  [[ -n $v && $(printf '%s\n' 4.1 "$v" | sort -V | head -n1) == 4.1 ]] ||
    die "Kindle's window needs scrcpy 4.1 or newer; your distro has ${v:-none}. Install a newer scrcpy, then rerun."
  note "scrcpy $v (from your distro)"
fi

# --- The Android emulator ----------------------------------------------------------------------

if [[ $BACKEND == emulator ]]; then
  # KVM runs Android at near-native speed. Most distros let everyone use it; others need the
  # kvm group, which takes effect at the next login (an ACL gives access right away).
  if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
    say "Letting you use KVM (hardware virtualization)"
    getent group kvm >/dev/null || root groupadd -r kvm
    root usermod -aG kvm "$USER"
    if command -v setfacl >/dev/null; then root setfacl -m "u:$USER:rw" /dev/kvm; fi
    state_set kvm_group_added 1
    [[ -r /dev/kvm && -w /dev/kvm ]] || die "Log out and back in (to join the kvm group), then run this again."
  fi

  say "Google's Android emulator and Android 15 (about 2 GB to download)"
  note "From Google, under the Android SDK License: https://developer.android.com/studio/terms"
  mkdir -p "$CACHE_DIR" "$EMU_SDK/platforms" "$EMU_SDK/platform-tools"
  if [[ $(cat "$EMU_SDK/emulator/kindle-for-linux.version" 2>/dev/null) == "$EMU_VERSION" ]]; then
    note "Emulator $EMU_VERSION is already installed."
  else
    fetch_verified "$EMU_URL" "$EMU_SHA256" "$CACHE_DIR/$EMU_ZIP"
    rm -rf "$EMU_SDK/emulator"
    unzip -q "$CACHE_DIR/$EMU_ZIP" -d "$EMU_SDK"
    echo "$EMU_VERSION" >"$EMU_SDK/emulator/kindle-for-linux.version"
    rm -f "$CACHE_DIR/$EMU_ZIP"
  fi
  if [[ $(cat "$EMU_SDK/$EMU_IMAGE_DIR/kindle-for-linux.version" 2>/dev/null) == "$EMU_IMAGE_VERSION" ]]; then
    note "Android 15 ($EMU_IMAGE_VERSION) is already installed."
  else
    fetch_verified "$EMU_IMAGE_URL" "$EMU_IMAGE_SHA256" "$CACHE_DIR/$EMU_IMAGE_ZIP"
    rm -rf "${EMU_SDK:?}/${EMU_IMAGE_DIR:?}"
    mkdir -p "$(dirname "$EMU_SDK/$EMU_IMAGE_DIR")"
    unzip -q "$CACHE_DIR/$EMU_IMAGE_ZIP" -d "$(dirname "$EMU_SDK/$EMU_IMAGE_DIR")"
    echo "$EMU_IMAGE_VERSION" >"$EMU_SDK/$EMU_IMAGE_DIR/kindle-for-linux.version"
    rm -f "$CACHE_DIR/$EMU_IMAGE_ZIP"
  fi
  # The emulator calls adb itself: give it ours, so it talks to our adb server, not yours.
  ln -sfn "$(adb_bin)" "$EMU_SDK/platform-tools/adb"
  mkdir -p "$ADB_HOME/.android"
  [[ -f $ADB_HOME/.android/adbkey ]] || kfl_adb keygen "$ADB_HOME/.android/adbkey" >/dev/null 2>&1

  # The virtual device. 2.5 GB is ample once Google's background apps are off (Android then
  # uses ~1.3 GB with Kindle open). No cameras or sensors. Its own screen only appears for
  # signing in (Kindle has its own window otherwise): a phone shape with large text, readable
  # even in a narrow tile.
  cores=$(nproc)
  ((cores <= 4)) || cores=4
  # Earlier versions named the device kindle-for-linux: keep its Android data under the new name.
  if [[ -d $EMU_AVD_HOME/kindle-for-linux.avd && ! -e $EMU_AVD_HOME/$EMU_AVD.avd ]]; then
    stop_android
    mv "$EMU_AVD_HOME/kindle-for-linux.avd" "$EMU_AVD_HOME/$EMU_AVD.avd"
    rm -f "$EMU_AVD_HOME/kindle-for-linux.ini"
  fi
  mkdir -p "$EMU_AVD_HOME/$EMU_AVD.avd"
  printf 'avd.ini.encoding=UTF-8\npath=%s\ntarget=android-35\n' "$EMU_AVD_HOME/$EMU_AVD.avd" >"$EMU_AVD_HOME/$EMU_AVD.ini"
  cat >"$EMU_AVD_HOME/$EMU_AVD.avd/config.ini" <<EOF
AvdId=$EMU_AVD
avd.ini.displayname=Kindle for Linux
avd.ini.encoding=UTF-8
abi.type=x86_64
hw.cpu.arch=x86_64
hw.cpu.ncore=$cores
hw.ramSize=2560
disk.dataPartition.size=8G
image.sysdir.1=$EMU_IMAGE_DIR/
tag.id=google_apis
tag.display=Google APIs
target=android-35
PlayStore.enabled=false
hw.gpu.enabled=yes
hw.lcd.width=720
hw.lcd.height=1280
hw.lcd.density=320
hw.keyboard=yes
hw.mainKeys=no
hw.dPad=no
hw.trackBall=no
hw.camera.back=none
hw.camera.front=none
hw.audioInput=no
hw.accelerometer=no
hw.gyroscope=no
hw.gps=no
hw.sensors.proximity=no
hw.sensors.magnetic_field=no
hw.sensors.orientation=no
hw.sensors.temperature=no
hw.sensors.light=no
hw.sensors.pressure=no
hw.sensors.humidity=no
showDeviceFrame=no
fastboot.forceColdBoot=yes
EOF
  note "Virtual device ready ($cores cores, 2.5 GB)."
fi

# --- Android settings --------------------------------------------------------------------------

say "Starting Android (the first start takes a minute or two)"
start_android 300 || die "Android didn't start. Details: $STATE_DIR/"

say "Tuning Android for reading"
if [[ $BACKEND == waydroid ]]; then
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
  # Clean up properties an earlier version wrote to waydroid.cfg (Waydroid's adbd has `adb root`
  # compiled out, so they aren't needed; sign-in uses the overlay service below instead).
  if [[ -n $(state_get debuggable_set_by_us) ]]; then
    root python3 - "$WAYDROID_CFG" <<'PYCFG'
import configparser, sys
cfg = configparser.ConfigParser()
cfg.optionxform = str
cfg.read(sys.argv[1])
if cfg.has_section("properties"):
    for key in ("ro.debuggable", "lineage.service.adb.root"):
        cfg.remove_option("properties", key)
with open(sys.argv[1], "w") as f:
    cfg.write(f)
PYCFG
    stop_android
    root waydroid upgrade --offline >/dev/null 2>&1 || true
    state_set debuggable_set_by_us ""
    changed=1
  fi
  # Sign-in inside Kindle's window needs the patched scrcpy server to run as Android's system user
  # (uid 1000) so it can create a secure virtual screen. Waydroid's adbd refuses `adb root`, so
  # place the pinned server in Waydroid's system overlay as an init service started only on demand.
  if [[ -f $SCRCPY_DIR/scrcpy-server-secure ]]; then
    overlay=/var/lib/waydroid/overlay/system
    if ! cmp -s "$SCRCPY_DIR/scrcpy-server-secure" "$overlay/framework/kfl-scrcpy-server.jar" ||
      ! cmp -s "$here/scrcpy-server/kfl-scrcpy-server" "$overlay/bin/kfl-scrcpy-server" ||
      ! cmp -s "$here/scrcpy-server/kfl-scrcpy.rc" "$overlay/etc/init/kfl-scrcpy.rc"; then
      stop_android
      root install -Dm 644 "$SCRCPY_DIR/scrcpy-server-secure" "$overlay/framework/kfl-scrcpy-server.jar"
      root install -Dm 755 "$here/scrcpy-server/kfl-scrcpy-server" "$overlay/bin/kfl-scrcpy-server"
      root install -Dm 644 "$here/scrcpy-server/kfl-scrcpy.rc" "$overlay/etc/init/kfl-scrcpy.rc"
      state_set waydroid_signin_service 1
      changed=1
    fi
  fi
  if ((changed)); then
    note "Restarting Android so the changes take effect"
    stop_android
    start_android 180 || die "Android didn't restart. Details: $STATE_DIR/session.log"
  fi
  android_wake

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
    # shellcheck disable=SC2016
    "${run[@]}" bash -c '
      f=$1/adb_keys key=$(<"$2")
      grep -qsF "${key%% *}" "$f" && exit 0
      if [[ -s $f && -n $(tail -c1 "$f") ]]; then echo >>"$f"; fi # adb writes keys without a newline
      printf "%s\n" "$key" >>"$f"
      chmod 640 "$f"
      chown 1000:2000 "$f" 2>/dev/null || true' _ "$dir" "$ADB_HOME/.android/adbkey.pub"
  }
  trust_adb_key
fi
serial=$(android_connect 60) || die "Couldn't connect to Android with adb. Details: $LOG"
adb_shell() { kfl_adb -s "$serial" shell "$@"; }

if [[ $BACKEND == emulator && $(state_get android_trimmed) != 1 ]]; then
  # Google's apps and services on this image keep working in the background, and Kindle needs
  # none of them: switched off (not removed), Android uses ~400 MB less and idles quieter.
  for pkg in com.google.android.gms com.google.android.gsf com.android.vending com.google.android.googlequicksearchbox \
    com.google.android.apps.wellbeing com.google.android.as com.google.android.as.oss com.google.android.apps.messaging \
    com.google.android.apps.maps com.google.android.apps.photos com.google.android.apps.docs \
    com.google.android.apps.youtube.music com.google.android.gm com.google.android.calendar com.google.android.dialer \
    com.google.android.contacts com.android.chrome com.google.android.apps.restore com.google.android.apps.safetyhub \
    com.google.android.feedback com.google.android.partnersetup; do
    adb_shell pm disable-user --user 0 "$pkg" >/dev/null 2>&1 || true
  done
  state_set android_trimmed 1
fi
# These live in Android's data, so they survive restarts and image switches: set them once.
# No window animations (pages and menus appear at once), and no
# screen sleep, which would blank the page you're reading (Android is paused whenever Kindle's
# window is closed, so this costs nothing). Each backend has its own Android, so its own flag.
tuned_key=android_tuned
[[ $BACKEND == waydroid ]] || tuned_key=android_tuned_$BACKEND
if [[ $(state_get "$tuned_key") != 2 ]]; then
  for key in window_animation_scale transition_animation_scale animator_duration_scale; do
    adb_shell settings put global "$key" 0 || warn "Couldn't set $key."
  done
  adb_shell settings put system screen_off_timeout 2147483647 || warn "Couldn't turn off screen sleep."
  state_set "$tuned_key" 2
fi
# Light or dark like the desktop (the launcher keeps them matched from then on).
state_set "night_$BACKEND" ""
match_color_scheme "$serial"
note "Paused while Kindle is closed, no animations, no screen sleep, $(desktop_color_scheme || true) like your desktop."

# --- Kindle ------------------------------------------------------------------------------------

# Kindle's own icon, for the menu entry and the window: the sharpest bitmap in the APK, as PNG
# (works everywhere) when something can convert its WebP, else as it is.
save_kindle_icon() {
  local icon conv
  mkdir -p "$APP_DIR"
  icon=$(python3 "$here/apkicon.py" "$1" "$APP_DIR/kindle" 2>/dev/null) || return 0
  [[ $icon == *.webp ]] || return 0
  for conv in "magick $icon $APP_DIR/kindle.png" "convert $icon $APP_DIR/kindle.png" \
    "dwebp -quiet $icon -o $APP_DIR/kindle.png" "ffmpeg -loglevel error -y -i $icon $APP_DIR/kindle.png"; do
    if command -v "${conv%% *}" >/dev/null && $conv 2>/dev/null && [[ -s $APP_DIR/kindle.png ]]; then
      rm -f "$icon"
      return 0
    fi
  done
}

# Checks an APK is Amazon's Play build of Kindle: 0 = yes, else explains why not and exits.
check_kindle_apk() {
  local rc=0
  python3 "$here/apkcert.py" "$1" --kindle "$AMAZON_KINDLE_CERT" || rc=$?
  case $rc in
    0) note "Signed with Amazon's Kindle certificate; the Google Play build." ;;
    3 | 4) die "$(basename "$1") is the wrong build of Kindle (see above)." ;;
    *) die "$(basename "$1") is NOT signed by Amazon's Kindle certificate. Not installing it." ;;
  esac
}

had_kindle=""
[[ $(adb_shell pm path "$KINDLE_PKG" 2>/dev/null) != package:* ]] || had_kindle=1
if [[ -n $had_kindle && -z $apk_arg ]]; then
  note "Kindle is already installed."
else
  apk=$apk_arg downloaded=""
  if [[ -n $apk ]]; then
    say "Checking $(basename "$apk") is genuinely Amazon's Kindle"
    check_kindle_apk "$apk"
  else
    say "Downloading the Kindle app (Google Play's build, from APKMirror)"
    mkdir -p "$CACHE_DIR"
    apk=$CACHE_DIR/kindle.apk
    if version=$(python3 "$here/getkindle.py" "$apk"); then
      note "Kindle $version"
      check_kindle_apk "$apk"
      downloaded=1
    elif apk=$(find_kindle_apk); then
      note "Couldn't download it, but found one in your Downloads: $(basename "$apk")"
      note "Signed with Amazon's Kindle certificate; the Google Play build."
    else
      explain_kindle_apk
      die "Couldn't download the Kindle app. Everything else is set up, so the rerun is quick."
    fi
  fi
  say "Installing Kindle (Android prepares the app under ARM translation, which takes a minute)"
  # -r keeps an installed Kindle's data (your sign-in and books) when replacing it.
  out=$(timeout 600 env HOME="$ADB_HOME" "$(adb_bin)" -s "$serial" install -r "$apk" 2>&1) || true
  [[ $out == *Success* ]] || die "Kindle didn't install: ${out##*$'\n'}"
  note "Installed."
  [[ -n $had_kindle ]] || fresh_kindle=1 # a new Kindle starts signed out
  rm -f "$APP_DIR"/kindle.png "$APP_DIR"/kindle.webp # a new Kindle may bring a new icon
  save_kindle_icon "$apk"
  [[ -z $downloaded ]] || rm -f "$apk"
fi
if [[ ! -f $APP_DIR/kindle.png && ! -f $APP_DIR/kindle.webp ]]; then
  # Kindle was already installed: take the icon from Android's copy of the app.
  installed=$(adb_shell pm path "$KINDLE_PKG" 2>/dev/null | tr -d '\r' | sed -n 's/^package://p' | head -n1)
  if [[ -n $installed ]] && kfl_adb -s "$serial" pull "$installed" "$CACHE_DIR/installed.apk" >/dev/null 2>&1; then
    save_kindle_icon "$CACHE_DIR/installed.apk"
    rm -f "$CACHE_DIR/installed.apk"
  fi
fi

# Kindle's phone layout (used when the window is under 600 px tall, or narrow) locks itself to
# portrait, which leaves a wide window letterboxed: Kindle in a strip down the middle. Android's
# compatibility overrides make it follow the window instead: whatever orientation Kindle asks
# for becomes "the screen's own". They belong to Kindle's install, so set them every run.
for change in OVERRIDE_ANY_ORIENTATION OVERRIDE_UNDEFINED_ORIENTATION_TO_NOSENSOR; do
  adb_shell am compat enable "$change" "$KINDLE_PKG" >/dev/null ||
    warn "Couldn't set $change: Kindle may show black bars in wide windows."
done

# Kindle asks for some Android permissions, and Android's question would appear where nobody can
# see it (on Android's own screen, or blanked out of Kindle's window). Settle them up front:
# notifications allowed (they never show anywhere), the rest (Bluetooth, phone state, storage:
# nothing Kindle needs for reading) denied for good, so it doesn't ask.
adb_shell pm grant "$KINDLE_PKG" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
for perm in BLUETOOTH_CONNECT BLUETOOTH_SCAN BLUETOOTH_ADVERTISE READ_PHONE_STATE READ_EXTERNAL_STORAGE; do
  adb_shell pm revoke "$KINDLE_PKG" "android.permission.$perm" >/dev/null 2>&1 || true
  adb_shell pm set-permission-flags "$KINDLE_PKG" "android.permission.$perm" user-set user-fixed >/dev/null 2>&1 || true
done

# --- Launcher ----------------------------------------------------------------------------------

say "Adding Kindle to your app menu"
mkdir -p "$APP_DIR" "$BIN_DIR" "$APPS_DIR"
if [[ $here == "$PKG_DIR" ]]; then
  # Installed via system package (.deb / .rpm / AUR): run straight from /usr/share/kindle-for-linux
  # so package upgrades update the launcher and helpers immediately.
  rm -f "$APP_DIR"/{VERSION,kindle,lib.sh,install.sh,uninstall.sh,verify.sh,adb-system,apkcert.py,getkindle.py,apkicon.py}
  launcher=/usr/bin/kindle-for-linux
  cmd_name=kindle-for-linux
  if [[ ! -e $BIN_DIR/kindle || $(readlink -f "$BIN_DIR/kindle" 2>/dev/null) == "$PKG_DIR/kindle" || $(readlink -f "$BIN_DIR/kindle" 2>/dev/null) == "$APP_DIR/kindle" ]]; then
    ln -sfn "$launcher" "$BIN_DIR/kindle"
  fi
  state_set packaged 1
else
  install -m 755 "$here/kindle" "$here/install.sh" "$here/uninstall.sh" "$here/verify.sh" "$APP_DIR/"
  install -m 644 "$here/lib.sh" "$here/apkcert.py" "$here/getkindle.py" "$here/apkicon.py" "$APP_DIR/"
  [[ ! -f $here/VERSION ]] || install -m 644 "$here/VERSION" "$APP_DIR/VERSION"
  mkdir -p "$APP_DIR/scrcpy-server"
  install -m 755 "$here/scrcpy-server/adb-system" "$APP_DIR/adb-system"
  install -m 755 "$here/scrcpy-server/adb-system" "$here/scrcpy-server/kfl-scrcpy-server" "$APP_DIR/scrcpy-server/"
  install -m 644 "$here/scrcpy-server/kfl-scrcpy.rc" "$here/scrcpy-server/scrcpy-server-secure" "$APP_DIR/scrcpy-server/"
  launcher=$APP_DIR/kindle
  # Don't clobber a different `kindle` command or a "Kindle" entry from another setup.
  cmd_name=kindle
  if [[ -e $BIN_DIR/kindle && $(readlink -f "$BIN_DIR/kindle") != "$APP_DIR/kindle" ]]; then
    cmd_name=kindle-for-linux
  fi
  prev=$(state_get command)
  if [[ -n $prev && $prev != "$cmd_name" && $(readlink -f "$BIN_DIR/$prev" 2>/dev/null) == "$APP_DIR/kindle" ]]; then
    rm -f "$BIN_DIR/$prev" # this installer's own command under an earlier name
  fi
  ln -sfn "$APP_DIR/kindle" "$BIN_DIR/$cmd_name"
  if [[ $cmd_name != kindle-for-linux && (! -e $BIN_DIR/kindle-for-linux || $(readlink -f "$BIN_DIR/kindle-for-linux" 2>/dev/null) == "$APP_DIR/kindle") ]]; then
    ln -sfn "$APP_DIR/kindle" "$BIN_DIR/kindle-for-linux"
  fi
  state_set packaged ""
fi
# The icon: the one saved from the APK, else Waydroid's copy, else the package SVG (lib.sh picks).
KINDLE_ICON=$APP_DIR/kindle.png
[[ -f $KINDLE_ICON ]] || KINDLE_ICON=$APP_DIR/kindle.webp
[[ -f $KINDLE_ICON ]] || KINDLE_ICON=$WAYDROID_DATA/data/icons/$KINDLE_PKG.png
[[ -f $KINDLE_ICON ]] || KINDLE_ICON=kindle-for-linux

state_set command "$cmd_name"
entry_name=Kindle
if (grep -lsx 'Name=Kindle' "$APPS_DIR"/*.desktop 2>/dev/null || true) | grep -qvF -e "$DESKTOP_FILE" -e "$WAYDROID_DESKTOP"; then
  entry_name="Kindle for Linux"
fi
cat >"$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=$entry_name
GenericName=E-book reader
Comment=The Kindle Android app, running in $([[ $BACKEND == emulator ]] && echo "Google's Android emulator" || echo Waydroid)
Exec=$launcher
Icon=$KINDLE_ICON
Terminal=false
Categories=Office;Viewer;
Keywords=ebook;books;reader;amazon;
StartupWMClass=$WINDOW_ID
Actions=sign-in;setup;

[Desktop Action sign-in]
Name=Sign in to Amazon
Exec=$launcher --sign-in

[Desktop Action setup]
Name=Run setup
Exec=$launcher --setup
EOF
hide_waydroid_entry
update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
note "Menu entry \"$entry_name\", command: $cmd_name"
if [[ $here != "$PKG_DIR" && :$PATH: != *":$BIN_DIR:"* ]]; then
  note "($BIN_DIR isn't on your PATH, so run it as $BIN_DIR/$cmd_name)"
fi

say "Done"
note "Open Kindle from your app menu (\"$entry_name\") or with: $cmd_name"
if [[ -n ${fresh_kindle:-} ]]; then
  # Amazon's sign-in page can't show in Kindle's usual window (see `kindle --sign-in`), so the
  # first open is the sign-in window.
  say "Last step: sign in to Amazon"
  note "Kindle opens in a moment at Amazon's sign-in page. Once you're signed in, it reopens"
  note "with your library."
  note "(To sign in again later: the menu entry's \"Sign in to Amazon\" action, or $cmd_name --sign-in.)"
  setsid -f "$launcher" --sign-in >/dev/null 2>&1 </dev/null
else
  setsid -f "$launcher" >/dev/null 2>&1 </dev/null
fi
