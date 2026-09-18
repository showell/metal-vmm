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
set -u
IMAGE="${1:?usage: sound.sh <image>}"
# The first partition, where judge_gopher.py's staging puts it.
FIRST_LBA="${FIRST_LBA:-2048}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
dd if="$IMAGE" of="$WORK/part.img" bs=512 skip="$FIRST_LBA" status=none
out=$(fsck.vfat -n "$WORK/part.img" 2>&1)
echo "$out" | tail -1 | sed 's/.*img: /  /'
# Anything that is not the version line, the tally or the headings is a
# complaint, and a complaint is the answer.
complaints=$(echo "$out" | grep -v "^fsck.fat\|files, .*clusters\|^Checking\|^$")
if [ -n "$complaints" ]; then
    echo "$complaints" | sed 's/^/  /'
    exit 1
fi
echo "  sound"
