//! **THE GUEST'S COVERAGE PROPERTIES, READ AS THEY ARE PRINTED.**
//!
//! A gopher-metal kernel built `-Dcoverage` writes zig-coverage-sdk's JSONL
//! to COM1, one event a line behind `coverage: `: an `antithesis_sdk` line
//! when it boots, a declaration (`hit: false`) of every property, then the
//! first pass and the first failure of each (the SDK's `src/coverage.zig`).
//! A script used to grep them out of stdout afterwards. Here the serial port
//! recognizes them as they arrive, which is what an explorer needs: a table
//! of what this run has reached, and when, while the run is still going.
//!
//! - **With `COVERAGE_OUT=<file>`** the lines are kept out of stdout and
//!   appended to that file, as JSONL (the `coverage: ` and any `\r` gone),
//!   the moment each one ends. The SDK's `tools/report.py` reads the file.
//! - **Without it** stdout is exactly what the guest wrote, byte for byte,
//!   and the table is kept all the same.
//!
//! The table is every property's id (its message), its kind, how many times
//! it was seen true and false, and the first of each: at which exit and at
//! what virtual time. A run that printed any coverage line ends with one
//! line on the error stream saying how many properties it reached.

const std = @import("std");

pub const prefix = "coverage: ";

/// When something happened: the exit it happened in, and the machine's time.
pub const When = struct { exit: u64, ns: u64 };

/// The SDK's `display_type`, which says what a property's verdict is.
pub const Kind = enum {
    always,
    always_or_unreachable,
    sometimes,
    reachable,
    @"unreachable",

    fn parse(text: []const u8) ?Kind {
        const names = [_]struct { []const u8, Kind }{
            .{ "Always", .always },
            .{ "AlwaysOrUnreachable", .always_or_unreachable },
            .{ "Sometimes", .sometimes },
            .{ "Reachable", .reachable },
            .{ "Unreachable", .@"unreachable" },
        };
        for (names) |n| if (std.mem.eql(u8, text, n[0])) return n[1];
        return null;
    }
};

pub const Property = struct {
    id_buf: [max_id]u8 = undefined,
    id_len: usize = 0,
    kind: Kind,
    trues: u64 = 0,
    falses: u64 = 0,
    first_true: ?When = null,
    first_false: ?When = null,

    pub fn id(self: *const Property) []const u8 {
        return self.id_buf[0..self.id_len];
    }

    /// Seen at all, true or false.
    pub fn reached(self: *const Property) bool {
        return self.trues + self.falses > 0;
    }

    /// The verdict `tools/report.py` gives it: an Unreachable records being
    /// reached as false, as the SDK writes it.
    pub fn holds(self: *const Property) bool {
        return switch (self.kind) {
            .always => self.reached() and self.falses == 0,
            .always_or_unreachable, .@"unreachable" => self.falses == 0,
            .sometimes, .reachable => self.trues > 0,
        };
    }

    /// Not merely unmet but contradicted: a FAIL, not a MISS.
    pub fn broken(self: *const Property) bool {
        return self.falses > 0 and switch (self.kind) {
            .always, .always_or_unreachable, .@"unreachable" => true,
            .sometimes, .reachable => false,
        };
    }
};

/// Longer than any message gopher-metal declares; a longer one is cut, and
/// two cut alike would share a row.
const max_id = 160;
const max_properties = 512;
/// The SDK's own line buffer is 4096 bytes; this takes the same.
const max_line = 4096;

