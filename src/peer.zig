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
//!
//! **IT CAN MISBEHAVE, TO A RECIPE** (`Rough`): reset the connection, vanish
//! part-way through the answer, flood the guest with SYNs from elsewhere,
//! shut its receive window for a while, split its request, and, when the wire
//! may lose or damage what it sends (faults.zig), send it again on a timer of
//! its own. Everything it does on its own happens at an instant of the
//! machine's clock (`due`, `wakeAt`), so a run is still a function of the
//! guest and the recipe. With no recipe it is the plain client it always was,
//! frame for frame.

const std = @import("std");
const frames = @import("frames.zig");
const client = @import("client.zig");
pub const Tcp = client.Tcp;
pub const Ask = client.Ask;
pub const Response = @import("response.zig").Response;
const earliest = client.earliest;
const opened = client.opened;
pub const peer_mac = frames.peer_mac;
pub const card_mac = frames.card_mac;
pub const guest_ip = frames.guest_ip;
pub const server_ip = frames.server_ip;
pub const dns_ip = frames.dns_ip;
pub const netmask = frames.netmask;
pub const broadcast_ip = frames.broadcast_ip;
const flag_fin = frames.flag_fin;
const flag_syn = frames.flag_syn;
const flag_rst = frames.flag_rst;
const flag_psh = frames.flag_psh;
const flag_ack = frames.flag_ack;
const Segment = frames.Segment;
const window_open = frames.window_open;
const closedPort = frames.closedPort;
const build = frames.build;
const tcpIn = frames.tcpIn;
const ethertype_ipv4 = frames.ethertype_ipv4;
const proto_udp = frames.proto_udp;
const wrap = frames.wrap;
const checksum = frames.checksum;
const pseudoChecksum = frames.pseudoChecksum;
const sum = frames.sum;
const finish = frames.finish;
const readBe16 = frames.readBe16;
const readBe32 = frames.readBe32;
const writeBe16 = frames.writeBe16;
const writeBe32 = frames.writeBe32;
const fakeSegment = frames.fakeSegment;
const verifies = frames.verifies;
const fakeTo = frames.fakeTo;

/// **WHAT THE PEER MAY DO THAT A GOOD CLIENT DOES NOT**, each set by an
/// environment knob (main.zig, `tellTheFaults`) as the wire's faults are.
/// Times are the machine's, from the moment the client opened.
pub const Rough = struct {
    /// It resets the connection this long after opening it, if it is open
    /// then: at its next sequence number, or `reset_off` past it, inside the
    /// guest's window, where it must be challenged and not obeyed (RFC 5961
    /// §3). From then on it is a closed port, and answers whatever reaches it
    /// with a reset (RFC 9293 §3.10.7.1).
    reset_after_ns: ?u64 = null,
    reset_off: u32 = 0,
    /// Once it has this much of the answer it neither sends nor hears: the
    /// guest's table alone is left to give up on it.
    vanish_after: ?usize = null,
    /// SYNs from addresses that never finish the handshake, `flood_gap_ns`
    /// apart from `flood_after_ns` past the opening: more half-open
    /// connections than the guest has room for, so a new SYN has to take
    /// one's place. Up to `max_flood`, each from its own (address, port).
    flood: u32 = 0,
    flood_gap_ns: u64 = 10 * std.time.ns_per_ms,
    flood_after_ns: u64 = 0,
    /// Once it has this much of the answer its receive window shuts, for
    /// `shut_for_ns`, and then it says the window is open again. While shut
    /// it takes nothing, and answers the guest's probes with the window
    /// still shut (RFC 9293 §3.8.6.1).
    shut_after: ?usize = null,
    shut_for_ns: u64 = 0,
    /// The most of its request it puts in one segment, below the MSS the
    /// guest announced (`Tcp.send_mss`); that MSS alone, if null.
    mss: ?usize = null,
    /// **IT SENDS PAST THE GUEST'S WINDOW** (`PEER_IGNORE_WINDOW`), all it
    /// has released at once, as a careless or hostile client does; what the
    /// guest throws away its timer sends again. A plain client keeps to the
    /// window the guest last offered.
    ignore_window: bool = false,
    /// **IT ASKS AGAIN WHAT GOT NO ANSWER** (`PEER_RETRY=n`): a connection
    /// that closed, or was reset, before a byte of the answer came is
    /// followed by a new one asking the same, as a browser does, up to `n`
    /// times. The new one behaves.
    retry: u8 = 0,
    /// **A SLOW CLIENT** (`PEER_DRIP_US`): each segment of its request goes
    /// this long after the last, so it is never silent and never done for a
    /// long time (with `PEER_MSS`, a byte at a time if asked).
    drip_ns: ?u64 = null,
    /// **IT PIPELINES** (`PEER_PIPELINE`): its second request goes with the
    /// first, before any answer, and it asks at least twice.
    pipeline: bool = false,
    /// **ITS OWN RETRANSMISSION TIMER RUNS** (RFC 6298): set when the wire
    /// may lose or damage what it sends. A peer whose frames always arrive
    /// never needs to send one twice, so without this the run is the run it
    /// always was.
    retransmits: bool = false,
};

