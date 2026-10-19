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
- **CC:** 239 (Dog Park: more physics in Roc; the box's C is in, start from dog-park 4bfc265), then the rest of 240 (its kinds in World.roc are merged) (new kinds of critter from Roc alone). 238 merged and archived (2026-10-19). The night's 234 to 237 are merged and archived (2026-10-18).

## CC: open

**Your role (Steve, 2026-10-08): build what needs no emulator, and anything
adversarial.** Every item here runs on the host: `zig build test
-Dtest-file=<file>` runs one zig-metal-unikernel test file in seconds (the whole step
takes minutes); metal-vmm's `zig build test` and its `sweep_test.sh` need no
guest. Where a claim needs a real boot, write the recipe under Questions for
the box instead of guessing. Findings arrive as red tests where they can.

**239. Dog Park: more of the physics in Roc, the poop's spot first, then the chickens' turn: CC'S** (the box, 2026-10-19, at Steve's ask). **Start from dog-park `main` 4bfc265**: the box's C is in (the leashed dog's step in Roc, below), which changed `roc_walk` and what A crosses. Two cold surveys of what Zig still does, the second checking the first against the code; the plan below is what survived. Steve: more Roc, minor speed regressions tolerable, large ones not. Read `docs/ROC-SPEED.md` first: every chunk keeps its rules (no list held in two places; no record, tag or closure carried round a hot loop; no new caller for a hot helper the walk inlines; one export).

**Done by the box today, so not yours:** the physics hash covers the Roc (`physics_sources.zon`); the walk's limits (`most`, `nudge_most`, `dead_zone`) and `cell_per_tile` have one source, Rules.roc and World.roc, printed into rules.zon and world.zon; Walk.roc names the veto's why (`why_went`..`why_poop`, numbers, not a tag) and a key's marks (`not_lined_up`, `visited`); Zig's `stepWhole` is for the leashed dog and chickens only, the dead nudge gone, with `comptime poop_every > 2 * step_most` and `poop_due <= 1` asserted; seven dead declarations gone.

