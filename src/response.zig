//! **WHERE ONE HTTP ANSWER ENDS**, for the peer's clients (client.zig).

const std = @import("std");
const testing = std.testing;

/// **WHERE ONE HTTP ANSWER ENDS** (RFC 9112 §6.3), read a byte at a time as
/// it arrives, so an answer of any size is followed without being kept: by
/// its Content-Length, by its chunks, or, with neither, not until the server
/// closes the connection. A stream that never ends is an answer that is
/// never whole, and its client reads it for as long as it lasts.
pub const Response = struct {
    phase: enum { head, length, chunk_size, chunk_data, chunk_end, trailer, to_close, done } = .head,
    /// The head so far, until its blank line.
    head: [4096]u8 = undefined,
    head_len: usize = 0,
    /// Body bytes left: of the whole length, or of the chunk.
    left: u64 = 0,
    /// Within a chunk-size line or a trailer line: the size so far, whether
    /// past an extension, and the line's length.
    size: u64 = 0,
    in_extension: bool = false,
    line_len: usize = 0,

    /// Takes bytes until the answer is whole; answers how many it took.
    pub fn feed(self: *Response, bytes: []const u8) usize {
        for (bytes, 0..) |b, i| {
            switch (self.phase) {
                .head => {
                    if (self.head_len < self.head.len) {
                        self.head[self.head_len] = b;
                        self.head_len += 1;
                    } else {
                        self.phase = .to_close; // a head past all reason
                        continue;
                    }
                    if (std.mem.endsWith(u8, self.head[0..self.head_len], "\r\n\r\n")) self.headDone();
                },
                .length => {
                    self.left -= 1;
                    if (self.left == 0) self.phase = .done;
                },
                .chunk_size => {
                    if (b == '\n') {
                        if (self.size == 0) {
                            self.phase = .trailer;
                            self.line_len = 0;
                        } else {
                            self.left = self.size;
                            self.phase = .chunk_data;
                        }
                        self.size = 0;
                        self.in_extension = false;
                    } else if (b == ';') {
                        self.in_extension = true;
                    } else if (!self.in_extension) {
                        if (std.fmt.charToDigit(b, 16)) |d| {
                            self.size = self.size *% 16 +% d;
                        } else |_| {}
                    }
                },
                .chunk_data => {
                    self.left -= 1;
                    if (self.left == 0) self.phase = .chunk_end;
                },
                .chunk_end => if (b == '\n') {
                    self.phase = .chunk_size;
                },
                .trailer => {
                    if (b == '\n') {
                        if (self.line_len == 0) self.phase = .done;
                        self.line_len = 0;
                    } else if (b != '\r') self.line_len += 1;
                },
                .to_close => {},
                .done => return i,
            }
            if (self.phase == .done) return i + 1;
        }
        return bytes.len;
    }

    /// The server closed the connection: an answer read to the close is
    /// whole now.
    pub fn closed(self: *Response) void {
        if (self.phase == .to_close) self.phase = .done;
    }

    fn headDone(self: *Response) void {
        const head = self.head[0..self.head_len];
        const code = statusOf(head);
        // No body at all: 1xx, 204 and 304.
        if ((code >= 100 and code < 200) or code == 204 or code == 304) {
            self.phase = .done;
            return;
        }
        if (header(head, "transfer-encoding")) |te| if (std.ascii.indexOfIgnoreCase(te, "chunked") != null) {
            self.phase = .chunk_size;
            return;
        };
        if (header(head, "content-length")) |cl| {
            self.left = std.fmt.parseInt(u64, std.mem.trim(u8, cl, " \t"), 10) catch {
                self.phase = .to_close;
                return;
            };
            self.phase = if (self.left == 0) .done else .length;
            return;
        }
        self.phase = .to_close;
    }

    fn statusOf(head: []const u8) u16 {
        const space = std.mem.indexOfScalar(u8, head, ' ') orelse return 0;
        if (space + 4 > head.len) return 0;
        return std.fmt.parseInt(u16, head[space + 1 ..][0..3], 10) catch 0;
    }

    /// A header's value, its name matched without regard to case.
    fn header(head: []const u8, name: []const u8) ?[]const u8 {
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        _ = lines.next(); // the status line
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(line[0..colon], name)) return line[colon + 1 ..];
        }
        return null;
    }
};

test "where an answer ends: its length, its chunks, its close, or nothing to read" {
    var r = Response{};
    const sized = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhelloHTTP/1.1";
    try testing.expectEqual(@as(usize, sized.len - 8), r.feed(sized));
    try testing.expect(r.phase == .done);

    // The same, a byte at a time, and the header's name in another case.
    var b = Response{};
    const again = "HTTP/1.1 200 OK\r\ncontent-LENGTH:  3\r\n\r\nabc";
    for (again, 0..) |_, i| {
        try testing.expect(b.phase != .done);
        _ = b.feed(again[i..][0..1]);
    }
    try testing.expect(b.phase == .done);

    // Chunks, with an extension and a trailer (RFC 9112 §7.1).
    var c = Response{};
    const chunked = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4;x=y\r\nWiki\r\n5\r\npedia\r\n0\r\nT: 1\r\n\r\n";
    try testing.expectEqual(chunked.len, c.feed(chunked ++ "next"));
    try testing.expect(c.phase == .done);

    // No length, no chunks: whole only when the server closes.
    var d = Response{};
    _ = d.feed("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\ndata: 1\n\ndata: 2\n\n");
    try testing.expect(d.phase == .to_close);
    d.closed();
    try testing.expect(d.phase == .done);

    // 204 and 304 have no body.
    var e = Response{};
    _ = e.feed("HTTP/1.1 304 Not Modified\r\nContent-Length: 99\r\n\r\n");
    try testing.expect(e.phase == .done);
}
