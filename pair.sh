#!/bin/bash
# **TWO KERNELS TALKING, JUDGED** (docs/TWO-KERNELS.md §7, step 3; QUEUE 225
# chunk 13): zig-metal-unikernel's gopher.elf as the server (side 0) and its
# probe/fetch.elf as the client (side 1), on PAIR mode, deterministic by
# construction. Every run must end with the client's outcome as its exit
# code, and every run that recovers must deliver the page byte for byte.
#
#   ./pair.sh
#
# **THE ORACLE IS NOT THE PAIR'S OWN.** The page each fetch must deliver is
# the one gopher.elf serves metal-vmm's built-in client (a single-guest run,
# `PEER_BODY`), hashed with the same FNV-1a 64 the client prints. A pair that
# agreed with itself and got the page wrong would fail here.
#
# The scenarios, about 50 runs of under half a second each:
# - **unhurt**, `/` and `/steve-resume.pdf`, each twice: exit 0, the page,
#   and the two runs' outputs byte-identical (determinism);
# - **the SYN eaten** once and twice: still the page; three times: the
#   connect deadline (exit 3), at 150 ms;
# - **silent**: a port nobody listens on; our server drops the SYN (a
#   `DEPARTS (bounded)` line in tcp.zig), so the connect deadline again.
#   "Refused" cannot happen between two of our kernels: our server never
#   resets a SYN. The native judge's fetch case "refused" has it, against
#   Linux;
# - **no ARP**: an address nobody has (exit 9);
# - **idle**: every server frame after the SYN-ACK lost, so the client hears
#   nothing past the handshake: the idle deadline (exit 4) at 1 s;
# - **one frame lost**, on `/steve-resume.pdf`, each side's first 12 and last
#   8 crossing frames in turn (counted from the unhurt run): the page, every
#   time.
#
# Needs: KVM, zig-metal-unikernel beside this checkout (GUESTS, its probe/
# with gopher.elf and fetch.elf built: `zig build gopher fetch`) and a site
# volume for gopher.elf's disk (SITE; zig-metal-unikernel's long.sh builds
# one). Exit 0 when every run is as it must be; 1 otherwise, naming each.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
GUESTS="${GUESTS:-$(cd "$HERE/../zig-metal-unikernel/probe" 2> /dev/null && pwd)}"
SITE="${SITE:-$HOME/build/zig-metal-unikernel/site/pristine.img}"
# OUT, as sweep.sh names it: never PAIR_WORK, which metal-vmm would refuse
# as a misspelled PAIR_ setting (it reaches every run through the env).
WORK="${OUT:-$HOME/build/metal-vmm/pair}"
VMM="$HERE/zig-out/bin/metal-vmm"
for f in "$GUESTS/gopher.elf" "$GUESTS/fetch.elf" "$SITE"; do
    [ -f "$f" ] || { echo "pair.sh: NOT RUN: no $f"; exit 2; }
done
[ -e /dev/kvm ] || { echo "pair.sh: NOT RUN: no /dev/kvm"; exit 2; }
zig build > /dev/null 2>&1 || { echo "pair.sh: NOT RUN: metal-vmm does not build"; exit 2; }
mkdir -p "$WORK"
rm -f "$WORK/times"
failed=()
began=$SECONDS
runs=0

