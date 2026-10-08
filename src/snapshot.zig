//! **THE MACHINE'S STATE, SAVED AND RESTORED: THE DEVICE SIDE.**
//!
//! An explorer, as Antithesis's does, branches many runs from one prefix
//! instead of booting each from scratch. That needs the whole machine saved
//! at an instant and put back. This file is the half that is all logic: every
//! model this program keeps.
//!
//! **A MODEL'S SNAPSHOT IS ITS VALUE.** Each model here keeps its state
//! inline: the clock, the PIT and the RTC, the APIC, the MSI-X table and the
//! PCI functions, the virtqueues' positions, the serial port's reader and its
//! coverage table, the entropy generator, the wire with the frames in flight,
//! the disk's faults, the peer and every client's TCP. So `save` is a copy and
//! `restore` an assignment *in place*. A model that points at another
//! (a `Device` at the device it serves, a `Function` at its `Device` and the
//! APIC) points at the same storage after a restore, which is what keeps
//! those pointers right. A restore into other storage would not.
//!
//! **ONE THING IS NOT INLINE: THE DISK'S BYTES.** A `Block` borrows its image
//! (disk.zig's mapping), so `Disk` here copies the image and the record of
//! what was written.
//!
//! **THE OTHER HALF IS THE BOX'S**: the vCPU's state and guest memory. The
//! plan for it, and for a whole sweep from one boot, is docs/SNAPSHOT.md.
//! This file does not guess at it.
//!
//! The proof is a test per model. Drive it k seeded steps, save it, take a
//! detour of different steps, restore it, and go on: the trace must be the
//! uninterrupted run's, exactly. The generator and the trace's hash are saved
//! with the model, so "go on" means the very same steps.
//!
//! **AND THE PREMISE IS HELD, NOT ONLY SHOWN** (metal-vmm QUEUE 113): a walk
//! over every model's type (`models`) finds each pointer in it, and the test
//! build fails on one that is neither `borrowed` (with why a restore in place
//! keeps it right) nor a known gap (`gaps`, each with its red test). So a
//! model that grows a slice or a heap map next month fails to compile here,
//! instead of a restored run quietly going another way. `main.zig`'s census
//! does the same for every field of the machine.

const std = @import("std");
const clock = @import("clock.zig");
const apic = @import("apic.zig");
const msix = @import("msix.zig");
const virtio = @import("virtio.zig");
const entropy = @import("entropy.zig");
const faults = @import("faults.zig");
const net = @import("net.zig");
const coverage = @import("coverage.zig");
const disk = @import("disk.zig");
const scsi = @import("scsi.zig");
const cache = @import("cache.zig");
const pci = @import("pci.zig");
const virtio_pci = @import("virtio_pci.zig");
const cost = @import("cost.zig");

/// A model's state, as of now.
pub fn save(model: anytype) @TypeOf(model.*) {
    return model.*;
}

/// Puts a model back as it was saved, in the same storage it was saved from.
pub fn restore(model: anytype, saved: @TypeOf(model.*)) void {
    model.* = saved;
}

/// **THE DISK'S BYTES, AND WHICH SECTORS THE RUN HAS WRITTEN**: the one part
/// of the device side not held inline (`Block.image` is borrowed). `block`
/// is either disk: the boot disk's `virtio.Block` or the volume's
/// `scsi.Scsi`, which borrow their bytes alike (metal-vmm QUEUE 113).
pub const Disk = struct {
    image: []u8,
    dirty: ?[]u8,

    pub fn save(allocator: std.mem.Allocator, block: anytype) !Disk {
        const image = try allocator.dupe(u8, block.image);
        errdefer allocator.free(image);
        const dirty = if (block.dirty) |d| try allocator.dupe(u8, d) else null;
        return .{ .image = image, .dirty = dirty };
    }

    pub fn restore(self: *const Disk, block: anytype) void {
        @memcpy(block.image, self.image);
        if (block.dirty) |d| @memcpy(d, self.dirty.?);
    }

    pub fn deinit(self: *Disk, allocator: std.mem.Allocator) void {
        allocator.free(self.image);
        if (self.dirty) |d| allocator.free(d);
    }
};

