//! Searches file contents for a literal substring and returns matches as
//! 'path:line:text'.

const std = @import("std");

const llm = @import("../llm.zig");
const Context = @import("Context.zig");
const Result = @import("Result.zig");
const fs = @import("fs.zig");
const parse = @import("parse.zig");
const walk = @import("walk.zig");

const limit_default = 100;
const file_bytes_max = 4 << 20;
const line_bytes_max = 300;
// The retained candidate paths bound the path-list memory. The running total of
// bytes read across searched files bounds the actual I/O work. A bare
// `files_max * file_bytes_max` ceiling leaves the I/O work at hundreds of gigabytes.
const files_max = 100_000;
const bytes_read_max = 256 << 20;

pub const spec: llm.Tool = .{
    .name = "grep",
    .description = "Search file contents for a literal substring (not a regex). " ++
        "Returns matching lines as 'path:line:text', with paths relative to the working " ++
        "directory. Ignores .git, zig-out, and build cache directories.",
    .parameters = &.{
        .{
            .name = "pattern",
            .type = .string,
            .required = true,
            .description = "Literal substring to search for",
        },
        .{
            .name = "path",
            .type = .string,
            .description = "Directory to search, or a single file to search directly " ++
                "(default: '.')",
        },
        .{
            .name = "glob",
            .type = .string,
            .description = "Only search files whose path matches this glob; * and ? do not " ++
                "cross '/', so use a '**/' prefix to recurse; has no effect when path names " ++
                "a single file (default: all files)",
        },
        .{
            .name = "ignore_case",
            .type = .boolean,
            .description = "Case-insensitive search (default: false)",
        },
        .{
            .name = "limit",
            .type = .integer,
            .description = "Maximum number of matching lines (default: 100)",
        },
    },
};

