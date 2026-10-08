const std = @import("std");

const accounts = @import("accounts");
const core = @import("core");

const Message = @import("../Message.zig");
const Context = @import("Context.zig");
const testing = @import("testing.zig");

pub const name = "model";
pub const summary = "Switch the model";

const cancellation_message = "You canceled the model selection.";

const fetch_row = "Fetch the model list";
const refresh_row = "Refresh the model list";
const lead_rows = 1;

const extra_output_limit = "The output limit is unknown.";

const vendors_max = std.enums.values(accounts.Account.Vendor).len;
const rows_max = accounts.Account.table.len;

const opener: Context.Outcome.Opener = .{ .open = reopen };

const AuthorRow = struct {
    name: []const u8,
    count: usize,
    first: usize,

    fn ranksBefore(_: void, left: AuthorRow, right: AuthorRow) bool {
        if (left.count != right.count) return left.count > right.count;
        return left.first < right.first;
    }
};

const AuthorModels = packed struct(usize) {
    account: u8,
    first: @Int(.unsigned, @bitSizeOf(usize) - 8),
};

pub fn run(context: *Context) Context.Error!Context.Outcome {
    var buffer: [vendors_max]accounts.Account.Vendor = undefined;
    const vendors = authenticatedVendors(context.account_registry, &buffer);
    if (vendors.len == 0) return .{ .refusal = try Message.print(
        context.gpa,
        .failure,
        "Sign in to an account before you select a model.",
        .{},
    ) };
    if (vendors.len == 1) return accountStep(context, vendors[0]);

    var options: Context.Outcome.Options = .{ .gpa = context.gpa };
    errdefer options.deinit();
    var current: ?usize = null;
    const active_vendor = activeVendor(context);
    for (vendors, 0..) |vendor, index| {
        try options.print("{s}", .{@tagName(vendor)});
        if (active_vendor == vendor) current = index;
    }
    return .{ .pick = .{
        .select = selectVendor,
        .title = "Vendor",
        .cancellation_message = cancellation_message,
        .options = try options.toOwnedSlice(),
        .current = current,
        .reopen = opener,
    } };
}

fn reopen(context: *Context, payload: usize) Context.Error!Context.Outcome {
    _ = payload;
    return run(context);
}

fn selectVendor(
    context: *Context,
    selection: Context.Outcome.Pick.Selection,
) Context.Error!Context.Outcome {
    var buffer: [vendors_max]accounts.Account.Vendor = undefined;
    const vendors = authenticatedVendors(context.account_registry, &buffer);
    return accountStep(context, vendors[selection.row]);
}

fn accountStep(context: *Context, vendor: accounts.Account.Vendor) !Context.Outcome {
    var buffer: [rows_max]usize = undefined;
    const list = authenticatedAccounts(context.account_registry, vendor, &buffer);
    std.debug.assert(list.len > 0);
    if (list.len == 1) return .{ .pick = try forAccount(context, list[0]) };

    var options: Context.Outcome.Options = .{ .gpa = context.gpa };
    errdefer options.deinit();
    var current: ?usize = null;
    for (list, 0..) |account, index| {
        try options.print("{s}", .{accounts.Account.table[account].id});
        if (context.choice.isActive(account)) current = index;
    }
    return .{ .pick = .{
        .select = selectAccount,
        .title = "Account",
        .cancellation_message = cancellation_message,
        .options = try options.toOwnedSlice(),
        .current = current,
        .payload = @backingInt(vendor),
        .reopen = .{ .open = reopenAccounts, .payload = @backingInt(vendor) },
    } };
}

fn reopenAccounts(context: *Context, payload: usize) Context.Error!Context.Outcome {
    return accountStep(context, @fromBackingInt(@intCast(payload)));
}

fn selectAccount(
    context: *Context,
    selection: Context.Outcome.Pick.Selection,
) Context.Error!Context.Outcome {
    var buffer: [rows_max]usize = undefined;
    const vendor: accounts.Account.Vendor = @fromBackingInt(@intCast(selection.payload));
    const list = authenticatedAccounts(context.account_registry, vendor, &buffer);
    return .{ .pick = try forAccount(context, list[selection.row]) };
}

pub fn forAccount(context: *Context, account: usize) !Context.Outcome.Pick {
    const source = accounts.Account.table[account].model_source;
    if (source == .public) return authorStep(context, account);
    return modelStep(context, account);
}

