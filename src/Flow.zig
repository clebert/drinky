const std = @import("std");
const application = @import("application");
const format = @import("format.zig");
const reference = @import("reference.zig");

const accounts = @import("accounts");
const core = @import("core");
const providers = @import("providers");

const ui = @import("ui/root.zig");

const Flow = @This();

pub const fetch_wait_text = "Drinky fetches the model list.";
const trail_max = 8;
const fetch_row = "Fetch the model list";
const refresh_row = "Refresh the model list";
const output_limit_extra = "The output limit is unknown.";
const fold_extra = "The model folds this level to {s}.";
const drop_extra = "The model drops this level.";

gpa: std.mem.Allocator,
step: Step = .help,
title: std.ArrayList(u8) = .empty,
options: std.ArrayList(ui.Picker.Option) = .empty,
targets: std.ArrayList(Target) = .empty,
author: std.ArrayList(u8) = .empty,
trail: [trail_max]Entry = undefined,
depth: usize = 0,
fetch: ?Fetch = null,

pub const Step = union(enum) {
    help,
    vendor,
    account: usize,
    author: usize,
    author_models: usize,
    models: usize,
    effort,
    login,
    logout,
    skill,
    rewind,

    fn reopens(self: Step) bool {
        return switch (self) {
            .help, .vendor, .account, .author, .models => true,
            .author_models, .effort, .login, .logout, .skill, .rewind => false,
        };
    }

    pub fn cancellation(self: Step) []const u8 {
        return switch (self) {
            .help => "You canceled the command selection.",
            .vendor, .account, .author, .author_models, .models => "You canceled the model " ++
                "selection.",
            .effort => "You canceled the effort selection.",
            .login => "You canceled the sign-in selection.",
            .logout => "You canceled the sign-out selection.",
            .skill => "You canceled the skill selection.",
            .rewind => "You canceled the prompt selection.",
        };
    }
};

const Target = union(enum) {
    command: reference.Command,
    vendor: usize,
    account: usize,
    fetch: usize,
    author: Named,
    model: Named,
    effort: application.Effort,
    sign_in: usize,
    sign_out: usize,
    skill: []const u8,
    turn: Turn,

    const Named = struct { account: usize, name: []const u8 };
    const Turn = struct { id: u64, mutated: bool };

    fn deinit(self: *const Target, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .author, .model => |named| gpa.free(named.name),
            .skill => |skill_name| gpa.free(skill_name),
            .command, .vendor, .account, .fetch, .effort, .sign_in, .sign_out, .turn => {},
        }
    }
};

pub const Fetch = struct {
    operation: u64,
    exit: ?Exit = null,

    pub const Exit = enum { step, command };
};

const Entry = struct { step: Step, cursor: usize };

const Shown = struct {
    title: []const u8,
    options: []const ui.Picker.Option,
    current: ?usize = null,
    preselected: ?usize = null,
};

const AuthorRow = struct {
    name: []const u8,
    count: usize,
    first: usize,

    fn ranksBefore(_: void, left: AuthorRow, right: AuthorRow) bool {
        if (left.count != right.count) return left.count > right.count;
        return left.first < right.first;
    }
};

pub fn init(gpa: std.mem.Allocator) Flow {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Flow) void {
    self.clearRows();
    self.title.deinit(self.gpa);
    self.options.deinit(self.gpa);
    self.targets.deinit(self.gpa);
    self.author.deinit(self.gpa);
}

pub fn target(self: *const Flow, row: usize) Target {
    return self.targets.items[row];
}

pub fn push(self: *Flow, cursor: usize) void {
    std.debug.assert(self.step.reopens() and self.depth < trail_max);
    self.trail[self.depth] = .{ .step = self.step, .cursor = cursor };
    self.depth += 1;
}

pub fn back(self: *Flow) ?Entry {
    if (self.depth == 0) return null;
    self.depth -= 1;
    return self.trail[self.depth];
}

pub fn setAuthor(self: *Flow, name: []const u8) error{OutOfMemory}!void {
    self.author.clearRetainingCapacity();
    try self.author.appendSlice(self.gpa, name);
}

