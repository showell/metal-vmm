//! **THE MACHINE THE GUEST RUNS ON**: its devices by port and by virtio
//! slot, the serial port it prints on, the exit door, the interval timer, and
//! what it decides about each exit (`Machine`); and the census that names
//! every field it holds. main.zig makes one and serves it; halt.zig,
//! loader.zig, processor.zig, reports.zig and settings.zig take its type.

const clock = @import("clock.zig");
const virtio = @import("virtio.zig");
const turn = @import("turn.zig");
const net = @import("net.zig");
const pci = @import("pci.zig");
const apic = @import("apic.zig");
const cost = @import("cost.zig");
const faults = @import("faults.zig");
const cache = @import("cache.zig");
const scsi = @import("scsi.zig");
const reports = @import("reports.zig");
const coverage = @import("coverage.zig");
const std = @import("std");
const loader = @import("loader.zig");
const processor = @import("processor.zig");
const linux = std.os.linux;
const Rewritten = loader.Rewritten;
const msr_tsc = processor.msr_tsc;
const testing = std.testing;

const com1: u16 = 0x3F8;
const com1_line_control: u16 = com1 + 3;
const com1_line_status: u16 = com1 + 5;
/// **THE DIVISOR LATCH.** With this bit set in the line-control register, a
/// write to the data port sets the baud rate instead of sending a byte. The
/// guest's serial init writes 0x01 there, and a model that did not know this
/// printed it: every line of output began with an invisible control character,
/// which is exactly the kind of thing only a second implementation catches.
const divisor_latch: u8 = 0x80;
/// Both "the holding register is empty" and "the transmitter is idle": the
/// guest spins on the first, and nothing here is ever busy.
const transmitter_ready: u8 = 0x20 | 0x40;
const exit_door: u16 = 0xF4;

const pit_channel0: u16 = clock.Pit.channel0_port;
const pit_command: u16 = clock.Pit.command_port;

