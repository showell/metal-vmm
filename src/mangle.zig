//! **FRAMES THAT LIE, FROM THE PEER** (`PEER_MANGLE`, QUEUE.md items 50 and
//! 55). The guest's parsers have only ever seen frames this program built
//! well; this is how they meet the others. A frame the schedule picks is
//! sent twice: first a copy that lies in one way, then the frame itself. The
//! copy's checksums are made right, unless the lie is the checksum, so it
//! reaches the check meant for it rather than the first sum that fails.
//!
//! **WHAT MUST HOLD**: every lying copy is dropped or refused by the guest,
//! never crashes it and never reaches the application. So a run with
//! `PEER_MANGLE` must give the client the answer the run without it gives.
//! A dropped kind's data is replaced with `X`s, so a copy that is taken
//! instead of dropped shows in that answer.
//!
//! `zero_window` is the one kind that does not lie: a window of 0 with the
//! frame's own data, which a guest must take (RFC 9293 §3.8.6) and then stop
//! sending until a window opens. Its data is the frame's own, so the run's
//! answer still holds it; what may change is how long it takes.
//!
//! Which of gopher-metal's checks each kind meets (`proto.parseIpv4`,
//! `tcp.Table.handle`, on `box/v18`) is in `Kind.check`.

const std = @import("std");
const frames = @import("frames.zig");

const ip_at = 14;
const tcp_at = 34;
const proto_tcp: u8 = 6;

pub const Kind = enum {
    ip_version,
    ip_header_short,
    ip_options,
    ip_checksum,
    ip_total_past,
    ip_total_short,
    fragment,
    not_ours,
    wrong_port,
    tcp_offset_short,
    tcp_offset_past,
    zero_window,

    /// The guest's check this kind meets, by name.
    pub fn check(self: Kind) []const u8 {
        return switch (self) {
            .ip_version => "proto.parseIpv4: version not 4",
            .ip_header_short, .ip_options => "proto.parseIpv4: header not 20 bytes",
            .ip_checksum => "proto.parseIpv4: header checksum",
            .ip_total_past => "proto.parseIpv4: total length past the frame",
            .fragment => "proto.parseIpv4: a fragment",
            .ip_total_short => "tcp.handle: shorter than a TCP header",
            .not_ours => "tcp.handle: not our address",
            .wrong_port => "tcp.handle: not our port",
            .tcp_offset_short, .tcp_offset_past => "tcp.handle: data offset",
            .zero_window => "tcp.zig: a shut window, taken",
        };
    }

    /// Whether the guest must drop it: all but `zero_window`.
    pub fn dropped(self: Kind) bool {
        return self != .zero_window;
    }
};

pub const kinds = std.enums.values(Kind);

/// Whether a frame is the peer's IPv4 TCP, the only frames mangled.
pub fn isTcp(frame: []const u8) bool {
    return frame.len >= tcp_at + 20 and frames.readBe16(frame[12..14]) == frames.ethertype_ipv4 and
        frame[ip_at] == 0x45 and frame[ip_at + 9] == proto_tcp;
}

/// **THE LYING COPY** of `frame`, an IPv4 TCP frame as `frames.wrap` builds
/// one, written into `out` (at least 40 bytes longer than `frame`). Null for
/// a frame that is not.
pub fn mangle(frame: []const u8, kind: Kind, out: []u8) ?[]const u8 {
    if (!isTcp(frame) or out.len < frame.len + 40) return null;
    var len = frame.len;
    @memcpy(out[0..len], frame);
    const total = frames.readBe16(frame[ip_at + 2 ..][0..2]);
    if (ip_at + @as(usize, total) != frame.len) return null;
    const offset = @as(usize, frame[tcp_at + 12] >> 4) * 4;
    if (offset < 20 or tcp_at + offset > frame.len) return null;
    // Data a dropped copy carries is not the frame's: taken, it would show.
    if (kind.dropped()) @memset(out[tcp_at + offset .. len], 'X');

    switch (kind) {
        .ip_version => out[ip_at] = 0x65,
        .ip_header_short => out[ip_at] = 0x44,
        .ip_options => {
            // Four bytes of NOPs between the IP header and the segment: a
            // header of 24 bytes, well formed, which the guest does not take.
            std.mem.copyBackwards(u8, out[tcp_at + 4 .. len + 4], out[tcp_at..len]);
            @memset(out[tcp_at..][0..4], 1);
            len += 4;
            out[ip_at] = 0x46;
            frames.writeBe16(out[ip_at + 2 ..][0..2], total + 4);
        },
        .ip_checksum => {},
        .ip_total_past => frames.writeBe16(out[ip_at + 2 ..][0..2], total + 40),
        .ip_total_short => frames.writeBe16(out[ip_at + 2 ..][0..2], 20 + 12),
        .fragment => frames.writeBe16(out[ip_at + 6 ..][0..2], 0x2000), // more fragments
        .not_ours => out[ip_at + 19] +%= 1,
        .wrong_port => frames.writeBe16(out[tcp_at + 2 ..][0..2], frames.readBe16(out[tcp_at + 2 ..][0..2]) +% 1),
        .tcp_offset_short => out[tcp_at + 12] = (4 << 4) | (out[tcp_at + 12] & 0x0F),
        .tcp_offset_past => out[tcp_at + 12] = (15 << 4) | (out[tcp_at + 12] & 0x0F),
        .zero_window => frames.writeBe16(out[tcp_at + 14 ..][0..2], 0),
    }

    // The sums made right for what the copy now is, so each kind meets its
    // own check; the segment's over the bytes after the IP header as it
    // says, the header's over the header it says.
    const ihl = @as(usize, out[ip_at] & 0x0F) * 4;
    if (kind != .ip_options and kind != .ip_header_short) {
        const seg = out[tcp_at..len];
        frames.writeBe16(seg[16..18], 0);
        const from = out[ip_at + 12 ..][0..4].*;
        const to = out[ip_at + 16 ..][0..4].*;
        frames.writeBe16(seg[16..18], frames.pseudoChecksum(from, to, proto_tcp, seg));
    } else if (kind == .ip_options) {
        const seg = out[tcp_at + 4 .. len];
        frames.writeBe16(seg[16..18], 0);
        frames.writeBe16(seg[16..18], frames.pseudoChecksum(out[ip_at + 12 ..][0..4].*, out[ip_at + 16 ..][0..4].*, proto_tcp, seg));
    }
    const header = out[ip_at..][0..@max(@min(ihl, len - ip_at), 20)];
    frames.writeBe16(header[10..12], 0);
    frames.writeBe16(header[10..12], frames.checksum(header));
    if (kind == .ip_checksum) out[ip_at + 10] ^= 0x5A;
    return out[0..len];
}

