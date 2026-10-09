# Working on metal-vmm from a cloud session

For Claude Code running in the cloud ("CC"). Read this at the start of every
session, then read `QUEUE.md`. This is the same arrangement gopher-metal ran
on until 2026-10-04 (its `CLOUD.md`, retired, is in gopher-metal's
`git show c28a6ec~1:CLOUD.md`), cut down to this repo.

## What this is for

metal-vmm is our own deterministic hypervisor: gopher-metal's kernels run on
it, and the same guest with the same seed gives the same run, byte for byte.
**The goal is zero bugs in the lower levels** (gopher-metal first, then this
repo); angry-gopher is the reality check, not the only consumer. Judge the
kernel by its own promises (gopher-metal's STORE.md and HOST.md).

What works best, so far, is **a class hunt**: name one kind of mistake,
walk every place in the code it could live, and end in red tests. Seed
sweeps find less than they cost. The judge is moving from "does this run
differ from the unhurt one, and is the difference excused?" to "did anything
forbidden happen?", and `plants.sh` (a standing set of planted bugs) is to
run on every change to it (written 2026-10-09; its first run is pending). The whole-machine snapshot (`docs/SNAPSHOT.md`) is
parked. Essays: `notes/the-plan-after-the-postmortem.md`,
`notes/our-lexicon.md` (the shared vocabulary).

## Who does what

- **Steve** decides. He relays between the two Claudes only when he wants to;
  the default channel is git.
- **The box Claude** works on Steve's development droplet, which has KVM and
  QEMU. It runs the guests: `check.sh`, `same.sh`, `site.sh`, `rest.sh`,
  `sweep.sh`, `nightly.sh` and the rest. It merges your branch into `master`
  after `check-cc.sh` (your branch built and swept on a guest, then
  `plants.sh`; its first run is pending), a cold review and the unit tests; what the guests catch comes
  back to you as new items. It owns gopher-metal,
  the guest side of every contract here, and the releases.
- **You (CC)**: build what needs no emulator, and anything adversarial
  (Steve, 2026-10-08): logic, tests that run on ordinary Linux, attacking
  what the box changed, design. You have no `/dev/kvm`, so no guest ever
  boots in your container. Do not try to get one.
- **Talk in `FEEDBACK.md`** (this repo, newest entry first, signed). Say
  there when a task should have been split, when a check is too slow to run,
  when you disagree with an item, or when you are stuck (one line, then
  stop: Steve wakes whichever of us is needed).

**Run unattended for as long as the queue gives you work.** When something
is the box Claude's or Steve's to do, write it under "Questions" in
`QUEUE.md` and take the next item. Do not wait.
**An item in the CC section of `QUEUE.md` is permission to start it**:
never ask Steve or the box whether to. When you finish one, `git fetch` and
reread `QUEUE.md` on `master`, since the box adds items as it goes. Only
an empty queue ends a session.

## Most of it is logic

Everything in `src/` except the ioctls in `kvm.zig` and the run loop in
`main.zig` is a model: the PCI bus, MSI-X, the APIC, the clock, the virtio
rings, the peer's TCP, the faults. A model is tested on Linux like any code.
`zig build test` runs them all, and none needs KVM.

So treat "this needs a guest" as a smell. When you meet a behavior only the
box's scripts check, ask how to check it here:

- **Drive the device as the driver does.** `virtio.zig`'s `FakeGuest` lays out
  a queue the way gopher-metal's driver does and drives the mmio window
  through it; `virtio_pci.zig`'s does the same over PCI (config space,
  capabilities, common config, MSI-X).
- **Extract the decision from the I/O.** When a halted guest wakes, and on
  what, is `halt.zig`'s `wakes`: pure, and tested without a vCPU.
- **Read the guest's side.** gopher-metal's `src/pci.zig`, `src/virtio.zig`
  and `src/interrupts.zig` are what the guest does. They are public
  (github.com/showell/gopher-metal); clone it read-only. Do not push to it.
- **Read the spec, not our code**, when writing a test's expectation: virtio
  1.2 §4.1 (PCI), PCI 3.0 §6.8.2 (MSI-X), Intel SDM vol. 3 ch. 11 (APIC). A
  test written from our code agrees with its bugs.

## Rules this machine lives by

- **Determinism is the point.** Nothing in this program reads the host's
  clock, the host's randomness, or anything else outside the guest's own
  inputs. Time is the guest's questions (`clock.zig`); a halt's length is
  computed, never waited. A change that breaks this is wrong, however much
  else it fixes.
