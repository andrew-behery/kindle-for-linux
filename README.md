# Kindle for Linux

The real **Kindle Android app** on any Linux desktop, in its own window, with your Amazon library,
your **Send to Kindle documents** and your reading position synced with your other devices.

Amazon makes no Kindle app for Linux. The web reader (read.amazon.com) can't open Send to Kindle
documents, and Kindle for PC doesn't run under Wine (2.2+ crash in Amazon's anti-tamper code,
2.1 crashes opening books, 1.x can no longer register; Amazon retired it on June 30, 2026).
This runs Amazon's own Android app, unmodified, with no DRM removal:

- on computers with AMD, Intel or ARM graphics, in [Waydroid](https://waydro.id), a container
  that runs Android on your Linux kernel: light, and drawn by your GPU;
- on NVIDIA-only computers (Waydroid's Android can't use NVIDIA GPUs), in Google's Android
  emulator, using KVM. The installer picks for you.

Kindle's window comes from [scrcpy](https://github.com/Genymobile/scrcpy): Android draws Kindle on
a virtual screen that follows the window, so Kindle fills it whether it's tiled, side by side or
fullscreen, with sharp text on scaled displays.

*Not affiliated with Amazon. Kindle is a trademark of Amazon.com, Inc.*

## Install

Install the package for your distro from the [Releases](https://github.com/andrew-behery/kindle-for-linux/releases) page, or install from source below.

**Arch Linux:**
```sh
curl -fL https://github.com/andrew-behery/kindle-for-linux/releases/download/v0.1.2/kindle-for-linux-0.1.2-1-any.pkg.tar.zst -o /tmp/kindle-for-linux.pkg.tar.zst
sudo pacman -U /tmp/kindle-for-linux.pkg.tar.zst
kindle-for-linux --setup
```
*(Not on the AUR yet because new AUR account registrations are temporarily paused — it will be published there once registrations reopen. A verified `PKGBUILD` is also attached to each [Release](https://github.com/andrew-behery/kindle-for-linux/releases) if you prefer building with `makepkg -si`.)*

**Debian, Ubuntu, Linux Mint:**
```sh
curl -fL https://github.com/andrew-behery/kindle-for-linux/releases/download/v0.1.2/kindle-for-linux_0.1.2_all.deb -o /tmp/kindle-for-linux.deb
sudo apt install /tmp/kindle-for-linux.deb
kindle-for-linux --setup
```

**Fedora:**
```sh
sudo dnf install https://github.com/andrew-behery/kindle-for-linux/releases/download/v0.1.2/kindle-for-linux-0.1.2-1.noarch.rpm
kindle-for-linux --setup
```

**openSUSE:**
```sh
curl -fL https://github.com/andrew-behery/kindle-for-linux/releases/download/v0.1.2/kindle-for-linux-0.1.2-1.noarch.rpm -o /tmp/kindle-for-linux.rpm
sudo zypper install /tmp/kindle-for-linux.rpm
kindle-for-linux --setup
```

**Any distro (from source):**
```sh
git clone https://github.com/andrew-behery/kindle-for-linux.git
cd kindle-for-linux
./install.sh
```

*(If you installed a `.deb`, `.rpm`, or Arch package, clicking **Kindle** in your app menu before running `--setup` also opens a terminal and runs first-time setup automatically.)*

Run setup as your normal user inside your desktop session. It asks for your password when it
needs it (Waydroid's packages and images; KVM access if your distro restricts it), and it's safe
to rerun. **No Google account, no Play Store.** It:

1. checks your computer and picks Waydroid or the emulator,
2. **Waydroid:** installs it with your package manager (pacman, apt, dnf or zypper; on Debian,
   Ubuntu and Mint it adds Waydroid's official apt repository), downloads Android without Google
   (LineageOS 20, about 1 GB, pinned to the spring 2026 images because the September ones crash
   when app windows open and close: [waydroid#2436](https://github.com/waydroid/waydroid/issues/2436)),
   lets Android through your firewall (ufw or firewalld) and adds ARM translation (Kindle only
   ships ARM code),
   **emulator:** downloads Google's Android emulator and its Android 15 "Google APIs" image (about
   2 GB; Google's Google-free images can't run ARM apps), all under `~/.local/share`, and switches
   off the Google apps and services Kindle doesn't need,
3. downloads scrcpy (official build, checksum-verified; ARM64 uses your distro's scrcpy 4.1+),
4. tunes Android for reading: no animations, no screen sleep, light or dark like your desktop,
   and paused (no CPU use) whenever Kindle's window is closed,
5. **downloads Kindle** (Google Play's build, mirrored by
   [APKMirror](https://www.apkmirror.com/apk/amazon-mobile-llc/amazon-kindle/)), **checks it's signed
   with Amazon's Kindle certificate**, and installs it. Amazon's 14.x builds, which other stores
   carry, are its Fire tablet version, which ordinary Android refuses to install,
6. adds **Kindle** to your app menu and opens the sign-in.

Downloads are checksum-verified. Google's emulator and image come under the
[Android SDK License](https://developer.android.com/studio/terms).

**All you do by hand is sign in.** Kindle opens at Amazon's sign-in page; once you're signed in, it
reopens with your library. Ctrl+V pastes there (from a password manager, say). To sign in again
later, use the menu entry's **Sign in to Amazon** action or `kindle --sign-in`.

Amazon marks its sign-in page as secure, and Android blanks secure pages out of screen captures,
which is what Kindle's window shows. So for signing in, Kindle's window uses scrcpy's own server
with one change ([`scrcpy-server/secure-display.patch`](scrcpy-server/secure-display.patch), built
from scrcpy's tagged source by [`scrcpy-server/build.sh`](scrcpy-server/build.sh)): it runs as
Android's system user and marks its screen secure (on the emulator via `adb root`; on Waydroid,
where `adb root` is disabled, as an on-demand `init` service in Waydroid's read-only system
overlay). The system user can't use Android's clipboard, so this is only used until you're signed
in. Where it isn't possible, signing in happens in a separate window showing Android's own screen.

Already have the Kindle APK? `kindle-for-linux --setup --apk kindle.apk` (or `./install.sh --apk kindle.apk`) uses it instead (same checks).

## Use

Open **Kindle** from your app menu, or run `kindle` (`kindle-for-linux` when installed as a system package, or if another `kindle` command was already there).

- The first open after logging in starts Android in the background (about 20 s). After that,
  Android stays loaded but paused while Kindle is closed, so it reopens in about a second.
- Kindle is light or dark like your desktop, and switches when your desktop does. It's read from
  the desktop portal, so it works on GNOME, KDE, Hyprland, Sway and others.
- Copy and paste work between Kindle and your other apps (Ctrl+C / Ctrl+V). Right-click is Back.
- Everything in Kindle is sized like your other apps. For larger or smaller text and buttons
  everywhere, set a density: `KINDLE_DENSITY=200 kindle` (the default is 160 × your display's
  scale). Book text size is also in Kindle's own reading settings.
- `kindle --stop` shuts Android down and frees its memory. `kindle --status` shows its state.
- `kindle --setup`, `kindle --verify [--bench]`, `kindle --uninstall`, and `kindle --version` manage the install from anywhere.

## Requirements

| | Waydroid | Emulator (NVIDIA-only computers) |
|---|---|---|
| CPU | x86_64 or ARM64 | x86_64 with virtualization (VT-x / AMD-V) turned on |
| Kernel | binder support (most distro kernels; Ubuntu/Debian: `linux-modules-extra`) | KVM (every distro kernel) |
| GPU | AMD, Intel or ARM | any (Android draws in software on NVIDIA; fine for reading) |
| RAM | 4 GB or more (Android uses ~1.3 GB) | 8 GB or more (the emulator holds ~3.5 GB) |
| Disk | ~5 GB on the system disk | ~7 GB in your home directory |

A kernel without binder gets the emulator too. Desktop: Wayland or X11 (on Waydroid under X11,
Android runs in a hidden `cage` compositor; tested in nested X11 with Xephyr + Openbox). Image-based systems
(Silverblue, Bazzite, SteamOS) need Waydroid installed their own way first (Bazzite:
`ujust setup-waydroid`), or the emulator: `KINDLE_BACKEND=emulator ./install.sh`.

## Check and measure

Check the install and show disk use, memory, and idle CPU:

```sh
kindle-for-linux --verify
```

Also time opening Kindle, close and reopen it 3 times, and count Android crashes (on Hyprland, also checks that Kindle fills the window when tiled and fullscreen):

```sh
kindle-for-linux --verify --bench
```

*(From a git clone, `./verify.sh` and `./verify.sh --bench` also work.)*

## Uninstall

```sh
kindle-for-linux --uninstall
```

*(From a git clone, `./uninstall.sh` also works.)*

The emulator and everything in it goes with `~/.local/share/kindle-for-linux`. If Waydroid was
already on your computer before, it stays and only Kindle is removed; otherwise Waydroid, Android
and everything in it go, along with any firewall rules and the apt repository this added.
If you installed a system package, remove it afterwards with `apt`, `dnf`, `zypper`, or `pacman`.

## Files

| | |
|---|---|
| `/usr/share/kindle-for-linux/` | system package files (when installed via `.deb`, `.rpm`, or Arch package) |
| `~/.local/share/kindle-for-linux/` | scrcpy and its adb plus the patched server (`scrcpy/`), the adb key (`adb/`), Kindle's icon (and the launcher scripts when installed from a tarball/clone); on the emulator also the emulator and its image (`sdk/`) and Android's data (`avd/`); on Waydroid the ARM translation installer ([waydroid_script](https://github.com/casualsnek/waydroid_script), pinned and checksummed) |
| `~/.local/state/kindle-for-linux/` | `install.log`, `session.log` / `emulator.log`, `window.log`, and what was installed (for uninstall) |
| `/etc/waydroid-extra/images/` | Waydroid: the pinned Android images |
| `/var/lib/waydroid/`, `~/.local/share/waydroid/` | Waydroid: its settings, sign-in overlay service, and Android's data |

## License

MIT ([`LICENSE`](LICENSE)). The bundled patched scrcpy server in `scrcpy-server/` is built from
[Genymobile/scrcpy](https://github.com/Genymobile/scrcpy) under the Apache-2.0 license.
