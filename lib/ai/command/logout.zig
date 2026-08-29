//! `/logout`: a picker over the signed-in accounts. API-key accounts are
//! environment-sourced and have no logout. A selection hands the
//! app a `logout` outcome. The command takes no argument.

const std = @import("std");

const Accounts = @import("../Accounts.zig");
const llm = @import("../llm.zig");
const Context = @import("Context.zig");
const testing = @import("testing.zig");

pub const name = "logout";
pub const summary = "drop the credentials of an account";

pub fn run(context: *Context) !Context.Outcome {
    var buffer: [account_count]llm.Account = undefined;
    const accounts = loggedIn(context.accounts, &buffer);
    if (accounts.len == 0) return Context.Outcome.reportNotice(
        context.gpa,
        .failure,
        "No accounts are signed in.",
        .{},
    );

    var options: Context.Outcome.Options = .{ .gpa = context.gpa };
    errdefer options.deinit();
    for (accounts) |account| try options.print("{s}", .{account.label()});
    return .{ .pick = .{
        .select = select,
        .title = "Sign out",
        .cancellation_message = "You canceled the sign-out selection.",
        .options = try options.toOwnedSlice(),
        .current = null,
    } };
}

pub fn select(context: *Context, index: usize) !Context.Outcome {
    var buffer: [account_count]llm.Account = undefined;
    const accounts = loggedIn(context.accounts, &buffer);
    if (index >= accounts.len)
        return Context.Outcome.reportNotice(
            context.gpa,
            .failure,
            "Select a valid account.",
            .{},
        );
    return .{ .logout = accounts[index] };
}

const account_count = std.enums.values(llm.Account).len;

/// The picker's rows in enum order. `run` and `select` re-derive them identically.
fn loggedIn(accounts: *const Accounts, buffer: []llm.Account) []llm.Account {
    var count: usize = 0;
    for (std.enums.values(llm.Account)) |account| {
        if (!account.hasLogin() or !accounts.isAuthenticated(account)) continue;
        buffer[count] = account;
        count += 1;
    }
    return buffer[0..count];
}

test "the picker lists only signed-in accounts, and none reports an error" {
    const gpa = std.testing.allocator;

    var some = testing.accounts(.{ .anthropic = "sk-ant" }, .{ .openai = true });
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = undefined, .accounts = &some };
    switch (try run(&context)) {
        .pick => |pick| {
            defer {
                for (pick.options) |option| gpa.free(option);
                gpa.free(pick.options);
            }
            try std.testing.expectEqualStrings("Sign out", pick.title);
            try std.testing.expectEqual(@as(usize, 1), pick.options.len);
            try std.testing.expectEqualStrings("OpenAI Subscription", pick.options[0]);
        },
        else => return error.ExpectedPick,
    }

    var none = testing.accounts(.{ .anthropic = "sk-ant" }, .{});
    context.accounts = &none;
    try Context.Outcome.expectNotice(try run(&context), .failure);
}

test "select names the chosen signed-in account, rejecting out of range" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant" }, .{ .anthropic = true });
    defer testing.deinitAccounts(&accounts);
    var context: Context = .{
        .gpa = gpa,
        .io = undefined,
        .agent = undefined,
        .accounts = &accounts,
    };

    switch (try select(&context, 0)) {
        .logout => |account| try std.testing.expectEqual(
            llm.Account.anthropic_subscription,
            account,
        ),
        else => return error.ExpectedLogout,
    }
    try Context.Outcome.expectNotice(try select(&context, 99), .failure);
}
