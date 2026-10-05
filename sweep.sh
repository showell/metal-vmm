#!/bin/bash
# **A SEED SWEEP: ONE KERNEL, ONE VOLUME, A RANGE OF WHOLE FAULT SCHEDULES.**
#
#   ./sweep.sh [first] [last]     # FAULT_SEED 1 to 100 by default
#
# Each seed is one exact run (knobs.zig): which frames each way are lost or
# damaged, how late they arrive, which disk request is refused, how the peer
# misbehaves. Every run gets a fresh copy of the volume, and the sweep stops
# at nothing. Each run's verdict:
#
#   - its exit must be the unhurt run's: a crash, a stuck guest or a refused
#     start is a failure whatever the faults were;
#   - it must break no coverage property (metal-vmm's "N broken");
#   - a volume the guest wrote must still be a filesystem (sound.sh);
#   - the page must be the unhurt run's, status and body, unless the seed
#     reset the connection, made the peer vanish or refused a disk request,
#     which may rightly cost the page: then it is "differs (allowed: ...)".
#
# Every run's coverage goes to one JSONL, merged at the end (coverage-merge,
# with FLOOR=<file> if set). The sweep ends with the failing seeds, each as
# the knobs that repeat it without the seed. It exits 1 if any seed failed
# or the merge did.
#
# Environment: GUESTS, SITE and PATH_WANTED (default /) as rest.sh has them;
# TRANSPORT (default pci, the machine that rests); FLOOR; RUN_TIMEOUT
# (seconds, default 300); KEEP=<dir> keeps every run's log, page and the
# coverage JSONL there. VMM, MERGE and SOUND name the programs, for a test.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUESTS="${GUESTS:-$HOME/showell_repos/gopher-metal/probe}"
KERNEL="${KERNEL:-$GUESTS/gopher.elf}"
SITE="${SITE:-$HOME/build/gopher-metal/probe/gopher/pristine.img}"
PATH_WANTED="${PATH_WANTED:-/}"
FIRST="${1:-1}"
LAST="${2:-100}"
VMM="${VMM:-$HERE/zig-out/bin/metal-vmm}"
MERGE="${MERGE:-$HERE/zig-out/bin/coverage-merge}"
SOUND="${SOUND:-$HERE/sound.sh}"
export TRANSPORT="${TRANSPORT:-pci}"
RUN_TIMEOUT="${RUN_TIMEOUT:-300}"
if [ -n "${KEEP:-}" ]; then WORK="$KEEP"; mkdir -p "$WORK"; else WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT; fi
[ -x "$VMM" ] || { echo "no $VMM; run: zig build"; exit 1; }
[ -x "$MERGE" ] || { echo "no $MERGE; run: zig build"; exit 1; }
[ -f "$KERNEL" ] || { echo "no $KERNEL"; exit 1; }
[ -f "$SITE" ] || { echo "no volume at $SITE; set SITE=<image>"; exit 1; }
COVERAGE="$WORK/coverage.jsonl"
: > "$COVERAGE"

# run <name> [VAR=value ...]: one boot on a fresh volume; its exit, log and page.
run() {
  local name="$1"; shift
  cp "$SITE" "$WORK/$name.img"
  env "$@" COVERAGE_OUT="$COVERAGE" PEER_BODY="$WORK/$name.body" \
    timeout "$RUN_TIMEOUT" "$VMM" "$KERNEL" "$WORK/$name.img" "" "$PATH_WANTED" > "$WORK/$name.log" 2>&1
  echo $? > "$WORK/$name.exit"
  [ -f "$WORK/$name.body" ] || : > "$WORK/$name.body"
}

status_of() { sed -n 's/^peer: \([0-9]*\).*/\1/p' "$WORK/$1.log" | head -1; }
knobs_of() { sed -n 's/^metal-vmm: FAULT_SEED=[0-9]* is //p' "$WORK/$1.log" | head -1; }
broken_of() { sed -n 's/^metal-vmm: coverage: .*, \([0-9]*\) broken).*/\1/p' "$WORK/$1.log" | tail -1; }

# verdict <name>: "ok", "differs (allowed: ...)", or "FAIL: ..." for one run
# against the unhurt one.
verdict() {
  local name="$1" why="" exit status knobs broken excuse=""
  exit=$(cat "$WORK/$name.exit")
  status=$(status_of "$name")
  knobs=$(knobs_of "$name")
  broken=$(broken_of "$name")
  [ "$exit" = "$(cat "$WORK/unhurt.exit")" ] || why="$why, exit $exit (unhurt: $(cat "$WORK/unhurt.exit"))"
  [ "${broken:-0}" = 0 ] || why="$why, $broken coverage properties broken"
  if ! cmp -s "$WORK/$name.img" "$SITE"; then
    "$SOUND" "$WORK/$name.img" > "$WORK/$name.sound" 2>&1 || why="$why, the volume is not sound"
  fi
  if [ "$status" != "$(status_of unhurt)" ] || ! cmp -s "$WORK/$name.body" "$WORK/unhurt.body"; then
    for k in PEER_RESET_AT PEER_VANISH_AFTER DISK_REFUSE; do
      case " $knobs" in *" $k="*) excuse="$excuse${excuse:+, }$k" ;; esac
    done
    [ -n "$excuse" ] || why="$why, not the page (status ${status:-none})"
  fi
  if [ -n "$why" ]; then echo "FAIL: ${why#, }"
  elif [ -n "$excuse" ]; then echo "differs (allowed: $excuse)"
  else echo "ok"; fi
}

run unhurt
unhurt_status=$(status_of unhurt)
echo "unhurt: exit $(cat "$WORK/unhurt.exit"), status ${unhurt_status:-none}, $(wc -c < "$WORK/unhurt.body") bytes of $PATH_WANTED"
[ -n "$unhurt_status" ] || echo "  (the unhurt run got no page: every seed is judged against that)"
printf '%-6s %-4s %-6s %-8s %-40s %s\n' seed exit status bytes verdict knobs

failing=""
ok=0
allowed=0
seed="$FIRST"
while [ "$seed" -le "$LAST" ]; do
  run "seed$seed" FAULT_SEED="$seed"
  v=$(verdict "seed$seed")
  case "$v" in
    ok) ok=$((ok + 1)) ;;
    differs*) allowed=$((allowed + 1)) ;;
    *) failing="$failing $seed" ;;
  esac
  printf '%-6s %-4s %-6s %-8s %-40s %s\n' "$seed" "$(cat "$WORK/seed$seed.exit")" "$(status_of "seed$seed")" \
    "$(wc -c < "$WORK/seed$seed.body")" "$v" "$(knobs_of "seed$seed")"
  seed=$((seed + 1))
done

echo
echo "coverage over the sweep:"
merged=0
if [ -n "${FLOOR:-}" ]; then "$MERGE" --floor "$FLOOR" "$COVERAGE" || merged=1
else "$MERGE" "$COVERAGE" || merged=1; fi

echo
total=$((LAST - FIRST + 1))
echo "$total seeds: $ok ok, $allowed differ as their faults allow, $(echo $failing | wc -w) failed"
for s in $failing; do
  echo "  FAULT_SEED=$s: $(verdict "seed$s")"
  echo "    repeat it: $(knobs_of "seed$s") TRANSPORT=$TRANSPORT $VMM $KERNEL <volume> \"\" $PATH_WANTED"
done
[ -z "$failing" ] && [ $merged = 0 ]
