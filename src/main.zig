//! **A VIRTUAL MACHINE, ONE PROCESS, NO QEMU.**
//!
//!     metal-vmm <kernel.elf>
//!
//! Loads a PVH kernel — zig-metal-unikernel's probes and its server are exactly this
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
const frames = @import("frames.zig");
const clock = @import("clock.zig");
const entropy = @import("entropy.zig");
const disk = @import("disk.zig");
const wire = @import("peer.zig");
const cost = @import("cost.zig");
const cache = @import("cache.zig");
const scsi = @import("scsi.zig");
const coverage = @import("coverage.zig");
const knobs = @import("knobs.zig");
const checked = @import("checked.zig");
const pci = @import("pci.zig");
const settings = @import("settings.zig");
const reports = @import("reports.zig");
const loader = @import("loader.zig");
const processor = @import("processor.zig");
const halt = @import("halt.zig");
const turn = @import("turn.zig");
const pair = @import("pair.zig");
const boot = @import("boot.zig");
const machine_file = @import("machine.zig");
const serve_file = @import("serve.zig");
const client_files = @import("client_files.zig");
const readAll = client_files.readAll;
const request_max = client_files.request_max;
const theClient = client_files.theClient;
const serve = serve_file.serve;
const readLittle = machine_file.readLittle;
const Machine = machine_file.Machine;
const SerialOut = machine_file.SerialOut;
const tellTheFaults = settings.tellTheFaults;
const count = settings.count;
const knob = settings.knob;
const numbers = settings.numbers;
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
const describeProcessor = processor.describeProcessor;
const forgetTheDice = processor.forgetTheDice;
const sayTheApic = processor.sayTheApic;
const hideTheHostsTime = processor.hideTheHostsTime;
const owned_msrs = processor.owned_msrs;
const msr_tsc = processor.msr_tsc;
const msrFilter = processor.msrFilter;
const ownTheMsrs = processor.ownTheMsrs;
const Rested = halt.Rested;
const Cpu = halt.Cpu;
const Wake = halt.Wake;
const wakes = halt.wakes;

// ── putting it together ──────────────────────────────────────────────────────

/// What the volume was asked, if one was attached (`VOLUME`): a run without
/// one says nothing new.
/// **THE POWER FAILS WHEN THE GUEST STOPS** (`VOLUME_CUT_AT_EXIT=1`, QUEUE
/// item 68): every write cache loses what was never synchronized, before
/// anything is reported or written back, whatever the end. So a write the
/// guest answered for and never synchronized is gone, even when the
/// response that confirmed it came after the last write. One line says
/// what each lost.
fn cutAtExit(machine: *Machine) void {
    if (!machine.cut_at_exit) return;
    var disk_lost: u64 = 0;
    var volume_lost: u64 = 0;
    if (machine.write_cache) |c| {
        c.loseAtExit();
        disk_lost = c.exit_lost;
    }
    if (machine.volume) |v| if (v.cache) |c| {
        c.loseAtExit();
        volume_lost = c.exit_lost;
    };
    std.debug.print("metal-vmm: the power failed when the guest stopped (VOLUME_CUT_AT_EXIT): {d} volume sectors and {d} disk sectors never synchronized were lost\n", .{ volume_lost, disk_lost });
}

/// The faults that took effect, for a sweep's excuses (metal-vmm QUEUE
/// 124(e)): `reports.fired`.
fn reportFired(card: *const net.Net, block: *const virtio.Block, machine: *const Machine) void {
    var buf: [512]u8 = undefined;
    std.debug.print("{s}", .{reports.fired(&card.peer, &block.refusals, machine.volume, &buf)});
    var during_buf: [1024]u8 = undefined;
    std.debug.print("{s}", .{machine.during.say(&during_buf)});
}

fn reportVolume(machine: *const Machine) void {
    const v = machine.volume orelse return;
    var buf: [scsi.Scsi.line_bytes]u8 = undefined;
    std.debug.print("{s}", .{v.line(&buf)});
}

