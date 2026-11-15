# Changes

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
