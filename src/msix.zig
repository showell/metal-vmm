//! **MSI-X, AS PCI 3.0 §6.8.2 HAS IT**, for a virtio-pci function
//! (virtio_pci.zig): its table, its pending bits, and Message Control's two
//! writable bits. A message is a memory write to an APIC (apic.zig); the
//! function lends the APIC it would reach, and whether bus mastering lets it
//! write at all.

const std = @import("std");
const apic = @import("apic.zig");

/// **THE TABLE'S SIZE**: as many entries as a driver could want one each —
/// the configuration change, and the two queues a device here may have.
/// Message Control says it, less one, in bits 10:0.
pub const entries = 3;
pub const table_bytes = entries * 16;
/// Where the table and the pending bits are in the function's BAR.
pub const table_at = 0x4000;
pub const pba_at = 0x5000;
/// Message Control's bits a driver may write: 15 enables MSI-X, 14 masks the
/// whole function. The rest are read-only (§6.8.2.3).
pub const enable: u16 = 0x8000;
pub const function_mask: u16 = 0x4000;
/// No entry at all (virtio §4.1.4.3).
pub const no_vector: u16 = 0xFFFF;

/// One entry of the table (§6.8.2.6-9): where its message goes, what it says,
/// and its vector control, of which only bit 0, the mask, is defined. Every
/// entry starts masked.
pub const Entry = struct {
    address: u64 = 0,
    data: u32 = 0,
    control: u32 = 1,
};

