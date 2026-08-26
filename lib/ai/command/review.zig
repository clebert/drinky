//! `/review`: the bounded review workflow over the pending changes, and the
//! setup pickers that choose the account, the model, and the effort level of
//! each role. The app owns the workflow, its state, and its persistence, so
//! every picker here reads and writes the setup that the context carries and
//! reports each result as a review action. The command takes no argument.
//!
//! The top setup holds the start row and one row per role. A role row opens
//! the role menu, whose rows open the account, model, and effort steps. Esc
//! returns one menu level through the reopen trail, and the top setup cancels.
//! A model or effort selection confirms the choice, so the app persists it and
//! rebuilds the top setup with the new value on its row.

const std = @import("std");

const llm = @import("../llm.zig");
const models = @import("../models.zig");
const Accounts = @import("../Accounts.zig");
const Context = @import("Context.zig");
const testing = @import("testing.zig");

pub const name = "review";
pub const summary = "review the pending changes in rounds";

/// Every step belongs to one `/review` setup, so all of them report one
/// cancellation.
const cancellation_message = "You canceled the review setup.";

const roles = std.enums.values(Context.ReviewSetup.Role);

pub fn run(context: *Context) !Context.Outcome {
    _ = context;
    return .{ .review = .setup };
}

/// The name of a role on a setup row.
fn roleLabel(role: Context.ReviewSetup.Role) []const u8 {
    return switch (role) {
        .reviewer => "Reviewer",
        .judge => "Judge",
        .fixer => "Fixer",
    };
}

/// The top setup: the start row, then one row per role with its whole choice.
pub fn setup(context: *Context) anyerror!Context.Outcome {
    const state = context.review_setup orelse return hostless(context);
    var options: Context.Outcome.Options = .{ .gpa = context.gpa };
    errdefer options.deinit();
    try options.print("Start review", .{});
    for (roles) |role| {
        const choice = state.choices.get(role);
        try options.print("{s}: {s} ({s}) · {s}", .{
            roleLabel(role),
            choice.model.name,
            choice.account.label(),
            @tagName(choice.effort),
        });
    }
    return .{ .pick = .{
        .select = selectSetup,
        .title = "Select a review setup",
        .cancellation_message = cancellation_message,
        .options = try options.toOwnedSlice(),
        .current = null,
        .reopen = setup,
    } };
}

fn selectSetup(context: *Context, index: usize) anyerror!Context.Outcome {
    const state = context.review_setup orelse return hostless(context);
    if (index == 0) return .{ .review = .start };
    if (index - 1 >= roles.len) return Context.Outcome.reportNotice(
        context.gpa,
        .failure,
        "Select a valid row.",
        .{},
    );
    state.role = roles[index - 1];
    return roleStep(context);
}

/// The menu of the open role: its model with its account, and its effort
/// level. The failure hold of the app opens this step directly for the failed
/// role, so it reads the role from the setup rather than from a row.
pub fn roleStep(context: *Context) anyerror!Context.Outcome {
    const state = context.review_setup orelse return hostless(context);
    const choice = state.choices.get(state.role);
    var options: Context.Outcome.Options = .{ .gpa = context.gpa };
    errdefer options.deinit();
    try options.print("Model: {s} ({s})", .{ choice.model.name, choice.account.label() });
    try options.print("Effort: {s}", .{@tagName(choice.effort)});
    return .{ .pick = .{
        .select = selectRole,
        .title = switch (state.role) {
            .reviewer => "Select the reviewer",
            .judge => "Select the judge",
            .fixer => "Select the fixer",
        },
        .cancellation_message = cancellation_message,
        .options = try options.toOwnedSlice(),
        .current = null,
        .reopen = roleStep,
    } };
}

fn selectRole(context: *Context, index: usize) anyerror!Context.Outcome {
    return switch (index) {
        0 => accountStep(context),
        1 => effortStep(context),
        else => Context.Outcome.reportNotice(context.gpa, .failure, "Select a valid row.", .{}),
    };
}

/// The account step: every authenticated account, across both providers,
/// because a role runs on its own account. One account alone answers the step,
/// so the flow opens its model list at once.
fn accountStep(context: *Context) anyerror!Context.Outcome {
    const state = context.review_setup orelse return hostless(context);
    var buffer: [std.enums.values(llm.Account).len]llm.Account = undefined;
    const list = authenticatedAccounts(context.accounts, &buffer);
    if (list.len == 0) return Context.Outcome.reportNotice(
        context.gpa,
        .failure,
        "Sign in to an account before you select a role model.",
        .{},
    );
    if (list.len == 1) return modelStep(context, list[0]);

    var options: Context.Outcome.Options = .{ .gpa = context.gpa };
    errdefer options.deinit();
    var current: ?usize = null;
    const choice = state.choices.get(state.role);
    for (list, 0..) |account, index| {
        try options.print("{s}", .{account.label()});
        if (account == choice.account) current = index;
    }
    return .{ .pick = .{
        .select = selectAccount,
        .title = "Account",
        .cancellation_message = cancellation_message,
        .options = try options.toOwnedSlice(),
        .current = current,
        .reopen = accountStep,
    } };
}

