//! **THE LOCAL APIC, OURS.** gopher-metal halts between frames (`sti; hlt`)
//! once its network card is on PCI, and wakes on one of two interrupts: the
//! card's MSI-X message, or the APIC's timer in TSC-deadline mode. KVM can
//! model an APIC in the kernel, but that one keeps the host's time, and this
//! machine's time is its own (clock.zig). So the vCPU has no in-kernel
//! interrupt controller, and this file is its APIC: its registers, its timer
//! in all three modes, and the vectors waiting and in service.
//!
//! **ITS TIMER IS LOOKED AT WHENEVER ANYONE LOOKS.** Every way the guest can
//! see the timer — a register, an MSR, a halt — passes the machine's time in,
//! and the timer first catches up to it: a deadline that passed while the
//! guest ran has fired, its vector is waiting, and the MSR reads zero, exactly
//! as on a PC, without this program looking at it on every exit.
//!
//! **WHEN AN INTERRUPT IS TAKEN IS OURS TO SAY, AND IT IS ALWAYS A HALT.** The
//! guest runs with interrupts off except across `sti; hlt`, so an interrupt
//! can only be taken where it halted. At that halt the machine moves its clock
//! straight to the earliest thing that can wake it — the deadline, or the next
//! frame due on the wire — and injects the vector. Same guest, same seed: the
//! same interrupt at the same instruction at the same virtual time.
//!
//! Intel SDM vol. 3 ch. 11 (the APIC): §11.4 (enabling it), §11.5.4 (the
//! timer), §11.8 (priority, the IRR and ISR, EOI).

const std = @import("std");
const clock = @import("clock.zig");

pub const base: u64 = 0xFEE0_0000;
pub const size: u64 = 0x1000;

pub fn inWindow(addr: u64) bool {
    return addr >= base and addr < base + size;
}

/// **WHAT AN MSI MESSAGE ASKS OF THIS APIC** (SDM §11.11): the vector it
/// delivers here, or null when it is not for us. The address is 0xFEExxxxx
/// with the destination in bits 19:12; it names a processor by APIC id
/// (ours is 0, and 0xFF is all of them) unless both the redirection hint
/// (bit 3) and the destination mode (bit 2) ask for a logical destination,
/// which no destination names while our logical id is 0. The data's bits
/// 10:8 are the delivery mode: fixed and lowest-priority are a vector, and
/// the others (SMI, NMI, INIT, ExtINT) are not modeled.
pub fn messageVector(address: u64, data: u32) ?u8 {
    if (address >> 20 != 0xFEE) return null;
    if (address & 0b1100 == 0b1100) return null;
    const destination = (address >> 12) & 0xFF;
    if (destination != 0 and destination != 0xFF) return null;
    return switch ((data >> 8) & 7) {
        0, 1 => @truncate(data),
        else => null,
    };
}

pub const msr_apic_base: u32 = 0x1B;
pub const msr_tsc_deadline: u32 = 0x6E0;

const reg_id = 0x020;
const reg_version = 0x030;
const reg_tpr = 0x080;
const reg_ppr = 0x0A0;
const reg_eoi = 0x0B0;
const reg_svr = 0x0F0;
const reg_isr = 0x100;
const reg_tmr = 0x180;
const reg_irr = 0x200;
const reg_lvt_timer = 0x320;
const reg_lvt_lint0 = 0x350;
const reg_lvt_lint1 = 0x360;
const reg_lvt_error = 0x370;
const reg_initial_count = 0x380;
const reg_current_count = 0x390;
const reg_divide = 0x3E0;

const lvt_masked: u32 = 1 << 16;
const svr_enabled: u32 = 1 << 8;
const base_enabled: u64 = 1 << 11;
const base_x2apic: u64 = 1 << 10;
const base_bsp: u64 = 1 << 8;

/// **THE TIMER'S CLOCK**, for its one-shot and periodic modes: the count goes
/// down once per bus cycle divided by the divide configuration. Like the
/// TSC's rate (clock.zig) this is a decision; 1 GHz is what KVM's own APIC
/// says, so a guest that calibrates against the PIT finds a familiar number.
pub const bus_hz: u64 = 1_000_000_000;
const ns_per_bus_cycle = std.time.ns_per_s / bus_hz;

