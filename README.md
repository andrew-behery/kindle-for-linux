# Kindle for Linux

The real **Kindle Android app** on any Linux desktop, in its own window, with your Amazon library,
your **Send to Kindle documents** and your reading position synced with your other devices.

Amazon makes no Kindle app for Linux. The web reader (read.amazon.com) can't open Send to Kindle
documents, and Kindle for PC doesn't run under Wine (2.2+ crash in Amazon's anti-tamper code,
2.1 crashes opening books, 1.x can no longer register; Amazon retired it on June 30, 2026).
This runs Amazon's own Android app in [Waydroid](https://waydro.id), a container that runs Android
on your Linux kernel: no virtual machine, no DRM removal, nothing modified.

*Not affiliated with Amazon. Kindle is a trademark of Amazon.com, Inc.*

## Install

```sh
git clone https://github.com/andrew-behery/kindle-for-linux.git
cd kindle-for-linux
./install.sh
```

Run it as your normal user in a terminal inside your desktop. It asks for your password once,
and it's safe to rerun. **No Google account, no Play Store, no device registration.** It:

1. installs Waydroid with your package manager (pacman, apt, dnf or zypper; on Debian, Ubuntu
   and Mint it adds Waydroid's official apt repository), plus clipboard sharing,
2. downloads Android without Google (LineageOS 20, about 1 GB, checksum-verified). It's pinned to
   the spring 2026 images, because the September ones crash whenever an app window opens or
   closes ([waydroid#2436](https://github.com/waydroid/waydroid/issues/2436)),
3. lets Android through your firewall (ufw or firewalld) if one is on,
4. on Intel/AMD computers, adds ARM translation (Kindle only ships ARM code),
5. tunes Android for reading: no animations, dark mode, and sleep (no CPU use) when Kindle
   isn't open,
6. downloads the Kindle app and **checks it's signed with Amazon's Kindle certificate** before
   installing it (or use `./install.sh --apk kindle.apk` with an APK you already have; same check),
7. adds **Kindle** to your app menu and opens it.

All you do by hand: type your password, then sign in to Amazon in Kindle.

## Use

Open **Kindle** from your app menu, or run `kindle`.

- The first open after logging in starts Android in the background (about 10–20 s). After that,
  Android stays loaded but frozen while Kindle is closed, so it opens again quickly.
- `kindle --stop` shuts Android down and frees its memory. `kindle --status` shows its state.

## Requirements

| | |
|---|---|
| CPU | x86_64 (Intel/AMD) or ARM64 |
| Kernel | binder support. Most distro kernels have it; on Ubuntu/Debian it's in `linux-modules-extra`, on Arch use `linux-zen` if yours lacks it |
| Desktop | Wayland: Android opens in a window of its own. X11 works through `cage` (experimental) |
| GPU | AMD, Intel and ARM GPUs draw Android's graphics. On NVIDIA-only machines Android draws on the CPU (tested on a GTX 1660 Ti: Kindle opens and reads fine) |
| RAM | 4 GB or more |
| Disk | about 5 GB on the system disk (`/etc/waydroid-extra/images`, `/var/lib/waydroid`) |

Image-based systems (Silverblue, Bazzite, SteamOS) can't take new packages the usual way:
install Waydroid the way your system recommends (Bazzite: `ujust setup-waydroid`), then run `./install.sh`.

## Check and measure

```sh
./verify.sh          # checks the install, shows disk use, memory and idle CPU
./verify.sh --bench  # also times opening Kindle (Hyprland only for now)
```

## Uninstall

```sh
./uninstall.sh
```

If Waydroid was already on your computer before, it stays and only Kindle is removed. Otherwise
Waydroid, Android and everything in it go, along with any firewall rules and the apt repository
this added.

## Files

| | |
|---|---|
| `~/.local/share/kindle-for-linux/` | the launcher, and the ARM translation installer ([waydroid_script](https://github.com/casualsnek/waydroid_script), pinned and checksummed) |
| `~/.local/state/kindle-for-linux/` | `install.log`, `session.log`, and what was installed (for uninstall) |
| `/etc/waydroid-extra/images/` | the pinned Android images |
| `/var/lib/waydroid/`, `~/.local/share/waydroid/` | Waydroid's settings and Android's data |
