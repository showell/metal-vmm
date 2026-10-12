//! Scratch experiment for the 181 review. Not for commit.
const std = @import("std");
const disk_fat = @import("disk_fat.zig");
const virtio = @import("virtio.zig");
const test_disk = @import("test_disk.zig");
const testing = std.testing;
const Disk = test_disk.Disk;
const Kind = @FieldType(virtio.Block.Fault, "kind");

const W = struct { at: u64, lba: u64, sectors: u32 };

const Rec = struct {
    blk: *virtio.Block,
    list: std.ArrayList(W) = .empty,
    fn each(context: *anyopaque, write: bool, lba: u64, sectors: u32) void {
        const r: *Rec = @ptrCast(@alignCast(context));
        if (!write) return;
        r.list.append(testing.allocator, .{ .at = r.blk.requests - 1, .lba = lba, .sectors = sectors }) catch unreachable;
    }
};

fn pat(bytes: []u8, seed: u8) []u8 {
    for (bytes, 0..) |*b, i| b.* = @truncate(i *% 7 +% seed +% (i >> 9));
    return bytes;
}

const Mounted = struct { found: []const u8, trusted: u32, repaired: u32, ms: u64 };

fn remount(d: *Disk) !Mounted {
    d.vol = try disk_fat.Volume.mount(&d.blk, &d.scratch, 0);
    if (d.fat_cache) |c| d.gpa.free(c);
    if (d.check_room) |r| d.gpa.free(r);
    d.fat_cache = try d.gpa.alloc(u8, d.vol.fatBytes());
    d.check_room = try d.gpa.alloc(u8, d.vol.checkBytes());
    const t0 = d.blk.requests;
    const m = try d.vol.cacheFatChecked(d.fat_cache.?, d.check_room.?);
    const t1 = d.blk.requests;
    d.repaired = m.repaired;
    d.trusted = m.trusted;
    if (m.found == .tied) {
        ties += 1;
        std.debug.print("EXP181 TIE at mount: health0 problems {d} leaked {d}, health1 problems {d} leaked {d}\n", .{ m.health[0].problems, m.health[0].leaked, m.health[1].problems, m.health[1].leaked });
    }
    if (m.found == .unweighed) unweighed_n += 1;
    d.vol.dir_burst = &d.dir_burst;
    d.vol.cacheDirs(&d.dir_keys, &d.dir_data);
    return .{ .found = @tagName(m.found), .trusted = m.trusted, .repaired = m.repaired, .ms = t1 - t0 };
}

const Col = struct {
    buf: []u8,
    w: usize = 0,
    dmg: u32 = 0,
    shown: u32 = 0,
    fn each(c: *Col, f: disk_fat.Finding) void {
        if (f.problem.damage()) c.dmg += 1;
        if (c.shown >= 8) return;
        c.shown += 1;
        const s = std.fmt.bufPrint(c.buf[c.w..], "{s}{s}('{s}' c{d} n{d}) ", .{ if (f.problem.damage()) "!" else "", @tagName(f.problem), f.path[0..@min(f.path.len, 40)], f.cluster, f.count }) catch return;
        c.w += s.len;
    }
};

fn checkDamage(d: *Disk) !u32 {
    var buf: [2048]u8 = undefined;
    var c = Col{ .buf = &buf };
    const seen = try d.gpa.alloc(u8, d.vol.checkBytes());
    defer d.gpa.free(seen);
    _ = try d.vol.check(seen, &c, Col.each);
    return c.dmg;
}

fn damageLine(d: *Disk, out: []u8) ![]const u8 {
    var c = Col{ .buf = out };
    const seen = try d.gpa.alloc(u8, d.vol.checkBytes());
    defer d.gpa.free(seen);
    const h = try d.vol.check(seen, &c, Col.each);
    const s = try std.fmt.bufPrint(out[c.w..], "[problems {d}, damage {d}, leaked {d}]", .{ h.problems, c.dmg, h.leaked });
    return out[0 .. c.w + s.len];
}

