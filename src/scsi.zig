//! **A DIGITALOCEAN VOLUME** (`VOLUME=<file>`, QUEUE.md item 53): a SCSI
//! disk behind a virtio-scsi controller, which is how prod reaches chat's
//! data (gopher-metal `scsi.zig`). The boot disk stays virtio-blk; this is
//! the second disk, and the one whose writes matter.
//!
//! **THE SMALLEST CONTROLLER GOPHER-METAL'S DRIVER ACCEPTS.** Three queues
//! (control, event, requests), of which only the third is ever used; the
//! default CDB and sense sizes, which the driver insists on; one disk, at
//! target 0, LUN 0. A request is a 51-byte header the device reads (the
//! LUN, a tag, and a 32-byte CDB), any data it reads, then a 108-byte
//! response it writes (sense length, residual, status, the device's own
//! outcome, sense data), then any data it writes (virtio 1.2 §5.6.6).
//!
//! **SIX COMMANDS AND TEST UNIT READY**: INQUIRY, READ CAPACITY(10), MODE
//! SENSE(10) for the caching page, READ(10), WRITE(10), SYNCHRONIZE
//! CACHE(10) (SPC-4, SBC-3). Anything else is ILLEGAL REQUEST. A target
//! with no disk is BAD_TARGET, as QEMU answers, and the first command after
//! power-on but INQUIRY is UNIT ATTENTION, as a real disk's is: gopher-metal
//! sends it again.
//!
//! **THE WRITE CACHE** (`VOLUME_CACHE`, cache.zig), with `DISK_CACHE`'s
//! semantics. SCSI negotiates nothing: a disk says in MODE SENSE's caching
//! page (WCE) whether it answers writes from a cache, and only SYNCHRONIZE
//! CACHE makes them durable. `VOLUME_CACHE=1` is that disk, saying so.
//! `VOLUME_CACHE=lie` holds writes and says WCE=0, as a disk that lies
//! about its cache does: a driver that believes it never synchronizes.
//! Unset, the disk writes through and says so. A driver may turn the cache
//! off with MODE SELECT (WCE=0), unless `VOLUME_WCE_FIXED=1` makes it a
//! disk that refuses. Nothing here reads a clock.

const std = @import("std");
const virtio = @import("virtio.zig");
const cache_mod = @import("cache.zig");
const faults = @import("faults.zig");
const disk = @import("disk.zig");

const Desc = virtio.Desc;
const Device = virtio.Device;
const inside = virtio.inside;
const readInt = virtio.readInt;
const writeInt = virtio.writeInt;

pub const sector_bytes: u64 = 512;

/// The sizes the driver insists on (virtio 1.2 §5.6.4's defaults), and the
/// header and response at those sizes.
pub const cdb_size = 32;
pub const sense_size = 96;
pub const request_len = 19 + cdb_size;
pub const response_len = 12 + sense_size;

pub const request_queue: u32 = 2;

/// The device's outcome (§5.6.6.1) and the disk's SCSI status.
pub const response_ok: u8 = 0;
pub const response_bad_target: u8 = 3;
pub const status_good: u8 = 0;
pub const status_check_condition: u8 = 2;

/// Sense keys, and the additional sense codes that say why (SPC-4 §4.5.6).
pub const key_medium_error: u8 = 3;
pub const key_illegal_request: u8 = 5;
pub const key_data_protect: u8 = 7;
pub const key_unit_attention: u8 = 6;
const asc_write_error: u8 = 0x0C;
const asc_invalid_opcode: u8 = 0x20;
/// WRITE PROTECTED.
pub const asc_write_protected: u8 = 0x27;
const asc_lba_out_of_range: u8 = 0x21;
const asc_invalid_field: u8 = 0x24;
const asc_invalid_parameter: u8 = 0x26;
const asc_lun_not_supported: u8 = 0x25;
const asc_power_on: u8 = 0x29;
/// With ASCQ 09h: CAPACITY DATA HAS CHANGED.
pub const asc_capacity_changed: u8 = 0x2A;
const asc_saving_not_supported: u8 = 0x39;

pub const op_test_unit_ready: u8 = 0x00;
pub const op_inquiry: u8 = 0x12;
pub const op_read_capacity: u8 = 0x25;
pub const op_read: u8 = 0x28;
pub const op_write: u8 = 0x2A;
pub const op_synchronize: u8 = 0x35;
pub const op_mode_sense: u8 = 0x5A;
pub const op_mode_select: u8 = 0x55;

const page_caching: u8 = 0x08;
const page_all: u8 = 0x3F;