pub const Msix = struct {
    /// Message Control's writable bits, `enable` and `function_mask`.
    control: u16 = 0,
    table: [entries]Entry = @splat(.{}),
    /// The Pending Bit Array (§6.8.2.10): one bit per entry, for a message
    /// it could not send while it or the function was masked. Sent, lowest
    /// entry first, the moment nothing masks it.
    pending: u64 = 0,
    /// Messages sent, for a run's closing account.
    messages: u64 = 0,
    /// Messages sent that nothing here takes: aimed at another processor, or
    /// asking for a delivery this machine does not model (apic.zig,
    /// `messageVector`). A PC would deliver some of them elsewhere.
    unheard: u64 = 0,

    pub fn enabled(self: *const Msix) bool {
        return self.control & enable != 0;
    }

    /// Message Control as it reads: the writable bits, and the table's size
    /// less one.
    pub fn messageControl(self: *const Msix) u16 {
        return self.control | (entries - 1);
    }

    /// A write to the capability's dword at `mask`: only the bytes written
    /// change, and only the bits that are not read-only.
    pub fn writeControl(self: *Msix, value: u32, mask: u32, lapic: ?*apic.Apic, may_send: bool) void {
        if (mask & 0xFFFF_0000 == 0) return;
        const was = self.control;
        const merged = ((@as(u32, was) << 16) & ~mask) | (value & mask);
        self.control = @as(u16, @truncate(merged >> 16)) & (enable | function_mask);
        if (was != self.control) self.flush(lapic, may_send);
    }

    /// Whether an offset in the BAR is the table's or the pending bits'.
    pub fn inWindow(offset: u64) bool {
        return (offset >= table_at and offset < table_at + table_bytes) or
            (offset >= pba_at and offset < pba_at + 8);
    }

    /// A load from the table or the pending bits, at any width.
    pub fn read(self: *const Msix, offset: u64, len: u32) u64 {
        var value: u64 = 0;
        for (0..len) |i| {
            const at = offset + i;
            const byte = (self.dword(at & ~@as(u64, 3)) >> @intCast((at & 3) * 8)) & 0xFF;
            value |= @as(u64, byte) << @intCast(i * 8);
        }
        return value;
    }

    /// **A QWORD IS TWO DWORDS, LOW FIRST** (§6.8.2: software uses aligned
    /// DWORD or QWORD accesses). So one store of data and vector control
    /// sets the data before it unmasks. A narrower store changes only its
    /// own bytes.
    pub fn write(self: *Msix, offset: u64, len: u32, value: u64, lapic: ?*apic.Apic, may_send: bool) void {
        var at_dword = offset & ~@as(u64, 3);
        while (at_dword < offset + len) : (at_dword += 4) {
            var merged = self.dword(at_dword);
            for (0..4) |k| {
                const at = at_dword + k;
                if (at < offset or at >= offset + len) continue;
                const byte: u32 = @truncate(value >> @intCast((at - offset) * 8));
                const shift: u5 = @intCast(k * 8);
                merged = (merged & ~(@as(u32, 0xFF) << shift)) | (byte << shift);
            }
            self.store(at_dword, merged, lapic, may_send);
        }
    }

    /// One aligned dword of the table or the pending bits.
    fn dword(self: *const Msix, offset: u64) u32 {
        // An access that began inside may run past the end: there, nothing.
        if (!inWindow(offset)) return 0;
        if (offset >= pba_at) return @truncate(self.pending >> @intCast((offset - pba_at) * 8));
        const e = &self.table[@intCast((offset - table_at) / 16)];
        return switch ((offset - table_at) % 16) {
            0 => @truncate(e.address),
            4 => @truncate(e.address >> 32),
            8 => e.data,
            else => e.control,
        };
    }

    fn store(self: *Msix, offset: u64, value: u32, lapic: ?*apic.Apic, may_send: bool) void {
        if (!inWindow(offset) or offset >= pba_at) return; // the pending bits are read-only
        const e = &self.table[@intCast((offset - table_at) / 16)];
        switch ((offset - table_at) % 16) {
            0 => e.address = (e.address & 0xFFFF_FFFF_0000_0000) | value,
            4 => e.address = (e.address & 0xFFFF_FFFF) | (@as(u64, value) << 32),
            8 => e.data = value,
            else => {
                e.control = value & 1;
                self.flush(lapic, may_send);
            },
        }
    }

    /// An entry a driver asked for, if the table has it: one it does not is
    /// refused, and reads back as NO_VECTOR (virtio §4.1.4.3).
    pub fn entryOrNone(value: u32) u16 {
        return if (value & 0xFFFF < entries) @truncate(value) else no_vector;
    }

    /// Entry `vector` has a message to send: pending until nothing masks it.
    pub fn signal(self: *Msix, vector: u16, lapic: ?*apic.Apic, may_send: bool) void {
        if (vector >= entries) return; // NO_VECTOR: no interrupt at all
        self.pending |= @as(u64, 1) << @intCast(vector);
        self.flush(lapic, may_send);
    }

    /// Sends every held message that nothing now masks, lowest entry first.
    /// A message is a memory write, so a function not allowed to master the
    /// bus (`may_send` false) holds them all.
    pub fn flush(self: *Msix, lapic: ?*apic.Apic, may_send: bool) void {
        if (self.control & enable == 0 or self.control & function_mask != 0) return;
        if (!may_send) return;
        for (&self.table, 0..) |*e, i| {
            const bit = @as(u64, 1) << @intCast(i);
            if (self.pending & bit == 0 or e.control & 1 != 0) continue;
            self.pending &= ~bit;
            self.messages += 1;
            // A message is a memory write; only this machine's one APIC
            // listens, and only for what it can take.
            if (apic.messageVector(e.address, e.data)) |v| lapic.?.raise(v) else self.unheard += 1;
        }
    }
};

// ── MSI-X, as PCI 3.0 §6.8.2 has it, driven as a driver does ─────────────────