fn readsAs(d: *Disk, path: []const u8, want: []const u8) []const u8 {
    const got = d.read(path) catch |e| return @errorName(e);
    defer d.gpa.free(got);
    return if (std.mem.eql(u8, got, want)) "whole" else "WRONG BYTES";
}

/// After a fault: remount, check, read `path` back (if `want`), write 4 MB
/// more, read it back, check again.
fn after(label: []const u8, d: *Disk, wrote: []const u8, path: []const u8, want: ?[]const u8, alt: ?[]const u8) !void {
    d.blk.fault = null;
    d.blk.fail_after = null;
    var buf: [2048]u8 = undefined;
    var buf2: [2048]u8 = undefined;
    const m = try remount(d);
    const c1 = try damageLine(d, &buf);
    var rb: []const u8 = "-";
    if (want) |w| {
        rb = readsAs(d, path, w);
        if (alt) |a| if (!std.mem.eql(u8, rb, "whole")) {
            const r2 = readsAs(d, path, a);
            if (std.mem.eql(u8, r2, "whole")) rb = "whole(old)";
        };
    }
    const next = try testing.allocator.alloc(u8, 4 << 20);
    defer testing.allocator.free(next);
    _ = pat(next, 0x33);
    const nres: []const u8 = if (d.vol.writeFile("next.bin", next)) |_| readsAs(d, "next.bin", next) else |e| @errorName(e);
    var rb2: []const u8 = "-";
    if (want) |w| {
        rb2 = readsAs(d, path, w);
        if (alt) |a| if (!std.mem.eql(u8, rb2, "whole")) {
            if (std.mem.eql(u8, readsAs(d, path, a), "whole")) rb2 = "whole(old)";
        };
    }
    const c2 = try damageLine(d, &buf2);
    std.debug.print("{s}: write={s} mount={s} trusted={d} repaired={d} mount_reqs={d}\n    check: {s}\n    file: {s}; next 4MB: {s}; file after: {s}\n    check after: {s}\n", .{ label, wrote, m.found, m.trusted, m.repaired, m.ms, c1, rb, nres, rb2, c2 });
}

fn record(d: *Disk, rec: *Rec) void {
    rec.* = .{ .blk = &d.blk };
    d.blk.observe = .{ .context = rec, .each = Rec.each };
}

fn copyOf(d: *Disk, lba: u64) ?u32 {
    const fs = d.vol.fat_start;
    const per = d.vol.sectors_per_fat;
    if (lba < fs or lba >= fs + 2 * per) return null;
    return @intCast((lba - fs) / per);
}

const mb20 = 40_960 * 512;
var ties: u32 = 0;
var unweighed_n: u32 = 0;