pub fn resolve(controller: *application.Controller, step: Step) Step {
    const facts = controller.listAccounts();
    var resolved = step;
    if (resolved == .vendor) {
        const vendor = onlyMatch(&facts, null) orelse return resolved;
        resolved = .{ .account = vendor };
    }
    if (resolved == .account) {
        const account = onlyMatch(&facts, resolved.account) orelse return resolved;
        resolved = forAccount(&facts, account);
    }
    return resolved;
}

fn onlyMatch(facts: []const application.query.Account, maybe_vendor: ?usize) ?usize {
    var only: ?usize = null;
    for (facts, 0..) |*fact, index| {
        if (!fact.authenticated) continue;
        const counted = if (maybe_vendor) |vendor|
            sameVendor(facts, index, vendor)
        else
            firstOfVendor(facts, index) == index;
        if (!counted) continue;
        if (only != null) return null;
        only = index;
    }
    return only;
}

pub fn forAccount(facts: []const application.query.Account, account: usize) Step {
    return if (facts[account].authors) .{ .author = account } else .{ .models = account };
}

pub fn show(
    self: *Flow,
    controller: *application.Controller,
    choice: *const application.Choice,
    step: Step,
) error{OutOfMemory}!Shown {
    self.clearRows();
    self.title.clearRetainingCapacity();
    self.step = step;
    const facts = controller.listAccounts();
    var shown: Shown = .{ .title = "", .options = &.{} };
    switch (step) {
        .help => {
            try self.setTitle("Command", .{});
            for (std.enums.values(reference.Command)) |command| {
                if (command == .help) continue;
                const summary = reference.commands.get(command).summary;
                const name = try self.gpa.print("/{s}", .{@tagName(command)});
                defer self.gpa.free(name);
                const extra = try self.gpa.print("{s}.", .{summary});
                defer self.gpa.free(extra);
                try self.addRow(.{ .command = command }, &.{ .name = name, .extra = extra });
            }
        },
        .vendor => {
            try self.setTitle("Vendor", .{});
            for (&facts, 0..) |*fact, index| {
                if (!fact.authenticated or firstOfVendor(&facts, index) != index) continue;
                if (choice.account) |active| {
                    if (sameVendor(&facts, active, index)) shown.current = self.targets.items.len;
                }
                try self.addRow(.{ .vendor = index }, &.{ .name = fact.vendor });
            }
        },
        .account => |vendor| {
            try self.setTitle("Account", .{});
            for (&facts, 0..) |*fact, index| {
                if (!fact.authenticated or !sameVendor(&facts, index, vendor)) continue;
                if (choice.isActive(index)) shown.current = self.targets.items.len;
                try self.addRow(.{ .account = index }, &.{ .name = fact.id });
            }
        },
        .models => |account| {
            try self.setTitle("Model: {s}", .{facts[account].id});
            const remembered = try application.Record.dupeData(
                self.gpa,
                if (facts[account].remembered) |saved| saved.model else null,
            );
            defer application.Record.freeData(self.gpa, &remembered);
            const models = controller.listModels(account);
            try self.addFetchRow(account, models.len);
            for (models) |*model| {
                if (choice.usesModel(account, model.name)) shown.current = self.targets.items.len;
                if (same(remembered, model.name)) shown.preselected = self.targets.items.len;
                try self.addModelRow(account, model);
            }
        },
        .author => |account| try self.showAuthors(controller, choice, &facts, account, &shown),
        .author_models => |account| {
            try self.setTitle("Model: {s}", .{facts[account].id});
            const remembered = try application.Record.dupeData(
                self.gpa,
                if (facts[account].remembered) |saved| saved.model else null,
            );
            defer application.Record.freeData(self.gpa, &remembered);
            for (controller.listModels(account)) |*model| {
                if (!std.mem.eql(u8, model.author, self.author.items)) continue;
                if (choice.usesModel(account, model.name)) shown.current = self.targets.items.len;
                if (same(remembered, model.name)) shown.preselected = self.targets.items.len;
                try self.addModelRow(account, model);
            }
        },
        .effort => {
            try self.setTitle("Effort", .{});
            const effort = controller.effort();
            for (application.query.levels, 0..) |level, index| {
                if (level == effort.requested) shown.current = index;
                try self.addEffortRow(&effort, index);
            }
        },
        .login => {
            try self.setTitle("Sign in", .{});
            for (&facts, 0..) |*fact, index| {
                const active = choice.isActive(index);
                if (active) shown.current = index;
                const tag: ?[]const u8 = if (active)
                    null
                else if (fact.authenticated)
                    (if (fact.login) "Signed in" else "Set")
                else if (fact.load_failed)
                    "Not loaded"
                else
                    null;
                try self.addRow(.{ .sign_in = index }, &.{
                    .name = fact.id,
                    .tag = tag,
                    .tag_pressure = !active and !fact.authenticated and fact.load_failed,
                });
            }
        },
        .logout => {
            try self.setTitle("Sign out", .{});
            for (&facts, 0..) |*fact, index| {
                if (!fact.login or !fact.authenticated) continue;
                try self.addRow(.{ .sign_out = index }, &.{ .name = fact.id });
            }
        },
        .skill => {
            try self.setTitle("Skill", .{});
            const skills = controller.listSkills();
            const order = try self.gpa.alloc(usize, skills.len);
            defer self.gpa.free(order);
            for (order, 0..) |*position, index| position.* = index;
            std.mem.sort(usize, order, skills, skillBefore);
            for (order) |index| {
                const skill = &skills[index];
                const name = try self.gpa.print(
                    "{s}{s}",
                    .{ "/" ++ reference.skill_prefix, skill.name },
                );
                defer self.gpa.free(name);
                try self.addRow(.{ .skill = skill.name }, &.{
                    .name = name,
                    .extra = firstSentence(skill.description),
                });
            }
        },
        .rewind => {
            try self.setTitle("Prompt", .{});
            const turns = controller.listTurns();
            for (turns) |turn| {
                const copy = try self.gpa.dupe(u8, turn.line);
                defer self.gpa.free(copy);
                try self.addRow(
                    .{ .turn = .{ .id = turn.id, .mutated = turn.drops_mutating_turn } },
                    &.{ .name = format.singleLine(copy) },
                );
            }
            if (self.targets.items.len > 0) shown.preselected = self.targets.items.len - 1;
        },
    }
    shown.title = self.title.items;
    shown.options = self.options.items;
    return shown;
}

