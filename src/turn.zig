//! **TWO MACHINES, ONE AT A TIME** (docs/TWO-KERNELS.md §4; QUEUE 225,
//! chunk 11): the pure part of a pair's turn-taking. Two metal-vmm
//! processes pass the turn back and forth, so exactly one guest runs, and
//! every decision here is a function of the two virtual clocks: how far the
//! holder may run (`limit`), what wakes a halted guest (`wake`), the frames
//! from the other machine kept in order until they are due (`Inbox`), the
//! handoffs that make no progress (`Livelock`), how a pair with nothing left
//! to do ends (`atNever`), what a pair refuses at its start (`checkStart`),
//! and the two messages, FRAME and TURN, as bytes. No sockets, no KVM, no
//! clock but the ones handed in: main.zig does those (chunk 12).

const std = @import("std");

/// **WHERE THE OTHER SIDE IS**, as its last TURN said.
pub const Status = union(enum) {
    /// Not yet powered on: the client before START.
    off,
    /// Its guest runs, and its clock is `clock`.
    running,
    /// Its guest is halted, and nothing of its own wakes it before `wake`
    /// (null: only a frame can).
    halted: ?i96,
    /// Its guest's run is over.
    stopped,
};

/// **HOW FAR THE HOLDER MAY RUN** (§4, "The turn rule"), or null for no
/// limit. `other_clock` is the other side's clock as its TURN said;
/// `first_sent_due` is the due of the first frame the holder has sent it
/// this turn; `lookahead` is L, `WIRE_LATENCY_US` in nanoseconds, which no
/// frame takes less than to arrive.
///
/// - running at c: c + L, since it may send a frame due no earlier;
/// - halted{wake}: min(wake, first_sent_due) + L, since a halted guest sends
///   nothing until it wakes, at its own `wake` or at a frame's arrival;
/// - off, or stopped: none, since it sends nothing at all.
pub fn limit(other: Status, other_clock: i96, first_sent_due: ?i96, lookahead: i96) ?i96 {
    return switch (other) {
        .off, .stopped => null,
        .running => other_clock + lookahead,
        .halted => |own_wake| blk: {
            const soonest = earliest(own_wake, first_sent_due) orelse break :blk null;
            break :blk soonest + lookahead;
        },
    };
}

/// **WHAT WAKES A HALTED GUEST** (§4, "The wake"): the earliest of the local
/// APIC's deadline, the card's next due (its peer's timers and its Wire),
/// and the inbox's next due, keeping only those after `clock`. A due at or
/// before `clock` is a frame already due and undelivered, which waits for
/// the guest, not the clock, so it wakes nothing: every wake is after the
/// clock, or null.
pub fn wake(clock: i96, lapic: ?i96, card: ?i96, inbox: ?i96) ?i96 {
    var soonest: ?i96 = null;
    for ([_]?i96{ lapic, card, inbox }) |due| {
        const at = due orelse continue;
        if (at <= clock) continue;
        soonest = earliest(soonest, at);
    }
    return soonest;
}

fn earliest(a: ?i96, b: ?i96) ?i96 {
    const x = a orelse return b;
    const y = b orelse return x;
    return @min(x, y);
}

// ── the frames from the other machine ──────────────────────────────────────

/// The most bytes a frame from the other machine carries: an ethernet frame.
pub const frame_max = 1514;

