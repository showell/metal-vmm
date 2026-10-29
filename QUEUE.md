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

**319. roc-chat: the readability review's fixes: CC'S** (Steve, 2026-10-29.) **showell/roc-chat only**, on `claude/roc-chat`. **Start only when FEEDBACK has a box entry saying the security fixes (`box/security-2`) are merged into roc-chat `main`.** Until then, it isn't startable: finish 318 and stop. Branch from that `main`. Finish as 314 did: roc-chat's verify script passes in full, its output goes in FEEDBACK, and the box merges.

**Read first:**
- docs/reviews/REVIEW-roc-readability-2026-10-29.md (this repo): take every **roc-chat** finding. The roc-markdown ones are 318's;
- Steve's decisions at its top:
  - remove the four unused hosted functions;
  - pages use roc-markdown's one HTML escape, which 318 exposes; if 318 isn't merged yet, leave `Pages.escape` and say so;
  - keep both `Ascii` copies, with a header line saying why.

Its line numbers are old (a restyle and renames came since: the Store's lookups are `load_*!`): search for the quoted text.

**Also:**
- **The bypass:** `ConvAccess.Conv.start` (the raw constructor) is still public beside `start_by`, which holds the owner rule (security M2). Make the rule impossible to bypass from app code: test-only construction, or one constructor taking the starter, whichever the pin allows. Say which.
- **`name_hunt`'s 24 remaining `noun_effect` findings:** route handlers are `serve_*!`, and fallible lookups `load_*!`. A Shale fix teaching it mint, redeem, audit, spend and echo may land first; rerun the recipe.
- **The domain refusal aliases `errors` flags** (`GitHubSignIn.Refusal`, `InviteCodec.Refusal`, `ApiKey.Refusal`, and so on): judge each one, keep a shared alias only where it's one vocabulary on purpose, and say why at its definition.

**Verify:** the floors don't fall, every plant stays red at its step, and both formatters are clean. Run as `steve`.

**318. roc-markdown: the reviews' polish, the uploads prefix, one escape: CC'S** (Steve, 2026-10-29: "Keep polishing markdown as top priority"; "2) yes" to the uploads prefix.) **showell/roc-markdown only**, after 317 and on top of it, on `claude/roc-markdown`. Finish as 316 and 317 do: roc-markdown's verify script passes, its output goes in FEEDBACK, and the box merges, re-freezes gold and explains every move.

**Read first:** two cold reviews from today, in this repo:
- docs/reviews/REVIEW-roc-readability-2026-10-29.md: take every roc-markdown finding. The roc-chat ones are the box's.
- docs/reviews/REVIEW-roc-security-2026-10-29.md: take H2 and L2's markdown half.

Their line numbers are as of roc-markdown `66b99a7`; search for the quoted text.

**Do, in this order, each its own commit:**
1. **The uploads prefix** (security H2 and L2; Steve's decision).
   - Today `MdSafety.is_local_url` allows any `/` path for `<img>` and `<video>`, which lets a message aim media at the app's own routes (`/conversations/N/stream`, `/login`).
   - Allow only paths under one uploads prefix. It's the chat's convention, so it lives in MdChat, with `/user_uploads/` as the default. MdSafety asks MdChat for it.
   - The rule applies to rebuilt `<img>`/`<video>` tags and to 317's `![alt](src)` alike.
   - Freeze cases for the inside and outside sides: `/user_uploads/a.png` passes; `/conversations/1/stream`, `/login` and `/user_uploads/../login` don't. Read how `..` and percent-encoding should be judged, and say what you chose.
   - **The playground's `safety` example** must still show an image:
     - point its sample at `/user_uploads/sample.png`;
     - make `zig build playground` put the image where the box can publish it at the site root's `user_uploads/`, and say exactly what the box copies where;
     - re-freeze `examples`, named in the commit.
2. **One HTML escape** (Steve: "yes"): `MdText.escape_onto` escapes `'` too, and the package exposes it, so roc-chat's pages can use it instead of their own. Gold will move if any rendered text held a `'`: say which corpora moved.
3. **The readability review's roc-markdown findings:**
   - **Stale claims:** the "the Zig's charges, unit for unit" clauses (MdInline, MdLinks, MdEmphasis), MdMedia's Feeds reference, and Bytes' "roc-webbox's chat".
   - **History in place of reasons:** the ticket numbers and the old Zig function names that open docstrings (``## markdown `renderTrusted`:`` and about 15 more, plus "the Zig's"). Each reason already stands without them.
   - **Names:** MdInline's `$run_start` becomes `$text_start`, and `$rb`/`rb` becomes `$next_bracket`.
   - **Ascii:** keep both copies (Steve). Add one header line in Ascii.roc saying roc-chat keeps its own copy on purpose until a shared package exists.
   - **Duplication:** have `work_units`, `hostility` and `rendered` share one seed builder. Keep the corpus counts in one home: verify.shale reads ratchet.txt rather than copying it.
   - **The long functions,** split along their real seams: `MdInline.render_onto` (each byte class a scan returning `{html, end}`, with one helper taking the piece) and `Md.blocks_onto` (a `block_at` dispatcher, its result applied once). Both must keep every frozen answer and work unit byte for byte, with no re-freeze.
   - **Tests a reader can read:**
     - `MdEmphasis` gets worked examples (`expect`s) of the rule of 3 and the floor;
     - `MdInline`'s localhost expect gets a one-line why;
     - `Md.roc`'s "markdown.zig's own cases" label says what the group proves.
   - **README accuracy:**
     - "269 of the specs' examples", and say how they were chosen (`spec_diverge.txt`'s header);
     - "about a thousand hostile shapes";
     - name why MdFence, MdMedia and MdTable are exposed.
     - Keep the README for the deciding developer, with detail in TESTING.md.
   - **Timing:** the judge's time stays within 10% of before.

**What roc-markdown's verify script checks:** raised counts; **plants, each red:** a media src outside the prefix accepted; a `'` left unescaped; one of the split functions' answers changed.

Run everything as `steve`.

**317. roc-markdown: the standard image syntax, `![alt](src)`: CC'S** (Steve, 2026-10-29: "I think supporting the standard syntax for images is a good idea, but we'll continue to have our chat insert img tags.") **showell/roc-markdown only**, after 316 and on top of it, on `claude/roc-markdown`. Finish as 316 does: roc-markdown's verify script passes, and its output goes in FEEDBACK. The box merges and re-freezes gold.

**Why:** today `![alt](src)` renders as `!` followed by a link. The playground's `safety` example shows it, and the chat's users, who know GitHub's markdown, will type it. The chat itself keeps inserting `<img>` tags for uploads, which MdMedia rebuilds. This adds the familiar syntax under **the same safety rule**.

**Build:**
- **Parsing:** CommonMark's image, `![alt](src "title")`, parsed where links are (MdLinks), with the same paren balancing and the same linear budget.
- **Where `src` is allowed** (`MdSafety.is_local_url`, the one rule `<img>` tags already follow):
  - **allowed:** `<img src alt title>`, built in `MdHtml`, its attributes MdSafety's allowlist, exactly what a rebuilt `<img>` tag gives for the same src and alt;
  - **refused** (another site, `javascript:`, anything `is_local_url` refuses): what the source would be with the `!` dropped (a link, subject to the link rules), or the text as written. Choose, say why in MdSafety's header, and freeze a case for each.
- **The alt text:** plain text from the label's inline content, as CommonMark specifies, escaped. No markup inside an `alt`.
- **The playground:** the `safety` example's last line, `![not an image](/markdown/sample.png)`, now shows an image. Change its caption, and add a refused one beside it, so both sides of the decision still show. Re-freeze `examples` and name it in the commit.

**Tests:**
- the CommonMark spec's image cases taken off the diverge list where they now match, with the ones the same-origin rule refuses on purpose listed as dialect;
- hostile shapes for `![` runs and nested brackets at the usual five sizes, held linear;
- **plants, each red:**
  - an image allowed from another origin;
  - markup kept inside an `alt`;
  - a `javascript:` src rendered.

**Gold** moves wherever a real message held `![`. The box re-freezes it and explains every move.

Run everything as `steve`.

**316. roc-markdown: GFM's strikethrough and CommonMark's backslash escapes: CC'S** (Steve, 2026-10-29: "Yes to strike/escapes".) **showell/roc-markdown only**, on `claude/roc-markdown` from `main`. Finish as 311 did: roc-markdown's verify script passes, and its whole output goes in FEEDBACK. The box merges, re-freezes gold, and explains every gold move (gold never leaves the box).

**Why:** roc-markdown's canned examples (judge/data/examples.jsonl, the `inline` example's caption) say it: "Unlike GitHub: no ~~strikethrough~~ and no backslash escapes". The chat's users are technical and know GitHub's and Zulip's markdown, and both have strikethrough.

**Read first:**
- the package as it now stands, after today's reorganization: README's Layout, `package/MdInline.roc` (the pass), `package/MdEmphasis.roc` (the delimiter engine), `package/MdHtml.roc` (every tag lives there), `package/MdSafety.roc`, `package/MdChat.roc`;
- a local agent is building the web playground on `box/playground` at the same time, touching roc-markdown's build.zig, its verify script and a new playground folder. Expect a small merge there; keep your verify changes to new lines and new counts.

**Build:**
1. **Strikethrough, as GFM's extension specifies it:** `~~text~~` (and `~text~`, if you follow GFM's tilde rules) to `<del>`, through the emphasis engine's delimiter runs. The tag goes in `MdHtml`.
   - The GFM spec's strikethrough examples become their own frozen corpus, like `spec_tables`.
   - New hostile shapes at 1, 10, 100, 1,000 and 8,191 (long `~` runs, mixed `~` and `*`), with their work units held linear.
