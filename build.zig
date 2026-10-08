const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const terminal_module = b.addModule("terminal", .{
        .root_source_file = b.path("lib/terminal/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const markdown_module = b.addModule("markdown", .{
        .root_source_file = b.path("lib/markdown/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const core_module = b.addModule("core", .{
        .root_source_file = b.path("lib/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const providers_module = b.addModule("providers", .{
        .root_source_file = b.path("lib/providers/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_module },
        },
    });

    const tools_module = b.addModule("tools", .{
        .root_source_file = b.path("lib/tools/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_module },
        },
    });

    const accounts_module = b.addModule("accounts", .{
        .root_source_file = b.path("lib/accounts/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_module },
            .{ .name = "providers", .module = providers_module },
        },
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "terminal", .module = terminal_module },
            .{ .name = "markdown", .module = markdown_module },
            .{ .name = "core", .module = core_module },
            .{ .name = "providers", .module = providers_module },
            .{ .name = "tools", .module = tools_module },
            .{ .name = "accounts", .module = accounts_module },
        },
    });

    const exe = b.addExecutable(.{
        .name = "drinky",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);

    run.addPassthruArgs();

    const run_step = b.step("run", "Build and run Drinky");

    run_step.dependOn(&run.step);

    const comment_scan_module = b.createModule(.{
        .root_source_file = b.path("scripts/comment_scan.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });

    const width_scan_module = b.createModule(.{
        .root_source_file = b.path("scripts/width_scan.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Build and run all tests");

    const TestedModule = struct { name: []const u8, module: *std.Build.Module };

    const tested_modules = [_]TestedModule{
        .{ .name = "terminal", .module = terminal_module },
        .{ .name = "markdown", .module = markdown_module },
        .{ .name = "core", .module = core_module },
        .{ .name = "providers", .module = providers_module },
        .{ .name = "tools", .module = tools_module },
        .{ .name = "accounts", .module = accounts_module },
        .{ .name = "src", .module = root_module },
        .{ .name = "comment_scan", .module = comment_scan_module },
        .{ .name = "width_scan", .module = width_scan_module },
    };

    for (tested_modules) |tested| {
        const module = tested.module;
        const test_module = b.createModule(.{
            .root_source_file = module.root_source_file,
            .target = module.resolved_target,
            .optimize = module.optimize,
            .strip = true,
        });
        for (module.import_table.keys(), module.import_table.values()) |name, imported|
            test_module.addImport(name, imported);
        const tests = b.addTest(.{ .name = tested.name, .root_module = test_module });
        const run_tests = b.addRunArtifact(tests);
        run_tests.has_side_effects = true;
        test_step.dependOn(&run_tests.step);
    }

    const unicode_generator = b.addExecutable(.{
        .name = "generate-unicode-data",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/generate_unicode_data.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .strip = true,
        }),
    });

    const run_unicode = b.addRunArtifact(unicode_generator);
    run_unicode.setCwd(b.path("."));
    run_unicode.has_side_effects = true;

    const unicode_step = b.step(
        "unicode",
        "Regenerate the Unicode data, its test corpus, and its license notice",
    );
    unicode_step.dependOn(&run_unicode.step);

    b.default_step.dependOn(&unicode_generator.step);

    const commonmark_generator = b.addExecutable(.{
        .name = "generate-commonmark-corpus",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/generate_commonmark_corpus.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .strip = true,
        }),
    });

    const run_commonmark = b.addRunArtifact(commonmark_generator);
    run_commonmark.setCwd(b.path("."));
    run_commonmark.has_side_effects = true;

    const commonmark_step = b.step(
        "commonmark",
        "Regenerate the CommonMark test corpus and its license notice",
    );
    commonmark_step.dependOn(&run_commonmark.step);

    b.default_step.dependOn(&commonmark_generator.step);
}
