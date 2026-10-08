const std = @import("std");

const core = @import("core");

const Context = @import("Context.zig");
const format = @import("format.zig");
const fs = @import("fs.zig");
const output = @import("output.zig");
const parse = @import("parse.zig");
const testing = @import("testing.zig");

pub const spec: core.Tool = .{
    .name = "write",
    .description = "Create or overwrite a UTF-8 text file with the given contents.",
    .parameters = &.{
        .{ .name = "path", .type = .string, .required = true, .description = "Path to the file" },
        .{
            .name = "content",
            .type = .string,
            .required = true,
            .description = "Complete content that replaces the file",
        },
    },
    .mutates = true,
};

const Input = struct {
    path: []const u8,
    content: []const u8,
};

comptime {
    parse.check(Input, spec.parameters);
}

pub fn run(context: *const Context, input_json: []const u8) Context.Error!core.Tool.Output {
    const gpa = context.gpa;
    const parsed = try parse.input(Input, gpa, input_json);
    defer parsed.deinit();
    const path = parsed.value.path;
    const content = parsed.value.content;

    fs.writeFile(gpa, context.host.io, &.{ .path = path, .data = content }) catch |err|
        return output.cannot(gpa, err, "write", path);
    var result = try output.sentence(gpa, "Drinky wrote {d} byte{s} to {s}.", .{
        content.len,
        core.text.pluralSuffix(content.len),
        path,
    });
    result.measures.put(.lines, format.lines(content));
    return result;
}

test "write creates a file with the given contents" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = io } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var input_buffer: [128]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/new.txt","content":"hello\nworld\n"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    try std.testing.expect(std.mem.find(u8, result.content, "wrote 12 bytes") != null);
    const data = try tmp.dir.readFileAlloc(io, "new.txt", gpa, .limited(64));
    defer gpa.free(data);
    try std.testing.expectEqualStrings("hello\nworld\n", data);
}

test "write overwrites an existing file entirely" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = io } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "old contents" });
    var input_buffer: [128]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/f.txt","content":"new"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    const data = try tmp.dir.readFileAlloc(io, "f.txt", gpa, .limited(64));
    defer gpa.free(data);
    try std.testing.expectEqualStrings("new", data);
}

test "a write through a dangling link creates the target and keeps the link" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = io } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.symLink(io, "AGENTS.md", "CLAUDE.md", .{});
    var input_buffer: [128]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/CLAUDE.md","content":"new"}}
    , .{tmp.sub_path});

    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    const data = try tmp.dir.readFileAlloc(io, "AGENTS.md", gpa, .limited(64));
    defer gpa.free(data);
    try std.testing.expectEqualStrings("new", data);
    var link_buffer: [64]u8 = undefined;
    const link_len = try tmp.dir.readLink(io, "CLAUDE.md", &link_buffer);
    try std.testing.expectEqualStrings("AGENTS.md", link_buffer[0..link_len]);
}

test "a write through a link cycle fails and keeps both links" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = io } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.symLink(io, "b.md", "a.md", .{});
    try tmp.dir.symLink(io, "a.md", "b.md", .{});
    var input_buffer: [128]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/a.md","content":"new"}}
    , .{tmp.sub_path});

    const result = try run(&context, input);
    defer result.deinit(gpa);
    try testing.expectConditions(&result, &.{.failed});
    try std.testing.expect(std.mem.find(u8, result.content, "SymLinkLoop") != null);
    var link_buffer: [64]u8 = undefined;
    for ([_][2][]const u8{ .{ "a.md", "b.md" }, .{ "b.md", "a.md" } }) |link| {
        const link_len = try tmp.dir.readLink(io, link[0], &link_buffer);
        try std.testing.expectEqualStrings(link[1], link_buffer[0..link_len]);
    }
}

test "write to a missing directory reports an error" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = std.testing.io } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var input_buffer: [128]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/missing/f.txt","content":"x"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try testing.expectConditions(&result, &.{.path_missing});
    try testing.expectMeasures(&result, &.{});
    try std.testing.expect(std.mem.find(u8, result.content, "could not write") != null);
}

test "write canceled mid-write propagates and leaves the file untouched" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "old" });
    var input_buffer: [128]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/f.txt","content":"new"}}
    , .{tmp.sub_path});
    var cancel: testing.CancelIo = .init(.file_write);
    const context: Context = .{ .gpa = gpa, .host = .{ .io = cancel.io() } };
    try std.testing.expectError(error.Canceled, run(&context, input));
    const data = try tmp.dir.readFileAlloc(io, "f.txt", gpa, .limited(64));
    defer gpa.free(data);
    try std.testing.expectEqualStrings("old", data);
}

test "write measures the lines of what it wrote" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = io } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var input_buffer: [160]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/sample.txt","content":"one\ntwo\nthree\n"}}
    , .{tmp.sub_path});

    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    try testing.expectMeasures(&result, &.{.{ .lines, 3 }});
    try testing.expectConditions(&result, &.{});
}
