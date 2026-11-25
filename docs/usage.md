# Using AMD RAID arrays with mdadm

mdadm handles AMD RAIDXpert2 the way it handles Intel IMSM: the disks form a **container** (all RAID disks of a
system share one AMD configuration), and the **volumes** (the arrays the BIOS menu lists) are member arrays of that
container. `mdmon` runs for the container and keeps the AMD metadata up to date.

- [Assembling](#assembling)
- [Creating](#creating)
- [Spares](#spares)
- [RAIDABLE → RAID1](#raidable--raid1)
- [Growing a volume, RAID0 → RAID10](#growing-a-volume-raid0--raid10)
- [More disks, RAID1 → RAID5, stripe size](#more-disks-raid1--raid5-stripe-size)
- [Changing and deleting volumes](#changing-and-deleting-volumes)
- [When a disk fails or goes missing](#when-a-disk-fails-or-goes-missing)
- [Working with the BIOS and Windows](#working-with-the-bios-and-windows)
- [Tools](#tools)

All commands below need root. The examples use a container `/dev/md/amd0` on `/dev/sda`…`/dev/sdd`.

## Assembling

udev assembles the volumes when the disks appear, at boot as well. By hand:

```sh
mdadm --assemble --scan
cat /proc/mdstat
mdadm --detail /dev/md/data
mdadm --examine /dev/sda                 # the AMD configuration as this disk has it
mdadm --examine --scan                   # ARRAY lines for /etc/mdadm.conf
```

- A disk joins the container whose configuration lists it and whose disks its own configuration lists. A disk
  that missed changes (it was absent) still joins, and `mdmon` brings its copy of the configuration up to date; a
  disk taken into another set does not join the old one.
- A RAID0, Volume or RAIDABLE starts with a disk that missed the latest configuration update if that disk's own
  configuration has the volume in the same place: such a volume cannot have been written without it. A RAID1,
  RAID10 or RAID5 treats such a disk as out of date: it starts without it only with `--run`, and the disk is then
  rebuilt.
- A volume in the middle of an AMD migration that adds disks (RAID0 or RAID5 onto more disks, RAID1 → RAID5) is
  not assembled; once the AMD driver has finished it, the volume is assembled as any other. A migration that grows
  a volume in place or makes a RAID0 a RAID10 is assembled and finished by `mdmon`.

## Creating

`sudo mdadm --detail-platform -e amd` shows what the firmware takes for RAID (the EFI variable `AMD_RAID`): the
controllers, the disks behind them, the levels, chunk sizes and limits below.

First the container: the disks are initialized as the BIOS menu does it (both ends zeroed, an MBR with AMD's one
partition, the AMD label and configuration). Then volumes in it.

```sh
mdadm --create /dev/md/amd0 --metadata=amd --raid-devices=4 /dev/sd[abcd] --run

mdadm --create /dev/md/mirror --level=1  --raid-devices=2 --size=100G /dev/md/amd0
mdadm --create /dev/md/fast   --level=0  --raid-devices=4 --size=50G  /dev/md/amd0
mdadm --create /dev/md/r10    --level=10 --raid-devices=4 --size=50G  /dev/md/amd0
mdadm --create /dev/md/r5     --level=5  --raid-devices=3 --size=50G  /dev/md/amd0
mdadm --create /dev/md/span   --level=linear --raid-devices=2 --size=50G /dev/md/amd0
```

- `--size` is the size taken on each disk, in whole MiB; without it the volume takes all the free space. With
  only the container named, the volume goes on the container's disks; to choose them, name them instead of the
  container: `mdadm --create /dev/md/mirror --metadata=amd --level=1 --raid-devices=2 /dev/sdc /dev/sdd`.
- A RAID1, RAID10 or RAID5 is then initialized by md (`resync` in `/proc/mdstat`); `mdmon` records the progress, and
  an interrupted initialization goes on after a reboot. `--assume-clean` skips it.
- `--bitmap=internal` adds the md write-intent bitmap ([install.md](install.md#the-md-bitmap)).
- Each volume needs all its disks: `missing` is refused, as for IMSM.
- The BIOS menu creates at most 8 disks per volume and 12 arrays in a system (a Legacy disk counts as one); so does
  mdadm, unless `--force` is given. The BIOS and the Windows driver accept larger volumes, but their own tools
  cannot create them.
- A new volume also takes the container's global spares as members, as IMSM builds volumes of its spares; they are
  spares no more.

## Spares

```sh
mdadm /dev/md/amd0 --add /dev/sde               # a new disk: initialized, becomes a global spare
mdadm /dev/md/mirror --add-spare /dev/sde       # a disk of the container: a dedicated spare of this volume
mdadm /dev/md/mirror --remove /dev/sde          # takes the dedicated role back
mdadm /dev/md/amd0 --remove /dev/sde            # takes all spare roles from a disk that is present
```

When a member of a redundant volume fails, `mdmon` rebuilds onto the volume's dedicated spares first, then onto a
global spare, as the AMD driver does. `--add` refuses a disk with an ext2/3/4, ReiserFS, XFS or btrfs file system, a LUKS volume, an LVM physical volume or
another AMD set on it;
`--force` wipes it.

## RAIDABLE → RAID1

A RAIDABLE volume is one whole disk kept for a future mirror; it runs as an md RAID1 of one member.

```sh
mdadm --create /dev/md/single --level=1 --raid-devices=1 --force /dev/md/amd0   # on a disk no volume uses
mdadm /dev/md/amd0 --add /dev/sde                                               # the future second disk
mdadm --grow /dev/md/single --raid-devices=2                                    # migrate to RAID1
```

The migration is recorded as the AMD driver records it, so the BIOS and Windows see it in progress, and an
interrupted one goes on after a reboot. A migration that the AMD driver started is finished by `mdmon`.

## Growing a volume, RAID0 → RAID10

```sh
mdadm --grow /dev/md/mirror --size=max          # RAID1, RAID10, RAID5: larger, in place (or --size=<size per disk>)
mdadm /dev/md/amd0 --add /dev/sde /dev/sdf       # a RAID0 of 2 needs 2 spares
mdadm --grow /dev/md/stripe --level=10           # RAID0 of n disks -> RAID10 of 2n, each disk mirrored onto a spare
```

As with the AMD migrations, a volume grows only into the free space right behind its members on each disk: a
volume after it on the same disks leaves no room. The data stay where they are; md resyncs the new part, or copies
each disk onto its new mirror. The migration is recorded as the AMD driver records it; stopped midway, it goes on
from where it was at the next assembly. Not supported: growing a RAID0 or a Volume, other layouts and numbers
of disks for RAID10, a volume smaller than one region of AMD's log of the migration (9 MiB for a RAID1, 16 MiB
for a RAID10, 9 MiB a data disk for a RAID5). Growing a RAID1, a RAID10 or a RAID5 in place was tried on real
hardware: the Windows driver reads the volume and finishes such a growth stopped midway (with mdadm before 1.6.1
it left a strip of the new part out of sync, see the changelog), and the BIOS menu shows each grown volume with
its new size. RAID0 → RAID10 was tried in emulation with AMD's Linux driver, which takes and finishes these
migrations as its own.

## More disks, RAID1 → RAID5, stripe size

```sh
mdadm /dev/md/amd0 --add /dev/sde                # a spare: a new disk (a global spare) ...
mdadm /dev/md/r5 --add-spare /dev/sdd            # ... or a disk of the container with room (a dedicated spare)
mdadm --grow /dev/md/r5 --raid-devices=4         # RAID5 of 3 -> 4 disks
mdadm --grow /dev/md/stripe --raid-devices=3     # RAID0 of 2 -> 3 disks (a global spare only)
mdadm --grow /dev/md/mirror --level=5 --layout=right-asymmetric --raid-devices=3   # RAID1 of two -> RAID5 of 3
mdadm --grow /dev/md/r5 --chunk=128              # RAID5 or RAID10: stripe size 64, 128 or 256 KiB
```

These are AMD's own migrations (`rcadm -T`), recorded as the AMD driver records them; the stripe size change is
recorded the same way, although AMD's tools do not offer it. md reshapes the volume and moves the data of each
member 9 MiB down, as AMD does; the new disks come from the spares, as with AMD: a volume's dedicated spares
first, then the global ones. A dedicated spare must be no smaller than the disks of the volume (AMD drops a
smaller one), and a RAID0 has none: it takes a global spare, a disk in no volume. A spare keeps its role after a
migration used part of it, as with AMD. For a RAID5, `--chunk` goes with `--raid-devices` too.

- Stopped midway (a reboot, `mdadm --stop`), the migration goes on from where it was at the next assembly; one
  stopped before md moved anything goes on from the start. The BIOS menu shows such a volume as "Transform", and
  the Windows driver finishes it.
- A RAID10 stripe size change stopped midway: let mdadm finish it, or let Windows finish it before using the
  volume there. Reading the volume while the Windows driver (9.3.3 or 9.5) carries the change on may stall its
  I/O (seen in a VM with slowed-down disks). The data stay safe; mdadm goes on from where Windows stopped.
- One migration at a time in a container. Volumes the AMD driver left midway are finished one after another; a
  volume that waits for its turn is assembled read-only.
- After one of these migrations the data stay 1 MiB into their extents: more disks for the volume again go in
  place, the first stripes through the log of their data AMD keeps in front of each member, and a stripe size
  change moves them back up 9 MiB, from the end of the volume, as AMD would. More disks and another stripe size
  at once are refused then: one, then the other. Growing in place still works.
- Not supported: fewer disks, more disks for a RAID10, the stripe size of a RAID0.
- A RAID0 onto more disks on kernels 6.6 to 6.17 and the stable 5.15.y, 6.1.y, 6.6.y and 6.12.y: a bug of md
  there (fixed in 6.18) lets I/O that comes in the moment md turns the volume from raid4 back into raid0 read
  data of other places and write to the wrong places, silently, with any metadata. From 1.6.4 on, `mdadm --grow`
  keeps the I/O to one chunk at that moment, and the volume may stay in use; with 1.6.3 and earlier keep it
  idle until the growth ends. Other tools that change the level of a RAID0 through sysfs are not covered.

Tried on real hardware with the BIOS menu and Windows: RAID5 of 3 → 4 disks, RAID0 of 2 → 3 disks, RAID1 of two
→ RAID5 of 3, the stripe size of a RAID5 (64 → 128 KiB) and of a RAID10 (64 → 256 KiB). RAID5 of 3 → 4, RAID0 of
2 → 3 and the RAID5 stripe size stopped midway by mdadm were finished by the Windows driver. In a VM, the
Windows drivers 9.3.3.329 and 9.5 took all five, finished or stopped midway, the same way. A second migration of
moved data (RAID5 of 3 → 4) and the stripe size change of such a volume (RAID10 128 → 64 KiB), stopped midway by
mdadm (1.6), were finished by the Windows driver too; AMD's Linux driver takes both, both ways, in emulation.

## Changing and deleting volumes

```sh
mdadm --update-subarray=0 --update=name -N newname /dev/md/amd0
mdadm --update-subarray=0 --update=write-back /dev/md/amd0      # also no-write-back, read-cache, no-read-cache
mdadm --stop /dev/md/mirror
mdadm --kill-subarray=0 /dev/md/amd0                            # delete a stopped volume
```

The subarray number is the `Subarray` line of `mdadm --examine`. The cache options set the policy the AMD drivers
use under Windows; md itself does not cache. Names are at most 31 characters, and two volumes cannot share one.

## When a disk fails or goes missing

- **A member fails while running:** md drops it, `mdmon` records it as the AMD driver does and rebuilds onto a
  spare if there is one. Replace the disk with `--add`, as above. It is failed in that volume alone: the other
  volumes on the disk keep it, and the disk stays online until it fails in all of them.
- **Being told:** `mdmonitor.service` (`mdadm --monitor --scan`) needs `MAILADDR` or `PROGRAM` in
  `/etc/mdadm.conf`; without either it exits ("No mail address or alert command") and systemd lists it as
  failed, as with any mdadm.
- **A disk is pulled:** the udev rule takes it out of the container (`mdadm -If`), its volumes fail it first. With a
  udev older than systemd 257, run `mdadm -If sdc` yourself after pulling the disk.
- **A disk comes back:** a member that was missing is rebuilt into its own place on that disk. A disk that failed
  on I/O errors waits for you, as with the AMD driver: `--remove` it, then `--add` it.
- **Booting with a disk missing:** the volumes start degraded after about 30 seconds (mdadm's last-resort timer, as
  for native md): the volume with the root file system still in the initramfs, the others in the running system, 30
  to 90 seconds after boot. When the disk is back, they are rebuilt onto it.
- **All disks of a volume gone and back:** a volume the AMD driver recorded offline because all its disks went
  away together is taken back without a rebuild when they come back with the same configuration, also one at a
  time, as the AMD driver does. If they bring different configurations it is not: the AMD driver would take it
  with mirrors that differ. Tried in emulation with AMD's Linux driver.
- **A reboot during a rebuild or an initialization:** it goes on from the point recorded in the metadata. A rebuild
  target that comes only after its volume has started is copied from the start.

## Working with the BIOS and Windows

- Volumes made or changed by mdadm are shown as Normal by the BIOS menu and taken by the Windows driver, and the
  other way round. A rebuild, an initialization or a migration started by one goes on under the other.
- The AMD write-intent bitmap is kept as the AMD driver keeps it. After Linux crashed while writing, md resyncs
  the parts it was writing at the next assembly, even when Windows ran in between: the Windows driver does not
  always do it (9.5.0 clears the bitmap without checking the volume, 9.3.3 checks mirrors but leaves RAID5 parity as
  it was; both seen in a VM), so `mdmon` keeps its own copy of the bitmap's state next to it, which the AMD drivers
  do not write. `mdadm --examine` says "mdmon bitmap : dirty from bit N, the AMD bitmap cleared since" when the
  AMD driver cleared the bitmap of a volume Linux left dirty. The copy is on the disk of the volume's first
  member: with that disk missing, or after a crash under an mdadm before 1.2, check the volume from Linux and
  repair what differs: `echo repair | sudo tee /sys/block/mdX/md/sync_action`.
- TRIM reaches a RAID1 or RAID10 only while every member reads zeroes after it, as the AMD driver decides, and never
  a RAID5. `mdmon` decides again on each new member. Kernels from 6.17 (and 6.12.42 on) do not take TRIM back once
  it was turned off (a fix: [kernel/blk-discard/](../kernel/blk-discard/)); the volume then keeps it
  off until it is started again.
- Disks are taken only behind controllers the firmware uses for RAID (EFI variable `AMD_RAID`); `--force` takes
  others, for example to read the disks on another machine. Disks last written by AMD's Linux driver (it writes a
  wrong controller serial number) become this machine's on the first write, as with the BIOS and Windows.
- The BIOS menu can break the Legacy (non-RAID) record of a pass-through disk, which then stops booting
  ([firmware-bugs.md](firmware-bugs.md)). mdadm and `mdmon` repair it whenever they write the configuration;
  `tools/amdraid_fix_legacy.py` repairs it on its own.

## Tools

| Tool | What it does |
|---|---|
| `tools/amdraid_dump.py <disk> --brief [--ring]` | reads a disk's AMD metadata, one line per array; `--ring` — the history of configurations |
| `tools/amdraid_fix_legacy.py <disks>` | shows what it would change in broken Legacy records; `--write` changes it |
| `tools/imsm-bitmap-probe.sh` | checks whether the kernel can run an md bitmap for external metadata |
