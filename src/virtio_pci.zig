//! **A VIRTIO DEVICE AS A PCI FUNCTION** (virtio 1.2 §4.1): its
//! configuration registers and capability list, the four windows in its BAR
//! (the common configuration, the ISR, the device's own configuration and
//! the doorbells), and its MSI-X (msix.zig). The bus it sits on, and how a
//! guest reaches it, is pci.zig. The tests here drive it as gopher-metal's
//! driver does (`FakeGuest`).

const std = @import("std");
const virtio = @import("virtio.zig");
const apic = @import("apic.zig");
const net = @import("net.zig");
const entropy = @import("entropy.zig");
const testing = std.testing;
const pci = @import("pci.zig");
const msix_zig = @import("msix.zig");
const msix = msix_zig;
const Bus = pci.Bus;
const address_port = pci.address_port;
const data_port = pci.data_port;
const isPort = pci.isPort;
const bar_base = pci.bar_base;
const bar_size = pci.bar_size;
const command_memory = pci.command_memory;
const command_bus_master = pci.command_bus_master;
const command_writable = pci.command_writable;
const slots = pci.slots;
const cfgWrite32 = pci.cfgWrite32;
const msixReady = msix_zig.msixReady;
const setVector = msix_zig.setVector;

pub const common_at = 0x0000;
pub const common_len = 0x38;
pub const isr_at = 0x1000;
pub const device_at = 0x2000;
pub const device_len = 0x100;
pub const notify_at = 0x3000;
pub const notify_len = 0x1000;
pub const notify_multiplier = 4;
pub const msix_table_at = msix.table_at;
pub const msix_pba_at = msix.pba_at;

// The capability list, at fixed places in configuration space.
pub const cap_common = 0x40;
pub const cap_isr = 0x50;
pub const cap_device = 0x60;
pub const cap_notify = 0x70;
pub const cap_msix = 0x88;

pub const no_vector = msix.no_vector;

pub const msix_entries = msix.entries;
pub const msix_table_bytes = msix.table_bytes;
pub const Entry = msix.Entry;

