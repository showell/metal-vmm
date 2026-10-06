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

/// `a` comes before `b`, modulo 2^32.
fn before(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) < 0;
}

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
/// **THE FLOOR, LINUX'S** (RFC 6298 §2.4 allows it): a measured path as
/// short as this one would otherwise time out within its own round trip.
const min_rto_ns: u64 = 200 * std.time.ns_per_ms;
/// RFC 6298's G, the clock's granularity.
const granularity_ns: u64 = std.time.ns_per_ms;
const max_tries: u8 = 8;
/// **TIME-WAIT LASTS 2MSL** (RFC 9293 §3.10.7.4): Linux's 60 s, of the
/// guest's time.
const time_wait_ns: u64 = 60 * std.time.ns_per_s;

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
    /// The segment SND.WND was last taken from (RFC 9293 §3.10.7.4), so an
    /// older one, reordered, does not take it back.
    snd_wl1: u32 = 0,
    snd_wl2: u32 = 0,
    /// **THE PERSIST TIMER** (§3.8.6.1): with the window shut and bytes
    /// waiting, a byte past it is sent this often, doubling to a minute,
    /// whatever the knobs, and never counted toward giving up.
    persist_at: ?u64 = null,
    persist_ns: u64 = initial_rto_ns,
    opened_at: u64 = 0,
    /// The retransmission timer: when it goes off, and how long the next
    /// wait is.
    timer_at: ?u64 = null,
    rto_ns: u64 = initial_rto_ns,
    tries: u8 = 0,
    /// **THE ROUND TRIP, MEASURED** (RFC 6298 §2-3): one segment timed at a
    /// time, never one sent twice (Karn), and the estimates from it.
    timed: ?struct { end: u32, at: u64 } = null,
    srtt_ns: ?u64 = null,
    rttvar_ns: u64 = 0,
    /// Duplicate acknowledgements in a row (RFC 5681 §3.2): three resend
    /// the oldest unacknowledged at once.
    dupacks: u8 = 0,
    /// **AFTER A TIMEOUT, EVERYTHING FROM SND.UNA GOES AGAIN**, within the
    /// window: what is still to be sent again, by sequence number.
    resend_from: u32 = 0,
    resend_to: u32 = 0,
    /// The reset is behind it, done or let go of because the connection was
    /// not open when its time came.
    reset_past: bool = false,
    /// While its window is shut, when it opens; and whether it has shut yet.
    shut_until: ?u64 = null,
    shut_ever: bool = false,
    /// A slow client's next segment may go then (`Rough.drip_ns`).
    drip_at: ?u64 = null,
    /// **IN TIME-WAIT UNTIL THEN**: it closed first, and the guest's FIN
    /// came. Its state is still `done`, as every run's report has it.
    time_wait_until: ?u64 = null,

    pub fn open(self: *Tcp, ask: Ask, now: u64, rough: Rough, out: []u8) []const u8 {
        self.* = .{
            .state = .syn_sent,
            .request = ask.request,
            .asks = @max(ask.asks, @as(u32, if (rough.pipeline) 2 else 1)),
            .port = ask.port,
            .iss = ask.iss,
            .seq = ask.iss,
            .una = ask.iss,
            .rough = rough,
            .opened_at = now,
        };
        const frame = self.segment(out, flag_syn, "");
        self.seq +%= 1; // the SYN takes one
        self.timed = .{ .end = self.seq, .at = now };
        self.arm(now);
        return frame;
    }

    /// What this client says back to one segment, if anything.
    pub fn receive(self: *Tcp, s: Segment, now: u64, out: []u8) ?[]const u8 {
        if (s.dst_port != self.port) return null;
        switch (self.state) {
            .gone => return null,
            // **A CLOSED CONNECTION IS A CLOSED PORT** (RFC 9293
            // §3.10.7.1): one it reset or gave up on, one the guest reset,
            // one never opened, and one finished but for TIME-WAIT.
            .reset, .gave_up, .refused, .idle => return closedPort(s, out),
            .done => {
                const until = self.time_wait_until orelse return closedPort(s, out);
                if (now >= until) return closedPort(s, out);
                return self.timeWait(s, now, out);
            },
            else => {},
        }
        if (self.state == .syn_sent) {
            // **AN ACKNOWLEDGEMENT OF ANOTHER SYN** (RFC 9293 §3.10.7.3):
            // answered with a reset at what it acknowledged; a reset that
            // does not acknowledge ours is not believed.
            const acceptable = s.flags & flag_ack != 0 and s.ack == self.iss +% 1;
            if (s.flags & flag_ack != 0 and !acceptable) {
                if (s.flags & flag_rst != 0) return null;
                return build(out, server_ip, self.port, s.ack, 0, flag_rst, 0, "");
            }
            if (s.flags & flag_rst != 0) {
                if (acceptable) self.refuse();
                return null;
            }
        } else if (s.flags & flag_rst != 0) {
            // **A RESET MUST NAME RCV.NXT** (RFC 5961 §3.2): one inside the
            // window draws a challenge ACK, anything else is ignored.
            if (s.seq == self.ack) {
                self.refuse();
                return null;
            }
            if (s.seq -% self.ack < self.window()) return self.segment(out, flag_ack, "");
            return null;
        }
        switch (self.state) {
            .syn_sent => {
                if (s.flags & flag_syn == 0 or s.flags & flag_ack == 0) return null;
                self.ack = s.seq +% 1; // their SYN takes one too
                self.send_mss = std.math.clamp(@as(usize, s.mss orelse default_mss), 1, most_data);
                self.snd_wnd = s.window;
                self.snd_wl1 = s.seq;
                self.snd_wl2 = s.ack;
                self.state = .established;
                self.owes_empty = self.request.len == 0;
                self.acknowledged(self.seq, now);
                return self.segment(out, flag_ack, "");
            },
            .established, .closing, .fin_wait => {
                // **AN ACKNOWLEDGEMENT OF WHAT WAS NEVER SENT** (RFC 9293
                // §3.10.7.4): an ACK, and the segment is dropped.
                if (s.flags & flag_ack != 0 and before(self.seq, s.ack)) return self.segment(out, flag_ack, "");
                // A duplicate acknowledgement (RFC 5681 §2): nothing new,
                // nothing carried, the window as it was, and something
                // still out.
                const duplicate = s.flags & flag_ack != 0 and s.ack == self.una and self.una != self.seq and
                    s.data.len == 0 and s.flags & (flag_syn | flag_fin) == 0 and s.window == self.snd_wnd;
                if (s.flags & flag_ack != 0) {
                    self.acknowledged(s.ack, now);
                    // The window counts from what it acknowledges, so an
                    // acknowledgement older than SND.UNA says nothing of it;
                    // nor does a segment older than the one it came from.
                    if (s.ack == self.una and (before(self.snd_wl1, s.seq) or
                        (self.snd_wl1 == s.seq and !before(s.ack, self.snd_wl2))))
                    {
                        self.snd_wnd = s.window;
                        self.snd_wl1 = s.seq;
                        self.snd_wl2 = s.ack;
                        if (s.window > 0) {
                            self.persist_at = null;
                            self.persist_ns = initial_rto_ns;
                        }
                    }
                }
                if (duplicate and self.rough.retransmits) {
                    self.dupacks +|= 1;
                    if (self.dupacks == 3) {
                        // Fast retransmit: the oldest, now, and not timed.
                        self.timed = null;
                        return self.again(out);
                    }
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
                    // Its FIN was first: TIME-WAIT, where the guest's FIN
                    // is acknowledged again if this ACK is lost.
                    if (self.state == .fin_wait) self.time_wait_until = now + time_wait_ns;
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

    /// **TIME-WAIT** (RFC 9293 §3.10.7.4): the guest's FIN again is
    /// acknowledged again, and the wait restarts; anything else unacceptable
    /// is acknowledged; a reset is let be (RFC 1337). An acknowledgement of
    /// our own FIN, which a simultaneous close can still be waiting for,
    /// stops its timer.
    fn timeWait(self: *Tcp, s: Segment, now: u64, out: []u8) ?[]const u8 {
        if (s.flags & flag_rst != 0) return null;
        if (s.flags & flag_ack != 0) self.acknowledged(s.ack, now);
        if (s.flags & flag_fin != 0) {
            self.time_wait_until = now + time_wait_ns;
            return self.segment(out, flag_ack, "");
        }
        if (s.data.len > 0 or s.seq != self.ack) return self.segment(out, flag_ack, "");
        return null;
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
        if (self.rough.pipeline) return self.request.len * self.asks;
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
            if (self.drip_at) |at| if (now < at) return null; // a slow client waits
            const next = self.chunk(from);
            const data = next[0..@min(next.len, self.windowRoom())];
            if (data.len == 0) {
                // The window is full: wait for it, and if it is shut with
                // nothing in flight, probe it.
                if (self.snd_wnd == 0 and self.seq == self.una and self.persist_at == null)
                    self.persist_at = now + self.persist_ns;
                return null;
            }
            const frame = self.segment(out, flag_ack | flag_psh, data);
            self.seq +%= @intCast(data.len);
            if (self.rough.drip_ns) |gap| self.drip_at = now + gap;
            self.time(now);
            self.arm(now);
            return frame;
        }
        if (self.asks > 1 and self.answers >= self.asks) {
            self.state = .fin_wait;
            const frame = self.segment(out, flag_fin | flag_ack, "");
            self.seq +%= 1;
            self.fin_sent = true;
            self.time(now);
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
        if (self.dripDue()) |at| if (now >= at) {
            if (self.more(now, out)) |frame| return frame;
            self.drip_at = null;
        };
        if (self.persist_at) |at| if (now >= at) {
            self.persist_at = null;
            if (self.snd_wnd == 0 and self.state == .established and self.sent() < self.released()) {
                // One byte past the shut window: the next one, or the one
                // already sent and not yet taken.
                const from: usize = self.una -% (self.iss +% 1);
                const byte = self.chunk(from)[0..1];
                const frame = build(out, server_ip, self.port, self.una, self.ack, flag_ack | flag_psh, self.window(), byte);
                if (self.seq == self.una) self.seq +%= 1;
                self.persist_ns = @min(self.persist_ns * 2, max_rto_ns);
                self.persist_at = now + self.persist_ns;
                return frame;
            }
        };
        if (self.timer_at) |at| if (now >= at) {
            self.tries += 1;
            if (self.tries >= max_tries) {
                self.state = .gave_up;
                self.timer_at = null;
                return null;
            }
            // RFC 6298 §5.5-5.6: back off, and resend from SND.UNA; Karn's
            // rule: nothing sent again is timed.
            self.rto_ns = @min(self.rto_ns * 2, max_rto_ns);
            self.timer_at = now + self.rto_ns;
            self.timed = null;
            const frame = self.again(out);
            if (tcpIn(frame)) |sent_again| {
                const end = sent_again.seq +% @as(u32, @intCast(sent_again.data.len));
                if (sent_again.data.len > 0 and before(end, self.dataEnd())) {
                    self.resend_from = end;
                    self.resend_to = self.dataEnd();
                }
            }
            return frame;
        };
        // The rest of what a timeout sends again, as far as the window goes.
        if (self.rough.retransmits and before(self.resend_from, self.resend_to)) {
            if (!before(self.resend_from, self.una)) {
                const off: usize = self.resend_from -% (self.iss +% 1);
                const room: usize = if (self.rough.ignore_window) std.math.maxInt(usize) else self.snd_wnd -| (self.resend_from -% self.una);
                const pending = self.chunk(off);
                const n = @min(pending.len, room, self.resend_to -% self.resend_from);
                if (n > 0) {
                    const frame = build(out, server_ip, self.port, self.resend_from, self.ack, flag_ack | flag_psh, self.window(), pending[0..n]);
                    self.resend_from +%= @intCast(n);
                    return frame;
                }
            }
            self.resend_to = self.resend_from;
        }
        return null;
    }

    /// The next instant at which `due` will have something, if any.
    pub fn wakeAt(self: *const Tcp) ?u64 {
        return earliest(earliest(earliest(earliest(self.resetAt(), self.shut_until), self.timer_at), self.persist_at), self.dripDue());
    }

    /// When a slow client's next segment goes, if one is waiting.
    fn dripDue(self: *const Tcp) ?u64 {
        const at = self.drip_at orelse return null;
        if (self.state != .established or self.sent() >= self.released()) return null;
        return at;
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

    /// Where the request bytes sent so far end, by sequence number.
    fn dataEnd(self: *const Tcp) u32 {
        return self.iss +% 1 +% @as(u32, @intCast(self.sent()));
    }

    /// The guest reset it.
    fn refuse(self: *Tcp) void {
        self.state = .refused;
        self.timer_at = null;
        self.persist_at = null;
    }

    /// What was just sent is timed, if nothing is (RFC 6298 §3).
    fn time(self: *Tcp, now: u64) void {
        if (self.timed == null) self.timed = .{ .end = self.seq, .at = now };
    }

    /// **A ROUND TRIP, MEASURED** (RFC 6298 §2.2-2.4), and the timeout it
    /// makes, between the floor and the cap.
    fn sample(self: *Tcp, r: u64) void {
        if (self.srtt_ns) |srtt| {
            const diff = if (srtt > r) srtt - r else r - srtt;
            self.rttvar_ns = (3 * self.rttvar_ns + diff) / 4;
            self.srtt_ns = (7 * srtt + r) / 8;
        } else {
            self.srtt_ns = r;
            self.rttvar_ns = r / 2;
        }
        const rto = self.srtt_ns.? + @max(granularity_ns, 4 * self.rttvar_ns);
        self.rto_ns = std.math.clamp(rto, min_rto_ns, max_rto_ns);
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
        // A segment timed, and now acknowledged: a sample. Until one comes,
        // a backed-off timeout stays backed off (RFC 6298 §5.7).
        if (self.timed) |t| if (!before(ack, t.end)) {
            self.sample(now - t.at);
            self.timed = null;
        };
        self.una = ack;
        self.tries = 0;
        self.dupacks = 0;
        if (before(self.resend_from, self.una)) self.resend_from = self.una;
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
    const syn = tcpIn(peer.open("GET / HTTP/1.1\r\n\r\n", 0)).?;
    // A reset that does not acknowledge the SYN is not believed (RFC 9293
    // §3.10.7.3); the guest's refusal of it, acknowledging it, is.
    try testing.expect(peer.answer(fakeSegment(&theirs, flag_rst, 0, 0, ""), 0) == null);
    try testing.expectEqual(Tcp.State.syn_sent, peer.tcp.state);
    try testing.expect(peer.answer(fakeSegment(&theirs, flag_rst | flag_ack, 0, syn.seq +% 1, ""), 0) == null);
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
    // The guest has the first ten bytes only: the timer restarts from there,
    // at the timeout the round trips make (RFC 6298 §2): the SYN's took no
    // time (SRTT 0, RTTVAR 0), the first segment's 500 ms (SRTT 62.5 ms,
    // RTTVAR 125 ms), so 62.5 + 4 x 125 = 562.5 ms.
    _ = peer.answer(fakeSegment(&theirs, flag_ack, 5001, 1011, ""), 500 * ms);
    try testing.expectEqual(@as(?u64, 500 * ms + 562_500_000), peer.wakeAt());
    const again = tcpIn(peer.due(500 * ms + 562_500_000).?).?;
    try testing.expectEqual(@as(u32, 1011), again.seq);
    try testing.expectEqualStrings("klmnopqrst", again.data);
    // And everything after it, at once (RFC 6298 §5.4: go back to SND.UNA).
    const rest = tcpIn(peer.due(500 * ms + 562_500_000).?).?;
    try testing.expectEqual(@as(u32, 1021), rest.seq);
    try testing.expectEqualStrings("uvwxy", rest.data);
    try testing.expect(peer.due(500 * ms + 562_500_000) == null);
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
    // RFC 9293 §3.10.7.4: SEG.ACK past SND.NXT acknowledges nothing, and
    // draws an ACK. (The timer is the floor: the SYN's round trip took no
    // time.)
    const said = tcpIn(peer.answer(fakeSegment(&theirs, flag_ack, 5001, 1004 + 50, "data"), 0).?).?;
    try testing.expectEqual(flag_ack, said.flags);
    try testing.expectEqual(@as(u32, 5001), said.ack); // and its data not taken
    try testing.expectEqual(@as(u32, 1001), peer.tcp.una);
    try testing.expectEqual(@as(?u64, min_rto_ns), peer.wakeAt());
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

test "P1: after closing first, TIME-WAIT acknowledges the guest's FIN again, then the port is closed" {
    var peer = Peer{ .plan = .{ .asks = 2 } };
    var theirs: [2048]u8 = undefined;
    const answer = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok";
    try opened(&peer, .{}, "GET / HTTP/1.1\r\n\r\n", 0);
    const c = &peer.tcp;
    // Two answers, each acknowledging what was asked; then the client's FIN.
    var their_seq: u32 = 5001;
    for (0..2) |_| {
        _ = peer.answer(fakeSegment(&theirs, flag_ack | flag_psh, their_seq, c.seq, answer), 0);
        their_seq +%= answer.len;
        while (peer.more(0)) |_| {}
    }
    try testing.expectEqual(Tcp.State.fin_wait, c.state);
    _ = peer.answer(fakeSegment(&theirs, flag_ack, their_seq, c.seq, ""), 0); // its FIN acknowledged
    // The guest's FIN: acknowledged, and TIME-WAIT begins.
    const ack = tcpIn(peer.answer(fakeSegment(&theirs, flag_fin | flag_ack, their_seq, c.seq, ""), 1 * sec).?).?;
    try testing.expectEqual(Tcp.State.done, c.state);
    try testing.expectEqual(their_seq +% 1, ack.ack);
    // The ACK was lost: the guest's FIN again is acknowledged again, 30 s on.
    const again = tcpIn(peer.answer(fakeSegment(&theirs, flag_fin | flag_ack, their_seq, c.seq, ""), 31 * sec).?).?;
    try testing.expectEqual(flag_ack, again.flags);
    try testing.expectEqual(their_seq +% 1, again.ack);
    // A plain acceptable ACK draws nothing; a reset is let be.
    try testing.expect(peer.answer(fakeSegment(&theirs, flag_ack, their_seq +% 1, c.seq, ""), 32 * sec) == null);
    try testing.expect(peer.answer(fakeSegment(&theirs, flag_rst, their_seq +% 1, 0, ""), 33 * sec) == null);
    // The wait restarted at 31 s: by 92 s it is over, and the port is closed.
    const rst = tcpIn(peer.answer(fakeSegment(&theirs, flag_fin | flag_ack, their_seq, c.seq, ""), 92 * sec).?).?;
    try testing.expect(rst.flags & flag_rst != 0);
}

test "P1: a port the guest reset, one never opened, and one closed by the guest first answer as closed ports" {
    var theirs: [2048]u8 = undefined;
    // The guest resets the connection; what it sends after draws a reset.
    var peer = Peer{};
    try opened(&peer, .{}, "GET / HTTP/1.1\r\n\r\n", 0);
    _ = peer.answer(fakeSegment(&theirs, flag_rst, 5001, 0, ""), 0);
    try testing.expectEqual(Tcp.State.refused, peer.tcp.state);
    const r1 = tcpIn(peer.answer(fakeSegment(&theirs, flag_ack, 5001, 77, "late"), 0).?).?;
    try testing.expectEqual(flag_rst, r1.flags);
    try testing.expectEqual(@as(u32, 77), r1.seq);
    // A client port not opened yet: a reset, acknowledging the segment.
    const r2 = tcpIn(peer.answer(fakeTo(&theirs, 49153, flag_syn | flag_ack, 900, 1, ""), 0).?).?;
    try testing.expect(r2.flags & flag_rst != 0);
    // A segment to a flood's address: nobody there.
    const flooded = fakeTo(&theirs, 40001, flag_syn | flag_ack, 900, 1, "");
    @memcpy(theirs[14 + 16 ..][0..4], &[_]u8{ 198, 51, 100, 1 });
    try testing.expect(peer.answer(flooded, 0) == null);
    // The guest closed first, and its FIN and ours are done: closed.
    var done = Peer{};
    try opened(&done, .{}, "GET / HTTP/1.1\r\n\r\n", 0);
    const fin = tcpIn(done.answer(fakeSegment(&theirs, flag_fin | flag_ack, 5001, done.tcp.seq, ""), 0).?).?;
    try testing.expect(fin.flags & flag_fin != 0);
    _ = done.answer(fakeSegment(&theirs, flag_ack, 5002, done.tcp.seq, ""), 0);
    try testing.expectEqual(Tcp.State.done, done.tcp.state);
    const r3 = tcpIn(done.answer(fakeSegment(&theirs, flag_fin | flag_ack, 5001, done.tcp.seq, ""), 0).?).?;
    try testing.expect(r3.flags & flag_rst != 0);
}

test "P2: a shut window is probed a byte at a time, backing off, until it opens" {
    var request: [3000]u8 = undefined;
    for (&request, 0..) |*b, i| b.* = @truncate('a' + i % 26);
    var peer = Peer{};
    var theirs: [2048]u8 = undefined;
    const syn = tcpIn(peer.open(&request, 0)).?;
    const iss = syn.seq;
    // A SYN-ACK with a shut window: nothing goes, and the persist timer runs.
    const syn_ack = fakeSynAck(&theirs, 5000, iss +% 1, 1460);
    theirs[34 + 14] = 0;
    theirs[34 + 15] = 0;
    _ = peer.answer(syn_ack, 0).?;
    try testing.expect(peer.more(0) == null);
    try testing.expectEqual(@as(?u64, sec), peer.wakeAt());
    // A second on: one byte past the window.
    const probe = tcpIn(peer.due(sec).?).?;
    try testing.expectEqual(@as(usize, 1), probe.data.len);
    try testing.expectEqual(request[0], probe.data[0]);
    try testing.expectEqual(iss +% 1, probe.seq);
    // Still shut, the byte not taken: the same byte again, two seconds on.
    var shut = fakeSegment(&theirs, flag_ack, 5001, iss +% 1, "");
    theirs[34 + 14] = 0;
    theirs[34 + 15] = 0;
    _ = &shut;
    _ = peer.answer(theirs[0..shut.len], sec);
    try testing.expectEqual(@as(?u64, 3 * sec), peer.wakeAt());
    const again = tcpIn(peer.due(3 * sec).?).?;
    try testing.expectEqual(iss +% 1, again.seq);
    try testing.expectEqual(@as(usize, 1), again.data.len);
    // It opens, the byte taken: the rest goes, and no probe is due.
    _ = peer.answer(fakeSegment(&theirs, flag_ack, 5001, iss +% 2, ""), 3 * sec);
    var sent: usize = 1;
    while (peer.more(3 * sec)) |frame| sent += tcpIn(frame).?.data.len;
    try testing.expectEqual(request.len, sent);
    try testing.expect(peer.tcp.persist_at == null);
}

test "P2: an older segment does not take the window back" {
    var peer = Peer{};
    var theirs: [2048]u8 = undefined;
    var request: [9000]u8 = @splat('x');
    const syn = tcpIn(peer.open(&request, 0)).?;
    _ = peer.answer(fakeSynAck(&theirs, 5000, syn.seq +% 1, 1460), 0).?;
    while (peer.more(0)) |_| {}
    const una = peer.tcp.seq;
    // Two acknowledgements of everything: the newer, from seq 5003, shuts
    // the window; the older, from 5001, reordered behind it, says 8192.
    var newer = fakeSegment(&theirs, flag_ack, 5003, una, "");
    theirs[34 + 14] = 0;
    theirs[34 + 15] = 0;
    _ = &newer;
    _ = peer.answer(theirs[0..newer.len], 0);
    try testing.expectEqual(@as(u32, 0), peer.tcp.snd_wnd);
    _ = peer.answer(fakeSegment(&theirs, flag_ack, 5001, una, ""), 0);
    try testing.expectEqual(@as(u32, 0), peer.tcp.snd_wnd);
}

test "P3: three duplicate acknowledgements resend the oldest at once" {
    var peer = Peer{ .rough = .{ .retransmits = true, .mss = 10 } };
    var theirs: [2048]u8 = undefined;
    const syn = tcpIn(peer.open("abcdefghijklmnopqrstuvwxyz0123456789", 0)).?;
    _ = peer.answer(fakeSegment(&theirs, flag_syn | flag_ack, 5000, syn.seq +% 1, ""), 0).?;
    while (peer.more(0)) |_| {}
    // Four segments; the first is lost, so each of the other three draws
    // the same acknowledgement, of 1001, which the SYN-ACK already gave.
    try testing.expect(peer.answer(fakeSegment(&theirs, flag_ack, 5001, 1001, ""), ms) == null);
    try testing.expect(peer.answer(fakeSegment(&theirs, flag_ack, 5001, 1001, ""), ms) == null);
    const fast = tcpIn(peer.answer(fakeSegment(&theirs, flag_ack, 5001, 1001, ""), ms).?).?;
    try testing.expectEqual(@as(u32, 1001), fast.seq);
    try testing.expectEqualStrings("abcdefghij", fast.data);
    // Without a lossy wire the peer has no timer, and does nothing of this.
    var plain = Peer{ .rough = .{ .mss = 10 } };
    const syn2 = tcpIn(plain.open("abcdefghijklmnopqrstuvwxyz0123456789", 0)).?;
    _ = plain.answer(fakeSegment(&theirs, flag_syn | flag_ack, 5000, syn2.seq +% 1, ""), 0).?;
    while (plain.more(0)) |_| {}
    for (0..3) |_| try testing.expect(plain.answer(fakeSegment(&theirs, flag_ack, 5001, 1001, ""), ms) == null);
}

test "P3: a backed-off timeout stays backed off until a round trip is measured" {
    var peer = Peer{ .rough = .{ .retransmits = true } };
    var theirs: [2048]u8 = undefined;
    const syn = tcpIn(peer.open("GET", 0)).?;
    // The SYN-ACK takes 100 ms: RTO 300 ms (100 + 4 x 50, over the floor).
    _ = peer.answer(fakeSegment(&theirs, flag_syn | flag_ack, 5000, syn.seq +% 1, ""), 100 * ms).?;
    try testing.expectEqual(@as(u64, 300 * ms), peer.tcp.rto_ns);
    _ = peer.more(100 * ms).?;
    // Lost: a timeout at 400 ms, the next at 600 ms past it.
    _ = peer.due(400 * ms).?;
    try testing.expectEqual(@as(?u64, 1000 * ms), peer.wakeAt());
    // Its acknowledgement measures nothing (it was sent twice): the timeout
    // stays 600 ms.
    _ = peer.answer(fakeSegment(&theirs, flag_ack, 5001, 1004, ""), 450 * ms);
    try testing.expectEqual(@as(u64, 600 * ms), peer.tcp.rto_ns);
}

test "P5: a reset must name RCV.NXT; one in the window is challenged, one outside is ignored" {
    var theirs: [2048]u8 = undefined;
    var peer = Peer{};
    try opened(&peer, .{}, "GET", 0);
    const nxt = peer.tcp.ack;
    // In the window but not exact: a challenge ACK, and it carries on.
    const challenge = tcpIn(peer.answer(fakeSegment(&theirs, flag_rst, nxt +% 100, 0, ""), 0).?).?;
    try testing.expectEqual(flag_ack, challenge.flags);
    try testing.expectEqual(nxt, challenge.ack);
    try testing.expectEqual(Tcp.State.established, peer.tcp.state);
    // Outside it: nothing at all.
    try testing.expect(peer.answer(fakeSegment(&theirs, flag_rst, nxt -% 1, 0, ""), 0) == null);
    try testing.expectEqual(Tcp.State.established, peer.tcp.state);
    // Exact: believed.
    try testing.expect(peer.answer(fakeSegment(&theirs, flag_rst, nxt, 0, ""), 0) == null);
    try testing.expectEqual(Tcp.State.refused, peer.tcp.state);
}

test "P7: a SYN-ACK acknowledging another SYN is answered with a reset" {
    var peer = Peer{};
    var theirs: [2048]u8 = undefined;
    const syn = tcpIn(peer.open("GET", 0)).?;
    const rst = tcpIn(peer.answer(fakeSegment(&theirs, flag_syn | flag_ack, 5000, syn.seq +% 7, ""), 0).?).?;
    try testing.expectEqual(flag_rst, rst.flags);
    try testing.expectEqual(syn.seq +% 7, rst.seq);
    try testing.expectEqual(Tcp.State.syn_sent, peer.tcp.state);
}

test "PEER_RETRY: a connection closed before any answer is followed by one asking the same" {
    var peer = Peer{};
    var theirs: [2048]u8 = undefined;
    const req = "POST /chat HTTP/1.1\r\n\r\nhello";
    try opened(&peer, .{ .retry = 2 }, req, 0);
    // The guest closes with no response at all.
    _ = peer.answer(fakeSegment(&theirs, flag_fin | flag_ack, 5001, peer.tcp.seq, ""), 10 * ms).?;
    try testing.expectEqual(@as(?u64, 11 * ms), peer.wakeAt());
    // A millisecond on, the same request on a new connection.
    const syn = tcpIn(peer.due(11 * ms).?).?;
    try testing.expectEqual(flag_syn, syn.flags);
    try testing.expectEqual(@as(u16, 49152 + peer_zig.max_clients), syn.src_port);
    _ = peer.answer(fakeTo(&theirs, syn.src_port, flag_syn | flag_ack, 9000, syn.seq +% 1, ""), 12 * ms).?;
    const asked = tcpIn(peer.more(12 * ms).?).?;
    try testing.expectEqualStrings(req, asked.data);
    try testing.expectEqual(@as(u32, 2), peer.sends());
    // Reset before an answer: once more, and then no more.
    _ = peer.answer(fakeTo(&theirs, syn.src_port, flag_rst, 9001, 0, ""), 20 * ms);
    try testing.expect(peer.due(21 * ms) != null);
    try testing.expectEqual(@as(u32, 3), peer.sends());
    _ = peer.answer(fakeTo(&theirs, 49152 + peer_zig.max_clients + 1, flag_rst | flag_ack, 0, peer.tcp.iss +% 1, ""), 22 * ms);
    try testing.expectEqual(Tcp.State.refused, peer.tcp.state);
    try testing.expect(peer.wakeAt() == null);
    // The first connection's port is closed now.
    try testing.expect(tcpIn(peer.answer(fakeSegment(&theirs, flag_ack, 5002, 1, ""), 30 * ms).?).?.flags & flag_rst != 0);
}

test "PEER_RETRY: an answer, even a short one, is not asked again" {
    var peer = Peer{};
    var theirs: [2048]u8 = undefined;
    try opened(&peer, .{ .retry = 1 }, "GET / HTTP/1.1\r\n\r\n", 0);
    _ = peer.answer(fakeSegment(&theirs, flag_fin | flag_ack | flag_psh, 5001, peer.tcp.seq, "HTTP/1.1 500"), 0).?;
    try testing.expect(peer.wakeAt() == null);
    try testing.expectEqual(@as(u32, 1), peer.sends());
}

test "PEER_DRIP_US: a slow client sends its request a segment a gap, never silent, never done till the end" {
    var peer = Peer{};
    var theirs: [2048]u8 = undefined;
    const syn = tcpIn(peer.open("GET /slow HTTP/1.1\r\n\r\n", 0)).?;
    peer.tcp.rough = .{ .mss = 4, .drip_ns = 3 * sec };
    _ = peer.answer(fakeSegment(&theirs, flag_syn | flag_ack, 5000, syn.seq +% 1, ""), 0).?;
    // One segment now, and no more until the gap is up.
    const first = tcpIn(peer.more(0).?).?;
    try testing.expectEqualStrings("GET ", first.data);
    try testing.expect(peer.more(0) == null);
    try testing.expectEqual(@as(?u64, 3 * sec), peer.wakeAt());
    try testing.expect(peer.due(3 * sec - 1) == null);
    var at: u64 = 3 * sec;
    var got: [64]u8 = undefined;
    var n: usize = 0;
    while (peer.wakeAt()) |w| : (at = w) {
        const seg = tcpIn(peer.due(w).?).?;
        @memcpy(got[n..][0..seg.data.len], seg.data);
        n += seg.data.len;
        try testing.expect(peer.due(w) == null); // one a gap
    }
    try testing.expectEqualStrings("/slow HTTP/1.1\r\n\r\n", got[0..n]);
    try testing.expectEqual(@as(u64, 5 * 3 * sec), at); // five more segments, three seconds apart
}

test "PEER_PIPELINE: both requests go before any answer, each in its own segments" {
    var peer = Peer{ .rough = .{ .pipeline = true } };
    var theirs: [2048]u8 = undefined;
    const req = "GET /a HTTP/1.1\r\n\r\n";
    try opened(&peer, .{ .pipeline = true }, req, 0);
    try testing.expectEqual(@as(u32, 2), peer.tcp.asks);
    // `opened` drained the first; the second went with it, unanswered.
    try testing.expectEqual(@as(u32, 1001 + 2 * req.len), peer.tcp.seq);
    try testing.expect(peer.more(0) == null);
    // The first answer, and a FIN: one answer whole, and a FIN back.
    const answer = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok";
    _ = peer.answer(fakeSegment(&theirs, flag_ack | flag_psh | flag_fin, 5001, peer.tcp.seq, answer), ms);
    try testing.expectEqual(@as(u32, 1), peer.tcp.answers);
}
