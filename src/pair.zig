//! **TWO MACHINES, ONE AT A TIME: THE HOST'S HALF** (docs/TWO-KERNELS.md §4;
//! QUEUE 225, chunk 12b). `PAIR=<client kernel>` makes this program fork and
//! exec itself, the two joined by a `SOCK_SEQPACKET` socketpair: the parent
//! is side 0, the server; the child side 1, the client. `Link` is one side's
//! end of the socket, behind turn.zig's `Hooks` (for main.zig) and `Pair`
//! (for net.zig). Every decision it makes is turn.zig's; this file only
//! moves the messages.
//!
//! **THE CLIENT'S OWN SETTINGS** are the parent's `PAIR_CLIENT_<NAME>`, as
//! `<NAME>`: each process keeps its own environment, so a knob applies to
//! its guest and to no other. `WIRE_LATENCY_US` (L, which both must agree
//! on), `WIRE_TRACE` (the pair's one trace) and `PAIR` go to both; nothing
//! else crosses. The client's PVH
//! command line is `PAIR_CMDLINE`.

const std = @import("std");
const linux = std.os.linux;
const turn = @import("turn.zig");

pub const client_prefix = "PAIR_CLIENT_";
/// The settings both sides take as the server has them.
const shared = [_][]const u8{ "WIRE_LATENCY_US=", "WIRE_TRACE=", "PAIR=" };

pub const Error = error{
    /// The other process ended with no `stopped`: it died.
    OtherDied,
    /// Two handoffs in a row with neither clock moving (`turn_livelock`).
    TurnLivelock,
    /// A frame from the other machine found the inbox full.
    InboxFull,
    /// The socket would not take or give a message.
    PairSocket,
    /// A message that is not one, or a first TURN with no START.
    BadMessage,
    /// The server's run ended before its guest listened.
    NeverStarted,
};

