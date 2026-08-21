//! Reads a UTF-8 text file, paginated by line. A large file returns a bounded
//! window that points at the next offset to continue from.

const std = @import("std");

const format = @import("../format.zig");
const llm = @import("../llm.zig");
const Context = @import("Context.zig");
const Result = @import("Result.zig");
const fs = @import("fs.zig");
const parse = @import("parse.zig");

/// The window of one call. A file inside it comes back whole, so a caller that
/// must show the model a whole file keeps that file below both bounds.
pub const lines_max = 2000;
pub const bytes_max = 50 * 1024;
const file_bytes_max = 16 << 20;

pub const spec: llm.Tool = .{
    .name = "read",
    .description = "Read a UTF-8 text file. Output is truncated to 2000 lines or 50KB, " ++
        "whichever comes first; use offset and limit to page through large files " ++
        "(the output notes the next offset to continue from).",
    .parameters = &.{
        .{
            .name = "path",
            .type = .string,
            .required = true,
            .description = "Path to the file (relative or absolute)",
        },
        .{
            .name = "offset",
            .type = .integer,
            .description = "1-indexed line to start reading from (default: 1)",
        },
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

    const data = std.Io.Dir.cwd().readFileAlloc(
        context.io,
        path,
        gpa,
        .limited(file_bytes_max),
    ) catch |err| switch (err) {
        error.StreamTooLong => return Result.report(
            gpa,
            .err,
            "Drinky cannot read {s} because it is larger than {d} bytes.",
            .{ path, file_bytes_max },
        ),
        else => return Result.cannot(gpa, err, "read", path),
    };
    defer gpa.free(data);

    if (std.mem.indexOfScalar(u8, data, 0) != null or !std.unicode.utf8ValidateSlice(data)) {
        return Result.report(
            gpa,
            .err,
            "Drinky cannot read {s} because it is not a UTF-8 text file.",
            .{path},
        );
    }

    // A rule can require a skill for this file. A read is never refused, so it
    // only asks Drinky to send that skill, which reaches the model at the next
    // round. A role that reads and never writes still gets the rules.
    if (context.skill_guard) |guard| try guard.require(&.{
        .gpa = gpa,
        .io = context.io,
        .path = path,
        .history = context.history,
    });

    const total = format.lines(data);
    const start = if (offset > 0) offset - 1 else 0;
    if (start >= total and !(total == 0 and start == 0)) {
        return Result.report(
            gpa,
            .err,
            "Line offset {d} is after the last line in {s}. The file has {d} lines.",
            .{ offset, path, total },
        );
    }
    const shown_max = @min(limit orelse lines_max, lines_max);
    if (shown_max == 0)
        return Result.report(gpa, .err, "Set limit to 1 or more.", .{});
    if (total == 0) {
        const content = try gpa.dupe(u8, "");
        errdefer gpa.free(content);
        return .{
            .content = content,
            .summary = .{ .text = try gpa.dupe(u8, "Lines: 0") },
            .is_error = false,
        };
    }

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var index: usize = 0;
    var shown: usize = 0;
    var bytes: usize = 0;
    var last = start;
    var truncated = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| : (index += 1) {
        if (index >= total) break;
        if (index < start) continue;
        if (shown >= shown_max) break;
        if (shown > 0 and bytes + line.len > bytes_max) break;
        // The first line is exempt from the byte budget so a page always makes
        // progress. It must not carry the whole cap away on its own.
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
    if (!truncated and (last + 1 < total or data[data.len - 1] == '\n'))
        try out.writer.writeAll("\n");
    if (truncated) {
        const written = out.written();
        const separator =
            if (written.len > 0 and written[written.len - 1] == '\n') "\n" else "\n\n";
        try out.writer.print(
            "{s}[Line {d} is longer than {d} bytes. Drinky truncated it.]",
            .{ separator, last + 1, bytes_max },
        );
    }
    if (last + 1 < total) {
        const written = out.written();
        const separator =
            if (written.len > 0 and written[written.len - 1] == '\n') "\n" else "\n\n";
        try out.writer.print(
            "{s}[Drinky shows lines {d}–{d} of {d}. Use offset={d} to continue.]",
            .{ separator, start + 1, last + 1, total, last + 2 },
        );
    }

    const truncation_suffix = if (truncated) " · Line: Truncated" else "";
    // A read of the whole file states the one number that matters. A read that
    // left part of the file out states the range against the total, which says
    // what stayed out without a count of its own.
    const summary = if (start == 0 and last + 1 == total)
        try std.fmt.allocPrint(gpa, "Lines: {d}{s}", .{ shown, truncation_suffix })
    else
        try std.fmt.allocPrint(gpa, "Lines: {d}–{d} of {d}{s}", .{
            start + 1, last + 1, total, truncation_suffix,
        });
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

test "read rejects invalid input" {
    const context: Context = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    try std.testing.expectError(error.InvalidArguments, run(&context, "{}"));
}

test "read of missing file reports an error" {
    const context: Context = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    const result = try run(&context,
        \\{"path":"/definitely/not/here.txt"}
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);
}

test "read paginates and points at the next offset" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.txt", .data = "one\ntwo\nthree" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"path":".zig-cache/tmp/{s}/f.txt","limit":1}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.startsWith(u8, result.content, "one\n"));
    try std.testing.expect(std.mem.indexOf(u8, result.content, "Use offset=2 to continue") != null);
    // The range against the total says what stayed out, so no second count
    // repeats it.
    try std.testing.expectEqualStrings("Lines: 1–1 of 3", result.summary.?.text);
}

test "read summarizes a fully shown file" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.txt", .data = "one\ntwo\nthree" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"path":".zig-cache/tmp/{s}/f.txt"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("Lines: 3", result.summary.?.text);
}

test "read does not count a trailing newline as an empty line" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.txt", .data = "one\n" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"path":".zig-cache/tmp/{s}/f.txt"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expectEqualStrings("one\n", result.content);
    try std.testing.expectEqualStrings("Lines: 1", result.summary.?.text);
}