// ── checked against the guest's own checks ──────────────────────────────────

const testing = std.testing;

/// gopher-metal's checks, in its order (`proto.parseIpv4`, then
/// `tcp.Table.handle` up to the data), answering the one that refused the
/// frame, or null for a segment that reaches the connection.
fn guestRefuses(frame: []const u8, our_ip: [4]u8, our_port: u16) ?Kind {
    if (frame.len < 34) return .ip_total_past;
    const ip = frame[14..];
    if (ip[0] >> 4 != 4) return .ip_version;
    const ihl = @as(usize, ip[0] & 0x0F) * 4;
    if (ihl != 20) return .ip_options;
    if (frames.readBe16(ip[6..8]) & 0x1FFF != 0 or ip[6] & 0x20 != 0) return .fragment;
    const total = frames.readBe16(ip[2..4]);
    if (total < ihl) return .ip_total_short;
    if (frames.checksum(ip[0..ihl]) != 0) return .ip_checksum;
    if (14 + @as(usize, total) > frame.len) return .ip_total_past;
    if (ip[9] != proto_tcp) return .ip_version;
    if (!std.mem.eql(u8, ip[16..20], &our_ip)) return .not_ours;
    const t = ip[ihl..total];
    if (t.len < 20) return .ip_total_short;
    if (frames.readBe16(t[2..4]) != our_port) return .wrong_port;
    if (frames.pseudoChecksum(ip[12..16].*, ip[16..20].*, proto_tcp, t) != 0) return .ip_checksum;
    const offset = @as(usize, t[12] >> 4) * 4;
    if (offset < 20 or offset > t.len) return .tcp_offset_short;
    return null;
}

fn sample(out: []u8) []const u8 {
    return frames.fakeTo(out, 80, 0x18, 1000, 2000, "GET / HTTP/1.1\r\n\r\n");
}

test "every kind but zero_window is refused by the guest's check named for it, and zero_window reaches the connection" {
    var buf: [2048]u8 = undefined;
    const frame = sample(&buf);
    const to = frame[30..34].*;
    try testing.expect(isTcp(frame));
    try testing.expectEqual(@as(?Kind, null), guestRefuses(frame, to, 80));
    for (kinds) |k| {
        var out: [2048]u8 = undefined;
        const lie = mangle(frame, k, &out).?;
        const refused = guestRefuses(lie, to, 80);
        if (!k.dropped()) {
            try testing.expectEqual(@as(?Kind, null), refused);
            try testing.expectEqual(@as(u16, 0), frames.readBe16(lie[48..50]));
            continue;
        }
        const want: Kind = switch (k) {
            .ip_header_short => .ip_options,
            .tcp_offset_past => .tcp_offset_short,
            else => k,
        };
        testing.expectEqual(@as(?Kind, want), refused) catch |e| {
            std.debug.print("kind {s}\n", .{@tagName(k)});
            return e;
        };
        // Its data is not the frame's.
        try testing.expect(std.mem.indexOf(u8, lie, "GET /") == null);
    }
}

test "only the peer's IPv4 TCP frames are mangled" {
    var buf: [2048]u8 = undefined;
    var out: [2048]u8 = undefined;
    const frame = sample(&buf);
    try testing.expectEqual(@as(?[]const u8, null), mangle(frame[0..40], .fragment, &out));
    var udp: [2048]u8 = undefined;
    @memcpy(udp[0..frame.len], frame);
    udp[23] = frames.proto_udp;
    try testing.expectEqual(@as(?[]const u8, null), mangle(udp[0..frame.len], .fragment, &out));
}
