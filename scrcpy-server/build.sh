#!/usr/bin/env bash
# Rebuild scrcpy-server-secure: scrcpy's own server, from its tagged source, with one change
# (secure-display.patch): when it runs as root, the virtual screen it creates is marked secure, so
# windows Android would otherwise blank out of the picture (Amazon's sign-in page is FLAG_SECURE)
# are shown. Without root it behaves exactly like the official server.
#
#   ANDROID_HOME=~/Android/Sdk ./build.sh
#
# Needs: git, a JDK (17+), and in ANDROID_HOME: platforms/android-36 and a build-tools (31+).
# scrcpy is Apache-2.0 licensed (https://github.com/Genymobile/scrcpy); the result keeps scrcpy's
# version string, which its client checks.
set -euo pipefail

VERSION=5.0.1
COMMIT=a60891aea193d92e7e5c3942700eca63f9d19a5f # tag v5.0.1
here=$(dirname "$(readlink -f "$0")")
: "${ANDROID_HOME:?set ANDROID_HOME to an Android SDK}"
tools=${ANDROID_BUILD_TOOLS:-$(ls "$ANDROID_HOME/build-tools" | sort -V | tail -n1)}
[[ -f $ANDROID_HOME/platforms/android-36/android.jar ]] || { echo "Missing $ANDROID_HOME/platforms/android-36" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git -c advice.detachedHead=false clone -q --depth 1 --branch "v$VERSION" https://github.com/Genymobile/scrcpy.git "$work/scrcpy"
[[ $(git -C "$work/scrcpy" rev-parse HEAD) == "$COMMIT" ]] || { echo "Tag v$VERSION isn't commit $COMMIT" >&2; exit 1; }
git -C "$work/scrcpy" apply "$here/secure-display.patch"
(cd "$work/scrcpy/server" && ANDROID_PLATFORM=36 ANDROID_BUILD_TOOLS=$tools BUILD_DIR="$work/out" ./build_without_gradle.sh) >/dev/null
install -m 644 "$work/out/scrcpy-server" "$here/scrcpy-server-secure"
sha256sum "$here/scrcpy-server-secure"