/// LVT timer bits 18:17 (§11.5.4).
const Mode = enum { one_shot, periodic, tsc_deadline, reserved };

pub const Apic = struct {
    /// IA32_APIC_BASE: the address, this processor as the bootstrap one, and
    /// globally enabled, as after a reset (§11.4.4).
    base_msr: u64 = base | base_bsp | base_enabled,
    svr: u32 = 0xFF,
    tpr: u32 = 0,
    lvt_timer: u32 = lvt_masked,
    lvt_lint0: u32 = lvt_masked,
    lvt_lint1: u32 = lvt_masked,
    lvt_error: u32 = lvt_masked,
    /// IA32_TSC_DEADLINE, in the guest's TSC ticks; zero is disarmed.
    deadline: u64 = 0,
    /// The one-shot and periodic count: what the guest wrote, the divide
    /// configuration, when the count began, and when it next reaches zero
    /// (null when it is not counting).
    initial_count: u32 = 0,
    divide: u32 = 0,
    count_began: u64 = 0,
    count_ends: ?u64 = null,
    /// The IRR, vectors raised and not yet taken, and the ISR, those taken
    /// and not yet ended by an EOI (§11.8.4).
    irr: std.StaticBitSet(256) = .initEmpty(),
    isr: std.StaticBitSet(256) = .initEmpty(),
    /// How many of each were taken, for a run's closing account.
    timer_fired: u64 = 0,
    raised: u64 = 0,
    taken: u64 = 0,

    /// Enabled both ways: globally (IA32_APIC_BASE) and by software (SVR).
    pub fn enabled(self: *const Apic) bool {
        return self.base_msr & base_enabled != 0 and self.svr & svr_enabled != 0;
    }

    /// A message for `vector` arrived: an MSI-X write to our address, or the
    /// timer.
    pub fn raise(self: *Apic, vector: u8) void {
        if (vector < 16) return; // reserved for exceptions: an illegal vector
        self.irr.set(vector);
        self.raised += 1;
    }

    fn mode(self: *const Apic) Mode {
        return @enumFromInt((self.lvt_timer >> 17) & 3);
    }

    /// The divide configuration's divisor: bits 3, 1 and 0 (§11.5.4).
    fn divisor(self: *const Apic) u64 {
        const code = (self.divide & 3) | ((self.divide >> 1) & 4);
        return if (code == 7) 1 else @as(u64, 2) << @intCast(code);
    }

    fn period(self: *const Apic) u64 {
        return @as(u64, self.initial_count) * self.divisor() * ns_per_bus_cycle;
    }

    /// When the timer next reaches zero, in the machine's nanoseconds, if it
    /// will at all: armed, in either way of counting, whether masked or not.
    fn expiry(self: *const Apic) ?u64 {
        return switch (self.mode()) {
            .tsc_deadline => if (self.deadline != 0) clock.nsAt(self.deadline) else null,
            .one_shot, .periodic => self.count_ends,
            .reserved => null,
        };
    }

    /// When the timer will next interrupt: as `expiry`, but only if its LVT
    /// entry is unmasked. A masked timer still counts, and cannot wake.
    pub fn timerDue(self: *const Apic) ?u64 {
        if (self.lvt_timer & lvt_masked != 0) return null;
        return self.expiry();
    }

    /// **THE TIMER, CAUGHT UP TO `now`.** If it reached zero by then it has
    /// fired: once, however long ago, as an interrupt waits in the IRR as one
    /// bit. A TSC deadline and a one-shot count disarm; a periodic count
    /// begins again from where it reached zero. Masked, it fires with no
    /// interrupt (§11.5.1).
    pub fn tick(self: *Apic, now: u64) void {
        const due = self.expiry() orelse return;
        if (now < due) return;
        switch (self.mode()) {
            .tsc_deadline => self.deadline = 0,
            .one_shot => self.count_ends = null,
            .periodic => {
                const p = self.period();
                const ends = due + ((now - due) / p + 1) * p;
                self.count_began = ends - p;
                self.count_ends = ends;
            },
            .reserved => unreachable,
        }
        self.timer_fired += 1;
        if (self.lvt_timer & lvt_masked == 0) self.raise(@truncate(self.lvt_timer));
    }

    /// The highest vector in service, or 0 for none.
    fn isrv(self: *const Apic) u8 {
        var it = self.isr.iterator(.{ .direction = .reverse });
        return @intCast(it.next() orelse 0);
    }

    /// The processor priority (§11.8.3.1): the task priority, or the class of
    /// what is in service, whichever is higher.
    fn ppr(self: *const Apic) u8 {
        const tpr: u8 = @truncate(self.tpr);
        const in_service = self.isrv();
        return if (tpr >> 4 >= in_service >> 4) tpr else in_service & 0xF0;
    }

    /// **THE VECTOR TO INJECT NOW**, if one may be: the highest waiting, if
    /// its priority class is above the processor's (§11.8.3). So a vector
    /// waits while one of its own class or higher is in service, or while the
    /// task priority holds its class off. It is in service from here until
    /// the guest's EOI.
    pub fn next(self: *Apic) ?u8 {
        if (!self.enabled()) return null;
        var it = self.irr.iterator(.{ .direction = .reverse });
        const v: u8 = @intCast(it.next() orelse return null);
        if (v >> 4 <= self.ppr() >> 4) return null;
        self.irr.unset(v);
        self.isr.set(v);
        self.taken += 1;
        return v;
    }

    /// One 32-bit register of the page at `offset`, at the machine's time
    /// `now`.
    pub fn read(self: *Apic, offset: u64, now: u64) u32 {
        self.tick(now);
        return switch (offset) {
            reg_id => 0, // APIC id 0, in bits 24-31
            reg_version => 0x0005_0014, // a modern integrated APIC, 6 LVT entries
            reg_tpr => self.tpr,
            reg_ppr => self.ppr(),
            reg_svr => self.svr,
            reg_isr...reg_isr + 0x70 => bits(&self.isr, offset - reg_isr),
            reg_tmr...reg_tmr + 0x70 => 0, // every interrupt here is edge-triggered
            reg_irr...reg_irr + 0x70 => bits(&self.irr, offset - reg_irr),
            reg_lvt_timer => self.lvt_timer,
            reg_lvt_lint0 => self.lvt_lint0,
            reg_lvt_lint1 => self.lvt_lint1,
            reg_lvt_error => self.lvt_error,
            reg_initial_count => self.initial_count,
            reg_current_count => self.currentCount(now),
            reg_divide => self.divide,
            else => 0,
        };
    }

    /// Eight 32-bit registers, 16 bytes apart, of 32 bits each of a set.
    fn bits(set: *const std.StaticBitSet(256), offset: u64) u32 {
        if (offset % 0x10 != 0) return 0;
        const first: usize = @intCast(offset / 0x10 * 32);
        var word: u32 = 0;
        for (0..32) |i| if (set.isSet(first + i)) {
            word |= @as(u32, 1) << @intCast(i);
        };
        return word;
    }

    /// What is left of the count (§11.5.4): zero when it is not counting, in
    /// TSC-deadline mode among them.
    fn currentCount(self: *const Apic, now: u64) u32 {
        if (self.mode() == .tsc_deadline) return 0;
        const ends = self.count_ends orelse return 0;
        if (now >= ends) return 0;
        const cycles = self.divisor() * ns_per_bus_cycle;
        return @intCast((ends - now + cycles - 1) / cycles);
    }

    pub fn write(self: *Apic, offset: u64, value: u32, now: u64) void {
        self.tick(now);
        switch (offset) {
            // An EOI ends the highest vector in service (§11.8.5).
            reg_eoi => if (self.isr.findLastSet()) |v| self.isr.unset(v),
            reg_tpr => self.tpr = value & 0xFF,
            reg_svr => {
                self.svr = value;
                // **SOFTWARE-DISABLED, EVERY LVT ENTRY IS MASKED**, and stays
                // masked until it is enabled again (§11.4.7.2).
                if (value & svr_enabled == 0) {
                    self.lvt_timer |= lvt_masked;
                    self.lvt_lint0 |= lvt_masked;
                    self.lvt_lint1 |= lvt_masked;
                    self.lvt_error |= lvt_masked;
                }
            },
            reg_lvt_timer => {
                const was = self.mode();
                self.lvt_timer = self.lvtValue(value);
                const now_mode = self.mode();
                // Moving into or out of TSC-deadline mode disarms the timer
                // (§11.5.4.1); between one-shot and periodic it keeps counting.
                if ((was == .tsc_deadline) != (now_mode == .tsc_deadline)) {
                    self.deadline = 0;
                    self.initial_count = 0;
                    self.count_ends = null;
                }
            },
            reg_lvt_lint0 => self.lvt_lint0 = self.lvtValue(value),
            reg_lvt_lint1 => self.lvt_lint1 = self.lvtValue(value),
            reg_lvt_error => self.lvt_error = self.lvtValue(value),
            // Writing the initial count starts the count from it, and zero
            // stops it; in TSC-deadline mode the write is ignored (§11.5.4).
            reg_initial_count => if (self.mode() != .tsc_deadline) {
                self.initial_count = value;
                self.count_began = now;
                self.count_ends = if (value == 0) null else now + self.period();
            },
            reg_divide => self.divide = value & 0b1011,
            else => {},
        }
    }

    /// An LVT entry as written, kept masked while the APIC is software
    /// disabled.
    fn lvtValue(self: *const Apic, value: u32) u32 {
        return if (self.svr & svr_enabled == 0) value | lvt_masked else value;
    }

    /// An MSR the filter sent here. Null for one this does not model, which
    /// the guest gets as a #GP.
    pub fn readMsr(self: *Apic, index: u32, now: u64) ?u64 {
        self.tick(now);
        return switch (index) {
            msr_apic_base => self.base_msr,
            msr_tsc_deadline => self.deadline,
            else => null,
        };
    }

    /// False for a write the processor would refuse with a #GP.
    pub fn writeMsr(self: *Apic, index: u32, value: u64, now: u64) bool {
        self.tick(now);
        switch (index) {
            msr_apic_base => {
                // Bits 7:0 and 9 are reserved, and x2APIC mode (bit 10) is
                // one this processor does not have (CPUID says so).
                if (value & (0xFF | (1 << 9) | base_x2apic) != 0) return false;
                // **GLOBALLY DISABLED, THE APIC FORGETS EVERYTHING**: enabled
                // again, it is as after a reset (§11.4.3).
                // Its counts are the run's, and are kept.
                if (value & base_enabled == 0) self.* = .{ .timer_fired = self.timer_fired, .raised = self.raised, .taken = self.taken };
                // The address stays where it is: a guest that moves it is not
                // one this machine was built for, and gopher-metal refuses to.
                // The bootstrap flag is the processor's, not the guest's.
                self.base_msr = (value & base_enabled) | base_bsp | base;
            },
            // Written outside TSC-deadline mode it is ignored (§11.5.4.1);
            // zero disarms it.
            msr_tsc_deadline => if (self.mode() == .tsc_deadline) {
                self.deadline = value;
                // One already past fires at once.
                self.tick(now);
            },
            else => return false,
        }
        return true;
    }
};

