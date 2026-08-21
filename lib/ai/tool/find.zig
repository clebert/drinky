//! Finds files by glob pattern and returns the matching paths one per line.

const std = @import("std");

const llm = @import("../llm.zig");
const Context = @import("Context.zig");
const Result = @import("Result.zig");
const parse = @import("parse.zig");
const walk = @import("walk.zig");

const limit_default = 1000;

pub const spec: llm.Tool = .{
    .name = "find",
    .description = "Find files by glob pattern. Returns paths relative to the working " ++
        "directory, one per line. The pattern matches the whole path and * and ? never " ++
        "cross '/', so use a '**/' prefix to recurse. Ignores .git, zig-out, and build " ++
        "cache directories.",
    .parameters = &.{
        .{
            .name = "pattern",
            .type = .string,
            .required = true,
            .description = "Glob pattern, e.g. '**/*.zig' or 'src/**/*.zig'",
        },
        .{ .name = "path", .type = .string, .description = "Directory to search (default: '.')" },
        .{
            .name = "limit",
            .type = .integer,
            .description = "Maximum number of results (default: 1000)",
        },
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

    var matches = walk.collect(context.io, gpa, .{
        .base = base,
        .pattern = pattern,
        .retain = limit,
    }) catch |err|
        return Result.cannot(gpa, err, "search", base);
    defer matches.deinit(gpa);

    const shown = matches.paths.len;
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (matches.paths, 0..) |path, index| {
        if (index > 0) try out.writer.writeAll("\n");
        try out.writer.writeAll(path);
    }
    // An empty search is a whole result, so its sentence is the content and the
    // count below states it. The paths are empty here, so the sentence opens the
    // content and takes no separator.
    if (matches.matched == 0) {
        if (matches.capped) {
            try out.writer.print(
                "No files match {s} in the part that Drinky searched. Use a narrower path or " ++
                    "pattern because Drinky could not scan the full file tree.",
                .{pattern},
            );
        } else {
            try out.writer.print("No files match {s}.", .{pattern});
        }
    } else if (matches.capped) {
        if (shown > 0) try out.writer.writeAll("\n");
        try out.writer.print(
            "[Drinky stopped the search because the file tree is too large. " ++
                "Drinky shows the {d} smallest matches. Use a narrower path or pattern.]",
            .{shown},
        );
    } else if (matches.matched > shown) {
        if (shown > 0) try out.writer.writeAll("\n");
        try out.writer.print(
            "[Drinky omitted {d} matches. Increase limit to see them.]",
            .{matches.matched - shown},
        );
    }

    var summary_output: std.Io.Writer.Allocating = .init(gpa);
    errdefer summary_output.deinit();
    try summary_output.writer.print("Matches: {d}", .{shown});
    if (matches.capped) {
        try summary_output.writer.writeAll(" · Search: Incomplete");
    } else if (matches.matched > shown) {
        try summary_output.writer.print(" · Omitted matches: {d}", .{matches.matched - shown});
    }
    const summary = try summary_output.toOwnedSlice();
    errdefer gpa.free(summary);
    const content = try out.toOwnedSlice();
    return .{ .content = content, .summary = .{ .text = summary }, .is_error = false };
}

test "find matches files by glob under a directory" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.zig", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.txt", .data = "" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"pattern":"**/*.zig","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    var expected_buf: [128]u8 = undefined;
    const expected =
        try std.fmt.bufPrint(&expected_buf, ".zig-cache/tmp/{s}/a.zig", .{tmp.sub_path});
    try std.testing.expectEqualStrings(expected, result.content);
    try std.testing.expectEqualStrings("Matches: 1", result.summary.?.text);
}

test "find reports how many more matched beyond the limit" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "a.txt", "b.txt", "c.txt" }) |name| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = "" });
    }
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"pattern":"*.txt","path":".zig-cache/tmp/{s}","limit":1}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    var expected_buf: [128]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        ".zig-cache/tmp/{s}/a.txt\n[Drinky omitted 2 matches. Increase limit to see them.]",
        .{tmp.sub_path},
    );
    try std.testing.expectEqualStrings(expected, result.content);
    try std.testing.expectEqualStrings("Matches: 1 · Omitted matches: 2", result.summary.?.text);
}

test "find reports when no files match" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"pattern":"*.md","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("No files match *.md.", result.content);
    // An empty search still states its count, so the box reads like every other
    // result of this tool.
    try std.testing.expectEqualStrings("Matches: 0", result.summary.?.text);
}
