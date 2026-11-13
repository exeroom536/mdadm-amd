// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * mdadm - support for AMD RAIDXpert2 ("RAIDCore") metadata.
 *
 * The format is undocumented; the layout below was worked out for
 * interoperability from metadata found on our own disks and firmware.
 *
 * What is supported: --examine, --detail and assembly of every volume the
 * AMD RAID BIOS or driver made; Volume (linear) and RAID0 read-write,
 * RAID1/RAID10/RAID5 managed by mdmon (clean/dirty in the AMD bitmap,
 * member failures and missing members, initialization, rebuilds onto AMD
 * global spares and of a returning member into its slot - both go on after
 * a reboot from where md stopped);
 * --create of a container (the disks "initialized" as the BIOS menu does)
 * and of Volume/RAID0/1/10/5 volumes in it; --add, --remove,
 * --kill-subarray, --update-subarray (name, the AMD driver's cache
 * policy); Legacy (pass-through) records the BIOS menu broke are repaired.
 * Disks are taken only behind controllers the AMD firmware uses for RAID
 * (EFI variable AMD_RAID), unless --force.
 *
 * On-disk layout, little-endian, 512-byte sectors:
 *   LBA 0x5000         RC_MetaData: per-disk label, "RAIDCore", DeviceId
 *   LBA 0x5001         RC_ConfigCommit: names the live config packet
 *   LBA 0x5800-0x5fff  ring of config packets, the newest one is live
 * A config packet is a header followed by physical device (PD) records,
 * logical device (LD) records - each with its element array - and
 * controller/enclosure records.  All of them are covered by a 64-bit
 * xor checksum.  The LD element array is FirstCount x SecondCount:
 * stripe width x number of mirrors (or disks per parity set).
 */

#include "mdadm.h"
#include "drive_encryption.h"
#include "mapfile.h"
#include "mdmon.h"
#include "mdstat.h"
#include "part.h"
#include "platform-intel.h"
#include "sha1.h"
#include "xmalloc.h"

#include <stddef.h>
#include <ctype.h>
#include <limits.h>
#include <dirent.h>
#include <scsi/sg.h>
#include <linux/major.h>
#include <linux/nvme_ioctl.h>

#define AMD_SECTOR		512
#define AMD_METADATA_LBA	0x5000
#define AMD_COMMIT_LBA		0x5001
#define AMD_RING_LBA		0x5800
#define AMD_RING_END		0x6000
#define AMD_MAX_PACKET		(1024 * 1024)
#define AMD_DEFAULT_ALLOC_LBA	0x100000	/* where volumes start */
#define AMD_SERVICE		0x5000	/* AllocatedSpace in front of user data */
#define AMD_SERVICE_BYTES	(AMD_SERVICE * AMD_SECTOR)
#define AMD_MIB			0x800		/* sectors */
/*
 * The controller serial number of the AMD BIOS and Windows driver alike: a
 * constant in RAIDCoreDxe (0x1700), and on the disks of every AMD system
 * (X399, ASRock X670E, MSI X870E, the Windows driver in a VM).  The
 * Windows driver gets it from its virtual controller, vendor 0x8590 device
 * 0x1022 (rcraid.sys 9.3.3.218 @14000fe6c: vendor << 32 | device << 16).
 * The AMD driver for Linux has the halves the other way round, 0x102285900000
 * (rcblob RC_STH_DiscoverAdapter, 9.3.2 to 9.3.3-00302): the BIOS and the
 * Windows driver take what it writes for a foreign configuration.
 */
#define AMD_SERIAL		0x859010220000ULL

#define AMD_RC_IDENT		0x65726f4344494152ULL	/* "RAIDCore" */
#define AMD_RC_VERSION		0x30000
#define AMD_HEADER_KEY		0xe1e10000ULL

#define AMD_DST_PD		0x25bc
#define AMD_DST_LD		0x25bd

/* RC_DeviceType of a PD record */
#define AMD_DEV_RAIDCORE_DISK	0x1200
#define AMD_DEV_RAIDCORE_CORE	0x1201
#define AMD_DEV_LEGACY		0x1203

#define AMD_DEV_STATE_ONLINE	0x3000
#define AMD_DEV_STATE_OFFLINE	0x3001

/* RC_LogicalDeviceTypes */
#define AMD_LDT_RAID50		0x1bf5	/* RAID5 when FirstCount == 1 */
#define AMD_LDT_RAID10N		0x1bf6	/* RAID0, RAID1, RAID10 */
#define AMD_LDT_VOLUME		0x1bf7
#define AMD_LDT_RAW		0x1bf8
#define AMD_LDT_LEGACY		0x1bf9
#define AMD_LDT_RAID60		0x1bfa	/* RAID6 when FirstCount == 1 */
#define AMD_LDT_RAIDABLE	0x1bfb

#define AMD_LD_STATE_NORMAL	0x200
#define AMD_LD_STATE_CRITICAL	0x201
#define AMD_LD_STATE_OFFLINE	0x202
#define AMD_LD_STATE_LOCKED	0x204	/* a member behind an ATA password (rcraid.sys 9.3.3.291) */

/* Attribute bits */
#define AMD_ATTR_BITMAP		0x1	/* the volume keeps a write-intent bitmap */

/* RC_LogicalDevice.Cache: the AMD driver's cache (RAIDCoreDxe FUN_0001d234, FUN_000158d4) */
#define AMD_CACHE_READ		0x80000000	/* menu "Read Cache": read-ahead */
#define AMD_CACHE_WRITE_BACK	0x40000000	/* menu "Write Back Cache" */

/* write-intent bitmap: one sector, on element [0][0] */
#define AMD_BITMAP_OFFSET	0x80	/* from AllocatedSpace.SectorOffset */
#define AMD_BITMAP_BYTES	512

/*
 * Element flags for a member out of service, as the AMD driver records them
 * (rcblob): a member it fails on I/O errors gets 0x10
 * (RC_SignalDriveErrorWithLogicalElement @0013b2c0); a member without its
 * disk gets 0x20 "offline" (RC_ValidateLogicalElement @0012f1e0), which
 * becomes 0x30 on the first write (RC_UpdateDriveErrors @0012f080).  X399
 * ring: both in one packet.  Never write 0x20 without 0x10: the AMD
 * driver drops 0x20 (and 0x4000) of a member whose disk is there and
 * current, and takes it back without a rebuild (RC_ValidateLogicalElement,
 * rcraid.sys 9.3.3.218 @14002379c); 0x10 stays until the user recovers it.
 * Of a RAID0 or Volume it keeps no 0x10 at all (@140018b80).
 */
#define AMD_ELEMENT_FAILED	0x10
#define AMD_ELEMENT_MISSING	0x20
#define AMD_ELEMENT_OFFLINE	0x30
/*
 * The failure is committed to the configuration (rcblob
 * RC_UpdateCommitDriveErrors); the ring of an X399 RAID10 has a failed
 * member of the LD being rebuilt into as 0x8010.
 */
#define AMD_ELEMENT_FAIL_COMMITTED	0x8000

/* RC_TransformTypes / RC_TransformState */
#define AMD_TRANSFORM_NORMAL	0x5354	/* a migration: level, size, disks (rcadm -T) */
#define AMD_TRANSFORM_CREATE_REDUNDANCY	0x5355	/* initialization of a new volume */
#define AMD_TRANSFORM_RESTORE_SEGMENTS	0x5358	/* rebuild onto a spare */
#define AMD_TRANSFORM_STARTED	0xa1a1
#define AMD_TRANSFORM_FAILED	0xa1a4
#define AMD_TRANSFORM_COMPLETED	0xa1a6
#define AMD_PERCENT_DONE	100000	/* TransformPercentDone: all of it */

/*
 * RC_LogicalDevice.Flags set while RESTORE_SEGMENTS runs (the ring of an
 * X399 RAID10); the LD a migration starts from has the same SRC flags
 * (rcraid 9.3.3 midway through RAIDABLE -> RAID1).
 */
#define AMD_LDF_RESTORE_SRC	0x20010
#define AMD_LDF_RESTORE_DST	0x10020000
#define AMD_LDF_TRANSFORM	0x10020094	/* cleared when it ends */
/* the source LD in the "100 %" packet (m1, m2): rcblob sets Flags = 0x80, then |= 4 */
#define AMD_LDF_TRANSFORM_DONE	0x84

/* SpareInfo of a PD: a global hot spare */
#define AMD_SPARE_GLOBAL	0x100

/* element flags that take a member out of service */
#define AMD_ELEMENT_UNUSABLE	0x4030

#define AMD_MAX_PD		64
#define AMD_MAX_VOL		48

/* a DeviceID nobody has (Legacy LDs the BIOS menu broke, dropped members) */
#define AMD_ID_NONE		0xffffffffffffffffULL

/*
 * A disk's Handle (Handle.Internal) is a slot the AMD software gives it -
 * RAIDCoreDxe its table index + 1, the Windows driver the first free one
 * from 0 (RAIDCoreDxe FUN_00015c10, rcraid.sys FUN_1400033cc) - not the
 * port the BIOS menu shows: on the MSI X870E a disk on menu port 1 has
 * Handle 3.  An LD's Handle is its number in the packet, from 1.
 */
struct amd_dev_id {
	__u64 id;
	__u16 handle;
	__u16 routing;
	__u32 reserved;
} __attribute__((packed));

struct amd_space {
	__u64 offset;		/* sectors */
	__u64 size;
} __attribute__((packed));

struct amd_metadata {		/* LBA 0x5000 */
	__u64 checksum;		/* over 0x08..0x1ff */
	__u64 ident;
	__u64 device_id;
	__u64 commit_offset;
	__u64 ring_offset;
	__u32 ring_size;
	__u32 version;
	__u32 features;
	__u32 spare_info;
	__u64 mbr_checksum;
	__u32 reserved[112];
} __attribute__((packed));

struct amd_commit {		/* LBA 0x5001 */
	__u64 checksum;		/* over 0x08..0x1ff */
	__u32 packet_offset;	/* LBA */
	__u32 packet_size;	/* bytes */
	__u64 committed_checksum; /* checksum of the live packet */
	__u64 generation;
	__u64 last_modifier_sn;
	__u64 last_online_sn;
	__u64 packet_number;	/* writes to this disk */
	__u32 committed_by;
	__u32 reserved[113];
} __attribute__((packed));

struct amd_packet_header {
	__u64 checksum;		/* over 0x0c..packet_size */
	__u32 prev_offset;	/* per disk, not checksummed */
	__u64 header_key;
	__u32 version;
	__u32 packet_size;
	__u64 modifier_sn;	/* controller serial number */
	__u32 pd_offset;
	__u32 pd_size;
	__u32 ld_offset;
	__u32 ld_size;
	__u64 generation;
	__u32 wait_accept;
	__u32 ctrl_offset;
	__u32 ctrl_size;
	__u32 sep_offset;
	__u32 sep_size;
	__u32 reserved[108];
} __attribute__((packed));

struct amd_pd {
	__u32 type;		/* AMD_DST_PD */
	struct amd_dev_id id;
	__u32 prev_handle;
	__u32 devices;
	__u64 capacity;
	__u32 device_type;
	__u32 bus_type;
	__u32 device_state;
	__u32 spare_info;
	struct amd_space start_md;
	struct amd_space end_md;
	__u32 features;
	__u32 port_type;
	__u32 reserved[9];
} __attribute__((packed));

#define AMD_NAME_LEN		32	/* RC_LogicalDevice.Name */

struct amd_ld {
	__u32 type;		/* AMD_DST_LD */
	__u32 element_offset;
	__u32 state;
	__u32 device_type;
	__u32 transform_type;
	__u32 last_operation;
	__u32 transform_state;
	struct amd_dev_id cluster_id;
	struct amd_dev_id id;
	struct amd_dev_id invalidate_id;
	__u32 prev_handle;
	__u64 capacity;
	__u64 transform_protect_start;
	__u64 generation;
	__u32 devices;
	__u32 first_count;	/* stripe width */
	__u32 second_count;	/* mirrors, or disks per parity set */
	__u32 parent_count;
	__u32 transform_flags;
	__u32 transform_protect_size;
	__u32 cache;
	__u32 flags;
	__u32 transform_link;	/* 1: the next LD belongs to this one */
	__u32 spare_count;
	__u32 packet_size;
	__u32 transform_percent;
	__u32 attribute;
	__u32 last_repair_count;
	__u32 distributed_spare;
	__u32 prefer_read_element;
	__u32 task_priority;
	__u32 chunk_size;
	__u8  name[AMD_NAME_LEN];
	__u32 reference_count;
	__u64 copy_from_id;
	__u64 copy_to_id;
	__u64 qsync_element_id;
	struct amd_space qsync_space;
	__u64 cold_id;
	__u64 hot_id;
	__u32 tier_pages;
	__u32 cache_tag_size;	/* 1: 64KiB, 2: 128KiB, 3: 256KiB per disk */
	__u32 reserved[59];
} __attribute__((packed));

struct amd_element {
	struct amd_dev_id id;
	struct amd_space allocated;
	struct amd_space user_data;
	__u32 flags;
	__u32 reserved[3];
} __attribute__((packed));

_Static_assert(sizeof(struct amd_metadata) == AMD_SECTOR, "RC_MetaData");
_Static_assert(sizeof(struct amd_commit) == AMD_SECTOR, "RC_ConfigCommit");
_Static_assert(sizeof(struct amd_packet_header) == AMD_SECTOR, "RC_ConfigPacketHeader");
_Static_assert(sizeof(struct amd_pd) == 0x80, "RC_PhysicalDeviceOnDisk");
_Static_assert(sizeof(struct amd_ld) == 0x200, "RC_LogicalDevice");
/*
 * Transform log of a volume (RC_TransformLogStruct_LE): one sector at
 * AllocatedSpace + 0 of each element of stripe column 0 of the LD being
 * transformed into.  The AMD driver resumes a transform from it.
 */
struct amd_tlog {
	__u64 checksum;		/* over 0x08..0x67, Reserved fields as 0 */
	struct amd_dev_id id;	/* the volume */
	__u32 type;
	__u64 protect_start;	/* volume sectors below this are done */
	__u64 io_start;
	__u32 io_size;
	__u32 flags;
	__u32 protect_size;
	__u32 current_stripe;
	__u32 dynamic_protect_stripe;
	__u32 log_update_stripe;
	__u32 status;
	struct amd_dev_id copy_to;
	__u64 copy_start;
	__u64 copy_size;
} __attribute__((packed));

#define AMD_TLOG_STARTED	1
#define AMD_TFLAGS_RESTORE	0x241	/* TransformFlags of RESTORE_SEGMENTS */
#define AMD_TFLAGS_CREATE	0x211	/* of CREATE_REDUNDANCY (menu, mdadm -C) */
/*
 * RAIDABLE -> RAID1 as rcraid 9.3.3-00302 runs it (seen midway):
 * TransformFlags of both LDs and of the log, and the log's I/O unit - its
 * protect window (0x4800) is 12 of them.
 */
#define AMD_TFLAGS_GROW		0x02022241
#define AMD_GROW_IO_SIZE	0x600

_Static_assert(sizeof(struct amd_element) == 0x40, "RC_LogicalElement_LE");
_Static_assert(sizeof(struct amd_tlog) == 0x68, "RC_TransformLogStruct_LE");

/* A disk we have read */
/*
 * An element a disk has in service in its own packet: its volume, and
 * where the data is.  Kept as on disk (little-endian), only compared.
 */
struct amd_own {
	__u64 ld;
	struct amd_space user_data;
};

struct amd_disk {
	struct amd_disk *next;
	int major, minor;
	char *devname;
	unsigned long long sectors;
	__u64 device_id;
	__u32 features;
	__u32 label_spare;	/* SpareInfo of its label (0x100: a global spare) */
	int commit_valid;
	__u64 generation;
	__u64 packet_number;
	__u64 committed_checksum;
	__u32 packet_lba;	/* where this disk's live packet is */
	__u32 packet_size;
	int fd;			/* open for writing (container only), or -1 */
	int update;		/* amd_write_config: gets the new packet */
	__u32 new_lba;
	/* md failed it (a member, or a rebuild onto it): not again until back */
	int spare_failed;
	int write_failed;	/* a configuration write to it failed: stale until back */
	int rejoin;		/* a former member rebuilt in place: gets configs again */
	int removed;		/* taken out of the container (mdmon): gone, as missing */
	int fresh;		/* mdadm --add initialized it: no configuration yet */
	__u64 last_online;	/* LastOnlineSerialNumber of its commit block */
	int foreign;		/* ... not AMD_SERIAL: last online on another controller */
	int mbr;		/* LBA 0 against its label: AMD_MBR_* */
	struct amd_own own[AMD_MAX_VOL];	/* amd_note_own */
	int nown;
};

/*
 * LBA 0 of a RAIDCore disk as the AMD driver checks it (rcraid.sys
 * 9.3.3.218 RC_ReadMBR @14001fa6c, = rcblob RC_ReadMBR): the label's
 * MBRChecksum must be the checksum of the sector or, if it is 0, the type
 * of the first partition must be 0x82.  If not, the BIOS and the Windows
 * driver do not take the disk for a RAID disk: it is Legacy or not
 * initialized, it drops out of its volumes, and the Windows driver lays a
 * Legacy LD over the whole disk (RC_AddLegacyLogicalDevice @140019344).
 */
#define AMD_MBR_OK	0	/* as AMD wants it (or not read) */
#define AMD_MBR_SUM	1	/* AMD's partition table, another checksum */
#define AMD_MBR_OTHER	2	/* something else: GPT, another table, none */

/* the one partition AMD writes in LBA 0 (RAIDCoreDxe FUN_00016e28) */
#define AMD_MBR_TYPE	0x82
#define AMD_MBR_START	0x3f	/* its first sector */

/*
 * Updates about one disk, for mdmon (amd_process_update):
 *  - REMOVE: it left the container (mdadm --remove, udev -If);
 *  - ADD: mdadm --add initialized it - a new global spare, or a former
 *    member given back (@known);
 *  - ATTACH (struct amd_update_attach): it joined the container.
 */
#define AMD_UPDATE_SPARE	1	/* struct amd_update_spare */
#define AMD_UPDATE_CREATE	2	/* struct amd_update_create */
#define AMD_UPDATE_REMOVE	3
#define AMD_UPDATE_ADD		4
#define AMD_UPDATE_ATTACH	5	/* amd_update_attach */
#define AMD_UPDATE_KILL		6	/* mdadm --kill-subarray: @major = volume, @id = its LD */
#define AMD_UPDATE_SUBARRAY	7	/* mdadm --update-subarray: struct amd_update_subarray */
#define AMD_UPDATE_ROLE		8	/* a spare role: struct amd_update_role */
#define AMD_UPDATE_GROW		9	/* --grow a RAIDABLE: @major = volume, @id = LD */
struct amd_update_role {
	int type;
	int vol;		/* the volume, or -1: the global role */
	__u64 vol_id;		/* LD ID of @vol */
	__u64 id;		/* the disk */
	int add;		/* 1: assign a dedicated spare, 0: unassign */
	int pad;
};

struct amd_update_disk {
	int type;
	int major, minor;
	int known;
	__u32 features;
	__u64 id;
	__u64 sectors;
};

struct amd_update_attach {
	int type;
	int fd;			/* the monitor's now: kept by the disk, or closed */
	int major, minor;
	int commit_valid;
	__u32 features;
	__u32 spare_info;	/* of the label */
	__u32 packet_lba, packet_size;
	__u64 id;		/* from the label, 0: no RAIDCore label */
	__u64 sectors;
	__u64 generation, packet_number, committed_checksum;
	__u64 last_online;
	int mbr;
	/* zeroed, for a disk new to us: the monitor's now, taken or freed */
	struct amd_disk *disk;
};

/*
 * mdmon's state of a volume: what it has seen md do, and how much of that
 * is on disk yet.  amd_open_new() sets it up; amd_parse_packet() builds the
 * rest of struct amd_vol from the packet and clears this, so amd_reparse()
 * carries it over whole.
 */
struct amd_vol_mon {
	int bitmap_dirty;	/* AMD write-intent bitmap has bits set */
	int bitmap_want;	/* state to write at the next sync_metadata */
	unsigned int bitmap_dirty_from;	/* ... from this bit to the end */
	unsigned int bitmap_from;	/* ... from this bit to the end */
	unsigned long long resync_ckpt;	/* resync after a crash, volume sectors */
	unsigned long long ckpt_seen;	/* the monitor's checkpoint, last call */
	int members_checked;	/* the members md runs without are recorded (amd_mark_missing) */
	int init_done;		/* md finished the init: record that at sync_metadata */
	int rebuilding;		/* md recovers onto a spare, element rebuild_el */
	int rebuild_slot;
	int rebuild_done;	/* md finished it: record that at sync_metadata */
	struct amd_element rebuild_el;
	int rebuild_recorded;	/* RESTORE_SEGMENTS and its log are on disk */
	unsigned long long rebuild_ckpt; /* member sectors md has recovered */
	int tlog_dirty;		/* write rebuild_ckpt to the transform log */
	int tlog_restart;	/* md wrote without the recorded target: log it from 0 */
	int target_away;	/* ... the target is not in md (amd_target_away) */
	unsigned long long md_writes;	/* sectors md had written at open_new */
	unsigned long long init_ckpt;	/* volume sectors md has initialized */
	int init_tlog;		/* 1: write init_ckpt to the log, 2: clear it */
	unsigned int md_bitmap;	/* md runs its md bitmap: sectors a bit, or 0 */
	int mdbm_drop;		/* ... no room for a spare at its LBA: md is to stop it */
	int mdbm_wipe;		/* ... stopped so: clear its headers */
	__u64 mdbm_gen;		/* generation the headers say, 0: to be written */
	__u64 mdbm_sum;		/* ... and config checksum */
	__u32 mdbm_amd;		/* ... and AMD bitmap */
	unsigned int trim_gran;	/* TRIM capped (amd_limit_trim): discard_granularity before */
};

/* A logical device exposed as an md array */
struct amd_vol {
	struct amd_ld *ld;
	struct amd_ld *link;	/* second copy of the LD while a transform runs */
	struct amd_element *el;
	int nel;
	int level, layout, raid_disks;
	int chunk_sectors;
	unsigned long long component_size;
	int readonly;
	int managed;		/* mdmon keeps its state in the AMD metadata */
	int single;		/* RAIDABLE: md raid1 of its one member, no bitmap */
	int grow;		/* RAIDABLE -> RAID1 recorded: @link is the RAID1 */
	int init_pending;	/* CREATE_REDUNDANCY not completed: md resyncs */
	struct amd_vol_mon mon;
	const char *blocked;	/* why it cannot be assembled */
};

struct amd_super {
	struct amd_disk *disks;
	void *packet;		/* live config packet */
	unsigned int packet_len;
	unsigned int packet_room;	/* bytes allocated for it */
	void *next_packet;	/* mdmon: AMD_MAX_PACKET bytes it moves into (amd_mm_room) */
	__u64 generation;
	__u64 serial;		/* controller serial number */
	__u64 container_id;	/* lowest DeviceId among RAIDCore disks */
	struct amd_pd *pd[AMD_MAX_PD];
	int npd;
	struct amd_vol vol[AMD_MAX_VOL];
	int nvol;
	int current_vol;
	int config_dirty;	/* the packet changed, write it out */
	int legacy_checked;	/* mdmon: start-up writes decided (amd_sync_metadata) */
	int foreign;		/* the live packet is from a disk last online elsewhere */
	int from_md;		/* the disks of a running container (amd_load_md) */
	int attached;		/* add_to_super took a disk in, nothing to init */
	int add_checked;	/* mdadm --add: amd_check_add passed, the disk may be initialized */
	__u64 add_id;		/* mdadm --add: DeviceID the disk had, if it was ours */
	void *iobuf;		/* one sector, for mdmon's writes */
	/* ... for reads and writes under amd_lock by managemon (and mdadm) */
	void *mmbuf;
	/* mdmon: the LD a rebuild goes into is made here (amd_rebuild_ld) */
	void *ldbuf;
	unsigned int ldbuf_room;
	bool busy;		/* mdmon: a thread works on it (amd_lock) */
	/* --create */
	int creating;		/* AMD_CREATE_CONTAINER: disks being initialized */
	struct amd_disk *cur_disk;	/* the disk add_to_super took last */
	int new_vol;		/* the volume being created, or -1 */
	int add_slot;		/* its member add_to_super was given last, or -1 */
	struct amd_disk *layout[AMD_MAX_PD];	/* its disks, by slot */
	int npick;		/* of them, given on the command line */
	int fill;		/* no size asked: a Volume takes all the room of each disk */
	int whole;		/* it is a RAIDABLE: one whole disk free of volumes */
	unsigned int new_mdbm;	/* --bitmap=internal: its md bitmap, sectors a bit */
	bool new_mdbm_clean;	/* ... --assume-clean: no bit set */
};

static int amd_open_new(struct supertype *c, struct active_array *a, int inst);
static void amd_mm_room(struct amd_super *super);
static void amd_lock(struct amd_super *super);
static void amd_unlock(struct amd_super *super);
static void amd_ld_clear_transform(struct amd_ld *ld);
static void amd_end_transform(struct amd_super *super, int vol, __u32 op,
			      __u32 tstate);
static void amd_cut_ld(struct amd_super *super, unsigned int at,
		       unsigned int size);
static void amd_trim_packet(struct amd_super *super);
static int amd_extent_given_away(struct amd_super *super,
				 const struct amd_vol *v, int slot);
static void amd_reparse(struct amd_super *super);
static void amd_reparse_without(struct amd_super *super, int gone);
static int amd_drop_dedicated(struct amd_super *super, int vol, __u64 id);
static struct amd_disk *amd_find_spare(struct amd_super *super,
				       struct amd_vol *v, int slot,
				       struct amd_element *el, int *recorded);
static int amd_spare_count(struct amd_super *super, struct amd_vol *v);
static void amd_apply_role(struct amd_super *super,
			   const struct amd_update_role *u);
static int amd_label_spare(int fd, __u64 id, __u32 spare);
static int amd_pd_index(struct amd_super *super, __u64 id);
static int amd_disk_in_volumes(struct amd_super *super, __u64 id);
static void amd_kmsg(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

/*
 * Checksum used by every RAIDCore structure: xor of 64-bit words, each
 * with two of its 16-bit lanes swapped.  The lanes come from the low bits
 * of the word and of the running sum, or from the word index if those
 * are equal.
 */
static __u64 amd_checksum(const void *buf, size_t len)
{
	const __u8 *p = buf;
	__u64 acc = 0;
	size_t i;

	for (i = 0; i < len / 8; i++) {
		unsigned int a, b;
		__u64 w, la, lb;

		memcpy(&w, p + i * 8, 8);
		w = __le64_to_cpu(w);
		a = w & 3;
		b = acc & 3;
		if (a == b) {
			a = i & 3;
			b = (i + 1) & 3;
		}
		la = (w >> (16 * a)) & 0xffff;
		lb = (w >> (16 * b)) & 0xffff;
		w &= ~((0xffffULL << (16 * a)) | (0xffffULL << (16 * b)));
		w |= (lb << (16 * a)) | (la << (16 * b));
		acc ^= w;
	}
	return acc;
}

/* checksum of a one-sector structure (label, commit block): the bytes after its own */
static __u64 amd_sector_sum(const void *sector)
{
	return amd_checksum((const char *)sector + 8, AMD_SECTOR - 8);
}

/* a RAIDCore label with a valid checksum */
static int amd_label_valid(const struct amd_metadata *md)
{
	return __le64_to_cpu(md->ident) == AMD_RC_IDENT &&
	       __le64_to_cpu(md->checksum) == amd_sector_sum(md);
}

static int amd_read(int fd, unsigned long long lba, void *buf, size_t len)
{
	ssize_t n;

	/* from the metadata it may be anything: not past what an off_t holds */
	if (lba > LLONG_MAX / AMD_SECTOR)
		return -1;
	n = pread(fd, buf, len, (off_t)lba * AMD_SECTOR);
	return n == (ssize_t)len ? 0 : -1;
}

static void *amd_alloc(size_t len)
{
	void *buf;

	if (posix_memalign(&buf, AMD_SECTOR, len) != 0)
		return NULL;
	memset(buf, 0, len);
	return buf;
}

/* open the disk @major:@minor, as dev_open() takes it */
static int amd_dev_open(int major, int minor, int flags)
{
	char nm[32];

	snprintf(nm, sizeof(nm), "%d:%d", major, minor);
	return dev_open(nm, flags);
}

/*
 * The capacity AMD gives a RAIDCore disk of @sectors: past the first
 * 0x100000 sectors, whole 0x40000 (128 MiB) - rcblob RCS_AlignDriveSize,
 * rcraid.sys 9.3.3.218 @140001498, called by RC_ReadMBR for RAID disks
 * only; the PD records of the BIOS have it too (HDD 1 TB, 1953525168
 * sectors: 1953497088; a Legacy disk keeps its full size).  Volumes lie
 * within it.
 */
static unsigned long long amd_align_capacity(unsigned long long sectors)
{
	if (sectors <= AMD_DEFAULT_ALLOC_LBA)
		return sectors;
	return ((sectors - AMD_DEFAULT_ALLOC_LBA) & ~0x3ffffULL) +
	       AMD_DEFAULT_ALLOC_LBA;
}

/*
 * Where extents on the RAIDCore disk of @pd (@sectors big) may reach: its
 * PD Capacity, but not past the aligned size - an older mdadm recorded the
 * full size, and the AMD driver goes by the aligned one (it rewrites the
 * PD so).  @pd may be NULL.
 */
static unsigned long long amd_pd_capacity(const struct amd_pd *pd,
					  unsigned long long sectors)
{
	unsigned long long cap = amd_align_capacity(sectors);

	if (pd && pd->capacity && __le64_to_cpu(pd->capacity) < cap)
		cap = __le64_to_cpu(pd->capacity);
	return cap;
}

/*
 * PacketSize of LD record @ld by its counts (RAIDCoreDxe FUN_00006a80,
 * FUN_00025f74): the record, its elements, its parent references and its
 * dedicated spares.  0 if a count is out of the range RAIDCoreDxe takes
 * reading an LD (FUN_000248ac; SpareCount: FUN_000249bc).
 */
static unsigned int amd_ld_size(const struct amd_ld *ld)
{
	__u32 f = __le32_to_cpu(ld->first_count);
	__u32 s = __le32_to_cpu(ld->second_count);
	__u32 p = __le32_to_cpu(ld->parent_count);
	__u32 sp = __le32_to_cpu(ld->spare_count);

	if (f == 0 || f > 0x100 || s == 0 || s > 0x40 ||
	    p == 0 || p > 0x10 || sp > 4)
		return 0;
	return sizeof(struct amd_ld) + sizeof(struct amd_element) * f * s +
	       sizeof(struct amd_dev_id) * (p + sp);
}

static int amd_chunk_sectors(const struct amd_ld *ld)
{
	switch (__le32_to_cpu(ld->cache_tag_size)) {
	case 3:
		return 512;
	case 2:
		return 256;
	default:
		return 128;
	}
}

static const char *amd_ld_type_name(__u32 type)
{
	switch (type) {
	case AMD_LDT_RAID50:	return "RAID50";
	case AMD_LDT_RAID10N:	return "RAID10N";
	case AMD_LDT_VOLUME:	return "VOLUME";
	case AMD_LDT_RAW:	return "RAW";
	case AMD_LDT_LEGACY:	return "LEGACY";
	case AMD_LDT_RAID60:	return "RAID60";
	case AMD_LDT_RAIDABLE:	return "RAIDABLE";
	default:		return "unknown";
	}
}

static const char *amd_pd_type_name(__u32 type)
{
	switch (type) {
	case AMD_DEV_RAIDCORE_CORE:	return "ctrl";
	case AMD_DEV_RAIDCORE_DISK:	return "raid";
	case AMD_DEV_LEGACY:		return "legacy";
	default:			return "other";
	}
}

static int amd_element_usable(const struct amd_element *el)
{
	return el->id.id && !(__le32_to_cpu(el->flags) & AMD_ELEMENT_UNUSABLE);
}

static struct amd_element *amd_ld_elements(const struct amd_ld *ld)
{
	return (struct amd_element *)((char *)ld +
				      __le32_to_cpu(ld->element_offset));
}

/* elements of @ld: FirstCount x SecondCount */
static int amd_ld_nel(const struct amd_ld *ld)
{
	return __le32_to_cpu(ld->first_count) *
	       __le32_to_cpu(ld->second_count);
}

static struct amd_element *amd_link_elements(const struct amd_vol *v)
{
	return amd_ld_elements(v->link);
}

/* elements of the second LD copy of @v, 0 if there is none */
static int amd_link_nel(const struct amd_vol *v)
{
	return v->link ? amd_ld_nel(v->link) : 0;
}

/* @v has a second LD copy with the elements of the first, slot for slot */
static int amd_link_same_shape(const struct amd_vol *v)
{
	return v->link && v->link->first_count == v->ld->first_count &&
	       v->link->second_count == v->ld->second_count;
}

static int amd_same_geometry(const struct amd_ld *a, const struct amd_ld *b)
{
	const struct amd_element *ea, *eb;
	unsigned int i, n;

	if (a->device_type != b->device_type ||
	    a->first_count != b->first_count ||
	    a->second_count != b->second_count ||
	    a->capacity != b->capacity ||
	    a->cache_tag_size != b->cache_tag_size)
		return 0;
	/*
	 * Members in service in both copies sit at the same place.  A slot
	 * out of service in either copy may differ: it is empty, or being
	 * rebuilt (RESTORE_SEGMENTS has the spare in the second copy only).
	 */
	n = amd_ld_nel(a);
	ea = amd_ld_elements(a);
	eb = amd_ld_elements(b);
	for (i = 0; i < n; i++)
		if (amd_element_usable(&ea[i]) && amd_element_usable(&eb[i]) &&
		    (ea[i].id.id != eb[i].id.id ||
		     memcmp(&ea[i].allocated, &eb[i].allocated,
			    sizeof(ea[i].allocated)) != 0 ||
		     memcmp(&ea[i].user_data, &eb[i].user_data,
			    sizeof(ea[i].user_data)) != 0))
			return 0;
	return 1;
}

/*
 * The dedicated spares of an LD: SpareCount device identifiers (ID, Handle,
 * RoutingPath 1) after its parent references.  The AMD menu writes them in
 * the first LD copy only; the disk itself is not marked (its SpareInfo
 * stays 0).
 */
static struct amd_dev_id *amd_ld_spares(const struct amd_ld *ld)
{
	struct amd_dev_id *parents;

	parents = (struct amd_dev_id *)(amd_ld_elements(ld) + amd_ld_nel(ld));
	return parents + __le32_to_cpu(ld->parent_count);
}

/* the volume @id is a dedicated spare of, or -1 */
static int amd_dedicated_owner(const struct amd_super *super, __u64 id)
{
	int vol, i;

	for (vol = 0; vol < super->nvol; vol++) {
		const struct amd_ld *ld = super->vol[vol].ld;
		const struct amd_dev_id *sp = amd_ld_spares(ld);

		for (i = 0; i < (int)__le32_to_cpu(ld->spare_count); i++)
			if (__le64_to_cpu(sp[i].id) == id)
				return vol;
	}
	return -1;
}

/*
 * Slot @i of @v is in service in the LD and, while a transform runs, in
 * its second copy too: the AMD BIOS takes a stale member out of the second
 * copy only, and a rebuild target is not in service until the rebuild is
 * recorded as done.
 */
static int amd_slot_usable(const struct amd_vol *v, int i)
{
	if (!amd_element_usable(&v->el[i]))
		return 0;
	if (amd_link_same_shape(v))
		return amd_element_usable(&amd_link_elements(v)[i]);
	return 1;
}

/*
 * Element @i of @v was failed on errors (0x10 without the 0x20 of a
 * member found offline) in the LD or its second copy.
 */
static int amd_slot_failed(const struct amd_vol *v, int i)
{
	__u32 flags = __le32_to_cpu(v->el[i].flags);

	if (amd_link_same_shape(v))
		flags |= __le32_to_cpu(amd_link_elements(v)[i].flags);
	return (flags & AMD_ELEMENT_OFFLINE) == AMD_ELEMENT_FAILED;
}

/*
 * The slot the transform recorded for @v copies onto, or -1: of a
 * RESTORE_SEGMENTS, the one out of service in the LD and in service in the
 * second copy (the ring of an X399 RAID10); of a RAIDABLE growing into a
 * RAID1, its mirror, the slot past its one element (amd_grow_link).
 */
static int amd_rebuild_slot(const struct amd_vol *v)
{
	int i;

	if (v->grow)
		return v->nel;
	if (!amd_link_same_shape(v) ||
	    __le32_to_cpu(v->ld->transform_type) != AMD_TRANSFORM_RESTORE_SEGMENTS)
		return -1;
	for (i = 0; i < v->nel; i++)
		if (!amd_element_usable(&v->el[i]) &&
		    amd_element_usable(&amd_link_elements(v)[i]))
			return i;
	return -1;
}

/*
 * md slot @slot of @v is one AMD has a place for: an element's, or the
 * mirror a RAIDABLE grows by (mdadm --grow --raid-devices=2, or a migration
 * the AMD driver started).
 */
static int amd_md_slot(const struct amd_vol *v, int slot)
{
	return slot < v->nel || (slot == v->nel && (v->single || v->grow));
}

/*
 * The rebuild md runs on @v is the mirror a RAIDABLE grows by: to the AMD
 * driver a migration (NORMAL into a RAID1 LD), not a RESTORE_SEGMENTS.
 */
static int amd_rebuild_grows(const struct amd_vol *v)
{
	return v->mon.rebuild_slot >= v->nel;
}

/*
 * RAIDABLE @v is being made a RAID1 the way the AMD driver does it (rcadm -T
 * -r1 under rcraid 9.3.3-00302, seen midway):
 * the LD with TransformType NORMAL and TransformLink 1, then the RAID1 it
 * becomes - 1 x 2, the same ID and capacity, element [0][0] the RAIDABLE's
 * own, [0][1] the new mirror, as large.  md runs that as a recovery of the
 * mirror.  Any other migration it cannot run.
 */
static int amd_grow_link(const struct amd_vol *v)
{
	const struct amd_ld *t = v->link;
	const struct amd_element *tel;

	if (!t || __le32_to_cpu(v->ld->transform_type) != AMD_TRANSFORM_NORMAL ||
	    __le32_to_cpu(t->device_type) != AMD_LDT_RAID10N ||
	    __le32_to_cpu(t->first_count) != 1 ||
	    __le32_to_cpu(t->second_count) != 2 ||
	    t->id.id != v->ld->id.id || t->capacity != v->ld->capacity)
		return 0;
	tel = amd_link_elements(v);
	return tel[0].id.id == v->el[0].id.id &&
	       memcmp(&tel[0].allocated, &v->el[0].allocated,
		      sizeof(tel[0].allocated)) == 0 &&
	       memcmp(&tel[0].user_data, &v->el[0].user_data,
		      sizeof(tel[0].user_data)) == 0 &&
	       amd_element_usable(&tel[0]) && amd_element_usable(&tel[1]) &&
	       tel[1].user_data.size == v->el[0].user_data.size;
}

/*
 * The md level, layout and members of @v from its device type and its First
 * x Second elements; @data_disks: how many members' user data make up the
 * capacity.  0 with v->blocked set if md cannot run that type.
 */
static int amd_classify_level(struct amd_vol *v,
			      unsigned long long *data_disks)
{
	int f = __le32_to_cpu(v->ld->first_count);
	int s = __le32_to_cpu(v->ld->second_count);

	switch (__le32_to_cpu(v->ld->device_type)) {
	case AMD_LDT_RAID10N:
		if (s == 1) {
			v->level = 0;
			v->raid_disks = f;
			*data_disks = f;
			v->readonly = 0;
		} else if (f == 1) {
			v->level = 1;
			v->raid_disks = s;
			*data_disks = 1;
		} else {
			v->level = 10;
			v->layout = (1 << 8) | s;	/* near copies */
			v->raid_disks = f * s;
			*data_disks = f;
		}
		return 1;
	case AMD_LDT_RAID50:
		if (f != 1 || s < 3) {
			v->blocked = "RAID50 is not supported";
			return 0;
		}
		v->level = 5;
		v->layout = ALGORITHM_RIGHT_ASYMMETRIC;
		v->raid_disks = s;
		*data_disks = s - 1;
		return 1;
	case AMD_LDT_RAID60:
		/*
		 * RAIDCoreDxe and the AMD drivers know RAID6 (its Q is an
		 * EVENODD code md cannot produce), but no AMD platform
		 * enables it.
		 */
		v->blocked = "RAID6 is not supported";
		return 0;
	case AMD_LDT_RAIDABLE:
		/*
		 * "RAID aware single disk for future redundancy": the menu
		 * gives it one whole free disk, 1 x 1, no chunk, laid out as
		 * its Volume; the AMD driver creates it as a Volume and makes
		 * a RAID1 of it later by a migration (rcraid.sys 9.3.3.218
		 * @140025364; rcadm -T under the AMD Linux driver keeps the
		 * member where it is and adds the mirror).  So md raid1 of
		 * one member: the same layout, in every kernel (md linear
		 * only from 6.14), and what md grows into a mirror.
		 */
		if (f != 1 || s != 1) {
			v->blocked = "a RAIDABLE volume on more than one disk is not supported";
			return 0;
		}
		v->level = 1;
		v->chunk_sectors = 0;
		*data_disks = 1;
		if (amd_grow_link(v)) {
			v->grow = 1;
			v->raid_disks = 2;
			return 1;
		}
		v->raid_disks = 1;
		v->single = 1;
		return 1;
	case AMD_LDT_VOLUME:
		/*
		 * Concatenation: the user data of element [i][0] follows that
		 * of [i-1][0], each element its own size, no chunk (rcblob
		 * RC_VolumeLogicalToPhysical, RC_AllocateLogicalElementSpace:
		 * First = members, Second = 1).  md linear, like RAID0 run
		 * without mdmon: AMD keeps no state for it but OFFLINE.
		 */
		if (s != 1) {
			v->blocked = "a Volume with SecondCount > 1 is not supported";
			return 0;
		}
		v->level = LEVEL_LINEAR;
		v->raid_disks = f;
		v->chunk_sectors = 0;
		v->readonly = 0;
		return 1;
	default:
		v->blocked = "unsupported volume type";
		return 0;
	}
}

/*
 * The members of linear @v, each its own size, add up to its capacity.
 * 0 with v->blocked set if not.
 */
static int amd_linear_size(struct amd_vol *v)
{
	unsigned long long sum = 0;
	int i;

	/* md's component_size: the smallest member (it must fit them all) */
	v->component_size = 0;
	for (i = 0; i < v->nel; i++) {
		unsigned long long size = __le64_to_cpu(v->el[i].user_data.size);

		sum += size;
		if (amd_slot_usable(v, i) && size &&
		    (v->component_size == 0 || size < v->component_size))
			v->component_size = size;
	}
	if (v->component_size == 0) {
		v->blocked = "no member in service";
		return 0;
	}
	if (sum != __le64_to_cpu(v->ld->capacity)) {
		v->blocked = "capacity does not match the layout";
		return 0;
	}
	return 1;
}

/*
 * The members of striped or mirrored @v are of one size, a multiple of the
 * chunk, and @data_disks of them make up its capacity.  0 with v->blocked
 * set if not.
 */
static int amd_equal_size(struct amd_vol *v, unsigned long long data_disks)
{
	int i;

	/* an empty slot (the BIOS writes ID 0, size 0) has no size */
	v->component_size = 0;
	for (i = 0; i < v->nel; i++) {
		unsigned long long size = __le64_to_cpu(v->el[i].user_data.size);

		if (!amd_slot_usable(v, i))
			continue;
		if (v->component_size == 0)
			v->component_size = size;
		if (size != v->component_size) {
			v->blocked = "members differ in size";
			return 0;
		}
	}
	if (v->component_size == 0) {
		v->blocked = "no member in service";
		return 0;
	}
	if (v->level != 1 && v->component_size % v->chunk_sectors) {
		v->blocked = "member size is not a multiple of the chunk";
		return 0;
	}
	if (data_disks * v->component_size != __le64_to_cpu(v->ld->capacity)) {
		v->blocked = "capacity does not match the layout";
		return 0;
	}
	return 1;
}

/* mdmon manages @v, or md runs it read-only: by its state and transform */
static void amd_classify_state(struct amd_vol *v)
{
	struct amd_ld *ld = v->ld;
	__u32 state;
	int transform;

	/*
	 * A volume the AMD BIOS has just created has State 0 until the next
	 * config write, and RAIDXpert2 shows it as normal.  It also carries
	 * a CREATE_REDUNDANCY transform that only the OS driver runs; for
	 * mirrors md does it as a resync.
	 */
	state = __le32_to_cpu(ld->state);
	if (state == 0)
		state = AMD_LD_STATE_NORMAL;
	/*
	 * The AMD driver for Windows (9.3.3.291) marks a volume LOCKED while a
	 * member is locked by its ATA password (AmdRaidPassword unlocks it at
	 * boot).  Locked, the disk cannot be read: here it is missing, and md
	 * judges the members it has, as for a critical volume.  A LOCKED left
	 * in the metadata once the disk was unlocked costs nothing then.
	 */
	if (state == AMD_LD_STATE_LOCKED)
		state = AMD_LD_STATE_CRITICAL;
	v->init_pending = __le32_to_cpu(ld->transform_type) ==
			  AMD_TRANSFORM_CREATE_REDUNDANCY &&
		__le32_to_cpu(ld->transform_state) != AMD_TRANSFORM_COMPLETED;
	/*
	 * An initialization or a rebuild left unfinished goes on from the
	 * volume's transform log (amd_tlog_read).  Any other transform is an
	 * AMD migration: only RAIDABLE -> RAID1 is supported (v->grow), with
	 * any other the volume is not assembled.
	 */
	transform = ld->transform_type && !v->init_pending &&
		__le32_to_cpu(ld->transform_type) != AMD_TRANSFORM_RESTORE_SEGMENTS &&
		__le32_to_cpu(ld->transform_state) != AMD_TRANSFORM_COMPLETED &&
		ld->transform_state;
	if (v->single || v->grow) {
		/*
		 * md raid1 needs mdmon for its clean/active transitions even
		 * with one member; an AMD RAIDABLE keeps no write-intent
		 * bitmap (attribute 0), so there is nothing to record but
		 * failures.  Growing into a RAID1 it has the RAID1's
		 * (amd_bitmap_disk), and mdmon records the migration.
		 */
		v->managed = state == AMD_LD_STATE_NORMAL && (!transform || v->grow);
		v->readonly = !v->managed;
	} else if (v->level == 0 || v->level == LEVEL_LINEAR) {
		v->readonly = state != AMD_LD_STATE_NORMAL || transform;
	} else if ((v->level == 1 || v->level == 10 || v->level == 5) &&
		   !transform &&
		   (__le32_to_cpu(ld->attribute) & AMD_ATTR_BITMAP) &&
		   (state == AMD_LD_STATE_NORMAL ||
		    state == AMD_LD_STATE_CRITICAL)) {
		/*
		 * Mirrors and RAID5: mdmon records dirty/clean in the AMD
		 * write-intent bitmap and member failures in the config
		 * packet.  RAID5 is md raid5 right-asymmetric, checked against
		 * the AMD Windows driver (rcraid.sys 9.3.3): md check finds the
		 * parity it writes right, and it reads what md wrote with a
		 * member missing, through md's parity.
		 */
		v->managed = 1;
		v->readonly = 0;
	} else {
		v->readonly = 1;
	}
}

/*
 * The extent of element @el is where the AMD BIOS and drivers put one: past
 * the metadata of the disk, the service area (AMD_SERVICE sectors) in front
 * of the user data, the user data within it.  Every element of a volume in
 * the configurations we have seen is so (RAIDCoreDxe, rcraid.sys, rcraid,
 * mdadm).  Offsets and sizes read from a disk may be anything, and mdmon
 * writes the transform log and the bitmaps of the volume into that area.
 */
static int amd_extent_sane(const struct amd_element *el)
{
	unsigned long long at = __le64_to_cpu(el->allocated.offset);
	unsigned long long size = __le64_to_cpu(el->allocated.size);
	unsigned long long data = __le64_to_cpu(el->user_data.offset);
	unsigned long long dsize = __le64_to_cpu(el->user_data.size);

	/* its end, in bytes, fits an off_t */
	const unsigned long long max = LLONG_MAX / AMD_SECTOR / 2;

	if (at > max || size > max)
		return 0;
	return at >= AMD_RING_END && size >= AMD_SERVICE &&
	       data == at + AMD_SERVICE && dsize <= size - AMD_SERVICE;
}

/* ... of every element of @v with a disk, and of those of its second copy */
static int amd_extents_sane(const struct amd_vol *v)
{
	const struct amd_element *el = v->el;
	int i, n = v->nel, copy;

	for (copy = 0; copy < 2; copy++) {
		for (i = 0; i < n; i++)
			if (el[i].id.id && !amd_extent_sane(&el[i]))
				return 0;
		if (!v->link)
			break;
		el = amd_link_elements(v);
		n = amd_link_nel(v);
	}
	return 1;
}

/* Work out how md should run this logical device. */
static void amd_classify(struct amd_vol *v)
{
	unsigned long long data_disks = 0;
	int sizes_ok;

	v->chunk_sectors = amd_chunk_sectors(v->ld);
	v->readonly = 1;
	if (!amd_classify_level(v, &data_disks))
		return;
	if (v->level == LEVEL_LINEAR)
		sizes_ok = amd_linear_size(v);
	else
		sizes_ok = amd_equal_size(v, data_disks);
	if (sizes_ok)
		amd_classify_state(v);
}

/* end of the LD section of the packet, not past the packet */
static unsigned int amd_ld_end(const struct amd_super *super)
{
	const struct amd_packet_header *h = super->packet;
	unsigned int end = __le32_to_cpu(h->ld_offset) + __le32_to_cpu(h->ld_size);

	return end < super->packet_len ? end : super->packet_len;
}

/* Is there room for one more LD record at offset @off of the LD section? */
static int amd_ld_follows(const struct amd_super *super, unsigned int off)
{
	return off + sizeof(struct amd_ld) <= amd_ld_end(super);
}

/*
 * PacketSize and ElementOffset of LD record @ld are what its counts make
 * them.  RAIDCoreDxe stops reading the LD list at a record that is not so
 * (FUN_00028810), and so do we.
 */
static int amd_ld_valid(const struct amd_ld *ld)
{
	return __le32_to_cpu(ld->packet_size) == amd_ld_size(ld) &&
	       __le32_to_cpu(ld->element_offset) == sizeof(struct amd_ld);
}

/*
 * The LD record at offset *@off of the packet, and *@off moves past it.
 * NULL at the end of the LD list: no room for a record there, no whole LD
 * record within the section, or a record that is not valid (amd_ld_valid) -
 * its elements may be anywhere.  Every walk over the LD list goes by it,
 * so they all end where the parser does.
 */
static struct amd_ld *amd_next_ld(const struct amd_super *super,
				  unsigned int *off)
{
	struct amd_ld *ld;
	unsigned int size;

	if (!amd_ld_follows(super, *off))
		return NULL;
	ld = (struct amd_ld *)((char *)super->packet + *off);
	size = amd_ld_size(ld);
	if (__le32_to_cpu(ld->type) != AMD_DST_LD || size == 0 ||
	    !amd_ld_valid(ld) || *off + size > amd_ld_end(super))
		return NULL;
	*off += size;
	return ld;
}

/*
 * A member whose PD the AMD driver dropped (it ran without the disk: the
 * element stays) is still a disk of the container: its own stale packet
 * lists it, and the container UUID must not change.
 */
static void amd_dropped_container_id(struct amd_super *super)
{
	int vol, i, j;

	for (vol = 0; vol < super->nvol; vol++)
		for (i = 0; i < super->vol[vol].nel; i++) {
			__u64 id = __le64_to_cpu(super->vol[vol].el[i].id.id);

			if (!id || id == AMD_ID_NONE ||
			    (super->container_id && id >= super->container_id))
				continue;
			for (j = 0; j < super->npd; j++)
				if (__le64_to_cpu(super->pd[j]->id.id) == id)
					break;
			if (j == super->npd)
				super->container_id = id;
		}
}

/* Index the PD and LD records of the live packet. */
static void amd_parse_packet(struct amd_super *super)
{
	struct amd_packet_header *h = super->packet;
	char *p = super->packet;
	unsigned int len = super->packet_len;
	unsigned int off, end;
	struct amd_ld *ld;

	super->npd = 0;
	super->nvol = 0;
	super->container_id = 0;
	if (!h)
		return;
	super->serial = __le64_to_cpu(h->modifier_sn);

	off = __le32_to_cpu(h->pd_offset);
	end = off + __le32_to_cpu(h->pd_size);
	if (end > len)
		end = len;
	for (; off + sizeof(struct amd_pd) <= end && super->npd < AMD_MAX_PD;
	     off += sizeof(struct amd_pd)) {
		struct amd_pd *pd = (struct amd_pd *)(p + off);
		__u64 id = __le64_to_cpu(pd->id.id);

		if (__le32_to_cpu(pd->type) != AMD_DST_PD)
			break;
		super->pd[super->npd++] = pd;
		if (__le32_to_cpu(pd->device_type) == AMD_DEV_RAIDCORE_DISK &&
		    (super->container_id == 0 || id < super->container_id))
			super->container_id = id;
	}

	off = __le32_to_cpu(h->ld_offset);
	while (super->nvol < AMD_MAX_VOL && (ld = amd_next_ld(super, &off))) {
		__u32 type = __le32_to_cpu(ld->device_type);
		struct amd_ld *link = NULL;
		struct amd_vol *v;

		/* the second copy follows, unless the section ends here */
		if (__le32_to_cpu(ld->transform_link) == 1 &&
		    amd_ld_follows(super, off)) {
			link = amd_next_ld(super, &off);
			if (!link)
				break;
		}
		if (type == AMD_LDT_LEGACY || type == AMD_LDT_RAW)
			continue;

		v = &super->vol[super->nvol++];
		memset(v, 0, sizeof(*v));
		v->ld = ld;
		v->link = link;
		v->el = amd_ld_elements(ld);
		v->nel = amd_ld_nel(ld);
		amd_classify(v);
		if (!v->blocked && !amd_extents_sane(v))
			v->blocked = "member extents are not where AMD puts them";
		if (link && !v->blocked && !v->grow && !amd_same_geometry(ld, link))
			v->blocked = "a migration is in progress";
		/*
		 * Spare space on the members themselves (rcblob
		 * RC_ValidateLogicalElementSpace): a rebuild into it changes
		 * the layout.  The platforms we know lack feature bit 0x10
		 * and the AMD driver takes such a volume offline
		 * (RC_ValidateLogicalDevice, "offline due to dist. spare").
		 */
		if (!v->blocked && ld->distributed_spare)
			v->blocked = "a distributed spare is not supported";
	}
	amd_dropped_container_id(super);
}

/*
 * Is this a commit block the AMD driver would read a configuration by?
 * (rcblob RC_CheckConfigCommit, RC_UpdateCorePhysicalDevice; the same in
 * rcraid.sys 9.3.3.218 @140062e44, @1400226d4): a valid checksum that is
 * not 0 ("INVALID"), ConfigPacketOffset 1..0x6000, PacketSize below 1 MiB.
 * The driver does not require the packet to end within the ring, and
 * neither do we; we also require the packet to hold at least its header.
 */
static int amd_check_commit(const struct amd_commit *c)
{
	__u32 lba = __le32_to_cpu(c->packet_offset);
	__u32 size = __le32_to_cpu(c->packet_size);

	if (!c->checksum || __le64_to_cpu(c->checksum) != amd_sector_sum(c))
		return 0;
	if (size < sizeof(struct amd_packet_header) || size >= AMD_MAX_PACKET)
		return 0;
	if (lba < 1 || lba > AMD_RING_END)
		return 0;
	return 1;
}

/*
 * The PD and LD sections lie in the packet, after its header, the LDs after
 * the PDs; the controller and enclosure sections (25BE, 25BF) end in it too:
 * what is put into the packet goes behind them (amd_sections_end,
 * amd_packet_insert), and with one past the end mdmon could record neither
 * a spare nor a rebuild.  Read from a disk the offsets may be anything:
 * 64-bit sums, so that none wraps around.
 */
static int amd_packet_sane(const struct amd_packet_header *h,
			   unsigned int len)
{
	unsigned long long pd = __le32_to_cpu(h->pd_offset);
	unsigned long long pd_end = pd + __le32_to_cpu(h->pd_size);
	unsigned long long ld = __le32_to_cpu(h->ld_offset);
	unsigned long long ld_end = ld + __le32_to_cpu(h->ld_size);
	unsigned long long ctrl_end = (unsigned long long)
		__le32_to_cpu(h->ctrl_offset) + __le32_to_cpu(h->ctrl_size);
	unsigned long long sep_end = (unsigned long long)
		__le32_to_cpu(h->sep_offset) + __le32_to_cpu(h->sep_size);

	return pd >= sizeof(*h) && pd_end <= ld && ld_end <= len &&
	       ctrl_end <= len && sep_end <= len;
}

/*
 * The packet of @size bytes (at least its header) at @lba, if its header
 * key, PacketSize and checksum are right; else NULL.
 */
static struct amd_packet_header *amd_read_packet_at(int fd, __u32 lba,
						    __u32 size)
{
	size_t buflen = ROUND_UP(size, AMD_SECTOR);
	struct amd_packet_header *h = amd_alloc(buflen);

	if (!h)
		return NULL;
	if (amd_read(fd, lba, h, buflen) != 0 ||
	    __le64_to_cpu(h->header_key) != AMD_HEADER_KEY ||
	    __le32_to_cpu(h->packet_size) != size ||
	    __le64_to_cpu(h->checksum) !=
	    amd_checksum((char *)h + 0x0c, size - 0x0c)) {
		free(h);
		return NULL;
	}
	return h;
}

/* the live packet commit block @c names (amd_check_commit passed) */
static void *amd_read_packet(int fd, const struct amd_commit *c)
{
	__u32 size = __le32_to_cpu(c->packet_size);
	struct amd_packet_header *h;

	h = amd_read_packet_at(fd, __le32_to_cpu(c->packet_offset), size);
	if (h && (h->checksum != c->committed_checksum ||
		  !amd_packet_sane(h, size))) {
		free(h);
		return NULL;
	}
	return h;
}

/* the PD records of a packet: index 0 is the controller itself */
static struct amd_pd *amd_packet_pds(void *packet, unsigned int len, int *n)
{
	struct amd_packet_header *h = packet;

	*n = 0;
	if (!amd_packet_sane(h, len))
		return NULL;
	*n = __le32_to_cpu(h->pd_size) / sizeof(struct amd_pd);
	return (struct amd_pd *)((char *)packet + __le32_to_cpu(h->pd_offset));
}

static int amd_pds_broken(const struct amd_pd *pd, int n)
{
	int i;

	for (i = 1; i < n; i++)
		if (__le32_to_cpu(pd[i].type) == AMD_DST_PD && pd[i].id.id == 0)
			return 1;
	return 0;
}

/*
 * The size of the packet at @lba of the ring, from its header: 0 if there
 * is none, or it would not end within the ring.
 */
static __u32 amd_ring_packet_size(int fd, __u32 lba)
{
	struct amd_packet_header *h = amd_alloc(AMD_SECTOR);
	__u32 size = 0;

	if (h && amd_read(fd, lba, h, AMD_SECTOR) == 0 &&
	    __le64_to_cpu(h->header_key) == AMD_HEADER_KEY) {
		size = __le32_to_cpu(h->packet_size);
		if (size < AMD_SECTOR || size > AMD_MAX_PACKET ||
		    lba + (size + AMD_SECTOR - 1) / AMD_SECTOR > AMD_RING_END)
			size = 0;
	}
	free(h);
	return size;
}

/*
 * Take DeviceID, Handle, BusType and Features of PDs 1..@n-1 back from the
 * @on PD records @old, if they are the same list (count, capacities).
 */
static int amd_restore_pds(struct amd_pd *pd, int n, const struct amd_pd *old,
			   int on)
{
	int i;

	if (on != n)
		return 0;
	for (i = 1; i < n; i++)
		if (old[i].capacity != pd[i].capacity ||
		    old[i].type != pd[i].type)
			return 0;
	for (i = 1; i < n; i++) {
		pd[i].id = old[i].id;
		pd[i].bus_type = old[i].bus_type;
		pd[i].features = old[i].features;
	}
	return 1;
}

/*
 * RAIDCoreDxe's own config writes at boot leave DeviceID, Handle, BusType
 * and Features of the PD records unset, and put its version string over
 * PD 1: FUN_00028ae8 never fills them in (seen as it recorded a stale disk
 * and a rebuild as RESTORE_SEGMENTS).  The AMD driver rebuilds them from
 * the disks; we take them back from the newest earlier packet of this
 * disk's ring that has them and the same PD list (count, capacities).
 * Device type, state and SpareInfo stay as written.
 */
static void amd_repair_pds(int fd, void *packet, unsigned int len)
{
	struct amd_packet_header *h = packet;
	struct amd_pd *pd, *old;
	__u32 lba = __le32_to_cpu(h->prev_offset);
	int n, on, step;

	pd = amd_packet_pds(packet, len, &n);
	if (!pd || !amd_pds_broken(pd, n))
		return;
	for (step = 0; step < 16 && lba >= AMD_RING_LBA && lba < AMD_RING_END;
	     step++) {
		__u32 osize = amd_ring_packet_size(fd, lba);
		struct amd_packet_header *o;

		o = osize ? amd_read_packet_at(fd, lba, osize) : NULL;
		if (!o)
			return;
		old = amd_packet_pds(o, osize, &on);
		if (old && !amd_pds_broken(old, on)) {
			if (amd_restore_pds(pd, n, old, on))
				dprintf("PD records restored from the packet at %#x\n",
					lba);
			free(o);
			return;
		}
		lba = __le32_to_cpu(o->prev_offset);
		free(o);
	}
}

/*
 * Creating a volume in the RAIDXpert2 menu over all the RAID disks (MSI
 * X870E 1.A93, RAIDCoreDxe 9.3.3: RAID10 and RAID5 on 4 HDDs) breaks the
 * Legacy LD of a disk without metadata: State OFFLINE, its element
 * DeviceID all ones and Handle 0; the firmware then adds another Legacy LD
 * with a new ID that breaks the same way.  It no longer ties the disk to an
 * LD and does not offer it for boot.  A good record differs only in these
 * three fields.
 */
static int amd_legacy_broken(const struct amd_ld *ld)
{
	const struct amd_element *el = (const struct amd_element *)(ld + 1);

	return __le32_to_cpu(ld->state) != AMD_LD_STATE_NORMAL ||
	       el->id.id == AMD_ID_NONE;
}

/* the Legacy PD with DeviceID @id (little-endian, as in the packet), or -1 */
static int amd_legacy_pd(const struct amd_super *super, __u64 id)
{
	int i;

	for (i = 0; i < super->npd; i++)
		if (super->pd[i]->id.id == id &&
		    __le32_to_cpu(super->pd[i]->device_type) == AMD_DEV_LEGACY)
			return i;
	return -1;
}

/*
 * For each Legacy PD without a good Legacy LD: bring back the LD with the
 * ID of the PD (or the first broken one of its capacity) - State NORMAL,
 * the element the PD itself - and drop the other broken Legacy LDs of
 * that capacity: then the BIOS offers the disk for boot again (MSI X870E).
 * The Legacy LD of a disk has the ID of its PD, the extra ones the firmware
 * adds have random IDs (every packet of the dumps): a broken record with
 * the ID of another Legacy PD - a second Legacy disk of that capacity - is
 * that disk's, to repair or to keep.  With @fix 0 only count.  Returns the
 * number of LD records changed or dropped.
 *
 * mdmon repairs them once all RAID disks are here; mdadm with every
 * configuration it writes itself (-C, --kill-subarray, --update-subarray
 * without mdmon): mdmon runs only for a redundant volume, and a RAID0 or
 * Volume made in the menu over all the RAID disks breaks the record too.
 */
static int amd_repair_legacy(struct amd_super *super, int fix)
{
	struct amd_packet_header *h = super->packet;
	int i, changes = 0;

	if (!h)
		return 0;
	for (i = 0; i < super->npd; i++) {
		struct amd_pd *pd = super->pd[i];
		__u64 pid = pd->id.id;	/* both sides little-endian */
		__u16 handle = pd->id.handle;
		__u64 cap = pd->capacity;
		unsigned int broken[16], nb = 0, keep = 0, off, k;
		char *p = super->packet;
		struct amd_element *el;
		struct amd_ld *ld;
		int good = 0;

		if (__le32_to_cpu(pd->device_type) != AMD_DEV_LEGACY)
			continue;
		off = __le32_to_cpu(h->ld_offset);
		while ((ld = amd_next_ld(super, &off))) {
			el = (struct amd_element *)(ld + 1);
			if (__le32_to_cpu(ld->device_type) == AMD_LDT_LEGACY &&
			    __le32_to_cpu(ld->first_count) == 1 &&
			    __le32_to_cpu(ld->second_count) == 1) {
				if (!amd_legacy_broken(ld) && el->id.id == pid)
					good = 1;
				else if (amd_legacy_broken(ld) && ld->capacity == cap &&
					 (el->id.id == pid || el->id.id == AMD_ID_NONE) &&
					 (ld->id.id == pid ||
					  amd_legacy_pd(super, ld->id.id) < 0) &&
					 nb < ARRAY_SIZE(broken))
					broken[nb++] = (char *)ld - p;
			}
		}
		if (nb == 0)
			continue;
		changes += nb;
		if (!fix)
			continue;
		if (!good) {
			for (k = 0; k < nb; k++)
				if (((struct amd_ld *)(p + broken[k]))->id.id == pid) {
					keep = k;
					break;
				}
			ld = (struct amd_ld *)(p + broken[keep]);
			el = (struct amd_element *)(ld + 1);
			ld->state = __cpu_to_le32(AMD_LD_STATE_NORMAL);
			el->id.id = pid;
			el->id.handle = handle;
			amd_kmsg("Legacy record of disk %016llx (handle %u) repaired",
				 (unsigned long long)__le64_to_cpu(pid),
				 __le16_to_cpu(handle));
		}
		/* from the end, so that the offsets before stay valid */
		for (k = nb; k-- > 0;) {
			ld = (struct amd_ld *)(p + broken[k]);
			if (!good && k == keep)
				continue;
			amd_kmsg("broken extra Legacy record %012llx of disk %016llx dropped",
				 (unsigned long long)__le64_to_cpu(ld->id.id),
				 (unsigned long long)__le64_to_cpu(pid));
			amd_cut_ld(super, broken[k], amd_ld_size(ld));
		}
		amd_trim_packet(super);
		amd_reparse(super);
	}
	return changes;
}

static struct amd_disk *amd_find_disk(struct amd_super *super, __u64 id)
{
	struct amd_disk *d;

	for (d = super->disks; d; d = d->next)
		if (d->device_id == id)
			return d;
	return NULL;
}

/*
 * A descriptor to read @d through: the container's, or one opened here,
 * which the caller closes (it is not d->fd).
 */
static int amd_disk_fd(const struct amd_disk *d)
{
	return d->fd >= 0 ? d->fd : amd_dev_open(d->major, d->minor, O_RDONLY);
}

/*
 * A disk that missed configuration updates (lower generation, or another
 * packet under the same generation) may hold stale data: it must not
 * take part in a volume as an in-sync member.
 */
static int amd_disk_current(struct amd_super *super,
			    const struct amd_disk *d)
{
	struct amd_packet_header *h = super->packet;

	return h && d->commit_valid && d->generation == super->generation &&
	       d->committed_checksum == __le64_to_cpu(h->checksum) &&
	       d->foreign == super->foreign;
}

/*
 * @d has an older configuration of the set's own history: a lower
 * generation, last online on the same controller.  Not another packet
 * under the live generation: that one was written apart from the others.
 */
static int amd_disk_behind(struct amd_super *super, const struct amd_disk *d)
{
	return super->packet && d->commit_valid &&
	       d->generation < super->generation &&
	       d->foreign == super->foreign;
}

/*
 * A volume without redundancy - RAID0, Volume, RAIDABLE - never ran
 * without one of its members: a member that missed configurations missed
 * no write to the volume, and its older generation does not keep it out
 * (amd_volume_disk).  Not while a transform is recorded: the disk may
 * have missed where that got to.
 */
static int amd_volume_plain(const struct amd_vol *v)
{
	return !v->blocked && !v->link && (v->level <= 0 || v->single);
}

/*
 * The elements @d has in service in the packet @super is parsed from - its
 * own one, or the one just committed to it.
 */
static void amd_note_own(struct amd_disk *d, const struct amd_super *super)
{
	int vol, i;

	d->nown = 0;
	for (vol = 0; vol < super->nvol; vol++) {
		const struct amd_vol *v = &super->vol[vol];

		for (i = 0; i < v->nel && d->nown < AMD_MAX_VOL; i++) {
			if (__le64_to_cpu(v->el[i].id.id) != d->device_id ||
			    !amd_slot_usable(v, i))
				continue;
			d->own[d->nown].ld = v->ld->id.id;
			d->own[d->nown].user_data = v->el[i].user_data;
			d->nown++;
		}
	}
}

/* amd_note_own() from @packet of @len bytes, the disk's own, parsed aside */
static void amd_note_own_packet(struct amd_disk *d, void *packet,
				unsigned int len)
{
	struct amd_super *one = xcalloc(1, sizeof(*one));

	one->packet = packet;
	one->packet_len = len;
	amd_parse_packet(one);
	amd_note_own(d, one);
	free(one);
}

/* @d's own packet has element @el of @v in service, at the same place */
static int amd_disk_had(const struct amd_disk *d, const struct amd_vol *v,
			const struct amd_element *el)
{
	int i;

	for (i = 0; i < d->nown; i++)
		if (d->own[i].ld == v->ld->id.id &&
		    memcmp(&d->own[i].user_data, &el->user_data,
			   sizeof(el->user_data)) == 0)
			return 1;
	return 0;
}

/*
 * The AMD driver picks the live configuration among the disks last online
 * on its own controller only (LastOnlineSerialNumber = its serial number,
 * the same on every AMD system); the others are "foreign" (ConfigFlags
 * 0x1002) and none of their elements is bound (rcblob
 * RC_UpdateCorePhysicalDevice, RC_ValidateLogicalElement; rcraid.sys
 * 9.3.3.218 @1400226d4, @14002379c).  We prefer them the same way, but a
 * set made only of foreign disks still yields its own configuration, so
 * that the data can be reached.
 */
static int amd_packet_better(struct amd_super *super, int foreign,
			     __u64 generation)
{
	if (!super->packet)
		return 1;
	if (foreign != super->foreign)
		return !foreign;
	return generation > super->generation;
}

/*
 * What AMD makes of LBA 0 of a RAIDCore disk (@sector, its label @md):
 * AMD_MBR_*.  AMD_MBR_SUM: the table is the one AMD writes - one
 * partition, type 0x82 from sector 0x3F (RAIDCoreDxe FUN_00016e28, the
 * Windows driver's RC_WriteRAIDCoreBootRecord @140024270) - and the rest
 * of the sector changed (boot code, disk signature).
 */
static int amd_mbr_state(const __u8 *sector, const struct amd_metadata *md)
{
	const struct MBR *pt = (const struct MBR *)sector;
	__u64 want = __le64_to_cpu(md->mbr_checksum);
	int i;

	if (want ? amd_checksum(sector, AMD_SECTOR) == want :
		   pt->parts[0].part_type == AMD_MBR_TYPE)
		return AMD_MBR_OK;
	if (pt->magic != MBR_SIGNATURE_MAGIC ||
	    pt->parts[0].part_type != AMD_MBR_TYPE ||
	    __le32_to_cpu(pt->parts[0].first_sect_lba) != AMD_MBR_START)
		return AMD_MBR_OTHER;
	for (i = 1; i < MBR_PARTITIONS; i++)
		if (pt->parts[i].part_type)
			return AMD_MBR_OTHER;
	return AMD_MBR_SUM;
}

static int amd_read_mbr_state(int fd, const struct amd_metadata *md)
{
	__u8 *sector = amd_alloc(AMD_SECTOR);
	int rv = AMD_MBR_OK;	/* unreadable: say nothing */

	if (sector && amd_read(fd, 0, sector, AMD_SECTOR) == 0)
		rv = amd_mbr_state(sector, md);
	free(sector);
	return rv;
}

/* the disk holding this element, if it is present and up to date */
static struct amd_disk *amd_member_disk(struct amd_super *super, __u64 id)
{
	struct amd_disk *d = amd_find_disk(super, id);

	return d && amd_disk_current(super, d) ? d : NULL;
}

/*
 * @d can be a member in sync of @v, whose element @el in service it holds.
 * Up to date - or, for a volume without redundancy, with an older
 * configuration too.  A power cut between the commit blocks of two disks
 * (amd_write_config), or a configuration written for another volume
 * before this disk came (-I per disk), leaves a member so with its data
 * whole, and nothing else would start the volume.  As IMSM, where the
 * members are those of the newest copy's table whatever their own
 * generation (container_content_imsm).  But only if the disk's own packet
 * has that element of that volume too: a disk taken to another system,
 * where the volume was deleted and another made in its place, comes back
 * with an older generation as well, and a write to the volume it left
 * would land in the one made there.  A mirror or a RAID5 does run without
 * a member, and the AMD driver drops a disk with an older generation from
 * its volumes: there the rule stays (amd_member_disk).
 */
static int amd_disk_serves(struct amd_super *super, const struct amd_disk *d,
			   const struct amd_vol *v,
			   const struct amd_element *el)
{
	return amd_disk_current(super, d) ||
	       (amd_volume_plain(v) && amd_disk_behind(super, d) &&
		amd_disk_had(d, v, el));
}

/* the disk of element @el in service of @v, if it is a member (amd_disk_serves) */
static struct amd_disk *amd_volume_disk(struct amd_super *super,
					const struct amd_vol *v,
					const struct amd_element *el)
{
	struct amd_disk *d = amd_find_disk(super, __le64_to_cpu(el->id.id));

	return d && amd_disk_serves(super, d, v, el) ? d : NULL;
}

static void amd_add_disk(struct amd_super *super, struct amd_disk *disk)
{
	struct amd_disk **dp = &super->disks;

	while (*dp)
		dp = &(*dp)->next;
	*dp = disk;
}

static void amd_free_disk(struct amd_disk *d)
{
	if (d->fd >= 0)
		close(d->fd);
	free(d->devname);
	free(d);
}

/*
 * @disk, just read, has the DeviceID of @old: a copy of a disk, both
 * attached.  One of them is the disk of the set: the one with the newer
 * commit block (md wrote to it since), of two alike the one read first -
 * which is a matter of device names, so say which is left out.  Returns 1
 * if that is @old, now gone from @super.
 */
static int amd_copy_replaces(struct amd_super *super, struct amd_disk *old,
			     struct amd_disk *disk)
{
	int newer = disk->commit_valid > old->commit_valid ||
		    (disk->commit_valid == old->commit_valid &&
		     (disk->generation > old->generation ||
		      (disk->generation == old->generation &&
		       disk->packet_number > old->packet_number)));
	struct amd_disk *out = newer ? old : disk, *in = newer ? disk : old;
	char *out_name = out->devname, *in_name = in->devname;
	struct amd_disk **dp;

	if (old->major == disk->major && old->minor == disk->minor)
		return 0;	/* the disk itself, read twice */
	if (!out_name)
		out_name = map_dev(out->major, out->minor, 0);
	if (!in_name)
		in_name = map_dev(in->major, in->minor, 0);
	pr_err("%s is not used: it has the DeviceID of %s (%016llx) - a copy of that disk?\n",
	       out_name ? out_name : "a disk", in_name ? in_name : "another disk",
	       (unsigned long long)in->device_id);
	if (!newer)
		return 0;
	for (dp = &super->disks; *dp != old; dp = &(*dp)->next)
		;
	*dp = old->next;
	amd_free_disk(old);
	return 1;
}

static void amd_take_packet(struct amd_super *super, void *packet,
			    unsigned int len, __u64 generation)
{
	free(super->packet);
	super->packet = packet;
	super->packet_len = len;
	super->packet_room = len;
	super->generation = generation;
	amd_parse_packet(super);
}

/*
 * Read one disk into @super.  Returns 0 if the disk carries a valid
 * RAIDCore label, even if it has no usable configuration.
 */
static int amd_load_disk(struct amd_super *super, int fd, char *devname,
			 int keep_fd)
{
	struct amd_metadata *md = NULL;
	struct amd_commit *c = NULL;
	struct amd_disk *disk, *old;
	unsigned long long dsize;
	struct stat stb;
	int rv = 1;

	if (!get_dev_size(fd, devname, &dsize))
		return 1;
	if (dsize < (unsigned long long)AMD_RING_END * AMD_SECTOR)
		return 1;

	md = amd_alloc(AMD_SECTOR);
	c = amd_alloc(AMD_SECTOR);
	if (!md || !c)
		goto out;
	if (amd_read(fd, AMD_METADATA_LBA, md, AMD_SECTOR) != 0)
		goto out;
	if (__le64_to_cpu(md->ident) != AMD_RC_IDENT)
		goto out;
	/*
	 * DeviceID 0 is that of an empty element, all ones that of the
	 * element of a Legacy LD the BIOS menu broke: a disk labelled so
	 * would be taken for a member there.
	 */
	if (__le32_to_cpu(md->version) != AMD_RC_VERSION ||
	    __le64_to_cpu(md->checksum) != amd_sector_sum(md) ||
	    !md->device_id || md->device_id == AMD_ID_NONE) {
		if (devname)
			pr_err("%s: RAIDCore label is damaged or of unknown version\n",
			       devname);
		goto out;
	}

	disk = xcalloc(1, sizeof(*disk));
	disk->fd = keep_fd ? dup(fd) : -1;
	disk->device_id = __le64_to_cpu(md->device_id);
	disk->features = __le32_to_cpu(md->features);
	disk->label_spare = __le32_to_cpu(md->spare_info);
	disk->sectors = dsize / AMD_SECTOR;
	if (fstat(fd, &stb) == 0 && S_ISBLK(stb.st_mode)) {
		disk->major = major(stb.st_rdev);
		disk->minor = minor(stb.st_rdev);
	}
	if (devname)
		disk->devname = xstrdup(devname);
	disk->mbr = amd_read_mbr_state(fd, md);

	if (amd_read(fd, AMD_COMMIT_LBA, c, AMD_SECTOR) == 0 &&
	    amd_check_commit(c)) {
		disk->commit_valid = 1;
		disk->generation = __le64_to_cpu(c->generation);
		disk->packet_number = __le64_to_cpu(c->packet_number);
		disk->committed_checksum = __le64_to_cpu(c->committed_checksum);
		disk->packet_lba = __le32_to_cpu(c->packet_offset);
		disk->packet_size = __le32_to_cpu(c->packet_size);
		disk->last_online = __le64_to_cpu(c->last_online_sn);
		disk->foreign = disk->last_online != AMD_SERIAL;
	}
	rv = 0;
	old = amd_find_disk(super, disk->device_id);
	if (old && !amd_copy_replaces(super, old, disk)) {
		amd_free_disk(disk);
		goto out;
	}
	if (disk->commit_valid) {
		void *packet = amd_read_packet(fd, c);

		if (packet)
			amd_repair_pds(fd, packet, __le32_to_cpu(c->packet_size));
		if (packet &&
		    amd_packet_better(super, disk->foreign, disk->generation)) {
			amd_take_packet(super, packet,
					__le32_to_cpu(c->packet_size),
					disk->generation);
			super->foreign = disk->foreign;
			amd_note_own(disk, super);
		} else {
			if (packet)
				amd_note_own_packet(disk, packet,
					__le32_to_cpu(c->packet_size));
			free(packet);
		}
	}
	amd_add_disk(super, disk);
out:
	free(md);
	free(c);
	return rv;
}

/*
 * LBA 0 of @d is not what AMD wrote there, and not its partition (a GPT, a
 * table of someone else's, nothing): say what follows, and how to repair
 * it.  Nothing is written, as LBA 0 may belong to someone else now: AMD's
 * partition can only be put back by hand, and then mdmon puts its checksum
 * in the label (amd_repair_mbr).  @examine: as a field of --examine, else
 * a warning.
 */
static void amd_mbr_advice(struct amd_disk *d, int examine)
{
	const char *n = d->devname ? d->devname : "the disk";

	if (examine)
		printf("    MBR (LBA 0) : not the one AMD wrote: the AMD BIOS and driver take the disk for a non-RAID one\n"
		       "                  (it drops out of its volumes, and the Windows driver lays a Legacy volume over it).\n"
		       "                  If nothing uses LBA 0 now: \"echo 'start=63, type=82' | sfdisk --label dos --wipe never %s\"\n"
		       "                  writes AMD's partition back, and mdmon then updates the label.\n", n);
	else
		pr_err("%s: LBA 0 is not the MBR AMD wrote: the AMD BIOS and driver take this disk for a non-RAID one (mdadm -E %s)\n",
		       n, n);
}

static struct amd_super *amd_new_super(void)
{
	struct amd_super *super = xcalloc(1, sizeof(*super));

	super->current_vol = -1;
	super->new_vol = -1;
	super->add_slot = -1;
	super->iobuf = amd_alloc(AMD_SECTOR);
	super->mmbuf = amd_alloc(AMD_SECTOR);
	return super;
}

static void amd_free(struct amd_super *super)
{
	while (super->disks) {
		struct amd_disk *d = super->disks;

		super->disks = d->next;
		amd_free_disk(d);
	}
	free(super->packet);
	free(super->next_packet);
	free(super->iobuf);
	free(super->mmbuf);
	free(super->ldbuf);
	free(super);
}

static void free_super_amd(struct supertype *st)
{
	if (st->sb)
		amd_free(st->sb);
	st->sb = NULL;
}

static void amd_set_ss(struct supertype *st)
{
	if (st->ss == NULL) {
		st->ss = &super_amd;
		st->minor_version = 0;
		st->max_devs = AMD_MAX_PD - 1;	/* and the controller's record */
	}
}

static int load_super_amd(struct supertype *st, int fd, char *devname)
{
	struct amd_super *super;

	free_super_amd(st);
	if (test_partition(fd))
		return 1;

	super = amd_new_super();
	if (amd_load_disk(super, fd, devname, 0) != 0 || !super->disks) {
		amd_free(super);
		return 1;
	}
	/* -A, -I and -E pass the disk's name: warn what the AMD BIOS will make of it */
	if (devname && super->disks->mbr == AMD_MBR_OTHER)
		amd_mbr_advice(super->disks, 0);
	if (devname && super->disks->foreign)
		pr_err("%s: last online on another controller (%012llx): the AMD BIOS and driver take its configuration for a foreign one\n",
		       devname, (unsigned long long)super->disks->last_online);
	st->sb = super;
	amd_set_ss(st);
	return 0;
}

/*
 * The disks md holds in the container @sra (GET_DEVS), each read as
 * amd_load_disk does, with descriptors, writable if they can be - mdmon
 * records state through these.  NULL if none is a RAIDCore disk.
 */
static struct amd_super *amd_load_md(struct mdinfo *sra)
{
	struct amd_super *super = amd_new_super();
	struct mdinfo *sd;

	for (sd = sra->devs; sd; sd = sd->next) {
		int dfd = amd_dev_open(sd->disk.major, sd->disk.minor, O_RDWR);

		if (!is_fd_valid(dfd))
			dfd = amd_dev_open(sd->disk.major, sd->disk.minor,
					   O_RDONLY);
		if (!is_fd_valid(dfd))
			continue;
		amd_load_disk(super, dfd, NULL, 1);
		close(dfd);
	}
	if (!super->disks) {
		amd_free(super);
		return NULL;
	}
	super->from_md = 1;
	return super;
}

static int load_container_amd(struct supertype *st, int fd, char *devname)
{
	struct amd_super *super;
	struct mdinfo *sra;
	int rv = 1;

	sra = sysfs_read(fd, NULL, GET_VERSION | GET_DEVS);
	if (!sra)
		return 1;
	if (sra->array.major_version != -1 || sra->array.minor_version != -2 ||
	    strcmp(sra->text_version, "amd") != 0)
		goto out;

	super = amd_load_md(sra);
	if (!super)
		goto out;
	free_super_amd(st);
	st->sb = super;
	amd_set_ss(st);
	snprintf(st->container_devnm, sizeof(st->container_devnm), "%s",
		 fd2devnm(fd));
	rv = 0;
out:
	sysfs_free(sra);
	return rv;
}

static struct supertype *match_metadata_desc_amd(char *arg)
{
	struct supertype *st;

	if (strcmp(arg, "amd") != 0)
		return NULL;
	st = xcalloc(1, sizeof(*st));
	amd_set_ss(st);
	return st;
}

static void amd_uuid(const char *tag, __u64 a, __u64 b, int uuid[4])
{
	char buf[80];
	char sha[20];
	int n;

	n = snprintf(buf, sizeof(buf), "amd:%s:%016llx:%016llx", tag,
		     (unsigned long long)a, (unsigned long long)b);
	sha1_buffer(buf, n, sha);
	memcpy(uuid, sha, 4 * sizeof(int));
}

/*
 * Take the disks of @second into @first, and its configuration if it is
 * the better one (amd_packet_better, as load_container picks it).
 * Copies, not moves: the caller may still use @second.
 */
static int amd_merge(struct amd_super *first, struct amd_super *second)
{
	struct amd_disk *d;

	for (d = second->disks; d; d = d->next) {
		struct amd_disk *copy;

		if (amd_find_disk(first, d->device_id))
			continue;
		copy = xmalloc(sizeof(*copy));
		*copy = *d;
		copy->next = NULL;
		copy->fd = -1;
		copy->devname = d->devname ? xstrdup(d->devname) : NULL;
		amd_add_disk(first, copy);
	}
	if (second->packet &&
	    amd_packet_better(first, second->foreign, second->generation)) {
		void *packet = amd_alloc(ROUND_UP(second->packet_len, AMD_SECTOR));

		if (!packet)
			return 3;
		memcpy(packet, second->packet, second->packet_len);
		amd_take_packet(first, packet, second->packet_len,
				second->generation);
		first->foreign = second->foreign;
	}
	return 0;
}

/* Does the live configuration of @super list disk @id - a PD, or an element? */
static int amd_lists(struct amd_super *super, __u64 id)
{
	return amd_pd_index(super, id) >= 0 || amd_disk_in_volumes(super, id);
}

/* ... one of the disks of @other? */
static int amd_lists_one_of(struct amd_super *super, struct amd_super *other)
{
	struct amd_disk *d;

	for (d = other->disks; d; d = d->next)
		if (amd_lists(super, d->device_id))
			return 1;
	return 0;
}

/*
 * Do the disks of @one belong with those of @set?  AMD records no ID of
 * a disk set: its driver takes every RAID disk of the controller for one
 * configuration, the newest (rcblob RC_ReadConfig).  So we go by what
 * each side lists: the live configuration of @set lists a disk of @one -
 * a disk of the set, maybe one that missed configurations since (mdmon
 * keeps its PD, amd_pd_states; the AMD driver drops that, but not its
 * elements) - and the configuration of @one lists a disk of @set: it has
 * not moved on to another set.  Two sets without a common disk never
 * meet; a disk taken from set X into set Y is still listed by the
 * configurations of X, but lists only disks of Y.
 */
static int amd_belongs(struct amd_super *set, struct amd_super *one)
{
	return amd_lists_one_of(set, one) && amd_lists_one_of(one, set);
}

/* Are all disks of @super loop devices - test images? */
static int amd_images(struct amd_super *super)
{
	struct amd_disk *d;
	int images = super->disks != NULL;

	for (d = super->disks; d; d = d->next)
		if (d->major != LOOP_MAJOR)
			images = 0;
	return images;
}

/*
 * The next whole disk in /sys/block (@dir) that may be a disk of the AMD
 * controller: no md or ram device, and loop devices only - or none - as
 * @images: images are sets of their own, never with real disks.
 */
static const char *amd_next_disk(DIR *dir, int images, int *maj, int *min)
{
	struct dirent *de;

	while ((de = readdir(dir)) != NULL) {
		dev_t devid;

		if (de->d_name[0] == '.' || strncmp(de->d_name, "md", 2) == 0 ||
		    strncmp(de->d_name, "ram", 3) == 0)
			continue;
		devid = devnm2devid(de->d_name);
		if (!devid || (major(devid) == LOOP_MAJOR) != images)
			continue;
		*maj = major(devid);
		*min = minor(devid);
		return de->d_name;
	}
	return NULL;
}

/* What tells that a disk is as it was when read, see amd_disk_key */
struct amd_disk_key {
	unsigned long long seq, sectors, writes, discards;
};

/* A disk as amd_disk_alone read it */
struct amd_seen_disk {
	struct amd_seen_disk *next;
	int major, minor;
	int keyed;		/* @key was there to read */
	struct amd_disk_key key;
	struct amd_super *super;	/* NULL: no RAIDCore disk */
};

static struct amd_seen_disk *amd_seen;

/* /sys/dev/block/@major:@minor/@attr into @buf; 0 if it is not there */
static int amd_disk_attr(int major, int minor, const char *attr, char *buf,
			 int len)
{
	char path[64];

	snprintf(path, sizeof(path), "/sys/dev/block/%d:%d/%s", major, minor,
		 attr);
	return load_sys(path, buf, len) == 0;
}

/*
 * What disk @major:@minor holds is what it held while @key stays the
 * same: the medium (diskseq - a new one, or a loop device given another
 * image, changes it), its size, and the writes and discards completed,
 * which the kernel counts for the whole disk (stat, with iostats on) -
 * whoever wrote: mdmon, another mdadm, anyone.  All from sysfs, no I/O
 * on the disk.  0 if the kernel gives none of this (diskseq: 5.15).
 */
static int amd_disk_key(int major, int minor, struct amd_disk_key *key)
{
	char seq[32], size[32], iostats[8], stat[512];
	unsigned long long f[11];

	memset(key, 0, sizeof(*key));
	if (!amd_disk_attr(major, minor, "diskseq", seq, sizeof(seq)) ||
	    !amd_disk_attr(major, minor, "size", size, sizeof(size)) ||
	    !amd_disk_attr(major, minor, "queue/iostats", iostats,
			   sizeof(iostats)) ||
	    !amd_disk_attr(major, minor, "stat", stat, sizeof(stat)))
		return 0;
	/* fields 5 and 12: write and discard requests completed */
	if (strcmp(iostats, "1") != 0 ||
	    sscanf(stat, "%llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu",
		   &f[0], &f[1], &f[2], &f[3], &f[4], &f[5], &f[6], &f[7],
		   &f[8], &f[9], &f[10], &key->discards) < 5)
		return 0;
	key->seq = strtoull(seq, NULL, 10);
	key->sectors = strtoull(size, NULL, 10);
	key->writes = f[4];
	return 1;
}

/*
 * Disk @major:@minor read on its own; NULL if it is no RAIDCore disk.
 * AMD records no ID of a disk set (IMSM has its family number), so the
 * UUID of a container comes from all disks present (amd_container_uuid),
 * and mdadm asks for it several times a disk: -I, -A, -E --scan.  A disk
 * is read again only when amd_disk_key says it changed.  The copy stays
 * ours, valid until the next call for this disk.
 */
static struct amd_super *amd_disk_alone(int major, int minor)
{
	struct amd_seen_disk *s;
	struct amd_disk_key key;
	int keyed = amd_disk_key(major, minor, &key);
	int fd;

	for (s = amd_seen; s; s = s->next)
		if (s->major == major && s->minor == minor)
			break;
	if (s && keyed && s->keyed && memcmp(&s->key, &key, sizeof(key)) == 0)
		return s->super;
	if (!s) {
		s = xcalloc(1, sizeof(*s));
		s->major = major;
		s->minor = minor;
		s->next = amd_seen;
		amd_seen = s;
	} else if (s->super) {
		amd_free(s->super);
		s->super = NULL;
	}
	s->keyed = keyed;
	s->key = key;
	/* too small for a label: amd_load_disk would not take it */
	if (keyed && key.sectors < AMD_RING_END)
		return NULL;
	fd = amd_dev_open(major, minor, O_RDONLY);
	if (!is_fd_valid(fd)) {
		s->keyed = 0;
		return NULL;
	}
	s->super = amd_new_super();
	if (amd_load_disk(s->super, fd, NULL, 0) != 0) {
		amd_free(s->super);
		s->super = NULL;
	}
	close(fd);
	return s->super;
}

/*
 * The RAIDCore disks present that carry a configuration, each read on its
 * own into @pool (up to AMD_MAX_PD of them; amd_disk_alone's, not to be
 * freed).  Their count.
 */
static int amd_scan_disks(int images, struct amd_super **pool)
{
	DIR *dir = opendir("/sys/block");
	int n = 0, maj, min;

	while (dir && n < AMD_MAX_PD && amd_next_disk(dir, images, &maj, &min)) {
		struct amd_super *one = amd_disk_alone(maj, min);

		if (one && one->packet)
			pool[n++] = one;
	}
	if (dir)
		closedir(dir);
	return n;
}

/*
 * The disks md holds in the container @sra, as amd_load_md reads them (one
 * configuration, the better one; no second disk of a DeviceID), but from
 * amd_disk_alone: only to look at.
 */
static struct amd_super *amd_md_set(struct mdinfo *sra)
{
	struct amd_super *set = amd_new_super();
	struct mdinfo *sd;

	for (sd = sra->devs; sd; sd = sd->next) {
		struct amd_super *one = amd_disk_alone(sd->disk.major,
						       sd->disk.minor);

		if (one && !amd_find_disk(set, one->disks->device_id))
			amd_merge(set, one);
	}
	if (!set->disks) {
		amd_free(set);
		return NULL;
	}
	set->from_md = 1;
	return set;
}

/*
 * The set the disks of @super belong to, among the disks present: those
 * that belong with each other (amd_belongs, disk by disk), starting from
 * the disks of @super, and of them the ones the best configuration lists -
 * a disk dropped from the set since may still list the others.  NULL if
 * @super's disks are not among them.
 */
static struct amd_super *amd_present_set(struct amd_super *super)
{
	struct amd_super *pool[AMD_MAX_PD], *live = NULL, *set = NULL;
	int n = amd_scan_disks(amd_images(super), pool);
	char in[AMD_MAX_PD];
	int i, j, grew;

	for (i = 0; i < n; i++)
		in[i] = amd_find_disk(super, pool[i]->disks->device_id) != NULL;
	do {
		grew = 0;
		for (i = 0; i < n; i++)
			for (j = 0; j < n && !in[i]; j++)
				if (in[j] && amd_belongs(pool[j], pool[i]))
					in[i] = grew = 1;
	} while (grew);
	for (i = 0; i < n; i++)
		if (in[i] && (!live || amd_packet_better(live, pool[i]->foreign,
							 pool[i]->generation)))
			live = pool[i];
	if (live) {
		set = amd_new_super();
		amd_merge(set, live);
		for (i = 0; i < n; i++)
			if (in[i] && amd_lists(live, pool[i]->disks->device_id))
				amd_merge(set, pool[i]);
		if (!amd_lists_one_of(set, super)) {
			amd_free(set);
			set = NULL;
		}
	}
	return set;
}

/*
 * The running container (/proc/mdstat) that the disks of @super are in or
 * belong to, read from its disks, and its name into @devnm; NULL if there
 * is none.  Should two of them qualify (a set split by an older mdadm), the
 * one with the better configuration.
 */
static struct amd_super *amd_running_set(struct amd_super *super, char *devnm)
{
	struct mdstat_ent *mdstat = mdstat_read(0, 0), *e;
	struct amd_super *best = NULL;

	for (e = mdstat; e; e = e->next) {
		struct amd_super *set = NULL;
		struct mdinfo *sra;
		struct amd_disk *d;
		int in;

		if (!e->metadata_version ||
		    strcmp(e->metadata_version, "external:amd") != 0)
			continue;
		sra = sysfs_read(-1, e->devnm, GET_DEVS);
		if (sra)
			set = amd_md_set(sra);
		sysfs_free(sra);
		if (!set)
			continue;
		in = set->packet && amd_belongs(set, super);
		for (d = super->disks; d && set->packet && !in; d = d->next)
			in = amd_find_disk(set, d->device_id) != NULL;
		if (in && (!best || amd_packet_better(best, set->foreign,
						      set->generation))) {
			if (best)
				amd_free(best);
			best = set;
			snprintf(devnm, MD_NAME_MAX, "%s", e->devnm);
		} else {
			amd_free(set);
		}
	}
	free_mdstat(mdstat);
	return best;
}

/*
 * The set the disks of @super - read on their own, or gathered by
 * Assemble - belong to: the running container they are in or belong to
 * (its name into @devnm), else the disks present they belong with.  NULL
 * if none.
 */
static struct amd_super *amd_find_set(struct amd_super *super, char *devnm)
{
	struct amd_super *set = amd_running_set(super, devnm);

	return set ? set : amd_present_set(super);
}

/*
 * The UUID the map has for the running container @devnm.  None without a
 * map file: the map rebuilt from the disks (RebuildMap) would ask us.
 */
static int amd_map_uuid(char *devnm, int uuid[4])
{
	struct map_ent *map = NULL, *me;
	int found = 0;

	if (access(MAP_DIR "/" MAP_FILE, R_OK) != 0)
		return 0;
	me = map_by_devnm(&map, devnm);
	if (me) {
		memcpy(uuid, me->uuid, sizeof(me->uuid));
		found = 1;
	}
	map_free(map);
	return found;
}

/*
 * The UUIDs carry AMD's controller serial number, whatever the packet has:
 * mdmon takes a configuration of another controller over (amd_take_over),
 * and the arrays keep their UUIDs through that.
 *
 * The container UUID comes from the lowest DeviceID of the configuration
 * (AMD records no ID of a disk set): a disk added with a lower one changes
 * it, and a disk that missed that has the old one.  So it is the UUID of
 * the set the disks belong to, among those present (amd_present_set) - a
 * running container's too - and a disk of a running container, or one
 * that belongs to it, has the UUID the map knows that container by:
 * Incremental puts a set's new UUID in the map as its disks join, not as
 * they appear.
 */
static void amd_container_uuid(struct amd_super *super, int uuid[4])
{
	char devnm[MD_NAME_MAX];
	struct amd_super *set = NULL;
	__u64 id = super->container_id;

	if (!super->packet && !super->creating) {
		amd_uuid("disk", 0, super->disks->device_id, uuid);
		return;
	}
	/* --create: the lowest DeviceID of the disks given so far */
	if (super->creating) {
		amd_uuid("container", AMD_SERIAL, id, uuid);
		return;
	}
	if (!super->from_md) {
		set = amd_running_set(super, devnm);
		if (set) {
			amd_free(set);
			if (amd_map_uuid(devnm, uuid))
				return;
		}
	}
	set = amd_present_set(super);
	if (set) {
		id = set->container_id;
		amd_free(set);
	}
	amd_uuid("container", AMD_SERIAL, id, uuid);
}

static void amd_volume_uuid(struct amd_super *super, int vol, int uuid[4])
{
	amd_uuid("volume", AMD_SERIAL,
		 __le64_to_cpu(super->vol[vol].ld->id.id), uuid);
}

static void uuid_from_super_amd(struct supertype *st, int uuid[4])
{
	struct amd_super *super = st->sb;

	if (super->current_vol >= 0 && super->current_vol < super->nvol)
		amd_volume_uuid(super, super->current_vol, uuid);
	else
		amd_container_uuid(super, uuid);
}

/* @uuid as mdadm prints it, without the "UUID-" of fname_from_uuid() */
static const char *amd_uuid_text(const int uuid[4], char *buf)
{
	struct mdinfo info;

	memcpy(info.uuid, uuid, sizeof(info.uuid));
	return fname_from_uuid(&info, buf) + 5;
}

/* md array names: printable, no '/' */
static void amd_volume_name(const struct amd_ld *ld, char *name, size_t len)
{
	size_t i, n = 0;

	for (i = 0; i < sizeof(ld->name) && ld->name[i] && n + 1 < len; i++) {
		char ch = ld->name[i];

		name[n++] = (isalnum((unsigned char)ch) || ch == '-' ||
			     ch == '.' || ch == '_') ? ch : '_';
	}
	name[n] = '\0';
}

static int amd_pd_index(struct amd_super *super, __u64 id)
{
	int i;

	for (i = 0; i < super->npd; i++)
		if (__le64_to_cpu(super->pd[i]->id.id) == id)
			return i;
	return -1;
}

static void amd_fill_volume(struct amd_super *super, int vol,
			    struct mdinfo *info)
{
	struct amd_vol *v = &super->vol[vol];

	info->array.level = v->level;
	info->array.layout = v->layout;
	info->array.raid_disks = v->raid_disks;
	info->array.chunk_size = v->level == 1 ? 0 : v->chunk_sectors * 512;
	info->array.md_minor = -1;
	info->array.major_version = -1;
	info->array.minor_version = -2;
	info->array.state = 1 << MD_SB_CLEAN;
	if (v->blocked)
		info->array.state |= 1 << MD_SB_BLOCK_VOLUME;
	info->component_size = v->component_size;
	info->array.size = v->component_size / 2;
	info->resync_start = MaxSector;
	info->recovery_start = MaxSector;
	info->safe_mode_delay = 4000;
	info->container_member = vol;
	info->events = super->generation;
	amd_volume_name(v->ld, info->name, sizeof(info->name));
	amd_volume_uuid(super, vol, info->uuid);
}

/* what the container itself is, for getinfo_super */
static void amd_fill_container(struct amd_super *super, struct mdinfo *info)
{
	info->array.level = LEVEL_CONTAINER;
	info->array.md_minor = -1;
	info->array.major_version = -1;
	info->array.minor_version = -2;
	snprintf(info->text_version, sizeof(info->text_version), "amd");
	amd_container_uuid(super, info->uuid);
}

/*
 * Can @v run with the disks we have?  1: all members present (or missing
 * ones were already out of service), 0: only degraded, -1: not at all.
 */
static int amd_volume_enough(struct amd_super *super, struct amd_vol *v)
{
	int f = __le32_to_cpu(v->ld->first_count);
	int s = __le32_to_cpu(v->ld->second_count);
	int i, j, lost = 0, newly_missing = 0;

	for (i = 0; i < f; i++) {
		int present = 0;

		for (j = 0; j < s; j++) {
			struct amd_element *el = &v->el[i * s + j];

			if (!amd_slot_usable(v, i * s + j)) {
				lost++;
			} else if (!amd_volume_disk(super, v, el)) {
				lost++;
				newly_missing++;
			} else {
				present++;
			}
		}
		if ((v->level == 1 || v->level == 10) && present == 0)
			return -1;
	}
	if ((v->level <= 0 && lost > 0) || (v->level == 5 && lost > 1))
		return -1;
	return newly_missing ? 0 : 1;
}

/* State to record for @v: CRITICAL while some member is out of service. */
static __u32 amd_volume_state(struct amd_super *super, struct amd_vol *v)
{
	int i;

	if (amd_volume_enough(super, v) < 0)
		return AMD_LD_STATE_OFFLINE;
	for (i = 0; i < v->nel; i++)
		if (!amd_slot_usable(v, i))
			return AMD_LD_STATE_CRITICAL;
	return AMD_LD_STATE_NORMAL;
}

static int amd_container_enough(struct amd_super *super)
{
	int vol, most = -1, any = 0;

	for (vol = 0; vol < super->nvol; vol++) {
		struct amd_vol *v = &super->vol[vol];
		int e;

		if (v->blocked)
			continue;
		any = 1;
		e = amd_volume_enough(super, v);
		if (e > most)
			most = e;
	}
	return any ? most : 1;
}

/* Sectors from the start of @disk up to its first allocated extent. */
static unsigned long long amd_metadata_area(struct amd_super *super,
					    struct amd_disk *disk)
{
	unsigned long long area = AMD_DEFAULT_ALLOC_LBA;
	int vol, i;

	for (vol = 0; vol < super->nvol; vol++) {
		struct amd_vol *v = &super->vol[vol];

		for (i = 0; i < v->nel; i++)
			if (__le64_to_cpu(v->el[i].id.id) == disk->device_id &&
			    __le64_to_cpu(v->el[i].allocated.offset) < area)
				area = __le64_to_cpu(v->el[i].allocated.offset);
	}
	if (area < AMD_RING_END)
		area = AMD_RING_END;
	if (area > disk->sectors)
		area = disk->sectors;
	return area;
}

/* Disks in elements of volumes with no PD record (dropped by the AMD driver) */
static int amd_dropped_members(struct amd_super *super)
{
	__u64 seen[AMD_MAX_PD];
	int vol, i, j, n = 0;

	for (vol = 0; vol < super->nvol; vol++)
		for (i = 0; i < super->vol[vol].nel; i++) {
			__u64 id = __le64_to_cpu(super->vol[vol].el[i].id.id);

			if (!id || id == AMD_ID_NONE || amd_pd_index(super, id) >= 0)
				continue;
			for (j = 0; j < n && seen[j] != id; j++)
				;
			if (j == n && n < AMD_MAX_PD)
				seen[n++] = id;
		}
	return n;
}

/*
 * The RAID disks of the configuration: those with a PD record, and the
 * members whose PD the AMD driver dropped, running without them
 * (rcraid.sys 9.3.3.218) - they are in its elements still.  A disk
 * without a configuration: itself.
 */
static int amd_container_disks(struct amd_super *super)
{
	int i, n = amd_dropped_members(super);

	if (!super->packet)
		return 1;
	for (i = 0; i < super->npd; i++)
		if (__le32_to_cpu(super->pd[i]->device_type) == AMD_DEV_RAIDCORE_DISK)
			n++;
	return n;
}

/* getinfo_super_amd of the volume mdadm --create is making */
static void amd_getinfo_new_volume(struct supertype *st, struct mdinfo *info)
{
	struct amd_super *super = st->sb;
	struct amd_vol *v = &super->vol[super->current_vol];

	/* --create: md initializes it (CREATE_REDUNDANCY) */
	if (v->init_pending) {
		info->array.state &= ~(1 << MD_SB_CLEAN);
		info->resync_start = 0;
	}
	if (super->new_mdbm)
		info->consistency_policy = CONSISTENCY_POLICY_BITMAP;
	if (super->add_slot >= 0 && super->add_slot < v->nel) {
		struct amd_element *el = &v->el[super->add_slot];
		struct amd_disk *d = amd_find_disk(super,
				__le64_to_cpu(el->id.id));

		info->disk.number = super->add_slot;
		info->disk.raid_disk = super->add_slot;
		info->disk.major = d ? d->major : 0;
		info->disk.minor = d ? d->minor : 0;
		info->disk.state = (1 << MD_DISK_SYNC) | (1 << MD_DISK_ACTIVE);
		info->data_offset = __le64_to_cpu(el->user_data.offset);
		info->component_size = __le64_to_cpu(el->user_data.size);
	}
	/* a member array of the container, under mdmon */
	snprintf(info->text_version, sizeof(info->text_version),
		 "/%s/%d", st->container_devnm, super->current_vol);
}

/* getinfo_super_amd of volume super->current_vol, as on disk @disk */
static void amd_getinfo_volume(struct supertype *st, struct mdinfo *info,
			       struct amd_disk *disk)
{
	struct amd_super *super = st->sb;
	struct amd_vol *v = &super->vol[super->current_vol];
	int i;

	amd_fill_volume(super, super->current_vol, info);
	if (super->current_vol == super->new_vol) {
		amd_getinfo_new_volume(st, info);
		return;
	}
	info->disk.raid_disk = -1;
	for (i = 0; i < v->nel; i++)
		if (__le64_to_cpu(v->el[i].id.id) == disk->device_id) {
			info->disk.raid_disk = i;
			info->data_offset =
				__le64_to_cpu(v->el[i].user_data.offset);
			break;
		}
	info->disk.number = info->disk.raid_disk;
	info->disk.state = info->disk.raid_disk >= 0 ?
		(1 << MD_DISK_SYNC) | (1 << MD_DISK_ACTIVE) : 0;
	snprintf(info->text_version, sizeof(info->text_version), "amd");
}

/*
 * getinfo_super_amd of the container, as disk @disk; @map: the first
 * @map_disks PDs, whether each is online.
 */
static void amd_getinfo_container(struct amd_super *super, struct mdinfo *info,
				  struct amd_disk *disk, char *map,
				  int map_disks)
{
	int i, idx;

	amd_fill_container(super, info);
	info->container_enough = amd_container_enough(super);
	/*
	 * No number of disks to expect (as IMSM): a disk's packet has the
	 * disks of its generation, and one that missed a disk being added
	 * would differ from the others - Incremental refuses each disk whose
	 * count is not that of the container's first device (a stale disk
	 * that came first would keep all the others out).
	 */
	info->array.raid_disks = 0;
	if (super->cur_disk)
		disk = super->cur_disk;	/* --create: the disk just added */

	idx = amd_pd_index(super, disk->device_id);
	info->disk.number = idx;
	/*
	 * No slot in the container (as IMSM): the PD index is the disk's own
	 * packet's, and a stale disk's may be another disk's in the current
	 * one (the AMD driver drops the PD of a disk it ran without, the
	 * later ones move up) - Assemble would keep one of the two.
	 */
	info->disk.raid_disk = -1;
	info->disk.state = (1 << MD_DISK_SYNC) | (1 << MD_DISK_ACTIVE);
	/*
	 * The container member covers only the metadata area in front of
	 * the volumes, so that it does not overlap them (md refuses that).
	 */
	info->data_offset = 0;
	info->component_size = amd_metadata_area(super, disk);
	info->events = disk->generation;
	info->recovery_start = MaxSector;

	if (map)
		for (i = 0; i < map_disks; i++)
			map[i] = i < super->npd &&
				 __le32_to_cpu(super->pd[i]->device_state) ==
				 AMD_DEV_STATE_ONLINE;
}

static void getinfo_super_amd(struct supertype *st, struct mdinfo *info,
			      char *map)
{
	struct amd_super *super = st->sb;
	struct amd_disk *disk = super->disks;
	int map_disks = info->array.raid_disks;

	memset(info, 0, sizeof(*info));
	if (!disk && super->creating) {
		/* --create, before the first disk */
		amd_fill_container(super, info);
		info->disk.raid_disk = -1;
		return;
	}
	if (!disk)
		return;
	if (super->current_vol >= 0 && super->current_vol < super->nvol)
		amd_getinfo_volume(st, info, disk);
	else
		amd_getinfo_container(super, info, disk, map, map_disks);
}

/*
 * Are @first and @second disks of one container?  Of the set @first
 * belongs to (amd_find_set) - the configuration of @first alone may not
 * list @second: a disk added while @first was away.  Disks without a
 * configuration, and those of --create, go by UUID, as before.
 */
static int amd_same_set(struct amd_super *first, struct amd_super *second)
{
	char devnm[MD_NAME_MAX];
	struct amd_super *set;
	struct amd_disk *d;
	int u1[4], u2[4];
	int same;

	if (!first->packet || !second->packet || first->creating ||
	    second->creating) {
		amd_container_uuid(first, u1);
		amd_container_uuid(second, u2);
		return memcmp(u1, u2, sizeof(u1)) == 0;
	}
	set = first->from_md ? first : amd_find_set(first, devnm);
	if (!set)
		return amd_belongs(first, second);
	same = amd_belongs(set, second);
	for (d = second->disks; d && !same; d = d->next)
		same = amd_find_disk(set, d->device_id) != NULL;
	if (set != first)
		amd_free(set);
	return same;
}

static int compare_super_amd(struct supertype *st, struct supertype *tst,
			     int verbose)
{
	/*
	 * return:
	 *  0 same, or first was empty, and second was copied
	 *  2 different container
	 */
	struct amd_super *first = st->sb;
	struct amd_super *second = tst->sb;

	if (!first) {
		st->sb = tst->sb;
		tst->sb = NULL;
		return 0;
	}
	if (!second)
		return 1;
	if (!amd_same_set(first, second))
		return 2;
	return amd_merge(first, second);
}

/* Data elements of one parity set (RC_SecondElementCount). */
static unsigned int amd_data_per_set(const struct amd_ld *ld)
{
	__u32 s = __le32_to_cpu(ld->second_count);

	switch (__le32_to_cpu(ld->device_type)) {
	case AMD_LDT_RAID50:
		return s - 1;
	case AMD_LDT_RAID60:
		return s - 2;
	case AMD_LDT_RAW:
		return s;
	default:
		return 1;
	}
}

/*
 * RC_TransformProtectSize: min(data elements x FirstCount x 0x4800, 0x8000)
 * sectors (no cap for RAID5/6), cut down to whole stripes.
 */
static unsigned long long amd_protect_size(const struct amd_vol *v)
{
	const struct amd_ld *ld = v->ld;
	unsigned long long f = __le32_to_cpu(ld->first_count);
	unsigned long long data = amd_data_per_set(ld);
	unsigned long long protect, stripe;
	__u32 type = __le32_to_cpu(ld->device_type);

	stripe = v->chunk_sectors * data * f;
	protect = data * f * 0x4800;
	if (protect > 0x8000 && type != AMD_LDT_RAID50 && type != AMD_LDT_RAID60)
		protect = 0x8000;
	if (stripe && protect >= stripe)
		protect -= protect % stripe;
	return protect;
}

/*
 * Sectors covered by one bit of the write-intent bitmap (RC_BitCoverSize):
 * the next power of two >= capacity spread over the 4096 bits, at least
 * 0x32000 sectors and the transform protect size, rounded up to whole
 * protect units and whole stripes.  0 if the volume is too large for a
 * one-sector bitmap.
 */
static unsigned long long amd_bitmap_cover(const struct amd_vol *v)
{
	const struct amd_ld *ld = v->ld;
	unsigned long long cap = __le64_to_cpu(ld->capacity);
	unsigned long long f = __le32_to_cpu(ld->first_count);
	unsigned long long data = amd_data_per_set(ld);
	unsigned long long p = 0x200000, c, protect, stripe;

	while (p < cap) {
		p <<= 1;
		if (p > (1ULL << 43))
			return 0;
	}
	stripe = v->chunk_sectors * data * f;
	protect = amd_protect_size(v);

	c = p / (AMD_BITMAP_BYTES * 8);
	if (c < 0x32000)
		c = 0x32000;
	if (c < protect)
		c = protect;
	if (protect && c % protect)
		c += protect - c % protect;
	if (stripe && c % stripe)
		c += stripe - c % stripe;
	if (c > cap)
		c = cap;
	return c;
}

static unsigned int amd_bitmap_bits(const struct amd_vol *v)
{
	unsigned long long cover = amd_bitmap_cover(v);
	unsigned long long cap = __le64_to_cpu(v->ld->capacity);

	return cover ? (cap + cover - 1) / cover : 0;
}

/*
 * The up-to-date disk holding element [0][0], which keeps the bitmap.  A
 * RAIDABLE growing into a RAID1 has the RAID1's: the same element and size,
 * attribute 0x1 in the RAID1 LD only (rcraid 9.3.3, seen midway).
 */
static struct amd_disk *amd_bitmap_disk(struct amd_super *super,
					struct amd_vol *v)
{
	const struct amd_ld *ld = v->grow ? v->link : v->ld;

	if (!(__le32_to_cpu(ld->attribute) & AMD_ATTR_BITMAP) ||
	    !amd_slot_usable(v, 0) || amd_bitmap_bits(v) == 0 ||
	    amd_bitmap_bits(v) > AMD_BITMAP_BYTES * 8)
		return NULL;
	return amd_member_disk(super, __le64_to_cpu(v->el[0].id.id));
}

static unsigned long long amd_bitmap_lba(const struct amd_vol *v)
{
	return __le64_to_cpu(v->el[0].allocated.offset) + AMD_BITMAP_OFFSET;
}

/* The AMD bitmap of @v into @buf (AMD_BITMAP_BYTES): 0, or -1 if unreadable */
static int amd_bitmap_load(struct amd_super *super, struct amd_vol *v,
			   __u8 *buf)
{
	struct amd_disk *d = amd_bitmap_disk(super, v);
	int fd, rv;

	if (!d)
		return -1;
	fd = amd_disk_fd(d);
	if (!is_fd_valid(fd))
		return -1;
	rv = amd_read(fd, amd_bitmap_lba(v), buf, AMD_BITMAP_BYTES);
	if (fd != d->fd)
		close(fd);
	return rv;
}

/* the first bit set in AMD bitmap @buf of @v, or -1 */
static int amd_bitmap_first(const struct amd_vol *v, const __u8 *buf)
{
	unsigned int i, bits = amd_bitmap_bits(v);

	for (i = 0; i < bits; i++)
		if (buf[i >> 3] & (1 << (i & 7)))
			return i;
	return -1;
}

/*
 * 1: some bit of the volume's bitmap is set (the first in *@first, if
 * given), 0: clean, -1: unreadable
 */
static int amd_bitmap_read(struct amd_super *super, struct amd_vol *v,
			   unsigned int *first)
{
	__u8 *buf = super->mmbuf;
	int i;

	if (v->single)
		return 0;	/* no bitmap, and nothing to resync */
	/* managemon reads (open_new), the monitor writes iobuf meanwhile */
	if (!buf || amd_bitmap_load(super, v, buf) != 0)
		return -1;
	i = amd_bitmap_first(v, buf);
	if (i < 0)
		return 0;
	if (first)
		*first = i;
	return 1;
}

/* AMD bitmap @buf of @v as mdmon writes it: dirty from bit @from, or clean */
static void amd_bitmap_fill(const struct amd_vol *v, __u8 *buf, int dirty,
			    unsigned int from)
{
	unsigned int i, bits = dirty ? amd_bitmap_bits(v) : 0;

	memset(buf, 0, AMD_BITMAP_BYTES);
	for (i = from; i < bits; i++)
		buf[i >> 3] |= 1 << (i & 7);
}

/*
 * Mark the volume dirty from bit @from to the end, or clean, in the AMD
 * bitmap.  From 0 while md may write anywhere; later bits only while a
 * resync after a crash runs and md is clean: what it has done is in step.
 */
static int amd_bitmap_write(struct amd_super *super, struct amd_vol *v,
			    int dirty, unsigned int from)
{
	struct amd_disk *d = amd_bitmap_disk(super, v);
	__u8 *buf = super->iobuf;

	if (v->single)
		return 0;
	if (!d || d->fd < 0 || !buf)
		return -1;
	amd_bitmap_fill(v, buf, dirty, from);
	if (pwrite(d->fd, buf, AMD_BITMAP_BYTES,
		   (off_t)amd_bitmap_lba(v) * AMD_SECTOR) != AMD_BITMAP_BYTES ||
	    fsync(d->fd) != 0)
		return -1;
	return 0;
}

/*
 * Member sectors <-> volume sectors, at whole stripes.  In RAID1 they are
 * the same; in RAID10 (near copies, AMD order) a member holds one chunk of
 * each stripe of FirstCount chunks, in RAID5 one chunk (data or parity) of
 * each stripe of SecondCount - 1 data chunks.
 */
static unsigned long long amd_stripe_data(const struct amd_vol *v)
{
	if (v->chunk_sectors == 0)
		return 0;
	if (v->level == 10)
		return __le32_to_cpu(v->ld->first_count);
	if (v->level == 5)
		return amd_data_per_set(v->ld);
	return 0;
}

static unsigned long long amd_member_to_volume(const struct amd_vol *v,
					       unsigned long long sectors)
{
	unsigned long long chunk = v->chunk_sectors;
	unsigned long long data = amd_stripe_data(v);

	if (data == 0)
		return sectors;
	return sectors / chunk * chunk * data;
}

static unsigned long long amd_volume_to_member(const struct amd_vol *v,
					       unsigned long long sectors)
{
	unsigned long long chunk = v->chunk_sectors;
	unsigned long long data = amd_stripe_data(v);

	if (data == 0)
		return sectors;
	return sectors / (chunk * data) * chunk;
}

/*
 * md counts a resync in array sectors for raid1/raid10 (resync_max_sectors
 * = the array size) but in member sectors for raid5 (= dev_sectors), as a
 * recovery for every level; AMD logs and its bitmap count volume sectors.
 */
static unsigned long long amd_sync_to_volume(const struct amd_vol *v,
					     unsigned long long sectors)
{
	return v->level == 5 ? amd_member_to_volume(v, sectors) : sectors;
}

static unsigned long long amd_volume_to_sync(const struct amd_vol *v,
					     unsigned long long sectors)
{
	return v->level == 5 ? amd_volume_to_member(v, sectors) : sectors;
}

static __u64 amd_tlog_checksum(const struct amd_tlog *t)
{
	struct amd_tlog c = *t;

	c.id.reserved = 0;
	c.copy_to.reserved = 0;
	return amd_checksum((char *)&c + 8, sizeof(c) - 8);
}

/*
 * The transform log of transform @type of @v, the LD @tl transformed into,
 * into @t: STARTED, @done volume sectors done.  One log for every transform
 * type: Type and Flags come from the LD, the AMD driver resumes any of them
 * from ProtectStart (RC_SetTaskLog, RC_RestartTask, RC_InitTransformStruct).
 * For a rebuild of a mirror IOStart/IOSize and the stripe fields stay 0
 * (the AMD driver works its I/O size out again each region, see below);
 * a migration (NORMAL), an initialization and any transform of RAID5
 * (@raid5) have them as the AMD drivers write them.
 */
static void amd_tlog_fill(const struct amd_vol *v, const struct amd_ld *tl,
			  struct amd_tlog *t, unsigned long long done,
			  __u32 type, int raid5)
{
	t->id = v->ld->id;
	t->id.reserved = 0;
	/*
	 * A migration logs the region in work, of ProtectSize: all
	 * below it is in the new LD (rcblob RC_TransformDiskLogNextRegion;
	 * rcraid 9.3.3: ProtectStart = IOStart on a region boundary).
	 */
	if (type == AMD_TRANSFORM_NORMAL)
		done -= done % amd_protect_size(v);
	t->type = __cpu_to_le32(type);
	t->protect_start = __cpu_to_le64(done);
	t->flags = type == AMD_TRANSFORM_RESTORE_SEGMENTS ?
		   __cpu_to_le32(AMD_TFLAGS_RESTORE) : tl->transform_flags;
	if (!t->flags)
		t->flags = __cpu_to_le32(AMD_TFLAGS_CREATE);
	t->protect_size = __cpu_to_le32(amd_protect_size(v));
	if (type == AMD_TRANSFORM_NORMAL) {
		/* and its I/O, IOSize 0x600, 12 to the region */
		t->io_start = t->protect_start;
		t->io_size = __cpu_to_le32(AMD_GROW_IO_SIZE);
		t->dynamic_protect_stripe =
			__cpu_to_le32(amd_protect_size(v) / AMD_GROW_IO_SIZE);
		t->log_update_stripe = t->dynamic_protect_stripe;
	} else if (raid5 ||
		   type == AMD_TRANSFORM_CREATE_REDUNDANCY) {
		/*
		 * The I/O at ProtectStart and the protect window in
		 * stripes, as the AMD drivers log them: initializing a
		 * RAID1, rcraid 0x100 sectors, 0x90 stripes; RAID5,
		 * rcraid.sys a chunk (RAID10 a chunk by rcblob
		 * RC_SetTransformSize).  The flags are those of the
		 * LD at any level: 0x211 on a volume of the menu or
		 * of mdadm -C, 0x241 of rcadm -C (rcraid on mirrors,
		 * rcraid.sys on a RAID5).  Resuming,
		 * the driver takes the I/O size from the log
		 * (RC_InitTransformInfo skips RC_SetTransformSize); a
		 * rebuild or migration works it out again each region
		 * (RC_MaxDynamicTransformIoSize), an initialization
		 * does not (RC_TransformUpdateNextRegionFromBeginning).
		 * Left 0, rcraid 9.3.3-00302 makes no headway on an
		 * initialization - I/O past the mark times out, the
		 * volume goes critical - and rcraid.sys 9.3.3.218 fails
		 * a RAID5 transform ("rebuild/create task has failed").
		 */
		unsigned long long stripe = v->chunk_sectors *
			amd_data_per_set(v->ld) *
			__le32_to_cpu(v->ld->first_count);

		t->io_start = t->protect_start;
		t->io_size = __cpu_to_le32(v->level == 1 ? 0x100 :
					   v->chunk_sectors);
		if (stripe)
			t->dynamic_protect_stripe =
				__cpu_to_le32(amd_protect_size(v) / stripe);
		t->log_update_stripe = t->dynamic_protect_stripe;
	}
	t->status = __cpu_to_le32(AMD_TLOG_STARTED);
	t->checksum = __cpu_to_le64(amd_tlog_checksum(t));
}

/*
 * Write the transform log of transform @type of @v (amd_tlog_fill) - or
 * clear it (@erase) - on each in-service element of column 0 of @tl, the
 * LD transformed into (rcblob RC_TransformDiskLogNextRegion: logical
 * sector Capacity with I/O flag 0x10000 is AllocatedSpace + 0 of the
 * column-0 elements).  RAID5 (F = 1): the log is on the data and the
 * parity element of chunk 0 of the stripe past the end
 * (RC_Raid50LogicalToPhysical with 0x10000: data and parity I/O).
 */
static int amd_tlog_write(struct amd_super *super, struct amd_vol *v,
			  const struct amd_ld *tl, int erase,
			  unsigned long long done, __u32 type)
{
	const struct amd_element *el = amd_ld_elements(tl);
	struct amd_tlog *t = super->iobuf;
	int s = __le32_to_cpu(tl->second_count);
	int j, n = 0, only[2] = { -1, -1 };

	if (!t)
		return -1;
	memset(t, 0, AMD_SECTOR);
	/*
	 * RAID5: the two elements rcraid.sys keeps the log on, the data and
	 * the parity element of the stripe past the end (seen on a RAID5
	 * it was initializing, shut down midway).  Cleared on all of them.
	 */
	if (v->level == 5 && !erase && v->chunk_sectors && s >= 3) {
		unsigned long long stripes = __le64_to_cpu(tl->capacity) /
			(v->chunk_sectors * (unsigned long long)(s - 1));

		only[0] = stripes % s;
		only[1] = only[0] == 0 ? 1 : 0;
	}
	if (!erase)
		amd_tlog_fill(v, tl, t, done, type, only[0] >= 0);
	for (j = 0; j < s; j++) {
		struct amd_disk *d;

		if (!amd_element_usable(&el[j]) ||
		    (only[0] >= 0 && j != only[0] && j != only[1]))
			continue;
		d = amd_find_disk(super, __le64_to_cpu(el[j].id.id));
		/* one a configuration write failed on is stale: no member next time */
		if (!d || d->fd < 0 || d->spare_failed || d->write_failed)
			continue;
		if (pwrite(d->fd, t, AMD_SECTOR,
			   (off_t)__le64_to_cpu(el[j].allocated.offset) * AMD_SECTOR) !=
		    AMD_SECTOR || fsync(d->fd) != 0)
			return -1;
		n++;
	}
	return n ? 0 : -1;
}

/*
 * Volume sectors done by transform @type of @v, from its transform log on
 * the column-0 elements of @tl (written by us or by the AMD driver), or 0
 * if no copy is valid (rcblob RC_IsTransformLogValid, RC_RestartTask).
 * The least of the valid copies: a copy on a disk that was missing lags
 * behind, or predates a restart from 0 (amd_target_behind); copying more
 * is harmless, less is not.
 */
static unsigned long long amd_tlog_read(struct amd_super *super,
					struct amd_vol *v,
					const struct amd_ld *tl, __u32 type)
{
	const struct amd_element *el = amd_ld_elements(tl);
	/* managemon reads (activate_spare), the monitor writes iobuf meanwhile */
	struct amd_tlog *t = super->mmbuf;
	unsigned long long cap = __le64_to_cpu(v->ld->capacity), least = cap;
	int s = __le32_to_cpu(tl->second_count);
	int j, valid = 0;

	for (j = 0; t && j < s; j++) {
		struct amd_disk *d;
		int fd, rv;

		if (!amd_element_usable(&el[j]))
			continue;
		d = amd_find_disk(super, __le64_to_cpu(el[j].id.id));
		if (!d)
			continue;
		fd = amd_disk_fd(d);
		if (!is_fd_valid(fd))
			continue;
		rv = amd_read(fd, __le64_to_cpu(el[j].allocated.offset), t,
			      AMD_SECTOR);
		if (fd != d->fd)
			close(fd);
		if (rv != 0 || !t->checksum ||
		    __le64_to_cpu(t->checksum) != amd_tlog_checksum(t) ||
		    t->id.id != v->ld->id.id || !t->flags ||
		    __le32_to_cpu(t->type) != type ||
		    __le32_to_cpu(t->status) != AMD_TLOG_STARTED)
			continue;
		valid = 1;
		if (__le64_to_cpu(t->protect_start) < least)
			least = __le64_to_cpu(t->protect_start);
	}
	return valid ? least : 0;
}

/*
 * @done, but at least a MiB short of @end, at a whole MiB: md must still
 * run the resync or recovery for mdmon to see it finish.
 */
static unsigned long long amd_short_of_end(unsigned long long done,
					   unsigned long long end)
{
	if (done + AMD_MIB <= end)
		return done;
	return end > AMD_MIB ? (end - AMD_MIB) / AMD_MIB * AMD_MIB : 0;
}

/*
 * Member sector a recorded rebuild of @v resumes from: what its transform
 * log says is done, but short of the end - md must still run a recovery
 * for mdmon to see it finish.
 */
static unsigned long long amd_resume_point(struct amd_super *super,
					   struct amd_vol *v)
{
	unsigned long long done = amd_volume_to_member(v,
		amd_tlog_read(super, v, v->link,
			      __le32_to_cpu(v->ld->transform_type)));

	/*
	 * The "100 %" packet - TransformState COMPLETED, 100000 per cent: all
	 * is copied, the log may be cleared already.  The AMD driver then
	 * ends the transform without I/O (rcblob RC_RestartTask).
	 */
	if (__le32_to_cpu(v->ld->transform_percent) == AMD_PERCENT_DONE &&
	    __le32_to_cpu(v->ld->transform_state) == AMD_TRANSFORM_COMPLETED)
		done = v->component_size;
	return amd_short_of_end(done, v->component_size);
}

/*
 * Volume sector an initialization (CREATE_REDUNDANCY) of @v that was
 * stopped resumes from: what its transform log says, short of the end so
 * that md still resyncs and mdmon sees it finish.  md resyncs a mirror in
 * volume sectors (RAID10: the array's).
 */
static unsigned long long amd_init_resume_point(struct amd_super *super,
						struct amd_vol *v)
{
	unsigned long long cap = __le64_to_cpu(v->ld->capacity);
	unsigned long long done;

	if (!v->link)
		return 0;
	done = amd_tlog_read(super, v, v->link,
			     AMD_TRANSFORM_CREATE_REDUNDANCY);
	return amd_short_of_end(done, cap);
}

static int amd_disk_failed(struct amd_super *super, __u64 id)
{
	int vol, i;

	for (vol = 0; vol < super->nvol; vol++)
		for (i = 0; i < super->vol[vol].nel; i++) {
			struct amd_element *el = &super->vol[vol].el[i];

			if (__le64_to_cpu(el->id.id) == id &&
			    (__le32_to_cpu(el->flags) & AMD_ELEMENT_FAILED))
				return 1;
		}
	return 0;
}

/* md recovers onto disk @id for some volume (mdmon) */
static int amd_rebuild_target(struct amd_super *super, __u64 id)
{
	int vol;

	for (vol = 0; vol < super->nvol; vol++)
		if (super->vol[vol].mon.rebuilding &&
		    __le64_to_cpu(super->vol[vol].mon.rebuild_el.id.id) == id)
			return 1;
	return 0;
}

/* a configuration write to @d failed: it gets no further ones (amd_write_config) */
static void amd_write_failed(struct amd_disk *d)
{
	d->write_failed = 1;
	d->update = 0;
	/* the number: glibc's strerror() allocates (gettext), the monitor must not */
	amd_kmsg("cannot write the configuration to %d:%d (errno %d): it stays stale",
		 d->major, d->minor, errno);
}

/*
 * DeviceState of the PD records, as the AMD driver keeps it (rcraid 9.3.2):
 * a disk that is here is ONLINE - again, when one that failed is back; one
 * that failed or went away is OFFLINE.  The driver drops the PD of a disk
 * that was not there when it started (so does the Windows one); we keep the
 * record, OFFLINE, so that the disk is known when it is back.  Only set
 * while a configuration is written anyway: a disk still on its way at
 * assembly does not cause a write.  Other states (SMART error, new, locked)
 * are kept.
 */
static void amd_pd_states(struct amd_super *super)
{
	int i;

	for (i = 0; i < super->npd; i++) {
		struct amd_pd *pd = super->pd[i];
		__u32 state = __le32_to_cpu(pd->device_state), want;
		struct amd_disk *d;

		if (__le32_to_cpu(pd->device_type) != AMD_DEV_RAIDCORE_DISK ||
		    (state != AMD_DEV_STATE_ONLINE && state != AMD_DEV_STATE_OFFLINE))
			continue;
		d = amd_find_disk(super, __le64_to_cpu(pd->id.id));
		/* added by mdadm --add, its descriptor not handed over yet: here */
		want = d && !d->spare_failed && !d->removed &&
		       (d->fd >= 0 || d->fresh) ?
		       AMD_DEV_STATE_ONLINE : AMD_DEV_STATE_OFFLINE;
		if (state != want) {
			pd->device_state = __cpu_to_le32(want);
			dprintf("PD of disk %016llx %s\n",
				(unsigned long long)__le64_to_cpu(pd->id.id),
				want == AMD_DEV_STATE_ONLINE ? "online" : "offline");
		}
	}
}

/*
 * A configuration another controller wrote becomes this one's, as with the
 * AMD driver: it builds the configuration of disks last online elsewhere
 * (rcblob 9.3.3 RC_ReadConfig @0013d6e0, group FOREIGN) and writes it back
 * with its own serial number (RC_UpdateConfig @0013aba0) - the Windows
 * driver over what the AMD driver for Linux wrote, and that one the other
 * way round (MSI X870E, 08.11).  Here the packet gets AMD_SERIAL in place
 * of the old one: in its header, as the controller's PD and as the
 * volumes' parent reference; the commit blocks follow (amd_write_config).
 */
static void amd_take_over(struct amd_super *super)
{
	struct amd_packet_header *h = super->packet;
	__u64 old = super->serial;
	unsigned int off = __le32_to_cpu(h->ld_offset);
	struct amd_ld *ld;
	int i;

	h->modifier_sn = __cpu_to_le64(AMD_SERIAL);
	for (i = 0; i < super->npd; i++)
		if (__le64_to_cpu(super->pd[i]->id.id) == old)
			super->pd[i]->id.id = __cpu_to_le64(AMD_SERIAL);
	while ((ld = amd_next_ld(super, &off))) {
		struct amd_dev_id *ref = (struct amd_dev_id *)
			(amd_ld_elements(ld) + __le32_to_cpu(ld->first_count) *
					       __le32_to_cpu(ld->second_count));

		for (i = 0; i < (int)__le32_to_cpu(ld->parent_count); i++)
			if (__le64_to_cpu(ref[i].id) == old)
				ref[i].id = __cpu_to_le64(AMD_SERIAL);
	}
	super->serial = AMD_SERIAL;
	amd_kmsg("the configuration of controller %012llx is this one's now",
		 (unsigned long long)old);
}

/*
 * Handles of the LD records as RAIDCoreDxe gives them when it reads a
 * configuration (FUN_0002be1c): each LD takes the first free slot from 1,
 * in packet order, Legacy ones too, and its Handle is the slot number; the
 * second copy of a transform has the Handle of the first.  RoutingPath it
 * keeps as read (FUN_00026460), and every packet we know has 0 there.  If a
 * Handle differs from that, the firmware writes the configuration back at
 * boot (FUN_0002b908, RC_UpdateConfig FUN_00028e98) with the DeviceID,
 * Handle and BusType of the PD records left out (see amd_repair_pds).  A
 * deleted volume leaves a gap: the BIOS menu and the AMD driver keep the
 * Handles they have until they read the configuration again (rcblob
 * RC_AddLogicalDevice numbers the same way, RC_NextAvailableLogicalNumber),
 * and so did older versions of this code.  A volume the firmware does not
 * take (OFFLINE: its disks are not there) gets no slot and the later ones
 * move down, but then it does not write either: a volume short of its
 * disks keeps it from writing at boot (FUN_000250b8).  Nothing refers to
 * an LD by its Handle but the transform log, which the AMD driver matches
 * by DeviceID alone (rcblob RC_CheckTransformLogs).
 */
static void amd_number_lds(struct amd_super *super)
{
	struct amd_packet_header *h = super->packet;
	unsigned int off = __le32_to_cpu(h->ld_offset);
	struct amd_ld *ld;
	int slot = 0, copy = 0;

	while ((ld = amd_next_ld(super, &off))) {
		if (!copy)
			slot++;
		ld->id.handle = __cpu_to_le16(slot);
		copy = !copy && __le32_to_cpu(ld->transform_link) == 1;
	}
}

/*
 * Disk @id holds an element in service, in either LD copy, of a volume
 * that an older generation keeps it out of: any but one without
 * redundancy - and that one too when @d, the disk itself, is here and no
 * member of it (amd_disk_serves): written apart from the others, or with
 * something else in its own packet.
 */
static int amd_disk_guarded(struct amd_super *super, const struct amd_disk *d,
			    __u64 id)
{
	int vol, i;

	for (vol = 0; vol < super->nvol; vol++) {
		struct amd_vol *v = &super->vol[vol];
		int plain = amd_volume_plain(v);

		for (i = 0; i < v->nel; i++)
			if (__le64_to_cpu(v->el[i].id.id) == id &&
			    amd_element_usable(&v->el[i]) &&
			    (!plain ||
			     (d && !amd_disk_serves(super, d, v, &v->el[i]))))
				return 1;
		for (i = 0; i < amd_link_nel(v); i++)
			if (__le64_to_cpu(amd_link_elements(v)[i].id.id) == id &&
			    amd_element_usable(&amd_link_elements(v)[i]))
				return 1;
	}
	return 0;
}

/*
 * @d is a RAID disk of the configuration that is here, with the live
 * configuration or an older one, and no volume needs what it has: a free
 * disk, a spare, a member out of service (failed, offline, or replaced) -
 * or a member of volumes without redundancy only, which missed nothing
 * with an older configuration (amd_volume_disk) and, left stale, would
 * stay so for good.
 * The AMD driver writes each configuration to every RAIDCore disk that is
 * here (rcblob 9.3.3 RC_WriteAllConfigData @00134ad0: PD ONLINE, as a disk
 * a scan finds is, RC_InsertCorePhysicalDevice @0015b670), and a disk that
 * comes back makes it scan and write again (RC_ConfigRescan @0015c8e0); so
 * does mdmon.  Left stale, such a disk would make Incremental refuse the
 * next one when it is the container's first device (its UUID is of the
 * old packet), and hold back the end of a rebuild or an initialization
 * (amd_all_disks_here).
 *
 * Not a member in service of a mirror or a RAID5 (amd_disk_guarded): its
 * older generation is what keeps it out of the volume (amd_disk_current),
 * or has a rebuild target copied from 0
 * (amd_spare_target).  Not a disk md failed while mdmon runs - it may be
 * dying - until it has left the container and is back (amd_attach_update).
 * One that failed before (its element FAILED, 0x10) is idle as the others:
 * the AMD driver writes to every disk a scan finds, failed elements or not
 * (rcraid at start-up, notes/rcraid-judge.md D); the element keeps it out
 * of the volume, and a rebuild onto it copies it from 0 (amd_spare_own).
 */
static int amd_disk_idle(struct amd_super *super, const struct amd_disk *d)
{
	return d->fd >= 0 && !d->removed && !d->write_failed &&
	       !d->spare_failed && d->commit_valid &&
	       d->generation <= super->generation &&
	       d->foreign == super->foreign &&
	       amd_pd_index(super, d->device_id) >= 0 &&
	       !amd_rebuild_target(super, d->device_id) &&
	       !amd_disk_guarded(super, d, d->device_id);
}

/* Packet @h (@nsec sectors) to the next slot of @d's ring, at d->new_lba. */
static int amd_put_packet(struct amd_disk *d, struct amd_packet_header *h,
			  unsigned int nsec)
{
	__u32 lba = d->packet_lba + (d->packet_size + AMD_SECTOR - 1) / AMD_SECTOR;

	if (lba < AMD_RING_LBA || lba + nsec > AMD_RING_END)
		lba = AMD_RING_LBA;
	h->prev_offset = __cpu_to_le32(d->packet_lba);	/* not checksummed */
	if (pwrite(d->fd, h, nsec * AMD_SECTOR, (off_t)lba * AMD_SECTOR) !=
	    (ssize_t)(nsec * AMD_SECTOR) || fsync(d->fd) != 0) {
		amd_write_failed(d);
		return -1;
	}
	d->new_lba = lba;
	return 0;
}

/* The commit block naming @d's new packet (amd_put_packet), generation @gen. */
static int amd_put_commit(struct amd_super *super, struct amd_disk *d,
			  __u64 gen)
{
	struct amd_packet_header *h = super->packet;
	struct amd_commit *c = super->iobuf;

	memset(c, 0, AMD_SECTOR);
	c->packet_offset = __cpu_to_le32(d->new_lba);
	c->packet_size = __cpu_to_le32(super->packet_len);
	c->committed_checksum = h->checksum;
	c->generation = __cpu_to_le64(gen);
	c->last_modifier_sn = __cpu_to_le64(super->serial);
	c->last_online_sn = __cpu_to_le64(super->serial);
	c->packet_number = __cpu_to_le64(d->packet_number + 1);
	c->checksum = __cpu_to_le64(amd_sector_sum(c));
	if (pwrite(d->fd, c, AMD_SECTOR,
		   (off_t)AMD_COMMIT_LBA * AMD_SECTOR) != AMD_SECTOR ||
	    fsync(d->fd) != 0) {
		amd_write_failed(d);
		return -1;
	}
	d->packet_lba = d->new_lba;
	d->packet_size = super->packet_len;
	d->generation = gen;
	d->committed_checksum = __le64_to_cpu(h->checksum);
	d->packet_number++;
	d->last_online = super->serial;
	d->foreign = super->serial != AMD_SERIAL;
	amd_note_own(d, super);
	return 0;
}

/*
 * Write the in-memory packet as a new configuration, like the AMD driver
 * (RC_UpdateConfig): the packet goes to the next slot of each up-to-date
 * disk's ring, then every such disk gets a commit block naming it with
 * the generation number bumped; so does an idle disk (amd_disk_idle).
 * Other disks that are missing or stale are left alone and stay stale,
 * and so does a disk a write fails on: as with IMSM, the others get the
 * configuration all the same (it may record that very disk's failure),
 * and with its older generation the next assembly does not take that
 * disk as current.  Fails only if no disk took the configuration.
 */
static int amd_write_config(struct amd_super *super)
{
	struct amd_packet_header *h = super->packet;
	unsigned int size = super->packet_len;
	unsigned int nsec = (size + AMD_SECTOR - 1) / AMD_SECTOR;
	__u64 gen = super->generation + 1;
	struct amd_disk *d;
	int n = 0;

	if (!h || !super->iobuf)
		return -1;
	for (d = super->disks; d; d = d->next) {
		/*
		 * A member md has failed while mdmon runs may be dying: do not
		 * write to it (spare_failed).  One that failed before is an
		 * idle disk (amd_disk_idle).  A former member being rebuilt in
		 * its slot, stale or out of service in the LD, gets the
		 * configuration again.
		 */
		int back = d->rejoin || amd_rebuild_target(super, d->device_id);

		/* one taken out of the container is gone, as a missing one */
		d->update = !d->removed && !d->write_failed &&
			    (amd_disk_current(super, d) || back) &&
			    !d->spare_failed &&
			    (back || !amd_disk_failed(super, d->device_id));
		if (d->update && d->fd < 0)
			return -1;	/* all of them, or none */
		d->update |= amd_disk_idle(super, d);
		n += d->update;
	}
	if (n == 0)
		return -1;

	if (super->serial != AMD_SERIAL)
		amd_take_over(super);
	amd_pd_states(super);
	amd_number_lds(super);
	/* as observed: the packet carries the previous generation number */
	h->generation = __cpu_to_le64(super->generation);
	h->checksum = __cpu_to_le64(amd_checksum((char *)h + 0x0c, size - 0x0c));

	for (d = super->disks; d; d = d->next)
		if (d->update)
			amd_put_packet(d, h, nsec);

	n = 0;
	for (d = super->disks; d; d = d->next)
		if (d->update && amd_put_commit(super, d, gen) == 0)
			n++;
	if (n == 0)
		return -1;
	super->generation = gen;
	super->foreign = super->serial != AMD_SERIAL;
	return 0;
}

/*
 * The disk of the target recorded for @v is here but missed configurations:
 * md wrote without it (amd_target_behind).  No member to wait for - mdmon
 * copies it from 0 (amd_target_disk), as does the AMD driver.
 */
static int amd_target_stale(struct amd_super *super, const struct amd_vol *v)
{
	int slot = amd_rebuild_slot(v);
	struct amd_disk *d;

	if (slot < 0)
		return 0;
	d = amd_find_disk(super, __le64_to_cpu(amd_link_elements(v)[slot].id.id));
	return d && (d->major || d->minor) && !amd_disk_current(super, d);
}

/* the md device of element @el of a volume, in slot @slot, on disk @d */
static struct mdinfo *amd_member_info(struct amd_super *super,
				      const struct amd_element *el,
				      const struct amd_disk *d, int slot)
{
	struct mdinfo *dev = xcalloc(1, sizeof(*dev));

	dev->disk.number = slot;
	dev->disk.major = d->major;
	dev->disk.minor = d->minor;
	dev->disk.raid_disk = slot;
	dev->events = super->generation;
	dev->data_offset = __le64_to_cpu(el->user_data.offset);
	dev->component_size = __le64_to_cpu(el->user_data.size);
	if (d->devname)
		snprintf(dev->name, sizeof(dev->name), "%s", d->devname);
	return dev;
}

/* Where md starts the resync of @v (array @this), if it needs one. */
static void amd_resync_start(struct amd_super *super, struct amd_vol *v,
			     struct mdinfo *this)
{
	unsigned long long done = MaxSector;
	unsigned int first = 0;
	int bm;

	if (!v->managed)
		return;
	/*
	 * Bits left in the AMD bitmap (unclean shutdown), or the volume
	 * is not initialized yet: resync.  An initialization goes on
	 * from its transform log, as the AMD driver resumes it
	 * (RC_RestartTask) - but not past bits in the bitmap: those
	 * are writes that were in flight when the system went down,
	 * below the log too (mdmon marks the bitmap while md writes,
	 * an initialization alone leaves it clean), so the resync
	 * starts at the first one - from 0 after mdmon's "anywhere";
	 * after a resync that stopped cleanly, from where it stopped.
	 * A volume with the root file system on it must be left
	 * clean at shutdown (mdadm --wait-clean from the shutdown
	 * ramfs), or every reboot looks like a crash.
	 */
	bm = amd_bitmap_read(super, v, &first);
	if (bm == 1)
		done = (unsigned long long)first * amd_bitmap_cover(v);
	if (v->init_pending) {
		unsigned long long logged = amd_init_resume_point(super, v);

		if (logged < done)
			done = logged;
	}
	/*
	 * The bitmap is on element [0][0] only (the AMD driver too does
	 * no bitmap I/O without it): a RAID10 without that member could
	 * not record a crash, its other mirrors may differ - resync.
	 * (A RAID1 without it has one mirror left; a RAID5 without it
	 * is degraded: md could not resync it, nor could the AMD
	 * driver have recorded a crash.)  With -I per disk, an mdadm
	 * that has not got [0][0] yet may set the array up so; the one
	 * that starts it gives md its own resync point
	 * (assemble_container_content).
	 */
	if (!v->init_pending && bm < 0 && v->level == 10)
		done = 0;
	if (done == MaxSector)
		return;
	this->array.state &= ~(1 << MD_SB_CLEAN);
	this->resync_start = amd_volume_to_sync(v, done);
}

/* The members of @v that are here, and its rebuild target, as this->devs. */
static void amd_volume_devs(struct amd_super *super, struct amd_vol *v,
			    struct mdinfo *this)
{
	struct mdinfo **dtail = &this->devs;
	char *insync = xcalloc(this->array.raid_disks + 1, 1);
	int i, run;

	for (i = 0; i < v->nel; i++) {
		struct amd_element *el = &v->el[i];
		struct amd_disk *d;
		struct mdinfo *dev;

		if (!amd_slot_usable(v, i))
			continue;
		this->array.working_disks++;
		d = amd_volume_disk(super, v, el);
		if (!d || (d->major == 0 && d->minor == 0))
			continue;
		if (i < this->array.raid_disks)
			insync[i] = 1;
		dev = amd_member_info(super, el, d, i);
		dev->disk.state = (1 << MD_DISK_SYNC) | (1 << MD_DISK_ACTIVE);
		dev->recovery_start = MaxSector;
		*dtail = dev;
		dtail = &dev->next;
	}
	/*
	 * -I waits for the disk of a recorded rebuild's target as for any
	 * member, which then goes on from the log: a target missing at the
	 * start would miss what is written until it comes - a configuration
	 * already (the volume running on the first disk, stand 11.11): copied
	 * from 0 then (amd_activate_spare).  A target that missed
	 * configurations is copied from 0 anyway: not waited for.
	 * The same for the mirror a RAIDABLE grows by, a member of its RAID1
	 * LD (the AMD driver's view: a RAID1 of two).
	 */
	if (amd_rebuild_slot(v) >= 0 && (v->managed || v->grow) &&
	    !amd_target_stale(super, v))
		this->array.working_disks++;
	/*
	 * A rebuild recorded as RESTORE_SEGMENTS (by mdmon or the AMD
	 * driver) goes on where its transform log says it got to.
	 * Its target only once the members in sync can run the volume:
	 * it counts as present to mdadm, and md would be started on a
	 * target with nothing to copy from (-I, the target came first).
	 */
	i = amd_rebuild_slot(v);
	run = enough(this->array.level, this->array.raid_disks,
		     this->array.layout, 1, insync);
	free(insync);
	if (i >= 0 && v->managed && run) {
		struct amd_element *el = &amd_link_elements(v)[i];
		struct amd_disk *d = amd_member_disk(super,
					__le64_to_cpu(el->id.id));

		if (!d || (d->major == 0 && d->minor == 0))
			return;
		*dtail = amd_member_info(super, el, d, i);
		(*dtail)->recovery_start = amd_resume_point(super, v);
	}
}

/*
 * md's own write-intent bitmap ("md bitmap") for a RAID1, RAID10 or RAID5
 * under mdmon: after a crash md resyncs only what it was writing, not the
 * whole volume.  The AMD bitmap is far coarser (4096 bits for the volume,
 * 8 GiB a bit on a 20 TB one) and only on element [0][0].  As for IMSM, md
 * keeps the bits alone (bitmap/metadata=external: no md superblock, the
 * kernel reads and writes nothing but the bits) at one LBA on every member
 * (bitmap/location is added to rdev->sb_start, 0 for a member of external
 * metadata): the elements must all start at one AllocatedSpace.SectorOffset.
 *
 * Its area is AllocatedSpace + 0x100 .. + 0x600 of each element.  The AMD
 * firmware and drivers use +0 (transform log), +2 (array scan log), +0x80
 * (their bitmap) and +0x600 (the data-move log of a migration) of the
 * service area, nothing else (rcblob, rcraid.sys 9.3.3.218, RAIDCoreDxe;
 * a pattern there outlived rcraid, the Windows driver and the firmware -
 * notes/agent-bitmap-space.md).  Counted from AllocatedSpace, not from the
 * user data: a migration of the AMD driver moves that to +0x800.  Our
 * header takes the first page, the bits the rest.  The header alone says
 * that the volume has an md bitmap - AMD's metadata has no field for it -
 * and it has to be checked on each member: the AMD drivers neither copy
 * nor clear the area, a rebuild leaves on the new element what the disk
 * had there.
 */
#define AMD_MDBM_OFFSET		0x100	/* from AllocatedSpace.SectorOffset */
#define AMD_MDBM_SECTORS	0x500
#define AMD_MDBM_HEADER		8	/* sectors: a page, the kernel writes the bits in pages */
#define AMD_MDBM_ROOM		((AMD_MDBM_SECTORS - AMD_MDBM_HEADER) * AMD_SECTOR)
#define AMD_MDBM_CHUNK		(64 << 20)	/* bytes per bit, at least (as IMSM) */
#define AMD_MDBM_CHUNK_MAX	(1U << 21)	/* sectors: 1 GiB a bit, 5 PiB in all */
#define AMD_MDBM_DAEMON		5	/* bitmap/time_base, seconds (as IMSM) */
#define AMD_MDBM_VERSION	1
/*
 * amd_mdbm.amd_bitmap: the AMD bitmap as mdmon writes it in this session -
 * k: clean, or dirty from bit k to the end (one header for both, so that a
 * write to an idle volume costs the headers nothing); AMD_MDBM_AMD_CLEAN:
 * clean only, as mdmon left it when md stopped the array (or as set_bitmap
 * found it).
 */
#define AMD_MDBM_AMD_CLEAN	0xffffffffU
#define AMD_MDBM_AMD_UNKNOWN	0xfffffffeU	/* not read (no element [0][0]), or not mdmon's */
#define AMD_MDBM_UNKEPT		0xfffffffdU	/* md keeps no bits: trust none */

#define AMD_MDBM_MAGIC	"mdadmWIB"	/* amd_mdbm.magic, without the NUL */

struct amd_mdbm {
	__u64 checksum;		/* amd_sector_sum */
	char magic[8];
	__u32 version;
	__u32 chunk;		/* sectors a bit covers */
	__u64 volume_id;	/* the LD's: no header of a volume deleted before */
	__u64 bits_lba;		/* bitmap/location */
	__u64 sync_sectors;	/* what the bits cover: md's resync_max_sectors */
	/*
	 * The AMD configuration and bitmap as mdmon last wrote them: still
	 * so, and no one else has written the volume since (amd_mdbm_own).
	 */
	__u64 generation;
	__u64 config_checksum;
	__u32 amd_bitmap;
	__u32 reserved[111];
} __attribute__((packed));

_Static_assert(sizeof(struct amd_mdbm) == AMD_SECTOR, "md bitmap header");

/*
 * The md bitmap area of @el ends where its user data begins, or before: the
 * AMD drivers put the data 0x5000 or 0x800 sectors into the element (rcblob
 * IsElementSnapDown, IsElementSnapUp), but the offsets are read from the
 * disk - an element laid out otherwise has no room for the area.
 */
static int amd_mdbm_room(const struct amd_element *el)
{
	unsigned long long at = __le64_to_cpu(el->allocated.offset);
	unsigned long long data = __le64_to_cpu(el->user_data.offset);

	return data >= at && data - at >= AMD_MDBM_OFFSET + AMD_MDBM_SECTORS;
}

/* LBA of the md bitmap area of @v (its header), or 0 if it can have none */
static unsigned long long amd_mdbm_lba(const struct amd_vol *v)
{
	unsigned long long base = 0;
	int i, slot = amd_rebuild_slot(v);

	if (!v->managed || v->single || v->grow ||
	    (v->level != 1 && v->level != 10 && v->level != 5))
		return 0;
	for (i = 0; i < v->nel; i++) {
		unsigned long long at = __le64_to_cpu(v->el[i].allocated.offset);

		if (!amd_slot_usable(v, i))
			continue;
		if ((base && at != base) || !amd_mdbm_room(&v->el[i]))
			return 0;
		base = at;
	}
	/* the target of a rebuild the AMD driver started joins them */
	if (slot >= 0 &&
	    (__le64_to_cpu(amd_link_elements(v)[slot].allocated.offset) != base ||
	     !amd_mdbm_room(&amd_link_elements(v)[slot])))
		return 0;
	if (!base || base % AMD_MDBM_HEADER)
		return 0;
	return base + AMD_MDBM_OFFSET;
}

/* sectors the bits cover: md's resync_max_sectors (amd_sync_to_volume) */
static unsigned long long amd_mdbm_sync(const struct amd_vol *v)
{
	return amd_volume_to_sync(v, __le64_to_cpu(v->ld->capacity));
}

static unsigned long long amd_mdbm_nbits(const struct amd_vol *v,
					 unsigned int chunk)
{
	return (amd_mdbm_sync(v) + chunk - 1) / chunk;
}

/*
 * Bytes of bits at @chunk sectors a bit, in whole pages as md writes them.
 * Not a size_t: where that has 32 bits, the bits of a large volume at a
 * small @chunk (a header's, --bitmap-chunk) would seem to fit the area.
 */
static unsigned long long amd_mdbm_bytes(const struct amd_vol *v,
					 unsigned int chunk)
{
	return ROUND_UP((amd_mdbm_nbits(v, chunk) + 7) / 8, 4096ULL);
}

/*
 * Sectors a bit covers: @want (--bitmap-chunk), or the least power of two
 * from 64 MiB up whose bits fit the area - 64 MiB a bit covers 318 TiB.
 * 0 if @want does not fit.
 */
static unsigned int amd_mdbm_chunk(const struct amd_vol *v, unsigned int want)
{
	unsigned int chunk = want ? want : AMD_MDBM_CHUNK / AMD_SECTOR;

	while (amd_mdbm_bytes(v, chunk) > AMD_MDBM_ROOM) {
		if (want || chunk >= AMD_MDBM_CHUNK_MAX)
			return 0;
		chunk <<= 1;
	}
	return chunk;
}

/* @h is a header of @v's md bitmap, of its geometry now */
static int amd_mdbm_valid(const struct amd_vol *v, const struct amd_mdbm *h)
{
	unsigned int chunk = __le32_to_cpu(h->chunk);

	return __le64_to_cpu(h->checksum) == amd_sector_sum(h) &&
	       memcmp(h->magic, AMD_MDBM_MAGIC, sizeof(h->magic)) == 0 &&
	       __le32_to_cpu(h->version) == AMD_MDBM_VERSION &&
	       h->volume_id == v->ld->id.id &&
	       __le64_to_cpu(h->bits_lba) == amd_mdbm_lba(v) + AMD_MDBM_HEADER &&
	       __le64_to_cpu(h->sync_sectors) == amd_mdbm_sync(v) &&
	       chunk && (chunk & (chunk - 1)) == 0 &&
	       chunk <= AMD_MDBM_CHUNK_MAX &&
	       amd_mdbm_bytes(v, chunk) <= AMD_MDBM_ROOM;
}

static void amd_mdbm_header(struct amd_super *super, const struct amd_vol *v,
			    unsigned int chunk, __u32 amd, struct amd_mdbm *h)
{
	const struct amd_packet_header *p = super->packet;

	memset(h, 0, sizeof(*h));
	memcpy(h->magic, AMD_MDBM_MAGIC, sizeof(h->magic));
	h->version = __cpu_to_le32(AMD_MDBM_VERSION);
	h->chunk = __cpu_to_le32(chunk);
	h->volume_id = v->ld->id.id;
	h->bits_lba = __cpu_to_le64(amd_mdbm_lba(v) + AMD_MDBM_HEADER);
	h->sync_sectors = __cpu_to_le64(amd_mdbm_sync(v));
	h->generation = __cpu_to_le64(super->generation);
	h->config_checksum = p->checksum;
	h->amd_bitmap = __cpu_to_le32(amd);
	h->checksum = __cpu_to_le64(amd_sector_sum(h));
}

/*
 * The disks of @v's members in service that are here and up to date, and
 * where the md bitmap area of each is (if @lba).  With @every, the disks of
 * all its elements that are here: one out of service keeps what its area
 * has, and a rebuild in place (amd_spare_own) would bring a header back -
 * unless its extent is another volume's by now (amd_extent_given_away).
 */
static int amd_mdbm_disks(struct amd_super *super, const struct amd_vol *v,
			  int every, struct amd_disk **disks,
			  unsigned long long *lba)
{
	int i, n = 0;

	for (i = 0; i < v->nel && n < AMD_MAX_PD; i++) {
		__u64 id = __le64_to_cpu(v->el[i].id.id);
		struct amd_disk *d;

		if (!amd_slot_usable(v, i) &&
		    (!every || amd_extent_given_away(super, v, i)))
			continue;
		d = every ? amd_find_disk(super, id) : amd_member_disk(super, id);
		if (!d || (!d->major && !d->minor) || d->removed ||
		    d->spare_failed)
			continue;
		if (lba)
			lba[n] = __le64_to_cpu(v->el[i].allocated.offset) +
				 AMD_MDBM_OFFSET;
		disks[n++] = d;
	}
	return n;
}

/* Read the area past the page cache: md writes the bits so. */
static int amd_mdbm_pread(const struct amd_disk *d, unsigned long long lba,
			  void *buf, size_t len)
{
	int fd = amd_dev_open(d->major, d->minor, O_RDONLY | O_DIRECT);
	int rv;

	if (!is_fd_valid(fd))
		return -1;
	rv = amd_read(fd, lba, buf, len);
	close(fd);
	return rv;
}

/*
 * Write header @h and, unless NULL, @len bytes of bits @bits to the area at
 * LBA @lba of disk @d: through the container's descriptor if there is one
 * (mdmon; mdadm with the container loaded), else past the page cache - and
 * on the media either way (fsync).  Bits are only written before md runs
 * the bitmap, md never writes the header's page, and the area is read past
 * the page cache only (amd_mdbm_pread): what the page cache keeps of it is
 * never read back nor written over md's.  The bits first: a header names
 * bits that are there.
 */
static int amd_mdbm_write(struct amd_disk *d, unsigned long long lba,
			  const struct amd_mdbm *h, const void *bits,
			  size_t len)
{
	off_t at = (off_t)lba * AMD_SECTOR;
	int fd = d->fd >= 0 ? d->fd :
		 amd_dev_open(d->major, d->minor, O_RDWR | O_DIRECT);
	int rv = -1;

	if (!is_fd_valid(fd))
		return -1;
	if (bits && pwrite(fd, bits, len, at + AMD_MDBM_HEADER * AMD_SECTOR) !=
		    (ssize_t)len)
		goto out;
	if (pwrite(fd, h, AMD_SECTOR, at) == AMD_SECTOR && fsync(fd) == 0)
		rv = 0;
out:
	if (fd != d->fd)
		close(fd);
	return rv;
}

/*
 * ... on the members of @v here (amd_mdbm_disks), @every: on all its
 * elements.  0, or -1 if some write failed.
 */
static int amd_mdbm_put(struct amd_super *super, const struct amd_vol *v,
			int every, const struct amd_mdbm *h, const void *bits,
			size_t len)
{
	struct amd_disk *disks[AMD_MAX_PD];
	unsigned long long lba[AMD_MAX_PD];
	int i, n = amd_mdbm_disks(super, v, every, disks, lba), rv = 0;

	for (i = 0; i < n; i++)
		if (amd_mdbm_write(disks[i], lba[i], h, bits, len) != 0)
			rv = -1;
	return n ? rv : -1;
}

/*
 * @v has no md bitmap any more: no header on any of its elements - else
 * the next assembly would see one and take the bitmap up again.  The zero
 * sector is iobuf: the monitor allocates nothing (amd_mm_room).
 */
static int amd_mdbm_clear(struct amd_super *super, const struct amd_vol *v)
{
	if (!super->iobuf)
		return -1;
	memset(super->iobuf, 0, AMD_SECTOR);
	return amd_mdbm_put(super, v, 1, super->iobuf, NULL, 0);
}

/* the first header of @v's md bitmap on a member here, into @h (a sector) */
static int amd_mdbm_find(struct amd_super *super, const struct amd_vol *v,
			 struct amd_mdbm *h)
{
	unsigned long long lba = amd_mdbm_lba(v);
	struct amd_disk *disks[AMD_MAX_PD];
	int i, n = amd_mdbm_disks(super, v, 0, disks, NULL);

	for (i = 0; lba && i < n; i++)
		if (amd_mdbm_pread(disks[i], lba, h, AMD_SECTOR) == 0 &&
		    amd_mdbm_valid(v, h))
			return 1;
	return 0;
}

/* some member of @v here has a header of its md bitmap */
static int amd_mdbm_present(struct amd_super *super, const struct amd_vol *v)
{
	struct amd_mdbm *h = amd_alloc(AMD_SECTOR);
	int found = h && amd_mdbm_find(super, v, h);

	free(h);
	return found;
}

/*
 * The headers of @v's md bitmap (@chunk sectors a bit) trust no bits
 * (AMD_MDBM_UNKEPT): md does not keep them, or is about to stop.  0, or -1
 * if some write failed.
 */
static int amd_mdbm_unkept(struct amd_super *super, const struct amd_vol *v,
			   unsigned int chunk)
{
	struct amd_mdbm *h = super->mmbuf;	/* managemon's: amd_mdbm_stop */

	if (!h)
		return -1;
	amd_mdbm_header(super, v, chunk, AMD_MDBM_UNKEPT, h);
	return amd_mdbm_put(super, v, 0, h, NULL, 0);
}

/*
 * A new md bitmap of @v: @chunk sectors a bit, every bit @fill (0 or 0xff).
 * md keeps none of them yet: set_bitmap takes them up.
 */
static int amd_mdbm_init(struct amd_super *super, struct amd_vol *v,
			 unsigned int chunk, int fill)
{
	size_t len = amd_mdbm_bytes(v, chunk);
	struct amd_mdbm *h = amd_alloc(AMD_SECTOR);
	void *bits = amd_alloc(len);
	int rv = -1;

	if (h && bits) {
		memset(bits, fill, len);
		amd_mdbm_header(super, v, chunk, AMD_MDBM_UNKEPT, h);
		rv = amd_mdbm_put(super, v, 0, h, bits, len);
	}
	free(h);
	free(bits);
	return rv;
}

/*
 * AMD bitmap @buf of @v as mdmon writes it: AMD_MDBM_AMD_CLEAN, the bit it is
 * dirty from - or AMD_MDBM_AMD_UNKNOWN, not so (the AMD driver's own bits).
 */
static __u32 amd_bitmap_pattern(const struct amd_vol *v, const __u8 *buf)
{
	__u8 want[AMD_BITMAP_BYTES];
	int first = amd_bitmap_first(v, buf);

	if (first < 0)
		return AMD_MDBM_AMD_CLEAN;
	amd_bitmap_fill(v, want, 1, first);
	return memcmp(want, buf, sizeof(want)) ? AMD_MDBM_AMD_UNKNOWN : (__u32)first;
}

/*
 * Header @h is mdmon's last word, and no one has written the volume since:
 * the AMD configuration is still the one it wrote or found (the AMD drivers
 * write theirs as they start, rcraid.sys 9.3.3.218 RC_ConfigInit; the BIOS
 * writes none at POST) and the AMD bitmap is as it left it (the AMD driver
 * sets its bits before each write, rcblob RC_SetLogicalBitmap): clean, or
 * dirty from the bit the header names.  Without element [0][0] (@amd
 * unreadable, < 0) the configuration has to do.  Never bits md did not
 * keep (AMD_MDBM_UNKEPT).
 */
static int amd_mdbm_own(struct amd_super *super, const struct amd_mdbm *h,
			long long amd)
{
	const struct amd_packet_header *p = super->packet;
	__u32 was = __le32_to_cpu(h->amd_bitmap);

	if (was == AMD_MDBM_UNKEPT ||
	    __le64_to_cpu(h->generation) != super->generation ||
	    h->config_checksum != p->checksum)
		return 0;
	if (amd < 0)
		return 1;
	if (amd == AMD_MDBM_AMD_UNKNOWN || was == AMD_MDBM_AMD_UNKNOWN)
		return 0;
	return amd == was || amd == AMD_MDBM_AMD_CLEAN;
}

/* Set the bits of md bitmap @bits of @v for volume sectors @start to @end. */
static void amd_mdbm_mark(const struct amd_vol *v, __u8 *bits,
			  unsigned int chunk, unsigned long long start,
			  unsigned long long end)
{
	unsigned long long i = amd_volume_to_sync(v, start) / chunk;
	unsigned long long last = (amd_volume_to_sync(v, end) + chunk - 1) / chunk;

	if (last > amd_mdbm_nbits(v, chunk))
		last = amd_mdbm_nbits(v, chunk);
	for (; i < last; i++)
		bits[i >> 3] |= 1 << (i & 7);
}

/* ... where AMD bitmap @amd of @v has bits: Cover sectors each */
static void amd_mdbm_from_amd(const struct amd_vol *v, __u8 *bits,
			      unsigned int chunk, const __u8 *amd)
{
	unsigned long long cover = amd_bitmap_cover(v);
	unsigned long long cap = __le64_to_cpu(v->ld->capacity);
	unsigned int i, n = amd_bitmap_bits(v);

	for (i = 0; i < n; i++)
		if (amd[i >> 3] & (1 << (i & 7)))
			amd_mdbm_mark(v, bits, chunk, i * cover,
				      (i + 1) * cover < cap ? (i + 1) * cover : cap);
}

/* sectors a bit: the headers' (--bitmap-chunk at -C) while it fits the volume */
static unsigned int amd_mdbm_chunk_of(struct amd_super *super,
				      const struct amd_vol *v, struct amd_mdbm *h)
{
	return amd_mdbm_find(super, v, h) ? __le32_to_cpu(h->chunk) :
					    amd_mdbm_chunk(v, 0);
}

/*
 * OR the bits of every member of @v here with a header of @chunk into @bits
 * (@len bytes; @b: a buffer as large, @h: a sector).  1 if one of them is
 * mdmon's last word (amd_mdbm_own, @amd: the AMD bitmap's pattern or -1).
 * Any member's bits count: one may be another's, all of them are a crash's
 * at worst.
 */
static int amd_mdbm_union(struct amd_super *super, const struct amd_vol *v,
			  unsigned int chunk, __u8 *bits, __u8 *b, size_t len,
			  struct amd_mdbm *h, long long amd)
{
	unsigned long long lba = amd_mdbm_lba(v);
	struct amd_disk *disks[AMD_MAX_PD];
	int i, n = amd_mdbm_disks(super, v, 0, disks, NULL), own = 0;
	size_t j;

	for (i = 0; i < n; i++) {
		if (amd_mdbm_pread(disks[i], lba, h, AMD_SECTOR) != 0 ||
		    !amd_mdbm_valid(v, h) || __le32_to_cpu(h->chunk) != chunk ||
		    amd_mdbm_pread(disks[i], lba + AMD_MDBM_HEADER, b, len) != 0)
			continue;
		for (j = 0; j < len; j++)
			bits[j] |= b[j];
		own |= amd_mdbm_own(super, h, amd);
	}
	return own;
}

/*
 * The bits md is to start @v with (@len bytes, @chunk sectors a bit; @amd:
 * the AMD bitmap's pattern now).  The members' own if mdmon with this
 * bitmap was the last to write the volume - else theirs and where the AMD
 * bitmap has bits, or all if it cannot be read: the AMD driver may have
 * written anywhere.  And all of an initialization left (md resyncs only the
 * bits from resync_start on).
 */
static __u8 *amd_mdbm_merge(struct amd_super *super, struct amd_vol *v,
			    unsigned int *chunk, size_t *len, __u32 *amd)
{
	struct amd_mdbm *h = amd_alloc(AMD_SECTOR);
	__u8 *amdbuf = amd_alloc(AMD_BITMAP_BYTES);
	__u8 *bits = NULL, *b = NULL;
	long long state = -1;
	int own;

	if (!h || !amdbuf)
		goto out;
	*chunk = amd_mdbm_chunk_of(super, v, h);
	if (!*chunk)
		goto out;	/* too large for one, and no header says otherwise */
	*len = amd_mdbm_bytes(v, *chunk);
	bits = amd_alloc(*len);
	b = amd_alloc(*len);
	if (!bits || !b) {
		free(bits);
		bits = NULL;
		goto out;
	}
	if (amd_bitmap_load(super, v, amdbuf) == 0)
		state = amd_bitmap_pattern(v, amdbuf);
	*amd = state < 0 ? AMD_MDBM_AMD_UNKNOWN : state;
	own = amd_mdbm_union(super, v, *chunk, bits, b, *len, h, state);
	if (!own && state >= 0)
		amd_mdbm_from_amd(v, bits, *chunk, amdbuf);
	else if (!own)
		memset(bits, 0xff, *len);
	if (v->init_pending)
		amd_mdbm_mark(v, bits, *chunk, amd_init_resume_point(super, v),
			      __le64_to_cpu(v->ld->capacity));
	dprintf("subarray-%d: md bitmap %s, chunk %u\n", (int)(v - super->vol),
		own ? "own" : "rebuilt", *chunk);
out:
	free(h);
	free(amdbuf);
	free(b);
	return bits;
}

/* md runs @v with its md bitmap: before it starts (Create, Assemble) */
static int amd_mdbm_sysfs(struct mdinfo *info, const struct amd_vol *v,
			  unsigned int chunk)
{
	char loc[32];

	snprintf(loc, sizeof(loc), "+%llu", amd_mdbm_lba(v) + AMD_MDBM_HEADER);
	if (sysfs_set_str(info, NULL, "bitmap/metadata", MD_EXT) ||
	    sysfs_set_num(info, NULL, "bitmap/chunksize",
			  (unsigned long long)chunk * AMD_SECTOR) ||
	    sysfs_set_num(info, NULL, "bitmap/space",
			  AMD_MDBM_SECTORS - AMD_MDBM_HEADER) ||
	    sysfs_set_num(info, NULL, "bitmap/time_base", AMD_MDBM_DAEMON) ||
	    sysfs_set_str(info, NULL, "bitmap/location", loc))
		return -1;
	return 0;
}

/*
 * set_bitmap: md is to run volume @info with its md bitmap (Create,
 * assemble_container_content).  The bits are made right on every member
 * first - md reads them from any.  If md cannot take the bitmap (from 6.18
 * md has no bitmap/ until an array runs, nor then the attributes for an
 * external one), the volume runs with the resync policy: a crash then
 * costs a whole resync, as without a bitmap, and the headers trust no bits
 * (AMD_MDBM_UNKEPT) - md does not keep them meanwhile.  Never fails:
 * the volume is not to stay down for its bitmap (Create would leave it so).
 */
static int set_bitmap_amd(struct supertype *st, struct mdinfo *info)
{
	struct amd_super *super = st->sb;
	int vol = info->container_member;
	struct amd_mdbm *h = amd_alloc(AMD_SECTOR);
	unsigned int chunk;
	struct amd_vol *v;
	__u8 *bits = NULL;
	__u32 amd;
	size_t len;

	if (!super || vol < 0 || vol >= super->nvol || !h)
		goto out;
	v = &super->vol[vol];
	if (!amd_mdbm_lba(v))
		goto out;
	bits = amd_mdbm_merge(super, v, &chunk, &len, &amd);
	if (!bits)
		goto out;
	amd_mdbm_header(super, v, chunk, amd, h);
	if (amd_mdbm_put(super, v, 0, h, bits, len) != 0) {
		pr_err("subarray-%d: cannot write its md bitmap: it runs without one, and a crash resyncs it whole\n",
		       vol);
	} else if (amd_mdbm_sysfs(info, v, chunk) != 0) {
		pr_err("subarray-%d: this kernel cannot run an md bitmap for external metadata (md/bitmap/metadata): it runs without one, and a crash resyncs it whole\n",
		       vol);
	} else {
		dprintf("subarray-%d: md bitmap at %llu, chunk %u\n", vol,
			amd_mdbm_lba(v) + AMD_MDBM_HEADER, chunk);
		goto out;
	}
	amd_mdbm_unkept(super, v, chunk);
out:
	free(h);
	free(bits);
	return 0;
}

static struct mdinfo *container_content_amd(struct supertype *st,
					    char *subarray)
{
	struct amd_super *super = st->sb;
	struct mdinfo *rest = NULL, **tail = &rest;
	int vol;

	for (vol = 0; vol < super->nvol; vol++) {
		struct amd_vol *v = &super->vol[vol];
		struct mdinfo *this;
		char *ep;

		if (subarray &&
		    (strtoul(subarray, &ep, 10) != (unsigned long)vol ||
		     *ep != '\0'))
			continue;

		this = xcalloc(1, sizeof(*this));
		*tail = this;
		tail = &this->next;
		amd_fill_volume(super, vol, this);
		this->array.spare_disks = amd_spare_count(super, v);
		/*
		 * A leading '-' tells mdmon to leave the array alone, so it
		 * stays read-only: we cannot yet record its state for AMD.
		 */
		snprintf(this->text_version, sizeof(this->text_version),
			 "%c%s/%d", v->readonly ? '-' : '/',
			 st->container_devnm, vol);
		if (v->blocked)
			continue;
		amd_resync_start(super, v, this);
		if (amd_mdbm_present(super, v))
			this->consistency_policy = CONSISTENCY_POLICY_BITMAP;
		amd_volume_devs(super, v, this);
	}
	return rest;
}

/* The md bitmap of @v as this disk (super->disks) has it, if it has one. */
static void amd_print_mdbm(struct amd_super *super, const struct amd_vol *v)
{
	unsigned long long lba = amd_mdbm_lba(v), i, n, set = 0;
	struct amd_disk *d = super->disks, *disks[AMD_MAX_PD];
	struct amd_mdbm *h = amd_alloc(AMD_SECTOR);
	int k = amd_mdbm_disks(super, v, 0, disks, NULL);
	unsigned int chunk;
	__u8 *bits = NULL;
	__u32 amd;

	/* only a member in service has bits md keeps */
	while (k > 0 && disks[k - 1] != d)
		k--;
	if (!lba || !h || !k || amd_mdbm_pread(d, lba, h, AMD_SECTOR) != 0 ||
	    !amd_mdbm_valid(v, h))
		goto out;
	chunk = __le32_to_cpu(h->chunk);
	n = amd_mdbm_nbits(v, chunk);
	bits = amd_alloc(amd_mdbm_bytes(v, chunk));
	if (!bits || amd_mdbm_pread(d, lba + AMD_MDBM_HEADER, bits,
				    amd_mdbm_bytes(v, chunk)) != 0)
		goto out;
	for (i = 0; i < n; i++)
		set += (bits[i >> 3] >> (i & 7)) & 1;
	printf("           md Bitmap : %u KiB a bit, %llu of %llu set (this disk), at %llu\n",
	       chunk / 2, set, n, lba + AMD_MDBM_HEADER);
	amd = __le32_to_cpu(h->amd_bitmap);
	printf("     md Bitmap mdmon : AMD generation %llu, ",
	       (unsigned long long)__le64_to_cpu(h->generation));
	if (amd == AMD_MDBM_AMD_CLEAN)
		printf("AMD bitmap clean\n");
	else if (amd == AMD_MDBM_AMD_UNKNOWN)
		printf("AMD bitmap not mdmon's or not read\n");
	else if (amd == AMD_MDBM_UNKEPT)
		printf("md kept no bits: bits not trusted\n");
	else
		printf("AMD bitmap clean or dirty from bit %u\n", amd);
out:
	free(h);
	free(bits);
}

/* why element @i of @v is out of service, for --examine; "" if it is not */
static const char *amd_element_note(const struct amd_vol *v, int i)
{
	__u32 flags = __le32_to_cpu(v->el[i].flags);

	if (amd_slot_usable(v, i))
		return "";
	if ((flags & AMD_ELEMENT_OFFLINE) == AMD_ELEMENT_OFFLINE)
		return " (out of service: offline)";
	if (flags & AMD_ELEMENT_FAILED)
		return " (out of service: failed)";
	return " (out of service)";
}

static void amd_print_volume(struct amd_super *super, int vol)
{
	struct amd_vol *v = &super->vol[vol];
	struct amd_ld *ld = v->ld;
	const struct amd_dev_id *sp = amd_ld_spares(ld);
	char name[AMD_NAME_LEN + 1], nbuf[64];
	int i, uuid[4];

	amd_volume_uuid(super, vol, uuid);
	amd_volume_name(ld, name, sizeof(name));
	printf("\n[%s]:\n", name[0] ? name : "(no name)");
	printf("            Subarray : %d\n", vol);
	printf("           Volume ID : %016llx\n",
	       (unsigned long long)__le64_to_cpu(ld->id.id));
	printf("                UUID : %s\n", amd_uuid_text(uuid, nbuf));
	printf("                Type : %s (0x%x), %u x %u\n",
	       amd_ld_type_name(__le32_to_cpu(ld->device_type)),
	       __le32_to_cpu(ld->device_type), __le32_to_cpu(ld->first_count),
	       __le32_to_cpu(ld->second_count));
	if (v->blocked) {
		printf("          md support : none - %s\n", v->blocked);
	} else {
		/* amd_classify gives a volume it does not block a level md has */
		printf("          RAID Level : %s\n", map_num_s(pers, v->level));
		if (v->level == 5 || v->level == 10)
			printf("              Layout : %s\n",
			       v->level == 10 ? "near" : "right-asymmetric");
		printf("          md support : %s\n",
		       v->readonly ? "read-only" : "read-write");
	}
	if (v->chunk_sectors)	/* a Volume has none */
		printf("          Chunk Size : %d KiB\n", v->chunk_sectors / 2);
	printf("          Array Size : %llu sectors (%llu MiB)\n",
	       (unsigned long long)__le64_to_cpu(ld->capacity),
	       (unsigned long long)__le64_to_cpu(ld->capacity) / AMD_MIB);
	printf("               State : 0x%x%s\n", __le32_to_cpu(ld->state),
	       __le32_to_cpu(ld->state) == AMD_LD_STATE_NORMAL ? " (normal)" :
	       __le32_to_cpu(ld->state) == AMD_LD_STATE_LOCKED ?
	       " (locked: a member had an ATA password set, AMD driver 9.3.3.291)" : "");
	/* the AMD driver's own cache; md has none, Linux reads through its page cache */
	printf("    AMD driver cache : read %s, write %s\n",
	       __le32_to_cpu(ld->cache) & AMD_CACHE_READ ? "ahead" : "on request",
	       __le32_to_cpu(ld->cache) & AMD_CACHE_WRITE_BACK ? "back" : "through");
	if (ld->transform_type || ld->last_operation)
		printf("           Transform : 0x%x, last 0x%x, state 0x%x, %u%%\n",
		       __le32_to_cpu(ld->transform_type),
		       __le32_to_cpu(ld->last_operation),
		       __le32_to_cpu(ld->transform_state),
		       __le32_to_cpu(ld->transform_percent));
	/*
	 * A migration (rcadm -T, the AMD driver): the LD as it was, then the
	 * one it becomes; the progress is in the transform log of the new
	 * one's elements.
	 */
	if (v->link && __le32_to_cpu(ld->transform_type) == AMD_TRANSFORM_NORMAL) {
		unsigned long long done = amd_tlog_read(super, v, v->link,
						       AMD_TRANSFORM_NORMAL);
		unsigned long long cap = __le64_to_cpu(v->link->capacity);

		printf("           Migration : %s %u x %u, %llu MiB -> %s %u x %u, %llu MiB; %llu%% done (AMD transform log)\n",
		       amd_ld_type_name(__le32_to_cpu(ld->device_type)),
		       __le32_to_cpu(ld->first_count),
		       __le32_to_cpu(ld->second_count),
		       (unsigned long long)__le64_to_cpu(ld->capacity) / AMD_MIB,
		       amd_ld_type_name(__le32_to_cpu(v->link->device_type)),
		       __le32_to_cpu(v->link->first_count),
		       __le32_to_cpu(v->link->second_count), cap / AMD_MIB,
		       cap ? done * 100 / cap : 0);
	}
	amd_print_mdbm(super, v);
	for (i = 0; i < v->nel; i++) {
		struct amd_element *el = &v->el[i];
		__u64 id = __le64_to_cpu(el->id.id);

		printf("          Member %3d : %016llx handle %u offset %llu size %llu%s%s\n",
		       i, (unsigned long long)id, __le16_to_cpu(el->id.handle),
		       (unsigned long long)__le64_to_cpu(el->user_data.offset),
		       (unsigned long long)__le64_to_cpu(el->user_data.size),
		       amd_element_note(v, i),
		       id == super->disks->device_id ? " <- this disk" : "");
	}
	for (i = 0; i < (int)__le32_to_cpu(ld->spare_count); i++)
		printf("     Dedicated spare : %016llx handle %u%s\n",
		       (unsigned long long)__le64_to_cpu(sp[i].id),
		       __le16_to_cpu(sp[i].handle),
		       __le64_to_cpu(sp[i].id) == super->disks->device_id ?
		       " <- this disk" : "");
}

static void examine_super_amd(struct supertype *st, char *homehost)
{
	struct amd_super *super = st->sb;
	struct amd_disk *disk = super->disks;
	char nbuf[64];
	int i, uuid[4];

	amd_container_uuid(super, uuid);
	printf("          Magic : RAIDCore\n");
	printf("        Version : 0x%x\n", AMD_RC_VERSION);
	printf("      Device ID : %016llx\n",
	       (unsigned long long)disk->device_id);
	printf(" Container UUID : %s\n", amd_uuid_text(uuid, nbuf));
	if (disk->mbr == AMD_MBR_SUM)
		printf("    MBR (LBA 0) : AMD's partition, but not the checksum in the label;"
		       " mdmon updates the label\n");
	else if (disk->mbr == AMD_MBR_OTHER)
		amd_mbr_advice(disk, 1);
	if (!disk->commit_valid) {
		printf("  Configuration : none (no valid commit block)\n");
		return;
	}
	printf("     Generation : %llu\n", (unsigned long long)disk->generation);
	printf("  Packet Writes : %llu\n", (unsigned long long)disk->packet_number);
	if (disk->foreign)
		printf("    Last Online : on controller %012llx, not AMD's %012llx: the AMD BIOS and driver take this disk's configuration for a foreign one%s\n",
		       (unsigned long long)disk->last_online,
		       (unsigned long long)AMD_SERIAL,
		       super->foreign ? "" : " (the configuration here is from the disks of AMD's)");
	if (!super->packet) {
		printf("  Configuration : unreadable (checksum mismatch or malformed)\n");
		return;
	}
	printf("  Controller SN : %012llx\n", (unsigned long long)super->serial);
	printf("\n  Physical devices:\n");
	printf("     Index         Device ID  Handle  Type    State    Size (MiB)\n");
	for (i = 0; i < super->npd; i++) {
		struct amd_pd *pd = super->pd[i];

		printf("     %5d  %016llx  %6u  %-6s  0x%04x  %11llu%s%s\n", i,
		       (unsigned long long)__le64_to_cpu(pd->id.id),
		       __le16_to_cpu(pd->id.handle),
		       amd_pd_type_name(__le32_to_cpu(pd->device_type)),
		       __le32_to_cpu(pd->device_state),
		       (unsigned long long)__le64_to_cpu(pd->capacity) / AMD_MIB,
		       __le32_to_cpu(pd->spare_info) & AMD_SPARE_GLOBAL ?
		       "  global spare" : "",
		       __le64_to_cpu(pd->id.id) == disk->device_id ?
		       "  <- this disk" : "");
	}
	i = amd_repair_legacy(super, 0);
	if (i)
		printf("\n  Legacy records : %d broken by the BIOS (the disk is not bootable);"
		       " repaired with the next configuration mdmon or mdadm writes\n", i);
	for (i = 0; i < super->nvol; i++)
		amd_print_volume(super, i);
}

static void brief_examine_super_amd(struct supertype *st, int verbose)
{
	char nbuf[64];
	int uuid[4];

	amd_container_uuid(st->sb, uuid);
	printf("ARRAY metadata=amd UUID=%s\n", amd_uuid_text(uuid, nbuf));
}

static void brief_examine_subarrays_amd(struct supertype *st, int verbose)
{
	struct amd_super *super = st->sb;
	char nbuf[64], nbuf1[64], name[AMD_NAME_LEN + 1];
	int i, uuid[4];
	const char *cuuid;

	amd_container_uuid(super, uuid);
	cuuid = amd_uuid_text(uuid, nbuf);
	for (i = 0; i < super->nvol; i++) {
		amd_volume_uuid(super, i, uuid);
		amd_volume_name(super->vol[i].ld, name, sizeof(name));
		printf("ARRAY%s%s container=%s member=%d UUID=%s\n",
		       name[0] ? " " DEV_MD_DIR : "", name, cuuid, i,
		       amd_uuid_text(uuid, nbuf1));
	}
}

static void export_examine_super_amd(struct supertype *st)
{
	char nbuf[64];
	int uuid[4];

	amd_container_uuid(st->sb, uuid);
	printf("MD_METADATA=amd\n");
	printf("MD_LEVEL=container\n");
	printf("MD_UUID=%s\n", amd_uuid_text(uuid, nbuf));
	/* the disks of its packet, as IMSM gives its num_disks */
	printf("MD_DEVICES=%u\n", amd_container_disks(st->sb));
}

/* the UUID of @subarray, or of what @st holds if it is NULL */
static void amd_subarray_uuid(struct supertype *st, char *subarray,
			      int uuid[4])
{
	struct amd_super *super = st->sb;
	int temp_vol = super->current_vol;

	if (subarray)
		super->current_vol = strtoul(subarray, NULL, 10);
	uuid_from_super_amd(st, uuid);
	super->current_vol = temp_vol;
}

static void detail_super_amd(struct supertype *st, char *homehost,
			     char *subarray)
{
	struct amd_super *super = st->sb;
	char nbuf[64];
	int uuid[4];

	amd_subarray_uuid(st, subarray, uuid);
	printf("\n              UUID : %s\n", amd_uuid_text(uuid, nbuf));
	if (!subarray && super->current_vol < 0) {
		printf("     Controller SN : %012llx\n",
		       (unsigned long long)super->serial);
		printf("        Generation : %llu\n",
		       (unsigned long long)super->generation);
		printf("           Volumes : %d\n", super->nvol);
	}
}

static void brief_detail_super_amd(struct supertype *st, char *subarray)
{
	char nbuf[64];
	int uuid[4];

	amd_subarray_uuid(st, subarray, uuid);
	printf(" UUID=%s", amd_uuid_text(uuid, nbuf));
}

static int match_home_amd(struct supertype *st, char *homehost)
{
	/* the controller serial number is the same on every AMD system */
	return -1;
}

static int update_super_amd(struct supertype *st, struct mdinfo *info,
			    enum update_opt update, char *devname, int verbose,
			    int uuid_set, char *homehost)
{
	/*
	 * No --update applies to an AMD disk; volumes take --update-subarray.
	 * As IMSM: -1 for what it does not know, and Assemble refuses the
	 * option instead of trying to store each disk; 0 for Assemble's own
	 * per-device check, which with --force would store the disk too.
	 */
	return update == UOPT_SPEC_ASSEMBLE ? 0 : -1;
}

/*
 * Creation, the way the RAIDXpert2 menu does it (RAIDCoreDxe 9.3.3):
 *  - a container is a set of disks "initialized" (FUN_00016e28): the first
 *    and last 0xA000 sectors zeroed, an MBR with one partition of type 0x82
 *    from sector 0x3F over the capacity (its low 32 bits), the RAIDCore
 *    label with a random 48-bit DeviceID and Features 0x1C, 0x7E sectors of
 *    0xAF at 0x4F80 (written by the menu, FUN_0001d0e4), and a config packet
 *    listing the controller and the disks, handles 1..n;
 *  - a volume is an LD record and its second copy (TransformLink) in the
 *    next packet: State 0, CREATE_REDUNDANCY not started, TransformFlags
 *    0x211, Cache 0xC0000000, Attribute 1 (bitmap), TaskPriority 0x14, one
 *    parent reference to the controller, its own handle (1, 2, ...) and a
 *    random 48-bit ID.  Each member gets the first free extent from
 *    0x100000: the size asked for in whole MiB plus 0x5000 sectors of
 *    service area in front.  mdmon then initializes it (md resync).
 * Levels: Volume (linear), RAID0, RAID1 (2 disks), RAID10 (2 x n) and
 * RAID5 (3 to 8 disks), as amd_level_ok() checks.
 */
#define AMD_INIT_ZERO		0xa000	/* zeroed at each end by Initialize */
#define AMD_FILL_LBA		0x4f80
#define AMD_FILL_SECTORS	0x7e
#define AMD_FILL_BYTE		0xaf
#define AMD_FEATURES		0x1c
#define AMD_CREATE_CONTAINER	1

static int amd_insert_ld(struct amd_super *super, unsigned int at,
			 const void *rec, unsigned int size);
static int amd_packet_reserve(struct amd_super *super, unsigned int size);
static int amd_add_new(struct supertype *st, int fd, char *devname);
static int amd_erase(int fd);
static int amd_in_volume(const struct amd_vol *v, __u64 id);
static int amd_vol_has_disk(const struct amd_vol *v, __u64 id);
static struct amd_ld *amd_ld_by_id(struct amd_super *super, __u64 id);
static int amd_rebuilt_into(struct amd_super *super, const struct amd_disk *d);
static int amd_extent_overlap(struct amd_super *super, __u64 id,
			      unsigned long long start, unsigned long long len,
			      unsigned long long *end);

static int amd_id_used(struct amd_super *super, __u64 id)
{
	int i;

	for (i = 0; i < super->npd; i++)
		if (__le64_to_cpu(super->pd[i]->id.id) == id)
			return 1;
	for (i = 0; i < super->nvol; i++)
		if (__le64_to_cpu(super->vol[i].ld->id.id) == id)
			return 1;
	return amd_find_disk(super, id) != NULL;
}

/* a random 48-bit ID (as RAIDCoreDxe FUN_00019aa4 makes), not 0, not in use */
static __u64 amd_random_id(struct amd_super *super)
{
	for (;;) {
		__u64 id = (((__u64)random32() << 16) ^ random32()) &
			   0xffffffffffffULL;

		if (id && !amd_id_used(super, id))
			return id;
	}
}

/*
 * ATA IDENTIFY DEVICE through SG_IO (ATA PASS-THROUGH(16)); 0 on success.
 * Not drive_encryption.c's ata_pass_through12_ioctl(): it sets CK_COND and
 * takes the answer only with "ATA pass through information available" in
 * the sense data, which Linux 6.12 with QEMU AHCI does not give for a good
 * IDENTIFY - the disk would get a random DeviceID, not the one the BIOS
 * knows it by (amd_serial_hash).
 */
static int amd_ata_identify(int fd, __u16 *id)
{
	/* ATA PASS-THROUGH(16): PIO data-in; T_DIR, BYT_BLOK, length in the count */
	unsigned char cdb[16] = { 0x85, 4 << 1, 0x0e };
	unsigned char sense[32];
	struct sg_io_hdr sg;

	cdb[6] = 1;		/* one sector */
	cdb[14] = 0xec;		/* IDENTIFY DEVICE */
	memset(&sg, 0, sizeof(sg));
	sg.interface_id = 'S';
	sg.cmd_len = sizeof(cdb);
	sg.cmdp = cdb;
	sg.dxfer_direction = SG_DXFER_FROM_DEV;
	sg.dxferp = id;
	sg.dxfer_len = 512;
	sg.sbp = sense;
	sg.mx_sb_len = sizeof(sense);
	sg.timeout = 5000;
	if (ioctl(fd, SG_IO, &sg) != 0 || sg.status || sg.host_status ||
	    (sg.driver_status & ~0x08))		/* DRIVER_SENSE: ATA return */
		return -1;
	return 0;
}

/*
 * The DeviceID RAIDCoreDxe gives a disk (FUN_00019904 with FUN_00006ae0;
 * the menu's Initialize writes it): two 31-bit shift-register signatures,
 * low and high half, of the 20-byte serial number field as the disk reports
 * it (padding kept) followed by 12 't's.  The menu finds a member's disk by
 * it alone (FUN_00019b58, FUN_00021bb0): with another ID the disk shows
 * "New" and its volume no capacity.  Checked on 11 disks of the dumps.
 */
static __u64 amd_serial_hash(const unsigned char *sn)
{
	__u32 a = 0x7fffffff, b = 0x7fffffff;
	int i, k;

	for (i = 0; i < 32; i++) {
		unsigned int c = i < 20 ? sn[i] : 't';

		for (k = 0; k < 8; k++) {
			unsigned int bit = c >> k & 1;

			if (bit != ((a >> 28 ^ a) >> 2 & 1))
				a |= 0x80000000;
			a >>= 1;
			if (bit != ((b >> 26 ^ b) >> 3 & 1))
				b |= 0x80000000;
			b >>= 1;
		}
	}
	return a + ((__u64)b << 32);
}

/* the serial number field of the disk: NVMe Identify Controller, ATA IDENTIFY */
static int amd_disk_serial(int fd, unsigned char *sn)
{
	unsigned char ctrl[4096];
	__u16 id[256];
	int i;

	if (ioctl(fd, NVME_IOCTL_ID) > 0) {
		if (nvme_identify_ioctl(fd, 0, NVME_IDENTIFY_CONTROLLER_DATA,
					ctrl, sizeof(ctrl), 0) !=
		    MDADM_STATUS_SUCCESS)
			return -1;
		memcpy(sn, ctrl + 4, 20);
		return 0;
	}
	if (amd_ata_identify(fd, id) != 0)
		return -1;
	for (i = 0; i < 10; i++) {		/* words 10-19, high byte first */
		sn[2 * i] = __le16_to_cpu(id[10 + i]) >> 8;
		sn[2 * i + 1] = __le16_to_cpu(id[10 + i]) & 0xff;
	}
	return 0;
}

/*
 * A new disk's DeviceID: the firmware's, from its serial number; if the
 * disk does not tell (a loop device) or that ID is taken, a random one, as
 * RAIDCoreDxe also falls back to (FUN_000199cc).
 */
static __u64 amd_disk_id(struct amd_super *super, int fd)
{
	unsigned char sn[20];
	__u64 id;

	if (amd_disk_serial(fd, sn) == 0) {
		id = amd_serial_hash(sn);
		if (id && !amd_id_used(super, id))
			return id;
	}
	return amd_random_id(super);
}

/*
 * The PCI function (DDDD:BB:DD.F) a sysfs device path ends up at: the last
 * one on it, the one the device is attached to.  1 if found, 0 if none.
 */
static int amd_pci_in_path(const char *path, char *pci, size_t len)
{
	const char *c;
	int found = 0;

	for (c = strchr(path, '/'); c; c = strchr(c + 1, '/')) {
		unsigned int d, b, s, f;
		int n = 0;

		if (sscanf(c, "/%4x:%2x:%2x.%1x%n", &d, &b, &s, &f, &n) == 4 &&
		    n == 13 && (c[n] == '/' || c[n] == 0)) {
			snprintf(pci, len, "%.12s", c + 1);
			found = 1;
		}
	}
	return found;
}

/*
 * The PCI function a disk is attached to (into @pci, 16 bytes); a multipath
 * NVMe namespace through its first controller (devt_to_devpath() level 1).
 * 1 if found, 0 if the disk is behind none (a loop device), -1 if unknown.
 */
static int amd_pci_of(int major, int minor, char *pci)
{
	dev_t dev = makedev(major, minor);
	char path[PATH_MAX];

	if (!devt_to_devpath(dev, 0, path))
		return -1;
	if (strstr(path, "/nvme-subsystem/") &&
	    (!devt_to_devpath(dev, 1, path) ||
	     strstr(path, "/nvme-subsystem/")))
		return -1;		/* no controller (path) now */
	return amd_pci_in_path(path, pci, 16);
}

static unsigned int amd_pci_attr(const char *pci, const char *attr)
{
	char path[64], buf[32];

	snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/%s", pci, attr);
	if (load_sys(path, buf, sizeof(buf)) != 0)
		return 0;
	return strtoul(buf, NULL, 16);
}

/*
 * The EFI variable AMD_RAID (u64) the platform sets for the AMD firmware
 * (MSI X870E in RAID mode: 0x0d), 0 if it is not there (*present 0 then).
 */
#define AMD_RAID_GUID EFI_GUID(0xfe26a894, 0xd199, 0x47d4, 0x8a, 0xfa, \
			       0x07, 0x0e, 0x3d, 0x54, 0xba, 0x86)
static unsigned int amd_raid_var(int *present)
{
	__u64 var;

	*present = read_efi_variable(&var, sizeof(var), "AMD_RAID",
				     AMD_RAID_GUID) == 0;
	return *present ? (unsigned int)__le64_to_cpu(var) : 0;
}

/*
 * Does the AMD firmware (AMD_RAID @raid) take the disks behind PCI function
 * @pci?  RAIDCoreDxe's Supported (D:0xd00) takes AHCI 1022:43bd if
 * AMD_RAID & 1, 1022:7905/7916/7917 if AMD_RAID & 2, and NVMe if
 * AMD_RAID & 4 - only 1022:b000 if AMD_RAID & 8, any otherwise.
 */
static int amd_raid_takes(const char *pci, unsigned int raid,
			  unsigned int *vendor, unsigned int *device)
{
	unsigned int class = amd_pci_attr(pci, "class") >> 8;

	*vendor = amd_pci_attr(pci, "vendor");
	*device = amd_pci_attr(pci, "device");
	if (*vendor == 0x1022 && *device == 0x43bd)
		return (raid & 1) != 0;
	if (*vendor == 0x1022 &&
	    (*device == 0x7905 || *device == 0x7916 || *device == 0x7917))
		return (raid & 2) != 0;
	if (class == 0x0108)
		return (raid & 4) && (!(raid & 8) ||
				      (*vendor == 0x1022 && *device == 0xb000));
	return 0;
}

/*
 * Will RAIDCoreDxe see disk @subdev?  A disk the firmware does not see is
 * missing from the volume there and in Windows, and RAIDCoreDxe writes
 * that into the configuration.  Not behind a controller (a loop device: an
 * image) - fine.  --force: taken anyway (another machine, the disks on
 * another controller to get at the data).
 */
static int amd_controller_ok(struct supertype *st, const char *subdev,
			     int verbose)
{
	unsigned int vendor = 0, device = 0, raid;
	char pci[16] = "?";
	struct stat stb;
	int present, r;

	if (stat(subdev, &stb) != 0 || !S_ISBLK(stb.st_mode))
		return 1;		/* validate_geometry says what it is */
	r = amd_pci_of(major(stb.st_rdev), minor(stb.st_rdev), pci);
	if (r == 0)
		return 1;
	raid = amd_raid_var(&present);
	if (r > 0 && amd_raid_takes(pci, raid, &vendor, &device))
		return 1;
	if (verbose || !st->force) {
		if (!raid)
			pr_err("%s: AMD RAID is off in the firmware (EFI variable AMD_RAID %s)\n",
			       subdev, present ? "0" : "absent");
		else if (r < 0)
			pr_err("%s: cannot tell which controller it is on (no path to it in sysfs)\n",
			       subdev);
		else
			pr_err("%s: its controller %s (%04x:%04x) is not one AMD RAID takes (AMD_RAID 0x%x)\n",
			       subdev, pci, vendor, device, raid);
		pr_err("the firmware and Windows would not see %s in the volume%s\n",
		       subdev, st->force ? ": taken anyway (--force)" :
		       "; --force takes it anyway");
	}
	return st->force;
}

static int amd_is_nvme(int major, int minor)
{
	char real[PATH_MAX];

	return devt_to_devpath(makedev(major, minor), 0, real) &&
	       strstr(real, "/nvme/") != NULL;
}

/*
 * PD Features as RAIDCoreDxe sets them for a disk (FUN_0001bbf4 for SATA:
 * IDENTIFY and the AHCI port; FUN_0000c950 for NVMe: 0x2100): 0x100 SMART
 * supported (word 82 bit 0), 0x2000 SMART enabled (word 85 bit 0), the
 * link speed 0x200 / 0x400 / 0x800 (PxSSTS.SPD: 1.5 / 3 / 6 Gb/s).  A
 * SATA HDD at 6 Gb/s: 0x2900; QEMU AHCI (1.5 Gb/s): 0x2300 - also what a
 * disk we cannot ask (a loop device) gets.
 */
static __u32 amd_pd_features(int fd, int major, int minor)
{
	char path[64], real[PATH_MAX], *p;
	__u32 f = 0, speed = 0x200;
	__u16 id[256];
	unsigned int ata;

	if ((fd >= 0 && ioctl(fd, NVME_IOCTL_ID) > 0) || amd_is_nvme(major, minor))
		return 0x2100;
	if (fd < 0 || amd_ata_identify(fd, id) != 0)
		return 0x2300;
	if (__le16_to_cpu(id[82]) & 1) {
		f |= 0x100;
		if (__le16_to_cpu(id[85]) & 1)
			f |= 0x2000;
	}
	p = devt_to_devpath(makedev(major, minor), 0, real) ?
	    strstr(real, "/ata") : NULL;
	if (p && sscanf(p, "/ata%u/", &ata) == 1) {
		char buf[32];

		snprintf(path, sizeof(path), "/sys/class/ata_link/link%u/sata_spd", ata);
		if (load_sys(path, buf, sizeof(buf)) == 0) {
			if (strncmp(buf, "6.0", 3) == 0)
				speed = 0x800;
			else if (strncmp(buf, "3.0", 3) == 0)
				speed = 0x400;
		}
	}
	return f | speed;
}

/*
 * The PD record of an ONLINE RAIDCore disk, as RAIDCoreDxe writes one: its
 * Handle, RoutingPath 1, BusType 0x2000, the capacity AMD gives the disk.
 */
static void amd_fill_pd(struct amd_pd *pd, __u64 id, int handle,
			unsigned long long sectors, __u32 features, __u32 spare)
{
	pd->type = __cpu_to_le32(AMD_DST_PD);
	pd->id.id = __cpu_to_le64(id);
	pd->id.handle = __cpu_to_le16(handle);
	pd->id.routing = __cpu_to_le16(1);
	pd->capacity = __cpu_to_le64(amd_align_capacity(sectors));
	pd->device_type = __cpu_to_le32(AMD_DEV_RAIDCORE_DISK);
	pd->bus_type = __cpu_to_le32(0x2000);
	pd->device_state = __cpu_to_le32(AMD_DEV_STATE_ONLINE);
	pd->spare_info = __cpu_to_le32(spare);
	pd->features = __cpu_to_le32(features);
}

/*
 * The packet of a container being created: the controller and the disks
 * added so far, in that order (Handles 1, 2, ...), no LDs.  The container
 * UUID follows the lowest DeviceID among them (amd_parse_packet), so it
 * may change as disks come: amd_create_map puts the last one in the map.
 */
static int amd_build_packet(struct amd_super *super)
{
	unsigned int n = 1, len, i;
	struct amd_packet_header *h;
	struct amd_disk *d;
	struct amd_pd *pd;

	for (d = super->disks; d; d = d->next)
		n++;
	len = ROUND_UP(sizeof(*h) + n * sizeof(*pd), AMD_SECTOR);
	h = amd_alloc(len);
	if (!h)
		return -1;
	h->header_key = __cpu_to_le64(AMD_HEADER_KEY);
	h->version = __cpu_to_le32(1);
	h->packet_size = __cpu_to_le32(len);
	h->modifier_sn = __cpu_to_le64(super->serial);
	h->pd_offset = __cpu_to_le32(sizeof(*h));
	h->pd_size = __cpu_to_le32(n * sizeof(*pd));
	h->ld_offset = __cpu_to_le32(sizeof(*h) + n * sizeof(*pd));
	pd = (struct amd_pd *)(h + 1);
	pd[0].type = __cpu_to_le32(AMD_DST_PD);
	pd[0].id.id = __cpu_to_le64(super->serial);
	pd[0].id.handle = __cpu_to_le16(0xffff);
	pd[0].device_type = __cpu_to_le32(AMD_DEV_RAIDCORE_CORE);
	pd[0].device_state = __cpu_to_le32(AMD_DEV_STATE_ONLINE);
	for (i = 1, d = super->disks; d; d = d->next, i++)
		amd_fill_pd(&pd[i], d->device_id, i, d->sectors,
			    amd_pd_features(d->fd, d->major, d->minor), 0);
	h->checksum = __cpu_to_le64(amd_checksum((char *)h + 0x0c, len - 0x0c));
	amd_take_packet(super, h, len, 0);
	for (d = super->disks; d; d = d->next) {
		/* a packet these disks have "seen": amd_write_config writes them */
		d->commit_valid = 1;
		d->last_online = super->serial;
		d->generation = 0;
		d->committed_checksum = __le64_to_cpu(h->checksum);
		d->packet_lba = 0;
		d->packet_size = 0;
		d->packet_number = 0;
	}
	return 0;
}

/*
 * Initialize one disk: zeroed ends, MBR, the 0xAF area, the label.  @spare is
 * the label's SpareInfo (AMD_SPARE_GLOBAL for a global hot spare).  @keep_tail:
 * a former member - an extent of another volume may reach the end.
 */
static int amd_init_disk(struct amd_disk *d, __u32 spare, int keep_tail)
{
	size_t zlen = AMD_INIT_ZERO * AMD_SECTOR;
	char *buf = amd_alloc(zlen);
	struct MBR *pt = (struct MBR *)buf;
	struct amd_metadata *md;
	__u32 sig;
	__u64 mbr_sum;
	int rv = 1;

	if (!buf || d->sectors < 2 * AMD_INIT_ZERO + AMD_DEFAULT_ALLOC_LBA)
		goto out;
	if (pwrite(d->fd, buf, zlen, 0) != (ssize_t)zlen ||
	    (!keep_tail &&
	     pwrite(d->fd, buf, zlen,
		    (off_t)(d->sectors - AMD_INIT_ZERO) * AMD_SECTOR) != (ssize_t)zlen))
		goto out;

	/* MBR, with a random disk signature */
	pt->parts[0].part_type = AMD_MBR_TYPE;
	pt->parts[0].first_sect_lba = __cpu_to_le32(AMD_MBR_START);
	pt->parts[0].blocks_num = __cpu_to_le32((__u32)d->sectors);
	sig = __cpu_to_le32(random32());
	memcpy(pt->pad + 0x1b8, &sig, sizeof(sig));
	pt->magic = MBR_SIGNATURE_MAGIC;
	mbr_sum = amd_checksum(buf, AMD_SECTOR);
	if (pwrite(d->fd, buf, AMD_SECTOR, 0) != AMD_SECTOR)
		goto out;

	memset(buf, AMD_FILL_BYTE, AMD_FILL_SECTORS * AMD_SECTOR);
	if (pwrite(d->fd, buf, AMD_FILL_SECTORS * AMD_SECTOR,
		   (off_t)AMD_FILL_LBA * AMD_SECTOR) !=
	    AMD_FILL_SECTORS * AMD_SECTOR)
		goto out;

	memset(buf, 0, AMD_SECTOR);
	md = (struct amd_metadata *)buf;
	md->ident = __cpu_to_le64(AMD_RC_IDENT);
	md->device_id = __cpu_to_le64(d->device_id);
	md->commit_offset = __cpu_to_le64(AMD_COMMIT_LBA);
	md->ring_offset = __cpu_to_le64(AMD_RING_LBA);
	md->ring_size = __cpu_to_le32(AMD_RING_END - AMD_RING_LBA);
	md->version = __cpu_to_le32(AMD_RC_VERSION);
	md->features = __cpu_to_le32(AMD_FEATURES);
	md->spare_info = __cpu_to_le32(spare);
	md->mbr_checksum = __cpu_to_le64(mbr_sum);
	md->checksum = __cpu_to_le64(amd_sector_sum(md));
	if (pwrite(d->fd, buf, AMD_SECTOR, (off_t)AMD_METADATA_LBA * AMD_SECTOR) !=
	    AMD_SECTOR || fsync(d->fd) != 0)
		goto out;
	d->features = AMD_FEATURES;
	rv = 0;
out:
	free(buf);
	return rv;
}

/* the new volume's members: free extent of @size sectors on each disk */
static unsigned long long amd_free_extent(struct amd_super *super,
					  struct amd_disk *d,
					  unsigned long long size)
{
	unsigned long long start = AMD_DEFAULT_ALLOC_LBA, end;
	int i = amd_pd_index(super, d->device_id);
	unsigned long long cap = amd_pd_capacity(i >= 0 ? super->pd[i] : NULL,
						 d->sectors);

	while (amd_extent_overlap(super, d->device_id, start, size, &end))
		start = end;
	/* an element recorded past the disk may end near 2^64: no wrap */
	return start <= cap && size <= cap - start ? start : 0;
}

/* largest extent (sectors) free on @d */
static unsigned long long amd_max_extent(struct amd_super *super,
					 struct amd_disk *d)
{
	unsigned long long lo = 0, hi = d->sectors;

	/* first fit is monotone in the size asked for: bisect, in MiB */
	while (hi - lo > AMD_MIB) {
		unsigned long long mid = (lo + hi) / 2 / AMD_MIB * AMD_MIB;

		if (mid <= lo)
			break;
		if (amd_free_extent(super, d, mid))
			lo = mid;
		else
			hi = mid;
	}
	return lo;
}

/*
 * -l1 -n1 (mdadm.c asks --force for one disk): a RAIDABLE, "RAID aware
 * single disk for future redundancy" - md raid1 of one member, as it is
 * assembled (amd_classify_level), and grown into a RAID1 with --grow -n2.
 */
static int amd_is_raidable(int level, int raiddisks)
{
	return level == 1 && raiddisks == 1;
}

static int amd_level_ok(int level, int raiddisks, int verbose)
{
	if (level == LEVEL_LINEAR && raiddisks >= 1)
		return 1;	/* Volume (the menu: 1 to 8 disks) */
	if (level == 0 && raiddisks >= 2)
		return 1;
	if (level == 1 && raiddisks == 2)
		return 1;
	if (amd_is_raidable(level, raiddisks))
		return 1;
	if (level == 10 && raiddisks >= 4 && raiddisks % 2 == 0)
		return 1;
	if (level == 5 && raiddisks >= 3 && raiddisks <= 8)
		return 1;	/* rcadm: "three to eight disks" */
	if (verbose)
		pr_err("AMD RAID volumes can be created as RAID0 (2 or more disks), RAID1 (2 disks), RAID10 (2 x n disks), RAID5 (3 to 8 disks), linear (Volume, 1 or more disks) or RAIDABLE (RAID1 of 1 disk: -l1 -n1 --force)\n");
	return 0;
}

/*
 * Room for a new member on the disk of this PD: user data sectors in whole
 * MiB of its largest free extent, after the service area.  0 if the disk
 * cannot take one: missing, stale, failed, a dedicated spare (its volume's),
 * being rebuilt onto, or full.  A global spare can, as IMSM builds new
 * volumes of the spares of its container: --add makes every new disk one
 * (amd_add_new), and it is no spare once a member (amd_take_spares).
 * A RAIDABLE (super->whole) takes a disk no volume has an element on, and
 * all of it, up to the end of the disk (amd_pd_capacity): the BIOS menu
 * offers it only "Ready" disks (RAIDCoreDxe FUN_0000ed9c) and lays it out
 * so (dumps/2026-11-06-qemu-spares-raidable, snapshot 04; MSI X870E 1 TB,
 * dumps/2026-11-07-raidable-done).
 */
static unsigned long long amd_disk_room(struct amd_super *super,
					struct amd_pd *pd, struct amd_disk **dp)
{
	struct amd_disk *d;
	unsigned long long m;

	if (__le32_to_cpu(pd->device_type) != AMD_DEV_RAIDCORE_DISK ||
	    amd_dedicated_owner(super, __le64_to_cpu(pd->id.id)) >= 0)
		return 0;
	d = amd_member_disk(super, __le64_to_cpu(pd->id.id));
	if (!d || amd_disk_failed(super, d->device_id) ||
	    amd_rebuilt_into(super, d) >= 0)
		return 0;
	if (super->whole) {
		if (amd_disk_in_volumes(super, d->device_id))
			return 0;
		m = amd_pd_capacity(pd, d->sectors);
		m = m > AMD_DEFAULT_ALLOC_LBA ? m - AMD_DEFAULT_ALLOC_LBA : 0;
	} else {
		m = amd_max_extent(super, d);
	}
	if (m < AMD_SERVICE + AMD_MIB)
		return 0;
	*dp = d;
	return (m - AMD_SERVICE) / AMD_MIB * AMD_MIB;
}

/* Why amd_disk_room() gave 0 for the disk of @pd, for messages. */
static const char *amd_no_room(struct amd_super *super, struct amd_pd *pd)
{
	static char why[96];
	__u64 id = __le64_to_cpu(pd->id.id);
	struct amd_disk *d = amd_member_disk(super, id);
	int vol;

	if (__le32_to_cpu(pd->device_type) == AMD_DEV_LEGACY)
		return "a Legacy disk";
	if (__le32_to_cpu(pd->device_type) != AMD_DEV_RAIDCORE_DISK)
		return "not a RAID disk";
	vol = amd_dedicated_owner(super, id);
	if (vol >= 0) {
		snprintf(why, sizeof(why),
			 "a dedicated spare of subarray-%d (mdadm <that volume> --remove unassigns it)",
			 vol);
		return why;
	}
	if (!d)
		return "missing or stale";
	if (amd_disk_failed(super, id))
		return "failed";
	vol = amd_rebuilt_into(super, d);
	if (vol >= 0) {
		snprintf(why, sizeof(why), "md is rebuilding subarray-%d onto it",
			 vol);
		return why;
	}
	if (super->whole && amd_disk_in_volumes(super, id))
		return "a RAIDABLE volume takes a whole disk, and a volume is on this one";
	return "no free space left";
}

static char *amd_disk_name(struct amd_disk *d)
{
	char *n = d->devname;

	if (!n && (d->major || d->minor))
		n = map_dev(d->major, d->minor, 0);
	return n ? n : "?";
}

/*
 * amd_autolayout() found no disks for the new volume: say how much room
 * the container has, disk by disk.  @size: per member, sectors, or 0.
 */
static void amd_explain_room(struct amd_super *super, int raiddisks,
			     unsigned long long size)
{
	unsigned long long room[AMD_MAX_PD];
	int i, j, n = 0;

	for (i = 0; i < super->npd; i++) {
		struct amd_disk *d = NULL;
		unsigned long long m = amd_disk_room(super, super->pd[i], &d);

		if (!m)
			continue;
		for (j = n++; j > 0 && room[j - 1] < m; j--)
			room[j] = room[j - 1];
		room[j] = m;
	}
	if (n < raiddisks)
		pr_err("%d disk%s of the container can take a member, %d needed:\n",
		       n, n == 1 ? "" : "s", raiddisks);
	else
		pr_err("%llu MiB per member asked for, but no %d disks of the container have more than %llu MiB free each:\n",
		       (size + AMD_MIB - 1) / AMD_MIB, raiddisks,
		       room[raiddisks - 1] / AMD_MIB);
	for (i = 0; i < super->npd; i++) {
		struct amd_pd *pd = super->pd[i];
		struct amd_disk *d = NULL;
		unsigned long long m = amd_disk_room(super, pd, &d);
		struct amd_disk *md = amd_member_disk(super,
						      __le64_to_cpu(pd->id.id));

		if (__le32_to_cpu(pd->device_type) == AMD_DEV_RAIDCORE_CORE)
			continue;	/* the controller */
		if (m)
			cont_err("handle %u, %s: %llu MiB free\n",
				 __le16_to_cpu(pd->id.handle), amd_disk_name(d),
				 m / AMD_MIB);
		else
			cont_err("handle %u, %s: %s\n", __le16_to_cpu(pd->id.handle),
				 md ? amd_disk_name(md) : "-",
				 amd_no_room(super, pd));
	}
}

/*
 * The disks of the new volume, by slot, in super->layout: the ones given
 * on the command line (amd_pick_disk), else the first disks in PD order
 * with room for @size - global spares only after the others, as a disk
 * kept for rebuilds is the last one to go.  *freesize: the room they all
 * have.
 */
static int amd_autolayout(struct amd_super *super, int raiddisks,
			  unsigned long long size, unsigned long long *freesize)
{
	unsigned long long common = ~0ULL;
	int i, n = 0, spares;

	if (super->npick) {
		if (super->npick != raiddisks)
			return 0;
		for (i = 0; i < raiddisks; i++) {
			struct amd_disk *d = NULL;
			int p = amd_pd_index(super, super->layout[i]->device_id);
			unsigned long long m = p < 0 ? 0 :
				amd_disk_room(super, super->pd[p], &d);

			if (m == 0 || (size && m < size))
				return 0;
			if (m < common)
				common = m;
		}
		n = raiddisks;
	}
	for (spares = 0; spares < 2 && n < raiddisks; spares++)
		for (i = 0; i < super->npd && n < raiddisks; i++) {
			struct amd_pd *pd = super->pd[i];
			int global = (__le32_to_cpu(pd->spare_info) &
				      AMD_SPARE_GLOBAL) != 0;
			struct amd_disk *d = NULL;
			unsigned long long m;

			if (global != spares)
				continue;
			m = amd_disk_room(super, pd, &d);
			if (m == 0 || (size && m < size))
				continue;
			super->layout[n++] = d;
			if (m < common)
				common = m;
		}
	if (n < raiddisks)
		return 0;
	if (freesize)
		*freesize = common;
	return 1;
}

/*
 * The size of the new volume, as validate_geometry is first asked with
 * the container loaded: @size per member (sectors), 0 when no -z was given
 * (or -z max); @whole: it is a RAIDABLE.  A RAIDABLE takes no size: the
 * BIOS menu greys Array Size out for it and gives it the whole disk
 * (dumps/2026-11-06-qemu-spares-raidable, snapshot 04).
 */
static int amd_new_size(struct amd_super *super, int whole,
			unsigned long long size, int verbose)
{
	if (whole && size) {
		if (verbose)
			pr_err("an AMD RAIDABLE volume takes its whole disk: give no --size\n");
		return 0;
	}
	super->fill = size == 0;
	super->whole = whole;
	return 1;
}

/*
 * mdadm -C <name> -e amd -l<level> -n<n> <disk>...: the disks must be in
 * the assembled AMD container; the first one loads it.  Each is checked
 * and becomes the next slot of the new volume (RAID10: slots 0,1 are the
 * first mirror pair, 2,3 the second).  @size: per member (sectors) or 0.
 * @whole: the volume is a RAIDABLE.  *freesize: its room.
 */
static int amd_pick_disk(struct supertype *st, char *subdev, int whole,
			 unsigned long long size,
			 unsigned long long *freesize, int verbose)
{
	struct amd_super *super = st->sb;
	struct amd_metadata *md;
	struct amd_disk *d = NULL;
	unsigned long long room;
	int fd, cfd, p, i;
	__u64 id = 0;

	fd = open(subdev, O_RDONLY);
	if (!is_fd_valid(fd)) {
		if (verbose)
			pr_err("cannot open %s\n", subdev);
		return 0;
	}
	md = amd_alloc(AMD_SECTOR);
	if (md && amd_read(fd, AMD_METADATA_LBA, md, AMD_SECTOR) == 0 &&
	    __le64_to_cpu(md->ident) == AMD_RC_IDENT)
		id = __le64_to_cpu(md->device_id);
	free(md);
	if (!super) {
		cfd = open_container(fd);
		if (!is_fd_valid(cfd) ||
		    load_container_amd(st, cfd, NULL) != 0) {
			if (verbose)
				pr_err("%s is not in an assembled AMD RAID container: mdadm -A /dev/md/<name> <its disks> first\n",
				       subdev);
			close_fd(&cfd);
			close(fd);
			return 0;
		}
		close(cfd);
		super = st->sb;
	}
	close(fd);
	p = id ? amd_pd_index(super, id) : -1;
	if (p < 0) {
		if (verbose)
			pr_err("%s is not a disk of this AMD RAID container\n",
			       subdev);
		return 0;
	}
	for (i = 0; i < super->npick; i++)
		if (super->layout[i]->device_id == id) {
			if (verbose)
				pr_err("%s is given twice\n", subdev);
			return 0;
		}
	if (super->npick >= AMD_MAX_PD)
		return 0;
	if (super->npick == 0 && !amd_new_size(super, whole, size, verbose))
		return 0;
	room = amd_disk_room(super, super->pd[p], &d);
	if (room == 0) {
		if (verbose)
			pr_err("%s cannot take a member: %s\n", subdev,
			       amd_no_room(super, super->pd[p]));
		return 0;
	}
	if (size && room < size) {
		if (verbose)
			pr_err("%s has %llu MiB free for a member, %llu MiB asked\n",
			       subdev, room / AMD_MIB,
			       (size + AMD_MIB - 1) / AMD_MIB);
		return 0;
	}
	super->layout[super->npick++] = d;
	if (freesize)
		*freesize = room;
	return 1;
}

/*
 * A partition table on @fd (read into @buf, a sector) other than the MBR
 * AMD writes - one 0x82 partition, the first, from 0x3F - or a GPT: a
 * Legacy disk has no RAIDCore label, its partitions tell it.  -1 if LBA 0
 * cannot be read.
 */
static int amd_foreign_table(int fd, void *buf)
{
	const struct MBR *pt = buf;
	int k, table = 0, amd = 0;

	if (amd_read(fd, 0, buf, AMD_SECTOR) != 0)
		return -1;
	if (pt->magic == MBR_SIGNATURE_MAGIC)
		for (k = 0; k < MBR_PARTITIONS; k++) {
			const struct MBR_part_record *pe = &pt->parts[k];

			if (pe->part_type == 0)
				continue;
			table = 1;
			/* any partition after the first makes it another table */
			amd = k == 0 && pe->part_type == AMD_MBR_TYPE &&
			      __le32_to_cpu(pe->first_sect_lba) == AMD_MBR_START;
		}
	if (!table && amd_read(fd, 1, buf, AMD_SECTOR) == 0 &&
	    ((struct GPT *)buf)->magic == GPT_SIGNATURE_MAGIC)
		table = 1;
	return table && !amd;
}

/*
 * mdadm --add of a disk that is not of this configuration: Initialize zeroes
 * its first and last 20 MiB.  What mdadm can tell holds data is refused
 * unless --force, as Create asks before it goes on: a file system it knows
 * on the whole disk (check_ext2, check_reiser - they say what they found),
 * or a member of a volume of another AMD RAID configuration.  A volume of
 * @super is no reason: its member comes back (the AMD driver dropped the PD
 * of a disk it ran without).
 */
static int amd_add_holds_data(struct amd_super *super, int fd, char *subdev)
{
	struct amd_super *other;
	int vol, foreign = 0;

	if (check_ext2(fd, subdev) | check_reiser(fd, subdev)) {
		cont_err("not adding %s: --force wipes it\n", subdev);
		return 1;
	}
	other = amd_new_super();
	if (amd_load_disk(other, fd, NULL, 0) == 0 && other->disks)
		for (vol = 0; vol < other->nvol; vol++) {
			struct amd_vol *v = &other->vol[vol];

			foreign += amd_vol_has_disk(v, other->disks->device_id) &&
				   !amd_ld_by_id(super, __le64_to_cpu(v->ld->id.id));
		}
	amd_free(other);
	if (foreign)
		pr_err("%s is a member of %d volume%s of another AMD RAID configuration: not adding it (--force wipes it)\n",
		       subdev, foreign, foreign == 1 ? "" : "s");
	return foreign;
}

/*
 * mdadm --add of @subdev to the container, before Manage wipes the disk
 * (Kill) and hands it to add_to_super_amd blank.  mdmon records the disk,
 * so it must run.  A Legacy disk holds data: never - nor a disk we cannot
 * read to tell.  A disk of this configuration keeps its DeviceID (a member
 * failed on errors given back).
 */
static int amd_check_add(struct supertype *st, char *subdev)
{
	struct amd_super *super = st->sb;
	struct amd_metadata *md = amd_alloc(AMD_SECTOR);
	int fd = -1, i, rv = 0, table;

	super->add_id = 0;
	super->add_checked = 0;
	if (!mdmon_running(st->container_devnm)) {
		pr_err("%s: mdmon records a new disk, and it does not run for this container: it runs while a RAID1, RAID10, RAID5 or RAIDABLE volume of it is started\n",
		       subdev);
		goto out;
	}
	fd = open(subdev, O_RDONLY);
	table = md && is_fd_valid(fd) ? amd_foreign_table(fd, md) : -1;
	if (table < 0) {
		pr_err("cannot read %s, not adding it\n", subdev);
		goto out;
	}
	if (table) {
		pr_err("%s has a partition table: it may hold data, not adding it (wipe it first)\n",
		       subdev);
		goto out;
	}
	i = -1;
	if (amd_read(fd, AMD_METADATA_LBA, md, AMD_SECTOR) == 0 &&
	    __le64_to_cpu(md->ident) == AMD_RC_IDENT)
		i = amd_pd_index(super, __le64_to_cpu(md->device_id));
	if (i >= 0) {
		if (__le32_to_cpu(super->pd[i]->device_type) != AMD_DEV_RAIDCORE_DISK) {
			pr_err("%s is a Legacy (non-RAID) disk of the AMD RAID configuration: it holds data, not adding it\n",
			       subdev);
			goto out;
		}
		super->add_id = __le64_to_cpu(md->device_id);
	}
	/*
	 * No label, but the configuration has the disk (its DeviceID is the
	 * hash of its serial number).  As a non-RAID one: the AMD driver for
	 * Windows records a blank NVMe drive so, NOT_INITIALIZE with a Legacy
	 * LD of its own (rcadm -M -id turns the PD into a RAIDCore disk and
	 * drops that LD).  As a RAID disk: its label was wiped while its record
	 * stayed.  Here it would get another, random, DeviceID and two records.
	 */
	if (!super->add_id) {
		unsigned char sn[20];

		i = amd_disk_serial(fd, sn) == 0 ?
		    amd_pd_index(super, amd_serial_hash(sn)) : -1;
		if (i >= 0 &&
		    __le32_to_cpu(super->pd[i]->device_type) != AMD_DEV_RAIDCORE_DISK) {
			pr_err("%s is a non-RAID disk of the AMD RAID configuration (not initialized or Legacy): initialize it in the BIOS RAID menu or with rcadm -M -id first\n",
			       subdev);
			goto out;
		}
		if (i >= 0) {
			pr_err("%s has no AMD label, but the AMD RAID configuration has it as a RAID disk (was its label wiped?): it would be recorded twice, not adding it\n",
			       subdev);
			goto out;
		}
	}
	if (!super->add_id && !st->force &&
	    amd_add_holds_data(super, fd, subdev))
		goto out;
	/* a disk new to the configuration takes one more PD record */
	if (!super->add_id && super->npd >= AMD_MAX_PD) {
		pr_err("the AMD RAID configuration has %d device records, as many as mdadm reads: not adding %s\n",
		       AMD_MAX_PD, subdev);
		goto out;
	}
	super->add_checked = 1;
	rv = 1;
out:
	close_fd(&fd);
	free(md);
	return rv;
}

/* map_update() frees the entry's path before copying the new one */
static void amd_map_set_uuid(struct map_ent **map, struct map_ent *me,
			     int uuid[4])
{
	char devnm[sizeof(me->devnm)], meta[sizeof(me->metadata)];
	char *path = me->path ? xstrdup(me->path) : NULL;

	snprintf(devnm, sizeof(devnm), "%s", me->devnm);
	snprintf(meta, sizeof(meta), "%s", me->metadata);
	map_update(map, devnm, meta, uuid, path);	/* frees *map */
	free(path);
}

/*
 * The container UUID comes from its lowest DeviceID (AMD records no ID of
 * the disk set, see amd_container_uuid): a disk added with a lower one
 * changes it.  Keep the map of the running container in step and say so -
 * an mdadm.conf that names the container by UUID needs the new one.  The
 * map is locked: we are called from add_to_super through Manage_add(),
 * which holds the map lock (one per process, mapfile.c) until the disk is
 * in - taking and dropping it here would drop Manage's.
 */
static void amd_new_container_uuid(struct supertype *st, __u64 id,
				   const char *name)
{
	struct map_ent *map = NULL, *me;
	char buf[64];
	int uuid[4];

	amd_uuid("container", AMD_SERIAL, id, uuid);
	me = map_by_devnm(&map, st->container_devnm);
	if (me)
		amd_map_set_uuid(&map, me, uuid);
	map_free(map);
	pr_err("%s has the lowest DeviceID now: the container UUID becomes %s (update mdadm.conf if it names the container)\n",
	       name, amd_uuid_text(uuid, buf));
}

/*
 * Send the updates queued for mdmon and see that it has recorded them.  It
 * sends no answer, and an update that no longer fits its configuration -
 * another mdadm or the monitor itself changed it meanwhile - it turns down
 * in the kernel log only (amd_kill_volume, amd_apply_role ...); one it
 * cannot write stays in its memory (amd_flush_config).  But the
 * configuration is on the disks by the time flush_metadata_updates() has
 * its ack: managemon gives that once the queue is empty and the monitor
 * has made another pass (managemon.c handle_message), and the monitor
 * writes right after process_update (monitor.c wait_and_act).  So
 * @recorded asks the configuration on the disks of @st's container, loaded
 * afresh, whether the change is there.  IMSM does not check ("these
 * routines do not report success/failure", Kill.c).  0 if it is there, 1
 * if not, -1 if mdmon cannot be reached (said here).
 */
static int amd_mdmon_recorded(struct supertype *st,
			      int (*recorded)(struct amd_super *, const void *),
			      const void *arg)
{
	struct supertype *tst;
	int fd, rv = 1;

	if (flush_metadata_updates(st) != 0) {
		pr_err("cannot reach mdmon\n");
		return -1;
	}
	tst = dup_super(st);
	fd = open_dev(st->container_devnm);
	if (is_fd_valid(fd) && tst->ss->load_container(tst, fd, NULL) == 0) {
		rv = !recorded(tst->sb, arg);
		tst->ss->free_super(tst);
	}
	close_fd(&fd);
	free(tst);
	return rv;
}

/* amd_mdmon_recorded of --add: disk @id has a PD record */
static int amd_has_pd(struct amd_super *super, const void *id)
{
	return amd_pd_index(super, *(const __u64 *)id) >= 0;
}

/*
 * mdadm --add, after Manage wiped the disk: initialize it as the BIOS
 * menu does (Initialize; a new disk also Assign Global Hot Spare: label
 * SpareInfo 0x100) and tell mdmon (ADD), which records it in
 * the configuration and rebuilds onto it.  The descriptor is ours on
 * success (Manage): closed here, as the disk must be free for the kernel.
 */
static int amd_add_new(struct supertype *st, int fd, char *devname)
{
	struct amd_super *super = st->sb;
	const char *name = devname ? devname : "the disk";
	struct amd_update_disk *u;
	unsigned long long dsize;
	__u32 spare = AMD_SPARE_GLOBAL;
	struct amd_disk d;
	struct stat stb;
	int rv;

	if (fd < 0 || !get_dev_size(fd, devname, &dsize) ||
	    fstat(fd, &stb) != 0 || !S_ISBLK(stb.st_mode))
		return 1;
	memset(&d, 0, sizeof(d));
	d.fd = fd;
	d.sectors = dsize / AMD_SECTOR;
	d.major = major(stb.st_rdev);
	d.minor = minor(stb.st_rdev);
	d.device_id = super->add_id ? super->add_id : amd_disk_id(super, fd);
	/* a former global spare stays one (the PD keeps SpareInfo 0x100) */
	if (super->add_id) {
		int i = amd_pd_index(super, super->add_id);

		spare = i >= 0 ? __le32_to_cpu(super->pd[i]->spare_info) &
				 AMD_SPARE_GLOBAL : 0;
		/* in no volume any more: a global spare (amd_add_pd) */
		if (!amd_disk_in_volumes(super, super->add_id))
			spare = AMD_SPARE_GLOBAL;
	}
	if (amd_init_disk(&d, spare, super->add_id != 0) != 0) {
		pr_err("%s: cannot initialize the disk\n", name);
		return 1;
	}
	u = xcalloc(1, sizeof(*u));
	u->type = AMD_UPDATE_ADD;
	u->id = d.device_id;
	u->known = super->add_id != 0;
	u->sectors = d.sectors;
	u->features = amd_pd_features(fd, d.major, d.minor);
	st->update_tail = &st->updates;
	append_metadata_update(st, u, sizeof(*u));
	rv = amd_mdmon_recorded(st, amd_has_pd, &d.device_id);
	if (rv) {
		/* not in the configuration: no label of it on the disk either */
		amd_erase(fd);
		if (rv > 0)
			pr_err("%s: mdmon did not record the disk (see dmesg)\n",
			       name);
		return 1;
	}
	if (!super->add_id && d.device_id < super->container_id)
		amd_new_container_uuid(st, d.device_id, name);
	if (st->verbose >= 0) {
		if (super->add_id &&
		    !amd_disk_in_volumes(super, super->add_id))
			pr_err("%s: dropped from its volumes, added back as an AMD global hot spare\n",
			       name);
		else if (super->add_id)
			pr_err("%s: a former member, it will be rebuilt\n",
			       name);
		else
			pr_err("%s: added as an AMD global hot spare\n", name);
	}
	close(fd);
	return 0;
}

/* the LD record with volume ID @id in the packet, any type; NULL if none */
static struct amd_ld *amd_ld_by_id(struct amd_super *super, __u64 id)
{
	struct amd_packet_header *h = super->packet;
	unsigned int off = __le32_to_cpu(h->ld_offset);
	struct amd_ld *ld;

	while ((ld = amd_next_ld(super, &off)))
		if (__le64_to_cpu(ld->id.id) == id)
			return ld;
	return NULL;
}

/* the volume whose (first) LD record has ID @id, or NULL */
static struct amd_vol *amd_vol_by_id(struct amd_super *super, __u64 id)
{
	int vol;

	for (vol = 0; vol < super->nvol; vol++)
		if (__le64_to_cpu(super->vol[vol].ld->id.id) == id)
			return &super->vol[vol];
	return NULL;
}

/*
 * The disks on a controller AMD RAID takes that are neither RAIDCore disks
 * nor in the configuration: each gets a Legacy LD.  None counted for a
 * container of images (a disk behind no controller).
 */
static int amd_unlisted_disks(struct amd_super *super)
{
	struct amd_metadata *md = amd_alloc(AMD_SECTOR);
	int real = 1, present, n = 0;
	struct amd_disk *d;
	unsigned int raid;
	struct dirent *de;
	char pci[16];
	DIR *dir;

	for (d = super->disks; d; d = d->next)
		if (amd_pci_of(d->major, d->minor, pci) != 1)
			real = 0;
	raid = amd_raid_var(&present);
	dir = real && raid && md ? opendir("/sys/block") : NULL;
	while (dir && (de = readdir(dir)) != NULL) {
		unsigned int vendor, device;
		unsigned char sn[20];
		int maj, min, fd, skip = 0;
		dev_t devid;

		if (de->d_name[0] == '.')
			continue;
		devid = devnm2devid(de->d_name);
		maj = major(devid);
		min = minor(devid);
		if (!devid || amd_pci_of(maj, min, pci) != 1 ||
		    !amd_raid_takes(pci, raid, &vendor, &device))
			continue;
		for (d = super->disks; d; d = d->next)
			skip |= d->major == maj && d->minor == min;
		fd = skip ? -1 : amd_dev_open(maj, min, O_RDONLY);
		if (!is_fd_valid(fd))
			continue;
		if (amd_read(fd, AMD_METADATA_LBA, md, AMD_SECTOR) == 0 &&
		    __le64_to_cpu(md->ident) == AMD_RC_IDENT)
			skip = 1;	/* a RAID disk, of this configuration or not */
		else if (amd_disk_serial(fd, sn) == 0 &&
			 amd_pd_index(super, amd_serial_hash(sn)) >= 0)
			skip = 1;	/* in the configuration: a PD of its own */
		close(fd);
		n += !skip;
	}
	if (dir)
		closedir(dir);
	free(md);
	return n;
}

/*
 * The AMD RAID BIOS menu and rcadm create no array past 12 on a system,
 * Legacy LDs counted, second LD copies not (RAIDCoreDxe FUN_0000f140; the
 * menu of an MSI X870E greys out "Create Array" at 12, a Legacy disk
 * counted).  The cores go past it: the BIOS and the Windows driver
 * give every non-RAID disk they find a Legacy LD of its own (FUN_0002c130;
 * rcraid.sys 9.3.3.218 RC_AddLegacyLogicalDevice @140019344, a blank disk
 * too).  The arrays there are and will be: the LDs of the packet, a Legacy
 * LD to come for each non-RAID PD without one and - with a container of
 * real disks - for each other disk on a controller AMD RAID takes that is
 * neither a RAIDCore disk nor in the configuration (amd_unlisted_disks).
 * *legacy: how many of them are Legacy.
 */
#define AMD_MENU_ARRAYS		12
static int amd_array_count(struct amd_super *super, int *legacy)
{
	struct amd_packet_header *h = super->packet;
	unsigned int off = __le32_to_cpu(h->ld_offset);
	int n = 0, copy = 0, unlisted, i;
	struct amd_ld *ld;

	*legacy = 0;
	while ((ld = amd_next_ld(super, &off))) {
		__u32 type = __le32_to_cpu(ld->device_type);

		if (!copy && type != AMD_LDT_RAW) {
			n++;
			*legacy += type == AMD_LDT_LEGACY;
		}
		copy = !copy && __le32_to_cpu(ld->transform_link) == 1;
	}
	for (i = 0; i < super->npd; i++) {
		__u32 type = __le32_to_cpu(super->pd[i]->device_type);

		if (type != AMD_DEV_RAIDCORE_DISK && type != AMD_DEV_RAIDCORE_CORE &&
		    !amd_ld_by_id(super, __le64_to_cpu(super->pd[i]->id.id))) {
			n++;
			(*legacy)++;
		}
	}
	unlisted = amd_unlisted_disks(super);
	*legacy += unlisted;
	return n + unlisted;
}

/*
 * mdadm -C of a volume: within the limit of the BIOS menu, or --force.
 * Not for a RAIDABLE: its --force is the one mdadm.c asks for -n1.
 */
static int amd_array_limit(struct supertype *st, int verbose)
{
	struct amd_super *super = st->sb;
	int legacy, n = amd_array_count(super, &legacy);
	int force = st->force && !super->whole;

	if (n < AMD_MENU_ARRAYS)
		return 1;
	if (verbose || !force) {
		pr_err("AMD RAID allows %d arrays in a system (the BIOS menu and rcadm stop there), and the BIOS and Windows count each Legacy (non-RAID) disk as one: there are %d (%d Legacy)\n",
		       AMD_MENU_ARRAYS, n, legacy);
		if (force)
			cont_err("creating one more anyway (--force): the BIOS menu will create no array then\n");
		else if (super->whole)
			cont_err("delete one first: a RAIDABLE volume is not created past the limit\n");
		else
			cont_err("delete one first, or give --force to go past the limit (the BIOS menu then creates none)\n");
	}
	return force;
}

/*
 * The BIOS menu and rcadm create a volume of 8 disks at most, at every
 * level ("An invalid number of disks were selected for the chosen RAID
 * level", "VOLUME is limited to 8 drives"; RAIDCoreDxe 1.A93, rcadm
 * 9.3.3).  Both took volumes of up to 12 disks made otherwise as Normal
 * (RAID0, RAID10, Volume on two controllers; dumps/2026-11-12-q3j-w3), so
 * --force goes past the limit.
 */
#define AMD_MENU_DISKS		8

static int amd_disk_limit(struct supertype *st, int raiddisks, int verbose)
{
	if (raiddisks <= AMD_MENU_DISKS)
		return 1;
	if (verbose || !st->force) {
		pr_err("the AMD BIOS menu and rcadm create volumes of at most %d disks\n",
		       AMD_MENU_DISKS);
		if (st->force)
			cont_err("creating one of %d anyway (--force): the BIOS and the Windows driver take it, but cannot create it again\n",
				 raiddisks);
		else
			cont_err("give --force to go past the limit: the BIOS and the Windows driver take such a volume, but cannot create it again\n");
	}
	return st->force;
}

/* @subdev can be a disk of the container: a whole disk, not in use */
static int amd_validate_disk(struct supertype *st, char *subdev,
			     unsigned long long *freesize, int verbose)
{
	struct amd_super *super = st->sb;
	unsigned long long ldsize;
	unsigned int sectsize;
	int fd;

	/* mdadm --add to a container we read: checked before mdadm wipes it */
	if (super && super->packet && !super->creating &&
	    !amd_check_add(st, subdev))
		return 0;
	if (!amd_controller_ok(st, subdev, verbose))
		return 0;
	fd = open(subdev, O_RDONLY | O_EXCL);
	if (!is_fd_valid(fd)) {
		if (verbose)
			pr_err("%s is busy, cannot use it\n", subdev);
		return 0;
	}
	if (test_partition(fd) || !get_dev_size(fd, subdev, &ldsize)) {
		if (verbose)
			pr_err("%s: AMD RAID needs a whole disk\n", subdev);
		close(fd);
		return 0;
	}
	/* volumes start at AMD_DEFAULT_ALLOC_LBA, Initialize zeroes both ends */
	if (ldsize / AMD_SECTOR < 2 * AMD_INIT_ZERO + AMD_DEFAULT_ALLOC_LBA) {
		if (verbose)
			pr_err("%s is too small for AMD RAID: %llu MiB, at least %u MiB are needed\n",
			       subdev, ldsize / AMD_SECTOR / AMD_MIB,
			       (2 * AMD_INIT_ZERO + AMD_DEFAULT_ALLOC_LBA) / AMD_MIB);
		close(fd);
		return 0;
	}
	/*
	 * The AMD format counts in 512-byte sectors and AMD has no 4Kn
	 * variant (Dell's S150 RAIDCore has one, bcraid690.sys); we could not
	 * read back what we wrote there (amd_read, O_DIRECT).
	 */
	if (!get_dev_sector_size(fd, subdev, &sectsize) ||
	    sectsize != AMD_SECTOR) {
		if (verbose)
			pr_err("%s: AMD RAID takes disks with 512-byte logical sectors only\n",
			       subdev);
		close(fd);
		return 0;
	}
	close(fd);
	if (freesize)
		*freesize = ldsize / AMD_SECTOR - AMD_DEFAULT_ALLOC_LBA;
	return 1;
}

/* The chunk size of a new volume: as the BIOS menu offers them */
static int amd_validate_chunk(int level, int *chunk, int verbose)
{
	if (!chunk)
		return 1;
	if (level == LEVEL_LINEAR) {
		/* md linear would round the members down to it */
		if (*chunk != UnSet && *chunk != 0) {
			if (verbose)
				pr_err("an AMD RAID Volume (linear) has no chunk size\n");
			return 0;
		}
		*chunk = 0;
		return 1;
	}
	if (*chunk == UnSet || *chunk == 0)
		*chunk = level == 1 ? 0 : 64;
	if (level != 1 && *chunk != 64 && *chunk != 128 && *chunk != 256) {
		if (verbose)
			pr_err("AMD RAID chunk size is 64, 128 or 256 KiB\n");
		return 0;
	}
	return 1;
}

static int validate_geometry_amd(struct supertype *st, int level, int layout,
				 int raiddisks, int *chunk,
				 unsigned long long size,
				 unsigned long long data_offset,
				 char *subdev, unsigned long long *freesize,
				 int consistency_policy, int verbose)
{
	struct amd_super *super = st->sb;
	int whole = amd_is_raidable(level, raiddisks);

	if (is_container(level))
		/* without a disk: the level is fine */
		return !subdev ||
		       amd_validate_disk(st, subdev, freesize, verbose);

	if (!amd_level_ok(level, raiddisks, verbose))
		return 0;
	if (level == 5 && layout != UnSet &&
	    layout != ALGORITHM_RIGHT_ASYMMETRIC) {
		if (verbose)
			pr_err("AMD RAID5 is right-asymmetric (--layout=ra)\n");
		return 0;
	}
	/* the mirrors of a RAID10N are neighbours: md's near copies */
	if (level == 10 && layout != UnSet && layout != 0x102) {
		if (verbose)
			pr_err("AMD RAID10 has two near copies (--layout=n2)\n");
		return 0;
	}
	if (!amd_validate_chunk(level, chunk, verbose))
		return 0;
	/* a member is whole MiB (amd_init_volume): less would be none */
	if (size && size < AMD_MIB) {
		if (verbose)
			pr_err("an AMD RAID member is sized in whole MiB: --size is 1M at least\n");
		return 0;
	}
	if (subdev) {
		if (!amd_pick_disk(st, subdev, whole, size, freesize, verbose))
			return 0;
		super = st->sb;		/* the first disk loaded it */
		if (super->nvol >= AMD_MAX_VOL) {
			if (verbose)
				pr_err("the container has the maximum number of volumes\n");
			return 0;
		}
		/* once, with the first disk */
		if (super->npick == 1 && (!amd_array_limit(st, verbose) ||
					  !amd_disk_limit(st, raiddisks, verbose)))
			return 0;
		return 1;
	}
	/* -e amd and disks: the first of them loads the container */
	if (!super)
		return 1;
	if (!super->packet) {
		if (verbose)
			pr_err("no AMD RAID container loaded\n");
		return 0;
	}
	if (super->nvol >= AMD_MAX_VOL) {
		if (verbose)
			pr_err("the container has the maximum number of volumes\n");
		return 0;
	}
	/* no disks given: the container's own (Create asks with size 0 first) */
	if (!super->npick && !amd_new_size(super, whole, size, verbose))
		return 0;
	if (!super->npick && (!amd_array_limit(st, verbose) ||
			      !amd_disk_limit(st, raiddisks, verbose)))
		return 0;
	if (!amd_autolayout(super, raiddisks, size, freesize)) {
		if (verbose && super->npick && super->npick != raiddisks)
			pr_err("give all %d disks of the new volume (%d given)\n",
			       raiddisks, super->npick);
		else if (verbose && super->npick)
			pr_err("the disks given have less free space than asked for\n");
		else if (verbose)
			amd_explain_room(super, raiddisks, size);
		return 0;
	}
	return 1;
}

static void default_geometry_amd(struct supertype *st, int *level,
				 int *layout, int *chunk)
{
	if (level && *level == UnSet)
		*level = LEVEL_CONTAINER;
	if (level && layout && *layout == UnSet)
		*layout = *level == 10 ? 0x102 :	/* RAID10: near 2 */
			  *level == 5 ? ALGORITHM_RIGHT_ASYMMETRIC : 0;
	if (level && chunk && (*chunk == UnSet || *chunk == 0))
		*chunk = *level == 1 || *level == LEVEL_LINEAR ||
			 is_container(*level) ? 0 : 64; /* BIOS default */
}

static __u64 avail_size_amd(struct supertype *st, __u64 devsize,
			    unsigned long long data_offset)
{
	devsize = amd_align_capacity(devsize);
	if (devsize < AMD_DEFAULT_ALLOC_LBA + AMD_SERVICE + AMD_MIB)
		return 0;
	return (devsize - AMD_DEFAULT_ALLOC_LBA - AMD_SERVICE) / AMD_MIB * AMD_MIB;
}

/* First x Second elements of a new volume of md @level on @n disks */
static void amd_ld_shape(int level, int n, int *f, int *s)
{
	if (level == 0 || level == LEVEL_LINEAR) {
		*f = n;		/* RAID10N with one copy, Volume (menu: First=n, Second=1) */
		*s = 1;
	} else if (level == 1) {
		*f = 1;
		*s = 2;
	} else if (level == 5) {
		*f = 1;		/* one parity set (the menu and rcadm: First=1) */
		*s = n;
	} else {
		*f = n / 2;
		*s = 2;
	}
}

/* CacheTagSize for a chunk of @chunk_size bytes (see amd_chunk_sectors) */
static __u32 amd_chunk_tag(int chunk_size)
{
	switch (chunk_size / 1024) {
	case 128:
		return 2;
	case 256:
		return 3;
	default:
		return 1;
	}
}

/*
 * The @nel elements @el of a new volume of md @level, on the disks
 * autolayout picked, @member sectors of user data each; @capacity: their
 * sum (a Volume's).  0 if a disk has no room.
 */
static int amd_new_elements(struct amd_super *super, int level, int nel,
			    unsigned long long member, struct amd_element *el,
			    unsigned long long *capacity)
{
	int i;

	for (i = 0; i < nel; i++) {
		struct amd_disk *d = super->layout[i];
		int p = amd_pd_index(super, d->device_id);
		unsigned long long start, msize = member;

		/*
		 * A Volume without -z takes the largest free extent of each
		 * disk, as the menu at its maximum size does (rcblob
		 * RC_CreateRaidArray: MaxVolumeSpace = sum of them less the
		 * service area each; RC_AllocateSpace for a Volume falls back
		 * to the disk's largest extent).  With -z: that much on each.
		 */
		if (level == LEVEL_LINEAR && super->fill && p >= 0) {
			struct amd_disk *dd = NULL;

			msize = amd_disk_room(super, super->pd[p], &dd);
			if (msize < member)
				msize = 0;
		}
		/* autolayout picked distinct disks: one member each */
		start = msize ? amd_free_extent(super, d, msize + AMD_SERVICE) : 0;
		if (!start || p < 0)
			return 0;
		el[i].id = super->pd[p]->id;
		el[i].allocated.offset = __cpu_to_le64(start);
		el[i].allocated.size = __cpu_to_le64(msize + AMD_SERVICE);
		el[i].user_data.offset = __cpu_to_le64(start + AMD_SERVICE);
		el[i].user_data.size = __cpu_to_le64(msize);
		if (level == LEVEL_LINEAR)
			*capacity += msize;
	}
	return 1;
}

/*
 * The state new volume @ld (its LD record, @size bytes, with room for a
 * second copy after it) is created in, by md @level and --assume-clean
 * (@assume_clean).  Returns the length of its LD records: one, or two if md
 * initializes it (CREATE_REDUNDANCY, the second copy the transform's).
 */
static unsigned int amd_new_ld_state(struct amd_ld *ld, unsigned int size,
				     int level, int assume_clean)
{
	if (level == 0 || level == LEVEL_LINEAR) {
		/*
		 * As the menu writes a RAID0, a Volume and a RAIDABLE (MSI
		 * X870E; the same fields but type, size, counts): no transform,
		 * LastOperation CREATE_REDUNDANCY, TransformState 0, no bitmap,
		 * one LD record.  The menu leaves State 0, which its next
		 * configuration write makes NORMAL (amd_classify_state): mdadm
		 * writes the NORMAL at once.
		 */
		ld->state = __cpu_to_le32(AMD_LD_STATE_NORMAL);
		ld->transform_type = 0;
		ld->transform_flags = 0;
		ld->attribute = 0;
		return size;
	}
	if (assume_clean) {
		/* --assume-clean: recorded as initialized, as mdmon would */
		ld->state = __cpu_to_le32(AMD_LD_STATE_NORMAL);
		ld->transform_type = 0;
		ld->transform_state = __cpu_to_le32(AMD_TRANSFORM_COMPLETED);
		ld->transform_flags = 0;
		return size;
	}
	memcpy((char *)ld + size, ld, size);
	ld->transform_link = __cpu_to_le32(1);
	return 2 * size;
}

/*
 * The LD record pair of a new volume, inserted at the end of the LD list;
 * @kib KiB a member; @assume_clean: --assume-clean.
 */
static int amd_init_volume(struct amd_super *super, mdu_array_info_t *info,
			   unsigned long long kib, char *name, int assume_clean)
{
	int f, s, n = info->raid_disks;
	int raidable = amd_is_raidable(info->level, n);
	/*
	 * A RAIDABLE is laid out and recorded as the Volume of its one disk,
	 * but for the type: so the menu writes the two (snapshots 04 and 14
	 * of dumps/2026-11-06-qemu-spares-raidable); its disk is all its own
	 * (amd_disk_room).
	 */
	int level = raidable ? LEVEL_LINEAR : info->level;
	unsigned long long member = kib * 2;
	unsigned long long capacity = 0;
	struct amd_packet_header *h = super->packet;
	unsigned int size, at, len;
	struct amd_element *el;
	struct amd_dev_id *ref;
	struct amd_ld *ld;
	__u32 cts;
	char *rec;

	member = member / AMD_MIB * AMD_MIB;
	if (!amd_level_ok(info->level, n, 1) || member == 0 ||
	    !amd_autolayout(super, n, member, NULL))
		return 0;
	amd_ld_shape(level, n, &f, &s);
	cts = amd_chunk_tag(info->chunk_size);

	size = sizeof(*ld) + (f * s) * sizeof(*el) + sizeof(struct amd_dev_id);
	rec = xcalloc(2, size);
	ld = (struct amd_ld *)rec;
	ld->type = __cpu_to_le32(AMD_DST_LD);
	ld->element_offset = __cpu_to_le32(sizeof(*ld));
	ld->device_type = __cpu_to_le32(AMD_LDT_RAID10N);
	ld->transform_type = __cpu_to_le32(AMD_TRANSFORM_CREATE_REDUNDANCY);
	ld->last_operation = ld->transform_type;
	ld->id.id = __cpu_to_le64(amd_random_id(super));
	/* its Handle: the next one, given as the packet is written (amd_number_lds) */
	ld->capacity = __cpu_to_le64(member * f *
				     (level == 5 ? s - 1 : 1));
	ld->generation = __cpu_to_le64(super->generation);
	ld->devices = __cpu_to_le32(n);
	ld->first_count = __cpu_to_le32(f);
	ld->second_count = __cpu_to_le32(s);
	ld->parent_count = __cpu_to_le32(1);
	ld->transform_flags = __cpu_to_le32(AMD_TFLAGS_CREATE);
	ld->cache = __cpu_to_le32(AMD_CACHE_READ | AMD_CACHE_WRITE_BACK); /* menu default */
	ld->packet_size = __cpu_to_le32(size);
	ld->attribute = __cpu_to_le32(AMD_ATTR_BITMAP);
	ld->task_priority = __cpu_to_le32(0x14);
	ld->cache_tag_size = __cpu_to_le32(cts);
	if (name)
		memcpy(ld->name, name, strnlen(name, sizeof(ld->name) - 1));
	el = (struct amd_element *)(ld + 1);
	if (!amd_new_elements(super, level, f * s, member, el,
			      &capacity)) {
		free(rec);
		return 0;
	}
	if (level == 5)
		ld->device_type = __cpu_to_le32(AMD_LDT_RAID50);
	if (level == LEVEL_LINEAR) {
		/* as the menu writes one (MSI X870E): like its RAID0 */
		ld->device_type = __cpu_to_le32(AMD_LDT_VOLUME);
		ld->capacity = __cpu_to_le64(capacity);
		ld->cache_tag_size = __cpu_to_le32(1);
	}
	if (raidable)
		ld->device_type = __cpu_to_le32(AMD_LDT_RAIDABLE);
	/* the parent reference: the controller */
	ref = (struct amd_dev_id *)(el + f * s);
	ref->id = __cpu_to_le64(super->serial);
	ref->handle = __cpu_to_le16(0xffff);
	at = __le32_to_cpu(h->ld_offset) + __le32_to_cpu(h->ld_size);
	len = amd_new_ld_state(ld, size, level, assume_clean);
	if (amd_packet_reserve(super, len) != 0 ||
	    amd_insert_ld(super, at, rec, len) != 0) {
		free(rec);
		return 0;
	}
	free(rec);
	super->new_vol = super->nvol - 1;
	super->current_vol = super->new_vol;
	super->add_slot = -1;
	return 1;
}

/*
 * --create --bitmap: can the new volume @v have an md bitmap?  Asked as it
 * is laid out (its members' extents are known then), so that a refusal is
 * one line: Create.c follows any refusal of add_internal_bitmap with
 * "Given bitmap chunk size not supported.", which is not why.
 */
static int amd_mdbm_possible(const struct amd_vol *v, enum bitmap_type btype)
{
	/* a RAIDABLE (md raid1 of one) has nothing to resync, and AMD no bitmap */
	if (v->single || (v->level != 1 && v->level != 10 && v->level != 5)) {
		pr_err("an md bitmap is for AMD RAID1, RAID10 and RAID5 volumes\n");
		return 0;
	}
	/* md keeps the bits alone (bitmap/metadata=external), as for IMSM */
	if (btype != BitmapInternal) {
		pr_err("an AMD volume takes --bitmap=internal only\n");
		return 0;
	}
	if (!amd_mdbm_lba(v)) {
		pr_err("no md bitmap for this volume: its members do not start at one LBA (another volume lies before it on only some of its disks); create it without --bitmap, or on disks that hold the same volumes\n");
		return 0;
	}
	return 1;
}

/*
 * @name fits a volume's DevicePrivate - 1 to 31 characters and the NUL - and
 * no volume but @vol (-1: a new one) has it: two of a name are assembled as
 * <name>_0 and <name>_1, whichever comes first.  IMSM refuses the same
 * (imsm_check_name).
 */
static int amd_name_ok(struct amd_super *super, const char *name, int vol)
{
	const size_t max = sizeof(((struct amd_ld *)NULL)->name) - 1;
	size_t len = strlen(name);
	int i;

	if (len < 1 || len > max) {
		pr_err("an AMD volume name is 1 to %zu characters\n", max);
		return 0;
	}
	for (i = 0; i < super->nvol; i++)
		if (i != vol &&
		    strncmp((char *)super->vol[i].ld->name, name, max + 1) == 0) {
			pr_err("subarray-%d of the container has the name %s already\n",
			       i, name);
			return 0;
		}
	return 1;
}

static int init_super_amd(struct supertype *st, mdu_array_info_t *info,
			  struct shape *s, char *name, char *homehost,
			  int *uuid, unsigned long long data_offset)
{
	struct amd_super *super;

	/* info == NULL: --zero-superblock, store_super erases */
	if (!info)
		return 0;
	if (data_offset != INVALID_SECTORS) {
		pr_err("data-offset not supported by amd\n");
		return 0;
	}
	if (info->level == LEVEL_CONTAINER) {
		free_super_amd(st);
		super = amd_new_super();
		super->serial = AMD_SERIAL;
		super->creating = AMD_CREATE_CONTAINER;
		st->sb = super;
		return 1;
	}
	super = st->sb;
	if (!super || !super->packet || super->creating) {
		pr_err("create the AMD RAID container first: mdadm -C /dev/md/<name> -e amd -n<disks> <disks>\n");
		return 0;
	}
	if (super->npick && super->npick != info->raid_disks) {
		pr_err("an AMD RAID volume is created on all its disks: give %d, not \"missing\"\n",
		       info->raid_disks);
		return 0;
	}
	/*
	 * --write-zeroes: Create zeroes [st->data_offset, size) of the disks
	 * it opened and sets --assume-clean.  A member's data starts where its
	 * element says, and with the container given Create opens no disk:
	 * the volume would be recorded as initialized with nothing zeroed.
	 */
	if (s && s->write_zeroes) {
		pr_err("--write-zeroes is not supported for an AMD RAID volume: md initializes it\n");
		return 0;
	}
	/* not cut short: the volume would come back under another name */
	if (name && name[0] && !amd_name_ok(super, name, -1))
		return 0;
	/* the shape's size: info->size is an int of KiB, short from 2 TiB a member */
	if (!amd_init_volume(super, info, s ? s->size : (unsigned int)info->size,
			     name, s && s->assume_clean)) {
		pr_err("cannot lay out the new AMD RAID volume\n");
		return 0;
	}
	if (s && s->btype != BitmapNone &&
	    !amd_mdbm_possible(&super->vol[super->new_vol], s->btype))
		return 0;
	return 1;
}

/*
 * --bitmap=internal at --create: the new volume gets an md bitmap (written
 * by write_init_super, run by set_bitmap) - off unless asked, as for IMSM.
 * Whether it can have one, init_super_amd has checked (amd_mdbm_possible).
 * @chunkp: --bitmap-chunk in bytes, or UnSet.
 */
static int add_internal_bitmap_amd(struct supertype *st, int *chunkp,
				   int delay, int write_behind,
				   unsigned long long size, int may_change,
				   int major, bool assume_clean)
{
	struct amd_super *super = st->sb;
	unsigned int want = 0, chunk;
	struct amd_vol *v;

	if (!super || super->new_vol < 0) {
		pr_err("an AMD volume gets an md bitmap as it is created, or with --update-subarray=N --update=bitmap\n");
		return -EINVAL;
	}
	v = &super->vol[super->new_vol];
	if (*chunkp != UnSet && *chunkp > 0)
		want = *chunkp / AMD_SECTOR;
	chunk = amd_mdbm_chunk(v, want);
	if (!chunk && !want) {
		pr_err("the new volume is too large for an md bitmap: its bitmap chunk would be over %u KiB\n",
		       AMD_MDBM_CHUNK_MAX / 2);
		return -EINVAL;
	}
	if (!chunk) {
		pr_err("a bitmap chunk of %u KiB gives the new volume more bits than the %u KiB AMD leaves for them: give a larger --bitmap-chunk\n",
		       want / 2, AMD_MDBM_ROOM / 1024);
		return -EINVAL;
	}
	super->new_mdbm = chunk;
	super->new_mdbm_clean = assume_clean;
	*chunkp = chunk * AMD_SECTOR;
	return 0;
}

/* end of the last section of the packet (PD, LD, 25BE, 25BF) */
static unsigned int amd_sections_end(const struct amd_packet_header *h)
{
	unsigned int end = __le32_to_cpu(h->ld_offset) + __le32_to_cpu(h->ld_size);

	if (__le32_to_cpu(h->ctrl_offset) + __le32_to_cpu(h->ctrl_size) > end)
		end = __le32_to_cpu(h->ctrl_offset) + __le32_to_cpu(h->ctrl_size);
	if (__le32_to_cpu(h->sep_offset) + __le32_to_cpu(h->sep_size) > end)
		end = __le32_to_cpu(h->sep_offset) + __le32_to_cpu(h->sep_size);
	return end;
}

/*
 * @delta bytes were inserted (or cut, < 0) at offset @at: move the 25BE and
 * 25BF sections behind it.  Offset 0 is a section the packet does not have
 * (the BIOS writes 0/0); an empty section keeps its place right behind the
 * one before, as the AMD drivers write it (dump ASRock X670E: 25BF at the
 * end of 25BE, size 0; rcraid 9.3.3 the same after every change).
 */
static void amd_move_sections(struct amd_packet_header *h, unsigned int at,
			      int delta)
{
	if (h->ctrl_offset && __le32_to_cpu(h->ctrl_offset) >= at)
		h->ctrl_offset = __cpu_to_le32(__le32_to_cpu(h->ctrl_offset) + delta);
	if (h->sep_offset && __le32_to_cpu(h->sep_offset) >= at)
		h->sep_offset = __cpu_to_le32(__le32_to_cpu(h->sep_offset) + delta);
}

/* the packet moves into buffer @p of @room bytes */
static void amd_packet_move(struct amd_super *super, void *p,
			    unsigned int room)
{
	memcpy(p, super->packet, super->packet_len);
	free(super->packet);
	super->packet = p;
	super->packet_room = room;
}

/* mdadm: room in the packet buffer to insert @size bytes (amd_packet_insert) */
static int amd_packet_reserve(struct amd_super *super, unsigned int size)
{
	unsigned int len = ROUND_UP(super->packet_len + size, AMD_SECTOR);
	void *p;

	if (len <= super->packet_room)
		return 0;
	p = amd_alloc(len);
	if (!p)
		return -1;
	amd_packet_move(super, p, len);
	return 0;
}

/*
 * Insert @size bytes of @rec (not in the packet) at offset @at, within the
 * sections; the packet grows to the sections rounded up to sectors and the
 * sections behind move.  The new header, or NULL with the packet as it
 * was.  The caller sets the size of the section it grew, and reparses.
 * The buffer has the room (amd_packet_reserve), or mdmon's monitor moves
 * the packet into the one managemon put by for the largest (amd_mm_room).
 */
static struct amd_packet_header *amd_packet_insert(struct amd_super *super,
						   unsigned int at,
						   const void *rec,
						   unsigned int size)
{
	struct amd_packet_header *h = super->packet;
	unsigned int end = amd_sections_end(h), len;
	char *p;

	if (at > end || end > super->packet_len)
		return NULL;
	len = ROUND_UP(end + size, AMD_SECTOR);
	if (len > AMD_MAX_PACKET)
		return NULL;
	if (len > super->packet_room) {
		if (!super->next_packet)
			return NULL;
		amd_packet_move(super, super->next_packet, AMD_MAX_PACKET);
		super->next_packet = NULL;
	}
	p = super->packet;
	memmove(p + at + size, p + at, end - at);
	memcpy(p + at, rec, size);
	memset(p + end + size, 0, len - end - size);
	h = (struct amd_packet_header *)p;
	amd_move_sections(h, at, size);
	h->packet_size = __cpu_to_le32(len);
	super->packet_len = len;
	return h;
}

/*
 * Insert PD record @rec into the packet, in Handle order as the
 * BIOS keeps them (a SATA disk initialized later sits between the other
 * SATA disks and the NVMe ones).
 */
static int amd_insert_pd(struct amd_super *super, const struct amd_pd *rec)
{
	struct amd_packet_header *h = super->packet;
	unsigned int size = sizeof(*rec), at, n, i;
	struct amd_pd *pd;

	n = __le32_to_cpu(h->pd_size) / sizeof(*rec);
	pd = (struct amd_pd *)((char *)h + __le32_to_cpu(h->pd_offset));
	for (i = 1; i < n; i++)
		if (__le16_to_cpu(pd[i].id.handle) > __le16_to_cpu(rec->id.handle))
			break;
	at = __le32_to_cpu(h->pd_offset) + i * size;
	if (__le32_to_cpu(h->ld_offset) < at)
		return -1;
	h = amd_packet_insert(super, at, rec, size);
	if (!h)
		return -1;
	h->pd_size = __cpu_to_le32(__le32_to_cpu(h->pd_size) + size);
	h->ld_offset = __cpu_to_le32(__le32_to_cpu(h->ld_offset) + size);
	amd_reparse(super);
	return 0;
}

/* Is disk @id in an element of @v (or of its second LD copy)? */
static int amd_vol_has_disk(const struct amd_vol *v, __u64 id)
{
	int i, n = amd_link_nel(v);

	if (amd_in_volume(v, id))
		return 1;
	for (i = 0; i < n; i++)
		if (__le64_to_cpu(amd_link_elements(v)[i].id.id) == id)
			return 1;
	return 0;
}

/* Is disk @id in an element of a volume (or of its second LD copy)? */
static int amd_disk_in_volumes(struct amd_super *super, __u64 id)
{
	int vol;

	for (vol = 0; vol < super->nvol; vol++)
		if (amd_vol_has_disk(&super->vol[vol], id))
			return 1;
	return 0;
}

/*
 * A PD record for disk @id, an ONLINE RAIDCore disk with the first free
 * Handle from 1 (as RAIDCoreDxe numbers them; the AMD driver for Windows
 * numbers from 0 by discovery - both take either).  The Handle, or -1.
 */
static int amd_new_pd(struct amd_super *super, __u64 id,
		      unsigned long long sectors, __u32 features, __u32 spare)
{
	struct amd_pd rec;
	int handle, used, i;

	for (handle = 1; ; handle++) {
		for (i = 0, used = 0; i < super->npd; i++)
			used |= __le16_to_cpu(super->pd[i]->id.handle) == handle;
		if (!used)
			break;
	}
	memset(&rec, 0, sizeof(rec));
	amd_fill_pd(&rec, id, handle, sectors, features, spare);
	if (amd_insert_pd(super, &rec) != 0)
		return -1;
	return handle;
}

/*
 * The disk md rebuilds onto (@el) has a PD record, and @el its Handle.  The
 * AMD driver drops the PD of a disk it ran without - the element stays,
 * with an offline handle 0x8000 - n and flags 0x30 - and puts it back, with
 * SpareInfo from the label, when the disk is there again (rcraid.sys
 * 9.3.3.218).  A member rebuilt in its slot here gets the same, or
 * RAIDCoreDxe (elements found by the PD's DeviceID) would not know the
 * disk of the element.  @features:
 * the PD Features of the disk, which managemon asked it for
 * (amd_mm_activate_spare) - not the monitor, under the lock.
 */
static void amd_rebuild_pd(struct amd_super *super, struct amd_element *el,
			   __u32 features)
{
	__u64 id = __le64_to_cpu(el->id.id);
	struct amd_disk *d = amd_find_disk(super, id);
	int i = amd_pd_index(super, id);

	if (i < 0 && d && d->fd >= 0) {
		int handle = amd_new_pd(super, id, d->sectors, features,
				      d->label_spare & AMD_SPARE_GLOBAL);

		if (handle < 0) {
			amd_kmsg("cannot record returning disk %016llx",
				 (unsigned long long)id);
			return;
		}
		dprintf("disk %016llx is back: PD again, handle %d\n",
			(unsigned long long)id, handle);
		super->config_dirty = 1;
		i = amd_pd_index(super, id);
	}
	if (i >= 0)
		el->id.handle = super->pd[i]->id.handle;
}

/*
 * Element @el, if it is disk @id's and failed on errors (0x10), becomes
 * offline (0x30).  An element of another disk keeps its flags: in the
 * second LD copy of a recorded rebuild the slot holds the rebuild target,
 * which a 0x20 alone would have the AMD driver take back without a rebuild
 * (see AMD_ELEMENT_FAILED).
 */
static void amd_give_back(struct amd_element *el, __u64 id)
{
	if (__le64_to_cpu(el->id.id) == id &&
	    (el->flags & __cpu_to_le32(AMD_ELEMENT_FAILED)))
		el->flags |= __cpu_to_le32(AMD_ELEMENT_MISSING);
}

/*
 * ADD (monitor): a former member failed on errors becomes offline (0x30)
 * and is rebuilt in its slot (amd_find_spare); a new disk gets a PD record
 * as a global hot spare, as the BIOS menu writes one (Initialize, then
 * Assign Global Hot Spare) - the next free Handle, SATA 0x2300 or NVMe 0x2100
 * features, SpareInfo 0x100.  *@space: a zeroed struct amd_disk, taken if
 * the disk needs a record.
 */
static void amd_add_pd(struct supertype *st, const struct amd_update_disk *u,
		       void **space)
{
	struct amd_super *super = st->sb;
	struct active_array *a;
	struct amd_disk *d;
	int vol, i;

	if (u->known && amd_pd_index(super, u->id) >= 0) {
		/*
		 * Its volumes dropped it (the AMD driver, back after running
		 * without it, zeroes its elements; rcraid.sys 9.3.3.218):
		 * given back as rcadm gives a disk to a volume, a global
		 * spare - rebuilt onto.
		 */
		if (!amd_disk_in_volumes(super, u->id)) {
			struct amd_pd *pd = super->pd[amd_pd_index(super, u->id)];

			pd->spare_info |= __cpu_to_le32(AMD_SPARE_GLOBAL);
			dprintf("disk %016llx: in no volume, a global spare\n",
				(unsigned long long)u->id);
		}
		for (vol = 0; vol < super->nvol; vol++) {
			struct amd_vol *v = &super->vol[vol];

			for (i = 0; i < v->nel; i++) {
				if (__le64_to_cpu(v->el[i].id.id) != u->id ||
				    !amd_slot_failed(v, i))
					continue;
				amd_give_back(&v->el[i], u->id);
				if (amd_link_same_shape(v))
					amd_give_back(&amd_link_elements(v)[i], u->id);
				dprintf("array %d member %d given back\n", vol, i);
			}
		}
		d = amd_find_disk(super, u->id);
		if (d)
			d->spare_failed = 0;
	} else if (!u->known && amd_pd_index(super, u->id) < 0) {
		/* one more record would be one amd_parse_packet does not see */
		int handle = super->npd >= AMD_MAX_PD ? -1 :
			   amd_new_pd(super, u->id, u->sectors, u->features,
				      AMD_SPARE_GLOBAL);

		if (handle < 0) {
			amd_kmsg("cannot record new disk %016llx",
				 (unsigned long long)u->id);
			return;
		}
		dprintf("disk %016llx: a global spare, handle %d\n",
			(unsigned long long)u->id, handle);
	} else {
		return;
	}
	/* the disk's record waits for it (amd_attach_disk), no configuration on it */
	d = amd_find_disk(super, u->id);
	if (!d) {
		d = *space;	/* amd_prepare_update's */
		*space = NULL;
		d->device_id = u->id;
		d->fd = -1;
		d->removed = 1;
		amd_add_disk(super, d);
	}
	d->fresh = 1;
	super->config_dirty = 1;
	for (a = st->arrays; a; a = a->next)
		a->check_degraded = 1;
}

/*
 * A disk joins the running container (udev adds disks one at a time, or
 * mdadm --add): managemon calls add_to_super.  It only reads the disk's
 * label and commit block and hands them, with the descriptor (ours, as IMSM
 * keeps it), to the monitor (ATTACH): the monitor alone changes the super -
 * it may be rebuilding the packet meanwhile.  Nothing is written here.
 */
static int amd_attach_disk(struct supertype *st, int fd, char *devname)
{
	struct amd_super *super = st->sb;
	struct amd_metadata *md;
	struct amd_commit *c;
	struct amd_update_attach *u;
	unsigned long long dsize;
	struct stat stb;
	void *packet;

	if (!super || !super->packet || fd < 0 || !st->update_tail ||
	    fstat(fd, &stb) != 0 || !S_ISBLK(stb.st_mode) ||
	    !get_dev_size(fd, devname, &dsize)) {
		amd_kmsg("cannot take %s into the container",
			 devname ? devname : "a new disk");
		if (fd >= 0)
			close(fd);
		return 1;
	}
	md = amd_alloc(AMD_SECTOR);
	c = amd_alloc(AMD_SECTOR);
	u = xcalloc(1, sizeof(*u));
	u->type = AMD_UPDATE_ATTACH;
	u->fd = fd;
	u->disk = xcalloc(1, sizeof(*u->disk));	/* the monitor allocates nothing */
	u->major = major(stb.st_rdev);
	u->minor = minor(stb.st_rdev);
	u->sectors = dsize / AMD_SECTOR;
	if (md && amd_read(fd, AMD_METADATA_LBA, md, AMD_SECTOR) == 0 &&
	    __le64_to_cpu(md->ident) == AMD_RC_IDENT) {
		u->id = __le64_to_cpu(md->device_id);
		u->features = __le32_to_cpu(md->features);
		u->spare_info = __le32_to_cpu(md->spare_info);
		u->mbr = amd_read_mbr_state(fd, md);
	}
	if (c && amd_read(fd, AMD_COMMIT_LBA, c, AMD_SECTOR) == 0 &&
	    amd_check_commit(c)) {
		u->commit_valid = 1;
		u->generation = __le64_to_cpu(c->generation);
		u->packet_number = __le64_to_cpu(c->packet_number);
		u->committed_checksum = __le64_to_cpu(c->committed_checksum);
		u->packet_lba = __le32_to_cpu(c->packet_offset);
		u->packet_size = __le32_to_cpu(c->packet_size);
		u->last_online = __le64_to_cpu(c->last_online_sn);
		packet = amd_read_packet(fd, c);
		if (packet) {
			u->disk->device_id = u->id;
			amd_note_own_packet(u->disk, packet, u->packet_size);
			free(packet);
		}
	}
	free(md);
	free(c);
	append_metadata_update(st, u, sizeof(*u));
	super->attached = 1;
	return 0;
}

/*
 * ATTACH (monitor): a disk of this configuration that has seen no newer
 * one is taken in and gets the following configurations too; one mdadm
 * --add initialized (its record waits, fresh: amd_add_pd) has "seen" the
 * current packet, as the disks of mdadm -C.  A disk we have open already
 * is left alone.  Other disks - new, foreign, with a newer configuration
 * than ours - are refused as before (the descriptor is closed).
 */
static void amd_attach_update(struct supertype *st,
			      const struct amd_update_attach *u)
{
	struct amd_super *super = st->sb;
	struct amd_packet_header *h = super->packet;
	struct amd_disk *rec = u->disk;
	struct active_array *a;
	struct amd_disk *d;

	/*
	 * Not in the PD list: the AMD driver drops the PD of a disk it ran
	 * without (its elements stay, offline) - such a former member is
	 * taken in, other disks are refused.
	 */
	if (!u->id || !h || (amd_pd_index(super, u->id) < 0 &&
			     !amd_disk_in_volumes(super, u->id)))
		goto refuse;
	d = amd_find_disk(super, u->id);
	if (d && d->fresh && d->fd < 0) {
		d->commit_valid = 1;
		d->generation = super->generation;
		d->committed_checksum = __le64_to_cpu(h->checksum);
		d->packet_lba = 0;
		d->packet_size = 0;
		d->packet_number = 0;
		d->features = AMD_FEATURES;
		d->spare_failed = 0;
		d->last_online = super->serial;
		d->foreign = super->foreign;
		super->config_dirty = 1;
	} else if (u->commit_valid && u->generation <= super->generation &&
		   (!d || d->fd < 0)) {
		if (!d) {
			d = rec;
			rec = NULL;
			d->device_id = u->id;
			d->fd = -1;
			amd_add_disk(super, d);
		} else {
			memcpy(d->own, rec->own, sizeof(d->own));
			d->nown = rec->nown;
		}
		d->commit_valid = 1;
		d->generation = u->generation;
		d->packet_number = u->packet_number;
		d->committed_checksum = u->committed_checksum;
		d->packet_lba = u->packet_lba;
		d->packet_size = u->packet_size;
		d->features = u->features;
		d->label_spare = u->spare_info;
		d->last_online = u->last_online;
		d->foreign = u->last_online != AMD_SERIAL;
		/*
		 * Failed or written to in vain before it left: back, it is a
		 * disk found anew, as on the AMD driver's rescan (PD ONLINE,
		 * the configuration written to it: amd_disk_idle).  Its
		 * failed elements stay so: it is no member again unless
		 * rebuilt.
		 */
		d->spare_failed = 0;
		d->write_failed = 0;
	} else {
		goto refuse;
	}
	d->mbr = u->mbr;
	d->major = u->major;
	d->minor = u->minor;
	d->sectors = u->sectors;
	d->removed = 0;
	d->fd = u->fd;
	dprintf("disk %016llx (%d:%d) joins the container\n",
		(unsigned long long)u->id, u->major, u->minor);
	/* it may be the spare, or the target of a rebuild, a volume waits for */
	for (a = st->arrays; a; a = a->next)
		a->check_degraded = 1;
	free(rec);
	return;
refuse:
	dprintf("disk %d:%d not taken into the container\n",
		u->major, u->minor);
	close(u->fd);
	free(rec);
}

static int add_to_super_amd(struct supertype *st, mdu_disk_info_t *dinfo,
			    int fd, char *devname, unsigned long long data_offset)
{
	struct amd_super *super = st->sb;
	struct amd_disk *d;
	unsigned long long dsize;
	struct stat stb;

	if (super && super->creating == AMD_CREATE_CONTAINER) {
		/* a disk of the container being created */
		if (fd < 0 || !get_dev_size(fd, devname, &dsize) ||
		    fstat(fd, &stb) != 0)
			return 1;
		d = xcalloc(1, sizeof(*d));
		d->fd = fd;	/* ours now: Create does not close it (as IMSM) */
		d->devname = devname ? xstrdup(devname) : NULL;
		d->sectors = dsize / AMD_SECTOR;
		d->major = major(stb.st_rdev);
		d->minor = minor(stb.st_rdev);
		d->device_id = amd_disk_id(super, fd);
		amd_add_disk(super, d);
		super->cur_disk = d;
		return amd_build_packet(super);
	}
	if (super && super->new_vol >= 0) {
		/* a member of the volume being created: laid out already */
		struct amd_vol *v = &super->vol[super->new_vol];

		if (dinfo->raid_disk < 0 || dinfo->raid_disk >= v->nel) {
			pr_err("a new AMD RAID volume takes no spares: add them to the container (global hot spares) or to the volume with --add-spare (dedicated ones)\n");
			return 1;
		}
		if (fd >= 0) {
			/* a disk given on the command line: the one picked */
			struct amd_disk *pick = super->layout[dinfo->raid_disk];
			int ok = super->npick == v->nel && fstat(fd, &stb) == 0 &&
				 pick->major == (int)major(stb.st_rdev) &&
				 pick->minor == (int)minor(stb.st_rdev);

			close(fd);	/* ours, as IMSM: Create does not close it */
			if (!ok) {
				pr_err("%s is not the disk laid out for member %d\n",
				       devname ? devname : "?", dinfo->raid_disk);
				return 1;
			}
		}
		super->add_slot = dinfo->raid_disk;
		return 0;
	}
	/* mdadm --add (Manage, no update list): the disk checked, then wiped */
	if (dinfo->raid_disk < 0 && !st->update_tail && super && super->packet &&
	    !super->creating && super->add_checked) {
		super->add_checked = 0;
		return amd_add_new(st, fd, devname);
	}
	if (dinfo->raid_disk < 0)
		return amd_attach_disk(st, fd, devname);	/* mdmon */
	pr_err("adding %s this way is not supported for AMD metadata: add it to the container\n",
	       devname ? devname : "the disk");
	return 1;
}

/*
 * The disk left the container.  From mdmon (managemon): queued, and done by
 * the monitor in amd_process_update, which may be writing to it.
 */
static void amd_remove_disk(struct amd_super *super,
			    const struct amd_update_disk *u)
{
	struct amd_disk *d;

	for (d = super->disks; d; d = d->next)
		if (!d->removed && d->major == u->major && d->minor == u->minor) {
			if (d->fd >= 0)
				close(d->fd);
			d->fd = -1;
			d->removed = 1;
			dprintf("disk %d:%d left the container\n",
				u->major, u->minor);
		}
}

static int remove_from_super_amd(struct supertype *st, mdu_disk_info_t *dk)
{
	struct amd_update_disk *u;

	if (!st->sb)
		return 1;
	u = xcalloc(1, sizeof(*u));
	u->type = AMD_UPDATE_REMOVE;
	u->major = dk->major;
	u->minor = dk->minor;
	/* managemon calls write_init_super next: nothing to write */
	((struct amd_super *)st->sb)->attached = 1;
	if (st->update_tail) {
		append_metadata_update(st, u, sizeof(*u));
		return 0;
	}
	amd_remove_disk(st->sb, u);
	free(u);
	return 0;
}

/*
 * A RAIDCore disk of this system that is not one of the container's: all
 * RAID disks of a machine share one configuration (one controller serial
 * number), so a second container would make two that RAIDCoreDxe picks
 * between by generation - the disks of the other would look stale.  Loop
 * devices (images) are not disks of the controller: a container of them is
 * checked against other images only, one of real disks against real ones.
 */
static char *amd_other_raidcore_disk(struct amd_super *super)
{
	static char name[300];
	struct amd_metadata *md = amd_alloc(AMD_SECTOR);
	DIR *dir = opendir("/sys/block");
	int images = amd_images(super);
	struct amd_disk *d;
	char *found = NULL;
	const char *nm;
	int maj, min, fd;

	while (md && dir && !found &&
	       (nm = amd_next_disk(dir, images, &maj, &min)) != NULL) {
		for (d = super->disks; d; d = d->next)
			if (d->major == maj && d->minor == min)
				break;
		if (d)
			continue;
		fd = amd_dev_open(maj, min, O_RDONLY);
		if (!is_fd_valid(fd))
			continue;
		if (amd_read(fd, AMD_METADATA_LBA, md, AMD_SECTOR) == 0 &&
		    amd_label_valid(md)) {
			snprintf(name, sizeof(name), "/dev/%s", nm);
			found = name;
		}
		close(fd);
	}
	if (dir)
		closedir(dir);
	free(md);
	return found;
}

/*
 * The service area of the elements of new volume @ld: no stale log, scan
 * or bitmap.  Before the configuration has the volume: a crash in between
 * leaves zeroes in free space.  @zero: AMD_SERVICE_BYTES of zeroes - the
 * monitor's from amd_prepare_update.
 */
static int amd_clear_service(struct amd_super *super, const struct amd_ld *ld,
			     const void *zero)
{
	const struct amd_element *el = amd_ld_elements(ld);
	unsigned int i, n = __le32_to_cpu(ld->first_count) *
			    __le32_to_cpu(ld->second_count);

	for (i = 0; i < n; i++) {
		struct amd_disk *d = amd_find_disk(super,
					__le64_to_cpu(el[i].id.id));

		if (!d || d->fd < 0 ||
		    pwrite(d->fd, zero, AMD_SERVICE_BYTES,
			   (off_t)__le64_to_cpu(el[i].allocated.offset) *
			   AMD_SECTOR) != AMD_SERVICE_BYTES || fsync(d->fd) != 0)
			return -1;
	}
	return 0;
}

/* ... mdadm's, with zeroes of its own */
static int amd_zero_service(struct amd_super *super, const struct amd_ld *ld)
{
	void *zero = amd_alloc(AMD_SERVICE_BYTES);
	int rv = zero ? amd_clear_service(super, ld, zero) : -1;

	free(zero);
	return rv;
}

/* disk @id is a global spare no more: its PD, and its label as we know it */
static void amd_drop_global(struct amd_super *super, __u64 id)
{
	struct amd_disk *d = amd_find_disk(super, id);
	int p = amd_pd_index(super, id);

	if (p >= 0)
		super->pd[p]->spare_info &= ~__cpu_to_le32(AMD_SPARE_GLOBAL);
	if (d)
		d->label_spare &= ~AMD_SPARE_GLOBAL;
}

/*
 * The global spares new volume @v is made of are spares no more: its
 * members end up as those of a volume made of Ready disks.  The AMD core
 * would leave SpareInfo as it is (rcblob RC_CreateRaidArray checks only
 * that a disk is online and initialized) and would take the rest of such
 * a disk for a rebuild of any volume; the menu builds volumes of Ready
 * disks only - a global spare has a status of its own there (RAIDCoreDxe
 * FUN_0000dc88) - and lists a member with SpareInfo 0x100 as a Global
 * Spare (MSI X870E, after a migration onto one).
 */
static void amd_take_spares(struct amd_super *super, const struct amd_vol *v)
{
	int i;

	for (i = 0; i < v->nel; i++)
		amd_drop_global(super, __le64_to_cpu(v->el[i].id.id));
}

/*
 * ... in their labels too: the BIOS fills the PD's SpareInfo in from the
 * label at every start (amd_label_spare).  mdadm writes them, as for the
 * other spare roles (subarray_spare_amd).
 */
static void amd_label_members(struct amd_super *super, const struct amd_vol *v)
{
	int i;

	for (i = 0; i < v->nel; i++) {
		struct amd_disk *d = amd_find_disk(super,
					__le64_to_cpu(v->el[i].id.id));

		if (d && d->fd >= 0 &&
		    amd_label_spare(d->fd, d->device_id, 0) != 0)
			pr_err("%s: cannot write its label: the BIOS will take it for a global spare again\n",
			       amd_disk_name(d));
	}
}

struct amd_update_create {
	int type;
	int vol;		/* the number mdadm gave the volume's md array */
	unsigned int len;	/* of the LD records that follow */
	char rec[];
};

/* amd_mdmon_recorded of --create: volume @id is in the configuration */
static int amd_has_volume(struct amd_super *super, const void *id)
{
	return amd_ld_by_id(super, *(const __u64 *)id) != NULL;
}

/* ... of --kill-subarray: it is not */
static int amd_lacks_volume(struct amd_super *super, const void *id)
{
	return !amd_has_volume(super, id);
}

/*
 * --create while mdmon runs the container: mdmon records new volume @v -
 * or not, if a rebuild it began meanwhile took an extent of it, as onto a
 * global spare the volume is laid out on (amd_create_update) - and clears
 * its service area first.  Until then mdadm writes nothing to the members:
 * the extent may be that rebuild's target.  The update goes now, and the
 * configuration on the disks says how it went (amd_mdmon_recorded).  Then
 * Create has no update left to send.
 */
static int amd_create_by_mdmon(struct supertype *st, struct amd_vol *v)
{
	struct amd_super *super = st->sb;
	unsigned int len = amd_ld_size(v->ld);
	struct amd_update_create *u;
	__u64 id = __le64_to_cpu(v->ld->id.id);
	int rv;

	if (v->link)
		len += amd_ld_size(v->link);
	u = xmalloc(sizeof(*u) + len);
	u->type = AMD_UPDATE_CREATE;
	u->vol = super->new_vol;
	u->len = len;
	memcpy(u->rec, v->ld, len);
	append_metadata_update(st, u, sizeof(*u) + len);
	rv = amd_mdmon_recorded(st, amd_has_volume, &id);
	if (rv > 0)
		pr_err("mdmon did not record the new volume: the configuration changed meanwhile, or md is rebuilding another volume onto its disks (see dmesg)\n");
	return rv != 0;
}

/*
 * Has a configuration been written since @super was read?  The commit block
 * of each disk tells.  Create reads the container before it takes the map
 * lock and the exclusive open that keep other writers out: a volume laid out
 * on what was read may lie on the extent, and under the number, of one
 * another mdadm --create has recorded meanwhile - writing it would drop that
 * volume from the configuration while its md array runs.
 */
static int amd_config_changed(struct amd_super *super)
{
	struct amd_commit *c = amd_alloc(AMD_SECTOR);
	struct amd_disk *d;
	int changed = !c;

	for (d = super->disks; d && !changed; d = d->next) {
		if (d->fd < 0 || !d->commit_valid ||
		    amd_read(d->fd, AMD_COMMIT_LBA, c, AMD_SECTOR) != 0 ||
		    !amd_check_commit(c))
			continue;
		changed = __le64_to_cpu(c->generation) != d->generation ||
			  __le64_to_cpu(c->committed_checksum) !=
			  d->committed_checksum;
	}
	free(c);
	return changed;
}

/*
 * The new volume @vol did not go into the configuration: stop the md array
 * Create has set up for it.  Create stops it only when a disk fails to go
 * in (add_disk_to_super); after a failed write_init_super it would leave it
 * inactive, under the subarray number of a volume that is not there - or is
 * that of another mdadm --create that won.  The array has no disks yet
 * (they go in after write_init_super), and the map has it under the
 * volume's UUID: Create put it there, under the map lock it still holds.
 */
static void amd_stop_new_array(struct amd_super *super, int vol)
{
	struct map_ent *map = NULL, *me;
	int uuid[4], fd;

	amd_volume_uuid(super, vol, uuid);
	me = map_by_uuid(&map, uuid);
	if (me) {
		fd = open_dev(me->devnm);
		if (is_fd_valid(fd) && !md_array_active(fd))
			ioctl(fd, STOP_ARRAY, NULL);
		close_fd(&fd);
	}
	map_free(map);
}

/*
 * Create maps the new container right after init_super, before any disk:
 * with no DeviceID yet its UUID is that of container_id 0.  Now that the
 * lowest one is known, put the real UUID in the map (as -A would).
 */
static void amd_create_map(struct amd_super *super)
{
	struct map_ent *map = NULL, *me;
	int was[4], uuid[4];

	amd_uuid("container", AMD_SERIAL, 0, was);
	amd_uuid("container", AMD_SERIAL, super->container_id, uuid);
	map_read(&map);
	for (me = map; me; me = me->next)
		if (strcmp(me->metadata, "amd") == 0 &&
		    memcmp(me->uuid, was, sizeof(was)) == 0) {
			amd_map_set_uuid(&map, me, uuid);
			break;
		}
	map_free(map);
}

static int write_init_super_amd(struct supertype *st)
{
	struct amd_super *super = st->sb;
	struct amd_disk *d;
	int rv = 0;

	if (!super)
		return 1;
	/* after add_to_super took a disk of this configuration in */
	if (super->attached) {
		super->attached = 0;
		return 0;
	}
	if (super->creating == AMD_CREATE_CONTAINER) {
		char *other = amd_other_raidcore_disk(super);

		if (other) {
			pr_err("%s is an AMD RAID disk already: all of them share one configuration\n",
			       other);
			cont_err("add disks to that container, or --zero-superblock %s first\n",
				 other);
			return 1;
		}
		for (d = super->disks; d; d = d->next)
			if (amd_init_disk(d, 0, 0) != 0) {
				pr_err("%s: cannot initialize the disk\n",
				       amd_disk_name(d));
				return 1;
			}
		if (amd_write_config(super) != 0) {
			pr_err("cannot write the AMD RAID configuration\n");
			return 1;
		}
		amd_create_map(super);
		super->creating = 0;
		super->cur_disk = NULL;
		/* Create opened them exclusively: md must be able to claim them */
		for (d = super->disks; d; d = d->next)
			if (d->fd >= 0) {
				close(d->fd);
				d->fd = -1;
			}
		return 0;
	}
	if (super->new_vol >= 0) {
		struct amd_vol *v = &super->vol[super->new_vol];

		/* mdmon does the same in its packet (amd_create_update) */
		amd_take_spares(super, v);
		if (st->update_tail) {
			rv = amd_create_by_mdmon(st, v);
		} else if (amd_config_changed(super)) {
			pr_err("the AMD RAID configuration changed since it was read (another mdadm?): nothing written, try again\n");
			rv = 1;
		} else if (amd_zero_service(super, v->ld) != 0) {
			pr_err("cannot clear the service area of the new volume\n");
			rv = 1;
		} else {
			/* a Legacy record the BIOS broke goes out fixed */
			amd_repair_legacy(super, 1);
			if (amd_write_config(super) != 0) {
				pr_err("cannot write the AMD RAID configuration\n");
				rv = 1;
			}
		}
		if (rv != 0)
			amd_stop_new_array(super, super->new_vol);
		/*
		 * The volume is in the configuration: what follows does not
		 * undo it - a volume left without its md array would be.
		 */
		if (rv == 0)
			amd_label_members(super, v);
		/*
		 * All bits set: md initializes it all (none: --assume-clean).
		 * Without it set_bitmap still tries, at the default chunk.
		 */
		if (rv == 0 && super->new_mdbm &&
		    amd_mdbm_init(super, v, super->new_mdbm,
				  super->new_mdbm_clean ? 0 : 0xff) != 0)
			pr_err("cannot write the md bitmap of the new volume\n");
		super->new_mdbm = 0;
		super->new_vol = -1;
		super->add_slot = -1;
		super->npick = 0;
		super->current_vol = -1;
		return rv;
	}
	pr_err("writing AMD metadata is supported only for --create and --add\n");
	return 1;
}

/*
 * --zero-superblock: wipe the label, the commit block and the config
 * ring, so that the AMD BIOS sees a new disk.  LBA 0 is wiped too, but
 * only if it still holds the MBR that AMD wrote (its checksum is in the
 * label); anything else there belongs to someone else.
 */
static int amd_erase(int fd)
{
	struct amd_metadata *md = amd_alloc(AMD_SECTOR);
	void *sector = amd_alloc(AMD_SECTOR);
	size_t zlen = (AMD_RING_END - AMD_COMMIT_LBA) * AMD_SECTOR;
	void *zero = amd_alloc(zlen);
	int wipe_mbr = 0, rv = 1;

	if (!md || !sector || !zero)
		goto out;
	if (test_partition(fd))
		goto out;
	if (amd_read(fd, AMD_METADATA_LBA, md, AMD_SECTOR) != 0 ||
	    !amd_label_valid(md)) {
		pr_err("no valid RAIDCore label found, not erasing\n");
		goto out;
	}
	if (md->mbr_checksum && amd_read(fd, 0, sector, AMD_SECTOR) == 0 &&
	    amd_checksum(sector, AMD_SECTOR) == __le64_to_cpu(md->mbr_checksum))
		wipe_mbr = 1;

	/*
	 * The commit block and the ring first: a label left without them is
	 * a disk initialized, with no configuration.  The MBR after the label.
	 */
	if (pwrite(fd, zero, zlen, (off_t)AMD_COMMIT_LBA * AMD_SECTOR) !=
	    (ssize_t)zlen ||
	    pwrite(fd, zero, AMD_SECTOR, (off_t)AMD_METADATA_LBA * AMD_SECTOR) !=
	    AMD_SECTOR)
		goto out;
	if (wipe_mbr && pwrite(fd, zero, AMD_SECTOR, 0) != AMD_SECTOR)
		goto out;
	if (fsync(fd) != 0)
		goto out;
	rv = 0;
out:
	free(md);
	free(sector);
	free(zero);
	return rv;
}

static int store_super_amd(struct supertype *st, int fd)
{
	/* Kill() frees the loaded metadata before asking us to store it */
	if (st->sb == NULL)
		return amd_erase(fd);
	pr_err("storing AMD metadata on a single disk is not supported (volumes take --update-subarray)\n");
	return 1;
}

/*
 * mdmon.  Managed volumes (RAID1/RAID10 with an AMD bitmap, see
 * amd_classify) keep their state the way the AMD driver does:
 *  - dirty/clean in the write-intent bitmap on element [0][0]: the whole
 *    volume is marked while md has it dirty, so that the AMD driver checks
 *    it after a crash under Linux (and we resync after a crash under it);
 *  - a failed member as element flags 0x10, a missing one as 0x30, and the
 *    volume CRITICAL, in a new config packet;
 *  - the initialization (CREATE_REDUNDANCY) of a volume made in the BIOS:
 *    md resyncs it, and when that is done a new config packet has the
 *    transform completed (amd_finish_init);
 *  - a rebuild onto an AMD global spare (SpareInfo 0x100) for a member out
 *    of service: md recovers it, and when that is done a new config packet
 *    has the spare in the slot (amd_activate_spare, amd_finish_rebuild).
 * Other volumes are not taken.
 */
static struct amd_vol *amd_active_vol(struct active_array *a)
{
	struct amd_super *super = a->container->sb;
	int inst = a->info.container_member;

	if (inst < 0 || inst >= super->nvol || !super->vol[inst].managed)
		return NULL;
	return &super->vol[inst];
}

/*
 * A message that must not get lost: once mdmon runs, its stderr is
 * /dev/null (manage_fork_fds), so the message goes to the kernel log too.
 * The "amd: " prefix tells it from the messages of other metadata there.
 */
static void amd_kmsg(const char *fmt, ...)
{
	char msg[256], line[300];
	va_list ap;
	int fd, n;

	va_start(ap, fmt);
	vsnprintf(msg, sizeof(msg), fmt, ap);
	va_end(ap);
	pr_err("amd: %s\n", msg);
	fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
	if (fd < 0)
		return;
	n = snprintf(line, sizeof(line), "<5>%s: amd: %s\n", Name, msg);
	if (write(fd, line, n) != n)
		dprintf("/dev/kmsg: %s\n", strerror(errno));
	close(fd);
}

/*
 * Does the disk read zeroes where it was trimmed?  SATA: ATA IDENTIFY
 * word 169 bit 0 (TRIM), word 69 bits 14 and 5 (deterministic, zeroes);
 * NVMe: DLFEAT 001b of its namespace.  Anything else, or no answer: no.
 */
static int amd_trim_zeroes(int fd)
{
	__u16 id[256];
	unsigned char ns[4096];
	int nsid;

	nsid = ioctl(fd, NVME_IOCTL_ID);
	if (nsid > 0) {
		if (nvme_identify_ioctl(fd, nsid, NVME_IDENTIFY_NAMESPACE_DATA,
					ns, sizeof(ns), 0) !=
		    MDADM_STATUS_SUCCESS)
			return 0;
		return (ns[33] & 7) == 1;
	}
	if (amd_ata_identify(fd, id) != 0)
		return 0;
	return (__le16_to_cpu(id[169]) & 1) &&
	       (__le16_to_cpu(id[69]) & 0x4020) == 0x4020;
}

/*
 * Does the disk of @dev read zeroes where it was trimmed?  Opened anew:
 * managemon asks it without the lock, while the monitor may close the
 * container's descriptors.  Gone meanwhile: not a member to ask.
 */
static int amd_dev_trim_zeroes(const struct mdinfo *dev)
{
	int fd = amd_dev_open(dev->disk.major, dev->disk.minor, O_RDONLY);
	int rv;

	if (!is_fd_valid(fd))
		return 1;
	rv = amd_trim_zeroes(fd);
	close(fd);
	return rv;
}

/*
 * Why the AMD driver would not TRIM redundant volume @a with the members
 * md runs and @spare it is to take (or NULL) - or NULL: it would.  The
 * disks are asked anew (amd_dev_trim_zeroes), a failed member is not.
 */
static const char *amd_trim_veto(struct active_array *a,
				 const struct mdinfo *spare)
{
	struct mdinfo *dev;

	if (a->info.array.level == 5)
		return "a parity volume";
	if (spare && !amd_dev_trim_zeroes(spare))
		return "the new member does not read zeroes after TRIM";
	for (dev = a->info.devs; dev; dev = dev->next)
		if (is_fd_valid(dev->state_fd) &&
		    !(dev->curr_state & DS_FAULTY) && !amd_dev_trim_zeroes(dev))
			return "a member does not read zeroes after TRIM";
	return NULL;
}

/* queue/@attr of volume @a: a limit in bytes, 0 if it cannot be read */
static unsigned long long amd_queue_limit(struct active_array *a,
					  const char *attr)
{
	char path[PATH_MAX], buf[32];

	snprintf(path, sizeof(path), "/sys/block/%s/queue/%s",
		 a->info.sys_name, attr);
	if (load_sys(path, buf, sizeof(buf)) != 0)
		return 0;
	return strtoull(buf, NULL, 10);
}

static int amd_set_trim(struct active_array *a, unsigned long long bytes)
{
	char path[PATH_MAX], buf[32];
	int fd, rv;

	snprintf(path, sizeof(path), "/sys/block/%s/queue/discard_max_bytes",
		 a->info.sys_name);
	fd = open(path, O_WRONLY);
	if (fd < 0)
		return -1;
	snprintf(buf, sizeof(buf), "%llu", bytes);
	rv = write_attr(buf, fd) == MDADM_STATUS_SUCCESS ? 0 : -1;
	close(fd);
	return rv;
}

/*
 * The discard_granularity of @a's volume as mdmon capped TRIM, 0 if it did
 * not (amd_limit_trim): set it to @gran, the old one back.
 */
static unsigned int amd_swap_trim_gran(struct active_array *a,
				       unsigned int gran)
{
	struct amd_super *super = a->container->sb;
	unsigned int old = 0;
	struct amd_vol *v;

	amd_lock(super);
	v = amd_active_vol(a);
	if (v) {
		old = v->mon.trim_gran;
		v->mon.trim_gran = gran;
	}
	amd_unlock(super);
	return old;
}

/*
 * TRIM the way the AMD driver allows it (rcblob RC_IsTrimAllowed,
 * RC_CheckLogicalDeviceTrimable): never on RAID5/6 - stale parity over a
 * trimmed block would rebuild garbage into live data - and on mirrors
 * only if every member reads zeroes after it, or the mirrors differ where
 * they were trimmed and the AMD driver's check finds that.  md would pass
 * it down: cap the volume's discard_max_bytes at 0 instead, and lift the
 * cap once the members allow TRIM again - the AMD driver asks for every
 * request.
 *
 * Decided at open_new with the members md runs, and again whenever
 * managemon looks for a spare (amd_mm_activate_spare): with each disk it
 * takes to rebuild or grow onto, before md adds it - a RAIDABLE grown
 * into a mirror keeps TRIM only if its own disk reads zeroes too - and
 * after a failure, the failed member no longer asked.  A degraded mirror
 * keeps TRIM if the members it has read zeroes: a disk rebuilt from them
 * gets zeroes there too, and one going on from a checkpoint starts over if
 * md trimmed meanwhile (amd_md_writes).  The AMD driver trims no degraded
 * mirror - it counts the disks it has (RC_DeterministicTrimZeroCount) -
 * but a cap may stay for good: with discard_max_bytes 0 the kernel makes
 * discard_granularity 0 too and then takes no other value (6.17 on,
 * 6.12.42 on: blk_validate_limits, queue_max_discard_sectors_store) until
 * md starts the volume anew.  The cap is lifted to what the kernel takes
 * back: a multiple of the granularity as it was (read before the cap: it
 * says 0 while TRIM is off), at most UINT_MAX (queue_var_store) - not
 * discard_max_hw_bytes itself, 0xfffffe00 with a granularity of 4 KiB.
 * Only a cap of this mdmon's, not one set by hand.
 *
 * The disks are asked with ATA IDENTIFY or NVMe Identify, seconds each
 * when a disk is slow to answer, and writing the limit freezes the
 * volume's queue, which waits for its writes - they may wait for the
 * monitor (blk-sysfs queue_attr_store): managemon, with the lock released.
 */
static void amd_limit_trim(struct active_array *a, const struct mdinfo *spare)
{
	int level = a->info.array.level;
	unsigned long long hw, gran;
	const char *why;

	if ((level != 1 && level != 10 && level != 5) ||
	    a->info.array.raid_disks < 2)
		return;		/* one copy: a RAIDABLE */
	hw = amd_queue_limit(a, "discard_max_hw_bytes");
	if (!hw)
		return;		/* no TRIM down there anyway */
	if (amd_queue_limit(a, "discard_max_bytes")) {
		why = amd_trim_veto(a, spare);
		if (!why)
			return;
		gran = amd_queue_limit(a, "discard_granularity");
		if (amd_set_trim(a, 0) != 0) {
			amd_kmsg("cannot turn TRIM off on %s (%s)",
				 a->info.sys_name, why);
			return;
		}
		amd_swap_trim_gran(a, gran);
		amd_kmsg("TRIM off on %s as the AMD driver does: %s",
			 a->info.sys_name, why);
		return;
	}
	gran = amd_swap_trim_gran(a, 0);
	if (!gran)
		return;		/* not capped by us */
	if (amd_trim_veto(a, spare)) {
		amd_swap_trim_gran(a, gran);
		return;
	}
	hw = min(hw, (unsigned long long)UINT_MAX);
	if (amd_set_trim(a, hw - hw % gran) == 0)
		amd_kmsg("TRIM on again on %s: every member reads zeroes after it",
			 a->info.sys_name);
	else
		amd_kmsg("TRIM stays off on %s until it is started again: the kernel does not take it back",
			 a->info.sys_name);
}

/*
 * Sectors written or trimmed on the array, from its block device's stat
 * (fields 7 and 14, the discards since 4.18), or 0: what changes on the
 * volume, not md's own resync or recovery.  The monitor asks too
 * (amd_target_missed): no stdio, which allocates.
 */
static unsigned long long amd_md_writes(struct active_array *a)
{
	unsigned long long n[14] = { 0 };
	char path[64], buf[512], *p = buf;
	int i;

	snprintf(path, sizeof(path), "/sys/block/%s/stat", a->info.sys_name);
	if (load_sys(path, buf, sizeof(buf)) != 0)
		return 0;
	for (i = 0; i < 14 && *p; i++)
		n[i] = strtoull(p, &p, 10);
	return n[6] + n[13];
}

/*
 * Where md writes the bits of array @a: bitmap/location, sectors from the
 * start of each member (rdev->sb_start + offset, 0 for external metadata)
 * - or 0: no bitmap, or one in a file; -1: cannot tell.
 */
static long long amd_md_bitmap_at(struct active_array *a)
{
	char buf[SYSFS_MAX_BUF_SIZE];

	/* a kernel without the attribute runs no bitmap of ours either */
	if (sysfs_get_str(&a->info, NULL, "consistency_policy", buf,
			  sizeof(buf)) <= 0 || strncmp(buf, "bitmap\n", 7) != 0)
		return 0;
	if (sysfs_get_str(&a->info, NULL, "bitmap/location", buf,
			  sizeof(buf)) <= 0)
		return -1;
	if (buf[0] != '+' && buf[0] != '-')
		return 0;
	return strtoll(buf, NULL, 10);
}

/* @at is where md keeps the bits of @v's md bitmap (amd_mdbm_lba) */
static int amd_mdbm_ours(const struct amd_vol *v, long long at)
{
	return amd_mdbm_lba(v) &&
	       at == (long long)(amd_mdbm_lba(v) + AMD_MDBM_HEADER);
}

/*
 * md runs @v with its md bitmap (set_bitmap): sectors a bit, or 0 - md
 * without one (a kernel that cannot, or none on disk) keeps no bits.
 */
static unsigned int amd_mdbm_running(struct active_array *a,
				     const struct amd_vol *v)
{
	unsigned long long chunk;

	if (!amd_mdbm_ours(v, amd_md_bitmap_at(a)) ||
	    sysfs_get_ll(&a->info, NULL, "bitmap/chunksize", &chunk) != 0)
		return 0;
	return chunk / AMD_SECTOR;
}

/*
 * The target of the transform recorded for @v (amd_rebuild_slot) is not in
 * md: the volume was started without its disk (-I waits for it, -R and
 * mdadm-last-resort do not).  The next assembly goes on from its log
 * (amd_resume_point), as the AMD driver would, unless md writes meanwhile
 * (amd_target_missed); should the disk come before that, it is copied
 * from 0 (amd_activate_spare).
 */
static int amd_target_away(struct active_array *a, struct amd_vol *v)
{
	int slot = amd_rebuild_slot(v);
	struct mdinfo *dev;

	if (slot < 0)
		return 0;
	for (dev = a->info.devs; dev; dev = dev->next)
		if (dev->disk.raid_disk == slot)
			return 0;
	return 1;
}

static int amd_open_new(struct supertype *c, struct active_array *a, int inst)
{
	struct amd_super *super = c->sb;
	unsigned int first;
	struct amd_vol *v;
	struct mdinfo *d;
	int slot;

	if (inst < 0 || inst >= super->nvol)
		return -ENODEV;
	v = &super->vol[inst];
	if (!v->managed) {
		dprintf("not managing array %d\n", inst);
		return -1;
	}
	/* unreadable counts as dirty: then we never try to write it */
	first = 0;
	v->mon.bitmap_dirty = amd_bitmap_read(super, v, &first) != 0;
	v->mon.bitmap_want = v->mon.bitmap_dirty;
	v->mon.bitmap_dirty_from = v->mon.bitmap_from = first;
	v->mon.resync_ckpt = 0;
	v->mon.ckpt_seen = a->last_checkpoint;
	/*
	 * Here already, not only as the array leaves readonly (amd_set_array_state):
	 * an mdmon that takes a running array over never sees that.
	 */
	v->mon.target_away = amd_target_away(a, v);
	v->mon.members_checked = 0;
	v->mon.trim_gran = 0;	/* md starts it with the kernel's limits */
	v->mon.md_writes = amd_md_writes(a);
	/* its headers say this session's AMD state from the first pass on */
	v->mon.md_bitmap = amd_mdbm_running(a, v);
	v->mon.mdbm_gen = 0;
	v->mon.mdbm_drop = 0;
	v->mon.mdbm_wipe = 0;
	a->info.container_member = inst;

	/* a recorded rebuild that container_content handed to md goes on */
	v->mon.rebuilding = 0;
	slot = amd_rebuild_slot(v);
	for (d = a->info.devs; slot >= 0 && d; d = d->next) {
		if (d->disk.raid_disk != slot)
			continue;
		v->mon.rebuilding = 1;
		v->mon.rebuild_slot = slot;
		v->mon.rebuild_done = 0;
		v->mon.rebuild_el = amd_link_elements(v)[slot];
		v->mon.rebuild_el.flags = 0;
		v->mon.rebuild_recorded = 1;
		/*
		 * The log on disk has where md resumed from; it is rewritten
		 * once md checkpoints further (amd_set_array_state).
		 */
		v->mon.rebuild_ckpt = 0;
		v->mon.tlog_dirty = 0;
		dprintf("array %d rebuilds member %d\n", inst, slot);
	}
	return 0;
}

static void amd_mark_missing(struct active_array *a, struct amd_vol *v);

/*
 * Back to the start packet of the transform recorded for @v: nothing of it
 * done - undo what the "100 %" packet set (amd_grow_copied; for a
 * RESTORE_SEGMENTS, the ring of an X399 RAID10).
 */
static void amd_transform_rewind(struct amd_super *super, struct amd_vol *v)
{
	struct amd_ld *ld = v->ld, *t = v->link;

	ld->transform_percent = 0;
	t->transform_percent = 0;
	ld->transform_protect_start = 0;
	t->transform_protect_start = 0;
	ld->transform_protect_size = __cpu_to_le32(amd_protect_size(v));
	ld->flags = (ld->flags & ~__cpu_to_le32(AMD_LDF_TRANSFORM)) |
		    __cpu_to_le32(AMD_LDF_RESTORE_SRC);
	if (v->grow) {
		ld->transform_state = 0;
		t->transform_type = 0;
		t->transform_state = 0;
	} else {
		t->transform_protect_size = ld->transform_protect_size;
	}
	super->config_dirty = 1;
}

/* md has written to @v while the target was away: the target lacks those writes */
static int amd_target_missed(struct active_array *a, struct amd_vol *v)
{
	return v->mon.target_away && amd_md_writes(a) > v->mon.md_writes;
}

/*
 * The target of @v is copied from the start: it lacks writes md made
 * meanwhile (amd_target_missed), or md copies it from 0 anyway
 * (amd_activate_spare).  Its log goes back to 0, and a "100 %" packet back
 * to the start one - either would have us and the AMD driver take the
 * target for done (amd_resume_point, rcblob RC_RestartTask).  The log goes
 * back to 0 on the disks here only, and the AMD driver reads it through
 * the target LD, from its first element (RC_ReadLogicalDeviceTransformLog):
 * the target's own old copy when it rebuilds slot 0 - it would go on from
 * there, over what md wrote meanwhile (rcraid 9.3.3-00302).  So the
 * configuration is written too: a target away misses it, its PD goes
 * offline (amd_pd_states), and the AMD driver copies it from the start, as
 * we do (amd_target_disk).
 * amd_sync_metadata writes the log, then the packet.
 */
static void amd_target_behind(struct amd_super *super, struct amd_vol *v)
{
	v->mon.target_away = 0;
	v->mon.tlog_restart = 1;
	if (v->ld->transform_percent)
		amd_transform_rewind(super, v);
	super->config_dirty = 1;
}

/*
 * What md itself records as done, exact where a sync action was
 * interrupted (frozen, md -S, the shutdown): resync_start for an
 * initialization, the rebuilt member's recovery_start for a rebuild.  The
 * monitor's checkpoints move only every 1/16 of the array or so, and the
 * last, exact one comes when the action is no longer resync or recover.
 * Only forward: an array being stopped reads 0 (md_clean), or nothing.
 */
static void amd_note_md_progress(struct active_array *a, struct amd_vol *v)
{
	struct mdinfo *mdi;

	if (v->init_pending && !v->mon.init_done &&
	    a->info.resync_start != MaxSector) {
		unsigned long long cap = __le64_to_cpu(v->ld->capacity);
		unsigned long long done = amd_sync_to_volume(v,
						a->info.resync_start);

		if (done > v->mon.init_ckpt && done < cap) {
			v->mon.init_ckpt = done;
			v->mon.init_tlog = 1;	/* written by amd_sync_metadata */
		}
	}
	if (!v->mon.rebuilding || v->mon.rebuild_done)
		return;
	for (mdi = a->info.devs; mdi; mdi = mdi->next)
		if (mdi->disk.raid_disk == v->mon.rebuild_slot &&
		    mdi->recovery_start != MaxSector &&
		    mdi->recovery_start > v->mon.rebuild_ckpt &&
		    mdi->recovery_start < v->component_size) {
			v->mon.rebuild_ckpt = mdi->recovery_start;
			v->mon.tlog_dirty = 1;	/* written by amd_sync_metadata */
		}
}

/*
 * The monitor's checkpoints of md's sync actions, the furthest each has
 * reached: a resync after a crash, an initialization and a rebuild - and
 * the end of an initialization.
 */
static void amd_note_checkpoints(struct active_array *a, struct amd_vol *v)
{
	unsigned long long ckpt;
	int moved;

	/*
	 * The monitor keeps the last checkpoint of the previous sync action
	 * (a recovery's, in member sectors) until the next one passes it: a
	 * checkpoint counts only when it has moved since the last call.  The
	 * monitor moves it only where it writes a checkpoint, and that comes
	 * here - the first one of an action too, which may be the first call
	 * in that action (a recovery that waited for another, DELAYED).  When
	 * an action is complete it goes back to 0, which counts for nothing.
	 */
	moved = a->last_checkpoint != v->mon.ckpt_seen;
	v->mon.ckpt_seen = a->last_checkpoint;
	/* resync after a crash: the monitor's checkpoint, in volume sectors */
	ckpt = amd_sync_to_volume(v, a->last_checkpoint);
	if (!v->init_pending && a->curr_action == resync && moved &&
	    ckpt > v->mon.resync_ckpt && ckpt < __le64_to_cpu(v->ld->capacity))
		v->mon.resync_ckpt = ckpt;
	/*
	 * The initialization is done when md has ended its resync: resync_start
	 * "none" with the array running and its sync action idle - or recover
	 * (a recovery leaves resync_start as it is; md runs it before a resync
	 * it owes, which then follows): a degraded volume started --force is
	 * in sync for md from the start, the recovery of its missing member
	 * makes its stripes whole, and that rebuild is recorded once the
	 * initialization has ended (amd_sync_metadata).  Not while the array stops
	 * (array_state inactive/clear, sync_action frozen or gone): what
	 * resync_start then reads is no proof, and a completion recorded
	 * wrongly leaves the rest of the volume unsynced for good (one stopped
	 * at ~15% was recorded COMPLETED so).  An end missed so is only late:
	 * the next assembly resyncs from the log.
	 */
	if (v->init_pending && !v->mon.init_done && is_resync_complete(&a->info) &&
	    a->curr_state > inactive && a->curr_state != bad_word &&
	    (a->curr_action == idle || a->curr_action == recover)) {
		v->mon.init_done = 1;	/* recorded by amd_sync_metadata */
		dprintf("array %d initialized\n", a->info.container_member);
	}
	/* initialization progress, volume sectors: the monitor's checkpoint */
	if (v->init_pending && !v->mon.init_done && a->curr_action == resync &&
	    moved && ckpt > v->mon.init_ckpt &&
	    ckpt < __le64_to_cpu(v->ld->capacity)) {
		v->mon.init_ckpt = ckpt;
		v->mon.init_tlog = 1;	/* written by amd_sync_metadata */
	}
	/* recovery progress: the monitor's checkpoint is in member sectors */
	if (v->mon.rebuilding && !v->mon.rebuild_done && a->curr_action == recover &&
	    moved && a->last_checkpoint > v->mon.rebuild_ckpt &&
	    a->last_checkpoint < v->component_size) {
		v->mon.rebuild_ckpt = a->last_checkpoint;
		v->mon.tlog_dirty = 1;	/* written by amd_sync_metadata */
	}
}

static int amd_set_array_state(struct active_array *a, int consistent)
{
	struct amd_vol *v = amd_active_vol(a);

	if (!v)
		return consistent;
	if (consistent == 2) {
		/* before md may write: written by amd_sync_metadata first */
		amd_mark_missing(a, v);
		v->mon.members_checked = 1;
		consistent = is_resync_complete(&a->info);
		/* degraded: active, so that md rebuilds onto what it gets (as IMSM) */
		if (amd_volume_state(a->container->sb, v) != AMD_LD_STATE_NORMAL)
			consistent = 0;
		/* a rebuild handed to md at assembly needs the array active */
		if (v->mon.rebuilding && !v->mon.rebuild_done)
			consistent = 0;
		v->mon.target_away = amd_target_away(a, v);
	} else if (!consistent && v->mon.target_away) {
		/*
		 * md is to write (write_pending; md waits for us): before it
		 * does.  A degraded volume comes this way too: md has it clean
		 * until its first write.  Only an array taken over active
		 * (mdmon --takeover) writes unseen: amd_sync_progress sees
		 * that later.
		 */
		amd_target_behind(a->container->sb, v);
	}
	/*
	 * An initialization not done yet is in the LD and its progress in the
	 * transform log: it leaves the bitmap to tell a crash from a clean stop.
	 */
	v->mon.bitmap_want = !consistent ||
			 (!is_resync_complete(&a->info) && !v->init_pending);
	amd_note_checkpoints(a, v);
	amd_note_md_progress(a, v);
	/* clean, resyncing after a crash: dirty past what md has resynced */
	v->mon.bitmap_from = 0;
	if (v->mon.bitmap_want && consistent && !v->init_pending) {
		unsigned long long done = v->mon.resync_ckpt;
		unsigned long long cover = amd_bitmap_cover(v);

		if (a->info.resync_start != MaxSector &&
		    amd_sync_to_volume(v, a->info.resync_start) > done)
			done = amd_sync_to_volume(v, a->info.resync_start);
		if (cover)
			v->mon.bitmap_from = done / cover;
	}
	dprintf("array %d %s\n", a->info.container_member,
		v->mon.bitmap_want ? "dirty" : "clean");
	if (v->mon.bitmap_want && v->mon.bitmap_from)
		dprintf("array %d bitmap from bit %u\n",
			a->info.container_member, v->mon.bitmap_from);
	return consistent;
}

/*
 * Element @n of @v out of service, as the AMD driver records it: @mark
 * (AMD_ELEMENT_FAILED or AMD_ELEMENT_OFFLINE) in the LD and its second
 * copy, CRITICAL.  0 if it was so already.
 */
static int amd_fail_element(struct amd_super *super, struct amd_vol *v, int n,
			    __u32 mark)
{
	struct amd_element *el = &v->el[n];
	__u32 flags = __le32_to_cpu(el->flags);

	if (flags & AMD_ELEMENT_FAILED)
		return 0;
	el->flags = __cpu_to_le32(flags | mark);
	/* the same element in the second copy, or [0][0] of a RAIDABLE's RAID1 */
	if (v->link && (v->grow || amd_link_same_shape(v))) {
		el = &amd_link_elements(v)[n];
		el->flags |= __cpu_to_le32(mark);
		v->link->state = __cpu_to_le32(amd_volume_state(super, v));
	}
	v->ld->state = __cpu_to_le32(amd_volume_state(super, v));
	super->config_dirty = 1;
	return 1;
}

static void amd_set_disk(struct active_array *a, int n, int state)
{
	struct amd_super *super = a->container->sb;
	struct amd_vol *v = amd_active_vol(a);
	struct amd_disk *d;

	if (!v || n < 0)
		return;
	/* the spare md recovers onto is not in the config yet */
	if (v->mon.rebuilding && n == v->mon.rebuild_slot) {
		if (state & DS_FAULTY) {
			d = amd_find_disk(super, __le64_to_cpu(v->mon.rebuild_el.id.id));
			if (d)
				d->spare_failed = 1;
			v->mon.rebuilding = 0;
			if (amd_rebuild_slot(v) == n) {
				/*
				 * RESTORE_SEGMENTS, or the migration of a
				 * RAIDABLE, is in the packet: end it.  The
				 * migration goes as the AMD driver drops one
				 * the user cancels (rcblob RC_RemoveTransform-
				 * UpdateDriver): the RAIDABLE as it was.  (On a
				 * failed target it stops and goes on after a
				 * reboot instead - onto the same disk.)
				 */
				v->mon.rebuild_recorded = 0;
				v->mon.tlog_dirty = 2;
				amd_ld_clear_transform(v->ld);
				amd_end_transform(super, a->info.container_member,
						  __le32_to_cpu(v->ld->transform_type),
						  AMD_TRANSFORM_FAILED);
			}
			dprintf("array %d rebuild of member %d failed\n",
				a->info.container_member, n);
		} else if ((state & DS_INSYNC) && !v->mon.rebuild_done) {
			v->mon.rebuild_done = 1;	/* recorded by amd_sync_metadata */
			dprintf("array %d member %d rebuilt\n",
				a->info.container_member, n);
		}
		return;
	}
	/* past the elements: the mirror a RAIDABLE grows by, not recorded */
	if (n >= v->nel || !(state & DS_FAULTY))
		return;
	d = amd_find_disk(super, __le64_to_cpu(v->el[n].id.id));
	if (d)
		d->spare_failed = 1;	/* not rebuilt onto while here (mdmon) */
	if (amd_fail_element(super, v, n, AMD_ELEMENT_FAILED))
		dprintf("array %d member %d failed\n",
			a->info.container_member, n);
}

/*
 * The volume is about to be used with members missing (started degraded:
 * mdadm -R, or mdadm-last-resort at boot) or stale (left out at assembly):
 * record them as failed before md writes anything, or the copies would
 * look in step when the disk is back.  As IMSM's handle_missing().  The
 * AMD driver does the same in two steps: a member without its disk gets
 * 0x20 when the volume is validated (rcblob RC_ValidateLogicalElement
 * @0012f1e0, "logical element offline"), 0x20 becomes 0x30 on the first
 * write (RC_UpdateDriveErrors @0012f080).  So 0x30, not the 0x10 of a
 * failure: when the disk is back it is rebuilt in place (amd_find_spare).
 */
static void amd_mark_missing(struct active_array *a, struct amd_vol *v)
{
	struct amd_super *super = a->container->sb;
	struct mdinfo *dev;
	int i;

	for (i = 0; i < v->nel; i++) {
		if (!amd_slot_usable(v, i))
			continue;
		/* in sync in md; a spare md may already rebuild onto does not count */
		for (dev = a->info.devs; dev; dev = dev->next)
			if (dev->disk.raid_disk == i && (dev->curr_state & DS_INSYNC))
				break;
		if (dev)
			continue;
		if (amd_fail_element(super, v, i, AMD_ELEMENT_OFFLINE))
			amd_kmsg("subarray-%d: member %d (disk %016llx) is missing, recorded as offline",
				 a->info.container_member, i,
				 (unsigned long long)__le64_to_cpu(v->el[i].id.id));
	}
}

/*
 * Every RAID disk a mirror or a RAID5 has in service is in the container
 * and up to date (members md has failed aside; a rebuild target that missed
 * some gets the next one: amd_write_config).  A configuration written
 * without one makes it stale, and the AMD driver then drops it from its
 * volumes - so writes that can wait, wait for this.  Not for a disk no
 * volume needs (a free disk, a spare, a member out of service) nor for a
 * member of volumes without redundancy only, which is taken with an older
 * configuration too (amd_volume_disk): it gets the live configuration
 * when it is back (amd_disk_idle), and one gone for good
 * would hold these writes back for good - the end of an initialization
 * never recorded, every assembly resyncing its tail again.
 */
static int amd_all_disks_here(struct amd_super *super)
{
	int i;

	for (i = 0; i < super->npd; i++) {
		__u64 id = __le64_to_cpu(super->pd[i]->id.id);
		struct amd_disk *d;

		if (__le32_to_cpu(super->pd[i]->device_type) !=
		    AMD_DEV_RAIDCORE_DISK || amd_disk_failed(super, id) ||
		    !amd_disk_guarded(super, NULL, id))
			continue;
		d = amd_find_disk(super, id);
		/*
		 * Failed, taken out of the container, or stale already: the
		 * configuration it failed to take is on the other disks.
		 */
		if (d && (d->spare_failed || d->removed || d->write_failed))
			continue;
		/*
		 * Gone, and a configuration written since says so (its PD
		 * OFFLINE, amd_pd_states): its label is stale already, and
		 * waiting for it would hold these writes back for good - the
		 * end of an initialization never recorded, every assembly
		 * initializing again (08.11, a disk pulled for good).
		 */
		if ((!d || d->fd < 0) &&
		    __le32_to_cpu(super->pd[i]->device_state) == AMD_DEV_STATE_OFFLINE)
			continue;
		if (!d || d->fd < 0 ||
		    (!amd_disk_current(super, d) && !amd_rebuild_target(super, id)))
			return 0;
	}
	return 1;
}

/*
 * Index the LD records again after the packet changed shape, keeping
 * mdmon's state of each volume.  Volume numbers do not change: of the two
 * copies of an LD only one is ever dropped - the second, or the first when
 * a migration has made the second the volume (amd_end_transform).
 */
static void amd_reparse(struct amd_super *super)
{
	amd_reparse_without(super, -1);
}

/* amd_reparse() after volume @gone left the packet: the later ones move down a place */
static void amd_reparse_without(struct amd_super *super, int gone)
{
	/*
	 * Not on the stack: the monitor runs on a small one (mdmon.c asks
	 * for 4 KiB, which musl grants).  One user at a time: mdadm, or the
	 * monitor under amd_lock - managemon never changes the packet.
	 */
	static struct amd_vol_mon keep[AMD_MAX_VOL];
	int i, j, n = super->nvol;

	for (i = 0; i < n; i++)
		keep[i] = super->vol[i].mon;
	amd_parse_packet(super);
	for (i = 0; i < super->nvol; i++) {
		j = gone >= 0 && i >= gone ? i + 1 : i;
		if (j >= n)
			break;
		super->vol[i].mon = keep[j];
	}
}

/* The transform fields of @ld a transform clears as it ends. */
static void amd_ld_clear_transform(struct amd_ld *ld)
{
	ld->transform_protect_size = 0;
	ld->transform_flags = 0;
	ld->flags &= ~__cpu_to_le32(AMD_LDF_TRANSFORM);
}

/*
 * End a transform the way the AMD driver does (seen in the ring of an X399
 * RAID10 for RESTORE_SEGMENTS and CHECK_BITMAP_REDUNDANCY, and after a
 * migration by rcraid 9.3.3): one copy of the LD is dropped from the
 * packet - the second, or, of a migration that has completed, the first:
 * the volume is the LD it made (rcblob RC_TransformUpdateDriver).  The one
 * kept has TransformType 0, LastOperation = the transform and
 * TransformState @tstate.
 */
static void amd_end_transform(struct amd_super *super, int vol, __u32 op,
			      __u32 tstate)
{
	struct amd_vol *v = &super->vol[vol];
	int made = v->grow && tstate == AMD_TRANSFORM_COMPLETED;
	struct amd_ld *ld = made ? v->link : v->ld;
	struct amd_ld *gone = made ? v->ld : v->link;

	super->config_dirty = 1;
	ld->transform_type = 0;
	ld->last_operation = __cpu_to_le32(op);
	ld->transform_state = __cpu_to_le32(tstate);
	ld->transform_protect_start = 0;
	ld->transform_percent = 0;
	ld->transform_link = 0;

	if (gone)
		amd_cut_ld(super, (char *)gone - (char *)super->packet,
			   amd_ld_size(gone));
	amd_trim_packet(super);
	amd_reparse(super);
}

/*
 * Delete volume @vol as the AMD driver does (rcblob RC_DeleteLogicalDevice
 * @0013f230: the volume's transform log cleared, its LD records - and the
 * second copy of a transform - gone; the data is left on the disks).  The
 * later volumes move down a place.  Written by sync_metadata.
 */
static void amd_remove_volume(struct amd_super *super, int vol)
{
	struct amd_vol *v = &super->vol[vol];
	unsigned int at = (char *)v->ld - (char *)super->packet;
	unsigned int size = amd_ld_size(v->ld), lat = 0, lsize = 0;

	/* only where there is a service area in front of the data */
	if (__le64_to_cpu(v->el[0].user_data.offset) >
	    __le64_to_cpu(v->el[0].allocated.offset) &&
	    amd_tlog_write(super, v, v->ld, 1, 0, 0) != 0)
		dprintf("volume %d: transform log not cleared\n", vol);
	if (v->link) {
		lat = (char *)v->link - (char *)super->packet;
		lsize = amd_ld_size(v->link);
	}
	/* the later record first: the offset of the other stays good */
	if (v->link && lat > at)
		amd_cut_ld(super, lat, lsize);
	amd_cut_ld(super, at, size);
	if (v->link && lat < at)
		amd_cut_ld(super, lat, lsize);
	amd_trim_packet(super);
	amd_reparse_without(super, vol);
	super->config_dirty = 1;
}

/*
 * mdadm without mdmon writes the configuration it has changed, here: after
 * kill_subarray and update_subarray the callers leave it to sync_metadata,
 * which cannot tell them that the write failed ("these routines do not
 * report success/failure", Kill.c) - they would report the change as made.
 */
static int amd_write_changed(struct amd_super *super)
{
	if (amd_write_config(super) != 0) {
		pr_err("cannot write the AMD RAID configuration\n");
		return 2;
	}
	super->config_dirty = 0;
	return 0;
}

/*
 * mdadm --kill-subarray: the volume is stopped (Kill_subarray checks).  As
 * IMSM, not when a later volume runs: it would be renumbered under md.  A
 * Legacy LD (a disk with data) is no subarray (amd_parse_packet).
 */
static int kill_subarray_amd(struct supertype *st, char *subarray_id)
{
	struct amd_super *super = st->sb;
	struct amd_update_disk *u;
	unsigned long vol;
	char *ep, sub[16];
	int i, rv;

	vol = strtoul(subarray_id, &ep, 10);
	if (!super || !super->packet || *ep || ep == subarray_id ||
	    vol >= (unsigned long)super->nvol)
		return 2;
	for (i = vol + 1; i < super->nvol; i++) {
		snprintf(sub, sizeof(sub), "%d", i);
		if (is_subarray_active(sub, st->devnm)) {
			pr_err("deleting subarray-%lu would renumber active subarray-%d, aborting\n",
			       vol, i);
			return 2;
		}
	}
	if (st->update_tail) {
		__u64 id = __le64_to_cpu(super->vol[vol].ld->id.id);

		u = xcalloc(1, sizeof(*u));
		u->type = AMD_UPDATE_KILL;
		u->major = vol;
		u->id = id;
		append_metadata_update(st, u, sizeof(*u));
		/* sent here: Kill_subarray would not know how it went */
		rv = amd_mdmon_recorded(st, amd_lacks_volume, &id);
		if (rv > 0)
			pr_err("mdmon did not delete subarray-%lu (see dmesg)\n",
			       vol);
		return rv != 0;
	}
	/* no mdmon: this process writes it */
	super->legacy_checked = 1;
	amd_remove_volume(super, vol);
	amd_repair_legacy(super, 1);	/* as -C does: see amd_repair_legacy */
	return amd_write_changed(super);
}

/*
 * KILL (monitor): the volume mdadm --kill-subarray named, if not running.
 * mdadm has checked both already; a refusal here (a volume started or the
 * packet changed in between) goes to the log, and mdadm finds the volume
 * still on the disks (amd_mdmon_recorded).
 */
static void amd_kill_volume(struct supertype *st, const struct amd_update_disk *u)
{
	struct amd_super *super = st->sb;
	struct active_array *a;

	if (u->major < 0 || u->major >= super->nvol ||
	    __le64_to_cpu(super->vol[u->major].ld->id.id) != u->id) {
		amd_kmsg("cannot delete subarray-%d: the volume changed meanwhile",
			 u->major);
		return;
	}
	for (a = st->arrays; a; a = a->next)
		if (a->info.container_member >= u->major) {
			amd_kmsg("cannot delete subarray-%d: subarray-%d is running",
				 u->major, a->info.container_member);
			return;
		}
	amd_remove_volume(super, u->major);
	dprintf("volume %d deleted\n", u->major);
}

/* the volume number of member array @devnm (its metadata_version: "/md127/1"), or -1 */
static int amd_devnm_volume(struct amd_super *super, char *devnm)
{
	struct mdinfo *sra = sysfs_read(-1, devnm, GET_VERSION);
	char *sub = sra ? strchr(sra->text_version + 1, '/') : NULL;
	char *ep = NULL;
	long vol = sub ? strtol(sub + 1, &ep, 10) : -1;

	if (!ep || *ep || vol < 0 || vol >= super->nvol)
		vol = -1;
	sysfs_free(sra);
	return vol;
}

/*
 * The volume md rebuilds onto disk @d that the configuration does not have
 * the disk in yet, or -1.  managemon gives md a spare before the monitor
 * records the rebuild (amd_start_rebuild: in that pass, or once the log of
 * a transform that ended is cleared), and until then only mdmon knows the
 * extent (amd_extent_overlap): a new volume must not take that disk.
 * Every md array that runs a disk holds it.
 */
static int amd_rebuilt_into(struct amd_super *super, const struct amd_disk *d)
{
	struct dirent *de;
	char path[64];
	int vol = -1;
	DIR *dir;

	snprintf(path, sizeof(path), "/sys/dev/block/%d:%d/holders",
		 d->major, d->minor);
	dir = opendir(path);
	while (dir && vol < 0 && (de = readdir(dir)) != NULL) {
		int n = de->d_name[0] == '.' ? -1 :
			amd_devnm_volume(super, de->d_name);

		if (n >= 0 && !amd_vol_has_disk(&super->vol[n], d->device_id))
			vol = n;
	}
	if (dir)
		closedir(dir);
	return vol;
}

/*
 * mdadm --grow <RAIDABLE volume> --raid-devices=2: the migration the AMD
 * driver makes of a RAIDABLE, into a RAID1 with a second disk (rcadm -T -r1).
 * md raid1 needs no restriping for it: Grow.c only gives the array a
 * second slot.  mdmon then takes a spare for that slot as for a rebuild
 * (amd_activate_spare: a dedicated, then a global spare) and records the
 * migration as the AMD driver does (amd_start_rebuild); the GROW update has
 * it look at once.  The spare is looked for here as well, so that the user
 * hears before anything changes.
 * --raid-devices=1 takes the second slot back after a migration that failed.
 * Nothing else reshapes: then Grow.c would also add to md every device
 * container_content offers a slot, the target of a recorded rebuild too.
 */
static int reshape_super_amd(struct supertype *st, struct shape *shape,
			     struct context *c)
{
	struct amd_super *super = st->sb;
	struct amd_update_disk *u;
	struct amd_element el;
	struct amd_disk *d;
	struct amd_vol *v;
	int vol, recorded;

	vol = amd_devnm_volume(st->sb, st->devnm);
	if (vol < 0) {
		pr_err("%s: AMD metadata does not reshape a container: only a RAIDABLE volume of it can be grown, into a RAID1\n",
		       shape->dev);
		return 1;
	}
	v = &super->vol[vol];
	if (shape->size || (shape->level != UnSet && shape->level != 1) ||
	    shape->layout != UnSet || shape->chunk ||
	    (shape->delta_disks != 1 && shape->delta_disks != -1)) {
		pr_err("%s: AMD metadata only grows a RAIDABLE volume into a RAID1: --raid-devices=2\n",
		       shape->dev);
		return 1;
	}
	if (v->grow) {
		pr_err("%s: its migration to RAID1 is in progress\n", shape->dev);
		return 1;
	}
	if (!v->single) {
		pr_err("%s is not an AMD RAIDABLE volume\n", shape->dev);
		return 1;
	}
	if (!v->managed) {
		pr_err("%s: the RAIDABLE volume is not in normal state: it cannot be grown now\n",
		       shape->dev);
		return 1;
	}
	/* md's second slot, left by a migration that failed: the metadata has none */
	if (shape->delta_disks == -1) {
		if (shape->raiddisks == 2)
			return 0;
		pr_err("%s: a RAIDABLE volume has one disk\n", shape->dev);
		return 1;
	}
	if (!st->update_tail) {
		pr_err("%s: mdmon does not run for /dev/%s\n", shape->dev,
		       st->container_devnm);
		return 1;
	}
	d = amd_find_spare(super, v, v->nel, &el, &recorded);
	if (!d) {
		pr_err("%s: no AMD spare for the mirror - add a disk to the container first (mdadm /dev/%s --add <disk>)\n",
		       shape->dev, st->container_devnm);
		return 1;
	}
	u = xcalloc(1, sizeof(*u));
	u->type = AMD_UPDATE_GROW;
	u->major = vol;
	u->id = __le64_to_cpu(v->ld->id.id);
	append_metadata_update(st, u, sizeof(*u));
	if (c->verbose >= 0)
		pr_err("%s: mdmon will mirror it onto %s (RAIDABLE -> RAID1)\n",
		       shape->dev, d->devname ? d->devname : "a spare");
	return 0;
}

/*
 * Grow.c needs manage_reshape whenever reshape_super is set, although
 * mdadm.h marks it optional.  reshape_super_amd accepts no change that md
 * has to restripe, so this is never reached.
 */
static int manage_reshape_amd(int afd, struct mdinfo *sra,
			      struct reshape *reshape, struct supertype *st,
			      unsigned long blocks, int *fds,
			      unsigned long long *offsets, int dests,
			      int *destfd, unsigned long long *destoffsets)
{
	pr_err("restriping an AMD RAID volume is not supported\n");
	return 0;
}

/*
 * GROW (monitor): mdadm gives md raid1 of a RAIDABLE a second slot; the
 * manager is to look for a spare once it has (amd_activate_spare).
 */
static void amd_grow_update(struct supertype *st,
			    const struct amd_update_disk *u)
{
	struct amd_super *super = st->sb;
	struct active_array *a;

	if (u->major < 0 || u->major >= super->nvol ||
	    __le64_to_cpu(super->vol[u->major].ld->id.id) != u->id)
		return;
	for (a = st->arrays; a; a = a->next)
		if (a->info.container_member == u->major)
			a->check_degraded = 1;
}

/*
 * mdadm --update-subarray: the AMD driver's cache policy of a volume (LD
 * Cache: read-ahead, write back - what the menu and RAIDXpert2 set, used by
 * the Windows driver; md has no such cache) or its name (DevicePrivate).
 */
struct amd_update_subarray {
	int type;
	int vol;
	__u64 id;
	__u32 cache_set, cache_clear;
	int rename;
	char name[32];
};

static int amd_apply_subarray(struct amd_super *super,
			      const struct amd_update_subarray *u)
{
	struct amd_ld *ld[2];
	int i;

	if (u->vol < 0 || u->vol >= super->nvol ||
	    __le64_to_cpu(super->vol[u->vol].ld->id.id) != u->id)
		return 1;
	ld[0] = super->vol[u->vol].ld;
	ld[1] = super->vol[u->vol].link;	/* the copy a transform keeps */
	for (i = 0; i < 2; i++) {
		if (!ld[i])
			continue;
		ld[i]->cache = __cpu_to_le32((__le32_to_cpu(ld[i]->cache) &
					      ~u->cache_clear) | u->cache_set);
		if (u->rename) {
			memset(ld[i]->name, 0, sizeof(ld[i]->name));
			memcpy(ld[i]->name, u->name, sizeof(ld[i]->name) - 1);
		}
	}
	super->config_dirty = 1;
	return 0;
}

/* amd_mdmon_recorded of --update-subarray: the volume is as @u makes it */
static int amd_subarray_recorded(struct amd_super *super, const void *arg)
{
	const struct amd_update_subarray *u = arg;
	const struct amd_vol *v = amd_vol_by_id(super, u->id);
	__u32 cache;

	if (!v)
		return 0;
	cache = __le32_to_cpu(v->ld->cache);
	return (cache & u->cache_set) == u->cache_set &&
	       !(cache & u->cache_clear) &&
	       (!u->rename ||
		memcmp(v->ld->name, u->name, sizeof(v->ld->name)) == 0);
}

/*
 * --update=bitmap / no-bitmap of stopped volume @vol (Update_subarray
 * refuses a running one): a new md bitmap with every bit set - the next
 * assembly resyncs it all if, and only if, the AMD bitmap says the volume
 * is dirty - or none, its header cleared.  On disk only, in the service
 * area mdmon leaves alone for a volume not running: no config.  Every
 * member must be here: a header left on one would bring the bitmap back.
 */
static int amd_update_mdbm(struct amd_super *super, int vol, int on)
{
	struct amd_vol *v = &super->vol[vol];
	struct amd_disk *disks[AMD_MAX_PD];
	const char *why = NULL;
	int i, n, in = 0, rv;

	if (v->level != 1 && v->level != 10 && v->level != 5)
		why = "only AMD RAID1, RAID10 and RAID5 can";
	else if (!v->managed)
		why = "mdmon does not manage it";
	else if (!amd_mdbm_lba(v))
		why = "its members do not start at one LBA, or have no room for it in front of their data";
	else if (on && !amd_mdbm_chunk(v, 0))
		why = "it is too large";
	if (why) {
		pr_err("subarray-%d can have no md bitmap: %s\n", vol, why);
		return 2;
	}
	for (i = 0; i < v->nel; i++)
		in += amd_slot_usable(v, i);
	n = amd_mdbm_disks(super, v, 0, disks, NULL);
	if (n != in) {
		pr_err("subarray-%d: %d of its %d members are here, all must be\n",
		       vol, n, in);
		return 2;
	}
	if (on)
		rv = amd_mdbm_init(super, v, amd_mdbm_chunk(v, 0), 0xff);
	else
		rv = amd_mdbm_clear(super, v);
	if (rv != 0) {
		pr_err("subarray-%d: cannot write its md bitmap\n", vol);
		return 2;
	}
	super->legacy_checked = 1;	/* nothing else to write */
	return 0;
}

static int update_subarray_amd(struct supertype *st, char *subarray,
			       enum update_opt update, struct mddev_ident *ident)
{
	struct amd_super *super = st->sb;
	struct amd_update_subarray u;
	unsigned long vol;
	char *ep;

	vol = strtoul(subarray, &ep, 10);
	if (!super || !super->packet || *ep || ep == subarray ||
	    vol >= (unsigned long)super->nvol)
		return 2;
	memset(&u, 0, sizeof(u));
	u.type = AMD_UPDATE_SUBARRAY;
	u.vol = vol;
	u.id = __le64_to_cpu(super->vol[vol].ld->id.id);
	switch (update) {
	case UOPT_READ_CACHE:
		u.cache_set = AMD_CACHE_READ;
		break;
	case UOPT_NO_READ_CACHE:
		u.cache_clear = AMD_CACHE_READ;
		break;
	case UOPT_WRITE_BACK:
		u.cache_set = AMD_CACHE_WRITE_BACK;
		break;
	case UOPT_NO_WRITE_BACK:
		u.cache_clear = AMD_CACHE_WRITE_BACK;
		break;
	case UOPT_NAME:
		if (!ident || !amd_name_ok(super, ident->name, vol))
			return 2;
		u.rename = 1;
		memcpy(u.name, ident->name, strlen(ident->name) + 1);
		break;
	case UOPT_BITMAP:
	case UOPT_NO_BITMAP:
		return amd_update_mdbm(super, vol, update == UOPT_BITMAP);
	default:
		pr_err("--update=%s is not supported for an AMD RAID volume\n",
		       map_num_s(update_options, update));
		return 2;
	}
	if (st->update_tail) {
		struct amd_update_subarray *m = xmalloc(sizeof(*m));
		int rv;

		*m = u;
		append_metadata_update(st, m, sizeof(*m));
		/* sent here: Update_subarray would not know how it went */
		rv = amd_mdmon_recorded(st, amd_subarray_recorded, &u);
		if (rv > 0)
			pr_err("mdmon did not update subarray-%lu (see dmesg)\n",
			       vol);
		return rv != 0 ? 2 : 0;
	}
	/* no mdmon: this process writes it */
	super->legacy_checked = 1;
	if (amd_apply_subarray(super, &u))
		return 2;
	amd_repair_legacy(super, 1);	/* as -C does: see amd_repair_legacy */
	return amd_write_changed(super);
}

/* Cut @size bytes at offset @at out of the LD section of the packet. */
static void amd_cut_ld(struct amd_super *super, unsigned int at,
		       unsigned int size)
{
	struct amd_packet_header *h = super->packet;
	char *p = super->packet;

	memmove(p + at, p + at + size, super->packet_len - at - size);
	memset(p + super->packet_len - size, 0, size);
	h->ld_size = __cpu_to_le32(__le32_to_cpu(h->ld_size) - size);
	amd_move_sections(h, at, -(int)size);
}

/* the packet is the sections rounded up to whole sectors */
static void amd_trim_packet(struct amd_super *super)
{
	struct amd_packet_header *h = super->packet;
	unsigned int end;

	end = ROUND_UP(amd_sections_end(h), AMD_SECTOR);
	if (end && end <= super->packet_len) {
		super->packet_len = end;
		h->packet_size = __cpu_to_le32(end);
	}
}

/* Record a finished initialization (CREATE_REDUNDANCY). */
static void amd_finish_init(struct amd_super *super, int vol)
{
	struct amd_ld *ld = super->vol[vol].ld;

	if (ld->state == 0)
		ld->state = __cpu_to_le32(AMD_LD_STATE_NORMAL);
	super->vol[vol].mon.init_tlog = 2;	/* cleared once the end is written */
	amd_end_transform(super, vol, AMD_TRANSFORM_CREATE_REDUNDANCY,
			  AMD_TRANSFORM_COMPLETED);
}

/*
 * The "100 %" packet of a RAIDABLE -> RAID1 migration md has copied (rcraid
 * 9.3.3; rcblob RC_TransformLogicalDevice): the RAIDABLE COMPLETED at the
 * RAID1's Capacity, 100000 per cent, Flags 0x84; the RAID1 runs the
 * migration, STARTED, as far.  The AMD driver ends it from either without
 * I/O.  Then the log is cleared and amd_end_grow writes the final packet
 * (amd_sync_metadata).
 */
static void amd_grow_copied(struct amd_vol *v)
{
	struct amd_ld *ld = v->ld, *t = v->link;

	ld->transform_state = __cpu_to_le32(AMD_TRANSFORM_COMPLETED);
	ld->transform_protect_start = t->capacity;
	ld->transform_protect_size = 0;
	ld->transform_percent = __cpu_to_le32(AMD_PERCENT_DONE);
	ld->flags = __cpu_to_le32(AMD_LDF_TRANSFORM_DONE);
	t->transform_type = ld->transform_type;
	t->transform_state = __cpu_to_le32(AMD_TRANSFORM_STARTED);
	t->transform_protect_start = t->capacity;
	t->transform_percent = ld->transform_percent;
}

/*
 * The final packet of a RAIDABLE -> RAID1 migration (rcraid 9.3.3), its log
 * cleared: the RAID1 alone, its generation as it was made, State as its
 * members are.
 */
static void amd_end_grow(struct amd_super *super, int vol)
{
	struct amd_vol *v = &super->vol[vol];

	amd_ld_clear_transform(v->link);
	amd_end_transform(super, vol, AMD_TRANSFORM_NORMAL,
			  AMD_TRANSFORM_COMPLETED);
	v->ld->state = __cpu_to_le32(amd_volume_state(super, v));
}

/*
 * Record a finished rebuild the way the AMD driver ends RESTORE_SEGMENTS
 * (the ring of an X399 RAID10): the spare's element takes the slot with
 * flags 0, the volume is NORMAL again unless another member is still out,
 * LastOperation RESTORE_SEGMENTS, TransformState COMPLETED.  The spare
 * keeps SpareInfo 0x100: the AMD driver clears it only when the user
 * unassigns the spare (rcblob RC_DeassignPhysicalDeviceGlobalSpare,
 * rcraid.sys FUN_1400652d0).
 * An initialization still pending stays so, with the new member in both
 * copies of the LD.  The mirror of a RAIDABLE ends in three packets
 * (amd_grow_copied): it can only once its start is recorded.
 */
static void amd_finish_rebuild(struct amd_super *super, int vol)
{
	struct amd_vol *v = &super->vol[vol];
	struct amd_ld *ld;
	struct amd_disk *d;
	__u32 state;

	if (amd_rebuild_grows(v) && !v->link)
		return;
	/* a dedicated spare whose start was not recorded leaves the list now */
	amd_drop_dedicated(super, vol, __le64_to_cpu(v->mon.rebuild_el.id.id));
	ld = v->ld;
	/* a former member rebuilt in place may be stale yet: written from now on */
	d = amd_find_disk(super, __le64_to_cpu(v->mon.rebuild_el.id.id));
	if (d)
		d->rejoin = 1;
	v->mon.rebuilding = 0;
	v->mon.rebuild_done = 0;
	if (amd_rebuild_grows(v)) {
		struct amd_element *tel = &amd_link_elements(v)[v->mon.rebuild_slot];

		/* onto another spare than recorded, if that one was missing */
		if (memcmp(tel, &v->mon.rebuild_el, sizeof(*tel)) != 0) {
			*tel = v->mon.rebuild_el;
			super->config_dirty = 1;
		}
		/* the "100 %" packet, unless it is the live one (a restart) */
		if (__le32_to_cpu(ld->transform_percent) != AMD_PERCENT_DONE) {
			amd_grow_copied(v);
			super->config_dirty = 1;
		}
		v->mon.rebuild_recorded = 0;
		v->mon.tlog_dirty = 2;
		return;
	}
	super->config_dirty = 1;
	v->el[v->mon.rebuild_slot] = v->mon.rebuild_el;
	if (v->link && amd_same_geometry(ld, v->link))
		amd_link_elements(v)[v->mon.rebuild_slot] = v->mon.rebuild_el;
	state = __cpu_to_le32(amd_volume_state(super, v));
	ld->state = state;
	/* the bitmap of element [0][0] is on the new member now: write it */
	if (v->mon.rebuild_slot == 0)
		v->mon.bitmap_dirty = -1;

	if (__le32_to_cpu(ld->transform_type) == AMD_TRANSFORM_CREATE_REDUNDANCY) {
		if (v->link)
			v->link->state = state;
		return;
	}
	/* a RESTORE_SEGMENTS in the packet has a transform log to clear */
	if (__le32_to_cpu(ld->transform_type) == AMD_TRANSFORM_RESTORE_SEGMENTS)
		v->mon.tlog_dirty = 2;
	v->mon.rebuild_recorded = 0;
	amd_ld_clear_transform(ld);
	amd_end_transform(super, vol, AMD_TRANSFORM_RESTORE_SEGMENTS,
			  AMD_TRANSFORM_COMPLETED);
}

/* Insert @size bytes of LD record @rec into the LD section, at offset @at. */
static int amd_insert_ld(struct amd_super *super, unsigned int at,
			 const void *rec, unsigned int size)
{
	struct amd_packet_header *h = amd_packet_insert(super, at, rec, size);

	if (!h)
		return -1;
	h->ld_size = __cpu_to_le32(__le32_to_cpu(h->ld_size) + size);
	amd_reparse(super);
	return 0;
}

/* the place of disk @id in the dedicated spares of LD @ld, or -1 */
static int amd_dedicated_index(const struct amd_ld *ld, __u64 id)
{
	const struct amd_dev_id *sp = amd_ld_spares(ld);
	int i;

	for (i = 0; i < (int)__le32_to_cpu(ld->spare_count); i++)
		if (__le64_to_cpu(sp[i].id) == id)
			return i;
	return -1;
}

/*
 * Take disk @id out of the dedicated spares of volume @vol: its entry
 * leaves the first LD copy, SpareCount and the record size go down (as
 * the menu unassigns one).  1 if it was one.
 */
static int amd_drop_dedicated(struct amd_super *super, int vol, __u64 id)
{
	struct amd_ld *ld = super->vol[vol].ld;
	struct amd_dev_id *sp = amd_ld_spares(ld);
	unsigned int n = __le32_to_cpu(ld->spare_count);
	int i = amd_dedicated_index(ld, id);

	if (i < 0)
		return 0;
	ld->spare_count = __cpu_to_le32(n - 1);
	ld->packet_size = __cpu_to_le32(__le32_to_cpu(ld->packet_size) -
					sizeof(*sp));
	amd_cut_ld(super, (char *)&sp[i] - (char *)super->packet, sizeof(*sp));
	amd_trim_packet(super);
	amd_reparse(super);
	super->config_dirty = 1;
	return 1;
}

/*
 * The LD a rebuild of @v goes into, *@size bytes: a copy of its LD without
 * the dedicated spares (as the menu writes the second copy), the spare in
 * the slot, failed members marked 0x8000 too (the ring of an X399
 * RAID10).  The RAID1 a RAIDABLE grows into is RAID10N 1 x 2 - its element
 * [0][0] and the new mirror - with a write-intent bitmap and the generation
 * of the packet it starts in (rcblob RC_CreateTransformRaidArray; rcraid
 * 9.3.3).
 * Made in ldbuf, as large as managemon has made it (amd_mm_activate_spare):
 * NULL if it does not fit.
 */
static struct amd_ld *amd_rebuild_ld(struct amd_super *super,
				     struct amd_vol *v, unsigned int *size)
{
	struct amd_ld *ld = v->ld, *t;
	int grow = amd_rebuild_grows(v);
	unsigned int els = sizeof(*ld) + sizeof(struct amd_element) * v->nel;
	unsigned int refs = sizeof(struct amd_dev_id) *
			    __le32_to_cpu(ld->parent_count);
	struct amd_element *tel;
	int i;

	*size = els + (grow ? sizeof(struct amd_element) : 0) + refs;
	if (*size > super->ldbuf_room)
		return NULL;
	t = super->ldbuf;
	memcpy(t, ld, els);
	memcpy((char *)t + *size - refs, (char *)ld + els, refs);
	t->spare_count = 0;
	t->packet_size = __cpu_to_le32(*size);
	tel = amd_ld_elements(t);
	tel[v->mon.rebuild_slot] = v->mon.rebuild_el;
	if (grow) {
		t->device_type = __cpu_to_le32(AMD_LDT_RAID10N);
		t->devices = __cpu_to_le32(2);
		t->second_count = __cpu_to_le32(2);
		t->attribute |= __cpu_to_le32(AMD_ATTR_BITMAP);
		t->state = __cpu_to_le32(AMD_LD_STATE_NORMAL);
		t->generation = __cpu_to_le64(super->generation);
		return t;
	}
	for (i = 0; i < v->nel; i++)
		if (i != v->mon.rebuild_slot &&
		    (__le32_to_cpu(tel[i].flags) & AMD_ELEMENT_FAILED))
			tel[i].flags |= __cpu_to_le32(AMD_ELEMENT_FAIL_COMMITTED);
	return t;
}

/*
 * Record the start of a rebuild the way the AMD driver does (the ring of
 * an X399 RAID10): the transform log (STARTED, nothing done yet) first,
 * then RESTORE_SEGMENTS in the LD and a second copy of it - the LD rebuilt
 * into, with the spare in the slot - in the next config packet.  Then a
 * reboot, into Linux or the AMD driver, goes on from the log instead of
 * starting over.  The mirror a RAIDABLE grows by is a migration to the AMD
 * driver, recorded the same way (rcblob RC_StartTransform; rcraid 9.3.3):
 * NORMAL in the RAIDABLE, TransformState 0, then the RAID1, which runs no
 * transform of its own.
 * Without the log first the AMD driver would not go on with it at all.
 * 1: not yet - another transform is pending (an initialization), or the
 * log of one that has ended is still to be cleared: it is in the same
 * sectors.  -1: cannot.
 */
static int amd_start_rebuild(struct amd_super *super, int vol)
{
	struct amd_vol *v = &super->vol[vol];
	struct amd_ld *ld = v->ld;
	unsigned int size = amd_ld_size(ld);
	unsigned int at = (char *)ld - (char *)super->packet + size;
	int grow = amd_rebuild_grows(v);
	__u32 op = __cpu_to_le32(grow ? AMD_TRANSFORM_NORMAL :
				 AMD_TRANSFORM_RESTORE_SEGMENTS);
	__u32 protect = __cpu_to_le32(amd_protect_size(v));
	struct amd_ld *t, saved;

	if (size == 0)
		return -1;
	if (v->link || ld->transform_type || v->mon.init_tlog == 2 ||
	    v->mon.tlog_dirty == 2)
		return 1;
	t = amd_rebuild_ld(super, v, &size);
	if (!t)
		return -1;
	t->last_operation = op;
	t->transform_flags = __cpu_to_le32(grow ? AMD_TFLAGS_GROW :
					   AMD_TFLAGS_RESTORE);
	t->transform_protect_start = 0;
	t->transform_percent = 0;
	t->transform_link = 0;
	if (grow) {
		t->transform_type = 0;
		t->transform_state = 0;
		t->transform_protect_size = 0;
		t->flags = 0;
	} else {
		t->transform_type = op;
		t->transform_protect_size = protect;
		t->flags |= __cpu_to_le32(AMD_LDF_RESTORE_DST);
	}
	if (amd_tlog_write(super, v, t, 0,
			   amd_member_to_volume(v, v->mon.rebuild_ckpt),
			   __le32_to_cpu(op)) != 0)
		return -1;

	saved = *ld;
	ld->transform_type = op;
	ld->last_operation = op;
	ld->transform_flags = t->transform_flags;
	ld->transform_protect_start = 0;
	ld->transform_protect_size = protect;
	/* nothing done yet: a per cent left over would say all (amd_resume_point) */
	ld->transform_percent = 0;
	ld->flags |= __cpu_to_le32(AMD_LDF_RESTORE_SRC);
	ld->transform_link = __cpu_to_le32(1);
	if (grow) {
		ld->transform_state = 0;
		/* State 0 of a RAIDABLE the BIOS has just created (amd_classify) */
		ld->state = t->state;
	}
	/*
	 * The packet only changes if the insertion succeeds - and the log
	 * written above goes then (REB-B7): it would lie in the elements'
	 * service sector until the next transform.
	 */
	if (amd_insert_ld(super, at, t, size) != 0) {
		*ld = saved;
		amd_tlog_write(super, v, t, 1, 0, 0);
		return -1;
	}
	/* a dedicated spare taken leaves the volume's list (RC_SetupTransform) */
	amd_drop_dedicated(super, vol, __le64_to_cpu(v->mon.rebuild_el.id.id));
	/* the RAID1's bitmap is cleared as it is created: write it as md has it */
	if (grow)
		v->mon.bitmap_dirty = -1;
	super->config_dirty = 1;
	return 0;
}

/* write the configuration if it has changed */
static void amd_flush_config(struct supertype *st)
{
	struct amd_super *super = st->sb;
	struct amd_disk *d;

	if (!super->config_dirty)
		return;
	if (amd_write_config(super) != 0) {
		amd_kmsg("cannot write the configuration");
		return;
	}
	super->config_dirty = 0;
	/* a disk mdadm --add initialized has its first one: a spare */
	for (d = super->disks; d; d = d->next)
		if (d->fresh && d->update) {
			struct active_array *a;

			d->fresh = 0;
			for (a = st->arrays; a; a = a->next)
				a->check_degraded = 1;
		}
}

/*
 * An idle disk (amd_disk_idle) with an older configuration, or another one
 * under the same generation (written on its own: a fork) - back in the
 * container, or so when mdmon started - gets the live one as it is, under
 * its generation: a new one would make stale the disks still on their way
 * (-I per disk) and their members out of date.  Only while the packet in
 * memory is the one committed; else the next configuration written
 * reaches the disk (amd_write_config).
 */
static void amd_catch_up(struct amd_super *super)
{
	struct amd_packet_header *h = super->packet;
	unsigned int nsec = (super->packet_len + AMD_SECTOR - 1) / AMD_SECTOR;
	struct amd_disk *d;

	if (!h || !super->iobuf || super->config_dirty)
		return;
	for (d = super->disks; d; d = d->next) {
		/* an older one, or another packet under this generation */
		if (!amd_disk_idle(super, d) || amd_disk_current(super, d))
			continue;
		if (amd_checksum((char *)h + 0x0c, super->packet_len - 0x0c) !=
		    __le64_to_cpu(h->checksum))
			return;
		if (amd_put_packet(d, h, nsec) == 0 &&
		    amd_put_commit(super, d, super->generation) == 0)
			amd_kmsg("disk %d:%d missed configurations: it has the live one again",
				 d->major, d->minor);
	}
}

/*
 * mdmon: a disk of the container whose LBA 0 holds AMD's own partition
 * (one, type 0x82 from 0x3F) but not the checksum its label has - boot
 * code or a disk signature written over it - gets that sector's checksum
 * in its label, as the AMD driver writes the label at Initialize
 * (rcraid.sys 9.3.3.218 RC_WriteRAIDCoreBootRecord @140024270).  LBA 0
 * stays as it is; without it the BIOS and the Windows driver would take
 * the disk for a non-RAID one (RC_ReadMBR).  Nothing else is repaired:
 * any other content of LBA 0 may belong to someone else (amd_mbr_advice).
 * Each disk is tried once.
 */
static void amd_repair_mbr(struct amd_super *super)
{
	struct amd_metadata label;
	struct amd_disk *d;
	__u8 *buf = super->iobuf;

	for (d = super->disks; d && buf; d = d->next) {
		__u64 sum;

		if (d->mbr != AMD_MBR_SUM || d->fd < 0 || d->removed ||
		    d->write_failed || d->spare_failed)
			continue;
		d->mbr = AMD_MBR_OK;
		if (amd_read(d->fd, AMD_METADATA_LBA, buf, AMD_SECTOR) != 0)
			continue;
		memcpy(&label, buf, sizeof(label));
		if (!amd_label_valid(&label) ||
		    __le64_to_cpu(label.device_id) != d->device_id ||
		    amd_read(d->fd, 0, buf, AMD_SECTOR) != 0 ||
		    amd_mbr_state(buf, &label) != AMD_MBR_SUM)
			continue;
		sum = amd_checksum(buf, AMD_SECTOR);
		label.mbr_checksum = __cpu_to_le64(sum);
		label.checksum = __cpu_to_le64(amd_sector_sum(&label));
		memcpy(buf, &label, sizeof(label));
		if (pwrite(d->fd, buf, AMD_SECTOR,
			   (off_t)AMD_METADATA_LBA * AMD_SECTOR) != AMD_SECTOR ||
		    fsync(d->fd) != 0) {
			amd_kmsg("disk %016llx: cannot write its label",
				 (unsigned long long)d->device_id);
			continue;
		}
		amd_kmsg("disk %016llx: LBA 0 changed under AMD's partition, the label has its checksum now",
			 (unsigned long long)d->device_id);
	}
}

/*
 * A recorded rebuild of a volume this mdmon found running (amd_open_new)
 * that md has finished already - as the other mdmon left, or with none
 * running: its target is in sync, and the monitor sees no recovery end
 * (set_disk).  Left so, the packet has the rebuild in progress until the
 * next assembly, and a failure of the source meanwhile would be recorded
 * as one of the only copy.
 */
static void amd_rebuild_ended_unseen(struct active_array *a, struct amd_vol *v)
{
	struct mdinfo *dev;

	if (!v->mon.rebuilding || v->mon.rebuild_done)
		return;
	for (dev = a->info.devs; dev; dev = dev->next)
		if (dev->disk.raid_disk == v->mon.rebuild_slot &&
		    (dev->curr_state & DS_INSYNC))
			v->mon.rebuild_done = 1;	/* recorded by amd_sync_metadata */
}

/* write the transform log of @vol at @done, or say it could not */
static int amd_sync_tlog(struct amd_super *super, int vol,
			 unsigned long long done, __u32 type)
{
	struct amd_vol *v = &super->vol[vol];

	if (amd_tlog_write(super, v, v->link, 0, done, type) == 0)
		return 0;
	amd_kmsg("cannot write the transform log of subarray-%d", vol);
	return -1;
}

/*
 * md's own progress records, of every array of the monitor.  An array the
 * monitor let go of (stopped, or clean on SIGTERM) stays on the list with
 * no container until the manager drops it.
 */
static void amd_sync_progress(struct supertype *st)
{
	struct amd_super *super = st->sb;
	struct active_array *a;

	for (a = st->arrays; a; a = a->next) {
		struct amd_vol *v;

		if (!a->container || a->to_remove)
			continue;
		v = amd_active_vol(a);
		if (!v)
			continue;
		/*
		 * A volume this mdmon found running (it took over from another
		 * mdmon, or was started anew) never is read-only for it, so
		 * set_array_state(2) did not look: a member md lost meanwhile -
		 * failed as the other mdmon left, its record written after this
		 * one read the configuration - is recorded now, once the monitor
		 * has read the array's state.  In service in the packet, it would
		 * be taken in sync at the next assembly.
		 */
		if (!v->mon.members_checked && a->curr_state > readonly &&
		    a->curr_state != bad_word) {
			amd_mark_missing(a, v);
			amd_rebuild_ended_unseen(a, v);
			v->mon.members_checked = 1;
		}
		amd_note_md_progress(a, v);
		if (amd_target_missed(a, v))
			amd_target_behind(super, v);
	}
}

/* The transform logs of the volumes, and the transforms md has finished */
static void amd_sync_transforms(struct amd_super *super)
{
	int vol;

	for (vol = 0; vol < super->nvol; vol++) {
		struct amd_vol *v = &super->vol[vol];
		__u32 type = __le32_to_cpu(v->ld->transform_type);

		/* the target of a recorded transform fell behind (amd_target_behind) */
		if (v->mon.tlog_restart &&
		    (!v->link || amd_sync_tlog(super, vol, 0, type) == 0))
			v->mon.tlog_restart = 0;
		/* rebuild or migration progress (RESTORE_SEGMENTS, NORMAL) */
		if (v->mon.rebuilding && v->mon.rebuild_recorded == 1 && v->mon.tlog_dirty == 1 &&
		    !v->mon.rebuild_done &&
		    amd_sync_tlog(super, vol, amd_member_to_volume(v, v->mon.rebuild_ckpt),
				  type) == 0)
			v->mon.tlog_dirty = 0;
		/* initialization progress, logged as the AMD driver does per region */
		if (v->init_pending && !v->mon.init_done && v->mon.init_tlog == 1 &&
		    v->link && amd_sync_tlog(super, vol, v->mon.init_ckpt,
					     AMD_TRANSFORM_CREATE_REDUNDANCY) == 0)
			v->mon.init_tlog = 0;
		if (v->mon.rebuilding && v->mon.rebuild_done && amd_all_disks_here(super))
			amd_finish_rebuild(super, vol);
		if (v->init_pending && v->mon.init_done && amd_all_disks_here(super))
			amd_finish_init(super, vol);
	}
}

/*
 * The transform has ended in the config: its log goes.  A migration's
 * "100 %" packet is written: its log goes from the RAID1's elements,
 * then the RAIDABLE (amd_end_grow).
 */
static void amd_sync_ended_logs(struct amd_super *super)
{
	int vol;

	for (vol = 0; vol < super->nvol && !super->config_dirty; vol++) {
		struct amd_vol *v = &super->vol[vol];

		if (v->mon.tlog_dirty == 2 &&
		    amd_tlog_write(super, v, v->grow ? v->link : v->ld, 1, 0, 0) == 0) {
			v->mon.tlog_dirty = 0;
			if (v->grow)
				amd_end_grow(super, vol);
		}
		if (v->mon.init_tlog == 2 && amd_tlog_write(super, v, v->ld, 1, 0, 0) == 0)
			v->mon.init_tlog = 0;
	}
}

/*
 * The start of a rebuild, after amd_sync_ended_logs: its log goes where
 * the log of a transform that has just ended was (an initialization md finished
 * by this very recovery, as with a degraded volume started --force).
 * A migration is recorded even if md has copied it all meanwhile: only
 * so can it end (amd_finish_rebuild) - at once, in another pass: the
 * monitor may sleep long, the array idle.  One that cannot be recorded
 * keeps its disk, which md mirrors onto: the metadata has the RAIDABLE.
 * Returns whether a pass more is needed for that.
 */
static int amd_sync_rebuilds(struct amd_super *super)
{
	int vol, again = 0;

	for (vol = 0; vol < super->nvol && !super->config_dirty; vol++) {
		struct amd_vol *v = &super->vol[vol];
		int rv;

		if (!v->mon.rebuilding || v->mon.rebuild_recorded ||
		    (v->mon.rebuild_done && !amd_rebuild_grows(v)) ||
		    !amd_all_disks_here(super))
			continue;
		rv = amd_start_rebuild(super, vol);
		if (rv == 0) {
			v->mon.rebuild_recorded = 1;
			again |= v->mon.rebuild_done;
		} else if (rv < 0) {
			v->mon.rebuild_recorded = -1;
			amd_kmsg("subarray-%d: cannot record its %s onto disk %016llx",
				 vol, amd_rebuild_grows(v) ? "migration to RAID1" : "rebuild",
				 (unsigned long long)__le64_to_cpu(v->mon.rebuild_el.id.id));
		}
	}
	return again;
}

/*
 * What the headers of @v's md bitmap are to say of its AMD bitmap: one
 * value for clean and dirty from the bit mdmon dirties it from, so that
 * they change as seldom as the configuration does (a write to an idle
 * volume would cost 1 + n writes with a flush each) - a crash leaves the
 * AMD bitmap either way.  Clean only (AMD_MDBM_AMD_CLEAN) once md stops
 * the array (@stops): the next session, if not ours (an mdadm without md
 * bitmaps), then shows as one when it leaves the AMD bitmap dirty.
 */
static __u32 amd_mdbm_state(const struct amd_vol *v, int stops)
{
	if (v->mon.bitmap_dirty == 1)
		return v->mon.bitmap_dirty_from;
	if (v->mon.bitmap_dirty != 0)
		return AMD_MDBM_AMD_UNKNOWN;	/* not read: no element [0][0] */
	if (stops)
		return AMD_MDBM_AMD_CLEAN;
	/* what they say now holds for clean too: keep it */
	if (v->mon.mdbm_gen && v->mon.mdbm_amd != AMD_MDBM_AMD_UNKNOWN)
		return v->mon.mdbm_amd;
	return v->mon.bitmap_dirty_from;
}

/*
 * The headers of @v's md bitmap after its AMD configuration or bitmap
 * changed: they say what mdmon wrote of them last (amd_mdbm_own) - after
 * it, so that a crash between the two only costs a larger resync.  Cleared
 * once md has stopped the bitmap (amd_mdbm_stop).
 */
static void amd_sync_mdbm(struct amd_super *super, struct amd_vol *v,
			  int stops)
{
	const struct amd_packet_header *p = super->packet;
	struct amd_mdbm *h = super->iobuf;
	__u32 amd;

	if (v->mon.mdbm_wipe && amd_mdbm_clear(super, v) == 0)
		v->mon.mdbm_wipe = 0;
	if (!v->mon.md_bitmap)
		return;
	amd = amd_mdbm_state(v, stops);
	if (v->mon.mdbm_gen == super->generation &&
	    v->mon.mdbm_sum == __le64_to_cpu(p->checksum) &&
	    v->mon.mdbm_amd == amd)
		return;
	amd_mdbm_header(super, v, v->mon.md_bitmap, amd, h);
	/* a member that failed to take it has its bits from md all the same */
	if (amd_mdbm_put(super, v, 0, h, NULL, 0) != 0)
		dprintf("subarray-%d: an md bitmap header not written\n",
			(int)(v - super->vol));
	v->mon.mdbm_gen = super->generation;
	v->mon.mdbm_sum = __le64_to_cpu(p->checksum);
	v->mon.mdbm_amd = amd;
}

/*
 * The md bitmap headers of the volumes md runs: not of one stopped - its
 * bitmap may have gone meanwhile (--update=no-bitmap clears the headers),
 * and a new assembly sets it up anew (set_bitmap, amd_open_new).  md stops
 * an array in the monitor's pass that hands it back (monitor.c
 * read_and_act: array_state inactive or clear, the array clean then).
 */
static void amd_sync_mdbms(struct supertype *st)
{
	struct active_array *a;

	for (a = st->arrays; a; a = a->next) {
		struct amd_vol *v;

		if (!a->container || a->to_remove)
			continue;
		v = amd_active_vol(a);
		if (v)
			amd_sync_mdbm(st->sb, v,
				      (a->curr_state <= inactive ||
				       a->curr_state == bad_word) &&
				      a->prev_state > inactive);
	}
}

/* The write-intent bitmaps of the managed volumes, as md has them */
static void amd_sync_bitmaps(struct amd_super *super)
{
	int vol;

	for (vol = 0; vol < super->nvol; vol++) {
		struct amd_vol *v = &super->vol[vol];

		if (!v->managed || (v->mon.bitmap_want == v->mon.bitmap_dirty &&
				    (!v->mon.bitmap_want ||
				     v->mon.bitmap_from == v->mon.bitmap_dirty_from)))
			continue;
		/*
		 * With no disk for element [0][0] there is no bitmap to write,
		 * and the AMD driver skips its I/O then too (rcblob
		 * RC_Raid10NLogicalToPhysical): no message, and it is written
		 * once a member holds [0][0] again.
		 */
		if (amd_bitmap_write(super, v, v->mon.bitmap_want, v->mon.bitmap_from) == 0) {
			v->mon.bitmap_dirty = v->mon.bitmap_want;
			v->mon.bitmap_dirty_from = v->mon.bitmap_from;
		} else if (amd_bitmap_disk(super, v)) {
			amd_kmsg("cannot write the bitmap of subarray-%d", vol);
		}
	}
}

/* The monitor calls us after every pass. */
static void amd_sync_metadata(struct supertype *st)
{
	struct amd_super *super = st->sb;
	int again;

	if (!super)
		return;
	amd_sync_progress(st);
	amd_sync_transforms(super);
	amd_repair_mbr(super);
	/* once, with the configuration going to every RAID disk */
	if (!super->legacy_checked && amd_all_disks_here(super)) {
		super->legacy_checked = 1;
		if (amd_repair_legacy(super, 1))
			super->config_dirty = 1;
		/*
		 * The AMD driver writes the configuration as it starts
		 * (rcraid.sys 9.3.3.218 RC_ConfigInit @140039e2c): one of
		 * another controller is its own from then on (amd_take_over).
		 */
		if (super->foreign)
			super->config_dirty = 1;
	}
	amd_flush_config(st);
	amd_sync_ended_logs(super);
	again = amd_sync_rebuilds(super);
	amd_flush_config(st);
	amd_catch_up(super);
	amd_sync_bitmaps(super);
	amd_sync_mdbms(st);
	if (again)
		amd_sync_metadata(st);
}

/* activate_spare -> process_update: md recovers @slot of @vol onto @el */
struct amd_update_spare {
	int type;
	int vol;
	int slot;
	int recorded;		/* a RESTORE_SEGMENTS in the packet goes on */
	__u32 features;		/* PD Features of the disk (amd_rebuild_pd) */
	struct amd_element el;
};

/* the size of an update of each type; AMD_UPDATE_CREATE: the least */
static const unsigned int amd_update_size[] = {
	[AMD_UPDATE_SPARE]	= sizeof(struct amd_update_spare),
	[AMD_UPDATE_CREATE]	= sizeof(struct amd_update_create),
	[AMD_UPDATE_REMOVE]	= sizeof(struct amd_update_disk),
	[AMD_UPDATE_ADD]	= sizeof(struct amd_update_disk),
	[AMD_UPDATE_ATTACH]	= sizeof(struct amd_update_attach),
	[AMD_UPDATE_KILL]	= sizeof(struct amd_update_disk),
	[AMD_UPDATE_SUBARRAY]	= sizeof(struct amd_update_subarray),
	[AMD_UPDATE_ROLE]	= sizeof(struct amd_update_role),
	[AMD_UPDATE_GROW]	= sizeof(struct amd_update_disk),
};

/*
 * The type of @update, or 0 if it is none or the update is not of its
 * size: the LD records of a new volume follow AMD_UPDATE_CREATE, the other
 * types are their structure exactly.
 */
static int amd_update_type(const struct metadata_update *update)
{
	int type;

	if (update->len < (int)sizeof(type))
		return 0;
	type = *(int *)update->buf;
	if (type <= 0 || type >= (int)ARRAY_SIZE(amd_update_size))
		return 0;
	if (type == AMD_UPDATE_CREATE ?
	    update->len < (int)amd_update_size[type] :
	    update->len != (int)amd_update_size[type])
		return 0;
	return type;
}

/*
 * The updates mdadm sends (--create, --add, --kill-subarray,
 * --update-subarray, spare roles, --grow); mdmon makes the others itself.
 */
static int amd_prepare_update(struct supertype *st,
			      struct metadata_update *update)
{
	if (!st->sb)
		return 0;
	switch (amd_update_type(update)) {
	case AMD_UPDATE_CREATE:
		/* the monitor allocates nothing (amd_mm_room): zeroes to clear with */
		update->space = amd_alloc(AMD_SERVICE_BYTES);
		break;
	case AMD_UPDATE_ADD:
		/* ... a record for a disk new to the container */
		update->space = xcalloc(1, sizeof(struct amd_disk));
		break;
	case AMD_UPDATE_KILL:
	case AMD_UPDATE_SUBARRAY:
	case AMD_UPDATE_ROLE:
	case AMD_UPDATE_GROW:
		break;
	default:
		return 0;
	}
	/* ... room in the packet for what it records */
	amd_mm_room(st->sb);
	return 1;
}

/*
 * Does new volume @ld (@len bytes of LD records) lie on an extent in use?
 * mdadm laid it out on the configuration it read, so a rebuild mdmon began
 * meanwhile onto a global spare may be in its way (amd_rebuilt_into looks
 * before); as IMSM, a volume that overlaps another is not recorded.
 */
static int amd_new_overlaps(struct amd_super *super, const struct amd_ld *ld,
			    unsigned int len)
{
	const struct amd_element *el = amd_ld_elements(ld);
	unsigned int i, n, size = len < sizeof(*ld) ? 0 : amd_ld_size(ld);
	unsigned long long end;

	if (size == 0 || size > len ||
	    __le32_to_cpu(ld->element_offset) != sizeof(*ld))
		return 1;
	n = __le32_to_cpu(ld->first_count) * __le32_to_cpu(ld->second_count);
	for (i = 0; i < n; i++)
		if (amd_extent_overlap(super, __le64_to_cpu(el[i].id.id),
				       __le64_to_cpu(el[i].allocated.offset),
				       __le64_to_cpu(el[i].allocated.size),
				       &end))
			return 1;
	return 0;
}

/*
 * mdadm --create: record the new volume, its LD records @c->rec, after its
 * service area is cleared with @zero (amd_create_by_mdmon); the global
 * spares it takes are spares no more.  managemon gives md no spare
 * meanwhile: it looks for one only with no update queued (managemon.c
 * manage_member).
 */
static void amd_create_update(struct supertype *st,
			      const struct amd_update_create *c,
			      unsigned int len, const void *zero)
{
	struct amd_super *super = st->sb;
	struct amd_packet_header *h = super->packet;
	const struct amd_ld *ld = (const struct amd_ld *)c->rec;

	/*
	 * mdadm read the configuration before it took the map lock: a volume
	 * another mdadm created or deleted meanwhile moved this one's number,
	 * and its md array is set up under the old one (external:/mdX/N).
	 */
	if (h && c->vol != super->nvol) {
		amd_kmsg("the new volume is not subarray-%d any more: not recorded",
			 c->vol);
		return;
	}
	if (sizeof(*c) + c->len != len || !h ||
	    amd_new_overlaps(super, ld, c->len)) {
		amd_kmsg("the new volume overlaps an extent in use: not recorded");
		return;
	}
	if (!zero || amd_clear_service(super, ld, zero) != 0 ||
	    amd_insert_ld(super, __le32_to_cpu(h->ld_offset) +
			  __le32_to_cpu(h->ld_size), c->rec, c->len) != 0) {
		amd_kmsg("cannot record the new volume");
		return;
	}
	amd_take_spares(super, &super->vol[super->nvol - 1]);
	super->config_dirty = 1;
	dprintf("volume %d created\n", super->nvol - 1);
}

/*
 * The monitor's array of volume @vol, or NULL - not one it let go of
 * (amd_sync_progress): a volume started again may be another md array.
 */
static struct active_array *amd_vol_array(struct supertype *st, int vol)
{
	struct active_array *a;

	for (a = st->arrays; a; a = a->next)
		if (a->container && !a->to_remove &&
		    a->info.container_member == vol)
			return a;
	return NULL;
}

/*
 * md has a device in @slot of @a: the rdN link of the array
 * (Documentation/admin-guide/md.rst).  managemon queues the update of
 * activate_spare even if md did not take the disk (manage_member:
 * sysfs_add_disk failed - EBUSY, the disk gone meanwhile).
 */
static int amd_md_took(struct active_array *a, int slot)
{
	char path[64];

	snprintf(path, sizeof(path), "/sys/block/%s/md/rd%d",
		 a->info.sys_name, slot);
	return access(path, F_OK) == 0;
}

static void amd_spare_update(struct supertype *st,
			     const struct amd_update_spare *u)
{
	struct amd_super *super = st->sb;
	struct active_array *a;
	struct amd_disk *d;
	struct amd_vol *v;

	if (u->vol < 0 || u->vol >= super->nvol)
		return;
	v = &super->vol[u->vol];
	if (v->mon.rebuilding || u->slot < 0 || !amd_md_slot(v, u->slot))
		return;
	a = amd_vol_array(st, u->vol);
	/*
	 * Recorded without the disk in md, the rebuild would never end
	 * (set_disk comes for md's devices only), and while it runs no other
	 * spare is taken (amd_activate_spare).  As with a target md fails:
	 * that disk is not taken again while here, another may be - once md
	 * ends the recovery it was told to run (managemon.c), the monitor has
	 * managemon look for a spare again.  No array to ask: open_new's, not
	 * on the list yet, which found the disk in md (amd_unrecorded_rebuild).
	 */
	if (a && !amd_md_took(a, u->slot)) {
		d = amd_find_disk(super, __le64_to_cpu(u->el.id.id));
		if (d)
			d->spare_failed = 1;
		amd_kmsg("subarray-%d: md did not take disk %016llx for member %d: no rebuild onto it",
			 u->vol, (unsigned long long)__le64_to_cpu(u->el.id.id),
			 u->slot);
		return;
	}
	/*
	 * md rebuilds the slot, so its member is out of service: if the
	 * packet does not say so yet (managemon found the slot empty before
	 * the monitor looked at the volume, amd_mark_missing), it does now.
	 * A rebuild recorded with the member in service in both LD copies is
	 * no rebuild to the next assembly: the target, half copied, in sync.
	 */
	if (u->slot < v->nel && amd_slot_usable(v, u->slot) &&
	    amd_fail_element(super, v, u->slot, AMD_ELEMENT_OFFLINE))
		amd_kmsg("subarray-%d: member %d is rebuilt, recorded as offline first",
			 u->vol, u->slot);
	v->mon.rebuilding = 1;
	v->mon.rebuild_slot = u->slot;
	v->mon.rebuild_done = 0;
	v->mon.rebuild_el = u->el;
	v->mon.rebuild_recorded = u->recorded;
	v->mon.rebuild_ckpt = 0;
	v->mon.tlog_dirty = 0;
	amd_rebuild_pd(super, &v->mon.rebuild_el, u->features);
	/* the target of a recorded rebuild is copied from 0 (amd_activate_spare) */
	if (u->recorded)
		amd_target_behind(super, v);
	v->mon.target_away = 0;
	/*
	 * open_new's rebuild md may have ended already: the monitor sees no
	 * recovery end then.  A spare activate_spare gives md is not on the
	 * list of the array yet (managemon replaces it after this update).
	 */
	if (a)
		amd_rebuild_ended_unseen(a, v);
	dprintf("array %d rebuilds member %d\n", u->vol, u->slot);
}

static void amd_process_update(struct supertype *st,
			       struct metadata_update *update)
{
	struct amd_super *super = st->sb;
	void *buf = update->buf;
	struct active_array *a;

	if (!super)
		return;
	switch (amd_update_type(update)) {
	case AMD_UPDATE_SPARE:
		amd_spare_update(st, buf);
		break;
	case AMD_UPDATE_CREATE:
		amd_create_update(st, buf, update->len, update->space);
		break;
	case AMD_UPDATE_REMOVE:
		amd_remove_disk(super, buf);
		break;
	case AMD_UPDATE_ADD:
		amd_add_pd(st, buf, &update->space);
		break;
	case AMD_UPDATE_ATTACH:
		amd_attach_update(st, buf);
		break;
	case AMD_UPDATE_KILL:
		amd_kill_volume(st, buf);
		break;
	case AMD_UPDATE_SUBARRAY:
		if (amd_apply_subarray(super, buf))
			amd_kmsg("cannot update the volume: it changed meanwhile");
		break;
	case AMD_UPDATE_ROLE:
		amd_apply_role(super, buf);
		/* a degraded volume given a dedicated spare: rebuild onto it */
		for (a = st->arrays; a; a = a->next)
			a->check_degraded = 1;
		break;
	case AMD_UPDATE_GROW:
		amd_grow_update(st, buf);
		break;
	}
}

/*
 * Does an extent on disk @id - of volume @v, its second LD copy or its
 * rebuild in progress - overlap [start, start + len)?  Then *end is where
 * it ends.
 */
static int amd_vol_overlap(struct amd_vol *v, __u64 id,
			   unsigned long long start, unsigned long long len,
			   unsigned long long *end)
{
	int i, j;

	for (j = 0; j < 3; j++) {
		struct amd_element *el = v->el;
		int n = v->nel;

		if (j == 1) {
			if (!v->link)
				continue;
			el = amd_link_elements(v);
			n = amd_link_nel(v);
		} else if (j == 2) {
			if (!v->mon.rebuilding)
				continue;
			el = &v->mon.rebuild_el;
			n = 1;
		}
		for (i = 0; i < n; i++) {
			unsigned long long o = __le64_to_cpu(el[i].allocated.offset);
			unsigned long long s = __le64_to_cpu(el[i].allocated.size);

			if (__le64_to_cpu(el[i].id.id) != id || s == 0 ||
			    o >= start + len || start >= o + s)
				continue;
			*end = o + s;
			return 1;
		}
	}
	return 0;
}

/* amd_vol_overlap() of any volume */
static int amd_extent_overlap(struct amd_super *super, __u64 id,
			      unsigned long long start, unsigned long long len,
			      unsigned long long *end)
{
	int vol;

	for (vol = 0; vol < super->nvol; vol++)
		if (amd_vol_overlap(&super->vol[vol], id, start, len, end))
			return 1;
	return 0;
}

/*
 * The extent of @v's element @slot lies in another volume as well.  The
 * AMD BIOS menu and driver count the extent of a member recorded offline
 * as free (rcblob BuildFreeList) and give it to a volume made later, but
 * they clear the old volume's element then (DeviceID 0, sizes 0;
 * dumps/2026-11-12-q3j-w2): their metadata never has both.  Configuration
 * packets of different generations put together, or a damaged one, can:
 * the other volume's data is not to be written over then.
 */
static int amd_extent_given_away(struct amd_super *super,
				 const struct amd_vol *v, int slot)
{
	const struct amd_element *own = &v->el[slot];
	unsigned long long end;
	int vol;

	for (vol = 0; vol < super->nvol; vol++)
		if (&super->vol[vol] != v &&
		    amd_vol_overlap(&super->vol[vol], __le64_to_cpu(own->id.id),
				    __le64_to_cpu(own->allocated.offset),
				    __le64_to_cpu(own->allocated.size), &end))
			return 1;
	return 0;
}

static int amd_in_volume(const struct amd_vol *v, __u64 id)
{
	int i;

	for (i = 0; i < v->nel; i++)
		if (__le64_to_cpu(v->el[i].id.id) == id)
			return 1;
	return 0;
}

/* a disk md can rebuild @v onto: present, not in @v, md has not failed it */
static struct amd_disk *amd_target_disk(struct amd_super *super,
					struct amd_vol *v, __u64 id)
{
	struct amd_disk *d = amd_find_disk(super, id);

	if (!d || d->fd < 0 || d->spare_failed || (d->major == 0 && d->minor == 0) ||
	    amd_in_volume(v, id) || amd_disk_failed(super, id))
		return NULL;
	return d;
}

/* a disk md can rebuild @v onto (amd_target_disk) that is up to date too: a spare */
static struct amd_disk *amd_spare_disk(struct amd_super *super,
				       struct amd_vol *v, __u64 id)
{
	struct amd_disk *d = amd_target_disk(super, v, id);

	return d && amd_disk_current(super, d) ? d : NULL;
}

/*
 * The spares of the container @v may take, as IMSM gives md the container's
 * (Grow.c checks --raid-devices against them): its dedicated spares and the
 * global ones that are here.  Whether one has room, amd_find_spare says.
 */
static int amd_spare_count(struct amd_super *super, struct amd_vol *v)
{
	const struct amd_dev_id *sp = amd_ld_spares(v->ld);
	int i, n = 0;

	for (i = 0; i < (int)__le32_to_cpu(v->ld->spare_count); i++)
		n += amd_spare_disk(super, v, __le64_to_cpu(sp[i].id)) != NULL;
	for (i = 0; i < super->npd; i++) {
		__u64 id = __le64_to_cpu(super->pd[i]->id.id);

		n += (__le32_to_cpu(super->pd[i]->spare_info) & AMD_SPARE_GLOBAL) &&
		     amd_dedicated_owner(super, id) < 0 &&
		     amd_spare_disk(super, v, id) != NULL;
	}
	return n;
}

/*
 * PD @pd of disk @d (may be NULL) is an AMD RAID disk to rebuild onto: ONLINE,
 * or OFFLINE in the packet (failed, or away at the last write: the record
 * says so until the next one, amd_pd_states) while the disk is here now and
 * md has not failed it - as the AMD driver takes it at its start.
 */
static int amd_pd_usable(const struct amd_pd *pd, const struct amd_disk *d)
{
	__u32 state = __le32_to_cpu(pd->device_state);

	if (__le32_to_cpu(pd->device_type) != AMD_DEV_RAIDCORE_DISK)
		return 0;
	return state == AMD_DEV_STATE_ONLINE ||
	       (state == AMD_DEV_STATE_OFFLINE && d && d->fd >= 0 &&
		!d->removed && !d->spare_failed);
}

/*
 * The element to rebuild into on spare @pd (disk @d): the first free extent
 * from 0x100000 within the disk's capacity, @size sectors as the members'
 * AllocatedSpace, user data @gap into it.  0, or -1 if it does not fit or
 * the disk is not an online RAIDCore disk.
 */
static int amd_spare_extent(struct amd_super *super, const struct amd_pd *pd,
			    const struct amd_disk *d,
			    const struct amd_element *model,
			    unsigned long long size, unsigned long long gap,
			    struct amd_element *el)
{
	__u64 id = __le64_to_cpu(pd->id.id);
	unsigned long long start = AMD_DEFAULT_ALLOC_LBA, end, cap;

	if (!amd_pd_usable(pd, d))
		return -1;
	cap = amd_pd_capacity(pd, d->sectors);
	while (amd_extent_overlap(super, id, start, size, &end))
		start = end;
	if (start + size > cap)
		return -1;
	memset(el, 0, sizeof(*el));
	el->id = pd->id;
	el->allocated.offset = __cpu_to_le64(start);
	el->allocated.size = __cpu_to_le64(size);
	el->user_data.offset = __cpu_to_le64(start + gap);
	el->user_data.size = model->user_data.size;
	return 0;
}

/*
 * amd_find_spare: the target of a recorded rebuild or migration (RAIDABLE ->
 * RAID1) of @slot.
 */
static struct amd_disk *amd_spare_target(struct amd_super *super,
					 struct amd_vol *v, int slot,
					 struct amd_element *el, int *recorded)
{
	struct amd_element *lel = &amd_link_elements(v)[slot];
	struct amd_disk *d = amd_target_disk(super, v,
					     __le64_to_cpu(lel->id.id));

	if (!amd_element_usable(lel) || !d)
		return NULL;
	*el = *lel;
	el->flags = 0;
	*recorded = 1;
	return d;
}

/*
 * amd_find_spare: the own disk of @slot is back (it was missing when the
 * volume ran, or stale: offline, 0x30, or dropped from the second LD copy
 * by the BIOS): rebuilt in place, in its extent, from the others - as IMSM
 * takes back a returning member.  Not a disk failed on errors (0x10
 * alone), now or before: that one waits for the user, as with the AMD
 * driver.  (The AMD driver also counts the extent of a member it found
 * offline as free - rcblob BuildFreeList, offline handle - and rebuilds
 * only onto spares or on the user's request.)  Nor one whose extent lies
 * in another volume as well (amd_extent_given_away): a rebuild in place
 * would go over that volume's data.
 */
static struct amd_disk *amd_spare_own(struct amd_super *super,
				      struct amd_vol *v, int slot,
				      struct amd_element *el, int *recorded)
{
	const struct amd_element *own = &v->el[slot];
	struct amd_disk *d = amd_find_disk(super, __le64_to_cpu(own->id.id));

	if (!own->id.id || !own->allocated.size || !d || d->fd < 0 ||
	    amd_slot_failed(v, slot) ||
	    (!d->major && !d->minor) || d->spare_failed ||
	    __le64_to_cpu(own->allocated.offset) +
	    __le64_to_cpu(own->allocated.size) > d->sectors ||
	    amd_extent_given_away(super, v, slot))
		return NULL;
	*el = *own;
	el->flags = 0;
	/* its rebuild in place was recorded already, the volume ran without it */
	if (amd_rebuild_slot(v) == slot) {
		const struct amd_element *lel = &amd_link_elements(v)[slot];

		if (lel->id.id == own->id.id &&
		    lel->allocated.offset == own->allocated.offset)
			*recorded = 1;
	}
	return d;
}

/* the element a spare's extent is shaped after: the first in service */
static const struct amd_element *amd_spare_model(const struct amd_vol *v)
{
	int i;

	for (i = 0; i < v->nel; i++)
		if (amd_slot_usable(v, i) && v->el[i].allocated.size)
			return &v->el[i];
	return NULL;
}

/*
 * Find a spare for the empty @slot of @v and the extent to rebuild into,
 * the way the AMD driver does (rcblob RC_CreateTransformDevice with a
 * global spare, RC_AllocateSpace): a RAIDCore disk with SpareInfo 0x100
 * that is not in the volume yet, the first free extent from 0x100000 as
 * large as the other members' AllocatedSpace, user data at the same
 * distance into it.  A rebuild the AMD driver started and did not finish
 * keeps its extent (the second LD copy has it): *@recorded is 1 for its
 * target.
 */
static struct amd_disk *amd_find_spare(struct amd_super *super,
				       struct amd_vol *v, int slot,
				       struct amd_element *el, int *recorded)
{
	const struct amd_dev_id *sp = amd_ld_spares(v->ld);
	const struct amd_element *model = NULL;
	unsigned long long size, gap;
	struct amd_disk *d = NULL;
	int i;

	*recorded = 0;
	if (amd_rebuild_slot(v) == slot)
		d = amd_spare_target(super, v, slot, el, recorded);
	/* the mirror a RAIDABLE grows by has no disk of its own yet */
	if (!d && slot < v->nel)
		d = amd_spare_own(super, v, slot, el, recorded);
	if (d)
		return d;

	model = amd_spare_model(v);
	if (!model)
		return NULL;
	size = __le64_to_cpu(model->allocated.size);
	gap = __le64_to_cpu(model->user_data.offset) -
	      __le64_to_cpu(model->allocated.offset);

	/*
	 * The volume's own dedicated spares first, in the order of its list,
	 * then the global ones: the AMD driver's order (rcraid.sys 9.3.3.218
	 * RC_SetupTransform: dedicated, distributed, global).  Neither is held
	 * to the members' controller: the menu takes a dedicated spare from
	 * any (an NVMe drive for a SATA RAID1), and the driver checks the
	 * controller of a global one only when RC_GetFeatures() lacks 0x8
	 * (arrays across controllers, rcblob RC_CreateTransformDevice) - the
	 * AND of the controllers' features, 0x4b or 0x6b on every platform
	 * seen, both with 0x8.
	 */
	for (i = 0; i < (int)__le32_to_cpu(v->ld->spare_count); i++) {
		int p = amd_pd_index(super, __le64_to_cpu(sp[i].id));

		if (p < 0)
			continue;
		d = amd_spare_disk(super, v, __le64_to_cpu(sp[i].id));
		if (d && amd_spare_extent(super, super->pd[p], d, model,
					  size, gap, el) == 0)
			return d;
	}

	for (i = 0; i < super->npd; i++) {
		struct amd_pd *pd = super->pd[i];
		__u64 id = __le64_to_cpu(pd->id.id);

		if (!(__le32_to_cpu(pd->spare_info) & AMD_SPARE_GLOBAL) ||
		    amd_dedicated_owner(super, id) >= 0)
			continue;
		d = amd_spare_disk(super, v, id);
		if (!d)
			continue;
		if (amd_spare_extent(super, pd, d, model, size, gap, el) == 0)
			return d;
	}
	return NULL;
}

/*
 * Spare roles from mdadm (subarray_spare_amd): a dedicated hot spare of a
 * volume assigned or unassigned (the menu's Manage Dedicated Hot Spares and
 * Unassign Hot Spare, rcblob RC_AssignSpare/RC_DeassignSpare), or the global
 * role of a disk unassigned (RC_DeassignPhysicalDeviceGlobalSpare).
 */
#define AMD_MAX_DEDICATED	4	/* RC_CoreLogicalDevice SpareListSize */

/*
 * ROLE (monitor).  A dedicated spare goes at the end of the volume's list
 * in its first LD copy, ID and Handle as the disk's PD (as the menu writes
 * it); it stops being a global spare - the menu offers only disks with
 * SpareInfo 0, and the AMD driver would take a global one for any volume.
 */
static void amd_apply_role(struct amd_super *super,
			   const struct amd_update_role *u)
{
	int p = amd_pd_index(super, u->id);

	if (p < 0) {
		amd_kmsg("cannot change the spare role of disk %016llx: it has no PD record",
			 (unsigned long long)u->id);
		return;
	}
	if (u->vol >= 0) {
		struct amd_ld *ld;
		struct amd_dev_id e, *sp;
		unsigned int n, at;

		if (u->vol >= super->nvol ||
		    __le64_to_cpu(super->vol[u->vol].ld->id.id) != u->vol_id) {
			amd_kmsg("cannot change the dedicated spares of subarray-%d: the volume changed meanwhile",
				 u->vol);
			return;
		}
		if (!u->add) {
			if (!amd_drop_dedicated(super, u->vol, u->id))
				amd_kmsg("disk %016llx is not a dedicated spare of subarray-%d",
					 (unsigned long long)u->id, u->vol);
			return;
		}
		ld = super->vol[u->vol].ld;
		n = __le32_to_cpu(ld->spare_count);
		sp = amd_ld_spares(ld);
		if (amd_dedicated_index(ld, u->id) >= 0)
			return;
		if (n >= AMD_MAX_DEDICATED) {
			amd_kmsg("cannot record disk %016llx as a dedicated spare of subarray-%d: it has %d already",
				 (unsigned long long)u->id, u->vol, AMD_MAX_DEDICATED);
			return;
		}
		e = super->pd[p]->id;
		e.reserved = 0;
		at = (char *)&sp[n] - (char *)super->packet;
		ld->spare_count = __cpu_to_le32(n + 1);
		ld->packet_size = __cpu_to_le32(__le32_to_cpu(ld->packet_size) +
						sizeof(e));
		if (amd_insert_ld(super, at, &e, sizeof(e)) != 0) {
			ld->spare_count = __cpu_to_le32(n);
			ld->packet_size = __cpu_to_le32(__le32_to_cpu(ld->packet_size) -
							sizeof(e));
			amd_kmsg("cannot record disk %016llx as a dedicated spare of subarray-%d",
				 (unsigned long long)u->id, u->vol);
			return;
		}
	}
	amd_drop_global(super, u->id);
	super->config_dirty = 1;
	dprintf("disk %016llx: %s\n", (unsigned long long)u->id,
		u->vol < 0 ? "no global spare" : u->add ? "a dedicated spare" :
		"no dedicated spare");
}

/*
 * The DeviceID in the AMD label of @devname, or 0 (no label of ours, or
 * the disk is gone).  With @fdp, the disk is opened for writing and the
 * descriptor kept there.
 */
static __u64 amd_label_id(const char *devname, int *fdp)
{
	struct amd_metadata *md = amd_alloc(AMD_SECTOR);
	__u64 id = 0;
	int fd;

	fd = open(devname, (fdp ? O_RDWR : O_RDONLY) | O_DIRECT);
	if (md && fd >= 0 && amd_read(fd, AMD_METADATA_LBA, md, AMD_SECTOR) == 0 &&
	    amd_label_valid(md))
		id = __le64_to_cpu(md->device_id);
	free(md);
	if (fdp && id)
		*fdp = fd;
	else if (fd >= 0)
		close(fd);
	return id;
}

/*
 * SpareInfo of the label of disk @id on @fd: the BIOS fills the PD's in from
 * it at every start (RAIDCoreDxe FUN_0001d68c), and the AMD driver rewrites
 * it as it assigns or unassigns a global spare (rcblob RC_ManageGlobalSpare:
 * RC_UpdateMetaData).  0 on success.
 */
static int amd_label_spare(int fd, __u64 id, __u32 spare)
{
	struct amd_metadata *md = amd_alloc(AMD_SECTOR);
	int rv = -1;

	if (md && amd_read(fd, AMD_METADATA_LBA, md, AMD_SECTOR) == 0 &&
	    amd_label_valid(md) && __le64_to_cpu(md->device_id) == id) {
		if (__le32_to_cpu(md->spare_info) == spare) {
			rv = 0;
		} else {
			md->spare_info = __cpu_to_le32(spare);
			md->checksum = __cpu_to_le64(amd_sector_sum(md));
			if (pwrite(fd, md, AMD_SECTOR,
				   (off_t)AMD_METADATA_LBA * AMD_SECTOR) == AMD_SECTOR &&
			    fsync(fd) == 0)
				rv = 0;
		}
	}
	free(md);
	return rv;
}

/*
 * Can disk @d (PD @p) be a dedicated spare of @v?  NULL if so, else the
 * reason why not.  As the AMD core takes one (rcblob RC_AssignSpare: an
 * online RAIDCore disk, not in the volume, at most SpareListSize) and keeps
 * it (RC_RemoveUnusableDedicatedSpares: no smaller than the smallest member,
 * with room for a member's extent).  The menu offers only whole free disks;
 * the core and the AMD driver for Windows take any disk with the room.
 */
static const char *amd_dedicated_refusal(struct amd_super *super,
					 struct amd_vol *v, struct amd_disk *d,
					 int p)
{
	static char why[96];
	int spare_count = __le32_to_cpu(v->ld->spare_count);
	const struct amd_element *model = NULL;
	unsigned long long min = ~0ULL;
	struct amd_element el;
	int i;

	if (v->blocked)
		return v->blocked;
	if (v->grow)
		return "it is being made a RAID1 (the spare list is the RAIDABLE's until then)";
	if (v->single || (v->level != 1 && v->level != 5 && v->level != 10))
		return "it has no redundancy (AMD gives dedicated spares to RAID1, RAID5 and RAID10 only)";
	if (amd_in_volume(v, d->device_id))
		return "the disk is one of its members";
	for (i = 0; i < amd_link_nel(v); i++)
		if (__le64_to_cpu(amd_link_elements(v)[i].id.id) == d->device_id)
			return "the disk is being rebuilt into it";
	if (amd_dedicated_index(v->ld, d->device_id) >= 0)
		return "the disk is a dedicated spare of it already";
	if (spare_count >= AMD_MAX_DEDICATED)
		return "it has 4 dedicated spares already, as many as AMD keeps";
	if (!amd_pd_usable(super->pd[p], d))
		return "the disk is not an online AMD RAID disk";
	for (i = 0; i < v->nel; i++) {
		int q = amd_pd_index(super, __le64_to_cpu(v->el[i].id.id));
		struct amd_disk *m = amd_find_disk(super, __le64_to_cpu(v->el[i].id.id));

		if (!model && amd_slot_usable(v, i) && v->el[i].allocated.size)
			model = &v->el[i];
		if (q >= 0 && m && amd_pd_capacity(super->pd[q], m->sectors) < min)
			min = amd_pd_capacity(super->pd[q], m->sectors);
	}
	if (min != ~0ULL && amd_pd_capacity(super->pd[p], d->sectors) < min)
		return "the disk is smaller than the members";
	if (!model)
		return "it has no member in service";
	if (amd_spare_extent(super, super->pd[p], d, model,
			     __le64_to_cpu(model->allocated.size),
			     __le64_to_cpu(model->user_data.offset) -
			     __le64_to_cpu(model->allocated.offset), &el) != 0) {
		snprintf(why, sizeof(why), "the disk has no free extent of %llu MiB for a member",
			 (unsigned long long)__le64_to_cpu(model->allocated.size) / AMD_MIB);
		return why;
	}
	return NULL;
}

/*
 * subarray_spare_amd of volume @vol: the role update @u for @devname (disk
 * @d of the container, or NULL) - a dedicated spare of it, or no longer
 * one.  0, or -1 if it cannot be.
 */
static int amd_dedicated_role(struct supertype *st, unsigned long vol,
			      char *devname, struct amd_disk *d,
			      struct amd_update_role *u)
{
	struct amd_super *super = st->sb;
	struct amd_vol *v = &super->vol[vol];
	const char *why;
	int p;

	u->vol = vol;
	u->vol_id = __le64_to_cpu(v->ld->id.id);
	if (u->add) {
		if (!d) {
			pr_err("%s is not in the container: add it there first (mdadm /dev/%s --add %s)\n",
			       devname, st->container_devnm, devname);
			return -1;
		}
		p = amd_pd_index(super, d->device_id);
		why = p < 0 ? "the disk has no PD record" :
			      amd_dedicated_refusal(super, v, d, p);
		if (why) {
			pr_err("%s cannot be a dedicated spare of subarray-%lu: %s\n",
			       devname, vol, why);
			return -1;
		}
		u->id = d->device_id;
		return 0;
	}
	u->id = d ? d->device_id : amd_label_id(devname, NULL);
	if (!u->id || amd_dedicated_index(v->ld, u->id) < 0) {
		pr_err("%s is not a dedicated spare of subarray-%lu\n",
		       devname, vol);
		return -1;
	}
	return 0;
}

/*
 * subarray_spare_amd of the container: @devname has left it already.  A
 * spare that is here loses every spare role: global, and dedicated of any
 * volume (each one an update, queued here).  Returns whether it was a
 * global spare (that update, @u, is the caller's), or -1 if there is
 * nothing to do.
 */
static int amd_drop_spare_roles(struct supertype *st, char *devname,
				struct amd_update_role *u)
{
	struct amd_super *super = st->sb;
	struct amd_update_role *m;
	unsigned long vol;
	int p, was_global;

	u->id = amd_label_id(devname, NULL);
	p = u->id ? amd_pd_index(super, u->id) : -1;
	if (p < 0 || amd_disk_in_volumes(super, u->id))
		return -1;
	st->update_tail = &st->updates;
	for (vol = 0; vol < (unsigned long)super->nvol; vol++) {
		const struct amd_ld *ld = super->vol[vol].ld;

		if (amd_dedicated_index(ld, u->id) < 0)
			continue;
		m = xmalloc(sizeof(*m));
		*m = *u;
		m->vol = vol;
		m->vol_id = __le64_to_cpu(ld->id.id);
		append_metadata_update(st, m, sizeof(*m));
	}
	was_global = (__le32_to_cpu(super->pd[p]->spare_info) &
		      AMD_SPARE_GLOBAL) != 0;
	if (!was_global && !st->updates)
		return -1;
	return was_global;
}

/*
 * The updates of subarray_spare_amd that were not sent, and its update
 * list: Manage goes on with @st, and with a list left add_to_super_amd
 * would take the --add that follows on the command line for mdmon's.
 */
static void amd_drop_updates(struct supertype *st)
{
	struct metadata_update *mu;

	while (st->updates) {
		mu = st->updates;
		st->updates = mu->next;
		free(mu->buf);
		free(mu);
	}
	st->update_tail = NULL;
}

/*
 * subarray_spare_amd of the container with no mdmon to record the roles
 * queued (no volume under it runs: only RAID0 or Volume, or all stopped):
 * this process applies them and writes the configuration, as it does for
 * --kill-subarray.  To a copy read afresh: the one loaded still says what
 * the roles were (amd_say_dropped).  0, or -1 if it was not written.
 */
static int amd_drop_roles_here(struct supertype *st)
{
	struct supertype *tst = dup_super(st);
	struct metadata_update *mu;
	int fd, rv = -1;

	/*
	 * Read and written under the exclusive open of the container that
	 * Create, Kill and Update_subarray write under: none of them
	 * writes in between.
	 */
	fd = open_dev_excl(st->container_devnm);
	if (is_fd_valid(fd) && tst->ss->load_container(tst, fd, NULL) == 0) {
		for (mu = st->updates; mu; mu = mu->next)
			amd_apply_role(tst->sb, (const void *)mu->buf);
		amd_repair_legacy(tst->sb, 1);	/* as -C does */
		rv = amd_write_changed(tst->sb) ? -1 : 0;
		tst->ss->free_super(tst);
	}
	close_fd(&fd);
	free(tst);
	return rv;
}

/*
 * subarray_spare_amd of the container, once the configuration has it: the
 * roles @devname (disk @id) had in configuration @super are gone.
 */
static void amd_say_dropped(struct amd_super *super, const char *devname,
			    __u64 id, int was_global)
{
	int vol;

	for (vol = 0; vol < super->nvol; vol++)
		if (amd_dedicated_index(super->vol[vol].ld, id) >= 0)
			pr_err("%s: no longer a dedicated hot spare of subarray-%d\n",
			       devname, vol);
	if (was_global)
		pr_err("%s: no longer an AMD global hot spare (still an AMD RAID disk: mdadm --zero-superblock clears it)\n",
		       devname);
}

/*
 * amd_mdmon_recorded of the spare roles of disk @u->id: a dedicated spare
 * of volume @u->vol_id or not, as @u->add asks; from the container (@u->vol
 * -1), no role left, global (SpareInfo of its PD) or dedicated.
 */
static int amd_role_recorded(struct amd_super *super, const void *arg)
{
	const struct amd_update_role *u = arg;
	const struct amd_vol *v;
	int p, vol;

	if (u->vol >= 0) {
		v = amd_vol_by_id(super, u->vol_id);
		return (v && amd_dedicated_index(v->ld, u->id) >= 0) == u->add;
	}
	p = amd_pd_index(super, u->id);
	if (p >= 0 && (__le32_to_cpu(super->pd[p]->spare_info) &
		       AMD_SPARE_GLOBAL))
		return 0;
	for (vol = 0; vol < super->nvol; vol++)
		if (amd_dedicated_index(super->vol[vol].ld, u->id) >= 0)
			return 0;
	return 1;
}

/*
 * The device file of @devname as Manage names a device to --remove: a
 * path, major:minor, or the kernel name of a container member ("sdb", the
 * name md gives it).  NULL if there is none - the disk has gone.
 */
static char *amd_dev_file(char *devname)
{
	int mj, mn;
	dev_t rdev;

	if (strchr(devname, '/'))
		return devname;
	if (get_maj_min(devname, &mj, &mn))
		rdev = makedev(mj, mn);
	else
		rdev = devnm2devid(devname);
	return rdev ? map_dev(major(rdev), minor(rdev), 0) : NULL;
}

/*
 * mdadm <volume> --add-spare <disk>: a disk of the container becomes a
 * dedicated hot spare of the volume (a global one loses that role);
 * mdadm <volume> --remove <disk>: it stops being a dedicated spare of it.
 * mdadm <container> --remove <disk> (@subarray NULL, called once the disk
 * has left the container): a global hot spare that is still here loses the
 * role - it stays an initialized AMD RAID disk, as after Unassign Hot Spare
 * in the menu; a disk that is gone keeps its role.  mdmon records it in the
 * configuration (this process, if no mdmon runs: amd_drop_roles_here); the
 * global role is in the disk's label too, which mdadm
 * writes only once the configuration on the disks has the change: a label
 * without the role the PD still has would have the BIOS drop it at the
 * next start (amd_label_spare).
 */
static int subarray_spare_amd(struct supertype *st, char *subarray,
			      char *devname, int add)
{
	struct amd_super *super;
	struct amd_update_role u, *m;
	struct amd_disk *d = NULL;
	struct stat stb;
	unsigned long vol = 0;
	int cfd, p, rv = subarray ? 1 : 0, wfd = -1, was_global = 0;
	char *ep, *name = devname;

	devname = amd_dev_file(devname);
	if (!devname || stat(devname, &stb) != 0 || !S_ISBLK(stb.st_mode)) {
		if (subarray)
			pr_err("%s is not a block device\n", name);
		return rv;
	}
	cfd = open_dev(st->container_devnm[0] ? st->container_devnm : st->devnm);
	if (cfd < 0 || st->ss->load_container(st, cfd, NULL) != 0) {
		if (cfd >= 0)
			close(cfd);
		pr_err("cannot load the AMD RAID configuration\n");
		return 1;
	}
	close(cfd);
	super = st->sb;
	memset(&u, 0, sizeof(u));
	u.type = AMD_UPDATE_ROLE;
	u.vol = -1;
	u.add = add;
	for (d = super->disks; d; d = d->next)
		if (!d->removed && d->major == (int)major(stb.st_rdev) &&
		    d->minor == (int)minor(stb.st_rdev))
			break;

	if (subarray) {
		vol = strtoul(subarray, &ep, 10);
		if (*ep || ep == subarray || vol >= (unsigned long)super->nvol ||
		    amd_dedicated_role(st, vol, devname, d, &u) != 0)
			goto out;
	} else {
		was_global = amd_drop_spare_roles(st, devname, &u);
		if (was_global < 0)
			goto out;
	}
	p = amd_pd_index(super, u.id);
	if (subarray)
		was_global = p >= 0 && (__le32_to_cpu(super->pd[p]->spare_info) &
					AMD_SPARE_GLOBAL) && add;
	if (subarray || was_global) {
		m = xmalloc(sizeof(*m));
		*m = u;
		st->update_tail = &st->updates;
		append_metadata_update(st, m, sizeof(*m));
	}
	if (subarray || mdmon_running(st->container_devnm)) {
		rv = amd_mdmon_recorded(st, amd_role_recorded, &u);
		if (rv > 0)
			pr_err("%s: mdmon did not change its spare roles (see dmesg)\n",
			       devname);
	} else {
		rv = amd_drop_roles_here(st);
	}
	if (rv) {
		rv = 1;
		goto out;
	}
	if (was_global && (amd_label_id(devname, &wfd) != u.id ||
			   amd_label_spare(wfd, u.id, 0) != 0))
		pr_err("%s: cannot write its label: the BIOS will take it for a global spare again\n",
		       devname);
	if (wfd >= 0)
		close(wfd);
	if (st->verbose >= 0) {
		if (!subarray)
			amd_say_dropped(super, devname, u.id, was_global);
		else if (add)
			pr_err("%s: a dedicated hot spare of subarray-%lu now%s\n",
			       devname, vol,
			       was_global ? " (no longer a global one)" : "");
		else
			pr_err("%s: no longer a dedicated hot spare of subarray-%lu\n",
			       devname, vol);
	}
	rv = 0;
out:
	amd_drop_updates(st);
	st->ss->free_super(st);
	return rv;
}

/*
 * The element of spare @d for @v at the LBA of the others: md writes the
 * bits of an md bitmap there on every member (amd_mdbm_lba).  The AMD
 * driver would take the disk's first free extent, but reads any from the
 * configuration.  0, or -1 if that is not free on @d - or a @recorded
 * rebuild keeps its extent.
 */
static int amd_mdbm_place(struct amd_super *super, const struct amd_vol *v,
			  const struct amd_disk *d, struct amd_element *el,
			  int recorded)
{
	unsigned long long lba = amd_mdbm_lba(v), base = lba - AMD_MDBM_OFFSET;
	unsigned long long at = __le64_to_cpu(el->allocated.offset);
	unsigned long long size = __le64_to_cpu(el->allocated.size), end;
	int p = amd_pd_index(super, d->device_id);

	if (!lba)
		return -1;
	if (at == base)
		return 0;
	if (recorded || p < 0 ||
	    base + size > amd_pd_capacity(super->pd[p], d->sectors) ||
	    amd_extent_overlap(super, d->device_id, base, size, &end))
		return -1;
	el->allocated.offset = __cpu_to_le64(base);
	el->user_data.offset = __cpu_to_le64(base +
		__le64_to_cpu(el->user_data.offset) - at);
	return 0;
}

/*
 * A managed volume with a member out of service (recorded so in the
 * config: flags 0x4030, or no disk) gets that member's own disk back if
 * it is here again, else an AMD global spare.  Members missing when the
 * volume went into use are out of service by then (amd_mark_missing).
 * The start is recorded by amd_start_rebuild, the end by
 * amd_finish_rebuild.  @bitmap_at: where md writes the bits of its bitmap
 * now (amd_md_bitmap_at).
 * The target of a recorded rebuild too is copied from 0, as IMSM copies
 * any disk it adds to a running array: md may write without it until the
 * slot is set, and the mark of its log would skip that (amd_spare_update
 * sets the log back to 0).  The next assembly goes on from the log
 * (container_content).
 * 1: the spare is in @di, the update for the monitor in @u - zeroed, and
 * allocated before the lock (amd_mm_activate_spare).
 */
static int amd_activate_spare(struct active_array *a, struct mdinfo *di,
			      struct amd_update_spare *u, long long bitmap_at)
{
	struct amd_super *super = a->container->sb;
	struct amd_vol *v = amd_active_vol(a);
	struct amd_disk *d = NULL;
	struct amd_element el;
	struct mdinfo *dev;
	int slot, recorded = 0;

	if (!v || v->mon.rebuilding ||
	    (v->level != 1 && v->level != 10 && v->level != 5))
		return 0;
	for (dev = a->info.devs; dev; dev = dev->next)
		if (is_fd_valid(dev->state_fd) && (dev->curr_state & DS_FAULTY))
			return 0;	/* wait for md to remove it */

	/*
	 * A slot md runs without: out of service, or its member missing - a
	 * running volume takes no late member in sync; amd_mark_missing
	 * records it, and the rebuild is recorded only after that.  Or the
	 * second slot mdadm --grow gave the md raid1 of a RAIDABLE: its
	 * mirror, a migration to the AMD driver.
	 */
	for (slot = 0; slot < a->info.array.raid_disks && amd_md_slot(v, slot);
	     slot++) {
		for (dev = a->info.devs; dev; dev = dev->next)
			if (dev->disk.raid_disk == slot && is_fd_valid(dev->state_fd))
				break;
		if (dev)
			continue;
		d = amd_find_spare(super, v, slot, &el, &recorded);
		if (d)
			break;
	}
	if (!d)
		return 0;
	/*
	 * md writes the bits at one LBA of every member, the spare too: only
	 * ours (amd_mdbm_place) is in the service area of the spare's element,
	 * any other may be another volume's data.  As md has it now, not as at
	 * open_new: it may have dropped the bitmap since (mdadm --grow
	 * --bitmap=none) - then its headers go, as --update=no-bitmap clears
	 * them - or taken another (bitmap/location written by hand).
	 */
	if (bitmap_at && !amd_mdbm_ours(v, bitmap_at)) {
		if (bitmap_at < 0)
			amd_kmsg("%s: cannot tell where md keeps its bitmap: no spare taken now",
				 a->info.sys_name);
		else
			amd_kmsg("%s: md keeps its bitmap at %+lld, not where AMD leaves room for it: no spare taken",
				 a->info.sys_name, bitmap_at);
		return 0;
	}
	if (!bitmap_at && v->mon.md_bitmap) {
		v->mon.md_bitmap = 0;
		v->mon.mdbm_wipe = 1;
	}
	if (bitmap_at && amd_mdbm_place(super, v, d, &el, recorded) != 0)
		v->mon.mdbm_drop = 1;

	di->disk.number = slot;
	di->disk.raid_disk = slot;
	di->disk.major = d->major;
	di->disk.minor = d->minor;
	di->recovery_start = 0;
	di->data_offset = __le64_to_cpu(el.user_data.offset);
	di->component_size = a->info.component_size;
	di->container_member = a->info.container_member;

	u->type = AMD_UPDATE_SPARE;
	u->vol = a->info.container_member;
	u->slot = slot;
	u->recorded = recorded;
	u->el = el;
	dprintf("array %d member %d: spare %d:%d at %llu\n",
		a->info.container_member, slot, d->major, d->minor,
		(unsigned long long)di->data_offset);
	return 1;
}

/* the disk of the container that is @major:@minor, or NULL */
static struct amd_disk *amd_devt_disk(struct amd_super *super, int major,
				      int minor)
{
	struct amd_disk *d;

	for (d = super->disks; d; d = d->next)
		if (!d->removed && d->major == major && d->minor == minor)
			return d;
	return NULL;
}

/*
 * The element md rebuilds @slot of @v into, on disk @d with user data at
 * @offset: the slot's own, rebuilt in place, or one shaped as the others
 * (amd_spare_extent) that lies free on the disk.  0, or -1.
 */
static int amd_md_element(struct amd_super *super, struct amd_vol *v,
			  int slot, const struct amd_disk *d,
			  unsigned long long offset, struct amd_element *el)
{
	const struct amd_element *model = amd_spare_model(v);
	unsigned long long gap, size, start, end;
	int p = amd_pd_index(super, d->device_id);

	if (slot < v->nel && __le64_to_cpu(v->el[slot].id.id) == d->device_id &&
	    __le64_to_cpu(v->el[slot].user_data.offset) == offset) {
		*el = v->el[slot];
		el->flags = 0;
		return 0;
	}
	if (!model)
		return -1;
	gap = __le64_to_cpu(model->user_data.offset) -
	      __le64_to_cpu(model->allocated.offset);
	size = __le64_to_cpu(model->allocated.size);
	if (offset < gap)
		return -1;
	start = offset - gap;
	if (start + size > amd_pd_capacity(p >= 0 ? super->pd[p] : NULL,
					   d->sectors) ||
	    amd_extent_overlap(super, d->device_id, start, size, &end))
		return -1;
	memset(el, 0, sizeof(*el));
	el->id.id = __cpu_to_le64(d->device_id);
	el->allocated.offset = __cpu_to_le64(start);
	el->allocated.size = model->allocated.size;
	el->user_data.offset = __cpu_to_le64(offset);
	el->user_data.size = model->user_data.size;
	return 0;
}

/*
 * A rebuild md runs on @v that is not recorded (REB-B5): the mdmon before
 * this one gave md the disk (activate_spare) and went - mdmon --takeover,
 * a restart after a crash - before its monitor wrote the start, or could
 * not write it (amd_sync_rebuilds).  Unknown to this mdmon, its end would
 * not be recorded either: the slot's member stays out of service, the
 * spare a spare, and a failure of another member would be recorded as one
 * of the last.  The update activate_spare made goes to the monitor again,
 * from what md runs: a device in a slot it is not the member in service
 * of, or not in sync.  1 if there is one, in @u.  (IMSM does not look
 * for one: imsm_open_new.)
 */
static int amd_unrecorded_rebuild(struct amd_super *super,
				  struct active_array *a, struct amd_vol *v,
				  struct amd_update_spare *u)
{
	struct mdinfo *dev;

	if (v->mon.rebuilding)
		return 0;
	for (dev = a->info.devs; dev; dev = dev->next) {
		int slot = dev->disk.raid_disk;
		struct amd_disk *d;

		if (slot < 0 || !amd_md_slot(v, slot) ||
		    (dev->disk.state & (1 << MD_DISK_FAULTY)))
			continue;
		d = amd_devt_disk(super, dev->disk.major, dev->disk.minor);
		if (!d || (slot < v->nel && amd_slot_usable(v, slot) &&
			   __le64_to_cpu(v->el[slot].id.id) == d->device_id &&
			   (dev->disk.state & (1 << MD_DISK_SYNC))))
			continue;
		if (amd_md_element(super, v, slot, d, dev->data_offset,
				   &u->el) != 0) {
			amd_kmsg("%s: md rebuilds member %d onto %d:%d at %llu, where AMD has no room for it: not recorded",
				 a->info.sys_name, slot, d->major, d->minor,
				 dev->data_offset);
			return 0;
		}
		u->type = AMD_UPDATE_SPARE;
		u->vol = a->info.container_member;
		u->slot = slot;
		return 1;
	}
	return 0;
}

/*
 * mdmon's two threads share the metadata.  The monitor changes the config
 * packet on its own (a failure, a member marked missing, the end of an
 * init or a rebuild - not only in process_update), its records move,
 * while managemon may be walking it in activate_spare or filling a volume
 * in open_new: one of them at a time.  Neither waits for the other with
 * the lock held, and managemon holds it only briefly: it reads a sector or
 * two (the AMD bitmap, a transform log) into mmbuf, what asks the disks
 * themselves runs unlocked (amd_mm_open_new, amd_mm_activate_spare), and so
 * does all it allocates - the monitor would wait for that (amd_mm_room).
 * An atomic flag, not a pthread lock: without USE_PTHREADS the monitor is
 * a clone() of managemon sharing its TLS.
 */
static void amd_lock(struct amd_super *super)
{
	while (__atomic_test_and_set(&super->busy, __ATOMIC_ACQUIRE))
		sleep_for(0, USEC_TO_NSEC(50), true);
}

static void amd_unlock(struct amd_super *super)
{
	__atomic_clear(&super->busy, __ATOMIC_RELEASE);
}

/*
 * managemon, without the lock: md stops the md bitmap of @v (a running
 * array may drop it, bitmap/location "none") and mdmon clears its headers;
 * the volume goes on with the resync policy.  The headers trust no bits
 * before md stops: from then on md sets none, while the AMD bitmap goes
 * on as the headers say (dirty from bit k) - a crash before the monitor
 * clears them would leave the writes of that time out of the resync.  The
 * monitor leaves them alone meanwhile (md_bitmap 0), and writes them anew
 * if md keeps its bitmap after all.
 */
static int amd_mdbm_stop(struct active_array *a, struct amd_vol *v)
{
	struct amd_super *super = a->container->sb;
	unsigned int chunk;
	int rv;

	amd_lock(super);
	v->mon.mdbm_drop = 0;
	chunk = v->mon.md_bitmap;
	v->mon.md_bitmap = 0;
	amd_mdbm_unkept(super, v, chunk);
	amd_unlock(super);
	rv = sysfs_set_str(&a->info, NULL, "bitmap/location", "none");
	amd_lock(super);
	if (rv == 0) {
		v->mon.mdbm_wipe = 1;
	} else {
		v->mon.md_bitmap = chunk;
		v->mon.mdbm_gen = 0;
	}
	amd_unlock(super);
	if (rv == 0)
		amd_kmsg("md bitmap of %s off: the spare has no room at its LBA",
			 a->info.sys_name);
	else
		amd_kmsg("cannot stop the md bitmap of %s: no rebuild onto the spare",
			 a->info.sys_name);
	return rv;
}

/*
 * managemon: the monitor allocates no memory.  Memory is managemon's to
 * allocate ("things which might block such as memory allocation",
 * managemon.c), and IMSM has larger buffers ready (prepare_update) for its
 * monitor to take: an allocation may wait for the kernel to write dirty
 * pages out - to a volume of ours waiting for the monitor (write_pending).
 * The packet grows as the monitor records a volume, a disk, a rebuild or
 * a dedicated spare (amd_packet_insert): before it can, a buffer for the
 * largest packet is put by for the packet to move into.
 * Allocated without the lock: the monitor would wait for it.
 */
static void amd_mm_room(struct amd_super *super)
{
	void *p;
	int want;

	amd_lock(super);
	want = super->packet && !super->next_packet &&
	       super->packet_room < AMD_MAX_PACKET;
	amd_unlock(super);
	if (!want)
		return;
	p = amd_alloc(AMD_MAX_PACKET);
	/* managemon alone puts one by: still none */
	amd_lock(super);
	super->next_packet = p;
	amd_unlock(super);
}

/*
 * managemon: ldbuf takes @len bytes, the LD a rebuild goes into (made by
 * the monitor: amd_rebuild_ld).
 */
static void amd_mm_ldbuf(struct amd_super *super, unsigned int len)
{
	void *p, *old;

	/* managemon alone changes it: read without the lock */
	if (len <= super->ldbuf_room)
		return;
	p = amd_alloc(len);
	if (!p)
		return;
	amd_lock(super);
	old = super->ldbuf;
	super->ldbuf = p;
	super->ldbuf_room = len;
	amd_unlock(super);
	free(old);
}

/*
 * managemon: what asks the disks themselves (ATA IDENTIFY, NVMe Identify -
 * seconds when a disk is slow to answer) runs after the lock is released,
 * on disks opened anew: the monitor would wait for the lock all that time,
 * and may close the container's descriptors meanwhile (a disk removed).
 */
static int amd_mm_open_new(struct supertype *c, struct active_array *a,
			   int inst)
{
	struct amd_super *super = c->sb;
	/* before the lock, as all managemon allocates (amd_mm_room) */
	struct amd_update_spare *u = xcalloc(1, sizeof(*u));
	unsigned int len = 0;
	struct mdinfo *dev;
	int rv, fd, found = 0;

	/* the monitor may record a rebuild of the volume from now on */
	amd_mm_room(super);
	amd_lock(super);
	rv = amd_open_new(c, a, inst);
	if (rv == 0)
		found = amd_unrecorded_rebuild(super, a, &super->vol[inst], u);
	if (found)
		len = amd_ld_size(super->vol[inst].ld) + sizeof(struct amd_element);
	amd_unlock(super);
	if (rv == 0)
		amd_limit_trim(a, NULL);
	/* managemon queues the update (manage_new), as imsm_open_new's */
	if (!found || !c->update_tail) {
		free(u);
		return rv;
	}
	/* the LD and the disk's PD Features, as amd_mm_activate_spare has them */
	amd_mm_ldbuf(super, len);
	for (dev = a->info.devs; dev->disk.raid_disk != u->slot; dev = dev->next)
		;
	fd = amd_dev_open(dev->disk.major, dev->disk.minor, O_RDONLY);
	u->features = amd_pd_features(fd, dev->disk.major, dev->disk.minor);
	close_fd(&fd);
	append_metadata_update(c, u, sizeof(*u));
	return rv;
}

static struct mdinfo *amd_mm_activate_spare(struct active_array *a,
					    struct metadata_update **updates)
{
	struct amd_super *super = a->container->sb;
	/* before the lock, as all managemon allocates (amd_mm_room) */
	struct mdinfo *di = xcalloc(1, sizeof(*di));
	struct amd_update_spare *u = xcalloc(1, sizeof(*u));
	struct metadata_update *mu;
	struct amd_vol *v;
	unsigned int len;
	int fd, found, drop;
	/* md's sysfs before the lock: the monitor is not to wait on md */
	long long bitmap_at = amd_md_bitmap_at(a);

	amd_lock(super);
	found = amd_activate_spare(a, di, u, bitmap_at);
	v = amd_active_vol(a);
	drop = found && v && v->mon.mdbm_drop;
	amd_unlock(super);
	if (!found) {
		amd_limit_trim(a, NULL);
		goto none;
	}
	/*
	 * The spare cannot lie at the md bitmap's LBA: md stops the bitmap
	 * before it takes the disk - without the lock, md waits for the
	 * monitor's writes to end (mddev_suspend).
	 */
	if (drop && amd_mdbm_stop(a, v) != 0)
		goto none;
	fd = amd_dev_open(di->disk.major, di->disk.minor, O_RDONLY);
	u->features = amd_pd_features(fd, di->disk.major, di->disk.minor);
	close_fd(&fd);
	amd_limit_trim(a, di);
	/* the LD the rebuild goes into: at most @v's own and an element */
	amd_lock(super);
	v = amd_active_vol(a);
	len = v ? amd_ld_size(v->ld) + sizeof(struct amd_element) : 0;
	amd_unlock(super);
	amd_mm_ldbuf(super, len);
	/* process_update reads it */
	mu = xcalloc(1, sizeof(*mu));
	mu->buf = (char *)u;
	mu->len = sizeof(*u);
	mu->next = *updates;
	*updates = mu;
	return di;
none:
	free(di);
	free(u);
	return NULL;
}

/* the monitor */
static int amd_mon_set_array_state(struct active_array *a, int consistent)
{
	int rv;

	amd_lock(a->container->sb);
	rv = amd_set_array_state(a, consistent);
	amd_unlock(a->container->sb);
	return rv;
}

static void amd_mon_set_disk(struct active_array *a, int n, int state)
{
	amd_lock(a->container->sb);
	amd_set_disk(a, n, state);
	amd_unlock(a->container->sb);
}

static void amd_mon_sync_metadata(struct supertype *st)
{
	amd_lock(st->sb);
	amd_sync_metadata(st);
	amd_unlock(st->sb);
}

static void amd_mon_process_update(struct supertype *st,
				   struct metadata_update *update)
{
	amd_lock(st->sb);
	amd_process_update(st, update);
	amd_unlock(st->sb);
}

struct superswitch super_amd = {
	.examine_super	= examine_super_amd,
	.brief_examine_super = brief_examine_super_amd,
	.brief_examine_subarrays = brief_examine_subarrays_amd,
	.export_examine_super = export_examine_super_amd,
	.detail_super	= detail_super_amd,
	.brief_detail_super = brief_detail_super_amd,
	.validate_geometry = validate_geometry_amd,
	.default_geometry = default_geometry_amd,
	.write_init_super = write_init_super_amd,
	.add_to_super	= add_to_super_amd,
	.remove_from_super	= remove_from_super_amd,
	.kill_subarray	= kill_subarray_amd,
	.update_subarray = update_subarray_amd,
	.subarray_spare = subarray_spare_amd,
	.load_container	= load_container_amd,
	.match_home	= match_home_amd,
	.uuid_from_super = uuid_from_super_amd,
	.getinfo_super	= getinfo_super_amd,
	.update_super	= update_super_amd,
	.avail_size	= avail_size_amd,
	.compare_super	= compare_super_amd,
	.load_super	= load_super_amd,
	.init_super	= init_super_amd,
	.store_super	= store_super_amd,
	.free_super	= free_super_amd,
	.match_metadata_desc = match_metadata_desc_amd,
	.container_content = container_content_amd,
	.reshape_super	= reshape_super_amd,
	.manage_reshape	= manage_reshape_amd,
	.add_internal_bitmap = add_internal_bitmap_amd,
	.set_bitmap	= set_bitmap_amd,
	.external	= 1,
	.subarray_raid_disks = 1,
	.swapuuid	= 0,
	.name		= "amd",

/* for mdmon */
	.open_new	= amd_mm_open_new,
	.set_array_state = amd_mon_set_array_state,
	.set_disk	= amd_mon_set_disk,
	.sync_metadata	= amd_mon_sync_metadata,
	.process_update	= amd_mon_process_update,
	.prepare_update	= amd_prepare_update,
	.activate_spare	= amd_mm_activate_spare,
};
