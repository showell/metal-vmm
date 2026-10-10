#!/bin/bash
# **IS THE VOLUME STILL A FILESYSTEM?**
#
#   ./sound.sh <image>        # a whole disk: the first partition is checked
#
# "It mounted and answered" is a weaker question than "is it sound". A guest
# that reports a write failure honestly still leaves whatever it had half done
# — an allocated cluster nothing points at, a long file name with no entry
# behind it — and FAT16 has no journal to undo it with. This machine has no
# fsck of its own, so Linux's is borrowed to ask.
#
# Reads only: `-n` answers no to every repair.
#
# **WHAT A STOP LEAVES** (`STOP_LEAVES=1`, for a disk whose power was cut
# mid-write): FAT has no journal, so a cut between an operation's writes
# leaves a cluster allocated that nothing points at, a long name's parts
# with no entry after them, or the two FATs apart. gopher-metal's own check
# counts exactly these as what a stop leaves, not damage (disk_fat.zig
# `Problem.damage`), and handles each at the next boot. With it, those three
# are not complaints; anything else still is.
set -u
IMAGE="${1:?usage: sound.sh <image>}"
# The first partition, where judge_gopher.py's staging puts it.
FIRST_LBA="${FIRST_LBA:-2048}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
dd if="$IMAGE" of="$WORK/part.img" bs=512 skip="$FIRST_LBA" status=none conv=sparse
out=$(fsck.vfat -n "$WORK/part.img" 2>&1)
echo "$out" | tail -1 | sed 's/.*img: /  /'
# Anything that is not the version line, the tally or the headings is a
# complaint, and a complaint is the answer. Except one: FAT32's FSInfo free
# count marked unknown (0xFFFFFFFF), which the spec allows and gopher-metal
# does on purpose at a volume's first change after mount (disk_fat.zig
# `forgetFsInfo`). A count that is set and wrong is still a complaint
# ("Free cluster summary wrong").
complaints=$(echo "$out" | grep -v "^fsck.fat\|files, .*clusters\|^Checking\|^$\|^Free cluster summary uninitialized (should be [0-9]*)$")
if [ -n "${STOP_LEAVES:-}" ] && [ -n "$complaints" ]; then
    left=$(echo "$complaints" | grep -c "^Reclaimed [0-9]* unused clusters\? (\|^Orphaned long file name part \|^FATs differ but appear to be intact\.$")
    complaints=$(echo "$complaints" | grep -v "^Reclaimed [0-9]* unused clusters\? (\|^Orphaned long file name part \|^  *Auto-deleting\.$\|^FATs differ but appear to be intact\.$\|^  *Using first FAT\.$\|^Leaving filesystem unchanged\.$")
    # What the stop left is said, line by line, before the verdict: the judge
    # holds it to one operation's worth beside the kernel's own count
    # (sweep.sh `stop_leftovers`), never excuses it unread.
    [ "$left" = 0 ] || [ -n "$complaints" ] || {
        echo "$out" | grep "^Reclaimed [0-9]* unused clusters\? (\|^Orphaned long file name part \|^FATs differ but appear to be intact\.$" | sed 's/^/  /'
        echo "  sound but for what a stop leaves ($left)"; exit 0; }
fi
if [ -n "$complaints" ]; then
    echo "$complaints" | sed 's/^/  /'
    exit 1
fi
echo "  sound"
