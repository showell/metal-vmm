//! **THE FRAMES ON THE WIRE**, as the peer (peer.zig) builds and reads them:
//! the addresses QEMU's user-mode network uses, a TCP segment to the guest's
//! port 80 with the checksums the guest verifies, a TCP segment read out of a
//! frame, the IP and ethernet headers around both, and a closed port's reset.
//! And the hand-made frames the tests use, as the guest would send them.

const std = @import("std");

/// The gateway's hardware address, as QEMU's user-mode network uses it.
pub const peer_mac = [6]u8{ 0x52, 0x55, 0x0a, 0x00, 0x02, 0x02 };
/// What the guest's card reports from config space: QEMU's default, so a probe
/// that prints its MAC prints the same one either way.
pub const card_mac = [6]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };

pub const guest_ip = [4]u8{ 10, 0, 2, 15 };
pub const server_ip = [4]u8{ 10, 0, 2, 2 };
pub const dns_ip = [4]u8{ 10, 0, 2, 3 };
pub const netmask = [4]u8{ 255, 255, 255, 0 };
pub const broadcast_ip = [4]u8{ 255, 255, 255, 255 };

pub const flag_fin: u8 = 1;
pub const flag_syn: u8 = 2;
pub const flag_rst: u8 = 4;
pub const flag_psh: u8 = 8;
pub const flag_ack: u8 = 16;

/// One segment, as it arrived.
pub const Segment = struct {
    seq: u32,
    ack: u32,
    flags: u8,
    data: []const u8,
    src_port: u16,
    dst_port: u16,
    /// The MSS option, on a SYN that carries one (RFC 9293 §3.7.1).
    mss: ?u16 = null,
};

/// **THE MOST ONE SEGMENT CARRIES HERE**: an ethernet frame's 1500 bytes
/// less the IP and TCP headers. The peer sends no more, whatever the guest
/// announces.
pub const most_data: usize = 1460;
/// What a peer may send when the guest announced no MSS (RFC 9293 §3.7.1).
pub const default_mss: usize = 536;

/// The window it offers: one it never actually fills, or none.
pub const window_open: u16 = 64240;

/// **A CLOSED PORT'S ANSWER** (RFC 9293 §3.10.7.1): a reset for anything
/// but a reset, at the sequence number the segment acknowledged, or else
/// acknowledging all of it.
pub fn closedPort(s: Segment, out: []u8) ?[]const u8 {
    if (s.flags & flag_rst != 0) return null;
    if (s.flags & flag_ack != 0) return build(out, server_ip, s.dst_port, s.ack, 0, flag_rst, 0, "");
    const len: u32 = @intCast(s.data.len + @intFromBool(s.flags & flag_syn != 0) + @intFromBool(s.flags & flag_fin != 0));
    return build(out, server_ip, s.dst_port, 0, s.seq +% len, flag_rst | flag_ack, 0, "");
}

/// One TCP segment to the guest's port 80, in a frame.
pub fn build(out: []u8, from: [4]u8, port: u16, seq: u32, ack: u32, flags: u8, window: u16, data: []const u8) []const u8 {
    const tcp_len = 20 + data.len;
    const tcp = out[34..][0..tcp_len];
    @memset(tcp[0..20], 0);
    writeBe16(tcp[0..2], port);
    writeBe16(tcp[2..4], 80);
    writeBe32(tcp[4..8], seq);
    writeBe32(tcp[8..12], ack);
    tcp[12] = 5 << 4; // five words of header, no options
    tcp[13] = flags;
    writeBe16(tcp[14..16], window);
    @memcpy(tcp[20..][0..data.len], data);

    // **THE GUEST VERIFIES THIS ONE.** Its table counts a segment whose
    // checksum is wrong as damaged and drops it without a word, so a
    // client that got it wrong would simply hang.
    writeBe16(tcp[16..18], pseudoChecksum(from, guest_ip, 6, tcp));
    return wrap(out, 6, from, guest_ip, tcp_len);
}

