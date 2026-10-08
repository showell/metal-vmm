#!/bin/bash
# **THE NIGHTLY SWEEP**: sweep.sh with a volume, batch after batch of new
# seeds, until the hours are up. Detached by itself; nothing it runs reads the
# checkouts after it starts, so the box can be worked on meanwhile.
#
#   ./nightly.sh                    10 hours, from where the last night stopped
#   HOURS=0.33 ./nightly.sh         a 20-minute trial
#   FIRST=1 BATCH=100 ./nightly.sh  from seed 1, 100 seeds a batch
#
# **WHAT IT WRITES** (in `~/nightly/<date-time>/`, or NIGHTLY_OUT), all of it
# as it goes, so it can be read mid-run:
#   header.txt        the commits, the kernel's hash, the settings, the start
#   progress.log      one line a batch: the time, the seeds, ok/differ/failed,
#                     the night's totals so far and seeds an hour
#   failures.log      each failing seed's verdict and how to repeat it, as found
#   failed/seedN/     a failing seed's stdout, stderr, page and coverage
#   batches/F-L.log   a batch's whole sweep.sh output, every seed's line
#   nightly.out/.err  this script's own stdout and stderr
#   DONE              written last, with the night's totals
# The next night starts after the last seed this one ran (`~/nightly/next-seed`).
#
# **THE BINARIES ARE FROZEN AT THE START**: metal-vmm and the kernel are
# copied into the night's folder and run from there, so a rebuild of either
# during the night changes nothing about it. The kernel is gopher-metal's
# probe/gopher.elf as it stands: build it first (`./port.sh && zig build
# gopher` in gopher-metal) if it should be master's.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${NIGHTLY_ROOT:-$HOME/nightly}"
HOURS="${HOURS:-10}"
BATCH="${BATCH:-200}"
GOPHER="${GOPHER:-$HOME/showell_repos/gopher-metal}"
SITE="${SITE:-$HOME/build/gopher-metal/probe/gopher/pristine.img}"

if [ -z "${NIGHTLY_ATTACHED:-}" ]; then
    OUT="${NIGHTLY_OUT:-$ROOT/$(date +%F-%H%M)}"
    mkdir -p "$OUT"
    NIGHTLY_ATTACHED=1 NIGHTLY_OUT="$OUT" setsid nohup "$0" > "$OUT/nightly.out" 2> "$OUT/nightly.err" < /dev/null &
    echo "nightly: PID $!, $HOURS hours, logging in $OUT (progress.log, failures.log)"
    exit 0
fi

OUT="$NIGHTLY_OUT"
mkdir -p "$OUT/bin" "$OUT/batches" "$OUT/failed"
[ -x "$HERE/zig-out/bin/metal-vmm" ] || { echo "no metal-vmm built" >&2; exit 2; }
[ -f "$GOPHER/probe/gopher.elf" ] || { echo "no $GOPHER/probe/gopher.elf" >&2; exit 2; }
[ -f "$SITE" ] || { echo "no site volume at $SITE" >&2; exit 2; }
cp "$HERE/zig-out/bin/metal-vmm" "$OUT/bin/metal-vmm"
cp "$GOPHER/probe/gopher.elf" "$OUT/bin/gopher.elf"
cp "$SITE" "$OUT/bin/site.img"
# sweep.sh and sound.sh too: an edit to either during the night changes
# nothing about it.
cp "$HERE/sweep.sh" "$HERE/sound.sh" "$OUT/bin/"
SDK="${COVERAGE_SDK:-$HERE/../zig-coverage-sdk}"
cp "$SDK/tools/report.py" "$OUT/bin/report.py"

FIRST="${FIRST:-$(cat "$ROOT/next-seed" 2>/dev/null || echo 1)}"
start=$(date +%s)
deadline=$((start + $(python3 -c "print(int(float('$HOURS') * 3600))")))
{
    echo "nightly sweep, started $(date '+%F %T %Z')"
    echo "metal-vmm     $(git -C "$HERE" rev-parse --short HEAD)$( [ -n "$(git -C "$HERE" status --porcelain)" ] && echo ' (with uncommitted changes)')"
    echo "gopher-metal  $(git -C "$GOPHER" rev-parse --short HEAD)$( [ -n "$(git -C "$GOPHER" status --porcelain)" ] && echo ' (with uncommitted changes)')"
    echo "kernel        $(sha256sum "$OUT/bin/gopher.elf" | cut -c1-16) (gopher.elf as built)"
    echo "volume        $SITE"
    echo "seeds from    $FIRST, $BATCH a batch, for $HOURS hours (no batch starts after $(date -d "@$deadline" '+%F %T %Z'))"
    echo "machine       TRANSPORT=pci, a volume (VOLUME_SITE), JOBS=${JOBS:-2}"
} > "$OUT/header.txt"
: > "$OUT/failures.log"
echo "time      elapsed  seeds              ok  differ  failed | night: seeds  ok  differ  failed  seeds/hour" > "$OUT/progress.log"

seed=$FIRST
tot=0; tok=0; tdiff=0; tfail=0
while [ "$(date +%s)" -lt "$deadline" ]; do
    last=$((seed + BATCH - 1))
    log="$OUT/batches/$seed-$last.log"
    VMM="$OUT/bin/metal-vmm" KERNEL="$OUT/bin/gopher.elf" SITE="$OUT/bin/site.img" VOLUME_SITE="$OUT/bin/site.img" \
        SOUND="$OUT/bin/sound.sh" REPORT="$OUT/bin/report.py" COVERAGE_SDK="$SDK" KEEP_FAILED="$OUT/failed" \
        "$OUT/bin/sweep.sh" "$seed" "$last" > "$log" 2>&1
    code=$?
    summary=$(grep -E '^[0-9]+ seeds: ' "$log" | tail -1)
    ok=$(sed -n -E 's/.* ([0-9]+) ok,.*/\1/p' <<< "$summary"); ok=${ok:-0}
    diff=$(sed -n -E 's/.* ([0-9]+) differ.*/\1/p' <<< "$summary"); diff=${diff:-0}
    fail=$(sed -n -E 's/.* ([0-9]+) failed.*/\1/p' <<< "$summary"); fail=${fail:-0}
    if [ -z "$summary" ]; then
        # A batch that ended without its summary (sweep.sh stopped early: no
        # unhurt page, say) is a failure of the whole batch, said as such.
        echo "batch $seed-$last: sweep.sh exited $code with no summary; see $log" >> "$OUT/failures.log"
        tail -5 "$log" >> "$OUT/failures.log"
        fail=$BATCH
    fi
    grep -E '^  FAULT_SEED=[0-9]+: FAIL|^    repeat it:' "$log" >> "$OUT/failures.log"
    tot=$((tot + BATCH)); tok=$((tok + ok)); tdiff=$((tdiff + diff)); tfail=$((tfail + fail))
    elapsed=$(( $(date +%s) - start ))
    rate=$(( tot * 3600 / (elapsed > 0 ? elapsed : 1) ))
    printf '%s %6ds  %-17s %4d  %6d  %6d | %12d %4d  %6d  %6d  %10d\n' \
        "$(date +%H:%M:%S)" "$elapsed" "$seed-$last" "$ok" "$diff" "$fail" "$tot" "$tok" "$tdiff" "$tfail" "$rate" >> "$OUT/progress.log"
    seed=$((last + 1))
    echo "$seed" > "$ROOT/next-seed"
done
echo "done $(date '+%F %T %Z'): $tot seeds, $tok ok, $tdiff differ as their faults allow, $tfail failed" | tee "$OUT/DONE" >> "$OUT/progress.log"
