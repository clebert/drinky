//! Model fixtures for tests. Drinky compiles no model in, so a test that needs
//! one builds it here rather than reading a table that no longer exists. The
//! fixtures carry no vendor data: a caller passes the name it wants to see, and
//! the limits and rates below are round numbers chosen for arithmetic that is
//! easy to check.

const std = @import("std");

const Accounts = @import("Accounts.zig");
const llm = @import("llm.zig");
const Model = @import("Model.zig");

/// A fully described model: a window, an output limit, every effort level, a
/// stoppable reasoning, and a price. A test that needs another shape starts
/// here and overwrites the one field it cares about.
pub fn model(name: []const u8) Model {
    var built = Model.init(name) catch unreachable;
    built.context_window = 1_000_000;
    built.tokens_max = 128_000;
    built.thinking = .optional;
    for ([_]llm.Effort{ .low, .medium, .high, .xhigh, .max }) |level| built.addEffort(level);
    built.price = .{ .input = 3, .output = 15, .cache_read = 0.3, .cache_write = 3.75 };
    return built;
}

/// A model that states its name alone, as an OpenAI key states one. It has no
/// window, no level, and no price.
pub fn bareModel(name: []const u8) Model {
    return Model.init(name) catch unreachable;
}

/// A registry stubbed to the given API keys, which offers no model until a
/// `seedAccount` call. It owns no store, so a caller frees only what it seeds.
pub fn accounts(keys: Accounts.ApiKeys) Accounts {
    return .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .timeouts = .{},
        .anthropic_auth = undefined,
        .anthropic_console_auth = undefined,
        .openai_auth = undefined,
        .keys = keys,
        .anthropic_subscription_ready = false,
        .openai_subscription_ready = false,
        .anthropic_console_ready = false,
        .catalog = .{
            .gpa = std.testing.allocator,
            .io = std.testing.io,
            .models_path = "",
            .metadata_path = "",
            .accounts = .initFill(&.{}),
            .metadata = &.{},
        },
    };
}

/// Offer `names` under `account`, as a fetch does. Every model is fully
/// described, so it survives the merge and reaches a picker. The registry frees
/// the list, so a caller that owns the registry needs no teardown of its own.
pub fn seedAccount(
    registry: *Accounts,
    account: llm.Account,
    names: []const []const u8,
) !void {
    const models = try registry.gpa.alloc(Model, names.len);
    for (models, names) |*target, name| target.* = model(name);
    registry.gpa.free(registry.catalog.accounts.get(account));
    registry.catalog.accounts.set(account, models);
}

test model {
    const built = model("test-model");
    try std.testing.expectEqualStrings("test-model", built.name());
    try std.testing.expectEqual(@as(?u64, 1_000_000), built.context_window);
    try std.testing.expect(built.offers(.high));
    try std.testing.expect(built.offers(.none));
    try std.testing.expectEqual(@as(f64, 3), built.price.?.input);
}

test bareModel {
    const built = bareModel("bare");
    try std.testing.expectEqualStrings("bare", built.name());
    try std.testing.expect(built.context_window == null);
    try std.testing.expect(built.price == null);
    try std.testing.expect(!built.offers(.high));
}
