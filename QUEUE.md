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

**282. Overnight port 14 (stretch): search /messages in Roc: CC'S** (Steve, 2026-10-28.) Needs 281. See 269's rules.
- **The port:** hits cross the seam as flat byte strings, and excerptOf moves to the Roc. chat_search.handle goes.

**Test:** twins for excerpts (multibyte, the word at either edge) and the byte cap. M (about 60 minutes). Census about −138.

**281. Overnight port 13: search /words in Roc: CC'S** (Steve, 2026-10-28; the search index and its rate limit stay Zig, as platform primitives.) Needs 269. See 269's rules.
- **The port:** the Roc parses the query and writes the JSON.
- **The Zig keeps:** admit! (the rate limit) and a primitive, search_words!(key), returning word and count pairs plus the unreadable count.

**Test:** a twin over a built index. M (about 60 minutes).

**280. Overnight port 12: a roc glue test drive on one seam record: CC'S** (Steve, 2026-10-28.) Any order. See 269's rules. Run roc glue on one small seam record (the listing's Entry). Assert at compile time that its generated layout equals the hand-laid one in chat_abi.zig. Report the diff and anything glue can't express. **Replace nothing.** M (about 60 minutes).

**279. Overnight port 11: the welcome DM seeded on a member's first /chat visit: CC'S** (Steve, 2026-10-28: "Seed on first /chat visit".) Needs 278. See 269's rules.
- **The change:** login stops writing to the chat. When a member opens /chat and has no DM with the host account yet, the Roc creates it, with the welcome message as login's code writes it today: the same text, topic and author.
- **Then:** if docs' post (278) has moved, delete the old Zig store's appendMessage, fanoutCrossPage and the chat_state functions only they reach. Otherwise say what still calls them.

**Test:** a new member's first /chat makes the DM exactly once; a second visit doesn't; an existing member with the DM sees no change. Compare against login's old output. Census: report the drop. M (about 60 minutes).

**278. Overnight port 10: docs' post to chat in Roc: CC'S** (Steve, 2026-10-28.) Needs 269. See 269's rules.
- **The port:** served_by sends the docs' post to the Roc. The partner check and the resume topic move there, and the Roc's own append_message! stores the message. The Zig docsPost goes.
- **Afterwards:** say what is left reaching the old Zig store (appendMessage, fanoutCrossPage and chat_state). The welcome DM (279) should then be the only caller.

**Test:** chat_actions_twin compares the transcript, the count sidecar, the frames and the 303 against the old Zig. M (about 60 minutes).

**277. Overnight port 9: gather_recent in Roc: CC'S** (Steve, 2026-10-28.) Needs 269, 275 and 276. See 269's rules.
- **The port:** the /chat/recent rows built in Roc: accounts, channels, topics and docs, with the mtime floored to even seconds as now.
- **Deleted:** the hosted gather_recent!, the RecentRow seam record, recent.gatherRows, and chat_count.lastMessage once nothing reaches it.

**Test:** the recent page twin over a tree that has DMs, channels, an empty topic and docs. **Measure:** one /chat/recent before and after. M (about 60 minutes). Census about −440 reached.

**276. Overnight port 8: a topic's last message in Roc: CC'S** (Steve, 2026-10-28.) Needs 274. See 269's rules. Port chat_count.lastMessage: a topic's last message without reading the whole transcript, through read_at! and stat!, with its window, its fallback, and its rule of one member as the author or nobody. **Test:** a twin against lastMessage for a current record, a record behind, a full window, the fallback, a nameless author and duplicate names. M (about 60 minutes).

**275. Overnight port 7: message_count! in Roc (read-only): CC'S** (Steve, 2026-10-28; **the Roc does not write the count sidecar tonight**: "Wait for one writer".) Needs 274 (stat!, read_at!). See 269's rules.
- **The port:** the Roc trusts the count sidecar only when the transcript's size matches; otherwise it reads the transcript and counts its blocks, as chat_count.messageCount does. Count.roc already parses the sidecar. The hosted message_count! goes.
- **The Zig keeps writing the sidecar:** store_message!, the backfill and appendMessage all still do.

**Test:** a twin over CountFixture's cases (a stale size, a torn sidecar, the legacy two-line form, a missing transcript), and a send's numbering in chat_actions_twin. M (about 60 minutes).

**274. Overnight port 6: stat! and read_at!, two file primitives: CC'S** (Steve, 2026-10-28; see 269's rules.) Two hosted primitives, each checked like read!:
- **stat!(path):** Missing, a size and an mtime in seconds, or Failed.
- **read_at!(path, offset, max):** the bytes.

