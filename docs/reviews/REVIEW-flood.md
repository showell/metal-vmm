# Review: can tcp.zig tell a real client from a flood?

QUEUE.md item 24, by the cloud session, 2026-10-05. This reads gopher-metal
`src/tcp.zig` at `02de06f` (branch `antithesis-sdk`): `oldestHalfOpen`, the
`syn_received` path of `handle` and `transmitOne`, and `refuse`. It reads
them against RFC 4987 (TCP SYN flooding attacks and common mitigations), RFC
9293 and RFC 6298. Design only: nothing is fixed, and gopher-metal is the
box's and Steve's.

## The failure, as the simulator found it

14 rough seeds in 50,000. A real client's handshake ACK is lost. Its slot
on the table's side stays `syn_received`. A flood SYN then finds the table
full, and `oldestHalfOpen` gives way at the client's slot, which is older
than `min_rto_ns`. The client believes it is connected. Its next segment
(its request, or its ACK of a repeated SYN-ACK) meets no connection, and
`refuse` answers it with a reset.

## Why it happens: two clocks that are the same clock

- A half-open's SYN-ACK is sent again at `rto_at = opened_at + rto_ns`,
  which is `first_rto_ns` = `min_rto_ns` = 200 ms for a new connection
  (`handle`, `transmitOne`).
- `oldestHalfOpen` lets a half-open give way once
  `now - opened_at >= min_rto_ns`: also 200 ms.

So a client whose ACK was lost becomes evictable at the very instant its
only chance to recover begins. The repeated SYN-ACK is what makes it ACK
again. The table sends that at 200 ms, and its answer arrives a round trip
later, at 200 ms + RTT at the earliest. For that whole round trip, and
longer if the repeated SYN-ACK or its answer is lost too, the client's slot
is "a stuck half-open older than a round trip". To the table it is
indistinguishable from a flood's.

The rule's own comment states the intent: "a real client completes its
handshake in one round trip, far under `min_rto_ns`". That is true of a
client whose ACK arrives. It is false of one whose ACK was lost, and that
is the case the rule was never asked about. The burst that motivated item
82 had no loss.

**What it costs.** One request, reset, under a flood and a lost ACK at
once. A browser retries an idempotent request after a reset; Caddy, in
front of this box, may or may not. The table itself stays sound: every
slot is accounted for, and nothing leaks.

**How likely it is in production.** The README's own premise: this box
sits behind Caddy on a private network. Its real clients are Caddy's few
connections, from one address, over a path that rarely loses. A flood
would have to come from inside that network. So the failure needs two
unlikely things at once, and costs one retried request. It is a real
defect in the policy, but not an urgent one. The simulator found it
because it is built to put the two together.

## The options, against RFC 4987

RFC 4987 §3 lists the end-host defenses. Here is each one, at gopher.zig's
scale: 256 slots of 80 KiB each, about 20 MiB, one thread, a test-supplied
`isn`.

### 1. Recycling the oldest half-open (§3.4), today's policy, retuned

RFC 4987 notes that recycling fails exactly when the attack replaces the
table faster than a legitimate handshake completes. Here, "completes"
should mean "completes even after one lost ACK", and the threshold is set
to the case without loss.

- **The smallest fix.** Give way only at a half-open whose repeated SYN-ACK
  has also gone unanswered for a round trip. In code, that is
  `c.retries >= 1 and now - c.last_sent >= max(c.rto_ns, measured RTT)`,
  or in effect an age threshold of about `2 * first_rto_ns`. A client that
  lost one ACK answers the repeated SYN-ACK inside that window and keeps
  its slot.
- **What it costs.** A flood's half-opens live about 400 ms instead of
  200 ms. So 256 slots shed a flood at about 640 SYNs/s instead of 1,280
  before real SYNs start being refused. A refused real SYN is retried by
  the client's SYN timer (1 s on Linux), so the cost is latency under a
  heavy flood, not a reset.
- **What it does not fix.** Two losses in a row (the ACK and the re-ACK),
  or a repeated SYN-ACK lost on the way out. The window moves; it is not
  closed.
