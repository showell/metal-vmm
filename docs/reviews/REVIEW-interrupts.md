# Review: the `interrupts` branch

QUEUE.md item 1, by the cloud session, 2026-10-05. The branch at `c402556`:
`git log master..interrupts`, read against PCI 3.0 (§3.2.2.3.2, §6.8.2),
virtio 1.2 (§4.1), the Intel SDM vol. 3 ch. 11, and gopher-metal's driver on
its branch `antithesis-sdk` (`2a6658f`: `src/pci.zig`, `src/virtio.zig`,
`src/interrupts.zig`, `src/reset.zig`).

The question was where the model differs from a PC in a way a guest can
reach, and where a run could stop being a function of the guest alone.
Every finding marked **confirmed** was run, against this branch, in a
throwaway test that is not part of the commit. Nothing is fixed here; each
finding is an item under "Proposed" in QUEUE.md.

## What holds up

- **The halt is computed, never waited.** `rest` moves `machine.time.ns` and
  nothing else; no host clock is read on any new path. `clock.nsAt` rounds
  up and `Clock.ticks` rounds down, so the clock lands on the first
  nanosecond at which `rdtsc` answers at least the deadline, and the one
  before it answers less. The timer cannot fire a nanosecond early or a tick
  late.
- **A frame that is due but has no buffer does not wake the guest.** `rest`
  only counts a frame due strictly after now, and the wire is FIFO, so a
  stuck head cannot hide a later frame that could be delivered: none can be.
  Every exit pumps the wire before the switch, so at a halt nothing
  deliverable is still waiting.
- **`TRANSPORT` unset is unchanged.** The bus, the APIC's MMIO window, the
  `.hlt` path, the CPUID bits and the MSR filter are all gated on `pc` or
  `machine.bus`. One thing is not gated: the loader rewrites marked deadline
  `wrmsr`s in every kernel. gopher-metal only reaches that `wrmsr` after
  `interrupts.arm`, which needs a card on PCI, so the microvm-shaped machine
  never executes it, and check.sh cannot see the difference.
- **The file on disk is never changed.** Both rewrites act on guest memory
  after the copy, as before.
- **MSI-X does what the guest relies on.** A message held while the entry or
  the function is masked waits in the pending bit and goes out on unmasking.
  The capability chain is laid out as virtio 1.2 §4.1.4 has it, and
  gopher-metal's parser finds all four windows and the MSI-X capability in
  it. `notify_off` is the queue index with a multiplier of 4, which the
  doorbell arithmetic matches. Memory decoding off (command bit 1) answers
  all ones, as §6.2.2 has it.
- **The APIC's choices are SDM-correct where gopher-metal walks.** The highest
  vector goes first, which is the SDM's priority order. Leaving TSC-deadline
  mode disarms the deadline, and a deadline written outside that mode is
  ignored and reads zero (§11.5.4.1). With one vector in service and the
  guest's handler running with interrupts off, nothing nests.
- **The MSR filter is minimal.** It covers two MSRs, both directions. An
  index the filter sends here that `apic.zig` does not model is a #GP, as on
  a processor without it.

## Findings

Severity is what the failure costs. Likelihood is how likely gopher-metal
is to reach it today, and separately how likely any other guest (or a future
explorer driving inputs) is to reach it.

### High

**H1. An unaligned access to the configuration data port panics this
program.** *Confirmed.* `Bus.in` and `Bus.out` shift by
`(port - 0xCFC) * 8 + i * 8` in a `u5`. A 4-byte access at 0xCFD or 0xCFE, or
a 2-byte one at 0xCFF, overflows it. In Debug, the default build, that is
`panic: integer overflow` at `pci.zig:350`, and in a release build it is
undefined behavior. Any guest instruction `inl $0xCFD` reaches it.
- *Failure*: the VMM dies on a guest's input. That is the worst kind of
  failure for an explorer, which exists to feed a guest odd inputs.
- *Likelihood*: nil for gopher-metal, whose `pci.zig` only uses aligned `outl`
  and `inl` and an `outw` at `0xCFC + (reg & 2)`. Certain for any guest that
  does this.
