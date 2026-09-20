const std = @import("std");

const Accounts = @import("../Accounts.zig");
const format = @import("../format.zig");
const llm = @import("../llm.zig");
const Metadata = @import("../Metadata.zig");
const Model = @import("../Model.zig");
const Context = @import("Context.zig");
const testing = @import("testing.zig");

pub const name = "model";
pub const summary = "Switch the model";

const cancellation_message = "You canceled the model selection.";

const fetch_row = "Fetch the model list";
const refresh_row = "Refresh the model list";
const lead_rows = 1;

const extra_output_limit = "The output limit is unknown.";

const extra_engine = "Weights: {s}";

const Selector = *const fn (*Context, Context.Outcome.Pick.Selection) anyerror!Context.Outcome;

const ModelStep = struct {
    select: Selector,
    open: Context.Outcome.Opener,
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
    if (vendors.len == 1) return accountStep(context, vendors[0]);

    var options: Context.Outcome.Options = .{ .gpa = context.gpa };
    errdefer options.deinit();
    var current: ?usize = null;
    const active_account = activeAccount(context);
    for (vendors, 0..) |vendor, index| {
        try options.print("{s}", .{@tagName(vendor)});
        if (active_account) |account| {
            if (account.provider() == vendor) current = index;
        }
    }
    return .{ .pick = .{
        .select = selectProvider,
        .title = "Provider",
        .cancellation_message = cancellation_message,
        .options = try options.toOwnedSlice(),
        .current = current,
        .reopen = run,
    } };
}

