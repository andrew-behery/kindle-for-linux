#!/usr/bin/env bash
# Offline unit and CLI tests for Kindle for Linux helpers.
# Runs with an isolated HOME/XDG state so it never touches the host user's setup.
set -euo pipefail

ROOT=$(dirname "$(dirname "$(readlink -f "$0")")")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export HOME=$TMP/home
export XDG_DATA_HOME=$TMP/data
export XDG_STATE_HOME=$TMP/state
export XDG_CACHE_HOME=$TMP/cache
mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"

PASS=0
FAIL=0

assert_eq() {
  local name=$1 want=$2 got=$3
  if [[ $got == "$want" ]]; then
    printf '  ok   %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL %s\n    want: %q\n    got:  %q\n' "$name" "$want" "$got" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local name=$1 needle=$2 hay=$3
  if [[ $hay == *"$needle"* ]]; then
    printf '  ok   %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL %s (missing %q)\n' "$name" "$needle" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local name=$1 needle=$2 hay=$3
  if [[ $hay != *"$needle"* ]]; then
    printf '  ok   %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL %s (unexpectedly contained %q)\n' "$name" "$needle" >&2
    FAIL=$((FAIL + 1))
  fi
}

# --- lib.sh tests ------------------------------------------------------------------------------

printf '==> lib.sh\n'
# shellcheck source=lib.sh
source "$ROOT/lib.sh"

# state_get / state_set
assert_eq "state_get missing file returns empty" "" "$(state_get foo)"
state_set alpha one
state_set beta "two=three four"
assert_eq "state_get reads simple key" "one" "$(state_get alpha)"
assert_eq "state_get preserves = and spaces" "two=three four" "$(state_get beta)"
state_set alpha updated
assert_eq "state_set updates key in place" "updated" "$(state_get alpha)"
assert_eq "state_set preserves sibling keys" "two=three four" "$(state_get beta)"
state_set alpha ""
assert_eq "state_set empty removes key" "" "$(state_get alpha)"
assert_eq "state_set removal preserves sibling keys" "two=three four" "$(state_get beta)"

# display_mode
assert_eq "display_mode wayland" "wayland" "$(env -u DISPLAY WAYLAND_DISPLAY=wayland-1 bash -c "source '$ROOT/lib.sh'; display_mode")"
assert_eq "display_mode x11" "x11" "$(env -u WAYLAND_DISPLAY DISPLAY=:0 bash -c "source '$ROOT/lib.sh'; display_mode")"
assert_eq "display_mode none" "none" "$(env -u WAYLAND_DISPLAY -u DISPLAY bash -c "source '$ROOT/lib.sh'; display_mode")"

# json_monitor_scale across Hyprland, Sway, KDE, wlr-randr
hypr_json='[{"name":"DP-1","focused":false,"scale":1.00},{"name":"HDMI-A-1","focused":true,"scale":1.50}]'
assert_eq "json_monitor_scale Hyprland focused" "1.50" \
  "$(printf '%s\n' "$hypr_json" | json_monitor_scale 1 '' '"focused"[[:space:]]*:[[:space:]]*true')"

sway_json='[
  {"name": "DP-1", "active": false, "focused": true, "scale": 2.0},
  {"name": "eDP-1", "active": true, "focused": false, "scale": 1.25},
  {"name": "HDMI-1", "active": true, "focused": true, "scale": 1.75}
]'
assert_eq "json_monitor_scale Sway active+focused" "1.75" \
  "$(printf '%s\n' "$sway_json" | json_monitor_scale 1 '"active"[[:space:]]*:[[:space:]]*true' '"focused"[[:space:]]*:[[:space:]]*true')"

kde_json='{"outputs":[{"enabled":true,"priority":10,"scale":2},{"enabled":true,"priority":1,"scale":1.5},{"enabled":false,"priority":1,"scale":3}]}'
assert_eq "json_monitor_scale KDE priority 1 (not 10)" "1.5" \
  "$(printf '%s\n' "$kde_json" | json_monitor_scale 2 '"enabled"[[:space:]]*:[[:space:]]*true' '"priority"[[:space:]]*:[[:space:]]*1([^0-9]|$)')"

