//! **THE SAME DEVICES, ON A PCI BUS.** A droplet's network card and disks are
//! virtio on PCI, and gopher-metal only lets its machine halt between frames
//! when its card is there: an MSI-X message is what wakes it. So to run the
//! code a droplet runs, this machine can present its devices as a PC does
//! (`TRANSPORT=pci`), and the guest, which asks a PCI bus when there is one
//! and never mixes the two, finds them nowhere else.
//!
//! What is here, and no more than the guest reads:
//!   - configuration mechanism #1, ports 0xCF8/0xCFC, bus 0 only;
//!   - a host bridge in slot 0, which is how the guest learns there is a bus;
//!   - each `virtio.Device` in a slot of its own, as a modern-only virtio-pci
//!     function (device id 0x1040 + type), with one 32-bit memory BAR that
//!     holds its four virtio windows and its MSI-X table;
//!   - MSI-X (PCI 3.0 §6.8.2): a table with an entry for configuration
//!     changes and one per queue, its pending bits, the function's mask and
//!     each entry's, delivered to apic.zig.
//!
//! The devices themselves are the ones the mmio window serves: only the
//! registers in front of them differ. PCI 3.0 §3.2.2.3.2 and §6.8.2; virtio
//! 1.2 §4.1.

const std = @import("std");
const virtio = @import("virtio.zig");
const apic = @import("apic.zig");
const net = @import("net.zig");
const entropy = @import("entropy.zig");
const testing = std.testing;
const virtio_pci = @import("virtio_pci.zig");
const msix_zig = @import("msix.zig");
const msix = msix_zig;
pub const Function = virtio_pci.Function;
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
const no_vector = virtio_pci.no_vector;
const msix_entries = virtio_pci.msix_entries;
const msix_table_bytes = virtio_pci.msix_table_bytes;
const Entry = virtio_pci.Entry;
const completedThunk = virtio_pci.completedThunk;
const nothing = virtio_pci.nothing;
const read32 = virtio_pci.read32;
const write16 = virtio_pci.write16;
const FakeGuest = virtio_pci.FakeGuest;
const Machine = virtio_pci.Machine;
const msixReady = msix_zig.msixReady;
const setVector = msix_zig.setVector;

pub const address_port: u16 = 0xCF8;
pub const data_port: u16 = 0xCFC;

pub fn isPort(port: u16) bool {
    return port >= address_port and port < data_port + 4;
}

/// Where the BARs go: well above RAM and below the APIC, 64 KiB a slot. This
/// is the firmware's placement; a guest may move a BAR (§6.2.5.1).
pub const bar_base: u64 = 0xC000_0000;
pub const bar_size: u64 = 0x1_0000;

// The command register's bits a function here has (§6.2.2): memory space,
// bus master, and interrupt disable. With no I/O BAR, I/O space is
// hardwired to 0, and so is every bit for an error it never reports.
pub const command_memory: u16 = 1 << 1;
pub const command_bus_master: u16 = 1 << 2;
pub const command_writable: u16 = command_memory | command_bus_master | (1 << 10);

// Inside each BAR.
pub const slots = 8;

