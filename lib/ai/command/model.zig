//! `/model`: picker over every authenticated account's models, the active one
//! marked; a model is always chosen together with its account. Any argument is
//! ignored.

const std = @import("std");

const Accounts = @import("../Accounts.zig");
const llm = @import("../llm.zig");
const models = @import("../models.zig");
const Context = @import("Context.zig");
const Outcome = @import("outcome.zig").Outcome;
const testing = @import("testing.zig");

pub const name = "model";

/// One selectable list row: a model bound to the account it runs under.
const Combo = struct { account: llm.Account, model: models.Model };

pub fn run(context: *Context) !Outcome {
    const gpa = context.gpa;

    var combos: std.ArrayList(Combo) = .empty;
    defer combos.deinit(gpa);
    try collect(context.accounts, &combos, gpa);
    if (combos.items.len == 0)
        return Outcome.report(gpa, .err, "no authenticated accounts", .{});

    const active_account: ?llm.Account = if (context.agent.client) |client| client.account() else null;
    const active_model = context.agent.model.name;

    var options: Outcome.Options = .{ .gpa = gpa };
    errdefer options.deinit();
    var current: ?usize = null;
    for (combos.items, 0..) |combo, index| {
        try options.print("{s} ({s})", .{ combo.model.name, combo.account.label() });
        if (active_account) |account| {
            if (combo.account == account and std.mem.eql(u8, combo.model.name, active_model))
                current = index;
        }
    }
    return .{ .pick = .{
        .command = name,
        .title = "Select a model",
        .options = try options.toOwnedSlice(),
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

/// The picker's rows in account-enum then table order, re-derived identically by
/// `run` and `select`.
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

test "the picker lists every authenticated account's models, marking the active one" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant", .openai = "sk-openai" }, false, false);
    var agent = testing.agent(gpa, .{ .anthropic_api = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .agent = &agent, .accounts = &accounts };

    switch (try run(&context)) {
        .pick => |pick| {
            defer {
                for (pick.options) |option| gpa.free(option);
                gpa.free(pick.options);
            }
            // Three anthropic models plus three openai models, both keys present.
            try std.testing.expectEqual(@as(usize, 6), pick.options.len);
            try std.testing.expectEqualStrings("claude-opus-4-8 (anthropic api)", pick.options[0]);
            try std.testing.expectEqualStrings("gpt-5.6-sol (openai api)", pick.options[3]);
            try std.testing.expectEqualStrings("claude-sonnet-4-6 (anthropic api)", pick.options[pick.current.?]);
        },
        else => return error.ExpectedPick,
    }
}

test "select switches to the chosen account and model" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant", .openai = "sk-openai" }, false, false);
    var agent = testing.agent(gpa, .{ .anthropic_api = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .agent = &agent, .accounts = &accounts };

    // Row 3 is the first openai model, so selecting it crosses vendors.
    try Outcome.expectFeedback(try select(&context, 3), .ok);
    try std.testing.expectEqualStrings("gpt-5.6-sol", agent.model.name);
    try std.testing.expectEqual(llm.Account.openai_api, agent.client.?.account());

    try Outcome.expectFeedback(try select(&context, 99), .err);
    try std.testing.expectEqualStrings("gpt-5.6-sol", agent.model.name);
}

test "no authenticated accounts reports an error instead of a picker" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{}, false, false);
    var context: Context = .{ .gpa = gpa, .agent = undefined, .accounts = &accounts };

    try Outcome.expectFeedback(try run(&context), .err);
}

test "the active mark matches the account, not just the model name" {
    const gpa = std.testing.allocator;
    // Both anthropic accounts are authenticated, so every model name appears
    // twice; the mark must land on the active subscription's row.
    var accounts = testing.accounts(.{ .anthropic = "sk-ant" }, true, false);
    var agent = testing.agent(gpa, .{ .anthropic_subscription = undefined });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .agent = &agent, .accounts = &accounts };

    switch (try run(&context)) {
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
    var accounts = testing.accounts(.{ .anthropic = "sk-ant", .openai = "sk-openai" }, false, false);
    var agent = testing.agent(gpa, .{ .anthropic_api = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .agent = &agent, .accounts = &accounts };

    switch (try run(&context)) {
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
