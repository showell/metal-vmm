#!/bin/bash
# **QEMU IS THE ORACLE.** This program emulates devices, and the way to know
# whether it emulates them right is to give the same guest the same disk and
# require the same words out of it — from a device model that thousands of
# people rely on and one written here in an afternoon.
#
#   ./check.sh
#
# Each probe runs twice, each side on its own fresh copy of the image, and the
# serial output is compared byte for byte. Two probes are compared by verdict
# alone, and for opposite reasons: `rng`'s output is random on purpose, and
# `clock`'s output is a MEASUREMENT OF THE MACHINE IT RAN ON — QEMU's guest
# reads today's date off the host and times a real processor, ours reads noon
# on 2026-09-18 and times a processor that runs at exactly 2.5 GHz. What has to
# agree is the guest's own cross-checks: the interval timer against the
# real-time clock, all four register formats against each other, and the wall
# clock against the edge it was anchored to.
#
# **QEMU HERE EMULATES THE PROCESSOR IN SOFTWARE** (no `-accel kvm`, so its
# default, TCG). That keeps the oracle independent of the hardware this program
# drives, and it makes the two timings different kinds of number: a device
# access costs QEMU a function call and costs us a full exit through KVM, while
# plain computation runs at the processor's speed here and at an interpreter's
# under QEMU.
#
# Reproducibility is a different question, and QEMU cannot answer it about
# itself: that one is same.sh.
#
# The probes that need a step between boots — a Linux mount writing a file the
# next boot reads — belong to gopher-metal's own runner and are not here.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUESTS="${GUESTS:-$HOME/showell_repos/gopher-metal/probe}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

VMM="$HERE/zig-out/bin/metal-vmm"
[ -x "$VMM" ] || { echo "no $VMM; run: zig build"; exit 1; }

# probe:volume. Both volumes are made below, fresh for the run.
CASES="block:fat16 vfat:fat16 net:fat16 http:fat16 stdhttp:fat16 rng:fat16 clock:fat16 \
vfat:fat32 append:fat32"

# **FAT32, ON A VOLUME MADE HERE**, as gopher-metal's runner makes its own
# (`FAT=32 probe/run.sh`): 512-byte sectors and clusters, enough clusters to be
# FAT32, and a FAT bigger than one device request. Prod's data is FAT32, so
# this is the format the devices here must not get wrong. One format, copied to
# both sides: mkfs stamps the volume with the time it ran.
# **FAT16 the same way**: 32 MB, 512-byte sectors, bare (no partition table),
# the disk every other probe boots with.
command -v mkfs.vfat > /dev/null || { echo "FAIL mkfs.vfat is not installed, and every case needs it"; exit 1; }
mkfs.vfat -F 32 -S 512 -s 1 -n GOPHER -C "$WORK/fat32.blank" 40960 > /dev/null 2>&1 \
    || { echo "FAIL mkfs.vfat could not make the FAT32 volume"; exit 1; }
mkfs.vfat -F 16 -S 512 -n GOPHER -C "$WORK/fat16.blank" 32768 > /dev/null 2>&1 \
    || { echo "FAIL mkfs.vfat could not make the FAT16 volume"; exit 1; }

