#!/bin/bash
# **A MAP OF WHICH DISK REQUESTS THIS GUEST CAN SURVIVE BEING REFUSED.**
#
#   ./flaky.sh [probe] [how many]     # fat16 and its first 20 by default
#   ./flaky.sh fat16 all              # every request it makes, in turn
#   ./flaky.sh gopher all             # the REAL server, on the site's volume
#
# One run per request: the disk answers that one with an I/O error, exactly as
# a real one does when it cannot do the work, and the guest's own fat16.zig
# turns that into ReadFailed. Outcomes are tallied rather than listed, because
# the interesting thing about 709 runs is how many DIFFERENT things happened.
#
# The wire's equivalent is lossy.sh.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUESTS="${GUESTS:-$HOME/showell_repos/gopher-metal/probe}"
IMAGES="${IMAGES:-$HOME/showell_repos/cobblestone-u61/codex/test}"
PROBE="${1:-fat16}"
HOW_MANY="${2:-20}"
# The real server reads its site off its own volume, and answers a request the
# peer makes; a probe brings its own small disk and answers nobody.
SITE="${SITE:-$HOME/build/gopher-metal/probe/gopher/pristine.img}"
FETCH=""
case "$PROBE" in
    gopher) DISK="$SITE"; FETCH="/" ;;
    fat16) DISK="$IMAGES/fat16-list.disk" ;;
    *) DISK="$IMAGES/fat16-write.disk" ;;
esac
VMM="$HERE/zig-out/bin/metal-vmm"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
[ -x "$VMM" ] || { echo "no $VMM; run: zig build"; exit 1; }
[ -f "$GUESTS/$PROBE.elf" ] || { echo "no $GUESTS/$PROBE.elf"; exit 1; }
[ -f "$DISK" ] || { echo "no disk at $DISK"; exit 1; }

run() { # $1 = DISK_REFUSE value
    cp "$DISK" "$WORK/img"
    DISK_REFUSE="$1" timeout 120 "$VMM" "$GUESTS/$PROBE.elf" "$WORK/img" "" "$FETCH" > "$WORK/out" 2> "$WORK/err"
    code=$?
    asked=$(sed -n 's/^disk: \([0-9]*\) requests.*/\1/p' "$WORK/err")
    local said client
    said=$(grep -a '^PASS$\|^FAIL' "$WORK/out" | head -1)
    [ -z "$said" ] && said="said nothing about it"
    outcome="exit $code — $said"
    # **AND WHAT THE CLIENT GOT**, which for a server is the whole question: a
    # machine that survives a refused read and answers 500 is a different
    # animal from one that survives it and answers nothing.
    client=$(sed -n 's/^peer: //p' "$WORK/out")
    [ -n "$client" ] && outcome="$outcome — client got: $client"
}

# A number no request reaches, to learn the shape of an untouched run.
run 999999
total=$asked
perfect="$outcome"
echo "$PROBE makes $total disk requests; an untouched run: $perfect"

[ "$HOW_MANY" = all ] && HOW_MANY=$total
[ "$HOW_MANY" -gt "$total" ] && HOW_MANY=$total
echo "refusing each of the first $HOW_MANY, one run each:"

declare -A tally first last
n=1
while [ "$n" -le "$HOW_MANY" ]; do
    run "$n"
    tally["$outcome"]=$(( ${tally["$outcome"]:-0} + 1 ))
    [ -z "${first["$outcome"]:-}" ] && first["$outcome"]=$n
    last["$outcome"]=$n
    n=$((n + 1))
done

for outcome in "${!tally[@]}"; do
    printf '  %4d runs  (#%s..#%s)  %s\n' "${tally[$outcome]}" "${first[$outcome]}" "${last[$outcome]}" "$outcome"
done | sort -rn
