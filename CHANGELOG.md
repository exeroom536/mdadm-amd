# Changes

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
