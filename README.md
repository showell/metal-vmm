# metal-vmm

**PARKED 2026-09-18, all green.** Ten milestones in one day: a guest boots,
mounts a disk, takes a lease, serves HTTP, keeps its own clock, draws its own
entropy, and can be lied to on purpose about any of it. Nine probes agree with
QEMU and repeat themselves exactly, and angry-gopher's real server runs on it
and serves pages byte-identical to curl's. What it found is in
**Being unhelpful on purpose** below — one defect in the application, three in
the bare-metal layer, one of which bricks a volume. Read that section first if
you are picking this up again.

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
| a disk the run cannot spoil | **works** — mapped private, the changed sectors written back at the end and only then |
| fault injection on the wire | **works** — lose the guest's nth frame, or one in n, and watch its own timers deal with it |
| fault injection on the disk | **works** — refuse the guest's nth request, or one in n, and see what it says |
| the real server as the guest | **works** — angry-gopher's own route table, serving its own site, page identical to curl's |

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
- `src/disk.zig` — the image, mapped private, and the record of which sectors
  the run changed. A run reads the image it started with; a run that crashes
  leaves it alone.
- `src/faults.zig` — what this machine is allowed to do to its guest.
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

## Being unhelpful on purpose

A hypervisor that owns every input can choose to withhold one, and a
deterministic one can do it to a recipe. The wire will eat what the guest
sends — a numbered frame (`WIRE_EAT=3`, or `3,9`), or one frame in n
(`WIRE_LOSS=4`) — and it will hold what comes back (`WIRE_LATENCY_US=250`).

**Losing frame number n is a better knob than a loss rate.** A rate explores
randomly; a number explores exhaustively, and the table is a map of which
frames this guest can survive losing. `./lossy.sh` draws it, one run per frame:

```
eaten     sent   exit  guest ms  verdict, and what the client got
nothing   7      0     177       PASS — 200 "hello from no Linux"
#1        1      1     164       FAIL: no DHCP lease, so there is no address to listen on
#2        2      1     165       FAIL: no DHCP lease, so there is no address to listen on
#3        8      0     377       PASS — 200 "hello from no Linux" (+200 ms: a retransmission timeout)
#4        7      0     177       PASS — 200 "hello from no Linux"
#5        9      0     377       PASS — 200 "hello from no Linux" (+200 ms: a retransmission timeout)
#6        8      0     377       PASS — 200 "hello from no Linux" (+200 ms: a retransmission timeout)
#7        7      0     177       PASS — 200 "hello from no Linux"
```

Read the last column: it is **the guest's own clock**, and the 200 ms is the
guest's own retransmission timeout — `min_rto_ns` in its `tcp.zig` — happening
in front of you. The rows that cost nothing are frames whose loss the next one
covers.

The first two rows are a real defect in the guest, found by this table rather
than argued for: **gopher-metal's `dhcp.acquire` sends its DISCOVER once and
never retransmits.** One lost frame and the machine has no address. Its TCP
handles loss; its DHCP does not.

Running the same sweep against the `stdhttp` guest gives the same shape with a
1,000 ms cost instead of 200 — the same stack with a different measured
round-trip time, and so a different timer.

**The wire does not lose what the peer sends**, only what the guest sends. The
peer is a test fixture with no timers of its own, so a frame lost on the way in
would only hang the run, which would say nothing about the guest.

### And the disk can refuse

Same idea one layer over: `DISK_REFUSE=3` answers the guest's third request
with the I/O error a real disk gives when it cannot do the work, and the
guest's own `fat16.zig` turns that into `ReadFailed`. `./flaky.sh` sweeps it,
and because every run is reproducible the sweep can be **exhaustive** rather
than a sample:

```
$ ./flaky.sh fat16 all
fat16 makes 709 disk requests; an untouched run: exit 0 — PASS
refusing each of the first 709, one run each:
   701 runs  (#8..#708)  exit 1 — FAIL: the file would not read
     3 runs  (#5..#7)    exit 1 — FAIL: EFI/BOOT/BOOTX64.EFI would not open
     2 runs  (#1..#2)    exit 1 — FAIL: the partition table would not read
     1 runs  (#709)      exit 1 — FAIL: the lookup failed
     1 runs  (#4)        exit 1 — FAIL: the root directory would not list
     1 runs  (#3)        exit 1 — FAIL: the volume would not mount
```