const virtio = @import("virtio.zig");
const net = @import("net.zig");
const entropy = @import("entropy.zig");
const testing = std.testing;
const pci = @import("pci.zig");
const virtio_pci = @import("virtio_pci.zig");
const msix_zig = @This();
const address_port = pci.address_port;
const data_port = pci.data_port;
const isPort = pci.isPort;
const bar_base = pci.bar_base;
const bar_size = pci.bar_size;
const command_memory = pci.command_memory;
const command_bus_master = pci.command_bus_master;
const command_writable = pci.command_writable;
const slots = pci.slots;
const Bus = pci.Bus;
const cfgWrite32 = pci.cfgWrite32;
const common_at = virtio_pci.common_at;
const common_len = virtio_pci.common_len;
const isr_at = virtio_pci.isr_at;
const device_at = virtio_pci.device_at;
const device_len = virtio_pci.device_len;
const notify_at = virtio_pci.notify_at;
const notify_len = virtio_pci.notify_len;
const notify_multiplier = virtio_pci.notify_multiplier;
const msix_table_at = virtio_pci.msix_table_at;
const msix_pba_at = virtio_pci.msix_pba_at;
const cap_common = virtio_pci.cap_common;
const cap_isr = virtio_pci.cap_isr;
const cap_device = virtio_pci.cap_device;
const cap_notify = virtio_pci.cap_notify;
const cap_msix = virtio_pci.cap_msix;
const msix_entries = entries;
const msix_table_bytes = table_bytes;
const Function = virtio_pci.Function;
const completedThunk = virtio_pci.completedThunk;
const nothing = virtio_pci.nothing;
const read32 = virtio_pci.read32;
const write16 = virtio_pci.write16;
const FakeGuest = virtio_pci.FakeGuest;
const Machine = virtio_pci.Machine;

test "MSI-X: masked, the message waits; unmasked, it reaches the APIC" {
    var bus = Bus{};
    var lapic = apic.Apic{};
    _ = lapic.writeMsr(apic.msr_apic_base, lapic.readMsr(apic.msr_apic_base, 0).? | (1 << 11), 0);
    lapic.write(0x0F0, 0x1FF, 0);
    var context: u8 = 0;
    var d = virtio.Device{ .id = virtio.device_id_net, .context = &context, .notified = nothing };
    const f = bus.plug(1, &d, &lapic);
    var ram: [16]u8 = undefined;
    write16(&bus, 1, 0x04, 0x6); // memory and bus master
    write16(&bus, 1, cap_msix + 2, 0x8000); // enabled
    // queue 0 takes vector-table entry 0
    var sel = [2]u8{ 0, 0 };
    try testing.expect(bus.memory(&ram, f.bar + 0x16, true, &sel));
    var zero = [2]u8{ 0, 0 };
    try testing.expect(bus.memory(&ram, f.bar + 0x1A, true, &zero));
    f.completed(0);
    try testing.expect(lapic.next() == null); // the entry is still masked
    var addr = [4]u8{ 0x00, 0x00, 0xE0, 0xFE };
    _ = bus.memory(&ram, f.bar + msix_table_at, true, &addr);
    var data = [4]u8{ 0x31, 0, 0, 0 };
    _ = bus.memory(&ram, f.bar + msix_table_at + 8, true, &data);
    var unmask = [4]u8{ 0, 0, 0, 0 };
    _ = bus.memory(&ram, f.bar + msix_table_at + 12, true, &unmask);
    try testing.expectEqual(@as(?u8, 0x31), lapic.next());
}

/// A device with MSI-X enabled, `entries` of its table aimed at APIC 0 on
/// vectors 0x50, 0x51, ..., unmasked; its queues not yet given any.
pub fn msixReady(m: *Machine, g: *FakeGuest, slot: u8) !FakeGuest.Found {
    var f = g.open(slot).?;
    _ = (try g.negotiate(f, 0)).?;
    try g.prepareMsix(&f);
    for (0..msix_entries) |i| {
        const entry = f.msix_entry.? + i * 16;
        try g.store(u32, entry + 0, @intCast(apic.base));
        try g.store(u32, entry + 4, 0);
        try g.store(u32, entry + 8, 0x50 + @as(u32, @intCast(i)));
        try g.store(u32, entry + 12, 0);
    }
    _ = m;
    return f;
}

