//! **THE LOCAL APIC, OURS.** gopher-metal halts between frames (`sti; hlt`)
//! once its network card is on PCI, and wakes on one of two interrupts: the
//! card's MSI-X message, or the APIC's timer in TSC-deadline mode. KVM can
//! model an APIC in the kernel, but that one keeps the host's time, and this
//! machine's time is its own (clock.zig). So the vCPU has no in-kernel
//! interrupt controller, and this file is its APIC: the few registers the guest
//! touches, the timer's deadline, and the vectors waiting to be taken.
//!
//! **WHEN AN INTERRUPT IS TAKEN IS OURS TO SAY, AND IT IS ALWAYS A HALT.** The
//! guest runs with interrupts off except across `sti; hlt`, so an interrupt
//! can only be taken where it halted. At that halt the machine moves its clock
//! straight to the earliest thing that can wake it — the deadline, or the next
//! frame due on the wire — and injects the vector. Same guest, same seed: the
//! same interrupt at the same instruction at the same virtual time.
//!
//! Intel SDM vol. 3 ch. 11 (the APIC) and §11.5.4.1 (TSC-deadline mode).

const std = @import("std");

pub const base: u64 = 0xFEE0_0000;
pub const size: u64 = 0x1000;

pub fn inWindow(addr: u64) bool {
    return addr >= base and addr < base + size;
}

pub const msr_apic_base: u32 = 0x1B;
pub const msr_tsc_deadline: u32 = 0x6E0;

const reg_id = 0x020;
const reg_version = 0x030;
const reg_tpr = 0x080;
const reg_eoi = 0x0B0;
const reg_svr = 0x0F0;
const reg_lvt_timer = 0x320;
const reg_lvt_lint0 = 0x350;
const reg_lvt_lint1 = 0x360;
const reg_lvt_error = 0x370;

const lvt_masked: u32 = 1 << 16;
const timer_mode_tsc_deadline: u32 = 2 << 17;
const svr_enabled: u32 = 1 << 8;

