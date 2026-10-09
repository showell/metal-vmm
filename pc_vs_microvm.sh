#!/bin/bash
# **THE PC-SHAPED MACHINE: THE REAL SERVER HALTS, AND WAKES ON INTERRUPTS.**
#
#   ./pc_vs_microvm.sh [path]          # / by default
#   ./pc_vs_microvm.sh all             # every route site.sh fetches
#
# `TRANSPORT=pci` puts the devices on a PCI bus with an APIC (pci.zig,
# apic.zig), which is what makes gopher.elf rest between frames as it does on
# a droplet: `sti; hlt`, woken by the card's MSI-X message or the APIC timer.
# With a wire that takes `LATENCY_US` (default 5000) each way, it has
# something to wait for. For each route, three things must hold:
#
#   - the page is the page the microvm-shaped machine serves (the one
#     site.sh holds to QEMU's), status and body;
#   - the run is the same run twice: serial log, disk and page, byte for byte;
#   - the guest halted and took interrupts, timer and MSI-X both. A run that
#     never halted proves nothing here.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUESTS="${GUESTS:-$HOME/showell_repos/gopher-metal/probe}"
SITE="${SITE:-$HOME/build/gopher-metal/probe/gopher/pristine.img}"
LATENCY_US="${LATENCY_US:-5000}"
PATH_WANTED="${1:-/}"
ROUTES="/ /driving /tutorial /chess /steve-resume /steve-resume.pdf \
/safari_download /nope /drivingX /login /login/full /admin"
VMM="$HERE/zig-out/bin/metal-vmm"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
[ -x "$VMM" ] || { echo "no $VMM; run: zig build"; exit 1; }
[ -f "$GUESTS/gopher.elf" ] || { echo "no $GUESTS/gopher.elf; in gopher-metal: ./port.sh && zig build gopher"; exit 1; }
[ -f "$SITE" ] || { echo "no volume at $SITE; set SITE=<image with the site on it>"; exit 1; }

failed=0

# run <name> <path> [VAR=value ...]: one boot, its serial log, disk and page.
run() {
  local name="$1" path="$2"; shift 2
  cp "$SITE" "$WORK/$name.img"
  env "$@" PEER_BODY="$WORK/$name.body" "$VMM" "$GUESTS/gopher.elf" "$WORK/$name.img" "" "$path" > "$WORK/$name.log" 2>&1
  echo $? > "$WORK/$name.exit"
}

check() {
  local path="$1" note="same"
  run plain "$path"
  run pc1 "$path" TRANSPORT=pci WIRE_LATENCY_US="$LATENCY_US"
  run pc2 "$path" TRANSPORT=pci WIRE_LATENCY_US="$LATENCY_US"
  local status plain_status
  status=$(sed -n 's/^peer: \([0-9]*\).*/\1/p' "$WORK/pc1.log")
  plain_status=$(sed -n 's/^peer: \([0-9]*\).*/\1/p' "$WORK/plain.log")
  { [ -n "$status" ] && [ "$status" = "$plain_status" ] && cmp -s "$WORK/pc1.body" "$WORK/plain.body"; } ||
    { failed=1; note="NOT THE PAGE: status $status vs $plain_status"; }
  { cmp -s "$WORK/pc1.log" "$WORK/pc2.log" && cmp -s "$WORK/pc1.img" "$WORK/pc2.img" && cmp -s "$WORK/pc1.body" "$WORK/pc2.body"; } ||
    { failed=1; note="$note, NOT THE SAME RUN TWICE"; }
  [ "$(cat "$WORK/pc1.exit")" = "$(cat "$WORK/plain.exit")" ] || { failed=1; note="$note, EXIT $(cat "$WORK/pc1.exit") vs $(cat "$WORK/plain.exit")"; }
  # "metal-vmm: H halts skipped N ms; I interrupts taken (T timer, M MSI-X messages); ..."
  local line timer msix
  line=$(grep -a '^metal-vmm: .* halts skipped' "$WORK/pc1.log")
  timer=$(echo "$line" | sed -n 's/.*(\([0-9]*\) timer.*/\1/p')
  msix=$(echo "$line" | sed -n 's/.*timer, \([0-9]*\) MSI-X.*/\1/p')
  { [ "${timer:-0}" -gt 0 ] && [ "${msix:-0}" -gt 0 ]; } || { failed=1; note="$note, NO REST (timer ${timer:-?}, MSI-X ${msix:-?})"; }
  printf '  %-18s %-4s %7s bytes  %-12s %s\n' "$path" "$status" "$(wc -c < "$WORK/pc1.body")" "$note" "${line#metal-vmm: }"
}

echo "the PC-shaped machine, a ${LATENCY_US} us wire: the same page, the same run twice, and rests"
if [ "$PATH_WANTED" = all ]; then
  for one in $ROUTES; do check "$one"; done
else
  check "$PATH_WANTED"
fi
if [ $failed = 0 ]; then echo "every route: the same page, the same run twice, and the guest rested"; else echo "something differed"; fi
exit $failed
