//! `/model`: a stepped picker that ends on one model. The steps are the
//! provider, the account, and the model. A step that offers one row alone opens
//! the next step at once, so the user answers an open question only. A selection
//! always chooses a model together with its account. The command takes no
//! argument.
//!
//! A selector receives the row index alone, so it carries no earlier choice. The
//! compiler therefore builds one selector per provider and one per account.

const std = @import("std");

const Accounts = @import("../Accounts.zig");
const llm = @import("../llm.zig");
const models = @import("../models.zig");
const Context = @import("Context.zig");
const testing = @import("testing.zig");

pub const name = "model";
pub const summary = "switch account and model together";

/// Every step belongs to one `/model` run, so all three report one cancellation.
const cancellation_message = "You canceled the model selection.";

/// A picker selector. It takes the row index alone, so a step that depends on an
/// earlier choice needs one selector for each value of that choice.
const Selector = *const fn (*Context, usize) anyerror!Context.Outcome;

/// The parts of the model picker that name one account.
const ModelStep = struct {
    select: Selector,
    title: []const u8,
};

pub fn run(context: *Context) !Context.Outcome {
    var buffer: [std.enums.values(llm.Provider).len]llm.Provider = undefined;
    const vendors = authenticatedProviders(context.accounts, &buffer);
    if (vendors.len == 0)
        return Context.Outcome.reportNotice(
            context.gpa,
            .failure,
            "Sign in to an account before you select a model.",
            .{},
        );
    // One provider answers this step already, so the flow opens the next one.
    if (vendors.len == 1) return accountStep(context, vendors[0]);

    var options: Context.Outcome.Options = .{ .gpa = context.gpa };
    errdefer options.deinit();
    var current: ?usize = null;
    const active_account = activeAccount(context);
    for (vendors, 0..) |vendor, index| {
        try options.print("{s}", .{vendor.label()});
        if (active_account) |account| {
            if (account.provider() == vendor) current = index;
        }
    }
    return .{ .pick = .{
        .select = selectProvider,
        .title = "Select a provider",
        .cancellation_message = cancellation_message,
        .options = try options.toOwnedSlice(),
        .current = current,
    } };
}

fn selectProvider(context: *Context, index: usize) anyerror!Context.Outcome {
    var buffer: [std.enums.values(llm.Provider).len]llm.Provider = undefined;
    const vendors = authenticatedProviders(context.accounts, &buffer);
    if (index >= vendors.len) return Context.Outcome.reportNotice(
        context.gpa,
        .failure,
        "Select a valid provider.",
        .{},
    );
    return accountStep(context, vendors[index]);
}

/// The account step of `vendor`: a picker over its authenticated accounts, or
/// the model step when it holds one account alone. The caller guarantees that
/// `vendor` has an authenticated account.
fn accountStep(context: *Context, vendor: llm.Provider) !Context.Outcome {
    var buffer: [std.enums.values(llm.Account).len]llm.Account = undefined;
    const list = authenticatedAccounts(context.accounts, vendor, &buffer);
    std.debug.assert(list.len > 0);
    if (list.len == 1) return modelStep(context, list[0]);

    var options: Context.Outcome.Options = .{ .gpa = context.gpa };
    errdefer options.deinit();
    var current: ?usize = null;
    const active_account = activeAccount(context);
    for (list, 0..) |account, index| {
        try options.print("{s}", .{account.label()});
        if (active_account) |active| {
            if (active == account) current = index;
        }
    }
    return .{ .pick = .{
        .select = switch (vendor) {
            inline else => |tag| selectAccountOf(tag),
        },
        .title = "Select an account",
        .cancellation_message = cancellation_message,
        .options = try options.toOwnedSlice(),
        .current = current,
    } };
}

