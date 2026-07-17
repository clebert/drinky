//! Finds files by glob pattern, returning matching paths one per line.

const std = @import("std");

const llm = @import("../llm.zig");
const Context = @import("Context.zig");
const Result = @import("Result.zig");
const parse = @import("parse.zig");
const walk = @import("walk.zig");

const limit_default = 1000;

pub const spec: llm.Tool = .{
    .name = "find",
    .description = "Find files by glob pattern. Returns paths relative to the working directory, one per line. The pattern matches the whole path and * and ? never cross '/', so use a '**/' prefix to recurse. Ignores .git, zig-out, and build cache directories.",
    .parameters = &.{
        .{ .name = "pattern", .type = .string, .required = true, .description = "Glob pattern, e.g. '**/*.zig' or 'src/**/*.zig'" },
        .{ .name = "path", .type = .string, .description = "Directory to search (default: '.')" },
        .{ .name = "limit", .type = .integer, .description = "Maximum number of results (default: 1000)" },
    },
};

const Input = struct {
    pattern: []const u8,
    path: []const u8 = ".",
    limit: usize = limit_default,
};

comptime {
    parse.check(Input, spec.parameters);
}

pub fn run(context: *const Context, input_json: []const u8) !Result {
    const gpa = context.gpa;
    const parsed = try parse.input(Input, gpa, input_json);
    defer parsed.deinit();
    const pattern = parsed.value.pattern;
    const base = parsed.value.path;
    const limit = parsed.value.limit;

    var matches = walk.collect(context.io, gpa, .{ .base = base, .pattern = pattern, .retain = limit }) catch |err| switch (err) {
        error.Canceled => return err,
        else => return Result.report(gpa, .err, "cannot search {s}: {s}", .{ base, @errorName(err) }),
    };
    defer matches.deinit(gpa);
    if (matches.matched == 0) {
        if (matches.capped) return Result.report(gpa, .ok, "no files match {s} in the portion searched; the tree is too large to scan fully — narrow the path or pattern", .{pattern});
        return Result.report(gpa, .ok, "no files match {s}", .{pattern});
    }

    const shown = matches.paths.len;
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (matches.paths, 0..) |path, index| {
        if (index > 0) try out.writer.writeAll("\n");
        try out.writer.writeAll(path);
    }
    if (matches.capped) {
        if (shown > 0) try out.writer.writeAll("\n");
        try out.writer.print("... search stopped: the tree is too large to scan fully; showing the {d} smallest matches — narrow the path or pattern", .{shown});
    } else if (matches.matched > shown) {
        if (shown > 0) try out.writer.writeAll("\n");
        try out.writer.print("... {d} more (raise limit to see them)", .{matches.matched - shown});
    }
    return .{ .content = try out.toOwnedSlice(), .is_error = false };
}

test "find matches files by glob under a directory" {
    const context: Context = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    const result = try run(&context,
        \\{"pattern":"**/glob.zig","path":"lib"}
    );
    defer std.testing.allocator.free(result.content);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("lib/ai/tool/glob.zig", result.content);
}
