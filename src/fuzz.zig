//! **THE GUEST'S INPUT NEVER KILLS THE VMM.** A fuzzer over every model a
//! guest can reach, without a vCPU: a seeded stream of what a guest could do,
//! applied to the PCI bus and its functions' BARs, the virtio-mmio window,
//! the APIC and its MSRs, the
//! virtqueues behind them laid out any way at all, the serial port's reader,
//! and the interval timer and the real-time clock. And the peer's side: its
//! clients, asking requests of any size, answered by whatever segments a
//! guest might send them (item 37 was a 20 KB request it could not send).
//! And a volume's SCSI controller (scsi.zig), and the peer's lying frames
//! (mangle.zig), each on dice of its own.
//!
//! What must hold for every seed:
//!   - nothing panics: an overflow, a read past guest memory, an `unreachable`
//!     is a Zig safety panic in Debug, and the panic names the seed and step;
//!   - the same seed makes the same trace: every value read back is hashed,
//!     and two runs of a seed agree.
//!
//!     zig build fuzz -Dseeds=10000        # seeds 1..n
//!     zig build test                      # the first `test_seeds`, and the regressions
//!
//! A seed that finds something stays as a named regression, as gopher-metal's
//! do (`regressions`).

const std = @import("std");
const pci = @import("pci.zig");
const apic = @import("apic.zig");
const virtio = @import("virtio.zig");
const net = @import("net.zig");
const entropy = @import("entropy.zig");
const clock = @import("clock.zig");
const coverage = @import("coverage.zig");
const peer_zig = @import("peer.zig");
const frames = @import("frames.zig");
const scsi = @import("scsi.zig");
const cache_mod = @import("cache.zig");
const mangle = @import("mangle.zig");

/// Guest memory: small, so that random addresses land inside it often.
const ram_bytes = 64 * 1024;
/// The disk: sixty-four sectors.
const disk_bytes = 64 * 512;

/// Where the panic handler finds what was running.
pub var current_seed: u64 = 0;
pub var current_step: u64 = 0;

/// Steps in one seed's run.
const steps = 400;

/// The seeds `zig build test` runs every time.
pub const test_seeds = 64;

/// Seeds that found something, kept so it stays found. Each names what it was.
pub const regressions = [_]u64{
    // A queue size past 16 bits, from the mmio register: virtio.zig narrowed
    // it in `take` (now `Queue.usableSize`). And on the peer's half (steps
    // past 400), item 37: a request larger than the peer's 2048-byte frame,
    // sent in one segment.
    1,
    // A device-config read past its 32 bytes underflowed (virtio.zig, `read`).
    // A ring index 65,535 ahead walked every chain for one doorbell (`take`).
    // Both found within the first 64 seeds; kept by `test_seeds`.
    // pci.zig's common configuration narrowed a queue size past 16 bits.
    81,
    // An MSI-X access that began in the pending bits and ran past them.
    135,
    // A used ring over the available ring: every completion offered another
    // chain, and one doorbell never ended (virtio.zig, `budget`).
    4939,
};

