//! **WHAT THIS MACHINE IS ALLOWED TO DO TO ITS GUEST.**
//!
//! A hypervisor that owns every input can choose to be unhelpful, and a
//! deterministic one can do it to a recipe: this guest, this seed, this frame
//! number. That is the difference between "it failed once on Tuesday" and a
//! failure with a name.
//!
//! **THE WIRE CAN LOSE WHAT THE GUEST SENDS**, by number or by chance, and it
//! can make what comes back take time to arrive. **IT CAN LOSE OR DAMAGE WHAT
//! THE PEER SENDS, TOO**, and then the peer (peer.zig) runs a retransmission
//! timer of its own on the machine's clock, so a frame lost on the way in is
//! sent again rather than hanging the run. The point either way is to make
//! the guest's own recovery do its job: its retransmissions for what it sent,
//! and its handling of what arrives out of order, twice, or damaged.
//!
//! **THE DISK CAN REFUSE TO SERVE A REQUEST**, which is the same idea one
//! layer over: the guest's own `fat16.zig` turns a bad status byte into
//! `ReadFailed`, and those paths have almost certainly never run.
//!
//! **PICKING THE NTH IS THE INTERESTING KNOB**, more than a rate. A rate
//! explores randomly; a number explores systematically — lose the first, then
//! the second, then the third, and the table of what happened is a map of what
//! this guest can survive. `lossy.sh` and `flaky.sh` draw those maps.

const std = @import("std");
const mangle = @import("mangle.zig");

/// **WHICH ONES.** The same question for a frame on the wire and a request to
/// the disk, so it is asked in one place: this is the nth of them — was n
/// named, or does the rate say so?
///
/// Each user gets its own dice. A draw for the disk must not move the wire's
/// generator along, or turning one on would change what the other did.
pub const Schedule = struct {
    /// The ones to pick, counting from one: each a number or a range of them
    /// (`WIRE_EAT=3,9,20-60`), as many as `named.len`. Zeroes mean nothing.
    named: [32]Span = @splat(.{}),
    /// Or one in this many, drawn. Zero picks none, which is the default and
    /// what every probe in check.sh runs on.
    rate: u32 = 0,
    dice: std.Random.DefaultPrng,
    /// How many have gone past, and which ones were picked.
    seen: u64 = 0,
    picked: [8]u32 = @splat(0),
    picked_count: u64 = 0,

    /// The ones from `lo` to `hi`, both included; zero is none.
    pub const Span = struct {
        lo: u32 = 0,
        hi: u32 = 0,

        pub fn one(n: u32) Span {
            return .{ .lo = n, .hi = n };
        }

        fn has(self: Span, n: u64) bool {
            return self.lo != 0 and n >= self.lo and n <= self.hi;
        }
    };

    pub fn init(seed: u64) Schedule {
        return .{ .dice = .init(seed) };
    }

    pub fn configured(self: *const Schedule) bool {
        return self.rate != 0 or self.named[0].lo != 0;
    }

    /// Counts one more, and answers whether it is chosen. Called once per
    /// candidate, in order, so the answer is a function of the run.
    pub fn picks(self: *Schedule) bool {
        self.seen += 1;
        var chosen = false;
        for (self.named) |n| {
            if (n.has(self.seen)) chosen = true;
        }
        if (!chosen and self.rate != 0) chosen = self.dice.random().uintLessThan(u32, self.rate) == 0;
        if (!chosen) return false;
        if (self.picked_count < self.picked.len) self.picked[@intCast(self.picked_count)] = @intCast(self.seen);
        self.picked_count += 1;
        return true;
    }
};

/// As much as an ethernet frame can hold, which is all the peer ever sends.
const frame_bytes: usize = 1514;
/// How many frames can be in flight on the wire at once. A guest emptying a
/// whole HTTP response into one doorbell is answered segment by segment, and
/// every one of those answers waits here until the guest has a buffer free for
/// it, so this is deeper than the two the peer produces per frame.
const in_flight: usize = 64;

const Held = struct {
    due_ns: u64 = 0,
    len: usize = 0,
    /// A lying copy `PEER_MANGLE` put ahead of a frame: the knob's own.
    lie: bool = false,
    bytes: [frame_bytes]u8 = undefined,
};