pub const Table = struct {
    rows: [max_properties]Property = undefined,
    len: usize = 0,
    /// Lines that were coverage lines, boots (`antithesis_sdk` lines), lines
    /// that were not the JSON they should be, and properties past the table.
    lines: u64 = 0,
    boots: u64 = 0,
    malformed: u64 = 0,
    dropped: u64 = 0,

    pub fn find(self: *Table, id: []const u8) ?*Property {
        const cut = id[0..@min(id.len, max_id)];
        for (self.rows[0..self.len]) |*p| if (std.mem.eql(u8, p.id(), cut)) return p;
        return null;
    }

    pub fn reached(self: *const Table) usize {
        var n: usize = 0;
        for (self.rows[0..self.len]) |*p| n += @intFromBool(p.reached());
        return n;
    }

    pub fn holding(self: *const Table) usize {
        var n: usize = 0;
        for (self.rows[0..self.len]) |*p| n += @intFromBool(p.holds());
        return n;
    }

    pub fn broken(self: *const Table) usize {
        var n: usize = 0;
        for (self.rows[0..self.len]) |*p| n += @intFromBool(p.broken());
        return n;
    }

    /// One event's JSON, as the SDK writes it, into the table.
    pub fn take(self: *Table, json: []const u8, at: When) void {
        self.lines += 1;
        var scratch: [4 * max_line]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&scratch);
        const value = std.json.parseFromSliceLeaky(std.json.Value, fba.allocator(), json, .{}) catch {
            self.malformed += 1;
            return;
        };
        if (value != .object) {
            self.malformed += 1;
            return;
        }
        if (value.object.get("antithesis_sdk") != null) {
            self.boots += 1;
            return;
        }
        // A numeric comparison's guidance line (the SDK's
        // `alwaysGreaterThan` and the rest): its assertion has a line of its
        // own, which is what the table counts.
        if (value.object.get("antithesis_guidance") != null) return;
        const event = value.object.get("antithesis_assert") orelse {
            self.malformed += 1;
            return;
        };
        if (event != .object) {
            self.malformed += 1;
            return;
        }
        const e = event.object;
        const id = text(e.get("id")) orelse return self.bad();
        const kind = Kind.parse(text(e.get("display_type")) orelse return self.bad()) orelse return self.bad();
        const hit = flag(e.get("hit")) orelse return self.bad();
        const condition = flag(e.get("condition")) orelse return self.bad();

        const p = self.find(id) orelse blk: {
            if (self.len == self.rows.len) {
                self.dropped += 1;
                return;
            }
            const row = &self.rows[self.len];
            self.len += 1;
            row.* = .{ .kind = kind };
            row.id_len = @min(id.len, max_id);
            @memcpy(row.id_buf[0..row.id_len], id[0..row.id_len]);
            break :blk row;
        };
        if (!hit) return; // a declaration
        if (condition) {
            p.trues += 1;
            if (p.first_true == null) p.first_true = at;
        } else {
            p.falses += 1;
            if (p.first_false == null) p.first_false = at;
        }
    }

    fn bad(self: *Table) void {
        self.malformed += 1;
    }

    fn text(v: ?std.json.Value) ?[]const u8 {
        const value = v orelse return null;
        return if (value == .string) value.string else null;
    }

    fn flag(v: ?std.json.Value) ?bool {
        const value = v orelse return null;
        return if (value == .bool) value.bool else null;
    }
};

