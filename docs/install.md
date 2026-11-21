# Installing mdadm-amd

mdadm-amd replaces your distribution's `mdadm` and `mdmon` with a build that knows the AMD metadata, and adds an
initramfs integration so that Linux can boot from an AMD volume. An optional kernel module enables the md
write-intent bitmap on recent kernels.

- [Before you start](#before-you-start)
- [Arch Linux and derivatives](#arch-linux-and-derivatives)
- [Debian and Ubuntu (initramfs-tools)](#debian-and-ubuntu-initramfs-tools)
- [Fedora, RHEL and its rebuilds](#fedora-rhel-and-its-rebuilds)
- [openSUSE](#opensuse)
- [Ubuntu 26.04 and other dracut systems](#ubuntu-2604-and-other-dracut-systems)
- [Building mdadm from source](#building-mdadm-from-source)
- [Checking the installation](#checking-the-installation)
- [The md bitmap](#the-md-bitmap)

## Before you start

- **BIOS.** Set the SATA mode to RAID. The disks must be AMD RAID disks: initialized in the RAIDXpert2 menu, or by
  `mdadm --create --metadata=amd` after installing. mdadm takes only disks behind the controllers the firmware uses
  for RAID (EFI variable `AMD_RAID`); `--force` overrides that. Disks that are not behind a PCI controller, such as
  loop devices over image files, are taken as they are; each disk needs at least 552 MiB.
- **Kernel.** RAID0, RAID1, RAID10, RAID5 and RAIDABLE work on any current kernel. Volume (linear) arrays need the
  `md-linear` module: Linux 6.14 and later, or a kernel that ships it (RHEL 9 and 10 and their rebuilds do in their
  5.14 and 6.12; Debian 13 and Ubuntu 24.04 do not). Without it `mdadm --create` refuses a Volume.
- **Back up.** This is experimental code that writes RAID metadata. Never load `rcraid` on the same disks.
- **Uninstalling** brings the distribution's `mdadm` and `mdmon` back, and they do not know the AMD metadata: do
  it with no AMD volume in use, never with the root file system on one. (On Ubuntu 26.04 `needrestart` restarted
  `mdmon` in the middle of the uninstall, and a system with its root on a volume hung.)
- **Get the sources:**

  ```sh
  git clone https://github.com/exeroom536/mdadm-amd.git
  cd mdadm-amd
  ```

How each distribution was checked is in [testing.md](testing.md#distributions).

## Arch Linux and derivatives

`packaging/arch/PKGBUILD` builds two packages:

| Package | What it is |
|---|---|
| `mdadm-amd` | mdadm and mdmon with the AMD handler, the udev rule, the `amdraid` mkinitcpio hook and a shutdown hook. Replaces `mdadm`. |
| `md-bitmap-ext-dkms` | optional: `md_mod` with the md bitmap fix, for Linux 6.18.57 to 6.18.64 and 7.3.0 to 7.3.5 ([details](#the-md-bitmap)) |

Manjaro and EndeavourOS build and install them the same way. New EndeavourOS installs build their initramfs with
dracut, not mkinitcpio: for booting from a volume there, use the dracut module (step 3 of
[Fedora](#fedora-rhel-and-its-rebuilds)) instead of step 3 below; that was not tried.

**1. Build.**

```sh
sudo pacman -Syu --needed base-devel git
cd packaging/arch
cp ../../mdadm/mdadm-amd.patch ../dkms/* .
makepkg -s
```

`makepkg` downloads upstream mdadm at the pinned commit, applies the patch and builds the packages. If
`/etc/makepkg.conf` enables `debug`, it also builds `mdadm-amd-debug` with the debug symbols; you do not need it.

**2. Install.**

```sh
sudo pacman -U mdadm-amd-[0-9]*.pkg.tar.zst
sudo pacman -U md-bitmap-ext-dkms-*.pkg.tar.zst      # optional, see "The md bitmap"
```

pacman replaces the `mdadm` package and rebuilds the initramfs.

**3. Boot from a volume** (skip this if the root file system is not on an AMD volume). Add `amdraid` to `HOOKS`
in `/etc/mkinitcpio.conf`, after `block`; the `systemd` hook is required:

```
HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block amdraid filesystems fsck)
```

then rebuild the initramfs:

```sh
sudo mkinitcpio -P
```

The shutdown hook needs no setup. At shutdown an `mdmon` of the shutdown ramfs takes the volumes over, the old root
is unmounted, and the volumes are stopped clean, the root volume included.

**4. Volume names (optional).** Without `ARRAY` lines in `/etc/mdadm.conf` a volume assembled by udev is named
`/dev/md/<name>_0`, as an Intel IMSM volume is. To get `/dev/md/<name>`:

```sh
sudo mdadm --examine --scan | sudo tee -a /etc/mdadm.conf
sudo mkinitcpio -P          # the hook copies mdadm.conf into the initramfs
```

Mounting by file system UUID works either way.

**Uninstall.** Remove `amdraid` from `HOOKS`, then:

```sh
sudo pacman -S mdadm                     # takes the place of mdadm-amd, rebuilds the initramfs
sudo pacman -R md-bitmap-ext-dkms        # if installed
```

## Debian and Ubuntu (initramfs-tools)

Debian's own initramfs scripts assemble the volumes with this mdadm as they are; Ubuntu's need one more file
(step 4).

Ubuntu 24.04 and Linux Mint 22, which is based on it, build their initramfs with initramfs-tools (on Mint, follow
the Ubuntu steps); new installs of Ubuntu 26.04 use dracut, see
[dracut systems](#ubuntu-2604-and-other-dracut-systems). On Ubuntu 25.10 the server and the desktop differ, and an
upgraded system keeps what it had, so check:

```sh
dpkg -l dracut initramfs-tools           # the one marked "ii" builds the initramfs
```

**1. Build mdadm** as in [Building mdadm from source](#building-mdadm-from-source), with:

```sh
sudo apt install build-essential git libudev-dev pkgconf
```

**2. Install.** Install the distribution's `mdadm` package for its scripts, then divert its binaries and put this
build in their place. The diversion keeps package updates from overwriting them.

```sh
sudo apt install mdadm
cd /path/to/upstream-mdadm             # the build directory from step 1
for b in mdadm mdmon; do
	sudo dpkg-divert --local --rename --divert /usr/sbin/$b.debian --add /usr/sbin/$b
	sudo install -m755 $b /usr/sbin/$b
done
```

If the root file system is on an AMD volume, run `sudo systemctl restart mdmon@md127` after installing a new build
(the container is the `super external:amd` line of `/proc/mdstat`): the old `mdmon` keeps the deleted binary open,
the root cannot be remounted read-only at shutdown, and the volume resyncs at the next boot.

**3. udev rule** for disks attached after boot:

```sh
cd /path/to/mdadm-amd
sed 's,/usr/bin/mdadm,/usr/sbin/mdadm,' packaging/arch/64-amd-raid-assembly.rules |
	sudo tee /usr/lib/udev/rules.d/64-amd-raid-assembly.rules
```

**4. Boot from a volume.** The initramfs assembles the volumes listed in `mdadm.conf`. On Ubuntu, also install the
hook that puts the udev rule into the initramfs: Ubuntu waits 30 s for the root device before it runs its mdadm
script, and with the rule udev assembles the volumes as soon as the disks show up. With a disk missing, the volume
starts degraded after those 30 s. On both, install the `local-bottom` script too: with a disk missing, a volume the
boot does not wait for is then started degraded by systemd 30 s after boot (this initramfs has no systemd to run
mdadm's last-resort timer).

```sh
sudo /usr/share/mdadm/mkconf force-generate /etc/mdadm/mdadm.conf
sudo install -m755 /path/to/mdadm-amd/packaging/initramfs-tools/amdraid /etc/initramfs-tools/hooks/   # Ubuntu
sudo install -m755 /path/to/mdadm-amd/packaging/initramfs-tools/local-bottom-amdraid \
	/etc/initramfs-tools/scripts/local-bottom/amdraid
sudo update-initramfs -u
```

**Uninstall.** Remove `/usr/lib/udev/rules.d/64-amd-raid-assembly.rules`, `/etc/initramfs-tools/hooks/amdraid` and
`/etc/initramfs-tools/scripts/local-bottom/amdraid`, then:

```sh
for b in mdadm mdmon; do sudo rm /usr/sbin/$b && sudo dpkg-divert --rename --remove /usr/sbin/$b; done
sudo update-initramfs -u
```

## Fedora, RHEL and its rebuilds

Fedora, RHEL, AlmaLinux and Rocky Linux build their initramfs with dracut. dracut's `mdraid` module finds RAID
disks by the type libblkid reports, and libblkid does not know AMD disks, so the `90amdraid` module from this
repository is needed: when the root is on an AMD volume it pulls `mdraid` in, and its udev rule offers every whole
disk to `mdadm --incremental` (mdadm leaves disks without AMD metadata alone).

**1. Build mdadm** as in [Building mdadm from source](#building-mdadm-from-source), with:

```sh
sudo dnf install gcc make git systemd-devel
```

**2. Install** the distribution's mdadm and dracut, then this build over them:

```sh
sudo dnf install mdadm dracut
cd /path/to/upstream-mdadm
sudo install -m755 mdadm mdmon /usr/sbin/
sudo restorecon /usr/sbin/mdadm /usr/sbin/mdmon       # SELinux labels
```

**3. dracut module and udev rule:**

```sh
cd /path/to/mdadm-amd
sudo cp -r packaging/dracut/90amdraid /usr/lib/dracut/modules.d/
sudo chmod 755 /usr/lib/dracut/modules.d/90amdraid/module-setup.sh
sudo cp packaging/dracut/90amdraid/64-amd-raid-assembly.rules /usr/lib/udev/rules.d/
for u in timer service; do
	sudo install -Dm644 packaging/dracut/90amdraid/last-resort-$u.conf \
		/usr/lib/systemd/system/mdadm-last-resort@.$u.d/amdraid.conf
done
sudo dracut -f
```

The two `last-resort` files keep mdadm's last-resort timer running past the switch to the real root, so that a volume
the boot does not need also starts degraded when a disk is missing.

**4. Keep it in place.** An update of the `mdadm` package writes its own binaries back. Hold the package with
dnf's versionlock, or install these again after each update:

```sh
sudo dnf install 'dnf-command(versionlock)'    # RHEL 9 and 10 need the plugin; Fedora's dnf has the command
sudo dnf versionlock add mdadm
```

SELinux needs nothing beyond the labels set by `restorecon`. `rd.md=0` on the kernel command line turns the module
off, as it does `mdraid`.

**Uninstall.** Remove `/usr/lib/dracut/modules.d/90amdraid`, `/usr/lib/udev/rules.d/64-amd-raid-assembly.rules` and
`/usr/lib/systemd/system/mdadm-last-resort@.{timer,service}.d/amdraid.conf`, then `sudo dnf versionlock delete mdadm; sudo dnf reinstall mdadm; sudo dracut -f`.

## openSUSE

openSUSE Tumbleweed and Leap 16 use dracut as well; follow [Fedora](#fedora-rhel-and-its-rebuilds) with `zypper`:

```sh
sudo zypper install gcc make git systemd-devel           # build
sudo zypper install mdadm dracut grep sed                 # install
```

Install `grep` and `sed` themselves: with the busybox variants dracut fails. SELinux on Tumbleweed and Leap 16 needs
the same `restorecon` line. To hold the package: `sudo zypper addlock mdadm`. The minimal VM images come with
`kernel-default-base`, which has no md modules; install `kernel-default`.

**Uninstall.** Remove the files listed in Fedora's Uninstall, then:

```sh
sudo zypper removelock mdadm
sudo zypper install --force mdadm
sudo dracut -f
```

openSUSE Leap 15.6 cannot build current upstream mdadm (gcc 7 rejects code in `platform-intel.h`).

## Ubuntu 26.04 and other dracut systems

New installs of Ubuntu 26.04 build their initramfs with dracut (how to check: [Debian and
Ubuntu](#debian-and-ubuntu-initramfs-tools)). Build mdadm with the Debian packages from that section, then follow
steps 2 and 3 of [Fedora](#fedora-rhel-and-its-rebuilds) with `apt install mdadm dracut`, without `restorecon`, and
with `sudo update-initramfs -u` in place of `sudo dracut -f`. On Ubuntu `update-initramfs` runs dracut and also
updates the copy the boot loader reads; with systemd-boot, `dracut -f` writes a file the boot entry does not use,
and the system does not boot. AppArmor has no profile for mdadm or mdmon, so nothing more is needed. To hold the
package: `sudo apt-mark hold mdadm`.

**Uninstall.** Remove the files listed in Fedora's Uninstall, then:

```sh
sudo apt-mark unhold mdadm
sudo apt install --reinstall mdadm
sudo update-initramfs -u
```

## Building mdadm from source

Everything except the Arch package builds upstream mdadm at the commit the patch is made against:

```sh
git clone https://github.com/md-raid-utilities/mdadm.git upstream-mdadm
cd upstream-mdadm
git checkout 4cd7d33c1d2672c40ee3653006c36fe84cd1a545
git apply /path/to/mdadm-amd/mdadm/mdadm-amd.patch
make mdadm mdmon
```

The patch can also be applied as a series (`git am /path/to/mdadm-amd/mdadm/series/*.patch`); the result is the
same tree.

## Checking the installation

```sh
mdadm --version                          # mdadm - v4.6-132-g4cd7d33c
sudo mdadm --examine /dev/sdX            # "Magic : RAIDCore" on an AMD disk
sudo mdadm --assemble --scan             # or reboot: udev assembles the volumes
cat /proc/mdstat
```

What to do next: [usage.md](usage.md).

## The md bitmap

With the md write-intent bitmap, md resyncs after a crash only the parts of a volume it was writing, instead of the
whole volume. This works for RAID1, RAID10 and RAID5 volumes. It is off unless you ask for it:

```sh
sudo mdadm --create /dev/md/data --level=1 --raid-devices=2 --bitmap=internal /dev/md/amd0
sudo mdadm --update-subarray=0 --update=bitmap /dev/md/amd0         # an existing volume, stopped
sudo mdadm --update-subarray=0 --update=no-bitmap /dev/md/amd0      # remove it
```

`mdadm --create` of a volume also asks whether to add one.

### Kernel requirements

| Kernel | md bitmap with external metadata |
|---|---|
| up to 6.17 | works as is |
| 6.18 and later | broken upstream, Intel IMSM included. Needs the fix in `kernel/` (two md patches) |

Without the fix mdadm says the kernel cannot run the bitmap, and the volume runs without it, with a full resync
after a crash.

How to get the fix (optional: everything else works without it):

- **Arch Linux, kernel 6.18.57 to 6.18.64 or 7.3.0 to 7.3.5:** install the `md-bitmap-ext-dkms` package. It builds
  `md_mod` from the stable kernel's `drivers/md` with the fix (downloaded from kernel.org and checked by SHA-256)
  and installs it under `/updates/dkms`. The package carries `drivers/md` of 6.18.57 (the same files as in 6.18.57
  to 6.18.60), 6.18.61 (to 6.18.62), 6.18.63 (and 6.18.64), 7.3.1 (7.3.0 to 7.3.3) and 7.3.4 (and 7.3.5), and takes the one of the kernel it
  builds for. On any other kernel version it builds nothing, and the stock `md_mod` stays. It needs md built as a
  module (`CONFIG_BLK_DEV_MD=m`). If your kernel enforces module signatures, enroll the DKMS key first. The kernel's
  own `md-mod.ko.zst` stays in place, so `pacman -Qk` finds the kernel package whole.
- **openSUSE Tumbleweed and other distributions with DKMS, the same kernel versions:** the same module, installed
  by `packaging/dkms/install.sh` ([below](#the-dkms-module-without-the-arch-package)).
- **Other kernel versions, and kernels with md built in** (`CONFIG_BLK_DEV_MD=y`: Fedora 45, Ubuntu 26.04): apply
  `kernel/0001-*.patch` and `kernel/0002-*.patch` to the kernel and rebuild it. They apply to 6.18.63, 7.0.14,
  7.1.13, 7.2.15, 7.3.1 to 7.3.5, 7.4-rc3 and the mainline of 15 November 2026.

To check that the bitmap is in use:

```sh
cat /sys/block/mdX/md/consistency_policy       # "bitmap"
sudo mdadm --examine /dev/sdX                  # "md Bitmap : … KiB a bit, … set"
```

`tools/imsm-bitmap-probe.sh` checks the kernel side alone, with Intel IMSM on two loop files.

### The DKMS module without the Arch package

This step is optional. `packaging/dkms/install.sh` installs the module of `md-bitmap-ext-dkms` on other
distributions: it downloads `drivers/md` of the bases listed in `packaging/arch/PKGBUILD` from kernel.org, checks them
against the SHA-256 sums there, applies the fix, lays out `/usr/src/md-bitmap-ext-<version>/` as the package does,
runs `dkms install` for the running kernel and rebuilds its initramfs (`update-initramfs -u` where there is one,
otherwise `dracut -f`), from which `md_mod` is loaded when the root is on a volume. A version installed before is
removed first.

It builds for the same kernels as the package, 6.18.57 to 6.18.64 and 7.3.0 to 7.3.5, and needs md built as a
module. openSUSE Tumbleweed has it so; Fedora 45 and Ubuntu 26.04 build md into the kernel, and there the script
stops: only a kernel rebuilt with the fix helps. A distribution kernel of these versions may still carry md changes
of its own: Tumbleweed 7.3.3 has the stable `drivers/md`; on another distribution compare its kernel's `drivers/md`
first (`packaging/dkms/md-bases.sh` shows which stable releases share these files).

**1. Packages:** DKMS, the headers of the running kernel, `patch` and `curl`. On openSUSE the devel package must be
the version of the running kernel: after a kernel update, reboot first. Elsewhere, install the same with the
distribution's package names.

```sh
sudo zypper install dkms kernel-default-devel patch curl     # openSUSE
```

**2. Install, then reboot:**

```sh
cd /path/to/mdadm-amd
sudo packaging/dkms/install.sh
```

DKMS builds the module again for each new kernel; on a kernel without a base it builds nothing, and that kernel
runs with its own `md_mod` (volumes then run without the bitmap) until a newer mdadm-amd has a base for it: update
the sources and run the script again. The kernel's own `md-mod.ko` stays in place, so the package manager finds the
kernel package whole.

**3. Check** after the reboot, then add the bitmap to a volume as above:

```sh
modinfo -n md_mod                  # a file under /lib/modules/<kernel>/updates/
cat /sys/module/md_mod/taint       # contains "O": the module from DKMS is loaded
```

**Secure Boot.** With Secure Boot on, the kernel loads only modules signed by a key it trusts. DKMS signs the module
with a key of its own (`/var/lib/dkms/mok.pub`, made at the first build), and that key has to be enrolled into
shim's MOK list before you reboot:

```sh
sudo mokutil --import /var/lib/dkms/mok.pub    # asks for a one-time password
```

At the next boot MokManager asks to enroll the key, with that password. Without the key the kernel rejects this
`md_mod` and does not fall back to its own one: no md array starts, and a system with its root on a volume does not
boot (in the initramfs: "Loading of module with unavailable key is rejected"). To get out of that, turn Secure Boot
off for one boot, then enroll the key or uninstall. This was tried with `module.sig_enforce=1`, which makes the
kernel check signatures as Secure Boot does, not with Secure Boot itself.

**Uninstall:**

```sh
sudo packaging/dkms/install.sh --remove     # then reboot
```

The kernel's own `md_mod` comes back. A volume with a bitmap then runs without it, as on a kernel without the fix.

### Where it is stored and when it is not used

- The bitmap lives in a part of each member's AMD service area that neither the AMD firmware nor the AMD drivers
  use: 640 KiB per member, 64 MiB a bit for volumes up to 318 TiB. The AMD metadata has no field for it; a header
  of ours marks it ([format.md](format.md)).
- All members of the volume must start at the same LBA. A volume created after another one that uses only some of
  its disks cannot have a bitmap, so create the volumes that span more disks first. Volumes made by
  `mdadm --create` on empty disks always qualify.
- If Windows or the BIOS wrote the volume after Linux, mdadm does not trust the md bitmap: it resyncs what the AMD
  bitmap marks, or the whole volume.
- A volume with a bitmap should not be run by an mdadm without bitmap support (an older build). If that happened,
  give it `--update=no-bitmap` and then `--update=bitmap` before it runs again (`mdadm(8)`).
