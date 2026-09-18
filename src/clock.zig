//! **THE MACHINE'S TIME, AND WHY IT IS NOT THE HOST'S.**
//!
//! Time here is measured in QUESTIONS. Every exit — every port the guest
//! reads, every register it touches, every timestamp it asks for — advances
//! one counter by a fixed amount, and nothing else advances it. The host's
//! clock is never read. A run is therefore a function of what the guest did,
//! not of what this box was busy with, and the same guest twice is the same
//! run twice.
//!
//! Three devices report that one counter, and because they all derive from it
//! they cannot disagree:
//!
//!   - the **timestamp counter**, `rdtsc`, at a rate this file decides;
//!   - the **interval timer**, the i8254, counting down at its famous
//!     1,193,182 Hz;
//!   - the **real-time clock**, the MC146818 every PC has had since the AT,
//!     which says what day it is.
//!
//! **THE CALIBRATION IS THEREFORE EXACT.** A guest measures its own processor
//! by counting `rdtsc` ticks across a known number of the interval timer's.
//! When both sides of that division come from the same counter, the answer is
//! the rate we chose — not a measurement of this afternoon. See the test at
//! the bottom, which runs the guest's own procedure against these models.

const std = @import("std");

/// **HOW FAR TIME MOVES FOR ONE QUESTION.** Any value gives a deterministic
/// machine; this one is a trade. Too small and a guest waiting a virtual half
/// second asks hundreds of thousands of questions to get there, each of which
/// costs a real trip through the kernel. Too large and the machine cannot
/// measure anything finer than the quantum. Ten microseconds puts the guest's
/// PIT calibration at a few thousand exits and keeps its shortest measured
/// wait — a quarter-millisecond nap between RTC polls — at twenty-five of
/// them.
pub const per_question_ns: u64 = 100_000;

/// **THE RATE OF THE GUEST'S PROCESSOR IS A DECISION, NOT A MEASUREMENT.**
/// 2.5 GHz is close enough to this box's real 2,494 MHz that nothing about
/// the guest's behaviour looks strange, and round enough to read.
pub const tsc_hz: u64 = 2_500_000_000;

/// **THE INSTANT THIS MACHINE BOOTS. EVERY TIME.** 2026-09-18 12:00:00 UTC.
/// A guest that writes a file dates it from here, which is what makes the
/// disk it leaves behind the same disk on every run.
pub const boots_at: i64 = 1_789_732_800;

pub const Clock = struct {
    /// Nanoseconds since the machine started.
    ns: u64 = 0,

    /// The guest asked the outside world for something, so time moved.
    pub fn asked(self: *Clock) void {
        self.ns += per_question_ns;
    }

    /// What `rdtsc` answers.
    pub fn ticks(self: Clock) u64 {
        return @intCast(@as(u128, self.ns) * tsc_hz / std.time.ns_per_s);
    }
};

// ── the interval timer ───────────────────────────────────────────────────────

/// The i8254, channel 0, latched and read — which is all any guest here does
/// with it. It has no gate (port 0x61 belongs to a speaker this machine does
/// not have) and it delivers no interrupt, because the guest runs with them
/// off and polls the count instead.
pub const Pit = struct {
    /// The input frequency every PC has agreed on since 1981.
    pub const hz: u64 = 1_193_182;

    pub const channel0_port: u16 = 0x40;
    pub const command_port: u16 = 0x43;

    began_ns: u64 = 0,
    reload: u16 = 0xFFFF,
    /// Set by a latch command: the count is frozen for the next two reads.
    latched: ?u16 = null,
    /// Which half of the count the next read gives.
    high_next: bool = false,
    /// How many bytes of a reload value have been written.
    written: u2 = 0,

    /// Where the count has got to, counting down from the reload value.
    pub fn count(self: *const Pit, ns: u64) u16 {
        const elapsed = ns -| self.began_ns;
        const ticks: u64 = @intCast(@as(u128, elapsed) * hz / std.time.ns_per_s);
        return @truncate(@as(u64, self.reload) -% ticks);
    }

    pub fn command(self: *Pit, value: u8, ns: u64) void {
        // Bits 5 and 4 say which bytes follow; zero means "latch the count".
        if (value & 0x30 == 0) {
            self.latched = self.count(ns);
            self.high_next = false;
            return;
        }
        self.written = 0;
        self.began_ns = ns;
    }

    pub fn write(self: *Pit, value: u8, ns: u64) void {
        // The reload value arrives low byte first.
        if (self.written == 0) {
            self.reload = (self.reload & 0xFF00) | value;
            self.written = 1;
        } else {
            self.reload = (@as(u16, value) << 8) | (self.reload & 0x00FF);
            self.written = 0;
            self.began_ns = ns;
        }
    }

    pub fn read(self: *Pit, ns: u64) u8 {
        const value = self.latched orelse self.count(ns);
        const byte: u8 = if (self.high_next) @truncate(value >> 8) else @truncate(value);
        if (self.high_next) self.latched = null; // the latch lasts two reads
        self.high_next = !self.high_next;
        return byte;
    }
};