/// Where a flood's SYNs come from: TEST-NET-2 (RFC 5737), off the guest's
/// subnet, so they reach it through the gateway this peer already is. SYN
/// `i` is from host `1 + i % 254` and port `40000 + i`, so no two share an
/// (address, port), and a flood can be as large as there are ports above
/// 40000: enough to fill gopher.zig's 256 slots many times over.
const flood_ip = [3]u8{ 198, 51, 100 };
const flood_port: u16 = 40000;
pub const max_flood: u32 = 65536 - @as(u32, flood_port);

fn floodSyn(out: []u8, i: u32) []const u8 {
    const from = flood_ip ++ [1]u8{@intCast(1 + i % 254)};
    return build(out, from, @intCast(flood_port + i), 7000 +% i *% 1000, 0, flag_syn, window_open, "");
}

/// The most clients the peer has at once: the first, and the rest of
/// `PEER_CLIENTS`.
pub const max_clients = 8;

/// **WHO CONNECTS, AND WHAT EACH ASKS** (`PEER_CLIENTS`, `PEER_REQUEST`,
/// `PEER_ASKS`, `PEER_CLIENT_GAP_US`; main.zig). The first client opens when
/// the guest says it is listening, and each of the others a gap after the
/// one before. Each asks its own request, or the last one named.
///
/// **IN TURN** (`PEER_IN_TURN=1`, metal-vmm QUEUE 126): each of the others
/// opens a gap after the one before it ended (`turnEnded`), not after it
/// opened. A request that depends on the last one's write (a move in the
/// session the last made) is then always asked after it, whatever a fault
/// did to the last one's timing; a client that opens a gap after another
/// opened is behind it only while nothing slows that one's SYN.
pub const Plan = struct {
    clients: u8 = 1,
    gap_ns: u64 = std.time.ns_per_ms,
    in_turn: bool = false,
    requests: [max_clients][]const u8 = @splat(""),
    /// How many requests were named; none means the one `open` is given.
    named: u8 = 0,
    asks: u32 = 1,
};

