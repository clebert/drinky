//! Searches file contents for a literal substring, returning matches as
//! 'path:line:text'.

const std = @import("std");

const llm = @import("../llm.zig");
const Context = @import("Context.zig");
const Result = @import("Result.zig");
const parse = @import("parse.zig");
const walk = @import("walk.zig");

const limit_default = 100;
const file_bytes_max = 4 << 20;
const line_bytes_max = 300;
// Retained candidate paths (bounds the path-list memory) and the running total
// of bytes read across searched files (bounds the actual I/O work, which a bare
// `files_max * file_bytes_max` ceiling would leave at hundreds of gigabytes).
const files_max = 100_000;
const bytes_read_max = 256 << 20;

pub const spec: llm.Tool = .{
    .name = "grep",
    .description = "Search file contents for a literal substring (not a regex). Returns matching lines as 'path:line:text', with paths relative to the working directory. Ignores .git, zig-out, and build cache directories.",
    .parameters = &.{
        .{ .name = "pattern", .type = .string, .required = true, .description = "Literal substring to search for" },
        .{ .name = "path", .type = .string, .description = "Directory to search (default: '.')" },
        .{ .name = "glob", .type = .string, .description = "Only search files whose path matches this glob; * and ? do not cross '/', so use a '**/' prefix to recurse (default: all files)" },
        .{ .name = "ignore_case", .type = .boolean, .description = "Case-insensitive search (default: false)" },
        .{ .name = "limit", .type = .integer, .description = "Maximum number of matching lines (default: 100)" },
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
    if (pattern.len == 0) return Result.report(gpa, .err, "pattern must not be empty", .{});
    const base = parsed.value.path;
    const file_glob = parsed.value.glob;
    const ignore_case = parsed.value.ignore_case;
    const limit = parsed.value.limit;

    var matches = walk.collect(context.io, gpa, .{ .base = base, .pattern = file_glob, .retain = files_max }) catch |err| switch (err) {
        error.Canceled => return err,
        else => return Result.report(gpa, .err, "cannot search {s}: {s}", .{ base, @errorName(err) }),
    };
    defer matches.deinit(gpa);
    // Fewer candidates retained than found, or a capped walk, means some files
    // were never searched.
    const files_incomplete = matches.capped or matches.matched > matches.paths.len;

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var count: usize = 0;
    var line_capped = false;
    var bytes_read: usize = 0;
    var bytes_capped = false;
    search: for (matches.paths) |path| {
        if (bytes_read >= bytes_read_max) {
            bytes_capped = true;
            break :search;
        }
        const data = std.Io.Dir.cwd().readFileAlloc(context.io, path, gpa, .limited(file_bytes_max)) catch |err| switch (err) {
            error.Canceled => return err,
            else => continue,
        };
        defer gpa.free(data);
        bytes_read += data.len;
        if (std.mem.indexOfScalar(u8, data, 0) != null) continue;

        var line_number: usize = 0;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            line_number += 1;
            if (!lineContains(.{ .line = line, .needle = pattern, .ignore_case = ignore_case })) continue;
            if (count == limit) {
                line_capped = true;
                break :search;
            }
            const shown = line[0..utf8FloorLength(line, line_bytes_max)];
            if (count > 0) try out.writer.writeAll("\n");
            try out.writer.print("{s}:{d}:{s}", .{ path, line_number, shown });
            count += 1;
        }
    }
    if (count == 0) {
        if (line_capped or bytes_capped or files_incomplete)
            return Result.report(gpa, .ok, "no matches for {s} in the portion searched; the search was incomplete — narrow the path or glob", .{pattern});
        return Result.report(gpa, .ok, "no matches for {s}", .{pattern});
    }
    // Report the reason the result may be incomplete, most specific first: a hit
    // result budget, then the I/O budget, then unsearched files.
    if (line_capped) {
        try out.writer.print("\n... stopped at the limit of {d} matches; refine the search or raise limit", .{limit});
    } else if (bytes_capped) {
        try out.writer.print("\n... stopped after reading {d} MB; refine the search or narrow the path or glob", .{bytes_read_max >> 20});
    } else if (files_incomplete) {
        try out.writer.writeAll("\n... search incomplete: the tree is too large to scan fully; some files were not searched");
    }
    return .{ .content = try out.toOwnedSlice(), .is_error = false };
}

/// Largest length no greater than `max` that does not split a UTF-8 codepoint,
/// so a truncated line stays valid UTF-8 for JSON serialization.
fn utf8FloorLength(bytes: []const u8, max: usize) usize {
    var end = @min(bytes.len, max);
    while (end > 0 and end < bytes.len and bytes[end] & 0xC0 == 0x80) end -= 1;
    return end;
}

fn lineContains(options: struct { line: []const u8, needle: []const u8, ignore_case: bool }) bool {
    const line = options.line;
    const needle = options.needle;
    if (needle.len == 0 or line.len < needle.len) return false;
    if (!options.ignore_case) return std.mem.indexOf(u8, line, needle) != null;
    const last = line.len - needle.len;
    var start: usize = 0;
    while (start <= last) : (start += 1) {
        if (std.ascii.startsWithIgnoreCase(line[start..], needle)) return true;
    }
    return false;
}

test utf8FloorLength {
    try std.testing.expectEqual(@as(usize, 1), utf8FloorLength("a\xC3\xA9", 2));
    try std.testing.expectEqual(@as(usize, 3), utf8FloorLength("a\xC3\xA9", 3));
    try std.testing.expectEqual(@as(usize, 3), utf8FloorLength("a\xC3\xA9", 10));
    try std.testing.expectEqual(@as(usize, 0), utf8FloorLength("", 5));
}

test "grep finds a literal substring with a glob filter" {
    const context: Context = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    const result = try run(&context,
        \\{"pattern":"pub fn match","path":"lib","glob":"**/glob.zig"}
    );
    defer std.testing.allocator.free(result.content);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "lib/ai/tool/glob.zig:") != null);
}

test "grep is case-insensitive when asked" {
    const context: Context = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    const result = try run(&context,
        \\{"pattern":"PUB FN MATCH","path":"lib","glob":"**/glob.zig","ignore_case":true}
    );
    defer std.testing.allocator.free(result.content);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "lib/ai/tool/glob.zig:") != null);
}
