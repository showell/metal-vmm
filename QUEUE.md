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

## CC: open, paused

98. **Paused (Steve, 2026-10-07 evening: a stable point first; the box will say when).** **Your finding 3, in gopher-metal's `explore_bench.zig`**, after the box
    merges `box/store-explore` into `master` (it rewrites the bench into
    three columns, fat or store, and refuses a drifted run; until it lands,
    start from that branch). Count only the properties blind `fat_sim`
    reaches at 300 seeds; report each target as reached-in-N-of-20 explorer
    seeds; print a failure's `unfaithful` beside `drifted`.

99. **Paused (Steve, 2026-10-07 evening: a stable point first; the box will say when).** **Attack the box's three branches**, adversarially, as you did the
    explorer (they're pushed; read, run `zig build test` where you can, and
    report under Questions with a reproduction where you have one):
    - gopher-metal `box/store-explore`: STORE.md, HOST.md, the store judge
      (`src/store_judge.zig`, `judge_world.zig`; it needs angry-gopher and a
      port, so read it if you can't run it), B21, B22 (and removeTree's
      final step), `tools/check_limits.py`, store_sim's named choices.
    - angry-gopher `box/has-errors`: `store.has` answers no only for what
      is not there; every caller's choice of what an error means. Security
      first: `legacyHonoured`, `isMarked`, `authFileExists`.
    - angry-gopher `box/request-door` (on top of has-errors): `request.zig`,
      every handler behind it, `tools/lint_portable.py`'s two new rules. Is
      anything still reaching past the door the lint can't see?
    A cold reviewer already caught five serious bugs in the first two
    (removeTree broken by B22, a build.zig that didn't compile, missed
    `has` callers, the judge's model not being the seam's, legacy cookies
    failing open); they are fixed on those branches. Look for what it missed.

102. **Paused (Steve, 2026-10-07 evening: a stable point first; the box will say when).** **The rough peers must reach their properties by design, on both
    kernels** (the box, 2026-10-07; before 101). v19's `long.sh` failed only
    its metal floor: four TCP properties ("an exact reset closes a
    connection", "an inexact reset in the window draws a challenge ACK", "a
    shut window is probed", "a segment for no connection is refused") that
    gopher-metal's rough-peer scenarios reach only by luck on the coverage
    kernel. Measured: v18's coverage kernel reached 3 of the 4 with the
    console costing time, 1 with it free (an experiment, reverted); v19's
    reaches none either way, and `PEER_RESET_AT=500000` under it ends with
    the guest idle and no request served (4 frames out, `peer: 0`), which
    needs a diagnosis, not a new number. The production kernel passed every
    rough scenario. They are off `coverage/floor-metal.txt` on
    `box/store-explore` (`4f6d7bc`) with a line saying why. Find why each
    scenario stops reaching its property, make each reach it by
    construction (an event timed from the connection's own state, a
    scenario that cannot finish before it, whatever the knob needs), show it
    on both kernels and on several boot lengths, and put the four back on
    the floor. Read long.sh's rough-peer block and its two-kernel comment
    first. You have no KVM: build what you can on the host (metal-vmm's
    unit tests drive `client.zig` without a guest), and write what needs a
    real run as a recipe under Questions for the box.

101. **Paused (Steve, 2026-10-07 evening: a stable point first; the box will say when).** **Your proposals again** when 97-100 and 102 are done.

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
- **B23.** A request head over 16 KiB gets no answer on metal-vmm.
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

## Questions

*(Either side, with a reproduction where there is one.)*

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
