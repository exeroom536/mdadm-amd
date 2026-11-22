# Changes

## 1.6.1 — 2026-11-22

**Fixed.**
- Growing a RAID1, RAID10 or RAID5 in place (`mdadm --grow --size`, since 1.4), stopped midway and then finished
  by the Windows driver, left a strip of the new part without its mirror copy or parity: from where md had
  stopped to the end of the region mdmon had logged (a region is 9 MiB of the volume for a RAID1, 16 MiB for a
  RAID10, 9 MiB a data disk for a RAID5). The Windows driver (9.3.3.218) takes the region at the log's mark as done
  and goes on from the next one; AMD's Linux driver repeats it. mdmon now logs the region below the one md is in,
  so that either driver goes on at or below where md stopped. User data written before the growth were not
  touched; a disk failing there later would have read wrong data back. Found on real hardware: a RAID5 finished
  by Windows had 7680 sectors of wrong parity, exactly in that strip.
- If such a growth of yours was finished by Windows, a check shows it (`echo check >
  /sys/block/mdX/md/sync_action`, then `mismatch_cnt`), and `repair` instead of `check` rewrites it.
- Growing in place refuses a volume smaller than one region of the log: there is no region
  below its old end to log.

**Tests.** Stage 70: the new part of a RAID1 different on its two halves, the growth stopped midway — md has
mirrored everything below the end of the logged region, where the Windows driver goes on; the growth of a too
small volume is refused. Stage 48 checks the log a region lower. 845 checks in 83 stages, all pass in a VM with
the emulated AMD controllers. mdadm's own tests on `4cd7d33c`: 69 pass, 0 fail, 1 skipped.

**On real hardware** (MSI X870E, BIOS 1.A93, kernel 7.3.5). A RAID5 of three disks, a RAID10 2 × 2 and a RAID1,
1 GiB a member grown to 2 GiB, the new part filled with random data first, stopped with `mdadm -S` twice and
going on after assembly, then finished by the Windows driver: `md` check clean on all three, every sector of the
old part right (with 1.6 the RAID5 showed the bug above). The BIOS menu shows the RAID5 of 1.6's second migration
as Normal, 128 KB, all disks online, and writes nothing to the disks; after the release, a RAID10 and a RAID5
grown by Linux: Normal with the new size, nothing written.

## 1.6 — 2026-11-22

**Base.** The patch and the series now apply to upstream mdadm `4cd7d33c` (mdadm-4.6-132, 20 November 2026) instead
of `5542bf40`. Upstream renamed `mdopen.c` to `mddev.c` (one line of the `Makefile` in the patch follows it),
dropped `raid5extend.c` and the static build, and added tests and an IMSM `--data-offset`; the AMD handler relies on
none of it. The package gives mdadm `4.6.r132.g4cd7d33c` (`provides=mdadm`).

**New.**
- A volume whose data a migration moved already (more disks, RAID1 → RAID5, stripe size) gets more disks again
  with `mdadm --grow --raid-devices` (a RAID0 or a RAID5), as AMD does it: in place, the first stripes through the
  log of their data AMD keeps in front of each member. A migration stopped in those first stripes, by mdadm or by
  the AMD driver, is finished there as the volume is assembled, before md runs it; before, such a volume was not
  assembled, or ran as it was with the migration left recorded.
- `mdadm --grow --chunk` of such a volume (a RAID5 or a RAID10): the data go back up 9 MiB, from the end of the
  volume, as the AMD driver would move them; md reshapes it backwards. More disks and another stripe size at once
  stay refused for such a volume: one, then the other. Two fixes of mdadm's own `Grow.c` and `sysfs.c` (patches 32
  and 33 of `mdadm/series/`): a reshape whose data move up is held from its end - also where `mdadm --grow --continue`, as the
  `mdadm-grow-continue@` unit runs it under systemd, takes it on -, and md is given the new data
  offsets the way it takes higher ones.
- Both tried in emulation with AMD's Linux driver (rcraid 9.3.3), both ways: it finishes ours stopped midway,
  mdadm finishes its own, the final records the same as the AMD driver's; on real hardware the Windows driver
  finishes ours (below).