pub const Peer = struct {
    /// The first client, which the run's `peer:` line reports. The knobs of
    /// `Rough` are its alone: the others are well-behaved, so a run can ask
    /// whether a good client got its answer while a bad one misbehaved.
    tcp: Tcp = .{},
    /// The rest, client 2 and on.
    others: [max_clients - 1]Tcp = @splat(.{}),
    rough: Rough = .{},
    plan: Plan = .{},
    /// The request `open` was given, for clients the plan names none for.
    request: []const u8 = "",
    scratch: [2048]u8 = undefined,
    /// When the first client opened, how many clients are open, and how
    /// many of the flood's SYNs are sent.
    opened_at: ?u64 = null,
    opened: u8 = 0,
    flooded: u32 = 0,
    /// The first client's retries (`Rough.retry`): how many, and when the
    /// next opens.
    retried: u8 = 0,
    retry_at: ?u64 = null,
    /// In turn: when the next client opens, once the last one's turn ended.
    turn_at: ?u64 = null,
    /// **THE LEASE IT HANDS OUT** (`DHCP_LEASE_S`, a day by default), and
    /// what the guest did with it: when the last one ends, how many ACKs
    /// it was given and how many of them renewed a lease, and how many
    /// requests came only after the lease had run out.
    lease_s: u32 = 86_400,
    /// Whether a person set it, and so whether the run's end says it.
    lease_named: bool = false,
    lease_until: ?u64 = null,
    acks: u32 = 0,
    renewals: u32 = 0,
    late: u32 = 0,

    pub fn client(self: *Peer, i: usize) *Tcp {
        return if (i == 0) &self.tcp else &self.others[i - 1];
    }

    pub fn clientConst(self: *const Peer, i: usize) *const Tcp {
        return if (i == 0) &self.tcp else &self.others[i - 1];
    }

    /// What the peer says back to one frame, or nothing.
    pub fn answer(self: *Peer, frame: []const u8, now: u64) ?[]const u8 {
        if (dhcpIn(frame)) |request| return self.dhcpOut(request, now);
        const segment = tcpIn(frame) orelse return null;
        // To a flood's address: nobody is there to answer.
        if (!std.mem.eql(u8, &segment.to, &server_ip)) return null;
        for (0..self.opened) |i| {
            const c = self.client(i);
            if (c.port == segment.dst_port) {
                const said = c.receive(segment, now, &self.scratch);
                if (i == 0) self.noticeNoAnswer(now);
                self.noticeTurn(now);
                return said;
            }
        }
        // **A PORT OF OURS WITH NOTHING ON IT** answers as a closed port
        // (RFC 9293 §3.10.7.1): a client not opened yet, or none at all.
        return closedPort(segment, &self.scratch);
    }

    /// Opens the first connection to the guest and asks it for something.
    /// The answer arrives over the frames that follow; the other clients
    /// open on their own, by `due`.
    pub fn open(self: *Peer, request: []const u8, now: u64) []const u8 {
        self.opened_at = now;
        self.request = request;
        self.opened = 1;
        return self.tcp.open(self.ask(0), now, self.rough, &self.scratch);
    }

    /// The first client's connection ended with nothing of the answer: a
    /// retry is due a millisecond on, if one is left.
    fn noticeNoAnswer(self: *Peer, now: u64) void {
        if (self.retried >= self.rough.retry or self.retry_at != null) return;
        const c = &self.tcp;
        const closed = c.state == .closing or c.state == .done or c.state == .refused;
        if (closed and c.received == 0) self.retry_at = now + std.time.ns_per_ms;
    }

    /// How many times the first client sent its request: once, and once
    /// for each retry.
    pub fn sends(self: *const Peer) u32 {
        return @as(u32, self.retried) + 1;
    }

    /// What client `i` asks, on which port, from which first number.
    fn ask(self: *const Peer, i: usize) Ask {
        const named = self.plan.named;
        const request = if (named == 0) self.request else self.plan.requests[@min(i, named - 1)];
        return .{
            .request = request,
            .asks = self.plan.asks,
            .port = 49152 + @as(u16, @intCast(i)),
            .iss = 1000 +% @as(u32, @intCast(i)) *% 0x0100_0000,
        };
    }

    /// Anything else to say right now, after an answer, from whichever client
    /// has something. See `Tcp.more`.
    pub fn more(self: *Peer, now: u64) ?[]const u8 {
        defer self.noticeTurn(now);
        for (0..self.opened) |i| {
            if (self.client(i).more(now, &self.scratch)) |frame| return frame;
        }
        return null;
    }

    /// **WHETHER THE LAST CLIENT'S TURN ENDED**: every answer it asked for
    /// came, or its connection is over without them (the guest reset it, it
    /// gave up, it reset or vanished itself), and, for the first, no retry
    /// is due.
    fn turnEnded(self: *const Peer, i: usize) bool {
        const c = self.clientConst(i);
        if (i == 0 and self.retry_at != null) return false;
        if (c.answers >= c.asks) return true;
        return switch (c.state) {
            .closing, .done, .refused, .reset, .gone, .gave_up => true,
            .idle, .syn_sent, .established, .fin_wait => false,
        };
    }

    /// In turn: the next client's opening, set when the last one's turn ends.
    fn noticeTurn(self: *Peer, now: u64) void {
        if (!self.plan.in_turn or self.turn_at != null or self.opened == 0) return;
        if (self.opened >= @min(self.plan.clients, max_clients)) return;
        if (self.turnEnded(self.opened - 1)) self.turn_at = now + self.plan.gap_ns;
    }

    /// **WHAT IT SAYS UNSPOKEN TO, BY `now`**: the next of a flood's SYNs, a
    /// client opening, a reset, a window reopened, a segment sent again. One
    /// frame a call; null when there is nothing more.
    pub fn due(self: *Peer, now: u64) ?[]const u8 {
        self.noticeTurn(now);
        defer self.noticeTurn(now);
        if (self.retry_at) |at| if (now >= at) {
            // **THE SAME REQUEST, ON A NEW CONNECTION**: a port past the
            // clients' own, and new numbers.
            self.retry_at = null;
            self.retried += 1;
            var asking = self.ask(0);
            asking.port = 49152 + max_clients + @as(u16, self.retried) - 1;
            asking.iss = 1000 +% @as(u32, self.retried) *% 0x0F00_0000;
            const good = Rough{ .retransmits = self.rough.retransmits, .mss = self.rough.mss };
            return self.tcp.open(asking, now, good, &self.scratch);
        };
        if (self.nextFlood()) |at| if (now >= at) {
            self.flooded += 1;
            return floodSyn(&self.scratch, self.flooded - 1);
        };
        if (self.nextOpening()) |at| if (now >= at) {
            const i = self.opened;
            self.opened += 1;
            self.turn_at = null;
            const good = Rough{ .retransmits = self.rough.retransmits };
            return self.client(i).open(self.ask(i), now, good, &self.scratch);
        };
        for (0..self.opened) |i| {
            if (self.client(i).due(now, &self.scratch)) |frame| return frame;
        }
        return null;
    }

    /// The next instant at which `due` will have something, if any.
    pub fn wakeAt(self: *const Peer) ?u64 {
        var at = earliest(earliest(self.nextFlood(), self.nextOpening()), self.retry_at);
        for (0..self.opened) |i| at = earliest(at, self.clientConst(i).wakeAt());
        return at;
    }

    fn nextFlood(self: *const Peer) ?u64 {
        const at = self.opened_at orelse return null;
        if (self.flooded >= @min(self.rough.flood, max_flood)) return null;
        return at + self.rough.flood_after_ns + @as(u64, self.flooded) * self.rough.flood_gap_ns;
    }

    fn nextOpening(self: *const Peer) ?u64 {
        const at = self.opened_at orelse return null;
        if (self.opened >= @min(self.plan.clients, max_clients)) return null;
        if (self.plan.in_turn) return self.turn_at;
        return at + @as(u64, self.opened) * self.plan.gap_ns;
    }

    fn dhcpOut(self: *Peer, request: Dhcp, now: u64) ?[]const u8 {
        const kind: u8 = switch (request.kind) {
            msg_discover => msg_offer,
            msg_request => msg_ack,
            else => return null,
        };
        if (kind == msg_ack) {
            if (self.lease_until) |until| {
                if (now >= until) self.late += 1 else self.renewals += 1;
            }
            self.acks += 1;
            self.lease_until = now + @as(u64, self.lease_s) * std.time.ns_per_s;
        }
        return writeDhcp(&self.scratch, request, kind, self.lease_s);
    }

    /// The run's lease, in one line, at `now` (its end).
    pub fn leaseLine(self: *const Peer, now: u64, buf: []u8) []const u8 {
        const until = self.lease_until orelse
            return std.fmt.bufPrint(buf, "metal-vmm: dhcp: a lease of {d} s offered, and never taken\n", .{self.lease_s}) catch "";
        const ended = if (now >= until)
            std.fmt.bufPrint(buf[200..], "it ran out at {d} s of the guest's time, unrenewed", .{until / std.time.ns_per_s}) catch ""
        else
            std.fmt.bufPrint(buf[200..], "it was held to the end", .{}) catch "";
        return std.fmt.bufPrint(buf[0..200], "metal-vmm: dhcp: a lease of {d} s; {d} renewals, {d} requests after it ran out; {s}\n", .{ self.lease_s, self.renewals, self.late, ended }) catch "";
    }
};

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

