//! `/login`: open a picker over every account, so the same picker serves a
//! mid-session login, the first-run bootstrap, and the fall-through after logging
//! out the last account. An unauthenticated subscription runs its OAuth flow on
//! select (a `login` outcome the app executes, suspending the tty around the
//! browser callback); an environment API account, which cannot be logged in
//! interactively, reports how to set its key and restart; an authenticated but
//! inactive account switches the session to it; the already-active account is
//! marked and does nothing. `run` and `select` index the same account list (enum
//! order), so a row resolves identically. Any argument is ignored.

const std = @import("std");

const Accounts = @import("../Accounts.zig");
const Agent = @import("../Agent.zig");
const llm = @import("../llm.zig");
const models = @import("../models.zig");
const provider = @import("../provider.zig");
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
        options[index] = try std.fmt.allocPrint(gpa, "{s}{s}", .{ account.label(), marker(context, account) });
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
    if (isActive(context, account)) return Outcome.report(gpa, .ok, "{s} is already active", .{account.label()});
    if (context.accounts.isAuthenticated(account)) {
        // Already authenticated: switch without a login (mirroring /model), on
        // the account's first listed model.
        var vendor_models: std.ArrayList(models.Model) = .empty;
        defer vendor_models.deinit(gpa);
        try context.accounts.listModels(account, &vendor_models, gpa);
        const model = vendor_models.items[0];
        context.agent.switchTo(context.accounts.client(account).?, model);
        return Outcome.report(gpa, .ok, "switched to {s} ({s})", .{ model.name, account.label() });
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

/// The suffix marking an account's state in the picker: the active account reads
/// as active, an authenticated but inactive subscription as logged in, an
/// inactive API account with its key as set, and anything unauthenticated has
/// none.
fn marker(context: *const Context, account: llm.Account) []const u8 {
    if (isActive(context, account)) return " (active)";
    if (!context.accounts.isAuthenticated(account)) return "";
    return if (account.isSubscription()) " (logged in)" else " (key set)";
}

/// Whether `account` is the session's active account (the agent's client).
fn isActive(context: *const Context, account: llm.Account) bool {
    const client = context.agent.client orelse return false;
    return client.account() == account;
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

fn testAgent(gpa: std.mem.Allocator, credentials: provider.Credentials) Agent {
    const client = provider.Client.init(gpa, std.testing.io, credentials, .{});
    return Agent.init(gpa, std.testing.io, client, .{
        .model = models.get(.anthropic, "claude-sonnet-4-6").?,
        .system = "",
        .retry = .{},
    });
}

test "the picker lists every account, marking the active and authenticated ones" {
    const gpa = std.testing.allocator;
    // An anthropic subscription logged in and an anthropic API key set (the
    // active account); both openai accounts unauthenticated.
    var accounts = testAccounts("sk-ant", true, false);
    var agent = testAgent(gpa, .{ .anthropic_api = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .agent = &agent, .accounts = &accounts };

    switch (try run(&context, "")) {
        .pick => |pick| {
            defer {
                for (pick.options) |option| gpa.free(option);
                gpa.free(pick.options);
            }
            try std.testing.expectEqual(@as(usize, 4), pick.options.len);
            try std.testing.expectEqualStrings("anthropic subscription (logged in)", pick.options[0]);
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
    var accounts = testAccounts("sk-ant", false, false);
    var agent = testAgent(gpa, .{ .anthropic_api = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .agent = &agent, .accounts = &accounts };

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

    // The active account (the env API key) does nothing but say so.
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

test "select never re-runs the login for the active subscription" {
    const gpa = std.testing.allocator;
    var accounts = testAccounts(null, true, false);
    var agent = testAgent(gpa, .{ .anthropic_subscription = undefined });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .agent = &agent, .accounts = &accounts };

    switch (try select(&context, 0)) {
        .feedback => |feedback| {
            defer gpa.free(feedback.content);
            try std.testing.expect(!feedback.is_error);
            try std.testing.expect(std.mem.indexOf(u8, feedback.content, "already active") != null);
        },
        else => return error.ExpectedFeedback,
    }
    try std.testing.expectEqual(llm.Account.anthropic_subscription, agent.client.?.account());
}

test "select switches to an authenticated but inactive subscription without a login" {
    const gpa = std.testing.allocator;
    var accounts = testAccounts("sk-ant", true, false);
    var agent = testAgent(gpa, .{ .anthropic_api = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .agent = &agent, .accounts = &accounts };

    switch (try select(&context, 0)) {
        .feedback => |feedback| {
            defer gpa.free(feedback.content);
            try std.testing.expect(!feedback.is_error);
            try std.testing.expect(std.mem.indexOf(u8, feedback.content, "switched to") != null);
        },
        else => return error.ExpectedFeedback,
    }
    try std.testing.expectEqual(llm.Account.anthropic_subscription, agent.client.?.account());
    try std.testing.expectEqualStrings("claude-opus-4-8", agent.model.name);
}
