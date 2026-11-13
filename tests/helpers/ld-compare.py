#!/usr/bin/env python3
"""ld-compare.py <image A>[@LBA] <image B>[@LBA] [--type 0x1bfb] -- byte-for-byte comparison of an LD record.

Takes the live packet of each image (by the commit block; @LBA: the ring packet at that LBA; parsed with
tools/amdraid_dump.py of the repository), the first LD of the given type in it (RAIDABLE 0x1BFB by default),
and compares the records whole (the 0x200 header, the elements, the references): prints every field that
differs by name (struct amd_ld / amd_element in super-amd.c) with the values of A and B.
Exit code: 0 equal, 1 differences, 2 no such LD.  Read-only.  Stage 38 of the suite compares a RAIDABLE
created by mdadm with one the BIOS menu made (fixture 2026-11-06-qemu-spares-raidable, snapshot 04).
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
import amdraid_dump as ad  # noqa: E402

# (offset, length, name): RC_LogicalDevice, as struct amd_ld
LD_FIELDS = [
    (0x00, 4, "Type"), (0x04, 4, "ElementOffset"), (0x08, 4, "State"), (0x0C, 4, "DeviceType"),
    (0x10, 4, "TransformType"), (0x14, 4, "LastOperation"), (0x18, 4, "TransformState"),
    (0x1C, 16, "ClusterId"), (0x2C, 8, "Id"), (0x34, 2, "Id.Handle"), (0x36, 2, "Id.RoutingPath"),
    (0x38, 4, "Id.Reserved"), (0x3C, 16, "InvalidateId"), (0x4C, 4, "PrevHandle"), (0x50, 8, "Capacity"),
    (0x58, 8, "TransformProtectStart"), (0x60, 8, "Generation"), (0x68, 4, "Devices"),
    (0x6C, 4, "FirstCount"), (0x70, 4, "SecondCount"), (0x74, 4, "ParentCount"),
    (0x78, 4, "TransformFlags"), (0x7C, 4, "TransformProtectSize"), (0x80, 4, "Cache"), (0x84, 4, "Flags"),
    (0x88, 4, "TransformLink"), (0x8C, 4, "SpareCount"), (0x90, 4, "PacketSize"),
    (0x94, 4, "TransformPercent"), (0x98, 4, "Attribute"), (0x9C, 4, "LastRepairCount"),
    (0xA0, 4, "DistributedSpare"), (0xA4, 4, "PreferReadElement"), (0xA8, 4, "TaskPriority"),
    (0xAC, 4, "ChunkSize"), (0xB0, 32, "Name (DevicePrivate)"), (0x110, 4, "CacheTagSize"),
]
EL_FIELDS = [
    (0x00, 8, "Id"), (0x08, 2, "Id.Handle"), (0x0A, 2, "Id.RoutingPath"), (0x0C, 4, "Id.Reserved"),
    (0x10, 8, "AllocatedSpace.Offset"), (0x18, 8, "AllocatedSpace.Size"), (0x20, 8, "UserDataSpace.Offset"),
    (0x28, 8, "UserDataSpace.Size"), (0x30, 4, "Flags"), (0x34, 12, "Reserved"),
]


def live_ld(arg, devtype):
    path, _, at = arg.partition("@")
    d = ad.Disk(path)
    if at:
        lba = int(at, 0)
        g = ad.read_gen(d, lba, ad.gen_header(d.read(lba))["length"])
    else:
        c = ad.parse_commit(d.read(ad.LBA_COMMIT))
        g = ad.read_gen(d, c["gen_lba"], c["gen_len"])
    h, pds, lds = ad.parse_gen(g)
    for ld in lds:
        if ld["devtype"] == devtype:
            return g[ld["off"]:ld["off"] + ld["length"]], ld
    return None, None


def field(table, rel):
    for off, size, name in table:
        if off <= rel < off + size:
            return off, size, name
    return rel, 1, "+0x%x" % rel


def name_of(o, el_end):
    if o < 0x200:
        off, size, name = field(LD_FIELDS, o)
        return off, size, "LD." + name
    if o < el_end:
        i, rel = divmod(o - 0x200, 0x40)
        off, size, name = field(EL_FIELDS, rel)
        return 0x200 + i * 0x40 + off, size, "Element[%d].%s" % (i, name)
    i, rel = divmod(o - el_end, 0x10)
    return el_end + i * 0x10 + rel, 1, "Ref[%d]+0x%x" % (i, rel)


def show(b):
    if len(b) in (2, 4, 8):
        return "0x%x" % int.from_bytes(b, "little")
    t = b.split(b"\0")[0]
    return repr(t.decode("latin-1")) if b and all(32 <= x < 127 for x in t) else b.hex()


def main():
    args = sys.argv[1:]
    devtype = 0x1BFB
    if "--type" in args:
        i = args.index("--type")
        devtype = int(args[i + 1], 0)
        del args[i:i + 2]
    if len(args) != 2:
        print(__doc__)
        return 2
    a, la = live_ld(args[0], devtype)
    b, lb = live_ld(args[1], devtype)
    if a is None or b is None:
        print("no LD of type 0x%x in %s" % (devtype, args[0] if a is None else args[1]))
        return 2
    if len(a) != len(b):
        print("record length: A 0x%x, B 0x%x" % (len(a), len(b)))
    el_end = 0x200 + la["first"] * la["second"] * 0x40
    seen, diff = set(), 0
    for o in range(min(len(a), len(b))):
        if a[o] == b[o]:
            continue
        off, size, name = name_of(o, el_end)
        if off in seen:
            continue
        seen.add(off)
        diff += 1
        print("%-34s +0x%03x  A %s  B %s" % (name, off, show(a[off:off + size]), show(b[off:off + size])))
    print("differences: %d (record length 0x%x)" % (diff, len(a)))
    return 1 if diff or len(a) != len(b) else 0


if __name__ == "__main__":
    sys.exit(main())
