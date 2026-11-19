#!/usr/bin/env python3
"""commit-serial.py <image>... -- the controller serial of the board's firmware and Windows driver in commit blocks.

Writes LastModifierSN and LastOnlineSN of the commit block (LBA 0x5001) of each disk as 0x859010220000, the serial
the firmware and the AMD Windows driver use, instead of 0x102285900000 of the AMD Linux driver rcraid, and computes
the commit block's checksum again; the packets are not touched.  A set rcraid wrote in an emulator then looks as if
the firmware or Windows had written it, as on real hardware, so this mdadm does not take it for a set of another
controller.  Stage 56 of the suite uses it on the fixture 2026-11-15-rcraid-away.  Needs tools/amdraid_dump.py of
the repository.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
import amdraid_dump as A  # noqa: E402

AMD_SN = 0x859010220000


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for img in sys.argv[1:]:
        dk = A.Disk(img)
        rc = A.parse_raidcore(dk.read(A.LBA_RAIDCORE))
        c = bytearray(dk.read(rc["commit_lba"]))
        old = struct.unpack_from("<QQ", c, 0x20)
        struct.pack_into("<QQ", c, 0x20, AMD_SN, AMD_SN)
        struct.pack_into("<Q", c, 0, A.rc_sum(bytes(c), 8, 0x1F8))
        with open(img, "r+b") as f:
            f.seek(rc["commit_lba"] * 512)
            f.write(c)
        print("%s: commit block at %#x: modifier %x, online %x -> %x" % (os.path.basename(img), rc["commit_lba"],
              old[0], old[1], AMD_SN))


if __name__ == "__main__":
    main()
