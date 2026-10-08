const std = @import("std");

const core = @import("core");

const Context = @import("Context.zig");
const format = @import("format.zig");
const fs = @import("fs.zig");
const output = @import("output.zig");
const parse = @import("parse.zig");
const testing = @import("testing.zig");

pub const spec: core.Tool = .{
    .name = "edit",
    .description = "Replace an exact, unique span of text in an existing file. The old_text " ++
        "must occur exactly once in the file. Include enough context around it to make it " ++
        "unique.",
    .parameters = &.{
        .{ .name = "path", .type = .string, .required = true, .description = "Path to the file" },
        .{
            .name = "old_text",
            .type = .string,
            .required = true,
            .description = "Exact text to replace. It must occur exactly once.",
        },
        .{
            .name = "new_text",
            .type = .string,
            .required = true,
            .description = "Replacement text",
        },
    },
    .mutates = true,
};

const Input = struct {
    path: []const u8,
    old_text: []const u8,
    new_text: []const u8,
};

comptime {
    parse.check(Input, spec.parameters);
}

pub fn run(context: *const Context, input_json: []const u8) Context.Error!core.Tool.Output {
    const gpa = context.gpa;
    const parsed = try parse.input(Input, gpa, input_json);
    defer parsed.deinit();
    const path = parsed.value.path;
    const old = parsed.value.old_text;
    const new = parsed.value.new_text;

    const data = fs.readFile(gpa, context.host.io, path) catch |err|
        return fs.readFailure(gpa, err, "edit", path);
    defer gpa.free(data);

    const updated = applyEdit(gpa, &.{ .data = data, .old = old, .new = new }) catch |err|
        switch (err) {
            error.EmptyOldText => return output.failure(
                gpa,
                .invalid_arguments,
                "Set old_text to a nonempty value.",
                .{},
            ),
            error.NotFound => return output.failure(
                gpa,
                .target_missing,
                "Drinky did not find old_text in {s}.",
                .{path},
            ),
            error.NotUnique => return output.failure(
                gpa,
                .target_ambiguous,
                "Drinky found old_text more than once in {s}. Add more text before and " ++
                    "after old_text.",
                .{path},
            ),
            error.OutOfMemory => return error.OutOfMemory,
        };
    defer gpa.free(updated);

    fs.writeFile(gpa, context.host.io, &.{ .path = path, .data = updated }) catch |err|
        return output.cannot(gpa, err, "write", path);
    var result = try output.sentence(gpa, "Drinky edited {s}.", .{path});
    result.measures.put(.lines_removed, format.lines(old));
    result.measures.put(.lines_added, format.lines(new));
    return result;
}

fn applyEdit(
    gpa: std.mem.Allocator,
    edit: *const struct { data: []const u8, old: []const u8, new: []const u8 },
) error{ EmptyOldText, NotFound, NotUnique, OutOfMemory }![]u8 {
    if (edit.old.len == 0) return error.EmptyOldText;
    const index = std.mem.find(u8, edit.data, edit.old) orelse return error.NotFound;
    if (std.mem.findPos(u8, edit.data, index + 1, edit.old) != null) return error.NotUnique;
    return gpa.print("{s}{s}{s}", .{
        edit.data[0..index],
        edit.new,
        edit.data[index + edit.old.len ..],
    });
}

test applyEdit {
    const gpa = std.testing.allocator;

    const updated = try applyEdit(gpa, &.{ .data = "one two three", .old = "two", .new = "2" });
    defer gpa.free(updated);
    try std.testing.expectEqualStrings("one 2 three", updated);

    try std.testing.expectError(
        error.NotFound,
        applyEdit(gpa, &.{ .data = "abc", .old = "z", .new = "y" }),
    );
    try std.testing.expectError(
        error.NotUnique,
        applyEdit(gpa, &.{ .data = "a a a", .old = "a", .new = "b" }),
    );
    try std.testing.expectError(
        error.NotUnique,
        applyEdit(gpa, &.{ .data = "aaa", .old = "aa", .new = "b" }),
    );
    try std.testing.expectError(
        error.EmptyOldText,
        applyEdit(gpa, &.{ .data = "abc", .old = "", .new = "y" }),
    );
}

test "edit rewrites the file on disk" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = io } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "one two three" });
    var input_buffer: [160]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/f.txt","old_text":"two","new_text":"2"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.hasFailure());
    try std.testing.expect(std.mem.find(u8, result.content, "edited") != null);
    const data = try tmp.dir.readFileAlloc(io, "f.txt", gpa, .limited(64));
    defer gpa.free(data);
    try std.testing.expectEqualStrings("one 2 three", data);
}