/// **ONE SIDE'S END OF THE SOCKET.** Placed where it stays, then `bind`.
pub const Link = struct {
    fd: linux.fd_t,
    lookahead: u64,
    pair: turn.Pair,
    /// The other side, as its last TURN said (the server's view of the
    /// client is `off` until its guest listens).
    other: turn.Status,
    other_clock: i96 = 0,
    /// START's `d`: the server's, sent with its first TURN after it is set;
    /// the client's, as it arrived.
    start_at: ?i96 = null,
    start_sent: bool = false,
    livelock: turn.Livelock = .{},
    /// The other side said `stopped`, and this side has too: nothing more.
    ended: bool = false,
    /// The socket failed or the other side died: nothing more is sent.
    broken: bool = false,
    /// What happened, for the pair's line.
    turns: u64 = 0,
    frames_sent: u64 = 0,
    frames_received: u64 = 0,
    sent_while_off: u64 = 0,

    pub fn init(fd: linux.fd_t, side: u8, lookahead_ns: u64, other: turn.Status) Link {
        return .{
            .fd = fd,
            .lookahead = lookahead_ns,
            .pair = .{ .side = side, .lookahead_ns = lookahead_ns, .sendFn = sendFrame, .ctx = undefined },
            .other = other,
        };
    }

    /// Points the Pair at this Link, where it now stays.
    pub fn bind(self: *Link) void {
        self.pair.ctx = self;
    }

    /// **`WIRE_TRACE=1`**: the pair's lines on stderr, each written while
    /// this side holds the turn, so the two sides' lines interleave in
    /// turn order and need no sorting.
    pub fn traceOn(self: *Link) void {
        self.pair.traceFn = writeTrace;
    }

    fn writeTrace(_: *anyopaque, text: []const u8) void {
        std.debug.print("{s}", .{text});
    }

    pub fn hooks(self: *Link) turn.Hooks {
        return .{
            .ctx = self,
            .limitFn = limitOf,
            .otherFn = otherOf,
            .yieldFn = yieldTurn,
            .listeningFn = if (self.pair.side == 0) listened else null,
        };
    }

    fn of(ctx: *anyopaque) *Link {
        return @ptrCast(@alignCast(ctx));
    }

    fn limitOf(ctx: *anyopaque) ?u64 {
        const self = of(ctx);
        const at = turn.limit(self.other, self.other_clock, self.pair.first_sent_due, self.lookahead) orelse return null;
        return @intCast(@max(at, 0));
    }

    fn otherOf(ctx: *anyopaque) turn.Status {
        return of(ctx).other;
    }

    /// **THE SERVER'S GUEST LISTENS** at `clock`: the client powers on at
    /// d = clock + L and is running there from now (§4, "Power-on and START").
    fn listened(ctx: *anyopaque, clock: u64) void {
        const self = of(ctx);
        if (self.start_at != null) return;
        const d = @as(i96, clock) + self.lookahead;
        self.start_at = d;
        self.other = .running;
        self.other_clock = d;
    }

    /// **A FRAME ACROSS**, written as the guest sends it. One sent while the
    /// client is not yet on is due before its power-on, so it is discarded
    /// here and counted, as the client would on arrival.
    fn sendFrame(ctx: *anyopaque, f: *const turn.Frame) void {
        const self = of(ctx);
        if (self.other == .off) {
            self.sent_while_off += 1;
            return;
        }
        if (self.broken) return;
        var buf: [turn.message_max]u8 = undefined;
        self.write(turn.encode(.{ .frame = f.* }, &buf)) catch return;
        self.frames_sent += 1;
    }

    fn write(self: *Link, bytes: []const u8) Error!void {
        const rc = linux.write(self.fd, bytes.ptr, bytes.len);
        if (linux.errno(rc) != .SUCCESS or rc != bytes.len) {
            self.broken = true;
            return error.PairSocket;
        }
    }

    /// **GIVING UP THE TURN** (§4): send TURN{clock, status}, then block
    /// until the next TURN, keeping each FRAME before it in the inbox.
    fn yieldTurn(ctx: *anyopaque, clock: u64, status: turn.Status) anyerror!void {
        const self = of(ctx);
        try self.giveUp(clock, status);
        try self.await(clock);
    }

    fn giveUp(self: *Link, clock: u64, status: turn.Status) Error!void {
        if (self.broken) return error.PairSocket;
        const start = if (self.start_sent) null else self.start_at;
        var buf: [turn.message_max]u8 = undefined;
        try self.write(turn.encode(.{ .turn = .{ .clock = clock, .status = status, .start = start } }, &buf));
        if (start != null) self.start_sent = true;
        self.pair.first_sent_due = null;
        self.turns += 1;
        if (self.livelock.handoff(clock, self.other_clock)) return error.TurnLivelock;
    }

    fn await(self: *Link, clock: u64) Error!void {
        var buf: [turn.message_max]u8 = undefined;
        while (true) {
            const m = try self.read(&buf);
            switch (m) {
                .frame => |f| {
                    self.frames_received += 1;
                    if (!self.pair.inbox.put(f)) return error.InboxFull;
                },
                .turn => |t| {
                    self.other = t.status;
                    self.other_clock = t.clock;
                    if (t.start) |d| {
                        self.start_at = d;
                        self.pair.inbox.powerOn(d);
                    }
                    if (self.livelock.handoff(clock, t.clock)) return error.TurnLivelock;
                    return;
                },
            }
        }
    }

    /// The next message; an EOF the other side did not announce is its death.
    fn read(self: *Link, buf: *[turn.message_max]u8) Error!turn.Message {
        const rc = linux.read(self.fd, buf, buf.len);
        if (linux.errno(rc) != .SUCCESS) {
            self.broken = true;
            return error.PairSocket;
        }
        if (rc == 0) {
            self.broken = true;
            return error.OtherDied;
        }
        return turn.decode(buf[0..rc]) catch {
            self.broken = true;
            return error.BadMessage;
        };
    }

    /// **THE CLIENT, BEFORE ITS GUEST RUNS**: blocked until the server's
    /// first TURN, which says when it powers on.
    pub fn awaitStart(self: *Link) Error!i96 {
        try self.await(0);
        if (self.start_at) |d| return d;
        if (self.other == .stopped) return error.NeverStarted;
        return error.BadMessage;
    }

    /// **THIS SIDE'S RUN IS OVER** (§4, "A clean ending"): say `stopped`,
    /// then read on, discarding frames, until the other side says it too.
    pub fn finish(self: *Link, clock: u64) Error!void {
        defer _ = linux.close(self.fd);
        if (self.broken) return;
        var buf: [turn.message_max]u8 = undefined;
        try self.write(turn.encode(.{ .turn = .{ .clock = clock, .status = .stopped } }, &buf));
        while (self.other != .stopped) {
            const m = self.read(&buf) catch |e| {
                if (turn.eofExpected(self.other, false)) return;
                return e;
            };
            switch (m) {
                .frame => {},
                .turn => |t| {
                    self.other = t.status;
                    self.other_clock = t.clock;
                },
            }
        }
        self.ended = true;
    }

    /// One line on what crossed, said at the run's end (a pair's only).
    pub fn line(self: *const Link, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "metal-vmm: pair side {d}: {d} turns given up, {d} frames sent across, {d} received, {d} sent before the client was on, {d} discarded before power-on, {d} broadcasts dropped\n", .{
            self.pair.side,
            self.turns,
            self.frames_sent,
            self.frames_received,
            self.sent_while_off,
            self.pair.inbox.before_power_on,
            self.pair.dropped_broadcasts,
        }) catch buf[0..0];
    }
};