fn selectProvider(
    context: *Context,
    selection: Context.Outcome.Pick.Selection,
) anyerror!Context.Outcome {
    const index = selection.row;
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

fn accountStep(context: *Context, vendor: llm.Provider) !Context.Outcome {
    var buffer: [std.enums.values(llm.Account).len]llm.Account = undefined;
    const list = authenticatedAccounts(context.accounts, vendor, &buffer);
    std.debug.assert(list.len > 0);
    if (list.len == 1) return forAccount(context, list[0]);

    var options: Context.Outcome.Options = .{ .gpa = context.gpa };
    errdefer options.deinit();
    var current: ?usize = null;
    const active_account = activeAccount(context);
    for (list, 0..) |account, index| {
        try options.print("{s}", .{account.id()});
        if (active_account) |active| {
            if (active == account) current = index;
        }
    }
    return .{ .pick = .{
        .select = switch (vendor) {
            inline else => |tag| selectAccountOf(tag),
        },
        .title = "Account",
        .cancellation_message = cancellation_message,
        .options = try options.toOwnedSlice(),
        .current = current,
        .reopen = switch (vendor) {
            inline else => |tag| accountStepOf(tag),
        },
    } };
}

fn accountStepOf(comptime vendor: llm.Provider) Context.Outcome.Opener {
    return struct {
        fn open(context: *Context) anyerror!Context.Outcome {
            return accountStep(context, vendor);
        }
    }.open;
}

fn selectAccountOf(comptime vendor: llm.Provider) Selector {
    return struct {
        fn select(
            context: *Context,
            selection: Context.Outcome.Pick.Selection,
        ) anyerror!Context.Outcome {
            const index = selection.row;
            var buffer: [std.enums.values(llm.Account).len]llm.Account = undefined;
            const list = authenticatedAccounts(context.accounts, vendor, &buffer);
            if (index >= list.len) return Context.Outcome.reportNotice(
                context.gpa,
                .failure,
                "Select a valid account.",
                .{},
            );
            return forAccount(context, list[index]);
        }
    }.select;
}

pub fn forAccount(context: *Context, account: llm.Account) !Context.Outcome {
    if (account.provider() == .openrouter) return authorStep(context, account);
    return modelStep(context, account);
}

const AuthorRow = struct {
    name: []const u8,
    count: usize,
    first: usize,
};

fn authorStep(context: *Context, account: llm.Account) !Context.Outcome {
    const gpa = context.gpa;
    const preferred_model = rememberedModel(context, account);
    var list: std.ArrayList(Model) = .empty;
    defer list.deinit(gpa);
    try context.accounts.listModels(account, &list, gpa);

    const authors = try gpa.alloc(AuthorRow, @max(list.items.len, 1));
    defer gpa.free(authors);
    const grouped = authorsOf(list.items, authors);

    var options: Context.Outcome.Options = .{ .gpa = gpa };
    errdefer options.deinit();
    var current: ?usize = null;
    var preselected: ?usize = null;
    try options.print("{s}", .{firstRow(list.items.len)});
    for (grouped, 0..) |author, index| {
        try options.addExtra(false, author.name, "{d} model{s}", .{
            author.count,
            format.pluralSuffix(author.count),
        });
        if (isActiveAuthor(context, account, list.items, author)) current = index + lead_rows;
        if (isPreferredAuthor(preferred_model, author.name)) preselected = index + lead_rows;
    }
    const step: ModelStep = switch (account) {
        inline else => |tag| authorStepOf(tag),
    };
    return .{ .pick = .{
        .select = step.select,
        .title = step.title,
        .cancellation_message = cancellation_message,
        .options = try options.toOwnedSlice(),
        .current = current,
        .preselected = preselected,
        .reopen = step.open,
    } };
}

fn authorKey(author_name: []const u8) usize {
    return @truncate(std.hash.Wyhash.hash(0, author_name));
}

fn authorModelIndex(
    grouped: []const AuthorRow,
    selection: Context.Outcome.Pick.Selection,
) ?usize {
    var found: ?AuthorRow = null;
    for (grouped) |author| {
        if (authorKey(author.name) != selection.payload) continue;
        if (found != null) return null;
        found = author;
    }
    const author = found orelse return null;
    if (selection.row >= author.count) return null;
    return author.first + selection.row;
}

fn authorsOf(models: []const Model, out: []AuthorRow) []AuthorRow {
    var count: usize = 0;
    var index: usize = 0;
    while (index < models.len) {
        const author_name = Metadata.authorOf(models[index].name());
        var length: usize = 1;
        while (index + length < models.len and
            std.mem.eql(u8, Metadata.authorOf(models[index + length].name()), author_name))
            length += 1;
        out[count] = .{ .name = author_name, .count = length, .first = index };
        count += 1;
        index += length;
    }
    return out[0..count];
}

fn isActiveAuthor(
    context: *const Context,
    account: llm.Account,
    models: []const Model,
    author: AuthorRow,
) bool {
    const active_account = activeAccount(context) orelse return false;
    const model = context.agent.model orelse return false;
    if (active_account != account) return false;
    const end = author.first + author.count;
    for (models[author.first..end]) |*item| {
        if (item.sameName(model.name())) return true;
    }
    return false;
}

fn isPreferredAuthor(preferred_model: ?*const Model, author_name: []const u8) bool {
    const model = preferred_model orelse return false;
    return std.mem.eql(u8, Metadata.authorOf(model.name()), author_name);
}

fn authorStepOf(comptime account: llm.Account) ModelStep {
    return .{
        .select = struct {
            fn select(
                context: *Context,
                selection: Context.Outcome.Pick.Selection,
            ) anyerror!Context.Outcome {
                const gpa = context.gpa;
                if (selection.row < lead_rows) return .{ .fetch = account };
                var list: std.ArrayList(Model) = .empty;
                defer list.deinit(gpa);
                try context.accounts.listModels(account, &list, gpa);
                const authors = try gpa.alloc(AuthorRow, @max(list.items.len, 1));
                defer gpa.free(authors);
                const grouped = authorsOf(list.items, authors);
                if (selection.row - lead_rows >= grouped.len) return Context.Outcome.reportNotice(
                    gpa,
                    .failure,
                    "Select a valid author.",
                    .{},
                );
                return authorModelsStep(context, account, grouped[selection.row - lead_rows].first);
            }
        }.select,
        .open = struct {
            fn open(context: *Context) anyerror!Context.Outcome {
                return authorStep(context, account);
            }
        }.open,
        .title = comptime "Author: " ++ account.id(),
    };
}

fn authorModelsStep(context: *Context, account: llm.Account, first: usize) !Context.Outcome {
    const gpa = context.gpa;
    const preferred_model = rememberedModel(context, account);
    var list: std.ArrayList(Model) = .empty;
    defer list.deinit(gpa);
    try context.accounts.listModels(account, &list, gpa);
    if (first >= list.items.len) return Context.Outcome.reportNotice(
        gpa,
        .failure,
        "Select a valid author.",
        .{},
    );
    const author_name = Metadata.authorOf(list.items[first].name());
    var options: Context.Outcome.Options = .{ .gpa = gpa };
    errdefer options.deinit();
    var current: ?usize = null;
    var preselected: ?usize = null;
    for (list.items[first..], 0..) |*model, index| {
        if (!std.mem.eql(u8, Metadata.authorOf(model.name()), author_name)) break;
        try row(&options, account, model);
        if (isActive(context, account, model.name())) current = index;
        if (isPreferred(preferred_model, model)) preselected = index;
    }
    const step: ModelStep = switch (account) {
        inline else => |tag| authorModelsOf(tag),
    };
    return .{ .pick = .{
        .select = step.select,
        .title = step.title,
        .cancellation_message = cancellation_message,
        .options = try options.toOwnedSlice(),
        .current = current,
        .preselected = preselected,
        .payload = authorKey(author_name),
        .reopen = step.open,
    } };
}

fn authorModelsOf(comptime account: llm.Account) ModelStep {
    return .{
        .select = struct {
            fn select(
                context: *Context,
                selection: Context.Outcome.Pick.Selection,
            ) anyerror!Context.Outcome {
                const gpa = context.gpa;
                var list: std.ArrayList(Model) = .empty;
                defer list.deinit(gpa);
                try context.accounts.listModels(account, &list, gpa);
                const authors = try gpa.alloc(AuthorRow, @max(list.items.len, 1));
                defer gpa.free(authors);
                const index = authorModelIndex(authorsOf(list.items, authors), selection) orelse
                    return Context.Outcome.reportNotice(
                        gpa,
                        .failure,
                        "Select a valid model.",
                        .{},
                    );
                return apply(context, account, &list.items[index]);
            }
        }.select,
        .open = struct {
            fn open(context: *Context) anyerror!Context.Outcome {
                return authorStep(context, account);
            }
        }.open,
        .title = comptime "Model: " ++ account.id(),
    };
}

fn modelStep(context: *Context, account: llm.Account) !Context.Outcome {
    const gpa = context.gpa;
    const preferred_model = rememberedModel(context, account);
    var list: std.ArrayList(Model) = .empty;
    defer list.deinit(gpa);
    try context.accounts.listModels(account, &list, gpa);

    var options: Context.Outcome.Options = .{ .gpa = gpa };
    errdefer options.deinit();
    var current: ?usize = null;
    var preselected: ?usize = null;
    try options.print("{s}", .{firstRow(list.items.len)});
    for (list.items, 0..) |*model, index| {
        try row(&options, account, model);
        if (isActive(context, account, model.name())) current = index + lead_rows;
        if (isPreferred(preferred_model, model)) preselected = index + lead_rows;
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
        .preselected = preselected,
        .reopen = step.open,
    } };
}

fn firstRow(count: usize) []const u8 {
    return if (count == 0) fetch_row else refresh_row;
}

fn row(
    options: *Context.Outcome.Options,
    account: llm.Account,
    model: *const Model,
) !void {
    if (model.outputLimitUnknown(account))
        return options.addExtra(true, model.name(), extra_output_limit, .{});
    if (model.engineName().len != 0)
        return options.addExtra(false, model.name(), extra_engine, .{model.engineName()});
    return options.print("{s}", .{model.name()});
}

