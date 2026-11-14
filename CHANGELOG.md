# Changes

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
