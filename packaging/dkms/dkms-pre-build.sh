#!/bin/sh
# dkms-pre-build.sh <kernel_source_dir> <kernelver>: take the drivers/md sources of the
# target kernel's base into the build directory (the current one), or refuse to build when
# none fits (DKMS then installs nothing and the kernel keeps its own md_mod).
kdir=$1
kver=$2
fail() {
	echo "md-bitmap-ext: $*; keeping the md_mod of $kver" >&2
	exit 1
}
grep -qs '^CONFIG_BLK_DEV_MD=m' "$kdir/.config" || fail "md is not built as a module"
# "bases": "<regex of kernel versions> <directory>", the version being kver up to its first "-"
base=$(awk -v v="${kver%%-*}" 'v ~ "^(" $1 ")$" { print $2; exit }' bases)
[ -n "$base" ] && [ -d "$base" ] || fail "no drivers/md sources for Linux ${kver%%-*}"
cp "$base"/* . || fail "cannot copy the sources of $base"
# Headers of some kernels (Arch, CachyOS) carry drivers/md/*.h: they must match ours.
for h in md.h md-bitmap.h md-cluster.h; do
	[ -f "$kdir/drivers/md/$h" ] || continue
	cmp -s "$kdir/drivers/md/$h" "$h" || fail "drivers/md/$h of the kernel differs from ours ($base)"
done
exit 0
