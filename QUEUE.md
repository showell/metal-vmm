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

**296. Shale stacks anything with three or more parts, one per line, in Roc and in Zig: CC'S** (Steve, 2026-10-28, on a long Pages.roc line: "We should make our shale aggressive about vertically stacking things. Almost anything with 3+ whatevers will read nice if it's stacked imho.") Do this first in the run, before 285: the ports after it then write stacked code.

**The tool,** in Shale's cookbook as recipes for any repo, not only the chat (cookbook/roc/ and cookbook/zig/):
- **A check:** any list, record, tuple, call's arguments, tag payload, or (Zig) struct literal or argument list with three or more elements on one line is a finding, path:line plus what to stack. A line over about 100 columns is a finding too. Plant one example of each.
- **A rewrite:** it stacks a finding one element per line, with a trailing comma. Roc's and Zig's formatters keep a trailing-comma collection stacked, so roc fmt and zig fmt hold the result. The rewrite is idempotent: a second run changes nothing. Comments and strings are never touched (read tokens, as the name hunts do).

**Then apply it** to roc-webbox's chat/ (its Roc and src/chat_*.zig) and to angry-gopher's chat Zig (zig-server/src/chat*.zig). That's one commit per repo, with the formatters and the usual gates green, and byte-identical behaviour held by the goldens. Add the check to roc-webbox's hunt, so a long line coming back is a finding. Pages.roc's sidebar_json `room` and `topic` lambdas are the example Steve read. M.