fn writeDhcp(out: []u8, request: Dhcp, kind: u8, lease_s: u32) []const u8 {
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
    var lease: [4]u8 = undefined;
    writeBe32(&lease, lease_s);
    at = writeOption(bootp, at, opt_lease_time, &lease);
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

// ── what can be checked without a guest ──────────────────────────────────────

const testing = std.testing;
const ms = std.time.ns_per_ms;
const sec = std.time.ns_per_s;

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

test "a discover is answered with the lease QEMU would hand out" {
    var peer = Peer{};
    var request: [512]u8 = undefined;
    const reply = peer.answer(fakeDiscover(&request, msg_discover, card_mac, .{ 1, 2, 3, 4 }), 0).?;
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
    const reply = peer.answer(fakeDiscover(&request, msg_request, card_mac, .{ 9, 9, 9, 9 }), 0).?;
    try testing.expectEqual(msg_ack, option(reply[42..], opt_message_type).?);
    try testing.expectEqual(@as(u16, 0), checksum(reply[14..34])); // a good header sums to zero
}

test "a frame for another port, or no frame at all, is not answered" {
    var peer = Peer{};
    var buf: [512]u8 = undefined;
    @memset(buf[0..60], 0);
    writeBe16(buf[12..14], 0x0806); // ARP, which this peer does not speak
    try testing.expect(peer.answer(buf[0..60], 0) == null);
    try testing.expect(peer.answer(buf[0..20], 0) == null);
}

test "with no recipe, the peer never acts on its own" {
    var peer = Peer{};
    var theirs: [2048]u8 = undefined;
    try opened(&peer, .{}, "GET / HTTP/1.1\r\n\r\n", 0);
    try testing.expect(peer.wakeAt() == null);
    try testing.expect(peer.due(1000 * sec) == null);
    _ = peer.answer(fakeSegment(&theirs, flag_fin | flag_ack, 5001, 0, ""), 0);
    try testing.expect(peer.wakeAt() == null);
}

test "a flood: SYNs from addresses that never finish, a gap apart, unanswered" {
    var peer = Peer{};
    var theirs: [2048]u8 = undefined;
    peer.rough = .{ .flood = 3, .flood_gap_ns = 10 * ms };
    _ = peer.open("GET", 100);
    var froms: [3]u8 = undefined;
    var ports: [3]u16 = undefined;
    for (0..3) |i| {
        const at = 100 + i * 10 * ms;
        try testing.expectEqual(@as(?u64, at), peer.wakeAt());
        const frame = peer.due(at).?;
        try testing.expect(verifies(frame));
        try testing.expectEqualSlices(u8, &flood_ip, frame[26..29]);
        froms[i] = frame[29];
        const syn = tcpIn(frame).?;
        try testing.expectEqual(flag_syn, syn.flags);
        ports[i] = syn.src_port;
        try testing.expect(peer.due(at) == null); // one a gap
    }
    try testing.expect(peer.wakeAt() == null);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, &froms);
    try testing.expectEqualSlices(u16, &.{ 40000, 40001, 40002 }, &ports);
    // The guest's SYN-ACK to one of them, at the address it came from,
    // goes unanswered: it never finishes.
    var reply = fakeSegment(&theirs, flag_syn | flag_ack, 9000, 7001, "");
    _ = &reply;
    theirs[36] = 0x9C; // to port 40000
    theirs[37] = 0x40;
    @memcpy(theirs[14 + 16 ..][0..3], &flood_ip);
    theirs[14 + 19] = froms[0];
    try testing.expect(peer.answer(theirs[0..reply.len], 0) == null);
    // The same to the peer's own address is a closed port's, and answered.
    theirs[14 + 16 ..][0..4].* = server_ip;
    try testing.expect(tcpIn(peer.answer(theirs[0..reply.len], 0).?).?.flags & flag_rst != 0);
}