fn authorStep(context: *Context, account: usize) !Context.Outcome.Pick {
    const gpa = context.gpa;
    const preferred_name = rememberedName(context, account);
    var list: std.ArrayList(accounts.Model) = .empty;
    defer list.deinit(gpa);
    try context.account_registry.listModels(account, &list, gpa);

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
            core.text.pluralSuffix(author.count),
        });
        if (isActiveAuthor(context, account, list.items, author.name)) current = index + lead_rows;
        if (isPreferredAuthor(preferred_name, author.name)) preselected = index + lead_rows;
    }
    return .{
        .select = selectAuthor,
        .title = title("Author", account),
        .cancellation_message = cancellation_message,
        .options = try options.toOwnedSlice(),
        .current = current,
        .preselected = preselected,
        .payload = account,
        .reopen = .{ .open = reopenAuthors, .payload = account },
    };
}

fn reopenAuthors(context: *Context, payload: usize) Context.Error!Context.Outcome {
    return .{ .pick = try authorStep(context, payload) };
}

fn title(comptime step: []const u8, account: usize) []const u8 {
    const titles = comptime blk: {
        var list: [rows_max][]const u8 = undefined;
        for (&accounts.Account.table, 0..) |*entry, index| list[index] = step ++ ": " ++ entry.id;
        break :blk list;
    };
    return titles[account];
}

fn authorsOf(models: []const accounts.Model, out: []AuthorRow) []AuthorRow {
    var count: usize = 0;
    for (models, 0..) |*model, index| {
        const author_name = accounts.Metadata.authorOf(model.name());
        for (out[0..count]) |*author| {
            if (!std.mem.eql(u8, author.name, author_name)) continue;
            author.count += 1;
            break;
        } else {
            out[count] = .{ .name = author_name, .count = 1, .first = index };
            count += 1;
        }
    }
    const grouped = out[0..count];
    std.mem.sort(AuthorRow, grouped, {}, AuthorRow.ranksBefore);
    return grouped;
}

fn writtenBy(model: *const accounts.Model, author_name: []const u8) bool {
    return std.mem.eql(u8, accounts.Metadata.authorOf(model.name()), author_name);
}

fn isActiveAuthor(
    context: *const Context,
    account: usize,
    models: []const accounts.Model,
    author_name: []const u8,
) bool {
    const model = context.choice.model orelse return false;
    if (!context.choice.isActive(account)) return false;
    for (models) |*item| {
        if (item.sameName(model.name())) return writtenBy(item, author_name);
    }
    return false;
}

fn isPreferredAuthor(preferred_name: ?[]const u8, author_name: []const u8) bool {
    const remembered = preferred_name orelse return false;
    return std.mem.eql(u8, accounts.Metadata.authorOf(remembered), author_name);
}

fn selectAuthor(
    context: *Context,
    selection: Context.Outcome.Pick.Selection,
) Context.Error!Context.Outcome {
    const gpa = context.gpa;
    const account = selection.payload;
    if (selection.row < lead_rows) return .{ .fetch = account };
    var list: std.ArrayList(accounts.Model) = .empty;
    defer list.deinit(gpa);
    try context.account_registry.listModels(account, &list, gpa);
    const authors = try gpa.alloc(AuthorRow, @max(list.items.len, 1));
    defer gpa.free(authors);
    const grouped = authorsOf(list.items, authors);
    return authorModelsStep(context, .{
        .account = @intCast(account),
        .first = @intCast(grouped[selection.row - lead_rows].first),
    });
}

fn authorModelsStep(context: *Context, step: AuthorModels) !Context.Outcome {
    const gpa = context.gpa;
    const account: usize = step.account;
    const first: usize = step.first;
    const preferred_name = rememberedName(context, account);
    var list: std.ArrayList(accounts.Model) = .empty;
    defer list.deinit(gpa);
    try context.account_registry.listModels(account, &list, gpa);
    const author_name = accounts.Metadata.authorOf(list.items[first].name());
    var options: Context.Outcome.Options = .{ .gpa = gpa };
    errdefer options.deinit();
    var current: ?usize = null;
    var preselected: ?usize = null;
    var index: usize = 0;
    for (list.items[first..]) |*model| {
        if (!writtenBy(model, author_name)) continue;
        try row(&options, &accounts.Account.table[account], model);
        if (context.choice.usesModel(account, model.name())) current = index;
        if (isPreferred(preferred_name, model)) preselected = index;
        index += 1;
    }
    return .{ .pick = .{
        .select = selectAuthorModel,
        .title = title("Model", account),
        .cancellation_message = cancellation_message,
        .options = try options.toOwnedSlice(),
        .current = current,
        .preselected = preselected,
        .payload = @bitCast(step),
    } };
}

