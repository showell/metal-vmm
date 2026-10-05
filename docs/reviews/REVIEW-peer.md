# Review: the peer, as a TCP

QUEUE.md item 25, by the cloud session, 2026-10-05. This reads
`src/peer.zig` (with items 7, 20 and 21 in it), against RFC 9293, RFC 6298,
RFC 5961 and RFC 5681. It reads the guest side from gopher-metal `02de06f`
(`tcp.zig`, `stream.zig`). Most of this file is the cloud session's own
code, so this is a review against its author.

The question is the one item 1 asked of the devices, turned around: where
does the peer differ from a real host in a way the guest can reach? And
for each such difference, which verdict does it make wrong? The peer is
half of every verdict. A peer that is wrong makes a run blame the guest for
the peer's mistake. gopher-metal's seed 23953 was exactly this: its model
client went silent where a real host sends a reset, and the table was
faulted for giving up on it.

Nothing is fixed here. Each finding is an item under "Proposed".

## What holds up

- **Sequence numbers are counted, not guessed.** SND.NXT, SND.UNA and
  RCV.NXT are kept as RFC 9293 §3.3.1 names them, and the SYN and FIN each
  take one. An acknowledgement past SND.NXT moves nothing (§3.10.7.4,
  tested).
- **A closed port answers as one.** After it resets the connection itself
  or gives up, a segment gets the reset §3.10.7.1 specifies: at SEG.ACK
  with ACK set, else acknowledging SEG.SEQ + SEG.LEN with RST|ACK. A reset
  is not answered.
- **A shut receive window is a shut window.** With RCV.WND = 0 nothing is
  taken, neither a byte nor a FIN (each takes sequence space). Probes are
  answered with the window still shut, and the reopening is said
  (§3.8.6.1).
- **Retransmission starts from SND.UNA** and covers only what has been
  released (item 20's keep-alive). The timer is stopped by the ACK that
  covers everything and restarted by any newer one (RFC 6298 §5.2-5.3).
- **Answers are framed as RFC 9112 §6.3 frames them** (Content-Length,
  chunks, to the close, none for 1xx, 204 and 304), so keep-alive waits on
  the right byte.
- **Checksums are right both ways**, IP and TCP, so nothing the peer sends
  is dropped as damaged unless `PEER_DAMAGE` asked for it.

## Findings

As in item 1: each has a severity (what the wrong verdict costs) and a
likelihood (how reachable it is today, with which knobs).

### High

**P1. A connection the peer has finished with goes silent.** After the
peer closes first (`fin_wait`, then `done`), it should be in TIME-WAIT
(RFC 9293 §3.10.7.4, "TIME-WAIT STATE"): a retransmitted FIN is
re-acknowledged and the 2MSL timer restarts. In `done` it answers nothing.
So if the peer's last ACK is lost, the guest repeats its FIN to a peer that
has stopped listening. gopher.zig then runs out its FIN retries, or its
`fin_wait_ns` (30 s), and "gives up" on a client that in fact had its whole
answer. This is seed 23953, from the other side. The same silence follows
`refused` (the guest reset it), which should be CLOSED, and any client port
not yet opened (`idle`). A real host answers a segment for a closed
connection with a reset.
- *Wrong verdict:* the guest's give-up and its `given_up` count, blamed on
  the guest; under `sweep.sh`, a FAIL.
- *Likelihood:* reachable with `PEER_ASKS>1` (the peer closes first) plus
  `PEER_EAT` on the peer's last ACK, or `PEER_LOSS`. Rare per run, but a
  sweep finds it.
- *Fix shape:* `done` after an active close is TIME-WAIT. It
  re-acknowledges a FIN, and answers anything else with an ACK (RFC 9293:
  an unacceptable segment gets an ACK) for 2MSL of guest time. A port in
  `done` after a passive close, in `refused`, or `idle` answers as a closed
  port (`closedPort`), as `reset` and `gave_up` already do.

**P2. The peer ignores the guest's receive window, and never probes it.**
The peer never reads the window field of the guest's segments (there is no
SND.WND), so it sends its whole request whatever room the guest has. gopher.zig
receives into a 16 KiB buffer per connection. A request larger than what is
free takes only what fits ("tcp: a peer sends past the window and only what
fits is taken"). The rest is gone. Without a loss knob the peer has no
timer, so it never sends it again. Even with one, it resends a segment
whatever the window, and never sends a window probe (RFC 9293 §3.8.6.1).
- *Wrong verdict:* the request never completes, gopher.zig lets the
  connection go after `idle_ns` (10 s), and the run says the guest did not
  serve the page.
- *Likelihood:* any `PEER_REQUEST` larger than the guest's free window (a
  chat upload, a long POST), or `PEER_ASKS` with pipelining. The probes'
  small GETs never reach it.
- *Fix shape:* keep SND.WND and SND.WL1/WL2 from the guest's segments
  (§3.10.7.4), send no further than SND.UNA + SND.WND, and when the window
  is zero with bytes waiting, probe on a persist timer that runs whatever
  the knobs. The property above stays reachable with a knob that makes the
  peer ignore the window on purpose (`PEER_OVERRUN`), as a rough peer does.

### Medium

