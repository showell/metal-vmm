# The knobs

Every way metal-vmm can be unhelpful to its guest is a knob in the
environment, not a flag. **Nothing set is a machine that works perfectly**,
which is what `check.sh` and `same.sh` run on. Every knob here is off unless
its default column says otherwise.

    WIRE_EAT=3 DISK_REFUSE=7 ./zig-out/bin/metal-vmm <kernel.elf> [disk.img] [command line] [path to fetch]

Where a knob takes frame or request numbers, it takes a list: `3`, `3,9`, or a
range, `8-40`, up to 32 of these. Numbering starts at 1. **A number is a better
knob than a rate**: a rate explores at random, a number explores exhaustively,
and a sweep over numbers is a map (`lossy.sh` for frames, `flaky.sh` for disk
requests). A run says on the error stream what each knob did.

**A value that is not one stops the run** (exit 2, naming it): a word where
a number goes (`PEER_RESET_AT=30ms`), a flag that is not `1` or `0`, a list
past what it holds, a number past its most, a volume's knob with no
`VOLUME`. Nothing is read as "no fault" or cut to fit. A name in these
families that metal-vmm does not read (a misspelling, or a script's own
`VOLUME_SITE`) is said on the error stream and ignored. `src/checked.zig`
holds what each one must be.

The source of truth is `src/settings.zig` (the knobs into the faults),
`src/knobs.zig` (the full list, and what a seed draws), and the module each
table names.

## Machine

| knob | what it does | default |
|---|---|---|
| `TRANSPORT=pci` | the PC-shaped machine: virtio on a PCI bus, MSI-X, a local APIC; the guest halts between frames (README, "Interrupts, at a halt"). Needs Linux 5.10 or later for the MSR filter | unset: the microvm-shaped machine, devices in an mmio window, no interrupts |
| `PATIENCE_S=s` | on the PC-shaped machine, a run with nothing printed and no doorbell rung for `s` seconds of guest time ends as idle | 600 |
| `COVERAGE_OUT=<file>` | the guest's coverage lines go to that file, appended, as plain JSONL, and stay out of stdout (README, "What the guest says it reached") | unset: stdout is the guest's bytes exactly |
| `DISK_TRACE=1` | prints every disk request the guest makes | off |

## The calendar

