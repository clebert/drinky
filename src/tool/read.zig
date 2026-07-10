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
    const shown_max = limit orelse lines_max;

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var index: usize = 0;
    var shown: usize = 0;
    var bytes: usize = 0;
    var last = start;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| : (index += 1) {
        if (index < start) continue;
        if (shown >= shown_max) break;
        if (shown > 0 and bytes + line.len > bytes_max) break;
        if (shown > 0) try out.writer.writeAll("\n");
        try out.writer.writeAll(line);
        bytes += line.len + 1;
        last = index;
        shown += 1;
    }
    if (last + 1 < total) {
        try out.writer.print("\n\n[showing lines {d}-{d} of {d}; use offset={d} to continue]", .{ start + 1, last + 1, total, last + 2 });
    }
    return .{ .content = try out.toOwnedSlice(), .is_error = false };
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
