#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Разбор метаданных AMD RAIDXpert2 (RAIDCore) с диска-участника. Только чтение.

    amdraid_dump.py <образ|устройство> [--ring] [--hex] [--first-lba N] [--packet LBA] [--brief]
    amdraid_dump.py --selftest

--brief: одна строка на PD и на LD (номер массива в меню, тип, состояние, участники Handle:ID); с --ring —
так же для каждого поколения кольца (история конфигураций).

Образ — файл, где смещение 0 = LBA 0 (достаточно первых 0x6000 секторов = 12 МиБ:
    dd if=/dev/sdX of=sdX-meta.img bs=512 count=$((0x6000)) iflag=direct).
Если файл начинается не с LBA 0 (например, дамп `dd skip=20480` с LBA 0x5000), задать --first-lba;
недостающие секторы (MBR) тогда пропускаются.
Раскладка — notes/format.md; источники полей помечены там же.
"""

import argparse
import os
import struct
import sys

SECTOR = 512
LBA_MBR = 0
LBA_RAIDCORE = 0x5000
LBA_COMMIT = 0x5001
LBA_RING = 0x5800
RING_SECTORS = 0x800
LBA_RING_END = LBA_RING + RING_SECTORS          # 0x6000

RAIDCORE_SIG = 0x65726F4344494152               # b"RAIDCore"
RAIDCORE_VER = 0x30000
GEN_VER = 0xE1E10000
HOST_ID = 0x859010220000                        # константа UEFI-драйвера

MAG_PD = 0x25BC
MAG_LD = 0x25BD
MAG_BE = 0x25BE
MAG_BF = 0x25BF

# RC_LogicalDeviceTypes и прочие перечисления — из DWARF rcblob 9.3.3 (notes/format.md)
DEVTYPES = {
    0x1BF5: "RAID50 (RAID5 при First=1)",
    0x1BF6: "RAID10N (полоса x зеркала)",
    0x1BF7: "VOLUME",
    0x1BF8: "RAW_DEVICE",
    0x1BF9: "LEGACY_DEVICE",
    0x1BFA: "RAID60 (RAID6 при First=1, Q=EVENODD)",
    0x1BFB: "RAIDABLE",
    0x1BFC: "PROMISE",
    0x1BFD: "RAIDTIER",
}
LD_STATES = {0x200: "NORMAL", 0x201: "CRITICAL", 0x202: "OFFLINE", 0x203: "OUTDATE", 0x204: "LOCKED"}
PD_TYPES = {0x1200: "RAIDCORE_DISK", 0x1201: "RAIDCORE_CORE", 0x1202: "NOT_INITIALIZE", 0x1203: "LEGACY",
            0x1204: "PROMISE"}
PD_STATES = {0x3000: "ONLINE", 0x3001: "OFFLINE", 0x3002: "SMARTERR", 0x3003: "NEW", 0x3004: "LOCKED"}
TRANSFORMS = {0: "-", 0x5354: "NORMAL", 0x5355: "CREATE_REDUNDANCY", 0x5356: "CHECK_REDUNDANCY",
              0x5357: "COPY_SEGMENTS", 0x5358: "RESTORE_SEGMENTS", 0x5359: "CHECK_BITMAP_REDUNDANCY",
              0x535A: "FLUSH_BITMAP", 0x535B: "CREATE_ZERO", 0x535C: "SECURE_ERASE",
              0x535D: "QSYNC_SEGMENTS", 0x535E: "MOVE_TIER_PAGE"}


def rc_sum(buf, off=0, length=None):
    """Контрольная сумма RAIDCore (FUN_0000698c): XOR u64 с перестановкой 16-битных дорожек."""
    if length is None:
        length = len(buf) - off
    acc = 0
    for i in range(length // 8):
        w = struct.unpack_from("<Q", buf, off + 8 * i)[0]
        a = w & 3
        b = acc & 3
        if a == b:
            a = i & 3
            b = (i + 1) & 3
        if a != b:
            la = (w >> (16 * a)) & 0xFFFF
            lb = (w >> (16 * b)) & 0xFFFF
            w &= ~((0xFFFF << (16 * a)) | (0xFFFF << (16 * b))) & 0xFFFFFFFFFFFFFFFF
            w |= (lb << (16 * a)) | (la << (16 * b))
        acc ^= w
    return acc


def u16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def u64(b, o):
    return struct.unpack_from("<Q", b, o)[0]


class Disk:
    def __init__(self, path, first_lba=0):
        self.f = open(path, "rb")
        self.f.seek(0, os.SEEK_END)
        self.size = self.f.tell()
        self.first_lba = first_lba

    def has(self, lba):
        return self.first_lba <= lba < self.first_lba + self.size // SECTOR

    def read(self, lba, count=1):
        if lba < self.first_lba:
            raise EOFError("LBA 0x%x раньше начала образа (0x%x)" % (lba, self.first_lba))
        self.f.seek((lba - self.first_lba) * SECTOR)
        data = self.f.read(count * SECTOR)
        if len(data) != count * SECTOR:
            raise EOFError("LBA 0x%x+%d за концом образа" % (lba, count))
        return data


def ok(flag):
    return "ok" if flag else "НЕВЕРНО"


# --- разбор ---------------------------------------------------------------

def parse_mbr(s):
    r = {"sig55aa": u16(s, 0x1FE) == 0xAA55, "disk_sig": u32(s, 0x1B8), "sum": rc_sum(s)}
    r["parts"] = []
    for i in range(4):
        e = 0x1BE + 16 * i
        typ = s[e + 4]
        if typ:
            r["parts"].append((i, typ, u32(s, e + 8), u32(s, e + 12)))
    return r


def parse_raidcore(s):
    return {
        "sum": u64(s, 0), "sum_ok": u64(s, 0) == rc_sum(s, 8, 0x1F8),
        "sig": u64(s, 8), "device_id": u64(s, 0x10),
        "commit_lba": u64(s, 0x18), "ring_lba": u64(s, 0x20),
        "ring_sectors": u32(s, 0x28), "version": u32(s, 0x2C),
        "flags": u32(s, 0x30), "param34": u32(s, 0x34), "mbr_sum": u64(s, 0x38),
    }


def parse_commit(s):
    return {
        "sum": u64(s, 0), "sum_ok": u64(s, 0) == rc_sum(s, 8, 0x1F8),
        "gen_lba": u32(s, 8), "gen_len": u32(s, 0xC), "gen_sum": u64(s, 0x10),
        "config_seq": u64(s, 0x18), "host_a": u64(s, 0x20), "host_b": u64(s, 0x28),
        "disk_writes": u64(s, 0x30), "f38": u32(s, 0x38),
    }


def gen_header(g):
    return {
        "sum": u64(g, 0), "prev_lba": u32(g, 8), "version": u64(g, 0xC),
        "f14": u32(g, 0x14), "length": u32(g, 0x18), "host_id": u64(g, 0x1C),
        "pd_off": u32(g, 0x24), "pd_len": u32(g, 0x28),
        "ld_off": u32(g, 0x2C), "ld_len": u32(g, 0x30), "config_seq": u64(g, 0x34),
        "f3c": u32(g, 0x3C), "be_off": u32(g, 0x40), "be_len": u32(g, 0x44),
        "bf_off": u32(g, 0x48), "bf_len": u32(g, 0x4C),
    }


def gen_valid(g):
    """Проверка, как в FUN_0002b908/FUN_00024a54: сумма и версия."""
    if len(g) < 0x200:
        return False
    length = u32(g, 0x18)
    if length < 0x200 or length > len(g) or u64(g, 0xC) != GEN_VER:
        return False
    return u64(g, 0) == rc_sum(g, 0xC, length - 0xC)


def ld_size(first, second, third, fourth):
    """FUN_00006a80."""
    if not (1 <= first <= 0x100 and 1 <= second <= 0x40 and 1 <= third <= 0x10 and fourth <= 4):
        return 0
    return (first * second + 8) * 0x40 + (third + fourth) * 0x10


def parse_pd(g, o):
    return {
        "off": o, "device_id": u64(g, o + 4), "handle": u16(g, o + 0xC), "f0e": u16(g, o + 0xE),
        "prev_handle": (u16(g, o + 0x14), u16(g, o + 0x16)), "f1c": u64(g, o + 0x1C),
        "state": u32(g, o + 0x24), "f28": u32(g, o + 0x28), "f2c": u32(g, o + 0x2C),
        "f30": u32(g, o + 0x30), "flags": u32(g, o + 0x54),
    }


def parse_ld(g, o):
    """Запись LD @o; элементы и ссылки — сколько влезло в буфер (пакет может быть порчен или обрезан)."""
    first, second, third = u32(g, o + 0x6C), u32(g, o + 0x70), u32(g, o + 0x74)
    fourth = u32(g, o + 0x8C)
    r = {
        "off": o, "elem_off": u32(g, o + 4), "state": u32(g, o + 8), "devtype": u32(g, o + 0xC),
        "transform": u32(g, o + 0x10), "last_op": u32(g, o + 0x14), "transform_state": u32(g, o + 0x18),
        "ld_id": u64(g, o + 0x2C), "capacity": u64(g, o + 0x50), "protect_start": u64(g, o + 0x58),
        "ld_gen": u64(g, o + 0x60), "cache": u32(g, o + 0x80), "attribute": u32(g, o + 0x98),
        "percent": u32(g, o + 0x94),
        "members": u32(g, o + 0x68), "first": first, "second": second, "third": third,
        "fourth": fourth, "linked_next": u32(g, o + 0x88), "length": u32(g, o + 0x90),
        "chunk_sectors": u32(g, o + 0xAC), "cache_tag_size": u32(g, o + 0x110),
        "flags84": u32(g, o + 0x84),
        "name": g[o + 0xB0:o + 0xD0].split(b"\0")[0].decode("latin-1"),
        "raw_hdr": g[o:o + 0x200],
    }
    r["calc_len"] = ld_size(first, second, third, fourth)
    e = o + r["elem_off"]
    r["elems"], r["refs"] = [], []
    for i in range(first):
        for j in range(second):
            if e + 0x40 > len(g):
                return r
            r["elems"].append({
                "i": i, "j": j, "device_id": u64(g, e), "handle": u16(g, e + 8), "f0a": u16(g, e + 0xA),
                "alloc_off": u64(g, e + 0x10), "alloc_size": u64(g, e + 0x18),
                "start": u64(g, e + 0x20), "size": u64(g, e + 0x28), "flags": u32(g, e + 0x30),
            })
            e += 0x40
    for _ in range(third + fourth):
        if e + 0x10 > len(g):
            break
        r["refs"].append((u64(g, e), u16(g, e + 8), u16(g, e + 0xA)))
        e += 0x10
    return r


def ld_check(g, o):
    """FUN_000248ac."""
    t = u32(g, o + 0xC)
    if not (0x1BF5 <= t <= 0x1BF7 or 0x1BF9 <= t <= 0x1BFB):
        return False
    f, s, th = u32(g, o + 0x6C), u32(g, o + 0x70), u32(g, o + 0x74)
    if not (1 <= f <= 0x100 and 1 <= s <= 0x40 and 1 <= th <= 0x10):
        return False
    return u32(g, o + 0x68) != 0 and u64(g, o + 0x50) != 0


def parse_gen(g):
    h = gen_header(g)
    end = min(h["length"], len(g))     # порченый пакет: не читать за буфером
    pds, lds = [], []
    o = h["pd_off"]
    while o + 0x80 <= end and u32(g, o) == MAG_PD:
        pds.append(parse_pd(g, o))
        o += 0x80
    o = h["ld_off"]
    while o + 0x200 <= end and u32(g, o) == MAG_LD and ld_check(g, o):
        ld = parse_ld(g, o)
        lds.append(ld)
        if ld["length"] != ld["calc_len"] or ld["length"] == 0:
            break
        o += ld["length"]
    return h, pds, lds


def read_gen(disk, lba, length):
    n = (length + SECTOR - 1) // SECTOR
    return disk.read(lba, n)[:length]


def scan_ring(disk):
    """Все валидные поколения в кольце (порядок — по номеру конфигурации)."""
    found = []
    lba = LBA_RING
    while lba < LBA_RING_END:
        s = disk.read(lba)
        if u64(s, 0xC) == GEN_VER:
            length = u32(s, 0x18)
            if 0x200 <= length <= RING_SECTORS * SECTOR and lba + (length + 511) // 512 <= LBA_RING_END:
                g = read_gen(disk, lba, length)
                if gen_valid(g):
                    found.append((lba, gen_header(g)))
                    lba += (length + 511) // 512
                    continue
        lba += 1
    return sorted(found, key=lambda x: x[1]["config_seq"])


# --- вывод ----------------------------------------------------------------

def hexdump(b, base=0):
    for i in range(0, len(b), 16):
        row = b[i:i + 16]
        if not any(row):
            continue
        print("    %04x: %-48s %s" % (base + i, " ".join("%02x" % c for c in row),
                                      "".join(chr(c) if 32 <= c < 127 else "." for c in row)))


def show_ld(ld, ids, hexd):
    lvl = ld["first"] * ld["second"]
    print("  LD @+0x%x  id=%012x  type=0x%x (%s)  state=0x%x (%s)  DevicePrivate=%r"
          % (ld["off"], ld["ld_id"], ld["devtype"], DEVTYPES.get(ld["devtype"], "?"), ld["state"],
             LD_STATES.get(ld["state"], "?"), ld["name"]))
    print("     transform=%s last=%s state=0x%x %d%% protect_start=0x%x  gen=%d  cache=0x%x attr=0x%x"
          % (TRANSFORMS.get(ld["transform"], hex(ld["transform"])), TRANSFORMS.get(ld["last_op"], hex(ld["last_op"])),
             ld["transform_state"], ld["percent"], ld["protect_start"], ld["ld_gen"], ld["cache"], ld["attribute"]))
    print("     capacity=%d сект. (%.2f ГиБ)  members=%d  First=%d Second=%d (F*S=%d) Third=%d Fourth=%d"
          % (ld["capacity"], ld["capacity"] / 2097152, ld["members"], ld["first"], ld["second"], lvl,
             ld["third"], ld["fourth"]))
    print("     CacheTagSize=%d ChunkSize=%d  TransformLink=%d  Flags=0x%x  len=0x%x (расчёт 0x%x %s)"
          % (ld["cache_tag_size"], ld["chunk_sectors"], ld["linked_next"], ld["flags84"], ld["length"],
             ld["calc_len"], ok(ld["length"] == ld["calc_len"])))
    for e in ld["elems"]:
        who = ids.get(e["device_id"], "?")
        print("     [%d,%d] dev=%012x (%s) handle=%d data=0x%x+0x%x (%.2f ГиБ) alloc=0x%x+0x%x flags=0x%x"
              % (e["i"], e["j"], e["device_id"], who, e["handle"], e["start"], e["size"], e["size"] / 2097152,
                 e["alloc_off"], e["alloc_size"], e["flags"]))
    for r in ld["refs"]:
        print("     ref id=%012x %s handle=0x%x f=0x%x" % (r[0], "(хост)" if r[0] == HOST_ID else "", r[1], r[2]))
    if hexd:
        hexdump(ld["raw_hdr"])


SHORT_TYPES = {0x1BF5: "R5", 0x1BF6: "R10N", 0x1BF7: "VOL", 0x1BF8: "RAW", 0x1BF9: "LEGACY", 0x1BFA: "R6",
               0x1BFB: "RAIDABLE"}


def brief_gen(g, title):
    """Краткая сводка поколения: PD и LD по строке. Номер массива — порядковый среди уникальных LD."""
    h, pds, lds = parse_gen(g)
    print("%s: seq %d, PD %d, LD %d" % (title, h["config_seq"], len(pds), len(lds)))
    for p in pds:
        if p["state"] == 0x1201:
            continue
        print("  PD handle %d %012x %s %s %.1f ГиБ f=0x%x" % (p["handle"], p["device_id"], PD_TYPES.get(p["state"], hex(p["state"])),
              PD_STATES.get(p["f2c"], hex(p["f2c"])), p["f1c"] / 2097152, p["flags"]))
    seen, n = {}, 0
    for ld in lds:
        if ld["ld_id"] in seen:
            continue
        n += 1
        seen[ld["ld_id"]] = n
        el = " ".join("%d:%s" % (e["handle"], "FFFF" if e["device_id"] == 0xFFFFFFFFFFFFFFFF else "%04x" % (e["device_id"] & 0xFFFF))
                      + ("/f%x" % e["flags"] if e["flags"] else "") for e in ld["elems"])
        copies = sum(1 for x in lds if x["ld_id"] == ld["ld_id"])
        print("  Array %d %012x %-6s %-8s %dx%d CTS%d %.1f ГиБ%s  [%s]"
              % (n, ld["ld_id"], SHORT_TYPES.get(ld["devtype"], hex(ld["devtype"])), LD_STATES.get(ld["state"], hex(ld["state"])),
                 ld["first"], ld["second"], ld["cache_tag_size"], ld["capacity"] / 2097152,
                 " x%d" % copies if copies > 1 else "", el))


def commit_usable(c):
    """Commit годен для поиска живого поколения (как в dump)."""
    return c["sum_ok"] and 1 <= c["gen_lba"] < LBA_RING_END and 1 <= c["gen_len"] < 0x100000


def dump_brief(path, ring, first_lba=0, packet=None):
    """Кратко; суммы метки, commit и пакета проверяются, как в dump: негодное не выдаётся за конфигурацию
    (по --brief судят проверки tools/vm-test.sh)."""
    d = Disk(path, first_lba)
    rc = parse_raidcore(d.read(LBA_RAIDCORE))
    if rc["sig"] != RAIDCORE_SIG:
        print("%s: нет метки RAIDCore" % path)
        return 1
    if not rc["sum_ok"]:
        print("%s: метка RAIDCore НЕГОДНА (сумма)" % path)
        return 1
    c = parse_commit(d.read(LBA_COMMIT))
    live = commit_usable(c)
    if live:
        print("%s: DeviceID %012x, живое поколение @0x%x, конфигурация %d"
              % (path, rc["device_id"], c["gen_lba"], c["config_seq"]))
    else:
        print("%s: DeviceID %012x, commit НЕГОДЕН — живое поколение не определить" % (path, rc["device_id"]))
    if ring:
        for lba, h in scan_ring(d):
            mark = " (живое)" if live and lba == c["gen_lba"] and h["sum"] == c["gen_sum"] else ""
            brief_gen(read_gen(d, lba, h["length"]), "кольцо @0x%04x%s" % (lba, mark))
        return 0 if live else 1
    if packet is not None:
        g = read_gen(d, packet, u32(d.read(packet), 0x18))
        good, why = gen_valid(g), "сумма, версия или длина"
    elif live:
        packet = c["gen_lba"]
        g = read_gen(d, packet, c["gen_len"])
        good, why = gen_valid(g) and u64(g, 0) == c["gen_sum"], "сумма, версия или длина; сверка с commit"
    else:
        return 1
    if not good:
        print("пакет @0x%x: НЕГОДЕН (%s)" % (packet, why))
        return 1
    brief_gen(g, "пакет @0x%x" % packet)
    return 0


def dump(path, ring, hexd, first_lba=0, packet=None):
    d = Disk(path, first_lba)
    print("%s: %d байт (%d секторов) с LBA 0x%x" % (path, d.size, d.size // SECTOR, first_lba))

    m = None
    if d.has(LBA_MBR):
        m = parse_mbr(d.read(LBA_MBR))
        print("\nMBR: 55AA=%s подпись=%08x сумма=%016x" % (ok(m["sig55aa"]), m["disk_sig"], m["sum"]))
        for i, typ, start, size in m["parts"]:
            print("  раздел %d: тип 0x%02x начало %d размер %d%s"
                  % (i, typ, start, size, "  <- RAIDCore" if typ == 0x82 and start == 0x3F else ""))
    else:
        print("\nMBR: нет в образе")

    s = d.read(LBA_RAIDCORE)
    rc = parse_raidcore(s)
    print("\nRAIDCore @0x%x: сигнатура %s, версия 0x%x %s, сумма %s"
          % (LBA_RAIDCORE, ok(rc["sig"] == RAIDCORE_SIG), rc["version"],
             ok(rc["version"] == RAIDCORE_VER), ok(rc["sum_ok"])))
    if rc["sig"] != RAIDCORE_SIG:
        print("  диск не инициализирован в RAIDXpert2 (или формат другой)")
        if hexd:
            hexdump(s)
        return 1
    print("  DeviceID=%012x  commit=0x%x ring=0x%x/%d сект.  flags=0x%x  +0x34=0x%x"
          % (rc["device_id"], rc["commit_lba"], rc["ring_lba"], rc["ring_sectors"], rc["flags"], rc["param34"]))
    print("  сумма MBR: %016x (%s)" % (rc["mbr_sum"], "не с чем сверить" if m is None
                                         else ok(rc["mbr_sum"] in (0, m["sum"]))))
    if hexd:
        hexdump(s)

    c = parse_commit(d.read(LBA_COMMIT))
    print("\nCommit @0x%x: сумма %s" % (LBA_COMMIT, ok(c["sum_ok"])))
    print("  поколение: LBA 0x%x, %d байт, его сумма %016x" % (c["gen_lba"], c["gen_len"], c["gen_sum"]))
    print("  номер конфигурации %d, записей на этот диск %d, хост %012x/%012x %s, +0x38=%d"
          % (c["config_seq"], c["disk_writes"], c["host_a"], c["host_b"],
             "(свой)" if c["host_b"] == HOST_ID else "(ЧУЖОЙ?)", c["f38"]))

    if ring:
        print("\nКольцо 0x%x..0x%x:" % (LBA_RING, LBA_RING_END))
        for lba, h in scan_ring(d):
            live = " <- живое" if lba == c["gen_lba"] and h["sum"] == c["gen_sum"] else ""
            print("  LBA 0x%04x: seq %d, %d байт, сумма %016x, prev 0x%x, PD %d, LD %d байт%s"
                  % (lba, h["config_seq"], h["length"], h["sum"], h["prev_lba"], h["pd_len"] // 0x80,
                     h["ld_len"], live))

    if not commit_usable(c):
        print("\nблок фиксации негоден — живое поколение не определить")
        return 1
    g_lba = c["gen_lba"]
    if packet is not None:
        g_lba = packet
        c["gen_len"] = u32(d.read(packet), 0x18)
    g = read_gen(d, g_lba, c["gen_len"])
    h, pds, lds = parse_gen(g)
    print("\n%s @0x%x: версия 0x%x %s, сумма %s, совпадает с commit: %s"
          % ("Пакет" if packet is not None else "Живое поколение", g_lba, h["version"],
             ok(h["version"] == GEN_VER), ok(gen_valid(g)), ok(h["sum"] == c["gen_sum"])))
    print("  длина %d (commit %d)  seq %d  хост %012x  prev_lba 0x%x  +0x14=%d +0x3C=%d"
          % (h["length"], c["gen_len"], h["config_seq"], h["host_id"], h["prev_lba"], h["f14"], h["f3c"]))
    print("  PD +0x%x/%d  LD +0x%x/%d  25BE +0x%x/%d  25BF +0x%x/%d"
          % (h["pd_off"], h["pd_len"], h["ld_off"], h["ld_len"], h["be_off"], h["be_len"], h["bf_off"], h["bf_len"]))
    if hexd:
        hexdump(g[:0x200])

    ids = {rc["device_id"]: "этот диск", HOST_ID: "хост"}
    for p in pds:
        if p["state"] == 0x1201:
            ids.setdefault(p["device_id"], "контроллер")
        else:
            ids.setdefault(p["device_id"], "handle %d" % p["handle"])
    print("\nPD (%d):" % len(pds))
    for p in pds:
        print("  @+0x%x dev=%012x handle=%d/%d %s %s cap=0x%x (%.2f ГиБ) bus=0x%x spare=0x%x features=0x%x%s"
              % (p["off"], p["device_id"], p["handle"], p["f0e"], PD_TYPES.get(p["state"], hex(p["state"])),
                 PD_STATES.get(p["f2c"], hex(p["f2c"])), p["f1c"], p["f1c"] / 2097152,
                 p["f28"], p["f30"], p["flags"], "  <- этот диск" if p["device_id"] == rc["device_id"] else ""))
        if hexd:
            hexdump(g[p["off"]:p["off"] + 0x80], p["off"])
    print("\nLD (%d):" % len(lds))
    for ld in lds:
        show_ld(ld, ids, hexd)
    for name, off, length, step, mag in (("25BE", h["be_off"], h["be_len"], 0x88, MAG_BE),
                                         ("25BF", h["bf_off"], h["bf_len"], 0x40, MAG_BF)):
        if length:
            print("\nЗаписи %s (%d):" % (name, length // step))
            for o in range(off, min(off + length, len(g) - step + 1), step):
                print("  @+0x%x магия %s" % (o, ok(u32(g, o) == mag)))
                hexdump(g[o:o + step], o)
    return 0


# --- самопроверка на синтетическом образе ---------------------------------

def _put_sum(buf, at, off, length):
    struct.pack_into("<Q", buf, at, rc_sum(buf, off, length))


def build_image(path, disks=2, member=0, cap=0x1000000):
    """Синтетический участник RAID0 по раскладке из notes/format.md — только для самопроверки разбора."""
    ids = [0x111111000000 + k for k in range(disks)]
    ld_id = 0x222222000000
    img = bytearray(LBA_RING_END * SECTOR)

    mbr = bytearray(SECTOR)
    struct.pack_into("<I", mbr, 0x1B8, 0x12345678)
    mbr[0x1C2] = 0x82
    struct.pack_into("<II", mbr, 0x1C6, 0x3F, cap & 0xFFFFFFFF)
    struct.pack_into("<H", mbr, 0x1FE, 0xAA55)
    img[0:SECTOR] = mbr

    rc = bytearray(SECTOR)
    struct.pack_into("<QQQQII", rc, 8, RAIDCORE_SIG, ids[member], LBA_COMMIT, LBA_RING, RING_SECTORS, RAIDCORE_VER)
    struct.pack_into("<IIQ", rc, 0x30, 0x1C, 0, rc_sum(mbr))
    _put_sum(rc, 0, 8, 0x1F8)
    img[LBA_RAIDCORE * SECTOR:(LBA_RAIDCORE + 1) * SECTOR] = rc

    first, second, third, fourth = disks, 1, 1, 0
    ldl = ld_size(first, second, third, fourth)
    length = 0x200 + 0x80 * (disks + 1) + ldl + 8 * 0x40
    length = (length + 511) & ~511
    g = bytearray(length)
    seq = 7
    struct.pack_into("<IQIIQ", g, 8, 0x5800, GEN_VER, 1, length, HOST_ID)
    pd_len = 0x80 * (disks + 1)
    struct.pack_into("<IIIIQ", g, 0x24, 0x200, pd_len, 0x200 + pd_len, ldl, seq)
    o = 0x200
    struct.pack_into("<IQI", g, o, MAG_PD, HOST_ID, 0xFFFF)
    struct.pack_into("<I", g, o + 0x24, 0x1201)
    struct.pack_into("<I", g, o + 0x2C, 0x3000)
    for k in range(disks):
        o += 0x80
        struct.pack_into("<IQHH", g, o, MAG_PD, ids[k], k, 1)
        struct.pack_into("<QIII", g, o + 0x1C, cap, 0x1200, 0x2000, 0x3000)
        struct.pack_into("<I", g, o + 0x54, 0x1C)
    o += 0x80
    struct.pack_into("<IIII", g, o, MAG_LD, 0x200, 0x200, 0x1BF6)
    struct.pack_into("<Q", g, o + 0x2C, ld_id)
    data = (cap - 0x105000) & ~0x7FF
    struct.pack_into("<Q", g, o + 0x50, data * disks)
    struct.pack_into("<IIII", g, o + 0x68, disks, first, second, third)
    struct.pack_into("<II", g, o + 0x8C, fourth, ldl)
    struct.pack_into("<I", g, o + 0x110, 2)
    g[o + 0xB0:o + 0xB0 + 6] = b"Array1"
    e = o + 0x200
    for k in range(disks):
        struct.pack_into("<QHH", g, e, ids[k], k, 1)
        struct.pack_into("<QQ", g, e + 0x20, 0x105000, data)
        e += 0x40
    struct.pack_into("<QHH", g, e, HOST_ID, 0xFFFF, 0)
    _put_sum(g, 0, 0xC, length - 0xC)
    g_lba = 0x5800 + 0x10
    img[g_lba * SECTOR:g_lba * SECTOR + length] = g

    cm = bytearray(SECTOR)
    struct.pack_into("<IIQQQQQ", cm, 8, g_lba, length, u64(g, 0), seq, HOST_ID, HOST_ID, 42)
    _put_sum(cm, 0, 8, 0x1F8)
    img[LBA_COMMIT * SECTOR:(LBA_COMMIT + 1) * SECTOR] = cm
    with open(path, "wb") as f:
        f.write(img)
    return ids, ld_id


def selftest():
    import tempfile
    # сумма: свойства, видные из алгоритма
    assert rc_sum(bytes(64)) == 0
    one = struct.pack("<Q", 0x0004000300020001)     # i=0, acc=0, w&3=1 -> меняются дорожки 1 и 0
    assert rc_sum(one) == 0x0004000300010002, hex(rc_sum(one))
    zero_lane = struct.pack("<Q", 0x0004000300020000)  # w&3=0 == acc&3 -> дорожки 0 и 1
    assert rc_sum(zero_lane) == 0x0004000300000002, hex(rc_sum(zero_lane))
    assert rc_sum(b"\1" * 15) == rc_sum(b"\1" * 8)     # хвост короче 8 байт не считается

    fd, path = tempfile.mkstemp(suffix=".img")
    os.close(fd)
    try:
        ids, ld_id = build_image(path)
        d = Disk(path)
        rc = parse_raidcore(d.read(LBA_RAIDCORE))
        assert rc["sum_ok"] and rc["device_id"] == ids[0]
        c = parse_commit(d.read(LBA_COMMIT))
        assert c["sum_ok"]
        g = read_gen(d, c["gen_lba"], c["gen_len"])
        assert gen_valid(g) and u64(g, 0) == c["gen_sum"]
        _, pds, lds = parse_gen(g)
        assert [p["device_id"] for p in pds] == [HOST_ID] + ids
        assert len(lds) == 1 and lds[0]["ld_id"] == ld_id and lds[0]["length"] == lds[0]["calc_len"]
        assert [e["device_id"] for e in lds[0]["elems"]] == ids
        assert [x[0] for x in scan_ring(d)] == [c["gen_lba"]]
        # порча одного байта в поле +0x08 не ломает сумму поколения, в +0x0C — ломает
        g2 = bytearray(g)
        g2[8] ^= 1
        assert gen_valid(g2)
        g2[0xC] ^= 1
        assert not gen_valid(g2)
        d.f.close()
        if "-v" in sys.argv:
            dump(path, True, False)
    finally:
        os.unlink(path)
    print("selftest: ok")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("path", nargs="?")
    ap.add_argument("--ring", action="store_true", help="показать все поколения в кольце")
    ap.add_argument("--hex", action="store_true", help="hex служебных секторов и записей")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--packet", type=lambda x: int(x, 0), help="разобрать пакет по этому LBA вместо живого")
    ap.add_argument("--first-lba", type=lambda x: int(x, 0), default=0, help="LBA первого сектора файла")
    ap.add_argument("--brief", action="store_true", help="кратко: строка на PD/LD (с --ring — для каждого поколения)")
    ap.add_argument("-v", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if not a.path:
        ap.error("нужен образ или устройство")
    try:
        if a.brief:
            return dump_brief(a.path, a.ring, a.first_lba, a.packet)
        return dump(a.path, a.ring, a.hex, a.first_lba, a.packet)
    except (OSError, EOFError, struct.error) as e:
        # обрезанный образ, недоступное устройство, смещения порченого пакета за буфером
        print("%s: %s" % (a.path, e), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
