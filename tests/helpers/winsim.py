#!/usr/bin/env python3
"""winsim.py -- write into member images what the AMD RAID driver for Windows (rcraid.sys 9.3.3.218) writes
about a disk it ran without.  For the tests of mdadm: images only.

  winsim.py drop   <disk ID> <image>...   the driver ran without the disk: its PD is gone from the packet,
                                          its elements offline with handles 0x8fff, 0x8ffe..., flags 0x30,
                                          the LD CRITICAL (seen with the Windows driver in a VM)
  winsim.py forget <disk ID> <image>...   the disk came back to the driver: PD in place, the ID of its
                                          elements zeroed, handles 0x9000, 0x8fff..., flags 0x30

ID: 16 hex digits (or a tail of them, if unique).  The live packet of each image is changed in place (same
length, the tail of the sections padded with zeroes), its checksum, then the commit block: generation +1,
packet checksum, record count +1.  Images not given (the absent disk itself) keep the old generation: stale.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
import amdraid_dump as a  # noqa: E402


def live(path):
    d = a.Disk(path)
    c = a.parse_commit(d.read(a.LBA_COMMIT))
    g = bytearray(a.read_gen(d, c["gen_lba"], c["gen_len"]))
    return c, g


def find_id(paths, tail):
    ids = set()
    for p in paths:
        _, g = live(p)
        _, pds, lds = a.parse_gen(bytes(g))
        ids |= {x["device_id"] for x in pds}
        for ld in lds:
            ids |= {e["device_id"] for e in ld["elems"]}
    t = int(tail, 16)
    m = [i for i in ids if i == t or ("%016x" % i).endswith(tail.lower())]
    if len(m) != 1:
        raise SystemExit("ID %s: %d found" % (tail, len(m)))
    return m[0]


def edit(g, op, dev):
    h, pds, lds = a.parse_gen(bytes(g))
    length = h["length"]
    n = 0
    for ld in lds:
        e = ld["off"] + ld["elem_off"]
        hit = False
        for el in ld["elems"]:
            if el["device_id"] == dev:
                hit = True
                if op == "forget":
                    struct.pack_into("<Q", g, e, 0)
                struct.pack_into("<H", g, e + 8, (0x9000 if op == "forget" else 0x8fff) - n)
                struct.pack_into("<I", g, e + 0x30, el["flags"] | 0x30)
                n += 1
            e += 0x40
        if hit:
            struct.pack_into("<I", g, ld["off"] + 8, 0x201)
    if op == "drop":
        pd = [x for x in pds if x["device_id"] == dev]
        if pd:
            o = pd[0]["off"]
            g[o:length] = g[o + 0x80:length] + bytes(0x80)
            struct.pack_into("<I", g, 0x28, h["pd_len"] - 0x80)
            for off_at, len_at in ((0x2C, 0x30), (0x40, 0x44), (0x48, 0x4C)):
                if a.u32(g, off_at) > o:
                    struct.pack_into("<I", g, off_at, a.u32(g, off_at) - 0x80)
    struct.pack_into("<Q", g, 0x34, h["config_seq"] + 1)
    struct.pack_into("<Q", g, 0, a.rc_sum(g, 0xC, length - 0xC))
    return n


def main():
    if len(sys.argv) < 4 or sys.argv[1] not in ("drop", "forget"):
        raise SystemExit(__doc__)
    op, paths = sys.argv[1], sys.argv[3:]
    dev = find_id(paths, sys.argv[2])
    for p in paths:
        c, g = live(p)
        n = edit(g, op, dev)
        with open(p, "r+b") as f:
            f.seek(c["gen_lba"] * a.SECTOR)
            f.write(bytes(g))
            f.seek(a.LBA_COMMIT * a.SECTOR)
            s = bytearray(f.read(a.SECTOR))
            struct.pack_into("<Q", s, 0x10, a.u64(g, 0))
            struct.pack_into("<Q", s, 0x18, c["config_seq"] + 1)
            struct.pack_into("<Q", s, 0x30, c["disk_writes"] + 1)
            struct.pack_into("<Q", s, 0, a.rc_sum(s, 8, 0x1F8))
            f.seek(a.LBA_COMMIT * a.SECTOR)
            f.write(bytes(s))
        print("%s: %s %016x, %d elements, generation %d" % (p, op, dev, n, c["config_seq"] + 1))


if __name__ == "__main__":
    main()
