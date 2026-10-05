const std = @import("std");

const Context = @import("Context.zig");
const testing = @import("testing.zig");

pub const name = "remote";
pub const summary = "Attach a Telegram bot";

const add_row = "Add a bot";
const remove_row = "Remove a bot";

const opener: Context.Outcome.Opener = .{ .open = reopen };

const removal_opener: Context.Outcome.Opener = .{ .open = reopenRemoval };

pub fn run(context: *Context) Context.Error!Context.Outcome {
    var options: Context.Outcome.Options = .{ .gpa = context.gpa };
    errdefer options.deinit();
    for (context.remote_bots) |username| try options.print("@{s}", .{username});
    try options.print("{s}", .{add_row});
    if (context.remote_bots.len > 0) try options.print("{s}", .{remove_row});
    return .{ .pick = .{
        .select = select,
        .title = "Remote",
        .cancellation_message = "You canceled the bot selection.",
        .options = try options.toOwnedSlice(),
        .current = null,
        .reopen = opener,
    } };
}

fn reopen(context: *Context, payload: usize) Context.Error!Context.Outcome {
    _ = payload;
    return run(context);
}

fn select(
    context: *Context,
    selection: Context.Outcome.Pick.Selection,
) Context.Error!Context.Outcome {
    const index = selection.row;
    const bot_count = context.remote_bots.len;
    if (index < bot_count) return .{ .remote_attach = index };
    if (index == bot_count) return .remote_add;
    std.debug.assert(index == bot_count + 1 and bot_count > 0);
    return openRemoval(context);
}

fn openRemoval(context: *Context) !Context.Outcome {
    var options: Context.Outcome.Options = .{ .gpa = context.gpa };
    errdefer options.deinit();
    for (context.remote_bots) |username| try options.print("@{s}", .{username});
    return .{ .pick = .{
        .select = selectRemoval,
        .title = "Remove a bot",
        .cancellation_message = "You canceled the bot removal.",
        .options = try options.toOwnedSlice(),
        .current = null,
        .reopen = removal_opener,
    } };
}

fn reopenRemoval(context: *Context, payload: usize) Context.Error!Context.Outcome {
    _ = payload;
    return openRemoval(context);
}

fn selectRemoval(
    context: *Context,
    selection: Context.Outcome.Pick.Selection,
) Context.Error!Context.Outcome {
    std.debug.assert(selection.row < context.remote_bots.len);
    return .{ .remote_remove = selection.row };
}

test "a picker with no saved bot holds the add row alone" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    var context = rig.context();

    const pick = try testing.expectPick(try run(&context));
    defer pick.deinit(gpa);
    try std.testing.expectEqualStrings("Remote", pick.title);
    try std.testing.expectEqual(@as(usize, 1), pick.options.len);
    try std.testing.expectEqualStrings(add_row, pick.options[0].name);
    try testing.expectReopen(&context, &pick);
    try std.testing.expect((try testing.selectRow(&pick, &context, 0)) == .remote_add);
}

test "the rows name each bot, then the add row and the remove row" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .remote_bots = &.{ "drinky_bot", "other_bot" } });
    defer rig.deinit();
    var context = rig.context();

    const pick = try testing.expectPick(try run(&context));
    defer pick.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 4), pick.options.len);
    try std.testing.expectEqualStrings("@drinky_bot", pick.options[0].name);
    try std.testing.expectEqualStrings("@other_bot", pick.options[1].name);
    try std.testing.expectEqualStrings(add_row, pick.options[2].name);
    try std.testing.expectEqualStrings(remove_row, pick.options[3].name);
    switch (try testing.selectRow(&pick, &context, 1)) {
        .remote_attach => |index| try std.testing.expectEqual(@as(usize, 1), index),
        else => return error.ExpectedAttach,
    }
    try std.testing.expect((try testing.selectRow(&pick, &context, 2)) == .remote_add);
}

test "the remove row opens the second list, and one pick removes" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .remote_bots = &.{ "drinky_bot", "other_bot" } });
    defer rig.deinit();
    var context = rig.context();

    const pick = try testing.expectPick(try run(&context));
    defer pick.deinit(gpa);
    const removal = try testing.expectPick(try testing.selectRow(&pick, &context, 3));
    defer removal.deinit(gpa);
    try std.testing.expectEqualStrings("Remove a bot", removal.title);
    try std.testing.expectEqual(@as(usize, 2), removal.options.len);
    try std.testing.expectEqualStrings("@other_bot", removal.options[1].name);
    try testing.expectReopen(&context, &removal);
    switch (try testing.selectRow(&removal, &context, 1)) {
        .remote_remove => |index| try std.testing.expectEqual(@as(usize, 1), index),
        else => return error.ExpectedRemove,
    }
}
