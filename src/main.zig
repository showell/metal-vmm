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
const coverage = @import("coverage.zig");
const knobs = @import("knobs.zig");
const pci = @import("pci.zig");

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
/// **WHERE THE LOADER PUT ITS PORT WRITES**: the address, as the guest runs
/// it, of each `out` it wrote in place of a marked instruction. An exit on
/// its port from anywhere else is the guest's own `out`, to a port nothing
/// here decodes. (At a port exit, KVM leaves RIP on the `out` itself until
/// the exit is complete.)
const Rewritten = struct {
    at: [1024]u64 = undefined,
    len: usize = 0,

    fn add(self: *Rewritten, address: u64) LoadError!void {
        if (self.len == self.at.len) return error.TooManyMarks;
        self.at[self.len] = address;
        self.len += 1;
    }

    fn has(self: *const Rewritten, address: u64) bool {
        return std.mem.indexOfScalar(u64, self.at[0..self.len], address) != null;
    }
};

const Loaded = struct {
    entry: u64,
    clock_reads: usize,
    /// The `out`s that answer for a marked `rdtsc` and a marked deadline
    /// `wrmsr`.
    clocks: Rewritten = .{},
    deadlines: Rewritten = .{},
    /// **WHERE THE KERNEL'S CODE IS**, which is how a word on the stack can be
    /// told from a return address. Not the loaded image's range: a guest's
    /// stack lives in its own `.bss`, so most of the image is data and every
    /// stack word would look like a caller.
    text_lo: u64 = 0,
    text_hi: u64 = 0,
};

/// One section header, for the one thing this program wants from them.
const SectionHeader = extern struct {
    name: u32,
    type: u32,
    flags: u64,
    addr: u64,
    offset: u64,
    size: u64,
    link: u32,
    info: u32,
    alignment: u64,
    entsize: u64,

    const executable: u64 = 4; // SHF_EXECINSTR
};

/// The address range of everything a guest can execute. A kernel with its
/// section headers stripped answers nothing, and a caller that gets nothing
/// simply does not guess at stacks.
fn textRange(image: []const u8, head: *const ElfHeader) struct { lo: u64, hi: u64 } {
    var lo: u64 = 0;
    var hi: u64 = 0;
    if (head.shentsize != @sizeOf(SectionHeader)) return .{ .lo = 0, .hi = 0 };
    for (0..head.shnum) |i| {
        const at = head.shoff + i * head.shentsize;
        if (at + @sizeOf(SectionHeader) > image.len) break;
        const sh: *const SectionHeader = @ptrCast(@alignCast(image.ptr + at));
        if (sh.flags & SectionHeader.executable == 0 or sh.addr == 0) continue;
        if (lo == 0 or sh.addr < lo) lo = sh.addr;
        if (sh.addr + sh.size > hi) hi = sh.addr + sh.size;
    }
    return .{ .lo = lo, .hi = hi };
}

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
/// **ONLY A MARKED READ.** Two bytes is too short a pattern: gopher.elf
/// (2026-10-05) has 87 `0F 31` pairs in its text and 77 `rdtsc`s, and
/// rewriting the other ten, inside other instructions' operands, stopped the
/// guest on an invalid opcode. gopher-metal's `tsc.read` puts
/// `mov $"mvmc", %ecx` (`B9 6D 76 6D 63`) right before its `rdtsc`; this
/// rewrites the `rdtsc` after that mark and nothing else. A guest that reads the
/// counter without the mark reads the host's, which this does not see.
/// **THE APIC TIMER'S DEADLINE IS ANSWERED THE SAME WAY.** KVM's fast path
/// for IA32_TSC_DEADLINE takes the guest's `wrmsr` before the MSR filter
/// (`ownTheApicMsrs`) sees it, on a host with the VMX preemption timer — this
/// one. So gopher-metal marks that one write with `mov $"mvmd", %esi`
/// (`BE 6D 76 6D 64`), and its `wrmsr` (`0F 30`) becomes `out 0xE1, al`
/// (`E6 E1`): a port write whose registers say which MSR and what value.
fn rewriteDeadlineWrites(segment: []u8, vaddr: u64, into: *Rewritten) LoadError!usize {
    return rewriteMarked(segment, vaddr, into, .{ 0xBE, 'm', 'v', 'm', 'd' }, .{ 0x0F, 0x30 }, msr_port);
}

fn rewriteClockReads(segment: []u8, vaddr: u64, into: *Rewritten) LoadError!usize {
    return rewriteMarked(segment, vaddr, into, .{ 0xB9, 'm', 'v', 'm', 'c' }, .{ 0x0F, 0x31 }, tsc_port);
}

