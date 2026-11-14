# Testing

What was checked, on what, and what was not. Kinds of evidence: **hardware** (the test machine below),
**emulation** (the board's own RAID firmware in QEMU with emulated AMD controllers), **Windows** and **rcraid** (AMD's
own drivers, in a VM on disk images unless said otherwise), **metadata** (dumps of other boards).

## Test machine

MSI MPG X870E EDGE TI WIFI, BIOS 1.A93 (RAIDCoreDxe 9.3.3-00277), Ryzen 7 9800X3D; CachyOS (Arch-based), kernel
7.3; four SATA HDDs and two SATA SSDs. The NVMe system disk is kept by the BIOS as a Legacy disk, so there are no
NVMe arrays on real hardware.

## Distributions

| Distribution | initramfs | Checked |
|---|---|---|
| CachyOS | mkinitcpio | hardware: the Arch package, booting from a volume |
| Arch Linux | mkinitcpio | VM: the package built and installed, a container and a RAID1 created |
| Debian 13 | initramfs-tools | emulation, booting from a volume |
| Ubuntu 24.04 | initramfs-tools | emulation, booting from a volume, AppArmor on; install guide followed as written |
| Ubuntu 26.04 | dracut | emulation, booting from a volume, AppArmor on; install guide followed as written |
| Fedora 45 | dracut | emulation, booting from a volume, SELinux enforcing |
| AlmaLinux 10.2, openSUSE Tumbleweed | dracut | emulation, booting from a volume, SELinux enforcing |
| AlmaLinux 9 | — | builds without warnings; not run |
| openSUSE Leap 15.6 | — | does not build: gcc 7 rejects upstream mdadm code (`platform-intel.h`) |

Every row uses mdadm at commit `cd27b828` with `mdadm/mdadm-amd.patch` as it was on the day of the test (mdadm-amd
1.0); for 1.1 (upstream `5542bf40`) only the CachyOS hardware and the test suites below were run again. In
emulation each system booted from an NVMe RAID1 made by this mdadm, also with a disk missing and with the disk
coming back (rebuilt into its slot), with no SELinux or AppArmor denials; boot loader systemd-boot.

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
  9.3.3 checks the mirrors then, but not RAID5 parity.
- **Linux driver** rcraid (9.3.3-00302 and 9.3.2): takes the arrays made by this mdadm with the data intact; on a
  member failing, missing at start and coming back, it and `mdmon` pick the same spares and placements. A RAIDABLE →
  RAID1 migration started by one and interrupted is finished by the other. Interrupted rebuilds and
  initializations go on from the other one's mark both ways.

## Metadata only

An ASRock X670E RAID0 of two NVMe drives (our dump) and an ASUS X399 RAID10 (public dump, `test-data/`).

## Test suites

- The test suite in [tests/](../tests/README.md), on loop devices with metadata of real disks and of the emulated
  board: 545 checks, all pass on a VM with the emulated AMD controllers (1.1; for 1.0: 530 checks, 504 of them
  also on a plain VM without the controllers).
- The same suite with mdadm and mdmon built with AddressSanitizer and UBSan: no reports. A fuzzer on the metadata
  parser: no crashes. (Both for 1.0.)
- The upstream mdadm test suite: no regressions (1.1: 67 pass, 0 fail, 1 skipped, the same as upstream `5542bf40`
  alone). The upstream CI build matrix; no new compiler warnings on the distributions above and on i686, s390x,
  powerpc and musl (for 1.0; for 1.1 each patch of the series builds with gcc and clang without new warnings).

## Not tested

NVMe arrays on real hardware; booting from a degraded volume on real hardware; the Windows driver 9.3.3-00329; the md bitmap with the AMD drivers on real hardware; the
controller check refusing a disk on real hardware; distributions other than the test machine's on real hardware;
GRUB with shim; openSUSE Leap and RHEL 9; other boards and BIOS versions.

## Not supported

`--grow` and AMD migrations other than RAIDABLE → RAID1 (a volume in the middle of another migration is not
assembled); RAID6, RAID50 and distributed spares (no AMD platform we know of enables them; such volumes are not
assembled); 4Kn disks (AMD has no format for them); creating a volume with `missing` disks (refused, as for IMSM);
a second AMD RAID disk set in one system (all RAID disks of a system share one configuration).
