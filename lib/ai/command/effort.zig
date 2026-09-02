//! `/effort`: a picker over the reasoning-effort ladder. A selection switches
//! the level from the next turn. The command takes no argument.
//!
//! The level states the intention of the user and not a capability of a model,
//! so the picker offers every level at every time. It stands without an account
//! and without a model, because both can change while the intention holds.
//!
//! The model resolves the intention when a request goes out. A model that names
//! no such level folds it onto the nearest level it names, and a model that
//! takes no level drops it. The request resolves in silence, and the picker
//! marks the resolution of each level under the active model, so the fold is
//! visible before the choice.

const std = @import("std");

const llm = @import("../llm.zig");
const Model = @import("../Model.zig");
const model_testing = @import("../testing.zig");
const Context = @import("Context.zig");
const testing = @import("testing.zig");

pub const name = "effort";
pub const summary = "set the reasoning-effort level";

/// The whole ladder, in order.
const ladder = std.enums.values(llm.Effort);

/// The mark of a level that the model does not name. The request then carries
/// the nearest level the model names, and the mark states that level.
const fold_mark = " · Folds to ";

/// The mark of a level that the model drops. The request then carries no
/// reasoning control.
const drop_mark = " · Dropped";

pub fn run(context: *Context) !Context.Outcome {
    var options: Context.Outcome.Options = .{ .gpa = context.gpa };
    errdefer options.deinit();
    var current: ?usize = null;
    const maybe_model: ?*const Model = if (context.agent.model) |*model| model else null;
    for (ladder, 0..) |level, index| {
        try printRow(&options, maybe_model, level);
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

/// Write the picker row of `level`. The row carries the mark of the resolution
/// that a request under the model renders, unless that resolution is the level
/// itself. Without a model nothing resolves the level, so the row holds the
/// level alone.
fn printRow(
    options: *Context.Outcome.Options,
    maybe_model: ?*const Model,
    level: llm.Effort,
) !void {
    const tag = @tagName(level);
    const model = maybe_model orelse return options.print("{s}", .{tag});
    return switch (model.reasoning(level)) {
        .named => |found| if (found == level)
            options.print("{s}", .{tag})
        else
            options.print("{s}" ++ fold_mark ++ "{s}", .{ tag, @tagName(found) }),
        .omitted => options.print("{s}" ++ drop_mark, .{tag}),
    };
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
            try std.testing.expectEqualStrings("low", pick.options[0]);
            try std.testing.expectEqualStrings("max", pick.options[ladder.len - 1]);
            try std.testing.expectEqualStrings("high", pick.options[pick.current.?]);
        },
        else => return error.ExpectedPick,
    }
}

// The mark states what the request carries for each level, so the user sees the
// fold before the choice. A tie folds to the lower level.
test "the picker marks a level that the model folds" {
    const gpa = std.testing.allocator;
    var agent = testing.agent(gpa, .{ .anthropic_subscription = undefined });
    defer agent.deinit();
    var model = model_testing.model("subset");
    model.efforts = .initEmpty();
    model.addEffort(.low);
    model.addEffort(.max);
    agent.model = model;
    var context = contextForTest(&agent);

    const rows = try expectRows(try run(&context));
    defer freeRows(rows);
    const expected = [_][]const u8{
        "low",
        "medium · Folds to low",
        "high · Folds to low",
        "xhigh · Folds to max",
        "max",
    };
    try std.testing.expectEqual(expected.len, rows.len);
    for (expected, rows) |want, row| try std.testing.expectEqualStrings(want, row);
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
    agent.model = model;
    var context = contextForTest(&agent);

    const rows = try expectRows(try run(&context));
    defer freeRows(rows);
    try std.testing.expectEqual(ladder.len, rows.len);

    // The rows are the ladder, so index 3 is xhigh, which folds up to max.
    try Context.Outcome.expectEvent(try select(&context, 3), .information);
    try std.testing.expectEqual(llm.Effort.xhigh, agent.effort);
    try std.testing.expectEqual(llm.Effort.max, agent.model.?.reasoning(agent.effort).named);
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
    // The model takes no level, so every row states that the request drops it.
    for (ladder, rows) |level, row| {
        try std.testing.expect(std.mem.startsWith(u8, row, @tagName(level)));
        try std.testing.expect(std.mem.endsWith(u8, row, " · Dropped"));
    }

    try Context.Outcome.expectEvent(try select(&context, 4), .information);
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

    try Context.Outcome.expectEvent(try select(&context, 4), .information);
    try std.testing.expectEqual(llm.Effort.max, agent.effort);
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
    // No model resolves the level, so no row carries a mark.
    for (ladder, rows) |level, row| try std.testing.expectEqualStrings(@tagName(level), row);

    try Context.Outcome.expectEvent(try select(&context, 1), .information);
    try std.testing.expectEqual(llm.Effort.medium, agent.effort);
}

test "select applies the level at a row index, rejecting out of range" {
    const gpa = std.testing.allocator;
    var agent = testing.agent(gpa, .{ .anthropic_subscription = undefined });
    defer agent.deinit();
    var context = contextForTest(&agent);

    // The rows are the ladder, so row 3 is xhigh.
    try Context.Outcome.expectEvent(try select(&context, 3), .information);
    try std.testing.expectEqual(llm.Effort.xhigh, agent.effort);

    try Context.Outcome.expectNotice(try select(&context, 3), .information);
    try Context.Outcome.expectNotice(try select(&context, ladder.len), .failure);
    try std.testing.expectEqual(llm.Effort.xhigh, agent.effort);
}
