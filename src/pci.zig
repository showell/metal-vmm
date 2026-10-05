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

// ── the driver's whole sequence, without a processor ────────────────────────

const entropy = @import("entropy.zig");
const net = @import("net.zig");

/// **GOPHER-METAL'S DRIVER, FROM THE OTHER SIDE.** Each step is what its
/// `pci.zig` and `virtio.zig` do, at the widths they do it: configuration
/// space by `outl`/`inl` and `outw`, the common configuration by each field's
/// own width, 64-bit fields as two 32-bit stores. Its RAM holds the rings; its
/// stores to a BAR go through `Bus.memory`, as an exit would bring them.
const FakeGuest = struct {
    bus: *Bus,
    ram: [0x4000]u8 align(8) = @splat(0),

    // Where this guest keeps one queue's rings and buffers, in its RAM.
    const size: u16 = 8;
    const desc_at: u64 = 0x100;
    const avail_at: u64 = desc_at + size * @sizeOf(virtio.Desc);
    const used_at: u64 = 0x400;
    const buffer_at: u64 = 0x1000;
    const buffer_len: u32 = 0x800;

    const wake_vector: u8 = 0x40;

    /// What `pciDevice` and `prepareMsix` found.
    const Found = struct {
        slot: u8,
        common: u64,
        notify: u64,
        multiplier: u32,
        isr: u64,
        device: u64,
        msix_entry: ?u64 = null,
        msix_cap: u8 = 0,
    };

    // ── configuration space, by the two ports ──

    fn cfgRead32(self: *FakeGuest, slot: u8, register: u8) u32 {
        var addr: [4]u8 = undefined;
        std.mem.writeInt(u32, &addr, 0x8000_0000 | (@as(u32, slot) << 11) | (register & 0xFC), .little);
        self.bus.out(address_port, &addr);
        var data: [4]u8 = undefined;
        self.bus.in(data_port, &data);
        return std.mem.readInt(u32, &data, .little);
    }

    fn cfgRead16(self: *FakeGuest, slot: u8, register: u8) u16 {
        return @truncate(self.cfgRead32(slot, register) >> @intCast((register & 2) * 8));
    }

    fn cfgRead8(self: *FakeGuest, slot: u8, register: u8) u8 {
        return @truncate(self.cfgRead32(slot, register) >> @intCast((register & 3) * 8));
    }

    fn cfgWrite16(self: *FakeGuest, slot: u8, register: u8, value: u16) void {
        var addr: [4]u8 = undefined;
        std.mem.writeInt(u32, &addr, 0x8000_0000 | (@as(u32, slot) << 11) | (register & 0xFC), .little);
        self.bus.out(address_port, &addr);
        var data: [2]u8 = undefined;
        std.mem.writeInt(u16, &data, value, .little);
        self.bus.out(data_port + (register & 2), &data);
    }

    // ── a BAR, by loads and stores ──

    fn load(self: *FakeGuest, comptime T: type, addr: u64) !T {
        var data: [@sizeOf(T)]u8 = undefined;
        try testing.expect(self.bus.memory(&self.ram, addr, false, &data));
        return std.mem.readInt(T, &data, .little);
    }

    fn store(self: *FakeGuest, comptime T: type, addr: u64, value: T) !void {
        var data: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &data, value, .little);
        try testing.expect(self.bus.memory(&self.ram, addr, true, &data));
    }

    fn store64(self: *FakeGuest, addr: u64, value: u64) !void {
        try self.store(u32, addr, @truncate(value));
        try self.store(u32, addr + 4, @truncate(value >> 32));
    }

    // ── gopher-metal's pci.zig ──

    /// `Scan`: every slot of bus 0, function 0 unless the header says more;
    /// the first function whose device id names virtio `kind`.
    fn find(self: *FakeGuest, kind: u32) ?u8 {
        if (!someone(self.cfgRead16(0, 0x00))) return null; // `present`
        var slot: u8 = 0;
        while (slot < 32) : (slot += 1) {
            if (!someone(self.cfgRead16(slot, 0x00))) continue;
            if (self.cfgRead8(slot, 0x0E) & 0x80 != 0) return null; // nothing here is multi-function
            if (self.cfgRead16(slot, 0x00) != 0x1AF4) continue;
            const id = self.cfgRead16(slot, 0x02);
            if (id >= 0x1040 and id <= 0x107F and id - 0x1040 == kind) return slot;
        }
        return null;
    }

    fn someone(vendor: u16) bool {
        return vendor != 0xFFFF and vendor != 0x0000;
    }

    fn bar(self: *FakeGuest, slot: u8, index: u8) ?u64 {
        const low = self.cfgRead32(slot, 0x10 + index * 4);
        if (low & 1 != 0) return null;
        var at: u64 = low & 0xFFFF_FFF0;
        if ((low >> 1) & 3 == 2) at |= @as(u64, self.cfgRead32(slot, 0x10 + index * 4 + 4)) << 32;
        return if (at == 0) null else at;
    }

    /// `pciDevice`: the four windows from the capability list, then memory
    /// and bus mastering on (`Function.enable`).
    fn open(self: *FakeGuest, slot: u8) ?Found {
        var common: ?u64 = null;
        var notify: ?u64 = null;
        var isr: ?u64 = null;
        var device: ?u64 = null;
        var multiplier: u32 = 0;
        var msix_cap: u8 = 0;
        if (self.cfgRead16(slot, 0x06) & 0x10 == 0) return null;
        var at = self.cfgRead8(slot, 0x34) & 0xFC;
        var seen: u8 = 0;
        while (at != 0 and seen < 48) : (seen += 1) {
            const id = self.cfgRead8(slot, at);
            const next = self.cfgRead8(slot, at + 1) & 0xFC;
            if (id == 0x11) msix_cap = at;
            if (id == 0x09) {
                const window = (self.bar(slot, self.cfgRead8(slot, at + 4)) orelse return null) + self.cfgRead32(slot, at + 8);
                switch (self.cfgRead8(slot, at + 3)) {
                    1 => common = common orelse window,
                    2 => if (notify == null) {
                        notify = window;
                        multiplier = self.cfgRead32(slot, at + 16);
                    },
                    3 => isr = isr orelse window,
                    4 => device = device orelse window,
                    else => {},
                }
            }
            at = next;
        }
        self.cfgWrite16(slot, 0x04, self.cfgRead16(slot, 0x04) | 0x0006);
        return .{
            .slot = slot,
            .common = common orelse return null,
            .notify = notify orelse return null,
            .multiplier = multiplier,
            .isr = isr orelse return null,
            .device = device orelse return null,
            .msix_cap = msix_cap,
        };
    }

    // ── gopher-metal's virtio.zig ──

    /// `negotiate`: reset and wait for it, ACKNOWLEDGE, DRIVER, VERSION_1 and
    /// `want_low`, FEATURES_OK read back. The status so far, or null where
    /// the driver would have given up.
    fn negotiate(self: *FakeGuest, f: Found, want_low: u32) !?u8 {
        try self.store(u8, f.common + 0x14, 0);
        var spins: usize = 0;
        while (try self.load(u8, f.common + 0x14) != 0) : (spins += 1) if (spins == 1000) return null;
        var st: u8 = 1;
        try self.store(u8, f.common + 0x14, st);
        st |= 2;
        try self.store(u8, f.common + 0x14, st);
        try self.store(u32, f.common + 0x00, 1);
        if (try self.load(u32, f.common + 0x04) & 1 == 0) return null; // VERSION_1
        try self.store(u32, f.common + 0x00, 0);
        if (try self.load(u32, f.common + 0x04) & want_low != want_low) return null;
        try self.store(u32, f.common + 0x08, 1);
        try self.store(u32, f.common + 0x0C, 1);
        try self.store(u32, f.common + 0x08, 0);
        try self.store(u32, f.common + 0x0C, want_low);
        st |= 8;
        try self.store(u8, f.common + 0x14, st);
        if (try self.load(u8, f.common + 0x14) & 8 == 0) return null;
        return st;
    }

    /// `prepareMsix`: entry 0 masked and cleared, then MSI-X on for the
    /// function, not masked as a whole.
    fn prepareMsix(self: *FakeGuest, f: *Found) !void {
        if (f.msix_cap == 0) return;
        const table = self.cfgRead32(f.slot, f.msix_cap + 4);
        const window = self.bar(f.slot, @truncate(table & 7)) orelse return;
        const entry = window + (table & ~@as(u32, 7));
        try self.store(u32, entry + 12, 1);
        try self.store(u32, entry + 0, 0);
        try self.store(u32, entry + 4, 0);
        try self.store(u32, entry + 8, 0);
        const control = self.cfgRead16(f.slot, f.msix_cap + 2);
        self.cfgWrite16(f.slot, f.msix_cap + 2, (control | 0x8000) & ~@as(u16, 0x4000));
        f.msix_entry = entry;
    }

    /// `Queue.setup` for queue `index`: its rings, its vector (entry 0, read
    /// back), enabled. The doorbell's address, and whether the vector took.
    fn setupQueue(self: *FakeGuest, f: Found, index: u16) !struct { doorbell: u64, vectored: bool } {
        try self.store(u16, f.common + 0x16, index);
        const max = try self.load(u16, f.common + 0x18);
        try testing.expect(max >= size);
        try self.store(u16, f.common + 0x18, size);
        try self.store64(f.common + 0x20, desc_at);
        try self.store64(f.common + 0x28, avail_at);
        try self.store64(f.common + 0x30, used_at);
        const off = try self.load(u16, f.common + 0x1E);
        var vectored = false;
        if (f.msix_entry != null) {
            try self.store(u16, f.common + 0x1A, 0);
            vectored = try self.load(u16, f.common + 0x1A) == 0;
        }
        try self.store(u16, f.common + 0x1C, 1);
        return .{ .doorbell = f.notify + @as(u64, off) * f.multiplier, .vectored = vectored };
    }

    /// `routeToProcessor`: entry 0 aimed at APIC 0 with `vector`, unmasked.
    fn route(self: *FakeGuest, f: Found, vector: u8) !void {
        const entry = f.msix_entry.?;
        try self.store(u32, entry + 0, @intCast(apic.base));
        try self.store(u32, entry + 4, 0);
        try self.store(u32, entry + 8, vector);
        try self.store(u32, entry + 12, 0);
    }

    fn driverOk(self: *FakeGuest, f: Found, st: u8) !void {
        try self.store(u8, f.common + 0x14, st | 4);
    }

    /// One device-writable buffer offered on the queue, and the doorbell rung
    /// as `notify` does: the queue's index, 16 bits wide.
    fn offer(self: *FakeGuest, doorbell: u64, index: u16, flags: u16) !void {
        virtio.writeInt(u64, &self.ram, desc_at, buffer_at);
        virtio.writeInt(u32, &self.ram, desc_at + 8, buffer_len);
        virtio.writeInt(u16, &self.ram, desc_at + 12, virtio.Desc.write_flag);
        const idx = virtio.readInt(u16, &self.ram, avail_at + 2);
        virtio.writeInt(u16, &self.ram, avail_at, flags);
        virtio.writeInt(u16, &self.ram, avail_at + 4 + @as(u64, idx % size) * 2, 0);
        virtio.writeInt(u16, &self.ram, avail_at + 2, idx +% 1);
        try self.store(u16, doorbell, index);
    }

    fn usedIdx(self: *FakeGuest) u16 {
        return virtio.readInt(u16, &self.ram, used_at + 2);
    }

    /// The whole bring-up, as `net.zig`/`rng.zig` call it: found, negotiated,
    /// MSI-X prepared, one queue set up, routed, DRIVER_OK.
    fn bringUp(self: *FakeGuest, kind: u32, want_low: u32, queue: u16) !struct { f: Found, doorbell: u64 } {
        var f = self.open(self.find(kind) orelse return error.NotFound) orelse return error.NoWindows;
        const st = (try self.negotiate(f, want_low)) orelse return error.Refused;
        try self.prepareMsix(&f);
        const q = try self.setupQueue(f, queue);
        try testing.expect(q.vectored);
        try self.route(f, wake_vector);
        try self.driverOk(f, st);
        return .{ .f = f, .doorbell = q.doorbell };
    }
};

