//! Shared factories for the command tests: an `Accounts` registry stubbed to
//! the given authentication state, the model lists that registry offers, and an
//! `Agent` on the given credentials.

const std = @import("std");

const Accounts = @import("../Accounts.zig");
const Agent = @import("../Agent.zig");
const llm = @import("../llm.zig");
const model_testing = @import("../testing.zig");
const provider = @import("../provider.zig");

/// A registry that offers no model. A test that needs one calls `seed`.
pub fn accounts(
    keys: Accounts.ApiKeys,
    ready: struct {
        anthropic: bool = false,
        openai: bool = false,
        anthropic_console: bool = false,
    },
) Accounts {
    return .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .timeouts = .{},
        .anthropic_auth = undefined,
        .anthropic_console_auth = undefined,
        .openai_auth = undefined,
        .keys = keys,
        .anthropic_subscription_ready = ready.anthropic,
        .openai_subscription_ready = ready.openai,
        .anthropic_console_ready = ready.anthropic_console,
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

/// Free every model list a `seed` call added. A registry from `accounts` owns
/// nothing else, so this is its whole teardown.
pub fn deinitAccounts(registry: *Accounts) void {
    for (std.enums.values(llm.Account)) |account|
        registry.gpa.free(registry.catalog.accounts.get(account));
}

/// Offer `names` under `account`, as a fetch does.
pub fn seed(registry: *Accounts, account: llm.Account, names: []const []const u8) !void {
    try model_testing.seedAccount(registry, account, names);
}

pub fn agent(gpa: std.mem.Allocator, credentials: provider.Credentials) Agent {
    const client = provider.Client.init(gpa, std.testing.io, credentials, .{});
    return Agent.init(gpa, std.testing.io, client, .{
        .model = model_testing.model("claude-sonnet-4-6"),
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
}