pub const Wire = struct {
    /// Which of the guest's frames never arrive. 1 is the first frame it ever
    /// sends.
    lost: Schedule = .init(0x77_69_72_65_64_69_63_65), // "wiredice"
    /// Which of the PEER's frames never arrive, and which arrive damaged: a
    /// byte of the TCP segment changed, which its checksum notices (or of
    /// the IP header, for a frame that is not TCP). 1 is the first frame the
    /// peer ever sends. Each has its own dice.
    peer_lost: Schedule = .init(0x70_65_65_72_6c_6f_73_65), // "peerlose"
    peer_damaged: Schedule = .init(0x70_65_65_72_68_75_72_74), // "peerhurt"
    /// **AND WHICH ARRIVE AFTER A COPY THAT LIES** (`PEER_MANGLE`,
    /// mangle.zig): the copy first, of the kind `mangle_kind` names or the
    /// next in turn, then the frame. Only TCP frames have a copy; the
    /// schedule still counts every frame, as the others do.
    peer_mangled: Schedule = .init(0x70_65_65_72_6c_69_65_73), // "peerlies"
    mangle_kind: ?mangle.Kind = null,
    /// Copies sent, by kind, and frames picked that were not TCP.
    mangled: [mangle.kinds.len]u32 = @splat(0),
    mangled_not_tcp: u32 = 0,
    /// How long a frame takes to reach the guest. Zero means it arrives in the
    /// same breath the guest's frame was sent, which is what the probes have
    /// always seen and what makes the peer look like a function call.
    ///
    /// **A GUEST THAT WAITS WITHOUT ASKING QUESTIONS WAITS FOREVER.** Time
    /// here is measured in exits (clock.zig), so a wait implemented by
    /// spinning on memory — gopher-metal's `dhcp.exchange` counts twenty
    /// million turns of the receive ring and never looks at a clock — does not
    /// advance it, and a frame held for a while is never due. Its TCP loops do
    /// check the clock, so they see latency as intended. This is a real limit
    /// of a machine whose clock is its guest's curiosity, not a bug to fix
    /// here: the fix is in the guest, and it is the same fix rtc.zig already
    /// had to make when its spin counts became hours under KVM.
    latency_ns: u64 = 0,

    held: [in_flight]Held = @splat(.{}),
    /// Frames a full wire pushed out to make room that carried more than an
    /// acknowledgement (data, or SYN, FIN, RST): a loss no knob asked for,
    /// which a peer that never resends never recovers from. The peer keeps
    /// to `room` with what it sends, so a run that counts any has a bug
    /// here. A bare ACK pushed out is a busy receiver's ordinary loss, and
    /// the next ACK says all it said: `acks_pushed_out`.
    pushed_out: u64 = 0,
    acks_pushed_out: u64 = 0,
    /// Lying copies pushed out: the knob's frames, owed to nobody.
    lies_pushed_out: u64 = 0,
    /// The oldest frame in flight and the next free slot, as a ring.
    first: usize = 0,
    next: usize = 0,

    pub fn configured(self: *const Wire) bool {
        return self.lost.configured() or self.latency_ns != 0;
    }

    /// The peer's frames may not arrive as sent, so it must be ready to send
    /// them again.
    pub fn hurtsPeer(self: *const Wire) bool {
        return self.peer_lost.configured() or self.peer_damaged.configured();
    }

    /// **DOES THE GUEST'S NEXT FRAME GET THERE?**
    pub fn carries(self: *Wire) bool {
        return !self.lost.picks();
    }

    /// A frame from the peer, put on the wire. It arrives when the wire says,
    /// which with no latency is at once.
    pub fn hold(self: *Wire, bytes: []const u8, now: u64) void {
        if (bytes.len > frame_bytes) return;
        // Both are asked of every frame, so each counts every frame.
        const lose = self.peer_lost.picks();
        const damage = self.peer_damaged.picks();
        const lie = self.peer_mangled.picks();
        if (lose) return;
        if (lie) self.lieFirst(bytes, now);
        const slot = &self.held[self.next % in_flight];
        // A full wire drops the oldest rather than the newest, which is what a
        // queue that overflows does.
        if (self.next - self.first >= in_flight) self.pushOut();
        slot.due_ns = now + self.latency_ns;
        slot.len = bytes.len;
        slot.lie = false;
        @memcpy(slot.bytes[0..bytes.len], bytes);
        if (damage) {
            const tcp = bytes.len >= 34 + 20 and bytes[23] == 6;
            slot.bytes[if (tcp) 34 + 16 else 24] ^= 0x5A; // a checksum's byte
        }
        self.next += 1;
    }

    /// The oldest frame goes, to make room, counted by what it carried.
    fn pushOut(self: *Wire) void {
        const oldest = &self.held[self.first % in_flight];
        if (oldest.lie) {
            self.lies_pushed_out += 1;
        } else if (bareAck(oldest.bytes[0..oldest.len])) self.acks_pushed_out += 1 else self.pushed_out += 1;
        self.first += 1;
    }

    /// A TCP segment with no data and no SYN, FIN or RST: an acknowledgement
    /// alone, which a later one supersedes.
    fn bareAck(f: []const u8) bool {
        if (f.len < 54 or f[12] != 0x08 or f[13] != 0x00 or f[23] != 6) return false;
        const ihl = @as(usize, f[14] & 0x0F) * 4;
        const total = (@as(usize, f[16]) << 8) | f[17];
        if (f.len < 14 + ihl + 20) return false;
        const tcp = f[14 + ihl ..];
        const header = @as(usize, tcp[12] >> 4) * 4;
        return tcp[13] & 0x07 == 0 and total == ihl + header;
    }

    /// The lying copy of `bytes`, put on the wire ahead of it.
    fn lieFirst(self: *Wire, bytes: []const u8, now: u64) void {
        var total: u32 = 0;
        for (self.mangled) |n| total += n;
        const kind = self.mangle_kind orelse mangle.kinds[total % mangle.kinds.len];
        var out: [frame_bytes + 64]u8 = undefined;
        const copy = mangle.mangle(bytes, kind, &out) orelse {
            self.mangled_not_tcp += 1;
            return;
        };
        if (copy.len > frame_bytes) return;
        const slot = &self.held[self.next % in_flight];
        if (self.next - self.first >= in_flight) self.pushOut();
        slot.due_ns = now + self.latency_ns;
        slot.len = copy.len;
        slot.lie = true;
        @memcpy(slot.bytes[0..copy.len], copy);
        self.next += 1;
        self.mangled[@intFromEnum(kind)] += 1;
    }

    /// The next frame that has arrived, or nothing. In the order they were
    /// sent: a wire does not reorder unless it is asked to.
    ///
    /// **IT STAYS ON THE WIRE UNTIL SOMEBODY TAKES IT.** The guest may have no
    /// receive buffer free at this instant — it posts them and recycles them
    /// as it polls, and a guest in the middle of emptying a response has not
    /// polled for a while. A real card in that position holds the frame in its
    /// FIFO for the microsecond it takes; dropping it instead invents a loss
    /// that nothing on this wire could have caused, and the guest pays a
    /// retransmission timeout for our impatience.
    pub fn ready(self: *Wire, now: u64) ?[]const u8 {
        if (self.first >= self.next) return null;
        const slot = &self.held[self.first % in_flight];
        if (slot.due_ns > now) return null;
        return slot.bytes[0..slot.len];
    }

    /// How many more frames it can hold before a new one pushes out the
    /// oldest.
    pub fn room(self: *const Wire) usize {
        return in_flight - (self.next - self.first);
    }

    /// When the oldest frame in flight arrives, if one is.
    pub fn nextDue(self: *const Wire) ?u64 {
        if (self.first >= self.next) return null;
        return self.held[self.first % in_flight].due_ns;
    }

    /// The frame `ready` offered has been delivered.
    pub fn take(self: *Wire) void {
        if (self.first < self.next) self.first += 1;
    }
};

