//! **A DISK THAT HOLDS ITS WRITES** (`DISK_CACHE`, QUEUE.md item 44). A real
//! disk acknowledges a write when it is in its cache, not on the platter,
//! and only a flush (VIRTIO_BLK_T_FLUSH) promises it is kept. Pull the power
//! and what was not flushed is gone. So "the client was told 303" is only
//! "the message is saved" on a machine whose guest flushes, and this is how
//! that is asked.
//!
//! **THE SPEC DECIDES WHEN THE CACHE HOLDS** (virtio 1.1 §5.2.5.1): with
//! VIRTIO_BLK_F_FLUSH offered, the cache is write-back if and only if the
//! driver negotiated FLUSH; a driver that did not is promised write-through.
//! `DISK_CACHE=1` is that disk. `DISK_CACHE=lie` holds the writes whether
//! the driver asked or not, as a disk that lies about its cache does.
//!
//! The image is written as the guest writes, so its reads see its writes,
//! as a cache serves them. What the cache keeps is the sectors as they were
//! durable, before the first write since the last flush: a power cut puts
//! them back. Nothing here reads a clock or the host.

const std = @import("std");

pub const sector_bytes = 512;

pub const Cache = struct {
    gpa: std.mem.Allocator,
    image: []u8,
    /// Holds writes whatever the driver negotiated (`DISK_CACHE=lie`).
    lies: bool = false,
    /// Each sector written since the last flush, as it was before.
    durable: std.AutoHashMapUnmanaged(u64, [sector_bytes]u8) = .empty,
    flushes: u64 = 0,
    /// Writes held, and sectors put back by a power cut.
    held: u64 = 0,
    lost: u64 = 0,
    /// The power failed at the run's end (`loseAtExit`), and what it lost.
    exit_cut: bool = false,
    exit_lost: u64 = 0,
    /// Whether any write was ever held, and whether the driver negotiated
    /// FLUSH, for the report.
    write_back: bool = false,
    negotiated: bool = false,

    pub fn deinit(self: *Cache) void {
        self.durable.deinit(self.gpa);
    }

    /// Whether writes are held now, given what the driver negotiated.
    pub fn holds(self: *const Cache, negotiated_flush: bool) bool {
        return self.lies or negotiated_flush;
    }

    /// A write of `sectors` from `sector` is about to land: each sector not
    /// held yet is kept as it is now, durable. False if memory ran out, and
    /// then the write goes through as if write-through, which loses nothing.
    pub fn wrote(self: *Cache, sector: u64, sectors: u64) bool {
        self.write_back = true;
        self.held += 1;
        var s = sector;
        while (s < sector + sectors) : (s += 1) {
            const at = s * sector_bytes;
            if (at + sector_bytes > self.image.len) break;
            const slot = self.durable.getOrPut(self.gpa, s) catch return false;
            if (!slot.found_existing) @memcpy(&slot.value_ptr.*, self.image[at..][0..sector_bytes]);
        }
        return true;
    }

    /// A flush: everything written is durable now.
    pub fn flush(self: *Cache) void {
        self.flushes += 1;
        self.durable.clearRetainingCapacity();
    }

    /// **THE POWER IS CUT**: every sector written since the last flush is
    /// what it was before.
    /// **THE POWER FAILS WHEN THE GUEST STOPS** (`VOLUME_CUT_AT_EXIT=1`):
    /// what was never synchronized is lost at the run's end, as at a cut,
    /// and the line says it was this. `exit_lost` is what it lost.
    pub fn loseAtExit(self: *Cache) void {
        const before = self.lost;
        self.lose();
        self.exit_cut = true;
        self.exit_lost = self.lost - before;
    }

    pub fn lose(self: *Cache) void {
        var it = self.durable.iterator();
        while (it.next()) |e| {
            @memcpy(self.image[e.key_ptr.* * sector_bytes ..][0..sector_bytes], e.value_ptr);
            self.lost += 1;
        }
        self.durable.clearRetainingCapacity();
    }

    /// One line for the run's end, in `buf`.
    pub fn line(self: *const Cache, buf: []u8, cut: bool) []const u8 {
        const mode = if (!self.write_back)
            (if (self.negotiated) "write-back, and nothing was written" else "write-through: the guest did not negotiate FLUSH (virtio 1.1 §5.2.5.1)")
        else if (self.negotiated)
            "write-back, the guest having negotiated FLUSH"
        else
            "write-back, though the guest did not negotiate FLUSH (DISK_CACHE=lie)";
        const end = if (self.exit_cut and !cut)
            std.fmt.bufPrint(buf[0..], "metal-vmm: disk: a write cache, {s}; {d} writes held, {d} flushes; the power failed when the guest stopped and lost {d} sectors never flushed\n", .{ mode, self.held, self.flushes, self.exit_lost })
        else if (cut)
            std.fmt.bufPrint(buf[0..], "metal-vmm: disk: a write cache, {s}; {d} writes held, {d} flushes; the power cut lost {d} sectors never flushed\n", .{ mode, self.held, self.flushes, self.lost })
        else
            std.fmt.bufPrint(buf[0..], "metal-vmm: disk: a write cache, {s}; {d} writes held, {d} flushes\n", .{ mode, self.held, self.flushes });
        return end catch "metal-vmm: disk: a write cache\n";
    }
};

