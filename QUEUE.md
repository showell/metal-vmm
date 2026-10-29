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

**310. roc-markdown: finish moving the judge in, and prove it with one command: CC'S** (Steve, 2026-10-29: "give it to CC".) **showell/roc-markdown only.**

**A trial of a new way of finishing** (Steve: "we need to refine our CC process so that we're not constantly worrying about final cold checks"; this item only for now, maybe CLOUD_WORK later):
- **Your proof is a committed script, not a report.** Write `tools/verify.shale` (Shale; `shale --help` and docs/SHALE-AGENTS.md in the shale repo). In one run it does every check below and prints a fixed checklist: each line is `PASS` or `FAIL` with its numbers. Its last line is `verify: N of N passed` or `verify: FAILED`, and its exit code matches.
- **The planted faults are in the script too.** For each plant, it changes a scratch copy, runs the judge, requires red, and never touches the tree.
- **You merge it yourself.** When `shale tools/verify.shale` passes on `box/judge-wip`, merge that branch to `main`, push, and delete `box/judge-wip`. Then paste the script's whole output into FEEDBACK.
- **The box's whole check is rerunning that one command,** which also runs gold, the one thing you can't. If it fails here, the box says so in FEEDBACK with its output.

**Why:** the markdown judge, which holds every case to frozen answers, is moving out of angry-gopher (frozen as reference: Steve, "the training wheels are off") and into roc-markdown, with no Zig markdown left in it. A box agent got halfway and stopped, and its work is pushed on `box/judge-wip`. Start from there; its two commits say what they are.
- **Done:** `judge/data/` is copied byte for byte from angry-gopher `c67657e4` (`zig-server/` and `zig-server/markdown_twin/`).
  - `judge/judge.zig` is the old judge, ported from angry-gopher `zig-server/src/markdown_twin_test.zig`, without `--zig`, `zigAnswers`, `judgeZig*`, `fuzz`, the Zig half of `--time`, or the `roc_crashed` verdict. A Roc crash now stops the judge.
  - The judge finds its data through a build-option module, `judge_paths.data`.
  - Also there: `judge/roc_host.zig`, `judge/answers.roc` (the five answers, importing `../package/main.roc`) and `judge/platform/main.roc`.
  - None of the Zig has been compiled.
- **Left:**
  1. **Build files.** `build.zig`, modeled on roc-chat's (github.com/showell/roc-chat):
     - the `rocCompiler` pin check;
     - `roc build judge/answers.roc --target=x64musl --opt=dev`, with every `.roc` in `judge/` and `package/` as inputs. Use `--opt=dev`: `roc build` defaults to LLVM, which took 5 minutes against 0.9 s;
     - the `judge_paths` options module, pointing at `b.pathFromRoot("judge/data")`;
     - a `judge` step with passthrough args;
     - a `test` step running `roc test package/main.roc` and then the judge.

     Also add `build.zig.zon` with `minimum_zig_version = "0.17.0"`, and `roc-version` containing `nightly-2026-10-09-258ab27`.
  2. **Compile and debug.** The one known risk is whether the pinned Roc passes `List(U8)` by value as `roc_host.zig` assumes. If it doesn't, use roc-webbox's twin shape, `{which, args}`, which is proven (github.com/showell/roc-webbox, `chat/twin/platform/` and `src/twin_abi.zig`).
  3. **Renames, in one commit after the copy:**
     - `zig_tests` becomes `unit_cases`; record its origin, chat-markdown's Zig unit tests, once in the README;
     - `corpora.txt`'s paths become bare names, and fix its header;
     - fix `spec_diverge.txt`'s header, which names the old file;
     - fix `package/Md.roc` lines 11-13, which name angry-gopher's judge, and any other package module that does the same.
  4. **README:** rewrite the "Its judge" section, give the two commands (`zig build test`, and `zig build judge -- --also <gold>`), and drop "No LICENSE yet".

**What `tools/verify.shale` checks:**
- `zig build test` passes, and the judge's case counts per corpus are exactly: adversarial 29, dialect 3, unit_cases 69, spec_agree 269, pinned 3, hostile 983, for 1,356 in all. A different number is a FAIL, never a pass.
- **Three planted faults, each red:** one byte changed in a frozen answer, one wrong hostile hash, and a spec_diverge id listed that now matches.
- `zig fmt --check` and `roc fmt --check` are clean.
- roc-chat's `roc test` still passes against this roc-markdown. Clone roc-chat beside it; it imports `../../roc-markdown/package/main.roc`.
- **Gold:** if `~/showell_repos/gopher-gold/gold.jsonl` exists, run `zig build judge -- --also` on it, require 10,103 agreeing, and print only counts. **NEVER PRINT GOLD MESSAGE TEXT.** If it's absent, which it is for you, print `SKIP gold: not on this machine`. That SKIP is the only one allowed, and only for gold.
- The judge's time, with and without gold, printed as a number.

