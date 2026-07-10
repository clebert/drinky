//! Finds files by glob pattern, returning matching paths one per line.

const std = @import("std");

const llm = @import("../llm.zig");
const Context = @import("Context.zig");
const Result = @import("Result.zig");
const field = @import("field.zig");
const walk = @import("walk.zig");

const limit_default = 1000;

pub const spec: llm.Tool = .{
    .name = "find",
    .description = "Find files by glob pattern. Returns paths relative to the working directory, one per line. The pattern matches the whole path and * and ? never cross '/', so use a '**/' prefix to recurse. Ignores .git, zig-out, and build cache directories.",
    .schema_json =
    \\{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern, e.g. '**/*.zig' or 'src/**/*.zig'"},"path":{"type":"string","description":"Directory to search (default: '.')"},"limit":{"type":"integer","description":"Maximum number of results (default: 1000)"}},"required":["pattern"]}
    ,
};

pub fn run(context: *const Context, input_json: []const u8) !Result {
    const gpa = context.gpa;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, input_json, .{});
    defer parsed.deinit();
    const pattern = field.string(parsed.value, "pattern") orelse return Result.report(gpa, .err, "missing 'pattern'", .{});
    const base = field.string(parsed.value, "path") orelse ".";
    const limit = field.uint(parsed.value, "limit") orelse limit_default;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const files = walk.collect(context.io, arena, .{ .base = base, .pattern = pattern }) catch |err| {
        return Result.report(gpa, .err, "cannot search {s}: {s}", .{ base, @errorName(err) });
    };
    if (files.len == 0) return Result.report(gpa, .ok, "no files match {s}", .{pattern});

    const shown = @min(files.len, limit);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (files[0..shown], 0..) |path, index| {
        if (index > 0) try out.writer.writeAll("\n");
        try out.writer.writeAll(path);
    }
    if (files.len > shown) {
        if (shown > 0) try out.writer.writeAll("\n");
        try out.writer.print("... {d} more (raise limit to see them)", .{files.len - shown});
    }
    return .{ .content = try out.toOwnedSlice(), .is_error = false };
}

test "find matches files by glob under a directory" {
    const context: Context = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    const result = try run(&context,
        \\{"pattern":"**/glob.zig","path":"src"}
    );
    defer std.testing.allocator.free(result.content);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("src/tool/glob.zig", result.content);
}
