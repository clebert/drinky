//! Networking policy shared across the provider seam: the timeout and retry
//! knobs (defaults live here, so the config file only patches them) and three
//! bounds. `withTimeout` bounds one blocking operation. `Deadline` bounds a
//! run of reads by one fixed instant. `Budget` caps a stream's total bytes.

const std = @import("std");

/// Per-request timeout bounds, applied in the transport. A bound of 0 disables
/// that timeout.
pub const Timeouts = struct {
    /// The time to the response head: DNS, connect, TLS, request send, and
    /// first byte. This bounds `Transport.send`.
    connect_ms: u64 = 30_000,
    /// The longest gap tolerated between real streamed events. Keepalive pings
    /// do not count as progress. This bounds the read of each event.
    idle_ms: u64 = 60_000,
};

/// Whole-request retry policy, applied above the transport.
pub const Retry = struct {
    /// The total tries per request, the initial attempt included. A value of 1 disables retries.
    attempts_max: u32 = 3,
    backoff_ms_initial: u64 = 500,
    backoff_ms_max: u64 = 16_000,

    /// One failed try: which `attempt` failed (1-based) and the server's
    /// `retry-after` hint in milliseconds. The hint is 0 when the server gave
    /// none.
    pub const Failure = struct { attempt: u32, suggested_ms: u64 = 0 };

    /// Whether the policy allows another try after `failure`. A spent attempt
    /// bound refuses one. A `retry-after` hint longer than `backoff_ms_max`
    /// refuses one too: the cap bounds every wait, so no wait this policy can
    /// serve clears a failure that asks for more.
    pub fn allows(self: Retry, failure: Failure) bool {
        if (failure.attempt >= self.attempts_max) return false;
        return failure.suggested_ms <= self.backoff_ms_max;
    }

    /// The wait before the retry that follows `failure`: the initial delay
    /// doubled once per prior attempt, capped at `backoff_ms_max`. A server hint
    /// takes precedence over the computed backoff but is capped too. A server
    /// cannot make a turn wait longer than the local policy allows.
    pub fn backoffMs(self: Retry, failure: Failure) u64 {
        if (failure.suggested_ms > 0) return @min(failure.suggested_ms, self.backoff_ms_max);
        const steps: u6 = @intCast(@min(failure.attempt -| 1, 20));
        return @min(self.backoff_ms_initial *| (@as(u64, 1) << steps), self.backoff_ms_max);
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

/// Run `function(args)` bounded by `timeout_ms`. It returns the function's
/// result if it finishes first, or `error.Timeout` if the timer wins (the
/// operation is canceled and reaped first). A cancel of the calling task
/// propagates as `error.Canceled`. A `timeout_ms` of 0, or an io without
/// concurrency, runs the operation unbounded.
///
/// Zig's `std.http` offers no request deadline, so the bound is a race of two
/// concurrent tasks. An operation that finishes right at the deadline can
/// still surface `error.Timeout` (its reaped result is discarded here). A
/// caller whose operation acquires resources must be able to reclaim them on
/// `error.Timeout` (e.g. a flag the operation sets last, checked on the error
/// path).
pub fn withTimeout(
    io: std.Io,
    timeout_ms: u64,
    comptime function: anytype,
    args: std.meta.ArgsTuple(@TypeOf(function)),
) Timed(@TypeOf(function)) {
    // A zero bound disables the timeout: run the operation unbounded.
    if (timeout_ms == 0) return @call(.auto, function, args);
    return race(io, timeout_ms, function, args) catch @call(.auto, function, args);
}

/// The bare race behind `withTimeout`. The timer is registered before the
/// work, so the operation never starts without its bound. A failed
/// registration surfaces as the outer `error.ConcurrencyUnavailable`, distinct
/// from the operation's own result, which lives in the payload. The caller
/// maps the outer error to its policy (run unbounded, or refuse as the OAuth
/// callback must).
pub fn race(
    io: std.Io,
    timeout_ms: u64,
    comptime function: anytype,
    args: std.meta.ArgsTuple(@TypeOf(function)),
) error{ConcurrencyUnavailable}!Timed(@TypeOf(function)) {
    const Racer = union(enum) {
        work: @typeInfo(@TypeOf(function)).@"fn".return_type.?,
        timer: std.Io.Cancelable!void,
    };

    var buffer: [2]Racer = undefined;
    var select = std.Io.Select(Racer).init(io, &buffer);
    defer select.cancelDiscard();

    try select.concurrent(.timer, sleep, .{ io, timeout_ms });
    try select.concurrent(.work, function, args);
    const first = select.await() catch |err| return @as(Timed(@TypeOf(function)), err);
    return @as(Timed(@TypeOf(function)), switch (first) {
        .work => |result| result,
        .timer => error.Timeout,
    });
}

fn sleep(io: std.Io, milliseconds: u64) std.Io.Cancelable!void {
    return io.sleep(.fromMilliseconds(@intCast(@min(milliseconds, std.math.maxInt(i64)))), .awake);
}

/// An idle window shared across a run of timed reads: one fixed instant bounds
/// each read by the time left until it. A read that makes no progress draws
/// the window down and does not reset it. A source that stays busy without
/// progress (an Anthropic stream that sends only keepalive pings) still trips.
pub const Deadline = struct {
    /// The monotonic instant when the window closes, or null when unbounded.
    at: ?std.Io.Timestamp,

    /// A window `timeout_ms` wide that opens now. The window is unbounded when `timeout_ms` is 0.
    pub fn start(io: std.Io, timeout_ms: u64) Deadline {
        if (timeout_ms == 0) return .{ .at = null };
        const ms: i64 = @intCast(@min(timeout_ms, std.math.maxInt(i64)));
        return .{ .at = std.Io.Clock.awake.now(io).addDuration(.fromMilliseconds(ms)) };
    }

    /// Whether the window has already closed. An unbounded deadline never has.
    /// This lets a caller time out a source that stays busy without blocking a
    /// read, which the read-bounding `call` never reaches.
    pub fn expired(self: Deadline, io: std.Io) bool {
        const at = self.at orelse return false;
        return std.Io.Clock.awake.now(io).durationTo(at).nanoseconds <= 0;
    }

    /// Run `function(args)` bounded by the time left until the deadline. It
    /// returns the function's result if it finishes first, or `error.Timeout`
    /// once the window has closed. A call already past the deadline is refused
    /// without a run. An unbounded deadline runs it without a bound.
    pub fn call(
        self: Deadline,
        io: std.Io,
        comptime function: anytype,
        args: std.meta.ArgsTuple(@TypeOf(function)),
    ) Timed(@TypeOf(function)) {
        const at = self.at orelse return withTimeout(io, 0, function, args);
        const remaining_ns = std.Io.Clock.awake.now(io).durationTo(at).nanoseconds;
        if (remaining_ns <= 0) return error.Timeout;
        const remaining_ms: u64 = @intCast(@divFloor(remaining_ns, std.time.ns_per_ms) + 1);
        return withTimeout(io, remaining_ms, function, args);
    }
};

/// A decompression window sized for `encoding`, or an empty slice when the body
/// is not compressed. The caller frees a non-empty result.
pub fn decompressBuffer(gpa: std.mem.Allocator, encoding: std.http.ContentEncoding) ![]u8 {
    return switch (encoding) {
        .identity => &.{},
        .gzip, .deflate => gpa.alloc(u8, std.compress.flate.max_window_len),
        .zstd => gpa.alloc(u8, std.compress.zstd.default_window_len),
        .compress => error.UnsupportedContentEncoding,
    };
}

/// Whether a runtime string is safe as an HTTP header value: non-empty and free
/// of CR/LF, so a hostile credential cannot split the request head.
pub fn validHeaderValue(value: []const u8) bool {
    return value.len != 0 and std.mem.indexOfAny(u8, value, "\r\n") == null;
}

/// A hard ceiling on the total wire bytes one streamed response body can
/// deliver. Every model tops out at 128k output tokens (~14 MB of framed SSE
/// at one token per frame). This ceiling clears any real reply several times
/// over and still bounds a stream that never ends. A safety limit, not a
/// tunable, like the OAuth token-response cap.
pub const stream_response_bytes_max = 64 << 20;

/// A running byte budget for one streamed response, shared across its reads.
/// It is the volume counterpart to `Deadline`, so a peer that continues to
/// make valid progress still hits an aggregate ceiling. Bytes are charged
/// after decompression, the memory-relevant quantity.
pub const Budget = struct {
    /// The bytes charged so far.
    used: usize = 0,
    /// The ceiling. A charge that carries `used` past it fails.
    max: usize,

    /// Charge `bytes` against the budget. The charge fails once the running
    /// total passes the ceiling. The addition saturates, so no single charge
    /// can wrap the counter back under the ceiling.
    pub fn take(self: *Budget, bytes: usize) error{StreamResponseTooLarge}!void {
        self.used +|= bytes;
        if (self.used > self.max) return error.StreamResponseTooLarge;
    }

    /// The bytes the stream can still deliver before the ceiling, or zero once
    /// spent. Bound one line's read by this value. Then a single oversized
    /// frame cannot allocate past the whole stream's allowance before it is
    /// buffered.
    pub fn remaining(self: Budget) usize {
        return self.max -| self.used;
    }
};

test "credential header values cannot inject another header" {
    try std.testing.expect(validHeaderValue("token.account"));
    try std.testing.expect(!validHeaderValue(""));
    try std.testing.expect(!validHeaderValue("token\r\nleaked: value"));
}

test "Budget charges until the running total passes its ceiling" {
    var budget: Budget = .{ .max = 10 };
    try budget.take(4);
    try budget.take(6); // used == max is still within the budget
    try std.testing.expectEqual(@as(usize, 10), budget.used);
    try std.testing.expectError(error.StreamResponseTooLarge, budget.take(1));
    // The addition saturates, so an absurd charge trips and does not wrap the
    // counter back under the ceiling.
    try std.testing.expectError(error.StreamResponseTooLarge, budget.take(std.math.maxInt(usize)));
    try std.testing.expectEqual(@as(usize, std.math.maxInt(usize)), budget.used);
}

test "Budget reports the bytes remaining before its ceiling" {
    var budget: Budget = .{ .max = 10 };
    try std.testing.expectEqual(@as(usize, 10), budget.remaining());
    try budget.take(4);
    try std.testing.expectEqual(@as(usize, 6), budget.remaining());
    try budget.take(6); // exactly spent
    try std.testing.expectEqual(@as(usize, 0), budget.remaining());
    // The addition saturates, so an overshooting charge leaves remaining at
    // zero, never wrapped.
    try std.testing.expectError(error.StreamResponseTooLarge, budget.take(5));
    try std.testing.expectEqual(@as(usize, 0), budget.remaining());
}

test "allows refuses a spent attempt bound and a hint past the cap" {
    const retry: Retry = .{ .attempts_max = 3, .backoff_ms_max = 16_000 };
    try std.testing.expect(retry.allows(.{ .attempt = 1 }));
    try std.testing.expect(retry.allows(.{ .attempt = 2 }));
    // The third try is the last one, so no retry follows its failure.
    try std.testing.expect(!retry.allows(.{ .attempt = 3 }));
    try std.testing.expect(!retry.allows(.{ .attempt = 4 }));

    // A hint the policy can serve keeps the retry. A hint past the cap asks for
    // a wait no retry here can serve, so no retry follows it.
    try std.testing.expect(retry.allows(.{ .attempt = 1, .suggested_ms = 16_000 }));
    try std.testing.expect(!retry.allows(.{ .attempt = 1, .suggested_ms = 16_001 }));
    try std.testing.expect(!retry.allows(.{ .attempt = 1, .suggested_ms = 3_600_000 }));

    // A policy of one try disables retries.
    const once: Retry = .{ .attempts_max = 1 };
    try std.testing.expect(!once.allows(.{ .attempt = 1 }));
}

test "backoffMs without a hint doubles per attempt and caps" {
    const retry: Retry = .{ .backoff_ms_initial = 500, .backoff_ms_max = 16_000 };
    try std.testing.expectEqual(@as(u64, 500), retry.backoffMs(.{ .attempt = 1 }));
    try std.testing.expectEqual(@as(u64, 1000), retry.backoffMs(.{ .attempt = 2 }));
    try std.testing.expectEqual(@as(u64, 2000), retry.backoffMs(.{ .attempt = 3 }));
    try std.testing.expectEqual(@as(u64, 16_000), retry.backoffMs(.{ .attempt = 10 }));
}

test "backoffMs caps a server hint at the max backoff" {
    const retry: Retry = .{ .backoff_ms_initial = 500, .backoff_ms_max = 16_000 };
    // A hint longer than the local policy is capped, so a turn never waits
    // longer than the computed backoff's ceiling. A saturated hint cannot wrap
    // past it either.
    try std.testing.expectEqual(
        @as(u64, 16_000),
        retry.backoffMs(.{ .attempt = 1, .suggested_ms = 3_600_000 }),
    );
    try std.testing.expectEqual(
        @as(u64, 16_000),
        retry.backoffMs(.{ .attempt = 1, .suggested_ms = 16_000 }),
    );
    try std.testing.expectEqual(
        @as(u64, 16_000),
        retry.backoffMs(.{ .attempt = 1, .suggested_ms = std.math.maxInt(u64) }),
    );
    // A hint at or below the cap takes precedence over the computed backoff,
    // whether it is longer or shorter than that backoff.
    try std.testing.expectEqual(
        @as(u64, 5000),
        retry.backoffMs(.{ .attempt = 1, .suggested_ms = 5000 }),
    );
    try std.testing.expectEqual(
        @as(u64, 200),
        retry.backoffMs(.{ .attempt = 3, .suggested_ms = 200 }),
    );
    // No hint falls back to the exponential backoff.
    try std.testing.expectEqual(@as(u64, 1000), retry.backoffMs(.{ .attempt = 2 }));
}

fn fastWork(io: std.Io) anyerror!u64 {
    try io.sleep(.fromMilliseconds(1), .awake);
    return 42;
}

fn slowWork(io: std.Io) anyerror!u64 {
    try io.sleep(.fromMilliseconds(60_000), .awake);
    return 0;
}

fn timedSlowWork(io: std.Io) anyerror!u64 {
    return withTimeout(io, 60_000, slowWork, .{io});
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

test "withTimeout propagates a caller cancel as Canceled, not Timeout" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var future = try io.concurrent(timedSlowWork, .{io});
    try io.sleep(.fromMilliseconds(10), .awake);
    try std.testing.expectError(error.Canceled, future.cancel(io));
}

test "Deadline with a zero timeout is unbounded" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    try std.testing.expectEqual(@as(?std.Io.Timestamp, null), Deadline.start(threaded.io(), 0).at);
}

test "Deadline draws its window down instead of resetting per read" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const deadline = Deadline.start(io, 100);
    // A read inside the window returns its result and, unlike a fresh per-read
    // timeout, does not extend the window.
    try std.testing.expect(!deadline.expired(io));
    try std.testing.expectEqual(@as(u64, 42), try deadline.call(io, fastWork, .{io}));
    // Past the window, it is expired and the next read is refused without a run.
    try io.sleep(.fromMilliseconds(150), .awake);
    try std.testing.expect(deadline.expired(io));
    try std.testing.expectError(error.Timeout, deadline.call(io, fastWork, .{io}));
}
