# State tracking: changes only by named events, checked in Debug

CC → the box, 2026-10-09 night, from a brainstorm with Steve. Two proposals,
**P139(a) and P139(b)** in QUEUE.md's "Proposed". Both touch image code
(`disk_fat.zig`, `tcp.zig`), so the box decides, and probably does them. CC
can do any part the box hands back.

## The idea

Steve's idea, from code he has worked on: list every valid state and every
valid event, and change state **only** by firing an event. In Debug, each
change is checked against a matrix of allowed (state, event) pairs. In
release the event is ignored and the state is simply set, so it costs
nothing.

Our twist is the coverage SDK. A matrix is a list of things that should
happen, and the SDK already reports what never happened:

- **Every allowed cell is a `sometimes`.** The sweep then reports the legal
  transitions it never exercised. That's transition coverage, sharper than
  line coverage: "a FIN never went from `.sent` back to `.queued`" names a
  missing test.
- **Every forbidden cell is an `unreachable`.** Under `on_broken` (SDK
  `c7baca9`), a unit test that hits one fails at that property.
- **The table is data.** It can be printed as a diagram, compared with the
  RFC's figure, and handed to the simulators as a list of targets.

**It is mechanically possible today, on paper.** The SDK makes one `Site`
per distinct (module, file, function, line, column, kind, **message**), all
comptime (`coverage.zig`, the `S` struct near line 483). One `inline for`
over the table's cells inside `fire`, each cell calling `sometimes(@src(),
..., comptimePrint("{s} -> {s} on {s}", ...))`, therefore gives one
catalogued site per cell from one source line. Every branch of an `inline
for` is compiled, so every cell is in the catalog. **Not yet built or
measured:** whether `tools/scan.zig` (`catalogFile`) needs to know about
generated messages. It reads source text, so it wouldn't see them, but a
compiled `fire` doesn't need it to. The first step of P139(b) is to build
this and look at the report.

**Enforcement.** Zig has no private fields, so the compiler can't stop a
stray `c.fin = .sent`. The cheap guard is a lint: the field is assigned only
inside `fire`, the way angry-gopher's lints already work. The strict form
lets callers name only the event, with the new state a function of (state,
event), so code can't choose a state at all. That fits a machine whose
transitions don't depend on other fields, which is P139(b), and doesn't fit
TCP's `State`, below.

## What I looked at first, and why the obvious target is the wrong one

`tcp.zig`'s `State` has four values (`closed`, `syn_received`,
`established`, `closing`) and 5 assignments. Its doc comment says the RFC's
other states are told apart by `fin` and `peer_done`. The real state is the
product of `State` × `Fin` × `peer_done` × `WindowNews`. A matrix over
`State` alone would say almost nothing; the transitions that matter happen
in the other fields. So neither proposal starts there.

## P139(a). A ledger for clusters taken before a commit (disk_fat.zig)

**The bug class it aims at is the one we keep hitting.** The box's last two
fixes were both clusters "lost and uncounted" after a failure before the
commit:
- `ec77f28`: an append whose link failed;
- `05b0cfb`: an empty file's first chain, and an overwrite's new one.

Both were found by review and pinned by hand-written red tests, not by a
check that runs on every path.

**This is a lifecycle per reservation, not a state machine for the volume.**
`allocChain` takes clusters, and every cluster it takes must end in exactly
one of these:

| end | where it happens today |
|---|---|
| **committed**: an entry on disk points at it | the commit write, `Landing.landed` |
| **given back** | `giveBack`, an `errdefer` before the commit |
| **counted as leaked** | `leftLeaked`, `afterCommit`, a failed `giveBack` (`cleanups_failed`) |

The rules are there already, spread over about a dozen call sites (the
`errdefer if (commit == .before) self.giveBack(...)` lines, and the
`switch (landing)` blocks in `allocChain`, `grow` and the writes). Nothing
checks that every path picked one.

**The proposal, in Debug only:**
- `Volume` gets an `open: u32`, the clusters taken and not yet ended.
  `allocChain` adds what it took.
- The three endings subtract: the commit subtracts its chain, `giveBack`
  what it freed, and a counted leak closes everything open for the
  operation. A counted leak is "unknown", so it can't say how many, and
  doesn't need to.
- Each public operation (`writeFileIn`, `writeInto`, `makeDirIn`, `rename`, `remove`,
  `removeTree`, ...) ends
  with `props.always(@src(), self.open == 0, "fat: every cluster an
  operation took ended committed, given back, or a counted leak", ...)`,
  through one `defer` at its top.
- In release, `open` and the check compile away.

**What it would have caught:** both box fixes above, the first time any
fault test reached the path. `disk_fat_faults_test` already stops every
operation after every write, so the ledger turns each of those runs into
this check, with no test having to count free clusters itself. **What it
won't catch:** a path no fault test reaches. Its `reachable` sites already
say which those are.

**What it needs no new SDK feature for:** it's one `always` per operation.
No generated sites.

**Red first:** revert `ec77f28`'s fix on a scratch branch, add the ledger,
and check that the existing faults test fails at the new property. Do the
same for `05b0cfb`. If either doesn't fail, the ledger misses that path, and
that is the finding.

## P139(b). TCP's `Fin` as a declared machine (tcp.zig)

**Small and clean.** It has 4 states, `none`, `queued`, `sent`,
`acknowledged`, and 5 assignments, which give these events:

| from | event | to | where |
|---|---|---|---|
| none | host finishes (`finish`) | queued | `tcp.zig` ~659 |
| queued | all queued data sent, FIN emitted (`transmitOne`) | sent | ~770 |
| sent | retransmit timeout rewinds (`transmitOne`) | queued | ~738 |
| sent | fast retransmit rewinds (`resend`) | queued | ~825 |
| sent | an ACK covers the FIN (`acknowledge`) | acknowledged | ~910 |

Everything else is forbidden. In particular nothing leaves `acknowledged`
except the slot's reset, nothing goes back to `none`, and
`none → sent` (a FIN with no close) is impossible.

**What it buys:**
- The mechanism above, proved on a table small enough to read in full: per-cell
  `sometimes` sites in the sweep's report.
- One thing to delete: `fin_ever_sent` is a bool kept beside `fin` to
  remember that `sent` was once reached (`acknowledge`'s `always` and the
  sequence count near line 295 read it). A machine that keeps its history, or a `queued` that knows it's a
  resend, could replace it. That's to look at, not promised.
- A template for the next, larger machine: `WindowNews`, or the closing
  states as (`State`, `Fin`, `peer_done`) with the allowed combinations
  written down. Today those live only in `State`'s doc comment.

**What it would have caught:** honestly, nothing we've had. The `u8`
duplicate-ACK overflow and Karn missing on a resent SYN-ACK aren't
transition bugs. Its worth is the coverage report and the template, not a
known bug.

**Red first:** plant a forbidden transition (say `acknowledge` setting
`.queued`) and check that `tcp_test` fails at the cell's `unreachable`.
Delete one test that drives a fast retransmit after the FIN and check that
the sweep reports `sent → queued on resend` unhit.

## A steelman: first-class machines in the SDK

**This section argues a case on purpose, as strongly as I can make it.
It is not my vote; that comes next.** Both proposals above treat the SDK as
it is and build on its `sometimes` and `unreachable`. The strongest case for
going further is that the SDK should know what a state machine is:

- **One implementation, not one per machine.** It would be something like
  `coverage.Machine(State, Event, table)`, with `fire`, the Debug check, the
  `inline for` that makes one site per cell, and the release build that is a
  plain assignment. Built once, in the SDK, with its own tests. Otherwise
  `tcp.zig`, `disk_fat.zig`, angry-gopher and whatever comes next each grow a
  slightly different copy, and the copies drift.
- **The report could show a matrix, not a list.** Today a machine's cells
  would arrive as N unrelated `sometimes` lines, and a reader rebuilds the
  table in their head. If the catalog knew that sites belong to one machine,
  `report.py` could print the state × event grid with hit, unhit and
  forbidden marked. A gap in a grid is visible at a glance in a way that
  line 47 of a list is not. The wire need not change: each cell is still an
  ordinary Antithesis `sometimes` or `unreachable`, and only the catalog
  gains a machine name and a (from, event, to) per site.
- **The explorer gets real targets.** An unhit legal cell is a precise
  goal: "reach `sent` and then see a fast retransmit". A guided explorer can
  steer toward a named cell far better than toward a line number.
- **Products of states, done once and done right.** TCP's real state is
  `State` × `Fin` × `peer_done`. The hard part is a declared set of allowed
  combinations and a check of every field change against it. Done ad hoc,
  that is exactly where a hand copy would be wrong. In the SDK it would be
  written and tested once.
- **The lint comes with it.** "This field is assigned only inside `fire`"
  could be one rule the SDK ships, keyed by the machine's declaration,
  instead of a lint each repo writes.
- **It makes the habit cheap.** If declaring a machine is one line, more
  of our state gets declared, and each declaration is a coverage report for
  free. That compounding is the real prize.

The case against, in one line: there is one candidate machine today
(`Fin`), and the SDK's job so far has been Antithesis's wire and nothing
more. A feature for one user is a guess at the second. P139(b), done
locally first, would show what the SDK version should be.

**LC: please either vote on this (SDK-first, or local-first and promote
later) or riff on it.** A riff is as useful as a vote here. Steve and I
both see the shape and not the details.

## My vote, for the box

**P139(a) first.** It's aimed at the bug class that has cost us the most
this week. It needs nothing new from the SDK, and its red test is two
reverts away. Steve leans the same way.

P139(b) is the better-looking idea and the cleaner piece of code, and it is
the only one that tests the SDK integration, which is what makes this more
than a debug assert. I'd do it second, and on its own merits I'd still do
it. If the box would rather prove the mechanism before spending it on the
volume, (b) first is a fine order too. It's small either way.

**What I'd skip:** a matrix over TCP's four-value `State`, for the reason
above.
