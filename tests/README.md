# Test suite

Functional tests of mdadm's AMD RAIDXpert2 support (`--metadata=amd`, `super-amd.c`): 842 checks in 82
stages, on images of real AMD RAID disks, of disks made by the board's own RAID firmware in emulation, and of
disks this mdadm makes. Everything runs on loop devices of sparse files (plus LIO SCSI disks backed by files for
the udev stages); no real disk is touched unless you provide the optional AMD controller disks below.

## Requirements

A Linux test machine or VM you can reboot, **not a machine with data on md arrays**: the suite stops every md
array it finds, loads and unloads kernel modules, and puts udev rules and systemd units under `/run`.

- root, or a user with password-less `sudo`;
- kernel modules `md_mod`, `raid0`, `raid1`, `raid10`, `raid456`, `loop`, `btrfs`, `dm_mod`; for stage 18 and
  part of 39 the LIO loopback target (`target_core_mod`, `target_core_file`, `tcm_loop`) and configfs; for part
  of 26 `scsi_debug`; md `linear` is not needed;
- systemd (stage 39 runs `mdmon@` and `mdadm-last-resort@` units from the tree);
- `gcc`, `python3`, `xz`, `btrfs-progs`, `e2fsprogs`, `util-linux` (`losetup`, `sfdisk`, `blkdiscard`, `lsblk`),
  `dmsetup`, `udev`; for stage 40 also `xfsprogs`, `cryptsetup` and `lvm2` (skipped without them);
- about 20 GB free in the work directory (`WORKDIR`, default `/var/tmp/mdadm-amd-tests`): images of up to 10 TB
  are sparse, and the volumes md resyncs live on a compressed btrfs image (16 GB, a few GB used);
- 2 CPUs and 2 GB of RAM are enough.

An installed mdadm package may stay: `run.sh` points udev's rule 63 at the tree's mdadm and masks rule 64 under
`/run/udev/rules.d` while it runs.

**Optional: disks behind AMD RAID controllers.** Stages 21 (reused disk), 23 (b) and 27 (TRIM) need real block
devices the AMD firmware would take — SATA disks behind an AMD AHCI controller (`1022:43bd`, `7905`, `7916`,
`7917`) and NVMe disks — with the EFI variable `AMD_RAID` that enables them, because `mdadm --create` checks both
(the firmware would not see other disks). Without them these blocks are skipped with a `skip` line. They run on
blank disks with the serial numbers `AMDSATA0`…`AMDSATA4` and `AMDNVME0`, `AMDNVME1` (64 GiB was used), e.g. an
emulated AMD board in QEMU; **they write to and wipe those disks**, and refuse disks that carry AMD metadata.

## Running

Build mdadm from upstream with the patch (as in [docs/install.md](../docs/install.md)):

```sh
git clone https://github.com/md-raid-utilities/mdadm.git && cd mdadm
git checkout 4cd7d33c
git apply ../mdadm-amd/mdadm/mdadm-amd.patch
make -j4 mdadm mdmon
```

Then, from the repository:

```sh
sudo tests/run.sh ../mdadm                    # all stages
STAGES="7e 7f" tests/run.sh ../mdadm          # only these (ids as in "if want ..." of suite.sh)
PART=1 tests/run.sh ../mdadm                  # one half; PART=2 on a second machine: the halves are independent
STAGES=34 Q3L=B1 tests/run.sh ../mdadm        # one block of a stage, where the stage says so
```

With `sudo tests/run.sh` the suite runs as root; as a user it calls `sudo` itself. `WORKDIR=<dir>` puts the
images elsewhere; `ALLOW_MD=1` runs although md arrays are active. The output also goes to `$WORKDIR/run.log`,
and every check is written to the kernel log (`amd-test: ok …`), so `dmesg` shows which check the kernel
messages belong to.

The whole suite takes about 110 minutes in a VM with 2 vCPUs and 2 GB (Debian 13, kernel 6.12), `PART=2` about 60
minutes and `PART=1` about 50; most of it is waiting for md (resync at chosen speeds, rebuilds stopped midway, the md
bitmap daemon), not CPU. Without the AMD controller disks three blocks are skipped (in stages 21, 23 and 27).

**After an interrupted run, reboot** (or stop the md arrays and detach the loop devices of `$WORKDIR` by hand):
leftover arrays and loop devices of the suite's images make the next run fail or refuse to start.

## Reading the results

One line per check: `ok  <name>  (+<seconds of this check>s, <seconds since the start>s)` or `FAIL <name> …`;
`skip <block>: <why>` for a block the machine cannot run; `info: …` lines report values the checks used. At the
end: `checks: <n> ok, <n> FAIL, <n> blocks skipped, <seconds> s` and `ALL OK` or `SOME FAILED`; the exit code
is 0 only for `ALL OK`. Names that start with a stage id (`21: …`, `31 (c): …`) belong to that stage; `...` at
the start of a name continues the check before it. "(passes on the base too)" marks a check that also passes
without the fix its stage is about. Lines `mdadm: /dev/loopN: LBA 0 is not the MBR AMD wrote` are warnings
about the X399 fixture (its dump has no LBA 0), printed by `-E` inside checks.

