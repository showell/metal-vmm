//! **THE CLIENT'S FILES**: its request, read whole from the file it was
//! given (`PEER_REQUEST`, never cut short), and what it got, said on stdout in
//! one line a run under QEMU can be compared with, its body and whole answer
//! written to files when asked (`PEER_BODY`, `PEER_RESPONSE`), a short or
//! missing file never silent.

const wire = @import("peer.zig");
const std = @import("std");
const linux = std.os.linux;
const reports = @import("reports.zig");

/// **THE MOST ONE CLIENT'S REQUEST MAY BE** (`PEER_REQUEST`): a whole
/// document past angry-gopher's 1 MiB cap (limits.zig, `body.doc`), so a
/// client can be refused with 413 as well as answered.
pub const request_max = 2 << 20;
/// Each client's request, read from its file. Not on the stack: eight of
/// them are 16 MiB.
pub var request_bufs: [wire.max_clients][request_max]u8 = undefined;

/// **A FILE, WHOLE, OR AN ERROR**: read until its end, however many reads
/// that takes, into `into`. A file larger than `into` is `error.TooLarge`,
/// never its first `into.len` bytes: a request cut short is a different
/// request (QUEUE B23, a 17,000-byte head sent as its first 8,192 bytes).
pub fn readAll(path: [:0]const u8, into: []u8) error{ Unreadable, Empty, TooLarge }![]const u8 {
    const opened = linux.open(path.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(opened) != .SUCCESS) return error.Unreadable;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    var len: usize = 0;
    while (true) {
        if (len == into.len) {
            // Full: the file must end here.
            var one: [1]u8 = undefined;
            const more = linux.read(fd, &one, 1);
            if (linux.errno(more) != .SUCCESS) return error.Unreadable;
            if (more != 0) return error.TooLarge;
            break;
        }
        const n = linux.read(fd, into[len..].ptr, into.len - len);
        if (linux.errno(n) != .SUCCESS) return error.Unreadable;
        if (n == 0) break;
        len += n;
    }
    if (len == 0) return error.Empty;
    return into[0..len];
}

/// **WHAT THE CLIENT GOT, IN ONE LINE** on stdout, so a run here can be
/// compared with a run under QEMU where curl says the same thing; and its
/// body and whole answer to files, when asked (`PEER_BODY`, `PEER_RESPONSE`),
/// every client's. See `reports.client`.
pub fn theClient(environ: std.process.Environ, peer: *const wire.Peer) void {
    // **A REAL PAGE DOES NOT FIT ON A LINE.** The probes answer with a
    // sentence and the line is compared against curl's; a guest serving an
    // actual site answers with kilobytes, so the body goes to a file when one
    // is asked for and the line says how much there was.
    //
    // **AN ANSWER KEPT IN PART IS NOT WRITTEN AS IF WHOLE.** The client keeps
    // the first `reply.len` bytes of what came back. Past that, the files
    // would hold a page's beginning and a comparison of two of them (pc_vs_microvm.sh)
    // would pass on half a page: they are not written, and the line says why,
    // so whatever reads them fails for want of them.
    //
    // **EVERY CLIENT'S ANSWER** (metal-vmm QUEUE 126): client k's goes
    // beside the first's, at `<file>.k` (`reports.answerPath`), so a sweep
    // can hold each client to the same client unhurt.
    const body_stem = environ.getPosix("PEER_BODY");
    const response_stem = environ.getPosix("PEER_RESPONSE");
    if (body_stem != null or response_stem != null) {
        for (0..reports.answered(peer)) |i| {
            const c = peer.clientConst(i);
            if (!reports.keptWhole(c)) {
                var line: [200]u8 = undefined;
                const text = if (i == 0)
                    std.fmt.bufPrint(&line, "metal-vmm: the answer was {d} bytes and the client keeps {d}; PEER_BODY and PEER_RESPONSE are not written\n", .{ c.received, c.reply.len }) catch "metal-vmm: the answer was cut; PEER_BODY and PEER_RESPONSE are not written\n"
                else
                    std.fmt.bufPrint(&line, "metal-vmm: client {d}'s answer was {d} bytes and the client keeps {d}; its PEER_BODY and PEER_RESPONSE are not written\n", .{ i + 1, c.received, c.reply.len }) catch "metal-vmm: a client's answer was cut; its PEER_BODY and PEER_RESPONSE are not written\n";
                _ = linux.write(2, text.ptr, text.len);
                continue;
            }
            var name: [4200]u8 = undefined;
            if (body_stem) |stem| if (reports.answerPath(stem, i, &name)) |into| writeOut(into, c.body()) else writeFailed(stem);
            if (response_stem) |stem| if (reports.answerPath(stem, i, &name)) |into| writeOut(into, c.whole()) else writeFailed(stem);
        }
    }
    var buf: [4096]u8 = undefined;
    const text = reports.client(peer, &buf);
    _ = linux.write(1, text.ptr, text.len);
}

/// Writes `bytes` to `path`, all of them, or says on stderr that it could
/// not: a file left short or missing is never silent.
fn writeOut(path: [:0]const u8, bytes: []const u8) void {
    const opened = linux.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (linux.errno(opened) != .SUCCESS) return writeFailed(path);
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(fd, bytes[done..].ptr, bytes.len - done);
        if (linux.errno(n) != .SUCCESS or n == 0) return writeFailed(path);
        done += n;
    }
}

fn writeFailed(path: [:0]const u8) void {
    var line: [4200]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "metal-vmm: could not write {s} whole\n", .{path}) catch "metal-vmm: could not write an answer's file whole\n";
    _ = linux.write(2, text.ptr, text.len);
}

test "a request file is read whole, past one read's worth, and one too large is refused, not cut" {
    const path = "/tmp/metal-vmm-readall-test";
    var bytes: [20_000]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @truncate(i *% 31);
    const fd = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(fd));
    try std.testing.expectEqual(bytes.len, linux.write(@intCast(fd), &bytes, bytes.len));
    _ = linux.close(@intCast(fd));
    defer _ = linux.unlink(path);

    var room: [32 * 1024]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &bytes, try readAll(path, &room));
    var exact: [20_000]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &bytes, try readAll(path, &exact));
    var small: [8192]u8 = undefined;
    try std.testing.expectError(error.TooLarge, readAll(path, &small));
    try std.testing.expectError(error.Unreadable, readAll("/tmp/metal-vmm-readall-no-such-file", &small));
}
