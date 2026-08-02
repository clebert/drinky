//! `/login`: a picker over every account (also the first-run bootstrap and the
//! fall-through after the last logout). `run` and `select` index the same
//! enum-order account list. The command ignores any argument.

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
        .title = "Select an account to sign in",
        .cancellation_message = "You canceled the sign-in selection.",
        .options = try options.toOwnedSlice(),
        .current = null,
    } };
}

pub fn select(context: *Context, index: usize) !Context.Outcome {
    const gpa = context.gpa;
    const accounts = std.enums.values(llm.Account);
    if (index >= accounts.len)
        return Context.Outcome.reportNotice(gpa, .failure, "Select a valid account.", .{});
    const account = accounts[index];
    if (isActive(context, account))
        return Context.Outcome.reportNotice(
            gpa,
            .information,
            "{s} is already the active account.",
            .{account.label()},
        );
    // Authenticated but inactive: the app performs the switch so the configured
    // default model applies, exactly as in a startup on this account.
    if (context.accounts.isAuthenticated(account)) return .{ .switch_account = account };
    if (account.hasLogin()) return .{ .login = account };
    return Context.Outcome.reportNotice(
        gpa,
        .information,
        "Set {s} in the environment. Restart Pith to use {s}.",
        .{ account.apiKeyEnv().?, account.label() },
    );
}

/// The account's state suffix in the picker. Empty when unauthenticated.
fn marker(context: *const Context, account: llm.Account) []const u8 {
    if (isActive(context, account)) return " (Active)";
    if (!context.accounts.isAuthenticated(account)) return "";
    return if (account.hasLogin()) " (Signed in)" else " (API key set)";
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
            try std.testing.expectEqual(@as(usize, 5), pick.options.len);
            try std.testing.expectEqualStrings(
                "Anthropic Subscription (Signed in)",
                pick.options[0],
            );
            try std.testing.expectEqualStrings("Anthropic Console", pick.options[1]);
            try std.testing.expectEqualStrings("Anthropic API (Active)", pick.options[2]);
            try std.testing.expectEqualStrings("OpenAI Subscription", pick.options[3]);
            try std.testing.expectEqualStrings("OpenAI API", pick.options[4]);
            try std.testing.expect(pick.current == null);
        },
        else => return error.ExpectedPick,
    }
}

test "select starts login, instructs an API account, and no-ops the active one" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant" }, .{});
    var agent = testing.agent(gpa, .{ .anthropic_api = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    switch (try select(&context, 1)) {
        .login => |account| try std.testing.expectEqual(llm.Account.anthropic_console, account),
        else => return error.ExpectedLogin,
    }
    switch (try select(&context, 3)) {
        .login => |account| try std.testing.expectEqual(llm.Account.openai_subscription, account),
        else => return error.ExpectedLogin,
    }
    try Context.Outcome.expectNoticeContaining(
        try select(&context, 4),
        .information,
        "OPENAI_API_KEY",
    );
    try Context.Outcome.expectNoticeContaining(
        try select(&context, 2),
        .information,
        "active account",
    );
    try Context.Outcome.expectNotice(try select(&context, 99), .failure);
}

test "select never re-runs the login for the active subscription" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{}, .{ .anthropic = true });
    var agent = testing.agent(gpa, .{ .anthropic_subscription = undefined });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    try Context.Outcome.expectNoticeContaining(
        try select(&context, 0),
        .information,
        "active account",
    );
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