pub const Scsi = struct {
    /// The volume, mapped, as `virtio.Block`'s image is.
    image: []u8,
    /// One bit per sector written, for disk.zig to write back.
    dirty: ?[]u8 = null,
    /// **A WRITE CACHE** (`VOLUME_CACHE`), or none: write-through.
    cache: ?*cache_mod.Cache = null,
    /// **THE POWER** (`VOLUME_CUT_AFTER`): only its cut is used here.
    power: faults.Drive = .{},
    /// **A CACHE THAT CANNOT REACH ITS MEDIA** (`VOLUME_SYNC_FAIL=n`,
    /// `VOLUME_SYNC_FAIL_FOR=k`): the nth SYNCHRONIZE CACHE, and the k-1
    /// after it, answer MEDIUM ERROR, and what they were to keep stays held.
    sync_fail_at: ?u64 = null,
    sync_fail_for: u64 = 1,
    sync_failed: u64 = 0,
    /// **A VOLUME THAT TAKES TIME** (`VOLUME_LATENCY_US`): each command
    /// answered costs the guest this long. gopher-metal waits on a command
    /// by spinning on the used ring, which no exit interrupts, so a
    /// completion held back would never be seen; instead it is answered at
    /// once and the machine's clock moves on by the latency before the
    /// guest runs again, which is what its spin would have counted.
    /// `owed_ns` is what the run loop has yet to add; `waited_ns` all of it.
    latency_ns: u64 = 0,
    owed_ns: u64 = 0,
    waited_ns: u64 = 0,
    /// **A FLUSH THAT COSTS MORE** (`VOLUME_SYNC_US`): what each
    /// SYNCHRONIZE CACHE costs on top of `latency_ns`, since on network
    /// storage it is the slow command. `sync_waited_ns` is its share.
    sync_latency_ns: u64 = 0,
    sync_waited_ns: u64 = 0,
    /// UNIT ATTENTION, owed to the first command but INQUIRY.
    /// Pending: the additional sense code it is told with, POWER ON first.
    attention: ?u8 = asc_power_on,
    /// **ONE MORE, IN THE MIDDLE OF A RUN** (`VOLUME_ATTENTION_AT=n`): from
    /// the nth command, CAPACITY DATA HAS CHANGED is pending, as a volume
    /// resized under a droplet tells it; the command it is told on is not
    /// performed. `commands` counts every command; `attentions` those told.
    attention_at: ?u64 = null,
    /// **A VOLUME THAT GOES AWAY** (`VOLUME_GONE_AT=n`): from the nth
    /// command the controller answers BAD_TARGET, as one whose DO volume
    /// was detached under it does. `gone_answered` counts them.
    gone_at: ?u64 = null,
    gone_answered: u64 = 0,
    /// **A VOLUME THAT TURNS READ-ONLY** (`VOLUME_READ_ONLY_AT=n`): from
    /// the nth command MODE SENSE says WP and every WRITE is DATA PROTECT,
    /// as a DO volume the host has made read-only after an I/O error.
    /// Reads and SYNCHRONIZE CACHE still answer. `protected` counts the
    /// writes refused.
    read_only_at: ?u64 = null,
    /// **A TRANSFER THAT MOVES HALF** (`VOLUME_SHORT_AT=n`): the nth READ
    /// or WRITE moves the first half of its bytes and answers GOOD with the
    /// rest as its residual (virtio 1.2 §5.6.6.1), a legal underrun. A
    /// driver that does not read the residual takes it as whole: a read's
    /// buffer keeps its old bytes past the half, a write's are never written.
    short_at: ?u64 = null,
    transfers: u64 = 0,
    shortened: u64 = 0,
    /// **WHAT READ CAPACITY SAYS A SECTOR IS** (`VOLUME_SECTOR=n`): 512
    /// unless the run names another, such as 4096. Only the answer changes:
    /// a driver that takes 512 only must refuse the disk at bring-up, before
    /// any transfer, which is the refusal this reaches.
    sector_said: u32 = sector_bytes,
    /// **MODE SENSE WITH NO PAGES** (`VOLUME_MODE_PAGES=none`): the header
    /// alone, as a disk with no caching page answers.
    no_mode_pages: bool = false,
    /// **TURNED OFF BY MODE SELECT**: the driver set the caching page's WCE
    /// to 0, and writes from then on go through, unless the cache lies,
    /// which holds them whatever it was told. What it held before stays held
    /// until a SYNCHRONIZE: a disk may drain it then or not (SBC-3 leaves it
    /// to the disk), so a driver that turns the cache off and needs what it
    /// wrote before must still synchronize.
    write_through: bool = false,
    /// **A CACHE THAT CANNOT BE TURNED OFF** (`VOLUME_WCE_FIXED=1`): the
    /// changeable values say WCE is not changeable, and a MODE SELECT that
    /// changes it is refused, INVALID FIELD IN PARAMETER LIST.
    wce_fixed: bool = false,
    mode_selects: u64 = 0,
    protected: u64 = 0,
    commands: u64 = 0,
    attentions: u64 = 0,
    reads: u64 = 0,
    writes: u64 = 0,
    synchronizes: u64 = 0,
    mode_senses: u64 = 0,
    /// Commands answered CHECK CONDITION, UNIT ATTENTION aside.
    refused: u64 = 0,

    pub fn device(self: *Scsi) Device {
        var d = Device{ .id = virtio.device_id_scsi, .context = self, .notified = notified, .queue_count = 3 };
        // struct virtio_scsi_config (§5.6.4), QEMU's numbers.
        const c = &d.config;
        std.mem.writeInt(u32, c[0..4], 1, .little); // num_queues: request queues
        std.mem.writeInt(u32, c[4..8], 126, .little); // seg_max
        std.mem.writeInt(u32, c[8..12], 0xFFFF, .little); // max_sectors
        std.mem.writeInt(u32, c[12..16], 128, .little); // cmd_per_lun
        std.mem.writeInt(u32, c[16..20], 16, .little); // event_info_size
        std.mem.writeInt(u32, c[20..24], sense_size, .little);
        std.mem.writeInt(u32, c[24..28], cdb_size, .little);
        std.mem.writeInt(u16, c[28..30], 0, .little); // max_channel
        std.mem.writeInt(u16, c[30..32], 255, .little); // max_target
        std.mem.writeInt(u32, c[32..36], 16383, .little); // max_lun
        return d;
    }

    fn readOnly(self: *const Scsi) bool {
        const n = self.read_only_at orelse return false;
        return self.commands >= n;
    }

    /// What the caching page's WCE bit says: a cache, unless it lies.
    pub fn saysWce(self: *const Scsi) bool {
        const c = self.cache orelse return false;
        return !c.lies and !self.write_through;
    }

    /// Whether a write now is held in the cache: by one that lies, always.
    fn holding(self: *const Scsi) ?*cache_mod.Cache {
        const c = self.cache orelse return null;
        return if (c.lies or !self.write_through) c else null;
    }

    fn notified(context: *anyopaque, d: *Device, ram: []u8, queue: u32) void {
        const self: *Scsi = @ptrCast(@alignCast(context));
        // The control and event queues: the driver sends nothing on the one,
        // and an event buffer is held for an event that never comes.
        if (queue != request_queue) return;
        var links: [8]Desc = undefined;
        var left = d.budget(queue);
        while (left > 0) : (left -= 1) {
            if (self.power.cut != null) return;
            const chain = d.take(ram, queue, &links) orelse break;
            const written = self.serve(ram, chain.links);
            self.owed_ns += self.latency_ns;
            self.waited_ns += self.latency_ns;
            // The command the power went out in is never answered.
            if (self.power.cut != null) return;
            d.complete(ram, queue, chain.head, written);
        }
    }

    const Answer = struct {
        status: u8 = status_good,
        key: u8 = 0,
        asc: u8 = 0,
        ascq: u8 = 0,
        /// Bytes of data written to the driver, after the response.
        data: u32 = 0,
        /// Bytes of the driver's data taken: a WRITE's.
        taken: u32 = 0,
        response: u8 = response_ok,
    };

    fn check(self: *Scsi, key: u8, asc: u8) Answer {
        if (key != key_unit_attention) self.refused += 1;
        return .{ .status = status_check_condition, .key = key, .asc = asc };
    }

    /// One request: the device-readable descriptors (the header, then any
    /// data out), then the device-writable (the response, then any data
    /// in), one descriptor each, as gopher-metal sends them. A chain of any
    /// other shape is not answered, as `virtio.Block` answers none.
    pub fn serve(self: *Scsi, ram: []u8, chain: []const Desc) u32 {
        var readable: [2]Desc = undefined;
        var writable: [2]Desc = undefined;
        var r: usize = 0;
        var w: usize = 0;
        for (chain) |one| {
            if (one.flags & Desc.write_flag == 0) {
                if (w > 0 or r == readable.len) return 0;
                readable[r] = one;
                r += 1;
            } else {
                if (w == writable.len) return 0;
                writable[w] = one;
                w += 1;
            }
        }
        if (r == 0 or w == 0 or (r == 2 and w == 2)) return 0;
        const head = readable[0];
        const resp = writable[0];
        if (head.len < request_len or resp.len < response_len) return 0;
        if (!inside(ram, head.addr, request_len) or !inside(ram, resp.addr, response_len)) return 0;
        const out: ?[]u8 = if (r == 2) virtio.buffer(ram, readable[1]) else null;
        const in: ?[]u8 = if (w == 2) virtio.buffer(ram, writable[1]) else null;

        const lun = ram[@intCast(head.addr)..][0..8];
        const cdb = ram[@intCast(head.addr + 19)..][0..cdb_size];
        const a = self.command(lun, cdb, out, in);

        const at: usize = @intCast(resp.addr);
        @memset(ram[at..][0..response_len], 0);
        const sense_len: u32 = if (a.status == status_check_condition) 18 else 0;
        const expected: u32 = if (in) |b| @intCast(b.len) else if (out) |b| @intCast(b.len) else 0;
        std.mem.writeInt(u32, ram[at..][0..4], sense_len, .little);
        // **THE RESIDUAL IS WHAT WAS NOT MOVED** (virtio 1.2 §5.6.6.1): of
        // a read, the bytes not written to the driver; of a write, those not
        // taken from it. A write once reported all of its bytes as not
        // taken, and a driver that read the residual failed every one.
        const moved: u32 = if (in != null) a.data else a.taken;
        std.mem.writeInt(u32, ram[at + 4 ..][0..4], expected - @min(expected, moved), .little);
        ram[at + 10] = a.status;
        ram[at + 11] = a.response;
        if (sense_len > 0) {
            const s = ram[at + 12 ..][0..18];
            s[0] = 0x70; // current, fixed format
            s[2] = a.key;
            s[7] = 10; // additional length
            s[12] = a.asc;
            s[13] = a.ascq;
        }
        return response_len + a.data;
    }

    fn command(self: *Scsi, lun: *const [8]u8, cdb: *const [cdb_size]u8, out: ?[]u8, in: ?[]u8) Answer {
        // Target 0 is the only one; a LUN other than 0 there has no disk.
        if (lun[0] != 1 or lun[1] != 0) return .{ .response = response_bad_target };
        const lun_n = (@as(u16, lun[2] & 0x3F) << 8) | lun[3];
        self.commands += 1;
        if (self.gone_at) |n| if (self.commands >= n) {
            self.gone_answered += 1;
            return .{ .response = response_bad_target };
        };
        if (self.read_only_at) |n| if (self.commands >= n and cdb[0] == op_write) {
            self.protected += 1;
            return self.check(key_data_protect, asc_write_protected);
        };
        if (self.attention_at) |n| if (self.commands == n) {
            self.attention = asc_capacity_changed;
        };
        const op = cdb[0];
        if (op == op_inquiry) return self.inquiry(cdb, in, lun_n == 0);
        if (lun_n != 0) return self.check(key_illegal_request, asc_lun_not_supported);
        if (self.attention) |asc| {
            self.attention = null;
            self.attentions += 1;
            var a = self.check(key_unit_attention, asc);
            if (asc == asc_capacity_changed) a.ascq = 0x09;
            return a;
        }
        return switch (op) {
            op_test_unit_ready => .{},
            op_read_capacity => self.capacity(in),
            op_mode_sense => self.modeSense(cdb, in),
            op_mode_select => self.modeSelect(cdb, out),
            op_read, op_write => self.transfer(cdb, op == op_write, out, in),
            op_synchronize => self.synchronize(),
            else => self.check(key_illegal_request, asc_invalid_opcode),
        };
    }

    fn synchronize(self: *Scsi) Answer {
        self.synchronizes += 1;
        self.owed_ns += self.sync_latency_ns;
        self.waited_ns += self.sync_latency_ns;
        self.sync_waited_ns += self.sync_latency_ns;
        if (self.sync_fail_at) |at| if (self.synchronizes >= at and self.synchronizes - at < self.sync_fail_for) {
            self.sync_failed += 1;
            return self.check(key_medium_error, asc_write_error);
        };
        if (self.cache) |c| c.flush();
        return .{};
    }

    fn give(in: ?[]u8, bytes: []const u8, allocated: usize) u32 {
        const to = in orelse return 0;
        const n = @min(bytes.len, allocated, to.len);
        @memcpy(to[0..n], bytes[0..n]);
        return @intCast(n);
    }

    fn inquiry(self: *Scsi, cdb: *const [cdb_size]u8, in: ?[]u8, here: bool) Answer {
        if (cdb[1] & 1 != 0) return self.check(key_illegal_request, asc_invalid_field); // no VPD pages
        var data: [36]u8 = @splat(' ');
        // A disk, or a LUN with nothing connected (qualifier 3, type 1Fh).
        data[0] = if (here) 0x00 else 0x7F;
        data[1] = 0;
        data[2] = 5; // SPC-3
        data[3] = 2; // response data format
        data[4] = 31; // what follows
        data[5] = 0;
        data[6] = 0;
        data[7] = 0;
        @memcpy(data[8..16], "METALVMM");
        @memcpy(data[16..22], "VOLUME");
        @memcpy(data[32..36], "0001");
        const allocated = std.mem.readInt(u16, cdb[3..5], .big);
        return .{ .data = give(in, &data, allocated) };
    }

    fn capacity(self: *Scsi, in: ?[]u8) Answer {
        // `VOLUME_SECTOR`: the size said, counted in its own sectors.
        const sectors = self.image.len / self.sector_said;
        var data: [8]u8 = undefined;
        const last: u32 = if (sectors == 0) 0 else @intCast(@min(sectors - 1, 0xFFFF_FFFF));
        std.mem.writeInt(u32, data[0..4], last, .big);
        std.mem.writeInt(u32, data[4..8], self.sector_said, .big);
        return .{ .data = give(in, &data, data.len) };
    }

    /// MODE SENSE(10): the caching page (SBC-3 §6.5.5), with no block
    /// descriptors, whose WCE bit is the cache's.
    fn modeSense(self: *Scsi, cdb: *const [cdb_size]u8, in: ?[]u8) Answer {
        self.mode_senses += 1;
        const control = cdb[2] >> 6;
        const page = cdb[2] & 0x3F;
        if (page != page_caching and page != page_all) return self.check(key_illegal_request, asc_invalid_field);
        if (control == 3) return self.check(key_illegal_request, asc_saving_not_supported);
        var data: [8 + 20]u8 = @splat(0);
        std.mem.writeInt(u16, data[0..2], data.len - 2, .big); // mode data length
        // The device-specific parameter's WP bit (SBC-3 §6.4.1).
        if (self.readOnly()) data[3] = 0x80;
        if (self.no_mode_pages) {
            // `VOLUME_MODE_PAGES=none`: the header alone, no page after it.
            std.mem.writeInt(u16, data[0..2], 6, .big);
            const allocated_none = std.mem.readInt(u16, cdb[7..9], .big);
            return .{ .data = give(in, data[0..8], allocated_none) };
        }
        data[8] = page_caching;
        data[9] = 18; // page length
        // Current values say the cache as it is now, default ones as it was
        // at power-on, and changeable ones that WCE may be set, unless
        // `VOLUME_WCE_FIXED`. A disk with no cache says WCE=0 in every one.
        switch (control) {
            0 => if (self.saysWce()) {
                data[10] = 0x04;
            },
            1 => if (self.cache != null and !self.wce_fixed) {
                data[10] = 0x04;
            },
            else => if (self.cache) |c| if (!c.lies) {
                data[10] = 0x04;
            },
        }
        const allocated = std.mem.readInt(u16, cdb[7..9], .big);
        return .{ .data = give(in, &data, allocated) };
    }

    /// MODE SELECT(10) (SPC-4 §6.13): the caching page, PF set and SP
    /// clear, with no block descriptors. Only WCE may change; every other
    /// field must be what MODE SENSE says. Setting WCE=0 makes later writes
    /// go through (`write_through`), WCE=1 puts the cache back.
    fn modeSelect(self: *Scsi, cdb: *const [cdb_size]u8, out: ?[]u8) Answer {
        self.mode_selects += 1;
        if (cdb[1] & 0x10 == 0) return self.check(key_illegal_request, asc_invalid_field); // PF
        if (cdb[1] & 0x01 != 0) return self.check(key_illegal_request, asc_saving_not_supported); // SP
        const len = std.mem.readInt(u16, cdb[7..9], .big);
        if (len == 0) return .{};
        const from = out orelse return self.check(key_illegal_request, asc_invalid_field);
        if (from.len < len or len < 8 + 20) return self.check(key_illegal_request, asc_invalid_parameter);
        const list = from[0..len];
        // The header: mode data length is reserved, no block descriptors.
        if (list[0] != 0 or list[1] != 0 or std.mem.readInt(u16, list[6..8], .big) != 0)
            return self.check(key_illegal_request, asc_invalid_parameter);
        const page = list[8..][0..20];
        if (page[0] & 0x3F != page_caching or page[1] != 18) return self.check(key_illegal_request, asc_invalid_parameter);
        // Every field but WCE as MODE SENSE gives it: zero.
        if (page[2] & ~@as(u8, 0x04) != 0) return self.check(key_illegal_request, asc_invalid_parameter);
        for (page[3..]) |b| if (b != 0) return self.check(key_illegal_request, asc_invalid_parameter);
        const wce = page[2] & 0x04 != 0;
        if (self.cache) |c| {
            if (wce != self.saysWce()) {
                if (self.wce_fixed or c.lies) return self.check(key_illegal_request, asc_invalid_parameter);
                self.write_through = !wce;
            }
        } else if (wce) return self.check(key_illegal_request, asc_invalid_parameter);
        return .{ .taken = len };
    }

    fn transfer(self: *Scsi, cdb: *const [cdb_size]u8, writing: bool, out: ?[]u8, in: ?[]u8) Answer {
        const lba: u64 = std.mem.readInt(u32, cdb[2..6], .big);
        const n: u64 = std.mem.readInt(u16, cdb[7..9], .big);
        if (lba + n > self.image.len / sector_bytes) return self.check(key_illegal_request, asc_lba_out_of_range);
        if (n == 0) return .{};
        const whole_bytes = n * sector_bytes;
        const at: usize = @intCast(lba * sector_bytes);
        self.transfers += 1;
        const short = if (self.short_at) |k| self.transfers == k else false;
        if (short) self.shortened += 1;
        // A short one moves the first half, and says the rest as its residual.
        const bytes = if (short) whole_bytes / 2 else whole_bytes;
        if (!writing) {
            const to = in orelse return self.check(key_illegal_request, asc_invalid_field);
            if (to.len < whole_bytes) return self.check(key_illegal_request, asc_invalid_field);
            @memcpy(to[0..@intCast(bytes)], self.image[at..][0..@intCast(bytes)]);
            self.reads += 1;
            return .{ .data = @intCast(bytes) };
        }
        const from = out orelse return self.check(key_illegal_request, asc_invalid_field);
        if (from.len < whole_bytes) return self.check(key_illegal_request, asc_invalid_field);
        if (short) {
            // Half of it, a byte copy: no sector of it is said to have landed
            // whole, and the power and the cache are not asked.
            @memcpy(self.image[at..][0..@intCast(bytes)], from[0..@intCast(bytes)]);
            self.writes += 1;
            return .{ .taken = @intCast(bytes) };
        }
        // As much as lands before the power goes, which is all of it unless
        // this is the write it goes in.
        const landed = self.power.lands(lba, n);
        if (self.holding()) |c| _ = c.wrote(lba, landed);
        const len: usize = @intCast(landed * sector_bytes);
        @memcpy(self.image[at..][0..len], from[0..len]);
        if (self.dirty) |bits| disk.mark(bits, lba, landed);
        self.writes += 1;
        return .{ .taken = @intCast(bytes) };
    }

    /// One line for the run's end, in `buf`.
    pub fn line(self: *const Scsi, buf: []u8) []const u8 {
        const mode = if (self.cache) |c|
            (if (c.lies) "a write cache that says it writes through (VOLUME_CACHE=lie)" else if (self.write_through) "a write cache, turned off by MODE SELECT" else "a write cache, said in MODE SENSE")
        else
            "write-through";
        const lost: u64 = if (self.cache) |c| c.lost else 0;
        var told_buf: [64]u8 = undefined;
        const told = if (self.attention_at) |n|
            std.fmt.bufPrint(&told_buf, "; UNIT ATTENTION at command {d} {s}", .{ n, if (self.commands >= n and self.attention == null) "told" else "never told" }) catch ""
        else
            "";
        var keeps_buf: [96]u8 = undefined;
        const keeps = if (self.cache) |c| (if (c.keeps) |k|
            std.fmt.bufPrint(&keeps_buf, "; {d} sectors had reached the media on their own (VOLUME_CACHE_KEEPS={d})", .{ c.kept, k }) catch ""
        else
            "") else "";
        var gone_buf: [96]u8 = undefined;
        const gone = if (self.gone_at) |n|
            std.fmt.bufPrint(&gone_buf, "; gone from command {d}, {d} commands answered BAD_TARGET", .{ n, self.gone_answered }) catch ""
        else
            "";
        var ro_buf: [96]u8 = undefined;
        const ro = if (self.read_only_at) |n|
            std.fmt.bufPrint(&ro_buf, "; read-only from command {d}, {d} writes refused", .{ n, self.protected }) catch ""
        else
            "";
        var short_buf: [80]u8 = undefined;
        const short = if (self.short_at) |n|
            std.fmt.bufPrint(&short_buf, "; transfer {d} moved half ({d} shortened)", .{ n, self.shortened }) catch ""
        else
            "";
        var waited_buf: [64]u8 = undefined;
        const waited = if (self.latency_ns != 0 or self.sync_latency_ns != 0)
            std.fmt.bufPrint(&waited_buf, "; {d} ms waited on it, {d} ms of it on SYNCHRONIZE CACHE", .{ self.waited_ns / std.time.ns_per_ms, self.sync_waited_ns / std.time.ns_per_ms }) catch ""
        else
            "";
        var failed_buf: [64]u8 = undefined;
        const failed = if (self.sync_fail_at != null)
            std.fmt.bufPrint(&failed_buf, " ({d} failed, VOLUME_SYNC_FAIL)", .{self.sync_failed}) catch ""
        else
            "";
        return std.fmt.bufPrint(buf, "metal-vmm: volume: {s}; {d} reads, {d} writes, {d} SYNCHRONIZE CACHE{s}, {d} MODE SENSE{s}{s}{s}{s}{s}{s}{s}\n", .{
            mode, self.reads, self.writes, self.synchronizes, failed, self.mode_senses, told, gone, ro, short, waited, keeps,
            if (self.power.cut != null)
                (if (lost > 0) "; the power cut lost sectors never synchronized" else "; the power cut lost nothing")
            else if (self.cache) |c|
                (if (!c.exit_cut) "" else if (c.exit_lost > 0) "; the power failed when the guest stopped and lost sectors never synchronized" else "; the power failed when the guest stopped and lost nothing")
            else
                "",
        }) catch "metal-vmm: volume\n";
    }
};

