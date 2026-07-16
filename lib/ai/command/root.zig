//! Slash commands: input lines the user starts with `/`, which the app handles
//! itself instead of sending to the model. Each command is a module exposing a
//! `name` and a `run` handler; the registry pairs them, mirroring the tool
//! registry, so a command is added by writing its module and registering it
//! below.

const std = @import("std");

pub const Context = @import("Context.zig");
pub const Outcome = @import("outcome.zig").Outcome;

const effort = @import("effort.zig");
const model = @import("model.zig");

const Entry = struct {
    name: []const u8,
    run: *const fn (*Context, []const u8) anyerror!Outcome,
    /// Applies a picker choice by its row index; null for a command that opens no
    /// picker.
    select: ?*const fn (*Context, usize) anyerror!Outcome = null,
};

const registry = [_]Entry{
    .{ .name = model.name, .run = model.run, .select = model.select },
    .{ .name = effort.name, .run = effort.run, .select = effort.select },
};

/// Dispatch `line` (a full input line beginning with `/`) to its command,
/// reporting an unknown command as an error (mirroring an unknown tool).
pub fn run(context: *Context, line: []const u8) !Outcome {
    const body = line[1..];
    const split = std.mem.indexOfAny(u8, body, " \t") orelse body.len;
    const name = body[0..split];
    const entry = find(name) orelse
        return Outcome.report(context.gpa, .err, "unknown command: /{s}", .{name});
    return entry.run(context, body[split..]);
}

/// Apply the choice at row `index` from the picker the command `name` opened. The
/// command re-derives its option list and acts on the chosen row, so a picker
/// selection never routes through a typed argument.
pub fn select(context: *Context, name: []const u8, index: usize) !Outcome {
    const entry = find(name) orelse
        return Outcome.report(context.gpa, .err, "unknown command: /{s}", .{name});
    const handler = entry.select orelse
        return Outcome.report(context.gpa, .err, "/{s} has no picker", .{name});
    return handler(context, index);
}

/// The registered command named `name`, or null when none matches.
fn find(name: []const u8) ?*const Entry {
    for (&registry) |*entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry;
    }
    return null;
}

test "unknown command is reported" {
    const gpa = std.testing.allocator;
    var context: Context = .{ .gpa = gpa, .agent = undefined, .accounts = undefined };
    const outcome = try run(&context, "/nope");
    switch (outcome) {
        .feedback => |feedback| {
            defer gpa.free(feedback.content);
            try std.testing.expect(feedback.is_error);
        },
        .pick => return error.ExpectedFeedback,
    }
}