const testing = std.testing;

test "what was written since the last flush is lost at a power cut, and only that" {
    var image: [8 * sector_bytes]u8 = @splat('o');
    var c = Cache{ .gpa = testing.allocator, .image = &image };
    defer c.deinit();
    // Sectors 1 and 2 written, then flushed: durable.
    try testing.expect(c.wrote(1, 2));
    @memset(image[1 * sector_bytes ..][0 .. 2 * sector_bytes], 'a');
    c.flush();
    // Sector 2 again, and 5: held.
    try testing.expect(c.wrote(2, 1));
    @memset(image[2 * sector_bytes ..][0..sector_bytes], 'b');
    try testing.expect(c.wrote(5, 1));
    @memset(image[5 * sector_bytes ..][0..sector_bytes], 'c');
    // Written twice since the flush: the first one's "before" is kept.
    try testing.expect(c.wrote(5, 1));
    @memset(image[5 * sector_bytes ..][0..sector_bytes], 'd');
    c.lose();
    try testing.expectEqual(@as(u8, 'a'), image[1 * sector_bytes]);
    try testing.expectEqual(@as(u8, 'a'), image[2 * sector_bytes]);
    try testing.expectEqual(@as(u8, 'o'), image[5 * sector_bytes]);
    try testing.expectEqual(@as(u8, 'o'), image[0]);
    try testing.expectEqual(@as(u64, 2), c.lost);
    try testing.expectEqual(@as(u64, 1), c.flushes);
}

test "the spec's rule: write-back only if FLUSH was negotiated, unless the disk lies" {
    var image: [sector_bytes]u8 = undefined;
    const honest = Cache{ .gpa = testing.allocator, .image = &image };
    try testing.expect(!honest.holds(false));
    try testing.expect(honest.holds(true));
    const liar = Cache{ .gpa = testing.allocator, .image = &image, .lies = true };
    try testing.expect(liar.holds(false));
}

test "the cache's line says which it was" {
    var image: [sector_bytes]u8 = undefined;
    var c = Cache{ .gpa = testing.allocator, .image = &image };
    var buf: [256]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, c.line(&buf, false), "write-through") != null);
    c.write_back = true;
    c.negotiated = true;
    c.lost = 3;
    try testing.expect(std.mem.indexOf(u8, c.line(&buf, true), "lost 3 sectors never flushed") != null);
}

test "VOLUME_CUT_AT_EXIT: at the run's end what was never flushed is lost, and the line says it was the end" {
    var image: [8 * sector_bytes]u8 = @splat('o');
    var c = Cache{ .gpa = testing.allocator, .image = &image };
    defer c.deinit();
    c.negotiated = true;
    try testing.expect(c.wrote(0, 1));
    @memset(image[0..sector_bytes], 'a');
    c.flush();
    try testing.expect(c.wrote(1, 2));
    @memset(image[sector_bytes .. 3 * sector_bytes], 'b');
    c.loseAtExit();
    try testing.expectEqual(@as(u8, 'a'), image[0]);
    try testing.expectEqual(@as(u8, 'o'), image[sector_bytes]);
    try testing.expectEqual(@as(u64, 2), c.exit_lost);
    var buf: [256]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, c.line(&buf, false), "the power failed when the guest stopped and lost 2 sectors never flushed") != null);
}
