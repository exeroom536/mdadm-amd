# Speed: md (this mdadm) and the AMD RAID drivers on the same volumes

The same two AMD RAIDXpert2 volumes, on the same disks, measured three ways:

- **md** — Linux md, the volumes assembled by this mdadm (`metadata=amd`);
- **rcraid Linux** — AMD's RAID driver for Linux, 9.3.3-00302 (the newest public build, from Lenovo's
  RHEL 10.1 driver package), built for this kernel, with NVMe handling taken out so that it could not touch
  the system disk;
- **Windows** — AMD's RAID driver for Windows, `rcraid.sys` 9.3.3.218 (MSI's package for this board),
  loaded with `drvload` in a Windows 10 1809 setup environment (WinPE).

All three run the same jobs on the same regions of the volumes. Measured on 08.11.2026.

## Setup

- MSI MPG X870E EDGE TI WIFI, BIOS 1.A93 (RAIDCoreDxe 9.3.3-00277), Ryzen 7 9800X3D, SATA mode RAID;
  CachyOS, kernel 7.3.
- Four 2.5" SATA HDDs of about 1 TB (two HGST HTS541010B7E610, one HGST HTS721010A9E630, one Seagate
  ST1000LM035), 84–142 MB/s each at the start of the disk.
- **RAID1** of two disks (made as a RAIDABLE volume in the BIOS menu and grown into a RAID1 by this mdadm) and
  **RAID0** of the other two (made by this mdadm, 64 KiB stripe). Both are AMD volumes: the firmware offers both as
  disks (UEFI Shell), and both AMD drivers take them.

## Method

- **Linux:** `fio --direct=1 --ioengine=libaio --time_based --runtime=30 --ramp_time=3`.
- **Windows:** `diskspd -d30 -W3 -Sh -t1` on the raw disk of the volume. The DiskSpd figures are converted from
  MiB/s to MB/s.
- **Jobs:**
  - sequential read 1 MiB QD8 and 128 KiB QD32;
  - random read 4 KiB QD1 and QD32;
  - sequential write 1 MiB QD8;
  - random write 4 KiB QD32.
- **Separate regions for reads and writes:**
  - reads use only the first 40 GB of each volume. That region was rewritten sequentially before the runs, and
    nothing wrote to it afterwards;
  - sequential writes go to 100–140 GB, random writes to 200–240 GB.

  This matters on these disks. After random writes to a region (one of the disks is SMR, and the others have
  caches of their own), sequential reads of that same region were twice as slow as after a sequential rewrite:
  RAID0 under md read at 109 MB/s instead of 233. A first run that let the jobs overlap showed the AMD drivers
  "reading at half speed". That was the state of the disks, not the drivers, and those numbers were dropped.
- **Order of the runs:**
  1. md;
  2. rcraid Linux;
  3. rcraid Linux without "Read Cache";
  4. md again — matched the first md run within 1 %;
  5. Windows;
  6. Windows without "Read Cache".

  The AMD volume cache policy ("Read Cache", on by default) was switched off and back on with this mdadm
  (`--update-subarray=N --update=no-read-cache` / `read-cache`).

## Results

MB/s for sequential jobs, IOPS for random ones.

| Volume | Job | md | rcraid Linux | rcraid Linux, no read cache | Windows | Windows, no read cache |
|---|---|---:|---:|---:|---:|---:|
| RAID1 | seq read 1M QD8 | 143 | 171 | 217 | 146 | 191 |
| RAID1 | seq read 128K QD32 | 143 | 175 | 222 | 141 | 155 |
| RAID1 | rand read 4K QD1 | 112 | 108 | 108 | 100 | 104 |
| RAID1 | rand read 4K QD32 | 355 | 308 | 319 | 355 | 366 |
| RAID1 | seq write 1M QD8 | 116 | 116 | 116 | 116 | 116 |
| RAID1 | rand write 4K QD32 | 201 | 202 | 201 | 203 | 205 |
| RAID0 | seq read 1M QD8 | 232 | 231 | 230 | 230 | 231 |
| RAID0 | seq read 128K QD32 | 232 | 230 | 230 | 230 | 231 |
| RAID0 | rand read 4K QD1 | 100 | 98 | 100 | 94 | 97 |
| RAID0 | rand read 4K QD32 | 385 | 302 | 311 | 381 | 388 |
| RAID0 | seq write 1M QD8 | 224 | 227 | 225 | 229 | 225 |
| RAID0 | rand write 4K QD32 | 124 | 117 | 116 | 123 | 123 |

