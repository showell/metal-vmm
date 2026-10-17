#!/bin/bash
# **A KERNEL THAT SLEEPS, JUDGED IN ITS OWN TIME** (zig-metal-unikernel's
# docs/designs/DESIGN-sleep.md): a quiescent machine halts until its
# application's wake, at most its longest rest, and a frame wakes it sooner.
# Here a halt is an event (the clock jumps to its deadline), so an hour of
# sleeping costs well under a second. Every check reads the halts too: a
# kernel that woke on time by never sleeping (a 1 ms slice throughout) would
# pass every lateness bound here.
#
#   ./sleeps.sh
#
# - **an idle server costs little**: gopher.elf, one `GET /`, then 60 s of its
#   own time with nothing to do, ends on PATIENCE_S with fewer than 20,000
#   exits and 100 halts. Before the sleep (2026-10-17): 307,564 exits and
#   37,605 halts, a halt every 1.6 ms; after: 6,781 and 8;
# - **an hour of wakes**: the sleeper (probe/sleeper/), waking every 60 s for
#   an hour of its time (GUEST_S): 60 lines, each due exactly 60 s after the
#   one before, each woken within 700 µs of it; at most 400 halts, the
#   longest of them the whole longest rest (10 s). A wake costs six clock
#   reads, 100 µs of guest time each (clock.zig), so 0.6 ms is what "at once"
#   looks like here;
# - **its lines on a volume**: the same, ten minutes, the data on a volume
#   with a write cache the kernel cannot turn off (`VOLUME_CACHE=1
#   VOLUME_WCE_FIXED=1`): each wake's line is flushed before the machine
#   sleeps (a SYNCHRONIZE CACHE a wake), and the machine still sleeps;
# - **the longest rest changes nothing the application sees**: the sleeper
#   every 5 s for 20 s with `longest_rest_ms = 6` and without it (10 s):
#   both runs steady, while the 6 ms one halts at least a hundred times more.
#   6 ms and 10 s are one path;
# - **a request wakes a sleep**: the sleeper asleep, a client 35 s in, in the
#   middle of a longest rest: answered within 5 ms of opening, and the whole
#   minute at most 20 halts (11 when written; a 1 ms slice would be 60,000).
#
# - **two kernels: the sleeper fetching from gopher.elf** (PAIR, its disk
#   PAIR_DISK), every 60 s for ten minutes: ten polls, each ok and the page's
#   size from a single-guest run; then with the server silent from 180 s to
#   300 s (WIRE_SILENT_S), across polls 4 and 5: those two no_arp, the rest
#   ok.
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

# disk <file> <machine conf> [sleeper conf]: a fresh copy of the site disk,
# with zig-metal-unikernel.conf, and the sleeper's own conf in its data.
disk() {
    cp "$SITE" "$1"
    printf '%b' "$2" > "$1.conf"
    mcopy -o -i "$1@@$PART" "$1.conf" ::zig-metal-unikernel.conf || { echo "sleeps.sh: NOT RUN: mcopy"; exit 2; }
    if [ -n "${3:-}" ]; then
        mmd -i "$1@@$PART" ::data 2> /dev/null
        printf '%b' "$3" > "$1.sleeper"
        mcopy -o -i "$1@@$PART" "$1.sleeper" ::data/sleeper.conf || { echo "sleeps.sh: NOT RUN: mcopy"; exit 2; }
    fi
}

# wakes <tag> <image>: the sleeper's lines, from the disk its data is on.
wakes() {
    rm -f "$WORK/$1.wakes"
    mcopy -o -i "$2@@$PART" ::data/wakes.txt "$WORK/$1.wakes" 2> /dev/null
    touch "$WORK/$1.wakes"
}

# **A NUMBER OR A FAILURE** (the cold review): a cost line misread is an
# empty string, and `[ "" -lt N ]` is an error the `if` reads as false, so
# every number a check reads comes through here, and an empty one fails.
# num <tag> <what> <value>: the value, or a failure and nothing.
num() {
    if [[ "$3" =~ ^[0-9]+$ ]]; then echo "$3"; return 0; fi
    echo "  FAIL $1: no $2 in its run (got '$3')" >&2
    return 1
}