/// Everything one seed's run touches, made fresh for it.
const World = struct {
    ram: [ram_bytes]u8 = @splat(0),
    image: [disk_bytes]u8 = @splat(0),
    bus: pci.Bus = .{},
    lapic: apic.Apic = .{},
    block: virtio.Block = undefined,
    block_device: virtio.Device = undefined,
    card: net.Net = .{},
    card_device: virtio.Device = undefined,
    dice: entropy.Entropy = .{},
    dice_device: virtio.Device = undefined,
    serial: coverage.Serial = .{},
    pit: clock.Pit = .{},
    rtc: clock.Rtc = .{},
    peer: peer_zig.Peer = .{},
    volume_image: [disk_bytes]u8 = @splat(0),
    volume: scsi.Scsi = undefined,
    volume_device: virtio.Device = undefined,
    volume_cache: cache_mod.Cache = undefined,
    request: [24 * 1024]u8 = undefined,
    now: u64 = 0,
    hash: std.hash.Wyhash = .init(0),

    fn init(self: *World) void {
        self.block = .{ .image = &self.image };
        self.block_device = self.block.device();
        self.card_device = self.card.device();
        self.dice_device = self.dice.device();
        _ = self.bus.plug(1, &self.block_device, &self.lapic);
        _ = self.bus.plug(2, &self.card_device, &self.lapic);
        _ = self.bus.plug(3, &self.dice_device, &self.lapic);
        self.volume = .{ .image = &self.volume_image };
        self.volume_device = self.volume.device();
    }

    fn note(self: *World, value: u64) void {
        self.hash.update(std.mem.asBytes(&value));
    }

    pub fn stdout(self: *World, bytes: []const u8) void {
        self.hash.update(bytes);
    }

    pub fn jsonl(self: *World, line: []const u8) void {
        self.hash.update(line);
    }
};

/// A number a guest might choose: often a small or a boundary one, sometimes
/// anything at all.
fn pick(r: std.Random) u64 {
    return switch (r.uintLessThan(u8, 8)) {
        0 => 0,
        1 => std.math.maxInt(u64),
        2 => @as(u64, 1) << r.intRangeAtMost(u6, 0, 63),
        3 => r.int(u64) & 0xFFFF,
        4 => r.int(u64) % ram_bytes,
        5 => std.math.maxInt(u64) - r.uintLessThan(u64, 64),
        6 => r.int(u32),
        else => r.int(u64),
    };
}

fn width(r: std.Random) usize {
    return ([_]usize{ 1, 2, 4, 8 })[r.uintLessThan(usize, 4)];
}

