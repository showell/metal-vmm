//! **THE KERNEL'S SIDE OF A VIRTUAL MACHINE**, as Linux presents it: a
//! character device, a handful of ioctls, and three structures that have to be
//! laid out exactly as `/usr/include/linux/kvm.h` lays them out.
//!
//! Everything here is transcribed from that header rather than remembered.
//! The sizes are checked at compile time, because an ioctl number CARRIES the
//! size of its argument — a structure a byte too long does not mis-parse, it
//! fails with EINVAL and says nothing about why.

const std = @import("std");
const linux = std.os.linux;

pub const device = "/dev/kvm";
/// The version this was written against. KVM promises 12 forever.
pub const api_version: usize = 12;

// ── the ioctl numbers ────────────────────────────────────────────────────────
//
// _IOC(dir, type, nr, size): the direction and the argument's size are part of
// the number, which is why the sizes below are computed from our own structs.

const none = 0;
const write = 1;
const read = 2;

fn code(dir: u32, nr: u32, size: usize) u32 {
    return (dir << 30) | (@as(u32, @intCast(size)) << 16) | (0xAE << 8) | nr;
}

pub const get_api_version = code(none, 0x00, 0);
pub const create_vm = code(none, 0x01, 0);
pub const get_vcpu_mmap_size = code(none, 0x04, 0);
pub const create_vcpu = code(none, 0x41, 0);
pub const set_user_memory_region = code(write, 0x46, @sizeOf(MemoryRegion));
pub const run = code(none, 0x80, 0);
/// **A NEW PROCESSOR KNOWS NOTHING ABOUT ITSELF.** KVM gives a fresh vCPU an
/// empty CPUID, and a guest that cannot see long mode in CPUID cannot turn it
/// on: setting EFER.LME faults, and with no interrupt table that is a triple
/// fault three instructions later. So the host's supported CPUID is fetched
/// and handed straight back.
pub const get_supported_cpuid = code(read | write, 0x05, @sizeOf(Cpuid));
pub const set_cpuid2 = code(write, 0x90, @sizeOf(Cpuid));
pub const get_regs = code(read, 0x81, @sizeOf(Regs));
pub const set_regs = code(write, 0x82, @sizeOf(Regs));
pub const get_sregs = code(read, 0x83, @sizeOf(Sregs));
pub const set_sregs = code(write, 0x84, @sizeOf(Sregs));

// ── the structures ───────────────────────────────────────────────────────────

pub const MemoryRegion = extern struct {
    slot: u32,
    flags: u32 = 0,
    guest_phys_addr: u64,
    memory_size: u64,
    userspace_addr: u64,
};

pub const Regs = extern struct {
    rax: u64 = 0,
    rbx: u64 = 0,
    rcx: u64 = 0,
    rdx: u64 = 0,
    rsi: u64 = 0,
    rdi: u64 = 0,
    rsp: u64 = 0,
    rbp: u64 = 0,
    r8: u64 = 0,
    r9: u64 = 0,
    r10: u64 = 0,
    r11: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0,
    rip: u64 = 0,
    /// Bit 1 is reserved and must be set; a zero here is not a valid state.
    rflags: u64 = 0x2,
};

pub const Segment = extern struct {
    base: u64 = 0,
    limit: u32 = 0,
    selector: u16 = 0,
    type: u8 = 0,
    present: u8 = 0,
    dpl: u8 = 0,
    db: u8 = 0,
    s: u8 = 0,
    l: u8 = 0,
    g: u8 = 0,
    avl: u8 = 0,
    unusable: u8 = 0,
    padding: u8 = 0,
};

pub const Dtable = extern struct {
    base: u64 = 0,
    limit: u16 = 0,
    padding: [3]u16 = .{ 0, 0, 0 },
};

pub const Sregs = extern struct {
    cs: Segment = .{},
    ds: Segment = .{},
    es: Segment = .{},
    fs: Segment = .{},
    gs: Segment = .{},
    ss: Segment = .{},
    tr: Segment = .{},
    ldt: Segment = .{},
    gdt: Dtable = .{},
    idt: Dtable = .{},
    cr0: u64 = 0,
    cr2: u64 = 0,
    cr3: u64 = 0,
    cr4: u64 = 0,
    cr8: u64 = 0,
    efer: u64 = 0,
    apic_base: u64 = 0,
    interrupt_bitmap: [4]u64 = .{ 0, 0, 0, 0 },
};