test "several clients: each opens a gap after the last, on its own port and its own numbers" {
    var peer = Peer{ .plan = .{ .clients = 3, .gap_ns = 5 * ms } };
    _ = peer.open("GET /a HTTP/1.1\r\n\r\n", 100);
    try testing.expectEqual(@as(?u64, 100 + 5 * ms), peer.wakeAt());
    try testing.expect(peer.due(100 + 5 * ms - 1) == null);
    const two = tcpIn(peer.due(100 + 5 * ms).?).?;
    try testing.expectEqual(flag_syn, two.flags);
    try testing.expectEqual(@as(u16, 49153), two.src_port);
    try testing.expectEqual(@as(?u64, 100 + 10 * ms), peer.wakeAt());
    const three = tcpIn(peer.due(100 + 10 * ms).?).?;
    try testing.expectEqual(@as(u16, 49154), three.src_port);
    try testing.expect(three.seq != two.seq);
    try testing.expect(peer.wakeAt() == null);
    try testing.expectEqual(@as(u8, 3), peer.opened);
}

test "clients in turn: each opens a gap after the one before it was answered, so a request may depend on the last one's write (QUEUE 126)" {
    var peer = Peer{ .plan = .{ .clients = 3, .gap_ns = 5 * ms, .in_turn = true } };
    var theirs: [2048]u8 = undefined;
    _ = peer.open("GET /a HTTP/1.1\r\n\r\n", 100);
    // Nothing is due while the first is unanswered, however long it takes.
    try testing.expect(peer.wakeAt() == null);
    try testing.expect(peer.due(100 + sec) == null);
    const c1 = peer.client(0);
    _ = peer.answer(fakeTo(&theirs, c1.port, flag_syn | flag_ack, 9000, c1.iss +% 1, ""), 2 * sec).?;
    while (peer.more(2 * sec)) |_| {}
    try testing.expect(peer.wakeAt() == null);
    const answer = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok";
    _ = peer.answer(fakeTo(&theirs, c1.port, flag_ack | flag_psh | flag_fin, 9001, c1.seq, answer), 3 * sec);
    try testing.expectEqual(@as(u32, 1), c1.answers);
    // Answered at 3 s: the second opens 5 ms on, and the third waits on it.
    try testing.expectEqual(@as(?u64, 3 * sec + 5 * ms), peer.wakeAt());
    try testing.expect(peer.due(3 * sec + 5 * ms - 1) == null);
    const two = tcpIn(peer.due(3 * sec + 5 * ms).?).?;
    try testing.expectEqual(@as(u16, 49153), two.src_port);
    try testing.expect(peer.wakeAt() != 3 * sec + 10 * ms);
    try testing.expectEqual(@as(u8, 2), peer.opened);
    // A client that ends without an answer (the guest resets it) ends its
    // turn too: the next is not held for ever.
    const c2 = peer.client(1);
    _ = peer.answer(fakeTo(&theirs, c2.port, flag_rst | flag_ack, 0, c2.iss +% 1, ""), 4 * sec);
    try testing.expectEqual(Tcp.State.refused, c2.state);
    try testing.expectEqual(@as(?u64, 4 * sec + 5 * ms), peer.wakeAt());
    try testing.expectEqual(@as(u16, 49154), tcpIn(peer.due(4 * sec + 5 * ms).?).?.src_port);
    try testing.expect(peer.wakeAt() == null or peer.wakeAt().? > 4 * sec + 5 * ms);
}

