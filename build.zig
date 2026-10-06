//! `zig build` makes `zig-out/bin/metal-vmm`; `zig build run -- <kernel.elf>`
//! starts a guest. Debug by default: this program's whole job is to be
//! inspectable while the thing it runs is not.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
        .optimize = optimize,
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
