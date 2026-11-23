#!/bin/bash
# suite.sh: the checks of the AMD RAIDXpert2 test suite.  Run it through run.sh, which sets
# MDADM_DIR, TOOLS, HLP, FIXT, X399, AMD_RULE, WK, IMG, WQ, TMPW and builds the base images.
set -u
cd "$MDADM_DIR"
export MDADM_NO_SYSTEMCTL=1
M="sudo -E ./mdadm"
fail=0
T0=$(date +%s); TL=$T0
NOK=0; NFAIL=0; NSKIP=0
check() { local t r; if eval "$2"; then r="ok  "; NOK=$((NOK + 1)); else r="FAIL"; fail=1; NFAIL=$((NFAIL + 1)); fi; t=$(date +%s); echo "$r $1  (+$((t - TL))s, $((t - T0))s)"; TL=$t
	echo "amd-test: $r $1" | sudo tee /dev/kmsg >/dev/null; }   # to dmesg: tells which check the kernel messages belong to
# skip <what> <why>: a block that needs what this machine does not have (README: requirements); counted, not a FAIL
skip() { NSKIP=$((NSKIP + 1)); echo "skip $1: $2"; echo "amd-test: skip $1" | sudo tee /dev/kmsg >/dev/null; }
# lio_ok: SCSI disks from files (LIO, tcm_loop) for real udev add/remove events
lio_ok() { sudo modprobe -a target_core_mod target_core_file tcm_loop 2>/dev/null && [ -d /sys/kernel/config/target ]; }
# amd_disks <serial>...: blank disks the AMD firmware would take (SATA behind an AMD AHCI controller, NVMe) with these
# serial numbers, and the EFI variable AMD_RAID that enables them: an emulated AMD board (README). Without them, -C on
# real disks refuses (the firmware would not see them), so the blocks that need them are skipped.
amd_disks() { local s d; [ -e /sys/firmware/efi/efivars/AMD_RAID-fe26a894-d199-47d4-8afa-070e3d54ba86 ] || return 1
	for s in "$@"; do d=$(lsblk -dno NAME,SERIAL | awk -v s=$s '$2 == s { print $1 }'); [ -n "$d" ] || return 1; done; }
AMD_DISKS_WHY="needs blank disks behind AMD RAID controllers with the EFI variable AMD_RAID (an emulated AMD board, README)"
# refused <command>: a refusal is exit code 1..127. A crash (signal: code 128+N) is not a refusal; "! <command>" would let it pass
refused() { "$@"; local r=$?; [ $r != 0 ] && [ $r -lt 128 ]; }
# Stages to run: STAGES="<ids>" runs only these (ids as in the stages' "if want ..."), PART=1 / PART=2 run halves
# for two machines at once: the second runs the stages in PART2, the first all others (a new stage not listed
# in PART2 goes to the first). A stage prepares its own images; helpers needed by other stages too are defined outside "if want ...",
# so any set of stages gets them.
PART2="7c 7d 10c 15 9b 17 20 21 32 34 36 38 53 55 56 57 58 59 60 61 62 63 64"
SEEN=" "
want() {	# want <stage>: the stage is selected (SEEN: all stages asked about, to check the ids at the end)
	SEEN="$SEEN$1 "
	case "${PART:-}" in
	1) case " $PART2 " in *" $1 "*) return 1 ;; esac ;;
	2) case " $PART2 " in *" $1 "*) ;; *) return 1 ;; esac ;;
	esac
	case " ${STAGES:-$1} " in *" $1 "*) return 0 ;; esac
	return 1
}
case "${PART:-}" in ""|1|2) ;; *) echo "PART=$PART: 1 or 2"; exit 1 ;; esac
mdof() { for m in $(ls /sys/block | grep ^md); do [ "$(cat /sys/block/$m/md/level)" = "$1" ] && echo $m; done; }

for m in $(ls /sys/block | grep ^md); do $M -S /dev/$m >/dev/null 2>&1; done
for m in $(ls /sys/block | grep ^md); do $M -S /dev/$m >/dev/null 2>&1; done
# loop devices of past runs (image deleted or left by an interrupted run): otherwise they are "foreign" RAIDCore
# disks. Stage images are all under $WQ, temporary ones in $IMG; the six base images are attached again below
for l in $(sudo losetup -a | grep -E "deleted|$WQ/|$IMG/(ma/|k[0-9]\.img|zero\.img|stale\.img)" | cut -d: -f1); do sudo losetup -d $l; done
for f in asrock-nvme1n1 asrock-nvme2n1 x399-member0 x399-member1 x399-member2 x399-member3; do
	sudo losetup -j $IMG/$f.img | grep -q . || sudo losetup -f $IMG/$f.img
done
L() { sudo losetup -j $IMG/$1.img | cut -d: -f1; }
A1=$(L asrock-nvme1n1); A2=$(L asrock-nvme2n1)
X="$(L x399-member0) $(L x399-member1) $(L x399-member2) $(L x399-member3)"

# stop everything and wait for mdmon to exit: otherwise a container assembled next under the same number finds the exiting
# mdmon with the old state (mdadm sees "mdmon is running" and starts no new one)
stopall() { for i in 1 2; do for m in $(ls /sys/block | grep ^md); do $M -S /dev/$m >/dev/null 2>&1; done; done
	for i in $(seq 1 50); do pgrep -x mdmon >/dev/null || break; sleep 0.2; done; }
active() { grep -cE "^md[0-9]+ : active.*$1" /proc/mdstat; }
# the stage's AMD container, only if there is exactly one: an extra one (left by an interrupted run) gets no stray writes
cont1() { local c=$(grep -B1 "super external:amd" /proc/mdstat | grep -o "^md[0-9]*"); [ $(echo "$c" | grep -c .) = 1 ] && echo $c; }
waitrec() { for i in $(seq 1 $(( ${1:-600} / 2 ))); do grep -q -E 'resync|recover|check|repair' /proc/mdstat || { sleep 3; grep -q -E 'resync|recover|check|repair' /proc/mdstat || return 0; }; sleep 2; done; return 1; }
# amdshrink <image> <LD ID> <sectors per element> [...]: shorter LDs where the volume size does not matter and md
# would sync tens of GiB. Elements keep their start, volume capacity shrinks in the same ratio (for RAID5, RAID10 the size
# must be a multiple of the chunk: up to the caller); an empty slot (size 0) and a disk without a RAIDCore label (Legacy) stay as they were
amdshrink() {
	python3 - "$@" <<'PY'
import os, struct, sys
sys.path.insert(0, os.environ["TOOLS"]); from amdraid_dump import rc_sum
p, a = sys.argv[1], sys.argv[2:]
want = {int(a[i], 16): int(a[i + 1], 0) for i in range(0, len(a), 2)}
with open(p, "r+b") as f:
    f.seek(0x5000 * 512)
    if b"RAIDCore" not in f.read(512):
        sys.exit(0)
    f.seek(0x5001 * 512); c = bytearray(f.read(512)); off, size = struct.unpack_from("<II", c, 8)
    f.seek(off * 512); g = bytearray(f.read((size + 511) // 512 * 512)); q, end = struct.unpack_from("<II", g, 0x2c); end += q
    while q + 0x200 <= end and struct.unpack_from("<I", g, q)[0] == 0x25BD:
        sz = struct.unpack_from("<I", g, q + 0x90)[0]
        data = want.get(struct.unpack_from("<Q", g, q + 0x2c)[0])
        if data:
            old = 0
            for k in range(struct.unpack_from("<I", g, q + 0x6c)[0] * struct.unpack_from("<I", g, q + 0x70)[0]):
                e = q + 0x200 + 0x40 * k; ao, _, do, ds = struct.unpack_from("<QQQQ", g, e + 0x10)
                if ds:
                    old = old or ds
                    struct.pack_into("<Q", g, e + 0x18, data + do - ao); struct.pack_into("<Q", g, e + 0x28, data)
            cap = struct.unpack_from("<Q", g, q + 0x50)[0]
            assert old and cap * data % old == 0, (p, hex(old), cap)
            struct.pack_into("<Q", g, q + 0x50, cap * data // old)
        q += sz
    struct.pack_into("<Q", g, 0, rc_sum(g, 0xc, size - 0xc)); f.seek(off * 512); f.write(g)
    struct.pack_into("<Q", c, 0x10, struct.unpack_from("<Q", g, 0)[0]); struct.pack_into("<Q", c, 0, rc_sum(c, 8, 0x1f8))
    f.seek(0x5001 * 512); f.write(c)
PY
}
# sync speeds: the kernel defaults, the position checks are tuned to them (min above max overrides max)
sudo modprobe md_mod	# /proc/sys/dev/raid even without stage 1 (there the first -I loaded md)
echo 1000 | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null; echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null

# --- stage 1: dump disks of ASRock (RAID0) and X399 (RAID10): -E, assembly, member missing, stale disk, --zero-superblock ---
if want 1; then
check "examine ASRock" "$M -E $A1 | grep -q 'RAID Level : raid0'"
check "examine X399" "$M -E $(L x399-member0) | grep -q 'RAID Level : raid10'"
check "X399 fixture, LBA 0 empty: -E and the warning say AMD takes it for a non-RAID disk (rcraid.sys RC_ReadMBR)" "$M -E $(L x399-member0) 2>/dev/null | grep -q 'MBR (LBA 0) : not the one AMD wrote' && $M -E $(L x399-member0) 2>&1 >/dev/null | grep -q 'LBA 0 is not the MBR AMD wrote'"
check "brief groups ASRock into one container" "[ \$($M -E --brief $A1 $A2 | grep -c '^ARRAY metadata=amd') = 1 ]"
check "brief groups X399 into one container" "[ \$($M -E --brief $X | grep -c '^ARRAY metadata=amd') = 1 ]"

for d in $A1 $A2 $X; do $M -I $d >/dev/null 2>&1; done
R0=$(mdof raid0); R10=$(mdof raid10)
check "RAID0 started" "[ -n '$R0' ] && [ \$(cat /sys/block/$R0/md/array_state) = clean ]"
check "RAID0 size = LD capacity" "[ \$(cat /sys/block/$R0/size) = 3904856064 ]"
check "RAID0 chunk 256K" "[ \$(cat /sys/block/$R0/md/chunk_size) = 262144 ]"
check "RAID0 rd0 is element 0 (nvme2n1)" "[ \$(basename \$(readlink -f /sys/block/$R0/md/rd0/block)) = \$(basename $A2) ]"
check "RAID0 data offset" "[ \$(cat /sys/block/$R0/md/rd0/offset) = 1069056 ]"
sleep 1
check "RAID10 started, managed by mdmon" "[ -n '$R10' ] && [ \$(cat /sys/block/$R10/md/array_state) = read-auto ] && grep -q '^external:/' /sys/block/$R10/md/metadata_version && pgrep -x mdmon >/dev/null"
check "RAID10 layout near2, 64K" "[ \$(cat /sys/block/$R10/md/layout) = 258 ] && [ \$(cat /sys/block/$R10/md/chunk_size) = 65536 ]"
check "RAID10 size = LD capacity" "[ \$(cat /sys/block/$R10/size) = 39063609344 ]"
check "zero-superblock refused while in a container" "refused $M --zero-superblock $A1 2>/dev/null"
stopall

# starting without a member records its failure (mdmon): on copies of the X399 images
for i in 0 1 2 3; do cp --sparse=always $IMG/x399-member$i.img $IMG/k$i.img; done
K=""; for i in 0 1 2 3; do K="$K $(sudo losetup -f --show $IMG/k$i.img)"; done
set -- $K
for d in $1 $3 $4; do $M -I $d >/dev/null 2>&1; done
check "RAID10 3/4: waits without --run" "[ \$(active raid10) = 0 ]"
$M -IRs >/dev/null 2>&1
check "RAID10 3/4: -IRs starts it degraded" "grep -q '\[4/3\] \[U_UU\]' /proc/mdstat"
stopall
for d in $3 $4; do $M -I $d >/dev/null 2>&1; done; $M -IRs >/dev/null 2>&1
check "RAID10 without a whole mirror pair: not started" "[ \$(active raid10) = 0 ]"
stopall
$M -I $A1 >/dev/null 2>&1; $M -IRs >/dev/null 2>&1
check "RAID0 with a disk missing: not started" "[ \$(active raid0) = 0 ]"
stopall

for d in $K; do sudo losetup -d $d; done
for i in 0 1 2 3; do cp --sparse=always $IMG/x399-member$i.img $IMG/k$i.img; done
K=""; for i in 0 1 2 3; do K="$K $(sudo losetup -f --show $IMG/k$i.img)"; done
set -- $K
# stale disk: the commit block of member1 points to an old packet
cp --sparse=always $IMG/x399-member1.img $IMG/stale.img
python3 - <<'PY'
import os, struct, sys
sys.path.insert(0, os.environ["TOOLS"])
import amdraid_dump as a
p = os.environ["IMG"] + "/stale.img"
d = a.Disk(p)
c = a.parse_commit(d.read(a.LBA_COMMIT))
lba, h = [x for x in a.scan_ring(d) if x[1]['config_seq'] < c['config_seq'] - 5][-1]
blk = bytearray(d.read(a.LBA_COMMIT))
struct.pack_into('<IIQQ', blk, 8, lba, h['length'], h['sum'], h['config_seq'] + 1)
struct.pack_into('<Q', blk, 0, a.rc_sum(blk, 8, 0x1f8))
with open(p, 'r+b') as f:
    f.seek(a.LBA_COMMIT * 512); f.write(blk)
PY
S=$(sudo losetup -f --show $IMG/stale.img)
# mdmon rebuilds onto it at once (a former member): slowly, or the 10 TB sparse image fills up
echo 1000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
$M -A /dev/md/st -e amd $1 $S $3 $4 >/dev/null 2>&1
C=$(for m in $(ls /sys/block | grep ^md); do grep -q "^external:amd" /sys/block/$m/md/metadata_version && echo $m; done | head -1)
$M -I /dev/$C >/dev/null 2>&1; $M -IRs >/dev/null 2>&1; sleep 1
check "stale disk is not taken in sync (rebuilt onto)" "grep -q '\[4/3\] \[U_UU\]' /proc/mdstat && [ \"\$(cat /sys/block/\$(mdof raid10)/md/rd1/state 2>/dev/null)\" != in_sync ]"
stopall; sudo losetup -d $S; rm $IMG/stale.img
echo 200000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
for d in $K; do sudo losetup -d $d; done; rm -f $IMG/k?.img

cp --sparse=always $IMG/asrock-nvme1n1.img $IMG/zero.img
Z=$(sudo losetup -f --show $IMG/zero.img)
check "zero-superblock wipes the label" "$M --zero-superblock $Z 2>/dev/null && ! $M -E $Z >/dev/null 2>&1"
check "zero-superblock wipes AMD's MBR, keeps volume area" "[ \$(sudo dd if=$Z bs=512 count=1 status=none | tr -d '\0' | wc -c) = 0 ] && cmp -s <(sudo dd if=$Z bs=512 skip=$((0x100000)) count=$((0x5000)) status=none) <(sudo dd if=$A1 bs=512 skip=$((0x100000)) count=$((0x5000)) status=none)"
sudo losetup -d $Z; rm $IMG/zero.img
stopall
fi

# --- stage 3: mdmon writes the state (on copies of the X399 images) ---
if want 3; then
for i in 0 1 2 3; do cp --sparse=always $IMG/x399-member$i.img $IMG/w$i.img; done
W=""; for i in 0 1 2 3; do W="$W $(sudo losetup -f --show $IMG/w$i.img)"; done
set -- $W
BM=$(( (0x100000 + 0x80) * 512 ))
bits() { sudo dd if=$IMG/w0.img bs=1 skip=$BM count=512 status=none | python3 -c "import sys;print(sum(bin(x).count('1') for x in sys.stdin.buffer.read()))"; }
for d in $W; do $M -I $d >/dev/null 2>&1; done
V=$(mdof raid10); sleep 1
printf 'HELLO' | sudo dd of=/dev/$V bs=4096 conv=notrunc oflag=direct status=none; sleep 0.5
check "dirty: whole volume marked in AMD bitmap (2329 bits)" "[ \$(cat /sys/block/$V/md/array_state) = active ] && [ \$(bits) = 2329 ]"
for i in $(seq 1 20); do [ "$(cat /sys/block/$V/md/array_state)" = clean ] && break; sleep 1; done
check "clean: AMD bitmap cleared" "[ \$(cat /sys/block/$V/md/array_state) = clean ] && [ \$(bits) = 0 ]"
$M --fail /dev/$V $3 >/dev/null 2>&1; sleep 2
cfg() { python3 $TOOLS/amdraid_dump.py $IMG/w$1.img 2>/dev/null; }
check "failure: new config generation 55 on w0, w1, w3" "cfg 0 | grep -q 'конфигурации 55' && cfg 1 | grep -q 'конфигурации 55' && cfg 3 | grep -q 'конфигурации 55'"
check "failure: failed disk w2 not written" "cfg 2 | grep -q 'конфигурации 54'"
check "failure: volume CRITICAL, element 2 flags 0x10 (failed, as the AMD driver on errors)" "cfg 0 | grep -q 'state=0x201' && cfg 0 | grep -q '\[1,0\].*flags=0x10'"
check "failure: packet moved to next ring slot, sums valid" "cfg 0 | grep -q 'LBA 0x5903' && [ \$(cfg 0 | grep НЕВЕРНО | grep -vc MBR) = 0 ]"
# the PD of a disk failed at run time is OFFLINE, as rcraid writes it
W2ID=$(cfg 2 | sed -n 's/^  @+0x[0-9a-f]* dev=\([0-9a-f]*\) .*этот диск.*/\1/p')
check "failure: PD of the failed disk OFFLINE (as the AMD Linux driver), the others ONLINE" "[ -n '$W2ID' ] && cfg 0 | grep -q 'dev=$W2ID handle=[0-9/]* RAIDCORE_DISK OFFLINE' && [ \$(cfg 0 | grep -c 'RAIDCORE_DISK ONLINE') = 3 ]"
# PD records written by the Windows driver (ports from 0, Features 0x21ed001c) are rewritten by mdmon as they are
pdk() { python3 $TOOLS/amdraid_dump.py $1 2>/dev/null | sed -n 's/^  @+0x[0-9a-f]* \(dev=[0-9a-f]* handle=[0-9]*\/[0-9]*\) .*\(bus=0x[0-9a-f]*\) .*\(features=0x[0-9a-f]*\).*/\1 \2 \3/p'; }
check "failure: PD records of the Windows driver kept (ID, port from 0, bus, Features)" "[ \$(pdk $IMG/w0.img | grep -c 'handle=0/1 .*features=0x21ed001c') = 1 ] && [ \"\$(pdk $IMG/x399-member0.img)\" = \"\$(pdk $IMG/w0.img)\" ]"
stopall
# w2, failed on errors (0x10), is attached, but mdmon does not rebuild onto it by itself (as AMD); a missing one: stage 9
for d in $1 $2 $3 $4; do $M -I $d >/dev/null 2>&1; done
V=$(mdof raid10); sleep 3
check "reassembled degraded without the failed member" "grep -q '\[4/3\] \[UU_U\]' /proc/mdstat"
check "failed member present: not rebuilt onto, -E says failed" "! grep -q recover /proc/mdstat && $M -E $1 | grep -q 'Member   2 .*out of service: failed'"
stopall
printf '\xff\x07' | sudo dd of=$IMG/w0.img bs=1 seek=$BM conv=notrunc status=none
for d in $1 $2 $4; do $M -I $d >/dev/null 2>&1; done
V=$(mdof raid10); sleep 2
check "bits left in AMD bitmap: md resyncs" "[ \$(cat /sys/block/$V/md/sync_action) = resync ]"
stopall
check "interrupted resync: bitmap stays dirty" "[ \$(bits) != 0 ]"
for d in $W; do sudo losetup -d $d; done; rm -f $IMG/w?.img
fi

# --- stage 4: volumes created by the real RAIDCoreDxe (the emulated board, snapshots 04-r1 and 08) ---
# Images of 64 GiB, md writes whole mirrors: keep them on compressed btrfs (zeroes take almost no space).
QD=$FIXT/2026-10-31-qemu-raidcore-msi1a93
if ! mountpoint -q $WQ; then
	[ -e $IMG/q.btrfs ] || { truncate -s 16G $IMG/q.btrfs && sudo /sbin/mkfs.btrfs -q -f $IMG/q.btrfs; }
	mkdir -p $WQ && sudo mount -o loop,compress-force=zstd:1 $IMG/q.btrfs $WQ && sudo chown $USER $WQ
fi
mkdir -p $WQ/c	# images of stages 7...14, 29
qsnap() { local s; for s in "$@"; do [ -d $WQ/$s ] || tar -C $WQ -xSJf $QD/$s.tar.xz; done; }	# snapshots of the emulated board: into $WQ, once
QL() { sudo losetup -j $WQ/w/blank-$1.img | cut -d: -f1; }
qcfg() { python3 $TOOLS/amdraid_dump.py $WQ/w/blank-$1.img 2>/dev/null; }
qgen() { qcfg $1 | grep -o 'конфигурации [0-9]*' | cut -d' ' -f2; }
qsum() { python3 $TOOLS/amdraid_dump.py $1 2>/dev/null | grep -o 'его сумма [0-9a-f]*'; }
waitsync() { for i in $(seq 1 300); do grep -q -E 'resync|recover' /proc/mdstat || return 0; sleep 2; done; return 1; }
if want 4; then
qsnap 04-r1 08-md-init-late
rm -rf $WQ/w && mkdir $WQ/w && cp --reflink=always $WQ/04-r1/*.img $WQ/w/
# Volumes shrunk: this tests md's initialization and recording its end, not sizes (BIOS volume sizes: stage 1).
# RAID1: 4 GiB per element (was 11.2: the first check would catch its resync, ~10 s), RAID5 and RAID10: 1 GiB each
for n in sata0 sata1 sata2 sata3 nvme0 nvme1; do
	amdshrink $WQ/w/blank-$n.img 7e317001abc2 0x800000 0a2ec63738e0 0x200000 8eab03ae550b 0x200000
done
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
for n in sata0 sata1 sata2 sata3 nvme0 nvme1; do sudo losetup -f $WQ/w/blank-$n.img; done

check "BIOS volumes: RAID1 (State 0) and RAID5 managed" "$M -E \$(QL nvme0) | grep -A6 'Subarray : 2' | grep -q 'md support : read-write' && $M -E \$(QL sata0) | grep -A6 'Subarray : 0' | grep -q 'md support : read-write'"
# the order udev gives when one disk arrives last
OUT=$(for n in sata0 sata1 sata2 nvme0 nvme1; do $M -I $(QL $n) 2>&1; done)
sleep 2
R1=$(mdof raid1)
check "uninitialized mirror: md resyncs it under mdmon" "[ -n '$R1' ] && grep -q '^external:/' /sys/block/$R1/md/metadata_version && [ \$(cat /sys/block/$R1/md/sync_action) = resync ]"
waitsync
check "init done, a disk missing: completion not written yet (config 19)" "[ \$(qgen sata0) = 19 ] && [ \$(qgen nvme0) = 19 ]"
ST=$(cat /sys/block/$R1/md/array_state)
OUT=$($M -I $(QL sata3) 2>&1); sleep 2
check "late disk: running volume left alone" "! echo \"\$OUT\" | grep -q \"$R1\" && [ \$(cat /sys/block/$R1/md/array_state) = $ST ]"
waitsync; sleep 2
check "late disk joins: config 22 on all six disks" "(for n in sata0 sata1 sata2 sata3 nvme0 nvme1; do [ \$(qgen \$n) = 22 ] || exit 1; done)"
check "mirrors and RAID5: one LD each, transform completed (0xa1a6), NORMAL" "[ \$(qcfg sata0 | grep -c 'transform=- last=CREATE_REDUNDANCY state=0xa1a6') = 3 ] && [ \$(qcfg sata0 | grep -c '^  LD @') = 3 ] && [ \$(qcfg sata0 | grep '^  LD @' | grep -c 'state=0x200') = 3 ]"
check "RAID5 from the menu initialized by md (resync), not left to AMD" "qcfg sata0 | grep -A1 'type=0x1bf5' | grep -q 'transform=- last=CREATE_REDUNDANCY state=0xa1a6' && ! qcfg sata0 | grep -q 'transform=CREATE_REDUNDANCY'"
# (before RAID5 became writable the packet matched snapshot 08, accepted by RAIDCoreDxe; now RAID5 is initialized in it too)
check "the same packet on all six disks" "(for n in sata1 sata2 sata3 nvme0 nvme1; do [ -n \"\$(qsum $WQ/w/blank-\$n.img)\" ] && [ \"\$(qsum $WQ/w/blank-\$n.img)\" = \"\$(qsum $WQ/w/blank-sata0.img)\" ] || exit 1; done)"
stopall
echo 1000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null	# small volumes: slow, so a started resync does not end before the check
for n in sata0 sata1 sata2 sata3 nvme0 nvme1; do $M -I $(QL $n) >/dev/null 2>&1; done; sleep 2
check "initialized volumes reassemble without resync" "[ -n \"\$(mdof raid1)\" ] && [ -n \"\$(mdof raid10)\" ] && [ -n \"\$(mdof raid5)\" ] && ! grep -q resync /proc/mdstat"
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
stopall
for n in sata0 sata1 sata2 sata3 nvme0 nvme1; do sudo losetup -d $(QL $n); done
rm -rf $WQ/w
fi

# --- stage 5: rebuild onto an AMD global spare (snapshot 11 -> 12, accepted by RAIDCoreDxe) ---
# 11: RAID10 Critical and uninitialized, slot [1,0] empty (0x8010), blank-sata4 has SpareInfo 0x100;
# in RAID5 the BIOS removed the stale blank-sata2 only from the second LD copy.
Q5="sata0 sata1 sata2 sata3 sata4 nvme0 nvme1"
if want 5; then
qsnap 11-spare-assigned
rm -rf $WQ/w; mkdir $WQ/w && cp --reflink=always $WQ/11-spare-assigned/*.img $WQ/w/
# RAID10 shrunk to 1 GiB per element (was 5.6): tested is which spare it is rebuilt onto, where, and what is recorded
for n in $Q5; do amdshrink $WQ/w/blank-$n.img 8eab03ae550b 0x200000; done
for n in $Q5; do sudo losetup -f $WQ/w/blank-$n.img; done
check "slot empty in either LD copy is out of service (RAID5 without the stale disk)" "$M -E \$(QL sata0) | sed -n '/Subarray : 0/,/Subarray : 1/p' | grep -q 'Member   2 .*out of service'"
for n in $Q5; do $M -I $(QL $n) >/dev/null 2>&1; done; sleep 2
R10=$(mdof raid10)
check "degraded uninitialized RAID10 is managed" "[ -n '$R10' ] && grep -q '^external:/' /sys/block/$R10/md/metadata_version"
waitrec
check "spare taken: RAID10 4/4, member 2 on blank-sata4 at 0x105000" "grep -A1 '^$R10 ' /proc/mdstat | grep -q '\[UUUU\]' && [ \$(cat /sys/block/$R10/md/rd2/offset) = $((0x105000)) ] && [ \$(basename \$(readlink -f /sys/block/$R10/md/rd2/block)) = \$(basename \$(QL sata4)) ]"
check "rebuilt member = its mirror" "[ \"\$(sudo dd if=$WQ/w/blank-sata4.img bs=1M skip=$((0x105000/2048)) count=$((0x200000/2048)) status=none | sha256sum)\" = \"\$(sudo dd if=$WQ/w/blank-sata3.img bs=1M skip=$((0x87d000/2048)) count=$((0x200000/2048)) status=none | sha256sum)\" ]"
check "recorded: init 5, rebuild start 6, end 7 on all seven disks, spare keeps 0x100" "(for n in $Q5; do [ \$(qgen \$n) = 7 ] || exit 1; done) && qcfg sata0 | grep -q 'last=RESTORE_SEGMENTS state=0xa1a6' && qcfg sata0 | grep -q 'spare=0x100' && [ \$(qcfg sata0 | grep -c 'id=8eab03ae550b') = 1 ]"
stopall
echo 1000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null	# small volumes: slow, so a started resync does not end before the check
for n in $Q5; do $M -I $(QL $n) >/dev/null 2>&1; done; sleep 2
check "rebuilt RAID10 reassembles 4/4 without recovery" "R=\$(mdof raid10); [ -n \"\$R\" ] && grep -A1 \"^\$R \" /proc/mdstat | grep -q '\[UUUU\]' && ! grep -q -E 'resync|recover' /proc/mdstat"
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
stopall
for n in $Q5; do sudo losetup -d $(QL $n); done
rm -rf $WQ/w
fi

# --- stage 5b: snapshot 13: rebuild interrupted at 44 %, RAIDCoreDxe rewrote the configuration at boot
# with broken PDs (no DeviceID) -> PDs restored from the ring, resume from the log -> snapshot 14
if want 5b; then
qsnap 13-fw-restore-boot 14-md-resume
rm -rf $WQ/w; mkdir $WQ/w && cp --reflink=always $WQ/13-fw-restore-boot/*.img $WQ/w/
for n in $Q5; do sudo losetup -f $WQ/w/blank-$n.img; done
check "PD records the firmware left without IDs are restored from the ring" "$M -E \$(QL sata0) | grep -q '^         5  436269cf4bbed96f       5  raid'"
L14=$(sudo losetup -r -f --show $WQ/14-md-resume/blank-sata0.img)
check "container keeps its UUID" "[ \"\$($M -E --brief \$(QL sata0) | head -1)\" = \"\$($M -E --brief $L14 | head -1)\" ]"
sudo losetup -d $L14
# slowly (10 MB/s): in 2 s md covers < 0x10000 sectors, so a start from zero cannot pass for a resume.
# The rebuild target (sata4) arrives after sata3, when RAID10 already runs: mdmon adds it as a spare.
echo 10000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
for n in $Q5; do $M -I $(QL $n) >/dev/null 2>&1; done; sleep 2
R10=$(mdof raid10)
RS=$(cat /sys/block/$R10/md/rd2/recovery_start 2>/dev/null)
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
check "recovery resumes from the transform log (member sector 5127680), target joining late" "[ -n '$RS' ] && [ '$RS' != none ] && [ $RS -ge 5127680 ] && [ $RS -lt $((5127680 + 0x10000)) ]"
waitrec
check "end recorded: config 8 on all seven disks, RAID10 NORMAL" "(for n in $Q5; do [ \$(qgen \$n) = 8 ] || exit 1; done) && qcfg sata0 | sed -n '/id=8eab03ae550b/,/\[1,1\]/p' | grep -q 'state=0x200'"
check "packet = the one RAIDCoreDxe accepted (snapshot 14)" "(for n in $Q5; do [ -n \"\$(qsum $WQ/w/blank-\$n.img)\" ] && [ \"\$(qsum $WQ/w/blank-\$n.img)\" = \"\$(qsum $WQ/14-md-resume/blank-\$n.img)\" ] || exit 1; done)"
check "resumed member = its mirror" "[ \"\$(sudo dd if=$WQ/w/blank-sata4.img bs=1M skip=$((0x105000/2048)) count=$((0xb2d000/2048)) status=none | sha256sum)\" = \"\$(sudo dd if=$WQ/w/blank-sata3.img bs=1M skip=$((0x87d000/2048)) count=$((0xb2d000/2048)) status=none | sha256sum)\" ]"
stopall
for n in $Q5; do sudo losetup -d $(QL $n); done
rm -rf $WQ/w
fi

# --- stage 6: an interrupted rebuild resumes where it stopped (AMD transform log) ---
# Snapshot 12: --fail nvme1 of RAID1 -> spare blank-sata4 (flag 0x100 kept), space after the RAID10 extent.
if want 6; then
qsnap 12-md-rebuild
rm -rf $WQ/w; mkdir $WQ/w && cp --reflink=always $WQ/12-md-rebuild/*.img $WQ/w/
# RAID1 shrunk to 2 GiB per element (was 11.2): stop in the middle, at 1.5M sectors (60 MB/s: ~13 s, ~20 s more to
# the end); recording start and end, the mark and resuming from it do not depend on the size
for n in $Q5; do amdshrink $WQ/w/blank-$n.img 7e317001abc2 0x400000; done
for n in $Q5; do sudo losetup -f $WQ/w/blank-$n.img; done
for n in $Q5; do $M -I $(QL $n) >/dev/null 2>&1; done; sleep 2
tlog() { sudo dd if=$WQ/w/blank-$1.img bs=512 skip=$(($2)) count=1 status=none | python3 -c '
import sys, struct
b = sys.stdin.buffer.read()
print("%x %d %d" % (struct.unpack_from("<I", b, 0x18)[0], struct.unpack_from("<Q", b, 0x1c)[0], struct.unpack_from("<I", b, 0x44)[0]))'; }
R1=$(mdof raid1)
echo 60000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
$M /dev/$R1 --fail $(QL nvme1) >/dev/null 2>&1; sleep 8
check "rebuild start recorded: RESTORE_SEGMENTS in two LD copies, spare at 0xc32000" "[ \$(qcfg sata0 | grep -c 'transform=RESTORE_SEGMENTS last=RESTORE_SEGMENTS') = 2 ] && qcfg sata0 | grep -q 'dev=436269cf4bbed96f.*alloc=0xc32000+0x405000 flags=0x0'"
check "transform log written on both column-0 members" "[ \"\$(tlog sata4 0xc32000 | cut -d' ' -f1,3)\" = '5358 1' ] && [ \"\$(tlog nvme0 0x100000 | cut -d' ' -f1,3)\" = '5358 1' ]"
for i in $(seq 1 120); do [ $(cut -d' ' -f1 /sys/block/$R1/md/sync_completed 2>/dev/null || echo 0) -gt 1500000 ] 2>/dev/null && break; sleep 2; done
sleep 1; stopall
DONE=$(tlog sata4 0xc32000 | cut -d' ' -f2)
echo "info: 6: the rebuild stopped at $DONE of $((0x400000)) sectors"
check "interrupted: log has the checkpoint" "[ $DONE -gt 1000000 ]"
for n in $Q5; do $M -I $(QL $n) >/dev/null 2>&1; done; sleep 3
R1=$(mdof raid1)
check "reassembled: md resumes the recovery from the log" "[ \$(cat /sys/block/$R1/md/rd1/recovery_start 2>/dev/null || echo 0) = $DONE ] || [ \$(cut -d' ' -f1 /sys/block/$R1/md/sync_completed) -ge $DONE ]"
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
waitrec
check "rebuild end recorded: one LD, RESTORE completed, NORMAL, flags back to 0x100" "qcfg sata0 | sed -n '/id=7e317001abc2/,/\[0,1\]/p' | grep -q 'state=0x200' && [ \$(qcfg sata0 | grep -c 'id=7e317001abc2') = 1 ] && qcfg sata0 | sed -n '/id=7e317001abc2/,/\[0,1\]/p' | grep -q 'Flags=0x100 ' && qcfg sata0 | grep -q 'last=RESTORE_SEGMENTS state=0xa1a6 0% protect_start=0x0  gen=17'"
check "transform logs cleared" "[ \"\$(tlog sata4 0xc32000)\" = '0 0 0' ] && [ \"\$(tlog nvme0 0x100000)\" = '0 0 0' ]"
check "resumed rebuild: member = its mirror" "[ \"\$(sudo dd if=$WQ/w/blank-sata4.img bs=1M skip=$((0xc37000/2048)) count=$((0x400000/2048)) status=none | sha256sum)\" = \"\$(sudo dd if=$WQ/w/blank-nvme0.img bs=1M skip=$((0x105000/2048)) count=$((0x400000/2048)) status=none | sha256sum)\" ]"
stopall
for n in $Q5; do sudo losetup -d $(QL $n); done
rm -rf $WQ/w
fi

# the stage 1 images (X399, ASRock) are RAIDCore disks too: creating a container would see them
for f in $IMG/*.img; do for l in $(sudo losetup -j $f | cut -d: -f1); do sudo losetup -d $l; done; done
# --- stage 7: creating a container and volumes (as the RAIDXpert2 BIOS menu; the emulated board accepted it: snapshot 15) ---
if want 7; then
mkdir -p $WQ/c && rm -f $WQ/c/*.img
CL=""; for n in 0 1 2 3; do truncate -s 4G $WQ/c/d$n.img; CL="$CL $(sudo losetup -f --show $WQ/c/d$n.img)"; done
C1=$(echo $CL | cut -d' ' -f1)
$M -C /dev/md/amdc -e amd -n 4 $CL --run >/dev/null 2>&1
CN=$(cont1)
check "container created: 4 disks, controller + 4 PDs, handles 1-4" "[ -n '$CN' ] && [ \$($M -E $C1 | grep -c ' raid    0x3000') = 4 ] && $M -E $C1 | grep -q '^         4  [0-9a-f]*       4  raid'"
check "container UUID in the map after -C = UUID from the metadata (-E --brief)" "[ \"\$(sudo awk '\$1==\"$CN\"{print \$3}' /run/mdadm/map)\" = \"\$($M -E --brief $C1 | head -1 | sed 's/.*UUID=//')\" ]"
check "Initialize as the BIOS: MBR 0x82 from 0x3F, 0xAF at 0x4F80, zeroed tail" "sudo dd if=$C1 bs=512 count=1 status=none | od -A n -t x1 -j 450 -N 1 | grep -q 82 && sudo dd if=$C1 bs=512 skip=$((0x4f80)) count=1 status=none | od -A n -t x1 -N 1 | grep -q af"
$M -C /dev/md/mirror -l1 -n2 -z 2G /dev/$CN --run >/dev/null 2>&1
$M -C /dev/md/data -l10 -n4 -c 128 /dev/$CN --run >/dev/null 2>&1
sleep 2
RM=$(mdof raid1); RD=$(mdof raid10)
check "volumes created under mdmon: RAID1 and RAID10 (second one through mdmon)" "[ -n '$RM' ] && [ -n '$RD' ] && grep -q '^external:/$CN/0' /sys/block/$RM/md/metadata_version && grep -q '^external:/$CN/1' /sys/block/$RD/md/metadata_version"
check "RAID10: near 2, 128K, member = largest common free extent" "[ \$(cat /sys/block/$RD/md/layout) = 258 ] && [ \$(cat /sys/block/$RD/md/chunk_size) = 131072 ]"
# loop disks support TRIM but do not say whether they read zeroes after it: AMD mirrors get no TRIM
check "TRIM as the AMD driver: off on mirrors whose members give no zeroes (loop has TRIM), said in dmesg" "[ \$(cat /sys/block/\$(basename $C1)/queue/discard_max_bytes) != 0 ] && [ \$(cat /sys/block/$RM/queue/discard_max_bytes) = 0 ] && [ \$(cat /sys/block/$RD/queue/discard_max_bytes) = 0 ] && [ \$(cat /sys/block/$RM/queue/discard_max_hw_bytes) != 0 ] && sudo dmesg | grep -q 'mdmon: amd: TRIM off on $RM as the AMD driver does'"
waitrec; sleep 2
check "md initialized them: one LD each, CREATE_REDUNDANCY completed, NORMAL" "[ \$(python3 $TOOLS/amdraid_dump.py $WQ/c/d0.img 2>/dev/null | grep -c 'last=CREATE_REDUNDANCY state=0xa1a6') = 2 ] && [ \$(python3 $TOOLS/amdraid_dump.py $WQ/c/d0.img 2>/dev/null | grep -c '^  LD @') = 2 ]"
C3=$(echo $CL | cut -d' ' -f3); C4=$(echo $CL | cut -d' ' -f4)
$M -C /dev/md/pick -e amd -l1 -n2 -z 256M $C4 $C3 --run >/dev/null 2>&1; waitrec; sleep 2
check "disks given: RAID1 on handles 4,3 in that order, initialized" "$M -E $C1 | grep -A14 '^\[pick\]' | grep -q 'Member   0 : [0-9a-f]* handle 4 ' && $M -E $C1 | grep -A14 '^\[pick\]' | grep -q 'Member   1 : [0-9a-f]* handle 3 ' && [ \$(python3 $TOOLS/amdraid_dump.py $WQ/c/d0.img 2>/dev/null | grep -c 'last=CREATE_REDUNDANCY state=0xa1a6') = 3 ]"
check "disks given: twice, or missing - refused" "$M -C /dev/md/bad -e amd -l1 -n2 -z 64M $C4 $C4 --run 2>&1 | grep -q 'is given twice' && $M -C /dev/md/bad -e amd -l1 -n2 -z 64M $C4 missing --run 2>&1 | grep -q 'not \"missing\"'"
# little room: d1 fully used (RAID1 2 GiB + RAID10), d3/d4 have ~1.7 GiB: refused with sizes and the reason per disk
check "no room: sizes and reasons per disk, nothing created" "$M -C /dev/md/bad -e amd -l1 -n2 -z 3G $C4 $C3 --run 2>&1 | grep -q 'has [0-9]* MiB free for a member, 3072 MiB asked' && $M -C /dev/md/bad -e amd -l1 -n2 -z 64M $C1 $C4 --run 2>&1 | grep -q 'cannot take a member: no free space left' && $M -C /dev/md/bad -l1 -n2 -z 3G /dev/$CN --run 2>&1 | grep -q '3072 MiB per member asked for, but no 2 disks of the container have more than [0-9]* MiB free each' && $M -C /dev/md/bad -l1 -n2 -z 3G /dev/$CN --run 2>&1 | grep -q 'handle 1, .*: no free space left' && [ ! -e /dev/md/bad ]"
# RAID0 as the BIOS menu makes it (MSI): RAID10N First=n Second=1, one LD record, no transform, last=CREATE_REDUNDANCY, no bitmap
$M -C /dev/md/stripe -e amd -l0 -n2 -z 256M $C4 $C3 --run >/dev/null 2>&1; sleep 1; R0=$(mdof raid0)
check "RAID0 created as the menu writes one: one LD, First=2 Second=1, no transform, no bitmap, NORMAL" "[ -n '$R0' ] && python3 $TOOLS/amdraid_dump.py $WQ/c/d0.img 2>/dev/null | grep -A2 \"DevicePrivate='stripe'\" | grep -q 'transform=- last=CREATE_REDUNDANCY state=0x0 .*attr=0x0' && python3 $TOOLS/amdraid_dump.py $WQ/c/d0.img 2>/dev/null | grep -A2 \"DevicePrivate='stripe'\" | grep -q 'First=2 Second=1' && [ \$(python3 $TOOLS/amdraid_dump.py $WQ/c/d0.img 2>/dev/null | grep -c \"DevicePrivate='stripe'\") = 1 ] && python3 $TOOLS/amdraid_dump.py $WQ/c/d0.img 2>/dev/null | grep \"DevicePrivate='stripe'\" | grep -q 'state=0x200'"
head -c 16M /dev/urandom > $TMPW/amd-r0.bin; sudo dd if=$TMPW/amd-r0.bin of=/dev/$R0 bs=1M oflag=direct status=none
check "RAID0: 512 MiB, 64K chunk, data reads back" "[ \$(cat /sys/block/$R0/size) = $((512 * 2048)) ] && [ \$(cat /sys/block/$R0/md/chunk_size) = 65536 ] && cmp -s <(sudo dd if=/dev/$R0 bs=1M count=16 iflag=direct status=none) $TMPW/amd-r0.bin"
truncate -s 4G $WQ/c/d4.img; L5=$(sudo losetup -f --show $WQ/c/d4.img)
check "a second AMD container is refused (one configuration per system)" "refused $M -C /dev/md/amdx -e amd -n 1 $L5 --run --force >/dev/null 2>&1 && ! sudo dd if=$L5 bs=512 skip=$((0x5000)) count=1 status=none | grep -q RAIDCore"
sudo losetup -d $L5
stopall
for d in $CL; do $M -I $d >/dev/null 2>&1; done; sleep 2
check "created volumes reassemble without resync, RAID0 data in place" "[ -n \"\$(mdof raid1)\" ] && [ -n \"\$(mdof raid10)\" ] && [ -n \"\$(mdof raid0)\" ] && ! grep -q -E 'resync|recover' /proc/mdstat && cmp -s <(sudo dd if=/dev/\$(mdof raid0) bs=1M count=16 iflag=direct status=none) $TMPW/amd-r0.bin"
# AMD driver cache policy and volume name (mdadm --update-subarray; the cache is for Windows/firmware, md does not use it)
CNU=$(cont1)
ldc() { python3 $TOOLS/amdraid_dump.py $WQ/c/d0.img 2>/dev/null | grep -A2 "DevicePrivate='$1'" | grep -o 'cache=0x[0-9a-f]*' | sort -u | tr '\n' ' '; }
$M --update-subarray=0 --update=no-write-back /dev/$CNU >/dev/null 2>&1; sleep 2
check "update-subarray no-write-back on a running volume (mdmon): LD Cache 0x80000000, -E write through" "[ \"\$(ldc mirror)\" = 'cache=0x80000000 ' ] && $M -E $C1 | grep -A12 '^\[mirror\]' | grep -q 'read ahead, write through'"
$M --update-subarray=0 --update=no-read-cache /dev/$CNU >/dev/null 2>&1; $M --update-subarray=0 --update=read-cache /dev/$CNU >/dev/null 2>&1; $M --update-subarray=0 --update=write-back /dev/$CNU >/dev/null 2>&1; sleep 2
check "update-subarray read-cache / write-back: back to the menu default 0xc0000000" "[ \"\$(ldc mirror)\" = 'cache=0xc0000000 ' ]"
check "update-subarray name: refused on a running volume" "refused $M --update-subarray=1 --update=name -N data2 /dev/$CNU >/dev/null 2>&1"
RDU=$(for m in $(ls /sys/block | grep ^md); do grep -qx "external:/$CNU/1" /sys/block/$m/md/metadata_version 2>/dev/null && echo $m; done)
$M -S /dev/$RDU >/dev/null 2>&1; sleep 1
$M --update-subarray=1 --update=name -N data2 /dev/$CNU >/dev/null 2>&1; sleep 2
check "update-subarray name on a stopped volume: DevicePrivate renamed, ID kept" "python3 $TOOLS/amdraid_dump.py $WQ/c/d0.img 2>/dev/null | grep -q \"DevicePrivate='data2'\" && ! python3 $TOOLS/amdraid_dump.py $WQ/c/d0.img 2>/dev/null | grep -q \"DevicePrivate='data'\""
$M --update-subarray=1 --update=name -N data /dev/$CNU >/dev/null 2>&1; sleep 1; $M -I /dev/$CNU >/dev/null 2>&1; sleep 2
# deleting a volume (mdadm --kill-subarray; AMD RC_DeleteLogicalDevice: the LD and transform log go, data stays)
mdsub() { for m in $(ls /sys/block | grep ^md); do grep -qx "external:/$CN/$1" /sys/block/$m/md/metadata_version 2>/dev/null && echo $m; done; }
cgen() { $M -E $C1 | sed -n 's/^ *Generation : //p'; }
nld7() { python3 $TOOLS/amdraid_dump.py $WQ/c/d0.img 2>/dev/null | grep -c '^  LD @'; }
CN=$(cont1)
$M -S /dev/$(mdsub 0) >/dev/null 2>&1; sleep 1
OUT=$($M --kill-subarray=0 /dev/$CN 2>&1)
check "kill-subarray: refused while a later volume runs (renumbering)" "echo \"\$OUT\" | grep -q 'renumber' && [ \$(nld7) = 4 ]"
GK=$(cgen); $M -S /dev/$(mdsub 3) >/dev/null 2>&1; sleep 1
$M --kill-subarray=3 /dev/$CN >/dev/null 2>&1; sleep 2
check "kill-subarray of the stopped last volume, mdmon running: its LD gone, generation +1" "[ \$(nld7) = 3 ] && ! python3 $TOOLS/amdraid_dump.py $WQ/c/d0.img 2>/dev/null | grep -q \"DevicePrivate='stripe'\" && [ \$(cgen) = $((GK + 1)) ] && [ -n \"\$(mdsub 1)\" ]"
for n in 1 2; do $M -S /dev/$(mdsub $n) >/dev/null 2>&1; done
for i in $(seq 1 20); do pgrep -f "mdmon $CN" >/dev/null || break; sleep 1; done
$M --kill-subarray=2 /dev/$CN >/dev/null 2>&1
check "kill-subarray without mdmon: written by mdadm" "[ \$(nld7) = 2 ] && ! python3 $TOOLS/amdraid_dump.py $WQ/c/d0.img 2>/dev/null | grep -q \"DevicePrivate='pick'\" && [ \$(cgen) = $((GK + 2)) ]"
stopall
for d in $CL; do $M -I $d >/dev/null 2>&1; done; sleep 2
check "after deleting: the others reassemble without resync" "[ -n \"\$(mdof raid1)\" ] && [ -n \"\$(mdof raid10)\" ] && [ -z \"\$(mdof raid0)\" ] && ! grep -q -E 'resync|recover' /proc/mdstat"
# the AMD bitmap is only on element [0][0]: without it RAID10 cannot record a crash -> resync on assembly
stopall
for d in $(echo $CL | cut -d' ' -f2-); do $M -I $d >/dev/null 2>&1; done; $M -IRs >/dev/null 2>&1; sleep 3
RD=$(mdof raid10)
check "RAID10 without element [0][0] (no bitmap to tell a crash): resync" "[ -n '$RD' ] && grep -A2 \"^$RD \" /proc/mdstat | grep -q -E 'resync|\[4/3\]' && [ \$(cat /sys/block/$RD/md/sync_action) = resync ]"
stopall
for d in $CL; do sudo losetup -d $d; done
rm -f $WQ/c/*.img
fi

# --- stage 7b: an interrupted initialization (CREATE_REDUNDANCY) resumes from the transform log mark ---
# The log is the same as the rebuild's (rcblob: one for all types), at AllocatedSpace + 0 of the column-0 elements.
tlogd() { sudo dd if=$1 bs=512 skip=$(($2)) count=1 status=none | python3 -c '
import sys, struct
b = sys.stdin.buffer.read()
print("%x %d %d" % (struct.unpack_from("<I", b, 0x18)[0], struct.unpack_from("<Q", b, 0x1c)[0], struct.unpack_from("<I", b, 0x44)[0]))'; }
if want 7b; then
IL=""; for n in 0 1; do truncate -s 4G $WQ/c/i$n.img; IL="$IL $(sudo losetup -f --show $WQ/c/i$n.img)"; done
I1=$(echo $IL | cut -d' ' -f1)
echo 10000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
$M -C /dev/md/amdi -e amd -n 2 $IL --run >/dev/null 2>&1
IN=$(cont1)
$M -C /dev/md/slow -l1 -n2 -z 1G /dev/$IN --run >/dev/null 2>&1
RI=$(mdof raid1)
for i in $(seq 1 60); do [ $(cut -d' ' -f1 /sys/block/$RI/md/sync_completed 2>/dev/null || echo 0) -gt 300000 ] 2>/dev/null && break; sleep 1; done
sleep 1; stopall
IDONE=$(tlogd $I1 0x100000 | cut -d' ' -f2)
check "interrupted initialization: log CREATE_REDUNDANCY, STARTED, checkpoint" "[ \"\$(tlogd $I1 0x100000 | cut -d' ' -f1,3)\" = '5355 1' ] && [ $IDONE -gt 200000 ] && [ $IDONE -lt 2097152 ]"
# I/O fields as rcraid writes them (BIOS menu and rcadm -C): IOStart = ProtectStart, IOSize 0x100, window 0x90 stripes.
# The AMD driver resumes initialization with the log's IOSize, not recomputing it; with 0 it stalls, volume critical
# (tested with rcraid on the emulated board)
tlogio() { sudo dd if=$1 bs=512 skip=$(($2)) count=1 status=none | python3 -c '
import sys, struct
b = sys.stdin.buffer.read()
u = lambda o: struct.unpack_from("<I", b, o)[0]
print(struct.unpack_from("<Q", b, 0x24)[0] == struct.unpack_from("<Q", b, 0x1c)[0], "%x %x %x" % (u(0x2c), u(0x3c), u(0x40)))'; }
check "interrupted initialization: the log's I/O fields as the AMD driver's (IOStart = ProtectStart, IOSize 0x100, 0x90/0x90)" "[ \"\$(tlogio $I1 0x100000)\" = 'True 100 90 90' ]"
for d in $IL; do $M -I $d >/dev/null 2>&1; done; sleep 2
RI=$(mdof raid1)
IPOS=$(cut -d' ' -f1 /sys/block/$RI/md/sync_completed 2>/dev/null)
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
check "reassembled: initialization resumes from the log, not from 0" "[ -n '$IPOS' ] && [ '$IPOS' != none ] && [ $IPOS -ge $IDONE ] && [ $IPOS -lt $((IDONE + 0x10000)) ]"
waitrec; sleep 3
check "initialization end recorded, its log cleared" "python3 $TOOLS/amdraid_dump.py $WQ/c/i0.img 2>/dev/null | grep -q 'last=CREATE_REDUNDANCY state=0xa1a6' && [ \$(python3 $TOOLS/amdraid_dump.py $WQ/c/i0.img 2>/dev/null | grep -c '^  LD @') = 1 ] && [ \"\$(tlogd $I1 0x100000)\" = '0 0 0' ]"
# Resync after a crash, stopped cleanly: AMD bitmap bits only from the mark on (Cover of a 1 GiB volume = 0x36000, 10 bits),
# assembly resyncs from the first bit, not from 0 (it was from 0: emulated board, poweroff in the middle of a resync).
bmb() { sudo dd if=$I1 bs=512 skip=$((0x100080)) count=1 status=none | python3 -c '
import sys
b = sys.stdin.buffer.read()
print(next((i for i in range(4096) if b[i >> 3] >> (i & 7) & 1), -1))'; }
stopall
printf '\xff\x03' | sudo dd of=$I1 bs=1 seek=$((0x100080 * 512)) conv=notrunc status=none
echo 10000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
for d in $IL; do $M -I $d >/dev/null 2>&1; done; sleep 2; RI=$(mdof raid1)
check "crash bits: resync from 0" "[ -n '$RI' ] && [ \$(cat /sys/block/$RI/md/sync_action) = resync ] && [ \$(cut -d' ' -f1 /sys/block/$RI/md/sync_completed) -lt $((0x36000)) ]"
for i in $(seq 1 90); do [ $(cut -d' ' -f1 /sys/block/$RI/md/sync_completed 2>/dev/null || echo 0) -gt $((0x36000 * 2 + 0x8000)) ] 2>/dev/null && break; sleep 1; done
sleep 2; stopall
BF=$(bmb)
check "resync stopped cleanly: bitmap bits from the checkpoint on (first bit $BF)" "[ $BF -ge 1 ] && [ $BF -le 9 ]"
for d in $IL; do $M -I $d >/dev/null 2>&1; done; sleep 2; RI=$(mdof raid1)
RPOS=$(cut -d' ' -f1 /sys/block/$RI/md/sync_completed 2>/dev/null)
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
check "reassembled: resync from the first bit, not from 0" "[ -n '$RPOS' ] && [ '$RPOS' != none ] && [ $RPOS -ge $((BF * 0x36000)) ] && [ $RPOS -lt $((BF * 0x36000 + 0x10000)) ]"
waitrec; sleep 7
check "resync done and clean: bitmap cleared" "[ \$(bmb) = -1 ]"
stopall
for d in $IL; do sudo losetup -d $d; done
rm -f $WQ/c/*.img
fi

# --- stage 7c: initial sync stopped cleanly (the test PC: hddroot RAID1 stopped at ~15 %,
# but CREATE_REDUNDANCY COMPLETED was recorded -> resync did not resume after boot). Stop: (a) the volume, then
# the container; (s) --stop --scan. Expected: initialization not completed, the log at the stop point; assembly
# resyncs from there; at the end COMPLETED, NORMAL, log cleared, md check without mismatches.
tlogmax() { for d in "$@"; do sudo dd if=$d bs=512 skip=$((0x100000)) count=1 status=none | python3 -c '
import sys, struct
b = sys.stdin.buffer.read()
if struct.unpack_from("<I", b, 0x18)[0] == 0x5355 and struct.unpack_from("<I", b, 0x44)[0] == 1:
    print(struct.unpack_from("<Q", b, 0x1c)[0])'; done | sort -n | tail -1; }
initstop() {	# initstop <level> <disks> <a|s>
	local lv=$1 n=$2 how=$3 k=1 SL="" S1 SC LG V P i
	[ $lv = 5 ] && k=$((n - 1))	# md counts RAID5 resync in member sectors, the AMD log in volume sectors
	for i in $(seq 1 $n); do truncate -s 2G $WQ/c/s$i.img; SL="$SL $(sudo losetup -f --show $WQ/c/s$i.img)"; done
	S1=$(echo $SL | cut -d' ' -f1)
	echo 10000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
	$M -C /dev/md/amds -e amd -n $n $SL --run >/dev/null 2>&1
	$M -C /dev/md/ini -l$lv -n$n -z 512M /dev/$(cont1) --run >/dev/null 2>&1
	V=$(mdof raid$lv)
	for i in $(seq 1 60); do [ $(cut -d' ' -f1 /sys/block/$V/md/sync_completed 2>/dev/null || echo 0) -gt 150000 ] 2>/dev/null && break; sleep 1; done
	SC=$(cat /sys/block/$V/md/resync_start)	# resync goes on until the stop: tolerance 0x80000 (--stop --scan with RAID10 went past 0x40000)
	if [ $how = a ]; then $M -S /dev/$V >/dev/null 2>&1; stopall; else $M --stop --scan >/dev/null 2>&1; fi
	# all stopped: by /proc/mdstat, not /sys/block: after --stop --scan the exiting mdmon (open_dev_excl by number
	# 9:N, common mdmon code) opens the already removed container, and the kernel creates an empty mdN again (legacy autoload;
	# seen with a kprobe on md_probe); stopall (variant a) removes it in its second pass
	LG=$(tlogmax $SL)
	check "init raid$lv stopped ($how): not completed, log STARTED at the stop point ($SC)" "! grep -q ^md /proc/mdstat && [ \$(python3 $TOOLS/amdraid_dump.py $WQ/c/s1.img 2>/dev/null | grep -c 'transform=CREATE_REDUNDANCY last=CREATE_REDUNDANCY state=0x0') = 2 ] && [ -n '$LG' ] && [ '$LG' -ge $((SC * k)) ] && [ '$LG' -lt $((SC * k + 0x80000)) ]"
	for d in $SL; do $M -I $d >/dev/null 2>&1; done; sleep 2; V=$(mdof raid$lv)
	P=$(cut -d' ' -f1 /sys/block/$V/md/sync_completed 2>/dev/null)
	echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
	check "init raid$lv ($how) reassembled: resync from the log ($P), not from 0, not done" "[ -n '$LG' ] && [ -n '$P' ] && [ '$P' != none ] && [ '$P' -ge $((LG / k)) ] && [ '$P' -lt $((LG / k + 0x10000)) ]"
	waitrec; sleep 3
	echo check | sudo tee /sys/block/$V/md/sync_action >/dev/null; sleep 1
	for i in $(seq 1 300); do grep -q check /proc/mdstat || break; sleep 1; done
	check "init raid$lv ($how) done: CREATE_REDUNDANCY completed, one LD, NORMAL, log cleared, md check 0" "python3 $TOOLS/amdraid_dump.py $WQ/c/s1.img 2>/dev/null | grep -q 'last=CREATE_REDUNDANCY state=0xa1a6' && [ \$(python3 $TOOLS/amdraid_dump.py $WQ/c/s1.img 2>/dev/null | grep -c '^  LD @') = 1 ] && python3 $TOOLS/amdraid_dump.py $WQ/c/s1.img 2>/dev/null | grep -q 'state=0x200 (NORMAL)' && [ -z \"\$(tlogmax $SL)\" ] && [ \$(cat /sys/block/$V/md/mismatch_cnt) = 0 ]"
	stopall
	for d in $SL; do sudo losetup -d $d; done
	rm -f $WQ/c/s*.img
}
if want 7c; then
for c in "1 2 a" "1 2 s" "5 3 a" "5 3 s" "10 4 a" "10 4 s"; do initstop $c; done
fi

# --- stage 7d: a crash during the initial sync. Model: a write to the volume below the log mark (md active,
# mdmon marks the AMD bitmap), kill -9 mdmon, stop without mdmon: bits in the bitmap, the log at the last checkpoint.
# Expected: resync from 0, not from the log, so writes in flight below the mark are checked too (found in review; before,
# it resumed from the log: a reboot with the root on the volume looked like a crash; now the amdraid-shutdown hook covers it).
# A clean stop in the middle of a sync resumes from the log (stages 7b, 7c). The end is as in 7c.
bmset() { local d; for d in "$@"; do [ "$(sudo dd if=$d bs=512 skip=$((0x100080)) count=1 status=none | od -A n -t x1 -N 1 | xargs)" != 00 ] && return 0; done; return 1; }	# AMD bitmap bits (on [0][0])
initcrash() {	# initcrash <level> <disks>
	local lv=$1 n=$2 k=1 SL="" CNI SC LG V P i
	[ $lv = 5 ] && k=$((n - 1))
	for i in $(seq 1 $n); do truncate -s 2G $WQ/c/s$i.img; SL="$SL $(sudo losetup -f --show $WQ/c/s$i.img)"; done
	echo 10000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
	$M -C /dev/md/amds -e amd -n $n $SL --run >/dev/null 2>&1
	CNI=$(cont1)
	$M -C /dev/md/ini -l$lv -n$n -z 512M /dev/$CNI --run >/dev/null 2>&1
	V=$(mdof raid$lv)
	for i in $(seq 1 60); do [ $(cut -d' ' -f1 /sys/block/$V/md/sync_completed 2>/dev/null || echo 0) -gt 150000 ] 2>/dev/null && [ -n "$(tlogmax $SL)" ] && break; sleep 1; done
	# a write below the mark (md active, mdmon marks the bitmap), then "power lost" for the metadata
	head -c 1M /dev/urandom | sudo dd of=/dev/$V bs=64k seek=16 oflag=direct status=none; sleep 1
	SC=$(cut -d' ' -f1 /sys/block/$V/md/sync_completed)
	for i in $(pgrep -x mdmon); do grep -qa "$CNI" /proc/$i/cmdline && sudo kill -9 $i; done; sleep 1
	stopall
	LG=$(tlogmax $SL)
	check "init raid$lv cut by a crash (md active, mdmon gone): bitmap set, not completed, log STARTED ($LG)" "[ -z \"\$(ls /sys/block | grep ^md)\" ] && bmset $SL && [ \$(python3 $TOOLS/amdraid_dump.py $WQ/c/s1.img 2>/dev/null | grep -c 'transform=CREATE_REDUNDANCY last=CREATE_REDUNDANCY state=0x0') = 2 ] && [ -n '$LG' ] && [ '$LG' -gt 0 ] && [ '$LG' -le $(( (SC + 0x10000) * k )) ]"
	for d in $SL; do $M -I $d >/dev/null 2>&1; done; sleep 2; V=$(mdof raid$lv)
	P=$(cut -d' ' -f1 /sys/block/$V/md/sync_completed 2>/dev/null)
	echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
	check "init raid$lv after a crash (bitmap set), -I per disk: resync from 0 ($P), not from the log ($LG)" "[ -n '$LG' ] && [ -n '$P' ] && [ '$P' != none ] && [ '$P' -lt $((LG / k)) ] && [ '$P' -lt $((0x10000)) ]"
	waitrec; sleep 3
	echo check | sudo tee /sys/block/$V/md/sync_action >/dev/null; sleep 1
	for i in $(seq 1 300); do grep -q check /proc/mdstat || break; sleep 1; done
	for i in $(seq 1 15); do bmset $SL || break; sleep 1; done
	check "init raid$lv after the reboot done: CREATE_REDUNDANCY completed, NORMAL, log and bitmap cleared, md check 0" "python3 $TOOLS/amdraid_dump.py $WQ/c/s1.img 2>/dev/null | grep -q 'last=CREATE_REDUNDANCY state=0xa1a6' && python3 $TOOLS/amdraid_dump.py $WQ/c/s1.img 2>/dev/null | grep -q 'state=0x200 (NORMAL)' && [ -z \"\$(tlogmax $SL)\" ] && ! bmset $SL && [ \$(cat /sys/block/$V/md/mismatch_cnt) = 0 ]"
	stopall
	for d in $SL; do sudo losetup -d $d; done
	rm -f $WQ/c/s*.img
}
if want 7d; then
for c in "1 2" "5 3" "10 4"; do initcrash $c; done
# The same on a dump of the test PC (2026-11-03-r5-after-reboot: 4 HDDs, LBA 0..0x6000 and the hddr5 service area): log
# at 0x0b461200 volume sectors, bitmap all set (reboot without the shutdown hook = crash). Assembly by -I: hddr5 from 0.
RD=$FIXT/2026-11-03-r5-after-reboot
mkdir -p $WQ/r && rm -f $WQ/r/*.img
echo 1 | sudo tee /proc/sys/dev/raid/speed_limit_min /proc/sys/dev/raid/speed_limit_max >/dev/null
RL=""; for s in WX41A685FR98 WES1KE09 JR10044M28WJGM WX61A68KYK45; do
	truncate -s 1000204886016 $WQ/r/$s.img
	xz -dc $RD/$s-lba0-6000.img.xz | dd of=$WQ/r/$s.img conv=notrunc status=none
	for f in $RD/$s-hddr5-alloc-*; do [ -e "$f" ] || continue
		xz -dc $f | dd of=$WQ/r/$s.img bs=512 seek=$(($(echo $f | sed 's/.*alloc-\(0x[0-9a-f]*\)-.*/\1/'))) conv=notrunc status=none; done
	RL="$RL $(sudo losetup -f --show $WQ/r/$s.img)"
done
for d in $RL; do $M -I $d >/dev/null 2>&1; done; sleep 2
RV=$(for m in $(ls /sys/block | grep ^md); do grep -q '^external:/md[0-9]*/7$' /sys/block/$m/md/metadata_version 2>/dev/null && echo $m; done)	# subarray 7 = hddr5
check "PC dump (hddr5, RAID5 at 90% of its init, bitmap set): -I resyncs from 0, not from the log (94570752)" "[ -n '$RV' ] && [ \$(cat /sys/block/$RV/md/resync_start) = 0 ]"
stopall
echo 1000 | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null; echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
for d in $RL; do sudo losetup -d $d; done; rm -rf $WQ/r
fi

# --- stages 7e, 7f: HDDs of the test PC (2026-11-04-rebuild-reboot: LBA 0..0x6000 and 10 MiB before each element's data) ---
# Volumes: 0 = Array 2 (RAID1, BIOS menu), 2 = Array 4 (RAID5, menu, CREATE_REDUNDANCY not started, WES1KE09 0x30), 4 = r1test...
HS4="WX41A685FR98 JR10044M28WJGM WX61A68KYK45 WES1KE09"	# WES1KE09 last
hwimgs() {	# hwimgs [<LD ID> <sectors per element>]...: recreate the test PC images (volumes shrunk by amdshrink), attach; $RL in HS4 order
	stopall; for d in ${RL:-}; do sudo losetup -d $d 2>/dev/null; done
	mkdir -p $WQ/r && rm -rf $WQ/r/*
	tar -C $WQ/r -xJf $FIXT/2026-11-04-rebuild-reboot/hdd-service-areas.tar.xz
	RL=""; for s in $HS4; do
		truncate -s 1000204886016 $WQ/r/$s.img
		dd if=$WQ/r/grab/$s.meta of=$WQ/r/$s.img conv=notrunc status=none
		for f in $WQ/r/grab/$s.[0-9]*; do dd if=$f of=$WQ/r/$s.img bs=512 seek=${f##*.} conv=notrunc status=none; done
		[ $# = 0 ] || amdshrink $WQ/r/$s.img "$@"
		RL="$RL $(sudo losetup -f --show $WQ/r/$s.img)"
	done
	RB=$(basename $(echo $RL | cut -d' ' -f4))
}
sub() { for m in $(ls /sys/block | grep ^md); do grep -q "^external:/md[0-9]*/$1\$" /sys/block/$m/md/metadata_version 2>/dev/null && echo $m; done; }
hcfg() { python3 $TOOLS/amdraid_dump.py $WQ/r/WX41A685FR98.img 2>/dev/null; }
htlog() { sudo dd if=$WQ/r/WX41A685FR98.img bs=512 skip=$(($1)) count=1 status=none | python3 -c '
import sys, struct
b = sys.stdin.buffer.read()
print("%x %d %d" % (struct.unpack_from("<I", b, 0x18)[0], struct.unpack_from("<Q", b, 0x1c)[0], struct.unpack_from("<I", b, 0x44)[0]))'; }

# 7e. Reboot with hddroot at 81% of the WES1KE09 rebuild in Array 2 (log: 208001664); udev runs -I of the disks
# in parallel, the volume started without WES1KE09 -> mdmon added it (activate_spare): it used to restart from 0.
if want 7e; then
echo 1 | sudo tee /proc/sys/dev/raid/speed_limit_min /proc/sys/dev/raid/speed_limit_max >/dev/null
hwimgs
for d in $RL; do $M -I $d >/dev/null 2>&1; sleep 1; done; sleep 3
RV=$(sub 0)
check "PC dump: own member with a recorded rebuild, arriving last (-I), resumes from the log (208001664), not from 0" "[ -n '$RV' ] && [ \"\$(cat /sys/block/$RV/md/dev-$RB/recovery_start 2>/dev/null)\" = 208001664 ]"
# Array 2 is still rebuilding (speed 1): take it down (earlier: by stage 7f's hwimgs), speeds back as before
stopall; for d in $RL; do sudo losetup -d $d; done; rm -rf $WQ/r; RL=
echo 1000 | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null; echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
fi

# 7f. Array 4: uninitialized and missing a member: mdadm does not start it (dirty RAID5 missing a member), --force
# starts it "clean": the recovery of WES1KE09 is the initialization. It was (the test PC): mdmon recorded neither the end
# of the initialization (waited for sync_action idle) nor the rebuild (another transform): after a reboot from 0 and --force again.
# Volumes shrunk (size does not matter here): Array 4 to 2 GiB per element (was 40.7), and so is what md syncs
# along with it after -I of all disks (in turn: shared disks): Array 2 to the mark of its recorded rebuild
# (208001664) + 512 MiB, Array 3 (RAID10 initialization from 32000256) to 8 GiB per element, hddroot (resync from 0)
# to 2 GiB. Stop in the middle: 1M sectors at 200 MB/s (~3 s, ~8 s more to the end); records and marks are the same
if want 7f; then
echo 1 | sudo tee /proc/sys/dev/raid/speed_limit_min /proc/sys/dev/raid/speed_limit_max >/dev/null
hwimgs 5783ed3d9594 0x400000 ddb310ca36ad $((208001664 + 0x100000)) 2b9f6a176b4f 0x1000000 2f3e6ba496f3 0x400000
$M -A /dev/md/hw -e amd $RL >/dev/null 2>&1
$M -A /dev/md/arr4 --uuid=8c02e05b:b48f4fe2:d96db1fb:7b33d897 /dev/md/hw >/dev/null 2>&1
check "Array 4 (uninitialized, member 0x30) is not started without --force" "[ -z \"\$(sub 2)\" ] || [ \"\$(cat /sys/block/\$(sub 2)/md/array_state)\" = inactive ]"
for m in $(ls /sys/block | grep ^md); do grep -q '^external:/md[0-9]*/2$' /sys/block/$m/md/metadata_version 2>/dev/null && $M -S /dev/$m >/dev/null 2>&1; done
$M -A /dev/md/arr4 --force --uuid=8c02e05b:b48f4fe2:d96db1fb:7b33d897 /dev/md/hw >/dev/null 2>&1
for i in $(seq 1 40); do [ $(hcfg | grep -A1 'id=5783ed3d9594' | grep -c 'transform=RESTORE_SEGMENTS') = 2 ] && break; sleep 0.5; done
check "--force: initialization recorded done, the rebuild of WES1KE09 recorded (RESTORE_SEGMENTS in two LD copies, log STARTED)" "[ \$(hcfg | grep -A1 'id=5783ed3d9594' | grep -c 'transform=RESTORE_SEGMENTS last=RESTORE_SEGMENTS') = 2 ] && ! hcfg | grep -A1 'id=5783ed3d9594' | grep -q CREATE_REDUNDANCY && [ \"\$(htlog 0x7b17000 | cut -d' ' -f1,3)\" = '5358 1' ]"
R4=$(sub 2)
echo 200000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
for i in $(seq 1 120); do [ $(cut -d' ' -f1 /sys/block/$R4/md/sync_completed 2>/dev/null || echo 0) -gt 1000000 ] 2>/dev/null && break; sleep 1; done
echo 1 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null; sleep 1
stopall
DONE=$(htlog 0x7b17000 | cut -d' ' -f2)
echo "info: 7f: the rebuild stopped at $DONE of $((3 * 0x400000)) volume sectors"
check "interrupted: the log has the checkpoint" "[ $DONE -gt 0 ]"
for d in $RL; do $M -I $d >/dev/null 2>&1; sleep 1; done; sleep 3
R4=$(sub 2)
check "-I per disk, WES1KE09 last: Array 4 starts (recorded rebuild, no --force), recovery resumes from the log (member sector = whole stripes of the log: / 1536 * 512)" "[ -n '$R4' ] && [ \"\$(cat /sys/block/$R4/md/dev-$RB/recovery_start 2>/dev/null)\" = $((DONE / 1536 * 512)) ]"
echo 1000 | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null; echo 2000000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
waitrec 1800; sleep 2
check "rebuild end recorded: Array 4 NORMAL, one LD, last RESTORE_SEGMENTS, log cleared" "[ \$(hcfg | grep -c 'id=5783ed3d9594') = 1 ] && hcfg | grep -A1 'id=5783ed3d9594' | grep -q 'state=0x200' && hcfg | grep -A1 'id=5783ed3d9594' | grep -q 'transform=- last=RESTORE_SEGMENTS' && [ \"\$(htlog 0x7b17000)\" = '0 0 0' ]"
echo check | sudo tee /sys/block/$R4/md/sync_action >/dev/null; sleep 2; waitrec 1800
check "Array 4 after the rebuild: md check 0 (parity whole)" "[ \$(cat /sys/block/$R4/md/mismatch_cnt) = 0 ]"
stopall
echo 1000 | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null; echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
for d in $RL; do sudo losetup -d $d; done; rm -rf $WQ/r; RL=
fi

# --- stage 7g: the disk with element [0][0] (it holds the AMD bitmap) arrives last (-I one by one; seen on the test PC) ---
# The volume is set up by the first mdadm -I that sees it; without [0][0] it cannot read the bitmap. It was: RAID10 without a readable
# bitmap was declared dirty (clean RAID10s on the test PC resynced after a reboot), and a crash trace in the bitmap, if [0][0]
# arrived last, was lost (the first mdadm set "clean"). Now resync_start is set by the mdadm that starts the volume.
if want 7g; then
GL=""; for n in 0 1 2 3; do truncate -s 3G $WQ/c/g$n.img; GL="$GL $(sudo losetup -f --show $WQ/c/g$n.img)"; done
echo 2000000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
$M -C /dev/md/amdg -e amd -n 4 $GL --run >/dev/null 2>&1
GC=$(cont1)
$M -C /dev/md/g10 -l10 -n4 -z 256M /dev/$GC --run >/dev/null 2>&1
$M -C /dev/md/g1 -l1 -n2 -z 256M /dev/$GC --run >/dev/null 2>&1
waitrec; sleep 6; stopall
G0=$(echo $GL | cut -d' ' -f1)
gal() { sudo python3 $TOOLS/amdraid_dump.py $G0 2>/dev/null | grep -A6 "DevicePrivate='$1'" | grep -m1 "\[0,0\]" | sed 's/.*dev=\([0-9a-f]*\).*alloc=\(0x[0-9a-f]*\)+.*/\1 \2/'; }
read GD10 GA10 <<< "$(gal g10)"
read GD1 GA1 <<< "$(gal g1)"
GLAST=; for d in $GL; do [ "$(sudo python3 $TOOLS/amdraid_dump.py $d 2>/dev/null | grep -m1 -oE 'DeviceID=[0-9a-f]+' | cut -d= -f2)" = "$GD10" ] && GLAST=$d; done
GFIRST=$(for d in $GL; do [ $d != "$GLAST" ] && echo $d; done)
gnc() { sudo dmesg -C; for d in $GFIRST $GLAST; do $M -I $d >/dev/null 2>&1; sleep 0.5; done; sleep 2; sudo dmesg | grep 'not clean' | grep -oE 'md[0-9]+' | sort | paste -sd' '; }
NC=$(gnc); stopall
check "[0][0] last, clean bitmaps: RAID10 and RAID1 start clean (no resync)" "[ -n '$GLAST' ] && [ '$GD10' = '$GD1' ] && [ -z '$NC' ]"
for x in "$GA10" "$GA1"; do printf '\xff\xff\xff\xff' | sudo dd of=$GLAST bs=512 seek=$((x + 0x80)) conv=notrunc status=none; done
NC=$(gnc); stopall
check "[0][0] last, crash bits in its bitmap: both volumes resync" "[ \$(echo '$NC' | wc -w) = 2 ]"
for d in $GL; do sudo losetup -d $d; done; rm -f $WQ/c/g*.img
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
fi

# --- stage 7h: an exact mark on interruption (frozen; likewise md -S and STOP_ARRAY): the log = md's position ---
# It was: only the monitor's checkpoints (every ~1/16 of the volume), the last one when the action was no longer resync/recover.
if want 7h; then
XL=""; for n in 0 1 2; do truncate -s 3G $WQ/c/x$n.img; XL="$XL $(sudo losetup -f --show $WQ/c/x$n.img)"; done
X1=$(echo $XL | cut -d' ' -f1); X2=$(echo $XL | cut -d' ' -f2); X3=$(echo $XL | cut -d' ' -f3)
echo 20000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
$M -C /dev/md/amdx -e amd -n 2 $X1 $X2 --run >/dev/null 2>&1
XC=$(cont1)
$M -C /dev/md/x1 -l1 -n2 -z 1G /dev/$XC --run >/dev/null 2>&1
XR=$(basename $(readlink -f /dev/md/x1*))
sleep 5; echo frozen | sudo tee /sys/block/$XR/md/sync_action >/dev/null; sleep 2
XRS=$(cat /sys/block/$XR/md/resync_start)
check "init frozen: the log has md's very resync_start ($XRS), not an older checkpoint" "[ \"\$(tlogd $X1 0x100000)\" = '5355 $XRS 1' ]"
echo idle | sudo tee /sys/block/$XR/md/sync_action >/dev/null
echo 2000000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null; waitrec; sleep 3
echo 20000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
$M --add /dev/$XC $X3 >/dev/null 2>&1; sleep 2
$M /dev/$XR --fail $X2 >/dev/null 2>&1; sleep 6
echo frozen | sudo tee /sys/block/$XR/md/sync_action >/dev/null; sleep 2
XRC=$(cat /sys/block/$XR/md/dev-$(basename $X3)/recovery_start)
check "rebuild frozen: the log has the spare's very recovery_start ($XRC)" "[ \"\$(tlogd $X1 0x100000)\" = '5358 $XRC 1' ]"
stopall; for d in $XL; do sudo losetup -d $d; done; rm -f $WQ/c/x*.img
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
fi

# --- stage 7i: a crafted packet (found in review): the PD section points outside the packet (pd_offset 0xFFFFFF90:
# off + size overflowed in 32 bits: a read 4 GB past the buffer), packet and commit sums valid. A disk with a RAIDCore label
# is handed by udev to mdadm -I as root: such a packet must be rejected, not parsed.
if want 7i; then
cp --sparse=always $IMG/x399-member0.img $WQ/c/evil.img
python3 - $WQ/c/evil.img <<'PY'
import os, struct, sys
sys.path.insert(0, os.environ["TOOLS"])
import amdraid_dump as a
p = sys.argv[1]
with open(p, 'r+b') as f:
    f.seek(a.LBA_COMMIT * 512); c = bytearray(f.read(512))
    lba, size = struct.unpack_from('<II', c, 8)
    f.seek(lba * 512); g = bytearray(f.read((size + 511) // 512 * 512))
    struct.pack_into('<II', g, 0x24, 0xFFFFFF90, 0x100)
    struct.pack_into('<Q', g, 0, a.rc_sum(g, 0x0c, size - 0x0c))
    struct.pack_into('<Q', c, 0x10, struct.unpack_from('<Q', g, 0)[0])
    struct.pack_into('<Q', c, 0, a.rc_sum(c, 8, 0x1f8))
    f.seek(lba * 512); f.write(g); f.seek(a.LBA_COMMIT * 512); f.write(c)
PY
EV=$(sudo losetup -f --show $WQ/c/evil.img)
$M -E $EV > $TMPW/amd-evil.txt 2>&1; ER=$?
$M -I $EV > /dev/null 2>&1; IR=$?
check "crafted packet (PD section out of the packet): -E and -I refuse it, no crash ($ER, $IR)" "[ $ER -lt 128 ] && [ $IR -lt 128 ] && grep -q 'Configuration : unreadable' $TMPW/amd-evil.txt"
stopall; sudo losetup -d $EV; rm -f $WQ/c/evil.img
fi

# --- stage 7j: writing the configuration to one disk failed (found in review): the others get it, this one stays
# stale (as with IMSM); it was: the whole write failed, and a partial commit made exactly the written disks stale.
wgen() { $M -E $1 2>/dev/null | awk '/Generation/{print $NF; exit}'; }
if want 7j; then
WL=""; for n in 0 1; do truncate -s 3G $WQ/c/w$n.img; WL="$WL $(sudo losetup -f --show $WQ/c/w$n.img)"; done
W0=$(echo $WL | cut -d' ' -f1); W1=$(echo $WL | cut -d' ' -f2)
echo 2000000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
$M -C /dev/md/amdw -e amd -n 2 $WL --run >/dev/null 2>&1
WC=$(basename $(readlink -f /dev/md/amdw))
$M -C /dev/md/wv -l1 -n2 -z 512M /dev/$WC --run >/dev/null 2>&1; waitrec; sleep 3
G0=$(wgen $W0); G1=$(wgen $W1)
sudo dmesg -C; sudo blockdev --setro $W1
$M --update-subarray=0 --update=write-back /dev/$WC >/dev/null 2>&1; sleep 2
sudo blockdev --setrw $W1
check "config write fails on one disk: the other gets it (gen $G0 -> $(wgen $W0)), that one stays ($G1 -> $(wgen $W1)), logged" "[ \$(wgen $W0) -gt $G0 ] && [ \$(wgen $W1) = $G1 ] && sudo dmesg | grep -q 'mdmon: amd: cannot write the configuration to'"
stopall; for d in $WL; do sudo losetup -d $d; done; rm -f $WQ/c/w*.img
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
fi

# --- stage 7k: a volume the monitor let go (stopped; clean on SIGTERM) stays in the list without a container
# until the manager removes it; amd_sync_metadata skips it. On the test PC (8 HDD volumes) mdmon crashed
# (NULL->sb in amd_active_vol) when volumes were stopped one by one and when mdmon@initrd handed the container to mdmon@.
if want 7k; then
hwimgs
echo 0 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null	# no syncs: only the volume states
sudo dmesg -C
$M -A /dev/md/hdd -e amd --force $RL >/dev/null 2>&1; $M -I /dev/md/hdd >/dev/null 2>&1; sleep 2
HC=$(basename $(readlink -f /dev/md/hdd))
LV=$(for m in /sys/block/md*/md/metadata_version; do grep -q "^external:/$HC/" $m && { m=${m#/sys/block/}; echo ${m%%/*}; }; done)
OLDP=$(sudo cat /run/mdadm/$HC.pid 2>/dev/null)
for v in $LV; do sudo dd if=/dev/zero of=/dev/$v bs=4k count=64 oflag=direct status=none 2>/dev/null & done
sudo -E ./mdmon --takeover $HC; wait; sleep 3
NEWP=$(sudo cat /run/mdadm/$HC.pid 2>/dev/null)
for v in $LV; do $M -S /dev/$v >/dev/null 2>&1; done; sleep 1
NV=$(echo $LV | wc -w)
check "mdmon --takeover under writes, then $NV volumes stopped one by one: no mdmon crash (mdmon $OLDP -> $NEWP)" "[ $NV -ge 8 ] && [ -n '$NEWP' ] && [ '$NEWP' != '$OLDP' ] && ! sudo dmesg | grep -q 'mdmon\[[0-9]*\]: segfault'"
stopall; for d in $RL; do sudo losetup -d $d; done; rm -rf $WQ/r; RL=
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
fi

# --- stage 8: XPG's Legacy record broken by the RAIDXpert2 BIOS menu (MSI X870E, 2026-11-02-msi-x870e-hdd, config 19) ---
# mdmon repairs it as tools/amdraid_fix_legacy.py does (it restored booting from XPG on the test PC): packet = the script's.
if want 8; then
HD=$FIXT/2026-11-02-msi-x870e-hdd; HS="WX41A685FR98 WES1KE09 JR10044M28WJGM WX61A68KYK45"
mkdir -p $WQ/l/exp && rm -f $WQ/l/*.img $WQ/l/exp/*.img
HL=""; for s in $HS; do
	truncate -s $((1953525168 * 512)) $WQ/l/$s.img
	xz -dc $HD/$s-lba0-6000.img.xz | dd of=$WQ/l/$s.img conv=notrunc status=none
	xz -dc $HD/$s-lba0-6000.img.xz > $WQ/l/exp/$s.img
	HL="$HL $(sudo losetup -f --show $WQ/l/$s.img)"
done
python3 $TOOLS/amdraid_fix_legacy.py $WQ/l/exp/*.img --write >/dev/null
lcfg() { python3 $TOOLS/amdraid_dump.py $WQ/l/$1.img --brief 2>/dev/null; }
H1=$(echo $HL | cut -d' ' -f1)
check "examine reports the broken Legacy records" "$M -E $H1 | grep -q 'Legacy records : 2 broken'"
for d in $HL; do $M -I $d >/dev/null 2>&1; done; sleep 3
check "mdmon repaired it: config 20 on all four disks, packet = amdraid_fix_legacy.py" "(for s in $HS; do [ -n \"\$(qsum $WQ/l/\$s.img)\" ] && [ \"\$(qsum $WQ/l/\$s.img)\" = \"\$(qsum $WQ/l/exp/\$s.img)\" ] && lcfg \$s | grep -q 'конфигурация 20' || exit 1; done)"
check "Legacy LD of XPG NORMAL on its port, extra one gone" "lcfg WES1KE09 | grep -q '7d730af340a81267 LEGACY NORMAL .*\[1:1267\]' && [ \$(lcfg WES1KE09 | grep -c 'Array .* LEGACY') = 1 ]"
stopall
check "repaired: examine is quiet" "! $M -E $H1 | grep -q 'Legacy records'"
for d in $HL; do sudo losetup -d $d; done
rm -rf $WQ/l
fi

# --- stage 9: start without a member (mdadm -R / mdadm-last-resort), write, the disk returns ---
# A missing member is recorded as failed before the first write (otherwise both halves look current),
# a returning disk is rebuilt into its slot (as IMSM). Found on the emulated board: booting CachyOS without nvme1.
mgen() { $M -E $1 | sed -n 's/^ *Generation : //p'; }
if want 9; then
stopall
mkdir -p $WQ/m && rm -f $WQ/m/*.img
truncate -s 1G $WQ/m/m0.img $WQ/m/m1.img
G0=$(sudo losetup -f --show $WQ/m/m0.img); G1=$(sudo losetup -f --show $WQ/m/m1.img)
$M -C /dev/md/amdm -e amd -n 2 $G0 $G1 --run >/dev/null 2>&1
$M -C /dev/md/mir -e amd -l1 -n2 -z 256M $G0 $G1 --run >/dev/null 2>&1; sleep 1; waitrec; sleep 2
mdump() { python3 $TOOLS/amdraid_dump.py $WQ/m/$1.img 2>/dev/null; }
GEN=$(mgen $G0)
stopall
$M -I $G0 >/dev/null 2>&1; $M -IRs >/dev/null 2>&1; sleep 2
RG=$(mdof raid1)
check "started without a member: its failure recorded before use (CRITICAL, only on the disk present)" "[ -n '$RG' ] && grep -q '\[2/1\] \[U_\]' /proc/mdstat && $M -E $G0 | grep -q 'State : 0x201' && $M -E $G0 | grep -q 'Member   1 .*out of service: offline' && [ \$(mgen $G0) -gt $GEN ] && [ \$(mgen $G1) = $GEN ]"
head -c 32M /dev/urandom > $TMPW/amd-deg.bin
sudo dd if=$TMPW/amd-deg.bin of=/dev/$RG bs=1M oflag=direct status=none; sync; sleep 1
stopall
$M -I $G1 >/dev/null 2>&1
check "the stale member alone: nothing started" "[ \$(active raid1) = 0 ]"
$M -I $G0 >/dev/null 2>&1; sleep 2; RG=$(mdof raid1)
check "assembled with the current disk only, stale one rebuilt in its slot" "[ -n '$RG' ] && [ \"\$(cat /sys/block/$RG/md/rd0/state)\" = in_sync ] && grep -q -E 'recover|\[UU\]' <(grep -A2 \"^$RG \" /proc/mdstat)"
waitrec; sleep 3
check "rebuild recorded and ended: same generation on both, NORMAL, one LD, RESTORE completed" "[ \$(mgen $G0) = \$(mgen $G1) ] && $M -E $G1 | grep -q 'State : 0x200' && ! $M -E $G1 | grep -q 'out of service' && [ \$(mdump m1 | grep -c '^  LD @') = 1 ] && mdump m1 | grep -q 'last=RESTORE_SEGMENTS state=0xa1a6'"
check "data written degraded is on both mirrors" "cmp -s <(sudo dd if=/dev/$RG bs=1M count=32 status=none) $TMPW/amd-deg.bin && cmp -s <(sudo dd if=$G0 bs=512 skip=\$(cat /sys/block/$RG/md/rd0/offset) count=$((256 * 2048)) status=none) <(sudo dd if=$G1 bs=512 skip=\$(cat /sys/block/$RG/md/rd1/offset) count=$((256 * 2048)) status=none)"
stopall
# the disk comes back to the running volume (udev -I after start)
$M -I $G0 >/dev/null 2>&1; $M -IRs >/dev/null 2>&1; sleep 2; RG=$(mdof raid1)
sudo dd if=$TMPW/amd-deg.bin of=/dev/$RG bs=1M seek=64 oflag=direct status=none; sync; sleep 1
$M -I $G1 >/dev/null 2>&1; sleep 1; waitrec; sleep 3
for i in $(seq 1 60); do [ "$(mgen $G0)" = "$(mgen $G1)" ] && $M -E $G0 | grep -q "State : 0x200" && ! grep -q recover /proc/mdstat && break; sleep 1; done
check "member back while running: rebuilt, NORMAL, mirrors equal" "grep -q '\[2/2\] \[UU\]' <(grep -A1 \"^$RG \" /proc/mdstat) && $M -E $G0 | grep -q 'State : 0x200' && [ \$(mgen $G0) = \$(mgen $G1) ] && cmp -s <(sudo dd if=$G0 bs=512 skip=\$(cat /sys/block/$RG/md/rd0/offset) count=$((256 * 2048)) status=none) <(sudo dd if=$G1 bs=512 skip=\$(cat /sys/block/$RG/md/rd1/offset) count=$((256 * 2048)) status=none)"
stopall
for d in $G0 $G1; do $M -I $d >/dev/null 2>&1; done; sleep 2
check "reassembled in step: no resync, no recovery" "grep -q '\[2/2\] \[UU\]' /proc/mdstat && ! grep -q -E 'resync|recover' /proc/mdstat"
# failure on errors → member taken out of the container (mdadm --remove; udev -If likewise): mdmon used to crash (no remove_from_super)
RG=$(mdof raid1); CN=$(cut -d/ -f2 /sys/block/$RG/md/metadata_version); GB=$(basename $G1); MP=$(pgrep -f "mdmon $CN")
$M /dev/$RG --fail $G1 >/dev/null 2>&1
# mdmon records the failure and takes the disk out of the volume; --remove from the container once it is out (wait on the condition)
for i in $(seq 1 30); do grep "^$RG " /proc/mdstat | grep -q $GB || break; sleep 0.5; done
for i in $(seq 1 30); do $M /dev/$CN --remove $G1 >/dev/null 2>&1; grep "^$CN " /proc/mdstat | grep -q $GB || break; sleep 0.5; done
check "failed member taken out of the container: mdmon stays" "[ -n '$MP' ] && [ \"\$(pgrep -f 'mdmon $CN')\" = '$MP' ] && ! grep \"^$CN \" /proc/mdstat | grep -q $GB"
$M -I $G1 >/dev/null 2>&1; sleep 3
check "failed member back through udev: in the container, not rebuilt onto, -E says failed" "grep \"^$CN \" /proc/mdstat | grep -q $GB && [ \"\$(pgrep -f 'mdmon $CN')\" = '$MP' ] && ! grep -q recover /proc/mdstat && $M -E $G0 | grep -q 'Member   1 .*out of service: failed'"

# --- stage 10: mdadm --add to the container (the generic code wipes the disk first: Kill) ---
# without mdmon: refused before the wipe; a former member: rebuilt in its slot; a new disk: AMD global spare
# (as the BIOS menu: Initialize + Assign Global Hot Spare, snapshot 11), rebuild onto it.
# (uses the volumes of stage 9: runs together with it, want 9)
mir() { RG=$(mdof raid1); cmp -s <(sudo dd if=$G0 bs=512 skip=$(cat /sys/block/$RG/md/rd0/offset) count=$((256 * 2048)) status=none) <(sudo dd if=$1 bs=512 skip=$(cat /sys/block/$RG/md/rd1/offset) count=$((256 * 2048)) status=none); }
$M /dev/$CN --remove $G1 >/dev/null 2>&1; $M -S /dev/$RG >/dev/null 2>&1
for i in $(seq 1 20); do pgrep -f "mdmon $CN" >/dev/null || break; sleep 1; done
OUT=$($M /dev/$CN --add $G1 2>&1)
check "--add without mdmon: refused before mdadm wipes the disk" "echo \"\$OUT\" | grep -q 'mdmon records a new disk' && $M -E $G1 | grep -q 'Magic : RAIDCore'"
$M -IRs >/dev/null 2>&1; sleep 2; RG=$(mdof raid1)
sudo dd if=$TMPW/amd-deg.bin of=/dev/$RG bs=1M seek=128 oflag=direct status=none; sync
OUT=$($M /dev/$CN --add $G1 2>&1); sleep 2; waitrec; sleep 3
check "--add of the failed member: rebuilt in its slot, NORMAL, same generation, mirrors equal" "echo \"\$OUT\" | grep -q 'former member' && [ \$(mgen $G0) = \$(mgen $G1) ] && $M -E $G1 | grep -q 'State : 0x200' && ! $M -E $G0 | grep -q 'out of service' && mir $G1"
# a disk with a partition table (Legacy: no RAIDCore label): refused before the wipe, table intact
truncate -s 1G $WQ/m/m3.img; G3=$(sudo losetup -f --show $WQ/m/m3.img)
python3 -c '
import struct, sys
b = bytearray(512); b[0x1be + 4] = 0x83; struct.pack_into("<II", b, 0x1be + 8, 2048, 100000); b[0x1fe:0x200] = b"\x55\xaa"
open(sys.argv[1], "r+b").write(b)' $WQ/m/m3.img
OUT=$($M /dev/$CN --add $G3 2>&1)
check "--add of a disk with a partition table: refused, table intact" "echo \"\$OUT\" | grep -q 'partition table' && [ \"\$(sudo dd if=$G3 bs=1 skip=$((0x1c2)) count=1 status=none | od -A n -t x1 | tr -d ' ')\" = 83 ]"
sudo losetup -d $G3
truncate -s 1G $WQ/m/m2.img; G2=$(sudo losetup -f --show $WQ/m/m2.img)
$M /dev/$RG --fail $G1 >/dev/null 2>&1; sleep 3; $M /dev/$CN --remove $G1 >/dev/null 2>&1; sleep 1
OUT=$($M /dev/$CN --add $G2 2>&1); sleep 2; waitrec; sleep 3
check "--add of a blank disk: AMD global spare (label and PD SpareInfo 0x100, next port)" "echo \"\$OUT\" | grep -q 'global hot spare' && mdump m2 | grep -q '+0x34=0x100' && mdump m2 | grep -q 'handle=3/1 RAIDCORE_DISK ONLINE .* spare=0x100 .*этот диск'"
check "rebuilt onto the spare: NORMAL, it is member 1, mirrors equal" "$M -E $G2 | grep -q 'State : 0x200' && $M -E $G2 | grep -q 'Member   1 .*handle 3 .*this disk' && [ \$(mgen $G0) = \$(mgen $G2) ] && mir $G2"
stopall
for d in $G0 $G2; do $M -I $d >/dev/null 2>&1; done; sleep 2
check "reassembled with the spare in step: no resync, no recovery" "grep -q '\[2/2\] \[UU\]' /proc/mdstat && ! grep -q -E 'resync|recover' /proc/mdstat"
stopall
sudo losetup -d $G2
sudo losetup -d $G0 $G1; rm -rf $WQ/m $TMPW/amd-deg.bin
fi

# --- stage 10b: a disk the Windows driver ran without (the Windows driver in a VM, runs W1–W5; helpers/winsim.py) ---
# drop: Windows removed the PD of the absent disk, its elements offline handle 0x8fff, 0x30. mdmon rebuilds the returned disk
# in its slot (as before), puts the PD back into the packet and gives the element the PD port (before: the PD was not restored).
# forget: Windows saw the return (element IDs zeroed, PD in place): not rebuilt onto without a spare role, as with AMD;
# mdadm --add of such a disk: a global spare (as rcadm), rebuild onto it.
if want 10b; then
stopall
mkdir -p $WQ/j && rm -rf $WQ/j/*
truncate -s 1G $WQ/j/j0.img $WQ/j/j1.img $WQ/j/j2.img
J0=$(sudo losetup -f --show $WQ/j/j0.img); J1=$(sudo losetup -f --show $WQ/j/j1.img); J2=$(sudo losetup -f --show $WQ/j/j2.img)
$M -C /dev/md/amdj -e amd -n 3 $J0 $J1 $J2 --run >/dev/null 2>&1
$M -C /dev/md/jmir -e amd -l1 -n2 -z 128M $J0 $J1 --run >/dev/null 2>&1; sleep 1; waitrec; sleep 2
jdump() { python3 $TOOLS/amdraid_dump.py $WQ/j/$1.img 2>/dev/null; }
jid() { jdump $1 | sed -n 's/.*DeviceID=\([0-9a-f]*\).*/\1/p' | head -1; }
jpd() { jdump $1 | grep -E "^  @\+0x[0-9a-f]+ dev=$2 "; }		# PD of disk $2 in the live packet of image $1
jel() { jdump $1 | grep -E "^ +\[0,1\] dev=$2 "; }		# element [0,1] of the volume
jmir() { local R=$(mdof raid1); cmp -s <(sudo dd if=$J0 bs=512 skip=$(cat /sys/block/$R/md/rd0/offset) count=$((128 * 2048)) status=none) <(sudo dd if=$J1 bs=512 skip=$(cat /sys/block/$R/md/rd1/offset) count=$((128 * 2048)) status=none); }
ID1=$(jid j1)
stopall
$M -I $J0 >/dev/null 2>&1; $M -I $J2 >/dev/null 2>&1; $M -IRs >/dev/null 2>&1; sleep 2; RJ=$(mdof raid1)
head -c 32M /dev/urandom > $TMPW/amd-j.bin
sudo dd if=$TMPW/amd-j.bin of=/dev/$RJ bs=1M oflag=direct status=none; sync; sleep 1
stopall
sudo python3 $HLP/winsim.py drop $ID1 $WQ/j/j0.img $WQ/j/j2.img >/dev/null
check "winsim drop: no PD of the absent disk, its element offline handle 0x8fff with 0x30" "[ -n '$ID1' ] && ! jpd j0 $ID1 >/dev/null && jel j0 $ID1 | grep -q 'handle=36863 .*flags=0x30'"
mkdir -p $WQ/j/drop && cp --sparse=always $WQ/j/j?.img $WQ/j/drop/
# the disk comes back to the running volume (udev -I): ATTACH used to refuse (no PD)
$M -I $J0 >/dev/null 2>&1; $M -I $J2 >/dev/null 2>&1; $M -IRs >/dev/null 2>&1; sleep 2; RJ=$(mdof raid1)
$M -I $J1 >/dev/null 2>&1; sleep 2; waitrec; sleep 3
for i in $(seq 1 30); do jpd j0 $ID1 >/dev/null && ! grep -q recover /proc/mdstat && break; sleep 1; done
P1=$(jpd j0 $ID1 | sed -n 's/.* handle=\([0-9]*\)\/.*/\1/p')
check "dropped member back while running: rebuilt in its slot, PD back (RAIDCore disk, Features 0x2300 of a disk without IDENTIFY), element has its port, NORMAL" "[ -n '$RJ' ] && grep -q '\[2/2\] \[UU\]' <(grep -A1 \"^$RJ \" /proc/mdstat) && jpd j0 $ID1 | grep -q 'RAIDCORE_DISK ONLINE.* features=0x2300' && [ -n '$P1' ] && jel j0 $ID1 | grep -q \"handle=$P1 .*flags=0x0\$\" && $M -E $J0 | grep -q 'State : 0x200'"
check "... the same packet on all three, mirrors equal, data written without it intact" "[ \$(mgen $J0) = \$(mgen $J1) ] && [ \$(mgen $J0) = \$(mgen $J2) ] && jmir && cmp -s <(sudo dd if=/dev/$RJ bs=1M count=32 iflag=direct status=none) $TMPW/amd-j.bin"
stopall
for d in $J0 $J1 $J2; do $M -I $d >/dev/null 2>&1; done; sleep 2
check "reassembled in step: no resync, no recovery" "grep -q '\[2/2\] \[UU\]' /proc/mdstat && ! grep -q -E 'resync|recover' /proc/mdstat"
stopall
# the same when the whole container is assembled at once (-A, as on the test PC)
sudo losetup -d $J0 $J1 $J2; cp --sparse=always $WQ/j/drop/j?.img $WQ/j/
J0=$(sudo losetup -f --show $WQ/j/j0.img); J1=$(sudo losetup -f --show $WQ/j/j1.img); J2=$(sudo losetup -f --show $WQ/j/j2.img)
$M -A /dev/md/amdj -e amd $J0 $J1 $J2 >/dev/null 2>&1; sleep 1; $M -I /dev/md/amdj >/dev/null 2>&1; sleep 2; waitrec; sleep 3
for i in $(seq 1 30); do jpd j0 $ID1 >/dev/null && ! grep -q recover /proc/mdstat && break; sleep 1; done
P1=$(jpd j0 $ID1 | sed -n 's/.* handle=\([0-9]*\)\/.*/\1/p')
check "dropped member at assembly (-A): rebuilt in its slot, PD back, element has its port, NORMAL, mirrors equal" "jpd j0 $ID1 | grep -q 'RAIDCORE_DISK ONLINE' && [ -n '$P1' ] && jel j0 $ID1 | grep -q \"handle=$P1 .*flags=0x0\$\" && $M -E $J0 | grep -q 'State : 0x200' && [ \$(mgen $J0) = \$(mgen $J1) ] && jmir"
stopall
# Windows saw the return: element without ID; the disk is not a spare
sudo python3 $HLP/winsim.py forget $ID1 $WQ/j/j0.img $WQ/j/j1.img $WQ/j/j2.img >/dev/null
for d in $J0 $J2 $J1; do $M -I $d >/dev/null 2>&1; done; $M -IRs >/dev/null 2>&1; sleep 5; RJ=$(mdof raid1)
JN=$(cut -d/ -f2 /sys/block/$RJ/md/metadata_version 2>/dev/null)
check "forgotten member (element without ID, disk no spare): not rebuilt onto, as the AMD driver" "[ -n '$RJ' ] && grep -q '\[2/1\] \[U_\]' <(grep -A1 \"^$RJ \" /proc/mdstat) && ! grep -q recover /proc/mdstat && jpd j0 $ID1 | grep -q 'spare=0x0 '"
$M /dev/$JN --remove $J1 >/dev/null 2>&1; sleep 1
OUT=$($M /dev/$JN --add $J1 2>&1); sleep 2; waitrec; sleep 3
for i in $(seq 1 30); do $M -E $J0 | grep -q 'State : 0x200' && ! grep -q recover /proc/mdstat && break; sleep 1; done
check "--add of it: a global spare again (label and PD 0x100), rebuilt onto, NORMAL, mirrors equal, data intact" "echo \"\$OUT\" | grep -q 'added back as an AMD global hot spare' && jdump j1 | grep -q '+0x34=0x100' && jpd j0 $ID1 | grep -q 'spare=0x100 ' && jel j0 $ID1 | grep -q 'flags=0x0\$' && $M -E $J0 | grep -q 'State : 0x200' && jmir && cmp -s <(sudo dd if=/dev/$RJ bs=1M count=32 iflag=direct status=none) $TMPW/amd-j.bin"
stopall
sudo losetup -d $J0 $J1 $J2; rm -rf $WQ/j $TMPW/amd-j.bin
fi

# --- stage 10c: RAID5 under mdmon (md raid5 right-asymmetric; layout and parity checked against the Windows driver) ---
# creation as rcadm does (RAID50 First=1), initialization by resync, AMD bitmap, failure, writes without a member,
# rebuild onto a global spare interrupted midway: the log is in volume sectors (= md mark x data disks)
if want 10c; then
mkdir -p $WQ/p && rm -f $WQ/p/*.img
PL=""; for n in 0 1 2 3; do truncate -s 1G $WQ/p/p$n.img; PL="$PL $(sudo losetup -f --show $WQ/p/p$n.img)"; done
set -- $PL; P0=$1; P1=$2; P2=$3; P3=$4
pdump() { python3 $TOOLS/amdraid_dump.py $WQ/p/p0.img 2>/dev/null; }
pld() { pdump | sed -n "/DevicePrivate='par'/,/ref id/p"; }
palloc() { pld | grep -m1 '\[0,0\]' | sed 's/.*alloc=\(0x[0-9a-f]*\)+.*/\1/'; }
pbm() { sudo dd if=$P0 bs=512 skip=$(( $(palloc) + 0x80 )) count=1 status=none | od -A n -t x1 | tr -d ' \n' | grep -q '[1-9a-f]'; }
ptlog() { sudo dd if=$P0 bs=512 skip=$(( $(palloc) )) count=1 status=none | python3 -c '
import sys, struct
b = sys.stdin.buffer.read()
print("%x %d %d" % (struct.unpack_from("<I", b, 0x18)[0], struct.unpack_from("<Q", b, 0x1c)[0], struct.unpack_from("<I", b, 0x44)[0]))'; }
ptlx() { sudo dd if=$P0 bs=512 skip=$(( $(palloc) )) count=1 status=none | python3 -c '
import sys, struct
b = sys.stdin.buffer.read()
print("%d %d %x %d" % (struct.unpack_from("<Q", b, 0x24)[0], struct.unpack_from("<I", b, 0x2c)[0], struct.unpack_from("<I", b, 0x30)[0], struct.unpack_from("<I", b, 0x3c)[0]))'; }
pidle() { sleep 1; while [ "$(cat /sys/block/$1/md/sync_action)" != idle ]; do sleep 1; done; }
pcheck() { echo check | sudo tee /sys/block/$1/md/sync_action >/dev/null && pidle $1 && [ "$(cat /sys/block/$1/md/mismatch_cnt)" = 0 ]; }
$M -C /dev/md/amdp -e amd -n 3 $P0 $P1 $P2 --run >/dev/null 2>&1
PN=$(cont1)
$M -C /dev/md/par -l5 -n3 -c 128 -z 256M /dev/$PN --run >/dev/null 2>&1; sleep 1; R5=$(mdof raid5)
check "RAID5 created under mdmon: right-asymmetric, 128K, 2 x 256 MiB" "[ -n '$R5' ] && [ \$(cat /sys/block/$R5/md/layout) = 1 ] && [ \$(cat /sys/block/$R5/md/chunk_size) = 131072 ] && [ \$(cat /sys/block/$R5/size) = $((512 * 2048)) ] && grep -q '^external:/$PN/0' /sys/block/$R5/md/metadata_version"
check "RAID5 LD as rcadm writes one: RAID50 First=1 Second=3, CTS 2, bitmap" "pld | grep -q 'type=0x1bf5' && pld | grep -q 'First=1 Second=3' && pld | grep -q 'CacheTagSize=2' && pld | grep -q 'attr=0x1'"
check "RAID5 layout refused unless right-asymmetric" "$M -C /dev/md/bad -l5 -n3 --layout=ls -z 64M /dev/$PN --run 2>&1 | grep -q 'right-asymmetric' && [ ! -e /dev/md/bad ]"
waitrec; sleep 3
check "md initialized it: one LD, CREATE_REDUNDANCY completed, NORMAL, parity in step" "[ \$(pdump | grep -c \"DevicePrivate='par'\") = 1 ] && pld | grep -q 'last=CREATE_REDUNDANCY state=0xa1a6' && pld | grep -q 'state=0x200' && pcheck $R5"
head -c 64M /dev/urandom > $TMPW/amd-r5.bin
check "writing: AMD bitmap dirty; idle again: clean" "sudo dd if=$TMPW/amd-r5.bin of=/dev/$R5 bs=1M oflag=direct status=none && pbm && for i in \$(seq 15); do pbm || break; sleep 1; done && ! pbm"
stopall
for d in $P0 $P1 $P2; do $M -I $d >/dev/null 2>&1; done; sleep 2; R5=$(mdof raid5)
check "reassembled clean: no resync, data in place" "[ -n '$R5' ] && ! grep -q -E 'resync|recover' /proc/mdstat && cmp -s <(sudo dd if=/dev/$R5 bs=1M count=64 iflag=direct status=none) $TMPW/amd-r5.bin"
$M /dev/$R5 --fail $P1 >/dev/null 2>&1; sleep 3
head -c 16M /dev/urandom > $TMPW/amd-r5b.bin; sudo dd if=$TMPW/amd-r5b.bin of=/dev/$R5 bs=1M seek=100 oflag=direct status=none; sync
check "member failed: 0x10 recorded, CRITICAL; degraded data reads back" "pld | grep '\[0,1\]' | grep -q 'flags=0x10' && pld | grep -q 'state=0x201' && cmp -s <(sudo dd if=/dev/$R5 bs=1M count=64 iflag=direct status=none) $TMPW/amd-r5.bin && cmp -s <(sudo dd if=/dev/$R5 bs=1M skip=100 count=16 iflag=direct status=none) $TMPW/amd-r5b.bin"
$M /dev/$PN --remove $P1 >/dev/null 2>&1; sleep 1
echo 5000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
$M /dev/$PN --add $P3 >/dev/null 2>&1; sleep 2
for i in $(seq 1 90); do [ $(cut -d' ' -f1 /sys/block/$R5/md/sync_completed 2>/dev/null || echo 0) -gt 200000 ] 2>/dev/null && break; sleep 1; done
SPOS=$(cut -d' ' -f1 /sys/block/$R5/md/sync_completed 2>/dev/null)
stopall
set -- $(ptlog); TT=$1; TPS=$2; TST=$3; TLX=$(ptlx)
# the log is where md stopped the rebuild (member x 2, whole stripes): not before the position read before
# the stop, not beyond a few seconds of progress (5 MB/s) after it
check "rebuild stopped midway: log RESTORE_SEGMENTS, at the very place md stopped (volume sector = member x 2, whole stripes)" "[ $TT = 5358 ] && [ $TST = 1 ] && [ $TPS -ge $(( ${SPOS:-0} / 256 * 512 )) ] && [ $TPS -le $(( (${SPOS:-0} + 40960) * 2 )) ] && [ $((TPS % 512)) = 0 ]"
for d in $P0 $P2 $P3; do $M -I $d >/dev/null 2>&1; done; sleep 3; R5=$(mdof raid5)
check "RAID5 log as rcraid.sys fills it: IOStart = ProtectStart, one chunk, flags 0x241, protect window 0x9000 / stripe" "[ \"$TLX\" = \"$TPS 256 241 72\" ]"
check "reassembled: md resumes the recovery from the log (member sector = log / 2)" "[ -n '$R5' ] && { [ \$(cat /sys/block/$R5/md/rd1/recovery_start 2>/dev/null || echo 0) = $((TPS / 2)) ] || [ \$(cut -d' ' -f1 /sys/block/$R5/md/sync_completed) -ge $((TPS / 2)) ]; }"
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
waitrec; sleep 3
check "rebuilt onto the spare: NORMAL, one LD, RESTORE completed, log cleared, parity in step, data intact" "pld | grep -q 'state=0x200' && [ \$(pdump | grep -c \"DevicePrivate='par'\") = 1 ] && pld | grep -q 'last=RESTORE_SEGMENTS state=0xa1a6' && [ \"\$(ptlog)\" = '0 0 0' ] && pcheck $R5 && cmp -s <(sudo dd if=/dev/$R5 bs=1M count=64 iflag=direct status=none) $TMPW/amd-r5.bin && cmp -s <(sudo dd if=/dev/$R5 bs=1M skip=100 count=16 iflag=direct status=none) $TMPW/amd-r5b.bin"
stopall
for d in $PL; do sudo losetup -d $d; done; rm -rf $WQ/p $TMPW/amd-r5.bin $TMPW/amd-r5b.bin
fi

# --- stage 11: dedicated spares and RAIDABLE (the real RAIDCoreDxe on the emulated board: fixture 2026-11-06-qemu-spares-raidable) ---
# Images of 64 GiB each, as on the emulated board (LBA 0…0x5FFF from the snapshot), on compressed btrfs: md writes whole mirrors.
SD=$FIXT/2026-11-06-qemu-spares-raidable
DN="sata0 sata1 sata2 sata3 sata4 nvme0"
dset() {	# dset <snapshot> [<LD ID> <sectors per element>]…: recreate images $WQ/d/<disk>.img (volumes shrunk), attach them
	stopall; for n in $DN; do [ -e $WQ/d/$n.img ] && for l in $(sudo losetup -j $WQ/d/$n.img | cut -d: -f1); do sudo losetup -d $l; done; done
	rm -rf $WQ/d; mkdir -p $WQ/d; local T=$(mktemp -d) b n
	tar -C $T -xJf $SD/$1.tar.xz
	for b in $T/*/*.bin; do n=$(basename $b .bin); truncate -s 64G $WQ/d/$n.img; dd if=$b of=$WQ/d/$n.img conv=notrunc status=none; done
	rm -rf $T; shift
	[ $# = 0 ] || for n in $DN; do [ -e $WQ/d/$n.img ] && amdshrink $WQ/d/$n.img "$@"; done
	for n in $DN; do [ -e $WQ/d/$n.img ] && sudo losetup -f $WQ/d/$n.img; done
}
DL() { sudo losetup -j $WQ/d/$1.img | cut -d: -f1; }
dbrief() { python3 $TOOLS/amdraid_dump.py $WQ/d/$1.img --brief 2>/dev/null; }
mdsz() { for m in $(mdof raid1); do [ "$(cat /sys/block/$m/size)" = $1 ] && echo $m; done; }	# RAID1 by size
indev() { [ "$(cat /sys/block/$1/md/dev-$(basename $(DL $2))/state 2>/dev/null)" = in_sync ]; }	# disk in the volume and in sync
if want 11; then
# 07: RAID1 r1 (840a7c70b562, 31248384 sect.) and r1b (8a2c51b386dd, 15624192) on sata0+sata1; dedicated spares:
# r1: sata2, r1b: sata4; RAIDABLE on sata3; NVMe is Legacy. Both RAID1 are uninitialized (CREATE_REDUNDANCY).
# Both shrunk, r1 to 1 GiB, r1b to 512 MiB: tests initialization, recording its end, rebuild of each onto
# its own spare. The first check catches the resync at 50 MB/s (r1 ~20 s; md runs them in turn), then full speed
dset 07-ded-r1b 840a7c70b562 0x200000 8a2c51b386dd 0x100000
check "dedicated spares (snapshot 07): -E lists each under its volume" "$M -E \$(DL sata0) | sed -n '/Subarray : 0/,/Subarray : 1/p' | grep -q 'Dedicated spare : 7cae660336c3a413 handle 3$' && $M -E \$(DL sata0) | sed -n '/Subarray : 2/,\$p' | grep -q 'Dedicated spare : 436269cf4bbed96f handle 5$' && $M -E \$(DL sata2) | grep -q 'Dedicated spare : 7cae660336c3a413 handle 3 <- this disk'"
check "RAIDABLE (snapshot 07): -E raid1 (one member), md support read-write" "$M -E \$(DL sata3) | sed -n '/Subarray : 1/,/Subarray : 2/p' | grep -q 'Type : RAIDABLE (0x1bfb), 1 x 1' && $M -E \$(DL sata3) | sed -n '/Subarray : 1/,/Subarray : 2/p' | grep -q 'RAID Level : raid1' && $M -E \$(DL sata3) | sed -n '/Subarray : 1/,/Subarray : 2/p' | grep -q 'md support : read-write'"
echo 50000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
for n in $DN; do $M -I $(DL $n) >/dev/null 2>&1; done; sleep 2
R1=$(mdsz $((0x200000))); R1B=$(mdsz $((0x100000)))
check "-I: both RAID1 started under mdmon, initialized by md (resync)" "[ -n '$R1' ] && [ -n '$R1B' ] && grep -q '^external:/' /sys/block/$R1/md/metadata_version && grep -q '^external:/' /sys/block/$R1B/md/metadata_version && grep -A3 '^$R1 ' /proc/mdstat | grep -q resync && grep -A3 '^$R1B ' /proc/mdstat | grep -q resync"
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
waitrec 900; sleep 3
check "init done: CREATE_REDUNDANCY completed, one LD each, dedicated spares kept" "[ \$(python3 $TOOLS/amdraid_dump.py $WQ/d/sata0.img 2>/dev/null | grep -c 'last=CREATE_REDUNDANCY state=0xa1a6') = 2 ] && ! dbrief sata0 | grep -q ' x2 ' && [ \$($M -E \$(DL sata0) | grep -c 'Dedicated spare') = 2 ]"
for R in $R1 $R1B; do $M /dev/$R --fail $(DL sata1) >/dev/null 2>&1; done; sleep 3
check "--fail sata1: each RAID1 rebuilds onto its own dedicated spare (r1 -> sata2, r1b -> sata4)" "grep -A3 '^$R1 ' /proc/mdstat | grep -q -E 'recover|\[UU\]' && [ -e /sys/block/$R1/md/dev-\$(basename \$(DL sata2)) ] && [ -e /sys/block/$R1B/md/dev-\$(basename \$(DL sata4)) ] && [ ! -e /sys/block/$R1/md/dev-\$(basename \$(DL sata4)) ] && [ ! -e /sys/block/$R1B/md/dev-\$(basename \$(DL sata2)) ]"
waitrec 900; sleep 3
check "rebuilt: both [UU] on their spares, no dedicated spare left" "indev $R1 sata0 && indev $R1 sata2 && indev $R1B sata0 && indev $R1B sata4 && ! $M -E \$(DL sata0) | grep -q 'Dedicated spare'"
check "live packet (--brief): NORMAL, one LD each, r1 on ports 1+3, r1b on 1+5, the same on sata0 and sata2" "dbrief sata0 | grep -q '840a7c70b562 R10N   NORMAL .*ГиБ  \[1:8f38 3:a413\]' && dbrief sata0 | grep -q '8a2c51b386dd R10N   NORMAL .*ГиБ  \[1:8f38 5:d96f\]' && [ \"\$(dbrief sata0 | tail -n +2)\" = \"\$(dbrief sata2 | tail -n +2)\" ]"
stopall
echo 1000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null	# small volumes: a started resync must not finish before the check
for n in $DN; do $M -I $(DL $n) >/dev/null 2>&1; done; sleep 3
check "reassembled on the spares: no resync, no recovery" "indev \$(mdsz $((0x200000))) sata2 && indev \$(mdsz $((0x100000))) sata4 && ! grep -q -E 'resync|recover' /proc/mdstat"
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
# 03: sata2 is a dedicated spare of r1, sata3 is free: -C does not take sata2 (the BIOS menu does not offer it either)
dset 03-dedspare
$M -A /dev/md/ds -e amd $(DL sata0) $(DL sata1) $(DL sata2) $(DL sata3) >/dev/null 2>&1
DC=$(basename $(readlink -f /dev/md/ds))
NL3=$(python3 $TOOLS/amdraid_dump.py $WQ/d/sata0.img 2>/dev/null | grep -c '^  LD @')
OUT=$($M -C /dev/md/bad -e amd -l1 -n2 -z 64M $(DL sata3) $(DL sata2) --run 2>&1)
OUT2=$($M -C /dev/md/bad -l10 -n4 -z 64M /dev/$DC --run 2>&1)
check "-C does not take a dedicated spare: given (refused), picked by mdadm (not counted, says why)" "echo \"\$OUT\" | grep -q \"\$(DL sata2) cannot take a member: a dedicated spare\" && echo \"\$OUT2\" | grep -q '3 disks of the container can take a member, 4 needed' && echo \"\$OUT2\" | grep -q 'handle 3, .*: a dedicated spare' && [ ! -e /dev/md/bad ] && [ \$(python3 $TOOLS/amdraid_dump.py $WQ/d/sata0.img 2>/dev/null | grep -c '^  LD @') = $NL3 ]"
# 04: RAIDABLE on sata3 (State 0x0): -E, --brief, -D of the container; runs as md raid1 of one member, starts on any kernel
dset 04-raidable
check "RAIDABLE (snapshot 04): -E raid1 (one member) read-write, -E --brief lists it, -D of the container 2 volumes" "$M -E \$(DL sata3) | sed -n '/Subarray : 1/,\$p' | grep -q 'Type : RAIDABLE (0x1bfb), 1 x 1' && $M -E \$(DL sata3) | sed -n '/Subarray : 1/,\$p' | grep -q 'RAID Level : raid1' && $M -E \$(DL sata3) | sed -n '/Subarray : 1/,\$p' | grep -q 'md support : read-write' && $M -E --brief \$(DL sata3) | grep -q 'member=1 UUID=1c8c9228:02ed31a0:739b380c:41fc9d11' && $M -A /dev/md/ra -e amd \$(DL sata0) \$(DL sata1) \$(DL sata2) \$(DL sata3) >/dev/null 2>&1 && $M -D /dev/md/ra | grep -q 'Volumes : 2'"
# RAIDABLE starts (md raid1 of one member: some kernels have no md linear), is writable; the AMD area before
# the data (it holds the bitmap of volumes that have one) untouched: RAIDABLE has no bitmap
RA=$(python3 $TOOLS/amdraid_dump.py $WQ/d/sata3.img 2>/dev/null | grep -A6 'type=0x1bfb' | grep -m1 '\[0,0\]' | sed 's/.*alloc=\(0x[0-9a-f]*\)+.*/\1/')
rah() { sudo dd if=$(DL sata3) bs=512 skip=$((RA)) count=$((0x5000)) status=none | md5sum | cut -c1-12; }
RH0=$(rah)
$M -I /dev/md/ra >/dev/null 2>&1; sleep 3
RB=$(for m in $(ls /sys/block | grep ^md); do [ "$(cat /sys/block/$m/md/level 2>/dev/null)" = raid1 ] && [ "$(cat /sys/block/$m/md/raid_disks)" = 1 ] && echo $m; done)
[ -n "$RB" ] && { echo amd-raidable | sudo dd of=/dev/$RB bs=512 seek=8 count=1 oflag=direct conv=sync status=none; sleep 2; }
check "RAIDABLE runs as md raid1 of one member, writable; the AMD area before its data untouched (alloc $RA)" "[ -n '$RB' ] && grep -A1 \"^$RB \" /proc/mdstat | grep -q '\[1/1\] \[U\]' && [ \"\$(sudo dd if=/dev/$RB bs=512 skip=8 count=1 status=none | head -c 12)\" = amd-raidable ] && [ -n '$RA' ] && [ \"\$(rah)\" = '$RH0' ]"
stopall
for n in $DN; do sudo losetup -d $(DL $n); done; rm -rf $WQ/d
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
fi

# --- stage 12: behaviour aligned with rcraid.sys ---
cn() { cont1; }
if want 12; then
mkdir -p $WQ/c && rm -f $WQ/c/*.img
# 12a. AMD PD capacity = round_down(N − 0x100000, 0x40000) + 0x100000 (rcraid.sys @140001498); disk 4 GiB + 100 MiB:
# the PD is 4 GiB, the largest volume (-C without -z) ends within it (before: by the full disk size).
N=$((8388608 + 204800)); NA=$(( (N - 0x100000) / 0x40000 * 0x40000 + 0x100000 ))
AL=""; for n in 0 1; do truncate -s $((N * 512)) $WQ/c/a$n.img; AL="$AL $(sudo losetup -f --show $WQ/c/a$n.img)"; done
echo 1000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null	# no sync needed here
$M -C /dev/md/amda -e amd -n 2 $AL --run >/dev/null 2>&1
$M -C /dev/md/amax -l1 -n2 /dev/$(cn) --run >/dev/null 2>&1; sleep 2
AEND=$(python3 $TOOLS/amdraid_dump.py $WQ/c/a0.img 2>/dev/null | sed -n "/DevicePrivate='amax'/,/ref id/p" | grep -E '^ +\[0,[01]\]' | sed 's/.*alloc=\(0x[0-9a-f]*\)+\(0x[0-9a-f]*\).*/\1 \2/' | while read s l; do echo $((s + l)); done | sort -u | paste -sd' ')
check "unaligned disk ($N sectors): PD capacity $NA as AMD's, the largest volume ends within it, by less than 1 MiB ($AEND)" "[ \$(python3 $TOOLS/amdraid_dump.py $WQ/c/a0.img 2>/dev/null | grep -c \"RAIDCORE_DISK ONLINE cap=$(printf 0x%x $NA) \") = 2 ] && [ -n '$AEND' ] && [ \$(echo $AEND | wc -w) = 1 ] && [ $AEND -le $NA ] && [ $AEND -gt $((NA - 2048)) ]"
stopall; for d in $AL; do sudo losetup -d $d; done; rm -f $WQ/c/a*.img
echo 2000000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
# 12b. LBA 0 (rcraid.sys RC_ReadMBR): b0, boot code over AMD's partition (partition intact) → mdmon puts the sector's sum
# into the label, leaves LBA 0 alone; b1, a GPT protective MBR, b2, zeros → only a warning, nothing written.
BL=""; for n in 0 1 2; do truncate -s 2G $WQ/c/b$n.img; BL="$BL $(sudo losetup -f --show $WQ/c/b$n.img)"; done
set -- $BL; B0=$1; B1=$2; B2=$3
$M -C /dev/md/amdb -e amd -n 3 $BL --run >/dev/null 2>&1
$M -C /dev/md/bm -e amd -l1 -n2 -z 128M $B0 $B1 --run >/dev/null 2>&1; sleep 1; waitrec; sleep 3; stopall
lab() { sudo dd if=$1 bs=512 skip=$((0x5000)) count=1 status=none | sha256sum; }
lba0() { sudo dd if=$1 bs=512 count=1 status=none | sha256sum; }
printf '\xeb\x63\x90\x10\x8e\xd0' | sudo dd of=$B0 bs=1 conv=notrunc,fsync status=none
python3 -c '
import struct, sys
b = bytearray(512); b[0x1be + 4] = 0xee; struct.pack_into("<II", b, 0x1be + 8, 1, 0xffffffff); b[0x1fe:0x200] = b"\x55\xaa"
open(sys.argv[1], "r+b").write(b)' $WQ/c/b1.img
sudo dd if=/dev/zero of=$B2 bs=512 count=1 conv=notrunc,fsync status=none
sudo blockdev --flushbufs $B1
LB0=$(lab $B0); LB1=$(lab $B1); LB2=$(lab $B2); MB0=$(lba0 $B0); MB1=$(lba0 $B1)
check "-E: boot code over AMD's partition: label to be updated by mdmon; GPT, zeros: not AMD's MBR, how to repair" "$M -E $B0 | grep -q \"MBR (LBA 0) : AMD's partition, but not the checksum in the label\" && $M -E $B1 2>/dev/null | grep -q 'MBR (LBA 0) : not the one AMD wrote' && $M -E $B1 2>/dev/null | grep -q 'sfdisk --label dos' && $M -E $B2 2>/dev/null | grep -q 'MBR (LBA 0) : not the one AMD wrote'"
sudo dmesg -C
OUT=$(for d in $BL; do $M -I $d 2>&1 >/dev/null; done); sleep 3
check "-I warns of the GPT and zeroed disks only" "[ \$(echo \"\$OUT\" | grep -c 'LBA 0 is not the MBR AMD wrote') = 2 ] && echo \"\$OUT\" | grep -q '$B1: LBA 0 is not' && echo \"\$OUT\" | grep -q '$B2: LBA 0 is not'"
check "mdmon: the sum of the changed LBA 0 into the label (LBA 0 kept); GPT and zeros untouched; the volume runs" "sudo dmesg | grep -q \"LBA 0 changed under AMD's partition, the label has its checksum now\" && [ \"\$(lab $B0)\" != '$LB0' ] && ! $M -E $B0 | grep -q 'MBR (LBA 0)' && [ \"\$(lba0 $B0)\" = '$MB0' ] && [ \"\$(lab $B1)\" = '$LB1' ] && [ \"\$(lab $B2)\" = '$LB2' ] && [ \"\$(lba0 $B1)\" = '$MB1' ] && [ \$(sudo dd if=$B2 bs=512 count=1 status=none | tr -d '\0' | wc -c) = 0 ] && grep -q '\[2/2\] \[UU\]' /proc/mdstat"
stopall; for d in $BL; do sudo losetup -d $d; done; rm -f $WQ/c/b*.img
# 12c. LastOnlineSerialNumber not AMD's (the disk last ran on another controller): AMD treats its configuration as
# foreign: the disk is not current, the volume is taken from the other one, this one is rebuilt onto (as a stale one).
FL=""; for n in 0 1; do truncate -s 2G $WQ/c/f$n.img; FL="$FL $(sudo losetup -f --show $WQ/c/f$n.img)"; done
set -- $FL; F0=$1; F1=$2
$M -C /dev/md/amdf -e amd -n 2 $FL --run >/dev/null 2>&1
$M -C /dev/md/fm -e amd -l1 -n2 -z 128M $F0 $F1 --run >/dev/null 2>&1; sleep 1; waitrec; sleep 3; stopall
sudo losetup -d $F1
python3 - $WQ/c/f1.img <<'PY'
import os, struct, sys
sys.path.insert(0, os.environ["TOOLS"])
import amdraid_dump as a
with open(sys.argv[1], 'r+b') as f:
    f.seek(a.LBA_COMMIT * 512); c = bytearray(f.read(512))
    struct.pack_into('<Q', c, 0x28, 0x0123456789ab)
    struct.pack_into('<Q', c, 0, a.rc_sum(c, 8, 0x1f8))
    f.seek(a.LBA_COMMIT * 512); f.write(c)
PY
F1=$(sudo losetup -f --show $WQ/c/f1.img); FL="$F0 $F1"
check "-E: last online on another controller (0123456789ab)" "$M -E $F1 2>/dev/null | grep -q \"Last Online : on controller 0123456789ab, not AMD's 859010220000\""
echo 1000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
OUT=$($M -I $F1 2>&1; $M -I $F0 2>&1); sleep 2
check "foreign disk first, then the other (-I): -I says why, the volume waits as one degraded (as AMD binds none of its elements)" "echo \"\$OUT\" | grep -q '$F1: last online on another controller' && [ -z \"\$(mdof raid1)\" ]"
$M -IRs >/dev/null 2>&1; sleep 3; RF=$(mdof raid1)
check "-IRs: started from the current disk, the foreign one rebuilt onto (not in sync)" "[ -n '$RF' ] && [ \"\$(cat /sys/block/$RF/md/dev-\$(basename $F0)/state)\" = in_sync ] && [ -e /sys/block/$RF/md/dev-\$(basename $F1) ] && [ \"\$(cat /sys/block/$RF/md/dev-\$(basename $F1)/state)\" != in_sync ]"
echo 2000000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null; waitrec; sleep 3
check "rebuilt: last online AMD's on both, same generation, NORMAL" "! $M -E $F1 2>/dev/null | grep -q 'Last Online' && [ \"\$($M -E $F0 2>/dev/null | sed -n 's/^ *Generation : //p')\" = \"\$($M -E $F1 2>/dev/null | sed -n 's/^ *Generation : //p')\" ] && $M -E $F1 2>/dev/null | grep -q 'State : 0x200'"
stopall; for d in $FL; do sudo losetup -d $d; done; rm -f $WQ/c/f*.img
# 12c2. The whole set from another controller: rcraid for Linux writes serial 102285900000 (rcblob RC_STH_DiscoverAdapter).
# AMD puts its own on writing (the OS driver: at every start): at start mdmon makes the configuration
# its own: 859010220000 in the header, controller PD, LD reference and commit blocks, number +1; container and volume UUIDs kept.
GL=""; for n in 0 1; do truncate -s 2G $WQ/c/g$n.img; GL="$GL $(sudo losetup -f --show $WQ/c/g$n.img)"; done
$M -C /dev/md/amdg -e amd -n 2 $GL --run >/dev/null 2>&1
$M -C /dev/md/gm -e amd -l1 -n2 -z 128M $GL --run >/dev/null 2>&1; sleep 1; waitrec; sleep 3; stopall
for d in $GL; do sudo losetup -d $d; done
python3 - $WQ/c/g0.img $WQ/c/g1.img <<'PY'
import os, struct, sys
sys.path.insert(0, os.environ["TOOLS"])
import amdraid_dump as a
old, new = struct.pack('<Q', 0x859010220000), struct.pack('<Q', 0x102285900000)
for path in sys.argv[1:]:
    with open(path, 'r+b') as f:
        f.seek(a.LBA_COMMIT * 512); c = bytearray(f.read(512))
        lba, size = struct.unpack_from('<II', c, 8)
        f.seek(lba * 512); p = bytearray(f.read(size))
        p[0x1c:0x24] = new                       # ModifierSerialNumber
        p[0x200:] = p[0x200:].replace(old, new)  # PD of the controller, parent references of the LDs
        struct.pack_into('<Q', p, 0, a.rc_sum(p, 0x0c, size - 0x0c))
        f.seek(lba * 512); f.write(p)
        c[0x10:0x18] = p[0:8]                    # CommittedChecksum
        c[0x20:0x28] = new; c[0x28:0x30] = new   # LastModifier-, LastOnlineSerialNumber
        struct.pack_into('<Q', c, 0, a.rc_sum(c, 8, 0x1f8))
        f.seek(a.LBA_COMMIT * 512); f.write(c)
PY
GL=""; for n in 0 1; do GL="$GL $(sudo losetup -f --show $WQ/c/g$n.img)"; done
set -- $GL; G0=$1; G1=$2
uuids() { $M -E $1 2>/dev/null | grep 'UUID :' | tr -s ' ' | paste -sd' '; }
gen() { $M -E $1 2>/dev/null | sed -n 's/^ *Generation : //p'; }
U0=$(uuids $G0); GN=$(gen $G0)
check "-E: set last online on rcraid for Linux (102285900000), generation $GN" "[ -n '$GN' ] && $M -E $G0 2>/dev/null | grep -q 'Controller SN : 102285900000' && $M -E $G1 2>/dev/null | grep -q \"Last Online : on controller 102285900000, not AMD's 859010220000\""
MK="12e-$(date +%s%N)"; echo "amd-test: $MK" | sudo tee /dev/kmsg >/dev/null
$M -A /dev/md/amdg $GL >/dev/null 2>&1; $M -I /dev/md/amdg >/dev/null 2>&1; sleep 3
check "foreign set: mdmon takes the configuration over at start, as the AMD driver (dmesg)" "[ -n \"\$(mdof raid1)\" ] && sudo dmesg | sed -n '/amd-test: $MK/,\$p' | grep -q 'mdmon: amd: the configuration of controller 102285900000 is this one.s now'"
stopall
check "taken over: AMD's serial on both disks (header, controller PD, LD reference, commit), generation +1, UUIDs kept" "( for g in $G0 $G1; do $M -E \$g 2>/dev/null | grep -q 'Controller SN : 859010220000' && ! $M -E \$g 2>&1 | grep -q -e 'Last Online' -e 'another controller' && [ \"\$(gen \$g)\" = $((GN + 1)) ] || exit 1; done ) && [ \$(python3 $TOOLS/amdraid_dump.py $WQ/c/g0.img 2>/dev/null | grep -c -e 'dev=859010220000 handle=65535/0 RAIDCORE_CORE' -e 'ref id=859010220000') = 2 ] && ! python3 $TOOLS/amdraid_dump.py $WQ/c/g0.img 2>/dev/null | grep -q 102285900000 && [ -n '$U0' ] && [ \"\$(uuids $G0)\" = '$U0' ]"
stopall; for d in $GL; do sudo losetup -d $d; done; rm -f $WQ/c/g*.img
# 12d. 12 arrays per system, Legacy ones counted (the MSI BIOS menu and the emulated board): the 13th refused, --force passes
VL=""; for n in 0 1; do truncate -s 2G $WQ/c/v$n.img; VL="$VL $(sudo losetup -f --show $WQ/c/v$n.img)"; done
$M -C /dev/md/amdv -e amd -n 2 $VL --run >/dev/null 2>&1; VC=$(cn)
for i in $(seq 1 12); do $M -C /dev/md/v$i -l0 -n2 -z 8M /dev/$VC --run >/dev/null 2>&1; done; sleep 1
nldv() { python3 $TOOLS/amdraid_dump.py $WQ/c/v0.img 2>/dev/null | grep -c '^  LD @'; }
N12=$(nldv)
OUT=$($M -C /dev/md/v13 -l0 -n2 -z 8M /dev/$VC --run 2>&1)
check "12 volumes created; the 13th refused as the BIOS menu does ($N12 LDs)" "[ $N12 = 12 ] && echo \"\$OUT\" | grep -q 'allows 12 arrays in a system' && [ \$(nldv) = 12 ] && [ ! -e /dev/md/v13 ]"
OUT=$($M -C /dev/md/v13 -e amd -l0 -n2 -z 8M $VL --run --force 2>&1); sleep 1
check "--force, disks given: the 13th created, with a word on the BIOS menu" "echo \"\$OUT\" | grep -q 'creating one more anyway (--force)' && [ \$(nldv) = 13 ] && [ -e /dev/md/v13 ]"
# into the container (/dev/mdX without disks): before the fix, --force did not reach validate_geometry
OUT=$($M -C /dev/md/v14 -l0 -n2 -z 8M /dev/$VC --run --force 2>&1); sleep 1
check "--force, into the container: the 14th created too" "echo \"\$OUT\" | grep -q 'creating one more anyway (--force)' && [ \$(nldv) = 14 ] && [ -e /dev/md/v14 ]"
stopall; for d in $VL; do sudo losetup -d $d; done; rm -f $WQ/c/v*.img
# 12e. The commit block as AMD reads it (RC_CheckConfigCommit): the packet anywhere in 1…0x6000, its end not necessarily
# in the ring; LBA 0, past 0x6000, size from 1 MiB, sum 0: refused. On a copy of X399, -E (read-only).
cp --sparse=always $IMG/x399-member0.img $WQ/c/cm.img
sudo dd if=$WQ/c/cm.img bs=512 skip=$((0x5001)) count=1 status=none > $TMPW/amd-commit.bin
cmt() {	# cmt <how> [value]: original commit block + an edit; -E: whether the configuration is parsed
	dd if=$TMPW/amd-commit.bin of=$WQ/c/cm.img bs=512 seek=$((0x5001)) conv=notrunc status=none
	python3 - $WQ/c/cm.img "$@" <<'PY'
import os, struct, sys
sys.path.insert(0, os.environ["TOOLS"])
import amdraid_dump as a
p, how = sys.argv[1], sys.argv[2]
v = int(sys.argv[3], 0) if len(sys.argv) > 3 else 0
with open(p, 'r+b') as f:
    f.seek(a.LBA_COMMIT * 512); c = bytearray(f.read(512))
    lba, size = struct.unpack_from('<II', c, 8)
    if how == 'move':
        f.seek(lba * 512); g = f.read((size + 511) // 512 * 512)
        f.seek(v * 512); f.write(g)
        struct.pack_into('<I', c, 8, v)
    elif how == 'off':
        struct.pack_into('<I', c, 8, v)
    elif how == 'size':
        struct.pack_into('<I', c, 12, v)
    struct.pack_into('<Q', c, 0, a.rc_sum(c, 8, 0x1f8))
    if how == 'zerosum':	# a spare word at 0x1f8 makes the block sum 0, with 0 in the sum field
        def sw(w, x, y):
            l = [(w >> (16 * k)) & 0xffff for k in range(4)]; l[x], l[y] = l[y], l[x]
            return sum(q << (16 * k) for k, q in enumerate(l))
        struct.pack_into('<Q', c, 0x1f8, 0); acc = a.rc_sum(c, 8, 0x1f0)
        for w in [acc] + [sw(acc, x, y) for x in range(4) for y in range(x + 1, 4)]:
            struct.pack_into('<Q', c, 0x1f8, w)
            if a.rc_sum(c, 8, 0x1f8) == 0:
                break
        else:
            sys.exit(1)
        struct.pack_into('<Q', c, 0, 0)
    f.seek(a.LBA_COMMIT * 512); f.write(c)
PY
	local l=$(sudo losetup -r -f --show $WQ/c/cm.img) r=no
	$M -E $l 2>/dev/null | grep -q 'RAID Level : raid10' && r=yes
	$M -E $l 2>/dev/null | grep -q 'Configuration : none (no valid commit block)' && r=none
	sudo losetup -d $l; echo $r
}
CM="$(cmt off 0x58fe) $(cmt move 0x100) $(cmt move 0x5fff) $(cmt off 0) $(cmt off 0x6001) $(cmt size 0x100000) $(cmt zerosum)"
check "commit block as AMD reads it: packet at 0x100, at 0x5fff (past the ring) taken; LBA 0, 0x6001, 1 MiB, sum 0 refused ($CM)" "[ '$CM' = 'yes yes yes none none none none' ]"
rm -f $WQ/c/cm.img $TMPW/amd-commit.bin

# 12f. LD State 0x204 LOCKED (Windows driver 9.3.3.291: a member locked with an ATA password) is treated as
# CRITICAL: a locked disk is unreadable (it is simply absent), md decides by the members; LOCKED left after unlocking
# does not hinder the volume. Copy of X399, first LD of the live packet, packet and commit block sums recomputed; -E (read-only).
cp --sparse=always $IMG/x399-member0.img $WQ/c/lk.img
python3 - $WQ/c/lk.img <<'PY'
import os, struct, sys
sys.path.insert(0, os.environ["TOOLS"])
import amdraid_dump as a
with open(sys.argv[1], 'r+b') as f:
    f.seek(a.LBA_COMMIT * 512); c = bytearray(f.read(512))
    lba, size = struct.unpack_from('<II', c, 8)
    f.seek(lba * 512); g = bytearray(f.read((size + 511) // 512 * 512))
    h, pds, lds = a.parse_gen(bytes(g))
    struct.pack_into('<I', g, lds[0]['off'] + 8, 0x204)
    struct.pack_into('<Q', g, 0, a.rc_sum(g, 0xC, h['length'] - 0xC))
    struct.pack_into('<Q', c, 0x10, struct.unpack_from('<Q', g, 0)[0])
    struct.pack_into('<Q', c, 0, a.rc_sum(c, 8, 0x1F8))
    f.seek(lba * 512); f.write(g); f.seek(a.LBA_COMMIT * 512); f.write(c)
PY
LK=$(sudo losetup -r -f --show $WQ/c/lk.img)
check "LD LOCKED (0x204, AMD driver 9.3.3.291): -E says so, the volume is read-write for md, as a critical one" "$M -E $LK 2>/dev/null | grep -q 'State : 0x204 (locked' && $M -E $LK 2>/dev/null | grep -q 'md support : read-write'"
sudo losetup -d $LK; rm -f $WQ/c/lk.img

# 12g. LD with a distributed spare (DistributedSpare +0xA0 ≠ 0): our platforms lack bit 0x10, AMD takes such a volume
# offline ("offline due to dist. spare", rcblob RC_ValidateLogicalDevice); rebuilding into spare space on members changes the layout: md does not
# assemble it. Copy of X399, sums recomputed; -E (read-only).
cp --sparse=always $IMG/x399-member0.img $WQ/c/ds.img
python3 - $WQ/c/ds.img <<'PY'
import os, struct, sys
sys.path.insert(0, os.environ["TOOLS"])
import amdraid_dump as a
with open(sys.argv[1], 'r+b') as f:
    f.seek(a.LBA_COMMIT * 512); c = bytearray(f.read(512))
    lba, size = struct.unpack_from('<II', c, 8)
    f.seek(lba * 512); g = bytearray(f.read((size + 511) // 512 * 512))
    h, pds, lds = a.parse_gen(bytes(g))
    struct.pack_into('<I', g, lds[0]['off'] + 0xA0, 1)
    struct.pack_into('<Q', g, 0, a.rc_sum(g, 0xC, h['length'] - 0xC))
    struct.pack_into('<Q', c, 0x10, struct.unpack_from('<Q', g, 0)[0])
    struct.pack_into('<Q', c, 0, a.rc_sum(c, 8, 0x1F8))
    f.seek(lba * 512); f.write(g); f.seek(a.LBA_COMMIT * 512); f.write(c)
PY
DS=$(sudo losetup -r -f --show $WQ/c/ds.img)
check "LD with a distributed spare (DistributedSpare != 0, AMD bit 0x10): -E says md does not support it" "$M -E $DS 2>/dev/null | grep -q 'md support : none - a distributed spare is not supported'"
sudo losetup -d $DS; rm -f $WQ/c/ds.img
fi

# --- stage 13: spare roles from mdadm: <volume> --add-spare / --remove: a dedicated spare of the volume (as the BIOS menu
# Manage Dedicated Hot Spares / Unassign, rcblob RC_AssignSpare/RC_DeassignSpare); <container> --remove of a global
# spare that is present: drops the role (PD and label SpareInfo 0, RC_DeassignPhysicalDeviceGlobalSpare); roles kept after
# a stop and -I; rebuild onto a dedicated spare assigned this way.
sid() { $M -E $1 2>/dev/null | sed -n 's/^ *Device ID : //p' | head -1; }
slbl() { sudo dd if=$1 bs=512 skip=$((0x5000)) count=1 status=none | od -An -tx4 -j52 -N4 | tr -d ' '; }
if want 13; then
SP=(); for n in 0 1 2 3 4; do truncate -s 1G $WQ/c/s$n.img; SP[$n]=$(sudo losetup -f --show $WQ/c/s$n.img); done
ndd() { $M -E ${SP[0]} 2>/dev/null | grep -c 'Dedicated spare'; }
$M -C /dev/md/amds -e amd -n4 ${SP[0]} ${SP[1]} ${SP[2]} ${SP[3]} --run >/dev/null 2>&1
$M -C /dev/md/sr1 -e amd -l1 -n2 -z 64M ${SP[0]} ${SP[1]} --run >/dev/null 2>&1
$M -C /dev/md/sr0 -e amd -l0 -n2 -z 32M ${SP[0]} ${SP[1]} --run >/dev/null 2>&1; waitrec; sleep 2
OUT=$($M /dev/md/sr1 --add-spare ${SP[2]} 2>&1); sleep 1
check "--add-spare to a RAID1 volume: a disk of the container becomes its dedicated spare" "echo '$OUT' | grep -q 'a dedicated hot spare of subarray-0 now' && $M -E ${SP[0]} | sed -n '/Subarray : 0/,/Subarray : 1/p' | grep -q 'Dedicated spare : $(sid ${SP[2]}) handle '"
check "refused: a RAID0 volume, a member, a disk outside the container, the same spare twice" "$M /dev/md/sr0 --add-spare ${SP[3]} 2>&1 | grep -q 'it has no redundancy' && $M /dev/md/sr1 --add-spare ${SP[1]} 2>&1 | grep -q 'one of its members' && $M /dev/md/sr1 --add-spare ${SP[4]} 2>&1 | grep -q 'not in the container' && $M /dev/md/sr1 --add-spare ${SP[2]} 2>&1 | grep -q 'a dedicated spare of it already' && [ \$(ndd) = 1 ]"
$M /dev/md/amds --add ${SP[4]} >/dev/null 2>&1; sleep 1
G4="$($M -E ${SP[0]} | grep -c "$(sid ${SP[4]}) .*global spare") $(slbl ${SP[4]})"
$M /dev/md/sr1 --add-spare ${SP[4]} >/dev/null 2>&1; sleep 1
check "a global spare given to a volume: dedicated, no longer global (PD, label 0x100 -> 0) ($G4)" "[ '$G4' = '1 00000100' ] && [ \$(ndd) = 2 ] && ! $M -E ${SP[0]} | grep -q 'global spare' && [ \$(slbl ${SP[4]}) = 00000000 ]"
stopall; for l in ${SP[@]}; do $M -I $l >/dev/null 2>&1; done; sleep 3
check "roles kept after a stop and -I: 2 dedicated spares, no global one, both volumes run" "[ \$(ndd) = 2 ] && ! $M -E ${SP[0]} | grep -q 'global spare' && [ \$(active raid1) = 1 ] && [ \$(active raid0) = 1 ]"
SR1=/dev/$(mdof raid1)
$M $SR1 --remove ${SP[4]} >/dev/null 2>&1; sleep 1
check "--remove from the volume unassigns its dedicated spare; again: refused" "[ \$(ndd) = 1 ] && $M $SR1 --remove ${SP[4]} 2>&1 | grep -q 'is not a dedicated spare of subarray-0'"
$M $SR1 --fail ${SP[1]} >/dev/null 2>&1; sleep 2; waitrec; sleep 3
check "a member fails: the rebuild takes the dedicated spare, which leaves the list" "$M -D $SR1 | grep -q '${SP[2]}' && [ \$(ndd) = 0 ] && $M -E ${SP[0]} | sed -n '/Subarray : 0/,/Subarray : 1/p' | grep -q 'State : 0x200'"
$M $SR1 --add-spare ${SP[4]} >/dev/null 2>&1; sleep 1; N4=$(ndd)
CNS=/dev/$(cn)
OUT=$($M $CNS --remove ${SP[4]} 2>&1); sleep 1
check "--remove of a dedicated spare from the container unassigns it too ($N4)" "[ '$N4' = 1 ] && echo '$OUT' | grep -q 'no longer a dedicated hot spare of subarray-0' && [ \$(ndd) = 0 ]"
$M $CNS --remove ${SP[3]} >/dev/null 2>&1; $M $CNS --add ${SP[3]} >/dev/null 2>&1; sleep 1
G3="$($M -E ${SP[0]} | grep -c "$(sid ${SP[3]}) .*global spare") $(slbl ${SP[3]})"
OUT=$($M $CNS --remove ${SP[3]} 2>&1); sleep 1
check "--remove of a global spare that is here: the role goes (PD, label), it stays an AMD RAID disk ($G3)" "[ '$G3' = '1 00000100' ] && echo '$OUT' | grep -q 'no longer an AMD global hot spare' && ! $M -E ${SP[0]} | grep -q 'global spare' && [ \$(slbl ${SP[3]}) = 00000000 ] && $M -E ${SP[3]} | grep -q 'this disk'"
stopall; for l in ${SP[@]}; do $M -I $l >/dev/null 2>&1; done; sleep 3
check "after a stop and -I: no global spare, the unassigned disks are back in the container" "! $M -E ${SP[0]} | grep -q 'global spare' && grep -B1 'super external:amd' /proc/mdstat | head -1 | grep -q '$(basename ${SP[3]})\[' && grep -B1 'super external:amd' /proc/mdstat | head -1 | grep -q '$(basename ${SP[4]})\['"
stopall; for l in ${SP[@]}; do sudo losetup -d $l; done; rm -f $WQ/c/s*.img
fi

# --- stage 13b: -C of volumes from the container's global spares ---
# As IMSM builds new volumes from the container's spares: --add makes a blank disk an AMD global spare (BIOS menu:
# Initialize + Assign Global Hot Spare), -C takes it as a member, the role is dropped: PD and label SpareInfo 0x100 -> 0,
# as for a Ready disk that became a member of a BIOS-menu volume. Both paths: mdmon running (CREATE via mdmon) and a container without
# running volumes (mdadm writes the configuration itself). Refused: a dedicated spare of another volume; a spare md is
# rebuilding a volume onto before mdmon has recorded the rebuild.
if want 13b; then
mkdir -p $WQ/cs && rm -f $WQ/cs/*.img
CS=(); for n in $(seq 0 10); do truncate -s 1G $WQ/cs/s$n.img; CS[$n]=$(sudo losetup -f --show $WQ/cs/s$n.img); done
csl() { sudo losetup -j $WQ/cs/$1.img | cut -d: -f1; }
csid() { $M -E $(csl $1) 2>/dev/null | sed -n 's/^ *Device ID : //p' | head -1; }
# disk role: SpareInfo of its PD in the live packet (on s0) and SpareInfo of its label (+0x34): "0x100 00000100" is a global spare
csrole() { local id=$(printf '%012x' 0x$(csid $1)); echo "$(python3 $TOOLS/amdraid_dump.py $WQ/cs/s0.img 2>/dev/null | sed -n "s/.* dev=$id handle=.* spare=\(0x[0-9a-f]*\) .*/\1/p" | head -1) $(sudo dd if=$(csl $1) bs=512 skip=$((0x5000)) count=1 status=none | od -An -tx4 -j52 -N4 | tr -d ' ')"; }
csvol() { $M -E ${CS[0]} 2>/dev/null | sed -n "/^\[$1\]:/,/^\[/p"; }
csdump() { python3 $TOOLS/amdraid_dump.py $WQ/cs/s0.img 2>/dev/null; }
$M -C /dev/md/csc -e amd -n2 ${CS[0]} ${CS[1]} --run >/dev/null 2>&1
$M -C /dev/md/csr1 -e amd -l1 -n2 -z 128M ${CS[0]} ${CS[1]} --run >/dev/null 2>&1; waitrec; sleep 2
CSN=/dev/$(cont1)
$M $CSN --add ${CS[2]} ${CS[3]} >/dev/null 2>&1; sleep 1
check "13b: --add of two blank disks: AMD global spares (PD and label 0x100)" "[ \"\$(csrole s2)\" = '0x100 00000100' ] && [ \"\$(csrole s3)\" = '0x100 00000100' ] && pgrep -x mdmon >/dev/null"
# no disks on the command line: non-spare disks first (s0, s1 with free space), the spares remain
$M -C /dev/md/csa -l1 -n2 -z 64M $CSN --run >/dev/null 2>&1; waitrec; sleep 2
check "13b: -C in the container without disks: takes the disks that are no spares first, the spares stay" "csvol csa | grep -q 'Member   0 : $(csid s0) ' && csvol csa | grep -q 'Member   1 : $(csid s1) ' && [ \"\$(csrole s2)\" = '0x100 00000100' ]"
OUT=$($M -C /dev/md/csn -e amd -l1 -n2 -z 128M ${CS[2]} ${CS[3]} --run 2>&1); sleep 2
VN=$(basename $(readlink -f /dev/md/csn))
check "13b: -C RAID1 on the two global spares (mdmon has the container): created, managed by mdmon" "echo \"\$OUT\" | grep -q 'array /dev/md/csn started' && grep -q '^external:/' /sys/block/$VN/md/metadata_version && pgrep -x mdmon >/dev/null"
check "13b: ... they are global spares no more: PD and label SpareInfo 0, as a Ready disk the menu made a member" "[ \"\$(csrole s2)\" = '0x0 00000000' ] && [ \"\$(csrole s3)\" = '0x0 00000000' ] && ! $M -E ${CS[0]} | grep -q 'global spare'"
waitrec; sleep 3
check "13b: ... md initialized it: one LD, CREATE_REDUNDANCY completed, NORMAL, members s2, s3" "[ \$(csdump | grep -c \"DevicePrivate='csn'\") = 1 ] && csdump | grep -A2 \"DevicePrivate='csn'\" | grep -q 'last=CREATE_REDUNDANCY state=0xa1a6' && csvol csn | grep -q 'State : 0x200' && csvol csn | grep -q 'Member   0 : $(csid s2) ' && csvol csn | grep -q 'Member   1 : $(csid s3) '"
# RAID0 from a global spare and a disk with free space
$M $CSN --add ${CS[4]} >/dev/null 2>&1; sleep 1; R4=$(csrole s4)
$M -C /dev/md/cs0 -e amd -l0 -n2 -z 64M ${CS[4]} ${CS[2]} --run >/dev/null 2>&1; sleep 2
head -c 8M /dev/urandom > $TMPW/cs-r0.bin; sudo dd if=$TMPW/cs-r0.bin of=/dev/md/cs0 bs=1M oflag=direct status=none
check "13b: RAID0 on a global spare and a member disk: runs, data reads back, s4 no spare ($R4 -> 0)" "[ '$R4' = '0x100 00000100' ] && [ \"\$(csrole s4)\" = '0x0 00000000' ] && [ \$(cat /sys/block/\$(basename \$(readlink -f /dev/md/cs0))/md/level) = raid0 ] && cmp -s <(sudo dd if=/dev/md/cs0 bs=1M count=8 iflag=direct status=none) $TMPW/cs-r0.bin"
rm -f $TMPW/cs-r0.bin
# --bitmap=internal
$M $CSN --add ${CS[5]} ${CS[6]} >/dev/null 2>&1; sleep 1
$M -C /dev/md/csb -e amd -l1 -n2 -z 128M --bitmap=internal ${CS[5]} ${CS[6]} --run >/dev/null 2>&1; sleep 2; waitrec; sleep 2
check "13b: -C --bitmap=internal on two global spares: policy bitmap, both spares no more" "[ \$(cat /sys/block/\$(basename \$(readlink -f /dev/md/csb))/md/consistency_policy) = bitmap ] && [ \"\$(csrole s5)\" = '0x0 00000000' ] && [ \"\$(csrole s6)\" = '0x0 00000000' ]"
# a dedicated spare of another volume: refused
$M $CSN --add ${CS[7]} >/dev/null 2>&1; sleep 1; $M /dev/md/csr1 --add-spare ${CS[7]} >/dev/null 2>&1; sleep 1
OUT=$($M -C /dev/md/csbad -e amd -l1 -n2 -z 64M ${CS[7]} ${CS[2]} --run 2>&1)
check "13b: a dedicated spare of another volume: refused, says whose and how to unassign it" "echo \"\$OUT\" | grep -q 'cannot take a member: a dedicated spare of subarray-0 (mdadm <that volume> --remove unassigns it)' && [ ! -e /dev/md/csbad ] && csvol csr1 | grep -q 'Dedicated spare : $(csid s7) '"
# a spare md already took into the volume while mdmon has not recorded the rebuild (before the configuration write): mdmon holds the extent
# itself (amd_extent_overlap), mdadm does not see it: refused by sysfs holders. Window model: mdmon stopped (SIGSTOP), the disk
# added to the volume's md via sysfs, as managemon does (new_dev); then removed, mdmon continues
$M $CSN --add ${CS[8]} >/dev/null 2>&1; sleep 1
VR=$(basename $(readlink -f /dev/md/csr1)); MP=$(pgrep -x mdmon)
sudo kill -STOP $MP
echo $(lsblk -dno MAJ:MIN ${CS[8]} | tr -d ' ') | sudo tee /sys/block/$VR/md/new_dev >/dev/null
HOLD=$(ls /sys/block/$(basename ${CS[8]})/holders | grep -c "^$VR\$")
OUT=$($M -C /dev/md/csbad -e amd -l1 -n2 -z 64M ${CS[8]} ${CS[0]} --run 2>&1)
echo remove | sudo tee /sys/block/$VR/md/dev-$(basename ${CS[8]})/state >/dev/null
sudo kill -CONT $MP; sleep 1
check "13b: a global spare md runs in a volume the configuration does not have it in yet: refused (holder: $HOLD)" "[ '$HOLD' = 1 ] && echo \"\$OUT\" | grep -q 'cannot take a member: md is rebuilding subarray-0 onto it' && [ ! -e /dev/md/csbad ] && [ \"\$(csrole s8)\" = '0x100 00000100' ]"
$M $CSN --add ${CS[9]} ${CS[10]} >/dev/null 2>&1; sleep 1
stopall
for l in ${CS[@]}; do $M -I $l >/dev/null 2>&1; done; sleep 3
check "13b: after a stop, -I of each disk: all 5 volumes run, roles kept (s7 dedicated, s8-s10 global)" "[ \$(active raid1) = 4 ] && [ \$(active raid0) = 1 ] && csvol csr1 | grep -q 'Dedicated spare : $(csid s7) ' && [ \$($M -E ${CS[0]} | grep -c 'global spare') = 3 ] && [ \"\$(csrole s2)\" = '0x0 00000000' ]"
stopall
# a container without running volumes: no mdmon, -C writes the configuration itself, then starts mdmon
$M -A /dev/md/csc -e amd ${CS[@]} >/dev/null 2>&1; sleep 1
NM=$(pgrep -xc mdmon)
OUT=$($M -C /dev/md/csm -e amd -l1 -n2 -z 64M ${CS[9]} ${CS[10]} --run 2>&1); sleep 2; waitrec; sleep 2
check "13b: container without running volumes (mdmon: $NM): -C on two global spares, mdmon started for it, spares no more" "[ '$NM' = 0 ] && echo \"\$OUT\" | grep -q 'array /dev/md/csm started' && pgrep -x mdmon >/dev/null && [ \"\$(csrole s9)\" = '0x0 00000000' ] && [ \"\$(csrole s10)\" = '0x0 00000000' ] && csvol csm | grep -q 'State : 0x200'"
stopall
$M -A /dev/md/csc -e amd ${CS[@]} >/dev/null 2>&1
CSN=/dev/$(cont1); $M -I $CSN >/dev/null 2>&1; sleep 3
check "13b: -A of the container and -I of it: all 6 volumes run, s8 the only global spare" "[ \$(active raid1) = 5 ] && [ \$(active raid0) = 1 ] && [ \$($M -E ${CS[0]} | grep -c 'global spare') = 1 ] && [ \"\$(csrole s8)\" = '0x100 00000100' ]"
stopall; for l in ${CS[@]}; do sudo losetup -d $l; done; rm -f $WQ/cs/*.img
fi
# --- end of stage 13b ---

# --- stage 13c: a disk removed for good (seen on the test PC: an HDD after hotplug): its PD is OFFLINE in the configuration, yet the end
# of a new volume's initialization is still recorded (amd_all_disks_here does not wait for a disk whose absence is recorded;
# before the fix: State 0x0, CREATE_REDUNDANCY 0 % forever, every assembly initialized again) ---
if want 13c; then
mkdir -p $WQ/gn && rm -f $WQ/gn/*.img
for n in 0 1 2; do truncate -s 1G $WQ/gn/g$n.img; sudo losetup -f $WQ/gn/g$n.img; done
gnl() { sudo losetup -j $WQ/gn/$1.img | cut -d: -f1; }
gnsec() { $M -E $(gnl g0) 2>/dev/null | sed -n "/^\[$1\]/,/^\[/p"; }
gncont() { echo /dev/$(cont1); }
$M -C /dev/md/gnc -e amd -n3 $(gnl g0) $(gnl g1) $(gnl g2) --run >/dev/null 2>&1
$M -C /dev/md/gn1 -e amd -l1 -n2 -z 128M $(gnl g0) $(gnl g1) --run >/dev/null 2>&1; waitrec; sleep 3
stopall; sudo losetup -d $(gnl g2)
$M -A /dev/md/gnc -e amd $(gnl g0) $(gnl g1) >/dev/null 2>&1; $M -I $(gncont) >/dev/null 2>&1; sleep 2
$M -C /dev/md/gn2 -e amd -l1 -n2 -z 128M $(gnl g0) $(gnl g1) --run >/dev/null 2>&1; waitrec; sleep 5
check "13c: a disk gone for good (its PD OFFLINE): the new volume's initialization is recorded - NORMAL, CREATE_REDUNDANCY completed" "$M -E $(gnl g0) | grep -qE '^ +[0-9]+ +[0-9a-f]{16} +[0-9]+ +raid +0x3001' && gnsec gn2 | grep -q 'State : 0x200 (normal)' && gnsec gn2 | grep -q 'last 0x5355, state 0xa1a6'"
stopall; $M -A /dev/md/gnc -e amd $(gnl g0) $(gnl g1) >/dev/null 2>&1; $M -I $(gncont) >/dev/null 2>&1; sleep 3
GV=$(for m in $(ls /sys/block | grep ^md); do grep -qx "external:/$(basename $(gncont))/1" /sys/block/$m/md/metadata_version 2>/dev/null && echo $m; done)
check "13c: ... assembled again: no initialization, no resync" "[ -n '$GV' ] && [ \$(cat /sys/block/$GV/md/resync_start) = none ] && ! grep -A2 '^$GV ' /proc/mdstat | grep -q resync"
stopall; for n in g0 g1; do sudo losetup -d $(gnl $n); done; rm -f $WQ/gn/*.img
fi
# --- end of stage 13c ---

# --- stage 14: -As with the stale disk first in the scan (patch 21 "Assemble: look at every slotless device…"):
# members of an AMD container have no slot, Assemble.c looked for the newest disk only at even places of best[]:
# "No suitable drives found". So Debian 13 failed to boot from the volume after a boot without a disk (initramfs: mdadm -As by
# mdadm.conf, on the emulated board). Here the same on loop: the stale one first in DEVICE, ARRAY from -Es, as Debian mkconf writes.
if want 14; then
for n in 0 1; do truncate -s 1G $WQ/c/o$n.img; done
O0=$(sudo losetup -f --show $WQ/c/o0.img); O1=$(sudo losetup -f --show $WQ/c/o1.img)
$M -C /dev/md/amdo -e amd -n2 $O0 $O1 --run >/dev/null 2>&1
$M -C /dev/md/ro1 -l1 -n2 -z 64M /dev/md/amdo --run >/dev/null 2>&1; waitrec; sleep 2
stopall
$M -I $O1 >/dev/null 2>&1; $M -IRs >/dev/null 2>&1; sleep 2	# without O0: mdmon records its absence
echo x | sudo dd of=/dev/$(mdof raid1) bs=4096 count=1 oflag=direct status=none; sleep 2
stopall
gen() { $M -E $1 2>/dev/null | sed -n 's/^ *Generation : //p'; }
G="$(gen $O0) $(gen $O1)"
for order in "$O0 $O1" "$O1 $O0"; do
	echo "DEVICE $order containers" > $TMPW/amd-o.conf; $M -Es -c $TMPW/amd-o.conf >> $TMPW/amd-o.conf 2>/dev/null
	OUT=$($M -As -c $TMPW/amd-o.conf 2>&1); sleep 2; waitrec; sleep 2
	check "-As, DEVICE $order (stale $O0 first or last; generations $G): container of both, volume runs, stale disk rebuilt into its slot" "[ \$(echo $G | cut -d' ' -f1) -lt \$(echo $G | cut -d' ' -f2) ] && ! echo '$OUT' | grep -q 'No suitable' && grep -B1 'super external:amd' /proc/mdstat | head -1 | grep -q '$(basename $O0)\[' && grep -B1 'super external:amd' /proc/mdstat | head -1 | grep -q '$(basename $O1)\[' && grep -A1 '^md.*raid1' /proc/mdstat | grep -q '\[2/2\] \[UU\]' && $M -E $O0 | grep -q 'State : 0x200'"
	stopall
	# second round: again with the stale O0
	[ "$order" = "$O0 $O1" ] && { $M -I $O1 >/dev/null 2>&1; $M -IRs >/dev/null 2>&1; sleep 2; echo y | sudo dd of=/dev/$(mdof raid1) bs=4096 count=1 oflag=direct status=none; sleep 2; stopall; G="$(gen $O0) $(gen $O1)"; }
done
sudo losetup -d $O0 $O1; rm -f $WQ/c/o*.img $TMPW/amd-o.conf
fi

# --- stage 15: AMD migrations (rcadm -T under rcraid 9.3.3-00302: fixture 2026-11-07-rcraid-migrations) ---
# m1: RAIDABLE → RAID1 started by the AMD driver (34 %): runs as md raid1 of two, the second catches up
# from the log mark 0x5354; mdmon records progress in the log and reduces to one LD, as AMD in m1-post. m2 (RAID1 expansion) is not
# assembled. The log is moved near the end (amdtlog) to avoid copying 63 GiB.
amdtlog() {	# amdtlog <image> <LBA> <mark>: ProtectStart = IOStart = mark, sum recomputed
	python3 - "$@" <<'PY'
import os, struct, sys
sys.path.insert(0, os.environ["TOOLS"]); from amdraid_dump import rc_sum
p, lba, done = sys.argv[1], int(sys.argv[2], 0), int(sys.argv[3], 0)
with open(p, "r+b") as f:
    f.seek(lba * 512); t = bytearray(f.read(512)); struct.pack_into("<QQ", t, 0x1c, done, done)
    c = bytearray(t[:0x68]); c[0x14:0x18] = bytes(4); c[0x54:0x58] = bytes(4)
    struct.pack_into("<Q", t, 0, rc_sum(c, 8, 0x60)); f.seek(lba * 512); f.write(t)
PY
}
tlogf() { sudo dd if=$1 bs=512 skip=$(($2)) count=1 status=none | python3 -c '
import sys, struct
b = sys.stdin.buffer.read()
print("%x %d %d %x %x" % (struct.unpack_from("<I", b, 0x18)[0], struct.unpack_from("<Q", b, 0x1c)[0], struct.unpack_from("<I", b, 0x44)[0], struct.unpack_from("<I", b, 0x2c)[0], struct.unpack_from("<I", b, 0x30)[0]))'; }
ldring() {	# ldring <image> <LD ID> <packet number>: LD records with this ID in the ring packet with this number (hex); ID 0:
		# offsets and sizes of sections 25BE/25BF from the packet header
	python3 - "$@" <<'PY'
import struct, sys
img, ldid, gen = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3])
r = open(img, "rb"); r.seek(0x5800 * 512); ring = r.read(0x800 * 512); lba = 0
while lba < 0x800:
    o = lba * 512
    if struct.unpack_from("<Q", ring, o + 0xc)[0] != 0xe1e10000: lba += 1; continue
    size = struct.unpack_from("<I", ring, o + 0x18)[0]
    if not 0x200 <= size <= 0x100000 or o + size > len(ring): lba += 1; continue
    p = ring[o:o + size]; q, end = struct.unpack_from("<II", p, 0x2c); end += q; out = []
    while q + 0x200 <= end and struct.unpack_from("<I", p, q)[0] == 0x25BD and struct.unpack_from("<I", p, q + 0x90)[0]:
        sz = struct.unpack_from("<I", p, q + 0x90)[0]
        if struct.unpack_from("<Q", p, q + 0x2c)[0] == ldid: out.append(p[q:q + sz].hex())
        q += sz
    if ldid == 0: out = [p[0x40:0x50].hex()]
    if struct.unpack_from("<Q", p, 0x34)[0] == gen: print("|".join(out))
    lba += (size + 511) // 512
PY
}
if want 15; then
MG=$FIXT/2026-11-07-rcraid-migrations; mkdir -p $WQ/m; rm -f $WQ/m/*
for s in m1-mid m1-post m2-mid; do for i in 0 1 2 3 4; do
	f=$WQ/m/$s-$i.img; truncate -s 64G $f
	xz -dc $MG/$s-sata$i-lba0-6000.img.xz | dd of=$f conv=notrunc status=none
	for b in $MG/$s-sata$i-lba0x*.bin; do [ -e "$b" ] || continue; l=${b##*-lba}; l=${l%.bin}; dd if=$b of=$f bs=512 seek=$((l)) conv=notrunc status=none; done
done; done
MGL=(); for i in 0 1 2 3 4; do MGL[$i]=$(sudo losetup -f --show $WQ/m/m1-mid-$i.img); done
check "m1 (RAIDABLE -> RAID1 by the AMD driver, 34 %): -E — md raid1 read-write, the migration and its progress" "$M -E ${MGL[3]} 2>/dev/null | sed -n '/Volume ID : 2017d15d59ca496b/,/Member/p' | grep -q 'RAID Level : raid1' && $M -E ${MGL[3]} 2>/dev/null | sed -n '/Volume ID : 2017d15d59ca496b/,/Member/p' | grep -q 'md support : read-write' && $M -E ${MGL[3]} 2>/dev/null | grep -q 'Migration : RAIDABLE 1 x 1, 65014 MiB -> RAID10N 1 x 2, 65014 MiB; 34% done'"
echo 50000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
for l in ${MGL[@]}; do $M -I $l >/dev/null 2>&1; done; sleep 3
MR=$(for m in $(ls /sys/block | grep ^md); do [ "$(cat /sys/block/$m/size)" = 133148672 ] && echo $m; done)
check "m1: md raid1 [2/1], the new disk (sata1, 0x105000) recovers from the log's 0x2bb3000; the other volumes run" "[ -n '$MR' ] && grep -A2 \"^$MR \" /proc/mdstat | grep -q '\[2/1\]' && [ \$(cut -d' ' -f1 /sys/block/$MR/md/sync_completed) -ge $((0x2bb3000)) ] && [ \$(basename \$(readlink -f /sys/block/$MR/md/rd1/block)) = \$(basename ${MGL[1]}) ] && [ \$(cat /sys/block/$MR/md/rd1/offset) = $((0x105000)) ] && [ \$(active raid5) = 1 ]"
sleep 2; $M -S /dev/$MR >/dev/null 2>&1; sleep 1
T3=$(tlogf ${MGL[3]} 0x100000); T1=$(tlogf ${MGL[1]} 0x100000); D3=$(echo $T3 | cut -d' ' -f2)
check "m1 stopped midway: the log (0x5354, STARTED, I/O 0x600, flags 0x2022241) is further on, on a 0x4800 boundary, on both" "[ '$T3' = '$T1' ] && [ \"\$(echo '$T3' | cut -d' ' -f1,3,4,5)\" = '5354 1 600 2022241' ] && [ $D3 -gt $((0x2bb3000)) ] && [ \$(($D3 % 0x4800)) = 0 ]"
stopall; echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
for i in 1 3; do amdtlog $WQ/m/m1-mid-$i.img 0x100000 $(( (0x7efb000 - 0x40000) / 0x4800 * 0x4800 )); done
for l in ${MGL[@]}; do $M -I $l >/dev/null 2>&1; done; sleep 2; waitrec; sleep 3; stopall
check "m1 ended: log cleared on both; LD records of the \"100 %\" and final packets = AMD's 15 and 16 in m1-post, one later (mdmon took the rcraid set over first) and with AMD's serial, byte for byte" "[ \"\$(tlogf ${MGL[3]} 0x100000)\" = '0 0 0 0 0' ] && [ \"\$(tlogf ${MGL[1]} 0x100000)\" = '0 0 0 0 0' ] && (for g in 15 16; do [ -n \"\$(ldring $WQ/m/m1-post-3.img 2017d15d59ca496b \$g)\" ] && [ \"\$(ldring $WQ/m/m1-mid-3.img 2017d15d59ca496b \$((g + 1)))\" = \"\$(ldring $WQ/m/m1-post-3.img 2017d15d59ca496b \$g | sed s/0000908522100000/0000221090850000/g)\" ] || exit 1; done)"
check "m1 ended: 25BE/25BF section offsets in the header of the \"100 %\" and final packets = AMD's 15 and 16 (empty 25BF right behind 25BE)" "(for g in 15 16; do [ -n \"\$(ldring $WQ/m/m1-post-3.img 0 \$g)\" ] && [ \"\$(ldring $WQ/m/m1-mid-3.img 0 \$((g + 1)))\" = \"\$(ldring $WQ/m/m1-post-3.img 0 \$g)\" ] || exit 1; done)"
for l in ${MGL[@]}; do $M -I $l >/dev/null 2>&1; done; sleep 3
MR=$(for m in $(ls /sys/block | grep ^md); do [ "$(cat /sys/block/$m/size)" = 133148672 ] && echo $m; done)
check "m1 reassembled: RAID1 [2/2], no resync or recovery" "grep -A2 \"^$MR \" /proc/mdstat | grep -q '\[2/2\] \[UU\]' && ! grep -A3 \"^$MR \" /proc/mdstat | grep -qE 'resync|recovery'"
stopall; for l in ${MGL[@]}; do sudo losetup -d $l; done
# 15c. The new disk did not come: -I waits for it (RAID1 of two); -IRs: volume [2/1]; while md does not write, the log stays; md wrote:
# the log from 0; the disk came: copy from 0
for i in 0 1 2 3 4; do f=$WQ/m/m1-mid-$i.img; rm -f $f; truncate -s 64G $f; xz -dc $MG/m1-mid-sata$i-lba0-6000.img.xz | dd of=$f conv=notrunc status=none; done
for i in 1 3; do dd if=$MG/m1-mid-sata$i-lba0x100000.bin of=$WQ/m/m1-mid-$i.img bs=512 seek=$((0x100000)) conv=notrunc status=none; done
MGL=(); for i in 0 1 2 3 4; do MGL[$i]=$(sudo losetup -f --show $WQ/m/m1-mid-$i.img); done
echo 1000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
for i in 0 2 3 4; do $M -I ${MGL[$i]} >/dev/null 2>&1; done; sleep 2
check "m1 -I without the new disk: the RAIDABLE waits for it (a RAID1 of two), the other volumes run" "[ -z \"\$(grep -A1 'active raid1' /proc/mdstat | grep 66574336)\" ] && [ \$(active raid5) = 1 ]"
$M -IRs >/dev/null 2>&1; sleep 3
MR=$(for m in $(ls /sys/block | grep ^md); do [ "$(cat /sys/block/$m/size)" = 133148672 ] && echo $m; done)
check "m1 run without it (-IRs), nothing written: [2/1], the log kept (34 %)" "grep -A2 \"^$MR \" /proc/mdstat | grep -q '\[2/1\]' && [ \$(tlogf ${MGL[3]} 0x100000 | cut -d' ' -f2) = $((0x2bb3000)) ]"
echo m1 | sudo dd of=/dev/$MR bs=4096 count=1 seek=100 oflag=direct conv=sync status=none; sleep 2
check "m1, md wrote without the new disk: the log on the RAIDABLE's disk back to 0, the away disk's still 34 %" "[ \"\$(tlogf ${MGL[3]} 0x100000 | cut -d' ' -f1-3)\" = '5354 0 1' ] && [ \$(tlogf ${MGL[1]} 0x100000 | cut -d' ' -f2) = $((0x2bb3000)) ]"
$M -I ${MGL[1]} >/dev/null 2>&1; sleep 3
check "m1: the disk back — copied from the start" "grep -A3 \"^$MR \" /proc/mdstat | grep -q recovery && [ \$(cut -d' ' -f1 /sys/block/$MR/md/sync_completed) -lt $((0x100000)) ]"
stopall; echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null; for l in ${MGL[@]}; do sudo losetup -d $l; done
MGL=(); for i in 0 1 2 3 4; do MGL[$i]=$(sudo losetup -r -f --show $WQ/m/m2-mid-$i.img); done
check "m2 (RAID1 expansion 2 -> 4 GB, moved to a new extent): -E blocks it and shows the migration" "$M -E ${MGL[0]} 2>/dev/null | sed -n '/Subarray : 0/,/Subarray : 1/p' | grep -q 'md support : none - a migration is in progress' && $M -E ${MGL[0]} 2>/dev/null | grep -q 'Migration : RAID10N 1 x 2, 2048 MiB -> RAID10N 1 x 2, 3906 MiB; 1% done'"
for l in ${MGL[@]}; do sudo losetup -d $l; done; rm -f $WQ/m/*
# 15b. mdadm --grow <RAIDABLE> --raid-devices=2 (RAIDABLE from the BIOS menu, snapshot 04, shrunk to 512 MiB, its RAID1 to 32 MiB)
dset 04-raidable 840a7c70b562 0x10000 88a5d4fa2af7 0x100000
truncate -s 64G $WQ/d/gs.img; GS=$(sudo losetup -f --show $WQ/d/gs.img)
$M -A /dev/md/gr -e amd $(DL sata0) $(DL sata1) $(DL sata2) $(DL sata3) >/dev/null 2>&1; $M -I /dev/md/gr >/dev/null 2>&1; sleep 2; waitrec
GR=$(for m in $(ls /sys/block | grep ^md); do [ "$(cat /sys/block/$m/size)" = 1048576 ] && echo $m; done)
head -c 8M /dev/urandom > $TMPW/amd-gr.bin; sudo dd if=$TMPW/amd-gr.bin of=/dev/$GR bs=1M oflag=direct status=none
OUT=$($M --grow /dev/$GR --raid-devices=2 2>&1)
OUT2=$($M --grow /dev/$GR --raid-devices=2 --force 2>&1)
check "--grow -n 2 of a RAIDABLE without a global spare (sata2 is a dedicated one): refused (Grow.c: container's spares; --force: AMD's check), raid_disks 1" "echo \"\$OUT\" | grep -q 'Need 1 spare to avoid degraded array, and only have 0' && echo \"\$OUT2\" | grep -q 'no AMD spare for the mirror' && [ \$(cat /sys/block/$GR/md/raid_disks) = 1 ]"
check "--grow -n 2 of the container: refused" "refused $M --grow /dev/md/gr --raid-devices=2 >/dev/null 2>&1"
$M /dev/md/gr --add $GS >/dev/null 2>&1; sleep 2
echo 3000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
$M --grow /dev/$GR --raid-devices=2 >/dev/null 2>&1; sleep 5
check "--grow -n 2 with a global spare: md raid1 [2/1] recovers onto it; recorded as AMD: log 0x5354 on both, then the packet with both LDs" "[ \$(cat /sys/block/$GR/md/raid_disks) = 2 ] && [ -e /sys/block/$GR/md/dev-\$(basename $GS) ] && [ \"\$(tlogf $(DL sata3) 0x100000 | cut -d' ' -f1,3)\" = '5354 1' ] && [ \"\$(tlogf $GS 0x100000 | cut -d' ' -f1,3)\" = '5354 1' ] && python3 $TOOLS/amdraid_dump.py --brief $WQ/d/sata3.img | grep -q '88a5d4fa2af7 RAIDABLE NORMAL   1x1 .* x2'"
$M -S /dev/$GR >/dev/null 2>&1; sleep 1; GD=$(tlogf $(DL sata3) 0x100000 | cut -d' ' -f2)
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
$M -I /dev/md/gr >/dev/null 2>&1; sleep 1
check "stopped midway, reassembled: md goes on from the log ($GD)" "[ $GD -gt 0 ] && [ \$(cut -d' ' -f1 /sys/block/$GR/md/sync_completed) -ge $GD ]"
waitrec; sleep 3
echo check | sudo tee /sys/block/$GR/md/sync_action >/dev/null; sleep 1; waitrec
check "done: [2/2] [UU], data as written, md check clean" "grep -A2 \"^$GR \" /proc/mdstat | grep -q '\[2/2\] \[UU\]' && cmp -s $TMPW/amd-gr.bin <(sudo dd if=/dev/$GR bs=1M count=8 iflag=direct status=none) && [ \$(cat /sys/block/$GR/md/mismatch_cnt) = 0 ]"
stopall
check "final packet: one LD R10N 1x2 NORMAL on the RAIDABLE's disk and the spare, log cleared" "python3 $TOOLS/amdraid_dump.py --brief $WQ/d/sata3.img | grep -q '88a5d4fa2af7 R10N   NORMAL   1x2 .*\[4:3186 ' && [ \"\$(tlogf $WQ/d/sata3.img 0x100000)\" = '0 0 0 0 0' ] && [ \"\$(tlogf $WQ/d/gs.img 0x100000)\" = '0 0 0 0 0' ]"
sudo losetup -d $GS; for n in $DN; do sudo losetup -d $(DL $n) 2>/dev/null; done; rm -rf $WQ/d $TMPW/amd-gr.bin
# 15d. AMD packet "100 %" (ring m1-post, packet 15; log already zeroed, as in m1-post) is live: with all disks mdmon
# finishes at once (our final packet is number 16 too, last in the ring, = AMD's packet 16); without the new disk and with md writes: back to the start, log 0, copy from 0
amdcommit() {	# amdcommit <image> <packet number>: commit block pointed at the ring packet with this number (an older state)
	python3 - "$@" <<'PY'
import os, struct, sys
sys.path.insert(0, os.environ["TOOLS"]); from amdraid_dump import rc_sum
p, gen = sys.argv[1], int(sys.argv[2])
with open(p, "r+b") as f:
    f.seek(0x5800 * 512); ring = f.read(0x800 * 512); lba = 0
    while lba < 0x800:
        o = lba * 512
        if struct.unpack_from("<Q", ring, o + 0xc)[0] != 0xe1e10000: lba += 1; continue
        size = struct.unpack_from("<I", ring, o + 0x18)[0]
        if struct.unpack_from("<Q", ring, o + 0x34)[0] == gen:
            f.seek(0x5001 * 512); c = bytearray(f.read(512))
            struct.pack_into("<IIQQ", c, 8, 0x5800 + lba, size, struct.unpack_from("<Q", ring, o)[0], gen + 1)
            struct.pack_into("<Q", c, 0, rc_sum(c, 8, 0x1f8)); f.seek(0x5001 * 512); f.write(c); break
        lba += max(1, (size + 511) // 512)
PY
}
m1ld() { python3 $TOOLS/amdraid_dump.py $WQ/m/m1-post-3.img 2>/dev/null | sed -n "/id=2017d15d59ca496b  type=$1/,+1p"; }
mk100() { for i in 0 1 2 3 4; do f=$WQ/m/m1-post-$i.img; rm -f $f; truncate -s 64G $f
	xz -dc $MG/m1-post-sata$i-lba0-6000.img.xz | dd of=$f conv=notrunc status=none; amdcommit $f 15; done; }
mk100
check "m1 \"100 %\" packet live (fixture): two LDs, the RAIDABLE COMPLETED at 100000, log cleared" "m1ld 0x1bfb | grep -q 'state=0xa1a6 100000%' && [ \"\$(tlogf $WQ/m/m1-post-3.img 0x100000)\" = '0 0 0 0 0' ]"
MGL=(); for i in 0 1 2 3 4; do MGL[$i]=$(sudo losetup -f --show $WQ/m/m1-post-$i.img); done
for l in ${MGL[@]}; do $M -I $l >/dev/null 2>&1; done; sleep 3; waitrec; sleep 3; stopall
xz -dc $MG/m1-post-sata3-lba0-6000.img.xz > $TMPW/amd-m1p3.img
check "m1 \"100 %\", all disks: md copies the last MiB, the final packet = AMD's 16, one later (taken over first) and with AMD's serial, byte for byte" "[ -n \"\$(ldring $TMPW/amd-m1p3.img 2017d15d59ca496b 16)\" ] && [ \"\$(ldring $WQ/m/m1-post-3.img 2017d15d59ca496b 17 | tail -1)\" = \"\$(ldring $TMPW/amd-m1p3.img 2017d15d59ca496b 16 | sed s/0000908522100000/0000221090850000/g)\" ]"
rm -f $TMPW/amd-m1p3.img; for l in ${MGL[@]}; do sudo losetup -d $l; done
mk100; MGL=(); for i in 0 1 2 3 4; do MGL[$i]=$(sudo losetup -f --show $WQ/m/m1-post-$i.img); done
echo 1000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
for i in 0 2 3 4; do $M -I ${MGL[$i]} >/dev/null 2>&1; done; $M -IRs >/dev/null 2>&1; sleep 3
MR=$(for m in $(ls /sys/block | grep ^md); do [ "$(cat /sys/block/$m/size)" = 133148672 ] && echo $m; done)
check "m1 \"100 %\" without the new disk, nothing written: kept" "grep -A2 \"^$MR \" /proc/mdstat | grep -q '\[2/1\]' && m1ld 0x1bfb | grep -q 'state=0xa1a6 100000%'"
echo m1 | sudo dd of=/dev/$MR bs=4096 count=1 seek=100 oflag=direct conv=sync status=none; sleep 2
check "m1 \"100 %\", md wrote without the new disk: back to the start packet, log 0" "m1ld 0x1bfb | grep -q 'transform=NORMAL last=NORMAL state=0x0 0% protect_start=0x0' && m1ld 0x1bf6 | grep -q 'transform=- last=NORMAL state=0x0 0% protect_start=0x0' && [ \"\$(tlogf ${MGL[3]} 0x100000 | cut -d' ' -f1-3)\" = '5354 0 1' ]"
$M -I ${MGL[1]} >/dev/null 2>&1; sleep 3
check "m1 \"100 %\": the disk back is copied from 0, not taken for done" "grep -A3 \"^$MR \" /proc/mdstat | grep -q recovery && [ \$(cut -d' ' -f1 /sys/block/$MR/md/sync_completed) -lt $((0x100000)) ]"
stopall; echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null; for l in ${MGL[@]}; do sudo losetup -d $l; done
rm -f $WQ/m/*
fi

# --- stage 9b: a recorded rebuild (RESTORE_SEGMENTS) whose target (a global spare) did not come to the assembly. md wrote
# nothing: the log is untouched, the next assembly continues from the mark (as 5b, 7e, 10); a target that comes to an already
# running volume (-I after -IRs) is copied from 0, and the log restarts from 0 (as IMSM). md wrote without
# it: the log from 0 at once (md writes seen by stat of the volume's block device), the target copied from 0, md check clean.
if want 9b; then
rtl() { tlogf $1 0x100000 | cut -d' ' -f2,3; }
roff() { sudo python3 $TOOLS/amdraid_dump.py $RR0 2>/dev/null | grep -c 'RAIDCORE_DISK OFFLINE'; }	# PD OFFLINE in the live packet
rset() {	# RAID1 256 MiB on r0+r1, global spare r2; r1 failed, rebuild onto r2 stopped midway
	stopall; for l in $(sudo losetup -a | grep $WQ/rr/ | cut -d: -f1); do sudo losetup -d $l; done
	mkdir -p $WQ/rr; rm -f $WQ/rr/*; for n in 0 1 2; do truncate -s 1G $WQ/rr/r$n.img; done
	RR0=$(sudo losetup -f --show $WQ/rr/r0.img); RR1=$(sudo losetup -f --show $WQ/rr/r1.img); RR2=$(sudo losetup -f --show $WQ/rr/r2.img)
	echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
	$M -C /dev/md/amdrr -e amd -n 2 $RR0 $RR1 --run >/dev/null 2>&1
	$M -C /dev/md/rr1 -e amd -l1 -n2 -z 256M $RR0 $RR1 --run >/dev/null 2>&1; sleep 2; waitrec
	RRC=$(cont1); RRM=$(mdof raid1)
	$M /dev/$RRC --add $RR2 >/dev/null 2>&1; sleep 2
	echo 3000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
	$M /dev/$RRM --fail $RR1 >/dev/null 2>&1; sleep 8; stopall
	echo 1000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
	$M -I $RR0 >/dev/null 2>&1; $M -I $RR1 >/dev/null 2>&1; $M -IRs >/dev/null 2>&1; sleep 3; RRM=$(mdof raid1)
}
rset; RP=$(rtl $RR0 | cut -d' ' -f1)
check "9b: rebuild recorded midway ($RP), started without its target, nothing written: the log kept" "[ \$(rtl $RR0 | cut -d' ' -f2) = 1 ] && [ $RP -gt 0 ] && [ \$(rtl $RR0 | cut -d' ' -f1) = $RP ]"
$M -I $RR2 >/dev/null 2>&1; sleep 3
check "9b: the target comes to the running volume: copied from 0, its log back below the mark" "[ \$(cut -d' ' -f1 /sys/block/$RRM/md/sync_completed) -lt $RP ] && [ \$(rtl $RR0 | cut -d' ' -f1) -lt $RP ]"
rset; RP=$(rtl $RR0 | cut -d' ' -f1); RG=$(wgen $RR0)
head -c 4M /dev/urandom > $TMPW/amd-rr.bin; sudo dd if=$TMPW/amd-rr.bin of=/dev/$RRM bs=1M oflag=direct status=none; sleep 7
check "9b: md wrote without the target: the log goes to 0 (was $RP)" "[ \"\$(rtl $RR0)\" = '0 1' ]"
# AMD reads the log through element [0][0] of the target: in slot 0 that is the target's old copy.
# So a configuration is written too: the target misses it and goes stale (its PD OFFLINE since the assembly), AMD copies it from 0
check "9b: ... and a configuration is written without the target: its disk stale" "[ \$(wgen $RR0) -gt $RG ] && [ \$(wgen $RR2) = $RG ]"
$M -I $RR2 >/dev/null 2>&1; sleep 3
check "9b: the target comes: copied from 0" "[ \$(cut -d' ' -f1 /sys/block/$RRM/md/sync_completed) -lt $RP ]"
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null; waitrec; sleep 3
echo check | sudo tee /sys/block/$RRM/md/sync_action >/dev/null; sleep 1; waitrec
check "9b: done, md check clean, the data written without the target is on it" "grep -A2 \"^$RRM \" /proc/mdstat | grep -q '\[2/2\] \[UU\]' && [ \$(cat /sys/block/$RRM/md/mismatch_cnt) = 0 ] && cmp -s $TMPW/amd-rr.bin <(sudo dd if=$RR2 bs=512 skip=\$(cat /sys/block/$RRM/md/dev-\$(basename $RR2)/offset) count=8192 iflag=direct status=none)"
check "9b: the end of the rebuild written, the stale target current again, its PD online" "[ \$(wgen $RR2) = \$(wgen $RR0) ] && [ \$(roff) = 0 ]"
stopall; for l in $RR0 $RR1 $RR2; do sudo losetup -d $l; done; rm -rf $WQ/rr $TMPW/amd-rr.bin
fi

# 16. -C without -e (the generic Create.c with our changes; it used to SIGSEGV when mdadm.conf sets no metadata):
# 1.2 by default, as upstream
if want 16; then
mkdir -p $WQ/ne && for i in 0 1; do truncate -s 256M $WQ/ne/n$i.img; done
NE0=$(sudo losetup -f --show $WQ/ne/n0.img); NE1=$(sudo losetup -f --show $WQ/ne/n1.img)
OUT=$($M -C /dev/md/netest -l1 -n2 $NE0 $NE1 --run 2>&1); RC=$?
check "16: -C without -e: 1.2 by default, no crash" "[ $RC = 0 ] && echo \"\$OUT\" | grep -q 'Defaulting to version 1.2'"
$M -S /dev/md/netest >/dev/null 2>&1; $M --zero-superblock $NE0 $NE1 >/dev/null 2>&1
for l in $NE0 $NE1; do sudo losetup -d $l; done; rm -rf $WQ/ne
fi

# --- stage 17: md bitmap (md write-intent bitmap, bitmap/metadata=external, as IMSM) in the reserved area of the AMD volume:
# AllocatedSpace + 0x100 (our header, 4 KiB) and the bits from + 0x108 on each element.
# "Crash": copies of the images while the volume writes (md sets a bit before writing data, mdmon the AMD bitmap and the header), then
# a clean stop and the copies put back. "Bits only" probe: 1 MiB of corruption on a member in a dirty chunk (resync fixes it)
# and in a clean one (resync leaves it: check finds exactly it).
if want 17; then
for l in $(sudo losetup -a | grep $WQ/bm/ | cut -d: -f1); do sudo losetup -d $l; done
mkdir -p $WQ/bm && rm -f $WQ/bm/*
BMAS=$((0x100000)); BMDATA=$((0x105000))	# AllocatedSpace and the data start of volumes -C makes on blank disks
bmloop() { sudo losetup -j $WQ/bm/$1.img | cut -d: -f1; }
bmcn() { cont1; }
bmvol() { for m in $(ls /sys/block | grep ^md); do grep -qx "external:/$(bmcn)/$1" /sys/block/$m/md/metadata_version 2>/dev/null && echo $m; done; }
# fields of the "md Bitmap" line in a member's -E: "<KiB per bit> <set> <total> <bits LBA>", empty: no header
bmE() { $M -E $1 2>/dev/null | sed -n "/^\[$2\]/,/^\[/s/^ *md Bitmap : \([0-9]*\) KiB a bit, \([0-9]*\) of \([0-9]*\) set (this disk), at \([0-9]*\)$/\1 \2 \3 \4/p"; }
# wait until the md bitmap daemon (time_base 5 s) clears the bits: ~15-20 s after the last write
bmwait0() { local i; for i in $(seq 1 60); do [ "$(bmE $1 $2 | cut -d' ' -f2)" = 0 ] && return 0; sleep 1; done; return 1; }
bmtrust() { $M -E $1 2>/dev/null | sed -n "/^\[$2\]/,/^\[/s/^ *md Bitmap mdmon : //p"; }
# 1 MiB of random data into a member image at offset <MiB from the data start>
bmspoil() { head -c 1M /dev/urandom | dd of=$WQ/bm/$1.img bs=1M seek=$(( BMDATA / 2048 + $2 )) conv=notrunc status=none; }
bmcheck() { echo check | sudo tee /sys/block/$1/md/sync_action >/dev/null; sleep 1; waitrec; cat /sys/block/$1/md/mismatch_cnt; }
bmrepair() { echo repair | sudo tee /sys/block/$1/md/sync_action >/dev/null; sleep 1; waitrec; bmcheck $1; }
bmup() { for n in "$@"; do $M -I $(bmloop $n) >/dev/null 2>&1; done; sleep 2; }
# "crash" of volume $1: a write loop at MiB $2 of the volume, copies of images $3..., clean stop, copies put back
bmcrash() {
	local v=$1 at=$2 n w; shift 2
	( while :; do sudo dd if=/dev/urandom of=/dev/$v bs=1M count=4 seek=$at oflag=direct status=none; done ) & w=$!
	sleep 3
	for n in "$@"; do cp --sparse=always $WQ/bm/$n.img $WQ/bm/$n.crash; done
	kill $w; wait $w 2>/dev/null
	stopall
	for n in "$@"; do sudo losetup -d $(bmloop $n); mv $WQ/bm/$n.crash $WQ/bm/$n.img; sudo losetup -f $WQ/bm/$n.img; done
}
bmamdbit() { printf "\\x$(printf %02x $((1 << ($2 & 7))))" | dd of=$WQ/bm/$1.img bs=1 seek=$(( (BMAS + 0x80) * 512 + $2 / 8 )) conv=notrunc status=none; }

# 17a. RAID1, RAID10, RAID5: -C --bitmap=internal, -E/-D, crash → resync by bits only; a foreign session (an AMD bitmap bit,
# as the AMD driver would leave it) → md bits from the AMD bitmap
bmlevel() {	# bmlevel <level> <disks> <volume MiB to write> <member MiB: dirty chunk> <clean chunk> <clean, outside AMD bit 3>
	local lv=$1 n=$2 wr=$3 dirty=$4 clean=$5 far=$6 i D="" V P
	for i in $(seq 0 $((n - 1))); do truncate -s 2G $WQ/bm/l$i.img; D="$D l$i"; sudo losetup -f $WQ/bm/l$i.img; done
	$M -C /dev/md/bmc -e amd -n $n $(for i in $D; do bmloop $i; done) --run >/dev/null 2>&1
	$M -C /dev/md/bmv -e amd -l$lv -n$n -z 512M --bitmap=internal $(for i in $D; do bmloop $i; done) --run >/dev/null 2>&1
	V=$(bmvol 0); waitrec; bmwait0 $(bmloop l0) bmv
	check "17a raid$lv: -C --bitmap=internal: policy bitmap, md bitmap at AllocatedSpace + 0x108, 64 MiB a bit" "[ -n '$V' ] && [ \$(cat /sys/block/$V/md/consistency_policy) = bitmap ] && [ \$(cat /sys/block/$V/md/bitmap/location) = +$((BMAS + 0x108)) ] && [ \$(cat /sys/block/$V/md/bitmap/chunksize) = 67108864 ] && [ \$(cat /sys/block/$V/md/bitmap/metadata) = external ]"
	check "17a raid$lv: -D says bitmap; the header on every member (-E), bits cleared by the initialization" "$M -D /dev/$V | grep -q 'Consistency Policy : bitmap' && (for i in $D; do [ \"\$(bmE \$(bmloop \$i) bmv | cut -d' ' -f1,2,4)\" = '65536 0 $((BMAS + 0x108))' ] || exit 1; done)"
	bmcrash $V $wr $D
	check "17a raid$lv: crash copy: AMD bitmap dirty, md bits set ($(bmE $(bmloop l0) bmv | cut -d' ' -f2)), header: mdmon's AMD state" "[ \$(bmE \$(bmloop l0) bmv | cut -d' ' -f2) -ge 1 ] && [ \$(bmE \$(bmloop l0) bmv | cut -d' ' -f2) -le 2 ] && bmtrust \$(bmloop l0) bmv | grep -q 'dirty from bit 0'"
	bmspoil l1 $dirty; bmspoil l1 $clean
	bmup $D; V=$(bmvol 0); waitrec
	P=$(bmcheck $V)
	check "17a raid$lv: reassembled: resync of the dirty chunk only - spoiled MiB there fixed, the one in a clean chunk left ($P)" "[ '$P' = 2048 ]"
	P=$(bmrepair $V)
	check "17a raid$lv: repair, check 0; policy bitmap again" "[ '$P' = 0 ] && [ \$(cat /sys/block/$V/md/consistency_policy) = bitmap ]"
	stopall
	# foreign session: after a clean stop under Linux the AMD driver wrote and crashed: bit 3 in its bitmap (covers ~108 MiB of the volume);
	# corruption in a clean md chunk under this bit and in a clean chunk outside it
	bmamdbit l0 3; bmspoil l1 $clean; bmspoil l1 $far
	bmup $D; V=$(bmvol 0); waitrec
	P=$(bmcheck $V); sleep 6
	check "17a raid$lv: AMD bitmap not as mdmon left it (AMD driver's bit 3): md bits from it - spoiled MiB under it fixed, the other left ($P)" "[ '$P' = 2048 ]"
	check "17a raid$lv: and the headers say mdmon's state again" "bmtrust \$(bmloop l1) bmv | grep -q 'AMD bitmap clean'"
	bmrepair $V >/dev/null
	stopall
	for i in $D; do sudo losetup -d $(bmloop $i); done; rm -f $WQ/bm/*
}
bmlevel 1 2 136 140 330 480
bmlevel 10 4 136 69 200 240
bmlevel 5 3 136 69 200 300

# 17b. RAID1: a foreign configuration (AMD packet number changed, AMD bitmap the same "dirty from 0") → full resync;
# garbage in place of the md bitmap on one member (a rebuild by the AMD driver) → rewritten; --update=no-bitmap/bitmap
for i in 0 1 2; do truncate -s 2G $WQ/bm/g$i.img; sudo losetup -f $WQ/bm/g$i.img; done
$M -C /dev/md/bmc -e amd -n 3 $(bmloop g0) $(bmloop g1) $(bmloop g2) --run >/dev/null 2>&1
$M -C /dev/md/bmv -e amd -l1 -n2 -z 512M --bitmap=internal $(bmloop g0) $(bmloop g1) --run >/dev/null 2>&1
V=$(bmvol 0); waitrec; bmwait0 $(bmloop g0) bmv
bmcrash $V 136 g0 g1 g2
bmspoil g1 330
$M -A /dev/md/bmc -e amd $(bmloop g0) $(bmloop g1) $(bmloop g2) >/dev/null 2>&1
CG=$($M -E $(bmloop g0) | sed -n 's/^ *Generation : //p')
$M --update-subarray=0 --update=name -N bmw /dev/$(bmcn) >/dev/null 2>&1
$M -I /dev/$(bmcn) >/dev/null 2>&1; sleep 2; V=$(bmvol 0); waitrec
P=$(bmcheck $V)
check "17b: AMD configuration written since (generation $CG -> $($M -E $(bmloop g0) | sed -n 's/^ *Generation : //p')): md bits not trusted, all resynced ($P)" "[ '$P' = 0 ]"
stopall
head -c 1M /dev/urandom | dd of=$WQ/bm/g1.img bs=512 seek=$((BMAS + 0x100)) conv=notrunc status=none
check "17b: garbage over the md bitmap area of member 1: no header there (-E)" "[ -z \"\$(bmE \$(bmloop g1) bmw)\" ] && [ -n \"\$(bmE \$(bmloop g0) bmw)\" ]"
bmup g0 g1 g2; V=$(bmvol 0); waitrec
check "17b: reassembled: policy bitmap (member 0 has the header), member 1's header and bits rewritten, no resync" "[ \$(cat /sys/block/$V/md/consistency_policy) = bitmap ] && [ \"\$(bmE \$(bmloop g1) bmw | cut -d' ' -f1,2)\" = '65536 0' ] && [ \$(cat /sys/block/$V/md/resync_start) = none ]"
check "17b: --update=no-bitmap refused while the volume runs" "! $M --update-subarray=0 --update=no-bitmap /dev/$(bmcn) >/dev/null 2>&1 && [ -n \"\$(bmE \$(bmloop g1) bmw)\" ]"
$M -S /dev/$V >/dev/null 2>&1; sleep 1
$M --update-subarray=0 --update=no-bitmap /dev/$(bmcn) >/dev/null 2>&1; RC=$?
check "17b: --update=no-bitmap on the stopped volume: headers cleared on all members" "[ $RC = 0 ] && [ -z \"\$(bmE \$(bmloop g0) bmw)\" ] && [ -z \"\$(bmE \$(bmloop g1) bmw)\" ]"
$M -I /dev/$(bmcn) >/dev/null 2>&1; sleep 2; V=$(bmvol 0)
check "17b: ... assembled with the resync policy" "[ \$(cat /sys/block/$V/md/consistency_policy) = resync ]"
$M -S /dev/$V >/dev/null 2>&1; sleep 1
$M --update-subarray=0 --update=bitmap /dev/$(bmcn) >/dev/null 2>&1; RC=$?
check "17b: --update=bitmap: headers on all members, every bit set" "[ $RC = 0 ] && [ \"\$(bmE \$(bmloop g0) bmw | cut -d' ' -f1-3)\" = '65536 8 8' ] && [ \"\$(bmE \$(bmloop g1) bmw | cut -d' ' -f1-3)\" = '65536 8 8' ]"
$M -I /dev/$(bmcn) >/dev/null 2>&1; sleep 2; V=$(bmvol 0)
check "17b: ... assembled with the bitmap, clean: no resync, the daemon clears the bits" "[ \$(cat /sys/block/$V/md/consistency_policy) = bitmap ] && [ \$(cat /sys/block/$V/md/resync_start) = none ] && bmwait0 \$(bmloop g1) bmw"
stopall
for i in 0 1 2; do sudo losetup -d $(bmloop g$i); done; rm -f $WQ/bm/*

# 17c. Elements not on the same LBA: -C --bitmap refused; RAID0: no bitmap; chunk: a --bitmap-chunk that does not fit is refused;
# one that fits is in -E and in the kernel
for i in 0 1 2 3; do truncate -s 8G $WQ/bm/c$i.img; sudo losetup -f $WQ/bm/c$i.img; done
$M -C /dev/md/bmc -e amd -n 4 $(bmloop c0) $(bmloop c1) $(bmloop c2) $(bmloop c3) --run >/dev/null 2>&1
$M -C /dev/md/bma -e amd -l1 -n2 -z 256M --assume-clean $(bmloop c1) $(bmloop c2) --run >/dev/null 2>&1
OUT=$($M -C /dev/md/bmx -e amd -l1 -n2 -z 256M --bitmap=internal $(bmloop c0) $(bmloop c1) --run 2>&1)
check "17c: members at different LBAs (c1 holds another volume first): -C --bitmap refused, nothing created" "echo \"\$OUT\" | grep -q 'do not start at one LBA' && [ -z \"\$(bmvol 1)\" ]"
OUT=$($M -C /dev/md/bmx -e amd -l0 -n2 -z 256M --bitmap=internal $(bmloop c0) $(bmloop c1) --run 2>&1)
check "17c: RAID0 --bitmap refused (mdadm: not meaningful)" "echo \"\$OUT\" | grep -q 'bitmaps not meaningful' && [ -z \"\$(bmvol 1)\" ]"
OUT=$($M -C /dev/md/bmx -e amd -l1 -n2 -z 6G --bitmap=internal --bitmap-chunk=1K --assume-clean $(bmloop c0) $(bmloop c3) --run 2>&1)
check "17c: --bitmap-chunk=1K for 6 GiB: 6 Mi bits do not fit the area - refused" "echo \"\$OUT\" | grep -q 'more bits than the 636 KiB AMD leaves' && [ -z \"\$(bmvol 1)\" ]"
$M -C /dev/md/bmx -e amd -l1 -n2 -z 6G --bitmap=internal --bitmap-chunk=4K --assume-clean $(bmloop c0) $(bmloop c3) --run >/dev/null 2>&1
V=$(bmvol 1)
check "17c: --bitmap-chunk=4K: taken (kernel, -E: 1572864 bits), --assume-clean: no bit set" "[ -n '$V' ] && [ \$(cat /sys/block/$V/md/bitmap/chunksize) = 4096 ] && [ \"\$(bmE \$(bmloop c0) bmx | cut -d' ' -f1-3)\" = '4 0 1572864' ]"
stopall
for i in 0 1 2 3; do sudo losetup -d $(bmloop c$i); done; rm -f $WQ/bm/*

# 17d. A spare that does not fit the bitmap LBA: RAID1 bmb (d0, d3) after a RAID0 of the same length on each of them; global
# spare: (a) blank 4 GiB: the element goes at the LBA of the others (AMD would take the first free, 0x100000), the bitmap stays;
# (b) 1.2 GiB: no room there: md drops the bitmap before adding the disk, headers wiped, the volume goes on with the resync policy
bmspare() {	# bmspare <spare size> <keep|drop>
	local sz=$1 how=$2 i V X E
	for i in d0 d1 d2 d3; do truncate -s 4G $WQ/bm/$i.img; sudo losetup -f $WQ/bm/$i.img; done
	$M -C /dev/md/bmc -e amd -n 4 $(for i in d0 d1 d2 d3; do bmloop $i; done) --run >/dev/null 2>&1
	$M -C /dev/md/bmz -e amd -l0 -n2 -z 1G $(bmloop d0) $(bmloop d1) --run >/dev/null 2>&1
	$M -C /dev/md/bmy -e amd -l0 -n2 -z 1G $(bmloop d3) $(bmloop d2) --run >/dev/null 2>&1
	$M -C /dev/md/bmb -e amd -l1 -n2 -z 256M --bitmap=internal $(bmloop d0) $(bmloop d3) --run >/dev/null 2>&1
	V=$(bmvol 2); waitrec
	X=$(bmE $(bmloop d0) bmb | cut -d' ' -f4)
	head -c 8M /dev/urandom > $TMPW/bm-sp.bin; sudo dd if=$TMPW/bm-sp.bin of=/dev/$V bs=1M oflag=direct status=none
	truncate -s $sz $WQ/bm/s.img; sudo losetup -f $WQ/bm/s.img
	$M /dev/$(bmcn) --add $(bmloop s) >/dev/null 2>&1; sleep 1
	$M /dev/$V --fail $(bmloop d3) >/dev/null 2>&1; sleep 3; waitrec; sleep 3
	E=$($M -E $(bmloop d0) | sed -n '/^\[bmb\]/,/^\[/s/^ *Member   1 : [0-9a-f]* handle 5 offset \([0-9]*\) .*/\1/p')
	if [ $how = keep ]; then
		check "17d: spare of 4 GiB: rebuilt at the md bitmap's LBA ($E = $X - 0x108 + 0x5000), bitmap kept, header on the spare" "[ -n '$X' ] && [ '$E' = \$(( X - 0x108 + 0x5000 )) ] && [ \$(cat /sys/block/$V/md/consistency_policy) = bitmap ] && [ -n \"\$(bmE \$(bmloop s) bmb)\" ]"
	else
		check "17d: spare of 1.2 GiB, no room at the md bitmap's LBA: rebuilt at 0x105000, md bitmap stopped first (dmesg), headers cleared" "[ '$E' = $BMDATA ] && [ \$(cat /sys/block/$V/md/consistency_policy) = resync ] && sudo dmesg | grep -q 'md bitmap of $V off: the spare has no room' && [ -z \"\$(bmE \$(bmloop d0) bmb)\" ]"
	fi
	check "17d ($how): mirror whole, data in place, md check 0" "grep -A1 \"^$V \" /proc/mdstat | grep -q '\[UU\]' && cmp -s $TMPW/bm-sp.bin <(sudo dd if=/dev/$V bs=1M count=8 iflag=direct status=none) && [ \$(bmcheck $V) = 0 ]"
	stopall
	for i in d0 d1 d2 d3 s; do sudo losetup -d $(bmloop $i); done; rm -f $WQ/bm/* $TMPW/bm-sp.bin
}
bmspare 4G keep
bmspare 1200M drop

# 17e. Bitmap chunk by size: 64 MiB per bit covers 318 TiB (636 KiB of bits), beyond that the chunk doubles. RAID1 on two
# sparse "disks" of 400 TiB (files on btrfs $WQ), --assume-clean: 128 MiB per bit
for i in 0 1; do truncate -s 400T $WQ/bm/h$i.img; sudo losetup -f $WQ/bm/h$i.img; done
$M -C /dev/md/bmc -e amd -n 2 $(bmloop h0) $(bmloop h1) --run >/dev/null 2>&1
$M -C /dev/md/bmh -e amd -l1 -n2 --bitmap=internal --assume-clean $(bmloop h0) $(bmloop h1) --run >/dev/null 2>&1
V=$(bmvol 0)
check "17e: RAID1 of ~400 TiB: 128 MiB a bit (kernel and -E), $(bmE $(bmloop h0) bmh | cut -d' ' -f3) bits" "[ -n '$V' ] && [ \$(cat /sys/block/$V/md/bitmap/chunksize) = 134217728 ] && [ \"\$(bmE \$(bmloop h0) bmh | cut -d' ' -f1,2)\" = '131072 0' ] && [ \$(bmE \$(bmloop h0) bmh | cut -d' ' -f3) -gt 2605056 ]"
check "17e: ... its size from the shape, not the int of KiB (truncated from 2 TiB a member): $(( $(cat /sys/block/$V/size) / 2**31 )) TiB" "[ \$(cat /sys/block/$V/size) -gt \$((399 * 2**31)) ]"
stopall
for i in 0 1; do sudo losetup -d $(bmloop h$i); done; rm -f $WQ/bm/*
fi
# --- end of stage 17 ---
# --- stage 18: udev, a disk pulled while running (remove branch of the AMD rule: mdadm -If, as IMSM) ---
# What -I --export gave udev at add (MD_DEVICE…) is erased by the next change event, so the rule asks md
# (TEST /sys/devices/virtual/block/*/md/dev-<disk>). Five LIO disks: u0, u1 RAID1, u2 free in the container,
# u3 a global spare (--add), u4 with a partition table (like a Legacy disk: no RAIDCore label). The container is created
# on loop from the same files: -C on the "real" disks would refuse if other disks of the machine carry a label (amd_other_raidcore_disk).
if want 18; then
if ! lio_ok; then skip "18" "needs LIO (target_core_mod, target_core_file, tcm_loop) and configfs"; else
stopall
CF=/sys/kernel/config/target; FB=$CF/core/fileio_18; W=naa.5001405018000001; TP=$CF/loopback/$W/tpgt_1
UR=/run/udev/rules.d/64-amd-raid-assembly-test.rules
mkdir -p $WQ/u && rm -f $WQ/u/*.img
UL=""; for n in 0 1 2 3; do truncate -s 1G $WQ/u/u$n.img; UL="$UL $(sudo losetup -f --show $WQ/u/u$n.img)"; done
truncate -s 1G $WQ/u/u4.img; printf 'label: gpt\n,,L\n' | /sbin/sfdisk -q $WQ/u/u4.img >/dev/null 2>&1
set -- $UL
$M -C /dev/md/udc -e amd -n 3 $1 $2 $3 --run >/dev/null 2>&1
CN=$(cont1)
$M -C /dev/md/udm -l1 -n2 -z 256M /dev/$CN --run >/dev/null 2>&1; sleep 1; waitrec; sleep 2
$M /dev/$CN --add $4 >/dev/null 2>&1; sleep 2
stopall; sudo losetup -d $UL; set --
sudo modprobe -a target_core_mod target_core_file tcm_loop
sudo mkdir -p $TP && echo $W | sudo tee $TP/nexus >/dev/null   # nexus before the LUN: otherwise INQUIRY without an I_T nexus
for n in 0 1 2 3 4; do
	sudo mkdir -p $FB/u$n
	echo "fd_dev_name=$WQ/u/u$n.img,fd_dev_size=1073741824" | sudo tee $FB/u$n/control >/dev/null
	echo 1 | sudo tee $FB/u$n/enable >/dev/null
	sudo mkdir $TP/lun/lun_$n && sudo ln -s $FB/u$n $TP/lun/lun_$n/u$n
done
sudo udevadm settle
# LIO disk by LUN number (the sdX name may change after it is back); pull - as libata drops an unplugged disk
# (scsi_remove_device), plug - the LUN anew (tcm_loop calls scsi_add_device: an add event)
U() { local d a; for d in /sys/block/sd*; do a=$(basename "$(readlink -f $d/device)"); [ "$(sed 's/ *$//' $d/device/vendor 2>/dev/null)" = LIO-ORG ] && [ "${a##*:}" = $1 ] && echo /dev/${d##*/}; done; }
pull() { echo 1 | sudo tee /sys/block/$(basename "$(U $1)")/device/delete >/dev/null; sudo udevadm settle; sleep 2; }
plug() { sudo rm $TP/lun/lun_$1/u$1; sudo ln -s $FB/u$1 $TP/lun/lun_$1/u$1; sudo udevadm settle; sleep 2; }
inc() { local d=$(U $1); [ -n "$d" ] && grep "^$CN " /proc/mdstat | grep -q "${d#/dev/}\["; }   # disk u$1 is in the container
ncont() { grep "^$CN " /proc/mdstat | grep -o '\[[0-9]*\](S)' | wc -l; }
rmrun() { sudo udevadm test --action=remove /sys/block/$(basename "$(U $1)") 2>&1 | grep -q "RUN{program} : .*mdadm -If $(U $1)"; }
devid() { [ -n "${1:-}" ] && $M -E $1 2>/dev/null | sed -n 's/^ *Device ID : //p'; }
# assemble from the shell (mdmon not from udev: udev kills processes left after the event), then the rule
for n in 0 1 2 3; do $M -I $(U $n) >/dev/null 2>&1; done; sleep 2
CN=$(cont1)
sudo mkdir -p /run/udev/rules.d
sed -e "s|/usr/bin/mdadm|$MDADM_DIR/mdadm|g; s|/sbin/mdadm|$MDADM_DIR/mdadm|g" \
	-e '/^SUBSYSTEM!="block"/a ENV{ID_VENDOR}!="LIO-ORG", GOTO="amd_raid_end"' "$AMD_RULE" | sudo tee $UR >/dev/null
sudo udevadm control --reload
RV=$(mdof raid1)
check "18: five LIO disks: container of four (u0, u1 in RAID1, u2 free, u3 global spare), u4 partitioned, not in it" "[ -n '$CN' ] && [ -n '$RV' ] && [ \$(ncont) = 4 ] && inc 3 && ! inc 4 && $M -E \$(U 3) | grep -q 'global spare  <- this disk' && grep -A1 '^$RV ' /proc/mdstat | grep -q '\[UU\]'"
check "18: udevadm test, remove: mdadm -If for a disk md holds, nothing for one it does not (u4)" "rmrun 2 && rmrun 0 && ! sudo udevadm test --action=remove /sys/block/\$(basename \$(U 4)) 2>&1 | grep -q 'mdadm -If'"
pull 2
check "18: free member pulled: out of the container, RAID1 intact" "[ \$(ncont) = 3 ] && grep -A1 '^$RV ' /proc/mdstat | grep -q '\[UU\]'"
plug 2
check "18: ... back: udev -I put it into the container (MD_DEVICE=$CN exported)" "inc 2 && udevadm info -q property \$(U 2) | grep -qx 'MD_DEVICE=$CN'"
sudo udevadm trigger -c change --settle $(U 2) $(U 3) $(U 1)
udevadm info -q property $(U 2) | grep -q '^MD_DEVICE=' && echo "info: MD_DEVICE kept after change (this udev keeps imported properties)" || echo "info: MD_DEVICE dropped by the change event (as systemd 257)"
pull 3
check "18: global spare pulled (after a change event): out of the container" "[ \$(ncont) = 3 ] && ! inc 3"
plug 3
check "18: ... back: in the container, still the global spare" "inc 3 && $M -E \$(U 3) | grep -q 'global spare  <- this disk'"
I1=$(devid $(U 1)); I3=$(devid $(U 3))
pull 1; sleep 1; waitrec; sleep 3
check "18: RAID1 member pulled: -If failed it, mdmon wrote its PD OFFLINE and rebuilt onto the spare (NORMAL, member 1 = spare)" "[ -n '$I1' ] && grep -A1 '^$RV ' /proc/mdstat | grep -q '\[UU\]' && $M -E \$(U 0) | grep -qE '^ +[0-9]+ +$I1 +[0-9]+ +raid +0x3001' && $M -E \$(U 0) | grep -q 'State : 0x200' && $M -E \$(U 0) | grep -q 'Member   1 : $I3 '"
check "18: ... mirrors equal" "[ -n \"\$(U 0)\" ] && [ -n \"\$(U 3)\" ] && cmp -s <(sudo dd if=\$(U 0) bs=512 skip=\$(cat /sys/block/$RV/md/dev-\$(basename \$(U 0))/offset) count=$((256 * 2048)) status=none) <(sudo dd if=\$(U 3) bs=512 skip=\$(cat /sys/block/$RV/md/dev-\$(basename \$(U 3))/offset) count=$((256 * 2048)) status=none)"
N=$(ncont); pull 4; plug 4
check "18: partitioned disk (no AMD label) pulled and back: container untouched, -I exported nothing" "[ \$(ncont) = $N ] && ! udevadm info -q property \$(U 4) | grep -q '^MD_DEVICE='"
plug 1
check "18: pulled member back: in the container, not rebuilt onto (failed in this session, as rcraid)" "inc 1 && ! grep -q recover /proc/mdstat && ! grep '^$RV ' /proc/mdstat | grep -q \"\$(basename \$(U 1))\[\""
sudo rm -f $UR; sudo udevadm control --reload
stopall
for n in 0 1 2 3 4; do sudo rm -f $TP/lun/lun_$n/u$n; sudo rmdir $TP/lun/lun_$n; done
sudo rmdir $TP $CF/loopback/$W
for n in 0 1 2 3 4; do sudo rmdir $FB/u$n; done; sudo rmdir $FB
sudo udevadm settle; rm -rf $WQ/u
fi
fi
# --- end of stage 18 ---

# --- stage 19: a stale disk in the container gets the live configuration; -I after it is not refused ---
# Six 1 GiB loops. Incremental compares a new disk with the container's first device (sysfs_read: readdir order
# of md/, by name hash), so the failed member F is the first in that order. F failed, was removed from the container
# and came back (-I): stale, its element failed - the AMD driver does the same (PD ONLINE again, no role).
if want 19; then
stopall
for l in $(sudo losetup -a | grep $WQ/sm/ | cut -d: -f1); do sudo losetup -d $l; done
mkdir -p $WQ/sm && rm -f $WQ/sm/*.img
SM=(); for n in $(seq 0 5); do truncate -s 1G $WQ/sm/s$n.img; SM[$n]=$(sudo losetup -f --show $WQ/sm/s$n.img); done
smid() { $M -E $1 2>/dev/null | sed -n 's/^ *Device ID : //p' | head -1; }
smgen() { $M -E $1 2>/dev/null | sed -n 's/^ *Generation : //p' | head -1; }
smvol() { $M -E $2 2>/dev/null | sed -n "/^\[$1\]:/,/^\[/p"; }
# state of disk $1's PD in the packet on disk $2 (0x3000 ONLINE, 0x3001 OFFLINE)
smpd() { $M -E $2 2>/dev/null | grep -E "^ +[0-9]+  $(smid $1) .* raid " | awk '{print $5}'; }
smfirst() { ls -f /sys/block/$1/md | grep '^dev-' | head -1; }
$M -C /dev/md/smc -e amd -n5 ${SM[@]:0:5} --run >/dev/null 2>&1
SMC=$(basename $(readlink -f /dev/md/smc))
ORD=($(for e in $(ls -f /sys/block/$SMC/md | grep '^dev-'); do echo /dev/${e#dev-}; done))
F=${ORD[0]}; G=${ORD[1]}; X=${ORD[2]}; H=${ORD[3]}; J=${ORD[4]}; K=${SM[5]}
$M -C /dev/md/smr -e amd -l1 -n2 -z 64M $F $G --run >/dev/null 2>&1; waitrec; sleep 2
SMR=$(basename $(readlink -f /dev/md/smr))
$M /dev/$SMR --fail $F >/dev/null 2>&1; sleep 2
$M /dev/$SMC --remove $F >/dev/null 2>&1; sleep 1
$M -I $F >/dev/null 2>&1; sleep 2
check "19: failed member out of the container and back (-I): the live configuration on it (generation $(smgen $F), the other $(smgen $G)), its PD OFFLINE as mdmon wrote it" "[ -e /sys/block/$SMC/md/dev-${F#/dev/} ] && [ \"\$(smgen $F)\" = \"\$(smgen $G)\" ] && [ \"\$(smpd $F $F)\" = 0x3001 ]"
check "19: ... no member again: the volume runs on the other one, -E of the returned disk shows its element failed" "grep -A1 \"^$SMR \" /proc/mdstat | grep -q '\[2/1\]' && smvol smr $F | grep -q \"Member   0 : \$(smid $F) .*(out of service: failed)\""
# dedicated spare: rebuild onto it, F in no volume. Assigning a spare to a degraded volume does not by itself wake
# the spare search (ROLE does not set check_degraded - a separate finding): ATTACH wakes it -
# the free H is removed from the container and returned (same name, so the same readdir order)
$M /dev/md/smr --add-spare $X >/dev/null 2>&1; sleep 1
$M /dev/$SMC --remove $H >/dev/null 2>&1; sleep 1; $M -I $H >/dev/null 2>&1; sleep 2; waitrec; sleep 3
check "19: ... rebuilt onto a dedicated spare: in no volume now, its PD ONLINE again (as rcraid), still current" "grep -A1 \"^$SMR \" /proc/mdstat | grep -q '\[2/2\]' && ! smvol smr $G | grep -q \"\$(smid $F)\" && [ \"\$(smpd $F $G)\" = 0x3000 ] && [ \"\$(smpd $F $F)\" = 0x3000 ] && [ \"\$(smgen $F)\" = \"\$(smgen $G)\" ]"
# a disk added (+1 PD), removed, back: compared with the container's first device, i.e. with F
$M /dev/$SMC --add $K >/dev/null 2>&1; sleep 2
$M /dev/$SMC --remove $K >/dev/null 2>&1; sleep 1
FIRST=$(smfirst $SMC)
OUT=$($M -I $K 2>&1); RC=$?; sleep 2
check "19: a disk added (+1 PD), out and back (-I): taken in (rc $RC; the container's first device $FIRST is the former member ${F#/dev/})" "[ $FIRST = dev-${F#/dev/} ] && [ $RC = 0 ] && [ -e /sys/block/$SMC/md/dev-${K#/dev/} ] && ! echo \"\$OUT\" | grep -q 'unexpected difference'"
stopall
for l in ${SM[@]}; do $M -I $l >/dev/null 2>&1; done; sleep 3
check "19: after a stop, -I of each disk: one container of 6, the RAID1 in step, the former member not in it" "[ \$(grep -c 'super external:amd' /proc/mdstat) = 1 ] && [ \$(ls /sys/block/\$(grep -B1 'super external:amd' /proc/mdstat | head -1 | cut -d' ' -f1)/md | grep -c '^dev-') = 6 ] && grep -q '\[2/2\] \[UU\]' /proc/mdstat && ! grep -E '^md[0-9]+ : active.* raid1 ' /proc/mdstat | grep -q '${F#/dev/}\['"
# the end of initialization is recorded only when all disks of the configuration are here and current (amd_all_disks_here):
# the stale F (no longer failed in this mdmon session) would hold it back forever
$M -C /dev/md/smn -e amd -l1 -n2 -z 64M $H $J --run >/dev/null 2>&1; sleep 2; waitrec; sleep 3
check "19: a new RAID1 on two free disks: the end of its initialization is recorded (no stale disk to wait for)" "smvol smn $G | grep -q 'State : 0x200'"
stopall; for l in ${SM[@]}; do sudo losetup -d $l; done; rm -f $WQ/sm/*.img

# Boot: the free disk B was away when a disk was added (+1 PD); udev gives it first. B has the lowest DeviceID
# (the container UUID comes from it: its old packet has the same); if the added disk has the lowest, B's UUID differs (a separate
# container, as for a stale disk with a foreign UUID), so the set is made again.
for try in 1 2 3 4 5; do
	SB=(); for n in 0 1 2 3 4; do rm -f $WQ/sm/b$n.img; truncate -s 1G $WQ/sm/b$n.img; SB[$n]=$(sudo losetup -f --show $WQ/sm/b$n.img); done
	$M -C /dev/md/sbc -e amd -n4 ${SB[@]:0:4} --run >/dev/null 2>&1
	B=$(for l in ${SB[@]:0:4}; do echo "$(smid $l) $l"; done | sort | head -1 | cut -d' ' -f2)
	BO=(); for l in ${SB[@]:0:4}; do [ $l = $B ] || BO+=($l); done
	$M -C /dev/md/sbr -e amd -l1 -n2 -z 64M ${BO[0]} ${BO[1]} --run >/dev/null 2>&1; waitrec; sleep 2
	stopall
	for l in ${BO[@]}; do $M -I $l >/dev/null 2>&1; done; sleep 2
	SBC=$(cont1)
	OUT=$($M /dev/$SBC --add ${SB[4]} 2>&1); sleep 2
	stopall
	echo "$OUT" | grep -q 'lowest DeviceID' || break
	for l in ${SB[@]}; do sudo losetup -d $l; done
done
BG=$(smgen $B); OG=$(smgen ${BO[0]})
BOUT=$(for l in $B ${BO[@]} ${SB[4]}; do $M -I $l 2>&1; done); sleep 3
check "19: boot, the disk away when one was added comes first (-I): the others are taken in all the same, one container, RAID1 runs (set $try, generation $BG/$OG)" "! echo \"\$BOUT\" | grep -q 'unexpected difference' && [ \$(grep -c 'super external:amd' /proc/mdstat) = 1 ] && grep -q '\[2/2\] \[UU\]' /proc/mdstat"
check "19: ... mdmon gave it the live configuration: the generation of the others, the added disk among its PDs" "[ \"\$(smgen $B)\" = \"\$(smgen ${BO[0]})\" ] && $M -E $B | grep -qE \"^ +[0-9]+  \$(smid ${SB[4]}) \""
stopall; for l in ${SB[@]}; do sudo losetup -d $l; done; rm -f $WQ/sm/*.img
fi
# --- end of stage 19 ---

# --- stage 20: review fixes ---
# Disks: 2 GiB sparse files in $WQ/rf; the first volume on a blank disk has AllocatedSpace 0x100000: AMD bitmap
# at +0x80, md bitmap header at +0x100, data from 0x105000.
if want 20; then
stopall
RF=$WQ/rf
for l in $(sudo losetup -a | grep "$RF/" | cut -d: -f1); do sudo losetup -d $l; done
mkdir -p $RF && rm -f $RF/*
rfl() { sudo losetup -j $RF/$1.img | cut -d: -f1; }
rfls() { local n; for n in "$@"; do rfl $n; done; }
rfnew() { local n; for n in "$@"; do truncate -s 2G $RF/$n.img; sudo losetup -f $RF/$n.img; done; }
rfdone() { stopall; for l in $(sudo losetup -a | grep "$RF/" | cut -d: -f1); do sudo losetup -d $l; done; rm -f $RF/*; }
rfcn() { cont1; }
rfvol() { local m; for m in $(ls /sys/block | grep ^md); do grep -qx "external:/$(rfcn)/$1" /sys/block/$m/md/metadata_version 2>/dev/null && echo $m; done; }
rfsec() { sudo dd if=$(rfl $1) bs=512 skip=$(($2)) count=1 iflag=direct status=none; }
rfmag() { rfsec $1 $2 | head -c 16 | tail -c 8 | tr -d '\0'; }	# "mdadmWIB": an md bitmap header in sector $2
rfhdr() { rfsec $1 $2 | sha256sum | cut -c1-16; }
rfamd() { rfsec $1 $((0x100080)) | tr -d '\0' | wc -c; }	# bytes with bits set in the AMD bitmap of the volume with [0][0] on disk $1
rfclean() { local i; for i in $(seq 1 150); do [ $(rfamd $1) = 0 ] && return 0; sleep 0.2; done; return 1; }
rfgen() { $M -E $(rfl $1) 2>/dev/null | sed -n 's/^ *Generation : //p' | head -1; }
rfvolE() { $M -E $(rfl $1) 2>/dev/null | sed -n "/^\[$2\]:/,/^\[/p"; }
rftrust() { rfvolE $1 $2 | sed -n 's/^ *md Bitmap mdmon : //p'; }
rfset() { rfvolE $1 $2 | sed -n 's/^ *md Bitmap : [0-9]* KiB a bit, \([0-9]*\) of .*/\1/p'; }
rfbits() { rfvolE $1 $2 | sed -n 's/^ *md Bitmap : .* at \([0-9]*\)$/\1/p'; }	# LBA of the bits; the header is 8 sectors before
rfwait0() { local i; for i in $(seq 1 60); do [ "$(rfset $1 $2)" = 0 ] && return 0; sleep 1; done; return 1; }
rfrole() { rfsec $1 $((0x5000)) | od -An -tx4 -j52 -N4 | tr -d ' '; }	# SpareInfo of the label (+0x34): 00000100 - global spare
rfcheck() { echo check | sudo tee /sys/block/$1/md/sync_action >/dev/null; sleep 1; waitrec; cat /sys/block/$1/md/mismatch_cnt; }
rfrepair() { echo repair | sudo tee /sys/block/$1/md/sync_action >/dev/null; sleep 1; waitrec; rfcheck $1; }
# 1 MiB of random data into a member image at offset <MiB from the start of data>
rfspoil() { head -c 1M /dev/urandom | dd of=$RF/$1.img bs=1M seek=$(( 0x105000 / 2048 + $2 )) conv=notrunc status=none; }
# "crash" of volume $1: a write loop at MiB $2 of the volume, copies of images $3..., clean stop, copies put back
rfcrash() {
	local v=$1 at=$2 n w; shift 2
	( while :; do sudo dd if=/dev/urandom of=/dev/$v bs=1M count=4 seek=$at oflag=direct status=none; done ) & w=$!
	sleep 3
	for n in "$@"; do cp --sparse=always $RF/$n.img $RF/$n.crash; done
	kill $w; wait $w 2>/dev/null
	stopall
	for n in "$@"; do sudo losetup -d $(rfl $n); mv $RF/$n.crash $RF/$n.img; sudo losetup -f $RF/$n.img; done
}
cat > $TMPW/rf-shim.c <<'C'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

static int held;

static void hold(void)
{
	const char *f = getenv("RF_HOLD");
	int fd;

	if (held || !f)
		return;
	held = 1;
	fd = creat(f, 0644);
	if (fd >= 0)
		close(fd);
	while (access(f, F_OK) == 0)
		usleep(100000);
}

int connect(int s, const struct sockaddr *a, socklen_t l)
{
	int (*real)(int, const struct sockaddr *, socklen_t) = dlsym(RTLD_NEXT, "connect");

	if (a && a->sa_family == AF_UNIX &&
	    strstr(((const struct sockaddr_un *)a)->sun_path, ".sock"))
		hold();
	return real(s, a, l);
}

static ssize_t rf_pwrite(const char *name, int fd, const void *b, size_t n, off_t o)
{
	ssize_t (*real)(int, const void *, size_t, off_t) = dlsym(RTLD_NEXT, name);

	if (n == 10 << 20)
		hold();
	return real(fd, b, n, o);
}

ssize_t pwrite(int fd, const void *b, size_t n, off_t o) { return rf_pwrite("pwrite", fd, b, n, o); }
ssize_t pwrite64(int fd, const void *b, size_t n, off_t o) { return rf_pwrite("pwrite64", fd, b, n, o); }

static int rf_blocked(const char *p, int flags)
{
	size_t n = strlen(p);

	return getenv("RF_NO_MDBM") && (flags & O_ACCMODE) != O_RDONLY &&
	       n >= 16 && strcmp(p + n - 16, "/bitmap/metadata") == 0;
}

static int rf_open(const char *name, const char *p, int flags, mode_t m)
{
	int (*real)(const char *, int, ...) = dlsym(RTLD_NEXT, name);

	if (rf_blocked(p, flags)) {
		errno = EACCES;
		return -1;
	}
	return real(p, flags, m);
}

int open(const char *p, int flags, ...)
{
	mode_t m = 0;
	va_list ap;

	if (flags & (O_CREAT | O_TMPFILE)) {
		va_start(ap, flags);
		m = va_arg(ap, int);
		va_end(ap);
	}
	return rf_open("open", p, flags, m);
}

int open64(const char *p, int flags, ...)
{
	mode_t m = 0;
	va_list ap;

	if (flags & (O_CREAT | O_TMPFILE)) {
		va_start(ap, flags);
		m = va_arg(ap, int);
		va_end(ap);
	}
	return rf_open("open64", p, flags, m);
}
C
gcc -shared -fPIC -O2 -o $TMPW/rf-shim.so $TMPW/rf-shim.c -ldl || echo "20: the LD_PRELOAD shim does not build"
RFENV="sudo env LD_PRELOAD=$TMPW/rf-shim.so MDADM_NO_SYSTEMCTL=1"

# 20a. -C through mdmon while md rebuilds another volume onto the global spare on which mdadm lays out the new one (a race
# window): both extents start at the spare's first free LBA. mdadm checked holders before
# managemon handed the spare to md (model: a shim stops mdadm before its first disk write or mdmon message; meanwhile
# a member of the volume fails). mdmon does not record the volume (amd_new_overlaps); mdadm wrote nothing onto the spare:
# mdmon zeroes the metadata area after the check, labels and the md bitmap come after the volume is recorded.
rfnew a0 a1 a2 a3
$M -C /dev/md/rfc -e amd -n 3 $(rfls a0 a1 a3) --run >/dev/null 2>&1
$M -C /dev/md/rfv -e amd -l1 -n2 -z 256M $(rfls a0 a1) --run >/dev/null 2>&1; waitrec; sleep 2
V=$(rfvol 0); CN=$(rfcn)
$M /dev/$CN --add $(rfl a2) >/dev/null 2>&1; sleep 2
R0=$(rfrole a2); A2=dev-$(basename $(rfl a2))
sudo rm -f $TMPW/rf-hold; sudo dmesg -C
( $RFENV RF_HOLD=$TMPW/rf-hold ./mdadm -C /dev/md/rfn -e amd -l1 -n2 -z 256M --bitmap=internal $(rfls a2 a3) --run >$TMPW/rf-c.out 2>&1; echo $? >$TMPW/rf-c.rc ) &
CP=$!
for i in $(seq 1 150); do [ -e $TMPW/rf-hold ] && break; sleep 0.1; done
HELD=$([ -e $TMPW/rf-hold ] && echo 1 || echo 0)
$M /dev/$V --fail $(rfl a1) >/dev/null 2>&1
for i in $(seq 1 50); do [ -e /sys/block/$V/md/$A2 ] && break; sleep 0.2; done
TOOK=$([ -e /sys/block/$V/md/$A2 ] && echo 1 || echo 0)
sleep 2; sudo rm -f $TMPW/rf-hold; wait $CP
check "20a: setup: -C held before its first write or message to mdmon ($HELD), meanwhile md takes the global spare (label $R0) for degraded subarray-0 ($TOOK)" "[ $HELD = 1 ] && [ $TOOK = 1 ] && [ '$R0' = 00000100 ]"
check "20a: mdmon does not record the new volume (an extent of it is the rebuild's): -C fails and says so (rc $(cat $TMPW/rf-c.rc))" "[ \$(cat $TMPW/rf-c.rc) != 0 ] && grep -q 'mdmon did not record the new volume' $TMPW/rf-c.out && ! rfvolE a0 rfn | grep -q . && sudo dmesg | grep -q 'the new volume overlaps an extent in use'"
check "20a: mdadm wrote nothing onto the rebuild's target: no md bitmap header of the new volume there, label a global spare still ($(rfrole a2))" "[ \"\$(rfmag a2 0x100100)\" != mdadmWIB ] && [ \$(rfrole a2) = 00000100 ]"
waitrec
check "20a: subarray-0 rebuilt onto the spare, whole (md check 0)" "grep -A1 \"^$V \" /proc/mdstat | grep -q '\[UU\]' && [ \$(rfcheck $V) = 0 ]"
rfdone

# 20b. --update=no-bitmap of a stopped volume while mdmon runs (another volume of the container is running): the next
# configuration write does not bring the header back (mdmon writes headers of running volumes only)
rfnew b0 b1 b2
$M -C /dev/md/rfc -e amd -n 3 $(rfls b0 b1 b2) --run >/dev/null 2>&1
$M -C /dev/md/rfx -e amd -l1 -n2 -z 128M $(rfls b0 b1) --run >/dev/null 2>&1
$M -C /dev/md/rfb -e amd -l1 -n2 -z 128M --bitmap=internal $(rfls b0 b1) --run >/dev/null 2>&1; waitrec; sleep 2
CN=$(rfcn); B=$(rfvol 1); BB=$(rfbits b0 rfb); BH=$(( ${BB:-8} - 8 ))
$M -S /dev/$B >/dev/null 2>&1; sleep 1
$M --update-subarray=1 --update=no-bitmap /dev/$CN >/dev/null 2>&1; RC=$?
G1=$(rfgen b0)
$M --update-subarray=1 --update=name -N rfb2 /dev/$CN >/dev/null 2>&1; sleep 2
G2=$(rfgen b0)
check "20b: setup: header at $BH, --update=no-bitmap of the stopped subarray-1 (rc $RC), mdmon runs for subarray-0, a configuration written since ($G1 -> $G2)" "[ -n '$BB' ] && [ $RC = 0 ] && pgrep -x mdmon >/dev/null && [ '$G2' -gt '$G1' ] && rfvolE b0 rfb2 | grep -q ."
check "20b: mdmon wrote no md bitmap header for the stopped volume: none on its members" "[ \"\$(rfmag b0 $BH)\" != mdadmWIB ] && [ \"\$(rfmag b1 $BH)\" != mdadmWIB ]"
$M -I /dev/$CN >/dev/null 2>&1; sleep 2; B=$(rfvol 1)
check "20b: ... assembled with the resync policy" "[ -n '$B' ] && [ \$(cat /sys/block/$B/md/consistency_policy) = resync ]"
rfdone

# 20c. The md bitmap header is not rewritten on each clean ↔ active transition (one value: "clean or dirty from
# bit k"); on stop - "clean"
rfnew c0 c1
$M -C /dev/md/rfc -e amd -n 2 $(rfls c0 c1) --run >/dev/null 2>&1
$M -C /dev/md/rfm -e amd -l1 -n2 -z 512M --bitmap=internal $(rfls c0 c1) --run >/dev/null 2>&1; waitrec
V=$(rfvol 0); rfwait0 c0 rfm; rfclean c0
H0=$(rfhdr c0 0x100100); TR0=$(rftrust c0 rfm)
sudo dd if=/dev/urandom of=/dev/$V bs=1M count=1 seek=100 oflag=direct status=none
D=0; H1=-
for i in $(seq 1 50); do [ $(rfamd c0) != 0 ] && { D=1; break; }; sleep 0.1; done
sleep 1.5; [ $(rfamd c0) != 0 ] && H1=$(rfhdr c0 0x100100)
rfclean c0; C=$?
H2=$(rfhdr c0 0x100100)
check "20c: a write to the idle volume: AMD bitmap dirty ($D), clean again ($C); the md bitmap header the same throughout" "[ $D = 1 ] && [ $C = 0 ] && [ '$H0' = '$H1' ] && [ '$H1' = '$H2' ]"
check "20c: -E: the header holds one state for both ($TR0)" "echo '$TR0' | grep -q 'AMD bitmap clean or dirty from bit 0'"
# crash while idle: image copies while the volume is clean (header "clean or dirty from 0")
for n in c0 c1; do cp --sparse=always $RF/$n.img $RF/$n.crash; done
$M -S /dev/$V >/dev/null 2>&1; sleep 1
check "20c: the volume stopped: the header says clean only (the session ended)" "rftrust c0 rfm | grep -q 'AMD bitmap clean\$'"
stopall
for n in c0 c1; do sudo losetup -d $(rfl $n); mv $RF/$n.crash $RF/$n.img; sudo losetup -f $RF/$n.img; done
# a foreign session after the idle crash: the AMD driver wrote and crashed - bit 3 of the AMD bitmap; damage under it and outside
printf '\x08' | dd of=$RF/c0.img bs=1 seek=$(( 0x100080 * 512 )) conv=notrunc status=none
rfspoil c1 330; rfspoil c1 480
$M -I $(rfl c0) >/dev/null 2>&1; $M -I $(rfl c1) >/dev/null 2>&1; sleep 2; V=$(rfvol 0); waitrec
P=$(rfcheck $V)
check "20c: crash while idle, then the AMD driver's bit 3: md bits from the AMD bitmap - the MiB spoiled under it fixed, the other left ($P)" "[ '$P' = 2048 ]"
rfrepair $V >/dev/null; rfwait0 c0 rfm; rfclean c0
# mdadm without the md bitmap after our clean stop: its session crashed ("dirty from 0"), our header says "clean"
$M -S /dev/$V >/dev/null 2>&1; sleep 1
for n in c0 c1; do sudo dd if=$(rfl $n) of=$RF/$n.hdr bs=512 skip=$((0x100100)) count=1 iflag=direct status=none; done
G1=$(rfgen c0); stopall
$M -I $(rfl c0) >/dev/null 2>&1; $M -I $(rfl c1) >/dev/null 2>&1; sleep 2; V=$(rfvol 0)
rfcrash $V 136 c0 c1
for n in c0 c1; do dd if=$RF/$n.hdr of=$RF/$n.img bs=512 seek=$((0x100100)) conv=notrunc status=none; done
G2=$(rfgen c0); A=$(rfamd c0)
rfspoil c1 330
$M -I $(rfl c0) >/dev/null 2>&1; $M -I $(rfl c1) >/dev/null 2>&1; sleep 2; V=$(rfvol 0); waitrec
P=$(rfcheck $V)
check "20c: a session after our clean stop crashed without md bits (AMD bitmap dirty, $A bytes; generation $G1 = $G2): not ours - all resynced ($P)" "[ '$G1' = '$G2' ] && [ $A -gt 0 ] && [ '$P' = 0 ]"
rfdone

# 20d. The kernel took no bitmap (the shim refuses bitmap/metadata): headers say "md kept no bits"; crash, assembly without
# element [0][0] (no AMD bitmap) - bits not trusted, full resync (RAID10: the second mirror pair)
rfnew e0 e1 e2 e3
$M -C /dev/md/rfc -e amd -n 4 $(rfls e0 e1 e2 e3) --run >/dev/null 2>&1
$M -C /dev/md/rft -e amd -l10 -n4 -z 512M --bitmap=internal $(rfls e0 e1 e2 e3) --run >/dev/null 2>&1; waitrec
rfwait0 e1 rft; stopall
for n in e0 e1 e2 e3; do $RFENV RF_NO_MDBM=1 ./mdadm -I $(rfl $n) >/dev/null 2>&1; done; sleep 2; V=$(rfvol 0)
check "20d: md takes no bitmap: the volume runs with the resync policy, its headers say md keeps no bits ($(rftrust e1 rft))" "[ -n '$V' ] && [ \$(cat /sys/block/$V/md/consistency_policy) = resync ] && rftrust e1 rft | grep -q 'md kept no bits: bits not trusted'"
rfcrash $V 136 e0 e1 e2 e3
rfspoil e3 200
for n in e1 e2 e3; do $M -I $(rfl $n) >/dev/null 2>&1; done; $M -IRs >/dev/null 2>&1; sleep 2; V=$(rfvol 0); waitrec
P=$(rfcheck $V)
check "20d: crash, then assembled without element [0][0]: the bits md did not keep not trusted - all resynced, the MiB spoiled on the second mirror fixed ($P)" "[ -n '$V' ] && [ \$(cat /sys/block/$V/md/consistency_policy) = bitmap ] && [ '$P' = 0 ]"
rfdone

# 20e. md keeps the bitmap away from its AMD place (bitmap/location set by hand): no spare taken - md would write bits into
# a foreign area on it; md dropped the bitmap (location none, as mdadm --grow --bitmap=none) - spare taken, headers cleared
rfnew f0 f1 f2 f3
$M -C /dev/md/rfc -e amd -n 2 $(rfls f0 f1) --run >/dev/null 2>&1
$M -C /dev/md/rfa -e amd -l1 -n2 -z 256M --bitmap=internal $(rfls f0 f1) --run >/dev/null 2>&1; waitrec; sleep 2
V=$(rfvol 0); CN=$(rfcn)
$M /dev/$CN --add $(rfl f2) >/dev/null 2>&1; sleep 2
echo none | sudo tee /sys/block/$V/md/bitmap/location >/dev/null; echo +3000000 | sudo tee /sys/block/$V/md/bitmap/location >/dev/null
LOC=$(cat /sys/block/$V/md/bitmap/location)
sudo dmesg -C
$M /dev/$V --fail $(rfl f1) >/dev/null 2>&1; sleep 4
check "20e: md keeps the bitmap at $LOC: no spare taken, the kernel log says why" "[ '$LOC' = +3000000 ] && ! [ -e /sys/block/$V/md/dev-\$(basename \$(rfl f2)) ] && ! grep -q recover /proc/mdstat && sudo dmesg | grep -q 'md keeps its bitmap at +3000000'"
echo none | sudo tee /sys/block/$V/md/bitmap/location >/dev/null
$M /dev/$CN --add $(rfl f3) >/dev/null 2>&1; sleep 3; waitrec; sleep 2
check "20e: md dropped the bitmap: a spare taken, rebuilt, the md bitmap headers cleared" "grep -A1 \"^$V \" /proc/mdstat | grep -q '\[UU\]' && [ \$(cat /sys/block/$V/md/consistency_policy) = resync ] && [ \"\$(rfmag f0 0x100100)\" != mdadmWIB ] && [ \$(rfcheck $V) = 0 ]"
rfdone

# 20f. --update=no-bitmap clears the header on the failed member too: an in-place rebuild would bring the bitmap back
rfnew g0 g1
$M -C /dev/md/rfc -e amd -n 2 $(rfls g0 g1) --run >/dev/null 2>&1
$M -C /dev/md/rfg -e amd -l1 -n2 -z 128M --bitmap=internal $(rfls g0 g1) --run >/dev/null 2>&1; waitrec; sleep 2
V=$(rfvol 0); CN=$(rfcn)
$M /dev/$V --fail $(rfl g1) >/dev/null 2>&1; sleep 3
M1=$(rfmag g1 0x100100)
$M -S /dev/$V >/dev/null 2>&1; sleep 1
$M --update-subarray=0 --update=no-bitmap /dev/$CN >/dev/null 2>&1; RC=$?
check "20f: --update=no-bitmap (rc $RC): no header on the member in service, nor on the failed one (it had: $M1)" "[ $RC = 0 ] && [ '$M1' = mdadmWIB ] && [ \"\$(rfmag g0 0x100100)\" != mdadmWIB ] && [ \"\$(rfmag g1 0x100100)\" != mdadmWIB ]"
rfdone

# 20g. A disk with another packet under the same configuration number (written separately) is caught up as a stale one
rfnew h0 h1 h2
$M -C /dev/md/rfc -e amd -n 3 $(rfls h0 h1 h2) --run >/dev/null 2>&1
$M -C /dev/md/rfh -e amd -l1 -n2 -z 128M $(rfls h0 h1) --run >/dev/null 2>&1; waitrec; sleep 2
stopall
$M -A /dev/md/rff -e amd $(rfl h2) >/dev/null 2>&1; $M --update-subarray=0 --update=name -N rfh1 /dev/md/rff >/dev/null 2>&1; stopall
$M -A /dev/md/rfc -e amd $(rfls h0 h1) >/dev/null 2>&1; $M --update-subarray=0 --update=name -N rfh2 /dev/md/rfc >/dev/null 2>&1; stopall
GA=$(rfgen h0); GB=$(rfgen h2)
$M -I $(rfl h0) >/dev/null 2>&1; $M -I $(rfl h1) >/dev/null 2>&1; sleep 2
sudo dmesg -C; $M -I $(rfl h2) >/dev/null 2>&1; sleep 3
check "20g: setup: h2's configuration and the others' have one generation ($GA, $GB), not one packet" "[ '$GA' = '$GB' ] && [ -n '$GA' ] && grep -q '\[2/2\] \[UU\]' /proc/mdstat"
check "20g: mdmon gives it the live configuration (kernel log), -E shows it" "sudo dmesg | grep -q \"disk \$(lsblk -dno MAJ:MIN \$(rfl h2) | tr -d ' ') missed configurations\" && rfvolE h2 rfh2 | grep -q . && ! rfvolE h2 rfh1 | grep -q ."
rfdone

# 20h. --bitmap=lockless (and clustered): an AMD volume takes an internal bitmap only
rfnew i0 i1
$M -C /dev/md/rfc -e amd -n 2 $(rfls i0 i1) --run >/dev/null 2>&1
OUT=$($M -C /dev/md/rfi -e amd -l1 -n2 -z 64M --bitmap=lockless $(rfls i0 i1) --run 2>&1)
check "20h: -C --bitmap=lockless refused, nothing created" "echo \"\$OUT\" | grep -q 'takes --bitmap=internal only' && ! rfvolE i0 rfi | grep -q ."
rfdone
rm -f $TMPW/rf-shim.c $TMPW/rf-hold $TMPW/rf-c.out $TMPW/rf-c.rc
fi
# --- end of stage 20 ---

# --- stage 21: a stale disk joins its container (mutual membership), a foreign set and a reused disk do not ---
# Set A (loop): container on a0..a2, RAID1 mbr on a0+a1. a0 away (assembled without it, mbr with --run on a1 alone),
# a3 added to the container with the lowest DeviceID (the container UUID changes; retried until it comes out), mbr rebuilt
# onto a3 (global spare). a0 is stale: old packet, old UUID; a copy of its image to repeat in another order.
# Set W (loop, 2 disks, its own RAID1) is foreign: it merges with nothing.
if want 21; then
cd "$MDADM_DIR"
stopall
for l in $(sudo losetup -a | grep $WQ/mb/ | cut -d: -f1); do sudo losetup -d $l; done
mkdir -p $WQ/mb && rm -f $WQ/mb/*
mbid() { $M -E $1 2>/dev/null | sed -n 's/^ *Device ID : //p' | head -1; }
mbgen() { $M -E $1 2>/dev/null | sed -n 's/^ *Generation : //p' | head -1; }
mbcu() { $M -E $1 2>/dev/null | sed -n 's/^ *Container UUID : //p' | head -1; }
# the AMD container holding disk $1 (md name), and its devices
mbcont() { local m; for m in $(ls /sys/block | grep ^md); do [ "$(cat /sys/block/$m/md/metadata_version 2>/dev/null)" = external:amd ] && [ -e /sys/block/$m/md/dev-${1#/dev/} ] && echo $m; done; }
mbdevs() { ls /sys/block/$1/md | grep -c '^dev-'; }
ncont() { grep -c 'super external:amd' /proc/mdstat; }
# UUID of container $1 in /run/mdadm/map (in the same form as Container UUID of -E)
mapuuid() { sudo cat /run/mdadm/map | awk -v m=$1 '$1 == m { print $3 }'; }
# RAID1 with member $1 runs on two: [2/2] [UU] (the volume name after assembly may have _0, so by member)
vol_ok() { grep -A1 -E "^md[0-9]+ : active.* raid1 .*${1#/dev/}\[" /proc/mdstat | grep -q '\[2/2\] \[UU\]'; }
# the packet on disk $2 has a PD of disk $1
haspd() { $M -E $2 2>/dev/null | grep -qE "^ +[0-9]+  $(mbid $1) "; }
caught() { [ "$(mbgen $1)" = "$(mbgen $2)" ] && haspd $3 $1; }   # $1 caught up to $2, has the PD of the added $3

MW=(); for n in 0 1; do truncate -s 1G $WQ/mb/w$n.img; MW[$n]=$(sudo losetup -f --show $WQ/mb/w$n.img); done
$M -C /dev/md/mwc -e amd -n2 ${MW[@]} --run >/dev/null 2>&1
$M -C /dev/md/mwr -e amd -l1 -n2 -z 32M ${MW[@]} --run >/dev/null 2>&1; waitrec; sleep 2
stopall; for l in ${MW[@]}; do sudo losetup -d $l; done   # -C of set A would refuse with a foreign label present
for try in $(seq 1 40); do
	MA=(); for n in 0 1 2 3; do rm -f $WQ/mb/a$n.img; truncate -s 1G $WQ/mb/a$n.img; MA[$n]=$(sudo losetup -f --show $WQ/mb/a$n.img); done
	$M -C /dev/md/mbc -e amd -n3 ${MA[@]:0:3} --run >/dev/null 2>&1
	$M -C /dev/md/mbr -e amd -l1 -n2 -z 64M ${MA[0]} ${MA[1]} --run >/dev/null 2>&1; waitrec; sleep 2
	stopall
	for l in ${MA[1]} ${MA[2]}; do $M -I $l >/dev/null 2>&1; done; $M -IRs >/dev/null 2>&1; sleep 2
	C=$(mbcont ${MA[1]})
	OUT=$($M /dev/$C --add ${MA[3]} 2>&1); sleep 2; waitrec; sleep 2
	stopall
	echo "$OUT" | grep -q 'lowest DeviceID' && break
	for l in ${MA[@]}; do sudo losetup -d $l; done
done
S=${MA[0]}
cp --reflink=always $WQ/mb/a0.img $WQ/mb/a0.stale
MW=(); for n in 0 1; do MW[$n]=$(sudo losetup -f --show $WQ/mb/w$n.img); done
SGEN=$(mbgen $S); NGEN=$(mbgen ${MA[1]})
restale() { stopall; sudo losetup -d $S; cp --reflink=always $WQ/mb/a0.stale $WQ/mb/a0.img; S=$(sudo losetup -f --show $WQ/mb/a0.img); MA[0]=$S; }
# all checks of set A after assembly: one container A of 4, a0 in it and caught up, volume on a1+a3, W apart, map = disks' UUID
setA_ok() { local c=$(mbcont ${MA[1]}); [ -n "$c" ] && [ "$(mbcont $S)" = $c ] && [ $(mbdevs $c) = 4 ] && vol_ok ${MA[1]} &&
	[ -n "$(mbcont ${MW[0]})" ] && [ "$(mbcont ${MW[0]})" != $c ] && [ $(mbdevs $(mbcont ${MW[0]})) = 2 ] && vol_ok ${MW[0]} && [ $(ncont) = 2 ]; }
mapA_ok() { local c=$(mbcont ${MA[1]}); [ -n "$c" ] && [ "$(mapuuid $c)" = "$(mbcu ${MA[1]})" ] && [ "$(mbcu $S)" = "$(mbcu ${MA[1]})" ]; }

check "21: set A: a3 added with the lowest DeviceID while a0 was away (try $try), a0 stale (generation $SGEN, the others $NGEN), the RAID1 rebuilt onto a3" "echo \"\$OUT\" | grep -q 'lowest DeviceID' && [ $SGEN -lt $NGEN ] && ! haspd ${MA[3]} $S"
for l in ${MA[1]} ${MW[0]} ${MA[2]} ${MA[3]} ${MW[1]} $S; do $M -I $l >/dev/null 2>&1; done; sleep 3; waitrec; sleep 2
check "21: -I, the stale disk last: it joins its container (4 disks), RAID1 on a1+a3 [UU], set W apart" "setA_ok"
check "21: ... mdmon caught it up (generation and the PD of a3), the map has the UUID the disks give" "caught $S ${MA[1]} ${MA[3]} && mapA_ok"
check "21: ... a0 in no volume (its element was rebuilt onto a3)" "! grep -E '^md[0-9]+ : active.* raid1 ' /proc/mdstat | grep -q '${S#/dev/}\['"

restale
OLDU=$(mbcu ${MA[1]})
$M -I $S >/dev/null 2>&1; sleep 1
for l in ${MW[0]} ${MA[1]} ${MA[2]} ${MW[1]} ${MA[3]}; do $M -I $l >/dev/null 2>&1; done; sleep 3; waitrec; sleep 2
check "21: -I, the stale disk first: the others join its container, which takes the live configuration" "setA_ok"
check "21: ... the map follows it: the UUID of the live configuration ($OLDU), mdmon caught a0 up" "mapA_ok && [ \"\$(mapuuid \$(mbcont $S))\" = $OLDU ] && caught $S ${MA[1]} ${MA[3]}"

restale
{ for l in $S ${MA[1]} ${MA[2]} ${MA[3]} ${MW[@]}; do echo "DEVICE $l"; done; echo "DEVICE containers"; } > $WQ/mb/devs.conf
ES=$($M -Es -c $WQ/mb/devs.conf 2>/dev/null)
check "21: -Es: one ARRAY line per container (A, W), the stale disk's set gives the live UUID" "[ \$(echo \"\$ES\" | grep -c '^ARRAY metadata=amd ') = 2 ] && echo \"\$ES\" | grep -qi \"UUID=\$(mbcu ${MA[1]})\$\" && [ \$(echo \"\$ES\" | grep -c 'member=') = 2 ]"
{ cat $WQ/mb/devs.conf; echo "$ES"; } > $WQ/mb/mdadm.conf
$M -As -c $WQ/mb/mdadm.conf >/dev/null 2>&1; sleep 3; waitrec; sleep 2
check "21: -As (mdadm.conf by UUID): the stale disk assembled into its container, volumes run, mdmon caught it up" "setA_ok && caught $S ${MA[1]} ${MA[3]} && mapA_ok"

restale
UA=$($M -E ${MA[1]} 2>/dev/null | sed -n 's/^ *Container UUID : //p')
$M -A /dev/md/mbc -e amd -u $UA $S ${MA[1]} ${MA[2]} ${MA[3]} >/dev/null 2>&1; sleep 1
$M -I /dev/md/mbc >/dev/null 2>&1; sleep 3; waitrec; sleep 2
check "21: -A --uuid with the stale disk listed: it is in the container (4 disks), RAID1 runs, caught up" "C=\$(mbcont ${MA[1]}); [ -n \"\$C\" ] && [ \"\$(mbcont $S)\" = \$C ] && [ \$(mbdevs \$C) = 4 ] && vol_ok ${MA[1]} && caught $S ${MA[1]} ${MA[3]}"

restale
for l in ${MW[1]} ${MA[3]} $S ${MA[2]} ${MW[0]} ${MA[1]}; do $M -I $l >/dev/null 2>&1 & done; wait; sleep 3; waitrec; sleep 2
check "21: -I of all six at once (as udev at boot): two containers, A with the stale disk, W apart" "setA_ok && mapA_ok"
stopall; for l in ${MA[@]} ${MW[@]}; do sudo losetup -d $l; done; rm -rf $WQ/mb

# Reused disk: z was in set X (z, x1, x2; RAID1 mxr on x1+x2), it was taken into set Y (z, y1; RAID1 myr)
# while the X disks were away. DeviceID comes from the serial number (AMD controller SATA disks), z in Y has the same ID, X's configs
# still list it, but z lists only the Y disks: X and Y do not merge. The X disks are hidden (SCSI device
# deletion, like a pulled disk) and come back by a port rescan - sdX names may change, hence by serial.
sd() { lsblk -dno NAME,SERIAL | awk -v s=$1 '$2 == s { print "/dev/" $1 }'; }
rescan() { for h in /sys/class/scsi_host/host*; do echo '- - -' | sudo tee $h/scan >/dev/null; done; sudo udevadm settle; sleep 1; }
RZ=AMDSATA0; RX1=AMDSATA1; RX2=AMDSATA2; RY1=AMDSATA3
if ! amd_disks $RZ $RX1 $RX2 $RY1; then skip "21 (reused disk: AMDSATA0-3)" "$AMD_DISKS_WHY"; else
CLEAN=1; for s in $RZ $RX1 $RX2 $RY1; do [ -n "$(sd $s)" ] && ! $M -E $(sd $s) 2>/dev/null | grep -q 'Magic : RAIDCore' || CLEAN=0; done
check "21: reused disk: the AMD controller SATA disks are there and blank" "[ $CLEAN = 1 ]"
if [ $CLEAN = 1 ]; then
	$M -C /dev/md/mxc -e amd -n3 $(sd $RZ) $(sd $RX1) $(sd $RX2) --run >/dev/null 2>&1
	$M -C /dev/md/mxr -e amd -l1 -n2 -z 32M $(sd $RX1) $(sd $RX2) --run >/dev/null 2>&1; waitrec; sleep 2
	stopall
	ZID=$(mbid $(sd $RZ))
	for s in $RX1 $RX2; do echo 1 | sudo tee /sys/block/$(basename $(sd $s))/device/delete >/dev/null; done; sudo udevadm settle
	$M -C /dev/md/myc -e amd -n2 $(sd $RZ) $(sd $RY1) --run >/dev/null 2>&1
	$M -C /dev/md/myr -e amd -l1 -n2 -z 32M $(sd $RZ) $(sd $RY1) --run >/dev/null 2>&1; waitrec; sleep 2
	stopall; rescan
	check "21: ... z is in set Y now with its DeviceID ($ZID), set X still lists it" "[ -n \"\$(sd $RX1)\" ] && [ \"\$(mbid \$(sd $RZ))\" = '$ZID' ] && haspd \$(sd $RZ) \$(sd $RX1) && ! haspd \$(sd $RX1) \$(sd $RZ)"
	setXY_ok() { local x=$(mbcont $(sd $RX1)) y=$(mbcont $(sd $RZ)); [ -n "$x" ] && [ -n "$y" ] && [ $x != $y ] &&
		[ "$(mbcont $(sd $RX2))" = $x ] && [ "$(mbcont $(sd $RY1))" = $y ] && [ $(mbdevs $x) = 2 ] && [ $(mbdevs $y) = 2 ] &&
		vol_ok $(sd $RX1) && vol_ok $(sd $RY1); }
	for s in $RZ $RX1 $RX2 $RY1; do $M -I $(sd $s) >/dev/null 2>&1; done; sleep 3; waitrec; sleep 2
	check "21: ... -I, z first: two containers, X (x1, x2) and Y (z, y1), both RAID1 [UU]" "setXY_ok"
	stopall
	{ for s in $RZ $RX1 $RX2 $RY1; do echo "DEVICE $(sd $s)"; done; echo "DEVICE containers"; } > $TMPW/mx.conf
	$M -As -c $TMPW/mx.conf >/dev/null 2>&1; sleep 3; waitrec; sleep 2
	check "21: ... -As (no ARRAY lines, z listed first): the same two containers" "setXY_ok"
	stopall
	# z's label wiped while X still knows it as a RAID disk (DeviceID = serial hash): --add to X would give z a second, random
	# DeviceID and two records - refused by design, nothing on z
	$M --zero-superblock $(sd $RZ) >/dev/null 2>&1
	$M -A /dev/md/mxc $(sd $RX1) $(sd $RX2) >/dev/null 2>&1 && $M -I /dev/md/mxc >/dev/null 2>&1; sleep 2; waitrec
	OUT=$($M /dev/md/mxc --add $(sd $RZ) 2>&1); RC=$?
	check "21: ... z wiped, X still lists it as a RAID disk: --add to X refused, said why, z left blank" "[ $RC != 0 ] && echo \"\$OUT\" | grep -q 'has it as a RAID disk' && ! $M -E \$(sd $RZ) 2>/dev/null | grep -q 'Magic : RAIDCore'"
	stopall
	for s in $RZ $RX1 $RX2 $RY1; do $M --zero-superblock $(sd $s) >/dev/null 2>&1; done
	rm -f $TMPW/mx.conf
fi
CLEAN=1; for s in $RZ $RX1 $RX2 $RY1; do [ -n "$(sd $s)" ] && ! $M -E $(sd $s) 2>/dev/null | grep -q 'Magic : RAIDCore' || CLEAN=0; done
check "21: ... the AMD controller SATA disks blank again" "[ $CLEAN = 1 ]"
fi
fi
# --- end of stage 21 ---

# --- stage 22: small things - -C --bitmap refused in one line; volume names on assembly, as IMSM's ---
if want 22; then
cd "$MDADM_DIR"
stopall
for l in $(sudo losetup -a | grep $WQ/mi/ | cut -d: -f1); do sudo losetup -d $l; done
mkdir -p $WQ/mi && rm -f $WQ/mi/*
miloop() { sudo losetup -j $WQ/mi/$1.img | cut -d: -f1; }
for i in 0 1 2; do truncate -s 2G $WQ/mi/c$i.img; sudo losetup -f $WQ/mi/c$i.img; done
$M -C /dev/md/mic -e amd -n 3 $(miloop c0) $(miloop c1) $(miloop c2) --run >/dev/null 2>&1
$M -C /dev/md/mia -e amd -l1 -n2 -z 256M --assume-clean $(miloop c1) $(miloop c2) --run >/dev/null 2>&1
# c1 holds mia first, c0 does not: a new volume on c0+c1 has members at different LBAs
OUT=$($M -C /dev/md/mix -e amd -l1 -n2 -z 256M --bitmap=internal $(miloop c0) $(miloop c1) --run 2>&1); RC=$?
check "22: -C --bitmap, members at different LBAs: refused with one line (no 'Given bitmap chunk size'), nothing created" "[ $RC != 0 ] && echo \"\$OUT\" | grep -q 'do not start at one LBA' && ! echo \"\$OUT\" | grep -q 'chunk size not supported' && [ ! -e /dev/md/mix ]"
OUT=$($M -C /dev/md/miy -e amd -l1 -n2 -z 256M --bitmap=internal --assume-clean $(miloop c1) $(miloop c2) --run 2>&1); RC=$?
MY=$(basename $(readlink -f /dev/md/miy 2>/dev/null) 2>/dev/null)
check "22: ... the same disks (one LBA): created with the bitmap" "[ $RC = 0 ] && [ -n '$MY' ] && [ \"\$(cat /sys/block/$MY/md/consistency_policy 2>/dev/null)\" = bitmap ]"
stopall; sudo rm -f /run/mdadm/map
$M -A /dev/md/mic $(miloop c0) $(miloop c1) $(miloop c2) >/dev/null 2>&1; $M -I /dev/md/mic >/dev/null 2>&1; sleep 2
check "22: assembled without mdadm.conf: volumes named <name>_0, as IMSM's (a foreign array: match_home -1)" "[ -e /dev/md/mia_0 ] && [ -e /dev/md/miy_0 ] && [ ! -e /dev/md/mia ]"
$M -Es 2>/dev/null | grep -E 'ARRAY (metadata|/dev/md/mi)' > $TMPW/mi.conf
stopall; sudo rm -f /run/mdadm/map
$M -As -c $TMPW/mi.conf >/dev/null 2>&1; sleep 2
check "22: ... with the ARRAY lines of -Es in mdadm.conf: named <name>" "[ -e /dev/md/mia ] && [ -e /dev/md/miy ] && [ ! -e /dev/md/mia_0 ]"
stopall; sudo rm -f /run/mdadm/map; rm -f $TMPW/mi.conf
for i in 0 1 2; do d=$(miloop c$i); $M --zero-superblock $d >/dev/null 2>&1; sudo losetup -d $d; done
rm -f $WQ/mi/*
fi
# --- end of stage 22 ---

# --- stage 23: mdadm without mdmon repairs the XPG Legacy too (--kill-subarray, --update-subarray); --add NVMe NOT_INITIALIZE ---
HD=$FIXT/2026-11-02-msi-x870e-hdd; HS="WX41A685FR98 WES1KE09 JR10044M28WJGM WX61A68KYK45"
l3load() {
	mkdir -p $WQ/l3 && rm -f $WQ/l3/*.img; L3=""
	for s in $HS; do
		truncate -s $((1953525168 * 512)) $WQ/l3/$s.img
		xz -dc $HD/$s-lba0-6000.img.xz | dd of=$WQ/l3/$s.img conv=notrunc status=none
		L3="$L3 $(sudo losetup -f --show $WQ/l3/$s.img)"
	done
	$M -A /dev/md/l3 $L3 >/dev/null 2>&1
}
l3drop() { stopall; for d in $L3; do sudo losetup -d $d; done; rm -rf $WQ/l3; }
l3cfg() { python3 $TOOLS/amdraid_dump.py $WQ/l3/$1.img --brief 2>/dev/null; }
l3fixed() {
	for s in $HS; do l3cfg $s | grep -q 'конфигурация 20' || return 1; done
	l3cfg WES1KE09 | grep -q '7d730af340a81267 LEGACY NORMAL .*\[1:1267\]' &&
	[ $(l3cfg WES1KE09 | grep -c 'Array .* LEGACY') = 1 ] && ! $M -E $(echo $L3 | cut -d' ' -f1) | grep -q 'Legacy records'
}
if want 23; then
l3load
check "23: container assembled without its volumes: no mdmon, examine reports the broken Legacy records" "[ -e /dev/md/l3 ] && ! pgrep -x mdmon >/dev/null && $M -E $(echo $L3 | cut -d' ' -f1) | grep -q 'Legacy records : 2 broken.*next configuration'"
$M --kill-subarray=4 /dev/md/l3 >/dev/null 2>&1
check "23: --kill-subarray of the Volume without mdmon: config 20, the Legacy LD of XPG repaired, the extra one gone" "! pgrep -x mdmon >/dev/null && l3fixed && [ \$(l3cfg WES1KE09 | grep -c 'Array .* VOL') = 0 ]"
l3drop
l3load
$M --update-subarray=3 --update=name -N l3r0 /dev/md/l3 >/dev/null 2>&1
check "23: --update-subarray (name of the RAID0) without mdmon: config 20, the Legacy LD of XPG repaired" "! pgrep -x mdmon >/dev/null && l3fixed && $M -E $(echo $L3 | cut -d' ' -f1) | grep -q '^\[l3r0\]'"
l3drop

# (b) --add NVMe NOT_INITIALIZE
sd() { lsblk -dno NAME,SERIAL | awk -v s=$1 '$2 == s { print "/dev/" $1 }'; }
NS=$(sd AMDSATA4); NR=$(sd AMDNVME1); NT=$(sd AMDNVME0)
if ! amd_disks AMDSATA4 AMDNVME0 AMDNVME1; then skip "23 (b) (AMDSATA4, AMDNVME0, AMDNVME1)" "$AMD_DISKS_WHY"; else
BL=1; for d in $NS $NR $NT; do $M -E $d 2>/dev/null | grep -q 'Magic : RAIDCore' && BL=0; done
check "23: AMDSATA4, AMDNVME0, AMDNVME1 there and blank" "[ -n '$NS' ] && [ -n '$NR' ] && [ -n '$NT' ] && [ $BL = 1 ]"
# not blank: one FAIL above, nothing written to them
if [ -n "$NS" ] && [ -n "$NR" ] && [ -n "$NT" ] && [ $BL = 1 ]; then
$M -C /dev/md/nv -e amd -n2 $NS $NR -R >/dev/null 2>&1
$M -C /dev/md/nvr1 -l1 -n2 -z 64M /dev/md/nv -R >/dev/null 2>&1
$M /dev/md/nv --add $NT >/dev/null 2>&1; sleep 2
NID=$($M -E $NT 2>/dev/null | awk '/<- this disk/ { print $2 }')
stopall
sudo -E python3 - $NID $NS $NR >/dev/null <<'PY'
import os, struct, sys
sys.path.insert(0, os.environ["TOOLS"])
import amdraid_fix_legacy as f
disks = [f.Disk(x, True) for x in sys.argv[2:]]
p = bytearray(disks[0].packet)
pds, lds = f.records(p)
hit = [po for po in pds if f.u64(p, po + 4) == int(sys.argv[1], 16)]
assert len(hit) == 1
struct.pack_into('<I', p, hit[0] + 0x24, 0x1202)
f.write_all(disks, p)
PY
sudo dd if=/dev/zero of=$NT bs=512 count=$((0x6000)) oflag=direct status=none
G0=$(sudo python3 $TOOLS/amdraid_dump.py $NS --brief 2>/dev/null | grep -o 'конфигурация [0-9]*')
$M -A /dev/md/nv $NS $NR >/dev/null 2>&1 && $M -I /dev/md/nv >/dev/null 2>&1; sleep 2
check "23: the NVMe PD is NOT_INITIALIZE, the RAID1 runs under mdmon" "[ -n '$NID' ] && sudo python3 $TOOLS/amdraid_dump.py $NS --brief 2>/dev/null | grep -q '$NID NOT_INITIALIZE' && pgrep -x mdmon >/dev/null"
OUT=$($M /dev/md/nv --add $NT 2>&1); RC=$?
check "23: --add of the NOT_INITIALIZE NVMe refused before any write (rc $RC)" "[ $RC != 0 ] && echo \"\$OUT\" | grep -q 'non-RAID disk of the AMD RAID configuration (not initialized or Legacy)' && sudo cmp -s -n $((0x6000 * 512)) $NT /dev/zero && [ \"\$(sudo python3 $TOOLS/amdraid_dump.py $NS --brief 2>/dev/null | grep -o 'конфигурация [0-9]*')\" = '$G0' ]"
stopall
for d in $NS $NR $NT; do sudo blkdiscard $d 2>/dev/null || sudo dd if=/dev/zero of=$d bs=1M count=12 oflag=direct status=none; done
BL=1; for d in $NS $NR $NT; do $M -E $d 2>/dev/null | grep -q 'Magic : RAIDCore' && BL=0; done
check "23: the AMD controller disks blank again" "[ $BL = 1 ]"
fi
fi
fi
# --- end of stage 23 ---
# --- stage 24: --add of a former member in the middle of a recorded rebuild;
# a volume name over 31 characters at -C; --add of a disk whose LBA 0 cannot be read ---
# Without the fix these fail: (a) (the name is cut to 31 characters), the second (b) (the rebuild target in the second copy
# gets 0x20) and (c) (another message: no check, refused only on the write after Kill).
if want 24; then
cd "$MDADM_DIR"
stopall
for l in $(sudo losetup -a | grep $WQ/qc/ | cut -d: -f1); do sudo losetup -d $l; done
sudo dmsetup remove qcbad 2>/dev/null
mkdir -p $WQ/qc && rm -f $WQ/qc/*
qcl() { sudo losetup -j $WQ/qc/$1.img | cut -d: -f1; }
for i in 0 1 2 3; do truncate -s 1G $WQ/qc/q$i.img; sudo losetup -f $WQ/qc/q$i.img; done
Q0=$(qcl q0); Q1=$(qcl q1); Q2=$(qcl q2); Q3=$(qcl q3)
$M -C /dev/md/qcc -e amd -n2 $Q0 $Q1 --run >/dev/null 2>&1
# (a) name: DevicePrivate is 31 characters and NUL; mdadm lets a 32-character -N through (ident.name[33])
OUT=$($M -C /dev/md/qcn -N qcname_of_thirty_two_characters_ -e amd -l1 -n2 -z 64M $Q0 $Q1 --run 2>&1); RC=$?
check "24: -C with a 32-character name: refused (not cut to 31), nothing created" "[ $RC != 0 ] && echo \"\$OUT\" | grep -q 'volume name is 1 to 31 characters' && [ ! -e /dev/md/qcn ] && ! $M -E $Q0 | grep -q '^\[qcname'"
# (b) md rebuilds the failed member's slot onto the global spare (second LD copy), the member is returned with --add
$M -C /dev/md/qcr -e amd -l1 -n2 -z 256M $Q0 $Q1 --run >/dev/null 2>&1; waitrec; sleep 2
QCN=/dev/$(cont1)
$M $QCN --add $Q2 >/dev/null 2>&1; sleep 2
QR=$(basename $(readlink -f /dev/md/qcr))
head -c 16M /dev/urandom > $TMPW/qc.bin; sudo dd if=$TMPW/qc.bin of=/dev/$QR bs=1M oflag=direct status=none; rm -f $TMPW/qc.bin
# flags of element [0,1] in the n-th LD record of volume qcr (1 - the LD, 2 - the second copy)
qcel() { python3 $TOOLS/amdraid_dump.py $WQ/qc/q0.img 2>/dev/null | awk -v n=$1 '/^  LD @/ { k += /DevicePrivate=.qcr./; on = /DevicePrivate=.qcr./ } on && k == n && /\[0,1\]/ { sub(/.*flags=/, ""); print; exit }'; }
echo 500 | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null; echo 500 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
$M /dev/$QR --fail $Q1 >/dev/null 2>&1; sleep 6
check "24: the failed member's slot is rebuilt onto the global spare, recorded (0x10 in the LD, the spare in the second copy)" "[ \"\$(qcel 1)\" = 0x10 ] && [ \"\$(qcel 2)\" = 0x0 ] && grep -q recovery /proc/mdstat"
$M $QCN --remove $Q1 >/dev/null 2>&1; sleep 2
OUT=$($M $QCN --add $Q1 2>&1); sleep 4
check "24: --add of the failed member meanwhile: offline (0x30) in the LD, the rebuild target in the second copy keeps 0 (no 0x20 alone)" "echo \"\$OUT\" | grep -q 'former member' && [ \"\$(qcel 1)\" = 0x30 ] && [ \"\$(qcel 2)\" = 0x0 ]"
echo 200000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null; echo 1000 | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null
waitrec; sleep 3
check "24: ... the rebuild ends: NORMAL, the spare in slot 1, mirrors equal" "$M -E $Q0 | grep -A12 '^\[qcr\]' | grep -q 'State : 0x200' && cmp -s <(sudo dd if=$Q0 bs=512 skip=\$(cat /sys/block/$QR/md/rd0/offset) count=$((256 * 2048)) status=none) <(sudo dd if=$Q2 bs=512 skip=\$(cat /sys/block/$QR/md/rd1/offset) count=$((256 * 2048)) status=none)"
# (c) LBA 0 unreadable (dm error on the first 8 sectors): neither partition table nor label can be checked - refuse before wiping
sudo modprobe dm_mod 2>/dev/null
QS=$(sudo blockdev --getsz $Q3)
printf '0 8 error\n8 %d linear %s 8\n' $((QS - 8)) $Q3 | sudo dmsetup create qcbad
OUT=$($M $QCN --add /dev/mapper/qcbad 2>&1); RC=$?
check "24: --add of a disk whose LBA 0 cannot be read: refused before mdadm wipes it" "[ $RC != 0 ] && echo \"\$OUT\" | grep -q 'cannot read /dev/mapper/qcbad, not adding it'"
sudo dmsetup remove qcbad
stopall
for d in $Q0 $Q1 $Q2 $Q3; do $M --zero-superblock $d >/dev/null 2>&1; sudo losetup -d $d; done
rm -f $WQ/qc/*
fi
# --- end of stage 24 ---
# --- stage 26: an mdmon refusal reaches mdadm; <container> --remove sdX ---
# mdmon sends no reply: mdadm checks the disks for whether it was recorded (amd_mdmon_recorded).
# (a) a real monitor refusal: mdmon stopped (SIGSTOP), two --add-spare to one volume queued on the socket - the fourth
#     dedicated spare and the global spare; the monitor takes the first and refuses the second ("has 4 already"). Without the fix
#     the second mdadm says "ok" and writes label SpareInfo 0, though the PD stayed a global spare.
# (b) the configuration cannot be written (container disks read-only, blockdev --setro: mdmon gets EPERM):
#     --kill-subarray, --update-subarray=name, <volume> --remove of a dedicated spare, --add - an error, nothing on the disks.
# (c) the same with writes - success, as before; (d) <container> --remove by kernel name (loopN) drops spare roles;
# (e) a 4Kn disk - -C and --add refuse; (f) -A --update=X - refused in one line.
if want 26; then
cd "$MDADM_DIR"
stopall
for l in $(sudo losetup -a | grep /images/ma/ | cut -d: -f1); do sudo blockdev --setrw $l; sudo losetup -d $l; done
mkdir -p $IMG/ma && rm -f $IMG/ma/*
mal() { sudo losetup -j $IMG/ma/m$1.img | cut -d: -f1; }
for i in 0 1 2 3 4 5 6 7; do truncate -s 1G $IMG/ma/m$i.img; sudo losetup -f $IMG/ma/m$i.img; done
for i in 0 1 2 3 4 5 6 7; do eval MA$i=$(mal $i); done
# -E of a member; dedicated spare of volume ma0; global spare (by the Device ID of the disk's label)
maE() { $M -E $MA0 2>/dev/null; }
maded() { maE | grep -q "Dedicated spare : $(sid $1) "; }
maglob() { maE | grep -q "$(sid $1) .*global spare"; }
# volume by name: -I after a stop gives /dev/md/ma0_0 (as IMSM without mdadm.conf)
mav() { ls -d /dev/md/$1 /dev/md/$1_* 2>/dev/null | head -1; }
$M -C /dev/md/mac -e amd -n6 $MA0 $MA1 $MA2 $MA3 $MA4 $MA5 --run >/dev/null 2>&1
$M -C /dev/md/ma0 -e amd -l1 -n2 -z 64M $MA0 $MA1 --run >/dev/null 2>&1
$M -C /dev/md/ma1 -e amd -l1 -n2 -z 32M $MA0 $MA1 --run >/dev/null 2>&1; waitrec; sleep 2
$M -S /dev/md/ma1 >/dev/null 2>&1
MAC=/dev/$(cn)
$M $MAC --add $MA6 >/dev/null 2>&1
for d in $MA2 $MA3 $MA4; do $M /dev/md/ma0 --add-spare $d >/dev/null 2>&1; done; sleep 1
# (a) two --add-spare queued for mdmon: managemon accepts connections in order (accept), the first is the fourth
# dedicated spare, the second loaded the configuration before it
MP=$(pgrep -x mdmon | head -1); sudo kill -STOP $MP
( $M /dev/md/ma0 --add-spare $MA5 >$TMPW/ma-b.out 2>&1; echo $? >$TMPW/ma-b.rc ) &
sleep 2
( $M /dev/md/ma0 --add-spare $MA6 >$TMPW/ma-a.out 2>&1; echo $? >$TMPW/ma-a.rc ) &
sleep 2; sudo kill -CONT $MP; wait; sleep 1
check "26: the 4th dedicated spare, queued first: recorded, mdadm says so (rc $(cat $TMPW/ma-b.rc))" "[ \$(cat $TMPW/ma-b.rc) = 0 ] && grep -q 'a dedicated hot spare of subarray-0 now' $TMPW/ma-b.out && maded $MA5"
check "26: a 5th, queued behind it: mdmon refuses (dmesg), mdadm fails and says so, the global spare keeps its role and label 0x100 (rc $(cat $TMPW/ma-a.rc))" "[ \$(cat $TMPW/ma-a.rc) != 0 ] && grep -q 'mdmon did not change its spare roles' $TMPW/ma-a.out && sudo dmesg | grep -q 'as a dedicated spare of subarray-0: it has 4 already' && ! maded $MA6 && maglob $MA6 && [ \$(slbl $MA6) = 00000100 ]"
# (b) container disks read-only: mdmon cannot write the configuration (EPERM), the update stays in its memory
for i in 0 1 2 3 4 5 6; do sudo blockdev --setro $(mal $i); done
OUT=$($M --kill-subarray=1 $MAC 2>&1); RC=$?
check "26: --kill-subarray, the configuration not written: mdadm fails and says so, the volume stays on the disks" "[ $RC != 0 ] && echo \"\$OUT\" | grep -q 'mdmon did not delete subarray-1' && maE | grep -q '^\[ma1\]'"
OUT=$($M --update-subarray=1 --update=name -N mab $MAC 2>&1); RC=$?
check "26: --update-subarray=name, not written: mdadm fails and says so, the name stays" "[ $RC != 0 ] && echo \"\$OUT\" | grep -q 'mdmon did not update subarray-1' && maE | grep -q '^\[ma1\]' && ! maE | grep -q '^\[mab\]'"
OUT=$($M /dev/md/ma0 --remove $MA2 2>&1); RC=$?
check "26: <volume> --remove of a dedicated spare, not written: mdadm fails and says so, the role stays" "[ $RC != 0 ] && echo \"\$OUT\" | grep -q 'mdmon did not change its spare roles' && maded $MA2"
OUT=$($M $MAC --add $MA7 2>&1); RC=$?
check "26: --add, not written: mdadm fails and says so, the disk is not in the container and has no AMD label" "[ $RC != 0 ] && echo \"\$OUT\" | grep -q 'mdmon did not record the disk' && ! grep -q '$(basename $MA7)\[' /proc/mdstat && ! $M -E $MA7 2>/dev/null | grep -q RAIDCore"
stopall
for i in 0 1 2 3 4 5 6; do sudo blockdev --setrw $(mal $i); done
for i in 0 1 2 3 4 5 6; do $M -I $(mal $i) >/dev/null 2>&1; done; sleep 3
check "26: ... after a stop and -I: the configuration as before (subarray-1 named ma1, 4 dedicated spares, a global one)" "maE | grep -q '^\[ma1\]' && [ \$(maE | grep -c 'Dedicated spare') = 4 ] && maglob $MA6 && [ -n \"\$(mav ma1)\" ]"
# (c) the same, with writes: success
MAC=/dev/$(cn)
$M -S $(mav ma1) >/dev/null 2>&1
OUT=$($M --update-subarray=1 --update=name -N mab $MAC 2>&1); RC=$?
check "26: --update-subarray=name, written: ok" "[ $RC = 0 ] && maE | grep -q '^\[mab\]'"
OUT=$($M --kill-subarray=1 $MAC 2>&1); RC=$?
check "26: --kill-subarray, written: ok" "[ $RC = 0 ] && echo \"\$OUT\" | grep -q 'Deleted subarray-1' && ! maE | grep -q '^\[mab\]'"
OUT=$($M $(mav ma0) --remove $MA2 2>&1); RC=$?
check "26: <volume> --remove of a dedicated spare, written: ok" "[ $RC = 0 ] && echo \"\$OUT\" | grep -q 'no longer a dedicated hot spare of subarray-0' && ! maded $MA2"
OUT=$($M $MAC --add $MA7 2>&1); RC=$?; sleep 1
check "26: --add, written: ok, a global spare" "[ $RC = 0 ] && echo \"\$OUT\" | grep -q 'added as an AMD global hot spare' && maglob $MA7"
# (d) <container> --remove by kernel name (Manage: sysfs, "loop7"): roles dropped, as for a path
OUT=$($M $MAC --remove $(basename $MA7) 2>&1); RC=$?; sleep 1
check "26: <container> --remove <kernel name> of a global spare: the role goes (PD, label 0)" "[ $RC = 0 ] && echo \"\$OUT\" | grep -q 'no longer an AMD global hot spare' && ! maglob $MA7 && [ \$(slbl $MA7) = 00000000 ]"
OUT=$($M $MAC --remove $(basename $MA3) 2>&1); RC=$?; sleep 1
check "26: <container> --remove <kernel name> of a dedicated spare: the role goes" "[ $RC = 0 ] && echo \"\$OUT\" | grep -q 'no longer a dedicated hot spare of subarray-0' && ! maded $MA3"
# (e) a 4Kn disk (scsi_debug, logical sector 4096): AMD has no 4Kn, mdadm could not read back what it wrote (-E "No md
#     superblock", --zero-superblock "Unrecognised") - -C and --add refuse, nothing on the disk
if sudo modprobe scsi_debug dev_size_mb=16 virtual_gb=2 sector_size=4096 2>/dev/null; then
	sleep 1; sudo udevadm settle
	K4=/dev/$(ls /sys/bus/pseudo/drivers/scsi_debug/adapter*/host*/target*/*/block/ | head -1)
	# the AMD label: LBA 0x5000 in 512 B sectors
	k4label() { sudo dd if=$K4 bs=4096 skip=$((0x5000 * 512 / 4096)) count=1 status=none | grep -q RAIDCore; }
	OUT=$($M -C /dev/md/k4c -e amd -n2 $K4 $MA7 --run 2>&1); RC=$?
	check "26: -C on a 4Kn disk ($K4, $(cat /sys/block/${K4#/dev/}/queue/logical_block_size) B): refused, said why, no AMD label written" "[ $RC != 0 ] && echo \"\$OUT\" | grep -q '512-byte logical sectors only' && ! k4label"
	OUT=$($M $MAC --add $K4 2>&1); RC=$?
	check "26: --add of a 4Kn disk to a container: refused, said why, no AMD label written" "[ $RC != 0 ] && echo \"\$OUT\" | grep -q '512-byte logical sectors only' && ! k4label"
	stopall; sudo udevadm settle; sudo rmmod scsi_debug
else
	skip "26 (e) (4Kn disk)" "needs the scsi_debug module"
fi
stopall
# (f) -A --update=X: AMD disks have no --update (volumes have --update-subarray); refused in one line, as IMSM, not
#     "storing AMD metadata on a single disk is not supported" + "Could not re-write superblock" per disk and rc 0
OUT=$($M -A /dev/md/mac -e amd $MA0 $MA1 --update=name 2>&1); RC=$?
check "26: -A --update=name of an AMD container: refused in one line, nothing assembled" "[ $RC != 0 ] && echo \"\$OUT\" | grep -q 'update=name not understood for amd metadata' && ! echo \"\$OUT\" | grep -q 'Could not re-write' && ! grep -q 'external:amd' /proc/mdstat"
# Assemble asks each disk (UOPT_SPEC_ASSEMBLE); non-zero with --force means "clearing FAULTY flag" and a disk write
OUT=$($M -A /dev/md/mac -e amd --force $MA0 $MA1 2>&1); RC=$?
check "26: -A --force of an AMD container: assembled, nothing stored" "[ $RC = 0 ] && echo \"\$OUT\" | grep -q 'has been assembled' && ! echo \"\$OUT\" | grep -q 'FAULTY\|Could not re-write'"
stopall
stopall
for i in 0 1 2 3 4 5 6 7; do $M --zero-superblock $(mal $i) >/dev/null 2>&1; sudo losetup -d $(mal $i); done
rm -rf $IMG/ma
fi
# --- end of stage 26 ---
# --- stage 27: TRIM by members. The AMD driver does not TRIM a mirror if any of its disks does not
# read zeroes after TRIM, and decides per request (rcblob RC_IsTrimAllowed, RC_DeterministicTrimZeroCount). mdmon decides
# at open_new by members and again on each spare search: with the disk it takes for a rebuild or --grow (before
# md adds it), and after a failure. TRIM it turned off comes back when the members allow again: a multiple of
# the previous granularity, at most UINT_MAX. Kernels 6.17+ and 6.12.42+ without the kernel/blk-discard patch, after 0 in
# discard_max_bytes, take no other value - then TRIM stays off (KLIFT=0, probed on scsi_debug).
# A degraded mirror whose present members read zeroes keeps TRIM (AMD's does not): what md trims without the target
# of a recorded rebuild shows in the volume's stat (field 14, as writes in field 7) - the target is copied from 0.
if want 27; then
sd() { lsblk -dno NAME,SERIAL | awk -v s=$1 '$2 == s { print "/dev/" $1 }'; }
tmax() { cat /sys/block/$1/queue/discard_max_bytes; }
kc() { sudo dmesg | grep -c "mdmon: amd: TRIM off on $1"; }	# how many times mdmon turned TRIM off (mdN ...; ".*" - any)
kl() { sudo dmesg | grep -c "mdmon: amd: TRIM $1"; }	# «on again on mdN:», «stays off on mdN »
tgran() { local d g=0; for d in "$@"; do d=$(basename $d); [ $(cat /sys/block/$d/queue/discard_granularity) -gt $g ] && g=$(cat /sys/block/$d/queue/discard_granularity); done; echo $g; }
# whether the kernel takes discard_max_bytes back after 0 (fad6551fcf53: no, the kernel/blk-discard patch: yes)
klift() { local d q r=1; sudo modprobe scsi_debug dev_size_mb=8 lbpu=1 lbprz=1 unmap_granularity=8 2>/dev/null || return 1
	sleep 1; d=$(ls /sys/bus/pseudo/drivers/scsi_debug/adapter*/host*/target*/*/block/ | head -1); q=/sys/block/$d/queue
	if [ -n "$d" ] && echo 0 | sudo tee $q/discard_max_bytes >/dev/null; then echo 1048576 | sudo tee $q/discard_max_bytes >/dev/null 2>&1 && r=0; fi
	sudo udevadm settle; sudo rmmod scsi_debug; return $r; }
klift && KLIFT=1 || KLIFT=0
tblank() { local d; for d in $TN0 $TN1 $TS0; do $M -E $d 2>/dev/null | grep -q 'Magic : RAIDCore' && return 1; done; return 0; }
twipe() { local d; stopall; for d in $TN0 $TN1 $TS0; do sudo blkdiscard -f $d 2>/dev/null || sudo dd if=/dev/zero of=$d bs=1M count=12 oflag=direct status=none; done; }
TN0=$(sd AMDNVME0); TN1=$(sd AMDNVME1); TS0=$(sd AMDSATA0)
if ! amd_disks AMDNVME0 AMDNVME1 AMDSATA0; then skip "27 (a)-(e) (AMDNVME0, AMDNVME1, AMDSATA0)" "$AMD_DISKS_WHY"; else
check "27: AMDNVME0, AMDNVME1, AMDSATA0 there and blank" "[ -n '$TN0' ] && [ -n '$TN1' ] && [ -n '$TS0' ] && tblank"
if [ -n "$TN0" ] && [ -n "$TN1" ] && [ -n "$TS0" ] && tblank; then
	$M -C /dev/md/tc -e amd -n2 $TN0 $TN1 --run >/dev/null 2>&1
	$M -C /dev/md/tr -e amd -l1 -n2 -z 64M $TN0 $TN1 --run >/dev/null 2>&1; sleep 1; waitrec; sleep 2
	TR=$(mdof raid1)
	check "27: RAID1 of the two NVMe (DLFEAT: zeroes after TRIM): TRIM kept" "[ -n '$TR' ] && [ \$(tmax $TR) != 0 ]"
	# (a) assembly without a member; it comes back (udev -I) and is rebuilt in its slot
	stopall; K=$(kc '.*')
	$M -I $TN0 >/dev/null 2>&1; $M -IRs >/dev/null 2>&1; sleep 2; TR=$(mdof raid1)
	check "27: assembled without a member, the one there reads zeroes: TRIM kept" "[ -n '$TR' ] && grep -A1 \"^$TR \" /proc/mdstat | grep -q '\[2/1\]' && [ \$(tmax $TR) != 0 ] && [ \$(kc '.*') = $K ]"
	$M -I $TN1 >/dev/null 2>&1; sleep 2; waitrec; sleep 2
	check "27: ... the member back, rebuilt in its slot (reads zeroes): TRIM kept" "grep -A1 \"^$TR \" /proc/mdstat | grep -q '\[2/2\] \[UU\]' && [ \$(tmax $TR) != 0 ] && [ \$(kc '.*') = $K ]"
	# (b) a failure with no spare; then a global spare without zeroes (QEMU SATA) - rebuild onto it
	$M /dev/$TR --fail $TN1 >/dev/null 2>&1; sleep 3
	check "27: a member failed, no spare: TRIM kept" "[ \$(tmax $TR) != 0 ] && [ \$(kc '.*') = $K ]"
	TC=$(cont1)
	$M /dev/$TC --add $TS0 >/dev/null 2>&1; sleep 3
	check "27: rebuilding onto a global spare that reads no zeroes (SATA): TRIM off as md takes it, said in dmesg" "[ -e /sys/block/$TR/md/dev-\$(basename $TS0) ] && [ \$(tmax $TR) = 0 ] && [ \$(kc '$TR as the AMD driver does: the new member does not read zeroes after TRIM') -gt 0 ] && [ \$(kc '.*') -gt $K ]"
	waitrec; sleep 2
	check "27: ... rebuilt: [2/2], TRIM still off" "grep -A1 \"^$TR \" /proc/mdstat | grep -q '\[2/2\] \[UU\]' && [ \$(tmax $TR) = 0 ]"
	# (c) assembly with only the disk without zeroes
	stopall; K=$(kc '.*')
	$M -I $TS0 >/dev/null 2>&1; $M -IRs >/dev/null 2>&1; sleep 2; TR=$(mdof raid1)
	check "27: assembled with only the SATA member: TRIM off (a member does not read zeroes)" "[ -n '$TR' ] && grep -A1 \"^$TR \" /proc/mdstat | grep -q '\[2/1\]' && [ \$(tmax $TR) = 0 ] && [ \$(kc '$TR as the AMD driver does: a member does not read zeroes after TRIM') -gt 0 ] && [ \$(kc '.*') -gt $K ]"
	# (d) the absent NVMe is back - rebuilt in its slot (SATA still a member: TRIM stays off); SATA fails -
	# the members read zeroes again: TRIM back (the kernel takes it) or stays off, one line in dmesg (it does not)
	TG=$(tgran $TN0 $TS0); TH=$(cat /sys/block/$TR/queue/discard_max_hw_bytes); [ $TH -gt 4294967295 ] && TH=4294967295
	$M -I $TN0 >/dev/null 2>&1; sleep 2; waitrec; sleep 2
	K=$(kl 'on again on .*:'); KS=$(kl 'stays off on .* ')
	check "27: ... the NVMe member back, rebuilt in its slot: TRIM still off (the SATA one is a member)" "grep -A1 \"^$TR \" /proc/mdstat | grep -q '\[2/2\] \[UU\]' && [ \$(tmax $TR) = 0 ]"
	$M /dev/$TR --fail $TS0 >/dev/null 2>&1; sleep 4
	if [ $KLIFT = 1 ]; then
		check "27: the SATA member failed: TRIM on again, a multiple of the granularity ($TG) up to the members' limit ($TH), said in dmesg" "T=\$(tmax $TR); [ \$T -gt 0 ] && [ \$((T % $TG)) = 0 ] && [ \$T -le $TH ] && [ \$((T + $TG)) -gt $TH ] && [ \$(kl 'on again on $TR:') -gt $K ] && sudo blkdiscard -o 0 -l 1048576 /dev/$TR"
	else
		check "27: the SATA member failed: the kernel takes no value back (6.17+/6.12.42+ unpatched) - TRIM stays off, said once" "[ \$(tmax $TR) = 0 ] && [ \$(kl 'stays off on .* ') = \$(( $KS + 1 )) ] && pgrep -x mdmon >/dev/null"
	fi
	twipe
	check "27: the AMD controller disks blank again" "tblank"
	# (e) a recorded rebuild onto NVMe interrupted; assembled without the target, md trims - the target is copied from 0, check clean
	$M -C /dev/md/tc -e amd -n2 $TN0 $TS0 --run >/dev/null 2>&1
	$M -C /dev/md/tr -e amd -l1 -n2 -z 64M $TN0 $TS0 --run >/dev/null 2>&1; sleep 1; waitrec; sleep 2
	TR=$(mdof raid1); TC=$(cont1)
	head -c 4M /dev/urandom > $TMPW/amd-trim.bin; sudo dd if=$TMPW/amd-trim.bin of=/dev/$TR bs=1M oflag=direct status=none
	$M /dev/$TC --add $TN1 >/dev/null 2>&1; sleep 2
	echo 3000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
	$M /dev/$TR --fail $TS0 >/dev/null 2>&1; sleep 8; stopall
	echo 1000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
	$M -I $TN0 >/dev/null 2>&1; $M -I $TS0 >/dev/null 2>&1; $M -IRs >/dev/null 2>&1; sleep 3; TR=$(mdof raid1)
	TP=$(tlogf $TN0 0x100000 | cut -d' ' -f2)
	check "27: rebuild onto NVMe recorded midway ($TP), started without its target: the NVMe there reads zeroes, TRIM kept" "[ -n '$TR' ] && [ $TP -gt $((8 * 2048)) ] && [ \$(tmax $TR) != 0 ]"
	sudo blkdiscard -o 0 -l $((4 << 20)) /dev/$TR; sleep 7
	check "27: md trimmed without the target: the log goes to 0 (was $TP)" "[ \"\$(tlogf $TN0 0x100000 | cut -d' ' -f2,3)\" = '0 1' ]"
	$M -I $TN1 >/dev/null 2>&1; sleep 3
	check "27: the target comes: copied from 0" "[ \$(cut -d' ' -f1 /sys/block/$TR/md/sync_completed) -lt $TP ]"
	echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null; waitrec; sleep 3
	echo check | sudo tee /sys/block/$TR/md/sync_action >/dev/null; sleep 1; waitrec
	check "27: done, md check clean, the trimmed 4 MiB zeroes on the target too" "grep -A2 \"^$TR \" /proc/mdstat | grep -q '\[2/2\] \[UU\]' && [ \$(cat /sys/block/$TR/md/mismatch_cnt) = 0 ] && cmp -s -n $((4 << 20)) /dev/zero <(sudo dd if=$TN1 bs=512 skip=\$(cat /sys/block/$TR/md/dev-\$(basename $TN1)/offset) count=8192 iflag=direct status=none)"
	twipe; rm -f $TMPW/amd-trim.bin
	check "27: the AMD controller disks blank again" "tblank"
fi
fi
# (f) --grow RAIDABLE -> RAID1 (snapshot 04, trimmed, as in stage 15b) onto a loop disk: zeroes after TRIM unknown
if ! mountpoint -q $WQ; then	# as at the start of stage 4 (for a separate run)
	[ -e $IMG/q.btrfs ] || { truncate -s 16G $IMG/q.btrfs && sudo /sbin/mkfs.btrfs -q -f $IMG/q.btrfs; }
	sudo mkdir -p $WQ && sudo mount -o loop,compress-force=zstd:1 $IMG/q.btrfs $WQ && sudo chown $USER $WQ
fi
SD=$FIXT/2026-11-06-qemu-spares-raidable
DN="sata0 sata1 sata2 sata3 sata4 nvme0"
dset 04-raidable 840a7c70b562 0x10000 88a5d4fa2af7 0x100000
truncate -s 64G $WQ/d/gs.img; GS=$(sudo losetup -f --show $WQ/d/gs.img)
$M -A /dev/md/gr -e amd $(DL sata0) $(DL sata1) $(DL sata2) $(DL sata3) >/dev/null 2>&1; $M -I /dev/md/gr >/dev/null 2>&1; sleep 2; waitrec
GR=$(for m in $(ls /sys/block | grep ^md); do [ "$(cat /sys/block/$m/size)" = 1048576 ] && echo $m; done)
check "27: RAIDABLE (md raid1 of one loop disk): TRIM kept - one copy" "[ -n '$GR' ] && [ \$(cat /sys/block/$GR/md/raid_disks) = 1 ] && [ \$(tmax $GR) != 0 ]"
$M /dev/md/gr --add $GS >/dev/null 2>&1; sleep 2
K=$(kc "$GR as the AMD driver does: the new member does not read zeroes after TRIM")
$M --grow /dev/$GR --raid-devices=2 >/dev/null 2>&1; sleep 3
check "27: --grow -n 2 onto a loop disk: TRIM off as md takes it (the new member reads no zeroes), said in dmesg" "[ \$(cat /sys/block/$GR/md/raid_disks) = 2 ] && [ -e /sys/block/$GR/md/dev-\$(basename $GS) ] && [ \$(tmax $GR) = 0 ] && [ \$(kc '$GR as the AMD driver does: the new member does not read zeroes after TRIM') -gt $K ]"
waitrec; sleep 2
check "27: ... the mirror done: [2/2], TRIM still off" "grep -A2 \"^$GR \" /proc/mdstat | grep -q '\[2/2\] \[UU\]' && [ \$(tmax $GR) = 0 ]"
stopall
sudo losetup -d $GS; for n in $DN; do sudo losetup -d $(DL $n) 2>/dev/null; done; rm -rf $WQ/d
fi
# --- end of stage 27 ---
# --- stage 28: volume Handles (LD +0x34) consecutive, as RAIDCoreDxe assigns them ---
# Uses the helpers of the suite ($M, check, stopall,
# cont1, waitrec and l3load/l3drop of stage 23). The firmware, reading the configuration, gives each LD a slot in packet order
# from 1 (Legacy too; the second transform copy gets the number of the main one, FUN_0002be1c); if a Handle in the packet differs,
# at boot it rewrites the configuration, losing PD DeviceIDs (emulated board: dump 2026-11-02-post-mdadm-r10 → configuration
# 5, as on the test PC). Without the fix (a)–(e) fail: after deleting a middle volume, after a Legacy repair
# and in an old configuration with a gap, Handles skip a number, a new volume gets "maximum + 1".
if want 28; then
cd "$MDADM_DIR"
stopall
for l in $(sudo losetup -a | grep $WQ/hd/ | cut -d: -f1); do sudo losetup -d $l; done
mkdir -p $WQ/hd && rm -f $WQ/hd/*.img
HL=""; for n in 0 1 2 3; do truncate -s 1G $WQ/hd/d$n.img; HL="$HL $(sudo losetup -f --show $WQ/hd/d$n.img)"; done
# LD Handles of the live packet of image $1 in order, and "ok" if they are as the firmware's, else "GAP"
hdl() { python3 - "$1" <<'PY'
import os, sys
sys.path.insert(0, os.environ["TOOLS"])
import amdraid_dump as a
d = a.Disk(sys.argv[1])
c = a.parse_commit(d.read(a.LBA_COMMIT))
g = a.read_gen(d, c['gen_lba'], c['gen_len'])
h, pds, lds = a.parse_gen(g)
hs, want, n, copy = [], [], 0, 0
for ld in lds:
    n += 0 if copy else 1
    want.append(n)
    hs.append(a.u16(g, ld['off'] + 0x34))
    copy = 0 if copy else ld['linked_next'] == 1
print(' '.join(map(str, hs)) + (' ok' if hs == want else ' GAP'))
PY
}
# set LD Handles of the live packet of images $2... from list $1 ("1,3"): a configuration as the earlier mdadm wrote
hset() { python3 - "$@" <<'PY'
import os, struct, sys
sys.path.insert(0, os.environ["TOOLS"])
import amdraid_dump as a
hs = [int(x) for x in sys.argv[1].split(',')]
for p in sys.argv[2:]:
    d = a.Disk(p)
    c = bytearray(d.read(a.LBA_COMMIT))
    lba, ln = a.u32(c, 8), a.u32(c, 0xC)
    g = bytearray(a.read_gen(d, lba, ln))
    h, pds, lds = a.parse_gen(bytes(g))
    for ld, x in zip(lds, hs):
        struct.pack_into('<H', g, ld['off'] + 0x34, x)
    s = a.rc_sum(g, 0xC, h['length'] - 0xC)
    struct.pack_into('<Q', g, 0, s)
    struct.pack_into('<Q', c, 0x10, s)
    struct.pack_into('<Q', c, 0, a.rc_sum(c, 8, 0x1F8))
    with open(p, 'r+b') as f:
        f.seek(lba * 512)
        f.write(g)
        f.seek(a.LBA_COMMIT * 512)
        f.write(c)
PY
}
HD0=$WQ/hd/d0.img
$M -C /dev/md/hdc -e amd -n4 $HL --run >/dev/null 2>&1
$M -C /dev/md/hm0 -l1 -n2 -z 64M /dev/md/hdc --assume-clean --run >/dev/null 2>&1
for v in hv1 hv2 hv3; do $M -C /dev/md/$v -l0 -n2 -z 32M /dev/md/hdc --run >/dev/null 2>&1; done; sleep 1
check "28: four volumes made one by one: Handles 1 2 3 4" "[ \"\$(hdl $HD0)\" = '1 2 3 4 ok' ]"
for v in hv1 hv2 hv3; do $M -S /dev/md/$v >/dev/null 2>&1; done
$M --kill-subarray=1 /dev/md/hdc >/dev/null 2>&1; sleep 2
check "28 (a): --kill-subarray of the 2nd volume by mdmon: the later ones move down, Handles 1 2 3" "pgrep -x mdmon >/dev/null && [ \"\$(hdl $HD0)\" = '1 2 3 ok' ]"
stopall
$M -A /dev/md/hdc $HL >/dev/null 2>&1
$M --kill-subarray=1 /dev/md/hdc >/dev/null 2>&1
check "28 (b): ... and by mdadm without mdmon: Handles 1 2" "! pgrep -x mdmon >/dev/null && [ \"\$(hdl $HD0)\" = '1 2 ok' ]"
stopall
# (c) a configuration with a gap (as the earlier mdadm wrote): the next write renumbers
hset 1,3 $WQ/hd/d?.img; for l in $HL; do sudo blockdev --flushbufs $l; done
check "28: (a gap made: Handles 1 3)" "[ \"\$(hdl $HD0)\" = '1 3 GAP' ]"
$M -A /dev/md/hdc $HL >/dev/null 2>&1
$M --update-subarray=1 --update=name -N hv3b /dev/md/hdc >/dev/null 2>&1
check "28 (c): the next write (--update-subarray, no mdmon) closes the gap: Handles 1 2" "[ \"\$(hdl $HD0)\" = '1 2 ok' ]"
stopall
hset 1,3 $WQ/hd/d?.img; for l in $HL; do sudo blockdev --flushbufs $l; done
for d in $HL; do $M -I $d >/dev/null 2>&1; done; sleep 2
# (d) a new volume after a gap gets the next number, not "maximum + 1"; a volume md initializes has two LD records,
# the second copy has the same Handle
echo 1000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
$M -C /dev/md/hm4 -l1 -n2 -z 64M /dev/$(cont1) --run >/dev/null 2>&1; sleep 2
check "28 (d): -C after a gap (mdmon): Handles 1 2 3, the initialization copy has the Handle of its LD" "[ \"\$(hdl $HD0)\" = '1 2 3 3 ok' ]"
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null; waitrec; sleep 2
check "28: ... initialized: one LD record each, Handles 1 2 3" "[ \"\$(hdl $HD0)\" = '1 2 3 ok' ]"
stopall
for l in $HL; do sudo losetup -d $l; done; rm -rf $WQ/hd
# (e) mdadm without mdmon repairs the XPG Legacy (stage 23 data): the extra Legacy LD cut out, the Legacy LD counted
HD=$FIXT/2026-11-02-msi-x870e-hdd; HS="WX41A685FR98 WES1KE09 JR10044M28WJGM WX61A68KYK45"
l3load
check "28: (dump 2026-11-02-msi-x870e-hdd, configuration 19 by the menu: Handles 1-7 in order)" "[ \"\$(hdl $WQ/l3/WES1KE09.img)\" = '1 2 2 3 3 4 5 5 6 7 ok' ]"
$M --kill-subarray=4 /dev/md/l3 >/dev/null 2>&1
check "28 (e): --kill-subarray of the Volume and the extra Legacy LD dropped: Handles 1-5 in order on every disk" "( for s in \$HS; do [ \"\$(hdl $WQ/l3/\$s.img)\" = '1 2 2 3 3 4 4 5 ok' ] || exit 1; done )"
l3drop
fi
# --- end of stage 28 ---

# --- stage 29: a volume with an interrupted rebuild and a degraded volume - the first -I ---
# CachyOS root on RAID1, reboot mid-rebuild: in the initrd fsck says "is in use", mount "Can't open blockdev" -
# emergency mode. (b) The first -I created the container itself (O_EXCL in create_mddev), mdmon_take_array() waited ~4 s for O_EXCL
# on it, all the while holding O_EXCL on the running volume; besides, the volume stayed under O_EXCL ~40 ms after start while mdadm
# started mdmon and waited for its reply (upstream too). (a) The volume started on the first disk, no target: what was written
# before it came (the configuration), it missed, and the rebuild went from 0; now -I waits for the target disk like any member.
if want 29; then
FL=""; for n in 0 1; do truncate -s 3G $WQ/c/f$n.img; FL="$FL $(sudo losetup -f --show $WQ/c/f$n.img)"; done
F0=$(echo $FL | cut -d' ' -f1); F1=$(echo $FL | cut -d' ' -f2)
$M -C /dev/md/amdf -e amd -n 2 $FL --run >/dev/null 2>&1
$M -C /dev/md/fv -l1 -n2 -z 512M /dev/$(cont1) --run --assume-clean >/dev/null 2>&1; sleep 1
FV=$(basename $(readlink -f /dev/md/fv*))
echo 5000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
$M /dev/$FV --fail $F1 >/dev/null 2>&1; sleep 2; $M /dev/$(cont1) --remove $F1 >/dev/null 2>&1; sleep 1
$M /dev/$(cont1) --add $F1 >/dev/null 2>&1; sleep 6
echo frozen | sudo tee /sys/block/$FV/md/sync_action >/dev/null; sleep 2
FRC=$(cat /sys/block/$FV/md/dev-$(basename $F1)/recovery_start)
stopall
echo 1000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
# the volume with member F0 (running or not); the target's recovery_start in it
fvol() { for m in /sys/block/md*/md; do [ -e $m/dev-$(basename $F0) ] && grep -q '^external:/' $m/metadata_version && { m=${m#/sys/block/}; echo ${m%%/*}; }; done; }
frun() { local v=$(fvol); [ -n "$v" ] && ! grep -qE 'inactive|clear' /sys/block/$v/md/array_state 2>/dev/null; }
frs() { cat /sys/block/$(fvol)/md/dev-$(basename $F1)/recovery_start 2>/dev/null; }
# (a) in both orders: first disk - no volume; second - the volume with the target, rebuild from the mark (md continues from the
# log's mark, which may be a bit below its own: 2048 sectors of slack)
for first in $F0 $F1; do
	[ $first = $F0 ] && second=$F1 || second=$F0
	$M -I $first >/dev/null 2>&1; sleep 1
	! frun; W=$?
	$M -I $second >/dev/null 2>&1; sleep 2
	FR=$(frs)
	check "29 (a), $(basename $first) first: the volume waits for the other disk ($([ $W = 0 ] && echo waits || echo started)), then runs with the rebuild target, from its checkpoint ($FRC -> $FR)" "[ $W = 0 ] && frun && [ '$FRC' -gt 4096 ] && [ -n '$FR' ] && [ '$FR' != none ] && [ '$FR' -ge $((FRC - 2048)) ]"
	stopall; sleep 1
done
# (b) a degraded volume - member F1 failed and removed, no spare: the first -I starts it.  The O_EXCL open is as
# mount and e2fsck do, only once the volume runs (not inactive: while mdadm sets it up, fsck has nothing to do there; false
# only on EBUSY: a fresh node without udev permissions gives the user EACCES); three assemblies, the time of the longest
$M -I $F0 >/dev/null 2>&1; $M -I $F1 >/dev/null 2>&1; sleep 2
$M /dev/$(fvol) --fail $F1 >/dev/null 2>&1; sleep 2; $M /dev/$(cont1) --remove $F1 >/dev/null 2>&1; sleep 1
stopall
excl() { sudo python3 -c "
import errno, os, sys
try:
    os.close(os.open(sys.argv[1], os.O_RDONLY | os.O_EXCL))
except OSError as e:
    sys.exit(e.errno == errno.EBUSY)" $1 2>/dev/null; }
FB=0; FT=0
for r in 1 2 3; do
	[ $r = 1 ] || { stopall; sleep 1; }
	FV=; t=$(date +%s%N)
	$M -I $F0 >/dev/null 2>&1 &
	while kill -0 $! 2>/dev/null; do
		[ -n "$FV" ] || FV=$(fvol)
		[ -n "$FV" ] && [ -b /dev/$FV ] && ! grep -qE 'inactive|clear' /sys/block/$FV/md/array_state 2>/dev/null &&
			! excl /dev/$FV && FB=$((FB + 1))
		sleep 0.02
	done
	t=$(( ($(date +%s%N) - t) / 1000000 )); [ $t -gt $FT ] && FT=$t
done
check "29 (b): the first -I starts a degraded volume (a member failed, no spare) in $FT ms at most, never holding it O_EXCL once running ($FB busy)" "frun && [ $FT -lt 2000 ] && [ $FB = 0 ]"
stopall; for l in $FL; do sudo losetup -d $l; done; rm -f $WQ/c/f*.img
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
fi
# --- end of stage 29 ---

# --- stage 30: mdmon writes that waited for disks in vain, and a volume taken over while running ---
# Uses the helpers of the suite ($M, check, stopall,
# cont1, waitrec, mdof). Own images, $WQ/q3m, 1 GiB sparse. Without the fixes (on the base) these fail:
# (a) MON-A1, (b) MON-A1 + MON-A2, (c) and (d) MON-A3, (e) the second check of MON-A4; (f) passes on the base too.
if want 30; then
cd "$MDADM_DIR"
Q3=$WQ/q3m
q3l() { sudo losetup -j $Q3/$1.img | cut -d: -f1; }
q3sec() { $M -E $(q3l g0) 2>/dev/null | sed -n "/^\[$1\]/,/^\[/p"; }
q3clean() { stopall; for l in $(sudo losetup -a | grep "$Q3/" | cut -d: -f1); do sudo losetup -d $l; done; rm -f $Q3/*.img; }
q3mk() { sudo mkdir -p $Q3; sudo chown $(id -un) $Q3; q3clean; for n in $(seq 0 $(($1 - 1))); do truncate -s 1G $Q3/g$n.img; sudo losetup -f $Q3/g$n.img; done; }
q3speed() { echo $1 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null; }
q3done() { q3sec qv | grep -q 'State : 0x200 (normal)' && q3sec qv | grep -q 'last 0x5355, state 0xa1a6'; }
Q3SPEED=$(cat /proc/sys/dev/raid/speed_limit_max 2>/dev/null || echo 200000)	# md_mod not loaded yet: the kernel default

# (a) MON-A1: a free disk of the container removed with the system off (its PD in the packet ONLINE), the volume midway
# through an initialization: its end must be recorded without that disk
q3mk 3
$M -C /dev/md/qc -e amd -n3 $(q3l g0) $(q3l g1) $(q3l g2) --run >/dev/null 2>&1
q3speed 2000
$M -C /dev/md/qv -e amd -l1 -n2 -z 128M $(q3l g0) $(q3l g1) --run >/dev/null 2>&1; sleep 3
stopall; sudo losetup -d $(q3l g2); q3speed $Q3SPEED
$M -A /dev/md/qc -e amd $(q3l g0) $(q3l g1) >/dev/null 2>&1; $M -I /dev/$(cont1) >/dev/null 2>&1; sleep 2; waitrec; sleep 5
check "30 (a): the end of an initialization is recorded with a free disk gone (PD ONLINE)" "q3done"
q3clean

# (b) MON-A1, MON-A2: a configuration write to a member failed (write_failed): the end of an initialization is written
# to the other disks, no transform log is written to the stale one (and the kernel log is not flooded)
q3mk 3
$M -C /dev/md/qc -e amd -n2 $(q3l g0) $(q3l g1) --run >/dev/null 2>&1
q3speed 2000
$M -C /dev/md/qv -e amd -l1 -n2 -z 128M $(q3l g0) $(q3l g1) --run >/dev/null 2>&1; sleep 2
sudo dmesg -C
sudo blockdev --setro $(q3l g1)
$M /dev/$(cont1) --add $(q3l g2) >/dev/null 2>&1; sleep 2
q3speed $Q3SPEED; waitrec; sleep 5
sudo blockdev --setrw $(q3l g1)
check "30 (b): the end of an initialization is recorded on the disks that take the configuration" "q3done"
check "30 (b): no transform log on the disk a configuration write failed on" \
	"[ \$(sudo dmesg | grep -c 'amd: cannot write the transform log') = 0 ]"
q3clean

# (c) MON-A3: a member failed while mdmon was being replaced (--takeover): the new mdmon read the configuration before
# the old one wrote it. The volume is taken over running (no set_array_state(2)); the failure must stay recorded, the rebuild
# onto the same disk recorded as a rebuild (not as "member in service"): after assembly the mirror agrees
q3mk 2
$M -C /dev/md/qc -e amd -n2 $(q3l g0) $(q3l g1) --run >/dev/null 2>&1
$M -C /dev/md/qv -e amd -l1 -n2 -z 128M $(q3l g0) $(q3l g1) --run >/dev/null 2>&1; waitrec; sleep 3
V=$(mdof raid1); C=$(cont1); L1=$(basename $(q3l g1))
OLD=$(pgrep -x mdmon)
sudo kill -STOP $OLD
sudo ./mdmon --takeover $C & sleep 2
echo faulty | sudo tee /sys/block/$V/md/dev-$L1/state >/dev/null
sudo kill -CONT $OLD
for i in $(seq 1 100); do sudo kill -0 $OLD 2>/dev/null || break; sleep 0.1; done
q3speed 1000
sudo timeout 10 dd if=/dev/urandom of=/dev/$V bs=1M seek=100 count=4 oflag=direct status=none
sleep 6
check "30 (c): a member failed during the takeover stays out of service or is recorded as rebuilt" \
	"q3sec qv | grep -q -E 'Member +1 .*out of service' || q3sec qv | grep -q 'State : 0x201'"
stopall; q3speed $Q3SPEED
$M -A /dev/md/qc -e amd $(q3l g0) $(q3l g1) >/dev/null 2>&1; $M -I /dev/$(cont1) >/dev/null 2>&1; sleep 2; waitrec; sleep 3
V=$(mdof raid1)
echo check | sudo tee /sys/block/$V/md/sync_action >/dev/null; sleep 1; waitrec
check "30 (c): the mirror agrees after the next assembly (mismatch_cnt $(cat /sys/block/$V/md/mismatch_cnt))" \
	"[ \"\$(cat /sys/block/$V/md/mismatch_cnt)\" = 0 ] && grep -A1 \"^$V\" /proc/mdstat | grep -q '\[UU\]'"
q3clean

# (d) MON-A3: mdmon killed, a member fails without it, mdmon started anew: the volume taken over running, the failure recorded
q3mk 2
$M -C /dev/md/qc -e amd -n2 $(q3l g0) $(q3l g1) --run >/dev/null 2>&1
$M -C /dev/md/qv -e amd -l1 -n2 -z 128M $(q3l g0) $(q3l g1) --run >/dev/null 2>&1; waitrec; sleep 3
V=$(mdof raid1); C=$(cont1); L1=$(basename $(q3l g1))
sudo kill -9 $(pgrep -x mdmon); sleep 1
echo faulty | sudo tee /sys/block/$V/md/dev-$L1/state >/dev/null
q3speed 1000
sudo ./mdmon $C; sleep 4
check "30 (d): a failure without mdmon is recorded by the mdmon started anew" "q3sec qv | grep -q 'State : 0x201'"
q3speed $Q3SPEED
q3clean

# (e) MON-A4: mdmon killed midway through a recorded rebuild, md finishes it alone, mdmon started anew: the volume taken
# over running, the monitor never sees the end of recovery: the end of the rebuild must still be recorded
q3mk 3
$M -C /dev/md/qc -e amd -n2 $(q3l g0) $(q3l g1) --run >/dev/null 2>&1
$M -C /dev/md/qv -e amd -l1 -n2 -z 128M $(q3l g0) $(q3l g1) --run >/dev/null 2>&1; waitrec; sleep 3
V=$(mdof raid1); C=$(cont1); L1=$(basename $(q3l g1))
$M /dev/$C --add $(q3l g2) >/dev/null 2>&1; sleep 2
q3speed 2000
echo faulty | sudo tee /sys/block/$V/md/dev-$L1/state >/dev/null
sleep 6
check "30 (e): the rebuild onto the spare is recorded" "q3sec qv | grep -q 'Transform : 0x5358'"
sudo kill -9 $(pgrep -x mdmon); sleep 1
q3speed $Q3SPEED; waitrec 120; sleep 2
sudo ./mdmon $C; sleep 5
check "30 (e): a rebuild md finished without mdmon is recorded as finished" \
	"q3sec qv | grep -q 'State : 0x200 (normal)' && q3sec qv | grep -q 'Transform : 0x0, last 0x5358, state 0xa1a6'"
q3clean

# (f) the same with an initialization: mdmon killed midway, md finishes it alone, the new mdmon records the end
q3mk 2
$M -C /dev/md/qc -e amd -n2 $(q3l g0) $(q3l g1) --run >/dev/null 2>&1
q3speed 2000
$M -C /dev/md/qv -e amd -l1 -n2 -z 128M $(q3l g0) $(q3l g1) --run >/dev/null 2>&1; sleep 3
C=$(cont1)
sudo kill -9 $(pgrep -x mdmon); sleep 1
q3speed $Q3SPEED; waitrec 120; sleep 2
sudo ./mdmon $C; sleep 5
check "30 (f): an initialization md finished without mdmon is recorded as finished" "q3done"
q3clean
fi
# --- end of stage 30 ---

# --- stage 31: creating and changing volumes: a race of two -C, refusals ---
# Uses the helpers of the suite ($M, check, stopall,
# cont1, waitrec, mdof). Alone: STAGES=31 ./run.sh <tree>. On the base (e2368f9f) all checks fail
# but those marked "passes on the base too".
if want 31; then
cd "$MDADM_DIR"
stopall
for l in $(sudo losetup -a | grep $WQ/q3c/ | cut -d: -f1); do sudo losetup -d $l; done
mkdir -p $WQ/q3c && rm -f $WQ/q3c/*.img
q3mk() { QL=""; for n in $(seq 0 $(($1 - 1))); do rm -f $WQ/q3c/d$n.img; truncate -s $2 $WQ/q3c/d$n.img; QL="$QL $(sudo losetup -f --show $WQ/q3c/d$n.img)"; done; QL=${QL# }; Q1=${QL%% *}; }
q3drop() { stopall; for l in $(sudo losetup -a | grep $WQ/q3c/ | cut -d: -f1); do sudo losetup -d $l; done; rm -f $WQ/q3c/*.img; }
q3gen() { $M -E $Q1 2>/dev/null | sed -n 's/^ *Generation : //p'; }
q3vols() { $M -E $Q1 2>/dev/null | grep -c '^\['; }
# two mdadm -C at once: the volumes of those that returned 0 must be on the disks, and only those (CRE-A1)
q3pair() {	# q3pair <name1> <args1> -- <name2> <args2>
	local a=$1 b; shift; local aa=""; while [ "$1" != -- ]; do aa="$aa $1"; shift; done; shift; b=$1; shift
	( $M -C /dev/md/$a $aa --run >$TMPW/q3-$a.log 2>&1; echo $? >$TMPW/q3-$a.rc ) &
	( $M -C /dev/md/$b "$@" --run >$TMPW/q3-$b.log 2>&1; echo $? >$TMPW/q3-$b.rc ) &
	wait
	QW=""; for v in $a $b; do [ "$(cat $TMPW/q3-$v.rc)" = 0 ] && QW="$QW $v"; done
	for v in $QW; do $M -E $Q1 2>/dev/null | grep -q "^\[$v\]" || return 1; done
	return 0
}

# (a) no mdmon (RAID0): the loser laid out its volume by a configuration read before the first one wrote
q3mk 4 1G
$M -C /dev/md/q3c -e amd -n 4 $QL --run >/dev/null 2>&1; CN=$(cont1)
q3pair qa -l0 -n2 -z 64M /dev/$CN -- qb -l0 -n2 -z 64M /dev/$CN; QP=$?; NW=$(echo $QW | wc -w)
check "31 (a): two -C at once, no mdmon: every volume reported as started is in the configuration, no other" "[ $QP = 0 ] && [ $NW != 0 ] && [ \$(q3vols) = $NW ] && [ \$(grep -c '^md.* : active raid0' /proc/mdstat) = $NW ]"
check "31 (a): the one that lost says the configuration changed, or both were created" "[ $NW = 2 ] || grep -q 'changed since it was read' $TMPW/q3-qa.log $TMPW/q3-qb.log"
q3drop

# (b) under mdmon, volumes on different disks: md and the configuration agree on the subarray number
q3mk 6 1G; set -- $QL
$M -C /dev/md/q3c -e amd -n 6 $QL --run >/dev/null 2>&1; CN=$(cont1)
$M -C /dev/md/q0 -e amd -l1 -n2 -z 64M $1 $2 --run >/dev/null 2>&1; waitrec 60
q3pair qc -e amd -l1 -n2 -z 64M $3 $4 -- qd -e amd -l1 -n2 -z 64M $5 $6; QP=$?; NW=$(echo $QW | wc -w)
sleep 1
q3num() { for m in $(grep '^md.* : active raid1' /proc/mdstat | cut -d' ' -f1); do sed 's,.*/,,' /sys/block/$m/md/metadata_version; done | sort | xargs; }
check "31 (b): two -C at once under mdmon, other disks: each md array has a subarray number of its own, as in the configuration" "[ $QP = 0 ] && [ $NW != 0 ] && [ \$(q3vols) = $((1 + NW)) ] && [ \"\$(q3num)\" = \"$(seq -s' ' 0 $NW)\" ]"
q3drop

# (c) MAN-A1: the write failed (disks read-only): no "Deleted subarray", exit code not 0
q3mk 2 1G
$M -C /dev/md/q3c -e amd -n 2 $QL --run >/dev/null 2>&1; CN=$(cont1)
$M -C /dev/md/q0 -l0 -n2 -z 64M /dev/$CN --run >/dev/null 2>&1; $M -C /dev/md/q1 -l0 -n2 -z 64M /dev/$CN --run >/dev/null 2>&1
for m in $(mdof raid0); do $M -S /dev/$m >/dev/null 2>&1; done
for l in $QL; do sudo blockdev --setro $l; done
OUT=$($M --kill-subarray=1 /dev/$CN 2>&1); RC=$?
check "31 (c): --kill-subarray without mdmon, write fails: said, exit code not 0" "[ $RC != 0 ] && ! echo \"\$OUT\" | grep -q 'Deleted subarray' && echo \"\$OUT\" | grep -q 'cannot write the AMD RAID configuration'"
OUT=$($M --update-subarray=1 --update=name -N q1new /dev/$CN 2>&1); RC=$?
check "31 (c): --update-subarray without mdmon, write fails: said, exit code not 0" "[ $RC != 0 ] && ! echo \"\$OUT\" | grep -q 'Updated subarray' && [ \$(q3vols) = 2 ]"
for l in $QL; do sudo blockdev --setrw $l; done
$M --kill-subarray=1 /dev/$CN >/dev/null 2>&1
check "31 (c): writable again: --kill-subarray deletes it (passes on the base too)" "[ \$(q3vols) = 1 ]"

# (d) requests that used to be changed silently or to end obscurely: refused before any write
G0=$(q3gen)
OUT=$($M -C /dev/md/qz -l1 -n2 -z 64M --write-zeroes /dev/$CN --run 2>&1)
check "31 (d): --write-zeroes with the container given: refused (was: recorded as initialized, nothing zeroed)" "echo \"\$OUT\" | grep -q 'write-zeroes is not supported' && [ \$(q3vols) = 1 ]"
OUT=$($M -C /dev/md/qz -e amd -l1 -n2 -z 64M --write-zeroes $QL --run 2>&1)
check "31 (d): --write-zeroes with the disks given: refused (was: zeroing failed)" "echo \"\$OUT\" | grep -q 'write-zeroes is not supported' && ! echo \"\$OUT\" | grep -q 'zeroing failed'"
OUT=$($M -C /dev/md/qz -l0 -n2 -z 64M --data-offset=8M /dev/$CN --run 2>&1)
check "31 (d): --data-offset: refused, as IMSM (was: ignored)" "echo \"\$OUT\" | grep -q 'data-offset not supported' && [ \$(q3vols) = 1 ]"
OUT=$($M -C /dev/md/qz -l0 -n2 -z 500K /dev/$CN --run 2>&1)
check "31 (d): --size below 1 MiB: said so (was: cannot lay out)" "echo \"\$OUT\" | grep -q 'whole MiB' && [ \$(q3vols) = 1 ]"
check "31 (d): nothing was written by the refusals" "[ \$(q3gen) = $G0 ]"
q3drop
q3mk 4 1G
$M -C /dev/md/q3c -e amd -n 4 $QL --run >/dev/null 2>&1; CN=$(cont1)
OUT=$($M -C /dev/md/qz -l10 -n4 -z 64M --layout=f2 /dev/$CN --run 2>&1)
check "31 (d): RAID10 --layout=f2: refused (was: created as n2)" "echo \"\$OUT\" | grep -q 'two near copies' && [ \$(q3vols) = 0 ]"
$M -C /dev/md/qz -l10 -n4 -z 64M --layout=n2 /dev/$CN --run >/dev/null 2>&1
check "31 (d): RAID10 --layout=n2: created (passes on the base too)" "[ \$(q3vols) = 1 ] && [ \$(cat /sys/block/\$(mdof raid10)/md/layout) = 258 ]"
q3drop

# (e) CRE-B7: 64 disks + the controller's record = 65 PD records, 64 are read
q3mk 64 600M
OUT=$($M -C /dev/md/q3c -e amd -n 64 $QL --run 2>&1)
check "31 (e): a container of 64 disks: refused, nothing written (was: the last disk unusable)" "echo \"\$OUT\" | grep -q 'only supports 63' && ! sudo dd if=$Q1 bs=512 skip=$((0x5000)) count=1 status=none | grep -q RAIDCore"
q3drop

# (f) DED-B1: <container> --remove of a global spare without mdmon: the role dropped in the PD and the label
q3mk 3 1G; set -- $QL
$M -C /dev/md/q3c -e amd -n 2 $1 $2 --run >/dev/null 2>&1; CN=$(cont1)
$M -C /dev/md/q0 -l1 -n2 -z 64M /dev/$CN --run >/dev/null 2>&1; sleep 1; waitrec 60
$M /dev/$CN --add $3 >/dev/null 2>&1; sleep 1
q3lbl() { sudo dd if=$1 bs=512 skip=$((0x5000)) count=1 status=none | od -A n -t x4 -j 52 -N 4 | tr -d ' '; }
QS0=$(q3lbl $3); QS1=$($M -E $1 2>/dev/null | grep -c 'global spare')
$M -S /dev/$(mdof raid1) >/dev/null 2>&1; for i in $(seq 1 30); do pgrep -x mdmon >/dev/null || break; sleep 0.3; done
OUT=$($M /dev/$CN --remove $3 2>&1)
check "31 (f): --remove of a global spare, no mdmon: role dropped in the label and the PD (was: cannot reach mdmon)" "[ $QS0 = 00000100 ] && [ $QS1 = 1 ] && [ \$(q3lbl $3) = 00000000 ] && echo \"\$OUT\" | grep -q 'no longer an AMD global hot spare' && ! echo \"\$OUT\" | grep -q 'cannot reach mdmon' && ! $M -E $1 2>/dev/null | grep -q 'global spare'"
q3drop

# (g) ADD-B1: --add does not silently wipe ext4 on a whole disk or a disk with a volume of another AMD configuration; --force does
for i in 0 1; do rm -f $WQ/q3c/f$i.img; truncate -s 1G $WQ/q3c/f$i.img; done
F0=$(sudo losetup -f --show $WQ/q3c/f0.img); F1=$(sudo losetup -f --show $WQ/q3c/f1.img)
$M -C /dev/md/q3f -e amd -n 2 $F0 $F1 --run >/dev/null 2>&1
$M -C /dev/md/qf -l1 -n2 -z 64M /dev/$(cont1) --run >/dev/null 2>&1; sleep 1; waitrec 60
stopall; sudo losetup -d $F0 $F1
q3mk 2 1G
$M -C /dev/md/q3c -e amd -n 2 $QL --run >/dev/null 2>&1; CN=$(cont1)
$M -C /dev/md/q0 -l1 -n2 -z 64M /dev/$CN --run >/dev/null 2>&1; sleep 1; waitrec 60
rm -f $WQ/q3c/e.img; truncate -s 1G $WQ/q3c/e.img; QE=$(sudo losetup -f --show $WQ/q3c/e.img)
sudo mkfs.ext4 -q -L precious $QE
OUT=$($M /dev/$CN --add $QE 2>&1); RC=$?
check "31 (g): --add of a disk with ext4 on the whole disk: refused, the file system intact (was: wiped)" "[ $RC != 0 ] && echo \"\$OUT\" | grep -q 'ext2fs file system' && echo \"\$OUT\" | grep -q 'force wipes it' && [ \"\$(sudo blkid -o value -s LABEL $QE)\" = precious ]"
F1=$(sudo losetup -f --show $WQ/q3c/f1.img)
OUT=$($M /dev/$CN --add $F1 2>&1); RC=$?
check "31 (g): --add of a member of another AMD configuration's volume: refused, its metadata intact (was: wiped)" "[ $RC != 0 ] && echo \"\$OUT\" | grep -q 'member of 1 volume of another AMD RAID configuration' && $M -E $F1 2>/dev/null | grep -q '^\[qf\]'"
$M /dev/$CN --add $F1 --force >/dev/null 2>&1; RC=$?; sleep 1
check "31 (g): --add --force takes it: a global spare of this configuration" "[ $RC = 0 ] && grep -q \"\$(basename $F1)\" /proc/mdstat && ! $M -E $F1 2>/dev/null | grep -q '^\[qf\]' && $M -E $F1 2>/dev/null | grep -q '^\[q0\]'"
q3drop
# (h) MAN-B2: <container> --remove <a disk with no spare role> --add <new> in one command: --add went the mdmon way
q3mk 4 1G; set -- $QL
$M -C /dev/md/q3c -e amd -n 3 $1 $2 $3 --run >/dev/null 2>&1; CN=$(cont1)
$M -C /dev/md/q0 -e amd -l1 -n2 -z 64M $1 $2 --run >/dev/null 2>&1; sleep 1; waitrec 60
OUT=$($M /dev/$CN --remove $3 --add $4 2>&1); RC=$?; sleep 1
check "31 (h): <container> --remove <a disk with no spare role> --add <disk> in one command: added, a global spare (was: new_dev busy)" "[ $RC = 0 ] && echo \"\$OUT\" | grep -q 'added as an AMD global hot spare' && grep -q \"\$(basename $4)\[\" /proc/mdstat && $M -E $1 2>/dev/null | grep -q 'global spare'"
q3drop

# (i) CRE-B9: two volumes of one name (were assembled as <name>_0 and <name>_1): refused, as IMSM
q3mk 4 1G
$M -C /dev/md/q3c -e amd -n 4 $QL --run >/dev/null 2>&1; CN=$(cont1)
$M -C /dev/md/qn -l0 -n2 -z 64M /dev/$CN --run >/dev/null 2>&1; $M -S /dev/md/qn >/dev/null 2>&1
OUT=$($M -C /dev/md/qn -l0 -n2 -z 64M /dev/$CN --run 2>&1); RC=$?
check "31 (i): -C of a second volume named as the first: refused (was: both created)" "[ $RC != 0 ] && echo \"\$OUT\" | grep -q 'has the name qn already' && [ \$(q3vols) = 1 ]"
$M -C /dev/md/qm -l0 -n2 -z 64M /dev/$CN --run >/dev/null 2>&1
for m in $(mdof raid0); do $M -S /dev/$m >/dev/null 2>&1; done
OUT=$($M --update-subarray=1 --update=name -N qn /dev/$CN 2>&1); RC=$?
check "31 (i): --update-subarray=1 --update=name to the name of subarray-0: refused" "[ $RC != 0 ] && echo \"\$OUT\" | grep -q 'has the name qn already' && $M -E $Q1 2>/dev/null | grep -q '^\[qm\]'"
$M --update-subarray=1 --update=name -N qm /dev/$CN >/dev/null 2>&1; RC=$?
$M --update-subarray=1 --update=name -N qk /dev/$CN >/dev/null 2>&1; RC2=$?
check "31 (i): ... to its own name, to a new one: taken (passes on the base too)" "[ $RC = 0 ] && [ $RC2 = 0 ] && $M -E $Q1 2>/dev/null | grep -q '^\[qk\]'"
q3drop
# (j) W3: volumes of more than 8 disks: the BIOS menu and rcadm do not create them; -C without --force refused, with --force created
q3mk 10 1G
$M -C /dev/md/q3c -e amd -n 10 $QL --run >/dev/null 2>&1; CN=$(cont1)
OUT=$($M -C /dev/md/qz -l0 -n9 -z 64M /dev/$CN --run 2>&1); RC=$?
check "31 (k): -C RAID0 of 9 disks, container given: refused, said (was: created)" "[ $RC != 0 ] && echo \"\$OUT\" | grep -q 'volumes of at most 8 disks' && echo \"\$OUT\" | grep -q 'give --force' && [ \$(q3vols) = 0 ]"
OUT=$($M -C /dev/md/qz -l10 -n10 -z 64M /dev/$CN --run 2>&1); RC=$?
check "31 (k): -C RAID10 of 10 disks: refused" "[ $RC != 0 ] && echo \"\$OUT\" | grep -q 'volumes of at most 8 disks' && [ \$(q3vols) = 0 ]"
OUT=$($M -C /dev/md/qz -l0 -n8 -z 64M /dev/$CN --run 2>&1); RC=$?
check "31 (k): -C RAID0 of 8 disks: created, nothing said of the limit (passes on the base too)" "[ $RC = 0 ] && ! echo \"\$OUT\" | grep -q 'at most 8' && [ \$(q3vols) = 1 ]"
OUT=$($M -C /dev/md/qy -l0 -n9 -z 64M /dev/$CN --run --force 2>&1); RC=$?
check "31 (k): -C RAID0 of 9 disks --force: created, said once (passes on the base too, without the message)" "[ $RC = 0 ] && [ \$(echo \"\$OUT\" | grep -c 'creating one of 9 anyway') = 1 ] && [ \$(q3vols) = 2 ] && grep -q '^md.* : active raid0' /proc/mdstat"
q3drop
q3mk 9 1G
$M -C /dev/md/q3c -e amd -n 9 $QL --run >/dev/null 2>&1; G0=$(q3gen)
OUT=$($M -C /dev/md/qz -e amd -l linear -n9 -z 64M $QL --run 2>&1); RC=$?
check "31 (k): -e amd -l linear -n9 with the disks given: refused, nothing written" "[ $RC != 0 ] && echo \"\$OUT\" | grep -q 'volumes of at most 8 disks' && [ \$(q3vols) = 0 ] && [ \$(q3gen) = $G0 ]"
OUT=$($M -C /dev/md/qz -e amd -l0 -n9 -z 64M $QL --run --force 2>&1); RC=$?
check "31 (k): -e amd -l0 -n9 --force with the disks given: created" "[ $RC = 0 ] && [ \$(echo \"\$OUT\" | grep -c 'creating one of 9 anyway') = 1 ] && [ \$(q3vols) = 1 ]"
q3drop
# (k) -C of a container without --run: no md bitmap question (no level; a "y" broke the -C: "bitmaps not meaningful
# with level container", upstream e97c4e18); for a RAID1 volume it is asked
q3mk 2 1G
OUT=$(echo y | $M -C /dev/md/q3c -e amd -n 2 $QL 2>&1); RC=$?
check "31 (l): -C of a container, 'y' on stdin: created, no bitmap question (was: create failed)" "[ $RC = 0 ] && ! echo \"\$OUT\" | grep -q 'write-intent bitmap' && [ -n \"\$(cont1)\" ]"
OUT=$(echo n | $M -C /dev/md/qz -l1 -n2 -z 64M /dev/$(cont1) 2>&1); RC=$?
check "31 (l): -C of a RAID1 volume: the question is still asked (passes on the base too)" "[ $RC = 0 ] && echo \"\$OUT\" | grep -q 'write-intent bitmap'"
q3drop
rmdir $WQ/q3c 2>/dev/null
fi
# --- end of stage 31 ---

# --- stage 32: an invalid LD record, two disks with one DeviceID, a member of a non-redundant volume with a stale configuration (MON-B1), packet sections, a small disk ---
# Uses the helpers of the suite ($M, check, stopall,
# cont1, waitrec, mdof). Own images in $Q3R (default $WQ/q3r), 1 GiB sparse (no smaller: volumes
# start at 512 MiB). Needs $HLP/forge-fields.py (helpers/forge-fields.py: edits fields keeping the checksums valid;
# needed for (a), (f), (h)). Without the fixes these fail: (a) READ-A1 (e331909f), (b) READ-B1 (a34387f7), (h) READ-B2
# (e902c333), (i) READ-B3 (4775b468); (c)–(e) MON-B1 (22d06350), (f) V-R1 (051bdb5a: on 22d06350
# FAIL), (g) V-R3 (04ea50ac + 2b10559a: two FAIL on 22d06350 and 051bdb5a). The "mirror still ..."
# checks pass on the base too. 22 checks in all: on the base 17 FAIL, with all the fixes 22 ok.
if want 32; then
cd "${Q3TREE:-$MDADM_DIR}"
Q3R=${Q3R:-$WQ/q3r}
q3l() { sudo losetup -j $Q3R/$1.img | cut -d: -f1; }
q3sec() { $M -E $(q3l g0) 2>/dev/null | sed -n "/^\[$1\]/,/^\[/p"; }
q3gen() { $M -E $(q3l $1) 2>/dev/null | sed -n 's/^ *Generation : //p'; }
q3clean() { stopall; for l in $(sudo losetup -a | grep "$Q3R/" | cut -d: -f1); do sudo losetup -d $l; done; rm -f $Q3R/*.img $Q3R/*.bin; }
q3mk() { sudo mkdir -p $Q3R; sudo chown $(id -un) $Q3R; q3clean; for n in $(seq 0 $(($1 - 1))); do truncate -s 1G $Q3R/g$n.img; sudo losetup -f $Q3R/g$n.img; done; }
q3speed() { [ -e /proc/sys/dev/raid/speed_limit_max ] && echo $1 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null; }
q3save() { sudo dd if=$(q3l $1) of=$Q3R/$1.bin bs=512 skip=$((0x5000)) count=$((0x1000)) status=none; }	# metadata area: label, commit, ring
q3back() { sudo dd if=$Q3R/$1.bin of=$(q3l $1) bs=512 seek=$((0x5000)) conv=notrunc status=none; }
q3sum() { sudo md5sum /dev/$(mdof $1) 2>/dev/null | cut -c1-12; }
q3up() { local m=$(mdof $1); [ -n "$m" ] && grep -A1 "^$m " /proc/mdstat | grep -q "$2"; }
Q3SPEED=$(cat /proc/sys/dev/raid/speed_limit_max 2>/dev/null || echo 200000)	# md_mod not loaded yet: the kernel default

# (a) READ-A1: a configuration of a foreign controller (non-AMD serial), the second LD has ElementOffset = 0x7ff00000, checksums
# valid. A configuration write (here: a volume name) takes it over (amd_take_over) and must not follow the invalid record
q3mk 2
$M -C /dev/md/qc -e amd -n2 $(q3l g0) $(q3l g1) --run >/dev/null 2>&1
$M -C /dev/md/qz -e amd -l0 -n2 -z 32M $(q3l g0) $(q3l g1) --run >/dev/null 2>&1
$M -C /dev/md/qy -e amd -l0 -n2 -z 32M $(q3l g0) $(q3l g1) --run >/dev/null 2>&1
stopall
python3 ${Q3FUZZ:-$HLP/forge-fields.py} --set header.modifier_sn=0x102285900000 --set commit.last_online=0x102285900000 \
	--set ld1.element_offset=0x7ff00000 $Q3R/g0.img $Q3R/g1.img
$M -A /dev/md/qc -e amd $(q3l g0) $(q3l g1) >/dev/null 2>&1
$M --update-subarray=0 --update=name --name=qx /dev/$(cont1) >/dev/null 2>&1; Q3RC=$?
check "32 (a): a configuration write with an invalid LD record in a foreign packet does not crash (rc $Q3RC)" \
	"[ $Q3RC = 0 ] && $M -E $(q3l g0) | grep -q '^\[qx\]'"
q3clean

# (b) READ-B1: a stale copy of a member (dd to another disk) with the same DeviceID: the member is the disk with the newer
# commit, whichever of the two is read first, and this is reported
q3mk 2
$M -C /dev/md/qc -e amd -n2 $(q3l g0) $(q3l g1) --run >/dev/null 2>&1
$M -C /dev/md/qv -e amd -l1 -n2 -z 64M $(q3l g0) $(q3l g1) --run >/dev/null 2>&1; waitrec; sleep 3
stopall
cp --sparse=always $Q3R/g0.img $Q3R/gc.img
$M -A /dev/md/qc -e amd $(q3l g0) $(q3l g1) >/dev/null 2>&1
$M --update-subarray=0 --update=name --name=qw /dev/$(cont1) >/dev/null 2>&1
stopall
sudo losetup -f $Q3R/gc.img
$M -A /dev/md/qc -e amd $(q3l gc) $(q3l g0) $(q3l g1) >$Q3R/b.bin 2>&1; $M -I /dev/$(cont1) >>$Q3R/b.bin 2>&1; sleep 2
check "32 (b): of two disks with one DeviceID the stale copy is named as not used" \
	"grep -q \"$(q3l gc) is not used: it has the DeviceID of $(q3l g0)\" $Q3R/b.bin"
check "32 (b): the mirror starts on both of its own disks" \
	"q3up raid1 '\[UU\]' && ! ls /sys/block/$(mdof raid1)/md/ | grep -q dev-$(basename $(q3l gc))"
q3clean

# (c) MON-B1, experiment E8: power lost between commit blocks: g0 and g2 got configuration N+1, g1 and g3 kept
# N. The RAID0 (g2+g3) cannot run without a member: g3 is taken with its older generation, the data the same. The mirror (g0+g1)
# behaves as before: does not start without --run, with --run runs without g1, which is recorded offline and rebuilt
q3mk 4
$M -C /dev/md/qc -e amd -n4 $(q3l g0) $(q3l g1) $(q3l g2) $(q3l g3) --run >/dev/null 2>&1
$M -C /dev/md/qz -e amd -l0 -n2 -z 32M $(q3l g2) $(q3l g3) --run >/dev/null 2>&1
$M -C /dev/md/qv -e amd -l1 -n2 -z 64M $(q3l g0) $(q3l g1) --run >/dev/null 2>&1; waitrec; sleep 3
sudo dd if=/dev/urandom of=/dev/$(mdof raid0) bs=1M count=8 oflag=direct status=none
Q3S0=$(q3sum raid0)
stopall
q3save g1; q3save g3
$M -A /dev/md/qc -e amd $(q3l g0) $(q3l g1) $(q3l g2) $(q3l g3) >/dev/null 2>&1
$M --update-subarray=1 --update=name --name=qw /dev/$(cont1) >/dev/null 2>&1
stopall
q3back g1; q3back g3
sudo dmesg -C
$M -A /dev/md/qc -e amd $(q3l g0) $(q3l g1) $(q3l g2) $(q3l g3) >/dev/null 2>&1; $M -I /dev/$(cont1) >/dev/null 2>&1; sleep 2
check "32 (c): a RAID0 whose member missed a configuration starts, its data intact (generations $(q3gen g2), $(q3gen g3))" \
	"q3up raid0 'active raid0' && [ \"\$(q3sum raid0)\" = $Q3S0 ]"
check "32 (c): the mirror with a stale member still waits for --run" "! grep -q 'active raid1' /proc/mdstat"
$M -IR /dev/$(cont1) >/dev/null 2>&1; sleep 3; waitrec; sleep 3
check "32 (c): with --run the mirror's stale member is recorded as offline and rebuilt" \
	"sudo dmesg | grep -q 'member 1 .* is missing, recorded as offline' && q3up raid1 '\[UU\]' && q3sec qw | grep -q 'last 0x5358, state 0xa1a6'"
check "32 (c): the RAID0 member has the live configuration again (generations $(q3gen g2), $(q3gen g3))" \
	"[ -n \"$(q3gen g3)\" ] && [ \"$(q3gen g3)\" = \"$(q3gen g2)\" ] && [ \"\$(q3sum raid0)\" = $Q3S0 ]"
q3clean

# (d) MON-B1, experiment E9: a RAID0 member (g3) is late. The end of the mirror's initialization is recorded
# without it (no point waiting for a member of a non-redundant volume that is not running), a mirror member's failure too; g3,
# back with its older generation, is taken into the RAID0, and mdmon brings it up to the live configuration
q3mk 4
$M -C /dev/md/qc -e amd -n4 $(q3l g0) $(q3l g1) $(q3l g2) $(q3l g3) --run >/dev/null 2>&1
$M -C /dev/md/qz -e amd -l0 -n2 -z 32M $(q3l g2) $(q3l g3) --run >/dev/null 2>&1
sudo dd if=/dev/urandom of=/dev/$(mdof raid0) bs=1M count=8 oflag=direct status=none
Q3S0=$(q3sum raid0)
q3speed 2000
$M -C /dev/md/qv -e amd -l1 -n2 -z 64M $(q3l g0) $(q3l g1) --run >/dev/null 2>&1; sleep 3
stopall; sudo losetup -d $(q3l g3); q3speed $Q3SPEED
$M -A /dev/md/qc -e amd $(q3l g0) $(q3l g1) $(q3l g2) >/dev/null 2>&1; $M -I /dev/$(cont1) >/dev/null 2>&1; sleep 2; waitrec; sleep 5
check "32 (d): the end of an initialization is recorded with a member of a RAID0 that is not running gone" \
	"q3sec qv | grep -q 'State : 0x200 (normal)' && q3sec qv | grep -q 'last 0x5355, state 0xa1a6'"
echo faulty | sudo tee /sys/block/$(mdof raid1)/md/dev-$(basename $(q3l g1))/state >/dev/null; sleep 3
sudo losetup -f $Q3R/g3.img; sleep 1
$M -I $(q3l g3) >/dev/null 2>&1; sleep 3
check "32 (d): the RAID0 starts when its late member comes, its data intact" \
	"q3up raid0 'active raid0' && [ \"\$(q3sum raid0)\" = $Q3S0 ]"
check "32 (d): mdmon gives the late member the live configuration (generations $(q3gen g2), $(q3gen g3))" \
	"[ -n \"$(q3gen g3)\" ] && [ \"$(q3gen g3)\" = \"$(q3gen g2)\" ]"
stopall
$M -A /dev/md/qc -e amd $(q3l g0) $(q3l g1) $(q3l g2) $(q3l g3) >/dev/null 2>&1; $M -IR /dev/$(cont1) >/dev/null 2>&1; sleep 3
check "32 (d): after the next assembly the RAID0 runs, the mirror runs without its failed member" \
	"q3up raid0 'active raid0' && [ \"\$(q3sum raid0)\" = $Q3S0 ] && q3up raid1 '\[U_\]'"
q3clean

# (e) MON-B1: one disk (g1) holds an element of the mirror (g0+g1) and one of the RAID0 (g1+g2) and missed a configuration.
# For the RAID0 it is a member; for the mirror it is stale, as before: it gets the live configuration no earlier than
# its mirror element is recorded offline (else the stale mirror copy would pass for a fresh one), then a rebuild
q3mk 3
$M -C /dev/md/qc -e amd -n3 $(q3l g0) $(q3l g1) $(q3l g2) --run >/dev/null 2>&1
$M -C /dev/md/qv -e amd -l1 -n2 -z 64M $(q3l g0) $(q3l g1) --run >/dev/null 2>&1
$M -C /dev/md/qz -e amd -l0 -n2 -z 32M $(q3l g1) $(q3l g2) --run >/dev/null 2>&1; waitrec; sleep 3
sudo dd if=/dev/urandom of=/dev/$(mdof raid0) bs=1M count=8 oflag=direct status=none
sudo dd if=/dev/urandom of=/dev/$(mdof raid1) bs=1M count=8 oflag=direct status=none
Q3S0=$(q3sum raid0); Q3S1=$(q3sum raid1)
stopall
q3save g1
$M -A /dev/md/qc -e amd $(q3l g0) $(q3l g1) $(q3l g2) >/dev/null 2>&1
$M --update-subarray=1 --update=name --name=qy /dev/$(cont1) >/dev/null 2>&1
stopall
q3back g1
sudo dmesg -C
$M -A /dev/md/qc -e amd $(q3l g0) $(q3l g1) $(q3l g2) >/dev/null 2>&1; $M -I /dev/$(cont1) >/dev/null 2>&1; sleep 2
check "32 (e): the RAID0 starts with the disk that is stale for the mirror, its data intact" \
	"q3up raid0 'active raid0' && [ \"\$(q3sum raid0)\" = $Q3S0 ] && ! grep -q 'active raid1' /proc/mdstat"
check "32 (e): that disk keeps its older generation while the mirror has its element in service ($(q3gen g1) < $(q3gen g0))" \
	"[ -n \"$(q3gen g1)\" ] && [ \"$(q3gen g1)\" -lt \"$(q3gen g0)\" ]"
$M -IR /dev/$(cont1) >/dev/null 2>&1; sleep 3; waitrec; sleep 3
check "32 (e): with --run the mirror records it as offline and rebuilds it, both volumes keep their data" \
	"sudo dmesg | grep -q 'member 1 .* is missing, recorded as offline' && q3up raid1 '\[UU\]' && q3sec qv | grep -q 'last 0x5358, state 0xa1a6' && [ \"\$(q3sum raid1)\" = $Q3S1 ] && [ \"\$(q3sum raid0)\" = $Q3S0 ]"
check "32 (e): the disk has the live configuration then (generations $(q3gen g0), $(q3gen g1))" \
	"[ \"$(q3gen g1)\" = \"$(q3gen g0)\" ]"
q3clean

# (f) MON-B1, a fork of history (V-R1): disk g1 is stale and its own packet has no volume qz (as if the disk had been taken
# to another machine, the volume deleted there and another created in its place: here another volume ID in g1's packet, checksums valid).
# Such a disk is not taken into the RAID0 and gets no live configuration: writes to the volume would land on foreign data
q3mk 2
$M -C /dev/md/qc -e amd -n2 $(q3l g0) $(q3l g1) --run >/dev/null 2>&1
$M -C /dev/md/qz -e amd -l0 -n2 -z 32M $(q3l g0) $(q3l g1) --run >/dev/null 2>&1
stopall
q3save g1
$M -A /dev/md/qc -e amd $(q3l g0) $(q3l g1) >/dev/null 2>&1
$M --update-subarray=0 --update=name --name=qy /dev/$(cont1) >/dev/null 2>&1
stopall
q3back g1
python3 ${Q3FUZZ:-$HLP/forge-fields.py} --set ld0.id=0x00001111deadbeef $Q3R/g1.img
Q3G=$(q3gen g1)
$M -A /dev/md/qc -e amd $(q3l g0) $(q3l g1) >/dev/null 2>&1; $M -I /dev/$(cont1) >/dev/null 2>&1; sleep 2
check "32 (f): a disk whose own packet has another volume in that place is no member of the RAID0 (generations $(q3gen g0), $Q3G)" \
	"[ -n \"$Q3G\" ] && [ \"$Q3G\" -lt \"$(q3gen g0)\" ] && ! q3up raid0 'active raid0'"
check "32 (f): and it keeps its own configuration (generation $(q3gen g1))" "[ \"$(q3gen g1)\" = \"$Q3G\" ]"
q3clean

# (g) V-R3: only a RAID0 in the container, so no mdmon. To a stale member taken into the volume mdadm writes the live
# configuration at assembly (else the BIOS and the AMD driver would see the stale disk until the first write)
q3mk 2
$M -C /dev/md/qc -e amd -n2 $(q3l g0) $(q3l g1) --run >/dev/null 2>&1
$M -C /dev/md/qz -e amd -l0 -n2 -z 32M $(q3l g0) $(q3l g1) --run >/dev/null 2>&1
sudo dd if=/dev/urandom of=/dev/$(mdof raid0) bs=1M count=8 oflag=direct status=none
Q3S0=$(q3sum raid0)
stopall
q3save g1
$M -A /dev/md/qc -e amd $(q3l g0) $(q3l g1) >/dev/null 2>&1
$M --update-subarray=0 --update=name --name=qy /dev/$(cont1) >/dev/null 2>&1
stopall
q3back g1
Q3G=$(q3gen g1)
# first read-only (-A -o of the volumes from the container; -I has no such option): nothing is written
$M -A /dev/md/qc -e amd $(q3l g0) $(q3l g1) >/dev/null 2>&1; $M -A -o /dev/md/qro /dev/$(cont1) >/dev/null 2>&1; sleep 2
check "32 (g): started read-only, the RAID0 runs and the stale member is not written to (generation $(q3gen g1))" \
	"q3up raid0 'raid0' && [ \"\$(cat /sys/block/\$(mdof raid0)/md/array_state)\" = readonly ] && [ \"$(q3gen g1)\" = \"$Q3G\" ] && [ \"\$(q3sum raid0)\" = $Q3S0 ]"
stopall
$M -A /dev/md/qc -e amd $(q3l g0) $(q3l g1) >/dev/null 2>&1; $M -I /dev/$(cont1) >/dev/null 2>&1; sleep 2
# without V-R3 (VR3 unset), as IMSM: assembly without mdmon writes nothing to a stale member
Q3VR3="[ \"$(q3gen g1)\" = \"$(q3gen g0)\" ]"; [ "${VR3:-}" = 1 ] || Q3VR3="[ \"$(q3gen g1)\" = \"$Q3G\" ]"
check "32 (g): started read-write without mdmon, the RAID0 runs, its data intact (generations $(q3gen g0), $(q3gen g1), was $Q3G; VR3=${VR3:-0})" \
	"q3up raid0 'active raid0' && ! pgrep -x mdmon >/dev/null && $Q3VR3 && [ \"\$(q3sum raid0)\" = $Q3S0 ]"
stopall
$M -A /dev/md/qc -e amd $(q3l g0) $(q3l g1) >/dev/null 2>&1; $M -I /dev/$(cont1) >/dev/null 2>&1; sleep 2
check "32 (g): the next assembly runs the RAID0 again, the data intact" \
	"q3up raid0 'active raid0' && [ \"\$(q3sum raid0)\" = $Q3S0 ] && $Q3VR3"
q3clean

# (h) READ-B2: the controller section (25BE) ends past the packet, checksums valid. Such a packet is not read, like
# any corrupt one (else mdmon could write into it neither a spare nor a rebuild: amd_packet_insert)
q3mk 2
$M -C /dev/md/qc -e amd -n2 $(q3l g0) $(q3l g1) --run >/dev/null 2>&1
$M -C /dev/md/qz -e amd -l0 -n2 -z 32M $(q3l g0) $(q3l g1) --run >/dev/null 2>&1
stopall
python3 ${Q3FUZZ:-$HLP/forge-fields.py} --set header.ctrl_offset=0x400 --set header.ctrl_size=0x100000 $Q3R/g0.img
check "32 (h): a packet whose controller section ends past it is not read" \
	"$M -E $(q3l g0) 2>/dev/null | grep -q 'Configuration : unreadable' && $M -E $(q3l g1) 2>/dev/null | grep -q '^\[qz\]'"
q3clean

# (i) READ-B3: a whole disk under 552 MiB: a message about the size, not "needs a whole disk"
q3mk 1
truncate -s 300M $Q3R/gs.img; sudo losetup -f $Q3R/gs.img
check "32 (i): a disk too small for AMD RAID is refused with its size and the size needed" \
	"$M -C /dev/md/qc -e amd -n2 $(q3l g0) $(q3l gs) --run 2>&1 | grep -q 'is too small for AMD RAID: 300 MiB, at least 552 MiB are needed'"
q3clean
fi
# --- end of stage 32 ---

# --- stage 33: ST-A1: volume element extents not where AMD puts them ---
# Uses the helpers of the suite ($M and check).
# No md or loop needed: mdadm -E reads the image file. Needs $HLP/forge-fields.py (helpers/forge-fields.py:
# edits fields keeping the checksums valid). Without the ST-A1 fix (a972ed44) check (a) fails: a volume with
# AllocatedSpace = 0 is listed "read-write", mdmon would write its transform log and bitmaps to LBA 0…0x100.
# Check (b) passes on the base too (the volume unchanged): a guard against a false refusal.
# Checked with the same commands on the ASRock dump image: base FAIL/ok, with the fix ok/ok.
if want 33; then
cd "${Q3TREE:-$MDADM_DIR}"
cp --sparse=always $IMG/asrock-nvme1n1.img $IMG/st-a1.img
check "33 (b): the extents of the ASRock RAID0 are AMD's" \
	"$M -E $IMG/st-a1.img | grep -q 'md support : read-write'"
python3 ${Q3FUZZ:-$HLP/forge-fields.py} --set ld0.el0.alloc_offset=0 $IMG/st-a1.img
check "33 (a): a volume with an element extent at LBA 0 is not assembled" \
	"$M -E $IMG/st-a1.img | grep -q 'md support : none - member extents are not where AMD puts them'"
rm -f $IMG/st-a1.img
fi
# --- end of stage 33 ---

# --- stage 34: quality review (LATE-*): md bitmap placement, two broken Legacy records ---
# Uses the helpers of the suite ($M, check, stopall).
# Alone: STAGES=34 ./run.sh <tree>; single blocks with Q3L (see lwant below).
# Needs $TOOLS/amdraid_dump.py, $HLP/forge-late.py and (block B3)
# $FIXT/2026-11-02-msi-x870e-hdd. Images in $WK/q3-late (sparse; the volumes are not written).
# The configurations are forged (forge-late.py): on the base e2368f9f all four blocks FAIL.
if want 34; then
LD=$WK/q3-late
sudo modprobe md_mod
ldown() { stopall; for l in $(sudo losetup -a | grep "$LD/" | cut -d: -f1); do sudo losetup -d $l; done; }
# lset [-C options of the first volume]: a container on three 1 GiB images, RAID1 q3v (L0+L1) and q3w (L1+L2) of 128 MiB; all
# stopped. lcont: assemble the container alone (no volumes started: no mdmon, mdadm writes the changes itself).
lset() {
	ldown; mkdir -p $LD; rm -f $LD/*.img; for n in 0 1 2; do truncate -s 1G $LD/l$n.img; done
	L0=$(sudo losetup -f --show $LD/l0.img); L1=$(sudo losetup -f --show $LD/l1.img); L2=$(sudo losetup -f --show $LD/l2.img)
	echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
	$M -C /dev/md/amdq3l -e amd -n 3 $L0 $L1 $L2 --run >/dev/null 2>&1
	$M -C /dev/md/q3v -e amd -l1 -n2 -z 128M "$@" $L0 $L1 --run >/dev/null 2>&1; sleep 2; waitrec
	$M -C /dev/md/q3w -e amd -l1 -n2 -z 128M $L1 $L2 --run >/dev/null 2>&1; sleep 2; waitrec; sleep 6; stopall
}
lcont() { $M -A /dev/md/amdq3l $L0 $L1 $L2 >/dev/null 2>&1; sleep 1; }
# lfill <disk> <LBA> <sectors>: fill with 'Z'; lsame: they are still there
lfill() { tr '\0' 'Z' < /dev/zero | sudo dd of=$1 bs=512 seek=$2 count=$3 oflag=direct status=none 2>/dev/null; }
lsame() { [ "$(sudo dd if=$1 bs=512 skip=$2 count=$3 iflag=direct status=none | tr -d 'Z' | wc -c)" = 0 ]; }
# single blocks: STAGES=34 Q3L=B1 ./run.sh <tree>
lwant() { case " ${Q3L:-B1 A2 A4 B3 D5} " in *" $1 "*) return 0;; esac; return 1; }

# LATE-B1: the md bitmap is in [AllocatedSpace + 0x100, + 0x600) of each element; AMD data begin 0x5000 or
# 0x800 sectors from the element start, but the offsets are read from disk. Here q3v data begin at 0x200 sectors: the bitmap
# area lies in the volume data. --update=bitmap must refuse without writing anything.
if lwant B1; then
lset
LA=$(sudo python3 $HLP/forge-late.py gap q3v 0x200 $L0 $L1 $L2 | grep -o 'LBA [0-9]*' | head -1 | cut -d' ' -f2)
lfill $L0 $LA 1280; lfill $L1 $LA 1280; lcont
OUT=$($M --update-subarray=0 --update=bitmap /dev/md/amdq3l 2>&1); RC=$?
check "34 (B1): no md bitmap for a volume whose data begin inside the bitmap area (rc $RC): refused, nothing written" "[ -n \"$LA\" ] && [ $RC != 0 ] && echo \"\$OUT\" | grep -q 'no room for it' && lsame $L0 $LA 1280 && lsame $L1 $LA 1280"
# an assembled volume with such a layout and an md bitmap header on disk does not take the bitmap (amd_mdbm_lba is 0)
fi

# LATE-A2: the L1 element of q3v is offline and the AMD driver gave its extent to q3w (rcblob BuildFreeList): the md bitmap
# area of that element lies in q3w data. --update=no-bitmap wipes the headers on all q3v elements; this sector
# must not be touched.
if lwant A2; then
lset
LA=$(sudo python3 $HLP/forge-late.py taken q3v q3w $L0 $L1 $L2 | grep -o 'LBA [0-9]*' | head -1 | cut -d' ' -f2)
lfill $L1 $LA 1; lcont
OUT=$($M --update-subarray=0 --update=no-bitmap /dev/md/amdq3l 2>&1); RC=$?
check "34 (A2): --update=no-bitmap (rc $RC) leaves the extent of an offline member alone once another volume holds it" "[ -n \"$LA\" ] && [ $RC = 0 ] && lsame $L1 $LA 1"
fi

# LATE-A4: a volume so large that md bitmap bits do not fit the area even at 1 GiB per bit: --update=bitmap divided by 0
if lwant A4; then
lset
sudo python3 $HLP/forge-late.py huge q3v $L0 $L1 $L2 >/dev/null; lcont
OUT=$($M --update-subarray=0 --update=bitmap /dev/md/amdq3l 2>&1); RC=$?
check "34 (A4): --update=bitmap of a volume too large for an md bitmap is refused (rc $RC), no crash" "[ $RC = 2 ] && echo \"\$OUT\" | grep -q 'can have no md bitmap: it is too large'"
fi
ldown; rm -f $LD/*.img

# LATE-B3: two Legacy disks of one capacity, each with a broken Legacy record of its own (the MSI X870E dump, configuration
# 19; the second disk and the owner of the second record forged). Both are repaired, none is dropped.
if lwant B3; then
HD=$FIXT/2026-11-02-msi-x870e-hdd; HS="WX41A685FR98 WES1KE09 JR10044M28WJGM WX61A68KYK45"
mkdir -p $LD/l && rm -f $LD/l/*.img
HL=""; for s in $HS; do
	truncate -s $((1953525168 * 512)) $LD/l/$s.img
	xz -dc $HD/$s-lba0-6000.img.xz | dd of=$LD/l/$s.img conv=notrunc status=none
	HL="$HL $(sudo losetup -f --show $LD/l/$s.img)"
done
sudo python3 $HLP/forge-late.py legacy2 $HL >/dev/null; LF=$?
lcfg() { python3 $TOOLS/amdraid_dump.py $LD/l/$1.img --brief 2>/dev/null; }
H1=$(echo $HL | cut -d' ' -f1)
check "34 (B3): two Legacy disks of one capacity, a broken record each: examine counts 2" "[ $LF = 0 ] && $M -E $H1 | grep -q 'Legacy records : 2 broken'"
for d in $HL; do $M -I $d >/dev/null 2>&1; done; sleep 4
check "34 (B3): mdmon repaired both, each on its own disk, none dropped" "(for s in $HS; do lcfg \$s | grep -q 'конфигурация 20' && lcfg \$s | grep -q '7d730af340a81267 LEGACY NORMAL .*\[1:1267\]' && lcfg \$s | grep -q '7d730af340a8beef LEGACY NORMAL .*\[6:beef\]' && [ \$(lcfg \$s | grep -c 'Array .* LEGACY') = 2 ] || exit 1; done)"
stopall
check "34 (B3): repaired: examine is quiet" "! $M -E $H1 | grep -q 'Legacy records'"
for d in $HL; do sudo losetup -d $d; done; rm -rf $LD/l
fi
# LATE-D5: md dropped the bitmap since the spare has no room at its LBA (as stage 17d: RAID1 q3b on d0+d3 after a RAID0 of the same
# length on each; a 1.2 GiB spare). After the rebuild the q3b members start at different LBAs: --update=bitmap will not
# bring the bitmap back (the man page promised otherwise): refused with the reason.
if lwant D5; then
ldown; mkdir -p $LD; rm -f $LD/*.img; DL=""
for i in d0 d1 d2 d3; do truncate -s 4G $LD/$i.img; DL="$DL $(sudo losetup -f --show $LD/$i.img)"; done
set -- $DL
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
$M -C /dev/md/amdq3l -e amd -n 4 $DL --run >/dev/null 2>&1
$M -C /dev/md/q3z -e amd -l0 -n2 -z 1G $1 $2 --run >/dev/null 2>&1
$M -C /dev/md/q3y -e amd -l0 -n2 -z 1G $4 $3 --run >/dev/null 2>&1
$M -C /dev/md/q3b -e amd -l1 -n2 -z 256M --bitmap=internal $1 $4 --run >/dev/null 2>&1; sleep 2; waitrec
V=$(mdof raid1); P0=$(cat /sys/block/$V/md/consistency_policy)
truncate -s 1288490496 $LD/s.img; DS=$(sudo losetup -f --show $LD/s.img)
$M /dev/$(cont1) --add $DS >/dev/null 2>&1; sleep 1
$M /dev/$V --fail $4 >/dev/null 2>&1; sleep 3; waitrec; sleep 3
P1=$(cat /sys/block/$V/md/consistency_policy); U=$(grep -A1 "^$V " /proc/mdstat | grep -c '\[UU\]')
stopall; $M -A /dev/md/amdq3l $DL $DS >/dev/null 2>&1; sleep 1
OUT=$($M --update-subarray=2 --update=bitmap /dev/md/amdq3l 2>&1); RC=$?
check "34 (D5): md dropped the bitmap for a spare with no room at its LBA ($P0 -> $P1, rebuilt: $U): --update=bitmap cannot bring it back (rc $RC)" "[ '$P0' = bitmap ] && [ '$P1' = resync ] && [ $U = 1 ] && [ $RC = 2 ] && echo \"\$OUT\" | grep -q 'can have no md bitmap: its members do not start at one LBA'"
ldown; rm -f $LD/*.img
fi
rmdir $LD 2>/dev/null
fi
# --- end of stage 34 ---

# --- stage 35: quality review (REB-A*): a rebuild onto a late target, an offline member's extent taken ---
# Uses the helpers of the suite ($M, check, stopall,
# cont1, mdof, waitrec, tlogf). Alone: STAGES=35 ./run.sh <tree>; single blocks with REB35 (see qwant below).
# Needs $HLP/forge-rebuild.py (block A3).
# Images in $WK/q3r (not $WQ: the volume is written, btrfs compression is no use).
if want 35; then
QD=$WK/q3r
sudo modprobe md_mod
qgen() { $M -E $1 2>/dev/null | awk '/Generation/{print $NF; exit}'; }
qtl() { tlogf $1 0x100000 | cut -d' ' -f2,3; }
qdown() { stopall; for l in $(sudo losetup -a | grep "$QD/" | cut -d: -f1); do sudo losetup -d $l; done; }
# qset <slot>: RAID1 of 256 MiB on q0+q1 (the volume filled with 0x5a), global spare q2; the slot's member failed, the rebuild
# onto q2 stopped midway (the log at mark QP); QS is the source disk, QT the target
qset() {
	qdown; mkdir -p $QD; rm -f $QD/*.img; for n in 0 1 2; do truncate -s 1G $QD/q$n.img; done
	Q0=$(sudo losetup -f --show $QD/q0.img); Q1=$(sudo losetup -f --show $QD/q1.img); QT=$(sudo losetup -f --show $QD/q2.img)
	echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
	$M -C /dev/md/amdq3 -e amd -n 2 $Q0 $Q1 --run >/dev/null 2>&1
	$M -C /dev/md/q3v -e amd -l1 -n2 -z 256M $Q0 $Q1 --run >/dev/null 2>&1; sleep 2; waitrec
	QC=$(cont1); QM=$(mdof raid1)
	tr '\0' 'Z' < /dev/zero | sudo dd of=/dev/$QM bs=1M count=256 oflag=direct status=none 2>/dev/null; sleep 6
	$M /dev/$QC --add $QT >/dev/null 2>&1; sleep 2
	echo 3000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
	if [ $1 = 0 ]; then QF=$Q0; QS=$Q1; else QF=$Q1; QS=$Q0; fi
	$M /dev/$QM --fail $QF >/dev/null 2>&1; sleep 8; stopall
	echo 1000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
	QP=$(qtl $QS | cut -d' ' -f1)
}
# the volume without the target: -I of the source and of the failed one (stale: not a member), -IRs
# (the volume is active at once; wait only until mdmon takes it)
qstart() { $M -I $QS >/dev/null 2>&1; $M -I $QF >/dev/null 2>&1; $M -IRs >/dev/null 2>&1; QM=$(mdof raid1); QC=$(cont1)
	for i in $(seq 1 50); do [ "$(cat /sys/block/$QM/md/array_state)" = active ] && break; sleep 0.1; done; }
head -c 4M /dev/urandom > $TMPW/q3r-b.bin
# single blocks: STAGES=35 REB35=A3 ./run.sh <tree> (not Q3R: that is the image directory of stage 32)
qwant() { case " ${REB35:-A1 A2 A3} " in *" $1 "*) return 0;; esac; return 1; }

# qend <what>: the target came; wait for the end, md check; the data written without the target are on both mirrors
qend() {
	echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null; sleep 2; waitrec; sleep 3
	echo check | sudo tee /sys/block/$QM/md/sync_action >/dev/null; sleep 1; waitrec
	check "35 ($1): rebuilt, md check clean, what md wrote without the target is on both mirrors" "grep -A2 \"^$QM \" /proc/mdstat | grep -q '\[2/2\] \[UU\]' && [ \$(cat /sys/block/$QM/md/mismatch_cnt) = 0 ] && cmp -s $TMPW/q3r-b.bin <(sudo dd if=$QS bs=512 skip=\$(cat /sys/block/$QM/md/dev-\$(basename $QS)/offset) count=8192 iflag=direct status=none) && cmp -s $TMPW/q3r-b.bin <(sudo dd if=$QT bs=512 skip=\$(cat /sys/block/$QM/md/dev-\$(basename $QT)/offset) count=8192 iflag=direct status=none)"
}

# REB-A1: the target comes to a running clean volume; the manager has read the log mark (t0) and queries the disk
# (IDENTIFY, here delayed 4 s by strace: the manager's second ioctl, the first is the disk size at ATTACH); meanwhile
# md writes to the volume for the first time (write_pending -> monitor: log from 0). The target must be copied from 0.
if qwant A1; then
qset 1; qstart
sudo strace -f -p $(pgrep -x mdmon) -e trace=ioctl -e inject=ioctl:delay_enter=4000000:when=2 -o /dev/null 2>/dev/null &
sleep 1; $M -I $QT >/dev/null 2>&1 & QJ=$!; sleep 1.5
sudo dd if=$TMPW/q3r-b.bin of=/dev/$QM bs=1M oflag=direct status=none; wait $QJ; sleep 4
sudo pkill -x strace; sleep 1
QR=$(cut -d' ' -f1 /sys/block/$QM/md/sync_completed)
check "35 (A1): md wrote while the manager asked the late target's disk: copied from 0 (mark $QP, md at $QR)" "[ \"\$(qtl $QS | cut -d' ' -f1)\" -lt $QP ] && [ $QR -lt $QP ]"
qend A1
fi

# REB-A2: mdmon replaced (--takeover: so it is restarted after the initramfs) while the volume runs without the target and has not
# written yet. The new mdmon must know there is no target: an md write puts the log at 0, a target that comes is copied from 0.
if qwant A2; then
qset 1; qstart
sudo -E ./mdmon --takeover $QC; sleep 3
sudo dd if=$TMPW/q3r-b.bin of=/dev/$QM bs=1M oflag=direct status=none; sleep 7
check "35 (A2): mdmon taken over, md wrote without the target: the log goes to 0 (was $QP)" "[ \"\$(qtl $QS)\" = '0 1' ]"
$M -I $QT >/dev/null 2>&1; sleep 3
check "35 (A2): the target comes: copied from 0" "[ \$(cut -d' ' -f1 /sys/block/$QM/md/sync_completed) -lt $QP ]"
qend A2
fi

# REB-A3: the slot's own disk is back (element offline, 0x30), but its extent already belongs to another volume: the AMD driver
# counts the extent of a member found offline as free (rcblob BuildFreeList). A rebuild "in place" would land on
# that volume's data. The configuration is forged (helpers/forge-rebuild.py): volumes q3v (q0+q1) and q3w (q1+q2), q1 in q3v
# offline; without --overlap the extents differ (control: the rebuild in place runs), with --overlap the q1 extent is shared.
# (1 GiB images: 512 MiB for volumes, two of 128 MiB). qforge <option>: QM is q3v after assembly, QFR the forge exit code
qforge() {
	qdown; mkdir -p $QD; rm -f $QD/*.img; for n in 0 1 2; do truncate -s 1G $QD/q$n.img; done
	Q0=$(sudo losetup -f --show $QD/q0.img); Q1=$(sudo losetup -f --show $QD/q1.img); Q2=$(sudo losetup -f --show $QD/q2.img)
	echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
	$M -C /dev/md/amdq3 -e amd -n 3 $Q0 $Q1 $Q2 --run >/dev/null 2>&1
	$M -C /dev/md/q3v -e amd -l1 -n2 -z 128M $Q0 $Q1 --run >/dev/null 2>&1; sleep 2; waitrec
	$M -C /dev/md/q3w -e amd -l1 -n2 -z 128M $Q1 $Q2 --run >/dev/null 2>&1; sleep 2; waitrec; sleep 6; stopall
	sudo python3 $HLP/forge-rebuild.py $1 $Q0 $Q1 $Q2 >/dev/null; QFR=$?
	for d in $Q0 $Q1 $Q2; do $M -I $d >/dev/null 2>&1; done; $M -IRs >/dev/null 2>&1; sleep 8
	QM=; for m in $(mdof raid1); do [ -e /sys/block/$m/md/dev-$(basename $Q0) ] && QM=$m; done
}
if qwant A3; then
qforge ""; waitrec
check "35 (A3): an offline member whose extent is its own is rebuilt in place" "[ $QFR = 0 ] && [ -n \"$QM\" ] && grep -A2 \"^$QM \" /proc/mdstat | grep -q '\[2/2\] \[UU\]' && [ -e /sys/block/$QM/md/dev-$(basename $Q1) ]"
qforge --overlap
check "35 (A3): an offline member whose extent another volume holds is not rebuilt in place" "[ $QFR = 0 ] && [ -n \"$QM\" ] && grep -A2 \"^$QM \" /proc/mdstat | grep -q '\[2/1\] \[U_\]' && [ ! -e /sys/block/$QM/md/dev-$(basename $Q1) ]"
fi

qdown; rm -rf $QD $TMPW/q3r-b.bin
fi
# --- end of stage 35 ---

# --- stage 36: a rebuild mdmon did not record or did not see ---
# Uses the helpers of the suite ($M, check, stopall,
# cont1, mdof, waitrec). Alone: STAGES=36 ./run.sh <tree>.
# Images in $WK/q3mr, 1 GiB sparse. Blocks: Q3MR (default all): B6 B5 B5e B4.
# On the base (3303159e): B6 passes (closed by MON-A4), B5, B5e and B4 fail; with the fixes all ok.
if want 36; then
cd "$MDADM_DIR"
QD=$WK/q3mr
sudo modprobe md_mod
qmwant() { case " ${Q3MR:-B6 B5 B5e B4} " in *" $1 "*) return 0;; esac; return 1; }
qml() { sudo losetup -j $QD/$1.img | cut -d: -f1; }
qmsec() { $M -E $(qml g0) 2>/dev/null | sed -n '/^\[qmv\]/,/^\[/p'; }
# qmspeed <KiB/s>: md sync speed limit (and the minimum not above it: else md does not keep it)
qmspeed() { local m=$(( $1 < 1000 ? $1 : 1000 ))
	echo $m | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null; echo $1 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null; }
qmclean() { stopall; for l in $(sudo losetup -a | grep "$QD/" | cut -d: -f1); do sudo losetup -d $l; done; rm -f $QD/*.img; }
# qmk <disks> <in container>: g0…; container qmc of the first <in container>, RAID1 qmv of 128 MiB on g0+g1 (in sync)
qmk() {
	mkdir -p $QD; qmclean
	for n in $(seq 0 $(($1 - 1))); do truncate -s 1G $QD/g$n.img; sudo losetup -f $QD/g$n.img; done
	qmspeed 400000
	$M -C /dev/md/qmc -e amd -n$2 $(for n in $(seq 0 $(($2 - 1))); do qml g$n; done) --run >/dev/null 2>&1
	$M -C /dev/md/qmv -e amd -l1 -n2 -z 128M $(qml g0) $(qml g1) --run >/dev/null 2>&1; sleep 2; waitrec; sleep 2
	QV=$(mdof raid1); QC=$(cont1)
}
# qmadd <disk> <slot>: put a disk into a slot of the running volume by hand, as managemon does (frozen, new_dev, offset, size, slot,
# recover), at the same place as the slot 0 member (a free disk: the first free space, as AMD)
qmadd() {
	local n=$(basename $1) s=/sys/block/$QV/md
	echo frozen | sudo tee $s/sync_action >/dev/null
	cat /sys/block/$n/dev | sudo tee $s/new_dev >/dev/null
	cat $s/rd0/offset | sudo tee $s/dev-$n/offset >/dev/null
	cat $s/rd0/size | sudo tee $s/dev-$n/size >/dev/null
	echo $2 | sudo tee $s/dev-$n/slot >/dev/null
	echo recover | sudo tee $s/sync_action >/dev/null
}
# qmagain: assemble again; the mirror agrees, the volume has g0 and <disk>
qmagain() {
	stopall; qmspeed 400000
	$M -A /dev/md/qmc -e amd $(for l in $(sudo losetup -a | grep "$QD/" | cut -d: -f1); do echo $l; done) >/dev/null 2>&1
	$M -I /dev/$(cont1) >/dev/null 2>&1; sleep 2; waitrec; QV=$(mdof raid1)
	echo check | sudo tee /sys/block/$QV/md/sync_action >/dev/null; sleep 1; waitrec
	check "36 ($1): assembled again: the mirror agrees, $(basename $2) is a member" "[ -n '$QV' ] && grep -A1 \"^$QV \" /proc/mdstat | grep -q '\[UU\]' && [ \"\$(cat /sys/block/$QV/md/mismatch_cnt)\" = 0 ] && [ -e /sys/block/$QV/md/dev-$(basename $2) ]"
}

# REB-B6: a recorded rebuild ended in md while the old mdmon was stopped (SIGSTOP), and it was replaced (--takeover,
# the old one killed): the new monitor never sees recover -> idle; the end of the rebuild must be recorded
if qmwant B6; then
qmk 3 2
$M /dev/$QC --add $(qml g2) >/dev/null 2>&1; sleep 2
qmspeed 2000
$M /dev/$QV --fail $(qml g1) >/dev/null 2>&1; sleep 6
check "36 (B6): the rebuild onto the spare is recorded" "qmsec | grep -q 'Transform : 0x5358'"
OLD=$(pgrep -x mdmon); sudo kill -STOP $OLD
qmspeed 400000; waitrec 120; sleep 1
sudo ./mdmon --takeover $QC & sleep 2; sudo kill -9 $OLD; sleep 5
check "36 (B6): md ended it while mdmon was replaced: the end is recorded" "qmsec | grep -q 'State : 0x200 (normal)' && qmsec | grep -q 'Transform : 0x0, last 0x5358, state 0xa1a6'"
qmagain B6 $(qml g2)
qmclean
fi

# REB-B5: md rebuilds a slot whose start is not recorded: the old mdmon gave md the disk and left before writing (here mdmon
# killed, the disk added by hand: g2 is a free disk of the container, not a spare). The new mdmon must adopt the rebuild:
# record its start and end (else the slot's member stays failed and g2 a free disk)
if qmwant B5; then
qmk 3 3
$M /dev/$QV --fail $(qml g1) >/dev/null 2>&1; sleep 4
check "36 (B5): a member failed, no spare: degraded, no rebuild" "grep -A1 \"^$QV \" /proc/mdstat | grep -q '\[2/1\]' && ! grep -q recover /proc/mdstat && qmsec | grep -q 'State : 0x201'"
sudo kill -9 $(pgrep -x mdmon); sleep 1
qmspeed 200; qmadd $(qml g2) 1; sleep 1
sudo ./mdmon $QC; sleep 5
echo "info: 36 (B5): $(grep -A2 "^$QV " /proc/mdstat | grep -o 'recovery = *[0-9.]*%'); -E: $(qmsec | grep -o -e 'Transform : [^,]*' -e 'State : [^ ]*' | tr '
' ' ')"
check "36 (B5): a rebuild md runs, not recorded, is recorded by the mdmon started anew" "grep -q recover /proc/mdstat && qmsec | grep -q 'Transform : 0x5358'"
qmspeed 400000; waitrec 120; sleep 4
check "36 (B5): ... and its end: the volume normal" "qmsec | grep -q 'State : 0x200 (normal)'"
qmagain B5 $(qml g2)
qmclean
fi

# REB-B5 (end): the same unrecorded rebuild ended in md before the new mdmon: that one must record its end
if qmwant B5e; then
qmk 3 3
$M /dev/$QV --fail $(qml g1) >/dev/null 2>&1; sleep 4
sudo kill -9 $(pgrep -x mdmon); sleep 1
qmadd $(qml g2) 1; sleep 1; waitrec 120; sleep 1
check "36 (B5e): md rebuilt onto g2 without mdmon" "grep -A1 \"^$QV \" /proc/mdstat | grep -q '\[UU\]' && qmsec | grep -q 'State : 0x201'"
sudo ./mdmon $QC; sleep 5
check "36 (B5e): the mdmon started anew records it: the volume normal" "qmsec | grep -q 'State : 0x200 (normal)'"
qmagain B5e $(qml g2)
qmclean
fi

# REB-B4: md did not take the spare handed to it (managemon: sysfs_add_disk failed; here the first write to new_dev, strace
# EBUSY). No rebuild onto it may be recorded (else mon.rebuilding forever: no end, no other spare);
# the next spare (g3) is taken
if qmwant B4; then
check "36 (B4): strace is there (it makes md refuse the spare; apt install strace)" "command -v strace >/dev/null"
qmk 4 2
$M /dev/$QC --add $(qml g2) >/dev/null 2>&1; sleep 1; $M /dev/$QC --add $(qml g3) >/dev/null 2>&1; sleep 2
sudo strace -f -qq -o /dev/null -p $(pgrep -x mdmon) -P /sys/block/$QV/md/new_dev -e trace=write -e inject=write:error=EBUSY:when=1 2>/dev/null &
sleep 2; qmspeed 1000
$M /dev/$QV --fail $(qml g1) >/dev/null 2>&1; sleep 8
sudo pkill -x strace; sleep 1
QT=$(basename $(readlink -f /sys/block/$QV/md/rd1/block 2>/dev/null) 2>/dev/null)
echo "info: 36 (B4): md $(grep -A1 "^$QV " /proc/mdstat | grep -o '\[[0-9]/[0-9]\] \[[U_]*\]'), rd1 ${QT:-none}; -E: $(qmsec | grep -o 'Transform : [^,]*')"
check "36 (B4): md did not take the first spare: no rebuild recorded onto it, the next spare taken (rd1: ${QT:-none})" "[ '$QT' = $(basename $(qml g3)) ] && grep -q recover /proc/mdstat"
qmspeed 400000; waitrec 120; sleep 4
check "36 (B4): ... the rebuild onto it ends: the volume normal" "qmsec | grep -q 'State : 0x200 (normal)' && grep -A1 \"^$QV \" /proc/mdstat | grep -q '\[UU\]'"
qmagain B4 $(qml g3)
qmclean
fi
rm -rf $QD
fi
# --- end of stage 36 ---

# --- stage 37: the loser of two -C at once leaves no inactive md array (CRE-A1) ---
# Uses the helpers of the suite ($M, check, stopall,
# cont1, waitrec). Alone: STAGES=37 ./run.sh <tree>.
# On the base (3303159e) the "no inactive md array left" checks fail; with the fix b5ebcffc ok.
if want 37; then
cd "$MDADM_DIR"
stopall
for l in $(sudo losetup -a | grep $WQ/q3m/ | cut -d: -f1); do sudo losetup -d $l; done
mkdir -p $WQ/q3m && rm -f $WQ/q3m/*.img
cr37mk() { QL=""; for n in $(seq 0 $(($1 - 1))); do truncate -s $2 $WQ/q3m/d$n.img; QL="$QL $(sudo losetup -f --show $WQ/q3m/d$n.img)"; done; QL=${QL# }; Q1=${QL%% *}; }
cr37drop() { stopall; for l in $(sudo losetup -a | grep $WQ/q3m/ | cut -d: -f1); do sudo losetup -d $l; done; rm -f $WQ/q3m/*.img; }
# cr37race <level>: three times two -C at once on the same disks of container $CN (the same free extent, the
# same subarray number); after each pair remove the winners' volumes. CR37L: how many times one lost, CR37I:
# how many times an inactive md array of a volume was left, CR37V: how many times the configuration had not exactly the winners' volumes
cr37race() {
	local t v n m; CR37L=0; CR37I=0; CR37V=0
	for t in 1 2 3; do
		( $M -C /dev/md/qa -l$1 -n2 -z 64M /dev/$CN --run >$TMPW/q3m-qa.log 2>&1; echo $? >$TMPW/q3m-qa.rc ) &
		( $M -C /dev/md/qb -l$1 -n2 -z 64M /dev/$CN --run >$TMPW/q3m-qb.log 2>&1; echo $? >$TMPW/q3m-qb.rc ) &
		wait; waitrec 60
		n=0; for v in qa qb; do [ "$(cat $TMPW/q3m-$v.rc)" = 0 ] && n=$((n + 1)) || CR37L=$((CR37L + 1)); done
		grep -q ': inactive super external:/' /proc/mdstat && CR37I=$((CR37I + 1))
		[ $($M -E $Q1 2>/dev/null | grep -c '^\[') = $((1 + n)) ] || CR37V=$((CR37V + 1))
		for m in $(ls /sys/block | grep ^md); do case "$(cat /sys/block/$m/md/metadata_version)" in external:/$CN/0|external:amd) ;; external:/$CN/*) $M -S /dev/$m >/dev/null 2>&1;; esac; done
		for v in 2 1; do $M --kill-subarray=$v /dev/$CN >/dev/null 2>&1; done
	done
}

# (a) no mdmon (RAID0): the loser refuses, "the configuration changed since it was read"
cr37mk 4 1G
$M -C /dev/md/q3c -e amd -n 4 $QL --run >/dev/null 2>&1; CN=$(cont1)
$M -C /dev/md/q0 -l0 -n2 -z 64M /dev/$CN --run >/dev/null 2>&1
cr37race 0
check "37 (a): two -C at once, no mdmon: one of them lost (the race took place) (passes on the base too)" "[ $CR37L -gt 0 ]"
check "37 (a): ... the configuration has the volumes of the winners only (passes on the base too)" "[ $CR37V = 0 ]"
check "37 (a): ... no inactive md array left of the volume that lost" "[ $CR37I = 0 ]"
cr37drop

# (b) under mdmon (RAID1): mdmon does not record the loser's volume, "mdmon did not record the new volume"
cr37mk 4 1G
$M -C /dev/md/q3c -e amd -n 4 $QL --run >/dev/null 2>&1; CN=$(cont1)
$M -C /dev/md/q0 -l1 -n2 -z 64M /dev/$CN --run >/dev/null 2>&1; waitrec 60
cr37race 1
check "37 (b): two -C at once under mdmon: one of them lost (the race took place) (passes on the base too)" "[ $CR37L -gt 0 ] && pgrep -x mdmon >/dev/null"
check "37 (b): ... the configuration has the volumes of the winners only (passes on the base too)" "[ $CR37V = 0 ]"
check "37 (b): ... no inactive md array left of the volume that lost" "[ $CR37I = 0 ]"
cr37drop
rm -f $TMPW/q3m-q[ab].log $TMPW/q3m-q[ab].rc
rmdir $WQ/q3m 2>/dev/null
fi
# --- end of stage 37 ---

# --- stage 38: mdadm -C -l1 -n1 --force creates a RAIDABLE, as the BIOS menu does ---
# Uses the helpers of the suite ($M, check, refused,
# stopall, cont1, waitrec, mdof); needs amdraid_dump.py and $HLP/ld-compare.py,
# the BIOS menu snapshot: $FIXT/2026-11-06-qemu-spares-raidable/04-raidable.tar.xz.
# Alone: STAGES=38 ./run.sh <tree>. On the base (3303159e) creation is refused ("AMD RAID volumes
# can be created as …"): all 11 checks fail (the first on the -z and --bitmap messages); with the fix ok.
if want 38; then
cd "$MDADM_DIR"
stopall
for l in $(sudo losetup -a | grep $WQ/r38/ | cut -d: -f1); do sudo losetup -d $l; done
mkdir -p $WQ/r38 && rm -rf $WQ/r38/*
r38mk() { RL=""; for n in $(seq 0 $(($1 - 1))); do truncate -s $2 $WQ/r38/d$n.img; RL="$RL $(sudo losetup -f --show $WQ/r38/d$n.img)"; done; RL=${RL# }; R1=${RL%% *}; }
r38drop() { stopall; for l in $(sudo losetup -a | grep $WQ/r38/ | cut -d: -f1); do sudo losetup -d $l; done; rm -f $WQ/r38/*.img; }
r38dev() { for m in $(ls /sys/block | grep ^md); do grep -qx "external:/$1/$2" /sys/block/$m/md/metadata_version 2>/dev/null && echo $m; done; }

# (a) RAIDABLE on a whole 64 GiB disk, as the BIOS menu (snapshot 04, the same disk size); refusals
r38mk 3 64G; set -- $RL; R2=$2; R3=$3
$M -C /dev/md/q3rc -e amd -n 3 $RL --run >/dev/null 2>&1; CN=$(cont1)
OUT1=$($M -C /dev/md/q3ra -e amd -l1 -n1 $R1 --run 2>&1)
OUT2=$($M -C /dev/md/q3ra -e amd -l1 -n1 --force -z 1G $R1 --run 2>&1)
OUT3=$($M -C /dev/md/q3ra -e amd -l1 -n1 --force $R1 $R2 --run 2>&1)
OUT4=$($M -C /dev/md/q3ra -e amd -l1 -n1 --force --bitmap=internal $R1 --run 2>&1)
OUT5=$($M -C /dev/md/q3ra -e amd -l1 -n1 -x1 --force $R1 $R2 --run 2>&1)
check "38 (a): -l1 -n1 without --force, with -z, two disks, --bitmap, -x: refused, nothing written" "echo \"\$OUT1\" | grep -q \"'1' is an unusual number of drives\" && echo \"\$OUT2\" | grep -q 'an AMD RAIDABLE volume takes its whole disk: give no --size' && echo \"\$OUT3\" | grep -q 'more devices (2) than are in the array(1)' && echo \"\$OUT4\" | grep -q 'an md bitmap is for AMD RAID1, RAID10 and RAID5 volumes' && echo \"\$OUT5\" | grep -q 'does not support spare disks at create time' && [ \$($M -E $R1 | grep -c '^\[') = 0 ]"
$M -C /dev/md/q3ra -e amd -l1 -n1 --force $R1 --run >/dev/null 2>&1; sleep 2
RA=$(r38dev $CN 0)
check "38 (a): created: md raid1 [1/1] of the whole disk (133148672 sectors, as the menu's), no resync" "[ -n '$RA' ] && [ \$(cat /sys/block/$RA/md/level) = raid1 ] && [ \$(cat /sys/block/$RA/md/raid_disks) = 1 ] && [ \$(cat /sys/block/$RA/size) = 133148672 ] && [ \$(cat /sys/block/$RA/md/sync_action) = idle ] && ! grep -A2 \"^$RA \" /proc/mdstat | grep -q -E 'resync|recover'"
check "38 (a): -E: RAIDABLE (0x1bfb), 1 x 1, read-write, normal" "$M -E $R1 | grep -A12 '^\[q3ra\]' | grep -q 'Type : RAIDABLE (0x1bfb), 1 x 1' && $M -E $R1 | grep -A12 '^\[q3ra\]' | grep -q 'md support : read-write' && $M -E $R1 | grep -A12 '^\[q3ra\]' | grep -q 'State : 0x200 (normal)'"
mkdir -p $WQ/r38/menu && tar -xSJf $FIXT/2026-11-06-qemu-spares-raidable/04-raidable.tar.xz -C $WQ/r38/menu 04-raidable/sata3.bin
R38CMP=$(python3 $HLP/ld-compare.py $WQ/r38/d0.img $WQ/r38/menu/04-raidable/sata3.bin | grep -v '^differences' | cut -d' ' -f1 | tr '\n' ' ')
check "38 (a): the LD record = the menu's (snapshot 04) but for IDs, Handles, generation, name and State 0x200: [$R38CMP]" "[ \"\$R38CMP\" = 'LD.State LD.Id LD.Id.Handle LD.Generation LD.Name Element[0].Id Element[0].Id.Handle ' ]"
OUT6=$($M -C /dev/md/q3rb -e amd -l1 -n1 --force $R1 --run 2>&1)
$M -C /dev/md/q3r0 -e amd -l0 -n2 -z 64M $R2 $R3 --run >/dev/null 2>&1
OUT7=$($M -C /dev/md/q3rb -l1 -n1 --force /dev/$CN --run 2>&1)
check "38 (a): a disk with a volume on it: refused, the disk given or none free in the container (reasons per disk)" "echo \"\$OUT6\" | grep -q 'cannot take a member: a RAIDABLE volume takes a whole disk, and a volume is on this one' && echo \"\$OUT7\" | grep -q '0 disks of the container can take a member, 1 needed' && [ \$(echo \"\$OUT7\" | grep -c 'a RAIDABLE volume takes a whole disk, and a volume is on this one') = 3 ] && [ \$($M -E $R1 | grep -c '^\[') = 2 ]"
$M -S /dev/$(r38dev $CN 1) >/dev/null 2>&1; $M --kill-subarray=1 /dev/$CN >/dev/null 2>&1; sleep 1
$M -C /dev/md/q3rb -l1 -n1 --force /dev/$CN --run >/dev/null 2>&1; sleep 2
check "38 (a): container given, mdmon running: the first whole free disk (Handle 2), recorded by mdmon" "[ -n \"\$(r38dev $CN 1)\" ] && $M -E $R1 | grep -A12 '^\[q3rb\]' | grep -q 'Member   0 : [0-9a-f]* handle 2 ' && $M -E $R1 | grep -A12 '^\[q3rb\]' | grep -q 'RAIDABLE (0x1bfb)'"
r38drop

# (b) 12 arrays (the BIOS menu's limit): the --force that -n1 needs does not lift the limit
r38mk 3 1G; set -- $RL; R2=$2; R3=$3
$M -C /dev/md/q3rc -e amd -n 3 $RL --run >/dev/null 2>&1; CN=$(cont1)
for i in $(seq 1 12); do $M -C /dev/md/q3l$i -e amd -l0 -n2 -z 4M $R1 $R2 --run >/dev/null 2>&1; done
OUT=$($M -C /dev/md/q3ra -e amd -l1 -n1 --force $R3 --run 2>&1)
check "38 (b): 12 arrays: a RAIDABLE refused although -n1 has --force, and --force not offered" "[ \$($M -E $R1 | grep -c '^\[') = 12 ] && echo \"\$OUT\" | grep -q 'AMD RAID allows 12 arrays' && echo \"\$OUT\" | grep -q 'delete one first: a RAIDABLE volume is not created past the limit' && [ \$($M -E $R3 | grep -c '^\[') = 12 ]"
r38drop

# (c) the created RAIDABLE: data, reassembly, --grow -n 2 onto a global spare -> RAID1 (as a volume from the BIOS menu, stage 15b)
r38mk 3 2G; set -- $RL; R2=$2
$M -C /dev/md/q3rc -e amd -n 2 $R1 $R2 --run >/dev/null 2>&1; CN=$(cont1)
$M -C /dev/md/q3ra -e amd -l1 -n1 --force $R1 --run >/dev/null 2>&1; sleep 2; RA=$(r38dev $CN 0)
head -c 8M /dev/urandom > $WQ/r38/data.bin; sudo dd if=$WQ/r38/data.bin of=/dev/$RA bs=1M oflag=direct status=none
stopall
for d in $R1 $R2; do $M -I $d >/dev/null 2>&1; done; CN=$(cont1); $M -I /dev/$CN >/dev/null 2>&1; sleep 2; RA=$(r38dev $CN 0)
check "38 (c): reassembled (-I): raid1 [1/1], no resync, data in place" "[ -n '$RA' ] && grep -A2 \"^$RA \" /proc/mdstat | grep -q '\[1/1\] \[U\]' && ! grep -A2 \"^$RA \" /proc/mdstat | grep -q -E 'resync|recover' && cmp -s $WQ/r38/data.bin <(sudo dd if=/dev/$RA bs=1M count=8 iflag=direct status=none)"
OUT=$($M --grow /dev/$RA --raid-devices=2 2>&1)
R4=${RL##* }; $M /dev/$CN --add $R4 >/dev/null 2>&1; sleep 2
$M --grow /dev/$RA --raid-devices=2 >/dev/null 2>&1; sleep 3
check "38 (c): --grow -n 2: refused without a spare; onto the global spare: [2/1] recovering, the RAIDABLE recorded growing (x2)" "echo \"\$OUT\" | grep -q 'Need 1 spare' && [ \$(cat /sys/block/$RA/md/raid_disks) = 2 ] && python3 $TOOLS/amdraid_dump.py --brief $WQ/r38/d0.img | grep -q 'RAIDABLE NORMAL   1x1 .* x2'"
waitrec; sleep 3
echo check | sudo tee /sys/block/$RA/md/sync_action >/dev/null; sleep 1; waitrec
check "38 (c): grown: [2/2] [UU], md check clean, data in place" "grep -A2 \"^$RA \" /proc/mdstat | grep -q '\[2/2\] \[UU\]' && [ \$(cat /sys/block/$RA/md/mismatch_cnt) = 0 ] && cmp -s $WQ/r38/data.bin <(sudo dd if=/dev/$RA bs=1M count=8 iflag=direct status=none)"
stopall
check "38 (c): final packet: one LD R10N 1x2 NORMAL on the RAIDABLE's disk and the spare, same element offsets" "python3 $TOOLS/amdraid_dump.py --brief $WQ/r38/d0.img | grep -q 'R10N   NORMAL   1x2 .*\[1:' && [ \$(python3 $TOOLS/amdraid_dump.py $WQ/r38/d0.img | grep -c 'data=0x105000+0x2fb000 .* alloc=0x100000+0x300000') = 2 ]"
r38drop; rm -rf $WQ/r38
fi
# --- end of stage 38 ---
# --- stage 39: the AMD udev rule: BOOT-A1 (a disk with md 0.90 on its last partition) and BOOT-A2 (last-resort on "unsafe") ---
# Uses the helpers of the suite ($M, check, stopall,
# cont1, waitrec, want). The rule: $AMD_RULE (default "$AMD_RULE", set by the suite; the old
# rule: AMD_RULE=<file>): with the old one (a) and (b) FAIL, with the new one ok.
# (a) mdadm -I from the rule on a whole disk whose last partition is
#     an md 0.90 member (the superblock where a whole disk's would be; libblkid deliberately ignores it on the whole disk):
#     without --metadata=amd mdadm assembles an array from the whole disk and drops the partitions.
# (b) BOOT-A2: a container on X, Y, Z, W: A is RAID1 X+W, B is RAID1 Y+Z; W failed in A and taken out, A recorded
#     CRITICAL with X alone. Then only X and Y come (LIO SCSI disks, real add events, as stage 18): A is complete
#     by itself, so -I Y gives MD_STARTED=unsafe, not no; the rule with the old condition (=="no") sets no
#     last-resort timer, B never starts; with the new one (no|*unsafe*) mdadm --run starts B on Y 30 s later.
#     mdmon@ and mdadm-last-resort@ from the tree into /run/systemd/system (BINDIR → the mdadm tree), removed at the end.
if want 39; then
cd "$MDADM_DIR"
stopall
mkdir -p $WQ/q3j && rm -f $WQ/q3j/*.img

# (a) BOOT-A1: 206898 sectors, a partition 2048…end: the ends of the partition and of the disk, rounded to 64 KiB, coincide
Q3B=""
for n in 0 1; do
	truncate -s $((206898 * 512)) $WQ/q3j/p$n.img
	printf 'label: dos\nstart=2048, type=fd\n' | /sbin/sfdisk -q $WQ/q3j/p$n.img
	Q3B="$Q3B $(sudo losetup -P -f --show $WQ/q3j/p$n.img)"
done
set -- $Q3B
yes | $M -C /dev/md/q3b090 -e 0.90 -l1 -n2 --assume-clean --run "${1}p1" "${2}p1" >/dev/null 2>&1
$M --stop /dev/md/q3b090 >/dev/null 2>&1
check "39 (a): 0.90 RAID1 on partitions; mdadm -E of the whole disk shows it too (passes on the base too)" "$M -E ${1}p1 | grep -q 'Version : 0.90' && $M -E $1 2>/dev/null | grep -q 'Version : 0.90'"
# the rule's IMPORT{program}: /usr/bin|/sbin/mdadm → $M, $devnode → the whole disk
q3b_cmd=$(sed -n 's/^IMPORT{program}="\(.*\)"$/\1/p' "$AMD_RULE" | sed -e "s,^[^ ]*mdadm ,$M ," -e "s,[\$]devnode,$1,")
echo "    rule: $q3b_cmd"
q3b_out=$(eval "$q3b_cmd" 2>&1)
echo "$q3b_out" | sed 's/^/    /'
check "39 (a): the rule's mdadm -I leaves a whole disk with a 0.90 member partition alone (BOOT-A1)" "! echo \"\$q3b_out\" | grep -q '^MD_DEVICE=' && [ -b ${1}p1 ]"
stopall
for l in $Q3B; do sudo losetup -d $l; done; set --
rm -f $WQ/q3j/p*.img

# (b) BOOT-A2. Layout on loop: u0 = X, u1 = Y, u2 = Z, u3 = W
if ! lio_ok || [ ! -d /run/systemd/system ]; then skip "39 (b)" "needs LIO (as stage 18) and systemd"; else
CF=/sys/kernel/config/target; FB=$CF/core/fileio_39; NAA=naa.5001405039000001; TP=$CF/loopback/$NAA/tpgt_1
UR=/run/udev/rules.d/64-amd-raid-assembly-test39.rules; SD=/run/systemd/system
mdby() { for m in $(ls /sys/block | grep ^md); do [ "$(cat /sys/block/$m/md/metadata_version 2>/dev/null)" = "external:/$1/$2" ] && echo $m; done; }
U39() { local d a; for d in /sys/block/sd*; do a=$(basename "$(readlink -f $d/device)"); [ "$(sed 's/ *$//' $d/device/vendor 2>/dev/null)" = LIO-ORG ] && [ "${a##*:}" = $1 ] && echo /dev/${d##*/}; done; }
plug39() { sudo mkdir $TP/lun/lun_$1 && sudo ln -s $FB/u$1 $TP/lun/lun_$1/u$1; sudo udevadm settle; sleep 1; }
L39=(); for n in 0 1 2 3; do truncate -s 1G $WQ/q3j/u$n.img; L39+=($(sudo losetup -f --show $WQ/q3j/u$n.img)); done
$M -C /dev/md/q3jc -e amd -n 4 ${L39[@]} --run >/dev/null 2>&1
CN=$(cont1)
# -C in a container picks the disks itself (the named ones are held by the container): A of 480 MiB (of 502 free) leaves no
# room on its disks, B goes to the other two; roles as they turn out, L39 and F39 (files for LIO) in the order X, Y, Z, W
$M -C /dev/md/q3ja -l1 -n2 -z 480M /dev/$CN --run >/dev/null 2>&1
$M -C /dev/md/q3jb -l1 -n2 -z 64M /dev/$CN --run >/dev/null 2>&1
sleep 1; waitrec; sleep 2
A39=$(mdby $CN 0); B39=$(mdby $CN 1); XA=(); YB=()
for l in ${L39[@]}; do
	[ -e /sys/block/$A39/md/dev-${l#/dev/} ] && XA+=($l)
	[ -e /sys/block/$B39/md/dev-${l#/dev/} ] && YB+=($l)
done
check "39 (b): A = RAID1 on two disks, B = RAID1 on the other two (passes on the base too)" "[ -n '$A39' ] && [ -n '$B39' ] && [ ${#XA[@]} = 2 ] && [ ${#YB[@]} = 2 ]"
L39=(${XA[0]:-} ${YB[0]:-} ${YB[1]:-} ${XA[1]:-})
F39=(); for l in ${L39[@]}; do F39+=($(sudo losetup -nO BACK-FILE $l | sed 's/ *$//')); done
$M /dev/$A39 --fail ${L39[3]} >/dev/null 2>&1; sleep 3
for i in $(seq 1 30); do $M /dev/$CN --remove ${L39[3]} >/dev/null 2>&1; grep "^$CN " /proc/mdstat | grep -q "${L39[3]#/dev/}\[" || break; sleep 0.5; done
sleep 2
check "39 (b): ... W failed and taken out: A recorded CRITICAL (0x201) with X alone, B NORMAL (passes on the base too)" "[ \"\$($M -E ${L39[0]} | grep 'State :' | sed -n 1p | grep -o '0x20[01]')\" = 0x201 ] && [ \"\$($M -E ${L39[0]} | grep 'State :' | sed -n 2p | grep -o '0x20[01]')\" = 0x200 ]"
stopall; for l in ${L39[@]}; do sudo losetup -d $l; done
# a boot-like environment: the rule (LIO disks only), mdmon@ and last-resort from the tree
sudo mkdir -p /run/udev/rules.d $SD
sed -e "s|/usr/bin/mdadm|$MDADM_DIR/mdadm|g; s|/sbin/mdadm|$MDADM_DIR/mdadm|g" \
	-e '/^SUBSYSTEM!="block"/a ENV{ID_VENDOR}!="LIO-ORG", GOTO="amd_raid_end"' "$AMD_RULE" | sudo tee $UR >/dev/null
for u in mdmon@.service mdadm-last-resort@.service mdadm-last-resort@.timer; do
	sed -e "s|BINDIR|$MDADM_DIR|g" systemd/$u | sudo tee $SD/$u >/dev/null
done
sudo systemctl daemon-reload; sudo udevadm control --reload
sudo modprobe -a target_core_mod target_core_file tcm_loop
sudo mkdir -p $TP && echo $NAA | sudo tee $TP/nexus >/dev/null
for n in 0 1 2 3; do
	sudo mkdir -p $FB/u$n
	echo "fd_dev_name=${F39[$n]:-$WQ/q3j/u$n.img},fd_dev_size=1073741824" | sudo tee $FB/u$n/control >/dev/null
	echo 1 | sudo tee $FB/u$n/enable >/dev/null
done
# "boot without Z": X comes, then Y (W taken out)
plug39 0; plug39 1; sleep 2
X39=$(U39 0); Y39=$(U39 1); CN=$(cont1); A39=$(mdby $CN 0)
T39=$(systemctl list-timers --all --no-pager | grep -c "mdadm-last-resort@$CN.timer")
echo "    MD_STARTED: X=$(udevadm info -q property $X39 | sed -n 's/^MD_STARTED=//p') Y=$(udevadm info -q property $Y39 | sed -n 's/^MD_STARTED=//p'); last-resort timers: $T39"
check "39 (b): X, then Y plugged: A (complete by itself) started on X; -I of Y said MD_STARTED=*unsafe* (passes on the base too)" "[ -n '$A39' ] && grep -A1 \"^$A39 \" /proc/mdstat | grep -q '\[2/1\]' && udevadm info -q property $Y39 | grep -q '^MD_STARTED=.*unsafe'"
check "39 (b): ... the rule set mdadm-last-resort@$CN.timer (BOOT-A2)" "[ $T39 -ge 1 ]"
sleep 40
B39=$(mdby $CN 1)
check "39 (b): ... 30 s later B runs degraded on Y (BOOT-A2)" "[ -n '$B39' ] && grep -A1 \"^$B39 \" /proc/mdstat | grep -q '\[2/1\]'"
check "39 (b): ... mdmon recorded B CRITICAL (0x201)" "pgrep -x mdmon >/dev/null && $M -E $Y39 | grep 'State :' | sed -n 2p | grep -q 0x201"
stopall
sudo systemctl stop "mdadm-last-resort@$CN.timer" "mdadm-last-resort@$CN.service" 2>/dev/null
sudo rm -f $UR $SD/mdmon@.service $SD/mdadm-last-resort@.service $SD/mdadm-last-resort@.timer
sudo systemctl daemon-reload; sudo udevadm control --reload
for n in 0 1; do sudo rm -f $TP/lun/lun_$n/u$n; sudo rmdir $TP/lun/lun_$n; done
sudo rmdir $TP $CF/loopback/$NAA
for n in 0 1 2 3; do sudo rmdir $FB/u$n; done; sudo rmdir $FB
sudo udevadm settle
fi
rm -rf $WQ/q3j
fi
# --- end of stage 39 ---

# --- stage 40: XFS, btrfs, LUKS, LVM on a whole disk: -C reports it and asks, --add refuses it ---
# check_fs_magic() (util.c): Create calls it next to check_ext2(), super-amd's --add in amd_add_holds_data().
# Needs mkfs.xfs, cryptsetup and pvcreate (xfsprogs, cryptsetup, lvm2); without them the stage is skipped.
if want 40; then
cd "$MDADM_DIR"
stopall
q40tools=1; for t in mkfs.xfs mkfs.btrfs cryptsetup pvcreate; do sudo sh -c "command -v $t" >/dev/null || q40tools=0; done
if [ $q40tools = 0 ]; then skip "40" "needs mkfs.xfs, mkfs.btrfs, cryptsetup, pvcreate (xfsprogs, btrfs-progs, cryptsetup, lvm2)"; else
q40drop() { stopall; sudo vgremove -q -ff q40vg >/dev/null 2>&1; for l in $(sudo losetup -a | grep $WQ/q4fs/ | cut -d: -f1); do sudo losetup -d $l; done; rm -f $WQ/q4fs/*.img; }
mkdir -p $WQ/q4fs
q40drop
QL=""; for n in 0 1 2 3; do truncate -s 700M $WQ/q4fs/d$n.img; QL="$QL $(sudo losetup -f --show $WQ/q4fs/d$n.img)"; done
read -r QA QB QC QD <<<"$QL"
q40fs() {	# q40fs <xfs|btrfs|luks|lvm>: only that on the whole of $QA
	sudo dd if=/dev/zero of=$QA bs=1M count=2 conv=fsync status=none
	case $1 in
	xfs)   sudo mkfs.xfs -q -f $QA ;;
	btrfs) sudo mkfs.btrfs -q -f $QA >/dev/null ;;
	luks)  printf q40 | sudo cryptsetup luksFormat -q --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 $QA - ;;
	lvm)   sudo pvcreate -q -ff -y $QA >/dev/null && sudo vgcreate -q q40vg $QA >/dev/null && sudo vgchange -q -an q40vg >/dev/null ;;
	esac
}
q40msg() { case $1 in xfs) echo 'appears to contain an XFS file system';; btrfs) echo 'appears to contain a btrfs file system';;
	luks) echo 'appears to contain a LUKS encrypted volume';; lvm) echo 'appears to be an LVM physical volume';; esac; }
for fs in xfs btrfs luks lvm; do
	q40fs $fs
	echo n | $M -C /dev/md/q40n -e1.2 -l1 -n2 $QA $QB >$TMPW/q40.log 2>&1
	check "40: $fs on the whole disk: -C -e1.2 reports it and asks, nothing created" "grep -q '$(q40msg $fs)' $TMPW/q40.log && grep -q 'Continue creating array' $TMPW/q40.log && [ ! -e /dev/md/q40n ]"
	echo n | $M -C /dev/md/q40c -e amd -n2 $QA $QB >$TMPW/q40.log 2>&1
	check "40: $fs on the whole disk: -C -e amd reports it and asks, nothing created" "grep -q '$(q40msg $fs)' $TMPW/q40.log && grep -q 'Continue creating array' $TMPW/q40.log && [ ! -e /dev/md/q40c ]"
	[ $fs = lvm ] && sudo vgremove -q -ff q40vg >/dev/null 2>&1
done
# --add to a container with a RAID1 (mdmon running)
for d in $QB $QC $QD; do sudo dd if=/dev/zero of=$d bs=1M count=2 conv=fsync status=none; done
$M -C /dev/md/q40c -e amd -n2 $QB $QC --run >/dev/null 2>&1; CN=$(cont1)
$M -C /dev/md/q40v -l1 -n2 -z 64M /dev/$CN --run >/dev/null 2>&1; waitrec 60
check "40: container with a RAID1 volume, mdmon runs" "grep -q 'active raid1' /proc/mdstat && pgrep -x mdmon >/dev/null"
for fs in xfs btrfs luks lvm; do
	q40fs $fs
	$M --add /dev/$CN $QA >$TMPW/q40.log 2>&1
	check "40: $fs on the whole disk: --add refused, the disk keeps it" "grep -q '$(q40msg $fs)' $TMPW/q40.log && grep -q 'not adding .*--force wipes it' $TMPW/q40.log && ! $M -E $QA 2>/dev/null | grep -q 'AMD' && sudo blkid -p -o value -s TYPE $QA | grep -qxE 'xfs|btrfs|crypto_LUKS|LVM2_member'"
	[ $fs = lvm ] && sudo vgremove -q -ff q40vg >/dev/null 2>&1
done
q40fs xfs
$M --add --force /dev/$CN $QA >$TMPW/q40.log 2>&1
check "40: xfs: --add --force takes the disk" "$M -E $QA 2>/dev/null | grep -q 'AMD'"
$M --add /dev/$CN $QD >$TMPW/q40.log 2>&1
check "40: blank disk: --add takes it, nothing reported" "! grep -qE 'appears to (contain|be)' $TMPW/q40.log && $M -E $QD 2>/dev/null | grep -q 'AMD'"
q40drop
rm -f $TMPW/q40.log
rmdir $WQ/q4fs 2>/dev/null
fi
fi
# --- end of stage 40 ---

# --- stage 41: mdmon's shadow of the AMD bitmap.  A crash of Linux, then the AMD Windows driver 9.5 clears the AMD
# bitmap without a check (notes of the judge 9.5) - the shadow (AllocatedSpace + 0x101 of element [0][0]) still says
# "dirty": the next assembly resyncs (with an md bitmap: by its bits only).  A clean stop leaves no dirty shadow.
# "Windows 9.5" here: the AMD bitmap sector zeroed and a configuration write (a rename) - what that driver leaves.
if want 41; then
cd "$MDADM_DIR"
stopall
Q41=$WQ/q41
for l in $(sudo losetup -a | grep $Q41/ | cut -d: -f1); do sudo losetup -d $l; done
mkdir -p $Q41 && rm -f $Q41/*
Q41AS=$((0x100000)); Q41DATA=$((0x105000))	# AllocatedSpace and the data start of volumes -C makes on blank disks
q41l() { sudo losetup -j $Q41/$1.img | cut -d: -f1; }
q41vol() { local c=$(cont1) m; for m in $(ls /sys/block | grep ^md); do grep -qx "external:/$c/0" /sys/block/$m/md/metadata_version 2>/dev/null && echo $m; done; }
q41nres() { sudo dmesg | grep -c 'md: resync of RAID array'; }
q41spoil() { head -c 1M /dev/urandom | dd of=$Q41/$1.img bs=1M seek=$(( Q41DATA / 2048 + $2 )) conv=notrunc status=none; }
q41check() { echo check | sudo tee /sys/block/$1/md/sync_action >/dev/null; sleep 1; waitrec; cat /sys/block/$1/md/mismatch_cnt; }
q41crash() {	# q41crash <md> <images...>: writes to the volume, copies of the images meanwhile, a clean stop, the copies put back
	local v=$1 n w; shift
	( while :; do sudo dd if=/dev/urandom of=/dev/$v bs=1M count=4 seek=136 oflag=direct status=none; done ) & w=$!
	sleep 3
	for n in "$@"; do cp --sparse=always $Q41/$n.img $Q41/$n.crash; done
	kill $w; wait $w 2>/dev/null
	stopall
	for n in "$@"; do sudo losetup -d $(q41l $n); mv $Q41/$n.crash $Q41/$n.img; sudo losetup -f $Q41/$n.img; done
}
q41win() {	# q41win <images...>: "Windows 9.5" - the AMD bitmap cleared, a configuration written; the container assembled, no volume
	local n
	for n in "$@"; do dd if=/dev/zero of=$Q41/$n.img bs=512 seek=$((Q41AS + 0x80)) count=1 conv=notrunc status=none; done
	$M -A /dev/md/q41c -e amd $(for n in "$@"; do q41l $n; done) >/dev/null 2>&1
	$M --update-subarray=0 --update=name -N q41w$RANDOM /dev/$(cont1) >/dev/null 2>&1
}
q41shadow() { for n in "$@"; do $M -E $(q41l $n) 2>/dev/null; done | grep -q 'mdmon bitmap : dirty from bit 0, the AMD bitmap cleared since'; }
q41level() {	# q41level <level> <disks> [--bitmap=internal]
	local lv=$1 n=$2 bm=${3:-} i D="" V P R tag=raid$1${3:+ md-bitmap}
	for i in $(seq 0 $((n - 1))); do truncate -s 2G $Q41/l$i.img; D="$D l$i"; sudo losetup -f $Q41/l$i.img; done
	$M -C /dev/md/q41c -e amd -n $n $(for i in $D; do q41l $i; done) --run >/dev/null 2>&1
	$M -C /dev/md/q41v -e amd -l$lv -n$n -z 512M $bm $(for i in $D; do q41l $i; done) --run >/dev/null 2>&1
	V=$(q41vol); waitrec
	# with an md bitmap: the bitmap daemon clears the bits of the initial sync (~15-20 s) - else the "crash" would catch them all
	[ -n "$bm" ] && for i in $(seq 1 60); do $M -E $(q41l l0) 2>/dev/null | grep -q 'md Bitmap : .*, 0 of ' && break; sleep 1; done
	q41crash $V $D
	# 1 MiB spoiled on member 1: in the md bitmap chunk written to (MiB 136-140 of the volume; MiB 140 of a RAID1 member,
	# about 70 of a RAID5/10 one), and in a clean one (MiB 330 of the member)
	q41spoil l1 $([ $lv = 1 ] && echo 140 || echo 70); [ -n "$bm" ] && q41spoil l1 330
	q41win $D
	check "41 $tag: crash, then the AMD driver cleared the bitmap: -E shows mdmon's shadow dirty from bit 0" "q41shadow $D"
	R=$(q41nres)
	$M -I /dev/$(cont1) >/dev/null 2>&1; sleep 2; V=$(q41vol); waitrec
	check "41 $tag: ... assembled: resync ($R -> $(q41nres) in the kernel log)" "[ -n '$V' ] && [ \$(q41nres) -gt $R ]"
	P=$(q41check $V)
	if [ -n "$bm" ]; then
		check "41 $tag: ... by the md bits only: the spoiled MiB in the dirty chunk fixed, the one in a clean chunk left ($P)" "[ '$P' = 2048 ]"
		echo repair | sudo tee /sys/block/$V/md/sync_action >/dev/null; sleep 1; waitrec
	else
		check "41 $tag: ... the spoiled MiB fixed, check 0 ($P)" "[ '$P' = 0 ]"
	fi
	stopall
	# a dual boot without a crash: Linux stopped cleanly, Windows clears the (clean) AMD bitmap - no resync
	q41win $D
	check "41 $tag: clean stop, then the AMD driver: no shadow left dirty (-E)" "! q41shadow $D"
	R=$(q41nres)
	$M -I /dev/$(cont1) >/dev/null 2>&1; sleep 2; V=$(q41vol); waitrec
	check "41 $tag: ... assembled without resync" "[ -n '$V' ] && [ \$(q41nres) = $R ] && [ \$(cat /sys/block/$V/md/resync_start) = none ]"
	stopall
	for i in $D; do sudo losetup -d $(q41l $i); done; rm -f $Q41/*
}
q41level 1 2
q41level 5 3
q41level 10 4
q41level 1 2 --bitmap=internal
rmdir $Q41
fi
# --- end of stage 41 ---

# --- stage 42: the bit 0x20000000 in LD.Flags, which rcraid.sys 9.5.0.201 sets while a transform runs, is cleared when
# mdmon ends the transform.  A model of Windows 9.5: a rebuild (RESTORE_SEGMENTS) or an initialization
# (CREATE_REDUNDANCY) mdmon recorded is stopped midway; the bit is put into the LDs with a transform in the live
# packet of each disk (as 9.5 writes them during its transforms, in a Windows VM); assembly, mdmon ends the transform.
if want 42; then
cd "$MDADM_DIR"
Q42=$WQ/q42
q42l() { sudo losetup -j $Q42/$1.img | cut -d: -f1; }
q42sec() { $M -E $(q42l g0) 2>/dev/null | sed -n '/^\[q42v\]/,/^\[/p'; }
# q42speed <KiB/s>: md's sync speed limit (and the lower one not above it)
q42speed() { local m=$(( $1 < 1000 ? $1 : 1000 ))
	echo $m | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null; echo $1 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null; }
q42clean() { stopall; for l in $(sudo losetup -a | grep "$Q42/" | cut -d: -f1); do sudo losetup -d $l; done; rm -f $Q42/*.img; }
# q42mk <disks> <in the container> <MiB of the volume>: g0...; container q42c of the first <in the container>, RAID1 q42v on g0+g1
q42mk() {
	mkdir -p $Q42; q42clean
	for n in $(seq 0 $(($1 - 1))); do truncate -s 1G $Q42/g$n.img; sudo losetup -f $Q42/g$n.img; done
	$M -C /dev/md/q42c -e amd -n$2 $(for n in $(seq 0 $(($2 - 1))); do q42l g$n; done) --run >/dev/null 2>&1
	$M -C /dev/md/q42v -e amd -l1 -n2 -z $3M $(q42l g0) $(q42l g1) --run >/dev/null 2>&1; sleep 2
}
# q42bit <disk>...: "<how many LDs with 0x20000000> <name:Flags> ..." of the live packet of each disk
q42bit() {
	python3 - $(for n in "$@"; do echo $Q42/$n.img; done) <<'PY'
import os, sys
sys.path.insert(0, os.environ["TOOLS"]); import amdraid_dump as ad
for p in sys.argv[1:]:
    dk = ad.Disk(p); rc = ad.parse_raidcore(dk.read(ad.LBA_RAIDCORE)); c = ad.parse_commit(dk.read(rc["commit_lba"]))
    h, pds, lds = ad.parse_gen(ad.read_gen(dk, c["gen_lba"], c["gen_len"]))
    print(sum(1 for l in lds if l["flags84"] & 0x20000000), " ".join("%s:%x" % (l["name"], l["flags84"]) for l in lds))
PY
}
# q42mark <disk>...: 0x20000000 into the LDs with a transform (TransformType != 0) of the live packet, packet and commit sums valid
q42mark() {
	python3 - $(for n in "$@"; do echo $Q42/$n.img; done) <<'PY'
import os, struct, sys
sys.path.insert(0, os.environ["TOOLS"]); from amdraid_dump import rc_sum
for p in sys.argv[1:]:
    with open(p, "r+b") as f:
        f.seek(0x5001 * 512); c = bytearray(f.read(512)); off, size = struct.unpack_from("<II", c, 8)
        f.seek(off * 512); g = bytearray(f.read((size + 511) // 512 * 512)); q, end = struct.unpack_from("<II", g, 0x2c); end += q
        while q + 0x200 <= end and struct.unpack_from("<I", g, q)[0] == 0x25BD:
            if struct.unpack_from("<I", g, q + 0x10)[0]:
                struct.pack_into("<I", g, q + 0x84, struct.unpack_from("<I", g, q + 0x84)[0] | 0x20000000)
            q += struct.unpack_from("<I", g, q + 0x90)[0]
        struct.pack_into("<Q", g, 0, rc_sum(g, 0xc, size - 0xc)); f.seek(off * 512); f.write(g)
        struct.pack_into("<Q", c, 0x10, struct.unpack_from("<Q", g, 0)[0]); struct.pack_into("<Q", c, 0, rc_sum(c, 8, 0x1f8))
        f.seek(0x5001 * 512); f.write(c)
PY
}
# q42again <disk>...: assemble the container of these disks again (-A, -I); mdmon ends the transform
q42again() {
	q42speed 400000
	$M -A /dev/md/q42c -e amd $(for n in "$@"; do q42l $n; done) >/dev/null 2>&1
	$M -I /dev/$(cont1) >/dev/null 2>&1; sleep 2; waitrec 120; sleep 4
}

# a rebuild onto a spare: started and recorded by mdmon, stopped midway, the LDs marked as 9.5 would; mdmon ends it
q42mk 3 2 256; waitrec; sleep 2
$M /dev/$(cont1) --add $(q42l g2) >/dev/null 2>&1; sleep 2
q42speed 2000
$M /dev/$(mdof raid1) --fail $(q42l g1) >/dev/null 2>&1; sleep 6
check "42 rebuild: the rebuild onto the spare is recorded" "q42sec | grep -q 'Transform : 0x5358'"
stopall
q42mark g0 g2
B=$(q42bit g0 g2)
check "42 rebuild: ... stopped midway, 0x20000000 in both LDs of the volume as rcraid.sys 9.5 writes them ($(echo $B | tr '\n' ' '))" "[ \"\$(q42bit g0 g2 | cut -d' ' -f1 | tr '\n' ' ')\" = '2 2 ' ]"
q42again g0 g2
V=$(mdof raid1)
check "42 rebuild: ... mdmon ended it: normal, last 0x5358, no 0x20000000 left ($(q42bit g0 g2 | tr '\n' ' '))" "q42sec | grep -q 'State : 0x200 (normal)' && q42sec | grep -q 'Transform : 0x0, last 0x5358, state 0xa1a6' && [ \"\$(q42bit g0 g2 | cut -d' ' -f1 | tr '\n' ' ')\" = '0 0 ' ]"
echo check | sudo tee /sys/block/$V/md/sync_action >/dev/null; sleep 1; waitrec 120
check "42 rebuild: ... the mirror agrees" "[ -n '$V' ] && grep -A1 \"^$V \" /proc/mdstat | grep -q '\[UU\]' && [ \"\$(cat /sys/block/$V/md/mismatch_cnt)\" = 0 ]"

# the initialization (CREATE_REDUNDANCY) of a new volume: stopped midway, the LD marked as 9.5 would; mdmon ends it
q42speed 2000
q42mk 2 2 256; sleep 4
check "42 init: the initialization is recorded" "q42sec | grep -q 'Transform : 0x5355'"
stopall
q42mark g0 g1
check "42 init: ... stopped midway, 0x20000000 in the LD ($(q42bit g0 g1 | tr '\n' ' '))" "! q42bit g0 g1 | grep -q '^0 '"
q42again g0 g1
V=$(mdof raid1)
check "42 init: ... mdmon ended it: normal, last 0x5355, no 0x20000000 left ($(q42bit g0 g1 | tr '\n' ' '))" "q42sec | grep -q 'State : 0x200 (normal)' && q42sec | grep -q 'Transform : 0x0, last 0x5355, state 0xa1a6' && [ \"\$(q42bit g0 g1 | cut -d' ' -f1 | tr '\n' ' ')\" = '0 0 ' ]"
echo check | sudo tee /sys/block/$V/md/sync_action >/dev/null; sleep 1; waitrec 120
check "42 init: ... the mirror agrees" "[ -n '$V' ] && [ \"\$(cat /sys/block/$V/md/mismatch_cnt)\" = 0 ]"
q42clean; rmdir $Q42
q42speed 400000
fi
# --- end of stage 42 ---

# --- stage 43: a check of a volume (CHECK_REDUNDANCY 0x5356) cut short in Windows is finished by md as an
# initialization.  A model without Windows: the initialization of a new volume (our -C: a pair of LDs and the transform
# log), recorded by mdmon, is stopped midway; in the live packet of each disk it is rewritten into a check as
# rcraid.sys 9.5.0.201 writes it midway: TransformType and LastOperation 0x5356, TransformState 0xa1a7, State 0x200,
# TransformFlags 0x241, Flags 0x20020626 / 0x30020022; the log - type 0x5356, flags 0x241, the same mark.  The volume
# was written during the initialization, so its copies agree everywhere, as on a volume being checked.  RAID1: garbage
# in copy [0][1] above the mark and below it.  Assembly: the volume runs read-write, md resyncs from the mark (above it
# puts things right, below it does not touch: the AMD driver checked there already), the end is recorded as the AMD
# driver records it (Transform 0, last 0x5356, 0xa1a6, one LD, the flags and TransformFlags cleared, the log wiped),
# a second assembly - no resync.  RAID5 - the same without garbage.
if want 43; then
cd "$MDADM_DIR"
Q43=$WQ/q43
q43l() { sudo losetup -j $Q43/$1.img | cut -d: -f1; }
q43sec() { $M -E $(q43l g0) 2>/dev/null | sed -n "/^\[$1\]/,/^\[/p"; }
q43speed() { local m=$(( $1 < 1000 ? $1 : 1000 ))
	echo $m | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null; echo $1 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null; }
q43clean() { stopall; for l in $(sudo losetup -a | grep "$Q43/" | cut -d: -f1); do sudo losetup -d $l; done; rm -f $Q43/*.img; }
# q43mk <disks> <level> <MiB per member> <name>: g0..., container q43c, a volume of all the disks; data written during
# the initialization (2 MB/s), then a stop midway through it
q43mk() {
	mkdir -p $Q43; q43clean
	for n in $(seq 0 $(($1 - 1))); do truncate -s 1G $Q43/g$n.img; sudo losetup -f $Q43/g$n.img; done
	q43speed 2000
	$M -C /dev/md/q43c -e amd -n$1 $(for n in $(seq 0 $(($1 - 1))); do q43l g$n; done) --run >/dev/null 2>&1
	$M -C /dev/md/$4 -e amd -l$2 -n$1 -z $3M $(for n in $(seq 0 $(($1 - 1))); do q43l g$n; done) --run >/dev/null 2>&1
	sleep 2; Q43V=$(mdof raid$2)
	sudo dd if=/dev/urandom of=/dev/$Q43V bs=1M oflag=direct status=none 2>/dev/null
	Q43MD5=$(sudo md5sum /dev/$Q43V | cut -c1-32); sleep 12
}
# q43lds <disk>: the LDs of the live packet - "name:TransformType:Last:TransformState:Flags:TransformFlags:Link" separated by spaces
q43lds() {
	python3 - $Q43/$1.img <<'PY'
import os, struct, sys
sys.path.insert(0, os.environ["TOOLS"]); import amdraid_dump as ad
dk = ad.Disk(sys.argv[1]); rc = ad.parse_raidcore(dk.read(ad.LBA_RAIDCORE)); c = ad.parse_commit(dk.read(rc["commit_lba"]))
h, pds, lds = ad.parse_gen(ad.read_gen(dk, c["gen_lba"], c["gen_len"]))
print(" ".join("%s:%x:%x:%x:%x:%x:%d" % (l["name"], l["transform"], l["last_op"], l["transform_state"], l["flags84"],
	struct.unpack_from("<I", l["raw_hdr"], 0x78)[0], l["linked_next"]) for l in lds))
PY
}
# q43log <disk>...: the transform log in the service sector of the volume's elements on the disk - "type:mark" or "-";
# q43start <disk>: the data start of its element (sectors)
q43tlog() {
	python3 - "$1" $(for n in $2; do echo $Q43/$n.img; done) <<'PY'
import os, struct, sys
sys.path.insert(0, os.environ["TOOLS"]); import amdraid_dump as ad
for p in sys.argv[2:]:
    dk = ad.Disk(p); rc = ad.parse_raidcore(dk.read(ad.LBA_RAIDCORE)); c = ad.parse_commit(dk.read(rc["commit_lba"]))
    h, pds, lds = ad.parse_gen(ad.read_gen(dk, c["gen_lba"], c["gen_len"]))
    el = [e for l in lds for e in l["elems"] if e["device_id"] == rc["device_id"]][:1]
    if sys.argv[1] == "start":
        print(el[0]["start"] if el else -1); continue
    s = dk.read(el[0]["alloc_off"]) if el else b"\0" * 512
    ok = any(s[8:0x68]) and struct.unpack_from("<Q", s, 0)[0] == ad.rc_sum(s, 8, 0x60)
    print("%x:%d" % (struct.unpack_from("<I", s, 0x18)[0], struct.unpack_from("<Q", s, 0x1c)[0]) if ok else "-")
PY
}
q43log() { q43tlog log "$*" | tr '\n' ' '; }
q43start() { q43tlog start $1; }
# q43check <disk>...: the initialization in the live packet and in the log made into a check, as rcraid.sys 9.5 has it midway
# through one; packet, commit and log sums valid.  Prints the marks of the logs
q43check() {
	python3 - $(for n in "$@"; do echo $Q43/$n.img; done) <<'PY'
import os, struct, sys
sys.path.insert(0, os.environ["TOOLS"]); import amdraid_dump as ad
for p in sys.argv[1:]:
    with open(p, "r+b") as f:
        f.seek(0x5000 * 512); dev = struct.unpack_from("<Q", f.read(512), 0x10)[0]
        f.seek(0x5001 * 512); c = bytearray(f.read(512)); off, size = struct.unpack_from("<II", c, 8)
        f.seek(off * 512); g = bytearray(f.read((size + 511) // 512 * 512)); q, end = struct.unpack_from("<II", g, 0x2c); end += q
        logs = set()
        while q + 0x200 <= end and struct.unpack_from("<I", g, q)[0] == 0x25BD:
            if struct.unpack_from("<I", g, q + 0x10)[0] == 0x5355:
                link = struct.unpack_from("<I", g, q + 0x88)[0]
                struct.pack_into("<I", g, q + 8, 0x200)
                struct.pack_into("<III", g, q + 0x10, 0x5356, 0x5356, 0xa1a7)
                struct.pack_into("<I", g, q + 0x78, 0x241)
                struct.pack_into("<I", g, q + 0x84, 0x20020626 if link else 0x30020022)
                logs |= {e["alloc_off"] for e in ad.parse_ld(g, q)["elems"] if e["device_id"] == dev}
            q += struct.unpack_from("<I", g, q + 0x90)[0]
        struct.pack_into("<Q", g, 0, ad.rc_sum(g, 0xc, size - 0xc)); f.seek(off * 512); f.write(g)
        struct.pack_into("<Q", c, 0x10, struct.unpack_from("<Q", g, 0)[0]); struct.pack_into("<Q", c, 0, ad.rc_sum(c, 8, 0x1f8))
        f.seek(0x5001 * 512); f.write(c)
        for lba in sorted(logs):
            f.seek(lba * 512); s = bytearray(f.read(512))
            if struct.unpack_from("<I", s, 0x18)[0] != 0x5355 or struct.unpack_from("<Q", s, 0)[0] != ad.rc_sum(s, 8, 0x60):
                continue
            struct.pack_into("<I", s, 0x18, 0x5356); struct.pack_into("<I", s, 0x30, 0x241)
            struct.pack_into("<Q", s, 0, ad.rc_sum(s, 8, 0x60)); f.seek(lba * 512); f.write(s)
            print(struct.unpack_from("<Q", s, 0x1c)[0])
PY
}
# q43junk <disk> <MiB of the volume>: 1 MiB of garbage into the volume's element on the disk (RAID1: volume MiB = element MiB)
q43junk() { sudo dd if=/dev/urandom of=$(q43l $1) bs=1M count=1 seek=$(( $(q43start $1) * 512 + $2 * 1048576 )) oflag=seek_bytes,direct conv=notrunc status=none; }
# q43same <MiB of the volume>: that MiB is the same on g0 and g1
q43same() { [ "$(sudo dd if=$(q43l g0) bs=1M count=1 skip=$(( $(q43start g0) * 512 + $1 * 1048576 )) iflag=skip_bytes,direct status=none | md5sum)" = \
	"$(sudo dd if=$(q43l g1) bs=1M count=1 skip=$(( $(q43start g1) * 512 + $1 * 1048576 )) iflag=skip_bytes,direct status=none | md5sum)" ]; }
# q43asm <disk>...: assemble the container of these disks (-A, -I)
q43asm() {
	q43speed 400000
	$M -A /dev/md/q43c -e amd $(for n in "$@"; do q43l $n; done) >/dev/null 2>&1
	$M -I /dev/$(cont1) >/dev/null 2>&1; sleep 2
}
q43nres() { sudo dmesg | grep -c 'md: resync of RAID array'; }
q43rw() { local m=$(cat /sys/block/$1/md/metadata_version 2>/dev/null); case "$m" in external:/*) [ "$(cat /sys/block/$1/md/array_state)" != readonly ] ;; *) false ;; esac; }
# q43ended <volume>: the end of the check recorded as the AMD driver records it: normal, Transform 0, last 0x5356, COMPLETED; one LD
# without the transform flags (mask AMD_LDF_TRANSFORM), TransformFlags 0, no TransformLink
q43ended() { local r n tt lo ts fl tf lk
	q43sec $1 | grep -q 'State : 0x200 (normal)' && q43sec $1 | grep -q 'Transform : 0x0, last 0x5356, state 0xa1a6' || return 1
	r=$(q43lds g0 | tr ' ' '\n' | grep "^$1:"); [ "$(echo "$r" | grep -c .)" = 1 ] || return 1
	IFS=: read n tt lo ts fl tf lk <<< "$r"
	[ $(( 0x$fl & 0x30020094 )) = 0 ] && [ "$tf" = 0 ] && [ "$lk" = 0 ]; }

# RAID1: a check midway, garbage in [0][1] above the mark and below it
q43mk 2 1 256 q43v; stopall
L=$(q43check g0 g1 | sort -n | head -1); L=${L:-0}; MK=$(( L / 2048 ))
check "43 raid1: Windows' check stopped midway, at MiB $MK of 256 ($(q43lds g0); log $(q43log g0 g1))" "q43sec q43v | grep -q 'Transform : 0x5356, last 0x5356, state 0xa1a7' && [ $MK -ge 8 ] && [ $MK -le 200 ] && q43log g0 g1 | grep -q '^5356:$L 5356:$L '"
LO=$(( MK / 2 )); q43junk g1 230; q43junk g1 $LO
R0=$(q43nres)
q43asm g0 g1; V=$(mdof raid1); waitrec 120; sleep 4
check "43 raid1: ... assembled read-write ($V: $(cat /sys/block/$V/md/metadata_version 2>/dev/null) $(cat /sys/block/$V/md/array_state 2>/dev/null)), md resynced it ($(( $(q43nres) - R0 )) resync)" "[ -n '$V' ] && q43rw $V && [ $(q43nres) -gt $R0 ]"
check "43 raid1: ... ended as AMD ends a check: normal, last 0x5356, one LD, transform flags clear ($(q43lds g0)), log cleared ($(q43log g0 g1))" "q43ended q43v && [ \"\$(q43log g0 g1)\" = '- - ' ]"
check "43 raid1: ... resynced from the log, as AMD resumes a check: the junk above it is gone, below it is left" "q43same 230 && ! q43same $LO"
echo repair | sudo tee /sys/block/$V/md/sync_action >/dev/null; sleep 1; waitrec 120
echo check | sudo tee /sys/block/$V/md/sync_action >/dev/null; sleep 1; waitrec 120
check "43 raid1: ... data as before (md5 ${Q43MD5:0:8}), md check 0" "[ \"\$(sudo md5sum /dev/$V | cut -c1-32)\" = $Q43MD5 ] && [ \"\$(cat /sys/block/$V/md/mismatch_cnt)\" = 0 ]"
stopall; R0=$(q43nres); q43asm g0 g1; V=$(mdof raid1); waitrec 60
check "43 raid1: ... assembled again: no resync, still ended" "[ -n '$V' ] && q43rw $V && [ $(q43nres) = $R0 ] && [ \"\$(cat /sys/block/$V/md/resync_start)\" = none ] && q43ended q43v"

# RAID5: the same without garbage (md puts the parity right from the data - garbage in the data would not show)
q43mk 3 5 128 q43r; stopall
L=$(q43check g0 g1 g2 | sort -n | head -1); L=${L:-0}; MK=$(( L / 2048 ))
check "43 raid5: Windows' check stopped midway, at MiB $MK of 256 ($(q43lds g0); log $(q43log g0 g1 g2))" "q43sec q43r | grep -q 'Transform : 0x5356, last 0x5356, state 0xa1a7' && [ $MK -ge 8 ] && [ $MK -le 200 ]"
R0=$(q43nres)
q43asm g0 g1 g2; V=$(mdof raid5); waitrec 120; sleep 4
check "43 raid5: ... assembled read-write ($V: $(cat /sys/block/$V/md/metadata_version 2>/dev/null)), md resynced it, ended as AMD ends a check ($(q43lds g0); log $(q43log g0 g1 g2))" "[ -n '$V' ] && q43rw $V && [ $(q43nres) -gt $R0 ] && q43ended q43r && [ \"\$(q43log g0 g1 g2)\" = '- - - ' ]"
echo check | sudo tee /sys/block/$V/md/sync_action >/dev/null; sleep 1; waitrec 120
check "43 raid5: ... data as before (md5 ${Q43MD5:0:8}), md check 0" "[ \"\$(sudo md5sum /dev/$V | cut -c1-32)\" = $Q43MD5 ] && [ \"\$(cat /sys/block/$V/md/mismatch_cnt)\" = 0 ]"
stopall; R0=$(q43nres); q43asm g0 g1 g2; V=$(mdof raid5); waitrec 60
check "43 raid5: ... assembled again: no resync, still ended" "[ -n '$V' ] && q43rw $V && [ $(q43nres) = $R0 ] && [ \"\$(cat /sys/block/$V/md/resync_start)\" = none ] && q43ended q43r"
q43clean; rmdir $Q43
q43speed 400000
fi
# --- end of stage 43 ---

# --- stage 44: -C of a Volume (linear) on a kernel with no md linear.  md linear is a module of its own, and Debian 13
# and Ubuntu 24.04 do not ship it.  -C used to write the volume into the AMD configuration and then fail on array_state
# ("failed to activate array"), leaving the volume there; now it loads md-linear as md would and refuses before
# writing.  On a kernel with md linear the volume is created and runs.
if want 44; then
cd "$MDADM_DIR"
stopall
Q44=$WQ/q44
q44drop() { stopall; for l in $(sudo losetup -a | grep $Q44/ | cut -d: -f1); do sudo losetup -d $l; done; rm -f $Q44/*.img; }
mkdir -p $Q44; q44drop
QL=""; for n in 0 1; do truncate -s 1G $Q44/d$n.img; QL="$QL $(sudo losetup -f --show $Q44/d$n.img)"; done
QL=${QL# }; Q1=${QL%% *}
q44gen() { $M -E $Q1 2>/dev/null | sed -n 's/^ *Generation : //p'; }
q44vols() { $M -E $Q1 2>/dev/null | grep -c '^\['; }
if grep -q '\[linear\]' /proc/mdstat || sudo modprobe -n md-linear 2>/dev/null; then LIN=1; else LIN=0; fi
$M -C /dev/md/q44c -e amd -n 2 $QL --run >/dev/null 2>&1; CN=$(cont1); G0=$(q44gen)
OUT=$($M -C /dev/md/q44v -l linear -n2 -z 64M /dev/$CN --run 2>&1); RC=$?
if [ $LIN = 0 ]; then
check "44: kernel without md linear: -C Volume in the container: refused, said, nothing written" "[ $RC != 0 ] && echo \"\$OUT\" | grep -q 'this kernel has no md linear' && [ \$(q44vols) = 0 ] && [ \"\$(q44gen)\" = '$G0' ]"
OUT=$($M -C /dev/md/q44v -e amd -l linear -n2 -z 64M $QL --run 2>&1); RC=$?
check "44: ... -C -e amd Volume, the disks given: refused, said, nothing written" "[ $RC != 0 ] && echo \"\$OUT\" | grep -q 'this kernel has no md linear' && [ \$(q44vols) = 0 ] && [ \"\$(q44gen)\" = '$G0' ]"
V0=$(q44vols); OUT=$($M -C /dev/md/q44r -l0 -n2 -z 64M /dev/$CN --run 2>&1); RC=$?
check "44: ... RAID0 in the same container: created" "[ $RC = 0 ] && [ \$(q44vols) = $((V0 + 1)) ] && grep -q '^md.* : active raid0' /proc/mdstat"
else
check "44: kernel with md linear: -C Volume: created and running" "[ $RC = 0 ] && [ \$(q44vols) = 1 ] && grep -q '^md.* : active linear' /proc/mdstat"
fi
q44drop; rmdir $Q44
fi
# --- end of stage 44 ---

# --- stage 45: --detail-platform: the controllers AMD RAID takes (the EFI variable AMD_RAID), their disks with serial
# numbers, the limits of -C; --export; a controller path as the argument; without AMD_RAID, exit status 2.  Create asks
# every metadata detail_platform(enumerate_only) and warns without a platform: AMD always answers 0 there, so -C of a
# container of images (loop devices) does not say "unable to enumerate platform support".
if want 45; then
cd "$MDADM_DIR"
stopall
AV=/sys/firmware/efi/efivars/AMD_RAID-fe26a894-d199-47d4-8afa-070e3d54ba86
if [ -e $AV ]; then
RAW=$(od -An -tx1 -j4 -N1 $AV | tr -d ' '); RAW=$((16#$RAW))
OUT=$(sudo $M --detail-platform -e amd 2>&1); RC=$?
AMDD=$(lsblk -dno NAME,SERIAL | awk '$2 ~ /^AMD(SATA|NVME)/ {print $1 "(" $2 ")"}')
q45has() { local d; for d in $AMDD; do echo "$OUT" | tr -d ' ' | grep -q "Disk:/dev/${d}\$" || return 1; done; }
# each disk listed is behind the controller it is listed under
q45behind() {
	local c= l d
	while IFS= read -r l; do
		case "$l" in
		*"I/O Controller : "*) c=$(echo "$l" | sed 's/.*I\/O Controller : \([^ ]*\) .*/\1/') ;;
		*" Disk : /dev/"*) d=$(echo "$l" | sed 's/.* Disk : \/dev\/\([^ ]*\).*/\1/')
			readlink -f /sys/block/$d | grep -q "^$c/" || return 1 ;;
		esac
	done <<< "$OUT"
}
check "45: --detail-platform -e amd: rc 0, Platform, AMD_RAID 0x$(printf %x $RAW), $(echo "$OUT" | grep -c 'I/O Controller') controllers, $(echo "$OUT" | grep -c ' Disk : ') disks, each behind its controller; the disks AMDSATA*/AMDNVME* with serials ($(echo $AMDD | wc -w))" "[ $RC = 0 ] && echo \"\$OUT\" | grep -q '^ *Platform : AMD RAIDXpert2' && echo \"\$OUT\" | grep -q '^ *AMD_RAID : 0x$(printf %x $RAW):' && [ \$(echo \"\$OUT\" | grep -c 'I/O Controller') -ge 1 ] && q45behind && q45has"
EX=$(sudo $M --detail-platform -e amd --export 2>&1); RC=$?
check "45: ... --export: MD_FIRMWARE_TYPE=amd, AMD_RAID, levels, chunk sizes" "[ $RC = 0 ] && echo \"\$EX\" | grep -qx 'MD_FIRMWARE_TYPE=amd' && echo \"\$EX\" | grep -qx 'AMD_RAID=0x$(printf %x $RAW)' && echo \"\$EX\" | grep -qx 'AMD_SUPPORTED_CHUNK_SIZES=64k 128k 256k'"
C1=$(echo "$OUT" | sed -n 's/^ *I\/O Controller : \([^ ]*\) .*/\1/p' | head -1)
O1=$(sudo $M --detail-platform -e amd $C1 2>&1); RC=$?
check "45: ... the controller $C1 given: rc 0, only it" "[ $RC = 0 ] && [ \$(echo \"\$O1\" | grep -c 'I/O Controller') = 1 ] && echo \"\$O1\" | grep -q 'I/O Controller : $C1 '"
VP=$(readlink -f /sys/bus/pci/devices/0000:00:00.0 2>/dev/null)	# the host bridge: no disks behind it
O2=$(sudo $M --detail-platform -e amd -v $VP 2>&1); RC=$?
check "45: ... a controller AMD RAID does not take ($VP): rc 2, said" "[ -n '$VP' ] && [ $RC = 2 ] && echo \"\$O2\" | grep -q 'no controller AMD RAID takes'"
else
OUT=$(sudo $M --detail-platform -e amd -v 2>&1); RC=$?
check "45: no EFI variable AMD_RAID: --detail-platform -e amd: rc 2, said" "[ $RC = 2 ] && echo \"\$OUT\" | grep -q 'AMD RAID is off in the firmware'"
fi
Q45=$WQ/q45
q45drop() { stopall; for l in $(sudo losetup -a | grep $Q45/ | cut -d: -f1); do sudo losetup -d $l; done; rm -f $Q45/*.img; }
mkdir -p $Q45; q45drop
QL=""; for n in 0 1; do truncate -s 1G $Q45/d$n.img; QL="$QL $(sudo losetup -f --show $Q45/d$n.img)"; done
OUT=$($M -C /dev/md/q45c -e amd -n 2 $QL --run 2>&1); RC=$?
check "45: -C of a container of images: no 'unable to enumerate platform support'" "[ $RC = 0 ] && ! echo \"\$OUT\" | grep -q 'unable to enumerate platform'"
q45drop; rmdir $Q45
fi
# --- end of stage 45 ---

# --- stage 46: a write of mdmon that keeps failing is told once in the kernel log, not once a pass of the monitor, and
# once more when it goes through again.  A RAID1 on two dm-linear devices; the sector of the AMD bitmap (AllocatedSpace
# + 0x80 of element [0][0]) is switched to an error target while it runs; 4 writes, each followed by a pause longer
# than safe_mode_delay (each makes the volume dirty and mdmon write the AMD bitmap); then the table as it was, one more.
if want 46; then
cd "$MDADM_DIR"
stopall
Q46=$WQ/q46
q46drop() { stopall; for n in 0 1; do sudo dmsetup remove q46d$n 2>/dev/null; done
	for l in $(sudo losetup -a | grep $Q46/ | cut -d: -f1); do sudo losetup -d $l; done; rm -f $Q46/*.img; }
mkdir -p $Q46; q46drop
for n in 0 1; do
	truncate -s 1G $Q46/d$n.img; L=$(sudo losetup -f --show $Q46/d$n.img); eval Q46L$n=$L
	echo "0 $(sudo blockdev --getsz $L) linear $L 0" | sudo dmsetup create q46d$n
done
QS=$(sudo blockdev --getsz $Q46L0)
$M -C /dev/md/q46c -e amd -n 2 /dev/mapper/q46d0 /dev/mapper/q46d1 --run >/dev/null 2>&1
$M -C /dev/md/q46v -l1 -n2 -z 128M /dev/$(cont1) --run --assume-clean >/dev/null 2>&1; sleep 2
V=$(mdof raid1)
OFF=$($M -E /dev/mapper/q46d0 2>/dev/null | sed -n 's/.* Member *0 : .* offset \([0-9]*\) .*/\1/p' | head -1)
# -E gives the user data offset; AllocatedSpace (AMD_SERVICE, 0x5000) is in front of it, the AMD bitmap at + 0x80
BL=$(( ${OFF:-0} - 0x5000 + 0x80 ))
# q46tab <n> <bad>: the table of q46d<n>, the sector of the AMD bitmap an error target if <bad> = 1
q46tab() { local L; eval L=\$Q46L$1
	if [ $2 = 1 ]; then printf '0 %d linear %s 0\n%d 1 error\n%d %d linear %s %d\n' $BL $L $BL $((BL + 1)) $((QS - BL - 1)) $L $((BL + 1))
	else echo "0 $QS linear $L 0"; fi | sudo dmsetup reload q46d$1 && sudo dmsetup resume q46d$1; }
# q46io <n>: <n> writes to the volume, each followed by a pause longer than its safe_mode_delay: md has it clean
# again, so each write makes it dirty and mdmon write the AMD bitmap
SMD=$(cut -d. -f1 /sys/block/$V/md/safe_mode_delay 2>/dev/null)
q46io() { local i; for i in $(seq $1); do
	sudo dd if=/dev/zero of=/dev/$V bs=64k count=8 seek=$((RANDOM % 1000)) oflag=direct conv=notrunc 2>/dev/null
	sleep $(( ${SMD:-4} + 2 )); done; }
sudo dmesg -C
q46tab 0 1; q46tab 1 1
q46io 4
NB=$(sudo dmesg | grep -c 'amd: cannot write the bitmap of subarray')
check "46: a write of the AMD bitmap failing at 4 writes ($V, LBA $BL, safe_mode_delay ${SMD}s): told once in the kernel log ($NB lines; was one a write)" "[ -n '$V' ] && [ -n '$OFF' ] && [ $NB = 1 ]"
q46tab 0 0; q46tab 1 0
q46io 1
# mdmon writes the bitmap at the volume's next state change; on a loaded host that can come a few seconds late
for i in $(seq 1 20); do NA=$(sudo dmesg | grep -c 'amd: the bitmap of subarray-[0-9]* is written again'); [ $NA = 0 ] || break; sleep 1; done
check "46: ... the write goes through again: told once ($NA), no more failures" "[ $NA = 1 ] && [ \$(sudo dmesg | grep -c 'amd: cannot write the bitmap of subarray') = $NB ]"
q46drop; rmdir $Q46
fi
# --- end of stage 46 ---

# --- stage 47: volumes after AMD migrations.  rcadm -T, adding disks, moves the data of each element from AllocatedSpace
# + 0x5000 to + 0x800, and they stay there; 1.3 did not assemble such volumes ("member extents are not where AMD puts
# them").  Snapshots of fixtures/2026-11-15-rcraid-migrations (rcraid 9.3.3-00302; metadata only, the data zeroes):
# after a migration, the volumes are assembled, at + 0x800; in the middle of one, not assembled, as before; mdmon on
# a RAID5 at + 0x800: written, stopped, assembled again - the data as written, AMD's data log (+ 0x600..+ 0x800 of
# each element) untouched.
if want 47; then
cd "$MDADM_DIR"
stopall
Q47=$WQ/q47; Q47D=$FIXT/2026-11-15-rcraid-migrations
q47drop() { stopall; for l in $(sudo losetup -a | grep $Q47/ | cut -d: -f1); do sudo losetup -d $l; done; rm -f $Q47/*.img; }
mkdir -p $Q47
# q47mk <snapshot>: its five disks (8 GiB) as loop devices in Q47L, the metadata and transform log sectors of the dump
q47mk() { local f n b lba; q47drop; Q47L=""
	for f in $Q47D/$1-sata*-lba0-6000.img.xz; do
		n=$(basename $f | sed 's/.*-sata\([0-9]\)-.*/\1/')
		truncate -s 8G $Q47/s$n.img; xz -dc $f | dd of=$Q47/s$n.img conv=notrunc status=none
		for b in $Q47D/$1-sata$n-lba0x*.bin; do
			[ -e "$b" ] || continue; lba=$(basename $b .bin | sed 's/.*-lba0x//')
			dd if=$b of=$Q47/s$n.img bs=512 seek=$((16#$lba)) conv=notrunc status=none
		done
		Q47L="$Q47L $(sudo losetup -f --show $Q47/s$n.img)"
	done
	for l in $Q47L; do $M -I $l >/dev/null 2>&1; done; sleep 2; }
# q47vol <level> <disks> [<offset>]: md of an assembled volume of <level> on <disks>, each member at <offset> if given
q47vol() { local m; for m in $(mdof $1); do [ "$(cat /sys/block/$m/md/raid_disks)" = $2 ] || continue
	[ -z "${3:-}" ] || [ "$(cat /sys/block/$m/md/dev-*/offset | sort -u)" = $3 ] || continue; echo $m; done; }
q47mk q8m-e1post
check "47: RAID0 2 -> 3 disks (rcadm -T -r0, data moved to + 0x800): assembled, members at 0x100800" "[ -n \"\$(q47vol raid0 3 $((0x100800)))\" ]"
q47mk q8m-e1cpost
check "47: ... grown again to 4 disks (data already at + 0x800): assembled" "[ -n \"\$(q47vol raid0 4 $((0x100800)))\" ]"
q47mk q8m-e3apost
check "47: RAID0 2 x 1 -> RAID10 2 x 2 (+ 0x5000 and new elements): assembled" "[ -n \"\$(q47vol raid10 4)\" ]"
q47mk q8m-e3bpost
check "47: RAID1 1 x 2 -> RAID5 3 disks (data to + 0x800): assembled" "[ -n \"\$(q47vol raid5 3)\" ]"
q47mk q8m-e3dpost
check "47: RAID1 1000 -> 2000 MB in place: assembled" "[ -n \"\$(q47vol raid1 2)\" ]"
q47mk q8m-e2mid
check "47: RAID5 3 -> 4 disks, in the middle of the migration: assembled, md reshaping it on" "[ -n \"\$(mdof raid5)\" ]"
q47mk q8m-e1cmid
check "47: RAID0 3 -> 4 disks, in the middle (data already at + 0x800): assembled, md reshaping it on in place" "[ -n \"\$(mdof raid4)\" ]"
q47mk q8m-e2post
V=$(q47vol raid5 4 $((0x2e2800)))
check "47: RAID5 3 -> 4 disks, 2862 -> 5724 MiB (data to + 0x800): assembled, members at 0x2e2800 ($V)" "[ -n '$V' ]"
# the AMD data log of each element: AllocatedSpace + 0x600 .. + 0x800 (0x2e2600..0x2e2800 on the four disks)
q47log() { local l; for l in $(echo $Q47L | cut -d' ' -f1-4); do sudo dd if=$l bs=512 skip=$((0x2e2600)) count=512 status=none; done | md5sum | cut -c1-32; }
L0=$(q47log)
sudo dd if=/dev/urandom of=$Q47/pat bs=1M count=8 status=none
sudo dd if=$Q47/pat of=/dev/$V bs=1M seek=100 oflag=direct status=none; sleep 3
stopall; for l in $Q47L; do $M -I $l >/dev/null 2>&1; done; sleep 2; V=$(q47vol raid5 4 $((0x2e2800)))
check "47: ... mdmon on it: written, stopped, assembled again: the data as written, clean, the AMD data log untouched" "[ -n '$V' ] && [ \"\$(sudo dd if=/dev/$V bs=1M skip=100 count=8 status=none | md5sum | cut -c1-32)\" = \"\$(md5sum < $Q47/pat | cut -c1-32)\" ] && [ \"\$(cat /sys/block/$V/md/resync_start)\" = none ] && [ \"\$(q47log)\" = $L0 ]"
q47drop; rm -f $Q47/pat; rmdir $Q47
fi
# --- end of stage 47 ---

# Helpers of stages 48, 49, 51, 53, 54, 55.
# qgdrop / qgmk <dir> <disks> <GiB>: images d0...d<n-1> in $WQ/<dir> anew, loop devices in QGL (in order)
qgdrop() { stopall; for l in $(sudo losetup -a | grep "$WQ/$1/" | cut -d: -f1); do sudo losetup -d $l; done; rm -rf $WQ/$1; }
qgmk() { local n; qgdrop $1; mkdir -p $WQ/$1; QGL=""
	for n in $(seq 0 $(($2 - 1))); do truncate -s ${3}G $WQ/$1/d$n.img; QGL="$QGL $(sudo losetup -f --show $WQ/$1/d$n.img)"; done; }
qgl() { echo $QGL | cut -d' ' -f$(($1 + 1)); }	# loop device of disk d<n>
# md of a volume by name: /dev/md/<name> after -C, /dev/md/<name>_0 after -I
qgmd() { local p; for p in /dev/md/$1 /dev/md/${1}_0; do [ -e $p ] && { basename $(readlink -f $p); return; }; done; }
qgasm() { local l; for l in $QGL; do $M -I $l >/dev/null 2>&1; done; sleep 2; }
# qgld <image> <LD ID hex> [<packet number>]: the records of the LD of this ID in the live packet (or in the packet of the
# ring with this number), a line a record: the transform fields and the elements id:alloc+size:data+size:flags (hex)
qgld() {
	python3 - "$@" <<'PY'
import struct, sys
img, ldid = sys.argv[1], int(sys.argv[2], 16)
f = open(img, "rb")
def packet(off, size):
    f.seek(off * 512); return f.read(size)
if len(sys.argv) > 3:
    gen, p = int(sys.argv[3]), None
    f.seek(0x5800 * 512); ring = f.read(0x800 * 512); lba = 0
    while lba < 0x800:
        o = lba * 512
        if struct.unpack_from("<Q", ring, o + 0xc)[0] != 0xe1e10000: lba += 1; continue
        size = struct.unpack_from("<I", ring, o + 0x18)[0]
        if not 0x200 <= size <= 0x100000: lba += 1; continue
        if struct.unpack_from("<Q", ring, o + 0x34)[0] == gen: p = ring[o:o + size]
        lba += (size + 511) // 512
    if p is None: sys.exit(0)
else:
    f.seek(0x5001 * 512); c = f.read(512); p = packet(*struct.unpack_from("<II", c, 8))
q, end = struct.unpack_from("<II", p, 0x2c); end += q
while q + 0x200 <= end and struct.unpack_from("<I", p, q)[0] == 0x25BD:
    sz = struct.unpack_from("<I", p, q + 0x90)[0]
    if not sz: break
    ld = p[q:q + sz]; q += sz
    if struct.unpack_from("<Q", ld, 0x2c)[0] != ldid: continue
    u = lambda o: struct.unpack_from("<I", ld, o)[0]
    Q = lambda o: struct.unpack_from("<Q", ld, o)[0]
    fc, sc = u(0x6c), u(0x70)
    out = ["type=%x" % u(0xc), "st=%x" % u(0x8), "tt=%x" % u(0x10), "lo=%x" % u(0x14), "ts=%x" % u(0x18),
           "cap=%x" % Q(0x50), "ps=%x" % Q(0x58), "gen=%x" % Q(0x60), "fs=%dx%d" % (fc, sc), "tf=%x" % u(0x78),
           "psz=%x" % u(0x7c), "fl=%x" % u(0x84), "lk=%x" % u(0x88), "pct=%x" % u(0x94), "at=%x" % u(0x98)]
    for e in range(fc * sc):
        b = ld[0x200 + 0x40 * e: 0x240 + 0x40 * e]
        dev = struct.unpack_from("<Q", b, 0)[0]
        at, size, data, dsize = struct.unpack_from("<QQQQ", b, 0x10)
        out.append("e%d=%x:%x+%x:%x+%x:%x" % (e, dev & 0xffff, at, size, data, dsize, struct.unpack_from("<I", b, 0x30)[0]))
    print(" ".join(out))
PY
}
# qgfix <dir> <fixture dir> <snapshot>: the snapshot's five disks (metadata and transform log sectors, 8 GiB) in
# $WQ/<dir>, loop devices in QGL
qgfix() { local n b l; qgdrop $1; mkdir -p $WQ/$1; QGL=""
	for n in 0 1 2 3 4; do truncate -s 8G $WQ/$1/d$n.img
		xz -dc $2/$3-sata$n-lba0-6000.img.xz | dd of=$WQ/$1/d$n.img conv=notrunc status=none
		for b in $2/$3-sata$n-lba0x*.bin; do [ -e "$b" ] || continue; l=${b##*-lba}; l=${l%.bin}
			dd if=$b of=$WQ/$1/d$n.img bs=512 seek=$((l)) conv=notrunc status=none; done
		QGL="$QGL $(sudo losetup -f --show $WQ/$1/d$n.img)"; done; }
qgids() { python3 $TOOLS/amdraid_dump.py --brief $1 2>/dev/null | sed -n 's/^  Array [0-9]* \([0-9a-f]*\) .*/\1/p'; }	# volume IDs
# qgtlog <loop> <LBA>: the transform log - type, ProtectStart, status, IOSize, flags, ProtectSize, DynProtStripe (hex)
qgtlog() { sudo dd if=$1 bs=512 skip=$(($2)) count=1 status=none | python3 -c '
import sys, struct
b = sys.stdin.buffer.read()
print("%x %x %x %x %x %x %x" % (struct.unpack_from("<I", b, 0x18)[0], struct.unpack_from("<Q", b, 0x1c)[0], struct.unpack_from("<I", b, 0x44)[0], struct.unpack_from("<I", b, 0x2c)[0], struct.unpack_from("<I", b, 0x30)[0], struct.unpack_from("<I", b, 0x34)[0], struct.unpack_from("<I", b, 0x3c)[0]))'; }
qgring() { python3 $TOOLS/amdraid_dump.py --brief --ring $1 2>/dev/null | grep -o 'seq [0-9]*' | cut -d' ' -f2; }	# packet numbers of the ring

# --- stage 48: growing the capacity in place: mdadm --grow <volume> --size=<KiB>|max - as rcadm -T -s does it
# (fixtures 2026-11-15-rcraid-migrations, q8m-e3dpost): the elements grow in place, the data stay where they are; a start
# packet (two LDs: the volume NORMAL, 0x2024241, protect 0x4800, Flags 0x20010, Link 1; the new one, larger, the packet's
# generation), the progress log (from the old capacity), "100 %", the log zeroed, the final packet. md resyncs the
# grown part (from the old size), an interrupted growth goes on from the log. Refused: no room (another volume right
# behind), smaller, RAID0, the container.
if want 48; then
cd "$MDADM_DIR"
stopall
qgmk q48 4 2
$M -C /dev/md/amd48 -e amd -n 4 $QGL --run >/dev/null 2>&1; CN=$(cont1)
$M -C /dev/md/a48 -e amd -l1 -n2 -z 256M $(qgl 0) $(qgl 1) --run >/dev/null 2>&1
$M -C /dev/md/b48 -e amd -l1 -n2 -z 256M $(qgl 0) $(qgl 1) --run >/dev/null 2>&1
$M -C /dev/md/z48 -e amd -l0 -n2 -z 64M $(qgl 2) $(qgl 3) --run >/dev/null 2>&1
sleep 1; waitrec
A=$(qgmd a48); B=$(qgmd b48); Z=$(qgmd z48)
BID=$(python3 $TOOLS/amdraid_dump.py --brief $WQ/q48/d0.img 2>/dev/null | sed -n 's/^  Array 2 \([0-9a-f]*\) .*/\1/p')
check "48: a RAID1 with the next volume right behind its members: refused, no room in place" "$M --grow /dev/$A --size=max 2>&1 | grep -q 'AMD makes a volume larger only, .*no more room where they are' && $M --grow /dev/$A --size=1G 2>&1 | grep -q '256 MiB a member at most: AMD grows the members in place'"
check "48: smaller, RAID0, the container: refused" "$M --grow /dev/$B --size=128M 2>&1 | grep -q 'AMD makes a volume larger only' && $M --grow /dev/$Z --size=128M 2>&1 | grep -q 'not supported for RAID0' && refused $M --grow /dev/$CN --size=128M >/dev/null 2>&1"
head -c 32M /dev/urandom > $WQ/q48/pat; sudo dd if=$WQ/q48/pat of=/dev/$B bs=1M oflag=direct status=none
# a migration the volume is read-auto for: md takes the size of a writable array only (Grow.c)
stopall; qgasm; B=$(qgmd b48)
G0=$(qgring $WQ/q48/d0.img | tail -1)
echo 3000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
OUT=$($M --grow /dev/$B --size=1200M 2>&1); sleep 3
check "48: --size=1200M of the RAID1 behind it (read-auto): md 1200 MiB a member, resyncing from 256 MiB" "echo \"\$OUT\" | grep -q '256 -> 1200 MiB a member' && [ \$(cat /sys/block/$B/md/component_size) = $((1200 * 1024)) ] && [ \$(cat /sys/block/$B/md/sync_action) = resync ] && [ \$(cut -d' ' -f1 /sys/block/$B/md/sync_completed) -ge $((256 * 2048)) ]"
S1=$(qgld $WQ/q48/d0.img $BID $((G0 + 1)))
check "48: start packet (the next one): the RAID1 NORMAL 0x2024241, protect 0x4800, Flags 0x20010, Link 1; the one it becomes - TransformType 0, LastOperation NORMAL, 0x2024241, 1200 MiB, generation of the packet, extents grown in place (as rcadm -T -s, q8m-e3dpost)" "[ \$(echo \"\$S1\" | wc -l) = 2 ] && echo \"\$S1\" | head -1 | grep -q 'tt=5354 lo=5354 ts=0 cap=80000 ps=0 .* tf=2024241 psz=4800 fl=20010 lk=1 pct=0 at=1' && echo \"\$S1\" | tail -1 | grep -q \"tt=0 lo=5354 ts=0 cap=258000 ps=0 gen=$(printf %x $((G0 + 1))) fs=1x2 tf=2024241 psz=0 fl=0 lk=0 pct=0 at=1 e0=[0-9a-f]*:185000+25d000:18a000+258000:0 e1=[0-9a-f]*:185000+25d000:18a000+258000:0\""
check "48: the log first: NORMAL, STARTED a region below the old capacity's (0x7e000; stage 70), I/O 0x600, 12 to the region, on both members" "T=\$(qgtlog $(qgl 0) 0x185000); [ \"\$T\" = \"\$(qgtlog $(qgl 1) 0x185000)\" ] && echo \"\$T\" | grep -qE '^5354 [0-9a-f]+ 1 600 2024241 4800 c$' && [ \$((0x\$(echo \$T | cut -d' ' -f2))) = $((0x7e000 - 0x4800)) ]"
sleep 6; $M -S /dev/$B >/dev/null 2>&1; sleep 1
T=$(qgtlog $(qgl 0) 0x185000); D=$((0x$(echo $T | cut -d' ' -f2)))
check "48: stopped midway: the log is on, from a region below the old capacity's on, at a region; -E says the migration" "[ \"\$T\" = \"\$(qgtlog $(qgl 1) 0x185000)\" ] && [ $D -ge $((0x7e000 - 0x4800)) ] && [ $((D % 0x4800)) = 0 ] && $M -E $(qgl 0) | grep -q 'Migration : RAID10N 1 x 2, 256 MiB -> RAID10N 1 x 2, 1200 MiB; [0-9]*% done'"
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
$M -I /dev/$CN >/dev/null 2>&1; sleep 1; B=$(qgmd b48)
check "48: assembled again: 1200 MiB a member, md resyncs from the log ($D)" "[ \$(cat /sys/block/$B/md/component_size) = $((1200 * 1024)) ] && [ \$(cut -d' ' -f1 /sys/block/$B/md/sync_completed) -ge $D ]"
waitrec; sleep 3
G1=$(qgring $WQ/q48/d0.img | tail -1)
P100=$(qgld $WQ/q48/d0.img $BID $((G1 - 1))); PF=$(qgld $WQ/q48/d0.img $BID $G1)
check "48: \"100 %\" packet (the RAID1 COMPLETED at 1200 MiB, 100000, Flags 0x84; the new one NORMAL STARTED as far), then the final one: one LD, 1200 MiB, LastOperation NORMAL COMPLETED, generation as made; log cleared on both" "echo \"\$P100\" | head -1 | grep -q 'tt=5354 lo=5354 ts=a1a6 cap=80000 ps=258000 .* psz=0 fl=84 lk=1 pct=186a0' && echo \"\$P100\" | tail -1 | grep -q 'tt=5354 lo=5354 ts=a1a1 cap=258000 ps=258000 .* pct=186a0' && [ \$(echo \"\$PF\" | wc -l) = 1 ] && echo \"\$PF\" | grep -q \"st=200 tt=0 lo=5354 ts=a1a6 cap=258000 ps=0 gen=$(printf %x $((G0 + 1))) fs=1x2 tf=0 psz=0 fl=0 lk=0 pct=0 at=1\" && [ \"\$(qgtlog $(qgl 0) 0x185000)\" = '0 0 0 0 0 0 0' ] && [ \"\$(qgtlog $(qgl 1) 0x185000)\" = '0 0 0 0 0 0 0' ]"
echo check | sudo tee /sys/block/$B/md/sync_action >/dev/null; sleep 1; waitrec
check "48: done: the data as written, md check 0" "cmp -s $WQ/q48/pat <(sudo dd if=/dev/$B bs=1M count=32 iflag=direct status=none) && [ \$(cat /sys/block/$B/md/mismatch_cnt) = 0 ]"
stopall; qgasm; B=$(qgmd b48)
check "48: assembled again: 1200 MiB, no resync" "[ \$(cat /sys/block/$B/size) = $((1200 * 2048)) ] && ! grep -A3 \"^$B \" /proc/mdstat | grep -qE 'resync|recovery'"
# RAID5 of 3, RAID10 of 4: --size=max, to the end of the disks
qgmk q48 4 2
$M -C /dev/md/amd48 -e amd -n 4 $QGL --run >/dev/null 2>&1; CN=$(cont1)
$M -C /dev/md/c48 -e amd -l5 -n3 -z 128M $(qgl 0) $(qgl 1) $(qgl 2) --run >/dev/null 2>&1; sleep 1; waitrec
C5=$(qgmd c48); head -c 32M /dev/urandom > $WQ/q48/pat; sudo dd if=$WQ/q48/pat of=/dev/$C5 bs=1M oflag=direct status=none
OUT=$($M --grow /dev/$C5 --size=max 2>&1); sleep 2; waitrec; sleep 3
CID=$(qgids $WQ/q48/d0.img | head -1)
check "48: RAID5 of 3 --size=max: 128 -> 1526 MiB a member (the disks' end), synced, one LD NORMAL, 3052 MiB, data as written" "echo \"\$OUT\" | grep -q '128 -> 1526 MiB a member' && [ \$(cat /sys/block/$C5/size) = $((3052 * 2048)) ] && qgld $WQ/q48/d0.img $CID | grep -q 'st=200 tt=0 lo=5354 ts=a1a6 cap=5f6000 .* fs=1x3 tf=0' && cmp -s $WQ/q48/pat <(sudo dd if=/dev/$C5 bs=1M count=32 iflag=direct status=none)"
echo check | sudo tee /sys/block/$C5/md/sync_action >/dev/null; sleep 1; waitrec
check "48: RAID5: md check 0" "[ \$(cat /sys/block/$C5/md/mismatch_cnt) = 0 ]"
qgmk q48 4 2
$M -C /dev/md/amd48 -e amd -n 4 $QGL --run >/dev/null 2>&1; CN=$(cont1)
$M -C /dev/md/d48 -l10 -n4 -z 128M /dev/$CN --run >/dev/null 2>&1; sleep 1; waitrec
R10=$(qgmd d48); head -c 32M /dev/urandom > $WQ/q48/pat; sudo dd if=$WQ/q48/pat of=/dev/$R10 bs=1M oflag=direct status=none
OUT=$($M --grow /dev/$R10 --size=max 2>&1); sleep 2; waitrec; sleep 3
DID=$(qgids $WQ/q48/d0.img | head -1)
echo check | sudo tee /sys/block/$R10/md/sync_action >/dev/null; sleep 1; waitrec
check "48: RAID10 2 x 2 --size=max: 1526 MiB a member, synced, one LD NORMAL, 3052 MiB, data as written, md check 0" "echo \"\$OUT\" | grep -q '128 -> 1526 MiB a member' && [ \$(cat /sys/block/$R10/size) = $((3052 * 2048)) ] && qgld $WQ/q48/d0.img $DID | grep -q 'st=200 tt=0 lo=5354 ts=a1a6 cap=5f6000 .* fs=2x2 tf=0' && cmp -s $WQ/q48/pat <(sudo dd if=/dev/$R10 bs=1M count=32 iflag=direct status=none) && [ \$(cat /sys/block/$R10/md/mismatch_cnt) = 0 ]"
# the AMD driver's own growth, midway (q9g-b1mid: rcadm -T -r1 -s 2000 of a RAID1 of 1000 MiB the mdadm here made,
# rcraid 9.3.3-00302, the log at 0x213000, 53 %): mdmon ends it, its final LD = the AMD driver's own end of it (q9g-b)
Q9=$FIXT/2026-11-15-rcraid-grow
qgfix q48 $Q9 q9g-b1mid
xz -dc $Q9/q9g-b-sata0-lba0-6000.img.xz > $WQ/q48/rc.img
check "48: q9g-b1mid (AMD's RAID1 growth midway): -E - raid1 read-write, the migration and its progress" "$M -E $(qgl 0) 2>/dev/null | grep -q 'md support : read-write' && $M -E $(qgl 0) 2>/dev/null | grep -q 'Migration : RAID10N 1 x 2, 1000 MiB -> RAID10N 1 x 2, 1907 MiB; 55% done'"
echo 3000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
qgasm; R1=$(mdof raid1)
check "48: q9g-b1mid assembled: 1907 MiB, md resyncs from the log's 0x213000" "[ -n '$R1' ] && [ \$(cat /sys/block/$R1/size) = $((0x3b9800)) ] && [ \$(cut -d' ' -f1 /sys/block/$R1/md/sync_completed) -ge $((0x213000)) ] && [ \$(cut -d' ' -f1 /sys/block/$R1/md/sync_completed) -lt $((0x213000 + 0x20000)) ]"
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
waitrec; sleep 3; stopall
check "48: q9g-b1mid ended by mdmon: its LD = the one the AMD driver ends it with (q9g-b), the log cleared, the configuration on all five disks" "[ -n \"\$(qgld $WQ/q48/rc.img 4631ee854d76)\" ] && [ \"\$(qgld $WQ/q48/d0.img 4631ee854d76)\" = \"\$(qgld $WQ/q48/rc.img 4631ee854d76)\" ] && [ \"\$(qgtlog $(qgl 0) 0x100000)\" = '0 0 0 0 0 0 0' ] && [ \$(for n in 0 1 2 3 4; do python3 $TOOLS/amdraid_dump.py --brief $WQ/q48/d\$n.img 2>/dev/null | head -1 | grep -oE '[0-9]+$'; done | sort -u | wc -l) = 1 ]"
qgdrop q48
fi
# --- end of stage 48 ---

# --- stage 49: RAID0 -> RAID10: mdadm --grow <RAID0 of N> --level=10 - as rcadm -T -r10 does it (q8m-e3amid,
# q8m-e3apost): md takes the RAID0 as a raid10 near-2 (slots 2i are its disks), mdmon puts spares of the container into
# all slots 2i+1 at once (recorded in the target LD before md starts), md recovers them, the data on the old disks do
# not move. Start packet: the RAID0 NORMAL, its elements 0x10000, 0x2022241, protect 0x8000; a RAID10 N x 2 (its
# elements as [i][0], the spares as [i][1]); the log (IO 0x400, 0x20 to the region) on [0][0] and [0][1]. Interrupted -
# goes on from the log; -I waits for the new disks too. A migration the AMD driver began (q8m-e3amid, 3 % of the log):
# mdmon ends it.
if want 49; then
cd "$MDADM_DIR"
stopall
qgmk q49 4 2
$M -C /dev/md/amd49 -e amd -n 2 $(qgl 0) $(qgl 1) --run >/dev/null 2>&1; CN=$(cont1)
$M -C /dev/md/z49 -e amd -l0 -n2 -z 256M $(qgl 0) $(qgl 1) --run >/dev/null 2>&1
$M -C /dev/md/k49 -e amd -l1 -n2 -z 32M $(qgl 0) $(qgl 1) --run >/dev/null 2>&1	# mdmon runs for it
sleep 1; waitrec; Z=$(qgmd z49); K=$(qgmd k49)
ZID=$(python3 $TOOLS/amdraid_dump.py --brief $WQ/q49/d0.img 2>/dev/null | sed -n 's/^  Array 1 \([0-9a-f]*\) .*/\1/p')
$M /dev/$CN --add $(qgl 2) >/dev/null 2>&1; sleep 1
check "49: one spare for a RAID0 of 2: refused, two needed" "$M --grow /dev/$Z --level=10 2>&1 | grep -q '2 AMD spares with 266 MiB free are needed' && [ \$(cat /sys/block/$Z/md/level) = raid0 ]"
$M /dev/$CN --add $(qgl 3) >/dev/null 2>&1; sleep 1
check "49: another layout, another number of disks, RAID1 to RAID10: refused" "$M --grow /dev/$Z --level=10 --layout=f2 2>&1 | grep -q 'RAID10 of 4, near 2' && $M --grow /dev/$Z --level=10 --raid-devices=6 2>&1 | grep -qE 'RAID10 of 4, near 2|Impossible number of devices|Need 4 spares' && $M --grow /dev/$K --level=10 2>&1 | grep -qE 'makes a RAID10 of a RAID0 only|RAID1 can only be converted|can only be changed' && [ \$(cat /sys/block/$Z/md/level) = raid0 ]"
head -c 32M /dev/urandom > $WQ/q49/pat; sudo dd if=$WQ/q49/pat of=/dev/$Z bs=1M oflag=direct status=none
G0=$(qgring $WQ/q49/d0.img | tail -1)
echo 3000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
OUT=$($M --grow /dev/$Z --level=10 2>&1); sleep 4
check "49: --grow --level=10: md raid10 near-2 of 4, the spares in slots 1 and 3 at 0x105000, recovering" "echo \"\$OUT\" | grep -q 'mdmon will mirror each member onto a spare' && [ \$(cat /sys/block/$Z/md/level) = raid10 ] && [ \$(cat /sys/block/$Z/md/layout) = 258 ] && [ \$(basename \$(readlink -f /sys/block/$Z/md/rd1/block)) = \$(basename $(qgl 2)) ] && [ \$(basename \$(readlink -f /sys/block/$Z/md/rd3/block)) = \$(basename $(qgl 3)) ] && [ \$(cat /sys/block/$Z/md/rd1/offset) = $((0x105000)) ] && [ \$(cat /sys/block/$Z/md/sync_action) = recover ]"
S1=$(qgld $WQ/q49/d0.img $ZID $((G0 + 1)))
check "49: start packet (the next one): the RAID0 NORMAL, its elements 0x10000, 0x2022241, protect 0x8000, Flags 0x20010, Link 1; the RAID10 2 x 2 - its elements as [i][0], the spares as [i][1], 0x2022241, a bitmap, generation of the packet (as rcadm -T -r10, q8m-e3amid)" "[ \$(echo \"\$S1\" | wc -l) = 2 ] && echo \"\$S1\" | head -1 | grep -qE 'tt=5354 lo=5354 ts=0 cap=100000 ps=0 .* fs=2x1 tf=2022241 psz=8000 fl=20010 lk=1 pct=0 at=0 e0=[0-9a-f]+:100000\\+85000:105000\\+80000:10000 e1=[0-9a-f]+:100000\\+85000:105000\\+80000:10000' && echo \"\$S1\" | tail -1 | grep -qE \"tt=0 lo=5354 ts=0 cap=100000 ps=0 gen=$(printf %x $((G0 + 1))) fs=2x2 tf=2022241 psz=0 fl=0 lk=0 pct=0 at=1( e[0-3]=[0-9a-f]+:100000\\\\+85000:105000\\\\+80000:0){4}\""
check "49: the log on [0][0] and [0][1]: NORMAL STARTED, I/O 0x400, 0x20 to the 0x8000 region" "T=\$(qgtlog $(qgl 0) 0x100000); [ \"\$T\" = \"\$(qgtlog $(qgl 2) 0x100000)\" ] && echo \"\$T\" | grep -qE '^5354 [0-9a-f]+ 1 400 2022241 8000 20$'"
sleep 6; $M -S /dev/$Z >/dev/null 2>&1; sleep 1
T=$(qgtlog $(qgl 0) 0x100000); D=$((0x$(echo $T | cut -d' ' -f2)))
check "49: stopped midway: the log on, at a region; -E: raid10, the new mirrors being copied onto" "[ \"\$T\" = \"\$(qgtlog $(qgl 2) 0x100000)\" ] && [ $D -gt 0 ] && [ $((D % 0x8000)) = 0 ] && $M -E $(qgl 0) | grep -A12 '^\[z49\]' | grep -q 'RAID Level : raid10' && [ \$($M -E $(qgl 0) | grep -A20 '^\[z49\]' | grep -c 'a new mirror: the migration copies onto it') = 2 ]"
stopall
for i in 0 1 2; do $M -I $(qgl $i) >/dev/null 2>&1; done; sleep 2
check "49: -I without a new mirror's disk: the volume waits for it" "[ \$(grep -c 'active raid10' /proc/mdstat) = 0 ]"
$M -I $(qgl 3) >/dev/null 2>&1; sleep 1; Z=$(mdof raid10)
# 3 MB/s: from 0 a mirror would take seconds to get as far as the mark
check "49: ... it comes: both new mirrors go on from the log ($D volume sectors = $((D / 2)) a member)" "[ \$(cat /sys/block/$Z/md/rd1/recovery_start) -ge $((D / 2)) ] && [ \$(cat /sys/block/$Z/md/rd3/recovery_start) -ge $((D / 2)) ]"
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
waitrec; sleep 3
G1=$(qgring $WQ/q49/d0.img | tail -1)
P100=$(qgld $WQ/q49/d0.img $ZID $((G1 - 1))); PF=$(qgld $WQ/q49/d0.img $ZID $G1)
check "49: \"100 %\" packet, then the final one: one LD RAID10 2 x 2 NORMAL, LastOperation NORMAL COMPLETED, elements flags 0; log cleared on both" "echo \"\$P100\" | head -1 | grep -q 'tt=5354 lo=5354 ts=a1a6 cap=100000 ps=100000 .* fl=84 lk=1 pct=186a0' && echo \"\$P100\" | tail -1 | grep -q 'tt=5354 lo=5354 ts=a1a1 .* fs=2x2 .* pct=186a0' && [ \$(echo \"\$PF\" | wc -l) = 1 ] && echo \"\$PF\" | grep -qE 'st=200 tt=0 lo=5354 ts=a1a6 cap=100000 ps=0 gen=[0-9a-f]+ fs=2x2 tf=0 psz=0 fl=0 lk=0 pct=0 at=1( e[0-3]=[0-9a-f]+:100000\\+85000:105000\\+80000:0){4}' && [ \"\$(qgtlog $(qgl 0) 0x100000)\" = '0 0 0 0 0 0 0' ] && [ \"\$(qgtlog $(qgl 2) 0x100000)\" = '0 0 0 0 0 0 0' ]"
echo check | sudo tee /sys/block/$Z/md/sync_action >/dev/null; sleep 1; waitrec
check "49: done: [4/4], the data as written, md check 0" "grep -A1 \"^$Z \" /proc/mdstat | grep -q '\[UUUU\]' && cmp -s $WQ/q49/pat <(sudo dd if=/dev/$Z bs=1M count=32 iflag=direct status=none) && [ \$(cat /sys/block/$Z/md/mismatch_cnt) = 0 ]"
stopall; qgasm; Z=$(qgmd z49)
check "49: assembled again: raid10 [4/4], no recovery" "[ \$(cat /sys/block/$Z/md/level) = raid10 ] && grep -A1 \"^$Z \" /proc/mdstat | grep -q '\[UUUU\]' && ! grep -A3 \"^$Z \" /proc/mdstat | grep -qE 'resync|recovery'"
qgdrop q49
# the AMD driver's own RAID0 -> RAID10, midway (q8m-e3amid: rcraid 9.3.3-00302, the log at 0x20000): mdmon ends it
qgfix q49 $FIXT/2026-11-15-rcraid-migrations q8m-e3amid
check "49: q8m-e3amid (AMD's RAID0 -> RAID10 midway): -E - raid10 read-write, the migration and its progress" "$M -E $(qgl 0) 2>/dev/null | sed -n '/Volume ID : f3b0509c1022ccd7/,/Member/p' | grep -q 'RAID Level : raid10' && $M -E $(qgl 0) 2>/dev/null | sed -n '/Volume ID : f3b0509c1022ccd7/,/Member/p' | grep -q 'md support : read-write' && $M -E $(qgl 0) 2>/dev/null | grep -q 'Migration : RAID10N 2 x 1, 1908 MiB -> RAID10N 2 x 2, 1908 MiB; 3% done'"
qgasm
E3=$(for m in $(mdof raid10); do [ $(cat /sys/block/$m/size) = $((0x3ba000)) ] && echo $m; done)
check "49: q8m-e3amid assembled: raid10 2 x 2, its new mirrors (SATA4, SATA3) from the log's 0x20000 (0x10000 a member)" "[ -n '$E3' ] && [ \$(basename \$(readlink -f /sys/block/$E3/md/rd1/block)) = \$(basename $(qgl 4)) ] && [ \$(basename \$(readlink -f /sys/block/$E3/md/rd3/block)) = \$(basename $(qgl 3)) ] && [ \$(cut -d' ' -f1 /sys/block/$E3/md/sync_completed) -ge $((0x10000)) ] 2>/dev/null"
waitrec; sleep 3; stopall
check "49: q8m-e3amid ended by mdmon: one LD RAID10 2 x 2 NORMAL, the AMD driver's elements, flags 0; log cleared on [0][0] and [0][1]" "qgld $WQ/q49/d0.img f3b0509c1022ccd7 | grep -qE '^type=1bf6 st=200 tt=0 lo=5354 ts=a1a6 cap=3ba000 ps=0 gen=1a fs=2x2 tf=0 psz=0 fl=0 lk=0 pct=0 at=1 e0=8f38:6a1000\\+1e2000:6a6000\\+1dd000:0 e1=d96f:100000\\+1e2000:105000\\+1dd000:0 e2=1aad:6a1000\\+1e2000:6a6000\\+1dd000:0 e3=3186:a5f800\\+1e2000:a64800\\+1dd000:0$' && [ \"\$(qgtlog $(qgl 0) 0x6a1000)\" = '0 0 0 0 0 0 0' ] && [ \"\$(qgtlog $(qgl 4) 0x100000)\" = '0 0 0 0 0 0 0' ]"
qgdrop q49
fi
# --- end of stage 49 ---

# --- stage 50: a rebuild target that lost the end of the rebuild - its write cache was gone at a power cut (the AMD
# Windows driver 9.3.3.329 rebuilt a RAID10 onto SATA4; SATA4 kept the packet of the rebuild's middle, the others its
# end). md rebuilds other volumes onto this disk, mdmon writes the live configuration to it, and the disk would be
# up to date with it: a RAID10 the live configuration has it in service in would be assembled [4/4] without a
# rebuild (and its mirrors differ). Now its element is offline before the write, md rebuilds it in place from 0; the
# recorded rebuilds of other volumes onto it go on as they went (an element offline in another volume does not hold
# them). Five loop devices of 1 GiB: RAID10 q50t (d0-d3), RAID1 q50m (d0, d1), RAID5 q50p (d0-d2), random data; d4 a
# spare; d1 failed in all three: q50t rebuilt onto d4, the rebuilds of q50m and q50p onto d4 recorded (1 KiB/s, then
# frozen), hardly begun. A snapshot; the control - as it is (d4 up to date: nothing offline, q50t [4/4] without a
# rebuild); the forgery - d4's commit block on the packet of its ring where the rebuild of q50t is still recorded, the
# data of d4's element of q50t zeroed (the whole rebuild lost). Assembled: -A of the container without d1, -I (the
# volumes that have enough disks), until mdmon has written d4, then -IR.
if want 50; then
cd "$MDADM_DIR"
stopall
Q50=$WQ/q50
q50drop() { stopall; for l in $(sudo losetup -a | grep "$Q50/" | cut -d: -f1); do sudo losetup -d $l; done; }
q50att() { local n; Q50L=(); for n in 0 1 2 3 4; do Q50L[$n]=$(sudo losetup -f --show $Q50/$1/d$n.img); done; }
q50md() { local p; for p in /dev/md/$1 /dev/md/${1}_0; do [ -e $p ] && { basename $(readlink -f $p); return; }; done; }
q50vol() { $M -E $2 2>/dev/null | sed -n "/^\[$1\]:/,/^\[/p"; }
q50gen() { $M -E $1 2>/dev/null | sed -n 's/^ *Generation : //p' | head -1; }
q50sum() { sudo md5sum /dev/$(q50md $1) | cut -c1-32; }
q50mm() { local m=$(q50md $1); echo check | sudo tee /sys/block/$m/md/sync_action >/dev/null; sleep 1
	while ! grep -q idle /sys/block/$m/md/sync_action; do sleep 1; done; cat /sys/block/$m/md/mismatch_cnt; }
# all three volumes in service (up to 90 rounds: the rebuilds go one at a time - the volumes share disks)
q50whole() { local i; for i in $(seq 1 90); do waitrec 120 >/dev/null
	[ "$(grep -A1 "^$(q50md q50t) " /proc/mdstat | grep -o '\[[0-9]/[0-9]\]')" = '[4/4]' ] &&
	[ "$(grep -A1 "^$(q50md q50m) " /proc/mdstat | grep -o '\[[0-9]/[0-9]\]')" = '[2/2]' ] &&
	[ "$(grep -A1 "^$(q50md q50p) " /proc/mdstat | grep -o '\[[0-9]/[0-9]\]')" = '[3/3]' ] && return 0; sleep 1; done; return 1; }
# q50asm <dir>: -A of the container without d1, -I, wait until d4 has the live configuration (d0's generation), -IR
q50asm() { local i; q50att $1; sudo dmesg -C
	$M -A /dev/md/q50c -e amd ${Q50L[0]} ${Q50L[2]} ${Q50L[3]} ${Q50L[4]} >/dev/null 2>&1
	$M -I /dev/md/q50c >/dev/null 2>&1
	for i in $(seq 1 40); do [ "$(q50gen ${Q50L[4]})" = "$(q50gen ${Q50L[0]})" ] && break; sleep 0.5; done; sleep 1
	Q50OFF=$(q50vol q50t ${Q50L[0]} | grep -c "Member *[0-9]* : $Q50ID4 .*(out of service: offline)")
	$M -IR /dev/md/q50c >/dev/null 2>&1; sleep 2; q50whole; sleep 3; }
q50drop; rm -rf $Q50; mkdir -p $Q50/s
for n in 0 1 2 3 4; do truncate -s 1G $Q50/s/d$n.img; done
q50att s
$M -C /dev/md/q50c -e amd -n4 ${Q50L[@]:0:4} --run >/dev/null 2>&1
$M -C /dev/md/q50t -e amd -l10 -n4 -z 64M ${Q50L[@]:0:4} --run --assume-clean >/dev/null 2>&1
$M -C /dev/md/q50m -e amd -l1 -n2 -z 128M ${Q50L[0]} ${Q50L[1]} --run --assume-clean >/dev/null 2>&1
$M -C /dev/md/q50p -e amd -l5 -n3 -z 64M ${Q50L[@]:0:3} --run --assume-clean >/dev/null 2>&1; sleep 2
for v in q50t q50m q50p; do m=$(q50md $v)
	sudo dd if=/dev/urandom of=/dev/$m bs=1M count=$(( $(sudo blockdev --getsize64 /dev/$m) / 1048576 )) oflag=direct status=none; done
Q50T=$(q50sum q50t); Q50M=$(q50sum q50m); Q50P=$(q50sum q50p)
$M /dev/$(cont1) --add ${Q50L[4]} >/dev/null 2>&1; sleep 2
# d1 fails in all three, d4 is taken for each (the rebuilds recorded); q50m and q50p at 1 KiB/s, then frozen once
# recorded, so that q50t (they share disks: one recovery at a time) gets to run and end (an array frozen before
# takes no spare: managemon)
for v in q50m q50p; do for f in sync_speed_min sync_speed_max; do echo 1 | sudo tee /sys/block/$(q50md $v)/md/$f >/dev/null; done; done
for v in q50t q50m q50p; do $M /dev/$(q50md $v) --fail ${Q50L[1]} >/dev/null 2>&1; done
Q50ID4=$($M -E ${Q50L[4]} 2>/dev/null | sed -n 's/^ *Device ID : //p' | head -1)
for i in $(seq 1 60); do q50vol q50m ${Q50L[0]} | grep -q 'Transform : 0x5358,' && q50vol q50p ${Q50L[0]} | grep -q 'Transform : 0x5358,' && break; sleep 1; done
for v in q50m q50p; do echo frozen | sudo tee /sys/block/$(q50md $v)/md/sync_action >/dev/null; done
q50setup() { q50vol q50t ${Q50L[0]} | grep -q "Member *[0-9]* : $Q50ID4 handle [0-9]* offset [0-9]* size [0-9]*\$" &&
	q50vol q50t ${Q50L[0]} | grep -q 'Transform : 0x0,' && q50vol q50m ${Q50L[0]} | grep -q 'Transform : 0x5358,' &&
	q50vol q50p ${Q50L[0]} | grep -q 'Transform : 0x5358,'; }
for i in $(seq 1 60); do q50setup && break; sleep 1; done
check "50: set-up: q50t rebuilt onto d4 ($Q50ID4, in service), the rebuilds of q50m and q50p onto d4 recorded, hardly begun" q50setup
# the data of d4's element of q50t (user data, sectors) and the LD ID of q50t, as the live packet has them
read Q50DATA Q50SIZE <<< "$(q50vol q50t ${Q50L[0]} | sed -n "s/.* Member *[0-9]* : $Q50ID4 handle [0-9]* offset \([0-9]*\) size \([0-9]*\).*/\1 \2/p")"
Q50DATA=${Q50DATA:-0}; Q50SIZE=${Q50SIZE:-0}
Q50TID=$(printf %x 0x$(q50vol q50t ${Q50L[0]} | sed -n 's/^ *Volume ID : //p'))
stopall; q50drop
for c in ctl forge; do mkdir $Q50/$c; cp --reflink=auto $Q50/s/*.img $Q50/$c/; done

q50asm ctl
check "50: control (d4 up to date): nothing recorded offline, q50t [4/4] without a recovery, q50m and q50p rebuilt onto d4" "[ $Q50OFF = 0 ] && ! sudo dmesg | grep -q 'missed configurations' && ! sudo dmesg | grep -q 'recover of RAID array $(q50md q50t)\$' && q50whole"
check "50: ... the data as written, md check 0 (q50t, q50m, q50p)" "[ \$(q50sum q50t) = $Q50T ] && [ \$(q50sum q50m) = $Q50M ] && [ \$(q50sum q50p) = $Q50P ] && [ \$(q50mm q50t) = 0 ] && [ \$(q50mm q50m) = 0 ] && [ \$(q50mm q50p) = 0 ]"
q50drop

# the forgery: d4's commit block on the newest packet of its ring where the rebuild of q50t is recorded (two
# records of its LD), as a disk that lost what it wrote since; the user data of its element of q50t zeroed
Q50SEQ=$(python3 - $Q50/forge/d4.img $Q50TID <<'PY'
import os, struct, sys
sys.path.insert(0, os.environ["TOOLS"])
import amdraid_dump as ad
img, ldid = sys.argv[1], int(sys.argv[2], 16)
dk = ad.Disk(img)
rc = ad.parse_raidcore(dk.read(ad.LBA_RAIDCORE))
c = bytearray(dk.read(rc["commit_lba"]))
for lba, h in reversed(ad.scan_ring(dk)):
    _, _, lds = ad.parse_gen(ad.read_gen(dk, lba, h["length"]))
    if sum(ld["ld_id"] == ldid for ld in lds) == 2:
        break
else:
    sys.exit(1)
struct.pack_into("<IIQQ", c, 8, lba, h["length"], h["sum"], h["config_seq"] + 1)
struct.pack_into("<Q", c, 0, ad.rc_sum(bytes(c), 8, 0x1F8))
with open(img, "r+b") as f:
    f.seek(rc["commit_lba"] * 512)
    f.write(c)
print(h["config_seq"])
PY
)
[ $Q50SIZE != 0 ] && fallocate -p -o $((Q50DATA * 512)) -l $((Q50SIZE * 512)) $Q50/forge/d4.img
# 10 MB/s: the rebuild in place of q50t lasts some seconds, mdmon records it (one md ends before the monitor's
# next pass is not recorded at all - it need not be)
echo 10000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
q50asm forge
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
check "50: forged (d4 back with packet $Q50SEQ, its rebuild of q50t lost): as d4 takes the live configuration, its member of q50t is recorded offline (-E), mdmon says so once" "[ -n '$Q50SEQ' ] && [ $Q50SIZE != 0 ] && [ $Q50OFF = 1 ] && [ \$(sudo dmesg | grep -c 'amd: subarray-[0-9]*: member [0-9]* (disk [0-9:]*) missed configurations, recorded as offline') = 1 ]"
check "50: ... q50t rebuilt onto d4 in place, from 0: [4/4], the data as written, md check 0" "sudo dmesg | grep -q 'recover of RAID array $(q50md q50t)\$' && [ \$(q50sum q50t) = $Q50T ] && [ \$(q50mm q50t) = 0 ]"
check "50: ... q50m and q50p rebuilt onto d4 as recorded (its member of q50t offline does not hold them), the data as written, md check 0" "q50whole && [ \$(q50sum q50m) = $Q50M ] && [ \$(q50sum q50p) = $Q50P ] && [ \$(q50mm q50m) = 0 ] && [ \$(q50mm q50p) = 0 ]"
stopall
D4S=$(echo $Q50ID4 | tail -c 5)
check "50: ... in the configuration as AMD records a rebuild: q50t CRITICAL with d4 offline (0x30), then RESTORE_SEGMENTS (two LD records), then NORMAL; every disk on one generation" "python3 $TOOLS/amdraid_dump.py --brief --ring $Q50/forge/d0.img 2>/dev/null | awk -v t=' $Q50TID ' -v d='$D4S' 'index(\$0, \"Array \") && index(\$0, t) { if (s == 0 && index(\$0, \"CRITICAL\") && index(\$0, d \"/f30\")) s = 1; else if (s == 1 && index(\$0, \" x2 \")) s = 2; else if (s == 2 && index(\$0, \"NORMAL\")) s = 3 } END { exit s != 3 }' && [ \"\$(q50gen ${Q50L[4]})\" = \"\$(q50gen ${Q50L[0]})\" ] && [ \"\$(q50gen ${Q50L[2]})\" = \"\$(q50gen ${Q50L[0]})\" ] && q50vol q50t ${Q50L[0]} | grep -q 'State : 0x200 (normal)'"
q50drop; rm -rf $Q50
fi
# --- end of stage 50 ---

# --- stage 51: adding disks, the data moving: mdadm --grow <RAID5> --raid-devices=N and <RAID1 of 2> --level=5
# --layout=right-asymmetric --raid-devices=N - as rcadm -T -r5 does it (q8m-e2mid, q8m-e3bmid): a start packet (the
# source NORMAL 0x22211, protect = the target's data disks x 0x4800, Flags 0x20010, Link 1; the target a RAID5 1 x N,
# 0x12211, the elements' data at + 0x800, the new disks spares of the container), the log before each region,
# "100 %", the log zeroed, the final packet. md reshapes with data_offset 0x4800 sectors down, held by the log
# (sync_max, suspend): never more than a region past the mark on disk, writes to the region wait. Interrupted - goes
# on from the mark, also from 0 (nothing moved yet), as the AMD driver; a member failed midway - degraded to the end;
# the AMD driver's own migrations midway (q8m-e2mid, q8m-e3bmid) - md ends them, the final packet as AMD's
# (q8m-e2post, q8m-e3bpost). 1.4 refused such a --grow and did not assemble volumes in the middle of such a migration.
if want 51; then
stopall
Q51D=$FIXT/2026-11-15-rcraid-migrations
# q51mark <loop> <LBA>: the log's mark (a sector of the volume), -1 - no log
q51mark() { sudo dd if=$1 bs=512 skip=$(($2)) count=1 iflag=direct status=none | python3 -c 'import sys,struct; b=sys.stdin.buffer.read(); print(struct.unpack_from("<Q", b, 0x1c)[0] if struct.unpack_from("<I", b, 0x18)[0] else -1)'; }
# q51lag <md> <seconds> <loop:LBA>...: while md reshapes - how far it is past the log's mark (the furthest of the
# copies): "samples worst" (md's position read first, then the log: the mark is not older than the position)
q51lag() { local md=$1 t=$(( $(date +%s) + $2 )) r m x d worst=0 n=0; shift 2
	while [ $(date +%s) -lt $t ]; do r=$(cat /sys/block/$md/md/reshape_position); [ "$r" = none ] && break; m=-1
		for x in "$@"; do d=$(q51mark ${x%:*} ${x#*:}); [ $d -gt $m ] && m=$d; done
		[ $m -ge 0 ] && { d=$((r - m)); [ $d -gt $worst ] && worst=$d; n=$((n + 1)); }; done; echo "$n $worst"; }
q51wait() { for i in $(seq 1 600); do grep -qE 'reshape|resync|recover|check' /proc/mdstat || { sleep 3; grep -qE 'reshape|resync|recover|check' /proc/mdstat || return 0; }; sleep 2; done; return 1; }
# q51nolog <ID> <LBA>...: no disk has a transform log of volume <ID> at any of these LBAs (the elements' AllocatedSpace)
q51nolog() { local id=$1 l a; shift; for l in $QGL; do for a in "$@"; do
	[ "$(sudo dd if=$l bs=512 skip=$((0x$a)) count=1 status=none | od -An -tx8 -j8 -N8 | tr -d ' ')" = $id ] && return 1; done; done; return 0; }
q51offs() { cat /sys/block/$1/md/dev-*/$2 | sort -u | tr '\n' ' '; }	# offset / new_offset of the members
qgmk q51 5 2
$M -C /dev/md/amd51 -e amd -n 3 $(qgl 0) $(qgl 1) $(qgl 2) --run >/dev/null 2>&1; CN=$(cont1)
$M -C /dev/md/c51 -e amd -l5 -n3 -z 128M $(qgl 0) $(qgl 1) $(qgl 2) --run >/dev/null 2>&1
$M -C /dev/md/m51 -e amd -l1 -n2 -z 64M $(qgl 0) $(qgl 1) --run >/dev/null 2>&1
sleep 1; waitrec; C=$(qgmd c51); R1=$(qgmd m51)
CID=$(qgids $WQ/q51/d0.img | sed -n 1p); RID=$(qgids $WQ/q51/d0.img | sed -n 2p)
check "51: no spare in the container: refused (Grow.c)" "$M --grow /dev/$C --raid-devices=4 2>&1 | grep -q 'Need 1 spare' && [ \$(cat /sys/block/$C/md/raid_disks) = 3 ]"
$M /dev/$CN --add $(qgl 3) >/dev/null 2>&1; sleep 1
check "51: a RAID1 of two to RAID5 without AMD's layout (Grow.c's default is left-symmetric): refused" "$M --grow /dev/$R1 --level=5 --raid-devices=3 2>&1 | grep -q 'AMD makes a RAID5 of a RAID1 of two disks, with its layout' && [ \$(cat /sys/block/$R1/md/level) = raid1 ]"
check "51: another chunk, another layout, a backup file, fewer disks: refused" "$M --grow /dev/$C --raid-devices=4 --chunk=32 2>&1 | grep -q 'AMD RAID chunk size is 64, 128 or 256 KiB' && $M --grow /dev/$C --raid-devices=4 --layout=left-symmetric 2>&1 | grep -q 'right-asymmetric only' && $M --grow /dev/$C --raid-devices=4 --backup-file=$WQ/q51/bk 2>&1 | grep -q 'no backup file' && $M --grow /dev/$C --raid-devices=2 2>&1 | grep -qE 'AMD takes no disk out|reduce the size' && [ \$(cat /sys/block/$C/md/raid_disks) = 3 ] && [ -z \"\$(qgld $WQ/q51/d0.img $CID | grep -v 'tt=0')\" ]"
head -c 64M /dev/urandom > $WQ/q51/pat; sudo dd if=$WQ/q51/pat of=/dev/$C bs=1M oflag=direct status=none
G0=$(qgring $WQ/q51/d0.img | tail -1)
echo 3000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
$M --grow /dev/$C --raid-devices=4 > $WQ/q51/grow.out 2>&1; sleep 3
check "51: --raid-devices=4: md reshapes 3 -> 4, every member's data 0x4800 sectors down (0x105000 -> 0x100800, the new disk too), the array blocked for mdmon (external:-)" "grep -q '3 -> 4 disks; mdmon records it as an AMD migration' $WQ/q51/grow.out && [ \$(cat /sys/block/$C/md/sync_action) = reshape ] && [ \"\$(q51offs $C offset)\" = '$((0x105000)) ' ] && [ \"\$(q51offs $C new_offset)\" = '$((0x100800)) ' ] && [ \$(ls -d /sys/block/$C/md/dev-* | wc -l) = 4 ] && grep -q 'external:-' /sys/block/$C/md/metadata_version"
S1=$(qgld $WQ/q51/d0.img $CID $((G0 + 1)))
check "51: start packet (the next one): the RAID5 1 x 3 NORMAL 0x22211, protect 0xd800 (3 data disks x 0x4800), Flags 0x20010, Link 1; the RAID5 1 x 4 it becomes - LastOperation NORMAL, 0x12211, 384 MiB, generation of the packet, its elements at the same extents, data at + 0x800, the spare's first-fit (as rcadm -T -r5, q8m-e2mid)" "[ \$(echo \"\$S1\" | wc -l) = 2 ] && echo \"\$S1\" | head -1 | grep -q 'type=1bf5 st=200 tt=5354 lo=5354 ts=0 cap=80000 ps=0 .* fs=1x3 tf=22211 psz=d800 fl=20010 lk=1 pct=0 at=1' && echo \"\$S1\" | tail -1 | grep -qE \"type=1bf5 st=200 tt=0 lo=5354 ts=0 cap=c0000 ps=0 gen=$(printf %x $((G0 + 1))) fs=1x4 tf=12211 psz=0 fl=0 lk=0 pct=0 at=1( e[0-3]=[0-9a-f]+:100000\\\\+45000:100800\\\\+40000:0){4}$\""
check "51: the log before each region: NORMAL STARTED at a region, the source's flags, I/O 0x600, 0x24 to the 0xd800 region, on the data and the parity element of the stripe past the end ([0], [1])" "T=\$(qgtlog $(qgl 0) 0x100000); [ \"\$T\" = \"\$(qgtlog $(qgl 1) 0x100000)\" ] && echo \"\$T\" | grep -qE '^5354 [0-9a-f]+ 1 600 22211 d800 24$' && [ \$((0x\$(echo \$T | cut -d' ' -f2) % 0xd800)) = 0 ] && [ \"\$(qgtlog $(qgl 2) 0x100000)\" = '0 0 0 0 0 0 0' ]"
LAG=$(q51lag $C 6 $(qgl 0):0x100000 $(qgl 1):0x100000)
check "51: md held behind the log: never more than a region past its mark on disk (${LAG#* } of $((0xd800)), ${LAG% *} samples)" "[ ${LAG% *} -gt 5 ] && [ ${LAG#* } -le $((0xd800)) ]"
$M -S /dev/$C >/dev/null 2>&1; sleep 1
T=$(qgtlog $(qgl 0) 0x100000); D=$((0x$(echo $T | cut -d' ' -f2)))
check "51: stopped midway: the log on, at a region past 0 ($D); -E says the migration" "[ \"\$T\" = \"\$(qgtlog $(qgl 1) 0x100000)\" ] && [ $D -gt 0 ] && [ $((D % 0xd800)) = 0 ] && $M -E $(qgl 0) | grep -q 'Migration : RAID50 1 x 3, 256 MiB -> RAID50 1 x 4, 384 MiB; [0-9]*% done'"
stopall; qgasm; C=$(qgmd c51)
RS=$(cat /sys/block/$C/md/reshape_position 2>/dev/null)
check "51: assembled again (-I): md goes on with the reshape from the log's mark, the new offsets again, held and blocked" "[ \"\$RS\" -ge $D ] && [ \"\$RS\" -lt $((D + 4 * 0xd800)) ] && [ \"\$(q51offs $C new_offset)\" = '$((0x100800)) ' ] && grep -q 'external:-' /sys/block/$C/md/metadata_version && [ \$(cat /sys/block/$C/md/sync_max) != max ]"
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
q51wait; sleep 3
G1=$(qgring $WQ/q51/d0.img | tail -1)
P100=$(qgld $WQ/q51/d0.img $CID $((G1 - 1))); PF=$(qgld $WQ/q51/d0.img $CID $G1)
check "51: \"100 %\" packet (the RAID5 1 x 3 COMPLETED at 384 MiB, 100000, Flags 0x84; the new one NORMAL STARTED as far), then the final one: one LD RAID5 1 x 4, 384 MiB, LastOperation NORMAL COMPLETED, generation as made, data at + 0x800; log cleared" "echo \"\$P100\" | head -1 | grep -q 'tt=5354 lo=5354 ts=a1a6 cap=80000 ps=c0000 .* fs=1x3 .* psz=0 fl=84 lk=1 pct=186a0' && echo \"\$P100\" | tail -1 | grep -q 'tt=5354 lo=5354 ts=a1a1 cap=c0000 ps=c0000 .* fs=1x4 .* pct=186a0' && [ \$(echo \"\$PF\" | wc -l) = 1 ] && echo \"\$PF\" | grep -qE \"type=1bf5 st=200 tt=0 lo=5354 ts=a1a6 cap=c0000 ps=0 gen=$(printf %x $((G0 + 1))) fs=1x4 tf=0 psz=0 fl=0 lk=0 pct=0 at=1( e[0-3]=[0-9a-f]+:100000\\\\+45000:100800\\\\+40000:0){4}$\" && [ \"\$(qgtlog $(qgl 0) 0x100000)\" = '0 0 0 0 0 0 0' ] && [ \"\$(qgtlog $(qgl 1) 0x100000)\" = '0 0 0 0 0 0 0' ]"
echo check | sudo tee /sys/block/$C/md/sync_action >/dev/null; sleep 1; waitrec
check "51: done: md raid5 of 4, 384 MiB, data at 0x100800 (offset), not blocked; the data as written, md check 0" "[ \$(cat /sys/block/$C/md/raid_disks) = 4 ] && [ \$(cat /sys/block/$C/size) = $((0xc0000)) ] && [ \"\$(q51offs $C offset)\" = '$((0x100800)) ' ] && grep -q 'external:/' /sys/block/$C/md/metadata_version && cmp -s $WQ/q51/pat <(sudo dd if=/dev/$C bs=1M count=64 iflag=direct status=none) && [ \$(cat /sys/block/$C/md/mismatch_cnt) = 0 ]"
stopall; qgasm; C=$(qgmd c51)
check "51: assembled again: raid5 of 4 at 0x100800, no reshape" "[ \$(cat /sys/block/$C/md/raid_disks) = 4 ] && [ \"\$(cat /sys/block/$C/md/reshape_position)\" = none ] && [ \"\$(q51offs $C offset)\" = '$((0x100800)) ' ]"
check "51: data moved by a migration already: another chunk with the disk refused (AMD would go in place, regions md cannot keep to; more disks alone - stage 65, the chunk alone - stage 66)" "$M /dev/$CN --add $(qgl 4) >/dev/null 2>&1; sleep 1; $M --grow /dev/$C --raid-devices=5 --chunk=128 2>&1 | grep -q 'an AMD migration moved its data already: AMD would take them onto more disks and to another chunk in place' && [ \$(cat /sys/block/$C/md/raid_disks) = 4 ]"
# RAID1 of two -> RAID5 of 3, at full speed, written to meanwhile
R1=$(qgmd m51); head -c 64M /dev/urandom > $WQ/q51/pat; sudo dd if=$WQ/q51/pat of=/dev/$R1 bs=1M oflag=direct status=none
cp $WQ/q51/pat $WQ/q51/model; G0=$(qgring $WQ/q51/d0.img | tail -1)
( for i in $(seq 1 150); do o=$((RANDOM % 64)); head -c 1M /dev/urandom > $WQ/q51/blk
	sudo dd if=$WQ/q51/blk of=/dev/$R1 bs=1M seek=$o oflag=direct conv=notrunc status=none 2>/dev/null
	dd if=$WQ/q51/blk of=$WQ/q51/model bs=1M seek=$o conv=notrunc status=none; done ) &
WP=$!
$M --grow /dev/$R1 --level=5 --layout=right-asymmetric --raid-devices=3 > $WQ/q51/grow.out 2>&1
S1=$(qgld $WQ/q51/d0.img $RID $((G0 + 1)))
A0=$(echo "$S1" | tail -1 | grep -o 'e0=[0-9a-f]*:[0-9a-f]*' | cut -d: -f2)
LAG=$(q51lag $R1 60 $(qgl 0):0x$A0)
wait $WP; q51wait; sleep 3
check "51: RAID1 of two -> RAID5 of 3 (--level=5 --layout=right-asymmetric -n3): start packet - the RAID1 NORMAL 0x22211, protect 0x9000, the RAID5 1 x 3 0x12211 with the spare (as rcadm -T -r5, q8m-e3bmid); md held behind the log at full speed (${LAG#* } of $((0x9000)), ${LAG% *} samples)" "grep -q '2 -> 3 disks' $WQ/q51/grow.out && echo \"\$S1\" | head -1 | grep -q 'type=1bf6 st=200 tt=5354 lo=5354 ts=0 cap=20000 ps=0 .* fs=1x2 tf=22211 psz=9000 fl=20010 lk=1' && echo \"\$S1\" | tail -1 | grep -qE 'type=1bf5 st=200 tt=0 lo=5354 ts=0 cap=40000 .* fs=1x3 tf=12211 .*( e[0-2]=[0-9a-f]+:[0-9a-f]+\\+25000:[0-9a-f]+800\\+20000:0){3}$' && [ ${LAG#* } -le $((0x9000)) ]"
echo check | sudo tee /sys/block/$R1/md/sync_action >/dev/null; sleep 1; waitrec
check "51: ... done: raid5 of 3, 128 MiB, one LD RAID5 1 x 3 NORMAL; the data with the writes made meanwhile, md check 0" "[ \$(cat /sys/block/$R1/md/level) = raid5 ] && [ \$(cat /sys/block/$R1/md/raid_disks) = 3 ] && [ \$(cat /sys/block/$R1/size) = $((0x40000)) ] && [ \$(qgld $WQ/q51/d0.img $RID | wc -l) = 1 ] && qgld $WQ/q51/d0.img $RID | grep -q 'type=1bf5 st=200 tt=0 lo=5354 ts=a1a6 cap=40000 .* fs=1x3 tf=0' && cmp -s $WQ/q51/model <(sudo dd if=/dev/$R1 bs=1M count=64 iflag=direct status=none) && [ \$(cat /sys/block/$R1/md/mismatch_cnt) = 0 ]"
# nothing moved yet (the log at 0): md goes on from 0, as the AMD driver (stage 55)
$M -C /dev/md/n51 -e amd -l5 -n3 -z 32M $(qgl 0) $(qgl 1) $(qgl 2) --run >/dev/null 2>&1; sleep 1; waitrec; N5=$(qgmd n51)
NID=$(qgids $WQ/q51/d0.img | sed -n 3p)
head -c 64M /dev/urandom > $WQ/q51/pat; sudo dd if=$WQ/q51/pat of=/dev/$N5 bs=1M oflag=direct status=none
echo 50 | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null; echo 100 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
$M --grow /dev/$N5 --raid-devices=4 > $WQ/q51/grow.out 2>&1; sleep 2; $M -S /dev/$N5 >/dev/null 2>&1; sleep 1
echo 1000 | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null; echo 3000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
check "51: stopped before md moved a region: the log at 0" "grep -q '3 -> 4 disks' $WQ/q51/grow.out && qgld $WQ/q51/d0.img $NID | head -1 | grep -q 'tt=5354' && $M -E $(qgl 0) | grep -q 'Migration : RAID50 1 x 3, 64 MiB -> RAID50 1 x 4, 96 MiB; 0% done'"
sudo dmesg -C; stopall; qgasm; N5=$(qgmd n51); sleep 2
check "51: ... assembled: md goes on from 0, as the AMD driver - raid5 of 4 reshaping, the migration kept (not dropped)" "[ \"\$(cat /sys/block/$N5/md/raid_disks)\" = '4 (3)' ] && [ \"\$(cat /sys/block/$N5/md/reshape_position)\" != none ] && [ \$(qgld $WQ/q51/d0.img $NID | wc -l) = 2 ] && ! sudo dmesg | grep -q 'had not begun: dropped'"
# a member failed midway (of that migration, gone on from 0): md goes on degraded, as the AMD driver does; the failure in both LDs
$M /dev/$N5 -f $(qgl 1) >/dev/null 2>&1; sleep 2; S1=$(qgld $WQ/q51/d0.img $NID)
D5=$(cat /sys/block/$N5/md/degraded); SA=$(cat /sys/block/$N5/md/sync_action)
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
q51wait; waitrec; sleep 3
# mdmon fails the disk in every volume of the container (monitor.c reconcile_failed); a spare is left (d4): once the
# reshape is over - not before, one transform at a time - each degraded volume is rebuilt onto it
check "51: a member failed midway: recorded in both LDs (0x10), CRITICAL; md reshapes on degraded ($D5, $SA) to the end; then rebuilt onto the spare left (RESTORE_SEGMENTS) - one LD RAID5 1 x 4, the data as written" "echo \"\$S1\" | head -1 | grep -qE 'st=201 tt=5354 .* e1=[0-9a-f]+:[0-9a-f+]+:[0-9a-f+]+:10( |$)' && echo \"\$S1\" | tail -1 | grep -qE 'st=201 tt=0 .* fs=1x4 .* e1=[0-9a-f]+:[0-9a-f+]+:[0-9a-f+]+:10( |$)' && [ $D5 = 1 ] && [ $SA = reshape ] && [ \$(cat /sys/block/$N5/md/raid_disks) = 4 ] && [ \$(qgld $WQ/q51/d0.img $NID | wc -l) = 1 ] && qgld $WQ/q51/d0.img $NID | grep -qE 'type=1bf5 st=20[01] tt=0 lo=535[48] ts=a1a6 cap=30000 .* fs=1x4 tf=0' && cmp -s -n $((32 << 20)) $WQ/q51/pat <(sudo dd if=/dev/$N5 bs=1M count=32 iflag=direct status=none)"
qgdrop q51
# an md bitmap: md reshapes none (Grow.c refuses, as for its own arrays)
qgmk q51 4 1
$M -C /dev/md/amd51 -e amd -n 3 $(qgl 0) $(qgl 1) $(qgl 2) --run >/dev/null 2>&1; CN=$(cont1)
$M -C /dev/md/b51 -e amd -l5 -n3 -z 32M --bitmap=internal $(qgl 0) $(qgl 1) $(qgl 2) --run >/dev/null 2>&1
$M /dev/$CN --add $(qgl 3) >/dev/null 2>&1; sleep 1; waitrec; B=$(qgmd b51)
check "51: a volume with an md bitmap: refused (remove it first), untouched" "[ \"\$(cat /sys/block/$B/md/consistency_policy)\" != bitmap ] || { $M --grow /dev/$B --raid-devices=4 2>&1 | grep -q 'write-intent bitmap consistency policy' && [ \$(cat /sys/block/$B/md/raid_disks) = 3 ]; }"
qgdrop q51
# the AMD driver's own migrations, midway (q8m-e2mid: RAID5 3 -> 4, rcadm -s 6000 grew the elements too, the log at
# 0x36000; q8m-e3bmid: RAID1 -> RAID5 3, the elements shrink - md runs the old size, past the new elements' end on
# the new disk, free there - the log at 0x12000): md goes on with them, mdmon ends them as the AMD driver does
for F in e2mid:b94efa9997052291:0x36000:4:e2post e3bmid:aafbccc7a2833ae2:0x12000:3:e3bpost; do
	S=${F%%:*}; F=${F#*:}; ID=${F%%:*}; F=${F#*:}; MK=$((${F%%:*})); F=${F#*:}; ND=${F%%:*}; POST=${F#*:}
	qgfix q51 $Q51D q8m-$S
	xz -dc $Q51D/q8m-$POST-sata0-lba0-6000.img.xz > $WQ/q51/rc.img
	E=$($M -E $(qgl 0) 2>/dev/null | sed -n "/Volume ID : $ID/,/Member/p")
	check "51: q8m-$S (the AMD driver's migration midway): -E - raid5 read-write, the migration and its progress" "echo \"\$E\" | grep -q 'RAID Level : raid5' && echo \"\$E\" | grep -q 'md support : read-write' && echo \"\$E\" | grep -qE 'Migration : RAID[0-9N]+ 1 x [23], [0-9]+ MiB -> RAID50 1 x $ND, [0-9]+ MiB; [0-9]+% done'"
	echo 3000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
	qgasm; V=""; for m in $(mdof raid5); do grep -q reshape /sys/block/$m/md/sync_action && V=$m; done
	RS=$(cat /sys/block/$V/md/reshape_position 2>/dev/null)
	check "51: q8m-$S assembled: md reshapes onto $ND disks from the log's mark ($MK), every member's data moving to + 0x800" "[ -n '$V' ] && [ \"\$RS\" -ge $MK ] && [ \"\$RS\" -lt $((MK + 0x40000)) ] && [ \$(for d in /sys/block/$V/md/dev-*; do echo \$((\$(cat \$d/offset) - \$(cat \$d/new_offset))); done | sort -u) = $((0x4800)) ]"
	echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
	q51wait; sleep 3; SZ=$(cat /sys/block/$V/size 2>/dev/null); stopall
	check "51: q8m-$S ended by mdmon: its LD = the one the AMD driver ends it with (q8m-$POST), md at its capacity ($SZ), no log of it left" "[ -n \"\$(qgld $WQ/q51/rc.img $ID)\" ] && [ \"\$(qgld $WQ/q51/d0.img $ID)\" = \"\$(qgld $WQ/q51/rc.img $ID)\" ] && [ $((SZ)) = \$((0x\$(qgld $WQ/q51/rc.img $ID | grep -o 'cap=[0-9a-f]*' | cut -d= -f2))) ] && q51nolog $ID \$(qgld $WQ/q51/rc.img $ID | grep -o 'e[0-9]*=[0-9a-f]*:[0-9a-f]*' | cut -d: -f2)"
done
qgdrop q51
fi
# --- end of stage 51 ---

# --- stage 54: RAID0 + disks: mdadm --grow <RAID0> --raid-devices=N - as rcadm -T -r0 does it (q8m-e1mid): a start
# packet (the source NORMAL 0x22211, protect 0x7e00 - RC_TransformProtectSize in whole stripes of both LDs, Flags
# 0x20010, Link 1, elements 0x10000; the target a RAID0 N x 1, 0x12211, elements 0x30000 / the new one 0x40000, data
# at + 0x800), the log before each region on [0], "100 %", the log zeroed, the final packet (elements' flags 0). md
# takes the raid0 over as a raid4 without its parity (Grow.c), reshapes with data_offset 0x4800 sectors down, held by
# the log; a raid0 again at the end. Interrupted - goes on from the mark, also from 0 (nothing moved yet). The AMD
# driver's own migrations midway: q8m-e1mid (the data from + 0x5000 to + 0x800) and q8m-e1cmid (a second growth, the
# data at + 0x800 already stay, the regions moved in place between the layouts) - md ends them, the final packet as
# AMD's (q8m-e1post, q8m-e1cpost); a second growth in its first stripes (AMD moves those with a log of their data) -
# finished there as the volume is assembled (stage 65; 1.5.1 did not assemble it). 1.4 refused such a --grow and
# did not assemble RAID0 volumes in the middle of such a migration.
if want 54; then
stopall
Q54D=$FIXT/2026-11-15-rcraid-migrations
q54mark() { sudo dd if=$1 bs=512 skip=$(($2)) count=1 iflag=direct status=none | python3 -c 'import sys,struct; b=sys.stdin.buffer.read(); print(struct.unpack_from("<Q", b, 0x1c)[0] if struct.unpack_from("<I", b, 0x18)[0] else -1)'; }
# q54lag <md> <seconds> <loop:LBA>: while md reshapes - how far it is past the log's mark: "samples worst"
q54lag() { local md=$1 t=$(( $(date +%s) + $2 )) r m d worst=0 n=0
	while [ $(date +%s) -lt $t ]; do r=$(cat /sys/block/$md/md/reshape_position); [ "$r" = none ] && break
		m=$(q54mark ${3%:*} ${3#*:}); [ $m -ge 0 ] && { d=$((r - m)); [ $d -gt $worst ] && worst=$d; n=$((n + 1)); }; done
	echo "$n $worst"; }
q54wait() { for i in $(seq 1 600); do grep -qE 'reshape|resync|recover|check' /proc/mdstat || { sleep 3; grep -qE 'reshape|resync|recover|check' /proc/mdstat || return 0; }; sleep 2; done; return 1; }
q54offs() { cat /sys/block/$1/md/dev-*/$2 | sort -u | tr '\n' ' '; }	# offset / new_offset of the members
# q54raid0 <md> <disks>: md is a raid0 of so many disks again (Grow.c changes the level after the reshape)
q54raid0() { for i in $(seq 1 60); do [ "$(cat /sys/block/$1/md/level 2>/dev/null)" = raid0 ] && [ $(cat /sys/block/$1/md/raid_disks) = $2 ] && return 0; sleep 1; done; return 1; }
qgmk q54 5 1
$M -C /dev/md/amd54 -e amd -n 3 $(qgl 0) $(qgl 1) $(qgl 2) --run >/dev/null 2>&1; CN=$(cont1)
$M -C /dev/md/z54 -e amd -l0 -n2 -z 64M $(qgl 0) $(qgl 1) --run >/dev/null 2>&1
$M -C /dev/md/m54 -e amd -l1 -n2 -z 16M $(qgl 0) $(qgl 1) --run --assume-clean >/dev/null 2>&1	# mdmon runs for it
sleep 1; Z=$(qgmd z54); ZID=$(qgids $WQ/q54/d0.img | sed -n 1p)
check "54: RAID0 --raid-devices=3, no spare in the container: refused (Grow.c)" "$M --grow /dev/$Z --raid-devices=3 2>&1 | grep -q 'Need 1 spare' && [ \$(cat /sys/block/$Z/md/raid_disks) = 2 ]"
$M /dev/$CN --add $(qgl 3) >/dev/null 2>&1; sleep 1
check "54: RAID0 + disks with another chunk or a backup file: refused, untouched" "$M --grow /dev/$Z --raid-devices=3 --chunk=128 2>&1 | grep -qE 'AMD keeps the chunk as it is, 64 KiB|level and chunk' && $M --grow /dev/$Z --raid-devices=3 --backup-file=$WQ/q54/bk 2>&1 | grep -q 'no backup file' && [ \$(cat /sys/block/$Z/md/level) = raid0 ] && [ \$(cat /sys/block/$Z/md/raid_disks) = 2 ] && [ -z \"\$(qgld $WQ/q54/d0.img $ZID | grep -v 'tt=0')\" ]"
head -c 128M /dev/urandom > $WQ/q54/pat; sudo dd if=$WQ/q54/pat of=/dev/$Z bs=1M oflag=direct status=none
G0=$(qgring $WQ/q54/d0.img | tail -1)
echo 3000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
$M --grow /dev/$Z --raid-devices=3 > $WQ/q54/grow.out 2>&1; sleep 3
check "54: --raid-devices=3: md takes the RAID0 over as a raid4 of 2 + 1 without its parity, reshapes onto 3 (+ the parity's place), every member's data 0x4800 down (0x105000 -> 0x100800, the new disk too, in the old parity's slot, recovering), blocked for mdmon (external:-)" "grep -q '2 -> 3 disks; mdmon records it as an AMD migration' $WQ/q54/grow.out && [ \$(cat /sys/block/$Z/md/level) = raid4 ] && [ \$(cat /sys/block/$Z/md/sync_action) = reshape ] && [ \"\$(cat /sys/block/$Z/md/raid_disks)\" = '4 (3)' ] && [ \"\$(q54offs $Z offset)\" = '$((0x105000)) ' ] && [ \"\$(q54offs $Z new_offset)\" = '$((0x100800)) ' ] && [ \$(cat /sys/block/$Z/md/rd2/state) = spare ] && grep -q 'external:-' /sys/block/$Z/md/metadata_version"
S1=$(qgld $WQ/q54/d0.img $ZID $((G0 + 1)))
check "54: start packet (the next one): the RAID0 2 x 1 NORMAL 0x22211, protect 0x7e00 (RC_TransformProtectSize of 2 -> 3), Flags 0x20010, Link 1, elements 0x10000; the RAID0 3 x 1 it becomes - LastOperation NORMAL, 0x12211, 192 MiB, generation of the packet, its elements at the same extents (0x30000), the spare's first-fit (0x40000), data at + 0x800 (as rcadm -T -r0, q8m-e1mid)" "[ \$(echo \"\$S1\" | wc -l) = 2 ] && echo \"\$S1\" | head -1 | grep -qE '^type=1bf6 st=200 tt=5354 lo=5354 ts=0 cap=40000 ps=0 .* fs=2x1 tf=22211 psz=7e00 fl=20010 lk=1 pct=0 at=0( e[01]=[0-9a-f]+:100000\\+25000:105000\\+20000:10000){2}$' && echo \"\$S1\" | tail -1 | grep -qE \"^type=1bf6 st=200 tt=0 lo=5354 ts=0 cap=60000 ps=0 gen=$(printf %x $((G0 + 1))) fs=3x1 tf=12211 psz=0 fl=0 lk=0 pct=0 at=0( e[01]=[0-9a-f]+:100000\\\\+25000:100800\\\\+20000:30000){2} e2=[0-9a-f]+:100000\\\\+25000:100800\\\\+20000:40000$\""
check "54: the log before each region: NORMAL STARTED at a region, the source's flags, I/O 0x600, 0x15 to the 0x7e00 region, on [0] only" "T=\$(qgtlog $(qgl 0) 0x100000); echo \"\$T\" | grep -qE '^5354 [0-9a-f]+ 1 600 22211 7e00 15$' && [ \$((0x\$(echo \$T | cut -d' ' -f2) % 0x7e00)) = 0 ] && [ \"\$(qgtlog $(qgl 1) 0x100000)\" = '0 0 0 0 0 0 0' ] && [ \"\$(qgtlog $(qgl 3) 0x100000)\" = '0 0 0 0 0 0 0' ]"
LAG=$(q54lag $Z 6 $(qgl 0):0x100000)
check "54: md held behind the log: never more than a region past its mark on disk (${LAG#* } of $((0x7e00)), ${LAG% *} samples)" "[ ${LAG% *} -gt 5 ] && [ ${LAG#* } -le $((0x7e00)) ]"
$M -S /dev/$Z >/dev/null 2>&1; sleep 1
T=$(qgtlog $(qgl 0) 0x100000); D=$((0x$(echo $T | cut -d' ' -f2)))
check "54: stopped midway: the log on, at a region past 0 ($D); -E says the migration" "[ $D -gt 0 ] && [ $((D % 0x7e00)) = 0 ] && $M -E $(qgl 0) | grep -q 'Migration : RAID10N 2 x 1, 128 MiB -> RAID10N 3 x 1, 192 MiB; [0-9]*% done'"
stopall; qgasm; Z=$(qgmd z54)
RS=$(cat /sys/block/$Z/md/reshape_position 2>/dev/null); RC=$(cat /sys/block/$Z/md/rd2/recovery_start 2>/dev/null)
check "54: assembled again (-I): md raid4 goes on with the reshape from the log's mark, the new disk in sync up to it, the new offsets again, held and blocked" "[ \$(cat /sys/block/$Z/md/level) = raid4 ] && [ \"\$RS\" -ge $D ] && [ \"\$RS\" -lt $((D + 4 * 0x7e00)) ] && [ \"\$RC\" -ge $((D / 3)) ] && [ \"\$(q54offs $Z new_offset)\" = '$((0x100800)) ' ] && grep -q 'external:-' /sys/block/$Z/md/metadata_version && [ \$(cat /sys/block/$Z/md/sync_max) != max ]"
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
q54wait; q54raid0 $Z 3; sleep 2
G1=$(qgring $WQ/q54/d0.img | tail -1)
P100=$(qgld $WQ/q54/d0.img $ZID $((G1 - 1))); PF=$(qgld $WQ/q54/d0.img $ZID $G1)
check "54: \"100 %\" packet (the RAID0 2 x 1 COMPLETED at 192 MiB, 100000, Flags 0x84; the new one NORMAL STARTED as far), then the final one: one LD RAID0 3 x 1, 192 MiB, LastOperation NORMAL COMPLETED, generation as made, elements flags 0, data at + 0x800; log cleared" "echo \"\$P100\" | head -1 | grep -q 'tt=5354 lo=5354 ts=a1a6 cap=40000 ps=60000 .* fs=2x1 .* psz=0 fl=84 lk=1 pct=186a0' && echo \"\$P100\" | tail -1 | grep -q 'tt=5354 lo=5354 ts=a1a1 cap=60000 ps=60000 .* fs=3x1 .* pct=186a0' && [ \$(echo \"\$PF\" | wc -l) = 1 ] && echo \"\$PF\" | grep -qE \"^type=1bf6 st=200 tt=0 lo=5354 ts=a1a6 cap=60000 ps=0 gen=$(printf %x $((G0 + 1))) fs=3x1 tf=0 psz=0 fl=0 lk=0 pct=0 at=0( e[0-2]=[0-9a-f]+:100000\\\\+25000:100800\\\\+20000:0){3}$\" && [ \"\$(qgtlog $(qgl 0) 0x100000)\" = '0 0 0 0 0 0 0' ]"
check "54: done: md raid0 of 3 again, 192 MiB, data at 0x100800, not blocked; the data as written" "[ \$(cat /sys/block/$Z/md/level) = raid0 ] && [ \$(cat /sys/block/$Z/size) = $((0x60000)) ] && [ \"\$(q54offs $Z offset)\" = '$((0x100800)) ' ] && grep -q 'external:/' /sys/block/$Z/md/metadata_version && cmp -s $WQ/q54/pat <(sudo dd if=/dev/$Z bs=1M count=128 iflag=direct status=none)"
stopall; qgasm; Z=$(qgmd z54)
check "54: assembled again: raid0 of 3 at 0x100800, the data as written" "[ \$(cat /sys/block/$Z/md/level) = raid0 ] && [ \$(cat /sys/block/$Z/md/raid_disks) = 3 ] && [ \"\$(q54offs $Z offset)\" = '$((0x100800)) ' ] && cmp -s $WQ/q54/pat <(sudo dd if=/dev/$Z bs=1M count=128 iflag=direct status=none)"
check "54: data moved by a migration already: no backup file either (AMD keeps its own log of the data; the second migration - stage 65)" "$M /dev/$CN --add $(qgl 4) >/dev/null 2>&1; sleep 1; $M --grow /dev/$Z --raid-devices=4 --backup-file=$WQ/q54/bk 2>&1 | grep -q 'AMD keeps what it backs up in its own log of the data: no backup file' && [ \$(cat /sys/block/$Z/md/level) = raid0 ]"
# nothing moved yet (the log at 0): md goes on from 0, as the AMD driver (stage 55) - a raid4 from 0, then a
# RAID0 again
$M -C /dev/md/n54 -e amd -l0 -n2 -z 64M $(qgl 0) $(qgl 1) --run >/dev/null 2>&1; sleep 1; N0=$(qgmd n54)
NID=$(qgids $WQ/q54/d0.img | sed -n 3p)
head -c 128M /dev/urandom > $WQ/q54/pat; sudo dd if=$WQ/q54/pat of=/dev/$N0 bs=1M oflag=direct status=none
echo 50 | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null; echo 100 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
$M --grow /dev/$N0 --raid-devices=3 > $WQ/q54/grow.out 2>&1; sleep 2; $M -S /dev/$N0 >/dev/null 2>&1; sleep 1
check "54: stopped before md moved a region: the log at 0" "grep -q '2 -> 3 disks' $WQ/q54/grow.out && qgld $WQ/q54/d0.img $NID | head -1 | grep -q 'tt=5354' && $M -E $(qgl 0) | grep -q 'Migration : RAID10N 2 x 1, 128 MiB -> RAID10N 3 x 1, 192 MiB; 0% done'"
stopall; qgasm; N0=$(qgmd n54)
check "54: ... assembled: md goes on from 0, as the AMD driver - raid4 of 2 + 1 without its parity reshaping, the migration kept" "[ \$(cat /sys/block/$N0/md/level) = raid4 ] && [ \"\$(cat /sys/block/$N0/md/raid_disks)\" = '4 (3)' ] && [ \"\$(cat /sys/block/$N0/md/reshape_position)\" != none ] && [ \$(qgld $WQ/q54/d0.img $NID | wc -l) = 2 ]"
echo 1000 | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null; echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
q54wait; q54raid0 $N0 3; sleep 2
check "54: ... done: one LD RAID0 3 x 1, raid0 of 3; the data as written" "[ \$(cat /sys/block/$N0/md/level) = raid0 ] && [ \$(cat /sys/block/$N0/md/raid_disks) = 3 ] && [ \$(qgld $WQ/q54/d0.img $NID | wc -l) = 1 ] && qgld $WQ/q54/d0.img $NID | grep -q 'type=1bf6 st=200 tt=0 lo=5354 ts=a1a6 cap=60000 .* fs=3x1 tf=0' && cmp -s $WQ/q54/pat <(sudo dd if=/dev/$N0 bs=1M count=128 iflag=direct status=none)"
qgdrop q54
# at full speed, written to meanwhile: md never more than a region past the log; the data with the writes
qgmk q54 4 1
$M -C /dev/md/amd54 -e amd -n 3 $(qgl 0) $(qgl 1) $(qgl 2) --run >/dev/null 2>&1; CN=$(cont1)
$M -C /dev/md/w54 -e amd -l0 -n3 -z 64M $(qgl 0) $(qgl 1) $(qgl 2) --run >/dev/null 2>&1
$M -C /dev/md/m54 -e amd -l1 -n2 -z 16M $(qgl 0) $(qgl 1) --run --assume-clean >/dev/null 2>&1
$M /dev/$CN --add $(qgl 3) >/dev/null 2>&1; sleep 1; W0=$(qgmd w54); WID=$(qgids $WQ/q54/d0.img | sed -n 1p)
head -c 192M /dev/urandom > $WQ/q54/pat; sudo dd if=$WQ/q54/pat of=/dev/$W0 bs=1M oflag=direct status=none
cp $WQ/q54/pat $WQ/q54/model; G0=$(qgring $WQ/q54/d0.img | tail -1)
( for i in $(seq 1 150); do o=$((RANDOM % 192)); head -c 1M /dev/urandom > $WQ/q54/blk
	sudo dd if=$WQ/q54/blk of=/dev/$W0 bs=1M seek=$o oflag=direct conv=notrunc status=none 2>/dev/null
	dd if=$WQ/q54/blk of=$WQ/q54/model bs=1M seek=$o conv=notrunc status=none; done ) &
WP=$!
$M --grow /dev/$W0 --raid-devices=4 > $WQ/q54/grow.out 2>&1
LAG=$(q54lag $W0 60 $(qgl 0):0x100000)
wait $WP; q54wait; q54raid0 $W0 4; sleep 2
check "54: RAID0 3 -> 4 at full speed, written to meanwhile: protect 0x7e00 (3 -> 4: 4 x 0x4800 capped at 0x8000, in whole stripes of both, 0x600); md held behind the log (${LAG#* } of $((0x7e00)), ${LAG% *} samples); raid0 of 4, 256 MiB, one LD RAID0 4 x 1; the data with the writes made meanwhile" "grep -q '3 -> 4 disks' $WQ/q54/grow.out && qgld $WQ/q54/d0.img $WID $((G0 + 1)) | head -1 | grep -q 'fs=3x1 tf=22211 psz=7e00 fl=20010' && [ ${LAG#* } -le $((0x7e00)) ] && [ \$(cat /sys/block/$W0/md/level) = raid0 ] && [ \$(cat /sys/block/$W0/size) = $((0x80000)) ] && [ \$(qgld $WQ/q54/d0.img $WID | wc -l) = 1 ] && qgld $WQ/q54/d0.img $WID | grep -q 'tt=0 lo=5354 ts=a1a6 cap=80000 .* fs=4x1 tf=0' && cmp -s $WQ/q54/model <(sudo dd if=/dev/$W0 bs=1M count=192 iflag=direct status=none)"
qgdrop q54
# the AMD driver's own migrations, midway: q8m-e1mid (RAID0 2 -> 3, the data move down, the log at 0x7e000) and
# q8m-e1cmid (3 -> 4, the second: the data at + 0x800 already stay - no offset change -, the log at 0x29c00): md goes
# on with them, mdmon ends them as the AMD driver does
for F in e1mid:0x7e000:3:e1post:4800:22211 e1cmid:0x29c00:4:e1cpost:0:12141; do
	S=${F%%:*}; F=${F#*:}; MK=$((${F%%:*})); F=${F#*:}; ND=${F%%:*}; F=${F#*:}; POST=${F%%:*}; F=${F#*:}; SH=$((0x${F%%:*})); TF=${F#*:}
	ID=9713116afc2df294
	qgfix q54 $Q54D q8m-$S
	xz -dc $Q54D/q8m-$POST-sata0-lba0-6000.img.xz > $WQ/q54/rc.img
	E=$($M -E $(qgl 0) 2>/dev/null | sed -n "/Volume ID : $ID/,/Member/p")
	check "54: q8m-$S (the AMD driver's RAID0 migration midway): -E - raid0 read-write, the migration and its progress" "echo \"\$E\" | grep -q 'RAID Level : raid0' && echo \"\$E\" | grep -q 'md support : read-write' && echo \"\$E\" | grep -qE 'Migration : RAID10N $((ND - 1)) x 1, 3816 MiB -> RAID10N $ND x 1, 3816 MiB; [0-9]+% done'"
	echo 3000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
	qgasm; V=""; for m in $(mdof raid4); do grep -q reshape /sys/block/$m/md/sync_action && V=$m; done
	RS=$(cat /sys/block/$V/md/reshape_position 2>/dev/null); sleep 2
	check "54: q8m-$S assembled: md raid4 reshapes onto $ND disks from the log's mark ($MK), every member's data $SH sectors down; the log goes on from there, the source's flags ($TF)" "[ -n '$V' ] && [ \"\$RS\" -ge $MK ] && [ \"\$RS\" -lt $((MK + 0x10000)) ] && [ \$(for d in /sys/block/$V/md/dev-*; do echo \$((\$(cat \$d/offset) - \$(cat \$d/new_offset))); done | sort -u) = $SH ] && qgtlog $(qgl 0) 0x100000 | grep -qE '^5354 [0-9a-f]+ 1 600 $TF 7e00 15$'"
	echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
	q54wait; q54raid0 $V $ND; sleep 2; SZ=$(cat /sys/block/$V/size 2>/dev/null); stopall
	check "54: q8m-$S ended by mdmon: its LD = the one the AMD driver ends it with (q8m-$POST), md at its capacity ($SZ), the log cleared" "[ -n \"\$(qgld $WQ/q54/rc.img $ID)\" ] && [ \"\$(qgld $WQ/q54/d0.img $ID)\" = \"\$(qgld $WQ/q54/rc.img $ID)\" ] && [ $((SZ)) = $((0x774000)) ] && [ \"\$(qgtlog $(qgl 0) 0x100000)\" = '0 0 0 0 0 0 0' ]"
done
# ... q8m-e1cmid with its mark in the first stripes (the log made so: the stripe at 0x400 whole in AMD's log of the
# data, 0x512141; LogDataRange 0x600): md cannot go on there - mdadm moves them as the volume is assembled
qgfix q54 $Q54D q8m-e1cmid
sudo python3 $HLP/tlog-patch.py $(qgl 0) 0x100000 ProtectStart=0x400 IOStart=0x400 Flags=0x512141 --write >/dev/null; sudo blockdev --flushbufs $(qgl 0)
OUT=$(for l in $QGL; do $M -I $l 2>&1; done); sleep 2
check "54: q8m-e1cmid at 0x400 (AMD's first stripes, with their data logged): assembled - the first stripes moved as the AMD driver moves them, md raid4 goes on from LogDataRange" "[ -n \"\$(mdof raid4)\" ] && echo \"\$OUT\" | grep -q 'its first stripes moved through the AMD log of the data, as the AMD driver does: md goes on from 1536'"
qgdrop q54
fi
# --- end of stage 54 ---

# --- stage 52: disks that went away together. RAID1 A on d0+d1, RAID1 B on d1+d2 (loop devices of 1 GiB, volumes
# of 64 MiB, random data).
# 52a - d1 and d2 go away together, A runs degraded and is written to. They come back: B is assembled [2/2] from them
#       without a rebuild (they have one and the same packet, no up-to-date disk of B holds it: md did not write B -
#       amd_volume_left; the AMD driver rcraid 9.3.3-00302 does the same), A is rebuilt onto d1, the end of the
#       rebuild recorded, one generation on all.
# 52b - d2 went away before d1 (a configuration written between them, --update-subarray): the packets of d1 and d2
#       differ, so B is not taken back (not assembled, as before), but the end of A's rebuild is recorded all the
#       same: d2 is here, behind, and takes no configuration - there is no reason to wait for it (amd_all_disks_here).
# 52c - the AMD driver's configuration (rcraid 9.3.3-00302, q9g-b: its RAID1 on d0+d1, d2-d4 free disks, its
#       serial): -I d0, d1 - mdmon takes it over and writes d0, d1; mdmon --takeover (a new session, the memory of
#       the takeover gone); -I of the free d2 with rcraid's packet: it gets the live configuration - mdmon finds the
#       packet it took over in the ring (amd_find_taken). (A member of a volume cannot be checked so: it is a rebuild
#       target in place and gets the configuration anyway.)
if want 52; then
cd "$MDADM_DIR"
stopall
Q52=$WQ/q52
q52drop() { stopall; for l in $(sudo losetup -a | grep "$Q52/" | cut -d: -f1); do sudo losetup -d $l; done; }
q52md() { local p; for p in /dev/md/$1 /dev/md/${1}_0; do [ -e $p ] && { basename $(readlink -f $p); return; }; done; }
q52sum() { local m=$(q52md $1); [ -n "$m" ] && sudo md5sum /dev/$m | cut -c1-32; }
q52mm() { local m=$(q52md $1); echo check | sudo tee /sys/block/$m/md/sync_action >/dev/null; sleep 1
	while ! grep -q idle /sys/block/$m/md/sync_action; do sleep 1; done; cat /sys/block/$m/md/mismatch_cnt; }
q52st() { local m=$(q52md $1); [ -n "$m" ] && grep -A1 "^$m " /proc/mdstat | grep -o '\[[0-9]/[0-9]\]'; }
q52gen() { $M -E $1 2>/dev/null | sed -n 's/^ *Generation : //p' | head -1; }
q52vol() { $M -E $2 2>/dev/null | sed -n "/^\[$1\]:/,/^\[/p"; }
# q52mk <dir>: three loop devices of 1 GiB, the container, A, B, data; Q52L - the loop devices, Q52A/Q52B - md5
q52mk() { local n v; q52drop; rm -rf $Q52/$1; mkdir -p $Q52/$1; Q52L=()
	for n in 0 1 2; do truncate -s 1G $Q52/$1/d$n.img; Q52L[$n]=$(sudo losetup -f --show $Q52/$1/d$n.img); done
	$M -C /dev/md/q52c -e amd -n3 ${Q52L[@]} --run >/dev/null 2>&1
	$M -C /dev/md/q52a -e amd -l1 -n2 -z 64M ${Q52L[0]} ${Q52L[1]} --run --assume-clean >/dev/null 2>&1
	$M -C /dev/md/q52b -e amd -l1 -n2 -z 64M ${Q52L[1]} ${Q52L[2]} --run --assume-clean >/dev/null 2>&1; sleep 2
	for v in q52a q52b; do sudo dd if=/dev/urandom of=/dev/$(q52md $v) bs=1M count=64 oflag=direct status=none; done
	Q52B=$(q52sum q52b); stopall; }
# q52away <loop>...: only these: -I one by one, -IRs, 8 MiB into A; Q52A - md5 of A
q52away() { local l; for l in "$@"; do $M -I $l >/dev/null 2>&1; done; $M -IRs >/dev/null 2>&1; sleep 2
	sudo dd if=/dev/urandom of=/dev/$(q52md q52a) bs=1M count=8 seek=8 oflag=direct status=none; sleep 1
	Q52A=$(q52sum q52a); stopall; }
# q52back: all three: -A of the container, -I, a pause, -IR, wait
q52back() { sudo dmesg -C; $M -A /dev/md/q52c -e amd ${Q52L[@]} >/dev/null 2>&1; $M -I /dev/md/q52c >/dev/null 2>&1; sleep 5
	$M -IR /dev/md/q52c >/dev/null 2>&1; sleep 3; waitrec; sleep 5; waitrec; }

# 52a
q52mk a
q52away ${Q52L[0]}
q52back
check "52a: B, both disks away together, assembled from them: [2/2] without a recovery, the data as written, md check 0" "[ \"\$(q52st q52b)\" = '[2/2]' ] && ! sudo dmesg | grep -q \"recover of RAID array \$(q52md q52b)\\\$\" && [ \"\$(q52sum q52b)\" = '$Q52B' ] && [ \$(q52mm q52b) = 0 ]"
check "52a: A rebuilt onto d1: [2/2], the data as written, md check 0" "[ \"\$(q52st q52a)\" = '[2/2]' ] && [ \"\$(q52sum q52a)\" = '$Q52A' ] && [ \$(q52mm q52a) = 0 ]"
stopall
check "52a: recorded: A and B NORMAL, every member in service, one generation on the three disks" "q52vol q52a ${Q52L[0]} | grep -q 'State : 0x200 (normal)' && q52vol q52b ${Q52L[0]} | grep -q 'State : 0x200 (normal)' && ! $M -E ${Q52L[0]} | grep -q 'out of service' && [ \"\$(q52gen ${Q52L[1]})\" = \"\$(q52gen ${Q52L[0]})\" ] && [ \"\$(q52gen ${Q52L[2]})\" = \"\$(q52gen ${Q52L[0]})\" ]"
q52drop

# 52b: d2 away first, a configuration written without it (the cache policy of A), then d1 too
q52mk b
$M -I ${Q52L[0]} >/dev/null 2>&1; $M -I ${Q52L[1]} >/dev/null 2>&1; sleep 2
C52=$(grep -B1 "super external:amd" /proc/mdstat | grep -o "^md[0-9]*" | head -1)
$M --update-subarray=0 --update=no-write-back /dev/$C52 >/dev/null 2>&1; sleep 2; stopall
Q52G1=$(q52gen ${Q52L[1]}); Q52G2=$(q52gen ${Q52L[2]})
q52away ${Q52L[0]}
q52back
echo "     52b: A $(q52st q52a) $(q52sum q52a | cut -c1-8) (written $(echo $Q52A | cut -c1-8)), B $(q52st q52b) $(q52sum q52b | cut -c1-8) (written $(echo $Q52B | cut -c1-8)), recoveries of B: $(sudo dmesg | grep -c "recover of RAID array $(q52md q52b)$")"
check "52b: d1 and d2 back with different packets ($Q52G1, $Q52G2): B not taken from both (not assembled, or from d1 once it is up to date, d2 rebuilt), A rebuilt onto d1, the data as written" "[ -n '$Q52G1' ] && [ '$Q52G1' != '$Q52G2' ] && { [ -z \"\$(q52st q52b)\" ] || { sudo dmesg | grep -q \"recover of RAID array \$(q52md q52b)\\\$\" && [ \"\$(q52sum q52b)\" = '$Q52B' ]; }; } && [ \"\$(q52st q52a)\" = '[2/2]' ] && [ \"\$(q52sum q52a)\" = '$Q52A' ]"
stopall
check "52b: the end of A's rebuild recorded though d2, stale, is here: A NORMAL with d1 in service" "q52vol q52a ${Q52L[0]} | grep -q 'State : 0x200 (normal)' && ! q52vol q52a ${Q52L[0]} | grep -q 'out of service'"
q52drop

# 52c: the AMD driver's configuration (q9g-b: rcraid's RAID1 on d0+d1, d2-d4 free disks, its serial), d0 and d1
# first: mdmon takes it over (written to them, generation +1); mdmon --takeover (a new session); a free disk then
F52=$FIXT/2026-11-15-rcraid-grow
rm -rf $Q52/c; mkdir -p $Q52/c; Q52L=()
for n in 0 1 2 3 4; do truncate -s 8G $Q52/c/d$n.img
	xz -dc $F52/q9g-b-sata$n-lba0-6000.img.xz | dd of=$Q52/c/d$n.img conv=notrunc status=none
	Q52L[$n]=$(sudo losetup -f --show $Q52/c/d$n.img); done
Q52F=$(q52gen ${Q52L[2]})
$M -I ${Q52L[0]} >/dev/null 2>&1; $M -I ${Q52L[1]} >/dev/null 2>&1
for i in $(seq 1 20); do [ "$(q52gen ${Q52L[0]})" != "$Q52F" ] && break; sleep 0.5; done
C52=$(grep -B1 "super external:amd" /proc/mdstat | grep -o "^md[0-9]*" | head -1)
Q52T=$(q52gen ${Q52L[0]})
sudo -E ./mdmon --takeover $C52; sleep 3
$M -I ${Q52L[2]} >/dev/null 2>&1; sleep 2
for i in $(seq 1 20); do [ "$(q52gen ${Q52L[2]})" = "$(q52gen ${Q52L[0]})" ] && break; sleep 0.5; done
check "52c: taken over ($Q52F -> $Q52T, AMD's serial), mdmon restarted: a free disk that comes then with the packet taken over has the live configuration" "[ -n '$C52' ] && [ -n '$Q52F' ] && [ '$Q52T' != '$Q52F' ] && [ \"\$(q52gen ${Q52L[2]})\" = \"\$(q52gen ${Q52L[0]})\" ] && ! $M -E ${Q52L[2]} 2>&1 | grep -q 'another controller' && $M -E ${Q52L[2]} 2>/dev/null | grep -q 'Controller SN : 859010220000'"
waitrec; stopall; q52drop; rm -rf $Q52
fi
# --- end of stage 52 ---

# --- stage 53: changing the chunk size: mdadm --grow <RAID5> --chunk=K (with --raid-devices=N or without) and
# <RAID10> --chunk=K. AMD's tools have no such operation of their own; mdadm records it as a migration the AMD driver
# carries out (tested with rcraid): the same LD, the target with the new CacheTagSize, the elements' data from
# + 0x5000 to + 0x800, flags 0x22211/0x12211, the region RC_TransformProtectSize in stripes of the source (RAID10
# 3 x 2 of 64K: 0x7f80). md reshapes with data_offset moving, held by the log (RAID10: its progress from
# /proc/mdstat); interrupted - goes on from the mark, also from 0; one such migration in a container at a time; the
# AMD driver's own, midway (fixture 2026-11-15-rcraid-chunk, chunk-mid: a RAID5 and a RAID10 at once, rcraid
# 9.3.3-00302) - md ends them one after the other, the final packets as AMD's (chunk-post). 1.4 refused --chunk
# ("AMD keeps the chunk as it is").
if want 53; then
stopall
Q53D=$FIXT/2026-11-15-rcraid-chunk
# q53cts <image> <LD ID hex>: CacheTagSize of the records of the LD of this ID in the live packet, space-separated
q53cts() { python3 - "$@" <<'PY'
import struct, sys
f = open(sys.argv[1], "rb"); ldid = int(sys.argv[2], 16)
f.seek(0x5001 * 512); off, size = struct.unpack_from("<II", f.read(512), 8)
f.seek(off * 512); p = f.read(size)
q, end = struct.unpack_from("<II", p, 0x2c); end += q; out = []
while q + 0x200 <= end and struct.unpack_from("<I", p, q)[0] == 0x25BD:
    sz = struct.unpack_from("<I", p, q + 0x90)[0]
    if not sz: break
    if struct.unpack_from("<Q", p, q + 0x2c)[0] == ldid: out.append(str(struct.unpack_from("<I", p, q + 0x110)[0]))
    q += sz
print(" ".join(out))
PY
}
q53mark() { sudo dd if=$1 bs=512 skip=$(($2)) count=1 iflag=direct status=none | python3 -c 'import sys,struct; b=sys.stdin.buffer.read(); print(struct.unpack_from("<Q", b, 0x1c)[0] if struct.unpack_from("<I", b, 0x18)[0] else -1)'; }
# q53pos <md>: how far md has reshaped it, sectors of the array (raid5: reshape_position; raid10: /proc/mdstat)
q53pos() { if [ "$(cat /sys/block/$1/md/level)" = raid10 ]; then
		echo $(( $(grep -A2 "^$1 " /proc/mdstat | sed -n 's/.*reshape = *[0-9.]*% (\([0-9]*\)\/.*/\1/p') * 2 ))
	else cat /sys/block/$1/md/reshape_position; fi; }
# q53lag <md> <seconds> <loop:LBA>...: while it reshapes - md past the furthest log mark, at most ("samples worst")
q53lag() { local md=$1 t=$(( $(date +%s) + $2 )) r m x d worst=0 n=0; shift 2
	while [ $(date +%s) -lt $t ]; do grep -q "^$md .*" /proc/mdstat && grep -A2 "^$md " /proc/mdstat | grep -q reshape || break
		r=$(q53pos $md); [ -n "$r" ] && [ "$r" != none ] || continue; m=-1
		for x in "$@"; do d=$(q53mark ${x%:*} ${x#*:}); [ $d -gt $m ] && m=$d; done
		[ $m -ge 0 ] && { d=$((r - m)); [ $d -gt $worst ] && worst=$d; n=$((n + 1)); }; done; echo "$n $worst"; }
q53wait() { for i in $(seq 1 600); do grep -qE 'reshape|resync|recover|check' /proc/mdstat || { sleep 3; grep -qE 'reshape|resync|recover|check' /proc/mdstat || return 0; }; sleep 2; done; return 1; }
# q53id <name> <disk>: the volume's ID (mdadm -E of disk d<n>)
q53id() { $M -E $(qgl $2) 2>/dev/null | sed -n "/\[$1\]/,/Volume ID/p" | sed -n 's/.*Volume ID : //p'; }
q53offs() { cat /sys/block/$1/md/dev-*/$2 | sort -u | tr '\n' ' '; }
q53check() { echo check | sudo tee /sys/block/$1/md/sync_action >/dev/null; sleep 1; q53wait; [ "$(cat /sys/block/$1/md/mismatch_cnt)" = 0 ]; }
q53fill() { head -c $2 /dev/urandom > $WQ/q53/pat-$1; sudo dd if=$WQ/q53/pat-$1 of=/dev/$(qgmd $1) bs=1M oflag=direct status=none; }
q53same() { cmp -s $WQ/q53/pat-$1 <(sudo dd if=/dev/$(qgmd $1) bs=1M count=$(( $(stat -c %s $WQ/q53/pat-$1) >> 20 )) iflag=direct status=none); }
qgmk q53 7 2
$M -C /dev/md/amd53 -e amd -n 6 $(qgl 0) $(qgl 1) $(qgl 2) $(qgl 3) $(qgl 4) $(qgl 5) --run >/dev/null 2>&1; CN=$(cont1)
$M -C /dev/md/c53 -e amd -l5 -n3 -c64 -z 128M $(qgl 0) $(qgl 1) $(qgl 2) --run >/dev/null 2>&1
$M -C /dev/md/r53 -e amd -l10 -n6 -c64 -z 64M $(qgl 0) $(qgl 1) $(qgl 2) $(qgl 3) $(qgl 4) $(qgl 5) --run >/dev/null 2>&1
$M -C /dev/md/n53 -e amd -l5 -n3 -c64 -z 64M $(qgl 3) $(qgl 4) $(qgl 5) --run >/dev/null 2>&1
$M -C /dev/md/m53 -e amd -l1 -n2 -z 32M $(qgl 0) $(qgl 1) --run >/dev/null 2>&1
$M -C /dev/md/z53 -e amd -l0 -n2 -c64 -z 32M $(qgl 2) $(qgl 3) --run >/dev/null 2>&1
sleep 1; waitrec
C=$(qgmd c53); R=$(qgmd r53); N=$(qgmd n53)
CID=$(q53id c53 0); RID=$(q53id r53 0); NID=$(q53id n53 3)
check "53: --chunk refused: 32 KiB (not a menu size), a RAID1, a RAID0, a RAID10 with more disks or another layout, a RAID5 of another layout, a backup file" "$M --grow /dev/$C --chunk=32 2>&1 | grep -q 'AMD RAID chunk size is 64, 128 or 256 KiB' && $M --grow /dev/$(qgmd m53) --chunk=128 2>&1 | grep -q 'changes the chunk of a RAID5 or a RAID10' && $M --grow /dev/$(qgmd z53) --chunk=128 2>&1 | grep -q 'changes the chunk of a RAID5 or a RAID10' && $M --grow /dev/$R --chunk=128 --layout=o2 2>&1 | grep -q 'AMD RAID10 is near only' && $M --grow /dev/$C --chunk=128 --layout=left-symmetric 2>&1 | grep -q 'right-asymmetric only' && $M --grow /dev/$C --chunk=128 --backup-file=$WQ/q53/bk 2>&1 | grep -q 'no backup file' && [ \$(cat /sys/block/$C/md/chunk_size) = 65536 ] && [ -z \"\$(qgld $WQ/q53/d0.img $CID | grep -v 'tt=0')\" ]"
q53fill c53 200M; q53fill r53 150M; q53fill n53 100M
G0=$(qgring $WQ/q53/d0.img | tail -1)
echo 3000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
$M --grow /dev/$C --chunk=128 > $WQ/q53/grow.out 2>&1; sleep 3
check "53: RAID5 --chunk=128: md reshapes 64 -> 128 KiB, every member's data 0x4800 sectors down (0x105000 -> 0x100800), the array blocked for mdmon" "grep -q 'chunk 64 -> 128 KiB; mdmon records it as an AMD migration' $WQ/q53/grow.out && [ \$(cat /sys/block/$C/md/sync_action) = reshape ] && [ \"\$(q53offs $C offset)\" = '$((0x105000)) ' ] && [ \"\$(q53offs $C new_offset)\" = '$((0x100800)) ' ] && grep -q 'external:-' /sys/block/$C/md/metadata_version"
S1=$(qgld $WQ/q53/d0.img $CID $((G0 + 1)))
check "53: start packet: the RAID5 1 x 3 NORMAL 0x22211, protect 0x9000, Flags 0x20010, Link 1, chunk 64 KiB; the same LD it becomes - LastOperation NORMAL, 0x12211, chunk 128 KiB (CacheTagSize 2), generation of the packet, its elements where they were, data at + 0x800" "[ \$(echo \"\$S1\" | wc -l) = 2 ] && echo \"\$S1\" | head -1 | grep -q 'type=1bf5 st=200 tt=5354 lo=5354 ts=0 cap=80000 ps=0 .* fs=1x3 tf=22211 psz=9000 fl=20010 lk=1 pct=0 at=1' && echo \"\$S1\" | tail -1 | grep -qE \"type=1bf5 st=200 tt=0 lo=5354 ts=0 cap=80000 ps=0 gen=$(printf %x $((G0 + 1))) fs=1x3 tf=12211 psz=0 fl=0 lk=0 pct=0 at=1( e[0-2]=[0-9a-f]+:100000\\\\+45000:100800\\\\+40000:0){3}$\" && [ \"\$(q53cts $WQ/q53/d0.img $CID)\" = '1 2' ]"
T=$(for d in 0 1 2; do qgtlog $(qgl $d) 0x100000; done | sort | uniq -c)
check "53: the log before each region on two of the elements (the stripe past the end): NORMAL STARTED at a region, the source's flags, I/O 0x600, 0x18 to the 0x9000 region (64 KiB's)" "echo \"\$T\" | grep -qE '^ *2 5354 [0-9a-f]+ 1 600 22211 9000 18$' && echo \"\$T\" | grep -qE '^ *1 0 0 0 0 0 0 0$'"
A0=$(for d in 0 1 2; do [ "$(qgtlog $(qgl $d) 0x100000)" != '0 0 0 0 0 0 0' ] && echo $(qgl $d):0x100000; done)
LAG=$(q53lag $C 6 $A0)
check "53: md held behind the log: never more than a region past its mark on disk (${LAG#* } of $((0x9000)), ${LAG% *} samples)" "[ ${LAG% *} -gt 5 ] && [ ${LAG#* } -le $((0x9000)) ]"
$M -S /dev/$C >/dev/null 2>&1; sleep 1
X=$(echo $A0 | cut -d' ' -f1); D=$(q53mark ${X%:*} ${X#*:}); D=${D:-0}
check "53: stopped midway: the log on, at a region past 0 ($D); -E says the migration, the chunks" "[ $D -gt 0 ] && [ $((D % 0x9000)) = 0 ] && $M -E $(qgl 0) | grep -q 'Migration : RAID50 1 x 3, 256 MiB, 64 KiB chunk -> RAID50 1 x 3, 256 MiB, 128 KiB chunk; [0-9]*% done'"
# (while md reshapes it, Grow.c refuses another volume itself: the container is held, "Unable to open container")
check "53: one such migration in the container at a time: --chunk of the RAID10 refused while the RAID5's is recorded" "$M --grow /dev/$R --chunk=256 2>&1 | grep -q 'another volume of the container is being migrated: one at a time' && [ \$(cat /sys/block/$R/md/chunk_size) = 65536 ] && [ \$(qgld $WQ/q53/d0.img $RID | wc -l) = 1 ]"
stopall; qgasm; C=$(qgmd c53)
RS=$(cat /sys/block/$C/md/reshape_position 2>/dev/null)
check "53: assembled again (-I): md goes on from the log's mark - chunk 128 KiB (64 KiB), the new offsets again - held and blocked" "[ \"\$RS\" -ge $D ] && [ \"\$RS\" -lt $((D + 4 * 0x9000)) ] && cat /sys/block/$C/md/chunk_size | grep -q '^131072 (65536)' && [ \"\$(q53offs $C new_offset)\" = '$((0x100800)) ' ] && grep -q 'external:-' /sys/block/$C/md/metadata_version && [ \$(cat /sys/block/$C/md/sync_max) != max ]"
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
q53wait; sleep 3
G1=$(qgring $WQ/q53/d0.img | tail -1)
P100=$(qgld $WQ/q53/d0.img $CID $((G1 - 1))); PF=$(qgld $WQ/q53/d0.img $CID $G1)
check "53: \"100 %\" packet, then the final one: one LD RAID5 1 x 3 of 128 KiB, LastOperation NORMAL COMPLETED, generation as made, data at + 0x800; log cleared" "echo \"\$P100\" | head -1 | grep -q 'tt=5354 lo=5354 ts=a1a6 cap=80000 ps=80000 .* fs=1x3 .* psz=0 fl=84 lk=1 pct=186a0' && echo \"\$P100\" | tail -1 | grep -q 'tt=5354 lo=5354 ts=a1a1 cap=80000 ps=80000 .* fs=1x3 .* pct=186a0' && [ \$(echo \"\$PF\" | wc -l) = 1 ] && echo \"\$PF\" | grep -qE \"type=1bf5 st=200 tt=0 lo=5354 ts=a1a6 cap=80000 ps=0 gen=$(printf %x $((G0 + 1))) fs=1x3 tf=0 psz=0 fl=0 lk=0 pct=0 at=1( e[0-2]=[0-9a-f]+:100000\\\\+45000:100800\\\\+40000:0){3}$\" && [ \"\$(q53cts $WQ/q53/d0.img $CID)\" = 2 ] && [ \"\$(for d in 0 1 2; do qgtlog \$(qgl \$d) 0x100000; done | sort -u)\" = '0 0 0 0 0 0 0' ]"
check "53: done: md raid5 of 128 KiB at 0x100800, not blocked; the data as written, md check 0" "[ \$(cat /sys/block/$C/md/chunk_size) = 131072 ] && [ \"\$(q53offs $C offset)\" = '$((0x100800)) ' ] && grep -q 'external:/' /sys/block/$C/md/metadata_version && q53same c53 && q53check $C"
check "53: the data moved by a migration already: another chunk with a disk refused (AMD would go in place; the chunk alone - stage 66)" "$M --grow /dev/$C --chunk=256 --raid-devices=4 --force 2>&1 | grep -q 'in regions md cannot keep to' && [ \$(cat /sys/block/$C/md/chunk_size) = 131072 ]"
# RAID10 of three columns 64 -> 256 KiB at full speed, written to meanwhile: the region of the source's chunk, 0x7f80
R=$(qgmd r53); cp $WQ/q53/pat-r53 $WQ/q53/model; G0=$(qgring $WQ/q53/d0.img | tail -1)
( for i in $(seq 1 120); do o=$((RANDOM % 150)); head -c 1M /dev/urandom > $WQ/q53/blk
	sudo dd if=$WQ/q53/blk of=/dev/$R bs=1M seek=$o oflag=direct conv=notrunc status=none 2>/dev/null
	dd if=$WQ/q53/blk of=$WQ/q53/model bs=1M seek=$o conv=notrunc status=none; done ) &
WP=$!
$M --grow /dev/$R --chunk=256 > $WQ/q53/grow.out 2>&1
S1=$(qgld $WQ/q53/d0.img $RID $((G0 + 1)))
A0=$(echo "$S1" | tail -1 | grep -o 'e0=[0-9a-f]*:[0-9a-f]*' | cut -d: -f2)
LAG=$(q53lag $R 60 $(qgl 0):0x$A0 $(qgl 1):0x$A0)
wait $WP; q53wait; sleep 3
check "53: RAID10 3 x 2 --chunk=256 at full speed: start packet - 0x22211, protect 0x7f80 (stripes of the source's 64 KiB), the RAID10 3 x 2 of 256 KiB 0x12211; md held behind the log, its progress from /proc/mdstat (${LAG#* } of $((0x7f80)), ${LAG% *} samples)" "grep -q 'chunk 64 -> 256 KiB' $WQ/q53/grow.out && echo \"\$S1\" | head -1 | grep -q 'type=1bf6 st=200 tt=5354 lo=5354 ts=0 cap=60000 ps=0 .* fs=3x2 tf=22211 psz=7f80 fl=20010 lk=1' && echo \"\$S1\" | tail -1 | grep -qE 'type=1bf6 st=200 tt=0 lo=5354 ts=0 cap=60000 .* fs=3x2 tf=12211 .*( e[0-5]=[0-9a-f]+:[0-9a-f]+\\+25000:[0-9a-f]+800\\+20000:0){6}$' && [ ${LAG% *} -gt 3 ] && [ ${LAG#* } -le $((0x7f80)) ]"
check "53: ... done: raid10 of 256 KiB, one LD RAID10N 3 x 2 of CacheTagSize 3 NORMAL; the data with the writes made meanwhile, md check 0" "[ \$(cat /sys/block/$R/md/chunk_size) = 262144 ] && [ \$(qgld $WQ/q53/d0.img $RID | wc -l) = 1 ] && qgld $WQ/q53/d0.img $RID | grep -q 'type=1bf6 st=200 tt=0 lo=5354 ts=a1a6 cap=60000 .* fs=3x2 tf=0' && [ \"\$(q53cts $WQ/q53/d0.img $RID)\" = 3 ] && cmp -s $WQ/q53/model <(sudo dd if=/dev/$R bs=1M count=150 iflag=direct status=none) && grep -q 'external:/' /sys/block/$R/md/metadata_version && q53check $R"
# RAID5 3 -> 4 disks and 64 -> 128 KiB at once
$M /dev/$CN --add $(qgl 6) >/dev/null 2>&1; sleep 1; G0=$(qgring $WQ/q53/d3.img | tail -1)
$M --grow /dev/$N --chunk=128 --raid-devices=4 > $WQ/q53/grow.out 2>&1
S1=$(qgld $WQ/q53/d3.img $NID $((G0 + 1)))
q53wait; sleep 3
check "53: RAID5 --chunk=128 --raid-devices=4: start packet - protect 0xd800 (3 data disks of the new LD in the old chunk's stripes), the RAID5 1 x 4 of 128 KiB 0x12211 with the spare; done: raid5 of 4, 128 KiB, the data as written, md check 0" "grep -q '3 -> 4 disks, chunk 64 -> 128 KiB' $WQ/q53/grow.out && echo \"\$S1\" | head -1 | grep -q 'fs=1x3 tf=22211 psz=d800 fl=20010 lk=1' && echo \"\$S1\" | tail -1 | grep -q 'fs=1x4 tf=12211' && [ \$(cat /sys/block/$N/md/raid_disks) = 4 ] && [ \$(cat /sys/block/$N/md/chunk_size) = 131072 ] && [ \"\$(q53cts $WQ/q53/d3.img $NID)\" = 2 ] && q53same n53 && q53check $N"
# nothing moved yet (the log at 0): md goes on from 0, as the AMD driver (stage 55; a RAID5: raid10 runs its
# first region at full speed before speed_limit_max holds it)
$M -C /dev/md/w53 -e amd -l5 -n3 -c64 -z 32M $(qgl 0) $(qgl 1) $(qgl 2) --run >/dev/null 2>&1; sleep 1; waitrec
W=$(qgmd w53); WID=$(q53id w53 0); q53fill w53 60M
echo 50 | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null; echo 100 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
$M --grow /dev/$W --chunk=128 > $WQ/q53/grow.out 2>&1; sleep 2; $M -S /dev/$W >/dev/null 2>&1; sleep 1
sudo dmesg -C; stopall; qgasm; W=$(qgmd w53); sleep 2
check "53: stopped before md moved a region, assembled again: md goes on from 0 - 128 KiB (64 KiB), the migration kept (not dropped)" "grep -q 'chunk 64 -> 128 KiB' $WQ/q53/grow.out && cat /sys/block/$W/md/chunk_size | grep -q '^131072 (65536)' && [ \"\$(cat /sys/block/$W/md/reshape_position)\" != none ] && [ \$(qgld $WQ/q53/d0.img $WID | wc -l) = 2 ] && ! sudo dmesg | grep -q 'had not begun: dropped'"
echo 1000 | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null; echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
q53wait; sleep 3
check "53: ... done: one LD of 128 KiB (CacheTagSize 2) NORMAL, md 128 KiB; the data as written" "[ \$(cat /sys/block/$W/md/chunk_size) = 131072 ] && [ \$(qgld $WQ/q53/d0.img $WID | wc -l) = 1 ] && qgld $WQ/q53/d0.img $WID | grep -q 'tt=0 lo=5354 ts=a1a6 .* fs=1x3 tf=0' && [ \"\$(q53cts $WQ/q53/d0.img $WID)\" = 2 ] && q53same w53"
qgdrop q53
# the AMD driver's chunk changes, both midway (chunk-mid: rcraid 9.3.3-00302 carrying out start packets and logs
# forged on a RAID5 and a RAID10 of this mdadm, both at once): md goes on with the first; the second, assembled too,
# waits held and md goes on with it by itself after (stage 55); each ends as the AMD driver ends it (chunk-post)
qgfix q53 $Q53D chunk-mid
xz -dc $Q53D/chunk-post-sata0-lba0-6000.img.xz > $WQ/q53/rc.img
E=$($M -E $(qgl 0) 2>/dev/null)
check "53: chunk-mid (the AMD driver's chunk changes midway): -E - raid5 and raid10 read-write, both migrations and their chunks" "echo \"\$E\" | grep -q 'Migration : RAID50 1 x 3, 2000 MiB, 64 KiB chunk -> RAID50 1 x 3, 2000 MiB, 128 KiB chunk; [0-9]*% done' && echo \"\$E\" | grep -q 'Migration : RAID10N 2 x 2, 1800 MiB, 64 KiB chunk -> RAID10N 2 x 2, 1800 MiB, 256 KiB chunk; [0-9]*% done' && [ \$(echo \"\$E\" | grep -c 'md support : read-write') = 2 ]"
echo 20000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
OUT=$(for l in $QGL; do $M -I $l 2>&1; done); sleep 2
V5=$(qgmd c5); V10=$(qgmd c10); RS=$(cat /sys/block/$V5/md/reshape_position 2>/dev/null); RS10=$(cat /sys/block/$V10/md/reshape_position 2>/dev/null)
check "53: chunk-mid assembled: md reshapes the RAID5 from the log's mark ($RS), 64 -> 128 KiB; the RAID10 assembled read-only at its mark ($RS10), waits for it" "[ -n '$V5' ] && [ \"\$RS\" -ge $((0x15f000)) ] && [ \$(cat /sys/block/$V5/md/sync_action) = reshape ] && [ -n '$V10' ] && [ \$(cat /sys/block/$V10/md/array_state) = readonly ] && [ '$RS10' -ge $((0x110000)) ] && echo \"\$OUT\" | grep -q 'its reshape goes on after that of another array of the container'"
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
q53wait; sleep 3
check "53: chunk-mid: the RAID5 ended by mdmon - its LD = the one the AMD driver ends it with (chunk-post), 128 KiB, not blocked" "[ \"\$(qgld $WQ/q53/d0.img 9283179a3b4f)\" = \"\$(qgld $WQ/q53/rc.img 9283179a3b4f)\" ] && [ \"\$(q53cts $WQ/q53/d0.img 9283179a3b4f)\" = 2 ] && grep -q 'external:/' /sys/block/$V5/md/metadata_version"
check "53: chunk-mid: md went on with the RAID10 by itself after it (from $RS10, no mdadm -I) - it ends as the AMD driver ends it (chunk-post), 256 KiB, not blocked" "[ \"\$(qgld $WQ/q53/d0.img 3b6d6ef1985c)\" = \"\$(qgld $WQ/q53/rc.img 3b6d6ef1985c)\" ] && [ \"\$(q53cts $WQ/q53/d0.img 3b6d6ef1985c)\" = 3 ] && [ \$(cat /sys/block/$V10/md/chunk_size) = 262144 ] && grep -q 'external:/' /sys/block/$V10/md/metadata_version"
qgdrop q53
fi
# --- end of stage 53 ---

# --- stage 55: a migration from mark 0, and several migrations in a container. A migration interrupted before its
# first region (md stopped, the log's mark 0, or no log yet - mdadm --grow gone between the start packet and the
# log) goes on from 0 when assembled, as the AMD driver goes on with one (from 0): md assembles the volume reshaping
# from position 0, read-only (Assemble.c: a reshape that moves the data goes on from 0 as from any point), and
# Grow_continue holds it behind the log - RAID5 + a disk, RAID1 of 2 -> RAID5 of 3, a chunk change, RAID0 + a disk
# (a raid4). Several migrations the AMD driver left in a container (chunk-mid: a RAID5 and a RAID10 midway;
# chunk-begun: both from mark 0) are all assembled; one mdadm carries them out one after the other
# (reshape_container), md holds those waiting where they are (sync_max), even when writable; the first done, it goes
# on with the next from its mark, the log never below it; the final LDs as rcraid's. In 1.4 a volume at 0 stayed as it
# was and the second volume waited for an mdadm -I.
if want 55; then
stopall
Q55A=$FIXT/2026-11-15-rcraid-chunk; Q55B=$FIXT/2026-11-16-rcraid-chunk-begun
q55mark() { sudo dd if=$1 bs=512 skip=$(($2)) count=1 iflag=direct status=none | python3 -c 'import sys,struct; b=sys.stdin.buffer.read(); print(struct.unpack_from("<Q", b, 0x1c)[0] if struct.unpack_from("<I", b, 0x18)[0] else -1)'; }
# q55pos <md>: how far md has reshaped it, sectors of the array (raid5/4: reshape_position; raid10: /proc/mdstat)
q55pos() { if [ "$(cat /sys/block/$1/md/level)" = raid10 ]; then
		echo $(( $(grep -A2 "^$1 " /proc/mdstat | sed -n 's/.*reshape = *[0-9.]*% (\([0-9]*\)\/.*/\1/p') * 2 ))
	else cat /sys/block/$1/md/reshape_position; fi; }
q55wait() { for i in $(seq 1 600); do grep -qE 'reshape|resync|recover|check' /proc/mdstat || { sleep 3; grep -qE 'reshape|resync|recover|check' /proc/mdstat || return 0; }; sleep 2; done; return 1; }
q55id() { $M -E $(qgl $2) 2>/dev/null | sed -n "/\[$1\]/,/Volume ID/p" | sed -n 's/.*Volume ID : //p'; }
# q55moved <md>: every member's data move 0x4800 sectors down (new_offset), the new disks' too
q55moved() { local d; for d in /sys/block/$1/md/dev-*; do [ $(( $(cat $d/offset) - $(cat $d/new_offset) )) = $((0x4800)) ] || return 1; done; }
q55check() { echo check | sudo tee /sys/block/$1/md/sync_action >/dev/null; sleep 1; q55wait; [ "$(cat /sys/block/$1/md/mismatch_cnt)" = 0 ]; }
q55fill() { head -c $2 /dev/urandom > $WQ/q55/pat-$1; sudo dd if=$WQ/q55/pat-$1 of=/dev/$(qgmd $1) bs=1M oflag=direct status=none; }
q55same() { cmp -s $WQ/q55/pat-$1 <(sudo dd if=/dev/$(qgmd $1) bs=1M count=$(( $(stat -c %s $WQ/q55/pat-$1) >> 20 )) iflag=direct status=none); }
q55slow() { echo 50 | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null; echo 100 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null; }
q55fast() { echo 1000 | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null; echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null; }
# q55logs <ID>: the transform logs at the start of every element of the volume's LDs, one line each (loop LBA log)
q55logs() { local l a; for a in $(qgld $WQ/q55/d0.img $1 | grep -o 'e[0-9]*=[0-9a-f]*:[0-9a-f]*' | cut -d: -f2 | sort -u); do
	for l in $QGL; do echo "$l 0x$a $(qgtlog $l 0x$a)"; done; done | grep -v ' 0 0 0 0 0 0 0$'; }
# q55stop0 <name> <grow args...>: md slow, mdadm --grow, stopped 2 s later - before md moved its first region
q55stop0() { local v=$1; shift; q55slow; $M --grow /dev/$(qgmd $v) "$@" > $WQ/q55/grow.out 2>&1; sleep 2
	$M -S /dev/$(qgmd $v) >/dev/null 2>&1; sleep 1; }
# q55again: everything stopped, assembled again (-I of each disk), md still slow; the kernel log anew
q55again() { sudo dmesg -C; stopall; qgasm; sleep 1; }
# q55from0 <md> <ID>: md reshapes it from 0, held (sync_max) and blocked for mdmon; the migration still recorded
q55from0() { local p=$(cat /sys/block/$1/md/reshape_position 2>/dev/null)
	[ "$p" != none ] && [ -n "$p" ] && [ "$p" -lt $((0x10000)) ] && grep -q reshape /sys/block/$1/md/sync_action &&
	[ "$(cat /sys/block/$1/md/sync_max)" != max ] && grep -q 'external:-' /sys/block/$1/md/metadata_version &&
	[ $(qgld $WQ/q55/d0.img $2 | wc -l) = 2 ] && ! sudo dmesg | grep -q 'had not begun: dropped'; }
# q55spare <disk>: disk d<n> into the container, a spare of every volume (one for each volume that takes a disk)
q55spare() { $M /dev/$(cont1) --add $(qgl $1) >/dev/null 2>&1; sleep 1; }
qgmk q55 9 2
$M -C /dev/md/amd55 -e amd -n 5 $(qgl 0) $(qgl 1) $(qgl 2) $(qgl 3) $(qgl 4) --run >/dev/null 2>&1
$M -C /dev/md/c55 -e amd -l5 -n3 -z 32M $(qgl 0) $(qgl 1) $(qgl 2) --run >/dev/null 2>&1
$M -C /dev/md/m55 -e amd -l1 -n2 -z 32M $(qgl 3) $(qgl 4) --run >/dev/null 2>&1
$M -C /dev/md/w55 -e amd -l5 -n3 -c64 -z 32M $(qgl 0) $(qgl 1) $(qgl 2) --run >/dev/null 2>&1
$M -C /dev/md/z55 -e amd -l0 -n2 -z 32M $(qgl 3) $(qgl 4) --run >/dev/null 2>&1
$M -C /dev/md/v55 -e amd -l5 -n3 -z 32M $(qgl 0) $(qgl 1) $(qgl 2) --run >/dev/null 2>&1
sleep 1; waitrec
CID=$(q55id c55 0); MID=$(q55id m55 3); WID=$(q55id w55 0); ZID=$(q55id z55 3); VID=$(q55id v55 0)
q55fill c55 64M; q55fill m55 32M; q55fill w55 64M; q55fill z55 64M; q55fill v55 64M
# RAID5 3 -> 4, stopped before md moved a region: the log at 0
q55spare 5; q55stop0 c55 --raid-devices=4
check "55: RAID5 3 -> 4 stopped before md moved a region: the log at 0, -E says 0%" "grep -q '3 -> 4 disks' $WQ/q55/grow.out && [ -n \"\$(q55logs $CID)\" ] && [ -z \"\$(q55logs $CID | grep -v ' 5354 0 1 ')\" ] && $M -E $(qgl 0) | grep -q 'Migration : RAID50 1 x 3, 64 MiB -> RAID50 1 x 4, 96 MiB; 0% done'"
q55again; C=$(qgmd c55)
check "55: ... assembled again: md goes on from 0 (as the AMD driver), raid5 of 4, the new offsets, held and blocked, the migration kept (not dropped)" "q55from0 $C $CID && [ \"\$(cat /sys/block/$C/md/raid_disks)\" = '4 (3)' ] && q55moved $C"
q55fast; q55wait; sleep 3
check "55: ... done: one LD RAID5 1 x 4 NORMAL, raid5 of 4, 96 MiB, not blocked; the data as written, md check 0" "[ \$(qgld $WQ/q55/d0.img $CID | wc -l) = 1 ] && qgld $WQ/q55/d0.img $CID | grep -q 'tt=0 lo=5354 ts=a1a6 cap=30000 .* fs=1x4 tf=0' && [ \$(cat /sys/block/$C/md/raid_disks) = 4 ] && [ \$(cat /sys/block/$C/size) = $((0x30000)) ] && grep -q 'external:/' /sys/block/$C/md/metadata_version && q55same c55 && q55check $C"
# RAID1 of two -> RAID5 of 3, stopped so
q55spare 6; q55stop0 m55 --level=5 --layout=right-asymmetric --raid-devices=3
q55again; R1=$(qgmd m55)
check "55: RAID1 of two -> RAID5 of 3 stopped before md moved a region, assembled again: md goes on from 0 - raid5 of 3, held and blocked, the migration kept" "grep -q '2 -> 3 disks' $WQ/q55/grow.out && q55from0 $R1 $MID && [ \$(cat /sys/block/$R1/md/level) = raid5 ] && [ \"\$(cat /sys/block/$R1/md/raid_disks)\" = '3 (2)' ]"
q55fast; q55wait; sleep 3
check "55: ... done: one LD RAID5 1 x 3 NORMAL, raid5 of 3, 64 MiB; the data as written, md check 0" "[ \$(qgld $WQ/q55/d0.img $MID | wc -l) = 1 ] && qgld $WQ/q55/d0.img $MID | grep -q 'type=1bf5 st=200 tt=0 lo=5354 ts=a1a6 cap=20000 .* fs=1x3 tf=0' && [ \$(cat /sys/block/$R1/md/level) = raid5 ] && [ \$(cat /sys/block/$R1/md/raid_disks) = 3 ] && q55same m55 && q55check $R1"
# RAID5 64 -> 128 KiB, stopped so
q55stop0 w55 --chunk=128
q55again; W=$(qgmd w55)
check "55: RAID5 --chunk=128 stopped before md moved a region, assembled again: md goes on from 0 - 128 KiB (64 KiB), held and blocked, the migration kept" "grep -q 'chunk 64 -> 128 KiB' $WQ/q55/grow.out && q55from0 $W $WID && cat /sys/block/$W/md/chunk_size | grep -q '^131072 (65536)'"
q55fast; q55wait; sleep 3
check "55: ... done: one LD RAID5 1 x 3 of 128 KiB NORMAL, md 128 KiB; the data as written, md check 0" "[ \$(qgld $WQ/q55/d0.img $WID | wc -l) = 1 ] && qgld $WQ/q55/d0.img $WID | grep -q 'tt=0 lo=5354 ts=a1a6 .* fs=1x3 tf=0' && [ \$(cat /sys/block/$W/md/chunk_size) = 131072 ] && q55same w55 && q55check $W"
# RAID0 2 -> 3 (md: raid4), stopped so
q55spare 7; q55stop0 z55 --raid-devices=3
q55again; Z=$(qgmd z55)
check "55: RAID0 2 -> 3 stopped before md moved a region, assembled again: md goes on from 0 - raid4 of 2 + 1 without its parity, the new offsets, held and blocked, the migration kept" "grep -q '2 -> 3 disks' $WQ/q55/grow.out && q55from0 $Z $ZID && q55moved $Z && [ \$(cat /sys/block/$Z/md/level) = raid4 ] && [ \"\$(cat /sys/block/$Z/md/raid_disks)\" = '4 (3)' ]"
q55fast; q55wait; sleep 3
for i in $(seq 1 60); do [ "$(cat /sys/block/$Z/md/level 2>/dev/null)" = raid0 ] && break; sleep 1; done
check "55: ... done: one LD RAID0 3 x 1 NORMAL, raid0 of 3; the data as written" "[ \$(qgld $WQ/q55/d0.img $ZID | wc -l) = 1 ] && qgld $WQ/q55/d0.img $ZID | grep -q 'tt=0 lo=5354 ts=a1a6 cap=30000 .* fs=3x1 tf=0' && [ \$(cat /sys/block/$Z/md/level) = raid0 ] && [ \$(cat /sys/block/$Z/md/raid_disks) = 3 ] && q55same z55"
# no log at all (mdadm --grow gone between the start packet and its first log): from 0 just the same
q55spare 8; q55stop0 v55 --raid-devices=4
for x in $(q55logs $VID | cut -d' ' -f1,2 | tr ' ' :); do sudo dd if=/dev/zero of=${x%:*} bs=512 seek=$((${x#*:})) count=1 conv=notrunc oflag=direct status=none; done
check "55: RAID5 3 -> 4 stopped so, its log cleared on every element: the start packet alone" "[ -z \"\$(q55logs $VID)\" ] && [ \$(qgld $WQ/q55/d0.img $VID | wc -l) = 2 ]"
q55again; V=$(qgmd v55)
check "55: ... assembled again: md goes on from 0, held and blocked, the migration kept; the log written before the first region" "q55from0 $V $VID && [ \"\$(cat /sys/block/$V/md/raid_disks)\" = '4 (3)' ] && [ -n \"\$(q55logs $VID | grep ' 5354 0 1 ')\" ]"
q55fast; q55wait; sleep 3
check "55: ... done: one LD RAID5 1 x 4 NORMAL; the data as written, md check 0" "[ \$(qgld $WQ/q55/d0.img $VID | wc -l) = 1 ] && qgld $WQ/q55/d0.img $VID | grep -q 'tt=0 lo=5354 ts=a1a6 .* fs=1x4 tf=0' && q55same v55 && q55check $V"
qgdrop q55
# the AMD driver's two migrations midway in one container (rcraid 9.3.3-00302, chunk-mid: RAID5 64 -> 128 KiB at
# 0x15f000, RAID10 64 -> 256 KiB at 0x110000): both assembled, md reshapes the first, holds the second where it is
# even writable; then goes on with the second by itself, from its mark, the log never below it; both end as the AMD
# driver ends them (chunk-post)
qgfix q55 $Q55A chunk-mid
xz -dc $Q55A/chunk-post-sata0-lba0-6000.img.xz > $WQ/q55/rc.img
echo 8000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
OUT=$(for l in $QGL; do $M -I $l 2>&1; done); sleep 2
V5=$(qgmd c5); V10=$(qgmd c10); RS10=$(cat /sys/block/$V10/md/reshape_position 2>/dev/null)
check "55: chunk-mid assembled: md reshapes the RAID5 from its mark; the RAID10 assembled too, read-only, its reshape at its mark ($RS10), held (sync_max) and blocked, said so" "[ \$(cat /sys/block/$V5/md/sync_action) = reshape ] && [ \$(cat /sys/block/$V5/md/reshape_position) -ge $((0x15f000)) ] && [ -n '$V10' ] && [ \$(cat /sys/block/$V10/md/array_state) = readonly ] && [ '$RS10' -ge $((0x110000)) ] && [ \"\$(cat /sys/block/$V10/md/sync_max)\" != max ] && grep -q 'external:-' /sys/block/$V10/md/metadata_version && echo \"\$OUT\" | grep -q 'its reshape goes on after that of another array of the container'"
$M --readwrite /dev/$V10 >/dev/null 2>&1; sleep 4
check "55: ... the RAID10 made writable meanwhile: md holds it where it was (sync_max), the RAID5 reshaping on" "[ \$(cat /sys/block/$V10/md/array_state) != readonly ] && [ \"\$(cat /sys/block/$V10/md/reshape_position)\" = '$RS10' ] && [ \$(cat /sys/block/$V5/md/sync_action) = reshape ]"
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
for i in $(seq 1 120); do grep -A2 "^$V5 " /proc/mdstat | grep -q reshape || break; sleep 1; done
for i in $(seq 1 60); do grep -A2 "^$V10 " /proc/mdstat | grep -q reshape && break; sleep 0.5; done
M10=-1; for d in 0 1 2 3; do x=$(q55mark $(qgl $d) 0x$(qgld $WQ/q55/d0.img 3b6d6ef1985c | head -1 | grep -o 'e0=[0-9a-f]*:[0-9a-f]*' | cut -d: -f2)); [ $x -gt $M10 ] && M10=$x; done
check "55: ... the RAID5 done, the RAID10 goes on by itself from its mark: reshaping, the log not below the mark ($M10)" "grep -A2 \"^$V10 \" /proc/mdstat | grep -q reshape && [ $M10 -ge $((0x110000)) ]"
q55wait; sleep 3
check "55: ... both ended by mdmon - their LDs = those the AMD driver ends them with (chunk-post), 128 and 256 KiB, not blocked" "[ \"\$(qgld $WQ/q55/d0.img 9283179a3b4f)\" = \"\$(qgld $WQ/q55/rc.img 9283179a3b4f)\" ] && [ \"\$(qgld $WQ/q55/d0.img 3b6d6ef1985c)\" = \"\$(qgld $WQ/q55/rc.img 3b6d6ef1985c)\" ] && [ \$(cat /sys/block/$V5/md/chunk_size) = 131072 ] && [ \$(cat /sys/block/$V10/md/chunk_size) = 262144 ] && grep -q 'external:/' /sys/block/$V5/md/metadata_version && grep -q 'external:/' /sys/block/$V10/md/metadata_version"
qgdrop q55
# the AMD driver's two migrations both just begun (chunk-begun: start packets and logs at 0 forged on the same
# volumes c5 and c10, not migrated yet - the RAID5 to 128 KiB, the RAID10 to 256 KiB; rcraid ends both from 0,
# chunk-begun-post): md goes on with the RAID5 from 0, holds the
# RAID10 at 0, then goes on with it; both end as the AMD driver ends them
qgfix q55 $Q55B chunk-begun
xz -dc $Q55B/chunk-begun-post-sata0-lba0-6000.img.xz > $WQ/q55/rc.img
echo 8000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
OUT=$(for l in $QGL; do $M -I $l 2>&1; done); sleep 2
V5=$(qgmd c5); V10=$(qgmd c10); RS5=$(cat /sys/block/$V5/md/reshape_position 2>/dev/null)
check "55: chunk-begun (the AMD driver's two migrations, logs at 0) assembled: md reshapes the RAID5 from 0 ($RS5), held; the RAID10 read-only at 0, held (sync_max 0) and blocked" "[ \$(cat /sys/block/$V5/md/sync_action) = reshape ] && [ '$RS5' -lt $((0x9000 * 4)) ] && [ \"\$(cat /sys/block/$V5/md/sync_max)\" != max ] && [ \$(cat /sys/block/$V10/md/array_state) = readonly ] && [ \"\$(cat /sys/block/$V10/md/reshape_position)\" = 0 ] && [ \"\$(cat /sys/block/$V10/md/sync_max)\" = 0 ] && grep -q 'external:-' /sys/block/$V10/md/metadata_version && echo \"\$OUT\" | grep -q 'its reshape goes on after that of another array of the container'"
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
for i in $(seq 1 120); do grep -A2 "^$V5 " /proc/mdstat | grep -q reshape || break; sleep 1; done
for i in $(seq 1 60); do grep -A2 "^$V10 " /proc/mdstat | grep -q reshape && break; sleep 0.5; done; q55wait; sleep 3
check "55: ... md went on with the RAID10 by itself; both ended by mdmon - their LDs = those the AMD driver ends them with from 0 (chunk-begun-post), 128 and 256 KiB, not blocked" "[ \"\$(qgld $WQ/q55/d0.img 9283179a3b4f)\" = \"\$(qgld $WQ/q55/rc.img 9283179a3b4f)\" ] && [ \"\$(qgld $WQ/q55/d0.img 3b6d6ef1985c)\" = \"\$(qgld $WQ/q55/rc.img 3b6d6ef1985c)\" ] && [ \$(cat /sys/block/$V5/md/chunk_size) = 131072 ] && [ \$(cat /sys/block/$V10/md/chunk_size) = 262144 ] && grep -q 'external:/' /sys/block/$V5/md/metadata_version && grep -q 'external:/' /sys/block/$V10/md/metadata_version"
qgdrop q55
fi
# --- end of stage 55 ---

# --- stage 56: volumes the AMD driver recorded OFFLINE; a disk that joined the container after a packet was written.
# 56a-56d - the fixture 2026-11-15-rcraid-away (rcraid 9.3.3-00302): RAID1 A (qaa) on d0+d1, RAID1 B (qab) on d1+d2,
#       244 MiB each; d1 and d2 went away together, rcraid on d0 alone recorded A CRITICAL (the element on d1 0x30 -
#       A was written to), B OFFLINE (both elements 0x20 - nothing was written), the PDs of d1, d2 removed; d1 and d2
#       have one packet (generation 10). Data straight into the elements (32 MiB each): B's the same on d1 and d2, A's
#       on d0, other data on A's element of d1.
# 56a - all three together: B is taken back [2/2] without a rebuild (amd_take_back: members at 0x20 that went away
#       together - one packet, no up-to-date disk of B holds it; rcraid does so), A is rebuilt onto d1 (0x30);
#       recorded: both NORMAL, the PDs of d1 and d2 back with their Handles (1, 2), one generation on the three disks.
# 56b - negative: d0 and d1 without d2 - B not taken back (a member is not here); d2 rolled back to its packet seq 8
#       (generation 9: it went away before d1) - the packets differ, B not taken back, the data of its disks untouched
#       (rcraid would take both).
# 56c - d0 rolled back to its packet seq 11 (rcraid: A CRITICAL, the element on d1 0x20 - A not written to yet): d0
#       alone, A written degraded - the element on d1 has to be 0x30 before the write (else AMD would take it back as
#       it is); then all three - A rebuilt onto d1, A's data as written.
# 56d - the same rollback, all three at once (A never written): A's up-to-date d0 holds the volume - its member at
#       0x20 is rebuilt, not taken back (AMD would take it too: stricter, for the data's sake); B is taken back.
# 56e, 56f - a disk that joined the container after a packet was written (-I disk by disk: managemon takes a new
#       array before new disks of the container), modelled so: a RAID5 Y on d0-d2 (loop devices of 1 GiB) assembled,
#       mdmon writes a packet (--update-subarray), d2's commit block back on the packet before, mdmon --takeover. md
#       runs d2 in sync -> mdmon gives it the live configuration (amd_md_holds, amd_catch_up); --grow --chunk=128 runs
#       and ends, the data as they were; the next assembly [3/3] without a rebuild. 56f - d2 also in a RAID1 Z
#       (d2+d3), stopped before: md does not run Z, d2 stays behind, --grow of Y refused (as stage 53 has it).
# 56g-56k - disks one at a time (-I per disk, as udev at boot; the container runs from d0 on - hot plugging). The
#       same fixture, but the commit blocks of all three with the serial of the firmware and the Windows driver,
#       8590... (helpers/commit-serial.py; rcraid for Linux writes its own 1022..., and after this mdadm's first
#       takeover its disks are "foreign" to mdadm - on hardware it is not so).
# 56g - d0, d1, d2: d1, the target of A's rebuild, gets the live configuration before d2 comes; B is taken back all the
#       same by the packet d1 came with (the ring, amd_ring_came / mdmon's memory) - [2/2] without a rebuild, the
#       data, recorded NORMAL, Handles 1/2, one generation. 56h - d0, d2, d1: the same. 56i - d0, d1, d2 never comes:
#       B OFFLINE, A rebuilt. 56j - d2 with an older packet (generation 9): B not taken back. 56k - d0, d1, all
#       stopped (mdmon gone), then d0, d1, d2: d1's packet from the ring, B taken back.
if want 56; then
cd "$MDADM_DIR"
stopall
Q56=$WQ/q56
F56=$FIXT/2026-11-15-rcraid-away
q56drop() { stopall; for l in $(sudo losetup -a | grep "$Q56/" | cut -d: -f1); do sudo losetup -d $l; done; }
q56md() { local p; for p in /dev/md/$1 /dev/md/${1}_0; do [ -e $p ] && { basename $(readlink -f $p); return; }; done; }
q56sum() { local m=$(q56md $1); [ -n "$m" ] && sudo head -c 33554432 /dev/$m | md5sum | cut -c1-32; }
q56mm() { local m=$(q56md $1); echo check | sudo tee /sys/block/$m/md/sync_action >/dev/null; sleep 1
	while ! grep -q idle /sys/block/$m/md/sync_action; do sleep 1; done; cat /sys/block/$m/md/mismatch_cnt; }
q56st() { local m=$(q56md $1); [ -n "$m" ] && grep -A1 "^$m " /proc/mdstat | grep -o '\[[0-9]/[0-9]\]'; }
q56rec() { sudo dmesg | grep -c "recover of RAID array $(q56md $1)\$"; }
q56gen() { $M -E $1 2>/dev/null | sed -n 's/^ *Generation : //p' | head -1; }
q56vol() { $M -E $2 2>/dev/null | sed -n "/^\[$1\]:/,/^\[/p"; }
# wait for the end of a resync/recovery/reshape (the suite's waitrec does not wait for a reshape)
q56wait() { for i in $(seq 1 300); do grep -qE 'resync|recover|check|repair|reshape' /proc/mdstat || { sleep 3; grep -qE 'resync|recover|check|repair|reshape' /proc/mdstat || return 0; }; sleep 2; done; return 1; }
q56raw() { sudo dd if=$1 bs=512 skip=$2 count=65536 status=none | md5sum | cut -c1-32; }
# q56mk <dir> [packet LBA for d0] [packet LBA for d2] [s - the serial 8590... in the commit blocks]: three loop devices of
# 8 GiB from the fixture, the data; Q56L - the loop devices, Q56A/Q56B - md5
q56mk() { local n; q56drop; rm -rf $Q56/$1; mkdir -p $Q56/$1; Q56L=()
	for n in 0 1 2; do truncate -s 8G $Q56/$1/d$n.img
		xz -dc $F56/away-sata$n-lba0-6000.img.xz | dd of=$Q56/$1/d$n.img conv=notrunc status=none; done
	[ -n "${2:-}" ] && python3 $HLP/commit-rollback.py $Q56/$1/d0.img $2 >/dev/null
	[ -n "${3:-}" ] && python3 $HLP/commit-rollback.py $Q56/$1/d2.img $3 >/dev/null
	[ -n "${4:-}" ] && python3 $HLP/commit-serial.py $Q56/$1/d0.img $Q56/$1/d1.img $Q56/$1/d2.img >/dev/null
	for n in pa pb px; do head -c 33554432 /dev/urandom > $Q56/$1/$n; done
	dd if=$Q56/$1/pb of=$Q56/$1/d1.img bs=512 seek=1589248 conv=notrunc status=none
	dd if=$Q56/$1/pb of=$Q56/$1/d2.img bs=512 seek=1069056 conv=notrunc status=none
	dd if=$Q56/$1/pa of=$Q56/$1/d0.img bs=512 seek=1069056 conv=notrunc status=none
	dd if=$Q56/$1/px of=$Q56/$1/d1.img bs=512 seek=1069056 conv=notrunc status=none
	Q56A=$(md5sum < $Q56/$1/pa | cut -c1-32); Q56B=$(md5sum < $Q56/$1/pb | cut -c1-32)
	for n in 0 1 2; do Q56L[$n]=$(sudo losetup -f --show $Q56/$1/d$n.img); done; }
# q56back <loop>...: -A of the container from them, -I, a pause, -IR, wait
q56back() { sudo dmesg -C; $M -A /dev/md/q56c -e amd "$@" >/dev/null 2>&1; $M -I /dev/md/q56c >/dev/null 2>&1; sleep 5
	$M -IR /dev/md/q56c >/dev/null 2>&1; sleep 3; q56wait; sleep 3; q56wait; }

# 56a
q56mk a
q56back ${Q56L[@]}
check "56a: B, recorded OFFLINE by AMD (both members 0x20), its disks back together: [2/2] without a recovery, the data as they were, md check 0" "[ \"\$(q56st qab)\" = '[2/2]' ] && [ \$(q56rec qab) = 0 ] && [ \"\$(q56sum qab)\" = '$Q56B' ] && [ \$(q56mm qab) = 0 ]"
check "56a: A, its member on d1 written to while away (0x30): rebuilt onto d1, the data of d0, md check 0" "[ \"\$(q56st qaa)\" = '[2/2]' ] && [ \$(q56rec qaa) = 1 ] && [ \"\$(q56sum qaa)\" = '$Q56A' ] && [ \$(q56mm qaa) = 0 ]"
stopall
check "56a: recorded: A and B NORMAL, every member in service, the PDs of d1 and d2 back with their Handles 1 and 2, one generation on the three disks" "q56vol qaa ${Q56L[0]} | grep -q 'State : 0x200 (normal)' && q56vol qab ${Q56L[0]} | grep -q 'State : 0x200 (normal)' && ! $M -E ${Q56L[0]} | grep -q 'out of service' && q56vol qab ${Q56L[0]} | grep -q 'Member   0 : 634861e5087d1aad handle 1 ' && q56vol qab ${Q56L[0]} | grep -q 'Member   1 : 7cae660336c3a413 handle 2 ' && $M -E ${Q56L[0]} | grep -qE '^ +[0-9]+  634861e5087d1aad +1  raid +0x3000' && [ \"\$(q56gen ${Q56L[1]})\" = \"\$(q56gen ${Q56L[0]})\" ] && [ \"\$(q56gen ${Q56L[2]})\" = \"\$(q56gen ${Q56L[0]})\" ]"
q56drop

# 56b: d0 and d1 only; then, anew, all three with d2 at its packet before d1's (generation 9)
q56mk b1
q56back ${Q56L[0]} ${Q56L[1]}
check "56b: d0 and d1 back, d2 not: B not taken back (not assembled), recorded OFFLINE still" "[ -z \"\$(q56st qab)\" ] && stopall && q56vol qab ${Q56L[0]} | grep -q 'State : 0x202'"
q56mk b2 '' 0x5818
R1=$(q56raw ${Q56L[1]} 1589248); R2=$(q56raw ${Q56L[2]} 1069056); G1=$(q56gen ${Q56L[1]}); G2=$(q56gen ${Q56L[2]})
q56back ${Q56L[@]}
check "56b: d2 back with its packet before d1's ($G2, $G1): B not taken back (not assembled), the data of its disks untouched" "[ -n '$G1' ] && [ '$G1' != '$G2' ] && [ -z \"\$(q56st qab)\" ] && stopall && [ \"\$(q56raw ${Q56L[1]} 1589248)\" = '$R1' ] && [ \"\$(q56raw ${Q56L[2]} 1069056)\" = '$R2' ]"
q56drop

# 56c: d0 at its packet seq 11 (A CRITICAL, d1 0x20); d0 alone, A written degraded
q56mk c 0x5832
$M -I ${Q56L[0]} >/dev/null 2>&1; $M -IRs >/dev/null 2>&1; sleep 2
sudo dd if=/dev/urandom of=/dev/$(q56md qaa) bs=1M count=8 seek=8 oflag=direct status=none; sleep 1
Q56A=$(q56sum qaa); stopall
check "56c: A written with its member AMD left missing (0x20 alone) away: recorded offline (0x30) before, as the AMD driver's first write does" "q56vol qaa ${Q56L[0]} | grep -q 'Member   1 : 634861e5087d1aad .*(out of service: offline)'"
q56back ${Q56L[@]}
check "56c: all three back: A rebuilt onto d1 (not taken back), the data written, md check 0" "[ \"\$(q56st qaa)\" = '[2/2]' ] && [ \$(q56rec qaa) = 1 ] && [ \"\$(q56sum qaa)\" = '$Q56A' ] && [ \$(q56mm qaa) = 0 ]"
q56drop

# 56d: the same packet of d0, all three at once (A never written)
q56mk d 0x5832
q56back ${Q56L[@]}
check "56d: A, its up-to-date member running it: its member 0x20 rebuilt (not taken back), the data of d0; B taken back [2/2] without a recovery, its data" "[ \"\$(q56st qaa)\" = '[2/2]' ] && [ \$(q56rec qaa) = 1 ] && [ \"\$(q56sum qaa)\" = '$Q56A' ] && [ \"\$(q56st qab)\" = '[2/2]' ] && [ \$(q56rec qab) = 0 ] && [ \"\$(q56sum qab)\" = '$Q56B' ] && [ \$(q56mm qab) = 0 ]"
q56drop

# 56e, 56f: a member md runs in sync, mdmon with it behind
# q56lag <dir> [z]: Y a RAID5 on d0-d2, 64 MiB (data), [z: Z a RAID1 on d2+d3], a packet more, [Z stopped], d2's commit
# block back, mdmon --takeover; Q56Y - the md of Y, Q56S - sha256 of Y
q56lag() { local n c; q56drop; rm -rf $Q56/$1; mkdir -p $Q56/$1; Q56L=()
	for n in 0 1 2 3; do truncate -s 1G $Q56/$1/d$n.img; Q56L[$n]=$(sudo losetup -f --show $Q56/$1/d$n.img); done
	$M -C /dev/md/q56c -e amd -n4 ${Q56L[@]} --run >/dev/null 2>&1
	$M -C /dev/md/q56y -e amd -l5 -n3 -z 64M ${Q56L[0]} ${Q56L[1]} ${Q56L[2]} --run --assume-clean >/dev/null 2>&1
	[ "${2:-}" = z ] && $M -C /dev/md/q56z -e amd -l1 -n2 -z 64M ${Q56L[2]} ${Q56L[3]} --run --assume-clean >/dev/null 2>&1
	sleep 2; Q56Y=$(q56md q56y); c=$(grep -B1 "super external:amd" /proc/mdstat | grep -o "^md[0-9]*" | head -1)
	sudo dd if=/dev/urandom of=/dev/$Q56Y bs=1M count=128 oflag=direct status=none
	Q56S=$(sudo sha256sum /dev/$Q56Y | cut -c1-64)
	sudo dd if=${Q56L[2]} of=$Q56/$1/commit2 bs=512 skip=$((0x5001)) count=1 status=none
	$M --update-subarray=0 --update=no-write-back /dev/$c >/dev/null 2>&1; sleep 2
	[ "${2:-}" = z ] && $M -S /dev/$(q56md q56z) >/dev/null 2>&1
	sudo dd if=$Q56/$1/commit2 of=${Q56L[2]} bs=512 seek=$((0x5001)) count=1 conv=notrunc oflag=direct status=none
	Q56G=$(q56gen ${Q56L[2]}); sudo -E ./mdmon --takeover $c
	for n in $(seq 1 20); do sleep 1; [ "$(q56gen ${Q56L[2]})" = "$(q56gen ${Q56L[0]})" ] && break; done; }
q56lag e
check "56e: d2, behind ($Q56G) but run in sync by md, has the live configuration" "[ -n '$Q56G' ] && [ '$Q56G' != \"\$(q56gen ${Q56L[0]})\" ] && [ \"\$(q56gen ${Q56L[2]})\" = \"\$(q56gen ${Q56L[0]})\" ]"
$M --grow /dev/$Q56Y --chunk=128 >/dev/null 2>&1; sleep 2; q56wait
check "56e: --grow --chunk=128 of the RAID5 runs and ends: 128K, the data as they were" "grep -A1 \"^$Q56Y \" /proc/mdstat | grep -q '128k chunk' && [ \"\$(sudo sha256sum /dev/$Q56Y | cut -c1-64)\" = '$Q56S' ]"
stopall; sudo dmesg -C
for l in ${Q56L[@]}; do $M -I $l >/dev/null 2>&1; done; sleep 3; q56wait
check "56e: the next assembly (-I per disk): [3/3] without a recovery, the data as they were" "[ \"\$(q56st q56y)\" = '[3/3]' ] && [ \$(q56rec q56y) = 0 ] && [ \"\$(sudo sha256sum /dev/\$(q56md q56y) | cut -c1-64)\" = '$Q56S' ]"
q56lag f z
check "56f: d2 also in a RAID1 md does not run: it stays behind, --grow of the RAID5 refused" "[ \"\$(q56gen ${Q56L[2]})\" != \"\$(q56gen ${Q56L[0]})\" ] && $M --grow /dev/$Q56Y --chunk=128 2>&1 | grep -q 'with all its members only' && grep -A1 \"^$Q56Y \" /proc/mdstat | grep -q '64k chunk'"
q56drop

# 56g-56k: one disk at a time (-I per disk), the commits with AMD's serial of the firmware and Windows
q56inc() { local l; for l in "$@"; do $M -I $l >/dev/null 2>&1; sleep 3; q56wait; done; }
q56rec0() { sudo dmesg | grep -c "recover of RAID array $(q56md qab)\$"; }
q56back1() { [ "$(q56st qab)" = '[2/2]' ] && [ $(q56rec0) = 0 ] && [ "$(q56sum qab)" = "$Q56B" ] && [ $(q56mm qab) = 0 ]; }
q56rec1() { stopall; q56vol qab ${Q56L[0]} | grep -q 'State : 0x200 (normal)' && ! $M -E ${Q56L[0]} | grep -q 'out of service' && q56vol qab ${Q56L[0]} | grep -q 'Member   0 : 634861e5087d1aad handle 1 ' && q56vol qab ${Q56L[0]} | grep -q 'Member   1 : 7cae660336c3a413 handle 2 ' && [ "$(q56gen ${Q56L[1]})" = "$(q56gen ${Q56L[0]})" ] && [ "$(q56gen ${Q56L[2]})" = "$(q56gen ${Q56L[0]})" ]; }
q56mk g '' '' s; sudo dmesg -C
q56inc ${Q56L[0]} ${Q56L[1]}; G1=$(q56gen ${Q56L[1]}); G0=$(q56gen ${Q56L[0]})
q56inc ${Q56L[2]}
check "56g: -I d0, d1, d2 - d1 up to date ($G1 = $G0) before d2 comes: B taken back all the same, [2/2] without a recovery, the data as they were, md check 0" "[ '$G1' = '$G0' ] && q56back1"
check "56g: A rebuilt onto d1, the data of d0; recorded: B NORMAL, Handles 1 and 2, one generation on the three disks" "[ \"\$(q56st qaa)\" = '[2/2]' ] && [ \$(q56rec qaa) = 1 ] && [ \"\$(q56sum qaa)\" = '$Q56A' ] && q56rec1"
q56drop
q56mk h '' '' s; sudo dmesg -C
q56inc ${Q56L[0]} ${Q56L[2]} ${Q56L[1]}
check "56h: -I d0, d2, d1: B taken back, [2/2] without a recovery, the data as they were; recorded NORMAL, one generation" "q56back1 && q56rec1"
q56drop
q56mk i '' '' s; sudo dmesg -C
q56inc ${Q56L[0]} ${Q56L[1]}
check "56i: -I d0, d1, d2 never comes: B not taken back (not assembled, OFFLINE), A rebuilt onto d1, the data of d0" "[ -z \"\$(q56st qab)\" ] && [ \"\$(q56st qaa)\" = '[2/2]' ] && [ \"\$(q56sum qaa)\" = '$Q56A' ] && stopall && q56vol qab ${Q56L[0]} | grep -q 'State : 0x202'"
q56drop
q56mk j '' 0x5818 s; sudo dmesg -C
R1=$(q56raw ${Q56L[1]} 1589248); R2=$(q56raw ${Q56L[2]} 1069056)
q56inc ${Q56L[0]} ${Q56L[1]} ${Q56L[2]}
check "56j: -I d0, d1, d2 with its packet before d1's: B not taken back (not assembled), the data of its disks untouched" "[ -z \"\$(q56st qab)\" ] && stopall && [ \"\$(q56raw ${Q56L[1]} 1589248)\" = '$R1' ] && [ \"\$(q56raw ${Q56L[2]} 1069056)\" = '$R2' ] && q56vol qab ${Q56L[0]} | grep -q 'State : 0x202'"
q56drop
q56mk k '' '' s; sudo dmesg -C
q56inc ${Q56L[0]} ${Q56L[1]}; stopall; sudo dmesg -C
q56inc ${Q56L[0]} ${Q56L[1]} ${Q56L[2]}
check "56k: d1 up to date, all stopped (mdmon gone), then -I d0, d1, d2: the packet d1 came back with from its ring, B taken back [2/2] without a recovery, the data as they were" "q56back1 && q56rec1"
q56drop; rm -rf $Q56
fi
# --- end of stage 56 ---
# --- stage 57: a transform log one member does not take (MON-B2), and that member failed as the AMD driver fails it.
# amd_tlog_write writes the log on the column-0 elements in turn and used to give up at the first error, leaving the
# others without it; a disk that does not take the log is failed in md now (the AMD driver gives its element 0x10,
# seen with rcraid 9.3.3-00302). Four dm-linear disks of 1 GiB (loop); the volume's log sector on d0 (its
# AllocatedSpace) an error target.
# 57a - a RAID5 of three of 128 MiB initializing: the log is on the parity element (d0, first in turn) and on the
# data element (d2: 2048 stripes % 3, the one the AMD driver reads); d0 does not take it - d0 failed (0x10, one
# "failed" line in the kernel log), the initialization of the degraded RAID5 stops (d2's log as mdmon left it); the
# data read as written.
# 57b - RAID5 3 -> 4, data moving (as stage 51), a new volume: the log before each region is on the data element (d0,
# first: 2048 stripes % 4) and the parity element (d1); d0 does not take it - mdadm fails d0, the reshape goes on
# with d1's copy; writes, -S, the error gone (d0 has a copy behind), assembled: d0 out of the volume (0x10, no one
# reads its copy), md goes on from d1's copy, the data as written.
if want 57; then
cd "$MDADM_DIR"
stopall
Q57=$WQ/q57
q57drop() { stopall; for n in 0 1 2 3; do sudo dmsetup remove q57d$n 2>/dev/null; done
	for l in $(sudo losetup -a | grep $Q57/ | cut -d: -f1); do sudo losetup -d $l; done; rm -rf $Q57; }
q57mk() { local n L; q57drop; mkdir -p $Q57; Q57D=""
	for n in 0 1 2 3; do
		truncate -s 1G $Q57/d$n.img; L=$(sudo losetup -f --show $Q57/d$n.img); eval Q57L$n=$L
		echo "0 $(sudo blockdev --getsz $L) linear $L 0" | sudo dmsetup create q57d$n; Q57D="$Q57D /dev/mapper/q57d$n"
	done
	QS=$(sudo blockdev --getsz $Q57L0); }
# q57bad <n> [<LBA>]: sector <LBA> of q57d<n> an error target; no <LBA>: the table as it was
q57bad() { local L; eval L=\$Q57L$1
	if [ -n "${2:-}" ]; then printf '0 %d linear %s 0\n%d 1 error\n%d %d linear %s %d\n' $2 $L $2 $(($2 + 1)) $((QS - $2 - 1)) $L $(($2 + 1))
	else echo "0 $QS linear $L 0"; fi | sudo dmsetup reload q57d$1 && sudo dmsetup resume q57d$1; }
# q57log <n> <LBA>: the transform log on d<n> (read from its loop, past the error target): type, mark, status
q57log() { local L; eval L=\$Q57L$1; sudo dd if=$L bs=512 skip=$(($2)) count=1 iflag=direct status=none | python3 -c 'import sys,struct; b=sys.stdin.buffer.read(); print("%x %d %d" % (struct.unpack_from("<I", b, 0x18)[0], struct.unpack_from("<Q", b, 0x1c)[0], struct.unpack_from("<I", b, 0x44)[0]))'; }
# -I of the dm disks puts them in the container, the volume is started from it
q57asm() { local d; for d in $Q57D; do $M -I $d >/dev/null 2>&1; done; $M -I /dev/$(cont1) >/dev/null 2>&1; sleep 2; }
q57wait() { for i in $(seq 1 120); do grep -qE 'reshape|resync|recover|check' /proc/mdstat || { sleep 3; grep -qE 'reshape|resync|recover|check' /proc/mdstat || return 0; }; sleep 2; done; return 1; }
q57flag() { echo "$2" | grep -o "e$1=[^ ]*" | cut -d: -f4; }	# flags of element e<n> of a qgld line (hex)
q57mk
echo 3000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
$M -C /dev/md/q57c -e amd -n 3 /dev/mapper/q57d0 /dev/mapper/q57d1 /dev/mapper/q57d2 --run >/dev/null 2>&1
$M -C /dev/md/q57r5 -l5 -n3 -z 128M /dev/$(cont1) --run >/dev/null 2>&1; V=$(qgmd q57r5); VID=$(qgids $Q57/d1.img | sed -n 1p)
OFF=$($M -E /dev/mapper/q57d0 2>/dev/null | sed -n 's/.* Member *0 : .* offset \([0-9]*\) .*/\1/p' | head -1)
LB=$(( ${OFF:-0x5000} - 0x5000 ))	# AllocatedSpace: data at + 0x5000 (AMD_SERVICE), the log at + 0
q57bad 0 $LB; sudo dmesg -C
head -c 64M /dev/urandom > $Q57/pat; sudo dd if=$Q57/pat of=/dev/$V bs=1M oflag=direct status=none
for i in $(seq 1 30); do [ "$(cat /sys/block/$V/md/degraded)" = 1 ] && break; sleep 1; done; sleep 2
# the failure recorded (0x10 in the packet on d1)
for i in $(seq 1 20); do S0=$(qgld $Q57/d1.img $VID | head -1); F=$(q57flag 0 "$S0"); [ $(( 0x${F:-0} & 0x10 )) != 0 ] && break; sleep 1; done
G2=$(q57log 2 $LB)
check "57a: RAID5 initializing ($V), d0 takes no log: d0 failed (0x$(q57flag 0 "$S0")), told once; the initialization of the degraded RAID5 stops (d2's log: $G2)" "[ -n '$V' ] && [ -n '$OFF' ] && [ \$(cat /sys/block/$V/md/degraded) = 1 ] && [ \$(( 0x$(q57flag 0 "$S0") & 0x10 )) != 0 ] && [ \$(sudo dmesg | grep -c 'did not take the transform log: failed') = 1 ]"
check "57a: ... the data read as written (degraded)" "cmp -s $Q57/pat <(sudo dd if=/dev/$V bs=1M count=64 iflag=direct status=none)"
# 57b: a new, whole RAID5 of three; 3 -> 4 (d3 added to the container), slowly; d0's sector fails after the first region began
q57bad 0; q57mk
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
$M -C /dev/md/q57c -e amd -n 3 /dev/mapper/q57d0 /dev/mapper/q57d1 /dev/mapper/q57d2 --run >/dev/null 2>&1
$M -C /dev/md/q57r5 -l5 -n3 -z 128M /dev/$(cont1) --run >/dev/null 2>&1; V=$(qgmd q57r5); q57wait; VID=$(qgids $Q57/d1.img | sed -n 1p)
$M /dev/$(cont1) --add /dev/mapper/q57d3 >/dev/null 2>&1; sleep 1
head -c 64M /dev/urandom > $Q57/pat; sudo dd if=$Q57/pat of=/dev/$V bs=1M oflag=direct status=none
echo 3000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
$M --grow /dev/$V --raid-devices=4 > $Q57/grow.out 2>&1
# the log of the first region (at 0) is on: d0 fails the next one
for i in $(seq 1 50); do [ "$(q57log 1 $LB | cut -d' ' -f1,3)" = '5354 1' ] && break; sleep 0.2; done; q57bad 0 $LB
for i in $(seq 1 60); do grep -q 'did not take the AMD transform log: failed' $Q57/grow.out && break; sleep 1; done; sleep 4
G1=$(q57log 1 $LB); G0=$(q57log 0 $LB); S0=$(qgld $Q57/d1.img $VID)
check "57b: 3 -> 4 ($V), d0 takes no log: d0 failed (0x$(q57flag 0 "$(echo "$S0" | tail -1)") in the LD it becomes), the reshape goes on - the parity element's copy (d1: $G1) past d0's (behind: $G0)" "grep -q '3 -> 4 disks' $Q57/grow.out && ! grep -q 'the reshape waits at' $Q57/grow.out && [ \"\$(echo $G1 | cut -d' ' -f1,3)\" = '5354 1' ] && [ $(echo $G1 | cut -d' ' -f2) -gt $(echo $G0 | cut -d' ' -f2) ] && [ \$(( 0x$(q57flag 0 "$(echo "$S0" | tail -1)") & 0x10 )) != 0 ] && [ \$(cat /sys/block/$V/md/degraded) = 1 ]"
head -c 64M /dev/urandom > $Q57/pat; sudo dd if=$Q57/pat of=/dev/$V bs=1M oflag=direct status=none
$M -S /dev/$V >/dev/null 2>&1; sleep 1; G0=$(q57log 0 $LB); G1=$(q57log 1 $LB)
q57bad 0; stopall; q57asm; V=$(qgmd q57r5); RP=$(cat /sys/block/$V/md/reshape_position 2>/dev/null)
check "57b: stopped, d0 well again (its copy behind: $G0), assembled: d0 out of the volume, md goes on from d1's copy ($RP, the log $G1)" "[ -n '$V' ] && [ \"\${RP:-none}\" != none ] && [ \${RP:-0} -ge $(echo $G1 | cut -d' ' -f2) ] && [ \$(cat /sys/block/$V/md/degraded) = 1 ] && ! ls /sys/block/$V/md/ | grep -q \"dev-\$(basename \$(readlink -f /dev/mapper/q57d0))\""
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
q57wait; sleep 3
check "57b: ... ended: raid5 of 4 (degraded), the data as written meanwhile (not copied over from where they were)" "[ \$(cat /sys/block/$V/md/raid_disks) = 4 ] && cmp -s $Q57/pat <(sudo dd if=/dev/$V bs=1M count=64 iflag=direct status=none)"
q57drop
fi
# --- end of stage 57 ---

# --- stage 58: a container whose mdmon is a zombie (the shutdown ramfs, COM-B6). In systemd's exitrd pid 1
# (systemd-shutdown) does not reap: an mdmon that left on SIGTERM (its pid file stays on that path - the mdmon taking
# the container over removes it, monitor.c wait_and_act()) is a zombie, kill(pid, 0) finds it, and mdmon_running()
# took it for running: -I of the container started no new mdmon (the volume stayed readonly without one), --stop of
# the container waited the full 5 s and said "mdmon for ... is still running". exitrd emulated: a pid namespace
# (unshare --pid --fork --mount-proc) whose pid 1 is python3, waiting for its own child only; everything about mdmon
# inside it (the pid file has the namespace's pid). IMSM (IMSM_NO_PLATFORM=1, loop) and AMD, a RAID1 of two loop
# devices of 1 GiB. The first check of each format is that the experiment is set up (mdmon a zombie, its pid file
# kept); before the fix "-I ..." and "--stop ..." fail for both formats.
if want 58; then
cd "$MDADM_DIR"
stopall
Q58=$WQ/q58; mkdir -p $Q58
# ns.sh <format> <loop0> <loop1> - inside the namespace, as root; lines "KEY=value"
cat > $Q58/ns.sh <<'NS'
F=$1; L0=$2; L1=$3
export IMSM_NO_PLATFORM=1 IMSM_DEVNAME_AS_SERIAL=1
vol() { local m; for m in /sys/block/md*/md; do grep -q "^external:/$1/" $m/metadata_version 2>/dev/null &&
	{ m=${m#/sys/block/}; echo ${m%%/*}; }; done; }
st() { awk '{print $3}' /proc/$1/stat 2>/dev/null; }
# term <container>: SIGTERM to its mdmon, wait for the zombie
term() { local p=$(cat /run/mdadm/$1.pid 2>/dev/null) i; [ -n "$p" ] || return 1; kill -TERM $p
	for i in $(seq 1 50); do [ "$(st $p)" = Z ] && return 0; sleep 0.1; done; return 1; }
./mdadm -C /dev/md/q58c -e $F -n2 $L0 $L1 --run >/dev/null 2>&1
C=$(basename $(readlink -f /dev/md/q58c)); echo "C=$C"
./mdadm -C /dev/md/q58v -l1 -n2 -z 64M /dev/$C --run --assume-clean >/dev/null 2>&1; sleep 2
V=$(vol $C); [ -n "$V" ] || exit 1
term $C && [ -e /run/mdadm/$C.pid ] && echo ZOMBIE=yes
# -I of the container again (the volume stopped): does a live mdmon take the volume
./mdadm -S /dev/$V >/dev/null 2>&1
./mdadm -I /dev/$C >/dev/null 2>&1; sleep 2
V=$(vol $C); P=$(cat /run/mdadm/$C.pid 2>/dev/null)
echo "STATE=$(cat /sys/block/$V/md/array_state 2>/dev/null)"
[ -n "$P" ] && [ "$(st $P)" != Z ] && [ -n "$(st $P)" ] && echo LIVE=yes
# a zombie again; --stop of the volume and of the container
term $C
./mdadm -S /dev/$V >/dev/null 2>&1
t=$(date +%s%N); OUT=$(./mdadm -S /dev/$C 2>&1); echo "STOPMS=$(( ($(date +%s%N) - t) / 1000000 ))"
echo "$OUT" | grep -q 'still running' && echo STILL=yes
grep -q "^$C " /proc/mdstat && echo STOPPED=no || echo STOPPED=yes
NS
for f in imsm amd; do
	for n in 0 1; do rm -f $Q58/$f$n.img; truncate -s 1G $Q58/$f$n.img; done
	L58=$(for n in 0 1; do sudo losetup -f --show $Q58/$f$n.img; done)
	R58=$(sudo -E unshare --pid --fork --mount-proc python3 -c 'import subprocess, sys; sys.exit(subprocess.call(sys.argv[1:]))' \
		bash $Q58/ns.sh $f $L58)
	r58() { echo "$R58" | sed -n "s/^$1=//p"; }
	check "58 ($f): exitrd emulated: mdmon left on SIGTERM is a zombie under a pid 1 that does not reap, its pid file kept" "[ \"\$(r58 ZOMBIE)\" = yes ]"
	check "58 ($f): -I of the container, its mdmon a zombie: a new mdmon takes the RAID1 ($(r58 STATE))" "[ \"\$(r58 LIVE)\" = yes ] && [ \"\$(r58 STATE)\" != readonly ]"
	check "58 ($f): --stop of the container, its mdmon a zombie: $(r58 STOPMS) ms, no 'still running'" "[ \"\$(r58 STOPPED)\" = yes ] && [ \"\$(r58 STOPMS)\" -lt 1000 ] && [ -z \"\$(r58 STILL)\" ]"
	# the zombie's pid file has a pid of the namespace that is gone: outside it could name another process
	C58=$(r58 C); [ -n "$C58" ] && sudo rm -f /run/mdadm/$C58.pid /run/mdadm/$C58.sock
	stopall
	IMSM_NO_PLATFORM=1 $M --zero-superblock $L58 >/dev/null 2>&1
	for l in $L58; do sudo losetup -d $l; done
done
rm -rf $Q58
fi
# --- end of stage 58 ---

# --- stage 59: assembling a volume by --uuid / --name with its container on the command line - without "<container>
# has wrong uuid" about the other volumes of the container (common code, Assemble.c select_devices(): ident_matches()
# spoke of each volume of the container passed over before the one asked for - IMSM the same). Sets of loop devices
# of 1 GiB, for AMD and IMSM (IMSM_NO_PLATFORM=1): container c (d0, d1) with RAID1 v1 and v2 of 32 MiB; foreign ones -
# a container w of the same format (w0, w1, volume wv; for AMD made first: -C next to a foreign AMD label is refused)
# and a member f0 of a 1.2 array (f0, f1).
# 59a - -A v1 and v2 by --uuid with the container: assembled, no "wrong uuid"; 59b - the same by --name; 59c - the
# volume already running: "already assembled", no "wrong uuid"; 59d - a UUID no volume of the container has: "c has
# wrong uuid" (a line per volume), nothing assembled; 59e - foreign ones: container w and disk f0 - "has wrong uuid"
# as before; 59f - -As by mdadm.conf (ARRAY lines of -Es): all volumes, no "wrong uuid".
if want 59; then
cd "$MDADM_DIR"
stopall
Q59=$WQ/q59
q59drop() { stopall; for l in $(sudo losetup -a | grep "$Q59/" | cut -d: -f1); do sudo losetup -d $l; done; rm -f $Q59/*; }
q59lo() { sudo losetup -j $Q59/$1.img | cut -d: -f1; }
q59up() { [ -e /dev/md/$1 ] && grep -q "^$(basename $(readlink -f /dev/md/$1)) : active" /proc/mdstat; }
mkdir -p $Q59; q59drop
for F in amd imsm; do
	[ $F = imsm ] && M59="sudo -E env IMSM_NO_PLATFORM=1 IMSM_DEVNAME_AS_SERIAL=1 ./mdadm" || M59=$M
	for n in d0 d1 f0 f1 w0 w1; do truncate -s 1G $Q59/$n.img; sudo losetup -f $Q59/$n.img; done
	# w without d0, d1 and c without w - on the same loop devices (IMSM_DEVNAME_AS_SERIAL: the loop name is the serial)
	q59off() { local n; for n in "$@"; do eval Q59_$n=$(q59lo $n); sudo losetup -d $(q59lo $n); done; }
	q59on() { local n; for n in "$@"; do eval sudo losetup \$Q59_$n $Q59/$n.img; done; }
	q59off d0 d1
	$M59 -C /dev/md/q59w -e $F -n2 $(q59lo w0) $(q59lo w1) --run >/dev/null 2>&1
	$M59 -C /dev/md/q59wv -l1 -n2 -z 32M /dev/md/q59w --assume-clean --run >/dev/null 2>&1
	stopall; q59off w0 w1; q59on d0 d1
	$M59 -C /dev/md/q59c -e $F -n2 $(q59lo d0) $(q59lo d1) --run >/dev/null 2>&1
	$M59 -C /dev/md/q59v1 -l1 -n2 -z 32M /dev/md/q59c --assume-clean --run >/dev/null 2>&1
	$M59 -C /dev/md/q59v2 -l1 -n2 -z 32M /dev/md/q59c --assume-clean --run >/dev/null 2>&1
	stopall; q59on w0 w1
	$M59 -C /dev/md/q59f -e 1.2 -l1 -n2 -z 32M $(q59lo f0) $(q59lo f1) --assume-clean --run >/dev/null 2>&1
	stopall
	{ for n in d0 d1 f0 f1 w0 w1; do echo "DEVICE $(q59lo $n)"; done; echo "DEVICE containers"; } > $Q59/devs.conf
	ES=$($M59 -Es -c $Q59/devs.conf 2>/dev/null)
	V1=$(echo "$ES" | sed -n 's|^ARRAY /dev/md/q59v1 .* UUID=\([0-9a-f:]*\)$|\1|p')
	V2=$(echo "$ES" | sed -n 's|^ARRAY /dev/md/q59v2 .* UUID=\([0-9a-f:]*\)$|\1|p')
	check "59 $F: sets made: container c with v1 and v2, foreign container w with wv, a 1.2 array on f0 f1" "[ -n '$V1' ] && [ -n '$V2' ] && [ \$(echo \"\$ES\" | grep -c '^ARRAY metadata=$F ') = 2 ] && echo \"\$ES\" | grep -q '^ARRAY /dev/md/q59wv ' && echo \"\$ES\" | grep -q '^ARRAY /dev/md/q59f '"
	q59c() { $M59 -A /dev/md/q59c $(q59lo d0) $(q59lo d1) >/dev/null 2>&1; }
	OK=1; for v in 1 2; do eval U=\$V$v
		q59c; OUT=$($M59 -A /dev/md/q59v$v --uuid=$U /dev/md/q59c 2>&1)
		echo "$OUT" | grep -q 'wrong uuid' && OK=0; q59up q59v$v || OK=0; stopall; done
	check "59a $F: -A v1, v2 --uuid=<volume> <container>: assembled, no 'wrong uuid'" "[ $OK = 1 ]"
	OK=1; for v in 1 2; do
		q59c; OUT=$($M59 -A /dev/md/q59v$v --name=q59v$v /dev/md/q59c 2>&1)
		echo "$OUT" | grep -q 'wrong name' && OK=0; q59up q59v$v || OK=0; stopall; done
	check "59b $F: ... --name=<volume>: assembled, no 'wrong name'" "[ $OK = 1 ]"
	OK=1; for v in 1 2; do eval U=\$V$v
		q59c; $M59 -A /dev/md/q59v$v --uuid=$U /dev/md/q59c >/dev/null 2>&1
		OUT=$($M59 -A /dev/md/q59x --uuid=$U /dev/md/q59c 2>&1)
		echo "$OUT" | grep -q 'is already assembled' || OK=0; echo "$OUT" | grep -q 'wrong uuid' && OK=0; stopall; done
	check "59c $F: ... the volume already running: 'already assembled', no 'wrong uuid'" "[ $OK = 1 ]"
	q59c; OUT=$($M59 -A /dev/md/q59v1 --uuid=12345678:9abcdef0:12345678:9abcdef0 /dev/md/q59c 2>&1); RC=$?
	check "59d $F: ... a UUID no volume of the container has: refused, 'q59c has wrong uuid' for each volume" "[ $RC != 0 ] && [ \$(echo \"\$OUT\" | grep -c '/dev/md/q59c has wrong uuid') = 2 ] && [ ! -e /dev/md/q59v1 ]"
	stopall
	$M59 -A /dev/md/q59w $(q59lo w0) $(q59lo w1) >/dev/null 2>&1
	OUTW=$($M59 -A /dev/md/q59v2 --uuid=$V2 /dev/md/q59w 2>&1); RCW=$?
	OUTF=$($M59 -A /dev/md/q59v2 --uuid=$V2 $(q59lo f0) 2>&1); RCF=$?
	check "59e $F: ... the foreign container w and the 1.2 member f0: refused, 'has wrong uuid'" "[ $RCW != 0 ] && echo \"\$OUTW\" | grep -q '/dev/md/q59w has wrong uuid' && [ $RCF != 0 ] && echo \"\$OUTF\" | grep -q '$(q59lo f0) has wrong uuid' && [ ! -e /dev/md/q59v2 ]"
	stopall
	{ cat $Q59/devs.conf; echo "$ES"; } > $Q59/full.conf
	OUT=$($M59 -As -c $Q59/full.conf 2>&1)
	check "59f $F: -As by mdadm.conf (ARRAY lines of -Es): v1, v2, wv run, no 'wrong uuid'" "q59up q59v1 && q59up q59v2 && q59up q59wv && ! echo \"\$OUT\" | grep -q 'wrong uuid'"
	stopall
	for n in d0 d1 f0 f1 w0 w1; do $M59 --zero-superblock $(q59lo $n) >/dev/null 2>&1; done
	q59drop
done
rmdir $Q59
fi
# --- end of stage 59 ---

# --- stage 60: a member that does not take the transform log is failed in md, as the AMD driver does it (rcblob
# RC_SignalDriveErrorWithLogicalElement: the element 0x10, if LicenseToKill allows) - its copy of the log (for a RAID5
# the data element of "the stripe past the end", the one the AMD driver reads) is read by no one any more, the
# transform goes on with the others. Where it cannot be failed (a RAID0, a degraded volume), the reshape waits,
# holding the writes to the region behind it. Five dm-linear disks of 1 GiB (loop), the volume's log sector
# (AllocatedSpace + 0 = LBA 0x100000 of the first volume) an error target.
# 60a - RAID5 3 -> 4, data moving (the reshape manager, mdadm): d0 does not take the log after the first region -
# mdadm fails d0 in md, mdmon writes 0x10 into both LDs; the reshape goes on degraded to its end (the error still
# there: the end of the migration does not wait for the log on d0 to be cleared), then a rebuild onto the spare d4;
# the data as written during the reshape, md check 0.
# 60b - a RAID5 of three initializing (the monitor, mdmon): d2 (the data element) does not take the log - mdmon fails
# d2, 0x10, one line in the kernel log; the volume degraded, the data readable.
# 60c - RAID0 2 -> 3 (md raid4 without parity): d0 ([0], the only copy) does not take the log - it cannot be failed:
# the reshape waits, a write into the region it moved waits too (suspend); the error gone - the log is written, the
# reshape and the write go on; stopped and assembled, the data as written (before the fix the reshape gave up,
# Grow.c abort_reshape let the write into the region moved, the assembly moved it again over that write).
# 60d - md frozen midway through a region (sync_action frozen, as mdadm -S does for a moment - Manage_stop): the
# manager waits, holding the region; let go, it goes on; the data as written (before the fix amd_reshape_wait gave
# -1, then abort_reshape and the same window).
if want 60; then
cd "$MDADM_DIR"
stopall
Q60=$WQ/q60
# q60free: writes held by a test that failed - let go (as Grow.c abort_reshape), or q60drop would hang on them
q60free() { local m; for m in $(ls /sys/block | grep ^md); do [ -e /sys/block/$m/md/suspend_hi ] || continue
	echo 9223372036854775807 | sudo tee /sys/block/$m/md/suspend_lo >/dev/null 2>&1
	echo 0 | sudo tee /sys/block/$m/md/suspend_hi /sys/block/$m/md/suspend_lo >/dev/null 2>&1; done; }
q60drop() { local n l; for n in 0 1 2 3 4; do q60bad $n 2>/dev/null; done; q60free; sudo pkill -f 'mdadm --grow' 2>/dev/null
	stopall; for n in 0 1 2 3 4; do sudo dmsetup remove q60d$n 2>/dev/null; done
	for l in $(sudo losetup -a | grep $Q60/ | cut -d: -f1); do sudo losetup -d $l; done; rm -rf $Q60; }
# q60mk: five 1 GiB dm-linear disks q60d0..4 over loop; QS - their size
q60mk() { local n L; q60drop; mkdir -p $Q60; Q60D=""
	for n in 0 1 2 3 4; do truncate -s 1G $Q60/d$n.img; L=$(sudo losetup -f --show $Q60/d$n.img); eval Q60L$n=$L
		echo "0 $(sudo blockdev --getsz $L) linear $L 0" | sudo dmsetup create q60d$n; Q60D="$Q60D /dev/mapper/q60d$n"; done
	QS=$(sudo blockdev --getsz $Q60L0); }
# q60bad <n> [<LBA>]: sector <LBA> of q60d<n> an error target; no <LBA>: the table as it was
q60bad() { local L; eval L=\${Q60L$1:-}; [ -n "$L" ] || return 0
	if [ -n "${2:-}" ]; then printf '0 %d linear %s 0\n%d 1 error\n%d %d linear %s %d\n' $2 $L $2 $(($2 + 1)) $((QS - $2 - 1)) $L $(($2 + 1))
	else echo "0 $QS linear $L 0"; fi | sudo dmsetup reload q60d$1 && sudo dmsetup resume q60d$1; }
# q60log <n>: the transform log on d<n> at LB (read from its loop, past the error target): type, mark, status
q60log() { local L; eval L=\$Q60L$1; sudo dd if=$L bs=512 skip=$((LB)) count=1 iflag=direct status=none | python3 -c 'import sys,struct; b=sys.stdin.buffer.read(); print("%x %d %d" % (struct.unpack_from("<I", b, 0x18)[0], struct.unpack_from("<Q", b, 0x1c)[0], struct.unpack_from("<I", b, 0x44)[0]))'; }
# q60flag <n> <LD line>: flags of element e<n> of a qgld line (hex)
q60flag() { echo "$2" | grep -o "e$1=[^ ]*" | cut -d: -f4; }
q60dm() { basename $(readlink -f /dev/mapper/q60d$1); }	# dm-N of d<n>
# q60wait <s>: no resync/reshape/recovery/check in mdstat (twice, 3 s apart), at most <s> seconds
q60wait() { local t=$(( $(date +%s) + $1 )); while [ $(date +%s) -lt $t ]; do grep -qE 'reshape|resync|recover|check' /proc/mdstat || { sleep 3; grep -qE 'reshape|resync|recover|check' /proc/mdstat || return 0; }; sleep 2; done; return 1; }
# q60grep <file> <text> <s>: wait for <text> in <file>
q60grep() { local i; for i in $(seq 1 $3); do grep -q "$2" $1 && return 0; sleep 1; done; return 1; }
q60asm() { local d; for d in $Q60D; do $M -I $d >/dev/null 2>&1; done; $M -I /dev/$(cont1) >/dev/null 2>&1; sleep 2; }
LB=$((0x100000))
slow() { echo $1 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null; }

# 60a: RAID5 3 -> 4, d0 (the data element of the log: 2048 stripes % 4) fails the log after the first region
q60mk
$M -C /dev/md/q60c -e amd -n 3 /dev/mapper/q60d0 /dev/mapper/q60d1 /dev/mapper/q60d2 --run >/dev/null 2>&1; CN=$(cont1)
$M -C /dev/md/q60r5 -l5 -n3 -z 128M /dev/$CN --run >/dev/null 2>&1; V=$(qgmd q60r5); q60wait 120
$M /dev/$CN --add /dev/mapper/q60d3 >/dev/null 2>&1; sleep 1; $M /dev/$CN --add /dev/mapper/q60d4 >/dev/null 2>&1; sleep 1
VID=$(qgids $Q60/d1.img | sed -n 1p)
head -c 128M /dev/urandom > $Q60/pat; sudo dd if=$Q60/pat of=/dev/$V bs=1M oflag=direct status=none
slow 3000; sudo dmesg -C
$M --grow /dev/$V --raid-devices=4 > $Q60/grow.out 2>&1
for i in $(seq 1 50); do [ "$(q60log 1 | cut -d' ' -f1,3)" = '5354 1' ] && break; sleep 0.2; done; q60bad 0 $LB
q60grep $Q60/grow.out 'did not take the AMD transform log' 90; sleep 3
S0=$(qgld $Q60/d1.img $VID); ST=$(cat /sys/block/$V/md/dev-$(q60dm 0)/state 2>/dev/null)
check "60a: 3 -> 4 ($V), d0 takes no log: mdadm fails d0 in md (${ST:-gone}), mdmon records it - 0x10 in both LDs ($(q60flag 0 "$(echo "$S0" | head -1)"), $(q60flag 0 "$(echo "$S0" | tail -1)")); the reshape goes on, degraded" "grep -q '3 -> 4 disks' $Q60/grow.out && grep -q 'did not take the AMD transform log: failed' $Q60/grow.out && ! echo '$ST' | grep -q in_sync && [ \$(cat /sys/block/$V/md/degraded) = 1 ] && [ \$(cat /sys/block/$V/md/sync_action) = reshape ] && [ \$(( 0x$(q60flag 0 "$(echo "$S0" | head -1)") & 0x10 )) != 0 ] && [ \$(( 0x$(q60flag 0 "$(echo "$S0" | tail -1)") & 0x10 )) != 0 ]"
# writes meanwhile - into the region md moved, the one it moves, those ahead
head -c 64M /dev/urandom > $Q60/pat2; sudo dd if=$Q60/pat2 of=/dev/$V bs=1M oflag=direct status=none
slow 400000; q60wait 240; sleep 3; q60wait 240; sleep 2
S1=$(qgld $Q60/d1.img $VID)
check "60a: ... to the end, the error still there (no wait for the log on d0 to be cleared): one LD RAID5 1 x 4, rebuilt onto the spare d4; the data as written, md check 0" "[ \$(cat /sys/block/$V/md/raid_disks) = 4 ] && [ \$(echo \"\$S1\" | wc -l) = 1 ] && echo \"\$S1\" | grep -q 'tt=0 .* fs=1x4' && [ \$(cat /sys/block/$V/md/degraded) = 0 ] && cmp -s <(cat $Q60/pat2; tail -c +$((64 * 1048576 + 1)) $Q60/pat) <(sudo dd if=/dev/$V bs=1M count=128 iflag=direct status=none) && echo check | sudo tee /sys/block/$V/md/sync_action >/dev/null && sleep 1 && q60wait 120 && [ \$(cat /sys/block/$V/md/mismatch_cnt) = 0 ]"

# 60b: RAID5 of three initializing (mdmon logs it): d2, the data element (2048 stripes % 3), fails the log
q60mk
$M -C /dev/md/q60c -e amd -n 3 /dev/mapper/q60d0 /dev/mapper/q60d1 /dev/mapper/q60d2 --run >/dev/null 2>&1; CN=$(cont1)
slow 3000; sudo dmesg -C
$M -C /dev/md/q60r5 -l5 -n3 -z 128M /dev/$CN --run >/dev/null 2>&1; V=$(qgmd q60r5); VID=$(qgids $Q60/d0.img | sed -n 1p)
q60bad 2 $LB
head -c 64M /dev/urandom > $Q60/pat; sudo dd if=$Q60/pat of=/dev/$V bs=1M oflag=direct status=none
for i in $(seq 1 30); do [ $(cat /sys/block/$V/md/degraded) = 1 ] && break; sleep 1; done; sleep 3
S0=$(qgld $Q60/d0.img $VID)
check "60b: RAID5 initializing ($V), d2 takes no log: mdmon fails it (degraded $(cat /sys/block/$V/md/degraded)), 0x10 ($(q60flag 2 "$S0")), told once in the kernel log; the data read as written" "[ -n '$V' ] && [ \$(cat /sys/block/$V/md/degraded) = 1 ] && [ \$(( 0x$(q60flag 2 "$S0") & 0x10 )) != 0 ] && [ \$(sudo dmesg | grep -c 'did not take the transform log: failed') = 1 ] && cmp -s $Q60/pat <(sudo dd if=/dev/$V bs=1M count=64 iflag=direct status=none)"
slow 400000

# 60c: RAID0 2 -> 3 (raid4 without its parity: md cannot do without d0): the log ([0], one copy) waits, writes too
q60mk
$M -C /dev/md/q60c -e amd -n 2 /dev/mapper/q60d0 /dev/mapper/q60d1 --run >/dev/null 2>&1; CN=$(cont1)
$M -C /dev/md/q60z -l0 -n2 -z 64M /dev/$CN --run >/dev/null 2>&1
$M -C /dev/md/q60m -l1 -n2 -z 16M /dev/$CN --run --assume-clean >/dev/null 2>&1	# mdmon runs
sleep 1; Z=$(qgmd q60z); $M /dev/$CN --add /dev/mapper/q60d2 >/dev/null 2>&1; sleep 1
head -c 128M /dev/urandom > $Q60/pat; sudo dd if=$Q60/pat of=/dev/$Z bs=1M oflag=direct status=none
slow 3000
$M --grow /dev/$Z --raid-devices=3 > $Q60/grow.out 2>&1
for i in $(seq 1 50); do [ "$(q60log 0 | cut -d' ' -f1,3)" = '5354 1' ] && break; sleep 0.2; done; q60bad 0 $LB
q60grep $Q60/grow.out 'the reshape waits at' 90; sleep 2
WM=$(sed -n 's/.*cannot write the AMD transform log: the reshape waits at \([0-9]*\).*/\1/p' $Q60/grow.out | head -1)
head -c 64M /dev/urandom > $Q60/pat2; (sudo dd if=$Q60/pat2 of=/dev/$Z bs=1M oflag=direct status=none; touch $Q60/dd.done) &
sleep 6; SH=$(cat /sys/block/$Z/md/suspend_hi)
check "60c: RAID0 2 -> 3 ($Z), d0 takes no log: not failed (md cannot do without it), the reshape waits at ${WM:-?}, writes to the region before wait too (suspend_hi $SH; the write not through)" "[ \${WM:-0} -gt 0 ] && ! grep -q 'did not take the AMD transform log: failed' $Q60/grow.out && [ \$(cat /sys/block/$Z/md/level) = raid4 ] && [ \$(cat /sys/block/$Z/md/degraded) = 1 ] && [ ${SH:-0} -gt 0 ] && [ ! -e $Q60/dd.done ]"
q60bad 0
for i in $(seq 1 30); do [ -e $Q60/dd.done ] && break; sleep 1; done
slow 400000; q60wait 120; for i in $(seq 1 60); do [ "$(cat /sys/block/$Z/md/level)" = raid0 ] && break; sleep 1; done
check "60c: ... d0 well again: the log written, the reshape and the write go on; raid0 of 3" "[ -e $Q60/dd.done ] && grep -q 'the AMD transform log is written: the reshape goes on' $Q60/grow.out && [ \$(cat /sys/block/$Z/md/level) = raid0 ] && [ \$(cat /sys/block/$Z/md/raid_disks) = 3 ]"
q60free; wait; $M -S /dev/$Z >/dev/null 2>&1; stopall; q60asm; Z=$(qgmd q60z); q60wait 120; sleep 2
for i in $(seq 1 60); do [ "$(cat /sys/block/$Z/md/level 2>/dev/null)" = raid0 ] && break; sleep 1; done
check "60c: ... stopped, assembled: the data as written (the region not copied again over the write)" "[ -n '$Z' ] && cmp -s <(cat $Q60/pat2; tail -c +$((64 * 1048576 + 1)) $Q60/pat) <(sudo dd if=/dev/$Z bs=1M count=128 iflag=direct status=none)"

# 60d: RAID5 3 -> 4, md frozen midway through a region: held so, the writes too; let go (idle) - on to the end
q60mk
$M -C /dev/md/q60c -e amd -n 3 /dev/mapper/q60d0 /dev/mapper/q60d1 /dev/mapper/q60d2 --run >/dev/null 2>&1; CN=$(cont1)
$M -C /dev/md/q60r5 -l5 -n3 -z 128M /dev/$CN --run >/dev/null 2>&1; V=$(qgmd q60r5); q60wait 120
$M /dev/$CN --add /dev/mapper/q60d3 >/dev/null 2>&1; sleep 1
head -c 128M /dev/urandom > $Q60/pat; sudo dd if=$Q60/pat of=/dev/$V bs=1M oflag=direct status=none
slow 1000
$M --grow /dev/$V --raid-devices=4 > $Q60/grow.out 2>&1
# md some way into a region past the first (the log - d1's copy - at its start; md's progress in member sectors x 3)
q60done() { local s=$(cut -d' ' -f1 /sys/block/$V/md/sync_completed); [ "$s" = none ] && echo 0 || echo $((s * 3)); }
for i in $(seq 1 300); do G=$(q60log 1)
	[ "$(echo $G | cut -d' ' -f1,3)" = '5354 1' ] && [ $(echo $G | cut -d' ' -f2) -gt 0 ] &&
		[ $(q60done) -gt $(( $(echo $G | cut -d' ' -f2) + 8192 )) ] && break; sleep 0.1; done
RP=$(q60done); echo frozen | sudo tee /sys/block/$V/md/sync_action >/dev/null; sleep 4
M1=$(q60log 1 | cut -d' ' -f2)
head -c 64M /dev/urandom > $Q60/pat2; (sudo dd if=$Q60/pat2 of=/dev/$V bs=1M oflag=direct status=none; touch $Q60/dd.done) &
sleep 6; SH=$(cat /sys/block/$V/md/suspend_hi)
check "60d: frozen midway (reshaped to $RP, the log at $M1): the region held (suspend_hi $SH), the write waits" "[ \$(cat /sys/block/$V/md/sync_action) = frozen ] && [ ${SH:-0} -gt 0 ] && [ ! -e $Q60/dd.done ] && [ ${RP:-0} -gt ${M1:-0} ]"
echo idle | sudo tee /sys/block/$V/md/sync_action >/dev/null; slow 400000
for i in $(seq 1 60); do [ -e $Q60/dd.done ] && break; sleep 1; done; q60wait 240; sleep 3
q60free; wait; $M -S /dev/$V >/dev/null 2>&1; stopall; q60asm; V=$(qgmd q60r5); q60wait 240; sleep 2
check "60d: ... let go: on to the end; stopped, assembled: raid5 of 4, the data as written, md check 0" "[ -e $Q60/dd.done ] && [ -n '$V' ] && [ \$(cat /sys/block/$V/md/raid_disks) = 4 ] && cmp -s <(cat $Q60/pat2; tail -c +$((64 * 1048576 + 1)) $Q60/pat) <(sudo dd if=/dev/$V bs=1M count=128 iflag=direct status=none) && echo check | sudo tee /sys/block/$V/md/sync_action >/dev/null && sleep 1 && q60wait 120 && [ \$(cat /sys/block/$V/md/mismatch_cnt) = 0 ]"
q60drop
fi
# --- end of stage 60 ---

# --- stage 61: md failed a disk in one volume - failed there alone, as the AMD driver does it (rcblob 9.3.3
# RC_SignalDriveErrorWithLogicalElement @0013b2c0: the element of that LD 0x10; the PD stays ONLINE, the disk's
# elements in other volumes stay in service, configurations go on to it - seen with rcraid 9.3.3-00302). Before:
# mdmon (monitor.c reconcile_failed) failed the disk in every volume of the container, wrote its PD OFFLINE and
# wrote to it no more - a RAID0 on the same disk was lost. A disk that goes away (udev: mdadm -If) is still failed in
# every volume.
# Four dm-linear disks of 1 GiB (loop); a container on d0-d2, a RAID5 of three of 128 MiB (first) and a RAID0 of
# three of 64 MiB.
# 61a - the RAID5's data sector on d0 an error target, a write to the RAID5: md fails d0 in the RAID5; the RAID0 in
# service, d0 in it; the data of both as written; in the packet on d1: d0's element in the RAID5 0x10, in the RAID0
# 0; d0's PD ONLINE; d0 gets the configurations.
# 61b - stopped, the error gone, assembled (-I per disk; then -A of the container): the RAID5 without d0 (no rebuild
# onto it), the RAID0 with d0; the data intact.
# 61c - d3 into the container (--add): the RAID5 rebuilt onto d3, not onto d0; the RAID0 in service; the data
# intact, md check 0.
# 61d - a new set: a RAID5 on d0-d2 and a RAID1 on d0+d1; --fail d1 in the RAID5 - there alone (the RAID1 [2/2], d1's
# PD ONLINE); then udev removes d1 (mdadm -If): d1 out of the RAID1 and the container, its PD OFFLINE, no more
# configurations written to d1.
# 61e - a configuration write fails on d2 (read-only): d2 stale, the next configuration has its PD OFFLINE (rcblob
# RC_WriteAllConfigData @00134ad0: the PD by how its write went).
if want 61; then
cd "$MDADM_DIR"
stopall
Q61=$WQ/q61
q61drop() { local n l; for n in 0 1 2 3; do q61bad $n 2>/dev/null; done; stopall
	for n in 0 1 2 3; do sudo dmsetup remove q61d$n 2>/dev/null; done
	for l in $(sudo losetup -a | grep $Q61/ | cut -d: -f1); do sudo losetup -d $l; done; rm -rf $Q61; }
# q61mk: four 1 GiB dm-linear disks q61d0..3 over loop; QS - their size; Q61ID<n> - their DeviceID, low 16 bits (hex)
q61mk() { local n L; q61drop; mkdir -p $Q61; Q61D=""
	for n in 0 1 2 3; do truncate -s 1G $Q61/d$n.img; L=$(sudo losetup -f --show $Q61/d$n.img); eval Q61L$n=$L
		echo "0 $(sudo blockdev --getsz $L) linear $L 0" | sudo dmsetup create q61d$n; Q61D="$Q61D /dev/mapper/q61d$n"; done
	QS=$(sudo blockdev --getsz $Q61L0); }
# q61bad <n> [<LBA>]: sector <LBA> of q61d<n> an error target; no <LBA>: the table as it was
q61bad() { local L; eval L=\${Q61L$1:-}; [ -n "$L" ] || return 0
	if [ -n "${2:-}" ]; then printf '0 %d linear %s 0\n%d 1 error\n%d %d linear %s %d\n' $2 $L $2 $(($2 + 1)) $((QS - $2 - 1)) $L $(($2 + 1))
	else echo "0 $QS linear $L 0"; fi | sudo dmsetup reload q61d$1 && sudo dmsetup resume q61d$1; }
q61dm() { basename $(readlink -f /dev/mapper/q61d$1); }	# dm-N of d<n>
q61id() { python3 $TOOLS/amdraid_dump.py --brief $Q61/d$1.img 2>/dev/null | sed -n '1s/.*DeviceID \([0-9a-f]*\),.*/\1/p'; }
# q61fl <LD line> <n>: flags of the element of d<n> in a qgld line (hex)
q61fl() { echo "$1" | grep -o " e[0-9]*=$(printf %x $((0x$(eval echo \$Q61ID$2) & 0xffff))):[^ ]*" | cut -d: -f4; }
# q61pd <img> <n>: DeviceState of d<n>'s PD in the live packet of <img> (ONLINE, OFFLINE)
q61pd() { python3 $TOOLS/amdraid_dump.py --brief $Q61/d$1.img 2>/dev/null | grep "PD handle .* $(eval echo \$Q61FULL$2) " | awk '{print $6}'; }
q61gen() { $M -E /dev/mapper/q61d$1 2>/dev/null | awk '/Generation/{print $NF; exit}'; }
q61st() { cat /sys/block/$1/md/dev-$(q61dm $2)/state 2>/dev/null; }	# state of d<n> in md <md>, empty: not in it
q61vid() { python3 $TOOLS/amdraid_dump.py --brief $Q61/d$1.img 2>/dev/null | grep -E "  Array .* $2" | awk '{print $3}'; }	# LD ID of the volume <regex> fits
q61wait() { local t=$(( $(date +%s) + $1 )); while [ $(date +%s) -lt $t ]; do grep -qE 'reshape|resync|recover|check' /proc/mdstat || { sleep 3; grep -qE 'reshape|resync|recover|check' /proc/mdstat || return 0; }; sleep 2; done; return 1; }
q61asm() { local d; for d in $Q61D; do $M -I $d >/dev/null 2>&1; done; $M -I /dev/$(cont1) >/dev/null 2>&1; sleep 3; }
q61ids() { local n; for n in 0 1 2 3; do eval Q61FULL$n=$(q61id $n); eval Q61ID$n=\${Q61FULL$n: -4}; done; }

# 61a: RAID5 + RAID0 on d0..d2; a write error in the RAID5's extent of d0
q61mk
$M -C /dev/md/q61c -e amd -n 3 /dev/mapper/q61d0 /dev/mapper/q61d1 /dev/mapper/q61d2 --run >/dev/null 2>&1; CN=$(cont1)
$M -C /dev/md/q61r5 -l5 -n3 -z 128M /dev/$CN --run >/dev/null 2>&1
$M -C /dev/md/q61z -l0 -n3 -z 64M /dev/$CN --run >/dev/null 2>&1; sleep 1
V=$(qgmd q61r5); Z=$(qgmd q61z); q61wait 180; q61ids
V5=$(q61vid 1 'R5 '); V0=$(q61vid 1 'R10N .* 3x1 ')
head -c 64M /dev/urandom > $Q61/p5; head -c 128M /dev/urandom > $Q61/p0
sudo dd if=$Q61/p0 of=/dev/$Z bs=1M oflag=direct status=none
OFF=$($M -E /dev/mapper/q61d0 2>/dev/null | sed -n 's/.* Member *0 : .* offset \([0-9]*\) .*/\1/p' | head -1)
q61bad 0 $(( ${OFF:-0} + 2048 )); sudo dmesg -C
sudo dd if=$Q61/p5 of=/dev/$V bs=1M oflag=direct status=none
for i in $(seq 1 30); do [ "$(cat /sys/block/$V/md/degraded)" = 1 ] && break; sleep 1; done; sleep 3
S5=$(qgld $Q61/d1.img $V5); S0=$(qgld $Q61/d1.img $V0)
check "61a: a write error in the RAID5 ($V) on d0: failed there (degraded $(cat /sys/block/$V/md/degraded), d0 '$(q61st $V 0)'); the RAID0 ($Z) on the same disks runs, d0 in it '$(q61st $Z 0)'" "[ -n '$V' ] && [ -n '$Z' ] && [ -n '$OFF' ] && [ \$(cat /sys/block/$V/md/degraded) = 1 ] && ! q61st $V 0 | grep -q in_sync && [ \"\$(q61st $Z 0)\" = in_sync ] && ! grep -q broken /sys/block/$Z/md/array_state"
check "61a: ... recorded as the AMD driver does: d0's element 0x10 in the RAID5 ($(q61fl "$S5" 0)), 0 in the RAID0 ($(q61fl "$S0" 0)); its PD $(q61pd 1 0); d0 gets the configurations ($(q61gen 0), d1 $(q61gen 1))" "[ -n '$V5' ] && [ -n '$V0' ] && [ \$(( 0x$(q61fl "$S5" 0) & 0x10 )) != 0 ] && [ '$(q61fl "$S0" 0)' = 0 ] && [ \"\$(q61pd 1 0)\" = ONLINE ] && [ -n \"\$(q61gen 0)\" ] && [ \"\$(q61gen 0)\" = \"\$(q61gen 1)\" ]"
check "61a: ... the data of both as written (the RAID5 degraded)" "cmp -s $Q61/p5 <(sudo dd if=/dev/$V bs=1M count=64 iflag=direct status=none) && cmp -s $Q61/p0 <(sudo dd if=/dev/$Z bs=1M count=128 iflag=direct status=none)"

# 61b: stopped, the error gone, assembled per disk
q61bad 0; stopall; q61asm; V=$(qgmd q61r5); Z=$(qgmd q61z); sleep 5
check "61b: stopped, assembled (-I): the RAID5 ($V) without d0 (degraded, no rebuild onto it), the RAID0 ($Z) with d0; PD d0 $(q61pd 1 0); the data as written" "[ -n '$V' ] && [ -n '$Z' ] && [ \$(cat /sys/block/$V/md/degraded) = 1 ] && [ -z \"\$(q61st $V 0)\" ] && ! grep -q recover /proc/mdstat && [ \"\$(q61st $Z 0)\" = in_sync ] && [ \"\$(q61pd 1 0)\" = ONLINE ] && cmp -s $Q61/p5 <(sudo dd if=/dev/$V bs=1M count=64 iflag=direct status=none) && cmp -s $Q61/p0 <(sudo dd if=/dev/$Z bs=1M count=128 iflag=direct status=none)"
stopall; $M -A /dev/md/q61c -e amd /dev/mapper/q61d0 /dev/mapper/q61d1 /dev/mapper/q61d2 >/dev/null 2>&1
$M -I /dev/md/q61c >/dev/null 2>&1; sleep 3; V=$(qgmd q61r5); Z=$(qgmd q61z); sleep 3
check "61b: ... the same with -A of the container: the RAID5 ($V) without d0, the RAID0 ($Z) with d0, the data as written" "[ -n '$V' ] && [ -n '$Z' ] && [ \$(cat /sys/block/$V/md/degraded) = 1 ] && [ -z \"\$(q61st $V 0)\" ] && ! grep -q recover /proc/mdstat && [ \"\$(q61st $Z 0)\" = in_sync ] && cmp -s $Q61/p5 <(sudo dd if=/dev/$V bs=1M count=64 iflag=direct status=none) && cmp -s $Q61/p0 <(sudo dd if=/dev/$Z bs=1M count=128 iflag=direct status=none)"

# 61c: a spare: the RAID5 rebuilds onto it, not onto d0 (free room after the RAID0, but failed in the RAID5)
CN=$(cont1); $M /dev/$CN --add /dev/mapper/q61d3 >/dev/null 2>&1; sleep 3; q61wait 180; sleep 3; q61ids
S5=$(qgld $Q61/d1.img $V5)
check "61c: d3 added: the RAID5 rebuilt onto it, not onto d0 (d3 '$(q61st $V 3)', d0 '$(q61st $V 0)'); the RAID0 with d0; the data as written, md check 0" "[ \$(cat /sys/block/$V/md/degraded) = 0 ] && [ \"\$(q61st $V 3)\" = in_sync ] && [ -z \"\$(q61st $V 0)\" ] && [ '$(q61fl "$S5" 3)' = 0 ] && [ \"\$(q61st $Z 0)\" = in_sync ] && cmp -s $Q61/p5 <(sudo dd if=/dev/$V bs=1M count=64 iflag=direct status=none) && cmp -s $Q61/p0 <(sudo dd if=/dev/$Z bs=1M count=128 iflag=direct status=none) && echo check | sudo tee /sys/block/$V/md/sync_action >/dev/null && sleep 1 && q61wait 120 && [ \$(cat /sys/block/$V/md/mismatch_cnt) = 0 ]"

# 61d: RAID5 on d0..d2, RAID1 on d0+d1; --fail d1 in the RAID5, then d1 pulled (udev: mdadm -If)
q61mk
$M -C /dev/md/q61c -e amd -n 3 /dev/mapper/q61d0 /dev/mapper/q61d1 /dev/mapper/q61d2 --run >/dev/null 2>&1; CN=$(cont1)
$M -C /dev/md/q61r5 -l5 -n3 -z 128M /dev/$CN --run >/dev/null 2>&1
$M -C /dev/md/q61m -e amd -l1 -n2 -z 64M /dev/mapper/q61d0 /dev/mapper/q61d1 --run --assume-clean >/dev/null 2>&1; sleep 1
V=$(qgmd q61r5); R=$(qgmd q61m); q61wait 180; q61ids
$M /dev/$V --fail /dev/mapper/q61d1 >/dev/null 2>&1; sleep 4
check "61d: --fail d1 in the RAID5 ($V): failed there alone - the RAID1 ($R) keeps it ('$(q61st $R 1)', degraded $(cat /sys/block/$R/md/degraded 2>/dev/null)); PD d1 $(q61pd 0 1), configurations on d1 ($(q61gen 1), d0 $(q61gen 0))" "[ -n '$V' ] && [ -n '$R' ] && [ \$(cat /sys/block/$V/md/degraded) = 1 ] && [ \"\$(q61st $R 1)\" = in_sync ] && [ \$(cat /sys/block/$R/md/degraded) = 0 ] && [ \"\$(q61pd 0 1)\" = ONLINE ] && [ \"\$(q61gen 1)\" = \"\$(q61gen 0)\" ]"
G1=$(q61gen 1); $M -If /dev/$(q61dm 1) >/dev/null 2>&1; sleep 4
$M --update-subarray=1 --update=write-back /dev/$CN >/dev/null 2>&1; sleep 2
check "61d: d1 pulled (mdadm -If): out of the RAID1 too ([2/1]) and of the container, its PD OFFLINE, no configuration written to it since ($G1 -> $(q61gen 1), d0 $(q61gen 0))" "[ \$(cat /sys/block/$R/md/degraded) = 1 ] && [ -z \"\$(q61st $R 1)\" ] && [ ! -e /sys/block/$CN/md/dev-$(q61dm 1) ] && [ \"\$(q61pd 0 1)\" = OFFLINE ] && [ \"\$(q61gen 1)\" = '$G1' ] && [ \$(q61gen 0) -gt ${G1:-0} ]"
# 61e: a configuration write fails on d2 (read-only): the next configuration has its PD OFFLINE (as the AMD driver)
G2=$(q61gen 2); sudo blockdev --setro /dev/mapper/q61d2
$M --update-subarray=1 --update=no-write-back /dev/$CN >/dev/null 2>&1; sleep 2
$M --update-subarray=1 --update=write-back /dev/$CN >/dev/null 2>&1; sleep 2; sudo blockdev --setrw /dev/mapper/q61d2
check "61e: a configuration write fails on d2: it stays stale ($G2 -> $(q61gen 2), d0 $(q61gen 0)), the next configuration has its PD OFFLINE ($(q61pd 0 2))" "[ \"\$(q61gen 2)\" = '$G2' ] && [ \$(q61gen 0) -gt \$(( ${G2:-0} + 1 )) ] && [ \"\$(q61pd 0 2)\" = OFFLINE ]"
q61drop
fi
# --- end of stage 61 ---

# --- stage 62: a RAID10 stopped (mdadm -S) midway through a chunk change. The reshape manager takes raid10's
# progress from /proc/mdstat (amd_mdstat_reshaped), and while md cleans up a reshape it has interrupted (md.c
# status_resync: MD_RECOVERY_DONE, "Still cleaning up") /proc/mdstat shows the whole array done for some 15 ms,
# sync_action frozen already. 1.5 took that for the end of the region: the log went a region ahead, md never moved
# that region, and after assembly it stayed in the old layout - the data wrong, md check 0. The manager looks every
# 100 ms and does not always hit the window: 9 of 50 random stops of a RAID10 2 x 2 (64 -> 128 and 256 -> 128 KiB,
# 32 MiB a member) went wrong with 1.5, 2 and 1 of 18 tries in this stage. Fixed: the progress from mdstat only
# while sync_action is "reshape", the end only of an array md runs (array_state not "clear" or "inactive").
# Here: a RAID10 2 x 2 of 64 KiB, 32 MiB a member, the sector number in every sector, md at 2000 KB/s, -S 3 to
# 14 s after --grow --chunk=128, assembled, run to the end, the whole volume read, md check; Q62N tries (default 24,
# about 10 minutes) - with 1.5 at least one goes wrong with a probability of 86 to 97 % (8 to 14 % a try).
if want 62; then
cd "$MDADM_DIR"
stopall
Q62N=${Q62N:-24}
# q62pat fill|check <md> [<sectors>]: in each sector s the pair (5, s) of 8-byte numbers; fill prints the number
# of sectors, check the number of sectors that differ (and the first and last of them)
q62pat() { sudo python3 - "$@" <<'PY'
import os, struct, sys
op, dev = sys.argv[1], "/dev/" + sys.argv[2]
fd = os.open(dev, os.O_RDWR if op == "fill" else os.O_RDONLY)
n = int(sys.argv[3]) if op == "check" else os.lseek(fd, 0, 2) // 512
os.lseek(fd, 0, 0); s = 0; bad = []
while s < n:
    k = min(2048, n - s); want = b"".join(struct.pack("<QQ", 5, x) * 32 for x in range(s, s + k))
    if op == "fill": os.write(fd, want)
    else:
        b = os.read(fd, k * 512)
        if b != want: bad += [x for x in range(s, s + k) if b[(x - s) * 512:(x - s + 1) * 512] != want[(x - s) * 512:(x - s + 1) * 512]]
    s += k
if op == "fill": os.fsync(fd); print(n)
else: print("%d%s" % (len(bad), "_0x%x-0x%x" % (bad[0], bad[-1]) if bad else ""))
PY
}
q62wait() { for i in $(seq 1 300); do grep -qE 'resync|recover|check|reshape' /proc/mdstat || { sleep 2; grep -qE 'resync|recover|check|reshape' /proc/mdstat || return 0; }; sleep 1; done; return 1; }
Q62R=""; Q62OK=0
for q62i in $(seq 1 $Q62N); do
	qgmk q62 4 1
	echo 1000 | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null; echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
	$M -C /dev/md/amd62 -e amd -n 4 $(qgl 0) $(qgl 1) $(qgl 2) $(qgl 3) --run >/dev/null 2>&1
	$M -C /dev/md/r62 -e amd -l10 -n4 -c64 -z 32M $(qgl 0) $(qgl 1) $(qgl 2) $(qgl 3) --run >/dev/null 2>&1
	sleep 1; waitrec; V=$(qgmd r62); [ -n "$V" ] || { Q62R="$Q62R $q62i:no-volume"; continue; }
	NS=$(q62pat fill $V)
	echo 1 | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null; echo 2000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
	$M --grow /dev/$V --chunk=128 >/dev/null 2>&1
	sleep $((3 + RANDOM % 12)); $M -S /dev/$V >/dev/null 2>&1; sleep 1
	Q62L=$(qgtlog $(qgl 0) 0x100000 | cut -d" " -f2)
	stopall; qgasm; V=$(qgmd r62)
	echo 1000 | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null; echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
	q62wait; sleep 2
	B=$(q62pat check $V $NS); echo check | sudo tee /sys/block/$V/md/sync_action >/dev/null; sleep 1; q62wait
	C=$(cat /sys/block/$V/md/chunk_size); MM=$(cat /sys/block/$V/md/mismatch_cnt)
	[ "$C" = 131072 ] && [ "$B" = 0 ] && [ "$MM" = 0 ] && Q62OK=$((Q62OK + 1)) || Q62R="$Q62R $q62i:log=0x$Q62L,chunk=$C,bad=$B,mm=$MM"
done
check "62: RAID10 2 x 2 --chunk=128 stopped (-S) midway, $Q62N times: assembled, done - 128 KiB, the data as written, md check 0 every time ($Q62OK of $Q62N;$Q62R)" "[ $Q62OK = $Q62N ]"
qgdrop q62
fi
# --- end of stage 62 ---

# --- stage 63: a RAID10 stopped (mdadm -S) midway through a chunk change goes on after assembly. Grow.c
# start_reshape() holds md where the reshape goes on from: sync_max = reshape_progress / data_disks, as for a RAID5,
# whose reshape md counts in sectors of a member; md counts that of a RAID10 in sectors of the array (raid10.c
# reshape_request), and the data_disks of a RAID10 are all its disks (analyse_change). On a RAID10 of 3 x 2 the AMD
# region is 0x7f80 (64 KiB) or 0x7e00 (256 KiB) sectors, and at an odd region mark the quotient is no multiple of
# the chunk: md.c max_sync_store - EINVAL, "Cannot continue reshape", the volume stays read-only and md reads the
# part it moved wrong (raid10.c choose_data_offset: the old data offset with the new geometry while no reshape
# runs). A 2 x 2 (region 0x8000, the quotient a multiple of the chunk) went on by chance. Here: RAID10 3 x 2
# 64 -> 128 and 256 -> 64 KiB, 2 x 2 64 -> 128 (control), 32 MiB a member, the sector number in every sector, md at
# 2000 KB/s, -S at different places (midway through regions 0 to 4 - from 0 the reshape goes on another way,
# Assemble.c; "edge": md at the end of a region, waiting for the log), assembled; checked: the volume went on (not
# read-only, md reshaping), reached the new chunk, the data as written, md check 0. How many marks were odd is in
# the output; about 9 minutes.
if want 63; then
cd "$MDADM_DIR"
stopall
# q63pat fill|check <md> [<sectors>]: in each sector s the pair (5, s) of 8-byte numbers; fill prints the number
# of sectors, check the number of sectors that differ (and the first and last of them)
q63pat() { sudo python3 - "$@" <<'PY'
import os, struct, sys
op, dev = sys.argv[1], "/dev/" + sys.argv[2]
fd = os.open(dev, os.O_RDWR if op == "fill" else os.O_RDONLY)
n = int(sys.argv[3]) if op == "check" else os.lseek(fd, 0, 2) // 512
os.lseek(fd, 0, 0); s = 0; bad = []
while s < n:
    k = min(2048, n - s); want = b"".join(struct.pack("<QQ", 5, x) * 32 for x in range(s, s + k))
    if op == "fill": os.write(fd, want)
    else:
        b = os.read(fd, k * 512)
        if b != want: bad += [x for x in range(s, s + k) if b[(x - s) * 512:(x - s + 1) * 512] != want[(x - s) * 512:(x - s + 1) * 512]]
    s += k
if op == "fill": os.fsync(fd); print(n)
else: print("%d%s" % (len(bad), "_0x%x-0x%x" % (bad[0], bad[-1]) if bad else ""))
PY
}
q63busy() { grep -qE 'resync|recover|check|reshape' /proc/mdstat; }
q63wait() { for i in $(seq 1 300); do q63busy || { sleep 2; q63busy || return 0; }; sleep 1; done; return 1; }
# q63stop <md> mid|edge <K>: mdadm -S once md is midway through region K (0 the first; a region lies between the
# values of sync_max the manager sets) or (edge) has reached the end of region K - 1 and waits at sync_max; prints where
q63stop() { sudo python3 - "$@" <<'PY'
import re, subprocess, sys, time
md, how, k = sys.argv[1], sys.argv[2], int(sys.argv[3]); ends = [0]; t0 = time.time()
def rd(a):
    try: return open("/sys/block/%s/md/%s" % (md, a)).read().strip()
    except OSError: return ""
while time.time() - t0 < 300:
    mx = rd("sync_max")
    if mx.isdigit() and int(mx) > ends[-1]: ends.append(int(mx))
    m = re.search(r"reshape =\s*[0-9.]+% \((\d+)/", open("/proc/mdstat").read().split(md + " :", 1)[-1].split("\n\n")[0])
    d = int(m.group(1)) * 2 if m else -1
    n = len(ends) - 1	# the region md is let on to the end of
    if (how == "mid" and n == k + 1 and d >= (ends[-2] + ends[-1]) // 2) or (how == "edge" and n == k and d >= ends[-1]):
        subprocess.run(["sudo", "-E", "./mdadm", "-S", "/dev/" + md], capture_output=True)
        print("%s%d@0x%x" % (how, k, d)); sys.exit(0)
    time.sleep(0.02)
subprocess.run(["sudo", "-E", "./mdadm", "-S", "/dev/" + md], capture_output=True); print("%s%d@timeout" % (how, k))
PY
}
# q63one <disks> <chunk> <new chunk> mid|edge <K>: one try; Q63R the failures, Q63OK, Q63ODD, Q63AT where stopped
q63one() { local nd=$1 c1=$2 c2=$3 how=$4$5 V NS L RO B C MM i ls=""
	qgmk q63 $nd 1
	for i in $(seq 0 $((nd - 1))); do ls="$ls $(qgl $i)"; done
	echo 1000 | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null; echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
	$M -C /dev/md/amd63 -e amd -n $nd $ls --run >/dev/null 2>&1
	$M -C /dev/md/r63 -e amd -l10 -n$nd -c$c1 -z 32M $ls --run >/dev/null 2>&1
	sleep 1; waitrec; V=$(qgmd r63); [ -n "$V" ] || { Q63R="$Q63R ${nd}d$c1-$how:no-volume"; return; }
	NS=$(q63pat fill $V)
	echo 1 | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null; echo 2000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
	$M --grow /dev/$V --chunk=$c2 >/dev/null 2>&1
	Q63AT="$Q63AT $(q63stop $V $4 $5)"
	sleep 1; L=$(qgtlog $(qgl 0) 0x100000 | cut -d" " -f2)
	stopall; qgasm; V=$(qgmd r63); sleep 3
	# went on: not read-only, md reshaping (or done already)
	RO=$(cat /sys/block/$V/md/array_state 2>/dev/null)/$(cat /sys/block/$V/md/sync_action 2>/dev/null)
	echo 1000 | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null; echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
	q63wait; sleep 2
	B=$(q63pat check $V $NS); echo check | sudo tee /sys/block/$V/md/sync_action >/dev/null; sleep 1; q63wait
	C=$(cat /sys/block/$V/md/chunk_size); MM=$(cat /sys/block/$V/md/mismatch_cnt)
	# an odd region mark of a 3 x 2 is where 1.5 did not go on (divided by 6, no multiple of the chunk)
	[ $nd = 6 ] && [ -n "$L" ] && [ $(((0x$L / (c1 == 64 ? 0x7f80 : 0x7e00)) % 2)) = 1 ] && Q63ODD=$((Q63ODD + 1))
	case $RO in readonly/*|*/idle|*/frozen) [ "$C" = $((c2 * 1024)) ] || RO="stuck:$RO";; esac
	[ "$C" = $((c2 * 1024)) ] && [ "$B" = 0 ] && [ "$MM" = 0 ] && case $RO in stuck:*) false;; *) true;; esac &&
		Q63OK=$((Q63OK + 1)) || Q63R="$Q63R ${nd}d$c1-$how:log=0x$L,after=$RO,chunk=${C%% *},bad=$B,mm=$MM"
}
Q63R=""; Q63OK=0; Q63ODD=0; Q63N=0; Q63AT=""
for q63s in "mid 0" "mid 1" "mid 2" "mid 3" "mid 4" "edge 2" "edge 3"; do q63one 6 64 128 $q63s; Q63N=$((Q63N + 1)); done
for q63s in "mid 1" "mid 2" "edge 3"; do q63one 6 256 64 $q63s; Q63N=$((Q63N + 1)); done
echo "63: RAID10 3 x 2 stopped at$Q63AT"
check "63: RAID10 3 x 2 --chunk 64 -> 128 and 256 -> 64 stopped (-S) midway, $Q63N times ($Q63ODD at an odd region mark): goes on after assembly, done - the new chunk, the data as written, md check 0 every time ($Q63OK of $Q63N;$Q63R)" "[ $Q63OK = $Q63N ] && [ $Q63ODD -gt 0 ]"
Q63R=""; Q63OK=0; Q63N=0; Q63AT=""
for q63s in "mid 1" "mid 2" "edge 2"; do q63one 4 64 128 $q63s; Q63N=$((Q63N + 1)); done
echo "63: RAID10 2 x 2 stopped at$Q63AT"
check "63: RAID10 2 x 2 --chunk 64 -> 128 stopped midway, $Q63N times: the same ($Q63OK of $Q63N;$Q63R)" "[ $Q63OK = $Q63N ]"
qgdrop q63
fi
# --- end of stage 63 ---

# --- stage 64: a RAID10 2 x 2, the chunk changed 64 -> 128: the AMD log does not get ahead of md (real hardware: md
# stood at 0x140100, and after assembly it went on from 0x290000 - a third of the volume left in the old layout).
# a) A second manager on the running volume. After mdadm -S, mdmon ran the volume again (its "active" for the
#    write-pending state came after "inactive"), the manager before left (its sync_completed was of the stopped
#    volume), and udev started mdadm-grow-continue@ by MD_RESHAPE_ACTIVE. That one took the sync_max the manager
#    before held md at (the end of a region) for where md was, twice it (Grow.c verify_reshape_position: a RAID10's
#    sync_max is in sectors of the array), and wrote the log there. Here the same without the restart: the manager
#    killed (SIGKILL), mdadm --grow --continue of the container, -S 1 s later. Before the fix: the log at
#    2 x sync_max, after assembly the part [where md was, that mark) wrong - every time.
# b) md interrupted unfrozen ("idle" in sync_action, as Grow.c abort_reshape interrupts it): for some 15 ms
#    /proc/mdstat shows the whole array with sync_action "reshape", which the manager took for the end of a region.
#    It hardly ever hit that window (the sync_completed event wakes it before, the next look is 100 ms later; 0 of
#    about 20 in a VM): here, that the manager goes through such interruptions with the data intact.
# c) mdmon does not run a volume mdadm -S stopped again: no "active with" of the volume in the kernel log after -S.
# Each try: a fresh volume, 64 MiB a member (with 32 MiB the doubled mark of a) is the end of the volume already and
# no log is written), the sector number in every sector, assembled, run to the end, the whole volume read, chunk
# 128K, md check 0. Q64A, Q64B, Q64C tries (3, 2, 5); about 8 minutes.
if want 64; then
cd "$MDADM_DIR"
stopall
Q64A=${Q64A:-3}; Q64B=${Q64B:-2}; Q64C=${Q64C:-5}
# q64pat fill|check <md> [<sectors>]: in each sector s the pair (5, s) of 8-byte numbers; fill prints the number
# of sectors, check the number of sectors that differ (and the first and last of them)
q64pat() { sudo python3 - "$@" <<'PY'
import os, struct, sys
op, dev = sys.argv[1], "/dev/" + sys.argv[2]
fd = os.open(dev, os.O_RDWR if op == "fill" else os.O_RDONLY)
n = int(sys.argv[3]) if op == "check" else os.lseek(fd, 0, 2) // 512
os.lseek(fd, 0, 0); s = 0; bad = []
while s < n:
    k = min(2048, n - s); want = b"".join(struct.pack("<QQ", 5, x) * 32 for x in range(s, s + k))
    if op == "fill": os.write(fd, want)
    else:
        b = os.read(fd, k * 512)
        if b != want: bad += [x for x in range(s, s + k) if b[(x - s) * 512:(x - s + 1) * 512] != want[(x - s) * 512:(x - s + 1) * 512]]
    s += k
if op == "fill": os.fsync(fd); print(n)
else: print("%d%s" % (len(bad), "_0x%x-0x%x" % (bad[0], bad[-1]) if bad else ""))
PY
}
q64wait() { for i in $(seq 1 300); do grep -qE 'resync|recover|check|reshape' /proc/mdstat || { sleep 2; grep -qE 'resync|recover|check|reshape' /proc/mdstat || return 0; }; sleep 1; done; return 1; }
q64spd() { echo $1 | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null; echo $2 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null; }
q64pos() { grep -A3 "^$1 :" /proc/mdstat | grep -o 'reshape = [^(]*([0-9]*' | grep -o '[0-9]*$'; }	# where md is, KiB
# q64mk: a fresh RAID10 2 x 2 of 64K "r64", 64 MiB a member, the pattern written, the chunk change to 128K started
# slowly (md at 1000 KB/s)
q64mk() { qgmk q64 4 1; q64spd 1000 400000
	$M -C /dev/md/amd64 -e amd -n 4 $(qgl 0) $(qgl 1) $(qgl 2) $(qgl 3) --run >/dev/null 2>&1
	$M -C /dev/md/r64 -e amd -l10 -n4 -c64 -z 64M $(qgl 0) $(qgl 1) $(qgl 2) $(qgl 3) --run >/dev/null 2>&1
	sleep 1; waitrec; V=$(qgmd r64); [ -n "$V" ] || return 1
	NS=$(q64pat fill $V); q64spd 1 1000
	$M --grow /dev/$V --chunk=128 >/dev/null 2>&1; }
# q64end: assembled, run to the end, the pattern and md check; Q64E what is wrong (empty: all ok)
q64end() { local b c mm
	stopall; q64spd 1 1000; qgasm; V=$(qgmd r64); q64spd 1000 400000; q64wait; sleep 2
	b=$(q64pat check $V $NS); echo check | sudo tee /sys/block/$V/md/sync_action >/dev/null; sleep 1; q64wait
	c=$(cat /sys/block/$V/md/chunk_size); mm=$(cat /sys/block/$V/md/mismatch_cnt)
	Q64E=""; [ "$c" = 131072 ] && [ "$b" = 0 ] && [ "$mm" = 0 ] || Q64E="chunk=$c,bad=$b,mm=$mm"; }
# a) a second manager: md in the second region or further (at 0x8100 or past it), the manager killed,
# --grow --continue, -S
Q64R=""; Q64OK=0
for q64i in $(seq 1 $Q64A); do
	q64mk || { Q64R="$Q64R $q64i:no-volume"; continue; }
	for i in $(seq 1 60); do P=$(q64pos $V); [ "${P:-0}" -ge $((0x8100 / 2)) ] && break; sleep 0.5; done
	P=$(( ${P:-0} * 2 )); S=$(cat /sys/block/$V/md/sync_max)
	sudo pkill -KILL -x mdadm; sleep 0.5
	( $M --grow --continue /dev/$(qgmd amd64) >/dev/null 2>&1 & ); sleep 1
	$M -S /dev/$V >/dev/null 2>&1; sleep 1
	L=$((0x$(qgtlog $(qgl 0) 0x100000 | cut -d" " -f2)))
	q64end
	[ $L -le $P ] && [ -z "$Q64E" ] && Q64OK=$((Q64OK + 1)) ||
		Q64R="$Q64R $q64i:md=$(printf 0x%x $P),sync_max=$(printf 0x%x $S),log=$(printf 0x%x $L),$Q64E"
done
check "64a: RAID10 2 x 2 --chunk=128, its manager killed, --grow --continue on the running volume, -S: the AMD log not ahead of md, assembled, done - 128 KiB, the data as written, md check 0 ($Q64OK of $Q64A;$Q64R)" "[ $Q64OK = $Q64A ]"
# b) md interrupted unfrozen while the manager waits: "idle" 4 times, 10 to 90 ms apart, then -S
Q64R=""; Q64OK=0
for q64i in $(seq 1 $Q64B); do
	q64mk || { Q64R="$Q64R $q64i:no-volume"; continue; }
	sleep $((3 + RANDOM % 5))
	for i in 1 2 3 4; do echo idle | sudo tee /sys/block/$V/md/sync_action >/dev/null 2>&1; sleep 0.0$((RANDOM % 9 + 1)); done
	sleep 0.5; $M -S /dev/$V >/dev/null 2>&1; sleep 1
	L=$(qgtlog $(qgl 0) 0x100000 | cut -d" " -f2)
	q64end
	[ -z "$Q64E" ] && Q64OK=$((Q64OK + 1)) || Q64R="$Q64R $q64i:log=0x$L,$Q64E"
done
check "64b: RAID10 2 x 2 --chunk=128, md interrupted unfrozen (sync_action idle) 4 times, then -S: assembled, done - 128 KiB, the data as written, md check 0 ($Q64OK of $Q64B;$Q64R)" "[ $Q64OK = $Q64B ]"
# c) -S midway: mdmon does not run the volume again (no "active with" after -S), the data intact
Q64R=""; Q64OK=0; Q64RS=0
for q64i in $(seq 1 $Q64C); do
	q64mk || { Q64R="$Q64R $q64i:no-volume"; continue; }
	# a mark in the kernel log: its ring is full by now, counting lines would not do
	sleep $((3 + RANDOM % 8)); K="q64c $q64i $RANDOM"; echo "$K" | sudo tee /dev/kmsg >/dev/null
	$M -S /dev/$V >/dev/null 2>&1; sleep 1
	RS=$(sudo dmesg | sed -n "/$K\$/,\$p" | grep -c "raid10:$V: active with")
	q64end
	[ $RS = 0 ] || Q64RS=$((Q64RS + 1))
	[ $RS = 0 ] && [ -z "$Q64E" ] && Q64OK=$((Q64OK + 1)) || Q64R="$Q64R $q64i:restarted=$RS,$Q64E"
done
check "64c: RAID10 2 x 2 --chunk=128 stopped (-S) midway: mdmon does not run it again ($Q64RS of $Q64C run again), assembled, done, the data as written ($Q64OK of $Q64C;$Q64R)" "[ $Q64OK = $Q64C ]"
qgdrop q64
fi
# --- end of stage 64 ---

# --- stage 65: a second migration of a volume whose data the first one moved to AllocatedSpace + 0x800 already:
# in place, the first stripes through AMD's log of the data (AllocatedSpace + 0x600; rcblob RC_MoveDataNextRegion
# @0018a770, LogDataRange - RC_InitTransformStruct @00192fd0), then dynamic regions
# (RC_TransformUpdateNextDynamicRegionFromBeginning @0014e070). Fixture 2026-11-19-rcraid-second-migration (rcraid
# 9.3.3-00302 in emulation): a RAID0 4 x 1 and a RAID5 1 x 4 at + 0x800 (after a first migration by rcadm -T), in
# every sector the pair (tag, sector number of the volume).
# 65a - rcraid's snapshot: RAID0 4 -> 5 midway through its log of the data (the stripe at 0x280, the phase before the
# log of the data - flags 0x712141): the assembly takes the first stripes on to LogDataRange (0xa00) itself, md goes
# on, mdmon ends the migration as AMD does (the LD = rcraid's final one, q20m-done), the data intact.
# 65b - rcraid's snapshot: RAID5 4 -> 5, a region of 0x600 a stripe at a time, the stripe at 0x200 in the log of the
# data (0x512141): the same, md check 0.
# 65c - mdadm --grow of that RAID0 4 -> 5: the start packet as rcadm -T -r0 writes it (0x112141 in both LDs, protect
# 0x7800, Flags 0x20010), the log a stripe at a time with its phase; stopped in the first stripes - the assembly
# finishes them, the data intact.
# 65d - the same for the RAID5 (a region of 0x600 a stripe at a time). 65e - --chunk of such a volume: the data go
# back up, from the end (stage 66).
# 1.5.1: volumes midway through the first stripes are not assembled, such a --grow is refused.
if want 65; then
cd "$MDADM_DIR"
stopall
Q65D=$FIXT/2026-11-19-rcraid-second-migration
R0ID=83b23ee6ee43; R5ID=d13cd6296c75
# q65over <snapshot>: the snapshot's metadata (LBA 0...0x6000) and parts of its extents [A, A + 0x4000) over the
# loop devices of the set q65
q65over() { local n f a
	for n in 0 1 2 3 4; do xz -dc $Q65D/$1-sata$n-lba0-6000.img.xz | sudo dd of=$(qgl $n) bs=512 oflag=direct conv=notrunc status=none
		for f in $Q65D/$1-sata$n-lba0x*-4000.img.xz; do [ -e "$f" ] || continue; a=${f##*-lba}; a=${a%-4000.img.xz}
			xz -dc $f | sudo dd of=$(qgl $n) bs=512 seek=$((a)) oflag=direct conv=notrunc status=none; done; done; }
# q65pat <dev> <MiB> <tag>: the pattern; q65chk <dev> <MiB> <tag>: "ok" or the first sector that differs
q65pat() { python3 -c '
import sys, struct
o = sys.stdout.buffer
for s in range(int(sys.argv[1]) * 2048): o.write(struct.pack("<QQ", int(sys.argv[2]), s) * 32)' $2 $3 |
	sudo dd of=$1 bs=1M oflag=direct conv=notrunc status=none; }
q65chk() { sudo dd if=$1 bs=1M count=$2 iflag=direct status=none | python3 -c '
import sys, struct
t = int(sys.argv[1]); b = sys.stdin.buffer.read()
bad = [s for s in range(len(b) // 512) if b[s * 512:s * 512 + 512] != struct.pack("<QQ", t, s) * 32][:1]
print("ok" if not bad and len(b) else "bad 0x%x" % (bad[0] if bad else 0))' $3; }
q65mm() { echo check | sudo tee /sys/block/$1/md/sync_action >/dev/null; sleep 1
	while ! grep -q idle /sys/block/$1/md/sync_action; do sleep 1; done; cat /sys/block/$1/md/mismatch_cnt; }
q65wait() { for i in $(seq 1 300); do grep -qE 'reshape|resync|recover' /proc/mdstat || { sleep 3; grep -qE 'reshape|resync|recover' /proc/mdstat || return 0; }; sleep 1; done; return 1; }
# q65base: the set as after rcraid's first migrations (q20m-first), the pattern in both volumes, all stopped
q65base() { qgfix q65 $Q65D q20m-first; qgasm; q65pat /dev/$(qgmd r0) 256 7; q65pat /dev/$(qgmd r5) 256 9; stopall; }
xz -dc $Q65D/q20m-done-sata0-lba0-6000.img.xz > $WQ/q65done.img
# 65a
q65base; q65over q20m-r0s01
check "65a: rcraid's RAID0 4 -> 5 stopped in its log of the data (the stripe at 0x280, 0x712141): -E says the migration" "$M -E $(qgl 0) 2>/dev/null | grep -qE 'Migration : RAID10N 4 x 1, 384 MiB -> RAID10N 5 x 1, 385 MiB; [0-9]+% done'"
OUT=$(for l in $QGL; do $M -I $l 2>&1; done); sleep 2; V=$(qgmd r0)
check "65a: assembled: the first stripes moved as the AMD driver moves them, md (raid4) goes on from LogDataRange 0xa00" "echo \"\$OUT\" | grep -q 'subarray-0: its first stripes moved through the AMD log of the data, as the AMD driver does: md goes on from 2560' && [ -n '$V' ]"
q65wait; sleep 3; V=$(qgmd r0)
check "65a: done: md raid0 of 5, the data as written; the LD as rcraid ends it (q20m-done), the log cleared" "[ \$(cat /sys/block/$V/md/level) = raid0 ] && [ \$(cat /sys/block/$V/md/raid_disks) = 5 ] && [ \"\$(q65chk /dev/$V 256 7)\" = ok ] && [ \"\$(qgld $WQ/q65/d0.img $R0ID)\" = \"\$(qgld $WQ/q65done.img $R0ID)\" ] && [ \"\$(qgtlog $(qgl 0) 0x100000)\" = '0 0 0 0 0 0 0' ]"
stopall
# 65b
q65base; q65over q20m-r5s02
OUT=$(for l in $QGL; do $M -I $l 2>&1; done); sleep 2
check "65b: rcraid's RAID5 4 -> 5 stopped in its log of the data (region 0x600 a stripe at a time, 0x200 logged, 0x512141): assembled, the stripe from the log of the data, the next through it, md goes on from 0x600" "echo \"\$OUT\" | grep -q 'subarray-1: its first stripes moved through the AMD log of the data, as the AMD driver does: md goes on from 1536'"
q65wait; sleep 3; V=$(qgmd r5)
check "65b: done: md raid5 of 5, the data as written, md check 0; the LD as rcraid ends it" "[ \$(cat /sys/block/$V/md/raid_disks) = 5 ] && [ \"\$(q65chk /dev/$V 256 9)\" = ok ] && [ \$(q65mm $V) = 0 ] && [ \"\$(qgld $WQ/q65/d0.img $R5ID)\" = \"\$(qgld $WQ/q65done.img $R5ID)\" ]"
stopall
# 65c, 65d: mdadm --grow, md slowed, stopped in the first stripes
q65base; qgasm; C=$(cont1); $M /dev/$C --remove $(qgl 4) >/dev/null 2>&1; sleep 1; $M /dev/$C --add $(qgl 4) >/dev/null 2>&1; sleep 1
for F in c:r0:0:7:100000:a00:280 d:r5:1:9:145000:600:200; do
	K=${F%%:*}; F=${F#*:}; N=${F%%:*}; F=${F#*:}; SA=${F%%:*}; F=${F#*:}; TG=${F%%:*}; F=${F#*:}; AL=0x${F%%:*}; F=${F#*:}; LR=$((0x${F%%:*})); IO=${F#*:}
	V=$(qgmd $N); [ $N = r5 ] && $M --readwrite /dev/$V >/dev/null 2>&1
	G0=$(qgring $WQ/q65/d0.img | tail -1); ID=$([ $N = r0 ] && echo $R0ID || echo $R5ID)
	echo 4 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null; echo 1 | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null
	$M --grow /dev/$V --raid-devices=5 > $WQ/q65/grow.out 2>&1; sleep 4
	S1=$(qgld $WQ/q65/d0.img $ID $((G0 + 1)) | head -1); T=$(qgtlog $(qgl 0) $AL)
	check "65$K: $N --raid-devices=5: in place (the data stay at + 0x800); start packet as rcadm -T (0x112141, Flags 0x20010, Link 1); the log a stripe at a time with its phase of the log of the data" "grep -q '4 -> 5 disks; mdmon records it as an AMD migration, md reshapes it, the data where they are' $WQ/q65/grow.out && echo \"\$S1\" | grep -q 'tt=5354 lo=5354 ts=0 .* tf=112141 psz=[0-9a-f]* fl=20010 lk=1' && echo \"\$T\" | grep -qE '^5354 [0-9a-f]+ 1 $IO [3-7]12141 [0-9a-f]+ '"
	$M -S /dev/$V >/dev/null 2>&1; sleep 1; T=$(qgtlog $(qgl 0) $AL)
	check "65$K: stopped in the first stripes (the log at 0x$(echo $T | cut -d' ' -f2), below 0x$(printf %x $LR))" "[ \"\$(echo \$T | cut -d' ' -f1)\" = 5354 ] && [ \$((0x\$(echo \$T | cut -d' ' -f2))) -lt $LR ]"
	echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null; echo 1000 | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null
	stopall; OUT=$(for l in $QGL; do $M -I $l 2>&1; done); sleep 2; q65wait; sleep 3; V=$(qgmd $N)
	check "65$K: assembled again: the first stripes moved through the log of the data, md goes on, done - $N of 5, the data as written" "echo \"\$OUT\" | grep -q 'subarray-$SA: its first stripes moved through the AMD log of the data' && [ \$(cat /sys/block/$V/md/raid_disks) = 5 ] && [ \"\$(q65chk /dev/$V 256 $TG)\" = ok ] && [ \$(qgld $WQ/q65/d0.img $ID | wc -l) = 1 ]"
done
V=$(qgmd r5)
check "65e: --chunk of a volume a migration moved already: the data go back up, from the end (stage 66) - md reshapes it backwards to the end, the data as written" "$M --grow /dev/$V --chunk=128 > $WQ/q65e.out 2>&1; grep -q 'the data moving 9 MiB up on each disk, from the end' $WQ/q65e.out && q65wait && sleep 3 && [ \$(cat /sys/block/$V/md/chunk_size) = 131072 ] && [ \"\$(q65chk /dev/$V 256 9)\" = ok ]"
qgdrop q65; rm -f $WQ/q65done.img
fi
# --- end of stage 65 ---

# --- stage 66: the chunk change of a volume whose data a first migration moved to AllocatedSpace + 0x800 already:
# AMD carries it out backwards - from the end, the data up to + 0x5000 (rcblob RC_SetupTransformParams @00190cd0:
# 0x20222 | 0x2000; regions RC_TransformUpdateNextRegionFromEnd @0014d910), md as reshape_backwards. Fixture
# 2026-11-20-rcraid-chunk-backwards (rcraid 9.3.3-00302 in emulation): a RAID0 4 x 1 and a RAID5 1 x 4 of 64K at
# + 0x800 after a first migration by rcadm -T (q20m-first of stage 65), a RAID10 2 x 2 of 64K at + 0x800 after a
# chunk change of ours; in every sector the pair (tag, sector number of the volume): 7 RAID0, 9 RAID5, 5 RAID10.
# 66a - mdadm --grow <RAID5> --chunk=128: the start packet as the AMD driver lays such a migration out
# (0x12222/0x22222, ProtectStart = capacity - ProtectSize, 0xd800), the log of a region from the end, md backwards,
# held; stopped (-S), assembled - md from the log's mark; the end - "100 %" with ProtectStart 0, the final packet as
# rcraid's (q21c-xs2). Refused: more disks and another chunk at once; members grown in place since.
# 66b - rcraid's snapshot midway through such a migration of the RAID5 (the region [0x28800, 0x36000) in work): md
# from 0x36000, the final packet = rcraid's.
# 66c - the same for the RAID10 (our --chunk=128, regions of 0x8000); 66d - rcraid's snapshot midway through the
# RAID10 (the region [0x18000, 0x20000)).
# 1.5.1: such a --chunk is refused, volumes midway through it are not assembled as a backward migration.
# shared with stage 69
Q66D=$FIXT/2026-11-20-rcraid-chunk-backwards
R5ID=d13cd6296c75; T10ID=d7b56f6f0525
# q66fix <snapshot>: five disks of 8 GiB - the snapshot's metadata (LBA 0...0x6000) and the volumes' extents
# [0x100000, + 0x9a000)
q66fix() { local n f; qgdrop q66; mkdir -p $WQ/q66; QGL=""
	for n in 0 1 2 3 4; do f=$WQ/q66/d$n.img; truncate -s 8G $f
		xz -dc $Q66D/$1-sata$n-lba0-6000.img.xz | dd of=$f conv=notrunc status=none
		f2=$Q66D/$1-sata$n-lba0x100000-9a000.img.xz
		[ -e $f2 ] && xz -dc $f2 | dd of=$f bs=512 seek=$((0x100000)) conv=notrunc status=none
		QGL="$QGL $(sudo losetup -f --show $f)"; done; }
q66chk() { sudo dd if=$1 bs=1M count=$2 iflag=direct status=none | python3 -c '
import sys, struct
t = int(sys.argv[1]); b = sys.stdin.buffer.read()
bad = [s for s in range(len(b) // 512) if b[s * 512:s * 512 + 512] != struct.pack("<QQ", t, s) * 32][:1]
print("ok" if not bad and len(b) else "bad 0x%x" % (bad[0] if bad else 0))' $3; }
q66mm() { echo check | sudo tee /sys/block/$1/md/sync_action >/dev/null; sleep 1
	while ! grep -q idle /sys/block/$1/md/sync_action; do sleep 1; done; cat /sys/block/$1/md/mismatch_cnt; }
q66wait() { for i in $(seq 1 300); do grep -qE 'reshape|resync|recover' /proc/mdstat || { sleep 3; grep -qE 'reshape|resync|recover' /proc/mdstat || return 0; }; sleep 1; done; return 1; }
q66md() { cat /sys/block/$1/md/$2; }
q66offs() { cat /sys/block/$1/md/dev-*/$2 | sort -u | tr '\n' ' '; }
# q66final <snapshot of rcraid's end> <ID>: the LD of the live packet of that snapshot (via $WQ/q66fin.img)
q66final() { xz -dc $Q66D/$1-sata0-lba0-6000.img.xz > $WQ/q66fin.img; qgld $WQ/q66fin.img $2; }
q66slow() { echo 1 | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null; echo $1 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null; }
q66fast() { echo 1000 | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null; echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null; }
if want 66; then
cd "$MDADM_DIR"
stopall
# 66a
q66fix q21c-pat; qgasm; V=$(qgmd r5); $M --readwrite /dev/$V >/dev/null 2>&1
check "66a: RAID5 64K at + 0x800: more disks and another chunk at once refused (AMD would go in place, regions md cannot keep to)" "$M --grow /dev/$V --chunk=128 --raid-devices=5 --force 2>&1 | grep -q 'in regions md cannot keep to' && [ \$(q66md $V chunk_size) = 65536 ] && [ \$(qgld $WQ/q66/d0.img $R5ID | wc -l) = 1 ]"
G0=$(qgring $WQ/q66/d0.img | tail -1); q66slow 300
$M --grow /dev/$V --chunk=128 > $WQ/q66/grow.out 2>&1; sleep 4
S1=$(qgld $WQ/q66/d0.img $R5ID); T=$(qgtlog $(qgl 0) 0x145000)
check "66a: --chunk=128: backwards (the data 0x4800 up: 0x145800 -> 0x14a000, 0x135800 -> 0x13a000 on sata3), md held, blocked" "grep -q 'chunk 64 -> 128 KiB; mdmon records it as an AMD migration, md reshapes it, the data moving 9 MiB up on each disk, from the end' $WQ/q66/grow.out && [ \$(q66md $V reshape_direction) = backwards ] && [ \"\$(q66offs $V new_offset)\" = '$((0x13a000)) $((0x14a000)) ' ] && [ \$(q66md $V sync_max) != max ] && grep -q 'external:-' /sys/block/$V/md/metadata_version"
check "66a: start packet as the AMD driver lays such a migration out: 0x12222 at +0x800, ProtectStart = capacity - 0xd800 (0x73800), Flags 0x20010, Link 1; the LD made 0x22222, chunk 128 KiB, data at + 0x5000" "echo \"\$S1\" | head -1 | grep -q 'tt=5354 lo=5354 ts=0 cap=81000 ps=73800 .* fs=1x4 tf=12222 psz=d800 fl=20010 lk=1' && echo \"\$S1\" | tail -1 | grep -qE 'tt=0 lo=5354 ts=0 cap=81000 ps=0 .* tf=22222 psz=0 fl=0 lk=0 .*e0=[0-9a-f]+:145000[+]30000:14a000[+]2b000'"
check "66a: the log of the region from the end: ProtectStart = IOStart at a region (ProtectSize 0xd800 from 0, the last 0x7800 up to 0x81000), I/O 0x600, the source's flags" "echo \"\$T\" | grep -qE '^5354 (79800 1 600 12222 7800 14|[0-9a-f]+ 1 600 12222 d800 24)$' && [ \$(( 0x\$(echo \$T | cut -d' ' -f2) % 0xd800 )) = 0 ]"
sleep 15; $M -S /dev/$V >/dev/null 2>&1; sleep 1; T=$(qgtlog $(qgl 0) 0x145000); PS=$((0x$(echo $T | cut -d' ' -f2))); PZ=$((0x$(echo $T | cut -d' ' -f6)))
check "66a: stopped midway: the log at a region below the end ($(printf %x $PS)); -E says the migration" "[ $PS -lt $((0x79800)) ] && [ \$(( $PS % 0xd800 )) = 0 ] && $M -E $(qgl 0) | grep -q 'Migration : RAID50 1 x 4, 258 MiB, 64 KiB chunk -> RAID50 1 x 4, 258 MiB, 128 KiB chunk; [0-9]*% done'"
stopall; qgasm; V=$(qgmd r5); RS=$(q66md $V reshape_position)
check "66a: assembled again: md goes on backwards from the log's region end ($(printf %x $((PS + PZ)))), the new offsets again, held" "[ \"\$RS\" -le $((PS + PZ)) ] && [ \"\$RS\" -ge $PS ] && [ \$(q66md $V reshape_direction) = backwards ] && [ \"\$(q66offs $V new_offset)\" = '$((0x13a000)) $((0x14a000)) ' ] && [ \$(q66md $V sync_max) != max ]"
q66fast; q66wait; sleep 3; V=$(qgmd r5); G1=$(qgring $WQ/q66/d0.img | tail -1)
P100=$(qgld $WQ/q66/d0.img $R5ID $((G1 - 1)))
check "66a: \"100 %\" packet backwards: both LDs at ProtectStart 0 (rcraid's own, q21c-xs2 ring)" "echo \"\$P100\" | head -1 | grep -q 'tt=5354 lo=5354 ts=a1a6 cap=81000 ps=0 .* fl=84 lk=1 pct=186a0' && echo \"\$P100\" | tail -1 | grep -q 'tt=5354 lo=5354 ts=a1a1 cap=81000 ps=0 .* pct=186a0'"
check "66a: done: md raid5 of 128 KiB at + 0x5000, the data as written, md check 0; the LD as rcraid ends it (q21c-xs2), the log cleared" "[ \$(q66md $V chunk_size) = 131072 ] && [ \"\$(q66offs $V offset)\" = '$((0x13a000)) $((0x14a000)) ' ] && [ \"\$(q66chk /dev/$V 256 9)\" = ok ] && [ \"\$(q66chk /dev/$(qgmd r0) 256 7)\" = ok ] && [ \$(q66mm $V) = 0 ] && [ \"\$(qgld $WQ/q66/d0.img $R5ID | sed 's/gen=[0-9a-f]* //')\" = \"\$(q66final q21c-xs2 $R5ID | sed 's/gen=[0-9a-f]* //')\" ] && [ \"\$(qgtlog $(qgl 0) 0x145000)\" = '0 0 0 0 0 0 0' ]"
# the members grown in place since (--size): no room above for the data
stopall; q66fix q21c-pat; qgasm; V=$(qgmd r5); $M --readwrite /dev/$V >/dev/null 2>&1; q66fast
$M --grow /dev/$V --size=98304 >/dev/null 2>&1; sleep 2; q66wait; sleep 2
check "66a: members grown in place since the data went down: another chunk refused (no room 9 MiB up)" "$M --grow /dev/$V --chunk=128 2>&1 | grep -q 'past the members. extents: they grew in place since' && [ \$(q66md $V chunk_size) = 65536 ]"
# 66b
stopall; q66fix q21c-xs1
check "66b: rcraid's RAID5 chunk change stopped midway (the region [0x28800, 0x36000) in work, 0x12222): -E says the migration" "$M -E $(qgl 0) 2>/dev/null | grep -q 'Migration : RAID50 1 x 4, 258 MiB, 64 KiB chunk -> RAID50 1 x 4, 258 MiB, 128 KiB chunk; [0-9]*% done'"
q66slow 300; qgasm; V=$(qgmd r5); RS=$(q66md $V reshape_position)
check "66b: assembled: md goes on backwards from 0x36000, the data 0x4800 up, held" "[ \"\$RS\" -le $((0x36000)) ] && [ \"\$RS\" -ge $((0x28800)) ] && [ \$(q66md $V reshape_direction) = backwards ] && [ \$(q66md $V sync_max) != max ]"
q66fast; q66wait; sleep 3; V=$(qgmd r5)
check "66b: done: md raid5 128 KiB, the data as written, md check 0; the LD as rcraid ends it (q21c-xs2)" "[ \$(q66md $V chunk_size) = 131072 ] && [ \"\$(q66chk /dev/$V 256 9)\" = ok ] && [ \$(q66mm $V) = 0 ] && [ \"\$(qgld $WQ/q66/d0.img $R5ID)\" = \"\$(q66final q21c-xs2 $R5ID)\" ]"
# 66c
stopall; q66fix q21c-r10b; qgasm; V=$(qgmd t10); $M --readwrite /dev/$V >/dev/null 2>&1; q66slow 300
$M --grow /dev/$V --chunk=128 > $WQ/q66/grow.out 2>&1; sleep 4; T=$(qgtlog $(qgl 0) 0x175000)
check "66c: RAID10 2 x 2 64K at + 0x800 --chunk=128: backwards, held; the log of the last region (0x38000, 0x8000, I/O 0x400)" "grep -q 'the data moving 9 MiB up on each disk, from the end' $WQ/q66/grow.out && [ \$(q66md $V reshape_direction) = backwards ] && [ \$(q66md $V sync_max) != max ] && echo \"\$T\" | grep -qE '^5354 [0-9a-f]+ 1 400 12222 8000 20$'"
sleep 10; $M -S /dev/$V >/dev/null 2>&1; sleep 1; stopall; qgasm; V=$(qgmd t10)
check "66c: stopped, assembled again: backwards from the log, held" "[ \$(q66md $V reshape_direction) = backwards ] && [ \$(q66md $V sync_max) != max ]"
q66fast; q66wait; sleep 3; V=$(qgmd t10)
check "66c: done: md raid10 of 128 KiB, the data as written, md check 0; the LD as rcraid ends it (q21c-r10s2rc but for its generation)" "[ \$(q66md $V chunk_size) = 131072 ] && [ \"\$(q66chk /dev/$V 120 5)\" = ok ] && [ \$(q66mm $V) = 0 ] && [ \"\$(qgld $WQ/q66/d0.img $T10ID | sed 's/gen=[0-9a-f]* //')\" = \"\$(q66final q21c-r10s2rc $T10ID | sed 's/gen=[0-9a-f]* //')\" ]"
# 66d
stopall; q66fix q21c-r10xs1; q66slow 300; qgasm; V=$(qgmd t10); RS=$(q66md $V reshape_position)
check "66d: rcraid's RAID10 256 -> 128 KiB stopped midway (region [0x18000, 0x20000)): assembled, md goes on backwards from 0x20000" "[ \"\$RS\" -le $((0x20000)) ] && [ \"\$RS\" -ge $((0x18000)) ] && [ \$(q66md $V reshape_direction) = backwards ]"
q66fast; q66wait; sleep 3; V=$(qgmd t10)
check "66d: done: the data as written, md check 0; the LD as rcraid ends it (q21c-r10s2rc)" "[ \$(q66md $V chunk_size) = 131072 ] && [ \"\$(q66chk /dev/$V 120 5)\" = ok ] && [ \$(q66mm $V) = 0 ] && [ \"\$(qgld $WQ/q66/d0.img $T10ID)\" = \"\$(q66final q21c-r10s2rc $T10ID)\" ]"
q66fast; qgdrop q66; rm -f $WQ/q66fin.img
fi
# --- end of stage 66 ---

# --- stage 67: md held (sync_max) midway through a stripe of the old layout holds a read of that stripe until it
# gets there (raid5.c stripe_ahead_of_reshape), and the write of the suspend_lo/hi window (mddev_suspend) waits for
# that read: mdadm waits for md, md for mdadm, for ever. It happens with a migration in place (the data at + 0x800
# already): AMD's regions of a RAID0 are in stripes of the target (rcblob RC_TransformDynamicProtectSize @0018c310),
# the marks midway through stripes of the source. Fixed: the window moves only where stripes of both layouts end (a
# region that goes past the window ends on it), and the assembly takes the migration on to such a boundary itself,
# before md runs (recover_backup_amd). Checked: a reader (4 KiB, O_DIRECT) again and again where md will stop
# (sync_max), md slowed; a hang - mdadm 10 s in mddev_suspend, md not moving - is cleared (kill -9, sync_max max).
# 67a - q8m-e1cmid (rcraid: RAID0 3 -> 4, a second growth, the mark at 0x29c00 - 0x80 into a stripe of the source of
# 0x180 sectors).
# 67b - q20m-r0s01 (rcraid: RAID0 4 -> 5 in its first stripes; past them AMD's regions end midway through stripes of
# the source, 0x2580).
# 67c, 67d - our --grow of the RAID0 / RAID5 4 -> 5 of that volume, mdadm killed (kill -9) with the log midway
# through a stripe of the old layout.
# 1.5.1: 67a hangs (cleared), 6 FAIL / 1 ok in all; 67b, 67c, 67d - not assembled, --grow refused.
if want 67; then
cd "$MDADM_DIR"
stopall
Q54D=$FIXT/2026-11-15-rcraid-migrations; Q65D=$FIXT/2026-11-19-rcraid-second-migration
R0ID=83b23ee6ee43
# q67pids: the mdadm processes of this tree that run a reshape (-I: assembly with Grow_continue; --grow)
q67pids() { local p; for p in $(pgrep -f 'mdadm (-I|--grow)'); do [ "$(sudo readlink /proc/$p/exe)" = "$PWD/mdadm" ] && echo $p; done; }
# q67slow <KiB/s> <level>: the md of the volume (that level, with disk d0) slow as soon as it has sync_speed_max
# (in the background)
q67slow() { ( local i m s; for i in $(seq 1 1500); do for m in $(ls /sys/block | grep ^md); do s=/sys/block/$m/md/sync_speed_max
	[ -e $s ] && [ "$(cat /sys/block/$m/md/level 2>/dev/null)" = $2 ] && ls /sys/block/$m/slaves | grep -qx $(basename $(qgl 0)) || continue
	echo $1 | sudo tee $s >/dev/null 2>&1 && echo 1 | sudo tee /sys/block/$m/md/sync_speed_min >/dev/null 2>&1 &&
		grep -q "^$1 (local)" $s && exit 0; done; sleep 0.01; done ) & }
# q67watch <md> <s>: a reader where md will stop; "ok", or "deadlock at ..." (cleared: mdadm kill -9, sync_max max)
q67watch() { local md=$1 t=$(( $(date +%s) + $2 )) S=/sys/block/$1/md nd last="" same=0 p sus r=ok pid rp
	[ -n "$md" ] && [ -e $S/sync_max ] || { echo "no md"; return; }
	nd=$(( $(cut -d' ' -f1 $S/raid_disks) - 1 ))
	sudo bash -c "end=\$(( \$(date +%s) + $2 )); while [ \$(date +%s) -lt \$end ]; do h=\$(cat $S/sync_max 2>/dev/null)
		case \$h in [0-9]*) ;; *) break ;; esac
		dd if=/dev/$md of=/dev/null bs=4k count=1 skip=\$(( h * $nd / 8 )) iflag=direct status=none 2>/dev/null; done" &
	rp=$!
	while [ $(date +%s) -lt $t ] && [ -e /proc/$rp ]; do sleep 2; p=$(cat $S/sync_completed 2>/dev/null)
		sus=""; for pid in $(q67pids); do sudo grep -q mddev_suspend /proc/$pid/stack 2>/dev/null && sus=1; done
		[ -n "$sus" ] && [ "$p" = "$last" ] && same=$((same + 1)) || same=0; last=$p
		[ $same -ge 5 ] && { r="deadlock at ${p%% *} of $nd"; break; }; done
	[ "$r" = ok ] || { for pid in $(q67pids); do sudo kill -9 $pid; done; echo max | sudo tee $S/sync_max >/dev/null; }
	sudo kill $rp 2>/dev/null; wait $rp 2>/dev/null; echo "$r"; }
q67wait() { for i in $(seq 1 600); do grep -qE 'reshape|resync|recover|check' /proc/mdstat || { sleep 3; grep -qE 'reshape|resync|recover|check' /proc/mdstat || return 0; }; sleep 1; done; return 1; }
# the pattern (as in stage 65): in every sector 32 x (tag, sector number of the volume)
q67pat() { python3 -c '
import sys, struct
o = sys.stdout.buffer
for s in range(int(sys.argv[1]) * 2048): o.write(struct.pack("<QQ", int(sys.argv[2]), s) * 32)' $2 $3 |
	sudo dd of=$1 bs=1M oflag=direct conv=notrunc status=none; }
q67chk() { sudo dd if=$1 bs=1M count=$2 iflag=direct status=none | python3 -c '
import sys, struct
t = int(sys.argv[1]); b = sys.stdin.buffer.read()
bad = [s for s in range(len(b) // 512) if b[s * 512:s * 512 + 512] != struct.pack("<QQ", t, s) * 32][:1]
print("ok" if not bad and len(b) else "bad 0x%x" % (bad[0] if bad else 0))' $3; }
q67over() { local n f a
	for n in 0 1 2 3 4; do xz -dc $Q65D/$1-sata$n-lba0-6000.img.xz | sudo dd of=$(qgl $n) bs=512 oflag=direct conv=notrunc status=none
		for f in $Q65D/$1-sata$n-lba0x*-4000.img.xz; do [ -e "$f" ] || continue; a=${f##*-lba}; a=${a%-4000.img.xz}
			xz -dc $f | sudo dd of=$(qgl $n) bs=512 seek=$((a)) oflag=direct conv=notrunc status=none; done; done; }
q67base() { qgfix q67 $Q65D q20m-first; qgasm; q67pat /dev/$(qgmd r0) 256 7; q67pat /dev/$(qgmd r5) 256 9; stopall; }
# the mark of the log on <loop> at <LBA> (as amd_tlog_mark: IOStart of a dynamic region midway); "-": no log
q67mark() { sudo dd if=$1 bs=512 skip=$(($2)) count=1 iflag=direct status=none | python3 -c '
import sys, struct
b = sys.stdin.buffer.read()
if struct.unpack_from("<I", b, 0x18)[0] != 0x5354: print("-"); sys.exit()
ps, io = struct.unpack_from("<QQ", b, 0x1c); fl, psz = struct.unpack_from("<II", b, 0x30)
print(io if fl & 0x100 and ps < io < ps + psz else ps)'; }
# 67a
qgfix q67 $Q54D q8m-e1cmid
q67slow 2000 raid4; OUT=$(for l in $QGL; do $M -I $l 2>&1; done); wait; V=$(mdof raid4 | head -1)
check "67a: q8m-e1cmid (rcraid's RAID0 3 -> 4 in place, log at 0x29c00 - 0x80 into a stripe of the old layout): assembled, the stripes up to 0x2a000 moved first, md goes on from there" "echo \"\$OUT\" | grep -q 'subarray-0: stripes from 171008 moved as the AMD driver moves them: md goes on from 172032, where stripes of both layouts end' && [ \$(cat /sys/block/$V/md/reshape_position) -ge 172032 ]"
R=$(q67watch "$V" 60)
check "67a: a reader again and again where md stops (60 s, md slowed): md goes on, mdadm never waits in mddev_suspend for it ($R)" "[ '$R' = ok ]"
qgdrop q67
# 67b
xz -dc $Q65D/q20m-done-sata0-lba0-6000.img.xz > $WQ/q67done.img
q67base; q67over q20m-r0s01
q67slow 2000 raid4; OUT=$(for l in $QGL; do $M -I $l 2>&1; done); wait; V=$(qgmd r0)
R=$(q67watch "$V" 60)
check "67b: q20m-r0s01 (rcraid's RAID0 4 -> 5 in its first stripes): md from 0xa00, past regions that end across old stripes (0x2580), a reader where md stops (60 s): no wait for ever ($R)" "echo \"\$OUT\" | grep -q 'md goes on from 2560' && [ '$R' = ok ]"
[ -e /sys/block/$V/md/sync_speed_max ] && echo system | sudo tee /sys/block/$V/md/sync_speed_max /sys/block/$V/md/sync_speed_min >/dev/null
q67wait; sleep 3; V=$(qgmd r0)
check "67b: done: md raid0 of 5, the data as written; the LD as rcraid ends it (q20m-done)" "[ \$(cat /sys/block/$V/md/level) = raid0 ] && [ \$(cat /sys/block/$V/md/raid_disks) = 5 ] && [ \"\$(q67chk /dev/$V 256 7)\" = ok ] && [ \"\$(qgld $WQ/q67/d0.img $R0ID)\" = \"\$(qgld $WQ/q67done.img $R0ID)\" ]"
stopall; rm -f $WQ/q67done.img
# 67c, 67d: our --grow, md very slow; killed as soon as the log is past LogDataRange midway through a stripe of
# the old layout
for F in c:r0:raid4:7:100000:200:a00 d:r5:raid5:9:145000:180:600; do
	K=${F%%:*}; F=${F#*:}; N=${F%%:*}; F=${F#*:}; LV=${F%%:*}; F=${F#*:}; TG=${F%%:*}; F=${F#*:}
	AL=0x${F%%:*}; F=${F#*:}; SS=$((0x${F%%:*})); LDR=$((0x${F#*:}))
	q67base; qgasm; C=$(cont1); $M /dev/$C --remove $(qgl 4) >/dev/null 2>&1; sleep 1; $M /dev/$C --add $(qgl 4) >/dev/null 2>&1; sleep 1
	V=$(qgmd $N); [ $N = r5 ] && $M --readwrite /dev/$V >/dev/null 2>&1
	q67slow 100 $LV; $M --grow /dev/$V --raid-devices=5 > $WQ/q67/grow.out 2>&1 &
	G=""; TE=$(( $(date +%s) + 600 )); TS=$(( $(date +%s) + 15 ))
	# at such a mark mdadm is stopped (SIGSTOP) and the mark read again: the log may have moved on
	while [ $(date +%s) -lt $TE ]; do m=$(q67mark $(qgl 0) $AL)
		if [ "$m" != - ] && [ $m -ge $LDR ] && [ $((m % SS)) != 0 ]; then
			P=$(q67pids); [ -n "$P" ] && sudo kill -STOP $P; m=$(q67mark $(qgl 0) $AL)
			[ $m -ge $LDR ] && [ $((m % SS)) != 0 ] && { G=$m; break; }
			[ -n "$P" ] && sudo kill -CONT $P
		fi
		[ $(date +%s) -gt $TS ] && ! grep -q reshape /sys/block/$V/md/sync_action 2>/dev/null && break
		sleep 0.01; done
	P=$(q67pids); [ -n "$P" ] && sudo kill -9 $P
	wait; sleep 2; stopall; OUT=$(for l in $QGL; do $M -I $l 2>&1; done); sleep 2; q67wait; sleep 3; V=$(qgmd $N)
	check "67$K: $N --raid-devices=5, mdadm killed with the log at $G (across a stripe of the old layout, past LogDataRange): assembled, the stripes from there moved up to where stripes of both layouts end, md goes on, done - $N of 5, the data as written" "[ -n '$G' ] && echo \"\$OUT\" | grep -q 'stripes from $G moved as the AMD driver moves them' && [ \$(cat /sys/block/$V/md/raid_disks) = 5 ] && [ \"\$(q67chk /dev/$V 256 $TG)\" = ok ]"
	if [ $N = r5 ]; then echo check | sudo tee /sys/block/$V/md/sync_action >/dev/null; sleep 1; q67wait
		check "67$K: md check of the RAID5 (the stripes moved at assembly with their parity): 0" "[ \$(cat /sys/block/$V/md/mismatch_cnt) = 0 ]"; fi
done
qgdrop q67
fi
# --- end of stage 67 ---

# --- stage 68: chunk changes of one volume one after another, without a pause: down (the data to + 0x800,
# forwards), at once up (backwards, to + 0x5000), at once down... - each held (md waits for the manager: sync_max not
# max midway), in its direction and with AMD's log of a region (forwards 0x22211, backwards 0x12222); the data
# intact, md check 0. 68c: through a pipe, mdadm --grow comes back as the migration ends, not as it starts - the
# reshape manager (a child mdadm, Grow.c handle_forking without manage_fork_fds) keeps the output open. What is read
# after such a pipe (md forwards, sync_max max, the log cleared) is the state after the end, not a chunk change left
# unheld.
if want 68; then
cd "$MDADM_DIR"
stopall
Q68=$WQ/q68
q68md() { cat /sys/block/$V/md/$1; }
# q68mk <level>: a container of 4 disks of 1 GiB, a volume 4 x 32 MiB of 64 KiB, the data at + 0x5000; the
# pattern (tag 6)
q68mk() { local n l; stopall; for l in $(sudo losetup -a | grep "$Q68/" | cut -d: -f1); do sudo losetup -d $l; done
	rm -rf $Q68; mkdir -p $Q68; L68=""
	for n in 0 1 2 3; do truncate -s 1G $Q68/d$n.img; L68="$L68 $(sudo losetup -f --show $Q68/d$n.img)"; done
	$M -C /dev/md/c68 -e amd -n 4 $L68 --run >/dev/null 2>&1
	$M -C /dev/md/v68 -e amd -l$1 -n4 -c64 -z 32M $L68 --run >/dev/null 2>&1; sleep 1
	V=$(basename $(readlink -f /dev/md/v68)); q68idle
	python3 -c '
import sys, struct
o = sys.stdout.buffer
for s in range(int(sys.argv[1]) * 2048): o.write(struct.pack("<QQ", 6, s) * 32)' $(( $(sudo blockdev --getsize64 /dev/$V) >> 20 )) |
		sudo dd of=/dev/$V bs=1M oflag=direct status=none; }
q68idle() { local i; for i in $(seq 1 900); do [ "$(q68md sync_action)" = idle ] && [ "$(q68md reshape_position)" = none ] && return 0; sleep 0.1; done; return 1; }
q68chk() { sudo dd if=/dev/$V bs=1M iflag=direct status=none | python3 -c '
import sys, struct
b = sys.stdin.buffer.read()
bad = [s for s in range(len(b) // 512) if b[s * 512:s * 512 + 512] != struct.pack("<QQ", 6, s) * 32][:1]
print("ok" if not bad and len(b) else "bad 0x%x" % (bad[0] if bad else 0))'; }
# the AMD log of member 0 (the first sector of its extent, 0x100000): "type flags"; "0 0": none
q68log() { sudo dd if=$(echo $L68 | cut -d' ' -f1) bs=512 skip=$((0x100000)) count=1 iflag=direct status=none | python3 -c '
import sys, struct
b = sys.stdin.buffer.read(); print("%x %x" % (struct.unpack_from("<I", b, 0x18)[0], struct.unpack_from("<I", b, 0x30)[0]))'; }
# q68run <level> <letter>: 64 -> 128 -> 256 -> 128 -> 64 KiB, each as soon as md ended the one before; md at
# 4 MB/s for the first 1.5 s
q68run() { local c i d r ok=0 n=0 want; q68mk $1; i=0	# after q68mk: stopall changes i
	for c in 128 256 128 64; do i=$((i + 1)); [ $((i % 2)) = 1 ] && want="forwards 5354 22211" || want="backwards 5354 12222"
		echo 4000 | sudo tee /sys/block/$V/md/sync_speed_max >/dev/null
		$M --grow /dev/$V --chunk=$c > $Q68/g$i.out 2>&1; sleep 1.5
		r="$(q68md sync_action) $(q68md reshape_direction) $(q68log) $(q68md sync_max)"
		n=$((n + 1)); [ "${r% *}" = "reshape $want" ] && [ "${r##* }" != max ] && ok=$((ok + 1)) || echo "  68$2 #$i -> ${c}K: $r"
		echo 400000 | sudo tee /sys/block/$V/md/sync_speed_max >/dev/null; q68idle; done
	check "68$2: raid$1 64 -> 128 -> 256 -> 128 -> 64 KiB, each as md ended the one before: down forwards, up backwards, held, the AMD log of a region ($ok of $n)" "[ $ok = $n ]"
	sleep 2; echo check | sudo tee /sys/block/$V/md/sync_action >/dev/null; sleep 1; q68idle
	check "68$2: done: 64 KiB at + 0x5000, the data as written, md check 0" "[ \$(q68md chunk_size) = 65536 ] && [ \"\$(cat /sys/block/$V/md/dev-*/offset | sort -u)\" = $((0x105000)) ] && [ \"\$(q68chk)\" = ok ] && [ \$(q68md mismatch_cnt) = 0 ]"; }
q68run 10 a
q68run 5 b
# 68c: the output through a pipe - mdadm comes back as the migration ends (the manager keeps the output), not
# as it starts
q68mk 10; echo 4000 | sudo tee /sys/block/$V/md/sync_speed_max >/dev/null
Q68T0=$(date +%s); $M --grow /dev/$V --chunk=128 2>&1 | cat > $Q68/pipe.out; Q68T1=$(date +%s)
R="$(q68md sync_action) $(q68md reshape_direction) $(q68md sync_max) $(q68log)"
check "68c: mdadm --grow | cat comes back as the migration ends ($((Q68T1 - Q68T0)) s: md forwards, sync_max max, the log cleared - not a reshape left unheld)" "[ $((Q68T1 - Q68T0)) -ge 8 ] && [ \"$R\" = 'idle forwards max 0 0' ] && grep -q 'the data moving 9 MiB down' $Q68/pipe.out && [ \$(q68md chunk_size) = 131072 ]"
stopall; for l in $(sudo losetup -a | grep "$Q68/" | cut -d: -f1); do sudo losetup -d $l; done; rm -rf $Q68
fi
# --- end of stage 68 ---
# --- stage 69: the chunk change backwards of stage 66 carried on by mdadm --grow --continue - as
# mdadm-grow-continue@, the systemd unit mdadm --grow hands its reshape manager to. Real hardware (1.6 before the
# fix): the unit failed at once - Grow.c verify_reshape_position read sync_max as counted from the start ("not
# properly frozen"), md counts a reshape it runs backwards from the end - and md stood at 0. The suite runs
# without the unit (MDADM_NO_SYSTEMCTL): the manager, the child of mdadm --grow, is killed here (SIGKILL) and
# --grow --continue of the container goes on as the unit would: a) at the start (sync_max 0), b) midway (md past a
# third), c) after -S and assembly; d) the end - 128K, the data as written, md check 0, the LD as rcraid's. The
# fixture of 66c (q21c-r10b: a RAID10 2 x 2 of 64K at + 0x800).
if want 69; then
cd "$MDADM_DIR"
stopall
# q69cont <tag>: the manager killed, --grow --continue of the container; waits until the new manager lets md on
# past the sync_max the killed one held it at (90 s at most: a region of 0x8000 at 1000 KB/s takes ~16 s)
q69cont() { local c=$(grep -l '^external:amd' /sys/block/md*/md/metadata_version | head -1 | cut -d/ -f4) s0 s i
	sudo pkill -KILL -x mdadm; sleep 0.5; s0=$(cat /sys/block/$V/md/sync_max)
	( $M --grow --continue /dev/$c > $WQ/q66/cont$1.out 2>&1 & ); sleep 1
	for i in $(seq 1 90); do s=$(cat /sys/block/$V/md/sync_max); [ "$s" != "$s0" ] && break; sleep 1; done
	Q69="$s0 -> $s"; Q69UP=0; [ "$s" = max ] || [ "$s" -gt "$s0" ] 2>/dev/null && Q69UP=1; }
q66fix q21c-r10b; qgasm; V=$(qgmd t10); $M --readwrite /dev/$V >/dev/null 2>&1; q66slow 1000
$M --grow /dev/$V --chunk=128 > $WQ/q66/grow.out 2>&1; sleep 2
q69cont a
check "69a: RAID10 at + 0x800 --chunk=128 (backwards), its manager killed at the start: --grow --continue goes on (sync_max $Q69)" "grep -q 'from the end' $WQ/q66/grow.out && ! grep -qE 'not properly frozen|Cannot continue' $WQ/q66/conta.out && [ \$(q66md $V reshape_direction) = backwards ] && [ $Q69UP = 1 ] && pgrep -x mdadm >/dev/null"
for i in $(seq 1 120); do read -r a _ b < /sys/block/$V/md/sync_completed; [ "${a:-0}" -ge $(( ${b:-1} / 3 )) ] 2>/dev/null && break; sleep 1; done
q69cont b
check "69b: its manager killed midway (md past a third): --grow --continue goes on (sync_max $Q69)" "! grep -qE 'not properly frozen|Cannot continue' $WQ/q66/contb.out && [ $Q69UP = 1 ] && pgrep -x mdadm >/dev/null"
sleep 3; $M -S /dev/$V >/dev/null 2>&1; sleep 1; stopall; qgasm; V=$(qgmd t10); sleep 2
q69cont c
check "69c: stopped (-S), assembled, its manager killed: --grow --continue goes on backwards (sync_max $Q69)" "! grep -qE 'not properly frozen|Cannot continue' $WQ/q66/contc.out && [ \$(q66md $V reshape_direction) = backwards ] && [ $Q69UP = 1 ] && pgrep -x mdadm >/dev/null"
q66fast; q66wait; sleep 3; V=$(qgmd t10)
check "69d: done: md raid10 of 128 KiB, the data as written, md check 0; the LD as rcraid ends it (q21c-r10s2rc but for its generation)" "[ \$(q66md $V chunk_size) = 131072 ] && [ \"\$(q66chk /dev/$V 120 5)\" = ok ] && [ \$(q66mm $V) = 0 ] && [ \"\$(qgld $WQ/q66/d0.img $T10ID | sed 's/gen=[0-9a-f]* //')\" = \"\$(q66final q21c-r10s2rc $T10ID | sed 's/gen=[0-9a-f]* //')\" ]"
q66fast; qgdrop q66; rm -f $WQ/q66fin.img
fi
# --- end of stage 69 ---

# --- stage 70: growing in place - the transform log a region behind md. Real hardware (1.4 to 1.6): the AMD Windows
# driver 9.3.3.218 goes on with such a growth from the region after ProtectStart, taking that one as done; the rest
# of the region md had stopped in was left without parity or a mirror copy (a RAID5 finished by Windows: md check
# 7680, exactly from md's last stripe to the end of the logged region). The new part of the two halves of a RAID1
# random and different, the growth slow, md -S midway: below ProtectStart + ProtectSize md has mirrored everything,
# the halves are equal there; md then ends it, md check 0. A volume smaller than a region of the log is refused.
if want 70; then
cd "$MDADM_DIR"
stopall
qgmk q70 4 1
$M -C /dev/md/amd70 -e amd -n 4 $QGL --run >/dev/null 2>&1; CN=$(cont1)
$M -C /dev/md/g70 -e amd -l1 -n2 -z 64M $(qgl 0) $(qgl 1) --run >/dev/null 2>&1
$M -C /dev/md/s70 -e amd -l1 -n2 -z 8M $(qgl 2) $(qgl 3) --run >/dev/null 2>&1
sleep 1; waitrec; G=$(qgmd g70); S=$(qgmd s70)
check "70: a RAID1 of 8 MiB, less than a region of the log (0x4800): --grow --size refused" "$M --grow /dev/$S --size=16M 2>&1 | grep -q 'AMD logs a growth in regions of 9216 KiB: a smaller volume cannot be grown in place' && [ \$(cat /sys/block/$S/md/component_size) = 8192 ]"
L0=$(qgl 0); L1=$(qgl 1)
O0=$(cat /sys/block/$G/md/dev-${L0#/dev/}/offset); O1=$(cat /sys/block/$G/md/dev-${L1#/dev/}/offset)
OLD=$((64 * 2048)); NEW=$((256 * 2048)); P=$((0x4800))
for l in "$L0 $O0" "$L1 $O1"; do set -- $l
	sudo dd if=/dev/urandom of=$1 bs=512 seek=$(($2 + OLD)) count=$((NEW - OLD)) oflag=direct status=none; done
# legs <from> <to>: the two halves hold the same from..to (sectors of the member's data)
legs() { cmp -s <(sudo dd if=$L0 bs=512 skip=$((O0 + $1)) count=$(($2 - $1)) iflag=direct status=none) \
	<(sudo dd if=$L1 bs=512 skip=$((O1 + $1)) count=$(($2 - $1)) iflag=direct status=none); }
echo 3000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
$M --grow /dev/$G --size=256M >/dev/null 2>&1; sleep 9
$M -S /dev/$G >/dev/null 2>&1; sleep 1
T=$(qgtlog $L0 $((O0 - 0x5000))); D=$((0x$(echo $T | cut -d' ' -f2)))
check "70: stopped midway ($D): md has mirrored all below the log's region end - where the Windows driver goes on - the rest not yet" "echo \"\$T\" | grep -qE '^5354 [0-9a-f]+ 1 600 2024241 4800 c$' && [ $((D % P)) = 0 ] && [ $D -ge $((OLD - OLD % P - P)) ] && legs $OLD $((D + P)) && ! legs $((NEW - P)) $NEW"
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
$M -I /dev/$CN >/dev/null 2>&1; sleep 1; G=$(qgmd g70); waitrec; sleep 3
echo check | sudo tee /sys/block/$G/md/sync_action >/dev/null; sleep 1; waitrec
check "70: assembled again, md ends it: 256 MiB, the halves equal, md check 0" "[ \$(cat /sys/block/$G/md/component_size) = $((256 * 1024)) ] && legs 0 $NEW && [ \$(cat /sys/block/$G/md/mismatch_cnt) = 0 ]"
qgdrop q70
fi
# --- end of stage 70 ---

# --- stage 71: the end of a migration the AMD driver began itself. rcraid 9.3.3-00302 ends one onto more disks so:
# the transform log goes COMPLETED (status 2, ProtectStart where the copy ended), 2 to 6 ms later the "100 %" packet,
# then the log is cleared and the final packet written (rcblob RC_CheckTransformLogs takes a log COMPLETED for valid,
# RC_RestartTask ends the transform on it without I/O). Fixture 2026-11-23-rcraid-migration-end: moments of that
# window from rcraid's own bytes (the commit block and the log as rcraid wrote them then, newer packets of the ring
# zeros), a RAID0 2 -> 3 of the largest capacity (its "100 %" is 67.29 %, at the old capacity, 0x5f7c00) and a
# RAID5 3 -> 4. md must not reshape from 0 - it would read the old layout over the data moved already (1.6.1-1.6.2
# did, the volume was lost): c3-f1 (the start packet and the log COMPLETED) from the log's mark; c3-f2, c3-f3 ("100 %"
# with the log and without) a RAID0 of 3 at once; r5g-f1 (the start packet, the log COMPLETED at the end) a RAID5 of
# 4 at once, ended by mdmon. A RAID0 taken as finished keeps AMD's "100 %" (no mdmon for a RAID0; the AMD driver
# ends it without I/O at its next start) - not checked.
if want 71; then
cd "$MDADM_DIR"
stopall
Q71D=$FIXT/2026-11-23-rcraid-migration-end
# q71fix <snapshot>: four disks of 2 GiB - the snapshot's metadata (LBA 0...0x6000) and the start of the extents
# (0x100 sectors from 0x100000: the transform log)
q71fix() { local n; qgdrop q71; mkdir -p $WQ/q71; QGL=""
	for n in 0 1 2 3; do truncate -s 2G $WQ/q71/d$n.img
		xz -dc $Q71D/$1-sata$n-lba0-6000.img.xz | dd of=$WQ/q71/d$n.img conv=notrunc status=none
		xz -dc $Q71D/$1-sata$n-lba0x100000-100.img.xz | dd of=$WQ/q71/d$n.img bs=512 seek=$((0x100000)) conv=notrunc status=none
		QGL="$QGL $(sudo losetup -f --show $WQ/q71/d$n.img)"; done; }
q71vol() { for m in $(ls /sys/block | grep ^md); do grep -q '^external:[-/]md' /sys/block/$m/md/metadata_version 2>/dev/null && echo $m; done | head -1; }
echo 1000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
q71fix c3-f1; qgasm; V=$(q71vol); sleep 2
RS=$(cat /sys/block/$V/md/reshape_position 2>/dev/null)
check "71: c3-f1 (rcraid's RAID0 2 -> 3: the start packet live, its log COMPLETED at 0x5f7c00): md raid4 reshapes on from the log's mark, not from 0" "[ -n '$V' ] && [ \$(cat /sys/block/$V/md/level) = raid4 ] && [ \"\$RS\" -ge $((0x5f7c00)) ] && [ \"\$RS\" -lt $((0x5f7c00 + 0x40000)) ]"
for f in c3-f2 c3-f3; do
	q71fix $f; qgasm; V=$(q71vol); sleep 2
	check "71: $f (rcraid's \"100 %\" of the RAID0 2 -> 3, 67.29 %, the log $([ $f = c3-f2 ] && echo COMPLETED || echo cleared)): md raid0 of 3 at once, no reshape, at the new capacity; -E 100% done" "[ -n '$V' ] && [ \$(cat /sys/block/$V/md/level) = raid0 ] && [ \$(cat /sys/block/$V/md/raid_disks) = 3 ] && [ \$(cat /sys/block/$V/size) = $((0x8f1000)) ] && [ -z \"\$(mdof raid4)\" ] && $M -E $(qgl 0) | grep -q 'Migration : .*; 100% done'"
done
q71fix r5g-f1; qgasm; V=$(q71vol); sleep 2
check "71: r5g-f1 (rcraid's RAID5 3 -> 4: the start packet live, its log COMPLETED at the end, 0x8f1000): md raid5 of 4 at once, no reshape from 0" "[ -n '$V' ] && [ \$(cat /sys/block/$V/md/level) = raid5 ] && [ \$(cat /sys/block/$V/md/raid_disks) = 4 ] && [ \"\$(cat /sys/block/$V/md/sync_action)\" != reshape ] && [ \$(cat /sys/block/$V/size) = $((0x8f1000)) ]"
for i in $(seq 1 30); do [ $(qgld $WQ/q71/d0.img 811bf40a3e20 | wc -l) = 1 ] && break; sleep 1; done
check "71: r5g-f1 ... ended by mdmon: one LD, a RAID5 of 4, NORMAL COMPLETED, the log cleared" "qgld $WQ/q71/d0.img 811bf40a3e20 | grep -qE '^type=[0-9a-f]+ st=200 tt=0 lo=5354 ts=a1a6 cap=8f1000 .* fs=1x4 tf=0 ' && [ \$(qgld $WQ/q71/d0.img 811bf40a3e20 | wc -l) = 1 ] && [ \"\$(qgtlog $(qgl 0) 0x100000)\" = '0 0 0 0 0 0 0' ]"
echo 400000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
qgdrop q71
fi
# --- end of stage 71 ---

# the ASRock and X399 snapshots are untouched: attached before stage 7, assembled only in stage 1
if want 1; then
# reg <image> <fixture> <LBA>: the image has the fixture (xz or raw) at that LBA
reg() { local n=$(xz -dcf $2 | wc -c); [ "$(sudo dd if=$IMG/$1 bs=512 skip=$3 count=$((n / 512)) status=none | sha256sum)" = "$(xz -dcf $2 | sha256sum)" ]; }
D=$FIXT/2026-10-28-asrock-x670e-raid0
check "metadata untouched (ASRock)" "reg asrock-nvme1n1.img $D/nvme1n1-lba0-6000.img.xz 0 && reg asrock-nvme2n1.img $D/nvme2n1-lba0-6000.img.xz 0 && reg asrock-nvme1n1.img $D/nvme1n1-lba100000-105000.img.xz $((0x100000)) && reg asrock-nvme2n1.img $D/nvme2n1-lba100000-105000.img.xz $((0x100000))"
check "metadata untouched (X399)" "reg x399-member0.img $X399/member0.meta.bin $((0x5000)) && reg x399-member3.img $X399/member3.meta.bin $((0x5000))"
check "LBA 0 of X399 still empty (no MBR written by mdmon)" "[ \$(dd if=$IMG/x399-member0.img bs=512 count=1 status=none | tr -d '\0' | wc -c) = 0 ]"
fi
# a number in STAGES or PART2 that no stage asked about (a typo: the stage would run nowhere)
for s in ${STAGES:-} $PART2; do case "$SEEN" in *" $s "*) ;; *) echo "FAIL no stage $s (STAGES, PART2)"; fail=1 ;; esac; done
echo "checks: $NOK ok, $NFAIL FAIL, $NSKIP blocks skipped, $(($(date +%s) - T0)) s"
[ $fail = 0 ] && echo "ALL OK" || echo "SOME FAILED"
exit $fail