/// **ONE SEED'S RUN**, answering its trace's hash.
pub fn run(seed: u64) u64 {
    current_seed = seed;
    const w = std.heap.page_allocator.create(World) catch @panic("no memory for a world");
    defer std.heap.page_allocator.destroy(w);
    w.* = .{};
    w.init();
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    // Some guest memory with something in it, and a BAR or two decoding.
    r.bytes(w.ram[0..r.uintLessThan(usize, ram_bytes)]);
    for (1..4) |slot| if (r.boolean()) {
        w.bus.functions[slot].?.command = @truncate(r.int(u16));
        w.bus.functions[slot].?.device.may_dma = r.boolean();
    };
    for (0..steps) |step| {
        current_step = step;
        w.now += r.uintLessThan(u64, 1_000_000);
        switch (r.uintLessThan(u8, 10)) {
            0 => configPort(w, r),
            1, 2 => bar(w, r),
            3 => apicOps(w, r),
            4 => queues(w, r),
            5 => blockRequest(w, r),
            6 => wire(w, r),
            7 => serialBytes(w, r),
            8 => if (r.boolean()) timers(w, r) else mmio(w, r),
            else => r.bytes(w.ram[r.uintLessThan(usize, ram_bytes - 64)..][0..r.uintLessThan(usize, 64)]),
        }
    }
    // **THE PEER'S HALF, ON DICE OF ITS OWN**, so that adding it left every
    // seed above, the regressions among them, the run it was.
    var peer_prng = std.Random.DefaultPrng.init(seed ^ 0x70_65_65_72); // "peer"
    const pr = peer_prng.random();
    for (0..steps) |step| {
        current_step = steps + step;
        w.now += pr.uintLessThan(u64, 5_000_000);
        peerSide(w, pr);
    }
    // **THE VOLUME'S HALF** (scsi.zig), on dice of its own for the same
    // reason: a SCSI controller and its disk, with a write cache that tells
    // the truth or lies, and the power cut after some write.
    var volume_prng = std.Random.DefaultPrng.init(seed ^ 0x73_63_73_69); // "scsi"
    const vr = volume_prng.random();
    w.volume_cache = .{ .gpa = std.heap.page_allocator, .image = &w.volume_image, .lies = vr.boolean() };
    defer w.volume_cache.deinit();
    if (vr.boolean()) w.volume.cache = &w.volume_cache;
    if (vr.boolean()) {
        w.volume_cache.keeps = vr.intRangeAtMost(u64, 1, 4);
        w.volume_cache.keep_seed = vr.int(u64);
    }
    if (vr.uintLessThan(u8, 4) == 0) w.volume.power.cut_after = vr.uintLessThan(u64, 40);
    if (vr.uintLessThan(u8, 4) == 0) w.volume.attention_at = vr.uintLessThan(u64, 60);
    if (vr.uintLessThan(u8, 8) == 0) w.volume.gone_at = vr.uintLessThan(u64, 300);
    if (vr.uintLessThan(u8, 8) == 0) w.volume.read_only_at = vr.uintLessThan(u64, 300);
    if (vr.uintLessThan(u8, 8) == 0) w.volume.sector_said = ([_]u32{ 1, 4096, 520, 1 << 20 })[vr.uintLessThan(usize, 4)];
    w.volume.no_mode_pages = vr.uintLessThan(u8, 8) == 0;
    w.volume.wce_fixed = ([_]scsi.WceFixed{ .no, .no, .refuses, .ignores })[vr.uintLessThan(usize, 4)];
    if (vr.uintLessThan(u8, 4) == 0) w.volume.reset_at = vr.uintLessThan(u64, 60);
    w.pit.frozen = vr.uintLessThan(u8, 8) == 0;
    w.rtc.absent = vr.uintLessThan(u8, 8) == 0;
    w.rtc.stuck = vr.uintLessThan(u8, 8) == 0;
    if (vr.uintLessThan(u8, 4) == 0) {
        w.volume.sync_fail_at = vr.uintLessThan(u64, 40);
        w.volume.sync_fail_for = vr.uintLessThan(u64, 4);
    }
    for (0..steps) |step| {
        current_step = 2 * steps + step;
        volumeSide(w, vr);
    }
    // **THE PEER'S LIES** (mangle.zig), on dice of their own: frames that
    // are the peer's TCP, then bent anywhere, each made into every kind.
    var lie_prng = std.Random.DefaultPrng.init(seed ^ 0x6c_69_65_73); // "lies"
    const lr = lie_prng.random();
    for (0..steps / 4) |step| {
        current_step = 3 * steps + step;
        lies(w, lr);
    }
    return w.hash.final();
}

fn lies(w: *World, r: std.Random) void {
    var buf: [2048]u8 = undefined;
    var data: [1400]u8 = undefined;
    const n = r.uintLessThan(usize, data.len);
    r.bytes(data[0..n]);
    const frame = frames.fakeTo(&buf, r.int(u16), r.int(u8), r.int(u32), r.int(u32), data[0..n]);
    var bent: [2048]u8 = undefined;
    @memcpy(bent[0..frame.len], frame);
    // Now and then a byte of the headers anything, or the frame cut short.
    if (r.boolean()) bent[r.uintLessThan(usize, 54)] = r.int(u8);
    const len = if (r.uintLessThan(u8, 4) == 0) r.uintLessThan(usize, frame.len + 1) else frame.len;
    for (mangle.kinds) |k| {
        var out: [2048]u8 = undefined;
        const lie = mangle.mangle(bent[0..len], k, &out) orelse {
            w.note(0);
            continue;
        };
        w.hash.update(lie);
        w.card.line.hold(lie, w.now);
    }
}

