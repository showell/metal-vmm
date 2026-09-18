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
const wire = @import("peer.zig");

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

const ElfHeader = extern struct {
    ident: [16]u8,
    type: u16,
    machine: u16,
    version: u32,
    entry: u64,
    phoff: u64,
    shoff: u64,
    flags: u32,
    ehsize: u16,
    phentsize: u16,
    phnum: u16,
    shentsize: u16,
    shnum: u16,
    shstrndx: u16,
};

const ProgramHeader = extern struct {
    type: u32,
    flags: u32,
    offset: u64,
    vaddr: u64,
    paddr: u64,
    filesz: u64,
    memsz: u64,
    alignment: u64,

    const load: u32 = 1;
    const note: u32 = 4;
    const executable: u32 = 1;
};

/// What a loaded kernel amounts to: where to start it, and how many of its
/// clock reads this program now answers.
const Loaded = struct {
    entry: u64,
    clock_reads: usize,
};

/// **`rdtsc` DOES NOT EXIT, SO THE LOADER MAKES IT ONE.** It is two bytes,
/// `0F 31`, and `out 0xE0, al` is also two bytes, `E6 E0` — so every
/// timestamp read in the guest's text becomes an ordinary port write that
/// lands in this program, which answers it from clock.zig and puts the value
/// in EDX:EAX exactly as the instruction would have.
///
/// **THE FILE ON DISK IS NOT TOUCHED.** The substitution happens in the copy
/// in guest memory, so QEMU still runs the same bytes and check.sh stays an
/// honest oracle.
///
/// Two bytes is a short pattern to search for, and a `0F 31` that fell inside
/// some other instruction's operand would corrupt the guest silently. Counted
/// across nine of gopher-metal's kernels, the number of these pairs in the
/// loadable segment equals the number of `rdtsc` instructions a disassembler
/// finds, every time — 34 in the clock probe, 12 in stdhttp, none in rng.
/// x86 leaves this pair unlikely to land on by accident, and these kernels
/// keep no data in their text.
fn rewriteClockReads(segment: []u8) usize {
    const rdtsc = [2]u8{ 0x0F, 0x31 };
    const out_to_us = [2]u8{ 0xE6, @as(u8, @intCast(tsc_port)) };
    var found: usize = 0;
    var at: usize = 0;
    while (at + 2 <= segment.len) {
        if (std.mem.eql(u8, segment[at..][0..2], &rdtsc)) {
            @memcpy(segment[at..][0..2], &out_to_us);
            found += 1;
            at += 2;
        } else {
            at += 1;
        }
    }
    return found;
}

const NoteHeader = extern struct {
    namesz: u32,
    descsz: u32,
    type: u32,

    /// Xen's number for "the 32-bit entry point", which is the whole reason
    /// this program reads notes at all.
    const phys32_entry: u32 = 18;
};

const LoadError = error{ NotAnElf, NotX86_64, NoPvhNote, DoesNotFit };

/// Copies every loadable segment to the physical address it asks for, and
/// answers the PVH entry point. **A segment is placed by `paddr`, not
/// `vaddr`**: the kernel is linked to run at one address and loaded at
/// another, and the loader's job is the second one.
fn load(ram: []u8, image: []const u8) LoadError!Loaded {
    if (image.len < @sizeOf(ElfHeader)) return error.NotAnElf;
    const head: *const ElfHeader = @ptrCast(@alignCast(image.ptr));
    if (!std.mem.eql(u8, head.ident[0..4], "\x7fELF")) return error.NotAnElf;
    if (head.ident[4] != 2 or head.machine != 62) return error.NotX86_64; // 64-bit, x86-64

    var entry: ?u64 = null;
    var clock_reads: usize = 0;
    for (0..head.phnum) |i| {
        const at = head.phoff + i * head.phentsize;
        if (at + @sizeOf(ProgramHeader) > image.len) return error.NotAnElf;
        const ph: *const ProgramHeader = @ptrCast(@alignCast(image.ptr + at));
        switch (ph.type) {
            ProgramHeader.load => {
                const to: usize = @intCast(ph.paddr);
                const from: usize = @intCast(ph.offset);
                const in_file: usize = @intCast(ph.filesz);
                const in_memory: usize = @intCast(ph.memsz);
                if (to + in_memory > ram.len or from + in_file > image.len) return error.DoesNotFit;
                @memcpy(ram[to..][0..in_file], image[from..][0..in_file]);
                // **.bss IS NOT ZERO UNLESS SOMEBODY ZEROES IT.** The memory
                // is fresh from the kernel here, so it already is — but a
                // second boot into the same memory would not be, and this
                // program is going to run guests over and over.
                @memset(ram[to + in_file ..][0 .. in_memory - in_file], 0);
                if (ph.flags & ProgramHeader.executable != 0) {
                    clock_reads += rewriteClockReads(ram[to..][0..in_file]);
                }
            },
            ProgramHeader.note => {
                if (pvhEntry(image, ph.*)) |found| entry = found;
            },
            else => {},
        }
    }
    return .{ .entry = entry orelse return error.NoPvhNote, .clock_reads = clock_reads };
}