// ── what can be checked without a processor ──────────────────────────────────

const testing = std.testing;

/// The guest's own start (gopher-metal's interrupts.startApic), then a rest.
fn started() Apic {
    var a = Apic{};
    _ = a.writeMsr(msr_apic_base, a.readMsr(msr_apic_base, 0).? | base_enabled, 0);
    a.write(reg_lvt_lint0, lvt_masked, 0);
    a.write(reg_svr, 0x100 | 0xFF, 0);
    a.write(reg_tpr, 0, 0);
    a.write(reg_lvt_timer, 0x21 | (2 << 17), 0);
    return a;
}

/// `ticks` of the TSC, in the machine's nanoseconds.
fn at(ticks: u64) u64 {
    return clock.nsAt(ticks);
}

test "the guest's start leaves an enabled APIC with the timer in deadline mode" {
    var a = started();
    try testing.expect(a.enabled());
    try testing.expect(a.timerDue() == null);
    try testing.expect(a.writeMsr(msr_tsc_deadline, 5000, 0));
    try testing.expectEqual(@as(?u64, at(5000)), a.timerDue());
}

test "the timer fires once, at its deadline, and is taken until EOI" {
    var a = started();
    _ = a.writeMsr(msr_tsc_deadline, 5000, 0);
    a.tick(at(5000) - 1);
    try testing.expect(a.next() == null);
    a.tick(at(5000));
    try testing.expectEqual(@as(?u8, 0x21), a.next());
    try testing.expect(a.timerDue() == null); // disarmed
    a.raise(0x22);
    try testing.expect(a.next() == null); // 0x21, of the same class, is in service
    a.write(reg_eoi, 0, 0);
    try testing.expectEqual(@as(?u8, 0x22), a.next());
}

