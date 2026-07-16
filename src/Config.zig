//! Global configuration loaded from `<home>/.pith/config.json`. The file is
//! optional and may be partial: a missing file, a missing section, or a missing
//! field falls back to a built-in default, and unknown keys are ignored so an
//! older binary still reads a newer file. It configures request networking
//! (timeouts and retries) and a default model per account; more sections join as
//! the harness grows. It carries no secrets — API keys come from the environment.
//!
//! Example:
//!   { "request": { "connect_timeout_ms": 30000, "idle_timeout_ms": 60000,
//!                  "attempts_max": 3, "backoff_ms_initial": 500,
//!                  "backoff_ms_max": 16000 },
//!     "default_models": { "anthropic_subscription": "claude-opus-4-8",
//!                         "openai_api": "gpt-5.6-sol" } }

const std = @import("std");

const ai = @import("ai");

const Config = @This();

timeouts: ai.net.Timeouts,
retry: ai.net.Retry,
default_models: DefaultModels,

/// The configured default model per account, resolved against the compiled model
/// table (an unset or unknown name is null, so the caller falls back to a
/// compiled default). A resolved model's name points into the static table, so
/// this outlives the parse with no owned memory.
pub const DefaultModels = struct {
    anthropic_api: ?ai.models.Model = null,
    anthropic_subscription: ?ai.models.Model = null,
    openai_api: ?ai.models.Model = null,
    openai_subscription: ?ai.models.Model = null,

    pub fn get(self: *const DefaultModels, account: ai.llm.Account) ?ai.models.Model {
        return switch (account) {
            .anthropic_api => self.anthropic_api,
            .anthropic_subscription => self.anthropic_subscription,
            .openai_api => self.openai_api,
            .openai_subscription => self.openai_subscription,
        };
    }
};

const timeouts_default: ai.net.Timeouts = .{};
const retry_default: ai.net.Retry = .{};
const default: Config = .{ .timeouts = timeouts_default, .retry = retry_default, .default_models = .{} };

/// The on-disk shape. Each field defaults to the built-in, so any subset parses.
const File = struct {
    request: Request = .{},
    default_models: DefaultModelsFile = .{},

    const Request = struct {
        connect_timeout_ms: u64 = timeouts_default.connect_ms,
        idle_timeout_ms: u64 = timeouts_default.idle_ms,
        attempts_max: u32 = retry_default.attempts_max,
        backoff_ms_initial: u64 = retry_default.backoff_ms_initial,
        backoff_ms_max: u64 = retry_default.backoff_ms_max,
    };

    /// Model names keyed by account tag; each resolved to a compiled model.
    const DefaultModelsFile = struct {
        anthropic_api: ?[]const u8 = null,
        anthropic_subscription: ?[]const u8 = null,
        openai_api: ?[]const u8 = null,
        openai_subscription: ?[]const u8 = null,
    };
};

/// Load `<home>/.pith/config.json`, or the built-in defaults when it is absent.
pub fn load(gpa: std.mem.Allocator, io: std.Io, home: []const u8) !Config {
    const path = try std.fs.path.join(gpa, &.{ home, ".pith", "config.json" });
    defer gpa.free(path);
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return default,
        else => return err,
    };
    defer gpa.free(data);
    return parse(gpa, data);
}

/// Parse config JSON, folding each section into the neutral option structs.
fn parse(gpa: std.mem.Allocator, data: []const u8) !Config {
    const parsed = try std.json.parseFromSlice(File, gpa, data, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const request = parsed.value.request;
    const default_models = parsed.value.default_models;
    return .{
        .timeouts = .{ .connect_ms = request.connect_timeout_ms, .idle_ms = request.idle_timeout_ms },
        .retry = .{
            .attempts_max = request.attempts_max,
            .backoff_ms_initial = request.backoff_ms_initial,
            .backoff_ms_max = request.backoff_ms_max,
        },
        .default_models = .{
            .anthropic_api = resolveModel(.anthropic_api, default_models.anthropic_api),
            .anthropic_subscription = resolveModel(.anthropic_subscription, default_models.anthropic_subscription),
            .openai_api = resolveModel(.openai_api, default_models.openai_api),
            .openai_subscription = resolveModel(.openai_subscription, default_models.openai_subscription),
        },
    };
}

/// Resolve a configured model name for `account` against the compiled table for
/// that account's vendor, or null when unset or not a model of that vendor.
fn resolveModel(account: ai.llm.Account, name: ?[]const u8) ?ai.models.Model {
    const model_name = name orelse return null;
    return ai.models.get(ai.llm.provider(account), model_name);
}

test "parse reads the request section" {
    const config = try parse(std.testing.allocator,
        \\{ "request": { "connect_timeout_ms": 1000, "idle_timeout_ms": 2000,
        \\  "attempts_max": 5, "backoff_ms_initial": 100, "backoff_ms_max": 900 } }
    );
    try std.testing.expectEqual(@as(u64, 1000), config.timeouts.connect_ms);
    try std.testing.expectEqual(@as(u64, 2000), config.timeouts.idle_ms);
    try std.testing.expectEqual(@as(u32, 5), config.retry.attempts_max);
    try std.testing.expectEqual(@as(u64, 100), config.retry.backoff_ms_initial);
    try std.testing.expectEqual(@as(u64, 900), config.retry.backoff_ms_max);
}

test "parse fills missing fields and sections from defaults" {
    const partial = try parse(std.testing.allocator,
        \\{ "request": { "attempts_max": 7 } }
    );
    try std.testing.expectEqual(@as(u32, 7), partial.retry.attempts_max);
    try std.testing.expectEqual(timeouts_default.connect_ms, partial.timeouts.connect_ms);
    try std.testing.expectEqual(retry_default.backoff_ms_initial, partial.retry.backoff_ms_initial);

    const empty = try parse(std.testing.allocator, "{}");
    try std.testing.expectEqual(timeouts_default.idle_ms, empty.timeouts.idle_ms);
    try std.testing.expectEqual(retry_default.attempts_max, empty.retry.attempts_max);
}

test "parse resolves default_models to compiled models, dropping unknown names" {
    const config = try parse(std.testing.allocator,
        \\{ "default_models": { "anthropic_subscription": "claude-sonnet-5",
        \\  "anthropic_api": "gpt-5.6-sol", "openai_api": "nope" } }
    );
    try std.testing.expectEqualStrings("claude-sonnet-5", config.default_models.get(.anthropic_subscription).?.name);
    // A wrong-vendor name (an openai model under an anthropic account) does not
    // resolve, so it falls back to null.
    try std.testing.expect(config.default_models.get(.anthropic_api) == null);
    // An unknown name and an unset account both resolve to null.
    try std.testing.expect(config.default_models.get(.openai_api) == null);
    try std.testing.expect(config.default_models.get(.openai_subscription) == null);
}

test "parse ignores unknown keys" {
    const config = try parse(std.testing.allocator,
        \\{ "request": { "connect_timeout_ms": 42 }, "future": { "x": 1 } }
    );
    try std.testing.expectEqual(@as(u64, 42), config.timeouts.connect_ms);
}
