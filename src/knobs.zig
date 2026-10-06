//! **ONE SEED NAMES A RUN'S WHOLE FAULT SCHEDULE.**
//!
//! Every way this machine can be unhelpful is a knob in the environment:
//! which of the guest's frames the wire eats, which of the peer's, how late
//! frames arrive, which disk requests are refused, and how the peer
//! misbehaves (faults.zig, peer.zig). `FAULT_SEED=n` turns them all at
//! once, by drawing each from the ranges below, so "seed 4711" names one
//! exact run, to a person and to an explorer alike.
//!
//! - **An explicit knob wins over the seed**: the seed fills in what the
//!   environment leaves unset, and nothing else.
//! - **The chosen schedule is printed as the knobs that reproduce it**, so
//!   a run is repeatable without the seed, and a person can see what it was.
//! - **The seed only chooses the knobs.** The dice behind a rate (faults.zig,
//!   `Schedule`) are seeded as they always were, so a knob set by hand and
//!   the same knob drawn by a seed are the same run.
//!
//! Each family of faults is in a seeded run by its own chance, so most
//! seeds turn a few knobs and not all of them:
//!
//! | knob | chance | drawn from |
//! |---|---|---|
//! | `WIRE_EAT` | 1/2 | 1-3 of the guest's frames 1-40 |
//! | `WIRE_LOSS` | 1/4 | one in 5-50 |
//! | `WIRE_LATENCY_US` | 1/2 | 100-20,000 |
//! | `PEER_EAT` | 1/3 | 1-2 of the peer's frames 1-40 |
//! | `PEER_LOSS` | 1/6 | one in 5-50 |
//! | `PEER_DAMAGE` | 1/4 | one of the peer's frames 1-40 |
//! | `DISK_REFUSE` | 1/4 | one request 1-100, writes only half the time |
//! | `DISK_CUT_AFTER` | 1/6 | the power cut after write 1-100 |
//! | `DISK_TEAR` | else 1/8 | multi-sector write 1-20 torn, `DISK_TEAR_KEEP` 1-7 sectors landing |
//! | `PEER_RESET_AT` | 1/4 | 1,000-2,000,000 us; `PEER_RESET_OFF` 1-2000 half the time |
//! | `PEER_VANISH_AFTER` | 1/4 | 1-60,000 bytes |
//! | `PEER_FLOOD` | 1/4 | 1-8 SYNs, `PEER_FLOOD_GAP_US` 10,000-400,000 |
//! | `PEER_SHUT_AFTER` | 1/4 | 1-20,000 bytes, `PEER_SHUT_FOR_US` 10,000-5,000,000 |
//! | `PEER_MSS` | 1/4 | 1-1460 |
//! | `DISK_ROT` | 1/8 | sector 0-4095, byte 0-511 (drawn last) |
//!
//! `PEER_FLOOD_AT_US`, `PEER_DAMAGE_RATE` and `DISK_REFUSE_RATE` are
//! never drawn: a seed's flood starts with the client, and a seed's peer
//! damage and disk refusals are named, not rated. Nor are `DISK_BAD_SECTOR`
//! and `DISK_READS_ONLY`: a sector is worth naming only on a volume whose
//! layout a person has read, and drawing them would change what every
//! existing seed does. `PEER_IGNORE_WINDOW` neither, for the same second
//! reason, nor `DISK_CACHE`, which changes the device the guest negotiates
//! with, nor `PEER_RETRY`, a client's habit rather than a fault, nor
//! `RTC_BOOTS_AT`, a date a person picks for what it means, nor
//! `PEER_DRIP_US`, a slow client, which a sweep would wait out, nor
//! `PEER_PIPELINE`, a client's habit. Set by hand, they print with the rest.
//!
//! The peer's ranges are gopher-metal's `tcp_sim.zig` `Rough`'s and
//! `Scenario`'s, where they have one.

const std = @import("std");

