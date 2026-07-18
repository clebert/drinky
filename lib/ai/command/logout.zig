//! `/logout`: open a picker over the logged-in subscription accounts (API-key
//! accounts are environment-sourced and cannot be logged out). Selecting one
//! hands the app a `logout` outcome, which drops that account's stored
//! credentials; logging out the active account hands the session to the next
//! authenticated account, or forces a login when none remains. There is no typed
//! form — any argument is ignored and the picker opens regardless.

const std = @import("std");

const Accounts = @import("../Accounts.zig");
const llm = @import("../llm.zig");
const Context = @import("Context.zig");
const Outcome = @import("outcome.zig").Outcome;
const testing = @import("testing.zig");

pub const name = "logout";

pub fn run(context: *Context) !Outcome {
    var buffer: [account_count]llm.Account = undefined;
    const accounts = loggedIn(context.accounts, &buffer);
    if (accounts.len == 0)
        return Outcome.report(context.gpa, .err, "no subscription accounts to log out", .{});

    var options: Outcome.Options = .{ .gpa = context.gpa };
    errdefer options.deinit();
    for (accounts) |account| try options.print("{s}", .{account.label()});
    return .{ .pick = .{
        .command = name,
        .title = "Log out of an account",
        .options = try options.toOwnedSlice(),
        .current = null,
    } };
}

pub fn select(context: *Context, index: usize) !Outcome {
    var buffer: [account_count]llm.Account = undefined;
    const accounts = loggedIn(context.accounts, &buffer);
    if (index >= accounts.len) return Outcome.report(context.gpa, .err, "invalid selection", .{});
    return .{ .logout = accounts[index] };
}

const account_count = std.enums.values(llm.Account).len;

/// The logged-in subscription accounts, in enum order — the picker's rows,
/// re-derived identically by `run` (to list) and `select` (to resolve an index).
fn loggedIn(accounts: *const Accounts, buffer: []llm.Account) []llm.Account {
    var count: usize = 0;
    for (std.enums.values(llm.Account)) |account| {
        if (!account.isSubscription() or !accounts.isAuthenticated(account)) continue;
        buffer[count] = account;
        count += 1;
    }
    return buffer[0..count];
}

test "the picker lists only logged-in subscriptions; none reports an error" {
    const gpa = std.testing.allocator;

    var some = testing.accounts(.{ .anthropic = "sk-ant" }, false, true);
    var context: Context = .{ .gpa = gpa, .agent = undefined, .accounts = &some };
    switch (try run(&context)) {
        .pick => |pick| {
            defer {
                for (pick.options) |option| gpa.free(option);
                gpa.free(pick.options);
            }
            // The env API key is not loggable-out, so only the openai subscription shows.
            try std.testing.expectEqual(@as(usize, 1), pick.options.len);
            try std.testing.expectEqualStrings("openai subscription", pick.options[0]);
        },
        else => return error.ExpectedPick,
    }

    var none = testing.accounts(.{ .anthropic = "sk-ant" }, false, false);
    context.accounts = &none;
    try Outcome.expectFeedback(try run(&context), .err);
}

test "select names the chosen logged-in account, rejecting out of range" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant" }, true, false);
    var context: Context = .{ .gpa = gpa, .agent = undefined, .accounts = &accounts };

    switch (try select(&context, 0)) {
        .logout => |account| try std.testing.expectEqual(llm.Account.anthropic_subscription, account),
        else => return error.ExpectedLogout,
    }
    try Outcome.expectFeedback(try select(&context, 99), .err);
}
