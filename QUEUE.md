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
- **CC:** off Shale (Steve, 2026-10-22: Shale's work is the box's again). Every repo is on Zig 0.17.0 (2026-10-20).

## CC: open

**Your role (Steve, 2026-10-08): build what needs no emulator, and anything
adversarial.** Every item here runs on the host: `zig build test
-Dtest-file=<file>` runs one zig-metal-unikernel test file in seconds (the whole step
takes minutes); metal-vmm's `zig build test` and its `sweep_test.sh` need no
guest. Where a claim needs a real boot, write the recipe under Questions for
the box instead of guessing. Findings arrive as red tests where they can.

**CC stays idle until Steve wakes it (2026-10-20); 241 is its next item then.** Every repo is on Zig 0.17.0 now (FEEDBACK, 2026-10-20): move your environment first.

**241. Shale's internals: every key line run by a unit test, a fuzzer that reaches deep, and the hot paths measured: CC'S** (the box, 2026-10-20, at Steve's ask: "probe for bugs and speedup opportunities"; line coverage toward 100% from unit tests on the key modules; the coverage SDK with a fuzzing strategy; **Shale itself for most of the work**). Start from shale `master` 84473cb (Zig 0.17.0). Each chunk is a branch the box merges; no review is needed between chunks unless a stop below says so. Nothing here needs KVM or QEMU.

**Read first:** shale `docs/SHALE-AGENTS.md` ("Before you reach for the shell" and the cookbook), `cookbook/look.shale`, `cookbook/zig_build.shale`, `cookbook/zig/README.md` and `cookbook/zig/dead.shale`; shale `build.zig` (the `test`, `fuzz`, `script-bench`, `shale-scale` steps); `src/script/gate_test.zig` (every `script.run` in a test is the VM's, held to the tree-walker's, also sliced and as a background run: the fuzzers get that differential for free); zig-metal-unikernel the kernel's Python linecov (gone since 243) and its `build.zig` steps `tcp-coverage`, `fat-coverage`, `store-model-coverage` (~473-564); zig-coverage-sdk `README.md`, `src/coverage.zig`, `src/explore.zig`.

**Working in Shale (the dogfood).** Build `zig-out/bin/shale` first and put it on your PATH; write `~/.config/shale/mounts` for your environment (`repos = <your checkouts>`, `cookbook = <shale>/cookbook`, `zig = <your zig 0.17.0> ro tools`). Then: `look.shale at=`/`find=` instead of `sed -n`/`grep -n`; `zig_build.shale step=...` instead of `zig build ... | grep`; `edit`'s list form and `edits_all` for test edits; the git prelude for commits; `zig_decls` and `cookbook/zig/dead.shale` for what a module holds. **Every time you reach past Shale, keep a line** (`# want: <tag>: <text>` or `# out-of-scope: ...`, as the box's gate logs them) and put the list, counted by tag, in each chunk's FEEDBACK report: those are the next wants.

**Every chunk's judges** (stop and report, don't push on, if one fails after one pass at the cause):
- `zig build test` green, **0 skipped** (after chunk A), its wall time beside the last chunk's;
- `zig build fuzz` green, with the count of hunts it ran equal to the count defined (after A);
- `zig build doc-check -- only=shale` green (a doc that names a moved file or test is fixed in the same commit);
- `zig build consumers` green if you have the sibling checkouts; if not, say so, and the box runs it before merging to master (dog-park's tests, the kernel's gopher.elf, angry-gopher's `ops/check_zig`, metal-vmm's queue tool all build on this tree);
- **every bug found arrives as a red unit test first**, in the module's own `*_test.zig`, named for the behaviour (never a seed number), then the fix, in two commits (red then green) so the box can check out the red one and see it fail.

### A. No carried skips; the hunt step honest (~2 h; first)

