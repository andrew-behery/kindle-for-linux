#!/usr/bin/env bash
# Build release artifacts into dist/:
#   - kindle-for-linux-<ver>.tar.gz        (universal release tarball with install.sh)
#   - kindle-for-linux_<ver>_all.deb       (Debian / Ubuntu / Linux Mint)
#   - kindle-for-linux-<ver>-1.noarch.rpm  (Fedora / openSUSE / RHEL-family)
#   - kindle-for-linux-<ver>-1-any.pkg.tar.zst (Arch, when makepkg is installed)
#   - PKGBUILD + .SRCINFO                  (for AUR, with matching tarball SHA-256)
#   - SHA256SUMS
set -euo pipefail

root=$(dirname "$(dirname "$(readlink -f "$0")")")
cd "$root"

VERSION=$(<VERSION)
export VERSION
dist=$root/dist
rm -rf "$dist"
mkdir -p "$dist"

# 1. Universal release tarball (contains everything needed for ./install.sh and AUR source)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
pkg_root="$stage/kindle-for-linux-$VERSION"
mkdir -p "$pkg_root/scrcpy-server" "$pkg_root/packaging"
cp -a VERSION LICENSE README.md kindle lib.sh install.sh uninstall.sh verify.sh \
  apkcert.py apkicon.py getkindle.py "$pkg_root/"
cp -a scrcpy-server/adb-system scrcpy-server/build.sh scrcpy-server/kfl-scrcpy-server \
  scrcpy-server/kfl-scrcpy.rc scrcpy-server/scrcpy-server-secure scrcpy-server/secure-display.patch \
  "$pkg_root/scrcpy-server/"
cp -a packaging/kindle-for-linux.desktop packaging/kindle-for-linux.svg "$pkg_root/packaging/"

tarball="$dist/kindle-for-linux-$VERSION.tar.gz"
tar -C "$stage" -czf "$tarball" "kindle-for-linux-$VERSION"
tar_sha=$(sha256sum "$tarball" | cut -d' ' -f1)
echo "Built: $(basename "$tarball") ($tar_sha)"

# 2. .deb and .rpm via nfpm (system nfpm or mise)
run_nfpm() {
  if command -v nfpm >/dev/null && nfpm --version >/dev/null 2>&1; then
    nfpm "$@"
  elif command -v mise >/dev/null; then
    mise x nfpm@latest -- nfpm "$@"
  else
    echo "Error: nfpm not found (install nfpm or mise)." >&2
    return 1
  fi
}

run_nfpm package --config packaging/nfpm.yaml --packager deb --target "$dist/"
run_nfpm package --config packaging/nfpm.yaml --packager rpm --target "$dist/"

# 3. AUR PKGBUILD (stamped with exact version and tarball checksum) + Arch package if makepkg exists
aur_dir="$stage/aur"
mkdir -p "$aur_dir"
sed -e "s/^pkgver=.*/pkgver=$VERSION/" \
    -e "s/^sha256sums=.*/sha256sums=('$tar_sha')/" \
    packaging/aur/PKGBUILD >"$aur_dir/PKGBUILD"
cp "$aur_dir/PKGBUILD" "$dist/PKGBUILD"

if command -v makepkg >/dev/null; then
  ln -s "$tarball" "$aur_dir/kindle-for-linux-$VERSION.tar.gz"
  (cd "$aur_dir" && makepkg --printsrcinfo >"$dist/.SRCINFO")
  (cd "$aur_dir" && PKGDEST="$dist" makepkg -f --nodeps --skippgpcheck >/dev/null)
fi

# 4. Checksums
(cd "$dist" && sha256sum kindle-for-linux* >SHA256SUMS)
echo
ls -lh "$dist"
