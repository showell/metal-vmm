//! **THE PROCESSOR, AS THE GUEST FINDS IT**: the CPUID it is told (no host
//! entropy, no host time, an APIC on the PC-shaped machine) and the MSRs this
//! program answers itself, through KVM's filter.

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
const loader = @import("loader.zig");
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
const fakeKernel = loader.fakeKernel;
const Rested = halt.Rested;
const Cpu = halt.Cpu;
const Wake = halt.Wake;
const wakes = halt.wakes;
const startedApic = halt.startedApic;

/// Tells the processor what kind of processor it is, by asking this one —
/// minus the two instructions that would let the guest reach outside this
/// program for entropy. Without any of it the guest cannot enter long mode;
/// see `kvm.get_supported_cpuid`.
pub fn describeProcessor(dev: linux.fd_t, vcpu: linux.fd_t, pc: bool) !void {
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
pub fn forgetTheDice(e: *kvm.CpuidEntry) void {
    const rdrand: u32 = 1 << 30; // leaf 1, ECX
    const rdseed: u32 = 1 << 18; // leaf 7 subleaf 0, EBX
    if (e.function == 1) e.ecx &= ~rdrand;
    if (e.function == 7 and e.index == 0) e.ebx &= ~rdseed;
}

/// **THE PC-SHAPED MACHINE HAS AN APIC WITH A DEADLINE TIMER** (apic.zig),
/// and says so where gopher-metal looks before it starts one: leaf 1's APIC
/// bit and TSC-deadline bit. No x2APIC: its registers are MSRs this machine
/// does not answer.
pub fn sayTheApic(e: *kvm.CpuidEntry) void {
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
pub fn hideTheHostsTime(e: *kvm.CpuidEntry) void {
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
pub const owned_msrs = [_]struct { base: u32, n: u32 }{
    .{ .base = apic.msr_apic_base, .n = 1 },
    .{ .base = apic.msr_tsc_deadline, .n = 1 },
    .{ .base = msr_tsc, .n = 3 }, // IA32_TSC, and kvmclock's first two (0x11, 0x12)
    .{ .base = 0x3B, .n = 1 }, // IA32_TSC_ADJUST
    .{ .base = 0xE7, .n = 2 }, // IA32_MPERF, IA32_APERF
    .{ .base = 0xC000_0103, .n = 1 }, // IA32_TSC_AUX
    .{ .base = 0x4B56_4D00, .n = 8 }, // KVM's own, kvmclock's second pair among them
};
pub const msr_tsc: u32 = 0x10;

pub fn msrFilter() kvm.MsrFilter {
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

pub fn ownTheMsrs(vm: linux.fd_t) !void {
    var cap = kvm.EnableCap{ .cap = kvm.cap_x86_user_space_msr, .args = .{ kvm.msr_exit_reason_filter, 0, 0, 0 } };
    _ = try kvm.call(vm, kvm.enable_cap, @intFromPtr(&cap));
    var filter = msrFilter();
    _ = try kvm.call(vm, kvm.set_msr_filter, @intFromPtr(&filter));
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
pub fn deniedByFilter(filter: *const kvm.MsrFilter, index: u32) bool {
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
