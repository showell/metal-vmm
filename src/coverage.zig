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
/// SDK's `tools/report.py` passes over it, as over any line that is not an
/// assertion.
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

/// **THE EXPLORER'S MEMORY**: every property over many runs, which run
/// reached it first, how many runs reached it, and so which ones only one
/// run ever did, the rare ones worth steering toward.
///
/// A run is a `metal_vmm_run` line and what follows it, however many times
/// its guest boots. A file with no such line, such as the judge's
/// `sdk.jsonl`, is a run per boot (`antithesis_sdk` line).
pub const Merged = struct {
    pub const Row = struct {
        property: Property,
        runs: u32 = 0,
        first_run: u32 = 0,
        /// The last run counted in `runs`, so a run counts once.
        last_run: ?u32 = null,

        pub fn rare(self: *const Row) bool {
            return self.runs == 1;
        }
    };

    allocator: std.mem.Allocator,
    /// Each run's name: its seed, else its knobs, else where it was found.
    runs: std.ArrayList([]const u8) = .empty,
    rows: std.StringArrayHashMapUnmanaged(Row) = .empty,
    malformed: u64 = 0,
    /// Within the file being read: whether its runs are marked, and its boots.
    marked: bool = false,
    boots: u32 = 0,
    in_run: bool = false,

    pub fn init(allocator: std.mem.Allocator) Merged {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Merged) void {
        for (self.runs.items) |name| self.allocator.free(name);
        self.runs.deinit(self.allocator);
        for (self.rows.keys()) |id| self.allocator.free(id);
        self.rows.deinit(self.allocator);
    }

    /// One file's lines, `name` saying where they came from.
    pub fn addFile(self: *Merged, name: []const u8, text: []const u8) !void {
        self.marked = false;
        self.boots = 0;
        self.in_run = false;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0) continue;
            try self.addLine(name, line);
        }
    }

    fn startRun(self: *Merged, owned_name: []const u8) !void {
        try self.runs.append(self.allocator, owned_name);
        self.in_run = true;
    }

    fn addLine(self: *Merged, file: []const u8, line: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), line, .{}) catch {
            self.malformed += 1;
            return;
        };
        if (value != .object) {
            self.malformed += 1;
            return;
        }
        if (value.object.get(run_key)) |run| {
            self.marked = true;
            try self.startRun(try self.runName(run, file));
            return;
        }
        if (value.object.get("antithesis_sdk") != null) {
            self.boots += 1;
            if (!self.marked) try self.startRun(try std.fmt.allocPrint(self.allocator, "{s}, boot {d}", .{ file, self.boots }));
            return;
        }
        const event = value.object.get("antithesis_assert") orelse return;
        if (event != .object) {
            self.malformed += 1;
            return;
        }
        const e = event.object;
        const id = Table.text(e.get("id")) orelse return self.bad();
        const kind = Kind.parse(Table.text(e.get("display_type")) orelse return self.bad()) orelse return self.bad();
        const hit = Table.flag(e.get("hit")) orelse return self.bad();
        const condition = Table.flag(e.get("condition")) orelse return self.bad();
        if (!self.in_run) try self.startRun(try self.allocator.dupe(u8, file));
        const run: u32 = @intCast(self.runs.items.len - 1);

        const slot = try self.rows.getOrPut(self.allocator, id);
        if (!slot.found_existing) {
            slot.key_ptr.* = try self.allocator.dupe(u8, id);
            slot.value_ptr.* = .{ .property = .{ .kind = kind } };
        }
        const row = slot.value_ptr;
        if (!hit) return;
        if (condition) row.property.trues += 1 else row.property.falses += 1;
        if (row.last_run != run) {
            if (row.runs == 0) row.first_run = run;
            row.runs += 1;
            row.last_run = run;
        }
    }

    fn bad(self: *Merged) void {
        self.malformed += 1;
    }

    fn runName(self: *Merged, run: std.json.Value, file: []const u8) ![]const u8 {
        if (run == .object) {
            if (run.object.get("seed")) |seed| if (seed == .integer) return std.fmt.allocPrint(self.allocator, "FAULT_SEED={d}", .{seed.integer});
            if (Table.text(run.object.get("knobs"))) |k| return self.allocator.dupe(u8, k);
        }
        return std.fmt.allocPrint(self.allocator, "{s}, run {d}", .{ file, self.runs.items.len + 1 });
    }

    /// **THE TABLE, AND THE FLOOR'S VERDICT.** Every property, contradicted
    /// ones first, then missed, then holding: its verdict, kind, how many runs
    /// reached it and which first. Then the rare ones. With a `floor` (one
    /// message a line, `#` for comments, as `tools/report.py --floor` reads
    /// it), a floor property missed fails, and so does a floor line naming no
    /// property: a floor gone stale. Answers whether the runs pass: no FAIL
    /// and, with a floor, nothing under it.
    pub fn report(self: *const Merged, w: *std.Io.Writer, floor: ?[]const u8) !bool {
        var broken: usize = 0;
        var missed: usize = 0;
        var holding: usize = 0;
        for ([_]u8{ 0, 1, 2 }) |pass| {
            var it = self.rows.iterator();
            while (it.next()) |entry| {
                const row = entry.value_ptr;
                const p = &row.property;
                const band: u8 = if (p.broken()) 0 else if (!p.holds()) 1 else 2;
                if (band != pass) continue;
                switch (band) {
                    0 => broken += 1,
                    1 => missed += 1,
                    else => holding += 1,
                }
                try w.print("{s} {s:<19} {s}  ({d} of {d} runs", .{
                    ([_][]const u8{ "FAIL", "MISS", "ok  " })[band], displayName(p.kind), entry.key_ptr.*, row.runs, self.runs.items.len,
                });
                if (row.runs > 0) try w.print(", first {s}", .{self.runs.items[row.first_run]});
                try w.writeAll(")\n");
            }
        }
        var rare: usize = 0;
        var it = self.rows.iterator();
        while (it.next()) |entry| if (entry.value_ptr.rare()) {
            if (rare == 0) try w.writeAll("\nreached by one run only:\n");
            rare += 1;
            try w.print("  {s}  ({s})\n", .{ entry.key_ptr.*, self.runs.items[entry.value_ptr.first_run] });
        };
        try w.print("\n{d} runs, {d} properties: {d} hold, {d} missed, {d} broken; {d} rare", .{
            self.runs.items.len, self.rows.count(), holding, missed, broken, rare,
        });
        if (self.malformed > 0) try w.print("; {d} lines could not be read", .{self.malformed});
        try w.writeAll("\n");

        var under: usize = 0;
        var stale: usize = 0;
        if (floor) |text| {
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |raw| {
                const line = std.mem.trim(u8, raw, " \t\r");
                if (line.len == 0 or line[0] == '#') continue;
                const row = self.rows.getPtr(line) orelse {
                    stale += 1;
                    try w.print("floor: STALE {s} (no run declared it)\n", .{line});
                    continue;
                };
                if (!row.property.holds() and !row.property.broken()) {
                    under += 1;
                    try w.print("floor: MISS {s}\n", .{line});
                }
            }
            try w.print("floor: {d} missed, {d} stale\n", .{ under, stale });
        }
        return broken == 0 and under == 0 and stale == 0;
    }

    fn displayName(k: Kind) []const u8 {
        return switch (k) {
            .always => "Always",
            .always_or_unreachable => "AlwaysOrUnreachable",
            .sometimes => "Sometimes",
            .reachable => "Reachable",
            .@"unreachable" => "Unreachable",
        };
    }
};

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