pub const Frame = struct {
    /// When it arrives: the sender's clock when it sent it, plus L.
    due: i96,
    /// Which side sent it.
    side: u8,
    /// Its place among that side's frames.
    seq: u64,
    len: u16,
    bytes: [frame_max]u8 = undefined,

    pub fn data(self: *const Frame) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// **THE FRAMES FROM THE OTHER MACHINE, IN ORDER OF (due, seq)** (§4, "The
/// inbox"), until `pump` moves the due ones onto the Wire. Arrival puts a
/// frame here and nowhere else: delivering it on arrival would hand the
/// guest a frame before its due, which the other side's clock had not yet
/// reached. A frame due before this side powered on is discarded and
/// counted (`before_power_on`): the server's ARP at boot, sent to a client
/// not yet there.
pub fn Inbox(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        frames: [capacity]Frame = undefined,
        n: usize = 0,
        /// When this side powered on (START's `d`); null until then, when
        /// nothing is discarded.
        power_on_at: ?i96 = null,
        before_power_on: u64 = 0,
        /// Frames that found the inbox full: refused, and the sender's
        /// run fails rather than losing a frame silently.
        full: u64 = 0,

        /// **A FRAME ARRIVED**: kept in its place, or discarded if it is due
        /// before this side was on. False when there is no room.
        pub fn put(self: *Self, f: Frame) bool {
            if (self.power_on_at) |d| if (f.due < d) {
                self.before_power_on += 1;
                return true;
            };
            if (self.n == capacity) {
                self.full += 1;
                return false;
            }
            var at = self.n;
            while (at > 0 and before(f, self.frames[at - 1])) : (at -= 1) self.frames[at] = self.frames[at - 1];
            self.frames[at] = f;
            self.n += 1;
            return true;
        }

        fn before(a: Frame, b: Frame) bool {
            return a.due < b.due or (a.due == b.due and a.seq < b.seq);
        }

        /// **THE NEXT FRAME DUE BY `now`**, taken out, oldest first; null
        /// when none is. The caller hands each to the Wire, and stops (the
        /// frame put back with `unpump`) when the Wire has no room.
        pub fn pump(self: *Self, now: i96) ?Frame {
            if (self.n == 0 or self.frames[0].due > now) return null;
            const f = self.frames[0];
            std.mem.copyForwards(Frame, self.frames[0 .. self.n - 1], self.frames[1..self.n]);
            self.n -= 1;
            return f;
        }

        /// Puts back the frame `pump` just gave, at the front: the Wire had
        /// no room, and it never pushes out an older frame.
        pub fn unpump(self: *Self, f: Frame) void {
            std.debug.assert(self.n < capacity);
            std.mem.copyBackwards(Frame, self.frames[1 .. self.n + 1], self.frames[0..self.n]);
            self.frames[0] = f;
            self.n += 1;
        }

        /// The earliest due after `clock`, for the wake.
        pub fn earliestAfter(self: *const Self, clock: i96) ?i96 {
            for (self.frames[0..self.n]) |f| if (f.due > clock) return f.due;
            return null;
        }
    };
}

// ── handoffs that go nowhere ──────────────────────────────────────────────

/// **`turn_livelock`** (§4): two handoffs in a row with neither clock
/// moving. Each process sees every handoff (its own and the other's TURN),
/// so each keeps this, and the first to see it names it.
pub const Livelock = struct {
    last: ?[2]i96 = null,
    still: u8 = 0,

    /// A handoff, at these two clocks: true when it is the second in a row
    /// at which neither moved.
    pub fn handoff(self: *Livelock, mine: i96, theirs: i96) bool {
        const now = [2]i96{ mine, theirs };
        if (self.last) |was| {
            if (was[0] == now[0] and was[1] == now[1]) self.still += 1 else self.still = 0;
        }
        self.last = now;
        return self.still >= 2;
    }
};

// ── the end ───────────────────────────────────────────────────────────────

/// **WHAT A HALT WITH NOTHING TO WAKE IT DOES IN A PAIR** (§4, "A clean
/// ending"): it never returns from `serve()` as a single machine's would,
/// since a frame from the other machine may yet wake it. It gives up the
/// turn as `halted{null}`, unless the other side is `halted{null}` or
/// `stopped` too: then nothing can ever happen again, and the pair ends,
/// named "both idle".
pub const AtNever = enum { give_up_turn, end_both_idle };

pub fn atNever(other: Status) AtNever {
    return switch (other) {
        .stopped => .end_both_idle,
        .halted => |w| if (w == null) .end_both_idle else .give_up_turn,
        .off, .running => .give_up_turn,
    };
}

/// **AN EOF IS EXPECTED** only after the other side said `stopped`, or once
/// the pair has ended; any other means the other process died, and the run
/// fails.
pub fn eofExpected(other: Status, ended: bool) bool {
    return ended or other == .stopped;
}

// ── what a pair refuses at its start ──────────────────────────────────────

/// **THE RECEIVER-SIDE FAULT KNOBS** (§4, "The inbox"): what the peer does to
/// its own frames before the guest sees them. A remote frame enters the Wire
/// past them, so in a pair they would fault only the local peer's frames, a
/// run that means less than it says: refused instead (fail, don't default).
/// Faults on what the guest sends (`WIRE_*`) are the sender's, and stay.
pub const receiver_side = [_][]const u8{
    "PEER_EAT",    "PEER_LOSS",        "PEER_DAMAGE",      "PEER_DAMAGE_RATE",
    "PEER_MANGLE", "PEER_MANGLE_RATE", "PEER_MANGLE_KIND",
};

