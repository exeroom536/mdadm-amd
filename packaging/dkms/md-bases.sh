#!/bin/sh
# md-bases.sh <clone of linux stable> [series ...]: which releases share the same drivers/md files of the
# DKMS package (md.c md.h md-bitmap.c md-bitmap.h md-llbitmap.c md-cluster.h). One line per run of
# consecutive tags with the same blobs ("v7.3..v7.3.3 13884adc"). The bases and their regexes in
# packaging/arch/PKGBUILD (_mdbases, _mdkvers) come from here. All tags are needed:
# git fetch stable 'refs/tags/v7.3*:refs/tags/v7.3*'.
# Example: sh md-bases.sh ~/src/linux 6.18 7.3
git_dir=${1:?clone of linux stable}
shift
[ $# -gt 0 ] || set -- 6.18 7.3
for s in "$@"; do
	git -C "$git_dir" tag -l "v$s" "v$s.*" | grep -v -- -rc | sort -V
done | while read -r t; do
	h=
	for f in md.c md.h md-bitmap.c md-bitmap.h md-llbitmap.c md-cluster.h; do
		h="$h $(git -C "$git_dir" rev-parse -q --verify "$t:drivers/md/$f" || echo none)"
	done
	echo "$t $(echo "$h" | md5sum | cut -c1-8)"
done | awk '$2 != p { if (n) print s ".." l " " p; s = $1; n = 1 } { l = $1; p = $2 } END { if (n) print s ".." l " " p }'
