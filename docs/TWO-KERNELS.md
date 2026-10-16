# Two kernels talking: the plan

**Status: a design, not built (2026-10-16).** Written for the implementer
(CC). "Measured" marks a number the box took; "inferred" marks one nobody has
taken yet.

## 1. The goal, and the bars

Steve: "We want metal-vmm to be able to test two unikernels talking to each
other as client/server in an observable way, and we want the gates to be
fast! Like under a minute to exercise the 90% most likely parts of the
protocol."

zig-metal-unikernel's TCP (`src/tcp.zig`) is a server only today. This plan
gives it a client, and gives metal-vmm a way to run two guests against each
other.

The bars:

1. **The client reads as a transcription of RFC 9293** §3.10 "Event
   Processing": it quotes the RFC, and keeps the RFC's step numbering and
   order of checks. Where today's server departs from the RFC, it says so,
   by name.
2. **Linux is the witness.** There are three pairings: metal client with a
   Linux server, Linux client with the metal server, and metal with metal.
   The Linux pairings run first; metal with metal may well find more.
3. **No new "independent" model.** "If we write it, it's not independent."
   `tcp_sim.zig`'s RFC 9293 client (its header, lines 21-29) stays as it is.
   No server model is written. The server gets more reliable by being judged
   by Linux and by our own client.
4. **Under a minute** for the sub-minute gate, with builds cached.
5. **Fail fast.** Every run ends on a verdict the client gives, by a
   deadline, never by the machine's patience. The gate stops at the first
   red.

## 2. The three pairings and their harnesses

