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
const Model = @import("../Model.zig");
const Accounts = @import("../Accounts.zig");
const Context = @import("Context.zig");
const effort = @import("effort.zig");
const model_command = @import("model.zig");
const model_testing = @import("../testing.zig");
const testing = @import("testing.zig");

pub const name = "review";
pub const summary = "review the pending changes in rounds";

/// Every step belongs to one `/review` setup, so all of them report one
/// cancellation.
const cancellation_message = "You canceled the review setup.";

/// The model slot of a role whose stored choice no longer resolves.
const no_model_label = "No model";

const roles = std.enums.values(Context.ReviewSetup.Role);

pub fn run(context: *Context) !Context.Outcome {
    _ = context;
    return .{ .review = .setup };
}

/// The name of a role on a setup row. Every Drinky sentence that names a role
/// of the setup reads it from here, so one concept keeps one noun. The app
/// states its own start failures with it too.
pub fn roleLabel(role: Context.ReviewSetup.Role) []const u8 {
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
            if (choice.model) |model| model.name() else no_model_label,
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
    if (index == 0) {
        // A role without a model runs nothing, and Drinky picks no replacement
        // for the choice of the user, so the start waits for that row.
        for (roles) |role| {
            if (state.choices.get(role).model != null) continue;
            return Context.Outcome.reportNotice(
                context.gpa,
                .failure,
                "The {s} row names no model. Select one before you start the review.",
                .{roleLabel(role)},
            );
        }
        return .{ .review = .start };
    }
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
    try options.print("Model: {s} ({s})", .{
        if (choice.model) |model| model.name() else no_model_label,
        choice.account.label(),
    });
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

/// The model step of `account`: the fetch row, then its models. A selection
/// confirms the account and the model together, like `/model` does. Drinky
/// compiles no model in, so an account that the user has not fetched yet holds
/// the fetch row alone.
fn modelStep(context: *Context, account: llm.Account) anyerror!Context.Outcome {
    const state = context.review_setup orelse return hostless(context);
    const gpa = context.gpa;
    var list: std.ArrayList(Model) = .empty;
    defer list.deinit(gpa);
    try context.accounts.listModels(account, &list, gpa);

    var options: Context.Outcome.Options = .{ .gpa = gpa };
    errdefer options.deinit();
    var current: ?usize = null;
    const choice = state.choices.get(state.role);
    // `/model` owns the first row and the model row, so both pickers label one
    // row alike and mark one fact alike.
    try options.print("{s}", .{model_command.firstRow(list.items.len)});
    for (list.items, 0..) |*model, index| {
        try model_command.row(&options, account, model);
        const chosen = if (choice.model) |chosen_model|
            model.sameName(chosen_model.name())
        else
            false;
        if (account == choice.account and chosen)
            current = index + 1;
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
                if (index == 0) return fetchStep(context, account);
                var list: std.ArrayList(Model) = .empty;
                defer list.deinit(gpa);
                try context.accounts.listModels(account, &list, gpa);
                if (index - 1 >= list.items.len) return Context.Outcome.reportNotice(
                    gpa,
                    .failure,
                    "Select a valid model.",
                    .{},
                );
                var choice = state.choices.get(state.role);
                choice.account = account;
                choice.model = list.items[index - 1];
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

/// Fetch the list of `account` and reopen its model step over the result. A
/// fetch has three exits. A failed account list reports itself and opens
/// nothing, so the user reads what went wrong before another try. That report
/// names a cache write that failed with it. A failed metadata request opens the
/// list and states itself beside it. A failed cache write does the same, because
/// that list arrived.
///
/// The requests block the thread that paints and reads the keys, so the
/// interface stops until they end. The wait line states that stop first.
fn fetchStep(context: *Context, account: llm.Account) anyerror!Context.Outcome {
    try context.stateFetchWait(account);
    const result = context.accounts.refresh(account);
    return fetchOutcome(context, account, &result);
}

/// The outcome of one fetch of `account` over `result`. It holds no request, so
/// a test reaches every exit without a socket.
fn fetchOutcome(
    context: *Context,
    account: llm.Account,
    result: *const Accounts.Refresh,
) anyerror!Context.Outcome {
    // `/model` owns the line that states a failed list, so both commands state
    // one failure alike.
    if (result.models_error) |err|
        return model_command.fetchFailure(context.gpa, account, err, result.metadata_save_error);
    var outcome = try modelStep(context, account);
    errdefer freePick(context.gpa, &outcome.pick);
    // `/model` owns the line that states the miss, so both commands state one
    // miss alike.
    outcome.pick.report = try model_command.fetchReport(context.gpa, account, result);
    return outcome;
}

/// The effort step of the open role: the whole ladder, the way `/effort` lists
/// it. The level states the intention of the user, so the step stands even
/// while the role names no model. The model of the role resolves that intention
/// silently on each request.
fn effortStep(context: *Context) anyerror!Context.Outcome {
    const state = context.review_setup orelse return hostless(context);
    const choice = state.choices.get(state.role);
    var options: Context.Outcome.Options = .{ .gpa = context.gpa };
    errdefer options.deinit();
    var current: ?usize = null;
    for (effort.ladder, 0..) |level, index| {
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
    var choice = state.choices.get(state.role);
    if (index >= effort.ladder.len) return Context.Outcome.reportNotice(
        context.gpa,
        .failure,
        "Select a valid effort level.",
        .{},
    );
    choice.effort = effort.ladder[index];
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

/// Free the rows of a picker that reaches no caller.
fn freePick(gpa: std.mem.Allocator, pick: *const Context.Outcome.Pick) void {
    for (pick.options) |option| gpa.free(option);
    gpa.free(pick.options);
}

/// Test helper: the picker of `outcome`, which the caller must free.
fn expectPick(outcome: Context.Outcome) !Context.Outcome.Pick {
    return switch (outcome) {
        .pick => |pick| pick,
        else => error.ExpectedPick,
    };
}

/// Test helper: a setup with every role on the Anthropic API account.
fn setupForTest() Context.ReviewSetup {
    return .{ .choices = .initFill(.{
        .account = .anthropic_api,
        .model = model_testing.model("claude-sonnet-4-6"),
        .effort = .high,
    }) };
}

// A cache write that failed costs this session no model, and a metadata request
// that failed costs it none either, so each states itself beside the list that
// arrived. A failed account list alone opens nothing. `/model` owns the line of
// a miss, and its own test states every word of that line.
test "a fetch opens the list that arrived and states what it missed" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .openai = "sk-openai" }, .{});
    defer testing.deinitAccounts(&accounts);
    try testing.seed(&accounts, .openai_api, &.{ "gpt-5.6-sol", "gpt-5.6-luna" });
    var state = setupForTest();
    var context: Context = .{
        .gpa = gpa,
        .io = undefined,
        .agent = undefined,
        .accounts = &accounts,
        .review_setup = &state,
    };

    // The account list never arrived, so no list can open.
    try Context.Outcome.expectEvent(
        try fetchOutcome(&context, .openai_api, &.{ .models_error = error.ConnectionRefused }),
        .failure,
    );

    // The metadata request runs even then, so its failed cache write states
    // itself in the same line, and that line is the one `/model` states.
    const failed = switch (try fetchOutcome(&context, .openai_api, &.{
        .models_error = error.ConnectionRefused,
        .metadata_save_error = error.StoreBusy,
    })) {
        .event => |event| event,
        else => return error.ExpectedEvent,
    };
    defer gpa.free(failed.content);
    const shared_failure = switch (try model_command.fetchFailure(
        gpa,
        .openai_api,
        error.ConnectionRefused,
        error.StoreBusy,
    )) {
        .event => |event| event,
        else => return error.ExpectedEvent,
    };
    defer gpa.free(shared_failure.content);
    try std.testing.expectEqualStrings(shared_failure.content, failed.content);
    try std.testing.expect(std.mem.indexOf(u8, failed.content, "StoreBusy") != null);

    // Every part arrived, so the list opens and states nothing beside itself.
    const complete = try expectPick(try fetchOutcome(&context, .openai_api, &.{ .count = 2 }));
    defer freePick(gpa, &complete);
    try std.testing.expect(complete.report == null);

    // The metadata never arrived, so the list opens beside that failure.
    const metadata_gone = try expectPick(try fetchOutcome(&context, .openai_api, &.{
        .count = 2,
        .metadata_error = error.ConnectionTimedOut,
    }));
    defer freePick(gpa, &metadata_gone);
    defer gpa.free(metadata_gone.report.?.content);
    try std.testing.expectEqual(@as(usize, 3), metadata_gone.options.len);
    try std.testing.expectEqualStrings("gpt-5.6-sol", metadata_gone.options[1]);
    try std.testing.expectEqual(
        Context.Outcome.Severity.failure,
        metadata_gone.report.?.severity,
    );
    // The line is the one `/model` states for the same result.
    const shared = (try model_command.fetchReport(gpa, .openai_api, &.{
        .count = 2,
        .metadata_error = error.ConnectionTimedOut,
    })).?;
    defer gpa.free(shared.content);
    try std.testing.expectEqualStrings(shared.content, metadata_gone.report.?.content);

    // The list write failed, so the list opens beside that failure too.
    const save_gone = try expectPick(try fetchOutcome(&context, .openai_api, &.{
        .count = 2,
        .models_save_error = error.StoreBusy,
    }));
    defer freePick(gpa, &save_gone);
    defer gpa.free(save_gone.report.?.content);
    try std.testing.expect(save_gone.report.?.content.len > 0);
}

// The role fetch takes the credential rule of `/model`, so a store that holds
// another principal stops it before its model request too. The app owns the
// transition, so the outcome names the account.
test "a role fetch that meets a replaced credential hands its account to the app" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{}, .{ .openai = true });
    defer testing.deinitAccounts(&accounts);
    var state = setupForTest();
    var context: Context = .{
        .gpa = gpa,
        .io = undefined,
        .agent = undefined,
        .accounts = &accounts,
        .review_setup = &state,
    };

    const outcome = try fetchOutcome(&context, .openai_subscription, &.{
        .models_error = error.CredentialReplaced,
    });
    try std.testing.expectEqual(
        llm.Account.openai_subscription,
        outcome.credential_replaced,
    );
}

