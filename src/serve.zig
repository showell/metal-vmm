//! **THE RUN LOOP**: `serve` runs the guest until it stops, answering each
//! exit (a port, a memory access, a halt, the clock the loader rewrote, the
//! coverage door) and saying, when it gives up, what the processor was doing
//! and who called it. main.zig sets the machine up and calls it once.

const loader = @import("loader.zig");
const std = @import("std");
const kvm = @import("kvm.zig");
const turn = @import("turn.zig");
const coverage = @import("coverage.zig");
const clock = @import("clock.zig");
const machine_file = @import("machine.zig");
const halt = @import("halt.zig");
const reports = @import("reports.zig");
const readLittle = machine_file.readLittle;
const linux = std.os.linux;
const Machine = machine_file.Machine;
const Rested = halt.Rested;
const Cpu = halt.Cpu;
const wakes = halt.wakes;
const reportCut = reports.reportCut;
const SerialOut = machine_file.SerialOut;
const tsc_port = loader.tsc_port;
const msr_port = loader.msr_port;
const testing = std.testing;

/// **THE COVERAGE DOOR**: a zig-metal-unikernel kernel built `-Dcoverage` reads it
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
                // In a pair, no further than the limit: there the turn
                // goes to the other side, whose frames may wake this one
                // sooner, and the halt asks again when it is back.
                const t = machine.turns orelse {
                    machine.time.ns = at;
                    machine.pump();
                    continue;
                };
                if (turn.capHalt(machine.time.ns, at, t.limit())) |cap| {
                    machine.time.ns = cap;
                    machine.pump();
                    try t.yield(machine.time.ns, .{ .halted = at });
                    machine.pump();
                    continue;
                }
                machine.time.ns = at;
                machine.pump();
            },
            .never => {
                const t = machine.turns orelse return .never;
                switch (turn.atNever(t.other())) {
                    .end_both_idle => return .both_idle,
                    .give_up_turn => {
                        try t.yield(machine.time.ns, .{ .halted = null });
                        machine.pump();
                    },
                }
            },
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
pub fn serve(vcpu: linux.fd_t, page: []align(std.heap.page_size_min) u8, machine: *Machine, text: Text) !u8 {
    const run: *kvm.Run = @ptrCast(page.ptr);
    while (true) {
        // What fired in the last exit, and whose request it fell in, before
        // a cut below ends the run.
        machine.during.look(if (machine.card) |c| &c.peer else null, machine.drive, machine.volume);
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
            if (machine.turns) |t| try t.beforeMove(machine.time.ns, v.owed_ns);
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
        if (@as(kvm.Exit, @fromBackingInt(@intCast(run.exit_reason))) == .io) {
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
        // In a pair, not past the limit: the turn goes first (§4).
        if (machine.turns) |t| try t.beforeMove(machine.time.ns, clock.per_question_ns);
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
        if (machine.watched()) {
            std.debug.print("metal-vmm: the guest has run {d} s of its own time, as GUEST_S asked, so the run ends\n", .{machine.time.ns / std.time.ns_per_s});
            return error.GuestWatched;
        }
        const exit_reason: kvm.Exit = @fromBackingInt(@intCast(run.exit_reason));
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
                    .both_idle => {
                        std.debug.print("metal-vmm: both idle: this guest and the other's are halted with nothing that could wake either, so the pair ends\n", .{});
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
                std.debug.print("metal-vmm: unhandled exit {d}\n", .{@backingInt(reason)});
                return error.Unhandled;
            },
        }
    }
}

test "a halt is not a hang: it starts the count of quiet exits again" {
    var machine = Machine{};
    machine.quiet = patience - 1;
    machine.time.ns = std.time.ns_per_s;
    try testing.expect(!machine.rested());
    try testing.expectEqual(@as(u64, 0), machine.quiet);
}
