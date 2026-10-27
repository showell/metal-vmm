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

**268. The Roc chat's adversarial review, hardening the seam's trust: CC'S** (Steve, 2026-10-27.) After the availability item. The box fixed the easy seam findings on `box/roc-cleanup`: a path that isn't UTF-8 no longer panics the router; the compile-time tag check now covers `Membership`, `Done` and `Serving`; and Roc's field-order rule is stated once, correctly, in `src/roc_abi.zig`. Left for you, branch `claude/review-hardening`:
- **The Zig trusts a Roc value and panics on a bad one:** `chat_abi.zig` ~:685 `@errorFromInt(fault)` on any U16 (0 or garbage is illegal behaviour); ~:784 a 405 allowing `Other`; `chat_router.zig` ~:302 a `Conv` family that is neither Dm nor Channel. Make each a checked conversion that fails the request (a 500 via `call.failed`), never a panic or UB.
- **"After a failure the host does nothing more" covers failures, not answers:** `check_hostile!`'s Refused (~:671) and `read_body!`'s 413 (~:334) respond to the request themselves but don't stop later effects or a second response. Make an answered request as dead as a failed one. And `.answered` with neither a host failure nor a host answer should be the router's 500, not silence.
- **Defense in depth:** `roc_chat_message_count` and `roc_chat_store_message` (~:535, ~:656) skip `inRoot`; the host joins `conv.key` and `sid` into paths unchecked (`chat_router.zig` ~:295-310). Check them as the other paths are.
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

**266. The Roc chat's adversarial review, security: feeds and page JSON (Roc and the live Zig): CC'S** (Steve, 2026-10-27: adversarial reviews of the Roc chat; "fix easy things yourself; queue up CC for more involved things".) **First after 263**, ahead of 264 and 265: two of these are live on lynrummy.com.

**Already fixed by the box** (angry-gopher master `fc0b3ee2`): stored XSS through the images feed. `images_store.encodeImagesEvent` now rebuilds each stored `<img>` with `markdown_media.safeImgAt` (allowlist, same-origin src) and drops what it can't. Read that commit first; it's the pattern.

**Part (1), the same XSS in the Roc port** (`box/roc-cleanup`): `chat/Fanout.roc` `parts_of` takes raw `<img …>` spans via `Feeds.img_tags` (`Feeds.roc` ~:209/:384), stores them in members' `images.md` and publishes them live; `Pages.roc` ~:261 puts them in the page JSON. Give the Roc the renderer's rule. Either a hosted primitive that returns the safe rebuild (the host has `safeImgAt`), or a Roc port of it with tests matching markdown_media's cases. Say which and why. Rebuild at the one place both the live event and the page backlog pass through, so stored entries are covered too. Then merge angry-gopher master (with `fc0b3ee2`) into `box/roc-cleanup`.

**Part (2), forged code-feed entries** (live Zig `code_store.formatCodeEntry`, and Roc `Feeds.code_entry` ~:356): a fenced block whose body contains the entry separator (`\n\n-------------\n\n`) and a fake `Sent by … source MSG_x in …:` header becomes its own entry in every member's `code.md`, showing a forged sender. `images_entry` already neutralizes CR/LF; give code entries an encoding that can't contain the separator, with the reader matching, and keep existing files readable. Fix master's Zig and the Roc. Tests: the forging body produces one entry with the real sender.

**Part (3), JSON inside `<script>`** (Roc `Html.script_safe` ~:74, and the Zig that builds the same pages on master): it escapes only `</`, so a message holding `<!--<script` in the recent excerpt or a code body puts the HTML tokenizer into its double-escaped state, which swallows the page's own `</script>` and `<script src>`. Escape every `<` in JSON embedded in a script as `<` (and `>`/`&` if you like), in one shared function per side. Test with that input.

**Gates:** angry-gopher master: `./ops/check_zig`. The branch: `shale tools/chat_quick_gate.shale` and angry-gopher's `check_zig` in the roc-clean layout (264's doc-check finding is known). Push master's fixes to master, the Roc's to `claude/review-security` from `origin/box/roc-cleanup`. Wall time: about 60 minutes. Part (1) first.

**265. The Roc chat's accessors as methods, and crash on the impossible: CC'S (needs the Roc toolchain)** (Steve, earlier rounds of the Roc chat cleanup; queued 2026-10-27.) After 264. **Needs the pinned `roc` in your container**, because the chat's gate runs `roc check`/`roc test`. If you can't get it, say so in FEEDBACK and skip this item; the box will publish the binaries somewhere you can fetch.