| knob | what it does | default |
|---|---|---|
| `RTC_BOOTS_AT=unix` | the instant the real-time clock boots at, 1970 to 9999: e.g. `2147483647` (the last second of 32-bit time), `4102444799` (the end of a century), `1835395199` (a leap day's eve) | noon on 2026-09-18, every run |

| `RTC_ABSENT=1` | no chip: every register reads 0xFF, as a port with nothing behind it does | a chip |
| `RTC_STUCK=1` | status A always says an update is in progress, so a guest that waits it out must give up | never mid-update |
| `PIT_FROZEN=1` | the interval timer's count never moves, as absent or broken hardware reads | it counts |

Never drawn by a seed: a date is a thing a person picks for what it means,
and a clock that does not answer stops a boot, which a sweep would count as
a failure. The last three exist to reach gopher-metal's refusals of a clock
(its COVERAGE.md, "For the box"; QUEUE item 82).

## The wire: what the guest sends

| knob | what it does | default |
|---|---|---|
| `WIRE_EAT=n[,m,lo-hi]` | the guest's nth frame is lost | none |
| `WIRE_LOSS=k` | one of the guest's frames in `k` is lost (seeded dice) | none |
| `WIRE_LATENCY_US=us` | each frame takes `us` microseconds of the machine's clock to arrive, each way | 0 |

The wire holds 64 frames and drops the oldest when a 65th comes. What the
peer has to say on its own (a flood, a timer) waits for room instead, so a
flood with no gap arrives as fast as the guest takes it, not mostly lost. A
frame the guest has no receive buffer for **waits on the wire** and goes in
at the next exit; the card never drops one for want of a buffer.

## The wire: what the peer sends

| knob | what it does | default |
|---|---|---|
| `PEER_EAT=n[,m]` | the peer's nth frame is lost; frame 1 is the first the peer ever sends, a DHCP reply included | none |
| `PEER_LOSS=k` | one of the peer's frames in `k` is lost | none |
| `PEER_DAMAGE=n[,m]` | a byte of that segment's checksum is changed, so the guest's own check throws it away | none |
| `PEER_DAMAGE_RATE=k` | one in `k` of the peer's frames is damaged | none |
| `PEER_MANGLE=n[,m]` | that frame arrives after a copy of it that lies in one way (`mangle.zig`) | none |
| `PEER_MANGLE_RATE=k` | one in `k` of the peer's frames gets a lying copy | none |
| `PEER_MANGLE_KIND=kind` | only that kind of lie | each kind in turn |

A lost or damaged peer frame winds the peer's own retransmission timer
(RFC 6298: one second, doubling to a minute, eight sends and it gives up), on
the machine's clock, so what is lost is sent again rather than hanging the run.

**The lies** (`mangle.zig`, `Kind`): an IP version not 4 (`ip_version`), a
header shorter than 20 bytes (`ip_header_short`) or with options
(`ip_options`), a bad header checksum (`ip_checksum`), a total length past the
frame (`ip_total_past`) or shorter than a TCP header (`ip_total_short`), a
fragment (`fragment`), an address (`not_ours`) or a port (`wrong_port`) not
the guest's, a TCP data offset too short (`tcp_offset_short`) or past the
segment (`tcp_offset_past`). The copy's sums are made right, so it meets the
check meant for it, and its data is `X`s. The guest must drop every one, so
the run must end with the page the run without it gets: `sweep.sh` does not
excuse a page that differs under it. `zero_window` alone is no lie: a window
of 0 with the frame's own data, which must be taken. Only TCP frames get a
copy; the schedule counts every frame. The run ends saying which lies were
sent and which of gopher-metal's checks (`proto.parseIpv4`,
`tcp.Table.handle`) each meets.

## The peer: a worse client

`peer.zig`, `Rough`. Times are microseconds of the machine's clock after the
peer opens; sizes are bytes of the answer. These apply to the first client
only; any others behave.

| knob | the peer | default |
|---|---|---|
| `PEER_RESET_AT=us` | resets the connection then, if it is open, at its next sequence number; then answers anything with a reset | never |
| `PEER_RESET_OFF=n` | puts that reset `n` past its next sequence number instead, inside the guest's window, which must challenge it | 0 |
| `PEER_VANISH_AFTER=n` | neither sends nor hears once it has `n` bytes of the answer | never |
| `PEER_FLOOD=n` | sends `n` SYNs that never finish (up to 25,536), each from its own address in 198.51.100.x and port; a thousand fills gopher.zig's 256 slots four times over | none |
| `PEER_FLOOD_GAP_US=us` | the gap between the flood's SYNs | 10,000 (10 ms) |
| `PEER_FLOOD_AT_US=us` | when the flood starts, after the opening | at once |
| `PEER_SHUT_AFTER=n` | shuts its receive window once it has `n` bytes, takes nothing while it is shut, then says it is open | never |
| `PEER_SHUT_FOR_US=us` | how long the window stays shut | 0 |
| `PEER_PIPELINE=1` | sends its second request with the first, before any answer (it asks twice at least); the run ends saying how many answers came whole and whether the guest ended it with a FIN or a reset | off |
| `PEER_DRIP_US=us` | sends each segment of its request `us` after the last (with `PEER_MSS` to make them small): a slow client, never silent and not done for a long while | off |
| `PEER_RETRY=n` | asks again, on a new connection, what got no answer at all (closed or reset before a byte came), up to `n` times (at most 100), as a browser does; the run ends saying how many times the request was sent | 0 |
| `PEER_IGNORE_WINDOW=1` | sends all its request at once, past the window the guest offered, and sends again what the guest threw away | off: it keeps to the window |
| `PEER_MSS=n` | sends its request `n` bytes a segment, never more than the guest's announced MSS | the guest's MSS: 536 if it announced none, 1460 at most |

