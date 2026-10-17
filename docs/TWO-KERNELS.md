# Two kernels talking

metal-vmm runs two of zig-metal-unikernel's kernels against each other,
client and server, on one virtual timeline, deterministic byte for byte
(`PAIR=`). This is the reference for that mode (§4), for the deadlines the
client keeps (§5), and for the decisions behind both (§8). The code is the
authority: this doc cites symbols, and `git grep` finds them.

## 1. What it is for

Steve: "We want metal-vmm to be able to test two unikernels talking to each
other as client/server in an observable way, and we want the gates to be
fast! Like under a minute to exercise the 90% most likely parts of the
protocol."

The bars the work holds to:

1. **The client reads as a transcription of RFC 9293** §3.10 "Event
   Processing": it quotes the RFC, keeps its step numbering and order of
   checks, and names each place it departs (`DEPARTS:`).
2. **Linux is the witness**, for the pairings that have Linux on one side.
3. **No new "independent" model.** "If we write it, it's not independent."
   The server is judged by Linux and by our own client.
4. **Fail fast.** Every run ends on a verdict the client gives, by a
   deadline, never by the machine's patience.

## 2. The three pairings

| pairing | harness | deterministic | gated in |
|---|---|---|---|
| Linux client → metal TCP | zig-metal-unikernel `native/serve.zig` + `native/judge_native.py`: `tcp.zig` as a Linux program on the TAP `gmtap0` | no | its tier 1 (quick); the loss check in `long.sh` |
| metal client → Linux server | zig-metal-unikernel `native/fetch.zig` on `gmtap0`, against a Python HTTP server, judged by `judge_native.py`'s fetch cases | no | its tier 1 |
| metal ↔ metal | metal-vmm `PAIR=`: `gopher.elf` serving `probe/fetch.elf` (`pair.sh`), or the sleeper polling it (`sleeps.sh`) | yes | its tier 3 (`SKIP=pair`, `SKIP=sleeps`) |

The native pairings run in real time against Linux's real stack, on the box
only (they need the TAP). They cannot be replayed: a failure is re-run on its
seed, and a real one is reproduced in `tcp_sim` or metal ↔ metal before it is
fixed.

**metal ↔ metal** is the only pairing that exercises virtio, DHCP and ARP
between two kernels, and the only one that replays exactly.

**The QEMU judges are not the Linux witness.** `probe/judge_gopher.py` uses
`-netdev user` with `hostfwd`, so the guest's TCP peer there is slirp's
stack. Those judges judge the application.

## 3. The TCP client

The client is zig-metal-unikernel's, in the same table as the server, and
its sources are the reference: `src/tcp.zig` (`State`, `Conn`, `Table`, the
user calls; `Table.connect` opens actively), `src/tcp_segment.zig` (§3.1's
`Segment`), `src/tcp_arrives.zig` (§3.10.7 SEGMENT ARRIVES) and
`src/tcp_timeouts.zig` (§3.10.8, RFC 6298, RFC 5681).

- **Pure decisions return enums**, each with a table-driven test; `Table`
  acts on the enum.
- **RFC text is quoted** before the code that does it, and a step that does
  not apply says so.
- **A `DEPARTS:` line names each departure from the RFC**:
  `git grep -c 'DEPARTS' -- 'src/tcp*.zig'` counts them.
- A connection is `Role.accepted` or `.initiated`; `reserved_for_initiated`
  keeps a slot for this machine's own connects, so a SYN flood cannot starve
  them. A simultaneous open is dropped and counted
  (`simultaneous_opens_refused`), with no RST.
- `tcp_held.zig` holds a segment that arrives ahead of a hole, so a
  reordering wire does not stall two of our kernels.

## 4. metal ↔ metal: two processes taking turns

### The shape

`PAIR=<client kernel>` makes metal-vmm fork and exec itself (`pair.spawn`),
the two joined by a `SOCK_SEQPACKET` socketpair (`pair.socketPair`).

- **The parent is side 0**, the server. **The child is side 1**, the
  client, given `SIDE=1` and `PAIR_FD` by `pair.childEnvironment`.
- **Exactly one process runs its guest at a time**: the holder of the turn.
  Every decision is a function of the two virtual clocks, so the pair is
  deterministic by construction, with no jitter knob and no lint exception.