test "the highest pending vector goes first" {
    var a = started();
    a.raise(0x30);
    a.raise(0x40);
    try testing.expectEqual(@as(?u8, 0x40), a.next());
    a.write(reg_eoi, 0, 0);
    try testing.expectEqual(@as(?u8, 0x30), a.next());
}

test "nothing is delivered by an APIC that was never enabled" {
    var a = Apic{};
    a.raise(0x30);
    try testing.expect(a.next() == null);
}

test "a deadline written outside deadline mode is ignored, and reads zero" {
    var a = Apic{};
    try testing.expect(a.writeMsr(msr_tsc_deadline, 5000, 0));
    try testing.expect(a.timerDue() == null);
    try testing.expectEqual(@as(?u64, 0), a.readMsr(msr_tsc_deadline, 0));
}

// §11.8.3: the task priority and the processor priority.

test "the task priority holds off every class at or below its own" {
    var a = started();
    a.write(reg_tpr, 0x45, 0);
    a.raise(0x41);
    a.raise(0x4F);
    try testing.expect(a.next() == null);
    a.raise(0x50);
    try testing.expectEqual(@as(?u8, 0x50), a.next());
    a.write(reg_eoi, 0, 0);
    a.write(reg_tpr, 0x30, 0);
    try testing.expectEqual(@as(?u8, 0x4F), a.next());
}

