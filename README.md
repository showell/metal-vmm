# metal-vmm

A virtual machine monitor of our own, aimed at one kind of guest: a small
freestanding kernel that polls, runs on one core, and takes its clock as an
argument. [gopher-metal](https://github.com/showell/gopher-metal)'s probes and
its chat server are exactly that.

    zig build
    zig build run -- ../gopher-metal/probe/rng.elf

```
gopher-metal rng probe
  virtio-rng: no   RDRAND: yes
  first draw: 1441cad88d3d62dbb490e88a7d50f865
  over 4 KB: 16306 of 32768 bits set, commonest byte appears 28 times
PASS
```

That output came out of a guest running on a processor this program asked
Linux for, in memory this program allocated, printing through a serial port
this program implements, and exiting through a door this program answers.
QEMU is not involved.

## Why write one

**Because determinism is nearly free for this guest, and determinism is the
whole point.** The people who build deterministic hypervisors for a living
name four hard problems: every clock read has to return a computed time;
interrupts have to be delivered at an exact instruction, which the performance
counters get wrong about once in a trillion; concurrent cores interleave
arbitrarily; and input has to enter only where the hypervisor says.

This guest hands three of those over for nothing. Its clock is already a
parameter rather than something it reads. It takes **no interrupts at all** —
it polls. It is single-threaded, and refuses to compile otherwise. Every byte
it sees crosses one seam.

So a monitor that owns every input is a few hundred lines rather than a
research project, and once it owns every input, the same guest and the same
seed give the same run — which is what makes a bug reproducible, a fault
injectable, and a measurement exact.

The other reason: the devices this has to emulate are virtio-blk and
virtio-net, and the guest half of both was written next door. **Implementing
the host half of a protocol you know from the other side is the shortest way
into a layer**, and the host half is the emulator.

## Where it stands

| | |
|---|---|
| loading a PVH kernel | **works** — segments by physical address, entry from the `XEN_ELFNOTE_PHYS32_ENTRY` note |
| starting the processor | **works** — 32-bit protected mode, flat segments, `%ebx` at a `hvm_start_info` |
| the memory map | **works** — the guest sizes its heaps from what it is told |
| the serial port | **works** — COM1, including the line-status bit the guest spins on |
| the exit door | **works** — 0xF4, and the guest's code becomes ours |
| absent devices | **works** — reads answer zero, which is how a guest discovers nothing is there |
| virtio-blk | **works** — the transport, one queue, and a disk image; judged against QEMU's own device |
| virtio-net | **works** — two queues, and a peer at the other end of the wire |
| TCP from the peer | **works** — it connects to the guest, fetches, and gets what curl gets |
| the clock | **works, and is ours** — the interval timer, the real-time clock and `rdtsc` all read one counter that only the guest's own questions advance |
| a run that repeats | **works** — same guest, same words, same disk, same measured processor speed, every time |
| entropy that repeats | **works** — a seeded virtio-rng, and a processor with no `RDRAND` to go behind its back |
| a disk that does not have to be a file | next: copy-on-write in memory, so a run can be replayed |
| fault injection | last, and the reason for the rest |

A boot costs about 100 ms, most of it spent zeroing the guest's `.bss`. QEMU's
`microvm` boots the same kernel in about 130. **Speed is not the argument** —
the argument is that nothing in that 100 ms came from anywhere but here.

## What a guest needs from us, exactly

- **32-bit protected mode, paging off, interrupts off**, with `%ebx` holding a
  `hvm_start_info` and `%eip` at the address its own ELF note names. It builds
  long mode itself from there, which is why so little of this program is
  processor setup.
- **A CPUID.** A fresh vCPU has none, and a guest that cannot see long mode in
  CPUID cannot turn it on: `EFER.LME` faults, and with no interrupt table that
  is a triple fault three instructions later. This was the first bug.
- **A memory map it can believe**, because it sizes every heap from it.
- **COM1's line-status register**, or it spins forever waiting to print.
- **An interval timer that advances**, because the guest measures its own
  processor's speed by counting timestamp ticks across a known number of the
  timer's, and refuses to boot if the answer is not a plausible clock rate.
- **A real-time clock**, if it is asked to say what day it is — the MC146818
  at 0x70/0x71, in whichever of its four register formats it is asked for.
- **Entropy**, because it mints session tokens with it and will not invent one
  out of a clock. It takes that from virtio-rng and from `RDRAND`, mixed — and
  **this machine deliberately has no `RDRAND`**, because one unrepeatable
  source in the mix makes every draw unrepeatable. The bits are cleared out of
  the CPUID the vCPU is given, and the guest, which looks for its sources
  rather than assuming them, uses the device.

## Time is measured in questions

**Every exit advances one counter by a fixed amount, and nothing else advances
it.** The host's clock is never read. So a run is a function of what the guest
did, not of what this box was busy with — and the interval timer, the real-time
clock and the timestamp counter all report that one counter, which is why they
cannot disagree.

Three things fall out of that, and two of them are not about determinism at
all.

**The guest's calibration is exact.** It measures its own processor by counting
`rdtsc` ticks across a known number of interval-timer ticks. Both sides of that
division now come from the same counter, so the answer is the rate `clock.zig`
chose — 2.5 GHz, to within the tick the PIT's own integer arithmetic rounds
away. It is not being lied to; it is being told.

**Waiting is nearly free.** A guest that waits half a second waits for the
counter to reach half a second, and the counter moves when the guest asks
questions. The `clock` probe — which waits for four separate real-time-clock
seconds-edges — takes 1.3 s here against 9.7 s under QEMU.

**And the wall clock is a decision.** The machine boots at noon on 2026-09-18,
every time, so the dates a guest writes into a filesystem are the same dates on
every run.

### `rdtsc` does not exit, so the loader makes it one

This is the trick the whole thing rests on. `rdtsc` is a register read: no trap,
no hypervisor, three cycles. KVM offers userspace no way to intercept it — you
can set the counter (`KVM_SET_MSRS`) and pin its frequency
(`KVM_SET_TSC_KHZ`), and that gets you to within the few hundred host cycles
between the VM entry and the instruction, which is a different number every
run.

So the loader rewrites it. `rdtsc` is two bytes, `0F 31`; `out 0xE0, al` is
also two bytes, `E6 E0`. Every timestamp read in the guest's text becomes an
ordinary port write that arrives here, and this program puts the answer in
EDX:EAX exactly as the instruction would have.

**The file on disk is untouched** — the substitution happens in the copy in
guest memory, so QEMU still runs the same bytes and stays an honest oracle.

Two bytes is a short pattern to search for, and a `0F 31` inside some other
instruction's operand would corrupt the guest silently. Counted across nine of
gopher-metal's kernels, the number of these pairs in the loadable segment
equals the number of `rdtsc` instructions a disassembler finds, every time: 34
in `clock`, 12 in `stdhttp`, 2 in `block`, none in `rng`.

## Reading it

- `src/kvm.zig` — Linux's side: the ioctl numbers and the structures,
  transcribed from `/usr/include/linux/kvm.h`, with their sizes asserted at
  compile time. An ioctl number carries its argument's size, so a structure a
  byte too long does not mis-parse; it fails with `EINVAL` and says nothing.
- `src/clock.zig` — the machine's time: one counter, and the three devices
  that report it. **Read this one first if you read only one.**
- `src/entropy.zig` — the seeded generator and the device that hands it out.
  **The seed is the run's name.**
- `src/virtio.zig` — the transport the devices sit on, and the block device.
- `src/net.zig` — the network card: two queues, and the asymmetry between them.
- `src/peer.zig` — the machine at the other end of the wire: DHCP, and a TCP
  client that fetches one thing. **There is no tap device and no real
  network**, deliberately — a host's network is an input this program does not
  control, which is the one thing a deterministic machine cannot have.
- `src/main.zig` — the loader, the processor's starting state, the serial port,
  the exit door, and the loop that serves them.

`zig build test` checks the parts that need no processor: the ELF loader, the
note parsing, the devices' answers, and a fake guest that drives the block
device through the rings exactly as the real driver does.

## QEMU is the oracle

`./check.sh` runs the same guest on the same disk twice — once here, once under
QEMU — and requires the same words out of the serial port, the same exit code,
and **the same disk image afterwards, byte for byte**. A device model that
answers correctly and writes the wrong sector would pass everything else.

```
PASS block       same words, same verdict (104 ms here, 128 ms under QEMU)
PASS fat16       same words, same verdict (163 ms here, 150 ms under QEMU)
PASS fat16write  same words, same verdict (878 ms here, 495 ms under QEMU)
PASS vfat        same words, same verdict (4247 ms here, 1998 ms under QEMU)
PASS net         same words, same verdict (118 ms here, 135 ms under QEMU)
PASS http        same words, same verdict (123 ms here, 1023 ms under QEMU)
PASS stdhttp     same words, same verdict (128 ms here, 1025 ms under QEMU)
PASS rng         same words, same verdict (98 ms here, 126 ms under QEMU)
PASS clock       same words, same verdict (1341 ms here, 8333 ms under QEMU)
```

`rng` and `clock` are compared by verdict rather than by words, for opposite
reasons: one is random on purpose, and the other is a measurement of the
machine it ran on, which is a different machine on each side on purpose.

The HTTP ones compare two clients: the peer written here, and curl through
QEMU's forwarded port. Both fetch `/probe` and both have to come back with the
same status and the same body — which, for `stdhttp`, means **zig's own
`std.http.Server`, unmodified, answering a TCP client written here, on a
machine with no operating system, under a hypervisor written here.**

The network one is the strongest of them: the guest asks for a lease and prints
the address, mask, router, DNS and server it was given, and every one of those
numbers has to match what QEMU's own DHCP server hands out.

It earned its keep immediately: our first output had an invisible `0x01` at the
head of it. The guest's serial init sets the divisor latch and writes the baud
rate to the data port, and a model that does not know that bit prints the baud
rate as a character. Nothing else would have found it — the words all looked
right.

The block probe prints which slots hold devices, and that genuinely differs:
QEMU fills its window from the top and has a random-number device too. Those
lines are left out of the comparison and everything else is not.

On the heavier probes we are slower than QEMU (4.1 s against 1.9 on `vfat`),
which is honest: every register access here — and now every clock read too — is
a full exit into this program, where QEMU has spent years not doing that. That
cost is the kernel's, not ours: a `ReleaseFast` build of this program runs
`vfat` in the same 4 s as the debug one, so `zig build`'s default stays debug.

## The other oracle: yesterday's run

`./same.sh` asks the question QEMU cannot answer about itself — whether a run
**repeats**. Same guest twice, and the words, the exit code and the disk all
have to match byte for byte.

```
SAME    clock       10 lines, verdict 0 (1375 ms, then 1390 ms)
SAME    rng          6 lines, verdict 0 (105 ms, then 113 ms)
SAME    block       10 lines, verdict 0 (106 ms, then 119 ms)
SAME    fat16        7 lines, verdict 0 (170 ms, then 167 ms)
SAME    fat16write   7 lines, verdict 0 (1010 ms, then 968 ms)
SAME    vfat         6 lines, verdict 0 (3706 ms, then 3652 ms)
SAME    net          9 lines, verdict 0 (112 ms, then 105 ms)
SAME    http         7 lines, verdict 0 (127 ms, then 129 ms)
SAME    stdhttp      8 lines, verdict 0 (161 ms, then 159 ms)
        tsc_hz 2500014511
        unix 1789732802
        civil 2026-9-18 12:0:2
        first draw: 35555648620a99592de40231899298e5
```

Those last four lines are the point. `tsc_hz` is what the guest measured about
its own processor, `unix` and `civil` are what it read off the clock chip, the
draw is sixteen bytes it will mint a session token out of — and all of them are
the same on every run on every day.

The `clock` probe is the one that makes this a real question, and it had never
booted here before this step because it needs a real-time clock. It calibrates
its timestamp counter against the interval timer, checks that its monotonic
clock never goes backwards over a thousand readings, checks the calibrated rate
against a **second, independent device** by timing the gap between two
real-time-clock seconds-edges, reads the chip in all four of its register
formats and requires them to decode to one moment, and anchors a wall clock to
an edge rather than to the moment it was told.
