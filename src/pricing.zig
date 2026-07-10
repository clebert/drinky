//! Per-model token prices and context-window sizes, used to turn a `Usage` into
//! a dollar cost and a context-window fraction. Base prices are USD per million
//! tokens; cache rates follow Anthropic's fixed multipliers (5-minute cache
//! write = 1.25x input, cache read = 0.1x input). An unknown model falls back to
//! zero cost and a conservative window.

const std = @import("std");

const llm = @import("llm.zig");

pub const Price = struct {
    model: []const u8,
    input: f64,
    output: f64,
    context_window: u64,

    /// Dollar cost of `usage` at these per-million rates.
    pub fn cost(self: Price, usage: llm.Usage) f64 {
        const million = 1_000_000.0;
        const cache_read = self.input * 0.1;
        const cache_write = self.input * 1.25;
        return (self.input * asFloat(usage.input) +
            self.output * asFloat(usage.output) +
            cache_read * asFloat(usage.cache_read) +
            cache_write * asFloat(usage.cache_write)) / million;
    }
};

const table = [_]Price{
    .{ .model = "claude-sonnet-4-6", .input = 3, .output = 15, .context_window = 1_000_000 },
    .{ .model = "claude-opus-4-8", .input = 5, .output = 25, .context_window = 1_000_000 },
    .{ .model = "claude-sonnet-4-5", .input = 3, .output = 15, .context_window = 200_000 },
    .{ .model = "claude-haiku-4-5", .input = 1, .output = 5, .context_window = 200_000 },
};

const fallback: Price = .{ .model = "", .input = 0, .output = 0, .context_window = 200_000 };

/// Price for `model`, or a zero-cost fallback with a conservative window.
pub fn lookup(model: []const u8) Price {
    for (table) |price| {
        if (std.mem.eql(u8, price.model, model)) return price;
    }
    return fallback;
}

fn asFloat(count: u64) f64 {
    return @floatFromInt(count);
}

test lookup {
    try std.testing.expectEqual(@as(u64, 1_000_000), lookup("claude-sonnet-4-6").context_window);
    try std.testing.expectEqual(@as(u64, 200_000), lookup("does-not-exist").context_window);

    const price = lookup("claude-sonnet-4-6");
    const usage: llm.Usage = .{
        .input = 1_000_000,
        .cache_read = 1_000_000,
        .cache_write = 1_000_000,
    };
    // 3.0 (input) + 0.3 (read, 0.1x) + 3.75 (write, 1.25x).
    try std.testing.expectApproxEqAbs(@as(f64, 7.05), price.cost(usage), 1e-9);
}