test "EXP181 1: one lie to copy 0's FAT write of a 20 MB upload" {
    const bytes = try testing.allocator.alloc(u8, mb20);
    defer testing.allocator.free(bytes);
    _ = pat(bytes, 0x5A);
    // Probe.
    var rec: Rec = undefined;
    {
        const d = try Disk.make("damaged-probe", test_disk.small32, true);
        defer d.deinit();
        record(d, &rec);
        try d.vol.writeFile("up.bin", bytes);
        d.blk.observe = null;
        std.debug.print("\nEXP181 writes of the 20MB upload (FAT ones):\n", .{});
        for (rec.list.items) |w| if (copyOf(d, w.lba)) |c| std.debug.print("  req {d} copy {d} lba {d} sectors {d}\n", .{ w.at, c, w.lba, w.sectors });
    }
    defer rec.list.deinit(testing.allocator);
    // Targets: every copy-0 FAT write (178 has many: cap to first, middle, last, largest).
    var targets: std.ArrayList(u64) = .empty;
    defer targets.deinit(testing.allocator);
    {
        const d = try Disk.make("damaged-probe2", test_disk.small32, true);
        defer d.deinit();
        var c0: std.ArrayList(W) = .empty;
        defer c0.deinit(testing.allocator);
        for (rec.list.items) |w| if (copyOf(d, w.lba)) |c| if (c == 0) try c0.append(testing.allocator, w);
        var big: W = c0.items[0];
        for (c0.items) |w| if (w.sectors > big.sectors) {
            big = w;
        };
        try targets.append(testing.allocator, c0.items[0].at);
        if (big.at != c0.items[0].at) try targets.append(testing.allocator, big.at);
        try targets.append(testing.allocator, c0.items[c0.items.len / 2].at);
        std.debug.print("EXP181 copy-0 FAT writes: {d}; targets", .{c0.items.len});
        for (targets.items) |t| std.debug.print(" {d}", .{t});
        std.debug.print("\n", .{});
    }
    for (targets.items) |at| for ([_]Kind{ .lands_nothing, .torn }) |lie| {
        const d = try Disk.make("damaged-lie", test_disk.small32, true);
        defer d.deinit();
        d.blk.fault = .{ .at = at, .kind = lie };
        const wrote: []const u8 = if (d.vol.writeFile("up.bin", bytes)) |_| "ok" else |e| @errorName(e);
        var label: [64]u8 = undefined;
        try after(try std.fmt.bufPrint(&label, "EXP181 lie {s} at req {d}", .{ @tagName(lie), at }), d, wrote, "up.bin", bytes, null);
    };
    // The cut: torn then stop, at the first copy-0 FAT write; and the cut right
    // after copy 0's write (copy 0 whole, copy 1 not).
    for (targets.items[0..1]) |at| {
        {
            const d = try Disk.make("damaged-cut", test_disk.small32, true);
            defer d.deinit();
            const free = d.vol.free_clusters;
            d.blk.fault = .{ .at = at, .kind = .torn };
            d.blk.fail_after = at + 1;
            const wrote: []const u8 = if (d.vol.writeFile("up.bin", bytes)) |_| "ok" else |e| @errorName(e);
            var label: [96]u8 = undefined;
            try after(try std.fmt.bufPrint(&label, "EXP181 torn+cut at req {d} (free before {d})", .{ at, free }), d, wrote, "up.bin", null, null);
        }
        {
            const d = try Disk.make("damaged-cut2", test_disk.small32, true);
            defer d.deinit();
            const free = d.vol.free_clusters;
            d.blk.fail_after = at + 1;
            const wrote: []const u8 = if (d.vol.writeFile("up.bin", bytes)) |_| "ok" else |e| @errorName(e);
            var label: [96]u8 = undefined;
            try after(try std.fmt.bufPrint(&label, "EXP181 cut after copy0 landed, req {d} (free before {d})", .{ at, free }), d, wrote, "up.bin", null, null);
        }
    }
}

