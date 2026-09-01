//! `/effort`: a picker over the reasoning-effort ladder. A selection switches
//! the level from the next turn. The command takes no argument.
//!
//! The level states the intention of the user and not a capability of a model,
//! so the picker offers every level at every time. It stands without an account
//! and without a model, because both can change while the intention holds.
//!
//! The model resolves the intention when a request goes out. A model that names
//! no such level folds it onto the nearest level it names, and a model that
//! takes no level drops it. Every resolution is silent.

const std = @import("std");

const llm = @import("../llm.zig");
const model_testing = @import("../testing.zig");
const Context = @import("Context.zig");
const testing = @import("testing.zig");

pub const name = "effort";
pub const summary = "set the reasoning-effort level";

/// The whole ladder, in order.
const ladder = std.enums.values(llm.Effort);

pub fn run(context: *Context) !Context.Outcome {
    var options: Context.Outcome.Options = .{ .gpa = context.gpa };
    errdefer options.deinit();
    var current: ?usize = null;
    for (ladder, 0..) |level, index| {
        try options.print("{s}", .{@tagName(level)});
        if (level == context.agent.effort) current = index;
    }
    return .{ .pick = .{
        .select = select,
        .title = "Effort",
        .cancellation_message = "You canceled the effort selection.",
        .options = try options.toOwnedSlice(),
        .current = current,
    } };
}

pub fn select(context: *Context, index: usize) !Context.Outcome {
    const gpa = context.gpa;
    if (index >= ladder.len)
        return Context.Outcome.reportNotice(gpa, .failure, "Select a valid effort level.", .{});
    const level = ladder[index];
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
        "Drinky set the effort level to {s}.",
        .{@tagName(level)},
    );
}

fn contextForTest(agent: anytype) Context {
    return .{ .gpa = std.testing.allocator, .io = undefined, .agent = agent, .accounts = undefined };
}

/// Test helper: the rows of `outcome`, which the caller must free.
fn expectRows(outcome: Context.Outcome) ![]const []const u8 {
    return switch (outcome) {
        .pick => |pick| pick.options,
        else => error.ExpectedPick,
    };
}

fn freeRows(rows: []const []const u8) void {
    const gpa = std.testing.allocator;
    for (rows) |row| gpa.free(row);
    gpa.free(rows);
}

test "the picker lists every level, preselecting the current one" {
    const gpa = std.testing.allocator;
    var agent = testing.agent(gpa, .{ .anthropic_subscription = undefined });
    defer agent.deinit();
    agent.setEffort(.high);
    var context = contextForTest(&agent);

    switch (try run(&context)) {
        .pick => |pick| {
            defer freeRows(pick.options);
            try std.testing.expect(pick.select == &select);
            try std.testing.expectEqualStrings("Effort", pick.title);
            try std.testing.expectEqual(ladder.len, pick.options.len);
            try std.testing.expectEqualStrings("none", pick.options[0]);
            try std.testing.expectEqualStrings("minimal", pick.options[1]);
            try std.testing.expectEqualStrings("ultra", pick.options[ladder.len - 1]);
            try std.testing.expectEqualStrings("high", pick.options[pick.current.?]);
        },
        else => return error.ExpectedPick,
    }
}

// The level is a wish of the user, so a model that names fewer levels narrows
// no row. The wish stands, and the request carries the nearest named level.
test "a model that names fewer levels still offers every level" {
    const gpa = std.testing.allocator;
    var agent = testing.agent(gpa, .{ .anthropic_subscription = undefined });
    defer agent.deinit();
    var model = model_testing.model("subset");
    model.efforts = .initEmpty();
    model.addEffort(.low);
    model.addEffort(.max);
    model.thinking = .mandatory;
    agent.model = model;
    var context = contextForTest(&agent);

    const rows = try expectRows(try run(&context));
    defer freeRows(rows);
    try std.testing.expectEqual(ladder.len, rows.len);

    // The rows are the ladder, so index 7 is ultra, which folds down to max.
    try Context.Outcome.expectEvent(try select(&context, 7), .information);
    try std.testing.expectEqual(llm.Effort.ultra, agent.effort);
    try std.testing.expectEqual(llm.Effort.max, agent.model.?.reasoning(agent.effort).named);

    // The reasoning of this model cannot stop, so `none` drops silently.
    try Context.Outcome.expectEvent(try select(&context, 0), .information);
    try std.testing.expectEqual(llm.Effort.none, agent.effort);
    try std.testing.expect(agent.model.?.reasoning(agent.effort) == .omitted);
}

test "a model that names no level keeps every row" {
    const gpa = std.testing.allocator;
    var agent = testing.agent(gpa, .{ .anthropic_subscription = undefined });
    defer agent.deinit();
    agent.model = model_testing.bareModel("bare");
    var context = contextForTest(&agent);

    const rows = try expectRows(try run(&context));
    defer freeRows(rows);
    try std.testing.expectEqual(ladder.len, rows.len);

    try Context.Outcome.expectEvent(try select(&context, 6), .information);
    try std.testing.expectEqual(llm.Effort.max, agent.effort);
    // The model takes no level, so the request carries no reasoning control.
    try std.testing.expect(agent.model.?.reasoning(agent.effort) == .omitted);
}

// The intention outlives the account, and the next sign-in adopts it, so the
// picker stands while no account is active.
test "the picker stands while no account is active" {
    const gpa = std.testing.allocator;
    var agent = testing.agent(gpa, .{ .anthropic_subscription = undefined });
    defer agent.deinit();
    agent.setEffort(.high);
    agent.signOut();
    var context = contextForTest(&agent);

    const rows = try expectRows(try run(&context));
    defer freeRows(rows);
    try std.testing.expectEqual(ladder.len, rows.len);

    try Context.Outcome.expectEvent(try select(&context, 7), .information);
    try std.testing.expectEqual(llm.Effort.ultra, agent.effort);
}

// A session reaches a model list only after a fetch, and the intention holds
// before that, so the picker stands without a model too.
test "the picker stands while the account offers no model" {
    const gpa = std.testing.allocator;
    var agent = testing.agent(gpa, .{ .anthropic_subscription = undefined });
    defer agent.deinit();
    agent.model = null;
    var context = contextForTest(&agent);

    const rows = try expectRows(try run(&context));
    defer freeRows(rows);
    try std.testing.expectEqual(ladder.len, rows.len);

    try Context.Outcome.expectEvent(try select(&context, 2), .information);
    try std.testing.expectEqual(llm.Effort.low, agent.effort);
}

test "select applies the level at a row index, rejecting out of range" {
    const gpa = std.testing.allocator;
    var agent = testing.agent(gpa, .{ .anthropic_subscription = undefined });
    defer agent.deinit();
    var context = contextForTest(&agent);

    // The rows are the ladder, so row 5 is xhigh.
    try Context.Outcome.expectEvent(try select(&context, 5), .information);
    try std.testing.expectEqual(llm.Effort.xhigh, agent.effort);

    try Context.Outcome.expectNotice(try select(&context, 5), .information);
    try Context.Outcome.expectNotice(try select(&context, ladder.len), .failure);
    try std.testing.expectEqual(llm.Effort.xhigh, agent.effort);
}
