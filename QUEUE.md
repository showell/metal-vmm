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

**306. M8: the chat renders with the Roc's markdown; the hosted renderers retire: CC'S** (Steve, 2026-10-29.) **Only after** 305 passes the box's gold check (the box says so in FEEDBACK).

- `render!`, `render_preview!`, `check_hostile!` and `serve_rendered!` retire from the seam.
- The Roc renders, decides hostility itself, answers the 400 itself, and counts it with `count!` (`MalformedMarkdown`).
- The glue check, every frozen run, and the twins hold; a page's bytes don't change.
- The Zig renderer stays in chat-markdown for angry-gopher's own pages (resume_page, safari_download, the Zig chat in production).
- Measure render time on the dev and speed backends against the Zig over the corpora you have, and report it; Steve sets the bound.

The quick gate and check_zig pass; census deltas in FEEDBACK.

**305. The chat's markdown in Roc, a faithful port of chat-markdown's Zig (M1-M7): CC'S** (Steve, 2026-10-29: "I'm highly confident it can do a pretty faithful port of the zig code with possible shallow bugs once we run the final gold check. Have them run all the repo checks pretty frequently.") After 303 and 304, or before them, your order.

**The source:**
- the Zig renderer in showell/chat-markdown (`src/markdown*.zig`, 1,224 code lines, std only), the definition of the dialect;
- its tests;
- angry-gopher's corpora: `zig-server/adversarial.jsonl` and `zig-server/dialect.jsonl` on box/roc-cleanup.

The plan is the box's essay notes/pure-roc-chat-plan.md, section 3; read it.

**Where:** flat `Md*.roc` modules in roc-webbox `chat/`, on `claude/roc-chat`, branched from roc-webbox `main` (the box's auth work is on `box/auth`; leave it alone). SafeImg.roc and Feeds' fence grammar are already twins of parts of it, so fold them under the markdown modules: one home per rule.

**The order (one commit or more each, a ratchet between them):**
- **M1:** the harness, the ratchet, text and escaping, paragraphs and hard wraps, headings, fences.
- **M2:** code spans, MSG_ refs, URL and email autolinks with monotonic cursors, external-link attributes.
- **M3:** `[t](u)` links and the dangerous-URL rule.
- **M4:** emphasis: the delimiter stack, flanking, the rule of 3.
- **M5:** img and video through SafeImg, and the raw HTML block.
- **M6:** lists (tight and loose, nested, the depth cap) and blockquotes.
- **M7:** the budget, exactly: `workUnits` equal number for number, `hostileReason`, trusted rendering.

**The judge you can run:**
- a new angry-gopher `markdown_twin_test.zig` (on box/roc-cleanup through your angry-gopher `claude/roc-chat`) renders every case through twin.roc and through chat-markdown's Zig;
- it requires identical html AND identical work units;
- it reads its corpora from a path list, so the box can add the private gold corpus (10,103 real messages, which never leaves the box);
- **it prints only counts and failing case ids, never message text.**

Your corpora:
- adversarial.jsonl;
- dialect.jsonl;
- every input in chat-markdown's own Zig tests, extracted to a jsonl you commit;
- generated hostile shapes, from the plan's list and cmark's pathological patterns.

A ratchet file holds the pass count, which may only rise. **A differential fuzzer** (random markdown from a grammar of the dialect's tokens, Zig vs Roc) hunts and doesn't gate; commit each difference it finds as a case.

**The traps (plan section 3):**
- per-byte recursion can overflow the stack, and a stack overflow is not a crash sljmp catches: use loops (`while`/`for`/`var` exist at the pin);
- the dev backend may be slower; measure in M7 and report it, don't optimize yet.

**Run the repo checks often** (Steve). After every M item:
- the quick gate (`shale tools/chat_quick_gate.shale` in roc-webbox);
- the Roc hunt (`shale tools/roc_hunt/hunt.shale`);
- the name hunt over the new modules;
- `roc fmt`;
- and angry-gopher's `./ops/check_zig` at least every other item.

Style: the guide as it now stands (roc-apps docs/roc-style.md, revised 2026-10-29). A style decision updates it, as 285's rule says.

**Done when** every case in the corpora you can run passes, html and work units both, the ratchet is at its maximum, and FEEDBACK says the box can run the gold check. The box then runs gold and hands you the failing ids, never the text; you fix them before M8.

**304. Shale's gaps from 2026-10-28: an atomic queue_done, edit between markers, JSON: CC'S** (Steve, 2026-10-29: "queue 1 and 2 for CC".) Three gaps the box and CC hit:

- **queue_done is not atomic.** Twice in one day it ran out of the default step budget (and once the arena budget) after three or so items. Once it removed an item from QUEUE.md without writing its line to QUEUE-ARCHIVE.md. Make one queue_done (and queue_move) a single `edits_all` over both files, so a stop leaves both or neither; and make archiving N items affordable under the default budget (the cost looks quadratic in QUEUE.md's size). Add a test that stops mid-way and finds both files consistent.
- **edit between markers** (CC's own ask from 288-290): a form of `edit` that replaces the text from one marker to another, or from a marker to the end of the file, without the 1-based `sub` and 0-based `find_in` arithmetic. Plants for: both markers present, the end-of-file form, a marker missing (a named failure), and a marker found twice (a named failure).
- **JSON:** Shale has no JSON reader, and the box fell back to `jq` reading Zulip's API answer. Add a reader that turns JSON into Shale's lists and maps, refusing on malformed input with a named error and a position, and with budgets that bound depth and size. Then `cookbook:http.shale` or the docs can use it. A writer too, if it falls out naturally.

Each one: Shale's tests and its doc (SHALE-AGENTS.md's table of builtins). Done when `zig build test` and `zig build consumers` pass.

**303. The Roc style review's checks become cookbook recipes: CC'S** (Steve, 2026-10-29: "queue 1 and 2 for CC".) A Roc Zulip thread on our style guide was reviewed against the chat by read-only box agents, and the clear findings are fixed (roc-webbox and roc-apps, 2026-10-29). Their checker scripts are drafts with no plants: shale branch `box/style-check-drafts`, folder drafts/style-check, whose README says what each one does. The findings and verdicts are in the guide's new rules (roc-apps docs/roc-style.md).

- **For each draft worth keeping, make a cookbook recipe** under cookbook/roc/, or fold it into an existing one (name_hunt's `command_tense` and `vague` are the natural homes for s2 and s4).
- **Each recipe gets plants and a `self_test=1`,** so `zig build test`'s cookbook-test runs it: a plant per finding, and quiet plants for the cases the guide allows on purpose (a single-caller pure function with expects, a rule's one home, a domain word like a directory's entry).
- **boundaries.shale's S7 half needs its filter:** context passed down (`me`, `accounts`, `at`) is not a constant.
- **Run each against roc-webbox `main`.** The fixes have landed, so a recipe's findings there should be zero, or only what the guide allows; say what's left and why.
- **Add the ones that should gate to `tools/roc_hunt/hunt.shale`** in roc-webbox, as findings. nest_depth is likely `min=4`. Each joins the guide's enforcement list.
- **Delete the drafts branch when done.** Your call which drafts aren't worth a recipe (s11_pure_names is a reading aid): say why.

Done when the kept checks are recipes with plants, cookbook-test runs them, the hunt carries the gating ones, and the guide's enforcement list names them.

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