**P3. The peer recovers far more slowly than a real client.** Its RTO is a
fixed 1 s at first, doubling to 60 s. It takes no RTT sample (RFC 6298
§2-3), so it never goes below 1 s, where Linux, measured, sits near its
200 ms floor on this path. It has no fast retransmit on three duplicate
ACKs (RFC 5681 §3.2). And each timeout sends one segment, so a burst of
lost segments costs one RTO each. With gopher.zig's `idle_ns` at 10 s, a
request that loses two of its segments in a row (1 s, then 2 s, then 4 s)
comes close to the guest's patience, and three in a row exceed it.
- *Wrong verdict:* the guest lets go of a client whose real counterpart
  would have finished. The page is missing under `PEER_LOSS` or
  `PEER_EAT`, and `sweep.sh`, which does not excuse those knobs, calls it a
  FAIL.
- *Likelihood:* `PEER_LOSS` at rates of one in 5-10, with `PEER_MSS`
  splitting the request. `FAULT_SEED` draws both.
- *Fix shape:* measure RTT on segments not retransmitted (Karn), compute
  RTO as RFC 6298 §2 says with a 200 ms floor (Linux's, which RFC 6298
  allows), resend on three duplicate ACKs, and keep a backed-off RTO until
  a fresh sample (§5.7). Today, after any new ACK, it resets to 1 s. It
  should go back to sending everything from SND.UNA on a timeout, within
  the window (P2).

**P4. The peer's SYN carries no MSS option.** gopher.zig then uses its
`default_mss`, 536 bytes (RFC 9293 §3.7.1), for every segment it sends
this client. curl through QEMU's slirp, and every browser on a droplet,
says 1460. Every answer here is therefore about 2.7 times as many segments
as in production.
- *Wrong verdict:* none directly; pages are byte-identical. But every
  frame-numbered map (lossy.sh's `WIRE_EAT=n`, `PEER_EAT=n`, a seed's
  frame lists) is a map of a segmentation production never sees. The
  window, segment-count and RTO paths are reached at different points than
  on a droplet.
- *Likelihood:* every run with a client.
- *Fix shape:* the SYN says MSS 1460 (`PEER_MSS` already limits the
  peer's own segments; this is the other direction). It changes every
  run's frames, so it is the box's to merge with its gate runs, and
  lossy.sh's maps are redrawn after it.

**P5. The peer believes any reset on its port.** RFC 5961 §3.2: a reset
must name RCV.NXT exactly. One inside the window draws a challenge ACK, and
anything else is ignored. The peer accepts any RST whatever its sequence
number and reports `refused`.
- *Wrong verdict:* a guest bug that resets with the wrong number is
  believed. The run says the guest refused the client, where a real Linux
  client would challenge it and carry on. That verdict is too kind to the
  guest, not too harsh.
- *Likelihood:* only a guest bug reaches it; gopher.zig numbers its resets
  as §3.10.7.1 says. It is still worth having, because the peer is meant to
  catch exactly such bugs.
- *Fix shape:* exact, challenge or ignore, as the guest's own table does,
  with a test per case.

### Low

**P6. An acknowledgement of something never sent still lets its segment's
data in.** RFC 9293 §3.10.7.4: if SEG.ACK > SND.NXT, send an ACK, drop the
segment and return. The peer moves nothing, which is right, but then takes
the data. A guest bug of that shape passes.

**P7. The SYN-ACK's acknowledgement number is not checked.** In SYN-SENT,
an ACK other than ISS + 1 is answered with a reset (§3.10.7.3). The peer
takes any SYN-ACK. This is reachable only by a guest bug.

**P8. Simultaneous close ends at once.** A FIN arriving in `fin_wait`
before the peer's own FIN is acknowledged should go to CLOSING, then
TIME-WAIT. The peer goes straight to `done`, which P1 makes silent. Fixed
with P1.

**P9. Segments out of order are dropped, not held.** This is legal (the
RFC does not require reassembly), and the guest's retransmission covers it.
It costs the guest extra retransmissions a real client would have spared it.
It also makes the guest's "three duplicate ACKs" path more common here than
in production. No verdict is wrong; the coverage is skewed.

**P10. Several clients (item 20).** Routing by port is right, and the rough
knobs are the first client's alone, as documented. A port past
`Plan.clients`, or not yet opened, is silent rather than closed (P1's fix
covers it). A second request on a keep-alive connection is sent only after
the first answer is whole, never pipelined, which is what browsers do. Fine.

### And one for item 23's sweep

**S1. A peer that gives up is counted against the guest.** `sweep.sh`
excuses a missing page only for `PEER_RESET_AT`, `PEER_VANISH_AFTER` and
`DISK_REFUSE`. Under `PEER_LOSS` or `PEER_EAT`, a peer that reaches
`gave_up` (eight sends of the same thing), or that P3 slowed past the
guest's `idle_ns`, misses the page through the peer's own fault, and the
sweep says FAIL.
- *Fix shape:* the run says the first client's final state on the error
  stream (stderr, so check.sh's stdout is untouched). The sweep excuses a
  missing page when that state is `gave_up` or `gone`, and names it. P3's
  fix removes most of the rest.

## Order

P1 first: it is the 23953 class, and small. Then P2, which makes large
requests possible at all. P3 and P5 can share one change to the client's
state machine. P4 waits for the box's gates. S1 is a few lines in the run's
report and in `sweep.sh`.
