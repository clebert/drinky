const std = @import("std");

pub const Timeouts = struct {
    connect_ms: u64 = 30_000,
    idle_ms: u64 = 60_000,
};

pub const ProviderTimeouts = struct {
    anthropic: Timeouts = .{},
    openai: Timeouts = .{ .idle_ms = 300_000 },
    xai: Timeouts = .{ .idle_ms = 300_000 },
    openrouter: Timeouts = .{ .idle_ms = 300_000 },
    deepseek: Timeouts = .{ .idle_ms = 300_000 },
    google: Timeouts = .{ .idle_ms = 300_000 },
    ds4: Timeouts = .{ .connect_ms = 3_600_000, .idle_ms = 3_600_000 },
};

pub const Retry = struct {
    attempts_max: u32 = 3,
    backoff_ms_initial: u64 = 500,
    backoff_ms_max: u64 = 16_000,

    pub const Failure = struct { attempt: u32, suggested_ms: u64 = 0 };

    pub fn allows(self: Retry, failure: Failure) bool {
        if (failure.attempt >= self.attempts_max) return false;
        return failure.suggested_ms <= self.backoff_ms_max;
    }

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

pub fn withTimeout(
    io: std.Io,
    timeout_ms: u64,
    comptime function: anytype,
    args: std.meta.ArgsTuple(@TypeOf(function)),
) Timed(@TypeOf(function)) {
    if (timeout_ms == 0) return @call(.auto, function, args);
    return race(io, timeout_ms, function, args) catch @call(.auto, function, args);
}

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

pub const Deadline = struct {
    at: ?std.Io.Timestamp,

    pub fn start(io: std.Io, timeout_ms: u64) Deadline {
        if (timeout_ms == 0) return .{ .at = null };
        const ms: i64 = @intCast(@min(timeout_ms, std.math.maxInt(i64)));
        return .{ .at = std.Io.Clock.awake.now(io).addDuration(.fromMilliseconds(ms)) };
    }

    pub fn expired(self: Deadline, io: std.Io) bool {
        const at = self.at orelse return false;
        return std.Io.Clock.awake.now(io).durationTo(at).nanoseconds <= 0;
    }

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

pub fn decompressBuffer(gpa: std.mem.Allocator, encoding: std.http.ContentEncoding) ![]u8 {
    return switch (encoding) {
        .identity => &.{},
        .gzip, .deflate => gpa.alloc(u8, std.compress.flate.max_window_len),
        .zstd => gpa.alloc(u8, std.compress.zstd.default_window_len),
        .compress => error.UnsupportedContentEncoding,
    };
}

pub fn validHeaderValue(value: []const u8) bool {
    return value.len != 0 and std.mem.indexOfAny(u8, value, "\r\n") == null;
}

pub const Get = struct {
    url: []const u8,
    bearer: []const u8,
    timeout_ms: u64 = 5_000,
    body_bytes_max: usize = 256 * 1024,
};

pub fn getJson(gpa: std.mem.Allocator, io: std.Io, get: *const Get) !?[]u8 {
    if (!validHeaderValue(get.bearer)) return error.BadCredentials;
    var out: ?[]u8 = null;
    withTimeout(io, get.timeout_ms, getInto, .{ gpa, io, get, &out }) catch |err| {
        if (out) |body| gpa.free(body);
        return err;
    };
    return out;
}

fn getInto(gpa: std.mem.Allocator, io: std.Io, get: *const Get, out: *?[]u8) !void {
    const authorization = try std.fmt.allocPrint(gpa, "Bearer {s}", .{get.bearer});
    defer gpa.free(authorization);

    const uri = try std.Uri.parse(get.url);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var request = try client.request(.GET, uri, .{
        .headers = .{ .authorization = .{ .override = authorization } },
        .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
        .redirect_behavior = .not_allowed,
    });
    defer request.deinit();

    try request.sendBodiless();

    var redirect_buffer: [4096]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    if (response.head.status != .ok) return;

    const decompress_buffer = try decompressBuffer(gpa, response.head.content_encoding);
    defer if (decompress_buffer.len != 0) gpa.free(decompress_buffer);
    var decompress: std.http.Decompress = undefined;
    var transfer_buffer: [16384]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    out.* = try reader.allocRemaining(gpa, .limited(get.body_bytes_max));
}

pub const stream_response_bytes_max = 256 << 20;

pub const error_body_bytes_max = 4096;

pub const Budget = struct {
    used: usize = 0,
    max: usize,

    pub fn take(self: *Budget, bytes: usize) error{StreamResponseTooLarge}!void {
        self.used +|= bytes;
        if (self.used > self.max) return error.StreamResponseTooLarge;
    }

    pub fn remaining(self: Budget) usize {
        return self.max -| self.used;
    }
};

test "credential header values cannot inject another header" {
    try std.testing.expect(validHeaderValue("token.account"));
    try std.testing.expect(!validHeaderValue(""));
    try std.testing.expect(!validHeaderValue("token\r\nleaked: value"));
}

test "a billing read takes a short bound and a small body cap by default" {
    const get: Get = .{ .url = "https://example.invalid/", .bearer = "token" };
    const timeouts: Timeouts = .{};
    try std.testing.expect(get.timeout_ms > 0);
    try std.testing.expect(get.timeout_ms < timeouts.connect_ms);
    try std.testing.expectEqual(@as(u64, 5_000), get.timeout_ms);
    try std.testing.expectEqual(@as(usize, 256 * 1024), get.body_bytes_max);
}

test "getJson refuses a credential that cannot be a header before it opens" {
    for ([_][]const u8{ "", "token\r\nleaked: value" }) |bearer| {
        try std.testing.expectError(error.BadCredentials, getJson(
            std.testing.allocator,
            std.testing.io,
            &.{ .url = "https://example.invalid/", .bearer = bearer },
        ));
    }
}

test "Budget charges until the running total passes its ceiling" {
    var budget: Budget = .{ .max = 10 };
    try budget.take(4);
    try budget.take(6);
    try std.testing.expectEqual(@as(usize, 10), budget.used);
    try std.testing.expectError(error.StreamResponseTooLarge, budget.take(1));
    try std.testing.expectError(error.StreamResponseTooLarge, budget.take(std.math.maxInt(usize)));
    try std.testing.expectEqual(@as(usize, std.math.maxInt(usize)), budget.used);
}

test "Budget reports the bytes remaining before its ceiling" {
    var budget: Budget = .{ .max = 10 };
    try std.testing.expectEqual(@as(usize, 10), budget.remaining());
    try budget.take(4);
    try std.testing.expectEqual(@as(usize, 6), budget.remaining());
    try budget.take(6);
    try std.testing.expectEqual(@as(usize, 0), budget.remaining());
    try std.testing.expectError(error.StreamResponseTooLarge, budget.take(5));
    try std.testing.expectEqual(@as(usize, 0), budget.remaining());
}

test "allows refuses a spent attempt bound and a hint past the cap" {
    const retry: Retry = .{ .attempts_max = 3, .backoff_ms_max = 16_000 };
    try std.testing.expect(retry.allows(.{ .attempt = 1 }));
    try std.testing.expect(retry.allows(.{ .attempt = 2 }));
    try std.testing.expect(!retry.allows(.{ .attempt = 3 }));
    try std.testing.expect(!retry.allows(.{ .attempt = 4 }));

    try std.testing.expect(retry.allows(.{ .attempt = 1, .suggested_ms = 16_000 }));
    try std.testing.expect(!retry.allows(.{ .attempt = 1, .suggested_ms = 16_001 }));
    try std.testing.expect(!retry.allows(.{ .attempt = 1, .suggested_ms = 3_600_000 }));

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
    try std.testing.expectEqual(
        @as(u64, 5000),
        retry.backoffMs(.{ .attempt = 1, .suggested_ms = 5000 }),
    );
    try std.testing.expectEqual(
        @as(u64, 200),
        retry.backoffMs(.{ .attempt = 3, .suggested_ms = 200 }),
    );
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
    try std.testing.expect(!deadline.expired(io));
    try std.testing.expectEqual(@as(u64, 42), try deadline.call(io, fastWork, .{io}));
    try io.sleep(.fromMilliseconds(150), .awake);
    try std.testing.expect(deadline.expired(io));
    try std.testing.expectError(error.Timeout, deadline.call(io, fastWork, .{io}));
}

test "the DwarfStar timeout defaults are one hour and independent" {
    const timeouts: ProviderTimeouts = .{};
    try std.testing.expectEqual(timeouts.anthropic.connect_ms, timeouts.openai.connect_ms);
    try std.testing.expectEqual(timeouts.anthropic.connect_ms, timeouts.google.connect_ms);
    try std.testing.expectEqual(timeouts.anthropic.connect_ms, timeouts.xai.connect_ms);
    try std.testing.expectEqual(timeouts.anthropic.connect_ms, timeouts.openrouter.connect_ms);
    try std.testing.expectEqual(timeouts.anthropic.connect_ms, timeouts.deepseek.connect_ms);
    try std.testing.expectEqual(@as(Timeouts, .{}), timeouts.anthropic);
    try std.testing.expect(timeouts.openai.idle_ms > timeouts.anthropic.idle_ms);
    try std.testing.expectEqual(timeouts.openai.idle_ms, timeouts.google.idle_ms);
    try std.testing.expectEqual(timeouts.openai.idle_ms, timeouts.xai.idle_ms);
    try std.testing.expectEqual(timeouts.openai.idle_ms, timeouts.openrouter.idle_ms);
    try std.testing.expectEqual(timeouts.openai.idle_ms, timeouts.deepseek.idle_ms);
    try std.testing.expectEqual(@as(u64, 3_600_000), timeouts.ds4.connect_ms);
    try std.testing.expectEqual(@as(u64, 3_600_000), timeouts.ds4.idle_ms);
}
