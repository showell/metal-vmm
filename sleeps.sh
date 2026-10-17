#!/bin/bash
# **A KERNEL THAT SLEEPS, JUDGED IN ITS OWN TIME** (zig-metal-unikernel's
# docs/designs/DESIGN-sleep.md): a quiescent machine halts until its
# application's wake, at most its longest rest, and a frame wakes it sooner.
# Here a halt is an event (the clock jumps to its deadline), so an hour of
# sleeping costs well under a second.
#
#   ./sleeps.sh
#
# - **an idle server costs little**: gopher.elf, one `GET /`, then 60 s of its
#   own time with nothing to do, ends on PATIENCE_S with fewer than 20,000
#   exits and 100 halts. Before the sleep (2026-10-17): 307,564 exits and
#   37,605 halts, a halt every 1.6 ms; after: 6,781 and 8;
# - **an hour of wakes**: the sleeper (probe/sleeper/), waking every 60 s for
#   an hour of its time (GUEST_S): 60 lines, each due exactly 60 s after the
#   one before, each woken under 1 ms after it was due. A wake costs six
#   clock reads, 100 µs of guest time each (clock.zig), so 0.6 ms is what
#   "at once" looks like here;
# - **the longest rest changes nothing the application sees**: the sleeper
#   every 5 s for 20 s, with `longest_rest_ms = 6` and without it (10 s):
#   the same wakes due at the same moments, each woken under 1 ms after,
#   while the 6 ms run halts hundreds of times more. (When within that ms
#   differs: the two take different turns to reach a wake, and each clock
#   read here is 100 µs.) 6 ms and 10 s are one path;
# - **a request wakes a sleep**: the sleeper asleep for 60 s, a client 30 s
#   in: answered within 20 ms of opening, not at the next wake.
#
# Needs: KVM, zig-metal-unikernel beside this checkout (GUESTS, its probe/
# with gopher.elf and sleeper.elf built: `zig build gopher sleeper`), a site
# volume (SITE; zig-metal-unikernel's long.sh builds one) and mtools. Exit 0
# when every check holds; 1 otherwise, naming each; 2 when it cannot run.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
GUESTS="${GUESTS:-$(cd "$HERE/../zig-metal-unikernel/probe" 2> /dev/null && pwd)}"
SITE="${SITE:-$HOME/build/zig-metal-unikernel/site/pristine.img}"
WORK="${OUT:-$HOME/build/metal-vmm/sleeps}"
VMM="$HERE/zig-out/bin/metal-vmm"
for f in "$GUESTS/gopher.elf" "$GUESTS/sleeper.elf" "$SITE"; do
    [ -f "$f" ] || { echo "sleeps.sh: NOT RUN: no $f"; exit 2; }
done
[ -e /dev/kvm ] || { echo "sleeps.sh: NOT RUN: no /dev/kvm"; exit 2; }
command -v mcopy > /dev/null || { echo "sleeps.sh: NOT RUN: no mcopy (mtools)"; exit 2; }
zig build > /dev/null 2>&1 || { echo "sleeps.sh: NOT RUN: metal-vmm does not build"; exit 2; }
mkdir -p "$WORK"
failed=()
began=$SECONDS
fail() { echo "  FAIL $1: $2"; failed+=("$1"); }

# The first partition of a GPT disk from mkfs.vfat starts at sector 2048.
PART=$((2048 * 512))

# disk <tag> <machine conf> [sleeper conf]: a fresh copy of the site disk,
# with zig-metal-unikernel.conf, and the sleeper's own conf in its data.
disk() {
    cp "$SITE" "$WORK/$1.img"
    printf '%b' "$2" > "$WORK/$1.conf"
    mcopy -o -i "$WORK/$1.img@@$PART" "$WORK/$1.conf" ::zig-metal-unikernel.conf || { echo "sleeps.sh: NOT RUN: mcopy"; exit 2; }
    if [ -n "${3:-}" ]; then
        mmd -i "$WORK/$1.img@@$PART" ::data 2> /dev/null
        printf '%b' "$3" > "$WORK/$1.sleeper"
        mcopy -o -i "$WORK/$1.img@@$PART" "$WORK/$1.sleeper" ::data/sleeper.conf || { echo "sleeps.sh: NOT RUN: mcopy"; exit 2; }
    fi
}

# wakes <tag>: the sleeper's lines, from its disk after the run.
wakes() {
    rm -f "$WORK/$1.wakes"
    mcopy -o -i "$WORK/$1.img@@$PART" ::data/wakes.txt "$WORK/$1.wakes" 2> /dev/null
    [ -f "$WORK/$1.wakes" ] && cat "$WORK/$1.wakes"
}

# cost <tag> <kind>: that kind's exits from the run's cost line (exits, halt).
cost() {
    local line
    line=$(grep '^metal-vmm: cost: ' "$WORK/$1.err")
    case "$2" in
        exits) sed -n 's/^metal-vmm: cost: \([0-9]*\) exits.*/\1/p' <<< "$line" ;;
        *) sed -n "s/.* $2 \([0-9]*\)[,)].*/\1/p" <<< "$line" ;;
    esac
}

