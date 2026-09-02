//! `/login`: a picker over every account (also the first-run bootstrap and the
//! fall-through after the last logout). `run` and `select` index the same
//! enum-order account list. The command takes no argument.

const std = @import("std");

const llm = @import("../llm.zig");
const Context = @import("Context.zig");
const testing = @import("testing.zig");

pub const name = "login";
pub const summary = "sign in or switch the account";

pub fn run(context: *Context) !Context.Outcome {
    var options: Context.Outcome.Options = .{ .gpa = context.gpa };
    errdefer options.deinit();
    for (std.enums.values(llm.Account)) |account| try writeRow(&options, context, account);
    return .{ .pick = .{
        .select = select,
        .title = "Sign in",
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
    // Authenticated but inactive: the app performs the switch so the model that
    // account ran last applies, exactly as in a startup on this account.
    if (context.accounts.isAuthenticated(account)) return .{ .switch_account = account };
    if (account.hasLogin()) return .{ .login = account };
    // The environment names the account, and the credential still did not load.
    if (context.accounts.loadError(account)) |err| return Context.Outcome.reportNotice(
        gpa,
        .failure,
        "Drinky could not load the {s} account because of error {s}. Fix it and restart Drinky.",
        .{ account.label(), @errorName(err) },
    );
    return Context.Outcome.reportNotice(
        gpa,
        .information,
        "Set {s} in the environment. Restart Drinky to use {s}.",
        .{ account.credentialEnv().?, account.label() },
    );
}

/// Write the picker row of `account`: its label and its state.
fn writeRow(options: *Context.Outcome.Options, context: *const Context, account: llm.Account) !void {
    const label = account.label();
    if (isActive(context, account)) return options.print("{s} (Active)", .{label});
    const maybe_kind = account.credentialLabel();
    if (context.accounts.isAuthenticated(account)) {
        const kind = maybe_kind orelse return options.print("{s} (Signed in)", .{label});
        return options.print("{s} ({s} set)", .{ label, kind });
    }
    if (context.accounts.loadError(account) != null)
        return options.print("{s} ({s} not loaded)", .{ label, maybe_kind.? });
    return options.print("{s}", .{label});
}

fn isActive(context: *const Context, account: llm.Account) bool {
    const client = context.agent.client orelse return false;
    return client.account() == account;
}

test "the picker lists every account, marking the active and authenticated ones" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant" }, .{ .anthropic = true });
    defer testing.deinitAccounts(&accounts);
    var agent = testing.agent(gpa, .{ .anthropic_api = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    switch (try run(&context)) {
        .pick => |pick| {
            defer {
                for (pick.options) |option| gpa.free(option);
                gpa.free(pick.options);
            }
            try std.testing.expectEqualStrings("Sign in", pick.title);
            try std.testing.expectEqual(@as(usize, 6), pick.options.len);
            try std.testing.expectEqualStrings(
                "Anthropic Subscription (Signed in)",
                pick.options[0],
            );
            try std.testing.expectEqualStrings("Anthropic Console", pick.options[1]);
            try std.testing.expectEqualStrings("Anthropic API (Active)", pick.options[2]);
            try std.testing.expectEqualStrings("OpenAI Subscription", pick.options[3]);
            try std.testing.expectEqualStrings("OpenAI API", pick.options[4]);
            try std.testing.expectEqualStrings("Google Vertex", pick.options[5]);
            try std.testing.expect(pick.current == null);
        },
        else => return error.ExpectedPick,
    }
}

/// The row of `account` as the picker prints it. The caller frees it.
fn row(context: *const Context, account: llm.Account) ![]const u8 {
    var options: Context.Outcome.Options = .{ .gpa = context.gpa };
    errdefer options.deinit();
    try writeRow(&options, context, account);
    const rows = try options.toOwnedSlice();
    defer context.gpa.free(rows);
    return rows[0];
}

test "the picker marks a loaded key file, a failed one, and an API key apart" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .openai = "sk-openai" }, .{ .google = true });
    defer testing.deinitAccounts(&accounts);
    var agent = testing.agent(gpa, .{ .openai_api = "sk-openai" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    const loaded = try row(&context, .google_vertex);
    defer gpa.free(loaded);
    try std.testing.expectEqualStrings("Google Vertex (Key file set)", loaded);
    const active = try row(&context, .openai_api);
    defer gpa.free(active);
    try std.testing.expectEqualStrings("OpenAI API (Active)", active);

    // A key file that did not load shows as such, and a pick names the error.
    accounts.google_auth = null;
    accounts.google_error = error.FileNotFound;
    const failed = try row(&context, .google_vertex);
    defer gpa.free(failed);
    try std.testing.expectEqualStrings("Google Vertex (Key file not loaded)", failed);
    try Context.Outcome.expectNoticeContaining(
        try select(&context, 5),
        .failure,
        "because of error FileNotFound",
    );

    // Without a load failure, the account is simply not set up.
    accounts.google_error = null;
    const absent = try row(&context, .google_vertex);
    defer gpa.free(absent);
    try std.testing.expectEqualStrings("Google Vertex", absent);
    try Context.Outcome.expectNoticeContaining(
        try select(&context, 5),
        .information,
        "GOOGLE_CLOUD_LOCATION",
    );
}

test "select starts login, instructs an API account, and no-ops the active one" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant" }, .{});
    defer testing.deinitAccounts(&accounts);
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
    defer testing.deinitAccounts(&accounts);
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
    defer testing.deinitAccounts(&accounts);
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
