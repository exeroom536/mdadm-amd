# AMD RAID firmware: known problems

What we found in RAIDCoreDxe, the UEFI driver of AMD RAID, as shipped in the MSI MPG X870E EDGE TI WIFI BIOS
1.A93 (RAIDCoreDxe 9.3.3-00277). Function addresses are offsets in that module, from our disassembly, done for
interoperability only. "Emulation" means QEMU with the board's real RAIDCoreDxe on emulated AMD controllers.

## 1. The NVMe pass-through disk gets a second record and stops booting

**Symptoms.** Seen on the real board on 02.11 and 05.11.2026, after an array was created over all RAID disks in
the BIOS RAID menu, and on 08.11 after Windows with the AMD driver had run:

- the menu shows the NVMe system disk (a Legacy, pass-through disk) as **Offline/Failed**, and a new
  **"Non-RAID"** array of the same size appears;
- the EFI shell lists the disk twice, as `Unit(0x1)` and `Unit(0x4)`, with the same partitions; `Unit(0x1)`
  cannot be read;
- a boot entry for that disk does not boot, and the BIOS returns to its setup.

As long as nothing is changed in the RAID menu, this lives only in the firmware's memory: the next boot is clean.
If the menu writes a configuration in this state (any operation), the damage goes to the RAID disks: the Legacy
record of the NVMe disk becomes OFFLINE with an element ID of `0xFFFFFFFFFFFF`, and a second Legacy record is
added. After that the disk is broken on every boot until the record is repaired.

**Cause.** A rescan of the disks that runs twice without clearing its table:

- the scan (`FUN_00006608`) clears the disk and array tables once, then repeats the discovery up to five times
  while some SATA disk has not finished IDENTIFY yet (`FUN_0001623c`, `FUN_0001b418`);
- on the repeat the NVMe disk is registered again; its ID, a hash of its serial number, collides with its own
  entry from the first pass, and it gets a random 48-bit ID instead (`FUN_00019904`, `FUN_00019aa4`);
- no Legacy array has that ID, so a new Legacy array is created for it (`FUN_0002c130`), while the old one,
  whose element no longer matches a disk (`FUN_0001d234`: handle 0, ID `0xFF…FF`), goes offline.

The rescan runs after operations in the RAID menu and also during boot: a timer polls the AHCI ports every two
seconds (`FUN_0000a654`) and schedules a rescan when a link changes, and so do some ATA pass-through commands
(`FUN_00022280`, for example SECURITY FREEZE LOCK, which the board's disk security module sends at the end of
POST). Whether it goes wrong depends on timing: whether a SATA disk is late with IDENTIFY in that very scan.
Three creations over all disks on 06.11 did not break anything.

**Reproduced** in emulation: the first pass was forced to report a disk as not ready (a breakpoint in the
firmware), then a rescan from the menu gave exactly the picture of the real board (menu, EFI shell, unreadable
`Unit(0x1)`), with nothing written to the disks.

**Probable trigger after Windows (not proven on hardware):** when it shuts down, the AMD Windows driver sends
STANDBY IMMEDIATE to all its disks. After a warm restart the HDDs are still spun down at POST, IDENTIFY is late,
and the scan repeats. After Linux the disks are not stopped on a restart, and the board booted normally.

**What to do.**

- After Windows or WinPE with the AMD driver, shut down and power on again (a cold start), rather than restart.
- If the BIOS stops in its setup or the NVMe disk shows twice: do nothing in the RAID menu (no Rescan, no Create),
  just restart. To boot right away, use the EFI shell and start the boot loader from the file system that
  can be read.
- If the broken record was already written: `tools/amdraid_fix_legacy.py` shows the repair and makes it with
  `--write`; this `mdadm` and `mdmon` also repair it whenever they write the configuration (mdmon when it starts
  for a redundant volume, `mdadm` after `--create`, `--kill-subarray` and `--update-subarray`).

## 2. The firmware rewrites the configuration at boot

**Symptoms.** On 02.11 the firmware wrote a new configuration on the RAID disks during POST, without anything
done in the menu; later boots wrote nothing.

**Cause** (disassembly, checked against the configurations on our disks). When the driver starts, one path writes
the configuration (`RC_UpdateConfig`, `0x28e98`, from the configuration reader at `0x2a194`). It is taken when
the arrays read from the disks do not match what the firmware builds from them, and only the handles are compared
(`FUN_0002b908`):

- an array's handle differs from the slot the firmware gives it: the firmware numbers the arrays 1, 2, 3, … in
  the order of the configuration, Legacy ones too, the second record of an array taking the handle of the
  first. A gap in the numbering, left after an array was deleted, is enough. The rewritten configuration lacks
  the IDs of the physical disk records;
- an element whose disk is missing gets an "offline" handle (`0x9000`, `0x8FFF`, …).

State, flags, cache settings and names do not start a write. A lock (`FUN_000250b8`) forbids any write by the
firmware's RAID core until the next boot when the first reading found the disks or arrays not as recorded (a disk
missing or moved, an array degraded). So a boot with a disk missing writes nothing.

Both writes of 02.11 closed a gap in the numbering: one left by a deletion in the menu, the other by our own
repair script, which had cut out an array without renumbering the rest. Nothing of the NVMe disk is written this
way, and the service areas of the volumes (the md bitmap, the transformation log) are not touched.

**In this mdadm:** every configuration `mdadm` or `mdmon` writes numbers the arrays the way the firmware does,
so a gap left by a deletion (ours, the menu's or an older version's) is closed with the next write, and
`tools/amdraid_fix_legacy.py` does the same. In emulation, with the board's firmware, configurations with a
gap were rewritten at boot and the same ones written by this mdadm were not.