- *Fix shape*: do the byte arithmetic in `u6` or `u32`, and treat bytes past
  0xCFF as undecoded: a read gets 0xFF and a write is dropped. A port-level
  test at every offset and width, 0xCF8 through 0xCFF.

**H2. The deadline timer only runs at a halt.** *Confirmed.*
`Apic.tick` is called from `rest` and nowhere else. While the guest runs, a
deadline can pass without firing. IA32_TSC_DEADLINE keeps reading the old
value, where the SDM says the MSR reads zero once the timer has fired
(§11.5.4.1). The vector is not pending either. If the guest writes a new
deadline before it halts, the expiry is lost. On a PC the vector would sit
in the IRR, and the next `sti; hlt` would return at once.
- *Failure*: gopher-metal's `rest` writes a fresh deadline before every halt.
  After an MSI-X wake, the old deadline (up to 1 ms later) is still armed.
  If serving the frame takes longer than what is left of that millisecond,
  a PC delivers 0x41 at the next halt and the loop goes round again. Here
  the new deadline overwrites the old one and the guest sleeps a full slice.
  So the PC-shaped machine wakes less often than a droplet. TCP timers are
  looked at later than they would be there, and a path the droplet takes
  (a wake with nothing to do) is never taken here.
- *Likelihood*: high for gopher-metal under load. Any response that costs
  more than the rest of a slice in exits reaches it, at 100 µs of guest time
  per exit.
- *Fix shape*: call `lapic.tick(machine.time.ticks())` on every exit, after
  `time.asked()`, beside `pump`. It is as deterministic as the clock it
  reads. Have `readMsr(msr_tsc_deadline)` answer what the timer says now.
  Tests from §11.5.4.1: a deadline passed while running reads zero, its
  vector is pending, and a write after expiry does not cancel it.

### Medium

**M1. A halt with interrupts off is treated as a rest.** `rest` never looks
at `run.if_flag`. After `cli; hlt`, a PC stops until an NMI, SMI or INIT.
Here the clock jumps to the next deadline or frame and the wire is pumped. A
vector goes into service, and the guest resumes past the `hlt`, which a PC
never does.
- *Failure*: a guest's last words (a panic loop, a `cli; hlt` that means
  "stop") are followed by more of its code running, at a later time, with
  frames delivered into its rings.
- *Likelihood*: low for gopher-metal. `serial.exitQemu` stops the machine at
  port 0xF4 before its `hlt`. `reset.now` reaches its `cli; hlt` loop only if
  the triple fault fails to stop the machine, and here it does stop it.
  Certain for a guest that halts with interrupts off on purpose.
- *Fix shape*: `if (run.if_flag == 0)`, stop as the microvm-shaped machine
  does, saying so. Item 3's extracted decision can take the flag as an
  input.

**M2. A vector is put in service before it is delivered.** `rest` calls
`lapic.next()`, which moves the vector from pending to in service, and only
then asks whether KVM can inject it. If it cannot, the vector waits in
`machine.waiting` and the guest resumes. In gopher-metal the guest resumes
at the `cli` after the `hlt`, so the window does not open. At the next
`sti; hlt` the halt exits to `rest` again, where `next()` answers null
because the vector is still "in service". The clock then runs out every
deadline and frame, and `rest` reports nothing can wake it. The run ends.
- *Likelihood*: low. It needs `ready_for_interrupt_injection == 0` at a halt
  after `sti`, which pc_vs_microvm.sh has not met: KVM clears the STI shadow when it
  skips the `hlt`. But the path is untested, and when it is reached it ends
  the run.
- *Fix shape*: the APIC answers what it would deliver without taking it
  (`peek`), and takes it in the same step as the `KVM_INTERRUPT` that
  delivers it, at the halt or at `irq_window_open`. A test drives the
  not-ready branch.