pub const Machine = struct {
    stopped: ?u8 = null,
    /// The devices in the virtio window, by slot. A slot with nothing in it
    /// answers zero, which is how the guest's scan skips it.
    devices: [virtio.slots]?*virtio.Device = @splat(null),
    ram: []u8 = &.{},
    /// The line-control register, kept because bit 7 changes what the data
    /// port means.
    line_control: u8 = 0,
    /// **THE MACHINE'S TIME IS ITS OWN** (clock.zig): one counter that the
    /// guest's own questions advance, and the three devices that report it.
    time: clock.Clock = .{},
    pit: clock.Pit = .{},
    rtc: clock.Rtc = .{},
    /// **THE GUEST'S OWN WORDS ARE THE CLOCK HERE.** It polls memory, so
    /// nothing it does gives this program back control except a device
    /// register or a printed character — and a printed line is the only signal
    /// that says "I am listening now". zig-metal-unikernel's own judge waits for the
    /// same line before it connects.
    said: [128]u8 = undefined,
    said_len: usize = 0,
    /// What to ask the guest for once it says so, and whether it has been asked.
    request: ?[]const u8 = null,
    asked: bool = false,
    /// In a pair (`PAIR`): the other machine is the client, so `consider`
    /// never connects this program's own.
    pair: bool = false,
    /// **AND HOW IT TAKES TURNS** (turn.zig's `Hooks`; chunk 12b's socket
    /// behind it): the clock never moves past the limit, and a halt with
    /// nothing to wake it gives up the turn. Null outside a pair, where
    /// nothing here changes.
    turns: ?*const turn.Hooks = null,
    card: ?*net.Net = null,
    card_device: ?*virtio.Device = null,
    /// **THE PC-SHAPED MACHINE** (`TRANSPORT=pci`): the devices on a PCI bus,
    /// and the local APIC their MSI-X messages and the timer go to. Null is
    /// the microvm-shaped machine, where the guest polls and never halts.
    bus: ?*pci.Bus = null,
    lapic: apic.Apic = .{},
    /// The guest's halts, and the virtual time they skipped.
    halts: u64 = 0,
    halted_ns: u64 = 0,
    /// MSR accesses the filter sent here.
    msrs: u64 = 0,
    /// Exits so far: with the time, when something happened.
    exits: u64 = 0,
    /// What the run has cost, in exits and the guest's time (cost.zig).
    cost: cost.Cost = .{},
    /// The disk's faults, watched for a power cut.
    drive: ?*const faults.Drive = null,
    /// The disk's write cache (`DISK_CACHE`), which a power cut empties.
    write_cache: ?*cache.Cache = null,
    /// `VOLUME_CUT_AT_EXIT=1`: every cache loses its unsynchronized writes
    /// at the run's end (`cutAtExit`).
    cut_at_exit: bool = false,
    /// **THE VOLUME** (`VOLUME`, scsi.zig): its power is the machine's, so
    /// a cut in either disk empties both caches.
    volume: ?*scsi.Scsi = null,
    /// Which disk and volume faults fired while each client's request was
    /// open (`reports.During`, metal-vmm QUEUE 138(d)).
    during: reports.During = .{},
    /// **THE SERIAL PORT READS THE GUEST'S COVERAGE LINES** (coverage.zig),
    /// and with `COVERAGE_OUT` sends them to this file instead of stdout.
    serial: coverage.Serial = .{},
    coverage_fd: ?linux.fd_t = null,
    /// The `out`s the loader wrote: the only ones `tsc_port` and `msr_port`
    /// answer.
    rewritten: struct { clocks: Rewritten = .{}, deadlines: Rewritten = .{} } = .{},
    /// **EXITS SINCE THE GUEST LAST DID ANYTHING.** A character printed or a
    /// device doorbell rung is progress; reading the clock and polling memory
    /// is not. A machine whose time is its guest's curiosity can count a hang
    /// exactly — see `patience`.
    quiet: u64 = 0,
    /// **WHEN THE GUEST LAST DID ANYTHING**, in its own time: the same
    /// progress `quiet` counts from. On the PC-shaped machine a halt is not
    /// a hang, so a halt resets `quiet`, and a guest that rests with
    /// nothing to do is bounded by this instead (`idle`).
    progress_ns: u64 = 0,
    /// How long, in its own time, a guest may rest without doing anything
    /// before the run ends as idle. `PATIENCE_S`; ten minutes by default.
    patience_ns: u64 = 600 * std.time.ns_per_s,
    /// **HOW LONG A TEST WATCHES**, in the guest's own time: `GUEST_S`. A
    /// guest that is never quiet (one that polls on a timer and logs every
    /// poll) never reaches its patience, so the test says when it has seen
    /// enough, and the run ends as a normal end. Null: no limit.
    watch_ns: ?u64 = null,
    /// Reads of addresses no device answers. The guest looks for virtio in a
    /// window this program does not fill yet, and a window of zeros is what
    /// "nothing is plugged in there" looks like from inside.
    absent: u64 = 0,

    /// A character printed or a doorbell rung.
    fn progressed(self: *Machine) void {
        self.quiet = 0;
        self.progress_ns = self.time.ns;
    }

    /// **A HALT THE GUEST WOKE FROM IS NOT A HANG**: `quiet` starts again.
    /// True when the guest has rested past its patience with nothing
    /// printed and no doorbell rung: idle, which ends the run.
    pub fn rested(self: *Machine) bool {
        self.quiet = 0;
        return self.time.ns - self.progress_ns > self.patience_ns;
    }

    /// True once the guest's time reaches `GUEST_S`.
    pub fn watched(self: *const Machine) bool {
        const limit = self.watch_ns orelse return false;
        return self.time.ns >= limit;
    }

    /// An MSR the filter sent here, read: IA32_TSC from this machine's own
    /// clock, the APIC's from the APIC, and null (a #GP) for the rest.
    pub fn readMsr(self: *Machine, index: u32) ?u64 {
        if (index == msr_tsc) return self.time.ticks();
        return self.lapic.readMsr(index, self.time.ns);
    }

    pub fn out(self: *Machine, port: u16, bytes: []const u8) void {
        if (self.bus) |bus| if (pci.isPort(port)) return bus.out(port, bytes);
        switch (port) {
            com1 => if (self.line_control & divisor_latch == 0) {
                self.serial.feed(bytes, .{ .exit = self.exits, .ns = self.time.ns }, SerialOut{ .jsonl_fd = self.coverage_fd });
                self.listen(bytes);
                self.progressed();
            },
            com1_line_control => if (bytes.len > 0) {
                self.line_control = bytes[0];
            },
            pit_command => if (bytes.len > 0) self.pit.command(bytes[0], self.time.ns),
            pit_channel0 => if (bytes.len > 0) self.pit.write(bytes[0], self.time.ns),
            clock.Rtc.index_port => if (bytes.len > 0) self.rtc.select(bytes[0]),
            clock.Rtc.data_port => if (bytes.len > 0) self.rtc.store(bytes[0]),
            exit_door => self.stopped = if (bytes.len > 0) bytes[0] else 0,
            else => {}, // the rest of the UART's registers: written, not read
        }
    }

    /// Keeps the line the guest is printing, and connects to it when that line
    /// says it is ready to be connected to.
    fn listen(self: *Machine, bytes: []const u8) void {
        for (bytes) |b| {
            if (b == '\n') {
                self.consider();
                self.said_len = 0;
                continue;
            }
            if (self.said_len < self.said.len) {
                self.said[self.said_len] = b;
                self.said_len += 1;
            }
        }
    }

    /// **EVERY EXIT IS A CHANCE TO DELIVER SOMETHING.** The guest polls
    /// memory and gives this program control at no other moment, so a wire
    /// that holds a frame for a while has to be asked, over and over, whether
    /// it is done holding it.
    pub fn pump(self: *Machine) void {
        const card = self.card orelse return;
        const device = self.card_device orelse return;
        card.pump(device, self.ram, self.time.ns);
    }

    fn consider(self: *Machine) void {
        if (self.asked) return;
        if (std.mem.indexOf(u8, self.said[0..self.said_len], "listening on port 80") == null) return;
        // In a pair the other machine asks: the server's listening starts
        // the client (§4, "Power-on and START"), once.
        if (self.pair) {
            const t = self.turns orelse return;
            self.asked = true;
            t.listening(self.time.ns);
            return;
        }
        const request = self.request orelse return;
        const card = self.card orelse return;
        const device = self.card_device orelse return;
        self.asked = true;
        _ = card.connect(device, self.ram, request);
    }

    /// **A DEVICE THAT IS NOT THERE READS AS ZERO AND SWALLOWS WRITES**,
    /// which is what a real machine does with an address nothing decodes. It is
    /// also how a guest discovers there is no device: virtio's magic value is
    /// the first thing it reads, and zero is not it.
    pub fn memory(self: *Machine, addr: u64, is_write: bool, data: []u8) void {
        if (self.bus) |bus| if (bus.memory(self.ram, addr, is_write, data)) {
            if (is_write) self.progressed();
            return;
        };
        if (self.bus != null and apic.inWindow(addr)) {
            const offset = addr - apic.base;
            if (is_write) self.lapic.write(offset, @truncate(readLittle(data)), self.time.ns) else writeLittle(data, self.lapic.read(offset, self.time.ns));
            return;
        }
        if (virtio.inWindow(addr)) {
            const slot: usize = @intCast((addr - virtio.window_base) / virtio.slot_stride);
            const offset = (addr - virtio.window_base) % virtio.slot_stride;
            if (self.devices[slot]) |device| {
                if (is_write) {
                    device.write(self.ram, offset, @truncate(readLittle(data)));
                    self.progressed();
                } else {
                    writeLittle(data, device.read(offset, @intCast(data.len)));
                }
                return;
            }
        }
        self.absent += 1;
        if (!is_write) @memset(data, 0);
    }

    pub fn in(self: *Machine, port: u16, bytes: []u8) void {
        if (self.bus) |bus| if (pci.isPort(port)) return bus.in(port, bytes);
        @memset(bytes, 0);
        if (bytes.len == 0) return;
        switch (port) {
            com1_line_status => bytes[0] = transmitter_ready,
            pit_channel0 => bytes[0] = self.pit.read(self.time.ns),
            clock.Rtc.data_port => bytes[0] = self.rtc.read(self.time.ns),
            else => {},
        }
    }
};