/// Every request of an operation, under every fault: the next mount must
/// find no damage, and a file the op committed (or the old one) reads whole.
fn sweep(comptime name: []const u8, prep: *const fn (*Disk, []u8, []u8) anyerror!void, op: *const fn (*Disk, []u8, []u8) anyerror!void, path: []const u8, new: bool) !void {
    const a = try testing.allocator.alloc(u8, mb20 / 2);
    defer testing.allocator.free(a);
    const b = try testing.allocator.alloc(u8, mb20 / 2);
    defer testing.allocator.free(b);
    _ = pat(a, 1);
    _ = pat(b, 2);
    var total: u64 = 0;
    {
        const d = try Disk.make("damaged-sweep-probe", test_disk.small32, true);
        defer d.deinit();
        try prep(d, a, b);
        const before = d.blk.requests;
        try op(d, a, b);
        total = d.blk.requests - before;
    }
    var bad: u32 = 0;
    var data_lies: u32 = 0;
    var runs: u32 = 0;
    var weighed_whole_picks1: u32 = 0;
    const modes = [_][]const u8{ "lands_nothing", "torn", "cut", "torn+cut", "lands_and_fails" };
    for (modes) |mode| {
        var n: u64 = 0;
        while (n < total) : (n += 1) {
            const d = try Disk.make("damaged-sweep", test_disk.small32, true);
            defer d.deinit();
            try prep(d, a, b);
            const at = d.blk.requests + n;
            if (std.mem.eql(u8, mode, "lands_nothing")) d.blk.fault = .{ .at = at, .kind = .lands_nothing };
            if (std.mem.eql(u8, mode, "lands_and_fails")) d.blk.fault = .{ .at = at, .kind = .lands_and_fails };
            if (std.mem.eql(u8, mode, "torn")) d.blk.fault = .{ .at = at, .kind = .torn };
            if (std.mem.eql(u8, mode, "cut")) d.blk.fail_after = at;
            if (std.mem.eql(u8, mode, "torn+cut")) {
                d.blk.fault = .{ .at = at, .kind = .torn };
                d.blk.fail_after = at + 1;
            }
            const ok = if (op(d, a, b)) |_| true else |_| false;
            d.blk.fault = null;
            d.blk.fail_after = null;
            const m = try remount(d);
            if (m.trusted == 1 and std.mem.eql(u8, m.found, "weighed")) weighed_whole_picks1 += 1;
            const dmg = (try checkDamage(d)) > 0;
            // What must read: committed op -> new; else old or new.
            var reads: []const u8 = "-";
            if (ok and !new) {
                reads = readsAs(d, path, a);
                if (std.mem.eql(u8, reads, "NotFound")) reads = "whole";
            } else if (ok) {
                reads = readsAs(d, path, b);
            } else {
                const x = readsAs(d, path, if (new) b else a);
                const y = readsAs(d, path, a);
                reads = if (std.mem.eql(u8, x, "whole") or std.mem.eql(u8, y, "whole")) "whole" else if (std.mem.eql(u8, x, "NotFound")) "NotFound" else x;
            }
            const lost = ok and !std.mem.eql(u8, reads, "whole");
            const lost2 = !ok and !std.mem.eql(u8, reads, "whole") and !std.mem.eql(u8, reads, "NotFound");
            if (!dmg and ok and std.mem.eql(u8, reads, "WRONG BYTES")) {
                data_lies += 1;
            } else if (dmg or lost or lost2) {
                bad += 1;
                var buf: [2048]u8 = undefined;
                std.debug.print("EXP181 {s} {s} at +{d}/{d}: op={s} mount={s} trusted={d} repaired={d}: {s}; file {s}\n", .{ name, mode, n, total, if (ok) "ok" else "err", m.found, m.trusted, m.repaired, try damageLine(d, &buf), reads });
            }
            runs += 1;
        }
    }
    std.debug.print("EXP181 sweep {s}: {d} requests, {d} runs, {d} bad, {d} data-write lies (wrong bytes, chain sound), {d} mounts trusted copy 1\n", .{ name, total, runs, bad, data_lies, weighed_whole_picks1 });
}

fn prepNone(_: *Disk, _: []u8, _: []u8) anyerror!void {}
fn prepA(d: *Disk, a: []u8, _: []u8) anyerror!void {
    try d.vol.writeFile("f.bin", a);
}
fn prepFrag(d: *Disk, a: []u8, _: []u8) anyerror!void {
    // Fragment the free space: many small files, every other one removed.
    var name: [32]u8 = undefined;
    var k: u32 = 0;
    while (k < 60) : (k += 1) try d.vol.writeFile(try std.fmt.bufPrint(&name, "s{d}.bin", .{k}), a[0 .. 40 * 1024]);
    k = 0;
    while (k < 60) : (k += 2) try d.vol.remove(try std.fmt.bufPrint(&name, "s{d}.bin", .{k}));
}
fn opWriteB(d: *Disk, _: []u8, b: []u8) anyerror!void {
    try d.vol.writeFile("f.bin", b);
}
fn opRemove(d: *Disk, _: []u8, _: []u8) anyerror!void {
    try d.vol.remove("f.bin");
}

