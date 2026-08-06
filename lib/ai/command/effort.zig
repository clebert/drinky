//! `/effort`: a picker over the reasoning-effort levels. The picker preselects
//! the current one. A selection switches the level from the next turn. The
//! command ignores any argument.
//!
//! The level belongs to the active account, and the status line hides it while
//! no account is active. A signed-out `/effort` therefore refuses, the same way
//! `/model` does, rather than change a level the user cannot see.

const std = @import("std");

const llm = @import("../llm.zig");
const Context = @import("Context.zig");
const testing = @import("testing.zig");

pub const name = "effort";

const levels = std.enums.values(llm.Effort);

pub fn run(context: *Context) !Context.Outcome {
    if (context.agent.client == null)
        return Context.Outcome.reportNotice(
            context.gpa,
            .failure,
            "Sign in to an account before you select an effort level.",
            .{},
        );
    var options: Context.Outcome.Options = .{ .gpa = context.gpa };
    errdefer options.deinit();
    var current: ?usize = null;
    for (levels, 0..) |level, index| {
        try options.print("{s}", .{@tagName(level)});
        if (level == context.agent.effort) current = index;
    }
    return .{ .pick = .{
        .select = select,
        .title = "Select an effort level",
        .cancellation_message = "You canceled the effort selection.",
        .options = try options.toOwnedSlice(),
        .current = current,
    } };
}

pub fn select(context: *Context, index: usize) !Context.Outcome {
    const gpa = context.gpa;
    if (index >= levels.len)
        return Context.Outcome.reportNotice(gpa, .failure, "Select a valid effort level.", .{});
    const level = levels[index];
    if (context.agent.effort == level)
        return Context.Outcome.reportNotice(
            gpa,
            .information,
            "The effort level is already {s}.",
            .{@tagName(level)},
        );
    context.agent.setEffort(level);
    return Context.Outcome.reportEvent(
        gpa,
        .information,
        "Pith set the effort level to {s}.",
        .{@tagName(level)},
    );
}

test "the picker lists every level, preselecting the current one" {
    const gpa = std.testing.allocator;
    var agent = testing.agent(gpa, .{ .anthropic_subscription = undefined });
    defer agent.deinit();
    agent.setEffort(.high);
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = undefined };

    switch (try run(&context)) {
        .pick => |pick| {
            defer {
                for (pick.options) |option| gpa.free(option);
                gpa.free(pick.options);
            }
            try std.testing.expect(pick.select == &select);
            try std.testing.expectEqual(levels.len, pick.options.len);
            try std.testing.expectEqualStrings("high", pick.options[pick.current.?]);
        },
        else => return error.ExpectedPick,
    }
}

test "the picker refuses while no account is active" {
    const gpa = std.testing.allocator;
    var agent = testing.agent(gpa, .{ .anthropic_subscription = undefined });
    defer agent.deinit();
    agent.setEffort(.high);
    agent.signOut();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = undefined };

    // The status line hides the level while signed out, so a change here would
    // be invisible and would never reach the machine-local state.
    try Context.Outcome.expectNotice(try run(&context), .failure);
    try std.testing.expectEqual(llm.Effort.high, agent.effort);
}

test "select applies the level at a row index, rejecting out of range" {
    const gpa = std.testing.allocator;
    var agent = testing.agent(gpa, .{ .anthropic_subscription = undefined });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = undefined };

    // The levels in declaration order: none, low, medium, high, xhigh, max. Index 4 is xhigh.
    try Context.Outcome.expectEvent(try select(&context, 4), .information);
    try std.testing.expectEqual(llm.Effort.xhigh, agent.effort);

    try Context.Outcome.expectNotice(try select(&context, 4), .information);
    try Context.Outcome.expectNotice(try select(&context, 99), .failure);
    try std.testing.expectEqual(llm.Effort.xhigh, agent.effort);
}
