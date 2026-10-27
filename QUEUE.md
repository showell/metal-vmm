# QUEUE

The one queue for metal-vmm, zig-metal-unikernel, zig-coverage-sdk,
angry-gopher, zig-webbox, shale and dog-park: what is open, and who has it.
**Finished, retired and answered items are in
[`QUEUE-ARCHIVE.md`](QUEUE-ARCHIVE.md)**, one line each by number with the
commits they name; their full text is `git show 3697b1c:QUEUE.md` and `git show
3697b1c:QUEUE-ARCHIVE.md`. New items take `queue_next()`'s number. The conversation between
the two Claudes is [`FEEDBACK.md`](FEEDBACK.md) (older entries:
[`FEEDBACK-ARCHIVE.md`](FEEDBACK-ARCHIVE.md)); the cloud session's charter is
[`CLOUD_WORK.md`](CLOUD_WORK.md).

## Context

metal-vmm runs zig-metal-unikernel's real kernel deterministically (both machines:
microvm-shaped and `TRANSPORT=pci`); the scenarios that cover what the site
meets go here, not to QEMU, which stays on the happy path (Steve). The goal
is zero bugs in the lower levels; class hunts find more than seeds; the
judge is becoming "did anything forbidden happen?", checked by `plants.sh`.
The snapshot (`docs/SNAPSHOT.md`) is parked.

## Now

- **What serves lynrummy.com:** zig-metal-unikernel's newest tag
  (`git -C ../zig-metal-unikernel tag -l 'v*' --sort=-v:refname | head -1`);
  its message names the commits. Dog Park serves dogpark.lynrummy.com.
- **Built, not deployed (Steve's):** the Observatory's droplet (228). Dog
  Park's release with `/version` serves (its `/version` names the commit).
- **CC:** Shale's work is the box's (Steve, 2026-10-22), but for 244. The
  box builds with a patched Zig 0.17.0 (FEEDBACK, 2026-10-26).

## CC: open

**Your role (Steve, 2026-10-08): build what needs no emulator, and anything
adversarial.** Every item here runs on the host: `zig build test
-Dtest-file=<file>` runs one zig-metal-unikernel test file in seconds (the whole step
takes minutes); metal-vmm's `zig build test` and its `sweep_test.sh` need no
guest. Where a claim needs a real boot, write the recipe under Questions for
the box instead of guessing. Findings arrive as red tests where they can.

**255. job_wait: one last look on a done record; the flaky large-log test names its case: CC'S** (CC's own finding, in FEEDBACK 2026-10-27, approved). `shale_jobs_test.zig:148`, the large-log `job_wait(..., {contains = "log 300000"})`, answered `exited` once on GitHub (run 40554443677).

**The change**, exactly CC's two small steps:
1. The test prints `code` and `signal` beside `ended`, so the next red names its case.
2. On a done record, `job_wait` looks at the log once more before answering `exited`. The log is whole by then, so `found` wins whenever the file holds the text.

Give it 15 minutes; don't chase the root cause further unless the next red names it.

**254. FEEDBACK/QUEUE merges by Shale: no resurrected entries, no glued headings: CC'S** (Steve, 2026-10-27: "we should use shale for merges and auto-detect conflicts. Our mechanism to update FEEDBACK should try to avoid common pitfalls too."). Do this before 253.

**The pitfall, seen today:** your merge of master into `claude/great-wright-i7aste` (5b5d98d) resolved FEEDBACK.md by hand. Two things went wrong:
- entries the box had archived on master came back (your "procs review" and "QUEUE 250 finished" entries, among others);
- one heading lost its blank line, so it is glued to the entry above.

`git_merge` already undoes a conflicted merge and names the files. What's missing is resolving FEEDBACK and QUEUE themselves.

**The change** (metal-vmm `.shale/prelude.shale`, beside `feedback_add`/`feedback_archive`):
- **`feedback_merge`:** resolves a FEEDBACK.md conflict from its two sides:
  - entries are taken as a union, matched by heading;
  - newest first, with a stable order within a day;
  - an entry whose heading is in FEEDBACK-ARCHIVE.md stays archived;
  - an entry changed on both sides stops the merge and names it.
