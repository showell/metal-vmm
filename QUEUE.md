# QUEUE

The one queue for metal-vmm, zig-metal-unikernel, zig-coverage-sdk,
angry-gopher, zig-webbox and dog-park: what is open, and who has it.
**Finished, retired and answered items are in
[`QUEUE-ARCHIVE.md`](QUEUE-ARCHIVE.md)**, one line each by number with the
commits they name; their full text is `git show 3697b1c:QUEUE.md` and `git show
3697b1c:QUEUE-ARCHIVE.md`. New items continue from 234. The conversation between
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
- **CC:** 234, in order. 233 is done and merged. `?` (optional parameters) stays (Steve, 2026-10-17). The `shale-gate` hook is installed on the box (2026-10-17): top-level Claude runs only Shale; subagents are exempt (zig-webbox SHALE-AGENTS.md, "The gate").

## CC: open

**Your role (Steve, 2026-10-08): build what needs no emulator, and anything
adversarial.** Every item here runs on the host: `zig build test
-Dtest-file=<file>` runs one zig-metal-unikernel test file in seconds (the whole step
takes minutes); metal-vmm's `zig build test` and its `sweep_test.sh` need no
guest. Where a claim needs a real boot, write the recipe under Questions for
the box instead of guessing. Findings arrive as red tests where they can.

**234. Shale, from the first afternoon under the ban: diffs as a setting, a dry run that sees its own changes, a rename that knows Zig: CC'S, in order** (Steve, 2026-10-17: "Please come up with fixes to the 6 pain points. Slice off a decent piece of work for CC"). The evidence: the essay `notes/shale-from-the-inside.md` (https://github.com/showell/essay-repl-server/blob/master/notes/shale-from-the-inside.md) and zig-webbox `docs/SHALE-WANTS.md` (quiet-edit, dry-run-overlay, zig-rename). A cold adversarial review shaped this text (the box's, 2026-10-17); where it cites code, the citations were checked at zig-webbox 816ae11. zig-webbox, from master. Both engines and the gate; `zig build consumers` before each push. **Metal behind the seam, as in 233:** gopher.elf's and dogpark.elf's images measured before and after each chunk; `script.report` frozen (232's golden); what metal never uses is gated at comptime (the `host_io` pattern at parse.zig's `shale_preludes`), never only false at runtime.

0. **`edits_all`'s pre-check** (src/shale_prelude_linux.shale, about :190-202): a `word` edit does not update the text the next edit is checked against, so a later edit that depends on it is checked against stale text. Red first, then fix.

