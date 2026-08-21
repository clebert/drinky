//! The loopback OAuth redirect receiver: one bounded HTTP request line under a
//! shared five-minute deadline, with stray connections ignored.

const std = @import("std");

const net = @import("net.zig");

const callback_timeout_ms = 5 * std.time.ms_per_min;
const request_bytes_max = 8 * 1024;
const response_page = "Drinky received authorization. Close this tab.";

pub const Redirect = struct {
    code: []const u8,
    state: []const u8,
};

pub fn receive(
    gpa: std.mem.Allocator,
    io: std.Io,
    server: *std.Io.net.Server,
) !Redirect {
    var source: ServerSource = .{ .io = io, .server = server };
    var bound: TimeoutBound = .{ .io = io, .timeout_ms = callback_timeout_ms };
    return receiveWith(gpa, &bound, &source);
}

fn receiveWith(gpa: std.mem.Allocator, bound: anytype, source: anytype) !Redirect {
    var request_buffer: [request_bytes_max]u8 = undefined;
    var output: Output = .{};
    errdefer output.deinit(gpa);

    bound.call(
        Wire(@TypeOf(source)).receive,
        .{ gpa, source, &request_buffer, &output },
    ) catch |err| switch (err) {
        error.Timeout => return error.CallbackTimeout,
        error.ConcurrencyUnavailable => return error.CallbackTimeoutUnavailable,
        error.StreamTooLong => return error.CallbackRequestTooLarge,
        else => return err,
    };
    return .{ .code = output.code.?, .state = output.state.? };
}

const Output = struct {
    code: ?[]const u8 = null,
    state: ?[]const u8 = null,

    fn deinit(self: *Output, gpa: std.mem.Allocator) void {
        if (self.code) |code| gpa.free(code);
        if (self.state) |state| gpa.free(state);
    }
};

fn Wire(comptime Source: type) type {
    return struct {
        fn receive(
            gpa: std.mem.Allocator,
            source: Source,
            request_buffer: *[request_bytes_max]u8,
            output: *Output,
        ) !void {
            // A stray connection (probe, prefetch, favicon) must not consume the
            // only accept: ignore it and continue to listen until the deadline. A
            // request that carries `code=` or `error=` is the provider redirect
            // and still fails fast when malformed or denied.
            while (true) {
                var connection = try source.accept();
                defer connection.close();

                const request_line = connection.readRequestLine(request_buffer) catch |err|
                    switch (err) {
                        error.EndOfStream, error.ReadFailed => continue,
                        else => return err,
                    };
                output.code = queryParameter(gpa, request_line, "code=") catch |err|
                    switch (err) {
                        error.MissingCallbackParam => if (std.mem.indexOf(
                            u8,
                            request_line,
                            "error=",
                        ) == null) continue else return err,
                        else => return err,
                    };
                output.state = try queryParameter(gpa, request_line, "state=");
                try connection.respondAuthorized();
                return;
            }
        }
    };
}

const ServerSource = struct {
    io: std.Io,
    server: *std.Io.net.Server,

    fn accept(self: *ServerSource) !Connection {
        return .{ .io = self.io, .stream = try self.server.accept(self.io) };
    }
};

const Connection = struct {
    io: std.Io,
    stream: std.Io.net.Stream,

    fn close(self: *Connection) void {
        self.stream.close(self.io);
    }

    fn readRequestLine(
        self: *Connection,
        buffer: *[request_bytes_max]u8,
    ) ![]const u8 {
        var reader = self.stream.reader(self.io, buffer);
        return takeRequestLine(&reader.interface);
    }

    fn respondAuthorized(self: *Connection) !void {
        var write_buffer: [512]u8 = undefined;
        var writer = self.stream.writer(self.io, &write_buffer);
        try writer.interface.print(
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\n" ++
                "Content-Length: {d}\r\nConnection: close\r\n\r\n{s}",
            .{ response_page.len, response_page },
        );
        try writer.interface.flush();
    }
};