// ── what can be checked without a guest ──────────────────────────────────────

const testing = std.testing;

test "the numbered frame is the one that goes missing" {
    var w = Wire{};
    w.lost.named[0] = .one(3);
    try testing.expect(w.carries());
    try testing.expect(w.carries());
    try testing.expect(!w.carries()); // the third
    try testing.expect(w.carries());
    try testing.expectEqual(@as(u64, 1), w.lost.picked_count);
    try testing.expectEqual(@as(u32, 3), w.lost.picked[0]);
}

test "a rate picks some and not all, and picks the same ones twice" {
    var a = Schedule.init(7);
    var b = Schedule.init(7);
    a.rate = 4;
    b.rate = 4;
    var from_a: [200]bool = undefined;
    var from_b: [200]bool = undefined;
    for (&from_a) |*x| x.* = a.picks();
    for (&from_b) |*x| x.* = b.picks();
    try testing.expectEqualSlices(bool, &from_a, &from_b);
    try testing.expect(a.picked_count > 20 and a.picked_count < 80); // one in four, loosely
}

test "two users of the same idea do not move each other's dice" {
    var wire = Wire{};
    var drive = Drive{};
    wire.lost.rate = 3;
    drive.refused.rate = 3;
    var alone: [60]bool = undefined;
    for (&alone) |*x| x.* = drive.serves(0, 1, false);

    var together = Drive{};
    together.refused.rate = 3;
    var mixed: [60]bool = undefined;
    for (&mixed) |*x| {
        _ = wire.carries(); // the wire is busy at the same time
        x.* = together.serves(0, 1, false);
    }
    try testing.expectEqualSlices(bool, &alone, &mixed);
}