test "the processor priority is the higher of the task priority and what is in service" {
    var a = started();
    a.write(reg_tpr, 0x23, 0);
    try testing.expectEqual(@as(u32, 0x23), a.read(reg_ppr, 0));
    a.raise(0x61);
    _ = a.next();
    try testing.expectEqual(@as(u32, 0x60), a.read(reg_ppr, 0));
    a.write(reg_eoi, 0, 0);
    try testing.expectEqual(@as(u32, 0x23), a.read(reg_ppr, 0));
}

test "a higher class nests above one in service; the EOI ends the higher first" {
    var a = started();
    a.raise(0x41);
    try testing.expectEqual(@as(?u8, 0x41), a.next());
    a.raise(0x48); // same class: waits
    a.raise(0x90); // higher class: may interrupt the handler
    try testing.expectEqual(@as(?u8, 0x90), a.next());
    try testing.expect(a.next() == null);
    a.write(reg_eoi, 0, 0); // ends 0x90, the highest in service
    try testing.expect(a.isr.isSet(0x41));
    try testing.expect(a.next() == null); // 0x41 still holds its class
    a.write(reg_eoi, 0, 0);
    try testing.expectEqual(@as(?u8, 0x48), a.next());
}

test "the IRR and ISR registers say what is waiting and what is in service" {
    var a = started();
    a.raise(0x41);
    a.raise(0x90);
    try testing.expectEqual(@as(u32, 1 << 1), a.read(reg_irr + 0x20, 0)); // 0x41 = 2 * 32 + 1
    try testing.expectEqual(@as(u32, 1 << 16), a.read(reg_irr + 0x40, 0)); // 0x90 = 4 * 32 + 16
    _ = a.next();
    try testing.expectEqual(@as(u32, 0), a.read(reg_irr + 0x40, 0));
    try testing.expectEqual(@as(u32, 1 << 16), a.read(reg_isr + 0x40, 0));
}