fn showAuthors(
    self: *Flow,
    controller: *application.Controller,
    choice: *const application.Choice,
    facts: []const application.query.Account,
    account: usize,
    shown: *Shown,
) error{OutOfMemory}!void {
    try self.setTitle("Author: {s}", .{facts[account].id});
    const remembered = try application.Record.dupeData(
        self.gpa,
        if (facts[account].remembered) |saved| saved.author else null,
    );
    defer application.Record.freeData(self.gpa, &remembered);
    const models = controller.listModels(account);
    try self.addFetchRow(account, models.len);
    var current_author: ?[]const u8 = null;
    for (models) |*model| {
        if (choice.usesModel(account, model.name)) current_author = model.author;
    }
    var rows: std.ArrayList(AuthorRow) = .empty;
    defer rows.deinit(self.gpa);
    for (models, 0..) |*model, index| {
        for (rows.items) |*row| {
            if (!std.mem.eql(u8, row.name, model.author)) continue;
            row.count += 1;
            break;
        } else try rows.append(self.gpa, .{ .name = model.author, .count = 1, .first = index });
    }
    std.mem.sort(AuthorRow, rows.items, {}, AuthorRow.ranksBefore);
    for (rows.items) |row| {
        if (current_author) |author| {
            if (std.mem.eql(u8, author, row.name)) shown.current = self.targets.items.len;
        }
        if (same(remembered, row.name)) shown.preselected = self.targets.items.len;
        const extra = try self.gpa.print(
            "{d} model{s}",
            .{ row.count, application.support.pluralSuffix(row.count) },
        );
        defer self.gpa.free(extra);
        try self.addRow(
            .{ .author = .{ .account = account, .name = row.name } },
            &.{ .name = row.name, .extra = extra },
        );
    }
}