/// The selector of the account picker of `vendor`.
fn selectAccountOf(comptime vendor: llm.Provider) Selector {
    return struct {
        fn select(context: *Context, index: usize) anyerror!Context.Outcome {
            var buffer: [std.enums.values(llm.Account).len]llm.Account = undefined;
            const list = authenticatedAccounts(context.accounts, vendor, &buffer);
            if (index >= list.len) return Context.Outcome.reportNotice(
                context.gpa,
                .failure,
                "Select a valid account.",
                .{},
            );
            return modelStep(context, list[index]);
        }
    }.select;
}

/// The last step: a picker over the models of `account`. The title names the
/// account, because an earlier step can collapse and hide it.
fn modelStep(context: *Context, account: llm.Account) !Context.Outcome {
    const gpa = context.gpa;
    var list: std.ArrayList(models.Model) = .empty;
    defer list.deinit(gpa);
    try context.accounts.listModels(account, &list, gpa);

    var options: Context.Outcome.Options = .{ .gpa = gpa };
    errdefer options.deinit();
    var current: ?usize = null;
    for (list.items, 0..) |model, index| {
        try options.print("{s}", .{model.name});
        if (isActive(context, account, model.name)) current = index;
    }
    const step: ModelStep = switch (account) {
        inline else => |tag| modelStepOf(tag),
    };
    return .{ .pick = .{
        .select = step.select,
        .title = step.title,
        .cancellation_message = cancellation_message,
        .options = try options.toOwnedSlice(),
        .current = current,
    } };
}

/// The selector and the title of the model picker of `account`.
fn modelStepOf(comptime account: llm.Account) ModelStep {
    return .{
        .select = struct {
            fn select(context: *Context, index: usize) anyerror!Context.Outcome {
                const gpa = context.gpa;
                var list: std.ArrayList(models.Model) = .empty;
                defer list.deinit(gpa);
                try context.accounts.listModels(account, &list, gpa);
                if (index >= list.items.len) return Context.Outcome.reportNotice(
                    gpa,
                    .failure,
                    "Select a valid model.",
                    .{},
                );
                return apply(context, account, &list.items[index]);
            }
        }.select,
        .title = comptime "Select a model for " ++ account.label(),
    };
}

/// Run `model` under `account` from the next turn on. The account of a picked
/// row is authenticated, so it always has a client.
fn apply(context: *Context, account: llm.Account, model: *const models.Model) !Context.Outcome {
    const gpa = context.gpa;
    if (isActive(context, account, model.name)) return Context.Outcome.reportNotice(
        gpa,
        .information,
        "Drinky already uses {s} with {s}.",
        .{ model.name, account.label() },
    );
    context.agent.switchTo(context.accounts.client(account).?, model.*);
    return Context.Outcome.reportEvent(
        gpa,
        .information,
        "Drinky now uses {s} with {s}.",
        .{ model.name, account.label() },
    );
}

/// The providers with at least one authenticated account, in enum order. Every
/// step re-derives its list identically, so a row index stays stable.
fn authenticatedProviders(registry: *const Accounts, out: []llm.Provider) []llm.Provider {
    var count: usize = 0;
    for (std.enums.values(llm.Provider)) |vendor| {
        for (std.enums.values(llm.Account)) |account| {
            if (account.provider() != vendor or !registry.isAuthenticated(account)) continue;
            out[count] = vendor;
            count += 1;
            break;
        }
    }
    return out[0..count];
}

/// The authenticated accounts of `vendor`, in enum order.
fn authenticatedAccounts(
    registry: *const Accounts,
    vendor: llm.Provider,
    out: []llm.Account,
) []llm.Account {
    var count: usize = 0;
    for (std.enums.values(llm.Account)) |account| {
        if (account.provider() != vendor or !registry.isAuthenticated(account)) continue;
        out[count] = account;
        count += 1;
    }
    return out[0..count];
}

/// The account that runs now, or null while Drinky is signed out.
fn activeAccount(context: *const Context) ?llm.Account {
    const client = context.agent.client orelse return null;
    return client.account();
}

/// Whether `account` and `model_name` are the pair that runs now.
fn isActive(context: *const Context, account: llm.Account, model_name: []const u8) bool {
    const active_account = activeAccount(context) orelse return false;
    return active_account == account and std.mem.eql(u8, context.agent.model.name, model_name);
}

