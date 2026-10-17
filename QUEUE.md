# QUEUE

The one queue for metal-vmm, zig-metal-unikernel, zig-coverage-sdk,
angry-gopher, zig-webbox and dog-park: what is open, and who has it.
**Finished, retired and answered items are in
[`QUEUE-ARCHIVE.md`](QUEUE-ARCHIVE.md)**, one line each by number with the
commits they name; their full text is `git show 3697b1c:QUEUE.md` and `git show
3697b1c:QUEUE-ARCHIVE.md`. New items continue from 234. The conversation between
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
- **Built, not deployed (Steve's):** a Dog Park release with `/version`, and
  the Observatory's droplet (228); the Safari downloads on metal and /tutorial's
  removal ride the next lynrummy.com release.
- **CC:** 233, in order.

## CC: open

**Your role (Steve, 2026-10-08): build what needs no emulator, and anything
adversarial.** Every item here runs on the host: `zig build test
-Dtest-file=<file>` runs one zig-metal-unikernel test file in seconds (the whole step
takes minutes); metal-vmm's `zig build test` and its `sweep_test.sh` need no
guest. Where a claim needs a real boot, write the recipe under Questions for
the box instead of guessing. Findings arrive as red tests where they can.

**233. Shale, dogfooded: the seam, `run`, the Linux prelude, git, jobs, the hook, the queue tool, the docs: CC'S, in order, after 232** (Steve, 2026-10-17: "go, queue it for CC", after six design rounds). **The spec is zig-webbox `docs/designs/DESIGN-shale-dogfood.md` (final, `56c8a8f` and after); the essay is https://github.com/showell/essay-repl-server/blob/master/notes/shale-dogfood.md.** Where this item and the design differ, the design wins; say so in FEEDBACK. Who writes Shale: a well-meaning agent who makes mistakes, so every slip ends in a clear stop, never a wrong answer, a panic or damage; no defences against hostile scripts. Metal stays as it is behind the seam: `script.report` frozen, `pathArg` byte-identical with no hook, `store.zig` unchanged, the whole gopher.elf image measured before and after each chunk. Linux only, no KVM needed. Chunk 0 is done (the box, 2026-10-17; the design's "Running a program"): **a Bash call past its timeout is backgrounded, not killed**, so `run`'s `timeout_ms` is what ends a program; **a task's stop is TERM then KILL to the whole process tree**, a child in its own session included, so `job_start`'s reaper must double-fork out of every task's tree; curl is 8.5.0.
1. **The seam and `run`** (the design's "The architecture", "Mounts", "Running a program", "The dry run", "The CLI's defaults"): `host(name, ...)` and `Options.host`; `Options.path_hook`; the prelude list in `Options` (the indexer as one function, comptime for core, runtime for the rest; no shadowing); the raw spawn and poll loop (`src/shale_spawn.zig`), the pure keep (`src/shale_keep.zig`, against the `take`/`last` oracle), the filters (`re`, `not_re`, `nocase`, `before`, `after`), `whole`, `log`, `env`, `secrets` and their scrubbing, the refusals (by basename, versions dropped, wrappers, an untracked program by path), `want`; mounts and `real` behind the hook, the mounts file and `SHALE_MOUNTS`; the dry run's uncatchable stop and the host's cap on programs; `now()` the wall clock; terse output in `script_runner.zig`; the script from stdin. Red first against the fixture program the build makes, never `/bin/sh`.
2. **The Linux prelude:** the wrappers (`run`, `real`, `job_*`), `re_lines`, `head_lines`, `tail_lines`, `unique`, `grep_all`, `newest`, `glob`'s `hidden`, `must`, `create`, `edits_all`; the repo prelude (`.shale/prelude.shale`) and the user prelude, and their pins (`SHALE_PRELUDE`).
3. **The git prelude** (the design's "Git"): `repo` a Shale path, `""` the root; reading calls give data, changing calls are `must`ed; red first on a temporary repo made with `git init`. Claude's `commit` (refusing a message without `Co-Authored-By:`) is a user-prelude example in SHALE-AGENTS.md, not in the git layer.
4. **Jobs:** `job_start` with its reaper (a detached `shale` in the same binary writing `<log>.job`), `job_alive`, `job_stop`, `job_wait`, found again by the `.job` path from a second `shale`; no `secrets` on jobs.
5. **`shale-gate`** (zig-webbox `tools/`, a pure classifier, tested on the design's grammar and its failure modes: a missing binary refuses, a heredoc TAG met twice refuses). **Local cold agents are exempt** (Steve, 2026-10-17): first find whether PreToolUse's input tells a subagent's call from the top-level one's (an agent id, a transcript path; say what you found in FEEDBACK), and pass a subagent's call if it does; **if it cannot tell, hold subagents too** (Steve, 2026-10-17: "If it's not easy to exempt the subs, then we can just have subs do shale as well"): no elaborate detection. **Do not install the hook**: Steve installs it when this item is done.
6. **The queue tool** (the design's "The queue, in Shale"): metal-vmm's `.shale/prelude.shale` (`queue_check`, `queue_next`, `queue_add`, `queue_done`, `queue_archive`, `queue_reorder`, `feedback_add`, `feedback_archive`), QUEUE.md's grammar written in metal-vmm's README, and its Shale tests on fixtures in `tests/queue/` including today's real misorder (232 … 227, 223, 224, 225, 226, 222). Then **propose** the live reorder and an archive of done items in FEEDBACK, with the diff; the box applies it.
7. **The docs:** SHALE.md and SHALE-AGENTS.md rewritten for what was built (the seam, mounts, `run`, jobs, git, the queue tool, the CLI's defaults, "where Shale is worse" now); and the docs audit's findings in FEEDBACK, "the docs audit's Shale findings", 2026-10-17).
**Report** in FEEDBACK after each chunk: its commits, its tests (red first), the image's size, and anything the design left you to guess.

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
  sector, the last TCP properties on the real kernel, request_heap's figure,
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
- **`fat16_test.zig`'s limits are not in `properties`** (no 8.3 alias left,
  a directory at FAT's most entries, too deep to check or remove), so four
  named properties show MISS there. Calling those tests' setups from a
  `properties` tier, or a `floor_sim` drive of each, would put them on the
  floor. Each costs a full directory or a deep tree: minutes of runtime.
- **The `writeRuns` re-checks** (a chain that ends before its size, past
  `chainEnd`'s walk) wait on a disk that lies between two reads; a
  `floor_sim` case with `Block.Fault.garbage` at the right request number
  could reach them, but finding that number by search is fiddly.
