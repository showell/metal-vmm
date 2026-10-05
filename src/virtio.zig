//! **THE OTHER HALF OF A PROTOCOL WE ALREADY WROTE.** gopher-metal drives
//! virtio-mmio from inside a guest; this answers it from outside. The register
//! offsets, the status bits and the ring layout below are the same numbers,
//! read from the opposite side — which is the whole reason this is a good way
//! into the layer.
//!
//! A device here is a window of registers at a physical address the guest
//! knows to look at, and one queue in guest memory that both sides walk: the
//! driver puts a chain of descriptors on the available ring and rings a
//! doorbell; the device does the work and puts the head back on the used ring.
//! **Nothing is copied through a port.** A descriptor names a guest physical
//! address, and since the guest's RAM is one mapping here, that address is an
//! offset into it.
//!
//! What this deliberately does NOT do: interrupts. The guest polls the used
//! ring, so a completion is visible the moment it is written. `interrupt_status`
//! is still kept, because the driver reads and acknowledges it, and a device
//! that never raises one would leave that code untested.

const std = @import("std");
const disk = @import("disk.zig");
const cache_mod = @import("cache.zig");
const faults = @import("faults.zig");

/// Where the guest looks: 32 slots of 512 bytes from 0xFEB00000, which is what
/// QEMU's `microvm` gives it and therefore what its driver scans.
pub const window_base: u64 = 0xFEB00000;
pub const slot_stride: u64 = 0x200;
pub const slots: usize = 32;

pub fn inWindow(addr: u64) bool {
    return addr >= window_base and addr < window_base + slots * slot_stride;
}

const magic_value: u32 = 0x74726976; // "virt"
const version: u32 = 2; // the modern interface; the guest refuses legacy
const vendor_id: u32 = 0x6D766D6D; // "mvmm"

pub const device_id_block: u32 = 2;
pub const device_id_net: u32 = 1;
pub const device_id_entropy: u32 = 4;

const Reg = enum(u64) {
    magic = 0x000,
    version = 0x004,
    device_id = 0x008,
    vendor_id = 0x00c,
    device_features = 0x010,
    device_features_sel = 0x014,
    driver_features = 0x020,
    driver_features_sel = 0x024,
    queue_sel = 0x030,
    queue_num_max = 0x034,
    queue_num = 0x038,
    queue_ready = 0x044,
    queue_notify = 0x050,
    interrupt_status = 0x060,
    interrupt_ack = 0x064,
    status = 0x070,
    queue_desc_lo = 0x080,
    queue_desc_hi = 0x084,
    queue_driver_lo = 0x090,
    queue_driver_hi = 0x094,
    queue_device_lo = 0x0a0,
    queue_device_hi = 0x0a4,
    config = 0x100,
    _,
};

/// **VIRTIO_F_VERSION_1, AND NOTHING ELSE.** It is bit 32, so it appears in
/// the high word — which is why the driver selects word 1 before reading. A
/// device that does not offer it is refused outright by this guest.
pub const feature_version_1_high: u32 = 1 << (32 - 32);
/// VIRTIO_BLK_F_FLUSH, offered only with a write cache (`DISK_CACHE`).
pub const feature_blk_flush: u32 = 1 << 9;

pub const status_features_ok: u32 = 8;

/// The most descriptors a queue here may have. The guest's block queue is 8;
/// answering a larger maximum is what lets it choose.
pub const queue_max: u32 = 256;

// ── the rings, as both sides see them ────────────────────────────────────────

pub const Desc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,

    pub const next_flag: u16 = 1;
    /// Set by the driver when the DEVICE writes this buffer.
    pub const write_flag: u16 = 2;
};

pub const UsedElem = extern struct { id: u32, len: u32 };

// ── one device on the transport ──────────────────────────────────────────────

/// One queue's state: what the driver told us about it, and how far along its
/// available ring this device has read.
pub const Queue = struct {
    size: u32 = 0,
    ready: u32 = 0,
    desc: u64 = 0,
    avail: u64 = 0,
    used: u64 = 0,
    last_avail: u16 = 0,

    /// Its size, if a ring can be that size here: one or more, and no more
    /// than this device offers (`queue_max`). A driver may write anything
    /// to the register; a size past the maximum is a queue nothing is
    /// taken from, not a number to trust.
    pub fn usableSize(self: *const Queue) ?u16 {
        if (self.size == 0 or self.size > queue_max) return null;
        return @intCast(self.size);
    }
};

/// A chain of descriptors the driver offered, and the head to answer with.
pub const Chain = struct { head: u16, links: []const Desc };

/// **THE DOORBELL RANG.** What a device does about it is its own business: a
/// block device serves every chain on the spot, while a network device's
/// receive queue holds the buffers until a frame turns up for them.
pub const Notified = *const fn (context: *anyopaque, device: *Device, ram: []u8, queue: u32) void;

pub const Completion = struct {
    context: *anyopaque,
    done: *const fn (context: *anyopaque, queue: u32) void,
};

