# Fixtures

Metadata of AMD RAIDXpert2 ("RAIDCore") disks that the test suite builds its disk images from. Each image is
sparse: the metadata at its own LBAs, the rest holes. `mkimages.sh` builds the six base images; the stages build
the others themselves (`suite.sh`). The public X399 RAID10 dump is not repeated here: the suite takes it from
`test-data/x399-raid10-plaidpiper/` of the repository (CC0).

All of it was captured read-only (`dd iflag=direct`) or from emulator disk images. Serial numbers and DeviceIDs are
as the disks had them.

**What was zeroed.** Only metadata is published. Sectors the AMD firmware and drivers do not use still held old
data of the disks, and are zeroed here:

- LBA `0x4F80`…`0x4FFF` (below the RAIDCore label) where it was not the BIOS menu's `0xAF` fill: 29 and 102
  sectors on the ASRock disks, 9 on the PC disk WX61A68KYK45;
- the service areas (AllocatedSpace … user data, 0x5000 sectors) of five elements in
  `2026-11-04-rebuild-reboot` that were full of old data: only a valid transform log sector (by its checksum) was
  kept; AMD uses +0 (transform log), +2 (scan log), +0x80 (AMD bitmap), +0x100…+0x600 and +0x600 of that area,
  nothing else.

Nothing the suite reads changed: the suite passes on these files as on the original dumps. The same rules
everywhere: LBA 0 (MBR) and LBA `0x5000`…`0x5FFF` (label, commit block, ring of configuration packets) are kept as
they were.

## Real hardware

