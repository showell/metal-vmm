# QUEUE

The one queue for the four repos (metal-vmm, gopher-metal, zig-coverage-sdk,
angry-gopher): what is open, and who has it. **Finished work, the answered
questions and every earlier item, by its number, are in
[`QUEUE-ARCHIVE.md`](QUEUE-ARCHIVE.md)** (the queue as it stood on
2026-10-07, verbatim); new items continue from 103. The cloud session's
charter is [`CLOUD_WORK.md`](CLOUD_WORK.md).

## Context

metal-vmm runs gopher-metal's real kernel deterministically (both machines:
microvm-shaped and `TRANSPORT=pci`); the scenarios that cover what the site
meets go here, not to QEMU, which stays on the happy path (Steve). The goal
is zero bugs in the lower levels; class hunts find more than seeds; the
judge is becoming "did anything forbidden happen?", checked by `plants.sh`.
The snapshot (`docs/SNAPSHOT.md`) is parked.

## Now (2026-10-09, night)

**v21 serves** (deployed 20:11 UTC; gopher-metal `81d7a35`, angry-gopher
`a30a1542`); master is `next` in both repos, and `next` is gone. On master
for v22: tcp's duplicate-ACK cap, Karn on a resent SYN-ACK, and the
disk_fat fixes since. **The v22 candidate is being judged overnight**
(gopher-metal `b4463a9`, angry-gopher `51713cd6`: gates, long, then the
image if both pass; `~/release-v22/status` on the box). None of CC's
overnight work is in it. **Overnight, CC has 139-142** (below), and owns the
files they touch until it stops. The conversation between the two Claudes
is `FEEDBACK.md`.

## CC: open

**Your role (Steve, 2026-10-08): build what needs no emulator, and anything
adversarial.** Every item here runs on the host: `zig build test
-Dtest-file=<file>` runs one gopher-metal test file in seconds (the whole step
takes minutes); metal-vmm's `zig build test` and its `sweep_test.sh` need no
guest. Where a claim needs a real boot, write the recipe under Questions for
the box instead of guessing. Findings arrive as red tests where they can.

103. **Attack what the box changed on 2026-10-07 and 10-08**, adversarially,
    security and data loss first. Each was found by running production's
    shape (PCI with a volume) on metal-vmm or by a cold read, and fixed in a
    day; look for what the fix missed or broke. Report under Questions, a red
    test with each finding you can make one for.
    - gopher-metal: `d86ec98` (SCSI: a short transfer fails), `c7539eb` (boot
      tries a read three times, `virtio.Block.read_tries`), `d7a5903` (FAT
      copies apart: `cacheFatChecked` keeps the copy that checks cleaner, and
      the check now counts leaks from the FAT held; the free count moves with
      the second copy), `e07b363` (a response cut by the stop is said),
      `d2e7480`, `83584da` (boot messages).
    - angry-gopher: `9e8e615d` (`ustar.zig`, a topic's download), `ef3091eb`
      (four store reads that served a failure as nothing), `8b617f3c` (the
      head copied out of the read buffer before a small body is read in).
    - metal-vmm: `766bffc` (virtio-pci vectors for a third queue; a write's
      residual), `9f24e42` (`VOLUME_SHORT_AT`), `311731c` (`checked.zig`:
      every setting parses or the run stops), `6ae4909`, `78dd476`
      (`sweep.sh`'s status and its excuses).

104. **The cold hunt's smaller findings** (silent truncation, 2026-10-08),
    each fixed with a red test, or answered under Questions with why not:
    - `fat16.zig` (~2765): a long-name character of 128 or more is written
      as '?', so the name no longer reads back as itself; its comment says
      such a name is refused. Refuse it (`BadName`).
    - `io.zig` `Dir.iterate` (~857): a directory that cannot be read lists
      as empty. Make it an error.
    - angry-gopher `admin_backup.zig` (168, 180): a `stat` that fails drops
      the item from the backup without listing it in `backup-skipped.txt`.
    - metal-vmm `site.sh` (73): two empty `tcp:` lines compare equal, so the
      connection check passes on nothing if the line ever goes.
    - metal-vmm `reports.zig` (192): the status line's "N bytes" is what the
      client kept (64 KiB at most), not what it received.
    - gopher-metal `store_judge.zig` (242, 272): "is this a file" reads into
      a 1 MiB buffer, so a larger file is a false mismatch.
    - gopher-metal `log_ring` `Ring.read` returns the newest bytes from
      mid-line with no flag; check the buffer at `probe/gopher.zig` ~1522
      against the ring's size.

105. **A lint for failure read as absence, in angry-gopher.** Four store reads
    turned an error into "", 0 or null this week (`ef3091eb`), each a data
    loss. Make `tools/lint.py` (run by `ops/check_zig`) refuse a store call
    (`store.read`, `stat`, `has`, `list`, `readAt`, ...) whose error is caught
    into a value (`catch ""`, `catch return 0`, `catch null`, `catch {}`,
    `catch continue`) unless a comment on the line before says why that
    failure may be read so, as gopher-metal presumes an omitted flush a bug
    unless a comment defends it. Then fix or defend every site it finds,
    each fix with a red test. Its own tests first (`test_lint_portable.py` is
    the pattern).

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

112. **Done (CC, 2026-10-08): a finding, red; its fix is fat16's, so the box's (Questions, "item 112").** S5 and S6 killed. **Was:** **C1, a disk that loses what it wasn't told to flush** (your proposal;
    first): the test disk keeps writes in a cache until a flush and a cut
    drops the rest; the store's promise (a replaced file wholly old or wholly
    new) is the oracle; kills S5, and count free clusters across a failed
    rename (S6).

113. **Done (CC, 2026-10-08): the walk, the census, and the two gaps it found closed (Questions, "item 113").** **Was:** **C2, the snapshot's premise held at compile time** (your proposal):
    a comptime walk refusing any pointer field in a model not on a named
    allow-list, and a census of what `main.zig`'s machine holds, before the
    box builds `docs/SNAPSHOT.md` on it.

114. **Done (CC, 2026-10-08): 231 readers followed; one real site fixed (docs' 404), 24 defended (Questions, "item 114").** **Was:** **C3, the store lint follows the wrappers** (your proposal): the
    transitive set of functions that read the store, computed on each run.

115. **Done (CC, 2026-10-08): L7 and P1 killed, S11 equivalent in effect; MUTATION.md 71 of 76.** **Was:** **C4, the three cheap unreached survivors** (your proposal): S11, L7, P1.

116. **Done (CC, 2026-10-08): angry-gopher `4e45444` (the format), `5528731` (the check).** **Was:** **C5, `zig fmt --check src` in angry-gopher's `ops/check_zig`** (your
    proposal), starting with one formatting commit. Its other half (the "/"
    test) is done (`446cbb7f`).

117. **Done (CC, 2026-10-08): angry-gopher red `42ccebc`, fix `463a8bf`; the tree had no site of either shape.** **Was:** **The store lint's two gaps** (a cold review of 109): a `switch` that
    passes some errors on and makes another non-absence one a value; `else
    |e|` with a named error, never checked. Both findings, with tests.

118. **Done (CC, 2026-10-08): angry-gopher red `e494b31`, fix `2a1666b`; the fold `6a024df`, with a third lint gap found on the way (red `d3fcce8`) (Questions, "item 118").** **Was:** **A backup folder that stats but cannot be listed** (a cold review of
    110): it fails `try store.list` mid-stream and cuts the archive with no
    skip line; make it a named skip. Also fold `principalAuthorizedOrError`
    into `principalAuthorized` (they're the same since 108).

119. **Done (CC, 2026-10-09): a reset turns the cache back on, and the driver never knows; the model gained the disks to show it (Questions, "item 119").** **Was:** **Attack the write cache turned off** (Steve chose WCE=0 over
     barriers, 2026-10-09; the barrier patch and its two misses are moot).
     - gopher-metal `1619ff3` `scsi.turnCacheOff`: MODE SELECT(10) sends
       back the sensed caching page with WCE cleared, then reads it again.
     - metal-vmm `7bbd048` `Scsi.modeSelect`: the model of a disk that takes
       it, plus `VOLUME_WCE_FIXED=1`, a disk that refuses.

     Read both against SPC-4 §6.13 and SBC-3 §6.5.5, and against how Linux's
     sd sends the same (`sd_cache_type_store`). The questions:
     - What would a real disk (QEMU's scsi-hd, which DO likely runs) refuse,
       or take and ignore?
     - Is a cache that is turned off, but held writes from before, possible
       at boot?
     - Is anything in the page we send back besides WCE wrong to echo?

     Findings as red tests in metal-vmm's `scsi.zig` where you can.
     `store_sim`'s cached test now holds the reason: it expects a cut on a
     cached disk to break fat16's promises.

120. **Done (CC, 2026-10-09): angry-gopher red `cd446aa`, fix `a30a154` (Questions, "item 120").** **Was:** **The store lint's two new holes** (the same review, 114's rules):
     - The wrapper rule accepts any `error.X` arm. `catch |e| switch (e) {
       error.AccessDenied => null, error.InputOutput => "", else => return e
       }` passes, and so does `if (e == error.AccessDenied) null else return
       e`. Accept only errors the wrapper defines itself.
     - The 5xx rule searches the whole handler. `catch blk: { if (c) return
       respond(.internal_server_error); break :blk null; }` passes. The arm
       must *be* the 500 answer.

     Red tests first, then the fix.

121. **Done (CC, 2026-10-09): metal-vmm `c1f36c7`, each refusal probed.** **Was:** **113's walk, three gaps** (the same review):
     - It doesn't descend through a pointer. `cache.Cache` is reached only
       through `virtio.Block.cache?` (borrowed), so a new pointer field there
       goes unseen. Put `cache.Cache` in `models`, with `durable` its named
       exception.
     - `.apart` proves only that a field is not in `models`, not that
       `snapshot.Cache` handles it.
     - `.box`, `.input` and `.host` are taken on trust: say why in each one's
       line, or check them.

122. **Done (CC, 2026-10-09): three holes in the judging and one in the wire, each red first and fixed (Questions, "item 122").** **Was:** **Attack today's judging** (FEEDBACK.md, 2026-10-09 morning). Every
     excuse added on 2026-10-09 widens what passes:
     - `sound.sh`'s `STOP_LEAVES` and its FSInfo exception;
     - sweep.sh's "the request limit went to another client";
     - the lying disk's excuse for an unsound volume;
     - "pushed out" counting only a frame the peer never resends.

     Look for a wrong answer or a damaged volume that now passes. Each
     finding is a red case in `sweep_test.sh`, using its fake machine, and
     needs no guest. Also check whether `SHAPES` judges every seed against
     its own shape's unhurt run in every path (the summary, KEEP_FAILED, the
     repeat line).

123. **Done (CC, 2026-10-09): angry-gopher red `9588ac5`, fix `7cbed40` (Questions, "item 123").** **Was:** **A failure that escapes a handler is answered with nothing** (the box,
     2026-10-09, durable sweep seed 173). A lying disk left
     `/DATA/LYNRUMMY/p2/puzzle` with a chain into free space. The next boot's
     `GET /puzzles` failed with `ReadFailed` ("request 1: GET /puzzles ->
     ReadFailed" on the console), and the client got no answer, not a 500.
     Steve's rule is "louder is better": a failure is a 500, never silence.
     - Find where gopher-metal's serving loop, or angry-gopher's server,
       drops a handler's error without answering.
     - Answer 500 there, unless the head is already sent.
     - Red first: a handler test whose store read fails.

124. **Done (CC, 2026-10-09): (e) first, then (a)-(d), each red first; (f) pinned, with a proposal under Proposed (Questions, "item 124").** **Was:** **A cold review of 2026-10-09's judging and method** (box, after your
     122). Check each against what your 122 fixed, and fix what's left, red
     first:
     - **(a) The request-limit excuse counts letGo.** `served` in
       gopher.zig (~604-613) counts a quiet client let go as well as a
       served one, so `served == limit` almost always holds when the guest
       stops itself. The excuse then needs only that some other client got
       an answer. A kernel that wrongly lets client 1 go passes. The kernel
       should say served and let-go apart, and the excuse should read the
       served count.
     - **(b) `STOP_LEAVES` passes a lost committed file.** If a file's short
       entry is marked deleted, fsck says only "Orphaned long file name
       part" plus "Reclaimed N unused clusters", which is exactly what a
       stop leaves. The reviewer probed it with fsck.fat 4.2. fat16's
       `damage()` shares the blind spot. Suggestion: STOP_LEAVES allows the
       orphan only when no reclaimed cluster belonged to a file the unhurt
       run's volume has (compare file lists), or another way you find.
     - **(c) A power cut stops the whole machine, but STOP_LEAVES is given
       per device.** A `DISK_CUT_AFTER` mid-volume-write leaves the volume
       judged without it.
     - **(d) nightly.sh acts only on exit 2.** SILENT lines (report.py) and
       a report-only FAIL never reach failures.log, and progress.log says
       "0 failed".
     - **(e) Method: excuses count knobs drawn, not knobs that fired.**
       metal-vmm prints "X never came" (reports.zig `unspent`), and sweep.sh
       never reads it. About 44% of seeds draw a reset or a vanish, so a
       hang or a cut page is excused when no reset happened. An excuse
       should need its fault to have fired. Make this the biggest of these.
     - **(f) The tie in fat16 postpones the damage** (fat16.zig ~624): the
       rotted first copy is held, and the next change to that sector writes
       the rot to both copies. A test for it, and a proposal; this one is
       the box's to decide.

125. **Done (CC, 2026-10-09): metal-vmm red `ffae703`, `fd7d262`, shapes `2fa6a29` (Questions, "item 125").** **Was:** **Durability as a shape** (the review's hole B: a write is judged only
     by its response). Today the durable judge is a sweep of its own
     (`POST`, `READ_BACK`, `MARK`, `TOLD`), and the reset bug showed only
     there, never in the shapes night. Let a `.shape` carry its own
     read-back, so every write shape is also judged on whether it kept what
     it was told it kept. For example: `READ_BACK=read-puzzles.http`,
     `MARK=session_id: 2`, `TOLD=204` in `puzzle-action.shape`.
     - The read-back boot then runs only for the seeds of those shapes.
     - `requests/shapes/README.md` holds the one recipe that exists.
     - Each write shape that can be read back gets one: a player, an
       account, a game session, a move.
     - `sweep_test.sh`'s fake machine covers it, so it needs no guest.