2. **Backslash escapes, as CommonMark specifies them:** a backslash before an ASCII punctuation character makes it literal.
   - Inside code spans and fences, a backslash stays a backslash.
   - A backslash at a line's end is a hard break per CommonMark. But the chat already breaks every line, so say what you chose and why.
   - The CommonMark spec's backslash-escape cases should now match. Take them off the diverge list.
3. **The examples:** update the `inline` example's caption and source, and re-freeze `examples` (named in the commit).

**Gold will move** wherever a real message held `~~` or a backslash before punctuation. Say which corpora moved and why, case by case for the frozen ones.

**What roc-markdown's verify script checks:**
- raised counts;
- a linearity line per new hostile shape;
- **plants, each red:**
  - `~~` pairing across a line;
  - a backslash escape applied inside a code span;
  - a strikethrough answer's byte changed.

Run everything as `steve`.

**315. roc-chat: a minimal chat page, to read and post in a conversation in a browser: CC'S** (Steve, 2026-10-29: "yes".) **showell/roc-chat only.** Work on `claude/roc-chat`, from `main` at `b8d14ff`, which has step 6 (314) merged. Finish as 314 did: extend roc-chat's verify script, and put its whole output in FEEDBACK. The box merges, since your session refuses pushes to `main`.

**Why:** the milestone is a three-way conversation between Steve, CC and LC on https://chat.lynrummy.com, which is live with GitHub sign-in.
- **Already there:** step 6 gives JSON and SSE routes.
- **In progress at the box:** step 7, agent accounts and API keys on branch `box/keys`, which is how CC and LC will join.
- **Steve's part** needs a page: see his conversations, open one, read it live, post.
- **Out of scope:** the real chat client (chat-client, with its CONTRACT.md) is later work. This page is small, plain and replaceable.

