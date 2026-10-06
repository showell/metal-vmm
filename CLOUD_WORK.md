# Working on metal-vmm from a cloud session

For Claude Code running in the cloud ("CC"). Read this at the start of every
session, then read `QUEUE.md`. This is the same arrangement gopher-metal ran
on until 2026-10-04 (its `CLOUD.md`, retired, is in gopher-metal's
`git show c28a6ec~1:CLOUD.md`), cut down to this repo.

## What this is for

metal-vmm is our own deterministic hypervisor: gopher-metal's kernels run on
it, and the same guest with the same seed gives the same run, byte for byte.
Steve's long-term aim is an explorer like Antithesis's: a machine that keeps
choosing faults and inputs, steered toward runs that reach properties no run
has reached yet (zig-coverage-sdk's `sometimes`). That is not the work yet.
The work now is making the machine more faithful, and better tested, without
giving up determinism. The README's "Interrupts, at a halt" says where it
stands; read it, and `src/pci.zig` and `src/apic.zig`, before anything else.

## Who does what

- **Steve** decides. He relays between the two Claudes only when he wants to;
  the default channel is git.
- **The box Claude** works on Steve's development droplet, which has KVM and
  QEMU. It runs the guests: `check.sh`, `same.sh`, `site.sh`, `rest.sh`,
  `lossy.sh` and the rest. It merges your branch into `interrupts` once the
  unit tests pass and runs the guests alongside: they catch edge cases, which
  come back to you as new items. It owns gopher-metal, the guest side of
  every contract here.
- **You (CC)**: logic, tests that run on ordinary Linux, adversarial reading,
  and design. You have no `/dev/kvm`, so no guest ever boots in your
  container. Do not try to get one.

**Run unattended for as long as the queue gives you work.** When something
is the box Claude's or Steve's to do, write it under "Questions" in
`QUEUE.md` and take the next item. Do not wait.
**An item in the CC section of `QUEUE.md` is permission to start it**:
never ask Steve or the box whether to. When you finish one, `git fetch` and
reread `QUEUE.md` on `interrupts`, since the box adds items as it goes. Only
an empty queue ends a session.

## Most of it is logic

Everything in `src/` except the ioctls in `kvm.zig` and the run loop in
`main.zig` is a model: the PCI bus, MSI-X, the APIC, the clock, the virtio
rings, the peer's TCP, the faults. A model is tested on Linux like any code.
`zig build test` runs 48 of them today, and none needs KVM.

So treat "this needs a guest" as a smell. When you meet a behavior only the
box's scripts check, ask how to check it here:

- **Drive the device as the driver does.** `virtio.zig`'s `FakeGuest` lays out
  a queue the way gopher-metal's driver does and drives the mmio window
  through it. The same over PCI (config space, capabilities, common config,
  MSI-X) is item 2.
- **Extract the decision from the I/O.** `main.zig`'s `rest` decides when a
  halted guest wakes and on what. That decision is pure and can be tested
  without a vCPU once it is pulled out (item 3).
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
  to `master`, `interrupts` or `antithesis-sdk`, which are the box's.
- **Rebase on `origin/interrupts` before every push.** The box merges your
  branch, so a stale base costs it a conflict.
- **One topic per commit.** Its message says what changed and why, what you
  verified (`zig build test`, `zig fmt --check src`), and what you could not
  (anything needing a guest).
- **`QUEUE.md` is shared.**
  - Mark an item yours in your branch when you start it.
  - Mark it done in the commit that finishes it.
  - Add items you discover under "Proposed", with a line each on why.
- **The box answers on `interrupts`:** in `QUEUE.md` under "Answers", in a
  `docs/reviews/REVIEW-*.md` file, or in the merge itself. Fetch it to see
  them.

## The branches, all of them

Three repos, one queue (this repo's `QUEUE.md`, on `interrupts`). Nothing else
is live; if you see a branch not listed here, ask under Questions before
building on it.

| repo | branch | whose | what |
|---|---|---|---|
| metal-vmm | `interrupts` | the box | the base: you branch from it, the box merges into it |
| metal-vmm | `claude/<your session's name>` | you | your work, rebased on `origin/interrupts` |
| metal-vmm | `master` | the box | untouched until Steve merges `interrupts` |
| gopher-metal | `antithesis-sdk` | the box | the base for the simulators: branch from it, the box merges into it |
| gopher-metal | `claude/<your session's name>` | you | simulator work, rebased on `origin/antithesis-sdk` |
| zig-coverage-sdk | `main` | the box | the base for SDK work: branch from it, the box merges into it |
| zig-coverage-sdk | `claude/<your session's name>` | you | SDK work, rebased on `origin/main` |
| gopher-metal | `box/v18` | the box | the next image after v17: flush before any response leaves (B11). Read it; do not branch from it |
| gopher-metal | `master` | the box | **what serves lynrummy.com. Never push, never branch from it.** |

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
`CLAUDE.md` on `antithesis-sdk` (master's still says a cloud session stops:
it predates this) and its `COVERAGE.md`, then `TCP_TESTING.md`.

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
- `zig build test` there takes about a minute; `zig build properties
  -Dseeds=n` sweeps. Run the sweep at a size your container can afford and
  say the size in the commit.

## Limits

- **Your container's disk is small, and zig fills it.** Clear `.zig-cache`
  between large runs.
- Do not change the scripts (`check.sh`, `same.sh`, `site.sh`, `rest.sh`,
  `lossy.sh`, `flaky.sh`, `sound.sh`) without saying so in `QUEUE.md`.
  gopher-metal's `gates.sh` runs three of them on a machine you cannot see.
- A review has this shape: what holds up; findings by severity, each with the
  failure it causes and how likely it is; fix shapes; and nothing fixed in
  the review commit itself.
