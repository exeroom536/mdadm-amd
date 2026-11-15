#!/bin/bash
# install.sh [--remove]: the optional md-bitmap-ext module (md_mod with the md bitmap fix, see
# "The md bitmap" in docs/install.md) through DKMS, on distributions without the Arch package.
# It lays out /usr/src/md-bitmap-ext-<version> as the md-bitmap-ext-dkms package does, with the
# bases, checksums and functions of packaging/arch/PKGBUILD, runs "dkms install" for the running
# kernel and rebuilds its initramfs (md_mod of a root volume is loaded from there).  Any version
# installed before is removed first.  --remove only removes, and rebuilds the initramfs.
# Needs bash, curl, patch, dkms and the headers of the running kernel.  Run as root.
set -e
name=md-bitmap-ext
here=$(cd "$(dirname "$0")" && pwd)
kver=$(uname -r)

# update-initramfs first: on Ubuntu with dracut it also updates the copy the boot loader reads
initramfs() {
	if command -v update-initramfs >/dev/null; then
		update-initramfs -u -k "$kver"
	elif command -v dracut >/dev/null; then
		dracut -f --kver "$kver"
	fi
}

# every version DKMS knows, with its sources (no package owns them here)
remove() {
	local d v
	for d in /var/lib/dkms/$name/[0-9]*/; do
		[ -d "$d" ] || continue
		v=${d%/}
		v=${v##*/}
		dkms remove "$name/$v" --all
		rm -rf "/usr/src/$name-$v"
	done
}

[ "$(id -u)" = 0 ] || { echo "$0: run as root" >&2; exit 1; }
if [ "$1" = --remove ]; then
	remove
	initramfs
	exit 0
fi

# (Ubuntu) dkms-pre-build.sh would refuse too, but only after the downloads and a dkms add
if [ "$(modinfo -n md_mod 2>/dev/null)" = "(builtin)" ]; then
	echo "$0: md is built into $kver: no module can take its place" >&2
	exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
cp "$here"/{Kbuild,dkms.conf,dkms-pre-build.sh,dkms-post-install.sh,md-bitmap-ext.patch} .
# _mdbases, source, sha256sums, _md_tree() and package_md-bitmap-ext-dkms()
. "$here/../arch/PKGBUILD"
# the drivers/md files of the bases: the downloads among the sources, checked as makepkg does
for i in "${!source[@]}"; do
	case ${source[i]} in
	*::https://*) ;;
	*) continue ;;
	esac
	f=${source[i]%%::*}
	curl -fsSL --retry 3 -o "$f" "${source[i]#*::}"
	echo "${sha256sums[i]}  $f" | sha256sum -c --quiet
done
_md_tree

remove
pkgdir=
package_md-bitmap-ext-dkms
src=$(echo /usr/src/$name-*)
ver=${src#/usr/src/$name-}
dkms add "$name/$ver"
if ! dkms install "$name/$ver"; then
	echo "$0: DKMS built nothing for $kver (see above); its md_mod stays" >&2
	exit 1
fi
initramfs
echo "md_mod: $(modinfo -n md_mod)"
