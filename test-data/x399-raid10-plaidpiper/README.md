# X399 RAIDCore (AMD rcraid) RAID10 metadata fixtures

Raw metadata captured from a real, firmware-created AMD RAID10 array on an
ASUS ROG Zenith Extreme (X399, Threadripper 1950X), 4 × WD100EMAZ-00WJTA0 on
the chipset SATA controller (PCI `1022:43bd`, bound to stock `ahci` with
`echo "1022 43bd" > /sys/bus/pci/drivers/ahci/new_id`). Metadata version
0x00030000. Captured 2026-10-06, read-only, with the array mounted
read-only under Linux and Windows still booting from it.

Companion to joeytroy/amd-raid-driver issue #57 and PR #67. This is
human + AI pair work.

## Files

| file | source member | sha256 |
|---|---|---|
| `member0.meta.bin` | element 0 (`/dev/sda`, device_id `0x4be995ed1cffcf94`) | see `SHA256SUMS` |
| `member1.meta.bin` | element 1 (`/dev/sdb`, device_id `0x78638f0a48085863`) | see `SHA256SUMS` |
| `member2.meta.bin` | element 2 (`/dev/sdc`, device_id `0x746da4013a2d0903`) | see `SHA256SUMS` |
| `member3.meta.bin` | element 3 (`/dev/sdd`, device_id `0x2d03f5b2460257c7`) | see `SHA256SUMS` |

Each file is 4096 sectors (2 MiB) read from LBA 0x5000 (sector 20480) of its
member: `dd if=/dev/sdX bs=512 skip=20480 count=4096`. That region holds the
`RAIDCore` header (LBA 0x5000), the commit block (0x5001) and the journal
with the committed generation's LogicalDevice record and element array. It
ends at sector 0x6000, which is 1,044,480 sectors below UserDataOffset, so
no volume data is included.

## What the array is

- level RAID10, 4 devices, FirstCount × SecondCount = 2 × 2
- capacity 39,063,609,344 sectors (= 2 × UserDataSize 19,531,804,672)
- chunk_index 1 → 128 sectors (64 KiB)
- UserDataOffset 1,069,056 sectors on every member
- mirror pairs are **adjacent**: elements {0,1} and {2,3} are byte-identical
  1 MiB past UserDataOffset at +0 and at +1 GiB, and the two pairs differ
- equivalent dm table (one leg per pair):
  `0 39063609344 striped 2 128 <elem0> 1069056 <elem2> 1069056`

## Rebuilding parseable images

Tools that expect the header at LBA 0x5000 of a member can be pointed at a
sparse image rebuilt from each dump:

```sh
sh make-fixtures.sh            # writes member{0..3}.img (12 MiB apparent, ~136 KiB real)
```

Verified with `scripts/rcassemble.py --parse-only member0.img member1.img
member2.img member3.img` from joeytroy/amd-raid-driver at 13878003fd, which
prints the geometry above and, with `--dry-run`, the table above.

## Caveats

- 2×2 only. Nothing here says anything about 3×2 or 2×3 layouts.
- "element N" is the committed LogicalDevice element order, which on this
  board matches `rcadm`'s disk order. It may not be the physical port order
  on another board.
- Only the committed generation was checked for consistency across members;
  older journal entries are whatever the firmware left there.

## Licence

CC0 1.0 — do what you like with the data. No warranty.