wlr_json='[{"name":"DP-1","enabled":false,"scale":2.0},{"name":"eDP-1","enabled":true,"scale":1.6}]'
assert_eq "json_monitor_scale wlr-randr enabled" "1.6" \
  "$(printf '%s\n' "$wlr_json" | json_monitor_scale 1 '"enabled"[[:space:]]*:[[:space:]]*true' '')"

# display_scale with mocked compositor binaries
STUB=$TMP/stubs
mkdir -p "$STUB"
cat >"$STUB/xrdb" <<'EOF'
#!/usr/bin/env bash
printf 'Xft.dpi:\t144\n'
EOF
cat >"$STUB/hyprctl" <<'EOF'
#!/usr/bin/env bash
printf '[{"name":"eDP-1","focused":true,"scale":1.60}]\n'
EOF
cat >"$STUB/gdbus" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"org.gnome.Mutter.DisplayConfig"* ]]; then
  printf "(uint32 1, [], [(0, 0, 1.0, uint32 0, false, []), (1920, 0, 2.0, uint32 0, true, [])], {})\n"
elif [[ "$*" == *"org.freedesktop.appearance color-scheme"* ]]; then
  printf '%s\n' "${MOCK_PORTAL_OUT:-}"
  exit "${MOCK_PORTAL_RC:-0}"
