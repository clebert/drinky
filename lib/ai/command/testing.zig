//! Shared factories for the command tests: an `Accounts` registry stubbed to
//! the given authentication state, the model lists that registry offers, and an
//! `Agent` on the given credentials.

const std = @import("std");

const Accounts = @import("../Accounts.zig");
const Agent = @import("../Agent.zig");
const llm = @import("../llm.zig");
const model_testing = @import("../testing.zig");
const provider = @import("../provider.zig");

/// A registry that offers no model. A test that needs one calls `seed`. A ready
/// key file account takes a credential stub that owns nothing, because the
/// commands read the authenticated state alone.
pub fn accounts(
    environment: Accounts.Environment,
    ready: struct {
        anthropic: bool = false,
        openai: bool = false,
        anthropic_api: bool = false,
        xai: bool = false,
        openrouter: bool = false,
        google: bool = false,
    },
) Accounts {
    var registry = model_testing.accounts(environment);
    registry.anthropic_plan_ready = ready.anthropic;
    registry.openai_plan_ready = ready.openai;
    registry.anthropic_api_ready = ready.anthropic_api;
    registry.xai_plan_ready = ready.xai;
    registry.openrouter_api_ready = ready.openrouter;
    if (ready.google) registry.google_auth = .{
        .gpa = registry.gpa,
        .io = registry.io,
        .timeouts = .{},
        .project = "",
        .location = .eu,
        .email = "",
        .token_uri = "",
        .key = .{ .modulus = "", .exponent = "" },
        .token = null,
    };
    return registry;
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
