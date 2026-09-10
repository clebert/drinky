//! `/model`: a stepped picker that ends on one model. The steps are the
//! provider, the account, the author, and the model. An OpenRouter account
//! opens the author step. A step that offers one row alone opens the next step
//! at once, so the user answers an open question only. A selection always
//! chooses a model together with its account. The command takes no argument.
//!
//! Every step names the opener that builds it again, so Esc in a later step
//! returns to it. The app keeps the trail, and a step that the flow skipped
//! opened no picker, so Esc never lands on a list that the user never saw.
//!
//! A selector receives the tapped row and the payload the command set. A step
//! that depends on an earlier choice needs one selector for each value of that
//! choice. Every step re-derives its lists from the live state.

const std = @import("std");

const Accounts = @import("../Accounts.zig");
const format = @import("../format.zig");
const llm = @import("../llm.zig");
const Metadata = @import("../Metadata.zig");
const Model = @import("../Model.zig");
const Context = @import("Context.zig");
const testing = @import("testing.zig");

pub const name = "model";
pub const summary = "switch the model";

/// Every step belongs to one `/model` run, so every step reports one cancellation.
const cancellation_message = "You canceled the model selection.";

/// The first row of the model step. It reads as a fetch while the account
/// offers nothing, because no list exists to refresh yet. The row hands its
/// account to the app, which runs the fetch and returns the result to
/// `fetchOutcome`.
const fetch_row = "Fetch the model list";
const refresh_row = "Refresh the model list";

/// The mark of a model whose output limit no source states. Drinky then sends a
/// low default, which can cut a long reply short, so the row states that Drinky
/// does not know the output support of the model.
const output_limit_mark = " · Output limit unknown";

/// A picker selector. It takes the tapped row and the payload the command set.
const Selector = *const fn (*Context, Context.Outcome.Pick.Selection) anyerror!Context.Outcome;

/// The parts of the model picker that name one account.
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
    // One provider answers this step already, so the flow opens the next one.
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

/// The account step of `vendor`: a picker over its authenticated accounts, or
/// the model step when it holds one account alone. The caller guarantees that
/// `vendor` has an authenticated account.
fn accountStep(context: *Context, vendor: llm.Provider) !Context.Outcome {
    var buffer: [std.enums.values(llm.Account).len]llm.Account = undefined;
    const list = authenticatedAccounts(context.accounts, vendor, &buffer);
    std.debug.assert(list.len > 0);
    if (list.len == 1) return nextStep(context, list[0]);

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

/// The opener of the account picker of `vendor`.
fn accountStepOf(comptime vendor: llm.Provider) Context.Outcome.Opener {
    return struct {
        fn open(context: *Context) anyerror!Context.Outcome {
            return accountStep(context, vendor);
        }
    }.open;
}

/// The selector of the account picker of `vendor`.
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
            return nextStep(context, list[index]);
        }
    }.select;
}

/// The step that follows the account: the author step of an OpenRouter account,
/// or the model step of every other account.
fn nextStep(context: *Context, account: llm.Account) !Context.Outcome {
    if (account.provider() == .openrouter) return authorStep(context, account);
    return modelStep(context, account);
}

const AuthorRow = struct {
    name: []const u8,
    count: usize,
    first: usize,
};

/// The author step of an OpenRouter account: the fetch row, then one row per
/// author. An author row opens the models of that author.
fn authorStep(context: *Context, account: llm.Account) !Context.Outcome {
    const gpa = context.gpa;
    var list: std.ArrayList(Model) = .empty;
    defer list.deinit(gpa);
    try context.accounts.listModels(account, &list, gpa);
    if (context.remote and list.items.len == 0) return Context.Outcome.reportNotice(
        gpa,
        .warning,
        "Fetch the model list of {s} with /model in the terminal first.",
        .{account.id()},
    );

    const authors = try gpa.alloc(AuthorRow, @max(list.items.len, 1));
    defer gpa.free(authors);
    const grouped = authorsOf(list.items, authors);

    var options: Context.Outcome.Options = .{ .gpa = gpa };
    errdefer options.deinit();
    var current: ?usize = null;
    const lead = leadRows(context);
    if (lead > 0) try options.print("{s}", .{firstRow(list.items.len)});
    for (grouped, 0..) |author, index| {
        try options.print("{s} · {d} model{s}", .{
            author.name,
            author.count,
            format.pluralSuffix(author.count),
        });
        if (isActiveAuthor(context, account, list.items, author)) current = index + lead;
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
        .reopen = step.open,
    } };
}

