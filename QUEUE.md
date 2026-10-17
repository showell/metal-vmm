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

- **v31 serves lynrummy.com:** zig-metal-unikernel `5fbfd87`, angry-gopher `4ac2c5f5`, zig-webbox `d83b2e1`.
- **Dog Park is live** at dogpark.lynrummy.com since 2026-10-16, image dog-park `ab222a2`.
- **v32 gathers on CC's branches:** 221 chunk 3, 222, 224, 225 so far; the box merges them.

## CC: open

**Your role (Steve, 2026-10-08): build what needs no emulator, and anything
adversarial.** Every item here runs on the host: `zig build test
-Dtest-file=<file>` runs one zig-metal-unikernel test file in seconds (the whole step
takes minutes); metal-vmm's `zig build test` and its `sweep_test.sh` need no
guest. Where a claim needs a real boot, write the recipe under Questions for
the box instead of guessing. Findings arrive as red tests where they can.

**Next for CC, in order (Steve, 2026-10-16: "give it all three"):**


**232. Shale's core, ahead of the dogfood design: CC'S, in order** (the box, 2026-10-18, while the design `docs/designs/DESIGN-shale-dogfood.md` in zig-webbox finishes its rounds; these parts have not moved since round 1 and touch no host, so the rest of the design cannot change them). zig-webbox, from master. Both engines, the gate, `charge_test` for anything charged. The design's section "Edits that work" and "Text" are the spec; where this item and the design differ, the design wins and say so in FEEDBACK.
1. **Split `src/script/builtins_store.zig`** (931 lines, past the 1000-line rule once the list form lands): by concern (reading, changing, walking), no behaviour change, the gate unchanged.
2. **Long strings:** **first, the fuzz corpus** (`fuzz_test.zig`) covers levels 0-3, an unclosed opener, end of source inside a closer, `]=]` at the end of source (round 6: the lexer touches every byte of every signed script on metal, so a bug is a kernel panic, not a stop); then `[=[ ... ]=]`, `[==[ ... ]==]`, any level of one or more `=`; `--[==[ ... ]==]` is a block comment, as Lua's; **pin every old case by a test**: `--[[` (level 0) refused as `[[` is, `--[=x` (no second `[`) a line comment as Lua's; **level 0 (`[[`) refused** by name ("a long string needs a level: `[=[`"), since code being edited is full of `]]`. The level must match; the first newline right after the opener is dropped; bytes are raw (no escapes, no `\r\n` folding); a newline before the closer is part of the string. A syntax error right after a long string hints the closer it met ("the long string at L:C closed at L:C; use `[===[`"). Line and column advance through it, so a stop after it is placed right. Red first in `lex` and `errors_test`: levels 1-3 with `]]` and `]=]` inside, CRLF kept, the first newline dropped, a stop on the line after.
3. **`edit`'s list form:** `edit(p, {{old = ..., new = ...[, all = true][, word = true]}, ...})` (arity overloading, as `read` and `sort` have; `edit`'s own option names). **The edits apply in sequence**, each to the result of the one before; each asserted (exactly once unless `all`); one diff; one write; at most 64 edits a call, every pass's bytes charged; refused in a background run before an argument is read (a test says so); it gives the number of replacements made in all; a failing edit writes nothing, prints no partial diff, and its stop names which edit (its index) and why. Red first: a later edit that matches only after an earlier one; a failing third leaves the file byte-identical; an `old` doubled refused with the existing message.
4. **`last(l, n)`:** the last `n` of a list (a new builtin; the design's round 6, the metal adversary: **`take` with a negative count stays the loud `argument` stop it is**, so a count gone negative on the live site is never silently the tail).
5. **`fail(msg)`:** ends a run with a new class `fail`, one line and its trail; `attempt` catches it (state it in SHALE.md beside `attempt`). The Linux CLI exits 1 on it. `parse.zig`'s refusal of `error` ("not in this language") names `fail`. The route's report is frozen by an `errors_test` golden of a whole reply first; its readers (dog-park `test_shale.mjs`, metal-vmm `script-refused.shape`, zig-metal-unikernel `judge_gopher.py`, angry-gopher's tests) are checked for the new class.
6. **Regular expressions gain alternation (`|`)** (lowest precedence, leftmost alternative first; a group around it is the one capture group, `(?:` stays refused), **`\b`** (an ASCII word boundary) and **`{nocase = true}`** on `re_find` and `re_match` (ASCII case folded; **the regex cache keyed by the pattern and `nocase` both**, round 6: keyed by the text alone a nocase program would answer a case-sensitive call; the folding charged) (added by the design's round 5, 2026-10-18: 263 and 219 uses in the evidence), Thompson-linear as the rest; still one capture group, no backreferences. Extend the property test's generator and backtracking oracle; the cost bound still holds on `(a|b)*c` shapes; SHALE-AGENTS.md's recipes that work around the missing `|` rewritten where it reads better.
7. **SHALE.md's own contradictions** (round 4): "No dry run" beside the CLI's dry run; "no network, no host" (to be revisited by the design, so word it as metal's); long strings and `|` now taken; `walk`'s `skip` missing from its entry; `get` missing from the index.
**Not in this item** (the design's, after its rounds): the host table, `run`, mounts, jobs, git, the hook. **Report** in FEEDBACK after each, as before; metal's size before and after, as a number: **the whole gopher.elf image** (round 6), not the script module alone.

**231. Shale: `== nil` and `~= nil` on a map or a list: CC'S** (Steve, 2026-10-18, on CC's recommendation in FEEDBACK: yes). `re_find` gives a map or nil, and `if m == nil` is a `type` stop today. Allow `==` and `~=` with the literal `nil` on either side when the other is a map or a list; a map or list against anything else stays the stop it is. Both engines and the gate; red first in `errors_test.zig` (the comparison that stays refused, its message unchanged) and `interp_test` (the one now allowed); SHALE.md's comparison rules and its `re_find` example. Small.

**230. Shale: regular expressions, and only the prelude a script calls: CC'S, in order** (Steve, 2026-10-18: "yes to regex and the prelude compile; tell CC"). zig-webbox, `src/script/`, branched from master (`01a18aa` or later). Both engines change together; `gate_test.zig` holds them identical; `charge_test` covers every new builtin.
1. **The prelude compiled for what a script calls** (your proposal in 229's chunks 1 and 2 entry): the parser knows a script's calls, so only the prelude functions it reaches (transitively, through the prelude's own calls) are parsed and compiled into its machine memory. **Red first:** `interp_test`'s bound, which 229 raised from 48 KiB to 112 KiB a run, back down for a script that calls no prelude function, and a script calling `walk_upto` holding only what it reaches. A test that every prelude function is still reachable when called (one script each), and the gate unchanged. Say in FEEDBACK what a run holds now, by script.
2. **Regular expressions, a linear-time subset** (your recommendation, as written in 229's chunks 3 and 4 entry): `re_find(s, pattern)` and `re_match(s, pattern)`; literals, `.`, character classes (`[a-z]`, `[^...]`, `\d \w \s`), `*`, `+`, `?`, `^`, `$`, and one capture group; no backreferences, no lookaround. Thompson-style matching, so the cost is linear in the string; charged a step per byte times the pattern's states, so a budget means what it says. A pattern is compiled once per call site or cached by its text, and its own size is bounded (a pattern past the bound is a `limit` stop, not a slow run). **Tests:** a `props_test` property against a reference: on random strings and random patterns from the subset, `re_find` agrees with a small backtracking matcher written in the test (slow, obviously right, test-only); the cost is linear (a pathological pattern like `(a*)*b` on a long `aaaa…` costs about what `a*b` does); errors for every unsupported construct, golden in `errors_test.zig`. Then rewrite the cookbook recipes that `between` and `split`/`sub` helpers carry today where a pattern reads better, and say in SHALE-AGENTS.md which one each task now uses. About 600 lines.
**Report** in FEEDBACK after each, as before.

**229. Shale, a language agents would choose: CC'S, in order** (Steve, 2026-10-17: "I want to get CC busy again"; "improving the core language would be most ideal"; "The best ceiling for Shale is that the agents would like it so much that they would use it on Linux too, even though it's clearly targeting bare metal as its current niche. If Shale were really killer, agents would use it in place of Python/sed/awk for working with code"; "try to make Shale a more attractive language for agents to do normal linux tasks"; "Some of the things that Shale does to play nice on bare metal also apply to conserving tokens"). zig-webbox (`src/script/`, `docs/SHALE.md`). Everything here builds and tests on plain Linux. **Both engines change together** (the tree-walker and the VM), and `gate_test.zig` must hold them identical. **Not yours to change without Steve:** `attempt` never catches a budget (SHALE.md, decided); anything touching `script_route`'s signing, the envelope or the bearer key. The box's cold survey (2026-10-17) found what follows; its evidence is in file:line form below. Language design questions (regex or not, floats, closures) go to FEEDBACK as questions, each with a recommendation, never decided in code.
1. **A stop's call trail.** A stop names only its innermost function (`diag.zig`'s Stop; set at `interp.zig:154,825`, `vm.zig:124,138,161`): the live `where_the_bytes_are` stop read `seq N:18:14 (in the prelude's walk_all)`, the prelude's line, the script's call site lost. Stop gains the frames (function, call-site line:col, prelude frames marked); the report's first line keeps its format, `called from <script>:L:C` lines follow; `attempt`'s failure map gains `trail`. Red first in `errors_test.zig` (a nested call, a recursion, a stop in the prelude called from the script); the gate compares trails. Grep the report's readers first: dog-park `tools/test_shale.mjs`, metal-vmm `requests/shapes/script-refused.shape`, zig-metal-unikernel `probe/judge_gopher.py`, angry-gopher's tests. About 250 lines.
2. **Partial results at a budget.** On the live site (v31) `where_the_bytes_are` stopped at the reads budget inside `walk_all` after 134,718 steps and printed **nothing**: it gathers, then prints, as `chat_topics` and `big_files` do; `find_message` and `stale_caches` guard only `read_bytes` by hand. Add a `walk` option `keep_reads = n` (the part ends with its `more` entry before the run's reads left fall below n; counts only, so deterministic), a prelude `walk_upto` returning `{entries, more}`, and a `room_for(...)` guard on `budget()`. Rewrite those five scripts to print what they have and "resume after X" (a `const START`). Red first: `where_the_bytes_are` under the site's budgets on `shale_scale`'s store just past its fit stops empty today; it must print a partial table and a resume line, and a second run from it complete the totals. About 400 lines.
3. **Lenient reads for real data.** `parse_int(s)` (an integer or nil; `tonumber` stays strict), `read_lines(p, offset, n)` → `{lines, next}` (whole lines only), `line_at`, `get(m, k, default)`. Evidence: `trouble.shale:20,32-33,46,53` (a stray `log-x` file or a 300-byte line stops the whole report), `find_message`'s `head[2]`, `chat_topics.cache()`, `stale_caches.cached()`, the 20-line carry loop at SHALE.md:676-700. `parse_int` and `line_at` were deferred in 220(a); they are wanted now. A `props_test` property: `read_lines` over any part size concatenates to `lines(read(whole))`. Then rewrite those scripts on them. About 350 lines.
4. **Shale as an agent's tool on Linux** (Steve's ceiling). Today `zig build script` (`script_runner.zig`) runs a script with the default budgets. Make it a tool an agent reaches for instead of Python, sed or awk on a code checkout:
   - `shale <file> [name=value ...]` (and `-e '<source>'`), rooted at a directory (the working directory by default), read-only unless a flag allows changes; `arg(name, default)` for the values, which also serves an installed suite later (G5: today inputs are edited into the source);
   - what code work needs, as builtins with budgets and both engines: file globs, a match over lines (literal first; whether Shale gets regular expressions is a question for Steve, with your recommendation), and **edits that show their diff before they write**: a dry run by default, the change made only when asked, every change in the effects log;
   - **the budgets as a feature, said so** (Steve: "Some of the things that Shale does to play nice on bare metal also apply to conserving tokens"): a bounded output budget is a bounded context cost; a stop says where and why in one line; nothing prints unbounded. Name this in SHALE.md's first page, for an agent choosing a tool;
   - **a cookbook against real tasks on this box's repos**, each beside the Python/sed/awk an agent would otherwise write: count the `DEPARTS` lines by reason in zig-metal-unikernel's `src/tcp*.zig`; list the files over 1,000 lines; find every `props.always` message; rename a symbol across a tree with its diff; check a doc's `file:line` references still land. Every cookbook block runs as a test, as SHALE.md's do today. Be honest in it about where Shale is worse.
5. **Dog Park's scripts get zig golden tests** (`tools/shale/`: `games`, `trouble`, `accounts`), on a fixture shaped by `physics_log.zig`; today only `node tools/test_shale.mjs` against a scratch server checks them.
6. **The installed suite, schedule only** (Steve's first idea: scripts on disk once they are well tested): an application declares `{name, source = @embedFile, args, period}`; scheduled runs go through `Site.between` as background runs (webbox's `wake.periodAfter`, `35f3695`, schedules them), yielding to signed ones; the last output per name kept under `{auth}/shale/suite/`, bounded, read by GET. **Running one by name on request touches the auth path: propose it in FEEDBACK, do not build it.**
7. **The docs pass**, after 1-4: an author's checklist at SHALE.md's top (guard every budget a loop spends; the index traps; `parse_int` over `tonumber` for data; read a `more` entry's `kind` first), the budgets and modes of each site in one table, the trail's format, the CLI and `arg`.
**Not yours:** a sized directory listing (each walk entry pays a stat, the reason reads bind first in every scale row: `store.zig:344-366`); a store and metal change only the box can test. **Report** in FEEDBACK after each chunk: its commits, its tests, and what the cookbook found Shale worse at.

**228. DONE in code (2026-10-18; zig-metal-unikernel docs/designs/DESIGN-sleep.md, chunks 1-8; observatory `0025a23`, dog-park `fb3253d`); not deployed: a Dog Park release and the Observatory's droplet are Steve's. The Observatory v1, and what it needs first: THE BOX'S, starting 2026-10-17** (Steve, 2026-10-16: "Let's do /version for Dog Park. Let's go straight to B (app tells kernel timeout amount) before deploying... We can start tomorrow." The plan: essay `notes/the-observatory-v1.md`, https://github.com/showell/essay-repl-server/blob/master/notes/the-observatory-v1.md). In order:
1. **B, the wake time from the application:** a site's `between` returns when it next needs to run; the kernel's idle rest (`probe/gopher.zig`) sleeps until then or until a frame arrives, instead of waking on its short timer. Red first; every application keeps working (chat, Dog Park); measure an idle kernel's exits on metal-vmm before and after.
2. **Dog Park's `/version`:** its commit, `started_ms`, turns held and accounts handed out; small JSON, no secret. Rides a Dog Park release (which starts every game over), with B's kernel in the same image.
3. **The Observatory app:** polls Dog Park's `/version` every `interval_s`, with the client's three deadlines; one line a poll on its disk; one page of the last lines; built with `addAppKernel`; tested with unit tests of its schedule, on Linux against a stalling server, and on metal-vmm's pair mode against dogpark.elf.
Decided (Steve, 2026-10-16): **its own repo** (`observatory`), **a private page** (reached through prod or a Shale script, no Caddy block), **60 s**.

**227. DONE (zig-metal-unikernel `01dbb1e`; long.sh metal PASS). 0a stalls a window that reopens: THE BOX'S, not CC's** (the box, 2026-10-16; v32 waits on it. Steve, 2026-10-16: "You can keep fixes to CC's work for yourself. I prefer to have CC focused on more straightforward stuff." The box fixes it on master, in tcp.zig; CC merges master in. The text below stays as the record). long.sh's rough `shut-window` case (`PEER_SHUT_AFTER=5000 PEER_SHUT_FOR_US=1500000`, `/steve-resume.pdf`, 26,751 bytes) **passes at `63d45cd~1` and fails at `63d45cd`** (0a), on the release kernel and the coverage kernel alike: the peer gets 5,268 bytes, the guest logs "1 response(s) cut by the stop, 21483 bytes never acknowledged", `tcp: 3 timeouts sent something again, 3 window probes`. After the window reopens, at about 1.5 s, the guest sends almost nothing before its 2 s grace ends. **The box's hypothesis, unverified:** a persist timeout (a shut window, nothing lost) goes through `expired` and sets `recovery`; the probe byte fills the cap; the peer's window update acknowledges nothing (`advance` 0), so `recovery` never grows and the send loop breaks at the cap until the next, backed-off timeout. If so, a shut window's probe is not a loss: RFC 9293 §3.8.6.1's probe should not enter RFC 6298 (5.4)'s recovery, or a window update should end it. **Red first** in tcp_test or tcp_sim: a peer that shuts its window mid-transfer and reopens it, which must finish within a few RTTs of the reopening. Also say why no simulator floor caught it (tcp_sim's rough peers do shut windows). Then the box reruns `./long.sh metal`.

**223. FIRST, before 222, about 20 minutes: what stops you running the long tier?** (Steve, 2026-10-16: "empower CC to work on the long gates. I can't remember if it's truly blocked on running QEMU.") The box is studying how to make zig-metal-unikernel's `long.sh` about 10x quicker (round 1: about 48 min, of which the simulators take about 22 min, the lossy sweep about 13 on metal-vmm, and the FAT16 chat judge about 9 on QEMU). If you can run its parts, you can own that work. **Find the blockers; fix nothing; don't run the whole tier.** In FEEDBACK, one line each, with the exact error where something fails:
1. **The machine:** `nproc`, memory, `ls -l /dev/kvm` (and whether you can open it), and `id` (are you in the `kvm` group?). The tools tier 1 needs (`tier1.sh` line 11): qemu-system-x86_64 (and its version), mkfs.vfat, fsck.vfat, sgdisk, mcopy, curl, as, ld.
2. **metal-vmm, needs KVM:** `zig build test` here, then **one** boot. For example, `sweep.sh` with one seed (`VOLUME_SEEDS=1`-style, as long.sh calls it at its step 5), or the smallest boot its README names. Give the time each takes.
3. **QEMU:** one boot of gopher.elf, for example tier 1's `droplet boot` step alone, or one probe. Say whether it ran with KVM or software emulation (TCG), and the time.
4. **The simulators:** `zig build properties` with `-Dseeds=200` or the smallest seed count the build takes (see `long.sh` lines 96-107 for how it is called). Give the build and the run as two times.
5. **Your verdict:** which of long.sh's six phases you can run as they are, which need something you lack, and what that something is.
If KVM is missing, say whether QEMU's software emulation is a usable substitute for any phase, and roughly how much slower.

**224. The long tier about 10x quicker, at about 80% of its value: THE BOX'S from here** (Steve, 2026-10-16: "Please keep 224 for yourself"; chunks 1-4 and 7 are CC's, done; 5-6 the box's, in `long.sh` `85834ee`) (Steve, 2026-10-16: "It's still my goal for the long gopher gates to be about 10x quicker. Quality over quantity... I would trade some thoroughness for speed... Even under QEMU, things should happen at computer scale, not lunch hour scale." Three rounds with a cold agent; the box's call on the result). **After 223, before 222.** zig-metal-unikernel. **v31's long tier, measured on the box (2026-10-16): simulator 1,429 s, fault sweeps 126 s, lossy 151 s, rough 18 s, volume sweep 29 s, FAT16 judge 194 s; about 32 min.** The simulators are 73% of it, on one core (the box has 2). The metal-vmm phases' v20 times (2.7 s a boot) predate the coverage door (metal-vmm `a92ca03`, which removed ~111k exits a coverage boot), so they are probably several times faster today. Measure them before cutting. **Target: about 5 minutes of running, plus builds timed as their own number.** Each chunk measures first, and is done when its phase time is met **and the floor is still fully reached, with no oracle broken**. Chunks 1-4 need no KVM; 5-6 need KVM, which you lack (223), so they are the box's; 7 runs under TCG, yours to try.

1. **Per-simulator timers, events and a floor** (20 min): `properties.zig` prints, for each simulator (TCP plain, rough, crowd; FAT; store; durable; floor; the rest), **`runs, events, seconds, ns/event`**: an event is that simulator's natural unit (a segment or timer for TCP, an operation for FAT and store; say which in a comment). `long.sh` logs the properties build's time apart from the run's. **The floor** (Steve, 2026-10-16, the box's essay `depth-points-at-the-instruments`, https://github.com/showell/essay-repl-server/blob/master/notes/depth-points-at-the-instruments.md): about 1 µs an event. A simulator more than about 10x over it gets one line in FEEDBACK saying why, or a fix; it is a number with its explanation beside it, not a gate and not a warning. Rough arithmetic for scale: v31's 1,429 s suggests about 40 ms (80M cycles) a TCP world; nobody knows its event count yet, which is the point.
2. **A fast allocator for the sweep** (30 min, the one bet): every simulator allocates through `std.testing.allocator`, a `DebugAllocator` that takes a 10-frame stack trace on every alloc and resize (zig 0.16 `std/testing.zig:22-24`; the box checked), in ReleaseSafe too. Thread an allocator through `run*Seed` (`tcp_sim`, `fat_sim`, `store_sim`, `durable_sim`, `floor_sim`, the others); the sweep uses a per-seed arena over a fast allocator, while tier 0's sampled runs keep `testing.allocator` for its leak checks. **Measure first:** 1,000 seeds both ways, per simulator. Done: the simulator phase at least 3x faster at the same seeds.
3. **Seeds by measurement** (20 min): `long.sh`'s `SEEDS` default becomes the smallest N of 1k, 2k or 5k that still reaches the whole `floor-sim.txt`; crowds on 500 seeds, not all (`build.zig:597`'s default). Plus `coverage/seeds-that-failed.txt`: every seed that once broke an oracle, always run (`properties.zig` reads it). A floor line left unreached by a later change fails the tier and names it; raising N or moving the line is a commit. `SEEDS=10000 ./long.sh` stays, for hunting. Done: simulators under 90 s.
4. **Shared setup, two shards** (30 min): one pre-formatted image per disk shape, copied per seed instead of zeroed and reformatted (`test_disk.makeIn`; FAT32's `small32` is 35 MB a seed); then TCP and the rest as two filters run side by side on the box's 2 cores. Done: at most half of chunk 3's phase time.
5. **One kernel per lossy and rough case** (KVM, 20 min): the coverage kernel runs exit for exit as the release one does (metal-vmm README, the coverage door), so each case runs only the coverage kernel and is judged on its page. The release kernel runs only the unhurt case, and its page must equal the coverage kernel's. Delete `long.sh:281`'s rebuild (a cache hit). **Measure first:** one coverage and one release boot of the PDF route, with the cost line's exits by kind, and one image copy. Done: lossy plus rough under 60 s, `floor-metal.txt` fully reached.
6. **Lossy, sampled and two at a time** (KVM, 30 min): the first 4 frames, the last 4, every 5th between; 2 jobs, a folder each. Done: lossy under 30 s, floor-metal fully reached (if sampling loses a floor line, keep the frames that reach it).
7. **The FAT16 judge, its write path only** (KVM + QEMU, 20 min): `JUDGE_QUICK=1` plus only the steps that write, append and rewrite (uploads, churn, bulk). **FAT16 matters again:** Dog Park keeps its data on a FAT16 partition in production. The sims run FAT16 on 3 seeds in 4, and Dog Park's root stays near 90 entries, far below FAT16's 512-entry root. Endurance and stamina stay on tier 3's FAT32. Done: under 90 s, PASS.

**Deferred until a missed bug shows the need (decided):** a seed bank and rebank tool, rotating seeds per release, a nightly run with FEEDBACK entries, a staleness check. **Retired:** crowds on every seed; the release kernel's second run of every lossy and rough case; long.sh:281's rebuild; FAT16 endurance and stamina. Say in FEEDBACK what each chunk measured, before and after.

**225. Two kernels talking: a TCP client, a literate tcp.zig, and metal ↔ metal** (Steve, 2026-10-16: "We want metal-vmm to be able to test two unikernels talking to each other as client/server in an observable way, and we want the gates to be fast! Like under a minute"; the client's Zig "should read almost as a literate transcription of the RFC itself"; "Linux is the witness": metal client with Linux, Linux client with metal, metal with metal). **After 224.** The plan is [`docs/TWO-KERNELS.md`](docs/TWO-KERNELS.md), the product of 15 design rounds (cold agents, three adversarial passes, the box's measurements): build from it, chunk by chunk, in its order, starting with **chunk 0a, RFC 6298 §5.4 in tcp.zig**, a production fix (the native judge's loss check stalled 2 in 5; the box caught it: `given_up` after a go-back phase lock). Its §8's four decisions are settled (Steve took the recommendations: simultaneous open dropped and counted; a 25 ms first SYN RTO for the client only; one reserved slot; L = 1 ms in pair.sh). Take it from there. "Box verifies" chunks wait for the box between pushes; say in FEEDBACK when one is ready.

**226. An out-of-order queue in tcp.zig** (Steve, 2026-10-16: "I see no reason not to have a small out-of-order queue"). **After 225's chunk 7, or in any wait on a "box verifies" chunk.** zig-metal-unikernel. Today a segment that arrives ahead of a hole is re-acknowledged but its data is dropped (DEPARTS 6, `acceptability`'s `.ahead`). The duplicate ACKs are already sent; what is lost is the data, so every segment behind the hole becomes a hole of its own, and each needs its own recovery. After a loss the window is small, so fewer than three segments follow each hole, fast retransmit never fires, and every hole waits on the doubled timer (your chunk 6 seed 2: 41 KB of 195 KB in 3 s with 3 ms of reorder jitter). Against Linux it has cost little so far; between two of our kernels, or on a network that reorders (the Observatory over DO's private network), it stalls. The RFC asks for the queue: RFC 9293 §3.10.7.4, "Segments with higher beginning sequence numbers SHOULD be held for later processing (SHLD-31)"; RFC 5681 §4.2, "the receiver SHOULD send an immediate ACK when it receives a data segment that fills in all or part of a gap in the sequence space". Quote both from `docs/rfc/`, word for word.
- **Small and fixed:** a few segments' worth a connection (you size it; say the bytes a connection costs, and the table's total), no allocation, held inside the window we advertise, so the window never promises room the queue lacks. A segment the queue can't hold is dropped as today and counted (a named reason, not a bool).
- **Taking it:** when the next byte arrives, what it makes contiguous is delivered in order, and one ACK names the new RCV.NXT. A FIN held ahead is taken only when the bytes before it are. Overlapping and repeated pieces are trimmed, never delivered twice. Behind and beyond stay as they are.
- **A pure decision**, as chunk 2's: what an arriving piece does to the queue (hold, merge, refuse full, deliver up to N) decided in `tcp_arrives.zig` or a file of its own, with table-driven tests.
- **Red first:** chunk 6's pinned seed 2 flips from pinning the limit to a test that the transfer completes, under the reorder jitter, well inside its deadline. A tcp_sim world with reordering (any seed) delivers every byte exactly once and in order. Golden traces change only where a segment ahead now lands; say which.
- **Retire DEPARTS 6** and TWO-KERNELS §4's "Known limit" paragraph (the pair stays FIFO; it no longer has to). Count what the queue does (held, delivered from it, refused full) on `/admin/host`'s tcp line.
- **Not in this item:** Limited Transmit (RFC 3042) and SACK. If the pair sim still stalls with the queue in, say so with a seed; that is a separate decision.

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