fn takeRequestLine(reader: *std.Io.Reader) ![]const u8 {
    const request_line = try reader.takeDelimiterInclusive('\n');
    return request_line[0 .. request_line.len - 1];
}

fn queryParameter(
    gpa: std.mem.Allocator,
    request_line: []const u8,
    needle: []const u8,
) ![]const u8 {
    const at = std.mem.indexOf(u8, request_line, needle) orelse
        return error.MissingCallbackParam;
    const rest = request_line[at + needle.len ..];
    const end = std.mem.findAny(u8, rest, "& \r") orelse rest.len;
    return gpa.dupe(u8, rest[0..end]);
}

const TimeoutBound = struct {
    io: std.Io,
    timeout_ms: u64,

    fn call(
        self: *const TimeoutBound,
        comptime function: anytype,
        args: std.meta.ArgsTuple(@TypeOf(function)),
    ) anyerror!void {
        // `net.race` reserves the timer before the work, and its outer error
        // propagates: the callback refuses to run unbounded.
        return try net.race(self.io, self.timeout_ms, function, args);
    }
};

const Fake = struct {
    behavior: Behavior = .request,
    request: []const u8 = "",
    /// Request lines served one per accept before `request`.
    stray_requests: []const []const u8 = &.{},
    clock_ms: u64 = 0,
    timeout_ms: u64 = 3,
    deadline_ms: ?u64 = null,
    accept_count: usize = 0,
    close_count: usize = 0,
    response_count: usize = 0,
    request_byte_count: usize = 0,

    const Behavior = enum {
        request,
        no_connection,
        slow,
        canceled_accept,
        canceled_read,
        deadline_wins_after_success,
    };

    const Bound = struct {
        fake: *Fake,

        fn call(
            self: Bound,
            comptime function: anytype,
            args: std.meta.ArgsTuple(@TypeOf(function)),
        ) anyerror!void {
            self.fake.deadline_ms = self.fake.clock_ms + self.fake.timeout_ms;
            defer self.fake.deadline_ms = null;
            try @call(.auto, function, args);
            if (self.fake.behavior == .deadline_wins_after_success) return error.Timeout;
        }
    };

    const Source = struct {
        fake: *Fake,

        fn accept(self: Source) !Fake.Connection {
            return switch (self.fake.behavior) {
                .no_connection => if (self.fake.deadline_ms) |deadline_ms| timeout: {
                    self.fake.clock_ms = deadline_ms;
                    break :timeout error.Timeout;
                } else error.UnboundedAccept,
                .canceled_accept => error.Canceled,
                else => accepted: {
                    self.fake.accept_count += 1;
                    break :accepted .{ .fake = self.fake };
                },
            };
        }
    };

    const Connection = struct {
        fake: *Fake,

        fn close(self: *Fake.Connection) void {
            self.fake.close_count += 1;
        }

        fn readRequestLine(
            self: *Fake.Connection,
            buffer: *[request_bytes_max]u8,
        ) ![]const u8 {
            return switch (self.fake.behavior) {
                .slow => self.readSlow(),
                .canceled_read => error.Canceled,
                .request, .deadline_wins_after_success => self.readRequest(buffer),
                .no_connection, .canceled_accept => unreachable,
            };
        }

        fn readSlow(self: *Fake.Connection) ![]const u8 {
            for (0..request_bytes_max) |_| {
                self.fake.clock_ms += 1;
                self.fake.request_byte_count += 1;
                if (self.fake.deadline_ms) |deadline_ms| {
                    if (self.fake.clock_ms >= deadline_ms) return error.Timeout;
                } else if (self.fake.request_byte_count == 16) {
                    return error.UnboundedRead;
                }
            }
            return error.StreamTooLong;
        }

        fn readRequest(
            self: *Fake.Connection,
            buffer: *[request_bytes_max]u8,
        ) ![]const u8 {
            const raw = if (self.fake.stray_requests.len == 0) self.fake.request else next: {
                defer self.fake.stray_requests = self.fake.stray_requests[1..];
                break :next self.fake.stray_requests[0];
            };
            var reader = std.testing.Reader.init(buffer, &.{.{ .buffer = raw }});
            const request_line = try takeRequestLine(&reader.interface);
            self.fake.request_byte_count = request_line.len + 1;
            return request_line;
        }

        fn respondAuthorized(self: *Fake.Connection) !void {
            self.fake.response_count += 1;
        }
    };
};

