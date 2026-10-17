# QUEUE

The one queue for metal-vmm, zig-metal-unikernel, zig-coverage-sdk,
angry-gopher, zig-webbox and dog-park: what is open, and who has it.
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
- **CC (tonight, unsupervised; the essay `notes/cc-overnight-plan.md`):** 234's report if not sent, then **235, then 236, then 237**; if time is left, a bug hunt in the Linux host (`shale_spawn`, `shale_jobs`, `shale_host_jobs`, `shale_keep`, the secret scrubber's carry across chunks, mounts), each bug a red unit test, nothing new in the gates. A FEEDBACK entry per chunk, so whatever finished can be merged; both images measured each chunk. 233 is done and merged. **The dry run is deleted** (Steve, 2026-10-17; zig-webbox b994ce6): every run writes, `--write` is gone (the gate refuses it), and on Linux git is the undo. Merge master before you push. `?` (optional parameters) stays (Steve, 2026-10-17). The `shale-gate` hook is installed on the box (2026-10-17): top-level Claude runs only Shale; subagents are exempt (zig-webbox SHALE-AGENTS.md, "The gate").

## CC: open

**Your role (Steve, 2026-10-08): build what needs no emulator, and anything
adversarial.** Every item here runs on the host: `zig build test
-Dtest-file=<file>` runs one zig-metal-unikernel test file in seconds (the whole step
takes minutes); metal-vmm's `zig build test` and its `sweep_test.sh` need no
guest. Where a claim needs a real boot, write the recipe under Questions for
the box instead of guessing. Findings arrive as red tests where they can.

**237. A doc checker for cited paths and names, not yet line numbers: CC'S, after 236** (Steve, 2026-10-17, of the box's "should a doc checker enforce `file:N`?": "Paths/names now, lines later"). The want is zig-webbox SHALE-WANTS.md `doc-check`: this morning five cold agents audited every doc in seven repos by hand, and each listed checks a script could run every time. **This item is the first of them, for paths and names only.** After 236, or before it if 235 stops on a disagreement.

