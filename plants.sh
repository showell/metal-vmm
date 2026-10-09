#!/usr/bin/env bash
# **THE PLANTS**: does the judge still catch a bug, and still pass a kernel
# that has none?
#
# Each `plants/<name>.patch` is a deliberate bug in gopher-metal, never to be
# merged. This builds the kernel at gopher-metal's HEAD as it is (the clean
# one) and once with each patch applied, all `-Dcoverage`, then sweeps the
# same seeds with each through this checkout's sweep.sh:
#
#   - the clean kernel must fail no seed: a failure there is the judge
#     crying wolf, or a real bug;
#   - each planted kernel must fail at least one seed, and every seed it
#     fails must be one where the plant fired (its `PLANT: <name> fires`
#     property reached); a failure where it didn't fire, that the clean
#     kernel passes, is the judge being inconsistent.
#
# Run it after every change to the judge (sweep.sh, sound.sh, the excuses),
# the box's or CC's. It says how often each plant fired and how often the
# judge caught it, so an excuse grown too wide shows as a plant that fires
# and is never caught.
#
#   ./plants.sh                 seeds 1-300, every plant
#   FIRST=1 LAST=100 ./plants.sh
#   PLANTS="net-goback-byte" ./plants.sh
#
# Kernels are kept in `$KERNELS` (default ~/nightly/kernels) by gopher-metal
# commit and patch, so a second run builds nothing. The port is gopher-metal's
# usual one, `$GOPHER_PORT` (`./port.sh` first, if angry-gopher moved); a
# kernel's name carries gopher-metal's commit and the port's content hash
# (`PORTED_FROM`), so a new port builds anew. Exit 0 when every
# check holds, 1 when one doesn't, 2 when something could not be built or
# judged at all.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GOPHER="${GOPHER:-$HOME/showell_repos/gopher-metal}"
KERNELS="${KERNELS:-$HOME/nightly/kernels}"
PORT="${GOPHER_PORT:-$HOME/build/gopher-metal/port}"
SHAPES="${SHAPES:-$HERE/requests/shapes}"
VOLUME_SITE="${VOLUME_SITE:-$HOME/build/gopher-metal/probe/gopher/pristine.img}"
FIRST="${FIRST:-1}"
LAST="${LAST:-300}"
OUT="${OUT:-$(mktemp -d)}"
mkdir -p "$OUT"
# gopher-metal's build.zig.zon finds the SDK at ../zig-coverage-sdk, so a
# worktree here needs it beside it.
[ -e "$OUT/zig-coverage-sdk" ] || ln -s "${COVERAGE_SDK:-$HOME/showell_repos/zig-coverage-sdk}" "$OUT/zig-coverage-sdk"
# and its build finds angry-gopher's assets at ../angry-gopher.
[ -e "$OUT/angry-gopher" ] || ln -s "${ANGRY_GOPHER:-$HOME/showell_repos/angry-gopher}" "$OUT/angry-gopher"

names=()
if [ -n "${PLANTS:-}" ]; then
  for p in $PLANTS; do names+=("$p"); done
