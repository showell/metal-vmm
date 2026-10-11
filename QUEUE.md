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
