//! **WHAT A RUN SAYS AT ITS END**, on the error stream: what was done to it
//! (the wire's, the peer's and the disk's faults), how it rested, where the
//! power was cut, and what coverage the guest reported.

const std = @import("std");
const kvm = @import("kvm.zig");
const virtio = @import("virtio.zig");
const net = @import("net.zig");
const clock = @import("clock.zig");
const entropy = @import("entropy.zig");
const disk = @import("disk.zig");
const mangle = @import("mangle.zig");
const faults = @import("faults.zig");
const wire = @import("peer.zig");
const apic = @import("apic.zig");
const coverage = @import("coverage.zig");
const knobs = @import("knobs.zig");
const pci = @import("pci.zig");
const main = @import("main.zig");
const linux = std.os.linux;
const Machine = main.Machine;
const settings = @import("settings.zig");
const loader = @import("loader.zig");
const processor = @import("processor.zig");
const halt = @import("halt.zig");
const testing = std.testing;

const tellTheFaults = settings.tellTheFaults;
const count = settings.count;
const knob = settings.knob;
const numbers = settings.numbers;
const FakeEnv = settings.FakeEnv;
const ElfHeader = loader.ElfHeader;
const ProgramHeader = loader.ProgramHeader;
const Rewritten = loader.Rewritten;
const Loaded = loader.Loaded;
const SectionHeader = loader.SectionHeader;
const textRange = loader.textRange;
const rewriteDeadlineWrites = loader.rewriteDeadlineWrites;
const rewriteClockReads = loader.rewriteClockReads;
const rewriteMarked = loader.rewriteMarked;
const NoteHeader = loader.NoteHeader;
const LoadError = loader.LoadError;
const load = loader.load;
const pvhEntry = loader.pvhEntry;
const tsc_port = loader.tsc_port;
const msr_port = loader.msr_port;
const fakeKernel = loader.fakeKernel;
const describeProcessor = processor.describeProcessor;
const forgetTheDice = processor.forgetTheDice;
const sayTheApic = processor.sayTheApic;
const hideTheHostsTime = processor.hideTheHostsTime;
const owned_msrs = processor.owned_msrs;
const msr_tsc = processor.msr_tsc;
const msrFilter = processor.msrFilter;
const ownTheMsrs = processor.ownTheMsrs;
const deniedByFilter = processor.deniedByFilter;
const Rested = halt.Rested;
const Cpu = halt.Cpu;
const Wake = halt.Wake;
const wakes = halt.wakes;
const startedApic = halt.startedApic;

/// What the power cut left, on the error stream: which write, and for a torn
/// one how much of it landed.
pub fn reportCut(cut: faults.Drive.Cut) void {
    if (cut.landed < cut.of) {
        std.debug.print("metal-vmm: the power was cut in the guest's write {d}: {d} of its {d} sectors from sector {d} landed\n", .{ cut.write, cut.landed, cut.of, cut.sector });
    } else {
        std.debug.print("metal-vmm: the power was cut after the guest's write {d} (sector {d}, {d} sectors)\n", .{ cut.write, cut.sector, cut.of });
    }
}

/// The run's coverage, if its guest printed any: the last line on the error
/// stream.
pub fn reportCoverage(machine: *const Machine) void {
    var buf: [256]u8 = undefined;
    if (machine.serial.summary(&buf)) |line| std.debug.print("{s}", .{line});
}

/// What was done to this run, if anything was.
/// The PC-shaped machine's halts and interrupts, on the error stream.
pub fn reportRest(machine: *const Machine) void {
    var messages: u64 = 0;
    for (machine.bus.?.functions) |f| if (f) |g| {
        messages += g.msix.messages;
    };
    std.debug.print("metal-vmm: {d} halts skipped {d} ms; {d} interrupts taken ({d} timer, {d} MSI-X messages); {d} APIC MSR accesses\n", .{
        machine.halts,             machine.halted_ns / std.time.ns_per_ms, machine.lapic.taken,
        machine.lapic.timer_fired, messages,                               machine.msrs,
    });
}

