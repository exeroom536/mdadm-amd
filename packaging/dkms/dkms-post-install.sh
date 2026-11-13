#!/bin/sh
# dkms-post-install.sh <dkms_tree> <module> <kernelver> <arch>: put the kernel's own md_mod
# back where DKMS took it from.  DKMS (3.x, do_install) moves the one in-tree module of the
# same name into original_module/ as it installs ours, so the kernel package misses a file
# (pacman -Qk).  Ours still wins with it back: depmod, run by DKMS after this script, takes
# updates/ before the kernel's own modules ("search updates ... built-in", depmod.d).  The
# archived copy stays: when ours is removed, DKMS moves it back over this one.
dir=$1/$2/original_module/$3/$4
for origin in "$dir"/*.origin; do
	[ -f "$origin" ] || continue
	to=$(head -n 1 "$origin")
	case $to in
	/lib/modules/"$3"/* | /usr/lib/modules/"$3"/*) ;;
	*) continue ;;
	esac
	[ -e "$to" ] || cp -p "${origin%.origin}" "$to"
done
exit 0