// ── the premise, held: no model points anywhere a restore would not mend ────

/// **EVERY MODEL THIS FILE SAVES BY ITS VALUE** (metal-vmm QUEUE 113): each
/// one the machine keeps (`main.Machine`'s census names them). A model added
/// to the machine goes here, and the walk below holds it to the premise.
pub const models = .{
    clock.Clock,         clock.Pit,       clock.Rtc,     apic.Apic,
    msix.Msix,           entropy.Entropy, faults.Wire,   faults.Drive,
    net.Net,             coverage.Serial, virtio.Device, virtio.Block,
    virtio_pci.Function, pci.Bus,         scsi.Scsi,     cost.Cost,
};

/// **THE POINTERS A RESTORE IN PLACE KEEPS RIGHT**, each with why. A path is
/// the model's name and its fields from there, `?` for an optional's child
/// and `[]` for an array's element. A function pointer is code, not state,
/// and needs no line.
pub const borrowed = .{
    .{ "virtio.Device.context", "the device it serves, beside it in the machine's storage" },
    .{ "virtio.Device.completion?.context", "the PCI function that hears a completion, in the machine's storage" },
    .{ "virtio_pci.Function.device", "the device the function carries, in the machine's storage" },
    .{ "virtio_pci.Function.apic?", "the machine's one local APIC" },
    .{ "pci.Bus.functions[]?.device", "as `virtio_pci.Function.device`" },
    .{ "pci.Bus.functions[]?.apic?", "as `virtio_pci.Function.apic?`" },
    .{ "virtio.Block.image", "the boot disk's bytes: saved apart, by `Disk`" },
    .{ "virtio.Block.dirty?", "which of them the run wrote: saved with them, by `Disk`" },
    .{ "scsi.Scsi.image", "the volume's bytes: saved apart, by `Disk`" },
    .{ "scsi.Scsi.dirty?", "which of them the run wrote: saved with them, by `Disk`" },
    .{ "net.Net.peer.request", "a request read before the run's first exit (`main`'s `request_bufs`), never written again" },
    .{ "net.Net.peer.plan.requests[]", "the same" },
    .{ "net.Net.peer.others[].request", "the same" },
    .{ "net.Net.peer.tcp.request", "the same: the first client's, from `Peer.ask`" },
};

/// **THE POINTERS A RESTORE IN PLACE GETS WRONG TODAY**, each with its red
/// test. Not a way to excuse a pointer: a line here is a gap in the
/// snapshot, for the box to close before a sweep restores a run that has it.
pub const gaps = .{
    .{ "virtio.Block.cache?", "a write cache (`DISK_CACHE`) holds the sectors as they were durable in a hash map on the heap: copied, the map is shared, and a restore keeps the detour's (test \"RED: a write cache\")" },
    .{ "scsi.Scsi.cache?", "the volume's (`VOLUME_CACHE`), the same" },
};

/// Every path in `Ty` that is a pointer to state, as one string of lines.
pub fn pointersIn(comptime Ty: type, comptime path: []const u8) []const u8 {
    return switch (@typeInfo(Ty)) {
        .pointer => |p| if (@typeInfo(p.child) == .@"fn") "" else path ++ "\n",
        .@"struct" => |st| blk: {
            var all: []const u8 = "";
            for (st.fields) |f| all = all ++ pointersIn(f.type, path ++ "." ++ f.name);
            break :blk all;
        },
        .@"union" => |u| blk: {
            var all: []const u8 = "";
            for (u.fields) |f| all = all ++ pointersIn(f.type, path ++ "." ++ f.name);
            break :blk all;
        },
        .optional => |o| pointersIn(o.child, path ++ "?"),
        .array => |a| pointersIn(a.child, path ++ "[]"),
        .error_union => |e| pointersIn(e.payload, path),
        else => "",
    };
}

