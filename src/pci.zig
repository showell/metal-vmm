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
//!   - MSI-X with one table entry, delivered to apic.zig.
//!
//! The devices themselves are the ones the mmio window serves: only the
//! registers in front of them differ. PCI 3.0 §3.2.2.3.2 and §6.8.2; virtio
//! 1.2 §4.1.

const std = @import("std");
const virtio = @import("virtio.zig");
const apic = @import("apic.zig");

pub const address_port: u16 = 0xCF8;
pub const data_port: u16 = 0xCFC;

pub fn isPort(port: u16) bool {
    return port >= address_port and port < data_port + 4;
}

/// Where the BARs go: well above RAM and below the APIC, 64 KiB a slot.
const bar_base: u64 = 0xC000_0000;
const bar_size: u64 = 0x1_0000;

// Inside each BAR.
const common_at = 0x0000;
const common_len = 0x38;
const isr_at = 0x1000;
const device_at = 0x2000;
const device_len = 0x100;
const notify_at = 0x3000;
const notify_len = 0x1000;
const notify_multiplier = 4;
const msix_table_at = 0x4000;
const msix_pba_at = 0x5000;

// The capability list, at fixed places in configuration space.
const cap_common = 0x40;
const cap_isr = 0x50;
const cap_device = 0x60;
const cap_notify = 0x70;
const cap_msix = 0x88;

const no_vector: u16 = 0xFFFF;