// §11.5.4.1: TSC-deadline mode.

test "a deadline already past fires at once, at the write" {
    var a = started();
    try testing.expect(a.writeMsr(msr_tsc_deadline, 100, at(1000)));
    try testing.expect(a.irr.isSet(0x21));
    try testing.expectEqual(@as(?u64, 0), a.readMsr(msr_tsc_deadline, at(1000)));
}

test "a deadline of zero disarms it" {
    var a = started();
    _ = a.writeMsr(msr_tsc_deadline, 5000, 0);
    _ = a.writeMsr(msr_tsc_deadline, 0, 0);
    try testing.expect(a.timerDue() == null);
    a.tick(at(1_000_000));
    try testing.expect(a.next() == null);
}

test "a deadline that passes while the guest runs has fired by the next time it looks" {
    var a = started();
    _ = a.writeMsr(msr_tsc_deadline, 5000, 0);
    // The guest runs past it and reads the MSR: zero, as the timer fired.
    try testing.expectEqual(@as(?u64, 0), a.readMsr(msr_tsc_deadline, at(6000)));
    // A new deadline written after it does not take back the interrupt.
    _ = a.writeMsr(msr_tsc_deadline, 9000, at(6000));
    try testing.expectEqual(@as(?u8, 0x21), a.next());
    try testing.expectEqual(@as(?u64, at(9000)), a.timerDue());
}

test "a masked deadline that passes disarms with no interrupt" {
    var a = started();
    a.write(reg_lvt_timer, 0x21 | (2 << 17) | lvt_masked, 0);
    _ = a.writeMsr(msr_tsc_deadline, 5000, 0);
    try testing.expect(a.timerDue() == null); // cannot wake anything
    a.write(reg_lvt_timer, 0x21 | (2 << 17), at(6000)); // unmasked, after
    try testing.expect(a.next() == null);
    try testing.expectEqual(@as(?u64, 0), a.readMsr(msr_tsc_deadline, at(6000)));
}

test "leaving deadline mode disarms the deadline" {
    var a = started();
    _ = a.writeMsr(msr_tsc_deadline, 5000, 0);
    a.write(reg_lvt_timer, 0x21, 0); // one-shot
    a.write(reg_lvt_timer, 0x21 | (2 << 17), 0);
    try testing.expect(a.timerDue() == null);
}

// §11.5.4: one-shot and periodic.

/// An APIC whose timer counts, on 0x30, in `mode` (0 one-shot, 1 periodic).
fn counting(mode_bits: u32) Apic {
    var a = started();
    a.write(reg_lvt_timer, 0x30 | (mode_bits << 17), 0);
    return a;
}

test "the divide configuration's eight divisors" {
    var a = Apic{};
    const want = [_]struct { u32, u64 }{
        .{ 0b0000, 2 },  .{ 0b0001, 4 },  .{ 0b0010, 8 },   .{ 0b0011, 16 },
        .{ 0b1000, 32 }, .{ 0b1001, 64 }, .{ 0b1010, 128 }, .{ 0b1011, 1 },
    };
    for (want) |w| {
        a.write(reg_divide, w[0], 0);
        try testing.expectEqual(w[1], a.divisor());
    }
}