/// Test helper: the picker of `outcome`, which the caller must free.
fn expectPick(outcome: Context.Outcome) !Context.Outcome.Pick {
    return switch (outcome) {
        .pick => |pick| pick,
        else => error.ExpectedPick,
    };
}

/// Test helper: free the rows of a picker.
fn freePick(gpa: std.mem.Allocator, pick: *const Context.Outcome.Pick) void {
    for (pick.options) |option| gpa.free(option);
    gpa.free(pick.options);
}

test "the first step lists the providers with an authenticated account" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant", .openai = "sk-openai" }, .{});
    var agent = testing.agent(gpa, .{ .anthropic_api = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    const pick = try expectPick(try run(&context));
    defer freePick(gpa, &pick);
    try std.testing.expectEqualStrings("Select a provider", pick.title);
    try std.testing.expectEqual(@as(usize, 2), pick.options.len);
    try std.testing.expectEqualStrings("Anthropic", pick.options[0]);
    try std.testing.expectEqualStrings("OpenAI", pick.options[1]);
    // The active account marks its provider.
    try std.testing.expectEqual(@as(usize, 0), pick.current.?);
}

test "one provider alone opens the account step at once" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant" }, .{ .anthropic = true });
    var agent = testing.agent(gpa, .{ .anthropic_api = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    const pick = try expectPick(try run(&context));
    defer freePick(gpa, &pick);
    try std.testing.expectEqualStrings("Select an account", pick.title);
    try std.testing.expectEqual(@as(usize, 2), pick.options.len);
    try std.testing.expectEqualStrings("Anthropic Subscription", pick.options[0]);
    try std.testing.expectEqualStrings("Anthropic API", pick.options[1]);
    try std.testing.expectEqual(@as(usize, 1), pick.current.?);
}

test "one account alone opens the model step at once" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant" }, .{});
    var agent = testing.agent(gpa, .{ .anthropic_api = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    // Both earlier steps hold one row, so the model list is the whole command.
    const pick = try expectPick(try run(&context));
    defer freePick(gpa, &pick);
    try std.testing.expectEqualStrings("Select a model for Anthropic API", pick.title);
    try std.testing.expectEqual(@as(usize, 5), pick.options.len);
    try std.testing.expectEqualStrings("claude-fable-5", pick.options[0]);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", pick.options[pick.current.?]);
}

test "a provider row opens its accounts, and an account row opens its models" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(
        .{ .anthropic = "sk-ant", .openai = "sk-openai" },
        .{ .anthropic = true },
    );
    var agent = testing.agent(gpa, .{ .anthropic_api = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    const vendors = try expectPick(try run(&context));
    defer freePick(gpa, &vendors);
    const anthropic_accounts = try expectPick(try vendors.select(&context, 0));
    defer freePick(gpa, &anthropic_accounts);
    try std.testing.expectEqual(@as(usize, 2), anthropic_accounts.options.len);

    const anthropic_models = try expectPick(try anthropic_accounts.select(&context, 0));
    defer freePick(gpa, &anthropic_models);
    try std.testing.expectEqualStrings(
        "Select a model for Anthropic Subscription",
        anthropic_models.title,
    );
    // The subscription is not the active account, so no row is the current one.
    try std.testing.expect(anthropic_models.current == null);

    // OpenAI holds one authenticated account, so its row skips the account step.
    const openai_models = try expectPick(try vendors.select(&context, 1));
    defer freePick(gpa, &openai_models);
    try std.testing.expectEqualStrings("Select a model for OpenAI API", openai_models.title);
    try std.testing.expectEqual(@as(usize, 3), openai_models.options.len);
    try std.testing.expectEqualStrings("gpt-5.6-sol", openai_models.options[0]);
}

test "a model row switches to the chosen account and model" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant", .openai = "sk-openai" }, .{});
    var agent = testing.agent(gpa, .{ .anthropic_api = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    const vendors = try expectPick(try run(&context));
    defer freePick(gpa, &vendors);
    const openai_models = try expectPick(try vendors.select(&context, 1));
    defer freePick(gpa, &openai_models);

    // The selection crosses vendors, so it switches the account too.
    try Context.Outcome.expectEvent(try openai_models.select(&context, 0), .information);
    try std.testing.expectEqualStrings("gpt-5.6-sol", agent.model.name);
    try std.testing.expectEqual(llm.Account.openai_api, agent.client.?.account());

    try Context.Outcome.expectNotice(try openai_models.select(&context, 0), .information);
    try std.testing.expectEqualStrings("gpt-5.6-sol", agent.model.name);
}

test "every step reports a row that its list does not hold" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(
        .{ .anthropic = "sk-ant", .openai = "sk-openai" },
        .{ .anthropic = true },
    );
    var agent = testing.agent(gpa, .{ .anthropic_api = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    const vendors = try expectPick(try run(&context));
    defer freePick(gpa, &vendors);
    try Context.Outcome.expectNoticeContaining(
        try vendors.select(&context, 99),
        .failure,
        "valid provider",
    );

    const anthropic_accounts = try expectPick(try vendors.select(&context, 0));
    defer freePick(gpa, &anthropic_accounts);
    try Context.Outcome.expectNoticeContaining(
        try anthropic_accounts.select(&context, 99),
        .failure,
        "valid account",
    );

    const anthropic_models = try expectPick(try anthropic_accounts.select(&context, 1));
    defer freePick(gpa, &anthropic_models);
    try Context.Outcome.expectNoticeContaining(
        try anthropic_models.select(&context, 99),
        .failure,
        "valid model",
    );
    try std.testing.expectEqualStrings("claude-sonnet-4-6", agent.model.name);
}

test "no authenticated accounts reports an error instead of a picker" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{}, .{});
    var context: Context = .{
        .gpa = gpa,
        .io = undefined,
        .agent = undefined,
        .accounts = &accounts,
    };

    try Context.Outcome.expectNotice(try run(&context), .failure);
}

test "the active mark matches the account, not just the model name" {
    const gpa = std.testing.allocator;
    // Both Anthropic accounts are authenticated, so every model name appears
    // under two accounts. The mark must land inside the active account's list.
    var accounts = testing.accounts(.{ .anthropic = "sk-ant" }, .{ .anthropic = true });
    var agent = testing.agent(gpa, .{ .anthropic_subscription = undefined });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    const anthropic_accounts = try expectPick(try run(&context));
    defer freePick(gpa, &anthropic_accounts);
    try std.testing.expectEqualStrings(
        "Anthropic Subscription",
        anthropic_accounts.options[anthropic_accounts.current.?],
    );

    const subscription_models = try expectPick(try anthropic_accounts.select(&context, 0));
    defer freePick(gpa, &subscription_models);
    try std.testing.expectEqualStrings(
        "claude-sonnet-4-6",
        subscription_models.options[subscription_models.current.?],
    );

    // The same model name under the API account marks no row.
    const api_models = try expectPick(try anthropic_accounts.select(&context, 1));
    defer freePick(gpa, &api_models);
    try std.testing.expect(api_models.current == null);
}

fn runUnderOom(gpa: std.mem.Allocator) !void {
    var accounts = testing.accounts(
        .{ .anthropic = "sk-ant", .openai = "sk-openai" },
        .{ .anthropic = true },
    );
    var agent = testing.agent(gpa, .{ .anthropic_api = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    const vendors = try expectPick(try run(&context));
    defer freePick(gpa, &vendors);
    const anthropic_accounts = try expectPick(try vendors.select(&context, 0));
    defer freePick(gpa, &anthropic_accounts);
    const anthropic_models = try expectPick(try anthropic_accounts.select(&context, 0));
    defer freePick(gpa, &anthropic_models);

    switch (try anthropic_models.select(&context, 0)) {
        .event => |event| gpa.free(event.content),
        else => return error.ExpectedEvent,
    }
}

test "a failed step build frees every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, runUnderOom, .{});
}
