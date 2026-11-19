# Development

## Repository layout

| Path | What |
|---|---|
| `mdadm/super-amd.c` | the metadata handler |
| `mdadm/mdadm-amd.patch` | the whole change to upstream mdadm (`super-amd.c` and small changes of common code), against mdadm `5542bf40` ([md-raid-utilities/mdadm](https://github.com/md-raid-utilities/mdadm)) |
| `mdadm/series/` | the same change as a series of patches, as it would go upstream ([below](#the-patch-series)) |
| `mdadm/upstream/` | fixes of upstream mdadm on their own, one per patch, against `5542bf40` |
| `packaging/arch/` | Arch Linux: one PKGBUILD for `mdadm-amd` (replaces `mdadm`; udev rule, mkinitcpio hooks) and the optional `md-bitmap-ext-dkms` |
| `packaging/dracut/` | dracut module `90amdraid` |
| `packaging/dkms/` | DKMS sources of `md_mod` with the md bitmap fix, for Linux 6.18.57–6.18.64 and 7.3.0–7.3.5, `install.sh`, which installs them on distributions without the Arch package, and `md-bases.sh`, which tells the stable releases that share these files |
| `kernel/` | the md fix for the write-intent bitmap of external metadata (Intel IMSM too) on kernels 6.18 and later: two patches |
| `kernel/blk-discard/` | a block layer fix: `discard_max_bytes` can be set again after it was set to 0 (kernels from 6.17, 6.12.42 on); for mainline, 7.3.1 and 6.12 |
| `util-linux/` | an optional libblkid prober: `blkid` and udev then see the disks as `amd_raid_member` |
| `tools/` | `amdraid_dump.py`, `amdraid_fix_legacy.py`, `imsm-bitmap-probe.sh` ([usage.md](usage.md#tools)) |
| `tests/` | the test suite: `run.sh`, its stages, fixtures ([tests/README.md](../tests/README.md)) |
| `test-data/` | a public CC0 dump of an X399 RAID10 ([PlaidPiper/x399-raidcore-fixtures](https://github.com/PlaidPiper/x399-raidcore-fixtures)) |


## The patch series

`mdadm/series/` has 48 patches; each builds on its own with gcc and clang without new warnings, and together they
give the tree of `mdadm-amd.patch`.

- **1–34 change common mdadm code**, one change each.
  - 1–5 fix bugs of upstream and apply to it as they are: `Manage_remove()` arguments swapped since 2017; an fd of
    mdmon leaked on every removal md refuses; a faulty device removed by hand that keeps a spare out for good;
    mdmon reading an array it has just freed when a member fails with a spare in the container (found with
    AddressSanitizer); `--create` of a container failing when the bitmap question is answered yes. 2–5 were
    reproduced with Intel IMSM.
  - 6–10, 12, 13, 19, 20 and 21 fix other things that are not AMD-specific (6, 8, 9, 19 and 21 reproduced with
    IMSM): among them an mdmon that is a zombie in the shutdown ramfs no longer taken for running (8), and no
    "has wrong uuid" about the other arrays of a container when one of them is assembled (19); 17 makes
    `--create` recognise XFS, btrfs, LUKS and LVM on a device, as it does ext2/3/4 and ReiserFS.
  - 11, 14–16, 18, 22–24, 31 and 32–34 give metadata handlers what AMD needs and export two helpers; 23 and 24
    let `--grow` change the number of disks and the size of a member array that md still keeps read-only
    (read-auto); 31 lets a format keep a member failure to the member array md failed it in, as AMD does.
  - 25–30 let external metadata run a reshape that moves the data, as AMD's migrations do: md gets the new data
    offsets the metadata records (also when the reshape goes on after a restart), the metadata handler keeps md
    behind its own log (RAID5 and RAID10), a reshape stopped before it moved anything goes on from its start, and
    the arrays of a container left midway go on one after another.
- **35–47 add the handler step by step**: reading and assembly, mdmon, rebuilds, creation, `--add` and volume
  updates, dedicated spares, the firmware's checks, RAIDABLE → RAID1, growing in place and RAID0 → RAID10, the md
  write-intent bitmap, more disks for a RAID5 and RAID1 → RAID5, more disks for a RAID0, the stripe size. Each stage builds
  on its own and refuses what it does not support yet before writing anything.
- **48** documents the format in `mdadm(8)` and `mdadm.conf(5)`.

`mdadm/upstream/` has the upstream fixes as stand-alone patches: `sha1.c` computing a wrong hash on big-endian
hosts and the 0.90 homehost match that depends on it, the mdmon use-after-free (patch 4 of the series), and the
bitmap question for containers (patch 5).

## Building and testing

Build as in [install.md](install.md#building-mdadm-from-source). With the patch applied, upstream's own test suite
runs as usual (`./test`); it needs devices of 1 GiB or more.

The test suite of this project is in [tests/](../tests/README.md): 791 checks on loop devices, with the metadata of
real disks and of the emulated board as fixtures; `sudo tests/run.sh /path/to/upstream-mdadm` runs it in about 80
minutes. Metadata dumps from other boards help most —
`tools/amdraid_dump.py <disk> --brief --ring`, or the first 12 MiB of a member
(`dd if=/dev/sdX of=member.img bs=512 count=$((0x6000))`).