**Fixed.**
- Going on with the AMD driver's own second migration of a RAID0 (more disks again, stopped midway) could hang for
  good (1.5 and 1.5.1): md was held across a stripe of the old layout, a read of that stripe waited for md, and
  mdadm, moving the window of writes it holds, waited for that read. The window now moves only where stripes of
  both layouts end, and assembly takes such a migration on to that point first. Reproduced on loop devices from
  the AMD driver's own marks (RAID0 of 3 → 4 and 4 → 5 disks); gone with the fix.
- A safeguard: mdadm refuses a migration whose record would not read back as one md reshapes — mdadm would then
  reshape the volume its own way, without the AMD log. No such case is known.

**Tests.** Stages 65 (a second migration of a RAID0 and a RAID5 in place, ours and the AMD driver's, stopped in
the first stripes), 66 (the stripe size of such a volume changed backwards, ours and the AMD driver's, stopped
midway), 67 (no hang with a reader where md is held midway through a stripe of the old layout), 68 (stripe
size changes one after another without a pause) and 69 (that change backwards carried on by `mdadm --grow
--continue`, its manager killed at the start, midway and after assembly), with two new fixtures of the AMD driver's snapshots
(`2026-11-19-rcraid-second-migration/`, `2026-11-20-rcraid-chunk-backwards/`); stages 51, 53 and 54 check what
changed for data moved already. 842 checks in 82 stages, all pass in a VM with the emulated AMD controllers.
mdadm's own tests on `4cd7d33c`: 69 pass, 0 fail,
1 skipped (two more tests upstream).

**On real hardware** (MSI X870E, BIOS 1.A93, kernel 7.3.5; two HDDs and two SATA SSDs, 1 GiB of each, every sector
holding its own number). A RAID10 2 × 2 whose data a first stripe size change had moved down: `--grow --chunk=64`,
backwards; stopped with `mdadm -S` twice, it went on after assembly under systemd from the AMD log, every sector
right while md reshaped; stopped at 60 %, the Windows driver (9.3.3.218) finished it: 64 KiB, the data 9 MiB
higher, every sector right, `md` check clean. A RAID5 of three disks (64 → 128 KiB first, the data moved down) got
a fourth disk in place (`--add-spare`, `--raid-devices=4`), stopped at 30 % and 60 % the same way: Windows finished
it, 3 GiB, every sector right, `md` check clean. The first run of the RAID10 change stood at 0: `mdadm --grow
--continue`, which carries a reshape on under systemd, read the progress of a reshape md runs backwards as counted
from the start (fixed before the release, patch 32; stage 69). Not looked at with this release: the BIOS menu.

## 1.5.1 — 2026-11-21

**Fixed.**
- A RAID10 stopped with `mdadm -S` in the middle of a stripe size change (`mdadm --grow --chunk`) could come back
  with part of one region left in the old layout: after assembly the volume read wrong data there, silently (`md`
  check found nothing). While md cleans up the reshape it was stopped in, it shows the whole volume done for a few
  milliseconds, and the migration manager took that for the end of the region and recorded the next one as
  reached. In a VM 9 of 50 stops of small volumes went wrong with 1.5, none of 50 with the fix; RAID5 and RAID0
  did not show it.
- A RAID10 of six disks (3 × 2) whose stripe size change was stopped in every other region of the migration did
  not go on after assembly: "Cannot continue reshape", the volume stayed read-only, and while it stood so it read
  wrong data in the part md had moved already (the data on the disks were intact). mdadm held md where the
  migration goes on from in the units of a RAID5, a position md refuses for a RAID10 of three mirror pairs; a
  RAID10 of four disks went on by chance. A fix of mdadm's own `Grow.c`, and the same in `Assemble.c` for a volume
  that waits for another migration of its container (that case not tried). The wrong reads are the kernel's: its
  raid10 reads a reshape that stands still with the old data offset, native arrays too; with the fix the reshape
  goes on instead.
