//! Per-model economics, cache retention, and limits, namespaced by provider so
//! the same model name can carry different prices and windows. Base prices
//! are USD per million tokens. Cache read/write rates are stored absolute
//! rather than derived, so a provider with different cache economics slots in
//! as new entries. An unknown model has no entry. Without a known context
//! window it cannot be sized, so it is unsupported rather than given a guessed
//! fallback. The table is compiled in. Account-aware metadata can overlay a
//! copied model at runtime and does not mutate these provider-wide defaults.

const std = @import("std");

const llm = @import("llm.zig");

const million = 1_000_000.0;

pub const Model = struct {
    name: []const u8,
    input: f64,
    output: f64,
    cache_read: f64,
    cache_write: f64,
    /// The active cache policy's inactivity window. Null means the provider
    /// does not expose a duration that Pith can use without a guess.
    cache_retention_ms: ?u64,
    context_window: u64,
    /// The model's maximum output tokens, sent verbatim as `max_tokens`. The
    /// effort level governs how much of it the model actually spends.
    tokens_max: u32,
    effort: EffortMap,

    /// The provider outcome for each effort level. The map includes `none` and
    /// folds an unavailable level onto the nearest supported level.
    pub const EffortMap = struct {
        none: Resolution,
        low: Resolution,
        medium: Resolution,
        high: Resolution,
        xhigh: Resolution,
        max: Resolution,

        pub const Resolution = union(enum) {
            omitted,
            disabled,
            named: []const u8,
        };

        pub fn resolve(self: *const EffortMap, effort: llm.Effort) Resolution {
            return switch (effort) {
                inline else => |level| @field(self, @tagName(level)),
            };
        }
    };

    /// The dollar cost of `usage` at these per-million rates.
    pub fn cost(self: *const Model, usage: *const llm.Usage) f64 {
        return (self.input * asFloat(usage.input) +
            self.output * asFloat(usage.output) +
            self.cache_read * asFloat(usage.cache_read) +
            self.cache_write * asFloat(usage.cache_write)) / million;
    }

    /// The dollars that caching saved on `usage`: the gap between the cache
    /// rates and the base input rate applied to every cached token. The result
    /// is negative when writes outweigh reads (a fresh write recovered by no
    /// read yet).
    pub fn savings(self: *const Model, usage: *const llm.Usage) f64 {
        return ((self.input - self.cache_read) * asFloat(usage.cache_read) +
            (self.input - self.cache_write) * asFloat(usage.cache_write)) / million;
    }
};

const Entry = struct {
    provider: llm.Provider,
    model: Model,
};

// Anthropic models that default to no thinking can omit the config for `none`.
const anthropic_effort_default_off: Model.EffortMap = .{
    .none = .omitted,
    .low = .{ .named = "low" },
    .medium = .{ .named = "medium" },
    .high = .{ .named = "high" },
    .xhigh = .{ .named = "xhigh" },
    .max = .{ .named = "max" },
};

// Anthropic models that default to thinking need the explicit off control.
const anthropic_effort_default_on: Model.EffortMap = .{
    .none = .disabled,
    .low = .{ .named = "low" },
    .medium = .{ .named = "medium" },
    .high = .{ .named = "high" },
    .xhigh = .{ .named = "xhigh" },
    .max = .{ .named = "max" },
};

// Fable 5 cannot disable thinking, so `none` folds onto `low`.
const anthropic_effort_always_on: Model.EffortMap = .{
    .none = .{ .named = "low" },
    .low = .{ .named = "low" },
    .medium = .{ .named = "medium" },
    .high = .{ .named = "high" },
    .xhigh = .{ .named = "xhigh" },
    .max = .{ .named = "max" },
};

// Sonnet 4.6 has no `xhigh`, so it folds that level onto `high`.
const anthropic_effort_no_xhigh: Model.EffortMap = .{
    .none = .omitted,
    .low = .{ .named = "low" },
    .medium = .{ .named = "medium" },
    .high = .{ .named = "high" },
    .xhigh = .{ .named = "high" },
    .max = .{ .named = "max" },
};

// OpenAI reasoning models use the provider's named `none` level.
const openai_effort: Model.EffortMap = .{
    .none = .{ .named = "none" },
    .low = .{ .named = "low" },
    .medium = .{ .named = "medium" },
    .high = .{ .named = "high" },
    .xhigh = .{ .named = "xhigh" },
    .max = .{ .named = "max" },
};