1. **Diffs as a setting, one rule** (the essay: "the diff behind `--verbose`, as the dry run's list is"). A field `diffs: enum { full, summary }` on the run (through `script.Options`, so the gate's three engines get the same), defaulting to `full`, so the route and metal are unchanged. The CLI sets `summary`; `--verbose` sets `full`. No per-call option, and no new flag. `summary` prints one line a change: `edit <path>: <n> hunk(s), -<n_old> +<n_new> lines` (the hunk walk's own counts, builtins_change.zig `writeDiff`), at the place the diff is printed today (before `changeAt`'s budget check; say so in SHALE.md). It keeps the hunk walk's charges and drops only the write's. Red first in builtins_test: the output bytes of a 20-edit call, summary against full. charge_test's `edit` case stays green.

2. **A dry run that sees its own file changes.** Today a dry run logs each change and makes none, so `replace(p, ...)` then `edit(p, ...)` previews the edit against the old file: the dry run misleads at the moment it exists for. In `Mode.dry_run`, hold an **overlay** of file contents and existence:
   - **Every read goes through one view** in builtins_store.zig (`statOrNull`, `has`, `readAt`, `list`), which the twelve or so direct `store.` reads in builtins_read.zig, builtins_store.zig and builtins_walk.zig call instead. The view consults the overlay only when `@hasDecl(host_io, "shale_dry_run")`; metal's `host_io` has no such decl, so metal compiles none of it (the image measurement proves it). A lint fails a builtins_* file that calls a `store.` read directly.
   - **Keys are the resolved path** (`p.full`, after the path hook), never `p.rel`: mounts alias.
   - **What it holds:** a `replace`'s or `create`'s content (already an arena string: no copy until a yield), an `edit`'s result, a removal, and an **append as a suffix**, joined only when a read asks (materializing it on the append would read the real file, spending reads `--write` never spends). `change_bytes` is already charged before the dry-run branch (builtins_change.zig `changeAt`); the overlay's cost is memory, counted against the arena and, at a yield, `kept_bytes`.
   - **It survives `yield`:** it is a collection root, copied at a yield as the effects are (`copyEffects`, collect.zig). Red: in the gate's cut engine, a dry run of replace, then `yield`, then read gives the replaced text.
   - **Reads that see it:** every file read (`read`, `read_or`, `read_lines`, `line_at`, `grep`, `count_lines`, `count_in`, `find_in`, and `edit`'s own read) and `exists`, `is_dir`, `stat` (an overlay file's `size` and `kind`). `remove` checks existence through the view.
   - **Listing a folder the run changed is a stop, named:** `ls`, `walk` (and so `glob`) on a folder under which this dry run created, replaced or removed anything stops, `a dry run cannot list <path> after changing it: run --write on a copy`. Merging an overlay into walk's ordering, budgets and its `more` entry is not worth it; refusing honestly is.
   - **Programs:** a dry run still refuses `run` (`budget runs`), so the overlay helps scripts with no `run` call; do not test it through `git_commit`.
   - Red first: replace-then-edit previews the edit against the replaced text; create-then-read reads it; remove-then-exists is false; an append then a read reads old plus suffix; listing a changed folder stops; past `change_bytes` it stops as `--write` would.

3. **`zig_rename(path, from, to, opts?)`: a rename that knows Zig**, in the Linux prelude over `host("zig_rename", ...)` (src/shale_host_linux.zig `call`), using `std.zig.Tokenizer`.
   - **What it renames:** every `.identifier` token equal to `from`. Never one right after `.` (a field, a decl access, an enum literal: the essay's `.watch`); never `@"from"` (tagged `.identifier`: a byte check); strings, character literals and comments are not identifier tokens. "Part of a longer identifier" comes free from tokens: keep it as a red, not a rule.
   - **When `to` is qualified** (contains `.`), a match in a **declaration position** stops the run, naming the line, and nothing is written: after `const`/`var`/`fn`, a parameter's or field's name before `:`, a capture inside `|...|`. That was the essay's worst miss (`pub const linux_writes.kept_write_deadline_ms`), and token rules alone do not prevent it.
   - **`from`** must be an identifier (refused otherwise); the file must tokenize with no `.invalid` (refused, nothing written).
   - **How it writes:** core exports one `pub fn rewrite(run, pos, p, was, now, spans)` from builtins_change.zig: the diff (by the run's `diffs` setting), then `changeAt(..., .edit, ...)`, logged as an `edit`. The host computes the spans and calls it. Unreferenced on metal, so the image does not change. It is a change: dry run, overlay, budgets.
   - **It gives** `{renamed = n, left_in_comments = m}`: the mentions of `from` in comments it did not touch (the gaps between tokens and the doc-comment tokens), so the author can decide.
   - **`opts.lines = {first, last}`**, inclusive, limits it to a range.
   - **Charges:** the file `dupeZ`'d for the tokenizer, and a step a token. Its charge test lives in the host's tests (N and 4N, as charge_test does: charge_test lists `.host` as the host's own work).
   - Red first: the essay's misses each untouched or refused (`.watch`; the comment word "asks" beside a variable `asks`; a test's name, a string; `pub const from = 1;` with a qualified `to` stops). A property: over the repo's own src/*.zig, renaming `a` to `b` and back gives the file it began with when `b` is not an identifier token in it.
   - SHALE-AGENTS.md: the refactor recipe (move a block, then `zig_rename` the host's uses) replaces word-mode `edit`.

**Not in this item** (the box's): `drop` (done, zig-webbox fdbdafa), the `grep` and Lua-habit docs (done, the same), the mounts (done, on the box), webbox owning its request-edge list. **Report** in FEEDBACK after each chunk: commits, tests (red first), both images' sizes.


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
- **`fat16_test.zig`'s limits are not in `properties`** (no 8.3 alias left,
  a directory at FAT's most entries, too deep to check or remove), so four
  named properties show MISS there. Calling those tests' setups from a
  `properties` tier, or a `floor_sim` drive of each, would put them on the
  floor. Each costs a full directory or a deep tree: minutes of runtime.
- **The `writeRuns` re-checks** (a chain that ends before its size, past
  `chainEnd`'s walk) wait on a disk that lies between two reads; a
  `floor_sim` case with `Block.Fault.garbage` at the right request number
  could reach them, but finding that number by search is fiddly.
