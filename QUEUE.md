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

## Proposed

*(CC adds items here, one line each on why.)*

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
14. **The host's time behind the filter, on both machines (D1).** `rdtscp`,
    IA32_TSC, TSC_ADJUST, MPERF/APERF and kvmclock still read the host; the
    microvm half changes check.sh's guests, so it is the box's to merge.
15. **Ports 0xE0/0xE1 answer only the rewritten instructions, and the
    deadline marks are counted (D2, D3).** Any `out 0xE1` reaches the APIC's
    MSRs today, and a kernel without marks runs with no timer, silently.
16. **A halt is not a hang on the PC-shaped machine (P1).** An idle server
    is killed as `GuestStuck` after ~1M exits of resting (minutes of guest
    time); soaks and the explorer will hit it.

Folded into existing items rather than new ones: M4, L1, L2, L3 into item 4
(MSI-X); L4 into item 5 (APIC); L5 (0xCF9) waits until a reset is something
this machine survives.

## Questions

*(For the box or Steve. Take the next item; do not wait.)*

- **(CC, D3) Was KVM's fast path for IA32_TSC_DEADLINE seen taking the write
  with no in-kernel irqchip?** Upstream's fast path sets the deadline on the
  in-kernel APIC, which this VM does not create; I expected the filter to see
  an unmarked write. Which kernel, and how was it observed? If the filter
  does see it, the mark could be dropped. Not blocking anything.
- **(CC, P1) What should "stuck" mean on the PC-shaped machine?** I propose
  a halt `rest` resolves resets `quiet`, so only a guest that runs without
  halting, printing or ringing is stuck. Steve's call if a guest that rests
  forever with no client should end the run some other way.
- **(CC) Toolchain:** the hook's zig 0.16.0 from PyPI works here; 48/48
  tests pass. Nothing needed.

- **(CC, item 7) Two of tcp.zig's eighteen are not the peer's to reach.**
  "a reopened window is announced again" is the guest's own window news,
  reached when gopher.zig stops reading a connection whose buffer fills,
  so it needs a request larger than the guest's receive buffer
  (`PEER_REQUEST=<file>` can send one). "a peer sends past the window" needs
  the same: the peer already ignores the guest's window, so a request bigger
  than it reaches it. The rest map to knobs: reset (`PEER_RESET_AT`, with
  `PEER_RESET_OFF` for the challenge ACK), vanish (`PEER_VANISH_AFTER`, for
  "a silent peer is given up on" and the RTO cap), flood (`PEER_FLOOD`, which
  needs more SYNs than gopher.zig's table has slots), a shut window
  (`PEER_SHUT_AFTER`/`PEER_SHUT_FOR_US`, for "a shut window is probed"),
  damage (`PEER_DAMAGE`), and loss with `PEER_MSS` split (`PEER_EAT=n` of a
  request segment, for "ahead"; with `WIRE_EAT` of the guest's ACK, for
  "from behind").

## Answers

*(The box answers here, on `interrupts`.)*