fn same(maybe_name: ?[]const u8, name: []const u8) bool {
    const value = maybe_name orelse return false;
    return std.mem.eql(u8, value, name);
}

fn clearRows(self: *Flow) void {
    for (self.options.items) |*option| option.deinit(self.gpa);
    self.options.clearRetainingCapacity();
    for (self.targets.items) |*item| item.deinit(self.gpa);
    self.targets.clearRetainingCapacity();
}

fn setTitle(self: *Flow, comptime template: []const u8, args: anytype) error{OutOfMemory}!void {
    var out: std.Io.Writer.Allocating = .fromArrayList(self.gpa, &self.title);
    defer self.title = out.toArrayList();
    out.writer.print(template, args) catch return error.OutOfMemory;
}

fn addRow(self: *Flow, item: Target, row: *const ui.Picker.Option) error{OutOfMemory}!void {
    try self.options.ensureUnusedCapacity(self.gpa, 1);
    try self.targets.ensureUnusedCapacity(self.gpa, 1);
    const option = try row.dupe(self.gpa);
    errdefer option.deinit(self.gpa);
    const owned: Target = switch (item) {
        .author => |named| .{ .author = .{
            .account = named.account,
            .name = try self.gpa.dupe(u8, named.name),
        } },
        .model => |named| .{ .model = .{
            .account = named.account,
            .name = try self.gpa.dupe(u8, named.name),
        } },
        .skill => |name| .{ .skill = try self.gpa.dupe(u8, name) },
        .command, .vendor, .account, .fetch, .effort, .sign_in, .sign_out, .turn => item,
    };
    self.options.appendAssumeCapacity(option);
    self.targets.appendAssumeCapacity(owned);
}

fn addFetchRow(self: *Flow, account: usize, count: usize) error{OutOfMemory}!void {
    const text = if (count == 0) fetch_row else refresh_row;
    try self.addRow(.{ .fetch = account }, &.{ .name = text });
}

fn addModelRow(
    self: *Flow,
    account: usize,
    model: *const application.query.Model,
) error{OutOfMemory}!void {
    try self.addRow(.{ .model = .{ .account = account, .name = model.name } }, &.{
        .name = model.name,
        .extra = if (model.output_limit_unknown) output_limit_extra else null,
        .extra_pressure = model.output_limit_unknown,
    });
}

fn addEffortRow(
    self: *Flow,
    effort: *const application.query.Effort,
    index: usize,
) error{OutOfMemory}!void {
    const level = application.query.levels[index];
    const item: Target = .{ .effort = level };
    const folds = effort.folds orelse return self.addRow(item, &.{ .name = @tagName(level) });
    const fold = folds[index] orelse return self.addRow(item, &.{
        .name = @tagName(level),
        .extra = drop_extra,
        .extra_pressure = true,
    });
    if (fold == level) return self.addRow(item, &.{ .name = @tagName(level) });
    const extra = try self.gpa.print(fold_extra, .{@tagName(fold)});
    defer self.gpa.free(extra);
    try self.addRow(item, &.{ .name = @tagName(level), .extra = extra });
}

fn firstOfVendor(facts: []const application.query.Account, index: usize) usize {
    for (facts[0..index], 0..) |*fact, earlier| {
        if (fact.authenticated and sameVendor(facts, earlier, index)) return earlier;
    }
    return index;
}

fn sameVendor(facts: []const application.query.Account, left: usize, right: usize) bool {
    return std.mem.eql(u8, facts[left].vendor, facts[right].vendor);
}

fn skillBefore(skills: []const application.query.Skill, left: usize, right: usize) bool {
    return std.mem.lessThan(u8, skills[left].name, skills[right].name);
}

