//! **THE KERNEL, LOADED**: an ELF's segments placed where they ask, its PVH
//! entry found, and its marked `rdtsc`s and deadline `wrmsr`s rewritten into
//! port writes this program answers (README, "`rdtsc` does not exit").

const std = @import("std");
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
const main = @import("main.zig");
const linux = std.os.linux;
const Machine = main.Machine;
const settings = @import("settings.zig");
const reports = @import("reports.zig");
const processor = @import("processor.zig");
const halt = @import("halt.zig");
const testing = std.testing;

const tellTheFaults = settings.tellTheFaults;
const count = settings.count;
const knob = settings.knob;
const numbers = settings.numbers;
const FakeEnv = settings.FakeEnv;
const reportCut = reports.reportCut;
const reportCoverage = reports.reportCoverage;
const reportRest = reports.reportRest;
const reportRun = reports.reportRun;
const reportFaults = reports.reportFaults;
const reportFaultsWith = reports.reportFaultsWith;
const pickedWord = reports.pickedWord;
const describeProcessor = processor.describeProcessor;
const forgetTheDice = processor.forgetTheDice;
const sayTheApic = processor.sayTheApic;
const hideTheHostsTime = processor.hideTheHostsTime;
const owned_msrs = processor.owned_msrs;
const msr_tsc = processor.msr_tsc;
const msrFilter = processor.msrFilter;
const ownTheMsrs = processor.ownTheMsrs;
const deniedByFilter = processor.deniedByFilter;
const Rested = halt.Rested;
const Cpu = halt.Cpu;
const Wake = halt.Wake;
const wakes = halt.wakes;
const startedApic = halt.startedApic;