**M3. An access wider than a register is cut to its first register.**
*Confirmed.* `commonWrite` ignores `len`. An 8-byte store to `queue_desc`
writes the low half and leaves the high half as it was; the same goes for
`queue_driver` and `queue_device`. In the MSI-X table, an 8-byte store at
entry offset 8 sets Message Data and leaves Vector Control alone, so the
entry stays masked. PCI 3.0 §6.8.2 allows aligned QWORD access to the table.
virtio 1.2 §4.1.3.1 lets a driver split a 64-bit field, but does not
require it.
- *Failure*: a driver that unmasks with one QWORD store never gets its
  interrupt, and a halt waiting for one sleeps until the timer.
- *Likelihood*: nil for gopher-metal, whose `write64` and `routeToProcessor`
  use 32-bit stores; Linux's do too. Reachable by any guest that uses
  `movq`. With 512 MiB of RAM, a ring's high half is always 0 on a first
  write.
- *Fix shape*: split every BAR access into its aligned dwords before
  dispatching. One test per field, at every width the specs allow. This is
  part of item 4 for the table.

**M4. Byte writes to MSI-X Message Control replace the whole word, and its
read-only bits are writable.** *Confirmed.* `configWrite` stores
`(value & mask) >> 16` without merging. A byte write to 0x8A (the low byte)
therefore clears Enable and Function Mask, which live in byte 0x8B. A write
of 0x87FF reads back a table size of 2047, where PCI 3.0 §6.8.2.3 makes
bits 10:0 read-only.
- *Failure*: a guest that sets the mask with a byte write to 0x8B is fine,
  but one that writes 0x8A turns MSI-X off. A guest that reads the table
  size after writing it believes it has 2048 entries and writes beyond the
  one modeled.
- *Likelihood*: nil for gopher-metal, which writes the word with the size
  bits it read. Low for others.
- *Fix shape*: merge under the mask and keep only bits 15:14 writable. Part
  of item 4.

**M5. A `queue_select` past the last queue aliases the last queue.**
*Confirmed.* `commonRead` and `commonWrite` clamp `queue_sel` to
`queues.len - 1`. Selecting queue 5 reads a `queue_size` of 256, and a write
of `queue_size` changes queue 1's. virtio 1.2 §4.1.4.3.2: "The device MUST
present a 0 in queue_size if the virtqueue corresponding to the current
queue_select is unavailable." `num_queues` is also 2 for every device,
including the block and entropy devices, which serve one queue.
- *Failure*: a driver that probes queues until `queue_size` reads 0, or sets
  up every queue `num_queues` names, configures a queue that does not
  exist. Its writes then rewrite a real queue's rings.
- *Likelihood*: nil for gopher-metal, which selects only its own queues.
  Medium for other drivers.
- *Fix shape*: a selector past the device's own count reads zero everywhere
  and swallows writes. Each device says how many queues it serves.

### Low

**L1. A reset keeps a message held while masked.** Status 0 resets the
vectors but not `msix_pending` (nor the ISR, as on mmio before this
branch). A message held at the reset is sent when the next driver unmasks
entry 0: a wake nobody asked for. gopher-metal resets only at boot, before
anything is sent. Part of item 4.

**L2. The ISR is set when the queue's message is sent.** `completed` sets
`interrupt_status` before it looks at MSI-X. virtio 1.2 §4.1.5.4 uses the
ISR for queue interrupts only when MSI-X is off. Harmless to gopher-metal,
which does not read the ISR once MSI-X is on. Part of item 4.

**L3. Only the low byte of an MSI message's data is read.** Any address in
the APIC's page reaches our APIC, which is right while its ID is 0. The
delivery mode (data bits 10:8) and the trigger mode are ignored, so a
message asking for an NMI, SMI, INIT or ExtINT arrives as a fixed interrupt
on whatever vector its low byte names. The destination mode (address bit 2)
is ignored too. Part of item 4.

**L4. The APIC differs from the SDM off gopher-metal's path.** These are
the ones not already in item 5:
- Clearing SVR bit 8 should set every LVT mask (§11.4.7.2); here the masks
  are left as they were.
- IA32_APIC_BASE accepts bit 10 (x2APIC) from a guest told by CPUID that
  there is none, which the SDM makes a #GP. Clearing bit 11 should reset the
  APIC's state.
