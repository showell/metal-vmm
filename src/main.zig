//! **A VIRTUAL MACHINE, ONE PROCESS, NO QEMU.**
//!
//!     metal-vmm <kernel.elf>
//!
//! Loads a PVH kernel — gopher-metal's probes and its server are exactly this
//! — into memory we own, hands it a processor through `/dev/kvm`, and answers
//! the two devices it needs before anything else works: the serial port it
//! prints on, and the door it exits through. The guest's console comes out on
//! ours, and its exit code becomes ours.
//!
//! **THE POINT IS NOT SPEED; IT IS THAT WE OWN EVERY INPUT.** A guest here
//! reads nothing this program did not give it — including what time it is,
//! which is clock.zig's job and the reason this program's loader rewrites the
//! guest's `rdtsc` instructions on the way in. Two runs of the same guest are
//! the same run.
//!
//! What the guest expects, and what this therefore provides:
//!
//!   - **32-bit protected mode, paging off**, flat segments, with `%ebx`
//!     holding a `hvm_start_info` and `%eip` at the address named by the
//!     `XEN_ELFNOTE_PHYS32_ENTRY` note in its own ELF. It builds long mode
//!     itself from there.
//!   - **A memory map it can believe**, because since the day it learned to
//!     read one, the size of its heaps comes from what the loader reports.
//!   - **COM1 at 0x3F8**, whose line-status register must say the transmitter
//!     is ready or it spins there forever.
//!   - **The exit door at 0xF4**, which QEMU calls `isa-debug-exit`.
//!   - **A clock**: an interval timer to calibrate against, a timestamp
//!     counter, and a real-time clock if it wants the date. All three are one
//!     counter — see clock.zig.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const kvm = @import("kvm.zig");
const virtio = @import("virtio.zig");
const net = @import("net.zig");
const clock = @import("clock.zig");
const entropy = @import("entropy.zig");
const disk = @import("disk.zig");
const faults = @import("faults.zig");
const wire = @import("peer.zig");
const apic = @import("apic.zig");
const cost = @import("cost.zig");
const cache = @import("cache.zig");
const scsi = @import("scsi.zig");
const coverage = @import("coverage.zig");
const knobs = @import("knobs.zig");
const checked = @import("checked.zig");
const pci = @import("pci.zig");
const settings = @import("settings.zig");
const reports = @import("reports.zig");
const loader = @import("loader.zig");
const processor = @import("processor.zig");
const halt = @import("halt.zig");
const tellTheFaults = settings.tellTheFaults;
const count = settings.count;
const knob = settings.knob;
const numbers = settings.numbers;
const reportCut = reports.reportCut;
const reportCoverage = reports.reportCoverage;
const reportRest = reports.reportRest;
const reportRun = reports.reportRun;
const reportFaults = reports.reportFaults;
const reportFaultsWith = reports.reportFaultsWith;
const pickedWord = reports.pickedWord;
const ElfHeader = loader.ElfHeader;
const ProgramHeader = loader.ProgramHeader;
const Rewritten = loader.Rewritten;
const Loaded = loader.Loaded;
const SectionHeader = loader.SectionHeader;
const textRange = loader.textRange;
const rewriteDeadlineWrites = loader.rewriteDeadlineWrites;
const rewriteClockReads = loader.rewriteClockReads;
const rewriteMarked = loader.rewriteMarked;
const NoteHeader = loader.NoteHeader;
const LoadError = loader.LoadError;
const load = loader.load;
const pvhEntry = loader.pvhEntry;
const tsc_port = loader.tsc_port;
const msr_port = loader.msr_port;
/// **THE COVERAGE DOOR**: a gopher-metal kernel built `-Dcoverage` reads it
/// at boot, and finding `coverage_door_answer` there, writes its coverage
/// lines to it instead of the serial port: each line in its own memory, a
/// little-endian u32 length and then the bytes, and the line's physical
/// address written to the door as one 32-bit `out`. One exit a line: KVM
/// emulates `rep outsb` a byte at a time, an exit each (300 lines at boot
/// were 111,448 exits). A one-byte write is taken as a byte of a line, as
/// the serial port's would be. Neither costs the guest any
/// time: no exit through it is counted, ticks the clock, delivers a frame
/// or counts as progress, so a coverage kernel runs as its release build
/// does, exit for exit, but for its own extra work. A release build never
/// touches it.
const coverage_door = loader.coverage_door;
const coverage_door_answer: u8 = 'M';
const describeProcessor = processor.describeProcessor;
const forgetTheDice = processor.forgetTheDice;
const sayTheApic = processor.sayTheApic;
const hideTheHostsTime = processor.hideTheHostsTime;
const owned_msrs = processor.owned_msrs;
const msr_tsc = processor.msr_tsc;
const msrFilter = processor.msrFilter;
const ownTheMsrs = processor.ownTheMsrs;
const Rested = halt.Rested;
const Cpu = halt.Cpu;
const Wake = halt.Wake;
const wakes = halt.wakes;

/// How much RAM the guest gets. The probes were written against `-m 512`.
const ram_bytes: usize = 512 * 1024 * 1024;

/// Where the things we hand the guest go: low memory, below anything a kernel
/// loads itself at, and out of the first page so that a null pointer stays a
/// null pointer.
const gdt_addr: u64 = 0x1000;
const start_info_addr: u64 = 0x6000;
const memmap_addr: u64 = 0x6100;
const cmdline_addr: u64 = 0x6200;

/// The first 640 KB, as every PC has reported it since 1981; the rest starts
/// at the megabyte, which is where a kernel image is loaded.
const low_ram_top: u64 = 0xA0000;
const high_ram_base: u64 = 0x100000;

// ── what the guest is told on the way in ─────────────────────────────────────

const StartInfo = extern struct {
    magic: u32 = 0x336ec578, // "xEn3"
    version: u32 = 1, // 1 is the first with a memory map
    flags: u32 = 0,
    nr_modules: u32 = 0,
    modlist_paddr: u64 = 0,
    cmdline_paddr: u64 = 0,
    rsdp_paddr: u64 = 0,
    memmap_paddr: u64 = 0,
    memmap_entries: u32 = 0,
    reserved: u32 = 0,
};

const MemmapEntry = extern struct {
    addr: u64,
    size: u64,
    type: u32 = 1, // 1 is ordinary RAM
    reserved: u32 = 0,
};

// ── the ELF we are asked to run ──────────────────────────────────────────────

/// Writes the start_info, its memory map and the command line into guest
/// memory, and answers where the start_info landed.
fn tell(ram: []u8, command_line: []const u8) u64 {
    const entries = [_]MemmapEntry{
        .{ .addr = 0, .size = low_ram_top },
        .{ .addr = high_ram_base, .size = ram_bytes - high_ram_base },
    };
    const map_at: usize = @intCast(memmap_addr);
    @memcpy(ram[map_at..][0..@sizeOf(@TypeOf(entries))], std.mem.asBytes(&entries));

    var cmdline_paddr: u64 = 0;
    if (command_line.len > 0) {
        const at: usize = @intCast(cmdline_addr);
        @memcpy(ram[at..][0..command_line.len], command_line);
        ram[at + command_line.len] = 0;
        cmdline_paddr = cmdline_addr;
    }

    const info = StartInfo{
        .cmdline_paddr = cmdline_paddr,
        .memmap_paddr = memmap_addr,
        .memmap_entries = entries.len,
    };
    const info_at: usize = @intCast(start_info_addr);
    @memcpy(ram[info_at..][0..@sizeOf(StartInfo)], std.mem.asBytes(&info));
    return start_info_addr;
}

// ── the processor, as the guest expects to find it ───────────────────────────

