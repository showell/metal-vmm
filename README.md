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
| virtio-blk | next |
| virtio-net | after that |
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

## Reading it

- `src/kvm.zig` — Linux's side: the ioctl numbers and the structures,
  transcribed from `/usr/include/linux/kvm.h`, with their sizes asserted at
  compile time. An ioctl number carries its argument's size, so a structure a
  byte too long does not mis-parse; it fails with `EINVAL` and says nothing.
- `src/main.zig` — the loader, the processor's starting state, the two
  devices, and the loop that serves them.

`zig build test` checks the parts that need no processor: the ELF loader, the
note parsing, and the devices' answers.