pub const StartError = error{ NoLookahead, ReceiverSideFault };

/// **A PAIR STARTS ONLY WITH A LOOKAHEAD** (`WIRE_LATENCY_US` set and over
/// 0: L) and with no receiver-side fault knob among `set`, the names the
/// environment sets. Returns L in nanoseconds.
pub fn checkStart(latency_us: ?u64, set: []const []const u8) StartError!i96 {
    const us = latency_us orelse return error.NoLookahead;
    if (us == 0) return error.NoLookahead;
    for (set) |name| for (receiver_side) |r| if (std.mem.eql(u8, name, r)) return error.ReceiverSideFault;
    return @as(i96, us) * std.time.ns_per_us;
}

// ── the two messages ──────────────────────────────────────────────────────

/// **WHAT CROSSES THE SOCKET**, one message a datagram (SOCK_SEQPACKET):
/// a FRAME as the guest transmits it, and a TURN when the holder gives the
/// turn up. The first TURN to the client also carries START's `d`.
pub const Message = union(enum) {
    frame: Frame,
    turn: Turn,
};

pub const Turn = struct {
    clock: i96,
    status: Status,
    /// START (§4, "Power-on and START"): the client powers on at `d`.
    start: ?i96 = null,
};

const tag_frame: u8 = 'F';
const tag_turn: u8 = 'T';
const status_off: u8 = 0;
const status_running: u8 = 1;
const status_halted: u8 = 2;
const status_halted_never: u8 = 3;
const status_stopped: u8 = 4;

/// The most bytes a message takes.
pub const message_max = 1 + 16 + 1 + 8 + 2 + frame_max;

pub fn encode(m: Message, out: *[message_max]u8) []const u8 {
    switch (m) {
        .frame => |f| {
            out[0] = tag_frame;
            std.mem.writeInt(i128, out[1..17], f.due, .little);
            out[17] = f.side;
            std.mem.writeInt(u64, out[18..26], f.seq, .little);
            std.mem.writeInt(u16, out[26..28], f.len, .little);
            @memcpy(out[28..][0..f.len], f.data());
            return out[0 .. 28 + f.len];
        },
        .turn => |t| {
            out[0] = tag_turn;
            std.mem.writeInt(i128, out[1..17], t.clock, .little);
            var wake_at: i96 = 0;
            out[17] = switch (t.status) {
                .off => status_off,
                .running => status_running,
                .stopped => status_stopped,
                .halted => |w| if (w) |at| blk: {
                    wake_at = at;
                    break :blk status_halted;
                } else status_halted_never,
            };
            std.mem.writeInt(i128, out[18..34], wake_at, .little);
            out[34] = @intFromBool(t.start != null);
            std.mem.writeInt(i128, out[35..51], t.start orelse 0, .little);
            return out[0..51];
        },
    }
}

pub const DecodeError = error{ Short, UnknownTag, UnknownStatus, TooLong };

pub fn decode(bytes: []const u8) DecodeError!Message {
    if (bytes.len < 1) return error.Short;
    switch (bytes[0]) {
        tag_frame => {
            if (bytes.len < 28) return error.Short;
            const len = std.mem.readInt(u16, bytes[26..28], .little);
            if (len > frame_max) return error.TooLong;
            if (bytes.len != 28 + @as(usize, len)) return error.Short;
            var f: Frame = .{
                .due = @intCast(std.mem.readInt(i128, bytes[1..17], .little)),
                .side = bytes[17],
                .seq = std.mem.readInt(u64, bytes[18..26], .little),
                .len = len,
            };
            @memcpy(f.bytes[0..len], bytes[28..][0..len]);
            return .{ .frame = f };
        },
        tag_turn => {
            if (bytes.len != 51) return error.Short;
            const wake_at: i96 = @intCast(std.mem.readInt(i128, bytes[18..34], .little));
            const status: Status = switch (bytes[17]) {
                status_off => .off,
                status_running => .running,
                status_stopped => .stopped,
                status_halted => .{ .halted = wake_at },
                status_halted_never => .{ .halted = null },
                else => return error.UnknownStatus,
            };
            return .{ .turn = .{
                .clock = @intCast(std.mem.readInt(i128, bytes[1..17], .little)),
                .status = status,
                .start = if (bytes[34] != 0) @intCast(std.mem.readInt(i128, bytes[35..51], .little)) else null,
            } };
        },
        else => return error.UnknownTag,
    }
}