- **`feedback_check`:** refuses an out-of-order date, a heading without a blank line before it, a heading that appears twice, and an entry that is also in the archive. Run it from `queue_check`, so the existing tests cover it.
- **The same for QUEUE.md if it fits cheaply:** an item number on both sides with different text stops; an archived number never returns.
- **One command for the whole merge:** git_merge, then on a FEEDBACK/QUEUE conflict, resolve with the above, commit, and stop on anything else. For example `shale .shale/merge_master.shale`.

**Deliverable:**
- red tests in `queue_test.shale` (a resurrected entry, a glued heading, a both-sides edit);
- your branch's FEEDBACK repaired with the new tool;
- CLOUD_WORK.md's "Shale first" naming the command.

Wall time: about 30 minutes. Cut QUEUE's half if it runs long, and say so.

**253. Shale's `re_find`: several capture groups: CC'S** (CC, in FEEDBACK 2026-10-27: "Shale's `re_find` allows one capture group. That cost me a workaround twice today."). After 251.

**The change:** `re_find` returns every group, still in linear time. Keep the one-group form working: say how it reads, and don't break a caller. Mirror it in `re_replace` (`\2`, ...) if it doesn't already take several.

**Deliverable:**
- Tests with two and three groups, an optional group that doesn't take part, and nested groups.
- The two workarounds from today rewritten to use it.
- SHALE.md and SHALE-AGENTS.md updated.
- A green on-demand GitHub run.

**252. Shale's own gates: every slow step load-bearing, and run after the cheap ones: CC'S** (Steve, 2026-10-27: "make sure that anything that's time-consuming in shale's own gates is load-bearing and sequenced after more inexpensive checks"). After the open review items.

**Today:** `zig build test` is about 95 s on the box, and about 190 s on GitHub's runner. Steps run in parallel, so a format slip or a one-line compile error can wait behind the fuzzers before it's reported.

**Measure (1):** `zig build test --summary all` gives each step's time. Find what the 95 s is: the script fuzzer (`-Dscript-fuzz`, 400 by default), the props tests, the cookbook tests, `web-test` (Node and the wasm build), the gate test, the doc check if it's in there. List each step with its time, cold and warm.

**Load-bearing (2):** every step over about 5 s must catch something nothing cheaper catches. For each, either:
- name a defect it alone has caught (a commit, or a QUEUE item), or
- plant one it alone catches, then remove the plant.

A step that can't show either is trimmed (fewer iterations, a smaller corpus) or moved to a slower tier. Say which, and why. Never loosen a check as a blanket.

**Sequenced (3):** the cheap checks run first, and an expensive step starts only after they pass: `zig fmt --check`, compile errors, then the fast unit tests, then the rest. In `build.zig`, make the expensive steps `dependOn` a cheap gate step. A slip should be reported within seconds, not after the fuzzers.

**Tiers, if they help (4):** `zig build test` stays the one full gate. A `zig build quick` (fmt, compile, unit tests) may be added if it is honestly under about 15 s. Say what it leaves out.

**Deliverable:** the timing table, before and after, on the box and on GitHub (via `cookbook/gh_build.shale`); the load-bearing evidence per step; and the sequencing. Report how long a format slip now takes to fail.

**251. The Shale tutorial's lessons: pin each cell's output: CC'S** (Steve, 2026-10-27, on the live tutorial at lynrummy.com/shale/tutorial.html: "Is our Shale tutorial self-maintaining?"). After your current item.

**Today:** `web/smoke_test.mjs` (in `zig build test`, through `web-test`) runs every lesson cell in `web/lessons.js` in order, on one tree, and checks only that each one **finishes or stops on purpose**, plus the blog the lessons build and `card.svg`. **What a cell prints isn't checked.** So a lesson whose prose quotes an error or an output drifts silently when the wording changes. Today's name-not-found error gained a `shale --help` pointer, for one.

