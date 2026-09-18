#!/bin/bash
# **A MAP OF WHICH DISK REQUESTS THIS GUEST CAN SURVIVE BEING REFUSED.**
#
#   ./flaky.sh [probe] [how many]     # fat16 and its first 20 by default
#   ./flaky.sh fat16 all              # every request it makes, in turn
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
case "$PROBE" in fat16) IMAGE="fat16-list" ;; *) IMAGE="fat16-write" ;; esac
VMM="$HERE/zig-out/bin/metal-vmm"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
[ -x "$VMM" ] || { echo "no $VMM; run: zig build"; exit 1; }
[ -f "$GUESTS/$PROBE.elf" ] || { echo "no $GUESTS/$PROBE.elf"; exit 1; }

run() { # $1 = DISK_REFUSE value
    cp "$IMAGES/$IMAGE.disk" "$WORK/img"
    DISK_REFUSE="$1" timeout 120 "$VMM" "$GUESTS/$PROBE.elf" "$WORK/img" > "$WORK/out" 2> "$WORK/err"
    code=$?
    asked=$(sed -n 's/^disk: \([0-9]*\) requests.*/\1/p' "$WORK/err")
    outcome="exit $code — $(grep -a '^PASS$\|^FAIL' "$WORK/out" | head -1)"
    [ -z "$(grep -a '^PASS$\|^FAIL' "$WORK/out")" ] && outcome="exit $code — said nothing about it"
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
