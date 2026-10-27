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

**250. Opaque types for validated values, beyond the Roc chat: CC'S** (Steve, 2026-10-27: "have CC look for more places to introduce the opaque type pattern for validation"). After 249.

**The pattern (the box found it in the Roc chat today):** a value checked once is passed on as a type that only its check can construct, so an unchecked value fails to compile, not merely fails a review.
- **Roc:** an opaque type, `ChatPath :: List(U8)` (`::`, not `:=`): outside its module, `ChatPath.(x)` is a compile error, so only the module's validated builders make one. The nominal syntax at the pin (nightly 2026-10-09): declare `X := T.{ ... }` or `X :: T`; wrap `X.(v)`; unwrap the pattern `|X.(v)| v`; `==` needs an `is_eq` on the type.
- **Zig:** a distinct type whose one constructor is the validator. Either `enum(u32) { _ }` with `fromInt`/`toInt`, or a struct whose field the rest of the code never sets: a convention, so say how it's enforced, perhaps by a test that greps for the field outside its file.

**Why it matters:** the box's tests showed the chat's path builders refuse nothing. `channel_path("../x")` makes `channels/../x.channel`, which stays inside the root, so the host's root check doesn't see it. Only upstream validation stands between them, and it holds only while every caller remembers it.

**Hunt, in repos you can see** (the Roc chat is on the box's local branch: not yours):
- **dog-park's Roc:** kinds, ids, world coordinates;
- **roc-webbox's TODO app** on master (its ids are parsed digits-only by hand; QUEUE's P1);
- **angry-gopher's Zig outside chat_*:** uids, API keys, session and cookie values, upload and doc names, game ids;
- **zig-webbox:** request paths, header values, mount names;
- **shale:** a script's path after `pathArg`, mount names, `want` tags.

Look for a value that one function validates and returns as the plain type it came in as, then several functions take and trust. A `valid_x`/`isValid`/`parseX` returning a Bool, or a cleaned string, is the tell.

**Deliverable:**
1. **A ranked list in FEEDBACK:** each candidate, where it is checked, how many places trust it, and what a forgotten check would do.
2. **Then do the top three:** each in its own commit, with a red test or a plant showing the unchecked value now fails to compile (a compile-fail case where the language allows one; otherwise a test that grep-checks the convention).
3. Keep each conversion small: the type, its one constructor, and the callers it forces to change.

**Stop and ask** if one would reach a public API or the Roc/Zig seam.

**249. One syntax check for every file kind, so no habit reaches for python3: CC'S** (Steve, 2026-10-27, on your 248 note that you checked Python syntax with `python3` out of habit: "err toward improving shale (have CC do it) unless it's truly a one-off"). The habit is real and general: after an edit, did this file's syntax survive? Today each language has its own command, and a habit reaches for whichever is nearest.

**`cookbook/syntax.shale files=a,b,...` (or `rev=<range>`: the files a commit range touched):** one verdict a file, by kind:
- `.zig`: `zig ast-check` (and `zig fmt --check`, said apart);
- `.zon`: `zig fmt --check`;
- `.roc`: `roc check` (an app or a module: say how a module is checked);
- `.js`/`.mjs`: `node --check`;
- `.shale`: Shale's own parse, with no run (read the CLI for one; if none exists, a `--check` that parses and stops is in scope);
- `.py`: `python3 -m py_compile`, passed through `run`'s `want` with the tag the recipe names, so the use is logged as the tool exception it is, never chosen by hand;
- `.sh`: `bash -n`, the same way;
- `.md`: nothing, said once.

One line a file (`ok`, or the first error), then PASS or FAIL. Refuse a dash-led value (`not_option`). Keep it fast: one program a file, and run the files of one kind together where the tool takes many.

**Then point the habit at it:** a line in SHALE-AGENTS.md's "Before you reach for the shell" table (`python3 -m py_compile f`, `node --check f`, `zig ast-check f` → `shale cookbook:syntax.shale files=f`), and in CLOUD_WORK.md if your environment notes say how you check an edit.

**Deliverable:** the recipe, with a test in the cookbook test file the others use, showing a good file and a broken one of each kind the box has tools for. In FEEDBACK, say how long a mixed set of 10 files takes.

**248. Code comments that cite the docs your sweep deleted: CC'S** (Steve, 2026-10-27: "queue the doc citation fixes for CC"). Your doc sweep (FEEDBACK, "the doc sweep, at Steve's ask") deleted docs that code comments still cite. Fix the citations, **comments only, no code**: each one either says the fact in place, briefly and in the present tense, or names where the fact lives now (a doc that exists, or the code). A comment that only pointed at history goes.

**In scope** (your own list):
- **zig-metal-unikernel:** probe/config.zig (picture-cache), probe/judge_gopher.py (signed-uid, admin-host, and FAT32's "Then the chat judge"), probe/test_judges.py (admin-host), droplet/replay.py, check_backup.py and backup.sh (admin-backup), src/log_ring.zig (secrets), src/net.zig and probe/gopher.zig (item90-step2).
- **angry-gopher:**
  - storage.zig (game-store)
  - uid_cookie.zig (signed-uid, request-paths)
  - login_throttle.zig (login-throttle)
  - admin_backup.zig and router_admin_test.zig (admin-backup)
  - users_session.zig, login.zig, admin.zig, chat_paths.zig (request-paths)
- **dog-park:** "decision N" in physics.zig, walk_reference.zig and physics_server_test.zig. State each rule where it applies.
- **essay-repl-server:** notes/cutover-decisions.md and notes/shale-dogfood.md, if they cite deleted files. Leave the tests/queue/misorder fixture as it is.

**Out of scope: the box's.** roc-webbox (roc_abi.zig, chat_abi.zig, sljmp.zig, chat_route.zig) and angry-gopher's chat_router.zig. The box's local `box/roc-cleanup` branch is rewriting those files, and will take their citations in its own pass.

**Also look for others:** run `zig build doc-check -- only=<repo>` (zig-webbox) on each repo. Then `git grep` each deleted doc's name (`git log --diff-filter=D --name-only` over your sweep's commits lists them) to catch citations your list missed.

**Deliverable:**
- one commit per repo, on your branch;
- each repo's doc check passes;
- each repo's own `zig fmt --check` passes where you touched Zig;
- in FEEDBACK: what you changed, and any citation you couldn't resolve, saying why.

Nothing here needs KVM.

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