/// The PC-shaped machine's three devices in main.zig's slots, and its APIC
/// as gopher-metal's `startApic` leaves it.
const Machine = struct {
    bus: Bus = .{},
    lapic: apic.Apic = .{},
    block_context: u8 = 0,
    block: virtio.Device = undefined,
    card: net.Net = .{},
    card_device: virtio.Device = undefined,
    dice: entropy.Entropy = .{},
    dice_device: virtio.Device = undefined,

    fn init(self: *Machine) void {
        self.block = .{ .id = virtio.device_id_block, .context = &self.block_context, .notified = nothing };
        self.card_device = self.card.device();
        self.dice_device = self.dice.device();
        _ = self.bus.plug(1, &self.block, &self.lapic);
        _ = self.bus.plug(2, &self.card_device, &self.lapic);
        _ = self.bus.plug(3, &self.dice_device, &self.lapic);
        _ = self.lapic.writeMsr(apic.msr_apic_base, self.lapic.readMsr(apic.msr_apic_base).? | (1 << 11));
        self.lapic.write(0x0F0, 0x1FF);
        self.lapic.write(0x320, 0x41 | (2 << 17));
    }
};

test "the scan finds a bus, and each device by its modern id" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    // PCI 3.0 §6.1: an empty slot's vendor reads all ones; virtio 1.2
    // §4.1.2.1: a modern-only device is 0x1040 plus its type.
    try testing.expectEqual(@as(u16, 0xFFFF), g.cfgRead16(4, 0x00));
    try testing.expectEqual(@as(?u8, 1), g.find(virtio.device_id_block));
    try testing.expectEqual(@as(?u8, 2), g.find(virtio.device_id_net));
    try testing.expectEqual(@as(?u8, 3), g.find(virtio.device_id_entropy));
    try testing.expectEqual(@as(?u8, null), g.find(16)); // a GPU: not here
    // §4.1.2.1: a non-transitional device has revision 1 or more.
    try testing.expect(g.cfgRead8(2, 0x08) >= 1);
}