pub const Apic = struct {
    /// What the guest wrote to IA32_APIC_BASE: the address, this processor
    /// as the bootstrap one, and (once the guest says so) enabled.
    base_msr: u64 = base | (1 << 8),
    svr: u32 = 0xFF,
    tpr: u32 = 0,
    lvt_timer: u32 = lvt_masked,
    lvt_lint0: u32 = lvt_masked,
    lvt_lint1: u32 = lvt_masked,
    lvt_error: u32 = lvt_masked,
    /// IA32_TSC_DEADLINE, in the guest's TSC ticks; zero is disarmed.
    deadline: u64 = 0,
    /// Vectors raised and not yet taken, and the one being handled until its
    /// EOI. Only one at a time is in service: the guest takes interrupts
    /// only at a halt and with them off in the handler, so nothing nests.
    pending: std.StaticBitSet(256) = .initEmpty(),
    in_service: ?u8 = null,
    /// How many of each were taken, for a run's closing account.
    timer_fired: u64 = 0,
    raised: u64 = 0,
    taken: u64 = 0,

    pub fn enabled(self: *const Apic) bool {
        return self.base_msr & (1 << 11) != 0 and self.svr & svr_enabled != 0;
    }

    /// A message for `vector` arrived: an MSI-X write to our address, or the
    /// timer.
    pub fn raise(self: *Apic, vector: u8) void {
        if (vector < 16) return; // reserved for exceptions: an illegal vector
        self.pending.set(vector);
        self.raised += 1;
    }

    /// The deadline, if one is armed and the timer is unmasked in
    /// TSC-deadline mode: the tick at which the timer fires.
    pub fn timerDue(self: *const Apic) ?u64 {
        if (self.deadline == 0) return null;
        if (self.lvt_timer & lvt_masked != 0) return null;
        if (self.lvt_timer & (3 << 17) != timer_mode_tsc_deadline) return null;
        return self.deadline;
    }

    /// The timer, if its deadline has come: it fires once and disarms, as
    /// TSC-deadline mode does.
    pub fn tick(self: *Apic, now_ticks: u64) void {
        const due = self.timerDue() orelse return;
        if (now_ticks < due) return;
        self.deadline = 0;
        self.timer_fired += 1;
        self.raise(@truncate(self.lvt_timer));
    }

    /// The vector to inject now, if one is waiting and none is in service:
    /// the highest, as the APIC's priority rule takes them. It is in service
    /// from here until the guest's EOI.
    pub fn next(self: *Apic) ?u8 {
        if (!self.enabled() or self.in_service != null) return null;
        var it = self.pending.iterator(.{ .direction = .reverse });
        const v = it.next() orelse return null;
        self.pending.unset(v);
        self.in_service = @intCast(v);
        self.taken += 1;
        return @intCast(v);
    }

    pub fn read(self: *const Apic, offset: u64) u32 {
        return switch (offset) {
            reg_id => 0, // APIC id 0, in bits 24-31
            reg_version => 0x0005_0014, // a modern integrated APIC, 6 LVT entries
            reg_tpr => self.tpr,
            reg_svr => self.svr,
            reg_lvt_timer => self.lvt_timer,
            reg_lvt_lint0 => self.lvt_lint0,
            reg_lvt_lint1 => self.lvt_lint1,
            reg_lvt_error => self.lvt_error,
            else => 0,
        };
    }

    pub fn write(self: *Apic, offset: u64, value: u32) void {
        switch (offset) {
            reg_eoi => self.in_service = null,
            reg_tpr => self.tpr = value & 0xFF,
            reg_svr => self.svr = value,
            reg_lvt_timer => {
                // Leaving TSC-deadline mode disarms the deadline (§11.5.4.1).
                if (value & (3 << 17) != timer_mode_tsc_deadline) self.deadline = 0;
                self.lvt_timer = value;
            },
            reg_lvt_lint0 => self.lvt_lint0 = value,
            reg_lvt_lint1 => self.lvt_lint1 = value,
            reg_lvt_error => self.lvt_error = value,
            else => {},
        }
    }

    /// An MSR the filter sent here. False for one this does not model, which
    /// the guest gets as a #GP.
    pub fn readMsr(self: *const Apic, index: u32) ?u64 {
        return switch (index) {
            msr_apic_base => self.base_msr,
            msr_tsc_deadline => self.deadline,
            else => null,
        };
    }

    pub fn writeMsr(self: *Apic, index: u32, value: u64) bool {
        switch (index) {
            // The address stays where it is: a guest that moves it is not one
            // this machine was built for, and gopher-metal refuses to.
            msr_apic_base => self.base_msr = (value & ~@as(u64, 0xFFFF_F000)) | base,
            // Written outside TSC-deadline mode it is ignored (§11.5.4.1).
            msr_tsc_deadline => if (self.lvt_timer & (3 << 17) == timer_mode_tsc_deadline) {
                self.deadline = value;
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
    _ = a.writeMsr(msr_apic_base, a.readMsr(msr_apic_base).? | (1 << 11));
    a.write(reg_lvt_lint0, lvt_masked);
    a.write(reg_svr, 0x100 | 0xFF);
    a.write(reg_tpr, 0);
    a.write(reg_lvt_timer, 0x21 | timer_mode_tsc_deadline);
    return a;
}

test "the guest's start leaves an enabled APIC with the timer in deadline mode" {
    var a = started();
    try testing.expect(a.enabled());
    try testing.expect(a.timerDue() == null);
    try testing.expect(a.writeMsr(msr_tsc_deadline, 5000));
    try testing.expectEqual(@as(?u64, 5000), a.timerDue());
}

test "the timer fires once, at its deadline, and is taken until EOI" {
    var a = started();
    _ = a.writeMsr(msr_tsc_deadline, 5000);
    a.tick(4999);
    try testing.expect(a.next() == null);
    a.tick(5000);
    try testing.expectEqual(@as(?u8, 0x21), a.next());
    try testing.expect(a.timerDue() == null); // disarmed
    a.raise(0x22);
    try testing.expect(a.next() == null); // 0x21 is still in service
    a.write(reg_eoi, 0);
    try testing.expectEqual(@as(?u8, 0x22), a.next());
}

test "the highest pending vector goes first" {
    var a = started();
    a.raise(0x30);
    a.raise(0x40);
    try testing.expectEqual(@as(?u8, 0x40), a.next());
    a.write(reg_eoi, 0);
    try testing.expectEqual(@as(?u8, 0x30), a.next());
}

test "nothing is delivered by an APIC that was never enabled" {
    var a = Apic{};
    a.raise(0x30);
    try testing.expect(a.next() == null);
}

test "a deadline written outside deadline mode is ignored" {
    var a = Apic{};
    try testing.expect(a.writeMsr(msr_tsc_deadline, 5000));
    try testing.expect(a.timerDue() == null);
}