/// One virtio device in a slot.
pub const Function = struct {
    device: *virtio.Device,
    bar: u64,
    command: u16 = 0,
    /// Its MSI-X table, pending bits and Message Control (msix.zig).
    msix: msix.Msix = .{},
    /// Which entry each source signals (virtio §4.1.4.3): the configuration
    /// change, and each queue. NO_VECTOR is none.
    msix_config: u16 = no_vector,
    queue_vector: [2]u16 = .{ no_vector, no_vector },
    /// Where its messages go: this machine's one APIC.
    apic: ?*apic.Apic = null,

    pub fn classCode(self: *const Function) u32 {
        return switch (self.device.id) {
            virtio.device_id_net => 0x02_00_00, // network, ethernet
            virtio.device_id_block => 0x01_00_00, // mass storage, SCSI-ish
            else => 0xFF_00_00, // unclassified
        };
    }

    /// One aligned dword of configuration space.
    pub fn config(self: *const Function, register: u8) u32 {
        return switch (register) {
            0x00 => 0x1AF4 | (@as(u32, 0x1040 + @as(u16, @intCast(self.device.id))) << 16),
            0x04 => self.command | (@as(u32, 0x0010) << 16), // status: capabilities
            0x08 => 0x01 | (self.classCode() << 8), // revision 1, modern
            0x0C => 0, // header type 0, one function
            0x10 => @intCast(self.bar), // memory, 32-bit, not prefetchable
            // The other BARs are not implemented, and read zero even after
            // all ones are written: how sizing learns so (§6.2.5.1).
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
            // MSI-X: id, next (none), message control (its table's size less
            // one, in bits 10:0); then the table's and the pending bits'
            // offsets, in BAR 0.
            cap_msix => 0x11 | (@as(u32, self.msix.messageControl()) << 16),
            cap_msix + 4 => msix_table_at,
            cap_msix + 8 => msix_pba_at,
            else => 0,
        };
    }

    pub fn vendorCap(next: u8, len: u8, cfg_type: u8) u32 {
        return 0x09 | (@as(u32, next) << 8) | (@as(u32, len) << 16) | (@as(u32, cfg_type) << 24);
    }

    pub fn configWrite(self: *Function, register: u8, value: u32, mask: u32) void {
        switch (register) {
            0x04 => {
                self.command = @as(u16, @truncate((self.command & ~mask) | (value & mask))) & command_writable;
                // **NOT ALLOWED TO MASTER THE BUS, A DEVICE TOUCHES NO
                // MEMORY**: not the rings, and not the APIC, which is what an
                // MSI-X message is a write to (§6.2.2, §6.8.2).
                self.device.may_dma = self.busMaster();
                self.msix.flush(self.apic, self.busMaster());
            },
            // The address bits of the one BAR; its size's bits stay zero, so
            // all ones written reads back the size (§6.2.5.1).
            0x10 => {
                const merged = (@as(u32, @truncate(self.bar)) & ~mask) | (value & mask);
                self.bar = merged & ~@as(u32, bar_size - 1);
            },
            // Only the bytes written change, and only the bits that are not
            // read-only.
            cap_msix => self.msix.writeControl(value, mask, self.apic, self.busMaster()),
            else => {}, // read-only, or not implemented
        }
    }

    // ── the BAR ──────────────────────────────────────────────────────────────

    pub fn read(self: *Function, offset: u64, len: u32) u64 {
        if (offset < common_at + common_len) return self.commonRead(offset, len);
        if (offset == isr_at) {
            // Reading the ISR is its acknowledgement (virtio §4.1.4.5).
            const v = self.device.interrupt_status;
            self.device.interrupt_status = 0;
            return v;
        }
        if (offset >= device_at and offset < device_at + device_len)
            return self.device.read(0x100 + (offset - device_at), len);
        if (msix.Msix.inWindow(offset)) return self.msix.read(offset, len);
        return 0;
    }

    pub fn write(self: *Function, ram: []u8, offset: u64, len: u32, value: u64) void {
        if (offset < common_at + common_len) return self.commonWrite(ram, offset, len, value);
        if (offset >= notify_at and offset < notify_at + notify_len) {
            const queue: u32 = @intCast((offset - notify_at) / notify_multiplier);
            if (queue < self.device.queue_count) self.device.notified(self.device.context, self.device, ram, queue);
            return;
        }
        if (msix.Msix.inWindow(offset)) self.msix.write(offset, len, value, self.apic, self.busMaster());
    }

    /// Bus mastering on: the device may touch memory, the APIC's included.
    pub fn busMaster(self: *const Function) bool {
        return self.command & command_bus_master != 0;
    }

    /// The common configuration (virtio §4.1.4.3), each field at its width.
    pub fn commonRead(self: *Function, offset: u64, len: u32) u64 {
        const d = self.device;
        var image: [common_len]u8 = @splat(0);
        std.mem.writeInt(u32, image[0x00..0x04], d.device_features_sel, .little);
        std.mem.writeInt(u32, image[0x04..0x08], switch (d.device_features_sel) {
            0 => d.features_low,
            1 => virtio.feature_version_1_high,
            else => 0,
        }, .little);
        std.mem.writeInt(u32, image[0x08..0x0C], d.driver_features_sel, .little);
        std.mem.writeInt(u16, image[0x10..0x12], self.msix_config, .little);
        std.mem.writeInt(u16, image[0x12..0x14], @intCast(d.queue_count), .little);
        image[0x14] = @truncate(d.status);
        std.mem.writeInt(u16, image[0x16..0x18], @truncate(d.queue_sel), .little);
        // **A QUEUE THAT IS NOT THERE READS AS ZERO** (§4.1.4.3.2), with no
        // vector; a queue that is reads its size, the maximum until the
        // driver picks.
        std.mem.writeInt(u16, image[0x1A..0x1C], no_vector, .little);
        if (self.selectedQueue()) |sel| {
            const q = &d.queues[sel];
            std.mem.writeInt(u16, image[0x18..0x1A], @truncate(if (q.size != 0) q.size else virtio.queue_max), .little);
            std.mem.writeInt(u16, image[0x1A..0x1C], self.queue_vector[sel], .little);
            std.mem.writeInt(u16, image[0x1C..0x1E], @truncate(q.ready), .little);
            std.mem.writeInt(u16, image[0x1E..0x20], @intCast(sel), .little);
            std.mem.writeInt(u64, image[0x20..0x28], q.desc, .little);
            std.mem.writeInt(u64, image[0x28..0x30], q.avail, .little);
            std.mem.writeInt(u64, image[0x30..0x38], q.used, .little);
        }
        const at: usize = @intCast(offset);
        var value: u64 = 0;
        for (0..@min(len, common_len - at)) |i| value |= @as(u64, image[at + i]) << @intCast(i * 8);
        return value;
    }

    /// The common configuration's fields (virtio 1.2 §4.1.4.3), where each
    /// is and how wide; a 64-bit address is two 32-bit halves.
    pub const common_fields = [_]struct { at: u8, len: u8 }{
        .{ .at = 0x00, .len = 4 }, .{ .at = 0x04, .len = 4 }, .{ .at = 0x08, .len = 4 },
        .{ .at = 0x0C, .len = 4 }, .{ .at = 0x10, .len = 2 }, .{ .at = 0x12, .len = 2 },
        .{ .at = 0x14, .len = 1 }, .{ .at = 0x15, .len = 1 }, .{ .at = 0x16, .len = 2 },
        .{ .at = 0x18, .len = 2 }, .{ .at = 0x1A, .len = 2 }, .{ .at = 0x1C, .len = 2 },
        .{ .at = 0x1E, .len = 2 }, .{ .at = 0x20, .len = 4 }, .{ .at = 0x24, .len = 4 },
        .{ .at = 0x28, .len = 4 }, .{ .at = 0x2C, .len = 4 }, .{ .at = 0x30, .len = 4 },
        .{ .at = 0x34, .len = 4 },
    };

    /// **A STORE IS SPLIT OVER THE FIELDS IT COVERS**, lowest first, and
    /// changes only the bytes it wrote of each: so one 64-bit store sets
    /// both halves of a queue's address (§4.1.3.1 lets a driver make it
    /// either way), and a byte changes only its byte.
    pub fn commonWrite(self: *Function, ram: []u8, offset: u64, len: u32, value: u64) void {
        for (common_fields) |field| {
            const lo = @max(offset, field.at);
            const hi = @min(offset + len, @as(u64, field.at) + field.len);
            if (lo >= hi) continue;
            var merged = self.commonRead(field.at, field.len);
            for (lo..hi) |at| {
                const byte = (value >> @intCast((at - offset) * 8)) & 0xFF;
                const shift: u6 = @intCast((at - field.at) * 8);
                merged = (merged & ~(@as(u64, 0xFF) << shift)) | (byte << shift);
            }
            self.commonField(ram, field.at, merged);
        }
    }

    /// One whole field of the common configuration, written.
    /// The queue `queue_select` names, if the device serves one by that
    /// number.
    pub fn selectedQueue(self: *const Function) ?usize {
        const d = self.device;
        return if (d.queue_sel < d.queue_count) d.queue_sel else null;
    }

    pub fn commonField(self: *Function, ram: []u8, offset: u64, value: u64) void {
        const d = self.device;
        const v32: u32 = @truncate(value);
        // What is written to a queue that is not there goes nowhere.
        if (offset >= 0x18 and offset != 0x1E) {
            const sel = self.selectedQueue() orelse return;
            const q = &d.queues[sel];
            switch (offset) {
                0x18 => q.size = v32 & 0xFFFF,
                0x1A => self.queue_vector[sel] = msix.Msix.entryOrNone(v32),
                0x1C => q.ready = v32 & 0xFFFF,
                0x20 => q.desc = (q.desc & 0xFFFF_FFFF_0000_0000) | (value & 0xFFFF_FFFF),
                0x24 => q.desc = (q.desc & 0xFFFF_FFFF) | (value << 32),
                0x28 => q.avail = (q.avail & 0xFFFF_FFFF_0000_0000) | (value & 0xFFFF_FFFF),
                0x2C => q.avail = (q.avail & 0xFFFF_FFFF) | (value << 32),
                0x30 => q.used = (q.used & 0xFFFF_FFFF_0000_0000) | (value & 0xFFFF_FFFF),
                0x34 => q.used = (q.used & 0xFFFF_FFFF) | (value << 32),
                else => {},
            }
            return;
        }
        switch (offset) {
            0x00 => d.device_features_sel = v32,
            0x08 => d.driver_features_sel = v32,
            0x0C => {}, // whatever it takes, it may have
            0x10 => self.msix_config = msix.Msix.entryOrNone(v32),
            0x14 => {
                if (v32 & 0xFF == 0) {
                    // A reset: the device as it was, vectors included.
                    // A message waiting for an event the reset undid is no
                    // longer owed (§6.8.2.10), and neither is the ISR's bit.
                    d.write(ram, 0x070, 0);
                    d.interrupt_status = 0;
                    self.queue_vector = .{ no_vector, no_vector };
                    self.msix_config = no_vector;
                    self.msix.pending = 0;
                } else d.write(ram, 0x070, v32 & 0xFF);
            },
            0x16 => d.queue_sel = v32 & 0xFFFF,
            else => {},
        }
    }

    // ── interrupts ───────────────────────────────────────────────────────────

    /// **THE DEVICE FINISHED SOMETHING ON `queue`.** With MSI-X off, that is
    /// the ISR's queue bit, which the guest polls; with it on, the message of
    /// the queue's entry, and the ISR is left alone (virtio §4.1.5.4).
    pub fn completed(self: *Function, queue: u32) void {
        if (!self.msix.enabled()) {
            self.device.interrupt_status |= 1;
            return;
        }
        if (queue < self.queue_vector.len) self.msix.signal(self.queue_vector[queue], self.apic, self.busMaster());
    }

    /// **THE DEVICE'S CONFIGURATION CHANGED** (virtio §4.1.5.3): the ISR's
    /// second bit, or `msix_config`'s message.
    pub fn configChanged(self: *Function) void {
        if (!self.msix.enabled()) {
            self.device.interrupt_status |= 2;
            return;
        }
        self.msix.signal(self.msix_config, self.apic, self.busMaster());
    }
};

