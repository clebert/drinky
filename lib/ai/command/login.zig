//! `/login`: open a picker over every account, so the same picker serves a
//! mid-session login, the first-run bootstrap, and the fall-through after logging
//! out the last account. An unauthenticated subscription runs its OAuth flow on
//! select (a `login` outcome the app executes, suspending the tty around the
//! browser callback); an environment API account, which cannot be logged in
//! interactively, reports how to set its key and restart; an already-active
//! account is marked and does nothing. `run` and `select` index the same account
//! list (enum order), so a row resolves identically. Any argument is ignored.

const std = @import("std");

const Accounts = @import("../Accounts.zig");
const llm = @import("../llm.zig");
const Context = @import("Context.zig");
const Outcome = @import("outcome.zig").Outcome;

pub const name = "login";

pub fn run(context: *Context, args: []const u8) !Outcome {
    _ = args;
    const gpa = context.gpa;
    const accounts = std.enums.values(llm.Account);

    const options = try gpa.alloc([]const u8, accounts.len);
    var filled: usize = 0;
    errdefer {
        for (options[0..filled]) |option| gpa.free(option);
        gpa.free(options);
    }
    for (accounts, 0..) |account, index| {
        options[index] = try std.fmt.allocPrint(gpa, "{s}{s}", .{ account.label(), marker(context.accounts, account) });
        filled += 1;
    }
    return .{ .pick = .{
        .command = name,
        .title = "Log in to an account",
        .options = options,
        .current = null,
    } };
}

pub fn select(context: *Context, index: usize) !Outcome {
    const gpa = context.gpa;
    const accounts = std.enums.values(llm.Account);
    if (index >= accounts.len) return Outcome.report(gpa, .err, "invalid selection", .{});
    const account = accounts[index];
    if (context.accounts.isAuthenticated(account)) {
        // Mirror the picker marker: a subscription reads as logged in, an API
        // account as active from the environment.
        const how = if (account.isSubscription()) "logged in" else "active via the environment";
        return Outcome.report(gpa, .ok, "{s} is already {s}", .{ account.label(), how });
    }
    if (account.isSubscription()) return .{ .login = account };
    // An API account has no interactive login: its key comes from the environment.
    return Outcome.report(
        gpa,
        .ok,
        "{s} uses an API key: set {s} in the environment and restart pith",
        .{ account.label(), account.apiKeyEnv().? },
    );
}

/// The suffix marking an account's state in the picker: an authenticated
/// subscription reads as logged in, an authenticated API account as active from
/// the environment, and anything the user can still act on has none.
fn marker(accounts: *const Accounts, account: llm.Account) []const u8 {
    if (!accounts.isAuthenticated(account)) return "";
    return if (account.isSubscription()) " (logged in)" else " (active via env)";
}

fn testAccounts(anthropic_key: ?[]const u8, anthropic_ready: bool, openai_ready: bool) Accounts {
    return .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .timeouts = .{},
        .anthropic_auth = undefined,
        .openai_auth = undefined,
        .keys = .{ .anthropic = anthropic_key },
        .anthropic_subscription_ready = anthropic_ready,
        .openai_subscription_ready = openai_ready,
        .openai_subscription_context_windows = .empty,
    };
}

test "the picker lists every account, marking the authenticated ones" {
    const gpa = std.testing.allocator;
    // An anthropic subscription logged in and an anthropic API key set; both
    // openai accounts unauthenticated.
    var accounts = testAccounts("sk-ant", true, false);
    var context: Context = .{ .gpa = gpa, .agent = undefined, .accounts = &accounts };

    switch (try run(&context, "")) {
        .pick => |pick| {
            defer {
                for (pick.options) |option| gpa.free(option);
                gpa.free(pick.options);
            }
            try std.testing.expectEqual(@as(usize, 4), pick.options.len);
            try std.testing.expectEqualStrings("anthropic subscription (logged in)", pick.options[0]);
            try std.testing.expectEqualStrings("anthropic api (active via env)", pick.options[1]);
            try std.testing.expectEqualStrings("openai subscription", pick.options[2]);
            try std.testing.expectEqualStrings("openai api", pick.options[3]);
            try std.testing.expect(pick.current == null);
        },
        else => return error.ExpectedPick,
    }
}

test "select logs in a subscription, instructs an API account, and no-ops an active one" {
    const gpa = std.testing.allocator;
    var accounts = testAccounts("sk-ant", false, false);
    var context: Context = .{ .gpa = gpa, .agent = undefined, .accounts = &accounts };

    // An unauthenticated subscription hands the app a login to run.
    switch (try select(&context, 2)) {
        .login => |account| try std.testing.expectEqual(llm.Account.openai_subscription, account),
        else => return error.ExpectedLogin,
    }

    // An unauthenticated API account explains how to set its key rather than
    // attempting a login.
    switch (try select(&context, 3)) {
        .feedback => |feedback| {
            defer gpa.free(feedback.content);
            try std.testing.expect(!feedback.is_error);
            try std.testing.expect(std.mem.indexOf(u8, feedback.content, "OPENAI_API_KEY") != null);
        },
        else => return error.ExpectedFeedback,
    }

    // An active account (the env API key) does nothing but say so.
    switch (try select(&context, 1)) {
        .feedback => |feedback| {
            defer gpa.free(feedback.content);
            try std.testing.expect(!feedback.is_error);
            try std.testing.expect(std.mem.indexOf(u8, feedback.content, "already active") != null);
        },
        else => return error.ExpectedFeedback,
    }

    // An out-of-range index is reported.
    switch (try select(&context, 99)) {
        .feedback => |feedback| {
            defer gpa.free(feedback.content);
            try std.testing.expect(feedback.is_error);
        },
        else => return error.ExpectedFeedback,
    }
}
