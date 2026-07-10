//! Slash commands: input lines the user starts with `/`, which the app handles
//! itself instead of sending to the model. Each command is a module exposing a
//! `name` and a `run` handler; the registry pairs them, mirroring the tool
//! registry, so a command is added by writing its module and registering it
//! below.

const std = @import("std");

pub const Context = @import("Context.zig");
pub const Outcome = @import("outcome.zig").Outcome;

const model = @import("model.zig");

const Entry = struct {
    name: []const u8,
    run: *const fn (*Context, []const u8) anyerror!Outcome,
};

const registry = [_]Entry{
    .{ .name = model.name, .run = model.run },
};

/// Dispatch `line` (a full input line beginning with `/`) to its command.
pub fn run(context: *Context, line: []const u8) !Outcome {
    const body = line[1..];
    const split = std.mem.indexOfAny(u8, body, " \t") orelse body.len;
    return apply(context, body[0..split], body[split..]);
}

/// Run the command `name` with `args`, reporting an unknown command as an error
/// (mirroring an unknown tool). Backs both `run`, which parses a typed line, and
/// the picker's re-apply of a chosen option.
pub fn apply(context: *Context, name: []const u8, args: []const u8) !Outcome {
    for (registry) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.run(context, args);
    }
    return Outcome.report(context.gpa, .err, "unknown command: /{s}", .{name});
}

test "unknown command is reported" {
    const gpa = std.testing.allocator;
    var context: Context = .{ .gpa = gpa, .agent = undefined };
    const outcome = try run(&context, "/nope");
    switch (outcome) {
        .feedback => |feedback| {
            defer gpa.free(feedback.content);
            try std.testing.expect(feedback.is_error);
        },
        .pick => return error.ExpectedFeedback,
    }
}