## The peer: more than one client, and what it sends

`peer.zig`, `Plan`, for a guest that holds many connections.

| knob | what it does | default |
|---|---|---|
| `PEER_CLIENTS=n` | the peer is `n` clients (8 at most), each on its own port and sequence numbers | 1 |
| `PEER_CLIENT_GAP_US=us` | opens each client a gap after the last | 1,000 (1 ms) |
| `PEER_REQUEST=a[,b,...]` | sends the bytes of request file `a` exactly as they are (a POST with a session cookie, say), and `b` for the second client; a client past the list asks the last | a GET of the path given as the fourth argument |
| `PEER_ASKS=k` | each client asks `k` times on one connection, the next when the last answer is whole (by its length or its chunks), then closes it itself | 1 |
| `PEER_BODY=<file>` | writes the body of the first client's answer to that file | unset: the closing line says how much there was |
| `PEER_RESPONSE=<file>` | writes the first client's whole answer, headers included, to that file | unset |
| `DHCP_LEASE_S=s` | offers and acknowledges a DHCP lease of `s` seconds; the run ends saying how many requests renewed it, how many came after it ran out, and whether it was held to the end or ran out unrenewed, and when | a day |

A client whose answer has neither a length nor chunks, such as a stream,
reads it until the server closes, and holds its connection open meanwhile. A
run with more than one conversation ends with a line for each client: its
status, how many answers came whole, how many bytes, and how it ended.

With none of the peer's knobs set, the peer is the plain client it always
was, frame for frame. The guest's coverage properties these reach are
gopher-metal's to measure (its `coverage/floor-metal.txt`).

## The boot disk (virtio-blk)

`faults.zig`, `cache.zig`, `disk.zig`.

| knob | what it does | default |
|---|---|---|
| `DISK_REFUSE=n[,m]` | answers the guest's nth request with the I/O error a real disk gives when it cannot do the work | none |
| `DISK_REFUSE_RATE=k` | refuses one request in `k` | none |
| `DISK_WRITES_ONLY=1` | `DISK_REFUSE` and `DISK_BAD_SECTOR` count and refuse writes only (a guest reads a hundred sectors for each it saves) | off |
| `DISK_READS_ONLY=1` | the same, reads only | off |
| `DISK_BAD_SECTOR=s[,t]` | refuses every request that touches that sector, for the whole run, read or write; named again on the next boot it is still bad, as a real one is. The run ends `metal-vmm: disk: bad sector S refused N of M requests (...)` | none |
| `DISK_ROT=s,b[,mask]` | serves every read of sector `s` with byte `b` changed by `mask`, and an "ok"; the image is untouched, and once the guest writes the sector it holds what was written | mask `0x01` |
| `DISK_CUT_AFTER=n` | lets the guest's nth write land, and then nothing: the request is never answered, the machine stops at the end of that exit, and the image keeps exactly what was written before the cut | none |
| `DISK_TEAR=n` | tears the nth write of several sectors: only its first `DISK_TEAR_KEEP` land, then the power is cut | none |
| `DISK_TEAR_KEEP=k` | how many sectors of the torn write land | 1 |
| `DISK_CACHE=1` | offers VIRTIO_BLK_F_FLUSH and keeps a write cache: a guest that negotiates FLUSH has its writes acknowledged before they are kept, a flush keeps them, and a power cut loses every write since the last flush. A guest that does not negotiate FLUSH is promised write-through (virtio 1.1 §5.2.5.1) and loses nothing | off: offering FLUSH changes what the guest negotiates |
| `DISK_CACHE=lie` | holds writes either way, as a disk that lies about its cache does | |