const avail_no_interrupt: u16 = 1;

pub const Device = struct {
    id: u32,
    /// What this device offers in feature word 0. VERSION_1 lives in word 1
    /// and every device here offers it.
    features_low: u32 = 0,
    context: *anyopaque,
    notified: Notified,
    /// Read by the guest at offset 0x100 and up; a block device keeps its
    /// capacity here.
    config: [32]u8 = @splat(0),

    // What the driver has told us, and what we have told it.
    status: u32 = 0,
    device_features_sel: u32 = 0,
    driver_features_sel: u32 = 0,
    /// What the driver took of feature word 0: a write cache asks whether
    /// FLUSH was among it.
    driver_features_low: u32 = 0,
    interrupt_status: u32 = 0,

    queue_sel: u32 = 0,
    /// Two is enough for both devices here: a block device's one, and a
    /// network device's receive and transmit.
    queues: [2]Queue = .{ .{}, .{} },
    /// How many of them this kind of device serves: what virtio-pci's
    /// `num_queues` says, and past which a queue reads as absent.
    queue_count: u32 = 2,

    /// How many requests it has served, for a host that wants to say what a
    /// guest actually asked of it.
    served: u64 = 0,
    /// **WHO HEARS THAT A REQUEST IS DONE**: on PCI, the function whose MSI-X
    /// message it may become (pci.zig). Not told when the driver asked for
    /// no interrupts on that queue (VIRTQ_AVAIL_F_NO_INTERRUPT). Null on mmio,
    /// where the guest only polls.
    completion: ?Completion = null,
    /// **WHETHER THE DEVICE MAY TOUCH THE GUEST'S MEMORY AT ALL.** On PCI,
    /// the function's bus-master bit (pci.zig); until it is set, nothing is
    /// taken from a queue, so a frame waits on the wire and a request waits
    /// for the next doorbell. Always so on mmio.
    may_dma: bool = true,

    pub fn read(self: *Device, offset: u64, len: u32) u64 {
        if (offset >= @intFromEnum(Reg.config)) {
            const at: usize = @intCast(offset - @intFromEnum(Reg.config));
            // Past the end of what this device keeps there is nothing, which
            // reads as zero, as the rest of the window does.
            if (at >= self.config.len) return 0;
            var value: u64 = 0;
            for (0..@min(len, 8, self.config.len - at)) |i| {
                value |= @as(u64, self.config[at + i]) << @intCast(i * 8);
            }
            return value;
        }
        return switch (@as(Reg, @enumFromInt(offset))) {
            .magic => magic_value,
            .version => version,
            .device_id => self.id,
            .vendor_id => vendor_id,
            .device_features => if (self.device_features_sel == 1) feature_version_1_high else self.features_low,
            .queue_num_max => queue_max,
            .queue_ready => self.queues[self.pick()].ready,
            // **THE DRIVER READS THIS BACK TO SEE IF IT WAS ACCEPTED**, so a
            // device that only stored it would look like one that refused.
            .status => self.status,
            .interrupt_status => self.interrupt_status,
            else => 0,
        };
    }

    pub fn write(self: *Device, ram: []u8, offset: u64, value: u32) void {
        switch (@as(Reg, @enumFromInt(offset))) {
            .device_features_sel => self.device_features_sel = value,
            .driver_features_sel => self.driver_features_sel = value,
            // Whatever it takes, it may have; word 0 is kept.
            .driver_features => if (self.driver_features_sel == 0) {
                self.driver_features_low = value;
            },
            .queue_sel => self.queue_sel = value,
            .queue_num => self.queues[self.pick()].size = value,
            .queue_desc_lo => self.setLow(&self.queues[self.pick()].desc, value),
            .queue_desc_hi => self.setHigh(&self.queues[self.pick()].desc, value),
            .queue_driver_lo => self.setLow(&self.queues[self.pick()].avail, value),
            .queue_driver_hi => self.setHigh(&self.queues[self.pick()].avail, value),
            .queue_device_lo => self.setLow(&self.queues[self.pick()].used, value),
            .queue_device_hi => self.setHigh(&self.queues[self.pick()].used, value),
            .queue_ready => self.queues[self.pick()].ready = value,
            .queue_notify => {
                if (value < self.queues.len) self.notified(self.context, self, ram, value);
                // The driver polls the used ring, but it also reads and
                // acknowledges this — so a device that never set it would
                // leave that path dead.
                self.interrupt_status |= 1;
            },
            .interrupt_ack => self.interrupt_status &= ~value,
            .status => {
                // A write of zero is a reset, and the driver starts over.
                if (value == 0) {
                    self.status = 0;
                    self.queues = .{ .{}, .{} };
                } else {
                    // FEATURES_OK is the device's to grant. We take the only
                    // feature this guest asks for, so it is always granted.
                    self.status = value | (value & status_features_ok);
                }
            },
            else => {},
        }
    }

    /// A queue index the driver asked for, clamped to what exists.
    fn pick(self: *const Device) usize {
        return @min(self.queue_sel, self.queues.len - 1);
    }

    fn setLow(_: *Device, field: *u64, value: u32) void {
        field.* = (field.* & 0xFFFFFFFF00000000) | value;
    }

    fn setHigh(_: *Device, field: *u64, value: u32) void {
        field.* = (field.* & 0xFFFFFFFF) | (@as(u64, value) << 32);
    }

    /// **THE NEXT CHAIN THE DRIVER OFFERED**, or null when it has offered
    /// nothing new. Reading it does not answer it: a device may hold a buffer
    /// for as long as it likes, which is exactly what a receive queue is for.
    pub fn take(self: *Device, ram: []u8, index: u32, into: []Desc) ?Chain {
        const q = &self.queues[index];
        if (!self.may_dma or q.ready == 0) return null;
        const size = q.usableSize() orelse return null;
        const avail_idx = readInt(u16, ram, q.avail +| 2);
        if (q.last_avail == avail_idx) return null;
        // **NEVER MORE OFFERED THAN THE RING HOLDS** (virtio 1.2 §2.7.13): an
        // index further ahead than that is a ring this device cannot trust,
        // and walking it would be up to 65,535 chains for one doorbell.
        if (avail_idx -% q.last_avail > size) return null;
        const head = readInt(u16, ram, q.avail +| (4 + @as(u64, q.last_avail % size) * 2));
        q.last_avail +%= 1;
        return .{ .head = head, .links = follow(ram, q.desc, head, into) };
    }

    /// **HOW MANY CHAINS ONE DOORBELL MAY SERVE**: the ring's size, which is
    /// all a driver can have offered at once. A device that served "until
    /// nothing is left" would never stop for a driver whose used ring lies
    /// over its available ring, where every completion offers one more.
    pub fn budget(self: *const Device, index: u32) u32 {
        return self.queues[index].usableSize() orelse 0;
    }

    /// Puts the head back on the used ring with what the device wrote, which
    /// is how the driver learns the buffer is its own again.
    pub fn complete(self: *Device, ram: []u8, index: u32, head: u16, written: u32) void {
        const q = &self.queues[index];
        const size = q.usableSize() orelse return;
        const used_idx = readInt(u16, ram, q.used +| 2);
        const at = q.used +| (4 + @as(u64, used_idx % size) * @sizeOf(UsedElem));
        writeInt(u32, ram, at, head);
        writeInt(u32, ram, at +| 4, written);
        writeInt(u16, ram, q.used +| 2, used_idx +% 1);
        self.served += 1;
        if (self.completion) |c| {
            if (readInt(u16, ram, q.avail) & avail_no_interrupt == 0) c.done(c.context, index);
        }
    }
};