# cost <tag> <kind>: from the run's cost line: `exits`, a kind's exits
# (`halt`), or `longest` (the longest halt, whole ms).
cost() {
    local line
    line=$(grep '^metal-vmm: cost: ' "$WORK/$1.err")
    case "$2" in
        exits) sed -n 's/^metal-vmm: cost: \([0-9]*\) exits.*/\1/p' <<< "$line" ;;
        longest) sed -n 's/.* the longest halt \([0-9]*\)\.[0-9]* ms.*/\1/p' <<< "$line" ;;
        *) sed -n "s/.* $2 \([0-9]*\)[,)].*/\1/p" <<< "$line" ;;
    esac
}

# watched <tag> <code> <s>: the run ended as GUEST_S asked, with exit 0.
watched() {
    [ "$2" = 0 ] && grep -q "run $3 s of its own time, as GUEST_S asked" "$WORK/$1.err"
}

# steady <tag> <n> <period ns>: n lines, each due a period after the one
# before, each woken no sooner than due and within 700 µs (seven clock
# reads) after.
steady() {
    awk -v n="$2" -v p="$3" '
        { if (NR > 1 && $4 - due != p) { printf "line %d due %d, not a period after %d\n", NR, $4, due; bad = 1 }
          if ($6 < $4 || $6 - $4 > 700000) { printf "line %d woken at %d, due %d\n", NR, $6, $4; bad = 1 }
          due = $4; count++ }
        END { if (count != n) { printf "%d lines, not %d\n", count, n; bad = 1 }; exit bad }' "$WORK/$1.wakes"
}

# ── an idle server ──────────────────────────────────────────────────────────
disk "$WORK/idle.img" 'requests = 100\n'
cp "$SITE" "$WORK/idle.vol"
TRANSPORT=pci PATIENCE_S=60 VOLUME="$WORK/idle.vol" \
    timeout 60 "$VMM" "$GUESTS/gopher.elf" "$WORK/idle.img" "" / > "$WORK/idle.out" 2> "$WORK/idle.err"
if ! grep -q "rested 6[0-9] s of its own time .* idle, so the run ends" "$WORK/idle.err" || ! grep -q '^peer: 200' "$WORK/idle.out"; then
    fail idle "gopher.elf did not serve / and then idle out on PATIENCE_S: $(tail -1 "$WORK/idle.err")"
elif ! exits=$(num idle exits "$(cost idle exits)") || ! halts=$(num idle halts "$(cost idle halt)"); then
    failed+=(idle)
elif [ "$exits" -ge 20000 ] || [ "$halts" -ge 100 ]; then
    fail idle "60 s idle cost $exits exits and $halts halts (want under 20,000 and 100)"
else
    echo "  idle: 60 s of nothing to do, $exits exits, $halts halts"
fi

# ── an hour of wakes ────────────────────────────────────────────────────────
disk "$WORK/hour.img" 'requests = 100\n'
TRANSPORT=pci GUEST_S=3600 timeout 60 "$VMM" "$GUESTS/sleeper.elf" "$WORK/hour.img" "" "" > "$WORK/hour.out" 2> "$WORK/hour.err"
code=$?
wakes hour "$WORK/hour.img"
if ! watched hour "$code" 3600; then
    fail hour "the sleeper's hour did not end on GUEST_S (exit $code): $(tail -1 "$WORK/hour.err")"
elif ! why=$(steady hour 60 60000000000); then
    fail hour "$why"
elif ! halts=$(num hour halts "$(cost hour halt)") || ! longest=$(num hour "longest halt" "$(cost hour longest)"); then
    failed+=(hour)
elif [ "$halts" -gt 400 ] || [ "$longest" -lt 9900 ]; then
    fail hour "$halts halts, the longest $longest ms (want at most 400, the longest the whole 10 s rest)"
else
    echo "  hour: 60 wakes 60 s apart, each within 700 us, $halts halts, the longest $longest ms"
fi

# ── its lines on a volume ───────────────────────────────────────────────────
disk "$WORK/onvol.img" 'requests = 100\n'
disk "$WORK/onvol.vol" 'requests = 100\n'
TRANSPORT=pci GUEST_S=600 VOLUME="$WORK/onvol.vol" VOLUME_CACHE=1 VOLUME_WCE_FIXED=1 \
    timeout 60 "$VMM" "$GUESTS/sleeper.elf" "$WORK/onvol.img" "" "" > "$WORK/onvol.out" 2> "$WORK/onvol.err"
