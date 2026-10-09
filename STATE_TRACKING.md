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