/// Reads a descriptor chain out of guest memory. A chain longer than `into`
/// is cut short rather than followed forever: the driver writes the `next`
/// links, and a loop in them is its bug, not a reason for this to hang.
fn follow(ram: []u8, table: u64, head: u16, into: []Desc) []const Desc {
    var at = head;
    var n: usize = 0;
    while (n < into.len) {
        const desc_at = table +| @as(u64, at) * @sizeOf(Desc);
        if (!inside(ram, desc_at, @sizeOf(Desc))) break;
        into[n] = .{
            .addr = readInt(u64, ram, desc_at),
            .len = readInt(u32, ram, desc_at + 8),
            .flags = readInt(u16, ram, desc_at + 12),
            .next = readInt(u16, ram, desc_at + 14),
        };
        n += 1;
        if (into[n - 1].flags & Desc.next_flag == 0) break;
        at = into[n - 1].next;
    }
    return into[0..n];
}

// ── guest memory, which is just our own with an offset ───────────────────────

/// **WHETHER `len` BYTES AT `at` ARE ALL GUEST MEMORY.** Every address here
/// is the guest's to choose, up to 2^64 - 1, so the test subtracts rather
/// than adds: `at + len` could wrap past the top and land back inside.
/// Addresses built from a guest's base and an offset add with saturation
/// (`+|`) for the same reason, so they land at the top, outside, instead.
pub fn inside(ram: []const u8, at: u64, len: u64) bool {
    return at <= ram.len and len <= ram.len - at;
}

pub fn readInt(comptime T: type, ram: []const u8, at: u64) T {
    if (!inside(ram, at, @sizeOf(T))) return 0;
    const i: usize = @intCast(at);
    return std.mem.readInt(T, ram[i..][0..@sizeOf(T)], .little);
}

pub fn writeInt(comptime T: type, ram: []u8, at: u64, value: T) void {
    if (!inside(ram, at, @sizeOf(T))) return;
    const i: usize = @intCast(at);
    std.mem.writeInt(T, ram[i..][0..@sizeOf(T)], value, .little);
}