fn selectAuthorModel(
    context: *Context,
    selection: Context.Outcome.Pick.Selection,
) Context.Error!Context.Outcome {
    const gpa = context.gpa;
    const step: AuthorModels = @bitCast(selection.payload);
    var list: std.ArrayList(accounts.Model) = .empty;
    defer list.deinit(gpa);
    try context.account_registry.listModels(step.account, &list, gpa);
    return apply(context, step.account, authorModel(list.items, step.first, selection.row));
}

fn authorModel(
    models: []const accounts.Model,
    first: usize,
    row_index: usize,
) *const accounts.Model {
    const author_name = accounts.Metadata.authorOf(models[first].name());
    var remaining = row_index;
    for (models[first..]) |*model| {
        if (!writtenBy(model, author_name)) continue;
        if (remaining == 0) return model;
        remaining -= 1;
    }
    unreachable;
}

fn modelStep(context: *Context, account: usize) !Context.Outcome.Pick {
    const gpa = context.gpa;
    const preferred_name = rememberedName(context, account);
    var list: std.ArrayList(accounts.Model) = .empty;
    defer list.deinit(gpa);
    try context.account_registry.listModels(account, &list, gpa);

    var options: Context.Outcome.Options = .{ .gpa = gpa };
    errdefer options.deinit();
    var current: ?usize = null;
    var preselected: ?usize = null;
    try options.print("{s}", .{firstRow(list.items.len)});
    for (list.items, 0..) |*model, index| {
        try row(&options, &accounts.Account.table[account], model);
        if (context.choice.usesModel(account, model.name())) current = index + lead_rows;
        if (isPreferred(preferred_name, model)) preselected = index + lead_rows;
    }
    return .{
        .select = selectModel,
        .title = title("Model", account),
        .cancellation_message = cancellation_message,
        .options = try options.toOwnedSlice(),
        .current = current,
        .preselected = preselected,
        .payload = account,
        .reopen = .{ .open = reopenModels, .payload = account },
    };
}

fn reopenModels(context: *Context, payload: usize) Context.Error!Context.Outcome {
    return .{ .pick = try modelStep(context, payload) };
}

fn firstRow(count: usize) []const u8 {
    return if (count == 0) fetch_row else refresh_row;
}

fn row(
    options: *Context.Outcome.Options,
    account: *const accounts.Account,
    model: *const accounts.Model,
) !void {
    if (model.outputLimitUnknown(account))
        return options.addExtra(true, model.name(), extra_output_limit, .{});
    return options.print("{s}", .{model.name()});
}

fn selectModel(
    context: *Context,
    selection: Context.Outcome.Pick.Selection,
) Context.Error!Context.Outcome {
    const gpa = context.gpa;
    const account = selection.payload;
    if (selection.row < lead_rows) return .{ .fetch = account };
    var list: std.ArrayList(accounts.Model) = .empty;
    defer list.deinit(gpa);
    try context.account_registry.listModels(account, &list, gpa);
    return apply(context, account, &list.items[selection.row - lead_rows]);
}

fn apply(context: *Context, account: usize, model: *const accounts.Model) !Context.Outcome {
    if (isCurrent(context, account, model)) return Context.Outcome.reportNotice(
        context.gpa,
        .information,
        "Drinky already uses {s}/{s}.",
        .{ accounts.Account.table[account].id, model.name() },
    );
    context.choice.account = account;
    context.choice.model = model.*;
    return usedEvent(context);
}

pub fn usedEvent(context: *Context) !Context.Outcome {
    const account = context.choice.account.?;
    const id = accounts.Account.table[account].id;
    const model = context.choice.model orelse {
        const lead = "Drinky now uses {s}. ";
        const registry = context.account_registry;
        return .{ .event = try nextStep(context.gpa, registry, account, lead, .{id}) };
    };
    return Context.Outcome.reportEvent(
        context.gpa,
        .information,
        "Drinky now uses {s}/{s}.",
        .{ id, model.name() },
    );
}