/// One virtio device in a slot.
pub const Function = struct {
    device: *virtio.Device,
    bar: u64,
    command: u16 = 0,
    /// Message Control: bit 15 enables MSI-X, bit 14 masks the function.
    msix_control: u16 = 0,
    /// The one table entry: address, data, and vector control (bit 0 masks).
    msix_address: u64 = 0,
    msix_data: u32 = 0,
    msix_masked: bool = true,
    /// A message the entry could not send while masked, sent on unmasking.
    msix_pending: bool = false,
    msix_config: u16 = no_vector,
    queue_vector: [2]u16 = .{ no_vector, no_vector },
    /// Messages sent, for a run's closing account.
    messages: u64 = 0,
    /// Where its messages go: this machine's one APIC.
    apic: ?*apic.Apic = null,

    fn classCode(self: *const Function) u32 {
        return switch (self.device.id) {
            virtio.device_id_net => 0x02_00_00, // network, ethernet
            virtio.device_id_block => 0x01_00_00, // mass storage, SCSI-ish
            else => 0xFF_00_00, // unclassified
        };
    }

    /// One aligned dword of configuration space.
    fn config(self: *const Function, register: u8) u32 {
        return switch (register) {
            0x00 => 0x1AF4 | (@as(u32, 0x1040 + @as(u16, @intCast(self.device.id))) << 16),
            0x04 => self.command | (@as(u32, 0x0010) << 16), // status: capabilities
            0x08 => 0x01 | (self.classCode() << 8), // revision 1, modern
            0x0C => 0, // header type 0, one function
            0x10 => @intCast(self.bar), // memory, 32-bit, not prefetchable
            0x2C => 0x1AF4 | (@as(u32, @intCast(self.device.id)) << 16),
            0x34 => cap_common,
            // struct virtio_pci_cap: vndr, next, len, cfg_type | bar, id, pad | offset | length
            cap_common => vendorCap(cap_isr, 16, 1),
            cap_common + 4 => 0,
            cap_common + 8 => common_at,
            cap_common + 12 => common_len,
            cap_isr => vendorCap(cap_device, 16, 3),
            cap_isr + 4 => 0,
            cap_isr + 8 => isr_at,
            cap_isr + 12 => 4,
            cap_device => vendorCap(cap_notify, 16, 4),
            cap_device + 4 => 0,
            cap_device + 8 => device_at,
            cap_device + 12 => device_len,
            cap_notify => vendorCap(cap_msix, 20, 2),
            cap_notify + 4 => 0,
            cap_notify + 8 => notify_at,
            cap_notify + 12 => notify_len,
            cap_notify + 16 => notify_multiplier,
            // MSI-X: id, next (none), message control (table size 1, so 0);
            // then the table's and the pending bits' offsets, in BAR 0.
            cap_msix => 0x11 | (@as(u32, self.msix_control) << 16),
            cap_msix + 4 => msix_table_at,
            cap_msix + 8 => msix_pba_at,
            else => 0,
        };
    }

    fn vendorCap(next: u8, len: u8, cfg_type: u8) u32 {
        return 0x09 | (@as(u32, next) << 8) | (@as(u32, len) << 16) | (@as(u32, cfg_type) << 24);
    }

    fn configWrite(self: *Function, register: u8, value: u32, mask: u32) void {
        switch (register) {
            0x04 => self.command = @truncate((self.command & ~mask) | (value & mask)),
            cap_msix => if (mask & 0xFFFF_0000 != 0) {
                const was = self.msix_control;
                self.msix_control = @truncate((value & mask) >> 16);
                if (was != self.msix_control) self.flush();
            },
            else => {}, // BARs are placed here, not by the guest
        }
    }

    // ── the BAR ──────────────────────────────────────────────────────────────

    fn read(self: *Function, offset: u64, len: u32) u64 {
        if (offset < common_at + common_len) return self.commonRead(offset, len);
        if (offset == isr_at) {
            // Reading the ISR is its acknowledgement (virtio §4.1.4.5).
            const v = self.device.interrupt_status;
            self.device.interrupt_status = 0;
            return v;
        }
        if (offset >= device_at and offset < device_at + device_len)
            return self.device.read(0x100 + (offset - device_at), len);
        if (offset >= msix_table_at and offset < msix_table_at + 16) return switch (offset - msix_table_at) {
            0 => @truncate(self.msix_address),
            4 => self.msix_address >> 32,
            8 => self.msix_data,
            12 => @intFromBool(self.msix_masked),
            else => 0,
        };
        if (offset == msix_pba_at) return @intFromBool(self.msix_pending);
        return 0;
    }

    fn write(self: *Function, ram: []u8, offset: u64, len: u32, value: u64) void {
        if (offset < common_at + common_len) return self.commonWrite(ram, offset, len, value);
        if (offset >= notify_at and offset < notify_at + notify_len) {
            const queue: u32 = @intCast((offset - notify_at) / notify_multiplier);
            if (queue < self.device.queues.len) self.device.notified(self.device.context, self.device, ram, queue);
            return;
        }
        if (offset >= msix_table_at and offset < msix_table_at + 16) {
            switch (offset - msix_table_at) {
                0 => self.msix_address = (self.msix_address & 0xFFFF_FFFF_0000_0000) | (value & 0xFFFF_FFFF),
                4 => self.msix_address = (self.msix_address & 0xFFFF_FFFF) | (value << 32),
                8 => self.msix_data = @truncate(value),
                12 => {
                    self.msix_masked = value & 1 != 0;
                    self.flush();
                },
                else => {},
            }
        }
    }

    /// The common configuration (virtio §4.1.4.3), each field at its width.
    fn commonRead(self: *Function, offset: u64, len: u32) u64 {
        const d = self.device;
        const q = &d.queues[@min(d.queue_sel, d.queues.len - 1)];
        const sel = @min(d.queue_sel, d.queues.len - 1);
        var image: [common_len]u8 = @splat(0);
        std.mem.writeInt(u32, image[0x00..0x04], d.device_features_sel, .little);
        std.mem.writeInt(u32, image[0x04..0x08], switch (d.device_features_sel) {
            0 => d.features_low,
            1 => virtio.feature_version_1_high,
            else => 0,
        }, .little);
        std.mem.writeInt(u32, image[0x08..0x0C], d.driver_features_sel, .little);
        std.mem.writeInt(u16, image[0x10..0x12], self.msix_config, .little);
        std.mem.writeInt(u16, image[0x12..0x14], @intCast(d.queues.len), .little);
        image[0x14] = @truncate(d.status);
        std.mem.writeInt(u16, image[0x16..0x18], @truncate(d.queue_sel), .little);
        // Zero would be "no such queue"; the maximum until the driver picks.
        std.mem.writeInt(u16, image[0x18..0x1A], @intCast(if (q.size != 0) q.size else virtio.queue_max), .little);
        std.mem.writeInt(u16, image[0x1A..0x1C], self.queue_vector[sel], .little);
        std.mem.writeInt(u16, image[0x1C..0x1E], @truncate(q.ready), .little);
        std.mem.writeInt(u16, image[0x1E..0x20], @intCast(sel), .little);
        std.mem.writeInt(u64, image[0x20..0x28], q.desc, .little);
        std.mem.writeInt(u64, image[0x28..0x30], q.avail, .little);
        std.mem.writeInt(u64, image[0x30..0x38], q.used, .little);
        const at: usize = @intCast(offset);
        var value: u64 = 0;
        for (0..@min(len, common_len - at)) |i| value |= @as(u64, image[at + i]) << @intCast(i * 8);
        return value;
    }

    fn commonWrite(self: *Function, ram: []u8, offset: u64, len: u32, value: u64) void {
        _ = len;
        const d = self.device;
        const sel = @min(d.queue_sel, d.queues.len - 1);
        const q = &d.queues[sel];
        const v32: u32 = @truncate(value);
        switch (offset) {
            0x00 => d.device_features_sel = v32,
            0x08 => d.driver_features_sel = v32,
            0x0C => {}, // whatever it takes, it may have
            0x10 => self.msix_config = @truncate(value),
            0x14 => {
                if (v32 & 0xFF == 0) {
                    // A reset: the device as it was, vectors included.
                    d.write(ram, 0x070, 0);
                    self.queue_vector = .{ no_vector, no_vector };
                    self.msix_config = no_vector;
                } else d.write(ram, 0x070, v32 & 0xFF);
            },
            0x16 => d.queue_sel = v32 & 0xFFFF,
            0x18 => q.size = v32 & 0xFFFF,
            // One table entry: vector 0 is taken, any other is NO_VECTOR.
            0x1A => self.queue_vector[sel] = if (v32 & 0xFFFF == 0) 0 else no_vector,
            0x1C => q.ready = v32 & 0xFFFF,
            0x20 => q.desc = (q.desc & 0xFFFF_FFFF_0000_0000) | (value & 0xFFFF_FFFF),
            0x24 => q.desc = (q.desc & 0xFFFF_FFFF) | (value << 32),
            0x28 => q.avail = (q.avail & 0xFFFF_FFFF_0000_0000) | (value & 0xFFFF_FFFF),
            0x2C => q.avail = (q.avail & 0xFFFF_FFFF) | (value << 32),
            0x30 => q.used = (q.used & 0xFFFF_FFFF_0000_0000) | (value & 0xFFFF_FFFF),
            0x34 => q.used = (q.used & 0xFFFF_FFFF) | (value << 32),
            else => {},
        }
    }

    // ── interrupts ───────────────────────────────────────────────────────────

    /// **THE DEVICE FINISHED SOMETHING ON `queue`.** Without MSI-X that is the
    /// ISR's bit, which the guest polls; with it, the queue's vector's
    /// message — held while masked, and sent when it is not.
    pub fn completed(self: *Function, queue: u32) void {
        self.device.interrupt_status |= 1;
        if (self.msix_control & 0x8000 == 0) return;
        if (queue >= self.queue_vector.len or self.queue_vector[queue] != 0) return;
        self.msix_pending = true;
        self.flush();
    }

    /// Sends the held message, if anything now lets it go.
    fn flush(self: *Function) void {
        if (!self.msix_pending) return;
        if (self.msix_control & 0x8000 == 0 or self.msix_control & 0x4000 != 0 or self.msix_masked) return;
        self.msix_pending = false;
        self.messages += 1;
        // Only this machine's one APIC listens; a message aimed anywhere else
        // goes nowhere, as on a PC.
        if (apic.inWindow(self.msix_address)) self.apic.?.raise(@truncate(self.msix_data));
    }
};

