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

**301. The chat's Roc uses the builtins it reimplemented, and each byte helper has one home: CC'S** (Steve, 2026-10-28: "do all your recommended CC queued tasks", after a box survey of the chat against the pin's builtins, nightly-2026-10-09 `258ab27`'s `src/build/roc/Builtin.roc`; the survey tested each equivalence with `roc test`.) After 300.

- **Use the builtin:** `ZigText.json_string` is `Json.to_str(s).to_utf8()` (byte for byte, tested on 9 strings; JsonOut stays, as the builtin orders fields alphabetically). `Bytes.split_byte` is `List.split_on`; `Bytes.split_seq` is `List.split_on_list`. `Paths.cut_first`/`index_of` and `cut_last` are `List.split_first`/`split_last` (they answer `{before, after}`). `Bytes.has_prefix`, `Search.has_prefix`/`has_suffix` and `Saved.has_at` are `List.starts_with`/`ends_with`. `Time.div_floor`/`mod_floor` are `I64.div_floor_by`/`I64.mod_by`. `Search.lesser`/`greater`/`sub_floor` and `Feeds.smaller` are `U64.min`/`max`/`minus_saturated`. `Pages.counted` is `List.map_try`. twin's `List.concat(..., List.keep_oks([x], ...))` is `List.append_if_ok`; Html:57 and twin:1221 can use `List.join_map`; twin's six stride loops can use `List.chunks_of`. `Docs.slug_of_title` lowercases by hand where `Str.with_ascii_lowercased` exists; `Docs.one_line` can be two `replace_each`s, as Feeds already does.
- **Kept on purpose, said in the code:** `ZigText.parse_u64` stays strict (its body may shrink to all-digits then `U64.from_int_digits`); `JsonOut.lossy` stays (one U+FFFD per byte, as chat_search.zig, where `Str.from_utf8_lossy` gives one per sequence); the ASCII trim stays (`Str.trim` is Unicode).
- **One home for each byte helper:** 7 trims (`ZigText.trim`, `Paths.trim_line`, `SafeImg.trim`, `Feeds.trim_info`, `Upload.trim_spaces`, `Accounts.stored_name`, `Docs.trim_hyphens`), about 30 "while" scans (`ZigText.count_while`/`count_back_while`, `Feeds.count_while`/`count_back`, `SafeImg.skip`/`back`, `Saved.run`, `Bytes.leading`, `Docs.leading_tildes`, `Transcript.line_len`, `Time.count_digits`), 3 byte finds and 3 byte-lowerings (`SafeImg.lower`, `Feeds.lower`), and the ASCII tests (`Paths.is_alpha`/`is_alnum`, `Search.is_ascii_punct`, 13 inline `c >= '0' and c <= '9'`). Each becomes one function in Bytes (say if another home reads better), taking a predicate or a set where the copies differ only in it.
- **The style guide** gains a section on `Str` at the pin: no `len`, `Str.trim` is Unicode, `U64.from_str` takes `+1` and `1_000`, why each kept helper exists. (The box's notes said it had one; it doesn't; the reasons live only in ZigText's comments.)

Every change is behaviour-neutral: the twins and frozen runs hash unchanged. Done when the list above is gone or each kept one says why, gates green, census deltas in FEEDBACK. A box agent is separately preparing ASCII predicates on U8 for upstream Roc; don't wait on it.

**300. The chat's modules cut where a reader needs them; a single-caller check in the hunt: CC'S** (Steve, 2026-10-28: "We don't want to force folks to read 5 different modules to understand a code flow. The most egregious things would be a module whose functions are all called by a single other module (unless there's a very pragmatic reason to split it out)"; and "do all your recommended CC queued tasks".) After 292. A box survey (roc-ast call sites, `expect`s left out) found:

- **Upload** (162 lines) is called by one function, `main.serve_upload!`: move `serve_upload!` into Upload, so the upload route is one module (or inline Upload into main if a pure module is wanted; say which).
- **Topics** merges into **Conversation**: one subject, twin never imports Topics, and `Topics.is_same_name` only forwards.
- **The docs feature** is half in main (create_doc!, docs_page!, ...) and half in Docs, with its title helper in Recent (`Recent.doc_title`, called 4 times by Docs): give it one home.
- **The message count** goes main `count_messages!` → `believed_count!` → `Last.sidecar!` → `Count.parse`/`Count.believed`: five modules (main, Last, Count, Files, Paths) for one number. Put the flow in one place; `Last.sidecar!` belongs with `believed_count!`.
- **Feeds exposes six helpers only for Recent** (`count_back`, `is_space`, `lower`, `find_seen`, fence parsing) and `Feeds.sep` only for `main.fan_out!`: move each to the home its callers share (the builtins item after this one gives the byte helpers theirs).
- **Keep, with the reason written in the allowlist:** SafeImg (a security rule, auditable alone; its one caller is Feeds), Last if anything effectful stays in it, the pure modules called only by main and twin (twin is their reason), Files (the single gateway, `fs_bypass`), Chat and Host (the platform).
- **The check:** `tools/roc_hunt/hunt.shale` gains `single_caller`: a module whose production calls (outside `expect`s; twin counts as a caller) all come from one other module is a finding, unless an allowlist in the script names it with its reason. Plants need a folder of modules: one firing, and quiet ones for a module twin also calls and an allowlisted one. Its rule joins the style guide (Modules and visibility), and the check its enforcement list.

Done when the hunt's `single_caller` is 0 with every allowlist entry reasoned, the gates are green, and the census deltas are in FEEDBACK.

**299. angry-gopher's effects named for their acts: the Zig name hunt's 113: CC'S** (Steve, 2026-10-28: "queue the renames for CC".) Any order within the run; see 285's rules for gates. **Branch:** angry-gopher `claude/roc-chat` is the chat's; this item touches production's code, so branch `claude/zig-names` from angry-gopher **master**, and the box merges it to master and then to box/roc-cleanup.

**Where they come from:** Shale's Zig name hunt gained `noun_effect` (Shale `0489ab8`): an effect (a function taking `io`, an `Io` or a store) whose first word is no verb in `cookbook/words/verbs.txt`. On angry-gopher's zig-server/src it finds 113. Run it yourself: `cd <angry-gopher>/zig-server && shale <shale>/cookbook/zig/name_hunt.shale`, as its header says; `words=1` gives the census.

**Most are getters and predicates that take an `Io`** (`nowUnix` ×8, `session*` ×12, `docs*` ×5, `user*` ×5 such as `userExists` and `userIsMember`, `current*` ×4). The renames are mostly `read*`, `load*`, `find*`, `is*` and `has*`, named for the act, following roc-apps' docs/roc-style.md Naming rules. They apply to Zig too: an effect is named for its act, and a Bool is a question.
- **Your call, with a reason each in FEEDBACK:** `fanout` (`fan` is a verb, so `fanOutCrossPage` would pass); `playPage` (`play` reads as a noun there); `form` and `slot` (each builds or returns the thing).
- **Leave a name** where the rename reads worse than the finding, and say why. Some will be test helpers, where a looser name may be fine.
- **A real verb the table lacks:** add it to Shale's `cookbook/words/verbs.txt` in a dated batch with its example, rather than renaming around it.

Use Shale's `zig_rename` (and `rename_member.shale` for members and `module.name` callers, QUEUE 261). Gates: angry-gopher's ops/check_zig. Done when the hunt's noun_effect on zig-server is 0, or every one left is explained. M-L: split by file group.

**298. Shale finds a phrase in prose wherever a line break splits it: CC'S** (Steve, 2026-10-28: "Our doc editing methods in shale for docs are ready for this level of sophistication--we need to spot these kind of quirks. Let CC pick the best strategy. It doesn't have to be perfect, and there are some tradeoffs. They can push back as needed. The main thing is to identify them, even if in some cases the actual edit might need to be done in custom shale.") Any order within the run.

**The quirk that started it:** in roc-apps' docs/roc-style.md the box removed every "(not yet settled)" mark with a search, and one survived. Markdown wrapped it as `*(not yet` at the end of one line and `settled)*` at the start of the next, so a line-by-line search never saw the phrase. Prose in our docs, memory and comments is hard-wrapped, so any phrase search or edit over it has this blind spot. Markup inside the phrase (`*`, `**`, a backtick) can split it too.

**The goal:** Shale can *find* a phrase in wrapped prose, reporting each hit by its starting line, wherever line breaks, indentation and inline markup fall inside it. Then, where it can, *edit* it. Your call on the strategy, for example:
- normalize each paragraph (join its lines, collapse whitespace, optionally strip inline markup) and map a match back to its lines;
- a match whose regex treats a space as any run of whitespace including a newline;
- a markdown-aware reader of paragraphs, list items, block quotes and code fences, so a fenced code block is never treated as prose.

**What to build** is up to you; say which and why in FEEDBACK. Push back if a better shape exists:
- **Finding:** a builtin, or a prelude function or cookbook recipe, that finds a phrase across wrapped lines (and in comments, if cheap). Report every hit as path:line, the starting line, so a human can see it.
- **Editing:** an edit that rewraps the paragraph after replacing the phrase, where that's safe. Where it isn't (markup in the middle, a list item's hanging indent), the finder at least says so, and a custom script does the rest.
- **The trade-offs to name:** reflowing a paragraph churns the diff; stripping markup can make a match ambiguous; comment blocks have their own prefixes (`--`, `//`, `##`).
- **Tests:** the `*(not yet` / `settled)*` case, a phrase split inside `**bold**`, a list item's continuation line, a phrase inside a code fence (must not count as prose), and a phrase split across a blank line (two paragraphs: must not match).

Then run the finder for a few phrases over the docs we keep (each repo's README, roc-apps docs, metal-vmm's QUEUE and FEEDBACK) and report any surprises. S-M.

**297. Three or more arguments take a record; the name hunt's five: CC'S** (Steve, 2026-10-28: "I prefer the record approach", for signatures with three or more arguments, which roc fmt can't stack since it refuses a trailing comma in a type annotation.) Any order within the run; see 285's rules. It's in roc-apps' roc-style.md under "Name what travels together", marked as Steve's preference.

**Part (1), records:** the stack hunt (roc-webbox's hunt, cookbook roc/stack.shale) now names 73 signatures with three or more bare arguments, for example main.roc's `Chat.Request, Route.R, Paths.TopicAt, Chat.Conv, Who`. Each becomes one record argument, or two arguments where one is a record of the rest, with call sites passing named fields. Where a record already exists that holds the same things, reuse it rather than making another.
- **Hosted effects (chat/platform/Host.roc) cross the seam:** a record there is a new seam record, so it goes in its own commit with its mirror in roc-webbox's src/chat_abi.zig, its size asserted, and a test driving each field through the real ABI. If a hosted effect's arguments would make a big record, split it, or leave that effect with its arguments and say why in FEEDBACK.
- Done when the hunt's signature findings are 0, or every one left is explained.

**Part (2), the name hunt's twelve,** now that it reads module members and bare annotations (roc-webbox `b0d5ea4`, Shale `075a5b9`): the hosted effects in chat/platform/Host.roc named as nouns, `stat!` (:95), `aside!` (:196), `welcome_pending!` (:257), `welcome_done!` (:265), `srcs!` (:269), `me!` (:277) and `now!` (:281), whose renames cross the seam with their Zig side; and the module members: noun_effect `Files.stat!` (Files.roc:58), `Last.of!` (Last.roc:32) and `Last.sidecar!` (Last.roc:97); vague `Form.value` (Form.roc:20) and `JsonOut.object` (JsonOut.roc:51). Rename each for its act or meaning, or, where the name is right (a JSON builder's `object` names the JSON value it makes), say so and leave it.

Goldens hold behaviour byte for byte. M-L: split part (1) as you see fit, pure modules first and hosted effects last.

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