/// **THE SERIAL PORT'S READER.** Bytes go in as the guest writes them, a
/// handful at a time; what goes to stdout and what goes to the JSONL comes
/// out through `out`, which has `stdout(bytes)` and `jsonl(line)`.
pub const Serial = struct {
    /// Keep coverage lines out of stdout (and send them to `jsonl`).
    withhold: bool = false,
    state: enum { matching, passing, covering } = .matching,
    /// How much of `prefix` the current line has matched so far.
    matched: usize = 0,
    line: [max_line]u8 = undefined,
    line_len: usize = 0,
    /// The current coverage line ran past `max_line`: it is malformed.
    overflowed: bool = false,
    /// **THE COVERAGE DOOR'S LINE** (`door`): apart from the serial port's,
    /// since the guest's console may be mid-line when one arrives.
    door_line: [max_line]u8 = undefined,
    door_len: usize = 0,
    door_overflowed: bool = false,
    table: Table = .{},

    pub fn feed(self: *Serial, bytes: []const u8, at: When, out: anytype) void {
        // Withholding nothing, stdout is the guest's bytes as they came.
        if (!self.withhold) out.stdout(bytes);
        var kept: [prefix.len + 64]u8 = undefined;
        var kept_len: usize = 0;
        for (bytes) |b| {
            switch (self.state) {
                .matching => if (b == prefix[self.matched]) {
                    self.matched += 1;
                    if (self.matched == prefix.len) {
                        self.state = .covering;
                        self.line_len = 0;
                        self.overflowed = false;
                    }
                    continue;
                } else {
                    // Not a coverage line: what was held back of it goes out
                    // first, then this byte as an ordinary one.
                    if (self.withhold) {
                        flushIf(out, &kept, &kept_len, self.matched + 1);
                        @memcpy(kept[kept_len..][0..self.matched], prefix[0..self.matched]);
                        kept_len += self.matched;
                    }
                    self.matched = 0;
                    self.state = .passing;
                },
                .passing => {},
                .covering => {
                    if (b == '\n') {
                        self.endLine(at, out);
                        continue;
                    }
                    if (self.line_len < self.line.len) {
                        self.line[self.line_len] = b;
                        self.line_len += 1;
                    } else self.overflowed = true;
                    continue;
                },
            }
            // An ordinary byte.
            if (self.withhold) {
                flushIf(out, &kept, &kept_len, 1);
                kept[kept_len] = b;
                kept_len += 1;
            }
            if (b == '\n') self.state = .matching;
        }
        if (self.withhold and kept_len > 0) out.stdout(kept[0..kept_len]);
    }

    fn flushIf(out: anytype, kept: []u8, kept_len: *usize, need: usize) void {
        if (kept_len.* + need <= kept.len) return;
        out.stdout(kept[0..kept_len.*]);
        kept_len.* = 0;
    }

    /// **BYTES FROM THE COVERAGE DOOR** (main.zig `coverage_door`): the
    /// SDK's JSONL lines whole, with no `coverage: ` before them, from a
    /// kernel that found the door. Read into the same table as the serial
    /// port's lines; withheld, each goes to the JSONL, and otherwise to
    /// stdout as the serial port would have shown it.
    pub fn door(self: *Serial, bytes: []const u8, at: When, out: anytype) void {
        for (bytes) |b| {
            if (b != '\n') {
                if (self.door_len < self.door_line.len) {
                    self.door_line[self.door_len] = b;
                    self.door_len += 1;
                } else self.door_overflowed = true;
                continue;
            }
            var json = self.door_line[0..self.door_len];
            if (json.len > 0 and json[json.len - 1] == '\r') json = json[0 .. json.len - 1];
            if (self.door_overflowed) {
                self.table.lines += 1;
                self.table.malformed += 1;
            } else self.table.take(json, at);
            if (self.withhold) out.jsonl(json) else {
                out.stdout(prefix);
                out.stdout(json);
                out.stdout("\n");
            }
            self.door_len = 0;
            self.door_overflowed = false;
        }
    }

    fn endLine(self: *Serial, at: When, out: anytype) void {
        var json = self.line[0..self.line_len];
        if (json.len > 0 and json[json.len - 1] == '\r') json = json[0 .. json.len - 1];
        if (self.overflowed) {
            self.table.lines += 1;
            self.table.malformed += 1;
        } else self.table.take(json, at);
        if (self.withhold) out.jsonl(json);
        self.state = .matching;
        self.matched = 0;
        self.line_len = 0;
    }

    /// The run's last word on its coverage, if it printed any.
    pub fn summary(self: *const Serial, buf: []u8) ?[]const u8 {
        const t = &self.table;
        if (t.lines == 0) return null;
        return std.fmt.bufPrint(buf, "metal-vmm: coverage: {d} of {d} properties reached ({d} hold, {d} broken), from {d} lines over {d} boots{s}\n", .{
            t.reached(),                                                               t.len, t.holding(), t.broken(), t.lines, t.boots,
            if (t.malformed + t.dropped > 0) "; some lines could not be read" else "",
        }) catch null;
    }
};

// ── many runs, one table ─────────────────────────────────────────────────────

/// **WHAT NAMES A RUN IN A JSONL OF MANY**: a line of its own, written by
/// this program when `COVERAGE_OUT` opens, before the guest's first. The
/// SDK's `tools/report.py` reads it as the start of a run, however many
/// times its guest boots, and names the run by its seed or its knobs.
pub const run_key = "metal_vmm_run";

