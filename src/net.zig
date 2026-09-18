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
    /// Frames the guest sent, frames handed to the guest, and frames that had
    /// nowhere to go because the guest had posted no buffer.
    sent: u64 = 0,
    received: u64 = 0,
    dropped: u64 = 0,
    /// The machine at the other end of it.
    peer: wire.Peer = .{},

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
        while (d.take(ram, tx_queue, &links)) |chain| {
            if (chain.links.len > 0) self.speak(d, ram, virtio.buffer(ram, chain.links[0]));
            d.complete(ram, tx_queue, chain.head, 0);
        }
    }

    /// One frame from the guest: the virtio header, then the ethernet frame.
    /// If the peer has an answer, it goes back at once — the guest's receive
    /// buffers were posted before it ever transmitted.
    fn speak(self: *Net, d: *virtio.Device, ram: []u8, buf: []const u8) void {
        if (buf.len <= @sizeOf(Header)) return;
        self.sent += 1;
        const frame = buf[@sizeOf(Header)..];
        if (self.peer.answer(frame)) |reply| {
            if (!self.deliver(d, ram, reply)) self.dropped += 1;
        }
        // One frame arriving can mean two to send: see `Peer.more`.
        while (self.peer.more()) |another| {
            if (!self.deliver(d, ram, another)) self.dropped += 1;
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
        return self.deliver(d, ram, self.peer.open(request));
    }

    pub fn fetched(self: *const Net) *const wire.Tcp {
        return &self.peer.tcp;
    }
};

// ── what can be checked without a guest ──────────────────────────────────────

const testing = std.testing;

test "a frame with nowhere to go is dropped, not lost track of" {
    var card = Net{};
    var ram = [_]u8{0} ** 256;
    var d = card.device();
    // No receive buffers have been posted, so delivery fails and says so.
    try testing.expect(!card.deliver(&d, &ram, &.{ 1, 2, 3 }));
}

test "the card reports the address the guest prints, and the feature it wants" {
    var card = Net{};
    var d = card.device();
    try testing.expectEqual(@as(u64, 0x54), d.read(0x101, 1));
    try testing.expectEqual(virtio.device_id_net, @as(u32, @intCast(d.read(0x008, 4))));
    try testing.expectEqual(@as(u64, feature_mac), d.read(0x010, 4));
}