// The model rows of a role read like the rows of `/model`, so a model whose
// output limit no source states carries the same mark here. `/model` owns that
// row, and its own test states every word of it.
test "a role model row marks an output limit that no source states" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant", .openai = "sk-openai" }, .{});
    defer testing.deinitAccounts(&accounts);
    try testing.seed(&accounts, .anthropic_api, &.{ "claude-fable-5", "claude-sonnet-4-6" });
    try testing.seed(&accounts, .openai_api, &.{"gpt-5.6-sol"});
    // No source states an output limit for these two models.
    accounts.catalog.accounts.get(.anthropic_api)[1].tokens_max = null;
    accounts.catalog.accounts.get(.openai_api)[0].tokens_max = null;
    var state = setupForTest();
    var context: Context = .{
        .gpa = gpa,
        .io = undefined,
        .agent = undefined,
        .accounts = &accounts,
        .review_setup = &state,
    };

    const anthropic_models = try expectPick(try modelStep(&context, .anthropic_api));
    defer freePick(gpa, &anthropic_models);
    try std.testing.expectEqualStrings("claude-fable-5", anthropic_models.options[1]);
    try std.testing.expectEqualStrings(
        "claude-sonnet-4-6 · Output limit unknown",
        anthropic_models.options[2],
    );

    // OpenAI takes no output limit from the request, so its rows stand as they
    // are.
    const openai_models = try expectPick(try modelStep(&context, .openai_api));
    defer freePick(gpa, &openai_models);
    try std.testing.expectEqualStrings("gpt-5.6-sol", openai_models.options[1]);
}