**295. One JSON builder, and multiline strings for the chat's HTML and CSS: CC'S** (Steve, 2026-10-28, reading Pages.roc's hand-built JSON: "I don't have a huge problem with hand-generating json, but do we need to?") Any order within 285-294; see 285's rules.
- **One JSON builder:** the chat has two, JsonText's obj/arr/str/bool helpers and 269's opaque JsonOut. Move every JSON the chat writes onto JsonOut (Pages' sidebar, feeds, recent, search, the frames, and the four hand-built strings in main.roc). Then delete JsonText's building half; its parsing half stays. Byte-identical output, held by the existing goldens.
- **Multiline strings for markup:** Roc's `\\` multiline strings (docs/langref/strings.md at the pin) need no `\"` escaping and keep `${…}` interpolation. Rewrite the HTML and CSS literals in Pages.roc and Chrome.roc (links_css and its kin) with them, wherever that reads better than `\n`-joined one-liners. Leave short single-line ones alone. Byte-identical pages, held by the goldens.

S-M.

**294. Aggressive port 10: what's left of the chat's Zig, triaged again: CC'S** (Steve, 2026-10-28, aggressive.) Last of the run. Run the census after 285-293 and list every live chat Zig unit that isn't a webbox primitive (files, the bus, streams, process-lifetime state, HTTP, bytes), the markdown processor, the search index, or auth. For each, give one line: what it does, its lines, and the port you'd do next. Port the two smallest yourself if time allows. This becomes the next run's queue. S.

**293. Aggressive port 9: admin retire's plan in Roc: CC'S** (Steve, 2026-10-28, aggressive.) Any order. See 285's rules. chat_retire (about 280 lines) is destructive, so move it in two halves:
- **The plan, pure:** which conversations and topics to retire under a mode, days and keep, plus keepProblem. It moves to the Roc, with a twin against the Zig plan over the retire tests' trees.
- **The execution** (staging and removals) stays Zig behind the admin gate, taking the Roc's plan.

Retire must never remove more than the old Zig would: the twin holds that. The admin page's handler can call the Roc plan through a second entry, or through the existing one with an admin route. Choose and say why. M-L.

**292. Aggressive port 8: uploads decided by the Roc: CC'S** (Steve, 2026-10-28, aggressive.) See 285's rules. chat_upload has about 270 lines.
- **Moves to the Roc:** every decision: the quota check against users' reserved bytes (through a primitive), the accepted types, the size limits (272's constants), the stored name, and the answer.
- **The Zig keeps** what has to touch every byte, as primitives: reading the multipart body to disk, and sniffing the type from the first bytes.

Say what moved and what couldn't, and why. **Tests:** goldens frozen on the old Zig for an image, a video, a refused type, over quota, too big, and a non-member. L: split as you see fit.

**291. Aggressive port 7: downloads decided by the Roc: CC'S** (Steve, 2026-10-28, aggressive.) Any order. See 285's rules. chat_download (about 60 lines) bundles a topic. The Roc authorizes and names the bundle. The Zig keeps the tar.gz streaming as a primitive (it is bytes and compression). Range handling for /uploads goes the same way: the Roc decides, the Zig serves the bytes. **Tests:** goldens of the headers and statuses (full, a range, a bad range, a non-member) frozen on the old Zig. S-M.

**290. Aggressive port 6: the docs' writes in Roc: CC'S** (Steve, 2026-10-28, aggressive.) Needs 289. See 285's rules. Move docs' save, new and save-to-the-reading-list: the forms, the checks and the files they write, through the file primitives. Afterwards, delete docs.zig, and docs_store except for whatever outside callers (reading_list, admin) still reach. Say which those are. **Tests:** goldens of the files written and the answers, frozen on the old Zig. Forms that are malformed, hostile or too big are refused as before. M.

**289. Aggressive port 5: the docs' read pages in Roc: CC'S** (Steve, 2026-10-28, aggressive.) See 285's rules. angry-gopher's docs.zig and docs_store (about 390 lines) serve /chat/docs. Move the pages that only read: the three-pane page, a doc's view, the list. Use JsonOut and the existing page modules. The Zig keeps only what 291 hasn't moved yet. **Tests:** route goldens frozen on the old Zig first, for the owner, another member and a missing doc. M.

**288. Aggressive port 4: presence decided by the Roc: CC'S** (Steve, 2026-10-28, aggressive.) See 285's rules.
- **The change:** count_presence! shrinks. The Zig keeps the online map: mark it active and answer whether this was the offline-to-online edge, plus check_online!. The Roc builds and publishes the came-online frames on that edge.
- **settings.zig** marks presence through the same map without a broadcast. **That's a behaviour change:** a settings view no longer announces a member coming online. Say so plainly in FEEDBACK, so Steve can object.
- **A failed accounts read during the broadcast** loses the broadcast, never the request.

**Tests:** the edge, broadcast once to each other member; no broadcast on a second request; and settings marks the member without a broadcast. M.

**287. Aggressive port 3: a message's store decided by the Roc, which writes .count: CC'S** (Steve, 2026-10-27, on .count: "Wait for one writer". 279 removed the old store, so the Roc and the startup backfill are now the only writers, and they never run at once.) See 285's rules.
- **The change:** store_message! shrinks to primitives:
  - an append that returns the transcript's new size;
  - an index_message! for the search index (process-lifetime state, so it stays a primitive).
- **Moves to the Roc:** the block, the count sidecar's text (Count.roc already parses it), and the order: append, count, index.
- **Stays Zig:** the startup backfill, the one other writer.

**Tests:**
- A byte-identity twin: the sidecar the Roc writes must equal what the backfill writes for the same transcript.
- A send's files and frames frozen before the change and the same after.
- A crash between the append and the count leaves a state the next count reads correctly (a stale count is a miss).

M-L.

**286. Aggressive port 2: every chat stream decided by the Roc: CC'S** (Steve, 2026-10-28, aggressive.) See 285's rules. Six routes are still Zig's: a topic's stream, the recent, images and code streams, notifications and the sidebar stream.
- **The change:** a Stream answer kind. The Roc authorizes the request (as 271 does for the other tails), picks the bus key with BusKey, and answers Stream(key). The Zig's sse.forward is the primitive that holds the connection.
- **Also:** the NotFound route becomes the Roc's answer too.
- **Afterwards:** only the static assets stay Zig.

**Tests:** route goldens for each stream: an owner, a non-member, a bad key. One real stream through chat_router delivering a published frame exactly once. L: split it as you see fit, the topic stream first.

**285. Aggressive port 1: the chat's unreached Zig deleted: CC'S** (Steve, 2026-10-28: "At this point I want to be pretty aggressive about moving code to Roc.") **The run is 285 to 294, in number order unless an item says "any order".**

**Rules for 285-294:**
- **One branch per repo for the whole run** (Steve, 2026-10-28: simplify the branches): claude/roc-chat, from roc-webbox's origin/main (its default now; Steve, 2026-10-28) and angry-gopher's origin/box/roc-cleanup (283 and 284 are merged; fetch first). Each item is one or more commits on it, its message starting with the item's number. Push after each item; the box merges claude/roc-chat into box/roc-cleanup as items land and deletes nothing of yours. No per-item branches.
- **Gates:** roc-webbox's quick gate (shale tools/chat_quick_gate.shale); angry-gopher's ./ops/check_zig; the hunt (bool_returns 0); and the census before and after, in FEEDBACK. A frozen-golden twin pins any behaviour that moves, before the Zig goes, as in 263b-d.
- **Overruns:** an item past 1.5 times its estimate pushes what's green, says what's left, and moves on.
- **Never wait on the box. Roc never reads auth_root.**
- **Seam records stay small:** each new one is its own commit, with its size asserted.
- **Bias:** when unsure whether something can move to Roc, move it, and say in FEEDBACK what it cost.
- **The style guide moves with the code** (Steve, 2026-10-28: "stay on top of it as CC makes changes"): when an item makes or changes a style decision (a naming pattern, a new opaque type's shape, a way to build text, a new hunt), the same item adds or edits the rule in roc-apps' docs/roc-style.md, in its section, in the guide's form (a bold rule, why, an example), and its FEEDBACK says which rule. A new Shale check goes in the guide's enforcement list.

**This item:** the census's 799 unreached lines go. They're the old feed stores (code_store and images_store), recent_feed's old helpers, chat_state, the dead codec and fan-out functions, and the test-only fixtures whose tests test nothing live. Where a test of unreached Zig is the only check of a behaviour the Roc now owns, port the case to a Roc test first and say which. Test seams of live code stay. M. Census: unreached down to about 100 or fewer.

**284. A cache read that fails falls back, as a miss: CC'S** (Steve, 2026-10-28, on 275's and 277's open differences: "fall back on cache reads".) After 283; any order with it.

**The rule:** a read of a cache (the .count sidecar, the last-message window) that fails is a cache miss. The Roc recounts or reads the whole transcript, as the Zig did, and never fails the request. A read of the truth (the transcript itself) that fails still fails it.

**One home for it:** a single way to read a cache that answers Failed without failing the request, either a variant of read_at! or a mode. Both 275's count and 277's window use it. Every other read keeps failing the request on error. Don't add a fallback at each call site.

**Tests:** for both the count and the window, a sidecar or window read that errors (the folder-in-place-of-the-file plant) gives the same answer as a miss; a transcript that errors still fails the request. The usual gates. S.

**283. The welcome DM for new members only: CC'S** (Steve, 2026-10-28, on 279's first point: "new members only".) Branch claude/port-283 from origin/box/roc-cleanup, which the box is merging your overnight chain into now: fetch first.

**The rule:** a member who signs up from now on gets the welcome on their first /chat. An existing member never does, whether or not they have a DM with the host.

**The design is yours. Constraints:**
- Login stays out of the chat's files (Steve chose the first-/chat seeding for that reason).
- Nothing is inferred from the absence of a DM.
- The decision is made from a fact written when the account is made: for example, a "welcome pending" marker in the member's own users folder that signup writes and the Roc consumes, or the account's creation time against a cutover stamp.
- Say which you chose and why. Existing accounts must need no migration step to be "old".

**Tests:** a member made after the change is welcomed exactly once; one made before isn't, with or without a DM with the host; a crash between the welcome and the marker's removal doesn't welcome twice (or say why it can't happen). The usual gates. S-M.

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