// Anthropic cache rates follow fixed multipliers of the base input price: 0.1x
// for a read, 1.25x for a 5-minute write. Each model states its real context
// window and maximum output. Nothing is defaulted.
const table = [_]Entry{
    .{ .provider = .anthropic, .model = .{
        .name = "claude-fable-5",
        .input = 10,
        .output = 50,
        .cache_read = 1,
        .cache_write = 12.5,
        .cache_retention_ms = 5 * std.time.ms_per_min,
        .context_window = 1_000_000,
        .tokens_max = 128_000,
        .effort = anthropic_effort_always_on,
    } },
    .{ .provider = .anthropic, .model = .{
        .name = "claude-opus-5",
        .input = 5,
        .output = 25,
        .cache_read = 0.5,
        .cache_write = 6.25,
        .cache_retention_ms = 5 * std.time.ms_per_min,
        .context_window = 1_000_000,
        .tokens_max = 128_000,
        .effort = anthropic_effort_default_on,
    } },
    .{ .provider = .anthropic, .model = .{
        .name = "claude-opus-4-8",
        .input = 5,
        .output = 25,
        .cache_read = 0.5,
        .cache_write = 6.25,
        .cache_retention_ms = 5 * std.time.ms_per_min,
        .context_window = 1_000_000,
        .tokens_max = 128_000,
        .effort = anthropic_effort_default_off,
    } },
    // Sonnet 5 standard rates. The launch introductory pricing ($2/$10 in/out)
    // is not modeled.
    .{ .provider = .anthropic, .model = .{
        .name = "claude-sonnet-5",
        .input = 3,
        .output = 15,
        .cache_read = 0.3,
        .cache_write = 3.75,
        .cache_retention_ms = 5 * std.time.ms_per_min,
        .context_window = 1_000_000,
        .tokens_max = 128_000,
        .effort = anthropic_effort_default_on,
    } },
    .{ .provider = .anthropic, .model = .{
        .name = "claude-sonnet-4-6",
        .input = 3,
        .output = 15,
        .cache_read = 0.3,
        .cache_write = 3.75,
        .cache_retention_ms = 5 * std.time.ms_per_min,
        .context_window = 1_000_000,
        .tokens_max = 128_000,
        .effort = anthropic_effort_no_xhigh,
    } },
    // The gpt-5.6 family reaches the same models over the API-key and the
    // ChatGPT-subscription (Codex) backends. One openai vendor row supplies
    // prices and fallback limits to both accounts. Subscription discovery can
    // overlay its context windows per account. The automatic cache has a
    // 30-minute minimum retention. Standard-tier pricing, per million tokens.
    // Fallback context: 1.05M. Max output: 128K.
    .{ .provider = .openai, .model = .{
        .name = "gpt-5.6-sol",
        .input = 5,
        .output = 30,
        .cache_read = 0.5,
        .cache_write = 6.25,
        .cache_retention_ms = 30 * std.time.ms_per_min,
        .context_window = 1_050_000,
        .tokens_max = 128_000,
        .effort = openai_effort,
    } },
    .{ .provider = .openai, .model = .{
        .name = "gpt-5.6-terra",
        .input = 2.5,
        .output = 15,
        .cache_read = 0.25,
        .cache_write = 3.125,
        .cache_retention_ms = 30 * std.time.ms_per_min,
        .context_window = 1_050_000,
        .tokens_max = 128_000,
        .effort = openai_effort,
    } },
    .{ .provider = .openai, .model = .{
        .name = "gpt-5.6-luna",
        .input = 1,
        .output = 6,
        .cache_read = 0.1,
        .cache_write = 1.25,
        .cache_retention_ms = 30 * std.time.ms_per_min,
        .context_window = 1_050_000,
        .tokens_max = 128_000,
        .effort = openai_effort,
    } },
};

/// The model `name` offered by `provider`, or null when it is not in the table.
pub fn get(provider: llm.Provider, name: []const u8) ?Model {
    for (table) |entry| {
        if (entry.provider == provider and std.mem.eql(u8, entry.model.name, name))
            return entry.model;
    }
    return null;
}

/// Every model name `provider` offers, in table order. The result is
/// comptime-known, so a caller can fold the list into a compiled document and
/// keep that document in step with this table.
pub fn names(comptime provider: llm.Provider) []const []const u8 {
    comptime {
        var collected: []const []const u8 = &.{};
        for (table) |entry| {
            if (entry.provider == provider)
                collected = collected ++ [_][]const u8{entry.model.name};
        }
        return collected;
    }
}

/// Append every model offered by `provider` to `out`, in table order.
pub fn list(provider: llm.Provider, out: *std.ArrayList(Model), gpa: std.mem.Allocator) !void {
    for (table) |entry| {
        if (entry.provider == provider) try out.append(gpa, entry.model);
    }
}

