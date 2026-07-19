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
//!
//! `Deadline` layers on top: it fixes one instant and bounds a run of reads by
//! the time left until it, so activity that makes no progress (an Anthropic
//! stream sending only keepalive pings) cannot hold the window open the way a
//! fresh per-read timeout would. `Budget` is the volume counterpart: it caps one
//! stream's total bytes, so a peer that keeps making progress — never letting
//! `Deadline` trip — still hits an aggregate ceiling.

const std = @import("std");

/// Per-request timeout bounds, applied in the transport. A bound of 0 disables
/// that timeout.
pub const Timeouts = struct {
    /// Time to the response head: DNS, connect, TLS, request send, and first
    /// byte. Bounds `Transport.send`.
    connect_ms: u64 = 30_000,
    /// Longest gap tolerated between real streamed events. Anthropic sends
    /// periodic keepalive pings, so a healthy stream never idles this long — and,
    /// because pings do not count as progress, a stream that only pings still
    /// trips it. Bounds the read of each event.
    idle_ms: u64 = 60_000,
};

/// Whole-request retry policy, applied above the transport.
pub const Retry = struct {
    /// Total tries per request, initial attempt included; 1 disables retries.
    attempts_max: u32 = 3,
    backoff_ms_initial: u64 = 500,
    backoff_ms_max: u64 = 16_000,

    /// Wait before the retry following a failed `attempt` (1-based): the initial
    /// delay doubled once per prior attempt, capped at `backoff_ms_max`. A server
    /// `retry-after` hint (`suggested_ms`, 0 when absent) takes precedence over the
    /// computed backoff but is capped too, so a server cannot make a turn wait
    /// longer than local policy allows.
    pub fn backoffMs(self: Retry, attempt: u32, suggested_ms: u64) u64 {
        if (suggested_ms > 0) return @min(suggested_ms, self.backoff_ms_max);
        const steps: u6 = @intCast(@min(attempt -| 1, 20));
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
    // A zero bound disables the timeout: run the operation unbounded.
    if (timeout_ms == 0) return @call(.auto, function, args);
    return race(io, timeout_ms, function, args) catch @call(.auto, function, args);
}

/// The bare race behind `withTimeout`: the timer is registered before the work,
/// so the operation never starts without its bound, and a failed registration
/// surfaces as the outer `error.ConcurrencyUnavailable` — distinct from the
/// operation's own result, which lives in the payload — for the caller to map
/// to its policy (run unbounded, or refuse as the OAuth callback must).
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

/// An idle window shared across a run of timed reads. Where `withTimeout` starts
/// a fresh window on every call — so a stream of quick reads never expires — a
/// `Deadline` fixes one instant and bounds each read by the time left until it.
/// A read that returns without making progress draws the window down instead of
/// resetting it, so a source that stays busy without progress (an Anthropic
/// stream sending only keepalive pings) still trips the timeout.
pub const Deadline = struct {
    /// Monotonic instant the window closes, or null when unbounded.
    at: ?std.Io.Timestamp,

    /// A window `timeout_ms` wide opening now; unbounded when `timeout_ms` is 0.
    pub fn start(io: std.Io, timeout_ms: u64) Deadline {
        if (timeout_ms == 0) return .{ .at = null };
        const ms: i64 = @intCast(@min(timeout_ms, std.math.maxInt(i64)));
        return .{ .at = std.Io.Clock.awake.now(io).addDuration(.fromMilliseconds(ms)) };
    }

    /// Whether the window has already closed; an unbounded deadline never has.
    /// Lets a caller time out a source that stays busy without blocking a read
    /// (a stream flooding pings), which the read-bounding `call` never reaches.
    pub fn expired(self: Deadline, io: std.Io) bool {
        const at = self.at orelse return false;
        return std.Io.Clock.awake.now(io).durationTo(at).nanoseconds <= 0;
    }

    /// Run `function(args)` bounded by the time left until the deadline: its
    /// result if it finishes first, `error.Timeout` once the window has closed
    /// (refused without running when already past it). An unbounded deadline runs
    /// it without a bound.
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
/// is not compressed. Caller frees a non-empty result.
pub fn decompressBuffer(gpa: std.mem.Allocator, encoding: std.http.ContentEncoding) ![]u8 {
    return switch (encoding) {
        .identity => &.{},
        .gzip, .deflate => gpa.alloc(u8, std.compress.flate.max_window_len),
        .zstd => gpa.alloc(u8, std.compress.zstd.default_window_len),
        .compress => error.UnsupportedContentEncoding,
    };
}

/// A hard ceiling on the total wire bytes one streamed response body may deliver.
/// Every model tops out at 128k output tokens (~14 MB of framed SSE at one token
/// per frame), so this clears any real reply several times over while bounding a
/// stream that never ends. A safety limit, not a tunable, like the OAuth
/// token-response cap.
pub const stream_response_bytes_max = 64 << 20;

/// A running byte budget for one streamed response, shared across its reads.
/// Where `Deadline` bounds how long a single read may block, `Budget` bounds a
/// whole stream's volume, so a peer that makes frequent valid progress —
/// restarting the idle window on every frame, so `Deadline` never trips — still
/// hits an aggregate ceiling. Bytes are charged after decompression, the
/// memory-relevant quantity.
pub const Budget = struct {
    /// Bytes charged so far.
    used: usize = 0,
    /// Ceiling; a charge that carries `used` past it fails.
    max: usize,

    /// Charge `bytes` against the budget, failing once the running total passes
    /// the ceiling. Saturating, so no single charge can wrap the counter back
    /// under the ceiling.
    pub fn take(self: *Budget, bytes: usize) error{StreamResponseTooLarge}!void {
        self.used +|= bytes;
        if (self.used > self.max) return error.StreamResponseTooLarge;
    }

    /// Bytes the stream may still deliver before the ceiling; zero once spent.
    /// Bounding one line's read by this stops a single oversized frame from
    /// allocating past what the whole stream is allowed, before it is buffered.
    pub fn remaining(self: Budget) usize {
        return self.max -| self.used;
    }
};

test "Budget charges until the running total passes its ceiling" {
    var budget: Budget = .{ .max = 10 };
    try budget.take(4);
    try budget.take(6); // used == max is still within budget
    try std.testing.expectEqual(@as(usize, 10), budget.used);
    try std.testing.expectError(error.StreamResponseTooLarge, budget.take(1));
    // Saturating, so an absurd charge trips without wrapping the counter back
    // under the ceiling.
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
    // Saturating, so an overshooting charge leaves remaining at zero, never wrapped.
    try std.testing.expectError(error.StreamResponseTooLarge, budget.take(5));
    try std.testing.expectEqual(@as(usize, 0), budget.remaining());
}

test "backoffMs without a hint doubles per attempt and caps" {
    const retry: Retry = .{ .backoff_ms_initial = 500, .backoff_ms_max = 16_000 };
    try std.testing.expectEqual(@as(u64, 500), retry.backoffMs(1, 0));
    try std.testing.expectEqual(@as(u64, 1000), retry.backoffMs(2, 0));
    try std.testing.expectEqual(@as(u64, 2000), retry.backoffMs(3, 0));
    try std.testing.expectEqual(@as(u64, 16_000), retry.backoffMs(10, 0));
}

test "backoffMs caps a server hint at the max backoff" {
    const retry: Retry = .{ .backoff_ms_initial = 500, .backoff_ms_max = 16_000 };
    // A hint longer than local policy is capped, so a turn never waits longer than
    // the computed backoff's ceiling; a saturated hint cannot wrap past it either.
    try std.testing.expectEqual(@as(u64, 16_000), retry.backoffMs(1, 3_600_000));
    try std.testing.expectEqual(@as(u64, 16_000), retry.backoffMs(1, 16_000));
    try std.testing.expectEqual(@as(u64, 16_000), retry.backoffMs(1, std.math.maxInt(u64)));
    // A hint at or below the cap takes precedence over the computed backoff, whether
    // it is longer or shorter than that backoff would be.
    try std.testing.expectEqual(@as(u64, 5000), retry.backoffMs(1, 5000));
    try std.testing.expectEqual(@as(u64, 200), retry.backoffMs(3, 200));
    // No hint falls back to the exponential backoff.
    try std.testing.expectEqual(@as(u64, 1000), retry.backoffMs(2, 0));
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
    // Past the window, it is expired and the next read is refused without running.
    try io.sleep(.fromMilliseconds(150), .awake);
    try std.testing.expect(deadline.expired(io));
    try std.testing.expectError(error.Timeout, deadline.call(io, fastWork, .{io}));
}