pub fn nextStep(
    gpa: std.mem.Allocator,
    registry: *accounts.Registry,
    account: usize,
    comptime lead: []const u8,
    lead_args: anytype,
) !Message {
    const id = accounts.Account.table[account].id;
    if (registry.offersModel(account)) return Message.print(
        gpa,
        .information,
        lead ++ "Select a model of {s} with /model.",
        lead_args ++ .{id},
    );
    return Message.print(
        gpa,
        .information,
        lead ++ "Fetch the model list of {s} with /model.",
        lead_args ++ .{id},
    );
}

fn authenticatedVendors(
    registry: *accounts.Registry,
    out: []accounts.Account.Vendor,
) []accounts.Account.Vendor {
    var count: usize = 0;
    for (std.enums.values(accounts.Account.Vendor)) |vendor| {
        for (&accounts.Account.table, 0..) |*account, index| {
            if (account.vendor != vendor or !registry.isAuthenticated(index)) continue;
            out[count] = vendor;
            count += 1;
            break;
        }
    }
    return out[0..count];
}

fn authenticatedAccounts(
    registry: *accounts.Registry,
    vendor: accounts.Account.Vendor,
    out: []usize,
) []usize {
    var count: usize = 0;
    for (&accounts.Account.table, 0..) |*account, index| {
        if (account.vendor != vendor or !registry.isAuthenticated(index)) continue;
        out[count] = index;
        count += 1;
    }
    return out[0..count];
}

fn activeVendor(context: *const Context) ?accounts.Account.Vendor {
    const account = context.choice.account orelse return null;
    return accounts.Account.table[account].vendor;
}

fn rememberedName(context: *const Context, account: usize) ?[]const u8 {
    return context.remembered_model_names[account];
}

fn isPreferred(preferred_name: ?[]const u8, model: *const accounts.Model) bool {
    const remembered = preferred_name orelse return false;
    return model.sameName(remembered);
}

fn isCurrent(context: *const Context, account: usize, model: *const accounts.Model) bool {
    const active = context.choice.model orelse return false;
    return context.choice.isActive(account) and active.eql(model);
}

pub fn fetchOutcome(
    context: *Context,
    account: usize,
    result: *const accounts.Registry.Refresh,
) !Context.Outcome {
    const id = accounts.Account.table[account].id;
    if (result.models_error) |err|
        return fetchFailure(context.gpa, id, err, result.metadata_save_error);
    var pick = try forAccount(context, account);
    errdefer pick.deinit(context.gpa);
    pick.report = try fetchReport(context.gpa, id, result);
    return .{ .pick = pick };
}

fn fetchFailure(
    gpa: std.mem.Allocator,
    id: []const u8,
    models_failure: accounts.Registry.FetchError,
    metadata_save_failure: ?accounts.json_store.SaveError,
) !Context.Outcome {
    const models_sentence = "Drinky could not fetch the model list of {s} because of error {t}.";
    const cache_failure = metadata_save_failure orelse return Context.Outcome.reportEvent(
        gpa,
        .failure,
        models_sentence,
        .{ id, models_failure },
    );
    return Context.Outcome.reportEvent(
        gpa,
        .failure,
        models_sentence ++ metadata_save_sentence ++ " The metadata serves this session.",
        .{ id, models_failure, cache_failure },
    );
}

const metadata_save_sentence = " Drinky could not save the public metadata because of error {t}.";

fn fetchReport(
    gpa: std.mem.Allocator,
    id: []const u8,
    result: *const accounts.Registry.Refresh,
) !?Message {
    const failed = result.metadata_error != null or result.models_save_error != null or
        result.metadata_save_error != null;
    if (!failed and result.count > 0) return null;
    var text: std.Io.Writer.Allocating = .init(gpa);
    errdefer text.deinit();
    writeFetchReport(&text.writer, id, result) catch return error.OutOfMemory;
    return .{
        .content = try text.toOwnedSlice(),
        .severity = if (failed) .failure else .warning,
    };
}