comptime {
    // The header's own sizes. If one of these is wrong the ioctl number is
    // wrong, and KVM answers EINVAL without saying which field moved.
    std.debug.assert(@sizeOf(MemoryRegion) == 32);
    std.debug.assert(@sizeOf(Regs) == 144);
    std.debug.assert(@sizeOf(Segment) == 24);
    std.debug.assert(@sizeOf(Dtable) == 16);
    std.debug.assert(@sizeOf(Sregs) == 312);
}

/// The head of a CPUID list; the entries follow it in memory.
pub const Cpuid = extern struct {
    nent: u32,
    padding: u32 = 0,
};

pub const CpuidEntry = extern struct {
    function: u32,
    index: u32,
    flags: u32,
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
    padding: [3]u32,
};

/// Enough for every entry any processor has offered so far; KVM writes how
/// many it used into `nent`.
pub const max_cpuid_entries = 256;

pub const CpuidBuffer = extern struct {
    head: Cpuid,
    entries: [max_cpuid_entries]CpuidEntry,
};

comptime {
    std.debug.assert(@sizeOf(Cpuid) == 8);
    std.debug.assert(@sizeOf(CpuidEntry) == 40);
}

// ── what the processor came back for ─────────────────────────────────────────

pub const Exit = enum(u32) {
    unknown = 0,
    io = 2,
    hlt = 5,
    mmio = 6,
    shutdown = 8,
    fail_entry = 9,
    internal_error = 17,
    _,
};

pub const io_in: u8 = 0;
pub const io_out: u8 = 1;

/// The shared page between us and the kernel. Only the head is spelled out
/// here: the rest is a union whose members are read through `ioExit`, which is
/// how the header means them to be reached.
pub const Run = extern struct {
    request_interrupt_window: u8,
    immediate_exit: u8,
    padding1: [6]u8,
    exit_reason: u32,
    ready_for_interrupt_injection: u8,
    if_flag: u8,
    flags: u16,
    cr8: u64,
    apic_base: u64,
    // the union begins here
};

pub const IoExit = extern struct {
    direction: u8,
    size: u8,
    port: u16,
    count: u32,
    /// Where the bytes are, measured from the start of the shared page.
    data_offset: u64,
};

pub const MmioExit = extern struct {
    phys_addr: u64,
    data: [8]u8,
    len: u32,
    is_write: u8,
};

comptime {
    std.debug.assert(@sizeOf(Run) == 32);
    std.debug.assert(@sizeOf(IoExit) == 16);
    std.debug.assert(@sizeOf(MmioExit) == 24);
}

/// The port-I/O exit's details, which live in the union just past the head.
pub fn ioExit(page: []align(std.heap.page_size_min) u8) *IoExit {
    return @ptrCast(@alignCast(page.ptr + @sizeOf(Run)));
}

/// The memory-mapped access's details, in the same union as the port one.
pub fn mmioExit(page: []align(std.heap.page_size_min) u8) *MmioExit {
    return @ptrCast(@alignCast(page.ptr + @sizeOf(Run)));
}

/// The bytes an OUT wrote, or the buffer an IN wants filled.
pub fn ioData(page: []align(std.heap.page_size_min) u8, io: *const IoExit) []u8 {
    const at: usize = @intCast(io.data_offset);
    return page[at .. at + @as(usize, io.size) * io.count];
}

// ── talking to it ────────────────────────────────────────────────────────────

pub const Error = error{KvmFailed};

/// One ioctl, with the errno turned into an error rather than a negative
/// number nobody checks.
pub fn call(fd: linux.fd_t, request: u32, arg: usize) Error!usize {
    const rc = linux.ioctl(fd, request, arg);
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        else => error.KvmFailed,
    };
}

/// The errno of the last failed call, for a message that says which one.
pub fn why(fd: linux.fd_t, request: u32, arg: usize) linux.E {
    return linux.errno(linux.ioctl(fd, request, arg));
}
