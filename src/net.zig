//! **THE NETWORK DEVICE, AND THE MACHINE AT THE OTHER END OF THE WIRE.**
//!
//! virtio-net is two queues and an asymmetry: the driver fills the receive
//! queue with empty buffers and leaves them there, and puts one buffer on the
//! transmit queue whenever it has something to say. So a frame from the guest
//! is served the moment the doorbell rings, and a frame TO the guest is
//! written into a buffer that has been waiting.
//!
//! **THERE IS NO REAL NETWORK HERE, AND THAT IS THE POINT.** A tap device
//! would make the host's network an input this program does not control, which
//! is the one thing a deterministic machine cannot have. Instead the wire ends
//! at a peer written here: it answers what the guest asks, from a script, and
//! the same run happens the same way every time.
//!
//! What it says on that wire lives in `peer.zig`; this file is only the card.

const std = @import("std");
const virtio = @import("virtio.zig");
const wire = @import("peer.zig");
const faults = @import("faults.zig");

/// VIRTIO_NET_F_MAC: the card's address is in config space. The guest asks for
/// this one by name and refuses a device that does not offer it.
const feature_mac: u32 = 1 << 5;

/// **TWELVE BYTES IN FRONT OF EVERY FRAME, BOTH WAYS.** Under VERSION_1 the
/// header always carries `num_buffers`, whether or not buffers are merged.
const Header = extern struct {
    flags: u8 = 0,
    gso_type: u8 = 0,
    hdr_len: u16 = 0,
    gso_size: u16 = 0,
    csum_start: u16 = 0,
    csum_offset: u16 = 0,
    num_buffers: u16 = 1,
};

comptime {
    std.debug.assert(@sizeOf(Header) == 12);
}

const rx_queue: u32 = 0;
const tx_queue: u32 = 1;

