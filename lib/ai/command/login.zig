//! `/login`: a picker over every account (also the first-run bootstrap and the
//! fall-through after the last logout). The picker shows the credential store
//! as it stands, so `run` asks the app to read the store again, and the app
//! builds the picker with `picker` once the session settled on what it found.
//! `picker` and `select` index the same enum-order account list. The command
//! takes no argument.

const std = @import("std");

const llm = @import("../llm.zig");
const Context = @import("Context.zig");
const testing = @import("testing.zig");

pub const name = "login";
pub const summary = "sign in or switch the account";

/// Hand the open to the app. The registry table fixes the signature, and the
/// rows come from `picker` once the app settled the session on the store.
pub fn run(context: *Context) !Context.Outcome {
    _ = context;
    return .login_picker;
}

/// The picker over every account, on the registry as it stands.
pub fn picker(context: *Context) !Context.Outcome {
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

pub fn select(context: *Context, selection: Context.Outcome.Pick.Selection) !Context.Outcome {
    const gpa = context.gpa;
    const index = selection.row;
    const accounts = std.enums.values(llm.Account);
    if (index >= accounts.len)
        return Context.Outcome.reportNotice(gpa, .failure, "Select a valid account.", .{});
    const account = accounts[index];
    if (isActive(context, account))
        return Context.Outcome.reportNotice(
            gpa,
            .information,
            "{s} is already the active account.",
            .{account.id()},
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
        .{ account.id(), @errorName(err) },
    );
    return Context.Outcome.reportNotice(
        gpa,
        .information,
        "Set {s} in the environment. Restart Drinky to use {s}.",
        .{ account.credentialEnv().?, account.id() },
    );
}

/// Write the picker row of `account`: its identifier and its state. The
/// identifier already names the credential source, so the state says whether
/// that source delivered.
fn writeRow(options: *Context.Outcome.Options, context: *const Context, account: llm.Account) !void {
    const id = account.id();
    if (isActive(context, account)) return options.print("{s} (Active)", .{id});
    if (context.accounts.isAuthenticated(account)) {
        if (account.hasLogin()) return options.print("{s} (Signed in)", .{id});
        return options.print("{s} (Set)", .{id});
    }
    if (context.accounts.loadError(account) != null)
        return options.print("{s} (Not loaded)", .{id});
    return options.print("{s}", .{id});
}

fn isActive(context: *const Context, account: llm.Account) bool {
    const client = context.agent.client orelse return false;
    return client.account() == account;
}

// The rows must show the store as it stands, and only the app can settle the
// session on a change there, so the command hands the open to the app.
test "run asks the app to read the store before it opens the picker" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant" }, .{});
    defer testing.deinitAccounts(&accounts);
    var agent = testing.agent(gpa, .{ .anthropic_api_key = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    try std.testing.expectEqual(Context.Outcome.login_picker, try run(&context));
}

test "the picker lists every account, marking the active and authenticated ones" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant" }, .{ .anthropic = true });
    defer testing.deinitAccounts(&accounts);
    var agent = testing.agent(gpa, .{ .anthropic_api_key = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    switch (try picker(&context)) {
        .pick => |pick| {
            defer {
                for (pick.options) |option| gpa.free(option);
                gpa.free(pick.options);
            }
            try std.testing.expectEqualStrings("Sign in", pick.title);
            try std.testing.expectEqual(@as(usize, 10), pick.options.len);
            try std.testing.expectEqualStrings("anthropic-plan (Signed in)", pick.options[0]);
            try std.testing.expectEqualStrings("anthropic-api", pick.options[1]);
            try std.testing.expectEqualStrings("anthropic-api-key (Active)", pick.options[2]);
            try std.testing.expectEqualStrings("openai-plan", pick.options[3]);
            try std.testing.expectEqualStrings("openai-api-key", pick.options[4]);
            try std.testing.expectEqualStrings("xai-plan", pick.options[5]);
            try std.testing.expectEqualStrings("xai-api-key", pick.options[6]);
            try std.testing.expectEqualStrings("openrouter-api", pick.options[7]);
            try std.testing.expectEqualStrings("openrouter-api-key", pick.options[8]);
            try std.testing.expectEqualStrings("google-cloud-key", pick.options[9]);
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
    var agent = testing.agent(gpa, .{ .openai_api_key = "sk-openai" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    const loaded = try row(&context, .google_cloud_key);
    defer gpa.free(loaded);
    try std.testing.expectEqualStrings("google-cloud-key (Set)", loaded);
    const active = try row(&context, .openai_api_key);
    defer gpa.free(active);
    try std.testing.expectEqualStrings("openai-api-key (Active)", active);

    // A key file that did not load shows as such, and a pick names the error.
    accounts.google_auth = null;
    accounts.google_error = error.FileNotFound;
    const failed = try row(&context, .google_cloud_key);
    defer gpa.free(failed);
    try std.testing.expectEqualStrings("google-cloud-key (Not loaded)", failed);
    try Context.Outcome.expectNoticeContaining(
        try select(&context, .{ .payload = 0, .row = 9 }),
        .failure,
        "because of error FileNotFound",
    );

    // Without a load failure, the account is simply not set up.
    accounts.google_error = null;
    const absent = try row(&context, .google_cloud_key);
    defer gpa.free(absent);
    try std.testing.expectEqualStrings("google-cloud-key", absent);
    try Context.Outcome.expectNoticeContaining(
        try select(&context, .{ .payload = 0, .row = 9 }),
        .information,
        "GOOGLE_CLOUD_LOCATION",
    );
}

test "select starts login, instructs an API account, and no-ops the active one" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant" }, .{});
    defer testing.deinitAccounts(&accounts);
    var agent = testing.agent(gpa, .{ .anthropic_api_key = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    switch (try select(&context, .{ .payload = 0, .row = 1 })) {
        .login => |account| try std.testing.expectEqual(llm.Account.anthropic_api, account),
        else => return error.ExpectedLogin,
    }
    switch (try select(&context, .{ .payload = 0, .row = 3 })) {
        .login => |account| try std.testing.expectEqual(llm.Account.openai_plan, account),
        else => return error.ExpectedLogin,
    }
    try Context.Outcome.expectNoticeContaining(
        try select(&context, .{ .payload = 0, .row = 4 }),
        .information,
        "OPENAI_API_KEY",
    );
    switch (try select(&context, .{ .payload = 0, .row = 5 })) {
        .login => |account| try std.testing.expectEqual(llm.Account.xai_plan, account),
        else => return error.ExpectedLogin,
    }
    try Context.Outcome.expectNoticeContaining(
        try select(&context, .{ .payload = 0, .row = 6 }),
        .information,
        "XAI_API_KEY",
    );
    switch (try select(&context, .{ .payload = 0, .row = 7 })) {
        .login => |account| try std.testing.expectEqual(llm.Account.openrouter_api, account),
        else => return error.ExpectedLogin,
    }
    try Context.Outcome.expectNoticeContaining(
        try select(&context, .{ .payload = 0, .row = 8 }),
        .information,
        "OPENROUTER_API_KEY",
    );
    try Context.Outcome.expectNoticeContaining(
        try select(&context, .{ .payload = 0, .row = 2 }),
        .information,
        "active account",
    );
    try Context.Outcome.expectNotice(try select(&context, .{ .payload = 0, .row = 99 }), .failure);
}

test "select never re-runs the login for the active subscription" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{}, .{ .anthropic = true });
    defer testing.deinitAccounts(&accounts);
    var agent = testing.agent(gpa, .{ .anthropic_plan = undefined });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    try Context.Outcome.expectNoticeContaining(
        try select(&context, .{ .payload = 0, .row = 0 }),
        .information,
        "active account",
    );
    try std.testing.expectEqual(llm.Account.anthropic_plan, agent.client.?.account());
}

test "select hands an authenticated but inactive account to the app to switch" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant" }, .{ .anthropic = true });
    defer testing.deinitAccounts(&accounts);
    var agent = testing.agent(gpa, .{ .anthropic_api_key = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    switch (try select(&context, .{ .payload = 0, .row = 0 })) {
        .switch_account => |account| try std.testing.expectEqual(
            llm.Account.anthropic_plan,
            account,
        ),
        else => return error.ExpectedSwitch,
    }
}