## What it shows

- **Writes:** the same everywhere; the disks are the limit.
- **RAID0:** the same, except random reads at QD32 under AMD's Linux driver, about 20 % lower. The Windows driver
  is level with md there. See [Why the numbers differ](#why-the-numbers-differ).
- **RAID1, one sequential stream:** both AMD drivers read it from both mirrors at once — up to 217 MB/s
  (Linux) and 191 MB/s (Windows) with "Read Cache" off. md's raid1 serves a single stream from one disk:
  143 MB/s. With "Read Cache" on, the AMD drivers lose part of that gain. With two streams md reads from both
  mirrors: 263 MB/s (measured later, see below).
- **Random reads on RAID1:** md and the Windows driver are level, AMD's Linux driver is about 10 % lower.

## Limits

One machine, HDDs only, two-disk volumes. Not measured:

- NVMe and SSD arrays;
- RAID5 and RAID10;
- several parallel streams;
- an installed Windows: only the driver in WinPE here (an installed Windows was measured later on the SSDs, below).

The AMD Linux driver was loaded only for this measurement. It is not needed with this mdadm, and its build
writes a wrong controller serial number (`102285900000` in place of `859010220000`). The BIOS and the Windows
driver then take the disks for another controller's. This mdadm now writes the right one back.

# SSDs: the same comparison on two SATA SSDs

Measured on 09.11.2026, on the same machine.

## Setup

- Two ADATA SU650 240 GB SATA SSDs (DRAM-less, TLC with an SLC cache, TRIM). The four HDDs stayed connected.
- **RAID1** of 20 GiB made by this mdadm, with an md write-intent bitmap (`--bitmap=internal`; the AMD drivers
  ignore it), and **RAID0** of 2 × 40 GiB, 64 KiB stripe, made by this mdadm. Both are in the same AMD container
  as the HDD volumes.
- **md** and **rcraid Linux:** as above, on the host.
- **Windows:** Windows 11 with `rcraid.sys` 9.3.3.218 in a KVM virtual machine (4 vCPUs, 4 GiB) that owns
  the board's SATA controller (VFIO passthrough). The NVMe system disk stays with the host and is never seen by
  the AMD driver. To tell the cost of the VM from the cost of the driver, md was measured in the same kind of
  VM too (Debian 13, kernel 6.12, the same controller passed through).
- **Windows (bare):** on 10.11, the same driver on the bare machine: WinPE of Windows 10 1809 booted from
  the KVM over IP's USB drive, the NVMe system disk kept offline (SAN policy) before the driver was loaded,
  DiskSpd on the raw volumes with the same jobs, after TRIM of the write regions. The configuration the
  driver writes when it starts was put back afterwards.

## Method

- The jobs are the ones above. Reads use 0–8 GiB of each volume, rewritten sequentially beforehand. Sequential
  writes go to 10–14 GiB and random writes to 15–19 GiB.
- These SSDs slow down sharply once their SLC cache is used up. After a few runs in a row, sequential writes to
  the RAID1 fell to 25 MB/s under md, and the Windows RAID0 to 55 MB/s. So the host runs were repeated as one
  clean round: TRIM of the write regions and 3 minutes idle before each run, in the order md, rcraid Linux,
  rcraid Linux without "Read Cache", md again. The second md run matched the first within 5 % on reads and on
  random writes.
- Sequential writes to the RAID1 still varied from run to run, between 200 and 490 MB/s, under md and under
  rcraid alike. That is the state of the SSDs, not the driver.
- The Windows runs came before this discipline, so their write figures are not comparable. Their reads are.

## Results

MB/s for sequential jobs, IOPS for random ones. md: the mean of the two clean runs. One SSD alone (md, raw
member, same region): 568 MB/s sequential read, 6 200 IOPS at QD1, 51 000 IOPS at QD32.

| Volume | Job | md | rcraid Linux | rcraid Linux, no read cache | Windows (VM) | Windows (bare) | md (VM) |
|---|---|---:|---:|---:|---:|---:|---:|
| RAID1 | seq read 1M QD8 | 569 | 943 | 974 | 1013 | 996 | 533 |
| RAID1 | seq read 128K QD32 | 559 | 945 | 974 | 967 | 1 020 | 505 |
| RAID1 | rand read 4K QD1 | 5 680 | 5 230 | 5 390 | 2 310 | 4 190 | 5 140 |
| RAID1 | rand read 4K QD32 | 85 100 | 69 300 | 70 300 | 26 900 | 58 000 | 77 400 |
| RAID1 | seq write 1M QD8 | 200–490 | 290–490 | 470 | — | 419 | — |
| RAID1 | rand write 4K QD32 | 51 000 | 53 300 | 50 200 | 20 200 | 31 700 | — |
| RAID0 | seq read 1M QD8 | 1 098 | 1 010 | 1 012 | 1 053 | 1 094 | 1 010 |
| RAID0 | seq read 128K QD32 | 1 116 | 1 010 | 1 009 | 988 | 1 110 | 1 021 |
| RAID0 | rand read 4K QD1 | 6 180 | 5 450 | 5 430 | 2 700 | 4 280 | 5 490 |
| RAID0 | rand read 4K QD32 | 84 600 | 69 200 | 68 900 | 28 100 | 59 000 | 81 000 |
| RAID0 | seq write 1M QD8 | 955 | 950 | 945 | — | 942 | — |
| RAID0 | rand write 4K QD32 | 107 800 | 111 200 | 110 400 | 25 000 | 52 700 | — |

## What it shows

- **Random reads:** md is ahead. At QD32 it reaches 85 000 IOPS against 69 000–70 000 for AMD's Linux driver,
  about 20 % more, as on the HDDs. At QD1 it is 5–15 % ahead.
- **Writes:** level. RAID0 writes about 950 MB/s sequentially and 110 000 IOPS at random under both, RAID1
  about 51 000 IOPS at random.
- **RAID1, one sequential stream:** the AMD drivers read from both SSDs at once, about 950 MB/s. md reads a
  single stream from one SSD, 569 MB/s. This is the same as on the HDDs. With several streams md uses both
  mirrors; that was not measured.
- **RAID0, sequential reads:** md and the Windows driver about 10 % ahead of AMD's Linux driver (1 100 MB/s
  against 1 010).