fnv() { python3 -c 'import sys
h = 0xcbf29ce484222325
for b in open(sys.argv[1], "rb").read(): h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
print(f"{h:016x}")' "$1"; }

# The page the single-guest run serves metal-vmm's own client.
want() {
    cp "$SITE" "$WORK/single.img"
    rm -f "$WORK/single.page"
    TRANSPORT=pci WIRE_LATENCY_US=1000 PEER_BODY="$WORK/single.page" \
        timeout 60 "$VMM" "$GUESTS/gopher.elf" "$WORK/single.img" "" "$1" > /dev/null 2>&1 || return 1
    [ -s "$WORK/single.page" ] || return 1
    fnv "$WORK/single.page"
}
# **THE ORACLE OR NOTHING** (the cold review): an empty hash would turn
# every page check off, so a page with no hash from its single-guest run
# stops the gate before any pair runs (exit 2, NOT RUN).
oracle() {
    local h
    h=$(want "$1") || true
    [[ "$h" =~ ^[0-9a-f]{16}$ ]] || { echo "pair.sh: NOT RUN: no page hash from the single-guest run of $1 (got '$h')" >&2; exit 2; }
    echo "$h"
}

# pair <tag> <path> <port|ip:port> [VAR=value …]: one pair run; sets code,
# outcome (the client's line), and crossing (each side's frames across).
pair() {
    local tag=$1 path=$2 to=$3; shift 3
    local ip=10.0.2.15 port=$to
    case "$to" in *:*) ip=${to%:*}; port=${to#*:} ;; esac
    cp "$SITE" "$WORK/disk.img"
    local t0
    t0=$(date +%s%N)
    # **PATIENCE_S=5, THE SERVER'S**: a run whose client gives up before any
    # request (the SYN eaten three times, silent, no ARP) leaves gopher.elf
    # waiting for a request that never comes; it wakes on its timer every
    # 0.8 ms, so the default 600 s of guest time is 3 million exits, about
    # 51 s of wall time a run (measured 2026-10-16). Once its client has
    # gone the server owes nothing; 5 s of its time ends it in well under
    # one of ours. A run that serves its request ends on the site's own
    # one-request setting long before.
    env "$@" PATIENCE_S=5 TRANSPORT=pci WIRE_LATENCY_US=1000 PAIR="$GUESTS/fetch.elf" PAIR_OUT="$WORK/$tag.client" \
        PAIR_CLIENT_TRANSPORT=pci PAIR_CMDLINE="fetch $ip $port $path connect_ms=150 idle_ms=1000 total_ms=3000" \
        timeout 60 "$VMM" "$GUESTS/gopher.elf" "$WORK/disk.img" > "$WORK/$tag.server" 2> "$WORK/$tag.err"
    code=$?
    echo "$(( ($(date +%s%N) - t0) / 1000000 )) $tag" >> "$WORK/times"
    runs=$((runs + 1))
    outcome=$(grep -a "outcome:" "$WORK/$tag.client" | sed 's/^ *//')
}

# lost <tag> <side>: the frames that side's wire lost, as metal-vmm counted
# them ("#5", "#3, #4, …"), from the `wire:` line before its `pair side` line.
lost() {
    awk -v s="$2" '/^wire: /{w=$0} $0 ~ "^metal-vmm: pair side "s":" {print w}' "$WORK/$1.err" |
        sed -n 's/.* lost (\(.*\)), .*/\1/p'
}

# expect <tag> <code> <hash|-> [eat side n]: the run's code, the word its
# outcome begins with (each code has one), and, for a code that delivers,
# the page's hash and a server that stopped on its own one-request setting
# rather than on PATIENCE_S. With an eat named, metal-vmm must say that
# side's wire lost exactly that frame: an eat that never fired would pass
# as an unhurt run.
expect() {
    local tag=$1 want_code=$2 want_hash=$3 side=${4:-} n=${5:-} word
    case "$want_code" in 0) word=ok ;; 3) word=connect_deadline ;; 4) word=idle_deadline ;; 9) word=no_arp ;; esac
    if [ "$code" != "$want_code" ] || [[ "$outcome" != "outcome: $word "* ]]; then
        echo "  FAIL $tag: exit $code, want $want_code, $word ($outcome)"; failed+=("$tag"); return
    fi
    if [ "$want_hash" != - ] && ! echo "$outcome" | grep -q "fnv1a $want_hash;"; then
        echo "  FAIL $tag: the page is not the single-guest run's ($outcome; want fnv1a $want_hash)"; failed+=("$tag"); return
    fi
    if [ "$want_code" = 0 ] && grep -q "rested .* idle, so the run ends" "$WORK/$tag.err"; then
        echo "  FAIL $tag: the server ended on PATIENCE_S, not on its own one-request setting"; failed+=("$tag"); return
    fi
    if [ -n "$side" ] && [ "$(lost "$tag" "$side")" != "#$n" ]; then
        echo "  FAIL $tag: side $side's wire lost '$(lost "$tag" "$side")', not #$n: the eat did not fire as named"; failed+=("$tag"); return
    fi
}

