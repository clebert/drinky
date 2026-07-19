//! The tools the model may call: each module exposes a `spec` and a `run`;
//! the registry pairs them.

const std = @import("std");

const llm = @import("../llm.zig");

pub const Context = @import("Context.zig");
pub const Result = @import("Result.zig");

const read = @import("read.zig");
const write = @import("write.zig");
const edit = @import("edit.zig");
const find = @import("find.zig");
const grep = @import("grep.zig");

const Entry = struct {
    tool: llm.Tool,
    run: *const fn (*const Context, []const u8) anyerror!Result,
    mutates: bool,
};

const registry = [_]Entry{
    .{ .tool = read.spec, .run = read.run, .mutates = false },
    .{ .tool = write.spec, .run = write.run, .mutates = true },
    .{ .tool = edit.spec, .run = edit.run, .mutates = true },
    .{ .tool = find.spec, .run = find.run, .mutates = false },
    .{ .tool = grep.spec, .run = grep.run, .mutates = false },
};

/// The schemas of every tool, for advertising to the provider in a request.
pub const specs = blk: {
    var list: [registry.len]llm.Tool = undefined;
    for (registry, 0..) |entry, index| list[index] = entry.tool;
    break :blk list;
};

/// Whether tool `name` writes to the filesystem, so the agent runs it as a
/// barrier. An unknown tool touches nothing, so it runs concurrently and just
/// reports the unknown-tool error.
pub fn mutates(name: []const u8) bool {
    for (registry) |entry| {
        if (std.mem.eql(u8, name, entry.tool.name)) return entry.mutates;
    }
    return false;
}

/// Execute tool `name` with `input_json`. Caller frees `Result.content`.
pub fn run(context: *const Context, name: []const u8, input_json: []const u8) !Result {
    for (registry) |entry| {
        if (!std.mem.eql(u8, name, entry.tool.name)) continue;
        return entry.run(context, input_json) catch |err| switch (err) {
            error.InvalidArguments => try Result.report(
                context.gpa,
                .err,
                "invalid arguments for {s}",
                .{name},
            ),
            else => return err,
        };
    }
    return Result.report(context.gpa, .err, "unknown tool: {s}", .{name});
}

test "mutating tools are marked, read-only tools are not" {
    try std.testing.expect(mutates("write"));
    try std.testing.expect(mutates("edit"));
    try std.testing.expect(!mutates("read"));
    try std.testing.expect(!mutates("grep"));
    try std.testing.expect(!mutates("nope"));
}

test "unknown tool is an error" {
    const context: Context = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    const result = try run(&context, "nope", "{}");
    defer std.testing.allocator.free(result.content);
    try std.testing.expect(result.is_error);
}

test "invalid arguments are reported, not raised" {
    const context: Context = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    const result = try run(&context, "read", "{}");
    defer std.testing.allocator.free(result.content);
    try std.testing.expect(result.is_error);
}