/// `{"metal_vmm_run":{"seed":4711,"knobs":"WIRE_EAT=3"}}`, the seed null when
/// the run had none.
pub fn runLine(buf: []u8, seed: ?u64, knobs: []const u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.writeAll("{\"" ++ run_key ++ "\":{\"seed\":");
    if (seed) |n| try w.print("{d}", .{n}) else try w.writeAll("null");
    try w.writeAll(",\"knobs\":");
    try std.json.Stringify.encodeJsonString(knobs, .{}, &w);
    try w.writeAll("}}");
    return w.buffered();
}

// ── what can be checked without a guest ──────────────────────────────────────

const testing = std.testing;

/// What came out, gathered.
const Captured = struct {
    out: [8192]u8 = undefined,
    out_len: usize = 0,
    jsonl_buf: [8192]u8 = undefined,
    jsonl_len: usize = 0,

    pub fn stdout(self: *Captured, bytes: []const u8) void {
        @memcpy(self.out[self.out_len..][0..bytes.len], bytes);
        self.out_len += bytes.len;
    }

    pub fn jsonl(self: *Captured, line: []const u8) void {
        @memcpy(self.jsonl_buf[self.jsonl_len..][0..line.len], line);
        self.jsonl_len += line.len;
        self.jsonl_buf[self.jsonl_len] = '\n';
        self.jsonl_len += 1;
    }

    fn printed(self: *const Captured) []const u8 {
        return self.out[0..self.out_len];
    }

    fn written(self: *const Captured) []const u8 {
        return self.jsonl_buf[0..self.jsonl_len];
    }
};

/// As the SDK writes them (its `writeLine`), less the location.
const boot = "{\"antithesis_sdk\":{\"language\":{\"name\":\"Zig\",\"version\":\"0.16.0\"},\"sdk_version\":\"0.0.1\",\"protocol_version\":\"1.1.0\"}}";

fn sdkEvent(comptime display: []const u8, comptime id: []const u8, comptime hit: bool, comptime cond: bool) []const u8 {
    return std.fmt.comptimePrint("{{\"antithesis_assert\":{{\"hit\":{},\"must_hit\":true,\"assert_type\":\"x\",\"display_type\":\"{s}\",\"message\":\"{s}\",\"condition\":{},\"id\":\"{s}\",\"location\":{{\"class\":\"tcp\",\"function\":\"f\",\"file\":\"tcp.zig\",\"begin_line\":1,\"begin_column\":1}}}}}}", .{ hit, display, id, cond, id });
}

/// Feeds `text` a byte at a time, as the guest writes it.
fn byBytes(s: *Serial, text: []const u8, at: When, c: *Captured) void {
    for (0..text.len) |i| s.feed(text[i..][0..1], at, c);
}

test "without COVERAGE_OUT, stdout is the guest's bytes exactly, and the table is kept" {
    var s = Serial{};
    var c = Captured{};
    const text = "hello\r\n" ++ prefix ++ comptime sdkEvent("Sometimes", "tcp: x", true, true) ++ "\r\ncover me\n";
    byBytes(&s, text, .{ .exit = 7, .ns = 100 }, &c);
    try testing.expectEqualStrings(text, c.printed());
    try testing.expectEqualStrings("", c.written());
    try testing.expectEqual(@as(usize, 1), s.table.reached());
}

test "with COVERAGE_OUT, coverage lines go to the JSONL and nothing else does" {
    var s = Serial{ .withhold = true };
    var c = Captured{};
    const a = comptime sdkEvent("Sometimes", "tcp: x", false, false);
    const b = comptime sdkEvent("Sometimes", "tcp: x", true, true);
    const text = "gopher-metal\r\n" ++ prefix ++ boot ++ "\r\n" ++ prefix ++ a ++ "\r\n" ++
        "covered: no\ncoverage:not quite\n" ++ prefix ++ b ++ "\n" ++ "listening on port 80\n";
    byBytes(&s, text, .{ .exit = 1, .ns = 1 }, &c);
    try testing.expectEqualStrings("gopher-metal\r\ncovered: no\ncoverage:not quite\nlistening on port 80\n", c.printed());
    try testing.expectEqualStrings(boot ++ "\n" ++ a ++ "\n" ++ b ++ "\n", c.written());
}

