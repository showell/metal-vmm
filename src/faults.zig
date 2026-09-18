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
//! **THE DISK CAN REFUSE TO SERVE A REQUEST**, which is the same idea one
//! layer over: the guest's own `fat16.zig` turns a bad status byte into
//! `ReadFailed`, and those paths have almost certainly never run.
//!
//! **PICKING THE NTH IS THE INTERESTING KNOB**, more than a rate. A rate
//! explores randomly; a number explores systematically — lose the first, then
//! the second, then the third, and the table of what happened is a map of what
//! this guest can survive. `lossy.sh` and `flaky.sh` draw those maps.

const std = @import("std");

/// **WHICH ONES.** The same question for a frame on the wire and a request to
/// the disk, so it is asked in one place: this is the nth of them — was n
/// named, or does the rate say so?
///
/// Each user gets its own dice. A draw for the disk must not move the wire's
/// generator along, or turning one on would change what the other did.
pub const Schedule = struct {
    /// The ones to pick, counting from one. Zeroes mean nothing.
    named: [8]u32 = @splat(0),
    /// Or one in this many, drawn. Zero picks none, which is the default and
    /// what every probe in check.sh runs on.
    rate: u32 = 0,
    dice: std.Random.DefaultPrng,
    /// How many have gone past, and which ones were picked.
    seen: u64 = 0,
    picked: [8]u32 = @splat(0),
    picked_count: u64 = 0,

    pub fn init(seed: u64) Schedule {
        return .{ .dice = .init(seed) };
    }

    pub fn configured(self: *const Schedule) bool {
        return self.rate != 0 or self.named[0] != 0;
    }

    /// Counts one more, and answers whether it is chosen. Called once per
    /// candidate, in order, so the answer is a function of the run.
    pub fn picks(self: *Schedule) bool {
        self.seen += 1;
        var chosen = false;
        for (self.named) |n| {
            if (n != 0 and n == self.seen) chosen = true;
        }
        if (!chosen and self.rate != 0) chosen = self.dice.random().uintLessThan(u32, self.rate) == 0;
        if (!chosen) return false;
        if (self.picked_count < self.picked.len) self.picked[@intCast(self.picked_count)] = @intCast(self.seen);
        self.picked_count += 1;
        return true;
    }
};

/// As much as an ethernet frame can hold, which is all the peer ever sends.
const frame_bytes: usize = 1514;
/// How many frames can be in flight on the wire at once. A guest emptying a
/// whole HTTP response into one doorbell is answered segment by segment, and
/// every one of those answers waits here until the guest has a buffer free for
/// it, so this is deeper than the two the peer produces per frame.
const in_flight: usize = 64;

const Held = struct {
    due_ns: u64 = 0,
    len: usize = 0,
    bytes: [frame_bytes]u8 = undefined,
};