fn writeFetchReport(
    writer: *std.Io.Writer,
    id: []const u8,
    result: *const accounts.Registry.Refresh,
) std.Io.Writer.Error!void {
    try writer.print("Drinky fetched the model list of {s}.", .{id});
    if (result.metadata_error) |err| try writer.print(
        " Drinky could not fetch the public metadata because of error {t}.",
        .{err},
    );
    if (result.models_save_error) |err| try writer.print(
        " Drinky could not save the model list because of error {t}.",
        .{err},
    );
    if (result.metadata_save_error) |err| try writer.print(metadata_save_sentence, .{err});
    const list_unsaved = result.models_save_error != null;
    const metadata_unsaved = result.metadata_save_error != null;
    try writer.writeAll(if (list_unsaved and metadata_unsaved)
        " Both serve this session."
    else if (list_unsaved)
        " The list serves this session."
    else if (metadata_unsaved)
        " The metadata serves this session."
    else
        "");
    if (result.count == 0) return writer.writeAll(" The account offers no model now.");
    if (result.metadata_error != null and !list_unsaved) try writer.print(
        " The account offers {d} model{s} now.",
        .{ result.count, core.text.pluralSuffix(result.count) },
    );
}

test "the first step lists the vendors with an authenticated account" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    try rig.init(
        &.{
            .variables = &.{
                .{ "ANTHROPIC_API_KEY", "sk-ant" },
                .{ "OPENAI_API_KEY", "sk-openai" },
            },
        },
    );
    defer rig.deinit();
    rig.choice.account = accounts.testing.anthropic_api_key;
    var context = rig.context();

    const pick = try testing.expectPick(try run(&context));
    defer pick.deinit(gpa);
    try std.testing.expectEqualStrings("Vendor", pick.title);
    try std.testing.expectEqual(@as(usize, 2), pick.options.len);
    try std.testing.expectEqualStrings("anthropic", pick.options[0].name);
    try std.testing.expectEqualStrings("openai", pick.options[1].name);
    try std.testing.expectEqual(@as(usize, 0), pick.current.?);
    try testing.expectReopen(&context, &pick);
}

test "one vendor alone opens the account step, and one account alone the model step" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "ANTHROPIC_API_KEY", "sk-ant" }},
        .store =
        \\{ "anthropic-plan":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000 } }
        ,
    });
    defer rig.deinit();
    try rig.account_rig.seed(
        accounts.testing.anthropic_api_key,
        &.{ "claude-fable-5", "claude-sonnet-4-6" },
    );
    rig.choice.account = accounts.testing.anthropic_api_key;
    rig.choice.model = rig.registry().findModel(
        accounts.testing.anthropic_api_key,
        "claude-sonnet-4-6",
    );
    var context = rig.context();

    const step = try testing.expectPick(try run(&context));
    defer step.deinit(gpa);
    try std.testing.expectEqualStrings("Account", step.title);
    try std.testing.expectEqual(@as(usize, 2), step.options.len);
    try std.testing.expectEqualStrings("anthropic-plan", step.options[0].name);
    try std.testing.expectEqualStrings("anthropic-api-key", step.options[1].name);
    try std.testing.expectEqual(@as(usize, 1), step.current.?);
    try testing.expectReopen(&context, &step);

    const models = try testing.expectPick(try testing.selectRow(&step, &context, 1));
    defer models.deinit(gpa);
    try std.testing.expectEqualStrings("Model: anthropic-api-key", models.title);
    try std.testing.expectEqual(@as(usize, 3), models.options.len);
    try std.testing.expectEqualStrings("Refresh the model list", models.options[0].name);
    try std.testing.expectEqualStrings("claude-fable-5", models.options[1].name);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", models.options[models.current.?].name);
    try testing.expectReopen(&context, &models);

    const plan_models = try testing.expectPick(try testing.selectRow(&step, &context, 0));
    defer plan_models.deinit(gpa);
    try std.testing.expectEqualStrings("Model: anthropic-plan", plan_models.title);
    try std.testing.expectEqualStrings("Fetch the model list", plan_models.options[0].name);
    try std.testing.expect(plan_models.current == null);
    try std.testing.expectEqual(
        accounts.testing.anthropic_plan,
        (try testing.selectRow(&plan_models, &context, 0)).fetch,
    );

    try rig.registry().logout(accounts.testing.anthropic_plan);
    const alone = try testing.expectPick(try run(&context));
    defer alone.deinit(gpa);
    try std.testing.expectEqualStrings("Model: anthropic-api-key", alone.title);
}