/// The bytes a descriptor names, as a slice of the guest's own memory; none
/// when any of them is not.
pub fn buffer(ram: []u8, desc: Desc) []u8 {
    if (!inside(ram, desc.addr, desc.len)) return ram[0..0];
    const at: usize = @intCast(desc.addr);
    return ram[at..][0..desc.len];
}

// ── the block device ─────────────────────────────────────────────────────────

pub const Block = struct {
    /// The image, mapped: a write by the guest is a write to the file, which
    /// is what QEMU does unless told otherwise. A caller that wants the image
    /// untouched copies it first.
    image: []u8,
    /// One bit per sector, if anybody is keeping that record — see disk.zig.
    /// The device does not know or care what it is for.
    dirty: ?[]u8 = null,
    /// **AND THE REQUESTS IT WILL NOT SERVE** — see faults.zig. Left alone it
    /// serves every one of them.
    refusals: faults.Drive = .{},
    /// **A WRITE CACHE** (`DISK_CACHE`, cache.zig), or none: every write is
    /// durable when it is acknowledged, as it always was.
    cache: ?*cache_mod.Cache = null,
    /// Every request, written out as it happens, for a caller asking where a
    /// guest's disk traffic actually goes. Off unless somebody asks.
    trace: bool = false,
    reads: u64 = 0,
    writes: u64 = 0,

    const sector_bytes: u64 = 512;

    const type_in: u32 = 0; // the guest reads
    const type_out: u32 = 1; // the guest writes
    const type_flush: u32 = 4; // what was written is to be kept

    const status_ok: u8 = 0;
    const status_ioerr: u8 = 1;
    const status_unsupported: u8 = 2;

    const Header = extern struct {
        type: u32,
        reserved: u32,
        sector: u64,
    };

    pub fn device(self: *Block) Device {
        var d = Device{ .id = device_id_block, .context = self, .notified = notified, .queue_count = 1 };
        // Config space: the capacity in sectors, at offset 0.
        std.mem.writeInt(u64, d.config[0..8], self.image.len / sector_bytes, .little);
        return d;
    }

    /// Every request waiting, served on the spot. A disk is fast enough here
    /// that there is nothing to be gained by holding one.
    fn notified(context: *anyopaque, d: *Device, ram: []u8, queue: u32) void {
        const self: *Block = @ptrCast(@alignCast(context));
        var links: [4]Desc = undefined;
        var left = d.budget(queue);
        while (left > 0) : (left -= 1) {
            // **NO POWER, NO DISK**: nothing more is taken, and the request
            // the power was cut in is never answered.
            if (self.refusals.cut != null) return;
            const chain = d.take(ram, queue, &links) orelse break;
            // A cache holds writes only if the driver negotiated FLUSH, or
            // the disk lies (virtio 1.1 §5.2.5.1).
            const negotiated = d.driver_features_low & feature_blk_flush != 0;
            const hold = if (self.cache) |c| blk: {
                c.negotiated = negotiated;
                break :blk c.holds(negotiated);
            } else false;
            const answer = self.serve(ram, chain.links, hold);
            if (self.refusals.cut != null) return;
            d.complete(ram, queue, chain.head, answer);
        }
    }

    /// **THE SPEC'S THREE DESCRIPTORS**: a header the device reads, a data
    /// buffer, and a status byte the device writes. Anything else is refused
    /// rather than guessed at.
    fn serve(self: *Block, ram: []u8, chain: []const Desc, hold: bool) u32 {
        // **A FLUSH HAS NO DATA**: a header and a status byte.
        if (chain.len == 2) return self.flushRequest(ram, chain[0], chain[1]);
        if (chain.len != 3) return 0;
        const head = chain[0];
        const data = chain[1];
        const status = chain[2];
        if (head.len < @sizeOf(Header) or status.len < 1) return 0;
        // A header the device cannot read is no request at all: zeros read
        // from nowhere would spell "read sector 0".
        if (!inside(ram, head.addr, @sizeOf(Header))) {
            writeInt(u8, ram, status.addr, status_ioerr);
            return 1;
        }

        // **A REFUSED REQUEST TOUCHES NOTHING**: no bytes move, no sector is
        // marked, and the guest gets the one thing a real disk gives it when
        // it cannot do the work.
        const asked = (buffer(ram, data).len + sector_bytes - 1) / sector_bytes;
        if (!self.refusals.serves(readInt(u64, ram, head.addr +| 8), asked, readInt(u32, ram, head.addr) == type_out)) {
            writeInt(u8, ram, status.addr, status_ioerr);
            return 1;
        }

        const kind = readInt(u32, ram, head.addr);
        const sector = readInt(u64, ram, head.addr +| 8);
        if (self.trace) {
            var line: [64]u8 = undefined;
            const text = std.fmt.bufPrint(&line, "{s} {d} {d}\n", .{
                if (kind == type_out) "w" else "r", sector, buffer(ram, data).len / sector_bytes,
            }) catch "";
            _ = std.os.linux.write(2, text.ptr, text.len);
        }
        // A sector the guest names may be anything: one past the image, by
        // however much, is an error, never an address computed by wrapping.
        const at = std.math.mul(u64, sector, sector_bytes) catch std.math.maxInt(u64);
        const bytes = buffer(ram, data);

        var answer: u8 = status_ok;
        var written: u32 = 0;
        if (!inside(self.image, at, bytes.len) or bytes.len == 0) {
            answer = status_ioerr;
        } else switch (kind) {
            type_in => {
                @memcpy(bytes, self.image[@intCast(at)..][0..bytes.len]);
                self.refusals.rotInto(sector, bytes);
                written = @intCast(bytes.len);
                self.reads += 1;
            },
            type_out => {
                // As much as lands before the power goes, which is all of it
                // unless this is the write it goes in.
                const sectors = (bytes.len + sector_bytes - 1) / sector_bytes;
                const landed = @min(bytes.len, self.refusals.lands(sector, sectors) * sector_bytes);
                if (hold) _ = self.cache.?.wrote(sector, (landed + sector_bytes - 1) / sector_bytes);
                @memcpy(self.image[@intCast(at)..][0..landed], bytes[0..landed]);
                self.refusals.rewrote(sector, (landed + sector_bytes - 1) / sector_bytes);
                if (self.dirty) |bits| disk.mark(bits, sector, (landed + sector_bytes - 1) / sector_bytes);
                self.writes += 1;
            },
            type_flush => answer = self.flush(),
            else => answer = status_unsupported,
        }
        writeInt(u8, ram, status.addr, answer);
        // The used ring's length counts everything the device wrote, which
        // includes the status byte.
        return written + 1;
    }

    /// A flush in its two descriptors: anything but a flush there is
    /// refused, as any other chain of the wrong shape is.
    fn flushRequest(self: *Block, ram: []u8, head: Desc, status: Desc) u32 {
        if (head.len < @sizeOf(Header) or status.len < 1) return 0;
        if (!inside(ram, head.addr, @sizeOf(Header))) {
            writeInt(u8, ram, status.addr, status_ioerr);
            return 1;
        }
        const kind = readInt(u32, ram, head.addr);
        writeInt(u8, ram, status.addr, if (kind == type_flush) self.flush() else status_unsupported);
        return 1;
    }

    /// **WHAT WAS WRITTEN IS KEPT**: unsupported where FLUSH was never
    /// offered, as before.
    fn flush(self: *Block) u8 {
        const c = self.cache orelse return status_unsupported;
        c.flush();
        return status_ok;
    }
};