// ── driven as gopher-metal's scsi.zig drives it ─────────────────────────────

const testing = std.testing;

/// A guest's memory with the request queue in it, and the requests built as
/// gopher-metal's `scsi.command` builds them: the header (51 bytes), then
/// the data the disk reads or the response, then the data it writes.
pub const FakeDriver = struct {
    ram: [16384]u8 = @splat(0),

    const size: u16 = 8;
    const desc_at: u64 = 0x100;
    const avail_at: u64 = desc_at + size * @sizeOf(Desc);
    const used_at: u64 = avail_at + 4 + size * 2 + 2;
    const request_at: u64 = 0x800;
    const response_at: u64 = 0x900;
    pub const data_at: u64 = 0x1000;

    const Dir = enum { none, from_disk, to_disk };
    pub const Outcome = struct { response: u8, status: u8, key: u8, asc: u8, residual: u32, used: u32 };

    pub fn open(self: *FakeDriver, d: *Device) void {
        d.write(&self.ram, 0x030, request_queue); // queue_sel
        d.write(&self.ram, 0x038, size);
        d.write(&self.ram, 0x080, desc_at);
        d.write(&self.ram, 0x090, avail_at);
        d.write(&self.ram, 0x0a0, used_at);
        d.write(&self.ram, 0x044, 1);
    }

    fn desc(self: *FakeDriver, i: u64, one: Desc) void {
        const at = desc_at + i * @sizeOf(Desc);
        writeInt(u64, &self.ram, at, one.addr);
        writeInt(u32, &self.ram, at + 8, one.len);
        writeInt(u16, &self.ram, at + 12, one.flags);
        writeInt(u16, &self.ram, at + 14, one.next);
    }

    fn send(self: *FakeDriver, d: *Device, target: u8, lun: u16, cdb: []const u8, dir: Dir, len: u32) Outcome {
        @memset(self.ram[request_at..][0..request_len], 0);
        const field = [8]u8{ 1, target, 0x40 | @as(u8, @truncate(lun >> 8)), @truncate(lun), 0, 0, 0, 0 };
        @memcpy(self.ram[request_at..][0..8], &field);
        @memcpy(self.ram[request_at + 19 ..][0..cdb.len], cdb);
        self.ram[response_at + 10] = 0xFF;
        self.ram[response_at + 11] = 0xFF;
        const n = Desc.next_flag;
        const wr = Desc.write_flag;
        const req: Desc = .{ .addr = request_at, .len = request_len, .flags = n, .next = 1 };
        switch (dir) {
            .none => {
                self.desc(0, req);
                self.desc(1, .{ .addr = response_at, .len = response_len, .flags = wr, .next = 0 });
            },
            .from_disk => {
                self.desc(0, req);
                self.desc(1, .{ .addr = response_at, .len = response_len, .flags = wr | n, .next = 2 });
                self.desc(2, .{ .addr = data_at, .len = len, .flags = wr, .next = 0 });
            },
            .to_disk => {
                self.desc(0, req);
                self.desc(1, .{ .addr = data_at, .len = len, .flags = n, .next = 2 });
                self.desc(2, .{ .addr = response_at, .len = response_len, .flags = wr, .next = 0 });
            },
        }
        const avail_idx = readInt(u16, &self.ram, avail_at + 2);
        writeInt(u16, &self.ram, avail_at + 4 + @as(u64, avail_idx % size) * 2, 0);
        writeInt(u16, &self.ram, avail_at + 2, avail_idx +% 1);
        d.write(&self.ram, 0x050, request_queue);
        const used_idx = readInt(u16, &self.ram, used_at + 2);
        const sense_len = readInt(u32, &self.ram, response_at);
        return .{
            .response = self.ram[response_at + 11],
            .status = self.ram[response_at + 10],
            .key = if (sense_len >= 3) self.ram[response_at + 12 + 2] & 0x0F else 0,
            .asc = if (sense_len >= 13) self.ram[response_at + 12 + 12] else 0,
            .residual = readInt(u32, &self.ram, response_at + 4),
            .used = readInt(u32, &self.ram, used_at + 4 + @as(u64, (used_idx -% 1) % size) * 8 + 4),
        };
    }

    /// `commandSettled`: sent again while the disk answers UNIT ATTENTION.
    fn settled(self: *FakeDriver, d: *Device, cdb: []const u8, dir: Dir, len: u32) Outcome {
        var tries: u8 = 0;
        while (true) : (tries += 1) {
            const o = self.send(d, 0, 0, cdb, dir, len);
            if (!(o.response == response_ok and o.status == status_check_condition and o.key == key_unit_attention) or tries == 2) return o;
        }
    }

    pub fn good(o: Outcome) bool {
        return o.response == response_ok and o.status == status_good;
    }

    pub fn rw(self: *FakeDriver, d: *Device, writing: bool, lba: u32, sectors: u16) Outcome {
        const cdb = [10]u8{ if (writing) op_write else op_read, 0, @truncate(lba >> 24), @truncate(lba >> 16), @truncate(lba >> 8), @truncate(lba), 0, @truncate(sectors >> 8), @truncate(sectors), 0 };
        return self.settled(d, &cdb, if (writing) .to_disk else .from_disk, @as(u32, sectors) * 512);
    }

    pub fn synchronize(self: *FakeDriver, d: *Device) Outcome {
        return self.settled(d, &[10]u8{ op_synchronize, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .none, 0);
    }

    /// MODE SELECT(10) of the caching page with WCE as given and every other
    /// field zero, PF set, as gopher-metal sends it; `changeable` asks MODE
    /// SENSE's changeable values first and gives WCE's bit there instead.
    fn select(self: *FakeDriver, d: *Device, wce_on: bool) Outcome {
        const len: u16 = 8 + 20;
        const list = self.ram[data_at..][0..len];
        @memset(list, 0);
        list[8] = page_caching;
        list[9] = 18;
        if (wce_on) list[10] = 0x04;
        return self.settled(d, &[10]u8{ op_mode_select, 0x10, 0, 0, 0, 0, 0, 0, len, 0 }, .to_disk, len);
    }

    fn changeable(self: *FakeDriver, d: *Device) ?bool {
        const want: u16 = 8 + 20;
        const o = self.settled(d, &[10]u8{ op_mode_sense, 0x08, 0x48, 0, 0, 0, 0, 0, want, 0 }, .from_disk, want);
        if (!good(o)) return null;
        return self.ram[data_at + 10] & 0x04 != 0;
    }

    /// `writeCache`: MODE SENSE(10), the caching page's WCE, or null.
    fn wce(self: *FakeDriver, d: *Device) ?bool {
        const want: u16 = 8 + 20;
        const o = self.settled(d, &[10]u8{ op_mode_sense, 0x08, 0x08, 0, 0, 0, 0, 0, want, 0 }, .from_disk, want);
        if (!good(o)) return null;
        const page = self.ram[data_at..][0..want];
        const p = 8 + ((@as(usize, page[6]) << 8) | page[7]);
        if (p + 3 > want or page[p] & 0x3F != 0x08) return null;
        return page[p + 2] & 0x04 != 0;
    }
};

/// The configuration as gopher-metal reads it: `virtio.configRead32/16`.
fn config32(d: *Device, off: u64) u32 {
    return @truncate(d.read(0x100 + off, 4));
}

test "brought up as gopher-metal brings it: sizes, INQUIRY, UNIT ATTENTION, READ CAPACITY, MODE SENSE" {
    var image: [64 * 512]u8 = @splat(0);
    var vol = Scsi{ .image = &image };
    var d = vol.device();
    try testing.expectEqual(@as(u32, cdb_size), config32(&d, 24));
    try testing.expectEqual(@as(u32, sense_size), config32(&d, 20));
    // max_target and max_lun where §5.6.4 puts them.
    try testing.expectEqual(@as(u32, 255), @as(u32, @truncate(d.read(0x100 + 30, 2))));
    try testing.expectEqual(@as(u32, 16383), config32(&d, 32));
    var g = FakeDriver{};
    g.open(&d);

    // Nobody at target 1; nothing connected at LUN 1; a disk at 0:0.
    try testing.expectEqual(response_bad_target, g.send(&d, 1, 0, &[6]u8{ op_inquiry, 0, 0, 0, 36, 0 }, .from_disk, 36).response);
    try testing.expect(FakeDriver.good(g.send(&d, 0, 1, &[6]u8{ op_inquiry, 0, 0, 0, 36, 0 }, .from_disk, 36)));
    try testing.expectEqual(@as(u8, 0x7F), g.ram[FakeDriver.data_at]);
    const inq = g.send(&d, 0, 0, &[6]u8{ op_inquiry, 0, 0, 0, 36, 0 }, .from_disk, 36);
    try testing.expect(FakeDriver.good(inq));
    try testing.expectEqual(@as(u8, 0x00), g.ram[FakeDriver.data_at]);
    try testing.expectEqual(@as(u32, response_len + 36), inq.used);

    // READ CAPACITY: UNIT ATTENTION once, then the answer.
    const capacity = [10]u8{ op_read_capacity, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const first = g.send(&d, 0, 0, &capacity, .from_disk, 8);
    try testing.expectEqual(status_check_condition, first.status);
    try testing.expectEqual(key_unit_attention, first.key);
    try testing.expect(FakeDriver.good(g.settled(&d, &capacity, .from_disk, 8)));
    try testing.expectEqual(@as(u32, 63), std.mem.readInt(u32, g.ram[FakeDriver.data_at..][0..4], .big));
    try testing.expectEqual(@as(u32, 512), std.mem.readInt(u32, g.ram[FakeDriver.data_at + 4 ..][0..4], .big));

    // No cache: the caching page says write-through.
    try testing.expectEqual(@as(?bool, false), g.wce(&d));
    try testing.expectEqual(@as(u64, 0), vol.refused);
}

test "a sector written is the sector read back, and past the end is ILLEGAL REQUEST" {
    var image: [16 * 512]u8 = @splat(0);
    var bits: [2]u8 = @splat(0);
    var vol = Scsi{ .image = &image, .dirty = &bits, .attention = null };
    var d = vol.device();
    var g = FakeDriver{};
    g.open(&d);
    for (g.ram[FakeDriver.data_at..][0 .. 2 * 512], 0..) |*b, i| b.* = @truncate(i * 7);
    const wrote = g.rw(&d, true, 5, 2);
    try testing.expect(FakeDriver.good(wrote));
    try testing.expectEqual(@as(u32, 0), wrote.residual); // every byte taken
    try testing.expectEqualSlices(u8, g.ram[FakeDriver.data_at..][0 .. 2 * 512], image[5 * 512 ..][0 .. 2 * 512]);
    try testing.expectEqual(@as(u8, 0x60), bits[0]); // sectors 5 and 6
    @memset(g.ram[FakeDriver.data_at..][0 .. 2 * 512], 0);
    const back = g.rw(&d, false, 5, 2);
    try testing.expect(FakeDriver.good(back));
    try testing.expectEqual(@as(u32, 0), back.residual);
    try testing.expectEqual(@as(u32, response_len + 1024), back.used);
    try testing.expectEqualSlices(u8, image[5 * 512 ..][0 .. 2 * 512], g.ram[FakeDriver.data_at..][0 .. 2 * 512]);
    const past = g.rw(&d, false, 15, 2);
    try testing.expectEqual(status_check_condition, past.status);
    try testing.expectEqual(key_illegal_request, past.key);
    try testing.expectEqual(asc_lba_out_of_range, past.asc);
    // A command it does not know.
    const unknown = g.send(&d, 0, 0, &[6]u8{ 0x1B, 0, 0, 0, 0, 0 }, .none, 0);
    try testing.expectEqual(key_illegal_request, unknown.key);
    try testing.expectEqual(asc_invalid_opcode, unknown.asc);
    try testing.expectEqual(@as(u64, 2), vol.refused);
}

test "VOLUME_CACHE=1: WCE said, writes held until SYNCHRONIZE CACHE, and a power cut loses only what was not synchronized" {
    var image: [16 * 512]u8 = @splat('o');
    var c = cache_mod.Cache{ .gpa = testing.allocator, .image = &image };
    defer c.deinit();
    var vol = Scsi{ .image = &image, .cache = &c };
    var d = vol.device();
    var g = FakeDriver{};
    g.open(&d);
    try testing.expectEqual(@as(?bool, true), g.wce(&d));
    @memset(g.ram[FakeDriver.data_at..][0..512], 'a');
    try testing.expect(FakeDriver.good(g.rw(&d, true, 1, 1)));
    try testing.expect(FakeDriver.good(g.synchronize(&d)));
    @memset(g.ram[FakeDriver.data_at..][0..512], 'b');
    try testing.expect(FakeDriver.good(g.rw(&d, true, 2, 1)));
    // Read back from the cache before the cut.
    try testing.expectEqual(@as(u8, 'b'), image[2 * 512]);
    c.lose();
    try testing.expectEqual(@as(u8, 'a'), image[1 * 512]);
    try testing.expectEqual(@as(u8, 'o'), image[2 * 512]);
    try testing.expectEqual(@as(u64, 1), vol.synchronizes);
}

test "VOLUME_CACHE=lie: WCE=0 said and writes held, so a driver that believes it loses them" {
    var image: [16 * 512]u8 = @splat('o');
    var c = cache_mod.Cache{ .gpa = testing.allocator, .image = &image, .lies = true };
    defer c.deinit();
    var vol = Scsi{ .image = &image, .cache = &c };
    var d = vol.device();
    var g = FakeDriver{};
    g.open(&d);
    try testing.expectEqual(@as(?bool, false), g.wce(&d));
    @memset(g.ram[FakeDriver.data_at..][0..512], 'a');
    try testing.expect(FakeDriver.good(g.rw(&d, true, 3, 1)));
    c.lose();
    try testing.expectEqual(@as(u8, 'o'), image[3 * 512]);
    var buf: [256]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, vol.line(&buf), "says it writes through") != null);
}