/// **A SCSI REQUEST SHAPED AS GOPHER-METAL SHAPES ONE, WITH ITS FIELDS
/// WRONG**: the header, the data and the response anywhere and any length,
/// in any order now and then; a LUN, a command of the six or any other, an
/// LBA and a count of anything. Or a queue laid out any way, or a sync.
fn volumeSide(w: *World, r: std.Random) void {
    const d = &w.volume_device;
    if (r.uintLessThan(u8, 8) == 0) {
        const qi = r.uintLessThan(usize, d.queues.len);
        const q = &d.queues[qi];
        q.desc = if (r.boolean()) r.uintLessThan(u64, ram_bytes) else pick(r);
        q.avail = if (r.boolean()) r.uintLessThan(u64, ram_bytes) else pick(r);
        q.used = if (r.boolean()) r.uintLessThan(u64, ram_bytes) else pick(r);
        q.size = @truncate(if (r.boolean()) r.uintLessThan(u64, 300) else pick(r));
        q.ready = @truncate(pick(r) & 1);
        d.notified(d.context, d, &w.ram, @intCast(qi));
        w.note(virtio.readInt(u16, &w.ram, q.used +% 2));
        return;
    }
    if (r.uintLessThan(u8, 16) == 0) {
        w.note(d.read(0x100 + r.uintLessThan(u64, 48), @intCast(width(r))));
        return;
    }
    const q = &d.queues[scsi.request_queue];
    q.* = .{ .size = 8, .ready = 1, .desc = 0x100, .avail = 0x200, .used = 0x300 };
    d.may_dma = true;
    const header: u64 = if (r.uintLessThan(u8, 8) != 0) 0x400 else pick(r);
    const response: u64 = if (r.uintLessThan(u8, 8) != 0) 0x500 else pick(r);
    const data: u64 = if (r.uintLessThan(u8, 8) != 0) 0x1000 else pick(r);
    // A count near the disk's 64 sectors, and as often as not the buffer
    // that fits it, so that reads and writes land as well as fail.
    const count = r.uintLessThan(u16, 10);
    const data_len: u32 = switch (r.uintLessThan(u8, 4)) {
        0, 1 => @as(u32, count) * 512,
        2 => 512 * r.uintLessThan(u32, 9),
        else => @truncate(pick(r)),
    };
    const header_len: u32 = if (r.uintLessThan(u8, 8) != 0) scsi.request_len else @truncate(pick(r));
    const response_len: u32 = if (r.uintLessThan(u8, 8) != 0) scsi.response_len else @truncate(pick(r));
    const wr = virtio.Desc.write_flag;
    const nx = virtio.Desc.next_flag;
    // none, from the disk, to the disk, or any flags at all.
    const Link = struct { addr: u64, len: u32, flags: u16 };
    var links: [3]Link = undefined;
    var n: usize = 3;
    switch (r.uintLessThan(u8, 4)) {
        0 => {
            links[0] = .{ .addr = header, .len = header_len, .flags = 0 };
            links[1] = .{ .addr = response, .len = response_len, .flags = wr };
            n = 2;
        },
        1 => {
            links[0] = .{ .addr = header, .len = header_len, .flags = 0 };
            links[1] = .{ .addr = response, .len = response_len, .flags = wr };
            links[2] = .{ .addr = data, .len = data_len, .flags = wr };
        },
        2 => {
            links[0] = .{ .addr = header, .len = header_len, .flags = 0 };
            links[1] = .{ .addr = data, .len = data_len, .flags = 0 };
            links[2] = .{ .addr = response, .len = response_len, .flags = wr };
        },
        else => {
            n = r.intRangeAtMost(usize, 1, 3);
            for (links[0..n]) |*l| l.* = .{ .addr = if (r.boolean()) 0x400 else pick(r), .len = @truncate(pick(r)), .flags = r.int(u16) & wr };
        },
    }
    for (links[0..n], 0..) |l, i| {
        const desc = 0x100 + i * @sizeOf(virtio.Desc);
        virtio.writeInt(u64, &w.ram, desc, l.addr);
        virtio.writeInt(u32, &w.ram, desc + 8, l.len);
        virtio.writeInt(u16, &w.ram, desc + 12, l.flags | @as(u16, if (i + 1 < n) nx else 0));
        virtio.writeInt(u16, &w.ram, desc + 14, @intCast(i + 1));
    }
    // The header at 0x400: the LUN field, then the CDB at 19.
    if (header == 0x400) {
        // The disk's address, 0:0, but now and then another.
        var lun = [8]u8{ 1, 0, 0x40, 0, 0, 0, 0, 0 };
        if (r.uintLessThan(u8, 8) == 0) r.bytes(lun[0..4]);
        @memcpy(w.ram[0x400..][0..8], &lun);
        const ops = [_]u8{ scsi.op_test_unit_ready, scsi.op_inquiry, scsi.op_read_capacity, scsi.op_mode_sense, scsi.op_read, scsi.op_write, scsi.op_synchronize, scsi.op_mode_select };
        var cdb: [scsi.cdb_size]u8 = undefined;
        r.bytes(&cdb);
        cdb[0] = if (r.uintLessThan(u8, 8) != 0) ops[r.uintLessThan(usize, ops.len)] else r.int(u8);
        if (r.uintLessThan(u8, 4) != 0) {
            std.mem.writeInt(u32, cdb[2..6], r.uintLessThan(u32, 72), .big);
            std.mem.writeInt(u16, cdb[7..9], count, .big);
        }
        // A MODE SELECT is often the one gopher-metal sends: PF set, the
        // header and the caching page, WCE either way (metal-vmm QUEUE 119).
        if (cdb[0] == scsi.op_mode_select and r.boolean()) {
            cdb[1] = 0x10;
            std.mem.writeInt(u16, cdb[7..9], 8 + 20, .big);
            if (data <= w.ram.len -| 28) {
                const list = w.ram[@intCast(data)..][0..28];
                @memset(list, 0);
                list[8] = 0x08;
                list[9] = 18;
                if (r.boolean()) list[10] = 0x04;
            }
        }
        @memcpy(w.ram[0x400 + 19 ..][0..scsi.cdb_size], &cdb);
    }
    virtio.writeInt(u16, &w.ram, 0x200, 0);
    virtio.writeInt(u16, &w.ram, 0x204, 0);
    virtio.writeInt(u16, &w.ram, 0x202, 1);
    q.last_avail = 0;
    d.notified(d.context, d, &w.ram, scsi.request_queue);
    w.note(virtio.readInt(u32, &w.ram, 0x500 + 8));
    w.note(w.volume.writes);
    if (r.uintLessThan(u8, 32) == 0) {
        w.volume_cache.lose();
        w.volume.power.cut = null;
    }
}

