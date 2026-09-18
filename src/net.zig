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
//! What it answers so far is DHCP, because that is what a machine asks first.
//! The addresses are QEMU's user-mode network's, so a guest written against
//! those numbers cannot tell the difference — and the probe that prints them
//! can be compared against QEMU word for word.

const std = @import("std");
const virtio = @import("virtio.zig");

/// The gateway's hardware address, as QEMU's user-mode network uses it.
pub const peer_mac = [6]u8{ 0x52, 0x55, 0x0a, 0x00, 0x02, 0x02 };
/// What the guest's own card reports, from config space. QEMU's default, so
/// that a probe printing its MAC prints the same one either way.
pub const card_mac = [6]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };

pub const guest_ip = [4]u8{ 10, 0, 2, 15 };
pub const server_ip = [4]u8{ 10, 0, 2, 2 };
pub const dns_ip = [4]u8{ 10, 0, 2, 3 };
pub const netmask = [4]u8{ 255, 255, 255, 0 };
pub const broadcast_ip = [4]u8{ 255, 255, 255, 255 };

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
    scratch: [2048]u8 = undefined,

    pub fn device(self: *Net) virtio.Device {
        var d = virtio.Device{
            .id = virtio.device_id_net,
            .features_low = feature_mac,
            .context = self,
            .notified = notified,
        };
        @memcpy(d.config[0..6], &card_mac);
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
        const reply = self.answer(frame) orelse return;
        if (!self.deliver(d, ram, reply)) self.dropped += 1;
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

    /// What the machine on the other end says back, if anything.
    fn answer(self: *Net, frame: []const u8) ?[]const u8 {
        const request = dhcpIn(frame) orelse return null;
        return self.dhcpOut(request);
    }

    fn dhcpOut(self: *Net, request: Dhcp) ?[]const u8 {
        const kind: u8 = switch (request.kind) {
            msg_discover => msg_offer,
            msg_request => msg_ack,
            else => return null,
        };
        return writeDhcp(&self.scratch, request, kind);
    }
};

// ── reading what the guest said ──────────────────────────────────────────────

const ethertype_ipv4: u16 = 0x0800;
const proto_udp: u8 = 17;
const port_server: u16 = 67;
const port_client: u16 = 68;

const magic_cookie = [4]u8{ 0x63, 0x82, 0x53, 0x63 };
const opt_subnet_mask: u8 = 1;
const opt_router: u8 = 3;
const opt_dns: u8 = 6;
const opt_message_type: u8 = 53;
const opt_server_id: u8 = 54;
const opt_lease_time: u8 = 51;
const opt_end: u8 = 255;

const msg_discover: u8 = 1;
const msg_offer: u8 = 2;
const msg_request: u8 = 3;
const msg_ack: u8 = 5;

/// What this peer needs to remember from a request in order to answer it.
const Dhcp = struct {
    kind: u8,
    xid: [4]u8,
    mac: [6]u8,
    /// The guest sets this when it wants the answer broadcast, which it does
    /// before it has an address to be reached at.
    broadcast: bool,
};

/// A DHCP request inside an ethernet frame, or null for anything else on the
/// wire. Everything is bounds-checked: this is data from the guest.
fn dhcpIn(frame: []const u8) ?Dhcp {
    if (frame.len < 14 + 20 + 8 + 240) return null;
    if (readBe16(frame[12..14]) != ethertype_ipv4) return null;
    const ip = frame[14..];
    const ihl: usize = @as(usize, ip[0] & 0x0F) * 4;
    if (ip[0] >> 4 != 4 or ihl < 20 or ip.len < ihl + 8) return null;
    if (ip[9] != proto_udp) return null;
    const udp = ip[ihl..];
    if (readBe16(udp[2..4]) != port_server) return null;
    const payload = udp[8..];
    if (payload.len < 240) return null;
    if (payload[0] != 1) return null; // a request, not a reply
    if (!std.mem.eql(u8, payload[236..240], &magic_cookie)) return null;
    return .{
        .kind = option(payload, opt_message_type) orelse return null,
        .xid = payload[4..8].*,
        .mac = payload[28..34].*,
        .broadcast = readBe16(payload[10..12]) & 0x8000 != 0,
    };
}