test "an edit through a link changes the target, and an edited file keeps its mode" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = io } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "one two three" });
    try tmp.dir.symLink(io, "AGENTS.md", "CLAUDE.md", .{});
    try tmp.dir.writeFile(io, .{ .sub_path = "run.sh", .data = "echo one" });
    try tmp.dir.setFilePermissions(io, "run.sh", .fromMode(0o755), .{});
    var input_buffer: [160]u8 = undefined;

    const linked = try std.mem.print(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/CLAUDE.md","old_text":"two","new_text":"2"}}
    , .{tmp.sub_path});
    const through = try run(&context, linked);
    defer through.deinit(gpa);
    try std.testing.expect(!through.hasFailure());
    const data = try tmp.dir.readFileAlloc(io, "AGENTS.md", gpa, .limited(64));
    defer gpa.free(data);
    try std.testing.expectEqualStrings("one 2 three", data);
    var link_buffer: [64]u8 = undefined;
    const link_len = try tmp.dir.readLink(io, "CLAUDE.md", &link_buffer);
    try std.testing.expectEqualStrings("AGENTS.md", link_buffer[0..link_len]);

    const script = try std.mem.print(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/run.sh","old_text":"one","new_text":"two"}}
    , .{tmp.sub_path});
    const kept = try run(&context, script);
    defer kept.deinit(gpa);
    try std.testing.expect(!kept.hasFailure());
    const stat = try tmp.dir.statFile(io, "run.sh", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o755), stat.permissions.toMode() & 0o777);
}

test "edit measures the lines it took out and put in" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = io } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "one\ntwo\nthree\nfour\n" });
    var input_buffer: [192]u8 = undefined;
    {
        const input = try std.mem.print(&input_buffer,
            \\{{"path":".zig-cache/tmp/{s}/f.txt","old_text":"two\nthree","new_text":"2"}}
        , .{tmp.sub_path});
        const result = try run(&context, input);
        defer result.deinit(gpa);
        try testing.expectMeasures(&result, &.{ .{ .lines_removed, 2 }, .{ .lines_added, 1 } });
        try testing.expectConditions(&result, &.{});
    }
    {
        const input = try std.mem.print(&input_buffer,
            \\{{"path":".zig-cache/tmp/{s}/f.txt","old_text":"2\n","new_text":""}}
        , .{tmp.sub_path});
        const result = try run(&context, input);
        defer result.deinit(gpa);
        try testing.expectMeasures(&result, &.{ .{ .lines_removed, 1 }, .{ .lines_added, 0 } });
    }
}

test "a missing or ambiguous old_text names its condition" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = io } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "one two two" });
    var input_buffer: [192]u8 = undefined;
    const cases = [_]struct { old: []const u8, condition: core.Tool.Condition }{
        .{ .old = "three", .condition = .target_missing },
        .{ .old = "two", .condition = .target_ambiguous },
        .{ .old = "", .condition = .invalid_arguments },
    };
    for (cases) |case| {
        const input = try std.mem.print(&input_buffer,
            \\{{"path":".zig-cache/tmp/{s}/f.txt","old_text":"{s}","new_text":"2"}}
        , .{ tmp.sub_path, case.old });
        const result = try run(&context, input);
        defer result.deinit(gpa);
        try testing.expectConditions(&result, &.{case.condition});
        try testing.expectMeasures(&result, &.{});
    }
    const kept = try tmp.dir.readFileAlloc(io, "f.txt", gpa, .limited(64));
    defer gpa.free(kept);
    try std.testing.expectEqualStrings("one two two", kept);
}

test "edit canceled while reading propagates" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.txt", .data = "one two three" });
    var input_buffer: [160]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/f.txt","old_text":"two","new_text":"2"}}
    , .{tmp.sub_path});
    var cancel: testing.CancelIo = .init(.file_open);
    const context: Context = .{ .gpa = gpa, .host = .{ .io = cancel.io() } };
    try std.testing.expectError(error.Canceled, run(&context, input));
}

test "edit canceled mid-write propagates and leaves the file untouched" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "one two three" });
    var input_buffer: [160]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/f.txt","old_text":"two","new_text":"2"}}
    , .{tmp.sub_path});
    var cancel: testing.CancelIo = .init(.file_write);
    const context: Context = .{ .gpa = gpa, .host = .{ .io = cancel.io() } };
    try std.testing.expectError(error.Canceled, run(&context, input));
    const data = try tmp.dir.readFileAlloc(io, "f.txt", gpa, .limited(64));
    defer gpa.free(data);
    try std.testing.expectEqualStrings("one two three", data);
}

test "edit rejects an oversized file" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .host = .{ .io = std.testing.io } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try gpa.alloc(u8, fs.file_bytes_max + 1);
    defer gpa.free(data);
    @memset(data, 'a');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "big.txt", .data = data });
    var input_buffer: [160]u8 = undefined;
    const input = try std.mem.print(&input_buffer,
        \\{{"path":".zig-cache/tmp/{s}/big.txt","old_text":"a","new_text":"b"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try testing.expectConditions(&result, &.{.path_too_large});
    try std.testing.expect(std.mem.find(u8, result.content, "larger than") != null);
}