test "VOLUME_CUT_AFTER: the write the power goes after lands, and is never answered" {
    var image: [16 * 512]u8 = @splat('o');
    var vol = Scsi{ .image = &image, .attention = null, .power = .{ .cut_after = 2 } };
    var d = vol.device();
    var g = FakeDriver{};
    g.open(&d);
    @memset(g.ram[FakeDriver.data_at..][0..512], 'a');
    try testing.expect(FakeDriver.good(g.rw(&d, true, 1, 1)));
    const served = d.served;
    _ = g.send(&d, 0, 0, &[10]u8{ op_write, 0, 0, 0, 0, 4, 0, 0, 1, 0 }, .to_disk, 512);
    try testing.expectEqual(served, d.served);
    try testing.expectEqual(@as(u8, 'a'), image[4 * 512]);
    try testing.expect(vol.power.cut != null);
}

test "a chain of another shape, or a header too short, is not answered" {
    var image: [4 * 512]u8 = @splat(0);
    var vol = Scsi{ .image = &image };
    var g = FakeDriver{};
    // Writable before readable.
    const backwards = [_]Desc{
        .{ .addr = FakeDriver.response_at, .len = response_len, .flags = Desc.write_flag | Desc.next_flag, .next = 1 },
        .{ .addr = FakeDriver.request_at, .len = request_len, .flags = 0, .next = 0 },
    };
    try testing.expectEqual(@as(u32, 0), vol.serve(&g.ram, &backwards));
    const short = [_]Desc{
        .{ .addr = FakeDriver.request_at, .len = request_len - 1, .flags = Desc.next_flag, .next = 1 },
        .{ .addr = FakeDriver.response_at, .len = response_len, .flags = Desc.write_flag, .next = 0 },
    };
    try testing.expectEqual(@as(u32, 0), vol.serve(&g.ram, &short));
    const outside = [_]Desc{
        .{ .addr = g.ram.len - 10, .len = request_len, .flags = Desc.next_flag, .next = 1 },
        .{ .addr = FakeDriver.response_at, .len = response_len, .flags = Desc.write_flag, .next = 0 },
    };
    try testing.expectEqual(@as(u32, 0), vol.serve(&g.ram, &outside));
}