pub const Bus = struct {
    /// The last address written to 0xCF8.
    address: u32 = 0,
    functions: [slots]?Function = @splat(null),

    /// Puts a device in `slot` (1 and up: 0 is the host bridge).
    pub fn plug(self: *Bus, slot: usize, device: *virtio.Device, lapic: *apic.Apic) *Function {
        std.debug.assert(slot >= 1 and slot < slots);
        self.functions[slot] = .{ .device = device, .bar = bar_base + slot * bar_size, .apic = lapic };
        const f = &self.functions[slot].?;
        device.completion = .{ .context = f, .done = completedThunk };
        device.may_dma = false; // until the driver sets bus master
        return f;
    }

    /// The function the address register names, if the guest named one that is
    /// there; `bridge` for slot 0.
    fn selected(self: *Bus) union(enum) { none, bridge, function: *Function } {
        if (self.address & 0x8000_0000 == 0) return .none;
        const bus = (self.address >> 16) & 0xFF;
        const slot = (self.address >> 11) & 0x1F;
        const function = (self.address >> 8) & 0x7;
        if (bus != 0 or function != 0) return .none;
        if (slot == 0) return .bridge;
        if (slot >= slots) return .none;
        if (self.functions[slot]) |*f| return .{ .function = f };
        return .none;
    }

    fn configDword(self: *Bus) u32 {
        const register: u8 = @truncate(self.address & 0xFC);
        return switch (self.selected()) {
            // **AN EMPTY SLOT READS ALL ONES**, vendor included.
            .none => 0xFFFF_FFFF,
            // An Intel host bridge (Q35's), so the guest knows there is a bus:
            // header type 0, one function, and the rest zero.
            .bridge => switch (register) {
                0x00 => 0x8086 | (0x29C0 << 16),
                0x08 => 0x06_00_00 << 8,
                else => 0,
            },
            .function => |f| f.config(register),
        };
    }

    /// **A PORT ACCESS AT ANY OFFSET AND WIDTH.** The address register is a
    /// whole dword at 0xCF8 and nothing narrower (§3.2.2.3.2). The data
    /// register is four ports, 0xCFC-0xCFF, each one byte of the dword the
    /// address names; an access that runs past 0xCFF reaches ports nothing
    /// here decodes, which read all ones and swallow writes. So `inl $0xCFD`
    /// is three bytes of configuration space and one of nothing.
    pub fn out(self: *Bus, port: u16, bytes: []const u8) void {
        if (port == address_port and bytes.len == 4) {
            self.address = std.mem.readInt(u32, bytes[0..4], .little);
            return;
        }
        var value: u32 = 0;
        var mask: u32 = 0;
        for (bytes, 0..) |b, i| {
            const at = dataByte(port, i) orelse continue;
            value |= @as(u32, b) << at;
            mask |= @as(u32, 0xFF) << at;
        }
        if (mask == 0) return;
        const f = switch (self.selected()) {
            .function => |f| f,
            else => return,
        };
        f.configWrite(@truncate(self.address & 0xFC), value, mask);
    }

    pub fn in(self: *Bus, port: u16, bytes: []u8) void {
        if (port == address_port and bytes.len == 4) {
            std.mem.writeInt(u32, bytes[0..4], self.address, .little);
            return;
        }
        const dword = self.configDword();
        for (bytes, 0..) |*b, i| {
            const at = dataByte(port, i) orelse {
                b.* = 0xFF;
                continue;
            };
            b.* = @truncate(dword >> at);
        }
    }

    /// Where byte `i` of an access at `port` falls in the data register's
    /// dword, as a shift; null when it is not one of its four ports.
    fn dataByte(port: u16, i: usize) ?u5 {
        const p = @as(usize, port) + i;
        if (p < data_port or p >= data_port + 4) return null;
        return @intCast((p - data_port) * 8);
    }

    /// **AN ACCESS TO SOME FUNCTION'S BAR**, wherever the guest put it, if
    /// its memory decoding is on (§6.2.2); false when nothing here holds
    /// `addr`. The firmware's range reads all ones where nothing decodes, as
    /// an access nobody claims does on a PC.
    pub fn memory(self: *Bus, ram: []u8, addr: u64, is_write: bool, data: []u8) bool {
        for (&self.functions) |*slot| {
            const f = if (slot.*) |*f| f else continue;
            if (f.command & command_memory == 0) continue;
            if (addr < f.bar or addr >= f.bar + bar_size) continue;
            const offset = addr - f.bar;
            if (is_write) {
                var value: u64 = 0;
                for (data, 0..) |b, i| value |= @as(u64, b) << @intCast(i * 8);
                f.write(ram, offset, @intCast(data.len), value);
            } else {
                const value = f.read(offset, @intCast(data.len));
                for (data, 0..) |*b, i| b.* = @truncate(value >> @intCast(i * 8));
            }
            return true;
        }
        if (addr < bar_base or addr >= bar_base + slots * bar_size) return false;
        if (!is_write) @memset(data, 0xFF);
        return true;
    }
};