- **Random choice among the stuck ones** (also in RFC 4987, as "random
  drop") would lower the chance from "certain, if it is the oldest" to
  about 1 in the number of stuck slots per flood SYN. Over a long flood
  that still adds up, and it costs a random draw and the determinism of
  which slot goes. It is worse than the fix above, and no better in
  combination.

### 2. A SYN cache (§3.5)

Half-opens live in a small table of their own: an address, two ports, two
sequence numbers, the MSS and the window, about 24 bytes each. A real
80 KiB slot is taken only when the handshake's final ACK arrives. This is
FreeBSD's syncache.

- **What it buys.** A thousand half-opens cost 24 KiB instead of a thousand
  slots, so a flood no longer competes with established connections for
  slots at all. A real client's half-open is pushed out only after as many
  newer SYNs as the cache has entries.
- **What it costs.** A second table, promotion on the final ACK,
  retransmission of SYN-ACKs from cache entries, and the "a stuck
  half-open gives way" property re-homed to the cache. That is the largest
  change of the four. And the cache can still be flooded faster than a
  handshake recovers from a loss, so it shares option 1's window, only
  scaled up by its size.

### 3. SYN cookies (§3.6)

No state for a half-open at all. The SYN-ACK's ISN encodes a keyed hash of
the 4-tuple and a coarse time, plus the MSS in a few bits. A final ACK, or
a data segment, whose ACK number is a valid cookie plus one creates the
connection.

- **What it buys.** Immunity to slot exhaustion by SYNs. A client survives
  any number of lost ACKs while its cookie's time bucket is still accepted
  (Linux: about 2 minutes).
- **What it costs here:**
  - a keyed hash (SipHash is in std) and a secret from the entropy pool;
  - the MSS packed into 3 bits;
  - no SYN-ACK retransmission for a cookie connection, the usual price;
  - the `isn` hook that `tcp_test.zig` and `tcp_sim.zig` drive would no
    longer choose the ISN outright, so every test that fixes an ISN
    changes;
  - and the table still needs a free slot to put the new connection in.

  Linux uses cookies only when the queue is full, and the same hybrid
  would apply here. It is the strongest defense, and more than 256 slots
  behind Caddy need.

### 4. Revive a given-way half-open by its client's ACK (the question)

> Can a segment that meets no connection, but carries an ACK matching a
> given-way slot's ISS+1, revive it?

**Yes, and it is the cheapest fix that closes the window rather than
moving it.** When `oldestHalfOpen` gives way at a slot, it first copies
what a completed handshake needs into a small ring of the recently given
way:

- the peer's address, port and MAC;
- the ISS (`c.una` before the SYN-ACK is acknowledged);
- the IRS + 1 (`c.rcv_nxt`);
- the MSS and window from the SYN.

That is about 24 bytes an entry. In `handle`, before the "anything else
for no connection is refused" branch, a segment from that (address, port)
with ACK set is checked against the ring. If `ack == ISS + 1` and
`seq == IRS + 1`, it is exactly the segment `syn_received` would have
accepted (`number == c.una +% 1`). So the connection is rebuilt in a slot
and the segment handled as if nothing had happened. Its data, the request,
is taken.

- **Safety.** It accepts exactly what the given-way slot would have
  accepted, no more. A blind attacker must guess a 32-bit ISS either way.
  A reset or a SYN never revives. A revived entry leaves the ring.
- **Where it goes.** A free slot, else another stuck half-open, which by
  then is almost certainly a flood's. An ACK proves its sender is real; a
  half-open proves nothing. With neither, drop the segment *silently*
  rather than reset it: the client retransmits, and may find room next
  time.
- **How large.** The ring must outlast the evictions that happen while a
  client recovers. Under a 1024-SYN flood at 1 ms apart, about 770
  half-opens give way in about 0.8 s. The client's recovery (repeated
  SYN-ACK at 200 ms, answered a round trip later) is about 200-250 ms of
  that: under 256 evictions at that rate. So 256 entries (6 KiB) covers
  this flood with room to spare, and 1024 (24 KiB) covers four times the
  rate. Both are small against the table's 20 MiB.
- **What it does not fix.** A client recovers only while its entry is
  still in the ring. A flood faster than the ring's size per recovery time
  pushes it out first. That is the same shape as option 1, but the window
  is now set by memory (entries) rather than by time (one round trip).
- **What it costs in code.** About 40 lines: the ring, the copy in
  `oldestHalfOpen`, and the check in `handle`. Plus one property ("tcp: a
  given-way half-open is revived by its client's ACK"), and a `tcp_test.zig`
  case modeled on the 14 seeds.

## Recommendation

1. **Revive (option 4)**, which removes the failure the simulator found for
   any flood the ring outlasts. It changes no ISN, no test's fixed numbers,
   and no behavior without a flood: the ring is written only when a
   half-open gives way. The simulator's 14 seeds, rerun, are its
   regression test.
2. **Optionally, with it, option 1's threshold** (give way only after the
   repeated SYN-ACK has gone a round trip unanswered). It makes revival the
   rare path rather than the common one, at the cost of halving the rate a
   full table sheds a flood. It is worth having only if the ring alone
   proves too small in the long tier.
3. **Not cookies or a SYN cache, at this size and behind Caddy.** They
   defend against a flood large enough to exhaust state. This table's
   problem is a policy that cannot tell recovery from abandonment, and
   option 4 answers that directly.

## For metal-vmm's side

Item 21's flood (`PEER_FLOOD=1024`, `PEER_FLOOD_AT_US`) can now produce
this race on the real kernel: lose the client's handshake ACK, and start the
flood inside the next 200 ms + RTT. The peer numbers its frames from its
first, a DHCP reply included. A run that takes a lease sends the OFFER (1)
and ACK (2), then the client's SYN (3) and its handshake ACK (4). So
`PEER_EAT=4 PEER_FLOOD=1024 PEER_FLOOD_AT_US=1000 PEER_FLOOD_GAP_US=100`
should reset the client today. The box should confirm the numbering on a
clean run first, as `lossy.sh` counts the guest's frames. Once a fix
lands, that run is its test on the real kernel.
