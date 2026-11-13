#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""amdraid_fix_legacy.py <диск>... [--write] [--break-for-test]

Починка Legacy-записей конфигурации AMD RAIDCore (RAIDXpert2). По умолчанию только показывает, что изменит.

Порча (MSI X870E 1.A93, RAIDCoreDxe 9.3.3-00277; dumps/2026-11-01-…, dumps/2026-11-02-msi-x870e-hdd/): при создании
в меню массива на все RAID-диски Legacy-LD диска без метаданных (XPG) получает State 0x202 (OFFLINE), элемент
DeviceID 0xFFFFFFFFFFFFFFFF и Handle 0; затем драйвер заводит ещё одну Legacy-LD (новый ID), которая ломается так же.
Прошивка не связывает Legacy-PD с LD и не отдаёт диск для загрузки. Здоровая запись (стенд, снимок 18) отличается
от сломанной только этими тремя полями.

Починка, для каждой Legacy-PD без исправной Legacy-LD: LD с ID = ID этой PD (или первая сломанная Legacy-LD той же
ёмкости) — State 0x200, элемент = DeviceID и Handle PD; остальные сломанные Legacy-LD той же ёмкости удаляются.
Запись — как amd_write_config в mdadm/super-amd.c: новый пакет в кольцо каждого диска следом за живым, затем commit
с номером конфигурации +1. Диски — все RAID-диски контроллера (на всех одинаковая живая конфигурация, иначе отказ;
диск из конфигурации, которого нет среди заданных, — отказ, если не --force: иначе он останется с прежней
конфигурацией). Диски без метки RAIDCore (сам Legacy-диск) не трогаются. Массивы на этих дисках должны быть
остановлены (mdmon пишет конфигурацию по своей копии и затёр бы починку): занятый диск не открывается для записи.

