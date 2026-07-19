//! `/effort`: picker over the reasoning-effort levels, preselecting the current
//! one; selecting one switches it from the next turn. Any argument is ignored.

const std = @import("std");

const llm = @import("../llm.zig");
const Context = @import("Context.zig");
const testing = @import("testing.zig");

pub const name = "effort";

const levels = std.enums.values(llm.Effort);

pub fn run(context: *Context) !Context.Outcome {
    var options: Context.Outcome.Options = .{ .gpa = context.gpa };
    errdefer options.deinit();
    var current: ?usize = null;
    for (levels, 0..) |level, index| {
        try options.print("{s}", .{@tagName(level)});
        if (level == context.agent.effort) current = index;
    }
    return .{ .pick = .{
        .select = select,
        .title = "Select reasoning effort",
        .options = try options.toOwnedSlice(),
        .current = current,
    } };
}

pub fn select(context: *Context, index: usize) !Context.Outcome {
    const gpa = context.gpa;
    if (index >= levels.len) return Context.Outcome.report(gpa, .err, "invalid selection", .{});
    const level = levels[index];
    context.agent.setEffort(level);
    return Context.Outcome.report(gpa, .ok, "effort set to {s}", .{@tagName(level)});
}

test "the picker lists every level, preselecting the current one" {
    const gpa = std.testing.allocator;
    var agent = testing.agent(gpa, .{ .anthropic_subscription = undefined });
    defer agent.deinit();
    agent.setEffort(.high);
    var context: Context = .{ .gpa = gpa, .agent = &agent, .accounts = undefined };

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

test "select applies the level at a row index, rejecting out of range" {
    const gpa = std.testing.allocator;
    var agent = testing.agent(gpa, .{ .anthropic_subscription = undefined });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .agent = &agent, .accounts = undefined };

    // Levels are declared none, low, medium, high, xhigh, max — index 4 is xhigh.
    try Context.Outcome.expectFeedback(try select(&context, 4), .ok);
    try std.testing.expectEqual(llm.Effort.xhigh, agent.effort);

    try Context.Outcome.expectFeedback(try select(&context, 99), .err);
    try std.testing.expectEqual(llm.Effort.xhigh, agent.effort);
}
