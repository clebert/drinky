//! The tools the model may call, and their execution. Each tool takes the raw
//! JSON input from a `tool_use` block and returns text for the matching
//! `tool_result`. File access is relative to the process working directory.

const std = @import("std");

const message = @import("../anthropic/message.zig");

pub const Result = struct {
    /// Owned by the caller's allocator.
    content: []const u8,
    is_error: bool,
};

pub const definitions = [_]message.Tool{
    .{
        .name = "read",
        .description = "Read a UTF-8 text file and return its full contents.",
        .schema_json =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file"}},"required":["path"]}
        ,
    },
    .{
        .name = "write",
        .description = "Create or overwrite a UTF-8 text file with the given contents.",
        .schema_json =
        \\{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}
        ,
    },
};

/// Execute tool `name` with `input_json`. Caller frees `Result.content`.
pub fn run(gpa: std.mem.Allocator, io: std.Io, name: []const u8, input_json: []const u8) !Result {
    if (std.mem.eql(u8, name, "read")) return readFile(gpa, io, input_json);
    if (std.mem.eql(u8, name, "write")) return writeFile(gpa, io, input_json);
    return report(gpa, true, "unknown tool: {s}", .{name});
}

fn readFile(gpa: std.mem.Allocator, io: std.Io, input_json: []const u8) !Result {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, input_json, .{});
    defer parsed.deinit();
    const path = field(parsed.value, "path") orelse return report(gpa, true, "missing 'path'", .{});

    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| {
        return report(gpa, true, "cannot read {s}: {s}", .{ path, @errorName(err) });
    };
    return .{ .content = data, .is_error = false };
}

fn writeFile(gpa: std.mem.Allocator, io: std.Io, input_json: []const u8) !Result {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, input_json, .{});
    defer parsed.deinit();
    const path = field(parsed.value, "path") orelse return report(gpa, true, "missing 'path'", .{});
    const contents = field(parsed.value, "content") orelse return report(gpa, true, "missing 'content'", .{});

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = contents }) catch |err| {
        return report(gpa, true, "cannot write {s}: {s}", .{ path, @errorName(err) });
    };
    return report(gpa, false, "wrote {d} bytes to {s}", .{ contents.len, path });
}

fn field(value: std.json.Value, name: []const u8) ?[]const u8 {
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const found = object.get(name) orelse return null;
    return switch (found) {
        .string => |string| string,
        else => null,
    };
}

fn report(gpa: std.mem.Allocator, is_error: bool, comptime format: []const u8, args: anytype) !Result {
    return .{ .content = try std.fmt.allocPrint(gpa, format, args), .is_error = is_error };
}

test "unknown tool is an error" {
    const result = try run(std.testing.allocator, std.testing.io, "nope", "{}");
    defer std.testing.allocator.free(result.content);
    try std.testing.expect(result.is_error);
}

test "read of missing file reports an error" {
    const result = try run(std.testing.allocator, std.testing.io, "read",
        \\{"path":"/definitely/not/here.txt"}
    );
    defer std.testing.allocator.free(result.content);
    try std.testing.expect(result.is_error);
}