fn modelStepOf(comptime account: llm.Account) ModelStep {
    return .{
        .select = struct {
            fn select(
                context: *Context,
                selection: Context.Outcome.Pick.Selection,
            ) anyerror!Context.Outcome {
                const gpa = context.gpa;
                const index = selection.row;
                if (index < lead_rows) return .{ .fetch = account };
                var list: std.ArrayList(Model) = .empty;
                defer list.deinit(gpa);
                try context.accounts.listModels(account, &list, gpa);
                if (index - lead_rows >= list.items.len) return Context.Outcome.reportNotice(
                    gpa,
                    .failure,
                    "Select a valid model.",
                    .{},
                );
                return apply(context, account, &list.items[index - lead_rows]);
            }
        }.select,
        .open = struct {
            fn open(context: *Context) anyerror!Context.Outcome {
                return modelStep(context, account);
            }
        }.open,
        .title = comptime "Model: " ++ account.id(),
    };
}

fn apply(context: *Context, account: llm.Account, model: *const Model) !Context.Outcome {
    const gpa = context.gpa;
    if (isCurrent(context, account, model)) return Context.Outcome.reportNotice(
        gpa,
        .information,
        "Drinky already uses {s}/{s}.",
        .{ account.id(), model.name() },
    );
    context.agent.switchTo(context.accounts.client(account).?, model.*);
    return Context.Outcome.reportEvent(
        gpa,
        .information,
        "Drinky now uses {s}/{s}.",
        .{ account.id(), model.name() },
    );
}

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

fn activeAccount(context: *const Context) ?llm.Account {
    const client = context.agent.client orelse return null;
    return client.account();
}

fn isActive(context: *const Context, account: llm.Account, model_name: []const u8) bool {
    const active_account = activeAccount(context) orelse return false;
    const model = context.agent.model orelse return false;
    return active_account == account and model.sameName(model_name);
}

fn rememberedModel(context: *const Context, account: llm.Account) ?*const Model {
    const remembered_models = context.remembered_models orelse return null;
    const maybe_model = remembered_models.getPtrConst(account);
    return if (maybe_model.*) |*model| model else null;
}

fn isPreferred(preferred_model: ?*const Model, model: *const Model) bool {
    const preferred = preferred_model orelse return false;
    return model.sameName(preferred.name());
}

fn isCurrent(context: *const Context, account: llm.Account, model: *const Model) bool {
    const active_account = activeAccount(context) orelse return false;
    const active = context.agent.model orelse return false;
    return active_account == account and active.eql(model);
}

pub fn fetchOutcome(
    context: *Context,
    account: llm.Account,
    result: *const Accounts.Refresh,
) !Context.Outcome {
    if (result.models_error) |err|
        return fetchFailure(context.gpa, account, err, result.metadata_save_error);
    var outcome = try forAccount(context, account);
    errdefer freePick(context.gpa, &outcome.pick);
    outcome.pick.report = try fetchReport(context.gpa, account, result);
    return outcome;
}

fn fetchFailure(
    gpa: std.mem.Allocator,
    account: llm.Account,
    models_failure: anyerror,
    metadata_save_failure: ?anyerror,
) !Context.Outcome {
    const cache_failure = metadata_save_failure orelse return Context.Outcome.reportEvent(
        gpa,
        .failure,
        "Drinky could not fetch the model list of {s} because of error {t}.",
        .{ account.id(), models_failure },
    );
    return Context.Outcome.reportEvent(
        gpa,
        .failure,
        "Drinky could not fetch the model list of {s} because of error {t}. Drinky could not " ++
            "save the public metadata because of error {t}. The metadata serves this session.",
        .{ account.id(), models_failure, cache_failure },
    );
}

const metadata_gone_head = "Drinky fetched the model list of {s}. Drinky could not fetch the " ++
    "public metadata because of error {t}.";

fn emptyNote(count: usize) []const u8 {
    return if (count == 0) " The account offers no model now." else "";
}

fn fetchReport(
    gpa: std.mem.Allocator,
    account: llm.Account,
    result: *const Accounts.Refresh,
) !?Context.Outcome.Message {
    const empty = emptyNote(result.count);
    if (result.metadata_error) |metadata_failure| {
        if (result.models_save_error) |save_failure| return try Context.Outcome.Message.print(
            gpa,
            .failure,
            metadata_gone_head ++ " Drinky could not save the model list because of error " ++
                "{t}. The list serves this session.{s}",
            .{ account.id(), metadata_failure, save_failure, empty },
        );
        if (result.count == 0) return try Context.Outcome.Message.print(
            gpa,
            .failure,
            metadata_gone_head ++ "{s}",
            .{ account.id(), metadata_failure, empty },
        );
        return try Context.Outcome.Message.print(
            gpa,
            .failure,
            metadata_gone_head ++ " The account offers {d} model{s} now.",
            .{
                account.id(),
                metadata_failure,
                result.count,
                format.pluralSuffix(result.count),
            },
        );
    }
    if (result.models_save_error) |list_failure| {
        if (result.metadata_save_error) |metadata_failure| return try Context.Outcome.Message.print(
            gpa,
            .failure,
            "Drinky fetched the model list of {s}. Drinky could not save the model list " ++
                "because of error {t}. Drinky could not save the public metadata because of " ++
                "error {t}. Both serve this session.{s}",
            .{ account.id(), list_failure, metadata_failure, empty },
        );
        return try Context.Outcome.Message.print(
            gpa,
            .failure,
            "Drinky fetched the model list of {s}. Drinky could not save the model list " ++
                "because of error {t}. The list serves this session.{s}",
            .{ account.id(), list_failure, empty },
        );
    }
    const metadata_failure = result.metadata_save_error orelse {
        if (result.count > 0) return null;
        return try Context.Outcome.Message.print(
            gpa,
            .warning,
            "Drinky fetched the model list of {s}. The account offers no model now.",
            .{account.id()},
        );
    };
    return try Context.Outcome.Message.print(
        gpa,
        .failure,
        "Drinky fetched the model list of {s}. Drinky could not save the public metadata " ++
            "because of error {t}. The metadata serves this session.{s}",
        .{ account.id(), metadata_failure, empty },
    );
}

