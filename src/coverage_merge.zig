//! **MANY RUNS' COVERAGE, ONE TABLE** (coverage.zig, `Merged`).
//!
//!     zig build coverage-merge -- [--floor <file>] <a.jsonl> [b.jsonl ...]
//!
//! Each file is what `COVERAGE_OUT` gathered (or the judge's `sdk.jsonl`).
//! Prints every property, how many runs reached it and which first, the ones
//! only one run reached, and, with a floor, what is under it. Exits 1 on a
//! FAIL, or with a floor on a property under it or a floor line gone stale,
//! as gopher-metal's long tier gates on `tools/report.py --floor`.

const std = @import("std");
const linux = std.os.linux;
const coverage = @import("coverage.zig");

pub fn main(init: std.process.Init.Minimal) !u8 {
    const allocator = std.heap.page_allocator;
    const argv = init.args.vector;
    var merged = coverage.Merged.init(allocator);
    defer merged.deinit();
    var floor: ?[]const u8 = null;
    var files: usize = 0;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = std.mem.span(argv[i]);
        if (std.mem.eql(u8, arg, "--floor")) {
            i += 1;
            if (i == argv.len) return usage();
            floor = readFile(allocator, argv[i]) orelse return cannot(argv[i]);
            continue;
        }
        const text = readFile(allocator, argv[i]) orelse return cannot(argv[i]);
        try merged.addFile(arg, text);
        files += 1;
    }
    if (files == 0) return usage();
    var out: std.ArrayList(u8) = .empty;
    var w: std.Io.Writer.Allocating = .fromArrayList(allocator, &out);
    const pass = try merged.report(&w.writer, floor);
    const text = w.writer.buffered();
    _ = linux.write(1, text.ptr, text.len);
    return if (pass) 0 else 1;
}

fn usage() u8 {
    std.debug.print("usage: coverage-merge [--floor <file>] <a.jsonl> [b.jsonl ...]\n", .{});
    return 2;
}

fn cannot(path: [*:0]const u8) u8 {
    std.debug.print("coverage-merge: cannot read {s}\n", .{path});
    return 2;
}

/// A whole file, however long.
fn readFile(allocator: std.mem.Allocator, path: [*:0]const u8) ?[]const u8 {
    const opened = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    var all: std.ArrayList(u8) = .empty;
    var chunk: [65536]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &chunk, chunk.len);
        if (linux.errno(n) != .SUCCESS) return null;
        if (n == 0) break;
        all.appendSlice(allocator, chunk[0..n]) catch return null;
    }
    return all.items;
}
