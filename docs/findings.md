# What metal-vmm found

A hypervisor that owns every input can withhold one, and a deterministic one
can do it to a recipe and repeat it. This is what that found in the guest
(gopher-metal's kernel) and in the application it runs (angry-gopher's route
table), and what became of each.

**Status, 2026-10-06.** The sweeps below ran in September 2026, on the
microvm-shaped machine, against the kernels of the day. Fixes were confirmed
by reading the code and its history on 2026-10-06; **none of the sweeps has
been re-run since its fix**, so the tables are what was found, not what the
current kernel does. Commits are in the repo named.

| found | where | now |
|---|---|---|
| DHCP sent DISCOVER once and never asked again | gopher-metal `src/dhcp.zig` | **fixed** (`f0f66a9`): RFC 2131 retransmission, 4 s doubling to 64 s |
| a refused read of `gopher-metal.conf` reads as "no config", and `requests` defaults to forever | gopher-metal `probe/gopher.zig`, `readConfig` | **open**: `readFileAlloc(...) catch return conf` still takes any error for an absent file |
| every open failure became `FileNotFound` | gopher-metal `src/io.zig` (the port of angry-gopher's) | **fixed** (`0b36067`): a failed read is `ReadFailed` |
| a failed topic announcement discarded with `catch {}`, after which the volume would not mount | angry-gopher `zig-server/src/chat.zig` | **fixed** (`298c0871`): `try` |
| one refused write to the FAT's second copy, and the volume never mounts again | gopher-metal `src/fat16.zig`, `cacheFat` | **fixed** (`5f08fc5`): copies that differ are brought into line with the first at mount |
| a failed read of the pinned file overwrites every pin | angry-gopher `zig-server/src/chat_state.zig`, `setSessionPinned` | **fixed** (`298c0871`): a failed read leaves the pins alone |
| reported write failures leave leaked clusters and orphaned long names | gopher-metal `src/fat16.zig` | **partly addressed**, not re-swept: a failed allocation gives back what it took; orphaned long names are tombstoned before an entry is written after them |
| a failed write closes the connection with no response | angry-gopher's host contract | **a design decision**, not rechecked |

Two more were in this program, and are fixed here: a serial port that did not
know the divisor latch, and a card that dropped frames it had no buffer for
(both below).

## The wire

The wire eats the guest's nth frame (`WIRE_EAT`, [KNOBS.md](../KNOBS.md)),
and `lossy.sh` runs it once per frame. From the `http` probe:

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

The guest-ms column is **the guest's own clock**, and the 200 ms is the
guest's own retransmission timeout (`min_rto_ns` in its `tcp.zig`) happening
in front of you. The rows that cost nothing are frames whose loss the next one
covers. The same sweep against `stdhttp` gives the same shape with a 1,000 ms
cost: the same stack with a different measured round-trip time.

**Found:** the first two rows. `dhcp.acquire` sent its DISCOVER once and
never retransmitted, so one lost frame left the machine with no address. Its
TCP handled loss; its DHCP did not. **Fixed** in gopher-metal `f0f66a9`.

Against the real server (`site.sh`'s kernel), one frame eaten per run:

```
  eat #none   exit=0   13668 bytes  same page  retransmits: 0   1220 ms
  eat #1      exit=1       0 bytes  no lease   (dhcp does not retransmit)
  eat #2      exit=1       0 bytes  no lease   (dhcp does not retransmit)
  eat #3      exit=0   13668 bytes  same page  retransmits: 1   1420 ms   ← a 200 ms timeout
  eat #4      exit=0   13668 bytes  same page  retransmits: 0   1220 ms
  eat #5..#16 exit=0   13668 bytes  same page  retransmits: 1   ~1235 ms  ← dupacks, ~15 ms
```

The last rows are the guest's **fast retransmit** (`dupacks_before_resend = 3`
in its `tcp.zig`), a path that had never run before: three duplicate
acknowledgements and it resends at once instead of waiting out the timer. Its
counter prints both kinds as "timeouts", which flatters the timer.

## The disk, refused one request at a time

`DISK_REFUSE=n` answers the guest's nth request with an I/O error, and
`flaky.sh` sweeps it. Because every run repeats, the sweep is **exhaustive**:

```
$ ./flaky.sh vfat all
vfat makes 173 disk requests; an untouched run: exit 0 — PASS
refusing each of the first 173, one run each:
   144 runs  (#4..#147)  exit 1 — FAIL: a write failed
    13 runs  (#148..#168)  exit 1 — FAIL: a path would not resolve
    10 runs  (#151..#170)  exit 1 — FAIL: a file would not read
     2 runs  (#2..#3)  exit 1 — FAIL: the volume would not mount
     2 runs  (#171..#172)  exit 1 — FAIL: auth/damian would not resolve
     1 runs  (#173..#173)  exit 1 — FAIL: the listing failed
     1 runs  (#1..#1)  exit 0 — PASS
```

173 runs, 21 seconds, on a fresh FAT16 volume. Every refusal past the first
failed cleanly and named its layer. No hang, no wrong answer, and no run that
carried on as though nothing had happened. The one PASS is #1, the GPT header:
`vfat` reads any failure to find a partition table as "no table" and mounts
sector 0, which on this bare volume is right; on a partitioned disk the same
fallback fails the mount, a layer later and under the volume's name.

The real server makes **141 disk requests** to boot, back-fill its chat
sidecars and answer `GET /`. `./flaky.sh gopher all`, seven minutes:

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
cannot read it should say so and stop. Two rows were not right.

### `exit 124`: a refused config read, and a server that never stops

Refusing #133 left the machine answering `GET /` correctly and then never
exiting. The hang report (README, "When a run ends") named the loop, and a
diff against a clean run named the cause in one line:

```
-   serving until stopped
+   serving 1 request(s), as gopher-metal.conf says
```

**Request #133 is the read of `gopher-metal.conf`.** `readConfig` says
`readFileAlloc(...) catch return conf`, so a disk that refuses the read is
indistinguishable from a volume with no config file, and the default for
`requests` is forever. Every malformed line in that file is a loud
`serial.fail`; the failed read is silent.

**Open.** `io.zig` now tells a failed read (`ReadFailed`) from an absent file
(`FileNotFound`), but `readConfig` in gopher-metal's `probe/gopher.zig` still
catches every error alike.

### The short pages are a 200

Refusing #138 got the client 7,801 bytes ending in:

```html
<h1>Home unavailable</h1>
<p>pages/home.txt could not be rendered: <strong>FileNotFound</strong>.</p>
```

The file was there; the disk refused to read it. `io.zig` said
`v.open(path) catch return Error.FileNotFound` in eight places, collapsing a
read error, a corrupt FAT and a missing file into one answer, so a machine
with a failing disk reported deleted files, and anything that reacts to a
missing file by recreating it would do that to a file that is fine. The status
stayed 200, so a cache would store "Home unavailable" as the home page.

**Fixed** in gopher-metal `0b36067`: NotFound is `FileNotFound`, any other
failure `ReadFailed`. That the page is still a 200 under a refused read is not
rechecked.

## The write path

A `GET` only reads. `PEER_REQUEST=<file>` sends whole request bytes, so the
peer can post a chat message with a signed session cookie, and
`DISK_WRITES_ONLY=1` makes `DISK_REFUSE=n` mean the nth write. One chat
message was **82 disk writes**. Refusing each in turn:

| | |
|---|---|
| writes #1–#22 | the route answers **`WriteFailed`**, the host closes the connection, the client gets nothing, and the message is not on the volume |
| writes #24–#82 | the client is told **303 See Other** and the message *is* on the volume |

Each of the 303 volumes was booted a second time and asked to read the
conversation back, and for `/chat/recent`, which is rendered from the sidecar
rather than the transcript:

```
clean: the transcript reads back as 116 bytes, message present: 1
  write #24  told the client 303; reading back: 116 bytes, message: 1, same as clean: yes
  ... #30 #40 #50 #60 #70 #82, all the same
  Recent: 3373 bytes, same as clean, every time
```

**angry-gopher does not lie about a save.** When it says 303 the message is
there and both views agree with a clean run; when it cannot save, it says
`WriteFailed`. A negative result, and the one worth having. (Write caches and
power cuts came later: `DISK_CACHE`, `VOLUME_CACHE` and `sweep.sh`'s
durability sweep ask the same question of a disk that holds its writes.)

**A design decision, not rechecked:** on that failure the connection closes
with no response, so a browser shows a network error rather than a page. The
host contract says a failed request is logged and the connection closed, and
`server.zig` does the same on Linux.

### A new topic: the client told 200, and the volume that would not mount

Creating a chat topic made **83 writes**. Refusing each, then booting each
volume again and asking whether the topic is listed and opens:

```
  56 runs  route:ok           client:200   listed:1  topic page:200    #24..#83
  17 runs  route:WriteFailed  client:none  listed:0  topic page:200    #1..#19
   4 runs  route:ok           client:200   listed:0  topic page:none   #50, #59, #67, #80
   3 runs  route:WriteFailed  client:none  listed:1  topic page:200    #20, #22, #23
```

The four-run row all refused one thing: a write to sector 2180, the FAT's
second copy. The client was told `200 {"conv":"1_2","sid":"metal-talk"}`, and
the next boot said:

```
  fat cache: FatsDisagree
FAIL: the FAT could not be held in memory
```

The volume would not mount at all, and the error was reported to nobody. The
swallowing was one line of `zig-server/src/chat.zig`:

```zig
// Announce the new topic where the partner already watches (best-effort).
_ = store.appendMessage(io, alloc, bus, …, note, "") catch {};
```

The topic was created; its announcement into the general conversation was
best-effort, and on this machine that append was the one that touched the FAT.
**Fixed** in angry-gopher `298c0871`: the append is `try`.

The three-run row is the mirror image: the write failed after the topic was
durable, so the client got no response for something that happened, and a
user who retries gets a duplicate. Not rechecked.

### One refused write to the mirror, and the volume never mounts again

Sector 2180 turned up under three paths:

| | writes | what happened |
|---|---|---|
| a reaction | 7 | every failure reported as `WriteFailed`, client gets nothing |
| an image upload | 22 | #1–#5 recover and answer 200 with a working image; #6–#22 answer a real **500**, the only path here that did |
| a new topic | 83 | the four `catch {}` runs above |

```
  new_topic  refuse write #2   (sector 2180): next boot WILL NOT MOUNT
  new_topic  refuse write #50  (sector 2180): next boot WILL NOT MOUNT
  react      refuse write #5   (sector 2180): next boot WILL NOT MOUNT
  upload     refuse write #2   (sector 2180): next boot mounts
```

`fatSet` writes the cached sector to every copy in turn; if the second write
failed, the first had landed and nothing put it back. `cacheFat` refused to
mount a volume whose copies disagree. Those two decisions met here: **one
failed write to the mirror left a volume that would never mount again.** The
upload survived only because it flushed that sector again later in the same
request, so propagating the error honestly made the damage certain: the
reaction path did everything right and lost the volume.

**Fixed** in gopher-metal `5f08fc5`: at mount, where the copies disagree the
first is the FAT, and each differing sector of the others is written from it
(`cacheFat` answers how many). Linux's vfat reads only the first copy too.

### The bookmark that eats your bookmarks

`chat_state.zig` is documented best-effort: "a failed write just loses the
bookmark for that visit". Four of its five swallowed errors were that. The
fifth was not:

```zig
pub fn setSessionPinned(…) void {
    const existing = readPinnedFile(io, alloc, uid, conv_key) catch "";
    const cur = parsePinned(alloc, existing) catch return;
    …                       // rebuild the set with sid added or removed
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body.items }) catch {};
```

A failed read of the pinned file became an empty set, and the file was then
overwritten from it: pin one session while that read fails and every other
pin is gone, with the client told 204.

The sweep did not corroborate it. Refusing each of the 218 requests a pin
makes, 25 runs told the client 204 while the new pin was missing, but the old
pin was intact in both volumes: those runs failed to add a pin, not destroyed
one, and the pre-fix kernel gave byte-identical output. The finding is the
code alone; making a disk fail that particular read was a harder aim than the
machine could take. **Fixed** in angry-gopher `298c0871`: `catch return`,
since an absent file already reads as "".

### "It answered" is a weaker question than "is it sound"

`./sound.sh <image>` borrows Linux's `fsck.vfat -n`. Refusing each of the
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

Three kinds of litter, and the client was told 200 for the first five runs:
a **leaked cluster** (allocated, referenced by nothing; 2 KB per failed
upload), an **orphaned long file name** (a name written across several slots
with no commit point), and **FATs that differ** (the mirror, seen from
outside). FAT16 has no journal, and this machine has no fsck: on Linux the
same application sits on a journalling filesystem; on bare metal it sits on
this. A reported write failure is not a crash, so the code that knows a write
failed could undo what it began.

**Partly addressed, not re-swept.** gopher-metal's `fat16.zig` now gives back
a chain whose allocation fails part way ("a failed allocation leaves nothing
behind", `allocChain`), and tombstones live long-name parts left before a free
slot before writing an entry there (`writeEntry`). The FAT copies are the
mirror fix above. `sweep.sh` now runs `sound.sh` on every volume a seed wrote.

### Why one chat message was eighty-two writes

`DISK_TRACE=1` printed every request. One message:

```
368 requests: 286 reads, 82 writes
  writes:   58  directory + data
            12  FAT, first copy
            12  FAT, second copy
  reads:   157  directory + data
           125  FAT, second copy
```

The FAT writes were two sectors written twenty-four times: every cluster
allocation flushed the cached FAT sector to every copy at once (`fatSet`), and
a chat message allocates in several files (the transcript, its sidecars, the
per-user cursor). The 125 reads of the second copy were the mount checking the
copies agree before caching the first. These counts are of September's kernel.

## In this program

**The serial port.** QEMU's oracle (`check.sh`) found an invisible `0x01` at
the head of the first output: the guest's serial init sets the divisor latch
and writes the baud rate to the data port, and a model that did not know that
bit printed the baud rate as a character. Every word looked right.

**The card that dropped frames.** The real server's first run reported one
retransmission timeout where curl through QEMU reported none: 30 of 51 frames
to the guest had nowhere to go. A guest emptying a whole HTTP response into one
doorbell has not polled for a while, so its receive buffers are all in the
host's hands, and the card dropped frames that found none free. There is no
congestion on this wire, so a frame lost there is one this program invented.
A frame with nowhere to go now waits on the wire and goes in at the next exit.

**The fuzzer.** `zig build fuzz` drives every guest-facing model from a seeded
stream without a processor. On its first day it found six ways a guest could
kill or hang this program, two of them on the microvm-shaped machine
`check.sh` runs. Each seed that found something stays in `src/fuzz.zig`'s
`regressions`, run by `zig build test`.

**The `rdtsc` rewrite** that corrupted other instructions is in the README,
"`rdtsc` does not exit".
