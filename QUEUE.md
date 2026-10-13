# QUEUE

The one queue for the four repos (metal-vmm, gopher-metal, zig-coverage-sdk,
angry-gopher): what is open, and who has it. **Finished work, the answered
questions and every earlier item, by its number, are in
[`QUEUE-ARCHIVE.md`](QUEUE-ARCHIVE.md)**, verbatim, each batch under the
date it moved; new items continue from 156. The cloud session's
charter is [`CLOUD_WORK.md`](CLOUD_WORK.md).

## Context

metal-vmm runs gopher-metal's real kernel deterministically (both machines:
microvm-shaped and `TRANSPORT=pci`); the scenarios that cover what the site
meets go here, not to QEMU, which stays on the happy path (Steve). The goal
is zero bugs in the lower levels; class hunts find more than seeds; the
judge is becoming "did anything forbidden happen?", checked by `plants.sh`.
The snapshot (`docs/SNAPSHOT.md`) is parked.

## Now (2026-10-10, late night)

**2026-10-11, afternoon: 161 (Dog Park, one human) and the cookie fix merged; v25 passed; v26 (v25 plus the fix) gating; CC does 162 (webbox hardening), then 164 (Dog Park's fixed dogs, Steve), then 163 (Dog Park from its cold review).**

**2026-10-11, later: 160 (Dog Park's types) merged; CC does 161 (Dog Park for one human, end to end). The box is on webbox (angry-gopher's library), Phase A; v24 serves.**

**2026-10-11 01:10 UTC: CC does 159 overnight (serveOne, on its branch); v23 re-gating on gopher-metal `d72f4bc`.**

**v22 serves** (gopher-metal `bc459b3`, angry-gopher `51713cd6`). **On
master, not released:** B42 and batched frees (uploads and deletes a FAT
sector at a time), exact accounting of what a failure leaves (148, 152),
plants in the source (B39), virtio's fence and ring zeroing (150, 154),
153's send cuts (a send 38 disk requests to 9), idle time (a volume's check
in quiet moments), `/admin/search` (the baseline). v23 waits (Steve).
**CC:** the Who cell must-fix (FEEDBACK), then 155. The conversation
between the two Claudes is `FEEDBACK.md`; finished items are in the
archive.

## CC: open

**Your role (Steve, 2026-10-08): build what needs no emulator, and anything
adversarial.** Every item here runs on the host: `zig build test
-Dtest-file=<file>` runs one gopher-metal test file in seconds (the whole step
takes minutes); metal-vmm's `zig build test` and its `sweep_test.sh` need no
guest. Where a claim needs a real boot, write the recipe under Questions for
the box instead of guessing. Findings arrive as red tests where they can.

**106-111: status unmarked (2026-10-10).** CC: say in FEEDBACK which are
done (the box moves those to the archive) and which are still open.

106. **The simulators as a library, the soak as a program.** `fat_sim`,
    `store_sim` and `tcp_sim` reach for `std.testing.allocator` and
    `std.testing.io`, so the explorer bench and the soak must be zig tests,
    and `zig build` holds a test's output until it exits (the soak's log sat
    empty seven hours). Give each simulator's run an allocator and an `Io`
    as arguments, keep their tests as they are, make `explore_bench` and
    `explore_soak` ordinary executables, and `tools/soak.sh` run the
    installed binary as it does now. No behaviour changes: a seed's run is
    the run it was (`same.sh`-style: the same tape, the same hash).

107. **Kill fat16's surviving mutants** (your `MUTATION.md`: fat16's tests
    caught 8 of 16). For each survivor, the test that kills it, in
    `fat16_test.zig`; rerun those mutants and update `MUTATION.md`.

108. **Wrappers that still read failure as absence** (a cold review of your
    105, 2026-10-08; security first). The lint can't see a store read
    reached through a module's own function and then caught into a value:
    `users.findMemberByName` takes a stat error on a member's password file
    as "not a member", so a stranger's "Create account" with that member's
    name, while the read fails, makes a second account of the same name.
    `isMember`, `principalExists` and `currentUser.member` swallow errors the
    same way. Make each answer an error on anything but absence, with a red
    test; then look for others of the shape (a wrapper whose `catch` makes a
    value) and say how a lint could reach them.

109. **The lint's defence must say it is one** (same review). Any `//` line
    above a site passes today, including an older comment that defends
    nothing (`admin_lynrummy.zig:188`, `store.list(...) catch &.{}`, passes on
    "Total actions = nonempty lines…"), and `catch |e|` passes whatever its
    handler does. Require a marker (`// absent-ok: <why>`), convert the 17
    defended sites, and make a `catch |e|` that turns `e` into a value a
    finding too. Tests first, as before.

110. **A backup that cannot read a root fails** (Steve, 2026-10-08: louder is
    better). `admin_backup` now names in `backup-skipped.txt` a root it
    cannot stat (anything but "not there yet"), and still answers OK. Make
    that a failed backup (an error answer, no archive), with a red test;
    a file inside that cannot be read stays a named skip.

111. **Small ones from the same review**: `store_judge.zig`'s new `isFile`
    sits under `onModel`'s doc comment (move it); `reports.zig`'s `came`
    counts the CR/LF that `body` trims (make the two agree).

**Decided (Steve, 2026-10-08):** a corrupt or empty counter fails the
request and is left as it is (games traffic is small; safe over clever: no
recovery from the highest ID); an unreadable session secret failing every
returning visitor's request is right (louder is better). After 108, one account
whose password file can't be read makes every name login and "Create
account" answer 500: keep it (Steve, 2026-10-08: "keep the loud 500").



153. **Done but (7) (CC, 2026-10-10, FEEDBACK "153 and 154 done"; angry-gopher `825c4da`, `d95dec2`, `0f9c858`, `cdd4560`): (7) reverted until 155 is measured; (4) deferred.** **151's cuts, the ones Steve picked** (2026-10-10: 1, 2, 3, 7 of your
    report; 4 deferred past v23; not 5 or 6). Revised after a cold review of
    the queue. Each its own commit, measured before and after with `zig
    build store-cost`, red first where a test can show it:
    - **(1)** angry-gopher: **drop `.lastauthor`, its writes and its reads.**
      The boot pass (`backfillSidecars`) already copies it into `.count`'s
      uid, so no session needs it after one boot. Where `.count` is stale
      (`number > c.count` in `chat_store.zig`'s last-message path, and
      recent.zig's same branch), the author is unknown: answer `""`, never
      an older author (which could show "You" wrongly). The `.count` by
      `write`, not `replace`: safe because its size check catches a torn
      sidecar on either host; say so in its doc. `last-sessions/<conv>` and
      `last-conv` written only when they change: `setUserLastSession` reads
      the file (free while cached) and compares first.
    - **(2)** **drop last-seen** (Steve): both files, `users.touchUser`'s
      `users_root/<id>/last-seen` and player.zig's own, their writes, and
      their only readers, the admin rosters' "since" columns
      (`admin.zig`, `admin_lynrummy.zig`).
    - **(3)** angry-gopher: a login's `player.mirror` writes the name only
      when it changed.
    - **(7)** gopher-metal io.zig: a positional read that misses, of a file
      the cache can hold, reads it whole once and keeps it. **Measure after
      155**: its boot build reads every transcript whole and may warm the
      cache already, making this unneeded; build it only if Recent still
      reads from the disk then. A first Recent visit after boot reads up to
      the cap per transcript inside one handler: say what that costs.
    - **(4) deferred** (Steve, after the review): an overwrite whose freed
      and taken clusters share a FAT sector. ~12 ms a send, in the
      allocation path; after v23, if ever.
    angry-gopher's changes go through port.sh into gopher-metal's gates; say
    which angry-gopher commit each needs.
155. **Done (CC, 2026-10-10, FEEDBACK "155 done"; angry-gopher `8849000`, `2f28d90`, `c18dfaf`): probe/gopher.zig's boot step 4b is the box's.** **Search across every topic a person can see: the server side**
    (Steve, 2026-10-10; design in essay-repl-server
    `notes/a-key-value-store-for-gopher.md`, "Decisions since this draft";
    revised after a cold review of the queue). angry-gopher, host-testable.
    **The UI is later** (Steve): `chat_search.js` is untouched by 155.
    **Small scale**: four people, ~10 MB of chat. Prefer the simplest thing
    that answers from memory, and measure.
    - **(a) The tokenizer, the server's alone** (the client will be dumb).
      Words split on whitespace; ASCII lowercased; any byte >= 0x80 a word
      character, two bytes or more. **Edge punctuation trimmed**: ASCII
      punctuation, and the curly quotes and apostrophes phones type
      (U+2018-U+201D) and others like them (Steve: trim curlies and similar),
      named in one table. URLs, phone numbers and markdown links are
      refined later, not now. A pure Zig function with its own tests.
    - **(b) The index, in memory, derived from the transcripts.** Behaviour,
      not structure: words by prefix and messages by word, answered from
      memory with no disk read (hold the message text, ~10 MB, rather than
      offsets that cost a read each). Any structure: a per-conv map sorted
      at query time is fine at this size. Built at boot after `backfillAll`,
      one transcript at a time; updated by `appendMessage` as a message lands
      (docs.zig and login.zig append through it too). **After a retire
      applies, rebuild the whole index** (rare, and always right). No disk
      writes.
    - **(c) Agreement with the baseline, restated so it can hold:**
      `/admin/search` matches substrings ("lay" finds "player"), the index
      whole tokens. For seeded corpora and every key that is a token:
      index(viewer, k) = the messages of baseline(viewer, k) whose tokens
      include k. Corpora stay under the baseline's 500-hit cap and its
      too-large skip, or the comparison says how it treats them.
    - **(d) Two routes, each filtering by `chat_store.visibleConvs(viewer)`
      on every request**, never by a list kept from an earlier one: words by
      prefix (a count each, summed over visible convs only, at most 20
      words), and messages for a word (conv, sid, id, from, date, markdown;
      at most 500, every one counted). **Red test**: a word that appears only
      in another pair's DM is neither suggested nor found. A crude per-user
      rate limit (Steve): a few searches a second, which debounced typing
      never meets.
    - **(e) Measure, on the host:** CPU time and memory to build the index
      over a synthetic ~10 MB corpus. The box measures the disk cost on
      metal-vmm with production's request cost, and checks the watchdog's
      patience with a boot a few seconds longer.
    If boot gets annoying, say so in FEEDBACK before making it lazy: Steve's
    fallback is the first search or an idle window.

156. **The normalization hunt's app findings** (Steve, 2026-10-10: CC's;
    the triage is essay-repl-server `notes/the-normalization-hunt.md`,
    bucket A). Each a refusal, or a decision named and tested; red first;
    the smaller ones may batch. The box did A1 (the open redirect,
    `492d6766`) and A2 (the retire keep list, `827d96d5`); these are the rest,
    each a reviewer's claim until its red test shows it:
    - **(a) A new topic differing only in case merges into the old**
      (`chat.zig` topic creation, ~421): the duplicate check is
      case-sensitive, the store is not. Compare without case; 409.
    - **(b) A send that stored nothing answers success** (`chat.zig`
      ~363-369): a missing `markdown` field reads as "" and answers 204; the
      trim strips a first line's indentation (a code block becomes a
      paragraph); `DROP_ON_FLOOR` drops a real message (no one uses it:
      delete it). A missing field is 400; trim only to test emptiness.
    - **(c) The fan-out's `catch continue` skips more than it names**
      (`chat_store.zig` ~355-384): one surface's failure loses that member's
      other surfaces (images, code: durable, no rebuild). A block per
      surface, each failure said.
    - **(d) A channel file's lines are trusted as uids** (`chat_store.zig`
      ~855): a line `../../x` becomes a path the fan-out writes under; `3 #
      Claude` drops a member; a duplicate double-notifies. A line that is not
      a canonical uid, or a duplicate, makes the channel malformed, said.
    - **(e) Sign-up rewrites a name instead of refusing it** (`login.zig`
      ~102): `sanitizeUser` before `validateUserName`, so `Bob<x>` registers
      as `Bobx`. Validate what was sent; never sanitize.
    - **(f) Sessions:** one `issued` in the future never expires
      (`users.zig` ~126); a signed player cookie never expires server-side
      (`uid_cookie.zig` ~88). Refuse the future past a small skew; name the
      player cookie's lifetime.
    - **(g) Pins and bookmarks fail silently and answer 204**
      (`chat_state.zig` ~70, 130, 139); the login mirror swallows its write
      (`player.zig` ~114). Fail loudly (500), or name and test.
    - **(h) The transcript decoder never refuses** (`chat_store.zig` 61-104):
      a block with no `MSG_`, author or date decodes as a message of "".
      Refuse it (said, counted where it is skipped); name the blank-piece
      skip a torn append relies on.
    - **(i) Smaller:** a missing name file reads as "" for a member
      (`users.zig` ~233); two URL decoders disagree (`chat.zig` urlDecode vs
      player.zig formDecode; duplicates take the first); account ids not held
      to canonical form (`+7`, `007`); `ops/start` reports the old server ready
      when the port never frees; chat.js reads a bad backlog size as 0
      (`chat.js` ~253) and a failed save as nothing; an admin delete of an
      unknown id says nothing (`admin_lynrummy.zig` ~59); `metalShape`
      undercounts a path with an empty part (`store.zig` ~97, now refused on
      metal).
    - **(j) From the search UI's walkthrough:** a topic that does not exist is
      served as an empty one (`chat.zig` topicRoute ~299) and, for a DM,
      becomes where `/chat/default` resumes; a channel the viewer was removed
      from is a bare 404. Decide each (a 404 page that says why, no resume
      pointer to a topic that is not there).

