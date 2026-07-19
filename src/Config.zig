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

timeouts: ai.net.Timeouts = .{},
retry: ai.net.Retry = .{},
default_models: DefaultModels = .{},
/// Configured default-model names that did not resolve (unknown, or a model of
/// the wrong vendor for their account), kept so the app can tell the user their
/// line was ignored. Empty on the built-in default. Owned; freed by `deinit`.
dropped_defaults: []const DroppedDefault = &.{},

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
            inline else => |tag| @field(self, @tagName(tag)),
        };
    }
};

/// A configured default-model name that did not resolve, with the account it was
/// written under. Owns `name` (duped out of the parsed file).
pub const DroppedDefault = struct {
    account: ai.llm.Account,
    name: []const u8,
};

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

const timeouts_default: ai.net.Timeouts = .{};
const retry_default: ai.net.Retry = .{};

/// Free the owned dropped-default names. A no-op on the built-in default (its
/// slice is empty).
pub fn deinit(self: *const Config, gpa: std.mem.Allocator) void {
    for (self.dropped_defaults) |dropped| gpa.free(dropped.name);
    gpa.free(self.dropped_defaults);
}

/// Load `<home>/.pith/config.json`, or the built-in defaults when it is absent.
pub fn load(gpa: std.mem.Allocator, io: std.Io, home: []const u8) !Config {
    const path = try std.fs.path.join(gpa, &.{ home, ".pith", "config.json" });
    defer gpa.free(path);
    const cwd = std.Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return .{},
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
    const names = parsed.value.default_models;

    var dropped: std.ArrayList(DroppedDefault) = .empty;
    errdefer {
        for (dropped.items) |item| gpa.free(item.name);
        dropped.deinit(gpa);
    }
    const default_models: DefaultModels = .{
        .anthropic_api = try resolveModel(gpa, &dropped, .anthropic_api, names.anthropic_api),
        .anthropic_subscription = try resolveModel(
            gpa,
            &dropped,
            .anthropic_subscription,
            names.anthropic_subscription,
        ),
        .openai_api = try resolveModel(gpa, &dropped, .openai_api, names.openai_api),
        .openai_subscription = try resolveModel(
            gpa,
            &dropped,
            .openai_subscription,
            names.openai_subscription,
        ),
    };
    return .{
        .timeouts = .{
            .connect_ms = request.connect_timeout_ms,
            .idle_ms = request.idle_timeout_ms,
        },
        .retry = .{
            .attempts_max = request.attempts_max,
            .backoff_ms_initial = request.backoff_ms_initial,
            .backoff_ms_max = request.backoff_ms_max,
        },
        .default_models = default_models,
        .dropped_defaults = try dropped.toOwnedSlice(gpa),
    };
}

/// Resolve a configured model name for `account` against the compiled table for
/// that account's vendor. A name that is unknown or belongs to another vendor
/// resolves to null and is recorded in `dropped` so the app can surface it; an
/// unset name is just null.
fn resolveModel(
    gpa: std.mem.Allocator,
    dropped: *std.ArrayList(DroppedDefault),
    account: ai.llm.Account,
    name: ?[]const u8,
) !?ai.models.Model {
    const model_name = name orelse return null;
    if (ai.models.get(account.provider(), model_name)) |model| return model;
    const owned = try gpa.dupe(u8, model_name);
    errdefer gpa.free(owned);
    try dropped.append(gpa, .{ .account = account, .name = owned });
    return null;
}

test "parse reads the request section" {
    const config = try parse(std.testing.allocator,
        \\{ "request": { "connect_timeout_ms": 1000, "idle_timeout_ms": 2000,
        \\  "attempts_max": 5, "backoff_ms_initial": 100, "backoff_ms_max": 900 } }
    );
    defer config.deinit(std.testing.allocator);
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
    defer partial.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 7), partial.retry.attempts_max);
    try std.testing.expectEqual(timeouts_default.connect_ms, partial.timeouts.connect_ms);
    try std.testing.expectEqual(retry_default.backoff_ms_initial, partial.retry.backoff_ms_initial);

    const empty = try parse(std.testing.allocator, "{}");
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(timeouts_default.idle_ms, empty.timeouts.idle_ms);
    try std.testing.expectEqual(retry_default.attempts_max, empty.retry.attempts_max);
}

test "parse resolves default_models to compiled models, dropping unknown names" {
    const config = try parse(std.testing.allocator,
        \\{ "default_models": { "anthropic_subscription": "claude-sonnet-5",
        \\  "anthropic_api": "gpt-5.6-sol", "openai_api": "nope" } }
    );
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "claude-sonnet-5",
        config.default_models.get(.anthropic_subscription).?.name,
    );
    // A wrong-vendor name (an openai model under an anthropic account) does not
    // resolve, so it falls back to null.
    try std.testing.expect(config.default_models.get(.anthropic_api) == null);
    // An unknown name and an unset account both resolve to null.
    try std.testing.expect(config.default_models.get(.openai_api) == null);
    try std.testing.expect(config.default_models.get(.openai_subscription) == null);

    // The two present-but-unresolved names are recorded for the app to surface;
    // the valid one and the unset ones are not.
    try std.testing.expectEqual(@as(usize, 2), config.dropped_defaults.len);
    try std.testing.expectEqual(ai.llm.Account.anthropic_api, config.dropped_defaults[0].account);
    try std.testing.expectEqualStrings("gpt-5.6-sol", config.dropped_defaults[0].name);
    try std.testing.expectEqual(ai.llm.Account.openai_api, config.dropped_defaults[1].account);
    try std.testing.expectEqualStrings("nope", config.dropped_defaults[1].name);
}

test "parse ignores unknown keys" {
    const config = try parse(std.testing.allocator,
        \\{ "request": { "connect_timeout_ms": 42 }, "future": { "x": 1 } }
    );
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 42), config.timeouts.connect_ms);
}
