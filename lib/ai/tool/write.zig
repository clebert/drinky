//! Creates or overwrites a UTF-8 text file with the given contents.

const std = @import("std");

const format = @import("../format.zig");
const llm = @import("../llm.zig");
const Context = @import("Context.zig");
const Result = @import("Result.zig");
const fs = @import("fs.zig");
const parse = @import("parse.zig");

pub const spec: llm.Tool = .{
    .name = "write",
    .description = "Create or overwrite a UTF-8 text file with the given contents.",
    .parameters = &.{
        .{ .name = "path", .type = .string, .required = true, .description = "Path to the file" },
        .{
            .name = "content",
            .type = .string,
            .required = true,
            .description = "Full file contents; replaces the file entirely",
        },
    },
};

const Input = struct {
    path: []const u8,
    content: []const u8,
};

comptime {
    parse.check(Input, spec.parameters);
}

pub fn run(context: *const Context, input_json: []const u8) !Result {
    const gpa = context.gpa;
    const parsed = try parse.input(Input, gpa, input_json);
    defer parsed.deinit();
    const path = parsed.value.path;
    const contents = parsed.value.content;

    fs.writeFile(context.io, std.Io.Dir.cwd(), .{ .sub_path = path, .data = contents }) catch |err|
        return Result.cannot(gpa, err, "write", path);
    var result = try Result.report(gpa, .ok, "Pith wrote {d} bytes to {s}.", .{
        contents.len,
        path,
    });
    errdefer result.deinit(gpa);
    // The whole file is what the call produced, so the line counts it. `write`
    // never reads the file it replaces, so it cannot state a change. The model
    // keeps the exact byte count in the content above.
    result.summary = .{
        .text = try std.fmt.allocPrint(gpa, "Lines: {d}", .{format.lines(contents)}),
    };
    return result;
}

test "write creates a file with the given contents" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{ .gpa = gpa, .io = io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"path":".zig-cache/tmp/{s}/new.txt","content":"hello\nworld\n"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "wrote 12 bytes") != null);
    const data = try tmp.dir.readFileAlloc(io, "new.txt", gpa, .limited(64));
    defer gpa.free(data);
    try std.testing.expectEqualStrings("hello\nworld\n", data);
}

test "write overwrites an existing file entirely" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{ .gpa = gpa, .io = io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "old contents" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"path":".zig-cache/tmp/{s}/f.txt","content":"new"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    const data = try tmp.dir.readFileAlloc(io, "f.txt", gpa, .limited(64));
    defer gpa.free(data);
    try std.testing.expectEqualStrings("new", data);
}

test "write to a missing directory reports an error" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"path":".zig-cache/tmp/{s}/missing/f.txt","content":"x"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "could not write") != null);
}

test "write canceled mid-write propagates and leaves the file untouched" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "old" });
    var input_buf: [128]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"path":".zig-cache/tmp/{s}/f.txt","content":"new"}}
    , .{tmp.sub_path});
    var cancel: fs.CancelIo = .init(.file_write);
    const context: Context = .{ .gpa = gpa, .io = cancel.io() };
    try std.testing.expectError(error.Canceled, run(&context, input));
    const data = try tmp.dir.readFileAlloc(io, "f.txt", gpa, .limited(64));
    defer gpa.free(data);
    try std.testing.expectEqualStrings("old", data);
}

// `write` and `read` count lines under one rule, so a write and a read of the
// same bytes cannot disagree about the number.
test "the box reports the lines of what was written" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{ .gpa = gpa, .io = io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var input_buf: [160]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"path":".zig-cache/tmp/{s}/sample.txt","content":"one\ntwo\nthree\n"}}
    , .{tmp.sub_path});

    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    // A closing line break ends the third line, it does not open a fourth.
    try std.testing.expectEqualStrings("Lines: 3", result.summary.?.text);
}