/// A flat GDT: null, code, data. The guest replaces it within a few dozen
/// instructions, but the processor will not enter protected mode without one
/// that agrees with the segments below.
fn writeGdt(ram: []u8) void {
    const table = [_]u64{
        0,
        0x00CF9A000000FFFF, // code: present, ring 0, executable, 32-bit, 4 GB
        0x00CF92000000FFFF, // data: present, ring 0, writable, 32-bit, 4 GB
    };
    const at: usize = @intCast(gdt_addr);
    @memcpy(ram[at..][0..@sizeOf(@TypeOf(table))], std.mem.asBytes(&table));
}

/// **WHO CALLED IT**, as far as a stack can be guessed: with no frame
/// pointers there is no backtrace, but any word on the stack that points into
/// the kernel's own image is almost certainly a return address, and a handful
/// of those is enough to name the loop a guest is stuck in.
///
///     addr2line -f -C -e <kernel.elf> <address>
fn callers(ram: []const u8, rsp: u64, text: Text) void {
    if (text.hi == 0 or rsp + 8 > ram.len) return;
    std.debug.print("         possibly called from, innermost first:\n", .{});
    var at = rsp;
    var found: usize = 0;
    while (at + 8 <= ram.len and at < rsp + 4096 and found < 10) : (at += 8) {
        const word = readLittle(ram[@intCast(at)..][0..8]);
        if (word < text.lo or word >= text.hi) continue;
        std.debug.print("           {x:0>16}\n", .{word});
        found += 1;
    }
}

/// What the processor was doing when it gave up, which is the only thing worth
/// knowing about a triple fault.
const Text = struct { lo: u64, hi: u64 };

fn report(vcpu: linux.fd_t, ram: []const u8, text: Text) void {
    var regs: kvm.Regs = undefined;
    var sregs: kvm.Sregs = undefined;
    if (kvm.call(vcpu, kvm.get_regs, @intFromPtr(&regs))) |_| {
        if (kvm.call(vcpu, kvm.get_sregs, @intFromPtr(&sregs))) |_| {
            std.debug.print(
                "         rip {x:0>16}  rbx {x:0>16}  rsp {x:0>16}\n" ++
                    "         cr0 {x:0>8}  cr3 {x:0>8}  cr4 {x:0>8}  efer {x:0>8}\n" ++
                    "         cs {{ base {x}, limit {x}, l {d}, db {d} }}\n",
                .{ regs.rip, regs.rbx, regs.rsp, sregs.cr0, sregs.cr3, sregs.cr4, sregs.efer, sregs.cs.base, sregs.cs.limit, sregs.cs.l, sregs.cs.db },
            );
            callers(ram, regs.rsp, text);
        } else |_| {}
    } else |_| {}
}

fn enterProtectedMode(vcpu: linux.fd_t, entry: u64, start_info: u64) !void {
    var sregs: kvm.Sregs = undefined;
    _ = try kvm.call(vcpu, kvm.get_sregs, @intFromPtr(&sregs));

    const code = kvm.Segment{
        .base = 0,
        .limit = 0xFFFFFFFF,
        .selector = 0x08,
        .type = 0b1011, // execute, read, accessed
        .present = 1,
        .dpl = 0,
        .db = 1, // 32-bit
        .s = 1, // a code/data segment, not a system one
        .l = 0, // not long mode; the guest gets there itself
        .g = 1, // the limit is in pages
    };
    var data = code;
    data.selector = 0x10;
    data.type = 0b0011; // read, write, accessed

    sregs.cs = code;
    sregs.ds = data;
    sregs.es = data;
    sregs.fs = data;
    sregs.gs = data;
    sregs.ss = data;
    sregs.gdt = .{ .base = gdt_addr, .limit = 3 * 8 - 1 };
    sregs.cr0 = 0x11; // protection on, and the coprocessor bit every x86 sets
    sregs.cr3 = 0;
    sregs.cr4 = 0;
    sregs.efer = 0;
    _ = try kvm.call(vcpu, kvm.set_sregs, @intFromPtr(&sregs));

    // **%ebx IS THE WHOLE HANDSHAKE.** Everything the guest learns about the
    // machine it is on starts at that pointer.
    var regs = kvm.Regs{ .rip = entry, .rbx = start_info, .rflags = 0x2 };
    _ = try kvm.call(vcpu, kvm.set_regs, @intFromPtr(&regs));
}

// ── the devices it cannot boot without ───────────────────────────────────────

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