**Every chunk's judges** (stop and report, don't push on, if one fails after one pass at the cause):
- `zig build physics-bench -- lines`: the 14,800 lines byte for byte as before the chunk;
- `zig build check` (physics-wasm and the golden test in it), `zig build roc-test`, and `zig build metal` compiling (no QEMU gate);
- `zig build walk-judge` (dog-park cc6ab50): every pixel-tick of the Roc checked against `src/play/walk_reference.zig`, a plain, naive Zig reference sharing no code with it, over the bench's drags and again with uneven steps (~11 s once compiled). **A change to the walk's behaviour changes the reference in the same commit**, by its own reading of PHYSICS.md, never by copying the Roc;
- **the speed**, the bench before and after run alternately, five rounds or more, best of each (`zig build physics-bench`, no args, the µs a tick it prints). **Stop at 15% slower** on the busiest drag or the packed herd and report, rather than tune (Steve, 2026-10-19: "We can tolerate up to 15% slowdown in Roc"; this VM's bench swings up to ±7% between identical code, so compare the walk's machine code itself where that settles it, as CC did for 240's first piece);
- the three archives rebuilt by `zig build roc` with **your** Roc, and committed, with `roc fmt` run before you measure (export order). Say in the commit which Roc built them.

1. **A. Where a poop lands (~3-4 h; first).** `layDue`, `layPoop`, `tryPoop`, `poopFits` and `away` move into `roc_walk`; `placePoop` stays Zig (it changes the poop lists and the slot bookkeeping). **Since C, `roc_walk` (Walk.roc's `pixel_tick`) already has the leashed dog's step and how far it walked this pixel-tick** (it hands both back; Zig's `Scene.walkOn` counts them), and Rules.roc has `poop.every`: so lend it the dog's walked count before the pixel-tick and `laid`, let it work out the poop due itself (at most one, asserted in Zig's `layDue`: keep that check, as a Roc `crash` or a Zig assert on what comes back), and hand back `poop_x`, `poop_y` and the slot, an `I32`, -1 for none (no `Bool` in the returned record: padding; update `roc_physics.zig`'s `@sizeOf(Walked)` assert). A ring search of its own, not a new caller of `poop_under`. Then `wishAlong` and `quotientAlong` (its wasm-only branch) have only test callers: delete them and physics_test.zig's tests at :296 (test 11's checksum; the Roc runs on wasm32 under `physics-wasm`, which keeps that guarantee) and :343. Judges besides the common: physics_trails_test.zig :70, :92, :275, :305; add Walk.roc `expect`s for the ring order and for coinciding centres going east.
2. **B. The chickens' turn as a mode of `roc_walk` (~5-6 h; after A).** `chickensTurn` and `nearestRipe`, and the chicken cases of `stepWhole`/`stepAround`/`poopUnder`'s `eats_ripe`. A mode number on the one export, not a second export. **Its own chicken step**: Walk.roc's `step_whole` and `gather` take no second caller (they would let a chicken shove chickens, which Zig vetoes, and may stop inlining). A chicken's own step is blocked only by the newest poop, which is never eaten, so what one chicken eats matters only to the next ones' `nearestRipe` and the eating: **lend an eaten list with room** (Roc allocates nothing; `roc_alloc` panics), hand it back, and Zig's `eat()` applies it. Roc has no chicken homes today (`layout.chickenHome(n)`, printed by world.roc, not in World.roc, and `Crit` has no chicken number): lend them as a read-only list by seen index. Chickens visit in seen order, as now. **Write it as a behaviour a kind has, not as chickens** (Steve, 2026-10-19: new kinds of critter are to be made in Roc alone, obeying the board's physics: moving at some pace away from some critters, toward their own kind, or toward food or poop): the forage (toward the nearest ripe poop within sight, else home past a band, at most a step and a share of the leashed dog's move; eats what it stands on) is a rule in Rules.roc's terms that a kind's rules name, keyed by kind, and the turn takes every critter whose kind forages. Today only chickens do, so the 14,800 lines stay the same bytes. Judges: physics_trails_test.zig :204, :218, :234, :245, :133; physics_test.zig :411 (the invariant fuzz). The `bucketsHold` asserts at each chicken (now in `chickensTurn`) can then run only after the call: say so in the code.
3. **Report** in FEEDBACK: per chunk, the speed before and after (alternating, best of five), the lines' check, what moved and what Zig is left; and anything ROC-SPEED's rules made you do.

**Not tonight:**
- **C, the leashed dog's step: DONE by the box** (dog-park ae5399a): `roc_walk` is one pixel-tick, `pixel_tick` (sweep, `go_around`, then the walk). Zig's `stepWhole` is now a chicken's step only (0261320), and a test holds a chicken going round a chicken (bb8ca30), for B. The survey's notes, kept for the record: it adds Roc work every pixel-tick, its accounting (the summed walked length of both moves, the bump, `due`) replaces A's `due` in, and it leaves the `Scene`'s `seen_cells` serving only tests.
- **The `Scene`'s lookup tables** (bitsets, linked poop lists): they change in place on every move; they stay Zig.
- **`overlaps` and `onPoops`** stay Zig: the independent check on the Roc (the judge and the invariant fuzz call them).

**Steve's to decide (not blocking A or B):** whether C is wanted. **Decided** (2026-10-19): new kinds of critter come from Roc alone, so the Zig is to become kind-blind; that is 240, after this.

**240. Dog Park: a new kind of critter is Roc's alone; the Zig knows no kinds: CC'S, after 239** (the box, 2026-10-19, at Steve's direction: "we eventually want to be able to create new types of critters in Roc without having to make zig changes. New critters would still have to obey overall board physics (i.e. they basically move at some speed away from some critters and towards critters of their own kind or some kind of food or poop)"). Start when 239 is in; no review needed between (Steve, 2026-10-19), with these defaults for what would otherwise be his:
- **How a kind looks**: World.roc gives each kind a size and a colour, and the page draws its square in that colour, as today's kinds are drawn; art later.
- **The formats change** (the wire, the log, the snapshots): bump each one's version, so an old page or report is refused, never misread. A release wipes games and accounts, so nothing old needs to keep working.
- **The fourth kind** that shows the Zig needs no change lives in a test world only; the served park keeps dogs, cows and chickens until Steve adds one.
- The same stops as 239: the 14,800 lines byte for byte while the kinds are today's three (the format version's own lines excepted, said in the commit), and 15% slower on the busiest drag or the packed herd.

What the surveys found the Zig knows of kinds, each to become data from Roc:
- **The board**: `Board` keeps one array per kind (`physics.zig` ~282-361), with `Kind`, `rank`, `kinOf`, `Critter.half` and `Scene.init`'s loops per kind: one critter array with a kind number, sizes and kinship from World.roc.
- **The wire, the judge and the log** (about 14 kind references each): critters as (kind, x, y), the kind a number Roc names.
- **The page's exports** (`physics_page.zig` ~99-147: `dogsAt`, `cowsAt`, `chickensAt`) and its drawing: one `crittersAt` with kinds, and how a kind looks (size, colour, sprite) from World.roc through world.js.
- **The rules**: Rules.roc's `Sees` has a field per kind (`dog`, `cow`, `chicken`), an N-by-N table kept as record fields; a rule by pair of kinds (`rule : Kind, Kind -> Rule`, a `match` with no `_`, so a new kind is a compiler-listed set of pairs to fill), with the behaviours the board's physics allows: keep away, herd with kin, close in, forage (239 B), go home.
- **The kinds' numbers** (`Wish.kind_of`, physics.zig's `Kind`): printed from Roc, so the Zig never names one.
The judge of each step stays the 14,800 lines byte for byte while the kinds are today's three; then a fourth kind, made in Roc alone, shows the Zig needs no change.

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
  sector, the last TCP properties on the real kernel, request_heap's figure,
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
