#!/bin/bash
# **THE OTHER ORACLE: YESTERDAY'S RUN.**
#
# check.sh asks whether this program is RIGHT, by requiring QEMU to agree with
# it. This one asks whether it is REPRODUCIBLE, which QEMU cannot answer about
# itself: the same guest, run twice here, has to produce the same words, the
# same exit code, and the same disk — byte for byte, including every number the
# guest measured about its own machine.
#
#   ./same.sh
#
# The `clock` probe is the one that makes this a real question. It prints the
# rate it measured for its own processor and the wall-clock time it read off
# the chip, and until the clock in clock.zig was ours, both were a measurement
# of this box on this afternoon and no two runs agreed.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUESTS="${GUESTS:-$HOME/showell_repos/gopher-metal/probe}"
IMAGES="${IMAGES:-$HOME/showell_repos/cobblestone-u61/codex/test}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

VMM="$HERE/zig-out/bin/metal-vmm"
[ -x "$VMM" ] || { echo "no $VMM; run: zig build"; exit 1; }

# probe:image
CASES="clock:fat16-list block:fat16-write fat16:fat16-list fat16write:fat16-write \
vfat:fat16-write net:fat16-write http:fat16-write stdhttp:fat16-write"

failed=0
for one in $CASES; do
    probe="${one%%:*}"
    image="$IMAGES/${one##*:}.disk"
    elf="$GUESTS/$probe.elf"
    [ -f "$elf" ] || { echo "SKIP $probe (no $elf)"; continue; }
    fetch=""
    case "$probe" in http|stdhttp) fetch="/probe" ;; esac

    for run in a b; do
        cp "$image" "$WORK/$run.img"
        began=$(date +%s%N)
        "$VMM" "$elf" "$WORK/$run.img" "" "$fetch" > "$WORK/$run.txt" 2>&1
        eval "code_$run=$?"
        eval "ms_$run=$(( ($(date +%s%N) - began) / 1000000 ))"
    done

    if ! cmp -s "$WORK/a.txt" "$WORK/b.txt"; then
        failed=1
        printf 'DIFFERS %-11s the two runs said different things\n' "$probe"
        diff -a "$WORK/a.txt" "$WORK/b.txt" | head -8 | sed 's/^/          /'
    elif [ "$code_a" != "$code_b" ]; then
        failed=1
        printf 'DIFFERS %-11s exited %s, then %s\n' "$probe" "$code_a" "$code_b"
    elif ! cmp -s "$WORK/a.img" "$WORK/b.img"; then
        failed=1
        printf 'DIFFERS %-11s same words, but the two disks are not the same disk\n' "$probe"
    else
        printf 'SAME    %-11s %s lines, verdict %s (%s ms, then %s ms)\n' \
            "$probe" "$(wc -l < "$WORK/a.txt")" "$code_a" "$ms_a" "$ms_b"
    fi
done

# **AND WHAT THE CLOCK PROBE ACTUALLY SAID**, because "the same twice" is only
# interesting when the thing being repeated is a measurement.
if [ -f "$GUESTS/clock.elf" ]; then
    "$VMM" "$GUESTS/clock.elf" > "$WORK/clock.txt" 2>&1
    grep -a '^tsc_hz \|^unix \|^civil ' "$WORK/clock.txt" | sed 's/^/        /'
fi

[ $failed = 0 ] && echo "every probe ran the same way twice" || echo "something drifted"
exit $failed
