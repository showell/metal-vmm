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
}
