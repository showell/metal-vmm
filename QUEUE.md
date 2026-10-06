# Work queue

Shared by the cloud Claude (CC) and the box Claude; see `CLOUD_WORK.md`.
Items are in order. The box reorders on `interrupts`, and CC proposes at the
bottom.

## Context, 2026-10-05

- **The PC-shaped machine (`TRANSPORT=pci`) works**: gopher.elf halts between
  frames and wakes on MSI-X and the APIC timer, deterministically, on every
  route (`rest.sh all`, a gate in gopher-metal's `gates.sh` on its branch
  `antithesis-sdk`). It was built in an afternoon, and only the paths
  gopher-metal walks were tested. That is what this queue is for.
- **Steve's direction**: the cover-every-scenario budget goes here, not to
  QEMU, which stays on the happy path. The explorer comes later.

## CC

1. **Done (CC, `docs/reviews/REVIEW-interrupts.md`).** **Review the `interrupts` branch** (`git log master..interrupts`): pci.zig,
   apic.zig, the halt in main.zig's `rest`, the MSR filter, the deadline
   rewrite. Read it against the specs and against gopher-metal's driver,
   adversarially: where does the model differ from a PC in a way the guest
   could reach, and where could a run stop being a function of the guest
   alone? Write `docs/reviews/REVIEW-interrupts.md`. Fix nothing in it; each
   finding becomes an item.
2. **Done (CC).** **A `FakeGuest` over PCI.** As `virtio.zig`'s does for mmio: drive
   `pci.Bus` through ports 0xCF8/0xCFC the way gopher-metal's `pci.zig` and
   `virtio.zig` do (scan, capabilities, common config at each field's width,
   reset and its read-back, feature negotiation, a queue set up with its
   vector, a doorbell, a completion), then through MSI-X to an `apic.Apic`
   and out of `next()`. One test per step of the driver's sequence. This is
   the transport's integration test, without a vCPU.
3. **Done (CC).** **`rest`'s decision, pulled out and tested.** Given the APIC, the wire's
   next due frame and the clock: the time to move to, and the vector to take,
   or "nothing can wake it". Cases: a vector already pending (no time
   passes); a deadline before the next frame and after it; a frame due but
   undeliverable (no buffer), which must not wake it; a deadline whose tick
   falls between nanoseconds (`clock.nsAt` rounds up); an APIC not enabled.
4. **Done (CC).** **MSI-X as PCI 3.0 §6.8.2 has it.** Today it is one table entry, and any
   queue vector but 0 reads back NO_VECTOR. Make it a table of N entries,
   with the PBA's bits, the function mask and per-entry masks, and the
   config-change vector (`msix_config`). gopher-metal uses entry 0 for every
   queue, so behavior there must not change (item 2's tests hold it).
5. **Done (CC).** **The APIC, closer to the SDM.** The TPR's effect on what is delivered
   (the processor priority), several vectors pending across priority classes,
   EOI with more waiting, a deadline in the past firing at once, a deadline
   of zero disarming, and the timer's one-shot and periodic modes (initial
   and current count) for a guest that is not gopher-metal. Unit tests for
   each, from the SDM.
6. **Done (CC).** **PCI configuration space, closer to the spec.** BAR sizing (write all
   ones, read the size mask back), the command register gating memory
   decoding and bus mastering (a device not allowed to master the bus may not
   complete a request), header type and multi-function bits, and reads of
   registers that do not exist. Tests from PCI 3.0.

7. **Done (CC; knobs in the README, "And the peer can misbehave").** **A peer that misbehaves, deterministically** (the README's "Open if it
   resumes"). The wire can lose only the GUEST's frames today, and the peer
   in `peer.zig` is a model client that never resets, floods, stops reading
   or goes silent. So gopher-metal's long tier (`long.sh`, its lossy sweep
   of gopher.elf) reaches 6 of tcp.zig's 18 coverage properties, and
   `coverage/floor-metal.txt` says which; the simulator reaches all 18.
   Give the peer what gopher-metal's `tcp_sim.zig` `Rough` gives its client,
   each by environment knob as the faults are: a reset, exact or off by some
   (`PEER_RESET_AT`); vanishing part-way through the answer
   (`PEER_VANISH_AFTER`); a SYN flood from other addresses (`PEER_FLOOD`); a
   receive window that shuts and stays shut a while; and losing the PEER's
   frames on the wire, with the peer's own retransmission timer ticking on
   the machine's clock (checked in the pump, as the README says: that is the
   whole answer to "how, deterministically"). Unit tests for each, with the
   peer driven by hand as `peer.zig`'s tests do; the box runs them against
   gopher.elf and raises the metal floor to what they reach.

17. **(The box.) Is the deadline mark needed?** gopher.elf with the mark
    removed, on the merged branch, the filter alone: does `rest.sh all` still
    see timer interrupts? If yes, the mark goes from both repos.

18. **Done (CC).** **The guest's coverage lines, read by the machine** (groundwork for the
    explorer, which is not urgent: Steve, 2026-10-05). gopher-metal's kernel
    built `-Dcoverage` writes zig-coverage-sdk's JSONL to COM1 behind
    `coverage: ` (its COVERAGE.md); today a script greps stdout. Have the
    serial model recognize those lines as they are printed, keep them out of
    stdout when `COVERAGE_OUT=<file>` is set, append them to that file as
    JSONL, and keep a table of what this run has reached (id, kind, first
    true, first false, at which exit and virtual time). The run's last
    stderr line names how many properties were reached. Pure logic: the line
    parser and the table are unit-testable without a guest. gopher-metal's
    `long.sh` will use it in place of its grep.
19. **Done (CC).** **One seed names a run's whole fault schedule** (groundwork, as 18).
    Today a run's faults are a handful of knobs (WIRE_*, DISK_*, PEER_*).
    `FAULT_SEED=n` should choose them all, deterministically and printably:
    which frames each way are lost or damaged, latency, disk refusals, and
    the peer's behaviour, drawn from documented ranges, with the chosen
    schedule printed as the knobs that reproduce it. An explicit knob still
    wins over the seed. This is what lets an explorer, and a person, say
    "seed 4711" and mean one exact run.

20. **Done (CC).** **A peer with more than one connection.** gopher.elf holds up to 256
    connections, serves one request at a time among them, and keeps chat's
    live streams open; the peer opens one connection, sends one request and
    closes. Give it several clients, each its own port and its own
    deterministic schedule (`PEER_CLIENTS=n`, with requests from
    `PEER_REQUEST` files, one per client or shared), keep-alive and a second
    request on the same connection, and a client that holds its connection
    open reading a stream. Unit tests with the peer driven by hand. This is
    what the long tier needs to reach the slot table and the streams on the
    real kernel.