const Input = struct {
    pattern: []const u8,
    path: []const u8 = ".",
    glob: []const u8 = "**",
    ignore_case: bool = false,
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
    if (pattern.len == 0)
        return Result.report(gpa, .err, "Enter a nonempty pattern.", .{});
    const base = parsed.value.path;
    const file_glob = parsed.value.glob;
    const ignore_case = parsed.value.ignore_case;
    const limit = parsed.value.limit;

    // Pith walks a directory for its files. Pith searches a path that names a
    // single file directly and ignores the glob. The glob only filters a
    // traversal, and a named file needs none. `maybe_match` owns the walked
    // paths. The file case borrows `base`, which outlives the search.
    const single_file: [1][]const u8 = .{base};
    var paths: []const []const u8 = &single_file;
    var files_incomplete = false;
    var maybe_match: ?walk.Match = null;
    defer if (maybe_match) |*match| match.deinit(gpa);
    if (walk.collect(context.io, gpa, .{
        .base = base,
        .pattern = file_glob,
        .retain = files_max,
    })) |match| {
        maybe_match = match;
        paths = match.paths;
        // A walk that retains fewer candidates than it found, or a capped walk,
        // leaves some files unsearched.
        files_incomplete = match.capped or match.matched > match.paths.len;
    } else |err| switch (err) {
        // Not a directory: `base` names a file, so search that one path.
        error.NotDir => {},
        else => return Result.cannot(gpa, err, "search", base),
    }

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var count: usize = 0;
    var line_capped = false;
    var lines_truncated = false;
    var bytes_read: usize = 0;
    var bytes_capped = false;
    search: for (paths) |path| {
        if (bytes_read >= bytes_read_max) {
            bytes_capped = true;
            break :search;
        }
        const data = std.Io.Dir.cwd().readFileAlloc(
            context.io,
            path,
            gpa,
            .limited(file_bytes_max),
        ) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => return err,
            // An oversized file streams the full limit off disk before it fails.
            error.StreamTooLong => {
                bytes_read += file_bytes_max;
                continue;
            },
            else => continue,
        };
        defer gpa.free(data);
        bytes_read += data.len;
        if (std.mem.indexOfScalar(u8, data, 0) != null) continue;

        var line_number: usize = 0;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            line_number += 1;
            const hit = if (ignore_case)
                std.ascii.findIgnoreCase(line, pattern)
            else
                std.mem.indexOf(u8, line, pattern);
            if (hit == null) continue;
            if (count == limit) {
                line_capped = true;
                break :search;
            }
            const shown = line[0..utf8FloorLength(line, line_bytes_max)];
            if (shown.len < line.len) lines_truncated = true;
            if (count > 0) try out.writer.writeAll("\n");
            // Substitute U+FFFD for invalid bytes so the result serializes as a JSON string.
            try out.writer.print("{f}:{d}:{f}", .{
                std.unicode.fmtUtf8(path),
                line_number,
                std.unicode.fmtUtf8(shown),
            });
            count += 1;
        }
    }
    // An empty search is a whole result, so its sentence is the content and the
    // count below states it. No match line precedes it, so it takes no
    // separator. A result with matches reports the reason it can be incomplete
    // instead, most specific first: a hit result budget, then the I/O budget,
    // then unsearched files.
    if (count == 0) {
        if (line_capped or bytes_capped or files_incomplete) {
            try out.writer.print(
                "Pith found no matches for {s} in the part that Pith searched. " ++
                    "Use a narrower path or glob because the search was incomplete.",
                .{pattern},
            );
        } else {
            try out.writer.print("Pith found no matches for {s}.", .{pattern});
        }
    } else if (line_capped) {
        try out.writer.print(
            "\n[Pith stopped after {d} matches. Refine the search or increase limit.]",
            .{limit},
        );
    } else if (bytes_capped) {
        try out.writer.print(
            "\n[Pith stopped after Pith read {d} MB. Refine the search or use a narrower " ++
                "path or glob.]",
            .{bytes_read_max >> 20},
        );
    } else if (files_incomplete) {
        try out.writer.writeAll(
            "\n[Pith could not scan the full file tree. Pith did not search some files.]",
        );
    }

    var summary_output: std.Io.Writer.Allocating = .init(gpa);
    errdefer summary_output.deinit();
    try summary_output.writer.print("Matches: {d}", .{count});
    if (line_capped) {
        try summary_output.writer.writeAll(" · Limit: Reached");
    } else if (bytes_capped) {
        try summary_output.writer.print(" · Stopped at: {d} MB", .{bytes_read_max >> 20});
    } else if (files_incomplete) {
        try summary_output.writer.writeAll(" · Search: Incomplete");
    }
    if (lines_truncated) try summary_output.writer.writeAll(" · Lines: Truncated");
    const summary = try summary_output.toOwnedSlice();
    errdefer gpa.free(summary);
    const content = try out.toOwnedSlice();
    return .{ .content = content, .summary = .{ .text = summary }, .is_error = false };
}

/// The largest length no greater than `max` that does not split a UTF-8
/// codepoint, so a truncated line stays valid UTF-8 for JSON serialization.
fn utf8FloorLength(bytes: []const u8, max: usize) usize {
    var end = @min(bytes.len, max);
    while (end > 0 and end < bytes.len and bytes[end] & 0xC0 == 0x80) end -= 1;
    return end;
}

test utf8FloorLength {
    try std.testing.expectEqual(@as(usize, 1), utf8FloorLength("a\xC3\xA9", 2));
    try std.testing.expectEqual(@as(usize, 3), utf8FloorLength("a\xC3\xA9", 3));
    try std.testing.expectEqual(@as(usize, 3), utf8FloorLength("a\xC3\xA9", 10));
    try std.testing.expectEqual(@as(usize, 0), utf8FloorLength("", 5));
}

test "grep finds a literal substring with a glob filter" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.zig", .data = "nope\nneedle here\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.txt", .data = "needle here\n" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"pattern":"needle","path":".zig-cache/tmp/{s}","glob":"**/*.zig"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    var expected_buf: [128]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        ".zig-cache/tmp/{s}/a.zig:2:needle here",
        .{tmp.sub_path},
    );
    try std.testing.expectEqualStrings(expected, result.content);
    try std.testing.expectEqualStrings("Matches: 1", result.summary.?.text);
}

test "grep searches a single file given as the path" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.zig", .data = "nope\nneedle here\n" });
    var input_buf: [160]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"pattern":"needle","path":".zig-cache/tmp/{s}/a.zig"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    var expected_buf: [128]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        ".zig-cache/tmp/{s}/a.zig:2:needle here",
        .{tmp.sub_path},
    );
    try std.testing.expectEqualStrings(expected, result.content);
}

test "grep ignores the glob when the path is a single file" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.zig", .data = "needle here\n" });
    var input_buf: [192]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"pattern":"needle","path":".zig-cache/tmp/{s}/a.zig","glob":"**/*.txt"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    var expected_buf: [128]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        ".zig-cache/tmp/{s}/a.zig:1:needle here",
        .{tmp.sub_path},
    );
    try std.testing.expectEqualStrings(expected, result.content);
}

