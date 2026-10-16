# QUEUE

The one queue for metal-vmm, zig-metal-unikernel, zig-coverage-sdk,
angry-gopher, zig-webbox and dog-park: what is open, and who has it.
**Finished, retired and answered items are in
[`QUEUE-ARCHIVE.md`](QUEUE-ARCHIVE.md)**, one line each by number with the
commits they name; their full text is `git show 3697b1c:QUEUE.md` and `git show
3697b1c:QUEUE-ARCHIVE.md`. New items continue from 225. The conversation between
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

## Now (2026-10-16)

- **v31 is in its release checks:** zig-metal-unikernel `5fbfd87`, angry-gopher `4ac2c5f5`, zig-webbox `d83b2e1`.
- **Dog Park is live** at dogpark.lynrummy.com since 2026-10-16, image dog-park `ab222a2`.
- **CC's 221 chunk 3** (`/admin/log` for Dog Park, on CC's branches) waits for the box to merge it after v31.

## CC: open

**Your role (Steve, 2026-10-08): build what needs no emulator, and anything
adversarial.** Every item here runs on the host: `zig build test
-Dtest-file=<file>` runs one zig-metal-unikernel test file in seconds (the whole step
takes minutes); metal-vmm's `zig build test` and its `sweep_test.sh` need no
guest. Where a claim needs a real boot, write the recipe under Questions for
the box instead of guessing. Findings arrive as red tests where they can.

**Next for CC, in order (Steve, 2026-10-16: "give it all three"):**


**223. FIRST, before 222, about 20 minutes: what stops you running the long tier?** (Steve, 2026-10-16: "empower CC to work on the long gates. I can't remember if it's truly blocked on running QEMU.") The box is studying how to make zig-metal-unikernel's `long.sh` about 10x quicker (round 1: about 48 min, of which the simulators take about 22 min, the lossy sweep about 13 on metal-vmm, and the FAT16 chat judge about 9 on QEMU). If you can run its parts, you can own that work. **Find the blockers; fix nothing; don't run the whole tier.** In FEEDBACK, one line each, with the exact error where something fails:
1. **The machine:** `nproc`, memory, `ls -l /dev/kvm` (and whether you can open it), and `id` (are you in the `kvm` group?). The tools tier 1 needs (`tier1.sh` line 11): qemu-system-x86_64 (and its version), mkfs.vfat, fsck.vfat, sgdisk, mcopy, curl, as, ld.
2. **metal-vmm, needs KVM:** `zig build test` here, then **one** boot. For example, `sweep.sh` with one seed (`VOLUME_SEEDS=1`-style, as long.sh calls it at its step 5), or the smallest boot its README names. Give the time each takes.
3. **QEMU:** one boot of gopher.elf, for example tier 1's `droplet boot` step alone, or one probe. Say whether it ran with KVM or software emulation (TCG), and the time.
4. **The simulators:** `zig build properties` with `-Dseeds=200` or the smallest seed count the build takes (see `long.sh` lines 96-107 for how it is called). Give the build and the run as two times.
5. **Your verdict:** which of long.sh's six phases you can run as they are, which need something you lack, and what that something is.
If KVM is missing, say whether QEMU's software emulation is a usable substitute for any phase, and roughly how much slower.

