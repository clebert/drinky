//! Replaces one exact, unique span of text in an existing file.

const std = @import("std");

const llm = @import("../llm.zig");
const Context = @import("Context.zig");
const Result = @import("Result.zig");
const field = @import("field.zig");

pub const spec: llm.Tool = .{
    .name = "edit",
    .description = "Replace an exact, unique span of text in an existing file. old_text must occur exactly once; include enough surrounding context to make it unique.",
    .schema_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file"},"old_text":{"type":"string","description":"Exact text to replace; must occur exactly once"},"new_text":{"type":"string","description":"Replacement text"}},"required":["path","old_text","new_text"]}
    ,
};

pub fn run(context: *const Context, input_json: []const u8) !Result {
    const gpa = context.gpa;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, input_json, .{});
    defer parsed.deinit();
    const path = field.string(parsed.value, "path") orelse return Result.report(gpa, .err, "missing 'path'", .{});
    const old = field.string(parsed.value, "old_text") orelse return Result.report(gpa, .err, "missing 'old_text'", .{});
    const new = field.string(parsed.value, "new_text") orelse return Result.report(gpa, .err, "missing 'new_text'", .{});

    const data = std.Io.Dir.cwd().readFileAlloc(context.io, path, gpa, .unlimited) catch |err| {
        return Result.report(gpa, .err, "cannot read {s}: {s}", .{ path, @errorName(err) });
    };
    defer gpa.free(data);

    const updated = applyEdit(gpa, .{ .data = data, .old = old, .new = new }) catch |err| switch (err) {
        error.EmptyOldText => return Result.report(gpa, .err, "old_text must not be empty", .{}),
        error.NotFound => return Result.report(gpa, .err, "old_text not found in {s}", .{path}),
        error.NotUnique => return Result.report(gpa, .err, "old_text is not unique in {s}; include more surrounding context", .{path}),
        else => return err,
    };
    defer gpa.free(updated);

    std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = path, .data = updated }) catch |err| {
        return Result.report(gpa, .err, "cannot write {s}: {s}", .{ path, @errorName(err) });
    };
    return Result.report(gpa, .ok, "edited {s}", .{path});
}

/// Replace the single occurrence of `edit.old` in `edit.data` with `edit.new`.
/// Errors when the match is absent or ambiguous so the caller never edits the
/// wrong span. A second match starting anywhere past the first — including an
/// overlapping one like "aa" in "aaa" — counts as ambiguous.
fn applyEdit(
    gpa: std.mem.Allocator,
    edit: struct { data: []const u8, old: []const u8, new: []const u8 },
) ![]u8 {
    if (edit.old.len == 0) return error.EmptyOldText;
    const index = std.mem.indexOf(u8, edit.data, edit.old) orelse return error.NotFound;
    if (std.mem.indexOfPos(u8, edit.data, index + 1, edit.old) != null) return error.NotUnique;
    return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ edit.data[0..index], edit.new, edit.data[index + edit.old.len ..] });
}

test applyEdit {
    const gpa = std.testing.allocator;

    const updated = try applyEdit(gpa, .{ .data = "one two three", .old = "two", .new = "2" });
    defer gpa.free(updated);
    try std.testing.expectEqualStrings("one 2 three", updated);

    try std.testing.expectError(error.NotFound, applyEdit(gpa, .{ .data = "abc", .old = "z", .new = "y" }));
    try std.testing.expectError(error.NotUnique, applyEdit(gpa, .{ .data = "a a a", .old = "a", .new = "b" }));
    try std.testing.expectError(error.NotUnique, applyEdit(gpa, .{ .data = "aaa", .old = "aa", .new = "b" }));
    try std.testing.expectError(error.EmptyOldText, applyEdit(gpa, .{ .data = "abc", .old = "", .new = "y" }));
}
