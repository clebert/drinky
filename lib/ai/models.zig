//! Per-model economics and limits, namespaced by provider so the same model
//! name can carry different prices and windows across providers. Base prices are
//! USD per million tokens; cache read/write rates are stored absolute rather
//! than derived, so a provider with different cache economics slots in as new
//! entries. An unknown model has no entry — without a known context window it
//! cannot be sized, so it is unsupported rather than given a guessed fallback.
//! The table is compiled in; a runtime override file is future work.

const std = @import("std");

const llm = @import("llm.zig");

const million = 1_000_000.0;

pub const Model = struct {
    name: []const u8,
    input: f64,
    output: f64,
    cache_read: f64,
    cache_write: f64,
    context_window: u64,
    /// The model's maximum output tokens, sent verbatim as `max_tokens`; the
    /// effort level governs how much of it the model actually spends.
    tokens_max: u32,
    effort: EffortMap,

    /// The provider outcome for each of our effort levels on this model: a
    /// provider effort name to send, or null to send no reasoning at all. Total
    /// over every level, off included, so each model states exactly what it does
    /// with each choice — including the awkward ends:
    ///   - a model missing a level folds it onto the nearest it has (Sonnet 4.6
    ///     has no xhigh, so xhigh maps to high);
    ///   - a model with no reasoning maps every level, off included, to null;
    ///   - a model that cannot disable reasoning maps off up to a floor level.
    pub const EffortMap = struct {
        off: ?[]const u8,
        low: ?[]const u8,
        medium: ?[]const u8,
        high: ?[]const u8,
        xhigh: ?[]const u8,
        max: ?[]const u8,

        /// The provider effort name to send for `effort`, or null to send no
        /// reasoning config.
        pub fn resolve(self: *const EffortMap, effort: llm.Effort) ?[]const u8 {
            return switch (effort) {
                .off => self.off,
                .low => self.low,
                .medium => self.medium,
                .high => self.high,
                .xhigh => self.xhigh,
                .max => self.max,
            };
        }
    };

    /// Dollar cost of `usage` at these per-million rates.
    pub fn cost(self: *const Model, usage: *const llm.Usage) f64 {
        return (self.input * asFloat(usage.input) +
            self.output * asFloat(usage.output) +
            self.cache_read * asFloat(usage.cache_read) +
            self.cache_write * asFloat(usage.cache_write)) / million;
    }

    /// Dollars caching saved on `usage`: the gap between the cache rates and
    /// billing every cached token at the base input rate. Negative when writes
    /// outweigh reads (a fresh write recovered by no read yet).
    pub fn savings(self: *const Model, usage: *const llm.Usage) f64 {
        return ((self.input - self.cache_read) * asFloat(usage.cache_read) +
            (self.input - self.cache_write) * asFloat(usage.cache_write)) / million;
    }
};

const Entry = struct {
    provider: llm.Provider,
    model: Model,
};

// Anthropic names its effort levels exactly like ours and lets reasoning be
// turned off, so a full-ladder model maps off to none and each level to its own
// name.
const anthropic_effort: Model.EffortMap = .{
    .off = null,
    .low = "low",
    .medium = "medium",
    .high = "high",
    .xhigh = "xhigh",
    .max = "max",
};

// Sonnet 4.6 has no xhigh, so it folds an xhigh request onto high; otherwise the
// standard ladder.
const anthropic_effort_no_xhigh: Model.EffortMap = .{
    .off = null,
    .low = "low",
    .medium = "medium",
    .high = "high",
    .xhigh = "high",
    .max = "max",
};

// Anthropic cache rates follow fixed multipliers of the base input price: 0.1x
// for a read, 1.25x for a 5-minute write. Each model states its real context
// window and maximum output; nothing is defaulted.
const table = [_]Entry{
    .{ .provider = .anthropic, .model = .{
        .name = "claude-opus-4-8",
        .input = 5,
        .output = 25,
        .cache_read = 0.5,
        .cache_write = 6.25,
        .context_window = 1_000_000,
        .tokens_max = 128_000,
        .effort = anthropic_effort,
    } },
    // Sonnet 5 standard rates; the launch introductory pricing ($2/$10 in/out) is
    // not modeled.
    .{ .provider = .anthropic, .model = .{
        .name = "claude-sonnet-5",
        .input = 3,
        .output = 15,
        .cache_read = 0.3,
        .cache_write = 3.75,
        .context_window = 1_000_000,
        .tokens_max = 128_000,
        .effort = anthropic_effort,
    } },
    .{ .provider = .anthropic, .model = .{
        .name = "claude-sonnet-4-6",
        .input = 3,
        .output = 15,
        .cache_read = 0.3,
        .cache_write = 3.75,
        .context_window = 1_000_000,
        .tokens_max = 128_000,
        .effort = anthropic_effort_no_xhigh,
    } },
};

/// The model `name` offered by `kind`, or null when it is not in the table.
pub fn get(kind: llm.Provider, name: []const u8) ?Model {
    for (table) |entry| {
        if (entry.provider == kind and std.mem.eql(u8, entry.model.name, name)) return entry.model;
    }
    return null;
}

/// Append every model offered by `kind` to `out`, in table order.
pub fn list(kind: llm.Provider, out: *std.ArrayList(Model), gpa: std.mem.Allocator) !void {
    for (table) |entry| {
        if (entry.provider == kind) try out.append(gpa, entry.model);
    }
}

fn asFloat(count: u64) f64 {
    return @floatFromInt(count);
}

test get {
    try std.testing.expectEqual(@as(u64, 1_000_000), get(.anthropic, "claude-sonnet-4-6").?.context_window);
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
    // Read saves 2.7 (3.0 - 0.3), write costs 0.75 extra (3.75 - 3.0).
    try std.testing.expectApproxEqAbs(@as(f64, 1.95), model.savings(&usage), 1e-9);
}

test "EffortMap.resolve maps every level, off included, to the model's outcome" {
    // A model that cannot disable reasoning maps off up to a floor level.
    const floored: Model.EffortMap = .{
        .off = "low",
        .low = "low",
        .medium = "medium",
        .high = "high",
        .xhigh = "xhigh",
        .max = "max",
    };
    try std.testing.expectEqualStrings("low", floored.resolve(.off).?);

    // A model with no reasoning maps every level, off included, to null.
    const none: Model.EffortMap = .{
        .off = null,
        .low = null,
        .medium = null,
        .high = null,
        .xhigh = null,
        .max = null,
    };
    try std.testing.expectEqual(@as(?[]const u8, null), none.resolve(.max));

    // Opus 4.8 and Sonnet 5 carry the full ladder and turn reasoning off for
    // off; Sonnet 4.6 folds its missing xhigh onto high.
    try std.testing.expectEqual(@as(?[]const u8, null), get(.anthropic, "claude-opus-4-8").?.effort.resolve(.off));
    try std.testing.expectEqualStrings("xhigh", get(.anthropic, "claude-opus-4-8").?.effort.resolve(.xhigh).?);
    try std.testing.expectEqualStrings("xhigh", get(.anthropic, "claude-sonnet-5").?.effort.resolve(.xhigh).?);
    try std.testing.expectEqualStrings("high", get(.anthropic, "claude-sonnet-4-6").?.effort.resolve(.xhigh).?);
    try std.testing.expectEqualStrings("max", get(.anthropic, "claude-sonnet-4-6").?.effort.resolve(.max).?);
}