fi
EOF
cat >"$STUB/gsettings" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${MOCK_GSETTINGS_OUT:-}"
EOF
cat >"$STUB/kreadconfig6" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${MOCK_KDE_COLOR:-}"
EOF
chmod +x "$STUB"/*

assert_eq "display_scale X11 xrdb Xft.dpi=144" "1.500" \
  "$(PATH="$STUB:$PATH" env -u WAYLAND_DISPLAY DISPLAY=:0 bash -c "source '$ROOT/lib.sh'; display_scale")"
assert_eq "display_scale Hyprland focused" "1.60" \
  "$(PATH="$STUB:$PATH" env -u DISPLAY WAYLAND_DISPLAY=wayland-1 HYPRLAND_INSTANCE_SIGNATURE=abc bash -c "source '$ROOT/lib.sh'; display_scale")"
assert_eq "display_scale GNOME primary monitor" "2.0" \
  "$(PATH="$STUB:$PATH" env -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u SWAYSOCK WAYLAND_DISPLAY=wayland-1 XDG_CURRENT_DESKTOP=ubuntu:GNOME bash -c "source '$ROOT/lib.sh'; display_scale")"
assert_eq "display_scale GDK_SCALE fallback" "2" \
  "$(PATH="/usr/bin:/bin" env -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u SWAYSOCK -u XDG_CURRENT_DESKTOP WAYLAND_DISPLAY=wayland-1 GDK_SCALE=2 bash -c "source '$ROOT/lib.sh'; display_scale")"

# desktop_color_scheme
assert_eq "desktop_color_scheme portal dark" "dark" \
  "$(PATH="$STUB:$PATH" MOCK_PORTAL_OUT='(<uint32 1>,)' bash -c "source '$ROOT/lib.sh'; desktop_color_scheme")"
assert_eq "desktop_color_scheme portal light" "light" \
  "$(PATH="$STUB:$PATH" MOCK_PORTAL_OUT='(<uint32 2>,)' bash -c "source '$ROOT/lib.sh'; desktop_color_scheme")"
assert_eq "desktop_color_scheme portal nopref -> gsettings dark" "dark" \
  "$(PATH="$STUB:$PATH" MOCK_PORTAL_OUT='(<uint32 0>,)' MOCK_GSETTINGS_OUT="'prefer-dark'" bash -c "source '$ROOT/lib.sh'; desktop_color_scheme")"
assert_eq "desktop_color_scheme fallback -> KDE BreezeDark" "dark" \
  "$(PATH="$STUB:$PATH" MOCK_PORTAL_RC=1 MOCK_GSETTINGS_OUT="" MOCK_KDE_COLOR=BreezeDark bash -c "source '$ROOT/lib.sh'; desktop_color_scheme")"
assert_eq "desktop_color_scheme fallback -> KDE BreezeLight" "light" \
  "$(PATH="$STUB:$PATH" MOCK_PORTAL_RC=1 MOCK_GSETTINGS_OUT="" MOCK_KDE_COLOR=BreezeLight bash -c "source '$ROOT/lib.sh'; desktop_color_scheme")"

# _drm_node_info on synthetic sysfs nodes (direct driver + virtio-pci -> virtio_gpu child)
mkdir -p "$TMP/sys/card0/device" "$TMP/sys/renderD128/device/virtio0"
printf 'DRIVER=amdgpu\n' >"$TMP/sys/card0/device/uevent"
printf 'DRIVER=virtio-pci\n' >"$TMP/sys/renderD128/device/uevent"
printf 'DRIVER=virtio_gpu\n' >"$TMP/sys/renderD128/device/virtio0/uevent"
printf '10001000\n' >"$TMP/sys/renderD128/device/virtio0/features"
read -r drv feat <<<"$(_drm_node_info "$TMP/sys/card0")"
assert_eq "_drm_node_info direct driver" "amdgpu" "$drv"
assert_eq "_drm_node_info direct features empty" "" "$feat"
read -r drv feat <<<"$(_drm_node_info "$TMP/sys/renderD128")"
assert_eq "_drm_node_info virtio-pci child driver" "virtio_gpu" "$drv"
assert_eq "_drm_node_info virtio-pci child features path" "$TMP/sys/renderD128/device/virtio0/features" "$feat"

# wd_connect: missing android.serial must not print stderr noise, and stuck netd fails fast
cat >"$STUB/waydroid" <<'EOF'
#!/usr/bin/env bash
if [[ $1 == status ]]; then
  printf 'Session:\tRUNNING\nContainer:\tRUNNING\nIP address:\t192.168.240.112\n'
elif [[ $1 == prop && $2 == get && $3 == init.svc.netd ]]; then
  printf '%s\n' "${MOCK_NETD_STATE:-running}"
fi
EOF
cat >"$STUB/adb" <<'EOF'
#!/usr/bin/env bash
if [[ $1 == -s && $3 == get-state ]]; then
  printf '%s\n' "${MOCK_ADB_STATE-device}"
elif [[ $1 == connect ]]; then
  printf 'connected\n'
fi
EOF
cat >"$STUB/scrcpy" <<'EOF'
#!/usr/bin/env bash
printf 'scrcpy 5.0.1\n'
EOF
chmod +x "$STUB/waydroid" "$STUB/adb" "$STUB/scrcpy"

rm -f "$XDG_STATE_HOME/kindle-for-linux/android.serial"
wd_err_file=$TMP/wd_connect.err
wd_got=$(PATH="$STUB:$PATH" MOCK_ADB_STATE=device bash -c "source '$ROOT/lib.sh'; wd_connect 5" 2>"$wd_err_file")
assert_eq "wd_connect resolves IP without cached serial" "192.168.240.112:5555" "$wd_got"
assert_eq "wd_connect emits no stderr when android.serial is missing" "" "$(<"$wd_err_file")"
assert_eq "wd_connect caches android.serial" "192.168.240.112:5555" "$(<"$XDG_STATE_HOME/kindle-for-linux/android.serial")"

wd_t0=$SECONDS
if PATH="$STUB:$PATH" MOCK_ADB_STATE="" MOCK_NETD_STATE=stopping bash -c "source '$ROOT/lib.sh'; wd_connect 20" >/dev/null 2>&1; then
  printf '  FAIL wd_connect should fail when netd is stuck stopping\n' >&2
  FAIL=$((FAIL + 1))
else
  wd_elapsed=$((SECONDS - wd_t0))
  if ((wd_elapsed < 10)); then
    printf '  ok   wd_connect fails fast when netd is stopping (%ds)\n' "$wd_elapsed"
    PASS=$((PASS + 1))
  else
    printf '  FAIL wd_connect waited too long when netd is stopping (%ds)\n' "$wd_elapsed" >&2
    FAIL=$((FAIL + 1))
  fi
fi

# avd_ram_mb
assert_eq "avd_ram_mb respects valid override" "2048" "$(KINDLE_EMULATOR_RAM=2048 avd_ram_mb)"
ram_default=$(KINDLE_EMULATOR_RAM=512 avd_ram_mb)
if [[ $ram_default =~ ^(1536|1792|1920)$ ]]; then
  printf '  ok   avd_ram_mb ignores too-small override (%s MB)\n' "$ram_default"
  PASS=$((PASS + 1))
else
  printf '  FAIL avd_ram_mb unexpected value: %s\n' "$ram_default" >&2
  FAIL=$((FAIL + 1))
fi

# --- Python helpers (apkcert.py & getkindle.py) ------------------------------------------------

printf '==> apkcert.py & getkindle.py\n'
python3 - "$ROOT" "$TMP" <<'PYTEST'
import hashlib, io, os, struct, subprocess, sys, zipfile

root, tmp = sys.argv[1], sys.argv[2]
sys.path.insert(0, root)
import apkcert, getkindle


def lp(data: bytes) -> bytes:
    return struct.pack("<I", len(data)) + data


def make_apk(path: str, cert: bytes, files: dict[str, bytes]) -> str:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_STORED) as z:
        for name, content in files.items():
            z.writestr(name, content)
    raw = buf.getvalue()
    eocd = raw.rfind(b"PK\x05\x06")
    cd_off = struct.unpack_from("<I", raw, eocd + 16)[0]

    # Build minimal v2 APK Signing Block with one signer holding `cert`
    signed_data = lp(b"") + lp(lp(cert)) + lp(b"")
    signer = lp(signed_data) + lp(b"") + lp(b"")
    v2_val = lp(lp(signer))
    pair_body = struct.pack("<I", 0x7109871A) + v2_val
    pairs = struct.pack("<Q", len(pair_body)) + pair_body
    block_size = len(pairs) + 24
    sig_block = struct.pack("<Q", block_size) + pairs + struct.pack("<Q", block_size) + b"APK Sig Block 42"

    new_cd_off = cd_off + len(sig_block)
    out = bytearray(raw[:cd_off] + sig_block + raw[cd_off:])
    new_eocd = out.rfind(b"PK\x05\x06")
    struct.pack_into("<I", out, new_eocd + 16, new_cd_off)
    with open(path, "wb") as f:
        f.write(out)
    return hashlib.sha256(cert).hexdigest()


cert_bytes = b"fake-amazon-der-certificate-bytes"
other_sha = hashlib.sha256(b"someone-else").hexdigest()

play_apk = os.path.join(tmp, "play.apk")
sha = make_apk(play_apk, cert_bytes, {
    "AndroidManifest.xml": b"com.amazon.kindle.MainActivity",
    "lib/arm64-v8a/libdummy.so": b"ELF",
})
assert apkcert.signer_certs(play_apk) == [(sha, "v2")]
assert subprocess.run([sys.executable, f"{root}/apkcert.py", play_apk, "--expect", sha]).returncode == 0
assert subprocess.run([sys.executable, f"{root}/apkcert.py", play_apk, "--expect", other_sha]).returncode == 1
assert subprocess.run([sys.executable, f"{root}/apkcert.py", play_apk, "--kindle", sha]).returncode == 0

fire_utf8 = os.path.join(tmp, "fire8.apk")
make_apk(fire_utf8, cert_bytes, {
    "AndroidManifest.xml": b"android.permission.ACCESS_ALL_DOWNLOADS",
    "lib/arm64-v8a/libdummy.so": b"ELF",
})
assert subprocess.run([sys.executable, f"{root}/apkcert.py", fire_utf8, "--kindle", sha], stderr=subprocess.DEVNULL).returncode == 3

fire_utf16 = os.path.join(tmp, "fire16.apk")
make_apk(fire_utf16, cert_bytes, {
    "AndroidManifest.xml": "com.amazon.kindle.TabletStartActivity".encode("utf-16-le"),
    "lib/arm64-v8a/libdummy.so": b"ELF",
})
assert subprocess.run([sys.executable, f"{root}/apkcert.py", fire_utf16, "--kindle", sha], stderr=subprocess.DEVNULL).returncode == 3

no_arm64 = os.path.join(tmp, "arm32.apk")
make_apk(no_arm64, cert_bytes, {
    "AndroidManifest.xml": b"com.amazon.kindle.MainActivity",
    "lib/armeabi-v7a/libdummy.so": b"ELF",
})
assert subprocess.run([sys.executable, f"{root}/apkcert.py", no_arm64, "--kindle", sha], stderr=subprocess.DEVNULL).returncode == 4

corrupt = os.path.join(tmp, "corrupt.apk")
with open(corrupt, "wb") as f:
    f.write(b"not a zip at all")
assert subprocess.run([sys.executable, f"{root}/apkcert.py", corrupt], stderr=subprocess.DEVNULL).returncode == 2

# getkindle.py HTML parsing tests (offline)
listing_html = """
<a href="/apk/amazon-mobile-llc/amazon-kindle/amazon-kindle-14-120-0-100-release/">Fire</a>
<a href="/apk/amazon-mobile-llc/amazon-kindle/amazon-kindle-8-159-0-100-release/">Old</a>
<a href="/apk/amazon-mobile-llc/amazon-kindle/amazon-kindle-8-160-1-0-release/">New</a>
"""
release_html = """
<h1>Amazon Kindle 8.160.1.0 (1.3.42)</h1>
<a href="/apk/amazon-mobile-llc/amazon-kindle/amazon-kindle-8-160-1-0-release/kindle-bundle-android-apk-download/">dl</a>
<div>arm64-v8a BUNDLE APKM</div>
<a href="/apk/amazon-mobile-llc/amazon-kindle/amazon-kindle-8-160-1-0-release/kindle-v7a-android-apk-download/">dl</a>
<div>armeabi-v7a APK</div>
<a href="/apk/amazon-mobile-llc/amazon-kindle/amazon-kindle-8-160-1-0-release/kindle-v8a-android-apk-download/">dl</a>
<div>arm64-v8a APK</div>
"""
orig_page = getkindle.page
try:
    getkindle.page = lambda url, referer=None: listing_html if "uploads" in url else release_html
    rels = getkindle.releases()
    assert rels == [
        "/apk/amazon-mobile-llc/amazon-kindle/amazon-kindle-8-160-1-0-release/",
        "/apk/amazon-mobile-llc/amazon-kindle/amazon-kindle-8-159-0-100-release/",
    ], rels
    ver, var = getkindle.arm64_variant(rels[0])
    assert ver == "8.160.1.0", ver
    assert var.endswith("kindle-v8a-android-apk-download/"), var
finally:
    getkindle.page = orig_page

print("  ok   apkcert.py & getkindle.py assertions passed")
PYTEST
PASS=$((PASS + 1))

# --- kindle CLI & --diagnostics tests ----------------------------------------------------------

printf '==> kindle CLI & --diagnostics\n'
ver_file=$(<"$ROOT/VERSION")
assert_eq "kindle --version" "kindle-for-linux $ver_file" "$("$ROOT/kindle" --version)"
help_out=$("$ROOT/kindle" --help)
assert_contains "kindle --help mentions --diagnostics" "--diagnostics" "$help_out"
status_out=$("$ROOT/kindle" --status)
assert_contains "kindle --status before setup" "Not set up yet" "$status_out"
# Partial/interrupted setup (backend set, scrcpy/waydroid present, but command never written) must still need setup
state_set backend waydroid
assert_contains "kindle --status after interrupted setup still needs setup" "Not set up yet" "$(PATH="$STUB:$PATH" "$ROOT/kindle" --status)"
state_set command kindle-for-linux
assert_contains "kindle --status after completed setup shows Android state" "Android (waydroid):" "$(PATH="$STUB:$PATH" "$ROOT/kindle" --status)"
state_set command ""
state_set backend ""
"$ROOT/kindle" --stop
printf '  ok   kindle --stop exits 0 before setup\n'
PASS=$((PASS + 1))

"$ROOT/kindle" --density 120 >/dev/null
assert_eq "kindle --density 120 saved" "120" "$(state_get density)"
"$ROOT/kindle" --density reset >/dev/null
assert_eq "kindle --density reset clears state" "" "$(state_get density)"
if "$ROOT/kindle" --density 999 >/dev/null 2>&1; then
  printf '  FAIL kindle --density 999 should fail\n' >&2
  FAIL=$((FAIL + 1))
else
  printf '  ok   kindle --density 999 rejected\n'
  PASS=$((PASS + 1))
fi

# Seed a fake log with $HOME and ANSI codes to verify redaction + stripping
mkdir -p "$XDG_STATE_HOME/kindle-for-linux"
printf '\033[1;34m==> Starting in %s/secret-path\033[0m\n' "$HOME" >"$XDG_STATE_HOME/kindle-for-linux/install.log"
diag_out=$("$ROOT/kindle" --diagnostics)
assert_contains "diagnostics has [System]" "[System]" "$diag_out"
assert_contains "diagnostics has [Graphics & Virtualization]" "[Graphics & Virtualization]" "$diag_out"
assert_contains "diagnostics has [Desktop & Security]" "[Desktop & Security]" "$diag_out"
assert_contains "diagnostics has [Install & State]" "[Install & State]" "$diag_out"
assert_contains "diagnostics has [Recent logs]" "[Recent logs]" "$diag_out"
# shellcheck disable=SC2088
assert_contains "diagnostics redacts HOME to ~ in logs" "~/secret-path" "$diag_out"
assert_not_contains "diagnostics hides raw HOME path" "$HOME" "$diag_out"
assert_not_contains "diagnostics strips ANSI escapes" $'\033[' "$diag_out"

# install.sh --check preflight guards
if err=$(env -u WAYLAND_DISPLAY -u DISPLAY "$ROOT/install.sh" --check 2>&1); then
  printf '  FAIL install.sh --check should fail without display\n' >&2
  FAIL=$((FAIL + 1))
else
  assert_contains "install.sh --check explains missing desktop session" "desktop session" "$err"
fi

if err=$(WAYLAND_DISPLAY=wayland-1 KINDLE_BACKEND=bogus "$ROOT/install.sh" --check 2>&1); then
  printf '  FAIL install.sh --check should reject bogus backend\n' >&2
  FAIL=$((FAIL + 1))
else
  assert_contains "install.sh --check rejects bogus backend" "KINDLE_BACKEND must be waydroid or emulator" "$err"
fi

# install.sh lockfile prevents concurrent setups while --check still runs
if command -v flock >/dev/null; then
  mkdir -p "$XDG_STATE_HOME/kindle-for-linux"
  (
    exec 9>"$XDG_STATE_HOME/kindle-for-linux/install.lock"
    flock -x 9
    if err=$(WAYLAND_DISPLAY=wayland-1 "$ROOT/install.sh" 2>&1 9>&-); then
      echo "UNLOCKED"
    else
      printf '%s\n' "$err"
    fi
    if check_err=$(WAYLAND_DISPLAY=wayland-1 KINDLE_BACKEND=bogus "$ROOT/install.sh" --check 2>&1 9>&-); then
      echo "CHECK_UNEXPECTED_OK"
    else
      printf 'CHECK:%s\n' "$check_err"
    fi
  ) >"$TMP/lock_test.out"
  assert_contains "install.sh refuses concurrent setup when locked" "already running" "$(<"$TMP/lock_test.out")"
  assert_contains "install.sh --check bypasses setup lock" "CHECK:" "$(<"$TMP/lock_test.out")"
  assert_not_contains "install.sh --check not blocked by lock" "CHECK:Error: Setup is already running" "$(<"$TMP/lock_test.out")"
fi

printf '\n%d passed, %d failed.\n' "$PASS" "$FAIL"
((FAIL == 0))
