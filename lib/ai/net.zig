//! Networking policy shared across the provider seam: the request timeout and
//! retry knobs (defaults live here, so the config file only patches them) and
//! `withTimeout`, the primitive that bounds a blocking operation.
//!
//! Zig's `std.http` has no request deadline and owns its own socket reads, so a
//! timeout cannot be attached to an operation directly. `withTimeout` instead
//! races the operation against a timer as two concurrent tasks and cancels the
//! loser: the operation wins with its result, or the timer wins and the still
//! blocked operation is cancelled and reaped, surfacing `error.Timeout`. A cancel
//! of the *caller* (a user aborting the turn) propagates through as
//! `error.Canceled`, distinct from a timeout.

const std = @import("std");

/// Per-request timeout bounds, applied in the transport. A bound of 0 disables
/// that timeout.
pub const Timeouts = struct {
    /// Time to the response head: DNS, connect, TLS, request send, and first
    /// byte. Bounds `Transport.send`.
    connect_ms: u64 = 30_000,
    /// Longest gap tolerated between streamed events; a healthy stream never
    /// idles this long because the provider sends periodic keep-alives. Bounds
    /// each streamed read.
    idle_ms: u64 = 60_000,
};

/// Whole-request retry policy, applied above the transport.
pub const Retry = struct {
    /// Total tries per request, initial attempt included; 1 disables retries.
    attempts_max: u32 = 3,
    backoff_ms_initial: u64 = 500,
    backoff_ms_max: u64 = 16_000,

    /// Backoff before the retry that follows a failed `attempt` (1-based): the
    /// initial delay doubled once per prior attempt, capped at `backoff_ms_max`.
    pub fn delayMs(self: Retry, attempt: u32) u64 {
        const steps: u6 = @intCast(@min(attempt -| 1, 20));
        const scaled = self.backoff_ms_initial *| (@as(u64, 1) << steps);
        return @min(scaled, self.backoff_ms_max);
    }
};

fn Timed(comptime Function: type) type {
    const info = @typeInfo(Function).@"fn";
    const payload = switch (@typeInfo(info.return_type.?)) {
        .error_union => |error_union| error_union.payload,
        else => info.return_type.?,
    };
    return anyerror!payload;
}

/// Run `function(args)` bounded by `timeout_ms`: its result if it finishes first,
/// `error.Timeout` if the timer wins (the operation is cancelled and reaped
/// first). A cancel of the calling task propagates as `error.Canceled`. A
/// `timeout_ms` of 0, or an io without concurrency, runs the operation unbounded.
///
/// The bound is a race, so an operation that finishes right at the deadline can
/// still surface `error.Timeout` (the timer's result was dequeued first, and the
/// reaped operation result is discarded here). A caller whose operation acquires
/// resources must be able to reclaim them on `error.Timeout` — e.g. a flag the
/// operation sets last, checked on the error path.
pub fn withTimeout(
    io: std.Io,
    timeout_ms: u64,
    comptime function: anytype,
    args: std.meta.ArgsTuple(@TypeOf(function)),
) Timed(@TypeOf(function)) {
    const Result = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    // A zero bound disables the timeout: run the operation unbounded.
    if (timeout_ms == 0) return @call(.auto, function, args);
    const Racer = union(enum) {
        work: Result,
        timer: std.Io.Cancelable!void,
    };

    var buffer: [2]Racer = undefined;
    var select = std.Io.Select(Racer).init(io, &buffer);
    select.concurrent(.work, function, args) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return @call(.auto, function, args),
    };
    select.concurrent(.timer, sleep, .{ io, timeout_ms }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => {},
    };

    const first = select.await() catch |err| {
        select.cancelDiscard();
        return err;
    };
    select.cancelDiscard();
    return switch (first) {
        .work => |result| result,
        .timer => error.Timeout,
    };
}

fn sleep(io: std.Io, milliseconds: u64) std.Io.Cancelable!void {
    return io.sleep(.fromMilliseconds(@intCast(@min(milliseconds, std.math.maxInt(i64)))), .awake);
}

test "delayMs doubles per attempt and caps" {
    const retry: Retry = .{ .backoff_ms_initial = 500, .backoff_ms_max = 16_000 };
    try std.testing.expectEqual(@as(u64, 500), retry.delayMs(1));
    try std.testing.expectEqual(@as(u64, 1000), retry.delayMs(2));
    try std.testing.expectEqual(@as(u64, 2000), retry.delayMs(3));
    try std.testing.expectEqual(@as(u64, 16_000), retry.delayMs(10));
}

fn fastWork(io: std.Io) anyerror!u64 {
    try io.sleep(.fromMilliseconds(1), .awake);
    return 42;
}

fn slowWork(io: std.Io) anyerror!u64 {
    try io.sleep(.fromMilliseconds(60_000), .awake);
    return 0;
}

test "withTimeout returns the result when the operation wins" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.testing.expectEqual(@as(u64, 42), try withTimeout(io, 5_000, fastWork, .{io}));
}

test "withTimeout times out and reaps a stalled operation" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.testing.expectError(error.Timeout, withTimeout(io, 20, slowWork, .{io}));
}
