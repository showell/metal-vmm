# tools/fresh.sh: sourced by metal-vmm's scripts. **A SCRIPT JUDGES THE
# BINARIES OF THE SOURCES IT IS RUN BESIDE, OR SAYS WHY NOT** (the
# protocols-in-prose hunt, 2026-10-10): each ran whatever metal-vmm and
# gopher.elf were on disk, and gates.sh records it once judged yesterday's
# kernel and passed.

# fresh_vmm <metal-vmm checkout>: metal-vmm built from what the checkout holds
# now (a build with nothing to do takes milliseconds). A script that is handed
# its own VMM (a test's fake, a nightly's copy) does not call this.
fresh_vmm() {
  (cd "$1" && zig build) > /dev/null 2>&1 || { echo "metal-vmm does not build from $1: run zig build there"; exit 2; }
}

# fresh_kernel <gopher.elf> <gopher-metal checkout>: refuses a kernel built
# from other kernel sources than the checkout's HEAD: one whose embedded commit
# (build.zig `commitOf`, as /admin/host shows it) is +dirty, is none of the
# last 500 commits, or is one since which src/, probe/, build.zig or
# build.zig.zon changed. A change to anything else (a doc) is no reason.
fresh_kernel() {
  local elf="$1" repo="$2" stamp c
  [ -f "$elf" ] || { echo "no $elf; in gopher-metal: zig build gopher"; exit 2; }
  stamp=""
  for c in $(git -C "$repo" log --format=%h -500); do
    if strings "$elf" | grep -qx "$c+dirty"; then echo "$elf was built from a dirty tree ($c+dirty): rebuild it from a commit"; exit 2; fi
    if strings "$elf" | grep -qx "$c"; then stamp=$c; break; fi
  done
  [ -n "$stamp" ] || { echo "$elf names none of gopher-metal's last 500 commits: rebuild it (zig build gopher)"; exit 2; }
  git -C "$repo" diff --quiet "$stamp" HEAD -- src probe build.zig build.zig.zon ||
    { echo "$elf was built at $stamp, and the kernel's sources changed since (HEAD is $(git -C "$repo" rev-parse --short HEAD)): rebuild it (zig build gopher)"; exit 2; }
}