Today the 15 tests named `expensive ...` (fuzz_test.zig 2, lex_fuzz_test.zig 1, props_test.zig 11, builtins_test.zig :241 1) are compiled into `zig build test` and each returns `error.SkipZigTest` when `script_test_options.expensive` is false, so every run reports 15 skipped. `zig build fuzz` (build.zig, the `hunt` test ~170-180) runs the same root, `src/shale.zig`, filtered to `"expensive "`: a hunt file that falls out of the imports, or a test renamed without the word, silently leaves the hunt.

1. **A hunt root of its own**, `src/script/hunt.zig`, importing exactly the hunt files: `fuzz_test.zig`, `lex_fuzz_test.zig`, `props_test.zig` (all its tests are hunts) and a new `builtins_hunt_test.zig` holding builtins_test.zig's sweep (it takes `Fixture` from builtins_test.zig, as prelude_test.zig does). `script.zig`'s test block (~239-249) stops importing the three. Every `if (!...expensive) return error.SkipZigTest;` goes, and so does the `expensive` field of `options_of` in build.zig; the `-Dscript-fuzz` count stays.
2. **build.zig:** the `hunt` test is rooted at `src/script/hunt.zig` with no filter. The `test` step **compiles** it (`test_step.dependOn(&hunt.step)`, the compile, not its run), so a hunt cannot rot between expeditions; only `fuzz` runs it.
3. **The count.** The hunt runs under a runner of its own, `tools/hunt_runner.zig` (the `simple` mode, as shale's `tools/timing_runner.zig`), which runs every test in `builtin.test_functions`, fails on any failure **or any skip**, and prints `N hunts ran`. A build-time list in build.zig (`hunt_files`) is the authority, checked at comptime against hunt.zig's imports (the kernel's `unit_files` check, its build.zig ~497-506, is the pattern).
4. **The guard on `test`:** a unit test beside `portable_test.zig`'s source scan that fails on any `SkipZigTest` in `src/` or `tools/` and on any `test "expensive` outside `hunt_files`. Plant it once each way (a skip, a stray hunt) and show it red in the commit message.

How in Shale: `look.shale find=SkipZigTest in=src,tools like=*.zig` before and after; `edits_all` for the moves; `zig_build.shale step=test` for the summary line.
**Done:** `zig build test` prints no `skipped`; `zig build fuzz` prints `15 hunts ran` and fails when one is made to skip (shown, then reverted). **The box judges:** both steps on the box; the plant reproduced by hand once.

### B. `zig build script-coverage`: the lines no unit test runs, per key module (~3-4 h)

**How line coverage works today.** It is not the coverage SDK. The SDK (`src/coverage.zig`) is property assertions (`always`, `sometimes`, `reachable`, a catalog of every site by `tools/scan.zig`); it says which *named cases* a run reached. Line coverage is zig-metal-unikernel's the kernel's Python linecov (gone since 243) (147 lines, Python): each test binary is run once under ptrace with a one-shot `0xCC` at the first address of every line of the measured file, from `readelf --debug-dump=decodedline`; the verdict is the union over the binaries, lines with code that never ran printed with their text, a closing `}` not counted, and **a binary that does not exit 0 fails the measure**. build.zig wires it as one `addSystemCommand` per source file with each test binary added by `addArtifactArg` (`tcp-coverage` ~473-483, `store-model-coverage` ~554-564). It needs a non-PIE x86-64 Debug test binary, as `zig build test` makes.

1. **The tool.** Default (Steve's to change, below): **port `linecov.py` to Zig** as `tools/linecov.zig` in zig-coverage-sdk, exposed as an artifact `linecov`, so the kernel (its first user) and Shale (the second) share one, and the Python can go once the kernel switches. Its judge is the Python itself: on the kernel's `tcp_test` binary, both print the same lines for each of `src/tcp*.zig`, held as a test in the SDK until the switch. **It must handle what Shale's tests do that the kernel's don't:** they fork (`shale_spawn.zig`) and exec the fixture and `shale --reap`. An untraced child inherits the patched text, so a child that runs a measured line before its `exec` dies of `SIGTRAP`. Set `PTRACE_O_TRACEFORK|TRACEVFORK|TRACECLONE|EXITKILL`, and on a new child put the original bytes back and detach it; on a thread (`CLONE_VM`), wait with `__WALL` and handle its traps as the leader's. **Red first:** a fixture test that forks and runs a measured line in the child fails under the ported tool before the fix. Reading DWARF: `std.debug.Dwarf`'s line program if it serves, `readelf` otherwise (say which, and why).
   **The pin:** zig-metal-unikernel's build.zig pins the SDK's `build.zig`, `src/` and `tools/` (`coverage_sdk_pin`, ~1041), so a new file under `tools/` stops the kernel's build until the pin moves. Move the pin in a zig-metal-unikernel branch of its own, with nothing else in it; the box merges it with the SDK change.
2. **Shale's build.zig:** the SDK as a **lazy** path dependency (`.lazy = true` in build.zig.zon, `b.lazyDependency`), so `test` and the applications that build Shale never need it; a step `script-coverage` running `linecov` once per key file (C's list) over the two unit binaries (the `src/shale.zig` and `src/shale_linux.zig` roots, built Debug), **not** the hunt (100% means from unit tests). The gate test and the signer test binaries are added where their files are measured.
3. **The report, in Shale:** `tools/coverage.shale` runs the step (`run`, a `whole` keep), and prints one `table()`: module, lines with code, ran, %, and the first few uncovered lines with their text; the full list per module to `.zig-cache/coverage/<module>.txt` for `look.shale at=`. A **floor file**, `coverage/lines.txt`, holds each module's count of uncovered lines, and the script fails when any count differs from it, up or down (strict equality: a chunk that covers lines moves the floor in the same commit, so the file is the record of the climb).

**Done:** `zig build script-coverage` and `shale tools/coverage.shale` print the table for every key module; the baseline numbers in FEEDBACK. **The box judges:** the step on the box gives the same counts; the Zig `linecov` and zig-metal-unikernel's the kernel's Python linecov (gone since 243) agree on the kernel's tcp files; the kernel's build with the moved pin.

### C. Coverage to 100%, module by module, worst risk first (several chunks, each ≤ a few hours)

**The modules, by risk** (lines today; risk is how much untrusted input reaches them and how intricate they are):

| order | module(s) | lines | why |
|---|---|---|---|
| C1 | `script_route.zig` | 634 | the live site's `POST /admin/script`: the envelope is read **before** the Ed25519 check; sequence durability; background/kill modes |
| C2 | `src/script/regex.zig`, `builtins_regex.zig` | 661 + 95 | a linear-time engine; pattern and subject both from a script; refusals by name |
| C3 | `src/script/lex.zig`, `src/script/parse.zig`, `src/script/diag.zig` | 553 + 1012 + 86 | every byte of every script; the nesting budget; the one-line stop |
| C4 | `src/script/compile.zig`, `src/script/vm.zig`, `src/script/process.zig`, `src/script/collect.zig` | 590 + 471 + 272 + 177 | step parity with the walker, slices and yields, `attempt`'s unwinding, copy-at-yield |
| C5 | `src/script/interp.zig`, `src/script/value.zig`, `src/script/builtins_store.zig`, `src/script/script.zig` | 963 + 280 + 152 + 256 | the budgets charged (`Run.charge`, `enter`); the root's confinement (no `..`, no absolute path) |
| C6 | the other builtins: `builtins_change.zig` (writes), `builtins_read.zig`, `builtins_text.zig`, `builtins_lists.zig`, `builtins_walk.zig`, `builtins_time.zig`, `builtins_format.zig`, `builtins_numbers.zig`, `builtins.zig`, and `shale_suite.zig` | ~2,700 | each a builtin's charges and limits; the suite runs on the site |
| C7 | the Linux host: `shale_spawn.zig`, `shale_keep.zig`, `shale_jobs.zig`, `shale_host_jobs.zig`, `shale_host_run.zig`, `shale_host_linux.zig`, `shale_host_zig.zig`, `shale_zig_ast.zig`, `shale_zig_move.zig`, `shale_host_setup.zig`, `src/script/cli.zig` | ~4,300 | an agent's tool, not the site's: local input, but a bug here edits a checkout wrongly |

Not measured: `script_runner.zig` and `shale_sign.zig`'s `main` (run as programs, not from a unit binary), `script_bench.zig`, `shale_scale.zig`, `shale_fixture.zig`, the test files.

For each module, in its own commit (or a few):
- **Dead code first:** `cookbook/zig/dead.shale` on the module, and for each uncovered line, the question "can any input reach this?" A line no input can reach is **deleted, not tested** (an impossible branch becomes an `unreachable` or an assert that the code makes true, saying why); a `pub` that nothing uses is a question for the box, not a deletion.
- **Then a test for each reachable uncovered line**, in the module's own test file, through the module's own API where it has one (a script through `script.run` for the language, so the walker/VM gate runs it too). A test that only runs a line, asserting nothing, is not one: each asserts what the line does.
- **A line a unit test cannot reach** (a kernel refusal, an allocation that fails outside a budget) is listed in FEEDBACK with why; it is not exempted by a marker until Steve says so (below).
- The floor file moves in the same commit.

How in Shale: `tools/coverage.shale` for the list; `look.shale at=src/script/regex.zig:120-160` to read around each line; `zig_decls` for which function holds it; `edit`'s list form to add tests; `zig_build.shale step=test args=-Dtest-filter=regex` for the module's tests in seconds.
**Done, per chunk:** the module's uncovered count at 0 (or at the listed unreachable lines), the before and after in FEEDBACK, the lines deleted named. **The box judges:** `script-coverage` on the box, the numbers as reported; each new test fails when the line it covers is changed (the box plants one per module: a flipped comparison on a covered line must turn a test red); every deletion compiles and `consumers` stays green.

### D. Fuzzing: deep inputs, invariants, and the SDK saying what a hunt reached (~2 chunks)

What exists: `fuzz_test.zig` (byte mutations of a corpus plus a "soup" of fragments; every run ends inside its budgets and root; the same run twice is byte-identical), `lex_fuzz_test.zig`, and `props_test.zig` (regex against a backtracking reference, edits against applying them in sequence, read in pieces against read whole, split/join, sort, dates, `table()`). Most mutated sources stop at the parser; few reach the compiler and VM deep.

1. **D1. A generator of well-formed scripts** (a new test-only module, `gen`, in shale's `src/script/`): from the grammar (`parse_test.zig`'s "every construct" is the list), scripts that parse, with bounded loops and recursion, every statement and expression form, `attempt`, `yield`, closures over locals, tables nested and aliased, strings near the budgets. Each runs through `script.run`, so the gate holds VM to walker, sliced and as a background run. **New invariants, each its own hunt:**
   - **budgets are exact:** a run that finished using `S` steps (and `R` reads, `B` read bytes, `O` output bytes) finishes byte-identically under budgets of exactly those, and stops with that budget's class under one less; the same for the arena;
   - **a stop is one line with a class:** no newline in its message, a class from the enum, a line and column inside the source;
   - **slicing changes nothing:** `vm_sliced` at every slice from 1 to 64 equals the unsliced run (the gate checks one slice size);
   - **numbers:** `tostring(tonumber(x))` for every i64 extreme and its neighbours; integer overflow stops, never wraps.
2. **The coverage SDK, in the hunt harness** (default: the harness only, below): the generator and the harness declare what a hunt must reach, `coverage.sometimes(@src(), stop.class == .index, "a generated script stops on an index", null)` and the like for every stop class, every budget kind, a yield inside each op that builds a value, an `attempt` catching each class; `coverage.always` for each invariant above. The hunt ends with `coverage.report` and fails on a FAIL; a MISS is printed (the hunt fell short of a case), and the list of MISSes is a floor the hunts climb. Run blind seeds first; then, as an experiment with its own numbers, the generator's choices as `explore.pick`s under a `Tape` and `explore.explore` against blind runs, properties reached per 1,000 runs (the SDK's lab found no gain on wide, shallow simulators; a grammar is deeper; measure, don't assume).
3. **D2. Zig 0.17's own fuzzer for the pure front end.** `std.testing.fuzz(context, testOne, .{ .corpus = ... })` with a `*std.testing.Smith` (lib/std/testing.zig ~1250, lib/std/testing/Smith.zig): built normally, it runs only its corpus and an empty input, so it is an ordinary unit test (no skip); `zig build test --fuzz=100K` (the `--fuzz=N` limit is in lib/compiler/Maker.zig ~505) runs it coverage-guided. Fit: the lexer, the parser (`parse.parseMeasured` with a small arena), regex compile-and-match against props_test.zig's backtracking reference, and `script_route`'s envelope reader. Not `script.run` (the gate copies the store twice per run: too slow for in-process fuzzing). **A small experiment first:** one fuzz test on the lexer under `--fuzz=10K`, to see that it runs in your environment and what it costs, before more.
4. **Every bug found** becomes a red unit test in the module's own test file (the minimal source as a string, named for the behaviour), then the fix; the seed or input that found it goes into the corpus. Fuzzers hunt, never gate: no hunt joins `test`.

**Done:** the hunts and `--fuzz` runs with their counts (seeds, inputs, time), the SDK's report of what they reached and missed, each finding as a red-then-green pair. **The box judges:** `zig build fuzz -Dscript-fuzz=<the number you report>` clean on the box; each red test red at its commit; the MISS list.

### E. Speed: measured, one change at a time (~2 chunks)

`zig build script-bench` (src/script_bench.zig, ReleaseSafe) runs nine cases, each on the walker and the VM, as many times as fit in half a second: ms a run, **steps** (exact, the same on both engines by the gate), ns a step, the arena, and the VM's time over the walker's. `zig build shale-scale` gives the largest site each cookbook script fits under the site's budgets (steps-bound, so it moves only when steps do).

1. **Baseline**, in FEEDBACK: the bench run alternately with itself five times, best of each, so the noise of your machine is known (on the box it swings up to ±7% between identical code). Then, from the code and a profile if your environment has `perf`, the hot paths with numbers, not guesses. Places to look: `vm.zig`'s `Machine.ops` dispatch and `enters` (the walker's step charges, run before each op); the size and layout of `compile.Op` (a tag, three `u32`s, a `Pos`, three more `u32`s: what the loop touches each op versus what only a stop reads); `value.Table`'s `StringArrayHashMapUnmanaged` (a constant field name hashed at every `m.size`); `..` building a string by copy; `push` and the arena's growth.
2. **One change a commit, one hard-coded case each:** before and after alternately, best of five; where the difference is inside the noise, settle it by the machine code of the function changed (`objdump -d` of the ReleaseSafe binary: instructions in the loop, loads per op), as the box's doctrine says. No claim without its numbers.
3. **Steps do not change.** A step is the unit every budget and every site's limit is in (`charge_test.zig` holds it); a speedup that changes a step count changes which scripts fit, and is a question for Steve, not a speedup. `script-bench`'s steps column and `shale-scale`'s table identical before and after.

How in Shale: `zig_build.shale step=script-bench` with its log, and a Shale script that reads two logs and prints the cases side by side (best of N, the ratio); `look.shale` over the objdump saved to a file.
**Done:** each change with its case, its before/after, and its steps unchanged; the changes that did not pay listed too, with their numbers. **The box judges:** the bench on the box, alternately, best of five; steps and shale-scale identical.

**Report** in FEEDBACK, per chunk: what was built, the numbers (coverage per module before/after, hunts' counts and reach, bench before/after), the bugs as red/green commits, the dead code deleted, and the escapes past Shale counted by tag.

**Steve's answers (2026-10-20):**
- **Line coverage lives in zig-coverage-sdk:** the Zig `linecov` there, shared with the kernel, whose pin moves once (B as written).
- **A line no unit test can reach takes an exemption comment:** `// coverage: not run, <why>`, on the line, the why a real reason (a kernel refusal, an allocation that fails only outside a budget). The report counts exemptions per module beside the uncovered lines, and `tools/coverage.shale` lists every one, so they stay visible and few. Deleting or restructuring stays the first choice (C's "dead code first").
- **SDK properties in the hunt harness only**, never in Shale's own modules (D2 as written).
- **100% for the strategic modules, not the whole codebase yet:** C1-C6 (what the site runs: the route, regex, the front end, compiler/VM, interp and budgets, the builtins) are held to 100%. C7, the Linux host, is measured and reported, not held to it.

### F. The preludes' coverage (after C; Steve: "should be fairly easy")

The preludes (`src/shale_prelude_linux.shale`, `src/shale_prelude_git.shale`) are Shale code, which no line tool sees. Two steps, the first cheap:
1. **Every prelude function called by some test:** a Shale script lists each prelude's `function` names (a `re_lines` over the source) and each test file's calls of them, and prints any never called; a unit test fails when one is uncalled.
2. **Lines, from the engine:** the walker and the VM know each step's source position, so a run can record which lines of each prelude it executed (a test-only hook, or `--coverage=<file>` on the CLI that appends `source:line` once each). Then `tools/coverage.shale` reports the preludes beside the Zig modules, with the same floor file and the same exemption comment (`-- coverage: not run, <why>`). The hook must not change step counts (E's rule).
**Done:** both preludes' functions all called; their line coverage in the table, at 100% or with listed exemptions. **The box judges:** the report on the box; a planted uncalled function turns the test red.
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
- **T1/A. Roc in gopher.elf: the chat's router** (roc-webbox
  docs/ROC-CHAT.md §7 milestone 1, the box's: zig-metal-unikernel build.zig).
  angry-gopher `bb9ad6c` (on `claude/great-wright-i7aste`) sends every /chat
  and /channel request through roc-webbox's Roc router (`a7aa6ab`): Roc
  parses the path and runs the prelude, and chat.zig serves the route once
  the call has ended. So `zig build gopher` needs `roc_chat` supplied to
  router.zig: 16 lines, `proposals/T1-zmu-roc-chat.diff` (the module by
  path, as cobble-webbox's are, imports std alone so it is no part; its Roc
  built for x64v1elf by `roc` on the PATH, `-Droc`, `-Droc-webbox-root`).
  Merge the three together. Measured here, applied: gopher.elf 41,529,840
  bytes against 41,492,664 without Roc; built in 84 s; under QEMU (TCG)
  `/chat` and `/channel/ops` 303 to sign in, `/chat/chat.js` 200; probe/judge_gopher.py against the Linux server of the
  same commit passed every case but two, neither the router's: `/version`
  (built `-Dstamp=off`) and **an upload bigger than the heap it keeps: a
  broken pipe where Linux answers 413, which the pre-Roc kernel (838f357)
  fails the same way under TCG**, so it wants a look on KVM whatever T1/A
  does; and a planted Roc crash (roc-webbox `3fe6000`, its test app in the
  router's place, built locally) was `RocCrashed, 500` and the machine
  served on. Every gate
  that builds gopher.elf then needs the pinned Roc
  (`nightly-2026-10-09-258ab27`, roc-webbox `tools/get_roc.sh`). To judge on
  KVM: the judges, boot time, the toolchain in the lynrummy.com kernel.
  **Re-judged on 2026-10-25 with master merged** (zig-metal-unikernel
  `083bff4` with the diff, cobble-webbox `93452a9`, zig-webbox `baa7766`,
  shale `8b2c701`, angry-gopher `dc3445e`): under TCG every case passes but
  `/version` (unstamped), the 40 MB upload included, refused as Linux
  refuses it; 237 s. **Again with C4** (roc-webbox `4012bb5`, angry-gopher
  `ffe98f1`: the Roc serves a topic's reactions, react, pin and unpin, its
  store writes hosted inside the call): the same, `/version` alone, the
  member story's reactions through the Roc; 245 s. **And with C3's
  landing and page** (roc-webbox `3d03ee2`, angry-gopher `6324f7c`): the
  same, `/version` alone; 228 s.
  **The diff's Roc inputs now follow Route.roc's imports** (`chat/Paths.roc`,
  `chat/ZigText.roc`): without them a change to either would link a stale
  router. Also, for C1 (roc-webbox docs/ROC-CHAT.md R6): angry-gopher `zig build
  codec-bench -- <transcript>` decodes a transcript in Zig and in Roc and
  gives time and peak memory; native, synthetic 5.4 MB: 2.1x the time, 1.5x
  the memory. The largest production transcript, on metal, is the box's.
  **And with C3 done** (roc-webbox `80c6383`, angry-gopher `3037312`, this
  diff as of `b5d1bc2`): the same, `/version` alone; 242 s.
- **RC-M1. Milestone for the box to judge: the Roc router, C3 and C4**
  (CC, 2026-10-26; per the box's 2026-10-26 FEEDBACK). On
  `claude/great-wright-i7aste`: roc-webbox `80c6383`, angry-gopher
  `3037312`, with T1/A's diff (this repo's `proposals/T1-zmu-roc-chat.diff`
  as of `b5d1bc2`) on zig-metal-unikernel master. The Roc now serves, not
  delegates: a conversation's landing, a topic's page, /chat and
  /chat/default, /chat/conversations, /chat/msg/<id>, a new topic, and a
  topic's reactions, react, pin and unpin; their reads and the store's
  writes are Zig's, as hosted functions, inside the Roc call. Held here to
  the Zig they replaced by angry-gopher `zig-server/src/chat_actions_twin_test.zig`
  (97 requests both ways, every answer and file the same) and the twins;
  under QEMU (TCG) the judges pass every case but `/version` (unstamped).
  Asked of the box: the judges and the QEMU gates on KVM, and what differs.
- **RC-v1. What "mostly Roc" means: the release candidate's scope** (CC,
  2026-10-26, proposed; the box takes or trims it). **Roc in v1, done on
  the branch:** the router's prelude for every /chat and /channel path (the
  scripts, the gate, presence), and the routes RC-M1 lists. **Roc in v1, to
  do before the candidate:** a message's send (O1 over U2: docs/ROC-CHAT.md
  §6.2's steps in Roc, the store's writes and the fan-out hosted), a
  topic's raw transcript, /chat/links (a static page), and the HTML of
  /chat/recent, /chat/images and /chat/code (C7, not their streams).
  **Zig in v1, delegated by the router:** docs, the reading list (`saved`)
  and search (Steve); every SSE stream (a topic's /stream,
  /chat/notifications, /chat/sidebar/stream, the feeds' /stream), which
  need S1's Stream answer and S2's tests on metal; uploads, upload and
  download (C6: multipart, sniffing, the quota, Range, all judged by the
  uploads cases as they are); the static scripts; and, as hosted
  functions, the fan-out (C5) and every store writer (C8). By request
  count that leaves the chat's pages, actions and sends in Roc, and its
  long-lived and byte-moving routes in Zig. If the box would rather a
  smaller candidate, the cut is after send: C7's pages can follow v1.

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