/// A model's name as the lists spell it: `clock.Clock`, from `clock.Clock`.
fn nameOf(comptime Ty: type) []const u8 {
    const full = @typeName(Ty);
    const dot = std.mem.lastIndexOfScalar(u8, full, '.').?;
    const start = if (std.mem.lastIndexOfScalar(u8, full[0..dot], '.')) |d| d + 1 else 0;
    return full[start..];
}

fn listed(comptime list: anytype, comptime path: []const u8) bool {
    for (list) |entry| if (std.mem.eql(u8, entry[0], path)) return true;
    return false;
}

test "the premise: every pointer in a model is one a restore keeps right, or a gap with its red test (metal-vmm QUEUE 113)" {
    comptime {
        @setEvalBranchQuota(2_000_000);
        var found: []const u8 = "";
        for (models) |M| found = found ++ pointersIn(M, nameOf(M));
        var lines = std.mem.tokenizeScalar(u8, found, '\n');
        while (lines.next()) |path| {
            if (!listed(borrowed, path) and !listed(gaps, path))
                @compileError("snapshot.zig: " ++ path ++ " points at state a restore in place would not put back. Hold it inline, save it apart (as `Disk`), or name it in `borrowed` with why a restore keeps it right.");
        }
        // And no line names a pointer that is not there: a stale line
        // would excuse the next field to take its name.
        for (borrowed ++ gaps) |entry| {
            if (std.mem.indexOf(u8, found, entry[0] ++ "\n") == null)
                @compileError("snapshot.zig: " ++ entry[0] ++ " is listed, and no model has it");
        }
    }
}

test "the volume: its commands, its faults, and the bytes it borrows, saved apart (metal-vmm QUEUE 113)" {
    const Volume = struct {
        image: [32 * 512]u8 = @splat(0),
        dirty: [4]u8 = @splat(0),
        vol: scsi.Scsi = .{ .image = &.{} },
        dev: virtio.Device = undefined,
        g: scsi.FakeDriver = .{},
    };
    const fixup = struct {
        fn f(v: *Volume) void {
            v.vol.image = &v.image;
            v.vol.dirty = &v.dirty;
            v.dev.context = &v.vol;
        }
    }.f;
    const step = struct {
        fn f(v: *Volume, r: std.Random, h: *std.hash.Wyhash) void {
            fixup(v); // the volume and its bytes beside it, wherever they are
            const lba = r.uintLessThan(u32, 30);
            const o = switch (r.uintLessThan(u8, 3)) {
                0 => blk: {
                    r.bytes(v.g.ram[scsi.FakeDriver.data_at..][0..1024]);
                    break :blk v.g.rw(&v.dev, true, lba, 2);
                },
                1 => v.g.rw(&v.dev, false, lba, 2),
                else => v.g.synchronize(&v.dev),
            };
            h.update(std.mem.asBytes(&o));
            h.update(v.g.ram[scsi.FakeDriver.data_at..][0..1024]);
            note(h, v.vol.commands);
            note(h, @intFromBool(v.vol.power.cut != null));
        }
    }.f;
    const fresh = try testing.allocator.create(Volume);
    defer testing.allocator.destroy(fresh);
    fresh.* = .{};
    fixup(fresh);
    fresh.dev = fresh.vol.device();
    fresh.vol.power.cut_after = 60;
    fresh.vol.attention_at = 150;
    fixup(fresh);
    fresh.g.open(&fresh.dev);
    try restoresExactly(Volume, fresh, step, fixup);
}

