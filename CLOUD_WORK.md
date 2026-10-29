# Working on metal-vmm from a cloud session

For Claude Code running in the cloud ("CC"). Read this at the start of every
session, then read `QUEUE.md`. **Read "Wall time is the cost" below first, and
reread it whenever something is slow.** This is the same arrangement zig-metal-unikernel ran
on until 2026-10-04 (its retired guide is in zig-metal-unikernel's
`git show c28a6ec~1:CLOUD.md`), cut down to this repo.

## What this is for

metal-vmm is our own deterministic hypervisor: zig-metal-unikernel's kernels run on
it, and the same guest with the same seed gives the same run, byte for byte.
**The goal is zero bugs in the lower levels** (zig-metal-unikernel first, then this
repo); angry-gopher is the reality check, not the only consumer. Judge the
kernel by its own promises (zig-metal-unikernel's STORE.md and HOST.md).

What works best, so far, is **a class hunt**: name one kind of mistake,
walk every place in the code it could live, and end in red tests. Seed
sweeps find less than they cost. The judge is moving from "does this run
differ from the unhurt one, and is the difference excused?" to "did anything
forbidden happen?", and `plants.sh` (a standing set of planted bugs, the
names in zig-metal-unikernel build.zig's `Plant` enum) runs on every change
to it. The whole-machine snapshot (`docs/SNAPSHOT.md`) is
parked. Essays: `notes/the-plan-after-the-postmortem.md`,
`notes/our-lexicon.md` (the shared vocabulary).

## Wall time is the cost

**Steve, 2026-10-27: "Claude has to stop tolerating long wall times! I
can't stress this enough. It's a mindset problem more than a tooling
issue."** And: "Anything that's not sub-second in our world is highly
fishy." And: "any run longer than a coffee break should be discussed."
Steve would rather have an item finished fast and a little rough than
finished slowly and complete. An item that finishes early is a good
problem to have. The bad problem is a rabbit hole that eats an hour
nobody asked for.

**A slow loop is a bug to find, not a wait to sit through.**
- **Time every loop**: the build, the test, the gate, a GitHub run. Say the
  number in FEEDBACK.
- **A build and a run are two numbers**, each naming the program that spent
  it. "zig build test took 4 minutes" says nothing until it is split into
  compile and run.
- **Anything over about a minute that should take seconds** gets its cause
  found before you go on.
- **Check the defaults first.** Is it in release mode when Debug would do?
  Is the build rebuilding what didn't change? Is it running every test when
  one file would answer the question?

These are real costs from 2026-10-27:
- `roc build` defaulted to an LLVM release build: 5 min 21 s, against 0.9 s
  with `--opt=dev`.
- A gate slept 20 minutes waiting on someone else's tree.
- A mutant run printed megabytes.
- Steps that took 45 minutes took 2-12 once those were found.

**Before any run longer than about 30 seconds, ask what it tells you that a
short, crafted one wouldn't.** Two runs that cover the same ground are the
same evidence at different prices. Never answer a slow run with a longer
one. These choices have been worth minutes each:
- one test file (`zig build test -Dtest-file=<file>`) instead of the whole
  suite;
- a filter instead of every case;
- a few seeds instead of a sweep;
- Debug instead of a release build.

A run you expect to pass 10 minutes goes in FEEDBACK first, as a question,
unless the item already asks for it.

**Time-box every sub-problem, and watch for rabbit holes.**
- **Fifteen minutes without progress on one question:** stop. Write what you
  know (what you tried, what it showed, the shortest reproduction) under
  Questions, and take the next piece of the item.
- **A tangent that isn't the item:** a bug in a tool, a nicer abstraction, a
  second thing you noticed. Give it one line in FEEDBACK, "Found on the
  way", and keep going. Never fix it inline unless it blocks the item.
- **Before a step, estimate what it will cost.** If it comes in at more than
  twice that, stop and say why before spending more.
- **Polish is the last thing**, after the deliverable is green and pushed.

**Never sit waiting on something slow.**
- A GitHub Actions run (`cookbook/gh_build.shale`) is fire-and-forget: start
  it, carry on with other work, and read its result later. Never poll in a
  loop. Never let a 20-minute CI run be the thing your session waits for.
- If the next step really does need the result, push and report what is
  pending: the run's URL, and what red or green would mean. The box reads it
  when it lands.

**Report time like a result.** Each FEEDBACK entry for an item says:
- the wall time it took;
- the slowest single step, and why it was slow;
- anything you cut, or parked, to keep it moving.

## Shale first

**Steve, 2026-10-27:** "Even though python/bash/sed/awk/grep can be more
convenient at times, I truly believe well-written shale will eventually make
CC more productive." This rule holds even when the shell would be quicker
this once:
- **No Python.**
- **Bash, sed, awk and grep are for what Shale can't do yet.** When you reach
  for one, write the gap as a line in FEEDBACK ("Shale wants: ..."), or fix
  it in Shale if it's small. We maintain Shale: a gap is fixed in Shale, not
  routed around.

Every routine operation already has a Shale form. Use it:
- **Merges: `git_merge(repo, ref)`** (the git prelude). It merges, and
  **on a conflict it undoes the merge** (`merge --abort`) and stops, naming
  the conflicted files. A checkout is never left half-merged. Never resolve
  a conflict in `FEEDBACK.md` or `QUEUE.md` by hand-editing markers. That is
  how archived entries come back from the dead, and how entries end up out
  of order or glued to the line above. **Merging master into your
  metal-vmm branch: `shale .shale/merge_master.shale`**: `git_merge`, and a
  conflict in the queue's four files alone resolved three ways: FEEDBACK.md
  by its entries (`feedback_merge`), QUEUE.md by its items (`queue_merge`),
  the archives by their lines; checked by `queue_check`, then committed.
- **FEEDBACK: `feedback_add(from, to, title, body)`** (metal-vmm's
  `.shale/prelude.shale`, loaded when you run `shale` from this repo's
  root). It writes the heading in the house form, dates it, puts it at the
  top, and refuses an out-of-order date. Never hand-edit a new entry in.
- **QUEUE:** `queue_add`, `queue_done`, `queue_archive`, `queue_next`,
  `queue_check`. `queue_add` refuses a body line that would read as an item
  or a section.
- **Git otherwise:** `git_log`, `git_diff`, `git_show`, `git_status`,
  `git_commit(repo, msg, {add})`, `git_push`, `git_worktree_add`.
- **Finding and reading:** `shale cookbook:look.shale find=... in=...` and
  `at=file:a-b`.
- **Programs:** `run` (or `cookbook:run.shale`) instead of `cmd | tail | grep`.
- **GitHub:** `cookbook/gh_build.shale`.

The full list is in shale's `docs/SHALE-AGENTS.md`, under "Before you reach
for the shell". Read it once per session.

## Who does what

- **Steve** decides. He relays between the two Claudes only when he wants to;
  the default channel is git.
- **The box Claude** works on Steve's development droplet, which has KVM and
  QEMU. It runs the guests: `check.sh`, `same.sh`, `site.sh`, `pc_vs_microvm.sh`,
  `sweep.sh`, `nightly.sh` and the rest. It merges your branch into `master`
  after `check-cc.sh` (your branch built and swept on a guest, then
  `plants.sh`), a cold review and the unit tests; what the guests catch comes
  back to you as new items. It owns zig-metal-unikernel,
  the guest side of every contract here, and the releases.
- **You (CC)**: build what needs no emulator, and anything adversarial
  (Steve, 2026-10-08): logic, tests that run on ordinary Linux, attacking
  what the box changed, design. You have zig, Python and QEMU under TCG
  (software emulation), but no `/dev/kvm`, no TAP and no vfat mounts: a
  guest boots in your container under QEMU, never under metal-vmm, and
  metal-vmm's scripts, the native judge and the sweeps are the box's. Do not
  try to get KVM.
- **Build with the patched Zig, as the box does** (Steve, 2026-10-27). It is
  `0.17.0+patched.N`, from github.com/showell/patched-zig-compiler: 0.17.0
  plus a few fixes, listed in its PATCHES.md. Install it at the start of a session:
  `curl -fsSL https://raw.githubusercontent.com/showell/patched-zig-compiler/main/tools/get_zig.sh | sh`
  (from a project root, it honours that project's `zig-version`), and put
  `~/.local/bin` first on the PATH. `zig version` must say `+patched`. Name
  the version in FEEDBACK when a result depends on the compiler. Stock 0.17.0
  only to compare, saying so.
- **Run builds and tests as a user named `steve`, never as root** (Steve,
  2026-10-29). Your container runs as root, and root reads through any
  permission, so a test of a file mode 000 means nothing there. Those
  tests now refuse to run as root, and fail saying so.
  - At the start of a session, as root: create the user, if it isn't there
    (`useradd -m steve`). Give it your checkouts and their caches (`chown -R
    steve`). Install the toolchains where it can run them: patched Zig, and
    the Roc toolchain, either in its own home or on a shared path.
  - **The recipe** (CC, 2026-10-29, the first time it was done; Steve's
    permission, given in the session, let `useradd` past the auto-mode
    check). Steve may put it in the environment's setup script; whatever it
    has done already, the rest is quick:
    - `id steve || useradd -m steve`, then `chown -R steve:steve /home/user`
      and `git config --global --add safe.directory '*'` (root's git, on
      steve's checkouts).
    - The toolchains live in `/root`, which steve can't read: copy them to
      `/opt/toolchains` (`cp -a /root/zig-<ver>+patched.<n>
      /root/roc-<pin> /opt/toolchains/`, `chmod -R a+rX`), and link `zig`
      and `roc` from `/usr/local/bin`. `shale` there already points into
      `/home/user/shale`.
    - Two more things in `/root` steve needs: the proxy's CA bundle (`install
      -m 644 /root/.ccr/ca-bundle.crt /etc/ssl/certs/ccr-ca-bundle.crt`;
      without it a clone fails "Problem with the SSL CA cert"), and Shale's
      mounts (`/home/steve/.config/shale/mounts`: `repos = /home/user` and
      `cookbook = /home/user/shale/cookbook`).
    - A wrapper, `/usr/local/bin/as-steve`, so each run is one word:
      ```sh
      #!/bin/sh
      CA=/etc/ssl/certs/ccr-ca-bundle.crt
      exec runuser -u steve -- env HOME=/home/steve USER=steve \
        PATH=/usr/local/bin:/opt/node22/bin:/usr/bin:/bin \
        GIT_SSL_CAINFO=$CA SSL_CERT_FILE=$CA CURL_CA_BUNDLE=$CA \
        NODE_EXTRA_CA_CERTS=$CA REQUESTS_CA_BUNDLE=$CA "$@"
      ```
      Then `as-steve zig build test`, `as-steve shale tools/verify.shale`.
      The proxy may rotate its CA mid-session: a certificate error as steve
      means copy the bundle again.
  - Run every build and test as it (`as-steve zig build test`),
    with the toolchains first on its PATH. Git, pushing included, stays
    with root.
  - If your session can't create the user, or a step fails, say so in
    FEEDBACK in one line, with the error, and stop. Don't work around it.
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
`serve.zig` is a model: the PCI bus, MSI-X, the APIC, the clock, the virtio
rings, the peer's TCP, the faults. A model is tested on Linux like any code.
`zig build test` runs them all, and none needs KVM.

So treat "this needs a guest" as a smell. When you meet a behavior only the
box's scripts check, ask how to check it here:

- **Drive the device as the driver does.** `virtio.zig`'s `FakeGuest` lays out
  a queue the way zig-metal-unikernel's driver does and drives the mmio window
  through it; `virtio_pci.zig`'s does the same over PCI (config space,
  capabilities, common config, MSI-X).
- **Extract the decision from the I/O.** When a halted guest wakes, and on
  what, is `halt.zig`'s `wakes`: pure, and tested without a vCPU.
- **Read the guest's side.** zig-metal-unikernel's `src/pci.zig`, `src/virtio.zig`
  and `src/interrupts.zig` are what the guest does. They are public
  (github.com/showell/zig-metal-unikernel); clone it read-only. Do not push to it.
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
  anything else that needs zig-metal-unikernel to change: propose it under
  "Proposed" in `QUEUE.md`, and do not build on it until it is answered.
- **`TRANSPORT` unset is the microvm-shaped machine**, and `check.sh` holds
  it to QEMU's microvm. Nothing you change may alter what it does.
- Never weaken a test to make it pass, and never make a check skip silently.
  If a test is wrong, say why in the commit that changes it.
- Comments say what holds and why, in the present tense, in the README's
  voice: no change history in source.

## Git is the channel

- **Push to the branch your session is given** (see "The branches"). Never
  to `master` or `main`, which are the box's, unless a QUEUE item says you
  merge it yourself (310 does, as a trial: Steve, 2026-10-29).
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
| zig-metal-unikernel | `master` | the box | the base: you branch from it, the box merges into it |
| zig-coverage-sdk | `main` | the box | the base: you branch from it, the box merges into it |
| angry-gopher | `master` | the box | the base: you branch from it, the box merges into it |
| zig-webbox | `master` | the box | the base: you branch from it, the box merges into it; zig-metal-unikernel builds gopher.elf from it |
| dog-park | `main` | the box | the base, when an item names it; `check-cc.sh` does not take it from your branch |
| zig-metal-unikernel, angry-gopher | `next`, only during a release's gates | the box | integration while `master` is held for the gates; `master` fast-forwards to it after the tag, and it is deleted. Never branch from it |
| roc-chat, roc-markdown, chat-client, chat-markdown, roc-webbox, roc-apps, shale | `main` (`master` for shale) | the box | the Roc chat's repos (2026-10-29): you branch from the base, the box merges, unless the item says you merge (QUEUE 310's trial) |
| each of them | `claude/<your session's name>` | you | your work, with that repo's base merged in |

**What serves lynrummy.com is a tag, not a branch**: zig-metal-unikernel's `vN`.
Its README's "Where it stands" says how to find which (it names no tag, by
design). `master` may be ahead of it. `interrupts` and `antithesis-sdk` are retired: both are merged
into `master`; don't branch from them.

Use the same `claude/<name>` in every repo. Each QUEUE.md item says which
repo it is in; an item in zig-metal-unikernel is merged there, and its answer comes
here like any other.

## zig-coverage-sdk: the SDK

Since 2026-10-06 you work on github.com/showell/zig-coverage-sdk too: the
properties API (`src/coverage.zig`), its scanner (`tools/scan.zig`) and its
report (`tools/report.py`). Read its README first, "Where this differs from
Antithesis" above all: those differences are decisions, not gaps.

- **zig-metal-unikernel builds against it as a sibling checkout**
  (`.path = "../zig-coverage-sdk"` in its `build.zig.zon`), with no version
  pin. A merge into `main` changes zig-metal-unikernel's build at once. So every
  existing call keeps compiling and meaning what it meant; add, never
  change. Say in the commit what zig-metal-unikernel would see.
- **Follow Antithesis's documented names and JSON** for anything they have
  (their SDK docs and the JSONL they describe), and say where you could not.
  The README's line stays: inspired by Antithesis, not endorsed, not yet
  compatible.
- Its tests are `zig build test` there; `tools/report.py` has its own.

## zig-metal-unikernel: the simulators

You work in zig-metal-unikernel too, on the **simulators and properties**,
and on **production code, such as `src/tcp.zig`, only when a QUEUE.md item
gives it to you** (225 and 226 did): `src/tcp_sim.zig`, `src/fat_sim.zig`, `src/properties.zig`,
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
  the model client went silent after TIME-WAIT, zig-metal-unikernel `02de06f`).
  Read the RFC, not the model, before calling it the code's.
- **A simulator finds; it does not fix the code it drives.** A defect in
  `tcp.zig`, `disk_fat.zig` or any module the kernel runs is a seed kept as a
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
- Do not change the scripts (`check.sh`, `same.sh`, `site.sh`, `pc_vs_microvm.sh`,
  `pair.sh`, `sleeps.sh`, `timeouts.sh`, `lossy.sh`, `refused.sh`, `sound.sh`)
  without saying so in `QUEUE.md`. zig-metal-unikernel's gates run several of
  them on a machine you cannot see (`grep -n 'VMM' tier*.sh long.sh` there
  says which).
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