/// The payload of the model step of one author. A key names the author, so a
/// row of that step lands on a model of that author after a fetch reordered the
/// list. An index cannot, because a stale index that meets the first model of
/// another author reads valid.
fn authorKey(author_name: []const u8) usize {
    return @truncate(std.hash.Wyhash.hash(0, author_name));
}

/// The index of the tapped model in the list that `grouped` describes, or null
/// when the row names no model of the author the selection carries.
///
/// Two rows of `grouped` that share one key name one author, so the list is
/// grouped wrong or two names collide under `authorKey`. The step then knows no
/// author and reports, rather than land the row on the models of the wrong one.
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

/// The authors of `models`, one row per run of one author. `Metadata` groups
/// the models of one author, so one run is one author. A list that broke that
/// order yields two rows of one author, and `authorModelIndex` refuses such a
/// pair rather than guess.
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

fn authorStepOf(comptime account: llm.Account) ModelStep {
    return .{
        .select = struct {
            fn select(
                context: *Context,
                selection: Context.Outcome.Pick.Selection,
            ) anyerror!Context.Outcome {
                const gpa = context.gpa;
                const lead = leadRows(context);
                if (selection.row < lead) return .{ .fetch = account };
                var list: std.ArrayList(Model) = .empty;
                defer list.deinit(gpa);
                try context.accounts.listModels(account, &list, gpa);
                const authors = try gpa.alloc(AuthorRow, @max(list.items.len, 1));
                defer gpa.free(authors);
                const grouped = authorsOf(list.items, authors);
                if (selection.row - lead >= grouped.len) return Context.Outcome.reportNotice(
                    gpa,
                    .failure,
                    "Select a valid author.",
                    .{},
                );
                return authorModelsStep(context, account, grouped[selection.row - lead].first);
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

/// The model step of one author: that author's models, no fetch row, and the
/// key of the author as the payload.
fn authorModelsStep(context: *Context, account: llm.Account, first: usize) !Context.Outcome {
    const gpa = context.gpa;
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
    for (list.items[first..], 0..) |*model, index| {
        if (!std.mem.eql(u8, Metadata.authorOf(model.name()), author_name)) break;
        try row(&options, account, model);
        if (isActive(context, account, model.name())) current = index;
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

/// The last step: the fetch row, then a picker over the models of `account`.
/// The title names the account, because the flow can skip the step that names
/// it. Drinky compiles no model in, so an account that the user has not fetched
/// yet holds the fetch row alone. A remote host runs no fetch, so its step lists
/// the cached models alone, and an account with no cached list answers with a
/// notice that names the terminal.
fn modelStep(context: *Context, account: llm.Account) !Context.Outcome {
    const gpa = context.gpa;
    var list: std.ArrayList(Model) = .empty;
    defer list.deinit(gpa);
    try context.accounts.listModels(account, &list, gpa);
    if (context.remote and list.items.len == 0) return Context.Outcome.reportNotice(
        gpa,
        .warning,
        "Fetch the model list of {s} with /model in the terminal first.",
        .{account.id()},
    );

    var options: Context.Outcome.Options = .{ .gpa = gpa };
    errdefer options.deinit();
    var current: ?usize = null;
    const lead = leadRows(context);
    if (lead > 0) try options.print("{s}", .{firstRow(list.items.len)});
    for (list.items, 0..) |*model, index| {
        try row(&options, account, model);
        if (isActive(context, account, model.name())) current = index + lead;
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
        .reopen = step.open,
    } };
}

/// The label of the row that leads a model step over `count` models. It reads
/// as a fetch while the account offers no model, because no list exists to
/// refresh yet.
fn firstRow(count: usize) []const u8 {
    return if (count == 0) fetch_row else refresh_row;
}

/// The rows before the first model of a model step: the fetch row in the
/// terminal, and none on a remote host, which runs no fetch. The step and its
/// selector both count them, so a row index stays stable.
fn leadRows(context: *const Context) usize {
    return if (context.remote) 0 else 1;
}

/// Write the picker row of `model` under `account`. A model whose output limit
/// no source states carries the mark, because a request for it then sends the
/// low default of `Model.tokens_max_fallback`.
fn row(
    options: *Context.Outcome.Options,
    account: llm.Account,
    model: *const Model,
) !void {
    if (model.outputLimitUnknown(account))
        return options.print("{s}" ++ output_limit_mark, .{model.name()});
    return options.print("{s}", .{model.name()});
}

/// The selector, the opener, and the title of the model picker of `account`.
fn modelStepOf(comptime account: llm.Account) ModelStep {
    return .{
        .select = struct {
            fn select(
                context: *Context,
                selection: Context.Outcome.Pick.Selection,
            ) anyerror!Context.Outcome {
                const gpa = context.gpa;
                // This step sets no payload, because its rows already name
                // every model of the account.
                const index = selection.row;
                const lead = leadRows(context);
                if (index < lead) return .{ .fetch = account };
                var list: std.ArrayList(Model) = .empty;
                defer list.deinit(gpa);
                try context.accounts.listModels(account, &list, gpa);
                if (index - lead >= list.items.len) return Context.Outcome.reportNotice(
                    gpa,
                    .failure,
                    "Select a valid model.",
                    .{},
                );
                return apply(context, account, &list.items[index - lead]);
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

/// Run `model` under `account` from the next turn on. The account of a picked
/// row is authenticated, so it always has a client. A pick that repeats the
/// active pair switches too, because a fetch can have replaced the description
/// behind that name. Only the pair that already runs in every part reports
/// itself and switches nothing.
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

/// Whether `account` and `model_name` are the pair that runs now. A row marks
/// the active model by its name, because that name is what the row shows.
fn isActive(context: *const Context, account: llm.Account, model_name: []const u8) bool {
    const active_account = activeAccount(context) orelse return false;
    const model = context.agent.model orelse return false;
    return active_account == account and model.sameName(model_name);
}

/// Whether the session already runs `model` under `account`, description and
/// all. A fetch replaces the description of a model and keeps its name, so a
/// comparison of names alone leaves the session on the description that the
/// fetch replaced.
fn isCurrent(context: *const Context, account: llm.Account, model: *const Model) bool {
    const active_account = activeAccount(context) orelse return false;
    const active = context.agent.model orelse return false;
    return active_account == account and active.eql(model);
}

/// The outcome of one fetch of `account` over `result`: its step, reopened over
/// the list that arrived. Drinky asks the provider and the public metadata in
/// one fetch, so the user chooses a model out of a list that is current. A fetch
/// has three exits. A failed account list reports itself and opens nothing, so
/// the user reads what went wrong before another try. That report names a cache
/// write that failed with it. A failed metadata request opens the list and
/// states itself beside it. A failed cache write does the same, because that
/// list arrived.
///
/// The fetch row returns `Outcome.fetch`, and the app runs the two requests on a
/// worker, so the interface stays live and Esc can cancel them. The app then
/// hands the result here. The function holds no request, so a test reaches every
/// exit without a socket.
pub fn fetchOutcome(
    context: *Context,
    account: llm.Account,
    result: *const Accounts.Refresh,
) !Context.Outcome {
    if (result.models_error) |err|
        return fetchFailure(context.gpa, account, err, result.metadata_save_error);
    var outcome = try nextStep(context, account);
    errdefer freePick(context.gpa, &outcome.pick);
    outcome.pick.report = try fetchReport(context.gpa, account, result);
    return outcome;
}

/// The outcome of a fetch of `account` whose account list never arrived. The
/// metadata request runs even then, so `metadata_save_failure` names the cache
/// write that failed with it, and one line states both. The metadata that
/// arrived serves this session alone.
///
/// A store that held the credential of another principal stopped the request
/// before it ran. The evidence of that principal must leave the session, and
/// only the app can drop it. The account therefore goes to the app in place of
/// a line that states an error name and no step.
fn fetchFailure(
    gpa: std.mem.Allocator,
    account: llm.Account,
    models_failure: anyerror,
    metadata_save_failure: ?anyerror,
) !Context.Outcome {
    if (models_failure == error.CredentialReplaced)
        return .{ .credential_replaced = account };
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

/// The head of every line that reports a fetch whose public metadata never
/// arrived. Three of those lines share it, so they state that miss alike. The
/// list and the metadata take one sentence each, because they arrived apart.
const metadata_gone_head = "Drinky fetched the model list of {s}. Drinky could not fetch the " ++
    "public metadata because of error {t}.";

/// The sentence that states an empty list, or nothing while the account offers a
/// model. A fetch that described no model returns the user to the same fetch
/// row, so every report of such a fetch ends on this one fact.
fn emptyNote(count: usize) []const u8 {
    return if (count == 0) " The account offers no model now." else "";
}

/// The line that states what a fetch of `account` missed, or null when the
/// metadata and both caches took what arrived and the list holds a model. A
/// fetch writes one cache per kind, so the line names the cache that failed. The
/// list stands beside the line, because neither failure costs this session a
/// model.
///
/// A fetch that arrived and described no model returns the user to the same
/// fetch row, so every line states that result too.
fn fetchReport(
    gpa: std.mem.Allocator,
    account: llm.Account,
    result: *const Accounts.Refresh,
) !?Context.Outcome.Message {
    const empty = emptyNote(result.count);
    // No metadata arrived, so its cache write never ran. The list write is the
    // one write that can have failed here.
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

/// Test helper: tap `row` of `pick`, the way the app taps it. The app hands the
/// payload of the picker back with the row, so a test that builds the selection
/// by hand cannot drift from that pairing.
fn selectRow(
    pick: *const Context.Outcome.Pick,
    context: *Context,
    index: usize,
) anyerror!Context.Outcome {
    return pick.select(context, .{ .payload = pick.payload, .row = index });
}

// A cache write that failed costs this session no model, and a metadata request
// that failed costs it none either, so each states itself beside the list that
// arrived. A failed account list alone opens nothing.
test "a fetch opens the list that arrived and states what it missed" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant" }, .{});
    defer testing.deinitAccounts(&accounts);
    try testing.seed(&accounts, .anthropic_api_key, &.{ "claude-fable-5", "claude-sonnet-4-6" });
    var agent = testing.agent(gpa, .{ .anthropic_api_key = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    // The account list never arrived, so no list can open.
    try Context.Outcome.expectEvent(
        try fetchOutcome(
            &context,
            .anthropic_api_key,
            &.{ .models_error = error.ConnectionRefused },
        ),
        .failure,
    );

    // Every part arrived, so the list opens and states nothing beside itself.
    const complete = try expectPick(
        try fetchOutcome(&context, .anthropic_api_key, &.{ .count = 2 }),
    );
    defer freePick(gpa, &complete);
    try std.testing.expect(complete.report == null);

    // The metadata never arrived, so the list opens beside that failure.
    const metadata_gone = try expectPick(try fetchOutcome(&context, .anthropic_api_key, &.{
        .count = 2,
        .metadata_error = error.ConnectionTimedOut,
    }));
    defer freePick(gpa, &metadata_gone);
    defer gpa.free(metadata_gone.report.?.content);
    try std.testing.expectEqual(@as(usize, 3), metadata_gone.options.len);
    try std.testing.expectEqualStrings("claude-fable-5", metadata_gone.options[1]);
    try std.testing.expectEqual(
        Context.Outcome.Severity.failure,
        metadata_gone.report.?.severity,
    );
    try std.testing.expectEqualStrings(
        "Drinky fetched the model list of anthropic-api-key. Drinky could not fetch the public " ++
            "metadata because of error ConnectionTimedOut. The account offers 2 models now.",
        metadata_gone.report.?.content,
    );

    // The list write failed, so the list opens beside that failure.
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

    // Both failed, so one line states both beside the list.
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

// The metadata request runs even when the account list fails, so a cache write
// can fail on that path too. The metadata that arrived serves this session
// alone, so the line that names the failed fetch names that write as well.
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

// A store that holds the credential of another principal stops the fetch before
// its model request. The evidence of that principal must leave the session, and
// only the app can drop it. The outcome therefore names the account and no
// error.
test "a fetch that meets a replaced credential hands its account to the app" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{}, .{ .anthropic = true });
    defer testing.deinitAccounts(&accounts);
    var agent = testing.agent(gpa, .{ .anthropic_sub_login = undefined });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    const outcome = try fetchOutcome(&context, .anthropic_sub_login, &.{
        .models_error = error.CredentialReplaced,
    });
    try std.testing.expectEqual(
        llm.Account.anthropic_sub_login,
        outcome.credential_replaced,
    );

    // The metadata request runs even then. A failed cache write of that metadata
    // changes no principal, so the transition stands alone.
    const with_save_failure = try fetchOutcome(&context, .anthropic_sub_login, &.{
        .models_error = error.CredentialReplaced,
        .metadata_save_error = error.StoreBusy,
    });
    try std.testing.expectEqual(
        llm.Account.anthropic_sub_login,
        with_save_failure.credential_replaced,
    );
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
    try std.testing.expectEqualStrings("anthropic", pick.options[0]);
    try std.testing.expectEqualStrings("openai", pick.options[1]);
    // The active account marks its provider.
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
    try std.testing.expectEqualStrings("anthropic-sub-login", pick.options[0]);
    try std.testing.expectEqualStrings("anthropic-api-key", pick.options[1]);
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

    // Both earlier steps hold one row, so the model list is the whole command.
    const pick = try expectPick(try run(&context));
    defer freePick(gpa, &pick);
    try std.testing.expectEqualStrings("Model: anthropic-api-key", pick.title);
    // The fetch row leads the list, so the user can replace a stale one.
    try std.testing.expectEqual(@as(usize, 3), pick.options.len);
    try std.testing.expectEqualStrings("Refresh the model list", pick.options[0]);
    try std.testing.expectEqualStrings("claude-fable-5", pick.options[1]);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", pick.options[pick.current.?]);
}

// Anthropic takes the output limit from every request, so a model that states
// none runs at the fallback and can lose the tail of a long reply. The row
// states that, because Drinky does not know the output support of that model.
// OpenAI takes no limit from the request, so no row of such an account carries
// the mark, whatever its list states.
test "a model row marks an output limit that no source states" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant", .openai = "sk-openai" }, .{});
    defer testing.deinitAccounts(&accounts);
    try testing.seed(&accounts, .anthropic_api_key, &.{ "claude-fable-5", "claude-sonnet-4-6" });
    try testing.seed(&accounts, .openai_api_key, &.{"gpt-5.6-sol"});
    // No source states an output limit for these two models.
    accounts.catalog.accounts.get(.anthropic_api_key)[1].tokens_max = null;
    accounts.catalog.accounts.get(.openai_api_key)[0].tokens_max = null;
    var agent = testing.agent(gpa, .{ .anthropic_api_key = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    const anthropic_models = try expectPick(try modelStep(&context, .anthropic_api_key));
    defer freePick(gpa, &anthropic_models);
    // The vendor stated the limit of this model, so its row stands as it is.
    try std.testing.expectEqualStrings("claude-fable-5", anthropic_models.options[1]);
    try std.testing.expectEqualStrings(
        "claude-sonnet-4-6 · Output limit unknown",
        anthropic_models.options[2],
    );

    const openai_models = try expectPick(try modelStep(&context, .openai_api_key));
    defer freePick(gpa, &openai_models);
    try std.testing.expectEqualStrings("gpt-5.6-sol", openai_models.options[1]);
}

// Drinky compiles no model in, so an account the user never fetched offers the
// fetch row and nothing else.
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
    try std.testing.expectEqualStrings("Fetch the model list", pick.options[0]);
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
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    const authors = try expectPick(try run(&context));
    defer freePick(gpa, &authors);
    try std.testing.expectEqualStrings("Author: openrouter-api-key", authors.title);
    try std.testing.expectEqual(@as(usize, 3), authors.options.len);
    try std.testing.expectEqualStrings("Refresh the model list", authors.options[0]);
    try std.testing.expectEqualStrings("openai · 2 models", authors.options[1]);
    try std.testing.expectEqualStrings("qwen · 1 model", authors.options[2]);
    try std.testing.expectEqual(
        llm.Account.openrouter_api_key,
        (try selectRow(&authors, &context, 0)).fetch,
    );

    const openai_models = try expectPick(try selectRow(&authors, &context, 1));
    defer freePick(gpa, &openai_models);
    try std.testing.expectEqualStrings("Model: openrouter-api-key", openai_models.title);
    try std.testing.expectEqual(@as(usize, 2), openai_models.options.len);
    try std.testing.expectEqualStrings("openai/gpt-new", openai_models.options[0]);
    try std.testing.expectEqualStrings("openai/gpt-old", openai_models.options[1]);
    try std.testing.expectEqual(authorKey("openai"), openai_models.payload);
    try Context.Outcome.expectEvent(try selectRow(&openai_models, &context, 1), .information);
    try std.testing.expectEqualStrings("openai/gpt-old", agent.model.?.name());

    const qwen_models = try expectPick(try selectRow(&authors, &context, 2));
    defer freePick(gpa, &qwen_models);
    try std.testing.expectEqualStrings("qwen/qwen-new", qwen_models.options[0]);
    try std.testing.expectEqual(authorKey("qwen"), qwen_models.payload);

    // A row past the models of the author must not reach the next author.
    try Context.Outcome.expectNoticeContaining(
        try selectRow(&openai_models, &context, 2),
        .failure,
        "valid model",
    );
    try std.testing.expectEqualStrings("openai/gpt-old", agent.model.?.name());

    // A fetch that reorders the authors while the step stands open moves the
    // models of the author. The payload names the author, so a row still lands
    // on a model of that author.
    std.mem.rotate(Metadata.Entry, metadata, 2);
    try std.testing.expectEqualStrings("qwen/qwen-new", metadata[0].model.name());
    try Context.Outcome.expectEvent(try selectRow(&openai_models, &context, 0), .information);
    try std.testing.expectEqualStrings("openai/gpt-new", agent.model.?.name());

    // An author that a fetch dropped reports, and the model stays.
    try Context.Outcome.expectNoticeContaining(
        try openai_models.select(&context, .{ .payload = authorKey("gone"), .row = 0 }),
        .failure,
        "valid model",
    );
    try std.testing.expectEqualStrings("openai/gpt-new", agent.model.?.name());
}

// The key of an author names one author. Two rows that carry one key therefore
// name no author at all: the list broke its grouping, or two names collide
// under the hash. The step must report, and never land the row on the models of
// the wrong author.
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
    // One row alone carries the key, so the row of the selection lands.
    try std.testing.expectEqual(
        @as(?usize, 1),
        authorModelIndex(rows[0..2], .{ .payload = key, .row = 1 }),
    );
    try std.testing.expect(authorModelIndex(rows[0..2], .{ .payload = key, .row = 2 }) == null);
}

// A remote host runs no fetch, so the author step holds no fetch row and its
// rows start at the first author. The step below it names the models of that
// author, exactly as it does in the terminal.
test "a remote host lists the authors with no fetch row" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .openrouter = "sk-or" }, .{});
    defer testing.deinitAccounts(&accounts);
    var openai_model = Model.init("openai/gpt-new") catch unreachable;
    openai_model.context_window = 1;
    openai_model.tools = .supported;
    var qwen = Model.init("qwen/qwen-new") catch unreachable;
    qwen.context_window = 1;
    qwen.tools = .supported;
    const entries = [_]Metadata.Entry{
        .{ .provider = .openrouter, .model = openai_model },
        .{ .provider = .openrouter, .model = qwen },
    };
    accounts.catalog.metadata = try gpa.dupe(Metadata.Entry, &entries);
    defer gpa.free(accounts.catalog.metadata);
    var agent = testing.agent(gpa, .{ .openrouter_api_key = "sk-or" });
    defer agent.deinit();
    var context: Context = .{
        .gpa = gpa,
        .io = undefined,
        .agent = &agent,
        .accounts = &accounts,
        .remote = true,
    };

    const authors = try expectPick(try run(&context));
    defer freePick(gpa, &authors);
    try std.testing.expectEqual(@as(usize, 2), authors.options.len);
    try std.testing.expectEqualStrings("openai · 1 model", authors.options[0]);
    try std.testing.expectEqualStrings("qwen · 1 model", authors.options[1]);

    const qwen_models = try expectPick(try selectRow(&authors, &context, 1));
    defer freePick(gpa, &qwen_models);
    try std.testing.expectEqual(authorKey("qwen"), qwen_models.payload);
    try Context.Outcome.expectEvent(try selectRow(&qwen_models, &context, 0), .information);
    try std.testing.expectEqualStrings("qwen/qwen-new", agent.model.?.name());

    try Context.Outcome.expectNoticeContaining(
        try selectRow(&authors, &context, 2),
        .failure,
        "valid author",
    );
}

// An OpenRouter account that the user never fetched holds no cached list, and a
// remote host cannot fetch one, so the author step names the terminal.
test "a remote host names the terminal when the OpenRouter list is empty" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .openrouter = "sk-or" }, .{});
    defer testing.deinitAccounts(&accounts);
    var agent = testing.agent(gpa, .{ .openrouter_api_key = "sk-or" });
    defer agent.deinit();
    var context: Context = .{
        .gpa = gpa,
        .io = undefined,
        .agent = &agent,
        .accounts = &accounts,
        .remote = true,
    };

    try Context.Outcome.expectNoticeContaining(
        try run(&context),
        .warning,
        "Fetch the model list of openrouter-api-key with /model in the terminal first.",
    );
}

// A remote host cannot run a fetch, so its model step lists the cached models
// alone and a row index counts from the first model. An account that the user
// never fetched answers with a notice that names the terminal, because the
// fetch happens there.
test "a remote host lists the cached models with no fetch row" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant", .openai = "sk-openai" }, .{});
    defer testing.deinitAccounts(&accounts);
    try testing.seed(&accounts, .anthropic_api_key, &.{ "claude-fable-5", "claude-sonnet-4-6" });
    var agent = testing.agent(gpa, .{ .anthropic_api_key = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{
        .gpa = gpa,
        .io = undefined,
        .agent = &agent,
        .accounts = &accounts,
        .remote = true,
    };

    const anthropic_models = try expectPick(try modelStep(&context, .anthropic_api_key));
    defer freePick(gpa, &anthropic_models);
    try std.testing.expectEqual(@as(usize, 2), anthropic_models.options.len);
    try std.testing.expectEqualStrings("claude-fable-5", anthropic_models.options[0]);
    try std.testing.expectEqualStrings(
        "claude-sonnet-4-6",
        anthropic_models.options[anthropic_models.current.?],
    );
    try Context.Outcome.expectEvent(try selectRow(&anthropic_models, &context, 0), .information);
    try std.testing.expectEqualStrings("claude-fable-5", agent.model.?.name());
    try Context.Outcome.expectNoticeContaining(
        try selectRow(&anthropic_models, &context, 2),
        .failure,
        "valid model",
    );

    try Context.Outcome.expectNoticeContaining(
        try modelStep(&context, .openai_api_key),
        .warning,
        "Fetch the model list of openai-api-key with /model in the terminal first.",
    );
}

// A fetch reaches the network, and a command runs on the thread that paints and
// reads the keys. The row therefore runs no request of its own and names the
// account for the app, which fetches on a worker. The row of a stale list does
// the same, because both rows lead to one fetch.
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
    try std.testing.expectEqualStrings("Fetch the model list", anthropic_models.options[0]);
    try std.testing.expectEqual(
        llm.Account.anthropic_api_key,
        (try selectRow(&anthropic_models, &context, 0)).fetch,
    );

    const openai_models = try expectPick(try selectRow(&vendors, &context, 1));
    defer freePick(gpa, &openai_models);
    try std.testing.expectEqualStrings("Refresh the model list", openai_models.options[0]);
    try std.testing.expectEqual(
        llm.Account.openai_api_key,
        (try selectRow(&openai_models, &context, 0)).fetch,
    );
    // The row itself changes nothing: the catalog and the agent stand as before.
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
        "Model: anthropic-sub-login",
        anthropic_models.title,
    );
    // The subscription is not the active account, so no row is the current one.
    try std.testing.expect(anthropic_models.current == null);

    // OpenAI holds one authenticated account, so its row skips the account step.
    const openai_models = try expectPick(try selectRow(&vendors, &context, 1));
    defer freePick(gpa, &openai_models);
    try std.testing.expectEqualStrings("Model: openai-api-key", openai_models.title);
    try std.testing.expectEqual(@as(usize, 3), openai_models.options.len);
    try std.testing.expectEqualStrings("gpt-5.6-sol", openai_models.options[1]);
}

// Esc returns to the picker that a row opened, so every step names the opener
// that builds it again. The app keeps the trail of those openers.
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
        anthropic_models.reopen.? == modelStepOf(.anthropic_sub_login).open,
    );

    // An opener builds the same picker again: the same rows, and the same
    // opener on the rebuilt one.
    const reopened = try expectPick(try anthropic_accounts.reopen.?(&context));
    defer freePick(gpa, &reopened);
    try std.testing.expectEqualStrings("Account", reopened.title);
    try std.testing.expectEqualStrings("anthropic-sub-login", reopened.options[0]);
    try std.testing.expect(reopened.reopen.? == accountStepOf(.anthropic));

    // A step that the flow skipped opens no picker, so it enters no trail and
    // Esc cannot land on it.
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

    // The selection crosses vendors, so it switches the account too.
    try Context.Outcome.expectEvent(try selectRow(&openai_models, &context, 1), .information);
    try std.testing.expectEqualStrings("gpt-5.6-sol", agent.model.?.name());
    try std.testing.expectEqual(llm.Account.openai_api_key, agent.client.?.account());

    try Context.Outcome.expectNotice(try selectRow(&openai_models, &context, 1), .information);
    try std.testing.expectEqualStrings("gpt-5.6-sol", agent.model.?.name());
}

// A fetch replaces the description of a model and keeps its name. The row of
// the model that already runs is the common pick after a fetch, so that pick
// must carry the fetched description into the session.
test "a pick of the active model adopts the fetched description" {
    const gpa = std.testing.allocator;
    var accounts = testing.accounts(.{ .anthropic = "sk-ant" }, .{});
    defer testing.deinitAccounts(&accounts);
    try testing.seed(&accounts, .anthropic_api_key, &.{"claude-opus-5"});
    var agent = testing.agent(gpa, .{ .anthropic_api_key = "sk-ant" });
    defer agent.deinit();

    // The session runs the description that the fetch replaced.
    var stale = try Model.init("claude-opus-5");
    stale.context_window = 7;
    stale.tokens_max = 11;
    stale.addEffort(.low);
    stale.price = .{ .input = 99, .output = 99, .cache_read = 99, .cache_write = 99 };
    agent.switchTo(accounts.client(.anthropic_api_key).?, stale);
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    const pick = try expectPick(try run(&context));
    defer freePick(gpa, &pick);
    try std.testing.expectEqualStrings("claude-opus-5", pick.options[pick.current.?]);

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
    // The description changed, so the line states the switch.
    try std.testing.expect(outcome == .event);
}

// The two cache writes of a fetch fail on their own, so a line must name the
// cache that failed. A user who reads the wrong cache fetches a list that
// already reached the disk, and the write that failed stays unnamed.
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

// A fetch that arrived and described no model returns the user to the same
// fetch row. Without a line, that result reads like a fetch that never ran.
test "a report of a fetch that described no model states that result" {
    const gpa = std.testing.allocator;
    const report = (try fetchReport(gpa, .anthropic_api_key, &.{ .count = 0 })).?;
    defer gpa.free(report.content);
    try std.testing.expectEqual(Context.Outcome.Severity.warning, report.severity);
    try std.testing.expectEqualStrings(
        "Drinky fetched the model list of anthropic-api-key. The account offers no model now.",
        report.content,
    );

    // A list that holds a model needs no line, because the list itself shows it.
    try std.testing.expect(try fetchReport(gpa, .anthropic_api_key, &.{ .count = 1 }) == null);
}

// A failed write and a missed metadata leave the picker on the fetch row too
// when no model arrived. Each report therefore ends on the same one fact, so a
// user never reads that a list serves a session that has no model.
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

// A line that counts models must read correctly for one model.
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

    // Both writes can fail together, so one line states both.
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
    // Both Anthropic accounts are authenticated, so every model name appears
    // under two accounts. The mark must land inside the active account's list.
    var accounts = testing.accounts(.{ .anthropic = "sk-ant" }, .{ .anthropic = true });
    defer testing.deinitAccounts(&accounts);
    try testing.seed(&accounts, .anthropic_sub_login, &.{"claude-sonnet-4-6"});
    try testing.seed(&accounts, .anthropic_api_key, &.{"claude-sonnet-4-6"});
    var agent = testing.agent(gpa, .{ .anthropic_sub_login = undefined });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    const anthropic_accounts = try expectPick(try run(&context));
    defer freePick(gpa, &anthropic_accounts);
    try std.testing.expectEqualStrings(
        "anthropic-sub-login",
        anthropic_accounts.options[anthropic_accounts.current.?],
    );

    const subscription_models = try expectPick(try selectRow(&anthropic_accounts, &context, 0));
    defer freePick(gpa, &subscription_models);
    try std.testing.expectEqualStrings(
        "claude-sonnet-4-6",
        subscription_models.options[subscription_models.current.?],
    );

    // The same model name under the API account marks no row.
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
    try testing.seed(&accounts, .anthropic_sub_login, &.{"claude-opus-5"});
    var agent = testing.agent(gpa, .{ .anthropic_api_key = "sk-ant" });
    defer agent.deinit();
    var context: Context = .{ .gpa = gpa, .io = undefined, .agent = &agent, .accounts = &accounts };

    const vendors = try expectPick(try run(&context));
    defer freePick(gpa, &vendors);
    const anthropic_accounts = try expectPick(try selectRow(&vendors, &context, 0));
    defer freePick(gpa, &anthropic_accounts);
    const anthropic_models = try expectPick(try selectRow(&anthropic_accounts, &context, 0));
    defer freePick(gpa, &anthropic_models);

    // Row 0 hands off to the app and allocates nothing, so the walk picks a
    // model row.
    switch (try selectRow(&anthropic_models, &context, 1)) {
        .event => |event| gpa.free(event.content),
        else => return error.ExpectedEvent,
    }
}

test "a failed step build frees every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, runUnderOom, .{});
}
