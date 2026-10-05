//! **THE FIRST RULE, CHECKED.** Nothing in this program reads the host's
//! clock, the host's randomness, or anything else outside the guest's own
//! inputs (CLOUD_WORK.md, "Rules this machine lives by"). This test reads
//! every source file in `src/` and fails on any use of the host's time or
//! entropy outside the allowlist below, where each exception says why in one
//! line. So a change that slips one in is refused by `zig build test`, not
//! left to a reviewer to notice.
//!
//! Seeded generators (`std.Random.DefaultPrng.init(seed)`) are not on the
//! list: a seed this program chose is an input, not the host. What is on it
//! is anything whose answer depends on when or where the program runs.

const std = @import("std");
const linux = std.os.linux;

/// What reads the host's time or entropy, as it is spelled in Zig source.
const forbidden = [_][]const u8{
    // The host's clock.
    "std.time.timestamp",     "std.time.milliTimestamp", "std.time.microTimestamp",
    "std.time.nanoTimestamp", "std.time.Instant",        "std.time.Timer",
    "clock_gettime",          "gettimeofday",            "Io.Clock",
    "linux.time(",            "CLOCK.REALTIME",          "CLOCK.MONOTONIC",
    // The host's entropy.
    "std.crypto.random",      "getrandom",               "/dev/urandom",
    "/dev/random",            "rdrand",                  "rdseed",
    "RDRAND",                 "RDSEED",
};

/// **THE EXCEPTIONS, EACH WITH ITS REASON.** A file and a spelling it may
/// use; anything else in that file is still refused.
const allowed = [_]struct { file: []const u8, spelling: []const u8, why: []const u8 }{
    .{ .file = "main.zig", .spelling = "rdseed", .why = "names the CPUID bit forgetTheDice clears, so the guest cannot ask the host for entropy" },
    .{ .file = "main.zig", .spelling = "rdrand", .why = "names the CPUID bit forgetTheDice clears" },
};

/// This file spells every forbidden word, in its list.
const self_name = "determinism.zig";

/// One finding: where, and what.
const Finding = struct { line: usize, spelling: []const u8 };

/// **WHAT A FILE USES THAT IT MAY NOT**, comments aside: everything after
/// `//` on a line is a comment here. (A `//` inside a string ends the line
/// early, which can only hide a finding in the rest of that line, never
/// invent one.)
fn scan(file: []const u8, text: []const u8, out: []Finding) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: usize = 0;
    while (lines.next()) |raw| {
        number += 1;
        const code = if (std.mem.indexOf(u8, raw, "//")) |at| raw[0..at] else raw;
        for (forbidden) |word| {
            if (std.mem.indexOf(u8, code, word) == null) continue;
            if (isAllowed(file, word)) continue;
            if (n < out.len) out[n] = .{ .line = number, .spelling = word };
            n += 1;
        }
    }
    return n;
}

fn isAllowed(file: []const u8, word: []const u8) bool {
    for (allowed) |a| {
        if (std.mem.eql(u8, a.file, file) and std.mem.eql(u8, a.spelling, word)) return true;
    }
    return false;
}

/// Every `.zig` file directly in `src/`, by name, from the directory itself,
/// so a new file is read without anybody adding it here.
fn sources(names: *[64][64]u8, lens: *[64]usize) !usize {
    const opened = linux.open("src", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return error.NoSourceDirectory;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    var count: usize = 0;
    var buf: [8192]u8 align(8) = undefined;
    while (true) {
        const got = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(got) != .SUCCESS) return error.CannotList;
        if (got == 0) break;
        var at: usize = 0;
        while (at < got) {
            const entry: *align(1) linux.dirent64 = @ptrCast(&buf[at]);
            const name = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&entry.name)), 0);
            if (std.mem.endsWith(u8, name, ".zig")) {
                if (count == names.len or name.len > names[0].len) return error.TooManyFiles;
                @memcpy(names[count][0..name.len], name);
                lens[count] = name.len;
                count += 1;
            }
            at += entry.reclen;
        }
    }
    return count;
}

fn readSource(name: []const u8, into: []u8) ![]const u8 {
    var path: [128]u8 = undefined;
    const p = try std.fmt.bufPrintZ(&path, "src/{s}", .{name});
    const opened = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(opened) != .SUCCESS) return error.CannotOpen;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    var len: usize = 0;
    while (true) {
        const got = linux.read(fd, into[len..].ptr, into.len - len);
        if (linux.errno(got) != .SUCCESS) return error.CannotRead;
        if (got == 0) break;
        len += got;
        if (len == into.len) return error.TooLarge;
    }
    return into[0..len];
}

// ── the check ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "no source file reads the host's time or entropy, but for the allowlist's reasons" {
    var names: [64][64]u8 = undefined;
    var lens: [64]usize = undefined;
    const count = try sources(&names, &lens);
    try testing.expect(count > 10); // it found the sources, not an empty directory
    const text = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(text);
    var bad: usize = 0;
    var saw_self = false;
    for (0..count) |i| {
        const name = names[i][0..lens[i]];
        if (std.mem.eql(u8, name, self_name)) {
            saw_self = true;
            continue;
        }
        const source = try readSource(name, text);
        var found: [16]Finding = undefined;
        const n = scan(name, source, &found);
        for (found[0..@min(n, found.len)]) |f| {
            std.debug.print("determinism: src/{s}:{d} uses {s}, which reads the host\n", .{ name, f.line, f.spelling });
        }
        bad += n;
    }
    try testing.expect(saw_self);
    try testing.expectEqual(@as(usize, 0), bad);

    // **NO STALE EXCEPTION**: each one is still needed, or it goes.
    for (allowed) |a| {
        const source = try readSource(a.file, text);
        var needed = false;
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw| {
            const code = if (std.mem.indexOf(u8, raw, "//")) |at| raw[0..at] else raw;
            if (std.mem.indexOf(u8, code, a.spelling) != null) needed = true;
        }
        if (!needed) std.debug.print("determinism: the exception for {s} in src/{s} is no longer needed\n", .{ a.spelling, a.file });
        try testing.expect(needed);
    }
}

test "the scanner: code is caught, comments are not, and the allowlist is per file" {
    var found: [8]Finding = undefined;
    const source =
        \\const now = std.time.nanoTimestamp(); // a real use
        \\// std.time.timestamp() in a comment is not
        \\var seed: u64 = 0; std.crypto.random.bytes(&buf);
        \\const r = asm volatile ("rdrand %[x]" : [x] "=r" (-> u64));
    ;
    try testing.expectEqual(@as(usize, 3), scan("other.zig", source, &found));
    try testing.expectEqual(@as(usize, 1), found[0].line);
    try testing.expectEqualStrings("std.time.nanoTimestamp", found[0].spelling);
    try testing.expectEqualStrings("std.crypto.random", found[1].spelling);
    try testing.expectEqualStrings("rdrand", found[2].spelling);
    // main.zig may name rdrand (forgetTheDice's CPUID bit); nothing else.
    try testing.expectEqual(@as(usize, 2), scan("main.zig", source, &found));
}

test "every exception has a reason" {
    for (allowed) |a| try testing.expect(a.why.len > 10);
}