/// Ports 0xCF8-0xCFF and their neighbours, at any width.
fn configPort(w: *World, r: std.Random) void {
    const port: u16 = 0xCF6 + r.uintLessThan(u16, 12);
    var bytes: [4]u8 = undefined;
    const n = ([_]usize{ 1, 2, 4 })[r.uintLessThan(usize, 3)];
    if (r.boolean()) {
        // Aim the address register at a real function's register, often.
        const value: u32 = if (r.boolean())
            0x8000_0000 | (@as(u32, r.uintLessThan(u32, 5)) << 11) | (@as(u32, r.uintLessThan(u32, 8)) << 8) | r.uintLessThan(u32, 256)
        else
            r.int(u32);
        std.mem.writeInt(u32, &bytes, value, .little);
        w.bus.out(pci.address_port, &bytes);
    }
    if (!pci.isPort(port)) return;
    if (r.boolean()) {
        r.bytes(bytes[0..n]);
        w.bus.out(port, bytes[0..n]);
    } else {
        w.bus.in(port, bytes[0..n]);
        w.hash.update(bytes[0..n]);
    }
}

/// A load or store anywhere in, or near, the functions' BARs.
fn bar(w: *World, r: std.Random) void {
    const slot = r.uintLessThan(u64, 5);
    const base = if (w.bus.functions[@intCast(@min(slot, 4))]) |f| f.bar else 0xC000_0000;
    const addr = if (r.uintLessThan(u8, 8) == 0) pick(r) else base + r.uintLessThan(u64, 0x6000);
    var data: [8]u8 = undefined;
    const n = width(r);
    if (r.boolean()) {
        r.bytes(data[0..n]);
        _ = w.bus.memory(&w.ram, addr, true, data[0..n]);
    } else {
        @memset(&data, 0);
        w.note(@intFromBool(w.bus.memory(&w.ram, addr, false, data[0..n])));
        w.hash.update(data[0..n]);
    }
}

