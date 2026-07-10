const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const terminal_module = b.addModule("terminal", .{
        .root_source_file = b.path("lib/terminal/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ai_module = b.addModule("ai", .{
        .root_source_file = b.path("lib/ai/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "terminal", .module = terminal_module },
            .{ .name = "ai", .module = ai_module },
        },
    });

    const exe = b.addExecutable(.{
        .name = "pith",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);

    if (b.args) |args| run.addArgs(args);

    const run_step = b.step("run", "Build and run pith");

    run_step.dependOn(&run.step);

    const test_step = b.step("test", "Build and run all tests");

    for ([_]*std.Build.Module{ terminal_module, ai_module, root_module }) |module| {
        const tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    const check_step = b.step("check", "Check Zig code for errors (used by ZLS)");

    check_step.dependOn(&exe.step);
    b.default_step.dependOn(check_step);
}