- A deadline that passes while the timer's LVT is masked should still
  disarm the timer, with no interrupt. Here it stays armed and fires on
  unmasking.
- IRR, ISR and TMR (0x100-0x270) read as zero.

**L5. Port 0xCF9 is swallowed.** On the PC-shaped machine the reset control
register falls inside `pci.isPort` and does nothing. gopher-metal's
`reset.now` tries 0xCF9 first, then the keyboard controller, then a triple
fault. Here only the triple fault acts, and it ends the run as before. The
outcome is the same, but the method that works differs from QEMU's `pc`
and from a droplet. This only matters once a reset is something this
machine survives.

### Determinism

**D1. The guest can still reach the host's time, without `rdtsc`.** This is
older than this branch, and it matters more now that an MSR filter exists
to close it. KVM answers these, each from the host's counter:
- `rdtscp`;
- `rdmsr` of IA32_TSC (0x10), IA32_TSC_ADJUST (0x3B), MPERF and APERF
  (0xE7, 0xE8);
- the kvmclock MSRs (0x4B564D00 and up, and 0x11 and 0x12), which the KVM
  CPUID leaves at 0x40000000 advertise.

An unmarked `rdtsc` reads the host's counter too, as the README says.
- *Likelihood*: nil for gopher-metal, which uses none of these. Certain for
  a guest that does, and the explorer's runs stop being a function of the
  guest the moment one does.
- *Fix shape*: put these MSRs behind the filter, answered from `clock.zig`
  or refused with a #GP. Strip the KVM leaves and RDTSCP (leaf 0x80000001,
  EDX bit 27) from CPUID, on both machines. The microvm part changes what
  check.sh's guests see, so it is the box's to merge.

**D2. Ports 0xE0 and 0xE1 answer anyone.** An `out` to 0xE1 the loader did
not write is taken as a deadline write, with whatever ECX, EDX and EAX hold.
With ECX = 0x1B, it rewrites IA32_APIC_BASE. On a PC nothing decodes either
port. The run stays deterministic, but a guest can reach the APIC through a
door the loader opened for someone else.
- *Fix shape*: the loader records the address of each instruction it
  rewrote, and an exit on 0xE0 or 0xE1 from any other RIP is an ordinary
  port write to nothing.

**D3. A kernel without the deadline mark runs with no timer, silently.**
`load` discards `rewriteDeadlineWrites`' count. A gopher.elf built before
gopher-metal's `1f742bb` writes IA32_TSC_DEADLINE with a bare `wrmsr`. The
branch says KVM's fast path takes that write before the filter, and with
no APIC in the kernel it goes nowhere. Every halt then waits for a frame,
and the first idle one ends the run as "nothing could wake it". The run is
deterministic, but it is the wrong machine.
- *Fix shape*: report the count, as `clock_reads` is reported. On
  `TRANSPORT=pci`, say so when a kernel that starts the APIC has no marks.
  See the question in QUEUE.md about the fast path itself.

### Patience

**P1. A resting guest is called stuck.** A halt and an interrupt taken are
not "progress", so `quiet` keeps counting through them. An idle gopher-metal
rests every millisecond of its own time, for a handful of exits per rest
(the `rdtsc`, the deadline, the `hlt`, the EOI, and its polls). After
`patience` (1,000,000) exits, roughly two to three minutes of guest time
with no client, the run ends as `GuestStuck`. pc_vs_microvm.sh's runs are short
enough not to reach it. A soak, or an explorer that leaves the server idle
between requests, will.
- *Fix shape*: on the PC-shaped machine a halt is not a hang. "Stuck" there
  is a guest that runs without halting, printing or ringing. So reset
  `quiet` at a halt that `rest` resolves. The microvm-shaped machine keeps
  its rule.

### Aside, not this branch's

`clock.per_question_ns` is 100,000 ns, but its comment reasons about ten
microseconds ("Ten microseconds puts the guest's PIT calibration at a few
thousand exits…"). One of the two is stale.
