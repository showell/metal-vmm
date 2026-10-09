//! **A SETTING THAT DOES NOT SAY WHAT IT MEANS STOPS THE RUN** (QUEUE B23's
//! class: what was asked, silently cut to what fits).
//!
//! Every setting metal-vmm reads from the environment is named here with
//! what its value must be. Before a run starts, `complaint` reads the whole
//! environment: a known setting whose value is not one (`PEER_RESET_AT=30ms`,
//! a schedule of 40 frames where 32 fit, `PEER_FLOOD` past its most) is
//! refused, with exit 2, instead of becoming "no fault" or its nearest
//! legal value; so is a volume's setting with no volume to set. A name in
//! one of the settings' families that metal-vmm does not read is said on
//! stderr but does not stop the run: scripts export names of their own
//! (`VOLUME_SITE`), and a misspelt setting is then one line to notice.

const std = @import("std");
const knobs = @import("knobs.zig");
const faults = @import("faults.zig");
const wire = @import("peer.zig");
const mangle = @import("mangle.zig");

const Kind = union(enum) {
    /// A decimal number from `lo` to `hi`.
    number: struct { lo: u64 = 0, hi: u64 = std.math.maxInt(u64) },
    /// "1" on, "0" off.
    flag,
    /// Frames or requests, `n` or `lo-hi`, comma-separated, at most `most`.
    schedule: usize,
    /// Sector numbers, comma-separated, at most `most`.
    sectors: usize,
    /// `sector,byte[,mask]`: a byte under 512, a mask that is not 0.
    rot,
    /// One of these words.
    choice: []const []const u8,
    /// One of `mangle.Kind`'s names.
    mangle_kind,
    /// Files, comma-separated, at most `most`.
    files: usize,
    /// Anything: a path.
    any,
};

const Setting = struct { name: []const u8, kind: Kind, needs_volume: bool = false };

const schedule_most = @typeInfo(@FieldType(faults.Schedule, "named")).array.len;
const bad_most = @typeInfo(@FieldType(faults.Drive, "bad")).array.len;
const any_number: Kind = .{ .number = .{} };
const at_least_one: Kind = .{ .number = .{ .lo = 1 } };
const u32_number: Kind = .{ .number = .{ .hi = std.math.maxInt(u32) } };
/// **A TIME IS AT MOST AN HOUR, A PATIENCE A DAY.** Each is kept in
/// nanoseconds and then added to the machine's clock (`now + latency_ns`, a
/// gap times a client's number), so a bound of what a u64 of nanoseconds
/// holds still overflowed the sum (a cold review, 2026-10-08). No run is
/// near an hour of any one of these; a day of patience is far past the
/// longest a guest is given.
const micros: Kind = .{ .number = .{ .hi = std.time.us_per_hour } };
const whole_seconds: Kind = .{ .number = .{ .lo = 1, .hi = std.time.s_per_day } };

