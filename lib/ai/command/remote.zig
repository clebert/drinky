//! `/remote`: a picker over the saved Telegram bots, then an `Add a bot` row and,
//! while a bot is saved, a `Remove a bot` row that opens the list of bots to
//! remove. The command takes no argument. The app owns the network and the
//! store, so every row hands an action back to it.

const std = @import("std");

const Context = @import("Context.zig");

pub const name = "remote";
pub const summary = "attach a Telegram bot";

const add_row = "Add a bot";
const remove_row = "Remove a bot";

pub fn run(context: *Context) !Context.Outcome {
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
        .reopen = run,
    } };
}

pub fn select(context: *Context, index: usize) !Context.Outcome {
    const bot_count = context.remote_bots.len;
    if (index < bot_count) return .{ .remote_attach = index };
    if (index == bot_count) return .remote_add;
    if (index == bot_count + 1 and bot_count > 0) return openRemoval(context);
    return Context.Outcome.reportNotice(context.gpa, .failure, "Select a valid row.", .{});
}

/// The second list: every saved bot, and one pick removes it.
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
        .reopen = openRemoval,
    } };
}

fn selectRemoval(context: *Context, index: usize) !Context.Outcome {
    if (index >= context.remote_bots.len)
        return Context.Outcome.reportNotice(context.gpa, .failure, "Select a valid row.", .{});
    return .{ .remote_remove = index };
}

fn freePick(gpa: std.mem.Allocator, pick: *const Context.Outcome.Pick) void {
    for (pick.options) |option| gpa.free(option);
    gpa.free(pick.options);
}

test "a picker with no saved bot holds the add row alone" {
    const gpa = std.testing.allocator;
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = undefined, .accounts = undefined };

    switch (try run(&context)) {
        .pick => |pick| {
            defer freePick(gpa, &pick);
            try std.testing.expectEqualStrings("Remote", pick.title);
            try std.testing.expectEqual(@as(usize, 1), pick.options.len);
            try std.testing.expectEqualStrings(add_row, pick.options[0]);
            try std.testing.expect(pick.reopen.? == &run);
        },
        else => return error.ExpectedPick,
    }
    try std.testing.expect((try select(&context, 0)) == .remote_add);
    // No remove row exists, so its index is no row.
    try Context.Outcome.expectNotice(try select(&context, 1), .failure);
}

test "the rows name each bot, then the add row and the remove row" {
    const gpa = std.testing.allocator;
    var context: Context = .{
        .gpa = gpa,
        .io = undefined,
        .agent = undefined,
        .accounts = undefined,
        .remote_bots = &.{ "drinky_bot", "other_bot" },
    };

    switch (try run(&context)) {
        .pick => |pick| {
            defer freePick(gpa, &pick);
            try std.testing.expectEqual(@as(usize, 4), pick.options.len);
            try std.testing.expectEqualStrings("@drinky_bot", pick.options[0]);
            try std.testing.expectEqualStrings("@other_bot", pick.options[1]);
            try std.testing.expectEqualStrings(add_row, pick.options[2]);
            try std.testing.expectEqualStrings(remove_row, pick.options[3]);
        },
        else => return error.ExpectedPick,
    }
    switch (try select(&context, 1)) {
        .remote_attach => |index| try std.testing.expectEqual(@as(usize, 1), index),
        else => return error.ExpectedAttach,
    }
    try std.testing.expect((try select(&context, 2)) == .remote_add);
    try Context.Outcome.expectNotice(try select(&context, 4), .failure);
}

test "the remove row opens the second list, and one pick removes" {
    const gpa = std.testing.allocator;
    var context: Context = .{
        .gpa = gpa,
        .io = undefined,
        .agent = undefined,
        .accounts = undefined,
        .remote_bots = &.{ "drinky_bot", "other_bot" },
    };

    switch (try select(&context, 3)) {
        .pick => |pick| {
            defer freePick(gpa, &pick);
            try std.testing.expectEqualStrings("Remove a bot", pick.title);
            try std.testing.expectEqual(@as(usize, 2), pick.options.len);
            try std.testing.expectEqualStrings("@other_bot", pick.options[1]);
            // The list builds itself again, so Esc returns to the first step.
            try std.testing.expect(pick.reopen.? == &openRemoval);
            switch (try pick.select(&context, 1)) {
                .remote_remove => |index| try std.testing.expectEqual(@as(usize, 1), index),
                else => return error.ExpectedRemove,
            }
            try Context.Outcome.expectNotice(try pick.select(&context, 2), .failure);
        },
        else => return error.ExpectedPick,
    }
}
