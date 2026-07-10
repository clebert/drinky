//! Creates or overwrites a UTF-8 text file with the given contents.

const std = @import("std");

const llm = @import("../llm.zig");
const Context = @import("Context.zig");
const Result = @import("Result.zig");
const field = @import("field.zig");

pub const spec: llm.Tool = .{
    .name = "write",
    .description = "Create or overwrite a UTF-8 text file with the given contents.",
    .schema_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file"},"content":{"type":"string","description":"Full file contents; replaces the file entirely"}},"required":["path","content"]}
    ,
};

pub fn run(context: *const Context, input_json: []const u8) !Result {
    const gpa = context.gpa;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, input_json, .{});
    defer parsed.deinit();
    const path = field.string(parsed.value, "path") orelse return Result.report(gpa, .err, "missing 'path'", .{});
    const contents = field.string(parsed.value, "content") orelse return Result.report(gpa, .err, "missing 'content'", .{});

    std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = path, .data = contents }) catch |err| {
        return Result.report(gpa, .err, "cannot write {s}: {s}", .{ path, @errorName(err) });
    };
    return Result.report(gpa, .ok, "wrote {d} bytes to {s}", .{ contents.len, path });
}
