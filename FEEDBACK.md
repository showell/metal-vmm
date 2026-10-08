# CC's feedback, 2026-10-08 (items 103-107)

For the local Claude, from the cloud session. Every item below is pushed to
`claude/great-wright-i7aste` in its repo. The details, each with its red
test, are under Questions in `QUEUE.md`.

## Where things stand

| Item | State | Where |
|---|---|---|
| 103, attack the 10-07/10-08 fixes | done: 3 findings, each with a red test; 2 fixed here | metal-vmm, gopher-metal |
| 104, the cold hunt's smaller findings | done: 6 fixed, red test first; 1 answered | gopher-metal, angry-gopher, metal-vmm |
| 105, the store-absence lint | done: lint, its tests, wired into `ops/check_zig`; 67 sites fixed or defended | angry-gopher |
| 106, simulators as a library | done, **not yet written up under Questions** (see below) | gopher-metal `68d3fcb` |
| 107, fat16's surviving mutants | done: 4 killed, 4 equivalent; `MUTATION.md` updated | gopher-metal `3525afc`, `84aaada` |
| 99 | still held, waiting for the request-door rebase | |

## Needs a decision or care at merge

1. **A red test, merged with its fix only.** gopher-metal `fccad06`
   (`fat16_test`, "copies apart and a directory that cannot be read") fails
   until fat16 is fixed. With the FAT copies apart, B26's weighing runs a
   whole `check`, and one directory sector that fails to read fails the
   mount, which stops the boot on metal. The proposed fix is in QUEUE.md:
   a weighing that can't run leaves both copies unwritten and mounts with
   the first. It's fat16, so it's the box's. Until then `zig build test` on
   that branch has exactly one failure, and it's this test.
2. **The counter (item 105), a reversal to confirm.** angry-gopher
   `counter.next` read an unreadable counter as a new one and answered 1,
   reissuing IDs, members' among them. Now absence is 1, and anything else
   that won't read or parse is an error. The old test pinned "a corrupt
   counter restarts rather than failing the request"; a corrupt counter now
   fails the request and keeps the file. That changes a choice made on
   purpose, so Steve should confirm it.
3. **A retire removed a kept member** (item 105, fixed in `e98feb8`). A
   member whose name file wouldn't read got the name "", and was removed
   everywhere. Worth knowing when reviewing the change to `users.zig`.
4. **`store_judge` now runs in the cloud.** `./port.sh` into a scratch
   directory (`GOPHER_SRC=... GOPHER_PORT=...`), then
   `zig build store-judge -Dgopher=<it>`. Both judge tests pass.

## Item 106, for its QUEUE entry

gopher-metal `68d3fcb`:
- **The `In` forms.** `fat_sim`, `store_sim` and `tcp_sim` each have
  `runWithIn(gpa, io, tape)`. `runWith(tape)` keeps its signature and passes
  `std.testing`'s allocator and `Io`, so every test is unchanged.
- **The helpers.** `test_disk.Disk` carries its allocator and `Io` (`makeIn`;
  `make` passes `std.testing`'s). `store_sim` makes its scratch directory
  through the new `scratch_dir.zig`, which makes what `std.testing.tmpDir`
  makes, from any `Io`, and has its own test.
- **The programs.** `explore_bench` and `explore_soak` are ordinary
  executables, whose `main` gives the simulators their allocator and `Io`.
  `zig build explore` now exits 0, with its output as it goes (the old false
  "failed" is gone). `tools/soak.sh` runs `zig-out/bin/soak` as before; only
  its comment changed.
- **No behaviour change**, checked against the commit before (`962c088`):
  - tapes 0–39 through `fat_sim` give the same hash and tape length;
  - tapes 0–19 through `store_sim` and `tcp_sim` give the same outcome,
    tape length and tape bytes.
- The soak needs SDK `main` at `a29a99e` or later (`explore.Options.moment`).

## What I'll do differently (my own process)

- **Cheaper checks while working, the full ones once, at the end, and say
  which.** Steve's guidance, taken: lighter checks for refactors, and
  expensive checks deferred, or partly skipped as long as I say so here. In
  this round I ran full suites far more often than needed.
- **Debug builds while iterating.** Measured here, on gopher-metal with
  nothing changed since the last build:
  - `zig build test -Dtest-file=src/fat16_test.zig` took **41 s**.
  - The same with `-Ddev` took **9 s**.
  - Zig's cache works: with `--summary all` the test's compile step reads
    `cached 8ms`. The time goes into running, not compiling.
  - One oddity for the box: the unit tests still compile as ReleaseSafe
    under `-Ddev` (the summary says so), so the saving comes from other
    steps `-Ddev` changes, not the tests' own build. Worth a look if the
    tests are meant to be Debug under `-Ddev`.
  - The properties sweep and the explorer default to ReleaseSafe (sensible
    for long runs). For a quick check, `-Dsweep-optimize=Debug` and
    `-Dexplore-optimize=Debug` exist.
- **Scope before fixing everything.** Item 105's lint found 67 sites. I
  should have shipped the lint with the dangerous sites fixed (the counter,
  the retire) and asked before doing the other 60-odd.
- **Merge master into my branches, never rebase.** I rebased my metal-vmm
  branch twice, which rewrote hashes I had already cited in QUEUE.md and
  needed two rounds of fixes. QUEUE.md's hashes are correct now.
- **No blanket `zig fmt src/*.zig`.** It reformatted files I hadn't
  touched. I put them back.
