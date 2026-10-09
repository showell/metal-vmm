#!/usr/bin/env bash
# **CC'S BRANCH ON A GUEST**, the box's first look at what CC pushed: what CC
# derived but could not run (it has no KVM), run before anyone reads the code.
#
# CC's branch (or master, where a repo has none) of metal-vmm, gopher-metal
# and angry-gopher, each in its own worktree, so no checkout here changes:
#   1. angry-gopher ported into gopher-metal, a -Dcoverage kernel built, and
#      metal-vmm built;
#   2. `sweep.sh 1 $SEEDS` over every shape: each shape's unhurt run and its
#      recipe, then a few seeds (exit 2 there names the shape that can't be
#      judged);
#   3. `plants.sh`: the judge as CC left it still catches every plant, and
#      passes the clean kernel.
# What it says goes under "the box → CC" in FEEDBACK by hand.
#
#   ./check-cc.sh                   CC's usual branch
#   CC_BRANCH=claude/other ./check-cc.sh
#
# Exit 0 when every step holds, 1 when a check failed, 2 when a step could
# not run.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS="${REPOS:-$HOME/showell_repos}"
BRANCH="${CC_BRANCH:-claude/great-wright-i7aste}"
SEEDS="${SEEDS:-10}"
PLANT_SEEDS="${PLANT_SEEDS:-300}"
OUT="${OUT:-$(mktemp -d)}"
mkdir -p "$OUT"
SDK="${COVERAGE_SDK:-$REPOS/zig-coverage-sdk}"
# gopher-metal's build.zig.zon finds the SDK at ../zig-coverage-sdk.
[ -e "$OUT/zig-coverage-sdk" ] || ln -s "$SDK" "$OUT/zig-coverage-sdk"
VOLUME_SITE="${VOLUME_SITE:-$HOME/build/gopher-metal/probe/gopher/pristine.img}"

worktrees=()
cleanup() { for w in "${worktrees[@]}"; do git -C "${w%%:*}" worktree remove --force "${w#*:}" 2>/dev/null; done; }
trap cleanup EXIT

# checkout <repo> <dir>: CC's branch of the repo, or master, into <dir>.
checkout() {
  local repo="$REPOS/$1" ref
  git -C "$repo" fetch -q origin || return 2
  if git -C "$repo" rev-parse -q --verify "origin/$BRANCH" > /dev/null; then ref="origin/$BRANCH"; else ref="origin/master"; fi
  git -C "$repo" worktree add -q --detach "$2" "$ref" || return 2
  worktrees+=("$repo:$2")
  printf '%-13s %s %s (%s ahead of master)\n' "$1" "$ref" "$(git -C "$2" rev-parse --short HEAD)" \
    "$(git -C "$repo" rev-list --count "origin/master..$ref")"
}

echo "check-cc, $(date -u '+%F %T UTC'), in $OUT"
for r in metal-vmm gopher-metal angry-gopher; do checkout "$r" "$OUT/$r" || exit 2; done

echo "== building"
GOPHER_SRC="$OUT/angry-gopher/zig-server/src" GOPHER_PORT="$OUT/port" "$OUT/gopher-metal/port.sh" > "$OUT/port.log" 2>&1 ||
  { echo "port.sh failed; see $OUT/port.log"; exit 2; }
(cd "$OUT/gopher-metal" && zig build gopher -Dcoverage -Dgopher="$OUT/port") > "$OUT/kernel.log" 2>&1 ||
  { echo "the coverage kernel did not build; see $OUT/kernel.log"; exit 2; }
cp "$OUT/gopher-metal/probe/gopher.elf" "$OUT/gopher-coverage.elf"
(cd "$OUT/metal-vmm" && zig build) > "$OUT/vmm.log" 2>&1 ||
  { echo "metal-vmm did not build; see $OUT/vmm.log"; exit 2; }
echo "built"

bad=0
echo "== every shape, then seeds 1-$SEEDS"
KERNEL="$OUT/gopher-coverage.elf" SHAPES="$OUT/metal-vmm/requests/shapes" VOLUME_SITE="$VOLUME_SITE" TRANSPORT=pci \
  COVERAGE_SDK="$SDK" GUESTS="$OUT/gopher-metal/probe" FAT_READ="$OUT/gopher-metal/tools/fat16_read.py" \
  KEEP_FAILED="$OUT/failed" "$OUT/metal-vmm/sweep.sh" 1 "$SEEDS" > "$OUT/sweep.log" 2>&1
code=$?
grep -E '^shape .*(unhurt|answered|cannot|not )' "$OUT/sweep.log" | cut -c1-200
grep -E '^[0-9]+ .* FAIL: ' "$OUT/sweep.log" | cut -c1-200
tail -1 "$OUT/sweep.log"
case $code in
  0) ;;
  2) echo "sweep.sh could not judge (exit 2): the lines above name why"; bad=1 ;;
  *) echo "sweep.sh exit $code"; bad=1 ;;
esac

echo "== the plants"
GOPHER="$OUT/gopher-metal" GOPHER_PORT="$OUT/port" COVERAGE_SDK="$SDK" GUESTS="$OUT/gopher-metal/probe" \
  FAT_READ="$OUT/gopher-metal/tools/fat16_read.py" VOLUME_SITE="$VOLUME_SITE" LAST="$PLANT_SEEDS" \
  KERNELS="$OUT/kernels" OUT="$OUT/plants" "$OUT/metal-vmm/plants.sh"
case $? in 0) ;; 1) bad=1 ;; *) echo "plants.sh could not run"; bad=1 ;; esac

echo "== $([ $bad = 0 ] && echo 'every check holds' || echo 'a check failed'); logs in $OUT"
exit $bad