fn selectAccount(context: *Context, index: usize) anyerror!Context.Outcome {
    var buffer: [std.enums.values(llm.Account).len]llm.Account = undefined;
    const list = authenticatedAccounts(context.accounts, &buffer);
    if (index >= list.len) return Context.Outcome.reportNotice(
        context.gpa,
        .failure,
        "Select a valid account.",
        .{},
    );
    return modelStep(context, list[index]);
}

/// The model step of `account`. A selection confirms the account and the model
/// together, like `/model` does.
fn modelStep(context: *Context, account: llm.Account) anyerror!Context.Outcome {
    const state = context.review_setup orelse return hostless(context);
    const gpa = context.gpa;
    var list: std.ArrayList(models.Model) = .empty;
    defer list.deinit(gpa);
    try context.accounts.listModels(account, &list, gpa);

    var options: Context.Outcome.Options = .{ .gpa = gpa };
    errdefer options.deinit();
    var current: ?usize = null;
    const choice = state.choices.get(state.role);
    for (list.items, 0..) |model, index| {
        try options.print("{s}", .{model.name});
        if (account == choice.account and std.mem.eql(u8, model.name, choice.model.name))
            current = index;
    }
    const step = switch (account) {
        inline else => |tag| modelStepOf(tag),
    };
    return .{ .pick = .{
        .select = step.select,
        .title = step.title,
        .cancellation_message = cancellation_message,
        .options = try options.toOwnedSlice(),
        .current = current,
        .reopen = step.open,
    } };
}

/// The parts of the model step that name one account. A selector receives the
/// row index alone, so each account gets its own.
const ModelStep = struct {
    select: *const fn (*Context, usize) anyerror!Context.Outcome,
    open: Context.Outcome.Opener,
    title: []const u8,
};

fn modelStepOf(comptime account: llm.Account) ModelStep {
    return .{
        .select = struct {
            fn select(context: *Context, index: usize) anyerror!Context.Outcome {
                const state = context.review_setup orelse return hostless(context);
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
                var choice = state.choices.get(state.role);
                choice.account = account;
                choice.model = list.items[index];
                state.choices.set(state.role, choice);
                return .{ .review = .confirm };
            }
        }.select,
        .open = struct {
            fn open(context: *Context) anyerror!Context.Outcome {
                return modelStep(context, account);
            }
        }.open,
        .title = comptime "Model: " ++ account.label(),
    };
}

/// The effort step of the open role.
fn effortStep(context: *Context) anyerror!Context.Outcome {
    const state = context.review_setup orelse return hostless(context);
    var options: Context.Outcome.Options = .{ .gpa = context.gpa };
    errdefer options.deinit();
    var current: ?usize = null;
    const choice = state.choices.get(state.role);
    for (std.enums.values(llm.Effort), 0..) |level, index| {
        try options.print("{s}", .{@tagName(level)});
        if (level == choice.effort) current = index;
    }
    return .{ .pick = .{
        .select = selectEffort,
        .title = "Effort",
        .cancellation_message = cancellation_message,
        .options = try options.toOwnedSlice(),
        .current = current,
        .reopen = effortStep,
    } };
}

fn selectEffort(context: *Context, index: usize) anyerror!Context.Outcome {
    const state = context.review_setup orelse return hostless(context);
    const levels = std.enums.values(llm.Effort);
    if (index >= levels.len) return Context.Outcome.reportNotice(
        context.gpa,
        .failure,
        "Select a valid effort level.",
        .{},
    );
    var choice = state.choices.get(state.role);
    choice.effort = levels[index];
    state.choices.set(state.role, choice);
    return .{ .review = .confirm };
}

/// The authenticated accounts, in enum order. Every step re-derives its list
/// identically, so a row index stays stable.
fn authenticatedAccounts(registry: *const Accounts, out: []llm.Account) []llm.Account {
    var count: usize = 0;
    for (std.enums.values(llm.Account)) |account| {
        if (!registry.isAuthenticated(account)) continue;
        out[count] = account;
        count += 1;
    }
    return out[0..count];
}

/// The report for a context without a setup. The app hands one to every picker
/// it opens, so only a foreign dispatch reaches this.
fn hostless(context: *Context) !Context.Outcome {
    return Context.Outcome.reportNotice(
        context.gpa,
        .failure,
        "The review setup is not open.",
        .{},
    );
}