A request number reaches a sector on one path; a bad sector is reached on
every path that touches it. A run with a cache ends saying which kind, and how
many writes a cut lost. After a cut, `sound.sh` on the image asks whether it is
still a filesystem: that is how a FAT volume's crash consistency is measured.

## The volume (virtio-scsi)

`scsi.zig`. `VOLUME=<file>` attaches a second disk, a SCSI disk at target 0,
LUN 0 of a virtio-scsi controller, which is how a DigitalOcean droplet reaches
chat's data (gopher-metal's `scsi.zig`). It answers INQUIRY, READ
CAPACITY(10), MODE SENSE(10)'s caching page, READ(10), WRITE(10), SYNCHRONIZE
CACHE(10) and TEST UNIT READY; anything else is ILLEGAL REQUEST, another target
is BAD_TARGET, and the first command after power-on but INQUIRY is UNIT
ATTENTION, as a real disk's is. Its file keeps the run's writes as the boot
disk's does. Nothing below changes anything unless `VOLUME` is set.

| knob | what it does | default |
|---|---|---|
| `VOLUME=<file>` | attaches the volume | none |
| `VOLUME_CACHE=1` | holds its writes until SYNCHRONIZE CACHE, and says so (WCE=1) | off: write-through |
| `VOLUME_CACHE=lie` | holds them and says it writes through (WCE=0), so a driver that believes it never synchronizes | |
| `VOLUME_CACHE_KEEPS=k` | the cache drains in its own order: at any cut, each sector never synchronized has reached the media with chance 1/k (by a hash of `FAULT_SEED` and the sector, so a seed repeats it), and the rest are lost; so a directory entry can survive without its data, or a chain without its entry | off: a cut loses all of it |
| `VOLUME_CUT_AFTER=n` | cuts the power after the volume's nth write; either disk's cut empties both caches | none |
| `VOLUME_CUT_AT_EXIT=1` | fails the power when the guest stops, at any end: every write cache (`VOLUME_CACHE`, `DISK_CACHE`) loses what was never synchronized before anything is reported or written back, and a line says how many sectors each lost. This is the cut `VOLUME_CUT_AFTER` cannot place: after a response that came after the last write | off |
| `VOLUME_SYNC_FAIL=n` | answers the nth SYNCHRONIZE CACHE, and the `VOLUME_SYNC_FAIL_FOR - 1` after it, MEDIUM ERROR, keeping nothing: a cache that cannot reach its media | none |
| `VOLUME_SYNC_FAIL_FOR=k` | how many SYNCHRONIZE CACHEs in a row fail | 1 |
| `VOLUME_LATENCY_US=us` | every command costs the guest that long: it is answered at once and the machine's clock moves on by the latency before the guest runs again, which is what a driver spinning on the used ring (gopher-metal's) would have counted. A completion held back would never be seen, since that spin makes no exit | 0 |
| `VOLUME_SYNC_US=us` | each SYNCHRONIZE CACHE costs that much more: the slow command on network storage | 0 |
| `VOLUME_ATTENTION_AT=n` | CAPACITY DATA HAS CHANGED is pending from the nth command, as a volume resized under a droplet reports it: told on the next command but INQUIRY, which is not performed, so the driver must send it again | none |
| `VOLUME_GONE_AT=n` | from the nth command on, every command is BAD_TARGET, as when a DO volume is detached under a running droplet | none |
| `VOLUME_SECTOR=n` | READ CAPACITY says a sector is `n` bytes (4096, say) and counts the disk in them; transfers stay 512, since a driver that takes only 512 refuses the disk at bring-up, before any | 512 |
| `VOLUME_MODE_PAGES=none` | MODE SENSE answers with its header alone, no caching page | the caching page |
| `VOLUME_SHORT_AT=n` | the nth READ or WRITE moves the first half of its bytes and answers GOOD with the rest as its residual, a legal underrun: a driver that ignores the residual serves a read's stale half, or calls a half-written write done | none |
| `VOLUME_READ_ONLY_AT=n` | read-only from the nth command: MODE SENSE says WP and every WRITE is DATA PROTECT, while reads and SYNCHRONIZE CACHE still answer, as a DO volume the host has made read-only after an I/O error | none |