- Because only one process writes at a time, and each flushes stderr before
  it gives up the turn, the two stderr streams interleave in turn order.
- **The pure part is `src/turn.zig`; the socket is `src/pair.zig`**
  (`Link`, behind `turn.Hooks` for main.zig and `turn.Pair` for net.zig).
  Both hooks are null outside a pair, where nothing changes.
- A pair is never snapshotted: one side's snapshot is not the pair's
  (snapshot.zig's `borrowed`).

### Settings

- **`WIRE_LATENCY_US` must be set and over 0.** It is the lookahead L: no
  frame arrives sooner than L after it is sent. `turn.checkStart` refuses a
  pair without it (exit 2). `pair.sh` sets 1000.
- **Each process keeps its own environment.** The client's settings are the
  server's `PAIR_CLIENT_<NAME>`, as `<NAME>`. Only `pair.shared`
  (`WIRE_LATENCY_US`, `WIRE_TRACE`, `PAIR`, `GUEST_S`) go to both.
- **Receiver-side fault knobs are refused** on either side
  (`turn.receiver_side`): a frame from the other machine enters the Wire past
  them, so they would fault only the local peer's frames. Faults on what the
  guest sends (`WIRE_*`) are the sender's, and stay.
- `PAIR_OUT` (required) is the client's console, `PAIR_CMDLINE` its PVH
  command line, `PAIR_DISK` its boot disk. [KNOBS.md](../KNOBS.md) has each.

### Messages

`turn.Message`, encoded by `turn.encode`:

- **FRAME** (`turn.Frame`: `due`, `side`, `seq`, the bytes): written as the
  guest transmits it, `due` = the sender's clock + L, `seq` counting up per
  sender. An eaten frame (`WIRE_EAT`, `WIRE_LOSS`, `WIRE_SILENT_S`) is
  decided on the sender and never sent.
- **TURN** (`turn.Turn`: `clock`, `status`, and on the first TURN to the
  client, `start`). `turn.Status` is `off` (not yet powered on), `running`,
  `halted` with its wake (null: only a frame can wake it), or `stopped`.
- **An unexpected EOF** means the other process died, and the run fails
  (`pair.Error.OtherDied`). EOF is expected only after the other side's
  `stopped` or once the pair has ended (`turn.eofExpected`).

### The turn rule

The holder runs up to a **limit** (`turn.limit`), set by the other side's
status:

| other side | limit |
|---|---|
| `running` at clock c | c + L |
| `halted` with wake w | min(w, the due of the first frame the holder sent it this turn) + L |
| `off` or `stopped` | none |

**The holder gives up the turn** when a clock move would pass the limit:
before an exit's tick and before owed volume time (`Hooks.beforeMove`), and
at a halt whose wake is past the limit, after `turn.capHalt` moves the clock
to the limit. Giving up the turn is: flush stderr, send TURN, block reading
until the next TURN.

**The wake** (`turn.wake`) is the earliest of the local APIC's deadline, the
card's next due (its own peer's timers and its Wire) and the inbox's next due
(`Pair.nextDue`), keeping only dues after the clock. A frame already due and
undelivered waits for the guest, not the clock, so every wake is after the
clock or null.

**`turn_livelock`** (`turn.Livelock`): two handoffs in a row with neither
clock moving end the run as a failure.

### The end

A halt with nothing to wake it does not return from `serve()` as a single
machine's does, since a frame may yet wake it. `turn.atNever` decides:

- the other side is `running`, `off`, or `halted` with a wake: give up the
  turn as `halted` with no wake;
- the other side is `stopped`, or `halted` with no wake: the pair ends,
  named "both idle". That is a normal end, not a hang.

Each side prints one `pair side N:` line at its end, while it holds the
turn (`Link.line`): turns given up, frames sent and received, frames sent
before the client was on, frames discarded before power-on, broadcasts
dropped. **The server's exit code** is `pair.combined`: its own when that
is not 0, else the client's; a server that ends idle or watched gives the
client's.

### The inbox