--break-for-test: обратное — сломать Legacy-LD так же, как прошивка (только для образов стенда).
"""
import argparse
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from amdraid_dump import (rc_sum, brief_gen, RAIDCORE_SIG, LBA_RAIDCORE, LBA_COMMIT, LBA_RING, LBA_RING_END,
                          RING_SECTORS, GEN_VER)  # noqa: E402

SECTOR = 512
LDT_LEGACY = 0x1BF9
PDT_LEGACY = 0x1203
PDT_DISK = 0x1200
PD_ONLINE = 0x3000
MAG_PD, MAG_LD = 0x25BC, 0x25BD
ALL_ONES = 0xFFFFFFFFFFFFFFFF
NORMAL, OFFLINE = 0x200, 0x202
MAX_PACKET = 0x100000       # как amd_check_commit в super-amd.c


def u32(b, o): return struct.unpack_from("<I", b, o)[0]
def u64(b, o): return struct.unpack_from("<Q", b, o)[0]


class Disk:
    def __init__(self, path, write):
        self.path = path
        # O_EXCL: диск, занятый md (или смонтированный), для записи не открывается — EBUSY
        flags = os.O_RDWR | os.O_EXCL if write else os.O_RDONLY
        try:
            self.fd = os.open(path, flags | getattr(os, "O_BINARY", 0))
        except OSError as e:
            raise SystemExit("%s: %s%s" % (path, e.strerror, " (массив на нём остановить)" if write else ""))
        lab = self.read(LBA_RAIDCORE, 1)
        if u64(lab, 8) != RAIDCORE_SIG or u64(lab, 0) != rc_sum(lab, 8, SECTOR - 8):
            raise SystemExit("%s: нет исправной метки RAIDCore — не RAID-диск, не трогаю" % path)
        if (u64(lab, 0x18), u64(lab, 0x20), u32(lab, 0x28)) != (LBA_COMMIT, LBA_RING, RING_SECTORS):
            raise SystemExit("%s: метка указывает commit/кольцо не там, где ожидалось — не трогаю" % path)
        self.device_id = u64(lab, 0x10)
        self.commit = bytearray(self.read(LBA_COMMIT, 1))
        c = self.commit
        if u64(c, 0) != rc_sum(c, 8, SECTOR - 8):
            raise SystemExit("%s: commit испорчен" % path)
        self.pkt_lba, self.pkt_size = u32(c, 8), u32(c, 0xC)
        self.committed, self.gen, self.pnum = u64(c, 0x10), u64(c, 0x18), u64(c, 0x30)
        if not 1 <= self.pkt_lba <= LBA_RING_END or not 0x200 <= self.pkt_size < MAX_PACKET:
            raise SystemExit("%s: commit указывает на негодный пакет" % path)
        self.packet = bytearray(self.read(self.pkt_lba, (self.pkt_size + SECTOR - 1) // SECTOR)[:self.pkt_size])
        if u64(self.packet, 0) != rc_sum(self.packet, 0xC, self.pkt_size - 0xC) or u64(self.packet, 0) != self.committed:
            raise SystemExit("%s: живой пакет не сходится с commit" % path)

    def read(self, lba, n):
        os.lseek(self.fd, lba * SECTOR, 0)
        data = os.read(self.fd, n * SECTOR)
        if len(data) != n * SECTOR:
            raise SystemExit("%s: LBA %#x+%d не читается целиком" % (self.path, lba, n))
        return data

    def write(self, lba, data):
        os.lseek(self.fd, lba * SECTOR, 0)
        if os.write(self.fd, data) != len(data):
            raise SystemExit("%s: запись не прошла" % self.path)
        os.fsync(self.fd)


def records(p):
    pds, lds = [], []
    o, end = u32(p, 0x24), u32(p, 0x24) + u32(p, 0x28)
    while o + 0x80 <= end and u32(p, o) == MAG_PD:
        pds.append(o)
        o += 0x80
    o, end = u32(p, 0x2C), u32(p, 0x2C) + u32(p, 0x30)
    while o + 0x200 <= end and u32(p, o) == MAG_LD:
        n = u32(p, o + 0x90)
        if n < 0x240 or o + n > end:
            break
        lds.append((o, n))
        o += n
    return pds, lds


def elem(p, o):
    """Смещение первого элемента LD @o (у Legacy-LD он один)."""
    return o + u32(p, o + 4)


def legacy_ld_broken(p, o):
    return u32(p, o + 8) != NORMAL or u64(p, elem(p, o)) == ALL_ONES


def remove_ld(p, o, n):
    """Вырезать LD из пакета, сдвинув всё после неё; поправить размеры и смещения."""
    # смещения PD (+0x24) не правятся: их область лежит до LD, иначе отказ
    if u32(p, 0x24) + u32(p, 0x28) > o:
        raise SystemExit("записи PD после LD @+%#x — такой пакет не правлю" % o)
    end = max(u32(p, 0x2C) + u32(p, 0x30), u32(p, 0x40) + u32(p, 0x44), u32(p, 0x48) + u32(p, 0x4C))
    q = bytearray(p[:o] + p[o + n:end])
    struct.pack_into("<I", q, 0x30, u32(q, 0x30) - n)
    for off_f, size_f in ((0x40, 0x44), (0x48, 0x4C)):
        if u32(q, size_f) and u32(q, off_f) > o:
            struct.pack_into("<I", q, off_f, u32(q, off_f) - n)
    size = (len(q) + SECTOR - 1) // SECTOR * SECTOR
    q += bytes(size - len(q))
    struct.pack_into("<I", q, 0x18, size)
    return q


def fix(p):
    p = bytearray(p)
    pds, lds = records(p)
    changes = []
    for po in pds:
        if u32(p, po + 0x24) != PDT_LEGACY:
            continue
        pid, port, cap = u64(p, po + 4), struct.unpack_from("<H", p, po + 0xC)[0], u64(p, po + 0x1C)
        leg = [(o, n) for o, n in lds if u32(p, o + 0xC) == LDT_LEGACY and u32(p, o + 0x6C) == 1 and u32(p, o + 0x70) == 1]
        good = [x for x in leg if not legacy_ld_broken(p, x[0]) and u64(p, elem(p, x[0])) == pid]
        broken = [x for x in leg if legacy_ld_broken(p, x[0]) and u64(p, elem(p, x[0])) in (pid, ALL_ONES)
                  and u64(p, x[0] + 0x50) == cap]
        if not broken:
            continue
        drop = list(broken)
        if not good:
            keep = next((x for x in broken if u64(p, x[0] + 0x2C) == pid), broken[0])
            drop.remove(keep)
            o = keep[0]
            struct.pack_into("<I", p, o + 8, NORMAL)
            struct.pack_into("<QH", p, elem(p, o), pid, port)
            changes.append("PD %016x (порт %d): Legacy-LD %012x @+%#x — State NORMAL, элемент = PD"
                           % (pid, port, u64(p, o + 0x2C), o))
        for o, n in sorted(drop, reverse=True):
            changes.append("PD %016x: лишняя сломанная Legacy-LD %012x @+%#x удалена" % (pid, u64(p, o + 0x2C), o))
            p = remove_ld(p, o, n)
        pds, lds = records(p)
    if changes:
        number_lds(p, lds)
    return p, changes


def number_lds(p, lds):
    """Handle LD (+0x34) по порядку пакета с 1, вторая копия — номер основной: так их раздаёт RAIDCoreDxe при
    чтении (FUN_0002be1c); с дырой после удалённой LD она переписывает конфигурацию при загрузке, теряя DeviceID PD
    (02.11: конфигурация 21 после этого скрипта; notes/agent-handle.md). Как mdadm (amd_number_lds)."""
    n = copy = 0
    for o, _ in lds:
        if not copy:
            n += 1
        struct.pack_into("<H", p, o + 0x34, n)
        copy = not copy and u32(p, o + 0x88) == 1


def break_legacy(p):
    p = bytearray(p)
    pds, lds = records(p)
    for o, n in lds:
        if u32(p, o + 0xC) == LDT_LEGACY and not legacy_ld_broken(p, o):
            struct.pack_into("<I", p, o + 8, OFFLINE)
            struct.pack_into("<QH", p, elem(p, o), ALL_ONES, 0)
            return p, ["Legacy-LD %012x @+%#x сломана как прошивкой" % (u64(p, o + 0x2C), o)]
    return p, []


def missing_disks(p, disks):
    """RAID-диски конфигурации (RAIDCORE_DISK, ONLINE), которых нет среди @disks: они остались бы с прежней
    конфигурацией, и прошивка/mdadm при сборке считали бы их отставшими."""
    have = {d.device_id for d in disks}
    pds, _ = records(p)
    return ["порт %d %012x" % (struct.unpack_from("<H", p, o + 0xC)[0], u64(p, o + 4)) for o in pds
            if u32(p, o + 0x24) == PDT_DISK and u32(p, o + 0x2C) == PD_ONLINE and u64(p, o + 4) not in have]


def write_all(disks, p):
    gen = disks[0].gen
    size = len(p)
    nsec = size // SECTOR
    struct.pack_into("<Q", p, 0x34, gen)  # как amd_write_config: пакет несёт прежний номер
    struct.pack_into("<Q", p, 0, rc_sum(p, 0xC, size - 0xC))
    for d in disks:
        lba = d.pkt_lba + (d.pkt_size + SECTOR - 1) // SECTOR
        if lba < LBA_RING or lba + nsec > LBA_RING_END:
            lba = LBA_RING
        struct.pack_into("<I", p, 8, d.pkt_lba)  # prev_offset, вне суммы
        d.write(lba, bytes(p))
        d.new_lba = lba
    for d in disks:
        c = d.commit
        struct.pack_into("<IIQQ", c, 8, d.new_lba, size, u64(p, 0), gen + 1)
        struct.pack_into("<Q", c, 0x30, d.pnum + 1)
        struct.pack_into("<Q", c, 0, rc_sum(c, 8, SECTOR - 8))
        d.write(LBA_COMMIT, bytes(c))
        print("  %s: пакет @%#x, конфигурация %d" % (d.path, d.new_lba, gen + 1))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("disks", nargs="+")
    ap.add_argument("--write", action="store_true", help="записать (иначе только показать)")
    ap.add_argument("--break-for-test", action="store_true", help="сломать Legacy-LD (образы стенда)")
    ap.add_argument("--force", action="store_true", help="писать, даже если заданы не все RAID-диски конфигурации")
    a = ap.parse_args()
    for x in a.disks if a.break_for_test else ():
        if not os.path.isfile(x):  # порча настоящего диска ломает загрузку с Legacy-диска (XPG)
            raise SystemExit("%s: --break-for-test — только для файлов образов, не для устройств" % x)
    disks = [Disk(x, a.write) for x in a.disks]
    d0 = disks[0]
    for d in disks[1:]:
        if (d.gen, d.committed) != (d0.gen, d0.committed):
            raise SystemExit("%s: другая живая конфигурация (%d) чем у %s (%d) — отказ" % (d.path, d.gen, d0.path, d0.gen))
    if u64(d0.packet, 0xC) != GEN_VER:
        raise SystemExit("незнакомая версия пакета")
    missing = missing_disks(d0.packet, disks)
    if missing:
        print("нет среди заданных RAID-дисков конфигурации: " + ", ".join(missing))
        if a.write and not a.force:
            raise SystemExit("задать все диски (или --force)")
    brief_gen(bytes(d0.packet), "было (конфигурация %d)" % d0.gen)
    p, changes = (break_legacy if a.break_for_test else fix)(d0.packet)
    if not changes:
        print("чинить нечего")
        return 0
    for ch in changes:
        print("*", ch)
    brief_gen(bytes(p), "станет")
    if not a.write:
        print("(только показ; --write — записать на %d диск(а))" % len(disks))
        return 0
    write_all(disks, p)
    return 0


if __name__ == "__main__":
    sys.exit(main())
