//! **ONE CLIENT OF THE PEER, AS A TCP** (RFC 9293, RFC 6298): it connects to
//! the guest, asks what it was told to, reads the answers, and closes, its
//! sequence numbers counted and its retransmission timer on the machine's
//! clock. peer.zig decides how many there are and how they misbehave
//! (`Rough`, `Plan`); this is how each one behaves.

const std = @import("std");
const frames = @import("frames.zig");
const peer_zig = @import("peer.zig");
const Rough = peer_zig.Rough;
const Peer = peer_zig.Peer;
const Response = @import("response.zig").Response;
const peer_mac = frames.peer_mac;
const card_mac = frames.card_mac;
const guest_ip = frames.guest_ip;
const server_ip = frames.server_ip;
const dns_ip = frames.dns_ip;
const netmask = frames.netmask;
const broadcast_ip = frames.broadcast_ip;
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
const most_data = frames.most_data;
const default_mss = frames.default_mss;
const fakeSynAck = frames.fakeSynAck;

pub fn earliest(a: ?u64, b: ?u64) ?u64 {
    const x = a orelse return b;
    const y = b orelse return x;
    return @min(x, y);
}

/// RFC 6298 §2: the first timeout is a second, and each one after a timeout
/// doubles, to a minute. A peer that has sent the same thing this many times
/// gives up on the connection.
const initial_rto_ns: u64 = std.time.ns_per_s;
const max_rto_ns: u64 = 60 * std.time.ns_per_s;
const max_tries: u8 = 8;

/// **HOW ONE CLIENT IS TO BEHAVE**: what it asks and how often, and where it
/// stands on the wire.
pub const Ask = struct {
    request: []const u8,
    /// How many times it asks, one after another on the same connection: the
    /// next goes when the answer to the last is whole (keep-alive). A client
    /// that asks more than once closes the connection itself after its last
    /// answer; one that asks once leaves that to the server, as before.
    asks: u32 = 1,
    port: u16 = 49152,
    /// A fixed first sequence number, because two runs of the same guest
    /// should look the same on the wire.
    iss: u32 = 1000,
};

