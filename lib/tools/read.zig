const std = @import("std");

const core = @import("core");

const Context = @import("Context.zig");
const format = @import("format.zig");
const fs = @import("fs.zig");
const output = @import("output.zig");
const parse = @import("parse.zig");
const testing = @import("testing.zig");

pub const lines_max = 2000;
pub const bytes_max = 50 * 1024;

pub const spec: core.Tool = .{
    .name = "read",
    .description = std.fmt.comptimePrint(
        "Read a UTF-8 text file. The output stops at {d} lines or {d} KiB, whichever comes " ++
            "first. Use offset and limit to read a large file in parts. The output names the " ++
            "offset of the next part.",
        .{ lines_max, @divExact(bytes_max, 1024) },
    ),
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
            .description = "1-indexed number of the first line to read (default: 1)",
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

pub fn run(context: *const Context, input_json: []const u8) Context.Error!core.Tool.Output {
    const gpa = context.gpa;
    const parsed = try parse.input(Input, gpa, input_json);
    defer parsed.deinit();
    const path = parsed.value.path;
    const offset = parsed.value.offset;
    const limit = parsed.value.limit;

    const data = fs.readFile(gpa, context.host.io, path) catch |err|
        return fs.readFailure(gpa, err, "read", path);
    defer gpa.free(data);

    if (!format.isText(data)) {
        return output.failure(
            gpa,
            .path_not_text,
            "Drinky cannot read {s} because it is not a UTF-8 text file.",
            .{path},
        );
    }

    const total = format.lines(data);
    const start = if (offset > 0) offset - 1 else 0;
    if (start >= total and !(total == 0 and start == 0)) {
        return output.failure(
            gpa,
            .invalid_arguments,
            "Line offset {d} is after the last line in {s}. The file has {d} line{s}.",
            .{ offset, path, total, core.text.pluralSuffix(total) },
        );
    }
    const shown_max = @min(limit orelse lines_max, lines_max);
    if (shown_max == 0)
        return output.failure(gpa, .invalid_arguments, "Set limit to 1 or more.", .{});

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
        if (shown == 0 and line.len > bytes_max) {
            try out.writer.writeAll(format.truncate(line, bytes_max));
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
    if (total > 0 and !truncated and (last + 1 < total or data[data.len - 1] == '\n'))
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

    var result: core.Tool.Output = .{ .content = try out.toOwnedSlice() };
    result.measures.put(.lines, shown);
    result.measures.put(.line_first, start + 1);
    result.measures.put(.lines_total, total);
    if (truncated) result.conditions.insert(.line_truncated);
    return result;
}

test "read rejects invalid input" {
    const context: Context = .{ .gpa = std.testing.allocator, .host = .{ .io = std.testing.io } };
    try std.testing.expectError(error.InvalidArguments, run(&context, "{}"));
}

test "read of missing file reports an error" {
    const context: Context = .{ .gpa = std.testing.allocator, .host = .{ .io = std.testing.io } };
    const result = try run(&context,
        \\{"path":"/definitely/not/here.txt"}
    );
    defer result.deinit(std.testing.allocator);
    try testing.expectConditions(&result, &.{.path_missing});
    try testing.expectMeasures(&result, &.{});
}

test "read paginates and points at the next offset" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = std.testing.io } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.txt", .data = "one\ntwo\nthree" });
    var input_buffer: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/f.txt","limit":1}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    try std.testing.expect(std.mem.startsWith(u8, result.content, "one\n"));
    try std.testing.expect(std.mem.indexOf(u8, result.content, "Use offset=2 to continue") != null);
    try testing.expectMeasures(&result, &.{
        .{ .lines, 1 },
        .{ .line_first, 1 },
        .{ .lines_total, 3 },
    });
    try testing.expectConditions(&result, &.{});
}

test "read measures a fully shown file" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = std.testing.io } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.txt", .data = "one\ntwo\nthree" });
    var input_buffer: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/f.txt"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    try testing.expectMeasures(&result, &.{
        .{ .lines, 3 },
        .{ .line_first, 1 },
        .{ .lines_total, 3 },
    });
}

test "read does not count a trailing newline as an empty line" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = std.testing.io } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.txt", .data = "one\n" });
    var input_buffer: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/f.txt"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expectEqualStrings("one\n", result.content);
    try testing.expectMeasures(&result, &.{
        .{ .lines, 1 },
        .{ .line_first, 1 },
        .{ .lines_total, 1 },
    });
}

test "read measures an empty file as zero lines" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = std.testing.io } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.txt", .data = "" });
    var input_buffer: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/f.txt"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expectEqualStrings("", result.content);
    try testing.expectMeasures(&result, &.{
        .{ .lines, 0 },
        .{ .line_first, 1 },
        .{ .lines_total, 0 },
    });
}

