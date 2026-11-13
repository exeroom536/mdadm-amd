#!/bin/sh
# mkimages.sh <dir>: the six base images of the suite as sparse files, the metadata at its own LBAs, the rest holes:
#   asrock-nvme1n1.img, asrock-nvme2n1.img  ASRock X670E RAID0 members (2026-10-28-asrock-x670e-raid0)
#   x399-member0..3.img                     ASUS X399 RAID10 members (test-data/x399-raid10-plaidpiper, CC0)
# Made anew on every run: stage 1 checks that the suite leaves this metadata alone.
set -eu
F=$(cd "$(dirname "$0")" && pwd)
X=$(dirname "$(dirname "$F")")/test-data/x399-raid10-plaidpiper
O=$1
mkdir -p "$O"
put() {	# put <image> <file, .xz or raw> <LBA>
	if [ "${2%.xz}" != "$2" ]; then xz -dc "$2"; else cat "$2"; fi |
		dd of="$O/$1" bs=512 seek=$(($3)) conv=notrunc status=none
}
A=$F/2026-10-28-asrock-x670e-raid0
for n in nvme1n1 nvme2n1; do
	rm -f "$O/asrock-$n.img"
	truncate -s $((1953525168 * 512)) "$O/asrock-$n.img"
	put asrock-$n.img "$A/$n-lba0-6000.img.xz" 0
	put asrock-$n.img "$A/$n-lba100000-105000.img.xz" 0x100000
done
for i in 0 1 2 3; do
	rm -f "$O/x399-member$i.img"
	truncate -s $((19532873728 * 512)) "$O/x399-member$i.img"
	put x399-member$i.img "$X/member$i.meta.bin" 0x5000
done
