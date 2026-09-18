#!/bin/bash
# **QEMU IS THE ORACLE.** This program emulates devices, and the way to know
# whether it emulates them right is to give the same guest the same disk and
# require the same words out of it — from a device model that thousands of
# people rely on and one written here in an afternoon.
#
#   ./check.sh
#
# Each probe runs twice, each side on its own fresh copy of the image, and the
# serial output is compared byte for byte. `rng` is the one exception: its
# output is random on purpose, so only its verdict is compared.
#
# The probes that need a step between boots — a Linux mount writing a file the
# next boot reads — belong to gopher-metal's own runner and are not here.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUESTS="${GUESTS:-$HOME/showell_repos/gopher-metal/probe}"
IMAGES="${IMAGES:-$HOME/showell_repos/cobblestone-u61/codex/test}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

VMM="$HERE/zig-out/bin/metal-vmm"
[ -x "$VMM" ] || { echo "no $VMM; run: zig build"; exit 1; }

# probe:image
CASES="block:fat16-write fat16:fat16-list fat16write:fat16-write vfat:fat16-write \
net:fat16-write http:fat16-write stdhttp:fat16-write rng:fat16-write"

failed=0
for one in $CASES; do
    probe="${one%%:*}"
    image="$IMAGES/${one##*:}.disk"
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

    # **THE BLOCK PROBE PRINTS THE MACHINE'S SHAPE**, not just its answer: which
    # slots hold devices, and where. QEMU fills its window from the top and has
    # a random-number device too; this one puts a disk in the first slot. That
    # is a difference between two machines, not between two device models, so
    # those lines are left out of the comparison and everything else — the
    # capacity, the boot signature, the sector written and read back — is not.
    for side in ours qemu; do
        grep -av "^  slot \|^  device at " "$WORK/$side.txt" > "$WORK/$side.cmp"
    done

    if [ "$probe" = rng ]; then
        # Random by design; what must agree is the verdict.
        a=$(tail -1 "$WORK/ours.txt"); b=$(tail -1 "$WORK/qemu.txt")
        [ "$a" = "$b" ] && [ "$ours" = "$theirs" ] && same=yes || same=no
    elif cmp -s "$WORK/ours.cmp" "$WORK/qemu.cmp" && [ "$ours" = "$theirs" ]; then
        same=yes
    else
        same=no
    fi

    if [ "$same" = yes ]; then
        printf 'PASS %-11s same words, same verdict (%s ms here, %s ms under QEMU)\n' \
            "$probe" "$ours_ms" "$qemu_ms"
    else
        failed=1
        printf 'FAIL %-11s ours exited %s, QEMU %s\n' "$probe" "$ours" "$theirs"
        diff -a "$WORK/qemu.cmp" "$WORK/ours.cmp" | head -12 | sed 's/^/       /'
    fi

    # **AND THE DISK EACH ONE LEFT BEHIND.** A device that answers right and
    # writes the wrong sector would pass everything above.
    if ! cmp -s "$WORK/ours.img" "$WORK/qemu.img"; then
        failed=1
        echo "     $probe: the two disks differ after the run"
        cmp "$WORK/ours.img" "$WORK/qemu.img" | head -3 | sed 's/^/       /'
    fi
done

[ $failed = 0 ] && echo "every probe said the same thing both ways" || echo "something differed"
exit $failed