test "the PCI bus and a function on it: config space, its BAR, MSI-X through it (metal-vmm QUEUE 113)" {
    const Board = struct {
        bus: pci.Bus = .{},
        lapic: apic.Apic = .{},
        dice: entropy.Entropy = .{},
        dev: virtio.Device = undefined,
        ram: [4096]u8 = @splat(0),
    };
    const fixup = struct {
        fn f(b: *Board) void {
            const fun = &b.bus.functions[1].?;
            fun.device = &b.dev;
            fun.apic = &b.lapic;
            b.dev.completion.?.context = fun;
            b.dev.context = &b.dice;
        }
    }.f;
    const step = struct {
        fn f(b: *Board, r: std.Random, h: *std.hash.Wyhash) void {
            fixup(b);
            var word: [4]u8 = undefined;
            switch (r.uintLessThan(u8, 4)) {
                0, 1 => {
                    // A config register of slot 1, or of the bridge.
                    const slot: u32 = r.uintLessThan(u32, 2);
                    const register: u32 = r.uintLessThan(u32, 64) * 4;
                    std.mem.writeInt(u32, &word, 0x8000_0000 | (slot << 11) | register, .little);
                    b.bus.out(pci.address_port, &word);
                    if (r.boolean()) {
                        std.mem.writeInt(u32, &word, r.int(u32) | 0x6, .little); // memory space and bus master, mostly
                        b.bus.out(pci.data_port, &word);
                    }
                    b.bus.in(pci.data_port, &word);
                    h.update(&word);
                },
                else => {
                    // Somewhere in the function's BAR, read or written.
                    const at = pci.bar_base + pci.bar_size + r.uintLessThan(u64, 0x4000);
                    const write = r.boolean();
                    if (write) std.mem.writeInt(u32, &word, r.int(u32), .little);
                    note(h, @intFromBool(b.bus.memory(&b.ram, at & ~@as(u64, 3), write, &word)));
                    h.update(&word);
                },
            }
            note(h, b.lapic.next() orelse 0);
        }
    }.f;
    const fresh = try testing.allocator.create(Board);
    defer testing.allocator.destroy(fresh);
    fresh.* = .{};
    fresh.dev = fresh.dice.device();
    _ = fresh.bus.plug(1, &fresh.dev, &fresh.lapic);
    _ = fresh.lapic.writeMsr(apic.msr_apic_base, apic.base | (1 << 8) | (1 << 11), 0);
    fresh.lapic.write(0x0F0, 0x1FF, 0);
    try restoresExactly(Board, fresh, step, fixup);
}

// ── a model restored at step k goes on as the run that never stopped ────────

const testing = std.testing;

/// What a test drives: the model, the generator choosing its steps, and the
/// hash of everything it answered. All three are saved together.
fn Run(comptime M: type) type {
    return struct {
        model: M,
        prng: std.Random.DefaultPrng,
        hash: std.hash.Wyhash = .init(0),
    };
}

/// **THE CHECK, FOR ANY MODEL.** For each seed: run `steps` steps straight
/// through; then run `k` of them, save, run a detour of other steps, restore,
/// and run the rest. The two traces must agree. `step` drives one step,
/// writing what the model answers into the hash; `fixup` re-aims any pointer
/// the model holds into itself, after the run is moved into place.
fn restoresExactly(comptime M: type, fresh: *const M, comptime step: fn (*M, std.Random, *std.hash.Wyhash) void, comptime fixup: ?fn (*M) void) !void {
    const steps = 300;
    for (1..25) |seed| {
        const k = (seed * 37) % steps;
        const a = try testing.allocator.create(Run(M));
        defer testing.allocator.destroy(a);
        a.* = .{ .model = fresh.*, .prng = .init(seed) };
        if (fixup) |f| f(&a.model);
        for (0..steps) |_| step(&a.model, a.prng.random(), &a.hash);

        const b = try testing.allocator.create(Run(M));
        defer testing.allocator.destroy(b);
        b.* = .{ .model = fresh.*, .prng = .init(seed) };
        if (fixup) |f| f(&b.model);
        for (0..k) |_| step(&b.model, b.prng.random(), &b.hash);
        const saved = try testing.allocator.create(Run(M));
        defer testing.allocator.destroy(saved);
        saved.* = save(b);
        // A detour: other steps, from another generator, into the same state.
        var detour = std.Random.DefaultPrng.init(seed ^ 0xDE70_0A);
        for (0..50) |_| step(&b.model, detour.random(), &b.hash);
        restore(b, saved.*);
        for (k..steps) |_| step(&b.model, b.prng.random(), &b.hash);

        try testing.expectEqual(a.hash.final(), b.hash.final());
    }
}