/// Every fault knob, in the order a schedule is printed.
pub const names = [_][]const u8{
    "WIRE_EAT",           "WIRE_LOSS",         "WIRE_LATENCY_US",  "PEER_EAT",
    "PEER_LOSS",          "PEER_DAMAGE",       "PEER_DAMAGE_RATE", "DISK_REFUSE",
    "DISK_REFUSE_RATE",   "DISK_WRITES_ONLY",  "DISK_READS_ONLY",  "DISK_BAD_SECTOR",
    "DISK_CUT_AFTER",     "DISK_TEAR",         "DISK_TEAR_KEEP",   "PEER_RESET_AT",
    "PEER_RESET_OFF",     "PEER_VANISH_AFTER", "PEER_FLOOD",       "PEER_FLOOD_GAP_US",
    "PEER_FLOOD_AT_US",   "PEER_SHUT_AFTER",   "PEER_SHUT_FOR_US", "PEER_MSS",
    "PEER_IGNORE_WINDOW", "DISK_ROT",          "DISK_CACHE",       "PEER_RETRY",
    "RTC_BOOTS_AT",       "PEER_DRIP_US",      "PEER_PIPELINE",
};

fn index(comptime name: []const u8) usize {
    inline for (names, 0..) |n, i| if (comptime std.mem.eql(u8, n, name)) return i;
    @compileError("no knob " ++ name);
}

/// Where a value the seed chose sits in `Knobs.text`.
const Span = struct { at: u16, len: u16 };

