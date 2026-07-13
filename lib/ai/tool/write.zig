//! Creates or overwrites a UTF-8 text file with the given contents.

const std = @import("std");

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
        .{ .name = "content", .type = .string, .required = true, .description = "Full file contents; replaces the file entirely" },
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

    fs.writeFile(context.io, std.Io.Dir.cwd(), .{ .sub_path = path, .data = contents }) catch |err| switch (err) {
        error.Canceled => return err,
        else => return Result.report(gpa, .err, "cannot write {s}: {s}", .{ path, @errorName(err) }),
    };
    return Result.report(gpa, .ok, "wrote {d} bytes to {s}", .{ contents.len, path });
}