fn note(h: *std.hash.Wyhash, value: u64) void {
    h.update(std.mem.asBytes(&value));
}

test "the clock" {
    const step = struct {
        fn f(c: *clock.Clock, r: std.Random, h: *std.hash.Wyhash) void {
            if (r.boolean()) c.asked();
            note(h, c.ticks());
        }
    }.f;
    try restoresExactly(clock.Clock, &.{}, step, null);
}

test "the interval timer and the real-time clock" {
    const Both = struct { pit: clock.Pit = .{}, rtc: clock.Rtc = .{}, ns: u64 = 0 };
    const step = struct {
        fn f(m: *Both, r: std.Random, h: *std.hash.Wyhash) void {
            m.ns += r.uintLessThan(u64, 1_000_000);
            switch (r.uintLessThan(u8, 5)) {
                0 => m.pit.command(r.int(u8), m.ns),
                1 => m.pit.write(r.int(u8), m.ns),
                2 => note(h, m.pit.read(m.ns)),
                3 => m.rtc.select(r.uintLessThan(u8, 14)),
                else => note(h, m.rtc.read(m.ns)),
            }
        }
    }.f;
    try restoresExactly(Both, &.{}, step, null);
}

test "the APIC: registers, its timer, the vectors waiting and in service" {
    const Lapic = struct { a: apic.Apic = .{}, ns: u64 = 0 };
    const step = struct {
        fn f(m: *Lapic, r: std.Random, h: *std.hash.Wyhash) void {
            m.ns += r.uintLessThan(u64, 100_000);
            switch (r.uintLessThan(u8, 7)) {
                0 => _ = m.a.writeMsr(apic.msr_apic_base, apic.base | (1 << 8) | (1 << 11), m.ns),
                1 => m.a.write(0x0F0, 0x1FF, m.ns),
                2 => m.a.write(0x320, 0x41 | (@as(u32, r.uintLessThan(u32, 3)) << 17), m.ns),
                3 => _ = m.a.writeMsr(apic.msr_tsc_deadline, clock.nsAt(m.ns) + r.uintLessThan(u64, 500_000), m.ns),
                4 => m.a.write(0x380, r.uintLessThan(u32, 10_000), m.ns),
                5 => m.a.raise(r.int(u8)),
                else => {
                    m.a.tick(m.ns);
                    note(h, m.a.next() orelse 0);
                    m.a.write(0x0B0, 0, m.ns);
                },
            }
            note(h, m.a.read(0x390, m.ns));
        }
    }.f;
    try restoresExactly(Lapic, &.{}, step, null);
}

test "MSI-X: the table, the pending bits, and the messages sent" {
    const Table = struct { m: msix.Msix = .{}, a: apic.Apic = .{} };
    const step = struct {
        fn f(t: *Table, r: std.Random, h: *std.hash.Wyhash) void {
            switch (r.uintLessThan(u8, 4)) {
                0 => t.m.write(msix.table_at + r.uintLessThan(u64, msix.table_bytes), 4, r.int(u32), &t.a, true),
                1 => t.m.writeControl(@as(u32, r.int(u16)) << 16, 0xFFFF_0000, &t.a, r.boolean()),
                2 => t.m.signal(r.uintLessThan(u16, 4), &t.a, r.boolean()),
                else => note(h, t.m.read(msix.pba_at, 8)),
            }
            note(h, t.m.messages);
        }
    }.f;
    var fresh = Table{};
    _ = fresh.a.writeMsr(apic.msr_apic_base, apic.base | (1 << 8) | (1 << 11), 0);
    fresh.a.write(0x0F0, 0x1FF, 0);
    try restoresExactly(Table, &fresh, step, null);
}