fn apicOps(w: *World, r: std.Random) void {
    const msrs = [_]u32{ apic.msr_apic_base, apic.msr_tsc_deadline, 0x10, 0x800, 0 };
    switch (r.uintLessThan(u8, 6)) {
        0 => w.lapic.write(r.uintLessThan(u64, 0x1000), @truncate(pick(r)), w.now),
        1 => w.note(w.lapic.read(r.uintLessThan(u64, 0x1000), w.now)),
        2 => w.note(@intFromBool(w.lapic.writeMsr(msrs[r.uintLessThan(usize, msrs.len)], pick(r), w.now))),
        3 => w.note(w.lapic.readMsr(msrs[r.uintLessThan(usize, msrs.len)], w.now) orelse 7),
        4 => w.lapic.raise(r.int(u8)),
        else => {
            w.lapic.tick(w.now);
            w.note(w.lapic.next() orelse 0);
            if (r.boolean()) w.lapic.write(0x0B0, 0, w.now);
        },
    }
}

/// **A QUEUE LAID OUT ANY WAY AT ALL**, and its doorbell rung: rings and
/// descriptor tables anywhere (inside guest memory, past it, at the top of
/// the address space), sizes that are not powers of two, chains that loop or
/// run off the table, buffers of any length.
fn queues(w: *World, r: std.Random) void {
    const devices = [_]*virtio.Device{ &w.block_device, &w.card_device, &w.dice_device };
    const d = devices[r.uintLessThan(usize, devices.len)];
    // Two, as there were before the SCSI controller's third: a seed's draws
    // stay the run they were. The volume's queues are `volumeSide`'s.
    const qi = r.uintLessThan(usize, 2);
    const q = &d.queues[qi];
    if (r.boolean()) {
        q.desc = if (r.boolean()) r.uintLessThan(u64, ram_bytes) else pick(r);
        q.avail = if (r.boolean()) r.uintLessThan(u64, ram_bytes) else pick(r);
        q.used = if (r.boolean()) r.uintLessThan(u64, ram_bytes) else pick(r);
        q.size = @truncate(if (r.boolean()) r.uintLessThan(u64, 300) else pick(r));
        q.ready = @truncate(pick(r) & 1);
        q.last_avail = r.int(u16);
    }
    if (r.boolean()) {
        // A descriptor that names somewhere, written where the table is.
        const at = q.desc +% r.uintLessThan(u64, 8) * @sizeOf(virtio.Desc);
        virtio.writeInt(u64, &w.ram, at, if (r.boolean()) r.uintLessThan(u64, ram_bytes) else pick(r));
        virtio.writeInt(u32, &w.ram, at +% 8, @truncate(if (r.boolean()) r.uintLessThan(u64, 4096) else pick(r)));
        virtio.writeInt(u16, &w.ram, at +% 12, r.int(u16));
        virtio.writeInt(u16, &w.ram, at +% 14, r.int(u16));
        virtio.writeInt(u16, &w.ram, q.avail +% 2, r.int(u16));
    }
    d.notified(d.context, d, &w.ram, @intCast(qi));
    w.note(virtio.readInt(u16, &w.ram, q.used +% 2));
}