- **The file on disk is never changed.** The loader rewrites marked
  instructions in guest memory only, so QEMU runs the same bytes and stays an
  honest oracle (README, "`rdtsc` does not exit").
- **Contracts with the guest are the box's.** The marks (`mov $"mvmc", %ecx`
  before `rdtsc`, `mov $"mvmd", %esi` before the deadline `wrmsr`) and
  anything else that needs gopher-metal to change: propose it under
  "Proposed" in `QUEUE.md`, and do not build on it until it is answered.
- **`TRANSPORT` unset is the microvm-shaped machine**, and `check.sh` holds
  it to QEMU's microvm. Nothing you change may alter what it does.
- Never weaken a test to make it pass, and never make a check skip silently.
  If a test is wrong, say why in the commit that changes it.
- Comments say what holds and why, in the present tense, in the README's
  voice: no change history in source.

## Git is the channel

- **Push to the branch your session is given** (see "The branches"). Never
  to `master` or `main`, which are the box's.
- **Merge `master` into your branch; never rebase** (agreed 2026-10-08): a
  rebase rewrites hashes already cited in `QUEUE.md`.
- **One topic per commit.** Its message says what changed and why, what you
  verified (`zig build test`, `zig fmt --check src`), and what you could not
  (anything needing a guest).
- **`QUEUE.md` is shared.**
  - Mark an item yours in your branch when you start it.
  - Mark it done in the commit that finishes it.
  - Add items you discover under "Proposed", with a line each on why.
- **The box answers on `master`:** in `FEEDBACK.md`, in `QUEUE.md` under
  "Answers", in a `docs/reviews/REVIEW-*.md` file, or in the merge itself.
  Fetch it to see them.

## The branches, all of them

