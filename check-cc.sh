#!/usr/bin/env bash
# **CC'S BRANCH ON A GUEST**, the box's first look at what CC pushed: what CC
# derived but could not run (it has no KVM), run before anyone reads the code.
#
# CC's branch (or master, where a repo has none) of metal-vmm, zig-metal-unikernel,
# angry-gopher, zig-webbox, shale and zig-coverage-sdk, each in its own worktree, so no checkout here changes:
#   1. angry-gopher ported into zig-metal-unikernel, a -Dcoverage kernel built, and
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
REPOS="${REPOS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BRANCH="${CC_BRANCH:-claude/great-wright-i7aste}"
# The repos CC works in: only these are taken from CC's branch. (dog-park
# is not checked here at all: the kernel neither builds nor judges it.)
CC_REPOS="${CC_REPOS:-metal-vmm zig-metal-unikernel angry-gopher zig-webbox shale zig-coverage-sdk}"
SEEDS="${SEEDS:-10}"
PLANT_SEEDS="${PLANT_SEEDS:-300}"
OUT="${OUT:-$(mktemp -d)}"
mkdir -p "$OUT"
SDK="$OUT/zig-coverage-sdk"
VOLUME_SITE="${VOLUME_SITE:-$HOME/build/zig-metal-unikernel/site/pristine.img}"

worktrees=()
cleanup() { for w in "${worktrees[@]}"; do git -C "${w%%:*}" worktree remove --force "${w#*:}" 2>/dev/null; done; }
trap cleanup EXIT

# checkout <repo> <dir>: CC's branch of the repo, or master, into <dir>.
checkout() {
  local repo="$REPOS/$1" ref
  git -C "$repo" fetch -q origin || return 2
  # The repo's main line (dog-park's is `main`), and CC's branch only when
  # it holds something the main line doesn't: a branch whose work is all
  # merged is behind it, and judging it judges old code.
  local main="origin/master"
  git -C "$repo" rev-parse -q --verify "$main" > /dev/null || main="origin/main"
  ref="$main"
  if [[ " $CC_REPOS " == *" $1 "* ]] &&
     git -C "$repo" rev-parse -q --verify "origin/$BRANCH" > /dev/null &&
     [ "$(git -C "$repo" rev-list --count "$main..origin/$BRANCH")" -gt 0 ]; then ref="origin/$BRANCH"; fi
  git -C "$repo" worktree add -q --detach "$2" "$ref" || return 2
  worktrees+=("$repo:$2")
  printf '%-13s %s %s (%s ahead of %s)\n' "$1" "$ref" "$(git -C "$2" rev-parse --short HEAD)" \
    "$(git -C "$repo" rev-list --count "$main..$ref")" "${main#origin/}"
}

echo "check-cc, $(date -u '+%F %T UTC'), in $OUT"
# The SDK too, from CC's branch when it holds work: zig-metal-unikernel's
# build.zig pins the SDK's commit, and CC moves the pin with its SDK change
# (198.2), so the box's own checkout would fail the pin. build.zig.zon
# finds it at ../zig-coverage-sdk.
for r in metal-vmm zig-metal-unikernel angry-gopher zig-webbox shale zig-coverage-sdk; do checkout "$r" "$OUT/$r" || exit 2; done

# angry-gopher's generated assets (wasm, built js) are untracked, so a
# worktree lacks them: copied from the main checkout, as built there.
python3 - "$REPOS/angry-gopher" "$OUT/angry-gopher" <<'PY' || { echo "the assets could not be copied"; exit 2; }
import os, re, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
# The embedded files are zig-server/assets.zon's (Phase B); paths are
# relative to zig-server/.
build = open(os.path.join(dst, "zig-server", "assets.zon")).read()
paths = re.findall(r'\.path\s*=\s*"([^"]+)"', build)
if not paths:
    sys.exit("assets.zon names no embedded path: has its shape changed?")
for path in paths:
    rel = os.path.normpath(os.path.join("zig-server", path))
    if not os.path.exists(os.path.join(dst, rel)) and os.path.exists(os.path.join(src, rel)):
        os.makedirs(os.path.dirname(os.path.join(dst, rel)), exist_ok=True)
        shutil.copy2(os.path.join(src, rel), os.path.join(dst, rel))
        print("  copied", rel)
PY

echo "== building"
(cd "$OUT/zig-metal-unikernel" && zig build gopher -Dcoverage -Dgopher-root="$OUT/angry-gopher" -Dwebbox-root="$OUT/zig-webbox" -Dshale-root="$OUT/shale") > "$OUT/kernel.log" 2>&1 ||
  { echo "the coverage kernel did not build; see $OUT/kernel.log"; exit 2; }
cp "$OUT/zig-metal-unikernel/probe/gopher.elf" "$OUT/gopher-coverage.elf"
(cd "$OUT/metal-vmm" && zig build) > "$OUT/vmm.log" 2>&1 ||
  { echo "metal-vmm did not build; see $OUT/vmm.log"; exit 2; }
echo "built"

bad=0
echo "== every shape, then seeds 1-$SEEDS"
KERNEL="$OUT/gopher-coverage.elf" SHAPES="$OUT/metal-vmm/requests/shapes" VOLUME_SITE="$VOLUME_SITE" TRANSPORT=pci \
  COVERAGE_SDK="$SDK" GUESTS="$OUT/zig-metal-unikernel/probe" \
  KEEP_FAILED="$OUT/failed" "$OUT/metal-vmm/sweep.sh" 1 "$SEEDS" > "$OUT/sweep.log" 2>&1
code=$?
grep -E '^shape .*(unhurt|answered|cannot|not )' "$OUT/sweep.log" | cut -c1-200
grep -E '^[0-9]+ .* FAIL: ' "$OUT/sweep.log" | cut -c1-200
tail -1 "$OUT/sweep.log"
case $code in
  0) ;;
  2) echo "sweep.sh could not judge (exit 2): the lines above name why"; bad=2 ;;
  *) echo "sweep.sh exit $code"; bad=1 ;;
esac

echo "== the plants"
GOPHER="$OUT/zig-metal-unikernel" COVERAGE_SDK="$SDK" GUESTS="$OUT/zig-metal-unikernel/probe" \
  ANGRY_GOPHER="$OUT/angry-gopher" WEBBOX="$OUT/zig-webbox" SHALE="$OUT/shale" VOLUME_SITE="$VOLUME_SITE" LAST="$PLANT_SEEDS" \
  KERNELS="$OUT/kernels" OUT="$OUT/plants" "$OUT/metal-vmm/plants.sh"
case $? in 0) ;; 1) bad=1 ;; *) echo "plants.sh could not run"; bad=2 ;; esac

echo "== $(case $bad in 0) echo 'every check holds' ;; 1) echo 'a check failed' ;; *) echo 'a step could not run' ;; esac); logs in $OUT"
exit $bad