- **Windows:** on the bare machine random reads reach 58 000–59 000 IOPS at QD32 and about 4 200 at QD1,
  twice what the same driver gave in the VM (about 27 000 and 2 300–2 700). So the 27 000 was the cost of
  Windows in a VM, not of the driver (md in the same kind of VM lost little: 77 000–81 000). On the bare
  machine Windows is below AMD's Linux driver (69 000) and md (85 000) at QD32, and below both at QD1.
  Random writes are lower too: 52 700 IOPS on the RAID0 against about 110 000, 31 700 on the RAID1 against
  about 51 000. Sequential reads and writes are level.

## Limits

One pair of DRAM-less SATA SSDs; their write speed depends on their state, so sequential writes are a range.
Windows on the bare machine: one run, in WinPE (Windows 10 1809). NVMe arrays, RAID5 and RAID10 on SSDs,
and several parallel streams were not measured.

# Why the numbers differ

From the code of the three stacks and from a second set of runs on the same machine and volumes (13.11.2026).

Sources:

- **Linux** — Linux 7.3 source.
- **AMD core** — the RAID core of AMD's Linux driver 9.3.3-00302 (`rcblob.x86_64`), read with a disassembler; the
  names come from its own symbols. The Windows driver runs the same core.
- **AMD shim** — the open part of the same Linux driver (`rc_*.c`).
- **rcraid.sys / rcbottom.sys** — AMD's Windows driver 9.3.3.218, disassembled; functions are given by address.
- **Runs** — fio under md and under AMD's Linux driver, DiskSpd under an installed Windows 10 LTSC 1809 (not WinPE)
  on the SSD RAID0; 20–30 s per job, the regions of the tables above.

## One sequential stream on a RAID1

- **md** keeps a read that continues a stream on the mirror that served it (Linux `drivers/md/raid1.c`:
  `is_sequential()`, `choose_best_rdev()`). It hands the stream to another mirror only if the disk reports an optimal
  I/O size (`should_choose_next()`), and libata never reports one for a SATA disk. Measured: one stream on the HDD
  RAID1 reads 140 MB/s from one disk and nothing from the other; on the SSD RAID1, 439 and 67 MB/s.
- **Two streams** go to both mirrors: 263 MB/s on the HDDs (139 + 115) and 1 058 MB/s on the SSDs (500 + 553), about
  the sum of the disks.
- **Both AMD drivers** move a single stream to the next mirror after a fixed amount of data (AMD core
  `RC_MapMirrorRead`): 4 MiB on an HDD array, 512 KiB on an SSD array. With 8 MiB in flight both disks are busy, so
  one stream gets both; on the HDDs each disk skips the other's pieces, hence 217 MB/s and not twice one disk. Under
  AMD's Linux driver two streams gave less than one (154 MB/s with "Read Cache" on).