The record is laid out by hand in chat_abi.zig with its size asserted, in its own commit. **Tests:** scripted-host tests for missing, a folder, a failed stat and a short read, plus one through the real ABI. S (about 30 minutes).

**273. Overnight port 5: saved in Roc, without the mtime cache: CC'S** (Steve, 2026-10-28: "Drop it, measure".) Needs 269. See 269's rules.
- **The port:** the Roc reads the member's reading list (users/<uid>/docs/reading-list.md, through read!), parses its refs and answers the saved ids as JSON. The Zig savedIds, reading_list's savedIdsFor and its mtime cache go.
- **Test:** a twin of parseRefs (malformed refs, both prefixes, a bad id); route twins for no doc, an empty doc, and a doc saved in another topic.
- **Measure:** one topic page load with a 1,000-entry reading list, before and after. A cache comes back only if the difference is measurable to a person.

M (about 60 minutes). Census about −100.

**272. Overnight port 4: limits! as Roc constants: CC'S** (Steve, 2026-10-28; see 269's rules.) Any order. The upload and search caps become Roc constants. The hosted limits! and its Limits seam record go. The Zig keeps the copies that enforce them, held equal by a Zig test that reads the Roc constants (or their values, pinned). S (about 30 minutes).

**271. Overnight port 3: the Roc answers every chat 404 and authorizes every DM and channel route: CC'S** (Steve, 2026-10-28: "Roc decides, Zig keeps a floor".) See 269's rules.
- **The 404s:** the Invalid and NotFound routes, plus the "not yours" and no-topic pages, come from Roc. Pages.roc gets the page.
- **Authorization:** served_by runs find! and the topic check before delegating any DM or channel tail (upload, uploads, stream, download, saved). The Roc becomes the one authorization point.
- **The Zig keeps a floor:** angry-gopher's chat.zig convRoute and channelRoute become a dispatch that builds the folder from the key. It keeps a cheap check that the path is under the chat root and the key is canonical, and never answers a 404 page itself. notFoundPage, topicExists and partnerName go.

**Test:** chat_actions_twin scenarios: every tail by a non-member, with a missing topic, and with an invalid tail. Status and bytes must equal the old Zig's. Red first, by deleting a Zig arm. Report what a stream open now costs (a list_accounts!). M (about 60 minutes). Census about −90.

**270. Overnight port 2: BusKey and ChatUrl in the Roc chat: CC'S** (Steve, 2026-10-28; see 269's rules.) Any order. Two small opaque types:
- **BusKey:** the bus keys Fanout and Feeds build from strings.
- **ChatUrl:** the Roc twin of webbox's http.Target, for the URLs they build.

Replace the string-built keys and URLs. **Test:** a twin against chat_fanout's bus-key functions, its conv base URL and Target formatting, and a hostile path refused. S (about 30 minutes).

**269. Overnight port 1: an opaque JSON builder in the Roc chat: CC'S** (Steve, 2026-10-28: overnight porting, from the box's triage of the census.) **The overnight run is 269 to 282, after 267, 268, 263b-d and 265, in number order unless an item says "any order".**