test "each client asks its own request, or the last one named, and is answered on its own port" {
    var peer = Peer{ .plan = .{ .clients = 3, .gap_ns = 0 } };
    peer.plan.requests[0] = "GET /one HTTP/1.1\r\n\r\n";
    peer.plan.requests[1] = "GET /two HTTP/1.1\r\n\r\n";
    peer.plan.named = 2;
    var theirs: [2048]u8 = undefined;
    _ = peer.open("ignored", 0);
    while (peer.due(0)) |_| {}
    var copies: [3][64]u8 = undefined;
    var asked: [3][]const u8 = undefined;
    for (0..3) |i| {
        const c = peer.client(i);
        _ = peer.answer(fakeTo(&theirs, c.port, flag_syn | flag_ack, 9000, c.iss +% 1, ""), 0).?;
        const req = tcpIn(peer.more(0).?).?;
        try testing.expectEqual(c.port, req.src_port);
        @memcpy(copies[i][0..req.data.len], req.data); // the peer's frame is reused
        asked[i] = copies[i][0..req.data.len];
    }
    try testing.expectEqualStrings("GET /one HTTP/1.1\r\n\r\n", asked[0]);
    try testing.expectEqualStrings("GET /two HTTP/1.1\r\n\r\n", asked[1]);
    try testing.expectEqualStrings("GET /two HTTP/1.1\r\n\r\n", asked[2]);
    // An answer to the second reaches the second alone.
    const c2 = peer.client(1);
    _ = peer.answer(fakeTo(&theirs, c2.port, flag_ack | flag_psh, 9001, c2.seq, "HTTP/1.1 200 OK\r\n"), 0).?;
    try testing.expectEqual(@as(usize, 17), c2.reply_len);
    try testing.expectEqual(@as(usize, 0), peer.client(0).reply_len);
    try testing.expectEqual(@as(usize, 0), peer.client(2).reply_len);
}

