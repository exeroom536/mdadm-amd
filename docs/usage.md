# Using AMD RAID arrays with mdadm

mdadm handles AMD RAIDXpert2 the way it handles Intel IMSM: the disks form a **container** (all RAID disks of a
system share one AMD configuration), and the **volumes** (the arrays the BIOS menu lists) are member arrays of that
container. `mdmon` runs for the container and keeps the AMD metadata up to date.

- [Assembling](#assembling)
- [Creating](#creating)
- [Spares](#spares)
- [RAIDABLE → RAID1](#raidable--raid1)
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
- A volume in the middle of an AMD migration other than RAIDABLE → RAID1 is not assembled.

## Creating

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
global spare, as the AMD driver does. `--add` refuses a disk with an ext2/3/4 or ReiserFS file system or with another AMD set on it;
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
  spare if there is one. Replace the disk with `--add`, as above.
- **A disk is pulled:** the udev rule takes it out of the container (`mdadm -If`), its volumes fail it first. With a
  udev older than systemd 257, run `mdadm -If sdc` yourself after pulling the disk.
- **A disk comes back:** a member that was missing is rebuilt into its own place on that disk. A disk that failed
  on I/O errors waits for you, as with the AMD driver: `--remove` it, then `--add` it.
- **Booting with a disk missing:** the volume that holds the root file system starts degraded after about 30
  seconds (the last-resort timer, as for native md). Another volume on the same disks is not started then: start it
  with `mdadm --run` on the container (the `super external:amd` line of `/proc/mdstat`, for example
  `mdadm --run /dev/md127`). At the first boot after the disk is back such a volume stays `inactive` until the same
  command; left alone, it starts whole at a boot after the root volume's rebuild has finished.
- **A reboot during a rebuild or an initialization:** it goes on from the point recorded in the metadata. A rebuild
  target that comes only after its volume has started is copied from the start.

## Working with the BIOS and Windows

- Volumes made or changed by mdadm are shown as Normal by the BIOS menu and taken by the Windows driver, and the
  other way round. A rebuild, an initialization or a migration started by one goes on under the other.
- The AMD write-intent bitmap is kept as the AMD driver keeps it, so after a crash the BIOS and Windows check the
  volume as usual.
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
