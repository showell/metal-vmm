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
| the interval timer | **works** — enough of the i8254 for the guest to measure its own clock |
| TCP from the peer | **works** — it connects to the guest, fetches, and gets what curl gets |
| determinism | next, and the reason for all of it |
| determinism | the point of all of it: a virtual clock, a seeded generator, device answers at chosen moments |
| fault injection and replay | last, and the reason for the rest |

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
- **An interval timer that advances.** The guest measures its own processor's
  speed by counting its timestamp ticks across a known number of the timer's,
  and refuses to boot if the answer is not a plausible clock rate. That timer
  is the **one input this program does not yet own** — it advances off the
  host's clock, so two runs disagree about how fast the guest's processor is.
  That is exactly what the next step fixes.

## Reading it

- `src/kvm.zig` — Linux's side: the ioctl numbers and the structures,
  transcribed from `/usr/include/linux/kvm.h`, with their sizes asserted at
  compile time. An ioctl number carries its argument's size, so a structure a
  byte too long does not mis-parse; it fails with `EINVAL` and says nothing.
- `src/virtio.zig` — the transport both devices sit on, and the block device.
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
PASS block       same words, same verdict (105 ms here, 143 ms under QEMU)
PASS fat16       same words, same verdict (134 ms here, 157 ms under QEMU)
PASS fat16write  same words, same verdict (580 ms here, 564 ms under QEMU)
PASS vfat        same words, same verdict (2281 ms here, 1956 ms under QEMU)
PASS net         same words, same verdict (100 ms here, 129 ms under QEMU)
PASS http        same words, same verdict (230 ms here, 1025 ms under QEMU)
PASS stdhttp     same words, same verdict (235 ms here, 1029 ms under QEMU)
PASS rng         same words, same verdict (129 ms here, 135 ms under QEMU)
```

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

On the heavier probes we are somewhat slower than QEMU (2.3 s against 2.0 on
`vfat`), which is honest: every register access here is a full exit into this
program, where QEMU has spent years not doing that.