pub const Net = struct {
    /// Frames the guest sent, frames handed to the guest, and the times a
    /// frame had to wait on the wire because the guest had no buffer free for
    /// it yet.
    sent: u64 = 0,
    received: u64 = 0,
    waited: u64 = 0,
    /// The machine at the other end of it.
    peer: wire.Peer = .{},
    /// **AND THE WIRE BETWEEN THEM**, which is allowed to be unhelpful — see
    /// faults.zig. Left alone it loses nothing and delays nothing.
    line: faults.Wire = .{},
    /// The machine's time as of this exit. The pump sets it at the top of
    /// every exit, so a doorbell handled later in the same exit has the right
    /// answer without being handed one.
    now: u64 = 0,

    pub fn device(self: *Net) virtio.Device {
        var d = virtio.Device{
            .id = virtio.device_id_net,
            .features_low = feature_mac,
            .context = self,
            .notified = notified,
        };
        @memcpy(d.config[0..6], &wire.card_mac);
        return d;
    }

    fn notified(context: *anyopaque, d: *virtio.Device, ram: []u8, queue: u32) void {
        const self: *Net = @ptrCast(@alignCast(context));
        if (queue != tx_queue) return; // receive buffers are parked, not served
        var links: [4]virtio.Desc = undefined;
        var left = d.budget(tx_queue);
        while (left > 0) : (left -= 1) {
            const chain = d.take(ram, tx_queue, &links) orelse break;
            if (chain.links.len > 0) self.speak(d, ram, virtio.buffer(ram, chain.links[0]));
            d.complete(ram, tx_queue, chain.head, 0);
        }
    }

    /// One frame from the guest: the virtio header, then the ethernet frame.
    /// **THE WIRE GETS A SAY BEFORE THE PEER DOES** — a frame it eats never
    /// happened, and the guest's own retransmission timer is what has to
    /// notice.
    fn speak(self: *Net, d: *virtio.Device, ram: []u8, buf: []const u8) void {
        if (buf.len <= @sizeOf(Header)) return;
        self.sent += 1;
        if (!self.line.carries()) return;
        const frame = buf[@sizeOf(Header)..];
        if (self.peer.answer(frame, self.now)) |reply| self.line.hold(reply, self.now);
        // One frame arriving can mean more to send (`Peer.more`): as many as
        // the wire has room for, and `pump` sends the rest as the guest takes
        // frames. All at once, a request in more segments than the wire holds
        // pushed out its own first ones, and a peer that never resends (no
        // fault turned) waited forever: a head of 65 segments was never
        // answered (2026-10-09, PEER_MSS=2).
        while (self.line.room() > 0) {
            const another = self.peer.more(self.now) orelse break;
            self.line.hold(another, self.now);
        }
        self.arrivals(d, ram);
    }

    /// **THE MACHINE'S HEARTBEAT FOR THIS DEVICE.** The guest polls memory, so
    /// a frame that is not delivered during an exit is not delivered at all.
    /// Every exit is therefore an opportunity, and this takes it.
    pub fn pump(self: *Net, d: *virtio.Device, ram: []u8, now: u64) void {
        self.now = now;
        // What the peer says unspoken to — a timer of its own, a flood, a
        // reset — goes on the wire first, at this instant, **AS FAR AS THE
        // WIRE HAS ROOM**: what is left waits for the guest to take frames,
        // rather than pushing out ones already in flight.
        while (self.line.room() > 0) {
            const frame = self.peer.due(now) orelse break;
            self.line.hold(frame, now);
        }
        // What the peer had more to send when the wire was full.
        while (self.line.room() > 0) {
            const frame = self.peer.more(now) orelse break;
            self.line.hold(frame, now);
        }
        self.arrivals(d, ram);
    }

    /// **WHEN SOMETHING NEXT HAPPENS ON THIS SIDE OF THE WIRE**, strictly
    /// after `now`, once `pump` has run at `now`: a frame arriving, or the
    /// peer acting on its own. A frame due already and still waiting has no
    /// buffer to go to, and waits for the guest, not the clock; so does
    /// the peer, when it is due already and the wire was full.
    pub fn nextDue(self: *const Net, now: u64) ?u64 {
        var at = self.peer.wakeAt();
        if (at) |a| if (a <= now) {
            at = null;
        };
        if (self.line.nextDue()) |due| if (due > now) {
            at = if (at) |a| @min(a, due) else due;
        };
        return at;
    }

    /// Everything the wire has finished carrying, into the guest's parked
    /// buffers — as far as the guest has buffers. **A FRAME THE GUEST CANNOT
    /// TAKE YET STAYS ON THE WIRE**; the next exit is another chance, and
    /// there are ten thousand of those a second.
    fn arrivals(self: *Net, d: *virtio.Device, ram: []u8) void {
        while (self.line.ready(self.now)) |frame| {
            if (!self.deliver(d, ram, frame)) {
                self.waited += 1;
                return;
            }
            self.line.take();
        }
    }

    /// Writes a frame into the next receive buffer the guest posted. False
    /// when it has posted none, which is a dropped frame and not an error —
    /// it is what a real card does when the driver falls behind.
    pub fn deliver(self: *Net, d: *virtio.Device, ram: []u8, frame: []const u8) bool {
        var links: [4]virtio.Desc = undefined;
        const chain = d.take(ram, rx_queue, &links) orelse return false;
        if (chain.links.len == 0) return false;
        const into = virtio.buffer(ram, chain.links[0]);
        if (into.len < @sizeOf(Header) + frame.len) {
            d.complete(ram, rx_queue, chain.head, 0);
            return false;
        }
        const header = Header{};
        @memcpy(into[0..@sizeOf(Header)], std.mem.asBytes(&header));
        @memcpy(into[@sizeOf(Header)..][0..frame.len], frame);
        d.complete(ram, rx_queue, chain.head, @intCast(@sizeOf(Header) + frame.len));
        self.received += 1;
        return true;
    }

    /// **THE GUEST IS LISTENING; GO AND ASK IT SOMETHING.** Nothing else in
    /// this program opens a connection, because a client that started on its
    /// own would race the guest's own setup.
    pub fn connect(self: *Net, d: *virtio.Device, ram: []u8, request: []const u8) bool {
        self.line.hold(self.peer.open(request, self.now), self.now);
        self.arrivals(d, ram);
        return true;
    }

    pub fn fetched(self: *const Net) *const wire.Tcp {
        return &self.peer.tcp;
    }
};