code=$?
wakes onvol "$WORK/onvol.vol"
syncs=$(sed -n 's/^metal-vmm: volume: .* \([0-9]*\) SYNCHRONIZE CACHE.*/\1/p' "$WORK/onvol.err")
if ! watched onvol "$code" 600; then
    fail onvol "the sleeper's ten minutes on a volume did not end on GUEST_S (exit $code): $(tail -1 "$WORK/onvol.err")"
elif ! grep -q "wakes: the volume" "$WORK/onvol.out"; then
    fail onvol "the sleeper's data was not on the volume: $(grep wakes "$WORK/onvol.out")"
elif ! why=$(steady onvol 10 60000000000); then
    fail onvol "$why"
elif ! halts=$(num onvol halts "$(cost onvol halt)") || ! syncs=$(num onvol "SYNCHRONIZE CACHE count" "$syncs"); then
    failed+=(onvol)
elif [ "$halts" -gt 100 ] || [ "$syncs" -lt 10 ]; then
    fail onvol "$halts halts and $syncs flushes (want at most 100, and one a wake): a write left unflushed keeps the machine awake"
else
    echo "  on a volume: 10 wakes, $syncs flushes, $halts halts"
fi

# ── the longest rest, 6 ms and 10 s ─────────────────────────────────────────
disk "$WORK/long.img" 'requests = 100\n' 'period_ms = 5000\n'
disk "$WORK/short.img" 'requests = 100\nlongest_rest_ms = 6\n' 'period_ms = 5000\n'
for tag in long short; do
    TRANSPORT=pci GUEST_S=20 timeout 60 "$VMM" "$GUESTS/sleeper.elf" "$WORK/$tag.img" "" "" > "$WORK/$tag.out" 2> "$WORK/$tag.err"
    code=$?
    wakes "$tag" "$WORK/$tag.img"
    watched "$tag" "$code" 20 || fail longest "the $tag run did not end on GUEST_S (exit $code): $(tail -1 "$WORK/$tag.err")"
done
if ! why=$(steady long 4 5000000000); then
    fail longest "the 10 s run: $why"
elif ! why=$(steady short 4 5000000000); then
    fail longest "the 6 ms run: $why"
elif ! long_halts=$(num longest "10 s run's halts" "$(cost long halt)") || ! short_halts=$(num longest "6 ms run's halts" "$(cost short halt)"); then
    failed+=(longest)
elif [ "$short_halts" -lt $((100 * long_halts)) ]; then
    fail longest "6 ms halted $short_halts times, 10 s $long_halts: the setting did not reach the rest"
else
    echo "  longest rest: 6 ms and 10 s both steady, halting $short_halts and $long_halts times"
fi

# ── a request wakes a sleep ─────────────────────────────────────────────────
disk "$WORK/woken.img" 'requests = 100\n'
TRANSPORT=pci GUEST_S=60 PEER_CLIENTS=2 PEER_CLIENT_GAP_US=35000000 \
    timeout 60 "$VMM" "$GUESTS/sleeper.elf" "$WORK/woken.img" "" / > "$WORK/woken.out" 2> "$WORK/woken.err"
code=$?
second=$(grep '^peer 2: ' "$WORK/woken.out")
opened=$(sed -n -E 's/.*, opened at ([0-9]+)\.([0-9]{3}) ms.*/\1\2/p' <<< "$second")
answered=$(sed -n -E 's/.*, answered at ([0-9]+)\.([0-9]{3}) ms.*/\1\2/p' <<< "$second")
if ! watched woken "$code" 60 || ! grep -q '^peer 2: 200' <<< "$second"; then
    fail woken "the second client was not answered, or the run did not end on GUEST_S (exit $code): $second"
elif ! opened=$(num woken "opened time" "$opened") || ! answered=$(num woken "answered time" "$answered") || ! halts=$(num woken halts "$(cost woken halt)"); then
    failed+=(woken)
elif [ "$opened" -lt 34000000 ] || [ $((answered - opened)) -ge 5000 ] || [ "$halts" -gt 20 ]; then
    fail woken "opened at $opened us, answered $((answered - opened)) us later, $halts halts (want 35 s in, under 5 ms, at most 20): $second"