**The change:**
- Each cell in `lessons.js` carries its expected output (and, for a cell that stops, the stop's line).
- The smoke test compares them exactly.
- Where a value really varies (a time, a size), the cell says so explicitly, with a marker the test understands. Never loosen the comparison as a blanket.
- **A way to refresh the pins on purpose,** for when the output really changes: a `node web/smoke_test.mjs --rewrite` mode, or a small script, that writes the new outputs into `lessons.js` for a human to review in the diff. The test itself never rewrites.
- Then read each lesson's **prose** against its now-pinned output, and fix any sentence that describes output the cell no longer prints. List them in FEEDBACK.

**Deliverable:**
- The pins, the comparison, the rewrite mode, and the prose fixes.
- A plant showing a changed output fails the test: change one cell's expected text, see red, revert.
- A green on-demand GitHub run (`cookbook/gh_build.shale`); paste its URL in FEEDBACK.

Shale is the box's otherwise; this item is Steve's ask.

## Parked

- **216's output ring and SSE stream** (Steve, 2026-10-16): revisit when a script needs to report as it runs; today `GET /admin/script` shows output after the run.
- **212, Dog Park's grid from 210's lessons** (the box, 2026-10-15, while Steve reshaped the world to 6 x 6 tiles): revisit to re-scope once the reshaped world is settled.
- **84, 85, 86: N5's FAT refusals, N3's `readAt`, the seam under `stream.zig`** (Steve, 2026-10-07: the adversary role comes first): revisit if the store's seventh call or the stream seam is wanted.
- **The whole-machine snapshot** (`docs/SNAPSHOT.md`, Steve): revisit when steering the real kernel by snapshot is wanted.

## The box: open

- **After a week of lynrummy.com's access log** (221): run the kernel's `droplet/replay.py` (QUEUE 48) over it once, as a corpus of real, hostile traffic.
- **B32 (2026-10-10, Steve; after v22): weigh a compile-time off switch for the coverage SDK**, as Antithesis's SDKs have one (Go's `no_antithesis_sdk` tag, C++'s `NO_ANTITHESIS_SDK`, Rust without `full`). Today the served kernel records every property on every call, and nothing there reads the counters. A plain property costs a few instructions and a store; a numeric comparison also works out its edge and reach on every call. Measure that first, with one hot-loop benchmark with the SDK on and off. **Against it:** the kernel the gates judge would not be the one served; `/admin/host` could someday show the properties broken in production; a condition with side effects still runs. Steve leans toward mostly what Antithesis does, with those concerns weighed.
- **B31 (2026-10-09, Steve's open question): a `gates.sh` line that fails when `zig build test` exceeds a time budget**, so the suite's cost can't creep back up (530 s at v21; 194 s after 136; 3m19s on the box tonight). Wait for 142's number, then decide the budget with Steve.
- **B29 (2026-10-09, found moving the slow-reader gate): stray resets after a reader that paused.** A client that shuts its window for 2.5 s mid-page (`PEER_SHUT_AFTER=4096 PEER_SHUT_FOR_US=2500000`, the 231 KB `requests/big-page.http`) gets the whole page, but the guest's tcp line then counts 8 strays reset (none unhurt), with 4 timeouts resent. Something reaches the guest for a connection it no longer holds: either the peer keeps talking after it is done, or the guest forgets a connection the peer is still owed (TIME-WAIT's ACK, say). Find which, from a frame trace; a peer fault is fixed here, a guest one becomes a red test in gopher-metal.
- **The explorer against blind runs, properly** (with Steve, a design
  session): the full bench (`zig build explore` at its defaults: 20 explorer
  seeds, counted against what blind runs reach at 300; CC's item 98,
  merged). A smoke run at budget 5 left about 4.5 of 40 counted properties
  unreached by blind runs and about 20 by either explorer: at small budgets
  the explorer branches from one or two early runs and sees far fewer
  scenarios. Quote no number before the full run. Also: the bench step shows
  "failed" under `zig build` because its test writes to stderr (CC: make it an
  executable, not a test).
- **B17.** A coverage property per refusal in the guest's parsers.
- **B18.** Lies in the peer's DHCP replies.
- **B19.** B14's power cut as a `long.sh` scenario; H5 and H2 against
  gopher.elf.
- **102 (from CC's list: it needs KVM).** The rough peers must reach their
  four TCP properties by design on both kernels, then back on
  `floor-metal.txt` (full text: `git show 3697b1c:QUEUE-ARCHIVE.md`).
- **N4.** The cloud session's device knobs (item 82), run on gopher.elf and
  put on `floor-metal.txt`.
- **B2, B3, B4, B6–B10, B12** (older: a seed sweep of gopher.elf, the bad
  sector, the last TCP properties on the real kernel,
  the fat16 seam, the deadline mark, the snapshot's box half, microvm,
  revival on the real kernel).
- **HOST.md's owed list:** the Bus contract and its simulator (the locks
  are gone and Linux durability is in, 2026-10-13).

## Proposed

*(The cloud session adds items here, one line each on why. Taken or retired proposals are in the archive.)*

- **The console door for every log line** (the box, 2026-10-16, from QUEUE 225's design): in metal-vmm runs, about 78% of exits are serial-port output (5,824 of 7,480 for one boot plus GET, about 580 ms of 748 ms virtual). Route every log line through the existing 0xE2 door (`main.zig:84-95`, `:707-721`), counted as progress for `quiet`/`rested` and feeding `said`; serial stays QEMU's fallback. It shifts every recorded exit count and `FAULT_SEED` schedule, so it lands at a release boundary with a re-baseline. It would speed every metal-vmm gate, the long tier's lossy sweep included.

- **P193(a). The SCSI event queue gets buffers** (zig-metal-unikernel
  `scsi.zig` ~350, the box's: a driver change). It is set up with none, so
  a transport reset or a hot-unplug event the device sends is lost, and a
  volume detached or re-attached under the machine is seen only when a
  command meets a unit attention. Two or four event buffers offered at
  bring-up, read in idle time and counted by kind
  (`disk_failures.Failures`, beside 193's unit attentions), would say it.
- **P193(b). gm_irq counts what it takes** (`interrupts.zig`'s stub, the
  box's: asm). 193's `rests` counts the wakes a device caused; a storm that
  arrives while the processor is not resting (it takes interrupts only in
  `rest`, so none today) would need the stub to count. Only if interrupts
  are ever taken outside `rest`.

## Questions

*(Either side, with a reproduction where there is one.)*

## Answers

*(The box's, newest first.)*

## The debt ledger

*(One line per shortcut, from item 76 on: what, where, what fixing it would
take. The box reads it at merge time.)*

- **floor_sim is several small drives in one file** (gopher-metal
  `src/floor_sim.zig`: GPT, page cache, redactor, damaged FAT). Fine at four;
  past six or so, split by module. An hour.
- **Two fat16 refusals need a directory this driver did not write** (a long
  name of 21 parts; a tree whose entries return after removal). A damage
  case that writes raw directory entries into `floor_sim`'s volume would
  reach them. Two hours, mostly getting the long-name checksum right.
- **`disk_fat_test.zig`'s limits are not in `properties`** (once fat16_test.zig) (no 8.3 alias left,
  a directory at FAT's most entries, too deep to check or remove), so four
  named properties show MISS there. Calling those tests' setups from a
  `properties` tier, or a `floor_sim` drive of each, would put them on the
  floor. Each costs a full directory or a deep tree: minutes of runtime.
- **The `writeRuns` re-checks** (a chain that ends before its size, past
  `chainEnd`'s walk) wait on a disk that lies between two reads; a
  `floor_sim` case with `Block.Fault.garbage` at the right request number
  could reach them, but finding that number by search is fiddly.
