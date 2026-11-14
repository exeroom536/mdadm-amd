#!/bin/bash
# imsm-bitmap-probe.sh: can this kernel run an md write-intent bitmap for external metadata?
# Creates Intel IMSM (no Intel hardware needed) on two loop files in /tmp, a RAID1 volume with
# --bitmap=internal, and shows what md reports.  On kernels 6.18 and later without the fix in
# kernel/ the volume stays inactive and md/bitmap/ is missing; with it (or on 6.17 and older):
# consistency_policy "bitmap".  The same kernel path serves AMD volumes.  Touches no real disk:
# only the container it made and the volumes in it are written to and stopped.
# Run as root; cleans up after itself.
set -u
D=/tmp/imsm-bm-probe
C=/dev/md/imsmbmc
V=/dev/md/imsmbmv
# loop devices have no serials; mdmon must see these too, so mdadm starts it
# itself rather than through mdmon@.service (which has a clean environment)
export IMSM_NO_PLATFORM=1 IMSM_DEVNAME_AS_SERIAL=1 MDADM_NO_SYSTEMCTL=1

# md devices of the volumes of our container ("external:/mdN/K" metadata, mdN the container),
# and nothing else that runs on this machine
volumes() {
	local c f
	c=$(readlink -f "$C" 2>/dev/null) || return 0
	c=${c##*/}
	for f in /sys/block/md*/md/metadata_version; do
		grep -qs "^external:/$c/" "$f" && basename "${f%/md/metadata_version}"
	done
}

cleanup() {
	# volumes first, then the container
	for m in $(volumes); do
		mdadm --stop "/dev/$m"
	done
	[ -e "$C" ] && mdadm --stop "$C" 2>/dev/null
	for l in ${LOOPS:-}; do
		mdadm --zero-superblock "$l" 2>/dev/null
		losetup -d "$l" 2>/dev/null
	done
	rm -rf "$D"
}

for m in "$C" "$V"; do
	[ -e "$m" ] && { echo "$m exists: not ours, stopping here"; exit 1; }
done
trap cleanup EXIT

uname -r
mdadm --version
mkdir -p "$D"
LOOPS=
for n in a b; do
	truncate -s 300M "$D/$n.img"
	LOOPS="$LOOPS $(losetup -f --show "$D/$n.img")"
done
echo "loops:$LOOPS"
for l in $LOOPS; do
	case "$l" in /dev/loop*) ;; *) echo "not a loop: $l"; exit 1;; esac
done

# shellcheck disable=SC2086	# LOOPS is a list
mdadm -C "$C" -e imsm -n 2 $LOOPS -R
mdadm -C -v "$V" -l 1 -n 2 --size=100M --bitmap=internal "$C" -R
echo "create rc=$?"
md=$(volumes | head -1)
echo "md=$md"
[ -n "$md" ] || { echo "no volume in $C"; exit 1; }
cat /proc/mdstat
echo "array_state: $(cat "/sys/block/$md/md/array_state" 2>&1)"
echo "consistency_policy: $(cat "/sys/block/$md/md/consistency_policy" 2>&1)"
ls "/sys/block/$md/md/bitmap/" 2>&1
for f in metadata location chunksize; do
	echo "bitmap/$f: $(cat "/sys/block/$md/md/bitmap/$f" 2>&1)"
done
# shellcheck disable=SC2086
set -- $LOOPS
mdadm -E "$1" 2>&1 | grep -i -E 'RWH|policy|bitmap'
pgrep -a mdmon
# a write makes the volume active: mdmon must mark it dirty, the kernel set bits
dd if=/dev/urandom of="/dev/$md" bs=1M count=4 oflag=direct status=none
sleep 1
echo "after write: array_state $(cat "/sys/block/$md/md/array_state")"