## Stages

| Stage | What |
|---|---|
| 1 | dumps of an ASRock X670E RAID0 and an ASUS X399 RAID10: `-E`, assembly, geometry, a member missing, a stale disk, `--zero-superblock` refused; at the end: the dumps' metadata untouched |
| 3 | mdmon writes the state of a volume: a failed member, a write failing on one disk, the configuration ring |
| 4 | volumes made by the real firmware (RAID1, RAID5, RAID10): md initializes them under mdmon, a late disk, reassembly without resync |
| 5, 5b, 6 | rebuild onto an AMD global spare; a rebuild interrupted and rewritten by the firmware at boot; an interrupted rebuild resumes from the transform log |
| 7 | creating a container and volumes as the BIOS menu does (Initialize, MBR, label, extents, TRIM policy) |
| 7b–7d | an interrupted initialization resumes; an initial sync stopped cleanly; a crash during the initial sync (AMD bitmap) |
| 7e, 7f | HDD dumps of the test PC: a rebuild interrupted by a reboot resumes from its mark; the other volumes of the set |
| 7g–7k | the disk with element [0][0] last; the exact mark on interruption; a crafted packet; a configuration write failing on one disk; a volume let go by the monitor |
| 8 | mdmon repairs the Legacy record of the system disk broken by the BIOS menu, byte for byte as `tools/amdraid_fix_legacy.py` |
| 9, 10 | start without a member, write, the disk returns; `--add` to a container |
| 10b, 10c | members the Windows driver ran without (`helpers/winsim.py`); RAID5 under mdmon, layout and parity as the Windows driver |
| 11 | dedicated spares and RAIDABLE made by the real firmware: rebuilds onto them, roles, the live packet |
| 12 | behaviour as the AMD drivers: PD capacity, LBA 0, sets from another controller, 12 arrays per system, the commit block, LOCKED and distributed-spare volumes |
| 13, 13b, 13c | spare roles from mdadm; `-C` from global spares; a disk removed for good |
| 14 | `-As` with the stale disk first in the scan |
| 15 | AMD migrations by rcraid: RAIDABLE → RAID1 in the middle and finished, RAID1 grown |
| 9b, 16 | a recorded rebuild whose target is missing; `-C` without `-e` makes 1.2 as upstream |
| 17 | the md write-intent bitmap in the AMD service area: RAID1, RAID10, RAID5, crashes, foreign sessions, spares |
| 18 | udev: disks (LIO) pulled and plugged while running, the AMD rule's remove branch |
| 19 | a stale disk in the container gets the live configuration |
| 20 | review fixes: `-C` while md rebuilds onto the same spare, the md bitmap header, the kernel refusing the bitmap (an `LD_PRELOAD` shim built with gcc), `--update=no-bitmap`, lockless bitmaps |
| 21 | a stale disk joins its container; a foreign set and a reused disk do not (the last needs the AMD controller disks) |
| 22 | `-C --bitmap` refused in one line; volume names at assembly as IMSM's |
| 23 | the Legacy repair by mdadm without mdmon; `--add` of a NOT_INITIALIZE NVMe refused (needs the AMD controller disks) |
| 24, 26 | `--add` of a former member during a recorded rebuild; long names; mdmon's refusals reach mdadm, `--remove`, 4Kn disks |
| 27 | TRIM of mirrors as the AMD driver allows it (needs the AMD controller disks); `--grow` of a RAIDABLE |
| 28, 29 | volume handles in order as the firmware assigns them; first `-I` of interrupted and degraded volumes |
| 30–33 | mdmon writes that wait for disks; races and refusals of `-C`; malformed records, duplicate DeviceIDs, stale members; element extents |
| 34–36 | md bitmap placement, two broken Legacy records; rebuilds onto a late target; rebuilds mdmon did not record |
| 37, 38 | the loser of two `-C` at once; `-C -l1 -n1 --force` makes a RAIDABLE as the BIOS menu |
| 39 | the AMD udev rule: a disk with md 0.90 on its last partition, last-resort start on "unsafe" (LIO, systemd) |
| 40 | XFS, btrfs, LUKS or LVM on a whole disk: `-C` reports it and asks, `--add` to a container refuses it (`xfsprogs`, `cryptsetup`, `lvm2`; skipped without them) |
| 41 | a crash, then the AMD Windows driver clears the AMD bitmap: mdmon's shadow of it still says dirty, the next assembly resyncs (RAID1/5/10, and RAID1 with an md bitmap by its bits only); a clean stop leaves no dirty shadow |
| 42 | the bit rcraid.sys 9.5 sets in LD.Flags during a rebuild or an initialization is cleared when mdmon ends the transform |
| 43 | a check of a volume cut short in Windows (CHECK_REDUNDANCY): the volume runs read-write, md resyncs from the AMD log's mark, the end is recorded as the AMD driver records it |
| 44 | `-C` of a Volume (linear) on a kernel with no md linear (Debian 13, Ubuntu 24.04): refused before anything is written; on a kernel with it, created and running |
| 45 | `--detail-platform -e amd`: the controllers `AMD_RAID` makes the firmware take, their disks, the limits; `--export`; a controller path; `-C` of images does not warn about the platform |
| 46 | a write of mdmon that keeps failing (the AMD bitmap sector an error target, dm): one line in the kernel log, and one when it goes through again |
| 47 | volumes after AMD migrations that moved the data to AllocatedSpace + 0x800 (`rcadm -T`): assembled, also in the middle of one (md goes on with it: stages 51, 54); mdmon writes nothing into AMD's data log |
| 48 | `--grow --size` of a RAID1, RAID5, RAID10 in place, as `rcadm -T -s`: the start packet, the log, "100 %" and the final packet as AMD writes them; stopped midway and assembled again - goes on from the log; refused where there is no room, smaller, RAID0, the container; AMD's own growth midway (rcraid) ended by mdmon as the AMD driver ends it |
| 49 | `--grow --level=10` of a RAID0 of 2, as `rcadm -T -r10`: the spares mirror the members, the packets and the log as AMD writes them; stopped midway, `-I` waits for the new disks, goes on from the log; refused with too few spares, another layout or number of disks; AMD's own RAID0 -> RAID10 midway (rcraid) ended by mdmon |
| 50 | a rebuild target that lost the end of its rebuild (a power cut, the write cache gone): its member is recorded offline before mdmon writes it the live configuration and is rebuilt in place from 0; the rebuilds of other volumes onto it go on; md check 0 |
| 51 | `--grow --raid-devices=N` of a RAID5 and `--level=5 --layout=right-asymmetric` of a RAID1 of 2, as `rcadm -T -r5`: the packets and the log as AMD writes them, md held behind the log; stopped midway or before the first region - goes on from the mark; a member failed midway; refused with no spare, another chunk or layout, a backup file, an md bitmap, more disks and another chunk at once for data moved already; AMD's own migrations midway ended by mdmon as the AMD driver ends them |
| 52 | two disks away together: a volume on both of them taken back without a rebuild when they come back with one packet, not with different ones; a free disk with the packet mdmon took over from the AMD driver gets the live configuration after mdmon restarts |
| 53 | `--grow --chunk` of a RAID5 (also with `--raid-devices`) and of a RAID10, recorded as an AMD migration: the packets and the log, md held behind the log, goes on from the mark or from 0; one such migration in a container at a time; refused for other levels, sizes, layouts, with more disks for data moved already; AMD's own chunk changes of two volumes at once (rcraid) ended one after the other as the AMD driver ends them |
| 54 | `--grow --raid-devices=N` of a RAID0, as `rcadm -T -r0` (md: raid4 without parity, then raid0 again): the packets and the log as AMD writes them, md held behind the log, goes on from the mark or from 0; AMD's own RAID0 migrations midway ended by mdmon; one in its first stripes taken through them as it is assembled |
| 55 | migrations stopped before their first region (log at 0, or no log at all) go on from 0 as the AMD driver does: RAID5 + a disk, RAID1 -> RAID5, a chunk change, RAID0 + a disk; two migrations the AMD driver left in a container (midway, and both at 0): all assembled, carried out one after the other, the waiting one held even when writable, both ended as rcraid ends them |
| 56 | volumes the AMD driver recorded OFFLINE (both members missing, nothing written): taken back without a rebuild when their disks come back together with one packet, at once or disk by disk, not with different packets or a member missing; a member left missing (0x20) is recorded offline before the first write; a disk md runs in sync but mdmon left behind gets the live configuration, a chunk change then runs |
| 57 | a transform log one member does not take (an error target on its log sector): the other members still get it, and that member is failed in md as the AMD driver fails it (0x10); an initialization stops with the volume degraded, a RAID5 of 3 → 4 goes on without it and, stopped and assembled again, goes on from the copy of the other member with the data written meanwhile intact |
| 58 | a container whose mdmon is a zombie (the shutdown ramfs emulated in a pid namespace whose pid 1 does not reap), IMSM and AMD: `-I` of the container starts a new mdmon for the volume, `--stop` takes no 5 s and says no "still running" |
| 59 | `-A` of a volume by `--uuid` or `--name` with its container, IMSM and AMD: no "has wrong uuid" about the other volumes of the container, nor next to "already assembled"; a UUID no volume has, a foreign container and a foreign member are still refused with it; `-As` by mdadm.conf |
| 60 | a member that does not take the transform log is failed in md where the volume runs on without it: a RAID5 of 3 → 4 goes on degraded to its end and is rebuilt onto a spare, an initialization degrades; a RAID0 of 2 → 3 (no member to spare) waits with the writes to the region held until the log goes through; md frozen midway through a region: the region held; the data as written, md check 0 |
| 61 | md fails a disk in one volume (a write error, `--fail`): failed there alone as the AMD driver does - the disk's RAID0 or RAID1 in service, its PD ONLINE, configurations go on to it; assembled again without it in that volume, a spare rebuilt instead; a disk that goes away (`mdadm -If`) is failed everywhere and its PD OFFLINE, as is a disk a configuration write fails on |
| 62 | a RAID10 stopped with `mdadm -S` midway through a stripe size change, 24 times at random moments (`Q62N=` sets how many): assembled, it goes on to the end with the data as written, `md` check 0 |
| 63 | a RAID10 of 3 × 2 and of 2 × 2 stopped midway through a stripe size change, in different regions and at a region's end: after assembly it goes on (not read-only), ends with the new chunk, the data as written, `md` check 0 |
| 64 | a RAID10 stopped midway through a stripe size change: a second migration manager on the running volume (as udev started one after `mdadm -S`) goes on from the AMD log, not ahead of md; md interrupted unfrozen (`idle`) several times; `mdmon` does not run the volume stopped with `mdadm -S` again - each assembled, run to the end with the data as written, `md` check 0 |
| 65 | a second migration of a volume whose data a first one moved to AllocatedSpace + 0x800: `--grow --raid-devices=5` of a RAID0 and a RAID5 of 4 in place, the first stripes through AMD's log of the data, as `rcadm -T` does it; stopped there (by mdadm or by rcraid) - finished as the volume is assembled, md goes on, the end as rcraid's |
| 66 | `--grow --chunk` of such a volume (RAID5, RAID10): backwards from the end, the data going back up to + 0x5000, as the AMD driver lays it out; stopped midway (by mdadm or by rcraid) - goes on backwards from the log, the end as rcraid's; refused with more disks at once and for members grown in place |
| 67 | a migration in place held midway through a stripe of the old layout, with a reader there: no hang between md and mdadm (the window of held writes moves only where stripes of both layouts end); rcraid's own and ours, mdadm killed midway |
| 68 | chunk changes of one volume one after another without a pause (RAID10, RAID5: down forwards, up backwards): each held, in its direction, with AMD's log of a region; `mdadm --grow` through a pipe comes back as the migration ends |
| 69 | the backwards chunk change of stage 66 carried on by `mdadm --grow --continue` (as the `mdadm-grow-continue@` unit under systemd): the manager killed at the start, midway and after `-S` and assembly - the new one lets md on from the AMD log; the end as rcraid's |