fn firstSentence(description: []const u8) []const u8 {
    var index: usize = 0;
    while (std.mem.findScalarPos(u8, description, index, '.')) |stop| {
        const end = stop + 1;
        index = end;
        if (end == description.len) break;
        if (std.mem.findScalar(u8, application.reference.blank_bytes, description[end]) == null)
            continue;
        const rest = description[end..];
        const next = std.mem.findNone(u8, rest, application.reference.blank_bytes) orelse break;
        const start = description[end + next];
        if (start < 'a' or start > 'z') return description[0..end];
    }
    return description;
}

test "the model flow resolves single choices and lists vendors, accounts, and model rows" {
    var rig: application.testing.Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "ANTHROPIC_API_KEY", "sk-ant" }},
        .store = "{\"anthropic-plan\":{\"access\":\"a\",\"refresh\":\"r\"," ++
            "\"expires_ms\":4102444800000}}",
        .models = &.{
            .{ .account = accounts.testing.openai_api_key, .names = &.{"gpt-5.6-sol"} },
            .{
                .account = accounts.testing.anthropic_api_key,
                .names = &.{ "claude-fable-5", "claude-sonnet-4-6" },
            },
        },
    });
    defer rig.deinit();
    const choice = try currentChoice(&rig);
    var flow: Flow = .init(std.testing.allocator);
    defer flow.deinit();

    try std.testing.expectEqual(Step.vendor, resolve(rig.controller, .vendor));
    const vendors = try flow.show(rig.controller, &choice, .vendor);
    try expectRows(&vendors, "Vendor", &.{ "anthropic", "openai" });
    try std.testing.expectEqual(@as(?usize, 1), vendors.current);
    const vendor = flow.target(0).vendor;

    const step = resolve(rig.controller, .{ .account = vendor });
    const listed = try flow.show(rig.controller, &choice, step);
    try expectRows(&listed, "Account", &.{ "anthropic-plan", "anthropic-api-key" });
    try std.testing.expect(listed.current == null);

    const models = try flow.show(rig.controller, &choice, .{
        .models = accounts.testing.anthropic_api_key,
    });
    try expectRows(&models, "Model: anthropic-api-key", &.{
        "Refresh the model list",
        "claude-fable-5",
        "claude-sonnet-4-6",
    });
    try std.testing.expectEqualStrings(output_limit_extra, models.options[1].extra.?);
    try std.testing.expect(models.options[1].extra_pressure);
    try std.testing.expectEqual(@as(?usize, 1), models.preselected);
    try std.testing.expect(models.current == null);
    try std.testing.expectEqual(
        accounts.testing.anthropic_api_key,
        flow.target(0).fetch,
    );
    try std.testing.expectEqualStrings("claude-sonnet-4-6", flow.target(2).model.name);

    const empty = try flow.show(rig.controller, &choice, .{
        .models = accounts.testing.anthropic_plan,
    });
    try expectRows(&empty, "Model: anthropic-plan", &.{"Fetch the model list"});

    var alone: application.testing.Rig = undefined;
    try alone.init(&.{});
    defer alone.deinit();
    try std.testing.expectEqual(
        Step{ .models = accounts.testing.openai_api_key },
        resolve(alone.controller, .vendor),
    );
    const own = try flow.show(alone.controller, &try currentChoice(&alone), .{
        .models = accounts.testing.openai_api_key,
    });
    try std.testing.expectEqual(@as(?usize, 1), own.current);
}

