//! **RANDOMNESS THAT REPEATS**, which is a contradiction everywhere except
//! here.
//!
//! A guest needs entropy — gopher-metal mints session tokens with it, and
//! refuses to invent one out of a clock. A deterministic machine needs every
//! byte of that entropy to be the same on the next run. Both are satisfied by
//! the same thing: a generator seeded from a number this program chose, which
//! is good enough to mint a token from and reproducible because we know the
//! seed.
//!
//! **THIS IS ALSO WHY THE PROCESSOR HAS NO `RDRAND`.** The guest mixes two
//! sources with SHA-256 — this device and the instruction — precisely so that
//! one broken source cannot show through. Mixing is the problem here: one
//! unrepeatable source makes the whole draw unrepeatable. So `main.zig` clears
//! RDRAND and RDSEED out of the CPUID it hands the vCPU, and this machine
//! simply does not have those instructions. The guest is built for that: it
//! prints which sources it found, and stops only if it finds none.

const std = @import("std");
const virtio = @import("virtio.zig");

/// **THE SEED IS THE RUN'S NAME.** One number, and every draw the guest ever
/// makes follows from it. When replay arrives this is what gets varied, and
/// the only thing that has to be written down to repeat a failure.
pub const seed: u64 = 0x6D_76_6D_6D_73_65_65_64; // "mvmmseed"

pub const Entropy = struct {
    prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(seed),
    drawn: u64 = 0,

    /// virtio-rng has one queue and no configuration at all: a buffer offered
    /// to it comes back filled with however many bytes the host had ready.
    /// Ours is always ready.
    pub fn device(self: *Entropy) virtio.Device {
        return .{ .id = virtio.device_id_entropy, .context = self, .notified = notified };
    }

    fn notified(context: *anyopaque, d: *virtio.Device, ram: []u8, queue: u32) void {
        const self: *Entropy = @ptrCast(@alignCast(context));
        var links: [4]virtio.Desc = undefined;
        while (d.take(ram, queue, &links)) |chain| {
            var written: u32 = 0;
            for (chain.links) |link| {
                if (link.flags & virtio.Desc.write_flag == 0) continue;
                const into = virtio.buffer(ram, link);
                self.prng.random().bytes(into);
                written += @intCast(into.len);
            }
            self.drawn += written;
            d.complete(ram, queue, chain.head, written);
        }
    }
};

// ── what can be checked without a guest ──────────────────────────────────────

const testing = std.testing;

test "the same seed gives the same bytes, and they are not one byte repeated" {
    var a = Entropy{};
    var b = Entropy{};
    var from_a: [64]u8 = undefined;
    var from_b: [64]u8 = undefined;
    a.prng.random().bytes(&from_a);
    b.prng.random().bytes(&from_b);
    try testing.expectEqualSlices(u8, &from_a, &from_b);

    var counts: [256]u16 = @splat(0);
    for (from_a) |x| counts[x] += 1;
    for (counts) |c| try testing.expect(c < 8); // 64 bytes over 256 values
}

test "a guest's buffer comes back filled, and the used ring says how much" {
    var card = Entropy{};
    var d = card.device();
    try testing.expectEqual(virtio.device_id_entropy, @as(u32, @intCast(d.read(0x008, 4))));

    // One write-only descriptor, offered the way gopher-metal's rng.zig does.
    var ram: [4096]u8 align(8) = @splat(0);
    const desc_at: u64 = 0x100;
    const avail_at: u64 = 0x200;
    const used_at: u64 = 0x300;
    const buf_at: u64 = 0x400;
    const want: u32 = 32;

    d.write(&ram, 0x030, 0); // queue select
    d.write(&ram, 0x038, 4); // queue size
    d.write(&ram, 0x080, @intCast(desc_at));
    d.write(&ram, 0x090, @intCast(avail_at));
    d.write(&ram, 0x0a0, @intCast(used_at));
    d.write(&ram, 0x044, 1); // queue ready

    virtio.writeInt(u64, &ram, desc_at, buf_at);
    virtio.writeInt(u32, &ram, desc_at + 8, want);
    virtio.writeInt(u16, &ram, desc_at + 12, virtio.Desc.write_flag);
    virtio.writeInt(u16, &ram, avail_at + 2, 1); // one entry available
    virtio.writeInt(u16, &ram, avail_at + 4, 0); // descriptor 0
    d.write(&ram, 0x050, 0); // the doorbell

    try testing.expectEqual(@as(u16, 1), virtio.readInt(u16, &ram, used_at + 2));
    try testing.expectEqual(want, virtio.readInt(u32, &ram, used_at + 8));
    var all_zero = true;
    for (ram[buf_at..][0..want]) |x| {
        if (x != 0) all_zero = false;
    }
    try testing.expect(!all_zero);
    try testing.expectEqual(@as(u64, want), card.drawn);
}