test "VOLUME_SYNC_FAIL: the nth SYNCHRONIZE CACHE fails, keeps nothing, and the next keeps it all" {
    var image: [16 * 512]u8 = @splat('o');
    var c = cache_mod.Cache{ .gpa = testing.allocator, .image = &image };
    defer c.deinit();
    var vol = Scsi{ .image = &image, .cache = &c, .attention = null, .sync_fail_at = 2, .sync_fail_for = 2 };
    var d = vol.device();
    var g = FakeDriver{};
    g.open(&d);
    @memset(g.ram[FakeDriver.data_at..][0..512], 'a');
    try testing.expect(FakeDriver.good(g.rw(&d, true, 1, 1)));
    try testing.expect(FakeDriver.good(g.synchronize(&d)));
    @memset(g.ram[FakeDriver.data_at..][0..512], 'b');
    try testing.expect(FakeDriver.good(g.rw(&d, true, 2, 1)));
    // The second and third fail as a medium error, as v18's `synchronize`
    // reads one: not ILLEGAL REQUEST, so not taken for a disk with no cache.
    for (0..2) |_| {
        const o = g.synchronize(&d);
        try testing.expectEqual(status_check_condition, o.status);
        try testing.expectEqual(key_medium_error, o.key);
    }
    var buf: [256]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, vol.line(&buf), "3 SYNCHRONIZE CACHE (2 failed, VOLUME_SYNC_FAIL)") != null);
    // Sector 2 is still held: a cut now would lose it.
    try testing.expectEqual(@as(u32, 1), c.durable.count());
    // The fourth succeeds, and keeps it.
    try testing.expect(FakeDriver.good(g.synchronize(&d)));
    c.lose();
    try testing.expectEqual(@as(u8, 'a'), image[1 * 512]);
    try testing.expectEqual(@as(u8, 'b'), image[2 * 512]);
    try testing.expectEqual(@as(u64, 2), vol.sync_failed);
}