test "a bridge in slot 0, a virtio net card in slot 1, and nothing in slot 2" {
    var bus = Bus{};
    var lapic = apic.Apic{};
    var context: u8 = 0;
    var d = virtio.Device{ .id = virtio.device_id_net, .context = &context, .notified = nothing };
    _ = bus.plug(1, &d, &lapic);
    try testing.expectEqual(@as(u32, 0x29C0_8086), read32(&bus, 0, 0));
    try testing.expectEqual(@as(u32, 0x1041_1AF4), read32(&bus, 1, 0));
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), read32(&bus, 2, 0));
    try testing.expectEqual(@as(u32, 0xC001_0000), read32(&bus, 1, 0x10));
}

pub fn cfgWrite32(g: *FakeGuest, slot: u8, register: u8, value: u32) void {
    var addr: [4]u8 = undefined;
    std.mem.writeInt(u32, &addr, 0x8000_0000 | (@as(u32, slot) << 11) | register, .little);
    g.bus.out(address_port, &addr);
    var data: [4]u8 = undefined;
    std.mem.writeInt(u32, &data, value, .little);
    g.bus.out(data_port, &data);
}

test "sizing a BAR: all ones written, the size read back, the address restored" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    // §6.2.5.1, as firmware does it, with decoding off.
    const was = g.cfgRead32(2, 0x10);
    cfgWrite32(&g, 2, 0x10, 0xFFFF_FFFF);
    const sized = g.cfgRead32(2, 0x10);
    try testing.expectEqual(@as(u32, 0), sized & 0xF); // memory, 32-bit, not prefetchable
    try testing.expectEqual(@as(u32, bar_size), ~(sized & 0xFFFF_FFF0) +% 1);
    cfgWrite32(&g, 2, 0x10, was);
    try testing.expectEqual(was, g.cfgRead32(2, 0x10));
}

test "the BARs that are not implemented read zero, even after all ones" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    for ([_]u8{ 0x14, 0x18, 0x1C, 0x20, 0x24, 0x30 }) |r| {
        cfgWrite32(&g, 2, r, 0xFFFF_FFFF);
        try testing.expectEqual(@as(u32, 0), g.cfgRead32(2, r));
    }
}

test "a BAR moved by the guest moves the windows with it" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    const f = g.open(2).?; // memory and bus master on
    const was = g.bar(2, 0).?;
    try testing.expectEqual(@as(u8, 0), try g.load(u8, f.common + 0x14));
    cfgWrite32(&g, 2, 0x10, 0xD000_0000);
    try testing.expectEqual(@as(?u64, 0xD000_0000), g.bar(2, 0));
    // The device answers at its new place, and not at its old one.
    try g.store(u8, 0xD000_0000 + common_at + 0x14, 1);
    try testing.expectEqual(@as(u8, 1), try g.load(u8, 0xD000_0000 + common_at + 0x14));
    try testing.expectEqual(@as(u8, 0xFF), try g.load(u8, was + common_at + 0x14));
}

test "with memory space off, the BAR decodes nothing" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    const f = g.open(2).?;
    try g.store(u8, f.common + 0x14, 1);
    g.cfgWrite16(2, 0x04, 0x0004); // bus master only
    try testing.expectEqual(@as(u8, 0xFF), try g.load(u8, f.common + 0x14));
    try g.store(u8, f.common + 0x14, 3); // swallowed
    g.cfgWrite16(2, 0x04, 0x0006);
    try testing.expectEqual(@as(u8, 1), try g.load(u8, f.common + 0x14));
}

test "the command register keeps only the bits a function here has" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    g.cfgWrite16(2, 0x04, 0xFFFF);
    // §6.2.2: I/O space is hardwired to 0 with no I/O BAR; memory, bus
    // master and interrupt disable are kept.
    try testing.expectEqual(@as(u16, 0x0406), g.cfgRead16(2, 0x04));
}