/// The 32-bit entry address out of a PT_NOTE segment, if it names one.
fn pvhEntry(image: []const u8, ph: ProgramHeader) ?u64 {
    var at: usize = @intCast(ph.offset);
    const end = at + @as(usize, @intCast(ph.filesz));
    while (at + @sizeOf(NoteHeader) <= end and end <= image.len) {
        const note: *const NoteHeader = @ptrCast(@alignCast(image.ptr + at));
        const name_at = at + @sizeOf(NoteHeader);
        const desc_at = name_at + std.mem.alignForward(usize, note.namesz, 4);
        const next = desc_at + std.mem.alignForward(usize, note.descsz, 4);
        if (next > end) return null;
        const name = image[name_at..][0..note.namesz];
        if (note.type == NoteHeader.phys32_entry and std.mem.startsWith(u8, name, "Xen") and note.descsz == 4) {
            return std.mem.readInt(u32, image[desc_at..][0..4], .little);
        }
        at = next;
    }
    return null;
}

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

/// Tells the processor what kind of processor it is, by asking this one —
/// minus the two instructions that would let the guest reach outside this
/// program for entropy. Without any of it the guest cannot enter long mode;
/// see `kvm.get_supported_cpuid`.
fn describeProcessor(dev: linux.fd_t, vcpu: linux.fd_t) !void {
    var buffer: kvm.CpuidBuffer = undefined;
    buffer.head = .{ .nent = kvm.max_cpuid_entries };
    _ = try kvm.call(dev, kvm.get_supported_cpuid, @intFromPtr(&buffer));
    for (buffer.entries[0..buffer.head.nent]) |*e| forgetTheDice(e);
    _ = try kvm.call(vcpu, kvm.set_cpuid2, @intFromPtr(&buffer));
}

/// **A MACHINE WITH `RDRAND` HAS AN INPUT NOBODY CAN INTERCEPT.** The
/// instruction does not exit, cannot be trapped, and answers from the
/// processor's own noise — and the guest mixes its answer into every draw it
/// makes, so leaving it in would make every draw unrepeatable however good the
/// device in entropy.zig is. So this machine does not have it: the bits are
/// cleared out of the CPUID the vCPU is given, and the guest, which is built
/// to find sources rather than to assume them, uses virtio-rng instead.
fn forgetTheDice(e: *kvm.CpuidEntry) void {
    const rdrand: u32 = 1 << 30; // leaf 1, ECX
    const rdseed: u32 = 1 << 18; // leaf 7 subleaf 0, EBX
    if (e.function == 1) e.ecx &= ~rdrand;
    if (e.function == 7 and e.index == 0) e.ebx &= ~rdseed;
}

