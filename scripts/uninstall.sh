#!/bin/sh
# Remove the patched vboxsf module and restore the in-tree one.
set -eu
VERSION=1.0
PKG=vboxsf-fix
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

dkms remove "$PKG/$VERSION" --all || true
rm -rf "/usr/src/$PKG-$VERSION"
rm -f /usr/local/sbin/vboxsf-fix-check /etc/systemd/system/vboxsf-fix-check.service
systemctl daemon-reload || true
depmod -a
echo "module: $(modinfo -n vboxsf)"
echo "Remove any mount unit drop-in that requires vboxsf-fix-check.service, then reboot."
