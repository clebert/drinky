//! Reads a UTF-8 text file, paginated by line so a large file returns a bounded
//! window that points at the next offset to continue from.

const std = @import("std");

const llm = @import("../llm.zig");
const Context = @import("Context.zig");
const Result = @import("Result.zig");
const parse = @import("parse.zig");

const lines_max = 2000;
const bytes_max = 50 * 1024;
const file_bytes_max = 16 << 20;

pub const spec: llm.Tool = .{
    .name = "read",
    .description = "Read a UTF-8 text file. Output is truncated to 2000 lines or 50KB, whichever comes first; use offset and limit to page through large files (the output notes the next offset to continue from).",
    .parameters = &.{
        .{ .name = "path", .type = .string, .required = true, .description = "Path to the file (relative or absolute)" },
        .{ .name = "offset", .type = .integer, .description = "1-indexed line to start reading from (default: 1)" },
        .{ .name = "limit", .type = .integer, .description = "Maximum number of lines to read" },
    },
};

const Input = struct {
    path: []const u8,
    offset: usize = 1,
    limit: ?usize = null,
};

comptime {
    parse.check(Input, spec.parameters);
}

pub fn run(context: *const Context, input_json: []const u8) !Result {
    const gpa = context.gpa;
    const parsed = try parse.input(Input, gpa, input_json);
    defer parsed.deinit();
    const path = parsed.value.path;
    const offset = parsed.value.offset;
    const limit = parsed.value.limit;

    const data = std.Io.Dir.cwd().readFileAlloc(context.io, path, gpa, .limited(file_bytes_max)) catch |err| switch (err) {
        error.StreamTooLong => return Result.report(gpa, .err, "{s} is larger than {d} bytes; read it another way", .{ path, file_bytes_max }),
        error.Canceled => return err,
        else => return Result.report(gpa, .err, "cannot read {s}: {s}", .{ path, @errorName(err) }),
    };
    defer gpa.free(data);

    if (std.mem.indexOfScalar(u8, data, 0) != null or !std.unicode.utf8ValidateSlice(data)) {
        return Result.report(gpa, .err, "{s} is not a UTF-8 text file", .{path});
    }

    const total = std.mem.count(u8, data, "\n") + 1;
    const start = if (offset > 0) offset - 1 else 0;
    if (start >= total) {
        return Result.report(gpa, .err, "offset {d} is past the end of {s} ({d} lines)", .{ offset, path, total });
    }
    const shown_max = @min(limit orelse lines_max, lines_max);
    if (shown_max == 0) return Result.report(gpa, .err, "limit must be at least 1", .{});

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var index: usize = 0;
    var shown: usize = 0;
    var bytes: usize = 0;
    var last = start;
    var truncated = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| : (index += 1) {
        if (index < start) continue;
        if (shown >= shown_max) break;
        if (shown > 0 and bytes + line.len > bytes_max) break;
        // The first line is exempt from the byte budget so a page always makes
        // progress, but it must not carry the whole cap away on its own.
        if (shown == 0 and line.len > bytes_max) {
            try out.writer.writeAll(line[0..utf8FloorLength(line, bytes_max)]);
            last = index;
            shown = 1;
            truncated = true;
            break;
        }
        if (shown > 0) try out.writer.writeAll("\n");
        try out.writer.writeAll(line);
        bytes += line.len + 1;
        last = index;
        shown += 1;
    }
    if (truncated) {
        try out.writer.print("\n\n[line {d} exceeds {d} bytes and was truncated]", .{ last + 1, bytes_max });
    }
    if (last + 1 < total) {
        try out.writer.print("\n\n[showing lines {d}-{d} of {d}; use offset={d} to continue]", .{ start + 1, last + 1, total, last + 2 });
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

test "read rejects invalid input" {
    const context: Context = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    try std.testing.expectError(error.InvalidArguments, run(&context, "{}"));
}

test "read of missing file reports an error" {
    const context: Context = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    const result = try run(&context,
        \\{"path":"/definitely/not/here.txt"}
    );
    defer std.testing.allocator.free(result.content);
    try std.testing.expect(result.is_error);
}

test "read paginates and points at the next offset" {
    const context: Context = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    const result = try run(&context,
        \\{"path":"build.zig.zon","limit":1}
    );
    defer std.testing.allocator.free(result.content);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "use offset=2 to continue") != null);
}

test "read rejects an offset past the end of the file" {
    const context: Context = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    const result = try run(&context,
        \\{"path":"build.zig.zon","offset":100000}
    );
    defer std.testing.allocator.free(result.content);
    try std.testing.expect(result.is_error);
}

test "read rejects a zero limit" {
    const context: Context = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    const result = try run(&context,
        \\{"path":"build.zig.zon","limit":0}
    );
    defer std.testing.allocator.free(result.content);
    try std.testing.expect(result.is_error);
}

test "read truncates a single line longer than the byte cap" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const line = try gpa.alloc(u8, bytes_max + 100);
    defer gpa.free(line);
    @memset(line, 'a');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "long.txt", .data = line });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"path":".zig-cache/tmp/{s}/long.txt"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer gpa.free(result.content);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(result.content.len < bytes_max + 100);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "truncated") != null);
}

test "read clamps an explicit limit to the line cap" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try gpa.alloc(u8, (lines_max + 100) * 2);
    defer gpa.free(data);
    for (0..lines_max + 100) |i| {
        data[i * 2] = 'x';
        data[i * 2 + 1] = '\n';
    }
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "many.txt", .data = data });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"path":".zig-cache/tmp/{s}/many.txt","limit":100000}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer gpa.free(result.content);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "use offset=2001 to continue") != null);
}