/// **WHAT THE MACHINE HOLDS, FOR A SNAPSHOT** (metal-vmm QUEUE 113): every
/// field of `Machine`, and how a whole-machine snapshot (docs/SNAPSHOT.md)
/// gets it back. A field added to `Machine` fails the test below until it
/// is named here, so the snapshot cannot quietly miss it.
const Holds = enum {
    /// Saved with the machine by copy: no pointer in it (the test checks).
    value,
    /// A pointer at a model `snapshot.zig` saves in place (the test checks
    /// the model is in `snapshot.models`).
    model,
    /// A pointer at state `snapshot.zig` saves apart, not by its value: the
    /// test checks `snapshot.saverOf` has a saver for it (a write cache's
    /// map, `snapshot.Cache`).
    apart,
    /// Guest memory: the box's half (docs/SNAPSHOT.md, "Guest RAM"). The
    /// test checks it is bytes and nothing else.
    box,
    /// Fixed before the run's first exit, and never written after. The test
    /// checks it is read-only memory.
    input,
    /// The host's, not the machine's: the same across a restore. The test
    /// checks it holds no pointer.
    host,
};

/// Each field, how a snapshot gets it back, and, for what is not saved
/// with the machine, why (metal-vmm QUEUE 121: those were taken on trust).
const census = .{
    .{ "stopped", Holds.value, "" },
    .{ "devices", Holds.model, "" },
    .{ "ram", Holds.box, "guest memory: copied whole and restored in place by the box's half (docs/SNAPSHOT.md)" },
    .{ "line_control", Holds.value, "" },
    .{ "time", Holds.value, "" },
    .{ "pit", Holds.value, "" },
    .{ "rtc", Holds.value, "" },
    .{ "said", Holds.value, "" },
    .{ "said_len", Holds.value, "" },
    .{ "request", Holds.input, "the first request, read into `request_bufs` before the run's first exit; `asked` is what a restore must put back, and it is a value" },
    .{ "asked", Holds.value, "" },
    .{ "pair", Holds.value, "" },
    .{ "turns", Holds.model, "" },
    .{ "card", Holds.model, "" },
    .{ "card_device", Holds.model, "" },
    .{ "bus", Holds.model, "" },
    .{ "lapic", Holds.value, "" },
    .{ "halts", Holds.value, "" },
    .{ "halted_ns", Holds.value, "" },
    .{ "msrs", Holds.value, "" },
    .{ "exits", Holds.value, "" },
    .{ "cost", Holds.value, "" },
    .{ "drive", Holds.model, "" },
    .{ "write_cache", Holds.apart, "" },
    .{ "cut_at_exit", Holds.value, "" },
    .{ "volume", Holds.model, "" },
    .{ "during", Holds.value, "" },
    .{ "serial", Holds.value, "" },
    .{ "coverage_fd", Holds.host, "the file the coverage lines go to, opened before the run: lines written before a restore stay written, as `serial`'s table says what was reached" },
    .{ "rewritten", Holds.value, "" },
    .{ "quiet", Holds.value, "" },
    .{ "progress_ns", Holds.value, "" },
    .{ "patience_ns", Holds.value, "" },
    .{ "watch_ns", Holds.value, "" },
    .{ "absent", Holds.value, "" },
};

