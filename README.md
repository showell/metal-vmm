# metal-vmm

**Active on `master`, 2026-10-06.** A deterministic hypervisor of our own, on
KVM, for one kind of guest: [gopher-metal](https://github.com/showell/gopher-metal)'s
bare-metal kernels, the probes and the real server behind lynrummy.com. It is
a test machine, never a production one. The same guest with the same seed
gives the same run, byte for byte, and any input can be withheld or damaged to
a recipe. The long-term aim is an explorer like Antithesis's, steered by
[zig-coverage-sdk](https://github.com/showell/zig-coverage-sdk)'s properties
toward runs no run has reached yet; that explorer is not built.

- **Live work** is in [QUEUE.md](QUEUE.md), one queue for all four repos
  (zig-coverage-sdk, metal-vmm, gopher-metal, angry-gopher).
- **A cloud Claude session ("CC")**, which has zig and Python but no KVM or
  QEMU, reads [CLOUD_WORK.md](CLOUD_WORK.md) first.
- **Agents** read [CLAUDE.md](CLAUDE.md).
- **"The box"** is Steve's development droplet, where a local Claude works
  with him and KVM and QEMU are available. The guests boot only there.

Every knob is in [KNOBS.md](KNOBS.md); what the machine has found in the guest
and the application is in [docs/findings.md](docs/findings.md); reviews are in
[docs/reviews/](docs/reviews/).

## What runs where

**Anywhere with zig** (no KVM, no guest):

- `zig build test` — every model, the loader, the fuzz regressions, and the
  determinism rule (`src/determinism.zig`).
- `zig build fuzz -Dseeds=n` — every guest-facing model under a seeded stream
  of guest input (`src/fuzz_main.zig`); 1000 seeds by default.
- `./sweep_test.sh`, `./sweep_durable_test.sh` — `sweep.sh`'s verdicts against
  a fake machine; they need zig-coverage-sdk's `tools/report.py` (a sibling
  checkout, or `COVERAGE_SDK=<dir>`).
- `./sound.sh <image>` — is a disk image still a FAT filesystem; needs only
  `fsck.vfat`.

**Needs `/dev/kvm`**, a built `zig-out/bin/metal-vmm`, and gopher-metal's
kernels (`GUESTS`, by default `~/showell_repos/gopher-metal/probe`, built
there by `zig build kernels`; `gopher.elf` by `./port.sh && zig build gopher`):

| | also needs | what it asks |
|---|---|---|
| `zig build run -- <kernel.elf>` | | one run |
| `./check.sh` | QEMU, `mkfs.vfat`, `fsck.vfat` | is it right: the probes here and under QEMU, words and disks byte for byte |
| `./same.sh` | `mkfs.vfat` | is it reproducible: each probe twice here |
| `./site.sh` | QEMU, curl, the site volume | the real server, here and under QEMU |
| `./rest.sh` | the site volume | the PC-shaped machine against the microvm-shaped one |
| `./lossy.sh` | | which lost frames the guest survives |
| `./flaky.sh` | `mkfs.vfat`; the site volume for `gopher` | which refused disk requests it survives |
| `./sweep.sh` | the site volume, zig-coverage-sdk | a range of seeds, each a whole fault schedule |

"The site volume" is `SITE`, by default
`~/build/gopher-metal/probe/gopher/pristine.img`, staged by gopher-metal's
`probe/judge_gopher.py` (which needs a loop mount, and so sudo; the scripts
here only read it).

## A first run

On the box, with gopher-metal checked out beside this repo and its kernels
built:

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

The full command is `metal-vmm <kernel.elf> [disk.img] [command line] [path to
fetch]`; the scripts above show it in use.

## Why write one

**Because determinism is nearly free for this guest, and determinism is the
whole point.** The people who build deterministic hypervisors for a living
name four hard problems: every clock read has to return a computed time;
interrupts have to be delivered at an exact instruction, which the performance
counters get wrong about once in a trillion; concurrent cores interleave
arbitrarily; and input has to enter only where the hypervisor says.

This guest hands three of those over for nothing. Its clock is already a
parameter rather than something it reads. It takes **interrupts only at a
halt** (`sti; hlt`, and off again at once): on the microvm-shaped machine it
never halts at all, and on the PC-shaped one the instruction an interrupt is
taken at is always the one after that `hlt`. It is single-threaded, and
refuses to compile otherwise. Every byte it sees crosses one seam.

So a monitor that owns every input is ordinary code rather than a research
project, and once it owns every input, the same guest and the same
seed give the same run — which is what makes a bug reproducible, a fault
injectable, and a measurement exact.

The other reason: the devices this has to emulate are virtio-blk,
virtio-net and virtio-scsi, and the guest half of each was written next door.
**Implementing the host half of a protocol you know from the other side is the
shortest way into a layer**, and the host half is the emulator.

## Where it stands

As of 2026-10-06. Two machines: the **microvm-shaped** one (devices in an mmio
window, no interrupts; the one QEMU's `microvm` is compared with) and the
**PC-shaped** one (`TRANSPORT=pci`). "Checked against QEMU" means `check.sh`
or `site.sh`; everything else is checked by unit tests and by this machine's
own repeat runs.

| | |
|---|---|
| loading a PVH kernel | **works** — segments by physical address, entry from the `XEN_ELFNOTE_PHYS32_ENTRY` note; marked `rdtsc` and deadline writes rewritten in guest memory |
| starting the processor | **works** — 32-bit protected mode, flat segments, `%ebx` at a `hvm_start_info`, a CPUID without `RDRAND` |
| the memory map, COM1, the exit door | **works** — 0xF4, and the guest's code becomes ours |
| the clock | **works, and is ours** — the interval timer, the real-time clock and `rdtsc` all read one counter that only the guest's own questions advance |
| entropy | **works** — a seeded virtio-rng; the seed is the run's name |
| virtio-blk | **works**, checked against QEMU — one queue and a disk image, mapped private, written back only at the end |
| virtio-net and the peer | **works**, checked against QEMU — DHCP, and TCP clients that fetch what curl fetches; no tap device and no real network, deliberately |
| the real server as the guest | **works**, checked against QEMU — angry-gopher's own route table, twelve routes, pages identical to curl's |
| the PC-shaped machine | **works** (`TRANSPORT=pci`) — virtio-pci, MSI-X, a local APIC with a TSC-deadline timer; the server halts between frames, and `rest.sh` holds it to the microvm-shaped machine's pages. Only the paths gopher-metal walks are exercised by a guest |
| a virtio-scsi volume | **works**, not compared with QEMU (`VOLUME`, `scsi.zig`) — the second disk a droplet has; unit-tested against gopher-metal's driver's sequence, and used by `sweep.sh`'s durability sweep |
| faults on the wire | **works** — the guest's or the peer's nth frame lost or damaged, latency, lying frames (`mangle.zig`) |
| a peer that misbehaves | **works** — resets, vanishing, SYN floods, shut windows, pipelining, slow clients, many clients |
| faults on the disks | **works** — refused requests, bad sectors, rotten bytes, power cuts, torn writes, write caches that hold or lie (`cache.zig`), and the volume's own: failed synchronizes, latency, a volume that changes size, goes away or turns read-only |
| seeds and sweeps | **works** — `FAULT_SEED` names a whole schedule; `sweep.sh` runs a range, judging exit, page, coverage and volume soundness, or durability of a post |
| the guest's coverage | **works** — its zig-coverage-sdk lines read as printed, a table per run, JSONL for the SDK's report across runs |
| fuzzing the models | **works** — `zig build fuzz`; nothing may panic and each seed repeats |
| snapshots | **device side only** — every model's state saved and restored in place (`snapshot.zig`), tested; the vCPU half and branching runs from it are not built |
| the explorer | **not built** |

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
  is a triple fault three instructions later.
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
did, not of what the box was busy with — and the interval timer, the real-time
clock and the timestamp counter all report that one counter, which is why they
cannot disagree.

**The guest's calibration is exact.** It measures its own processor by counting
`rdtsc` ticks across a known number of interval-timer ticks. Both sides of that
division come from the same counter, so the answer is the rate `clock.zig`
chose — 2.5 GHz, to within the tick the PIT's own integer arithmetic rounds
away. It is not being lied to; it is being told.

**Waiting is nearly free.** A guest that waits half a second waits for the
counter to reach half a second, and the counter moves when the guest asks
questions. The `clock` probe — which waits for four separate real-time-clock
seconds-edges — takes 1.3 s here against 9.7 s under QEMU.

**And the wall clock is a decision.** The machine boots at noon on 2026-09-18,
every time, so the dates a guest writes into a filesystem are the same dates on
every run. `RTC_BOOTS_AT=unix` makes it another instant ([KNOBS.md](KNOBS.md)).

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

**Only a marked `rdtsc` is rewritten.** Two bytes is too short a pattern:
gopher.elf has `0F 31` pairs inside other instructions, and rewriting those
corrupts them (an invalid opcode just after "listening on port 80").
gopher-metal's `tsc.read` puts `mov $"mvmc", %ecx` (`B9 6D 76 6D 63`) before
its `rdtsc`, and only the `rdtsc` after that mark becomes a question.
Elsewhere the `mov` costs a register. An unmarked `rdtsc` reads the host's
counter.

## Interrupts, at a halt

`TRANSPORT=pci` is the machine a droplet is, as far as gopher-metal can tell:

- **a PCI bus** (`pci.zig`): a host bridge in slot 0, and the disk, the card,
  the entropy and the volume as modern virtio-pci functions, one memory BAR
  each with their four virtio windows and an MSI-X table. The devices behind
  them are the mmio window's own; only the registers in front differ. The
  guest asks a bus when there is one and never mixes the two, so on this
  machine the mmio window is empty.
- **a local APIC** (`apic.zig`): its registers, its timer in TSC-deadline,
  one-shot and periodic modes, and the vectors waiting and in service, taken
  by priority class as the task priority allows. KVM's own APIC would keep
  the host's time, so the vCPU has none in the kernel, and every interrupt is
  injected from here (`KVM_INTERRUPT`). The timer catches up to the machine's
  time whenever the guest can see it — a register, an MSR, a halt — so a
  deadline that passed while the guest ran has fired by the time it looks.
- **a halt is an event, not a wait.** At the guest's `hlt` the clock moves
  straight to the earlier of the timer's deadline and the next frame due on
  the wire; the wire is pumped (a frame delivered is an MSI-X message); the
  APIC's highest waiting vector is injected. The halt's length is computed,
  never waited, so a run is still a function of the guest alone.

**The deadline is a marked write too.** IA32_APIC_BASE comes here through an
MSR filter (`KVM_X86_SET_MSR_FILTER`), but on a host with the VMX preemption
timer, like the box, KVM's fast path takes IA32_TSC_DEADLINE before the
filter sees it. So gopher-metal marks that one `wrmsr` with
`mov $"mvmd", %esi`, and the loader makes it `out 0xE1, al`, answered from
the registers.

    ./rest.sh all     every route: the page the microvm-shaped machine
                      serves, the same run twice, and real rests

With a 5 ms wire each route halts a few times and takes timer and MSI-X
interrupts both. At 200 ms, `/` halts 361 times, 356 woken by the timer at
its 1 ms slice, and pays one retransmission timeout, as it should when the
round trip is longer than the table's least timeout.

## When a run ends

A run ends when the guest exits through the door, faults, is cut off by a
power-cut knob, or stops making progress:

- **Stuck.** On the microvm-shaped machine, a million exits with nothing
  printed and no doorbell rung stops the run and says where the guest is:

  ```
  metal-vmm: the guest has printed nothing and rung no doorbell for 1000000 exits
             (101126 ms of its own time). It is here:
           rip 00000000001c6f7e  rbx 000000000137de30  rsp 000000000137d4d0
           possibly called from, innermost first:
             00000000001c59a4     ← stream.pump
             00000000001c6ef0     ← gopher.streamTurn
  ```

  There are no frame pointers, so the callers are a guess: any word on the
  stack pointing into the kernel's own executable sections is probably a
  return address. Feed them to `addr2line -f -C -e <kernel.elf>`.
- **Idle.** On the PC-shaped machine each halt starts that count again, and a
  guest that rests with nothing to do ends after `PATIENCE_S` seconds of its
  own time (600 by default) with nothing printed and no doorbell rung. An idle
  end is a server's normal end: the disk keeps what the run wrote and the
  client's lines are printed. A guest that is stuck or faults leaves the image
  as it was.

The error stream then says what the run cost (exits and guest time), what
each fault knob did, and the coverage line below.

## QEMU is the oracle

`./check.sh` runs the same guest on the same disk twice — once here, once under
QEMU — and requires the same words out of the serial port, the same exit code,
and **the same disk image afterwards, byte for byte**. A device model that
answers correctly and writes the wrong sector would pass everything else.

```
PASS block       same words, same verdict (109 ms here, 121 ms under QEMU, software CPU)
PASS vfat        same words, same verdict (118 ms here, 145 ms under QEMU, software CPU)
PASS net         same words, same verdict (132 ms here, 322 ms under QEMU, software CPU)
PASS http        same words, same verdict (133 ms here, 1020 ms under QEMU, software CPU)
PASS stdhttp     same words, same verdict (142 ms here, 1025 ms under QEMU, software CPU)
PASS rng         same words, same verdict (109 ms here, 130 ms under QEMU, software CPU)
PASS clock       same words, same verdict (849 ms here, 4156 ms under QEMU, software CPU)
PASS vfat/fat32  same words, same verdict (126 ms here, 154 ms under QEMU, software CPU)
PASS append/fat32 same words, same verdict (6531 ms here, 4587 ms under QEMU, software CPU)
```

- **The last two are FAT32** (prod's data is FAT32): a fresh volume made by
  `mkfs.vfat`, written by gopher-metal's own probes, and judged by `fsck.vfat`
  as well as by QEMU. `append` stamps its files with the wall clock, which
  differs between the two sides by design, so its clock line is left out and
  its two disks are each judged by `fsck.vfat` rather than compared;
  `vfat/fat32` is the byte-for-byte one.
- **`rng` and `clock` are compared by verdict** rather than by words, for
  opposite reasons: one is random on purpose, and the other is a measurement
  of the machine it ran on, which is a different machine on each side on
  purpose.
- **The HTTP ones compare two clients**: the peer written here, and curl
  through QEMU's forwarded port, both fetching `/probe`. For `stdhttp` that is
  **zig's own `std.http.Server`, unmodified, answering a TCP client written
  here, on a machine with no operating system, under a hypervisor written
  here.**
- **`net` is the strictest**: the address, mask, router, DNS and server the
  guest's DHCP lease names must match what QEMU's own DHCP server hands out.
- The block probe's list of device slots is left out: QEMU fills its window
  from the top and has a random-number device too.

**On timings.** `check.sh` runs QEMU without `-accel kvm`, so QEMU emulates
the processor in software: a device access costs it a function call and costs
this program a full exit through KVM, which on the box is itself nested in a
virtual machine. Measured 2026-10-01, `vfat` (44,193 disk requests, about
221,000 exits) takes 1.7-2.0 s under QEMU's software processor, 3.3-3.4 s
under QEMU with `-accel kvm`, and 4.15 s here; `clock`, mostly computation,
takes 8.3 s, 4.6 s and 1.2 s. A `ReleaseFast` build runs `vfat` in the same
4 s as the debug one, so `zig build`'s default stays debug.

## The other oracle: yesterday's run

`./same.sh` asks the question QEMU cannot answer about itself — whether a run
**repeats**. Same guest twice, and the words, the exit code and the disk all
have to match byte for byte. It can ask that of a guest that writes because the
image is mapped private: every run starts from the bytes the file holds, and
the sectors the guest changed go back into it at the end of the run and not
before.

```
SAME    clock       10 lines, verdict 0 (726 ms, then 701 ms)
SAME    rng         6 lines, verdict 0 (104 ms, then 106 ms)
...
SAME    stdhttp     8 lines, verdict 0 (135 ms, then 154 ms)
        tsc_hz 2500014511
        unix 1789732802
        civil 2026-9-18 12:0:2
        first draw: 35555648620a99592de40231899298e5
```

Those last four lines are the point. `tsc_hz` is what the guest measured about
its own processor, `unix` and `civil` are what it read off the clock chip, the
draw is sixteen bytes it will mint a session token out of — and all of them are
the same on every run on every day.

## The real server

`gopher.elf` is **angry-gopher's own route table**, compiled from its own
source for a machine with no operating system — its data on a FAT16 volume, its
clocks from its own hardware, `std.http.Server` over a TCP stack it brought
with it.

```
$ ./site.sh
GET /
  here        200 13668 bytes, exit 0  (1628 ms)
  under QEMU  200 13668 bytes, exit 0  (7215 ms)
  ours  tcp: 0 timeouts sent something again, 0 window probes, ...
  qemu  tcp: 0 timeouts sent something again, 0 window probes, ...
the same page, and the same connection, both ways
```

The guest's own closing counters are compared too, because **that is where a
difference between the two hypervisors shows up before it shows up in the
page**. `./site.sh all` runs the twelve cookie-free routes of
`judge_gopher.py`'s list through both machines, a 26 KB PDF and the redirects
among them.

## Faults, seeds and coverage

A hypervisor that owns every input can choose to withhold one, and a
deterministic one can do it to a recipe. Every fault is an environment knob;
**[KNOBS.md](KNOBS.md) lists them all**, grouped as the machine, the calendar,
the wire, the peer, the boot disk, the volume and the seeds.

- **Exhaustive maps.** `./lossy.sh` loses the guest's first frame, then its
  second, one run per frame; `./flaky.sh` does the same with disk requests.
  Because every run repeats, these are maps of every case, not samples.
- **Seeds.** `FAULT_SEED=n` turns many knobs at once, so "seed 4711" names
  one exact run, and the run prints the knobs that repeat it without the seed.
  `./sweep.sh [first] [last]` runs a range on the PC-shaped machine, a fresh
  copy of the volume each, and fails a seed whose exit is not the unhurt run's,
  that broke a coverage property, that left a volume `sound.sh` rejects, or
  whose page differs when nothing it did excuses that. With `POST`, it judges
  instead whether a post the client was told succeeded (303) is on the volume
  after a power cut. It ends with the failing seeds as the knobs that repeat
  them.
- **Nothing the guest does kills this program.** `zig build fuzz` drives every
  model a guest can reach (the PCI ports at any offset and width, every BAR,
  the mmio window, the APIC and its MSRs, virtqueues laid out any way at all,
  hostile block and SCSI requests, frames, COM1, the PIT and the RTC, the
  peer's clients) from a seeded stream, without a processor. Nothing may
  panic, and each seed must be the same run twice. `zig build test` runs the
  first 64 seeds and every seed that ever found something (`fuzz.zig`,
  `regressions`).

### What the guest says it reached

A gopher-metal kernel built `-Dcoverage` prints zig-coverage-sdk's JSONL on
COM1 behind `coverage: ` (gopher-metal's COVERAGE.md). The serial port here
reads those lines as they are printed (`coverage.zig`) and keeps a table of
every property: its kind, how often it was seen true and false, and the exit
and virtual time of the first of each. `COVERAGE_OUT=<file>` keeps the lines
out of stdout and appends them to that file as plain JSONL; without it stdout
is the guest's bytes exactly. A run that printed any ends with:

    metal-vmm: coverage: 7 of 23 properties reached (6 hold, 0 broken), from 412 lines over 1 boots

Each run's lines in a `COVERAGE_OUT` file follow a line naming it
(`{"metal_vmm_run":{"seed":4711,"knobs":"..."}}`). The SDK's
`tools/report.py a.jsonl [b.jsonl ...] [--floor f]` reads any number of such
files as one table: every property's verdict, how many runs reached it and
which first, each numeric comparison's edge and which run came nearest it, and
the properties only one run ever reached. `sweep.sh` ends with it.

## What it found

Sweeps of lost frames and refused disk writes found defects in gopher-metal and
angry-gopher, among them a DHCP client that never retransmitted and one
refused write that left a volume that could never mount again. Most are fixed
since and one is open; [docs/findings.md](docs/findings.md) has each, found →
fixed, with commits.

## Reading it

- `src/kvm.zig` — Linux's side: the ioctl numbers and the structures,
  transcribed from `/usr/include/linux/kvm.h`, with their sizes asserted at
  compile time. An ioctl number carries its argument's size, so a structure a
  byte too long does not mis-parse; it fails with `EINVAL` and says nothing.
- `src/clock.zig` — the machine's time: one counter, and the three devices
  that report it. **Read this one first if you read only one.**
- `src/entropy.zig` — the seeded generator and the device that hands it out.
- `src/main.zig` — the processor's starting state, the serial port, the exit
  door, and the loop that serves them. Beside it: `src/loader.zig` (the ELF,
  and the marked instructions rewritten), `src/processor.zig` (CPUID and the
  MSRs this program answers), `src/halt.zig` (what wakes a halted guest),
  `src/reports.zig` (what a run says at its end) and `src/cost.zig` (what it
  cost, in exits and guest time).
- **Devices**: `src/virtio.zig` (the transport and the block device),
  `src/disk.zig` (the image, mapped private, and the sectors the run changed),
  `src/cache.zig` (a disk write cache, `DISK_CACHE`), `src/scsi.zig` (the
  virtio-scsi volume), `src/net.zig` (the network card).
- **The PC-shaped machine**: `src/pci.zig` (the bus), `src/virtio_pci.zig` (a
  virtio device as a function on it), `src/msix.zig`, `src/apic.zig`.
- **The other end of the wire**: `src/peer.zig` (DHCP, its clients, how many
  and how they misbehave), `src/client.zig` (one client as a TCP),
  `src/response.zig` (where an HTTP answer ends), `src/frames.zig` (the
  frames), `src/mangle.zig` (frames that lie).
- **Faults**: `src/faults.zig` (what this machine may do to its guest),
  `src/settings.zig` (the knobs, into the faults), `src/knobs.zig` (every
  knob, and what a seed draws).
- **Watching**: `src/coverage.zig` (the guest's coverage lines, one run's and
  many runs').
- **Checks on this program**: `src/fuzz.zig` and `src/fuzz_main.zig` (the
  models under seeded guest input), `src/determinism.zig` (no host time or
  entropy anywhere in `src/`, checked), `src/snapshot.zig` (every model's
  state, saved and restored in place).
