#!/bin/sh
# Rebuild sparse member images with the metadata dump at LBA 0x5000, so a
# parser that reads a real member's layout can be pointed at the files.
set -eu
cd "$(dirname "$0")"
for i in 0 1 2 3; do
    img="member$i.img"
    truncate -s $((20480 * 512)) "$img"
    dd if="member$i.meta.bin" of="$img" bs=512 seek=20480 conv=notrunc,sparse status=none
    echo "$img"
done
sha256sum -c SHA256SUMS