**Build:**
- **A list of the viewer's conversations,** if step 6 has no such route: who is in each, and a link to it. It's decided by ConvAccess, like everything in step 6.
- **The page:**
  - one for the list, and one for a conversation;
  - the messages' HTML is step 6's, already rendered by roc-markdown;
  - new messages arrive live over the conversation's stream (`EventSource`, resuming with `Last-Event-ID`, as the browser does by itself);
  - a textarea posts markdown: Enter sends, Shift-Enter adds a line;
  - a form starts a conversation with participants by account id.
- **Keep it small:**
  - one Roc module for the pages (say Pages.roc, to be written), with their HTML built through roc-markdown's escaping or the app's own;
  - the JS inline in the page, or one small script;
  - a few lines of CSS, in the page.
  - No framework, and nothing from chat-client unless it fits as is.
- **Signed out:** the page sends the browser to `/login`, and back to the page after sign-in, if the sign-in flow can carry that without new risk. If it can't, say so; don't build it.
- **Never treat a message's HTML as anything but the renderer's output.** Any text the page itself writes (a name, an id) is escaped.
- **The route table** stays `app/main.roc`'s. Step 7, on `box/keys`, adds routes there too; keep your lines together so the merge is easy.

**Prove it:**
- **e2e steps, against the real server,** each in verify:
  - the list page shows a conversation the viewer is in, and not one they aren't;
  - the conversation page answers 200 to a participant, and 404 or 403 to a third user;
  - signed out, the page redirects to `/login`;
  - a message's HTML on the page is exactly step 6's for it.