pub fn reportRun(card: *const net.Net, block: *const virtio.Block, ns: u64) void {
    if (card.line.configured()) reportFaults("wire", "frames sent", &card.line.lost, ns);
    if (card.line.peer_lost.configured()) reportFaults("peer", "frames sent", &card.line.peer_lost, ns);
    if (card.line.peer_damaged.configured()) reportFaults("peer damage", "frames sent", &card.line.peer_damaged, ns);
    if (card.line.peer_mangled.configured()) {
        reportFaults("peer lies", "frames sent", &card.line.peer_mangled, ns);
        var line: [512]u8 = undefined;
        std.debug.print("{s}", .{mangledKinds(&card.line, &line)});
    }
    if (block.refusals.configured()) {
        const shown: usize = @intCast(@min(block.refusals.refused.picked_count, block.refusals.sectors.len));
        reportFaultsWith("disk", "requests", &block.refusals.refused, ns, block.refusals.sectors[0..shown], block.refusals.kinds[0..shown]);
    }
    if (block.refusals.bad_len != 0) {
        var buf: [512]u8 = undefined;
        std.debug.print("{s}", .{badSectors(&block.refusals, &buf)});
    }
    var buf: [2048]u8 = undefined;
    std.debug.print("{s}", .{unspent(&card.line, &card.peer, &block.refusals, &buf)});
    if (peerEnd(&card.peer.tcp)) |line| std.debug.print("{s}", .{line});
    if (pipelined(&card.peer.tcp)) |line| std.debug.print("{s}", .{line});
    if (card.peer.rough.retry > 0)
        std.debug.print("metal-vmm: the first client sent its request {d} times (PEER_RETRY={d})\n", .{ card.peer.sends(), card.peer.rough.retry });
    if (card.peer.lease_named) {
        var line: [512]u8 = undefined;
        std.debug.print("{s}", .{card.peer.leaseLine(ns, &line)});
    }
    if (block.cache) |c| {
        var line: [256]u8 = undefined;
        std.debug.print("{s}", .{c.line(&line, block.refusals.cut != null)});
    }
    const d = &block.refusals;
    if (d.rot_sector) |at| if (d.rotted > 0) {
        std.debug.print("metal-vmm: disk: sector {d} rotted (byte {d}, mask 0x{x:0>2}) in {d} reads{s}\n", .{
            at, d.rot_byte, d.rot_mask, d.rotted, if (d.rot_healed) ", then the guest wrote it again" else "",
        });
    };
}

/// **WHAT A PIPELINING CLIENT GOT** (`PEER_PIPELINE`): how many of its
/// answers came whole, and how the connection ended: the guest's FIN, its
/// reset, or neither.
pub fn pipelined(c: *const wire.Tcp) ?[]const u8 {
    if (!c.rough.pipeline) return null;
    const Static = struct {
        var buf: [256]u8 = undefined;
    };
    const how = switch (c.state) {
        .refused => "the guest reset the connection",
        .closing, .done => "the guest closed it with a FIN",
        .fin_wait => "it closed, and the guest's FIN never came",
        else => "it did not end",
    };
    return std.fmt.bufPrint(&Static.buf, "metal-vmm: the pipelining client got {d} of {d} answers whole ({d} bytes); {s}\n", .{ c.answers, c.asks, c.received, how }) catch null;
}

test "a pipelining client's end is said, and nothing for another client" {
    var c = wire.Tcp{ .asks = 2, .answers = 1, .received = 300, .state = .refused };
    try testing.expect(pipelined(&c) == null);
    c.rough.pipeline = true;
    try testing.expectEqualStrings("metal-vmm: the pipelining client got 1 of 2 answers whole (300 bytes); the guest reset the connection\n", pipelined(&c).?);
}

/// **WHEN THE PEER ITSELF LET THE PAGE GO** (REVIEW-peer.md S1): the first
/// client gave up, having sent the same thing too often unanswered, or
/// vanished as `PEER_VANISH_AFTER` asked. A run whose page is missing for
/// either reason missed it through the peer's own doing, and sweep.sh
/// excuses it by this line. Nothing for any other end.
pub fn peerEnd(c: *const wire.Tcp) ?[]const u8 {
    return switch (c.state) {
        .gave_up => "metal-vmm: the first client gave up: it sent the same thing too often, unanswered\n",
        .gone => "metal-vmm: the first client vanished, as PEER_VANISH_AFTER asked\n",
        else => null,
    };
}

test "the peer's own end is said when it gave up or vanished, and only then" {
    var c = wire.Tcp{};
    for (std.enums.values(wire.Tcp.State)) |state| {
        c.state = state;
        const said = peerEnd(&c);
        try testing.expectEqual(state == .gave_up or state == .gone, said != null);
    }
}