// A role that names no model runs nothing, and Drinky substitutes no model for
// the choice of the user, so the start waits for that row.
test "the start row refuses while a role names no model" {
    const gpa = std.testing.allocator;
    var state = setupForTest();
    var choice = state.choices.get(.judge);
    choice.model = null;
    state.choices.set(.judge, choice);
    var context: Context = .{
        .gpa = gpa,
        .io = undefined,
        .agent = undefined,
        .accounts = undefined,
        .review_setup = &state,
    };

    const pick = try expectPick(try setup(&context));
    defer freePick(gpa, &pick);
    // The row names the gap in place of a model name.
    try std.testing.expect(std.mem.indexOf(u8, pick.options[2], "No model") != null);
    try Context.Outcome.expectNoticeContaining(
        try pick.select(&context, 0),
        .failure,
        "Judge row names no model",
    );

    // Every role that names a model starts as before.
    choice.model = model_testing.model("claude-sonnet-4-6");
    state.choices.set(.judge, choice);
    try std.testing.expect((try pick.select(&context, 0)).review == .start);
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
    defer testing.deinitAccounts(&accounts);
    try testing.seed(&accounts, .anthropic_api, &.{"claude-sonnet-4-6"});
    try testing.seed(&accounts, .openai_api, &.{"gpt-5.6-sol"});
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
    // Row 0 fetches over the network, so the model rows start at row 1.
    try std.testing.expect((try model_list.select(&context, 1)).review == .confirm);
    const judge = state.choices.get(.judge);
    try std.testing.expectEqual(llm.Account.openai_api, judge.account);
    try std.testing.expectEqualStrings("gpt-5.6-sol", judge.model.?.name());
    const reviewer = state.choices.get(.reviewer);
    try std.testing.expectEqual(llm.Account.anthropic_api, reviewer.account);

    // The effort row confirms its level the same way. The rows are the ladder,
    // so row 5 is xhigh.
    const effort_list = try expectPick(try judge_menu.select(&context, 1));
    defer freePick(gpa, &effort_list);
    try std.testing.expectEqualStrings("high", effort_list.options[effort_list.current.?]);
    try std.testing.expect((try effort_list.select(&context, 5)).review == .confirm);
    try std.testing.expectEqual(llm.Effort.xhigh, state.choices.get(.judge).effort);
}

