//! `zig build fuzz -Dseeds=n [-Dfirst=k]`: seeds k..k+n-1 of `fuzz.zig`,
//! each run twice. A panic names its seed and step, so the seed can be kept
//! as a regression. The binary also takes `[first] [seeds]` as arguments,
//! which win over the build's options: one binary for any seed, under a
//! debugger.

const std = @import("std");
const fuzz = @import("fuzz.zig");
const options = @import("fuzz_options");

pub const panic = std.debug.FullPanic(named);

fn named(message: []const u8, first_trace_addr: ?usize) noreturn {
    std.debug.print("fuzz: seed {d}, step {d}: {s}\n", .{ fuzz.current_seed, fuzz.current_step, message });
    std.debug.defaultPanic(message, first_trace_addr);
}

pub fn main(init: std.process.Init.Minimal) !u8 {
    const argv = init.args.vector;
    const first = if (argv.len > 1) std.fmt.parseInt(u64, std.mem.span(argv[1]), 10) catch options.first else options.first;
    const seeds = if (argv.len > 2) std.fmt.parseInt(u64, std.mem.span(argv[2]), 10) catch options.seeds else options.seeds;
    const last = first + seeds - 1;
    fuzz.sweep(first, last) catch |e| {
        std.debug.print("fuzz: {s}\n", .{@errorName(e)});
        return 1;
    };
    std.debug.print("fuzz: seeds {d} to {d}: nothing panicked, each the same run twice\n", .{ first, last });
    return 0;
}
