//! `/effort`: open a picker over the reasoning-effort levels, preselecting the
//! current one; selecting one switches it from the next turn onward. There is no
//! typed form — any argument is ignored and the picker opens regardless.

const std = @import("std");

const Agent = @import("../Agent.zig");
const llm = @import("../llm.zig");
const models = @import("../models.zig");
const provider = @import("../provider.zig");
const Context = @import("Context.zig");
const Outcome = @import("outcome.zig").Outcome;

pub const name = "effort";

const levels = std.enums.values(llm.Effort);

pub fn run(context: *Context, args: []const u8) !Outcome {
    _ = args;
    const gpa = context.gpa;

    const options = try gpa.alloc([]const u8, levels.len);
    var filled: usize = 0;
    errdefer {
        for (options[0..filled]) |option| gpa.free(option);
        gpa.free(options);
    }
    var current: ?usize = null;
    for (levels, 0..) |level, index| {
        options[index] = try gpa.dupe(u8, @tagName(level));
        filled += 1;
        if (level == context.agent.effort) current = index;
    }
    return .{ .pick = .{
        .command = name,
        .title = "Select reasoning effort",
        .options = options,
        .current = current,
    } };
}

pub fn select(context: *Context, index: usize) !Outcome {
    const gpa = context.gpa;
    if (index >= levels.len) return Outcome.report(gpa, .err, "invalid selection", .{});
    const level = levels[index];
    context.agent.setEffort(level);
    return Outcome.report(gpa, .ok, "effort set to {s}", .{@tagName(level)});
}

fn testAgent(gpa: std.mem.Allocator) Agent {
    const client = provider.Client.init(gpa, std.testing.io, .{ .anthropic_subscription = undefined }, .{});
    return Agent.init(gpa, std.testing.io, client, .{
        .model = models.get(.anthropic, "claude-sonnet-4-6").?,
        .system = "",
        .retry = .{},
    });
}

test "the picker lists every level, preselecting the current one" {
    const gpa = std.testing.allocator;
    var agent = testAgent(gpa);
    defer agent.deinit();
    agent.setEffort(.high);
    var context: Context = .{ .gpa = gpa, .agent = &agent, .accounts = undefined };

    switch (try run(&context, "")) {
        .pick => |pick| {
            defer {
                for (pick.options) |option| gpa.free(option);
                gpa.free(pick.options);
            }
            try std.testing.expectEqualStrings("effort", pick.command);
            try std.testing.expectEqual(levels.len, pick.options.len);
            try std.testing.expectEqualStrings("high", pick.options[pick.current.?]);
        },
        else => return error.ExpectedPick,
    }
}

test "select applies the level at a row index, rejecting out of range" {
    const gpa = std.testing.allocator;
    var agent = testAgent(gpa);
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .agent = &agent, .accounts = undefined };

    // Levels are declared none, low, medium, high, xhigh, max — index 4 is xhigh.
    switch (try select(&context, 4)) {
        .feedback => |feedback| {
            defer gpa.free(feedback.content);
            try std.testing.expect(!feedback.is_error);
        },
        else => return error.ExpectedFeedback,
    }
    try std.testing.expectEqual(llm.Effort.xhigh, agent.effort);

    switch (try select(&context, 99)) {
        .feedback => |feedback| {
            defer gpa.free(feedback.content);
            try std.testing.expect(feedback.is_error);
        },
        else => return error.ExpectedFeedback,
    }
    try std.testing.expectEqual(llm.Effort.xhigh, agent.effort);
}
