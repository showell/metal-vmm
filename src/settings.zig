//! **THE KNOBS, INTO THE FAULTS**: what `FAULT_SEED` and the environment
//! turned (knobs.zig), set on the wire, the disk and the peer before a run.

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
const reports = @import("reports.zig");
const loader = @import("loader.zig");
const processor = @import("processor.zig");
const halt = @import("halt.zig");
const testing = std.testing;

const reportCut = reports.reportCut;
const reportCoverage = reports.reportCoverage;
const reportRest = reports.reportRest;
const reportRun = reports.reportRun;
const reportFaults = reports.reportFaults;
const reportFaultsWith = reports.reportFaultsWith;
const pickedWord = reports.pickedWord;
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

/// **THE FAULTS TAKE THEIR ORDERS FROM THE ENVIRONMENT**, not from a flag:
/// which of the guest's frames to eat (`WIRE_EAT=3` or `WIRE_EAT=3,9`), a rate
/// to eat them at (`WIRE_LOSS=4`, one frame in four), how long a frame takes to
/// reach the guest (`WIRE_LATENCY_US=250`), and which of its disk requests come
/// back refused (`DISK_REFUSE=3,9`, `DISK_REFUSE_RATE=100`). Nothing set is a
/// machine that works perfectly, which is what check.sh runs on.
pub fn tellTheFaults(line: *faults.Wire, drive: *faults.Drive, rough: *wire.Rough, k: *const knobs.Knobs) void {
    numbers(&line.lost, k, "WIRE_EAT");
    numbers(&line.peer_lost, k, "PEER_EAT");
    numbers(&line.peer_damaged, k, "PEER_DAMAGE");
    if (k.get("PEER_LOSS")) |n| line.peer_lost.rate = std.fmt.parseInt(u32, n, 10) catch 0;
    if (k.get("PEER_DAMAGE_RATE")) |n| line.peer_damaged.rate = std.fmt.parseInt(u32, n, 10) catch 0;
    rough.retransmits = line.hurtsPeer();
    // **THE PEER'S OWN MISBEHAVIOUR** (peer.zig, `Rough`): times in
    // microseconds of the machine's clock from when it opened, sizes in
    // bytes of the answer.
    if (knob(k, "PEER_RESET_AT")) |us| rough.reset_after_ns = us * std.time.ns_per_us;
    if (knob(k, "PEER_RESET_OFF")) |n| rough.reset_off = @truncate(n);
    if (knob(k, "PEER_VANISH_AFTER")) |n| rough.vanish_after = @intCast(n);
    if (knob(k, "PEER_FLOOD")) |n| rough.flood = @intCast(@min(n, wire.max_flood));
    if (knob(k, "PEER_FLOOD_AT_US")) |us| rough.flood_after_ns = us * std.time.ns_per_us;
    if (knob(k, "PEER_FLOOD_GAP_US")) |us| rough.flood_gap_ns = us * std.time.ns_per_us;
    if (knob(k, "PEER_SHUT_AFTER")) |n| rough.shut_after = @intCast(n);
    if (knob(k, "PEER_SHUT_FOR_US")) |us| rough.shut_for_ns = us * std.time.ns_per_us;
    if (knob(k, "PEER_MSS")) |n| if (n > 0) {
        rough.mss = @intCast(n);
    };
    numbers(&drive.refused, k, "DISK_REFUSE");
    if (knob(k, "DISK_CUT_AFTER")) |n| if (n > 0) {
        drive.cut_after = n;
    };
    if (knob(k, "DISK_TEAR")) |n| if (n > 0) {
        drive.tear = n;
    };
    if (knob(k, "DISK_TEAR_KEEP")) |n| if (n > 0) {
        drive.tear_keep = n;
    };
    if (k.get("WIRE_LOSS")) |n| line.lost.rate = std.fmt.parseInt(u32, n, 10) catch 0;
    if (k.get("DISK_REFUSE_RATE")) |n| drive.refused.rate = std.fmt.parseInt(u32, n, 10) catch 0;
    if (k.get("DISK_WRITES_ONLY")) |_| drive.writes_only = true;
    if (k.get("WIRE_LATENCY_US")) |n| {
        line.latency_ns = (std.fmt.parseInt(u64, n, 10) catch 0) * std.time.ns_per_us;
    }
}

/// One number from the environment, if it is there and is one.
pub fn count(environ: std.process.Environ, name: []const u8) ?u64 {
    const text = environ.getPosix(name) orelse return null;
    return std.fmt.parseInt(u64, text, 10) catch null;
}

/// One number a fault knob says, if it says one.
pub fn knob(k: *const knobs.Knobs, name: []const u8) ?u64 {
    const text = k.get(name) orelse return null;
    return std.fmt.parseInt(u64, text, 10) catch null;
}