/// **WHAT THE CLIENT GOT**, as main prints it on stdout at any end that is
/// not a crash: the first client's status and body on one line, or its size
/// when the line would pass 512 bytes; and, when there is more than one
/// conversation, a line for every client: what it got, how many answers came
/// whole, and how it ended.
pub fn client(peer: *const wire.Peer, buf: []u8) []const u8 {
    const got = &peer.tcp;
    // Trailing newlines are trimmed because the shell trims them too, and
    // this line is compared against one built from curl's output.
    const body = std.mem.trimEnd(u8, got.body(), "\r\n");
    // **THE SIZE IT CAME AT** (metal-vmm QUEUE 104): the client keeps the
    // first 64 KiB, and `received` counts all of it, so a page past what was
    // kept is said at its own size, the head's bytes taken off. Its trailing
    // newlines are counted, kept or cut (QUEUE 111): the end of a page cut
    // short is not here to trim, and the trimming is the quoted line's only.
    const came: u64 = if (got.received > got.reply_len) got.received - (got.reply_len - got.body().len) else got.body().len;
    var at: usize = 0;
    const first = buf[0..@min(buf.len, 512)];
    const text = std.fmt.bufPrint(first, "peer: {d} \"{s}\"\n", .{ got.status(), body }) catch
        std.fmt.bufPrint(first, "peer: {d}, {d} bytes\n", .{ got.status(), came }) catch return "peer: ?\n";
    at = text.len;
    if (peer.plan.clients > 1 or peer.plan.asks > 1) {
        for (0..peer.opened) |i| {
            const c = peer.clientConst(i);
            const each = std.fmt.bufPrint(buf[at..], "peer {d}: {d}, {d} of {d} answers, {d} bytes, {s}\n", .{
                i + 1, c.status(), c.answers, c.asks, c.received, @tagName(c.state),
            }) catch break;
            at += each.len;
        }
    }
    return buf[0..at];
}

test "what the client got: one line, or its size, and a line a client when there are several" {
    var buf: [4096]u8 = undefined;
    var peer = wire.Peer{};
    const answer = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello\r\n";
    @memcpy(peer.tcp.reply[0..answer.len], answer);
    peer.tcp.reply_len = answer.len;
    try testing.expectEqualStrings("peer: 200 \"hello\"\n", client(&peer, &buf));
    // A page that does not fit on the line says how big it was.
    const head = "HTTP/1.1 200 OK\r\n\r\n";
    @memcpy(peer.tcp.reply[0..head.len], head);
    @memset(peer.tcp.reply[head.len..][0..600], 'x');
    peer.tcp.reply_len = head.len + 600;
    try testing.expectEqualStrings("peer: 200, 600 bytes\n", client(&peer, &buf));
    // Two clients, the second still reading.
    peer.plan.clients = 2;
    peer.opened = 2;
    peer.tcp.state = .done;
    peer.tcp.answers = 1;
    peer.tcp.received = 618;
    peer.others[0].state = .established;
    try testing.expectEqualStrings(
        \\peer: 200, 600 bytes
        \\peer 1: 200, 1 of 1 answers, 618 bytes, done
        \\peer 2: 0, 0 of 1 answers, 0 bytes, established
        \\
    , client(&peer, &buf));
}

test "a page past what the client keeps is said at the size it came, not what was kept (QUEUE 104)" {
    var buf: [4096]u8 = undefined;
    var peer = wire.Peer{};
    const head = "HTTP/1.1 200 OK\r\n\r\n";
    @memcpy(peer.tcp.reply[0..head.len], head);
    @memset(peer.tcp.reply[head.len..], 'x');
    peer.tcp.reply_len = peer.tcp.reply.len; // the first 64 KiB, kept
    peer.tcp.received = head.len + 100_000; // a page of 100,000 bytes, all of it here
    try testing.expectEqualStrings("peer: 200, 100000 bytes\n", client(&peer, &buf));
}

test "a page's size is the same count kept or cut: its trailing newlines included (QUEUE 111)" {
    var buf: [4096]u8 = undefined;
    var peer = wire.Peer{};
    const head = "HTTP/1.1 200 OK\r\n\r\n";
    @memcpy(peer.tcp.reply[0..head.len], head);
    @memset(peer.tcp.reply[head.len..][0..600], 'x');
    @memcpy(peer.tcp.reply[head.len + 600 ..][0..2], "\r\n");
    peer.tcp.reply_len = head.len + 602;
    peer.tcp.received = head.len + 602;
    // Kept whole: 602 bytes came, as a page cut short counts what came.
    try testing.expectEqualStrings("peer: 200, 602 bytes\n", client(&peer, &buf));
}