**224. The long tier about 10x quicker, at about 80% of its value** (Steve, 2026-10-16: "It's still my goal for the long gopher gates to be about 10x quicker. Quality over quantity... I would trade some thoroughness for speed... Even under QEMU, things should happen at computer scale, not lunch hour scale." Three rounds with a cold agent; the box's call on the result). **After 223, before 222.** zig-metal-unikernel. **v31's long tier, measured on the box (2026-10-16): simulator 1,429 s, fault sweeps 126 s, lossy 151 s, rough 18 s, volume sweep 29 s, FAT16 judge 194 s; about 32 min.** The simulators are 73% of it, on one core (the box has 2). The metal-vmm phases' v20 times (2.7 s a boot) predate the coverage door (metal-vmm `a92ca03`, which removed ~111k exits a coverage boot), so they are probably several times faster today. Measure them before cutting. **Target: about 5 minutes of running, plus builds timed as their own number.** Each chunk measures first, and is done when its phase time is met **and the floor is still fully reached, with no oracle broken**. Chunks 1-4 need no KVM; 5-6 need KVM, which you lack (223), so they are the box's; 7 runs under TCG, yours to try.

1. **Per-simulator timers, events and a floor** (20 min): `properties.zig` prints, for each simulator (TCP plain, rough, crowd; FAT; store; durable; floor; the rest), **`runs, events, seconds, ns/event`**: an event is that simulator's natural unit (a segment or timer for TCP, an operation for FAT and store; say which in a comment). `long.sh` logs the properties build's time apart from the run's. **The floor** (Steve, 2026-10-16, the box's essay `depth-points-at-the-instruments`, https://github.com/showell/essay-repl-server/blob/master/notes/depth-points-at-the-instruments.md): about 1 µs an event. A simulator more than about 10x over it gets one line in FEEDBACK saying why, or a fix; it is a number with its explanation beside it, not a gate and not a warning. Rough arithmetic for scale: v31's 1,429 s suggests about 40 ms (80M cycles) a TCP world; nobody knows its event count yet, which is the point.
2. **A fast allocator for the sweep** (30 min, the one bet): every simulator allocates through `std.testing.allocator`, a `DebugAllocator` that takes a 10-frame stack trace on every alloc and resize (zig 0.16 `std/testing.zig:22-24`; the box checked), in ReleaseSafe too. Thread an allocator through `run*Seed` (`tcp_sim`, `fat_sim`, `store_sim`, `durable_sim`, `floor_sim`, the others); the sweep uses a per-seed arena over a fast allocator, while tier 0's sampled runs keep `testing.allocator` for its leak checks. **Measure first:** 1,000 seeds both ways, per simulator. Done: the simulator phase at least 3x faster at the same seeds.
3. **Seeds by measurement** (20 min): `long.sh`'s `SEEDS` default becomes the smallest N of 1k, 2k or 5k that still reaches the whole `floor-sim.txt`; crowds on 500 seeds, not all (`build.zig:597`'s default). Plus `coverage/seeds-that-failed.txt`: every seed that once broke an oracle, always run (`properties.zig` reads it). A floor line left unreached by a later change fails the tier and names it; raising N or moving the line is a commit. `SEEDS=10000 ./long.sh` stays, for hunting. Done: simulators under 90 s.
4. **Shared setup, two shards** (30 min): one pre-formatted image per disk shape, copied per seed instead of zeroed and reformatted (`test_disk.makeIn`; FAT32's `small32` is 35 MB a seed); then TCP and the rest as two filters run side by side on the box's 2 cores. Done: at most half of chunk 3's phase time.
5. **One kernel per lossy and rough case** (KVM, 20 min): the coverage kernel runs exit for exit as the release one does (metal-vmm README, the coverage door), so each case runs only the coverage kernel and is judged on its page. The release kernel runs only the unhurt case, and its page must equal the coverage kernel's. Delete `long.sh:281`'s rebuild (a cache hit). **Measure first:** one coverage and one release boot of the PDF route, with the cost line's exits by kind, and one image copy. Done: lossy plus rough under 60 s, `floor-metal.txt` fully reached.
6. **Lossy, sampled and two at a time** (KVM, 30 min): the first 4 frames, the last 4, every 5th between; 2 jobs, a folder each. Done: lossy under 30 s, floor-metal fully reached (if sampling loses a floor line, keep the frames that reach it).
7. **The FAT16 judge, its write path only** (KVM + QEMU, 20 min): `JUDGE_QUICK=1` plus only the steps that write, append and rewrite (uploads, churn, bulk). **FAT16 matters again:** Dog Park keeps its data on a FAT16 partition in production. The sims run FAT16 on 3 seeds in 4, and Dog Park's root stays near 90 entries, far below FAT16's 512-entry root. Endurance and stamina stay on tier 3's FAT32. Done: under 90 s, PASS.

**Deferred until a missed bug shows the need (decided):** a seed bank and rebank tool, rotating seeds per release, a nightly run with FEEDBACK entries, a staleness check. **Retired:** crowds on every seed; the release kernel's second run of every lossy and rough case; long.sh:281's rebuild; FAT16 endurance and stamina. Say in FEEDBACK what each chunk measured, before and after.

**225. Two kernels talking: a TCP client, a literate tcp.zig, and metal ↔ metal** (Steve, 2026-10-16: "We want metal-vmm to be able to test two unikernels talking to each other as client/server in an observable way, and we want the gates to be fast! Like under a minute"; the client's Zig "should read almost as a literate transcription of the RFC itself"; "Linux is the witness": metal client with Linux, Linux client with metal, metal with metal). **After 224.** The plan is [`docs/TWO-KERNELS.md`](docs/TWO-KERNELS.md), the product of 15 design rounds (cold agents, three adversarial passes, the box's measurements): build from it, chunk by chunk, in its order, starting with **chunk 0a, RFC 6298 §5.4 in tcp.zig**, a production fix (the native judge's loss check stalled 2 in 5; the box caught it: `given_up` after a go-back phase lock). Its §8's four decisions are settled (Steve took the recommendations: simultaneous open dropped and counted; a 25 ms first SYN RTO for the client only; one reserved slot; L = 1 ms in pair.sh). Take it from there. "Box verifies" chunks wait for the box between pushes; say in FEEDBACK when one is ready.

**222. Background Shale runs on lynrummy.com: 216's last piece** (Steve, 2026-10-16: "queue the 216 wiring for CC"; angry-gopher, your branch from master, which has 221's chunks 1-2; chunk 3 is on your branch, unmerged until v31's long tier ends). Today `admin_script.zig` sets no `backing`, so zig-webbox's route refuses `mode=background` (`no_background`) and lynrummy.com runs atomic scripts only, while Dog Park runs background ones on both hosts. **Model: Dog Park's `src/play/shale.zig`** and its `Site.between`.
- Set the route's `backing` and step the run from angry-gopher's `Site.between`, so both hosts step it (Linux's thread, the kernel's slices after each turn and on idle turns, kernel `12901a1`). `background_budgets` (reads 10,000) already waits for it. `GET /admin/script` shows the run going or the last one ended, with its output, as Dog Park's does. A background run only reads; a second job is refused while one runs (Steve, 2026-10-15); `mode=kill` ends it.
- **Tests, red first:** a background run started, stepped to its end and its output read back; a second refused while one runs; kill; an atomic run still answered as today.
- **For the box to run (you can't boot):** a step in the kernel's judge (`probe/judge_gopher.py`, or a gopher QEMU check like Dog Park's `tools/metal_gate.mjs` background run) that starts a background run on gopher.elf and answers another request beside it. Write it; the box runs it with tier 3.
- **Docs:** angry-gopher's README and the kernel's script-route release notes (README, "Release notes: the script route") say lynrummy.com takes background runs, from the release that carries this (v32).

- **221's two small things** (the box, FEEDBACK 2026-10-16, "221 chunks 1 and 2 installed"): `skip_install_trust` in the global Caddy options; `knocks` lists the paths in its "other" family, the top few with counts. Ride them on CC's next chunk.

## Parked

- **216's output ring and SSE stream** (Steve, 2026-10-16): revisit when a script needs to report as it runs; today `GET /admin/script` shows output after the run.
- **212, Dog Park's grid from 210's lessons** (the box, 2026-10-15, while Steve reshaped the world to 6 x 6 tiles): revisit to re-scope once the reshaped world is settled.
- **84, 85, 86: N5's FAT refusals, N3's `readAt`, the seam under `stream.zig`** (Steve, 2026-10-07: the adversary role comes first): revisit if the store's seventh call or the stream seam is wanted.
- **The whole-machine snapshot** (`docs/SNAPSHOT.md`, Steve): revisit when steering the real kernel by snapshot is wanted.

## The box: open

- **The native judge's loss check stalls intermittently (found 2026-10-16; its fix is QUEUE 225's chunk 0a-0c).** `native/judge_native.py` (tcp.zig as a Linux program on gmtap0, real Linux TCP as the client): in 2 of 5 full runs, `check_loss`'s 300 KB GET under netem 5% plus `GM_LOSE_SENT=13` got no byte for 60 s (`TimeoutError`). The same sequence (100 /tiny, then 300 KB) in isolation: 0 of 10 stalled, the big transfer 0.1-2 s. So something earlier in the judge sets it up. The native judge is in no tier, so nothing has run it. tcp.zig is production's TCP. **Caught (1 in 6 instrumented full runs): the server's stats at the stall say `given_up: 1, in_use: 0`**: tcp.zig abandoned the 300 KB connection after its retries, its RST was lost too, and Linux (nothing outstanding, no keepalive) waits forever. Six losses of the head under 5% random loss are vanishingly rare, so the likely mechanism is a **phase lock**: on a timeout `transmitOne` goes back and resends the whole usable window (`tcp.zig:849`, "GO BACK"; its own comment says RFC 6298 (5.4) asks only for the oldest segment), and `GM_LOSE_SENT=13` drops every 13th frame sent, so a window that is a multiple of 13 drops the head every cycle. **Fix (chunk 0 of the pair work): a timeout resends only the oldest segment (RFC 6298 5.4); the judge's loss becomes seeded random; the judge catches a stall and reports the server's stats instead of a traceback.** Red first: a tcp_sim world with a 1-in-13 wire and a 13-segment peer window.

- **222's kernel line, for v32** (CC, FEEDBACK 2026-10-16): gopher.zig steps `betweenSlice(io)` once before the loop, so a background run sent as the first request after a boot isn't refused `no_background`. Without it the judge's new `shale-background` gate is red. Dog Park has the same pattern (`stepped` in `src/play/shale.zig`). Then merge 222 (angry-gopher `12b41e8`, zig-webbox `f2c8f20`, kernel `f4e12ae`) and 221 chunk 3, ops/check, tier 3 with the gate.

Each line's full text, with its history, is in git (see the header).

- **221 chunk 3:** merge CC's `/admin/log` for Dog Park after v31 (branches named in FEEDBACK, "221 done"); it rides the next Dog Park image.
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

- **The console door for every log line** (the box, 2026-10-16, from QUEUE 225's design): in metal-vmm runs, about 78% of exits are serial-port output (5,824 of 7,480 for one boot plus GET, about 580 ms of 748 ms virtual). Route every log line through the existing 0xE2 door (`main.zig:84-95`, `:707-721`), counted as progress for `quiet`/`rested` and feeding `said`; serial stays QEMU's fallback. It shifts every recorded exit count and `FAULT_SEED` schedule, so it lands at a release boundary with a re-baseline. It would speed every metal-vmm gate, the long tier's lossy sweep included.

*(The cloud session adds items here, one line each on why. Taken or retired proposals are in the archive.)*

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
- **`fat16_test.zig`'s limits are not in `properties`** (no 8.3 alias left,
  a directory at FAT's most entries, too deep to check or remove), so four
  named properties show MISS there. Calling those tests' setups from a
  `properties` tier, or a `floor_sim` drive of each, would put them on the
  floor. Each costs a full directory or a deep tree: minutes of runtime.
- **The `writeRuns` re-checks** (a chain that ends before its size, past
  `chainEnd`'s walk) wait on a disk that lies between two reads; a
  `floor_sim` case with `Block.Fault.garbage` at the right request number
  could reach them, but finding that number by search is fiddly.