test "the disk refuses the request it was told to refuse" {
    var d = Drive{};
    d.refused.named[0] = .one(2);
    try testing.expect(d.serves(10, 1, false));
    try testing.expect(!d.serves(11, 1, true));
    try testing.expect(d.serves(12, 1, false));
    try testing.expectEqual(@as(u64, 1), d.refused.picked_count);
    // And it remembers what was being asked for, not just when.
    try testing.expectEqual(@as(u64, 11), d.sectors[0]);
    try testing.expectEqual(@as(u8, 'w'), d.kinds[0]);
}

test "a frame arrives when the wire says, and in the order it was sent" {
    var w = Wire{ .latency_ns = 1_000 };
    w.hold("first", 0);
    w.hold("second", 0);
    try testing.expect(w.ready(500) == null); // not yet
    try testing.expectEqualStrings("first", w.ready(1_000).?);
    // Still there until somebody takes it: the guest may have had no buffer.
    try testing.expectEqualStrings("first", w.ready(1_000).?);
    w.take();
    try testing.expectEqualStrings("second", w.ready(1_000).?);
    w.take();
    try testing.expect(w.ready(2_000) == null);
}

/// **THE DISK, WHEN IT WILL NOT.** virtio-blk answers every request with a
/// status byte, and the guest's own fat16.zig turns anything but "ok" into
/// `ReadFailed` or `WriteFailed` — paths that a disk which always works never
/// reaches.
pub const Drive = struct {
    /// Which of the guest's requests come back refused. 1 is the first request
    /// it ever makes, read or write.
    refused: Schedule = .init(0x64_69_73_6B_64_69_63_65), // "diskdice"
    /// **WHAT IT WAS ASKING FOR**, for the ones refused: a request number on
    /// its own says when, and a sector says what — which is the difference
    /// between "the 133rd read" and "the directory".
    sectors: [8]u64 = @splat(0),
    kinds: [8]u8 = @splat(0),
    /// **COUNT ONLY THE WRITES.** A guest reads a hundred sectors for every
    /// one it writes, so "refuse the nth request" is a blunt way to aim at the
    /// moment something is being saved. With this set, reads are served and
    /// not counted, and n means the nth write.
    writes_only: bool = false,
    /// **COUNT ONLY THE READS**, the other way round: writes land and are not
    /// counted. Both set is a disk that refuses nothing.
    reads_only: bool = false,

    /// **BAD SECTORS** (`DISK_BAD_SECTOR=s[,t]`): every request touching one
    /// of these is refused, read or write (or only one kind, by
    /// `DISK_READS_ONLY` and `DISK_WRITES_ONLY`), for the whole run. A request
    /// number reaches a sector on one path; a sector is reached on every path
    /// that touches it, and stays bad on the next boot if it is named again,
    /// as a real one does.
    bad: [8]u64 = @splat(0),
    bad_len: usize = 0,
    /// Every request so far, of either kind, counting from one, and the ones
    /// a bad sector refused: their numbers, sectors and kinds.
    requests: u64 = 0,
    bad_hits: u64 = 0,
    bad_at: [8]u64 = @splat(0),
    bad_sectors: [8]u64 = @splat(0),
    bad_kinds: [8]u8 = @splat(0),

    /// **SILENT ROT** (`DISK_ROT=sector,byte[,mask]`): every read of the
    /// sector is served with that byte XORed by `mask` (one bit, 0x01, by
    /// default), and says "ok", as a disk whose cell decayed does. Until the
    /// guest writes the sector again, which heals it. The image is never
    /// touched. `rotted` counts the reads it spoiled.
    rot_sector: ?u64 = null,
    rot_byte: u16 = 0,
    rot_mask: u8 = 0x01,
    rot_healed: bool = false,
    rotted: u64 = 0,

    /// **THE POWER IS CUT AFTER THE GUEST'S NTH WRITE** (`DISK_CUT_AFTER`):
    /// that write lands, nothing after it does, and the machine stops at the
    /// end of the exit it happened in. The image keeps what was written before
    /// it, as a disk does when the power goes: disk.zig writes back exactly the
    /// sectors written. 1 is the first write.
    cut_after: ?u64 = null,
    /// **A TORN WRITE** (`DISK_TEAR`, `DISK_TEAR_KEEP`): the nth write of more
    /// than one sector lands only its first `tear_keep` sectors, and the power
    /// is cut there.
    tear: ?u64 = null,
    tear_keep: u64 = 1,
    /// Writes served so far, all of them and those of several sectors.
    writes: u64 = 0,
    multi_writes: u64 = 0,
    /// Once the power is cut: which write it was, and what of it landed.
    cut: ?Cut = null,

    pub const Cut = struct {
        write: u64,
        sector: u64,
        landed: u64,
        of: u64,
    };

    pub fn configured(self: *const Drive) bool {
        return self.refused.configured() or self.writes_only or self.reads_only or self.bad_len != 0 or
            self.cut_after != null or self.tear != null or self.rot_sector != null;
    }

    /// **HOW MUCH OF THIS WRITE LANDS**, in sectors, for a write of `sectors`
    /// at `sector`: all of it, unless it is the one the power is cut after or
    /// in. Called once per write the device serves, in order; never after the
    /// cut.
    pub fn lands(self: *Drive, sector: u64, sectors: u64) u64 {
        self.writes += 1;
        if (sectors > 1) self.multi_writes += 1;
        if (self.tear) |n| if (sectors > 1 and self.multi_writes == n) {
            const keep = @min(self.tear_keep, sectors - 1);
            self.cut = .{ .write = self.writes, .sector = sector, .landed = keep, .of = sectors };
            return keep;
        };
        if (self.cut_after) |n| if (self.writes == n) {
            self.cut = .{ .write = self.writes, .sector = sector, .landed = sectors, .of = sectors };
        };
        return sectors;
    }

    /// The bytes of a read of `sectors` from `sector`, just copied: the
    /// rotted byte spoiled if it is among them.
    pub fn rotInto(self: *Drive, sector: u64, bytes: []u8) void {
        const at = self.rot_sector orelse return;
        if (self.rot_healed or at < sector) return;
        const off = (at - sector) * 512 + self.rot_byte;
        if (off >= bytes.len) return;
        bytes[@intCast(off)] ^= self.rot_mask;
        self.rotted += 1;
    }

    /// A write of `sectors` from `sector` landed: a rotted sector among them
    /// holds what was written now.
    pub fn rewrote(self: *Drive, sector: u64, sectors: u64) void {
        const at = self.rot_sector orelse return;
        if (at >= sector and at - sector < sectors) self.rot_healed = true;
    }

    /// **IS THIS ONE SERVED?** Called once per request of `sectors` sectors
    /// from `sector`, in order. A bad sector does not move the schedule's
    /// count, so `DISK_REFUSE=n` means the same request with one or without.
    pub fn serves(self: *Drive, sector: u64, sectors: u64, writing: bool) bool {
        self.requests += 1;
        if (self.writes_only and !writing) return true;
        if (self.reads_only and writing) return true;
        const at = self.refused.picked_count;
        if (self.refused.picks()) {
            if (at < self.sectors.len) {
                self.sectors[@intCast(at)] = sector;
                self.kinds[@intCast(at)] = if (writing) 'w' else 'r';
            }
            return false;
        }
        const hit = self.touchesBad(sector, sectors) orelse return true;
        if (self.bad_hits < self.bad_at.len) {
            const i: usize = @intCast(self.bad_hits);
            self.bad_at[i] = self.requests;
            self.bad_sectors[i] = hit;
            self.bad_kinds[i] = if (writing) 'w' else 'r';
        }
        self.bad_hits += 1;
        return false;
    }

    /// The first bad sector in `sectors` sectors from `sector`, if any.
    fn touchesBad(self: *const Drive, sector: u64, sectors: u64) ?u64 {
        for (self.bad[0..self.bad_len]) |b| {
            if (b >= sector and b - sector < @max(sectors, 1)) return b;
        }
        return null;
    }
};