pub const Knobs = struct {
    /// What the seed chose, as the text a person would have typed.
    drawn: [names.len]?Span = @splat(null),
    text: [512]u8 = undefined,
    used: usize = 0,
    /// What the environment set, which wins.
    set: [names.len]?[]const u8 = @splat(null),

    /// A knob's value: the environment's, else the seed's, else none.
    pub fn get(self: *const Knobs, name: []const u8) ?[]const u8 {
        for (names, 0..) |n, i| {
            if (!std.mem.eql(u8, n, name)) continue;
            if (self.set[i]) |v| return v;
            const s = self.drawn[i] orelse return null;
            return self.text[s.at..][0..s.len];
        }
        return null;
    }

    /// Every knob `env` sets (anything with `getPosix(name) ?[]const u8`),
    /// over whatever the seed chose.
    pub fn overlay(self: *Knobs, env: anytype) void {
        inline for (names, 0..) |n, i| {
            if (env.getPosix(n)) |v| self.set[i] = v;
        }
    }

    /// **THE KNOBS A SEED TURNS**, from the ranges in the table above.
    pub fn fromSeed(seed: u64) Knobs {
        var k = Knobs{};
        var prng = std.Random.DefaultPrng.init(seed);
        const r = prng.random();
        if (chance(r, 2)) k.list(index("WIRE_EAT"), r, r.intRangeAtMost(u32, 1, 3), 1, 40);
        if (chance(r, 4)) k.number(index("WIRE_LOSS"), r.intRangeAtMost(u64, 5, 50));
        if (chance(r, 2)) k.number(index("WIRE_LATENCY_US"), r.intRangeAtMost(u64, 100, 20_000));
        if (chance(r, 3)) k.list(index("PEER_EAT"), r, r.intRangeAtMost(u32, 1, 2), 1, 40);
        if (chance(r, 6)) k.number(index("PEER_LOSS"), r.intRangeAtMost(u64, 5, 50));
        if (chance(r, 4)) k.list(index("PEER_DAMAGE"), r, 1, 1, 40);
        if (chance(r, 4)) {
            k.list(index("DISK_REFUSE"), r, 1, 1, 100);
            if (r.boolean()) k.number(index("DISK_WRITES_ONLY"), 1);
        }
        // A power cut, or a torn write: rarer, because a seed that cuts the
        // power ends there, and most of a sweep should run to the end.
        if (chance(r, 6)) {
            k.number(index("DISK_CUT_AFTER"), r.intRangeAtMost(u64, 1, 100));
        } else if (chance(r, 8)) {
            k.number(index("DISK_TEAR"), r.intRangeAtMost(u64, 1, 20));
            k.number(index("DISK_TEAR_KEEP"), r.intRangeAtMost(u64, 1, 7));
        }
        if (chance(r, 4)) {
            k.number(index("PEER_RESET_AT"), r.intRangeAtMost(u64, 1_000, 2_000_000));
            if (r.boolean()) k.number(index("PEER_RESET_OFF"), r.intRangeAtMost(u64, 1, 2000));
        }
        if (chance(r, 4)) k.number(index("PEER_VANISH_AFTER"), r.intRangeAtMost(u64, 1, 60_000));
        if (chance(r, 4)) {
            k.number(index("PEER_FLOOD"), r.intRangeAtMost(u64, 1, 8));
            k.number(index("PEER_FLOOD_GAP_US"), r.intRangeAtMost(u64, 10_000, 400_000));
        }
        if (chance(r, 4)) {
            k.number(index("PEER_SHUT_AFTER"), r.intRangeAtMost(u64, 1, 20_000));
            k.number(index("PEER_SHUT_FOR_US"), r.intRangeAtMost(u64, 10_000, 5_000_000));
        }
        if (chance(r, 4)) k.number(index("PEER_MSS"), r.intRangeAtMost(u64, 1, 1460));
        // Drawn last, so every knob above is what each seed always drew.
        if (chance(r, 8)) k.pair(index("DISK_ROT"), r.uintLessThan(u64, 4096), r.uintLessThan(u64, 512));
        return k;
    }

    fn chance(r: std.Random, one_in: u32) bool {
        return r.uintLessThan(u32, one_in) == 0;
    }

    fn number(self: *Knobs, i: usize, n: u64) void {
        const written = std.fmt.bufPrint(self.text[self.used..], "{d}", .{n}) catch unreachable;
        self.drawn[i] = .{ .at = @intCast(self.used), .len = @intCast(written.len) };
        self.used += written.len;
    }

    /// Two numbers, `a,b`.
    fn pair(self: *Knobs, i: usize, a: u64, b: u64) void {
        const written = std.fmt.bufPrint(self.text[self.used..], "{d},{d}", .{ a, b }) catch unreachable;
        self.drawn[i] = .{ .at = @intCast(self.used), .len = @intCast(written.len) };
        self.used += written.len;
    }

    /// `how_many` distinct numbers from `lo` to `hi`, in order.
    fn list(self: *Knobs, i: usize, r: std.Random, how_many: u32, lo: u32, hi: u32) void {
        var picked: [8]u32 = undefined;
        var n: usize = 0;
        while (n < how_many) {
            const x = r.intRangeAtMost(u32, lo, hi);
            if (std.mem.indexOfScalar(u32, picked[0..n], x) != null) continue;
            picked[n] = x;
            n += 1;
        }
        std.mem.sort(u32, picked[0..n], {}, std.sort.asc(u32));
        const start = self.used;
        for (picked[0..n], 0..) |x, j| {
            const written = std.fmt.bufPrint(self.text[self.used..], "{s}{d}", .{ if (j == 0) "" else ",", x }) catch unreachable;
            self.used += written.len;
        }
        self.drawn[i] = .{ .at = @intCast(start), .len = @intCast(self.used - start) };
    }

    /// **THE SCHEDULE AS THE KNOBS THAT REPRODUCE IT**: `NAME=value`, space
    /// apart, in `names` order; "none" when nothing is turned.
    pub fn format(self: *const Knobs, buf: []u8) []const u8 {
        var at: usize = 0;
        for (names) |n| {
            const v = self.get(n) orelse continue;
            const written = std.fmt.bufPrint(buf[at..], "{s}{s}={s}", .{ if (at == 0) "" else " ", n, v }) catch break;
            at += written.len;
        }
        if (at == 0) return "none";
        return buf[0..at];
    }
};