test "a virtqueue's position, and the entropy it hands out" {
    const Queue = struct {
        dice: entropy.Entropy = .{},
        dev: virtio.Device = undefined,
        ram: [4096]u8 = @splat(0),
    };
    const fixup = struct {
        fn f(q: *Queue) void {
            q.dev.context = &q.dice;
        }
    }.f;
    const step = struct {
        fn f(q: *Queue, r: std.Random, h: *std.hash.Wyhash) void {
            fixup(q); // the device serves the entropy beside it, wherever that is
            // One buffer offered: descriptor (idx % 4) at 0x100, ring at 0x200.
            const idx = virtio.readInt(u16, &q.ram, 0x202);
            const d = 0x100 + @as(u64, idx % 4) * 16;
            virtio.writeInt(u64, &q.ram, d, 0x800 + @as(u64, idx % 4) * 64);
            virtio.writeInt(u32, &q.ram, d + 8, r.intRangeAtMost(u32, 1, 64));
            virtio.writeInt(u16, &q.ram, d + 12, virtio.Desc.write_flag);
            virtio.writeInt(u16, &q.ram, 0x204 + @as(u64, idx % 4) * 2, idx % 4);
            virtio.writeInt(u16, &q.ram, 0x202, idx +% 1);
            q.dev.notified(q.dev.context, &q.dev, &q.ram, 0);
            h.update(q.ram[0x800..0x900]);
            note(h, q.dev.queues[0].last_avail);
        }
    }.f;
    var fresh = Queue{};
    fresh.dev = fresh.dice.device();
    fresh.dev.queues[0] = .{ .size = 4, .ready = 1, .desc = 0x100, .avail = 0x200, .used = 0x300 };
    try restoresExactly(Queue, &fresh, step, fixup);
}

test "the wire: frames in flight, and the dice that lose them" {
    const step = struct {
        fn f(w: *faults.Wire, r: std.Random, h: *std.hash.Wyhash) void {
            var frame: [64]u8 = undefined;
            r.bytes(&frame);
            switch (r.uintLessThan(u8, 3)) {
                0 => w.hold(frame[0..r.uintLessThan(usize, 64)], r.uintLessThan(u64, 1000)),
                1 => if (w.ready(r.uintLessThan(u64, 2000))) |got| {
                    h.update(got);
                    w.take();
                },
                else => note(h, @intFromBool(w.carries())),
            }
        }
    }.f;
    var fresh = faults.Wire{ .latency_ns = 300 };
    fresh.lost.rate = 4;
    fresh.peer_lost.rate = 5;
    fresh.peer_damaged.rate = 6;
    try restoresExactly(faults.Wire, &fresh, step, null);
}

test "the disk's faults: refusals, a cut, a tear" {
    const step = struct {
        fn f(d: *faults.Drive, r: std.Random, h: *std.hash.Wyhash) void {
            if (d.cut != null) return note(h, 1);
            if (r.boolean()) note(h, @intFromBool(d.serves(r.int(u16), r.intRangeAtMost(u64, 1, 8), r.boolean()))) else note(h, d.lands(r.int(u16), r.intRangeAtMost(u64, 1, 8)));
        }
    }.f;
    var fresh = faults.Drive{ .tear = 40, .tear_keep = 2, .bad_len = 2 };
    fresh.bad = .{ 300, 9000, 0, 0, 0, 0, 0, 0 };
    fresh.refused.rate = 7;
    try restoresExactly(faults.Drive, &fresh, step, null);
}