fn asFloat(count: u64) f64 {
    return @floatFromInt(count);
}

test get {
    try std.testing.expectEqual(
        @as(u64, 1_000_000),
        get(.anthropic, "claude-sonnet-4-6").?.context_window,
    );
    try std.testing.expectEqual(@as(u32, 128_000), get(.anthropic, "claude-opus-4-8").?.tokens_max);
    try std.testing.expectEqual(@as(?Model, null), get(.anthropic, "does-not-exist"));

    const model = get(.anthropic, "claude-sonnet-4-6").?;
    const usage: llm.Usage = .{
        .input = 1_000_000,
        .cache_read = 1_000_000,
        .cache_write = 1_000_000,
    };
    // 3.0 (input) + 0.3 (read) + 3.75 (write).
    try std.testing.expectApproxEqAbs(@as(f64, 7.05), model.cost(&usage), 1e-9);
    // The read saves 2.7 (3.0 - 0.3). The write costs 0.75 extra (3.75 - 3.0).
    try std.testing.expectApproxEqAbs(@as(f64, 1.95), model.savings(&usage), 1e-9);
}

test "new Anthropic models have current prices and limits" {
    const fable = get(.anthropic, "claude-fable-5").?;
    try std.testing.expectEqual(@as(f64, 10), fable.input);
    try std.testing.expectEqual(@as(f64, 50), fable.output);
    try std.testing.expectEqual(@as(f64, 1), fable.cache_read);
    try std.testing.expectEqual(@as(f64, 12.5), fable.cache_write);
    try std.testing.expectEqual(@as(?u64, 5 * std.time.ms_per_min), fable.cache_retention_ms);
    try std.testing.expectEqual(@as(u64, 1_000_000), fable.context_window);
    try std.testing.expectEqual(@as(u32, 128_000), fable.tokens_max);

    const opus = get(.anthropic, "claude-opus-5").?;
    try std.testing.expectEqual(@as(f64, 5), opus.input);
    try std.testing.expectEqual(@as(f64, 25), opus.output);
    try std.testing.expectEqual(@as(f64, 0.5), opus.cache_read);
    try std.testing.expectEqual(@as(f64, 6.25), opus.cache_write);
    try std.testing.expectEqual(@as(u64, 1_000_000), opus.context_window);
    try std.testing.expectEqual(@as(u32, 128_000), opus.tokens_max);
}

test "cache retention follows each provider's active default" {
    try std.testing.expectEqual(
        @as(?u64, 5 * std.time.ms_per_min),
        get(.anthropic, "claude-sonnet-4-6").?.cache_retention_ms,
    );
    try std.testing.expectEqual(
        @as(?u64, 30 * std.time.ms_per_min),
        get(.openai, "gpt-5.6-sol").?.cache_retention_ms,
    );
}

test "effort maps resolve each model's supported levels" {
    const levels = std.enums.values(llm.Effort);
    const fable_names = [_][]const u8{ "low", "low", "medium", "high", "xhigh", "max" };
    const fable = get(.anthropic, "claude-fable-5").?;
    for (levels, fable_names) |level, expected| switch (fable.effort.resolve(level)) {
        .named => |actual| try std.testing.expectEqualStrings(expected, actual),
        else => return error.ExpectedNamedEffort,
    };

    const opus = get(.anthropic, "claude-opus-5").?;
    try std.testing.expect(std.meta.activeTag(opus.effort.resolve(.none)) == .disabled);
    const opus_names = [_][]const u8{ "low", "medium", "high", "xhigh", "max" };
    for (levels[1..], opus_names) |level, expected| switch (opus.effort.resolve(level)) {
        .named => |actual| try std.testing.expectEqualStrings(expected, actual),
        else => return error.ExpectedNamedEffort,
    };

    try std.testing.expect(
        std.meta.activeTag(get(.anthropic, "claude-opus-4-8").?.effort.resolve(.none)) == .omitted,
    );
    try std.testing.expect(
        std.meta.activeTag(get(.anthropic, "claude-sonnet-5").?.effort.resolve(.none)) == .disabled,
    );
    switch (get(.anthropic, "claude-sonnet-4-6").?.effort.resolve(.xhigh)) {
        .named => |actual| try std.testing.expectEqualStrings("high", actual),
        else => return error.ExpectedNamedEffort,
    }
    switch (get(.openai, "gpt-5.6-sol").?.effort.resolve(.none)) {
        .named => |actual| try std.testing.expectEqualStrings("none", actual),
        else => return error.ExpectedNamedEffort,
    }
}
