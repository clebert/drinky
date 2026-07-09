const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const check_step = b.step("check", "Check Zig code for errors (used by ZLS)");

    const lib_module = b.createModule(.{
        .root_source_file = b.path("lib/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "pith",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bin/pith/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lib", .module = lib_module }},
        }),
    });

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);

    if (b.args) |args| run.addArgs(args);

    const run_step = b.step("run", "Build and run pith");

    run_step.dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = lib_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Build and run all tests");

    test_step.dependOn(&run_tests.step);

    check_step.dependOn(&exe.step);
    b.default_step.dependOn(check_step);
}
