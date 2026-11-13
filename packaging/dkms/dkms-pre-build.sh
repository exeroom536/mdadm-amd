#!/bin/sh
# dkms-pre-build.sh <kernel_source_dir> <kernelver>: refuse to build when the shipped
# drivers/md sources may not fit the target kernel (DKMS then installs nothing and the
# kernel keeps its own md_mod).
kdir=$1
kver=$2
fail() {
	echo "md-bitmap-ext: $*; keeping the md_mod of $kver" >&2
	exit 1
}
grep -qs '^CONFIG_BLK_DEV_MD=m' "$kdir/.config" || fail "md is not built as a module"
# Headers of some kernels (Arch, CachyOS) carry drivers/md/*.h: they must match ours.
for h in md.h md-bitmap.h md-cluster.h; do
	[ -f "$kdir/drivers/md/$h" ] || continue
	cmp -s "$kdir/drivers/md/$h" "$h" || fail "drivers/md/$h of the kernel differs from ours"
done
exit 0
