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
- **CC:** Shale's work is the box's (Steve, 2026-10-22), but for 244. The
  box builds with a patched Zig 0.17.0 (FEEDBACK, 2026-10-26).

## CC: open

**Your role (Steve, 2026-10-08): build what needs no emulator, and anything
adversarial.** Every item here runs on the host: `zig build test
-Dtest-file=<file>` runs one zig-metal-unikernel test file in seconds (the whole step
takes minutes); metal-vmm's `zig build test` and its `sweep_test.sh` need no
guest. Where a claim needs a real boot, write the recipe under Questions for
the box instead of guessing. Findings arrive as red tests where they can.

**247. Shale says where a run's time went; two of your follow-ups: CC'S** (Steve, 2026-10-27, on the box's essay notes/polishing-shale-and-roc.md: "Claude has to stop tolerating long wall times... shale should be able to help us instrument slowness"; and on your six suggestions: improve Shale mostly by dogfooding, "better for Shale to be good at tasks that we actually do than to be perfect for things we rarely do"). After 246, from shale master as the box merges your branch. Each chunk: a red test where there is a defect, then the fix, one commit each; anything checked and found clean is listed in FEEDBACK.

**A. Slowness, said by the run itself (M; the lead item).**
- The case: today a gate printed `0 s` for every part, because `now()` is the run's start, and a cold agent's step took 55 min because `roc build` defaulted to LLVM. Nothing in the run said where its time went.
- **The run's own account:** after a script that ran any program, the `── used:` footer also says how many programs ran, their total wall time, and the slowest one's argv (cut short) with its seconds. `run`'s `ms` is already there to sum.
- **Give `job_wait` the same.**
- **Keep it inside Shale's niche:** no profiler and no hooks; `run` and the jobs are already the seams.
- Propose the footer's exact form in FEEDBACK before landing it if you are unsure, and say what it costs per `run` (it should be nothing measurable).

**B. `jobs.stop` TERMs `r.pid` without checking its start (S; your #2).** A red test with a forked pid, as you proposed.

**C. A recipe that puts a user's `arg` into an argv (S; your #1).**
- The places: `cookbook/run.shale`'s `cmd=`, `cookbook/zig_build.shale`'s `step=` and `grep=`, and any other recipe that builds an argv from `arg(...)`.
- A value that starts with `-` becomes the program's option.
- The fix: refuse it where the recipe reads it, or use one prelude helper that the git prelude's `git_value` could share. Choose by what the recipes actually need.

**Not now:**
- your #6 fixture host: add an awkward case to a shared fixture when a real defect needs it, not up front;
- #3-#5: take one only when dogfooding hits it.

**246. Shale: `sleep(ms)` on Linux, so a recipe waits without a program: DONE** (Steve, 2026-10-27, from 245 D: "please add them".) Start from shale `master` `21f1d21`, merged into CC's branch. **Why:** `now()` is the run's start, so a script has no clock to wait on. Its only way to wait was `run({"sleep", ...})`, one of a run's 64 programs (`runs_most`), so cookbook/http.shale's `wait` spent two programs a try and could never finish a long wait. **What, kept narrow for this one use (to grow when another one comes):**
- the Linux prelude's `sleep(ms)` over a host call, `host("sleep", ms)`: it waits, then gives nil;
- `ms` is an integer from 0 to 600000 (ten minutes a call); anything else stops, `argument`;
- it is no program and counts toward no budget but steps (one a call);
- `now()` stays the run's start, as SHALE.md says.
cookbook/http.shale's `wait` uses it: one program a try, so 64 tries a run, said before the first fetch. Its default `every` goes back to 10 s.

**Deliverable:** a red test (the recipe at `minutes=1 every=1` makes its 61 fetches and stops with its own "never held"), then `sleep` and the recipe, with SHALE.md and SHALE-AGENTS.md naming `sleep`. Nothing here needs KVM.

**245. Shale: six bug classes from its last 30 commits, by yield: CC'S** (Steve, 2026-10-27: "find other possible classes of bugs" in Shale's last ~30 commits). Start from shale `master` 3c02198. QUEUE 244 covers paths and values in the wrong normal form and options refused or allowed wrongly; nothing here repeats it. **Deliverable:** a red test for each defect, then its fix, one commit each, on your branch. List what you checked and found clean in FEEDBACK. Nothing here needs KVM.

**A. Option-like values passed into git's argv (M)**
- Seeds:
  - 12bb383 (`git_restore` puts `--source=` and `--` in front of the caller's values: the safe form);
  - d929fc1 (the git calls: many put a caller's value before any `--`);
  - 6c557d4 (the host checks a program's arguments only by substring).
- Class: a value that starts with `-` becomes a git option. One such option, `--output`, writes files that read-only mounts, `may_change` and `--undo-on-stop` never see.
- Where to look, in `src/shale_prelude_git.shale`:
  - `git_show`: `what`, with nothing before it;
  - `git_log`: `range` and `ref`;
  - `git_diff`: `range`;
  - `git_merge` and `git_merge_ff`: `ref`;
  - `git_tag`: `name` and `rev`;
  - `git_push`: `remote`, `branch` and `tag`;
  - `git_worktree_add`: `branch` and `rev`.
  - Also `src/shale_prelude_linux.shale`'s `curl_http`: `method` after `-X`, and the `headers` values.
- Red test, in `src/shale_prelude_git_test.zig`: `git_show("", "--output=x.txt")` and `git_diff("", {range = "--output=x.txt"})`, then `exists("x.txt")`. The test expects a stop that names the value; today git writes the file. A sharper variant points `--output=` into a read-only mount.

**B. A guard that checks only one spelling of a path (M)**
- **This item shares paths with 244: do it right after 244, on the same branch.**
- Seeds:
  - 6c557d4 (a secret reached "by another way, the root or another mount");
  - b18de89 (a writable mount inside a read-only one: the first mount that matched decided, not the nearest).
- Class: a refusal that compares strings looks at how a path is spelled, not at the file it reaches. A relative, `./`, `..` or symlinked spelling of a forbidden file gets through.
- Where to look, in `src/shale_host_linux.zig`:
  - `refuseSecretArgs`: it searches each argument for the mount's absolute folder. A relative `keys/tok` contains no such folder and passes. It checks no `env` values and no `stdin`, and nothing that `job_start` does beyond its argv.
  - `refuseSecretsUnder` and `runDirOf`: a mount folder named through a symlink. Check whether `src/shale_host_setup.zig`'s realpath step covers `m.dir`.
  - `underWritableWithin`: mounts nested three deep (read-only, then writable, then read-only), and a writable mount inside a `secrets` one.
- Red test, in `src/shale_ro_links_test.zig`, set up as its secrets test is: `run({"shale-fixture", "lines", "1", "keys/tok"}, {timeout_ms = 10000, tail = 5})` with no `cwd`. The test expects `refused ... holds secrets`; today the program prints the token.

**C. `edits_all` checks less than it then does (S)**
- Seed: metal-vmm's prelude `feedback_archive` made one `edit` per entry, past `edit`'s cap of 64 edits a call.
- Class: a prelude call promises "checked first, nothing written unless all hold". Its check is weaker than the step it guards, so the call stops halfway with files already written.
- Where to look: `src/shale_prelude_linux.shale`'s `edits_all`.
  - Its check never applies the cap of 64 (`edits_most` in `src/script/builtins_change.zig`).
  - A file listed twice is checked against its original text both times, though the writes apply in order.
  - Its count, `#split(text, old) - 1`, may differ from `edit`'s own count: an empty `old`, or one that overlaps itself ("aa" in "aaa").
  - It does not check the `changes` and `change_bytes` budgets.
- Red test, in `src/shale_prelude_linux_test.zig`:
  - The first file takes one edit and the second 65. The test expects a stop with the first file unchanged; today the first file is written before the second is refused.
  - A second test lists the same file twice, the later edit holding only after the earlier one.

**D. Hard-coded sizes that a host cap breaks (S)**
- Seeds:
  - 778a401 and dbfc274 (`count_all` and `find_next` scanned a fixed megabyte, which a smaller `call_bytes` cap stops);
  - C's case of 64 edits a call, seen from the caller's side.
- Class: a recipe or prelude loop sizes its work by a constant or by its input, not by the host's cap. It ends on a budget stop, never with its own message.
- Where to look:
  - `cookbook/http.shale`, the `wait` loop. Each try is two programs run (curl, then `sleep`), and `runs_most` in `src/shale_host_linux.zig` caps a run at 64 programs. The defaults need 61 tries, and the example in the recipe's own header (`minutes=20`) can never finish.
  - `src/shale_prelude_git.shale`'s `git_call` and `curl_http`: `whole = 16777216` against a smaller arena budget.
  - `src/shale_prelude_linux.shale`'s `tail_lines`: `part = 65536`.
- Red test, in `src/shale_cookbook_test.zig`: `http.shale url=http://127.0.0.1:1/ wait=x minutes=1 every=1`. The test expects the recipe's own "never held" stop after 61 fetches; today the run stops on the runs budget.

**E. Parsers that skip what they don't recognise (S-M)**
- Seeds:
  - 1593d23 (a `cwd=` that no `arg` read was taken silently);
  - 9285a24 (the doc reader);
  - metal-vmm's archive (lines in a form `queue_next` did not read let it reuse a number).
- Class: a reader of structured text, usually another program's output, skips or misreads a form it doesn't expect. The caller gets a quiet wrong answer instead of a stop.
- Where to look:
  - `src/shale_prelude_git.shale`'s `git_status`: it reads a rename's second NUL field only when the first status letter is R or C. A worktree rename (`" R"`) would leave its `from` path parsed as an entry of its own.
  - `src/shale_jobs.zig`'s `parseRecord`: it skips keys it doesn't know, and a record with no `start` reads as `start = ""`.
  - `curl_http`'s header loop: it skips any head line that has no `:`.
  - `git_upstream`: a `# branch.ab` line it can't read gives silent nils.
- Red test, in a repo: `mv a.txt b.txt`, then `git add -N b.txt`. The test expects `git_status` to give one entry, `{code = " R", path = "b.txt", from = "a.txt"}`. **Unverified until red:** first confirm that this git prints `" R"` for an intent-to-add file.

**F. Job lifecycle windows (S)**
- Seed: 8b2c701 (`alive` asked about the process group before the job had made it).
- Class: a job call decides by state that the child sets up only after `job_start` returns.
- Where to look:
  - `src/shale_jobs.zig`'s `stop`: it still waits on the group alone (`signalGroup(pgid, 0)`). With no group made yet it returns "stopped" at once and never sends KILL, though the leader may run on. It should wait on `alive(r)`.
  - `src/shale_host_jobs.zig`: `job_wait` and the wait for a log line, before the log file exists.
- Red test, in `src/shale_jobs_test.zig`: 20 rounds of `job_start`, `job_stop`, then `job_alive` at once. The test expects false every time. **Unverified until red:** the test is sharper with a leader that ignores TERM; add such a mode to shale-fixture if it has none.

**244. Shale's path and value normal forms: hunt the class of real(".") keeping its dot: CC'S** (Steve, 2026-10-27: "have CC look for similar defects in shale"). Start from shale `master` 9b4eb2e. **The defect:** `real(".")` returned `<cwd>/.`, with the dot left in. `absolute()` in `src/shale_host_linux.zig` joined the path onto the cwd without resolving it, so a script that took the folder above `real(".")` got the cwd itself. The Roc chat's quick gate went looking for angry-gopher inside roc-webbox. The fix (9b4eb2e) resolves the path with `std.fs.path.resolve` and adds a test. **Hunt the class:** a path, or any other value, that Shale hands back or compares in a form different from what it means. Look at every builtin and host call that takes or returns a path: `real`, `run`'s `cwd` and `log`, `pathArg` with mounts (`runs:`, `home:`), `exists`, `is_dir`, `read`, `replace`, `edit`, `list`, and the git prelude's `git_real` and `git_call`. Things to look for:
- `.` and `..` segments;
- trailing slashes, which `osPath` trims but other paths may not;
- doubled `//`;
- `""` as the root;
- a mount name with nothing after it;
- symlinks, if Shale promises anything about them;
- two spellings of one file that compare unequal (the change tracker, `may_change` and `edits_all` all key on a path);
- a relative path resolved against the wrong base (the data root vs. the cwd vs. a `cd DIR &&`).

The same class reaches past paths. Look for a builtin whose result needs a second normalising step its docs don't mention. Also look for an option that is wrongly refused or wrongly allowed: `git_commit` refuses `all`, and `run`'s `whole` is an integer where a reader expects a Boolean. Report any such case where the error doesn't name the right option. **Deliverable:** a red test for each defect, then the fix, one commit each, on your branch. List what you checked and found clean in FEEDBACK. Nothing here needs KVM. Shale's work is the box's otherwise; this item is the exception Steve asked for.

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