test "EXP181 2: sweep a 10 MB write on an empty volume" {
    try sweep("write10", prepNone, opWriteB, "f.bin", true);
}
test "EXP181 3: sweep a 10 MB overwrite of a 10 MB file" {
    try sweep("overwrite10", prepA, opWriteB, "f.bin", true);
}
test "EXP181 4: sweep a remove of a 10 MB file" {
    try sweep("remove10", prepA, opRemove, "f.bin", false);
}
test "EXP181 5: sweep a 10 MB write on fragmented free space" {
    try sweep("fragwrite10", prepFrag, opWriteB, "f.bin", true);
}

fn prepAppendBase(d: *Disk, a: []u8, _: []u8) anyerror!void {
    try d.vol.writeFile("f.bin", a);
}
fn opAppend(d: *Disk, a: []u8, b: []u8) anyerror!void {
    try d.vol.writeInto("f.bin", @intCast(a.len), b);
}

test "EXP181 6: sweep a 10 MB append to a 10 MB file" {
    // After: the file reads a (old) or a++b (new): judged by length and prefix.
    const a = try testing.allocator.alloc(u8, mb20 / 2);
    defer testing.allocator.free(a);
    const b = try testing.allocator.alloc(u8, mb20 / 2);
    defer testing.allocator.free(b);
    _ = pat(a, 1);
    _ = pat(b, 2);
    var total: u64 = 0;
    {
        const d = try Disk.make("damaged-ap-probe", test_disk.small32, true);
        defer d.deinit();
        try prepAppendBase(d, a, b);
        const before = d.blk.requests;
        try opAppend(d, a, b);
        total = d.blk.requests - before;
    }
    var bad: u32 = 0;
    var data_lies: u32 = 0;
    for ([_][]const u8{ "lands_nothing", "torn", "cut", "torn+cut", "lands_and_fails" }) |mode| {
        var n: u64 = 0;
        while (n < total) : (n += 1) {
            const d = try Disk.make("damaged-ap", test_disk.small32, true);
            defer d.deinit();
            try prepAppendBase(d, a, b);
            const at = d.blk.requests + n;
            if (std.mem.eql(u8, mode, "lands_nothing")) d.blk.fault = .{ .at = at, .kind = .lands_nothing };
            if (std.mem.eql(u8, mode, "lands_and_fails")) d.blk.fault = .{ .at = at, .kind = .lands_and_fails };
            if (std.mem.eql(u8, mode, "torn")) d.blk.fault = .{ .at = at, .kind = .torn };
            if (std.mem.eql(u8, mode, "cut")) d.blk.fail_after = at;
            if (std.mem.eql(u8, mode, "torn+cut")) {
                d.blk.fault = .{ .at = at, .kind = .torn };
                d.blk.fail_after = at + 1;
            }
            const ok = if (opAppend(d, a, b)) |_| true else |_| false;
            d.blk.fault = null;
            d.blk.fail_after = null;
            const m = try remount(d);
            const dmg = (try checkDamage(d)) > 0;
            const got = d.read("f.bin") catch |e| {
                bad += 1;
                std.debug.print("EXP181 append {s} at +{d}: op={s} mount={s} trusted={d}: read {s}\n", .{ mode, n, if (ok) "ok" else "err", m.found, m.trusted, @errorName(e) });
                continue;
            };
            defer d.gpa.free(got);
            const old = std.mem.eql(u8, got, a);
            const new = got.len == a.len + b.len and std.mem.eql(u8, got[0..a.len], a) and std.mem.eql(u8, got[a.len..], b);
            const new_len = got.len == a.len + b.len;
            if (!dmg and ok and new_len and !new) {
                data_lies += 1;
            } else if (dmg or (ok and !new) or (!ok and !old and !new)) {
                bad += 1;
                var buf: [2048]u8 = undefined;
                std.debug.print("EXP181 append {s} at +{d}/{d}: op={s} mount={s} trusted={d} repaired={d}: {s}; len {d} old={} new={}\n", .{ mode, n, total, if (ok) "ok" else "err", m.found, m.trusted, m.repaired, try damageLine(d, &buf), got.len, old, new });
            }
        }
    }
    std.debug.print("EXP181 sweep append10: {d} requests, {d} bad, {d} data lies\n", .{ total, bad, data_lies });
}