709 runs, 1 minute 46. **Every one of them failed cleanly, and every one named
the right layer** — the partition table for the first two, the volume for the
third, the directory for the fourth, the open for the next three, the read for
the rest. No hang, no wrong answer, and no run that carried on as though
nothing had happened. That is a statement about a guest's error paths that you
can only make by trying all of them.

## The real server

Probes were the right subject for building a machine. `gopher.elf` is the
reason it exists: **angry-gopher's own route table**, compiled from its own
source for a machine with no operating system — its data on a FAT16 volume, its
clocks from its own hardware, `std.http.Server` over a TCP stack it brought
with it. A 24 MB kernel that is, on Linux, a web application.

```
$ ./site.sh
GET /
  here        200 13668 bytes, exit 0  (1628 ms)
  under QEMU  200 13668 bytes, exit 0  (7215 ms)
  ours  tcp: 0 timeouts sent something again, 0 window probes, ...
  qemu  tcp: 0 timeouts sent something again, 0 window probes, ...
the same page, and the same connection, both ways
```

13,668 bytes of the site's index page, fetched by the TCP client in `peer.zig`,
identical to what curl gets from the same kernel under QEMU. The guest's own
closing counters are compared too, because **that is where a difference between
the two hypervisors shows up before it shows up in the page** — and on the
first run it did.

And with the wire eating one frame per run:

```
  eat #none   exit=0   13668 bytes  same page  retransmits: 0   1220 ms
  eat #1      exit=1       0 bytes  no lease   (dhcp does not retransmit)
  eat #2      exit=1       0 bytes  no lease   (dhcp does not retransmit)
  eat #3      exit=0   13668 bytes  same page  retransmits: 1   1420 ms   ← a 200 ms timeout
  eat #4      exit=0   13668 bytes  same page  retransmits: 0   1220 ms
  eat #5..#16 exit=0   13668 bytes  same page  retransmits: 1   ~1235 ms  ← dupacks, ~15 ms
```

The last rows are the guest's **fast retransmit** — `dupacks_before_resend = 3`
in its own `tcp.zig`, a path that until now had never run. Three duplicate
acknowledgements from the peer and it resends immediately instead of waiting
out the timer, which is the difference between the 200 ms row and the 15 ms
ones. (Its counter prints both kinds as "timeouts", which flatters the timer.)

### Twelve routes, and 141 refused reads

`./site.sh all` runs every cookie-free route in `judge_gopher.py`'s list
through both machines. Twelve routes, twenty-four boots: same status, same
bytes, same connection, every time — including a 26 KB PDF and the redirects.

`./flaky.sh gopher all` is the one that pays for everything. The real server
makes **141 disk requests** to boot, back-fill its chat sidecars and answer
`GET /`. Refusing each in turn, one boot per request, takes seven minutes:

```
gopher makes 141 disk requests; an untouched run: exit 0 — PASS — client got: 200, 13668 bytes
   129 runs  (#4..#132)    exit 1   FAIL: the FAT could not be held in memory
     3 runs  (#135..#137)  exit 0   PASS — client got: 200, 13668 bytes
     2 runs  (#140..#141)  exit 0   PASS — client got: 200, 7799 bytes
     2 runs  (#138..#139)  exit 0   PASS — client got: 200, 7801 bytes
     2 runs  (#133..#134)  exit 124  said nothing about it
     2 runs  (#1..#2)      exit 1   FAIL: the disk has no GPT partition to serve from
     1 runs  (#3..#3)      exit 1   FAIL: the first partition is not FAT16
```

The 129 loud failures are right: the FAT is read at boot, and a machine that
cannot read it should say so and stop. Two rows are not right.