**Roc toolchain:** use showell/roc-apps release `toolchain-2026-10-27`, which carries the same nightly.

**309. roc-chat: a Roc crash is a 500, proven by planted crashes: CC'S** (Steve, 2026-10-29: "Give the test hunt to CC.") **showell/roc-chat only**, branch `claude/roc-chat`; the box merges it.

**Why:** roc-chat (github.com/showell/roc-chat, `main`) is the new, standalone Roc chat. Its host (`host/`, Zig on std.http) catches a crash in the Roc app and answers 500, but nothing tests that: the path was written, never run.

- **Plant crashes in a test-only Roc app,** beside the real one (roc-webbox's `chat/test/crash.roc` at `5a4314b` is the model). Plant one crash per way the Roc can die: `crash` in a handler, an out-of-bounds `List.get` unwrapped by `crash`, integer overflow, and a crash inside a hosted function's continuation if the seam has one. If a way to die isn't reachable at the pin, say so.
- **For each crash, prove:**
  - the client gets a 500 with the host's fixed body, and no Roc state or stack text leaks into it;
  - the server keeps serving: the next request on a new connection succeeds;
  - the turn is released, so a waiting client is answered (the server tests have a turn harness);
  - the crash is logged once, with enough to find it.
- **Hunt past the plants:** a crash during a body read, during a header read, and after the answer has started (if the Roc can crash after headers are sent, what does the client see?). Each finding is a red test, then a fix.
- **Roc toolchain:** roc-chat pins `nightly-2026-10-09-258ab27` (`roc-version`). `tools/get_roc.sh` fetches from roc-lang's GitHub, which your sandbox can't reach. Use showell/roc-apps release `toolchain-2026-10-27` instead, which has the same nightly.
- **roc-chat builds against a sibling `../roc-markdown`** (github.com/showell/roc-markdown), so clone it beside roc-chat.

Done when `zig build test` passes with every plant held, a planted removal of the crash guard turns them red (say so in FEEDBACK), and `zig fmt --check host build.zig` is clean.

**308. chat-client: the client's contract with the server, written and tested: CC'S** (Steve, 2026-10-29.) **showell/chat-client only** (the browser client, served by both chats).

**Why:** the client relies on things nothing writes down: URLs, SSE frames, JSON payloads, the inline sidebar data, `data-*` attributes on `#chat-root`, and the rendered markdown's classes. On 2026-10-28 a server renamed the sidebar JSON's `sessions` key to `topics` and nothing failed: the unpinned topics showed "No sessions yet" in production until the client was fixed (chat-client `bdc12b50`).

- **Write the contract** as a document in the repo, CONTRACT.md: every request the client makes (method, URL, body), every response shape it reads (JSON fields with types, required vs optional), every SSE event type and its frame, every inline `<script type="application/json">` payload, the `data-*` attributes, and the CSS classes it expects in rendered markdown. Derive it from the JS itself, file by file; cite the file:line that reads each field.
- **Make it checkable:** a machine-readable form (JSON) of the payload shapes, and tests in the repo (node, as `tools/test_chat_resize.mjs` is) that load each JS module's readers against fixtures matching the contract, so a renamed key fails. Mark which fields are read but never sent by today's servers, if any.
- **No server changes.** A server checks itself against CONTRACT.md later; say in the README how.

Done when CONTRACT.md covers every reader, the tests run from one command (listed in the README), and they catch a planted rename of `topics`.

**307. Shale: the kept and machine budgets configurable; the doc check's `./ops/` quirk: CC'S** (Steve, 2026-10-29: "queue 1 and 2 for CC".) Shale repo only.

- **Two budgets nobody can raise:**
  - the kept budget at `yield` (1 MiB);
  - the machine budget (16 MiB, `budget machine`).

  Neither can be set from `--budget` or a script's `-- budget:` header line, as every other budget can. Both stopped real scripts: cookbook:roc/name_hunt.shale's main loop had to drop its `yield`, and a box agent's per-line inventory over a 745-line file stopped at `budget machine` after about 560k steps, avoided only by rewriting it with `re_lines`.
  - Make both settable the same way, with sane ceilings, and say in each one's stop message how to raise it.
  - Tests, including a script that needs more than the default and passes once its header asks.
  - Also find out why that per-line loop (a helper called about 25 times per line) used 16 MiB of machine: is something retained per call that shouldn't be?
- **The doc check reads `` `./ops/check_zig` `` as `ops/check_zi`:** a leading `./` loses the path's last character. Fix it with a plant in the doc check's self-test.

Done when `zig build test` and `zig build consumers` pass and SHALE-AGENTS.md's budget table names both.

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