pub fn setVector(g: *FakeGuest, f: FakeGuest.Found, queue: u16, entry: u16) !u16 {
    try g.store(u16, f.common + 0x16, queue);
    try g.store(u16, f.common + 0x1A, entry);
    return g.load(u16, f.common + 0x1A);
}

test "Message Control: the table's size is read-only, and only bits 15 and 14 are written" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    const f = g.open(3).?;
    const cap = f.msix_cap;
    // §6.8.2.3: bits 10:0 are the table size, N - 1, and read-only.
    try testing.expectEqual(@as(u16, msix_entries - 1), g.cfgRead16(3, cap + 2) & 0x7FF);
    g.cfgWrite16(3, cap + 2, 0xFFFF);
    try testing.expectEqual(@as(u16, 0xC000 | (msix_entries - 1)), g.cfgRead16(3, cap + 2));
    // A byte written to the low half leaves the high half's bits alone.
    var addr: [4]u8 = undefined;
    std.mem.writeInt(u32, &addr, 0x8000_0000 | (3 << 11) | @as(u32, cap), .little);
    m.bus.out(address_port, &addr);
    m.bus.out(data_port + 2, &.{0x00});
    try testing.expectEqual(@as(u16, 0xC000), g.cfgRead16(3, cap + 2) & 0xC000);
    m.bus.out(data_port + 3, &.{0x80});
    try testing.expectEqual(@as(u16, 0x8000), g.cfgRead16(3, cap + 2) & 0xC000);
}

test "each queue's own entry, and its own vector" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    const f = try msixReady(&m, &g, 2);
    try testing.expectEqual(@as(u16, 1), try setVector(&g, f, 0, 1));
    try testing.expectEqual(@as(u16, 2), try setVector(&g, f, 1, 2));
    m.bus.functions[2].?.completed(1);
    try testing.expectEqual(@as(?u8, 0x52), m.lapic.next());
    m.lapic.write(0x0B0, 0, 0);
    m.bus.functions[2].?.completed(0);
    try testing.expectEqual(@as(?u8, 0x51), m.lapic.next());
}

test "an entry past the table is refused: it reads back NO_VECTOR, and nothing is sent" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    const f = try msixReady(&m, &g, 2);
    // virtio 1.2 §4.1.4.3: a mapping the device cannot make reads NO_VECTOR.
    try testing.expectEqual(no_vector, try setVector(&g, f, 0, msix_entries));
    try g.store(u16, f.common + 0x10, 7);
    try testing.expectEqual(no_vector, try g.load(u16, f.common + 0x10));
    m.bus.functions[2].?.completed(0);
    m.bus.functions[2].?.configChanged();
    try testing.expect(m.lapic.next() == null);
    try testing.expectEqual(@as(u64, 0), m.bus.functions[2].?.msix.pending);
}

test "with MSI-X on, a queue's completion is a message and not the ISR's bit" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    const f = try msixReady(&m, &g, 2);
    _ = try setVector(&g, f, 0, 0);
    m.bus.functions[2].?.completed(0);
    try testing.expectEqual(@as(?u8, 0x50), m.lapic.next());
    // virtio 1.2 §4.1.5.4: with MSI-X, the device does not use the ISR.
    try testing.expectEqual(@as(u8, 0), try g.load(u8, f.isr));
}

test "with MSI-X off, a completion is the ISR's bit, and reading it clears it" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    const f = g.open(2).?;
    _ = (try g.negotiate(f, 0)).?;
    m.bus.functions[2].?.completed(0);
    try testing.expect(m.lapic.next() == null);
    try testing.expectEqual(@as(u8, 1), try g.load(u8, f.isr)); // §4.1.4.5
    try testing.expectEqual(@as(u8, 0), try g.load(u8, f.isr));
    m.bus.functions[2].?.configChanged();
    try testing.expectEqual(@as(u8, 2), try g.load(u8, f.isr));
}

