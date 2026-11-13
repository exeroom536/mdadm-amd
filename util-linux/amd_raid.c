/*
 * SPDX-License-Identifier: LGPL-2.1-or-later
 *
 * Copyright (C) 2026 exeroom536 <352890649+exeroom536@users.noreply.github.com>
 *
 * AMD RAIDXpert2 ("RAIDCore") is the RAID of AMD chipsets: the BIOS and the
 * AMD drivers keep a label on every disk they initialized, at LBA 0x5000
 * (512-byte sectors), followed by the commit block and the configuration
 * ring up to LBA 0x6000.  mdadm assembles these arrays (metadata=amd).
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <stdint.h>

#include "superblocks.h"

#define AMD_LABEL_OFFSET	(0x5000ULL * 0x200)
#define AMD_AREA_END		(0x6000ULL * 0x200)
#define AMD_VERSION		0x30000

struct amd_label {
	uint64_t	checksum;	/* over bytes 0x08..0x1ff */
	uint8_t		ident[8];	/* "RAIDCore" */
	uint64_t	device_id;
	uint64_t	commit_offset;	/* LBA of the commit block */
	uint64_t	ring_offset;	/* LBA of the configuration ring */
	uint32_t	ring_size;	/* sectors */
	uint32_t	version;
	uint8_t		reserved[0x200 - 0x30];
} __attribute__((packed));

/*
 * XOR of the little-endian 64-bit words, each with two of its 16-bit lanes
 * swapped first: the lanes given by the low two bits of the word and of the
 * sum so far, or, when those are the same, by the word's index.
 */
static uint64_t amd_checksum(const unsigned char *buf, size_t len)
{
	uint64_t sum = 0;
	size_t i;

	for (i = 0; i < len / 8; i++) {
		uint64_t w, la, lb;
		unsigned int a, b;

		memcpy(&w, buf + i * 8, sizeof(w));
		w = le64_to_cpu(w);
		a = w & 3;
		b = sum & 3;
		if (a == b) {
			a = i & 3;
			b = (i + 1) & 3;
		}
		la = (w >> (16 * a)) & 0xffff;
		lb = (w >> (16 * b)) & 0xffff;
		w &= ~((0xffffULL << (16 * a)) | (0xffffULL << (16 * b)));
		w |= (lb << (16 * a)) | (la << (16 * b));
		sum ^= w;
	}
	return sum;
}

static int probe_amdraid(blkid_probe pr, const struct blkid_idmag *mag)
{
	const struct amd_label *lb;
	uint32_t version;

	if (!S_ISREG(pr->mode) && !blkid_probe_is_wholedisk(pr))
		return 1;

	lb = blkid_probe_get_sb(pr, mag, struct amd_label);
	if (!lb)
		return errno ? -errno : 1;

	version = le32_to_cpu(lb->version);
	if (version != AMD_VERSION)
		return 1;
	if (!blkid_probe_verify_csum(pr,
			amd_checksum((const unsigned char *) lb + 8,
				     sizeof(*lb) - 8),
			le64_to_cpu(lb->checksum)))
		return 1;

	if (blkid_probe_sprintf_version(pr, "%u.%u",
			version >> 16, version & 0xffff) != 0)
		return 1;
	return 0;
}

const struct blkid_idinfo amdraid_idinfo = {
	.name		= "amd_raid_member",
	.usage		= BLKID_USAGE_RAID,
	.minsz		= AMD_AREA_END,
	.probefunc	= probe_amdraid,
	.magics		= {
		{ .magic = "RAIDCore", .len = 8,
		  .kboff = AMD_LABEL_OFFSET >> 10, .sboff = 8 },
		{ NULL }
	}
};