test "a wire with nothing configured is a wire that does nothing" {
    var w = Wire{};
    var d = Drive{};
    try testing.expect(!w.configured());
    try testing.expect(!d.configured());
    for (0..100) |_| try testing.expect(d.serves(0, 1, false));
    for (0..100) |_| try testing.expect(w.carries());
    w.hold("now", 12345);
    try testing.expectEqualStrings("now", w.ready(12345).?);
}

test "a bad sector refuses every request that touches it, and nothing else" {
    var d = Drive{ .bad_len = 2 };
    d.bad[0] = 2180;
    d.bad[1] = 7;
    try testing.expect(d.serves(2179, 1, false)); // beside it
    try testing.expect(!d.serves(2180, 1, false)); // on it
    try testing.expect(!d.serves(2176, 8, true)); // across it
    try testing.expect(d.serves(2181, 4, true)); // just past it
    try testing.expect(!d.serves(0, 8, false)); // across the other
    try testing.expect(!d.serves(2180, 1, true)); // and again: it stays bad
    try testing.expectEqual(@as(u64, 4), d.bad_hits);
    try testing.expectEqualSlices(u64, &.{ 2, 3, 5, 6 }, d.bad_at[0..4]);
    try testing.expectEqualSlices(u64, &.{ 2180, 2180, 7, 2180 }, d.bad_sectors[0..4]);
    try testing.expectEqualSlices(u8, "rwrw", d.bad_kinds[0..4]);
    try testing.expect(d.refused.picked_count == 0 and d.configured());
}