- A RAID10 whose stripe size change was stopped with `mdadm -S` could come back with up to a third of the volume
  left in the old layout (on real hardware: a RAID10 of four disks stopped at 31 % was assembled at 64 %, and all
  between read wrong data; `md` check found nothing). Three things went wrong together. `mdmon` wrote the metadata
  as md ended the reshape it was stopped in, then told md to go on - and so ran the volume it had just stopped again
  (a fix of mdmon's own `monitor.c`; Intel IMSM takes the same path, not tried). The volume that came back made udev
  start a second migration manager (`mdadm-grow-continue@`) as the first one left; it took how far md had been let
  go for where md was - for a RAID10 twice that, as mdadm's `Grow.c` counted a RAID10's position as a RAID5's (fixed
  too) - and recorded the migration in the AMD log there, where md went on from after assembly. The manager now goes
  on from the AMD log on the disks, as md and the AMD driver do after assembly. It also no longer takes the whole
  volume that `/proc/mdstat` shows for a moment as md is interrupted without being frozen first for the end of a
  region, and no longer crashes (SIGSEGV) when the container was stopped by the time it ended. In a VM, a second
  manager on a running volume left the data wrong every time before the fix (3 of 3) and never with it; `mdadm -S`
  ran the volume again in 21 of 24 stops before, in none of 9 with it.

**Tests.** Stages 62 (a RAID10 stopped with `mdadm -S` midway through a stripe size change, 24 times), 63 (a
RAID10 of 3 × 2 and of 2 × 2 stopped at different places goes on after assembly) and 64 (a second migration
manager on a running RAID10, md interrupted without being frozen, `mdmon` and a volume stopped with `mdadm -S`):
797 checks in 77 stages, all pass in a VM with the emulated AMD controllers. mdadm's own tests pass as
before (67 pass, 1 skipped, as upstream).

**On real hardware** (the board, Windows with driver 9.3.3.218): a RAID10 of two HDDs and two SSDs stopped with
`mdadm -S` midway through a stripe size change (five times; and twice in a row, then finished by Windows),
and a second migration manager forced on it - every sector right after assembly, `md` check clean
([docs/testing.md](docs/testing.md#hardware)). The BIOS menu was not looked at with this fix (it showed such a
volume as "Transform" with the first one).

## 1.5 — 2026-11-19

**New.**
- `mdadm --grow --raid-devices` gives a RAID0 or a RAID5 more disks, and `mdadm --grow --level=5
  --layout=right-asymmetric --raid-devices=N` makes a RAID1 of two a RAID5, as the AMD migrations (`rcadm -T`) do:
  md reshapes the volume and moves the data of each member 9 MiB down, as AMD does. The new disks come from the
  container's spares as with AMD: the volume's dedicated spares (`--add-spare`, also a disk of the container with
  room) first, then the global ones; a RAID0 takes global spares only.
- `mdadm --grow --chunk` changes the stripe size of a RAID5 or a RAID10 in place (64, 128 or 256 KiB), which AMD's
  own tools do not offer; it is recorded as an AMD migration, and the AMD drivers take it.
- Tried on real hardware with the BIOS menu and Windows (driver 9.3.3.218): RAID5 of 3 → 4 disks, RAID0 of 2 → 3,
  RAID1 of two → RAID5 of 3, the stripe size of a RAID5 and of a RAID10. Stopped midway by mdadm, the BIOS menu
  shows the volume as "Transform" and the Windows driver finishes the migration; the same both ways with AMD's
  Linux driver in emulation. In a VM, the Windows drivers 9.3.3.329 and 9.5 take them the same way. A RAID10
  stripe size change stopped midway is best finished before the volume is read under Windows: reading it while
  the Windows driver carries the change on may stall it (all three driver versions; the data stay safe).
- A volume in the middle of such an AMD migration is now assembled, and `mdmon` finishes the migration.
- A migration stopped before md moved anything goes on from the start at the next assembly, as with the AMD driver
  and IMSM; before, a RAID5 dropped it and a RAID0 kept it recorded until the next `--grow`. A fix of mdadm's own
  `Assemble.c` and `Grow.c`: a reshape that moves the data, at its start, is continued like one in the middle.
- Several migrations the AMD driver left in one container are finished one after the other, without a new
  assembly; a volume that waits for its turn is assembled read-only. A fix of `Assemble.c` and `Grow.c` too.
- A volume the AMD driver recorded offline because all its disks went away together is taken back without a
  rebuild when they come back with the same configuration, also one at a time, as the AMD driver does; not when
  they bring different ones (the AMD driver takes it then, with mirrors that differ). Volumes whose members all
  fell behind together are assembled from them. Tried in emulation with AMD's Linux driver.
- `md-bitmap-ext-dkms` covers Linux 6.18.64 and 7.3.5 too: their `drivers/md` is that of 6.18.63 and 7.3.4.
  Built for CachyOS 7.3.5.

**Fixed.**
- A disk that did not take the AMD transform log (a write error on that one sector) kept the log from the disks after
  it: an initialization or a rebuild went on from the start after a restart, and the AMD driver could read no mark.
  The log now goes on every disk that takes it, and the disk that did not take it is failed in md where the volume
  runs on without it, as the AMD driver fails it: its copy, left behind, is read by no one. Where the volume cannot
  do without it (a RAID0 being reshaped, a volume degraded already) the reshape waits at its region, and so do the
  writes to the region; they wait too while md does not reshape (frozen, interrupted). (With the migrations that
  move data, new in this release, it would have lost data written meanwhile.) Tried with AMD's Linux driver in
  emulation: it fails such a disk's element the same way; the Windows drivers 9.3.3.218, 9.3.3.329 and 9.5 (in a
  VM) take the degraded volume, finished by Linux or stopped midway and finished by Windows, with the same data.