// ── what can be checked without a guest ──────────────────────────────────────

const testing = std.testing;

/// An environment, by hand.
const Env = struct {
    pairs: []const [2][]const u8,

    pub fn getPosix(self: Env, name: []const u8) ?[]const u8 {
        for (self.pairs) |p| if (std.mem.eql(u8, p[0], name)) return p[1];
        return null;
    }
};

test "a seed is one schedule: the same seed twice is the same knobs" {
    var a: [512]u8 = undefined;
    var b: [512]u8 = undefined;
    for (0..200) |seed| {
        const x = Knobs.fromSeed(seed);
        const y = Knobs.fromSeed(seed);
        try testing.expectEqualStrings(x.format(&a), y.format(&b));
    }
}

test "different seeds turn different knobs, and every knob is turned by some seed" {
    var turned: [names.len]bool = @splat(false);
    var distinct: usize = 0;
    var last: [512]u8 = undefined;
    var last_len: usize = 0;
    var buf: [512]u8 = undefined;
    for (0..500) |seed| {
        const k = Knobs.fromSeed(seed);
        for (names, 0..) |n, i| if (k.get(n) != null) {
            turned[i] = true;
        };
        const f = k.format(&buf);
        if (!std.mem.eql(u8, f, last[0..last_len])) distinct += 1;
        @memcpy(last[0..f.len], f);
        last_len = f.len;
    }
    for (turned, names) |t, n| {
        // Eleven knobs only a person sets: a seed's runs keep to the flood
        // and rates of the table above, and name no sector.
        if (!t and !std.mem.eql(u8, n, "PEER_DAMAGE_RATE") and !std.mem.eql(u8, n, "DISK_REFUSE_RATE") and
            !std.mem.eql(u8, n, "PEER_FLOOD_AT_US") and !std.mem.eql(u8, n, "DISK_BAD_SECTOR") and
            !std.mem.eql(u8, n, "DISK_READS_ONLY") and !std.mem.eql(u8, n, "PEER_IGNORE_WINDOW") and
            !std.mem.eql(u8, n, "DISK_CACHE") and !std.mem.eql(u8, n, "PEER_RETRY") and
            !std.mem.eql(u8, n, "RTC_BOOTS_AT") and !std.mem.eql(u8, n, "PEER_DRIP_US") and
            !std.mem.eql(u8, n, "PEER_PIPELINE"))
        {
            std.debug.print("never turned: {s}\n", .{n});
            return error.TestUnexpectedResult;
        }
    }
    try testing.expect(distinct > 400);
}

test "every value a seed draws is in its documented range" {
    for (0..2000) |seed| {
        const k = Knobs.fromSeed(seed);
        if (k.get("WIRE_EAT")) |v| try inRangeList(v, 1, 40, 3);
        if (k.get("PEER_EAT")) |v| try inRangeList(v, 1, 40, 2);
        if (k.get("PEER_DAMAGE")) |v| try inRangeList(v, 1, 40, 1);
        if (k.get("DISK_REFUSE")) |v| try inRangeList(v, 1, 100, 1);
        try inRange(k.get("WIRE_LOSS"), 5, 50);
        try inRange(k.get("WIRE_LATENCY_US"), 100, 20_000);
        try inRange(k.get("PEER_LOSS"), 5, 50);
        try inRange(k.get("PEER_RESET_AT"), 1_000, 2_000_000);
        try inRange(k.get("PEER_RESET_OFF"), 1, 2000);
        try inRange(k.get("PEER_VANISH_AFTER"), 1, 60_000);
        try inRange(k.get("PEER_FLOOD"), 1, 8);
        try inRange(k.get("PEER_FLOOD_GAP_US"), 10_000, 400_000);
        try inRange(k.get("PEER_SHUT_AFTER"), 1, 20_000);
        try inRange(k.get("PEER_SHUT_FOR_US"), 10_000, 5_000_000);
        try inRange(k.get("PEER_MSS"), 1, 1460);
        try inRange(k.get("DISK_CUT_AFTER"), 1, 100);
        try inRange(k.get("DISK_TEAR"), 1, 20);
        try inRange(k.get("DISK_TEAR_KEEP"), 1, 7);
        if (k.get("DISK_ROT")) |v| {
            var parts = std.mem.splitScalar(u8, v, ',');
            try inRange(parts.next(), 0, 4095);
            try inRange(parts.next(), 0, 511);
            try testing.expect(parts.next() == null);
        }
        // A seed cuts the power one way or the other, never both.
        try testing.expect(k.get("DISK_CUT_AFTER") == null or k.get("DISK_TEAR") == null);
        // A reset's offset only with a reset; a flood's gap only with a flood.
        if (k.get("PEER_RESET_OFF") != null) try testing.expect(k.get("PEER_RESET_AT") != null);
        try testing.expectEqual(k.get("PEER_FLOOD") != null, k.get("PEER_FLOOD_GAP_US") != null);
    }
}