pub const ElfHeader = extern struct {
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

pub const ProgramHeader = extern struct {
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
pub const Rewritten = struct {
    at: [1024]u64 = undefined,
    len: usize = 0,

    pub fn add(self: *Rewritten, address: u64) LoadError!void {
        if (self.len == self.at.len) return error.TooManyMarks;
        self.at[self.len] = address;
        self.len += 1;
    }

    pub fn has(self: *const Rewritten, address: u64) bool {
        return std.mem.indexOfScalar(u64, self.at[0..self.len], address) != null;
    }
};

pub const Loaded = struct {
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
pub const SectionHeader = extern struct {
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
pub fn textRange(image: []const u8, head: *const ElfHeader) struct { lo: u64, hi: u64 } {
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
pub fn rewriteDeadlineWrites(segment: []u8, vaddr: u64, into: *Rewritten) LoadError!usize {
    return rewriteMarked(segment, vaddr, into, .{ 0xBE, 'm', 'v', 'm', 'd' }, .{ 0x0F, 0x30 }, msr_port);
}

pub fn rewriteClockReads(segment: []u8, vaddr: u64, into: *Rewritten) LoadError!usize {
    return rewriteMarked(segment, vaddr, into, .{ 0xB9, 'm', 'v', 'm', 'c' }, .{ 0x0F, 0x31 }, tsc_port);
}

/// **BOTH MARKS IN ONE PASS** over the segment, where `rewriteClockReads`
/// and `rewriteDeadlineWrites` each scan it whole (a 25 MB kernel, every
/// boot). The marked patterns cannot overlap each other or an `out` already
/// written over one (their first bytes differ), so one search for "mvm",
/// checking the byte before and the two after, finds exactly what the two
/// scans find, each list in address order. Answers the clock reads found.
pub fn rewriteMarks(segment: []u8, vaddr: u64, clocks: *Rewritten, deadlines: *Rewritten) LoadError!usize {
    var found: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, segment, at, "mvm")) |m| {
        at = m + 1;
        // The mark is the opcode byte before "mvm", "mvm" and its kind; the
        // instruction follows it.
        if (m < 1 or m + 6 > segment.len) continue;
        const op = segment[m - 1];
        const kind = segment[m + 3];
        const instruction = segment[m + 4 ..][0..2];
        if (op == 0xB9 and kind == 'c' and instruction[0] == 0x0F and instruction[1] == 0x31) {
            instruction.* = .{ 0xE6, @as(u8, @intCast(tsc_port)) };
            try clocks.add(vaddr + m + 4);
            found += 1;
            at = m + 6;
        } else if (op == 0xBE and kind == 'd' and instruction[0] == 0x0F and instruction[1] == 0x30) {
            instruction.* = .{ 0xE6, @as(u8, @intCast(msr_port)) };
            try deadlines.add(vaddr + m + 4);
            at = m + 6;
        }
    }
    return found;
}

/// Every `instruction` right after `mark` in a segment that runs at `vaddr`
/// becomes `out port, al`, and where it is goes `into` the record.
pub fn rewriteMarked(segment: []u8, vaddr: u64, into: *Rewritten, mark: [5]u8, instruction: [2]u8, port: u16) LoadError!usize {
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

pub const NoteHeader = extern struct {
    namesz: u32,
    descsz: u32,
    type: u32,

    /// Xen's number for "the 32-bit entry point", which is the whole reason
    /// this program reads notes at all.
    const phys32_entry: u32 = 18;
};

pub const LoadError = error{ NotAnElf, NotX86_64, NoPvhNote, DoesNotFit, TooManyMarks };

/// Copies every loadable segment to the physical address it asks for, and
/// answers the PVH entry point. **A segment is placed by `paddr`, not
/// `vaddr`**: the kernel is linked to run at one address and loaded at
/// another, and the loader's job is the second one.
pub fn load(ram: []u8, image: []const u8) LoadError!Loaded {
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
                    clock_reads += try rewriteMarks(ram[to..][0..in_file], ph.vaddr, &clocks, &deadlines);
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
pub fn pvhEntry(image: []const u8, ph: ProgramHeader) ?u64 {
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

/// **WHERE THE GUEST'S CLOCK READS ARRIVE.** Nothing on a PC decodes 0xE0, so
/// a write there can only be one of the loader's substitutions — see
/// `rewriteClockReads`.
pub const tsc_port: u16 = 0xE0;
/// Where a marked deadline `wrmsr` lands (`rewriteDeadlineWrites`).
pub const msr_port: u16 = 0xE1;
/// **THE COVERAGE DOOR** (main.zig): a coverage kernel's JSONL lines, which
/// cost the guest no time.
pub const coverage_door: u16 = 0xE2;

/// A tiny ELF with one loadable segment and one PVH note, built by hand so the
/// loader can be checked without a kernel to hand.
pub fn fakeKernel(buf: []u8, paddr: u64, entry: u32, body: []const u8) []const u8 {
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

test "one pass over both marks rewrites what the two passes rewrite, and records the same places" {
    var rng = std.Random.DefaultPrng.init(7);
    const r = rng.random();
    var seg: [4096]u8 = undefined;
    r.bytes(&seg);
    const clock_mark = [_]u8{ 0xB9, 'm', 'v', 'm', 'c', 0x0F, 0x31 };
    const deadline_mark = [_]u8{ 0xBE, 'm', 'v', 'm', 'd', 0x0F, 0x30 };
    // Marks at random places, back to back, at the very start and end, and
    // decoys: the right mark with the wrong instruction, "mvm" alone.
    for ([_]usize{ 0, 7, 100, 107, 2000 }) |at| @memcpy(seg[at..][0..7], &clock_mark);
    for ([_]usize{ 14, 300, 4089 }) |at| @memcpy(seg[at..][0..7], &deadline_mark);
    @memcpy(seg[500..][0..7], &[_]u8{ 0xB9, 'm', 'v', 'm', 'c', 0x0F, 0x30 });
    @memcpy(seg[600..][0..3], "mvm");
    var one = seg;
    var two = seg;
    var c1: Rewritten = .{};
    var d1: Rewritten = .{};
    var c2: Rewritten = .{};
    var d2: Rewritten = .{};
    const n1 = try rewriteMarks(&one, 0x1000, &c1, &d1);
    const n2 = try rewriteClockReads(&two, 0x1000, &c2);
    _ = try rewriteDeadlineWrites(&two, 0x1000, &d2);
    try std.testing.expectEqualSlices(u8, &two, &one);
    try std.testing.expectEqual(n2, n1);
    try std.testing.expectEqual(@as(usize, 5), n1);
    try std.testing.expectEqualDeep(c2, c1);
    try std.testing.expectEqualDeep(d2, d1);
}
