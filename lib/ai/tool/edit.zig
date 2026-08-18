//! Replaces one exact, unique span of text in an existing file.

const std = @import("std");

const format = @import("../format.zig");
const llm = @import("../llm.zig");
const Context = @import("Context.zig");
const fs = @import("fs.zig");
const parse = @import("parse.zig");
const Result = @import("Result.zig");

const file_bytes_max = 16 << 20;

pub const spec: llm.Tool = .{
    .name = "edit",
    .description = "Replace an exact, unique span of text in an existing file. old_text " ++
        "must occur exactly once; include enough surrounding context to make it unique.",
    .parameters = &.{
        .{ .name = "path", .type = .string, .required = true, .description = "Path to the file" },
        .{
            .name = "old_text",
            .type = .string,
            .required = true,
            .description = "Exact text to replace; must occur exactly once",
        },
        .{
            .name = "new_text",
            .type = .string,
            .required = true,
            .description = "Replacement text",
        },
    },
};

const Input = struct {
    path: []const u8,
    old_text: []const u8,
    new_text: []const u8,
};

comptime {
    parse.check(Input, spec.parameters);
}

pub fn run(context: *const Context, input_json: []const u8) !Result {
    const gpa = context.gpa;
    const parsed = try parse.input(Input, gpa, input_json);
    defer parsed.deinit();
    const path = parsed.value.path;
    const old = parsed.value.old_text;
    const new = parsed.value.new_text;

    const data = std.Io.Dir.cwd().readFileAlloc(
        context.io,
        path,
        gpa,
        .limited(file_bytes_max),
    ) catch |err| switch (err) {
        error.StreamTooLong => return Result.report(
            gpa,
            .err,
            "Pith cannot edit {s} because it is larger than {d} bytes.",
            .{ path, file_bytes_max },
        ),
        else => return Result.cannot(gpa, err, "read", path),
    };
    defer gpa.free(data);

    const updated = applyEdit(gpa, .{ .data = data, .old = old, .new = new }) catch |err|
        switch (err) {
            error.EmptyOldText => return Result.report(
                gpa,
                .err,
                "Set old_text to a nonempty value.",
                .{},
            ),
            error.NotFound => return Result.report(
                gpa,
                .err,
                "Pith did not find old_text in {s}.",
                .{path},
            ),
            error.NotUnique => return Result.report(
                gpa,
                .err,
                "Pith found old_text more than once in {s}. Add more text before and " ++
                    "after old_text.",
                .{path},
            ),
            else => return err,
        };
    defer gpa.free(updated);

    fs.writeFile(context.io, std.Io.Dir.cwd(), .{ .sub_path = path, .data = updated }) catch |err|
        return Result.cannot(gpa, err, "write", path);
    var result = try Result.report(gpa, .ok, "Pith edited {s}.", .{path});
    errdefer result.deinit(gpa);
    // The line counts the lines `old_text` took out against the lines
    // `new_text` put in, and it borrows the `-` and `+` of a diff to show them.
    // The two numbers measure the span the call replaced, not the lines that
    // differ inside it, so an edit that rewrites part of a line reports that
    // whole line on both sides. The size of the file the edit left says nothing
    // about what the call did.
    result.summary = .{ .text = try std.fmt.allocPrint(gpa, "Lines: -{d} +{d}", .{
        format.lines(old),
        format.lines(new),
    }) };
    return result;
}

/// Replace the single occurrence of `edit.old` in `edit.data` with `edit.new`.
/// Errors when the match is absent or ambiguous so the caller never edits the
/// wrong span. A second match that starts anywhere past the first — even an
/// overlapping one like "aa" in "aaa" — counts as ambiguous.
fn applyEdit(
    gpa: std.mem.Allocator,
    edit: struct { data: []const u8, old: []const u8, new: []const u8 },
) ![]u8 {
    if (edit.old.len == 0) return error.EmptyOldText;
    const index = std.mem.indexOf(u8, edit.data, edit.old) orelse return error.NotFound;
    if (std.mem.indexOfPos(u8, edit.data, index + 1, edit.old) != null) return error.NotUnique;
    return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{
        edit.data[0..index],
        edit.new,
        edit.data[index + edit.old.len ..],
    });
}

