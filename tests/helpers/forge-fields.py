#!/usr/bin/env python3
"""forge-fields.py -- spoil fields of RAIDCore metadata with valid checksums: mdadm must not crash.

For each member image (label 0x5000, commit block 0x5001, ring 0x5800) it spoils one field at a time -- of the
label, the commit block, the packet header, the PD records, the LD records and their elements --, computes the
checksums again (packet, commit block, label: or reading would stop at the checksum) and runs mdadm (a build
with -fsanitize=address,undefined) with `-E`, `-E --brief`, `-E --export` on the image file.  A case is bad
if mdadm is killed by a signal, runs out of time or prints a sanitizer report.

The image is changed in place and restored after each case: work on a copy.

  python3 forge-fields.py --mdadm <asan-build>/mdadm [--log out.log] [--only ld] image...

With --container /dev/mdN (a container assembled from loop devices of these images, no volumes running) each
case goes into all images at once, and mdadm runs so as to go through load_container, getinfo_super and
container_content: `--update-subarray=0 --update=ppl` (AMD refuses, writes nothing), `-D`, `-D --export`.

With --set WHAT.FIELD=VALUE (may be repeated) it only makes these changes with valid checksums and exits: the
image stays spoiled, for assembly tests (-A, -I).  WHAT: label, commit, header, pdN, ldN, ldN.elM; FIELD: as
in the tables below; ldN.name=hex:<bytes> is the volume name.
"""
import argparse
import os
import struct
import subprocess
import sys

SECTOR = 512
LABEL_LBA, COMMIT_LBA = 0x5000, 0x5001
PD_SIZE, LD_HDR, EL_SIZE = 0x80, 0x200, 0x40

V32 = [0, 1, 2, 3, 0x40, 0x41, 0x100, 0x101, 0x200, 0x4000, 0x7fffffff, 0x80000000, 0xffffffff]
V64 = [0, 1, 0x5000, 0x6000, 1 << 31, 1 << 32, 1 << 63, (1 << 64) - 1, 0xffffffffffffff00]

LABEL = [(0x10, 8, 'device_id'), (0x18, 8, 'commit_offset'), (0x20, 8, 'ring_offset'), (0x28, 4, 'ring_size'),
         (0x2c, 4, 'version'), (0x30, 4, 'features'), (0x34, 4, 'spare_info'), (0x38, 8, 'mbr_checksum')]
COMMIT = [(0x08, 4, 'packet_offset'), (0x0c, 4, 'packet_size'), (0x18, 8, 'generation'),
          (0x28, 8, 'last_online'), (0x30, 8, 'packet_number')]
HEADER = [(0x08, 4, 'prev_offset'), (0x14, 4, 'version'), (0x18, 4, 'packet_size'), (0x1c, 8, 'modifier_sn'),
          (0x24, 4, 'pd_offset'), (0x28, 4, 'pd_size'), (0x2c, 4, 'ld_offset'), (0x30, 4, 'ld_size'),
          (0x34, 8, 'generation'), (0x40, 4, 'ctrl_offset'), (0x44, 4, 'ctrl_size'), (0x48, 4, 'sep_offset'),
          (0x4c, 4, 'sep_size')]
PD = [(0x00, 4, 'type'), (0x04, 8, 'id'), (0x0c, 2, 'handle'), (0x1c, 8, 'capacity'), (0x24, 4, 'device_type'),
      (0x2c, 4, 'device_state'), (0x30, 4, 'spare_info')]
LD = [(0x00, 4, 'type'), (0x04, 4, 'element_offset'), (0x08, 4, 'state'), (0x0c, 4, 'device_type'),
      (0x10, 4, 'transform_type'), (0x14, 4, 'last_operation'), (0x18, 4, 'transform_state'), (0x2c, 8, 'id'),
      (0x50, 8, 'capacity'), (0x58, 8, 'protect_start'), (0x68, 4, 'devices'), (0x6c, 4, 'first_count'),
      (0x70, 4, 'second_count'), (0x74, 4, 'parent_count'), (0x78, 4, 'transform_flags'),
      (0x7c, 4, 'protect_size'), (0x84, 4, 'flags'), (0x88, 4, 'transform_link'), (0x8c, 4, 'spare_count'),
      (0x90, 4, 'packet_size'), (0x94, 4, 'percent'), (0x98, 4, 'attribute'), (0xa0, 4, 'distributed_spare'),
      (0xac, 4, 'chunk_size'), (0x110, 4, 'cache_tag_size')]
EL = [(0x00, 8, 'id'), (0x08, 2, 'handle'), (0x10, 8, 'alloc_offset'), (0x18, 8, 'alloc_size'),
      (0x20, 8, 'data_offset'), (0x28, 8, 'data_size'), (0x30, 4, 'flags')]
LD_TYPES = [0x1bf5, 0x1bf6, 0x1bf7, 0x1bf8, 0x1bf9, 0x1bfa, 0x1bfb, 0x1bfc, 0x1bfd]
TRANSFORMS = [0x5354, 0x5355, 0x5356, 0x5357, 0x5358, 0x535b]
NAMES = [b'\xff' * 32, b'A' * 32, b'..', b'.', b'a/b', b'\x01\x1b[31m\n', b'-rf', b'md0', b' ', b'\xd0\xb0\xd0\xb1']