/// The TCP segment inside a frame addressed to us, or null.
pub fn tcpIn(frame: []const u8) ?Segment {
    if (frame.len < 14 + 20 + 20) return null;
    if (readBe16(frame[12..14]) != ethertype_ipv4) return null;
    const ip = frame[14..];
    const ihl: usize = @as(usize, ip[0] & 0x0F) * 4;
    if (ip[0] >> 4 != 4 or ihl < 20 or ip.len < ihl) return null;
    if (ip[9] != 6) return null; // TCP
    const total: usize = readBe16(ip[2..4]);
    if (total < ihl + 20 or total > ip.len) return null;
    const tcp = ip[ihl..total];
    const offset: usize = @as(usize, tcp[12] >> 4) * 4;
    if (offset < 20 or offset > tcp.len) return null;
    return .{
        .seq = readBe32(tcp[4..8]),
        .ack = readBe32(tcp[8..12]),
        .flags = tcp[13],
        .data = tcp[offset..],
        .src_port = readBe16(tcp[0..2]),
        .dst_port = readBe16(tcp[2..4]),
        .mss = if (tcp[13] & flag_syn != 0) mssOption(tcp[20..offset]) else null,
    };
}

/// The MSS option among a SYN's options, if it is there and well formed.
fn mssOption(options: []const u8) ?u16 {
    var at: usize = 0;
    while (at < options.len) {
        switch (options[at]) {
            0 => return null, // the end of the list
            1 => at += 1, // padding
            else => {
                if (at + 1 >= options.len) return null;
                const len = options[at + 1];
                if (len < 2 or at + len > options.len) return null;
                if (options[at] == 2 and len == 4) return readBe16(options[at + 2 ..][0..2]);
                at += len;
            },
        }
    }
    return null;
}

pub const ethertype_ipv4: u16 = 0x0800;
pub const proto_udp: u8 = 17;

/// Puts the IP and ethernet headers in front of a payload already written at
/// offset 34, and answers the whole frame.
///
/// **THE GUEST CHECKS THE IP HEADER'S CHECKSUM** and drops a frame whose sum
/// is wrong without saying so, so this is not optional.
pub fn wrap(out: []u8, protocol: u8, from: [4]u8, to: [4]u8, payload_len: usize) []const u8 {
    const ip_len = 20 + payload_len;

    @memcpy(out[0..6], &card_mac);
    @memcpy(out[6..12], &peer_mac);
    writeBe16(out[12..14], ethertype_ipv4);

    const ip = out[14..][0..20];
    @memset(ip, 0);
    ip[0] = 0x45; // version 4, five words of header
    writeBe16(ip[2..4], @intCast(ip_len));
    ip[8] = 64; // time to live
    ip[9] = protocol;
    @memcpy(ip[12..16], &from);
    @memcpy(ip[16..20], &to);
    writeBe16(ip[10..12], checksum(ip));

    return out[0 .. 14 + ip_len];
}

/// The one's-complement sum an IP header carries.
pub fn checksum(header: []const u8) u16 {
    return finish(sum(header, 0));
}

/// TCP's checksum covers a pseudo-header of the addresses as well, which is
/// how a segment delivered to the wrong host is noticed.
pub fn pseudoChecksum(from: [4]u8, to: [4]u8, protocol: u8, segment: []const u8) u16 {
    var total: u32 = 0;
    total = sum(&from, total);
    total = sum(&to, total);
    total += protocol;
    total += @intCast(segment.len);
    return finish(sum(segment, total));
}

pub fn sum(bytes: []const u8, start: u32) u32 {
    var total = start;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) total += readBe16(bytes[i..][0..2]);
    if (i < bytes.len) total += @as(u32, bytes[i]) << 8;
    return total;
}

pub fn finish(total: u32) u16 {
    var t = total;
    while (t >> 16 != 0) t = (t & 0xFFFF) + (t >> 16);
    return ~@as(u16, @truncate(t));
}

pub fn readBe16(bytes: *const [2]u8) u16 {
    return std.mem.readInt(u16, bytes, .big);
}

pub fn readBe32(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, .big);
}

pub fn writeBe16(bytes: *[2]u8, value: u16) void {
    std.mem.writeInt(u16, bytes, value, .big);
}

