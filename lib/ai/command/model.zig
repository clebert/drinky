//! `/model`: open a picker over every account-qualified model the session is
//! authenticated for — each of an authenticated account's models, labeled by its
//! account — with the active one marked. Selecting one switches the active
//! account and model together from the next turn onward. There is no typed form:
//! a model is always chosen together with its account, so any argument is ignored
//! and the picker opens regardless.

const std = @import("std");

const Accounts = @import("../Accounts.zig");
const Agent = @import("../Agent.zig");
const llm = @import("../llm.zig");
const models = @import("../models.zig");
const provider = @import("../provider.zig");
const Context = @import("Context.zig");
const Outcome = @import("outcome.zig").Outcome;

pub const name = "model";

/// One selectable list row: a model bound to the account it runs under.
const Combo = struct { account: llm.Account, model: models.Model };

pub fn run(context: *Context, args: []const u8) !Outcome {
    _ = args;
    const gpa = context.gpa;

    var combos: std.ArrayList(Combo) = .empty;
    defer combos.deinit(gpa);
    try collect(context.accounts, &combos, gpa);
    if (combos.items.len == 0)
        return Outcome.report(gpa, .err, "no authenticated accounts", .{});

    const active_account: ?llm.Account = if (context.agent.client) |client| client.account() else null;
    const active_model = context.agent.model.name;

    const options = try gpa.alloc([]const u8, combos.items.len);
    var filled: usize = 0;
    errdefer {
        for (options[0..filled]) |option| gpa.free(option);
        gpa.free(options);
    }
    var current: ?usize = null;
    for (combos.items, 0..) |combo, index| {
        options[index] = try std.fmt.allocPrint(gpa, "{s} ({s})", .{ combo.model.name, combo.account.label() });
        filled += 1;
        if (active_account) |account| {
            if (combo.account == account and std.mem.eql(u8, combo.model.name, active_model))
                current = index;
        }
    }
    return .{ .pick = .{
        .command = name,
        .title = "Select a model",
        .options = options,
        .current = current,
    } };
}

pub fn select(context: *Context, index: usize) !Outcome {
    const gpa = context.gpa;
    var combos: std.ArrayList(Combo) = .empty;
    defer combos.deinit(gpa);
    try collect(context.accounts, &combos, gpa);
    if (index >= combos.items.len)
        return Outcome.report(gpa, .err, "invalid selection", .{});

    const combo = combos.items[index];
    context.agent.switchTo(context.accounts.client(combo.account).?, combo.model);
    return Outcome.report(gpa, .ok, "switched to {s} ({s})", .{ combo.model.name, combo.account.label() });
}

/// Every authenticated account's models, in account-enum then table order — the
/// picker's rows, re-derived identically by `run` (to list) and `select` (to
/// resolve an index).
fn collect(accounts: *const Accounts, out: *std.ArrayList(Combo), gpa: std.mem.Allocator) !void {
    for (std.enums.values(llm.Account)) |account| {
        if (!accounts.isAuthenticated(account)) continue;
        var vendor_models: std.ArrayList(models.Model) = .empty;
        defer vendor_models.deinit(gpa);
        try accounts.listModels(account, &vendor_models, gpa);
        for (vendor_models.items) |vendor_model|
            try out.append(gpa, .{ .account = account, .model = vendor_model });
    }
}

fn testAccounts(keys: Accounts.ApiKeys, anthropic_ready: bool) Accounts {
    return .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .timeouts = .{},
        .anthropic_auth = undefined,
        .openai_auth = undefined,
        .keys = keys,
        .anthropic_subscription_ready = anthropic_ready,
        .openai_subscription_ready = false,
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

test "the picker lists every authenticated account's models, marking the active one" {
    const gpa = std.testing.allocator;
    var accounts = testAccounts(.{ .anthropic = "sk-ant", .openai = "sk-openai" }, false);
    var agent = testAgent(gpa, .{ .anthropic_api = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .agent = &agent, .accounts = &accounts };

    switch (try run(&context, "")) {
        .pick => |pick| {
            defer {
                for (pick.options) |option| gpa.free(option);
                gpa.free(pick.options);
            }
            // Three anthropic models plus three openai models, both keys present.
            try std.testing.expectEqual(@as(usize, 6), pick.options.len);
            try std.testing.expectEqualStrings("claude-opus-4-8 (anthropic api)", pick.options[0]);
            try std.testing.expectEqualStrings("gpt-5.6-sol (openai api)", pick.options[3]);
            // The active account+model (anthropic api, sonnet 4.6) is preselected.
            try std.testing.expectEqualStrings("claude-sonnet-4-6 (anthropic api)", pick.options[pick.current.?]);
        },
        else => return error.ExpectedPick,
    }
}

test "select switches to the chosen account and model" {
    const gpa = std.testing.allocator;
    var accounts = testAccounts(.{ .anthropic = "sk-ant", .openai = "sk-openai" }, false);
    var agent = testAgent(gpa, .{ .anthropic_api = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .agent = &agent, .accounts = &accounts };

    // Row 3 is the first openai model, so selecting it crosses vendors.
    switch (try select(&context, 3)) {
        .feedback => |feedback| {
            defer gpa.free(feedback.content);
            try std.testing.expect(!feedback.is_error);
        },
        else => return error.ExpectedFeedback,
    }
    try std.testing.expectEqualStrings("gpt-5.6-sol", agent.model.name);
    try std.testing.expectEqual(llm.Account.openai_api, agent.client.?.account());

    // An out-of-range index is reported, leaving the model unchanged.
    switch (try select(&context, 99)) {
        .feedback => |feedback| {
            defer gpa.free(feedback.content);
            try std.testing.expect(feedback.is_error);
        },
        else => return error.ExpectedFeedback,
    }
    try std.testing.expectEqualStrings("gpt-5.6-sol", agent.model.name);
}

test "no authenticated accounts reports an error instead of a picker" {
    const gpa = std.testing.allocator;
    var accounts = testAccounts(.{}, false);
    var context: Context = .{ .gpa = gpa, .agent = undefined, .accounts = &accounts };

    switch (try run(&context, "")) {
        .feedback => |feedback| {
            defer gpa.free(feedback.content);
            try std.testing.expect(feedback.is_error);
        },
        else => return error.ExpectedFeedback,
    }
}

test "the active mark matches the account, not just the model name" {
    const gpa = std.testing.allocator;
    // Both anthropic accounts are authenticated, so every model name appears
    // twice; the mark must land on the active subscription's row.
    var accounts = testAccounts(.{ .anthropic = "sk-ant" }, true);
    var agent = testAgent(gpa, .{ .anthropic_subscription = undefined });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .agent = &agent, .accounts = &accounts };

    switch (try run(&context, "")) {
        .pick => |pick| {
            defer {
                for (pick.options) |option| gpa.free(option);
                gpa.free(pick.options);
            }
            try std.testing.expectEqualStrings("claude-sonnet-4-6 (anthropic subscription)", pick.options[pick.current.?]);
        },
        else => return error.ExpectedPick,
    }
}

fn runUnderOom(gpa: std.mem.Allocator) !void {
    var accounts = testAccounts(.{ .anthropic = "sk-ant", .openai = "sk-openai" }, false);
    var agent = testAgent(gpa, .{ .anthropic_api = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .agent = &agent, .accounts = &accounts };

    switch (try run(&context, "")) {
        .pick => |pick| {
            for (pick.options) |option| gpa.free(option);
            gpa.free(pick.options);
        },
        else => return error.ExpectedPick,
    }
}

test "a failed picker build frees every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, runUnderOom, .{});
}
