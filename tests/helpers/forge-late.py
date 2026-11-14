#!/usr/bin/env python3
"""forge-late.py <mode> [arguments] <disk>... -- forge an AMD configuration for stage 34 of the suite.  The live
packet on each disk is changed; the checksums of the packet and the commit block are computed again.  The arrays
must be stopped.  Needs tools/amdraid_dump.py of the repository.

Modes:
  gap <volume> <N>       LATE-B1: the data of the volume's elements starts N sectors into the element
                         (UserDataSpace.SectorOffset = AllocatedSpace.SectorOffset + N; AMD has 0x5000 or 0x800).
  taken <volume> <other> LATE-A2: the element of a disk the two volumes share is offline in <volume> (Flags 0x30,
                         the volume CRITICAL), and its extent starts inside the data of <other> on that disk
                         (UserDataSpace + 0x1000): so the AMD driver leaves a member found offline whose extent it
                         gave to another volume (rcblob BuildFreeList).  Prints the LBA of the md bitmap area of
                         that element (AllocatedSpace + 0x100).
  huge <volume>          LATE-A4: the capacity of the volume and the sizes of its elements are 2^44 sectors (the md
                         bitmap bits do not fit in the area even at 1 GiB a bit).
  legacy2                LATE-B3: a second Legacy disk of the same capacity (a copy of the first one's PD record, a
                         new DeviceID, port 6); the second broken Legacy LD (the firmware's, with a random ID) gets
                         its ID: each Legacy disk has a broken record of its own.  For the fixture
                         2026-11-02-msi-x870e-hdd.
Volumes are given by name (LD.name).
"""
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
import amdraid_dump as A  # noqa: E402

DEV_LEGACY = 0x1203
LDT_LEGACY = 0x1BF9
ID2 = 0x7D730AF340A8BEEF


def resum(g):
    struct.pack_into("<Q", g, 0, A.rc_sum(g, 0xC, A.u32(g, 0x18) - 0xC))


def ld_named(lds, name):
    for ld in lds:
        if ld["name"] == name:
            return ld
    sys.exit("no volume %s" % name)


def el_off(ld, n):
    return ld["off"] + ld["elem_off"] + 0x40 * n


def gap(g, name, n):
    h, pds, lds = A.parse_gen(g)
    ld = ld_named(lds, name)
    for i, e in enumerate(ld["elems"]):
        struct.pack_into("<Q", g, el_off(ld, i) + 0x20, e["alloc_off"] + n)
    return "data of %s 0x%x sectors into the elements, md bitmap area at LBA %d" % (name, n, ld["elems"][0]["alloc_off"] + 0x100)


def taken(g, name, other):
    h, pds, lds = A.parse_gen(g)
    a, b = ld_named(lds, name), ld_named(lds, other)
    for i, e in enumerate(a["elems"]):
        for o in b["elems"]:
            if o["device_id"] == e["device_id"]:
                at = o["start"] + 0x1000
                struct.pack_into("<I", g, el_off(a, i) + 0x30, 0x30)
                struct.pack_into("<Q", g, el_off(a, i) + 0x10, at)
                struct.pack_into("<Q", g, el_off(a, i) + 0x20, at + e["start"] - e["alloc_off"])
                struct.pack_into("<I", g, a["off"] + 8, 0x201)
                return "disk %016x offline in %s, md bitmap area at LBA %d" % (e["device_id"], name, at + 0x100)
    sys.exit("the volumes share no disk")


def huge(g, name):
    h, pds, lds = A.parse_gen(g)
    ld = ld_named(lds, name)
    cap = 1 << 44
    struct.pack_into("<Q", g, ld["off"] + 0x50, cap)
    for i, e in enumerate(ld["elems"]):
        struct.pack_into("<Q", g, el_off(ld, i) + 0x28, cap)
        struct.pack_into("<Q", g, el_off(ld, i) + 0x18, cap + e["start"] - e["alloc_off"])
    return "capacity of %s: 2^44 sectors" % name


def legacy2(g):
    h, pds, lds = A.parse_gen(g)
    leg = [p for p in pds if A.u32(g, p["off"] + 0x24) == DEV_LEGACY]
    if len(leg) != 1:
        sys.exit("needs exactly one Legacy PD")
    extra = [ld for ld in lds if ld["devtype"] == LDT_LEGACY and ld["ld_id"] != leg[0]["device_id"]]
    if len(extra) != 1:
        sys.exit("needs exactly one extra Legacy LD")
    struct.pack_into("<Q", g, extra[0]["off"] + 0x2C, ID2)
    pd = bytearray(g[leg[0]["off"]:leg[0]["off"] + 0x80])
    struct.pack_into("<Q", pd, 4, ID2)
    struct.pack_into("<H", pd, 0xC, 6)
    at = h["pd_off"] + h["pd_len"]
    length = h["length"]
    g[at:at] = pd
    del g[length + 0x80:]
    struct.pack_into("<I", g, 0x28, h["pd_len"] + 0x80)
    for o in (0x2C, 0x40, 0x48):		# the sections after the PDs: LD, 25BE, 25BF
        if A.u32(g, o) >= at:
            struct.pack_into("<I", g, o, A.u32(g, o) + 0x80)
    struct.pack_into("<I", g, 0x18, length + 0x80)
    return "second Legacy PD %016x, its record the former extra one %012x" % (ID2, extra[0]["ld_id"])


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    mode, args = args[0], args[1:]
    npar = {"gap": 2, "taken": 2, "huge": 1, "legacy2": 0}.get(mode)
    if npar is None or len(args) <= npar:
        sys.exit(__doc__)
    par, disks = args[:npar], args[npar:]
    for path in disks:
        with open(path, "r+b") as f:
            f.seek(A.LBA_COMMIT * A.SECTOR)
            c = bytearray(f.read(A.SECTOR))
            cm = A.parse_commit(c)
            f.seek(cm["gen_lba"] * A.SECTOR)
            n = (cm["gen_len"] + A.SECTOR - 1) // A.SECTOR
            g = bytearray(f.read((n + 1) * A.SECTOR))
            if not A.gen_valid(g):
                sys.exit("%s: the live packet does not parse" % path)
            if mode == "gap":
                what = gap(g, par[0], int(par[1], 0))
            elif mode == "taken":
                what = taken(g, par[0], par[1])
            elif mode == "huge":
                what = huge(g, par[0])
            else:
                what = legacy2(g)
            resum(g)
            length = A.u32(g, 0x18)
            g = g[:(length + A.SECTOR - 1) // A.SECTOR * A.SECTOR]
            struct.pack_into("<I", c, 0xC, length)
            struct.pack_into("<Q", c, 0x10, struct.unpack_from("<Q", g, 0)[0])
            struct.pack_into("<Q", c, 0, A.rc_sum(c, 8, 0x1F8))
            f.seek(cm["gen_lba"] * A.SECTOR)
            f.write(g)
            f.seek(A.LBA_COMMIT * A.SECTOR)
            f.write(c)
            f.flush()
            os.fsync(f.fileno())
        print("%s: %s" % (path, what))


if __name__ == "__main__":
    main()