/// What the client got, for a caller that wants to diff it against another
/// client's.
/// **WHICH ENDS KEEP WHAT THE GUEST WROTE** (QUEUE.md item 42): one that
/// ended as the guest meant, by its exit door or a power cut it was dealt,
/// an idle one, which is a server's normal end, and one watched for as
/// long as `GUEST_S` asked. Not a crash, a guest
/// that faulted or got stuck, or anything KVM refused: the image is left as
/// it was found, and a timeout from outside never gets here at all.
fn keepsWrites(e: anyerror) bool {
    return e == error.GuestIdle or e == error.GuestWatched;
}

test "an idle end keeps the guest's writes; a stuck, faulted or failed one does not" {
    try testing.expect(keepsWrites(error.GuestIdle));
    try testing.expect(keepsWrites(error.GuestWatched));
    for ([_]anyerror{ error.GuestStuck, error.GuestFaulted, error.KvmFailed, error.Unhandled }) |e| {
        try testing.expect(!keepsWrites(e));
    }
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

    // **EVERY SETTING SAYS WHAT IT MEANS, OR THE RUN DOES NOT START**
    // (checked.zig): a value that is not one is refused here, before any of
    // them is read, rather than read as no fault.
    var complaint_buf: [512]u8 = undefined;
    if (checked.complaint(init.environ.block.view().slice, &complaint_buf)) |why| {
        std.debug.print("metal-vmm: {s} (KNOBS.md)\n", .{why});
        return 2;
    }

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
    // an APIC, and a guest that halts between frames, as zig-metal-unikernel does on
    // a droplet. Unset is the microvm-shaped machine check.sh compares with
    // QEMU's microvm.
    const pc = if (init.environ.getPosix("TRANSPORT")) |t| std.mem.eql(u8, t, "pci") else false;
    if (pc) ownTheMsrs(vm) catch |e| {
        std.debug.print("metal-vmm: this KVM will not hand over the APIC's MSRs ({s}): TRANSPORT=pci needs Linux 5.10 or later\n", .{@errorName(e)});
        return 2;
    };

    const ram = try posix.mmap(null, boot.ram_bytes, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    // **HUGE PAGES FOR THE GUEST'S MEMORY, IF THE HOST GIVES THEM** (its
    // transparent huge pages are "madvise" here): the guest's first touch of
    // each 4 KiB page was a fault of the host's, about 26,000 a boot. A
    // speed-up only: refused, it is the run it was.
    _ = linux.madvise(ram.ptr, ram.len, linux.MADV.HUGEPAGE);
    var region = kvm.MemoryRegion{
        .slot = 0,
        .guest_phys_addr = 0,
        .memory_size = boot.ram_bytes,
        .userspace_addr = @intFromPtr(ram.ptr),
    };
    _ = try kvm.call(vm, kvm.set_user_memory_region, @intFromPtr(&region));

    const loaded = load(ram, image) catch |e| {
        std.debug.print("metal-vmm: {s} is not a kernel this can start: {s}\n", .{ path, @errorName(e) });
        return 2;
    };
    boot.writeGdt(ram);
    const start_info = boot.tell(ram, command_line);

    const vcpu: linux.fd_t = @intCast(try kvm.call(vm, kvm.create_vcpu, 0));
    defer _ = linux.close(vcpu);
    const page_size = try kvm.call(dev, kvm.get_vcpu_mmap_size, 0);
    const page = try posix.mmap(null, page_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, vcpu, 0);

    try describeProcessor(dev, vcpu, pc);
    try boot.enterProtectedMode(vcpu, loaded.entry, start_info);

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
    // A run with no disk still has a disk's faults to set and report: none,
    // on a block device with nothing behind it, never memory left undefined.
    var block: virtio.Block = .{ .image = &.{} };
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
        if (init.environ.getPosix("DISK_TRACE")) |v| block.trace = std.mem.eql(u8, v, "1");
        block_device = block.device();
        machine.drive = &block.refusals;
        if (!pc) machine.devices[0] = &block_device;
    }
    // **THE WIRE ENDS HERE, ON PURPOSE.** There is always a network device,
    // because the machine at the other end of it is this program and costs
    // nothing when nobody talks to it.
    // **WHICH SIDE OF A PAIR THIS IS** (`SIDE=0` or `1`, docs/TWO-KERNELS.md
    // §4; QUEUE 225, chunk 10): its card's address and its lease, read
    // before the card is built, which copies the address. 0 unset, as
    // every run before a pair.
    var side: u8 = 0;
    if (init.environ.getPosix("SIDE")) |text| {
        const n = std.fmt.parseInt(u8, text, 10) catch std.math.maxInt(u8);
        if (n > frames.max_side) {
            std.debug.print("metal-vmm: SIDE={s} is not a side of a pair: 0 or 1\n", .{text});
            return 2;
        }
        frames.guest = frames.side(n);
        side = n;
    }
    // **IN A PAIR, THE OTHER MACHINE ASKS** (`PAIR`, chunk 12b): this
    // program's own client does not connect when the guest says it listens.
    machine.pair = init.environ.getPosix("PAIR") != null;
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
    // **A VOLUME, IF ONE IS ATTACHED** (`VOLUME=<file>`, scsi.zig): a SCSI
    // disk on a virtio-scsi controller, as prod's chat data is.
    var volume: scsi.Scsi = .{ .image = &.{} };
    var volume_device: virtio.Device = undefined;
    var volume_drive: ?disk.Disk = null;
    // Out here, not in the block below: the disk keeps its path to write
    // back to at the run's end.
    var path_buf: [4096]u8 = undefined;
    if (init.environ.getPosix("VOLUME")) |name| {
        if (name.len >= path_buf.len) {
            std.debug.print("metal-vmm: the volume's name is too long: {s}\n", .{name});
            return 2;
        }
        @memcpy(path_buf[0..name.len], name);
        path_buf[name.len] = 0;
        volume_drive = disk.Disk.open(path_buf[0..name.len :0]) catch |e| {
            std.debug.print("metal-vmm: cannot open the volume {s}: {s}\n", .{ name, @errorName(e) });
            return 2;
        };
        volume = .{ .image = volume_drive.?.bytes, .dirty = volume_drive.?.dirty };
        volume_device = volume.device();
        machine.volume = &volume;
        if (!pc) machine.devices[3] = &volume_device;
    }
    // The same three, in slots of a PCI bus instead. The guest asks for each
    // kind by type, so the order is only the order a scan finds them in.
    var bus = pci.Bus{};
    if (pc) {
        machine.bus = &bus;
        if (disk_path != null) _ = bus.plug(1, &block_device, &machine.lapic);
        _ = bus.plug(2, &net_device, &machine.lapic);
        _ = bus.plug(3, &dice_device, &machine.lapic);
        if (machine.volume != null) _ = bus.plug(4, &volume_device, &machine.lapic);
    }

    // **THE FAULTS: A SEED'S, UNDER WHAT THE ENVIRONMENT SETS BY HAND**
    // (knobs.zig). A seeded run says what it chose, as the knobs that would
    // repeat it without the seed.
    var turned = if (count(init.environ, "FAULT_SEED")) |seed| knobs.Knobs.fromSeed(seed) else knobs.Knobs{};
    // A seed's volume faults, only with a volume, so no run without one moves.
    if (count(init.environ, "FAULT_SEED")) |seed| if (init.environ.getPosix("VOLUME") != null) turned.withVolume(seed);
    turned.overlay(init.environ);
    if (count(init.environ, "FAULT_SEED")) |seed| {
        var line: [1024]u8 = undefined;
        std.debug.print("metal-vmm: FAULT_SEED={d} is {s}\n", .{ seed, turned.format(&line) });
    }
    tellTheFaults(&card.line, &block.refusals, &card.peer.rough, &turned);
    // **THE LEASE THE PEER HANDS OUT** (`DHCP_LEASE_S`, a day unset): a
    // short one runs out within a run, and the run's end says whether the
    // guest renewed it.
    if (turned.get("DHCP_LEASE_S")) |text| {
        card.peer.lease_s = std.math.clamp(std.fmt.parseInt(u32, text, 10) catch 86_400, 1, std.math.maxInt(u32));
        card.peer.lease_named = true;
    }
    // **THE CALENDAR AS A KNOB** (`RTC_BOOTS_AT=unix`): the day the chip
    // boots on, from 1970 to 9999. Every run with it boots on that instant.
    if (turned.get("RTC_BOOTS_AT")) |text| {
        const at = std.fmt.parseInt(i64, text, 10) catch -1;
        if (at < 0 or at > clock.last_boot) {
            std.debug.print("metal-vmm: RTC_BOOTS_AT={s} is not a time from 1970 to 9999\n", .{text});
            return 2;
        }
        machine.rtc.from = at;
    }
    // **CLOCKS THAT DO NOT ANSWER** (QUEUE item 82): no RTC, an RTC stuck
    // mid-update, a PIT that never counts. Each reaches a refusal the guest
    // names and no other run can.
    if (turned.get("RTC_ABSENT")) |text| machine.rtc.absent = std.mem.eql(u8, text, "1");
    if (turned.get("RTC_STUCK")) |text| machine.rtc.stuck = std.mem.eql(u8, text, "1");
    if (turned.get("PIT_FROZEN")) |text| machine.pit.frozen = std.mem.eql(u8, text, "1");
    // **A WRITE CACHE, AND FLUSH OFFERED**, only when asked: offering the
    // feature changes what the guest negotiates, and check.sh holds the
    // default machine to QEMU's.
    var write_cache: cache.Cache = undefined;
    defer if (block.cache) |c| c.deinit();
    if (turned.get("DISK_CACHE")) |how| if (block.image.len > 0) {
        write_cache = .{ .gpa = std.heap.page_allocator, .image = block.image, .lies = std.mem.eql(u8, how, "lie") };
        block.cache = &write_cache;
        block_device.features_low |= virtio.feature_blk_flush;
        machine.write_cache = &write_cache;
    };
    // **THE VOLUME'S CACHE AND POWER** (`VOLUME_CACHE=1|lie`,
    // `VOLUME_CUT_AFTER=n`, scsi.zig): its WCE bit, said truly or not, and
    // the write the power goes after; and the SYNCHRONIZE CACHEs that fail
    // (`VOLUME_SYNC_FAIL=n`, `VOLUME_SYNC_FAIL_FOR=k`).
    var volume_cache: cache.Cache = undefined;
    defer if (volume.cache) |c| c.deinit();
    if (machine.volume != null) {
        if (turned.get("VOLUME_CACHE")) |how| {
            volume_cache = .{ .gpa = std.heap.page_allocator, .image = volume.image, .lies = std.mem.eql(u8, how, "lie") };
            if (turned.get("VOLUME_CACHE_KEEPS")) |text| if (std.fmt.parseInt(u64, text, 10) catch null) |k| if (k > 0) {
                volume_cache.keeps = k;
                volume_cache.keep_seed = count(init.environ, "FAULT_SEED") orelse 0;
            };
            volume.cache = &volume_cache;
        }
        if (turned.get("VOLUME_CUT_AT_EXIT")) |text| machine.cut_at_exit = std.mem.eql(u8, text, "1");
        if (turned.get("VOLUME_CUT_AFTER")) |text| if (std.fmt.parseInt(u64, text, 10) catch null) |n| if (n > 0) {
            volume.power.cut_after = n;
        };
        if (turned.get("VOLUME_ATTENTION_AT")) |text| if (std.fmt.parseInt(u64, text, 10) catch null) |n| if (n > 0) {
            volume.attention_at = n;
        };
        if (turned.get("VOLUME_RESET_AT")) |text| if (std.fmt.parseInt(u64, text, 10) catch null) |n| if (n > 0) {
            volume.reset_at = n;
        };
        if (turned.get("VOLUME_SECTOR")) |text| if (std.fmt.parseInt(u32, text, 10) catch null) |n| if (n > 0) {
            volume.sector_said = n;
        };
        if (turned.get("VOLUME_MODE_PAGES")) |text| volume.no_mode_pages = std.mem.eql(u8, text, "none");
        if (turned.get("VOLUME_MAX_TRANSFER")) |text| if (std.fmt.parseInt(u32, text, 10) catch null) |n| {
            volume.max_transfer = n;
        };
        if (turned.get("VOLUME_WCE_FIXED")) |text| volume.wce_fixed = if (std.mem.eql(u8, text, "1")) .refuses else if (std.mem.eql(u8, text, "ignore")) .ignores else .no;
        if (turned.get("VOLUME_GONE_AT")) |text| if (std.fmt.parseInt(u64, text, 10) catch null) |n| if (n > 0) {
            volume.gone_at = n;
        };
        if (turned.get("VOLUME_READ_ONLY_AT")) |text| if (std.fmt.parseInt(u64, text, 10) catch null) |n| if (n > 0) {
            volume.read_only_at = n;
        };
        if (turned.get("VOLUME_READ_ONLY_AT_WRITE")) |text| if (std.fmt.parseInt(u64, text, 10) catch null) |n| if (n > 0) {
            volume.read_only_at_write = n;
        };
        if (turned.get("VOLUME_SHORT_AT")) |text| if (std.fmt.parseInt(u64, text, 10) catch null) |n| if (n > 0) {
            volume.short_at = n;
        };
        if (turned.get("VOLUME_SYNC_US")) |text| if (std.fmt.parseInt(u64, text, 10) catch null) |us| {
            volume.sync_latency_ns = us * std.time.ns_per_us;
        };
        if (turned.get("VOLUME_LATENCY_US")) |text| if (std.fmt.parseInt(u64, text, 10) catch null) |us| {
            volume.latency_ns = us * std.time.ns_per_us;
        };
        if (turned.get("VOLUME_SYNC_FAIL")) |text| if (std.fmt.parseInt(u64, text, 10) catch null) |n| if (n > 0) {
            volume.sync_fail_at = n;
        };
        if (turned.get("VOLUME_SYNC_FAIL_FOR")) |text| if (std.fmt.parseInt(u64, text, 10) catch null) |n| if (n > 0) {
            volume.sync_fail_for = n;
        };
    }
    if (count(init.environ, "PATIENCE_S")) |seconds| machine.patience_ns = seconds * std.time.ns_per_s;
    if (init.environ.getPosix("WIRE_SILENT_S")) |text| card.line.silent = settings.silentOf(text) orelse {
        std.debug.print("metal-vmm: WIRE_SILENT_S={s}: not a-b, seconds, a before b (KNOBS.md)\n", .{text});
        return 2;
    };
    if (count(init.environ, "GUEST_S")) |seconds| machine.watch_ns = seconds * std.time.ns_per_s;
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
        // Which run the lines that follow are, for a report over many (the
        // SDK's `tools/report.py`): its seed, and the knobs that repeat it.
        var knob_text: [1024]u8 = undefined;
        var run_buf: [1200]u8 = undefined;
        if (coverage.runLine(&run_buf, count(init.environ, "FAULT_SEED"), turned.format(&knob_text))) |run| {
            SerialOut.jsonl(.{ .jsonl_fd = machine.coverage_fd }, run);
        } else |_| {}
    }

    // **WHAT THE PEER ASKS FOR.** A path is enough for a probe; a server with
    // a login and a chat wants a whole request, cookie and body and all, so
    // `PEER_REQUEST=<file>` sends those bytes exactly as they are.
    //
    // **AND HOW MANY ASK** (peer.zig, `Plan`): `PEER_CLIENTS=n` clients, a
    // gap apart (`PEER_CLIENT_GAP_US`; with `PEER_IN_TURN=1`, a gap after
    // the one before was answered), each asking `PEER_ASKS=k` times on
    // its own connection. `PEER_REQUEST=a,b,...` names a file for each
    // client; a client past the list asks the last one's.
    const plan = &card.peer.plan;
    if (count(init.environ, "PEER_CLIENTS")) |n| plan.clients = @intCast(std.math.clamp(n, 1, wire.max_clients));
    if (count(init.environ, "PEER_ASKS")) |n| plan.asks = @intCast(std.math.clamp(n, 1, 1000));
    if (count(init.environ, "PEER_CLIENT_GAP_US")) |us| plan.gap_ns = us * std.time.ns_per_us;
    if (init.environ.getPosix("PEER_IN_TURN")) |v| plan.in_turn = std.mem.eql(u8, v, "1");
    if (init.environ.getPosix("PEER_REQUEST")) |files| {
        var each = std.mem.tokenizeScalar(u8, files, ',');
        while (each.next()) |from| {
            if (plan.named == wire.max_clients) break;
            var name: [4096]u8 = undefined;
            if (from.len >= name.len) {
                std.debug.print("metal-vmm: a request file's name is too long: {s}\n", .{from});
                return 2;
            }
            @memcpy(name[0..from.len], from);
            name[from.len] = 0;
            plan.requests[plan.named] = readAll(name[0..from.len :0], &client_files.request_bufs[plan.named]) catch |e| {
                switch (e) {
                    error.TooLarge => std.debug.print("metal-vmm: the request in {s} is larger than {d} bytes, the most a client sends\n", .{ from, request_max }),
                    error.Empty => std.debug.print("metal-vmm: the request in {s} is empty\n", .{from}),
                    error.Unreadable => std.debug.print("metal-vmm: cannot read the request in {s}\n", .{from}),
                }
                return 2;
            };
            plan.named += 1;
        }
        if (plan.named > 0) machine.request = plan.requests[0];
    } else if (fetch) |target| {
        // A client that asks again keeps the connection; one that asks once
        // says it will close, as curl's judge does.
        const close = if (plan.asks > 1) "" else "Connection: close\r\n";
        machine.request = std.fmt.bufPrint(&client_files.request_bufs[0], "GET {s} HTTP/1.1\r\nHost: 10.0.2.15\r\n{s}\r\n", .{ target, close }) catch null;
    }

    // **A PAIR** (`PAIR=<client kernel>`, docs/TWO-KERNELS.md §4; QUEUE
    // 225, chunk 12b): the server forks and execs the client, joined by a
    // socket, and the two take turns. The client, before its guest runs,
    // waits for the server's first TURN, which says when it powers on.
    var link: pair.Link = undefined;
    var turn_hooks: turn.Hooks = undefined;
    var client_pid: ?linux.pid_t = null;
    if (!machine.pair and init.environ.getPosix("WIRE_TRACE") != null) {
        std.debug.print("metal-vmm: WIRE_TRACE traces the frames that cross a pair: it needs PAIR\n", .{});
        return 2;
    }
    if (machine.pair) {
        const lookahead_ns = pair.startPair(init.environ, init.environ.block.view().slice) orelse return 2;
        if (init.environ.getPosix("PAIR_FD")) |text| {
            if (side != 1) {
                std.debug.print("metal-vmm: the pair's client is side 1 (SIDE=1)\n", .{});
                return 2;
            }
            const fd = std.fmt.parseInt(linux.fd_t, text, 10) catch {
                std.debug.print("metal-vmm: PAIR_FD={s} is not a socket\n", .{text});
                return 2;
            };
            link = .init(fd, 1, lookahead_ns, .running);
        } else {
            if (side != 0) {
                std.debug.print("metal-vmm: the pair's server is side 0: SIDE is the client's, set by PAIR\n", .{});
                return 2;
            }
            const spawned = pair.spawnClient(init.environ, &complaint_buf) orelse return 2;
            link = .init(spawned.fd, 0, lookahead_ns, .off);
            client_pid = spawned.pid;
        }
        link.bind();
        if (init.environ.getPosix("WIRE_TRACE")) |v| if (std.mem.eql(u8, v, "1")) link.traceOn();
        card.pair = &link.pair;
        turn_hooks = link.hooks();
        machine.turns = &turn_hooks;
        if (side == 1) {
            const d = link.awaitStart() catch |e| {
                std.debug.print("metal-vmm: the pair's client never started: {s}\n", .{@errorName(e)});
                link.finish(0) catch {};
                return 2;
            };
            machine.time.ns = @intCast(d);
        }
    }

    // **A RUN THAT ENDS BADLY STILL SAYS WHAT WAS DONE TO IT.** The faults
    // below are the first thing anybody reads after a guest gets stuck, so
    // they are reported before the error goes anywhere.
    const code = serve(vcpu, page, &machine, .{ .lo = loaded.text_lo, .hi = loaded.text_hi }) catch |e| {
        cutAtExit(&machine);
        reportRun(&card, &block, machine.time.ns);
        reportVolume(&machine);
        reportFired(&card, &block, &machine);
        reports.cost(&machine, &card, &block);
        reportCoverage(&machine);
        // **AN IDLE END IS A SERVER'S NORMAL END**: a guest serving more than
        // one request always ends this way, so its disk keeps what it wrote
        // and it says what the client got, as any end does. The error, and so
        // the exit code, still says idle.
        if (keepsWrites(e)) if (drive) |*on_disk| {
            _ = on_disk.writeBack() catch |w| {
                std.debug.print("metal-vmm: the disk would not take the run's writes: {s}\n", .{@errorName(w)});
                return 1;
            };
        };
        if (keepsWrites(e)) if (volume_drive) |*on_disk| {
            _ = on_disk.writeBack() catch |w| {
                std.debug.print("metal-vmm: the volume would not take the run's writes: {s}\n", .{@errorName(w)});
                return 1;
            };
        };
        if (keepsWrites(e) and fetch != null) theClient(init.environ, &card.peer);
        // A pair's server ending idle or watched is its normal end: the
        // verdict is the client's.
        if (machine.turns != null) {
            const client = pair.endPair(&link, machine.time.ns, client_pid);
            if (keepsWrites(e) and side == 0) return client;
        }
        // Watched as long as asked is no verdict on the guest: the judge
        // reads what it printed.
        if (e == error.GuestWatched) return 0;
        return e;
    };
    // **WHAT THE WIRE DID, IF IT WAS ASKED TO DO ANYTHING**, on the error
    // stream: a run with a perfect wire says nothing, so the probes' output
    // stays comparable with QEMU's.
    cutAtExit(&machine);
    reportRun(&card, &block, machine.time.ns);
    reportVolume(&machine);
    reportFired(&card, &block, &machine);
    if (pc) reportRest(&machine);
    reports.cost(&machine, &card, &block);
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
    if (volume_drive) |*on_disk| {
        _ = on_disk.writeBack() catch |e| {
            std.debug.print("metal-vmm: the volume would not take the run's writes: {s}\n", .{@errorName(e)});
            return 1;
        };
    }
    if (fetch != null) theClient(init.environ, &card.peer);
    if (machine.turns != null) return pair.combined(code, pair.endPair(&link, machine.time.ns, client_pid));
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
    _ = @import("scsi.zig");
    _ = @import("mangle.zig");
    _ = @import("net.zig");
    _ = @import("peer.zig");
    _ = @import("apic.zig");
    _ = @import("pci.zig");
    _ = @import("virtio_pci.zig");
    _ = @import("msix.zig");
    _ = @import("coverage.zig");
    _ = @import("knobs.zig");
    _ = @import("turn.zig");
    _ = @import("pair.zig");
    _ = @import("fuzz.zig");
    _ = @import("determinism.zig");
    _ = @import("snapshot.zig");
    _ = @import("cost.zig");
    _ = @import("cache.zig");
    _ = @import("settings.zig");
    _ = @import("reports.zig");
    _ = @import("loader.zig");
    _ = @import("processor.zig");
    _ = @import("halt.zig");
    _ = @import("checked.zig");
    _ = @import("boot.zig");
    _ = @import("machine.zig");
    _ = @import("serve.zig");
    _ = @import("client_files.zig");
}