test "a model row switches to the chosen account and model, and a repeat is a notice" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    try rig.init(
        &.{
            .variables = &.{
                .{ "ANTHROPIC_API_KEY", "sk-ant" },
                .{ "OPENAI_API_KEY", "sk-openai" },
            },
        },
    );
    defer rig.deinit();
    try rig.account_rig.seed(accounts.testing.openai_api_key, &.{"gpt-5.6-sol"});
    rig.choice.account = accounts.testing.anthropic_api_key;
    var context = rig.context();

    const vendors = try testing.expectPick(try run(&context));
    defer vendors.deinit(gpa);
    const openai_models = try testing.expectPick(try testing.selectRow(&vendors, &context, 1));
    defer openai_models.deinit(gpa);
    try std.testing.expectEqualStrings("Model: openai-api-key", openai_models.title);

    try testing.expectEvent(
        try testing.selectRow(&openai_models, &context, 1),
        .information,
        "Drinky now uses openai-api-key/gpt-5.6-sol.",
    );
    try std.testing.expectEqualStrings("gpt-5.6-sol", rig.choice.model.?.name());
    try std.testing.expectEqual(accounts.testing.openai_api_key, rig.choice.account.?);
    try testing.expectNotice(
        try testing.selectRow(&openai_models, &context, 1),
        .information,
        "Drinky already uses openai-api-key/gpt-5.6-sol.",
    );
    try std.testing.expectEqualStrings("gpt-5.6-sol", rig.choice.model.?.name());
}

test "a model row marks an output limit that no source states" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .variables = &.{.{ "ANTHROPIC_API_KEY", "sk-ant" }} });
    defer rig.deinit();
    try rig.account_rig.seed(accounts.testing.anthropic_api_key, &.{"claude-sonnet-4-6"});
    var context = rig.context();

    const anthropic_models = try forAccount(&context, accounts.testing.anthropic_api_key);
    defer anthropic_models.deinit(gpa);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", anthropic_models.options[1].name);
    try std.testing.expectEqualStrings(extra_output_limit, anthropic_models.options[1].extra.?);
    try std.testing.expect(anthropic_models.options[1].extra_pressure);
}

test "an OpenRouter account opens the author step then the models of that author" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .variables = &.{.{ "OPENROUTER_API_KEY", "sk-or" }} });
    defer rig.deinit();
    try accounts.testing.seedMetadata(
        &rig.registry().catalog,
        &.{ "qwen/qwen-new", "openai/gpt-new", "openai/gpt-old" },
    );
    rig.remembered[accounts.testing.openrouter_api_key] = "openai/gpt-old";
    var context = rig.context();

    const authors = try testing.expectPick(try run(&context));
    defer authors.deinit(gpa);
    try std.testing.expectEqualStrings("Author: openrouter-api-key", authors.title);
    try std.testing.expectEqual(@as(usize, 3), authors.options.len);
    try std.testing.expectEqualStrings("Refresh the model list", authors.options[0].name);
    try std.testing.expectEqualStrings("openai", authors.options[1].name);
    try std.testing.expectEqualStrings("2 models", authors.options[1].extra.?);
    try std.testing.expectEqualStrings("qwen", authors.options[2].name);
    try std.testing.expectEqualStrings("1 model", authors.options[2].extra.?);
    try std.testing.expectEqual(@as(?usize, 1), authors.preselected);
    try std.testing.expect(authors.current == null);
    try std.testing.expectEqual(
        accounts.testing.openrouter_api_key,
        (try testing.selectRow(&authors, &context, 0)).fetch,
    );

    const openai_models = try testing.expectPick(try testing.selectRow(&authors, &context, 1));
    defer openai_models.deinit(gpa);
    try std.testing.expectEqualStrings("Model: openrouter-api-key", openai_models.title);
    try std.testing.expectEqual(@as(usize, 2), openai_models.options.len);
    try std.testing.expectEqualStrings("openai/gpt-new", openai_models.options[0].name);
    try std.testing.expectEqualStrings("openai/gpt-old", openai_models.options[1].name);
    try std.testing.expectEqual(@as(?usize, 1), openai_models.preselected);
    try std.testing.expect(openai_models.reopen == null);
    try testing.expectEvent(
        try testing.selectRow(&openai_models, &context, 1),
        .information,
        "Drinky now uses openrouter-api-key/openai/gpt-old.",
    );
    try std.testing.expectEqualStrings("openai/gpt-old", rig.choice.model.?.name());
    try std.testing.expectEqual(accounts.testing.openrouter_api_key, rig.choice.account.?);

    const marked = try testing.expectPick(try run(&context));
    defer marked.deinit(gpa);
    try std.testing.expectEqual(@as(?usize, 1), marked.current);

    const qwen_models = try testing.expectPick(try testing.selectRow(&authors, &context, 2));
    defer qwen_models.deinit(gpa);
    try std.testing.expectEqualStrings("qwen/qwen-new", qwen_models.options[0].name);
    try testing.expectEvent(
        try testing.selectRow(&qwen_models, &context, 0),
        .information,
        "Drinky now uses openrouter-api-key/qwen/qwen-new.",
    );
    try std.testing.expectEqualStrings("qwen/qwen-new", rig.choice.model.?.name());
}