/// **WHICH LIES WERE TOLD** (`PEER_MANGLE`): each kind sent, and the
/// guest's check it meets (mangle.zig).
pub fn mangledKinds(line: *const faults.Wire, buf: []u8) []const u8 {
    var at: usize = 0;
    const head = std.fmt.bufPrint(buf, "metal-vmm: peer lies:", .{}) catch return "";
    at = head.len;
    var any = false;
    for (line.mangled, 0..) |n, i| {
        if (n == 0) continue;
        const k: mangle.Kind = @enumFromInt(i);
        const out = std.fmt.bufPrint(buf[at..], "{s} {d} {s} ({s})", .{ if (any) "," else "", n, @tagName(k), k.check() }) catch break;
        at += out.len;
        any = true;
    }
    if (!any) {
        const out = std.fmt.bufPrint(buf[at..], " none sent", .{}) catch "";
        at += out.len;
    }
    if (line.mangled_not_tcp > 0) {
        const out = std.fmt.bufPrint(buf[at..], "; {d} frames picked were not TCP", .{line.mangled_not_tcp}) catch "";
        at += out.len;
    }
    if (at < buf.len) {
        buf[at] = '\n';
        at += 1;
    }
    return buf[0..at];
}

/// **A KNOB WHOSE MOMENT NEVER CAME SAYS SO**, one line each: a frame or a
/// request named past the last there was, a reset due when there was no
/// connection to reset, a vanish or a shut past the whole answer, a flood or
/// a power cut the run ended before. Without this such a run looks like the
/// fault happened and changed nothing. Empty when every knob was spent.
pub fn unspent(line: *const faults.Wire, peer: *const wire.Peer, drive: *const faults.Drive, buf: []u8) []const u8 {
    var at: usize = 0;
    const w = struct {
        fn f(b: []u8, i: *usize, comptime fmt: []const u8, args: anytype) void {
            const out = std.fmt.bufPrint(b[i.*..], "metal-vmm: " ++ fmt ++ "\n", args) catch return;
            i.* += out.len;
        }
    }.f;
    const named = [_]struct { name: []const u8, s: *const faults.Schedule, of: []const u8 }{
        .{ .name = "WIRE_EAT", .s = &line.lost, .of = "the guest sent" },
        .{ .name = "PEER_EAT", .s = &line.peer_lost, .of = "the peer sent" },
        .{ .name = "PEER_DAMAGE", .s = &line.peer_damaged, .of = "the peer sent" },
        .{ .name = "PEER_MANGLE", .s = &line.peer_mangled, .of = "the peer sent" },
        .{ .name = "DISK_REFUSE", .s = &drive.refused, .of = if (drive.writes_only) "the guest wrote" else if (drive.reads_only) "the guest read" else "the guest made" },
    };
    for (named) |n| for (n.s.named) |k| {
        if (k.lo == 0 or k.hi <= n.s.seen) continue;
        if (k.lo == k.hi) {
            w(buf, &at, "{s} #{d} never came: {s} {d}", .{ n.name, k.lo, n.of, n.s.seen });
        } else if (k.lo > n.s.seen) {
            w(buf, &at, "{s} #{d}-{d} never came: {s} {d}", .{ n.name, k.lo, k.hi, n.of, n.s.seen });
        } else {
            w(buf, &at, "{s} #{d}-{d} ended early: {s} {d}", .{ n.name, k.lo, k.hi, n.of, n.s.seen });
        }
    };

    const c = &peer.tcp;
    const r = &peer.rough;
    if (r.reset_after_ns) |ns| if (c.state != .reset) {
        if (c.state == .idle) {
            w(buf, &at, "PEER_RESET_AT={d} came to nothing: the client never opened", .{ns / std.time.ns_per_us});
        } else if (c.reset_past) {
            w(buf, &at, "PEER_RESET_AT={d} fell when the connection was not open ({s}); no reset sent", .{ ns / std.time.ns_per_us, @tagName(c.state) });
        } else {
            w(buf, &at, "PEER_RESET_AT={d} never came: the run ended first", .{ns / std.time.ns_per_us});
        }
    };
    if (r.vanish_after) |n| if (c.state != .gone) {
        w(buf, &at, "PEER_VANISH_AFTER={d} never came: the client had {d} bytes of the answer", .{ n, c.reply_len });
    };
    if (r.shut_after) |n| if (!c.shut_ever) {
        w(buf, &at, "PEER_SHUT_AFTER={d} never came: the client had {d} bytes of the answer", .{ n, c.reply_len });
    };
    if (peer.flooded < @min(r.flood, wire.max_flood)) {
        w(buf, &at, "PEER_FLOOD={d}: only {d} of its SYNs were sent before the run ended", .{ r.flood, peer.flooded });
    }
    if (drive.cut_after) |n| if (drive.cut == null) {
        w(buf, &at, "DISK_CUT_AFTER={d} never came: the guest wrote {d} times", .{ n, drive.writes });
    };
    if (drive.rot_sector) |sector| if (drive.rotted == 0) {
        w(buf, &at, "DISK_ROT={d},{d} never came: the guest never read sector {d}{s}", .{ sector, drive.rot_byte, sector, if (drive.rot_healed) " before writing it" else "" });
    };
    if (drive.tear) |n| if (drive.cut == null) {
        w(buf, &at, "DISK_TEAR={d} never came: the guest made {d} writes of more than one sector", .{ n, drive.multi_writes });
    };
    return buf[0..at];
}