/// **A BLOCK REQUEST SHAPED RIGHT, WITH ITS FIELDS WRONG**: a three-link
/// chain, as the device wants one, whose header, sector, buffer and status
/// are anywhere and anything. A random queue rarely builds one.
fn blockRequest(w: *World, r: std.Random) void {
    const d = &w.block_device;
    const q = &d.queues[0];
    q.* = .{ .size = 8, .ready = 1, .desc = 0x100, .avail = 0x200, .used = 0x300 };
    d.may_dma = true;
    const at = [_]u64{
        if (r.boolean()) 0x400 else pick(r), // the header
        if (r.boolean()) 0x1000 else pick(r), // the data
        if (r.boolean()) 0x500 else pick(r), // the status byte
    };
    const lens = [_]u32{ 16, if (r.boolean()) 512 * r.uintLessThan(u32, 9) else @truncate(pick(r)), 1 };
    for (0..3) |i| {
        const desc = 0x100 + i * @sizeOf(virtio.Desc);
        virtio.writeInt(u64, &w.ram, desc, at[i]);
        virtio.writeInt(u32, &w.ram, desc + 8, lens[i]);
        virtio.writeInt(u16, &w.ram, desc + 12, @as(u16, if (i < 2) virtio.Desc.next_flag else 0) | @as(u16, if (i > 0) virtio.Desc.write_flag else 0));
        virtio.writeInt(u16, &w.ram, desc + 14, @intCast(i + 1));
    }
    virtio.writeInt(u32, &w.ram, 0x400, r.uintLessThan(u32, 4)); // in, out, flush, unknown
    virtio.writeInt(u64, &w.ram, 0x408, if (r.boolean()) r.uintLessThan(u64, 80) else pick(r));
    virtio.writeInt(u16, &w.ram, 0x200, 0);
    virtio.writeInt(u16, &w.ram, 0x204, 0); // head: descriptor 0
    virtio.writeInt(u16, &w.ram, 0x202, 1);
    q.last_avail = 0;
    d.notified(d.context, d, &w.ram, 0);
    w.note(virtio.readInt(u8, &w.ram, 0x500));
    w.note(w.block.writes);
}

/// The virtio-mmio window the microvm-shaped machine serves: any register,
/// at any width, with any value.
fn mmio(w: *World, r: std.Random) void {
    const devices = [_]*virtio.Device{ &w.block_device, &w.card_device, &w.dice_device };
    const d = devices[r.uintLessThan(usize, devices.len)];
    const offset = if (r.boolean()) r.uintLessThan(u64, 0x200) else pick(r) % 0x1000;
    if (r.boolean()) {
        d.write(&w.ram, offset, @truncate(pick(r)));
    } else {
        w.note(d.read(offset, @intCast(width(r))));
    }
}

/// Frames from the peer's side onto the wire, and the pump.
fn wire(w: *World, r: std.Random) void {
    var frame: [1600]u8 = undefined;
    const n = r.uintLessThan(usize, frame.len);
    r.bytes(frame[0..n]);
    w.card.line.hold(frame[0..n], w.now);
    w.card.pump(&w.card_device, &w.ram, w.now);
    w.note(w.card.received);
}