test "the peer and its clients, and the card that carries them" {
    const Card = struct {
        card: net.Net = .{},
        dev: virtio.Device = undefined,
        ram: [4096]u8 = @splat(0),
        connected: bool = false,
        now: u64 = 0,
    };
    const fixup = struct {
        fn f(c: *Card) void {
            c.dev.context = &c.card;
        }
    }.f;
    const step = struct {
        fn f(c: *Card, r: std.Random, h: *std.hash.Wyhash) void {
            fixup(c);
            c.now += r.uintLessThan(u64, 50 * std.time.ns_per_ms);
            if (!c.connected) {
                _ = c.card.connect(&c.dev, &c.ram, "GET / HTTP/1.1\r\n\r\n");
                c.connected = true;
            }
            c.card.pump(&c.dev, &c.ram, c.now);
            note(h, c.card.nextDue(c.now) orelse 0);
            note(h, c.card.peer.flooded);
            note(h, c.card.line.next);
            while (c.card.line.ready(c.now)) |frame| {
                h.update(frame);
                c.card.line.take();
            }
        }
    }.f;
    const fresh = try testing.allocator.create(Card);
    defer testing.allocator.destroy(fresh);
    fresh.* = .{};
    fresh.dev = fresh.card.device();
    fresh.card.peer.rough = .{ .retransmits = true, .flood = 20, .flood_gap_ns = 3 * std.time.ns_per_ms, .reset_after_ns = 400 * std.time.ns_per_ms };
    fresh.card.peer.plan = .{ .clients = 3, .gap_ns = 7 * std.time.ns_per_ms };
    try restoresExactly(Card, fresh, step, fixup);
}

test "the serial port's reader and the coverage table it keeps" {
    const Reader = struct {
        serial: coverage.Serial = .{ .withhold = true },
        pub fn stdout(_: *@This(), _: []const u8) void {}
        pub fn jsonl(_: *@This(), _: []const u8) void {}
    };
    const step = struct {
        fn f(m: *Reader, r: std.Random, h: *std.hash.Wyhash) void {
            const lines = [_][]const u8{
                "coverage: {\"antithesis_assert\":{\"hit\":true,\"display_type\":\"Sometimes\",\"id\":\"a\",\"condition\":true}}\n",
                "coverage: {\"antithesis_assert\":{\"hit\":true,\"display_type\":\"Always\",\"id\":\"b\",\"condition\":false}}\n",
                "an ordinary line\n",
                "cover",
            };
            m.serial.feed(lines[r.uintLessThan(usize, lines.len)], .{ .exit = r.int(u16), .ns = r.int(u32) }, m);
            note(h, m.serial.table.lines);
            note(h, m.serial.table.reached());
            if (m.serial.table.find("a")) |p| note(h, (p.first_true orelse coverage.When{ .exit = 0, .ns = 0 }).exit);
        }
    }.f;
    const fresh = try testing.allocator.create(Reader);
    defer testing.allocator.destroy(fresh);
    fresh.* = .{};
    try restoresExactly(Reader, fresh, step, null);
}

test "the disk's bytes, saved apart from the block device that borrows them" {
    var image: [8 * 512]u8 = @splat(0);
    var dirty: [1]u8 = @splat(0);
    var block = virtio.Block{ .image = &image, .dirty = &dirty };
    @memset(image[512..1024], 0xAA);
    disk.mark(&dirty, 1, 1);
    var saved = try Disk.save(testing.allocator, &block);
    defer saved.deinit(testing.allocator);
    @memset(&image, 0x55);
    disk.mark(&dirty, 5, 2);
    saved.restore(&block);
    try testing.expectEqual(@as(u8, 0xAA), image[512]);
    try testing.expectEqual(@as(u8, 0), image[0]);
    try testing.expect(disk.isDirty(&dirty, 1) and !disk.isDirty(&dirty, 5));
}
