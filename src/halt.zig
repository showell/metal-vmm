//! **A HALT'S DECISION**, without the processor: from the processor's
//! state, the APIC, the time and the wire, what wakes the guest and when.
//! main.zig's `rest` does the I/O around it.

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
const processor = @import("processor.zig");

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
const describeProcessor = processor.describeProcessor;
const forgetTheDice = processor.forgetTheDice;
const sayTheApic = processor.sayTheApic;
const hideTheHostsTime = processor.hideTheHostsTime;
const owned_msrs = processor.owned_msrs;
const msr_tsc = processor.msr_tsc;
const msrFilter = processor.msrFilter;
const ownTheMsrs = processor.ownTheMsrs;
const deniedByFilter = processor.deniedByFilter;

pub const Rested = enum { woken, never, off };

/// What the processor says at a halt: whether interrupts are on (`sti`), and
/// whether one can be injected at this instant.
pub const Cpu = struct {
    interrupts_on: bool = true,
    can_inject: bool = true,
};

/// What a halted guest is waiting for, decided from the processor, the APIC,
/// the time, and when the wire's oldest frame is due.
pub const Wake = union(enum) {
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
pub fn wakes(lapic: *apic.Apic, now: u64, frame_due: ?u64, cpu: Cpu) Wake {
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

/// The APIC as gopher-metal's `startApic` leaves it: enabled, the timer on
/// 0x41 in TSC-deadline mode, nothing armed.
pub fn startedApic() apic.Apic {
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
