const std = @import("std");

const accounts = @import("accounts");
const core = @import("core");
const tools = @import("tools");

const Choice = @import("Choice.zig");
const Config = @import("Config.zig");
const discovery = @import("discovery/root.zig");

pub const account_count = accounts.Account.table.len;
pub const levels = std.enums.values(core.Provider.Effort);

pub const Account = struct {
    id: []const u8,
    vendor: []const u8,
    authenticated: bool,
    login: bool,
    load_failed: bool,
    authors: bool,
    remembered: ?Remembered,

    pub const Remembered = struct { model: []const u8, author: []const u8 };
};

pub const Model = struct {
    name: []const u8,
    author: []const u8,
    output_limit_unknown: bool,
};

pub const Effort = struct {
    requested: core.Provider.Effort,
    folds: ?[levels.len]?core.Provider.Effort,
};

pub const Turn = struct {
    id: u64,
    line: []const u8,
    drops_mutating_turn: bool,
};

pub const Skill = struct {
    name: []const u8,
    description: []const u8,
};

pub const Documents = struct {
    system_prompt: []const u8,
    user_instructions: []const discovery.instructions.File,
    project_instructions: []const discovery.instructions.File,
    skills: []const discovery.skills.Skill,
    required_skills: []const tools.SkillGuard.Rule,
    required_missing: []const Config.RequiredSkill,
};

comptime {
    for (accounts.Account.table[1..], 0..) |*row, index| {
        const previous = accounts.Account.table[index].vendor;
        if (@backingInt(row.vendor) < @backingInt(previous))
            @compileError("the account table must group its rows in vendor order");
    }
}

pub fn accountId(account: usize) []const u8 {
    return accounts.Account.table[account].id;
}

pub fn accountSetting(account: usize) ?[]const u8 {
    return accounts.Account.table[account].setting();
}

pub fn accountsOf(
    registry: *accounts.Registry,
    remembered_model_names: *const [account_count]?[]const u8,
) [account_count]Account {
    var result: [account_count]Account = undefined;
    const rows = &accounts.Account.table;
    for (rows, &result, remembered_model_names, 0..) |*row, *fact, remembered, index| {
        fact.* = .{
            .id = row.id,
            .vendor = @tagName(row.vendor),
            .authenticated = registry.isAuthenticated(index),
            .login = row.hasLogin(),
            .load_failed = registry.loadError(index) != null,
            .authors = row.model_source == .public,
            .remembered = if (remembered) |name|
                .{ .model = name, .author = accounts.Metadata.authorOf(name) }
            else
                null,
        };
    }
    return result;
}

pub fn modelOf(account: usize, model: *const accounts.Model) Model {
    return .{
        .name = model.name(),
        .author = accounts.Metadata.authorOf(model.name()),
        .output_limit_unknown = model.outputLimitUnknown(&accounts.Account.table[account]),
    };
}

pub fn effortOf(choice: *const Choice) Effort {
    const model = if (choice.model) |*model| model else return .{
        .requested = choice.effort,
        .folds = null,
    };
    var folds: [levels.len]?core.Provider.Effort = undefined;
    for (levels, &folds) |level, *fold| fold.* = model.fold(level);
    return .{ .requested = choice.effort, .folds = folds };
}