/// What the processor was doing when it gave up, which is the only thing worth
/// knowing about a triple fault.
fn report(vcpu: linux.fd_t) void {
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

/// **WHERE THE GUEST'S CLOCK READS ARRIVE.** Nothing on a PC decodes 0xE0, so
/// a write there can only be one of the loader's substitutions — see
/// `rewriteClockReads`.
const tsc_port: u16 = 0xE0;

// ── the interval timer ────────────────────────────────────────────────────────

const pit_channel0: u16 = clock.Pit.channel0_port;
const pit_command: u16 = clock.Pit.command_port;

const Machine = struct {
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
    /// Reads of addresses no device answers. The guest looks for virtio in a
    /// window this program does not fill yet, and a window of zeros is what
    /// "nothing is plugged in there" looks like from inside.
    absent: u64 = 0,

    fn out(self: *Machine, port: u16, bytes: []const u8) void {
        switch (port) {
            com1 => if (self.line_control & divisor_latch == 0) {
                _ = linux.write(1, bytes.ptr, bytes.len);
                self.listen(bytes);
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
        if (virtio.inWindow(addr)) {
            const slot: usize = @intCast((addr - virtio.window_base) / virtio.slot_stride);
            const offset = (addr - virtio.window_base) % virtio.slot_stride;
            if (self.devices[slot]) |device| {
                if (is_write) {
                    device.write(self.ram, offset, @truncate(readLittle(data)));
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
fn answerClock(vcpu: linux.fd_t, ticks: u64) !void {
    var regs: kvm.Regs = undefined;
    _ = try kvm.call(vcpu, kvm.get_regs, @intFromPtr(&regs));
    regs.rax = ticks & 0xFFFFFFFF;
    regs.rdx = ticks >> 32;
    _ = try kvm.call(vcpu, kvm.set_regs, @intFromPtr(&regs));
}

/// Runs until the guest stops, and answers what it stopped with.
fn serve(vcpu: linux.fd_t, page: []align(std.heap.page_size_min) u8, machine: *Machine) !u8 {
    const run: *kvm.Run = @ptrCast(page.ptr);
    while (true) {
        const rc = linux.ioctl(vcpu, kvm.run, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue, // a signal, not the guest's business
            else => |e| {
                std.debug.print("metal-vmm: the processor would not run: {s}\n", .{@tagName(e)});
                return error.KvmFailed;
            },
        }
        // **EVERY EXIT IS A TICK OF THIS MACHINE'S CLOCK.** The guest asked
        // the outside world for something, and in here that is the only thing
        // that makes time pass — see clock.zig.
        machine.time.asked();
        switch (@as(kvm.Exit, @enumFromInt(run.exit_reason))) {
            .io => {
                const io = kvm.ioExit(page);
                const data = kvm.ioData(page, io);
                if (io.direction == kvm.io_out) {
                    if (io.port == tsc_port) {
                        try answerClock(vcpu, machine.time.ticks());
                        continue;
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
            .hlt => return machine.stopped orelse 0,
            .shutdown => {
                std.debug.print("metal-vmm: the guest shut down (a triple fault, most likely)\n", .{});
                report(vcpu);
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

    const ram = try posix.mmap(null, ram_bytes, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
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

    try describeProcessor(dev, vcpu);
    try enterProtectedMode(vcpu, loaded.entry, start_info);

    // **THE DEVICES GO IN THE FIRST SLOTS**, which is not what QEMU does (it
    // fills from the top) and does not matter: the guest scans every slot and
    // takes the first of the kind it wants.
    var machine = Machine{ .ram = ram };
    var block: virtio.Block = undefined;
    var block_device: virtio.Device = undefined;
    var drive: ?disk.Disk = null;
    if (disk_path) |on_disk| {
        drive = disk.Disk.open(on_disk) catch |e| {
            std.debug.print("metal-vmm: cannot open the disk: {s}\n", .{@errorName(e)});
            return 2;
        };
        block = .{ .image = drive.?.bytes, .dirty = drive.?.dirty };
        block_device = block.device();
        machine.devices[0] = &block_device;
    }
    // **THE WIRE ENDS HERE, ON PURPOSE.** There is always a network device,
    // because the machine at the other end of it is this program and costs
    // nothing when nobody talks to it.
    var card = net.Net{};
    var net_device = card.device();
    machine.devices[1] = &net_device;
    machine.card = &card;
    machine.card_device = &net_device;
    // **AND THERE IS ALWAYS ENTROPY**, for the same reason: it is ours, it is
    // seeded, and it costs nothing when nobody draws from it.
    var dice = entropy.Entropy{};
    var dice_device = dice.device();
    machine.devices[2] = &dice_device;

    var request_buf: [256]u8 = undefined;
    if (fetch) |target| {
        machine.request = std.fmt.bufPrint(&request_buf, "GET {s} HTTP/1.1\r\nHost: 10.0.2.15\r\nConnection: close\r\n\r\n", .{target}) catch null;
    }

    const code = try serve(vcpu, page, &machine);
    // **THE FILE LEARNS WHAT HAPPENED ONLY NOW**, and only the sectors the
    // guest actually wrote. A run that never gets here leaves the image as it
    // found it — see disk.zig.
    if (drive) |*on_disk| {
        _ = on_disk.writeBack() catch |e| {
            std.debug.print("metal-vmm: the disk would not take the run's writes: {s}\n", .{@errorName(e)});
            return 1;
        };
    }
    // **WHAT THE CLIENT GOT, IN ONE LINE**, so a run here can be compared with
    // a run under QEMU where curl says the same thing.
    if (fetch != null) {
        const got = card.fetched();
        var line: [512]u8 = undefined;
        // Trailing newlines are trimmed because the shell trims them too, and
        // this line is compared against one built from curl's output.
        const text = std.fmt.bufPrint(&line, "peer: {d} \"{s}\"\n", .{
            got.status(), std.mem.trimEnd(u8, got.body(), "\r\n"),
        }) catch "peer: ?\n";
        _ = linux.write(1, text.ptr, text.len);
    }
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
    _ = @import("net.zig");
    _ = @import("peer.zig");
}

/// A tiny ELF with one loadable segment and one PVH note, built by hand so the
/// loader can be checked without a kernel to hand.
fn fakeKernel(buf: []u8, paddr: u64, entry: u32, body: []const u8) []const u8 {
    @memset(buf, 0);
    const head: *ElfHeader = @ptrCast(@alignCast(buf.ptr));
    head.* = .{
        .ident = .{ 0x7f, 'E', 'L', 'F', 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .type = 2,
        .machine = 62,
        .version = 1,
        .entry = entry,
        .phoff = @sizeOf(ElfHeader),
        .shoff = 0,
        .flags = 0,
        .ehsize = @sizeOf(ElfHeader),
        .phentsize = @sizeOf(ProgramHeader),
        .phnum = 2,
        .shentsize = 0,
        .shnum = 0,
        .shstrndx = 0,
    };
    // The note, then the body, both after the two program headers.
    const note_at = @sizeOf(ElfHeader) + 2 * @sizeOf(ProgramHeader);
    const note: *NoteHeader = @ptrCast(@alignCast(buf.ptr + note_at));
    note.* = .{ .namesz = 4, .descsz = 4, .type = NoteHeader.phys32_entry };
    @memcpy(buf[note_at + @sizeOf(NoteHeader) ..][0..4], "Xen\x00");
    std.mem.writeInt(u32, buf[note_at + @sizeOf(NoteHeader) + 4 ..][0..4], entry, .little);
    const note_len = @sizeOf(NoteHeader) + 8;

    const body_at = note_at + note_len;
    @memcpy(buf[body_at..][0..body.len], body);

    const phs: [*]ProgramHeader = @ptrCast(@alignCast(buf.ptr + @sizeOf(ElfHeader)));
    phs[0] = .{
        .type = ProgramHeader.load,
        .flags = 7,
        .offset = body_at,
        .vaddr = paddr,
        .paddr = paddr,
        .filesz = body.len,
        .memsz = body.len + 16, // some .bss past the file's bytes
        .alignment = 1,
    };
    phs[1] = .{
        .type = ProgramHeader.note,
        .flags = 4,
        .offset = note_at,
        .vaddr = 0,
        .paddr = 0,
        .filesz = note_len,
        .memsz = note_len,
        .alignment = 4,
    };
    return buf[0 .. body_at + body.len];
}

test "a segment is placed where it asks to be, and the note names the entry" {
    var file: [512]u8 align(8) = undefined;
    const image = fakeKernel(&file, 0x100000, 0x100020, "kernel bytes");
    var ram = try testing.allocator.alloc(u8, 0x101000);
    defer testing.allocator.free(ram);
    @memset(ram, 0xAA);

    try testing.expectEqual(@as(u64, 0x100020), (try load(ram, image)).entry);
    try testing.expectEqualStrings("kernel bytes", ram[0x100000..][0.."kernel bytes".len]);
    // **WHAT THE FILE DOES NOT CARRY IS ZEROED**, or a guest booted twice into
    // the same memory finds the last run's `.bss`.
    for (ram[0x100000 + "kernel bytes".len ..][0..16]) |b| try testing.expectEqual(@as(u8, 0), b);
    // And nothing before it was touched.
    try testing.expectEqual(@as(u8, 0xAA), ram[0x100000 - 1]);
}

test "every rdtsc in the guest's text becomes a question for us" {
    var file: [512]u8 align(8) = undefined;
    // Two real ones, and two near misses: 0F 30 is wrmsr, and the 31 0F pair
    // in the middle is the same two bytes the other way round.
    const body = "\x0f\x31\x0f\x30\x31\x0f\x0f\x31";
    const image = fakeKernel(&file, 0x100000, 0x100000, body);
    const ram = try testing.allocator.alloc(u8, 0x101000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);

    const loaded = try load(ram, image);
    try testing.expectEqual(@as(usize, 2), loaded.clock_reads);
    try testing.expectEqualSlices(u8, "\xe6\xe0\x0f\x30\x31\x0f\xe6\xe0", ram[0x100000..][0..body.len]);
}

test "a kernel with no PVH note is refused, rather than started at a guess" {
    var file: [512]u8 align(8) = undefined;
    const image = fakeKernel(&file, 0x100000, 0x100020, "x");
    // Turn the note into something else: the loader must not fall back to the
    // ELF header's own entry, which is a 64-bit address it cannot start at.
    const note_at = @sizeOf(ElfHeader) + 2 * @sizeOf(ProgramHeader);
    const note: *NoteHeader = @ptrCast(@alignCast(@constCast(image.ptr) + note_at));
    note.type = 99;
    const ram = try testing.allocator.alloc(u8, 0x101000);
    defer testing.allocator.free(ram);
    try testing.expectError(error.NoPvhNote, load(ram, image));
}

test "a segment that does not fit in the guest's memory is refused" {
    var file: [512]u8 align(8) = undefined;
    const image = fakeKernel(&file, 0x100000, 0x100020, "too high");
    const ram = try testing.allocator.alloc(u8, 0x1000);
    defer testing.allocator.free(ram);
    try testing.expectError(error.DoesNotFit, load(ram, image));
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