/// **THE PEER, SPOKEN TO BY A GUEST THAT MAY SAY ANYTHING.** The first
/// time, its clients and how rough the first one is, and a request of any
/// size up to 24 KB; then segments to one of its clients (a SYN-ACK to the first
/// client with any MSS, anything acknowledging anything, data, a FIN, a reset) or
/// any bytes at all, and whatever it says back and on its own by now.
fn peerSide(w: *World, r: std.Random) void {
    const p = &w.peer;
    if (p.opened_at == null) {
        const n = r.uintLessThan(usize, w.request.len);
        r.bytes(w.request[0..n]);
        p.rough = .{
            .mss = if (r.boolean()) r.uintLessThan(usize, 3000) else null,
            .retransmits = r.boolean(),
            .ignore_window = r.boolean(),
            .retry = r.uintLessThan(u8, 3),
            .drip_ns = if (r.uintLessThan(u8, 4) == 0) r.uintLessThan(u64, 50_000_000) else null,
            .reset_after_ns = if (r.uintLessThan(u8, 4) == 0) r.uintLessThan(u64, 50_000_000) else null,
            .reset_off = if (r.boolean()) r.int(u32) else 0,
            .vanish_after = if (r.uintLessThan(u8, 4) == 0) r.uintLessThan(usize, 70_000) else null,
            .flood = if (r.uintLessThan(u8, 4) == 0) r.uintLessThan(u32, 40) else 0,
            .flood_gap_ns = r.uintLessThan(u64, 2_000_000),
            .shut_after = if (r.uintLessThan(u8, 4) == 0) r.uintLessThan(usize, 70_000) else null,
            .shut_for_ns = r.uintLessThan(u64, 50_000_000),
        };
        p.plan = .{ .clients = r.intRangeAtMost(u8, 1, peer_zig.max_clients), .asks = r.intRangeAtMost(u32, 1, 3), .gap_ns = r.uintLessThan(u64, 2_000_000) };
        w.note(p.open(w.request[0..n], w.now).len);
        return;
    }
    var out: [2048]u8 = undefined;
    const i = r.uintLessThan(usize, @max(p.opened, 1));
    const c = p.client(i);
    const seq = if (r.boolean()) c.ack else @as(u32, @truncate(pick(r)));
    const ack = if (r.boolean()) c.seq else @as(u32, @truncate(pick(r)));
    var data: [1400]u8 = undefined;
    const len = if (r.boolean()) 0 else r.uintLessThan(usize, data.len);
    r.bytes(data[0..len]);
    const frame = switch (r.uintLessThan(u8, 4)) {
        0 => frames.fakeSynAck(&out, seq, ack, @truncate(pick(r))),
        1 => frames.fakeTo(&out, c.port, r.int(u8), seq, ack, data[0..len]),
        2 => frames.fakeTo(&out, c.port, frames.flag_ack | (if (r.boolean()) frames.flag_fin else 0), seq, ack, data[0..len]),
        else => raw: {
            r.bytes(out[0..len]);
            break :raw out[0..len];
        },
    };
    if (p.answer(frame, w.now)) |back| w.note(back.len);
    for (0..64) |_| w.note((p.more(w.now) orelse break).len);
    for (0..64) |_| w.note((p.due(w.now) orelse break).len);
    w.note(p.wakeAt() orelse 0);
}

/// Bytes on COM1, the coverage prefix among them.
fn serialBytes(w: *World, r: std.Random) void {
    w.serial.withhold = r.boolean();
    var bytes: [64]u8 = undefined;
    const n = r.uintLessThan(usize, bytes.len);
    r.bytes(bytes[0..n]);
    if (r.boolean() and n >= coverage.prefix.len) @memcpy(bytes[0..coverage.prefix.len], coverage.prefix);
    for (bytes[0..n]) |*b| if (r.uintLessThan(u8, 16) == 0) {
        b.* = '\n';
    };
    w.serial.feed(bytes[0..n], .{ .exit = 0, .ns = w.now }, w);
}

/// The interval timer and the real-time clock, with any byte.
fn timers(w: *World, r: std.Random) void {
    switch (r.uintLessThan(u8, 5)) {
        0 => w.pit.command(r.int(u8), w.now),
        1 => w.pit.write(r.int(u8), w.now),
        2 => w.note(w.pit.read(w.now)),
        3 => w.rtc.select(r.int(u8)),
        else => {
            if (r.boolean()) w.rtc.store(r.int(u8));
            w.note(w.rtc.read(w.now));
        },
    }
}

/// Seeds `first` to `last`, each run twice: the same trace both times.
pub fn sweep(first: u64, last: u64) !void {
    var seed = first;
    while (seed <= last) : (seed += 1) {
        const a = run(seed);
        const b = run(seed);
        if (a != b) {
            std.debug.print("fuzz: seed {d} is not the same run twice\n", .{seed});
            return error.NotDeterministic;
        }
    }
}

test "the first seeds: nothing panics, and each seed is one trace" {
    try sweep(1, test_seeds);
}

test "the regressions stay found" {
    for (regressions) |seed| _ = run(seed);
}
