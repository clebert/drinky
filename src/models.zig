//! Per-model economics and limits, namespaced by provider so the same model
//! name can carry different prices and windows across providers. Base prices are
//! USD per million tokens; cache read/write rates are stored absolute rather
//! than derived, so a provider with different cache economics slots in as new
//! entries. An unknown model has no entry — without a known context window it
//! cannot be sized, so it is unsupported rather than given a guessed fallback.
//! The table is compiled in; a runtime override file is future work.

const std = @import("std");

const llm = @import("llm.zig");
const provider = @import("provider.zig");

const million = 1_000_000.0;

pub const Model = struct {
    name: []const u8,
    input: f64,
    output: f64,
    cache_read: f64,
    cache_write: f64,
    context_window: u64,
    tokens_max: u32,

    /// Dollar cost of `usage` at these per-million rates.
    pub fn cost(self: Model, usage: llm.Usage) f64 {
        return (self.input * asFloat(usage.input) +
            self.output * asFloat(usage.output) +
            self.cache_read * asFloat(usage.cache_read) +
            self.cache_write * asFloat(usage.cache_write)) / million;
    }

    /// Dollars caching saved on `usage`: the gap between the cache rates and
    /// billing every cached token at the base input rate. Negative when writes
    /// outweigh reads (a fresh write recovered by no read yet).
    pub fn savings(self: Model, usage: llm.Usage) f64 {
        return ((self.input - self.cache_read) * asFloat(usage.cache_read) +
            (self.input - self.cache_write) * asFloat(usage.cache_write)) / million;
    }
};

const Entry = struct {
    provider: provider.Kind,
    model: Model,
};

// Anthropic cache rates follow fixed multipliers of the base input price:
// 0.1x for a read, 1.25x for a 5-minute write.
const table = [_]Entry{
    .{ .provider = .anthropic, .model = .{
        .name = "claude-sonnet-4-6",
        .input = 3,
        .output = 15,
        .cache_read = 0.3,
        .cache_write = 3.75,
        .context_window = 1_000_000,
        .tokens_max = 8192,
    } },
    .{ .provider = .anthropic, .model = .{
        .name = "claude-opus-4-8",
        .input = 5,
        .output = 25,
        .cache_read = 0.5,
        .cache_write = 6.25,
        .context_window = 1_000_000,
        .tokens_max = 8192,
    } },
    .{ .provider = .anthropic, .model = .{
        .name = "claude-sonnet-4-5",
        .input = 3,
        .output = 15,
        .cache_read = 0.3,
        .cache_write = 3.75,
        .context_window = 200_000,
        .tokens_max = 8192,
    } },
    .{ .provider = .anthropic, .model = .{
        .name = "claude-haiku-4-5",
        .input = 1,
        .output = 5,
        .cache_read = 0.1,
        .cache_write = 1.25,
        .context_window = 200_000,
        .tokens_max = 8192,
    } },
};

/// The model `name` offered by `kind`, or null when it is not in the table.
pub fn get(kind: provider.Kind, name: []const u8) ?Model {
    for (table) |entry| {
        if (entry.provider == kind and std.mem.eql(u8, entry.model.name, name)) return entry.model;
    }
    return null;
}

fn asFloat(count: u64) f64 {
    return @floatFromInt(count);
}

test get {
    try std.testing.expectEqual(@as(u64, 1_000_000), get(.anthropic, "claude-sonnet-4-6").?.context_window);
    try std.testing.expectEqual(@as(?Model, null), get(.anthropic, "does-not-exist"));

    const model = get(.anthropic, "claude-sonnet-4-6").?;
    const usage: llm.Usage = .{
        .input = 1_000_000,
        .cache_read = 1_000_000,
        .cache_write = 1_000_000,
    };
    // 3.0 (input) + 0.3 (read) + 3.75 (write).
    try std.testing.expectApproxEqAbs(@as(f64, 7.05), model.cost(usage), 1e-9);
    // Read saves 2.7 (3.0 - 0.3), write costs 0.75 extra (3.75 - 3.0).
    try std.testing.expectApproxEqAbs(@as(f64, 1.95), model.savings(usage), 1e-9);
}