/// **THE PARENT'S VERDICT** (§4, "The processes"): its own, unless that is
/// clean, and then the client's.
pub fn combined(server: u8, client: u8) u8 {
    return if (server != 0) server else client;
}

/// **THE CLIENT'S ENVIRONMENT**, as `NAME=value` lines: each
/// `PAIR_CLIENT_<NAME>=v` as `<NAME>=v`, `shared` as they are, then `SIDE=1` and `PAIR_FD=<fd>`. Into `out`, its lines into
/// `lines`; the count of lines, or null when either is too small.
pub fn childEnvironment(entries: []const [*:0]const u8, fd: linux.fd_t, out: []u8, lines: [][*:0]const u8) ?usize {
    var used: usize = 0;
    var n: usize = 0;
    var tail_buf: [32]u8 = undefined;
    const fd_line = std.fmt.bufPrint(&tail_buf, "PAIR_FD={d}", .{fd}) catch return null;
    const tail = [_][]const u8{ "SIDE=1", fd_line };
    var each: usize = 0;
    while (each < entries.len + tail.len) : (each += 1) {
        const text: []const u8 = if (each < entries.len) blk: {
            const entry = std.mem.span(entries[each]);
            if (std.mem.startsWith(u8, entry, client_prefix)) break :blk entry[client_prefix.len..];
            for (shared) |name| if (std.mem.startsWith(u8, entry, name)) break :blk entry;
            continue;
        } else tail[each - entries.len];
        if (n == lines.len or used + text.len + 1 > out.len) return null;
        @memcpy(out[used..][0..text.len], text);
        out[used + text.len] = 0;
        lines[n] = out[used .. used + text.len :0];
        used += text.len + 1;
        n += 1;
    }
    return n;
}

/// The names `lines` sets, for `turn.checkStart`; null when `out` cannot
/// hold them all, since a name left out is a knob not checked.
pub fn names(lines: []const [*:0]const u8, out: [][]const u8) ?[]const []const u8 {
    var n: usize = 0;
    for (lines) |entry| {
        if (n == out.len) return null;
        const text = std.mem.span(entry);
        out[n] = text[0 .. std.mem.indexOfScalar(u8, text, '=') orelse text.len];
        n += 1;
    }
    return out[0..n];
}

pub const Spawned = struct { fd: linux.fd_t, pid: linux.pid_t };

/// **THE CLIENT, STARTED**: this program again, as side 1, with `kernel`,
/// no disk, `command_line`, and `env` (`childEnvironment`, which names the
/// socket's other end as `child_fd`: the socketpair is made first, by
/// `socketPair`).
pub fn spawn(fds: [2]linux.fd_t, kernel: [*:0]const u8, command_line: [*:0]const u8, env: []const [*:0]const u8) Error!Spawned {
    var envp: [256:null]?[*:0]const u8 = @splat(null);
    if (env.len > envp.len) return error.PairSocket;
    for (env, 0..) |e, i| envp[i] = e;
    const argv = [_:null]?[*:0]const u8{ "metal-vmm", kernel, "", command_line };
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) return error.PairSocket;
    if (rc == 0) {
        _ = linux.close(fds[0]);
        _ = linux.execve("/proc/self/exe", &argv, &envp);
        std.debug.print("metal-vmm: the pair's client would not start\n", .{});
        linux.exit_group(2);
    }
    _ = linux.close(fds[1]);
    return .{ .fd = fds[0], .pid = @intCast(rc) };
}

/// The socketpair, both ends kept across `exec` (the client's must be).
pub fn socketPair() Error![2]linux.fd_t {
    var fds: [2]linux.fd_t = undefined;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.SEQPACKET, 0, &fds)) != .SUCCESS) return error.PairSocket;
    return fds;
}