test "read summarizes an empty file as zero lines" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.txt", .data = "" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"path":".zig-cache/tmp/{s}/f.txt"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expectEqualStrings("", result.content);
    try std.testing.expectEqualStrings("Lines: 0", result.summary.?.text);
}

test "read rejects an offset past the end of the file" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.txt", .data = "one\ntwo" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"path":".zig-cache/tmp/{s}/f.txt","offset":100000}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(result.is_error);
}

test "read rejects a zero limit" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.txt", .data = "one" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"path":".zig-cache/tmp/{s}/f.txt","limit":0}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(result.is_error);
}

test "read rejects a binary or non-UTF-8 file" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bin.dat", .data = "a\x00b" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "latin1.txt", .data = "caf\xE9" });
    for ([_][]const u8{ "bin.dat", "latin1.txt" }) |name| {
        var input_buf: [128]u8 = undefined;
        const input = try std.fmt.bufPrint(&input_buf,
            \\{{"path":".zig-cache/tmp/{s}/{s}"}}
        , .{ tmp.sub_path, name });
        const result = try run(&context, input);
        defer result.deinit(gpa);
        try std.testing.expect(result.is_error);
        try std.testing.expect(
            std.mem.indexOf(u8, result.content, "not a UTF-8 text file") != null,
        );
    }
}

test "read rejects an oversized file" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try gpa.alloc(u8, file_bytes_max + 1);
    defer gpa.free(data);
    @memset(data, 'a');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "big.txt", .data = data });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"path":".zig-cache/tmp/{s}/big.txt"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "larger than") != null);
}

test "read stops at the byte cap with a next-offset hint" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try gpa.alloc(u8, 60 * 1024);
    defer gpa.free(data);
    @memset(data, 'x');
    for (0..60) |i| data[i * 1024 + 1023] = '\n';
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "wide.txt", .data = data });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"path":".zig-cache/tmp/{s}/wide.txt"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(result.content.len <= bytes_max + 128);
    try std.testing.expect(
        std.mem.indexOf(u8, result.content, "Use offset=51 to continue") != null,
    );
}

test "read truncates to the line cap by default" {
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
        \\{{"path":".zig-cache/tmp/{s}/many.txt"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(
        std.mem.indexOf(u8, result.content, "Use offset=2001 to continue") != null,
    );
}

test "read canceled while opening propagates" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.txt", .data = "one" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"path":".zig-cache/tmp/{s}/f.txt"}}
    , .{tmp.sub_path});
    var cancel: fs.CancelIo = .init(.file_open);
    const context: Context = .{ .gpa = gpa, .io = cancel.io() };
    try std.testing.expectError(error.Canceled, run(&context, input));
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
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(result.content.len < bytes_max + 100);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "truncated") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.summary.?.text, "Line: Truncated") != null);
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
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(
        std.mem.indexOf(u8, result.content, "Use offset=2001 to continue") != null,
    );
}
