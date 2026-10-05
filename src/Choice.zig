const std = @import("std");

const accounts = @import("accounts");
const core = @import("core");

const Choice = @This();

account: ?usize = null,
model: ?accounts.Model = null,
effort: core.Provider.Effort,

pub fn adopt(
    self: *Choice,
    registry: *accounts.Registry,
    remembered_model_names: *const [accounts.Account.table.len]?[]const u8,
    maybe_account: ?usize,
) void {
    self.account = maybe_account;
    self.model = null;
    const account = maybe_account orelse return;
    const name = remembered_model_names[account] orelse return;
    self.model = registry.findModel(account, name);
}

pub fn eql(self: *const Choice, other: *const Choice) bool {
    if (self.account != other.account or self.effort != other.effort) return false;
    const model = self.model orelse return other.model == null;
    const other_model = other.model orelse return false;
    return model.eql(&other_model);
}

pub fn isActive(self: *const Choice, account: usize) bool {
    return self.account == account;
}

pub fn usesModel(self: *const Choice, account: usize, name: []const u8) bool {
    const model = self.model orelse return false;
    return self.isActive(account) and model.sameName(name);
}

pub fn modelName(self: *const Choice) ?[]const u8 {
    const model = if (self.model) |*model| model else return null;
    return model.name();
}

pub fn accountId(self: *const Choice) ?[]const u8 {
    const account = self.account orelse return null;
    return accounts.Account.table[account].id;
}

pub fn fold(self: *const Choice) ?core.Provider.Effort {
    const model = self.model orelse return null;
    return model.fold(self.effort);
}

test "a choice names its account, its model, and the effort the model takes" {
    var choice: Choice = .{ .effort = .high };
    try std.testing.expect(!choice.isActive(0));
    try std.testing.expect(choice.accountId() == null);
    try std.testing.expect(choice.fold() == null);
    try std.testing.expect(choice.modelName() == null);

    const plan = accounts.Account.index("anthropic-plan").?;
    choice.account = plan;
    var model = try accounts.Model.init("claude-opus-5");
    model.addEffort(.low);
    model.addEffort(.high);
    choice.model = model;
    try std.testing.expect(choice.isActive(plan));
    try std.testing.expect(choice.usesModel(plan, "claude-opus-5"));
    try std.testing.expect(!choice.usesModel(plan, "claude-opus-6"));
    try std.testing.expectEqualStrings("anthropic-plan", choice.accountId().?);
    try std.testing.expectEqualStrings("claude-opus-5", choice.modelName().?);
    try std.testing.expectEqual(core.Provider.Effort.high, choice.fold().?);

    choice.model.?.thinking = .unsupported;
    try std.testing.expect(choice.fold() == null);
}

test "two choices are equal when the account, the model, and the effort agree" {
    const plan = accounts.Account.index("anthropic-plan").?;
    const opus = try accounts.Model.init("claude-opus-5");
    const first: Choice = .{ .account = plan, .model = opus, .effort = .high };
    var second = first;
    try std.testing.expect(first.eql(&second));
    second.effort = .low;
    try std.testing.expect(!first.eql(&second));
    second = first;
    second.model = null;
    try std.testing.expect(!first.eql(&second));
    try std.testing.expect(!second.eql(&first));
    second.model = try accounts.Model.init("claude-opus-6");
    try std.testing.expect(!first.eql(&second));
    second = first;
    second.account = null;
    try std.testing.expect(!first.eql(&second));
}