Branch `claude/roc-methods` from `origin/box/roc-cleanup` (roc-webbox, plus angry-gopher only if a seam changes). Style: roc-apps `docs/roc-style.md`, and the langref round-2 items Steve approved:
- **Part (1), accessors as methods:** a module function whose first argument is the module's own type and that reads or derives a field (`Paths.conv_base(key)`, `Paths.conv_key_bytes(key)`, `Uid.to_str`'s kin) becomes callable as a method (`key.conv_base()`), with the call sites moved to the method form. Do this only where the method reads better, and say where it doesn't.
- **Part (2), crash on the impossible:** each `?? 0`, `?? ""` or `Err(_) => <default>` that hides a case which can't happen becomes a `crash` with a reason, site by site. A case that *can* happen keeps its handling. Each site's commit line says which it is and why.

**Gates:** `shale tools/chat_quick_gate.shale`; angry-gopher's `./ops/check_zig` if any Zig changed; `shale tools/roc_hunt/hunt.shale` (`bool_returns` stays 0). Wall time: about 45 minutes, with part (1) and part (2) as separate commits.

**264. Shale's doc check calls a gitignored build output gone in a sibling-worktree layout: CC'S** (The box, 2026-10-27; Steve: keep CC's queue full.) After 263. Shale and Zig only, so it needs no Roc toolchain.

**The symptom:** angry-gopher's `./ops/check_zig` runs `cd ../shale && zig build doc-check -- only=angry-gopher`. In `~/showell_repos` that passes. In `~/build/roc-clean`, where `shale`, `angry-gopher`, `zig-webbox` and the rest are sibling worktrees and checkouts, it reports `engine.js` as gone, twice: `games/lynrummy/README.md:79` and `games/lynrummy/elm/src/Puzzle/README.md:43`. The docs are identical, the file exists at `games/lynrummy/elm/engine.js` in both, and it is gitignored in both.

**Where to look:** `tools/doc_check.shale`'s `ignored(at, repo, paths)` runs `git -C real(at .. repo) check-ignore --no-index --stdin` over the citation as written (`engine.js`) and as joined from the doc's folder (`games/lynrummy/engine.js`). Neither is the file's real path. Also check `is_dir(at .. t)` and `real()` when `at` isn't a mount root (the roc-clean siblings are under the `build:` mount, or reached by a relative `..`).

**The change:** find why the two layouts differ, and fix the root cause. Either the check is wrong in one layout, or it passes in the other only by accident. If a bare file name is meant to pass because any file of that name is ignored, say so in a comment and make that hold in both layouts. **Tests:** a fixture in each layout, a plain checkout and sibling worktrees, both giving the same answer, and a citation of a file that is really gone still reported in both. Wall time: about 30 minutes.

**263. The Roc chat's dead Zig: what only tests or twins reach, deleted (the census): CC'S** (Steve, 2026-10-27: "give CC the census Zig deletions".) The Roc chat's work lives on branch `box/roc-cleanup` of roc-webbox and angry-gopher (both pushed; neither repo has CI). Branch `claude/census-deletions` from `origin/box/roc-cleanup` in each repo you change, and fetch first: the box's cold agent is renaming the Host seam on that branch now (hosted effects in `chat/platform/Host.roc` and their Zig side), so expect it to move under you; the box merges with conflict detection.

**Goal (Steve's):** the chat as purely Roc as possible; Zig keeps only webbox primitives (files, the bus, streams, a little process-lifetime state, HTTP) and the markdown processor. The census, roc-webbox's `shale tools/roc_hunt/zig_census.shale`, counts the live chat Zig against the Roc and found about 770 Zig lines that only tests or twins reach (twins: a Zig function kept beside its Roc port so a test can compare them).

**Part (1), the census runs again:** it fails today with `chat/main.roc: no roc_serves`. That function is `served_by` now, returning `[Roc, Zig]` rather than a Bool (`zig_census.shale` around lines 205-241 and 348; tools/README.md names it too). Make it evaluate the tag, with a test or plant that pins one route each way.

**Part (2), the deletions:** for each Zig function the census says only tests or twins reach:
- **A twin:** check first that its Roc port is live and covered by the Roc's own tests (`roc test chat/main.roc`, the chat's twin/crash hosts), then delete the Zig twin and the test that compared the two. If a twin test is the only coverage of some behaviour, port that case to a Roc test before deleting; say which.
- **Reached only by its own tests:** delete it with its tests.
- **Anything a production route still reaches:** leave it, and list it.
Report the census before and after (live Zig lines, Roc lines, routes Roc/Zig).

**Gates (each repo's, before you push):** `shale tools/chat_quick_gate.shale` in roc-webbox (~50 s: fmt, roc check, roc test, both repos' zig build test; it expects the two worktrees side by side, see its header); angry-gopher's `./ops/check_zig` (~75 s). Roc test builds use `--opt=dev` (build.zig's `rocOpt`); never LLVM. **Roc never reads auth_root** (passwords, keys): delete nothing that guards it without saying so.

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