test "a run that printed no coverage line says nothing about it" {
    var s = Serial{};
    var c = Captured{};
    s.feed("PASS\n", .{ .exit = 1, .ns = 1 }, &c);
    var buf: [256]u8 = undefined;
    try testing.expect(s.summary(&buf) == null);
}

// ── many runs, merged ───────────────────────────────────────────────────────

fn mergedReport(m: *const Merged, floor: ?[]const u8, out: []u8) !struct { text: []const u8, pass: bool } {
    var w: std.Io.Writer = .fixed(out);
    const pass = try m.report(&w, floor);
    return .{ .text = w.buffered(), .pass = pass };
}

test "a run line names its seed, or its knobs" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("{\"metal_vmm_run\":{\"seed\":4711,\"knobs\":\"WIRE_EAT=3\"}}", try runLine(&buf, 4711, "WIRE_EAT=3"));
    try testing.expectEqualStrings("{\"metal_vmm_run\":{\"seed\":null,\"knobs\":\"none\"}}", try runLine(&buf, null, "none"));
}

test "many runs, one table: who reached each property first, how many did, and the rare ones" {
    var buf: [256]u8 = undefined;
    const a = comptime sdkEvent("Sometimes", "tcp: a lost SYN-ACK is sent again", true, true);
    const a_decl = comptime sdkEvent("Sometimes", "tcp: a lost SYN-ACK is sent again", false, false);
    const r = comptime sdkEvent("Sometimes", "tcp: an exact reset closes a connection", true, true);
    const r_decl = comptime sdkEvent("Sometimes", "tcp: an exact reset closes a connection", false, false);
    const n_decl = comptime sdkEvent("Reachable", "tcp: backoff reaches the RTO cap", false, false);
    var m = Merged.init(testing.allocator);
    defer m.deinit();
    // One file, two marked runs; the second boots twice and is still one run.
    const file1 = try std.mem.concat(testing.allocator, u8, &.{
        try runLine(&buf, 1, "WIRE_EAT=3"), "\n", boot, "\n", a_decl, "\n", r_decl, "\n", n_decl, "\n", a, "\n",
    });
    defer testing.allocator.free(file1);
    try m.addFile("sweep.jsonl", file1);
    const file2 = try std.mem.concat(testing.allocator, u8, &.{
        try runLine(&buf, 2, "PEER_RESET_AT=500"), "\n", boot,   "\n", a_decl, "\n", a, "\n", r, "\n",
        boot,                                      "\n", a_decl, "\n", a,      "\n",
    });
    defer testing.allocator.free(file2);
    try m.addFile("sweep2.jsonl", file2);

    try testing.expectEqual(@as(usize, 2), m.runs.items.len);
    const syn = m.rows.getPtr("tcp: a lost SYN-ACK is sent again").?;
    try testing.expectEqual(@as(u32, 2), syn.runs);
    try testing.expectEqualStrings("FAULT_SEED=1", m.runs.items[syn.first_run]);
    const reset = m.rows.getPtr("tcp: an exact reset closes a connection").?;
    try testing.expect(reset.rare());
    try testing.expectEqualStrings("FAULT_SEED=2", m.runs.items[reset.first_run]);
    try testing.expectEqual(@as(u32, 0), m.rows.getPtr("tcp: backoff reaches the RTO cap").?.runs);

    var out: [4096]u8 = undefined;
    const got = try mergedReport(&m, null, &out);
    try testing.expect(got.pass); // a MISS without a floor is not a failure
    try testing.expect(std.mem.indexOf(u8, got.text, "MISS Reachable           tcp: backoff reaches the RTO cap  (0 of 2 runs)") != null);
    try testing.expect(std.mem.indexOf(u8, got.text, "ok   Sometimes           tcp: a lost SYN-ACK is sent again  (2 of 2 runs, first FAULT_SEED=1)") != null);
    try testing.expect(std.mem.indexOf(u8, got.text, "reached by one run only:\n  tcp: an exact reset closes a connection  (FAULT_SEED=2)") != null);
    try testing.expect(std.mem.indexOf(u8, got.text, "2 runs, 3 properties: 2 hold, 1 missed, 0 broken; 1 rare") != null);
}