test "VOLUME_LATENCY_US: each command answered at once, and owed to the clock" {
    var image: [16 * 512]u8 = @splat(0);
    var vol = Scsi{ .image = &image, .attention = null, .latency_ns = 2 * std.time.ns_per_ms };
    var d = vol.device();
    var g = FakeDriver{};
    g.open(&d);
    try testing.expect(FakeDriver.good(g.rw(&d, true, 1, 1)));
    try testing.expect(FakeDriver.good(g.synchronize(&d)));
    try testing.expectEqual(@as(u64, 4 * std.time.ns_per_ms), vol.owed_ns);
    var buf: [256]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, vol.line(&buf), "; 4 ms waited on it, 0 ms of it on SYNCHRONIZE CACHE") != null);
}

test "VOLUME_ATTENTION_AT: the nth command meets UNIT ATTENTION, is not performed, and is sent again" {
    var image: [16 * 512]u8 = @splat('o');
    var vol = Scsi{ .image = &image, .attention = null, .attention_at = 2 };
    var d = vol.device();
    var g = FakeDriver{};
    g.open(&d);
    @memset(g.ram[FakeDriver.data_at..][0..512], 'a');
    try testing.expect(FakeDriver.good(g.rw(&d, true, 1, 1)));
    // The second: told, not written; the third, the same write again, lands.
    @memset(g.ram[FakeDriver.data_at..][0..512], 'b');
    const told = g.send(&d, 0, 0, &[10]u8{ op_write, 0, 0, 0, 0, 2, 0, 0, 1, 0 }, .to_disk, 512);
    try testing.expectEqual(key_unit_attention, told.key);
    try testing.expectEqual(asc_capacity_changed, told.asc);
    try testing.expectEqual(@as(u8, 'o'), image[2 * 512]);
    try testing.expect(FakeDriver.good(g.rw(&d, true, 2, 1)));
    try testing.expectEqual(@as(u8, 'b'), image[2 * 512]);
    try testing.expectEqual(@as(u64, 1), vol.attentions);
    // INQUIRY is never told: one pending waits for the next command.
    vol.attention_at = 4; // the INQUIRY below
    try testing.expect(FakeDriver.good(g.send(&d, 0, 0, &[6]u8{ op_inquiry, 0, 0, 0, 36, 0 }, .from_disk, 36)));
    try testing.expectEqual(key_unit_attention, g.send(&d, 0, 0, &[10]u8{ op_read_capacity, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .from_disk, 8).key);
}

test "VOLUME_GONE_AT: from the nth command, BAD_TARGET, and nothing written" {
    var image: [16 * 512]u8 = @splat('o');
    var vol = Scsi{ .image = &image, .attention = null, .gone_at = 2 };
    var d = vol.device();
    var g = FakeDriver{};
    g.open(&d);
    @memset(g.ram[FakeDriver.data_at..][0..512], 'a');
    try testing.expect(FakeDriver.good(g.rw(&d, true, 1, 1)));
    for (0..3) |_| {
        const o = g.rw(&d, true, 2, 1);
        try testing.expectEqual(response_bad_target, o.response);
    }
    try testing.expectEqual(response_bad_target, g.synchronize(&d).response);
    try testing.expectEqual(@as(u8, 'o'), image[2 * 512]);
    try testing.expectEqual(@as(u64, 4), vol.gone_answered);
    var buf: [256]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, vol.line(&buf), "; gone from command 2, 4 commands answered BAD_TARGET") != null);
}

