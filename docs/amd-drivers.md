# AMD RAID drivers: how they differ from md

AMD's own RAID stack behaves differently from md in many places. This page lists what we found, how we found it,
and what this mdadm does about it: does the same for compatibility, works around it, refuses, or does not do it.
Problems of the UEFI driver alone are in [firmware-bugs.md](firmware-bugs.md); speed is in
[benchmark.md](benchmark.md).

What was looked at:

| | Versions | Where |
|---|---|---|
| Windows driver `rcraid.sys` | 9.3.3.218 (MSI's package for the test board) | the test machine (WinPE and an installed Windows 10), a VM |
| | 9.3.3.329 (WHQL), 9.5.0.201 | a VM |
| Linux driver `rcraid` | 9.3.3-00302 (from Lenovo's RHEL 10.1 driver package) | the test machine (only to measure it), emulation |
| | 9.3.2-00230 (a community build) | emulation |
| UEFI driver RAIDCoreDxe and its RAIDXpert2 menu | 9.3.3-00277 (MSI BIOS 1.A93) | the test machine, emulation |

"A VM" is Windows 10 in QEMU on disk images, with AMD's controller IDs. "Emulation" is the board's own firmware in
QEMU with emulated AMD controllers, with AMD's Linux driver in a Linux guest where said. "The disassembly" is of the
RAID core of AMD's Linux driver 9.3.3 (`rcblob`, with its own symbols); the Windows driver runs the same core.
Function names below are from those symbols. Dates are of 2026.

## At a glance

| AMD does | This mdadm | § |
|---|---|---|
| A write error fails the disk in that volume only | the same (since 1.5) | [1](#a-failure-is-recorded-in-one-volume) |
| Rebuilds only onto spares, in a fixed order | the same | [2](#rebuilds-go-onto-spares-only) |
| Rewrites the configuration at every start, renumbers it | takes it; does not rely on the numbers | [3](#the-configuration-is-rewritten-at-every-start) |
| Trusts the transform log as written | writes it as AMD does; records a rebuild target as gone when md writes without it | [4](#the-transform-log-is-trusted-as-written) |
| Takes a mirror member that missed a configuration update without a rebuild | stricter: `--run` and a full rebuild | [5](#a-member-that-missed-a-configuration-update) |
| Takes back a volume whose disks bring different configurations | refuses | [6](#disks-that-went-away-together) |
| TRIM only where every mirror reads zeroes after it | the same rule, a little wider | [7](#trim) |
| Moves data of an already moved volume with a log of the data | the same (since 1.6) | [8](#migrations) |
| Menu and `rcadm` create at most 8 disks per volume, 12 arrays | the same unless `--force` | [9](#limits-of-the-menu-and-rcadm) |
| Windows forgets a disk that was away | `--add` needed, as with AMD | [10](#windows-forgets-a-disk-that-was-away) |
| Windows clears or half-checks the bitmap after a Linux crash | resyncs at the next assembly | [11](#windows-after-a-linux-crash) |
| Windows Verify leaves RAID5 parity wrong | md's resync repairs it | [12](#the-windows-check-verify) |
| Windows 9.5 leaves a flag of its own on volumes | cleared when `mdmon` finishes its tasks | [13](#a-flag-of-windows-95) |
| Windows 9.3.3 crashes at boot on a rebuild target that lost writes | rebuilds it from the start (since 1.4) | [14](#windows-crashes-at-boot-on-a-rebuild-target-that-lost-writes) |
| Windows may stall finishing a RAID10 stripe size change while read | none (advice) | [15](#a-raid10-stripe-size-change-under-windows) |
| A RAID1 made by `rcadm` is not initialized | takes it as AMD recorded it | [16](#a-raid1-made-by-rcadm) |
| The Linux driver writes a wrong controller serial number | writes the right one back | [17](#the-linux-driver-writes-a-wrong-controller-serial-number) |
| The Linux driver drives the controllers itself, other makers' too | not needed | [18](#the-linux-driver-takes-the-controllers) |
| A disk missing at start loses its record | recorded offline instead | [19](#disk-records) |
| The firmware brings a disk that missed an update up to date at boot, without disk IDs | repairs the IDs | [20](#the-firmware-at-boot) |
| The menu shows a migration as "Transform" and leaves it | Linux and Windows finish it | [21](#the-menu-and-migrations) |
| The menu makes no volume of spares and spares only of whole disks | does both; AMD accepts them | [22](#the-menu-and-spares) |

# Both drivers: the AMD RAID core

## A failure is recorded in one volume

**AMD.** A write error fails the disk's element in the volume of that write only (element flag `0x10`;
`RC_SignalDriveErrorWithLogicalElement`, `RC_CommitDriveError`). The other volumes on the disk keep it, the
configuration is still written to it, and its disk record stays online. A disk record goes offline only when the
disk goes away (then every volume fails it at its first I/O) or a configuration write to it fails
(`RC_WriteAllConfigData`).

**How we know.** The disassembly; emulation with AMD's Linux driver (a write error on one sector during a RAID5
migration: the RAID5 element failed, a RAID1 on the same disk stayed normal, the disk online; 18.11); the Windows
drivers 9.3.3.218, 9.3.3.329 and 9.5 in a VM take such metadata and leave it as it is (19.11). On the test machine
(19.11), with a disk failed by mdadm in a RAID5 that shares it with a RAID0: the BIOS menu shows the RAID5 Critical
with all its disks online and the RAID0 Normal; Windows 9.3.3.218 reads both and leaves them so.

**This mdadm** does the same since 1.5 ([usage.md](usage.md#when-a-disk-fails-or-goes-missing)). Kept different
on purpose: a disk md failed in the last volume it serves is recorded offline and written to no more, as IMSM
does (AMD would go on writing the configuration to it). A disk that is pulled is failed in all its volumes, as
with AMD.

## Rebuilds go onto spares only

**AMD.** A degraded redundant volume is rebuilt only onto a spare: its dedicated spares first, then distributed,
then global ones (`RC_CheckRebuild`, `RC_SetupTransform`). Never onto the free space of a disk that is no spare,
and not onto the disk whose element failed: that disk is still a member of the volume. The Windows tool refuses
to make it a spare of that volume ("disk 0 is already part of array"). Further rules of the core:

- a dedicated spare can be any RAID disk that is online and not a member of the volume, also one that serves
  other volumes, up to four per volume (`RC_AssignSpare`); the BIOS menu offers only a whole free disk;
- a dedicated spare smaller than the smallest member is dropped (`RC_RemoveUnusableDedicatedSpares`);
- a global spare that a rebuild or a migration used keeps its spare mark on the disk; the BIOS menu then shows
  that member as "Global Spare".

**How we know.** The disassembly. Emulation with AMD's Linux driver (07.11): on a failure it rebuilt a RAID1 onto
its dedicated spare, a disk that was also a member of a RAID5, and a RAID5 onto a global spare; `mdmon` chose the
same disks and the same places. Windows in a VM and on the test machine (19.11): a volume failed in one volume
stays Critical; nothing is rebuilt until a spare is given.

**This mdadm** does the same: `mdmon` rebuilds onto spares only, in that order; `--add-spare` takes a disk of the
container with room, refuses one smaller than the members, a fifth one and one for a RAID0 or a Volume; the spare
mark is kept ([usage.md](usage.md#spares)). To rebuild a volume, give it a spare.

## The configuration is rewritten at every start

**AMD.** Both drivers write a new configuration each time they start, with nothing changed: the disk records
numbered again from port 0, the disk handles renumbered by Windows. The configuration number can start again from
1 (AMD's Linux driver went from 11 to 1). Windows records an NVMe disk without RAID metadata as "not initialized",
with a Legacy array of its own.

**How we know.** A VM (03.11, 12.11); emulation with AMD's Linux driver (07.11, 08.11); the test machine: Windows
9.3.3.218 wrote nine configurations in three minutes without any change (19.11).

**This mdadm** finds disks by their IDs (a hash of the serial number), not by handle or port, so a configuration
written by AMD is assembled as it is. It tells a configuration it wrote itself from AMD's by the number and the
checksum together, so a number that went back is not taken for its own (this decides whether the md bitmap is
trusted, [install.md](install.md#the-md-bitmap)). `--add` refuses an NVMe disk Windows recorded "not initialized":
initialize it in the BIOS menu or with `rcadm -M -id` first.

## The transform log is trusted as written

**AMD** continues an initialization, a rebuild or a migration from the mark in the volume's transform log, as the
log has it:

- the I/O fields of an initialization log are used as written: a log with an I/O size of 0 made AMD's Linux
  driver report the volume "gone critical", and Windows left it Critical and hung;
- a rebuild target's mark is trusted even when the volume was written without the target since: AMD's Linux
  driver went on from the old mark and left the two halves of the mirror different, without a word;
- the log is read from the first element of the target volume only; an element that does not take a write of the
  log is failed, and the transformation goes on.

**How we know.** Emulation with AMD's Linux driver (07.11, 18.11), Windows 9.3.3.218 in a VM (07.11, 08.11), the
disassembly (`RC_TransformDiskLogNextRegion`).

**This mdadm** writes the log fields as AMD does; when md writes a volume without its rebuild target, `mdmon`
records the configuration without the target, so that AMD starts that rebuild again from the start (both drivers
then rebuilt the mirror whole; since 1.0). It writes the log to every member and fails, in md, a member that does
not take it, as AMD does (since 1.5).

## A member that missed a configuration update

**AMD.** The BIOS at boot and Windows take a RAID0, a Volume or a RAIDABLE with a disk that missed the latest
configuration update, and also a mirror with such a member, as Normal, without a rebuild, and write the current
configuration onto that disk.

**How we know.** Emulation (the menu and the firmware at boot) and Windows 9.3.3.218 in a VM (12.11).

**This mdadm** takes such a RAID0, Volume or RAIDABLE as AMD does: it cannot have been written without that disk.
A mirror or a RAID5 starts without it only with `--run`, and the disk is rebuilt: stricter than AMD, because a
member one update behind may also have missed writes ([usage.md](usage.md#assembling)). `mdmon` brings the disk's
copy of the configuration up to date.

## Disks that went away together

**AMD.** A volume whose disks all went away together is recorded offline. When they come back, AMD takes it back
without a rebuild, also when they bring different configurations; the mirrors then differ, and reads of the same
place return different data. A member recorded as away is recorded failed before the volume is written without
it.

**How we know.** Emulation with AMD's Linux driver (15.11, 16.11).

**This mdadm** takes such a volume back without a rebuild only when the disks bring the same configuration, also
one at a time; otherwise the volume is rebuilt from the current member. A member recorded as away is recorded
failed before md writes without it (since 1.5; [usage.md](usage.md#when-a-disk-fails-or-goes-missing)).

## TRIM

**AMD** (the disassembly): TRIM reaches a mirror (RAID1) only if every member reads zeroes after TRIM: for SATA,
IDENTIFY word 169 is 1 and word 69 bit 5 is set (`RC_DeterministicTrimZeroCount`, `RC_IsTrimAllowed`). The driver
tells the system that a RAID10 or a RAID5 takes no TRIM at all (`RC_CheckLogicalDeviceTrimable`), sends none during
a transformation, and none to a degraded mirror. The Linux build sets the "zeroes after TRIM" mark for SATA disks
only, so its NVMe mirrors never get TRIM. The reason: md passes TRIM to mirrors in any case, and on disks that do
not read zeroes after it, AMD's check would find the mirrors different in unused space.

**This mdadm** turns TRIM off on a RAID5 and on a RAID1 or RAID10 with a member that does not read zeroes after
TRIM (for SATA it also asks for word 69 bit 14), and decides again on each new member. Different on the safe side:
a RAID10 and an NVMe mirror whose members all read zeroes keep TRIM, and so does a degraded mirror whose remaining
members do. On the test machine (04.11, 09.11) `mdmon` turned TRIM off on the HDD mirrors and the RAID5 and left
it on a RAID1 of two SATA SSDs ([usage.md](usage.md#working-with-the-bios-and-windows)).

## Migrations

- **Stripe size.** AMD's tools do not offer a stripe size change, but the drivers carry one through to the end:
  AMD's Linux driver in emulation (15.11), Windows 9.3.3.218 on the test machine (16.11), 9.3.3.329 and 9.5 in a VM
  (18.11). This mdadm makes it (`--grow --chunk`) and records it as an AMD migration.
- **A second migration that moves data.** After a migration that moved a volume's data, AMD does the next one in
  place with a log of the data (the disassembly, `RC_SetupTransformParams`; volumes AMD's Linux driver migrated
  twice in emulation). This mdadm writes that log as AMD does and carries such a second migration out in place
  (since 1.6); a stripe size change of such a volume moves the data back up from the end, as the AMD driver would
  (`RC_SetupTransformParams`; AMD's Linux driver takes both, both ways, in emulation; on real hardware the Windows driver finishes both)
  ([usage.md](usage.md#more-disks-raid1--raid5-stripe-size)).

## Limits of the menu and rcadm

**AMD.** The BIOS menu and `rcadm` create at most 8 disks per volume (a RAID1 of exactly 2, a RAID10 of 4 to 8)
and 12 arrays in a system, a Legacy disk counting as one; `rcadm` makes no volume under 100 MB. The BIOS menu
offers Volume, RAIDAble, RAID0, RAID1, RAID5 and RAID10; RAID6 and RAID50 no AMD platform we know of enables.
The BIOS and Windows accept larger volumes: up to 12 disks on two controllers in emulation and in a VM (12.11). On
the test machine (06.11) the menu refused a RAID1 of three disks and greyed out Create at 12 arrays.

**This mdadm** keeps the same limits unless `--force` is given ([usage.md](usage.md#creating)). It also creates
volumes under 100 MB (not tried with AMD). RAID6 and RAID50 volumes it neither creates nor assembles.

# The Windows driver

## Windows forgets a disk that was away

**AMD.** Running without a disk, Windows drops the disk's record and marks its elements offline. When the disk comes
back, the IDs of its elements are erased: the disk is a free one. Windows rebuilds onto it by itself only if it is
a global spare; otherwise its volumes stay Critical until the user acts. A former member that comes back during a
rebuild is not taken as the target (9.3.3.218, 9.3.3.329, 9.5). The BIOS menu and `rcadm` also count the space of
a member recorded offline as free, put a new volume over it, and erase the old element.

**How we know.** A VM (04.11, 12.11, 14.11, 15.11, 19.11).

**This mdadm** rebuilds a returning disk into its own place when its element still carries its ID; one whose
element Windows erased it takes only with `--add` (as a spare, then rebuilt onto), as with AMD. `mdmon` writes
nothing into the space of a member recorded offline.

## Windows after a Linux crash

**AMD.** After Linux crashed while writing, the volumes' AMD write-intent bitmap is dirty. Windows 9.5 clears it
within about 30 seconds without checking the volume. 9.3.3.218 and 9.3.3.329 start a check by the bitmap, but make
the mirrors agree only in about the first 100–200 MiB of the volume, and leave RAID5 parity as it is.

**How we know.** A VM (14.11, 15.11).

**This mdadm** keeps its own copy of the bitmap's state, which the AMD drivers do not write, and resyncs such a
volume at the next assembly (since 1.2; [usage.md](usage.md#working-with-the-bios-and-windows)). After a crash,
start Linux first, or run `repair` on the volume from Linux.

## The Windows check (Verify)

**AMD.** `rcadm -M -cs` makes the copies of a RAID10 agree with the first copy without telling, and neither
repairs nor reports wrong RAID5 parity.

**How we know.** Windows 9.3.3.218 in a VM, with garbage written into one copy and into parity (03.11).

**This mdadm.** A Windows check cut short (a power loss) is continued by md's resync from the mark in AMD's log,
which also rewrites wrong RAID5 parity, and `mdmon` records the check as completed; Windows then takes the volume
as Normal (since 1.3; 9.3.3.218, 9.3.3.329, 9.5 in a VM). A Critical volume with a check cut short is assembled
read-only.

## A flag of Windows 9.5

**AMD.** Windows 9.5 sets bit `0x20000000` of the volume flags on the disks while it initializes, rebuilds or
checks a volume, and clears it at the end. 9.3.3.218 and 9.3.3.329 do not set it.

**How we know.** A VM (14.11, 15.11).

**This mdadm** clears it too when `mdmon` finishes such a task that 9.5 started (since 1.2); 9.5 then takes the
volume as Normal and its next check runs to the end.

## Windows crashes at boot on a rebuild target that lost writes

**AMD.** If the target of a rebuild holds an older configuration than the other disks, from the middle of the
rebuild, Windows 9.3.3.329 stops at boot with a blue screen in `rcraid.sys` (`SYSTEM_THREAD_EXCEPTION_NOT_HANDLED`,
`DRIVER_IRQL_NOT_LESS_OR_EQUAL`; `DRIVER_POWER_STATE_FAILURE` with slowed disks), and 9.3.3.218 hangs at boot or
shows the same. This happens only when the disk lost writes it had acknowledged (its write cache lost at a power
loss). 9.5 was not tried.

**How we know.** A VM, on disk sets made up from snapshots of a rebuild (15.11): four boots on three sets.

**This mdadm** rebuilds such a target again from the start and writes the configuration to all disks; Windows
9.3.3.218 and 9.3.3.329 then boot, with the volumes Normal and the data the same (since 1.4). After a power loss
during a rebuild, start Linux first.

## A RAID10 stripe size change under Windows

**AMD.** When Windows finishes a RAID10 stripe size change that mdadm left midway, and the volume is read
meanwhile, the volume's I/O may stall: `rcadm` stops answering, the driver resets the device, shutdown hangs.
9.3.3.218, 9.3.3.329 and 9.5 alike; the data stay safe.

**How we know.** A VM with the disks slowed to 3 and 10 MB/s (18.11); not seen without the slow-down or without
the reads; not tried on real disks.

**This mdadm** changes nothing here: let mdadm finish the change, or let Windows finish it before the volume is
used ([usage.md](usage.md#more-disks-raid1--raid5-stripe-size)). After a hard power-off, mdadm goes on from the
mark Windows wrote.

## A RAID1 made by rcadm

**AMD.** `rcadm -C` records a new RAID1 as Normal at once, without an initialization (a RAID10 or RAID5 it
initializes; so does the BIOS menu for a RAID1).

**How we know.** A VM (04.11).

**This mdadm** takes such a RAID1 as AMD recorded it, in sync. A RAID1 it creates itself is initialized by md
unless `--assume-clean` is given.

# The Linux driver

## The Linux driver writes a wrong controller serial number

**AMD.** AMD's Linux driver records its controller serial number as `102285900000`; the firmware and Windows use
`859010220000`. The two halves are swapped in a constant of the driver's core (`RC_STH_DiscoverAdapter`), in every
Linux build we have (9.3.2 and 9.3.3). The BIOS then takes such disks for another controller's set: it assembles
them and gives their volumes but does not write them; Windows makes them its own at its first write.

**How we know.** The test machine (08.11): after AMD's Linux driver ran on two HDDs, their configuration carried
`102285900000`; the disassembly of the firmware, of `rcraid.sys` and of the Linux cores.

**This mdadm** says "last online on another controller" for such disks and, like the AMD drivers, makes the set
its own with its first write, with the firmware's serial number; the UUIDs of the container and its volumes come
from that number, so they do not change ([usage.md](usage.md#working-with-the-bios-and-windows)).

## The Linux driver takes the controllers

**AMD.** AMD's Linux driver drives the disks itself, in place of `ahci` and `nvme`, and shows each volume as a SCSI
disk. In emulation it took an Intel AHCI controller (ICH9) as well, and after the driver was unloaded the
controllers were left without a driver. So it cannot run next to md on the same disks.

**How we know.** Emulation (07.11). For the measurements on the test machine we built it without its NVMe part,
so that it could not take the system disk ([benchmark.md](benchmark.md)).

**This mdadm** needs no AMD driver in Linux. Why AMD's Linux driver is slower on random reads:
[benchmark.md](benchmark.md#amds-linux-driver-random-reads-and-ssd-sequential-reads).

## Disk records

**AMD.** A disk that is missing when the driver starts loses its disk record (Windows does the same), and the
remaining disks are numbered again. A disk whose configuration write failed is recorded offline.

**How we know.** Emulation with AMD's Linux driver 9.3.2 and 9.3.3 (07.11), which wrote the same records; the
disassembly.

**This mdadm** records a missing disk offline instead of removing its record, so that the disk is known again by
its record when it comes back. The BIOS menu and both drivers take such configurations.

# The firmware and its menu

Besides [firmware-bugs.md](firmware-bugs.md):

## The firmware at boot

**AMD.** When a disk missed the latest configuration update, the firmware writes the current configuration onto
the disks at boot (see also [firmware-bugs.md](firmware-bugs.md#2-the-firmware-rewrites-the-configuration-at-boot)).
The disk records of a configuration the firmware writes lack the disks' IDs, also of ones the menu writes
(Initialize, Delete Array) in emulation.

**How we know.** Emulation (12.11); the test machine (02.11: configurations written at boot with the disk IDs
zeroed).

**This mdadm** writes the IDs back into such records with its next write (tried on the test machine, 02.11).

## The menu and migrations

**AMD.** During a migration the BIOS menu shows the volume as "Transform" and writes nothing; the migration goes
on only under an operating system driver.

**How we know.** The test machine (16.11, 19.11): the RAID metadata area of every disk was the same byte for byte
before and after the menu.

**This mdadm** goes on from the mark after such a boot, and so does Windows
([usage.md](usage.md#more-disks-raid1--raid5-stripe-size)).

## The menu and spares

**AMD.** The menu makes no volume of spares, and offers as a dedicated spare only a whole free disk.

**This mdadm** makes a new volume of the container's global spares too, as IMSM does, and takes a disk with room
as a dedicated spare, as the RAID core does ([Rebuilds go onto spares only](#rebuilds-go-onto-spares-only)). The
BIOS menu (the test machine, 09.11) and Windows (a VM, 09.11) take such volumes as Normal.