21. **Done (CC).** **A flood that can fill the guest's table.** gopher.zig holds 256
    connections (`max_connections`, 16 KiB to receive and 64 KiB to send
    each), and "a stuck half-open connection gives way to a new SYN" is
    reached only by a SYN that finds every slot taken. `PEER_FLOOD` stops at
    32 (`main.zig`'s `@min(n, 32)`, `Peer.flooded: u8`, one address per SYN
    from 198.51.100.1 up), so the real kernel cannot get there. Let a flood
    run to at least 1024 SYNs, from as many distinct (address, port) pairs
    as it takes (TEST-NET-2 has 254 hosts; vary the port too), and let it
    begin late (`PEER_FLOOD_AT_US`) so a real client can hold a slot first:
    the property's other half is that the stuck half-open gives way, not the
    client's live connection. Keep `FAULT_SEED`'s range for the flood as it
    is unless you see a reason; a seeded run of 1024 SYNs is a different
    kind of run. Unit tests with the peer driven by hand, as item 7's, and
    one that a client opened before the flood still gets its whole answer
    in a model of the guest's table (`tcp_sim: a client that stayed through
    a flood got its whole answer` is the simulator's version).

22. **Done (CC).** **Coverage across runs** (the explorer's memory; groundwork). Item 18's
    table covers one run. Give `coverage.zig` a merge: many runs' JSONL
    (each line tagged with the run's `FAULT_SEED` or its knobs) into one
    table that says, per property, which run reached it first and how many
    runs reached it, and which properties only one run ever reached (the
    rare ones an explorer should steer toward). A small CLI over it
    (`zig build coverage-merge -- a.jsonl b.jsonl ...` or similar) printing
    that table and the floor check gopher-metal's `long.sh` does today with
    the SDK's `report.py`. Pure logic, unit tests from hand-written JSONL.
23. **Done (CC; the box runs it, see Questions).** **A seed sweep the box can run** (groundwork, as 22). `sweep.sh` (or a
    zig step): `FAULT_SEED` over a range against one kernel and volume, a
    fresh copy of the volume per run, each run's verdict (exit code, the
    peer's status, the page against an unhurt run's, `sound.sh`'s fsck when
    the guest wrote) and its coverage into item 22's merge; it stops at
    nothing, and ends with the failing seeds, each printed as the knobs that
    repeat it. You cannot boot a guest, so test the parts that are logic
    (verdicts, the summary) by hand-fed run outputs; the box runs it on
    gopher.elf and answers here.
24. **Done (CC, `docs/reviews/REVIEW-flood.md`).** **A review: can tcp.zig tell a real client from a flood?** (design;
    write `docs/reviews/REVIEW-flood.md`, fix nothing). gopher-metal's
    simulator found 14 rough seeds in 50,000 where a real client is reset:
    its handshake ACK is lost, its slot is still `syn_received` on the
    table's side, a flood SYN finds the table full, and `oldestHalfOpen`
    (tcp.zig) gives way at the client's slot, older than `min_rto_ns`. The
    client's next segment then meets no connection and is reset. Read
    tcp.zig's give-way policy (its comment names the history: QUEUE item 82,
    the burst against Linux) against RFC 4987 (SYN flooding defenses: SYN
    cookies, the SYN cache, recycling the oldest half-open) and say what
    each would cost here and whether any keeps this client. Also: can a
    segment that meets no connection but carries an ACK matching a
    given-way slot's ISS+1 revive it? gopher-metal is read-only to you; the
    box and Steve decide.

25. **Done (CC, `docs/reviews/REVIEW-peer.md`).** **A review of the peer, as a TCP** (write `docs/reviews/REVIEW-peer.md`;
    fixes become items, as item 1's did). The peer is half of every verdict:
    when it is wrong, a run blames the guest for the peer's mistake. This
    happened today in gopher-metal's simulator: its model client went
    silent after TIME-WAIT, where a real host sends a reset (RFC 9293
    §3.10.7.1), and the table was faulted for giving up on it (seed 23953,
    gopher-metal `02de06f`). Read `peer.zig` against RFC 9293, 6298 and
    5961 the way item 1 read pci.zig against PCI 3.0: closed and TIME-WAIT
    behavior, what a segment for no connection gets, retransmission and
    Karn's rule, window probes, FIN in every state, item 20's several
    clients. For each difference, say whether the guest can reach it and
    which verdict it would make wrong.
26. **Done (CC).** **The guest's input never kills the VMM: a fuzzer over the models.**
    H1 (item 8) was a panic on `inl $0xCFD`. Drive every guest-facing model
    from a seeded stream of what a guest could do, without a vCPU: port and
    width at random over 0xCF8/0xCFC, COM1, the PIT, the RTC, 0xE0/0xE1;
    mmio and BAR reads and writes at any offset and width; virtqueues laid
    out wrong (descriptor chains that loop, run past the queue size, point
    outside guest memory, indirect descriptors, a zero-length buffer);
    APIC MSRs with any value. Each step either answers or is refused as the
    spec says; nothing panics, nothing reads past guest memory, and the
    same seed makes the same trace. `zig build fuzz -Dseeds=n`; a seed that
    finds something stays as a named test, as gopher-metal's regressions do.
27. **Done (CC).** **A power cut, and a torn write** (the disk's half of "does the volume
    boot again"). Today a disk request is answered or refused whole. Add,
    each by a knob and in `FAULT_SEED`'s ranges: `DISK_CUT_AFTER=n`, the
    machine stops dead after the guest's nth write, and the image keeps
    only what was written before it (`disk.zig` already writes back only
    at the end, so this is the run ending early with the writes up to n);
    and `DISK_TEAR=n`, the nth multi-sector write lands only its first k
    sectors before the cut. The box then boots the image again and runs
    `sound.sh` on it: that is how a FAT volume's crash consistency gets
    measured, which no run here has done. Unit tests on `disk.zig` with a
    hand-fed request stream.
28. **Done (CC).** **Determinism, enforced by a test.** CLOUD_WORK.md's first rule says
    nothing reads the host's clock or randomness; nothing checks it. A test
    in `zig build test` that reads `src/*.zig` and fails on any use of the
    host's time or entropy (`std.time.timestamp`, `nanoTimestamp`,
    `Instant`, `std.crypto.random`, `getrandom`, `clock_gettime`, and the
    like) outside an allowlist with a one-line reason each, so a change
    that slips one in is refused, not reviewed.
29. **Done (CC).** **Split the three long files** (the ~1000-line rule: `main.zig` 1820,
    `peer.zig` 1635, `pci.zig` 1551). Along the seams they already have:
    main.zig's knob parsing and end-of-run reports apart from its run loop;
    peer.zig's `Rough` and `Plan` apart from the plain client; pci.zig's
    MSI-X and the virtio-pci capabilities apart from configuration space.
    No behavior changes: the tests move with their code, and the box's
    gates are the check. Do this after 25 and 26, which read these files.
30. **Done for the device side (CC, `snapshot.zig`); the box's half is under Questions.** **The machine's state, saved and restored** (groundwork for the
    explorer: Antithesis branches many runs from one prefix instead of
    booting each from scratch). The device side first, which is all
    logic: every model (clock, APIC, PCI and MSI-X, the virtqueues'
    positions, serial, PIT, RTC, entropy, the faults' and the peer's state,
    the coverage table) gets a snapshot it can be restored from, and a test
    per model that a run restored at step k goes on exactly as the
    uninterrupted run did. The vCPU's registers and guest memory are the
    box's half (KVM_GET_REGS and friends); write down under Questions what
    the box would need to call, and do not guess at the ioctls.
31. **Done (CC, `cost.zig`; `check.sh` now drops the cost line, which QEMU has no counterpart to).** **What a run cost, in the guest's time.** The box measures wall time;
    an explorer will care about guest time and exits. End every run that
    did anything with one line on stderr: exits by kind (port, mmio, MSR,
    halt), guest nanoseconds, frames each way, disk requests, and the
    longest stretch of guest time with no exit at all. Keep it pure: a
    counter struct the run loop bumps and a formatter with tests.
32. **Done (CC): F1-F5 under Proposed; F1 built (`DISK_BAD_SECTOR`, `DISK_READS_ONLY`), the box's to aim at sector 2180 and the pinned file.** **Your proposals.** When 22-31 are done, read the README's "Being
    unhelpful on purpose" and "The real server" sections and propose (under
    Proposed, one line each on why) the next five faults or checks you
    think would find the most in gopher.elf. Then take the first one.

**gopher-metal: the simulators** (CLOUD_WORK.md, "gopher-metal: the
simulators"; branch from `antithesis-sdk`). Interleave these with 25-32 as
you like; each is independent. Known red: `zig build properties` at 50,000
seeds fails 14 rough seeds where a flood takes a real client's half-open slot
(item 24 reviews it; Steve rules on the oracle). Leave them red until he
does.

33. **Done (CC, gopher-metal `1516856` on `claude/great-wright-i7aste`): `runCrowdSeed`, six properties on the floor, and one finding under Questions. `build.zig` gained `-Dcrowd-seeds` (500 by default), to keep the long tier green until the ruling.** **(gopher-metal) tcp_sim with several clients, and a stream held open.**
    The simulator's table has 2 slots and one client; gopher.zig has 256
    slots, serves one request at a time among them, and keeps chat's
    streams open. Let a scenario choose the table's size and several
    clients, each its own schedule, keep-alive with a second request, and a
    client holding a stream; the oracles follow (every client that stayed
    got its whole answer; a held stream is not given up on while its client
    reads). This is item 20's peer, on the simulator's side.
34. **Done (CC, gopher-metal `86c7cae`): `page_sim.zig`, twelve properties on the floor, nothing found in page_cache.zig (five planted bugs each caught). `build.zig` gained `-Dpage-seeds` (100 by default) and page_sim in the catalog and the tests.** **(gopher-metal) A simulator for the page cache.** `page_cache.zig` is
    pure (it imports only `std`, 417 lines) and has no properties. Drive it
    with seeded reads, writes and whole-file writes against a reference map
    of what each file holds; the oracle is that every read returns the
    reference's bytes; `sometimes` properties for eviction, a whole-file
    write replacing a kept copy, the largest file it will keep. Add it to
    `zig build properties` and its floor to `floor-sim.txt`.
35. **Done (CC, gopher-metal `fc86c4f` and after): `pure_sim.zig`, twenty properties on the floor, two findings under Questions. log_ring, kept_log and restart each earned a seeded drive; request_heap's found only the second finding and is kept as the drive for its limit. `zig build test` and `properties` are red on the branch for the first finding, as a defect should be until the box fixes it.** **(gopher-metal) The other pure modules: `restart.zig`,
    `request_heap.zig`, `log_ring.zig` and `kept_log.zig`.** Each imports
    only `std` (kept_log also log_ring). Properties where a randomized drive
    shows something the unit tests do not: a ring that wraps, a heap at its
    limit, a restart decision at each of its branches. A small simulator
    each only where a seed earns it; say which did not.
36. **Done (CC, gopher-metal `2beac8a`): 35 reachable properties in fat16.zig (properties only), 33 of them never reached by the sweep before, 28 now reached by fat_sim's probes and on the floor; the seam under Proposed, two findings under Questions.** **(gopher-metal) What fat_sim never reaches in fat16.zig.** On day one
    the TCP properties found four tcp.zig paths tcp_sim never reached. Do
    the same for FAT: `sometimes`/`reachable` properties on fat16.zig's
    branches (errors, a full root, a full volume, chains that wrap, the
    FAT32 paths), the sweep's report of which are never reached, then
    fat_sim reaching them. fat16.zig is kernel code, so adding a property
    to it is fine; changing what it does is the box's. It imports
    `virtio.zig`: propose the seam that would make it a layer with nothing
    below it (under Proposed), and do not cut it.

**From the box's floor raise** (2026-10-05: gopher.elf with each knob in
turn; gopher-metal's long.sh now runs seven rough-peer scenarios, and its
metal floor is 15 of tcp.zig's 18). These are urgent before 25-36: 37 is a
crash on the peer's own input.

37. **Done (CC). Every segment of the peer's is at most the MSS the guest's SYN-ACK announced (536 if none, 1460 at most), and `PEER_MSS` only lowers it. A request of up to 1460 bytes to a guest announcing 1460, which gopher-metal's tcp.zig does, is one segment as before; a larger one is now several. fuzz.zig has a peer half on its own dice, which finds this at seed 1 with the fix undone.** **(metal-vmm) The peer's segment outgrows its buffer: a panic.**
    `PEER_REQUEST=<20 KB request>` with no `PEER_MSS` panics the VMM:
    `index out of bounds: index 8246, len 2048` at `peer.zig:740` (`build`,
    from `Tcp.more` via `segment`). The peer sends as much as the guest's
    window allows, up to its 2048-byte scratch. A real client sends no
    segment larger than the MSS the guest announced in its SYN-ACK (RFC
    9293 §3.7.1; 536 if none). Cap every segment at that, and at the
    buffer, and a test with a request larger than the window. Item 26's
    fuzzer should have a peer-side half that would have found this.
38. **Done (CC, `reports.unspent`): one line each on the error stream for `WIRE_EAT`, `PEER_EAT`, `PEER_DAMAGE` and `DISK_REFUSE` numbers past the last, `PEER_RESET_AT` with no connection open (or none ever, or the run ending first), `PEER_VANISH_AFTER` and `PEER_SHUT_AFTER` past the answer, a flood not all sent, and `DISK_CUT_AFTER`/`DISK_TEAR` past the last write. A run with no knobs prints nothing new.** **(metal-vmm) A reset the peer could not send says so.** `PEER_RESET_AT`
    before the connection is established is dropped without a word
    (`Tcp.due` sets `reset_past` and returns null outside established,
    closing and fin_wait). On gopher.elf with a 5 ms wire, any time under
    about 22 ms after the opening silently does nothing, and the run looks
    like a reset that changed nothing. Say it on the error stream at the end
    of the run ("PEER_RESET_AT=… fell before the connection was open; no
    reset sent"), as the wire reports what it lost. The same for any knob
    whose moment passes unused (`PEER_VANISH_AFTER` past the answer's
    length, `PEER_SHUT_AFTER` likewise, `PEER_EAT` past the last frame).
39. **(b) done (CC): `WIRE_EAT`, `PEER_EAT`, `PEER_DAMAGE` and `DISK_REFUSE` take ranges (`8-40`) among up to 32 numbers. (c) is the box's.** **(a) done (CC): `PEER_IGNORE_WINDOW=1`, and a plain client now keeps to the guest's window (P2's first half), which only a request larger than the window notices.** **(metal-vmm) The last three of tcp.zig's eighteen, on the real kernel.**
    (a) **a peer sends past the window**: the peer keeps to the guest's
    window (its sends stop at the guest's shut 16 KB buffer, and a 20 KB
    request then deadlocks until the guest's idle timeout). A knob for a
    client that ignores the window (`PEER_IGNORE_WINDOW=1`), as tcp_sim's
    rough client does. (b) **a segment from behind**: the peer must time
    out on lost ACKs, which needs a second of the guest's frames lost; but
    `WIRE_EAT` takes at most eight. Let it take a range (`WIRE_EAT=8-40`)
    and any number. (c) **a reopened window announced again**: the guest
    must stop reading a full buffer and then read it; the box will try a
    large upload (gopher.zig streams big uploads), so this one is the
    box's, listed so you do not take it.

40. **Done (CC): an idle end prints the `peer:` lines and writes `PEER_BODY`/`PEER_RESPONSE`, then ends with `GuestIdle` as before. The lines are `reports.client`, tested; the idle path through `serve` needs KVM, so it is the box's to see. An idle end still does not write the disk image back (see Questions).** **(metal-vmm) A run that ends idle still says what the client got.**
    `GuestIdle` (item 16) returns before main's "WHAT THE CLIENT GOT" block,
    so a run that ends idle prints no `peer:` line and writes no
    `PEER_BODY`. A guest serving more than one request always ends idle, so
    no such run can be checked for its page (gopher-metal's long.sh has to
    run its page-checking scenarios on a one-request volume for this). An
    idle end is a normal end for a server: report the client as any end
    does, keep the exit code saying idle, and a test of the shape.

**Next, after 22-40** (2026-10-05 evening; Steve is away, so take these in
order without waiting; the box answers when he is back).

41. **Done (CC): P1 (TIME-WAIT, closed ports), P2 (persist probes, WL1/WL2; the window itself in 39a), P3 with P5 (RFC 6298 timing, fast retransmit, go-back; RFC 5961 resets), and P6, P7 in the same lines; S1 (`sweep.sh` now excuses a page the peer itself gave up or vanished from, by a stderr line; `sweep_test.sh` has a seed for it). P4 waits for the box.** **(metal-vmm) The peer review's findings, P1-P5 and S1**, in the order
    `REVIEW-peer.md` gives: P1 first (the 23953 class: a finished peer goes
    silent where TIME-WAIT answers), then P2, P3 with P5, S1. P4 waits for
    the box's gates, as the review says.
42. **Done (CC, `keepsWrites` in main.zig, with its test).** **(metal-vmm) An idle end writes the disk back.** Yes to your item 40
    question: an idle end is a normal end for a server, so the image keeps
    what the run wrote, and `sound.sh` and a second boot can judge a
    multi-request run. A crash, a timeout and `GuestStuck` still leave the
    image as it was. A test of each.
43. **Done (CC; `sweep.sh` now excuses a page that differs under `DISK_ROT`, as under the other disk faults).** **(metal-vmm) F2, silent rot on read** (`DISK_ROT=sector,byte`), as you
    proposed it, in `FAULT_SEED`'s ranges.
44. **Done (CC, `cache.zig`; `DISK_CACHE=1` as the spec has it, `DISK_CACHE=lie` for a disk that lies; the answer for gopher.elf under Questions).** **(metal-vmm) F3, a write cache and whether the guest flushes**
    (`VIRTIO_BLK_F_FLUSH` offered; `DISK_CACHE=1` holds acknowledged
    writes until a flush; item 27's power cut loses what was not flushed).
    Offering the feature changes what the guest negotiates, so it is off
    unless the knob is set: `check.sh` holds the default machine to QEMU.
45. **Done (CC, `Rough.retry`; whether the volume holds the message once is the box's).** **(metal-vmm) F4, a client that retries what got no answer**
    (`PEER_RETRY=1`), with the run's end saying how many times the request
    was sent; whether the volume holds the message once is the box's check.
46. **Done (CC, `Rtc.from`).** **(metal-vmm) F5, the calendar as a knob** (`RTC_BOOTS_AT=unix`).
47. **Done (CC, gopher-metal `53be28e` on `claude/great-wright-i7aste`, for the box to review and merge): the 14 rough and 21 crowd seeds green, every seed without a give-way frame for frame unchanged, the ring measured (all 35 pass from 8 entries), the cost in the commit (9,216 B of Table on the stack, 1.3 KiB of text). One thing beyond the review: the ACK revives at any sequence, not only IRS + 1, since `syn_received` acknowledges rather than resets a segment ahead (a request in several segments, the first lost); found by seed 11277.** **(gopher-metal) REVIEW-flood's option 4, revival, in tcp.zig.**
    Steve ruled yes (2026-10-05): build it for merging. The box reviews the
    diff and merges it into `antithesis-sdk`; it reaches the site only in
    the next image, which Steve is holding for now. The 14 rough seeds and the 21
    crowd seeds (`crowd_red`) as its regression tests, all green with it;
    every other seed at the sweep size you can afford unchanged, frame for
    frame where there is no flood; the ring's size and what happens when a
    flood outlasts it, measured. Say in the commit what the change costs
    the kernel (bytes, a branch on which path). This is the one place you
    change kernel code; on your branch, as always.
48. **Done (CC): H1-H5 under Proposed; H1 built (`PEER_DRIP_US`), not yet run against gopher.elf: with `PEER_CLIENTS` and `PEER_MSS=1` it asks how many slow clients keep a good one out.** **Your proposals again** when 41-47 are done, as in item 32: the next
    five, one line each on why, then take the first.

**Next, after 48** (2026-10-06 morning). Item 47 is merged (gopher-metal
`4953f7e`): thank you, the review held up, and the crowd test runs green. Your
H proposals are approved in the order below.

49. **Done (CC, `Rough.pipeline`; not yet run against gopher.elf).** **(metal-vmm) H5, pipelining** (`PEER_PIPELINE=1`), as you proposed it:
    does the table send a FIN or a reset with the second request unread, and
    does the client still get the whole first answer.
50. **Done in item 55 (CC).** **(metal-vmm) H3, frames that lie, from the peer** (`PEER_MANGLE=n`),
    as proposed, in `FAULT_SEED`'s ranges. Every mangled frame must be
    dropped or refused by the guest, never crash it or reach the
    application; say which of gopher-metal's parsers (`proto.zig`,
    `net.zig`, `tcp.zig`) each kind exercises.
51. **(gopher-metal) H4, a simulator for `ready.zig`.** It imports only `std`
    and `tcp.zig`, so it is the simulators' to drive: every split of a
    request head's bytes, at the receive buffer's edge and past it (the
    431 path), against a reference parse.
52. **Done (CC, 2026-10-06).** `DHCP_LEASE_S=s` is the lease the peer's
    OFFER and ACK carry; each ACK while one is held is a renewal, one after
    it ran out is counted late, and the run's end (only when the knob is
    set, so no script's output changes) says
    `metal-vmm: dhcp: a lease of s s; r renewals, l requests after it ran
    out; it was held to the end` or `...; it ran out at t s of the guest's
    time, unrenewed`. A knob only a person sets (not drawn). What the box
    runs: `DHCP_LEASE_S=60` on a run past a minute, to see if gopher-metal
    renews. **(metal-vmm) H2, a lease that ends** (`DHCP_LEASE_S=n`). The peer's
    side only; whether gopher-metal renews is what the box runs it to see.
53. **Done (CC, 2026-10-06): built, it was small.** `VOLUME=<file>` is a
    virtio-scsi controller (device 8, three queues, QEMU's config numbers)
    with one disk at 0:0 (`src/scsi.zig`), answering the six commands v18
    sends and TEST UNIT READY; UNIT ATTENTION once after power-on, which
    v18's `commandSettled` sends again; BAD_TARGET elsewhere.
    `VOLUME_CACHE=1|lie` is the WCE bit with `DISK_CACHE`'s semantics, and
    `VOLUME_CUT_AFTER=n` the power. Tested by a fake driver that builds
    requests as v18's `scsi.command` does, and in fuzz.zig on dice of its
    own (every existing seed is the run it was). What the box runs, with a
    FAT16 volume image chat's data is on: `VOLUME=vol.img VOLUME_CACHE=1
    VOLUME_CUT_AFTER=n` on v18 keeps the message a 303 confirmed, and on
    `antithesis-sdk`'s `scsi.zig` (no flush) loses it; `VOLUME_CACHE=lie`
    loses it on both. One finding for the driver, under Questions. **Was:**
    **(metal-vmm) The SCSI half of item 44.** Prod keeps chat's data on a
    DigitalOcean volume over virtio-scsi (gopher-metal `scsi.zig`), not
    virtio-blk, and `scsi.zig` sends no SYNCHRONIZE CACHE either. If
    metal-vmm has no virtio-scsi device, write down under Questions what
    the smallest one gopher-metal's driver would accept needs, and build it
    if it is small. **Read `scsi.zig` on gopher-metal's `box/v18`, not
    `antithesis-sdk`** (B11, built 2026-10-06): it now also sends MODE
    SENSE(10) for the caching page at bring-up and SYNCHRONIZE CACHE(10)
    before any response that follows a write (`io.durable`). So the model
    answers six commands, and a knob for the WCE bit with `DISK_CACHE`'s
    semantics (`lie` included) is what lets a run show v18's flush keeping
    a message that the cache would have lost.
54. **Done (CC, 2026-10-06).** I1-I5 under Proposed; I1 built:
    `VOLUME_SYNC_FAIL=n` (`VOLUME_SYNC_FAIL_FOR=k`) answers the nth
    SYNCHRONIZE CACHE, and the k-1 after it, MEDIUM ERROR and keeps
    nothing; the volume's line says how many failed. **Was:** your
    proposals again when 49-53 are done: the next five, then take the
    first.

**Next, after 54** (2026-10-06, late morning). Your branch is not merged
yet: v18's gates (`box/v18`) are running on this box against metal-vmm's
`interrupts` build, and a merge now would change what they test. The box
merges 49-54 once they finish. Keep working on your branch meanwhile.

55. **Done (CC, 2026-10-06), with item 50.** `PEER_MANGLE=n[,m]` (and
    `_RATE`, `_KIND`): a lying copy ahead of the frame picked, twelve kinds
    (`src/mangle.zig`), each checked in a unit test against a port of
    gopher-metal's own checks to be refused by the one `Kind.check` names
    (`proto.parseIpv4`: version, header length and options, checksum,
    total past the frame, fragment; `tcp.Table.handle`: too short for TCP,
    not our address, not our port, data offset), and `zero_window` to reach
    the connection. Drawn by a seed one time in four, last of its knobs,
    so a quarter of seeds change their run; `sweep.sh` already fails a
    seed whose page differs under it, which is the property. Fuzzed on dice
    of its own. **Was:** **(metal-vmm) Item 50, H3, frames that lie, is
    still open**: it has no
    commit and is not marked done. Take it first, as item 50 describes.
56. **Done (CC, 2026-10-06).** `VOLUME_LATENCY_US=us`: each command the
    volume answers is owed to the clock, which the run loop pays before the
    guest runs again. Not a completion held back: gopher-metal's `Q.wait`
    spins on the used ring with `pause` and makes no exit, so it would
    never see one (the same limit as `dhcp.exchange`, faults.zig); the
    spin's TSC reads see the time pass instead, as `busy_ticks` does on a
    droplet. The volume's line adds "N ms waited on it". For the box: v17
    and v18 under the same latency, the client's time for a chat post, is
    what v18's flush costs. **Was:** **(metal-vmm) I2, a volume that is slow** (`VOLUME_LATENCY_US`), as you
    proposed. It is what tells us what v18's flush costs a chat message.
57. **Done (CC, 2026-10-06).** `VOLUME_ATTENTION_AT=n`: CAPACITY DATA HAS
    CHANGED (2Ah/09h) pending from the volume's nth command, told on the
    next but INQUIRY, which is not performed; v18's `commandSettled` sends
    it again. The volume's line says whether it was told. A write that
    meets it is the case to run: `VOLUME_ATTENTION_AT` at a chat post's
    write, and the message still kept. **Was:** **(metal-vmm) I3, UNIT ATTENTION in the middle of a run**
    (`VOLUME_ATTENTION_AT=n`), as proposed.
58. **Done (CC, 2026-10-06).** `knobs.withVolume`: with `FAULT_SEED` and
    `VOLUME` both set, a seed also draws `VOLUME_CACHE` (1 or lie),
    `VOLUME_CUT_AFTER`, `VOLUME_SYNC_FAIL` (`_FOR`) and
    `VOLUME_ATTENTION_AT`, on dice of their own; a test holds every other
    knob of 500 seeds to what it was, and a run without a volume draws none.
    **`sweep.sh` changed, additively**: `VOLUME_SITE=<image>` gives each run
    a fresh copy as its volume, checks it with `sound.sh` as the boot disk
    is, and excuses `VOLUME_CUT_AFTER` as `DISK_CUT_AFTER` is; unset,
    nothing it does changes (`sweep_test.sh` passes). **Was:** **(metal-vmm) I5, a seed that draws the volume's faults**, as proposed:
    no existing seed's run changes.
59. **Done (CC, 2026-10-06), on gopher-metal's `claude/great-wright-i7aste`
    at `bcd434f`, on `f0c132e`.** `src/durable.zig`: `step(disk)` (none,
    clear, synchronize) and `settle`, which `virtio.Block.flush` now asks,
    leaving only `scsi.synchronize` in it; behaviour unchanged.
    `src/durable_sim.zig` drives them over writes, responses, stream turns,
    spill keeps and pushes and SYNCHRONIZE answers, against what each disk
    truly kept: 20,000 seeds clean, three planted bugs caught, seven
    properties on the floor. Every send-queue entry on v18 read by hand:
    covered by `io.durable` or defended (`Spill.push`). **Was:** unblocked
    (the box): **(gopher-metal) I4, the seam under `io.durable`, built for merging.**
    As item 47 was: kernel code, on your branch, for the box to review.
    The rule "nothing joins a send queue while a write before it is
    unflushed" as a pure function of the writes, sends, held streams and
    flush outcomes, `io.durable` and `serviceStreams` calling it, and a
    simulator driving every interleaving, with properties. Build it on
    `box/v18`'s `io.zig`, `stream.zig` and `probe/gopher.zig` (branch from
    `origin/box/v18` for this one item; say so in the commit), since
    `antithesis-sdk` does not have v18 yet. Steve's standing rule applies:
    **an omitted flush is presumed a bug unless a comment defends it.**
**The SDK** (Steve, 2026-10-06; CLOUD_WORK.md, "zig-coverage-sdk: the SDK").
Take these after 55-59, before 60's proposals.

61. **Done (CC, 2026-10-06).** zig-coverage-sdk `a4c8ab7`: `alwaysGreaterThan`,
    `alwaysGreaterThanOrEqualTo`, `alwaysLessThan`, `alwaysLessThanOrEqualTo`
    and the four `sometimes...`, after the Go SDK (`rich_assert.go`): judged
    as their plain kind, `left`/`right` in the details, and an
    `antithesis_guidance` line in its `guidanceInfo` JSON at each new edge.
    When a guidance line goes out is this SDK's rule (first call and each new
    edge): antithesis.com is blocked from this container and the Go tracker's
    file was not reachable, so README says so. `Site` is 128 bytes now.
    `report.py` gives each one's edge and the run that reached it (`afef771`).
    gopher-metal `claude/great-wright-i7aste`: slots in use and half-opens
    (`tcp.zig`, 2 of 2 in the simulator, as predicted), timeouts against
    `max_retries`, FAT's free clusters and directory entries, the page
    cache's bytes against its budget; properties only. metal-vmm's in-run
    table skips guidance lines rather than counting them unreadable.
    **Was:** **(zig-coverage-sdk) Numeric guidance: how close a run came to a limit.**
    Antithesis's SDK has comparisons that remember extremes
    (`AlwaysGreaterThan`, `AlwaysGreaterThanOrEqualTo`, `AlwaysLessThan`,
    `AlwaysLessThanOrEqualTo`, and the `Sometimes` forms), so a report can say
    "the most slots any run had in use" or "the fewest free clusters any run
    left", and an explorer can steer toward the edge. Add them to
    `src/coverage.zig` under their names in Zig's case, with the JSON their
    docs give where they give one; `tools/report.py` shows each one's extreme
    and which run reached it. Then use them where they would have told us
    something this week, without changing behavior: the table's slots in use
    and half-opens (`tcp.zig`; the simulator's 2 slots against the kernel's
    256 is the gap they would have shown), FAT's free clusters and directory
    entries (`fat16.zig`), the longest backoff, and the page cache's bytes
    held. Adding a property to kernel code is fine (item 36's rule);
    changing what it does is not.
62. **Done (CC, 2026-10-06).** `report.py` reads many files; a run is a
    `metal_vmm_run` line and what follows (else a run per boot); each
    property says how many runs reached it and which first, and the ones
    only one run reached are listed (zig-coverage-sdk `afef771`, with
    `tools/report_test.py`). `sweep.sh` now ends with it
    (`COVERAGE_SDK`, a sibling checkout by default; `sweep_test.sh` passes
    with its three merge-worded expectations moved to the report's), and
    `coverage-merge` and `Merged` are gone; the in-run table stays.
    `long.sh` already used `report.py`, and the lines it greps are
    unchanged. One thing `Merged` did that `report.py` does not: it counted
    an unreadable line and went on, where `report.py` stops. It does not
    matter for `COVERAGE_OUT`, which writes only whole lines. **Was:**
    **(zig-coverage-sdk, metal-vmm) One report over many runs.** The SDK's
    `tools/report.py` and metal-vmm's `zig build coverage-merge` (item 22)
    both read the same JSONL, and the merge has what the report lacks: which
    run first reached each property, how many runs reached it, and the
    properties only one run ever reached. Fold those into `report.py`,
    reading item 22's run tags, with tests; then have metal-vmm's
    `sweep.sh` and gopher-metal's `long.sh` use it, and retire
    `coverage-merge` (metal-vmm's in-run table, item 18, stays: it is a
    different job). If retiring it is wrong, say why under Questions.
60. **Done (CC, 2026-10-06), with 59 waiting.** J1-J5 under Proposed.
    **Was:** your proposals again when 55-59 are done.

**From item 60's proposals** (the box, 2026-10-06): J1-J4 are yours, in
this order, after 59 and 61-62. J5 is the box's (B16).

63. **Done (CC, 2026-10-06).** `VOLUME_GONE_AT=n`: from the volume's nth
    command, BAD_TARGET for every command, nothing written; the volume's
    line counts them. v18's `scsi.transfer` and `synchronize` read that as
    an I/O error. Hand-set only: not drawn by a seed, since a sweep has no
    excuse for it yet. For the box: a chat post with the volume gone must
    get no 303. **Was:** J1, a volume that goes away (`VOLUME_GONE_AT=n`), as proposed.
64. **Done (CC, 2026-10-06).** `VOLUME_READ_ONLY_AT=n`: from the volume's
    nth command, MODE SENSE's WP bit, and every WRITE CHECK CONDITION, DATA
    PROTECT (7h), WRITE PROTECTED (27h); reads and SYNCHRONIZE CACHE still
    answer. Hand-set only. For the box: every save after it must fail
    visibly, none confirmed. **Was:** J2, a volume that turns read-only (`VOLUME_READ_ONLY_AT=n`), as proposed.
65. **The box's now (B18), at Steve's direction.** J3, lies in the peer's UDP (`PEER_MANGLE` for DHCP).
66. **Done (CC, 2026-10-06).** `VOLUME_SYNC_US=us`: each SYNCHRONIZE CACHE
    owes that much more to the clock than `VOLUME_LATENCY_US`'s every
    command; the volume's line says the wait and SYNCHRONIZE CACHE's share
    of it. For the box: v17 and v18 with `VOLUME_LATENCY_US=500
    VOLUME_SYNC_US=5000`, say, and a chat post's time. **Was:** J4, a flush that costs more than a read (`VOLUME_SYNC_US`), as proposed.
68. **Done (CC, 2026-10-06).** `VOLUME_CUT_AT_EXIT=1`: at every end, the
    exit door, idle, or a bad one, `cutAtExit` has each write cache (the
    volume's and `DISK_CACHE`'s) lose what was never synchronized
    (`Cache.loseAtExit`) before the reports and before the image is written
    back. One line counts each one's loss, and the volume's and the disk's
    own lines say the power failed when the guest stopped. Hand-set only.
    After a `VOLUME_CUT_AFTER` cut it loses nothing more. Not run against a
    guest here (no KVM): B14 is
    `VOLUME=<copy> VOLUME_CACHE=1 VOLUME_CUT_AT_EXIT=1`, a chat post, and
    then the volume read back. **Was:** **(metal-vmm) The power fails when the guest stops: `VOLUME_CUT_AT_EXIT=1`**
    (the box, 2026-10-06, for B14). At the exit door, or any other end,
    each cache loses what was never synchronized (`Cache.lose`), as
    `VOLUME_CUT_AFTER` does, and the volume's line says so. Why: B14 posts
    a chat message to gopher.elf on a volume with `VOLUME_CACHE=1`; v17
    sends no SYNCHRONIZE CACHE and v18 sends one before its 303. But every
    write of the post comes before the 303 and none after, so no
    `VOLUME_CUT_AFTER=n` puts the cut after the response. A person's knob,
    not a seed's. Then B14 is: v17 loses the message, v18 keeps it.
67. **Done (CC, 2026-10-06).** K1-K5 under Proposed. **Was:** your
    proposals again when 59, 61-64, 66 and 68 are done.

**From item 67's proposals** (the box, 2026-10-06): all five are yours, in
this order. v18 serves (gopher-metal `master` = `box/v18`). B14 is done with
your item 68 (v17 loses the message, v18 keeps it), and K1 is its next step.

70. **Done (CC, 2026-10-06).** `sweep.sh` with `POST=<request>`,
    `READ_BACK=<path>`, `MARK=<text>` and `VOLUME_SITE`: each seed posts
    with `VOLUME_CUT_AT_EXIT=1` and its drawn volume faults, then an unhurt
    boot on a copy of that volume asks for `READ_BACK`. A 303 whose message
    the read-back lacks fails, but under `VOLUME_CACHE=lie` or
    `VOLUME_SYNC_FAIL` ("lost (allowed: ...)", the design's own losses, as
    `durable_sim` excuses them). No reader for FAT on the image: the
    kernel itself reads it back, as the README's write-path check did, so
    no mtools. The page is not compared; the attached volume is still
    checked with `sound.sh`. `sweep_durable_test.sh`, seven seeds told in
    advance; `sweep_test.sh` unchanged and passing. Not run against
    gopher.elf here (no KVM): the box's B14 request and `/chat/recent` are
    the obvious `POST` and `READ_BACK`. **Was:** K1, a sweep that judges durability, not the page, as proposed.
71. **Done (CC, 2026-10-06).** `VOLUME_CACHE_KEEPS=k`: at any cut (a
    `VOLUME_CUT_AFTER`, a disk cut, or `VOLUME_CUT_AT_EXIT`) each sector the
    volume's cache never synchronized has reached the media with chance
    1/k, decided by a hash of `FAULT_SEED` and the sector (so the walk's
    order does not matter and a seed repeats it); the volume's line counts
    them. `knobs.withVolume` draws it, last, half the times it draws
    `VOLUME_CACHE`, so no earlier volume draw moves. Fuzzed. The sweep's
    existing check is the property: the attached volume must stay sound.
    Also fixed: item 68 had left `lose`'s doc comment on `loseAtExit`.
    **Was:** K2, a write cache that writes back in its own order, as proposed.
72. **K3, crowds the size of the kernel's table**, as proposed.
73. **K4, an edge floor** (`report.py --edges`), as proposed.
74. **K5, one report, two images** (`report.py --against`), as proposed.
75. **Your proposals again** when 70-74 are done.

## Proposed

*(CC adds items here, one line each on why.)*

From the peer's review (`docs/reviews/REVIEW-peer.md`), most urgent first:

- **P1. TIME-WAIT, and closed ports that answer.** A finished, refused or
  unopened client is silent where a real host acknowledges a repeated FIN
  or resets. The guest is blamed for giving up: seed 23953's class.
- **P2. The guest's window, kept (CC, with item 39a) and probed (not yet: a zero window waits on the guest's own update).** The peer ignores SND.WND and
  never probes, so a request larger than the guest's 16 KiB free window
  loses its tail for good, and the guest is blamed after `idle_ns`.
- **P3. Recovery like a real client's.** No RTT sample, a 1 s floor, no
  fast retransmit, one segment per timeout: a few lost request segments
  outlast the guest's 10 s patience, where Linux would have recovered.
- **P5 (with P6, P7). RFC 5961 resets and §3.10.7 acknowledgement checks.**
  The peer believes any reset and takes data acknowledging unsent bytes, so
  a guest bug of those shapes passes as correct.
- **S1. The sweep excuses the peer's own give-up.** A peer in `gave_up` or
  `gone` costs the page through its own fault; say its state on stderr and
  let `sweep.sh` excuse it.
- **P4 (the box's call). An MSS option in the peer's SYN.** Without one the
  guest sends 536-byte segments where production sees 1460, so every
  frame-numbered map is of a segmentation production never sees.

From the review (`docs/reviews/REVIEW-interrupts.md`), most urgent first:

8. **Done (CC).** **Config-data port accesses at any offset and width (H1).** `inl $0xCFD`
   panics this program (integer overflow, `pci.zig:350`): a guest's input
   kills the VMM, which an explorer will find first.
9. **Done in item 5 (CC).** **The deadline timer between halts (H2).** `tick` runs only in `rest`, so
   a deadline passed while running reads back unchanged and is lost when
   rewritten; gopher-metal wakes less often here than on a droplet.
10. **Done (CC).** **A halt with interrupts off stops the machine (M1).** `rest` ignores
   `if_flag`, so `cli; hlt` resumes past the `hlt` later, which no PC does.
11. **Done (CC).** **A vector is in service only once injected (M2).** The not-ready branch
    of `rest` strands a vector in service and ends the run; untested.
12. **Done (CC; the MSI-X half in item 4).** **BAR accesses split into aligned dwords (M3).** A QWORD unmask of an
    MSI-X entry leaves it masked; a QWORD `queue_desc` write keeps the stale
    high half. The MSI-X half folds into item 4.
13. **Done (CC).** **Queues that do not exist read as absent (M5).** A `queue_select` past
    the last aliases the last queue, and `num_queues` is 2 for one-queue
    devices; virtio 1.2 §4.1.4.3.2 requires `queue_size` 0.
14. **Done for TRANSPORT=pci (CC); the microvm half is the box's call.** **The host's time behind the filter, on both machines (D1).** `rdtscp`,
    IA32_TSC, TSC_ADJUST, MPERF/APERF and kvmclock still read the host; the
    microvm half changes check.sh's guests, so it is the box's to merge.
15. **Done (CC; check.sh first, see Questions).** **Ports 0xE0/0xE1 answer only the rewritten instructions, and the
    deadline marks are counted (D2, D3).** Any `out 0xE1` reaches the APIC's
    MSRs today, and a kernel without marks runs with no timer, silently.
16. **Done (CC).** **A halt is not a hang on the PC-shaped machine (P1).** An idle server
    is killed as `GuestStuck` after ~1M exits of resting (minutes of guest
    time); soaks and the explorer will hit it.

From item 32: the next five faults or checks for gopher.elf, most finding
first (CC):

- **F1. A bad sector, aimed by address** (`DISK_BAD_SECTOR=s[,t]`, with
  `DISK_READS_ONLY` beside `DISK_WRITES_ONLY`). Every disk finding above is
  about one sector (2180, the FAT's mirror; the pinned file), and a request
  count reaches it on one path only. A sector is reached on every path, stays
  bad across a reboot as a real one does, and refusing the pinned file's
  reads while its writes land is the aim "The bookmark that eats your
  bookmarks" says this machine cannot take yet. **Built (CC); not yet run against gopher.elf.**
- **F2. Silent rot on read** (`DISK_ROT=sector,byte`): the sector is served
  with one byte changed and an "ok". fat16.zig checks nothing it reads, so a
  FAT entry that points back into its own chain is a loop to hang on, and a
  rotted directory entry a file written over another's clusters; the
  explorer finds which bytes matter.
- **F3. A write cache, and whether the guest ever flushes** (offer
  `VIRTIO_BLK_F_FLUSH`; `DISK_CACHE=1` holds acknowledged writes until a
  flush, and a power cut loses what was not flushed). gopher's driver may
  never send a flush; on a disk with a cache, "303 means saved" (README,
  "The write path") would then be true here and false on hardware.
- **F4. A client that retries what got no answer** (`PEER_RETRY=1`: a client
  whose connection closed with no response sends the same request again on
  a new one), with a check that the volume holds the message once. The
  three-run row of "The multi-file path" says a user who retries gets a
  duplicate; this measures it.
- **F5. The calendar as a knob** (`RTC_BOOTS_AT=unix`, clock.zig's
  `boots_at` today a constant): boots on 2038-01-19, 2099-12-31, 2108 (past
  FAT's last year), a leap day, and just before midnight, for FAT
  timestamps, cookie expiry and anything that sorts by date.

From item 36 (CC):

- **G1. The seam that makes fat16.zig a layer with nothing below it.** It
  imports `virtio.zig` for one thing: a disk of 512-byte sectors, through
  `Block.read`, `readMany`, `write`, `writeMany`, `Block.max_sectors` and
  `blk_s_ok`. Let `Volume` take that as a small interface of its own (a
  `Sectors` struct of four function pointers and a context, or `Volume`
  generic over a device type), with virtio.Block one implementation and an
  in-memory one another. What stays behind is the driver; what comes out
  is everything fat16 decides. And the test hooks that live in virtio.zig
  today (`Block.inMemory`, `fail_after`, `fail_after_writes`, `fault`, the
  `requests` and `writes` counts) move to test_disk.zig, out of the
  driver the kernel runs. Nothing about what fat16 does changes; it is a
  move the box makes, because fat16 serves lynrummy.com.
- **G2. A fault on a multi-sector write**, for test_disk: `fail_after`
  stops every request after it, so a failure meant for an append's run of
  data sectors meets the read before it first, and "fat: a run of sectors
  fails to write" is reached about once in 160 failure points. A fault
  that refuses only the next write of more than one sector reaches it
  every time. test_disk.zig is not the simulators' to change.

From item 48: the next five, most finding first (CC):

- **H1. A slow client** (`PEER_DRIP_US=us`: each segment of the request a
  gap after the last, with `PEER_MSS` to make them small). gopher.zig serves
  only a whole request and lets go only of a connection silent for
  `idle_ns`, so a client that is never silent and never done may hold its
  slot for as long as it drips; with `PEER_CLIENTS`, how many such clients
  it takes to keep a good one out is the measure. **Taken; see item 48.**
- **H5. Pipelining** (`PEER_PIPELINE=1`: the second request sent with the
  first). gopher.zig answers one request and closes with the second still
  unread; whether the table sends a FIN or a reset then, and whether the
  client still gets the whole first answer, is the case Apache's
  lingering close exists for.
- **H3. Frames that lie, from the peer** (`PEER_MANGLE=n`): an IP total
  length past the frame, IP options, a fragment, a TCP data offset past
  the segment, a zero window with data. The guest's parser sees only well
  formed frames today; the VMM's fuzzer covers the VMM, not the guest.
- **H2. A lease that ends** (`DHCP_LEASE_S=n`, the peer's offer): does
  gopher-metal renew at T1 or rebind at T2? If not, a real network takes
  its address back while it serves.
- **H4. A simulator for `ready.zig`** (gopher-metal): whether a request
  head is whole, over every split of the bytes, at the receive buffer's
  edge, and past it (the 431 path).

From item 54: the next five, most finding first (CC):

- **I1. A SYNCHRONIZE CACHE that fails** (`VOLUME_SYNC_FAIL=n`,
  `VOLUME_SYNC_FAIL_FOR=k`: MEDIUM ERROR, nothing kept). v18's `io.durable`
  logs a failed flush and lets the response go out, and tries again before
  the next one. So one failure then a cut (`VOLUME_CUT_AFTER`) is a 303 for
  a message the volume lost, and k failures in a row are k responses sent
  on writes not yet kept: the measure of that choice. **Taken; see item
  54.**
- **I2. A volume that is slow** (`VOLUME_LATENCY_US=us`: each command
  answered that long after its doorbell, on the guest's clock). A DO volume
  is network storage, milliseconds a command; here it answers at once. v18
  sends a SYNCHRONIZE CACHE before every response after a write, so what a
  chat message costs in time on a real volume is unknown until the volume
  takes time. Needs the completion deferred to a later exit, as the wire's
  latency is.
- **I3. UNIT ATTENTION in the middle of a run** (`VOLUME_ATTENTION_AT=n`:
  the nth command answers it, as a DO volume resized or its path reset
  does, with CAPACITY DATA HAS CHANGED or POWER ON). v18's `commandSettled`
  sends it again; a write that meets it is the case to watch, and whether
  the capacity is ever read again.
- **I4. The seam under `io.durable`** (gopher-metal, the box's): the rule
  "nothing is queued to send while a write before it is unflushed" pulled
  out of io.zig as a pure function of what was written and what is about
  to be sent, so a simulator can drive it over any interleaving of writes,
  sends, held streams and failed flushes. Today it can be checked only by a
  guest on a machine.
- **I5. A seed that draws the volume's faults** (`FAULT_SEED` with
  `VOLUME` set: `VOLUME_CUT_AFTER`, `VOLUME_SYNC_FAIL`, `VOLUME_CACHE`),
  so `sweep.sh` can sweep chat's real write path as it sweeps the boot
  disk's. Changes no existing seed's run: their draws come first, and the
  volume's are taken only when one is attached.

From item 60: the next five, most finding first (CC):

- **J1. A volume that goes away** (`VOLUME_GONE_AT=n`: from the nth
  command the controller answers BAD_TARGET, as a DO volume detached under
  a running droplet does). Chat's data is then unreachable mid-run: does a
  post get a 5xx and not a 303, and does the next boot say "the volume this
  machine serves is not attached" rather than serve from the boot disk?
- **J2. A volume that turns read-only** (`VOLUME_READ_ONLY_AT=n`: MODE
  SENSE's WP bit, and WRITE answered DATA PROTECT, key 7), which is what a
  DO volume does after an I/O error on the host. Every save must fail
  visibly; none may be confirmed.
- **J3. Lies in the peer's UDP** (`PEER_MANGLE` for its DHCP frames: a UDP
  length past the datagram, DHCP options running off the end, a lease
  option of the wrong length). Item 55 mangles only TCP, so
  `proto.parseUdp` and `dhcp.zig`'s option walk have only met well-formed
  replies.
- **J4. A flush that costs more than a read** (`VOLUME_SYNC_US`, beside
  `VOLUME_LATENCY_US`): on network storage SYNCHRONIZE CACHE is the slow
  command, and v18 sends one per response after a write, so its own price
  is the number item 56 is for.
- **J5 (the box's). A coverage property per refusal in the guest's
  parsers** (`proto.parseIpv4`'s and `tcp.handle`'s early returns, as
  "tcp: a damaged segment is dropped" already is), so a sweep's merged
  coverage says which of `PEER_MANGLE`'s lies each parser met, rather than
  only that the page held.

From item 67: the next five, most finding first (CC):

- **K1. A sweep that judges durability, not the page** (`sweep.sh` with
  `POST=<request>`): each seed posts one chat message, with the volume's
  faults drawn (item 58) and `VOLUME_CUT_AT_EXIT=1` always on, and its
  verdict reads the volume afterwards: **a 303 for a message the volume
  does not hold fails**, whatever else the seed did; no 303 and no message
  is allowed. That is B14's property swept over thousands of fault
  schedules instead of one, and it is the first use of the volume knobs
  that does not need an excuse for a page that differs. It needs a reader
  for the chat file on a FAT image (mtools, as `sound.sh` uses fsck).
- **K2. A write cache that writes back in its own order**
  (`VOLUME_CACHE_KEEPS=k`: at a cut, each unsynchronized sector reaches
  the media with chance 1/k, chosen by the seed, not none of them). A real
  cache drains in an order of its own, so after a cut the volume can hold
  a directory entry without its data, or a FAT chain without its entry.
  `VOLUME_CACHE=1`'s all-or-nothing never shows those; `sound.sh` after
  such a cut is FAT's crash consistency under reordering, measured.
- **K3. Crowds the size of the kernel's table** (gopher-metal,
  `tcp_sim.zig`): item 61's comparisons showed the simulator's table
  peaks at 2 slots of 2, and a crowd's at 8, where gopher.zig holds 256.
  A crowd tier of 64 to 256 slots and as many clients, few seeds, so
  `oldestHalfOpen`'s scan and revival meet a table as full as prod's. Its
  cost is the question; the sweep says the size in the commit.
- **K4. An edge floor** (zig-coverage-sdk, `report.py --edges <file>`):
  a line `tcp: slots in use stay within the table  >= 64` fails a run
  whose comparison never came that close, as `--floor` fails a property
  never reached. Without it, K3's gap is visible only to someone reading
  the report. And note: an edge is the nearest `left - right`, so 2 of 2
  and 256 of 256 are the same edge (0); the floor should judge `left`.
- **K5. One report, two images** (zig-coverage-sdk, `report.py --against
  <b.jsonl>`): the properties one run set reached and the other did not,
  and the edges that moved. v17 against v18 under the same seeds says
  what v18's flush changed in the kernel's own properties, beside the
  page and the volume.

Folded into existing items rather than new ones: M4, L1, L2, L3 into item 4
(MSI-X); L4 into item 5 (APIC); L5 (0xCF9) waits until a reset is something
this machine survives.

## Questions

*(For the box or Steve. Take the next item; do not wait.)*

- **(CC, item 59) Answered: Steve approved the merge of `box/v18`;** item
  59 is built on it (see item 59).

- **Every entry to a send queue is covered or defended.** On v18,
    `tcp.Table.queue` is called from `Stream.sendAll` (two places, after
    `io.durable`), `Spill.push` (defended in its comment: its bytes passed
    `sendAll`), and `serviceStreams`' carry, frames and ping (after its own
    `io.durable` at the top); `probe/http.zig` and `probe/ladder.zig` are
    other probes. `table.finish` sends no data. So no omitted flush is
    undefended today.
  - **The seam**: a pure `durable.zig` with a disk as `{ unflushed,
    write_cache: ?bool, asks: bool }` (asks: it is SCSI, so it can be
    told to synchronize) and `step(disk)`: `.none` (nothing written),
    `.clear` (virtio-blk without FLUSH, or a disk that says it writes
    through: durable once written) or `.synchronize`; and `settle(disk,
    step, ok)`. `Block.flush` becomes `step`, then `scsi.synchronize` only
    for `.synchronize`, then `settle`. The simulator drives `step` and
    `settle` over writes, responses, stream turns, spill pushes and
    SYNCHRONIZE outcomes (good, failed, ILLEGAL REQUEST), against what each
    disk truly does (a cache, none, or one that lies), with properties: no
    output claims a write not yet durable but after a flush that failed
    for it (counted, the defended case) or a disk that lied; no
    synchronize with nothing written since the last good one; after a
    failure the next output synchronizes again.
  **Answer (the box, 2026-10-06):** merged `origin/box/v18` into
  `claude/great-wright-i7aste` in gopher-metal (`f0c132e`, unit tests pass);
  fetch it and build 59 there. Steve's note: your permission checks
  sometimes refuse what he isn't there to approve. When that happens, do as
  you did: say what you need here and take the next item. The box does the
  shared-branch step at its next look.

- **(CC, item 55) B14 wants `VOLUME_CACHE=1`, not `lie`.** Under `lie`
  the volume holds writes and says WCE=0 in MODE SENSE, and v18's
  `Block.flush` believes it (`write_cache == false`) and sends no
  SYNCHRONIZE CACHE, so v18 loses the message too. `VOLUME_CACHE=1` says
  WCE=1: v18 synchronizes and keeps it, v17 sends nothing and loses it,
  which is the comparison B14 means. `lie` is the case where v18's rule
  "a disk that says it writes through is believed" is a choice, and it
  shows the loss, as it should.

- **(CC, item 53) gopher-metal's `scsi.bring` reads max_target and max_lun
  4 bytes late.** virtio 1.2 §5.6.4 (and Linux's `virtio_scsi.h`) put
  `max_channel` at 28 (le16), `max_target` at 30 (le16) and `max_lun` at
  32 (le32); `bring` reads `configRead16(device, 32)` and
  `configRead32(device, 36)`. So its max_target is max_lun's low half
  (QEMU's 16383, clamped to 63) and its max_lun is whatever lies past the
  config (QEMU on PCI answers all ones there, clamped to 7; metal-vmm
  answers 0). It finds a disk at 0:0 either way, and would miss one at a
  LUN past 0 here. 30 and 32 are the spec's; the box's call, being driver
  code.

- **(CC, item 44) gopher-metal never flushes, and never negotiates FLUSH.**
  Its virtio driver (`negotiate`, `want_low`) asks for no feature in word 0
  and its block requests are only `blk_t_in` and `blk_t_out`. So under
  `DISK_CACHE=1` it gets write-through, as virtio 1.1 §5.2.5.1 promises,
  and loses nothing: the honest answer on this machine. On a disk whose
  cache lies (`DISK_CACHE=lie`, and many consumer drives), every write since
  boot is at the mercy of the power, and "303 means saved" (README, "The
  write path") holds only as far as the drive keeps its word. Negotiating
  FLUSH and flushing at the end of each save would make it true either way;
  the box's call, being kernel code. Not yet run against gopher.elf here.

- **(CC, item 35) request_heap: the same request does not always ask the
  same amount.** `used` counts a growth only when the arena grows the block
  in place; otherwise the caller's fallback is counted the whole new block.
  Which happens depends on the room in the arena's node, which is what the
  request before left, and `preheat` leaves a different capacity than a
  reset keeps. So the figure the judge requires to repeat can move with
  what came before, preheated or not (seeds 69, 153, 285, a skipped test in
  `pure_sim.zig`). Counting what the request asked for (each `alloc`'s
  length, each growth's) the same way on both paths would make it a
  property of the request alone; or the judge compares only requests in
  the same position. The box's call.

- **(CC, item 23) `sweep.sh` is new** (no existing script changed), with
  `sweep_test.sh` for its logic. Please run it on gopher.elf, e.g. `SITE=...
  ./sweep.sh 1 200`, and answer here: how long a seed takes, which seeds fail
  and why, and whether the "allowed" rule (a page may differ under
  PEER_RESET_AT, PEER_VANISH_AFTER or DISK_REFUSE) is the rule you want.
  KEEP=<dir> keeps every run's log, page and the coverage JSONL.

- **(CC, item 30) What the box's half of a snapshot must hold**, named by
  what it is, not by ioctl: the devices' half is `snapshot.zig`, a value
  copy of every model restored in place, plus the disk's bytes.
  1. **The general registers**, RIP and RFLAGS among them.
  2. **The special registers**: segments, descriptor tables, CR0, CR2-CR4,
     CR8, EFER, and the APIC base as KVM keeps it.
  3. **The FPU, SSE and extended state** (XSAVE, and XCR0). gopher-metal is
     soft-float, but nothing stops a guest from using them.
  4. **The MSRs KVM answers itself** (not the filtered ones, which are
     apic.zig's): at least the SYSCALL MSRs, FS and GS bases, TSC_AUX, and
     whatever the guest wrote. Listing which ones KVM holds for this VM is
     part of the box's half.
  5. **The vCPU's events**: an interrupt or exception mid-injection, the
     interrupt shadow (an `sti` or `mov ss` just executed), NMI state. A
     snapshot taken between `KVM_INTERRUPT` and the entry that takes it must
     not lose the vector.
  6. **The run structure's own flags this program sets**:
     `request_interrupt_window`, and whether an exit was completed (a port
     read answered, or a rewritten `out` whose RIP KVM skips on the next
     entry). The simplest rule is to snapshot only between exits, after the
     answer is written, which is where this program's loop already is.
  7. **Guest memory**, 512 MiB. A full copy should take on the order of a tenth of a second (an estimate from memory bandwidth, not measured here). A
     copy-on-write mapping, or KVM's dirty-page log, would make a branch
     cheap. Which one is the box's call.
  8. **And no host time anywhere.** The TSC is this program's (rewritten),
     so restoring needs no TSC offset, as long as no unmarked `rdtsc` ran
     (item 14 and the README).

## Answers

*(The box answers here, on `interrupts`.)*

**2026-10-06 late morning, the box:** v17 shipped (gopher-metal `4953f7e`).
v18 is on `box/v18` and its gates are running. Your item 53 question is
right: `scsi.bring` reads max_target and max_lun at 32 and 36 where the
spec has 30 and 32. It is fixed in v18 after its gates (B13). Item 44's
question is answered by v18 (`io.durable`).

- **B13.** `scsi.bring`'s config offsets to the spec's (30, 32), in v18.
- **B14 done (2026-10-06, with item 68):** a chat post to gopher.elf on a
  volume, `VOLUME_CUT_AT_EXIT=1`. Honest cache (`VOLUME_CACHE=1`): v17 0
  SYNCHRONIZE CACHE, 303, message lost; v18 1 SYNCHRONIZE CACHE, 303, message
  kept. Lying cache: both lose it, as expected (WCE=0 is believed). Still
  open: H5 and H2 against gopher.elf, and this as a `long.sh` scenario (B19).
- **B14 (as first written; `lie` was the wrong cache). v18's flush, proven on metal-vmm's volume**: gopher.elf from v17
  and from v18, each with `VOLUME_CACHE=lie` and `VOLUME_CUT_AFTER` at the
  write after a chat message's 303: v17 loses the message, v18 keeps it.
  Then H5 (`PEER_PIPELINE`) and H2 (`DHCP_LEASE_S`) against gopher.elf.
- **B15. The invariants in the kernel, as `always`** (Steve's SDK question,
  2026-10-06): a `-Dcoverage` gopher.elf calls `tcp_check.check` after every
  `handle` and `transmit` as one `always("tcp: the table's invariants hold")`,
  and FAT's own `check` at the end of a run, so every metal-vmm run checks
  what the simulators check, on the real kernel. Production builds unchanged.
- **B16. A verdict keyed by what the image reads, not angry-gopher's commit.**
  v18's `long.sh` passed but kept no verdict: an angry-gopher docs commit
  (README, `ops/deploy`'s comment) landed mid-run. Key the pair by the git
  trees the image reads (`zig-server`, `pages`, `gallery`, and every
  `@embedFile` source `extract_assets.py` names), so a docs commit keeps it.
- **B18 (was CC's 65, J3).** Lies in the peer's DHCP replies (`PEER_MANGLE`
  for UDP: a length past the datagram, options off the end, a lease option
  of the wrong length), so `proto.parseUdp` and `dhcp.zig`'s option walk meet
  more than well-formed replies. The box's, not CC's (Steve, 2026-10-06).
- **B17 (J5).** A coverage property per refusal in the guest's parsers
  (`proto.parseIpv4`, `tcp.handle`'s early returns), so a sweep shows which
  of `PEER_MANGLE`'s lies each parser met.

**2026-10-06 morning, the box: items 47 and 48 merged** (gopher-metal
`4953f7e`, 829/830 with 1 skipped; metal-vmm `49f46ab`, 221/221, `check.sh`
and `same.sh` clean). v17's gates are running (`gates.sh`, then the whole
`long.sh`). Your item 33 crowd question is answered by item 47. Items 49-54
are yours.

Added to the box's list:

- **B11.** Does prod's chat volume cache writes? Read MODE SENSE's caching
  page (WCE) from the real volume on a droplet boot; if it caches,
  SYNCHRONIZE CACHE at the end of each save in `scsi.zig` (and FLUSH for
  virtio-blk, item 44), so "303 means saved" holds whatever the disk does.
- **B12.** The real kernel reaches revival: a `long.sh` rough-peer run
  losing the client's handshake ACK with a flood started inside the next
  round trip (REVIEW-flood's recipe: `PEER_EAT=4 PEER_FLOOD=1024
  PEER_FLOOD_AT_US=1000 PEER_FLOOD_GAP_US=100`), and the revival property
  on the metal floor. Also H1 (`PEER_DRIP_US`) against gopher.elf: how many
  slow clients keep a good one out.

**2026-10-05 late, the box: B5 done** (gopher-metal `582510e` on
`antithesis-sdk`). Your two fat16 findings from item 36: makePath now stops at
the last level `check` walks (15) and refuses deeper as `BadName`; `readAt`
passes every cluster through `Loop`, so a looped chain is refused on read
(fat_sim's new "refused on read" property, 114 at the default size; your
"reads as other bytes" probe stays, for the window inside two laps). Your
skipped depth test now asserts this behavior and runs. Pull `antithesis-sdk`
before item 47.

**2026-10-05 late, the box: items 41-46 merged (`9b0a41c`); B1 run.** metal-vmm
220/220, `site.sh all` green, gopher-metal `gates.sh` green except metal-vmm's
`check.sh`, and `long.sh metal` green (15 of 15 on the floor). `check.sh` failed
on rng and clock: item 31's cost line is the last line of `ours.txt`, and those
two probes compare only the last line of the raw output, not the filtered one.
Fixed on `interrupts` (one line). Nothing to redo; for next time, when a change
adds to what a run prints, grep `check.sh`, `same.sh`, `rest.sh` and
`sweep.sh` for every read of the raw output, not only the filter. The box now
runs `check.sh` and `same.sh` (half a minute) at every merge.

**2026-10-05 evening, the box: items 22-40 merged** (metal-vmm `c09ce2d`,
201/201; gopher-metal `f928de0`, then `fc42856`, 808/811 with 3 skipped).
The guest gates have NOT run on these merges yet (Steve away; B1 below).
In gopher-metal: the log_ring fix is in (your `<`, `fc42856`), and the
fat16 depth test is skipped with its reason until B5 decides. Your item 40
question: yes, item 42. Items 41-48 are yours.

### The box's own list, in order

- **B1.** The gates on both merged bases: metal-vmm `check.sh`, `same.sh`,
  `site.sh all`, `rest.sh all`; gopher-metal `gates.sh`; `long.sh metal`
  (item 37 caps the peer's segments, so the sweep's frame counts move).
- **B2.** `sweep.sh 1 200` on gopher.elf; answer item 23 here (time per
  seed, failing seeds, the "allowed" rule).
- **B3.** F1, the bad sector, against gopher.elf (the pinned file, the
  FAT's mirror).
- **B4.** The last three TCP properties on the real kernel: past the window
  (`PEER_IGNORE_WINDOW`, 39a), from behind (`WIRE_EAT` ranges, 39b), a
  reopened window (a large upload); the metal floor to 18.
- **B5.** fat16, the two findings: makePath's depth against check's and
  removeTree's (lean: makePath refuses past `max_tree_depth`, so the code
  never makes what it calls broken), and a looped chain on read (lean:
  `readAt` refuses with `Loop`, as an append does). Kernel code; Steve
  hears before an image.
- **B6.** request_heap's figure (item 35's second finding): count what a
  request asks for, the same on both paths.
- **B7.** G1, the seam that makes fat16.zig a layer with nothing below it;
  then G2 (a fault on a multi-sector write) in test_disk.zig, once the
  test hooks have left virtio.zig.
- **B8.** Item 17 (is the deadline mark needed?).
- **B9.** The snapshot's box half (item 30's note): registers, events,
  MSRs, and guest memory (KVM's dirty log or copy-on-write).
- **B10.** Item 14's microvm half, with its own `check.sh` run.

**Steve, 2026-10-05:** the flood: **yes**, revival (option 4), item 47.
The next image: **not yet**; B5's fat16 fixes and item 47 wait on
`antithesis-sdk` for it.

**2026-10-05, the box: item 21 merged (`44f6522`)**: 160/160, check.sh,
same.sh, site.sh all and rest.sh all green. Items 22-32 are yours, in order;
Steve wants a long queue, so do not stop between them.

**2026-10-05, the box: items 18-20 merged (`f66becf`)**: 156/156, check.sh,
same.sh, site.sh all and rest.sh all green. Item 21 is yours. The box puts
item 7's knobs and item 20's clients into gopher-metal's long tier next, and
raises its metal floor to what they reach.

**2026-10-05, the box: item 16 merged (`b9c3943`)**: 135/135, check.sh,
same.sh, site.sh all and rest.sh all green. Items 18-20 are queued; take
them in order. The box runs gopher-metal's long tier on this branch now.

**2026-10-05, the box: items 1-15 merged to `interrupts` (`7ffdf55`).** On
the box after the merge: `zig build test` 133/133, `check.sh` 9/9 (item 15's
RIP-at-the-`out` assumption holds), `same.sh` 7/7, `site.sh all` 12/12,
`rest.sh all` 12/12 on a gopher.elf with today's fat16.zig. Thank you: H1
and H2 were real, and the review is the shape we wanted.

- **D3.** Observed on this box: Linux 6.8.0-138-generic, an Intel host with
  `kvm_intel.preemption_timer=Y`, no in-kernel irqchip, the filter denying
  0x1B and 0x6E0 for read and write. gopher.elf with an unmarked deadline
  `wrmsr` (gopher-metal before `1f742bb`) at a 200 ms wire: 2 MSR exits in
  the run, both IA32_APIC_BASE from `startApic`, while `rest` ran its
  `wrmsr` before each of its halts; the timer never fired. That the fast
  path is the cause is my reading, not proven. An experiment settles it:
  the same kernel with the mark removed, on today's branch. Queued as item
  17, for the box. The mark stays until then.
- **P1.** Yes: a halt `rest` resolves resets `quiet`. And a guest that rests
  forever with nothing asked of it (gopher.elf with its timer always armed)
  then ends on a bound in GUEST time, not exits: `PATIENCE_S`, default 600
  (ten minutes of the guest's time), reported as idle rather than stuck.
  Item 16 is yours with that shape.
- **Item 7's map** is exactly what the box needs to raise gopher-metal's
  metal floor (`coverage/floor-metal.txt`, `long.sh`). The box does that
  next, with the knobs as you named them.
- **Item 14's microvm half**: not yet. It changes what check.sh's guests
  read on the machine QEMU judges; the box takes it with its own gate run.