pub fn writeBe32(bytes: *[4]u8, value: u32) void {
    std.mem.writeInt(u32, bytes, value, .big);
}

/// A segment as the guest's table would send one, so the client can be driven
/// through a whole exchange without a guest.
pub fn fakeSegment(out: []u8, flags: u8, seq: u32, ack: u32, data: []const u8) []const u8 {
    const tcp_len = 20 + data.len;
    const tcp = out[34..][0..tcp_len];
    @memset(tcp[0..20], 0);
    writeBe16(tcp[0..2], 80);
    writeBe16(tcp[2..4], 49152);
    writeBe32(tcp[4..8], seq);
    writeBe32(tcp[8..12], ack);
    tcp[12] = 5 << 4;
    tcp[13] = flags;
    writeBe16(tcp[14..16], 8192);
    @memcpy(tcp[20..][0..data.len], data);
    writeBe16(tcp[16..18], pseudoChecksum(guest_ip, server_ip, 6, tcp));
    return wrap(out, 6, guest_ip, server_ip, tcp_len);
}

/// A guest's SYN-ACK announcing `mss`, as gopher-metal's tcp.zig sends one.
pub fn fakeSynAck(out: []u8, seq: u32, ack: u32, mss: u16) []const u8 {
    const option = [4]u8{ 2, 4, @truncate(mss >> 8), @truncate(mss) };
    const frame = fakeSegment(out, flag_syn | flag_ack, seq, ack, &option);
    const tcp = out[34..frame.len];
    tcp[12] = 6 << 4; // the option is header, not data
    writeBe16(tcp[16..18], 0);
    writeBe16(tcp[16..18], pseudoChecksum(guest_ip, server_ip, 6, tcp));
    return frame;
}

/// A segment's TCP checksum adds up, as the guest checks it.
pub fn verifies(frame: []const u8) bool {
    const ip = frame[14..34];
    return pseudoChecksum(ip[12..16].*, ip[16..20].*, 6, frame[34..]) == 0;
}

/// A segment from the guest to client `port`.
pub fn fakeTo(out: []u8, port: u16, flags: u8, seq: u32, ack: u32, data: []const u8) []const u8 {
    const frame = fakeSegment(out, flags, seq, ack, data);
    writeBe16(out[34 + 2 ..][0..2], port);
    writeBe16(out[34 + 16 ..][0..2], 0);
    writeBe16(out[34 + 16 ..][0..2], pseudoChecksum(guest_ip, server_ip, 6, out[34..frame.len]));
    return frame;
}

test "a SYN's MSS option is read, and anything malformed is none" {
    var out: [128]u8 = undefined;
    const plain = fakeSegment(&out, flag_syn | flag_ack, 1, 2, "");
    try std.testing.expect(tcpIn(plain).?.mss == null);
    const announced = tcpIn(fakeSynAck(&out, 1, 2, 1460)).?;
    try std.testing.expectEqual(@as(?u16, 1460), announced.mss);
    try std.testing.expectEqualStrings("", announced.data);
    try std.testing.expect(verifies(fakeSynAck(&out, 1, 2, 1460)));
    // A guest's SYN-ACK with options: padding, the MSS, the end.
    const cases = [_]struct { options: []const u8, mss: ?u16 }{
        .{ .options = &.{ 2, 4, 0x05, 0xB4 }, .mss = 1460 },
        .{ .options = &.{ 1, 1, 1, 1, 2, 4, 0x02, 0x18, 0, 0, 0, 0 }, .mss = 536 },
        .{ .options = &.{ 3, 3, 7, 1, 2, 4, 0x01, 0x00 }, .mss = 256 },
        .{ .options = &.{ 2, 3, 5, 0 }, .mss = null },
        .{ .options = &.{ 9, 0, 2, 4 }, .mss = null },
        .{ .options = &.{ 2, 40, 1, 1 }, .mss = null },
        .{ .options = &.{ 0, 0, 2, 4, 1, 1, 0, 0 }, .mss = null },
    };
    for (cases) |c| {
        try std.testing.expectEqual(c.mss, mssOption(c.options));
    }
}
