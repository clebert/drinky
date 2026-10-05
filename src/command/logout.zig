const std = @import("std");

const accounts = @import("accounts");

const Message = @import("../Message.zig");
const Context = @import("Context.zig");
const testing = @import("testing.zig");

pub const name = "logout";
pub const summary = "Drop the credentials of an account";

pub fn run(context: *Context) Context.Error!Context.Outcome {
    var buffer: [accounts.Account.table.len]usize = undefined;
    const list = loggedIn(context.account_registry, &buffer);
    if (list.len == 0) return .{ .refusal = try Message.print(
        context.gpa,
        .failure,
        "No accounts are signed in.",
        .{},
    ) };

    var options: Context.Outcome.Options = .{ .gpa = context.gpa };
    errdefer options.deinit();
    for (list) |account| try options.print("{s}", .{accounts.Account.table[account].id});
    return .{ .pick = .{
        .select = select,
        .title = "Sign out",
        .cancellation_message = "You canceled the sign-out selection.",
        .options = try options.toOwnedSlice(),
        .current = null,
    } };
}

fn select(
    context: *Context,
    selection: Context.Outcome.Pick.Selection,
) Context.Error!Context.Outcome {
    var buffer: [accounts.Account.table.len]usize = undefined;
    const list = loggedIn(context.account_registry, &buffer);
    return .{ .logout = list[selection.row] };
}

fn loggedIn(registry: *accounts.Registry, buffer: []usize) []usize {
    var count: usize = 0;
    for (&accounts.Account.table, 0..) |*row, account| {
        if (!row.hasLogin() or !registry.isAuthenticated(account)) continue;
        buffer[count] = account;
        count += 1;
    }
    return buffer[0..count];
}

test "the picker lists only signed-in accounts and fails without one" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "ANTHROPIC_API_KEY", "sk-ant" }},
        .store =
        \\{ "openai-plan":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000,
        \\      "account_id": "account" } }
        ,
    });
    defer rig.deinit();
    var context = rig.context();

    const pick = try testing.expectPick(try run(&context));
    defer pick.deinit(gpa);
    try std.testing.expectEqualStrings("Sign out", pick.title);
    try std.testing.expectEqual(@as(usize, 1), pick.options.len);
    try std.testing.expectEqualStrings("openai-plan", pick.options[0].name);
    switch (try testing.selectRow(&pick, &context, 0)) {
        .logout => |account| try std.testing.expectEqual(
            accounts.Account.index("openai-plan").?,
            account,
        ),
        else => return error.ExpectedLogout,
    }

    try rig.registry().logout(accounts.Account.index("openai-plan").?);
    try testing.expectRefusal(
        try run(&context),
        .failure,
        "No accounts are signed in.",
    );
}
