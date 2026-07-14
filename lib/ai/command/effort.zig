//! `/effort`: with no argument, open a picker over the reasoning-effort levels,
//! preselecting the current one; with a name, switch to it from the next turn
//! onward. An unknown name is reported, not applied. The picker feeds its choice
//! back through the name path, mirroring `/model`.

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
    const gpa = context.gpa;
    const requested = std.mem.trim(u8, args, " \t");

    if (requested.len != 0) {
        const chosen = std.meta.stringToEnum(llm.Effort, requested) orelse
            return Outcome.report(gpa, .err, "unknown effort: {s}", .{requested});
        context.agent.setEffort(chosen);
        return Outcome.report(gpa, .ok, "effort set to {s}", .{@tagName(chosen)});
    }

    const options = try gpa.alloc([]const u8, levels.len);
    var filled: usize = 0;
    errdefer {
        for (options[0..filled]) |option| gpa.free(option);
        gpa.free(options);
    }
    var current_index: ?usize = null;
    for (levels, 0..) |level, index| {
        options[index] = try gpa.dupe(u8, @tagName(level));
        filled += 1;
        if (level == context.agent.effort) current_index = index;
    }
    return .{ .pick = .{
        .command = name,
        .title = "Select reasoning effort",
        .options = options,
        .current = current_index,
    } };
}

fn testAgent(gpa: std.mem.Allocator) Agent {
    const client = provider.Client.init(.anthropic, gpa, std.testing.io, undefined, .{});
    return Agent.init(gpa, std.testing.io, client, .{
        .model = models.get(.anthropic, "claude-sonnet-4-6").?,
        .system = "",
        .retry = .{},
    });
}

test "switch to a known level, reject an unknown one" {
    const gpa = std.testing.allocator;
    var agent = testAgent(gpa);
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .agent = &agent };

    switch (try run(&context, "xhigh")) {
        .feedback => |feedback| {
            defer gpa.free(feedback.content);
            try std.testing.expect(!feedback.is_error);
        },
        .pick => return error.ExpectedFeedback,
    }
    try std.testing.expectEqual(llm.Effort.xhigh, agent.effort);

    switch (try run(&context, "turbo")) {
        .feedback => |feedback| {
            defer gpa.free(feedback.content);
            try std.testing.expect(feedback.is_error);
        },
        .pick => return error.ExpectedFeedback,
    }
    try std.testing.expectEqual(llm.Effort.xhigh, agent.effort);
}

test "no argument opens a picker preselecting the current level" {
    const gpa = std.testing.allocator;
    var agent = testAgent(gpa);
    defer agent.deinit();
    agent.setEffort(.high);
    var context: Context = .{ .gpa = gpa, .agent = &agent };

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
        .feedback => return error.ExpectedPick,
    }
}