157. **Protocols in prose, the app's** (Steve, 2026-10-10: CC's, after
    156; triage in essay-repl-server `notes/protocols-in-prose.md`). Each a
    sequence or a list that callers keep by hand becomes code that holds them
    to it (Steve: a protocol is code, not a comment). Red first where a test
    can show the drift. In order:
    - **(a) A kept stream must be served or dropped, and the host must
      remember** (verified): `server.zig` does `try routed;` before it looks
      at `bus.kept`, so a handler that keeps its stream and then fails leaves
      a subscriber in the Hub for ever. `route` answers the kept stream
      (`!?Kept`, which Zig makes the caller use) and drops it on its own error
      path; gopher-metal's `serveOne` follows (tell the box the signature in
      FEEDBACK). The handlers' `var kept = false; defer if (!kept) close`
      pairs become a handle `keep` consumes.
    - **(b) Every game write must ask `admit` first** (`game_limits.zig`), and
      nothing checks it; each caller recounts the bytes by hand ("as storage
      writes it"), and `appendSessionJSONLLine` writes `compactJSON(body)`
      where the caller counted `body`. One storage call per kind of write
      that builds the line, admits its exact length and writes it (or a token
      only `admit` returns, which the writers require).
    - **(c) Three fixtures copy the eight globals `roots.point` sets**
      (`roots.zig` Snapshot, `router.zig` UidSite, `chat_retire.zig` Saved),
      restored by index; tests reassign one root by hand and leave the others.
      A `pointForTest` returning a handle to `defer`, or the roots as one
      struct, saved and restored in one assignment.
    - **(d) Values the client copies from the server:** the upload caps and
      accepted types (`chat_compose.js`, "must match"); search's word edges
      and its 20-word cap (`chat_search.js`, the box's, already apart on
      Unicode spaces: the server could send each result's mark offsets);
      `ops/check_zig`'s list of built bundles beside `build.zig`'s. Hand them
      to the page as data, or check them as `check_caddy_limits.py` checks
      Caddy.
    - **(e) Smaller:** the chat page's widgets "MUST run first / AFTER"
      (`chat.js` ~326, 371: each `init` returns what the next needs); tests
      that put module globals back by hand (`mem_meter.replace`,
      `search_index.drop`, `game_limits.forgetAll`: a handle to `defer`);
      `chat_chrome.begin`/`end` pairs (a `page(...)` wrapper).

158. **Done (the box, 2026-10-10 night; angry-gopher `7dfa6dae`): http.serveEmbedded, every embedded asset.** **THE BOX'S, NOT CC'S (Steve: for v23; CC does 157).** **Browsers keep the embedded JS, revalidating each use** (Steve,
    2026-10-10). Today `chat.zig` `serveAsset` sends each
    JS file with no `Cache-Control` and no `ETag`, so every page load downloads
    every file again (`chat_responsive.js` is 5.6 KB). Each embedded asset gets
    an `ETag` hashed from its bytes at compile time, and `Cache-Control:
    no-cache` (keep it, but ask first); a request whose `If-None-Match` names
    the hash gets `304 Not Modified` with no body. Any change to a file is a
    new hash at the next build, so a browser has the new file on its next
    load: no version numbers in the script tags (Steve), nothing in Caddy
    (which passes both through). Red first: a GET with the ETag it was given
    answers 304, empty; one with another answers 200 and the bytes. The same
    for any other embedded asset the routes serve the same way.

159. **CC's, overnight (Steve, 2026-10-11 01:10 UTC): `serveOne` takes the kept
    stream from `route`, so gopher-metal builds against a port of 157.** Your
    patch in FEEDBACK (2026-10-11, night) is the start: `probe/gopher.zig`
    serves what `router.route` answers (`!?Kept`), where it read `bus.kept`.
    - **On your branch only, in gopher-metal and angry-gopher.** v23 is gating
      on the box from gopher-metal master `d72f4bc` (the uploads judge now
      sends the topic's first message: 156(j) made an upload to a topic not
      there a 404; merge master in) and angry-gopher master `7dfa6dae`. 157
      and 159 go to master after v23 ships, when the box merges them.
    - **Done when:** a port of your angry-gopher branch, with `serveOne`
      patched, passes gopher-metal's `zig build check` and `zig build test`;
      every other reader of `bus.kept` in gopher-metal follows too, or say
      there is none. A real boot (the gates) is the box's, at the merge.

160. **CC's (Steve, 2026-10-11): Dog Park's data TYPES, and nothing else
    yet.** A new repo, `github.com/showell/dog-park` (your branch as usual).
    **The brief is `docs/TYPES-BRIEF.md` there: read it whole.** In short:
    - correct by construction: enums, tagged unions and records over bools,
      nulls, voids and tuples;
    - names over comments;
    - **frames of reference by type** (the park, the viewport, relative to
      the human's dog; positions apart from displacements);
    - your own sub-agents as adversaries, their use cases kept as small unit
      tests;
    - **restraint:** no algorithms (no quadtree, no physics) and no glue (no
      routes, server, JSON or persistence). The box assembles the pieces
      from your types.

    Done when `zig build test` passes, the brief's checklist is drafted, and
    FEEDBACK lists the adversaries' attacks, what each changed, and your
    open questions.

161. **CC's (Steve, 2026-10-11): Dog Park for one human, end to end.**
    160 is merged to dog-park `main`, with the box's nits and a working
    dependency on webbox; **merge `main` into your branch first.**
    **The brief is dog-park's `docs/BUILD-BRIEF.md`: read it whole.** It
    holds the answers to your open questions, then seven milestones, each a
    commit with its tests and one adversary pass before the next:
    1. the index (a quadtree against your ListPopulation, seeded);
    2. placement (a spiral from the centre);
    3. the world over webbox's store and counter;
    4. the scene, a pure function;
    5. the application (Site(App): `/`, `/park.js`, `POST /scene`, the
       device cookie through `signed_cookie`, the secret created at first
       setup);
    6. the Linux main (`DOGPARK_*`) and `ops/smoke`;
    7. the browser in plain JS, structured by the same frame names, with a
       dumb blitter in the safari screensaver's spirit, written fresh.

    No SSE yet. Gates: `zig build test` and a seconds-long `ops/smoke`.

    **AMENDED (Steve, 2026-10-11): the park wraps around, Pac-Man style**
    (dog-park `docs/WRAP-AMENDMENT.md`, merged to `main`; read it first). It
    adds a frame, the plane the park tiles, where the viewport and drawn
    dogs live, and makes the type changes milestone 0, before the index.

162. **CC's (the box, 2026-10-11): webbox's hardening, from your 161
    list.** 161 is merged (dog-park `main` `3a7f135`), and so is the cookie
    fix (angry-gopher master `d8d347d4`; v26 is gating with it). Work on
    angry-gopher master in your branch; each part is its own commit, red
    first, and `ops/check_zig` passes at each.
    1. **A held-open body freezes every handler on the Linux host.** Read
       the body before `turn`, under a deadline and the existing body cap,
       so a stalled client holds only its own connection. The red test:
       a chunked head with nothing after it, or a Content-Length longer
       than what is sent, and another client's `GET /` must still be
       served promptly. The archive's "request door, stage 2" was the same
       idea; this is it, for Linux.
       **Then gopher-metal:** say, citing the code, whether the kernel
       reads the body before its turn. If no test pins it, add the
       cheapest one that does (a unit test in gopher-metal, or a
       metal-vmm scenario), red first if it is broken.
    2. **The `Secure` attribute** on every cookie webbox issues
       (signed_cookie, and angry-gopher's own cookies through it). Behind
       Caddy the app sees plain http, and that's fine; the attribute is
       for the browser. Say what happens on `localhost` during
       development.
    3. **`site_secret.create` is atomic:** two processes starting at once
       make one secret, and the loser gets `error.SecretExists`. Do it
       with an exclusive create or a link that doesn't replace, not a
       check followed by a write.
    4. **Two cookies of the same name.** Today the first wins, and
       Dog Park shares lynrummy.com's domain: a cookie set for the parent
       domain arrives beside the subdomain's own. Decide the rule (my
       lean: the one that verifies wins, and two that both verify, or
       none, read as `invalid`), as a type rather than a comment, with a
       test per case.

    Not in this item: the park filling up (Steve decides), and the id
    burned on a disk failure (fine as it is: ids are unique, not dense).
    Done when each part is a commit on your branch and FEEDBACK says what
    you decided.

163. **CC's (the box, 2026-10-11): Dog Park, from a cold review of 161.**
    After 162, or beside it. Dog-park `main` is at `0259c44`: the box fixed
    the trivial findings (a drag capped at `longest_drag` per request, a
    request that gives up after 5 s, `farthest_origin_past_park` named apart
    from `widest_viewport`, the wire's header, the second dog's spot).
    Each part below is a commit, red first where there is a test to write:
    1. **The ask loop is a state machine, by name.** Today it is spread
       over `asking`, `wantScene` and a nullable `noRoom`. Its gap: after
       `no_room`, a 4xx or a failure, `nearCoveredEdge()` is true with no
       scene, and the page asks every 80 ms forever. On a full park, each
       waiting tab runs the whole spiral 12.5 times a second. Make the
       states one value (e.g. idle, asking, backing off until a time,
       no room), with backoff after a refusal or a failure.
    2. **The blitter gets a kind, not two flags.** `own` and `faint` allow
       `own && faint`. Use one `kind` (own, other, lattice spot), or a style
       chosen before `blit`.
    3. **`world.Refused` says what it names by type:** a dog record (its
       name) or the counter. The startup message's path then comes from the
       world, not from the glue branching on `why`.
    4. **The browser's frames and `take()` get a check:** a small node
       script (no packages) for `nearestCopy`, `homeShift` (ties go east or
       south, floored modulo, as park.zig has it) and `take`'s
       reconciliation, run from `ops/smoke`. Keep it seconds.
    5. **A restored `data/` with the old secret hands out live ids.**
       Restore or wipe `data/` but keep the auth folder, and a cookie issued
       after the backup names an id at or above the restored counter, so a
       new device gets an id that someone else's cookie also carries. Tie a
       cookie to its data. My lean: a generation made once with the data
       (beside `next-human`) and signed into the cookie's label, so a
       cookie from another generation reads as a new device. Say what you
       choose.

    **Part 5 moves into 164**, and so does the park filling up: Steve
    chose a fixed number of dogs, claimed (dog-park `docs/FIXED-DOGS.md`).

164. **CC's (Steve, 2026-10-11): the dogs are fixed, and a human claims
    one.** The brief is dog-park's `docs/FIXED-DOGS.md` (on `main`): read it
    whole. In short: a fixed number of dogs, made once with the data and
    never created or destroyed; a new human claims the unclaimed dog
    nearest the centre; when all are claimed, the least recently touched
    dog changes hands; one dog per device. It replaces placement and the
    "park full" refusal, and takes in 163's part 5.
    **Order: 162, then 164, then the rest of 163** (its parts 1 to 4 sit on
    top of 164).

165. **CC's (the box, 2026-10-11, corrected): the coverage scan warns and
    passes.** zig-coverage-sdk's `tools/scan.zig` logs a warning and skips a
    site whose message is not a string literal: gopher-metal's `machine.zig`
    :150 and :153 (messages computed at comptime). `zig build test` still
    exits 0, but prints the warning under a "failed command:" line, which
    the box and two hunters each misread as a flaky failure today. (The
    box's first version of this item said the step fails; a rerun showed it
    doesn't.)
    - **Fail, never warn:** a site the scan can't catalog either becomes
      catalogable (e.g. a comptime message the scan can resolve, or the
      machine's edges cataloged another way), or the scan refuses it with a
      named error. A passing build prints nothing that looks like a failure.
    - Done when a build after touching `machine.zig` is silent, and the
      machine's edges are in the catalog or their absence is a decision
      written next to them.

166. **CC's (the box, 2026-10-11): the kernel holds the turn for a slow
    body (from your 162 report).** On v26 (serving), a chunked body, an
    `Expect: 100-continue` body, or one bigger than the connection's buffer
    is read inside the turn, each read bounded by `idle_ns` from its own
    start. One client sending a byte every 9 s holds every other request
    on lynrummy.com indefinitely.
    - **The bar:** no client holds the turn past a bounded time for its
      whole body, and a body that fits the connection's buffer never holds
      it at all. Your two ideas are the start: the host answers
      100-continue and then waits as for any body that fits, and a body read
      in the turn gets one deadline for the whole body, not one per read.
      Weigh a chunked body that fits too (read before the turn, as
      Content-Length ones are). For an upload bigger than the buffer, say
      what the deadline is and how it is sized (a floor on bytes a second
      over the cap, say), and what a slow uploader still costs others.
    - **Red first** where the gates allow: a metal-vmm scenario (a peer
      trickling a chunked body while another asks `GET /`) is the right
      home; QEMU stays on the happy path. Say if a red test can't land
      without failing the gates, and land it with its fix.
    - Done when `zig build test`, `zig build check` and the metal-vmm
      scenario pass, and FEEDBACK says the deadline and what it costs.

167. **CC's (the box, 2026-10-11): 162 back, from its cold review; do it
    with 166, one design for both hosts.** 162 isn't merged (nor dog-park's
    164/163, which need its `largest_body`). Prod is metal, so nothing
    serving is exposed meanwhile. The findings, verified where marked:
    1. **(verified) `readBodyBeforeTurn` can return with its Select's task
       still running** (linux_host.zig ~:251). If the read has already set
       `whole.state` when it's checked, neither `await` nor `cancelDiscard`
       runs, and the task's completion writes into `race` on a dead stack
       frame. The `== .reading` check itself is an unsynchronised read of a
       union the other thread writes. Always await, then `cancelDiscard`,
       then read the state, red first if a test can make it bite (a body
       already in the buffer and an idle pool).
    2. **One cap for every body is the upload's (~101 MiB).** Any POST to
       any path now buffers that much before the turn, per connection and
       in parallel (and `allocRemaining` doubles it, then the handler's copy
       adds one more). Before, only the upload route read that much, after
       its uid check, inside the turn. **The cap belongs to the route:** the
       application says, from the head, how large a body that route takes
       (most routes are KiB). Large bodies (uploads) need their own answer.
    3. **10 s for the whole body breaks real uploads** (40 MB over a
       20 Mbit/s link is 16 s). A deadline sized from the length, with a
       floor on bytes a second, is one answer.
    4. **No deadline at all, silently,** when the timer or the read can't
       be spawned (`catch {}`, the inline fallback, even on the accept
       loop). Fail, never warn: a 503, not a read without a deadline.
    5. **A planted cookie denies login:** with "two that verify name no
       one", a sibling subdomain can set its own valid `gopher_auth` for
       `Domain=lynrummy.com` with a year's life, and the victim can't clear
       it (our clear has no Domain). Still better than first-wins (login
       fixation), and now `Secure` is set the cure is cheap: the
       `__Host-` prefix on every signed cookie (browsers refuse one with a
       Domain), with a migration read of the old names.
    6. `Secure` and the Caddyfile's plain-http `:80` testing note disagree:
       update the note. (Secure stays.)
    7. A head with both Content-Length and `Transfer-Encoding: chunked` is
       a 400 (RFC 9112 §6.1), not a 413 from the CL.

    **One design, two hosts:** 166's kernel and this Linux host should
    take the same rule (bodies that fit a route's small cap arrive before
    the turn; a large body's deadline is sized from its length), said once
    where both read it. Write the rule down first in FEEDBACK, briefly,
    then build it. Then dog-park's branch on top.

168. **CC's (Steve, 2026-10-11): Dog Park's claims, v1.** After 166 and 167,
    on dog-park's branch with your 164/163 work. The brief is dog-park's
    `docs/CLAIMS-V1.md` (on `main`): read it whole. In short:
    - human ids are 128 random bits, with no counter;
    - a new human's claim is provisional until the dog is dragged, and
      expires at 120 s;
    - a held claim never expires in v1, so the stalest takeover and
      `touched` go;
    - when no dog is free the human gets none, and the page is read-only
      (pan by dragging the background).

    **166, 167 and 168 are one run of work:** wake once, do them in order,
    report once.
    **After 168, no more Dog Park work for CC until Steve says otherwise**
    (Steve, 2026-10-11): he is testing it now, and the box takes Dog Park
    from here.

169. **CC's (Steve, 2026-10-11): 166's rule redone: THE TURN NEVER WAITS ON
    THE NETWORK.** 166/167 aren't merged. Their in-turn read (`2 s + bytes /
    1 MiB/s`) fails real uploads: prod today, a 1.8 MB photo from India
    arrived at ~65 KB/s in 27.7 s (0.18 s of it disk), and a retry waited 7 s
    for the turn behind it. Under 166 it would be a 408 every time, and no
    floor is both kind to that link and short enough to hold everyone behind
    it.
    - **An upload is read whole into memory BEFORE the turn,** under one
      patient deadline: 5 minutes (the page now waits that long, angry-gopher
      `fd2c7ab5`). It then takes the turn like any request; its save is
      milliseconds.
    - **Three upload slots per host, at most one per human.** A fourth
      uploader (or a second from the same human) waits on its own
      connection, holding no one else; say what it is told if it waits
      too long.
    - **Who is asking is checked before a slot is given:** the upload's
      sign-in moves before the body is read (the cookie's check is pure,
      the secret is in memory). A stranger never holds a slot.
    - **Memory:** at most 3 x the upload cap (~303 MiB); metal has 997 MB
      and peaks ~170 MB today. Say the number on both hosts.
    - **The rest of 166 stays:** small bodies before the turn under their
      deadlines, the route's cap, `100-continue`, chunked, and the head's
      whole deadline. The in-turn branch and `floor` go: nothing is read in
      the turn.
    - **167 rebased onto it** (the race fix, the 503, `__Host-` cookies,
      CL with chunked a 400, the Caddyfile note).
    - **Not in this item:** the Linux turn held by a client that never
      reads its answer. Same principle (answer into memory, send after the
      turn), but later.
    - **The request log says each upload's body size and how long it took
      to arrive**, so a slow link is read, not inferred (today's "1.8 MB"
      was inferred from the request heap).
    - Red first: a metal-vmm scenario where a slow uploader (at 64 KB/s) and
      another client's `GET /` overlap, and the `GET` is answered at once.
      The box runs `timeouts.sh` (you have no KVM).

170. **CC's (the box, 2026-10-11): 169 after its two cold reviews.**
    **Also, from v27's long run:** `zig build properties` (long.sh's
    simulators) didn't compile after 166 (`ready_sim` imports `body_rule`,
    which only the unit tests were handed); fixed on gopher-metal master
    `ea91fa4`. Your checks never build that step: add `zig build properties
    -Dseeds=20 -Dfat-seeds=2` to what you run, which compiles it (its verdict
    at that size is meaningless; long.sh's 10,000 seeds are the judge). 169 is
    merged and goes out in v27 with one fix, made by the box: a chunk size
    near u64's end overflowed `after + 2` in `ChunkedScan.end`, a panic of
    the served kernel from any client (red-first test in body.zig). The
    rest, one run, red first where a test can bite:
    1. **The dropped phone (both hosts):** a phone that loses its network
       mid-upload sends no FIN or RST, so its slot is held for the full 5
       minutes, and the same human's retry waits 30 s, then gets "busy".
       That's Apoorva's case. A human's new upload should take over their
       own stalled one (the old connection closed), or a slot should free
       after a stretch with no bytes. Say which, and why.
    2. **Kernel: body drains stop during a turn, but their deadlines run on**
       (`streamTurn` moves streams and response drains, not body drains). A
       turn longer than ~10 s (a 100 MiB upload written to disk) makes an
       honest small body a 408. Drain during turns too, or stop the clock
       while a turn holds the loop.
    3. **Kernel: strangers can fill the 64 MiB small-body budget** (~64
       silent `POST /chat/x/docs` with a 1 MiB Content-Length, renewable
       every 26 s). Charge as bytes arrive, or give a stranger the small
       form's cap, or a per-peer share. Linux has no total bound at all
       for small bodies (the Linux review's #2): the same rule there.
    4. **Kernel: an upload with an `Expect` other than 100-continue** is
       drained whole, then fails in std. Refuse it from the head.
    5. **Linux: an upload is in memory twice** (the host's read, then the
       handler's `readLimitedBody` copy), so 3 slots are ~404 MiB plus
       arena slack, not ~303. Hand the handler the bytes already read.
    6. **Linux: an error before the turn closes with no answer** (an I/O
       error in the uploader check): a 500 or 503, as in the turn.
    7. **Linux: a read that ended too large or unreadable as the timer
       fired** is told 408; it should be its own refusal.
    8. **The `__Host-` names were reverted out of v27** (angry-gopher, after
       7ef17a13): gopher-metal's judges and droplet tools read and send
       cookies by name (`probe/judge_gopher.py`, `droplet/rotate_secret.py`,
       `cutover_drill.py`, `compare_hosts.py`, `load.py`, `fuzz_requests.py`)
       and v27's gates failed six ways on it. Bring the rename back whole:
       the judges and tools moved to the new names in the same change, and
       the migration below finished. **The migration was unfinished:** a session from before the
       deploy keeps its legacy `gopher_auth` for up to a year and is never
       moved, so it stays plantable. A planted legacy cookie can sign a
       signed-out victim in as the planter, and a planted legacy
       `gopher_uid` is promoted to `__Host-`. Move the session on its next
       verified request too, and set an end date for reading legacy names.
       In dev over plain http, a legacy `gopher_uid` loops 303s forever:
       stop that.

171. **CC's (Steve, 2026-10-11): the kernel's body drains as pure
    functions, tested directly.** Your 170 note: `stepDrain`, `pauseClocks`,
    the takeover and the slot waits live in `probe/gopher.zig`'s loop state
    and only `timeouts.sh` judges them. Pull the decisions into a module of
    pure functions over the bytes seen, the clock and the slots (what to do
    next: wait, read more, take a slot, hand over, refuse with which status),
    the loop keeping only the I/O. Then:
    - **unit tests at every edge**, both sides of each boundary in one test
      (Steve's rule from the off-by-one hunt): a deadline at its last ms and
      the next, a body exactly the cap and one past, a stall at 29,999 and
      30,000 ms, a takeover with and without a slot free, a budget charged to
      exactly 64 MiB and one byte more, a chunk ending at the buffer's edge;
    - **a seeded simulator** if the shape invites it (the decisions against
      a model of slots and budget over random arrivals), on the pattern of
      `ready_sim`;
    - `timeouts.sh` unchanged and still the end-to-end judge (the box runs
      it).

    One long run: the seam, the tests, the simulator, an adversary pass.
    Note: Phase B (the box's) is reshaping how the kernel imports the
    application (`app` and `webbox` modules, `host_io`); keep this to
    `probe/gopher.zig`'s loop and a new `src/` module, and the box will
    rebase.

**After 171, in order (Steve, 2026-10-11: cleanup and quality for
angry-gopher and gopher-metal; no Dog Park).** Each is one long run, on your
branch, cold-reviewed by your own adversary before you report. Phase B (the
box's) is reshaping how the kernel takes the application (imports, `host_io`,
the build, the port); stay off those, and merge master in as it lands.

175. **The box's (2026-10-12): 170's two cold reviews, the kernel half. Do
    it with 171 (same code), or right after it, before 172.** 170 is merged
    (angry-gopher `c70f7b86`, the plant cutoff moved to 2026-10-14;
    gopher-metal `7b2de2b`); `timeouts.sh` passes on it. Each fix red first,
    on 171's pure functions where it can be:
    1. **MEDIUM: `pauseClocks` makes every body clock "time the loop was
       idle".** Every turn moves every drain's deadline, stall clock,
       `head_at` and `slot_wait_since` on by the whole turn, uncapped. With
       turns back to back (one busy client), a dropped phone's stall takes
       hours: its slot and its ~101 MiB stay pinned, others get 503, and
       silent small heads pile up in the table instead of a 408. Bound the
       credit: e.g. a stall clock is credited only when the drain had bytes
       waiting it could not take (bytes that arrived in the turn reset
       `last_progress` at the next `stepDrain` anyway), and a wait's total
       credit is capped at its own deadline. Show a busy loop still lets a
       silent upload go within its stall plus the cap.
    2. **MEDIUM: a full small-body budget is a 408 at the deadline, not
       503.** `beginDrain` → `.wait` runs to `late` (`body_too_slow`), and a
       refused `growDrain` takes no byte and also 408s; partially grown
       drains can starve each other until their deadlines. body.zig's
       `small_budget` says 503 and Linux answers `.busy` at once. Answer 503
       when the charge fails, at begin and at growth (or grant a begun drain
       its whole `most` once past its first 64 KiB), the same as Linux.
    3. **LOW: the memory bound is not exact.** `headOnly` charges no budget
       (256 heads); `growDrain`'s realloc holds both buffers before the
       charge. Say the real bound in the doc, or charge them. And
       `small_drain_budget` (gopher.zig) must BE body.zig's `small_budget`,
       not a second constant that agrees.
    4. **LOW, both hosts: `Expect` on a request with no body.** `plan`
       refuses only when there is a body; `GET / Expect: tea` (or
       `100-Continue`, any case) reaches std's `writeExpectContinue`, which
       errors, and the client gets no answer at all. Refuse 417 from the
       head whatever the body.

176. **The box's (2026-10-12): 170's cold reviews, the Linux and cookie
    half. After 175, before 172.**
    1. **MEDIUM: the tests go red on 2026-11-15 with no change.**
       `cookieOrLegacy` and `uid_cookie.reissue` read the real clock, so
       router.zig's migration tests (~2131, ~2154) and the unsigned-uid
       303 tests (~669, ~741 and kin) fail that day. Give the router's
       clock a seam the tests set. Separately, a single test that FAILS on
       and after the end date with "the legacy names have ended: delete the
       migration, its tests, and the judges' legacy steps" is welcome:
       a dated failure that says what to do, not a dozen that don't.
    2. **The judges' dated blind spot** (gopher-metal `probe/judge_gopher.py`):
       `P1 = "gopher_uid=1"` (cases ~84, ~96) and `UID_STORY`'s legacy steps
       (~272-286) quietly become anonymous after 11-15, and the "is no one"
       checks (~3206) pass testing nothing. Same dated failure, in
       test_judges.py. And the `set_uid`/`cookie_from` regexes see only the
       `__Host-` name: a host that set a legacy-named identity would pass the
       negative checks. Match both names and refuse the legacy one.
    3. **LOW-MEDIUM: a kept stream holds its small-body charge while it is
       open.** `unchargeSmall` is deferred to `handleConn`'s return, after
       `bus.serveKept`; the SSE routes don't check the method, so ~64
       member POSTs of 1 MiB to `/chat/notifications` pin the budget and
       every POST on the host is 503 until they leave. Refund when the route
       returns, and refuse non-GET on the stream routes (both hosts).
    4. **LOW: an internal failure in the read is a 400.** `Whole.read` maps
       every error, OOM included, to `.unreadable`: blame the server (500),
       as 170.6 says.
    5. **LOW: the budget counts bytes, not memory.** `readAll`'s
       `appendSlice` grows geometrically inside an arena (2-3x the charge),
       and the refund runs before `arena.deinit`. Grow as the note says
       (4 KiB steps, or exact), or charge capacity.
    6. **LOW: two waiting retries can make the older win** (C takes the
       slot, B's next poll ends it with 409). Newest wins, by a sequence
       number per human.
    7. **LOW: a stall is "no 4 KiB in 30 s"** (`readSliceShort` fills the
       buffer). Count bytes as they arrive (`readSliceShort` into what's
       available, or a smaller read), so a 100 B/s link is slow, not dead.
    8. **Tests that don't test what they say:** the migration test titled
       "a POST is still read" sends no POST; no route-level test that a
       legacy session or uid issued after the cutoff is neither read nor
       moved; the budget test is one 9-byte read against 8 (nothing for
       charge-as-it-arrives, or the refund after 408/409/error); the 500
       test fails before any slot or charge exists; nothing at host level
       shows `held_body` reaching the handler uncopied; nothing for 170.7's
       separate verdicts; the takeover test never runs the stall timer.
    9. Accepted, say so in the cookie doc: a sibling subdomain can still
       plant a PRE-cutoff legacy value on a victim with no `__Host-` cookie
       yet, and it is moved. The cutoff narrows it; the end date ends it.
    Note: the session cookie is `__Host-gopher_auth` (my brief said
    `_session`; the code is right).

177. **The box's (2026-10-12): 171/175/176/172's cold reviews. After 172's
    rest, before 173.** Your work to `4c2ea322` / `420616c` is merged onto
    Phase B (angry-gopher master `9f37827d`, gopher-metal `49b5a2e`) and goes
    out in v28. **Merge master into your branch before you go on:** Phase B
    moved the application behind modules: a host reaches `app.site.*`,
    `app.hosting.*` and `webbox.*`, never the router; an application file
    imports a library file by name (`@import("webbox").bus`), never by path
    (the lints say so); test locals named `site` shadow the router's export
    (use `uid_site`). The box fixed in the merge: linux_host's `sse.zig`,
    presence's `bus.zig` and router's `mem_meter.zig` by path; the kernel's
    start report back through `describeStart` (the merge had taken 171's
    `started.app.backfilled`); and a release that releases nothing is still
    a logout (its 403 now clears the cookies; 172 had dropped that).
    The rest, red first:
    1. **MEDIUM: a stored message whose live publish fails still ends in a
       resend.** The 204 comes, no SSE echo, `hostDown` after 3 s, the user
       resends: a duplicate. Build the publish's key and blob before
       `store.append`, so nothing can fail between the append and the
       (void) publish. The no-JS `sendDone` path still `allocPrint`s after
       the store (500 for a stored message): same.
    2. **176.5's "the charge is the memory" is false** under std 0.16's
       arena: resize/free work only on the newest allocation in a node, so
       an outgrown list leaves its old copy (1.5-4.5x the charge). Read into
       one allocation of the body's length when it is known, or charge what
       the arena holds; fix the comment either way.
    3. **An error before a streamed answer's first byte sends two status
       lines** (`chat_upload.streamFile`'s first `readAt`, `admin_backup`'s
       `archive`): `respondStreaming` buffers the head, `Sent.any` is false,
       `answerFailure` appends a 500. Either flush-or-discard the buffered
       head before a failure answer, or close with nothing more.
    4. **Expect: 100-continue on a bodiless request is now 417** (175.4);
       std answered an exact `100-continue` GET before. Refuse only what std
       can't answer (not exactly `100-continue`), serve the rest.
    5. **drain_sim excuses too much:** every 503 in tight-budget seeds (a
       slot wait's early 503 included: excuse only the budget's); "everything
       ends" in free time, so 175.1's wall-clock bound (a deadline plus at
       most its own length) is never judged there; assert `charged <=
       budget` directly (175.3's claim). And drain.zig's "1 MiB past the
       budget" understates a chunked drain's last growth (~16h + 1 MiB).
    6. LOW: an SSE frame lost to OOM on a live-only `sse.forward` stream is
       gone (no backlog); presence's `unmark` on a lasting read failure
       shows an active user offline and re-reads the user list per request;
       `ConversationTooBig` counts each later topic and `noteAppend` drops
       the index per message; `methodNotAllowed` sends no `Allow` header.

178. **The box's (Steve, 2026-10-12): bigger disk requests, so a big upload's
    turn is short on prod. After 177, before 173.** Measured on v28
    (gopher-metal `probe/bench_upload.py`, the droplet machine, chat's data
    on its SCSI volume): an upload arrives off the turn at ~60 MB/s and
    holds nobody up, but its WRITE is in the turn, at most 64 KiB a request
    (`virtio.Block.max_sectors = 128`, `disk_fat.zig`'s `max_run`): 93
    requests for 1.8 MB, 218 for 10 MB, 2,017 for 100 MB. Prod's volume is
    network storage with its write cache off, ~2 ms a request (Apoorva's 1.8
    MB: 93 requests, 0.18 s), so a 100 MB screencast freezes the site for
    ~4-8 s; photos are now shrunk to ~1 MB in the browser, so it is the
    screencasts that matter.
    - **A run of contiguous clusters goes as one request of up to 1 MiB**
      (or what the device allows: virtio-scsi's `max_sectors` and
      `seg_max` from its config, virtio-blk's `size_max`/`seg_max` when
      offered; a device that says less is obeyed, and its number is in the
      host facts). Reads of long runs the same, if they share the path.
    - The request size is a decision with edges: a run exactly the most, and
      one cluster more; a run that ends at the volume's end; a device whose
      limit is smaller than a cluster (refuse at mount, never split a
      cluster); red first, both sides in one test.
    - Durability unchanged: the same write order, the same barriers (the FAT
      after the data, `flush` where it is now); fat_sim / floor_sim /
      store_sim judge it, and the fault sweeps must still read a cut-short
      big write as it does a small one.
    - **The number to show:** the box reruns `bench_upload.py` (yours to
      leave runnable, no KVM there): the 100 MB upload's disk requests should
      fall from 2,017 to ~100-150. Say what you expect.

179. **The box's (Steve, 2026-10-13): the FAT written as runs, each sector
    once, so a 100 MB upload is ~100 disk requests.** Your 178 proposal, as
    you put it: an allocation writes its changed FAT sectors as runs, one
    request per copy, after the data and before the entry commit, and each
    sector once (not once when its clusters are taken and again when the
    chain is linked).
    - Red first, both sides of each edge in one test: a run of FAT sectors
      exactly the most and one more; changed sectors with a gap (two runs);
      a chain whose last link lands in the next sector; one copy's write
      failing and the other's not.
    - `allocChainHeld`'s verdicts and the ledger on a failed write move with
      it; the stop and lie sweeps (fat_sim, floor_sim, store_sim, metal-vmm
      `sweep.sh` via the box) must read a cut-short FAT run as they read a
      cut-short sector today. Say which properties moved, and why.
    - Say the count you expect from `probe/bench_upload.py` for the 100 MB
      upload; the box runs it on your branch.
    - Your two questions, answered: the idle check's TooBig stays as it is
      (counted, not a panic); no allocation-free `Kept` frame mode for now
      (a live-only stream loses frames over any reconnect by design).

181. **The box's (2026-10-13): 179's cold review. 179 is NOT merged: it
    loses a file a lie used to cost nothing. Fix this first, before 180.**
    The runs are right on every truthful path (FAT, then data, then entry;
    built right across sector edges, gaps and the limit; nothing interleaves;
    the ledger tells the disk). The regression, CONFIRMED by an experiment on
    both commits (a 20 MB file on `small32`):
    1. **One lying write to copy 0's FAT run** (`lands_nothing` or `torn`)
       now puts 161-321 sectors apart, past `max_weighed_sectors` (64,
       `disk_fat_fat.zig:136-143`): the mount takes `past_weighing`, trusts
       copy 0 and writes it over the good copy 1 ("repaired 321"); the file
       reads `BadChain`, the next 4 MB write is `crossed`/`short`. On 178 the
       same lie left the file whole (each FAT sector was written twice, and a
       lost one was 1 sector apart, weighed, copy 1 kept). Close it so a lie
       to one copy costs at most what it cost on 178: e.g. weigh copies that
       differ in contiguous runs however many sectors (what makes a copy
       "cleaner" holds per run), or read a big FAT run back before the
       second copy is written, or write copy 1 first for the run and copy 0
       after (say which, and why it holds for a torn write too).
    2. **A cut inside a big copy-0 run leaks what landed** (20,477 clusters,
       no damage): the same weighing cap trusts copy 0. The fix for 1 should
       let the mount keep the untouched copy here too.
    3. **The sweeps never reach these:** fat_sim's stops fail whole requests
       and it tells no lies; the lie sweep skips write lies on FAT32 and its
       runs are far under 64 sectors. Add a fault that tears a request part
       way (some of its sectors land), and write lies on FAT32 at upload
       sizes (> 64 FAT sectors a run), red on 70fc623 first.
    4. LOW: `giveBack` after a `.landed` failure frees a whole-chain segment
       one cluster at a time (two requests each: ~51,000 for 100 MB at 4 KiB
       clusters, the kernel stalled); give back as runs too.
    5. Note only: a lost chain can now link into a free cluster that the next
       write takes (fsck.fat reclaims only the lost part; harmless, the check
       counts leaks by marks); and "a volume full part-way gives back what it
       took" now also fires when nothing was written: if the floor should
       tell those apart, split the message.

190. **The box's (Steve, 2026-10-13): READ-ONLY reports for the renames.
    Commit nothing to gopher-metal, angry-gopher or dog-park: the box is
    about to extract `zig-webbox` from angry-gopher and rename gopher-metal
    to `zig-metal-unikernel` (plan: essay `notes/renaming-plan.md`, on the
    box's essay server; its text is summarised here). Write each report as
    a FEEDBACK entry, nothing else.** 189 is merged on master in all three
    repos; its first QEMU run (the gates) is under way on the box.
    1. **The rename census.** Every occurrence of `gopher-metal` (and
       `gopher_metal`, `GOPHER_METAL`) in gopher-metal, metal-vmm,
       angry-gopher, dog-park and zig-coverage-sdk, classified: LIVE (a
       script, a path, build code, a string a person or a judge reads, a
       README or current doc) versus HISTORY (a dated QUEUE/FEEDBACK entry,
       an archive, a review note, a design note describing the past). For
       each LIVE one: file:line, what it is, and what it should become.
       Call out the dangerous ones: strings a judge requires (the loader's
       banner), names on a disk image (`gopher-metal.conf`), paths that
       scripts compute, the verdict and build directories.
    2. **The library's edge.** The box finds 24 files of angry-gopher's
       `zig-server/src` reachable from `webbox.zig`, `webbox_linux.zig` and
       `host_io_std.zig`, none importing outside them, and the app
       importing them only as `@import("webbox")`. Check that, and list
       every other coupling a move to its own repo would break: build.zig
       steps or tests that name those files, `ops/` scripts, tools that
       read `zig-server/src` (gopher-metal's build.zig, tools/verdicts.py,
       droplet/chat.py, metal-vmm's check-cc.sh and plants.sh, the
       coverage SDK), the lint and the limits check that read the source,
       anything else. Say what each needs.
    3. **189 seen cold.** A fresh adversary pass (your subagent, not you)
       over 189's code, as you did for 187: the log ring's move into the
       kept region, `/admin/log`'s filters at their edges, the redaction of
       the new lines, the counts and the uploads table. Findings with
       scenarios; red tests named but NOT committed (the code is frozen
       until the renames are done; the box will land fixes after).
    4. **gopher-metal's README status table against v29:** each row that
       is stale ("on master, not served" for what v29 serves, numbers that
       moved), with the text it should say.

189. **The box's (Steve, 2026-10-13): /admin/host, so an agent can answer
    questions from it, and Steve can still read it.** First merge your 188
    work onto master yourself only if the box has not (it will try today;
    fetch first). Then, in this order, each its own commit, red first where
    there is a rule:
    1. **More log, 20x.** The live ring (`serial.zig`'s 64 KiB) and the kept
       log's two slots (`kept_log.slot_bytes`, 64 KiB each) go to about 1.25
       MiB each. Today a few minutes of traffic rotate it away; v29 uses 81
       MB of 997. Check what it costs a boot (the ring's section, the kept
       region's placement out of the page allocator) and say so. The page
       itself stays short (see 3).
    2. **Every request line carries its wall-clock time** (UTC, to the
       second or better), so "what happened at 14:02" can be answered; and
       its status code and its duration, where the line does not have them.
    3. **A view for agents, beside the page for Steve.** The HTML page stays
       human-first: a health summary at the top, then the sections it has,
       the log's newest lines as now. Add a plain-text (or JSON) view under
       the same bearer key, e.g. `/admin/host?view=text` or `/admin/log`,
       that an agent can fetch and grep: the whole ring, this boot's and
       the boot before (the kept log), with narrowing by time (`since=`),
       by request number, and by path prefix, and a short header saying
       what it is (boot time, commits, how many bytes and lines the ring
       holds, the oldest line's time). Your choice of shape; say why.
       Read-only, GET only, and refused without the key, as the page is.
    4. **Uploads, clearly.** A section (and its lines) answering "did that
       upload work, and what did it cost": the last N uploads with time,
       topic (as the log may name it), kind, bytes, how long it took to
       arrive, the turn, its disk requests, and the answer (ok, refused
       and why: too big, over quota, writes refused, the client gone,
       taken over). Counts since boot by outcome.
    5. **Counts an agent would otherwise grep for:** since boot, requests by
       status class and by route family (chat, games, docs, admin, uploads,
       streams), the slowest N requests (time, path, duration), and every
       5xx with its line. Errors first when there are any.
    6. **Redaction stays as it is, at write time, and grows only where
       Steve said:** a pure-text chat message may be logged as its LENGTH
       (bytes, and that it was text), never its words; nothing else of a
       message (not a link, a name, a mention). Cookies, keys, passwords,
       secrets, session values and upload paths (`/uploads/` segments)
       stay redacted. A plant for each: a line carrying each kind of
       secret, and a message's text, must come out redacted.
    7. **A short guide for agents**, in gopher-metal's docs: how to fetch
       each view (the bearer key from `~/.gopher_api_key`, never printed),
       what each section means, and five worked questions answered from it
       ("did the upload at 14:02 work?", "what failed since boot?", "why
       did the machine restart?", "is the disk healthy?", "who is
       connected?" (as counts, not names)).
    The chat judge compares /admin/host between hosts today
    (`host_page_differences`): keep it comparing, and have it cover the
    new view. Say what each step costs the page's time; it is fast now and
    should stay so.

188. **The box's (Steve, 2026-10-13): your two FAT design questions from
    187.1, answered. Both on master's gopher-metal (`689880c` or later: your
    179/181/180/182/187.2 are merged onto Phase B step 4).** Red first, both
    sides of each edge, fat_sim and the fault sweeps taking each.
    1. **An overwrite reads its commit back (Steve: yes).** Before the old
       chain is freed, the directory entry's sector is read from the disk,
       past the directory cache, and must hold the new entry; if not, the
       old chain is not freed and the write fails (the file keeps its old
       contents, nothing is lost). One read per overwrite. The red: your
       `overwrite10` `lands_nothing`-on-the-commit run (`broken /f.bin`,
       both copies agreeing), which must end with the old file whole or the
       new one, never broken. Say what it costs a 10 MB overwrite in
       requests.
    2. **An unweighed mount refuses writes (Steve: option (a)).** When the
       mount's weighing of the two FAT copies fails part way, the volume
       serves reads and refuses every write until a weighing succeeds: retry
       it at the next mount and from the idle check (say which, and how
       often), and the refusal is an error the application answers (a 503
       on an upload or a post), never a panic, and is visible on
       `/admin/host` and the boot log, not only `gopher.zig:1573`'s line.
       The red: your test 7 (a lie to copy 0's run, then a failed read in
       the mount), which must end with copy 1 intact and no write landed,
       and then, once a weighing succeeds, the volume writable again. 178's
       one-sector form of the same case too. Check every write path (data,
       FAT runs, directory, the store's rename, games, docs, uploads,
       backups) goes through the one refusal.

187. **The box's (Steve, 2026-10-13): the cold reviews of 181 and of 180/182's
    kernel half, as CC's own adversary passes, FIRST (before 186).** The box
    began both and stopped them (Steve: no more running at once than the
    policy allows; reviews that need no KVM go to the cloud). Neither is
    merged to master until these pass. Each: findings ranked, a concrete
    scenario, file:line, CONFIRMED by experiment where it can be, a verdict.
    1. **181 (`ecb467b`), by experiment.** The box's reviewer had built one:
       `docs/box-rev181/` (rev181_exp.zig, a test file that sweeps a lying
       `lands_nothing`/`torn` request at every request of a 10 MB write,
       overwrite, remove, and a write on fragmented space, on small FAT32;
       apply.sh wires it into a worktree; outputs from 179 and 181 beside
       it). Its partial result: on 179, `overwrite10` has 3 bad of 335
       (mount `past_weighing` trusts copy 0 -> broken `/f.bin`, BadChain);
       on 181 all six sweeps pass ("1 bad" in fragwrite10 is a leak of
       80 clusters at the last request, no damage). `out_ecb.txt`, an
       earlier run on 181, FAILED one assertion ("expected 31, found 16")
       after a series of `WRONG BYTES` with no damage in fragwrite10: find
       out which (the experiment's expectation or the code), and say.
       Finish it on 178 as the baseline. Then hunt what 181 might break:
       can a legitimately newer copy 0 lose to an older copy 1 (a cut after
       copy 0 landed whole, before copy 1)? the cost of weighing whole at
       mount on a 16 GiB volume; the idle check; do fat_sim's tears land a
       PREFIX of a request's sectors?
    2. **180 + 182, the kernel half (`da1ec5f`).** Prod's chat data is on a
       DigitalOcean volume over virtio-scsi, its boot disk virtio-blk, and
       requests just grew to 1 MiB: a mistake stops the site booting, or a
       silently cut request corrupts. INQUIRY EVPD B0h (the CDB; MAXIMUM
       TRANSFER LENGTH bytes 8..11 in LOGICAL BLOCKS: a block size not 512;
       no page, a CHECK CONDITION, page 00h not listing B0h, a short answer,
       a page length under 12); the least of disk/controller/2,048 used
       EVERYWHERE a request is built (data and FAT runs, the page cache, the
       idle check). virtio-blk chains: descriptor count against free
       descriptors and the chain limit, `seg_max`/`size_max` per the spec,
       physical contiguity, u32 lens, an uneven split, completion freeing
       every descriptor of a chain, a chain larger than the queue. 182's
       four: each red test at its edge, both sides; a normal disk still
       mounts. And anything that changes a normal boot.

186. **The box's (2026-10-13): 180.6/180.7/182's and 180.1-device's cold
    review. Before 183.** The box fixed the one blocker on branch
    `cc-merge-2` (angry-gopher `86eeae60`, on your `d1beb64e`): a bodiless
    `Expect: 100-Continue` was taken by `plan` but only linux_host made it
    std's spelling, so **metal answered nothing at all** (it was a 417).
    `site.route` now calls `meetExpectation` for every host; red first, both
    spellings. Merge that branch into yours. The rest, red first:
    1. **The 176.8 takeover test still never meets the race.** `watch`
       counts silence only in ticks; with a 1 s tick and the takeover at
       700 ms the watcher has not ticked once, so the test passes the same
       with no stall at all. Use a small tick (50 ms) with a 600 ms stall,
       take over at ~550 ms and at ~700 ms, and assert each side: before the
       stall the old is told 409; after it fired, what the old was told
       (408) and that the new upload gets the slot and is read whole.
    2. **metal-vmm's 180.1 test proves nothing about "the refused write
       wrote nothing"**: image and data area are both zero. Fill the data
       area with non-zero bytes first.
    3. metal-vmm's VPD: `vpd()` ignores `here`: a LUN with nothing attached
       answers 00h/B0h as a disk (type 0x00) where standard INQUIRY says
       0x7F; and an allocation length shorter than the page, and 0, are
       untested.
    4. Done by the box (Steve: fail closed): a uid marker dated after now
       is refused as past its grace (`cc-merge-2` `2d3e4c31`).

183. **The box's (Steve, 2026-10-13): a mechanical guard for the class that
    hit prod twice. After 180 and 182.** Twice a ReleaseSafe panic in the
    served kernel came from arithmetic on a number the client chose (v26:
    a forged cookie's MAC length; v28: `Last-Event-ID` + 1, fixed on master
    `3d5a5f3d`). Each read as right; an off-by-one sweep passed over the
    second. A reading hunt found it in one pass, but the class needs a
    guard that runs every time:
    - **A request harness over angry-gopher's Linux build in Debug** (every
      safety check panics, in seconds, no QEMU): for every place the
      application parses a number from a request (a header, a query key, a
      path segment, a form field, a cookie, a message's markdown: grep
      `parseInt(` in zig-server/src for the list, and make the harness
      refuse to pass if a request-reachable call site is not covered), send
      each of the type edges (0, -1, 2^31±1, 2^32±1, 2^63±1, 2^64-1, 2^64, a
      30-digit number, a sign, leading zeros, whitespace) as a signed-in
      member. Fail if the server dies or logs a panic, naming the request.
    - **Red first:** it must catch the sse.zig overflow on `v28` (tag),
      then pass on master. In `ops/check_zig` or its own fast gate.
    - If the shape invites it, the same over webbox's headers for dog-park's
      play server (no Dog Park feature work: only the harness pointed at it).

184. **The box's (2026-10-13): the next class hunt, slow exhaustion.**
    Anything a request (a stranger's, or a member's) can make grow without
    bound, on either host: a map keyed by request data (sessions, throttles,
    presence, per-human tables, caches, the bus's subscribers), files a
    request creates per call, connection- or stream-table slots held by a
    client that does little, an allocation sized by a header. For each:
    the bound, or a red test that shows there is none, then the bound (its
    edge, both sides, in one test). The kernel's fixed heap makes this a
    crash class there. Cold adversary before you report.

185. **The box's (2026-10-13): small, from the crash hunt.** angry-gopher:
    an `<img` tag in a message can carry `images_sep` inside the tag, which
    plants a fake entry header (a spoofed source / from line) in each
    member's images.md: escape or refuse it where it is written, red first.
    And an upload file name that is not UTF-8 comes back in JSON as an
    array of numbers: answer a string (replace what does not decode).

182. **The box's (2026-10-13): four panics at boot, from the crash-class
    hunt. After 181, with 180.** A hunt for every ReleaseSafe panic outside
    input can reach found none from the network in the kernel, and these
    four from a disk or the config (each stops the boot; red first, both
    sides of each edge in one test):
    1. `src/gpt.zig:85`: `@intCast(entries_lba + index / per_sector)` to
       u32 panics on a GPT header whose PartitionEntryLBA is >= 2^32.
       Refuse it (NotGpt).
    2. `src/gpt.zig:113`: `@intCast` of a partition's first/last LBA panics
       when either is >= 2^32: **no damage needed**, a DigitalOcean volume
       over 2 TiB partitioned whole does it. Refuse as `disk_fat.mount`
       refuses a volume past 32-bit sectors (and the `le64` comment says
       "truncated" where the code casts).
    3. `src/disk_fat_check.zig:286`: `(n + cluster_bytes - 1) / cluster_bytes`
       in u32 overflows for a file size > 2^32 - cluster_bytes: **no damage
       needed**, a valid FAT32 file near 4 GiB panics every mount's check,
       the weighing's, and the idle check. Round in 64 bits, as
       `disk_fat_file.zig`'s `writeInto` does.
    4. `probe/gopher.zig:1849, :1854`: `ms * std.time.ns_per_ms` for
       `idle_timeout_ms` and `keepalive_ms` overflows u64 above ~1.8e13;
       every other numeric key is range-checked. `std.math.mul`, and a
       `serial.fail` naming the key.
    And, while there: `Volume.mount` does not bound sectors_per_fat, so the
    u32 products `sec * per + i` (disk_fat_check.zig:548) and `at * per + e`
    (disk_fat_fat.zig:182) are safe only through gopher.zig's 32 MiB FAT
    budget; bound it in the driver itself. And angry-gopher's
    `uid_cookie.zig:147` `now - at`, `at` from a marker file on the volume,
    overflows i64 for a marker of -9223372036854775808: saturate.
    (The angry-gopher hunt's one request-reachable panic, sse.zig's
    Last-Event-ID + 1, is fixed on master `3d5a5f3d`.)

180. **The box's (2026-10-13): 178/177/174/173's cold reviews. With 179 or
    right after it; item 1 before v29 ships 178.** Your branch to `51f27862`
    / `18d51ee` is merged to master (angry-gopher `3555205a` adds two fixes:
    the four `pub const x = <var>` re-exports in chat_store removed (a
    container const can't read a var; it compiled only unreferenced), and
    readWhole's doc says gpa).
    1. **The disk's own transfer limit (gates v29).** `max_sectors` is
       virtio-scsi's controller-wide hint; the disk's limit is its Block
       Limits VPD page (0xB0, MAXIMUM TRANSFER LENGTH), which Linux's sd
       obeys and the kernel never asks. If DO's volume backend caps below 1
       MiB, the first 1 MiB FAT read at mount is CHECK CONDITION and the
       site does not boot. Ask INQUIRY VPD 0xB0 at bring-up (a disk that
       has no such page, or says 0, is unlimited by it); take the least of
       it, `max_sectors` and our 2,048; show it in the host facts and the
       volume's boot line. metal-vmm's SCSI device should answer the page
       (and a test device that answers a small limit, to show it obeyed).
    2. **virtio-blk `size_max` is a per-SEGMENT limit,** not per request:
       a device offering a `size_max` under a cluster now fails the mount
       (it served before 178). Either chain data descriptors up to
       `seg_max`, or bound the request by `size_max * seg_max`; and
       `size_max = 0` is unset, as virtio-scsi's 0 is.
    3. `probe/append.zig:78`: `@min(blk.most_sectors, 128)`, never raise
       what the device said.
    4. fat_sim draws `most_sectors` per seed from {spc, 8, 128, 2048}, so a
       run cut by the limit mid-chain is in the sweeps, not only five tests.
    5. Small: drain.zig's `Busy` sits under `Verdict`'s doc (move it);
       `tools/check_fat16_images.sh:66` greps `max_name` in disk_fat.zig, it
       lives in disk_fat_dirent.zig (broken on master).
    6. angry-gopher's tests that do less than their names: the 176.8
       takeover-with-stall test takes over at ~100 ms against a 600 ms stall
       (the race is never near); the 177.2 test reads the total after the
       read, not the peak (the old room beside the new one is untested).
       And presence's "tried again every 30 s" happens only on a request:
       say so, or retry from the 30 s tick.
    7. Expect: a bodiless `100-Continue` (any case) is 417, where the host
       already rewrites mixed case for a request with a body: rewrite it
       for none too, and serve it.

172. **A class hunt: errors swallowed, or sent the wrong way.** The largest
    class in the last 52 fixes (12 of them: a write's failure answered
    success, a catch-continue that skipped work, OOM counted as "unreadable",
    an error closing a connection with no answer). Hunt it across
    angry-gopher's handlers and stores and gopher-metal's `src/` (not
    `probe/gopher.zig`'s drain loop, which is 171's). For each site: what
    the caller is told, whether that is true, and whether a test pins it.
    **Red first** for every bug; a site that is right but unpinned gets its
    test. Report the sites checked, the bugs, and the questions where the
    intended answer is unclear.

173. **`src/disk_fat.zig` (4,146 lines) split by the ~1,000-line rule**, and
    `src/disk_fat_test.zig` (3,102) along the same seams. No behaviour
    change: cohesive modules (mount and layout, the FAT and its chains,
    directories and names, the write paths and their commits, the check),
    each with its tests beside it or in its own test file. Every existing
    test, fault test, plant and coverage property is kept, with the same
    message (the catalog and floors read them); new files join the coverage
    catalog's list. `zig build test`, `check`, and a small `properties` build
    pass; the box runs the guests.

174. **angry-gopher's `chat_store.zig` (1,896 lines) and `users.zig` (1,061)
    split** the same way, no behaviour change, `ops/check_zig` and
    `ops/check_chat` passing. `router.zig` (2,262) waits: it is Phase B's
    application root.

## The box: open

Each line's full text, with its history, is in the archive under its name.

- **B32 (2026-10-10, Steve; after v22): weigh a compile-time off switch for the coverage SDK**, as Antithesis's SDKs have one (Go's `no_antithesis_sdk` tag, C++'s `NO_ANTITHESIS_SDK`, Rust without `full`). Today the served kernel records every property on every call, and nothing there reads the counters. A plain property costs a few instructions and a store; a numeric comparison also works out its edge and reach on every call. Measure that first, with one hot-loop benchmark with the SDK on and off. **Against it:** the kernel the gates judge would not be the one served; `/admin/host` could someday show the properties broken in production; a condition with side effects still runs. Steve leans toward mostly what Antithesis does, with those concerns weighed.
- **B31 (2026-10-09, Steve's open question): a `gates.sh` line that fails when `zig build test` exceeds a time budget**, so the suite's cost can't creep back up (530 s at v21; 194 s after 136; 3m19s on the box tonight). Wait for 142's number, then decide the budget with Steve.
- **B29 (2026-10-09, found moving the slow-reader gate): stray resets after a reader that paused.** A client that shuts its window for 2.5 s mid-page (`PEER_SHUT_AFTER=4096 PEER_SHUT_FOR_US=2500000`, the 231 KB `requests/big-page.http`) gets the whole page, but the guest's tcp line then counts 8 strays reset (none unhurt), with 4 timeouts resent. Something reaches the guest for a connection it no longer holds: either the peer keeps talking after it is done, or the guest forgets a connection the peer is still owed (TIME-WAIT's ACK, say). Find which, from a frame trace; a peer fault is fixed here, a guest one becomes a red test in gopher-metal.
- **v20** (2026-10-08): port, `gates.sh`, `long.sh`, the image, Steve's go;
  Steve's steps gain a Caddy reload (angry-gopher `deploy/Caddyfile`).
- **The request door, stage 1** (angry-gopher branch `request-door`): to
  `master` once v20 is ported; rebase onto `limits.zig` first. Stage 2 (our
  own response type; a small body read before the turn) after.
- **The explorer against blind runs, properly** (with Steve, a design
  session): the full bench (`zig build explore` at its defaults: 20 explorer
  seeds, counted against what blind runs reach at 300; CC's item 98,
  merged). A smoke run at budget 5 left about 4.5 of 40 counted properties
  unreached by blind runs and about 20 by either explorer: at small budgets
  the explorer branches from one or two early runs and sees far fewer
  scenarios. Quote no number before the full run. Also: the bench step shows
  "failed" under `zig build` because its test writes to stderr (CC: make it an
  executable, not a test).
- ~~**B16.** The SDK's commit and what the image reads in the release verdict~~ (done, gopher-metal `tools/verdicts.py`, 2026-10-07).
- **B17.** A coverage property per refusal in the guest's parsers.
- **B18.** Lies in the peer's DHCP replies.
- **B19.** B14's power cut as a `long.sh` scenario; H5 and H2 against
  gopher.elf.
- **102 (from CC's list: it needs KVM).** The rough peers must reach their
  four TCP properties by design on both kernels, then back on
  `floor-metal.txt` (QUEUE-ARCHIVE.md has the full item).
- **N4.** The cloud session's device knobs (item 82), run on gopher.elf and
  put on `floor-metal.txt`.
- **B2, B3, B4, B6–B10, B12** (older: a seed sweep of gopher.elf, the bad
  sector, the last TCP properties on the real kernel, request_heap's figure,
  the fat16 seam, the deadline mark, the snapshot's box half, microvm,
  revival on the real kernel).
- **HOST.md's owed list:** the application's locks deleted (one handler at a
  time is in), durability on Linux (`fsync` before a response that followed
  a write), the Bus contract and its simulator.

## Proposed

*(The cloud session adds items here, one line each on why. Earlier
proposals, taken or not, are in the archive.)*

- **P139(a), P139(b). State changes only by named events, checked in Debug
  and counted by the coverage SDK** (Steve's idea; CC, 2026-10-09 night).
  (a) a ledger in `disk_fat.zig`: every cluster an operation takes ends
  committed, given back, or a counted leak (the class `ec77f28` and
  `05b0cfb` fixed). (b) `tcp.zig`'s `Fin` as a declared machine, with one
  `sometimes` per legal transition. CC votes (a) first. Written up in
  [STATE_TRACKING.md](STATE_TRACKING.md). **Taken: 139 and 140 under "CC: open".**

- **P128. The damage property says which disk** (gopher-metal
  `gopher.zig` ~1358 and ~1417, the box's). Its details carry
  `.damage = n` only, so sweep.sh excuses a break by a damaging fault on
  either disk. Adding the disk (`.disk = "boot"` / `"volume"`, or the
  volume's index) to the details would let the excuse need the fault on
  the disk the damage was found on. sweep.sh's `broken_props` already
  reads each event; it would read the details too.

- **P124(f). A FAT tie that cannot postpone the rot** (gopher-metal
  fat16, the box's; pinned as it is by `fat16_test.zig`'s "FAT copies that
  tie", gopher-metal `3f17998`). Today, copies that check alike are both
  kept, the first held, and the next change to a differing sector writes
  the held copy's version to both: the rot lands on both copies, later.
  Two ways out, either a red test away from that one:
  - **Merge toward allocated:** on a tie, take each differing entry's
    nonzero side over a zero (a cluster rot freed stays held), and write
    both copies at once. Rot can then only leak a cluster, which fsck
    reclaims, never free one a file holds.
  - **Keep each copy's own:** a change writes only the entries it touches
    into each copy, so the copies stay as unlike as they were, and the
    next boot's check sees the same tie and nothing worse.
  The first is what I would take: it ends the tie, and its worst case is a
  lost cluster.

From item 101: the next five, most finding first (CC, 2026-10-08). Each one
runs on the host, and each would start from a red test.

- **C1. A disk that loses what it wasn't told to flush** (gopher-metal,
  `store_sim`, mine). The test disk keeps writes in a cache until a flush,
  and a cut drops what is still cached. The oracle is the store's promise:
  after a cut, a replaced file is wholly old or wholly new. Today no disk
  in any test loses an unflushed write, so `store_fat.replace` passes with
  its flush deleted (mutant S5, reached by 18 runs and never checked). This
  is the host half of HOST.md's owed "durability", and the likeliest of the
  five to find a real bug. In the same tier, also count free clusters
  before and after a `replace` whose rename fails; a leaked temp file is
  mutant S6.
- **C2. Hold the snapshot's premise, not only its examples** (metal-vmm
  `snapshot.zig`, mine). "A model's snapshot is its value" holds only while
  no model keeps a slice, a pointer to its own storage, or anything an
  allocator owns. A comptime walk over every model type can refuse any
  pointer field that isn't on a named allow-list (`Device`→device,
  `Function`→APIC, `Block`'s image). Then a model added next month that
  breaks the premise fails to compile, instead of a restored run quietly
  diverging. Add a census too: every piece of state `main.zig`'s machine
  holds is either in `snapshot.zig` or is named as the box's half.
  Adversarial and cheap, before the box builds a sweep on it.
- **C3. The store lint follows the wrappers** (angry-gopher, mine). Item
  108's survey found 234 functions that read the store, directly or
  through others, and 25 calls to them whose error is caught into a value.
  `lint_store_absence.py` would apply its catch rule to calls of that
  transitive set, computed from the source on each run, so a new wrapper
  is covered without anyone listing it. I expect about 25 findings, most
  of them needing an `// absent-ok:` line. The point is the next
  `isMember`, which was a wrapper the lint couldn't see.
- **C4. The three cheap unreached survivors** (gopher-metal, mine), each
  one test, as `MUTATION.md` already says:
  - S11: `store_test` writes `a/b` where `a` is a file, and expects
    `BadName`.
  - L7: `floor_sim`'s `redactSeed` is given a quoted value ended by
    `\r\n`, and the `\r` must come out.
  - P1: `page_sim` gets a single path part of exactly `max_key + 1` bytes.
    The mutant writes out of bounds there.
- **C5. angry-gopher's hygiene, two small ones** (mine to propose, yours to
  take or not).
  - `ops/check_zig` gains `zig fmt --check src`, as gopher-metal's tests
    have. 8 files fail it on master today, so it starts with one
    formatting commit.
  - The router's "/" test reads `pages/home.txt`, which lives at the repo
    root, outside `zig-server/`. Here, under `ops/check_zig`, it gets 500
    and fails. A test that depends on the directory it runs from should
    supply its own page.

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
- **store_test's agreement is one volume size, FAT16 only** (gopher-metal
  `src/store_test.zig`): `store_sim` (item 79) takes FAT32 and a full
  volume, where `NoSpace` lives. *(Paid, item 83: `store_sim` fills a
  volume one seed in four.)*
- **The `writeRuns` re-checks** (a chain that ends before its size, past
  `chainEnd`'s walk) wait on a disk that lies between two reads; a
  `floor_sim` case with `Block.Fault.garbage` at the right request number
  could reach them, but finding that number by search is fiddly.
