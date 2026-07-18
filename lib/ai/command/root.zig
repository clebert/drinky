//! Slash commands: input lines the user starts with `/`, which the app handles
//! itself instead of sending to the model. Each command is a module exposing a
//! `name` and a `run` handler; the registry pairs them, mirroring the tool
//! registry, so a command is added by writing its module and registering it
//! below.

const std = @import("std");

pub const Context = @import("Context.zig");
pub const Outcome = @import("outcome.zig").Outcome;

const llm = @import("../llm.zig");
const testing = @import("testing.zig");

const effort = @import("effort.zig");
const login = @import("login.zig");
const logout = @import("logout.zig");
const model = @import("model.zig");

const Entry = struct {
    name: []const u8,
    run: *const fn (*Context) anyerror!Outcome,
    /// Applies a picker choice by its row index.
    select: *const fn (*Context, usize) anyerror!Outcome,
};

const registry = [_]Entry{
    .{ .name = model.name, .run = model.run, .select = model.select },
    .{ .name = effort.name, .run = effort.run, .select = effort.select },
    .{ .name = login.name, .run = login.run, .select = login.select },
    .{ .name = logout.name, .run = logout.run, .select = logout.select },
};

/// Dispatch `line` (a full input line beginning with `/`) to its command,
/// reporting an unknown command as an error (mirroring an unknown tool).
pub fn run(context: *Context, line: []const u8) !Outcome {
    const body = line[1..];
    // Editor input can carry interior newlines (Shift+Enter, paste).
    const name = body[0 .. std.mem.indexOfAny(u8, body, " \t\r\n") orelse body.len];
    const entry = find(name) orelse
        return Outcome.report(context.gpa, .err, "unknown command: /{s}", .{name});
    return entry.run(context);
}

/// Apply the choice at row `index` from the picker the command `name` opened. The
/// command re-derives its option list and acts on the chosen row, so a picker
/// selection never routes through a typed argument.
pub fn select(context: *Context, name: []const u8, index: usize) !Outcome {
    const entry = find(name) orelse
        return Outcome.report(context.gpa, .err, "unknown command: /{s}", .{name});
    return entry.select(context, index);
}

/// The registered command named `name`, or null when none matches.
fn find(name: []const u8) ?*const Entry {
    for (&registry) |*entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry;
    }
    return null;
}

test "unknown command is reported" {
    var context: Context = .{ .gpa = std.testing.allocator, .agent = undefined, .accounts = undefined };
    try Outcome.expectFeedback(try run(&context, "/nope"), .err);
}

test "run routes a known command, ignoring the argument tail" {
    const gpa = std.testing.allocator;
    var agent = testing.agent(gpa, .{ .anthropic_subscription = undefined });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .agent = &agent, .accounts = undefined };

    switch (try run(&context, "/effort xhigh trailing")) {
        .pick => |pick| {
            defer {
                for (pick.options) |option| gpa.free(option);
                gpa.free(pick.options);
            }
            try std.testing.expectEqualStrings("effort", pick.command);
        },
        else => return error.ExpectedPick,
    }
}

test "select reaches the named command's entry, reporting an unknown name" {
    const gpa = std.testing.allocator;
    var agent = testing.agent(gpa, .{ .anthropic_subscription = undefined });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .agent = &agent, .accounts = undefined };

    try Outcome.expectFeedback(try select(&context, "effort", 4), .ok);
    try std.testing.expectEqual(llm.Effort.xhigh, agent.effort);
    try Outcome.expectFeedback(try select(&context, "nope", 0), .err);
}

test "a newline delimits the command name like a space" {
    const gpa = std.testing.allocator;
    var context: Context = .{ .gpa = gpa, .agent = undefined, .accounts = undefined };
    const outcome = try run(&context, "/nope\nfoo");
    switch (outcome) {
        .feedback => |feedback| {
            defer gpa.free(feedback.content);
            try std.testing.expectEqualStrings("unknown command: /nope", feedback.content);
        },
        else => return error.ExpectedFeedback,
    }
}