test "one authenticated account skips the account step" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant" }, .{});
    defer testing.deinitAccounts(&accounts);
    try testing.seed(&accounts, .anthropic_api, &.{"claude-sonnet-4-6"});
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

// A role can name an account that no fetch ran for. The step must offer the
// fetch row there, like `/model` does, or the setup holds the start with no way
// to a model.
test "the role model step offers the fetch row of an unfetched account" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant", .openai = "sk-openai" }, .{});
    defer testing.deinitAccounts(&accounts);
    try testing.seed(&accounts, .anthropic_api, &.{"claude-sonnet-4-6"});
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
    const account_list = try expectPick(try menu.select(&context, 0));
    defer freePick(gpa, &account_list);

    // No fetch ran for the OpenAI API account, so its step holds the fetch row
    // alone and the user reaches a model from there.
    const openai_models = try expectPick(try account_list.select(&context, 1));
    defer freePick(gpa, &openai_models);
    try std.testing.expectEqualStrings("Model: OpenAI API", openai_models.title);
    try std.testing.expectEqual(@as(usize, 1), openai_models.options.len);
    try std.testing.expectEqualStrings("Fetch the model list", openai_models.options[0]);
    try std.testing.expect(openai_models.current == null);

    // A fetched account leads its models with the refresh row, so the row index
    // of a model matches the one `/model` uses.
    const anthropic_models = try expectPick(try account_list.select(&context, 0));
    defer freePick(gpa, &anthropic_models);
    try std.testing.expectEqual(@as(usize, 2), anthropic_models.options.len);
    try std.testing.expectEqualStrings("Refresh the model list", anthropic_models.options[0]);
    try std.testing.expectEqualStrings(
        "claude-sonnet-4-6",
        anthropic_models.options[anthropic_models.current.?],
    );
    try std.testing.expect((try anthropic_models.select(&context, 1)).review == .confirm);
    try std.testing.expectEqualStrings(
        "claude-sonnet-4-6",
        state.choices.get(.reviewer).model.?.name(),
    );
    try Context.Outcome.expectNoticeContaining(
        try anthropic_models.select(&context, 2),
        .failure,
        "valid model",
    );
}