// ── what can be checked without a guest ──────────────────────────────────────

const testing = std.testing;

test "an empty slot is empty, and the device's slot says what it is" {
    var image = [_]u8{0} ** 1024;
    var blk = Block{ .image = &image };
    var d = blk.device();
    try testing.expectEqual(@as(u64, magic_value), d.read(0x000, 4));
    try testing.expectEqual(@as(u64, 2), d.read(0x004, 4));
    try testing.expectEqual(@as(u64, device_id_block), d.read(0x008, 4));
    // The capacity, in sectors, read as the guest reads it: two 32-bit halves.
    try testing.expectEqual(@as(u64, 2), d.read(0x100, 4));
    try testing.expectEqual(@as(u64, 0), d.read(0x104, 4));
}

test "the feature the guest insists on is in the high word, and only there" {
    var image = [_]u8{0} ** 512;
    var blk = Block{ .image = &image };
    var d = blk.device();
    var ram = [_]u8{0} ** 64;
    d.write(&ram, 0x014, 1); // select the high word
    try testing.expectEqual(@as(u64, 1), d.read(0x010, 4)); // VERSION_1
    d.write(&ram, 0x014, 0);
    try testing.expectEqual(@as(u64, 0), d.read(0x010, 4));
}

test "FEATURES_OK reads back, because the driver checks whether it was granted" {
    var image = [_]u8{0} ** 512;
    var blk = Block{ .image = &image };
    var d = blk.device();
    var ram = [_]u8{0} ** 64;
    d.write(&ram, 0x070, 1 | 2 | status_features_ok);
    try testing.expect(d.read(0x070, 4) & status_features_ok != 0);
    d.write(&ram, 0x070, 0); // a reset starts the driver over
    try testing.expectEqual(@as(u64, 0), d.read(0x070, 4));
}