| pairing | harness | deterministic | runs on |
|---|---|---|---|
| Linux client → metal TCP | `native/serve.zig` + `native/judge_native.py`: `tcp.zig` as a Linux program on the TAP `gmtap0`, at 10.77.0.2 (exists) | no | the box |
| metal client → Linux server | new `native/fetch.zig` (tcp.zig's client) on `gmtap0` at 10.77.0.2, against a Python HTTP server at 10.77.0.1 | no | the box |
| metal ↔ metal | metal-vmm `PAIR=fetch.elf`: two metal-vmm processes, `gopher.elf` and `probe/fetch.elf`, taking turns (section 4) | yes, byte for byte | the box |

**The native pairings** run in real time against Linux's real stack. Losses
are a seeded sender-side drop in the sub-minute gate, and netem in the long
tier. They need no time protocol and nothing in metal-vmm.

**metal ↔ metal** is the only pairing that exercises virtio, DHCP and ARP
between two kernels, and the only one that replays exactly.

**The QEMU judges are not the Linux witness.** `probe/judge_gopher.py` uses
`-netdev user` with `hostfwd`, so the guest's TCP peer there is slirp's
stack, not Linux's. Those judges keep judging the application.

**`judge_native.py` is not gated today**: no `tier*.sh` calls it. Wiring it
in is part of this plan.

## 3. The TCP layout, and the literate rules

### Four files

- **`tcp.zig`**: `State`, `Conn` (gaining `local_port`, `role`,
  `deadlines`), `Table`, and the user calls from §3.10.1 OPEN to §3.10.5
  ABORT. OPEN is passive (the table listens) or active
  (`connect(ip, port, Deadlines)`).
  - `Table` re-exports the free functions in the other three files.
  - **Only `Table` does I/O.**
- **`tcp_segment.zig`**: §3.1's `Segment`, parsed and built.
- **`tcp_arrives.zig`**: §3.10.7 SEGMENT ARRIVES: CLOSED, LISTEN, SYN-SENT,
  and the synchronized states' steps first through eighth.
- **`tcp_timeouts.zig`**: §3.10.8 (user timeout and retransmission timeout),
  RFC 6298 (the RTO), and RFC 5681 (fast retransmit).

### The rules

**Pure decisions return enums**, each with a table-driven test:
`acceptability`, `resetCheck`, `ackCheck` and `synSent`. `Table` acts on the
enum.

**RFC text is quoted** in `//` comments: the step's words first, then the
code that does them. A step that does not apply says so ("Third, check the
security: not applicable").

**A `DEPARTS:` line names each place the code differs from the RFC.** There
are 12. The first 11 are today's server, all **kept**, so its wire is
unchanged:
1. RST is checked first.
2. SYN is checked before acceptability.
3. A segment with no ACK is dropped before the first check's answer.
4. Segments that straddle the window are not trimmed.
5. An ACK from behind still counts.
6. SYN-RECEIVED ignores segments ahead.
7. An ACK of unsent data is ignored.
8. The window is measured from `una`.
9. Text plus FIN draws two ACKs.
10. LISTEN answers a segment with neither SYN nor ACK with RST|ACK.
11. A segment to an unknown port is dropped silently.

The 12th is the new client's: simultaneous open (a SYN without an ACK in
SYN-SENT) is dropped and counted (`simultaneous_opens_refused`), with no RST.

**`tcp_check.zig` gains a row:** `syn_sent_without_a_timer`.

### An excerpt: SYN-SENT

```zig
/// RFC 9293 §3.10.7.3, SEGMENT ARRIVES, "If the state is SYN-SENT".
/// Pure: what the segment means for this connection. `Table` acts on it.
pub const SynSent = enum { reset_it, drop, refused, established, simultaneous_open };

pub fn synSent(c: *const Conn, seg: Segment) SynSent {
    // "First, check the ACK bit: If the ACK bit is set, If SEG.ACK =< ISS
    //  or SEG.ACK > SND.NXT, send a reset (unless the RST bit is set, if so
    //  drop the segment and return) <SEQ=SEG.ACK><CTL=RST> and discard the
    //  segment. Return.
    //  If SND.UNA < SEG.ACK =< SND.NXT, then the ACK is acceptable."
    const acceptable: ?bool = if (!seg.ctl.ack) null else
        sq.after(seg.ack, c.iss) and sq.atOrAfter(c.nxt, seg.ack);
    if (acceptable == false) return if (seg.ctl.rst) .drop else .reset_it;

    // "Second, check the RST bit: ... If the ACK was acceptable, then
    //  signal to the user 'error: connection reset', drop the segment,
    //  enter CLOSED state, delete TCB, and return. Otherwise (no ACK), drop
    //  the segment and return."
    if (seg.ctl.rst) return if (acceptable == true) .refused else .drop;

    // "Third, check the security": not applicable; there are no compartments.

    // "Fourth, check the SYN bit: This step should be reached only if the
    //  ACK is ok, or there is no ACK, and the segment did not contain a RST.
    //  If the SYN bit is on ... RCV.NXT is set to SEG.SEQ+1, IRS is set to
    //  SEG.SEQ. SND.UNA should be advanced to equal SEG.ACK ...
    //  If SND.UNA > ISS (our SYN has been ACKed), change the connection
    //  state to ESTABLISHED, form an ACK segment
    //  <SEQ=SND.NXT><ACK=RCV.NXT><CTL=ACK> and send it."
    if (seg.ctl.syn) {
        if (acceptable == true) return .established;
        // "Otherwise, enter SYN-RECEIVED ..."
        // DEPARTS: simultaneous open is dropped and counted, not answered.
        return .simultaneous_open;
    }

    // "Fifth, if neither of the SYN or RST bits is set, then drop the
    //  segment and return."
    return .drop;
}
```

`sq` is `@import("seq.zig").Seq(u32)`, as in `tcp.zig` today.
`sq.after(a, b)` is "a comes after b"; `sq.atOrAfter(a, b)` is "a is b or
after it".

`Table` does the effects:
- On `.established`: set `irs`, `rcv_nxt`, `una`, `wnd`, `wl1`/`wl2` and
  the MSS from the SYN-ACK, send the ACK, and stop the SYN's timer.
- On `.refused`: close with a **new** `Abandon.refused`. Today's enum
  (`tcp.zig:770`) is `silent_peer, fin_wait, slow_client, stream_behind,
  unfinished`.

### Changes `tcp.zig` needs for a client

These were checked against today's code.

- **The lookup key.** `find` keys on the 4-tuple (peer ip, peer port,
  **local port**). Today it uses (peer_ip, peer_port) (`tcp.zig:562`), so two
  polls of one site's port 80 would collide while one sits in `.closing`,
  which can last 30 s.
- **The source port.** `segment` writes `c.local_port`, not `self.port`.
- **The port filter.** The `self.port` filter in `handle` (about
  `tcp.zig:1072`, counted `not_for_us`) also accepts an initiated
  connection's local port.
- **`Role{accepted, initiated}`.** The server's host loop picks requests in
  `nextReady` (`probe/gopher.zig:880`). It already skips anything not
  `.established`, and must also skip `.initiated`.
- **Dispatch order.** A found `.syn_sent` connection goes to `synSent`
  *before* the RST block (`tcp.zig:1095`) and the SYN-challenge block.
- **`highest()` and `transmitOne`** gain `.syn_sent` branches beside their
  `syn_received` ones.
- **Ephemeral ports** start at a seeded port and count up, never reused
  within a run (RFC 6056). The server keeps no TIME-WAIT.
- **One reserved slot** for `.initiated`, so a SYN flood cannot starve the
  Observatory's own connects.
- **Deadlines.** `Deadlines{connect_ns, idle_ns, total_ns}` has **no
  default values**.
- **The SYN's first retransmit is at 25 ms**, doubling. The 200 ms floor
  (`min_rto_ns`) exists for peers that delay ACKs (`tcp.zig:113-119`), and
  nobody delays a SYN-ACK.

### The retransmission fix (chunk 0a, before everything)

**Today**, a timeout resends the whole window. `tcp.zig:849`: "**GO BACK.**
Everything from `una` is sent again ... RFC 6298 (5.4) asks only for the
oldest segment."

**The failure.** A sender-side drop of every 13th frame (`GM_LOSE_SENT=13`)
phase-locks with the go-back: each timeout resends the same window, so the
same frame is dropped again. Retries run out, the connection is abandoned
(`given_up`), and its RST can be lost too.

**The fix (RFC 6298 §5.4).** One new field, `recovery: ?usize`, counts the
bytes past `una` that may be on the wire while recovering.

- **On a timeout:** set `sent = 0` as today, and set
  `recovery = max(1, min(mss, high))`.
- **While `recovery` is set,** `transmitOne` sends no byte past
  `una + recovery`.
  - The cap is its own break in the send loop, checked **before** the
    window rule.
  - The one-byte window probe counts against it, so a timeout against a
    shut window still sends its probe.
- **The FIN-only case is unchanged.** If only the FIN is outstanding, a
  timeout sends no bytes and the FIN alone. The FIN's ACK advances `una` by
  1, counts as `acked`, and clears `recovery`.
- **On an ACK of `acked` new bytes:**
  `recovery = (recovery -| acked) + 2 * acked`, which doubles the allowance
  per round trip. Once `recovery >= high`, it becomes `null` and normal
  sending resumes.
- **Fast retransmit** (`resend()`, `tcp.zig:941`) sets `recovery` exactly
  as a timeout does, without touching the backoff.
- `high` is untouched throughout. `reset()` clears `recovery` when a slot is
  reused.

**Recovery cannot stall.** A lost resend times out, and the timeout starts
recovery again at one segment, as RFC 6298 intends.

## 4. metal ↔ metal: two processes taking turns

### The choice

There were three ways to run two guests on one virtual timeline:
- **(i)** one metal-vmm process holding two VMs;
- **(ii)** two processes with conservative parallel discrete-event
  simulation (promises, horizons, an outbox, `poll`);
- **(iii)** two processes passing a token, so that exactly one runs at a
  time.

**This plan builds (iii).**

**Against (ii).** It is deterministic only by proof: its jitter knob, lint
exception and five-seed test exist to catch races. Its one benefit is two
guests running at once, which nobody asked for: a request/response pairing
has one side halted almost all the time.

**Against (i).** It is deterministic by construction, but it costs:
- turning `serve()` into a re-entrant `step()`, moving about 250 lines of
  the loop every existing gate rides on;
- a per-guest namespace for the roughly 300 lines of environment parsing in
  `main()`;
- checking every module-level variable for sharing.

**(iii) is deterministic by construction too.** Only one guest ever runs, and
every decision is a function of the two virtual clocks. It keeps the small
touch to `main.zig`, and each process keeps its own environment, so every
knob applies to *its* guest with no new namespace. It needs only blocking
reads: no outbox, no `poll`, no jitter knob, no lint exception.

Because only one process ever writes, the two processes' stderr interleaves
deterministically, provided each flushes before giving up the turn. The
merged `WIRE_TRACE` therefore needs no sorting.

**What (iii) gives up:** parallelism, which is worth almost nothing here, and
one-process debugging.

### The processes

`PAIR=<client kernel>` makes metal-vmm fork and exec itself, joined by a
`SOCK_SEQPACKET` socketpair.
- **The parent is side 0**, the server (`gopher.elf`).
- **The child is side 1**, the client (`fetch.elf`), with `SIDE=1`.
- Each process's exit code is its own verdict. The parent's exit code
  combines both.

**`WIRE_LATENCY_US` must be set and greater than 0.** It is the lookahead L.
`PAIR=` without it refuses to start. `pair.sh` sets 1000.

### Messages

- **`FRAME{due, side, seq, bytes}`.** `due = sender.now + L`, and `seq`
  counts up per sender.
  - **Eats are decided on the sender only.** `WIRE_EAT` counts that guest's
    own crossing frames, and an eaten frame is never sent.
  - A FRAME is written as the guest transmits it. The other process is
    blocked reading, so it takes each one into its inbox.
- **`TURN{clock, status}`**, where `status` is one of:
  - `running`;
  - `halted{wake}`: the guest is halted, and nothing local wakes it before
    `wake` (`null` means only a frame can);
  - `stopped`: the guest's run is over.

  The first `TURN` to the client also carries **`start{d}`**.
- **An unexpected EOF** means the other process died. That ends the run as a
  failure.

### The turn rule

The holder runs. Its **limit** depends on the other side's status:

| other side | limit |
|---|---|
| `running` at clock c | c + L |
| `halted{wake}` | min(wake, due of the first frame the holder has sent it this turn) + L. A halted guest sends nothing until it wakes, and it wakes at its own `wake` or at a frame's arrival |
| not yet powered on, or `stopped` | ∞ |

**The holder gives up the turn** at either of two moments:
- **an exit would take its clock past the limit;** or
- **it halts with its wake past the limit.** `rest()` first moves the clock
  to the limit.

**Where the turn is given up.**
- **For an exit:** between `KVM_RUN`'s return and the clock's tick. The exit
  is ticked and handled after the next TURN arrives.
- **For the other two clock moves:** the `owed_ns` advance at the top of the
  loop, and `rest()`'s `move_to`, are checked against the limit the same
  way.

**Giving up the turn:** flush stderr, then send `TURN{clock, status}`, then
block reading until the next `TURN` arrives.

**The wake** is the earliest of:
- the LAPIC deadline;
- `card.nextDue(clock)`.

`card.nextDue(clock)` covers three things:
- the local peer's own timers (`peer.wakeAt()`; DHCP stays local);
- the Wire;
- the inbox's earliest due after `clock`, which `card.nextDue` folds in
  (so `rest()`'s wake includes the inbox).

It keeps only dues after `clock`.

**A frame already due and undelivered waits for the guest, not the clock**
(`net.zig:170`, `halt.zig:106`). So every TURN's wake is either after its
clock or `null`.

**`turn_livelock` is a named failure.** Two handoffs in a row with neither
clock moving trip it.

**A clean ending:**
- **A halt with nothing to wake it gives up the turn.** In PAIR mode,
  `rest()`'s `.never` gives up the turn as `halted{null}`, instead of
  returning from `serve()` (`main.zig:791`).
- **The pair ends itself.** A holder that halts with nothing to wake it,
  while the other side is `halted{null}` or `stopped`, ends the pair and
  names it ("both idle"). That is not a hang.
- **A stopped side waits for the end.** A process that has sent `stopped`
  keeps reading until the pair ends.
- **When EOF is expected.** EOF after the other side's `stopped`, or after
  the pair has ended, is expected. Any other EOF is a failure.

### The inbox

Received FRAMEs are kept in order of `(due, seq)`.

**The local peer's frames never enter the inbox.** Its DHCP replies and its
own timers' frames go straight onto `faults.Wire`, as today.

**`pump(now)` drains the inbox**, moving every frame with due ≤ now onto the
Wire. The turn rule guarantees that such a frame has already arrived.

**Head-of-line delay is accepted.** `faults.Wire` is a ring that delivers in
order of arrival (`faults.zig:242`, `ready` looks only at the oldest). A due
remote frame may therefore wait behind a local frame with a later due.

This adds delay and keeps causality. It is deterministic, because both
frames' places in the ring follow from virtual time. Making `ready` take the
earliest due would mean removing from the middle of the ring, which is not a
small change. Local frames are rare after boot.

**Remote frames enter `faults.Wire` through their own entry point.** It skips
the receiver's `peer_lost`, `peer_damaged` and `peer_mangled` picks, and adds
no latency (`due` is already stamped). If the Wire has no room, the frame
**stays in the inbox**. It never pushes out an older frame.

**Receiver-side fault knobs are refused in PAIR mode.** A run that sets one
refuses to start: fail, don't default.

**The pair is FIFO, and no longer has to be.** The inbox's `(due, seq)`
order and one latency L keep each direction in order. Since QUEUE 226,
tcp.zig holds a segment that arrives ahead of a hole (zig-metal-unikernel
`src/tcp_held.zig`), so a reordering wire no longer stalls two of our
kernels: the pair sim reorders in half its jittered seeds, and every one
completes inside the metal bounds.

### Power-on and START

The built-in peer's client, `consider()` (`main.zig:436`), is off on both
sides in PAIR mode.

1. **The client process starts blocked**, reading.
2. **The server runs alone.** Its limit is ∞, because the client is not on.
3. **When the server's `said` shows "listening on port 80"** at clock t, it
   sets `d = t + L`, treats the client as `running` at d (its limit becomes
   d + L), and runs on.
4. **At its first turn-end**, it sends `TURN{clock, status, start{d}}`.
5. **The client powers its guest on at clock = d.**

**A frame due before d is discarded and counted** (`frames_before_power_on`),
for example the server's ARP at boot. It is a named rule, not a silent loss.

### Identity and forwarding

- **`SIDE`** picks the MAC (`52:54:00:12:34:56` + side) and the DHCP lease
  (10.0.2.15 + side) in `frames.zig`. Today both guests would get the same.
- **Each process's own peer** keeps DHCP and 10.0.2.2.
- **What crosses:** every ARP frame, and every unicast frame not addressed
  to 10.0.2.2. Any other broadcast is dropped and counted.
- **`fetch.elf`** takes its target, path and deadlines from the PVH command
  line, e.g. `fetch 10.0.2.15 80 /big connect_ms=150 idle_ms=1000 total_ms=3000`.

### `WIRE_TRACE=1`, and the determinism check

**The trace.** Each side prints one line per crossing frame: virtual time,
side, seq, length, TCP flags, seq/ack numbers, and whether it was eaten or
delivered.
- It is a new instrument, so it is planted: a test-only build that changes
  one byte of one frame must change the trace.

**The determinism check.** One scenario run twice, and once pinned to one
core (`taskset`), must give byte-identical stderr. There is no jitter knob
and no lint exception: the design leaves nothing for one to find.

**EINTR from `KVM_RUN`** is retried before the exit is counted
(`.INTR => continue`, `main.zig:698`), so a signal never moves the virtual
clock.

## 5. Deadlines, and failing fast

| runs | SYN first RTO | connect | idle | total |
|---|---|---|---|---|
| metal ↔ metal; native with seeded single losses | 25 ms, doubling | 150 ms | 1 s | 3 s |
| native random loss (the long tier); the Observatory in production | 25 ms, doubling | 1 s | 5 s | 15 s |

**Why these values:**
- **connect 150 ms** covers two SYN retransmits (25 + 50 ms) and a third
  send.
- **idle 1 s** is five times the server's 200 ms minimum RTO: one loss
  recovers, a stall does not.
- **total 3 s** covers 300 KB plus one backoff chain.
- **In production, idle equals the server's `max_rto_ns` (5 s)**, so one bad
  patch never flaps the Observatory.
- **Random loss gets the production values.** Linux's 200 ms minimum RTO
  doubles under a double loss, so test values would make a flaky gate.

**Failing fast, per pairing:**
- **metal ↔ metal.** Deadlines are virtual, and halts jump time, so a hung
  run ends within 3 s of virtual time: about half a second of wall time
  (inferred). No run reaches `PATIENCE_S` (600 s).
- **Native.** Deadlines are real. The judge's own limit is `total + 1 s`;
  reaching it is a failure, and the report prints the server's `/stats`.
- **Every gate** runs cheapest first and stops at the first red.

## 6. Chunks, in safe order

**Who runs what:**
- **CC** has zig, Python and QEMU TCG (installed 2026-10-16). It has no KVM
  and no TAP.
- **The box** runs native and metal-vmm.

**Conventions:**
- Every chunk is committed and pushed.
- "Red" means the test was seen to fail before the change, or with a plant
  in place.
- **"Box verifies"** marks a chunk whose red CC cannot see. The box runs it
  before the next chunk starts.
- After chunk 1, every TCP chunk names its expected golden-trace changes in
  its commit, or has none.

**0a. RFC 6298 §5.4 in the table.**
- *Files:* `src/tcp.zig`, `src/tcp_sim.zig`.
- *Change:* `recovery` on a timeout, exactly as in section 3, including
  `reset()` clearing it.
- *Done:*
  - a fixed `Scenario` losing every 13th table frame, with a client window
    of 13 × MSS, is red before and green after;
  - a **shut-window** test: against a full but live peer, a timeout still
    sends the one-byte probe, and there is no `given_up`. It is red with
    the cap checked after the window rule;
  - all existing sim seeds stay green.
- *Runs it:* CC.

**0b. Fast retransmit resends one segment.**
- *Files:* `src/tcp.zig`, `resend()` (`:941`).
- *Change:* `resend()` sets `recovery` exactly as a timeout does, instead of
  the go-back. Backoff is untouched.
- *Done:* a sim test shows three duplicate ACKs resend exactly one MSS. It
  is red before.
- *Runs it:* CC.

**0c. The native judge: seeded loss and a stall report.**
- *Files:* `native/serve.zig`, `native/judge_native.py`.
- *Change:* the drop becomes seeded random. The judge catches a stall at its
  own limit and prints the server's `/stats`.
- *Done:* the box runs 10 full native runs with no stall.
- *Runs it:* CC writes; **box verifies**.

**1. Golden traces.**
- *Files:* `src/tcp_sim.zig`, `coverage/tcp-traces.txt`.
- *Change:*
  - pin the `traceOf` hash (`tcp_sim.zig:1819`) for seeds 1-200 in each of
    plain, rough, crowd, and crowd at the table's size (`full_seeds`,
    `build.zig:601`), plus the regression seeds 125, 1332 and 23953;
  - add a test listing every `tcp:` property string, because the floors
    key on them.
- *Done:* changing one byte of an emitted window turns the trace test red;
  renaming one string turns the strings test red.
- *Runs it:* CC.

**2. Extract `Segment` and the pure decisions inside today's `handle`.**
- *Files:* `src/tcp_segment.zig`, `src/tcp.zig`.
- *Done:*
  - golden traces identical;
  - table tests for `acceptability`, `resetCheck` and `ackCheck`, each with
    a planted wrong row seen red.
- *Runs it:* CC.

**3a. Move into the four files.**
- *Files:* `src/tcp*.zig`; `build.zig` (`unit_files`, the `tcp-coverage`
  step); `tools/linecov.py`; `tools/mutate_tcp.py` (`TARGET = "src/tcp.zig"`);
  `explore_soak.zig:56`; the `props.catalogFile` callers.
- *Done:*
  - golden traces and the strings test identical;
  - the coverage catalog builds;
  - the mutation tool finds its targets.
- *Runs it:* CC.

**3b. Quotes and `DEPARTS:` lines.**
- *Files:* `src/tcp_arrives.zig`, `src/tcp_timeouts.zig`.
- *Done:*
  - `grep -c 'DEPARTS:'` totals 12 across the files once chunk 5a lands
    (11 before it);
  - golden traces identical.
- *Runs it:* CC.

**4. The table becomes able to hold a client.**
- *Files:* `src/tcp.zig`, `probe/gopher.zig`.
- *Change:* the 4-tuple, `local_port`, `Role`, the `self.port` filter, the
  reserved slot, and `nextReady` skipping `.initiated`.
- *Done:*
  - golden traces identical;
  - a test opens two connections to the same ip:80 from different local
    ports; a `find` that ignores the local port is red.
- *Runs it:* CC.

**5a. `connect`, `synSent` and the dispatch order.**
- *Files:* `src/tcp.zig`, `src/tcp_arrives.zig`.
- *Includes:* the SYN-ACK's window and MSS, the `.syn_sent` branches, and
  `Abandon.refused`.
- *Done:* a scripted-segment test per RFC step. Accepting
  `SEG.ACK == ISS` is red; dispatching after the RST block is red.
- *Runs it:* CC.

**5b. `Deadlines`, the 25 ms SYN RTO, and `syn_sent_without_a_timer`.**
- *Files:* `src/tcp_timeouts.zig`, `src/tcp_check.zig`.
- *Done:* each deadline fires in a scripted test. A SYN-SENT connection
  with its timer cleared trips the check (red).
- *Runs it:* CC.

**6. Kernel client against kernel server in tcp_sim.**
- *Files:* `src/tcp_sim.zig`.
- *Covers:* loss, duplicates, reordering, all three deadlines.
- *Done:* about 300 seeds green. A plant of a 200 ms SYN RTO fails the
  connect bound.
- *Runs it:* CC.

**7. ARP request plus a one-entry cache.**
- *Files:* `src/arp.zig`.
- *Done:* tests for a request, a reply, and a stale entry replaced. Skipping
  the cache update is red.
- *Runs it:* CC.

**8. `native/fetch.zig` and its judge cases.**
- *Files:* `native/fetch.zig`, `build.zig`, `native/judge_native.py`.
- *Cases:* 200; 300 KB; refused; silent; idle; the SYN eaten 1, 2 and 3
  times; single losses each way.
- *Done:* compiles on CC. On the box, all green, and a plant breaking the ACK
  of the SYN-ACK is red.
- *Runs it:* CC writes; **box verifies**.

**9. `probe/fetch.zig`, the client kernel.**
- *Files:* `probe/fetch.zig`, `build.zig`.
- *Change:* target and deadlines from the command line; one exit code per
  outcome.
- *Done:*
  - a table test maps outcomes to codes;
  - exit 0 against `python3 -m http.server`, reached through slirp's
    10.0.2.2, under QEMU TCG.
- *Runs it:* CC.

**10. Identity.**
- *Files:* metal-vmm `src/frames.zig`, `src/peer.zig`, `src/main.zig`.
- *Change:* `SIDE`, the MAC and lease, the forwarding rules, `consider()`
  off in PAIR mode.
- *Done:* unit tests. Two equal MACs are refused at start.
- *Runs it:* CC.

**11. `turn.zig`, the pure part.**
- *Files:* metal-vmm `src/turn.zig`.
- *Contents:* the limit table, inbox order, the wake (dues after the clock
  only), START and power-on discards, `turn_livelock`, the clean ending,
  refusing receiver-side faults.
- *Done:* tests on scripted clocks, each red with its plant:
  - draining the inbox on arrival rather than at `pump`;
  - a limit of c + 2L;
  - **a livelock plant:** a wake that keeps an already-passed due must
    trip `turn_livelock` within two handoffs;
  - **both idle:** one side `stopped` and the other halting with nothing
    to wake it must end the pair cleanly and name it. It is red with
    `.never` returning from `serve()`.
- *Runs it:* CC.

**12a. The hooks, inert outside PAIR mode.**
- *Files:* `src/main.zig`, `src/halt.zig`, `src/net.zig`, `src/faults.zig`.
- *Change:* the limit check in `serve()`, the cap in `rest()`, and the
  remote entry point into `faults.Wire`.
- *Done:* single-guest `same.sh` output is byte-identical to before.
- *Runs it:* CC writes; **box verifies**.
- *As written* (CC): `turn.Pair` (net.zig's `Net.pair`: `route` in `speak`,
  `deliver` in `pump`, its inbox in `nextDue`), `turn.Hooks` (main.zig's
  `Machine.turns`: `beforeMove` ahead of each tick and of owed volume time,
  `capHalt` in `rest()`, `atNever` at `.never`, `Rested.both_idle`), and
  `faults.Wire.holdRemote`, which refuses on a full wire rather than
  pushing out. Both are null outside a pair. A pair is never snapshotted:
  one side's snapshot is not the pair's (snapshot.zig's `borrowed`).

**12b. `PAIR=`: fork and exec, the socket, TURN and START.**
- *Files:* `src/main.zig`, `src/turn.zig`, `KNOBS.md`.
- *Done:*
  - `PAIR=fetch.elf` gets a 200;
  - two runs, and a run pinned to one core, give byte-identical stderr.
- *Runs it:* CC writes; **box verifies**.
- *As written* (CC): the socket's half is a file of its own, `src/pair.zig`
  (`Link`, behind `turn.Hooks` and `turn.Pair`), so main.zig gains only
  the start and the end. **The client's settings are the server's
  `PAIR_CLIENT_<NAME>`**, unprefixed: only `WIRE_LATENCY_US` and `PAIR`
  go to both (a `VOLUME` or `COVERAGE_OUT` inherited by both would be
  shared by both). The command line is `PAIR_CMDLINE`. A frame the server
  sends while the client is off is not sent, and is counted (`sent before
  the client was on`): it is exactly a frame due before d. Each side
  prints one `pair side N:` line at its end, while it holds the turn, so
  stderr stays in turn order. The test with two scripted guests on two
  threads, over a real socket, is red with a limit of c + 2L: frames
  arrive late.

**12c. `WIRE_TRACE`.**
- *Files:* `src/turn.zig`, `src/main.zig`.
- *Done:* the one-byte plant changes the trace (red).
- *Runs it:* CC writes; **box verifies**.

**13. `pair.sh`, and the tiers.**
- *Files:* metal-vmm `pair.sh` and `plants.sh`; zig-metal-unikernel
  `tier2.sh` and `tier3.sh`.
- *Change:* the scenarios, the eat sweep, the plants; native and pair wired
  into the tiers.
- *Done:* each plant turns its scenario red.
- *Runs it:* **the box**.

## 7. The gate

Steve's order: native pairings first, then metal ↔ metal. Stop at the first
red.

| step | scenarios | time |
|---|---|---|
| 0. tcp_sim | kernel-client worlds, golden traces | ~5 s, inferred |
| 1. native, Linux client → metal TCP | a subset of `judge_native.py` (listed below) | **unmeasured** |
| 2. native, metal client → Linux server | 200; 300 KB; refused; silent (150 ms); idle (1 s real); the SYN eaten 1, 2 and 3 times (the third must hit the connect deadline); single losses over the first ~12 and last ~8 frames each way | ~6 s, inferred |
| 3. metal ↔ metal | the same scenarios, deterministic, plus single losses over the first ~12 and last ~8 crossing frames each way, counted from the unhurt run | ~45 runs × ~0.5 s ≈ 22 s, inferred |
| total | | ~35 s plus step 1 |

**Step 1's subset:**
- bytes, half-close and reset;
- lazy close, 30 connections;
- concurrent, kept small;
- single losses from the server's side (the first ~12 and last ~8 frames).

The full judge takes 30-34 s when green (measured), and its
`check_connections` alone makes 5,000 connections. That check stays out of
this gate.

**Measured anchors:**
- one single-guest boot plus GET: 0.28-0.30 s wall, 7,480 exits, about
  750 ms virtual, 32 frames each way;
- copying the image: 5 ms;
- a socketpair round trip: 15 µs or less.

**Inferred:**
- **A pair run takes about 0.5 s:** the server boots, then the client boots
  and fetches.
- **Turn overhead is small.** With L = 1 ms, a turn changes hands at most
  every 10 exits while both guests run (each exit is about 40 µs of real
  time), which is about 4% overhead. A halted partner changes hands far
  less.

**The long tier:** 6-8 seeds of random loss at 5% and 20% on a 300 KB
transfer, at the production deadlines. Native runs use netem; metal ↔ metal
uses `WIRE_LOSS`.

**When a native run fails, the report gives:**
- the pairing, the scenario and the loss seed;
- the server's `/stats` and the client's outcome code;
- a pcap of `gmtap0`.

Native runs cannot be replayed. A failure is re-run on its seed. If it is
real, it is reproduced in tcp_sim or metal ↔ metal before it is fixed.

## 8. Decisions (Steve took the recommendations, 2026-10-16)

1. **Simultaneous open:** dropped and counted, no RST.
2. **The SYN's first RTO:** 25 ms, for the client only; the server's
   200 ms floor stays.
3. **The reserved slot:** exactly one, for `.initiated`.
4. **The pair's latency L:** 1 ms in `pair.sh`, with no default in
   metal-vmm.

## 9. How to tell you're done

- **Chunk 0.** 0a-0c have landed, and ten full native runs show no stall.
- **The layout.**
  - `tcp.zig` is four files that read against RFC 9293 §3.10 with quotes;
  - `grep -c 'DEPARTS:'` totals 12;
  - the golden traces changed only where a commit said they would.
- **The client.** `fetch` returns the right outcome code against Linux
  (native), against `gopher.elf` (metal ↔ metal), and under QEMU TCG.
- **The pair.**
  - `PAIR=fetch.elf` gives byte-identical stderr run to run, and pinned to
    one core;
  - single-guest `same.sh` output is unchanged.
- **The plants.** Every plant named in sections 6 and 4 has been seen red.
- **The gate.** The sub-minute gate runs in under 60 s with builds cached,
  measured, in section 7's order, and stops at the first red.