test "one-shot: the count goes down from the initial count, fires at zero, and stays there" {
    var a = counting(0);
    a.write(reg_divide, 0b0001, 0); // by 4: 4 ns a count at 1 GHz
    a.write(reg_initial_count, 1000, 100);
    try testing.expectEqual(@as(u32, 1000), a.read(reg_current_count, 100));
    try testing.expectEqual(@as(u32, 750), a.read(reg_current_count, 1100));
    try testing.expectEqual(@as(?u64, 4100), a.timerDue());
    try testing.expect(a.next() == null);
    a.tick(4100);
    try testing.expectEqual(@as(?u8, 0x30), a.next());
    try testing.expectEqual(@as(u32, 0), a.read(reg_current_count, 5000));
    try testing.expect(a.timerDue() == null);
    try testing.expectEqual(@as(u32, 1000), a.read(reg_initial_count, 5000));
}

test "periodic: it reloads at zero and fires every period, once however late it is seen" {
    var a = counting(1);
    a.write(reg_divide, 0b1011, 0); // by 1
    a.write(reg_initial_count, 100, 0);
    a.tick(100);
    try testing.expectEqual(@as(?u8, 0x30), a.next());
    a.write(reg_eoi, 0, 100);
    try testing.expectEqual(@as(?u64, 200), a.timerDue());
    try testing.expectEqual(@as(u32, 50), a.read(reg_current_count, 150));
    // Three periods pass unseen: one interrupt waits, and the count is in
    // step with where it would have been.
    a.tick(450);
    try testing.expectEqual(@as(?u8, 0x30), a.next());
    try testing.expect(a.next() == null);
    try testing.expectEqual(@as(?u64, 500), a.timerDue());
    try testing.expectEqual(@as(u32, 50), a.read(reg_current_count, 450));
}

test "an initial count of zero stops the timer" {
    var a = counting(1);
    a.write(reg_initial_count, 100, 0);
    a.write(reg_initial_count, 0, 50);
    try testing.expect(a.timerDue() == null);
    try testing.expectEqual(@as(u32, 0), a.read(reg_current_count, 60));
}

test "in deadline mode the initial count is ignored and the current count reads zero" {
    var a = started();
    a.write(reg_initial_count, 100, 0);
    try testing.expectEqual(@as(u32, 0), a.read(reg_initial_count, 0));
    try testing.expectEqual(@as(u32, 0), a.read(reg_current_count, 10));
    try testing.expect(a.timerDue() == null);
}

// §11.4: enabling and disabling it.

test "software-disabled, every LVT entry is masked and stays masked" {
    var a = started();
    a.write(reg_svr, 0xFF, 0);
    try testing.expect(a.read(reg_lvt_timer, 0) & lvt_masked != 0);
    a.write(reg_lvt_timer, 0x21 | (2 << 17), 0);
    try testing.expect(a.read(reg_lvt_timer, 0) & lvt_masked != 0);
    a.write(reg_svr, 0x1FF, 0);
    a.write(reg_lvt_timer, 0x21 | (2 << 17), 0);
    try testing.expect(a.read(reg_lvt_timer, 0) & lvt_masked == 0);
}

test "IA32_APIC_BASE refuses x2APIC mode and its reserved bits" {
    var a = started();
    const b = a.readMsr(msr_apic_base, 0).?;
    try testing.expect(!a.writeMsr(msr_apic_base, b | base_x2apic, 0));
    try testing.expect(!a.writeMsr(msr_apic_base, b | 1, 0));
    try testing.expectEqual(@as(?u64, b), a.readMsr(msr_apic_base, 0));
}

test "globally disabled and enabled again, the APIC is as after a reset" {
    var a = started();
    a.raise(0x40);
    _ = a.writeMsr(msr_tsc_deadline, 5000, 0);
    const b = a.readMsr(msr_apic_base, 0).?;
    _ = a.writeMsr(msr_apic_base, b & ~base_enabled, 0);
    try testing.expect(!a.enabled());
    _ = a.writeMsr(msr_apic_base, b, 0);
    try testing.expectEqual(@as(u32, 0xFF), a.read(reg_svr, 0));
    try testing.expect(a.read(reg_lvt_timer, 0) & lvt_masked != 0);
    try testing.expect(!a.irr.isSet(0x40));
    try testing.expectEqual(@as(?u64, 0), a.readMsr(msr_tsc_deadline, 0));
}