/// **THE CLIENT'S VERDICT**: its exit code, or 128 and its signal.
pub fn reap(pid: linux.pid_t) u8 {
    var status: u32 = 0;
    while (true) {
        const rc = linux.waitpid(pid, &status, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => break,
            .INTR => continue,
            else => return 1,
        }
    }
    if (linux.W.IFEXITED(status)) return linux.W.EXITSTATUS(status);
    return 128 +| @as(u8, @truncate(@intFromEnum(linux.W.TERMSIG(status))));
}

// ── what can be checked without a guest: two Links over a real socket ─────

const testing = std.testing;

test "the client's environment: its own settings unprefixed, L and PAIR shared, the rest the server's alone" {
    const entries = [_][*:0]const u8{ "PAIR=fetch.elf", "WIRE_LATENCY_US=1000", "WIRE_TRACE=1", "WIRE_EAT=3", "PAIR_CLIENT_WIRE_EAT=5", "VOLUME=/tmp/v.img", "PAIR_CLIENT_TRANSPORT=pci" };
    var out: [256]u8 = undefined;
    var lines: [16][*:0]const u8 = undefined;
    const n = childEnvironment(&entries, 7, &out, &lines).?;
    const want = [_][]const u8{ "PAIR=fetch.elf", "WIRE_LATENCY_US=1000", "WIRE_TRACE=1", "WIRE_EAT=5", "TRANSPORT=pci", "SIDE=1", "PAIR_FD=7" };
    try testing.expectEqual(want.len, n);
    for (want, lines[0..n]) |w, got| try testing.expectEqualStrings(w, std.mem.span(got));
    var name_buf: [16][]const u8 = undefined;
    const set = names(lines[0..n], &name_buf).?;
    try testing.expectEqualStrings("WIRE_EAT", set[3]);
    try testing.expectEqual(@as(?[]const []const u8, null), names(lines[0..n], name_buf[0..2]));
    try testing.expectEqual(@as(?usize, null), childEnvironment(&entries, 7, out[0..20], &lines));
}

test "the parent's verdict: its own when it failed, the client's when it did not" {
    try testing.expectEqual(@as(u8, 3), combined(0, 3));
    try testing.expectEqual(@as(u8, 1), combined(1, 3));
    try testing.expectEqual(@as(u8, 0), combined(0, 0));
}

test "over a real socket: the server's first TURN starts the client at d, frames sent before the client was on are not sent, and each side's stopped ends the pair" {
    const fds = try socketPair();
    var server = Link.init(fds[0], 0, 1000, .off);
    server.bind();
    var client = Link.init(fds[1], 1, 1000, .running);
    client.bind();
    const hs = server.hooks();
    try testing.expectEqual(@as(?u64, null), hs.limit()); // the client is not on
    var f: turn.Frame = .{ .due = 0, .side = 0, .seq = 0, .len = 4 };
    @memcpy(f.bytes[0..4], "arp!");
    server.pair.sendFn(server.pair.ctx, &f);
    try testing.expectEqual(@as(u64, 1), server.sent_while_off);
    hs.listening(5000);
    try testing.expectEqual(@as(?u64, 7000), hs.limit()); // d + L
    f.due = 7000;
    server.pair.sendFn(server.pair.ctx, &f); // sent: the client reads it before the TURN
    try server.giveUp(7000, .running);
    try testing.expectEqual(@as(i96, 6000), try client.awaitStart());
    try testing.expectEqual(@as(usize, 1), client.pair.inbox.n);
    try testing.expectEqual(@as(?u64, 8000), client.hooks().limit());
    // The client stops; the server, reading for its turn, sees it; both end.
    try client.giveUp(6000, .stopped);
    try server.await(7000);
    try testing.expect(server.other == .stopped);
    try testing.expectEqual(@as(?u64, null), hs.limit());
    try server.finish(9000);
    try testing.expect(server.ended);
}

test "an EOF the other side never announced is its death, named" {
    const fds = try socketPair();
    var server = Link.init(fds[0], 0, 1000, .running);
    server.bind();
    _ = linux.close(fds[1]);
    try testing.expectError(error.OtherDied, server.await(0));
    _ = linux.close(fds[0]);
}