Every repo works on **`master`** (since 2026-10-06, Steve: "these are all
Steve-owned projects"). One queue: this repo's `QUEUE.md`, on `master`.
Nothing else is live; if you see a branch not listed here, ask under
Questions before building on it.

| repo | branch | whose | what |
|---|---|---|---|
| metal-vmm | `master` | the box | the base: you branch from it, the box merges into it |
| gopher-metal | `master` | the box | the base: you branch from it, the box merges into it |
| zig-coverage-sdk | `main` | the box | the base: you branch from it, the box merges into it |
| angry-gopher | `master` | the box | the base: you branch from it, the box merges into it |
| gopher-metal, angry-gopher | `next` | the box | integration while `master` is held for a release's gates; `master` fast-forwards to it after the tag. Never branch from it |
| each of them | `claude/<your session's name>` | you | your work, with that repo's base merged in |

**What serves lynrummy.com is a tag, not a branch**: gopher-metal's `vN`,
and its README's "Serving" line says which. `master` may be
ahead of it. `interrupts` and `antithesis-sdk` are retired: both are merged
into `master`; don't branch from them.

Use the same `claude/<name>` in both repos. Each QUEUE.md item says which
repo it is in; an item in gopher-metal is merged there, and its answer comes
here like any other.

## zig-coverage-sdk: the SDK

Since 2026-10-06 you work on github.com/showell/zig-coverage-sdk too: the
properties API (`src/coverage.zig`), its scanner (`tools/scan.zig`) and its
report (`tools/report.py`). Read its README first, "Where this differs from
Antithesis" above all: those differences are decisions, not gaps.

- **gopher-metal builds against it as a sibling checkout**
  (`.path = "../zig-coverage-sdk"` in its `build.zig.zon`), with no version
  pin. A merge into `main` changes gopher-metal's build at once. So every
  existing call keeps compiling and meaning what it meant; add, never
  change. Say in the commit what gopher-metal would see.
- **Follow Antithesis's documented names and JSON** for anything they have
  (their SDK docs and the JSONL they describe), and say where you could not.
  The README's line stays: inspired by Antithesis, not endorsed, not yet
  compatible.
- Its tests are `zig build test` there; `tools/report.py` has its own.

## gopher-metal: the simulators

Since 2026-10-05 you work in gopher-metal too, on the **simulators and
properties only**: `src/tcp_sim.zig`, `src/fat_sim.zig`, `src/properties.zig`,
new simulators beside them, their regression seeds, and `coverage/floor-sim.txt`
(raise it; never lower it without a line in QUEUE.md saying why). Read its
`CLAUDE.md` and its `COVERAGE.md`, then `TCP_TESTING.md`.

**Why the simulators exist: they keep the layers honest.** A simulator drives
only pure logic, code that needs no driver, no device, and no clock but the
one it is handed. `tcp.zig` is simulated because it is a layer with nothing
below it; a module that reaches into `io.zig` cannot be, and that is a fact
about the module, not a gap in the simulator. So:

- **Never mock I/O to reach a module.** Propose the seam instead, under
  Proposed: which pure decision comes out, what I/O stays behind. The box
  decides, because the module serves lynrummy.com.
- **A failing seed is the code's or the simulator's, and you say which.** A
  model that is wrong blames the code for its own mistake (seed 23953 did:
  the model client went silent after TIME-WAIT, gopher-metal `02de06f`).
  Read the RFC, not the model, before calling it the code's.
- **A simulator finds; it does not fix the code it drives.** A defect in
  `tcp.zig`, `fat16.zig` or any module the kernel runs is a seed kept as a
  named regression test, failing, plus a line under Questions. The box fixes
  it and decides whether it needs a new image for the site.
- **Since 2026-10-06, the Store too** (QUEUE 76-81): its interface, model,
  FAT store, strict Linux store and `store_sim` are new files the image
  doesn't use, so they're yours to write *and* to fix. Properties may go in
  any module the kernel runs (item 36's rule: observe, never steer). The
  rule above still holds for those modules: a defect in one is a named
  failing test plus a line under Questions, and the box fixes it.
- `zig build test` there takes about a minute; `zig build properties
  -Dseeds=n` sweeps. Run the sweep at a size your container can afford and
  say the size in the commit.

## Limits

- **Your container's disk is small, and zig fills it.** Clear `.zig-cache`
  between large runs.
- Do not change the scripts (`check.sh`, `same.sh`, `site.sh`, `rest.sh`,
  `lossy.sh`, `flaky.sh`, `sound.sh`) without saying so in `QUEUE.md`.
  gopher-metal's `gates.sh` runs three of them on a machine you cannot see.
  A change to the judge (`sweep.sh`, `sound.sh`, an excuse) says so in its
  commit, so the box runs `plants.sh` before merging it.
- A review has this shape: what holds up; findings by severity, each with the
  failure it causes and how likely it is; fix shapes; and nothing fixed in
  the review commit itself.

## Essays

An essay the box points you to lives in github.com/showell/essay-repl-server
under `notes/`: read it at
`https://github.com/showell/essay-repl-server/blob/master/notes/<name>.md`.
The box's own address for them (port 9100) isn't reachable from your
environment.

## Long assignments

A long assignment is meant to run
for hours with no one to ask, so it hands you more judgment than an ordinary
item. These rules are what make that safe.

How to work, on any long assignment:

- **Every item ends in a command and a number.** Say in the commit what
  `zig build properties` (or the test) printed: "`proto`: 11 of 12 reached;
  the 12th is under Questions".
- **Park after about three attempts.** If an item has taken about three
  tries without a passing test, write what you know under Questions (what
  you tried, what failed, the shortest reproduction), mark the item
  **parked**, and take the next one. Parked is not failed; the box can often
  settle it in a minute with KVM.
- **A refusal is reported, never routed around.** If your own checks stop
  you, say what stopped you under Questions and move on.
- **You decide:** names, file layout, test structure, which simulator reaches
  which property, module order within a phase, and fixes to your own earlier
  work. **You ask, under Questions, and keep going:** a seventh Store
  operation, anything that changes kernel behavior, anything in angry-gopher,
  and anything that looks like a bug in production.
- **A found bug is a test first.** Write the failing case. If the bug is in
  code you wrote for this assignment (the Store, a simulator), fix it in the
  same commit. If it's in a module the kernel runs, file it under Questions
  as a bug, with the test committed but left out of the default run
  *and named there*, so it's visible, never silently skipped. Then move on.
- **Green at every push.** Each commit leaves `zig build test` and `zig build
  properties` passing. Push after every item. Merge each repo's `master` (or
  `main`) into your branches at phase boundaries, not mid-phase.
- **A phase report, five lines,** under the phase's item when it's done:
  what was reached, what's parked, what was asked, what surprised you, and
  the floor's count before and after.

**Debt, calibrated.** Leave freely, and write one line in **the debt
ledger** (a new section at the end of `QUEUE.md`: what, where, what fixing it
would take): duplicated helpers across simulators, a crude generator that
still reaches the property, an awkward property name, a module reached only
by a host test so far. **Never**, whatever it saves: a test weakened or an
oracle loosened until it passes; a property that can't fire, written to make
the count look good; a skip without a name; kernel behavior changed as a side
effect of adding a property.