test "the rough knobs are the first client's; the others behave" {
    var peer = Peer{ .rough = .{ .reset_after_ns = ms, .retransmits = true }, .plan = .{ .clients = 2, .gap_ns = 0 } };
    var theirs: [2048]u8 = undefined;
    _ = peer.open("GET", 0);
    _ = peer.due(0).?; // the second client's SYN
    for (0..2) |i| {
        const c = peer.client(i);
        _ = peer.answer(fakeTo(&theirs, c.port, flag_syn | flag_ack, 9000, c.iss +% 1, ""), 0).?;
        while (peer.more(0)) |_| {}
    }
    try testing.expect(peer.client(1).rough.reset_after_ns == null);
    try testing.expect(peer.client(1).rough.retransmits); // a lossy wire is everyone's
    const rst = tcpIn(peer.due(ms).?).?;
    try testing.expectEqual(flag_rst, rst.flags);
    try testing.expectEqual(@as(u16, 49152), rst.src_port);
    try testing.expectEqual(Tcp.State.established, peer.client(1).state);
}

// ── a flood that can fill the guest's table ─────────────────────────────────

test "a flood of a thousand SYNs, from as many (address, port) pairs, starting when it was told" {
    var peer = Peer{ .rough = .{ .flood = 1024, .flood_gap_ns = 1000, .flood_after_ns = 5 * ms } };
    _ = peer.open("GET", 100);
    try testing.expectEqual(@as(?u64, 100 + 5 * ms), peer.wakeAt());
    try testing.expect(peer.due(100 + 5 * ms - 1) == null);
    var seen = std.AutoHashMap(u64, void).init(testing.allocator);
    defer seen.deinit();
    var at: u64 = 100 + 5 * ms;
    for (0..1024) |i| {
        try testing.expectEqual(@as(?u64, at), peer.wakeAt());
        const frame = peer.due(at).?;
        try testing.expect(verifies(frame));
        const syn = tcpIn(frame).?;
        try testing.expectEqual(flag_syn, syn.flags);
        try testing.expectEqualSlices(u8, &flood_ip, frame[26..29]);
        const host = frame[29];
        try testing.expect(host >= 1 and host <= 254);
        if (i < 254) try testing.expectEqual(@as(u8, @intCast(1 + i)), host); // as a small flood was
        const key = (@as(u64, host) << 16) | syn.src_port;
        try testing.expect(!seen.contains(key));
        try seen.put(key, {});
        at += 1000;
    }
    try testing.expect(peer.wakeAt() == null);
    try testing.expectEqual(@as(u32, 1024), peer.flooded);
}

test "the largest flood there are ports for, and no larger" {
    var peer = Peer{ .rough = .{ .flood = max_flood + 10, .flood_gap_ns = 0 } };
    _ = peer.open("GET", 0);
    var n: u32 = 0;
    var last_port: u16 = 0;
    while (peer.due(0)) |frame| : (n += 1) last_port = tcpIn(frame).?.src_port;
    try testing.expectEqual(max_flood, n);
    try testing.expectEqual(@as(u16, 65535), last_port);
}

/// **THE GUEST'S CONNECTION TABLE, IN MINIATURE**: gopher.zig's rule for a
/// SYN, as its tcp.zig states it. A free slot takes it; with none free, the
/// oldest half-open connection older than a round trip gives way to it;
/// with none of those either, it is dropped. An established connection is
/// never given up for a SYN.
const ModelTable = struct {
    const slots = 256;
    const round_trip_ns = ms;
    const Slot = struct { from: [4]u8, port: u16, established: bool, since: u64 };

    held: [slots]?Slot = @splat(null),
    gave_way: u32 = 0,
    dropped: u32 = 0,
    evicted_established: u32 = 0,

    fn syn(self: *ModelTable, from: [4]u8, port: u16, now: u64) bool {
        for (&self.held) |*s| if (s.* == null) {
            s.* = .{ .from = from, .port = port, .established = false, .since = now };
            return true;
        };
        var oldest: ?usize = null;
        for (self.held, 0..) |s, i| {
            const h = s.?;
            if (h.established or now - h.since <= round_trip_ns) continue;
            if (oldest == null or h.since < self.held[oldest.?].?.since) oldest = i;
        }
        const i = oldest orelse {
            self.dropped += 1;
            return false;
        };
        self.gave_way += 1;
        self.held[i] = .{ .from = from, .port = port, .established = false, .since = now };
        return true;
    }

    fn establish(self: *ModelTable, from: [4]u8, port: u16) void {
        for (&self.held) |*s| if (s.*) |*h| if (std.mem.eql(u8, &h.from, &from) and h.port == port) {
            h.established = true;
        };
    }

    fn holds(self: *const ModelTable, from: [4]u8, port: u16) bool {
        for (self.held) |s| if (s) |h| if (std.mem.eql(u8, &h.from, &from) and h.port == port) return true;
        return false;
    }
};