fn receiveFake(fake: *Fake) !Redirect {
    var bound: Fake.Bound = .{ .fake = fake };
    return receiveWith(
        std.testing.allocator,
        &bound,
        Fake.Source{ .fake = fake },
    );
}

fn stalledWork(io: std.Io) anyerror!void {
    try io.sleep(.fromSeconds(60), .awake);
}

test "callback refuses to run without deadline concurrency" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var bound: TimeoutBound = .{ .io = io, .timeout_ms = 1 };
    var fake: Fake = .{
        .request = "GET /callback?code=code&state=state HTTP/1.1\r\n",
    };

    try std.testing.expectError(
        error.CallbackTimeoutUnavailable,
        receiveWith(
            std.testing.allocator,
            &bound,
            Fake.Source{ .fake = &fake },
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.accept_count);
}

test "callback work does not start unless its deadline timer is reserved" {
    var threaded: std.Io.Threaded = .init(
        std.testing.allocator,
        .{ .concurrent_limit = .limited(1) },
    );
    defer threaded.deinit();
    const io = threaded.io();
    var bound: TimeoutBound = .{ .io = io, .timeout_ms = callback_timeout_ms };
    var fake: Fake = .{
        .request = "GET /callback?code=code&state=state HTTP/1.1\r\n",
    };

    try std.testing.expectError(
        error.CallbackTimeoutUnavailable,
        receiveWith(
            std.testing.allocator,
            &bound,
            Fake.Source{ .fake = &fake },
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.accept_count);
}

test "callback deadline cancels and reaps work when its timer wins" {
    var threaded: std.Io.Threaded = .init(
        std.testing.allocator,
        .{ .concurrent_limit = .limited(2) },
    );
    defer threaded.deinit();
    const io = threaded.io();
    var bound: TimeoutBound = .{ .io = io, .timeout_ms = 1 };
    try std.testing.expectError(error.Timeout, bound.call(stalledWork, .{io}));
}

test "callback accept has an aggregate deadline" {
    var fake: Fake = .{ .behavior = .no_connection };
    try std.testing.expectError(error.CallbackTimeout, receiveFake(&fake));
    try std.testing.expectEqual(@as(usize, 0), fake.accept_count);
    try std.testing.expectEqual(@as(usize, 0), fake.close_count);
}

test "callback request trickle cannot extend the aggregate deadline" {
    var fake: Fake = .{ .behavior = .slow };
    try std.testing.expectError(error.CallbackTimeout, receiveFake(&fake));
    try std.testing.expectEqual(@as(usize, 1), fake.accept_count);
    try std.testing.expectEqual(@as(usize, 1), fake.close_count);
    try std.testing.expectEqual(fake.timeout_ms, fake.clock_ms);
}

test "callback request has an explicit wire byte limit" {
    var request: [request_bytes_max + 1]u8 = @splat('x');
    request[request.len - 1] = '\n';
    var fake: Fake = .{ .request = &request };
    try std.testing.expectError(error.CallbackRequestTooLarge, receiveFake(&fake));
    try std.testing.expectEqual(@as(usize, 1), fake.close_count);
    try std.testing.expectEqual(@as(usize, 0), fake.response_count);
}

test "callback accepts a request at the wire byte limit" {
    var request: [request_bytes_max]u8 = @splat('x');
    const prefix = "GET /callback?code=code&state=state&padding=";
    @memcpy(request[0..prefix.len], prefix);
    request[request.len - 1] = '\n';

    var fake: Fake = .{ .request = &request };
    const callback = try receiveFake(&fake);
    defer {
        std.testing.allocator.free(callback.code);
        std.testing.allocator.free(callback.state);
    }
    try std.testing.expectEqualStrings("code", callback.code);
    try std.testing.expectEqualStrings("state", callback.state);
    try std.testing.expectEqual(request.len, fake.request_byte_count);
}

test "callback accepts normal requests for both provider paths" {
    for ([_][]const u8{
        "GET /callback?code=anthropic-code&state=anthropic-state HTTP/1.1\r\n",
        "GET /auth/callback?code=openai-code&state=openai-state HTTP/1.1\r\n",
    }) |request| {
        var fake: Fake = .{ .request = request };
        const callback = try receiveFake(&fake);
        defer {
            std.testing.allocator.free(callback.code);
            std.testing.allocator.free(callback.state);
        }
        try std.testing.expect(std.mem.endsWith(u8, callback.code, "code"));
        try std.testing.expect(std.mem.endsWith(u8, callback.state, "state"));
        try std.testing.expectEqual(@as(usize, 1), fake.close_count);
        try std.testing.expectEqual(@as(usize, 1), fake.response_count);
    }
}

test "callback ignores stray connections until the real redirect arrives" {
    var fake: Fake = .{
        .stray_requests = &.{
            // A connection closed before its request line completes, then a
            // request without callback parameters.
            "GET /callback?code=code&state=state HTTP/1.1\r",
            "GET /favicon.ico HTTP/1.1\r\n",
        },
        .request = "GET /callback?code=code&state=state HTTP/1.1\r\n",
    };
    const callback = try receiveFake(&fake);
    defer {
        std.testing.allocator.free(callback.code);
        std.testing.allocator.free(callback.state);
    }
    try std.testing.expectEqualStrings("code", callback.code);
    try std.testing.expectEqualStrings("state", callback.state);
    try std.testing.expectEqual(@as(usize, 3), fake.accept_count);
    try std.testing.expectEqual(@as(usize, 3), fake.close_count);
    try std.testing.expectEqual(@as(usize, 1), fake.response_count);
}

test "callback provider error redirects close without success response" {
    for ([_][]const u8{
        "GET /callback?error=access_denied&state=anthropic-state HTTP/1.1\r\n",
        "GET /auth/callback?error=access_denied&state=openai-state HTTP/1.1\r\n",
    }) |request| {
        var fake: Fake = .{ .request = request };
        try std.testing.expectError(error.MissingCallbackParam, receiveFake(&fake));
        try std.testing.expectEqual(@as(usize, 1), fake.close_count);
        try std.testing.expectEqual(@as(usize, 0), fake.response_count);
    }
}

test "callback error after a partial parse frees the acquired parameter" {
    // `code` present but `state` absent leaves `output.code` allocated when the
    // state lookup fails. The leak-detecting allocator proves the error path
    // frees it.
    var fake: Fake = .{ .request = "GET /callback?code=code HTTP/1.1\r\n" };
    try std.testing.expectError(error.MissingCallbackParam, receiveFake(&fake));
    try std.testing.expectEqual(@as(usize, 1), fake.close_count);
    try std.testing.expectEqual(@as(usize, 0), fake.response_count);
}

test "a deadline race cleans an acquired callback result" {
    var fake: Fake = .{
        .behavior = .deadline_wins_after_success,
        .request = "GET /callback?code=code&state=state HTTP/1.1\r\n",
    };
    try std.testing.expectError(error.CallbackTimeout, receiveFake(&fake));
    try std.testing.expectEqual(@as(usize, 1), fake.close_count);
    try std.testing.expectEqual(@as(usize, 1), fake.response_count);
}

test "callback cancellation closes acquired connections" {
    var accepting: Fake = .{ .behavior = .canceled_accept };
    try std.testing.expectError(error.Canceled, receiveFake(&accepting));
    try std.testing.expectEqual(@as(usize, 0), accepting.close_count);

    var reading: Fake = .{ .behavior = .canceled_read };
    try std.testing.expectError(error.Canceled, receiveFake(&reading));
    try std.testing.expectEqual(@as(usize, 1), reading.close_count);
}