test "the current mark follows the active account and not only the model name" {
    var rig: application.testing.Rig = undefined;
    try rig.init(&.{
        .authenticated = false,
        .variables = &.{.{ "ANTHROPIC_API_KEY", "sk-ant" }},
        .store = "{\"anthropic-plan\":{\"access\":\"a\",\"refresh\":\"r\"," ++
            "\"expires_ms\":4102444800000}}",
        .selected_account = accounts.testing.anthropic_plan,
        .models = &.{
            .{ .account = accounts.testing.anthropic_plan, .names = &.{"claude-sonnet-4-6"} },
            .{ .account = accounts.testing.anthropic_api_key, .names = &.{"claude-sonnet-4-6"} },
        },
    });
    defer rig.deinit();
    const choice = try currentChoice(&rig);
    var flow: Flow = .init(std.testing.allocator);
    defer flow.deinit();
    const step = resolve(rig.controller, .vendor);
    const listed = try flow.show(rig.controller, &choice, step);
    try expectRows(&listed, "Account", &.{ "anthropic-plan", "anthropic-api-key" });
    try std.testing.expectEqual(@as(?usize, 0), listed.current);
    const plan = try flow.show(rig.controller, &choice, .{
        .models = accounts.testing.anthropic_plan,
    });
    try std.testing.expectEqual(@as(?usize, 1), plan.current);
    const key = try flow.show(rig.controller, &choice, .{
        .models = accounts.testing.anthropic_api_key,
    });
    try std.testing.expect(key.current == null);
}

test "the author step ranks authors and preselects a remembered author absent from the list" {
    var rig: application.testing.Rig = undefined;
    try rig.init(&.{
        .variables = &.{.{ "OPENROUTER_API_KEY", "sk-or" }},
        .remembered = &.{.{
            .account = accounts.testing.openrouter_api_key,
            .name = "beta/gone",
        }},
        .files = &.{.{ ".drinky/metadata.json", ranked_metadata }},
    });
    defer rig.deinit();
    var choice = try currentChoice(&rig);
    var flow: Flow = .init(std.testing.allocator);
    defer flow.deinit();
    const account = accounts.testing.openrouter_api_key;

    const authors = try flow.show(rig.controller, &choice, .{ .author = account });
    try expectRows(&authors, "Author: openrouter-api-key", &.{
        "Refresh the model list",
        "delta",
        "beta",
        "alpha",
        "gamma",
    });
    try std.testing.expectEqualStrings("3 models", authors.options[1].extra.?);
    try std.testing.expectEqualStrings("1 model", authors.options[4].extra.?);
    try std.testing.expectEqual(@as(?usize, 2), authors.preselected);
    try std.testing.expect(authors.current == null);

    try flow.setAuthor(flow.target(3).author.name);
    const alpha = try flow.show(rig.controller, &choice, .{ .author_models = account });
    try expectRows(&alpha, "Model: openrouter-api-key", &.{ "alpha/one", "alpha/two" });
    try std.testing.expect(alpha.preselected == null);

    try std.testing.expect(rig.send(&.{ .select_model = .{
        .account = account,
        .model = "alpha/two",
    } }).accepted());
    choice = try currentChoice(&rig);
    const marked = try flow.show(rig.controller, &choice, .{ .author = account });
    try std.testing.expectEqual(@as(?usize, 3), marked.current);
    const models = try flow.show(rig.controller, &choice, .{ .author_models = account });
    try std.testing.expectEqual(@as(?usize, 1), models.current);
    const effort = try flow.show(rig.controller, &choice, .effort);
    for (effort.options) |option| {
        try std.testing.expectEqualStrings(drop_extra, option.extra.?);
        try std.testing.expect(option.extra_pressure);
    }
}

const ranked_metadata = metadata: {
    const names = [_][]const u8{
        "gamma/one", "beta/one",  "alpha/one", "beta/two",
        "delta/one", "alpha/two", "delta/two", "delta/three",
    };
    var text: []const u8 = "{\"openrouter\":{\"models\":[";
    for (names, 0..) |name, index| {
        const separator = if (index == 0) "" else ",";
        text = text ++ separator ++ "{\"name\":\"" ++ name ++
            "\",\"context_window\":1,\"tools\":\"supported\"}";
    }
    break :metadata text ++ "]}}";
};