test "the author step orders the authors by model count and then by their first model" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .variables = &.{.{ "OPENROUTER_API_KEY", "sk-or" }} });
    defer rig.deinit();
    try accounts.testing.seedMetadata(&rig.registry().catalog, &.{
        "gamma/one",
        "beta/one",
        "alpha/one",
        "beta/two",
        "delta/one",
        "alpha/two",
        "delta/two",
        "delta/three",
    });
    var context = rig.context();

    const authors = try testing.expectPick(try run(&context));
    defer authors.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 5), authors.options.len);
    for ([_][]const u8{ "delta", "beta", "alpha", "gamma" }, authors.options[1..]) |author, option|
        try std.testing.expectEqualStrings(author, option.name);

    const alpha_models = try testing.expectPick(try testing.selectRow(&authors, &context, 3));
    defer alpha_models.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), alpha_models.options.len);
    try std.testing.expectEqualStrings("alpha/one", alpha_models.options[0].name);
    try std.testing.expectEqualStrings("alpha/two", alpha_models.options[1].name);
    try testing.expectEvent(
        try testing.selectRow(&alpha_models, &context, 1),
        .information,
        "Drinky now uses openrouter-api-key/alpha/two.",
    );
    try std.testing.expectEqualStrings("alpha/two", rig.choice.model.?.name());
}

test "no authenticated account refuses the line instead of a picker" {
    var rig: testing.Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    var context = rig.context();
    try testing.expectRefusal(
        try run(&context),
        .failure,
        "Sign in to an account",
    );
}

test "a fetch opens the list that arrived and states what it missed" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .variables = &.{.{ "ANTHROPIC_API_KEY", "sk-ant" }} });
    defer rig.deinit();
    try rig.account_rig.seed(
        accounts.testing.anthropic_api_key,
        &.{ "claude-fable-5", "claude-sonnet-4-6" },
    );
    var context = rig.context();

    try testing.expectEvent(
        try fetchOutcome(
            &context,
            accounts.testing.anthropic_api_key,
            &.{ .models_error = error.ConnectionRefused },
        ),
        .failure,
        "Drinky could not fetch the model list of anthropic-api-key because of error " ++
            "ConnectionRefused.",
    );

    const complete = try testing.expectPick(
        try fetchOutcome(&context, accounts.testing.anthropic_api_key, &.{ .count = 2 }),
    );
    defer complete.deinit(gpa);
    try std.testing.expect(complete.report == null);

    const missed: accounts.Registry.Refresh = .{
        .count = 2,
        .metadata_error = error.Timeout,
    };
    const metadata_gone = try testing.expectPick(
        try fetchOutcome(&context, accounts.testing.anthropic_api_key, &missed),
    );
    defer metadata_gone.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), metadata_gone.options.len);
    try std.testing.expectEqualStrings("claude-fable-5", metadata_gone.options[1].name);
    try std.testing.expectEqual(Message.Severity.failure, metadata_gone.report.?.severity);
    try std.testing.expectEqualStrings(
        "Drinky fetched the model list of anthropic-api-key. Drinky could not fetch the public " ++
            "metadata because of error Timeout. The account offers 2 models now.",
        metadata_gone.report.?.content,
    );

    try testing.expectEvent(
        try fetchOutcome(&context, accounts.testing.anthropic_api_key, &.{
            .models_error = error.ConnectionRefused,
            .metadata_save_error = error.StoreBusy,
        }),
        .failure,
        "Drinky could not fetch the model list of anthropic-api-key because of error " ++
            "ConnectionRefused. Drinky could not save the public metadata because of " ++
            "error StoreBusy. The metadata serves this session.",
    );
}