else
    echo "  woken: a request 35 s into a sleep answered in $(((answered - opened) / 1000)) ms, $halts halts in the minute"
fi

# ── the sleeper fetching from a server, two kernels (PAIR, PAIR_DISK) ────────
# The page's size, from a single-guest run of gopher.elf (PEER_BODY), as
# pair.sh takes its oracle: the pair's own count could agree with itself.
cp "$SITE" "$WORK/single.img"
rm -f "$WORK/single.page"
TRANSPORT=pci WIRE_LATENCY_US=1000 PEER_BODY="$WORK/single.page" \
    timeout 60 "$VMM" "$GUESTS/gopher.elf" "$WORK/single.img" "" / > /dev/null 2>&1
page=$(stat -c %s "$WORK/single.page" 2> /dev/null)
if ! page=$(num fetches "page size from the single-guest run" "$page"); then
    failed+=(fetches)
fi
# pairfetch <tag> [VAR=value ...]: gopher.elf serving, the sleeper fetching
# / every 60 s for ten minutes of both machines' time.
pairfetch() {
    local tag=$1; shift
    disk "$WORK/$tag.server" 'requests = 1000\n'
    disk "$WORK/$tag.client" 'requests = 1000\n' 'period_ms = 60000\nfetch = 10.0.2.15:80 /\n'
    env "$@" TRANSPORT=pci GUEST_S=600 WIRE_LATENCY_US=1000 PAIR="$GUESTS/sleeper.elf" PAIR_DISK="$WORK/$tag.client" \
        PAIR_OUT="$WORK/$tag.out" PAIR_CLIENT_TRANSPORT=pci \
        timeout 60 "$VMM" "$GUESTS/gopher.elf" "$WORK/$tag.server" > "$WORK/$tag.server.out" 2> "$WORK/$tag.err"
    code=$?
    wakes "$tag" "$WORK/$tag.client"
    outcomes=$(awk '$1 == "fetch" {print $3}' "$WORK/$tag.wakes" | tr '\n' ' ')
}
if [ -n "${page:-}" ]; then
    pairfetch fetches
    sizes=$(awk '$1 == "fetch" && $3 == "ok" {print $5}' "$WORK/fetches.wakes" | sort -u | tr '\n' ' ')
    if ! watched fetches "$code" 600; then
        fail fetches "the pair did not end on GUEST_S (exit $code): $(tail -1 "$WORK/fetches.err")"
    elif [ "$outcomes" != "ok ok ok ok ok ok ok ok ok ok " ] || [ "$sizes" != "$page " ]; then
        fail fetches "the ten polls: $outcomes, sizes $sizes (want ten ok, each $page bytes)"
    else
        echo "  fetches: two kernels, ten polls in ten minutes, each ok and $page bytes"
    fi
    # **SILENT FOR A STRETCH**: the server sends nothing that arrives from
    # 180 s to 300 s of its time (WIRE_SILENT_S), across the 4th and 5th
    # polls: those two say no_arp, and the sleeper polls on, each after ok.
    pairfetch silent WIRE_SILENT_S=180-300
    silenced=$(sed -n 's/^metal-vmm: wire silent from 180 to 300 s .*: \([0-9]*\) frames lost$/\1/p' "$WORK/silent.err")
    if ! watched silent "$code" 600; then
        fail silent "the pair did not end on GUEST_S (exit $code): $(tail -1 "$WORK/silent.err")"
    elif [ "$outcomes" != "ok ok ok no_arp no_arp ok ok ok ok ok " ]; then
        fail silent "the ten polls: $outcomes (want the 4th and 5th no_arp, the rest ok)"
    elif ! silenced=$(num silent "frames silenced" "$silenced") || [ "$silenced" -lt 2 ]; then
        fail silent "the server's wire silenced '${silenced:-}' frames (want its replies to both polls)"
    else
        echo "  silent: the server silent from 180 s to 300 s ($silenced frames), polls 4 and 5 no_arp, the rest ok"
    fi
fi

echo "time: $((SECONDS - began)) s"
if [ ${#failed[@]} -gt 0 ]; then
    echo "SLEEPS: FAIL (${failed[*]})"
    exit 1
fi
echo "SLEEPS: PASS"