pub const table = [_]Setting{
    // The fault knobs (knobs.zig `names`; a test holds this list to it).
    .{ .name = "WIRE_EAT", .kind = .{ .schedule = schedule_most } },
    .{ .name = "WIRE_LOSS", .kind = u32_number },
    .{ .name = "WIRE_LATENCY_US", .kind = micros },
    .{ .name = "PEER_EAT", .kind = .{ .schedule = schedule_most } },
    .{ .name = "PEER_LOSS", .kind = u32_number },
    .{ .name = "PEER_DAMAGE", .kind = .{ .schedule = schedule_most } },
    .{ .name = "PEER_DAMAGE_RATE", .kind = u32_number },
    .{ .name = "DISK_REFUSE", .kind = .{ .schedule = schedule_most } },
    .{ .name = "DISK_REFUSE_RATE", .kind = u32_number },
    .{ .name = "DISK_WRITES_ONLY", .kind = .flag },
    .{ .name = "DISK_READS_ONLY", .kind = .flag },
    .{ .name = "DISK_BAD_SECTOR", .kind = .{ .sectors = bad_most } },
    .{ .name = "DISK_CUT_AFTER", .kind = any_number },
    .{ .name = "DISK_TEAR", .kind = any_number },
    .{ .name = "DISK_TEAR_KEEP", .kind = any_number },
    .{ .name = "PEER_RESET_AT", .kind = micros },
    .{ .name = "PEER_RESET_OFF", .kind = u32_number },
    .{ .name = "PEER_VANISH_AFTER", .kind = any_number },
    .{ .name = "PEER_FLOOD", .kind = .{ .number = .{ .hi = wire.max_flood } } },
    .{ .name = "PEER_FLOOD_GAP_US", .kind = micros },
    .{ .name = "PEER_FLOOD_AT_US", .kind = micros },
    .{ .name = "PEER_SHUT_AFTER", .kind = any_number },
    .{ .name = "PEER_SHUT_FOR_US", .kind = micros },
    .{ .name = "PEER_MSS", .kind = at_least_one },
    .{ .name = "PEER_IGNORE_WINDOW", .kind = .flag },
    .{ .name = "DISK_ROT", .kind = .rot },
    .{ .name = "DISK_CACHE", .kind = .{ .choice = &.{ "1", "lie" } } },
    .{ .name = "PEER_RETRY", .kind = .{ .number = .{ .hi = 100 } } },
    // main.zig checks its range against the calendar itself.
    .{ .name = "RTC_BOOTS_AT", .kind = .any },
    .{ .name = "PEER_DRIP_US", .kind = micros },
    .{ .name = "PEER_PIPELINE", .kind = .flag },
    .{ .name = "DHCP_LEASE_S", .kind = .{ .number = .{ .lo = 1, .hi = std.math.maxInt(u32) } } },
    .{ .name = "VOLUME_CACHE", .kind = .{ .choice = &.{ "1", "lie" } }, .needs_volume = true },
    .{ .name = "VOLUME_CUT_AFTER", .kind = any_number, .needs_volume = true },
    .{ .name = "VOLUME_SYNC_FAIL", .kind = any_number, .needs_volume = true },
    .{ .name = "VOLUME_SYNC_FAIL_FOR", .kind = any_number, .needs_volume = true },
    .{ .name = "PEER_MANGLE", .kind = .{ .schedule = schedule_most } },
    .{ .name = "PEER_MANGLE_RATE", .kind = u32_number },
    .{ .name = "PEER_MANGLE_KIND", .kind = .mangle_kind },
    .{ .name = "VOLUME_LATENCY_US", .kind = micros, .needs_volume = true },
    .{ .name = "VOLUME_ATTENTION_AT", .kind = any_number, .needs_volume = true },
    .{ .name = "VOLUME_GONE_AT", .kind = any_number, .needs_volume = true },
    .{ .name = "VOLUME_READ_ONLY_AT", .kind = any_number, .needs_volume = true },
    .{ .name = "VOLUME_SYNC_US", .kind = micros, .needs_volume = true },
    .{ .name = "VOLUME_CUT_AT_EXIT", .kind = .flag, .needs_volume = true },
    .{ .name = "VOLUME_CACHE_KEEPS", .kind = any_number, .needs_volume = true },
    .{ .name = "VOLUME_SECTOR", .kind = .{ .number = .{ .lo = 1, .hi = std.math.maxInt(u32) } }, .needs_volume = true },
    .{ .name = "VOLUME_MODE_PAGES", .kind = .{ .choice = &.{"none"} }, .needs_volume = true },
    .{ .name = "VOLUME_WCE_FIXED", .kind = .flag, .needs_volume = true },
    .{ .name = "RTC_ABSENT", .kind = .flag },
    .{ .name = "RTC_STUCK", .kind = .flag },
    .{ .name = "PIT_FROZEN", .kind = .flag },
    .{ .name = "VOLUME_SHORT_AT", .kind = at_least_one, .needs_volume = true },
    // The rest metal-vmm reads.
    .{ .name = "FAULT_SEED", .kind = any_number },
    .{ .name = "PATIENCE_S", .kind = whole_seconds },
    .{ .name = "PEER_CLIENTS", .kind = .{ .number = .{ .lo = 1, .hi = wire.max_clients } } },
    .{ .name = "PEER_ASKS", .kind = .{ .number = .{ .lo = 1, .hi = 1000 } } },
    .{ .name = "PEER_CLIENT_GAP_US", .kind = micros },
    .{ .name = "PEER_REQUEST", .kind = .{ .files = wire.max_clients } },
    .{ .name = "PEER_BODY", .kind = .any },
    .{ .name = "PEER_RESPONSE", .kind = .any },
    .{ .name = "DISK_TRACE", .kind = .flag },
    .{ .name = "TRANSPORT", .kind = .{ .choice = &.{"pci"} } },
    .{ .name = "VOLUME", .kind = .any },
    .{ .name = "COVERAGE_OUT", .kind = .any },
};

/// The families a misspelt setting would be in.
const families = [_][]const u8{ "WIRE_", "PEER_", "DISK_", "VOLUME_", "RTC_", "PIT_", "DHCP_", "FAULT_" };

