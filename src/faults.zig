//! **WHAT THIS MACHINE IS ALLOWED TO DO TO ITS GUEST.**
//!
//! A hypervisor that owns every input can choose to be unhelpful, and a
//! deterministic one can do it to a recipe: this guest, this seed, this frame
//! number. That is the difference between "it failed once on Tuesday" and a
//! failure with a name.
//!
//! **THE WIRE CAN LOSE WHAT THE GUEST SENDS**, by number or by chance, and it
//! can make what comes back take time to arrive. It does not lose what the
//! peer sends: the peer (peer.zig) is a test fixture with no timers, so a
//! frame lost on the way in would only hang the run, which says nothing about
//! the guest. The guest is the side with a retransmission timer, and the point
//! is to make that timer do its job.
//!
//! **LOSING FRAME NUMBER N IS THE INTERESTING KNOB**, more than a loss rate.
//! A rate explores randomly; a number explores systematically — lose the
//! first, then the second, then the third, and the table of what happened is a
//! map of which frames this guest can survive losing. `lossy.sh` draws it.

const std = @import("std");

/// Not entropy.zig's seed. Drawing a random number for the wire must not move
/// the guest's own generator along, or turning the wire's dice on would change
/// every token the guest mints.
const seed: u64 = 0x77_69_72_65_64_69_63_65; // "wiredice"

/// As much as an ethernet frame can hold, which is all the peer ever sends.
const frame_bytes: usize = 1514;
/// How many frames can be in flight on the wire at once. The peer answers one
/// frame with at most two, so this is generous.
const in_flight: usize = 8;

const Held = struct {
    due_ns: u64 = 0,
    len: usize = 0,
    bytes: [frame_bytes]u8 = undefined,
};

pub const Wire = struct {
    /// Frame numbers the guest sends that never arrive — 1 is the first frame
    /// it ever sends. Zeroes mean nothing.
    lose: [8]u32 = @splat(0),
    /// Or one frame in this many, drawn. Zero is a wire that loses nothing,
    /// which is what every probe in check.sh runs on.
    loss: u32 = 0,
    /// How long a frame takes to reach the guest. Zero means it arrives in the
    /// same breath the guest's frame was sent, which is what the probes have
    /// always seen and what makes the peer look like a function call.
    ///
    /// **A GUEST THAT WAITS WITHOUT ASKING QUESTIONS WAITS FOREVER.** Time
    /// here is measured in exits (clock.zig), so a wait implemented by
    /// spinning on memory — gopher-metal's `dhcp.exchange` counts twenty
    /// million turns of the receive ring and never looks at a clock — does not
    /// advance it, and a frame held for a while is never due. Its TCP loops do
    /// check the clock, so they see latency as intended. This is a real limit
    /// of a machine whose clock is its guest's curiosity, not a bug to fix
    /// here: the fix is in the guest, and it is the same fix rtc.zig already
    /// had to make when its spin counts became hours under KVM.
    latency_ns: u64 = 0,

    dice: std.Random.DefaultPrng = .init(seed),
    /// Frames the guest has sent, counting from one.
    sent: u64 = 0,
    /// The numbers of the ones that did not make it, for the record.
    eaten: [8]u32 = @splat(0),
    eaten_count: u64 = 0,

    held: [in_flight]Held = @splat(.{}),
    /// The oldest frame in flight and the next free slot, as a ring.
    first: usize = 0,
    next: usize = 0,

    pub fn configured(self: *const Wire) bool {
        return self.loss != 0 or self.lose[0] != 0 or self.latency_ns != 0;
    }

    /// **DOES THE GUEST'S NEXT FRAME GET THERE?** Called once per frame, in
    /// order, so the answer is a function of the run and nothing else.
    pub fn carries(self: *Wire) bool {
        self.sent += 1;
        var lost = false;
        for (self.lose) |n| {
            if (n != 0 and n == self.sent) lost = true;
        }
        if (!lost and self.loss != 0) lost = self.dice.random().uintLessThan(u32, self.loss) == 0;
        if (!lost) return true;
        if (self.eaten_count < self.eaten.len) self.eaten[@intCast(self.eaten_count)] = @intCast(self.sent);
        self.eaten_count += 1;
        return false;
    }

    /// A frame from the peer, put on the wire. It arrives when the wire says,
    /// which with no latency is at once.
    pub fn hold(self: *Wire, bytes: []const u8, now: u64) void {
        if (bytes.len > frame_bytes) return;
        const slot = &self.held[self.next % in_flight];
        // A full wire drops the oldest rather than the newest, which is what a
        // queue that overflows does.
        if (self.next - self.first >= in_flight) self.first += 1;
        slot.due_ns = now + self.latency_ns;
        slot.len = bytes.len;
        @memcpy(slot.bytes[0..bytes.len], bytes);
        self.next += 1;
    }

    /// The next frame that has arrived, or nothing. In the order they were
    /// sent: a wire does not reorder unless it is asked to.
    pub fn due(self: *Wire, now: u64) ?[]const u8 {
        if (self.first >= self.next) return null;
        const slot = &self.held[self.first % in_flight];
        if (slot.due_ns > now) return null;
        self.first += 1;
        return slot.bytes[0..slot.len];
    }
};

// ── what can be checked without a guest ──────────────────────────────────────

const testing = std.testing;

test "the numbered frame is the one that goes missing" {
    var w = Wire{ .lose = .{ 3, 0, 0, 0, 0, 0, 0, 0 } };
    try testing.expect(w.carries());
    try testing.expect(w.carries());
    try testing.expect(!w.carries()); // the third
    try testing.expect(w.carries());
    try testing.expectEqual(@as(u64, 1), w.eaten_count);
    try testing.expectEqual(@as(u32, 3), w.eaten[0]);
}

test "a rate loses some and not all, and loses the same ones twice" {
    var a = Wire{ .loss = 4 };
    var b = Wire{ .loss = 4 };
    var lost_a: [200]bool = undefined;
    var lost_b: [200]bool = undefined;
    for (&lost_a) |*x| x.* = !a.carries();
    for (&lost_b) |*x| x.* = !b.carries();
    try testing.expectEqualSlices(bool, &lost_a, &lost_b);
    try testing.expect(a.eaten_count > 20 and a.eaten_count < 80); // one in four, loosely
}

test "a frame arrives when the wire says, and in the order it was sent" {
    var w = Wire{ .latency_ns = 1_000 };
    w.hold("first", 0);
    w.hold("second", 0);
    try testing.expect(w.due(500) == null); // not yet
    try testing.expectEqualStrings("first", w.due(1_000).?);
    try testing.expectEqualStrings("second", w.due(1_000).?);
    try testing.expect(w.due(2_000) == null);
}

test "a wire with nothing configured is a wire that does nothing" {
    var w = Wire{};
    try testing.expect(!w.configured());
    for (0..100) |_| try testing.expect(w.carries());
    w.hold("now", 12345);
    try testing.expectEqualStrings("now", w.due(12345).?);
}