test "every report of a fetch states the writes that failed and an empty list" {
    const gpa = std.testing.allocator;
    const cases = [_]struct {
        result: accounts.Registry.Refresh,
        severity: Message.Severity,
        content: []const u8,
    }{
        .{
            .result = .{ .count = 0 },
            .severity = .warning,
            .content = "Drinky fetched the model list of anthropic-api-key. The account offers " ++
                "no model now.",
        },
        .{
            .result = .{ .count = 2, .metadata_save_error = error.StoreBusy },
            .severity = .failure,
            .content = "Drinky fetched the model list of anthropic-api-key. Drinky could not " ++
                "save the public metadata because of error StoreBusy. The metadata serves this " ++
                "session.",
        },
        .{
            .result = .{ .count = 0, .models_save_error = error.StoreBusy },
            .severity = .failure,
            .content = "Drinky fetched the model list of anthropic-api-key. Drinky could not " ++
                "save the model list because of error StoreBusy. The list serves this " ++
                "session. The account offers no model now.",
        },
        .{
            .result = .{
                .count = 0,
                .metadata_error = error.Timeout,
                .models_save_error = error.StoreBusy,
            },
            .severity = .failure,
            .content = "Drinky fetched the model list of anthropic-api-key. Drinky could not " ++
                "fetch the public metadata because of error Timeout. Drinky could " ++
                "not save the model list because of error StoreBusy. The list serves this " ++
                "session. The account offers no model now.",
        },
        .{
            .result = .{
                .count = 2,
                .models_save_error = error.StoreBusy,
                .metadata_save_error = error.AccessDenied,
            },
            .severity = .failure,
            .content = "Drinky fetched the model list of anthropic-api-key. Drinky could not " ++
                "save the model list because of error StoreBusy. Drinky could not save the " ++
                "public metadata because of error AccessDenied. Both serve this session.",
        },
        .{
            .result = .{ .count = 1, .metadata_error = error.Timeout },
            .severity = .failure,
            .content = "Drinky fetched the model list of anthropic-api-key. Drinky could not " ++
                "fetch the public metadata because of error Timeout. " ++
                "The account offers 1 model now.",
        },
        .{
            .result = .{ .count = 0, .metadata_error = error.Timeout },
            .severity = .failure,
            .content = "Drinky fetched the model list of anthropic-api-key. Drinky could not " ++
                "fetch the public metadata because of error Timeout. " ++
                "The account offers no model now.",
        },
    };
    var rig: testing.Rig = undefined;
    try rig.init(&.{ .variables = &.{.{ "ANTHROPIC_API_KEY", "sk-ant" }} });
    defer rig.deinit();
    var context = rig.context();
    for (cases) |case| {
        const pick = try testing.expectPick(
            try fetchOutcome(&context, accounts.testing.anthropic_api_key, &case.result),
        );
        defer pick.deinit(gpa);
        try std.testing.expectEqual(case.severity, pick.report.?.severity);
        try std.testing.expectEqualStrings(case.content, pick.report.?.content);
    }
}

test "the active mark matches the account, not just the model name" {
    const gpa = std.testing.allocator;
    var rig: testing.Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "ANTHROPIC_API_KEY", "sk-ant" }},
        .store =
        \\{ "anthropic-plan":
        \\    { "access": "a", "refresh": "r", "expires_ms": 4102444800000 } }
        ,
    });
    defer rig.deinit();
    try rig.account_rig.seed(accounts.testing.anthropic_plan, &.{"claude-sonnet-4-6"});
    try rig.account_rig.seed(accounts.testing.anthropic_api_key, &.{"claude-sonnet-4-6"});
    rig.choice.account = accounts.testing.anthropic_plan;
    rig.choice.model = rig.registry().findModel(
        accounts.testing.anthropic_plan,
        "claude-sonnet-4-6",
    );
    var context = rig.context();

    const step = try testing.expectPick(try run(&context));
    defer step.deinit(gpa);
    try std.testing.expectEqualStrings("anthropic-plan", step.options[step.current.?].name);

    const plan_models = try testing.expectPick(try testing.selectRow(&step, &context, 0));
    defer plan_models.deinit(gpa);
    try std.testing.expectEqualStrings(
        "claude-sonnet-4-6",
        plan_models.options[plan_models.current.?].name,
    );

    const key_models = try testing.expectPick(try testing.selectRow(&step, &context, 1));
    defer key_models.deinit(gpa);
    try std.testing.expect(key_models.current == null);
}