test "VOLUME_READ_ONLY_AT: from the nth command WP is said, writes are DATA PROTECT, and reads still answer" {
    var image: [16 * 512]u8 = @splat('o');
    var vol = Scsi{ .image = &image, .attention = null, .read_only_at = 2 };
    var d = vol.device();
    var g = FakeDriver{};
    g.open(&d);
    @memset(g.ram[FakeDriver.data_at..][0..512], 'a');
    try testing.expect(FakeDriver.good(g.rw(&d, true, 1, 1)));
    const refused = g.rw(&d, true, 2, 1);
    try testing.expectEqual(status_check_condition, refused.status);
    try testing.expectEqual(key_data_protect, refused.key);
    try testing.expectEqual(asc_write_protected, refused.asc);
    try testing.expectEqual(@as(u8, 'o'), image[2 * 512]);
    try testing.expect(FakeDriver.good(g.rw(&d, false, 1, 1)));
    try testing.expectEqual(@as(u8, 'a'), g.ram[FakeDriver.data_at]);
    try testing.expect(FakeDriver.good(g.synchronize(&d)));
    // MODE SENSE's header says WP.
    _ = g.wce(&d);
    try testing.expectEqual(@as(u8, 0x80), g.ram[FakeDriver.data_at + 3] & 0x80);
    try testing.expectEqual(@as(u64, 1), vol.protected);
}

test "VOLUME_SYNC_US: a SYNCHRONIZE CACHE costs that much more than another command" {
    var image: [16 * 512]u8 = @splat(0);
    var vol = Scsi{ .image = &image, .attention = null, .latency_ns = std.time.ns_per_ms, .sync_latency_ns = 10 * std.time.ns_per_ms };
    var d = vol.device();
    var g = FakeDriver{};
    g.open(&d);
    try testing.expect(FakeDriver.good(g.rw(&d, true, 1, 1)));
    try testing.expect(FakeDriver.good(g.synchronize(&d)));
    try testing.expectEqual(@as(u64, 12 * std.time.ns_per_ms), vol.owed_ns);
    var buf: [256]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, vol.line(&buf), "; 12 ms waited on it, 10 ms of it on SYNCHRONIZE CACHE") != null);
}