/// One option's first byte, which is all any option this peer reads needs.
fn option(payload: []const u8, want: u8) ?u8 {
    var at: usize = 240;
    while (at + 1 < payload.len) {
        const code = payload[at];
        if (code == opt_end) return null;
        if (code == 0) {
            at += 1; // padding
            continue;
        }
        const len = payload[at + 1];
        if (at + 2 + len > payload.len) return null;
        if (code == want) return if (len >= 1) payload[at + 2] else null;
        at += 2 + len;
    }
    return null;
}

// ── writing what it says back ────────────────────────────────────────────────

fn writeDhcp(out: []u8, request: Dhcp, kind: u8) []const u8 {
    @memset(out[0 .. 14 + 20 + 8 + 300], 0);

    // The BOOTP reply, which starts after the three headers.
    const bootp = out[14 + 20 + 8 ..];
    bootp[0] = 2; // a reply
    bootp[1] = 1; // ethernet
    bootp[2] = 6; // six bytes of it
    @memcpy(bootp[4..8], &request.xid);
    if (request.broadcast) writeBe16(bootp[10..12], 0x8000);
    @memcpy(bootp[16..20], &guest_ip); // yiaddr: the address being handed out
    @memcpy(bootp[20..24], &server_ip); // siaddr
    @memcpy(bootp[28..34], &request.mac);
    @memcpy(bootp[236..240], &magic_cookie);

    var at: usize = 240;
    at = writeOption(bootp, at, opt_message_type, &.{kind});
    at = writeOption(bootp, at, opt_server_id, &server_ip);
    at = writeOption(bootp, at, opt_lease_time, &.{ 0, 1, 0x51, 0x80 }); // a day
    at = writeOption(bootp, at, opt_subnet_mask, &netmask);
    at = writeOption(bootp, at, opt_router, &server_ip);
    at = writeOption(bootp, at, opt_dns, &dns_ip);
    bootp[at] = opt_end;
    at += 1;

    return wrap(out, at);
}

fn writeOption(p: []u8, at: usize, code: u8, value: []const u8) usize {
    p[at] = code;
    p[at + 1] = @intCast(value.len);
    @memcpy(p[at + 2 ..][0..value.len], value);
    return at + 2 + value.len;
}

/// Puts the UDP, IP and ethernet headers in front of `payload_len` bytes of
/// BOOTP, and answers the whole frame.
///
/// **THE GUEST CHECKS THE IP HEADER'S CHECKSUM** and drops a frame whose sum
/// is wrong, so this is not optional. UDP's checksum is, over IPv4, and a zero
/// there means "not computed" — which is what QEMU's own server sends.
fn wrap(out: []u8, payload_len: usize) []const u8 {
    const udp_len = 8 + payload_len;
    const ip_len = 20 + udp_len;

    @memcpy(out[0..6], &card_mac);
    @memcpy(out[6..12], &peer_mac);
    writeBe16(out[12..14], ethertype_ipv4);

    const ip = out[14..][0..20];
    ip[0] = 0x45; // version 4, five words of header
    writeBe16(ip[2..4], @intCast(ip_len));
    ip[8] = 64; // time to live
    ip[9] = proto_udp;
    @memcpy(ip[12..16], &server_ip);
    @memcpy(ip[16..20], &broadcast_ip);
    writeBe16(ip[10..12], 0);
    writeBe16(ip[10..12], checksum(ip));

    const udp = out[34..][0..8];
    writeBe16(udp[0..2], port_server);
    writeBe16(udp[2..4], port_client);
    writeBe16(udp[4..6], @intCast(udp_len));
    writeBe16(udp[6..8], 0);

    return out[0 .. 14 + ip_len];
}

/// The one's-complement sum every IP header carries.
fn checksum(header: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < header.len) : (i += 2) sum += readBe16(header[i..][0..2]);
    if (i < header.len) sum += @as(u32, header[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xFFFF) + (sum >> 16);
    return ~@as(u16, @truncate(sum));
}

fn readBe16(bytes: *const [2]u8) u16 {
    return std.mem.readInt(u16, bytes, .big);
}

fn writeBe16(bytes: *[2]u8, value: u16) void {
    std.mem.writeInt(u16, bytes, value, .big);
}

// ── what can be checked without a guest ──────────────────────────────────────

const testing = std.testing;