test "the effort rows mark the current level and each level that the model folds" {
    var rig: application.testing.Rig = undefined;
    try rig.init(&.{});
    defer rig.deinit();
    var flow: Flow = .init(std.testing.allocator);
    defer flow.deinit();
    const shown = try flow.show(rig.controller, &try currentChoice(&rig), .effort);
    try expectRows(&shown, "Effort", &.{ "low", "medium", "high", "xhigh", "max" });
    try std.testing.expectEqual(@as(?usize, 2), shown.current);
    const extras = [_]?[]const u8{
        null,
        "The model folds this level to low.",
        null,
        "The model folds this level to high.",
        "The model folds this level to high.",
    };
    for (shown.options, extras) |option, extra| {
        try std.testing.expect(!option.extra_pressure);
        const expected = extra orelse {
            try std.testing.expect(option.extra == null);
            continue;
        };
        try std.testing.expectEqualStrings(expected, option.extra.?);
    }
    try std.testing.expectEqual(application.Effort.xhigh, flow.target(3).effort);
}

test "the sign-in rows mark the active, the signed-in, the set, and the failed accounts" {
    var rig: application.testing.Rig = undefined;
    try rig.init(&.{
        .variables = &.{
            .{ "ANTHROPIC_API_KEY", "sk-ant" },
            .{ "GOOGLE_APPLICATION_CREDENTIALS", "key.json" },
            .{ "GOOGLE_CLOUD_LOCATION", "europe-west4" },
        },
        .store = "{\"anthropic-plan\":{\"access\":\"a\",\"refresh\":\"r\"," ++
            "\"expires_ms\":4102444800000}}",
    });
    defer rig.deinit();
    var flow: Flow = .init(std.testing.allocator);
    defer flow.deinit();
    const choice = try currentChoice(&rig);
    const login = try flow.show(rig.controller, &choice, .login);
    try std.testing.expectEqualStrings("Sign in", login.title);
    try std.testing.expectEqual(application.query.account_count, login.options.len);
    try std.testing.expectEqual(@as(?usize, accounts.testing.openai_api_key), login.current);
    const tags = [_]struct { account: usize, tag: ?[]const u8, pressure: bool }{
        .{ .account = accounts.testing.anthropic_plan, .tag = "Signed in", .pressure = false },
        .{ .account = accounts.testing.anthropic_api, .tag = null, .pressure = false },
        .{ .account = accounts.testing.anthropic_api_key, .tag = "Set", .pressure = false },
        .{ .account = accounts.testing.openai_api_key, .tag = null, .pressure = false },
        .{ .account = accounts.testing.google_cloud_key, .tag = "Not loaded", .pressure = true },
    };
    for (tags) |case| {
        const option = login.options[case.account];
        try std.testing.expectEqual(case.pressure, option.tag_pressure);
        const tag = case.tag orelse {
            try std.testing.expect(option.tag == null);
            continue;
        };
        try std.testing.expectEqualStrings(tag, option.tag.?);
    }
    try std.testing.expectEqual(accounts.testing.anthropic_plan, flow.target(0).sign_in);
    const logout = try flow.show(rig.controller, &choice, .logout);
    try expectRows(&logout, "Sign out", &.{"anthropic-plan"});
    try std.testing.expectEqual(accounts.testing.anthropic_plan, flow.target(0).sign_out);
}

test "the skill rows sort by name and hold the first sentence of each description" {
    const cases = [_]struct { name: []const u8, description: []const u8, summary: []const u8 }{
        .{ .name = "alpha", .description = "One sentence.", .summary = "One sentence." },
        .{ .name = "bravo", .description = "First. Second.", .summary = "First." },
        .{ .name = "charlie", .description = "no end at all", .summary = "no end at all" },
        .{
            .name = "delta",
            .description = "Use e.g. this form. And not that one.",
            .summary = "Use e.g. this form.",
        },
        .{ .name = "echo", .description = "First. second one.", .summary = "First. second one." },
    };
    var files: [cases.len][2][]const u8 = undefined;
    var paths: [cases.len][64]u8 = undefined;
    var sources: [cases.len][256]u8 = undefined;
    for (cases, &files, &paths, &sources, 0..) |case, *file, *path, *source, index| {
        const position = cases.len - 1 - index;
        file.* = .{
            try std.fmt.bufPrint(path, ".agents/skills/{d}/SKILL.md", .{position}),
            try std.fmt.bufPrint(
                source,
                "---\nname: {s}\ndescription: {s}\n---\nBody.\n",
                .{ case.name, case.description },
            ),
        };
    }
    var rig: application.testing.Rig = undefined;
    try rig.init(&.{ .files = &files });
    defer rig.deinit();
    var flow: Flow = .init(std.testing.allocator);
    defer flow.deinit();
    const shown = try flow.show(rig.controller, &try currentChoice(&rig), .skill);
    try std.testing.expectEqualStrings("Skill", shown.title);
    try std.testing.expectEqual(cases.len, shown.options.len);
    for (cases, shown.options, 0..) |case, option, row| {
        const name = try std.fmt.allocPrint(std.testing.allocator, "/skill:{s}", .{case.name});
        defer std.testing.allocator.free(name);
        try std.testing.expectEqualStrings(name, option.name);
        try std.testing.expectEqualStrings(case.summary, option.extra.?);
        try std.testing.expectEqualStrings(case.name, flow.target(row).skill);
    }
}

