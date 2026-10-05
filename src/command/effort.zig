const std = @import("std");

const accounts = @import("accounts");
const core = @import("core");

const Context = @import("Context.zig");
const testing = @import("testing.zig");

pub const name = "effort";
pub const summary = "Set the reasoning effort";

const ladder = std.enums.values(core.Provider.Effort);

const extra_fold = "The model folds this level to {s}.";

const extra_drop = "The model drops this level.";

pub fn run(context: *Context) Context.Error!Context.Outcome {
    var options: Context.Outcome.Options = .{ .gpa = context.gpa };
    errdefer options.deinit();
    var current: ?usize = null;
    const maybe_model: ?*const accounts.Model = if (context.choice.model) |*model| model else null;
    for (ladder, 0..) |level, index| {
        try printRow(&options, maybe_model, level);
        if (level == context.choice.effort) current = index;
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
    maybe_model: ?*const accounts.Model,
    level: core.Provider.Effort,
) !void {
    const tag = @tagName(level);
    const model = maybe_model orelse return options.print("{s}", .{tag});
    const found = model.fold(level) orelse return options.addExtra(true, tag, extra_drop, .{});
    if (found == level) return options.print("{s}", .{tag});
    return options.addExtra(false, tag, extra_fold, .{@tagName(found)});
}

fn select(
    context: *Context,
    selection: Context.Outcome.Pick.Selection,
) Context.Error!Context.Outcome {
    const gpa = context.gpa;
    const level = ladder[selection.row];
    if (context.choice.effort == level)
        return Context.Outcome.reportNotice(
            gpa,
            .information,
            "The effort level is already {s}.",
            .{@tagName(level)},
        );
    context.choice.effort = level;
    return Context.Outcome.reportEvent(
        gpa,
        .information,
        "Drinky set the effort level to {s}.",
        .{@tagName(level)},
    );
}

test "the picker lists every level without a model, marks the current one, and a pick applies" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    var context = rig.context();

    const pick = try testing.expectPick(try run(&context));
    defer pick.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Effort", pick.title);
    try std.testing.expectEqual(ladder.len, pick.options.len);
    for (ladder, pick.options) |level, row| {
        try std.testing.expectEqualStrings(@tagName(level), row.name);
        try std.testing.expect(row.extra == null);
    }
    try std.testing.expectEqualStrings("high", pick.options[pick.current.?].name);

    try testing.expectEvent(
        try testing.selectRow(&pick, &context, 3),
        .information,
        "Drinky set the effort level to xhigh.",
    );
    try std.testing.expectEqual(core.Provider.Effort.xhigh, rig.choice.effort);
    try testing.expectNotice(
        try testing.selectRow(&pick, &context, 3),
        .information,
        "The effort level is already xhigh.",
    );
    try std.testing.expectEqual(core.Provider.Effort.xhigh, rig.choice.effort);
}

fn subsetModel() accounts.Model {
    var model = accounts.Model.init("subset") catch unreachable;
    model.addEffort(.low);
    model.addEffort(.max);
    return model;
}

test "the picker marks a level that the model folds" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    rig.choice.model = subsetModel();
    var context = rig.context();

    const pick = try testing.expectPick(try run(&context));
    defer pick.deinit(std.testing.allocator);
    const rows = pick.options;
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

    try testing.expectEvent(
        try testing.selectRow(&pick, &context, 3),
        .information,
        "Drinky set the effort level to xhigh.",
    );
    try std.testing.expectEqual(core.Provider.Effort.xhigh, rig.choice.effort);
    try std.testing.expectEqual(core.Provider.Effort.max, rig.choice.fold().?);
}

test "a model that names no level keeps every row and marks the drop" {
    const bare = accounts.Model.init("bare") catch unreachable;
    var rig: testing.Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    rig.choice.model = bare;
    var context = rig.context();

    const pick = try testing.expectPick(try run(&context));
    defer pick.deinit(std.testing.allocator);
    try std.testing.expectEqual(ladder.len, pick.options.len);
    for (ladder, pick.options) |level, row| {
        try std.testing.expectEqualStrings(@tagName(level), row.name);
        try std.testing.expectEqualStrings(extra_drop, row.extra.?);
        try std.testing.expect(row.extra_pressure);
    }

    try testing.expectEvent(
        try testing.selectRow(&pick, &context, 4),
        .information,
        "Drinky set the effort level to max.",
    );
    try std.testing.expectEqual(core.Provider.Effort.max, rig.choice.effort);
    try std.testing.expect(rig.choice.fold() == null);
}