fn completedThunk(context: *anyopaque, queue: u32) void {
    const f: *Function = @ptrCast(@alignCast(context));
    f.completed(queue);
}

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
            // An Intel host bridge (Q35's), so the guest knows there is a bus.
            .bridge => switch (register) {
                0x00 => 0x8086 | (0x29C0 << 16),
                0x08 => 0x06_00_00 << 8,
                else => 0,
            },
            .function => |f| f.config(register),
        };
    }

    pub fn out(self: *Bus, port: u16, bytes: []const u8) void {
        if (port == address_port and bytes.len == 4) {
            self.address = std.mem.readInt(u32, bytes[0..4], .little);
            return;
        }
        if (port < data_port) return;
        const f = switch (self.selected()) {
            .function => |f| f,
            else => return,
        };
        const shift: u5 = @intCast((port - data_port) * 8);
        var value: u32 = 0;
        var mask: u32 = 0;
        for (bytes, 0..) |b, i| {
            const at: u5 = @intCast(i * 8);
            value |= @as(u32, b) << (shift + at);
            mask |= @as(u32, 0xFF) << (shift + at);
        }
        f.configWrite(@truncate(self.address & 0xFC), value, mask);
    }

    pub fn in(self: *Bus, port: u16, bytes: []u8) void {
        if (port == address_port and bytes.len == 4) {
            std.mem.writeInt(u32, bytes[0..4], self.address, .little);
            return;
        }
        if (port < data_port) return @memset(bytes, 0xFF);
        const dword = self.configDword();
        const shift: u5 = @intCast((port - data_port) * 8);
        for (bytes, 0..) |*b, i| b.* = @truncate(dword >> (shift + @as(u5, @intCast(i * 8))));
    }

    /// An access to some function's BAR; false when none holds `addr`.
    pub fn memory(self: *Bus, ram: []u8, addr: u64, is_write: bool, data: []u8) bool {
        if (addr < bar_base or addr >= bar_base + slots * bar_size) return false;
        const slot: usize = @intCast((addr - bar_base) / bar_size);
        const f = if (self.functions[slot]) |*f| f else return false;
        // A function whose memory decoding is off answers nothing (§6.2.2).
        if (f.command & 0x2 == 0) {
            if (!is_write) @memset(data, 0xFF);
            return true;
        }
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
};