The run ends with `metal-vmm: volume: ...`: its reads, writes, SYNCHRONIZE
CACHEs and MODE SENSEs, how long was waited and how much of it on
SYNCHRONIZE CACHE, and whether a cut lost anything.

## Seeds

`FAULT_SEED=n` turns many of these knobs at once, each family by its own
chance and from a documented range, so "seed 4711" names one exact run. **A
knob set by hand wins over the seed.** A seeded run says first, on the error
stream, what it chose, as the knobs that repeat it without the seed:

    metal-vmm: FAULT_SEED=4711 is WIRE_EAT=12 WIRE_LATENCY_US=8143 PEER_FLOOD=3 PEER_FLOOD_GAP_US=212998

The table of what a seed draws, with what chance and from what range, is the
header of `src/knobs.zig`, and is not repeated here. `DISK_ROT` (one time in
eight) and `PEER_MANGLE` (one in four) are drawn last of all.

**With `VOLUME` set**, a seed also draws the volume's faults, on dice of
their own (`Knobs.withVolume`), so every knob a seed drew without a volume it
draws the same with one: `VOLUME_CACHE` (half the time; `lie` a quarter of
those), `VOLUME_CUT_AFTER`, `VOLUME_SYNC_FAIL` and `VOLUME_SYNC_FAIL_FOR`,
`VOLUME_ATTENTION_AT`, and `VOLUME_CACHE_KEEPS` half the times it draws
`VOLUME_CACHE`. Not `VOLUME_LATENCY_US`, which a sweep would wait out.

Never drawn: the rates, `PEER_FLOOD_AT_US`, `DISK_BAD_SECTOR`,
`DISK_READS_ONLY`, `PEER_IGNORE_WINDOW`, `DISK_CACHE`, `PEER_RETRY`,
`RTC_BOOTS_AT`, `PEER_DRIP_US`, `PEER_PIPELINE`, `DHCP_LEASE_S`; `knobs.zig`
says why for each.

## `sweep.sh`'s own settings

`sweep.sh [first] [last]` runs `FAULT_SEED` from first to last (1 to 100 by
default); its header is the reference.

| variable | what it does | default |
|---|---|---|
| `GUESTS` | where the kernels are | `~/showell_repos/gopher-metal/probe` |
| `SITE` | the volume every run gets a fresh copy of | `~/build/gopher-metal/probe/gopher/pristine.img` |
| `PATH_WANTED` | the path fetched | `/` |
| `TRANSPORT` | the machine | `pci` |
| `FLOOR=<file>` | a coverage floor the merged report is gated on | none |
| `RUN_TIMEOUT` | seconds per run | 300 |
| `KEEP=<dir>` | keeps every run's log, page and the coverage JSONL there | none |
| `COVERAGE_SDK` | where zig-coverage-sdk is, for `tools/report.py` | a sibling checkout |
| `VOLUME_SITE=<image>` | attaches a fresh copy of that image to every run as its volume, so seeds draw the volume's faults | none |
| `POST=<request file>`, `READ_BACK=<path>`, `MARK=<text>` | **the durability sweep**: each seed sends the post with `VOLUME_CUT_AT_EXIT=1` and the volume faults its seed draws, then the same kernel boots again, unhurt, on a copy of that volume and asks for `READ_BACK` | off |

In the durability sweep, **a 303 for a message the read-back does not hold
fails**, whatever the seed did, except where the cache lied
(`VOLUME_CACHE=lie`) or a SYNCHRONIZE CACHE failed (`VOLUME_SYNC_FAIL`): there
losing it is the design's, and the verdict says "lost (allowed: ...)". No 303
promised nothing. A read-back that gets no page fails. Before any seed, the
unhurt post must be told 303 and keep `MARK`, and the pristine volume must not
hold it, or the sweep stops with exit 2.