test "a knob whose moment never came says so, and a spent one says nothing" {
    var buf: [2048]u8 = undefined;
    var line = faults.Wire{};
    var peer = wire.Peer{};
    var drive = faults.Drive{};
    try testing.expectEqualStrings("", unspent(&line, &peer, &drive, &buf));

    // Frames and requests named past the last.
    line.lost.named[0] = .one(2);
    line.lost.named[1] = .one(9);
    line.peer_lost.named[0] = .one(4);
    line.peer_lost.named[1] = .{ .lo = 3, .hi = 6 };
    line.peer_damaged.named[0] = .{ .lo = 5, .hi = 6 };
    drive.refused.named[0] = .one(50);
    drive.writes_only = true;
    for (0..3) |_| _ = line.carries();
    for (0..4) |_| line.hold("x", 0);
    for (0..7) |_| _ = drive.serves(0, 1, true);
    // A reset due before the handshake finished, a vanish and a shut past
    // the answer, half a flood, and a cut after more writes than there were.
    peer.rough = .{ .reset_after_ns = 3 * std.time.ns_per_ms, .vanish_after = 900, .shut_after = 800, .flood = 5 };
    peer.tcp.state = .syn_sent;
    peer.tcp.reset_past = true;
    peer.tcp.reply_len = 120;
    peer.flooded = 2;
    drive.cut_after = 40;
    try testing.expectEqualStrings(
        \\metal-vmm: WIRE_EAT #9 never came: the guest sent 3
        \\metal-vmm: PEER_EAT #3-6 ended early: the peer sent 4
        \\metal-vmm: PEER_DAMAGE #5-6 never came: the peer sent 4
        \\metal-vmm: DISK_REFUSE #50 never came: the guest wrote 7
        \\metal-vmm: PEER_RESET_AT=3000 fell when the connection was not open (syn_sent); no reset sent
        \\metal-vmm: PEER_VANISH_AFTER=900 never came: the client had 120 bytes of the answer
        \\metal-vmm: PEER_SHUT_AFTER=800 never came: the client had 120 bytes of the answer
        \\metal-vmm: PEER_FLOOD=5: only 2 of its SYNs were sent before the run ended
        \\metal-vmm: DISK_CUT_AFTER=40 never came: the guest wrote 0 times
        \\
    , unspent(&line, &peer, &drive, &buf));

    // Spent, each of them: nothing to say.
    peer.tcp.state = .gone;
    peer.tcp.shut_ever = true;
    peer.flooded = 5;
    drive.cut = .{ .write = 40, .sector = 0, .landed = 1, .of = 1 };
    line.lost.named[1] = .{};
    line.peer_lost.named[1] = .{};
    line.peer_damaged.named[0] = .{};
    drive.refused.named[0] = .one(7);
    try testing.expectEqualStrings("metal-vmm: PEER_RESET_AT=3000 fell when the connection was not open (gone); no reset sent\n", unspent(&line, &peer, &drive, &buf));
    // A reset that came: spent, though the vanish after it never could.
    peer.tcp.state = .reset;
    peer.rough.vanish_after = null;
    try testing.expectEqualStrings("", unspent(&line, &peer, &drive, &buf));
}

/// One line on the error stream, so a sweep can read what a run did. **THE
/// GUEST'S OWN CLOCK IS THE INTERESTING NUMBER**: a lost frame costs it a
/// retransmission timeout, and that shows up here and nowhere else.
pub fn reportFaults(what: []const u8, of: []const u8, s: *const faults.Schedule, ns: ?u64) void {
    reportFaultsWith(what, of, s, ns, null, null);
}

