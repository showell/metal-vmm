//! **THE DISK IS A FILE UNTIL THE MACHINE STARTS, AND THEN IT IS NOT.**
//!
//! The image is mapped private, so the guest's writes land in memory this
//! program owns and the file keeps the bytes it had. A run therefore reads
//! only what the image held when it began — not what the run before it left
//! behind, and not what a half-finished run left behind either. That is what
//! makes "the same guest twice" mean anything once a guest writes.
//!
//! What it changed is written down as it goes: one bit per sector. At the end
//! of a run those sectors, and only those, are written back to the file, which
//! is what keeps `check.sh` able to compare the disk QEMU left with the disk we
//! left. **A run that crashes writes nothing.**
//!
//! The bitmap is also the first half of replay. A machine that can say which
//! sectors a run touched can be asked to fail the fifth write instead of
//! serving it, which is where this is going.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

pub const sector_bytes: u64 = 512;

pub const Disk = struct {
    path: [*:0]const u8,
    /// The image and the guest's changes to it, in memory.
    bytes: []u8,
    /// One bit per sector. Borrowed by the block device, which sets a bit
    /// whenever it serves a write.
    dirty: []u8,

    pub const Error = error{ CannotOpen, CannotSize, OutOfMemory };

    pub fn open(path: [*:0]const u8) !Disk {
        const opened = linux.open(path, .{ .ACCMODE = .RDWR }, 0);
        if (linux.errno(opened) != .SUCCESS) return error.CannotOpen;
        const fd: linux.fd_t = @intCast(opened);
        defer _ = linux.close(fd);
        const size = linux.lseek(fd, 0, linux.SEEK.END);
        if (linux.errno(size) != .SUCCESS or size == 0) return error.CannotSize;

        // **PRIVATE, NOT SHARED.** One flag, and it is the whole point of this
        // file: with SHARED the guest's writes go straight into the image and
        // a run is no longer repeatable from it.
        const bytes = try posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE }, fd, 0);
        const sectors = (size + sector_bytes - 1) / sector_bytes;
        const bits = try posix.mmap(null, (sectors + 7) / 8, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        return .{ .path = path, .bytes = bytes, .dirty = bits };
    }

    /// Everything the run changed, back into the file, in one pass at the end.
    /// Answers how many sectors that was.
    pub fn writeBack(self: *const Disk) !usize {
        if (count(self.dirty) == 0) return 0;
        const opened = linux.open(self.path, .{ .ACCMODE = .WRONLY }, 0);
        if (linux.errno(opened) != .SUCCESS) return error.CannotOpen;
        const fd: linux.fd_t = @intCast(opened);
        defer _ = linux.close(fd);

        var written: usize = 0;
        var sector: u64 = 0;
        while (sector * sector_bytes < self.bytes.len) : (sector += 1) {
            if (!isDirty(self.dirty, sector)) continue;
            const at: usize = @intCast(sector * sector_bytes);
            const len = @min(sector_bytes, self.bytes.len - at);
            const rc = linux.pwrite(fd, self.bytes[at..].ptr, @intCast(len), @intCast(at));
            if (linux.errno(rc) != .SUCCESS) return error.CannotWrite;
            written += 1;
        }
        return written;
    }
};

pub fn mark(dirty: []u8, sector: u64, sectors: u64) void {
    var i: u64 = 0;
    while (i < sectors) : (i += 1) {
        const at = sector + i;
        const byte: usize = @intCast(at / 8);
        if (byte >= dirty.len) return;
        dirty[byte] |= @as(u8, 1) << @intCast(at % 8);
    }
}

pub fn isDirty(dirty: []const u8, sector: u64) bool {
    const byte: usize = @intCast(sector / 8);
    if (byte >= dirty.len) return false;
    return dirty[byte] & (@as(u8, 1) << @intCast(sector % 8)) != 0;
}

pub fn count(dirty: []const u8) usize {
    var n: usize = 0;
    for (dirty) |b| n += @popCount(b);
    return n;
}

// ── what can be checked without a guest ──────────────────────────────────────

const testing = std.testing;

test "a written sector is remembered, and its neighbours are not" {
    var dirty: [4]u8 = @splat(0);
    mark(&dirty, 9, 2); // sectors 9 and 10
    try testing.expect(!isDirty(&dirty, 8));
    try testing.expect(isDirty(&dirty, 9));
    try testing.expect(isDirty(&dirty, 10));
    try testing.expect(!isDirty(&dirty, 11));
    try testing.expectEqual(@as(usize, 2), count(&dirty));
    // Marking the same sector twice is still one sector.
    mark(&dirty, 9, 1);
    try testing.expectEqual(@as(usize, 2), count(&dirty));
}

test "a sector past the end of the record is dropped, not written elsewhere" {
    var dirty: [1]u8 = @splat(0);
    mark(&dirty, 7, 4); // 7 fits; 8, 9 and 10 do not
    try testing.expectEqual(@as(usize, 1), count(&dirty));
    try testing.expect(isDirty(&dirty, 7));
}