## "Read Cache"

- Both AMD drivers cut every request at 64 KiB boundaries (the volume's cache tag), with the cache on or off (AMD
  core `RC_GenericIoGenChild`). The 64 KiB pieces are not what the cache costs.
- On an SSD array the core does not use the cache for random reads or short streams (`RC_SetCacheStrategy`), which is
  why "Read Cache" barely changes the SSD figures.
- On the HDD RAID1 the cache costs about 20 % of a stream: 171 MB/s with it, 220 without, measured again under AMD's
  Linux driver. Why was not traced: kprobe events (tracefs, bpftrace, perf) refuse a function without an ftrace
  call site (Linux `kernel/trace/trace_kprobe.c`, `__within_notrace_func()`), and AMD's binary core is built without
  one.

## AMD's Linux driver: random reads and SSD sequential reads

Only AMD's Linux driver is lower here; the Windows driver runs the same core and is level with md.

- **The I/O scheduler is not the cause.** Under the AMD driver the volume has `mq-deadline` (SSDs) or `bfq` (HDDs);
  with `none` the SSD RAID0 gave the same 58 000–60 000 IOPS at QD32.
- **The cost is per request, and one CPU carries it.** The core runs one request at a time: on Linux in one tasklet
  under one spinlock (AMD shim `rc_msg.c`). At QD32 on the SSD RAID0 one CPU spent about 70 % of its time in softirq
  under the AMD driver, against about 10 % under md, and two fio jobs gave barely more than one (63 900 against 61 500 IOPS). At QD1 the driver
  adds about 45 µs to each request (0.215 ms against 0.171 ms under md).
- Random reads on the SSD RAID0 by queue depth, IOPS:

  | Queue depth | 1 | 2 | 4 | 8 | 16 | 32 |
  |---|---:|---:|---:|---:|---:|---:|
  | md | 5 850 | 10 900 | 19 450 | 33 850 | 53 600 | 73 600 |
  | AMD Linux driver | 4 650 | 9 650 | 18 250 | 30 850 | 51 350 | 65 300 |

  The gap is largest at QD1 and at QD32 and small in between: the fixed cost per request at QD1, the one busy CPU at
  QD32.
- The AMD core also drives the SATA ports itself and takes the NCQ slots strictly in turn (`ahciSataRequest`); the
  Windows driver leaves the ports to `rcbottom.sys`, which takes any free slot. Whether that costs anything could not
  be measured (no kprobe events in the binary core, see above), and the depth sweep does not point to it: a slot rule would cost more the
  deeper the queue.
- On the HDDs the difference is small: 310 IOPS at QD32 against 348 under md.

## Windows

The WinPE figures above are lower than what an installed Windows gives. On the SSD RAID0, random 4 KiB reads,
installed Windows 10 LTSC with the same driver:

| DiskSpd | IOPS |
|---|---:|
| QD32, 1 thread, balanced power plan | 69 500 |
| QD32, 2 or 4 threads (16 or 8 each) | 77 100–77 400 |
| QD32, 1 thread, high-performance plan | 81 000 |
| QD1, balanced | 4 240 |
| QD1, balanced, thread on CPU 3 (`-a3`) | 4 220 |
| QD1, high-performance plan | 6 000 |

- **The power plan** decides QD1: with the high-performance plan Windows gives 6 000 IOPS, md's level. Windows and WinPE
  use the balanced plan by default.
- **One DiskSpd thread** limits QD32: the thread that submits a request also runs the RAID core when the core is
  free (rcraid.sys 0x140073530). With two or four threads Windows reaches 77 000.
- **Not the cause:** the queue depth (127 requests per volume, 255 per adapter, rcraid.sys 0x14006b950);
  write-through (neither AMD driver passes FUA to the disks: rcraid.sys 0x14006f9a8, AMD core `RC_STH_SubmitSRB`);
  the fixed CPU of the driver's DPC (0x140075604) — running the thread on that CPU changed nothing.
- Random writes on these DRAM-less SSDs depended on their state (6 000 to 98 000 IOPS in one session) and are not
  compared.

## QD1 on the HDDs

The three stacks are 2–10 % apart at QD1 on the HDDs (94–112 IOPS). The drivers' own costs are tens of microseconds
against about 10 ms per request, so this is not explained.