**`exit 124` was a hang, and it turned out not to be a deadlock at all.**
Refusing request #133 leaves the machine answering `GET /` correctly and then
never exiting. The watchdog below names the loop, and the diff against a clean
run names the cause in one line:

```
-   serving until stopped
+   serving 1 request(s), as gopher-metal.conf says
```

**Request #133 is the read of `gopher-metal.conf`.** `readConfig` says
`readFileAlloc(...) catch return conf`, so a disk that refuses the read is
indistinguishable from a volume with no config file on it — and the default
for `requests` is *forever*. The machine served its one request and then waited
for the next one, exactly as instructed. Every malformed *line* in that file is
a loud `serial.fail`; the failed *read* is silent. Careful about content,
careless about access.

That is the same defect as the one below, one layer up: `io.zig` turns the I/O
error into `FileNotFound`, and `catch return conf` then cannot tell "there is no
config" from "I could not read the config".

### A hang is a number

A machine whose time is its guest's curiosity can count a hang exactly, so it
does: so many exits with nothing printed and no doorbell rung and the run stops
and says where the guest is.

```
metal-vmm: the guest has printed nothing and rung no doorbell for 1000000 exits
           (101126 ms of its own time). It is here:
         rip 00000000001c6f7e  rbx 000000000137de30  rsp 000000000137d4d0
         possibly called from, innermost first:
           00000000001c59a4     ← stream.pump
           00000000001c6ef0     ← gopher.streamTurn
           ...
```

There are no frame pointers, so that is a guess: any word on the stack pointing
into the kernel's own **executable sections** is probably a return address. The
sections matter — a guest's stack lives in its `.bss`, so a filter that takes
the whole loaded image calls every stack word a caller. Feed the addresses to
`addr2line -f -C -e <kernel.elf>`.

**And the short pages are a 200.** Refusing #138 gets the client 7,801 bytes
ending in:

```html
<h1>Home unavailable</h1>
<p>pages/home.txt could not be rendered: <strong>FileNotFound</strong>.</p>
```

The file is there. The disk refused to read it. `io.zig` says
`v.open(path) catch return Error.FileNotFound` in eight places, which collapses
a read error, a corrupt FAT and a genuinely missing file into one answer — so a
machine with a failing disk reports deleted files, and anything that reacts to a
missing file by recreating or skipping it will do that to a file that is
perfectly fine. The status stays 200, so a cache would store "Home unavailable"
as the site's home page.

Neither of those is a bug in this hypervisor. Both are what it was built to
find.

### The write path, which is the half that matters

A `GET` only reads. `PEER_REQUEST=<file>` sends whole request bytes instead of
a path, so the peer can post a chat message with a signed session cookie — and
**one chat message is 82 disk writes**. `DISK_WRITES_ONLY=1` makes
`DISK_REFUSE=n` mean the nth *write*, because a guest reads a hundred sectors
for every one it saves and counting all of them is a blunt way to aim.

Refusing each of those 82 writes in turn:

| | |
|---|---|
| writes #1–#22 | the route answers **`WriteFailed`**, the host closes the connection, the client gets nothing at all, and the message is not on the volume |
| writes #24–#82 | the client is told **303 See Other** and the message *is* on the volume |

The second row is the one worth checking rather than believing, because "the
client was told it worked" is exactly where silent loss hides. So each of those
volumes was **booted a second time** and asked to read the conversation back,
and asked for `/chat/recent`, which is rendered from the sidecar rather than
the transcript:

```
clean: the transcript reads back as 116 bytes, message present: 1
  write #24  told the client 303; reading back: 116 bytes, message: 1, same as clean: yes
  ... #30 #40 #50 #60 #70 #82, all the same
  Recent: 3373 bytes, same as clean, every time
```

**angry-gopher does not lie about a save.** When it says 303 the message is
there and both views agree with a clean run; when it cannot save, it says
`WriteFailed` and does not claim otherwise. That is a negative result, and it
is the one worth having.

The weak spot is what the *client* sees on that failure: the connection closes
with no response at all, so a browser shows a network error rather than a page.
The host contract says a failed request is logged and the connection closed —
`server.zig` does the same on Linux — so this is a design decision to revisit
rather than a defect, but it is a decision with no error page behind it.