/// The same line, plus what each refused request was asking for.
pub fn reportFaultsWith(what: []const u8, of: []const u8, s: *const faults.Schedule, ns: ?u64, sectors: ?[]const u64, kinds: ?[]const u8) void {
    var text: [256]u8 = undefined;
    var written = std.fmt.bufPrint(&text, "{s}: {d} {s}, {d} {s}", .{ what, s.seen, of, s.picked_count, pickedWord(what) }) catch return;
    var at = written.len;
    const shown = @min(s.picked_count, s.picked.len);
    for (s.picked[0..@intCast(shown)], 0..) |n, i| {
        written = std.fmt.bufPrint(text[at..], "{s}{d}", .{ if (i == 0) " (#" else ", #", n }) catch break;
        at += written.len;
        if (sectors) |where| {
            if (i < where.len) {
                const kind: u8 = if (kinds) |k| k[i] else '?';
                written = std.fmt.bufPrint(text[at..], ", a {s} of sector {d}", .{ if (kind == 'w') "write" else "read", where[i] }) catch break;
                at += written.len;
            }
        }
    }
    if (shown > 0 and at < text.len) {
        text[at] = ')';
        at += 1;
    }
    if (ns) |elapsed| {
        written = std.fmt.bufPrint(text[at..], ", {d} ms of the guest's time", .{elapsed / std.time.ns_per_ms}) catch return;
        at += written.len;
    }
    if (at < text.len) {
        text[at] = '\n';
        at += 1;
    }
    _ = linux.write(2, &text, at);
}

/// **WHAT THE BAD SECTORS REFUSED**: which, how often, and the first few
/// by request number, so a sweep can say which path reached them.
pub fn badSectors(d: *const faults.Drive, buf: []u8) []const u8 {
    var at: usize = 0;
    const w = struct {
        fn f(b: []u8, i: *usize, comptime fmt: []const u8, args: anytype) void {
            const out = std.fmt.bufPrint(b[i.*..], fmt, args) catch return;
            i.* += out.len;
        }
    }.f;
    w(buf, &at, "metal-vmm: disk: bad sector", .{});
    for (d.bad[0..d.bad_len], 0..) |s, i| w(buf, &at, "{s}{d}", .{ if (i == 0) " " else ", ", s });
    w(buf, &at, " refused {d} of {d} requests", .{ d.bad_hits, d.requests });
    const shown: usize = @intCast(@min(d.bad_hits, d.bad_at.len));
    for (0..shown) |i| {
        w(buf, &at, "{s}#{d}, a {s} of sector {d}", .{
            if (i == 0) " (" else "; ", d.bad_at[i], if (d.bad_kinds[i] == 'w') "write" else "read", d.bad_sectors[i],
        });
    }
    if (shown > 0) w(buf, &at, ")", .{});
    w(buf, &at, "\n", .{});
    return buf[0..at];
}

test "the bad sectors' line" {
    var d = faults.Drive{ .bad_len = 2 };
    d.bad[0] = 2180;
    d.bad[1] = 7;
    _ = d.serves(1, 1, false);
    _ = d.serves(2180, 1, true);
    _ = d.serves(0, 8, false);
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("metal-vmm: disk: bad sector 2180, 7 refused 2 of 3 requests (#2, a write of sector 2180; #3, a read of sector 7)\n", badSectors(&d, &buf));
    var none = faults.Drive{ .bad_len = 1 };
    none.bad[0] = 5;
    try std.testing.expectEqualStrings("metal-vmm: disk: bad sector 5 refused 0 of 0 requests\n", badSectors(&none, &buf));
}

pub fn pickedWord(what: []const u8) []const u8 {
    if (std.mem.eql(u8, what, "wire") or std.mem.eql(u8, what, "peer")) return "lost";
    if (std.mem.eql(u8, what, "peer damage")) return "damaged";
    if (std.mem.eql(u8, what, "peer lies")) return "sent after a lying copy";
    return "refused";
}

/// **WHAT THE RUN COST** (cost.zig), the line before the coverage's: exits by
/// kind, the guest's time, the longest halt, frames each way, disk requests.
pub fn cost(machine: *const Machine, card: *const net.Net, block: *const virtio.Block) void {
    var buf: [256]u8 = undefined;
    const line = machine.cost.line(&buf, .{
        .guest_ns = machine.time.ns,
        .frames_out = card.sent,
        .frames_in = card.received,
        .disk_requests = block.reads + block.writes,
    }) orelse return;
    std.debug.print("{s}", .{line});
}