test "the capability list gives four windows inside the BAR, and MSI-X" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    const f = g.open(2).?;
    const b = g.bar(2, 0).?;
    for ([_]u64{ f.common, f.notify, f.isr, f.device }) |w| try testing.expect(w >= b and w < b + bar_size);
    try testing.expect(f.msix_cap != 0);
    // `enable` read the command register, set memory and bus master, and
    // they read back (§6.2.2).
    try testing.expectEqual(@as(u16, 0x0006), g.cfgRead16(2, 0x04) & 0x0006);
}

test "a reset reads back zero, and the device's fields at their own widths" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    const f = g.open(2).?;
    try g.store(u8, f.common + 0x14, 1 | 2);
    try testing.expectEqual(@as(u8, 3), try g.load(u8, f.common + 0x14));
    // virtio 1.2 §4.1.4.3.1: writing 0 resets, and the device presents 0
    // once the reset is done.
    try g.store(u8, f.common + 0x14, 0);
    try testing.expectEqual(@as(u8, 0), try g.load(u8, f.common + 0x14));
    // A selector is read back as written, at its width (§4.1.4.3).
    try g.store(u16, f.common + 0x16, 1);
    try testing.expectEqual(@as(u16, 1), try g.load(u16, f.common + 0x16));
}

test "features: VERSION_1 in the high word, the card's MAC in the low, FEATURES_OK kept" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    const f = g.open(2).?;
    const st = (try g.negotiate(f, 1 << 5)).?; // VIRTIO_NET_F_MAC
    try testing.expectEqual(@as(u8, 1 | 2 | 8), st);
}