Frames from the other machine wait in `turn.Inbox` (`turn.inbox_frames`
deep), in order of `(due, seq)`. `Pair.deliver` moves each one due onto this
side's `faults.Wire` through `Wire.holdRemote`, which adds no latency (the
due is stamped) and skips the receiver's fault picks. A full Wire leaves the
frame in the inbox; it never pushes out an older one.

**Head-of-line delay is accepted.** `Wire.ready` looks only at the oldest
frame, so a due remote frame can wait behind a local one with a later due.
That adds delay, keeps causality, and is deterministic. The local peer's own
frames (its DHCP replies, its timers) never enter the inbox.

### Power-on and START

The built-in peer's client (`Machine.consider`) does not connect in a pair.

1. The client process starts blocked, reading (`Link.awaitStart`).
2. The server runs alone: its limit is none, since the client is `off`.
3. When the server's guest prints "listening on port 80" at clock t,
   `consider` calls `Hooks.listening`: d = t + L, and the client counts as
   `running` at d from then on.
4. The server's next TURN carries `start` = d, and the client powers its
   guest on at clock d.

A frame the server sends while the client is off is not sent, and is
counted ("sent before the client was on"). A frame in the client's inbox due
before d is discarded and counted (`Inbox.powerOn`). Both are named rules,
not silent losses.

### Identity and forwarding

- **`SIDE`** picks the card's MAC and the DHCP lease (`frames.side`): side 0
  is QEMU's default, side 1 one past each. Anything but 0 or 1 is refused;
  a server given `SIDE=1` is refused, since `PAIR` sets it.
- **Each process's own peer** keeps DHCP and 10.0.2.2.
- **What crosses** is `frames.route`'s: every ARP frame goes to both, every
  unicast frame not addressed to 10.0.2.2 crosses, DHCP's broadcasts stay
  local, and any other broadcast is dropped and counted.
- **`fetch.elf`** takes its target, path and deadlines from its command
  line: `fetch 10.0.2.15 80 /big connect_ms=150 idle_ms=1000 total_ms=3000`.
  Its outcome is its exit code (zig-metal-unikernel `src/fetch.zig`'s `Outcome`).

### `WIRE_TRACE=1`

One line on stderr per crossing frame, as it is sent or eaten and as it is
delivered (`turn.traceLine`):

    wire <ns> side <s> seq <n> len <l> tcp <flags> <sport>><dport> seq <x> ack <y> data <d> <fate> sum <fnv1a32>

An eaten frame's seq is `-`: it never had one. The hash of every byte is what
lets a one-byte change show; turn.zig's test flips each byte of a segment in
turn and requires the line to change. Outside a pair, `WIRE_TRACE` is
refused.

**EINTR from `KVM_RUN`** is retried before the exit is counted, so a signal
never moves the virtual clock.

## 5. Deadlines

`tcp_timeouts.Deadlines` (`connect_ns`, `idle_ns`, `total_ns`) has no
defaults: each caller says what its run can wait.

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

In metal ↔ metal the deadlines are virtual and halts jump time, so a hung run
ends within 3 s of its own time; no run reaches `PATIENCE_S`.

## 6. How it was built

QUEUE 225, chunks 0a to 13, CC writing and the box verifying, finished
2026-10-16: `git log --grep='225'` in both repos, and FEEDBACK.md's entries for 225.
Chunk 0a first gave the server RFC 6298 §5.4's retransmission (one segment
after a timeout, not the whole window); chunk 6 runs the kernel client
against the kernel server in `tcp_pair_sim.zig`, about 300 seeds in
`zig build test`.

## 7. The gates

zig-metal-unikernel's tier 1 runs the native pairings quick, before its QEMU
probes; its tier 3 runs `pair.sh` and `sleeps.sh`, since they need gopher.elf
and the site volume, which only tier 3 builds. Each stops at its first red.
`pair.sh` is red with `-Dplant=client_ack_off_by_one`.

## 8. Decisions (Steve, 2026-10-16)

1. **Simultaneous open:** dropped and counted, no RST.
2. **The SYN's first RTO:** 25 ms, for our own connections only
   (`syn_first_rto_ns`); the server's 200 ms floor stays.
3. **The reserved slot:** exactly one, for `.initiated`.
4. **The pair's latency L:** 1 ms in `pair.sh`, with no default in
   metal-vmm.
