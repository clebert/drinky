//! Shared factories for the command tests: an `Accounts` registry stubbed to
//! the given authentication state and an `Agent` on the given credentials.

const std = @import("std");

const Accounts = @import("../Accounts.zig");
const Agent = @import("../Agent.zig");
const models = @import("../models.zig");
const provider = @import("../provider.zig");

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
        .openai_subscription_context_windows = .empty,
    };
}

pub fn agent(gpa: std.mem.Allocator, credentials: provider.Credentials) Agent {
    const client = provider.Client.init(gpa, std.testing.io, credentials, .{});
    return Agent.init(gpa, std.testing.io, client, .{
        .model = models.get(.anthropic, "claude-sonnet-4-6").?,
        .system = "",
        .retry = .{},
        .environ = .empty,
    });
}
