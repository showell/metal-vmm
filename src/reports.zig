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
    if (block.refusals.configured()) {
        const shown: usize = @intCast(@min(block.refusals.refused.picked_count, block.refusals.sectors.len));
        reportFaultsWith("disk", "requests", &block.refusals.refused, ns, block.refusals.sectors[0..shown], block.refusals.kinds[0..shown]);
    }
    if (block.refusals.bad_len != 0) {
        var buf: [512]u8 = undefined;
        std.debug.print("{s}", .{badSectors(&block.refusals, &buf)});
    }
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