test "a client that opened before a flood of a thousand SYNs gets its whole answer, and only half-opens give way" {
    var peer = Peer{ .rough = .{ .flood = 1024, .flood_gap_ns = 20_000, .flood_after_ns = 2 * ms } };
    var table = ModelTable{};
    var theirs: [2048]u8 = undefined;
    const body_len = 20_000;
    const head = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n", .{body_len});

    // The client connects and asks, before the flood begins.
    const syn = tcpIn(peer.open("GET /long HTTP/1.1\r\n\r\n", 0)).?;
    try testing.expect(table.syn(server_ip, syn.src_port, 0));
    _ = peer.answer(fakeSegment(&theirs, flag_syn | flag_ack, 5000, syn.seq +% 1, ""), 0).?;
    table.establish(server_ip, syn.src_port);
    const request = tcpIn(peer.more(0).?).?;
    const acked = request.seq +% @as(u32, @intCast(request.data.len));

    // The guest answers a kilobyte a millisecond while the flood arrives.
    var answer: [head.len + body_len]u8 = undefined;
    @memcpy(answer[0..head.len], head);
    for (answer[head.len..], 0..) |*b, i| b.* = @truncate(i);
    var sent: usize = 0;
    var now: u64 = 0;
    while (now < 40 * ms) : (now += 10_000) {
        while (peer.due(now)) |frame| {
            const s = tcpIn(frame).?;
            if (s.flags & flag_syn != 0) _ = table.syn(frame[26..30].*, s.src_port, now);
        }
        if (now >= ms and now % ms == 0 and sent < answer.len) {
            const n = @min(1000, answer.len - sent);
            _ = peer.answer(fakeSegment(&theirs, flag_ack | flag_psh, 5001 +% @as(u32, @intCast(sent)), acked, answer[sent..][0..n]), now).?;
            sent += n;
        }
    }
    try testing.expectEqual(@as(u32, 1024), peer.flooded);
    try testing.expectEqual(@as(u32, 1), peer.tcp.answers); // whole, by its length
    try testing.expectEqual(answer.len, peer.tcp.reply_len);
    try testing.expectEqualSlices(u8, &answer, peer.tcp.whole());
    // The table was full and stuck half-opens gave way to new SYNs, while the
    // client's own connection held its slot throughout.
    try testing.expect(table.gave_way > 0);
    try testing.expect(table.holds(server_ip, syn.src_port));
    try testing.expectEqual(@as(u32, 1024 - 255), table.gave_way + table.dropped);
}

test "DHCP_LEASE_S: the lease offered, renewals counted, and a lease that ran out said" {
    var peer = Peer{ .lease_s = 60 };
    var request: [400]u8 = undefined;
    var buf: [512]u8 = undefined;
    const offer = peer.answer(fakeDiscover(&request, msg_discover, card_mac, .{ 1, 2, 3, 4 }), 0).?;
    // The lease time option, 60 seconds, big-endian.
    const at = std.mem.indexOf(u8, offer[14 + 20 + 8 + 240 ..], &.{ opt_lease_time, 4 }).?;
    try testing.expectEqual(@as(u32, 60), readBe32(offer[14 + 20 + 8 + 240 + at + 2 ..][0..4]));
    _ = peer.answer(fakeDiscover(&request, msg_request, card_mac, .{ 1, 2, 3, 4 }), 0).?;
    try testing.expectEqualStrings("metal-vmm: dhcp: a lease of 60 s; 0 renewals, 0 requests after it ran out; it was held to the end\n", peer.leaseLine(59 * std.time.ns_per_s, &buf));
    // Renewed at T1, half the lease; then never again.
    _ = peer.answer(fakeDiscover(&request, msg_request, card_mac, .{ 1, 2, 3, 5 }), 30 * std.time.ns_per_s).?;
    try testing.expectEqualStrings("metal-vmm: dhcp: a lease of 60 s; 1 renewals, 0 requests after it ran out; it ran out at 90 s of the guest's time, unrenewed\n", peer.leaseLine(120 * std.time.ns_per_s, &buf));
    // A request after it ran out is late, not a renewal.
    _ = peer.answer(fakeDiscover(&request, msg_request, card_mac, .{ 1, 2, 3, 6 }), 200 * std.time.ns_per_s).?;
    try testing.expectEqual(@as(u32, 1), peer.late);
}