// ── the interval timer ────────────────────────────────────────────────────────

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
    /// that says "I am listening now". gopher-metal's own judge waits for the
    /// same line before it connects.
    said: [128]u8 = undefined,
    said_len: usize = 0,
    /// What to ask the guest for once it says so, and whether it has been asked.
    request: ?[]const u8 = null,
    asked: bool = false,
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
    fn rested(self: *Machine) bool {
        self.quiet = 0;
        return self.time.ns - self.progress_ns > self.patience_ns;
    }

    /// An MSR the filter sent here, read: IA32_TSC from this machine's own
    /// clock, the APIC's from the APIC, and null (a #GP) for the rest.
    pub fn readMsr(self: *Machine, index: u32) ?u64 {
        if (index == msr_tsc) return self.time.ticks();
        return self.lapic.readMsr(index, self.time.ns);
    }

    fn out(self: *Machine, port: u16, bytes: []const u8) void {
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
    fn pump(self: *Machine) void {
        const card = self.card orelse return;
        const device = self.card_device orelse return;
        card.pump(device, self.ram, self.time.ns);
    }

    fn consider(self: *Machine) void {
        if (self.asked) return;
        const request = self.request orelse return;
        if (std.mem.indexOf(u8, self.said[0..self.said_len], "listening on port 80") == null) return;
        const card = self.card orelse return;
        const device = self.card_device orelse return;
        self.asked = true;
        _ = card.connect(device, self.ram, request);
    }

    /// **A DEVICE THAT IS NOT THERE READS AS ZERO AND SWALLOWS WRITES**,
    /// which is what a real machine does with an address nothing decodes. It is
    /// also how a guest discovers there is no device: virtio's magic value is
    /// the first thing it reads, and zero is not it.
    fn memory(self: *Machine, addr: u64, is_write: bool, data: []u8) void {
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

    fn in(self: *Machine, port: u16, bytes: []u8) void {
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
    .{ "serial", Holds.value, "" },
    .{ "coverage_fd", Holds.host, "the file the coverage lines go to, opened before the run: lines written before a restore stay written, as `serial`'s table says what was reached" },
    .{ "rewritten", Holds.value, "" },
    .{ "quiet", Holds.value, "" },
    .{ "progress_ns", Holds.value, "" },
    .{ "patience_ns", Holds.value, "" },
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
const SerialOut = struct {
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

/// The line a 32-bit write to the coverage door points at: a u32 length at
/// `addr`, then that many bytes, all inside guest RAM. Null if not.
fn doorLine(ram: []const u8, addr: u32) ?[]const u8 {
    const start: usize = addr;
    if (start + 4 > ram.len) return null;
    const len: usize = std.mem.readInt(u32, ram[start..][0..4], .little);
    if (len > ram.len - start - 4) return null;
    return ram[start + 4 ..][0..len];
}

test "a coverage door line: the length and the bytes, or null past guest RAM" {
    var ram: [32]u8 = @splat(0);
    std.mem.writeInt(u32, ram[8..12], 3, .little);
    @memcpy(ram[12..15], "ab\n");
    try std.testing.expectEqualStrings("ab\n", doorLine(&ram, 8).?);
    std.mem.writeInt(u32, ram[20..24], 9, .little);
    try std.testing.expect(doorLine(&ram, 20) == null);
    try std.testing.expect(doorLine(&ram, 30) == null);
    try std.testing.expect(doorLine(&ram, 0xFFFF_FFFF) == null);
}

fn readLittle(data: []const u8) u64 {
    var value: u64 = 0;
    for (data, 0..) |b, i| value |= @as(u64, b) << @intCast(i * 8);
    return value;
}

fn writeLittle(data: []u8, value: u64) void {
    for (data, 0..) |*b, i| b.* = @truncate(value >> @intCast(i * 8));
}

/// **THE GUEST ASKED WHAT TIME IT IS.** Its `rdtsc` became a write to
/// `tsc_port` when it was loaded, and that instruction's whole effect is to
/// put a 64-bit count in EDX:EAX — so that is what this does, leaving every
/// other register exactly as the guest left it.
fn answerClock(vcpu: linux.fd_t, regs: *kvm.Regs, ticks: u64) !void {
    regs.rax = ticks & 0xFFFFFFFF;
    regs.rdx = ticks >> 32;
    _ = try kvm.call(vcpu, kvm.set_regs, @intFromPtr(regs));
}

/// **THE GUEST HALTED (`sti; hlt`), SO TIME GOES STRAIGHT TO WHAT WAKES IT.**
/// Nothing it does can happen until an interrupt arrives, and only two things
/// raise one: the APIC's timer at its deadline, and the card's MSI-X message
/// when a frame the wire holds is delivered. The clock moves to the earlier of
/// the two, the wire is pumped, and the APIC's highest waiting vector is
/// injected. A run is still a function of the guest alone: the halt's length
/// is computed, never waited. False when nothing at all can wake it.
fn rest(vcpu: linux.fd_t, run: *kvm.Run, machine: *Machine) !Rested {
    machine.halts += 1;
    const began = machine.time.ns;
    while (true) {
        const due = if (machine.card) |card| card.nextDue(machine.time.ns) else null;
        const cpu = Cpu{ .interrupts_on = run.if_flag != 0, .can_inject = run.ready_for_interrupt_injection != 0 };
        switch (wakes(&machine.lapic, machine.time.ns, due, cpu)) {
            .take => |v| {
                machine.halted_ns += machine.time.ns - began;
                try inject(vcpu, v);
                return .woken;
            },
            // At a halt after `sti` the guest can take it now; if KVM says
            // otherwise, at the first moment it can (`irq_window_open`).
            .window => {
                machine.halted_ns += machine.time.ns - began;
                run.request_interrupt_window = 1;
                return .woken;
            },
            .move_to => |at| {
                machine.time.ns = at;
                machine.pump();
            },
            .never => return .never,
            .off => return .off,
        }
    }
}

fn inject(vcpu: linux.fd_t, vector: u8) !void {
    var irq = kvm.Interrupt{ .irq = vector };
    _ = try kvm.call(vcpu, kvm.interrupt, @intFromPtr(&irq));
}

/// How long a guest may go without printing anything or touching a device
/// before this program calls it stuck. Generous: the heaviest probe here goes
/// a few tens of thousands of exits between doorbells while it works. On the
/// PC-shaped machine a halt starts the count again, and a resting guest is
/// bounded in its own time instead (`Machine.patience_ns`).
const patience: u64 = 1_000_000;

/// Runs until the guest stops, and answers what it stopped with.
fn serve(vcpu: linux.fd_t, page: []align(std.heap.page_size_min) u8, machine: *Machine, text: Text) !u8 {
    const run: *kvm.Run = @ptrCast(page.ptr);
    while (true) {
        // **THE POWER WENT OUT IN THE LAST EXIT** (faults.zig, `Drive.cut`):
        // the guest runs no further, and the image keeps what landed.
        if (machine.drive) |d| if (d.cut) |cut| {
            // A write cache loses what was never flushed with it.
            if (machine.write_cache) |c| c.lose();
            if (machine.volume) |v| if (v.cache) |c| c.lose();
            reportCut(cut);
            return machine.stopped orelse 0;
        };
        // **WHAT THE VOLUME'S COMMANDS TOOK** (`VOLUME_LATENCY_US`), paid
        // to the clock before the guest runs again: its spin on the used
        // ring would have counted that long.
        if (machine.volume) |v| {
            machine.time.ns += v.owed_ns;
            v.owed_ns = 0;
        }
        if (machine.volume) |v| if (v.power.cut) |cut| {
            if (machine.write_cache) |c| c.lose();
            if (v.cache) |c| c.lose();
            std.debug.print("metal-vmm: the power was cut after the guest's write {d} to the volume (sector {d}, {d} sectors)\n", .{ cut.write, cut.sector, cut.of });
            return machine.stopped orelse 0;
        };
        const rc = linux.ioctl(vcpu, kvm.run, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue, // a signal, not the guest's business
            else => |e| {
                std.debug.print("metal-vmm: the processor would not run: {s}\n", .{@tagName(e)});
                return error.KvmFailed;
            },
        }
        if (@as(kvm.Exit, @enumFromInt(run.exit_reason)) == .io) {
            const io = kvm.ioExit(page);
            if (io.port == coverage_door) {
                const data = kvm.ioData(page, io);
                const at: coverage.When = .{ .exit = machine.exits, .ns = machine.time.ns };
                const out: SerialOut = .{ .jsonl_fd = machine.coverage_fd };
                if (io.direction != kvm.io_out) {
                    @memset(data, coverage_door_answer);
                } else if (io.size == 4) {
                    if (doorLine(machine.ram, @truncate(readLittle(data)))) |line| machine.serial.door(line, at, out) else {
                        machine.serial.table.lines += 1;
                        machine.serial.table.malformed += 1;
                    }
                } else machine.serial.door(data, at, out);
                continue;
            }
        }
        // **EVERY EXIT IS A TICK OF THIS MACHINE'S CLOCK.** The guest asked
        // the outside world for something, and in here that is the only thing
        // that makes time pass — see clock.zig.
        machine.time.asked();
        machine.exits += 1;
        machine.pump();
        // **A HANG IS A RUN THAT STOPS MAKING PROGRESS**, and on this machine
        // that is a number rather than a feeling: so many exits with nothing
        // printed and no doorbell rung. Saying where the guest is beats being
        // killed by a timeout with nothing to show for it.
        machine.quiet += 1;
        if (machine.quiet > patience) {
            std.debug.print("metal-vmm: the guest has printed nothing and rung no doorbell for {d} exits ({d} ms of its own time). It is here:\n", .{ patience, machine.time.ns / std.time.ns_per_ms });
            report(vcpu, machine.ram, text);
            return error.GuestStuck;
        }
        const exit_reason: kvm.Exit = @enumFromInt(run.exit_reason);
        machine.cost.exit(switch (exit_reason) {
            .io => io: {
                const io = kvm.ioExit(page);
                if (io.direction == kvm.io_out and io.port == tsc_port) break :io .clock;
                if (io.direction == kvm.io_out and io.port == msr_port) break :io .msr;
                break :io .port;
            },
            .mmio => .mmio,
            .rdmsr, .wrmsr => .msr,
            .hlt => .halt,
            else => .other,
        });
        switch (exit_reason) {
            .io => {
                const io = kvm.ioExit(page);
                const data = kvm.ioData(page, io);
                if (io.direction == kvm.io_out) {
                    // **ONLY THE LOADER'S OWN `out`s ARE QUESTIONS.** Any
                    // other write to these ports is the guest's, to nothing.
                    if (io.port == tsc_port or io.port == msr_port) {
                        var regs: kvm.Regs = undefined;
                        _ = try kvm.call(vcpu, kvm.get_regs, @intFromPtr(&regs));
                        if (io.port == tsc_port and machine.rewritten.clocks.has(regs.rip)) {
                            try answerClock(vcpu, &regs, machine.time.ticks());
                            continue;
                        }
                        if (io.port == msr_port and machine.rewritten.deadlines.has(regs.rip)) {
                            machine.msrs += 1;
                            _ = machine.lapic.writeMsr(@truncate(regs.rcx), (regs.rdx << 32) | (regs.rax & 0xFFFF_FFFF), machine.time.ns);
                            continue;
                        }
                    }
                    machine.out(io.port, data);
                    if (machine.stopped) |code| return code;
                } else {
                    machine.in(io.port, data);
                }
            },
            .mmio => {
                const m = kvm.mmioExit(page);
                machine.memory(m.phys_addr, m.is_write != 0, m.data[0..@intCast(m.len)]);
            },
            .hlt => {
                if (machine.bus == null) return machine.stopped orelse 0;
                const halted_at = machine.time.ns;
                const rested = try rest(vcpu, run, machine);
                machine.cost.halted(machine.time.ns - halted_at);
                switch (rested) {
                    .woken => if (machine.rested()) {
                        std.debug.print("metal-vmm: the guest has rested {d} s of its own time with nothing printed and no doorbell rung: idle, so the run ends\n", .{(machine.time.ns - machine.progress_ns) / std.time.ns_per_s});
                        return error.GuestIdle;
                    },
                    .never => {
                        std.debug.print("metal-vmm: the guest halted with nothing that could wake it\n", .{});
                        return machine.stopped orelse 0;
                    },
                    .off => {
                        std.debug.print("metal-vmm: the guest halted with interrupts off, which nothing here ends\n", .{});
                        return machine.stopped orelse 0;
                    },
                }
            },
            .irq_window_open => {
                run.request_interrupt_window = 0;
                machine.lapic.tick(machine.time.ns);
                if (machine.lapic.next()) |v| try inject(vcpu, v);
            },
            .rdmsr => {
                machine.msrs += 1;
                const m = kvm.msrExit(page);
                if (machine.readMsr(m.index)) |v| {
                    m.data = v;
                    m.@"error" = 0;
                } else m.@"error" = 1;
            },
            .wrmsr => {
                machine.msrs += 1;
                const m = kvm.msrExit(page);
                m.@"error" = if (machine.lapic.writeMsr(m.index, m.data, machine.time.ns)) 0 else 1; // IA32_TSC's write among the refused
            },
            .shutdown => {
                std.debug.print("metal-vmm: the guest shut down (a triple fault, most likely)\n", .{});
                report(vcpu, machine.ram, text);
                return error.GuestFaulted;
            },
            .fail_entry => {
                std.debug.print("metal-vmm: the processor refused the state it was given\n", .{});
                return error.KvmFailed;
            },
            .internal_error => {
                std.debug.print("metal-vmm: KVM reported an internal error\n", .{});
                return error.KvmFailed;
            },
            else => |reason| {
                std.debug.print("metal-vmm: unhandled exit {d}\n", .{@intFromEnum(reason)});
                return error.Unhandled;
            },
        }
    }
}

// ── putting it together ──────────────────────────────────────────────────────

/// **THE MOST ONE CLIENT'S REQUEST MAY BE** (`PEER_REQUEST`): a whole
/// document past angry-gopher's 1 MiB cap (limits.zig, `body.doc`), so a
/// client can be refused with 413 as well as answered.
const request_max = 2 << 20;
/// Each client's request, read from its file. Not on the stack: eight of
/// them are 16 MiB.
var request_bufs: [wire.max_clients][request_max]u8 = undefined;

/// **A FILE, WHOLE, OR AN ERROR**: read until its end, however many reads
/// that takes, into `into`. A file larger than `into` is `error.TooLarge`,
/// never its first `into.len` bytes: a request cut short is a different
/// request (QUEUE B23, a 17,000-byte head sent as its first 8,192 bytes).
fn readAll(path: [:0]const u8, into: []u8) error{ Unreadable, Empty, TooLarge }![]const u8 {
    const opened = linux.open(path.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(opened) != .SUCCESS) return error.Unreadable;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    var len: usize = 0;
    while (true) {
        if (len == into.len) {
            // Full: the file must end here.
            var one: [1]u8 = undefined;
            const more = linux.read(fd, &one, 1);
            if (linux.errno(more) != .SUCCESS) return error.Unreadable;
            if (more != 0) return error.TooLarge;
            break;
        }
        const n = linux.read(fd, into[len..].ptr, into.len - len);
        if (linux.errno(n) != .SUCCESS) return error.Unreadable;
        if (n == 0) break;
        len += n;
    }
    if (len == 0) return error.Empty;
    return into[0..len];
}

/// What the volume was asked, if one was attached (`VOLUME`): a run without
/// one says nothing new.
/// **THE POWER FAILS WHEN THE GUEST STOPS** (`VOLUME_CUT_AT_EXIT=1`, QUEUE
/// item 68): every write cache loses what was never synchronized, before
/// anything is reported or written back, whatever the end. So a write the
/// guest answered for and never synchronized is gone, even when the
/// response that confirmed it came after the last write. One line says
/// what each lost.
fn cutAtExit(machine: *Machine) void {
    if (!machine.cut_at_exit) return;
    var disk_lost: u64 = 0;
    var volume_lost: u64 = 0;
    if (machine.write_cache) |c| {
        c.loseAtExit();
        disk_lost = c.exit_lost;
    }
    if (machine.volume) |v| if (v.cache) |c| {
        c.loseAtExit();
        volume_lost = c.exit_lost;
    };
    std.debug.print("metal-vmm: the power failed when the guest stopped (VOLUME_CUT_AT_EXIT): {d} volume sectors and {d} disk sectors never synchronized were lost\n", .{ volume_lost, disk_lost });
}

/// The faults that took effect, for a sweep's excuses (metal-vmm QUEUE
/// 124(e)): `reports.fired`.
fn reportFired(card: *const net.Net, block: *const virtio.Block, machine: *const Machine) void {
    var buf: [512]u8 = undefined;
    std.debug.print("{s}", .{reports.fired(&card.peer, &block.refusals, machine.volume, &buf)});
}

fn reportVolume(machine: *const Machine) void {
    const v = machine.volume orelse return;
    var buf: [scsi.Scsi.line_bytes]u8 = undefined;
    std.debug.print("{s}", .{v.line(&buf)});
}

/// What the client got, for a caller that wants to diff it against another
/// client's.
/// **WHICH ENDS KEEP WHAT THE GUEST WROTE** (QUEUE.md item 42): one that
/// ended as the guest meant, by its exit door or a power cut it was dealt,
/// and an idle one, which is a server's normal end. Not a crash, a guest
/// that faulted or got stuck, or anything KVM refused: the image is left as
/// it was found, and a timeout from outside never gets here at all.
fn keepsWrites(e: anyerror) bool {
    return e == error.GuestIdle;
}

test "an idle end keeps the guest's writes; a stuck, faulted or failed one does not" {
    try testing.expect(keepsWrites(error.GuestIdle));
    for ([_]anyerror{ error.GuestStuck, error.GuestFaulted, error.KvmFailed, error.Unhandled }) |e| {
        try testing.expect(!keepsWrites(e));
    }
}

/// **WHAT THE CLIENT GOT, IN ONE LINE** on stdout, so a run here can be
/// compared with a run under QEMU where curl says the same thing; and its
/// body and whole answer to files, when asked (`PEER_BODY`, `PEER_RESPONSE`),
/// every client's. See `reports.client`.
fn theClient(environ: std.process.Environ, peer: *const wire.Peer) void {
    // **A REAL PAGE DOES NOT FIT ON A LINE.** The probes answer with a
    // sentence and the line is compared against curl's; a guest serving an
    // actual site answers with kilobytes, so the body goes to a file when one
    // is asked for and the line says how much there was.
    //
    // **AN ANSWER KEPT IN PART IS NOT WRITTEN AS IF WHOLE.** The client keeps
    // the first `reply.len` bytes of what came back. Past that, the files
    // would hold a page's beginning and a comparison of two of them (rest.sh)
    // would pass on half a page: they are not written, and the line says why,
    // so whatever reads them fails for want of them.
    //
    // **EVERY CLIENT'S ANSWER** (metal-vmm QUEUE 126): client k's goes
    // beside the first's, at `<file>.k` (`reports.answerPath`), so a sweep
    // can hold each client to the same client unhurt.
    const body_stem = environ.getPosix("PEER_BODY");
    const response_stem = environ.getPosix("PEER_RESPONSE");
    if (body_stem != null or response_stem != null) {
        for (0..reports.answered(peer)) |i| {
            const c = peer.clientConst(i);
            if (!reports.keptWhole(c)) {
                var line: [200]u8 = undefined;
                const text = if (i == 0)
                    std.fmt.bufPrint(&line, "metal-vmm: the answer was {d} bytes and the client keeps {d}; PEER_BODY and PEER_RESPONSE are not written\n", .{ c.received, c.reply.len }) catch "metal-vmm: the answer was cut; PEER_BODY and PEER_RESPONSE are not written\n"
                else
                    std.fmt.bufPrint(&line, "metal-vmm: client {d}'s answer was {d} bytes and the client keeps {d}; its PEER_BODY and PEER_RESPONSE are not written\n", .{ i + 1, c.received, c.reply.len }) catch "metal-vmm: a client's answer was cut; its PEER_BODY and PEER_RESPONSE are not written\n";
                _ = linux.write(2, text.ptr, text.len);
                continue;
            }
            var name: [4200]u8 = undefined;
            if (body_stem) |stem| if (reports.answerPath(stem, i, &name)) |into| writeOut(into, c.body()) else writeFailed(stem);
            if (response_stem) |stem| if (reports.answerPath(stem, i, &name)) |into| writeOut(into, c.whole()) else writeFailed(stem);
        }
    }
    var buf: [4096]u8 = undefined;
    const text = reports.client(peer, &buf);
    _ = linux.write(1, text.ptr, text.len);
}

/// Writes `bytes` to `path`, all of them, or says on stderr that it could
/// not: a file left short or missing is never silent.
fn writeOut(path: [:0]const u8, bytes: []const u8) void {
    const opened = linux.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (linux.errno(opened) != .SUCCESS) return writeFailed(path);
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(fd, bytes[done..].ptr, bytes.len - done);
        if (linux.errno(n) != .SUCCESS or n == 0) return writeFailed(path);
        done += n;
    }
}

fn writeFailed(path: [:0]const u8) void {
    var line: [4200]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "metal-vmm: could not write {s} whole\n", .{path}) catch "metal-vmm: could not write an answer's file whole\n";
    _ = linux.write(2, text.ptr, text.len);
}

/// The file, mapped rather than read: it is only ever looked at, and the
/// kernels are megabytes.
fn mapFile(path: [*:0]const u8) ![]align(std.heap.page_size_min) const u8 {
    const opened = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(opened) != .SUCCESS) return error.CannotOpen;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    const size = linux.lseek(fd, 0, linux.SEEK.END);
    if (linux.errno(size) != .SUCCESS or size == 0) return error.CannotSize;
    return posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
}

fn sayUnknown(name: []const u8) void {
    std.debug.print("metal-vmm: {s} is not a setting metal-vmm reads; ignored (KNOBS.md)\n", .{name});
}

pub fn main(init: std.process.Init.Minimal) !u8 {
    const argv = init.args.vector;
    if (argv.len < 2) {
        std.debug.print("usage: metal-vmm <kernel.elf> [disk.img] [command line] [path to fetch]\n", .{});
        return 2;
    }
    const path = argv[1];
    const disk_path: ?[*:0]const u8 = if (argv.len > 2 and argv[2][0] != 0) argv[2] else null;
    const command_line = if (argv.len > 3) std.mem.span(argv[3]) else "";
    const fetch: ?[]const u8 = if (argv.len > 4 and argv[4][0] != 0) std.mem.span(argv[4]) else null;

    // **EVERY SETTING SAYS WHAT IT MEANS, OR THE RUN DOES NOT START**
    // (checked.zig): a value that is not one is refused here, before any of
    // them is read, rather than read as no fault.
    var complaint_buf: [512]u8 = undefined;
    if (checked.complaint(init.environ.block.view().slice, &complaint_buf, sayUnknown)) |why| {
        std.debug.print("metal-vmm: {s} (KNOBS.md)\n", .{why});
        return 2;
    }

    const image = mapFile(path) catch |e| {
        std.debug.print("metal-vmm: cannot read {s}: {s}\n", .{ path, @errorName(e) });
        return 2;
    };

    const opened = linux.open(kvm.device, .{ .ACCMODE = .RDWR }, 0);
    if (linux.errno(opened) != .SUCCESS) {
        std.debug.print("metal-vmm: cannot open {s}: {s}\n", .{ kvm.device, @tagName(linux.errno(opened)) });
        return 2;
    }
    const dev: linux.fd_t = @intCast(opened);
    defer _ = linux.close(dev);
    const version = try kvm.call(dev, kvm.get_api_version, 0);
    if (version != kvm.api_version) {
        std.debug.print("metal-vmm: this is KVM version {d}, not {d}\n", .{ version, kvm.api_version });
        return 2;
    }

    const vm: linux.fd_t = @intCast(try kvm.call(dev, kvm.create_vm, 0));
    defer _ = linux.close(vm);

    // **`TRANSPORT=pci` IS THE PC-SHAPED MACHINE**: the devices on a PCI bus,
    // an APIC, and a guest that halts between frames, as gopher-metal does on
    // a droplet. Unset is the microvm-shaped machine check.sh compares with
    // QEMU's microvm.
    const pc = if (init.environ.getPosix("TRANSPORT")) |t| std.mem.eql(u8, t, "pci") else false;
    if (pc) ownTheMsrs(vm) catch |e| {
        std.debug.print("metal-vmm: this KVM will not hand over the APIC's MSRs ({s}): TRANSPORT=pci needs Linux 5.10 or later\n", .{@errorName(e)});
        return 2;
    };

    const ram = try posix.mmap(null, ram_bytes, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    // **HUGE PAGES FOR THE GUEST'S MEMORY, IF THE HOST GIVES THEM** (its
    // transparent huge pages are "madvise" here): the guest's first touch of
    // each 4 KiB page was a fault of the host's, about 26,000 a boot. A
    // speed-up only: refused, it is the run it was.
    _ = linux.madvise(ram.ptr, ram.len, linux.MADV.HUGEPAGE);
    var region = kvm.MemoryRegion{
        .slot = 0,
        .guest_phys_addr = 0,
        .memory_size = ram_bytes,
        .userspace_addr = @intFromPtr(ram.ptr),
    };
    _ = try kvm.call(vm, kvm.set_user_memory_region, @intFromPtr(&region));

    const loaded = load(ram, image) catch |e| {
        std.debug.print("metal-vmm: {s} is not a kernel this can start: {s}\n", .{ path, @errorName(e) });
        return 2;
    };
    writeGdt(ram);
    const start_info = tell(ram, command_line);

    const vcpu: linux.fd_t = @intCast(try kvm.call(vm, kvm.create_vcpu, 0));
    defer _ = linux.close(vcpu);
    const page_size = try kvm.call(dev, kvm.get_vcpu_mmap_size, 0);
    const page = try posix.mmap(null, page_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, vcpu, 0);

    try describeProcessor(dev, vcpu, pc);
    try enterProtectedMode(vcpu, loaded.entry, start_info);

    // **THE DEVICES GO IN THE FIRST SLOTS**, which is not what QEMU does (it
    // fills from the top) and does not matter: the guest scans every slot and
    // takes the first of the kind it wants.
    var machine = Machine{ .ram = ram, .rewritten = .{ .clocks = loaded.clocks, .deadlines = loaded.deadlines } };
    // **A KERNEL THAT MARKS NO DEADLINE** writes IA32_TSC_DEADLINE where
    // this machine's APIC never hears it, and its every rest waits for a
    // frame instead of its timer. Said once, at the start, rather than found
    // as a run that ends early.
    if (pc and loaded.deadlines.len == 0) {
        std.debug.print("metal-vmm: this kernel marks no deadline write (mov $\"mvmd\", %esi before wrmsr), so on TRANSPORT=pci no APIC timer it arms is heard\n", .{});
    }
    // A run with no disk still has a disk's faults to set and report: none,
    // on a block device with nothing behind it, never memory left undefined.
    var block: virtio.Block = .{ .image = &.{} };
    var block_device: virtio.Device = undefined;
    var drive: ?disk.Disk = null;
    if (disk_path) |on_disk| {
        drive = disk.Disk.open(on_disk) catch |e| {
            std.debug.print("metal-vmm: cannot open the disk: {s}\n", .{@errorName(e)});
            return 2;
        };
        block = .{ .image = drive.?.bytes, .dirty = drive.?.dirty };
        // `DISK_TRACE=1` prints every request the guest makes, which is how a
        // question like "why is one chat message eighty writes" gets answered.
        if (init.environ.getPosix("DISK_TRACE")) |v| block.trace = std.mem.eql(u8, v, "1");
        block_device = block.device();
        machine.drive = &block.refusals;
        if (!pc) machine.devices[0] = &block_device;
    }
    // **THE WIRE ENDS HERE, ON PURPOSE.** There is always a network device,
    // because the machine at the other end of it is this program and costs
    // nothing when nobody talks to it.
    var card = net.Net{};
    var net_device = card.device();
    if (!pc) machine.devices[1] = &net_device;
    machine.card = &card;
    machine.card_device = &net_device;
    // **AND THERE IS ALWAYS ENTROPY**, for the same reason: it is ours, it is
    // seeded, and it costs nothing when nobody draws from it.
    var dice = entropy.Entropy{};
    var dice_device = dice.device();
    if (!pc) machine.devices[2] = &dice_device;
    // **A VOLUME, IF ONE IS ATTACHED** (`VOLUME=<file>`, scsi.zig): a SCSI
    // disk on a virtio-scsi controller, as prod's chat data is.
    var volume: scsi.Scsi = .{ .image = &.{} };
    var volume_device: virtio.Device = undefined;
    var volume_drive: ?disk.Disk = null;
    // Out here, not in the block below: the disk keeps its path to write
    // back to at the run's end.
    var path_buf: [4096]u8 = undefined;
    if (init.environ.getPosix("VOLUME")) |name| {
        if (name.len >= path_buf.len) {
            std.debug.print("metal-vmm: the volume's name is too long: {s}\n", .{name});
            return 2;
        }
        @memcpy(path_buf[0..name.len], name);
        path_buf[name.len] = 0;
        volume_drive = disk.Disk.open(path_buf[0..name.len :0]) catch |e| {
            std.debug.print("metal-vmm: cannot open the volume {s}: {s}\n", .{ name, @errorName(e) });
            return 2;
        };
        volume = .{ .image = volume_drive.?.bytes, .dirty = volume_drive.?.dirty };
        volume_device = volume.device();
        machine.volume = &volume;
        if (!pc) machine.devices[3] = &volume_device;
    }
    // The same three, in slots of a PCI bus instead. The guest asks for each
    // kind by type, so the order is only the order a scan finds them in.
    var bus = pci.Bus{};
    if (pc) {
        machine.bus = &bus;
        if (disk_path != null) _ = bus.plug(1, &block_device, &machine.lapic);
        _ = bus.plug(2, &net_device, &machine.lapic);
        _ = bus.plug(3, &dice_device, &machine.lapic);
        if (machine.volume != null) _ = bus.plug(4, &volume_device, &machine.lapic);
    }

    // **THE FAULTS: A SEED'S, UNDER WHAT THE ENVIRONMENT SETS BY HAND**
    // (knobs.zig). A seeded run says what it chose, as the knobs that would
    // repeat it without the seed.
    var turned = if (count(init.environ, "FAULT_SEED")) |seed| knobs.Knobs.fromSeed(seed) else knobs.Knobs{};
    // A seed's volume faults, only with a volume, so no run without one moves.
    if (count(init.environ, "FAULT_SEED")) |seed| if (init.environ.getPosix("VOLUME") != null) turned.withVolume(seed);
    turned.overlay(init.environ);
    if (count(init.environ, "FAULT_SEED")) |seed| {
        var line: [1024]u8 = undefined;
        std.debug.print("metal-vmm: FAULT_SEED={d} is {s}\n", .{ seed, turned.format(&line) });
    }
    tellTheFaults(&card.line, &block.refusals, &card.peer.rough, &turned);
    // **THE LEASE THE PEER HANDS OUT** (`DHCP_LEASE_S`, a day unset): a
    // short one runs out within a run, and the run's end says whether the
    // guest renewed it.
    if (turned.get("DHCP_LEASE_S")) |text| {
        card.peer.lease_s = std.math.clamp(std.fmt.parseInt(u32, text, 10) catch 86_400, 1, std.math.maxInt(u32));
        card.peer.lease_named = true;
    }
    // **THE CALENDAR AS A KNOB** (`RTC_BOOTS_AT=unix`): the day the chip
    // boots on, from 1970 to 9999. Every run with it boots on that instant.
    if (turned.get("RTC_BOOTS_AT")) |text| {
        const at = std.fmt.parseInt(i64, text, 10) catch -1;
        if (at < 0 or at > clock.last_boot) {
            std.debug.print("metal-vmm: RTC_BOOTS_AT={s} is not a time from 1970 to 9999\n", .{text});
            return 2;
        }
        machine.rtc.from = at;
    }
    // **CLOCKS THAT DO NOT ANSWER** (QUEUE item 82): no RTC, an RTC stuck
    // mid-update, a PIT that never counts. Each reaches a refusal the guest
    // names and no other run can.
    if (turned.get("RTC_ABSENT")) |text| machine.rtc.absent = std.mem.eql(u8, text, "1");
    if (turned.get("RTC_STUCK")) |text| machine.rtc.stuck = std.mem.eql(u8, text, "1");
    if (turned.get("PIT_FROZEN")) |text| machine.pit.frozen = std.mem.eql(u8, text, "1");
    // **A WRITE CACHE, AND FLUSH OFFERED**, only when asked: offering the
    // feature changes what the guest negotiates, and check.sh holds the
    // default machine to QEMU's.
    var write_cache: cache.Cache = undefined;
    defer if (block.cache) |c| c.deinit();
    if (turned.get("DISK_CACHE")) |how| if (block.image.len > 0) {
        write_cache = .{ .gpa = std.heap.page_allocator, .image = block.image, .lies = std.mem.eql(u8, how, "lie") };
        block.cache = &write_cache;
        block_device.features_low |= virtio.feature_blk_flush;
        machine.write_cache = &write_cache;
    };
    // **THE VOLUME'S CACHE AND POWER** (`VOLUME_CACHE=1|lie`,
    // `VOLUME_CUT_AFTER=n`, scsi.zig): its WCE bit, said truly or not, and
    // the write the power goes after; and the SYNCHRONIZE CACHEs that fail
    // (`VOLUME_SYNC_FAIL=n`, `VOLUME_SYNC_FAIL_FOR=k`).
    var volume_cache: cache.Cache = undefined;
    defer if (volume.cache) |c| c.deinit();
    if (machine.volume != null) {
        if (turned.get("VOLUME_CACHE")) |how| {
            volume_cache = .{ .gpa = std.heap.page_allocator, .image = volume.image, .lies = std.mem.eql(u8, how, "lie") };
            if (turned.get("VOLUME_CACHE_KEEPS")) |text| if (std.fmt.parseInt(u64, text, 10) catch null) |k| if (k > 0) {
                volume_cache.keeps = k;
                volume_cache.keep_seed = count(init.environ, "FAULT_SEED") orelse 0;
            };
            volume.cache = &volume_cache;
        }
        if (turned.get("VOLUME_CUT_AT_EXIT")) |text| machine.cut_at_exit = std.mem.eql(u8, text, "1");
        if (turned.get("VOLUME_CUT_AFTER")) |text| if (std.fmt.parseInt(u64, text, 10) catch null) |n| if (n > 0) {
            volume.power.cut_after = n;
        };
        if (turned.get("VOLUME_ATTENTION_AT")) |text| if (std.fmt.parseInt(u64, text, 10) catch null) |n| if (n > 0) {
            volume.attention_at = n;
        };
        if (turned.get("VOLUME_RESET_AT")) |text| if (std.fmt.parseInt(u64, text, 10) catch null) |n| if (n > 0) {
            volume.reset_at = n;
        };
        if (turned.get("VOLUME_SECTOR")) |text| if (std.fmt.parseInt(u32, text, 10) catch null) |n| if (n > 0) {
            volume.sector_said = n;
        };
        if (turned.get("VOLUME_MODE_PAGES")) |text| volume.no_mode_pages = std.mem.eql(u8, text, "none");
        if (turned.get("VOLUME_WCE_FIXED")) |text| volume.wce_fixed = if (std.mem.eql(u8, text, "1")) .refuses else if (std.mem.eql(u8, text, "ignore")) .ignores else .no;
        if (turned.get("VOLUME_GONE_AT")) |text| if (std.fmt.parseInt(u64, text, 10) catch null) |n| if (n > 0) {
            volume.gone_at = n;
        };
        if (turned.get("VOLUME_READ_ONLY_AT")) |text| if (std.fmt.parseInt(u64, text, 10) catch null) |n| if (n > 0) {
            volume.read_only_at = n;
        };
        if (turned.get("VOLUME_SHORT_AT")) |text| if (std.fmt.parseInt(u64, text, 10) catch null) |n| if (n > 0) {
            volume.short_at = n;
        };
        if (turned.get("VOLUME_SYNC_US")) |text| if (std.fmt.parseInt(u64, text, 10) catch null) |us| {
            volume.sync_latency_ns = us * std.time.ns_per_us;
        };
        if (turned.get("VOLUME_LATENCY_US")) |text| if (std.fmt.parseInt(u64, text, 10) catch null) |us| {
            volume.latency_ns = us * std.time.ns_per_us;
        };
        if (turned.get("VOLUME_SYNC_FAIL")) |text| if (std.fmt.parseInt(u64, text, 10) catch null) |n| if (n > 0) {
            volume.sync_fail_at = n;
        };
        if (turned.get("VOLUME_SYNC_FAIL_FOR")) |text| if (std.fmt.parseInt(u64, text, 10) catch null) |n| if (n > 0) {
            volume.sync_fail_for = n;
        };
    }
    if (count(init.environ, "PATIENCE_S")) |seconds| machine.patience_ns = seconds * std.time.ns_per_s;
    // **COVERAGE LINES TO A FILE OF THEIR OWN**, appended: each boot of a
    // sweep adds its lines to the same JSONL, as the judge's do.
    if (init.environ.getPosix("COVERAGE_OUT")) |out_path| {
        const jsonl = linux.open(out_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
        if (linux.errno(jsonl) != .SUCCESS) {
            std.debug.print("metal-vmm: cannot open COVERAGE_OUT {s}\n", .{out_path});
            return 2;
        }
        machine.coverage_fd = @intCast(jsonl);
        machine.serial.withhold = true;
        // Which run the lines that follow are, for a report over many (the
        // SDK's `tools/report.py`): its seed, and the knobs that repeat it.
        var knob_text: [1024]u8 = undefined;
        var run_buf: [1200]u8 = undefined;
        if (coverage.runLine(&run_buf, count(init.environ, "FAULT_SEED"), turned.format(&knob_text))) |run| {
            SerialOut.jsonl(.{ .jsonl_fd = machine.coverage_fd }, run);
        } else |_| {}
    }

    // **WHAT THE PEER ASKS FOR.** A path is enough for a probe; a server with
    // a login and a chat wants a whole request, cookie and body and all, so
    // `PEER_REQUEST=<file>` sends those bytes exactly as they are.
    //
    // **AND HOW MANY ASK** (peer.zig, `Plan`): `PEER_CLIENTS=n` clients, a
    // gap apart (`PEER_CLIENT_GAP_US`; with `PEER_IN_TURN=1`, a gap after
    // the one before was answered), each asking `PEER_ASKS=k` times on
    // its own connection. `PEER_REQUEST=a,b,...` names a file for each
    // client; a client past the list asks the last one's.
    const plan = &card.peer.plan;
    if (count(init.environ, "PEER_CLIENTS")) |n| plan.clients = @intCast(std.math.clamp(n, 1, wire.max_clients));
    if (count(init.environ, "PEER_ASKS")) |n| plan.asks = @intCast(std.math.clamp(n, 1, 1000));
    if (count(init.environ, "PEER_CLIENT_GAP_US")) |us| plan.gap_ns = us * std.time.ns_per_us;
    if (init.environ.getPosix("PEER_IN_TURN")) |v| plan.in_turn = std.mem.eql(u8, v, "1");
    if (init.environ.getPosix("PEER_REQUEST")) |files| {
        var each = std.mem.tokenizeScalar(u8, files, ',');
        while (each.next()) |from| {
            if (plan.named == wire.max_clients) break;
            var name: [4096]u8 = undefined;
            if (from.len >= name.len) {
                std.debug.print("metal-vmm: a request file's name is too long: {s}\n", .{from});
                return 2;
            }
            @memcpy(name[0..from.len], from);
            name[from.len] = 0;
            plan.requests[plan.named] = readAll(name[0..from.len :0], &request_bufs[plan.named]) catch |e| {
                switch (e) {
                    error.TooLarge => std.debug.print("metal-vmm: the request in {s} is larger than {d} bytes, the most a client sends\n", .{ from, request_max }),
                    error.Empty => std.debug.print("metal-vmm: the request in {s} is empty\n", .{from}),
                    error.Unreadable => std.debug.print("metal-vmm: cannot read the request in {s}\n", .{from}),
                }
                return 2;
            };
            plan.named += 1;
        }
        if (plan.named > 0) machine.request = plan.requests[0];
    } else if (fetch) |target| {
        // A client that asks again keeps the connection; one that asks once
        // says it will close, as curl's judge does.
        const close = if (plan.asks > 1) "" else "Connection: close\r\n";
        machine.request = std.fmt.bufPrint(&request_bufs[0], "GET {s} HTTP/1.1\r\nHost: 10.0.2.15\r\n{s}\r\n", .{ target, close }) catch null;
    }

    // **A RUN THAT ENDS BADLY STILL SAYS WHAT WAS DONE TO IT.** The faults
    // below are the first thing anybody reads after a guest gets stuck, so
    // they are reported before the error goes anywhere.
    const code = serve(vcpu, page, &machine, .{ .lo = loaded.text_lo, .hi = loaded.text_hi }) catch |e| {
        cutAtExit(&machine);
        reportRun(&card, &block, machine.time.ns);
        reportVolume(&machine);
        reportFired(&card, &block, &machine);
        reports.cost(&machine, &card, &block);
        reportCoverage(&machine);
        // **AN IDLE END IS A SERVER'S NORMAL END**: a guest serving more than
        // one request always ends this way, so its disk keeps what it wrote
        // and it says what the client got, as any end does. The error, and so
        // the exit code, still says idle.
        if (keepsWrites(e)) if (drive) |*on_disk| {
            _ = on_disk.writeBack() catch |w| {
                std.debug.print("metal-vmm: the disk would not take the run's writes: {s}\n", .{@errorName(w)});
                return 1;
            };
        };
        if (keepsWrites(e)) if (volume_drive) |*on_disk| {
            _ = on_disk.writeBack() catch |w| {
                std.debug.print("metal-vmm: the volume would not take the run's writes: {s}\n", .{@errorName(w)});
                return 1;
            };
        };
        if (e == error.GuestIdle and fetch != null) theClient(init.environ, &card.peer);
        return e;
    };
    // **WHAT THE WIRE DID, IF IT WAS ASKED TO DO ANYTHING**, on the error
    // stream: a run with a perfect wire says nothing, so the probes' output
    // stays comparable with QEMU's.
    cutAtExit(&machine);
    reportRun(&card, &block, machine.time.ns);
    reportVolume(&machine);
    reportFired(&card, &block, &machine);
    if (pc) reportRest(&machine);
    reports.cost(&machine, &card, &block);
    reportCoverage(&machine);
    // **THE FILE LEARNS WHAT HAPPENED ONLY NOW**, and only the sectors the
    // guest actually wrote. A run that never gets here leaves the image as it
    // found it — see disk.zig.
    if (drive) |*on_disk| {
        _ = on_disk.writeBack() catch |e| {
            std.debug.print("metal-vmm: the disk would not take the run's writes: {s}\n", .{@errorName(e)});
            return 1;
        };
    }
    if (volume_drive) |*on_disk| {
        _ = on_disk.writeBack() catch |e| {
            std.debug.print("metal-vmm: the volume would not take the run's writes: {s}\n", .{@errorName(e)});
            return 1;
        };
    }
    if (fetch != null) theClient(init.environ, &card.peer);
    return code;
}

// ── the parts that can be checked without a processor ────────────────────────

const testing = std.testing;

// **THE OTHER FILES' TESTS DO NOT RUN UNLESS SOMETHING NAMES THEM.** A test
// build has no entry point, so `main` is never analysed and neither is
// anything only it mentions.
test {
    _ = @import("clock.zig");
    _ = @import("entropy.zig");
    _ = @import("disk.zig");
    _ = @import("virtio.zig");
    _ = @import("scsi.zig");
    _ = @import("mangle.zig");
    _ = @import("net.zig");
    _ = @import("peer.zig");
    _ = @import("apic.zig");
    _ = @import("pci.zig");
    _ = @import("virtio_pci.zig");
    _ = @import("msix.zig");
    _ = @import("coverage.zig");
    _ = @import("knobs.zig");
    _ = @import("fuzz.zig");
    _ = @import("determinism.zig");
    _ = @import("snapshot.zig");
    _ = @import("cost.zig");
    _ = @import("cache.zig");
    _ = @import("settings.zig");
    _ = @import("reports.zig");
    _ = @import("loader.zig");
    _ = @import("processor.zig");
    _ = @import("halt.zig");
    _ = @import("checked.zig");
}

test "a request file is read whole, past one read's worth, and one too large is refused, not cut" {
    const path = "/tmp/metal-vmm-readall-test";
    var bytes: [20_000]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @truncate(i *% 31);
    const fd = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(fd));
    try std.testing.expectEqual(bytes.len, linux.write(@intCast(fd), &bytes, bytes.len));
    _ = linux.close(@intCast(fd));
    defer _ = linux.unlink(path);

    var room: [32 * 1024]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &bytes, try readAll(path, &room));
    var exact: [20_000]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &bytes, try readAll(path, &exact));
    var small: [8192]u8 = undefined;
    try std.testing.expectError(error.TooLarge, readAll(path, &small));
    try std.testing.expectError(error.Unreadable, readAll("/tmp/metal-vmm-readall-no-such-file", &small));
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

// ── a halt's decision, without a processor ──────────────────────────────────

test "a halt is not a hang: it starts the count of quiet exits again" {
    var machine = Machine{};
    machine.quiet = patience - 1;
    machine.time.ns = std.time.ns_per_s;
    try testing.expect(!machine.rested());
    try testing.expectEqual(@as(u64, 0), machine.quiet);
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

test "the census: every field of the machine is named, and is what it says (metal-vmm QUEUE 113)" {
    const snapshot = @import("snapshot.zig");
    comptime {
        @setEvalBranchQuota(2_000_000);
        const fields = @typeInfo(Machine).@"struct".fields;
        for (fields) |f| {
            const holds: Holds = for (census) |c| {
                if (std.mem.eql(u8, c[0], f.name)) {
                    if ((c[1] == .box or c[1] == .input or c[1] == .host) and c[2].len == 0)
                        @compileError("main.zig: Machine." ++ f.name ++ " is not saved with the machine: say why in its census line");
                    break c[1];
                }
            } else @compileError("main.zig: Machine." ++ f.name ++ " is in no line of `census`: say how a snapshot gets it back");
            switch (holds) {
                .value => if (snapshot.pointersIn(f.type, "Machine." ++ f.name).len > 0)
                    @compileError("main.zig: Machine." ++ f.name ++ " is called a value, and holds a pointer: " ++ snapshot.pointersIn(f.type, "Machine." ++ f.name)),
                .model => {
                    const M = pointee(f.type);
                    for (snapshot.models) |known| {
                        if (known == M) break;
                    } else @compileError("main.zig: Machine." ++ f.name ++ " points at " ++ @typeName(M) ++ ", which is not in snapshot.models");
                },
                .apart => if (snapshot.saverOf(pointee(f.type)) == null)
                    @compileError("main.zig: Machine." ++ f.name ++ " is said to be saved apart, and snapshot.saverOf has no saver for " ++ @typeName(pointee(f.type))),
                .box => if (f.type != []u8)
                    @compileError("main.zig: Machine." ++ f.name ++ " is called guest memory, and is not bytes"),
                .input => {
                    const T = switch (@typeInfo(f.type)) {
                        .optional => |o| o.child,
                        else => f.type,
                    };
                    const info = @typeInfo(T);
                    if (info != .pointer or !info.pointer.is_const)
                        @compileError("main.zig: Machine." ++ f.name ++ " is called an input, and is not read-only memory");
                },
                .host => if (snapshot.pointersIn(f.type, "").len > 0)
                    @compileError("main.zig: Machine." ++ f.name ++ " is called the host's, and holds a pointer"),
            }
        }
        for (census) |c| {
            for (fields) |f| {
                if (std.mem.eql(u8, c[0], f.name)) break;
            } else @compileError("main.zig: `census` names Machine." ++ c[0] ++ ", which is not a field");
        }
    }
}