test "reads only: the bad sector's reads are refused and its writes land" {
    var d = Drive{ .bad_len = 1, .reads_only = true };
    d.bad[0] = 40;
    try testing.expect(!d.serves(40, 1, false));
    try testing.expect(d.serves(40, 1, true));
    try testing.expect(!d.serves(40, 1, false));
    var w = Drive{ .bad_len = 1, .writes_only = true };
    w.bad[0] = 40;
    try testing.expect(w.serves(40, 1, false));
    try testing.expect(!w.serves(40, 1, true));
}

test "a bad sector leaves the schedule's count where it was" {
    var plain = Drive{};
    plain.refused.named[0] = .one(4);
    var with = Drive{ .bad_len = 1 };
    with.bad[0] = 3;
    with.refused.named[0] = .one(4);
    for (1..7) |i| {
        const a = plain.serves(i, 1, false);
        const b = with.serves(i, 1, false);
        if (i == 3) try testing.expect(a and !b) else try testing.expectEqual(a, b);
    }
    try testing.expectEqual(@as(u32, 4), with.refused.picked[0]);
}

test "a rotted byte spoils every read of its sector, says ok, and a write heals it" {
    var d = Drive{ .rot_sector = 10, .rot_byte = 3, .rot_mask = 0x80 };
    var buf: [4 * 512]u8 = @splat(0);
    d.rotInto(8, &buf); // sectors 8..11: the rotted one is the third
    try testing.expectEqual(@as(u8, 0x80), buf[2 * 512 + 3]);
    var one: [512]u8 = @splat(0x11);
    d.rotInto(11, &one); // past it
    d.rotInto(9, &one); // before it, and too short to reach it
    try testing.expectEqual(@as(u8, 0x11), one[3]);
    d.rotInto(10, &one);
    try testing.expectEqual(@as(u8, 0x91), one[3]);
    try testing.expectEqual(@as(u64, 2), d.rotted);
    d.rewrote(9, 1); // another sector
    d.rewrote(8, 4); // its own
    var after: [512]u8 = @splat(0);
    d.rotInto(10, &after);
    try testing.expectEqual(@as(u8, 0), after[3]);
    try testing.expectEqual(@as(u64, 2), d.rotted);
    try testing.expect(d.configured());
}

test "the power is cut after the nth write, which lands whole" {
    var d = Drive{ .cut_after = 3 };
    try testing.expectEqual(@as(u64, 2), d.lands(10, 2));
    try testing.expectEqual(@as(u64, 1), d.lands(11, 1));
    try testing.expect(d.cut == null);
    try testing.expectEqual(@as(u64, 4), d.lands(20, 4));
    try testing.expectEqual(Drive.Cut{ .write = 3, .sector = 20, .landed = 4, .of = 4 }, d.cut.?);
}