fn find(name: []const u8) ?Setting {
    for (table) |s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

/// The first setting in `entries` (`NAME=value`, as the environment holds
/// them) that is refused, said in `buf`; null if none is. Names in a family
/// that metal-vmm does not read go to `unknown`, one line each.
pub fn complaint(entries: []const [*:0]const u8, buf: []u8, unknown: ?*const fn ([]const u8) void) ?[]const u8 {
    var volume = false;
    for (entries) |entry| {
        const line = std.mem.span(entry);
        if (std.mem.startsWith(u8, line, "VOLUME=")) volume = true;
    }
    for (entries) |entry| {
        const line = std.mem.span(entry);
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const name = line[0..eq];
        const value = line[eq + 1 ..];
        const setting = find(name) orelse {
            for (families) |f| if (std.mem.startsWith(u8, name, f)) {
                if (unknown) |say| say(name);
                break;
            };
            continue;
        };
        if (setting.needs_volume and !volume)
            return std.fmt.bufPrint(buf, "{s} is set, and there is no VOLUME for it to change", .{name}) catch name;
        if (why(setting.kind, value)) |reason|
            return std.fmt.bufPrint(buf, "{s}={s}: {s}", .{ name, value, reason }) catch name;
    }
    return null;
}

/// Why `value` is not a `kind`, or null if it is one.
fn why(kind: Kind, value: []const u8) ?[]const u8 {
    switch (kind) {
        .any => return null,
        .number => |range| {
            const n = std.fmt.parseInt(u64, value, 10) catch return "not a whole number";
            if (n < range.lo) return "below its least";
            if (n > range.hi) return "past its most";
            return null;
        },
        .flag => return if (std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "0")) null else "neither 1 nor 0",
        .schedule => |most| {
            var n: usize = 0;
            var each = std.mem.splitScalar(u8, value, ',');
            while (each.next()) |one| {
                n += 1;
                if (n > most) return "more entries than the schedule holds";
                if (!isSpan(one)) return "an entry that is not n or lo-hi, from 1";
            }
            return null;
        },
        .sectors => |most| {
            var n: usize = 0;
            var each = std.mem.splitScalar(u8, value, ',');
            while (each.next()) |one| {
                n += 1;
                if (n > most) return "more sectors than the disk keeps";
                _ = std.fmt.parseInt(u64, one, 10) catch return "a sector that is not a whole number";
            }
            return null;
        },
        .rot => {
            var parts = std.mem.splitScalar(u8, value, ',');
            _ = std.fmt.parseInt(u64, parts.next() orelse "", 10) catch return "no sector";
            const byte = std.fmt.parseInt(u16, parts.next() orelse "", 10) catch return "no byte";
            if (byte >= 512) return "a byte past the sector";
            if (parts.next()) |m| {
                const mask = std.fmt.parseInt(u8, m, 0) catch return "a mask that is not a byte";
                if (mask == 0) return "a mask that changes nothing";
            }
            if (parts.next() != null) return "more than sector, byte and mask";
            return null;
        },
        .choice => |words| {
            for (words) |w| if (std.mem.eql(u8, w, value)) return null;
            return "not one of its words";
        },
        .mangle_kind => return if (std.meta.stringToEnum(mangle.Kind, value) != null) null else "not a kind of lie mangle.zig tells",
        .files => |most| {
            var n: usize = 0;
            var each = std.mem.splitScalar(u8, value, ',');
            while (each.next()) |one| {
                n += 1;
                if (n > most) return "more files than there are clients";
                if (one.len == 0) return "an empty file name";
            }
            return null;
        },
    }
}

