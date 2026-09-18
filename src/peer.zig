//! **THE MACHINE AT THE OTHER END OF THE WIRE**, which is this program.
//!
//! There is no tap device and no real network here, deliberately: a host's
//! network is an input we do not control, and control over every input is the
//! whole point of the thing this is a step of. So the wire ends at a peer that
//! answers from what is written here — DHCP when the guest asks for an
//! address, and TCP when we decide to fetch something from it.
//!
//! **IT IS A CLIENT, NOT A SERVER.** The guest listens; this connects to it,
//! which is what the HTTP probes are for. Nothing here opens a connection on
//! its own: `open` is called when the guest says it is listening, exactly as
//! gopher-metal's own judge waits for that line before it connects.
//!
//! The numbers are QEMU's user-mode network's, so a guest written against
//! those cannot tell the difference and its printed output can be compared
//! against a QEMU run word for word.

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

pub const Peer = struct {
    tcp: Tcp = .{},
    scratch: [2048]u8 = undefined,

    /// What the peer says back to one frame, or nothing.
    pub fn answer(self: *Peer, frame: []const u8) ?[]const u8 {
        if (dhcpIn(frame)) |request| return self.dhcpOut(request);
        if (tcpIn(frame)) |segment| return self.tcp.receive(segment, &self.scratch);
        return null;
    }

    /// Opens a connection to the guest and asks it for something. The answer
    /// arrives over the frames that follow.
    pub fn open(self: *Peer, request: []const u8) []const u8 {
        return self.tcp.open(request, &self.scratch);
    }

    /// Anything else to say right now, after an answer. See `Tcp.more`.
    pub fn more(self: *Peer) ?[]const u8 {
        return self.tcp.more(&self.scratch);
    }

    fn dhcpOut(self: *Peer, request: Dhcp) ?[]const u8 {
        const kind: u8 = switch (request.kind) {
            msg_discover => msg_offer,
            msg_request => msg_ack,
            else => return null,
        };
        return writeDhcp(&self.scratch, request, kind);
    }
};

// ── TCP, from the client's side ──────────────────────────────────────────────

const flag_fin: u8 = 1;
const flag_syn: u8 = 2;
const flag_rst: u8 = 4;
const flag_psh: u8 = 8;
const flag_ack: u8 = 16;

/// One segment, as it arrived.
const Segment = struct {
    seq: u32,
    ack: u32,
    flags: u8,
    data: []const u8,
    src_port: u16,
    dst_port: u16,
};