pub fn completedThunk(context: *anyopaque, queue: u32) void {
    const f: *Function = @ptrCast(@alignCast(context));
    f.completed(queue);
}

pub fn nothing(_: *anyopaque, _: *virtio.Device, _: []u8, _: u32) void {}

/// The guest's own reads, through the two ports.
pub fn read32(bus: *Bus, slot: u8, register: u8) u32 {
    var addr: [4]u8 = undefined;
    std.mem.writeInt(u32, &addr, 0x8000_0000 | (@as(u32, slot) << 11) | register, .little);
    bus.out(address_port, &addr);
    var data: [4]u8 = undefined;
    bus.in(data_port, &data);
    return std.mem.readInt(u32, &data, .little);
}

pub fn write16(bus: *Bus, slot: u8, register: u8, value: u16) void {
    var addr: [4]u8 = undefined;
    std.mem.writeInt(u32, &addr, 0x8000_0000 | (@as(u32, slot) << 11) | (register & 0xFC), .little);
    bus.out(address_port, &addr);
    var data: [2]u8 = undefined;
    std.mem.writeInt(u16, &data, value, .little);
    bus.out(data_port + (register & 2), &data);
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

/// **GOPHER-METAL'S DRIVER, FROM THE OTHER SIDE.** Each step is what its
/// `pci.zig` and `virtio.zig` do, at the widths they do it: configuration
/// space by `outl`/`inl` and `outw`, the common configuration by each field's
/// own width, 64-bit fields as two 32-bit stores. Its RAM holds the rings; its
/// stores to a BAR go through `Bus.memory`, as an exit would bring them.
pub const FakeGuest = struct {
    bus: *Bus,
    ram: [0x4000]u8 align(8) = @splat(0),

    // Where this guest keeps one queue's rings and buffers, in its RAM.
    pub const size: u16 = 8;
    pub const desc_at: u64 = 0x100;
    pub const avail_at: u64 = desc_at + size * @sizeOf(virtio.Desc);
    pub const used_at: u64 = 0x400;
    pub const buffer_at: u64 = 0x1000;
    pub const buffer_len: u32 = 0x800;

    pub const wake_vector: u8 = 0x40;

    /// What `pciDevice` and `prepareMsix` found.
    pub const Found = struct {
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

    pub fn cfgRead32(self: *FakeGuest, slot: u8, register: u8) u32 {
        var addr: [4]u8 = undefined;
        std.mem.writeInt(u32, &addr, 0x8000_0000 | (@as(u32, slot) << 11) | (register & 0xFC), .little);
        self.bus.out(address_port, &addr);
        var data: [4]u8 = undefined;
        self.bus.in(data_port, &data);
        return std.mem.readInt(u32, &data, .little);
    }

    pub fn cfgRead16(self: *FakeGuest, slot: u8, register: u8) u16 {
        return @truncate(self.cfgRead32(slot, register) >> @intCast((register & 2) * 8));
    }

    pub fn cfgRead8(self: *FakeGuest, slot: u8, register: u8) u8 {
        return @truncate(self.cfgRead32(slot, register) >> @intCast((register & 3) * 8));
    }

    pub fn cfgWrite16(self: *FakeGuest, slot: u8, register: u8, value: u16) void {
        var addr: [4]u8 = undefined;
        std.mem.writeInt(u32, &addr, 0x8000_0000 | (@as(u32, slot) << 11) | (register & 0xFC), .little);
        self.bus.out(address_port, &addr);
        var data: [2]u8 = undefined;
        std.mem.writeInt(u16, &data, value, .little);
        self.bus.out(data_port + (register & 2), &data);
    }

    // ── a BAR, by loads and stores ──

    pub fn load(self: *FakeGuest, comptime T: type, addr: u64) !T {
        var data: [@sizeOf(T)]u8 = undefined;
        try testing.expect(self.bus.memory(&self.ram, addr, false, &data));
        return std.mem.readInt(T, &data, .little);
    }

    pub fn store(self: *FakeGuest, comptime T: type, addr: u64, value: T) !void {
        var data: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &data, value, .little);
        try testing.expect(self.bus.memory(&self.ram, addr, true, &data));
    }

    pub fn store64(self: *FakeGuest, addr: u64, value: u64) !void {
        try self.store(u32, addr, @truncate(value));
        try self.store(u32, addr + 4, @truncate(value >> 32));
    }

    // ── gopher-metal's pci.zig ──

    /// `Scan`: every slot of bus 0, function 0 unless the header says more;
    /// the first function whose device id names virtio `kind`.
    pub fn find(self: *FakeGuest, kind: u32) ?u8 {
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

    pub fn someone(vendor: u16) bool {
        return vendor != 0xFFFF and vendor != 0x0000;
    }

    pub fn bar(self: *FakeGuest, slot: u8, index: u8) ?u64 {
        const low = self.cfgRead32(slot, 0x10 + index * 4);
        if (low & 1 != 0) return null;
        var at: u64 = low & 0xFFFF_FFF0;
        if ((low >> 1) & 3 == 2) at |= @as(u64, self.cfgRead32(slot, 0x10 + index * 4 + 4)) << 32;
        return if (at == 0) null else at;
    }

    /// `pciDevice`: the four windows from the capability list, then memory
    /// and bus mastering on (`Function.enable`).
    pub fn open(self: *FakeGuest, slot: u8) ?Found {
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
    pub fn negotiate(self: *FakeGuest, f: Found, want_low: u32) !?u8 {
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
    pub fn prepareMsix(self: *FakeGuest, f: *Found) !void {
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
    pub fn setupQueue(self: *FakeGuest, f: Found, index: u16) !struct { doorbell: u64, vectored: bool } {
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
    pub fn route(self: *FakeGuest, f: Found, vector: u8) !void {
        const entry = f.msix_entry.?;
        try self.store(u32, entry + 0, @intCast(apic.base));
        try self.store(u32, entry + 4, 0);
        try self.store(u32, entry + 8, vector);
        try self.store(u32, entry + 12, 0);
    }

    pub fn driverOk(self: *FakeGuest, f: Found, st: u8) !void {
        try self.store(u8, f.common + 0x14, st | 4);
    }

    /// One device-writable buffer offered on the queue, and the doorbell rung
    /// as `notify` does: the queue's index, 16 bits wide.
    pub fn offer(self: *FakeGuest, doorbell: u64, index: u16, flags: u16) !void {
        virtio.writeInt(u64, &self.ram, desc_at, buffer_at);
        virtio.writeInt(u32, &self.ram, desc_at + 8, buffer_len);
        virtio.writeInt(u16, &self.ram, desc_at + 12, virtio.Desc.write_flag);
        const idx = virtio.readInt(u16, &self.ram, avail_at + 2);
        virtio.writeInt(u16, &self.ram, avail_at, flags);
        virtio.writeInt(u16, &self.ram, avail_at + 4 + @as(u64, idx % size) * 2, 0);
        virtio.writeInt(u16, &self.ram, avail_at + 2, idx +% 1);
        try self.store(u16, doorbell, index);
    }

    pub fn usedIdx(self: *FakeGuest) u16 {
        return virtio.readInt(u16, &self.ram, used_at + 2);
    }

    /// The whole bring-up, as `net.zig`/`rng.zig` call it: found, negotiated,
    /// MSI-X prepared, one queue set up, routed, DRIVER_OK.
    pub fn bringUp(self: *FakeGuest, kind: u32, want_low: u32, queue: u16) !struct { f: Found, doorbell: u64 } {
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
pub const Machine = struct {
    bus: Bus = .{},
    lapic: apic.Apic = .{},
    block_context: u8 = 0,
    block: virtio.Device = undefined,
    card: net.Net = .{},
    card_device: virtio.Device = undefined,
    dice: entropy.Entropy = .{},
    dice_device: virtio.Device = undefined,

    pub fn init(self: *Machine) void {
        self.block = .{ .id = virtio.device_id_block, .context = &self.block_context, .notified = nothing };
        self.card_device = self.card.device();
        self.dice_device = self.dice.device();
        _ = self.bus.plug(1, &self.block, &self.lapic);
        _ = self.bus.plug(2, &self.card_device, &self.lapic);
        _ = self.bus.plug(3, &self.dice_device, &self.lapic);
        _ = self.lapic.writeMsr(apic.msr_apic_base, self.lapic.readMsr(apic.msr_apic_base, 0).? | (1 << 11), 0);
        self.lapic.write(0x0F0, 0x1FF, 0);
        self.lapic.write(0x320, 0x41 | (2 << 17), 0);
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
    m.lapic.write(0x0B0, 0, 0);
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

test "not allowed to master the bus, a device completes nothing; allowed, the next doorbell does" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    const up = try g.bringUp(virtio.device_id_entropy, 0, 0);
    g.cfgWrite16(3, 0x04, 0x0002); // memory only
    try g.offer(up.doorbell, 0, 0);
    try testing.expectEqual(@as(u16, 0), g.usedIdx());
    try testing.expect(m.lapic.next() == null);
    g.cfgWrite16(3, 0x04, 0x0006);
    try g.store(u16, up.doorbell, 0);
    try testing.expectEqual(@as(u16, 1), g.usedIdx());
    try testing.expectEqual(@as(?u8, FakeGuest.wake_vector), m.lapic.next());
}

test "a frame waits on the wire while the card may not master the bus" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    const up = try g.bringUp(virtio.device_id_net, 1 << 5, 0);
    try g.offer(up.doorbell, 0, 0);
    g.cfgWrite16(2, 0x04, 0x0002);
    m.card.line.hold(&.{ 1, 2, 3, 4 }, 0);
    m.card.pump(&m.card_device, &g.ram, 0);
    try testing.expectEqual(@as(u16, 0), g.usedIdx());
    g.cfgWrite16(2, 0x04, 0x0006);
    m.card.pump(&m.card_device, &g.ram, 0);
    try testing.expectEqual(@as(u16, 1), g.usedIdx());
}

test "the common configuration at other widths: a 64-bit address in one store, a byte by itself" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    const f = g.open(2).?;
    try g.store(u16, f.common + 0x16, 0);
    try g.store(u64, f.common + 0x20, 0x0000_0001_2345_6000);
    try testing.expectEqual(@as(u64, 0x0000_0001_2345_6000), m.card_device.queues[0].desc);
    try g.store(u64, f.common + 0x28, 0x0000_0002_0000_7000);
    try testing.expectEqual(@as(u64, 0x0000_0002_0000_7000), try g.load(u64, f.common + 0x28));
    // One dword over queue_select and queue_size sets both.
    try g.store(u32, f.common + 0x16, (@as(u32, 64) << 16) | 1);
    try testing.expectEqual(@as(u32, 1), m.card_device.queue_sel);
    try testing.expectEqual(@as(u32, 64), m.card_device.queues[1].size);
    // A byte of queue_size changes that byte and not the other.
    try g.store(u8, f.common + 0x19, 0x01);
    try testing.expectEqual(@as(u32, 0x0140), m.card_device.queues[1].size);
    // The read-only ones stay as they were.
    try g.store(u16, f.common + 0x12, 99);
    try testing.expectEqual(@as(u16, 2), try g.load(u16, f.common + 0x12));
}

test "a queue the device does not serve reads as absent, and takes no writes" {
    var m = Machine{};
    m.init();
    var g = FakeGuest{ .bus = &m.bus };
    // virtio-rng serves one queue, virtio-net two (virtio 1.2 §5.4.2, §5.1.2).
    const rng = g.open(3).?;
    const card = g.open(2).?;
    try testing.expectEqual(@as(u16, 1), try g.load(u16, rng.common + 0x12));
    try testing.expectEqual(@as(u16, 2), try g.load(u16, card.common + 0x12));
    try g.store(u16, rng.common + 0x16, 1);
    try testing.expectEqual(@as(u16, 1), try g.load(u16, rng.common + 0x16)); // as written
    try testing.expectEqual(@as(u16, 0), try g.load(u16, rng.common + 0x18)); // §4.1.4.3.2
    try g.store(u16, rng.common + 0x18, 16);
    try g.store(u64, rng.common + 0x20, 0x1234_5000);
    try g.store(u16, rng.common + 0x1C, 1);
    try testing.expectEqual(@as(u32, 0), m.dice_device.queues[1].size);
    try testing.expectEqual(@as(u64, 0), m.dice_device.queues[1].desc);
    try testing.expectEqual(@as(u32, 0), m.dice_device.queues[1].ready);
    try testing.expectEqual(@as(u64, 0), try g.load(u64, rng.common + 0x20));
    try testing.expectEqual(no_vector, try g.load(u16, rng.common + 0x1A));
    // Selecting queue 0 again, it is as it was.
    try g.store(u16, rng.common + 0x16, 0);
    try testing.expectEqual(@as(u16, virtio.queue_max), try g.load(u16, rng.common + 0x18));
}
