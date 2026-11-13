#!/usr/bin/env python3
"""forge-rebuild.py [--overlap] <disk>... -- forge an AMD configuration for check REB-A3 (stage 35 of the suite):
so the AMD driver leaves a member found offline whose extent it takes for free (rcblob BuildFreeList) and may
have given to another volume.

The configuration on the disks: two volumes (LD 0 and LD 1) sharing disk X.  The live packet on each disk:
  - the element of X in LD 0: Flags 0x30 (offline), State of LD 0 CRITICAL;
  - with --overlap: the element of X in LD 1 moves to the extent of X's element in LD 0 (AllocatedSpace,
    UserDataSpace).
The checksums of the packet and the commit block are computed again.  The arrays must be stopped.  Needs
tools/amdraid_dump.py of the repository.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
import amdraid_dump as A  # noqa: E402


def elem_at(ld, dev):
    """the offset (from the start of the LD) of the element of disk dev"""
    for n, e in enumerate(ld["elems"]):
        if e["device_id"] == dev:
            return ld["elem_off"] + 0x40 * n
    return None


def forge(g, overlap):
    h, pds, lds = A.parse_gen(g)
    if len(lds) < 2:
        sys.exit("needs two volumes")
    a, b = lds[0], lds[1]
    common = [e["device_id"] for e in a["elems"] if elem_at(b, e["device_id"]) is not None]
    if len(common) != 1:
        sys.exit("the two volumes must share exactly one disk")
    ea = a["off"] + elem_at(a, common[0])
    eb = b["off"] + elem_at(b, common[0])
    struct.pack_into("<I", g, ea + 0x30, 0x30)
    struct.pack_into("<I", g, a["off"] + 8, 0x201)
    if overlap:
        g[eb + 0x10:eb + 0x18] = g[ea + 0x10:ea + 0x18]		# AllocatedSpace.SectorOffset
        g[eb + 0x20:eb + 0x28] = g[ea + 0x20:ea + 0x28]		# UserDataSpace.SectorOffset
    struct.pack_into("<Q", g, 0, A.rc_sum(g, 0xC, h["length"] - 0xC))
    return common[0]


def main():
    args = sys.argv[1:]
    overlap = "--overlap" in args
    for path in [p for p in args if p != "--overlap"]:
        with open(path, "r+b") as f:
            f.seek(A.LBA_COMMIT * A.SECTOR)
            c = bytearray(f.read(A.SECTOR))
            cm = A.parse_commit(c)
            f.seek(cm["gen_lba"] * A.SECTOR)
            n = (cm["gen_len"] + A.SECTOR - 1) // A.SECTOR
            g = bytearray(f.read(n * A.SECTOR))
            if not A.gen_valid(g):
                sys.exit("%s: the live packet does not parse" % path)
            dev = forge(g, overlap)
            struct.pack_into("<Q", c, 0x10, struct.unpack_from("<Q", g, 0)[0])
            struct.pack_into("<Q", c, 0, A.rc_sum(c, 8, 0x1F8))
            f.seek(cm["gen_lba"] * A.SECTOR)
            f.write(g)
            f.seek(A.LBA_COMMIT * A.SECTOR)
            f.write(c)
            f.flush()
            os.fsync(f.fileno())
        print("%s: disk %016x offline in LD 0%s" % (path, dev, ", its extent in LD 1 too" if overlap else ""))


if __name__ == "__main__":
    main()
