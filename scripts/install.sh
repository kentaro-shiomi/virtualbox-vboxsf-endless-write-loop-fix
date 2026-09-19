#!/bin/sh
# Build and install a patched vboxsf module via DKMS.
#
#   sudo ./scripts/install.sh [kernel-tag]
#
# kernel-tag is an upstream Linux tag such as v7.0 (default: derived from
# the running kernel).  The sources of fs/vboxsf are downloaded from
# github.com/torvalds/linux at that tag, the patch in patches/ is applied
# and the result is registered with DKMS so that it is rebuilt on kernel
# updates.
set -eu

VERSION=1.0
PKG=vboxsf-fix
SRC=/usr/src/$PKG-$VERSION
HERE=$(cd "$(dirname "$0")/.." && pwd)
KVER=$(uname -r)
FILES="Makefile dir.c file.c shfl_hostintf.h super.c utils.c vboxsf_wrappers.c vfsmod.h"

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

if [ $# -ge 1 ]; then
  TAG=$1
else
  base=${KVER%%-*}
  case $base in
    *.*.0) TAG=v${base%.0} ;;
    *)     TAG=v$base ;;
  esac
fi
echo "kernel: $KVER   upstream tag: $TAG"

for c in dkms make gcc curl patch; do
  command -v "$c" >/dev/null || { echo "missing command: $c" >&2; exit 1; }
done
[ -d "/lib/modules/$KVER/build" ] || { echo "kernel headers for $KVER are not installed" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for f in $FILES; do
  curl -fsSLo "$tmp/$f" "https://raw.githubusercontent.com/torvalds/linux/$TAG/fs/vboxsf/$f" ||
    { echo "failed to download fs/vboxsf/$f at $TAG" >&2; exit 1; }
done

patch -d "$tmp" -p3 --no-backup-if-mismatch -i "$HERE/patches/0001-vboxsf-fix-endless-write-loop-on-short-copy.patch"

if dkms status "$PKG/$VERSION" | grep -q .; then
  dkms remove "$PKG/$VERSION" --all || true
fi
rm -rf "$SRC"
mkdir -p "$SRC"
cp "$tmp"/* "$SRC"/
sed "s/@VERSION@/$VERSION/" "$HERE/dkms/dkms.conf" > "$SRC/dkms.conf"
cp "$HERE/patches/"*.patch "$SRC"/

dkms add "$PKG/$VERSION"
dkms build "$PKG/$VERSION"
dkms install "$PKG/$VERSION"

install -m 755 "$HERE/tools/vboxsf-fix-check" /usr/local/sbin/vboxsf-fix-check
install -m 644 "$HERE/tools/vboxsf-fix-check.service" /etc/systemd/system/vboxsf-fix-check.service
systemctl daemon-reload

echo
dkms status "$PKG/$VERSION"
echo "module:     $(modinfo -n vboxsf)"
echo "srcversion: $(modinfo -F srcversion vboxsf)"
echo
echo "Reboot (or unmount your shared folders, rmmod vboxsf and mount again)"
echo "to start using the patched driver."
