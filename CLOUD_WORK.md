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
  `lossy.sh` and the rest. It merges your branch into `interrupts` after
  running them, and it owns gopher-metal, the guest side of every contract
  here.
- **You (CC)**: logic, tests that run on ordinary Linux, adversarial reading,
  and design. You have no `/dev/kvm`, so no guest ever boots in your
  container. Do not try to get one.

**Run unattended for as long as the queue gives you work.** When something
is the box Claude's or Steve's to do, write it under "Questions" in
`QUEUE.md` and take the next item. Do not wait.

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

- **Push to the branch your session is given.** Never to `master`, and never
  to `interrupts`, which is the box's.
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

## Limits

- **Your container's disk is small, and zig fills it.** Clear `.zig-cache`
  between large runs.
- Do not change the scripts (`check.sh`, `same.sh`, `site.sh`, `rest.sh`,
  `lossy.sh`, `flaky.sh`, `sound.sh`) without saying so in `QUEUE.md`.
  gopher-metal's `gates.sh` runs three of them on a machine you cannot see.
- A review has this shape: what holds up; findings by severity, each with the
  failure it causes and how likely it is; fix shapes; and nothing fixed in
  the review commit itself.
