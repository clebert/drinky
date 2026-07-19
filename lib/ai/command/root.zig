//! Slash-command registry, mirroring the tool registry: each command module
//! exposes `name`/`run` and is registered below.

const std = @import("std");

pub const Context = @import("Context.zig");
pub const Outcome = Context.Outcome;

const testing = @import("testing.zig");

const effort = @import("effort.zig");
const login = @import("login.zig");
const logout = @import("logout.zig");
const model = @import("model.zig");

const Entry = struct {
    name: []const u8,
    run: *const fn (*Context) anyerror!Outcome,
};

const registry = [_]Entry{
    .{ .name = model.name, .run = model.run },
    .{ .name = effort.name, .run = effort.run },
    .{ .name = login.name, .run = login.run },
    .{ .name = logout.name, .run = logout.run },
};

/// Dispatch a `/`-prefixed input line to its command; an unknown command is an error.
pub fn run(context: *Context, line: []const u8) !Outcome {
    const body = line[1..];
    // Editor input can carry interior newlines (Shift+Enter, paste).
    const name = body[0 .. std.mem.indexOfAny(u8, body, " \t\r\n") orelse body.len];
    for (&registry) |*entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.run(context);
    }
    return Outcome.report(context.gpa, .err, "unknown command: /{s}", .{name});
}

test "unknown command is reported" {
    var context: Context = .{
        .gpa = std.testing.allocator,
        .agent = undefined,
        .accounts = undefined,
    };
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
            try std.testing.expect(pick.select == &effort.select);
        },
        else => return error.ExpectedPick,
    }
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