test "MSI-X prepared: enabled, entry 0 masked, nothing sent" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    var f = g.open(3).?;
    _ = (try g.negotiate(f, 0)).?;
    try g.prepareMsix(&f);
    const control = g.cfgRead16(3, f.msix_cap + 2);
    try testing.expect(control & 0x8000 != 0); // enabled
    try testing.expect(control & 0x4000 == 0); // the function not masked
    try testing.expectEqual(@as(u32, 1), try g.load(u32, f.msix_entry.? + 12) & 1);
    try testing.expect(m.lapic.next() == null);
}

test "a queue set up takes entry 0 as its vector, and its doorbell is in the notify window" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    var f = g.open(3).?;
    _ = (try g.negotiate(f, 0)).?;
    try g.prepareMsix(&f);
    const q = try g.setupQueue(f, 0);
    try testing.expect(q.vectored);
    try testing.expect(q.doorbell >= f.notify and q.doorbell < f.notify + notify_len);
    try testing.expectEqual(@as(u16, 1), try g.load(u16, f.common + 0x1C)); // enabled
    try testing.expectEqual(@as(u64, FakeGuest.desc_at), try g.load(u64, f.common + 0x20));
}

test "a doorbell is served: the buffer comes back filled on the used ring" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    const up = try g.bringUp(virtio.device_id_entropy, 0, 0);
    try g.offer(up.doorbell, 0, 0);
    try testing.expectEqual(@as(u16, 1), g.usedIdx());
    try testing.expectEqual(FakeGuest.buffer_len, virtio.readInt(u32, &g.ram, FakeGuest.used_at + 8));
}