### The multi-file path, where the client was told the wrong thing

Creating a chat topic writes several files. `./zig-out/bin/metal-vmm` with
`DISK_WRITES_ONLY=1 DISK_REFUSE=n` refuses the nth of its **83 writes**, one
run each, and every one of those volumes is then **booted again** and asked
whether the topic is listed and whether it opens:

```
  56 runs  route:ok           client:200   listed:1  topic page:200    #24..#83
  17 runs  route:WriteFailed  client:none  listed:0  topic page:200    #1..#19
   4 runs  route:ok           client:200   listed:0  topic page:none   #50, #59, #67, #80
   3 runs  route:WriteFailed  client:none  listed:1  topic page:200    #20, #22, #23
```

**The four-run row is a bad one, and all four refused the same thing: a write
to sector 2180 — the FAT's second copy.** The client is told `200
{"conv":"1_2","sid":"metal-talk"}`. The next boot says:

```
  fat cache: FatsDisagree
FAIL: the FAT could not be held in memory
```

Not "that topic is missing" — **the volume will not mount at all.** The site is
down. And the error was reported to nobody.

The swallowing is one line of the application, `zig-server/src/chat.zig`:

```zig
// Announce the new topic where the partner already watches (best-effort).
_ = store.appendMessage(io, alloc, bus, …, note, "") catch {};
```

The topic itself was created. The *announcement* of it into the general
conversation is best-effort, so its failure is discarded — and on this machine
that append is the one that touches the FAT. `catch {}` on a write is the same
line on Linux, where it silently drops the announcement instead; the volume
damage is this filesystem's mirroring, but **the ignored error is the
application's, on both.**

The three-run row is the mirror image: the write failed after the topic was
durable, so the client got no response at all for something that did happen. A
user who retries gets a duplicate.

### One refused write to the mirror, and the volume never mounts again

The same sector keeps turning up. Three more paths, swept the same way:

| | writes | what happens |
|---|---|---|
| a reaction | 7 | every failure reported as `WriteFailed`, client gets nothing — **honest** |
| an image upload | 22 | #1–#5 recover and answer 200 with a working image; #6–#22 answer the client a real **500** — the only path here that does |
| a new topic | 83 | the four `catch {}` runs above |

But underneath all three is one thing, and it is not the application's:

```
  new_topic  refuse write #2   (sector 2180): next boot WILL NOT MOUNT
  new_topic  refuse write #50  (sector 2180): next boot WILL NOT MOUNT
  react      refuse write #5   (sector 2180): next boot WILL NOT MOUNT
  upload     refuse write #2   (sector 2180): next boot mounts
