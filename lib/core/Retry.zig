const std = @import("std");

const Provider = @import("Provider.zig");

const Retry = @This();

attempts_max: u32 = 3,
backoff: Backoff = .{},

pub const Backoff = struct {
    delay_ms_initial: u64 = 500,
    delay_ms_max: u64 = 16_000,

    pub fn delay(self: *const Backoff, attempt: u32) u64 {
        const steps: u6 = @intCast(@min(attempt -| 1, std.math.maxInt(u6)));
        return @min(self.delay_ms_initial *| (@as(u64, 1) << steps), self.delay_ms_max);
    }
};

pub fn delay(self: *const Retry, attempt: u32, failure: *const Provider.Failure) ?u64 {
    if (attempt >= self.attempts_max) return null;
    switch (failure.reason) {
        .network, .overloaded, .rate_limited, .invalid_reply, .empty_reply => {},
        .unauthorized,
        .quota_exhausted,
        .invalid_request,
        .context_overflow,
        .unsupported_reply,
        .too_many_tool_calls,
        .out_of_memory,
        => return null,
    }
    const backoff = &self.backoff;
    if (failure.retry_after_ms) |hint| return if (hint <= backoff.delay_ms_max) hint else null;
    return backoff.delay(attempt);
}

test "a network failure doubles the delay, caps it, and stops at the last attempt" {
    try std.testing.expectEqual(@as(?u64, 500), delayOf(.network, 1));
    try std.testing.expectEqual(@as(?u64, 700), delayOf(.network, 2));
    try std.testing.expectEqual(@as(?u64, null), delayOf(.network, 3));
    try std.testing.expectEqual(@as(?u64, null), delayOf(.network, 4));
}

const policy: Retry = .{
    .attempts_max = 3,
    .backoff = .{ .delay_ms_initial = 500, .delay_ms_max = 700 },
};

fn delayOf(reason: Provider.Failure.Reason, attempt: u32) ?u64 {
    return policy.delay(attempt, &.{ .reason = reason });
}

test "an initial delay above the maximum is capped" {
    const tight: Retry = .{
        .attempts_max = 3,
        .backoff = .{ .delay_ms_initial = 5_000, .delay_ms_max = 700 },
    };
    try std.testing.expectEqual(@as(?u64, 700), tight.delay(1, &.{ .reason = .network }));
}

test "a hint waits as long as the provider asks, within the maximum" {
    try std.testing.expectEqual(
        @as(?u64, 300),
        policy.delay(1, &.{ .reason = .rate_limited, .retry_after_ms = 300 }),
    );
    try std.testing.expectEqual(
        @as(?u64, 700),
        policy.delay(1, &.{ .reason = .overloaded, .retry_after_ms = 700 }),
    );
    try std.testing.expectEqual(
        @as(?u64, null),
        policy.delay(1, &.{ .reason = .rate_limited, .retry_after_ms = 5_000 }),
    );
    try std.testing.expectEqual(@as(?u64, 700), delayOf(.rate_limited, 2));
}

test "a reply that a repeat can fix waits, and one that it cannot stops" {
    try std.testing.expectEqual(@as(?u64, 500), delayOf(.invalid_reply, 1));
    try std.testing.expectEqual(@as(?u64, 500), delayOf(.empty_reply, 1));
    try std.testing.expectEqual(@as(?u64, 500), delayOf(.overloaded, 1));
    try std.testing.expectEqual(@as(?u64, null), delayOf(.unsupported_reply, 1));
    try std.testing.expectEqual(@as(?u64, null), delayOf(.too_many_tool_calls, 1));
    try std.testing.expectEqual(@as(?u64, null), delayOf(.out_of_memory, 1));
}

test "a failure that a repeat cannot fix stops at once" {
    for ([_]Provider.Failure.Reason{
        .unauthorized,
        .quota_exhausted,
        .invalid_request,
        .context_overflow,
    }) |reason| {
        try std.testing.expectEqual(@as(?u64, null), delayOf(reason, 1));
        try std.testing.expectEqual(
            @as(?u64, null),
            policy.delay(1, &.{ .reason = reason, .retry_after_ms = 100 }),
        );
    }
}

test "the default policy runs three attempts between half a second and sixteen seconds" {
    const default: Retry = .{};
    try std.testing.expectEqual(@as(?u64, 500), default.delay(1, &.{ .reason = .network }));
    try std.testing.expectEqual(@as(?u64, 1_000), default.delay(2, &.{ .reason = .network }));
    try std.testing.expectEqual(@as(?u64, null), default.delay(3, &.{ .reason = .network }));
    const many: Retry = .{ .attempts_max = 100 };
    try std.testing.expectEqual(@as(?u64, 16_000), many.delay(10, &.{ .reason = .network }));
    try std.testing.expectEqual(@as(?u64, 16_000), many.delay(90, &.{ .reason = .network }));
}