/// A DISCOVER as the guest builds one, to feed the peer in tests.
fn fakeDiscover(out: []u8, kind: u8, mac: [6]u8, xid: [4]u8) []const u8 {
    @memset(out[0..400], 0);
    @memcpy(out[0..6], &[_]u8{0xFF} ** 6);
    @memcpy(out[6..12], &mac);
    writeBe16(out[12..14], ethertype_ipv4);
    const ip = out[14..][0..20];
    ip[0] = 0x45;
    ip[9] = proto_udp;
    writeBe16(ip[2..4], 20 + 8 + 244);
    const udp = out[34..][0..8];
    writeBe16(udp[0..2], port_client);
    writeBe16(udp[2..4], port_server);
    writeBe16(udp[4..6], 8 + 244);
    const bootp = out[42..];
    bootp[0] = 1;
    @memcpy(bootp[4..8], &xid);
    writeBe16(bootp[10..12], 0x8000);
    @memcpy(bootp[28..34], &mac);
    @memcpy(bootp[236..240], &magic_cookie);
    _ = writeOption(bootp, 240, opt_message_type, &.{kind});
    bootp[243] = opt_end;
    return out[0 .. 42 + 244];
}

test "a discover is answered with an offer of the address QEMU would offer" {
    var net = Net{};
    var request: [512]u8 = undefined;
    const frame = fakeDiscover(&request, msg_discover, card_mac, .{ 1, 2, 3, 4 });
    const reply = net.answer(frame).?;

    const bootp = reply[42..];
    try testing.expectEqual(@as(u8, 2), bootp[0]); // a reply
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, bootp[4..8]); // the same exchange
    try testing.expectEqualSlices(u8, &guest_ip, bootp[16..20]);
    try testing.expectEqualSlices(u8, &card_mac, bootp[28..34]);
    try testing.expectEqual(msg_offer, option(bootp, opt_message_type).?);
    // And the addresses the probe prints.
    try testing.expectEqual(@as(u8, 255), option(bootp, opt_subnet_mask).?);
    try testing.expectEqual(@as(u8, 10), option(bootp, opt_router).?);
    try testing.expectEqual(@as(u8, 10), option(bootp, opt_dns).?);
    try testing.expectEqual(@as(u8, 10), option(bootp, opt_server_id).?);
}

test "a request is acknowledged" {
    var net = Net{};
    var request: [512]u8 = undefined;
    const frame = fakeDiscover(&request, msg_request, card_mac, .{ 9, 9, 9, 9 });
    const reply = net.answer(frame).?;
    try testing.expectEqual(msg_ack, option(reply[42..], opt_message_type).?);
}

test "the header the guest checks adds up" {
    var net = Net{};
    var request: [512]u8 = undefined;
    const frame = fakeDiscover(&request, msg_discover, card_mac, .{ 0, 0, 0, 1 });
    const reply = net.answer(frame).?;
    // A correct header sums to zero when the checksum field is included.
    try testing.expectEqual(@as(u16, 0), checksum(reply[14..34]));
    try testing.expectEqual(@as(u16, ethertype_ipv4), readBe16(reply[12..14]));
    try testing.expectEqualSlices(u8, &card_mac, reply[0..6]); // to the guest
    try testing.expectEqualSlices(u8, &peer_mac, reply[6..12]); // from the gateway
}

test "anything that is not a DHCP request is not answered" {
    var net = Net{};
    var buf: [512]u8 = undefined;
    // An ARP frame, which this peer does not speak yet.
    @memset(buf[0..60], 0);
    writeBe16(buf[12..14], 0x0806);
    try testing.expect(net.answer(buf[0..60]) == null);
    // A frame too short to hold any of it.
    try testing.expect(net.answer(buf[0..20]) == null);
    // UDP to somewhere else.
    const frame = fakeDiscover(&buf, msg_discover, card_mac, .{ 1, 1, 1, 1 });
    writeBe16(@constCast(frame[36..38]), 9999);
    try testing.expect(net.answer(frame) == null);
}

test "a frame with nowhere to go is dropped, not lost track of" {
    var net = Net{};
    var blk_ram = [_]u8{0} ** 256;
    var d = net.device();
    // No receive buffers have been posted, so delivery fails and says so.
    try testing.expect(!net.deliver(&d, &blk_ram, &.{ 1, 2, 3 }));
}

test "the card reports the address the guest prints" {
    var net = Net{};
    var d = net.device();
    try testing.expectEqual(@as(u64, 0x54), d.read(0x101, 1));
    try testing.expectEqual(virtio.device_id_net, @as(u32, @intCast(d.read(0x008, 4))));
    // And it offers the feature the driver insists on.
    try testing.expectEqual(@as(u64, feature_mac), d.read(0x010, 4));
}