// ── tests, on scripted clocks ──────────────────────────────────────────────

const testing = std.testing;
const ms: i96 = std.time.ns_per_ms;
const L: i96 = 1 * ms;

test "the limit: c + L for a running side, min(wake, the first frame sent) + L for a halted one, none for one off or stopped" {
    try testing.expectEqual(@as(?i96, 10 * ms + L), limit(.running, 10 * ms, null, L));
    // Not c + 2L: a running side may send a frame due at c + L, which the
    // holder must not have run past.
    try testing.expect(limit(.running, 10 * ms, null, L).? < 10 * ms + 2 * L);
    try testing.expectEqual(@as(?i96, 50 * ms + L), limit(.{ .halted = 50 * ms }, 10 * ms, null, L));
    try testing.expectEqual(@as(?i96, 20 * ms + L), limit(.{ .halted = 50 * ms }, 10 * ms, 20 * ms, L));
    try testing.expectEqual(@as(?i96, 20 * ms + L), limit(.{ .halted = null }, 10 * ms, 20 * ms, L));
    try testing.expectEqual(@as(?i96, null), limit(.{ .halted = null }, 10 * ms, null, L));
    try testing.expectEqual(@as(?i96, null), limit(.off, 0, 20 * ms, L));
    try testing.expectEqual(@as(?i96, null), limit(.stopped, 99 * ms, 20 * ms, L));
}

test "the wake: the earliest due after the clock; one already due wakes nothing" {
    try testing.expectEqual(@as(?i96, 5 * ms), wake(1 * ms, 9 * ms, 5 * ms, 7 * ms));
    try testing.expectEqual(@as(?i96, 9 * ms), wake(5 * ms, 9 * ms, 5 * ms, 2 * ms));
    try testing.expectEqual(@as(?i96, null), wake(10 * ms, 9 * ms, null, 10 * ms));
    try testing.expectEqual(@as(?i96, null), wake(0, null, null, null));
}

fn frameAt(due: i96, seq: u64, byte: u8) Frame {
    var f: Frame = .{ .due = due, .side = 1, .seq = seq, .len = 1 };
    f.bytes[0] = byte;
    return f;
}

test "the inbox keeps (due, seq) order, gives frames only once due, and puts back what the Wire had no room for" {
    var in: Inbox(8) = .{};
    try testing.expect(in.put(frameAt(30 * ms, 3, 'c')));
    try testing.expect(in.put(frameAt(10 * ms, 1, 'a')));
    try testing.expect(in.put(frameAt(30 * ms, 2, 'b')));
    try testing.expect(in.put(frameAt(40 * ms, 4, 'd')));
    // Nothing is due on arrival: arrival is not delivery.
    try testing.expectEqual(@as(?Frame, null), in.pump(9 * ms));
    try testing.expectEqual(@as(?i96, 10 * ms), in.earliestAfter(0));
    try testing.expectEqual(@as(u8, 'a'), in.pump(30 * ms).?.bytes[0]);
    const b = in.pump(30 * ms).?;
    try testing.expectEqual(@as(u8, 'b'), b.bytes[0]);
    in.unpump(b); // the Wire was full
    try testing.expectEqual(@as(u8, 'b'), in.pump(30 * ms).?.bytes[0]);
    try testing.expectEqual(@as(u8, 'c'), in.pump(30 * ms).?.bytes[0]);
    try testing.expectEqual(@as(?Frame, null), in.pump(30 * ms));
    try testing.expectEqual(@as(?i96, 40 * ms), in.earliestAfter(30 * ms));
}

test "a frame due before this side powered on is discarded and counted; a full inbox refuses, counted" {
    var in: Inbox(2) = .{};
    in.power_on_at = 20 * ms;
    try testing.expect(in.put(frameAt(5 * ms, 1, 'x'))); // the server's ARP at boot
    try testing.expectEqual(@as(u64, 1), in.before_power_on);
    try testing.expectEqual(@as(usize, 0), in.n);
    try testing.expect(in.put(frameAt(21 * ms, 2, 'y')));
    try testing.expect(in.put(frameAt(22 * ms, 3, 'z')));
    try testing.expect(!in.put(frameAt(23 * ms, 4, 'w')));
    try testing.expectEqual(@as(u64, 1), in.full);
}