def rc_sum(buf, off, length):
    acc = 0
    for i in range(length // 8):
        w = struct.unpack_from('<Q', buf, off + 8 * i)[0]
        a, b = w & 3, acc & 3
        if a == b:
            a, b = i & 3, (i + 1) & 3
        la, lb = (w >> (16 * a)) & 0xffff, (w >> (16 * b)) & 0xffff
        w &= ~((0xffff << (16 * a)) | (0xffff << (16 * b)))
        w |= (lb << (16 * a)) | (la << (16 * b))
        acc ^= w
    return acc


def get(buf, off, size):
    return int.from_bytes(buf[off:off + size], 'little')


def put(buf, off, size, val):
    buf[off:off + size] = (val & ((1 << (8 * size)) - 1)).to_bytes(size, 'little')


class Image:
    def __init__(self, path):
        self.path = path
        with open(path, 'rb') as f:
            f.seek(LABEL_LBA * SECTOR)
            self.label0 = f.read(SECTOR)
            self.commit0 = f.read(SECTOR)
            self.plba = get(self.commit0, 0x08, 4)
            self.psize = get(self.commit0, 0x0c, 4)
            f.seek(self.plba * SECTOR)
            self.packet0 = f.read((self.psize + SECTOR - 1) // SECTOR * SECTOR)
        self.reset()

    def reset(self):
        self.label = bytearray(self.label0)
        self.commit = bytearray(self.commit0)
        self.packet = bytearray(self.packet0)

    def lds(self):
        """Offsets of the LD records in the pristine packet."""
        off, end, out = get(self.packet0, 0x2c, 4), 0, []
        end = off + get(self.packet0, 0x30, 4)
        while off + LD_HDR <= end and get(self.packet0, off, 4) == 0x25bd:
            out.append(off)
            size = get(self.packet0, off + 0x90, 4)
            if size < LD_HDR:
                break
            off += size
        return out

    def pds(self):
        off, n = get(self.packet0, 0x24, 4), get(self.packet0, 0x28, 4) // PD_SIZE
        return [off + i * PD_SIZE for i in range(n)]

    def write(self, sums=True):
        if sums:
            size = get(self.packet, 0x18, 4)
            if 0x200 <= size <= len(self.packet):
                put(self.packet, 0, 8, rc_sum(self.packet, 0x0c, size - 0x0c))
            put(self.commit, 0x10, 8, get(self.packet, 0, 8))
            put(self.commit, 0, 8, rc_sum(self.commit, 8, SECTOR - 8))
            put(self.label, 0, 8, rc_sum(self.label, 8, SECTOR - 8))
        with open(self.path, 'r+b') as f:
            f.seek(LABEL_LBA * SECTOR)
            f.write(self.label + self.commit)
            f.seek(self.plba * SECTOR)
            f.write(self.packet)

    def restore(self):
        self.reset()
        self.write(sums=False)


def cases(img, only):
    """(name, function that changes img.label / img.commit / img.packet)."""
    def field(what, buf, base, off, size, name, vals):
        orig = get(getattr(img, buf), base + off, size)
        for v in vals + [orig + 1, orig - 1]:
            v &= (1 << (8 * size)) - 1
            if v != orig:
                yield ('%s.%s=%#x' % (what, name, v),
                       lambda b=buf, o=base + off, s=size, v=v: put(getattr(img, b), o, s, v))

    def vals(size):
        return V64 if size == 8 else [v for v in V32 if v < (1 << (8 * size))]

    if only in (None, 'label'):
        for off, size, name in LABEL:
            yield from field('label', 'label', 0, off, size, name, vals(size))
    if only in (None, 'commit'):
        for off, size, name in COMMIT:
            yield from field('commit', 'commit', 0, off, size, name, vals(size))
    if only in (None, 'header'):
        for off, size, name in HEADER:
            yield from field('header', 'packet', 0, off, size, name, vals(size))
        # the packet size in the header and in the commit block together
        for v in (0x200, len(img.packet0) - SECTOR, 0x1ff, 0xffe00):
            def both(v=v):
                put(img.packet, 0x18, 4, v)
                put(img.commit, 0x0c, 4, v)
            yield ('header+commit.packet_size=%#x' % v, both)
    if only in (None, 'pd'):
        for i, base in enumerate(img.pds()):
            for off, size, name in PD:
                yield from field('pd%d' % i, 'packet', base, off, size, name, vals(size))
    if only in (None, 'ld'):
        for i, base in enumerate(img.lds()):
            what = 'ld%d' % i
            for off, size, name in LD:
                extra = LD_TYPES if name == 'device_type' else TRANSFORMS if 'transform_type' in name else []
                yield from field(what, 'packet', base, off, size, name, vals(size) + extra)
            for nm in NAMES:
                yield ('%s.name=%r' % (what, nm),
                       lambda b=base, nm=nm: img.packet.__setitem__(slice(b + 0xb0, b + 0xd0),
                                                                    nm.ljust(32, b'\0')[:32]))
            f, s = get(img.packet0, base + 0x6c, 4), get(img.packet0, base + 0x70, 4)
            # the same elements in another shape, as every device type
            for nf in range(1, f * s + 1):
                if f * s % nf:
                    continue
                for t in LD_TYPES:
                    def shape(b=base, nf=nf, ns=f * s // nf, t=t):
                        put(img.packet, b + 0x6c, 4, nf)
                        put(img.packet, b + 0x70, 4, ns)
                        put(img.packet, b + 0x0c, 4, t)
                    yield ('%s.shape=%dx%d,type=%#x' % (what, nf, f * s // nf, t), shape)
            nel = min(f * s, 0x4000)
            for e in sorted(set([0, 1, nel - 1])):
                if e < 0 or e >= nel:
                    continue
                for off, size, name in EL:
                    yield from field('%s.el%d' % (what, e), 'packet', base + LD_HDR + e * EL_SIZE, off, size,
                                     name, vals(size))


def apply_set(img, spec):
    what, val = spec.split('=', 1)
    what, name = what.rsplit('.', 1)
    parts = what.split('.')
    if parts[0] == 'label':
        buf, base, table = img.label, 0, LABEL
    elif parts[0] == 'commit':
        buf, base, table = img.commit, 0, COMMIT
    elif parts[0] == 'header':
        buf, base, table = img.packet, 0, HEADER
    elif parts[0].startswith('pd'):
        buf, base, table = img.packet, img.pds()[int(parts[0][2:])], PD
    elif parts[0].startswith('ld'):
        buf, base, table = img.packet, img.lds()[int(parts[0][2:])], LD
        if len(parts) > 1:
            base, table = base + LD_HDR + int(parts[1][2:]) * EL_SIZE, EL
        elif name == 'name':
            buf[base + 0xb0:base + 0xd0] = bytes.fromhex(val[4:]).ljust(32, b'\0')[:32]
            return
    else:
        sys.exit('--set: what is %r?' % what)
    for off, size, n in table:
        if n == name:
            put(buf, base + off, size, int(val, 0))
            return
    sys.exit('--set: no field %r' % name)


def run(mdadm, args, timeout):
    env = dict(os.environ, ASAN_OPTIONS='detect_leaks=0:abort_on_error=0', UBSAN_OPTIONS='print_stacktrace=1',
               MDADM_NO_SYSTEMCTL='1')
    try:
        p = subprocess.run([mdadm] + args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout,
                           env=env)
    except subprocess.TimeoutExpired:
        return 'TIMEOUT', b''
    out = p.stdout
    if p.returncode < 0:
        return 'SIGNAL %d' % -p.returncode, out
    if b'AddressSanitizer' in out or b'runtime error' in out:
        return 'SANITIZER', out
    return None, out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--mdadm')
    ap.add_argument('--log')
    ap.add_argument('--only', choices=['label', 'commit', 'header', 'pd', 'ld'])
    ap.add_argument('--set', action='append')
    ap.add_argument('--container')
    ap.add_argument('--timeout', type=int, default=30)
    ap.add_argument('images', nargs='+')
    a = ap.parse_args()
    log = open(a.log, 'w') if a.log else sys.stdout
    bad = total = 0
    if a.container:
        imgs = [Image(p) for p in a.images]
        rest = [dict(cases(i, a.only)) for i in imgs[1:]]
        for name, change in cases(imgs[0], a.only):
            change()
            for i, r in zip(imgs[1:], rest):
                if name in r:
                    r[name]()
            for i in imgs:
                i.write()
            total += 1
            for args in (['--update-subarray=0', '--update=ppl', a.container], ['-D', a.container],
                         ['-D', '--export', a.container]):
                verdict, out = run(a.mdadm, args, a.timeout)
                if verdict:
                    bad += 1
                    log.write('BAD %s %s: %s\n' % (name, ' '.join(args[:-1]), verdict))
                    log.write(out.decode('latin-1')[-3000:] + '\n')
                    log.flush()
                    break
            for i in imgs:
                i.restore()
        a.images = []
    for path in a.images:
        img = Image(path)
        if a.set:
            for spec in a.set:
                apply_set(img, spec)
            img.write()
            continue
        for name, change in cases(img, a.only):
            change()
            img.write()
            total += 1
            for args in (['-E', path], ['-E', '--brief', path], ['-E', '--export', path]):
                verdict, out = run(a.mdadm, args, a.timeout)
                if verdict:
                    bad += 1
                    log.write('BAD %s: %s %s: %s\n' % (os.path.basename(path), name, ' '.join(args[:-1]), verdict))
                    log.write(out.decode('latin-1')[-3000:] + '\n')
                    log.flush()
                    break
            img.restore()
    if not a.set:
        log.write('%d cases, %d bad\n' % (total, bad))
        print('%d cases, %d bad' % (total, bad))


if __name__ == '__main__':
    main()
