#!/bin/bash
# **THE REAL SERVER AS THE GUEST**, and the same page fetched twice.
#
#   ./site.sh [path]          # / by default
#   ./site.sh all             # every route below, one boot each side per route
#
# `gopher.elf` is angry-gopher's own route table compiled for a machine with no
# operating system: its data on a FAT16 volume, its clocks from its own
# hardware, std.http.Server on top of a TCP stack it brought with it. It serves
# `requests = N` from gopher-metal.conf on the volume and stops.
#
# The page it serves here, to the TCP client in peer.zig, must be the page it
# serves under QEMU to curl — byte for byte. The guest's own closing counters
# have to agree too: a retransmission on one side and not the other is a
# difference between the two hypervisors, not between two runs.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUESTS="${GUESTS:-$HOME/showell_repos/gopher-metal/probe}"
# The staged GPT + FAT16 volume with the site on it, as judge_gopher.py builds
# it (that needs a loop mount, and so sudo; this does not, it only reads one).
SITE="${SITE:-$HOME/build/gopher-metal/probe/gopher/pristine.img}"
PATH_WANTED="${1:-/}"

# Cookie-free GET routes, from judge_gopher.py's own list. /version is left out
# on purpose: it reports live memory and names the build, so the two sides
# differ by design.
ROUTES="/ /driving /tutorial /chess /steve-resume /steve-resume.pdf \
/safari_download /nope /drivingX /login /login/full /admin"
VMM="$HERE/zig-out/bin/metal-vmm"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
[ -x "$VMM" ] || { echo "no $VMM; run: zig build"; exit 1; }
[ -f "$GUESTS/gopher.elf" ] || { echo "no $GUESTS/gopher.elf; in gopher-metal: ./port.sh && zig build gopher"; exit 1; }
[ -f "$SITE" ] || { echo "no volume at $SITE; set SITE=<image with the site on it>"; exit 1; }

failed=0

compare() {
  local PATH_WANTED="$1"
cp "$SITE" "$WORK/ours.img"
began=$(date +%s%N)
PEER_BODY="$WORK/ours.body" "$VMM" "$GUESTS/gopher.elf" "$WORK/ours.img" "" "$PATH_WANTED" > "$WORK/ours.log" 2>&1
ours=$?
ours_ms=$(( ($(date +%s%N) - began) / 1000000 ))

cp "$SITE" "$WORK/qemu.img"
began=$(date +%s%N)
port=$(( 20000 + RANDOM % 20000 ))
qemu-system-x86_64 -M microvm,rtc=on,pit=on -kernel "$GUESTS/gopher.elf" -nographic -no-reboot -m 512 \
    -global virtio-mmio.force-legacy=false \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    -drive id=d,file="$WORK/qemu.img",format=raw,if=none -device virtio-blk-device,drive=d \
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$port-:80" -device virtio-net-device,netdev=n0 \
    -cpu max -device virtio-rng-device > "$WORK/qemu.log" 2>&1 &
qemu_pid=$!
code=$(curl -sS --max-time 60 --retry 60 --retry-delay 1 --retry-connrefused \
    -o "$WORK/qemu.body" -w '%{http_code}' "http://127.0.0.1:$port$PATH_WANTED" 2>/dev/null)
wait $qemu_pid
theirs=$(( ($? - 1) / 2 ))
qemu_ms=$(( ($(date +%s%N) - began) / 1000000 ))

  local status bytes note
  status=$(sed -n 's/^peer: \([0-9]*\).*/\1/p' "$WORK/ours.log")
  bytes=$(wc -c < "$WORK/ours.body")
  note="same"
  cmp -s "$WORK/ours.body" "$WORK/qemu.body" || { failed=1; note="THE BODIES DIFFER"; }
  { [ "$status" = "$code" ] && [ -n "$status" ]; } || { failed=1; note="$note, STATUS $status vs $code"; }
  [ "$ours" = "$theirs" ] || { failed=1; note="$note, EXIT $ours vs $theirs"; }
  # **THE GUEST'S OWN ACCOUNT OF THE CONNECTION**, which is where a difference
  # between the two hypervisors shows up before it shows up in the page.
  local a b
  a=$(grep -a '^  tcp:' "$WORK/ours.log"); b=$(grep -a '^  tcp:' "$WORK/qemu.log")
  [ "$a" = "$b" ] || { failed=1; note="$note, A DIFFERENT CONNECTION"; }
  printf '  %-18s %-4s %7s bytes  %-22s %5s ms here, %5s under QEMU\n' \
      "$PATH_WANTED" "$status" "$bytes" "$note" "$ours_ms" "$qemu_ms"
}

echo "the same request, answered twice — here, and under QEMU to curl:"
if [ "$PATH_WANTED" = all ]; then
    for one in $ROUTES; do compare "$one"; done
else
    compare "$PATH_WANTED"
fi

[ $failed = 0 ] && echo "every route: the same page, and the same connection, both ways" || echo "something differed"
exit $failed