/// A guest's memory with one queue in it, laid out the way gopher-metal's
/// `Ring(8)` lays it out, so the test drives the device the way the driver does.
const FakeGuest = struct {
    ram: [8192]u8 = @splat(0),

    const size: u16 = 8;
    const desc_at: u64 = 0x100;
    const avail_at: u64 = desc_at + size * @sizeOf(Desc);
    const used_at: u64 = avail_at + 4 + size * 2 + 2;
    const header_at: u64 = 0x800;
    const data_at: u64 = 0x1000;
    const status_at: u64 = 0x900;

    fn open(self: *FakeGuest, d: *Device) void {
        d.write(&self.ram, 0x038, size); // queue_num
        d.write(&self.ram, 0x080, desc_at);
        d.write(&self.ram, 0x090, avail_at);
        d.write(&self.ram, 0x0a0, used_at);
        d.write(&self.ram, 0x044, 1); // queue_ready
    }

    /// Builds the three-descriptor chain and rings the doorbell.
    fn ask(self: *FakeGuest, d: *Device, kind: u32, sector: u64, len: u32) u8 {
        writeInt(u32, &self.ram, header_at, kind);
        writeInt(u64, &self.ram, header_at + 8, sector);
        writeInt(u8, &self.ram, status_at, 0xFF);

        const desc = [_]Desc{
            .{ .addr = header_at, .len = 16, .flags = Desc.next_flag, .next = 1 },
            .{ .addr = data_at, .len = len, .flags = Desc.next_flag | (if (kind == 0) Desc.write_flag else 0), .next = 2 },
            .{ .addr = status_at, .len = 1, .flags = Desc.write_flag, .next = 0 },
        };
        for (desc, 0..) |one, i| {
            const at = desc_at + i * @sizeOf(Desc);
            writeInt(u64, &self.ram, at, one.addr);
            writeInt(u32, &self.ram, at + 8, one.len);
            writeInt(u16, &self.ram, at + 12, one.flags);
            writeInt(u16, &self.ram, at + 14, one.next);
        }
        const avail_idx = readInt(u16, &self.ram, avail_at + 2);
        writeInt(u16, &self.ram, avail_at + 4 + @as(u64, avail_idx % size) * 2, 0); // head
        writeInt(u16, &self.ram, avail_at + 2, avail_idx + 1);
        d.write(&self.ram, 0x050, 0); // the doorbell
        return readInt(u8, &self.ram, status_at);
    }
};

test "a sector asked for is the sector that arrives" {
    var image = [_]u8{0} ** (512 * 4);
    for (image[512 * 2 ..][0..512], 0..) |*b, i| b.* = @truncate(i);
    var blk = Block{ .image = &image };
    var d = blk.device();
    var guest = FakeGuest{};
    guest.open(&d);

    try testing.expectEqual(Block.status_ok, guest.ask(&d, 0, 2, 512));
    try testing.expectEqualSlices(u8, image[512 * 2 ..][0..512], guest.ram[FakeGuest.data_at..][0..512]);
    try testing.expectEqual(@as(u64, 1), blk.reads);
    // And the head came back on the used ring, with what was written.
    try testing.expectEqual(@as(u16, 1), readInt(u16, &guest.ram, FakeGuest.used_at + 2));
    try testing.expectEqual(@as(u32, 513), readInt(u32, &guest.ram, FakeGuest.used_at + 8));
}

test "a sector written is a sector that can be read back" {
    var image = [_]u8{0} ** (512 * 4);
    var blk = Block{ .image = &image };
    var d = blk.device();
    var guest = FakeGuest{};
    guest.open(&d);

    for (guest.ram[FakeGuest.data_at..][0..512], 0..) |*b, i| b.* = @truncate(i * 3);
    try testing.expectEqual(Block.status_ok, guest.ask(&d, 1, 1, 512));
    try testing.expectEqualSlices(u8, guest.ram[FakeGuest.data_at..][0..512], image[512..][0..512]);
    try testing.expectEqual(@as(u64, 1), blk.writes);
}

test "several sectors in one request, which is what a run of clusters costs" {
    var image = [_]u8{0} ** (512 * 8);
    for (image[512 * 3 ..][0 .. 512 * 2], 0..) |*b, i| b.* = @truncate(i / 7);
    var blk = Block{ .image = &image };
    var d = blk.device();
    var guest = FakeGuest{};
    guest.open(&d);

    try testing.expectEqual(Block.status_ok, guest.ask(&d, 0, 3, 512 * 2));
    try testing.expectEqualSlices(u8, image[512 * 3 ..][0 .. 512 * 2], guest.ram[FakeGuest.data_at..][0 .. 512 * 2]);
    try testing.expectEqual(@as(u64, 1), blk.reads); // ONE request, not two
}

test "a sector past the end of the image is an error, not a read of something else" {
    var image = [_]u8{0} ** 512;
    var blk = Block{ .image = &image };
    var d = blk.device();
    var guest = FakeGuest{};
    guest.open(&d);
    try testing.expectEqual(Block.status_ioerr, guest.ask(&d, 0, 99, 512));
    try testing.expectEqual(@as(u64, 0), blk.reads);
}

test "a kind of request this device does not know is refused by name" {
    var image = [_]u8{0} ** 512;
    var blk = Block{ .image = &image };
    var d = blk.device();
    var guest = FakeGuest{};
    guest.open(&d);
    try testing.expectEqual(Block.status_unsupported, guest.ask(&d, 4, 0, 512));
}