- A disk md failed in one volume was failed by `mdmon` in every volume of the container, recorded offline and
  written to no more: a RAID1 or RAID5 sharing the disk lost it for no reason, and the metadata differed from what
  the AMD driver writes. It is now failed in that volume alone, as the AMD driver records it (tried with AMD's
  Linux driver in emulation, and with the Windows drivers 9.3.3.218, 9.3.3.329 and 9.5 in a VM: the other volumes
  normal, the disk online, the data the same; on real hardware the BIOS menu and Windows 9.3.3.218 see it so
  too, see [docs/testing.md](docs/testing.md#hardware)); a disk failed in every volume it serves, one a configuration write
  failed on, and one that goes away are recorded offline, as IMSM does. If the Windows driver then rebuilds a
  volume onto such a disk, mdadm resyncs that volume once. The change in mdmon's own code is used by no other
  format.
- With an `mdmon` that had exited but was not reaped (the shutdown ramfs of systemd), mdadm took it for running:
  `--stop` of a container waited 5 s and said "still running", and `-I` of a container left its volume read-only
  without mdmon. mdadm also no longer holds the container while it starts mdmon, which could cost about 4 s when an
  mdmon was coming up at the same time. Both in mdadm's own code, for IMSM as well.
- `mdadm -A <volume> --uuid=... <container>` (or `--name`) no longer says "<container> has wrong uuid" for each
  other volume of the container before the one it assembles; for IMSM as well.
- A member the AMD driver had recorded as away (its disk not found, the volume not written since) stayed so while
  md wrote the volume without it: had the disk come back under the AMD driver, the driver would have taken its
  stale copy without a rebuild. It is now recorded as failed before the first write, as the AMD driver does.
- A disk that joined the container after `mdmon` had written the configuration, and that md runs in sync, now
  gets the current configuration at once; a migration of its volume no longer refuses to start.

**Tests.** Stages 51 (RAID5 + disks, RAID1 → RAID5), 52 (two disks away together), 53 (the chunk), 54 (RAID0 +
disks), 55 (migrations stopped before their first region), 56 (volumes recorded offline), 57 and 60 (a member
that does not take the transform log), 58 (a zombie `mdmon`), 59 (`-A --uuid`, `--name`) and 61 (a member failed
in one volume); fixtures `tests/fixtures/2026-11-15-rcraid-chunk/`, `2026-11-16-rcraid-chunk-begun/`,
`2026-11-15-rcraid-away/` and two more snapshots in `2026-11-15-rcraid-migrations/`: 791 checks in 74 stages.

**On real hardware** (the board, its BIOS menu and Windows with driver 9.3.3.218): the migrations and a member
failed in one volume, booting Linux and Windows from volumes with this release ([docs/testing.md](docs/testing.md#hardware)).
Not there yet: a disk that does not take the transform log (emulation and a VM only), a disk that goes away or
fails in every volume it serves, and two disks away together (they need the disks unplugged).

## 1.4 — 2026-11-15

**New.**
- `mdadm --grow --size` makes a RAID1, RAID10 or RAID5 larger in place, and `mdadm --grow --level=10` makes a
  RAID0 of n disks a RAID10 of 2n with n spares of the container, as the AMD migrations (`rcadm -T`) do. The
  migration is recorded as the AMD driver records it: stopped midway, it goes on from where it was, under md or
  under AMD's Linux driver 9.3.3-00302, both ways; such a migration that driver started is finished by `mdmon`.
  Tried in emulation with that driver; not with Windows or the BIOS.
- `mdadm --detail-platform -e amd` (and `--export`) shows what the AMD firmware takes for RAID: the EFI variable
  `AMD_RAID`, the controllers it makes the firmware take with the disks behind them and their serial numbers, the
  levels, chunk sizes and limits of `--create`. A controller path as the argument shows that one only.
- `packaging/dkms/install.sh` installs the optional md bitmap module (the one of `md-bitmap-ext-dkms`) on
  distributions without the Arch package; tried on openSUSE Tumbleweed in emulation. Fedora 45 and Ubuntu 26.04
  build md into the kernel: there only a kernel rebuilt with `kernel/` gets the fix. With Secure Boot, the DKMS key
  must be enrolled first, or no md array starts ([install.md](docs/install.md#the-dkms-module-without-the-arch-package)).

**Fixed.**
- Volumes that an AMD migration grew by adding disks (RAID0 or RAID5 onto more disks, RAID1 → RAID5) are now
  assembled. Such a migration moves the data of each member down, to 1 MiB into its extent, and leaves them there;
  mdadm took the volume for a broken one ("member extents are not where AMD puts them"). Tried in emulation with
  `rcadm -T` of AMD's Linux driver 9.3.3-00302: the volumes read the same under md as under that driver, `md`
  check clean. Not tried with RAIDXpert2 in Windows. A volume in the middle of such a migration is still not
  assembled.
- A rebuild target that lost the end of its rebuild (its write cache gone at a power loss, so that it holds
  the configuration of the rebuild's middle) is rebuilt again from the start. Before, `mdmon` wrote it the
  current configuration when it rebuilt another volume onto that disk, and the volume it had been rebuilt into
  started in sync with mirrors that differ; the Windows driver does the same. Tried in emulation, and in a VM
  with the Windows driver 9.3.3.329 and 9.3.3.218 after Linux: Windows boots, its volumes Normal, the data the same.
- After `mdmon` took over a configuration the AMD driver wrote, disks that came after its first write (spares, for
  one) kept the AMD driver's configuration; that driver then took its own configuration as the newer one and the
  volume offline. Found in emulation with AMD's Linux driver after its migration; it can happen with any
  configuration of the AMD driver whose spares come after the members.
- `mdadm --grow --size` of a volume of a container that was assembled but not yet written to (md keeps it
  read-only until the first write) failed with "Cannot set device size: Read-only file system". A fix of
  mdadm's own `Grow.c`, as it already does when the number of disks changes.
- `mdmon` tells the kernel log of a write of the configuration, the transform log or the AMD bitmap that keeps
  failing once, and once more when it goes through again; before, it wrote the line at every write it tried.

**Tests.** Stages 45 (`--detail-platform`), 46 (a write that keeps failing), 47 (volumes after AMD migrations;
fixtures `tests/fixtures/2026-11-15-rcraid-migrations/`), 48 (growing in place), 49 (RAID0 → RAID10; fixtures
`tests/fixtures/2026-11-15-rcraid-grow/`) and 50 (a rebuild target that lost the end of its rebuild): 639 checks in 63 stages.
`tests/run.sh` unmounts the suite's work area when it ends (it stayed mounted, and the work directory could not be
removed without `umount`).

**Docs.**
- `mdadm(8)` and [usage.md](docs/usage.md#growing-a-volume-raid0--raid10): growing a volume in place and
  RAID0 → RAID10. The patch series has 35 patches: a new one of common code (21, `--grow --size` of a read-auto
  member array) and a new stage of the handler (33, the migrations).
- The Windows driver 9.3.3.329 tried in a VM against 1.3 ([testing.md](docs/testing.md#amd-drivers)): no difference
  from 9.3.3.218 that matters to this mdadm. After a Linux crash 9.3.3.218 and 9.3.3.329 make the mirrors agree only
  near the start of the volume (testing.md said they checked the mirrors); `mdmon` resyncs such volumes anyway.
- The roadmap no longer lists DKMS modules: `md-bitmap-ext-dkms` is an optional package, and the TRIM
  fix (`kernel/blk-discard/`) cannot be a module at all: it is in the block layer, which is built into the kernel.

## 1.3 — 2026-11-15

**Fixed.**
- A volume whose check (Verify) in Windows was cut short, by a power loss for one, is no longer assembled read-only:
  md resyncs it from where the AMD driver's transform log has it, and `mdmon` records the check as completed, as
  the AMD driver does; Windows then takes the volume as Normal (tried with the Windows driver 9.5.0-00201 and
  9.3.3.218 in a VM). The end of an initialization now also clears the transform fields the AMD driver clears.
- After a boot with a disk missing, a volume the boot does not need is started degraded as well, 30 to 90 s after
  boot, by mdadm's own last-resort timer. Before, it stayed inactive until `mdadm --run`: the timer started in the
  initramfs was stopped at the switch to the real root. Tried in emulation on Arch, CachyOS, Debian 13, Ubuntu
  24.04 and 26.04, Fedora 45, AlmaLinux 9.8 and 10.2, openSUSE Tumbleweed and Leap 16.1; not on real hardware.
- `mdadm --create` of a Volume (linear) on a kernel without `md-linear` (Debian 13, Ubuntu 24.04) is refused before
  anything is written. Before, the volume was written into the AMD configuration and then failed to start.

**Tests.** Stages 43 (a check cut short in Windows) and 44 (a Volume on a kernel without `md-linear`): 586 checks in
57 stages. The scripts in the repository are executable again (after a clone, `tests/run.sh` failed with
"Permission denied"), and `run.sh` says so when files of an earlier run as root are in its work directory.

**Packaging.**
- Drop-ins for `mdadm-last-resort@.timer` and `.service` (`IgnoreOnIsolate`, the initramfs waits for a running
  `mdadm --run`, a 90 s start timeout) in the Arch package and the dracut module; a `local-bottom` script for
  initramfs-tools.

**Docs.**
- The install guide was followed as written, booting from a volume in emulation, on Arch, Debian 13, Ubuntu 24.04
  and 26.04, Fedora 45, AlmaLinux 9.8 and 10.2, openSUSE Tumbleweed and Leap 16.1; Manjaro, EndeavourOS and Linux
  Mint were checked in containers, Gentoo, NixOS, Void and Alpine build. Fixes from that: the dnf versionlock plugin
  on RHEL 9 and 10, Uninstall steps for Ubuntu 26.04 and openSUSE, a warning not to uninstall with the root on a
  volume, which kernels ship `md-linear` ([testing.md](docs/testing.md#distributions)).

**Known issues.**
- Debian and Ubuntu with the root on a volume: restart `mdmon@` after installing a new build, or the root volume
  resyncs after the next reboot ([install.md](docs/install.md#debian-and-ubuntu-initramfs-tools)).

## 1.2 — 2026-11-14

**New.**
- After Linux crashed while writing and the Windows driver cleared the AMD bitmap without checking the volume
  (9.5.0 does that; 9.3.3 leaves RAID5 parity unchecked), md now resyncs the volume at the next assembly: `mdmon`
  keeps its own copy of the bitmap's state, in a sector of the volume's reserved area the AMD drivers do not write,
  and `--examine` reports it (patch 25). Tried with the Windows driver 9.5.0-00201 in a VM on RAID1, RAID5 and
  RAID10, and on a RAID1 with the md bitmap (resynced by its bits only); not tried with 9.3.3.

**Fixed.**
- A rebuild or an initialization started by the Windows driver 9.5.0 and finished by `mdmon` no longer leaves that
  driver's flag `0x20000000` on the volume.
- `/etc/mdadm.conf` of the Arch package said `DEVICE partitions`, so `mdadm --assemble --scan` assembled AMD
  containers but not the volumes in them. It now says `DEVICE partitions containers`. Booting was not affected:
  udev assembles the volumes. A changed `/etc/mdadm.conf` is kept by pacman (`.pacnew`): add `containers` by hand.

**Tests.** Stages 41 (a crash, then the AMD bitmap cleared as Windows 9.5 does) and 42 (the flag of Windows 9.5 at the
end of a transform mdmon finishes): 573 checks in 55 stages.

**Packaging.**
- The package version is now the mdadm-amd release (`1.2`; a build between releases `1.1.r<n>`) instead of the
  mdadm version (`4.6.r112.g5542bf40`); `provides=mdadm` still gives the mdadm version. Pacman sees the change as
  a downgrade once: install the new package with `pacman -U`, later releases upgrade as usual.
- `replaces=raidtools` dropped (inherited from the Arch package, meaningless here).
- `md-bitmap-ext-dkms` covers Linux 6.18.57 to 6.18.63 too (the `linux-lts` of Arch and CachyOS), with three more
  bases: 6.18.57, 6.18.61, 6.18.63. Tried on Arch `linux-lts` 6.18.63 in a VM: the md bitmap runs, a crash
  resyncs the dirty chunk only.

## 1.1 — 2026-11-14

**Base.** The patch and the series now apply to upstream mdadm `5542bf40` (mdadm-4.6-112, 12 November 2026) instead
of `cd27b828`. The AMD handler did not change for it: the upstream changes since (`sysfs_read()`, `load_sys()`
return codes, llbitmap in `--detail`/`--examine`, the udev "change" event after a spare is taken) touch nothing it
relies on.

**New.**
- `mdadm --create`, for any metadata, recognises XFS, btrfs, a LUKS volume and an LVM physical volume on a device
  and asks before going on, as it already did for ext2/3/4 and ReiserFS (patch 15 of `mdadm/series/`).
- `--add` to an AMD container refuses a disk that holds one of these too; `--force` wipes it.

**Packaging.**
- `md-bitmap-ext-dkms` covers Linux 7.3.0 to 7.3.4 (was 7.3.1 to 7.3.3). It carries `drivers/md` of 7.3.1 and of
  7.3.4 and builds from the one of the target kernel; a kernel of any other release keeps its own `md_mod`.
  `packaging/dkms/md-bases.sh` tells which stable releases share these files. The DKMS module version is now the
  package version; upgrading the package from 1.0 replaces the module.

**Tests.** Stage 40 (the file systems and volumes above at `--create` and `--add`): 545 checks in 53 stages.

**Known issues.**
- After Linux crashed while writing to a RAID1, RAID10 or RAID5, the Windows driver 9.5.0 clears the AMD
  write-intent bitmap without checking the volume, and 9.3.3 checks mirrors but not RAID5 parity. Start Linux
  first after such a crash, or run `repair` on the volume from Linux
  ([usage.md](docs/usage.md#working-with-the-bios-and-windows)).
- A rebuild started by the Windows driver 9.5.0 and finished by `mdmon` leaves a flag of that driver set on the
  volume (bit `0x20000000` of the volume flags). Data and state are not affected; the driver takes the volume as
  Normal.
- The md bitmap needs the `kernel/` fix on 6.18 and later; a DKMS module is provided only for 7.3.0 to 7.3.4.

**Checked for this release** ([docs/testing.md](docs/testing.md)): the test suite, 545 of 545, on a VM with the
emulated AMD controllers; the upstream test suite as on upstream alone (67 pass, 1 skipped); each patch of the
series builds with gcc and clang without new warnings; the Arch packages on the test machine with kernel 7.3.4
(RAID1 volumes run with the md bitmap); the Windows driver 9.5.0-00201 in a VM.

## 1.0 — 2026-11-13

First release: assembly, `mdmon` and creation of AMD RAIDXpert2 (RAIDCore) Volume, RAID0, RAID1, RAID10, RAID5 and
RAIDABLE volumes; rebuilds onto dedicated and global spares and returning disks; the RAIDABLE → RAID1 migration;
the md write-intent bitmap; booting from a volume (mkinitcpio, initramfs-tools, dracut); upstream mdadm `cd27b828`.