// ── the calendar ─────────────────────────────────────────────────────────────

pub const Civil = struct {
    year: i32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

/// Days since 1970-01-01 to a date, by Howard Hinnant's algorithm — the same
/// one the guest uses to go the other way, so the two agree by construction
/// at every leap year and century.
fn civilFromDays(days: i64) struct { year: i32, month: u8, day: u8 } {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const day = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const month = if (mp < 10) mp + 3 else mp - 9;
    return .{
        .year = @intCast(yoe + era * 400 + @as(i64, if (month <= 2) 1 else 0)),
        .month = @intCast(month),
        .day = @intCast(day),
    };
}

pub fn civilFromUnix(unix: i64) Civil {
    const days = @divFloor(unix, 86400);
    const rest = unix - days * 86400;
    const ymd = civilFromDays(days);
    return .{
        .year = ymd.year,
        .month = ymd.month,
        .day = ymd.day,
        .hour = @intCast(@divTrunc(rest, 3600)),
        .minute = @intCast(@divTrunc(@rem(rest, 3600), 60)),
        .second = @intCast(@rem(rest, 60)),
    };
}

// ── the real-time clock ──────────────────────────────────────────────────────

/// The MC146818. Its registers are not stored anywhere: every read computes
/// them from the counter, in whatever format status B currently says.
pub const Rtc = struct {
    pub const index_port: u16 = 0x70;
    pub const data_port: u16 = 0x71;

    const reg_seconds: u8 = 0x00;
    const reg_minutes: u8 = 0x02;
    const reg_hours: u8 = 0x04;
    const reg_weekday: u8 = 0x06;
    const reg_day: u8 = 0x07;
    const reg_month: u8 = 0x08;
    const reg_year: u8 = 0x09;
    const reg_status_a: u8 = 0x0A;
    const reg_status_b: u8 = 0x0B;
    const reg_status_c: u8 = 0x0C;
    const reg_status_d: u8 = 0x0D;
    /// Where QEMU and the ACPI default keep the century.
    const reg_century: u8 = 0x32;

    const binary_mode: u8 = 0x04;
    const hour24_mode: u8 = 0x02;
    const pm_bit: u8 = 0x80;

    /// **THE CHIP IS NEVER MID-UPDATE HERE.** A real one spends about two
    /// milliseconds a second rolling its registers over and sets bit 7 of
    /// status A to say so; this one computes them on the spot, so there is no
    /// window to warn about. The rest of the byte is the divider and rate a
    /// running chip reports, which is what tells a driver it is there at all —
    /// a port with nothing behind it reads 0xFF, and the guest treats that as
    /// no chip.
    const status_a: u8 = 0x26;
    /// Bit 7: the battery is good. A guest that reads zero here is entitled to
    /// disbelieve every other register.
    const status_d: u8 = 0x80;

    /// BCD, 24-hour: what a PC's chip reports unless someone changes it.
    status_b: u8 = hour24_mode,
    index: u8 = 0,

    /// Port 0x70. Bit 7 is the NMI mask, which belongs to the chipset and not
    /// to the register number.
    pub fn select(self: *Rtc, value: u8) void {
        self.index = value & 0x7F;
    }

    /// Port 0x71. Only status B is writable here, because changing the format
    /// is the only write any guest of ours makes — setting the time would be
    /// telling the machine something it is this program's job to decide.
    pub fn store(self: *Rtc, value: u8) void {
        if (self.index == reg_status_b) self.status_b = value;
    }

    pub fn read(self: *const Rtc, ns: u64) u8 {
        const binary = self.status_b & binary_mode != 0;
        const hour24 = self.status_b & hour24_mode != 0;
        const c = civilFromUnix(boots_at + @as(i64, @intCast(ns / std.time.ns_per_s)));
        return switch (self.index) {
            reg_seconds => encode(c.second, binary),
            reg_minutes => encode(c.minute, binary),
            reg_hours => hours(c.hour, binary, hour24),
            // 1970-01-01 was a Thursday, and the chip counts Sunday as 1.
            reg_weekday => encode(@intCast(@mod(@divFloor(boots_at + @as(i64, @intCast(ns / std.time.ns_per_s)), 86400) + 4, 7) + 1), binary),
            reg_day => encode(c.day, binary),
            reg_month => encode(c.month, binary),
            reg_year => encode(@intCast(@mod(c.year, 100)), binary),
            reg_century => encode(@intCast(@divFloor(c.year, 100)), binary),
            reg_status_a => status_a,
            reg_status_b => self.status_b,
            reg_status_c => 0,
            reg_status_d => status_d,
            else => 0,
        };
    }

    fn encode(value: u8, binary: bool) u8 {
        return if (binary) value else (value / 10) << 4 | (value % 10);
    }

    /// 12-hour clocks count 12, 1, 2 … 11, and set the high bit in the
    /// afternoon. Midnight is 12 AM and noon is 12 PM, which is the part every
    /// implementation gets wrong once.
    fn hours(hour: u8, binary: bool, hour24: bool) u8 {
        if (hour24) return encode(hour, binary);
        const twelve: u8 = if (hour % 12 == 0) 12 else hour % 12;
        return encode(twelve, binary) | (if (hour >= 12) pm_bit else 0);
    }
};

// ── what can be checked without a guest ──────────────────────────────────────

const testing = std.testing;

test "time moves only when the guest asks for something" {
    var clock = Clock{};
    try testing.expectEqual(@as(u64, 0), clock.ticks());
    clock.asked();
    try testing.expectEqual(per_question_ns * tsc_hz / std.time.ns_per_s, clock.ticks());
}

// **THE GUEST'S OWN PROCEDURE, RUN AGAINST THESE MODELS.** The test below is
// pit.zig's `measure()` transcribed exit for exit: a latch command and two
// reads for every count, one exit for every `rdtsc`. What comes out has to be
// the rate this file chose, or a real guest boots with a wrong idea of its own
// speed.
test "the guest's calibration comes back with the rate we chose" {
    const span: u16 = 40_000; // pit.zig's, unchanged

    var clock = Clock{};
    var pit = Pit{};

    const g = struct {
        fn count(c: *Clock, p: *Pit) u16 {
            c.asked();
            p.command(0x00, c.ns); // latch
            c.asked();
            const lo = p.read(c.ns);
            c.asked();
            const hi = p.read(c.ns);
            return @as(u16, hi) << 8 | lo;
        }
        fn rdtsc(c: *Clock) u64 {
            c.asked();
            return c.ticks();
        }
    };

    // Channel 0, mode 2, counting down from the top.
    clock.asked();
    pit.command(0b0011_0100, clock.ns);
    clock.asked();
    pit.write(0xFF, clock.ns);
    clock.asked();
    pit.write(0xFF, clock.ns);

    const first = g.count(&clock, &pit);
    var c0 = first;
    while (c0 == first) c0 = g.count(&clock, &pit);
    const t0 = g.rdtsc(&clock);

    const hz = while (true) {
        const c = g.count(&clock, &pit);
        try testing.expect(c <= c0); // it must not have wrapped
        if (c0 - c >= span) {
            const t1 = g.rdtsc(&clock);
            break (t1 - t0) * Pit.hz / (c0 - c);
        }
    };

    // Within a tick of the PIT's own resolution over the span, which is where
    // the integer division rounds — and, being integer division, the same
    // number on every run.
    try testing.expectApproxEqRel(@as(f64, @floatFromInt(tsc_hz)), @as(f64, @floatFromInt(hz)), 0.0001);
    try testing.expect(hz >= 10_000_000 and hz <= 100_000_000_000); // pit.zig's plausible()
}

test "the machine boots at the same moment every time, in four formats" {
    var rtc = Rtc{};
    // BCD, 24-hour: 2026-09-18 12:00:00 UTC.
    const bcd = struct {
        fn f(v: u8) u8 {
            return (v / 10) << 4 | (v % 10);
        }
    }.f;
    rtc.select(0x09);
    try testing.expectEqual(bcd(26), rtc.read(0));
    rtc.select(0x08);
    try testing.expectEqual(bcd(9), rtc.read(0));
    rtc.select(0x07);
    try testing.expectEqual(bcd(18), rtc.read(0));
    rtc.select(0x04);
    try testing.expectEqual(bcd(12), rtc.read(0));
    rtc.select(0x32);
    try testing.expectEqual(bcd(20), rtc.read(0));

    // Binary, 24-hour.
    rtc.select(0x0B);
    rtc.store(0x04 | 0x02);
    rtc.select(0x04);
    try testing.expectEqual(@as(u8, 12), rtc.read(0));

    // Binary, 12-hour: noon is 12 PM.
    rtc.select(0x0B);
    rtc.store(0x04);
    rtc.select(0x04);
    try testing.expectEqual(@as(u8, 12 | 0x80), rtc.read(0));

    // BCD, 12-hour, an hour before midnight: 11 PM.
    rtc.select(0x0B);
    rtc.store(0);
    rtc.select(0x04);
    try testing.expectEqual(bcd(11) | 0x80, rtc.read(11 * 3600 * std.time.ns_per_s));
    // And an hour after it: 12 AM, not 0.
    rtc.select(0x04);
    try testing.expectEqual(bcd(12), rtc.read(12 * 3600 * std.time.ns_per_s));
    rtc.select(0x07);
    try testing.expectEqual(bcd(19), rtc.read(12 * 3600 * std.time.ns_per_s));
}

test "the calendar agrees with times computed elsewhere" {
    const cases = [_]struct { unix: i64, y: i32, m: u8, d: u8, h: u8, mi: u8, s: u8 }{
        .{ .unix = 0, .y = 1970, .m = 1, .d = 1, .h = 0, .mi = 0, .s = 0 },
        .{ .unix = 951825600, .y = 2000, .m = 2, .d = 29, .h = 12, .mi = 0, .s = 0 },
        .{ .unix = 1583020798, .y = 2020, .m = 2, .d = 29, .h = 23, .mi = 59, .s = 58 },
        .{ .unix = 1735689599, .y = 2024, .m = 12, .d = 31, .h = 23, .mi = 59, .s = 59 },
        .{ .unix = boots_at, .y = 2026, .m = 9, .d = 18, .h = 12, .mi = 0, .s = 0 },
        .{ .unix = 2147483648, .y = 2038, .m = 1, .d = 19, .h = 3, .mi = 14, .s = 8 },
        .{ .unix = 4107542400, .y = 2100, .m = 3, .d = 1, .h = 0, .mi = 0, .s = 0 },
    };
    for (cases) |k| {
        const c = civilFromUnix(k.unix);
        try testing.expectEqual(k.y, c.year);
        try testing.expectEqual(k.m, c.month);
        try testing.expectEqual(k.d, c.day);
        try testing.expectEqual(k.h, c.hour);
        try testing.expectEqual(k.mi, c.minute);
        try testing.expectEqual(k.s, c.second);
    }
}