test "a torn write lands its first sectors only, counting writes of more than one" {
    var d = Drive{ .tear = 2, .tear_keep = 3 };
    _ = d.lands(1, 1); // one sector: not counted
    try testing.expectEqual(@as(u64, 8), d.lands(2, 8)); // the first of several
    try testing.expect(d.cut == null);
    try testing.expectEqual(@as(u64, 3), d.lands(40, 8)); // the second: torn
    try testing.expectEqual(Drive.Cut{ .write = 3, .sector = 40, .landed = 3, .of = 8 }, d.cut.?);
    // A keep as large as the write still leaves its last sector unwritten.
    var e = Drive{ .tear = 1, .tear_keep = 99 };
    try testing.expectEqual(@as(u64, 1), e.lands(0, 2));
}

test "a range picks every one in it, and with numbers past eight of them" {
    var s = Schedule.init(1);
    s.named[0] = .one(2);
    s.named[1] = .{ .lo = 5, .hi = 40 };
    s.named[2] = .one(45);
    var picked: usize = 0;
    for (1..60) |n| {
        const p = s.picks();
        const want = n == 2 or (n >= 5 and n <= 40) or n == 45;
        try testing.expectEqual(want, p);
        if (p) picked += 1;
    }
    try testing.expectEqual(@as(u64, 38), s.picked_count);
    try testing.expectEqual(@as(usize, 38), picked);
    // The first eight are remembered by number; the rest only counted.
    try testing.expectEqualSlices(u32, &.{ 2, 5, 6, 7, 8, 9, 10, 11 }, &s.picked);
}

test "PEER_MANGLE: the picked frame arrives after a copy that lies, each kind in turn, and a frame not TCP has none" {
    const frames_zig = @import("frames.zig");
    var w = Wire{};
    w.peer_mangled.named[0] = .{ .lo = 2, .hi = 3 };
    var buf: [256]u8 = undefined;
    const frame = frames_zig.fakeTo(&buf, 80, 0x18, 1, 2, "hello");
    w.hold(frame, 0); // the first: as sent
    w.hold(frame, 0); // the second: a lie, then itself
    w.hold(frame[0..20], 0); // the third: not TCP, so no copy
    const want = [_]bool{ false, true, false, false };
    for (want) |lies| {
        const got = w.ready(0).?;
        try testing.expectEqual(lies, !std.mem.eql(u8, got, frame) and got.len != 20);
        w.take();
    }
    try testing.expectEqual(@as(?[]const u8, null), w.ready(0));
    try testing.expectEqual(@as(u32, 1), w.mangled[0]);
    try testing.expectEqual(@as(u32, 1), w.mangled_not_tcp);
}

test "a full wire counts what it pushes out: a bare ACK apart from a segment the peer would not resend" {
    const frames = @import("frames.zig");
    var w: Wire = .{};
    var buf: [2048]u8 = undefined;
    // The oldest a bare ACK, then a full wire: one more pushes it out.
    w.hold(frames.fakeSegment(&buf, frames.flag_ack, 1, 1, ""), 0);
    for (1..in_flight) |_| w.hold(frames.fakeSegment(&buf, frames.flag_ack, 1, 1, "data"), 0);
    w.hold(frames.fakeSegment(&buf, frames.flag_ack, 1, 1, "more"), 0);
    try std.testing.expectEqual(@as(u64, 1), w.acks_pushed_out);
    try std.testing.expectEqual(@as(u64, 0), w.pushed_out);
    // The oldest now carries data: pushing it out is the loss that counts.
    w.hold(frames.fakeSegment(&buf, frames.flag_ack, 1, 1, "more"), 0);
    try std.testing.expectEqual(@as(u64, 1), w.pushed_out);
}

test "a lying copy pushed out is the knob's, counted apart" {
    const frames = @import("frames.zig");
    var w: Wire = .{};
    var buf: [2048]u8 = undefined;
    w.hold(frames.fakeSegment(&buf, frames.flag_ack, 1, 1, "data"), 0);
    w.held[w.first % in_flight].lie = true; // as `lieFirst` marks its copy
    for (1..in_flight) |_| w.hold(frames.fakeSegment(&buf, frames.flag_ack, 1, 1, "data"), 0);
    w.hold(frames.fakeSegment(&buf, frames.flag_ack, 1, 1, "more"), 0);
    try std.testing.expectEqual(@as(u64, 1), w.lies_pushed_out);
    try std.testing.expectEqual(@as(u64, 0), w.pushed_out);
}