/// A client that fetches one thing and then closes, which is all the probes
/// ask of it. **Sequence numbers are counted, not guessed**: the guest's table
/// checks them, refuses a segment that is not the next one, and answers a
/// reset for a connection it does not know — so a client that drifts is told
/// about it immediately rather than hanging.
pub const Tcp = struct {
    pub const State = enum { idle, syn_sent, established, closing, done, refused };

    state: State = .idle,
    /// A fixed port and a fixed first sequence number, because two runs of the
    /// same guest should look the same on the wire.
    port: u16 = 49152,
    seq: u32 = 1000,
    ack: u32 = 0,
    request: []const u8 = "",
    /// **THE REQUEST GOES IN ITS OWN SEGMENT**, after the handshake's last
    /// acknowledgement rather than riding along with it. Both are legal, and
    /// an ordinary client does the second — which matters, because a guest
    /// whose table reports "the connection opened" and "data arrived" as
    /// different events may only look at the buffer on the second.
    owes_request: bool = false,
    reply: [64 * 1024]u8 = undefined,
    reply_len: usize = 0,

    pub fn open(self: *Tcp, request: []const u8, out: []u8) []const u8 {
        self.* = .{ .state = .syn_sent, .request = request };
        return self.segment(out, flag_syn, "");
    }

    /// What this client says back to one segment, if anything.
    pub fn receive(self: *Tcp, s: Segment, out: []u8) ?[]const u8 {
        if (s.dst_port != self.port) return null;
        if (s.flags & flag_rst != 0) {
            self.state = .refused;
            return null;
        }
        switch (self.state) {
            .syn_sent => {
                if (s.flags & flag_syn == 0 or s.flags & flag_ack == 0) return null;
                self.seq +%= 1; // our SYN took one
                self.ack = s.seq +% 1; // theirs did too
                self.state = .established;
                self.owes_request = true;
                return self.segment(out, flag_ack, "");
            },
            .established, .closing => {
                // **IN ORDER ONLY.** Anything else is re-acknowledged, which
                // asks for what we are missing — the same rule the guest's own
                // table follows.
                if (s.seq != self.ack) return self.segment(out, flag_ack, "");
                if (s.data.len > 0) {
                    const room = self.reply.len - self.reply_len;
                    const n = @min(room, s.data.len);
                    @memcpy(self.reply[self.reply_len..][0..n], s.data[0..n]);
                    self.reply_len += n;
                    self.ack +%= @intCast(s.data.len);
                }
                if (s.flags & flag_fin != 0) {
                    self.ack +%= 1; // their FIN takes one
                    if (self.state != .closing) {
                        self.state = .closing;
                        const frame = self.segment(out, flag_fin | flag_ack, "");
                        self.seq +%= 1;
                        return frame;
                    }
                    self.state = .done;
                    return self.segment(out, flag_ack, "");
                }
                if (s.data.len > 0) return self.segment(out, flag_ack, "");
                // An acknowledgement of our FIN and nothing else: we are done.
                if (self.state == .closing and s.flags & flag_ack != 0) self.state = .done;
                return null;
            },
            else => return null,
        }
    }

    /// The next thing this client has to say without being spoken to, if
    /// anything. Called after every answer, because one thing arriving can
    /// mean two things to send.
    pub fn more(self: *Tcp, out: []u8) ?[]const u8 {
        if (!self.owes_request or self.state != .established) return null;
        self.owes_request = false;
        const frame = self.segment(out, flag_ack | flag_psh, self.request);
        self.seq +%= @intCast(self.request.len);
        return frame;
    }

    /// Everything that came back, status line and headers included — which is
    /// what a caller checking a redirect's Location needs.
    pub fn whole(self: *const Tcp) []const u8 {
        return self.reply[0..self.reply_len];
    }

    /// What came back, headers and all.
    pub fn body(self: *const Tcp) []const u8 {
        const all = self.reply[0..self.reply_len];
        const at = std.mem.indexOf(u8, all, "\r\n\r\n") orelse return "";
        return all[at + 4 ..];
    }

    /// The status line's code, or zero if there is not one.
    pub fn status(self: *const Tcp) u16 {
        const all = self.reply[0..self.reply_len];
        const space = std.mem.indexOfScalar(u8, all, ' ') orelse return 0;
        if (space + 4 > all.len) return 0;
        return std.fmt.parseInt(u16, all[space + 1 ..][0..3], 10) catch 0;
    }

    fn segment(self: *Tcp, out: []u8, flags: u8, data: []const u8) []const u8 {
        const tcp_len = 20 + data.len;
        const tcp = out[34..][0..tcp_len];
        @memset(tcp[0..20], 0);
        writeBe16(tcp[0..2], self.port);
        writeBe16(tcp[2..4], 80);
        writeBe32(tcp[4..8], self.seq);
        writeBe32(tcp[8..12], self.ack);
        tcp[12] = 5 << 4; // five words of header, no options
        tcp[13] = flags;
        writeBe16(tcp[14..16], 64240); // a window we never actually fill
        @memcpy(tcp[20..][0..data.len], data);

        // **THE GUEST VERIFIES THIS ONE.** Its table counts a segment whose
        // checksum is wrong as damaged and drops it without a word, so a
        // client that got it wrong would simply hang.
        writeBe16(tcp[16..18], pseudoChecksum(server_ip, guest_ip, 6, tcp));
        return wrap(out, 6, server_ip, guest_ip, tcp_len);
    }
};

/// The TCP segment inside a frame addressed to us, or null.
fn tcpIn(frame: []const u8) ?Segment {
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
    };
}

// ── DHCP ─────────────────────────────────────────────────────────────────────

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

const port_server: u16 = 67;
const port_client: u16 = 68;

/// What this peer needs to remember from a request in order to answer it.
const Dhcp = struct {
    kind: u8,
    xid: [4]u8,
    mac: [6]u8,
    /// Set by a guest that has no address yet and so cannot be reached at one.
    broadcast: bool,
};

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

