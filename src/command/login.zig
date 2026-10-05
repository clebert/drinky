const std = @import("std");

const accounts = @import("accounts");

const Context = @import("Context.zig");
const testing = @import("testing.zig");
const model = @import("model.zig");

pub const name = "login";
pub const summary = "Sign in or switch the account";

pub fn run(context: *Context) Context.Error!Context.Outcome {
    return .{ .pick = try picker(context) };
}

pub fn picker(context: *Context) !Context.Outcome.Pick {
    var options: Context.Outcome.Options = .{ .gpa = context.gpa };
    errdefer options.deinit();
    var current: ?usize = null;
    for (&accounts.Account.table, 0..) |*row, account| {
        try writeRow(&options, context, row, account);
        if (context.choice.isActive(account)) current = account;
    }
    return .{
        .select = select,
        .title = "Sign in",
        .cancellation_message = "You canceled the sign-in selection.",
        .options = try options.toOwnedSlice(),
        .current = current,
    };
}

fn select(
    context: *Context,
    selection: Context.Outcome.Pick.Selection,
) Context.Error!Context.Outcome {
    const gpa = context.gpa;
    const account = selection.row;
    const row = &accounts.Account.table[account];
    if (context.choice.isActive(account))
        return Context.Outcome.reportNotice(
            gpa,
            .information,
            "{s} is already the active account.",
            .{row.id},
        );
    if (context.account_registry.isAuthenticated(account)) {
        context.choice.adopt(context.account_registry, context.remembered_model_names, account);
        return model.usedEvent(context);
    }
    if (row.hasLogin()) return .{ .login = account };
    if (context.account_registry.loadError(account)) |err| return Context.Outcome.reportNotice(
        gpa,
        .failure,
        "Drinky could not load the {s} account because of error {s}. Fix it and restart Drinky.",
        .{ row.id, @errorName(err) },
    );
    return Context.Outcome.reportNotice(
        gpa,
        .information,
        "Set {s} in the environment. Restart Drinky to use {s}.",
        .{ row.setting().?, row.id },
    );
}

fn writeRow(
    options: *Context.Outcome.Options,
    context: *const Context,
    row: *const accounts.Account,
    account: usize,
) !void {
    if (context.choice.isActive(account)) return options.print("{s}", .{row.id});
    if (context.account_registry.isAuthenticated(account)) {
        if (row.hasLogin()) return options.addTag(&.{ .name = row.id, .tag = "Signed in" });
        return options.addTag(&.{ .name = row.id, .tag = "Set" });
    }
    if (context.account_registry.loadError(account) != null)
        return options.addTag(&.{ .name = row.id, .tag = "Not loaded", .tag_pressure = true });
    return options.print("{s}", .{row.id});
}

