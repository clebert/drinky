const std = @import("std");

const llm = @import("../llm.zig");
const Model = @import("../Model.zig");
const model_testing = @import("../testing.zig");
const Context = @import("Context.zig");
const testing = @import("testing.zig");

pub const name = "effort";
pub const summary = "Set the reasoning effort";

const ladder = std.enums.values(llm.Effort);

const extra_fold = "The model folds this level to {s}.";

const extra_drop = "The model drops this level.";

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
            options.addExtra(false, tag, extra_fold, .{@tagName(found)}),
        .omitted => options.addExtra(true, tag, extra_drop, .{}),
    };
}

pub fn select(context: *Context, selection: Context.Outcome.Pick.Selection) !Context.Outcome {
    const gpa = context.gpa;
    const index = selection.row;
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

fn expectRows(outcome: Context.Outcome) ![]const Context.Outcome.Pick.Option {
    return switch (outcome) {
        .pick => |pick| pick.options,
        else => error.ExpectedPick,
    };
}

fn freeRows(rows: []const Context.Outcome.Pick.Option) void {
    const gpa = std.testing.allocator;
    for (rows) |*row| row.deinit(gpa);
    gpa.free(rows);
}

test "the picker lists every level, preselecting the current one" {
    const gpa = std.testing.allocator;
    var agent = testing.agent(gpa, .{ .anthropic_plan = undefined });
    defer agent.deinit();
    agent.setEffort(.high);
    var context = contextForTest(&agent);

    switch (try run(&context)) {
        .pick => |pick| {
            defer freeRows(pick.options);
            try std.testing.expect(pick.select == &select);
            try std.testing.expectEqualStrings("Effort", pick.title);
            try std.testing.expectEqual(ladder.len, pick.options.len);
            try std.testing.expectEqualStrings("low", pick.options[0].name);
            try std.testing.expectEqualStrings("max", pick.options[ladder.len - 1].name);
            try std.testing.expectEqualStrings("high", pick.options[pick.current.?].name);
        },
        else => return error.ExpectedPick,
    }
}

test "the picker marks a level that the model folds" {
    const gpa = std.testing.allocator;
    var agent = testing.agent(gpa, .{ .anthropic_plan = undefined });
    defer agent.deinit();
    var model = model_testing.model("subset");
    model.efforts = .initEmpty();
    model.addEffort(.low);
    model.addEffort(.max);
    agent.model = model;
    var context = contextForTest(&agent);

    const rows = try expectRows(try run(&context));
    defer freeRows(rows);
    try std.testing.expectEqual(@as(usize, 5), rows.len);
    try std.testing.expectEqualStrings("low", rows[0].name);
    try std.testing.expect(rows[0].extra == null);
    try std.testing.expectEqualStrings("medium", rows[1].name);
    try std.testing.expectEqualStrings("The model folds this level to low.", rows[1].extra.?);
    try std.testing.expect(!rows[1].extra_pressure);
    try std.testing.expectEqualStrings("high", rows[2].name);
    try std.testing.expectEqualStrings("The model folds this level to low.", rows[2].extra.?);
    try std.testing.expectEqualStrings("xhigh", rows[3].name);
    try std.testing.expectEqualStrings("The model folds this level to max.", rows[3].extra.?);
    try std.testing.expectEqualStrings("max", rows[4].name);
    try std.testing.expect(rows[4].extra == null);
}

test "a model that names fewer levels still offers every level" {
    const gpa = std.testing.allocator;
    var agent = testing.agent(gpa, .{ .anthropic_plan = undefined });
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

    try Context.Outcome.expectEvent(try select(&context, .ofRow(3)), .information);
    try std.testing.expectEqual(llm.Effort.xhigh, agent.effort);
    try std.testing.expectEqual(llm.Effort.max, agent.model.?.reasoning(agent.effort).named);
}

test "a model that names no level keeps every row" {
    const gpa = std.testing.allocator;
    var agent = testing.agent(gpa, .{ .anthropic_plan = undefined });
    defer agent.deinit();
    agent.model = model_testing.bareModel("bare");
    var context = contextForTest(&agent);

    const rows = try expectRows(try run(&context));
    defer freeRows(rows);
    try std.testing.expectEqual(ladder.len, rows.len);
    for (ladder, rows) |level, row| {
        try std.testing.expectEqualStrings(@tagName(level), row.name);
        try std.testing.expectEqualStrings(extra_drop, row.extra.?);
        try std.testing.expect(row.extra_pressure);
    }

    try Context.Outcome.expectEvent(try select(&context, .ofRow(4)), .information);
    try std.testing.expectEqual(llm.Effort.max, agent.effort);
    try std.testing.expect(agent.model.?.reasoning(agent.effort) == .omitted);
}

test "the picker stands while no account is active" {
    const gpa = std.testing.allocator;
    var agent = testing.agent(gpa, .{ .anthropic_plan = undefined });
    defer agent.deinit();
    agent.setEffort(.high);
    agent.signOut();
    var context = contextForTest(&agent);

    const rows = try expectRows(try run(&context));
    defer freeRows(rows);
    try std.testing.expectEqual(ladder.len, rows.len);

    try Context.Outcome.expectEvent(try select(&context, .ofRow(4)), .information);
    try std.testing.expectEqual(llm.Effort.max, agent.effort);
}

test "the picker stands while the account offers no model" {
    const gpa = std.testing.allocator;
    var agent = testing.agent(gpa, .{ .anthropic_plan = undefined });
    defer agent.deinit();
    agent.model = null;
    var context = contextForTest(&agent);

    const rows = try expectRows(try run(&context));
    defer freeRows(rows);
    try std.testing.expectEqual(ladder.len, rows.len);
    for (ladder, rows) |level, row| {
        try std.testing.expectEqualStrings(@tagName(level), row.name);
        try std.testing.expect(row.extra == null);
    }

    try Context.Outcome.expectEvent(try select(&context, .ofRow(1)), .information);
    try std.testing.expectEqual(llm.Effort.medium, agent.effort);
}

test "select applies the level at a row index, rejecting out of range" {
    const gpa = std.testing.allocator;
    var agent = testing.agent(gpa, .{ .anthropic_plan = undefined });
    defer agent.deinit();
    var context = contextForTest(&agent);

    try Context.Outcome.expectEvent(try select(&context, .ofRow(3)), .information);
    try std.testing.expectEqual(llm.Effort.xhigh, agent.effort);

    try Context.Outcome.expectNotice(try select(&context, .ofRow(3)), .information);
    try Context.Outcome.expectNotice(
        try select(&context, .ofRow(ladder.len)),
        .failure,
    );
    try std.testing.expectEqual(llm.Effort.xhigh, agent.effort);
}