- **Plants, each red:**
  - the list showing every conversation;
  - a participant's name written unescaped;
  - a third user getting the conversation page.

Run everything as `steve` (`as-steve`).

**314. roc-chat, step 6: the smallest end to end (sign in, post, read, stream): CC'S** (Steve, 2026-10-29: "queue step 6 for CC".) **showell/roc-chat only.** Work on `claude/roc-chat` and finish as 310 and 311 did: a committed verify script is the proof, and its whole output goes in FEEDBACK. Merge to `main` yourself if your session allows it; otherwise the box merges.

**Why:** roc-chat is the standalone Roc chat, a Zig host on std.http with every decision in Roc. Steps 1 to 5 of its host design are built. The design is the essay notes/roc-chat-host-design.md in showell/essay-repl-server; read section 4 for the build order.
- **Already built:**
  - the server and the turn;
  - the bus and SSE (platform/Sse.roc, `Chat.stream`, `Host.publish!`);
  - the files;
  - sign-in through the Roc (`app/SignIn.roc`, on the 16-module auth core).
- **Step 6** puts them together into the smallest real chat, and **replaces both stubs** (`/stub/*`, and `/stub/notes` with `/echo`, in `app/main.roc`, plus the host's stub log and its two hosted functions).

**Read first:**
- the essay notes/roc-chat-module-topology.md (same repo): where code goes now;
- roc-chat's README, `app/main.roc`, `app/Store.roc`, `app/SignIn.roc`, `app/ConvAccess.roc` and `app/Access.roc`;
- for prior art only, the frozen chat in showell/roc-webbox `chat/` (Transcript, Conversation, TopicStream, BusKey). It's frozen: copy ideas, never import it.

**Build:**
- **A conversation:**
  - **Start one:** a signed-in human starts a conversation with named participants, humans or agents by account id. ConvAccess makes it, and holds it to its rules (two humans alone are always private).
  - **Its record:** a new codec in Stored's line format, beside the others. Keep it as small as step 6 needs.
- **Post:** a participant posts markdown.
  - The message is rendered with roc-markdown (`Md.render`, refused as `TooMuchFormatting` when hostile).
  - It's appended to the conversation's transcript, then published to the conversation's bus key, so every open stream gets it once.
  - A non-participant's post is refused, decided by ConvAccess on the viewer from the session (`Access.Viewer`), never from anything the request claims.
- **Read:** the transcript, for anyone ConvAccess lets see it. JSON is fine. A full page isn't needed yet.
- **Stream:** the conversation's live messages, its backlog read in the same turn as the subscribe (`Chat.stream`). A reconnect with `Last-Event-ID` resumes from there.
- **The store:**
  - every new record and file lives in `app/Store.roc`, behind functions of the core's types; no handler names a path;
  - message bodies are arbitrary markdown, many lines, any bytes, so the transcript's format must round-trip any body exactly;
  - document the format in Store's header.
- **The routes:**
  - the route table stays `app/main.roc`'s alone;
  - the new routes' work lives in a module of their own (say Conversations.roc, to be written), as SignIn.roc's does;
  - choose the URLs, and list them in the README.
- **Delete the stubs** and their host side.

**What roc-chat's verify script, tools/verify.shale (to be written), checks:**
- **Tests:** `zig build test` passes. Print the Roc expect count and the Zig test count; neither may fall below today's (1,704 Roc expects, roc-markdown's included).
- **One end-to-end script, two clients, against the real server and the fake GitHub:**
  1. A and B sign in.
  2. A starts a conversation with B.
  3. B opens its stream.
  4. A posts.
  5. B's stream gets the message exactly once.
  6. A reads the transcript and sees it.
  7. B reconnects with `Last-Event-ID` and gets nothing twice.