else
  # plants/pending/ holds those the judge cannot see yet (its README).
  for f in "$HERE"/plants/*.patch; do names+=("$(basename "$f" .patch)"); done
fi

commit=$(git -C "$GOPHER" rev-parse --short HEAD) || exit 2
[ -z "$(git -C "$GOPHER" status --porcelain --untracked-files=no)" ] ||
  { echo "gopher-metal has uncommitted changes; plants build from a commit"; exit 2; }
sdk=$(git -C "${COVERAGE_SDK:-$HOME/showell_repos/zig-coverage-sdk}" rev-parse --short HEAD) || exit 2
ported=$(grep -o 'content-[0-9a-f]*' "$PORT/PORTED_FROM" 2>/dev/null | cut -c9-20)
[ -n "$ported" ] || { echo "no port at $PORT (gopher-metal's ./port.sh)"; exit 2; }
mkdir -p "$KERNELS"

# build <name>: the kernel for "clean" or a plant, built once per commit and
# patch, its path on stdout.
build() {
  local name="$1" tag elf wt
  tag="$commit-ag$ported-sdk$sdk"
  [ "$name" = clean ] || tag="$tag-$(sha256sum "$HERE/plants/$name.patch" | cut -c1-8)"
  elf="$KERNELS/gopher-coverage-$name-$tag.elf"
  if [ ! -f "$elf" ]; then
    wt="$OUT/build-$name"
    git -C "$GOPHER" worktree add -q --detach "$wt" "$commit" >&2 || return 2
    building="$wt"
    if [ "$name" != clean ]; then
      git -C "$wt" apply "$HERE/plants/$name.patch" >&2 ||
        { echo "plants/$name.patch no longer applies at gopher-metal $commit" >&2; git -C "$GOPHER" worktree remove --force "$wt"; return 2; }
    fi
    (cd "$wt" && zig build gopher -Dcoverage -Dgopher="$PORT") >&2 && cp "$wt/probe/gopher.elf" "$elf"
    local ok=$?
    git -C "$GOPHER" worktree remove --force "$wt"
    building=""
    [ $ok = 0 ] || { echo "the $name kernel did not build" >&2; return 2; }
  fi
  echo "$elf"
}

# sweep <name> <elf>: the seeds through this checkout's judge; the log is
# $OUT/<name>.log and the failed seeds' files $OUT/<name>-failed/.
sweep() {
  KERNEL="$2" SHAPES="$SHAPES" VOLUME_SITE="$VOLUME_SITE" TRANSPORT=pci \
    KEEP_FAILED="$OUT/$1-failed" "$HERE/sweep.sh" "$FIRST" "$LAST" > "$OUT/$1.log" 2>&1
}

failed_seeds() { sed -n -E 's/^([0-9]+) .* FAIL: .*/\1/p' "$OUT/$1.log"; }

building=""
trap '[ -z "$building" ] || git -C "$GOPHER" worktree remove --force "$building"' EXIT

# judged <name>: the sweep ended with its summary line ("N seeds: ..."); a
# sweep that stopped on a precondition (exit 1 or 2 with no summary) judged
# nothing, and says so rather than passing for a clean kernel.
judged() { grep -qE '^[0-9]+ seeds: ' "$OUT/$1.log"; }

bad=0
echo "plants, gopher-metal $commit, metal-vmm $(git -C "$HERE" rev-parse --short HEAD), seeds $FIRST-$LAST, logs in $OUT"
clean_elf=$(build clean) || exit 2
sweep clean "$clean_elf"; code=$?
judged clean || { echo "clean: sweep.sh judged nothing (exit $code); see $OUT/clean.log"; exit 2; }
clean_failed=$(failed_seeds clean | tr '\n' ' ')
if [ -n "$clean_failed" ]; then
  echo "FAIL  clean: seeds failed with no plant: $clean_failed"; bad=1
else
  echo "ok    clean: no seed failed ($(tail -1 "$OUT/clean.log"))"
fi

for name in "${names[@]}"; do
  elf=$(build "$name") || exit 2
  sweep "$name" "$elf"; code=$?
  judged "$name" || { echo "$name: sweep.sh judged nothing (exit $code); see $OUT/$name.log"; exit 2; }
  fires="PLANT: $name fires"
  fired=$(grep -F "  $fires  (" "$OUT/$name.log" | sed -n -E 's/.*reached by ([0-9]+) of ([0-9]+) runs.*/\1 of \2 runs/p' | head -1)
  caught=0; stray=""
  for s in $(failed_seeds "$name"); do
    if grep -qF "\"message\":\"$fires\"" "$OUT/$name-failed/seed$s/seed$s.cov" 2>/dev/null &&
       grep -F "\"message\":\"$fires\"" "$OUT/$name-failed/seed$s/seed$s.cov" | grep -q '"hit":true'; then
      caught=$((caught + 1))
    else
      case " $clean_failed " in *" $s "*) ;; *) stray="$stray $s" ;; esac
    fi
  done
  if [ -n "$stray" ]; then
    echo "FAIL  $name: failed where the plant never fired and the clean kernel passed:$stray"; bad=1
  elif [ "$caught" = 0 ]; then
    echo "FAIL  $name: never caught (it fired in ${fired:-0 runs})"; bad=1
  else
    echo "ok    $name: caught in $caught seeds; it fired in ${fired:-? runs}"
  fi
done
exit $bad