/// The model a field points at: `*T`, `?*T`, `[n]?*T`, and `*const T` alike.
fn pointee(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        .optional => |o| pointee(o.child),
        .array => |a| pointee(a.child),
        else => @compileError(@typeName(T) ++ " is not a pointer at a model"),
    };
}

/// Where the serial port's bytes go: stdout, and the coverage JSONL.
pub const SerialOut = struct {
    jsonl_fd: ?linux.fd_t,

    pub fn stdout(_: SerialOut, bytes: []const u8) void {
        _ = linux.write(1, bytes.ptr, bytes.len);
    }

    pub fn jsonl(self: SerialOut, line: []const u8) void {
        const fd = self.jsonl_fd orelse return;
        _ = linux.write(fd, line.ptr, line.len);
        _ = linux.write(fd, "\n", 1);
    }
};

pub fn readLittle(data: []const u8) u64 {
    var value: u64 = 0;
    for (data, 0..) |b, i| value |= @as(u64, b) << @intCast(i * 8);
    return value;
}

fn writeLittle(data: []u8, value: u64) void {
    for (data, 0..) |*b, i| b.* = @truncate(value >> @intCast(i * 8));
}

test "an absent device reads as zero and swallows writes" {
    var machine = Machine{};
    var data = [_]u8{ 1, 2, 3, 4 };
    machine.memory(0xDEAD0000, false, &data);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &data);
    machine.memory(0xDEAD0000, true, &data);
    try testing.expectEqual(@as(u64, 2), machine.absent);
}

test "a baud-rate write is not a character" {
    // The guest's serial init sets the divisor latch and writes 0x01 to the
    // data port. Printing that byte put an invisible 0x01 at the head of every
    // run, and only a comparison with another machine showed it.
    var machine = Machine{};
    machine.out(com1_line_control, &.{divisor_latch});
    machine.out(com1, &.{0x01});
    machine.out(com1_line_control, &.{0x03}); // 8N1, latch off
    try testing.expectEqual(@as(u8, 0x03), machine.line_control);
}