test "nothing happens until the queue is ready" {
    // A doorbell before the driver has finished setting up must not walk a
    // ring that is not there yet.
    var image = [_]u8{0} ** 512;
    var blk = Block{ .image = &image };
    var d = blk.device();
    var guest = FakeGuest{};
    d.write(&guest.ram, 0x050, 0);
    try testing.expectEqual(@as(u64, 0), d.served);
}

test "a used ring laid over the available ring does not keep a doorbell busy forever" {
    // Found by fuzz.zig, seed 4939: each completion wrote the used index
    // where the available index is, offering one more chain, and the device
    // served "until nothing was left" without end.
    var context: u8 = 0;
    var d = Device{ .id = device_id_entropy, .context = &context, .notified = struct {
        fn serve(_: *anyopaque, dev: *Device, ram: []u8, queue: u32) void {
            var links: [4]Desc = undefined;
            var left = dev.budget(queue);
            while (left > 0) : (left -= 1) {
                const chain = dev.take(ram, queue, &links) orelse break;
                dev.complete(ram, queue, chain.head, 0);
            }
        }
    }.serve };
    var ram: [4096]u8 = @splat(0);
    d.queues[0] = .{ .size = 8, .ready = 1, .desc = 0x100, .avail = 0x200, .used = 0x200 };
    writeInt(u16, &ram, 0x202, 1);
    d.notified(d.context, &d, &ram, 0);
    try testing.expect(d.served <= 8);
}

test "a block request with a sector or an address at the top of the range is an error, not a wrap" {
    var image: [8 * 512]u8 = @splat(0);
    var block = Block{ .image = &image };
    var ram: [4096]u8 = @splat(0);
    const links = [_]Desc{
        .{ .addr = 0x400, .len = 16, .flags = Desc.next_flag, .next = 1 },
        .{ .addr = 0x800, .len = 512, .flags = Desc.next_flag | Desc.write_flag, .next = 2 },
        .{ .addr = 0x600, .len = 1, .flags = Desc.write_flag, .next = 0 },
    };
    writeInt(u32, &ram, 0x400, Block.type_in);
    // A sector whose byte offset is past 2^64: refused, not wrapped to 0.
    writeInt(u64, &ram, 0x408, std.math.maxInt(u64) / 256);
    _ = block.serve(&ram, &links, false);
    try testing.expectEqual(Block.status_ioerr, readInt(u8, &ram, 0x600));
    // A header at the very top of the address space reads as nothing.
    var high = links;
    high[0].addr = std.math.maxInt(u64) - 4;
    writeInt(u8, &ram, 0x600, 0xFF);
    _ = block.serve(&ram, &high, false);
    try testing.expectEqual(@as(u64, 0), block.reads);
    try testing.expectEqual(Block.status_ioerr, readInt(u8, &ram, 0x600));
}

test "a power cut: the write it comes after lands, nothing after it does, and nothing is answered" {
    var image: [16 * 512]u8 = @splat(0);
    var dirty: [2]u8 = @splat(0);
    var block = Block{ .image = &image, .dirty = &dirty };
    block.refusals.cut_after = 1;
    var d = block.device();
    var ram: [8192]u8 = @splat(0);
    d.queues[0] = .{ .size = 8, .ready = 1, .desc = 0x100, .avail = 0x200, .used = 0x300 };
    // Two writes offered at once: sector 2 from 0x1000, then sector 5 from 0x1200.
    for (0..2) |r| {
        const base = 0x100 + r * 3 * @sizeOf(Desc);
        const header: u64 = 0x400 + r * 0x20;
        const links = [_]Desc{
            .{ .addr = header, .len = 16, .flags = Desc.next_flag, .next = @intCast(r * 3 + 1) },
            .{ .addr = 0x1000 + r * 0x200, .len = 512, .flags = Desc.next_flag, .next = @intCast(r * 3 + 2) },
            .{ .addr = 0x600 + r, .len = 1, .flags = Desc.write_flag, .next = 0 },
        };
        for (links, 0..) |l, i| {
            const at = base + i * @sizeOf(Desc);
            writeInt(u64, &ram, at, l.addr);
            writeInt(u32, &ram, at + 8, l.len);
            writeInt(u16, &ram, at + 12, l.flags);
            writeInt(u16, &ram, at + 14, l.next);
        }
        writeInt(u32, &ram, header, Block.type_out);
        writeInt(u64, &ram, header + 8, if (r == 0) 2 else 5);
        writeInt(u16, &ram, 0x204 + r * 2, @intCast(r * 3));
        @memset(ram[0x1000 + r * 0x200 ..][0..512], @intCast(0xA0 + r));
    }
    writeInt(u16, &ram, 0x202, 2);
    d.notified(d.context, &d, &ram, 0);
    try testing.expectEqual(@as(u8, 0xA0), image[2 * 512]); // the first landed
    try testing.expectEqual(@as(u8, 0), image[5 * 512]); // the second did not
    try testing.expect(disk.isDirty(&dirty, 2) and !disk.isDirty(&dirty, 5));
    try testing.expectEqual(@as(u16, 0), readInt(u16, &ram, 0x302)); // nothing answered
    // And a doorbell after the cut takes nothing.
    d.notified(d.context, &d, &ram, 0);
    try testing.expectEqual(@as(u8, 0), image[5 * 512]);
}

