#!/bin/bash
# run.sh <mdadm-tree>: run the test suite of mdadm's AMD RAIDXpert2 support (suite.sh) on that build tree.
#
#   <mdadm-tree>   an mdadm source tree with mdadm/mdadm-amd.patch applied and `make mdadm mdmon` done
#   STAGES="1 4 7c"  only these stages (the ids of "if want ..." in suite.sh); PART=1 / PART=2: one half each
#   WORKDIR=<dir>  where the images go (default /var/tmp/mdadm-amd-tests; ~20 GB free, no spaces in the path)
#   AMD_RULE=<file>  the udev rule under test (default packaging/arch/64-amd-raid-assembly.rules)
#   ALLOW_MD=1     run although md arrays are active (the suite stops ALL md arrays: test machines only)
#
# Run it as root or as a user with password-less sudo, on a test machine or VM only: the suite stops every md
# array, loads and unloads kernel modules (scsi_debug, LIO), writes udev rules and systemd units under /run and,
# if the machine has blank disks with the serial numbers AMDSATA0-4 / AMDNVME0-1, wipes those.  See README.md.
set -eu -o pipefail
usage() { echo "usage: [STAGES=...] [PART=1|2] [WORKDIR=dir] $0 <mdadm-tree>" >&2; exit 2; }
[ $# = 1 ] || usage
T=$(cd "$(dirname "$0")" && pwd)
R=$(dirname "$T")
MDADM_DIR=$(cd "$1" && pwd) || usage
for f in mdadm mdmon; do
	[ -x "$MDADM_DIR/$f" ] || { echo "$MDADM_DIR/$f: not built (make mdadm mdmon)" >&2; exit 1; }
done
[ -e "$MDADM_DIR/super-amd.c" ] || { echo "$MDADM_DIR: no super-amd.c (apply mdadm/mdadm-amd.patch)" >&2; exit 1; }

WK=${WORKDIR:-/var/tmp/mdadm-amd-tests}
case "$WK" in *" "*) echo "WORKDIR must not contain spaces" >&2; exit 1 ;; esac
export MDADM_DIR WK
export IMG=$WK/images WQ=$WK/q TMPW=$WK/tmp
export FIXT=$T/fixtures HLP=$T/helpers TOOLS=$R/tools X399=$R/test-data/x399-raid10-plaidpiper
export AMD_RULE=${AMD_RULE:-$R/packaging/arch/64-amd-raid-assembly.rules}
export STAGES=${STAGES:-} PART=${PART:-}
export PATH=$PATH:/usr/sbin:/sbin
export USER=${USER:-$(id -un)}

# root without sudo: a stand-in that runs the command (the suite calls "sudo", "sudo -E", "sudo env ...")
if [ "$(id -u)" = 0 ] && ! command -v sudo >/dev/null; then
	mkdir -p "$WK/bin"
	printf '#!/bin/sh\n[ "${1:-}" = -E ] && shift\nexec "$@"\n' > "$WK/bin/sudo"
	chmod +x "$WK/bin/sudo"
	export PATH=$WK/bin:$PATH
fi
sudo -n true 2>/dev/null || { echo "needs root or password-less sudo" >&2; exit 1; }

miss=""
for c in losetup truncate xz python3 gcc mkfs.btrfs mkfs.ext4 sfdisk blkdiscard dmsetup udevadm lsblk cmp od \
	setsid timeout; do
	command -v $c >/dev/null || miss="$miss $c"
done
[ -z "$miss" ] || { echo "missing commands:$miss" >&2; exit 1; }
for m in md_mod raid0 raid1 raid10 raid456 loop btrfs dm_mod; do
	sudo modprobe $m 2>/dev/null || [ -d /sys/module/$m ] || miss="$miss $m"
done
[ -z "$miss" ] || { echo "missing kernel modules:$miss" >&2; exit 1; }
for f in "$TOOLS/amdraid_dump.py" "$TOOLS/amdraid_fix_legacy.py" "$X399/member0.meta.bin" "$AMD_RULE"; do
	[ -e "$f" ] || { echo "$f: missing (run.sh is tests/run.sh of the mdadm-amd repository)" >&2; exit 1; }
done
if [ "${ALLOW_MD:-}" != 1 ] && grep -q '^md[0-9_a-z]* : active' /proc/mdstat 2>/dev/null; then
	echo "md arrays are active (/proc/mdstat): the suite would stop them all. Stop them, reboot after an" >&2
	echo "interrupted run, or set ALLOW_MD=1 on a test machine." >&2
	exit 1
fi

mkdir -p "$IMG" "$TMPW"
"$T/fixtures/mkimages.sh" "$IMG"

# udev for the run, under /run (gone at reboot, removed at exit): rule 63 of the tree only up to the /dev/md/<name>
# links, with this mdadm (without the links mdadm waits ~4 s for each); an installed mdadm's rule 64 masked, so that
# it does not assemble the suite's disks behind its back (stages 18 and 39 put the AMD rule in place themselves)
UR=/run/udev/rules.d
sudo mkdir -p $UR
sed -n '1,/SYMLINK+="md\/$env{MD_DEVNAME}"/p' "$MDADM_DIR/udev-md-raid-arrays.rules" |
	sed "s,BINDIR/mdadm,$MDADM_DIR/mdadm," | { cat; echo 'LABEL="md_end"'; } | sudo tee $UR/63-md-raid-arrays.rules >/dev/null
echo '# masked by the mdadm-amd test suite (tests/run.sh) while it runs' | sudo tee $UR/64-md-raid-assembly.rules >/dev/null
trap 'sudo rm -f $UR/63-md-raid-arrays.rules $UR/64-md-raid-assembly.rules; sudo udevadm control --reload' EXIT
sudo udevadm control --reload
echo "mdadm: $MDADM_DIR ($(cd "$MDADM_DIR" && md5sum mdadm mdmon | cut -c1-12 | tr '\n' ' '))"
echo "kernel $(uname -r); work dir $WK; STAGES='$STAGES' PART='$PART'"
cd "$MDADM_DIR"
bash "$T/suite.sh" 2>&1 | tee "$WK/run.log"
