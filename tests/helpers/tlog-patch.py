#!/usr/bin/env python3
"""tlog-patch.py <image> <LBA> [field=value ...] [--zero] [--write] -- change fields of an AMD transform log sector.

The transform log (RC_TransformLogStruct_LE) is the sector at the start of an element (AllocatedSpace) where AMD
keeps the progress of a transform.  Fields: Type ProtectStart IOStart IOSize Flags ProtectSize CurStripe DynStripe
LogStripe Status.  The checksum (+0x00, over +0x08...+0x67 with the Reserved halves of the two DeviceIDs as 0) is
computed again.  --zero clears the sector (no log, as the AMD driver leaves it at the end).  Without --write it only
prints the fields before and after.  Stage 54 of the suite makes a log of a migration in its first stripes so.
Needs tools/amdraid_dump.py of the repository.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
import amdraid_dump as A  # noqa: E402

FIELDS = {"Type": (0x18, "<I"), "ProtectStart": (0x1c, "<Q"), "IOStart": (0x24, "<Q"), "IOSize": (0x2c, "<I"),
          "Flags": (0x30, "<I"), "ProtectSize": (0x34, "<I"), "CurStripe": (0x38, "<I"), "DynStripe": (0x3c, "<I"),
          "LogStripe": (0x40, "<I"), "Status": (0x44, "<I")}


def tlog_sum(t):
    c = bytearray(t[:0x68])
    c[0x14:0x18] = bytes(4)  # DeviceID.Reserved
    c[0x54:0x58] = bytes(4)  # CopyToDeviceID.Reserved
    return A.rc_sum(bytes(c), 8, 0x60)


def show(t):
    return " ".join("%s=%#x" % (k, struct.unpack_from(f, t, o)[0]) for k, (o, f) in FIELDS.items())


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) < 2:
        sys.exit(__doc__)
    img, lba = args[0], int(args[1], 0)
    with open(img, "rb") as f:
        f.seek(lba * 512)
        t = bytearray(f.read(512))
    ok = struct.unpack_from("<Q", t, 0)[0] == tlog_sum(t)
    print("before: %s, checksum %s" % (show(t), "valid" if ok else "INVALID"))
    if "--zero" in sys.argv:
        t = bytearray(512)
    else:
        for kv in args[2:]:
            k, v = kv.split("=")
            o, f = FIELDS[k]
            struct.pack_into(f, t, o, int(v, 0))
        struct.pack_into("<Q", t, 0, tlog_sum(t))
    print("after:  %s" % show(t))
    if "--write" in sys.argv:
        with open(img, "r+b") as f:
            f.seek(lba * 512)
            f.write(t)
        print("written")


if __name__ == "__main__":
    main()