pub const Wire = struct {
    /// Which of the guest's frames never arrive. 1 is the first frame it ever
    /// sends.
    lost: Schedule = .init(0x77_69_72_65_64_69_63_65), // "wiredice"
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

    held: [in_flight]Held = @splat(.{}),
    /// The oldest frame in flight and the next free slot, as a ring.
    first: usize = 0,
    next: usize = 0,

    pub fn configured(self: *const Wire) bool {
        return self.lost.configured() or self.latency_ns != 0;
    }

    /// **DOES THE GUEST'S NEXT FRAME GET THERE?**
    pub fn carries(self: *Wire) bool {
        return !self.lost.picks();
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
    ///
    /// **IT STAYS ON THE WIRE UNTIL SOMEBODY TAKES IT.** The guest may have no
    /// receive buffer free at this instant — it posts them and recycles them
    /// as it polls, and a guest in the middle of emptying a response has not
    /// polled for a while. A real card in that position holds the frame in its
    /// FIFO for the microsecond it takes; dropping it instead invents a loss
    /// that nothing on this wire could have caused, and the guest pays a
    /// retransmission timeout for our impatience.
    pub fn ready(self: *Wire, now: u64) ?[]const u8 {
        if (self.first >= self.next) return null;
        const slot = &self.held[self.first % in_flight];
        if (slot.due_ns > now) return null;
        return slot.bytes[0..slot.len];
    }

    /// The frame `ready` offered has been delivered.
    pub fn take(self: *Wire) void {
        if (self.first < self.next) self.first += 1;
    }
};

// ── what can be checked without a guest ──────────────────────────────────────

const testing = std.testing;

test "the numbered frame is the one that goes missing" {
    var w = Wire{};
    w.lost.named[0] = 3;
    try testing.expect(w.carries());
    try testing.expect(w.carries());
    try testing.expect(!w.carries()); // the third
    try testing.expect(w.carries());
    try testing.expectEqual(@as(u64, 1), w.lost.picked_count);
    try testing.expectEqual(@as(u32, 3), w.lost.picked[0]);
}

test "a rate picks some and not all, and picks the same ones twice" {
    var a = Schedule.init(7);
    var b = Schedule.init(7);
    a.rate = 4;
    b.rate = 4;
    var from_a: [200]bool = undefined;
    var from_b: [200]bool = undefined;
    for (&from_a) |*x| x.* = a.picks();
    for (&from_b) |*x| x.* = b.picks();
    try testing.expectEqualSlices(bool, &from_a, &from_b);
    try testing.expect(a.picked_count > 20 and a.picked_count < 80); // one in four, loosely
}

test "two users of the same idea do not move each other's dice" {
    var wire = Wire{};
    var drive = Drive{};
    wire.lost.rate = 3;
    drive.refused.rate = 3;
    var alone: [60]bool = undefined;
    for (&alone) |*x| x.* = drive.serves(0, false);

    var together = Drive{};
    together.refused.rate = 3;
    var mixed: [60]bool = undefined;
    for (&mixed) |*x| {
        _ = wire.carries(); // the wire is busy at the same time
        x.* = together.serves(0, false);
    }
    try testing.expectEqualSlices(bool, &alone, &mixed);
}

test "the disk refuses the request it was told to refuse" {
    var d = Drive{};
    d.refused.named[0] = 2;
    try testing.expect(d.serves(10, false));
    try testing.expect(!d.serves(11, true));
    try testing.expect(d.serves(12, false));
    try testing.expectEqual(@as(u64, 1), d.refused.picked_count);
    // And it remembers what was being asked for, not just when.
    try testing.expectEqual(@as(u64, 11), d.sectors[0]);
    try testing.expectEqual(@as(u8, 'w'), d.kinds[0]);
}

test "a frame arrives when the wire says, and in the order it was sent" {
    var w = Wire{ .latency_ns = 1_000 };
    w.hold("first", 0);
    w.hold("second", 0);
    try testing.expect(w.ready(500) == null); // not yet
    try testing.expectEqualStrings("first", w.ready(1_000).?);
    // Still there until somebody takes it: the guest may have had no buffer.
    try testing.expectEqualStrings("first", w.ready(1_000).?);
    w.take();
    try testing.expectEqualStrings("second", w.ready(1_000).?);
    w.take();
    try testing.expect(w.ready(2_000) == null);
}

/// **THE DISK, WHEN IT WILL NOT.** virtio-blk answers every request with a
/// status byte, and the guest's own fat16.zig turns anything but "ok" into
/// `ReadFailed` or `WriteFailed` — paths that a disk which always works never
/// reaches.
pub const Drive = struct {
    /// Which of the guest's requests come back refused. 1 is the first request
    /// it ever makes, read or write.
    refused: Schedule = .init(0x64_69_73_6B_64_69_63_65), // "diskdice"
    /// **WHAT IT WAS ASKING FOR**, for the ones refused: a request number on
    /// its own says when, and a sector says what — which is the difference
    /// between "the 133rd read" and "the directory".
    sectors: [8]u64 = @splat(0),
    kinds: [8]u8 = @splat(0),

    pub fn configured(self: *const Drive) bool {
        return self.refused.configured();
    }

    /// **IS THIS ONE SERVED?** Called once per request, in order.
    pub fn serves(self: *Drive, sector: u64, writing: bool) bool {
        const at = self.refused.picked_count;
        if (!self.refused.picks()) return true;
        if (at < self.sectors.len) {
            self.sectors[@intCast(at)] = sector;
            self.kinds[@intCast(at)] = if (writing) 'w' else 'r';
        }
        return false;
    }
};

test "a wire with nothing configured is a wire that does nothing" {
    var w = Wire{};
    var d = Drive{};
    try testing.expect(!w.configured());
    try testing.expect(!d.configured());
    for (0..100) |_| try testing.expect(d.serves(0, false));
    for (0..100) |_| try testing.expect(w.carries());
    w.hold("now", 12345);
    try testing.expectEqualStrings("now", w.ready(12345).?);
}