test "the line status register always says the transmitter is free" {
    // The guest spins on this bit. A zero here is a machine that never prints.
    var machine = Machine{};
    var byte = [_]u8{0xFF};
    machine.in(com1_line_status, &byte);
    try testing.expect(byte[0] & 0x20 != 0);
    machine.in(com1, &byte);
    try testing.expectEqual(@as(u8, 0), byte[0]);
}

test "the exit door stops the machine with the guest's own code" {
    var machine = Machine{};
    try testing.expect(machine.stopped == null);
    machine.out(exit_door, &.{7});
    try testing.expectEqual(@as(u8, 7), machine.stopped.?);
}

test "a guest that rests past its patience with nothing done is idle; anything done starts it again" {
    var machine = Machine{ .patience_ns = 10 * std.time.ns_per_s };
    machine.time.ns = 10 * std.time.ns_per_s;
    try testing.expect(!machine.rested()); // exactly its patience: not yet
    machine.time.ns += 1;
    try testing.expect(machine.rested());
    // A character printed or a doorbell rung is progress, and the patience
    // starts from there.
    machine.progressed();
    machine.time.ns += 5 * std.time.ns_per_s;
    try testing.expect(!machine.rested());
}

test "a run watched for GUEST_S ends once the guest's time reaches it, and never without it" {
    var machine = Machine{};
    machine.time.ns = 100 * std.time.ns_per_s;
    try testing.expect(!machine.watched());
    machine.watch_ns = 30 * std.time.ns_per_s;
    machine.time.ns = 30 * std.time.ns_per_s - 1;
    try testing.expect(!machine.watched());
    machine.time.ns += 1;
    try testing.expect(machine.watched());
}

test "the census: every field of the machine is named, and is what it says (metal-vmm QUEUE 113)" {
    const snapshot = @import("snapshot.zig");
    comptime {
        @setEvalBranchQuota(2_000_000);
        const machine = @typeInfo(Machine).@"struct";
        for (machine.field_names, machine.field_types) |f_name, f_type| {
            const holds: Holds = for (census) |c| {
                if (std.mem.eql(u8, c[0], f_name)) {
                    if ((c[1] == .box or c[1] == .input or c[1] == .host) and c[2].len == 0)
                        @compileError("machine.zig: Machine." ++ f_name ++ " is not saved with the machine: say why in its census line");
                    break c[1];
                }
            } else @compileError("machine.zig: Machine." ++ f_name ++ " is in no line of `census`: say how a snapshot gets it back");
            switch (holds) {
                .value => if (snapshot.pointersIn(f_type, "Machine." ++ f_name).len > 0)
                    @compileError("machine.zig: Machine." ++ f_name ++ " is called a value, and holds a pointer: " ++ snapshot.pointersIn(f_type, "Machine." ++ f_name)),
                .model => {
                    const M = pointee(f_type);
                    for (snapshot.models) |known| {
                        if (known == M) break;
                    } else @compileError("machine.zig: Machine." ++ f_name ++ " points at " ++ @typeName(M) ++ ", which is not in snapshot.models");
                },
                .apart => if (snapshot.saverOf(pointee(f_type)) == null)
                    @compileError("machine.zig: Machine." ++ f_name ++ " is said to be saved apart, and snapshot.saverOf has no saver for " ++ @typeName(pointee(f_type))),
                .box => if (f_type != []u8)
                    @compileError("machine.zig: Machine." ++ f_name ++ " is called guest memory, and is not bytes"),
                .input => {
                    const T = switch (@typeInfo(f_type)) {
                        .optional => |o| o.child,
                        else => f_type,
                    };
                    const info = @typeInfo(T);
                    if (info != .pointer or !info.pointer.attrs.@"const")
                        @compileError("machine.zig: Machine." ++ f_name ++ " is called an input, and is not read-only memory");
                },
                .host => if (snapshot.pointersIn(f_type, "").len > 0)
                    @compileError("machine.zig: Machine." ++ f_name ++ " is called the host's, and holds a pointer"),
            }
        }
        for (census) |c| {
            for (machine.field_names) |f_name| {
                if (std.mem.eql(u8, c[0], f_name)) break;
            } else @compileError("machine.zig: `census` names Machine." ++ c[0] ++ ", which is not a field");
        }
    }
}