fn writeDhcp(out: []u8, request: Dhcp, kind: u8) []const u8 {
    @memset(out[0 .. 14 + 20 + 8 + 300], 0);

    const bootp = out[14 + 20 + 8 ..];
    bootp[0] = 2; // a reply
    bootp[1] = 1; // ethernet
    bootp[2] = 6; // six bytes of it
    @memcpy(bootp[4..8], &request.xid);
    if (request.broadcast) writeBe16(bootp[10..12], 0x8000);
    @memcpy(bootp[16..20], &guest_ip); // yiaddr: the address handed out
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

    const udp_len = 8 + at;
    const udp = out[34..][0..8];
    writeBe16(udp[0..2], port_server);
    writeBe16(udp[2..4], port_client);
    writeBe16(udp[4..6], @intCast(udp_len));
    writeBe16(udp[6..8], 0); // not computed, which IPv4 allows and QEMU does
    return wrap(out, proto_udp, server_ip, broadcast_ip, udp_len);
}

fn writeOption(p: []u8, at: usize, code: u8, value: []const u8) usize {
    p[at] = code;
    p[at + 1] = @intCast(value.len);
    @memcpy(p[at + 2 ..][0..value.len], value);
    return at + 2 + value.len;
}

// ── the headers every frame here carries ─────────────────────────────────────

const ethertype_ipv4: u16 = 0x0800;
const proto_udp: u8 = 17;

/// Puts the IP and ethernet headers in front of a payload already written at
/// offset 34, and answers the whole frame.
///
/// **THE GUEST CHECKS THE IP HEADER'S CHECKSUM** and drops a frame whose sum
/// is wrong without saying so, so this is not optional.
fn wrap(out: []u8, protocol: u8, from: [4]u8, to: [4]u8, payload_len: usize) []const u8 {
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
fn checksum(header: []const u8) u16 {
    return finish(sum(header, 0));
}

/// TCP's checksum covers a pseudo-header of the addresses as well, which is
/// how a segment delivered to the wrong host is noticed.
fn pseudoChecksum(from: [4]u8, to: [4]u8, protocol: u8, segment: []const u8) u16 {
    var total: u32 = 0;
    total = sum(&from, total);
    total = sum(&to, total);
    total += protocol;
    total += @intCast(segment.len);
    return finish(sum(segment, total));
}

fn sum(bytes: []const u8, start: u32) u32 {
    var total = start;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) total += readBe16(bytes[i..][0..2]);
    if (i < bytes.len) total += @as(u32, bytes[i]) << 8;
    return total;
}

fn finish(total: u32) u16 {
    var t = total;
    while (t >> 16 != 0) t = (t & 0xFFFF) + (t >> 16);
    return ~@as(u16, @truncate(t));
}

fn readBe16(bytes: *const [2]u8) u16 {
    return std.mem.readInt(u16, bytes, .big);
}

fn readBe32(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, .big);
}

fn writeBe16(bytes: *[2]u8, value: u16) void {
    std.mem.writeInt(u16, bytes, value, .big);
}

fn writeBe32(bytes: *[4]u8, value: u32) void {
    std.mem.writeInt(u32, bytes, value, .big);
}

// ── what can be checked without a guest ──────────────────────────────────────

const testing = std.testing;

/// A DHCP request as the guest builds one.
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

/// A segment as the guest's table would send one, so the client can be driven
/// through a whole exchange without a guest.
fn fakeSegment(out: []u8, flags: u8, seq: u32, ack: u32, data: []const u8) []const u8 {
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

test "a discover is answered with the lease QEMU would hand out" {
    var peer = Peer{};
    var request: [512]u8 = undefined;
    const reply = peer.answer(fakeDiscover(&request, msg_discover, card_mac, .{ 1, 2, 3, 4 })).?;
    const bootp = reply[42..];
    try testing.expectEqual(@as(u8, 2), bootp[0]);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, bootp[4..8]);
    try testing.expectEqualSlices(u8, &guest_ip, bootp[16..20]);
    try testing.expectEqual(msg_offer, option(bootp, opt_message_type).?);
    try testing.expectEqual(@as(u8, 255), option(bootp, opt_subnet_mask).?);
    try testing.expectEqual(@as(u8, 10), option(bootp, opt_server_id).?);
}