test "read rejects an offset past the end of the file and names its line count" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = std.testing.io } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "two.txt", .data = "one\ntwo" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "one.txt", .data = "one\n" });
    const cases = [_]struct { name: []const u8, count: []const u8 }{
        .{ .name = "two.txt", .count = "The file has 2 lines." },
        .{ .name = "one.txt", .count = "The file has 1 line." },
    };
    for (cases) |case| {
        var input_buffer: [128]u8 = undefined;
        const input = try std.fmt.bufPrint(&input_buffer,
            \\{{"path":".zig-cache/tmp/{s}/{s}","offset":100000}}
        , .{ tmp.sub_path, case.name });
        const result = try run(&context, input);
        defer result.deinit(gpa);
        try testing.expectConditions(&result, &.{.invalid_arguments});
        try std.testing.expectStringEndsWith(result.content, case.count);
    }
}

test "read rejects a zero limit" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = std.testing.io } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.txt", .data = "one" });
    var input_buffer: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/f.txt","limit":0}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try testing.expectConditions(&result, &.{.invalid_arguments});
}

test "read rejects a binary or non-UTF-8 file" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = std.testing.io } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bin.dat", .data = "a\x00b" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "latin1.txt", .data = "caf\xE9" });
    for ([_][]const u8{ "bin.dat", "latin1.txt" }) |name| {
        var input_buffer: [128]u8 = undefined;
        const input = try std.fmt.bufPrint(&input_buffer,
            \\{{"path":".zig-cache/tmp/{s}/{s}"}}
        , .{ tmp.sub_path, name });
        const result = try run(&context, input);
        defer result.deinit(gpa);
        try testing.expectConditions(&result, &.{.path_not_text});
        try std.testing.expect(
            std.mem.indexOf(u8, result.content, "not a UTF-8 text file") != null,
        );
    }
}

test "read rejects an oversized file" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = std.testing.io } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try gpa.alloc(u8, fs.file_bytes_max + 1);
    defer gpa.free(data);
    @memset(data, 'a');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "big.txt", .data = data });
    var input_buffer: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/big.txt"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try testing.expectConditions(&result, &.{.path_too_large});
    try std.testing.expect(std.mem.indexOf(u8, result.content, "larger than") != null);
}

test "read stops at the byte cap with a next-offset hint" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = std.testing.io } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try gpa.alloc(u8, 60 * 1024);
    defer gpa.free(data);
    @memset(data, 'x');
    for (0..60) |index| data[index * 1024 + 1023] = '\n';
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "wide.txt", .data = data });
    var input_buffer: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/wide.txt"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    try std.testing.expect(result.content.len <= bytes_max + 128);
    try std.testing.expect(
        std.mem.indexOf(u8, result.content, "Use offset=51 to continue") != null,
    );
    try testing.expectMeasures(&result, &.{
        .{ .lines, 50 },
        .{ .line_first, 1 },
        .{ .lines_total, 60 },
    });
}

test "read truncates to the line cap by default" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = std.testing.io } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try gpa.alloc(u8, (lines_max + 100) * 2);
    defer gpa.free(data);
    for (0..lines_max + 100) |index| {
        data[index * 2] = 'x';
        data[index * 2 + 1] = '\n';
    }
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "many.txt", .data = data });
    var input_buffer: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/many.txt"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    try std.testing.expect(
        std.mem.indexOf(u8, result.content, "Use offset=2001 to continue") != null,
    );
}

test "read canceled while opening propagates" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.txt", .data = "one" });
    var input_buffer: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/f.txt"}}
    , .{tmp.sub_path});
    var cancel: testing.CancelIo = .init(.file_open);
    const context: Context = .{ .gpa = gpa, .host = .{ .io = cancel.io() } };
    try std.testing.expectError(error.Canceled, run(&context, input));
}

test "read truncates a single line longer than the byte cap" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = std.testing.io } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const line = try gpa.alloc(u8, bytes_max + 100);
    defer gpa.free(line);
    @memset(line, 'a');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "long.txt", .data = line });
    var input_buffer: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/long.txt"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    try std.testing.expect(result.content.len < bytes_max + 100);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "truncated") != null);
    try testing.expectConditions(&result, &.{.line_truncated});
    try testing.expectMeasures(&result, &.{
        .{ .lines, 1 },
        .{ .line_first, 1 },
        .{ .lines_total, 1 },
    });
}

test "read clamps an explicit limit to the line cap" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = std.testing.io } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try gpa.alloc(u8, (lines_max + 100) * 2);
    defer gpa.free(data);
    for (0..lines_max + 100) |index| {
        data[index * 2] = 'x';
        data[index * 2 + 1] = '\n';
    }
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "many.txt", .data = data });
    var input_buffer: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/many.txt","limit":100000}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    try std.testing.expect(
        std.mem.indexOf(u8, result.content, "Use offset=2001 to continue") != null,
    );
}