// ── what can be checked without a guest ──────────────────────────────────────

const testing = std.testing;

test "a frame with nowhere to go waits on the wire rather than vanishing" {
    var card = Net{};
    var ram = [_]u8{0} ** 256;
    var d = card.device();
    // No receive buffers have been posted, so delivery fails and says so...
    try testing.expect(!card.deliver(&d, &ram, &.{ 1, 2, 3 }));
    // ...and a frame the wire is carrying is still there afterwards.
    card.line.hold(&.{ 1, 2, 3 }, 0);
    card.arrivals(&d, &ram);
    try testing.expectEqual(@as(u64, 1), card.waited);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, card.line.ready(0).?);
}

test "the card reports the address the guest prints, and the feature it wants" {
    var card = Net{};
    var d = card.device();
    try testing.expectEqual(@as(u64, 0x54), d.read(0x101, 1));
    try testing.expectEqual(virtio.device_id_net, @as(u32, @intCast(d.read(0x008, 4))));
    try testing.expectEqual(@as(u64, feature_mac), d.read(0x010, 4));
}

test "the wire loses the peer's nth frame, and damages another so its checksum fails" {
    var card = Net{};
    card.line.peer_lost.named[0] = .one(1);
    card.line.peer_damaged.named[0] = .one(2);
    var p = wire.Peer{};
    const syn = p.open("GET", 0);
    card.line.hold(syn, 0); // the first: lost
    try testing.expect(card.line.ready(0) == null);
    card.line.hold(syn, 0); // the second: damaged
    const got = card.line.ready(0).?;
    try testing.expect(!std.mem.eql(u8, got, syn));
    try testing.expectEqualSlices(u8, syn[0..50], got[0..50]); // only the checksum's byte
    card.line.take();
    card.line.hold(syn, 0); // the third: as sent
    try testing.expectEqualSlices(u8, syn, card.line.ready(0).?);
    try testing.expect(card.line.hurtsPeer());
}

test "the next thing on this side: the peer's own timer, past a frame stuck for want of a buffer" {
    var card = Net{};
    card.peer.rough = .{ .retransmits = true };
    var ram = [_]u8{0} ** 256;
    var d = card.device();
    _ = card.connect(&d, &ram, "GET");
    // The SYN has no buffer to go to: due now, it waits for the guest.
    try testing.expectEqual(@as(?u64, 0), card.line.nextDue());
    try testing.expectEqual(@as(?u64, std.time.ns_per_s), card.nextDue(0));
    // At the timer, the pump puts the SYN on the wire again.
    card.pump(&d, &ram, std.time.ns_per_s);
    card.line.take();
    try testing.expect(card.line.ready(std.time.ns_per_s) != null);
    try testing.expectEqual(@as(?u64, 3 * std.time.ns_per_s), card.nextDue(std.time.ns_per_s));
}

test "with nothing configured, nothing on this side ever happens on its own" {
    var card = Net{};
    var ram = [_]u8{0} ** 256;
    var d = card.device();
    _ = card.connect(&d, &ram, "GET");
    try testing.expect(card.nextDue(0) == null);
    card.pump(&d, &ram, 1000 * std.time.ns_per_s);
    try testing.expect(card.nextDue(1000 * std.time.ns_per_s) == null);
}