fn inRange(v: ?[]const u8, lo: u64, hi: u64) !void {
    const n = try std.fmt.parseInt(u64, v orelse return, 10);
    try testing.expect(n >= lo and n <= hi);
}

fn inRangeList(v: []const u8, lo: u64, hi: u64, most: usize) !void {
    var n: usize = 0;
    var last: u64 = 0;
    var each = std.mem.tokenizeScalar(u8, v, ',');
    while (each.next()) |one| : (n += 1) {
        const x = try std.fmt.parseInt(u64, one, 10);
        try testing.expect(x >= lo and x <= hi and x > last);
        last = x;
    }
    try testing.expect(n >= 1 and n <= most);
}

test "an explicit knob wins over the seed, and the rest of the seed stands" {
    var seed: u64 = 0;
    var k = while (true) : (seed += 1) {
        const k = Knobs.fromSeed(seed);
        if (k.get("WIRE_EAT") != null and k.get("WIRE_LATENCY_US") != null) break k;
    };
    const latency = k.get("WIRE_LATENCY_US").?;
    k.overlay(Env{ .pairs = &.{ .{ "WIRE_EAT", "7" }, .{ "PEER_MSS", "100" }, .{ "PATIENCE_S", "5" } } });
    try testing.expectEqualStrings("7", k.get("WIRE_EAT").?);
    try testing.expectEqualStrings("100", k.get("PEER_MSS").?);
    try testing.expectEqualStrings(latency, k.get("WIRE_LATENCY_US").?);
    try testing.expect(k.get("PATIENCE_S") == null); // not a fault knob
}

test "the printed schedule is the knobs that reproduce it" {
    var buf: [512]u8 = undefined;
    var again: [512]u8 = undefined;
    for (0..300) |seed| {
        const k = Knobs.fromSeed(seed);
        const printed = k.format(&buf);
        // Parse the line back as an environment: the same knobs.
        var pairs: [names.len][2][]const u8 = undefined;
        var n: usize = 0;
        if (!std.mem.eql(u8, printed, "none")) {
            var each = std.mem.tokenizeScalar(u8, printed, ' ');
            while (each.next()) |kv| : (n += 1) {
                const eq = std.mem.indexOfScalar(u8, kv, '=').?;
                pairs[n] = .{ kv[0..eq], kv[eq + 1 ..] };
            }
        }
        var by_hand = Knobs{};
        by_hand.overlay(Env{ .pairs = pairs[0..n] });
        try testing.expectEqualStrings(printed, by_hand.format(&again));
    }
}

test "no seed and no knobs: nothing is turned" {
    var k = Knobs{};
    k.overlay(Env{ .pairs = &.{} });
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("none", k.format(&buf));
    for (names) |n| try testing.expect(k.get(n) == null);
}