Fixtures and where they come from: [fixtures/README.md](fixtures/README.md). `helpers/` has the scripts that
forge metadata with valid checksums for some stages; `../tools/amdraid_dump.py` parses it.

## AddressSanitizer

The same suite with mdadm and mdmon built with AddressSanitizer and UBSan:

```sh
cd ../mdadm
sed -i 's#^\tmlockall(MCL_CURRENT | MCL_FUTURE);#\t/* ASan build: no mlockall */#' mdmon.c
SAN="-fsanitize=address,undefined -fno-omit-frame-pointer"
make -B -j4 mdadm mdmon CXFLAGS="-O1 -g $SAN" LDFLAGS="$SAN"
mkdir -p /var/tmp/asan
printf '%s\n' 'ENV{ASAN_OPTIONS}="detect_leaks=0:log_path=/var/tmp/asan/udev"' \
	'ENV{UBSAN_OPTIONS}="print_stacktrace=1:log_path=/var/tmp/asan/udev-ubsan"' |
	sudo tee /run/udev/rules.d/01-asan-test.rules && sudo udevadm control --reload
ASAN_OPTIONS=detect_leaks=0:log_path=/var/tmp/asan/asan UBSAN_OPTIONS=print_stacktrace=1:log_path=/var/tmp/asan/ubsan \
	../mdadm-amd/tests/run.sh .
ls /var/tmp/asan                                   # no files: no reports
```

- `mlockall` in mdmon would try to lock ASan's shadow memory;
- udev runs programs with the device's properties as their environment, not its own: the rule passes the options
  (without them LeakSanitizer stops `mdadm --detail --export` in udev and the `/dev/md/<name>` links are missing);
- `detect_leaks=0`: mdadm does not free its memory before it exits, on purpose;
- expected failures under ASan: the checks of stage 20 that preload a shim (`LD_PRELOAD`; ASan has to come first).