- **What it checks**, in each repo's tracked `*.md`. Out of scope: FEEDBACK*, QUEUE-ARCHIVE*, `docs/designs/` and essays, which are history, dated as they were written.
  - **Every cited path resolves.** A backticked or linked token that looks like a path (has a `/` or a known extension: `.zig`, `.shale`, `.md`, `.sh`, `.py`, `.json`) must exist. It is taken against the doc's own repo first, then a sibling the line names (`zig-webbox src/x.zig`, `angry-gopher's ...`), then the box's repos. Found nowhere is a finding; a path in two siblings that the line does not pick between is a finding too, named, so the doc says which.
  - **Every cited name exists where the line says.** For `` `file.zig`'s `name` `` and `` `name` (file.zig) `` and the like, `name` must be a declaration, a field or a test name in that file (235's `zig_decls`, once it lands; until then a word match, said so in the report).
  - **`file:N` is read as `file`:** the line number is not checked (Steve: "lines later"). Count them, so the next decision has a number.
- **How it runs:**
  - one Shale script, zig-webbox `tools/doc_check.shale`, run by `zig build doc-check` over the repos named in a list at its top. It is a second user of zig-webbox's own tools; scripts are first-class.
  - **Not in the gates yet:** its first report goes to FEEDBACK, the box fixes the findings, and Steve decides when it gates. Fail, never warn: it exits non-zero on any finding.
- **Its own tests** (red first), on a small tree of docs and files:
  - a path that's gone;
  - a sibling-named path;
  - an ambiguous one;
  - a name that's gone;
  - a link to a doc;
  - a history file passed by.
- **Report** in FEEDBACK:
  - the findings per repo, in counts, and the first 20 of each kind;
  - the false positives you saw, with the rule that would remove each;
  - how many `file:N` citations there are, and, if it's cheap, how many of them point at the wrong thing.

**236. `router.zig`'s tests split by the box's cut points, with 235's tools: CC'S, after 235** (Steve, 2026-10-17: "Let's do router.zig with you suggesting the cut points"; the essay `notes/cc-overnight-plan.md`). **235's second user**, done with 235's recipe (`zig_decls`, `zig_move`, `zig_rename`, `zig_imports`) and Shale throughout; where the tools fall short, say so in FEEDBACK as you go (that is the point: "a second non-trivial refactoring will lead to us wanting a bit more"). After 235. angry-gopher, from master, `zig-server/src/router.zig` (3,042 lines: ~340 of production, then 61 tests and their helpers from :339's `TESTS` banner on).

**The cut points are the box's; do not choose others.** A file that would come out wrong (a test that needs another file's helper, say) is reported, not re-cut. Line numbers at angry-gopher 1ec3fd13. Each helper used by one file travels with it; a helper two files use goes to the harness.

| file | what | tests (by line) | its own helpers |
|---|---|---|---|
| `router.zig` (stays) | the route table; tests of its private functions | 498 (`routeBodyLimit`), 1662 (families, `familyOf`); a `test {}` importing every file below | |
| `router_harness.zig` (no tests) | the harness every file uses | | `serve`, `serveFrom`, `get`, `status`, `responseHeader`, `responseBody` (:349-399), `UidSite`, `setUid`, `playingAs`, `nowSecs`, `signedUid`, `postAs`, `postForm`, `adminSession`, `memberSession`, `writeTranscript` |
| `router_pages_test.zig` | the public surfaces | 401, 439, 537, 561, 574, 592, 618 | |
| `router_identity_test.zig` | gopher_uid and sessions | 708, 758, 792, 837, 1527, 2362 | `removeSecret` |
| `router_legacy_cookies_test.zig` | the legacy names' migration: **deleted whole the day the legacy names retire** | 1552, 2311, 2334, 2641, 2669 | `currentId` |
| `router_games_test.zig` | games and their bounds | 887, 927, 995, 2384 | `lowDisk` |
| `router_admin_test.zig` | the admin surfaces and the host's setup | 1073, 1096, 1446, 1479, 1602, 1694, 1724, 2231 | `countFiles`, `TestLogs` |
| `router_search_test.zig` | search | 1139, 1195, 1247, 1321, 2442, 2477 | |
| `router_chat_test.zig` | chat's routes | 2091, 2110, 2139, 2206, 2247, 2284, 2416, 2614 | |
| `router_failures_test.zig` | the store-failure class: a failure is a 500, never silence or a lie | 1776, 1837, 1875, 1916, 1962, 2016, 2051, 2176, 2507, 2543, 2557, 2592 | `removalsFail`, `postFailing` |
| `router_script_test.zig` | the script route | 2703, 2784 | `scriptDurable`, `scriptRequest` |
| `router_edges_test.zig` | request edges | 2964 | `EdgeSite`, `edge_sites`, `edge_requests`, `edgeRequest` |

- **Section banners** (`// ── the script route (metal-vmm QUEUE 200) ──`) go with their section; the `TESTS` banner's text (why these tests exist) becomes `router_harness.zig`'s `//!`.
- **Enrolment:** angry-gopher's build lists test roots by hand (build.zig :158) and `router.zig` is its own root (its tests need the assets' wiring, :131-154), so every new file is reached from `router.zig`'s `test {}` block and nowhere else. `router_harness.zig` is imported by test files only.
- **A check that a test runs** (the hole that hid linux_host_test's orphan, zig-webbox bc2402f): in angry-gopher's `ops/check_zig` (fastest first), every `src/**/*.zig` holding a `test` block is a build.zig test root or imported, through a `test {}` block, from one; and no file that is not a `_test.zig` imports `router_harness.zig`. Plant a red for each (an unimported test file; a production import of the harness) and see it fire.
- **The request-edge list:** `router.zig countFiles` (`unreachable_because = "a test's helper"`) goes when `countFiles` moves into a `_test.zig` (the scan skips those): the stale-entry check (1ec3fd13) will say so.

**The judges, all without anyone's eyes:**
1. **gopher.elf byte-identical** before and after (zig-metal-unikernel `zig build gopher`), **once angry-gopher's commit string is set aside**: the image carries it (zig-metal-unikernel build.zig :173, `commitOf`), and it is the same length each time, so replace the after-image's commit with the before-image's and the two must be equal byte for byte. Only test code moves, and test code is not in the server: any other change is a finding, and the split stops there. Check the judge itself first: two builds of one commit agree, and a planted change to a production line in router.zig makes them differ.
2. **The same 61 test names** before and after, module left out (the box's `~/shale-scripts/same_tests.shale` is the shape; yours to write in angry-gopher), and the count the runner reports equal.
3. `ops/check_zig` and zig-webbox's `zig build consumers` green.
4. One commit per file moved, so a bad one reverts alone.

**Report** in FEEDBACK: the commits, the three judges' numbers, and **what 235's tools could not do** that you did by hand, each as a want (zig-webbox SHALE-WANTS.md).

**235. Shale reads Zig with Zig's parser: `zig_decls`, `zig_move`, `zig_imports`; read-only mounts: CC'S, after 234** (Steve, 2026-10-17: "I agree with your plan to use the zig tokenizer. ... divvy up that work among you, CC, and cold agents"). The evidence: the essay `notes/request-edges-and-zig-quirks.md` (https://github.com/showell/essay-repl-server/blob/master/notes/request-edges-and-zig-quirks.md), "What tooling this argues for", items 2 to 4; and the linux_host split, done by hand: zig-webbox 589837e (linux_writes) and 35317cf (linux_reads). A cold adversarial review shaped this text (the box's, 2026-10-17; it checked the citations at zig-webbox 7e2f379 and Zig 0.16's `lib/std/zig/Ast.zig`). zig-webbox, from master once 234 is merged: it builds on 234's host pattern (`host("zig_rename", ...)` in src/shale_host_linux.zig `call`) and core's `rewrite`. Both engines and the gate; `zig build consumers` before each push. **Metal behind the seam, as in 233 and 234:** gopher.elf's and dogpark.elf's images measured before and after each chunk and unchanged; `script.report` frozen (232's golden); all of it Linux-prelude only, gated at comptime. The box reviews each chunk as it lands and writes the docs' recipe.

**One reading of identifier tokens:** `zig_rename` (234) and `zig_move`'s `uses_left` share one walker, with a test that holds them to the same answers on the same inputs (the box's `edits_all`/`edit` lesson: two readings of one rule drift within the hour). **A use without a call counts:** `store.durable_now = scriptDurable;` and `free_space.reader = lowDisk;` (angry-gopher router.zig) are uses; a red each.

**The analysis is Zig's parser and identifier tokens, not types.** Say so in SHALE-AGENTS.md, with the limits below, and that the compiler judges after (`same_tests.shale`).

1. **`zig_decls(path)`: a file's top-level declarations, from `std.zig.Ast`.**
   - **Parsing:** `Ast.parse(..., .zig)` does not fail on bad syntax: `tree.errors.len != 0` stops the run, naming the first error's line (`tokenLocation`), and gives no partial list.
   - **Each is a map:**
     - `kind`: `"fn"`, `"const"`, `"var"`, `"test"`, `"comptime"`, or `"field"` (a file's root may hold container fields; never skipped).
     - `name` and `name_form`: `name_form` is `"identifier"` (a declaration, a field, `test foo {}`), `"string"` (`test "..."`) or `"none"` (`test {}`, `comptime`), and then `name` is `""`.
     - `visibility`: `"pub"` or `"file"`. `linkage`: `"none"`, `"extern"` or `"export"`. Both are enums.
     - `first`/`last`: lines, 1-based, inclusive. `start`/`stop`: bytes.
     - `comment_above`: `{first, last}` or absent. These are the plain `//` lines directly above it: contiguous, no blank line between them and the declaration or its doc comment.
   - **The span:**
     - It starts at its doc comment. Doc comments have no node, so walk back from `tree.firstToken(decl)` over `.doc_comment` tokens. `firstToken` already covers `pub`, `extern`, `export` and `inline`.
     - It ends at the `}` or `;` that ends it. A var decl's or proto's `lastToken` excludes the `;`, so take the next token when it is `.semicolon`.
     - `//!` lines belong to no declaration.
   - **The API:** `rootDecls()`, `fullVarDecl`, `fullFnProto` (`visib_token`, `extern_export_inline_token`, `body_node`), and `.test_decl`'s name token. (`usingnamespace` is gone from 0.16.)
   - **In file order, spans never overlap, and every gap between spans holds only whitespace and comments** (no token but comment tokens). That is the property, over the repo's own `src/**/*.zig`; "the spans and gaps rebuild the file" alone proves nothing.
   - **Red first:**
     - from `git show 589837e^:src/linux_host.zig`:
       - a `pub fn` with a doc comment;
       - `const Hold = struct` (:527) with its nested members: only `Hold` is listed;
       - a `test "..."` block;
       - `const Statfs = extern struct` (:1363): its kind is `const`, its linkage `none`;
     - hand-written fixtures for the rest:
       - an `extern fn` with no body and an `export fn` (their linkage);
       - a doc comment holding `{`;
       - `test foo {}` beside `const foo`;
       - two `test {}`;
       - a root field;
       - a parse error.
   - **Charges:** the file read, its `dupeZ`, and a step per token and per Ast node; the host's charge test (N and 4N).
   - It replaces the box's `~/shale-scripts/file_map.shale` (regular expressions), which the box retires.

2. **`zig_move(from, to, names, opts?)`: move top-level declarations between files, and say what the move broke** (built on 1).
   - **Naming what to move:** `names` entries are a bare name, or `{kind = ..., name = ...}` when a bare name matches more than one (`test foo {}` and `const foo`). A name found twice, or not at all, stops it with nothing written. A `name_form = "none"` declaration can't be named, so it can't be moved; say so.
   - **What it does:**
     - It cuts each span from `from` with the whitespace after it, up to the next token or comment. That leaves exactly one blank line where the declaration was between two others, and none at the end of the file.
     - `opts.comment = "doc"` (the default) takes the doc comment; `"doc_and_plain"` also takes `comment_above`.
     - It puts the declarations in `to` in `from`'s order, one blank line between each and before the first. They go at the end, or after the declaration `opts.after` names; an `after` name missing in `to` stops it.
     - It writes through core's `rewrite`: one logged `edit` per file, the run's `diffs` setting, budgets.
   - **It gives** `{moved = n, needs_pub, needs_import, needs_from_from, uses_left}`, each a list of `{name, line}`:
     - `needs_pub`: moved declarations that are `file`-visible and still used in `from`. 589837e's `Hold` (:527), `Sent` (:593) and `WriteWatch` (:703) were `const X = struct` and needed `pub`. It also lists members `y` of a moved `X` that are not `pub` and are named as `X.y` in `from`: 35317cf's `Progress.Ended`, from `git show 35317cf^:src/linux_host.zig`. It does not add `pub`.
     - `needs_import`: identifiers in the moved code that name a top-level `const` of `from` whose value is an `@import(...)` (`std`, `Io`, `net`): copy that import into `to`, as `{name, target}`. These are never in `needs_from_from`.
     - `needs_from_from`: identifiers in the moved code that name any other top-level declaration still in `from`, such as 35317cf's `sleepMs`. Each one needs `from` imported and the name made `pub`, or the helper copied (35317cf copied `sleepMs`). The script chooses.
     - `uses_left`: each line in `from` that still names a moved declaration, ready for `zig_rename(from_path, "x", "mod.x")`. 589837e's `kept_write_deadline_ms` was already `pub` (:506), and its uses at :483 and :1427 are the red here.
   - **What the analysis skips:**
     - an identifier right after `.` (a field, a declaration access, an enum literal: the essay's `.watch`);
     - a field's declaration, an identifier followed by `:` inside a container (`stream: net.Stream,`).
   - **Known limits, stated and pinned by a red each, never silent:**
     - Methods called through a value (`progress.end(.deadline)`, `old.end(.replaced)`) are not reported; 589837e needed `pub` on the three structs' methods.
     - Names reached through an `@This()` alias (the essay's `host_file`) are not reported.
     - The compiler finds both.
     - A local or parameter can't shadow a top-level name in Zig (the essay's quirk 6), so shadowing is no risk: say that as the reason, not as a limit.
   - **Red first:** the cases above, from both commits. Moving `Hold` lists `std` and `Io` in `needs_import` and not in `needs_from_from`.
   - **The property:** over one contiguous run of declarations, neither first nor last in the file and separated by single blank lines, moving them to an empty file and back (with `after` the declaration before them) gives `from` byte for byte.
   - **The recipe** (SHALE-AGENTS.md, the box's after the chunk), in order:
     1. `zig_move`;
     2. `zig_rename` for each of `uses_left`;
     3. `pub` per `needs_pub`;
     4. the imports per `needs_import`;
     5. import or copy per `needs_from_from`;
     6. the new file into the root's `test {}` block (library_test went red without it in both commits);
     7. `same_tests.shale`.
     
     **CC replays 589837e and 35317cf as this recipe** (on a worktree of each commit's parent; the essay `notes/cc-overnight-plan.md`, a cold agent's idea): that replay is `zig_move`'s acceptance, its diff against the commits made by hand reported in FEEDBACK. **If the replay disagrees with a hand commit, report the disagreement and stop**; do not tune the analysis until the numbers match.

3. **`zig_imports(path)`: a file's `@import` and `@embedFile` calls, from the same Ast.**
   - **Each is a map:** `{kind = "import" | "embed", target, name, line, file}`.
     - `name` is the declaration it binds (`const host_io = @import("host_io");` gives `host_io`), or `""` for one used inline (`@import("x.zig").T`).
     - `file` is `"found"`, `"missing"` or `"module"` (a target with no `.zig`, `.shale` or other extension, such as `std` or `host_io`). A missing file is reported, never skipped.
   - **One reading:** zig-webbox `src/library_test.zig`'s own reader, `refs` (:38-56), which collects imports and embeds, moves into a module both use, as `edge_sites.parseSites` is shared. Two of its readers stay its own: the root's `pub const NAME = @import("....zig")` names (:97-105) and the `test {` block (:153). Say so there.
   - **Each of library_test's rules gets a plant that still fires** after the move (a refactor plants its own failures); list them in the commit.

4. **Read-only mounts.**
   - **The format:** the mounts file is `SHALE_MOUNTS` or `~/.config/shale/mounts` (shale_host_linux.zig `loadMounts` :80; no CLI option). A line may end in ` ro`: `Mount.access: enum { read_write, read_only }`. Any other trailing word is refused, and so is a path with a space. Today's `parseMounts` (:42) reads everything after `=` as the path, so an older binary would take `~/zig-0.16.0 ro` as a path ending " ro": the new reader is the fix, and the box writes ` ro` only once it is merged.
   - **The refusal:** at one point every change passes (`changeAt` and `rewrite`, and `remove`'s and `create`'s own paths if they do not pass it), `refused: mount <name> is read-only`, before anything is written. A test lists every change builtin (`edit`, `replace`, `create`, `append`, `remove`, `zig_rename`, `zig_move`, `edits_all`) through an `ro` mount, so a new one can't skip it quietly.
   - **Reads and programs:** a read through it works. A `run` with its `cwd` there runs, since Shale cannot see what a program writes; SHALE-AGENTS.md says so.
   - It builds on the box's mounts (234's "Not in this item").
   - **The store follows no symlink** (Steve, 2026-10-17: "refuse any"): today `read` of a link inside the root reads its target outside it (the box: a link to /etc/hostname, read). On Linux, a path any part of which (below the root or a mount's own path) is a symlink stops, `refused: <path> is a symbolic link`, for every read, change, `exists`/`stat` and listing; `openat2`'s `RESOLVE_NO_SYMLINKS` or a component walk, your choice, said which in SHALE.md. `walk` already passes links by (builtins_walk.zig): make it the same rule, one place. A mount's own path is resolved once, at load. Metal's FAT has no links: nothing there changes (the images). Red first: a link to a file, to a folder, in the middle of a path, into an `ro` mount.

5. **The git prelude takes its root:** done by the box (zig-webbox a98cd48, with `git_merge`).

**Report** in FEEDBACK after each chunk: commits, tests (red first), both images' sizes.

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
   - **How it writes:** core exports one `pub fn rewrite(run, pos, p, was, now, spans)` from builtins_change.zig: the diff (by the run's `diffs` setting), then `changeAt(..., .edit, ...)`, logged as an `edit`. The host computes the spans and calls it. Unreferenced on metal, so the image does not change. It is a change: budgets (no dry run: it is being deleted, see Now).
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