test applyEdit {
    const gpa = std.testing.allocator;

    const updated = try applyEdit(gpa, .{ .data = "one two three", .old = "two", .new = "2" });
    defer gpa.free(updated);
    try std.testing.expectEqualStrings("one 2 three", updated);

    try std.testing.expectError(
        error.NotFound,
        applyEdit(gpa, .{ .data = "abc", .old = "z", .new = "y" }),
    );
    try std.testing.expectError(
        error.NotUnique,
        applyEdit(gpa, .{ .data = "a a a", .old = "a", .new = "b" }),
    );
    try std.testing.expectError(
        error.NotUnique,
        applyEdit(gpa, .{ .data = "aaa", .old = "aa", .new = "b" }),
    );
    try std.testing.expectError(
        error.EmptyOldText,
        applyEdit(gpa, .{ .data = "abc", .old = "", .new = "y" }),
    );
}

test "edit rewrites the file on disk" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{ .gpa = gpa, .io = io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "one two three" });
    var input_buf: [160]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"path":".zig-cache/tmp/{s}/f.txt","old_text":"two","new_text":"2"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "edited") != null);
    const data = try tmp.dir.readFileAlloc(io, "f.txt", gpa, .limited(64));
    defer gpa.free(data);
    try std.testing.expectEqualStrings("one 2 three", data);
}

// The box line counts the span the call replaced, in the `-` and `+` of a diff.
// A replacement inside one line takes that whole line out and puts one line in.
// A deletion puts none in.
test "the box reports the lines the edit took out and put in" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const context: Context = .{ .gpa = gpa, .io = io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "one\ntwo\nthree\nfour\n" });
    var input_buf: [192]u8 = undefined;
    {
        const input = try std.fmt.bufPrint(&input_buf,
            \\{{"path":".zig-cache/tmp/{s}/f.txt","old_text":"two\nthree","new_text":"2"}}
        , .{tmp.sub_path});
        const result = try run(&context, input);
        defer result.deinit(gpa);
        try std.testing.expectEqualStrings("Lines: -2 +1", result.summary.?.text);
    }
    {
        const input = try std.fmt.bufPrint(&input_buf,
            \\{{"path":".zig-cache/tmp/{s}/f.txt","old_text":"2\n","new_text":""}}
        , .{tmp.sub_path});
        const result = try run(&context, input);
        defer result.deinit(gpa);
        try std.testing.expectEqualStrings("Lines: -1 +0", result.summary.?.text);
    }
}

test "edit canceled while reading propagates" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.txt", .data = "one two three" });
    var input_buf: [160]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"path":".zig-cache/tmp/{s}/f.txt","old_text":"two","new_text":"2"}}
    , .{tmp.sub_path});
    var cancel: fs.CancelIo = .init(.file_open);
    const context: Context = .{ .gpa = gpa, .io = cancel.io() };
    try std.testing.expectError(error.Canceled, run(&context, input));
}

test "edit canceled mid-write propagates and leaves the file untouched" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "one two three" });
    var input_buf: [160]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"path":".zig-cache/tmp/{s}/f.txt","old_text":"two","new_text":"2"}}
    , .{tmp.sub_path});
    var cancel: fs.CancelIo = .init(.file_write);
    const context: Context = .{ .gpa = gpa, .io = cancel.io() };
    try std.testing.expectError(error.Canceled, run(&context, input));
    const data = try tmp.dir.readFileAlloc(io, "f.txt", gpa, .limited(64));
    defer gpa.free(data);
    try std.testing.expectEqualStrings("one two three", data);
}

test "edit rejects an oversized file" {
    const gpa = std.testing.allocator;
    const context: Context = .{ .gpa = gpa, .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try gpa.alloc(u8, file_bytes_max + 1);
    defer gpa.free(data);
    @memset(data, 'a');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "big.txt", .data = data });
    var input_buf: [160]u8 = undefined;
    const input = try std.fmt.bufPrint(&input_buf,
        \\{{"path":".zig-cache/tmp/{s}/big.txt","old_text":"a","new_text":"b"}}
    , .{tmp.sub_path});
    const result = try run(&context, input);
    defer result.deinit(gpa);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "larger than") != null);
}
