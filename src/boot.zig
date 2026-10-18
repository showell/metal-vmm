//! **THE GUEST'S WAY IN** (the PVH boot protocol): where in its memory the
//! things it is handed go, the start_info and memory map it is told, a flat
//! GDT, and the processor put in 32-bit protected mode with `%ebx` at the
//! start_info. main.zig calls these once, before the first run.

const std = @import("std");
const kvm = @import("kvm.zig");
const linux = std.os.linux;

/// How much RAM the guest gets. The probes were written against `-m 512`.
pub const ram_bytes: usize = 512 * 1024 * 1024;

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

/// Writes the start_info, its memory map and the command line into guest
/// memory, and answers where the start_info landed.
pub fn tell(ram: []u8, command_line: []const u8) u64 {
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

/// A flat GDT: null, code, data. The guest replaces it within a few dozen
/// instructions, but the processor will not enter protected mode without one
/// that agrees with the segments below.
pub fn writeGdt(ram: []u8) void {
    const table = [_]u64{
        0,
        0x00CF9A000000FFFF, // code: present, ring 0, executable, 32-bit, 4 GB
        0x00CF92000000FFFF, // data: present, ring 0, writable, 32-bit, 4 GB
    };
    const at: usize = @intCast(gdt_addr);
    @memcpy(ram[at..][0..@sizeOf(@TypeOf(table))], std.mem.asBytes(&table));
}

pub fn enterProtectedMode(vcpu: linux.fd_t, entry: u64, start_info: u64) !void {
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