test "a completion is an MSI-X message, and the APIC delivers its vector until EOI" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    const up = try g.bringUp(virtio.device_id_entropy, 0, 0);
    try g.offer(up.doorbell, 0, 0);
    try testing.expectEqual(@as(?u8, FakeGuest.wake_vector), m.lapic.next());
    // In service until the handler's EOI: a second completion waits.
    try g.offer(up.doorbell, 0, 0);
    try testing.expect(m.lapic.next() == null);
    m.lapic.write(0x0B0, 0);
    try testing.expectEqual(@as(?u8, FakeGuest.wake_vector), m.lapic.next());
}

test "a completion while entry 0 is masked waits, and routing it sends it" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    var f = g.open(3).?;
    const st = (try g.negotiate(f, 0)).?;
    try g.prepareMsix(&f);
    const q = try g.setupQueue(f, 0);
    try g.driverOk(f, st);
    try g.offer(q.doorbell, 0, 0);
    try testing.expectEqual(@as(u16, 1), g.usedIdx());
    try testing.expect(m.lapic.next() == null);
    // PCI 3.0 §6.8.2.9: a masked entry's message is held in its pending
    // bit, and sent when it is unmasked.
    try testing.expectEqual(@as(u64, 1), try g.load(u64, m.bus.functions[3].?.bar + msix_pba_at) & 1);
    try g.route(f, FakeGuest.wake_vector);
    try testing.expectEqual(@as(?u8, FakeGuest.wake_vector), m.lapic.next());
    try testing.expectEqual(@as(u64, 0), try g.load(u64, m.bus.functions[3].?.bar + msix_pba_at) & 1);
}

test "a driver that asked for no interrupts on a queue gets none" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    const up = try g.bringUp(virtio.device_id_entropy, 0, 0);
    try g.offer(up.doorbell, 0, 1); // VIRTQ_AVAIL_F_NO_INTERRUPT (§2.7.7)
    try testing.expectEqual(@as(u16, 1), g.usedIdx());
    try testing.expect(m.lapic.next() == null);
}

test "a frame the wire delivers into a receive buffer wakes the guest" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    const up = try g.bringUp(virtio.device_id_net, 1 << 5, 0); // receive queue
    try g.offer(up.doorbell, 0, 0);
    try testing.expect(m.lapic.next() == null); // a receive buffer is parked
    m.card.line.hold(&.{ 1, 2, 3, 4 }, 0);
    m.card.pump(&m.card_device, &g.ram, 0);
    try testing.expectEqual(@as(u16, 1), g.usedIdx());
    try testing.expectEqual(@as(?u8, FakeGuest.wake_vector), m.lapic.next());
}
