#!/usr/bin/env python3
"""commit-rollback.py <image> <packet LBA> -- a disk that missed the last configuration writes.

Points the commit block (LBA 0x5001) of the disk at an older packet of its ring, at the given LBA, with the fields
as AMD writes them (packet LBA, length, checksum; config_seq = the packet's sequence number + 1), and computes the
commit block's checksum again.  The packets are not touched.  Stage 56 of the suite rolls disks of the fixture
2026-11-15-rcraid-away back so.  Needs tools/amdraid_dump.py of the repository.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
import amdraid_dump as A  # noqa: E402


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    img, lba = sys.argv[1], int(sys.argv[2], 0)
    dk = A.Disk(img)
    rc = A.parse_raidcore(dk.read(A.LBA_RAIDCORE))
    c = bytearray(dk.read(rc["commit_lba"]))
    g = dk.read(lba, 64)
    h = A.gen_header(g)
    g = g[:h["length"]]
    if not A.gen_valid(g):
        sys.exit("%s: no valid packet at LBA %#x" % (img, lba))
    old = A.parse_commit(bytes(c))
    struct.pack_into("<IIQQ", c, 8, lba, h["length"], h["sum"], h["config_seq"] + 1)
    struct.pack_into("<Q", c, 0, A.rc_sum(bytes(c), 8, 0x1F8))
    with open(img, "r+b") as f:
        f.seek(rc["commit_lba"] * 512)
        f.write(c)
    print("%s: commit block at %#x: packet %#x seq %d -> %#x seq %d" % (os.path.basename(img), rc["commit_lba"],
          old["gen_lba"], old["config_seq"] - 1, lba, h["config_seq"]))


if __name__ == "__main__":
    main()