failed=0
for one in $CASES; do
    probe="${one%%:*}"
    image="$WORK/fat16.blank"
    name="$probe"
    if [ "${one##*:}" = fat32 ]; then
        image="$WORK/fat32.blank"
        name="$probe/fat32"
    fi
    elf="$GUESTS/$probe.elf"
    [ -f "$elf" ] || { echo "SKIP $probe (no $elf)"; continue; }

    # **THE HTTP PROBES NEED A CLIENT.** Ours is the peer inside the program;
    # QEMU's is curl through a forwarded port. Both fetch the same path, and
    # what each one got is compared as one more line of output.
    fetch=""
    case "$probe" in http|stdhttp) fetch="/probe" ;; esac

    cp "$image" "$WORK/ours.img"
    began=$(date +%s%N)
    "$VMM" "$elf" "$WORK/ours.img" "" "$fetch" > "$WORK/ours.txt" 2>&1
    ours=$?
    ours_ms=$(( ($(date +%s%N) - began) / 1000000 ))

    cp "$image" "$WORK/qemu.img"
    began=$(date +%s%N)
    netdev="user,id=n0"
    port=$(( 20000 + RANDOM % 20000 ))
    [ -n "$fetch" ] && netdev="user,id=n0,hostfwd=tcp:127.0.0.1:$port-:80"
    qemu-system-x86_64 -M microvm,rtc=on,pit=on -kernel "$elf" -nographic -no-reboot -m 512 \
        -global virtio-mmio.force-legacy=false \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
        -drive id=d,file="$WORK/qemu.img",format=raw,if=none \
        -device virtio-blk-device,drive=d \
        -netdev "$netdev" -device virtio-net-device,netdev=n0 \
        -cpu max -device virtio-rng-device > "$WORK/qemu.raw" 2>&1 &
    qemu_pid=$!
    if [ -n "$fetch" ]; then
        code=$(curl -sS --max-time 30 --retry 40 --retry-delay 1 --retry-connrefused \
            -o "$WORK/body" -w '%{http_code}' "http://127.0.0.1:$port$fetch" 2>/dev/null)
    fi
    wait $qemu_pid
    # **QEMU'S EXIT CODE IS NOT THE GUEST'S**: isa-debug-exit ends it with
    # `code << 1 | 1`, so the guest's 0 arrives as 1.
    theirs=$(( ($? - 1) / 2 ))
    [ -n "$fetch" ] && printf 'peer: %s "%s"\n' "$code" "$(cat "$WORK/body")" >> "$WORK/qemu.raw"
    qemu_ms=$(( ($(date +%s%N) - began) / 1000000 ))
    # **ITS FIRMWARE TALKS ON THE SAME SERIAL PORT.** SeaBIOS prints a banner
    # and escape codes before handing the machine over, and the last thing it
    # says is that it is booting. Everything after that line is the guest.
    # It does not end that line, either: the guest's first words continue it.
    awk '!started && /Booting from ROM/ { sub(/^.*Booting from ROM\.*/, ""); started = 1; if (length($0)) print; next }
         started { print }' "$WORK/qemu.raw" | sed 's/\r$//' > "$WORK/qemu.txt"

    # **WHAT A RUN COST** is this machine's account of itself (cost.zig), which
    # QEMU has no line for: left out of the comparison like the shape below.
    #
    # **THE BLOCK PROBE PRINTS THE MACHINE'S SHAPE**, not just its answer: which
    # slots hold devices, and where. QEMU fills its window from the top and has
    # a random-number device too; this one puts a disk in the first slot. That
    # is a difference between two machines, not between two device models, so
    # those lines are left out of the comparison and everything else — the
    # capacity, the boot signature, the sector written and read back — is not.
    #
    # **APPEND STAMPS ITS FILES WITH THE WALL CLOCK**, which is noon on
    # 2026-09-18 here and today under QEMU, by design (README: "the wall clock
    # is a decision"). So its clock line is left out, and its two disks, which
    # differ in those stamps, are each judged by fsck.vfat instead of by each
    # other; vfat/fat32 is the byte-for-byte FAT32 comparison.
    stamped=no
    [ "$probe" = append ] && stamped=yes
    for side in ours qemu; do
        grep -av "^  slot \|^  device at \|^  wall clock \|^metal-vmm: cost: " "$WORK/$side.txt" > "$WORK/$side.cmp"
    done

    if [ "$probe" = rng ] || [ "$probe" = clock ]; then
        # Random by design, or a measurement of two different machines by
        # design; either way, what must agree is the verdict.
        a=$(tail -1 "$WORK/ours.txt"); b=$(tail -1 "$WORK/qemu.txt")
        [ "$a" = "$b" ] && [ "$ours" = "$theirs" ] && same=yes || same=no
    elif cmp -s "$WORK/ours.cmp" "$WORK/qemu.cmp" && [ "$ours" = "$theirs" ]; then
        same=yes
    else
        same=no
    fi

    if [ "$same" = yes ]; then
        printf 'PASS %-11s same words, same verdict (%s ms here, %s ms under QEMU, software CPU)\n' \
            "$name" "$ours_ms" "$qemu_ms"
    else
        failed=1
        printf 'FAIL %-11s ours exited %s, QEMU %s\n' "$name" "$ours" "$theirs"
        diff -a "$WORK/qemu.cmp" "$WORK/ours.cmp" | head -12 | sed 's/^/       /'
    fi

    # **AND THE DISK EACH ONE LEFT BEHIND.** A device that answers right and
    # writes the wrong sector would pass everything above.
    if [ $stamped = no ] && ! cmp -s "$WORK/ours.img" "$WORK/qemu.img"; then
        failed=1
        echo "     $name: the two disks differ after the run"
        cmp "$WORK/ours.img" "$WORK/qemu.img" | head -3 | sed 's/^/       /'
    fi
    # A volume both sides wrote alike could still be wrong alike: dosfstools
    # judges what each side wrote.
    if [ "$image" = "$WORK/fat32.blank" ]; then
        for side in ours qemu; do
            fsck.vfat -n "$WORK/$side.img" > "$WORK/fsck.txt" 2>&1 && continue
            failed=1
            echo "     $name: fsck.vfat rejects the volume written by $side"
            grep -av "^fsck.fat\|^$" "$WORK/fsck.txt" | head -5 | sed 's/^/       /'
        done
    fi
done

[ $failed = 0 ] && echo "every probe said the same thing both ways" || echo "something differed"
exit $failed
