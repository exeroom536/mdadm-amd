# Testing

What was checked, on what, and what was not. Kinds of evidence: **hardware** (the test machine below),
**emulation** (the board's own RAID firmware in QEMU with emulated AMD controllers), **Windows** and **rcraid** (AMD's
own drivers, in a VM on disk images unless said otherwise), **metadata** (dumps of other boards).

## Test machine

MSI MPG X870E EDGE TI WIFI, BIOS 1.A93 (RAIDCoreDxe 9.3.3-00277), Ryzen 7 9800X3D; CachyOS (Arch-based), kernel
7.3; four SATA HDDs and two SATA SSDs. The NVMe system disk is kept by the BIOS as a Legacy disk, so there are no
NVMe arrays on real hardware.

## Distributions

| Distribution | Kernel | initramfs | Checked |
|---|---|---|---|
| CachyOS | 7.3 | mkinitcpio | hardware: the Arch package, booting from a volume |
| Arch Linux | 7.3.4 | mkinitcpio | emulation: install guide as written, booting from a volume |
| Debian 13 | 6.12 | initramfs-tools | emulation: install guide as written, booting from a volume, AppArmor on |
| Ubuntu 24.04 | 6.8 | initramfs-tools | emulation: install guide as written, booting from a volume, AppArmor on |
| Ubuntu 26.04 | 7.0 | dracut | emulation: install guide as written, booting from a volume, AppArmor on |
| Fedora 45 | 7.3.3 | dracut | emulation: install guide as written, booting from a volume, SELinux enforcing |
| AlmaLinux 9.8 and 10.2 | 5.14, 6.12 | dracut | emulation: install guide as written, booting from a volume, SELinux enforcing |
| openSUSE Tumbleweed, Leap 16.1 | 7.3.3, 6.12 | dracut | emulation: install guide as written, booting from a volume, SELinux enforcing |
| Manjaro, EndeavourOS | — | mkinitcpio, dracut | container: the Arch package built and installed; a container and a RAID1 made on loop devices and assembled again. Not booted from a volume |
| Linux Mint 22.3 | — | initramfs-tools | container: steps 1 to 3 for Debian and Ubuntu as written; volumes on loop devices as above. Not booted from a volume |
| Gentoo, NixOS, Void Linux (glibc and musl), Alpine Linux 3.24 | — | — | container: mdadm builds without warnings (Alpine needs `linux-headers` as well); not run. Their initramfs tools (genkernel, ugrd, NixOS stage 1, mkinitfs) have no integration here; Gentoo and Void can use dracut, untried |
| openSUSE Leap 15.6 | — | — | does not build: gcc 7 rejects upstream mdadm code (`platform-intel.h`) |

