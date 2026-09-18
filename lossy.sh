#!/bin/bash
# **A MAP OF WHICH FRAMES THIS GUEST CAN SURVIVE LOSING.**
#
#   ./lossy.sh [probe]        # http by default
#
# The wire eats the guest's first frame, then its second, and so on, one run
# per frame, and prints what happened to each. A rate would explore this
# randomly; a number explores it exhaustively, and the whole table is
# reproducible — every run here is the same run every time.
#
# Read the last column: it is the guest's OWN clock, and the gap between a run
# that lost nothing and one that did is the guest's retransmission timeout
# happening in front of you.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUESTS="${GUESTS:-$HOME/showell_repos/gopher-metal/probe}"
PROBE="${1:-http}"
VMM="$HERE/zig-out/bin/metal-vmm"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
[ -x "$VMM" ] || { echo "no $VMM; run: zig build"; exit 1; }
[ -f "$GUESTS/$PROBE.elf" ] || { echo "no $GUESTS/$PROBE.elf"; exit 1; }

run() { # $1 = WIRE_EAT value
    WIRE_EAT="$1" timeout 120 "$VMM" "$GUESTS/$PROBE.elf" "" "" /probe > "$WORK/out" 2> "$WORK/err"
    code=$?
    sent=$(sed -n 's/^wire: \([0-9]*\) frames sent.*/\1/p' "$WORK/err")
    ms=$(sed -n 's/.*, \([0-9]*\) ms of the guest.*/\1/p' "$WORK/err")
    got=$(sed -n 's/^peer: //p' "$WORK/out")
    verdict=$(grep -a '^PASS$\|^FAIL' "$WORK/out" | head -1)
}

# A run with a frame number no run reaches, to learn what an untouched run does.
run 9999
perfect_ms=$ms
total=$sent
printf '%-9s %-6s %-5s %-9s %s\n' "eaten" "sent" "exit" "guest ms" "verdict, and what the client got"
printf '%-9s %-6s %-5s %-9s %s\n' "nothing" "$total" "$code" "$ms" "$verdict — $got"

n=1
while [ "$n" -le "$((total + 1))" ]; do
    run "$n"
    note=""
    [ -n "$ms" ] && [ "$ms" -gt "$((perfect_ms + 50))" ] && note=" (+$((ms - perfect_ms)) ms: a retransmission timeout)"
    printf '#%-8s %-6s %-5s %-9s %s\n' "$n" "$sent" "$code" "$ms" "$verdict — $got$note"
    n=$((n + 1))
done