test "a wake that keeps an already-passed due trips turn_livelock within two handoffs" {
    // The plant, as a script: the holder halts with a wake that is a due
    // already passed, so its clock never moves; the other side, halted and
    // waiting on it, hands straight back. Neither clock moves.
    var a: Livelock = .{};
    var clock_a: i96 = 7 * ms;
    const clock_b: i96 = 9 * ms;
    const passed_due: i96 = 5 * ms; // what a wake that kept old dues would say
    var tripped_at: ?usize = null;
    for (0..4) |k| {
        clock_a = @max(clock_a, passed_due); // rest() moves to the wake: no move
        if (a.handoff(clock_a, clock_b)) {
            tripped_at = k;
            break;
        }
    }
    try testing.expect(tripped_at != null and tripped_at.? <= 2);
    // And the honest wake never reports that due: it keeps only dues after
    // the clock.
    try testing.expectEqual(@as(?i96, null), wake(clock_a, passed_due, null, null));
    // Clocks that move never trip it.
    var b: Livelock = .{};
    for (0..10) |k| try testing.expect(!b.handoff(@intCast(k), 3));
}

test "both idle: a halt with nothing to wake it ends the pair when the other is halted for good or stopped, and never returns from serve()" {
    try testing.expectEqual(AtNever.end_both_idle, atNever(.stopped));
    try testing.expectEqual(AtNever.end_both_idle, atNever(.{ .halted = null }));
    try testing.expectEqual(AtNever.give_up_turn, atNever(.{ .halted = 3 * ms }));
    try testing.expectEqual(AtNever.give_up_turn, atNever(.running));
    try testing.expectEqual(AtNever.give_up_turn, atNever(.off));
    // There is no third answer: the enum has no "return".
    try testing.expectEqual(@as(usize, 2), @typeInfo(AtNever).@"enum".fields.len);
    try testing.expect(eofExpected(.stopped, false));
    try testing.expect(eofExpected(.running, true));
    try testing.expect(!eofExpected(.{ .halted = null }, false));
}

test "a pair refuses to start without a lookahead, or with a receiver-side fault knob" {
    try testing.expectError(error.NoLookahead, checkStart(null, &.{}));
    try testing.expectError(error.NoLookahead, checkStart(0, &.{}));
    try testing.expectEqual(@as(i96, 1 * ms), try checkStart(1000, &.{ "WIRE_EAT", "PEER_SHUT_AFTER" }));
    try testing.expectError(error.ReceiverSideFault, checkStart(1000, &.{"PEER_LOSS"}));
    try testing.expectError(error.ReceiverSideFault, checkStart(1000, &.{ "WIRE_LOSS", "PEER_MANGLE" }));
}

test "the messages round-trip, and a short or unknown one is refused" {
    var buf: [message_max]u8 = undefined;
    var f = frameAt(123 * ms, 77, 'q');
    f.len = 3;
    @memcpy(f.bytes[0..3], "abc");
    const back = try decode(encode(.{ .frame = f }, &buf));
    try testing.expectEqual(f.due, back.frame.due);
    try testing.expectEqual(f.seq, back.frame.seq);
    try testing.expectEqualStrings("abc", back.frame.data());
    for ([_]Turn{
        .{ .clock = 5 * ms, .status = .running },
        .{ .clock = 6 * ms, .status = .{ .halted = 9 * ms } },
        .{ .clock = 7 * ms, .status = .{ .halted = null } },
        .{ .clock = 8 * ms, .status = .stopped, .start = 2 * ms },
        .{ .clock = 0, .status = .off },
    }) |t| {
        const got = (try decode(encode(.{ .turn = t }, &buf))).turn;
        try testing.expectEqual(t.clock, got.clock);
        try testing.expectEqual(t.start, got.start);
        try testing.expect(std.meta.eql(t.status, got.status));
    }
    try testing.expectError(error.Short, decode(""));
    try testing.expectError(error.UnknownTag, decode("X"));
    try testing.expectError(error.Short, decode(encode(.{ .frame = f }, &buf)[0..20]));
}