For 1.3 (upstream `5542bf40`), each emulation row started from the distribution's cloud image: the commands of
[install.md](install.md) as written, on the running system (the boot steps in a chroot of the system copied onto
the volume); then booting from an NVMe RAID1 made by this mdadm, with a second RAID1 of two SATA disks in the same
container. Each system rebooted without a resync; booted with an NVMe disk missing (the root volume started
degraded) and with a SATA disk missing (the other volume started degraded by mdadm's last-resort timer, 30 to 65
seconds after boot); each disk coming back was rebuilt into its slot, and `md` check found the volumes clean
(once, on Leap 16.1, a check right after the rebuild of the root counted 128 sectors; two more rebuilds and every
later check were clean). No SELinux or AppArmor denials for `mdadm` or `mdmon`. The Uninstall steps ran as
written on the same systems, with the root still on the volume; Ubuntu 26.04 hung then (see install.md). Boot
loader systemd-boot; root file system ext4. Volume (`md-linear`) ran on Arch, Ubuntu 26.04, Fedora, AlmaLinux 9 and
10 and openSUSE; Debian 13 and Ubuntu 24.04 have no `md-linear`. The md bitmap ran on the kernels before 6.18
(AlmaLinux 9 and 10, Debian 13, Ubuntu 24.04, Leap 16.1); on the 7.x kernels `mdadm` ran the volume without it, as
[install.md](install.md#the-md-bitmap) says. The container rows used the same 1.3 sources: podman with loop devices,
docker for the builds.

The optional md bitmap module outside Arch (`packaging/dkms/install.sh`), in emulation on openSUSE Tumbleweed
(kernel 7.3.3, DKMS 3.3.0, SELinux enforcing) with the root on an NVMe RAID1 volume: DKMS built `md_mod` from the
7.3.1 base, the initramfs took it, and the system booted from the volume with it. A RAID1 of two 32 GiB SATA disks
was given the bitmap (`consistency_policy` bitmap) and the VM was reset in the middle of a write: 18 of 504 bits
set, resync in 5.5 seconds (165 seconds on the same volume before the module), `md` check clean, the data intact.
`rpm -V` found the kernel package whole with the module in and after `--remove`, which brought the kernel's own
`md_mod` back. With `module.sig_enforce=1` the kernel rejected the module, signed by the DKMS key, and no volume
started. No SELinux denials. The tree the script lays out is the same, file for file, as that of the Arch package
(built in a container). Fedora 45 (7.3.3) and Ubuntu 26.04 (7.0) build md into the kernel; there the script stops.

## Hardware

- 1.1, kernel 7.3.4: `md-bitmap-ext-dkms` built from its 7.3.4 base; RAID1 volumes on the SSDs and on the HDDs
  run with the md bitmap.
- Volumes made in the BIOS menu (Volume, RAID0, RAID1, RAID10, RAID5) read by this mdadm; RAID0, RAID1, RAID10 and
  RAID5 run under it.
- Volumes made by this mdadm (Volume, RAID0, RAID1, RAID10, RAID5) shown as Normal by the BIOS menu; Linux boots
  from a RAID1 and from a RAID5 volume (the RAID5 one also while still initializing).
- A member failed out of all its volumes and added back: rebuilt into its slots, `md` check clean. Reboots in the
  middle of a rebuild and of an initialization: both resumed from their mark, also with the root on the rebuilding
  volume. Shutdown with the root on a volume leaves it clean, also after an update replaced the running `mdmon`.
- A dedicated spare set by this mdadm: a member of a RAID1 and of a RAID5 failed, the RAID1 rebuilt onto its spare,
  the failed disk recorded offline as the AMD driver records it; added back, the RAID5 rebuilt, `md` check clean.
- A RAIDABLE volume made in the BIOS menu grown into a RAID1 onto a global spare, with a reboot in the middle (the
  migration went on from its mark); the BIOS menu then showed a RAID1, Normal; a full `md` check of the mirror,
  clean.
- The md bitmap with the md fix (through the DKMS package): RAID1 on HDDs and on SSDs, RAID10 and RAID5. A hard
  reset while they were written: one bit set on each, the BIOS wrote nothing at boot, resync in one to seven
  seconds instead of hours; a mirror that differed in the chunk being written was made whole, and a MiB spoiled on
  purpose in a clean chunk was left alone. Without the fix `mdadm` says so and runs the volumes without a bitmap.
  The BIOS menu shows these volumes Normal and does not touch their bitmap area.
- SATA hot plug: a disk removed while running left its RAID1 and the container at once and was recorded as failed;
  added back, the mirror rebuilt onto it, `md` check clean.
- TRIM policy; repair of the Legacy record of the NVMe system disk with the script.
- Windows 10 LTSC installed on a RAID1 of two SATA SSDs made by this mdadm (the AMD driver 9.3.3.218 added to
  the image, boot files on the volume's own ESP): it boots from the volume. Windows → Linux → Windows: after
  Windows, this mdadm assembled the volume without a resync, `md` check clean, NTFS readable; Windows booted again
  after `mdmon` had written the configuration.
- Dual boot from two volumes on the same two SSDs: Linux with its root on one RAID1 made by this mdadm, Windows
  on another. Linux → Windows → Linux → Windows: every Linux boot without a resync, `md` check of both volumes
  clean; a 2 GiB file Windows wrote had the same SHA-256 under Linux and again under Windows.
- AMD's Windows driver (9.3.3, from WinPE) and Linux driver (rcraid 9.3.3-00302) read and wrote a RAID0 made and a
  RAID1 grown by this mdadm. Speed against them on the same volumes: [benchmark.md](benchmark.md).
- 1.4: `--detail-platform` lists the board's controllers and disks. A RAID1 of two HDDs grown in place by this
  mdadm, 50 to 100 GiB: the BIOS menu shows it Normal at the new size, and the installed Windows (driver
  9.3.3.218) sees a 100 GiB disk and reads the same data. Grown again to 200 GiB and stopped at 62 %, then
  Windows booted: the Windows driver finished the migration from that mark; Linux then assembled the volume
  without a resync, `md` check clean, the data the same.
- 1.5, on two HDDs and two SATA SSDs, volumes of 4 to 8 GiB per disk with random data at their start and end: the
  stripe size of a RAID5 of 3 disks 64 → 128 KiB and of a RAID10 of 4 disks 64 → 256 KiB; a RAID5 of 3 → 4 disks
  (a dedicated spare on a disk of the container); a RAID1 of two SSDs → a RAID5 of 3; a RAID0 of 2 → 3 disks (a
  global spare). Each time `md` check clean and the data the same; the BIOS menu shows the volume Normal at its
  new stripe size, size or level, and Windows (driver 9.3.3.218) reads the same data. A RAID5 stripe size change,
  a RAID5 of 3 → 4 and a RAID0 of 2 → 3, each stopped about halfway by this mdadm: the BIOS menu shows
  "Transform", Windows reads the volume right and finishes the migration; Linux then finds it Normal, the data the
  same. A RAID5 stripe size change and a RAID0 of 2 → 3 stopped before md moved anything went on from the start at
  the next assembly. A disk one configuration behind, which md kept in sync, got the current one from `mdmon`
  within seconds, and the next migration of its volume went through. The reshape runs under systemd
  (`mdadm-grow-continue@`) on this distribution.
- 1.5 fixes, kernel 7.3.5: an SSD failed in md in a RAID5 (HDD + two SSDs) that shares it with a RAID0 (two SSDs
  + HDD): `mdmon` failed it in the RAID5 alone; the RAID0 stayed Normal with it and the disk online, also after
  the container was stopped and assembled again. The BIOS menu shows the RAID5 Critical with all three disks
  online and the RAID0 Normal; Windows (driver 9.3.3.218, booted from its RAID1 volume) reads the same data from
  both and leaves the RAID5 as it was. The RAID5 then rebuilt onto a dedicated spare (an HDD of the container):
  Normal, `md` check clean, the data the same. Linux booted twice from its RAID1 volume with this release (kernel
  7.3.1): `mdmon` took over from the initramfs, no resync, shutdown without waiting for `mdmon`, `md` check of the
  Linux and the Windows volume clean.
- 1.5.1, kernel 7.3.5, a RAID10 of two HDDs and two SATA SSDs (1 GiB per disk) with each sector holding its own
  number, stripe size 64 → 128 KiB: before the fix such a volume stopped with `mdadm -S` at 31 % came back at 64 %, a
  third of it in the old layout. With 1.5.1: a second migration manager forced on the running volume (the first
  one killed, udev started another) went on from the AMD log, the data right; five `mdadm -S` at 9 to 13 % - the
  volume never ran again, after assembly md went on from where it was, every sector right, `md` check clean. Stopped
  at 31 %, assembled (md went on at 32 %), stopped again at 60 %: Windows (driver 9.3.3.218) read the volume right
  and finished the change; Linux then found it at 128 KiB, every sector right, `md` check clean.

## Emulation

The board's RAIDCoreDxe in QEMU with emulated AMD SATA and NVMe controllers:

- arrays made in its menu and by this mdadm (RAID0, RAID1, RAID10, RAID5), Linux booting from an NVMe RAID1 (also
  degraded), rebuilds onto a global spare, the controller check;
- volumes with an md bitmap shown Normal, the menu and the firmware at boot leaving the bitmap area alone;
- dedicated spares made in the menu: `mdmon` rebuilt each RAID1 onto its own spare, the menu then showed the
  volumes Normal; spare roles set by this mdadm are shown by the menu as such;
- volumes of up to 12 disks on two controllers accepted by the menu and the Windows driver;
- with the root on a RAID1, the shutdown hook unmounted the root and stopped the volume 8 times of 8, also after an
  update had replaced the running `mdmon`; a reboot in the middle of the root's rebuild went on from its mark.

## AMD drivers

- **Windows driver** 9.3.3 (RAIDXpert2): takes Volume, RAID0, RAID1, RAID10 and RAID5 arrays and a RAIDABLE made by
  this mdadm with the data intact; Volume, RAID10 and RAID5 the other way round too; members that come back after
  Windows ran without them. Initialization, rebuild and the RAIDABLE → RAID1 migration go on from the other one's
  mark both ways. Volumes with an md bitmap: the driver leaves its area alone; after Windows wrote a volume, `mdmon`
  does not trust the md bits.
- **Windows driver** 9.5.0-00201 (in a VM): takes RAID0, RAID1, RAID10 and RAID5 volumes made by this mdadm with the
  data intact, and the other way round (a RAID5 it made, data it wrote); a rebuild it started is finished by
  `mdmon`; a member that fell behind during its rebuild is not taken back. After Linux crashed while writing, it
  clears the AMD bitmap without checking the volume ([usage.md](usage.md#working-with-the-bios-and-windows));
  9.3.3 starts a check of the mirrors then, but makes them agree only near the start of the volume, and does not
  check RAID5 parity. 1.2: after such a crash and 9.5, Linux resyncs the volumes
  (RAID1, RAID5, RAID10; a RAID1 with the md bitmap by its bits) and `md` check finds them clean; a rebuild and an
  initialization 9.5 started and `mdmon` finished leave no flag of 9.5, and its next check runs to the end.
- **Windows driver** 9.3.3.329 (WHQL, March 2026; in a VM, against 1.3): volumes made by this mdadm (RAID0, RAID1,
  RAID5, RAID10, RAID1 with an md bitmap) are normal in Windows and read the same data both ways; a RAID5 made by
  `rcadm` is assembled by this mdadm. A rebuild or an initialization started by either side and finished by the
  other, and a Windows check (Verify) cut short, end as normal on both sides with the same data, `md` check clean.
  Where 9.3.3.218 and 9.5 differ, 9.3.3.329 does as 9.3.3.218: no flag of its own on the volume, and after a Linux
  crash it starts its check of the mirrors, which leaves them unchecked past the start of the volume; `mdmon`
  resyncs such volumes at the next assembly. 1.4, with 9.3.3.329 and 9.3.3.218: a rebuild target that lost the
  end of its rebuild, rebuilt again by `mdmon`: Windows boots after Linux, its volumes normal, the data the same.
- **Windows drivers** 9.3.3.329 and 9.5 (in a VM) and the 1.5 migrations of this mdadm: a RAID5 of 3 → 4, a
  RAID1 of two → a RAID5 of 3, a RAID0 of 2 → 3, the stripe size of a RAID5 and of a RAID10. Finished, the
  volume is normal in Windows at its new size, level and stripe size, with the same data; stopped about halfway,
  Windows reads it right and finishes the migration, and Linux then assembles it without a resync, `md` check
  clean, the data the same. Reading a RAID10 while Windows finished its stripe size change stalled the volume
  with 9.3.3.218, 9.3.3.329 and 9.5 alike (disks slowed down in the VM); after a hard power-off, mdadm went on
  from the mark Windows had written and finished, the data the same.
- **Linux driver** rcraid (9.3.3-00302 and 9.3.2): takes the arrays made by this mdadm with the data intact; on a
  member failing, missing at start and coming back, it and `mdmon` pick the same spares and placements. A RAIDABLE →
  RAID1 migration started by one and interrupted is finished by the other. Interrupted rebuilds and
  initializations go on from the other one's mark both ways. 1.4: volumes this mdadm grew in place (RAID1, RAID5,
  RAID10) or made a RAID10 from a RAID0 are normal under it with the data intact; such a migration stopped midway
  goes on under the other, both ways; for the same RAID1 `rcadm -T` writes the records `mdmon` writes. Volumes its
  migrations gave more disks (RAID0, RAID5, RAID1 → RAID5) are assembled by this mdadm and read the same data.
  1.5: the same migrations made by this mdadm (more disks for a RAID0 or RAID5, RAID1 → RAID5) and its stripe size
  changes (RAID5, RAID10) write the records `rcadm -T` writes; stopped midway or before the first region, they are
  finished by the driver, and the driver's own ones in the middle by `mdmon`, the data the same both ways; the
  driver takes a stripe size change, which its tools do not offer, through to the end too. Two migrations the
  driver left in one container are finished by mdadm one after the other. A volume the driver recorded offline,
  whose disks went away together and came back, is taken back by mdadm without a rebuild and is normal under the
  driver again.

## Metadata only

An ASRock X670E RAID0 of two NVMe drives (our dump) and an ASUS X399 RAID10 (public dump, `test-data/`).

## Test suites

- The test suite in [tests/](../tests/README.md), on loop devices with metadata of real disks and of the emulated
  board: 797 checks, all pass on a VM with the emulated AMD controllers (1.5.1; 791 for 1.5, 639 for 1.4, 586 for 1.3, 573 for 1.2, 545 for
  1.1; for 1.0: 530 checks, 504 of them also on a plain VM without the controllers).
- The same suite with mdadm and mdmon built with AddressSanitizer and UBSan: no reports. A fuzzer on the metadata
  parser: no crashes. (Both for 1.0.)
- The upstream mdadm test suite: no regressions (1.5 and 1.1: 67 pass, 0 fail, 1 skipped, the same as upstream
  `5542bf40` alone). The upstream CI build matrix; no new compiler warnings on the distributions above and on i686, s390x,
  powerpc and musl (for 1.0; for 1.1 to 1.5.1 each patch of the series builds with gcc and clang without new
  warnings).

## Not tested

NVMe arrays on real hardware; booting with a disk missing on real hardware (the root volume or another volume
started degraded); the md bitmap with the AMD drivers on real hardware; the
controller check refusing a disk on real hardware; distributions other than the test machine's on real hardware;
GRUB with shim; root file systems other than ext4 on a volume; booting from a volume on Manjaro, EndeavourOS, Linux
Mint and the distributions checked by build only; RHEL itself; the md bitmap module under Secure Boot (with the
DKMS key enrolled) and its rebuild by DKMS on a kernel update outside Arch; growing a RAID5 or RAID10 in place and
RAID0 → RAID10 on real hardware, with the Windows driver or the BIOS menu (a RAID1 was, see Hardware); a RAID1 →
RAID5 or a RAID10 stripe size change stopped midway and finished by Windows, and migrations with the Windows
driver 9.5 or 9.3.3.329, on real hardware (in a VM they were); reading a RAID10 on real disks while Windows
finishes its stripe size change; two migrations left in one container, and a volume the AMD driver recorded offline taken back,
on real hardware; a migration of the volume that holds the root file system (going on from the initramfs);
a disk that does not take the transform log (a write error on that sector; in emulation and with the Windows
drivers in a VM it was), and a disk that goes away or fails in every volume it serves with this release, on real
hardware (it needs a disk unplugged; SATA hot plug was tried with an earlier release, see Hardware);
other boards and BIOS versions.

## Not supported

`--grow` other than RAIDABLE → RAID1, growing a RAID1, RAID5 or RAID10 in place, RAID0 → RAID10, more disks for a
RAID0 or RAID5, RAID1 → RAID5 and the stripe size of a RAID5 or RAID10; a second such migration of a volume whose
data a migration already moved (refused: AMD needs its log of the data for it); RAID6, RAID50 and distributed spares (no AMD platform we know of enables them; such volumes are not
assembled); 4Kn disks (AMD has no format for them); creating a volume with `missing` disks (refused, as for IMSM);
a second AMD RAID disk set in one system (all RAID disks of a system share one configuration).