test "EXP181 7: a lie to copy 0's run, then every request of the repairing mount cut or lied to" {
    const bytes = try testing.allocator.alloc(u8, mb20);
    defer testing.allocator.free(bytes);
    _ = pat(bytes, 0x5A);
    // Find copy 0's run.
    var at: u64 = 0;
    {
        var rec: Rec = undefined;
        const d = try Disk.make("damaged-p7", test_disk.small32, true);
        defer d.deinit();
        record(d, &rec);
        defer rec.list.deinit(testing.allocator);
        try d.vol.writeFile("up.bin", bytes);
        d.blk.observe = null;
        for (rec.list.items) |w| if (copyOf(d, w.lba)) |c| if (c == 0 and w.sectors > 64) {
            at = w.at;
            break;
        };
    }
    if (at == 0) {
        std.debug.print("EXP181 7: no copy-0 run > 64 sectors on this commit; skipped\n", .{});
        return;
    }
    // Requests of the repairing mount.
    var mount_reqs: u64 = 0;
    {
        const d = try Disk.make("damaged-p7b", test_disk.small32, true);
        defer d.deinit();
        d.blk.fault = .{ .at = at, .kind = .lands_nothing };
        try d.vol.writeFile("up.bin", bytes);
        d.blk.fault = null;
        const before = d.blk.requests;
        _ = try remount(d);
        mount_reqs = d.blk.requests - before;
    }
    var bad: u32 = 0;
    var runs: u32 = 0;
    for ([_][]const u8{ "cut", "lands_nothing", "torn", "fails" }) |mode| {
        var n: u64 = 0;
        while (n < mount_reqs) : (n += 1) {
            const d = try Disk.make("damaged-p7c", test_disk.small32, true);
            defer d.deinit();
            d.blk.fault = .{ .at = at, .kind = .lands_nothing };
            try d.vol.writeFile("up.bin", bytes);
            d.blk.fault = null;
            const m_at = d.blk.requests + n;
            if (std.mem.eql(u8, mode, "cut")) d.blk.fail_after = m_at;
            if (std.mem.eql(u8, mode, "lands_nothing")) d.blk.fault = .{ .at = m_at, .kind = .lands_nothing };
            if (std.mem.eql(u8, mode, "torn")) d.blk.fault = .{ .at = m_at, .kind = .torn };
            if (std.mem.eql(u8, mode, "fails")) d.blk.fault = .{ .at = m_at, .kind = .fails };
            const first: []const u8 = if (remount(d)) |m| m.found else |e| @errorName(e);
            d.blk.fault = null;
            d.blk.fail_after = null;
            // For non-cut modes, the machine goes on: a write, then reboot.
            if (!std.mem.eql(u8, mode, "cut") and !std.mem.eql(u8, first, "ReadFailed")) {
                const nb = bytes[0 .. 4 << 20];
                d.vol.writeFile("next.bin", nb) catch {};
            }
            const m = try remount(d);
            const dmg = try checkDamage(d);
            const rb = readsAs(d, "up.bin", bytes);
            runs += 1;
            if (dmg > 0 or !std.mem.eql(u8, rb, "whole")) {
                bad += 1;
                var buf: [2048]u8 = undefined;
                std.debug.print("EXP181 7 {s} at mount +{d}/{d}: first mount {s}; second {s} trusted={d}: {s}; up.bin {s}\n", .{ mode, n, mount_reqs, first, m.found, m.trusted, try damageLine(d, &buf), rb });
            }
        }
    }
    std.debug.print("EXP181 7: {d} mount requests, {d} runs, {d} bad\n", .{ mount_reqs, runs, bad });
}

test "EXP181 zz: ties" {
    std.debug.print("EXP181 ties {d}, unweighed {d}\n", .{ ties, unweighed_n });
}