fn isSpan(text: []const u8) bool {
    const dash = std.mem.indexOfScalar(u8, text, '-') orelse {
        const n = std.fmt.parseInt(u32, text, 10) catch return false;
        return n > 0;
    };
    const lo = std.fmt.parseInt(u32, text[0..dash], 10) catch return false;
    const hi = std.fmt.parseInt(u32, text[dash + 1 ..], 10) catch return false;
    return lo > 0 and hi >= lo;
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "every fault knob is a setting here, and every setting before FAULT_SEED a fault knob" {
    for (knobs.names) |n| {
        if (find(n) == null) {
            std.debug.print("knobs.zig names {s}, and checked.zig does not\n", .{n});
            return error.Missing;
        }
    }
    // The other way: a fault setting knobs.zig does not name is checked and
    // then never turned, so a run that sets it is silently unhurt.
    for (table) |t| {
        if (std.mem.eql(u8, t.name, "FAULT_SEED")) break;
        for (knobs.names) |n| {
            if (std.mem.eql(u8, n, t.name)) break;
        } else {
            std.debug.print("checked.zig has {s} among the fault knobs, and knobs.zig does not name it\n", .{t.name});
            return error.Missing;
        }
    }
}

fn says(entries: []const [*:0]const u8) ?[]const u8 {
    const Static = struct {
        var buf: [256]u8 = undefined;
    };
    return complaint(entries, &Static.buf, null);
}

test "what a setting must be" {
    try testing.expectEqual(@as(?[]const u8, null), says(&.{ "WIRE_EAT=3,9-12", "PEER_RESET_AT=30000", "PEER_PIPELINE=1", "DISK_ROT=2180,7,0x80", "HOME=/x", "PEER_MANGLE_KIND=zero_window" }));
    try testing.expectEqualStrings("PEER_RESET_AT=30ms: not a whole number", says(&.{"PEER_RESET_AT=30ms"}).?);
    try testing.expectEqualStrings("PEER_PIPELINE=yes: neither 1 nor 0", says(&.{"PEER_PIPELINE=yes"}).?);
    try testing.expectEqualStrings("WIRE_EAT=3,x: an entry that is not n or lo-hi, from 1", says(&.{"WIRE_EAT=3,x"}).?);
    try testing.expectEqualStrings("WIRE_EAT=0: an entry that is not n or lo-hi, from 1", says(&.{"WIRE_EAT=0"}).?);
    try testing.expectEqualStrings("PEER_FLOOD=70000: past its most", says(&.{"PEER_FLOOD=70000"}).?);
    try testing.expectEqualStrings("PEER_CLIENTS=9: past its most", says(&.{"PEER_CLIENTS=9"}).?);
    try testing.expectEqualStrings("DISK_ROT=2180,600: a byte past the sector", says(&.{"DISK_ROT=2180,600"}).?);
    try testing.expectEqualStrings("PEER_MANGLE_KIND=lies: not a kind of lie mangle.zig tells", says(&.{"PEER_MANGLE_KIND=lies"}).?);
    try testing.expectEqualStrings("VOLUME_CACHE is set, and there is no VOLUME for it to change", says(&.{"VOLUME_CACHE=1"}).?);
    try testing.expectEqual(@as(?[]const u8, null), says(&.{ "VOLUME_CACHE=lie", "VOLUME=/tmp/v.img" }));
}

test "a schedule past what it holds is refused, not cut" {
    var text: [400]u8 = undefined;
    var at: usize = 0;
    for (0..schedule_most + 1) |i| {
        const w = std.fmt.bufPrint(text[at..], "{s}{d}", .{ if (i == 0) "WIRE_EAT=" else ",", i + 1 }) catch unreachable;
        at += w.len;
    }
    text[at] = 0;
    const entry: [*:0]const u8 = @ptrCast(&text);
    try testing.expect(std.mem.endsWith(u8, says(&.{entry}).?, ": more entries than the schedule holds"));
}

var unknown_seen: usize = 0;
fn countUnknown(_: []const u8) void {
    unknown_seen += 1;
}

test "a name in a family that is not a setting is said, and does not stop the run" {
    unknown_seen = 0;
    var buf: [256]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), complaint(&.{ "PEER_RESETAT=3", "VOLUME_SITE=/x", "PATH=/bin" }, &buf, countUnknown));
    try testing.expectEqual(@as(usize, 2), unknown_seen);
}

test "a time no clock here can hold is refused, not overflowed (metal-vmm QUEUE 103)" {
    // Each of these is read as a whole number and multiplied into nanoseconds
    // (settings.zig, main.zig): `us * std.time.ns_per_us`, `seconds *
    // std.time.ns_per_s`. The table takes any u64 for them, so a value that
    // passes here overflows there: a panic in a safe build, a short wait
    // in a fast one. The most each can be is the most a u64 of nanoseconds
    // holds.
    const micro = [_][]const u8{ "WIRE_LATENCY_US", "PEER_RESET_AT", "PEER_FLOOD_AT_US", "PEER_FLOOD_GAP_US", "PEER_SHUT_FOR_US", "PEER_DRIP_US", "PEER_CLIENT_GAP_US", "VOLUME_SYNC_US", "VOLUME_LATENCY_US" };
    var text: [96]u8 = undefined;
    for (micro) |name| {
        const line = std.fmt.bufPrintZ(&text, "{s}={d}", .{ name, std.time.us_per_hour + 1 }) catch unreachable;
        if (says(&.{ line, "VOLUME=/tmp/v.img" }) == null) {
            std.debug.print("{s} is taken, and overflows when read as nanoseconds\n", .{line});
            return error.Taken;
        }
    }
    const seconds = std.fmt.bufPrintZ(&text, "PATIENCE_S={d}", .{std.time.s_per_day + 1}) catch unreachable;
    if (says(&.{seconds}) == null) {
        std.debug.print("{s} is taken, and overflows when read as nanoseconds\n", .{seconds});
        return error.Taken;
    }
}