test "the picker lists every account, marking the active, the signed-in, and the failed ones" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    try rig.init(&.{
        .variables = &.{
            .{ "ANTHROPIC_API_KEY", "sk-ant" },
            .{ "GOOGLE_APPLICATION_CREDENTIALS", "key.json" },
            .{ "GOOGLE_CLOUD_LOCATION", "europe-west4" },
        },
        .store =
        \\{ "anthropic-plan":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000 } }
        ,
    });
    defer rig.deinit();
    rig.choice.account = accounts.testing.anthropic_api_key;
    var context = rig.context();

    const pick = try picker(&context);
    defer pick.deinit(gpa);
    try std.testing.expectEqualStrings("Sign in", pick.title);
    try std.testing.expectEqual(accounts.Account.table.len, pick.options.len);
    try std.testing.expectEqual(accounts.testing.anthropic_api_key, pick.current.?);
    try std.testing.expectEqualStrings(
        "anthropic-plan",
        pick.options[accounts.testing.anthropic_plan].name,
    );
    try std.testing.expectEqualStrings(
        "Signed in",
        pick.options[accounts.testing.anthropic_plan].tag.?,
    );
    try std.testing.expectEqualStrings(
        "anthropic-api",
        pick.options[accounts.testing.anthropic_api].name,
    );
    try std.testing.expect(pick.options[accounts.testing.anthropic_api].tag == null);
    try std.testing.expectEqualStrings(
        "anthropic-api-key",
        pick.options[accounts.testing.anthropic_api_key].name,
    );
    try std.testing.expect(pick.options[accounts.testing.anthropic_api_key].tag == null);
    const failed = pick.options[accounts.testing.google_cloud_key];
    try std.testing.expectEqualStrings("google-cloud-key", failed.name);
    try std.testing.expectEqualStrings("Not loaded", failed.tag.?);
    try std.testing.expect(failed.tag_pressure);

    try testing.expectNotice(
        try testing.selectRow(&pick, &context, accounts.testing.anthropic_api_key),
        .information,
        "active account",
    );
    try testing.expectNotice(
        try testing.selectRow(&pick, &context, accounts.testing.google_cloud_key),
        .failure,
        "because of error BadLocation",
    );
    switch (try testing.selectRow(&pick, &context, accounts.testing.anthropic_plan)) {
        .event => |event| {
            defer event.deinit(gpa);
            try std.testing.expectEqualStrings(
                "Drinky now uses anthropic-plan. Fetch the model list of anthropic-plan with " ++
                    "/model.",
                event.content,
            );
        },
        else => return error.ExpectedEvent,
    }
    try std.testing.expectEqual(accounts.testing.anthropic_plan, rig.choice.account.?);
    try std.testing.expect(rig.choice.model == null);
}

test "select starts a login, instructs a key account, and adopts a set key with its model" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .variables = &.{.{ "OPENAI_API_KEY", "sk-openai" }} });
    defer rig.deinit();
    try rig.account_rig.seed(accounts.testing.openai_api_key, &.{"gpt-5.6-sol"});
    rig.remembered[accounts.testing.openai_api_key] = "gpt-5.6-sol";
    var context = rig.context();

    const pick = try picker(&context);
    defer pick.deinit(gpa);
    try std.testing.expect(pick.current == null);
    try std.testing.expectEqualStrings("Set", pick.options[accounts.testing.openai_api_key].tag.?);
    try std.testing.expect(pick.options[accounts.testing.google_cloud_key].tag == null);

    for (
        [_]usize{
            accounts.testing.anthropic_api,
            accounts.testing.openai_plan,
            accounts.testing.xai_plan,
            accounts.testing.openrouter_api,
        },
    ) |login| {
        switch (try testing.selectRow(&pick, &context, login)) {
            .login => |account| try std.testing.expectEqual(login, account),
            else => return error.ExpectedLogin,
        }
    }
    const settings = [_]struct { account: usize, setting: []const u8 }{
        .{ .account = accounts.testing.anthropic_api_key, .setting = "ANTHROPIC_API_KEY" },
        .{ .account = accounts.testing.xai_api_key, .setting = "XAI_API_KEY" },
        .{ .account = accounts.testing.openrouter_api_key, .setting = "OPENROUTER_API_KEY" },
        .{ .account = accounts.testing.deepseek_api_key, .setting = "DEEPSEEK_API_KEY" },
        .{ .account = accounts.testing.google_cloud_key, .setting = "GOOGLE_CLOUD_LOCATION" },
    };
    for (settings) |case| try testing.expectNotice(
        try testing.selectRow(&pick, &context, case.account),
        .information,
        case.setting,
    );
    switch (try testing.selectRow(&pick, &context, accounts.testing.openai_api_key)) {
        .event => |event| {
            defer event.deinit(gpa);
            try std.testing.expectEqualStrings(
                "Drinky now uses openai-api-key/gpt-5.6-sol.",
                event.content,
            );
        },
        else => return error.ExpectedEvent,
    }
    try std.testing.expectEqual(accounts.testing.openai_api_key, rig.choice.account.?);
    try std.testing.expectEqualStrings("gpt-5.6-sol", rig.choice.model.?.name());
}