test "the peer sends no faster than the wire has room, and waits for the guest without stalling a halt" {
    var card = Net{};
    card.peer.rough = .{ .flood = 200, .flood_gap_ns = 0 };
    var ram = [_]u8{0} ** 256;
    var d = card.device();
    _ = card.connect(&d, &ram, "GET"); // the client's SYN: one frame in flight
    card.pump(&d, &ram, 0);
    try testing.expectEqual(@as(usize, 0), card.line.room()); // full, none pushed out
    try testing.expectEqual(@as(u32, 63), card.peer.flooded);
    // The rest are due already, and wait for room: nothing for a halt to
    // move the clock to.
    try testing.expect(card.nextDue(0) == null);
    for (0..10) |_| card.line.take();
    card.pump(&d, &ram, 1);
    try testing.expectEqual(@as(u32, 73), card.peer.flooded);
}

test "a request in more segments than the wire holds goes as the guest takes them, none pushed out" {
    const frames = @import("frames.zig");
    var card = Net{};
    card.peer.rough.mss = 2;
    var ram = [_]u8{0} ** 256;
    var d = card.device();
    const request: [130]u8 = @splat('a');
    _ = card.connect(&d, &ram, &request);
    const syn = frames.tcpIn(card.line.ready(0).?).?;
    card.line.take();
    var theirs: [2048]u8 = undefined;
    var buf: [@sizeOf(Header) + 2048]u8 = @splat(0);
    const syn_ack = frames.fakeSynAck(&theirs, 5000, syn.seq +% 1, 1460);
    @memcpy(buf[@sizeOf(Header)..][0..syn_ack.len], syn_ack);
    card.speak(&d, &ram, buf[0 .. @sizeOf(Header) + syn_ack.len]);
    // The guest takes each frame as it comes; the peer sends on as it does.
    var got: usize = 0;
    while (card.line.ready(0)) |frame| {
        if (frames.tcpIn(frame)) |seg| got += seg.data.len;
        card.line.take();
        card.pump(&d, &ram, 0);
    }
    try testing.expectEqual(@as(u64, 0), card.line.pushed_out);
    try testing.expectEqual(request.len, got);
}

test "an answer to the guest while the wire is full waits for room too, none pushed out (metal-vmm QUEUE 122)" {
    // `speak` kept the peer's later frames to the wire's room, and put its
    // answer to this frame on regardless: with the wire full of the
    // request, the guest sending its SYN-ACK again pushed out a segment of
    // it, which a peer that never resends never sends again.
    const frames = @import("frames.zig");
    var card = Net{};
    card.peer.rough.mss = 2;
    var ram = [_]u8{0} ** 256;
    var d = card.device();
    const request: [400]u8 = @splat('a');
    _ = card.connect(&d, &ram, &request);
    const syn = frames.tcpIn(card.line.ready(0).?).?;
    card.line.take();
    var theirs: [2048]u8 = undefined;
    var buf: [@sizeOf(Header) + 2048]u8 = @splat(0);
    const syn_ack = frames.fakeSynAck(&theirs, 5000, syn.seq +% 1, 1460);
    @memcpy(buf[@sizeOf(Header)..][0..syn_ack.len], syn_ack);
    card.speak(&d, &ram, buf[0 .. @sizeOf(Header) + syn_ack.len]);
    try testing.expectEqual(@as(usize, 0), card.line.room());
    // The guest takes the peer's bare ACK and nothing more: the oldest frame
    // left is the request's first segment, and the wire has one slot. The
    // peer's next frame takes it, and the wire is full again.
    card.line.take();
    card.pump(&d, &ram, 0);
    try testing.expectEqual(@as(usize, 0), card.line.room());
    card.speak(&d, &ram, buf[0 .. @sizeOf(Header) + syn_ack.len]);
    try testing.expectEqual(@as(u64, 0), card.line.pushed_out);
    var got: usize = 0;
    while (card.line.ready(0)) |frame| {
        if (frames.tcpIn(frame)) |seg| got += seg.data.len;
        card.line.take();
        card.pump(&d, &ram, 0);
    }
    try testing.expect(got >= request.len);
}