/// Every `instruction` right after `mark` in a segment that runs at `vaddr`
/// becomes `out port, al`, and where it is goes `into` the record.
fn rewriteMarked(segment: []u8, vaddr: u64, into: *Rewritten, mark: [5]u8, instruction: [2]u8, port: u16) LoadError!usize {
    const marked = mark ++ instruction;
    const out_to_us = [2]u8{ 0xE6, @as(u8, @intCast(port)) };
    var found: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, segment, at, &marked)) |k| {
        @memcpy(segment[k + mark.len ..][0..2], &out_to_us);
        try into.add(vaddr + k + mark.len);
        found += 1;
        at = k + marked.len;
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

const LoadError = error{ NotAnElf, NotX86_64, NoPvhNote, DoesNotFit, TooManyMarks };

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
    var clocks: Rewritten = .{};
    var deadlines: Rewritten = .{};
    const text = textRange(image, head);
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
                    clock_reads += try rewriteClockReads(ram[to..][0..in_file], ph.vaddr, &clocks);
                    _ = try rewriteDeadlineWrites(ram[to..][0..in_file], ph.vaddr, &deadlines);
                }
            },
            ProgramHeader.note => {
                if (pvhEntry(image, ph.*)) |found| entry = found;
            },
            else => {},
        }
    }
    return .{
        .entry = entry orelse return error.NoPvhNote,
        .clock_reads = clock_reads,
        .clocks = clocks,
        .deadlines = deadlines,
        .text_lo = text.lo,
        .text_hi = text.hi,
    };
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
fn describeProcessor(dev: linux.fd_t, vcpu: linux.fd_t, pc: bool) !void {
    var buffer: kvm.CpuidBuffer = undefined;
    buffer.head = .{ .nent = kvm.max_cpuid_entries };
    _ = try kvm.call(dev, kvm.get_supported_cpuid, @intFromPtr(&buffer));
    for (buffer.entries[0..buffer.head.nent]) |*e| {
        forgetTheDice(e);
        if (pc) sayTheApic(e);
        if (pc) hideTheHostsTime(e);
    }
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

/// **THE PC-SHAPED MACHINE HAS AN APIC WITH A DEADLINE TIMER** (apic.zig),
/// and says so where gopher-metal looks before it starts one: leaf 1's APIC
/// bit and TSC-deadline bit. No x2APIC: its registers are MSRs this machine
/// does not answer.
fn sayTheApic(e: *kvm.CpuidEntry) void {
    if (e.function != 1) return;
    e.edx |= 1 << 9; // APIC
    e.ecx |= 1 << 24; // TSC-deadline
    e.ecx &= ~@as(u32, 1 << 21); // x2APIC
}

/// **THE HOST'S TIME HAS OTHER DOORS THAN `rdtsc`**, and the PC-shaped
/// machine says it has none of them: no `rdtscp` and no `rdpid` (which read
/// IA32_TSC_AUX beside the host's counter), no IA32_TSC_ADJUST, no MPERF and
/// APERF, and none of KVM's own paravirtual features, kvmclock among them.
/// With the bits clear, KVM makes the two instructions undefined; the MSRs
/// are behind the filter (`ownTheMsrs`).
fn hideTheHostsTime(e: *kvm.CpuidEntry) void {
    if (e.function == 0x8000_0001) e.edx &= ~@as(u32, 1 << 27); // RDTSCP
    if (e.function == 7 and e.index == 0) {
        e.ebx &= ~@as(u32, 1 << 1); // IA32_TSC_ADJUST
        e.ecx &= ~@as(u32, 1 << 22); // RDPID
    }
    if (e.function == 6) e.ecx &= ~@as(u32, 1 << 0); // MPERF and APERF
    if (e.function == 0x4000_0001) e.eax = 0; // KVM's features: kvmclock and the rest
}

/// **THE MSRS THIS MACHINE ANSWERS ITSELF**, by a filter that denies them to
/// KVM so every access exits here. The APIC's two: with no interrupt
/// controller in the kernel, KVM would answer IA32_APIC_BASE itself and drop
/// IA32_TSC_DEADLINE on the floor. And every MSR that reads the host's
/// time: IA32_TSC, which this machine answers from its own clock, and the
/// rest, which it refuses with a #GP, as a processor without them does.
const owned_msrs = [_]struct { base: u32, n: u32 }{
    .{ .base = apic.msr_apic_base, .n = 1 },
    .{ .base = apic.msr_tsc_deadline, .n = 1 },
    .{ .base = msr_tsc, .n = 3 }, // IA32_TSC, and kvmclock's first two (0x11, 0x12)
    .{ .base = 0x3B, .n = 1 }, // IA32_TSC_ADJUST
    .{ .base = 0xE7, .n = 2 }, // IA32_MPERF, IA32_APERF
    .{ .base = 0xC000_0103, .n = 1 }, // IA32_TSC_AUX
    .{ .base = 0x4B56_4D00, .n = 8 }, // KVM's own, kvmclock's second pair among them
};
const msr_tsc: u32 = 0x10;

fn msrFilter() kvm.MsrFilter {
    const deny = struct {
        const bits = [1]u8{0}; // one bit an MSR, 0 denies; eight is enough
    };
    var filter = kvm.MsrFilter{};
    for (owned_msrs, 0..) |r, i| {
        std.debug.assert(r.n <= 8);
        filter.ranges[i] = .{ .flags = kvm.msr_filter_read | kvm.msr_filter_write, .nmsrs = r.n, .base = r.base, .bitmap = &deny.bits };
    }
    return filter;
}

fn ownTheMsrs(vm: linux.fd_t) !void {
    var cap = kvm.EnableCap{ .cap = kvm.cap_x86_user_space_msr, .args = .{ kvm.msr_exit_reason_filter, 0, 0, 0 } };
    _ = try kvm.call(vm, kvm.enable_cap, @intFromPtr(&cap));
    var filter = msrFilter();
    _ = try kvm.call(vm, kvm.set_msr_filter, @intFromPtr(&filter));
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

/// **WHERE THE GUEST'S CLOCK READS ARRIVE.** Nothing on a PC decodes 0xE0, so
/// a write there can only be one of the loader's substitutions — see
/// `rewriteClockReads`.
const tsc_port: u16 = 0xE0;
/// Where a marked deadline `wrmsr` lands (`rewriteDeadlineWrites`).
const msr_port: u16 = 0xE1;

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
    fn readMsr(self: *Machine, index: u32) ?u64 {
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

/// The run's coverage, if its guest printed any: the last line on the error
/// stream.
fn reportCoverage(machine: *const Machine) void {
    var buf: [256]u8 = undefined;
    if (machine.serial.summary(&buf)) |line| std.debug.print("{s}", .{line});
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

const Rested = enum { woken, never, off };

/// What the processor says at a halt: whether interrupts are on (`sti`), and
/// whether one can be injected at this instant.
const Cpu = struct {
    interrupts_on: bool = true,
    can_inject: bool = true,
};

/// What a halted guest is waiting for, decided from the processor, the APIC,
/// the time, and when the wire's oldest frame is due.
const Wake = union(enum) {
    /// This vector, now: no time passes. It is in service from here.
    take: u8,
    /// A vector could be delivered, but the processor cannot take one at
    /// this instant: it stays waiting in the APIC, and is taken when the
    /// processor says it can.
    window,
    /// Nothing yet: move the clock here, pump the wire, and ask again.
    move_to: u64,
    /// Nothing can ever wake it.
    never,
    /// **IT HALTED WITH INTERRUPTS OFF**, which on a PC only an NMI, an SMI or
    /// an INIT ends, and none of those come from this machine: it stops.
    off,
};

/// **ONE STEP OF A HALT**, without the processor: the timer is looked at, then
/// the waiting vectors; failing those, the earlier of the deadline and the
/// next frame. A frame due already but undelivered has no buffer to go to,
/// and waits for the guest, not the clock. A vector goes into service only
/// if it can be injected (`Cpu.can_inject`) in the same step.
fn wakes(lapic: *apic.Apic, now: u64, frame_due: ?u64, cpu: Cpu) Wake {
    if (!cpu.interrupts_on) return .off;
    lapic.tick(now);
    if (lapic.deliverable() != null) {
        if (!cpu.can_inject) return .window;
        return .{ .take = lapic.next().? };
    }
    var wake = lapic.timerDue();
    if (frame_due) |due| if (due > now) {
        wake = if (wake) |w| @min(w, due) else due;
    };
    return .{ .move_to = @max(now, wake orelse return .never) };
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
        switch (@as(kvm.Exit, @enumFromInt(run.exit_reason))) {
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
                switch (try rest(vcpu, run, machine)) {
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

/// **THE FAULTS TAKE THEIR ORDERS FROM THE ENVIRONMENT**, not from a flag:
/// which of the guest's frames to eat (`WIRE_EAT=3` or `WIRE_EAT=3,9`), a rate
/// to eat them at (`WIRE_LOSS=4`, one frame in four), how long a frame takes to
/// reach the guest (`WIRE_LATENCY_US=250`), and which of its disk requests come
/// back refused (`DISK_REFUSE=3,9`, `DISK_REFUSE_RATE=100`). Nothing set is a
/// machine that works perfectly, which is what check.sh runs on.
fn tellTheFaults(line: *faults.Wire, drive: *faults.Drive, rough: *wire.Rough, k: *const knobs.Knobs) void {
    numbers(&line.lost, k, "WIRE_EAT");
    numbers(&line.peer_lost, k, "PEER_EAT");
    numbers(&line.peer_damaged, k, "PEER_DAMAGE");
    if (k.get("PEER_LOSS")) |n| line.peer_lost.rate = std.fmt.parseInt(u32, n, 10) catch 0;
    if (k.get("PEER_DAMAGE_RATE")) |n| line.peer_damaged.rate = std.fmt.parseInt(u32, n, 10) catch 0;
    rough.retransmits = line.hurtsPeer();
    // **THE PEER'S OWN MISBEHAVIOUR** (peer.zig, `Rough`): times in
    // microseconds of the machine's clock from when it opened, sizes in
    // bytes of the answer.
    if (knob(k, "PEER_RESET_AT")) |us| rough.reset_after_ns = us * std.time.ns_per_us;
    if (knob(k, "PEER_RESET_OFF")) |n| rough.reset_off = @truncate(n);
    if (knob(k, "PEER_VANISH_AFTER")) |n| rough.vanish_after = @intCast(n);
    if (knob(k, "PEER_FLOOD")) |n| rough.flood = @intCast(@min(n, 32));
    if (knob(k, "PEER_FLOOD_GAP_US")) |us| rough.flood_gap_ns = us * std.time.ns_per_us;
    if (knob(k, "PEER_SHUT_AFTER")) |n| rough.shut_after = @intCast(n);
    if (knob(k, "PEER_SHUT_FOR_US")) |us| rough.shut_for_ns = us * std.time.ns_per_us;
    if (knob(k, "PEER_MSS")) |n| if (n > 0) {
        rough.mss = @intCast(n);
    };
    numbers(&drive.refused, k, "DISK_REFUSE");
    if (k.get("WIRE_LOSS")) |n| line.lost.rate = std.fmt.parseInt(u32, n, 10) catch 0;
    if (k.get("DISK_REFUSE_RATE")) |n| drive.refused.rate = std.fmt.parseInt(u32, n, 10) catch 0;
    if (k.get("DISK_WRITES_ONLY")) |_| drive.writes_only = true;
    if (k.get("WIRE_LATENCY_US")) |n| {
        line.latency_ns = (std.fmt.parseInt(u64, n, 10) catch 0) * std.time.ns_per_us;
    }
}

/// One number from the environment, if it is there and is one.
fn count(environ: std.process.Environ, name: []const u8) ?u64 {
    const text = environ.getPosix(name) orelse return null;
    return std.fmt.parseInt(u64, text, 10) catch null;
}

/// One number a fault knob says, if it says one.
fn knob(k: *const knobs.Knobs, name: []const u8) ?u64 {
    const text = k.get(name) orelse return null;
    return std.fmt.parseInt(u64, text, 10) catch null;
}

fn numbers(schedule: *faults.Schedule, k: *const knobs.Knobs, name: []const u8) void {
    const list = k.get(name) orelse return;
    var at: usize = 0;
    var each = std.mem.tokenizeScalar(u8, list, ',');
    while (each.next()) |one| {
        if (at >= schedule.named.len) break;
        schedule.named[at] = std.fmt.parseInt(u32, one, 10) catch continue;
        at += 1;
    }
}

/// What was done to this run, if anything was.
/// The PC-shaped machine's halts and interrupts, on the error stream.
fn reportRest(machine: *const Machine) void {
    var messages: u64 = 0;
    for (machine.bus.?.functions) |f| if (f) |g| {
        messages += g.messages;
    };
    std.debug.print("metal-vmm: {d} halts skipped {d} ms; {d} interrupts taken ({d} timer, {d} MSI-X messages); {d} APIC MSR accesses\n", .{
        machine.halts,             machine.halted_ns / std.time.ns_per_ms, machine.lapic.taken,
        machine.lapic.timer_fired, messages,                               machine.msrs,
    });
}

fn reportRun(card: *const net.Net, block: *const virtio.Block, ns: u64) void {
    if (card.line.configured()) reportFaults("wire", "frames sent", &card.line.lost, ns);
    if (card.line.peer_lost.configured()) reportFaults("peer", "frames sent", &card.line.peer_lost, ns);
    if (card.line.peer_damaged.configured()) reportFaults("peer damage", "frames sent", &card.line.peer_damaged, ns);
    if (block.refusals.configured()) {
        const shown: usize = @intCast(@min(block.refusals.refused.picked_count, block.refusals.sectors.len));
        reportFaultsWith("disk", "requests", &block.refusals.refused, ns, block.refusals.sectors[0..shown], block.refusals.kinds[0..shown]);
    }
}

/// One line on the error stream, so a sweep can read what a run did. **THE
/// GUEST'S OWN CLOCK IS THE INTERESTING NUMBER**: a lost frame costs it a
/// retransmission timeout, and that shows up here and nowhere else.
fn reportFaults(what: []const u8, of: []const u8, s: *const faults.Schedule, ns: ?u64) void {
    reportFaultsWith(what, of, s, ns, null, null);
}

/// The same line, plus what each refused request was asking for.
fn reportFaultsWith(what: []const u8, of: []const u8, s: *const faults.Schedule, ns: ?u64, sectors: ?[]const u64, kinds: ?[]const u8) void {
    var text: [256]u8 = undefined;
    var written = std.fmt.bufPrint(&text, "{s}: {d} {s}, {d} {s}", .{ what, s.seen, of, s.picked_count, pickedWord(what) }) catch return;
    var at = written.len;
    const shown = @min(s.picked_count, s.picked.len);
    for (s.picked[0..@intCast(shown)], 0..) |n, i| {
        written = std.fmt.bufPrint(text[at..], "{s}{d}", .{ if (i == 0) " (#" else ", #", n }) catch break;
        at += written.len;
        if (sectors) |where| {
            if (i < where.len) {
                const kind: u8 = if (kinds) |k| k[i] else '?';
                written = std.fmt.bufPrint(text[at..], ", a {s} of sector {d}", .{ if (kind == 'w') "write" else "read", where[i] }) catch break;
                at += written.len;
            }
        }
    }
    if (shown > 0 and at < text.len) {
        text[at] = ')';
        at += 1;
    }
    if (ns) |elapsed| {
        written = std.fmt.bufPrint(text[at..], ", {d} ms of the guest's time", .{elapsed / std.time.ns_per_ms}) catch return;
        at += written.len;
    }
    if (at < text.len) {
        text[at] = '\n';
        at += 1;
    }
    _ = linux.write(2, &text, at);
}

fn pickedWord(what: []const u8) []const u8 {
    if (std.mem.eql(u8, what, "wire") or std.mem.eql(u8, what, "peer")) return "lost";
    if (std.mem.eql(u8, what, "peer damage")) return "damaged";
    return "refused";
}

fn readAll(path: [:0]const u8, into: []u8) ?[]const u8 {
    const opened = linux.open(path.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    const n = linux.read(fd, into.ptr, into.len);
    if (linux.errno(n) != .SUCCESS or n == 0) return null;
    return into[0..n];
}

/// What the client got, for a caller that wants to diff it against another
/// client's.
fn writeOut(path: [:0]const u8, bytes: []const u8) void {
    const opened = linux.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (linux.errno(opened) != .SUCCESS) return;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    _ = linux.write(fd, bytes.ptr, bytes.len);
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
    var block: virtio.Block = undefined;
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
        if (init.environ.getPosix("DISK_TRACE")) |_| block.trace = true;
        block_device = block.device();
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
    // The same three, in slots of a PCI bus instead. The guest asks for each
    // kind by type, so the order is only the order a scan finds them in.
    var bus = pci.Bus{};
    if (pc) {
        machine.bus = &bus;
        if (disk_path != null) _ = bus.plug(1, &block_device, &machine.lapic);
        _ = bus.plug(2, &net_device, &machine.lapic);
        _ = bus.plug(3, &dice_device, &machine.lapic);
    }

    // **THE FAULTS: A SEED'S, UNDER WHAT THE ENVIRONMENT SETS BY HAND**
    // (knobs.zig). A seeded run says what it chose, as the knobs that would
    // repeat it without the seed.
    var turned = if (count(init.environ, "FAULT_SEED")) |seed| knobs.Knobs.fromSeed(seed) else knobs.Knobs{};
    turned.overlay(init.environ);
    if (count(init.environ, "FAULT_SEED")) |seed| {
        var line: [1024]u8 = undefined;
        std.debug.print("metal-vmm: FAULT_SEED={d} is {s}\n", .{ seed, turned.format(&line) });
    }
    tellTheFaults(&card.line, &block.refusals, &card.peer.rough, &turned);
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
    }

    // **WHAT THE PEER ASKS FOR.** A path is enough for a probe; a server with
    // a login and a chat wants a whole request, cookie and body and all, so
    // `PEER_REQUEST=<file>` sends those bytes exactly as they are.
    var request_buf: [8192]u8 = undefined;
    if (init.environ.getPosix("PEER_REQUEST")) |from| {
        machine.request = readAll(from, &request_buf) orelse {
            std.debug.print("metal-vmm: cannot read the request in {s}\n", .{from});
            return 2;
        };
    } else if (fetch) |target| {
        machine.request = std.fmt.bufPrint(&request_buf, "GET {s} HTTP/1.1\r\nHost: 10.0.2.15\r\nConnection: close\r\n\r\n", .{target}) catch null;
    }

    // **A RUN THAT ENDS BADLY STILL SAYS WHAT WAS DONE TO IT.** The faults
    // below are the first thing anybody reads after a guest gets stuck, so
    // they are reported before the error goes anywhere.
    const code = serve(vcpu, page, &machine, .{ .lo = loaded.text_lo, .hi = loaded.text_hi }) catch |e| {
        reportRun(&card, &block, machine.time.ns);
        reportCoverage(&machine);
        return e;
    };
    // **WHAT THE WIRE DID, IF IT WAS ASKED TO DO ANYTHING**, on the error
    // stream: a run with a perfect wire says nothing, so the probes' output
    // stays comparable with QEMU's.
    reportRun(&card, &block, machine.time.ns);
    if (pc) reportRest(&machine);
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
    // **WHAT THE CLIENT GOT, IN ONE LINE**, so a run here can be compared with
    // a run under QEMU where curl says the same thing.
    if (fetch != null) {
        const got = card.fetched();
        // **A REAL PAGE DOES NOT FIT ON A LINE.** The probes answer with a
        // sentence and the line below is compared against curl's; a guest
        // serving an actual site answers with kilobytes, so the body goes to a
        // file when one is asked for (`PEER_BODY=/path`) and the line says how
        // much there was.
        if (init.environ.getPosix("PEER_BODY")) |into| writeOut(into, got.body());
        if (init.environ.getPosix("PEER_RESPONSE")) |into| writeOut(into, got.whole());
        var line: [512]u8 = undefined;
        // Trailing newlines are trimmed because the shell trims them too, and
        // this line is compared against one built from curl's output.
        const body = std.mem.trimEnd(u8, got.body(), "\r\n");
        const text = std.fmt.bufPrint(&line, "peer: {d} \"{s}\"\n", .{ got.status(), body }) catch
            std.fmt.bufPrint(&line, "peer: {d}, {d} bytes\n", .{ got.status(), body.len }) catch "peer: ?\n";
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
    _ = @import("apic.zig");
    _ = @import("pci.zig");
    _ = @import("coverage.zig");
    _ = @import("knobs.zig");
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

test "every marked rdtsc in the guest's text becomes a question for us" {
    var file: [512]u8 align(8) = undefined;
    // Two marked reads, and two near misses: an unmarked 0F 31, which may sit
    // inside another instruction and must be left alone, and the mark before
    // 0F 30 (wrmsr).
    const m = "\xb9mvmc";
    const body = m ++ "\x0f\x31" ++ "\x0f\x31" ++ m ++ "\x0f\x30" ++ m ++ "\x0f\x31";
    const image = fakeKernel(&file, 0x100000, 0x100000, body);
    const ram = try testing.allocator.alloc(u8, 0x101000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);

    const loaded = try load(ram, image);
    try testing.expectEqual(@as(usize, 2), loaded.clock_reads);
    // Where each `out` the loader wrote is, as the guest runs it: only these
    // are questions for us.
    try testing.expectEqualSlices(u64, &.{ 0x100000 + 5, 0x100000 + 21 }, loaded.clocks.at[0..loaded.clocks.len]);
    try testing.expect(!loaded.clocks.has(0x100000 + 7)); // the unmarked 0F 31 stays itself
    const want = m ++ "\xe6\xe0" ++ "\x0f\x31" ++ m ++ "\x0f\x30" ++ m ++ "\xe6\xe0";
    try testing.expectEqualSlices(u8, want, ram[0x100000..][0..body.len]);
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

// ── a halt's decision, without a processor ──────────────────────────────────

/// The APIC as gopher-metal's `startApic` leaves it: enabled, the timer on
/// 0x41 in TSC-deadline mode, nothing armed.
fn startedApic() apic.Apic {
    var a = apic.Apic{};
    _ = a.writeMsr(apic.msr_apic_base, a.readMsr(apic.msr_apic_base, 0).? | (1 << 11), 0);
    a.write(0x0F0, 0x100 | 0xFF, 0);
    a.write(0x320, 0x41 | (2 << 17), 0);
    return a;
}

test "a vector already waiting is taken at once, and no time passes" {
    var a = startedApic();
    _ = a.writeMsr(apic.msr_tsc_deadline, 1_000_000, 0);
    a.raise(0x40);
    try testing.expectEqual(Wake{ .take = 0x40 }, wakes(&a, 5_000, 6_000, .{}));
}

test "a deadline before the next frame: the clock goes to the deadline, and the timer fires there" {
    var a = startedApic();
    _ = a.writeMsr(apic.msr_tsc_deadline, 25_000, 0); // 10 µs at 2.5 GHz
    try testing.expectEqual(Wake{ .move_to = 10_000 }, wakes(&a, 1_000, 50_000, .{}));
    try testing.expectEqual(Wake{ .take = 0x41 }, wakes(&a, 10_000, 50_000, .{}));
}

test "a frame before the deadline: the clock goes to the frame" {
    var a = startedApic();
    _ = a.writeMsr(apic.msr_tsc_deadline, 250_000, 0); // 100 µs
    try testing.expectEqual(Wake{ .move_to = 40_000 }, wakes(&a, 1_000, 40_000, .{}));
}

test "a frame due already but undelivered does not wake the guest" {
    var a = startedApic();
    // It had its chance in this exit's pump and found no buffer: only the
    // guest posting one can change that, and the guest is halted.
    try testing.expectEqual(Wake.never, wakes(&a, 5_000, 5_000, .{}));
    try testing.expectEqual(Wake.never, wakes(&a, 5_000, 1_000, .{}));
    // With a deadline, the deadline is what wakes it.
    _ = a.writeMsr(apic.msr_tsc_deadline, 25_000, 0);
    try testing.expectEqual(Wake{ .move_to = 10_000 }, wakes(&a, 5_000, 1_000, .{}));
}

test "a deadline between two nanoseconds: the first nanosecond at or past it" {
    var a = startedApic();
    // At 2.5 ticks a nanosecond, tick 26 falls between 10 ns (tick 25) and
    // 11 ns (tick 27.5, read as 27). The timer fires when rdtsc would first
    // answer 26 or more: at 11 ns, not at 10.
    _ = a.writeMsr(apic.msr_tsc_deadline, 26, 0);
    try testing.expectEqual(Wake{ .move_to = 11 }, wakes(&a, 0, null, .{}));
    try testing.expectEqual(@as(u64, 25), (clock.Clock{ .ns = 10 }).ticks());
    try testing.expectEqual(Wake{ .move_to = 11 }, wakes(&a, 10, null, .{})); // not yet
    try testing.expectEqual(Wake{ .take = 0x41 }, wakes(&a, 11, null, .{}));
}

test "a deadline already past fires without moving the clock" {
    var a = startedApic();
    _ = a.writeMsr(apic.msr_tsc_deadline, 100, 0);
    try testing.expectEqual(Wake{ .take = 0x41 }, wakes(&a, 1_000_000, null, .{}));
}

test "nothing armed and nothing on the wire: nothing can wake it" {
    var a = startedApic();
    try testing.expectEqual(Wake.never, wakes(&a, 1_000, null, .{}));
}

test "an APIC never enabled delivers nothing, and its timer cannot wake the guest" {
    var a = apic.Apic{};
    // Software-disabled (SVR bit 8 clear, as after a reset), every LVT entry
    // is masked and stays masked (SDM §11.4.7.2): the timer may count, but
    // it cannot interrupt, so it is not something a halt waits for.
    a.write(0x320, 0x41 | (2 << 17), 0);
    _ = a.writeMsr(apic.msr_tsc_deadline, 25_000, 0);
    a.raise(0x40);
    try testing.expectEqual(Wake.never, wakes(&a, 0, null, .{}));
}

test "a vector in service holds the others until EOI" {
    var a = startedApic();
    a.raise(0x40);
    try testing.expectEqual(Wake{ .take = 0x40 }, wakes(&a, 0, null, .{}));
    a.raise(0x40);
    try testing.expectEqual(Wake.never, wakes(&a, 0, null, .{}));
    a.write(0x0B0, 0, 0);
    try testing.expectEqual(Wake{ .take = 0x40 }, wakes(&a, 0, null, .{}));
}

test "a vector the processor cannot take yet stays waiting, and is not in service" {
    var a = startedApic();
    a.raise(0x40);
    try testing.expectEqual(Wake.window, wakes(&a, 0, null, .{ .can_inject = false }));
    try testing.expect(a.isr.findFirstSet() == null);
    // When it can, it is the one taken, and nothing else blocks it.
    try testing.expectEqual(Wake{ .take = 0x40 }, wakes(&a, 0, null, .{}));
}

test "a halt with interrupts off stops the machine, whatever is waiting" {
    var a = startedApic();
    a.raise(0x40);
    _ = a.writeMsr(apic.msr_tsc_deadline, 25_000, 0);
    const off = Cpu{ .interrupts_on = false, .can_inject = false };
    try testing.expectEqual(Wake.off, wakes(&a, 0, 5_000, off));
    // Nothing was taken, and the clock was not asked to move.
    try testing.expect(a.irr.isSet(0x40));
    try testing.expect(a.isr.findFirstSet() == null);
}

test "a marked deadline write becomes a port write, and its place is recorded" {
    var file: [512]u8 align(8) = undefined;
    const d = "\xbemvmd";
    const body = "\x90" ++ d ++ "\x0f\x30" ++ "\x0f\x30";
    const image = fakeKernel(&file, 0x100000, 0x100000, body);
    const ram = try testing.allocator.alloc(u8, 0x101000);
    defer testing.allocator.free(ram);
    @memset(ram, 0);
    const loaded = try load(ram, image);
    try testing.expectEqualSlices(u8, "\x90" ++ d ++ "\xe6\xe1" ++ "\x0f\x30", ram[0x100000..][0..body.len]);
    try testing.expectEqualSlices(u64, &.{0x100000 + 6}, loaded.deadlines.at[0..loaded.deadlines.len]);
    try testing.expectEqual(@as(usize, 0), loaded.clocks.len);
}

test "the PC-shaped machine's CPUID offers no other way to the host's time" {
    var entries = [_]kvm.CpuidEntry{
        .{ .function = 0x8000_0001, .index = 0, .flags = 0, .eax = 0, .ebx = 0, .ecx = 0, .edx = 0xFFFF_FFFF, .padding = @splat(0) },
        .{ .function = 7, .index = 0, .flags = 0, .eax = 0, .ebx = 0xFFFF_FFFF, .ecx = 0xFFFF_FFFF, .edx = 0, .padding = @splat(0) },
        .{ .function = 6, .index = 0, .flags = 0, .eax = 0, .ebx = 0, .ecx = 0xFFFF_FFFF, .edx = 0, .padding = @splat(0) },
        .{ .function = 0x4000_0001, .index = 0, .flags = 0, .eax = 0xFFFF_FFFF, .ebx = 0, .ecx = 0, .edx = 0, .padding = @splat(0) },
    };
    for (&entries) |*e| hideTheHostsTime(e);
    try testing.expectEqual(@as(u32, 0), entries[0].edx & (1 << 27));
    try testing.expectEqual(@as(u32, 0), entries[1].ebx & (1 << 1));
    try testing.expectEqual(@as(u32, 0), entries[1].ecx & (1 << 22));
    try testing.expectEqual(@as(u32, 0), entries[2].ecx & 1);
    try testing.expectEqual(@as(u32, 0), entries[3].eax);
    // Nothing else is touched.
    try testing.expectEqual(~@as(u32, 1 << 27), entries[0].edx);
    try testing.expectEqual(~@as(u32, 1 << 1), entries[1].ebx);
}

/// What KVM does with a filter whose ranges' bitmaps are all zero: an MSR in
/// a range is denied to it, and so exits here.
fn deniedByFilter(filter: *const kvm.MsrFilter, index: u32) bool {
    for (filter.ranges) |r| {
        if (r.nmsrs == 0 or index < r.base or index >= r.base + r.nmsrs) continue;
        const bit = index - r.base;
        if (r.bitmap.?[bit / 8] & (@as(u8, 1) << @intCast(bit % 8)) == 0) return true;
    }
    return false;
}

test "every MSR that reads the host's time, and the APIC's, exits here; others do not" {
    const filter = msrFilter();
    for ([_]u32{ 0x1B, 0x6E0, 0x10, 0x11, 0x12, 0x3B, 0xE7, 0xE8, 0xC000_0103, 0x4B56_4D00, 0x4B56_4D01, 0x4B56_4D07 }) |m| {
        try testing.expect(deniedByFilter(&filter, m));
    }
    for ([_]u32{ 0xC000_0080, 0x1A0, 0x13, 0xE6, 0xE9, 0x4B56_4D08, 0xC000_0102 }) |m| {
        try testing.expect(!deniedByFilter(&filter, m));
    }
}

test "IA32_TSC reads this machine's clock; the others are refused" {
    var machine = Machine{};
    machine.time.ns = 4_000;
    try testing.expectEqual(@as(?u64, 10_000), machine.readMsr(msr_tsc));
    for ([_]u32{ 0x11, 0x12, 0x3B, 0xE7, 0xE8, 0xC000_0103, 0x4B56_4D00 }) |m| {
        try testing.expect(machine.readMsr(m) == null);
        try testing.expect(!machine.lapic.writeMsr(m, 1, 0));
    }
    try testing.expect(!machine.lapic.writeMsr(msr_tsc, 0, 0));
}

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

/// An environment, by hand.
const FakeEnv = struct {
    pairs: []const [2][]const u8,

    pub fn getPosix(self: FakeEnv, name: []const u8) ?[]const u8 {
        for (self.pairs) |p| if (std.mem.eql(u8, p[0], name)) return p[1];
        return null;
    }
};

test "the knobs reach the wire, the disk and the peer, a seed's or the environment's alike" {
    var by_hand = knobs.Knobs{};
    by_hand.overlay(FakeEnv{ .pairs = &.{
        .{ "WIRE_EAT", "3,9" },  .{ "PEER_EAT", "2" },         .{ "WIRE_LATENCY_US", "250" },
        .{ "DISK_REFUSE", "4" }, .{ "DISK_WRITES_ONLY", "1" }, .{ "PEER_RESET_AT", "3000" },
        .{ "PEER_FLOOD", "4" },  .{ "PEER_MSS", "100" },
    } });
    var line = faults.Wire{};
    var drive = faults.Drive{};
    var rough = wire.Rough{};
    tellTheFaults(&line, &drive, &rough, &by_hand);
    try testing.expectEqualSlices(u32, &.{ 3, 9 }, line.lost.named[0..2]);
    try testing.expectEqual(@as(u32, 2), line.peer_lost.named[0]);
    try testing.expectEqual(@as(u64, 250 * std.time.ns_per_us), line.latency_ns);
    try testing.expectEqual(@as(u32, 4), drive.refused.named[0]);
    try testing.expect(drive.writes_only);
    try testing.expect(rough.retransmits); // the peer's frames may be lost
    try testing.expectEqual(@as(?u64, 3000 * std.time.ns_per_us), rough.reset_after_ns);
    try testing.expectEqual(@as(u8, 4), rough.flood);
    try testing.expectEqual(@as(?usize, 100), rough.mss);

    // A seed's schedule, applied, is its printed knobs applied by hand.
    var printed: [1024]u8 = undefined;
    for (0..50) |seed| {
        const drawn = knobs.Knobs.fromSeed(seed);
        var pairs: [knobs.names.len][2][]const u8 = undefined;
        var n: usize = 0;
        const text = drawn.format(&printed);
        if (!std.mem.eql(u8, text, "none")) {
            var each = std.mem.tokenizeScalar(u8, text, ' ');
            while (each.next()) |kv| : (n += 1) {
                const eq = std.mem.indexOfScalar(u8, kv, '=').?;
                pairs[n] = .{ kv[0..eq], kv[eq + 1 ..] };
            }
        }
        var again = knobs.Knobs{};
        again.overlay(FakeEnv{ .pairs = pairs[0..n] });
        var a_line = faults.Wire{};
        var a_drive = faults.Drive{};
        var a_rough = wire.Rough{};
        var b_line = faults.Wire{};
        var b_drive = faults.Drive{};
        var b_rough = wire.Rough{};
        tellTheFaults(&a_line, &a_drive, &a_rough, &drawn);
        tellTheFaults(&b_line, &b_drive, &b_rough, &again);
        try testing.expectEqual(a_rough, b_rough);
        try testing.expectEqual(a_line.latency_ns, b_line.latency_ns);
        try testing.expectEqualSlices(u32, &a_line.lost.named, &b_line.lost.named);
        try testing.expectEqual(a_line.lost.rate, b_line.lost.rate);
        try testing.expectEqualSlices(u32, &a_line.peer_lost.named, &b_line.peer_lost.named);
        try testing.expectEqualSlices(u32, &a_line.peer_damaged.named, &b_line.peer_damaged.named);
        try testing.expectEqualSlices(u32, &a_drive.refused.named, &b_drive.refused.named);
        try testing.expectEqual(a_drive.writes_only, b_drive.writes_only);
    }
}