// The level of a role states the intention of the user, so the role step lists
// the whole ladder, exactly as `/effort` does.
test "the role effort step lists every level" {
    const gpa = std.testing.allocator;
    var state = setupForTest();
    var context: Context = .{
        .gpa = gpa,
        .io = undefined,
        .agent = undefined,
        .accounts = undefined,
        .review_setup = &state,
    };

    const levels = try expectPick(try effortStep(&context));
    defer freePick(gpa, &levels);
    try std.testing.expectEqual(effort.ladder.len, levels.options.len);
    try std.testing.expectEqualStrings("none", levels.options[0]);
    try std.testing.expectEqualStrings("minimal", levels.options[1]);
    try std.testing.expectEqualStrings("ultra", levels.options[effort.ladder.len - 1]);
    try std.testing.expectEqualStrings("high", levels.options[levels.current.?]);

    // The rows are the ladder, so row 6 is max.
    try std.testing.expect((try levels.select(&context, 6)).review == .confirm);
    try std.testing.expectEqual(llm.Effort.max, state.choices.get(.reviewer).effort);
    try Context.Outcome.expectNoticeContaining(
        try levels.select(&context, effort.ladder.len),
        .failure,
        "valid effort level",
    );
}

// A model that names fewer levels narrows no row. It resolves the level of the
// role on each request instead.
test "the role effort step keeps every level for a model that names fewer" {
    const gpa = std.testing.allocator;
    var state = setupForTest();
    var choice = state.choices.get(.reviewer);
    var model = model_testing.model("mandatory");
    model.efforts = .initEmpty();
    model.addEffort(.low);
    model.addEffort(.max);
    model.thinking = .mandatory;
    choice.model = model;
    state.choices.set(.reviewer, choice);
    var context: Context = .{
        .gpa = gpa,
        .io = undefined,
        .agent = undefined,
        .accounts = undefined,
        .review_setup = &state,
    };

    const levels = try expectPick(try effortStep(&context));
    defer freePick(gpa, &levels);
    try std.testing.expectEqual(effort.ladder.len, levels.options.len);

    // Row 7 is ultra, which this model resolves down to the max it names.
    try std.testing.expect((try levels.select(&context, 7)).review == .confirm);
    const picked = state.choices.get(.reviewer);
    try std.testing.expectEqual(llm.Effort.ultra, picked.effort);
    try std.testing.expectEqual(llm.Effort.max, picked.model.?.reasoning(picked.effort).named);
}

// The review setup allows a role that names no model, and the level holds
// without one, so the step lists the ladder there too.
test "the role effort step stands while the role names no model" {
    const gpa = std.testing.allocator;
    var state = setupForTest();
    var choice = state.choices.get(.reviewer);
    choice.model = null;
    state.choices.set(.reviewer, choice);
    var context: Context = .{
        .gpa = gpa,
        .io = undefined,
        .agent = undefined,
        .accounts = undefined,
        .review_setup = &state,
    };

    const levels = try expectPick(try effortStep(&context));
    defer freePick(gpa, &levels);
    try std.testing.expectEqual(effort.ladder.len, levels.options.len);
    try std.testing.expect((try levels.select(&context, 2)).review == .confirm);
    try std.testing.expectEqual(llm.Effort.low, state.choices.get(.reviewer).effort);
    try Context.Outcome.expectNoticeContaining(
        try selectEffort(&context, effort.ladder.len),
        .failure,
        "valid effort level",
    );
}

test "the setup steps refuse a context without a setup and an empty registry" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{}, .{});
    defer testing.deinitAccounts(&accounts);
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
