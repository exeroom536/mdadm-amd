# mdadm-amd

**AMD RAIDXpert2 arrays on Linux with the kernel's own md — no `rcraid` blob.**

[Русский](README.ru.md) · [Install](docs/install.md) · [Usage](docs/usage.md) · [Testing](docs/testing.md) ·
[Format](docs/format.md)

AMD RAIDXpert2 ("RAIDCore") is the RAID built into AMD chipsets (X399, X570, X670, X870…). Its arrays are made in
the BIOS menu or by the Windows driver and kept in undocumented on-disk metadata; for Linux AMD offers only
`rcraid`, an out-of-tree binary module. This project teaches **mdadm** that format (`--metadata=amd`), the way it
already handles Intel IMSM: md runs the arrays, the disks stay on the stock `ahci`/`nvme` drivers, and `mdmon`
keeps the metadata where the BIOS and Windows expect it.

> [!WARNING]
> **Experimental.** mdadm-amd writes RAID metadata, and a bug can cost you an array. Back up first, try it on spare
> disks first, and never load `rcraid` on the same disks at the same time. It has been tested on one AMD board.

## Features

- **Assemble and run** the arrays the BIOS and Windows make: Volume, RAID0, RAID1, RAID10, RAID5 and RAIDABLE, on
  SATA and NVMe; single-disk Legacy (non-RAID) records are kept as they are.
- **Create** containers and volumes that the BIOS menu and the Windows driver show as Normal.
- **mdmon** keeps the volumes' state, initializes them, and rebuilds onto spares or a returning disk the way the AMD
  driver does; an interrupted rebuild goes on after a reboot from where it stopped.
- **Grow** a RAIDABLE volume into a RAID1, as the AMD migration does.
- **Boot from a volume**: mkinitcpio, initramfs-tools and dracut, with a clean shutdown of the root volume.
- **md write-intent bitmap** for RAID1, RAID10 and RAID5: after a crash only the parts being written are resynced.
- **Repairs** the Legacy record of the system disk that the BIOS menu can break.

| Level | Assemble | Create | Notes |
|---|:---:|:---:|---|
| Volume (linear) | ✓ | ✓ | needs the `md-linear` kernel module |
| RAID0 | ✓ | ✓ | |
| RAID1 | ✓ | ✓ | 2 disks |
| RAID10 | ✓ | ✓ | 2 × n disks |
| RAID5 | ✓ | ✓ | 3 to 8 disks |
| RAIDABLE | ✓ | ✓ | one disk, grows into a RAID1 |
| RAID6, RAID50 | — | — | no AMD platform is known to enable them |

## Quick start

Build and install: see [docs/install.md](docs/install.md) for Arch Linux, Debian and Ubuntu, Fedora, RHEL and its
rebuilds, and openSUSE. On Arch Linux:

```sh
sudo pacman -S --needed base-devel git
git clone https://github.com/exeroom536/mdadm-amd.git
cd mdadm-amd/packaging/arch
cp ../../mdadm/mdadm-amd.patch ../dkms/* .
makepkg -s
sudo pacman -U mdadm-amd-[0-9]*.pkg.tar.zst
```

Arrays made in the BIOS are assembled by udev at boot, or by hand:

```sh
sudo mdadm --assemble --scan
cat /proc/mdstat
sudo mdadm --examine /dev/sda           # what the AMD metadata on a disk says
```

Make a new set of disks and a RAID1 on it:

```sh
sudo mdadm --create /dev/md/amd0 --metadata=amd --raid-devices=4 /dev/sd[abcd] --run
sudo mdadm --create /dev/md/data --level=1 --raid-devices=2 --size=100G /dev/md/amd0
```

More — spares, RAIDABLE, the md bitmap, failed disks, booting — in [docs/usage.md](docs/usage.md).

## Limitations

- One AMD board tested so far; NVMe arrays only in emulation. See [docs/testing.md](docs/testing.md).
- No AMD migrations other than RAIDABLE → RAID1; a volume in the middle of another migration is not assembled.
- No 4Kn disks (AMD has no format for them), no `missing` disks at create, one AMD disk set per system.
- `--create` stays within what the BIOS menu allows (8 disks per volume, 12 arrays); `--force` goes past it.
- The md bitmap on kernels 6.18 and later needs an md fix from `kernel/` ([details](docs/install.md#the-md-bitmap)).

## Documentation

| | |
|---|---|
| [Install](docs/install.md) | building and installing on each distribution, booting from a volume, the md bitmap |
| [Usage](docs/usage.md) | creating and managing arrays, spares, failures, compatibility with the BIOS and Windows |
| [Testing](docs/testing.md) | what was tested where, what was not, what is not supported |
| [Development](docs/development.md) | repository layout, the patch series, the kernel and util-linux patches |
| [Tests](tests/README.md) | the test suite (530 checks on loop devices) and how to run it |
| [Format](docs/format.md) | the on-disk format, with a source for each statement (in Russian) |
| [Firmware bugs](docs/firmware-bugs.md) | known problems of the AMD RAID firmware |
| [Benchmark](docs/benchmark.md) | md against AMD's own Linux and Windows drivers on the same volumes |

## Roadmap

- [x] Assemble, run and create Volume, RAID0, RAID1, RAID10, RAID5 and RAIDABLE volumes
- [x] `mdmon`: initialization, rebuilds onto spares and returning disks, dedicated and global spares
- [x] Boot from a volume (mkinitcpio, initramfs-tools, dracut)
- [x] md write-intent bitmap; RAIDABLE → RAID1 migration
- [ ] Start a volume that the boot does not need, left inactive after booting with a disk missing
- [ ] The md bitmap and TRIM kernel fixes for 6.18 and 7.0 and later, as DKMS modules (today: Linux 7.3.1–7.3.3)
- [ ] Other AMD migrations: expansion, level and stripe size changes
- [ ] Detect XFS, btrfs, LUKS and LVM on a disk at `--add` and `--create` (ext2/3/4 and ReiserFS are detected now)

## How it was made

The code, the tests and the notes on the format were written by **Claude Opus 5.5**, an AI model by Anthropic,
using Claude Code. The whole code was then checked in a separate pass by **Claude Fable 5.2**, which also wrote the
fixes of that pass. The tests on the hardware were run by the models too. No person has reviewed the code. Each
patch of the series says which models wrote it.

The format was worked out for interoperability, from the metadata on our own disks, the firmware modules of our own
board and a public X399 dump; the layout of some structures was cross-checked with the type information (DWARF) in
AMD's Linux SDK, as [joeytroy/amd-raid-driver](https://github.com/joeytroy/amd-raid-driver) did. No AMD code is
copied. Legal basis: the interoperability exceptions (EU Directive 2009/24/EC art. 6, Russian Civil Code art.
1280(2), US DMCA §1201(f)).

## Contributing

Issues are welcome, especially metadata dumps from other boards (`tools/amdraid_dump.py --brief --ring /dev/sdX`).
The project is maintained as time allows, with no guarantees.

Thanks to [joeytroy/amd-raid-driver](https://github.com/joeytroy/amd-raid-driver) and to the authors of
[PlaidPiper/x399-raidcore-fixtures](https://github.com/PlaidPiper/x399-raidcore-fixtures).

## License

GPL-2.0-or-later ([LICENSE](LICENSE)), as mdadm. `util-linux/amd_raid.c`: LGPL-2.1-or-later, as libblkid.
`test-data/x399-raid10-plaidpiper/`: CC0 1.0.
