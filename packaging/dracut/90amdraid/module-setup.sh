#!/bin/bash
# dracut module amdraid: AMD RAIDXpert2 (RAIDCore) volumes, mdadm --metadata=amd, in the initramfs.
# libblkid does not know the AMD label, so the mdraid module neither includes itself for such a root
# (its check() looks for *_raid_member) nor assembles the disks (its rule keys on ID_FS_TYPE): this
# module pulls mdraid in and adds a rule that offers every whole disk to mdadm --incremental; mdadm
# leaves disks without the label alone.  Install into /usr/lib/dracut/modules.d/90amdraid/.

# Is block device $1 (a path, or MAJ:MIN as for_each_host_dev_and_slaves_all gives it) an md array of
# an AMD container (or such a container), or a partition of one?
amdraid_dev() {
    local d mv c
    if [[ $1 =~ ^[0-9]+:[0-9]+$ ]]; then
        d=$(readlink -f "/sys/dev/block/$1") || return 1
    else
        d=$(readlink -f "$1") || return 1
    fi
    d=${d##*/}
    [[ -e /sys/class/block/$d/partition ]] && d=$(basename "$(readlink -f "/sys/class/block/$d/..")")
    [[ -r /sys/block/$d/md/metadata_version ]] || return 1
    mv=$(< "/sys/block/$d/md/metadata_version")
    [[ $mv == external:amd ]] && return 0
    [[ $mv == external:/* ]] || return 1
    c=${mv#external:/}
    c=${c%%/*}
    [[ -r /sys/block/$c/md/metadata_version ]] && [[ $(< "/sys/block/$c/md/metadata_version") == external:amd ]]
}

# called by dracut
check() {
    require_binaries mdadm || return 1
    [[ $hostonly ]] || [[ $mount_needs ]] && {
        for_each_host_dev_and_slaves_all amdraid_dev && return 0
        return 255
    }
    return 0
}

# called by dracut
depends() {
    echo mdraid
    return 0
}

# called by dracut
install() {
    inst_rules "$moddir/64-amd-raid-assembly.rules"
}
