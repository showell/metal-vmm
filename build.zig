//! `zig build` makes `zig-out/bin/metal-vmm`; `zig build run -- <kernel.elf>`
//! starts a guest.
//!
//! **ReleaseSafe BY DEFAULT** (Steve, 2026-10-08): every safety check,
//! debug info and a stack trace on a panic, so it stays inspectable, at a
//! third of Debug's time a boot (the loader's scan of a 25 MB kernel and
//! every exit's handling were most of a run). `-Doptimize=Debug` to step
//! through it. The unit tests build Debug unless `-Dtest-optimize` says
//! otherwise; check.sh runs them once in ReleaseSafe too, the mode that ships.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "how metal-vmm and fuzz are built (ReleaseSafe)") orelse .ReleaseSafe;
    const test_optimize = b.option(std.builtin.OptimizeMode, "test-optimize", "how the unit tests are built (Debug)") orelse .Debug;

    const exe = b.addExecutable(.{
        .name = "metal-vmm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Start a guest: zig build run -- <kernel.elf>").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = test_optimize,
    }) });
    b.step("test", "The parts that can be checked without a processor").dependOn(&b.addRunArtifact(tests).step);

    // **THE GUEST'S INPUT NEVER KILLS THE VMM** (fuzz.zig):
    // `zig build fuzz -Dseeds=n -Dfirst=k`. `zig build test` runs the first
    // few seeds and the regressions every time.
    const fuzz_options = b.addOptions();
    fuzz_options.addOption(u64, "seeds", b.option(u64, "seeds", "How many fuzz seeds (zig build fuzz)") orelse 1000);
    fuzz_options.addOption(u64, "first", b.option(u64, "first", "The first fuzz seed (zig build fuzz)") orelse 1);
    const fuzz = b.addExecutable(.{
        .name = "fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    fuzz.root_module.addOptions("fuzz_options", fuzz_options);
    b.installArtifact(fuzz);
    b.step("fuzz", "Every guest-facing model under a seeded stream of guest input: zig build fuzz -Dseeds=n").dependOn(&b.addRunArtifact(fuzz).step);

}
