//! `/login`: picker over every account (also the first-run bootstrap and the
//! fall-through after the last logout). `run` and `select` index the same
//! enum-order account list; any argument is ignored.

const std = @import("std");

const llm = @import("../llm.zig");
const Context = @import("Context.zig");
const testing = @import("testing.zig");

pub const name = "login";

pub fn run(context: *Context) !Context.Outcome {
    var options: Context.Outcome.Options = .{ .gpa = context.gpa };
    errdefer options.deinit();
    for (std.enums.values(llm.Account)) |account|
        try options.print("{s}{s}", .{ account.label(), marker(context, account) });
    return .{ .pick = .{
        .select = select,
        .title = "Log in to an account",
        .options = try options.toOwnedSlice(),
        .current = null,
    } };
}

pub fn select(context: *Context, index: usize) !Context.Outcome {
    const gpa = context.gpa;
    const accounts = std.enums.values(llm.Account);
    if (index >= accounts.len) return Context.Outcome.report(gpa, .err, "invalid selection", .{});
    const account = accounts[index];
    if (isActive(context, account))
        return Context.Outcome.report(gpa, .ok, "{s} is already active", .{account.label()});
    // Authenticated but inactive: the app performs the switch so the configured
    // default model applies, exactly as a startup on this account would.
    if (context.accounts.isAuthenticated(account)) return .{ .switch_account = account };
    if (account.isSubscription()) return .{ .login = account };
    return Context.Outcome.report(
        gpa,
        .ok,
        "{s} uses an API key: set {s} in the environment and restart pith",
        .{ account.label(), account.apiKeyEnv().? },
    );
}

/// The account's state suffix in the picker; empty when unauthenticated.
fn marker(context: *const Context, account: llm.Account) []const u8 {
    if (isActive(context, account)) return " (active)";
    if (!context.accounts.isAuthenticated(account)) return "";
    return if (account.isSubscription()) " (logged in)" else " (key set)";
}

fn isActive(context: *const Context, account: llm.Account) bool {
    const client = context.agent.client orelse return false;
    return client.account() == account;
}

test "the picker lists every account, marking the active and authenticated ones" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant" }, .{ .anthropic = true });
    var agent = testing.agent(gpa, .{ .anthropic_api = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    switch (try run(&context)) {
        .pick => |pick| {
            defer {
                for (pick.options) |option| gpa.free(option);
                gpa.free(pick.options);
            }
            try std.testing.expectEqual(@as(usize, 4), pick.options.len);
            try std.testing.expectEqualStrings(
                "anthropic subscription (logged in)",
                pick.options[0],
            );
            try std.testing.expectEqualStrings("anthropic api (active)", pick.options[1]);
            try std.testing.expectEqualStrings("openai subscription", pick.options[2]);
            try std.testing.expectEqualStrings("openai api", pick.options[3]);
            try std.testing.expect(pick.current == null);
        },
        else => return error.ExpectedPick,
    }
}

test "select logs in a subscription, instructs an API account, and no-ops the active one" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant" }, .{});
    var agent = testing.agent(gpa, .{ .anthropic_api = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    switch (try select(&context, 2)) {
        .login => |account| try std.testing.expectEqual(llm.Account.openai_subscription, account),
        else => return error.ExpectedLogin,
    }
    try Context.Outcome.expectFeedbackContaining(try select(&context, 3), .ok, "OPENAI_API_KEY");
    try Context.Outcome.expectFeedbackContaining(try select(&context, 1), .ok, "already active");
    try Context.Outcome.expectFeedback(try select(&context, 99), .err);
}

test "select never re-runs the login for the active subscription" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{}, .{ .anthropic = true });
    var agent = testing.agent(gpa, .{ .anthropic_subscription = undefined });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    try Context.Outcome.expectFeedbackContaining(try select(&context, 0), .ok, "already active");
    try std.testing.expectEqual(llm.Account.anthropic_subscription, agent.client.?.account());
}

test "select hands an authenticated but inactive account to the app to switch" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant" }, .{ .anthropic = true });
    var agent = testing.agent(gpa, .{ .anthropic_api = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    switch (try select(&context, 0)) {
        .switch_account => |account| try std.testing.expectEqual(
            llm.Account.anthropic_subscription,
            account,
        ),
        else => return error.ExpectedSwitch,
    }
}