pub fn numbers(schedule: *faults.Schedule, k: *const knobs.Knobs, name: []const u8) void {
    const list = k.get(name) orelse return;
    var at: usize = 0;
    var each = std.mem.tokenizeScalar(u8, list, ',');
    while (each.next()) |one| {
        if (at >= schedule.named.len) break;
        schedule.named[at] = std.fmt.parseInt(u32, one, 10) catch continue;
        at += 1;
    }
}

/// An environment, by hand.
pub const FakeEnv = struct {
    pairs: []const [2][]const u8,

    pub fn getPosix(self: FakeEnv, name: []const u8) ?[]const u8 {
        for (self.pairs) |p| if (std.mem.eql(u8, p[0], name)) return p[1];
        return null;
    }
};

test "the knobs reach the wire, the disk and the peer, a seed's or the environment's alike" {
    var by_hand = knobs.Knobs{};
    by_hand.overlay(FakeEnv{ .pairs = &.{
        .{ "WIRE_EAT", "3,9" },  .{ "PEER_EAT", "2" },         .{ "WIRE_LATENCY_US", "250" },
        .{ "DISK_REFUSE", "4" }, .{ "DISK_WRITES_ONLY", "1" }, .{ "PEER_RESET_AT", "3000" },
        .{ "PEER_FLOOD", "4" },  .{ "PEER_MSS", "100" },       .{ "DISK_CUT_AFTER", "7" },
        .{ "DISK_TEAR", "2" },   .{ "DISK_TEAR_KEEP", "3" },
    } });
    var line = faults.Wire{};
    var drive = faults.Drive{};
    var rough = wire.Rough{};
    tellTheFaults(&line, &drive, &rough, &by_hand);
    try testing.expectEqualSlices(u32, &.{ 3, 9 }, line.lost.named[0..2]);
    try testing.expectEqual(@as(u32, 2), line.peer_lost.named[0]);
    try testing.expectEqual(@as(u64, 250 * std.time.ns_per_us), line.latency_ns);
    try testing.expectEqual(@as(u32, 4), drive.refused.named[0]);
    try testing.expect(drive.writes_only);
    try testing.expectEqual(@as(?u64, 7), drive.cut_after);
    try testing.expectEqual(@as(?u64, 2), drive.tear);
    try testing.expectEqual(@as(u64, 3), drive.tear_keep);
    try testing.expect(rough.retransmits); // the peer's frames may be lost
    try testing.expectEqual(@as(?u64, 3000 * std.time.ns_per_us), rough.reset_after_ns);
    try testing.expectEqual(@as(u8, 4), rough.flood);
    try testing.expectEqual(@as(?usize, 100), rough.mss);

    // A seed's schedule, applied, is its printed knobs applied by hand.
    var printed: [1024]u8 = undefined;
    for (0..50) |seed| {
        const drawn = knobs.Knobs.fromSeed(seed);
        var pairs: [knobs.names.len][2][]const u8 = undefined;
        var n: usize = 0;
        const text = drawn.format(&printed);
        if (!std.mem.eql(u8, text, "none")) {
            var each = std.mem.tokenizeScalar(u8, text, ' ');
            while (each.next()) |kv| : (n += 1) {
                const eq = std.mem.indexOfScalar(u8, kv, '=').?;
                pairs[n] = .{ kv[0..eq], kv[eq + 1 ..] };
            }
        }
        var again = knobs.Knobs{};
        again.overlay(FakeEnv{ .pairs = pairs[0..n] });
        var a_line = faults.Wire{};
        var a_drive = faults.Drive{};
        var a_rough = wire.Rough{};
        var b_line = faults.Wire{};
        var b_drive = faults.Drive{};
        var b_rough = wire.Rough{};
        tellTheFaults(&a_line, &a_drive, &a_rough, &drawn);
        tellTheFaults(&b_line, &b_drive, &b_rough, &again);
        try testing.expectEqual(a_rough, b_rough);
        try testing.expectEqual(a_line.latency_ns, b_line.latency_ns);
        try testing.expectEqualSlices(u32, &a_line.lost.named, &b_line.lost.named);
        try testing.expectEqual(a_line.lost.rate, b_line.lost.rate);
        try testing.expectEqualSlices(u32, &a_line.peer_lost.named, &b_line.peer_lost.named);
        try testing.expectEqualSlices(u32, &a_line.peer_damaged.named, &b_line.peer_damaged.named);
        try testing.expectEqualSlices(u32, &a_drive.refused.named, &b_drive.refused.named);
        try testing.expectEqual(a_drive.writes_only, b_drive.writes_only);
    }
}