test "the same, whatever the bytes arrive in: all at once or a byte at a time" {
    const text = "a\n" ++ prefix ++ comptime sdkEvent("Always", "an always", true, true) ++ "\r\nb\ncov\n";
    var whole = Serial{ .withhold = true };
    var w = Captured{};
    whole.feed(text, .{ .exit = 1, .ns = 1 }, &w);
    var bytes = Serial{ .withhold = true };
    var b = Captured{};
    byBytes(&bytes, text, .{ .exit = 1, .ns = 1 }, &b);
    try testing.expectEqualStrings("a\nb\ncov\n", w.printed());
    try testing.expectEqualStrings(w.printed(), b.printed());
    try testing.expectEqualStrings(w.written(), b.written());
}

test "the table: declared, then the first true and first false, with their exit and time" {
    var s = Serial{ .withhold = true };
    var c = Captured{};
    byBytes(&s, prefix ++ boot ++ "\n", .{ .exit = 1, .ns = 10 }, &c);
    byBytes(&s, prefix ++ comptime sdkEvent("Sometimes", "tcp: a lost SYN-ACK is sent again", false, false) ++ "\n", .{ .exit = 1, .ns = 10 }, &c);
    byBytes(&s, prefix ++ comptime sdkEvent("Always", "tcp: an RTO is bounded", false, false) ++ "\n", .{ .exit = 1, .ns = 10 }, &c);
    try testing.expectEqual(@as(usize, 2), s.table.len);
    try testing.expectEqual(@as(usize, 0), s.table.reached());

    byBytes(&s, prefix ++ comptime sdkEvent("Sometimes", "tcp: a lost SYN-ACK is sent again", true, false) ++ "\n", .{ .exit = 50, .ns = 2000 }, &c);
    byBytes(&s, prefix ++ comptime sdkEvent("Sometimes", "tcp: a lost SYN-ACK is sent again", true, true) ++ "\n", .{ .exit = 90, .ns = 3000 }, &c);
    byBytes(&s, prefix ++ comptime sdkEvent("Always", "tcp: an RTO is bounded", true, true) ++ "\n", .{ .exit = 60, .ns = 2500 }, &c);
    const syn = s.table.find("tcp: a lost SYN-ACK is sent again").?;
    try testing.expectEqual(Kind.sometimes, syn.kind);
    try testing.expectEqual(When{ .exit = 90, .ns = 3000 }, syn.first_true.?);
    try testing.expectEqual(When{ .exit = 50, .ns = 2000 }, syn.first_false.?);
    try testing.expect(syn.holds() and !syn.broken());
    try testing.expectEqual(@as(usize, 2), s.table.reached());
    try testing.expectEqual(@as(usize, 2), s.table.holding());
    try testing.expectEqual(@as(u64, 1), s.table.boots);

    // An Always seen false is broken: a FAIL, which the summary says.
    byBytes(&s, prefix ++ comptime sdkEvent("Always", "tcp: an RTO is bounded", true, false) ++ "\n", .{ .exit = 70, .ns = 2600 }, &c);
    try testing.expectEqual(@as(usize, 1), s.table.broken());
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("metal-vmm: coverage: 2 of 2 properties reached (1 hold, 1 broken), from 7 lines over 1 boots\n", s.summary(&buf).?);
}

test "the SDK's verdicts, as tools/report.py gives them" {
    var p = Property{ .kind = .@"unreachable" };
    try testing.expect(p.holds());
    p.falses = 1; // reached: the SDK records it as false
    try testing.expect(!p.holds() and p.broken());
    var q = Property{ .kind = .always };
    try testing.expect(!q.holds() and !q.broken()); // a MISS
    var r = Property{ .kind = .sometimes, .falses = 3 };
    try testing.expect(!r.holds() and !r.broken()); // a MISS, though reached
    try testing.expect(r.reached());
    var u = Property{ .kind = .always_or_unreachable };
    try testing.expect(u.holds());
}