/// A client that fetches what it was told to and then closes, which is all
/// the probes ask of it. **Sequence numbers are counted, not guessed**: the
/// guest's table checks them, refuses a segment that is not the next one, and
/// answers a reset for a connection it does not know — so a client that
/// drifts is told about it immediately rather than hanging.
pub const Tcp = struct {
    pub const State = enum {
        idle,
        syn_sent,
        established,
        /// The guest closed first, and our FIN answered it.
        closing,
        /// We closed first (after a keep-alive's last answer), and wait for
        /// the guest's FIN.
        fin_wait,
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

    state: State = .idle,
    port: u16 = 49152,
    iss: u32 = 1000,
    /// SND.NXT, SND.UNA and RCV.NXT (RFC 9293 §3.3.1).
    seq: u32 = 1000,
    una: u32 = 1000,
    ack: u32 = 0,
    /// What it asks, and how many times. **THE REQUEST GOES IN ITS OWN
    /// SEGMENT**, after the handshake's last acknowledgement rather than
    /// riding along with it. Both are legal, and an ordinary client does the
    /// second — which matters, because a guest whose table reports "the
    /// connection opened" and "data arrived" as different events may only
    /// look at the buffer on the second.
    request: []const u8 = "",
    asks: u32 = 1,
    /// An empty request is still one segment, once.
    owes_empty: bool = false,
    /// It has sent its FIN, at the sequence number just past everything it
    /// asked.
    fin_sent: bool = false,
    /// The first 64 KiB of everything that came back; `received` counts all
    /// of it.
    reply: [64 * 1024]u8 = undefined,
    reply_len: usize = 0,
    received: u64 = 0,
    /// The answer being read, and how many have come whole.
    answer: Response = .{},
    answers: u32 = 0,

    rough: Rough = .{},
    /// **THE MOST ONE SEGMENT OF OURS MAY CARRY**: what the guest announced
    /// in its SYN-ACK, or 536 if it announced nothing, and never more than a
    /// frame holds (RFC 9293 §3.7.1). `Rough.mss` may make it smaller.
    send_mss: usize = default_mss,
    /// **SND.WND**: the window the guest last offered, from SND.UNA. A plain
    /// client sends nothing past it (RFC 9293 §3.8.6); one that ignores it
    /// (`Rough.ignore_window`) sends everything at once.
    snd_wnd: u32 = 65535,
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

    pub fn open(self: *Tcp, ask: Ask, now: u64, rough: Rough, out: []u8) []const u8 {
        self.* = .{
            .state = .syn_sent,
            .request = ask.request,
            .asks = @max(ask.asks, 1),
            .port = ask.port,
            .iss = ask.iss,
            .seq = ask.iss,
            .una = ask.iss,
            .rough = rough,
            .opened_at = now,
        };
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
                self.send_mss = std.math.clamp(@as(usize, s.mss orelse default_mss), 1, most_data);
                self.snd_wnd = s.window;
                self.state = .established;
                self.owes_empty = self.request.len == 0;
                self.acknowledged(self.seq, now);
                return self.segment(out, flag_ack, "");
            },
            .established, .closing, .fin_wait => {
                if (s.flags & flag_ack != 0) {
                    self.acknowledged(s.ack, now);
                    // The window counts from what it acknowledges, so an
                    // acknowledgement older than SND.UNA says nothing of it.
                    if (s.ack == self.una) self.snd_wnd = s.window;
                }
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
                    self.received += s.data.len;
                    self.ack +%= @intCast(s.data.len);
                    self.read(s.data);
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
                    self.answer.closed(); // an answer read to the close is whole
                    if (self.answer.phase == .done) self.answered();
                    if (self.state == .established) {
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

    /// The answer's bytes, as they come: each one that comes whole lets the
    /// next request go.
    fn read(self: *Tcp, data: []const u8) void {
        var rest = data;
        while (rest.len > 0) {
            const used = self.answer.feed(rest);
            rest = rest[used..];
            if (self.answer.phase != .done) break;
            self.answered();
        }
    }

    fn answered(self: *Tcp) void {
        self.answers += 1;
        self.answer = .{};
    }

    /// How much of what it asks it may send by now: one request for each
    /// answer that came whole, and one more.
    fn released(self: *const Tcp) usize {
        return self.request.len * @min(self.answers + 1, self.asks);
    }

    /// Bytes of its requests it has sent.
    fn sent(self: *const Tcp) usize {
        return self.seq -% (self.iss +% 1) -% @intFromBool(self.fin_sent);
    }

    /// The bytes from `from` on that one segment may carry: up to the MSS
    /// the guest announced and `Rough.mss`, within one request, and no
    /// further than is released.
    fn chunk(self: *const Tcp, from: usize) []const u8 {
        const within = from % self.request.len;
        const most = @min(self.rough.mss orelse self.send_mss, self.send_mss);
        const n = @min(most, self.request.len - within, self.released() - from);
        return self.request[within..][0..n];
    }

    /// How much more the guest's window has room for past SND.NXT; all of it
    /// for a client that ignores the window.
    fn windowRoom(self: *const Tcp) usize {
        if (self.rough.ignore_window) return std.math.maxInt(usize);
        const in_flight = self.seq -% self.una;
        return self.snd_wnd -| in_flight;
    }

    /// The next thing this client has to say without being spoken to, if
    /// anything: its next request's bytes, or, after the last answer of a
    /// client that asked more than once, its FIN. Called after every
    /// answer, because one thing arriving can mean two things to send.
    pub fn more(self: *Tcp, now: u64, out: []u8) ?[]const u8 {
        if (self.state != .established) return null;
        if (self.request.len == 0) {
            if (!self.owes_empty) return null;
            self.owes_empty = false;
            return self.segment(out, flag_ack | flag_psh, "");
        }
        const from = self.sent();
        if (from < self.released()) {
            const next = self.chunk(from);
            const data = next[0..@min(next.len, self.windowRoom())];
            if (data.len == 0) return null; // the window is full: wait for it
            const frame = self.segment(out, flag_ack | flag_psh, data);
            self.seq +%= @intCast(data.len);
            self.arm(now);
            return frame;
        }
        if (self.asks > 1 and self.answers >= self.asks) {
            self.state = .fin_wait;
            const frame = self.segment(out, flag_fin | flag_ack, "");
            self.seq +%= 1;
            self.fin_sent = true;
            self.arm(now);
            return frame;
        }
        return null;
    }

    /// **WHAT IT SAYS ON ITS OWN, BY `now`**: its reset, its window reopened,
    /// or what its timer sends again. One frame a call.
    pub fn due(self: *Tcp, now: u64, out: []u8) ?[]const u8 {
        if (self.resetAt()) |at| if (now >= at) {
            self.reset_past = true;
            if (self.state != .established and self.state != .closing and self.state != .fin_wait) return null;
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
    /// a segment's worth of a request, or the FIN.
    fn again(self: *Tcp, out: []u8) []const u8 {
        if (self.state == .syn_sent) return build(out, server_ip, self.port, self.iss, 0, flag_syn, self.window(), "");
        const data_end = self.iss +% 1 +% @as(u32, @intCast(self.sent()));
        const from: usize = self.una -% (self.iss +% 1);
        if (self.una != data_end and self.request.len > 0) {
            return build(out, server_ip, self.port, self.una, self.ack, flag_ack | flag_psh, self.window(), self.chunk(from));
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

// ── what can be checked without a guest ──────────────────────────────────────

const testing = std.testing;
const ms = std.time.ns_per_ms;
const sec = std.time.ns_per_s;

/// A peer through its handshake with the guest (ISN 5000), its request sent.
pub fn opened(peer: *Peer, rough: Rough, request: []const u8, now: u64) !void {
    var theirs: [2048]u8 = undefined;
    peer.rough = rough;
    const syn = tcpIn(peer.open(request, now)).?;
    _ = peer.answer(fakeSegment(&theirs, flag_syn | flag_ack, 5000, syn.seq +% 1, ""), now).?;
    while (peer.more(now)) |_| {}
    try testing.expectEqual(Tcp.State.established, peer.tcp.state);
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

test "keep-alive: the second request goes when the first answer is whole, then the client closes" {
    var peer = Peer{ .plan = .{ .asks = 2 } };
    var theirs: [2048]u8 = undefined;
    const req = "GET / HTTP/1.1\r\n\r\n";
    const syn = tcpIn(peer.open(req, 0)).?;
    _ = peer.answer(fakeSegment(&theirs, flag_syn | flag_ack, 5000, syn.seq +% 1, ""), 0).?;
    const first = tcpIn(peer.more(0).?).?;
    try testing.expectEqualStrings(req, first.data);
    try testing.expect(peer.more(0) == null); // not until the answer is whole

    const answer = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi";
    const after_req: u32 = 1001 + @as(u32, req.len);
    // Half the answer: still nothing to say but its acknowledgement.
    _ = peer.answer(fakeSegment(&theirs, flag_ack, 5001, after_req, answer[0..20]), 0).?;
    try testing.expect(peer.more(0) == null);
    _ = peer.answer(fakeSegment(&theirs, flag_ack | flag_psh, 5001 + 20, after_req, answer[20..]), 0).?;
    try testing.expectEqual(@as(u32, 1), peer.tcp.answers);
    const second = tcpIn(peer.more(0).?).?;
    try testing.expectEqualStrings(req, second.data);
    try testing.expectEqual(after_req, second.seq);
    try testing.expect(peer.more(0) == null);

    // The second answer: then its FIN, ours first.
    const at: u32 = 5001 + @as(u32, answer.len);
    _ = peer.answer(fakeSegment(&theirs, flag_ack | flag_psh, at, after_req + @as(u32, req.len), answer), 0).?;
    const fin = tcpIn(peer.more(0).?).?;
    try testing.expectEqual(flag_fin | flag_ack, fin.flags);
    try testing.expectEqual(after_req + @as(u32, req.len), fin.seq);
    try testing.expectEqual(Tcp.State.fin_wait, peer.tcp.state);
    // The guest acknowledges it, then closes too: the client is done.
    const theirs_at = at + @as(u32, answer.len);
    try testing.expect(peer.answer(fakeSegment(&theirs, flag_ack, theirs_at, fin.seq + 1, ""), 0) == null);
    try testing.expectEqual(Tcp.State.fin_wait, peer.tcp.state);
    const last = tcpIn(peer.answer(fakeSegment(&theirs, flag_fin | flag_ack, theirs_at, fin.seq + 1, ""), 0).?).?;
    try testing.expectEqual(flag_ack, last.flags);
    try testing.expectEqual(theirs_at + 1, last.ack);
    try testing.expectEqual(Tcp.State.done, peer.tcp.state);
    try testing.expectEqual(@as(u32, 2), peer.tcp.answers);
}

test "a client reading a stream holds its connection open, however much comes" {
    var peer = Peer{};
    var theirs: [2048]u8 = undefined;
    try opened(&peer, .{}, "GET /chat/stream HTTP/1.1\r\n\r\n", 0);
    const head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n";
    var at: u32 = 5001;
    _ = peer.answer(fakeSegment(&theirs, flag_ack | flag_psh, at, 0, head), 0).?;
    at += head.len;
    const event = "data: a message for the room\n\n" ** 40;
    for (0..100) |_| {
        const ack = tcpIn(peer.answer(fakeSegment(&theirs, flag_ack | flag_psh, at, 0, event), 0).?).?;
        at += event.len;
        try testing.expectEqual(at, ack.ack);
    }
    try testing.expectEqual(Tcp.State.established, peer.tcp.state);
    try testing.expectEqual(@as(u32, 0), peer.tcp.answers);
    try testing.expectEqual(@as(u64, head.len + 100 * event.len), peer.tcp.received);
    try testing.expect(peer.more(0) == null);
}

test "a timeout during the second request sends the second request's bytes again" {
    var peer = Peer{ .rough = .{ .retransmits = true, .mss = 4 }, .plan = .{ .asks = 2 } };
    var theirs: [2048]u8 = undefined;
    const req = "GET /x\r\n\r\n"; // 10 bytes: 4, 4 and 2
    const syn = tcpIn(peer.open(req, 0)).?;
    _ = peer.answer(fakeSegment(&theirs, flag_syn | flag_ack, 5000, syn.seq +% 1, ""), 0).?;
    while (peer.more(0)) |_| {}
    try testing.expectEqual(@as(u32, 1011), peer.tcp.seq);
    const answer = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n";
    _ = peer.answer(fakeSegment(&theirs, flag_ack, 5001, 1011, answer), 10);
    var sent: [3][]const u8 = undefined;
    var copies: [3][8]u8 = undefined;
    for (0..3) |i| {
        const d = tcpIn(peer.more(10).?).?.data;
        @memcpy(copies[i][0..d.len], d);
        sent[i] = copies[i][0..d.len];
    }
    try testing.expectEqualStrings("GET ", sent[0]);
    try testing.expectEqualStrings("/x\r\n", sent[1]);
    try testing.expectEqualStrings("\r\n", sent[2]);
    // The guest has none of the second: the timer sends its first chunk.
    const again = tcpIn(peer.due(peer.wakeAt().?).?).?;
    try testing.expectEqual(@as(u32, 1011), again.seq);
    try testing.expectEqualStrings("GET ", again.data);
}

test "a request larger than a segment goes at the MSS the guest announced, or 536" {
    // Item 37: a 20 KB request panicked the peer, which sent it in one
    // segment through its 2048-byte scratch.
    var request: [20 * 1024]u8 = undefined;
    for (&request, 0..) |*b, i| b.* = @truncate('a' + i % 26);
    const cases = [_]struct { mss: ?u16, rough: ?usize, each: usize }{
        .{ .mss = null, .rough = null, .each = 536 },
        .{ .mss = 1460, .rough = null, .each = 1460 },
        .{ .mss = 9000, .rough = null, .each = 1460 }, // no more than a frame holds
        .{ .mss = 100, .rough = null, .each = 100 },
        .{ .mss = 0, .rough = null, .each = 1 },
        .{ .mss = 1460, .rough = 300, .each = 300 }, // PEER_MSS is smaller still
        .{ .mss = 200, .rough = 300, .each = 200 }, // but never larger than announced
    };
    for (cases) |c| {
        var peer = Peer{ .rough = .{ .mss = c.rough } };
        var theirs: [2048]u8 = undefined;
        const syn = tcpIn(peer.open(&request, 0)).?;
        const syn_ack = if (c.mss) |m| fakeSynAck(&theirs, 5000, syn.seq +% 1, m) else fakeSegment(&theirs, flag_syn | flag_ack, 5000, syn.seq +% 1, "");
        _ = peer.answer(syn_ack, 0).?;
        var got: usize = 0;
        while (got < request.len) {
            // A window's worth at a time: the guest acknowledges all of it,
            // and offers fakeSegment's 8192 again. 8192 is a whole number
            // of no segment size here, so a short segment ends each window.
            const window_start = got;
            while (peer.more(0)) |frame| {
                const seg = tcpIn(frame).?;
                try testing.expect(verifies(frame));
                try testing.expect(seg.data.len <= c.each);
                const window_left = 8192 - (got - window_start);
                if (got + c.each <= request.len and window_left >= c.each) try testing.expectEqual(c.each, seg.data.len);
                try testing.expectEqualSlices(u8, request[got..][0..seg.data.len], seg.data);
                got += seg.data.len;
            }
            try testing.expect(got > window_start);
            _ = peer.answer(fakeSegment(&theirs, flag_ack, 5001, syn.seq +% 1 +% @as(u32, @intCast(got)), ""), 0);
        }
        try testing.expectEqual(request.len, got);
    }
}

test "a plain client keeps to the guest's window; one that ignores it sends everything" {
    var request: [20 * 1024]u8 = undefined;
    for (&request, 0..) |*b, i| b.* = @truncate('a' + i % 26);
    var theirs: [2048]u8 = undefined;

    // The guest offers 8192 in its SYN-ACK (fakeSegment's window).
    var plain = Peer{};
    const syn = tcpIn(plain.open(&request, 0)).?;
    _ = plain.answer(fakeSynAck(&theirs, 5000, syn.seq +% 1, 1460), 0).?;
    var sent: usize = 0;
    while (plain.more(0)) |frame| sent += tcpIn(frame).?.data.len;
    try testing.expectEqual(@as(usize, 8192), sent); // five of 1460, and 892
    // It acknowledges 4000 and offers 8192 again: 4000 more go.
    _ = plain.answer(fakeSegment(&theirs, flag_ack, 5001, syn.seq +% 1 +% 4000, ""), 0);
    var more: usize = 0;
    while (plain.more(0)) |frame| more += tcpIn(frame).?.data.len;
    try testing.expectEqual(@as(usize, 4000), more);
    // An old acknowledgement offering a larger window says nothing of it.
    _ = plain.answer(fakeTo(&theirs, 49152, flag_ack, 5001, syn.seq +% 1 +% 100, ""), 0);
    try testing.expect(plain.more(0) == null);

    var careless = Peer{ .rough = .{ .ignore_window = true } };
    const syn2 = tcpIn(careless.open(&request, 0)).?;
    _ = careless.answer(fakeSynAck(&theirs, 5000, syn2.seq +% 1, 1460), 0).?;
    var all: usize = 0;
    while (careless.more(0)) |frame| all += tcpIn(frame).?.data.len;
    try testing.expectEqual(request.len, all);
}