test "VOLUME_SECTOR and VOLUME_MODE_PAGES=none: READ CAPACITY says another sector size; MODE SENSE has no page" {
    var image: [64 * 512]u8 = @splat(0);
    var vol = Scsi{ .image = &image, .attention = null, .sector_said = 4096, .no_mode_pages = true };
    var d = vol.device();
    var g = FakeDriver{};
    g.open(&d);
    try testing.expect(FakeDriver.good(g.send(&d, 0, 0, &[10]u8{ op_read_capacity, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .from_disk, 8)));
    try testing.expectEqual(@as(u32, 4096), std.mem.readInt(u32, g.ram[FakeDriver.data_at + 4 ..][0..4], .big));
    try testing.expectEqual(@as(u32, 64 * 512 / 4096 - 1), std.mem.readInt(u32, g.ram[FakeDriver.data_at..][0..4], .big));
    @memset(g.ram[FakeDriver.data_at..][0..28], 0xEE);
    try testing.expect(FakeDriver.good(g.send(&d, 0, 0, &[10]u8{ 0x5A, 0, 0x08, 0, 0, 0, 0, 0, 28, 0 }, .from_disk, 28)));
    try testing.expectEqual(@as(u16, 6), std.mem.readInt(u16, g.ram[FakeDriver.data_at..][0..2], .big));
}

test "VOLUME_SHORT_AT: the nth transfer moves half, answers GOOD, and says the rest as its residual" {
    var image: [16 * 512]u8 = @splat(0);
    var vol = Scsi{ .image = &image, .attention = null, .short_at = 2 };
    var d = vol.device();
    var g = FakeDriver{};
    g.open(&d);
    @memset(g.ram[FakeDriver.data_at..][0 .. 2 * 512], 0xAB);
    const first = g.rw(&d, true, 0, 2); // transfer 1: whole
    try testing.expect(FakeDriver.good(first));
    try testing.expectEqual(@as(u32, 0), first.residual);
    const second = g.rw(&d, true, 4, 2); // transfer 2: half
    try testing.expect(FakeDriver.good(second));
    try testing.expectEqual(@as(u32, 512), second.residual);
    try testing.expectEqual(@as(u8, 0xAB), image[4 * 512 + 511]);
    try testing.expectEqual(@as(u8, 0), image[5 * 512]); // the half never written
    @memset(g.ram[FakeDriver.data_at..][0 .. 2 * 512], 0x11);
    const third = g.rw(&d, false, 4, 2); // transfer 3: whole again
    try testing.expectEqual(@as(u32, 0), third.residual);
    try testing.expectEqual(@as(u64, 1), vol.shortened);
}

test "MODE SELECT turns a write cache off: later writes go through, and what was held before stays held until SYNCHRONIZE" {
    var image: [16 * 512]u8 = @splat('o');
    var c = cache_mod.Cache{ .gpa = testing.allocator, .image = &image };
    defer c.deinit();
    var vol = Scsi{ .image = &image, .cache = &c };
    var d = vol.device();
    var g = FakeDriver{};
    g.open(&d);
    try testing.expectEqual(@as(?bool, true), g.wce(&d));
    try testing.expectEqual(@as(?bool, true), g.changeable(&d));
    @memset(g.ram[FakeDriver.data_at..][0..512], 'a');
    try testing.expect(FakeDriver.good(g.rw(&d, true, 1, 1))); // held
    try testing.expect(FakeDriver.good(g.select(&d, false)));
    try testing.expectEqual(@as(?bool, false), g.wce(&d));
    @memset(g.ram[FakeDriver.data_at..][0..512], 'b');
    try testing.expect(FakeDriver.good(g.rw(&d, true, 2, 1))); // through
    c.lose();
    try testing.expectEqual(@as(u8, 'o'), image[1 * 512]);
    try testing.expectEqual(@as(u8, 'b'), image[2 * 512]);
    var buf: [256]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, vol.line(&buf), "turned off by MODE SELECT") != null);
    // And back on.
    try testing.expect(FakeDriver.good(g.select(&d, true)));
    try testing.expectEqual(@as(?bool, true), g.wce(&d));
}

test "VOLUME_WCE_FIXED: WCE is not changeable, and a MODE SELECT that turns it off is refused" {
    var image: [16 * 512]u8 = @splat('o');
    var c = cache_mod.Cache{ .gpa = testing.allocator, .image = &image };
    defer c.deinit();
    var vol = Scsi{ .image = &image, .cache = &c, .wce_fixed = true };
    var d = vol.device();
    var g = FakeDriver{};
    g.open(&d);
    try testing.expectEqual(@as(?bool, false), g.changeable(&d));
    const o = g.select(&d, false);
    try testing.expectEqual(key_illegal_request, o.key);
    try testing.expectEqual(asc_invalid_parameter, o.asc);
    try testing.expectEqual(@as(?bool, true), g.wce(&d));
    // Setting it to what it is changes nothing, and is taken.
    try testing.expect(FakeDriver.good(g.select(&d, true)));
}

test "MODE SELECT to a cache that lies: WCE=0 is what it says already, and it goes on holding" {
    var image: [16 * 512]u8 = @splat('o');
    var c = cache_mod.Cache{ .gpa = testing.allocator, .image = &image, .lies = true };
    defer c.deinit();
    var vol = Scsi{ .image = &image, .cache = &c };
    var d = vol.device();
    var g = FakeDriver{};
    g.open(&d);
    try testing.expect(FakeDriver.good(g.select(&d, false)));
    @memset(g.ram[FakeDriver.data_at..][0..512], 'a');
    try testing.expect(FakeDriver.good(g.rw(&d, true, 3, 1)));
    c.lose();
    try testing.expectEqual(@as(u8, 'o'), image[3 * 512]);
}

test "MODE SELECT: without PF, with SP, or changing a field but WCE, it is refused" {
    var image: [16 * 512]u8 = @splat('o');
    var c = cache_mod.Cache{ .gpa = testing.allocator, .image = &image };
    defer c.deinit();
    var vol = Scsi{ .image = &image, .cache = &c };
    var d = vol.device();
    var g = FakeDriver{};
    g.open(&d);
    _ = g.wce(&d); // past UNIT ATTENTION
    const len: u16 = 8 + 20;
    const list = g.ram[FakeDriver.data_at..][0..len];
    @memset(list, 0);
    list[8] = page_caching;
    list[9] = 18;
    const no_pf = g.send(&d, 0, 0, &[10]u8{ op_mode_select, 0, 0, 0, 0, 0, 0, 0, len, 0 }, .to_disk, len);
    try testing.expectEqual(asc_invalid_field, no_pf.asc);
    const sp = g.send(&d, 0, 0, &[10]u8{ op_mode_select, 0x11, 0, 0, 0, 0, 0, 0, len, 0 }, .to_disk, len);
    try testing.expectEqual(asc_saving_not_supported, sp.asc);
    list[10] = 0x01; // RCD, not WCE
    const rcd = g.send(&d, 0, 0, &[10]u8{ op_mode_select, 0x10, 0, 0, 0, 0, 0, 0, len, 0 }, .to_disk, len);
    try testing.expectEqual(asc_invalid_parameter, rcd.asc);
    try testing.expect(vol.saysWce());
}
