const std = @import("std");

const Accounts = @import("Accounts.zig");
const anthropic = @import("anthropic/root.zig");
const llm = @import("llm.zig");
const Model = @import("Model.zig");
const openai = @import("openai/root.zig");
const openrouter = @import("openrouter/root.zig");
const xai = @import("xai/root.zig");

pub fn model(name: []const u8) Model {
    var built = Model.init(name) catch unreachable;
    built.context_window = 1_000_000;
    built.tokens_max = 128_000;
    built.thinking = .supported;
    for ([_]llm.Effort{ .low, .medium, .high, .xhigh, .max }) |level| built.addEffort(level);
    built.price = .{ .input = 3, .output = 15, .cache_read = 0.3, .cache_write = 3.75 };
    return built;
}

pub fn bareModel(name: []const u8) Model {
    return Model.init(name) catch unreachable;
}

fn memoryStore(comptime Store: type) Store {
    return .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .timeouts = .{},
        .path = "",
        .tokens = null,
    };
}

pub fn accounts(environment: Accounts.Environment) Accounts {
    return .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .timeouts = .{},
        .anthropic_auth = memoryStore(anthropic.Auth),
        .anthropic_console_auth = memoryStore(anthropic.ConsoleAuth),
        .openai_auth = memoryStore(openai.Auth),
        .xai_auth = memoryStore(xai.Auth),
        .openrouter_auth = memoryStore(openrouter.Auth),
        .google_auth = null,
        .google_error = null,
        .ds4_base_url = environment.ds4_base_url,
        .ds4_error = null,
        .environment = environment,
        .anthropic_plan_ready = false,
        .openai_plan_ready = false,
        .xai_plan_ready = false,
        .anthropic_api_ready = false,
        .openrouter_api_ready = false,
        .catalog = .{
            .gpa = std.testing.allocator,
            .io = std.testing.io,
            .models_path = "",
            .metadata_path = "",
            .accounts = .initFill(&.{}),
            .base_urls = .initFill(null),
            .metadata = &.{},
        },
    };
}

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
    try std.testing.expectEqual(@as(f64, 3), built.price.?.input);
}

test bareModel {
    const built = bareModel("bare");
    try std.testing.expectEqualStrings("bare", built.name());
    try std.testing.expect(built.context_window == null);
    try std.testing.expect(built.price == null);
    try std.testing.expect(!built.offers(.high));
}