test "the prompt rows show each typed line on one row and carry the consequence of a rewind" {
    var rig: application.testing.Rig = undefined;
    try rig.init(&.{ .replies = &.{
        .{ .body = providers.testing.reply_stream },
        .{ .body = application.testing.write_call_stream },
        .{ .body = providers.testing.reply_stream },
        .{ .body = providers.testing.reply_stream },
    } });
    defer rig.deinit();
    for ([_][]const u8{ "first", "\n  look at this:  \n\n \t\n  the  file\r\n\n", "last" }) |line| {
        _ = rig.send(&.{ .send_message = line });
        try rig.expectTurn(.stopped);
    }
    var flow: Flow = .init(std.testing.allocator);
    defer flow.deinit();
    const shown = try flow.show(rig.controller, &try currentChoice(&rig), .rewind);
    try expectRows(&shown, "Prompt", &.{ "first", "look at this: the file", "last" });
    try std.testing.expectEqual(@as(?usize, 2), shown.preselected);
    try std.testing.expect(shown.current == null);
    for ([_]bool{ true, true, false }, 0..) |mutated, row|
        try std.testing.expectEqual(mutated, flow.target(row).turn.mutated);
}

test "the rows of each step release every partial allocation" {
    var rig: application.testing.Rig = undefined;
    try rig.init(&.{
        .files = &.{.{
            ".agents/skills/demo/SKILL.md",
            "---\nname: demo\ndescription: Demo. More.\n---\nBody.\n",
        }},
        .replies = &.{.{ .body = providers.testing.reply_stream }},
    });
    defer rig.deinit();
    _ = rig.send(&.{ .send_message = "first" });
    try rig.expectTurn(.stopped);
    const choice = try currentChoice(&rig);
    try std.testing.checkAllAllocationFailures(
        core.testing.no_resize_allocator,
        checkRows,
        .{ rig.controller, &choice },
    );
}

fn checkRows(
    gpa: std.mem.Allocator,
    controller: *application.Controller,
    choice: *const application.Choice,
) !void {
    var flow: Flow = .init(gpa);
    defer flow.deinit();
    const account = accounts.testing.openai_api_key;
    const steps = [_]Step{
        .help,
        .vendor,
        .{ .account = account },
        .{ .models = account },
        .{ .author = account },
        .effort,
        .login,
        .logout,
        .skill,
        .rewind,
    };
    for (steps) |step| _ = try flow.show(controller, choice, step);
    try flow.setAuthor("gpt-5.6-sol");
    _ = try flow.show(controller, choice, .{ .author_models = account });
}

fn currentChoice(rig: *application.testing.Rig) !application.Choice {
    const snapshot = try rig.snapshot();
    defer snapshot.deinit(std.testing.allocator);
    return snapshot.state.choice;
}

fn expectRows(shown: *const Shown, title: []const u8, names: []const []const u8) !void {
    try std.testing.expectEqualStrings(title, shown.title);
    try std.testing.expectEqual(names.len, shown.options.len);
    for (names, shown.options) |name, option| try std.testing.expectEqualStrings(name, option.name);
}
