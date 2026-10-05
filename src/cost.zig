//! **WHAT A RUN COST, IN THE GUEST'S TIME.** The box measures wall time; an
//! explorer choosing among runs cares about the guest's own: how many exits
//! it took, of which kinds, how much of its time passed, how much traffic
//! and disk work it did. Every run that did anything ends with one line of
//! this on the error stream.
//!
//! **THE LONGEST STRETCH WITH NO EXIT IS THE LONGEST HALT.** Time here moves
//! only at an exit, one question at a time (clock.zig, `per_question_ns`),
//! so while the guest runs no stretch is longer than one question. Its time
//! jumps only across a halt, when the machine moves the clock to whatever
//! wakes it (main.zig, `rest`).

const std = @import("std");

pub const Kind = enum { port, clock, mmio, msr, halt, other };

pub const Cost = struct {
    exits: [std.enums.values(Kind).len]u64 = @splat(0),
    longest_halt_ns: u64 = 0,

    pub fn exit(self: *Cost, kind: Kind) void {
        self.exits[@intFromEnum(kind)] += 1;
    }

    /// A halt that moved the clock by `ns`.
    pub fn halted(self: *Cost, ns: u64) void {
        self.longest_halt_ns = @max(self.longest_halt_ns, ns);
    }

    pub fn total(self: *const Cost) u64 {
        var n: u64 = 0;
        for (self.exits) |e| n += e;
        return n;
    }

    fn of(self: *const Cost, kind: Kind) u64 {
        return self.exits[@intFromEnum(kind)];
    }

    /// What the run around these counts did, from the devices' own counts.
    pub const Traffic = struct {
        guest_ns: u64,
        frames_out: u64,
        frames_in: u64,
        disk_requests: u64,
    };

    /// The line, or null for a run that did nothing.
    pub fn line(self: *const Cost, buf: []u8, t: Traffic) ?[]const u8 {
        if (self.total() == 0) return null;
        return std.fmt.bufPrint(buf, "metal-vmm: cost: {d} exits (port {d}, clock {d}, mmio {d}, msr {d}, halt {d}, other {d}); {d}.{d:0>3} ms of guest time, the longest halt {d}.{d:0>3} ms; {d} frames out, {d} in; {d} disk requests\n", .{
            self.total(),                              self.of(.port),                                     self.of(.clock),
            self.of(.mmio),                            self.of(.msr),                                      self.of(.halt),
            self.of(.other),                           t.guest_ns / std.time.ns_per_ms,                    (t.guest_ns / std.time.ns_per_us) % 1000,
            self.longest_halt_ns / std.time.ns_per_ms, (self.longest_halt_ns / std.time.ns_per_us) % 1000, t.frames_out,
            t.frames_in,                               t.disk_requests,
        }) catch null;
    }
};

const testing = std.testing;

test "a run that did nothing says nothing" {
    const c = Cost{};
    var buf: [256]u8 = undefined;
    try testing.expect(c.line(&buf, .{ .guest_ns = 0, .frames_out = 0, .frames_in = 0, .disk_requests = 0 }) == null);
}

test "exits by kind, guest time, the longest halt, the traffic and the disk" {
    var c = Cost{};
    for (0..5) |_| c.exit(.port);
    for (0..40) |_| c.exit(.clock);
    for (0..3) |_| c.exit(.mmio);
    c.exit(.msr);
    c.exit(.halt);
    c.exit(.halt);
    c.halted(1_250_000);
    c.halted(400_000);
    var buf: [256]u8 = undefined;
    const got = c.line(&buf, .{ .guest_ns = 12_345_678, .frames_out = 7, .frames_in = 9, .disk_requests = 81 }).?;
    try testing.expectEqualStrings("metal-vmm: cost: 51 exits (port 5, clock 40, mmio 3, msr 1, halt 2, other 0); 12.345 ms of guest time, the longest halt 1.250 ms; 7 frames out, 9 in; 81 disk requests\n", got);
}