test "a torn write lands only its first sectors, and marks only those" {
    var image: [16 * 512]u8 = @splat(0);
    var dirty: [2]u8 = @splat(0);
    var block = Block{ .image = &image, .dirty = &dirty };
    block.refusals.tear = 1;
    block.refusals.tear_keep = 2;
    var ram: [8192]u8 = @splat(0);
    @memset(ram[0x1000..][0 .. 4 * 512], 0xEE);
    writeInt(u32, &ram, 0x400, Block.type_out);
    writeInt(u64, &ram, 0x408, 3);
    const links = [_]Desc{
        .{ .addr = 0x400, .len = 16, .flags = Desc.next_flag, .next = 1 },
        .{ .addr = 0x1000, .len = 4 * 512, .flags = Desc.next_flag, .next = 2 },
        .{ .addr = 0x600, .len = 1, .flags = Desc.write_flag, .next = 0 },
    };
    _ = block.serve(&ram, &links, false);
    try testing.expectEqual(@as(u8, 0xEE), image[3 * 512]);
    try testing.expectEqual(@as(u8, 0xEE), image[5 * 512 - 1]);
    try testing.expectEqual(@as(u8, 0), image[5 * 512]); // the third of four: not landed
    try testing.expect(disk.isDirty(&dirty, 4) and !disk.isDirty(&dirty, 5));
    try testing.expectEqual(@as(u64, 2), block.refusals.cut.?.landed);
}

test "a write cache: held while FLUSH is negotiated, kept by a flush, lost by a power cut" {
    var image: [16 * 512]u8 = @splat(0);
    var c = cache_mod.Cache{ .gpa = testing.allocator, .image = &image };
    defer c.deinit();
    var block = Block{ .image = &image, .cache = &c };
    var ram: [8192]u8 = @splat(0);
    const write = struct {
        fn f(b: *Block, r: *[8192]u8, sector: u64, fill: u8, hold: bool) u8 {
            @memset(r[0x1000..][0..512], fill);
            writeInt(u32, r, 0x400, Block.type_out);
            writeInt(u64, r, 0x408, sector);
            const links = [_]Desc{
                .{ .addr = 0x400, .len = 16, .flags = Desc.next_flag, .next = 1 },
                .{ .addr = 0x1000, .len = 512, .flags = Desc.next_flag, .next = 2 },
                .{ .addr = 0x600, .len = 1, .flags = Desc.write_flag, .next = 0 },
            };
            _ = b.serve(r, &links, hold);
            return readInt(u8, r, 0x600);
        }
    }.f;
    const flush = [_]Desc{
        .{ .addr = 0x400, .len = 16, .flags = Desc.next_flag, .next = 1 },
        .{ .addr = 0x600, .len = 1, .flags = Desc.write_flag, .next = 0 },
    };
    try testing.expectEqual(Block.status_ok, write(&block, &ram, 2, 0xAA, true));
    writeInt(u32, &ram, 0x400, Block.type_flush);
    try testing.expectEqual(@as(u32, 1), block.serve(&ram, &flush, true));
    try testing.expectEqual(Block.status_ok, readInt(u8, &ram, 0x600));
    try testing.expectEqual(Block.status_ok, write(&block, &ram, 3, 0xBB, true));
    try testing.expectEqual(@as(u8, 0xBB), image[3 * 512]); // its reads see it
    c.lose();
    try testing.expectEqual(@as(u8, 0xAA), image[2 * 512]); // flushed: kept
    try testing.expectEqual(@as(u8, 0), image[3 * 512]); // not: lost
    // Write-through (FLUSH not negotiated): nothing held, nothing lost.
    try testing.expectEqual(Block.status_ok, write(&block, &ram, 4, 0xCC, false));
    c.lose();
    try testing.expectEqual(@as(u8, 0xCC), image[4 * 512]);
    // With no cache, FLUSH was never offered, and is refused as before.
    var plain = Block{ .image = &image };
    try testing.expectEqual(@as(u32, 0), plain.device().features_low & feature_blk_flush);
    writeInt(u32, &ram, 0x400, Block.type_flush);
    _ = plain.serve(&ram, &flush, false);
    try testing.expectEqual(Block.status_unsupported, readInt(u8, &ram, 0x600));
}

test "the driver's feature word 0 is kept, on mmio" {
    var image: [512]u8 = @splat(0);
    var block = Block{ .image = &image };
    var d = block.device();
    var ram: [64]u8 = @splat(0);
    d.write(&ram, 0x024, 1);
    d.write(&ram, 0x020, 1); // word 1: not word 0
    d.write(&ram, 0x024, 0);
    d.write(&ram, 0x020, feature_blk_flush);
    try testing.expectEqual(feature_blk_flush, d.driver_features_low);
}