**Rules for 269-282:**
- **Branches:** each item gets branch claude/port-N, from origin/box/roc-cleanup, or from the item it needs when it says "needs". The box merges them in order.
- **Gates:** roc-webbox's shale tools/chat_quick_gate.shale; angry-gopher's ./ops/check_zig whenever Zig changes; the hunt (shale tools/roc_hunt/hunt.shale, with bool_returns 0); and the census before and after, for any item that retires Zig.
- **Each item's FEEDBACK** gives its census delta (live Zig lines, Roc lines), its wall time and its slowest step.
- **Overruns:** an item past 1.5 times its estimate pushes what's green, says what's left, and moves on.
- **Never wait on the box.**
- **Roc never reads auth_root.**
- **Seam records stay small** (laid out by hand in roc-webbox's chat_abi.zig); a new one is its own commit, with its size asserted.

**This item, any order:** an opaque builder for JSON output (JsonOut; Json is reserved): object, array, string, number, built in order, over JsonText's escaping. Move one existing hand-built JSON (the smallest) onto it. **Test:** a twin against Zig's std.json formatting over the escaping corpus, red then green. M (about 60 minutes).

**268. The Roc chat's adversarial review, hardening the seam's trust: CC'S** (Steve, 2026-10-27.) After the availability item. The box fixed the easy seam findings on `box/roc-cleanup`: a path that isn't UTF-8 no longer panics the router; the compile-time tag check now covers `Membership`, `Done` and `Serving`; and Roc's field-order rule is stated once, correctly, in `src/roc_abi.zig`. Left for you, branch `claude/review-hardening`:
- **The Zig trusts a Roc value and panics on a bad one:** `chat_abi.zig` ~:685 `@errorFromInt(fault)` on any U16 (0 or garbage is illegal behaviour); ~:784 a 405 allowing `Other`; angry-gopher's chat router (box/roc-cleanup) ~:302 a `Conv` family that is neither Dm nor Channel. Make each a checked conversion that fails the request (a 500 via `call.failed`), never a panic or UB.
- **"After a failure the host does nothing more" covers failures, not answers:** `check_hostile!`'s Refused (~:671) and `read_body!`'s 413 (~:334) respond to the request themselves but don't stop later effects or a second response. Make an answered request as dead as a failed one. And `.answered` with neither a host failure nor a host answer should be the router's 500, not silence.
- **Defense in depth:** `roc_chat_message_count` and `roc_chat_store_message` (~:535, ~:656) skip `inRoot`; the host joins `conv.key` and `sid` into paths unchecked (angry-gopher's chat router, box/roc-cleanup, ~:295-310). Check them as the other paths are.
- **`load_uid!` reports a bad uid as `fail!(NotUtf8, …)`** (`main.roc` ~:303); the log then says "a file is not UTF-8". Give it its own reason.
- **Measure, then decide:** quadratic scans over a message on every send (`Feeds.img_tags_from`, `Recent.html_from`/`md_from`, `Feeds.close_at`, `Recent.quotes_from`) for inputs like 16k `![` or unclosed fences, up to 64 KB, under the global turn. Time one worst case. If a send costs more than about 50 ms, make the scan linear; otherwise report the number and stop.
Gates as above. Wall time: about 45 minutes.

**267. The Roc chat's adversarial review, availability: one bad byte is not a lasting 500: CC'S** (Steve, 2026-10-27.) After the security item, before 264 and 265. Branch `claude/review-availability` from `origin/box/roc-cleanup`. All of these trace back to the "text at the door" rule, `Files.read!` failing the request with NotUtf8. That rule is right for a file the request must understand, and wrong where one damaged line, entry or account takes down a page for everyone:
- **Reactions** (`main.roc` ~:198, `Files.roc` ~:121): a reaction line torn mid-emoji makes `GET …/reactions` a 500 for good. Serve the stored bytes without decoding, as the Zig oracle did (the client drops a bad line), or skip bad lines.
- **Feeds and recent** (`main.roc` ~:600 code/images, ~:576 with `Recent.roc` ~:25): a torn feed entry or a torn last transcript block 500s that member's page, or every member's /chat/recent. Skip the damaged entry or block, and count it where the host keeps such counts.
- **Accounts** (`main.roc` ~:276-281, `Accounts.roc` ~:64-69): one account whose name isn't UTF-8 fails the whole listing, so every member's chat goes down. List it with `name_read: Unreadable`, as the code's own comment says it should, so only a lookup of that name fails.
- **Channel member files** (`main.roc` ~:384, `Paths.roc` ~:323): a file that isn't UTF-8 must be `Malformed` (skipped and counted), like a malformed one, not a request failure.
- **STORED IS DONE across creating a DM topic** (`main.roc` ~:885-888): the "hi" is stored, then `announce!` can fail and 500 the create, and the retry gets a 409. Make the announcement best-effort after the store, like the fan-out, counted when it fails.
Each with a test that plants the bad byte or the failure. Gates as for the security item. Wall time: about 45 minutes.

**265. The Roc chat's accessors as methods, and crash on the impossible: CC'S (needs the Roc toolchain)** (Steve, earlier rounds of the Roc chat cleanup; queued 2026-10-27.) After 264. **Needs the pinned `roc` in your container**, because the chat's gate runs `roc check`/`roc test`. If you can't get it, say so in FEEDBACK and skip this item; the box will publish the binaries somewhere you can fetch.

Branch `claude/roc-methods` from `origin/box/roc-cleanup` (roc-webbox, plus angry-gopher only if a seam changes). Style: roc-apps docs/roc-style.md, and the langref round-2 items Steve approved:
- **Part (1), accessors as methods:** a module function whose first argument is the module's own type and that reads or derives a field (`Paths.conv_base(key)`, `Paths.conv_key_bytes(key)`, `Uid.to_str`'s kin) becomes callable as a method (`key.conv_base()`), with the call sites moved to the method form. Do this only where the method reads better, and say where it doesn't.
- **Part (2), crash on the impossible:** each `?? 0`, `?? ""` or `Err(_) => <default>` that hides a case which can't happen becomes a `crash` with a reason, site by site. A case that *can* happen keeps its handling. Each site's commit line says which it is and why.

**Gates:** shale tools/chat_quick_gate.shale; angry-gopher's ./ops/check_zig if any Zig changed; shale tools/roc_hunt/hunt.shale (`bool_returns` stays 0). Wall time: about 45 minutes, with part (1) and part (2) as separate commits.

**263. The Roc chat's dead Zig: what only tests or twins reach, deleted (the census): CC'S** (Steve, 2026-10-27: "give CC the census Zig deletions".) The Roc chat's work lives on branch `box/roc-cleanup` of roc-webbox and angry-gopher (both pushed; neither repo has CI). Branch `claude/census-deletions` from `origin/box/roc-cleanup` in each repo you change, and fetch first: the box's cold agent is renaming the Host seam on that branch now (hosted effects in `chat/platform/Host.roc` and their Zig side), so expect it to move under you; the box merges with conflict detection.

**Goal (Steve's):** the chat as purely Roc as possible; Zig keeps only webbox primitives (files, the bus, streams, a little process-lifetime state, HTTP) and the markdown processor. The census, roc-webbox's shale tools/roc_hunt/zig_census.shale, counts the live chat Zig against the Roc and found about 770 Zig lines that only tests or twins reach (twins: a Zig function kept beside its Roc port so a test can compare them).

**Part (1), the census runs again:** it fails today with `chat/main.roc: no roc_serves`. That function is `served_by` now, returning `[Roc, Zig]` rather than a Bool (zig_census.shale around lines 205-241 and 348; tools/README.md names it too). Make it evaluate the tag, with a test or plant that pins one route each way.

**Part (2), the deletions:** for each Zig function the census says only tests or twins reach:
- **A twin:** check first that its Roc port is live and covered by the Roc's own tests (`roc test chat/main.roc`, the chat's twin/crash hosts), then delete the Zig twin and the test that compared the two. If a twin test is the only coverage of some behaviour, port that case to a Roc test before deleting; say which.
- **Reached only by its own tests:** delete it with its tests.
- **Anything a production route still reaches:** leave it, and list it.
Report the census before and after (live Zig lines, Roc lines, routes Roc/Zig).

**Gates (each repo's, before you push):** shale tools/chat_quick_gate.shale in roc-webbox (~50 s: fmt, roc check, roc test, both repos' zig build test; it expects the two worktrees side by side, see its header); angry-gopher's ./ops/check_zig (~75 s). Roc test builds use `--opt=dev` (build.zig's `rocOpt`); never LLVM. **Roc never reads auth_root** (passwords, keys): delete nothing that guards it without saying so.

Wall time: about 45 minutes. Split it if it runs long: (1) and the twins first, the rest as a second commit.

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