126. **Done (CC, 2026-10-09): metal-vmm `0c7ee1b` (each client's file, `PEER_IN_TURN`), `0db9f88` (the sweep, `session-then-move`) (Questions, "item 126").** **Was:** **Every client's answer judged, not only the first** (the review's
     hole B again: state across requests). With `PEER_CLIENTS=2`, only
     client 1's page is compared; client 2's answer counts only as an
     excuse for client 1 (124(a)).
     - metal-vmm writes `PEER_BODY` for the first client only. Give each
       client its body (`PEER_BODY` as a stem, say).
     - Have sweep.sh judge each client against the same client in the
       unhurt run.
     - Add a shape where client 2's request depends on client 1's write
       (client 1 makes a game session, client 2 moves in it). A bug where
       request k damages request k+1 then shows.
     - The metal-vmm part is `net.zig`/`peer.zig` plus a unit test; the
       sweep part uses the fake machine. Split them if you'd rather.

127. **Done (CC, 2026-10-09 evening): all of (a)-(h) and the lesser one, red first (Questions, "item 127").** **Was:** **The cold review of 123-126 (the box, 2026-10-09 evening): three holes
     block the merge, four don't.** Your checks all pass; these get past them.
     Red first where you can.
     - **Blocking (a) `nightly.sh` never copies `tools/untouched.py`** (or
       the FAT reader) into `$OUT/bin`, where the night's sweep.sh looks for
       it. Every cut seed with stop leftovers would fail "No such file". The
       sweep_test stand-in (`UNTOUCHED=$T/untouched`) hides it; nightly_test
       should catch it.
     - **Blocking (b) 123 is still silence for any request with a body**
       (angry-gopher `router.zig:130`). `reader.state == .received_head`
       tracks reading, not whether a head went out: reading the body moves
       it on (the repo's own comments in chat.zig/login.zig say so), so an
       error after the body is read, such as `appendSessionLine` failing, is
       still answered with nothing. Track "a head was sent" explicitly. The
       red test needs a POST with a body.
     - **Blocking (c) `new-session`'s read-back fails falsely.** `GET
       /game/sessions/2/actions` is a 404 when session 2 was never made (a
       500 from a disk fault, a reset before the request arrived), and the
       verdict fails any read-back not 200. Accept the pristine read-back's
       status when the run wasn't told TOLD. The up-front recipe check never
       looks at that status.
     - (d) Too lenient: once client 1's answer differs, client 2 may answer
       anything, even a 500 with no disk fault. Narrow it to the unhurt
       answer, what "session never made" gives, or client 2's own excuses.
     - (e) Too lenient: a `PEER_RESET_AT` on client 1 excuses client 2's
       short or missing answer even when they are not in turn. A vanish
       holds the others back; a reset frees the guest at once, so this
       hides a reset that breaks another connection.
     - (f) Too strict: a lie is excused for the volume, but not a read-back
       500 caused by what the lie lost. Excuse the read-back's 5xx when a
       fired `VOLUME_CACHE=lie` lost something (the durable judge's rule).
     - (g) gopher-metal `3f17998` stays green under your proposed "merge
       toward allocated" fix, so it does not discriminate the decision.
       Fine as a pin; say so in its comment, or make it red for the fix.
     - **Blocking (h), from your 10-seed run on a guest (the box, 16:30
       UTC): `session-then-move`'s unhurt run answered `200,0`**, so the
       sweep stops (exit 2) before any seed, as designed. The cause is the
       one you guessed: the site's boot disk says `requests = 1`
       (gopher-metal.conf; "serving 1 request(s)"), so the guest stops after
       client 1. `two-clients`, held to `204` now, will stop the same way;
       it sorts later. Every other shape's unhurt run and read-back recipe
       came out as you derived them. A shape with n clients needs a site
       that serves at least n; how a shape says that is yours (a per-shape
       site copy with its conf raised, say). The single-client shapes'
       limit of 1 stays: it is what ends a run.
     - Lesser: untouched.py runs only when fsck reports leftovers, so a
       clean fsck after a cut never checks for lost files.

128. **Done (CC, 2026-10-09 evening): metal-vmm `9e6f952` (Questions, "item 128"); the per-disk line proposed (P128).** **Was:** **A broken "no damage" property is not excused by the rot that caused
     it** (the box, from the 2026-10-09 nightly, seeds 200728 and 201948,
     both `two-clients`, 2 failures in 44,400 seeds). `DISK_ROT=4093,20`
     (and `,52`) flips the high cluster word of a boot-disk directory entry.
     The kernel's disk check correctly counts 1 problem, and "fat: at boot /
     after a request, a volume has no damage beyond what a stop leaves"
     break. Verified: the same run without the rot shows 0 problems. The
     sweep excuses a page that rot changed, but no fault excuses a broken
     property (`sweep.sh`, "coverage properties broken").
     - Excuse only the damage properties (by id), only when a disk fault
       that writes damage (`DISK_ROT`, `DISK_TEAR`, `DISK_BAD_SECTOR`,
       volume equivalents) **fired** on that disk (124(e)'s `fired:`). Every
       other property break stays a failure.
     - The property's `details` say the damage count, not which disk.
       Saying so would let the excuse be per disk; that is a gopher-metal
       line (`gopher.zig` 1358/1417), yours to propose.
     - Red first with a fake seed.

129. **Done (CC, 2026-10-09 night): three fixes, red first, angry-gopher `d97c282`, `8377b5f`, `04e3913`; every site's verdict under Questions, "item 129".** **Was:** **Class hunt 1: a revoke or delete that fails quietly** (the box,
     2026-10-09 evening, after 127-128). The first of CC's class hunts, the
     new main work (essay "the plan after the postmortem", section 4; the
     list is the essay "questions to ask"). Walk every `catch {}` and `catch
     continue` in angry-gopher's `zig-server/src` (chat_store 22,
     chat_retire 18, users 13, uid_cookie 9, roots 8, login 7) and
     gopher-metal's served code, and ask of each: **does this call remove
     authority or data?** Where it does, a failure must not be answered as
     done.
     - **One instance, confirmed by the box:** `users.clearUserAPIKey` is
       `store.remove(...) catch {}`. Both callers (settings.zig:44,
       admin.zig:60) then redirect with `keyrevoked=1`, so a failed remove
       leaves the old key authenticating. Red test first (store_sim failing
       that remove, then the old key used).
     - Next lead: logout's release (`login.zig:250`) deletes the record
       even when `deleteUserData` failed.
     - Report every site, with its verdict: harmless, fixed (with a red
       test), or a policy question for Steve. Like 105: ship the dangerous
       sites first, and ask before a sweeping change.

130. **Done (CC, 2026-10-09 night): gopher-metal `efcfbe3`, both, red first; the decisions pulled out pure into `src/scsi_mode.zig`.** **Was:** **Two small ones from v21's release review** (the box, 2026-10-09;
     after v21, not in it). In gopher-metal `src/scsi.zig`:
     - `turnCacheOff` takes the caching page as 20 bytes, bounded by the
       512-byte scratch, not by what MODE SENSE returned (`got`). It also
       never checks `page[9] == 0x12`. A disk with a short or old page would
       be sent stale scratch bytes. Today that only ends in "would not turn
       off", which means flushing as before. Pass `got` and require the
       length.
     - When the reset recheck can't read MODE SENSE, `write_cache` becomes
       null but `cache_turned_off` stays true, so `/admin/host` says
       "turned off at boot". The data is safe; the line is wrong.
     Red tests first (store_sim or a scsi unit test).

131. **Done (CC, 2026-10-09 night): #2-#3 `624ac7f`, #6-#7 `b450132`, #11 `82470b1` (gopher-metal); #8 moved to the box, CC's `9576cb2` reverted in `e7d970a`, each red first (Questions, "item 131").** **Was:** **The kernel's facts: one place, one step** (the box, 2026-10-09
     evening; essay "kernel-facts", GitHub
     showell/essay-repl-server `notes/kernel-facts.md`). **Steve's focus
     today: the lower level.** angry-gopher is the reality check, not the
     only consumer; the kernel is judged by its own promises (STORE.md).
     A cold agent applied "one fact, one place, one atomic step" to
     gopher-metal. The box takes #1 (an atomic overwrite in `writeFileIn`)
     and #4 (leaks reclaimed at boot). Yours, each red first in
     `fat16_test`/`store_sim`, in this order:
     - **#2** `makeDirIn`: no rollback once the commit (`writeEntry`) is
       attempted; a failed-but-landed entry write must not free the
       directory's cluster.
     - **#3** `rename` / `unlinkEntry`: after the commit write, a
       `freeChain` failure is a leak, not the operation's error.
     - **#6** `allocChain`: give back a partial chain on every error, not
       only `Full`; `grow`'s fresh cluster needs an errdefer; count a
       failed give-back rather than swallowing it.
     - **#7** `fatSet`: on a failed FAT write, re-read the sector rather
       than assuming the old value; a second-copy failure is not the
       operation's failure.
     - **#8** the kept free count set from the boot check's count, and
       asserted equal per request in coverage builds.
     - **#11** (folds in 130's second bullet) the SCSI cache report derived
       from `write_cache` plus one "on at bring-up" bit, never a second
       stored fact.
     **Not #8 after all (the box, later the same evening):** the box takes
     #8 and #9 into a refactor of `Volume`'s held state (a `Held` part,
     derived from the disk at mount and, in coverage builds, derived again
     and compared after each request). Skip #8; the rest stands.
     Not yours yet: #5 (`removeTree` atomic) waits on #4; #9 and #12 are
     structural; #10 (503 on a failed flush) is Steve's call. The box's #4
     will make "commit, then sweepable cleanup" safe everywhere, so #3 and
     #6 may lean on it: say so in a comment rather than waiting.

132. **Done (CC, 2026-10-09 night): gopher-metal `9e7d8e9`, red first; with 131's counters on /admin/host (Steve: yes).** **Was:** **A reserve on the volume, for small writes** (Steve, 2026-10-09
     evening: "a little breathing room for emergencies"; for v22, after
     131). In gopher-metal's `fat16.allocChain`: keep a reserve, about
     64 MiB in clusters, capped at a small fraction of a small volume. An
     allocation that would leave fewer free clusters than the reserve is
     refused (`Full`) unless it is small (one or two clusters). So bulk
     writes (uploads, long appends) stop while small records, directory
     growth and `replace`'s temp copy, and since 935104f an overwrite's
     second chain, still work; removes always do. The kernel decides by
     size, so it needs no policy from the app.
     - Red first in `fat16_test`: on a nearly full volume a large write is
       refused while a small one still succeeds.
     - Check `fat_sim` and `store_sim`'s full-volume oracles still hold.
     - Say the reserve in the boot line and in `/admin/host`'s volume line.
     - The size: 64 MiB (Steve, 2026-10-09).

133. **Done (CC, 2026-10-09 night): gopher-metal `db1ade8`, red first; five tcp_sim crowd seeds no longer witness the ring (Questions, "item 133").** **Was:** **A duplicate ACK must name SND.UNA** (the box, 2026-10-09 evening, from
     a cold comment pass over tcp.zig; for v22). RFC 5681 §2 counts a
     duplicate only when its acknowledgement number equals the greatest
     acknowledged (`una`). `tcp.zig`'s count (the `dupacks += 1` arm in
     `acknowledge`) checks bare, same window, data outstanding, but not
     the number. So an older acknowledgement, or one for data never sent,
     counts toward a fast retransmit. The harm is small (`resent_early`
     allows one early resend per loss), but it is a departure we don't mean.
     Red first in `tcp_test` (three bare ACKs numbered below `una` must not
     resend); then the check; then remove the comment line the pass added
     saying it isn't checked.

134. **Done (CC, 2026-10-09 night): (a)-(c) `b810e98`, (h) `8134209` (gopher-metal); (d) `9e7d8e9`; (e)-(f) angry-gopher `14d964e`; (g) metal-vmm `8f8b431`; each red first (Questions, "item 134").** **Was:** **The cold review of 127-131 (the box, 2026-10-09 night): two
     blocking in gopher-metal, the rest after.** Verdicts: angry-gopher
     merge, metal-vmm merge, gopher-metal not yet. The box has merged your
     gopher-metal branch into its `next` (origin `next`, with the TCP
     comments, the FAT idioms and the `Derived` refactor); fix on your
     branch, and the box merges again. Red first; your `lands_and_fails`
     injector serves the re-read cleanly, so neither double fault is
     exercised today: give it a second failure.
     - **Blocking (a), `fat16.zig` `fatSet` (#7):** after a failed FAT
       write, the re-read goes straight into the held sector. If the re-read
       fails too, the device may have written part of it, and only the one
       entry is restored; the next `fatSet` in that sector writes the
       garbage to every copy. Read into `scratch`; copy into the held
       sector only on success; on failure the held sector is "not known".
       Say what the next change to it does.
     - **Blocking (b), `grow` (#2 against #7):** the link write lands and
       answers failure, the re-read fails, `fatGet(last)` says "not
       linked", and `giveBack(fresh)` frees a cluster the disk links from
       `last`. When the read-back can't tell, leak, never free.
     - (c) `allocChain`'s link write: lands-and-fails gives the candidate
       back, then the errdefer frees it again. The disk ends right, but
       "every cluster freed was in use" breaks falsely. If `previous`
       already points at it, leave it to the errdefer.
     - (d) `cleanups_failed` and `fat_copies_failed` on `/admin/host`
       (Steve: yes).
     - (e) angry-gopher `login.zig:255` (129): the auth tree removed, then
       `users_root` fails, gives a 500 for an account already released;
       nobody can log in to retry, and the folder leaks. Make the release
       finish, or say "released, with leftovers".
     - (f) angry-gopher `router.zig:205` sends `@errorName` to the client;
       a generic body instead, and the name to the log.
     - (g) metal-vmm 127(d): `UNMADE` is excused after any difference in
       client 1, even a page cut short after the session was made. Allow it
       only when client 1 got no answer, a 5xx, or a status not its unhurt
       one.
     - **(h), found since by a review of the box's `Derived` work:** in
       `fatSet`'s held path, a failed write replaces the WHOLE held sector
       with the disk's first copy, but `keepCount` moves the free count for
       one entry only. Where the sector differed elsewhere (a weighing that
       trusted the second copy and whose repair was refused; rot on the
       re-read), the kept count is now wrong, and the re-read quietly undoes
       that sector's weighing. Fix it with (a): move the count for every
       entry the copied sector changes. The box's new coverage property
       ("after a request, the kept free count is the FAT's", on `next`)
       will report it.
     - Note: `Expect: 100-continue` sets the "an answer went out" flag, so
       a later error is still silence. No worse than before; say whether
       it is cheap to fix.

135. **Done (CC, 2026-10-09 night): metal-vmm `f0dc9d8` (the draws; the plant moved up), `cd77816` (cannot_judge, FAILED_SEEDS); red first.** **Was:** **No seed refuses a write on the volume** (the box, 2026-10-09 night,
     from a pre-run review of `plants.sh`). `knobs.zig`'s `withVolume`
     draws none of `VOLUME_GONE_AT`, `VOLUME_READ_ONLY_AT`,
     `VOLUME_SHORT_AT`. So every night so far has never refused a
     production-shaped write, and a kernel that took a refused write as
     written (the pending plant `plants/pending/disk-write-swallowed`) would
     pass. Draw them (each in a fraction of seeds with a volume, aimed at
     the write requests of the write shapes), with the excuses the
     existing rules give: a 5xx after a disk fault that fired. With 125's
     read-backs, that plant becomes seeable: when both are in, move it to
     `plants/` and make `plants.sh` catch it.
     - Also, the reviewer's suggestion, yours if you agree: every "could
       not judge" in `sweep.sh` exits 2 through one function (today some
       preconditions exit 1), and the sweep ends with a machine line,
       `FAILED_SEEDS: 3 17 42`, which `plants.sh` and `nightly.sh` read
       instead of the human table.

136. **Done (CC, 2026-10-10): gopher-metal `a74cbd7`, `b467905`; 4m16s to 1m09s here, CPU 5m38s to 2m11s (Questions, "items 136-138").** **Was:** **`zig build test` in gopher-metal costs the box 530 s** (the box,
     2026-10-09, evening; Steve wants it fast before the next release
     run). It was 77 s at v18, then 162, 326, 446, 530; your container
     reports 3m07s, and the box has 2 cores. No test sleeps on wall time,
     so it is compile or run. Find which binaries dominate (`--summary
     all` gives each step's time; the box's gates now keep it in
     `test-summary.txt`) and make `test` cheap. The simulators' seed
     counts in Debug are the likely bulk, and `long.sh` sweeps them in
     ReleaseSafe anyway, so `test` may need only a few seeds of each plus
     every named regression seed. Lose no check that only `test` runs:
     say in the commit what moved where, and the before/after numbers.
     The box's goal: under two minutes there.

137. **Done (CC, 2026-10-10): angry-gopher `673e321`, `GOPHER_KEEPALIVE_MS` (Questions, "items 136-138").** **Was:** **A keepalive setting for angry-gopher's Linux server, for tests**
     (the box, 2026-10-09; Steve: "configure for tests"). The chat tab's
     keepalive is fixed at 25 s on Linux, so the judge's tab story waits
     27 s on each host. gopher-metal's kernel already takes `keepalive_ms`
     from its config. Give the Linux server the same knob (however its
     other test settings arrive), default unchanged, with a test that the
     setting governs. The box changes the judge to use it.

138. **Done (CC, 2026-10-10): (a)-(c) and (f)'s fat16 part gopher-metal `df1ef55`; (d) metal-vmm `be28b97`, `f9a74d9`; (e) and `tcp_test` gopher-metal `e9219ee`; (f)'s angry-gopher part `9dbafc5`; each red first (Questions, "items 136-138").** **Was:** **First: the cold review of 132-135, and check-cc.sh's first run**
     (the box, 2026-10-09 evening). gopher-metal is **not merged**: H1 is
     a data-loss path, and your branch no longer merges with master's
     `16494c3`/`315386e` (the free count is `derive()`'s now; the hint is
     apart): merge master in and re-express `keepCount`/`adoptSector`
     against it. angry-gopher merges. metal-vmm merges after (d).
     - **(a) H1, the blocker.** `adoptSector` (fat16.zig ~1404) copies the
       whole disk sector into the held FAT after a failed write's
       read-back, and the read-back is always copy 0. When the mount
       trusted copy 1 (copy 0 rejected, its repair refused), or the
       read-back is rot, every entry of the rejected bytes replaces the
       held ones: a zeroed entry under a file reads free, `allocChain`
       gives it to another file, and the next write of that sector
       spreads it to every copy. The held FAT stays the authority for
       every entry but the one in doubt: use the read-back for that one
       entry only (given back or leaked), never the rest. Red first:
       remount and check after the failure, not only the count
       (`then_garbage` passes while accepting the garbage).
     - **(b) H2.** Give a cluster back only when the read-back is exactly
       the value written (fat16.zig ~1611, ~1622, ~1807); a rotted
       nonzero read-back today sends `freeChain` into another file's
       chain. Anything else is a counted leak.
     - **(c) M4.** `fat_unknown_all` never clears: after nine double
       failures every FAT get and set fails until reboot. A re-read of
       the whole FAT that succeeds should clear it, or a per-sector map.
     - **(d) M2, metal-vmm.** A 5xx is excused by a volume refusal that
       fired anywhere in the run, a boot read included, so one seed in
       eight excuses the very bug class 135 hunts (an earlier refusal
       that breaks later writes). Excuse it only when the fault fired
       during that client's request. Also: `tools/site_requests.py` is
       mode 100644 and `sweep.sh` runs it directly, so check-cc.sh's
       first run could not judge `session-then-move` (exit 2):
       `git update-index --chmod=+x`.
     - **(e) M1.** The reserve is per call (`count > 2` clusters): many
       small appends spend it all, "small" is 1 KiB or 64 KiB by cluster
       size, and an overwrite that frees as much as it takes is refused
       near it. Threshold in bytes, and say (or count) what appends do.
     - **(f) Lows.** The uncached-FAT read-back failure assumes the old
       value (the comment says never); a first copy's failed write that
       landed leaves copies 1..n unwritten and uncounted;
       `tcp_test.zig:1321` `f.wire.count >= sent` should be `==`;
       angry-gopher 134(e): the authority file inside `auth_root/<id>`
       goes last too, and the test should not depend on how std's
       `deleteTree` walks; the swallowed-write plant is caught only by
       shapes with a read-back.
     - The box will run M3 (the new knobs on a guest, one batch) after
       (d), before any night.

**Overnight, 2026-10-09 → 10-10 (Steve: a large batch for CC; the box
finalized the design).** In order; each red first, each pushed as it lands.
**CC owns `disk_fat.zig`, `disk_fat_dirent.zig`, `tcp.zig` and `build.zig`
tonight: the box does not touch them until CC says it has stopped.** Merge
master first: the box's last disk_fat commits are `180462b` (NameTaken),
`e2dbde6` (fatSet's verdict), `e021bed` (copy 0 written again), and the
Mirrors enums. The design notes are in FEEDBACK, "the box → CC, night".

139. **Done (CC, 2026-10-10): gopher-metal `532b748`, `e07eaa6` (two leaks found, red first).** **Was:** **P139(a): the ledger for clusters taken before a commit**
    ([STATE_TRACKING.md](STATE_TRACKING.md)), with the box's notes in
    FEEDBACK. In short:
    - Four endings, not three: committed by the entry's write; **linked
      into a chain already committed** (`grow`'s link, an append's link,
      each a `Landing` from `fatSet` now); given back; a counted leak.
    - **Plant the bugs on today's code; don't revert.** `ec77f28`'s and
      `05b0cfb`'s lines were rewritten by `e2dbde6`, so a revert won't
      apply. Remove the give-back by hand and check the ledger fails.
    - Done when every public operation ends on the ledger's `always`, the
      faults tests pass, and both planted bugs fail at it.

140. **Done (CC, 2026-10-10): gopher-metal `ccd9f7b`, `1d28d4c` (native), `b87b68c` (review).** **Was:** **P139(b): `tcp.zig`'s `Fin` as a declared machine, with one
    `sometimes` per legal cell and an `unreachable` per forbidden one.**
    - **Fold `fin_ever_sent` into the state, and delete the bool**
      (Steve, tonight: "be pretty ruthless about booleans... enums are
      almost always more robust"). A FIN sent once and rewound is its own
      state (say `resending`), not `queued` plus a flag.
    - **Build the machine locally.** One helper in gopher-metal (say
      `src/machine.zig`, with its own tests), shaped so that moving it to
      the SDK later is a file move. The box's vote is in FEEDBACK.
    - **Add the lint**: the state field is assigned only inside `fire`.
      It can be a few lines in an existing tools script.
    - Then look at the sweep's report and say what it shows. Done when the
      planted forbidden transition fails `tcp_test`, and a deleted test
      shows up as an unhit cell.

141. **Done (CC, 2026-10-10): gopher-metal `5ab69b8` through `1b60b8a`, `465c194`, `417584d`; `peer_done` and `claimed` left for 144.** **Was:** **The rest of the boolean sweep in disk_fat** (Steve: enums over
    booleans; predicates such as `isEnd`, `inData` and `isDirectory` stay
    bools).
    - Already done by the box: `Mirrors` (`found`, `repair`), grow's
      `committing`, and `too_many`.
    - Left:
      - Lister's `loaded`, `done` and `long_ok`;
      - the long-name `long_ok` and `parts_overflowed`, in three places,
        plus `takeLongPart`'s `ok` in `disk_fat_dirent.zig` (one shared
        enum, say, for how a long name stands);
      - `writeInto`'s `fresh`;
      - `fsinfo_unknown`;
      - the visitors' `found` and `is_dir`;
      - the checker's `stopped_short`.
    - **Do this before or alongside 139**, since the ledger touches
      `fresh`'s lines.
    - Then the same sweep for `tcp.zig`, beyond `fin_ever_sent`.
    - One commit per struct or function, naming each conversion.

142. **Done (CC, 2026-10-10): gopher-metal `a345cd7`; 2m06s to 1m19s wall at -j2 (CC's measure).** **Was:** **Fewer test binaries** (your FEEDBACK `e87788d`; the box gives it to
    you, since nobody else touches `build.zig` tonight).
    - Measure first: a cold-cache `zig build test --summary all`, before
      and after.
    - Your FEEDBACK lists what to keep separate. Keep all of it: the
      `tcp_test` starts, the disk_fat binaries and their filters,
      `properties`, `store-judge`, `droplet/image.zig`, and `fat-coverage`'s
      binaries (or point `linecov.py` at the merged one).
    - Check `-Dtest-file` still works, and that one file's unreached site
      can't fail or hide in another's verdict.

143. **Done (CC, 2026-10-10, gopher-metal `a518cde`).** **Was:** **P143(a): named groups of states in `machine.zig`** (CC's FEEDBACK
    `3c751e6`; Steve and the box agree, 2026-10-10). A machine declares its
    groups beside its edges (`.groups = .{ .owed = &.{ .queued, .resending
    }, .numbered = &.{ .sent, .resending } }`), callers ask `in(.owed)`, and
    a comptime check makes every state say which groups it is in, so a new
    state is placed once. Replace the five `is(.a) or is(.b)` in `tcp.zig`
    and `tcp_check.zig`. Red first where it finds a miss.
144. **Done (CC, 2026-10-10, `d555892`; the finding: machine.zig cannot declare a relation between machines, tcp_check's rules are that relation).** **Was:** **P143(b): a connection's closing phase as a machine** (CC's FEEDBACK
    `3c751e6`; agreed 2026-10-10). Declare the peer's half (`open`,
    `finished`) as a machine in place of `peer_done`, and which (`State`,
    peer half) pairs may exist, checked after every `fire` of either. **It
    is the test of the abstraction:** if it reads well, it scales to a
    combined state; if it needs a product of machines or a relation checked
    outside them, write that up as the finding and stop. You may touch
    `probe/gopher.zig` and `ready.check` for it (the box hands them over for
    this item); say so in FEEDBACK when you start and stop.
145. **Done (CC, 2026-10-10, `7e5b09f`, `d951178`; the box's `161ad2a`: an undo when the unlink found nothing wrote the boot sector, red first).** **Was:** **A failed rename keeps its source where the disk says it can**
    (CC's FEEDBACK `da03f31`; agreed 2026-10-10). When rename's new entry is
    refused and its read-back says `before`, write `from`'s first byte
    back, undoing its tombstone; that write can fail too, so the promise
    becomes "a failed rename may lose `from`" (a crash between the writes
    still does, as the doc says). Update `store.zig`'s doc and STORE.md to
    match. Red first: a rename whose new entry is refused, `before`, then
    `from` still reads back whole.

146. **Done (CC, 2026-10-10, except (h); see 147).** **Was:** **The cold reviews of the overnight batch (139-142, B30, B33, B34,
    B36, B37)** (the box, 2026-10-10; merged to master at gopher-metal
    `a4271a7`, no blocker found; served code clean, no format change).
    Each red first where it is a bug:
    - **(a) A stale port turns `zig build test` red** (build.zig:226-240):
      `check` type-checks gopher.elf whenever a port and a checkout exist,
      but the asset list is port.sh's `gen/assets.zig` while the files are
      read from the live checkout, so an angry-gopher asset renamed since
      the last port fails gopher-metal's tests (and both mutation tools).
      Check against the port only when it matches the checkout (what
      `tools/verdicts.py` already asks), else say so and skip, loudly.
    - **(b) The mutation tools' verdicts can't count against you:**
      `mutate_tcp.py:186-187` scores a 600 s timeout as killed, and `zig
      build test` now analyzes every kernel; a mutant that did not compile
      leaves the exit code alone (`mutate_tcp.py:260`,
      `mutate_guards.py:216`), and `mutate_guards.py:211` tells killed from
      not-compiled by the substring "panic", which kernel compile errors
      can now contain. A timeout or a compile failure is its own verdict,
      and a not-compiled mutant fails the run. `mutate_guards` builds each
      of its 46 mutants in a fresh `--cache-dir` (:203), now with
      native and droplet: measure, and give the mutation runs a way past
      `check`.
    - **(c) `-Dtest-file` is no longer seconds:** `test` depends on `check`
      and the lint even then (build.zig ~284); one file's run should not
      analyze every kernel. Its comment promises seconds.
    - **(d) `linecov.py` exits 0 when a binary crashes** ("coverage is
      short", :120-133); with every file's tests in one binary a crash
      anywhere cuts the measure short silently. Fail it.
    - **(e) One process for every file's tests:** machine.zig's test calls
      `props.reset()` and swaps `on_broken`; a test that reads cumulative
      catalog hits now depends on order. Find any such test, or say none.
    - **(f) The ledger's `always` sites in ReleaseSafe:** the SDK exports
      every site, so a ReleaseSafe or `-Dcoverage` catalog lists `ended` and
      `balanced` as never evaluated. Does `long.sh`'s ReleaseSafe sweep or
      report.py call them SILENT or fail? Decide: register them only in
      Debug, or say why not.
    - **(g) `lint_machine.py` misses** a write through a pointer (`p.* =`)
      and a machine field typed other than `Name`/`x.Name`; braces in test
      strings and an unnamed `test {` give false refusals.
    - **(h) Reconcile 808 tests** with the ~210 `test` declarations in the
      unit files, from `--summary all`'s per-binary lines.
    - Known, not bugs: `remove` may return `WriteFailed` after the file is
      gone (store.zig says an error is not an undo); `cleanups_failed`
      rises in cases that used to leak silently.

147. **Done (CC, 2026-10-10, FEEDBACK "147 done"; gopher-metal `cf8c008`; merged at `53e0bfa` after a cold review, 884/885 on the box).**
    **The cold reviews of 143-146** (the box, 2026-10-10; merged to
    master at gopher-metal `161ad2a`, with the box's fix of the one served
    bug, a rename's undo of an unlink that found nothing). Each red first
    where it is a bug:
    - **(a) `mutate_guards.py` can report every mutant killed with nothing
      judged:** it never checks the unmutated tree is green first
      (`mutate_tcp.py` does), so a red test, a dirty untouched file or a
      lint/fmt failure kills every mutant; its last `else` (:227-228) calls
      any unrecognised non-zero exit "killed", and :225 calls a compiler
      killed by a signal (out of memory, 46 fresh `--cache-dir` builds on 8
      GB) a kill. Check the baseline first; an unrecognised failure is its
      own verdict and fails the run.
    - **(b) `mutate_tcp.py:197` knows only a compile error in
      `src/tcp.zig`:** one in `tcp_check.zig`, `tcp_sim.zig`, a test, the
      lint or fmt falls to "killed" (:199). The default is "unclassified",
      never "killed", in both tools.
    - **(c) The rename-undo test can't fail on its title**
      (`disk_fat_test.zig:2528`, "keeps exactly one file, under one whole
      name"): it never asserts `names == 1`, nor `counted > 0` when not; a
      file lost entirely, or under both names, passes. The test at :2490
      refuses only "under neither name", never runs `check()`, and never
      asserts a fault was injected.
    - **(d) `verdicts.py`'s `fresh` and `pair`/`ids` disagree** on
      `gen/assets.zig`, and `check`'s "NOT type-checked" line reaches only
      `test-summary.txt`, which gates.sh greps for `tests passed|error`:
      make gates.sh show it. gates.sh does not pass `-Dgopher-root`, so with
      `GOPHER_ROOT` set elsewhere `ids` and `check` judge different
      checkouts.
    - **(e) Timeouts in both tools kill only zig's parent:** test binaries
      may outlive it, and a child holding the pipe blocks `communicate()`.
      Kill the process group.
    - **(f) `lint_machine.py` misses** `|*m| m.* = ...`, an array element
      written by index with no `.` before it (its comment says caught), a
      type alias (`const FM = tcp.FinMachine`), a machine not declared as
      `machine.Machine(`.
    - **(g) A rename's refused tombstone that landed is not undone**
      (`disk_fat.zig` ~:2598): nothing else was written yet, so the same
      undo could keep `from`, the 145 promise where the disk says it can.
    - **(h) 146(h) still open:** reconcile the 808 tests.
    - **Noted, no change asked:** the ledger in the served kernel breaks
      only a site counter (`on_broken` is null and the sink unset outside
      `-Dcoverage`), so it is a check in coverage builds and sweeps, not in
      production; say so in its doc.

148. **Done (CC, 2026-10-10, FEEDBACK "148 and 149 done"; gopher-metal `0e737b8`).**
    **Exact accounting, across the kernel/judge boundary** (Steve, 2026-10-10;
    the essay: https://github.com/showell/essay-repl-server/blob/master/notes/where-the-bugs-are-now.md).
    The ledger made the kernel's own bookkeeping exact; gopher-metal
    `9c72d62`, `84e98ea`, `bc459b3` began the same for what it leaves on
    the disk (`leaked_clusters`, `orphaned_parts`, printed at a run's end),
    and metal-vmm's judge now holds fsck's findings to them
    (`counted_leak`, `632dc34`). Its first strict run found one uncounted
    leftover within the hour. **The goal: zero slack, every leftover
    counted exactly, and every judge excuse a comparison, never a blanket.**
    - **(a) Exact counts (absorbs the box's B41).** An `.unknown` verdict now
      counts its clusters as leaked though the write may have landed
      (`commitRefused`, grow's and append's `.unknown`), slack an
      uncounted leak can hide in. Say "left taken, may be live" apart from
      "lost", or settle unknowns at the next mount's check, so the judge
      holds fsck to the lost alone.
    - **(b) Proved on the host, not only on a guest.** In the faults tests,
      after every faulted operation, compare the volume's counters with
      what `Volume.check` finds (leaked clusters, orphaned long-name parts,
      anything else it reports): found must equal counted, not merely be
      at most. Red first wherever they differ. This is the check you can
      run; the box runs the judge's side.
    - **(c) Every leftover kind has a count.** List what `check` (and
      fsck.fat) can report after a failed write without a stop, and give
      each one a counter and an end-of-run line, or say why it cannot
      happen.
    - **(d) Each judge excuse ships with a plant it must not excuse.** For
      `counted_leak`: a plant that leaks a cluster without counting it.
      Write the patch (or, after the box's B39, the in-source plant) and the
      recipe; the box runs `plants.sh`.
    - **(f) Two uncounted leftovers on a rename, from the cold review of
      147** (both older than 147; `9c3190c` adds a route into the first):
      `undoUnlink`'s `.unknown` arm (`disk_fat.zig` ~:2557) keeps the long
      name's parts and counts none, so if the undo did not land they are
      orphans `orphaned_parts` never saw; and a tombstone whose verdict is
      `.unknown` is counted as 0 clusters (`unlinkEntry` ~:1852 calls
      `commitRefused(..., 0)`), and rename returns without `took`, leaving
      the chain lost and the parts orphaned, both uncounted (the comment at
      ~:2636, "Unknown is counted by the read-back", is not true). Red first,
      with (b)'s host comparison: found must equal counted.
    - **(g) `tools/mutate_run.py`:** `TEST_COUNTED` (:28-30) also matches a
      `0 fail` count, and `TEST_FAILED` any `error: '<x>' failed` line,
      the lint's included; both would call an unclassified run "killed".
    - **(e) TCP, as a design note only:** custody and debt are its
      bookkeeping already. Could the judge hold the wire to the kernel's
      own account of bytes owed and sent, as it now holds the disk to its
      counts? Write the idea in FEEDBACK; no code.

149. **Done (CC, 2026-10-10, same FEEDBACK).** **Every shape that writes reads back what it was told it kept**
    (the box's B40, given to CC 2026-10-10). metal-vmm's
    `requests/shapes/`: `register` gained a read-back today (`aa72cee`:
    registering the name again finds it "is taken"); `play`, `game-action`,
    `session-then-move` and `two-clients` still have none where they write.
    For each, find a request that reads the write back without a cookie
    the test can't know, whose pristine answer lacks the mark (read
    angry-gopher's handlers, as login.zig's "is taken" was found), and add
    `READ_BACK=`/`MARK=` with a comment saying where the answer comes from.
    You can't run a guest: write each as "derived, not yet run on a guest";
    the box runs `plants.sh` (the swallowed-write plant was caught in 1 of
    the 12 runs it fired in; the measure is that number rising).

150. **Done (CC, 2026-10-10, gopher-metal `99818c2`).** **virtio's `take` and ring sizes** (the box's B35, given to CC
    2026-10-10; served code). Its full text is under B35 in "The box: open":
    (a) a `fence()` between `take`'s volatile read of `used_idx` and its
    plain read of `used_ring` (read the ReleaseSafe disassembly of a caller
    first and say whether LLVM moves the load today; fence either way); (b)
    a `comptime` assertion that `Ring`/`Queue` sizes are powers of two;
    (c) decide the two minor ones there. Red first where a test can show it.
151. **Reported (CC, 2026-10-10, FEEDBACK "152 and 150 done; 151's report"; `zig build store-cost`): for Steve to pick.** **Why a chat send costs 38 disk requests** (2026-10-10; production's
    /admin/host: a send 222 ms, 218 ms of it 38 disk requests, ~5.8 ms each;
    `/chat/recent` 76 requests, 333 ms). On the host, count the disk
    requests each of angry-gopher's common operations makes through
    gopher-metal's store (a send, `/chat/recent`, a login, a game action),
    by kind: directory reads and writes, FAT, data, FSInfo, flushes. Then
    propose the cuts, each with its saving and what it risks (the folders
    cache's size, reads that could be answered from memory, writes that
    could be joined). Report first; build only what Steve picks.
152. **Done (CC, 2026-10-10, gopher-metal `725c0dd`, `7f48922`); the end line's form is in FEEDBACK.** **`orphaned_runs`: count orphaned long names as fsck.fat does**
    (Steve, 2026-10-10, from CC's 148 note). fsck.fat prints one "Orphaned
    long file name part" line per orphaned run (a whole name), and
    `counted_leak` holds those lines to P, which counts parts; so a counted
    3-part run leaves room for 2 uncounted runs. Count runs beside parts
    (exact and may be live, as 148 does), hold them to `Volume.check`'s
    runs in `countedIsFound`, and put them on the end line and /admin/host.
    Tell the box the line's new form here and in FEEDBACK; the box changes
    `counted_leak` to hold fsck's lines to runs, not parts. Red first: a
    test where parts and runs differ, which the parts-only count lets pass.

99. **Held until the box rebases angry-gopher's `request-door` onto master
    with `8b617f3c`** (it carries the same body pre-read): then attack it as
    the third bullet of the old 99 asked (`request.zig`, every handler behind
    it, `lint_portable.py`'s two rules, anything reaching past the door).

101. **Done (CC, 2026-10-08): C1-C5 under Proposed.** **Was:** your
     proposals when 106 and 108-111 are done.

(98 is done and merged. 102 needs KVM: it moves to the box's list.)

153. **151's cuts, the ones Steve picked** (2026-10-10: 1, 2, 3, 7 of your
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
154. **From the box's cold review of 150/152** (2026-10-10, revised):
    - (a) `Queue.setup` (virtio.zig): zero the whole ring before the device
      learns its address, `used_flags` and the event words too (the rings
      are `undefined`, and a stale NO_NOTIFY there would stop the doorbell).
      A margin, not a fix: your 150 report found the old order spec-safe.
    - (b) `writeEntry`'s orphan tombstoning (find it by name): it decrements
      `orphaned_runs`/`orphaned_parts` for an orphan this boot may never have
      counted, and drains the exact count before the unsure one. **No new
      state**: decrement only when an exact count from this boot covers the
      run (else leave the counts), unsure first where the run was unsure. The
      counts are the judge's accounting, never the data: a wrong one fails
      the judge falsely or passes it leniently.
    - (c) the end line prints `unsure_runs` and `unsure_long` apart, as U and
      V are; tell the line's form in FEEDBACK. **The box changes the judge's
      regexes** (floors: R - unsure_runs names, L - unsure_long clusters).
    - (d) **report, don't build**: whether a fragment the kernel's own check
      finds should count as damage. The box first reads production's
      `/admin/host` for fragments an older kernel left (it needs a release
      that reports them): if production holds one, damage would fail every
      boot's check.
155. **Search across every topic a person can see: the server side**
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

## The box: open

Each line's full text, with its history, is in the archive under its name.

- **B41, moved to CC as 148(a) (2026-10-10).** **Was:** (2026-10-10, a cold review of the box's judge changes): `leaked_clusters` over-counts, which is slack an uncounted leak can hide in.** Every `.unknown` verdict counts its clusters as leaked though the write may have landed: `commitRefused` (~1902-1923), grow's `.unknown => leftLeaked(1)` (~1696), append's `.unknown => leftLeaked(more)` (~2344); on a gone volume the read-back fails and is always unknown. The judge excuses fsck's reclaimed clusters up to that count (`counted_leak`), so a real leak of the same size beside an unknown passes. Make the count exact: say "left taken, may be live" apart from "lost", or have the next mount's check settle what was unknown, and judge only the lost.
- **B42, done (2026-10-10, gopher-metal `e4a7f3b`, `bdef1c2`, on master; a cold review's four fixes in; plants clean, 300 seeds).** Not yet released. Next of its kind: frees (a delete or overwrite still writes per cluster). **Was:** (2026-10-10, Steve: uploads are slower on metal than they were on Linux; after v22, red first): a chain's FAT entries written once per sector, not once per entry.** Production's `/admin/host`: a chat send took 222 ms, 218 ms of it 38 disk requests (~5.8 ms each: the volume is network block storage, its write cache off at boot). `allocChain` changes two entries per cluster (its end mark, the link to it), and `fatSet` writes the held FAT sector to each copy every time: about 4 writes per cluster. **Measured on the host (2026-10-10):** one 1 MiB file on 32 KiB clusters (production's, `droplet/build_volume.py`) with the FAT held: 143 disk writes, about 128 of them FAT (4 a cluster); at production's 5.8 ms a request, ~0.8 s a MiB on disk, ~90% of it the FAT. On 512 B clusters: 8,207 writes. Batched, ~15-20 writes a MiB: about 10x. **Build the chain in the held FAT and write each touched FAT sector once per copy before the commit**; the commit stays the directory entry, so a stop leaves what it leaves today. Red test: writing N clusters makes at most a fixed number of FAT writes per FAT sector touched. Keep the per-entry verdicts (`Landing`) and the ledger exact: a refused sector write now speaks for every entry in it. Measure first on the host (disk requests for a 1 MB file on a FAT32 test disk, before and after), then on a guest.
- **B40, moved to CC as 149 (2026-10-10).** **Was:** (2026-10-10): every shape that writes reads back what it was told it kept.** The first honest full plants run (metal-vmm `aa72cee`, gopher-metal `9c72d62`) caught `disk-write-swallowed` in 1 seed of the 12 runs it fired in: its earlier five "catches" were false alarms (the volume gone or read-only, judged unsound), and `register` had no read-back until `aa72cee`. Give `play`, `game-action`, `session-then-move` and `two-clients` read-backs where they have none (each its pristine answer without the mark), then measure the plant's catch rate again; a swallowed write that answers "saved" should fail wherever its write is one a read-back sees.
- **B39, done (2026-10-10, gopher-metal `c08dc9c`, metal-vmm `6b15df3`): plants in the source, `-Dplant=<name>`, `zig build check-plants`, dead plants fail.** **Was:** (2026-10-10, Steve: provisionally the box's, after v22): plants in the source, switched at compile time, as FoundationDB's BUGGIFY but decided at build: a plant is a few lines at its site behind `if (comptime plant == .<name>)`, `plant` one build option defaulting to `.none`, so the release binary holds none of it (the gates check it was built `.none`). It ends the patches' staleness (a plant moves with its code; a broken one is a compile error), `zig build check` type-checks every variant, and `plants.sh` builds `-Dplant=<name>` instead of applying `plants/*.patch`. A plant that fires in no run fails as dead, apart from "fired and never caught". **Against:** gopher-metal's source carries deliberate bugs (it reverses "never to merge"), and one more build option; Steve worries CC gets confused by too many, so the box builds it and CC is told only how to run it. **Why:** this week `net-goback-byte` went stale after CC's TCP refactor and `disk-write-swallowed` sat on a path no seed reached (0 of 311 runs), each found only on the box.
- **B38 (2026-10-10; BLOCKS v22, Steve): the FAT simulator got 67% slower since v21.** **Found (2026-10-10 morning):** not slower code, more work. The binaries run alone (no compile, under a light perf sample): v21 575 s, `b4463a9` 955 s, with the same profile (memset 38%, memcpy 9%, the same order below). `a74cbd7` (QUEUE 136) moved the tape-replay check out of `zig build test` into `properties` and scaled it to the FAT seed count (`@max(fat_seeds, 40)`), and each replay is two runs: 600 more runs at 300 seeds. With that loop removed, `b4463a9`'s sweep is 591 s compile and run together. **Decide (Steve):** the replays check the harness's determinism, not the FAT code; cap them at 40 seeds (what `zig build test` ran before 136) and the long tier gets its ~6 minutes back. Possibly the added instrumentation. The same 300 FAT seeds alone (`zig build properties` with every other seed count 0, ReleaseSafe, build included) took 600 s at v21 and 1,001 s at gopher-metal `b4463a9` (`~/b33/*.log`). Find the commit and the phase (the read-backs, the reserve's 8,304 refusals, the checks), then decide whether it is paid for.
- **B37, done (CC, 2026-10-10, gopher-metal `cb34a59`; its review's bug `53265d9`, red first).** **Was:** (2026-10-10, the cold survey in B35; refactor) TCP's sequence arithmetic in one small module, tested exhaustively.** The modular idiom is written four ways in `tcp.zig`: `after` (:1196), `ahead` (:310-312), `acknowledge`'s `advance > flight` (:878-883), and the inline `(c.rcv_nxt -% seq) < (1 << 31)` (:1061, which is `!after(seq, rcv_nxt)`). A `seq` module generic over the integer type: `after`, `offset(from, to) = to -% from`, `within(x, base, len)`. **Tests:** a u8 instance, exhaustive: `after` irreflexive and antisymmetric away from the half-range point, invariant under shifting both by any k; `within` agrees with a brute-force walk of `len` steps from `base`. CC owns tcp.zig tonight.
- **B36, done (CC, 2026-10-10, gopher-metal `2c70dcc`, `a4271a7`).** **Was:** (2026-10-10, the cold survey in B35; refactor) one byte-ring helper, tested exhaustively.** `log_ring.zig`'s `Ring` (overwrites the oldest) and `serial.zig`'s console backlog `pend` (refuses when full) are the same shape, each splitting at the seam by hand (`log_ring.parts` :103 and `read` :136-147; serial `put` :69 per byte, `drain` :107-113). Extract a pure `pieces(cap, start, len)` returning the up to two contiguous ranges from a free-running u64 position. Then the log ring keeps only `total` (`head` is always `total % len`, today redundant and unchecked, and `kept_log.valid()` checks `head < slot_bytes` but not that it agrees with `total`), and serial's `pend_at`/`pend_len` become free-running `written`/`drained`. **Tests:** exhaustive over cap 1..9, start 0..3·cap, len 0..cap (the lengths sum to `len`; the pieces concatenated are exactly `(start+i) % cap`; the second is empty iff no wrap); then each ring model-checked against a plain deque on random write/drain sequences. Not virtio's rings (the spec's layout, shared with the device), nor TCP's `rx`/`tx` (linear on purpose: the parser and `emit` want one slice), nor the revival ring.
- **B35, moved to CC as 150 (2026-10-10).** **Was:** (2026-10-10, a cold survey of the ring-like code; after v22, served code, red first): virtio's `take` and ring sizes. (a) `virtio.zig:509-514` `Queue.take` reads `used_idx` through a volatile pointer, then `used_ring[last_used % size]` with a plain load and no `fence()` between: the spec wants a read barrier there, and LLVM may hoist the plain load above the volatile one, so a completion just published can be read stale (wrong `id`/`len`). Suspected, not seen: x86 does not reorder loads, so it takes the compiler; read the disassembly first, then fence. (b) `Ring(size)`/`Queue(size)` never assert `size` is a power of two, and `avail_idx % size`, `last_used % size` stay right across the u16 wrap only if `size` divides 65536 (today 4, 8, 64 do): a `comptime` assertion. (c) Minor: `Queue.setup` zeroes `avail_idx`/`used_idx` after writing queue-ready (`virtio.zig:470-472`), backwards though harmless; `serial.keepIn` (`serial.zig:202-207`) resets `total`, so `lost()` forgets bytes lost before a restart. Decide each.
- **B34, done (CC, 2026-10-10, gopher-metal `13a7a98`, `aaf30bc`): `zig build check`, run by `zig build test`; gopher.elf against the real port (a stale port fails it: re-run `port.sh`).** **Was:** (2026-10-10, Steve: structural) every kernel compiles on every change.** `zig build test` never compiles `gopher.elf` or the native kernels, so a renamed field broke each without a red test: `b4463a9` (Mirrors, in `probe/gopher.zig`; the v22 gates caught it) and CC's Fin enum (`native/serve.zig`). Make `zig build test` (or one quick `zig build check` that every rule names) type-check every kernel, Debug, well under a minute. For CC, who has no `port.sh`: build `gopher.elf` against a small stub app when angry-gopher's port is absent, so a kernel API break shows on CC's side too. CC owns build.zig tonight; it fits beside 142.
- **B33, done (CC, 2026-10-10, gopher-metal `91038e9`, `bf41cd1`; 900 reaches over the 300 seeds, 0 before).** **Was:** (2026-10-10, the v22 run) the long tier's floor misses "fat: a FAT32 entry's first cluster is past 65535"** over its 300 FAT seeds, at gopher-metal `b4463a9`. v21's long tier reached it. Find which commit since v21 moved it (the FAT work: NameTaken, M-a, L-a, L-b, the Mirrors enums) and whether the simulator stopped reaching the case or the code stopped having it. v22 waits on this, along with `17eb459` (gopher.elf did not build at `b4463a9`). **Found (2026-10-10 night):** the 300 FAT seeds alone reach it 23,764 times at v21 and never at `b4463a9`, where the reserve refused 8,304 large writes: the reserve (`9e7d8e9`, after v21) stops large files about 1,000 clusters short of 65,535 on `test_disk.small32` (68,874 clusters, reserve 4,304). **Tried and not enough:** large files every other step clamped to 64 KiB after the first refusal (`~/b33/option1.patch`, not committed) still never reached it. Next: count how far into the reserve FAT32 filling runs get (few seeds are FAT32 and filling, about 1 in 16), before choosing the fix. Worktrees `~/b33/wt-*` keep each side's built sweep binary for B38.
- **B32 (2026-10-10, Steve; after v22): weigh a compile-time off switch for the coverage SDK**, as Antithesis's SDKs have one (Go's `no_antithesis_sdk` tag, C++'s `NO_ANTITHESIS_SDK`, Rust without `full`). Today the served kernel records every property on every call, and nothing there reads the counters. A plain property costs a few instructions and a store; a numeric comparison also works out its edge and reach on every call. Measure that first, with one hot-loop benchmark with the SDK on and off. **Against it:** the kernel the gates judge would not be the one served; `/admin/host` could someday show the properties broken in production; a condition with side effects still runs. Steve leans toward mostly what Antithesis does, with those concerns weighed.
- **B31 (2026-10-09, Steve's open question): a `gates.sh` line that fails when `zig build test` exceeds a time budget**, so the suite's cost can't creep back up (530 s at v21; 194 s after 136; 3m19s on the box tonight). Wait for 142's number, then decide the budget with Steve.
- **B30, done (CC, 2026-10-10, gopher-metal `629b576`, 27 remade).** **Was:** (2026-10-09) `tools/mutate_guards.py`'s 21 FAT mutants are stale.** Their anchors predate the guard rewrite and the rename to `disk_fat.zig`, so they no longer apply. Make them again against today's code, or delete the ones the faults tests now cover by name.
- **B29 (2026-10-09, found moving the slow-reader gate): stray resets after a reader that paused.** A client that shuts its window for 2.5 s mid-page (`PEER_SHUT_AFTER=4096 PEER_SHUT_FOR_US=2500000`, the 231 KB `requests/big-page.http`) gets the whole page, but the guest's tcp line then counts 8 strays reset (none unhurt), with 4 timeouts resent. Something reaches the guest for a connection it no longer holds: either the peer keeps talking after it is done, or the guest forgets a connection the peer is still owed (TIME-WAIT's ACK, say). Find which, from a frame trace; a peer fault is fixed here, a guest one becomes a red test in gopher-metal.
- **B28, done (2026-10-09, metal-vmm `a92ca03`, gopher-metal `21b1e47`): the coverage door.** A coverage boot is now 6,660 exits to the release kernel's 6,256, with the same page. `nightly.sh` takes `KERNEL_ELF` and `PEER_REQUEST`. **Was:** the sweeps judged no coverage property (found 2026-10-09).
  `sweep.sh` and `nightly.sh` run gopher.elf as a release builds it. Its
  properties are recorded but never written out ("201 runs, 0
  properties"), so a broken Always in a sweep is unseen unless it also
  changes the page or the exit. That includes fat16's per-request damage
  check, which runs only with `-Dcoverage`. long.sh uses a -Dcoverage kernel
  apart from the one it judges, because printing the catalog costs a boot
  about nine seconds of guest time. The fix to look at is a coverage line
  that costs the guest no time: one `rep outsb` per line to a port metal-vmm
  answers without moving the clock. Then a sweep could judge pages and
  properties on one kernel.

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
- **B23, done (2026-10-08): the peer sent the first 8,192 bytes.**
  `PEER_REQUEST` files were read into an 8 KiB buffer, once, and a longer
  one was silently cut: the guest waited for the rest of a head that never
  came, and let the client go. `readAll` now reads to the end and refuses a
  file over 2 MiB by name. A 17,000-byte head gets 431 at every `PEER_MSS`,
  as under QEMU and on Linux. (Yesterday's "10 to 13 KB" was misread: the
  peer released 8,192 bytes, all of them acknowledged.)
- **B24, done (gopher-metal, long.sh):** every judged boot of the lossy
  sweep and the rough peers has a volume attached, and a 100-seed sweep with
  `VOLUME_SITE` must end with none failed. The durable sweep (a post, then a
  cut) still needs a session cookie to run with the real kernel.
- **B25, done (gopher-metal c7539eb):** boot tries a read three times;
  serving, once. **B26, done (d7a5903):** FAT copies apart, the cleaner is
  the FAT, the first on a tie. Seeds 1-50 with a volume: 0 failed.
- **B27, done (gopher-metal 4ed59ba):** the member story downloads a topic
  of the longest name on both hosts. With it came angry-gopher 8b617f3c: on
  Linux a body sent after its head was read over the head (my c21d39c4), so
  POSTs were routed by their bodies' bytes (404s, lost messages, a panic).
  **angry-gopher's `request-door` branch carries the same pre-read: take
  8b617f3c when it is rebased for v21.**
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

- **(CC, items 136-138)** Master is merged into all three branches
  (gopher-metal through `a88f456`). Every gopher-metal check below ran
  against zig-coverage-sdk `c7baca9` (on_broken).
  - **138(a) H1 (`df1ef55`):** whole-sector adoption is gone (adoptSector,
    knowSector, `fat_unknown`). After a failed write of the first copy,
    `landed()` reads the sector back into scratch and looks at the **one
    entry in doubt** only. Exactly the old value: not landed, and the held
    entry is put back. Anything else (the new value, rot, or a failed
    read-back): taken as written. The held FAT stays the authority for
    every other entry. Red: a rotten read-back (`then_garbage`), then
    write on, remount and check. Copies 1..n are then written from the
    held sector (`writeCopies`), so (f)'s "left unwritten and uncounted"
    is gone too.
  - **(b) H2:** a cluster goes back only when the read-back is exactly
    the value written (`isEnd` for an end mark). Anything else is a counted
    leak (`leftLeaked`, `cleanups_failed`). Red: the FAT on the disk, two
    rotten read-backs, a neighbour's file checked whole.
  - **(c) M4:** gone with the not-known machinery: nothing is left
    "unknown" to clear.
  - **(d) M2 (`f9a74d9`):** metal-vmm's `reports.During` marks, before each
    entry to the guest, the disk and volume faults whose counts moved,
    against every client then between its open and its last answer. It
    prints `metal-vmm: fired during client k: ...`, and sweep.sh excuses a
    5xx only by a fault on that line. A client opened and waiting behind
    another is marked too, so it errs toward excusing. Red: fake seed 58
    (a volume refusal at boot, then a 500). **Not run on a guest** (no
    KVM here): your M3 batch is the first to print the line. Older
    metal-vmm builds print no such line, so against one every 5xx now
    fails.
  - **(e) M1 (`e9219ee`):** the reserve is judged in bytes by the file an
    allocation makes. Small is 64 KiB (`small_bytes`) whatever the cluster
    size. An append counts its file's size after, so a log grown a cluster
    at a time is refused at the reserve like one write of it. An overwrite
    counts what it leaves once its old chain is freed (counted from the
    old size, a lower bound), so one that frees as much as it takes goes.
    A directory's growth is always small. Red: all three, on both shapes.
    The 132 test now says its sizes in bytes.
  - **(f):**
    - `tcp_test`: `==`, and it holds.
    - **angry-gopher (`9dbafc5`):** `users.removeAccount` removes every
      other file in `auth_root/<id>`, then the password, then the folder.
      The release and the retire both use it. The test refuses each of 30
      files in turn by name (std's deleteTree asks by name alone). The
      old walk was red here, as `password` is last in this disk's order
      only one time in 31.
    - **The swallowed-write plant** is caught only by shapes with a
      read-back: noted, nothing changed.
  - **137 (`673e321`):** `GOPHER_KEEPALIVE_MS=<ms>` in the server's
    environment, as its other settings arrive. Unset keeps 25 s; 0 or not
    a number refuses to start. The test times an empty subscriber at
    200 ms. gopher.elf still builds through port.sh (bus.zig gains a
    `pub var`; the kernel still reads `keepalive_s` for its default).
  - **136 (`a74cbd7`):**
    - **Before:** 4m16s here (CPU 5m38s). fat_sim's run was 150 s, of which
      135 s was its 40-seed tape replay. store_sim's was 55 s. The three
      fat16 binaries' ReleaseSafe compiles were 72 s.
    - **After:** 1m09s (CPU 2m11s). The replays are `replaysExactly`: test
      runs one seed, properties 40 (fat) and 20 (store) as named alwayses.
      fat_sim's plain and probe seeds go from 1..8 to 1..2 (properties:
      1..20). store_sim's go from 1..20 to 1, 2 and 5 (5 kills mutant S4;
      properties: 1..1000). The cached-disk test stops at its first break.
      fat16_test, fat16_faults_test and fat16_lies_test build Debug.
    - **Mutants:** S4, S10, F5 and F9 are each re-checked killed.
    - **Estimate for the box:** your 530 s was about 1.6 × my CPU time, so
      expect about 3.5 minutes. That is short of your two. What is left:
      about 50 binaries at 1 s of compiling each, and runs of fat16_faults
      16 s, fat16_test 11, fat16_lies 11, store_sim 12 and tcp_sim 10 (its
      named regression seeds). The next cut would be the stops test's
      shapes or merging test binaries; neither is done, as each loses
      something or moves more than 136 asked.
    - **properties now costs about 2 more minutes in Debug** for the 60
      replays (long.sh builds it ReleaseSafe).

- **(CC, items 132-135)**
  - **132 (`9e7d8e9`):** `Volume.reserve_clusters` is 64 MiB of clusters
    or a sixteenth of the volume, whichever is less, set at mount.
    allocChain refuses (`Full`, before taking anything) an allocation of
    more than two clusters that would leave fewer free. The boot line says
    the reserve. /admin/host's volume line says it, and 131's
    `cleanups_failed` and `fat_copies_failed`. The judge's "N MB free of
    M MB" still reads it (test_judges passes). The full-volume oracles in
    fat_sim and store_sim hold.
  - **133 (`db1ade8`):** a duplicate now needs `number == una`. **Worth
    your eyes:** five of item 24's crowd seeds (1733, 6918, 7374, 7968,
    9728) now pass with the revival ring off. Each had failed by exactly
    such spurious fast retransmits, so they left `crowd_red`, with a
    comment. 16 crowd seeds and all 14 rough seeds still need the ring.
    The comment line 133 says a pass added is not on master's tcp.zig;
    there was nothing to remove.
  - **134:**
    - **(a)-(c) (`b810e98`):**
      - A failed held-FAT write's read-back goes into scratch, and is
        copied in only if it came.
      - A sector whose read-back fails is **not known**
        (`Volume.fat_unknown`; past eight, every sector is). **The next
        change to it:** fatGet or fatSet there reads it from the disk
        first and fails if that read fails, so no decision rests on an
        unknown value, and no failed read's bytes reach a copy.
      - grow's read-back failing is now an error: a leak, never a free.
      - allocChain reads its link again after a failure. Linked, the
        errdefer's chain frees it. Not linked, it goes back alone. Not
        known, it leaks.
      - Red, with virtio's `then_fail` (the next N requests fail, a read
        first scribbling its buffer): /data broken on the same mount;
        grow's double fault; "every cluster freed was in use" broken
        (counted from a coverage.reset per run).
    - **(h) (`8134209`):** `adoptSector` moves the free count entry by
      entry for whatever the disk's bytes change, both in the read-back and
      in knowSector. Red with `then_garbage` (a rotten read-back): the
      kept count was 8092 against the held FAT's 7840.
    - **(d):** done in `9e7d8e9`.
    - **(e) (angry-gopher `14d964e`):** deleteUserRecord removes users_root
      first and auth_root last. A failure leaves an account that logs in
      and can be released again. Red: removals refused under users_root.
    - **(f):** the 500's body is "The server failed."; route still returns
      the error for the host to log.
    - **(g) (metal-vmm `8f8b431`):** UNMADE opens only after a client
      whose write is in doubt: no answer, a 5xx, or another status. Red:
      fake seed 57, a page cut short under its own 200.
    - **The 100-continue note: cheap.** `Sent` would keep its first 25
      bytes and a count, and answerFailure would still answer when all
      that went out is `HTTP/1.1 100 Continue\r\n\r\n` (a final
      response may follow a 100). About ten lines; not done, say if you
      want it.
  - **135:**
    - **The draws (`f0dc9d8`):** one seed in eight with a volume draws one
      of `VOLUME_GONE_AT`, `VOLUME_READ_ONLY_AT` and `VOLUME_SHORT_AT`, at
      a command from 1 to 250. They are drawn last, so every earlier draw
      of every seed is unchanged. "Aimed at the write requests" is only as
      good as that range. A guest run's volume line (N reads, M writes)
      would let you narrow it.
    - **The plant:** disk-write-swallowed moved to `plants/` (it applies
      at gopher-metal's branch and master). plants.sh is not run here.
    - **The suggestion (`cd77816`), taken:** every "nothing can be judged"
      in sweep.sh exits 2 through `cannot_judge` (28 sites; some exited 1
      before). The sweep's last line is `FAILED_SEEDS: ...`, which
      plants.sh and nightly.sh now read.

- **(CC, item 131) The kernel's facts.** All in gopher-metal, each red
  first in fat16_faults_test, fat16_test or scsi_mode.
  - **A new fault kind**, `lands_and_fails` (virtio.zig, the disk in
    memory): a write lands whole and answers an error. A new test runs it
    at every request of every operation.
  - **#2 (`624ac7f`):** makeDirIn undoes nothing once its entry's write is
    asked. Red: "make a directory" left /data broken, its cluster freed
    under an entry that landed.
  - **#3 (`624ac7f`):** after the commit (the short entry cleared in
    unlinkEntry; the entry repointed in rename over a file, and in **your
    #1 overwrite**, whose doc comment left this to #3), freeing the old
    chain or clearing long-name parts is `afterCommit`. Its failure is
    counted (`Volume.cleanups_failed`) and said by a property; it is never
    swallowed and never the operation's error. The failed-request test
    now holds that done is said of what is done, and only of it: answering
    done means the finished outcome, and the finished outcome means
    answering done. Red on replace, remove and rename over a file, each
    shown alone. The stop test goes on past a done-with-a-leak.
  - **#6 (`b450132`):**
    - allocChain gives back its partial chain on every error (an
      errdefer), and on its own a cluster marked and not yet linked.
    - grow's fresh cluster and a new file's chain go back on a failure
      before their commit. writeEntry now marks the commit at the entry's
      own write (`committing`): its read before that write had counted as
      the commit, and leaked.
    - grow reads its link again after a failed write and gives back the
      cluster when the link did not land.
    - Every give-back that fails is counted, never `catch {}`.
    - Red: a new test fails every request before a new file's commit on
      FAT16, with and without its directory growing; no cluster may leak.
  - **#7 (`b450132`):**
    - The first FAT copy decides. A failed write of it is the caller's
      error, and the sector is read again for what landed (and for the
      kept count), never assumed old.
    - A later copy's failure is counted (`fat_copies_failed`) and left for
      the next mount to bring into line; it is not the operation's
      failure. Before, it failed the operation with the first copy
      already changed, so an allocation never learned it had taken that
      cluster: #6's red at request 9.
    - The lands-and-fails test now holds the FAT in memory to the disk's.
      Red: the kept free count was one off.
  - **#8: the box's now (Held refactor); CC's `9576cb2` is reverted in
    `e7d970a`, kept here for what it found.** `Health.free` is the check's count of the free
    clusters in the FAT the machine uses; the check already counted it for
    FSInfo. At boot, diskCheck sets `free_clusters` from it, and an Always
    says whether mount's count agreed. After every request, in a coverage
    build, an Always holds the kept count to the check's. Both are seen
    only on a guest; neither is run here. **A thought for the sweeps**:
    rot on a FAT sector's read at mount could put the two counts apart
    and break the boot property. If a night shows that, it belongs with
    128's damage excuses.
  - **#11 (`82470b1`):** `cache_turned_off` is gone. virtio.Block keeps
    `cache_on_at_bringup` (one bit), and `scsi_mode.report` derives what
    the boot line and /admin/host say from it and `write_cache`. A recheck
    only sets `write_cache`, so 130's `sensedNotOn` went with it.
  - **Leaning on your #4:** #2, #3 and #6 leave a leak where a write
    landed or failed unknowably. Each comment names the boot's reclaim
    (#4) as what clears it.
  - **A trap found on the way**: a test in fat16_faults_test whose name
    matches neither binary's filter (build.zig) never runs, and says
    nothing. Mine didn't run at first; both new tests are in the filters
    now. A check in build.zig that every test name matches a filter would
    close it; yours, if you want it.

- **(CC, item 129) Every `catch {}` and `catch continue`, asked "does this
  remove authority or data?"** 78 sites in angry-gopher's served
  `zig-server/src` (tests, stress, benches and probes left out; `else |_|
  {}` counted too), 15 in gopher-metal. **Three fixes, each red first**
  through a test Io whose file removals are refused (`AccessDenied`; std's
  `failingDirDeleteFile` answers `FileNotFound`, which the store rightly
  reads as "already gone").
  - **Fixed, `d97c282`: `users.clearUserAPIKey`** (users.zig:330). It
    returns its error, and both callers (settings.zig:44, admin.zig:60)
    `try` it. A refused revoke is a 500, never `keyrevoked=1`; an absent key
    is revoked already.
  - **Fixed, `8377b5f`: logout's release** (login.zig:250), and under it
    `storage.deleteUserData` (its `removeTree` was itself `catch {}`, so
    admin_lynrummy's delete, which answers an error 500, never got one),
    `users.deleteUserRecord` (both trees `catch {}`; auth_root is the
    account's authority) and `player.deleteRecord`. All return their errors
    (deleteTree takes a missing path as removed). The release goes data
    first, then record, so a failure keeps the account and its name to be
    released again.
  - **Fixed, `04e3913`: the admin's retire** (chat_retire.zig:90, 95, 208,
    211, 250, 265, 313): every topic, sidecar, user tree, DM and channel
    line. A confirm on a refusing store reported them all removed while the
    users went on logging in. Each error now ends the confirm (the admin's
    page is the router's 500). **A removed user's `auth/<id>` now goes
    last**, after everything else of theirs: the roster is read from
    auth_root, so a failure before it leaves the user listed, and a second
    confirm finishes the job. Before, auth went first, and a failure after
    it orphaned the rest where no confirm could find it.
  - **Harmless, removes nothing that holds authority or data:**
    - chat_state.zig:121, an unpin. Its failure shows: the page renders
      the pins from disk.
    - roots.zig:89, the old copy of a migrated secret. It goes only after
      the new copy reads back equal, and the next startup retries.
    - store.zig:377, a temporary after a refused rename. The rename's
      error is returned.
  - **Harmless, writes or work that recomputes or retries:**
    - chat_store.zig:184 (`.lastauthor`) and :725 (`.count`): sidecars,
      recomputed next time.
    - chat_state.zig:58, :61, :132: last-session and pin pointers.
    - users.zig:248 `touchUser`, player.zig:109 `mirror` and :176 `touch`:
      activity stamps and the player name mirror.
    - login.zig:323: the welcome message.
  - **Harmless, best-effort broadcasts** (each marked absent-ok, or
    formatting an event): chat_store.zig:340-389, presence.zig:97-110 and
    login.zig:298-303.
  - **Harmless, other:**
    - **Admin counts:** admin_lynrummy.zig:191, :212, :217.
    - **Parses and joins that skip one entry:** chat.zig:458,
      chat_retire.zig:227, storage.zig:226, chat_sse.zig:173, :176,
      session_meta.zig:123, recent.zig:141, and roots.zig:75-86 (the
      migration, absent-ok).
    - **I/O on a reply already failing:** server.zig:170, :171, :194,
      chat_upload.zig:196, router.zig:164, :206.
    - **Plumbing:** bus.zig:123 (a futex wait), driving.zig:40 (a
      deliberate leak build).
  - **gopher-metal, all harmless:**
    - **Request and check plumbing:** gopher.zig:812-813 (the 431),
      :1349-1357 (the damage check's skip).
    - **Cleanups after an error already returned:** fat16.zig:1394 and
      :1905 (clusters given back), store_fat.zig:135 and
      store_linux.zig:182 (a temporary), and scratch_dir.zig:33.
    - **Not served:** pages.zig:513 (a test).
    - Metal's own `deleteFile` (io.zig:787) and `removeTree`
      (fat16.zig:2358) pass every error but absence up, so the fixes above
      reach the image.
  - **Two stale comments, yours to change:** io.zig ~784 and fat16.zig
    ~2340 say "the application spells every call `catch {}`". Since these
    fixes it no longer does: revoke, release and retire each `try` it.
  - **No policy question for Steve**: every dangerous site had one right
    answer, a failure is not done.

- **(CC, item 128) The damage the disk was dealt excuses the kernel's
  "no damage" break, and nothing else does.** metal-vmm `9e6f952`.
  - Each run's broken properties are read from its own coverage lines (a
    must-hold one, hit, condition false). A break is allowed when every
    broken property is one of the two "fat: ... no damage beyond what a
    stop leaves" and `DISK_ROT`, `DISK_TEAR` or `DISK_BAD_SECTOR` fired, or
    a lying cache lost what it held. `VOLUME_SHORT_AT` is not one: a legal
    underrun a driver must handle.
  - **Such a seed's false damage events are left out of the merged
    report**, and the sweep says which seeds; their own coverage files
    keep them. Without that, the excused break still failed the sweep
    through report.py's FAIL line, and the night's failures.log.
  - Red: fake seeds 53 (allowed, and the report passes), 54 (another
    property too: FAIL), 55 (rot drawn, never fired: FAIL).
  - Either disk's fault excuses either disk's damage: P128 proposes the
    line that would make it per disk.

- **(CC, item 127) The cold review's holes in 123-126.**
  - **(a)** metal-vmm `b0e30fc`: nightly freezes `untouched.py` and the FAT
    reader (`FAT_READ`, else `$GOPHER/tools/fat16_read.py`) into the
    night's bin and names both to the sweep. sweep.sh asks `untouched.py
    --ready` before any seed and exits 2 when the reader does not load, so
    the gap is said once, at the start. nightly_test was red: every batch
    failed.
  - **(b)** angry-gopher `c56f345`: route lends the handler a writer of its
    own in place of the connection's (`Sent`: a 1 KiB stack buffer, every
    byte passed through, the protocol's chunk headers formatted in it as in
    the connection's). It notes whether any byte was written, and gives
    the connection's back, its buffer passed on unflushed, before the host
    flushes or serves a kept stream. The 500 goes out only when no byte did.
    Red: a move whose `actions.dsl` is a folder (the append fails after the
    body was read) got nothing. A handler that answered and then failed is
    not answered twice. Through the port, locally, gopher.elf builds.
  - **(c), (f)** metal-vmm `0662122`: a read-back not 200 passes when the
    run was not told TOLD and the pristine volume's read-back answered the
    same (`new-session`'s 404). Told, it must still be 200 and hold MARK. A
    read-back 5xx after a fired `VOLUME_CACHE=lie` that lost sectors is the
    lie's ("VOLUME_CACHE=lie (the read-back failed, 500)"), in a durable
    shape and the POST sweep alike.
  - **(h)** metal-vmm `eed1a41`: a shape of n clients asking k times boots
    from a copy of the site whose `gopher-metal.conf` says `requests = n x
    k` (`tools/site_requests.py`), and says so ("shape two-clients: the
    site raised to 2 requests"). The number is written over the old one's
    digits, padded with spaces the parser trims, so the file keeps its
    length and no entry, cluster or FAT changes; more digits than were
    there, or no `requests` line, is refused. Soundness and untouched files
    are judged against that copy; the repeat line names it, and now puts
    the volume in `VOLUME=`, where metal-vmm takes it. Red: the fake
    machine now serves client 1 alone on an unraised site, and shape p's
    unhurt run answered `200,0` as yours did. The tool's own tests build a
    volume with the conf under its long name: only the digit's byte
    changes, and the volume checks clean. **Not run on a guest**: the real
    site's conf is read through fat16_read.py, GPT and all.
  - **(d), (e), lesser** metal-vmm `bf789a7`. (d) After an earlier client
    in turn differed, a later one may answer what the shape's
    `UNMADE=<status>[,...]` names (`session-then-move` says 404), or what
    its own faults excuse; nothing else. (e) Client 1's reset no longer
    excuses another client's lesser answer; its vanish still does, since
    it holds the guest's one connection. (lesser) untouched.py runs after
    every cut, either disk's or the exit's, not only when fsck reported
    leftovers.
  - **(g)** gopher-metal `1ce36b8`: the pin's comment says it stays green
    under "merge toward allocated" and goes red under "keep each copy's
    own", and why a tie's difference is a neutral one (a freed cluster a
    file holds breaks that copy's chain, so the other wins outright): a
    fix is judged by its own red test.

- **(CC, item 126) Every client judged.** metal-vmm `0c7ee1b`, `0db9f88`.
  - **The files:** `PEER_BODY` and `PEER_RESPONSE` stay the first client's;
    client k's go to `<file>.k`. A client never opened gets an empty file;
    one whose answer was kept only in part gets none, and stderr says so,
    as the first client's always did (`reports.answerPath`, `answered`,
    `keptWhole`, with a unit test).
  - **`PEER_IN_TURN=1`, new, and why the dependent shape needs it.** With a
    gap after the last client *opened*, client 2 is behind client 1 only
    while nothing slows client 1's SYN. A lost SYN is resent a second
    later, so client 2's move would arrive before its session exists, and a
    sound kernel would fail. In turn, each client opens a gap after the one
    before it ended: answered, or its connection over (refused, reset,
    vanished, gave up), and for the first, no retry pending. Red first in
    `peer.zig`. The fuzzer draws it from the gap's last bit, not a draw of
    its own, so every seed it already found draws the rest as before (3000
    seeds clean).
  - **The sweep:** client k is held to client k unhurt, with the same
    excuses as the first (now one function, `answer_excuse`). The first
    client's faults excuse the others' lesser answers too, since the guest
    serves one connection at a time and a vanished client 1 holds client 2
    behind it. The request limit counts every other client's answers. In
    turn, once one client differs, the later ones may differ in any way
    ("client 1's answer differed first"); before that, never. Not in turn,
    each is judged alone. Fake seeds 38-45.
  - **EXPECT names one status a client** (`EXPECT=303,204`), else exit 2,
    as 122 does for a shape: a client held to nothing would judge every
    seed against an answer gone stale.
  - **Shapes, not run on a guest:** `session-then-move` (client 1 makes
    session 2, 200; client 2 moves in it, 204, `game-action-2.http`; a move
    in a missing session is a 404, game.zig `appendSessionLine`).
    `two-clients` now holds client 2 to 204. If the site volume's request
    limit is under two, both unhurt runs stop the sweep at once, naming the
    shape.

- **(CC, item 125) Durability as a shape.** metal-vmm red `ffae703`, then
  `fd7d262` and `2fa6a29`.
  - A shape may carry `READ_BACK` (a request file beside it, or a path),
    `MARK`, and `TOLD` (its first EXPECT unless said). Its runs get
    `VOLUME_CUT_AT_EXIT=1`; each of its seeds is read back by an unhurt
    boot; a seed told TOLD whose read-back lacks MARK fails, beside its
    page's verdict. A lying cache whose power took what it held, or a
    SYNCHRONIZE that failed and fired, excuses the write, never the page.
  - Before any seed, per durable shape: the pristine volume's read-back
    must lack MARK, and the unhurt run must be told TOLD and keep it; else
    exit 2, naming the shape.
  - `puzzle-action` (`read-puzzles.http`, `session_id: 2`), `new-session`
    (`read-game-2.http`, `state`), `game-action` (`read-game-1.http`,
    `move-kept`). **`game-action.http`'s body changed** from `y` to
    `move-kept` (Content-Length 9): `y` is too short to be a mark. The last
    two recipes are derived from game.zig, not run on a guest.
  - `play` and `register` have none: reading back a player or an account
    needs the cookie the run itself is answered with, whose time is the
    run's, or an admin's.

- **(CC, item 124) The cold review's holes.**
  - **(e), first:** metal-vmm says what fired (`reports.fired`:
    `metal-vmm: fired: ...`, or `none`, or nothing when no knob was
    turned), and every excuse in sweep.sh needs its fault in that line.
    Red: fake seeds 28, 29 and durable 8, 9. The seeds of the night that
    were excused by a reset or a vanish are worth judging again.
  - **(a):** already closed by 122's rule (the other clients' answers must
    be every one served); pinned by fake seed 30, a let-go counted in
    `served`.
  - **(b):** `tools/untouched.py PRISTINE UNHURT RUN`: every file
    byte-identical in the pristine and unhurt volumes must be in the run's,
    unchanged. sweep.sh runs it whenever fsck says "sound but for what a
    stop leaves". It needs gopher-metal's `tools/fat16_read.py` (beside
    `GUESTS`, or `FAT_READ`). Red: fake seed 31; 32 holds leftovers alone.
  - **(c):** a cut on either disk gives both `STOP_LEAVES`. An exit cut
    (`VOLUME_CUT_AT_EXIT`) gives neither: the guest had stopped, so nothing
    was mid-write. A lying cache's exit loss is excused by the lie's own
    rule. Say if you'd rather it did.
  - **(d):** nightly's FAIL, SILENT, STALE and EDGE report lines reach
    failures.log, and a batch failed by its report alone says so in
    progress.log and DONE. `nightly_test.sh` is new.
  - **(f):** pinned and proposed (P124(f) under Proposed); fat16 is yours.

- **(CC, item 123) A handler's error answered with nothing.** angry-gopher
  red `9588ac5`, fix `7cbed40`. `route` now answers 500 ("The server failed:
  <error>.") when the head is unsent (`req.server.reader.state ==
  .received_head`), and still returns the error so the host logs it, for
  both hosts. gopher-metal's serving loop (gopher.zig ~841) needed nothing:
  it records the error as the request's outcome and flushes what the router
  wrote, the 500 now included. The test is a doc that is a folder. Through
  the port, locally (not committed: the port is yours), store-judge passes
  2/2 and `zig build gopher` builds.

- **(CC, item 119) The write cache turned off: a reset turns it on again,
  and the driver never knows.** metal-vmm `6ec0f37`
  (red) and `4de2ea6`, `20e7022`, `7689d38`.
  - **Against Linux's sd (`cache_type_store`):** the same page sent back
    (DBD sensed, WCE cleared, header and device-specific byte zeroed). Two
    differences. **SP:** sd sets SP from the page's PS bit, so the setting
    is saved; gopher-metal sends SP=0, which is right for QEMU (it accepts
    PF=1 SP=0 only, `scsi_disk_emulate_mode_select`). **The length:**
    `turnCacheOff` sends 20 bytes of page whatever the disk sent; sd uses
    the page's own length. A disk with a shorter caching page (SCSI-2's, 12
    bytes) would be sent stale scratch bytes. QEMU's is 20, so this is for
    a disk that isn't QEMU's.
  - **Against QEMU's scsi-hd (from its source, as I remember it, not run
    here):** it takes the page. It checks the length equals its own, and
    that no unchangeable bit differs from MODE SENSE; WCE is changeable.
    It flushes when WCE goes to 0 (`blk_aio_flush`), so a cache turned off
    with writes held loses none of them. At boot nothing is written before
    `bring` asks, so there is nothing held then anyway.
  - **The finding, for the box: a reset turns the cache back on.** SPC-4:
    after a power on, hard reset or logical unit reset, a mode page's
    current values are its saved values, or its defaults when none were
    saved, and SP=0 saved nothing. gopher-metal turns the cache off once,
    in `bring`. `commandSettled` sends a command again on any UNIT
    ATTENTION, whatever its sense, and `write_cache` stays `false`.
    `io.durable` then never synchronizes, so after a reset the disk is
    *lying*, from the driver's side: answered writes can be lost at a cut,
    as well as reordered. **The fix is the driver's:** on UNIT ATTENTION
    29h (POWER ON, RESET) or 2Ah/01h (MODE PARAMETERS CHANGED), sense the
    page again, turn the cache off again, and believe what it reads back.
  - **The model, now able to show it** (each with its test):
    - `VOLUME_RESET_AT=n` (`7689d38`): POWER ON told at the nth command,
      and every mode page back at its default. Not drawn by `knobs.zig`:
      until the driver handles it, a sweep with it would fail on the known
      gap. Turn it on with the driver's fix.
    - `VOLUME_WCE_FIXED=ignore` (`20e7022`): a disk that takes the MODE
      SELECT and goes on caching. The driver reads the page back for this
      case, and no disk here could reach that path (`=1` refuses).
    - MODE SELECT refuses a list longer than its page, as QEMU does (red
      `6ec0f37`, fix `4de2ea6`).
    - `fuzz.zig` now sends MODE SELECT, and draws the three disks and the
      reset. 3000 seeds pass.
  - **A question:** a disk that won't answer MODE SENSE, or has no caching
    page (`VOLUME_MODE_PAGES=none`), has `write_cache` null. It is flushed
    as if cached, but nothing tries to turn its cache off, so 112's
    reordering is open again for such a disk. Worth sending a zeroed
    caching page with WCE=0 then?

- **(CC, item 120) The lint's two holes, closed.** angry-gopher red
  `cd446aa`, fix `a30a154`.
  - **A wrapper's own errors** are now those it returns or declares by
    name (`return error.X`, `=> error.X`, `orelse`/`catch error.X`,
    `error{...}`), and those of the readers it calls. `appendReaction`'s
    are `NoSuchMessage` alone, and no wrapper's include a disk's error.
  - **A 5xx counts only when the handler is the answer:** `return <5xx>`,
    or a block with no `break` or `continue`, every `return` a 5xx, ending
    in one.
  - **One new site:** `home.zig`'s render, which sets `status` to 500 and
    names the error on the page. It's marked, not taught to the lint.

- **(CC, item 122) Today's judging: three holes, and one in metal-vmm's
  wire.** metal-vmm red `3b5fba5`, fix `ceb6a83`; red `6da8211`, fix
  `22f35c4`.
  - **A lie that cost nothing excused an unsound volume.** With
    `*_CACHE=lie` and a cut, any unsound disk was excused, even when the
    cut lost nothing the cache held (the line says "lost 0 sectors" or
    "lost nothing"). Then the damage is the kernel's own. Now the cache
    must have lost something.
  - **The request limit was excused by one other answer.** With a limit of
    2, both served, client 2 answered once and client 1 given no page, the
    excuse held. One served request was client 1's, and its answer was
    lost. Now the other clients' answers must add up to every request
    served.
  - **A shape with no EXPECT was judged against whatever its unhurt run
    said.** A stale one (a 500) made every seed failing the same way "ok".
    Every shape in `requests/shapes` has one already; now the sweep stops
    with 2 on a shape without one.
  - **The wire still pushed out the request** (metal-vmm's, not the
    kernel's). `6c1aad9` kept `Peer.more` to the wire's room, but `speak`
    put the peer's *answer* to the arriving frame on a full wire regardless.
    With the guest sending its SYN-ACK again while the wire held the
    request, that answer pushed out a segment of it, which a peer that
    never resends never sends again. Answers now wait for room, oldest
    first (eight at most). **A run that filled the wire may differ from
    before:** `same.sh` is the check for that, and it needs a guest.
  - **No hole found:** in `STOP_LEAVES` (only its three complaints, only
    after a cut); in the FSInfo exception (unknown is legal); in "pushed
    out" (a resent frame still has its page compared); in the knobs a
    shape sets (they are in the seed's knobs line, so no excuse hangs on a
    hidden one); in the summary's and repeat line's shape (each seed's
    own).
  - **Two questions:**
    - "The stop cut it" excuses a short page when the guest says a stop
      cut *a* response. With two clients (`two-clients.shape`), the one
      cut may be the other client's. Should it name whose?
    - `KEEP_FAILED` keeps the failing seed's files, not its shape's unhurt
      run, which is what it is judged against.

- **(CC, item 112) On a disk with a write cache, a cut leaves files
  `Damaged` and other directories wrong; fat16's crash safety is the order
  of its writes, which a cache does not keep. The fix is fat16's, so the
  box's.** gopher-metal: `6298c0c` (the cache, S5 and S6 killed), red
  `4d86d06`, `230e4cf`, `2e0a838`.
  - **The cache.** `test_disk.Cache` sits in front of a disk in memory,
    through a host test's hook on `virtio.Block` (`cache`, beside `memory`,
    `fault` and `fail_after`; this touches the image's file, so it's yours
    to look at). A write lands in the disk's bytes and waits; a flush makes
    it durable; a cut keeps what was flushed and whichever waiting writes
    the test says, in the order they were written. A flush once the power
    is gone keeps nothing. Its own test is in `test_disk.zig`.
  - **The red test:** `store_sim`'s `runSeedCached`. Each step is flushed
    before the next, as `io.durable` flushes before a response, so a cut
    can only drop the operation it lands in; a coin per waiting write says
    whether it reached the media. The promises are store.zig's own.
    `runSeed` is untouched (no draw added), so every seed it runs is the run
    it was. Seeds 1-40: seed 13 fails first (a `write` over `data/x.md`
    reads `Damaged`).
  - **What 400 seeds found:** `Damaged` after a cut in `write` (11 seeds),
    `remove` (3) and `replace` (1); `append` never. Worse, past the
    operation: seed 247 shows `auth/7/session` again under `data/chat/7/`, a
    cluster in two directories (a dropped FAT write freed what an entry
    still names, and the next allocation took it); seeds 53, 84 and 218 list
    names with bytes of 0x7F and more (a new directory cluster whose zeroing
    write was dropped).
  - **The mechanism, seed 13:** a `write` over an existing file tombstones
    its entry (the `data` directory's sector), then frees its chain (FAT
    sectors 1 and 34). The cut dropped the tombstones and kept some of the
    frees: an entry naming clusters the FAT has given away, which
    `removeEntry`'s own comment says the order exists to prevent. (A side
    note: freeing six clusters in one FAT sector wrote that sector twelve
    times, both copies once per cluster.)
  - **A fix that holds, proven and not committed:**
    `docs/112-fat16-barriers.patch` (here, in metal-vmm; `git apply` it in
    gopher-metal). It is a flush at each of the order points fat16 already
    names: before `grow` links a zeroed cluster, before `unlinkEntry` frees
    a chain, before `writeFileIn` and `makeDirIn` write their entry, before
    `writeInto` moves the size, and between `rename`'s three steps. With
    it, 1000 cached seeds pass, and so do fat16_test (77), fat16_faults
    (3), fat_sim (22), store_test (29), floor_sim and page_sim. **One test
    differs:** `io_test`'s "a write is flushed before the next response,
    once" counts 4 flushes for a whole-file write. On virtio-blk (write-through) a flush sends
    nothing; on a SCSI disk with a cache each one is a SYNCHRONIZE CACHE.
  - **The other way:** turn the volume's cache off at boot (MODE SELECT,
    caching page WCE=0) and keep fat16 as it is; the disk then keeps the
    order itself. That costs every write a wait on the media instead.
  - **For the box:** what does lynrummy.com's facts page say for "the
    volume's write cache" (`probe/gopher.zig:1656`)? If it is on, this is
    production's shape. metal-vmm's `VOLUME_CACHE=1 VOLUME_CACHE_KEEPS=k` is
    the same model on the real kernel (item 71). Has a sweep with it ever
    found the volume unsound (`sound.sh`)?

- **(CC, item 113) The snapshot's premise, held at compile time.**
  metal-vmm `66614c5`, red `1e3e11a`, fix `d9a624e`.
  - **The walk.** `snapshot.models` lists every model saved by value. A
    test-time walk finds every pointer in each, and the build fails on one
    that is neither `borrowed` (with why a restore in place keeps it right)
    nor a `gap`; a stale line fails too. Each refusal was checked by hand:
    a new field, a stale line, a pointer called a value.
  - **What it found: the write caches were not values.** `virtio.Block.cache`
    and `scsi.Scsi.cache` point at a `cache.Cache` whose durable sectors are
    a heap map. Copied, the map is shared: restored after a detour that
    flushed, a cut lost nothing it should (red `1e3e11a`). `snapshot.Cache`
    now saves it apart, its map copied, and `gaps` is empty.
  - **And the volume had no saver for its bytes:** `Disk.save` takes the
    volume's `scsi.Scsi` as well as the boot disk's `Block` now. The volume
    and the PCI bus with a function on it each have a restore-exactly test
    (the volume's reaches its power cut and a UNIT ATTENTION).
  - **The census** (`main.zig`): every field of `Machine` is named as a
    value (checked pointer-free), a model (checked to be in
    `snapshot.models`), saved apart, guest RAM (yours), an input fixed
    before the first exit (the request), or the host's (the coverage fd).
    A field added to `Machine` fails the test until it is named.

- **(CC, item 114) The store lint follows the wrappers.** angry-gopher red
  `deff213`, fix `233a836`; red `83cb7f8`, lint `feea876`.
  - **How.** On each run it computes the functions that read the store,
    directly or through others (231 today), and holds a call of any of them
    to the store's rule. `readOrNull` and `statOrNull` are reads too. A
    failure answered as a 5xx is told, not read as absence. An arm naming a
    wrapper's own error (`error.NoSuchMessage`) has looked at it, so only
    a wrapper's catch-all is held to absence. 1.9 s.
  - **One real site, fixed:** `docs.serveRawDoc` answered 404 for a doc
    that exists and cannot be read, which tells an API client there is
    none and invites a save over it. It answers 500 now (router test).
  - **24 defended**, each with `// absent-ok:` and why: labels, best-effort
    indexes and broadcasts, the startup backfill that does less, checks
    that fail closed (API key, password, the legacy cookie), the gallery
    that says its failure on the page, the backup's named skip, the
    connection task's log.
  - **Its blind spot:** a method through a value (`x.f()`); only a file's
    top-level functions are followed.

- **(CC, item 118) A folder that stats and cannot be listed.** angry-gopher
  red `e494b31`, fix `2a1666b`.
  - **As root, it is a root that is a file:** it passed `checkRoots`, then
    the archive wrote it as a folder and failed to list it with the 200
    sent. `checkRoots` now lists each root too.
  - **Inside the tree,** a folder that cannot be listed is a named skip,
    listed before its folder goes in. Its test (mode 000) skips itself as
    root, which reads past permissions; run as `nobody` (`runuser`), all 16
    of the backup's tests pass.
  - **A third lint gap, found folding `principalAuthorizedOrError`** (red
    `d3fcce8`, fix `6a024df`): `if (call() catch v)` was taken for `if
    (call) |x|` and never checked, for direct reads too. Its one site in
    the tree was the call being folded, marked now as failing closed.

- **(CC, item 105) The store-absence lint, and the 67 sites it found.**
  It's on angry-gopher `claude/great-wright-i7aste`, and `ops/check_zig`
  runs green end to end. (Its six front-end bundles were empty stand-ins,
  since they can't be built here; they are git-ignored.)
  - **Where it lives.** It's `tools/lint_store_absence.py`, not
    `tools/lint.py`: that is the JavaScript linter, run by `ops/test_chat`.
    Its tests, `tools/test_lint_store_absence.py`, cover each form firing
    and each exemption holding (14). `ops/check_zig` runs them, then the
    lint (`c75961d`).
  - **What it refuses.** A read of the store (`read`, `readOrEmpty`,
    `readAt`, `stat`, `has`, `list`), under whatever name the file gives
    `store.zig`, whose error is caught into a value without being named. It
    also refuses an error dropped by `if (read) |v| ... else |_|`. Item 105
    didn't name that form, and it hid the worst site. A `//` comment on the
    line before defends a site.
  - **The worst site: `counter.next`** (red `444b303`, fix `54b3354`). An
    unreadable or garbled counter read as a new one, so it answered 1 and
    wrote 2. That hands out IDs already given: player IDs, puzzle and game
    session IDs, and **member IDs** (`users.zig`). Now nothing there is 1,
    and anything else that won't read or parse is an error.
    - **A decision to confirm:** the old test pinned "a corrupt counter
      restarts rather than failing the request". A restart reissues IDs, so
      a corrupt counter now fails the request and the file is left as it is,
      as `ef3091eb` did for a garbled upload total.
  - **The second-worst: a retire removed a kept member** (red `43779f8`,
    fix `e98feb8`). `users.readAuthFile` caught every read error into null,
    so a name file that wouldn't read gave the name "". No name is on the
    keep list, so the member was removed everywhere. `readAuthFile`,
    `loadSecret`, `previousSecret`, `userExists` and the two account
    listings now fail on anything but absence.
  - **The rest** (`152a1f5`).
    - 41 sites fixed, each in a function that already answers an error. A
      `store.list` caught into an empty list became `try`, since `list`
      already answers empty for a folder that isn't there. A read or stat
      whose absence means a value goes through `store.readOrNull` or
      `statOrNull` (new, tested, `54b3354`); they give null only for what
      `has` calls absent.
    - 16 sites defended with a comment saying why (17 with `userLastSeen`): the admin page's counts,
      an archive member's mtime, the cookie checks (each fails closed), two
      caches over the transcript, a display-only companion, `keptUser`,
      `migrateSecret`, and a stream whose headers are already out.
  - **Checked against gopher-metal.** `zig build gopher` and `store-judge`
    (2 pass) are green over a port of the new tree, so the new helpers'
    error names exist on metal too.
  - **What the lint can't see:** a read reached through a module's own
    wrapper, then caught into a value. For example,
    `users.getUserName(...) catch ""` in `chat_retire.retireUser`, which
    only labels a record line.

- **(CC, item 104) The cold hunt's smaller findings: six fixed, each red
  test first, and one answered.**
  - **fat16, a name past ASCII** (gopher-metal red `a2e8594`, fix
    `4132fc5`). The name was written, then read back with '?' in it, so it
    was found under no name it was given, and a second write made a second
    file.
    - `aliasFor` now refuses any byte of 0x80 or more with `BadName`. Every
      new name passes through it before anything is changed (`writeFileIn`,
      `makeDirIn`, `rename`).
    - The Store's `checkPart` refuses the same, so the model and the Linux
      store agree with FAT.
    - **This is a refusal angry-gopher can meet**, if any of its names can
      be non-ASCII (an upload's original name, a doc slug). Topic and user
      IDs are ASCII by their own checks.
    - Reading a foreign long name still shows '?'. I left that alone: the
      item asked for the write to be refused.
  - **io `Dir.iterate`** (red `8be63f7`, fix `f70bb83`). A volume that
    isn't there, or a directory fat16 won't walk (an entry naming a cluster
    outside the data), is now the first `next`'s error. A read that fails
    while listing already was an error.
  - **angry-gopher `admin_backup`** (angry-gopher `claude/great-wright-i7aste`,
    red `934976f`, fix `26aa925`). Each of these now gets a line in
    `backup-skipped.txt`, with why: a root that can't be stat'd (anything
    but "not there yet"), a file whose stat fails, and an entry that is
    neither a file nor a folder. Links were dropped unnamed too.
  - **metal-vmm `site.sh`** (`3fb7d94`). Two missing `tcp:` lines no longer
    compare equal; either side without one fails, saying which. There's no
    test, since `site.sh` needs QEMU and KVM; I checked the four cases by
    hand.
  - **metal-vmm `reports.zig`** (red `9850550`, fix `18c5e8d`). A page past
    the 64 KiB the client keeps is now said at the size it came, from
    `received` less the head. The line keeps the shape `sweep.sh` parses.
  - **gopher-metal `store_judge`** (red `3951b4f`, fix `cc262cf`). "Is this
    a file" asks the model's `stat`, so a file past `model_buf`'s 1 MiB is
    still a file on the way. The judge runs here: `./port.sh` into a
    scratch directory, then `zig build store-judge -Dgopher=<it>`, 2 pass.
  - **`log_ring` `Ring.read`, answered, not changed.** A reader with less
    room than the ring gets the newest bytes, from mid-line, with no flag.
    But every kernel reader passes a buffer of exactly the ring's size:
    `metalLog` passes `serial.ring.len()`, `serial.keepIn` 64 KiB (the
    ring's size), and `restarting`'s `lastLine` `kept_log.slot_bytes` (64
    KiB, the slot's). So that path is never taken. A flag would be dead
    code today.

- **(CC, item 103) What the 10-07 and 10-08 fixes missed: three findings,
  each with a red test.** Most important first.
  1. **B26 (gopher-metal `d7a5903`) makes a folder that can't be read stop
     the boot.** When the FAT copies differ, `cacheFatChecked` runs a whole
     `check`, which reads every directory. One directory sector that fails
     to read fails the mount (`ReadFailed`), and metal stops with "the FAT
     could not be held in memory". Before B26 the copies were brought into
     line from the first copy and the volume mounted. A rotted FAT sector
     next to a bad sector in a folder is the disk B25 and B26 were for.
     - Red test: gopher-metal `fccad06` (`fat16_test`, "copies apart and a
       directory that cannot be read"). The check's first read is made to
       fail, which I confirmed gives `ReadFailed`.
     - It asks that a weighing that cannot run leaves the choice unmade:
       mount with the first copy held, and write neither copy over, so the
       second copy (the good one, in B26's case) is still there for a boot
       that can weigh.
     - The fix is fat16's, so it's yours. In `cacheFatChecked`, a failed
       `check` restores the held sectors and returns `.{}` with nothing
       written.
     - **Merge the red test with the fix**, since it fails `zig build test`
       until then.
  2. **`checked.zig` (`311731c`) accepts times that overflow when read.**
     Nine microsecond settings and `PATIENCE_S` took any u64, and their
     readers multiply into nanoseconds. `WIRE_LATENCY_US=18446744073709552`
     passed the check, then panicked in a safe build or became a short wait
     in a fast one. Red test `b5d9669`, fix `c621611`: each is bounded by
     what a u64 of nanoseconds holds. Both are on metal-vmm
     `claude/great-wright-i7aste`, and `zig build test` and
     `sweep_test.sh` are green. The other narrowings checked out:
     `PEER_MSS`, `PEER_RETRY` and `PEER_FLOOD` are clamped, and the fields
     behind `@intCast` and `@truncate` are wide enough for what the table
     allows.
  3. **`sweep.sh`'s new excuse (`78dd476`) covered another status.** "The
     stop cut it" was granted whenever the guest said its stop cut any
     response, so a whole 500 where the unhurt run got 200 read "differs as
     allowed". Red `9d3a4a1` (sweep_test seed 11), fix `f539aa3`. The
     excuse now covers a page cut short, or no answer at all, never another
     status. **The older excuses have the same shape**: `PEER_RESET_AT`,
     `DISK_REFUSE`, `DISK_CUT_AFTER` and the rest excuse any difference,
     status included. A disk refusal that turns into a wrong 200 or a 404
     would pass. Narrowing them is a judgment about each fault, so it's
     yours.

  Read and found sound:
  - angry-gopher `8b617f3c`. The head can't be read over any more: the copy
    covers the pre-read case, and every later body read goes through
    `http.zig`'s owned accessors, which `lint_head_access.py` enforces.
  - angry-gopher `ef3091eb`. Each of the four reads passes on every error
    but absence, and its callers propagate.
  - angry-gopher `9e8e615d`. Topic IDs are validated before the download,
    so no tar name can carry `..` or `/`. `split` refuses rather than cuts.
    One limit: ustar's size field silently drops the high bits past 8 GiB,
    which uploads (1 GiB lifetime) can't reach today.
  - gopher-metal `d86ec98` (the INQUIRY guard needs only byte 0, so
    `residual < 36` is right) and `c7539eb`.
  - metal-vmm `766bffc`: the vector index is bounded by `queue_count`.
  - The boot-message commits (`d2e7480`, `83584da`, `e07b363`) and
    `9f24e42`.

- **(CC, item 98: done before the pause, not merged.)** It's gopher-metal
  `9c40811` on `claude/great-wright-i7aste`, with master merged in
  (`a7940d7`). `zig build test` is green.
  - The bench counts only what 300 blind runs reach, and shows each
    property as reached in N of 20 explorer seeds, for blind runs, random
    flips and aimed flips. Each failure prints `unfaithful`.
  - Also unmerged on that branch: `9745fd1`, `1a3fbc4` and `051941b`, the
    oracles that kill T16, R6 and S2.
  - The default bench run, which is long, wasn't run. A 2-seed trial at
    budget 20 had blind runs leave fewer properties unreached than either
    explorer (4.0, random flips 12.5, aimed 6.5). Confirm at 20 seeds
    before quoting it.
  - Item 99 is not started.

## Answers

*(The box's, newest first.)*

- **(2026-10-07, to CC's item 98 note):** merged, gopher-metal `b445e6f`; a
  smoke run (budget 5, 2 seeds) compiles and runs clean (no failures, no
  drift, no unfaithful flips). The three oracles were already on `master`
  (they rode in with `MUTATION.md`). Your blind-beats-explorer reading
  agrees with the smoke run; it is now the box's to settle with Steve, at
  the full size, before any number is quoted (the box's list).

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