test "two handoffs at the same two clocks are a livelock, named" {
    const fds = try socketPair();
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);
    var a = Link.init(fds[0], 0, 1000, .running);
    a.bind();
    var b = Link.init(fds[1], 1, 1000, .running);
    b.bind();
    var failed = false;
    for (0..3) |_| {
        a.giveUp(100, .running) catch {
            failed = true;
            break;
        };
        b.await(200) catch {};
        b.giveUp(200, .running) catch {};
        a.await(100) catch {
            failed = true;
            break;
        };
    }
    try testing.expect(failed);
}

/// **A GUEST WITHOUT A GUEST**, for the test below: a clock that ticks
/// `step` at a time through `beforeMove`, as `serve()` does, sending a frame
/// across every `every` and delivering what is due, until `end`.
const Scripted = struct {
    link: *Link,
    step: u64,
    every: u64,
    end: u64,
    listen_at: ?u64 = null,
    start: u64 = 0,
    late: u64 = 0,
    delivered: u64 = 0,
    sent: u64 = 0,
    log: [4096]u64 = undefined,
    logged: usize = 0,
    failed: ?anyerror = null,

    fn run(self: *Scripted) void {
        self.go() catch |e| {
            self.failed = e;
        };
    }

    fn go(self: *Scripted) !void {
        const hooks = self.link.hooks();
        var clock: u64 = self.start;
        var next_send: u64 = clock + self.every;
        while (clock < self.end) {
            const before = self.link.turns;
            try hooks.beforeMove(clock, self.step);
            if (self.link.turns != before) {
                // The turn came back: nothing that arrived may be due before
                // this clock, or the other side ran past this one's limit.
                for (self.link.pair.inbox.frames[0..self.link.pair.inbox.n]) |f| {
                    if (f.due < clock) self.late += 1;
                }
                if (self.logged < self.log.len) {
                    self.log[self.logged] = clock;
                    self.logged += 1;
                }
            }
            clock += self.step;
            while (self.link.pair.inbox.pump(clock)) |_| self.delivered += 1;
            if (self.listen_at) |at| if (clock >= at) {
                hooks.listening(clock);
                self.listen_at = null;
            };
            if (clock >= next_send) {
                self.link.pair.send("frame", clock);
                next_send += self.every;
            }
        }
        self.sent = self.link.frames_sent;
        try self.link.finish(clock);
    }
};

fn pairRun(server: *Scripted, client: *Scripted) !void {
    const fds = try socketPair();
    var s = Link.init(fds[0], 0, 1000_000, .off);
    s.bind();
    var c = Link.init(fds[1], 1, 1000_000, .running);
    c.bind();
    server.link = &s;
    client.link = &c;
    const thread = try std.Thread.spawn(.{}, struct {
        fn f(sc: *Scripted) void {
            const d = sc.link.awaitStart() catch |e| {
                sc.failed = e;
                return;
            };
            sc.start = @intCast(d);
            sc.run();
        }
    }.f, .{client});
    server.run();
    thread.join();
    try testing.expectEqual(@as(?anyerror, null), server.failed);
    try testing.expectEqual(@as(?anyerror, null), client.failed);
}

test "two scripted guests take turns over a real socket: no frame arrives late, every one sent is delivered, and the handoffs are the same run to run" {
    var logs: [2][2][]const u64 = undefined;
    var keep: [2][2]Scripted = undefined;
    for (0..2) |run| {
        keep[run][0] = .{ .link = undefined, .step = 100_000, .every = 300_000, .end = 20_000_000, .listen_at = 1_000_000 };
        keep[run][1] = .{ .link = undefined, .step = 100_000, .every = 500_000, .end = 15_000_000 };
        try pairRun(&keep[run][0], &keep[run][1]);
        for (0..2) |k| {
            try testing.expectEqual(@as(u64, 0), keep[run][k].late);
            // A turn runs about 2L past the other side's clock: some 14 ms
            // of the two together, in turns of about 2 ms.
            try testing.expect(keep[run][k].logged >= 6);
            logs[run][k] = keep[run][k].log[0..keep[run][k].logged];
        }
        // The client powered on at d: the listening clock plus L.
        try testing.expectEqual(@as(u64, 1_000_000 + 1_000_000), keep[run][1].start);
        // Every frame the client sent reached the server's guest, which ran
        // on past the client's end.
        try testing.expect(keep[run][1].sent > 20);
        try testing.expectEqual(keep[run][1].sent, keep[run][0].delivered);
    }
    for (0..2) |k| try testing.expectEqualSlices(u64, logs[0][k], logs[1][k]);
}