- **Plants, each in a scratch copy, each required red for its own reason:**
  - a forged session cookie;
  - a third user posting to A and B's conversation;
  - a third user reading it;
  - the subscribe moved out of the turn (a message lost or doubled);
  - a transcript line with a newline in its body that doesn't round-trip.
- `zig fmt --check host build.zig` and `roc fmt --check app platform` are clean.
- **Times:** each step's, printed.

Run everything as `steve`, as CLOUD_WORK says (`as-steve`).

**312. lynrummy.com without the Cobblestone apps: CC'S** (Steve, 2026-10-29: "I eventually want to remove the cobblestone apps (UO server and chat) from our deployments. They have already been demoed.") **angry-gopher and zig-metal-unikernel**, on your `claude/` branches; the box gates it and ships it after v44.

**Why:** lynrummy.com mounts two cobble-webbox guests beside angry-gopher, Codex Chat at `/codex-chat/` and the UO town at `/uo/town/`, through webbox's `combo.Mount` in `zig-server/src/router.zig`. Both have been demoed, and they cost a sibling checkout, a lint, build flags and a README section.

- **angry-gopher:**
  - drop both mounts, so angry-gopher is a plain webbox app again with no combo;
  - drop cobble-webbox from `build.zig.zon` and the build;
  - drop `codex_chat` and `uo_town` from `tools/lint_portable.shale`'s trees and modules;
  - remove the README's "Mounted guests" section and every mention of `/codex-chat` and `/uo`;
  - any test that asked those routes now expects the router's plain 404.
- **zig-metal-unikernel:** gopher.elf no longer builds cobble-webbox's `src`. `git grep -il cobble` there lists the places: `build.zig`, `DEPLOY.md`, `README.md`, `tools/verdicts.py`, `tools/tier_lib.sh`, `long.sh`, and the probe and docs files. The verdicts stop keying on cobble-webbox's commit. Probes that ask `/codex-chat/` or `/uo/town/` stop asking.
- **Leave alone:** cobble-webbox itself, and the data on the volume (`codex-chat/` and `uo/` under the data and auth roots, which the box removes by hand later if Steve wants). Dog Park's `/todo` combo is a different deployment and stays.
- **Say in FEEDBACK** what the image loses in size and build time, measured.

Done when angry-gopher's `ops/check_zig` passes (`zig build consumers` in shale too) and zig-metal-unikernel's `zig build test` passes, with no `cobble` left in either repo's code (`git grep -il cobble` lists only history-free prose you can justify). The box runs the gates.

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