# within <tag> <lo> <hi>: the outcome's "after N ms" between lo and hi.
within() {
    local ms
    ms=$(echo "$outcome" | sed -n 's/^outcome: [a-z_]* after \([0-9]*\) ms.*/\1/p')
    if [ -z "$ms" ] || [ "$ms" -lt "$2" ] || [ "$ms" -gt "$3" ]; then
        echo "  FAIL $1: let go after '${ms}' ms, want $2-$3 ($outcome)"; failed+=("$1")
    fi
}

crossing() {  # crossing <tag> <side>: that side's frames across, from its pair line
    sed -n "s/^metal-vmm: pair side $2: .* \([0-9]*\) frames sent across.*/\1/p" "$WORK/$1.err"
}

echo "── unhurt, twice each, against the single-guest page"
for path in / /steve-resume.pdf; do
    h=$(oracle "$path") || exit 2
    t=$(echo "$path" | tr / _)
    pair "unhurt$t" "$path" 80; expect "unhurt$t" 0 "$h"
    [ -z "$(lost "unhurt$t" 0)$(lost "unhurt$t" 1)" ] || { echo "  FAIL unhurt$t: a frame was lost"; failed+=("unhurt$t"); }
    pair "again$t" "$path" 80; expect "again$t" 0 "$h"
    for x in client server err; do
        cmp -s "$WORK/unhurt$t.$x" "$WORK/again$t.$x" || { echo "  FAIL $path: run twice, the $x output differs"; failed+=("same$t"); }
    done
    echo "  $path: $(echo "$outcome" | sed 's/^outcome: //' | cut -d';' -f1-2)"
done
small=$(oracle /) || exit 2
big=$(oracle /steve-resume.pdf) || exit 2

echo "── the SYN eaten, a port nobody listens on, an address nobody has, a dead path"
# The deadlines are 150 ms to connect and 1 s idle; each is seen by the
# turn of the loop after it passes, a few ms late at most.
pair syn1 / 80 PAIR_CLIENT_WIRE_EAT=2; expect syn1 0 "$small" 1 2
pair syn2 / 80 PAIR_CLIENT_WIRE_EAT=2,3; expect syn2 0 "$small"
[ "$(lost syn2 1)" = "#2, #3" ] || { echo "  FAIL syn2: the client's wire lost '$(lost syn2 1)', not #2, #3"; failed+=(syn2); }
pair syn3 / 80 PAIR_CLIENT_WIRE_EAT=2,3,4; expect syn3 3 -; within syn3 150 160
[ "$(lost syn3 1)" = "#2, #3, #4" ] || { echo "  FAIL syn3: the client's wire lost '$(lost syn3 1)', not #2, #3, #4"; failed+=(syn3); }
pair silent / 81; expect silent 3 -; within silent 150 160
pair no-arp / 10.0.2.99:80; expect no-arp 9 -; within no-arp 150 160
pair idle / 80 WIRE_EAT=3-9999; expect idle 4 -; within idle 1000 1020
grep -q "lost (#3, #4" "$WORK/idle.err" || { echo "  FAIL idle: the server's frames after the SYN-ACK were not the ones lost"; failed+=(idle); }
echo "  $runs runs so far"

echo "── /steve-resume.pdf, one frame lost, each side's first 12 and last 8 in turn"
for side in 1 0; do
    total=$(crossing unhurt_steve-resume.pdf $side)
    [ -n "$total" ] && [ "$total" -gt 0 ] || { echo "  FAIL: no crossing count for side $side"; failed+=("count-$side"); continue; }
    knob=WIRE_EAT; [ $side = 1 ] && knob=PAIR_CLIENT_WIRE_EAT
    for n in $(seq 1 "$total"); do
        [ "$n" -le 12 ] || [ "$n" -gt $((total - 8)) ] || continue
        pair "eat$side-$n" /steve-resume.pdf 80 "$knob=$n"
        expect "eat$side-$n" 0 "$big" "$side" "$n"
    done
    echo "  side $side ($([ $side = 1 ] && echo client || echo server)): $total frames across, $(( total < 20 ? total : 20 )) lost in turn"
done

echo "time: pair.sh $((SECONDS - began)) s, $runs pair runs; the slowest (ms): $(sort -rn "$WORK/times" | head -3 | tr '\n' ' ')"
if [ ${#failed[@]} = 0 ]; then echo "PAIR: PASS"; exit 0; fi
echo "PAIR: FAIL (${failed[*]})"
exit 1
