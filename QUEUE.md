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

1. **Review the `interrupts` branch** (`git log master..interrupts`): pci.zig,
   apic.zig, the halt in main.zig's `rest`, the MSR filter, the deadline
   rewrite. Read it against the specs and against gopher-metal's driver,
   adversarially: where does the model differ from a PC in a way the guest
   could reach, and where could a run stop being a function of the guest
   alone? Write `docs/reviews/REVIEW-interrupts.md`. Fix nothing in it; each
   finding becomes an item.
2. **A `FakeGuest` over PCI.** As `virtio.zig`'s does for mmio: drive
   `pci.Bus` through ports 0xCF8/0xCFC the way gopher-metal's `pci.zig` and
   `virtio.zig` do (scan, capabilities, common config at each field's width,
   reset and its read-back, feature negotiation, a queue set up with its
   vector, a doorbell, a completion), then through MSI-X to an `apic.Apic`
   and out of `next()`. One test per step of the driver's sequence. This is
   the transport's integration test, without a vCPU.
3. **`rest`'s decision, pulled out and tested.** Given the APIC, the wire's
   next due frame and the clock: the time to move to, and the vector to take,
   or "nothing can wake it". Cases: a vector already pending (no time
   passes); a deadline before the next frame and after it; a frame due but
   undeliverable (no buffer), which must not wake it; a deadline whose tick
   falls between nanoseconds (`clock.nsAt` rounds up); an APIC not enabled.
4. **MSI-X as PCI 3.0 §6.8.2 has it.** Today it is one table entry, and any
   queue vector but 0 reads back NO_VECTOR. Make it a table of N entries,
   with the PBA's bits, the function mask and per-entry masks, and the
   config-change vector (`msix_config`). gopher-metal uses entry 0 for every
   queue, so behavior there must not change (item 2's tests hold it).
5. **The APIC, closer to the SDM.** The TPR's effect on what is delivered
   (the processor priority), several vectors pending across priority classes,
   EOI with more waiting, a deadline in the past firing at once, a deadline
   of zero disarming, and the timer's one-shot and periodic modes (initial
   and current count) for a guest that is not gopher-metal. Unit tests for
   each, from the SDM.
6. **PCI configuration space, closer to the spec.** BAR sizing (write all
   ones, read the size mask back), the command register gating memory
   decoding and bus mastering (a device not allowed to master the bus may not
   complete a request), header type and multi-function bits, and reads of
   registers that do not exist. Tests from PCI 3.0.

## Proposed

*(CC adds items here, one line each on why.)*

## Questions

*(For the box or Steve. Take the next item; do not wait.)*

## Answers

*(The box answers here, on `interrupts`.)*