fn freePick(gpa: std.mem.Allocator, pick: *const Context.Outcome.Pick) void {
    for (pick.options) |*option| option.deinit(gpa);
    gpa.free(pick.options);
}

fn expectPick(outcome: Context.Outcome) !Context.Outcome.Pick {
    return switch (outcome) {
        .pick => |pick| pick,
        else => error.ExpectedPick,
    };
}

fn selectRow(
    pick: *const Context.Outcome.Pick,
    context: *Context,
    index: usize,
) anyerror!Context.Outcome {
    return pick.select(context, .{ .payload = pick.payload, .row = index });
}

test "a fetch opens the list that arrived and states what it missed" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant" }, .{});
    defer testing.deinitAccounts(&accounts);
    try testing.seed(&accounts, .anthropic_api_key, &.{ "claude-fable-5", "claude-sonnet-4-6" });
    var agent = testing.agent(gpa, .{ .anthropic_api_key = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    try Context.Outcome.expectEvent(
        try fetchOutcome(
            &context,
            .anthropic_api_key,
            &.{ .models_error = error.ConnectionRefused },
        ),
        .failure,
    );

    const complete = try expectPick(
        try fetchOutcome(&context, .anthropic_api_key, &.{ .count = 2 }),
    );
    defer freePick(gpa, &complete);
    try std.testing.expect(complete.report == null);

    const metadata_gone = try expectPick(try fetchOutcome(&context, .anthropic_api_key, &.{
        .count = 2,
        .metadata_error = error.ConnectionTimedOut,
    }));
    defer freePick(gpa, &metadata_gone);
    defer gpa.free(metadata_gone.report.?.content);
    try std.testing.expectEqual(@as(usize, 3), metadata_gone.options.len);
    try std.testing.expectEqualStrings("claude-fable-5", metadata_gone.options[1].name);
    try std.testing.expectEqual(
        Context.Outcome.Severity.failure,
        metadata_gone.report.?.severity,
    );
    try std.testing.expectEqualStrings(
        "Drinky fetched the model list of anthropic-api-key. Drinky could not fetch the public " ++
            "metadata because of error ConnectionTimedOut. The account offers 2 models now.",
        metadata_gone.report.?.content,
    );

    const save_gone = try expectPick(try fetchOutcome(&context, .anthropic_api_key, &.{
        .count = 2,
        .models_save_error = error.StoreBusy,
    }));
    defer freePick(gpa, &save_gone);
    defer gpa.free(save_gone.report.?.content);
    try std.testing.expectEqualStrings(
        "Drinky fetched the model list of anthropic-api-key. Drinky could not save the model " ++
            "list because of error StoreBusy. The list serves this session.",
        save_gone.report.?.content,
    );

    const both_gone = try expectPick(try fetchOutcome(&context, .anthropic_api_key, &.{
        .count = 2,
        .metadata_error = error.ConnectionTimedOut,
        .models_save_error = error.StoreBusy,
    }));
    defer freePick(gpa, &both_gone);
    defer gpa.free(both_gone.report.?.content);
    try std.testing.expectEqualStrings(
        "Drinky fetched the model list of anthropic-api-key. Drinky could not fetch the public " ++
            "metadata because of error ConnectionTimedOut. Drinky could not save the model " ++
            "list because of error StoreBusy. The list serves this session.",
        both_gone.report.?.content,
    );
}

test "a failed fetch states the cache write that failed with it" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant" }, .{});
    defer testing.deinitAccounts(&accounts);
    var agent = testing.agent(gpa, .{ .anthropic_api_key = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    switch (try fetchOutcome(&context, .anthropic_api_key, &.{
        .models_error = error.ConnectionRefused,
        .metadata_save_error = error.StoreBusy,
    })) {
        .event => |event| {
            defer gpa.free(event.content);
            try std.testing.expectEqual(Context.Outcome.Severity.failure, event.severity);
            try std.testing.expectEqualStrings(
                "Drinky could not fetch the model list of anthropic-api-key because of error " ++
                    "ConnectionRefused. Drinky could not save the public metadata because of " ++
                    "error StoreBusy. The metadata serves this session.",
                event.content,
            );
        },
        else => return error.ExpectedEvent,
    }
}

test "the first step lists the providers with an authenticated account" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant", .openai = "sk-openai" }, .{});
    defer testing.deinitAccounts(&accounts);
    var agent = testing.agent(gpa, .{ .anthropic_api_key = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    const pick = try expectPick(try run(&context));
    defer freePick(gpa, &pick);
    try std.testing.expectEqualStrings("Provider", pick.title);
    try std.testing.expectEqual(@as(usize, 2), pick.options.len);
    try std.testing.expectEqualStrings("anthropic", pick.options[0].name);
    try std.testing.expectEqualStrings("openai", pick.options[1].name);
    try std.testing.expectEqual(@as(usize, 0), pick.current.?);
}

test "one provider alone opens the account step at once" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant" }, .{ .anthropic = true });
    defer testing.deinitAccounts(&accounts);
    var agent = testing.agent(gpa, .{ .anthropic_api_key = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    const pick = try expectPick(try run(&context));
    defer freePick(gpa, &pick);
    try std.testing.expectEqualStrings("Account", pick.title);
    try std.testing.expectEqual(@as(usize, 2), pick.options.len);
    try std.testing.expectEqualStrings("anthropic-plan", pick.options[0].name);
    try std.testing.expectEqualStrings("anthropic-api-key", pick.options[1].name);
    try std.testing.expectEqual(@as(usize, 1), pick.current.?);
}

test "one account alone opens the model step at once" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant" }, .{});
    defer testing.deinitAccounts(&accounts);
    try testing.seed(&accounts, .anthropic_api_key, &.{ "claude-fable-5", "claude-sonnet-4-6" });
    var agent = testing.agent(gpa, .{ .anthropic_api_key = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    const pick = try expectPick(try run(&context));
    defer freePick(gpa, &pick);
    try std.testing.expectEqualStrings("Model: anthropic-api-key", pick.title);
    try std.testing.expectEqual(@as(usize, 3), pick.options.len);
    try std.testing.expectEqualStrings("Refresh the model list", pick.options[0].name);
    try std.testing.expectEqualStrings("claude-fable-5", pick.options[1].name);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", pick.options[pick.current.?].name);
}

test "a model row marks an output limit that no source states" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant", .openai = "sk-openai" }, .{});
    defer testing.deinitAccounts(&accounts);
    try testing.seed(&accounts, .anthropic_api_key, &.{ "claude-fable-5", "claude-sonnet-4-6" });
    try testing.seed(&accounts, .openai_api_key, &.{"gpt-5.6-sol"});
    accounts.catalog.accounts.get(.anthropic_api_key)[1].tokens_max = null;
    accounts.catalog.accounts.get(.openai_api_key)[0].tokens_max = null;
    var agent = testing.agent(gpa, .{ .anthropic_api_key = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    const anthropic_models = try expectPick(try modelStep(&context, .anthropic_api_key));
    defer freePick(gpa, &anthropic_models);
    try std.testing.expectEqualStrings("claude-fable-5", anthropic_models.options[1].name);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", anthropic_models.options[2].name);
    try std.testing.expectEqualStrings(extra_output_limit, anthropic_models.options[2].extra.?);
    try std.testing.expect(anthropic_models.options[2].extra_pressure);

    const openai_models = try expectPick(try modelStep(&context, .openai_api_key));
    defer freePick(gpa, &openai_models);
    try std.testing.expectEqualStrings("gpt-5.6-sol", openai_models.options[1].name);
}

test "a DwarfStar model row names the engine behind the request id" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .ds4_base_url = "http://127.0.0.1:8000/v1" }, .{});
    defer testing.deinitAccounts(&accounts);
    try testing.seed(&accounts, .ds4, &.{ "deepseek-v4-flash", "deepseek-v4-pro" });
    try accounts.catalog.accounts.get(.ds4)[0].setEngine("DeepSeek V4 Flash");
    try accounts.catalog.accounts.get(.ds4)[1].setEngine("DeepSeek V4 Flash");
    var agent = testing.agent(gpa, .{ .ds4 = "http://127.0.0.1:8000/v1" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    const pick = try expectPick(try modelStep(&context, .ds4));
    defer freePick(gpa, &pick);
    try std.testing.expectEqualStrings("Refresh the model list", pick.options[0].name);
    try std.testing.expectEqualStrings("deepseek-v4-flash", pick.options[1].name);
    try std.testing.expectEqualStrings("Weights: DeepSeek V4 Flash", pick.options[1].extra.?);
    try std.testing.expect(!pick.options[1].extra_pressure);
    try std.testing.expectEqualStrings("deepseek-v4-pro", pick.options[2].name);
    try std.testing.expectEqualStrings("Weights: DeepSeek V4 Flash", pick.options[2].extra.?);
}

test "an account with no model offers the fetch row alone" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant" }, .{});
    defer testing.deinitAccounts(&accounts);
    var agent = testing.agent(gpa, .{ .anthropic_api_key = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    const pick = try expectPick(try run(&context));
    defer freePick(gpa, &pick);
    try std.testing.expectEqual(@as(usize, 1), pick.options.len);
    try std.testing.expectEqualStrings("Fetch the model list", pick.options[0].name);
    try std.testing.expect(pick.current == null);
}

test "an OpenRouter account opens the author step then the models of that author" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .openrouter = "sk-or" }, .{});
    defer testing.deinitAccounts(&accounts);
    var openai_new = Model.init("openai/gpt-new") catch unreachable;
    openai_new.context_window = 1;
    openai_new.tools = .supported;
    var openai_old = Model.init("openai/gpt-old") catch unreachable;
    openai_old.context_window = 1;
    openai_old.tools = .supported;
    var qwen = Model.init("qwen/qwen-new") catch unreachable;
    qwen.context_window = 1;
    qwen.tools = .supported;
    const entries = [_]Metadata.Entry{
        .{ .provider = .openrouter, .model = openai_new },
        .{ .provider = .openrouter, .model = openai_old },
        .{ .provider = .openrouter, .model = qwen },
    };
    const metadata = try gpa.dupe(Metadata.Entry, &entries);
    defer gpa.free(metadata);
    accounts.catalog.metadata = metadata;
    var agent = testing.agent(gpa, .{ .openrouter_api_key = "sk-or" });
    defer agent.deinit();
    var remembered_models = std.EnumArray(llm.Account, ?Model).initFill(null);
    remembered_models.set(.openrouter_api_key, openai_old);
    var context: Context = .{
        .gpa = gpa,
        .io = undefined,
        .agent = &agent,
        .accounts = &accounts,
        .remembered_models = &remembered_models,
    };

    const preferred_authors = try expectPick(try forAccount(&context, .openrouter_api_key));
    defer freePick(gpa, &preferred_authors);
    try std.testing.expectEqual(@as(?usize, 1), preferred_authors.preselected);
    try std.testing.expect(preferred_authors.current == null);
    const preferred_models = try expectPick(try selectRow(
        &preferred_authors,
        &context,
        preferred_authors.preselected.?,
    ));
    defer freePick(gpa, &preferred_models);
    try std.testing.expectEqual(@as(?usize, 1), preferred_models.preselected);
    try std.testing.expect(preferred_models.current == null);

    const authors = try expectPick(try run(&context));
    defer freePick(gpa, &authors);
    try std.testing.expectEqualStrings("Author: openrouter-api-key", authors.title);
    try std.testing.expectEqual(@as(usize, 3), authors.options.len);
    try std.testing.expectEqualStrings("Refresh the model list", authors.options[0].name);
    try std.testing.expectEqualStrings("openai", authors.options[1].name);
    try std.testing.expectEqualStrings("2 models", authors.options[1].extra.?);
    try std.testing.expectEqualStrings("qwen", authors.options[2].name);
    try std.testing.expectEqualStrings("1 model", authors.options[2].extra.?);
    try std.testing.expectEqual(
        llm.Account.openrouter_api_key,
        (try selectRow(&authors, &context, 0)).fetch,
    );

    const openai_models = try expectPick(try selectRow(&authors, &context, 1));
    defer freePick(gpa, &openai_models);
    try std.testing.expectEqualStrings("Model: openrouter-api-key", openai_models.title);
    try std.testing.expectEqual(@as(usize, 2), openai_models.options.len);
    try std.testing.expectEqualStrings("openai/gpt-new", openai_models.options[0].name);
    try std.testing.expectEqualStrings("openai/gpt-old", openai_models.options[1].name);
    try std.testing.expectEqual(authorKey("openai"), openai_models.payload);
    try Context.Outcome.expectEvent(try selectRow(&openai_models, &context, 1), .information);
    try std.testing.expectEqualStrings("openai/gpt-old", agent.model.?.name());

    const qwen_models = try expectPick(try selectRow(&authors, &context, 2));
    defer freePick(gpa, &qwen_models);
    try std.testing.expectEqualStrings("qwen/qwen-new", qwen_models.options[0].name);
    try std.testing.expectEqual(authorKey("qwen"), qwen_models.payload);

    try Context.Outcome.expectNoticeContaining(
        try selectRow(&openai_models, &context, 2),
        .failure,
        "valid model",
    );
    try std.testing.expectEqualStrings("openai/gpt-old", agent.model.?.name());

    std.mem.rotate(Metadata.Entry, metadata, 2);
    try std.testing.expectEqualStrings("qwen/qwen-new", metadata[0].model.name());
    try Context.Outcome.expectEvent(try selectRow(&openai_models, &context, 0), .information);
    try std.testing.expectEqualStrings("openai/gpt-new", agent.model.?.name());

    try Context.Outcome.expectNoticeContaining(
        try openai_models.select(&context, .{ .payload = authorKey("gone"), .row = 0 }),
        .failure,
        "valid model",
    );
    try std.testing.expectEqualStrings("openai/gpt-new", agent.model.?.name());
}

test "a key that two author rows carry names no model" {
    const rows = [_]AuthorRow{
        .{ .name = "openai", .count = 2, .first = 0 },
        .{ .name = "qwen", .count = 1, .first = 2 },
        .{ .name = "openai", .count = 3, .first = 3 },
    };
    const key = authorKey("openai");
    try std.testing.expect(authorModelIndex(&rows, .{ .payload = key, .row = 0 }) == null);
    try std.testing.expectEqual(
        @as(?usize, 2),
        authorModelIndex(&rows, .{ .payload = authorKey("qwen"), .row = 0 }),
    );
    try std.testing.expectEqual(
        @as(?usize, 1),
        authorModelIndex(rows[0..2], .{ .payload = key, .row = 1 }),
    );
    try std.testing.expect(authorModelIndex(rows[0..2], .{ .payload = key, .row = 2 }) == null);
}

test "the fetch row hands its account to the app" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant", .openai = "sk-openai" }, .{});
    defer testing.deinitAccounts(&accounts);
    try testing.seed(&accounts, .openai_api_key, &.{"gpt-5.6-sol"});
    var agent = testing.agent(gpa, .{ .anthropic_api_key = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    const vendors = try expectPick(try run(&context));
    defer freePick(gpa, &vendors);
    const anthropic_models = try expectPick(try selectRow(&vendors, &context, 0));
    defer freePick(gpa, &anthropic_models);
    try std.testing.expectEqualStrings("Fetch the model list", anthropic_models.options[0].name);
    try std.testing.expectEqual(
        llm.Account.anthropic_api_key,
        (try selectRow(&anthropic_models, &context, 0)).fetch,
    );

    const openai_models = try expectPick(try selectRow(&vendors, &context, 1));
    defer freePick(gpa, &openai_models);
    try std.testing.expectEqualStrings("Refresh the model list", openai_models.options[0].name);
    try std.testing.expectEqual(
        llm.Account.openai_api_key,
        (try selectRow(&openai_models, &context, 0)).fetch,
    );
    try std.testing.expect(!accounts.offersModel(.anthropic_api_key));
    try std.testing.expectEqualStrings("claude-sonnet-4-6", agent.model.?.name());
}

test "a provider row opens its accounts, and an account row opens its models" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(
        .{ .anthropic = "sk-ant", .openai = "sk-openai" },
        .{ .anthropic = true },
    );
    defer testing.deinitAccounts(&accounts);
    try testing.seed(&accounts, .openai_api_key, &.{ "gpt-5.6-sol", "gpt-5.6-luna" });
    var agent = testing.agent(gpa, .{ .anthropic_api_key = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    const vendors = try expectPick(try run(&context));
    defer freePick(gpa, &vendors);
    const anthropic_accounts = try expectPick(try selectRow(&vendors, &context, 0));
    defer freePick(gpa, &anthropic_accounts);
    try std.testing.expectEqual(@as(usize, 2), anthropic_accounts.options.len);

    const anthropic_models = try expectPick(try selectRow(&anthropic_accounts, &context, 0));
    defer freePick(gpa, &anthropic_models);
    try std.testing.expectEqualStrings(
        "Model: anthropic-plan",
        anthropic_models.title,
    );
    try std.testing.expect(anthropic_models.current == null);

    const openai_models = try expectPick(try selectRow(&vendors, &context, 1));
    defer freePick(gpa, &openai_models);
    try std.testing.expectEqualStrings("Model: openai-api-key", openai_models.title);
    try std.testing.expectEqual(@as(usize, 3), openai_models.options.len);
    try std.testing.expectEqualStrings("gpt-5.6-sol", openai_models.options[1].name);
}

test "each step names the opener that builds it again" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(
        .{ .anthropic = "sk-ant", .openai = "sk-openai" },
        .{ .anthropic = true },
    );
    defer testing.deinitAccounts(&accounts);
    var agent = testing.agent(gpa, .{ .anthropic_api_key = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    const vendors = try expectPick(try run(&context));
    defer freePick(gpa, &vendors);
    try std.testing.expect(vendors.reopen.? == &run);

    const anthropic_accounts = try expectPick(try selectRow(&vendors, &context, 0));
    defer freePick(gpa, &anthropic_accounts);
    try std.testing.expect(anthropic_accounts.reopen.? == accountStepOf(.anthropic));

    const anthropic_models = try expectPick(try selectRow(&anthropic_accounts, &context, 0));
    defer freePick(gpa, &anthropic_models);
    try std.testing.expect(
        anthropic_models.reopen.? == modelStepOf(.anthropic_plan).open,
    );

    const reopened = try expectPick(try anthropic_accounts.reopen.?(&context));
    defer freePick(gpa, &reopened);
    try std.testing.expectEqualStrings("Account", reopened.title);
    try std.testing.expectEqualStrings("anthropic-plan", reopened.options[0].name);
    try std.testing.expect(reopened.reopen.? == accountStepOf(.anthropic));

    const openai_models = try expectPick(try selectRow(&vendors, &context, 1));
    defer freePick(gpa, &openai_models);
    try std.testing.expect(openai_models.reopen.? == modelStepOf(.openai_api_key).open);
}

test "a model row switches to the chosen account and model" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant", .openai = "sk-openai" }, .{});
    defer testing.deinitAccounts(&accounts);
    try testing.seed(&accounts, .openai_api_key, &.{"gpt-5.6-sol"});
    var agent = testing.agent(gpa, .{ .anthropic_api_key = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    const vendors = try expectPick(try run(&context));
    defer freePick(gpa, &vendors);
    const openai_models = try expectPick(try selectRow(&vendors, &context, 1));
    defer freePick(gpa, &openai_models);

    try Context.Outcome.expectEvent(try selectRow(&openai_models, &context, 1), .information);
    try std.testing.expectEqualStrings("gpt-5.6-sol", agent.model.?.name());
    try std.testing.expectEqual(llm.Account.openai_api_key, agent.client.?.account());

    try Context.Outcome.expectNotice(try selectRow(&openai_models, &context, 1), .information);
    try std.testing.expectEqualStrings("gpt-5.6-sol", agent.model.?.name());
}

test "a pick of the active model adopts the fetched description" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant" }, .{});
    defer testing.deinitAccounts(&accounts);
    try testing.seed(&accounts, .anthropic_api_key, &.{"claude-opus-5"});
    var agent = testing.agent(gpa, .{ .anthropic_api_key = "sk-ant" });
    defer agent.deinit();

    var stale = try Model.init("claude-opus-5");
    stale.context_window = 7;
    stale.tokens_max = 11;
    stale.addEffort(.low);
    stale.price = .{ .input = 99, .output = 99, .cache_read = 99, .cache_write = 99 };
    agent.switchTo(accounts.client(.anthropic_api_key).?, stale);
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    const pick = try expectPick(try run(&context));
    defer freePick(gpa, &pick);
    try std.testing.expectEqualStrings("claude-opus-5", pick.options[pick.current.?].name);

    const outcome = try selectRow(&pick, &context, 1);
    switch (outcome) {
        .event => |event| gpa.free(event.content),
        .notice => |notice| gpa.free(notice.content),
        else => return error.ExpectedEvent,
    }
    const active = agent.model.?;
    try std.testing.expectEqual(@as(?u64, 1_000_000), active.context_window);
    try std.testing.expectEqual(@as(?u32, 128_000), active.tokens_max);
    try std.testing.expect(active.offers(.max));
    try std.testing.expectEqual(@as(f64, 3), active.price.?.input);
    try std.testing.expect(outcome == .event);
}

test "a report of a failed metadata write names the metadata" {
    const gpa = std.testing.allocator;
    const report = (try fetchReport(gpa, .anthropic_api_key, &.{
        .count = 2,
        .metadata_save_error = error.StoreBusy,
    })).?;
    defer gpa.free(report.content);
    try std.testing.expectEqual(Context.Outcome.Severity.failure, report.severity);
    try std.testing.expectEqualStrings(
        "Drinky fetched the model list of anthropic-api-key. Drinky could not save the public " ++
            "metadata because of error StoreBusy. The metadata serves this session.",
        report.content,
    );
}

test "a report of a fetch that described no model states that result" {
    const gpa = std.testing.allocator;
    const report = (try fetchReport(gpa, .anthropic_api_key, &.{ .count = 0 })).?;
    defer gpa.free(report.content);
    try std.testing.expectEqual(Context.Outcome.Severity.warning, report.severity);
    try std.testing.expectEqualStrings(
        "Drinky fetched the model list of anthropic-api-key. The account offers no model now.",
        report.content,
    );

    try std.testing.expect(try fetchReport(gpa, .anthropic_api_key, &.{ .count = 1 }) == null);
}

test "every report of a fetch that described no model states that result" {
    const gpa = std.testing.allocator;
    const cases = [_]struct {
        result: Accounts.Refresh,
        content: []const u8,
    }{
        .{
            .result = .{ .count = 0, .models_save_error = error.StoreBusy },
            .content = "Drinky fetched the model list of anthropic-api-key. Drinky could not " ++
                "save the model list because of error StoreBusy. The list serves this " ++
                "session. The account offers no model now.",
        },
        .{
            .result = .{
                .count = 0,
                .metadata_error = error.ConnectionTimedOut,
                .models_save_error = error.StoreBusy,
            },
            .content = "Drinky fetched the model list of anthropic-api-key. Drinky could not " ++
                "fetch the public metadata because of error ConnectionTimedOut. Drinky could " ++
                "not save the model list because of error StoreBusy. The list serves this " ++
                "session. The account offers no model now.",
        },
        .{
            .result = .{ .count = 0, .metadata_save_error = error.StoreBusy },
            .content = "Drinky fetched the model list of anthropic-api-key. Drinky could not " ++
                "save the public metadata because of error StoreBusy. The metadata serves " ++
                "this session. The account offers no model now.",
        },
        .{
            .result = .{
                .count = 0,
                .models_save_error = error.StoreBusy,
                .metadata_save_error = error.AccessDenied,
            },
            .content = "Drinky fetched the model list of anthropic-api-key. Drinky could not " ++
                "save the model list because of error StoreBusy. Drinky could not save the " ++
                "public metadata because of error AccessDenied. Both serve this session. " ++
                "The account offers no model now.",
        },
        .{
            .result = .{ .count = 0, .metadata_error = error.ConnectionTimedOut },
            .content = "Drinky fetched the model list of anthropic-api-key. Drinky could not " ++
                "fetch the public metadata because of error ConnectionTimedOut. " ++
                "The account offers no model now.",
        },
    };

    for (cases) |case| {
        const report = (try fetchReport(gpa, .anthropic_api_key, &case.result)).?;
        defer gpa.free(report.content);
        try std.testing.expectEqual(Context.Outcome.Severity.failure, report.severity);
        try std.testing.expectEqualStrings(case.content, report.content);
    }
}

test "a report of a missed metadata counts one model in the singular" {
    const gpa = std.testing.allocator;
    const report = (try fetchReport(gpa, .anthropic_api_key, &.{
        .count = 1,
        .metadata_error = error.ConnectionTimedOut,
    })).?;
    defer gpa.free(report.content);
    try std.testing.expectEqualStrings(
        "Drinky fetched the model list of anthropic-api-key. Drinky could not fetch the public " ++
            "metadata because of error ConnectionTimedOut. The account offers 1 model now.",
        report.content,
    );
}

test "a report of a failed list write names the list" {
    const gpa = std.testing.allocator;
    const report = (try fetchReport(gpa, .anthropic_api_key, &.{
        .count = 2,
        .models_save_error = error.StoreBusy,
    })).?;
    defer gpa.free(report.content);
    try std.testing.expectEqualStrings(
        "Drinky fetched the model list of anthropic-api-key. Drinky could not save the model " ++
            "list because of error StoreBusy. The list serves this session.",
        report.content,
    );

    const both = (try fetchReport(gpa, .anthropic_api_key, &.{
        .count = 2,
        .models_save_error = error.StoreBusy,
        .metadata_save_error = error.AccessDenied,
    })).?;
    defer gpa.free(both.content);
    try std.testing.expectEqualStrings(
        "Drinky fetched the model list of anthropic-api-key. Drinky could not save the model " ++
            "list because of error StoreBusy. Drinky could not save the public metadata " ++
            "because of error AccessDenied. Both serve this session.",
        both.content,
    );
}

test "every step reports a row that its list does not hold" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(
        .{ .anthropic = "sk-ant", .openai = "sk-openai" },
        .{ .anthropic = true },
    );
    defer testing.deinitAccounts(&accounts);
    try testing.seed(&accounts, .anthropic_api_key, &.{"claude-sonnet-4-6"});
    var agent = testing.agent(gpa, .{ .anthropic_api_key = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    const vendors = try expectPick(try run(&context));
    defer freePick(gpa, &vendors);
    try Context.Outcome.expectNoticeContaining(
        try selectRow(&vendors, &context, 99),
        .failure,
        "valid provider",
    );

    const anthropic_accounts = try expectPick(try selectRow(&vendors, &context, 0));
    defer freePick(gpa, &anthropic_accounts);
    try Context.Outcome.expectNoticeContaining(
        try selectRow(&anthropic_accounts, &context, 99),
        .failure,
        "valid account",
    );

    const anthropic_models = try expectPick(try selectRow(&anthropic_accounts, &context, 1));
    defer freePick(gpa, &anthropic_models);
    try Context.Outcome.expectNoticeContaining(
        try selectRow(&anthropic_models, &context, 99),
        .failure,
        "valid model",
    );
    try std.testing.expectEqualStrings("claude-sonnet-4-6", agent.model.?.name());
}

test "no authenticated accounts reports an error instead of a picker" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{}, .{});
    defer testing.deinitAccounts(&accounts);
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
    var accounts = testing.accounts(.{ .anthropic = "sk-ant" }, .{ .anthropic = true });
    defer testing.deinitAccounts(&accounts);
    try testing.seed(&accounts, .anthropic_plan, &.{"claude-sonnet-4-6"});
    try testing.seed(&accounts, .anthropic_api_key, &.{"claude-sonnet-4-6"});
    var agent = testing.agent(gpa, .{ .anthropic_plan = undefined });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    const anthropic_accounts = try expectPick(try run(&context));
    defer freePick(gpa, &anthropic_accounts);
    try std.testing.expectEqualStrings(
        "anthropic-plan",
        anthropic_accounts.options[anthropic_accounts.current.?].name,
    );

    const subscription_models = try expectPick(try selectRow(&anthropic_accounts, &context, 0));
    defer freePick(gpa, &subscription_models);
    try std.testing.expectEqualStrings(
        "claude-sonnet-4-6",
        subscription_models.options[subscription_models.current.?].name,
    );

    const api_models = try expectPick(try selectRow(&anthropic_accounts, &context, 1));
    defer freePick(gpa, &api_models);
    try std.testing.expect(api_models.current == null);
}

fn runUnderOom(gpa: std.mem.Allocator) !void {
    var accounts = testing.accounts(
        .{ .anthropic = "sk-ant", .openai = "sk-openai" },
        .{ .anthropic = true },
    );
    defer testing.deinitAccounts(&accounts);
    try testing.seed(&accounts, .anthropic_plan, &.{"claude-opus-5"});
    var agent = testing.agent(gpa, .{ .anthropic_api_key = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    const vendors = try expectPick(try run(&context));
    defer freePick(gpa, &vendors);
    const anthropic_accounts = try expectPick(try selectRow(&vendors, &context, 0));
    defer freePick(gpa, &anthropic_accounts);
    const anthropic_models = try expectPick(try selectRow(&anthropic_accounts, &context, 0));
    defer freePick(gpa, &anthropic_models);

    switch (try selectRow(&anthropic_models, &context, 1)) {
        .event => |event| gpa.free(event.content),
        else => return error.ExpectedEvent,
    }
}

test "a failed step build frees every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, runUnderOom, .{});
}