| Directory | What | How |
|---|---|---|
| `2026-10-28-asrock-x670e-raid0/` | ASRock X670E Pro RS, BIOS 3.50 (09/18/2025), `AMD_RAID=0x0C` (NVMe RAID). RAID0 "prod" on two NVMe SSDs of 1 TB (`nvme1n1`, `nvme2n1`; 1953525168 sectors), chunk 256 KiB, capacity 3904856064 sectors, data at LBA 0x105000. Element 0 = `nvme2n1`. | 2026-10-28, live Linux, nothing mounted. `nvmeXn1-lba0-6000.img.xz`: LBA 0…0x5FFF; `nvmeXn1-lba100000-105000.img.xz`: the volume's service area 0x100000…0x104FFF (only 0x100002 on `nvme2n1` is not zero: the background check log). Past the volume to the end of the disk: zeroes (not shipped). |
| `2026-11-02-msi-x870e-hdd/` | MSI MPG X870E EDGE TI WIFI, BIOS 1.A93 (RAIDCoreDxe 9.3.3-00277), four HDDs 1 TB (WX41A685FR98, WES1KE09, JR10044M28WJGM, WX61A68KYK45; 1953525168 sectors) and the NVMe system disk XPG MARS 980 BLADE, which the BIOS keeps as a Legacy disk. In the BIOS menu: Delete Array, RAID1, RAID10, RAID5, RAID0, Volume on the HDDs; the menu broke the Legacy record of XPG on the way (a firmware bug the suite's stage 8 and 23 repair). Configuration 19. | 2026-11-02, back in AHCI mode, Linux, LBA 0…0x5FFF of each HDD. |
| `2026-11-03-r5-after-reboot/` | The same PC, a RAID5 `hddr5` of the four HDDs made by this mdadm, rebooted at 90.2 % of its initialization (transform log mark 0x0b461200) without a clean shutdown: the AMD bitmap is all set. | 2026-11-03, LBA 0…0x5FFF of each HDD and 10 MiB at the AllocatedSpace of the `hddr5` elements (`*-hddr5-alloc-<LBA>-5000.img.xz`). |
| `2026-11-04-rebuild-reboot/` | The same PC with several volumes on the HDDs (made in the BIOS menu and by this mdadm), rebooted at 81 % of a rebuild of WES1KE09 in "Array 2" (log mark 208001664), while a RAID5 of the BIOS menu had not started its initialization. | 2026-11-04, `hdd-service-areas.tar.xz`: `grab/<serial>.meta` (LBA 0…0x5FFF) and `grab/<serial>.<LBA>` (10 MiB at the AllocatedSpace of each element). |

## Emulated board

The board's own RAID firmware, RAIDCoreDxe 9.3.3-00277 from MSI X870E BIOS 1.A93, in QEMU 11.1 with OVMF, with
emulated AMD controllers (PCI IDs changed: SATA AHCI `1022:43bd`, NVMe `1022:b000`) and the EFI variable
`AMD_RAID` set; disks are sparse 64 GiB images (134217728 sectors). The arrays were made in the RAIDXpert2 menu
of the firmware (HII forms in OVMF) or by this mdadm in a Linux guest of the same VM, and each archive is a
snapshot after a step. Unpack: `tar -xSJf <archive>`.

| Archive | State |
|---|---|
| `2026-10-31-qemu-raidcore-msi1a93/04-r1.tar.xz` | menu: Initialize of 4 SATA + 2 NVMe, RAID5 (4 SATA, 12000 MB, 64K), RAID10 (4 SATA, 12000 MB, 128K), RAID1 (2 NVMe, 12000 MB, 256K); not initialized yet |
| `…/08-md-init-late.tar.xz` | from 04: this mdadm initialized RAID1 and RAID10 with the fourth SATA disk arriving last; configuration 21 on all six; the firmware rewrote nothing at the next boot |
| `…/11-spare-assigned.tar.xz` | RAID10 critical after a member failed under mdmon, a fifth SATA disk initialized in the menu and assigned as global hot spare (configuration 4: the menu restarts the numbering) |
| `…/12-md-rebuild.tar.xz` | from 11: this mdadm rebuilt RAID10 onto the global spare (configuration 6); accepted by the firmware at boot |
| `…/13-fw-restore-boot.tar.xz` | from 11: the rebuild stopped at 44 % (transform log `ProtectStart` 10255360), then a boot into the firmware, which wrote configuration 7 itself (PD records without DeviceID, a firmware bug) |
| `…/14-md-resume.tar.xz` | from 13: this mdadm restored the PD records from the previous packet of the ring and finished the rebuild from its mark (configuration 8) |
| `2026-11-06-qemu-spares-raidable/03-dedspare.tar.xz` | (QEMU without KVM) menu: Initialize sata0–3, RAID1 16000 MB on sata0+sata1 (LD `840a7c70b562`), sata2 its dedicated hot spare; sata4 and NVMe Legacy. LBA 0…0x5FFF of each disk (`<disk>.bin`) |
| `…/04-raidable.tar.xz` | from 03: RAIDABLE on sata3 (LD `88a5d4fa2af7`, type `0x1BFB`) |
| `…/07-ded-r1b.tar.xz` | from 04: sata4 initialized, a second RAID1 8000 MB on sata0+sata1 (LD `8a2c51b386dd`), sata4 its dedicated spare |
| `2026-11-07-rcraid-migrations/` | AMD's Linux driver rcraid 9.3.3-00302 with `rcadm` 9.3.0-00283 on five emulated SATA disks: **m1** RAIDABLE → RAID1 (`rcadm -T -r1`): before (`m1-pre`), at ~34 % (`m1-mid`), after (`m1-post`); **m2** RAID1 grown 2 → 4 GB: `m2-mid`, `m2-post`. `*-lba0-6000.img.xz`: LBA 0…0x5FFF; `*-lba0x<N>.bin`: the transform log sector at the start of an element (non-zero ones only). Snapshots: QEMU paused, reflink copy, resumed |

The suite uses the snapshots of the emulated board as they are, except that some stages shrink the volumes in
the packet (`amdshrink` in `suite.sh`) where the size does not matter, so that md does not resync tens of GiB.

`SHA256SUMS` lists every file here.