test "a configuration change is msix_config's message" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    const f = try msixReady(&m, &g, 2);
    try g.store(u16, f.common + 0x10, 2);
    try testing.expectEqual(@as(u16, 2), try g.load(u16, f.common + 0x10));
    m.bus.functions[2].?.configChanged();
    try testing.expectEqual(@as(?u8, 0x52), m.lapic.next());
}

test "the function's mask holds every entry's message, and the pending bits show them" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    const f = try msixReady(&m, &g, 2);
    _ = try setVector(&g, f, 0, 1);
    _ = try setVector(&g, f, 1, 2);
    const control = g.cfgRead16(2, f.msix_cap + 2);
    g.cfgWrite16(2, f.msix_cap + 2, control | 0x4000);
    const fn2 = &m.bus.functions[2].?;
    fn2.completed(1);
    fn2.completed(0);
    try testing.expect(m.lapic.next() == null);
    const pba = m.bus.functions[2].?.bar + msix_pba_at;
    try testing.expectEqual(@as(u64, 0b110), try g.load(u64, pba));
    // Unmasked, both go, and the pending bits clear (§6.8.2.10).
    g.cfgWrite16(2, f.msix_cap + 2, control & ~@as(u16, 0x4000));
    try testing.expectEqual(@as(u64, 0), try g.load(u64, pba));
    try testing.expectEqual(@as(?u8, 0x52), m.lapic.next()); // the higher vector first
    m.lapic.write(0x0B0, 0, 0);
    try testing.expectEqual(@as(?u8, 0x51), m.lapic.next());
}

test "an entry's own mask holds only its own message" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    const f = try msixReady(&m, &g, 2);
    _ = try setVector(&g, f, 0, 1);
    _ = try setVector(&g, f, 1, 2);
    try g.store(u32, f.msix_entry.? + 16 + 12, 1); // entry 1 masked
    const fn2 = &m.bus.functions[2].?;
    fn2.completed(0);
    fn2.completed(1);
    try testing.expectEqual(@as(?u8, 0x52), m.lapic.next());
    m.lapic.write(0x0B0, 0, 0);
    try testing.expect(m.lapic.next() == null);
    try g.store(u32, f.msix_entry.? + 16 + 12, 0);
    try testing.expectEqual(@as(?u8, 0x51), m.lapic.next());
}

test "an entry written by QWORDs: the address in one, the data and the unmask in another" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    var f = g.open(3).?;
    const st = (try g.negotiate(f, 0)).?;
    try g.prepareMsix(&f);
    const q = try g.setupQueue(f, 0);
    try g.driverOk(f, st);
    // §6.8.2: an aligned QWORD is a legal access to the table.
    try g.store(u64, f.msix_entry.?, apic.base);
    try g.store(u64, f.msix_entry.? + 8, 0x0000_0000_0000_0046);
    try testing.expectEqual(@as(u64, 0x46), try g.load(u64, f.msix_entry.? + 8));
    try g.offer(q.doorbell, 0, 0);
    try testing.expectEqual(@as(?u8, 0x46), m.lapic.next());
}

test "vector control's reserved bits read zero, and the pending bits cannot be written" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    const f = try msixReady(&m, &g, 2);
    try g.store(u32, f.msix_entry.? + 12, 0xFFFF_FFFF);
    try testing.expectEqual(@as(u32, 1), try g.load(u32, f.msix_entry.? + 12));
    const pba = m.bus.functions[2].?.bar + msix_pba_at;
    try g.store(u64, pba, 0xFF);
    try testing.expectEqual(@as(u64, 0), try g.load(u64, pba));
}