test "run requests the review setup" {
    var context: Context = .{
        .gpa = undefined,
        .io = undefined,
        .agent = undefined,
        .accounts = undefined,
    };
    try std.testing.expect((try run(&context)).review == .setup);
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

/// Test helper: a setup with every role on the Anthropic API account.
fn setupForTest() Context.ReviewSetup {
    return .{ .choices = .initFill(.{
        .account = .anthropic_api,
        .model = models.get(.anthropic, "claude-sonnet-4-6").?,
        .effort = .high,
    }) };
}

test "the top setup lists the start row and every role choice" {
    const gpa = std.testing.allocator;
    var state = setupForTest();
    var context: Context = .{
        .gpa = gpa,
        .io = undefined,
        .agent = undefined,
        .accounts = undefined,
        .review_setup = &state,
    };

    const pick = try expectPick(try setup(&context));
    defer freePick(gpa, &pick);
    try std.testing.expectEqualStrings("Select a review setup", pick.title);
    try std.testing.expect(pick.reopen.? == &setup);
    try std.testing.expectEqual(@as(usize, 4), pick.options.len);
    try std.testing.expectEqualStrings("Start review", pick.options[0]);
    try std.testing.expectEqualStrings(
        "Reviewer: claude-sonnet-4-6 (Anthropic API) · high",
        pick.options[1],
    );
    try std.testing.expectEqualStrings(
        "Fixer: claude-sonnet-4-6 (Anthropic API) · high",
        pick.options[3],
    );

    // The start row asks the app to start, and a row past the list reports.
    try std.testing.expect((try pick.select(&context, 0)).review == .start);
    try Context.Outcome.expectNoticeContaining(
        try pick.select(&context, 4),
        .failure,
        "valid row",
    );
}

test "a role row opens its menu, and the menus confirm a choice" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant", .openai = "sk-openai" }, .{});
    var state = setupForTest();
    var context: Context = .{
        .gpa = gpa,
        .io = undefined,
        .agent = undefined,
        .accounts = &accounts,
        .review_setup = &state,
    };

    const top = try expectPick(try setup(&context));
    defer freePick(gpa, &top);
    const judge_menu = try expectPick(try top.select(&context, 2));
    defer freePick(gpa, &judge_menu);
    try std.testing.expectEqualStrings("Select the judge", judge_menu.title);
    try std.testing.expect(judge_menu.reopen.? == &roleStep);
    try std.testing.expectEqualStrings(
        "Model: claude-sonnet-4-6 (Anthropic API)",
        judge_menu.options[0],
    );
    try std.testing.expectEqualStrings("Effort: high", judge_menu.options[1]);

    // The model row lists both authenticated accounts and tags the current one.
    const account_list = try expectPick(try judge_menu.select(&context, 0));
    defer freePick(gpa, &account_list);
    try std.testing.expectEqualStrings("Account", account_list.title);
    try std.testing.expectEqual(@as(usize, 2), account_list.options.len);
    try std.testing.expectEqualStrings(
        "Anthropic API",
        account_list.options[account_list.current.?],
    );

    // A model pick confirms the account and the model together for the judge
    // alone.
    const model_list = try expectPick(try account_list.select(&context, 1));
    defer freePick(gpa, &model_list);
    try std.testing.expectEqualStrings("Model: OpenAI API", model_list.title);
    try std.testing.expect(model_list.current == null);
    try std.testing.expect((try model_list.select(&context, 0)).review == .confirm);
    const judge = state.choices.get(.judge);
    try std.testing.expectEqual(llm.Account.openai_api, judge.account);
    try std.testing.expectEqualStrings("gpt-5.6-sol", judge.model.name);
    const reviewer = state.choices.get(.reviewer);
    try std.testing.expectEqual(llm.Account.anthropic_api, reviewer.account);

    // The effort row confirms its level the same way.
    const effort_list = try expectPick(try judge_menu.select(&context, 1));
    defer freePick(gpa, &effort_list);
    try std.testing.expectEqualStrings("high", effort_list.options[effort_list.current.?]);
    try std.testing.expect((try effort_list.select(&context, 4)).review == .confirm);
    try std.testing.expectEqual(llm.Effort.xhigh, state.choices.get(.judge).effort);
}

test "one authenticated account skips the account step" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant" }, .{});
    var state = setupForTest();
    var context: Context = .{
        .gpa = gpa,
        .io = undefined,
        .agent = undefined,
        .accounts = &accounts,
        .review_setup = &state,
    };

    const menu = try expectPick(try roleStep(&context));
    defer freePick(gpa, &menu);
    const model_list = try expectPick(try menu.select(&context, 0));
    defer freePick(gpa, &model_list);
    try std.testing.expectEqualStrings("Model: Anthropic API", model_list.title);
    try std.testing.expectEqualStrings(
        "claude-sonnet-4-6",
        model_list.options[model_list.current.?],
    );
}

test "the setup steps refuse a context without a setup and an empty registry" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{}, .{});
    var context: Context = .{
        .gpa = gpa,
        .io = undefined,
        .agent = undefined,
        .accounts = &accounts,
    };

    try Context.Outcome.expectNoticeContaining(try setup(&context), .failure, "not open");
    try Context.Outcome.expectNoticeContaining(try roleStep(&context), .failure, "not open");

    // With a setup but no authenticated account, the model row names the way
    // forward instead of an empty list.
    var state = setupForTest();
    context.review_setup = &state;
    try Context.Outcome.expectNoticeContaining(
        try accountStep(&context),
        .failure,
        "Sign in to an account",
    );
}
