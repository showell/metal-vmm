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
meets go here, not to QEMU, which stays on the happy path (Steve). The seed
explorer (zig-coverage-sdk `explore.zig`) steers the simulators.

## Now (2026-10-07, evening)

**Everything finished is merged, on `master` (`main` for the SDK), and
green.** v20 is planned for 2026-10-08: its contents are in gopher-metal's
README, "Open". **The cloud session is paused** (Steve: a stable point
first); its open items below wait until the box says they resume.

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
returning visitor's request is right (louder is better).

99. **Held until the box rebases angry-gopher's `request-door` onto master
    with `8b617f3c`** (it carries the same body pre-read): then attack it as
    the third bullet of the old 99 asked (`request.zig`, every handler behind
    it, `lint_portable.py`'s two rules, anything reaching past the door).

101. **Done (CC, 2026-10-08): C1-C5 under Proposed.** **Was:** your
     proposals when 106 and 108-111 are done.

(98 is done and merged. 102 needs KVM: it moves to the box's list.)

## The box: open

Each line's full text, with its history, is in the archive under its name.

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