```

Sector 2180 is the FAT's second copy. `fatSet` writes the cached sector to
every copy in turn; if the second write fails, the first has already landed and
**nothing puts it back**. `cacheFat` then refuses to mount a volume whose
copies disagree — deliberately, so that no tool silently "repairs" a volume
someone else has an opinion about. Those two reasonable decisions meet here:

**one failed write to the mirror leaves a volume that will never mount again,
and there is no repair path.**

The upload row is why the rule is exact rather than statistical. A refused
mirror write is permanent **unless something flushes that sector again
afterwards** — the upload does, later in the same request, and the volume
survives. Which has an unpleasant corollary: propagating the error honestly
*aborts* the request, so nothing flushes again, so **correct error handling
makes the damage certain**. The reaction path does everything right and loses
the volume; the upload path is saved by carrying on.

### The bookmark that eats your bookmarks

`chat_state.zig` is documented best-effort throughout — "a failed write just
loses the bookmark for that visit" — and for a bookmark that is a fair trade.
Four of its five swallowed errors are exactly that. The fifth is not:

```zig
pub fn setSessionPinned(…) void {
    const existing = readPinnedFile(io, alloc, uid, conv_key) catch "";
    const cur = parsePinned(alloc, existing) catch return;
    …                       // rebuild the set with sid added or removed
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body.items }) catch {};
```

**A failed *read* of the pinned file becomes an empty pinned set, and then the
file is overwritten from it.** Pin one session while that read fails and every
other pin the user had is gone — silently, with the client told 204. It is the
same shape as everything else in this list: an error treated as "there is
nothing there".

Sweeping the 218 requests a pin makes, 25 of them told the client **204 while
the volume lost the bytes a clean pin leaves behind**. That is indirect
evidence — this machine has no way to read one file out of a FAT16 volume and
the page does not render the group — so the code above is the finding and the
sweep is corroboration. The fix is one line: tell "no such file", which
legitimately means no pins, apart from every other error, which does not.

### "It answered" is a weaker question than "is it sound"

Every sweep so far asked what the client was told and whether the next boot
worked. `./sound.sh <image>` asks a third thing, by borrowing Linux's `fsck`
for a filesystem this machine has no fsck of its own for. Refusing each of the
upload's 22 writes and checking the volume afterwards:

```
before any upload: 48 files, 64/32167 clusters
after a clean one:  51 files, 67/32167 clusters

  #1..#4    client:200   Reclaimed 1 unused cluster (2048 bytes)
  #5        client:200   Orphaned long file name part "upload-bytes"
  #7, #17   client:500   FATs differ but appear to be intact
  #8..#13   client:500   Reclaimed 1 unused cluster (2048 bytes)
  #14, #15  client:500   Orphaned long file name part "ds" / "general.uploads"
  #20..#22  client:500   Orphaned long file name part "…173edb.png"
```

Three kinds of litter, and **the client was told 200 for the first five of
them**:

- **a leaked cluster** — marked allocated in the FAT, referenced by nothing.
  Every failed upload costs 2 KB that never comes back;
- **an orphaned long file name** — a directory entry written across several
  slots with no commit point, so a failure leaves the name without the entry
  behind it;
- **FATs that differ** — the mirror defect above, seen from outside.

None of this is exotic: FAT16 has no journal, so an interrupted operation
leaves work half done and an fsck is how it gets tidied. The point is the
second half of that sentence. **A reported write failure is not a crash** —
the code knows the write failed and could free the cluster it just allocated —
and **this machine has no fsck**. On Linux the same application sits on a
journalling filesystem that a boot will check. On bare metal it sits on this.

### Why one chat message is eighty-two writes

`DISK_TRACE=1` prints every request the guest makes. One message:

```
368 requests: 286 reads, 82 writes
  writes:   58  directory + data
            12  FAT, first copy
            12  FAT, second copy
  reads:   157  directory + data
           125  FAT, second copy
```

**The FAT writes are two sectors, written twenty-four times.** Every cluster
allocation flushes the whole cached FAT sector to *every copy* immediately
(`fatSet`, "in every copy of the FAT"), so twelve allocations cost
twenty-four writes, and a chat message allocates in several files at once — the
transcript, its sidecars, the per-user cursor. The other 58 are those files'
contents and their directory entries.

The 125 reads of the FAT's second copy are the mount checking that the copies
agree, sector by sector, before it caches the first — which is what makes the
defect above fatal rather than invisible.

### The pitfall that cost a retransmission

The first run of the real server reported **1 timeout** where curl through QEMU
reported 0, and the cause was ours: 30 of 51 frames on the way to the guest had
nowhere to go. A guest emptying a whole HTTP response into one doorbell has not
polled for a while, so its receive buffers are all in our hands, and the card
was **dropping** frames that found no buffer free.

There is no congestion on this wire. A frame that vanishes here is one this
program invented, and the guest pays a retransmission timeout for it. A frame
with nowhere to go now **waits on the wire** and goes in at the next exit, of
which there are ten thousand a second.

## The other oracle: yesterday's run

`./same.sh` asks the question QEMU cannot answer about itself — whether a run
**repeats**. Same guest twice, and the words, the exit code and the disk all
have to match byte for byte. It can ask that of a guest that writes because the
image is mapped private: every run starts from the bytes the file holds, and
the sectors the guest changed go back into it at the end of the run and not
before.

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
