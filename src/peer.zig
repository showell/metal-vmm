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
    /// apart from the opening: more half-open connections than the guest has
    /// room for, so a new SYN has to take one's place.
    flood: u8 = 0,
    flood_gap_ns: u64 = 10 * std.time.ns_per_ms,
    /// Once it has this much of the answer its receive window shuts, for
    /// `shut_for_ns`, and then it says the window is open again. While shut
    /// it takes nothing, and answers the guest's probes with the window
    /// still shut (RFC 9293 §3.8.6.1).
    shut_after: ?usize = null,
    shut_for_ns: u64 = 0,
    /// The most of its request it puts in one segment; all of it, if null.
    mss: ?usize = null,
    /// **ITS OWN RETRANSMISSION TIMER RUNS** (RFC 6298): set when the wire
    /// may lose or damage what it sends. A peer whose frames always arrive
    /// never needs to send one twice, so without this the run is the run it
    /// always was.
    retransmits: bool = false,
};

/// Where a flood's SYNs come from: TEST-NET-2 (RFC 5737), off the guest's
/// subnet, so they reach it through the gateway this peer already is.
const flood_ip = [3]u8{ 198, 51, 100 };
const flood_port: u16 = 40000;

pub const Peer = struct {
    tcp: Tcp = .{},
    rough: Rough = .{},
    scratch: [2048]u8 = undefined,
    /// When the client opened, and how many of the flood's SYNs are sent.
    opened_at: ?u64 = null,
    flooded: u8 = 0,

    /// What the peer says back to one frame, or nothing.
    pub fn answer(self: *Peer, frame: []const u8, now: u64) ?[]const u8 {
        if (dhcpIn(frame)) |request| return self.dhcpOut(request);
        if (tcpIn(frame)) |segment| return self.tcp.receive(segment, now, &self.scratch);
        return null;
    }

    /// Opens a connection to the guest and asks it for something. The answer
    /// arrives over the frames that follow.
    pub fn open(self: *Peer, request: []const u8, now: u64) []const u8 {
        self.opened_at = now;
        return self.tcp.open(request, now, self.rough, &self.scratch);
    }

    /// Anything else to say right now, after an answer. See `Tcp.more`.
    pub fn more(self: *Peer, now: u64) ?[]const u8 {
        return self.tcp.more(now, &self.scratch);
    }

    /// **WHAT IT SAYS UNSPOKEN TO, BY `now`**: the next of a flood's SYNs, a
    /// reset, a window reopened, a segment sent again. One frame a call;
    /// null when there is nothing more.
    pub fn due(self: *Peer, now: u64) ?[]const u8 {
        if (self.nextFlood()) |at| if (now >= at) {
            const i = self.flooded;
            self.flooded += 1;
            const from = flood_ip ++ [1]u8{1 + i};
            return build(&self.scratch, from, flood_port + i, 7000 + @as(u32, i) * 1000, 0, flag_syn, window_open, "");
        };
        return self.tcp.due(now, &self.scratch);
    }

    /// The next instant at which `due` will have something, if any.
    pub fn wakeAt(self: *const Peer) ?u64 {
        return earliest(self.nextFlood(), self.tcp.wakeAt());
    }

    fn nextFlood(self: *const Peer) ?u64 {
        const at = self.opened_at orelse return null;
        if (self.flooded >= self.rough.flood) return null;
        return at + @as(u64, self.flooded) * self.rough.flood_gap_ns;
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

fn earliest(a: ?u64, b: ?u64) ?u64 {
    const x = a orelse return b;
    const y = b orelse return x;
    return @min(x, y);
}

/// The window it offers: one it never actually fills, or none.
const window_open: u16 = 64240;

/// RFC 6298 §2: the first timeout is a second, and each one after a timeout
/// doubles, to a minute. A peer that has sent the same thing this many times
/// gives up on the connection.
const initial_rto_ns: u64 = std.time.ns_per_s;
const max_rto_ns: u64 = 60 * std.time.ns_per_s;
const max_tries: u8 = 8;

/// A client that fetches one thing and then closes, which is all the probes
/// ask of it. **Sequence numbers are counted, not guessed**: the guest's table
/// checks them, refuses a segment that is not the next one, and answers a
/// reset for a connection it does not know — so a client that drifts is told
/// about it immediately rather than hanging.
pub const Tcp = struct {
    pub const State = enum {
        idle,
        syn_sent,
        established,
        closing,
        done,
        /// The guest reset it.
        refused,
        /// It reset the connection itself (`Rough.reset_after_ns`), and is a
        /// closed port now.
        reset,
        /// It vanished (`Rough.vanish_after`): it neither sends nor hears.
        gone,
        /// It sent the same thing `max_tries` times and stopped: a closed
        /// port, as after a reset.
        gave_up,
    };

    /// A fixed first sequence number, because two runs of the same guest
    /// should look the same on the wire.
    const iss: u32 = 1000;

    state: State = .idle,
    /// A fixed port, for the same reason.
    port: u16 = 49152,
    /// SND.NXT, SND.UNA and RCV.NXT (RFC 9293 §3.3.1).
    seq: u32 = iss,
    una: u32 = iss,
    ack: u32 = 0,
    request: []const u8 = "",
    /// **THE REQUEST GOES IN ITS OWN SEGMENT**, after the handshake's last
    /// acknowledgement rather than riding along with it. Both are legal, and
    /// an ordinary client does the second — which matters, because a guest
    /// whose table reports "the connection opened" and "data arrived" as
    /// different events may only look at the buffer on the second.
    owes_request: bool = false,
    /// It has sent its FIN, at the sequence number just past the request.
    fin_sent: bool = false,
    reply: [64 * 1024]u8 = undefined,
    reply_len: usize = 0,

    rough: Rough = .{},
    opened_at: u64 = 0,
    /// The retransmission timer: when it goes off, and how long the next
    /// wait is.
    timer_at: ?u64 = null,
    rto_ns: u64 = initial_rto_ns,
    tries: u8 = 0,
    /// The reset is behind it, done or let go of because the connection was
    /// not open when its time came.
    reset_past: bool = false,
    /// While its window is shut, when it opens; and whether it has shut yet.
    shut_until: ?u64 = null,
    shut_ever: bool = false,

    pub fn open(self: *Tcp, request: []const u8, now: u64, rough: Rough, out: []u8) []const u8 {
        self.* = .{ .state = .syn_sent, .request = request, .rough = rough, .opened_at = now };
        const frame = self.segment(out, flag_syn, "");
        self.seq +%= 1; // the SYN takes one
        self.arm(now);
        return frame;
    }

    /// What this client says back to one segment, if anything.
    pub fn receive(self: *Tcp, s: Segment, now: u64, out: []u8) ?[]const u8 {
        if (s.dst_port != self.port) return null;
        switch (self.state) {
            .gone => return null,
            .reset, .gave_up => return closedPort(s, out),
            else => {},
        }
        if (s.flags & flag_rst != 0) {
            self.state = .refused;
            self.timer_at = null;
            return null;
        }
        switch (self.state) {
            .syn_sent => {
                if (s.flags & flag_syn == 0 or s.flags & flag_ack == 0) return null;
                self.ack = s.seq +% 1; // their SYN takes one too
                self.state = .established;
                self.owes_request = true;
                self.acknowledged(self.seq, now);
                return self.segment(out, flag_ack, "");
            },
            .established, .closing => {
                if (s.flags & flag_ack != 0) self.acknowledged(s.ack, now);
                // **IN ORDER ONLY.** Anything else is re-acknowledged, which
                // asks for what we are missing — the same rule the guest's own
                // table follows.
                if (s.seq != self.ack) return self.segment(out, flag_ack, "");
                // **A SHUT WINDOW TAKES NOTHING**, neither a byte nor a FIN;
                // what arrives is answered with the window still shut.
                if (self.shut_until != null and (s.data.len > 0 or s.flags & flag_fin != 0)) return self.segment(out, flag_ack, "");
                if (s.data.len > 0) {
                    const room = self.reply.len - self.reply_len;
                    const n = @min(room, s.data.len);
                    @memcpy(self.reply[self.reply_len..][0..n], s.data[0..n]);
                    self.reply_len += n;
                    self.ack +%= @intCast(s.data.len);
                    if (self.rough.vanish_after) |after| if (self.reply_len >= after) {
                        self.state = .gone;
                        self.timer_at = null;
                        return null;
                    };
                    if (self.rough.shut_after) |after| if (!self.shut_ever and self.reply_len >= after) {
                        self.shut_ever = true;
                        self.shut_until = now + self.rough.shut_for_ns;
                    };
                }
                if (s.flags & flag_fin != 0) {
                    self.ack +%= 1; // their FIN takes one
                    if (self.state != .closing) {
                        self.state = .closing;
                        const frame = self.segment(out, flag_fin | flag_ack, "");
                        self.seq +%= 1;
                        self.fin_sent = true;
                        self.arm(now);
                        return frame;
                    }
                    self.state = .done;
                    return self.segment(out, flag_ack, "");
                }
                if (s.data.len > 0) return self.segment(out, flag_ack, "");
                // An acknowledgement of our FIN and nothing else: we are done.
                // A peer that may have to send its FIN again waits for the
                // acknowledgement that covers it.
                if (self.state == .closing and s.flags & flag_ack != 0 and
                    (!self.rough.retransmits or s.ack == self.seq)) self.state = .done;
                return null;
            },
            else => return null,
        }
    }

    /// The next thing this client has to say without being spoken to, if
    /// anything. Called after every answer, because one thing arriving can
    /// mean two things to send. The request goes `Rough.mss` at a time.
    pub fn more(self: *Tcp, now: u64, out: []u8) ?[]const u8 {
        if (!self.owes_request or self.state != .established) return null;
        const start: usize = self.seq -% (iss +% 1);
        const n = @min(self.rough.mss orelse self.request.len, self.request.len - start);
        const frame = self.segment(out, flag_ack | flag_psh, self.request[start..][0..n]);
        self.seq +%= @intCast(n);
        if (start + n >= self.request.len) self.owes_request = false;
        if (n > 0) self.arm(now);
        return frame;
    }

    /// **WHAT IT SAYS ON ITS OWN, BY `now`**: its reset, its window reopened,
    /// or what its timer sends again. One frame a call.
    pub fn due(self: *Tcp, now: u64, out: []u8) ?[]const u8 {
        if (self.resetAt()) |at| if (now >= at) {
            self.reset_past = true;
            if (self.state != .established and self.state != .closing) return null;
            self.state = .reset;
            self.timer_at = null;
            self.shut_until = null;
            return build(out, server_ip, self.port, self.seq +% self.rough.reset_off, 0, flag_rst, 0, "");
        };
        if (self.shut_until) |at| if (now >= at) {
            self.shut_until = null;
            return self.segment(out, flag_ack, "");
        };
        if (self.timer_at) |at| if (now >= at) {
            self.tries += 1;
            if (self.tries >= max_tries) {
                self.state = .gave_up;
                self.timer_at = null;
                return null;
            }
            self.rto_ns = @min(self.rto_ns * 2, max_rto_ns);
            self.timer_at = now + self.rto_ns;
            return self.again(out);
        };
        return null;
    }

    /// The next instant at which `due` will have something, if any.
    pub fn wakeAt(self: *const Tcp) ?u64 {
        return earliest(earliest(self.resetAt(), self.shut_until), self.timer_at);
    }

    fn resetAt(self: *const Tcp) ?u64 {
        if (self.reset_past or self.state == .idle) return null;
        return self.opened_at + (self.rough.reset_after_ns orelse return null);
    }

    /// The oldest thing unacknowledged, sent again (RFC 6298 §5.4): the SYN,
    /// a segment's worth of the request, or the FIN.
    fn again(self: *Tcp, out: []u8) []const u8 {
        if (self.state == .syn_sent) return build(out, server_ip, self.port, iss, 0, flag_syn, self.window(), "");
        const data_end = iss +% 1 +% @as(u32, @intCast(self.request.len));
        const start: usize = self.una -% (iss +% 1);
        if (self.una != data_end and start < self.request.len) {
            const n = @min(self.rough.mss orelse self.request.len, self.request.len - start);
            return build(out, server_ip, self.port, self.una, self.ack, flag_ack | flag_psh, self.window(), self.request[start..][0..n]);
        }
        return build(out, server_ip, self.port, data_end, self.ack, flag_fin | flag_ack, self.window(), "");
    }

    /// Something of ours that takes sequence space is on the wire: if the
    /// timer runs and is not already running, it starts.
    fn arm(self: *Tcp, now: u64) void {
        if (self.rough.retransmits and self.timer_at == null) self.timer_at = now + self.rto_ns;
    }

    /// The guest acknowledged up to `ack`. New ground restarts the timer for
    /// whatever is left, or stops it (RFC 6298 §5.2-5.3).
    fn acknowledged(self: *Tcp, ack: u32, now: u64) void {
        const advance = ack -% self.una;
        if (advance == 0 or advance > self.seq -% self.una) return;
        self.una = ack;
        self.tries = 0;
        self.rto_ns = initial_rto_ns;
        self.timer_at = null;
        if (self.una != self.seq) self.arm(now);
    }

    fn window(self: *const Tcp) u16 {
        return if (self.shut_until != null) 0 else window_open;
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
        return build(out, server_ip, self.port, self.seq, self.ack, flags, self.window(), data);
    }
};

/// **A CLOSED PORT'S ANSWER** (RFC 9293 §3.10.7.1): a reset for anything
/// but a reset, at the sequence number the segment acknowledged, or else
/// acknowledging all of it.
fn closedPort(s: Segment, out: []u8) ?[]const u8 {
    if (s.flags & flag_rst != 0) return null;
    if (s.flags & flag_ack != 0) return build(out, server_ip, s.dst_port, s.ack, 0, flag_rst, 0, "");
    const len: u32 = @intCast(s.data.len + @intFromBool(s.flags & flag_syn != 0) + @intFromBool(s.flags & flag_fin != 0));
    return build(out, server_ip, s.dst_port, 0, s.seq +% len, flag_rst | flag_ack, 0, "");
}

/// One TCP segment to the guest's port 80, in a frame.
fn build(out: []u8, from: [4]u8, port: u16, seq: u32, ack: u32, flags: u8, window: u16, data: []const u8) []const u8 {
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

test "the whole fetch: a handshake, a request, an answer, and a close" {
    var peer = Peer{};
    var theirs: [2048]u8 = undefined;

    // The client opens with a SYN.
    const syn = peer.open("GET /probe HTTP/1.1\r\n\r\n", 0);
    const syn_tcp = tcpIn(syn).?;
    try testing.expectEqual(flag_syn, syn_tcp.flags);
    try testing.expectEqual(@as(u16, 80), syn_tcp.dst_port);

    // The guest answers it, and the request rides our last acknowledgement.
    const their_isn: u32 = 5000;
    const ack = peer.answer(fakeSegment(&theirs, flag_syn | flag_ack, their_isn, syn_tcp.seq +% 1, ""), 0).?;
    const ack_tcp = tcpIn(ack).?;
    try testing.expect(ack_tcp.flags & flag_ack != 0);
    try testing.expectEqual(their_isn +% 1, ack_tcp.ack);
    try testing.expectEqualStrings("", ack_tcp.data); // the handshake's own ACK carries nothing

    // And then the request, in a segment of its own.
    const asked = tcpIn(peer.more(0).?).?;
    try testing.expectEqualStrings("GET /probe HTTP/1.1\r\n\r\n", asked.data);
    try testing.expect(peer.more(0) == null); // and only once

    // The answer comes back in two segments, as any answer might.
    const head = "HTTP/1.1 200 OK\r\ncontent-length: 5\r\n\r\n";
    _ = peer.answer(fakeSegment(&theirs, flag_psh | flag_ack, their_isn +% 1, 0, head), 0);
    _ = peer.answer(fakeSegment(&theirs, flag_psh | flag_ack, their_isn +% 1 +% @as(u32, head.len), 0, "hello"), 0);
    try testing.expectEqual(@as(u16, 200), peer.tcp.status());
    try testing.expectEqualStrings("hello", peer.tcp.body());

    // The guest closes; the client says goodbye and is done.
    const after = their_isn +% 1 +% @as(u32, head.len) +% 5;
    const fin = peer.answer(fakeSegment(&theirs, flag_fin | flag_ack, after, 0, ""), 0).?;
    try testing.expect(tcpIn(fin).?.flags & flag_fin != 0);
    _ = peer.answer(fakeSegment(&theirs, flag_ack, after +% 1, 0, ""), 0);
    try testing.expectEqual(Tcp.State.done, peer.tcp.state);
}

test "a segment out of order is re-acknowledged rather than taken" {
    var peer = Peer{};
    var theirs: [2048]u8 = undefined;
    const syn = tcpIn(peer.open("GET / HTTP/1.1\r\n\r\n", 0)).?;
    _ = peer.answer(fakeSegment(&theirs, flag_syn | flag_ack, 5000, syn.seq +% 1, ""), 0);

    // A segment from further along than we have reached.
    const reply = peer.answer(fakeSegment(&theirs, flag_psh | flag_ack, 9999, 0, "later"), 0).?;
    const tcp = tcpIn(reply).?;
    try testing.expectEqual(@as(u32, 5001), tcp.ack); // still asking for what is missing
    try testing.expectEqual(@as(usize, 0), peer.tcp.reply_len);
}

test "a reset ends it, rather than leaving a client that waits forever" {
    var peer = Peer{};
    var theirs: [2048]u8 = undefined;
    _ = peer.open("GET / HTTP/1.1\r\n\r\n", 0);
    try testing.expect(peer.answer(fakeSegment(&theirs, flag_rst, 0, 0, ""), 0) == null);
    try testing.expectEqual(Tcp.State.refused, peer.tcp.state);
}

test "a frame for another port, or no frame at all, is not answered" {
    var peer = Peer{};
    var buf: [512]u8 = undefined;
    @memset(buf[0..60], 0);
    writeBe16(buf[12..14], 0x0806); // ARP, which this peer does not speak
    try testing.expect(peer.answer(buf[0..60], 0) == null);
    try testing.expect(peer.answer(buf[0..20], 0) == null);
}

// ── a peer that misbehaves, driven by hand ──────────────────────────────────

const ms = std.time.ns_per_ms;
const sec = std.time.ns_per_s;

/// A segment's TCP checksum adds up, as the guest checks it.
fn verifies(frame: []const u8) bool {
    const ip = frame[14..34];
    return pseudoChecksum(ip[12..16].*, ip[16..20].*, 6, frame[34..]) == 0;
}

/// A peer through its handshake with the guest (ISN 5000), its request sent.
fn opened(peer: *Peer, rough: Rough, request: []const u8, now: u64) !void {
    var theirs: [2048]u8 = undefined;
    peer.rough = rough;
    const syn = tcpIn(peer.open(request, now)).?;
    _ = peer.answer(fakeSegment(&theirs, flag_syn | flag_ack, 5000, syn.seq +% 1, ""), now).?;
    while (peer.more(now)) |_| {}
    try testing.expectEqual(Tcp.State.established, peer.tcp.state);
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

test "a lost SYN is sent again after a second, then two seconds after that" {
    var peer = Peer{ .rough = .{ .retransmits = true } };
    const first = tcpIn(peer.open("GET / HTTP/1.1\r\n\r\n", 0)).?;
    try testing.expectEqual(@as(?u64, sec), peer.wakeAt());
    try testing.expect(peer.due(sec - 1) == null);
    const again = tcpIn(peer.due(sec).?).?;
    try testing.expectEqual(flag_syn, again.flags);
    try testing.expectEqual(first.seq, again.seq);
    try testing.expectEqual(@as(?u64, 3 * sec), peer.wakeAt()); // RFC 6298 §5.5
}

test "the request goes a segment at a time, and a timeout sends the oldest unacknowledged again" {
    var peer = Peer{};
    var theirs: [2048]u8 = undefined;
    peer.rough = .{ .retransmits = true, .mss = 10 };
    const syn = tcpIn(peer.open("abcdefghijklmnopqrstuvwxy", 0)).?;
    _ = peer.answer(fakeSegment(&theirs, flag_syn | flag_ack, 5000, syn.seq +% 1, ""), 0).?;
    try testing.expect(peer.wakeAt() == null); // the SYN is acknowledged
    var seqs: [3]u32 = undefined;
    for (&seqs) |*q| q.* = tcpIn(peer.more(0).?).?.seq;
    try testing.expect(peer.more(0) == null);
    try testing.expectEqualSlices(u32, &.{ 1001, 1011, 1021 }, &seqs);
    // The guest has the first ten bytes only: the timer restarts from there.
    _ = peer.answer(fakeSegment(&theirs, flag_ack, 5001, 1011, ""), 500 * ms);
    try testing.expectEqual(@as(?u64, 1500 * ms), peer.wakeAt());
    const again = tcpIn(peer.due(1500 * ms).?).?;
    try testing.expectEqual(@as(u32, 1011), again.seq);
    try testing.expectEqualStrings("klmnopqrst", again.data);
    // All of it acknowledged: the timer stops.
    _ = peer.answer(fakeSegment(&theirs, flag_ack, 5001, 1026, ""), 2 * sec);
    try testing.expect(peer.wakeAt() == null);
}

test "a FIN is sent again until the acknowledgement that covers it" {
    var peer = Peer{};
    var theirs: [2048]u8 = undefined;
    try opened(&peer, .{ .retransmits = true }, "GET", 0);
    _ = peer.answer(fakeSegment(&theirs, flag_ack, 5001, 1004, ""), 0);
    const fin = tcpIn(peer.answer(fakeSegment(&theirs, flag_fin | flag_ack, 5001, 1004, ""), 0).?).?;
    try testing.expect(fin.flags & flag_fin != 0);
    // An acknowledgement short of the FIN does not end it.
    _ = peer.answer(fakeSegment(&theirs, flag_ack, 5002, 1004, ""), 10 * ms);
    try testing.expectEqual(Tcp.State.closing, peer.tcp.state);
    const again = tcpIn(peer.due(sec).?).?;
    try testing.expect(again.flags & flag_fin != 0);
    try testing.expectEqual(fin.seq, again.seq);
    _ = peer.answer(fakeSegment(&theirs, flag_ack, 5002, 1005, ""), sec + 1);
    try testing.expectEqual(Tcp.State.done, peer.tcp.state);
    try testing.expect(peer.wakeAt() == null);
}

test "a peer that has sent the same thing too often gives up, and is a closed port" {
    var peer = Peer{ .rough = .{ .retransmits = true } };
    var theirs: [2048]u8 = undefined;
    _ = peer.open("GET", 0);
    var sent: usize = 1; // the first SYN
    while (peer.wakeAt()) |at| {
        if (peer.due(at)) |_| sent += 1;
    }
    try testing.expectEqual(@as(usize, max_tries), sent);
    try testing.expectEqual(Tcp.State.gave_up, peer.tcp.state);
    const rst = tcpIn(peer.answer(fakeSegment(&theirs, flag_syn | flag_ack, 5000, 1001, ""), 0).?).?;
    try testing.expectEqual(flag_rst, rst.flags);
}

test "an exact reset, at the next sequence number, and a closed port after it" {
    var peer = Peer{};
    var theirs: [2048]u8 = undefined;
    try opened(&peer, .{ .reset_after_ns = 5 * ms }, "GET", 100);
    try testing.expectEqual(@as(?u64, 100 + 5 * ms), peer.wakeAt());
    const rst_frame = peer.due(100 + 5 * ms).?;
    try testing.expect(verifies(rst_frame));
    const rst = tcpIn(rst_frame).?;
    try testing.expectEqual(flag_rst, rst.flags);
    try testing.expectEqual(@as(u32, 1004), rst.seq); // SND.NXT: past the SYN and "GET"
    try testing.expectEqual(Tcp.State.reset, peer.tcp.state);
    try testing.expect(peer.wakeAt() == null);
    // RFC 9293 §3.10.7.1: with ACK, a reset at what it acknowledged...
    const a = tcpIn(peer.answer(fakeSegment(&theirs, flag_ack | flag_psh, 5001, 1004, "HTTP"), 0).?).?;
    try testing.expectEqual(flag_rst, a.flags);
    try testing.expectEqual(@as(u32, 1004), a.seq);
    // ...without, a reset acknowledging all of it (a SYN counts one).
    const b = tcpIn(peer.answer(fakeSegment(&theirs, flag_syn, 7000, 0, ""), 0).?).?;
    try testing.expectEqual(flag_rst | flag_ack, b.flags);
    try testing.expectEqual(@as(u32, 7001), b.ack);
    // And a reset is not answered.
    try testing.expect(peer.answer(fakeSegment(&theirs, flag_rst, 5001, 0, ""), 0) == null);
}

test "an inexact reset lands inside the window, off by what was asked" {
    var peer = Peer{};
    try opened(&peer, .{ .reset_after_ns = ms, .reset_off = 300 }, "GET", 0);
    const rst = tcpIn(peer.due(ms).?).?;
    try testing.expectEqual(@as(u32, 1004 + 300), rst.seq);
}

test "a reset whose time comes before the connection opens never happens" {
    var peer = Peer{ .rough = .{ .reset_after_ns = ms } };
    var theirs: [2048]u8 = undefined;
    const syn = tcpIn(peer.open("GET", 0)).?;
    try testing.expect(peer.due(ms) == null);
    _ = peer.answer(fakeSegment(&theirs, flag_syn | flag_ack, 5000, syn.seq +% 1, ""), 2 * ms);
    try testing.expect(peer.wakeAt() == null);
    try testing.expect(peer.due(10 * ms) == null);
    try testing.expectEqual(Tcp.State.established, peer.tcp.state);
}

test "a peer that vanishes part-way through the answer says nothing more" {
    var peer = Peer{};
    var theirs: [2048]u8 = undefined;
    try opened(&peer, .{ .vanish_after = 6, .retransmits = true }, "GET", 0);
    try testing.expect(peer.answer(fakeSegment(&theirs, flag_ack | flag_psh, 5001, 1004, "HTTP/1"), 0) == null);
    try testing.expectEqual(Tcp.State.gone, peer.tcp.state);
    try testing.expect(peer.answer(fakeSegment(&theirs, flag_ack | flag_psh, 5007, 1004, ".1 200"), 0) == null);
    try testing.expect(peer.wakeAt() == null);
    try testing.expectEqual(@as(usize, 6), peer.tcp.reply_len);
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
    // The guest's SYN-ACK to one of them goes unanswered: it never finishes.
    var reply = fakeSegment(&theirs, flag_syn | flag_ack, 9000, 7001, "");
    _ = &reply;
    theirs[36] = 0x9C; // to port 40000
    theirs[37] = 0x40;
    try testing.expect(peer.answer(theirs[0..reply.len], 0) == null);
}

test "a shut window takes nothing and says so, then opens and says that" {
    var peer = Peer{};
    var theirs: [2048]u8 = undefined;
    try opened(&peer, .{ .shut_after = 5, .shut_for_ns = 50 * ms }, "GET", 0);
    const shut = tcpIn(peer.answer(fakeSegment(&theirs, flag_ack | flag_psh, 5001, 1004, "HTTP/"), 0).?).?;
    try testing.expectEqual(@as(u32, 5006), shut.ack);
    const shut_frame = peer.answer(fakeSegment(&theirs, flag_ack | flag_psh, 5006, 1004, "1"), ms).?;
    try testing.expectEqual(@as(u16, 0), readBe16(shut_frame[34 + 14 ..][0..2]));
    // The probe's byte is not taken: still asking for 5006.
    try testing.expectEqual(@as(u32, 5006), tcpIn(shut_frame).?.ack);
    try testing.expectEqual(@as(usize, 5), peer.tcp.reply_len);
    // Nor a FIN, which takes sequence space the window does not have.
    _ = peer.answer(fakeSegment(&theirs, flag_fin | flag_ack, 5006, 1004, ""), ms);
    try testing.expectEqual(Tcp.State.established, peer.tcp.state);
    // It opens when it said it would, and says so.
    try testing.expectEqual(@as(?u64, 50 * ms), peer.wakeAt());
    const open_frame = peer.due(50 * ms).?;
    try testing.expectEqual(window_open, readBe16(open_frame[34 + 14 ..][0..2]));
    try testing.expectEqual(@as(u32, 5006), tcpIn(open_frame).?.ack);
    _ = peer.answer(fakeSegment(&theirs, flag_ack | flag_psh, 5006, 1004, "1"), 51 * ms);
    try testing.expectEqual(@as(usize, 6), peer.tcp.reply_len);
}

test "an acknowledgement of what was never sent moves nothing" {
    var peer = Peer{};
    var theirs: [2048]u8 = undefined;
    try opened(&peer, .{ .retransmits = true }, "GET", 0);
    // RFC 9293 §3.10.7.4: SEG.ACK past SND.NXT acknowledges nothing.
    _ = peer.answer(fakeSegment(&theirs, flag_ack, 5001, 1004 + 50, ""), 0);
    try testing.expectEqual(@as(u32, 1001), peer.tcp.una);
    try testing.expectEqual(@as(?u64, std.time.ns_per_s), peer.wakeAt());
    _ = peer.answer(fakeSegment(&theirs, flag_ack, 5001, 1004, ""), 0);
    try testing.expect(peer.wakeAt() == null);
}
