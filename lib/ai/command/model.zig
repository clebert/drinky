//! `/model`: with no argument, open a picker over the models the active provider
//! offers, preselecting the current one; with a name, switch to it from the next
//! turn onward. An unknown name is reported, not applied — the model stays as it
//! was. The picker feeds its choice back through the name path.

const std = @import("std");

const Agent = @import("../Agent.zig");
const models = @import("../models.zig");
const provider = @import("../provider.zig");
const Context = @import("Context.zig");
const Outcome = @import("outcome.zig").Outcome;

pub const name = "model";

pub fn run(context: *Context, args: []const u8) !Outcome {
    const gpa = context.gpa;
    const vendor = context.agent.client.provider();
    const requested = std.mem.trim(u8, args, " \t");

    if (requested.len != 0) {
        const chosen = models.get(vendor, requested) orelse
            return Outcome.report(gpa, .err, "unknown model: {s}", .{requested});
        context.agent.setModel(chosen);
        return Outcome.report(gpa, .ok, "switched to {s}", .{chosen.name});
    }

    var available: std.ArrayList(models.Model) = .empty;
    defer available.deinit(gpa);
    try models.list(vendor, &available, gpa);
    if (available.items.len == 0) return Outcome.report(gpa, .err, "no models available", .{});

    const current = context.agent.model.name;
    const options = try gpa.alloc([]const u8, available.items.len);
    var filled: usize = 0;
    errdefer {
        for (options[0..filled]) |option| gpa.free(option);
        gpa.free(options);
    }
    var current_index: ?usize = null;
    for (available.items, 0..) |entry, index| {
        options[index] = try gpa.dupe(u8, entry.name);
        filled += 1;
        if (std.mem.eql(u8, entry.name, current)) current_index = index;
    }
    return .{ .pick = .{
        .command = name,
        .title = "Select a model",
        .options = options,
        .current = current_index,
    } };
}

fn testAgent(gpa: std.mem.Allocator) Agent {
    const client = provider.Client.init(gpa, std.testing.io, .{ .anthropic_subscription = undefined }, .{});
    return Agent.init(gpa, std.testing.io, client, .{
        .model = models.get(.anthropic, "claude-sonnet-4-6").?,
        .system = "",
        .retry = .{},
    });
}

test "switch to a known model, reject an unknown one" {
    const gpa = std.testing.allocator;
    var agent = testAgent(gpa);
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .agent = &agent };

    switch (try run(&context, "claude-opus-4-8")) {
        .feedback => |feedback| {
            defer gpa.free(feedback.content);
            try std.testing.expect(!feedback.is_error);
        },
        .pick => return error.ExpectedFeedback,
    }
    try std.testing.expectEqualStrings("claude-opus-4-8", agent.model.name);

    switch (try run(&context, "does-not-exist")) {
        .feedback => |feedback| {
            defer gpa.free(feedback.content);
            try std.testing.expect(feedback.is_error);
        },
        .pick => return error.ExpectedFeedback,
    }
    try std.testing.expectEqualStrings("claude-opus-4-8", agent.model.name);
}

test "no argument opens a picker preselecting the current model" {
    const gpa = std.testing.allocator;
    var agent = testAgent(gpa);
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .agent = &agent };

    switch (try run(&context, "")) {
        .pick => |pick| {
            defer {
                for (pick.options) |option| gpa.free(option);
                gpa.free(pick.options);
            }
            try std.testing.expectEqualStrings("model", pick.command);
            try std.testing.expect(pick.options.len >= 2);
            try std.testing.expect(pick.current != null);
            try std.testing.expectEqualStrings("claude-sonnet-4-6", pick.options[pick.current.?]);
        },
        .feedback => return error.ExpectedPick,
    }
}