test "a request is acknowledged, and the headers the guest checks add up" {
    var peer = Peer{};
    var request: [512]u8 = undefined;
    const reply = peer.answer(fakeDiscover(&request, msg_request, card_mac, .{ 9, 9, 9, 9 })).?;
    try testing.expectEqual(msg_ack, option(reply[42..], opt_message_type).?);
    try testing.expectEqual(@as(u16, 0), checksum(reply[14..34])); // a good header sums to zero
}

test "the whole fetch: a handshake, a request, an answer, and a close" {
    var peer = Peer{};
    var theirs: [2048]u8 = undefined;

    // The client opens with a SYN.
    const syn = peer.open("GET /probe HTTP/1.1\r\n\r\n");
    const syn_tcp = tcpIn(syn).?;
    try testing.expectEqual(flag_syn, syn_tcp.flags);
    try testing.expectEqual(@as(u16, 80), syn_tcp.dst_port);

    // The guest answers it, and the request rides our last acknowledgement.
    const their_isn: u32 = 5000;
    const ack = peer.answer(fakeSegment(&theirs, flag_syn | flag_ack, their_isn, syn_tcp.seq +% 1, "")).?;
    const ack_tcp = tcpIn(ack).?;
    try testing.expect(ack_tcp.flags & flag_ack != 0);
    try testing.expectEqual(their_isn +% 1, ack_tcp.ack);
    try testing.expectEqualStrings("", ack_tcp.data); // the handshake's own ACK carries nothing

    // And then the request, in a segment of its own.
    const asked = tcpIn(peer.more().?).?;
    try testing.expectEqualStrings("GET /probe HTTP/1.1\r\n\r\n", asked.data);
    try testing.expect(peer.more() == null); // and only once

    // The answer comes back in two segments, as any answer might.
    const head = "HTTP/1.1 200 OK\r\ncontent-length: 5\r\n\r\n";
    _ = peer.answer(fakeSegment(&theirs, flag_psh | flag_ack, their_isn +% 1, 0, head));
    _ = peer.answer(fakeSegment(&theirs, flag_psh | flag_ack, their_isn +% 1 +% @as(u32, head.len), 0, "hello"));
    try testing.expectEqual(@as(u16, 200), peer.tcp.status());
    try testing.expectEqualStrings("hello", peer.tcp.body());

    // The guest closes; the client says goodbye and is done.
    const after = their_isn +% 1 +% @as(u32, head.len) +% 5;
    const fin = peer.answer(fakeSegment(&theirs, flag_fin | flag_ack, after, 0, "")).?;
    try testing.expect(tcpIn(fin).?.flags & flag_fin != 0);
    _ = peer.answer(fakeSegment(&theirs, flag_ack, after +% 1, 0, ""));
    try testing.expectEqual(Tcp.State.done, peer.tcp.state);
}

test "a segment out of order is re-acknowledged rather than taken" {
    var peer = Peer{};
    var theirs: [2048]u8 = undefined;
    const syn = tcpIn(peer.open("GET / HTTP/1.1\r\n\r\n")).?;
    _ = peer.answer(fakeSegment(&theirs, flag_syn | flag_ack, 5000, syn.seq +% 1, ""));

    // A segment from further along than we have reached.
    const reply = peer.answer(fakeSegment(&theirs, flag_psh | flag_ack, 9999, 0, "later")).?;
    const tcp = tcpIn(reply).?;
    try testing.expectEqual(@as(u32, 5001), tcp.ack); // still asking for what is missing
    try testing.expectEqual(@as(usize, 0), peer.tcp.reply_len);
}

test "a reset ends it, rather than leaving a client that waits forever" {
    var peer = Peer{};
    var theirs: [2048]u8 = undefined;
    _ = peer.open("GET / HTTP/1.1\r\n\r\n");
    try testing.expect(peer.answer(fakeSegment(&theirs, flag_rst, 0, 0, "")) == null);
    try testing.expectEqual(Tcp.State.refused, peer.tcp.state);
}

test "a frame for another port, or no frame at all, is not answered" {
    var peer = Peer{};
    var buf: [512]u8 = undefined;
    @memset(buf[0..60], 0);
    writeBe16(buf[12..14], 0x0806); // ARP, which this peer does not speak
    try testing.expect(peer.answer(buf[0..60]) == null);
    try testing.expect(peer.answer(buf[0..20]) == null);
}