// ── what can be checked without a processor ──────────────────────────────────

const testing = std.testing;

fn nothing(_: *anyopaque, _: *virtio.Device, _: []u8, _: u32) void {}

/// The guest's own reads, through the two ports.
fn read32(bus: *Bus, slot: u8, register: u8) u32 {
    var addr: [4]u8 = undefined;
    std.mem.writeInt(u32, &addr, 0x8000_0000 | (@as(u32, slot) << 11) | register, .little);
    bus.out(address_port, &addr);
    var data: [4]u8 = undefined;
    bus.in(data_port, &data);
    return std.mem.readInt(u32, &data, .little);
}

fn write16(bus: *Bus, slot: u8, register: u8, value: u16) void {
    var addr: [4]u8 = undefined;
    std.mem.writeInt(u32, &addr, 0x8000_0000 | (@as(u32, slot) << 11) | (register & 0xFC), .little);
    bus.out(address_port, &addr);
    var data: [2]u8 = undefined;
    std.mem.writeInt(u16, &data, value, .little);
    bus.out(data_port + (register & 2), &data);
}

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

test "the capability list leads to the four windows and MSI-X" {
    var bus = Bus{};
    var lapic = apic.Apic{};
    var context: u8 = 0;
    var d = virtio.Device{ .id = virtio.device_id_block, .context = &context, .notified = nothing };
    _ = bus.plug(3, &d, &lapic);
    var at: u8 = @truncate(read32(&bus, 3, 0x34));
    var kinds: [5]u8 = undefined;
    var n: usize = 0;
    while (at != 0) : (n += 1) {
        const head = read32(&bus, 3, at);
        kinds[n] = if (head & 0xFF == 0x09) @truncate(head >> 24) else @truncate(head);
        at = @truncate(head >> 8);
    }
    try testing.expectEqualSlices(u8, &.{ 1, 3, 4, 2, 0x11 }, kinds[0..n]);
}

test "MSI-X: masked, the message waits; unmasked, it reaches the APIC" {
    var bus = Bus{};
    var lapic = apic.Apic{};
    _ = lapic.writeMsr(apic.msr_apic_base, lapic.readMsr(apic.msr_apic_base).? | (1 << 11));
    lapic.write(0x0F0, 0x1FF);
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