test "a line that is not the SDK's JSON is counted, kept in the JSONL, and says so" {
    var s = Serial{ .withhold = true };
    var c = Captured{};
    byBytes(&s, prefix ++ "{not json\n" ++ prefix ++ "{\"other\":1}\n", .{ .exit = 1, .ns = 1 }, &c);
    try testing.expectEqual(@as(u64, 2), s.table.malformed);
    try testing.expectEqualStrings("{not json\n{\"other\":1}\n", c.written());
    var buf: [256]u8 = undefined;
    try testing.expect(std.mem.endsWith(u8, s.summary(&buf).?, "could not be read\n"));
}

test "a comparison's guidance line is the SDK's, kept in the JSONL, and not counted as unreadable" {
    var s = Serial{ .withhold = true };
    var c = Captured{};
    const g = "{\"antithesis_guidance\":{\"guidance_data\":{\"left\":2,\"right\":2},\"guidance_type\":\"numeric\",\"message\":\"slots\",\"id\":\"slots\",\"maximize\":true,\"hit\":true}}";
    byBytes(&s, prefix ++ g ++ "\n", .{ .exit = 1, .ns = 1 }, &c);
    try testing.expectEqual(@as(u64, 0), s.table.malformed);
    try testing.expectEqualStrings(g ++ "\n", c.written());
}

test "a run that printed no coverage line says nothing about it" {
    var s = Serial{};
    var c = Captured{};
    s.feed("PASS\n", .{ .exit = 1, .ns = 1 }, &c);
    var buf: [256]u8 = undefined;
    try testing.expect(s.summary(&buf) == null);
}

test "a run line names its seed, or its knobs" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("{\"metal_vmm_run\":{\"seed\":4711,\"knobs\":\"WIRE_EAT=3\"}}", try runLine(&buf, 4711, "WIRE_EAT=3"));
    try testing.expectEqualStrings("{\"metal_vmm_run\":{\"seed\":null,\"knobs\":\"none\"}}", try runLine(&buf, null, "none"));
}

test "the coverage door: whole lines, no prefix, into the same table; withheld to the JSONL, else shown as the serial port shows them" {
    const Out = struct {
        shown: std.ArrayList(u8) = .empty,
        kept: std.ArrayList(u8) = .empty,
        pub fn stdout(self: *@This(), bytes: []const u8) void {
            self.shown.appendSlice(std.testing.allocator, bytes) catch unreachable;
        }
        pub fn jsonl(self: *@This(), line: []const u8) void {
            self.kept.appendSlice(std.testing.allocator, line) catch unreachable;
            self.kept.append(std.testing.allocator, '\n') catch unreachable;
        }
    };
    const line = "{\"antithesis_assert\":{\"id\":\"a\",\"message\":\"a\",\"condition\":true,\"display_type\":\"Always\",\"hit\":true,\"must_hit\":true,\"assert_type\":\"always\",\"location\":{},\"details\":null}}";
    var out: Out = .{};
    defer out.shown.deinit(std.testing.allocator);
    defer out.kept.deinit(std.testing.allocator);
    var s: Serial = .{ .withhold = true };
    // A console line half printed, then a door line in two pieces.
    s.feed("half a line", .{ .exit = 1, .ns = 1 }, &out);
    s.door(line[0..10], .{ .exit = 2, .ns = 2 }, &out);
    s.door(line[10..] ++ "\n", .{ .exit = 3, .ns = 3 }, &out);
    s.feed(" ends\n", .{ .exit = 4, .ns = 4 }, &out);
    try std.testing.expectEqualStrings("half a line ends\n", out.shown.items);
    try std.testing.expectEqualStrings(line ++ "\n", out.kept.items);
    try std.testing.expectEqual(@as(u64, 1), s.table.lines);
    try std.testing.expect(s.table.find("a") != null);

    var plain: Serial = .{};
    var out2: Out = .{};
    defer out2.shown.deinit(std.testing.allocator);
    defer out2.kept.deinit(std.testing.allocator);
    plain.door(line ++ "\n", .{ .exit = 1, .ns = 1 }, &out2);
    try std.testing.expectEqualStrings(prefix ++ line ++ "\n", out2.shown.items);
    try std.testing.expectEqual(@as(usize, 0), out2.kept.items.len);
}
