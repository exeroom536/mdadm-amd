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
| `2026-11-15-rcraid-migrations/` | The same driver and `rcadm -T` on five emulated SATA disks of 8 GiB, migrations that move the data of each element from AllocatedSpace + 0x5000 to + 0x800: **e1** RAID0 2 → 3 disks (`e1mid`, the transform log at 0x7e000; `e1post`), then 3 → 4 (`e1cmid`, `e1cpost`); **e2** RAID5 3 → 4 disks, 2862 → 5724 MiB (`e2mid`, `e2post`); **e3a** RAID0 2 × 1 → RAID10 2 × 2 (`e3amid`, at 3 %; `e3apost`); **e3b** RAID1 → RAID5 of 3 disks (`e3bmid`, the log at 0x12000; `e3bpost`); **e3d** RAID1 1000 → 2000 MB in place (`e3dpost`). Each snapshot is the state of all five disks then. Files as in `2026-11-07-rcraid-migrations/` |
| `2026-11-15-rcraid-grow/` | The same driver and `rcadm`, five emulated SATA disks of 8 GiB: a RAID1 of 1000 MiB on SATA0 + SATA1 made by this mdadm, grown by `rcadm -T -r1 -s 2000` in place: `q9g-b1mid` midway (the transform log at 0x213000, 53 %), `q9g-b` after the AMD driver ended it (1907 MiB). Files as in `2026-11-07-rcraid-migrations/` |
| `2026-11-15-rcraid-chunk/` | The same driver, five emulated SATA disks of 8 GiB, a container of this mdadm on SATA0–3: RAID5 `c5` 3 × 1000 MiB (ID `9283179a3b4f`) and RAID10 `c10` 2 × 2 × 900 MiB (ID `3b6d6ef1985c`), chunk 64 KiB, random data. AMD's own tools cannot change the chunk; a start packet and logs of a chunk change written onto both volumes by a script (`c5` → 128 KiB, `c10` → 256 KiB), carried out by rcraid on both at once: `chunk-mid` at ~35 % / ~30 % (the logs at 0x15f000 and 0x110000), `chunk-post` (SATA0 only) after rcraid ended both. Files as in `2026-11-07-rcraid-migrations/` |
| `2026-11-16-rcraid-chunk-begun/` | The volumes `c5` and `c10` of `2026-11-15-rcraid-chunk/` before either migration, with the same two chunk changes written and their logs at mark 0: `chunk-begun`; `chunk-begun-post` (SATA0 only) after rcraid ended both from 0. Files as in `2026-11-07-rcraid-migrations/` |
| `2026-11-15-rcraid-away/` | The same driver and `rcadm -C`, three emulated SATA disks of 8 GiB: RAID1 `qaa` on SATA0 + SATA1 and RAID1 `qab` on SATA1 + SATA2, 256 MB each; SATA1 and SATA2 went away together and rcraid, on SATA0 alone, recorded `qaa` CRITICAL (written to meanwhile, its element on SATA1 0x30) and `qab` OFFLINE (both elements 0x20); SATA1 and SATA2 keep the packet before (generation 10). `away-sata<N>-lba0-6000.img.xz`: LBA 0…0x5FFF |
| `2026-11-19-rcraid-second-migration/` | The same driver and `rcadm -T`, five emulated SATA disks of 8 GiB: a RAID0 `r0` and a RAID5 `r5` of 3 × 128 MiB, 64 KiB, made by this mdadm, in each sector 32 × (a tag, the sector number in the volume; 8 bytes each), tag 7 in the RAID0 and 9 in the RAID5 (the first 256 MiB); a first migration of each onto four disks by `rcadm -T` (the data to AllocatedSpace + 0x800), then a second onto five: **q20m-first** both after the first migration (metadata only); **q20m-r0s01** the RAID0 4 → 5 midway through AMD's log of the data (the transform log on SATA0 at `0x280`, flags `0x712141`); **q20m-r5s02** the RAID5 4 → 5 midway through it (the region `[0, 0x600)` a stripe at a time, `IOStart 0x200`, `0x512141`); **q20m-done** both ended by rcraid (metadata only). `<snapshot>-sata<N>-lba0-6000.img.xz`: LBA 0…0x5FFF; `<snapshot>-sata<N>-lba0x<A>-4000.img.xz`: 0x4000 sectors from `A`, the start of an extent (RAID0 0x100000; RAID5 0x145000, 0x135000 on SATA3, 0x12b800 on SATA4): its service area (the transform log, the log of the data at + 0x600) and the start of its data |
| `2026-11-20-rcraid-chunk-backwards/` | The same driver, the disks of `q20m-first` above (the RAID0 4 × 1 and the RAID5 1 × 4 of 64 KiB, the data at + 0x800; the RAID5's `UserDataSpace 0x2b000`, AllocatedSpace 0x30000), with the same pattern, and a RAID10 `t10` 2 × 2 of 64 MiB a member made by this mdadm (tag 5, the first 120 MiB): **q21c-pat** that base, NORMAL; **q21c-xs1** the RAID5 64 → 128 KiB begun by this mdadm (backwards, from the end; the data going up to + 0x5000), cut short in its first region and carried on by rcraid, midway (the transform log at `0x28800`, `0x12222`); **q21c-xs2** that one ended by rcraid (metadata only); **q21c-r10b** the RAID10 after chunk changes of this mdadm 64 → 128 → 256 → 64 KiB (the data at + 0x800), the RAID5 at 128 KiB at + 0x5000; **q21c-r10xs1** a RAID10 change 256 → 128 KiB begun by this mdadm, carried on by rcraid, midway (the log at `0x18000`); **q21c-r10s2rc** that one ended by rcraid (metadata only). `<snapshot>-sata<N>-lba0-6000.img.xz`: LBA 0…0x5FFF; `<snapshot>-sata<N>-lba0x100000-9a000.img.xz`: 0x9a000 sectors from 0x100000, the extents of all volumes (the logs and the data) |
| `2026-11-23-rcraid-migration-end/` | The same driver and `rcadm -T`, four emulated SATA disks of 2 GiB, volumes made by this mdadm: the end of a migration rcraid carried out itself, at moments of the window between its transform log going COMPLETED and its final packet. The disks after rcraid ended it, the commit block and the log put back as rcraid wrote them at that moment (read off the images while QEMU wrote them), newer packets of the ring zeros. A RAID0 2 → 3 disks of the largest capacity (`rcadm -T -r0 -s 4800`): **c3-f1** the start packet live and the log COMPLETED (ProtectStart `0x5f7c00`, the old capacity rounded up to a region), 4 ms before the "100 %" packet; **c3-f2** the "100 %" packet (67.29 %, ProtectStart `0x5f7c00`, Flags `0x24`) and the log COMPLETED; **c3-f3** that packet and the log cleared. A RAID5 3 → 4 disks: **r5g-f1** the start packet and the log COMPLETED at the end (`0x8f1000`) on SATA0 and SATA1. `<snapshot>-sata<N>-lba0-6000.img.xz`: LBA 0…0x5FFF; `<snapshot>-sata<N>-lba0x100000-100.img.xz`: 0x100 sectors from 0x100000, the transform log at the start of the extent (no data) |
| `2026-11-23-uninit-stale-member/` | The menu and mdmon of 1.6.1, from `04-r1` above (the RAID5 and the RAID10 on SATA0–3, the RAID1 `7e317001abc2` on NVMe0–1, none initialized): NVMe1 away while mdmon wrote a configuration (SATA3 failed in the RAID10 with `--fail`), then Initialize Disk of a new fifth SATA disk in the menu wrote one: in the RAID1 the menu took NVMe1 out of the second LD copy only and kept it in service in the LD. `c-bios-<disk>-lba0-6000.img.xz`: LBA 0…0x5FFF of NVMe0, NVMe1 and SATA0–4; `c-bios-<disk>-lba0x<LBA>.bin`: the sectors of the transform logs that are not zeros, one each |

The suite uses the snapshots of the emulated board as they are, except that some stages shrink the volumes in
the packet (`amdshrink` in `suite.sh`) where the size does not matter, so that md does not resync tens of GiB.

`SHA256SUMS` lists every file here.