test "a file with no run lines is a run per boot, as the judge's sdk.jsonl is" {
    const a = comptime sdkEvent("Sometimes", "p", true, true);
    var m = Merged.init(testing.allocator);
    defer m.deinit();
    try m.addFile("sdk.jsonl", boot ++ "\n" ++ a ++ "\n" ++ boot ++ "\n" ++ boot ++ "\n" ++ a ++ "\n");
    try testing.expectEqual(@as(usize, 3), m.runs.items.len);
    try testing.expectEqualStrings("sdk.jsonl, boot 1", m.runs.items[0]);
    try testing.expectEqual(@as(u32, 2), m.rows.getPtr("p").?.runs);
}

test "the floor: a property on it missed fails, a line naming none is stale, a FAIL fails anyway" {
    const ok_line = comptime sdkEvent("Sometimes", "reached", true, true);
    const missed = comptime sdkEvent("Sometimes", "not reached", false, false);
    var m = Merged.init(testing.allocator);
    defer m.deinit();
    try m.addFile("a", boot ++ "\n" ++ ok_line ++ "\n" ++ missed ++ "\n");
    var out: [4096]u8 = undefined;
    try testing.expect((try mergedReport(&m, "# comment\nreached\n", &out)).pass);
    const under = try mergedReport(&m, "reached\nnot reached\n", &out);
    try testing.expect(!under.pass);
    try testing.expect(std.mem.indexOf(u8, under.text, "floor: MISS not reached") != null);
    const stale = try mergedReport(&m, "reached\nnever declared\n", &out);
    try testing.expect(!stale.pass);
    try testing.expect(std.mem.indexOf(u8, stale.text, "floor: STALE never declared") != null);

    var f = Merged.init(testing.allocator);
    defer f.deinit();
    try f.addFile("b", boot ++ "\n" ++ comptime sdkEvent("Always", "an always", true, false) ++ "\n");
    const failed = try mergedReport(&f, null, &out);
    try testing.expect(!failed.pass);
    try testing.expect(std.mem.startsWith(u8, failed.text, "FAIL Always"));
}

test "a line that is not JSON is counted, and the rest are read" {
    var m = Merged.init(testing.allocator);
    defer m.deinit();
    try m.addFile("a", boot ++ "\n{oops\n" ++ comptime sdkEvent("Reachable", "r", true, true) ++ "\r\n");
    try testing.expectEqual(@as(u64, 1), m.malformed);
    try testing.expectEqual(@as(u32, 1), m.rows.getPtr("r").?.runs);
}