test "a reset forgets a message held for an event it undid" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    var f = g.open(3).?;
    _ = (try g.negotiate(f, 0)).?;
    try g.prepareMsix(&f);
    const q = try g.setupQueue(f, 0);
    try g.offer(q.doorbell, 0, 0); // entry 0 is still masked: held
    try testing.expectEqual(@as(u64, 1), m.bus.functions[3].?.msix.pending);
    _ = (try g.negotiate(f, 0)).?; // which resets first
    try testing.expectEqual(@as(u64, 0), m.bus.functions[3].?.msix.pending);
    try g.route(f, FakeGuest.wake_vector);
    try testing.expect(m.lapic.next() == null);
}

test "a message reaches this APIC only if it is for this APIC, and asks for a vector" {
    // SDM §11.11.1-2: destination 0 or all (0xFF), physically; fixed or
    // lowest-priority delivery.
    try testing.expectEqual(@as(?u8, 0x40), apic.messageVector(0xFEE0_0000, 0x40));
    try testing.expectEqual(@as(?u8, 0x40), apic.messageVector(0xFEEF_F000, 0x40));
    try testing.expectEqual(@as(?u8, 0x40), apic.messageVector(0xFEE0_0000, 0x140));
    try testing.expectEqual(@as(?u8, null), apic.messageVector(0xFEE0_1000, 0x40)); // APIC 1
    try testing.expectEqual(@as(?u8, null), apic.messageVector(0xFEE0_000C, 0x40)); // logical
    try testing.expectEqual(@as(?u8, 0x40), apic.messageVector(0xFEE0_0004, 0x40)); // DM without RH: physical
    try testing.expectEqual(@as(?u8, null), apic.messageVector(0xFEE0_0000, 0x440)); // NMI
    try testing.expectEqual(@as(?u8, null), apic.messageVector(0xFEE0_0000, 0x740)); // ExtINT
    try testing.expectEqual(@as(?u8, null), apic.messageVector(0xC000_0000, 0x40)); // ordinary memory
    try testing.expectEqual(@as(?u8, null), apic.messageVector(0x1_FEE0_0000, 0x40));
}

test "a message nothing here takes is counted, not delivered" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    const f = try msixReady(&m, &g, 2);
    try g.store(u32, f.msix_entry.?, 0xFEE0_1000); // APIC 1
    _ = try setVector(&g, f, 0, 0);
    m.bus.functions[2].?.completed(0);
    try testing.expect(m.lapic.next() == null);
    try testing.expectEqual(@as(u64, 1), m.bus.functions[2].?.msix.unheard);
}

test "an MSI-X message is a memory write: held while bus mastering is off" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    _ = try g.bringUp(virtio.device_id_entropy, 0, 0);
    g.cfgWrite16(3, 0x04, 0x0002);
    m.bus.functions[3].?.completed(0);
    try testing.expect(m.lapic.next() == null);
    try testing.expectEqual(@as(u64, 1), m.bus.functions[3].?.msix.pending);
    g.cfgWrite16(3, 0x04, 0x0006);
    try testing.expectEqual(@as(?u8, FakeGuest.wake_vector), m.lapic.next());
}

test "an access that begins in the MSI-X table or its pending bits and runs past their end" {
    // Found by fuzz.zig, seed 135: a QWORD read at the last byte of the
    // pending bits read a dword past them, with a shift past 63.
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    _ = g.open(2).?;
    const b = m.bus.functions[2].?.bar;
    try testing.expectEqual(@as(u64, 0), try g.load(u64, b + msix_pba_at + 7));
    try testing.expectEqual(@as(u64, 0), try g.load(u64, b + msix_table_at + msix_table_bytes - 1) >> 8);
    // The low dword lands on the last entry's vector control; the high one
    // is past the table, and goes nowhere.
    try g.store(u64, b + msix_table_at + msix_table_bytes - 4, 0xFFFF_FFFF_0000_0001);
    try testing.expectEqual(@as(u32, 1), m.bus.functions[2].?.msix.table[msix_entries - 1].control);
}