# steady <tag> <n> <period ns>: n lines, each due a period after the one
# before, each woken under 1 ms after it was due.
steady() {
    awk -v n="$2" -v p="$3" -v tag="$1" '
        { if (NR > 1 && $4 - due != p) { printf "line %d due %d, not a period after %d\n", NR, $4, due; bad = 1 }
          if ($6 < $4 || $6 - $4 >= 1000000) { printf "line %d woken at %d, due %d\n", NR, $6, $4; bad = 1 }
          due = $4; count++ }
        END { if (count != n) { printf "%d lines, not %d\n", count, n; bad = 1 }; exit bad }' "$WORK/$1.wakes"
}

# ── an idle server ──────────────────────────────────────────────────────────
disk idle 'requests = 100\n'
cp "$SITE" "$WORK/idle.vol"
TRANSPORT=pci PATIENCE_S=60 VOLUME="$WORK/idle.vol" \
    timeout 60 "$VMM" "$GUESTS/gopher.elf" "$WORK/idle.img" "" / > "$WORK/idle.out" 2> "$WORK/idle.err"
exits=$(cost idle exits)
halts=$(cost idle halt)
if ! grep -q "rested 6[0-9] s of its own time .* idle, so the run ends" "$WORK/idle.err" || ! grep -q '^peer: 200' "$WORK/idle.out"; then
    fail idle "gopher.elf did not serve / and then idle out on PATIENCE_S: $(tail -1 "$WORK/idle.err")"
elif [ -z "$exits" ] || [ "$exits" -ge 20000 ] || [ -z "$halts" ] || [ "$halts" -ge 100 ]; then
    fail idle "60 s idle cost $exits exits and $halts halts (want under 20,000 and 100)"
else
    echo "  idle: 60 s of nothing to do, $exits exits, $halts halts"
fi

# ── an hour of wakes ────────────────────────────────────────────────────────
disk hour 'requests = 100\n'
TRANSPORT=pci GUEST_S=3600 timeout 60 "$VMM" "$GUESTS/sleeper.elf" "$WORK/hour.img" "" "" > "$WORK/hour.out" 2> "$WORK/hour.err"
code=$?
wakes hour > /dev/null
if [ "$code" != 0 ] || ! grep -q "run 3600 s of its own time, as GUEST_S asked" "$WORK/hour.err"; then
    fail hour "the sleeper's hour did not end on GUEST_S (exit $code): $(tail -1 "$WORK/hour.err")"
elif ! why=$(steady hour 60 60000000000); then
    fail hour "$why"
else
    echo "  hour: 60 wakes 60 s apart, each under 1 ms late, $(cost hour exits) exits"
fi

# ── the longest rest, 6 ms and 10 s ─────────────────────────────────────────
disk long 'requests = 100\n' 'period_ms = 5000\n'
disk short 'requests = 100\nlongest_rest_ms = 6\n' 'period_ms = 5000\n'
for tag in long short; do
    TRANSPORT=pci GUEST_S=20 timeout 60 "$VMM" "$GUESTS/sleeper.elf" "$WORK/$tag.img" "" "" > "$WORK/$tag.out" 2> "$WORK/$tag.err"
    wakes "$tag" > /dev/null
done
if ! why=$(steady long 4 5000000000); then
    fail longest "the 10 s run: $why"
elif ! why=$(steady short 4 5000000000); then
    fail longest "the 6 ms run: $why"
elif ! cmp -s <(cut -d' ' -f1-4 "$WORK/long.wakes") <(cut -d' ' -f1-4 "$WORK/short.wakes"); then
    fail longest "6 ms and 10 s were due differently: $(diff <(cut -d' ' -f1-4 "$WORK/long.wakes") <(cut -d' ' -f1-4 "$WORK/short.wakes") | head -3 | tr '\n' ' ')"
elif [ "$(cost short halt)" -lt $((100 * $(cost long halt))) ]; then
    fail longest "6 ms halted $(cost short halt) times, 10 s $(cost long halt): the setting did not reach the rest"
else
    echo "  longest rest: 6 ms and 10 s wake alike, halting $(cost short halt) and $(cost long halt) times"
fi

# ── a request wakes a sleep ─────────────────────────────────────────────────
disk woken 'requests = 100\n'
TRANSPORT=pci GUEST_S=60 PEER_CLIENTS=2 PEER_CLIENT_GAP_US=30000000 \
    timeout 60 "$VMM" "$GUESTS/sleeper.elf" "$WORK/woken.img" "" / > "$WORK/woken.out" 2> "$WORK/woken.err"
second=$(grep '^peer 2: ' "$WORK/woken.out")
opened=$(sed -n -E 's/.*, opened at ([0-9]+)\.([0-9]{3}) ms.*/\1\2/p' <<< "$second")
answered=$(sed -n -E 's/.*, answered at ([0-9]+)\.([0-9]{3}) ms.*/\1\2/p' <<< "$second")
if [ -z "$opened" ] || [ -z "$answered" ] || ! grep -q '^peer 2: 200' <<< "$second"; then
    fail woken "the second client was not answered: $second"
elif [ "$opened" -lt 29000000 ] || [ $((answered - opened)) -ge 20000 ]; then
    fail woken "opened at $opened us, answered $((answered - opened)) us later (want 30 s in, under 20 ms): $second"
else
    echo "  woken: a request 30 s into a sleep answered in $(((answered - opened) / 1000)) ms"
fi

echo "time: $((SECONDS - began)) s"
if [ ${#failed[@]} -gt 0 ]; then
    echo "SLEEPS: FAIL (${failed[*]})"
    exit 1
fi
echo "SLEEPS: PASS"