test "header type 0, one function: the others in the slot are not there" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    for ([_]u8{ 0, 2 }) |slot| {
        try testing.expectEqual(@as(u8, 0), g.cfgRead8(slot, 0x0E)); // §6.2.1
    }
    var addr: [4]u8 = undefined;
    std.mem.writeInt(u32, &addr, 0x8000_0000 | (2 << 11) | (1 << 8), .little);
    m.bus.out(address_port, &addr);
    var data: [4]u8 = undefined;
    m.bus.in(data_port, &data);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), std.mem.readInt(u32, &data, .little));
}

test "read-only registers keep their values, and unimplemented ones read zero" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    const id = g.cfgRead32(2, 0x00);
    const class = g.cfgRead32(2, 0x08);
    cfgWrite32(&g, 2, 0x00, 0);
    cfgWrite32(&g, 2, 0x08, 0);
    cfgWrite32(&g, 2, 0x34, 0);
    try testing.expectEqual(id, g.cfgRead32(2, 0x00));
    try testing.expectEqual(class, g.cfgRead32(2, 0x08));
    try testing.expectEqual(@as(u8, cap_common), g.cfgRead8(2, 0x34));
    // §6.1: reserved and unimplemented registers read zero.
    for ([_]u8{ 0x28, 0x38, 0x3C, 0xA0, 0xFC }) |r| try testing.expectEqual(@as(u32, 0), g.cfgRead32(2, r));
    for ([_]u8{ 0x04, 0x10, 0x2C, 0x34, 0x3C, 0xFC }) |r| try testing.expectEqual(@as(u32, 0), g.cfgRead32(0, r));
}

test "the data ports at every offset and width, the unaligned ones included" {
    var bus = Bus{};
    var lapic = apic.Apic{};
    var context: u8 = 0;
    var d = virtio.Device{ .id = virtio.device_id_net, .context = &context, .notified = nothing };
    _ = bus.plug(1, &d, &lapic);
    var addr: [4]u8 = undefined;
    std.mem.writeInt(u32, &addr, 0x8000_0000 | (1 << 11), .little); // vendor and device
    bus.out(address_port, &addr);
    const dword: u32 = 0x1041_1AF4;
    for ([_]usize{ 1, 2, 4 }) |width| {
        for (0..8) |k| {
            const port: u16 = address_port + @as(u16, @intCast(k));
            var got: [4]u8 = undefined;
            bus.in(port, got[0..width]);
            for (0..width) |i| {
                const p = port + i;
                const want: u8 = if (port == address_port and width == 4)
                    @truncate(@as(u32, 0x8000_0800) >> @intCast(i * 8))
                else if (p >= data_port and p < data_port + 4)
                    @truncate(dword >> @intCast((p - data_port) * 8))
                else
                    0xFF;
                try testing.expectEqual(want, got[i]);
            }
            // A write anywhere leaves the address register as it was, unless
            // it is the whole dword at 0xCF8.
            if (!(port == address_port and width == 4)) bus.out(port, got[0..width]);
            try testing.expectEqual(@as(u32, 0x8000_0800), bus.address);
        }
    }
}

test "an unaligned write lands only on the bytes of the data register it covers" {
    var bus = Bus{};
    var lapic = apic.Apic{};
    var context: u8 = 0;
    var d = virtio.Device{ .id = virtio.device_id_net, .context = &context, .notified = nothing };
    const f = bus.plug(1, &d, &lapic);
    var addr: [4]u8 = undefined;
    std.mem.writeInt(u32, &addr, 0x8000_0000 | (1 << 11) | 0x04, .little); // command
    bus.out(address_port, &addr);
    // Four bytes at 0xCFB: one before the data register, three in it. The
    // command register is the first two: 0x06 lands, the rest is status.
    bus.out(data_port - 1, &.{ 0xAA, 0x06, 0x00, 0xFF });
    try testing.expectEqual(@as(u16, 0x0006), f.command);
    try testing.expectEqual(@as(u32, 0x8000_0804), bus.address);
}