test "grep replaces invalid UTF-8 in matched lines" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "latin1.txt", .data = "caf\xE9 latte\n" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"pattern":"caf","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});

    const context: Context = .{ .gpa = std.testing.allocator, .io = io };
    const result = try run(&context, input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.unicode.utf8ValidateSlice(result.content));
    try std.testing.expect(
        std.mem.indexOf(u8, result.content, "latin1.txt:1:caf\u{FFFD} latte") != null,
    );
}

test "grep is case-insensitive when asked" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "Needle Here\n" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"pattern":"NEEDLE","path":".zig-cache/tmp/{s}","ignore_case":true}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "a.txt:1:Needle Here") != null);
}

test "grep stops at the result limit and reports it" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "f.txt",
        .data = "hit one\nhit two\nhit three\n",
    });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"pattern":"hit","path":".zig-cache/tmp/{s}","limit":2}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    var expected_buf: [256]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        ".zig-cache/tmp/{s}/f.txt:1:hit one\n.zig-cache/tmp/{s}/f.txt:2:hit two\n" ++
            "[Pith stopped after 2 matches. Refine the search or increase limit.]",
        .{ tmp.sub_path, tmp.sub_path },
    );
    try std.testing.expectEqualStrings(expected, result.content);
    try std.testing.expectEqualStrings("Matches: 2 · Limit: Reached", result.summary.?.text);
}

test "grep skips binary and oversized files" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bin.dat", .data = "hit\x00\n" });
    const big = try gpa.alloc(u8, file_bytes_max + 1);
    defer gpa.free(big);
    @memset(big, 'a');
    @memcpy(big[0..3], "hit");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "huge.txt", .data = big });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "small.txt", .data = "hit\n" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"pattern":"hit","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    var expected_buf: [128]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        ".zig-cache/tmp/{s}/small.txt:1:hit",
        .{tmp.sub_path},
    );
    try std.testing.expectEqualStrings(expected, result.content);
}

test "grep caps the reported line length" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const line = "hit" ++ "a" ** 397;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "long.txt", .data = line ++ "\n" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"pattern":"hit","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    var expected_buf: [512]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        ".zig-cache/tmp/{s}/long.txt:1:{s}",
        .{ tmp.sub_path, line[0..line_bytes_max] },
    );
    try std.testing.expectEqualStrings(expected, result.content);
    try std.testing.expectEqualStrings("Matches: 1 · Lines: Truncated", result.summary.?.text);
}

test "grep reports an incomplete search when nothing was shown" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.txt", .data = "hit\n" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"pattern":"hit","path":".zig-cache/tmp/{s}","limit":0}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(
        std.mem.indexOf(u8, result.content, "the search was incomplete") != null,
    );
    try std.testing.expectEqualStrings("Matches: 0 · Limit: Reached", result.summary.?.text);
}

// An empty search still states its count, so the box reads like every other
// result of this tool.
test "grep reports no matches of a complete search" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.txt", .data = "hit\n" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"pattern":"miss","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("Pith found no matches for miss.", result.content);
    try std.testing.expectEqualStrings("Matches: 0", result.summary.?.text);
}

test "grep canceled while reading a file propagates" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.txt", .data = "hit\n" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"pattern":"hit","path":".zig-cache/tmp/{s}"}}
    , .{tmp.sub_path});
    var cancel: fs.CancelIo = .init(.file_open);
    const context: Context = .{ .gpa = gpa, .io = cancel.io() };
    try std.testing.expectError(error.Canceled, run(&context, input));
}
