//! The loopback OAuth redirect receiver: one bounded HTTP request line under a
//! shared five-minute deadline, with stray connections ignored. A pasted
//! redirect line replays into the same listener, so a browser policy that
//! blocks the plain-HTTP callback cannot strand the login.

const std = @import("std");

const net = @import("net.zig");

const callback_timeout_ms = 5 * std.time.ms_per_min;
const request_bytes_max = 8 * 1024;
const request_frame_bytes = "GET ".len + " HTTP/1.1\r\n".len;
const response_page = "Drinky received authorization. Close this tab.";

/// The longest pasted line that fits the wire byte limit with the request
/// frame around it. A paste reader sizes its line storage with this, so the
/// two limits cannot disagree.
pub const paste_bytes_max = request_bytes_max - request_frame_bytes;

pub const Redirect = struct {
    code: []const u8,
    state: []const u8,
};

pub fn receive(
    gpa: std.mem.Allocator,
    io: std.Io,
    server: *std.Io.net.Server,
) !Redirect {
    return receiveBounded(gpa, io, server, callback_timeout_ms);
}

/// The redirect wait under an explicit deadline. `receive` holds the deadline of
/// the product, and a socket test holds a short one, so a stalled accept reads
/// as a failed test and not as a five-minute hang. Both callers share this one
/// wire path.
fn receiveBounded(
    gpa: std.mem.Allocator,
    io: std.Io,
    server: *std.Io.net.Server,
    timeout_ms: u64,
) !Redirect {
    var source: ServerSource = .{ .io = io, .server = server };
    var bound: TimeoutBound = .{ .io = io, .timeout_ms = timeout_ms };
    return receiveWith(gpa, &bound, &source);
}

/// Whether a pasted line can serve as the redirect request target: a callback
/// outcome, no byte that breaks a request line, and room for the request frame
/// within the wire byte limit.
///
/// RFC 6749 fixes the name of each outcome: `code` for a grant and `error` for
/// a failure. The filter demands of each outcome exactly what the listener
/// demands. A line that passes therefore reaches the verdict of the listener.
/// A grant needs its `state` for the token exchange. A failure needs nothing
/// more, because its own name ends the login.
pub fn holdsRedirect(line: []const u8) bool {
    if (line.len == 0 or line.len > paste_bytes_max) return false;
    for (line) |byte| if (byte <= ' ' or byte == 0x7f) return false;
    if (std.mem.indexOf(u8, line, "error=") != null) return true;
    return std.mem.indexOf(u8, line, "code=") != null and
        std.mem.indexOf(u8, line, "state=") != null;
}

/// Replay a pasted redirect line to the local listener on `port` as one HTTP
/// request, with the line as the request target. The listener parses only the
/// request line, and its success response is best effort, so replay closes
/// right after the flush and never waits on the listener. A listener stuck on
/// a stalled stray connection therefore cannot stall the paste watch.
pub fn replay(io: std.Io, port: u16, line: []const u8) !void {
    var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    const stream = try address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);
    var write_buffer: [512]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.print("GET {s} HTTP/1.1\r\n\r\n", .{line});
    try writer.interface.flush();
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
            // A stray connection must not consume the only accept. A probe, a
            // prefetch, a favicon fetch, and a TLS handshake are all stray.
            // Ignore one and listen on until the deadline.
            //
            // A request that carries `code=` or `error=` is the provider
            // redirect. It still fails fast when malformed or denied.
            while (true) {
                var connection = try source.accept();
                defer connection.close();

                const request_line = connection.readRequestLine(request_buffer) catch |err|
                    switch (err) {
                        error.EndOfStream, error.ReadFailed, error.StrayProtocol => continue,
                        else => return err,
                    };
                output.code = queryParameter(gpa, request_line, "code=") catch |err|
                    switch (err) {
                        // RFC 6749 fixes the `error` parameter of a failed
                        // authorization, so its presence marks a real redirect
                        // that carries no code. Every code of that parameter
                        // ends this login, so the reason stays unread.
                        error.MissingCallbackParam => if (std.mem.indexOf(
                            u8,
                            request_line,
                            "error=",
                        ) == null) continue else return error.AuthorizationFailed,
                        else => return err,
                    };
                output.state = try queryParameter(gpa, request_line, "state=");
                // The captured redirect authorizes the login. A torn success
                // page must not fail it, so the response is best effort. A
                // replayed paste closes its connection right after the send,
                // and this tolerance is what makes that close harmless.
                connection.respondAuthorized() catch {};
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
    // An HTTP method starts with an uppercase letter, while a TLS handshake
    // from a browser HTTPS upgrade starts with 0x16. Such a client waits for a
    // TLS response and sends no request line, so a wait for a newline holds
    // the accept loop until the deadline. Classify the first byte, so a fast
    // close lets the browser fall back to plain HTTP.
    if (!std.ascii.isUpper(try reader.peekByte())) return error.StrayProtocol;
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
    respond_fails: bool = false,
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
            if (self.fake.respond_fails) return error.ResponseTorn;
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
    const prefix = "GET /callback?padding=";
    @memcpy(request[0..prefix.len], prefix);
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

test "callback classifies a TLS handshake from its first byte" {
    // A browser HTTPS upgrade sends a TLS ClientHello to this plaintext port.
    // Such a stream carries no newline, so a wait for one stalls the accept
    // loop and shows the browser an error page instead of a fast failure.
    var buffer: [request_bytes_max]u8 = undefined;
    var reader = std.testing.Reader.init(&buffer, &.{
        .{ .buffer = "\x16\x03\x01\x02\x00\x01\x00\x01\xfc\x03\x03" },
    });
    try std.testing.expectError(error.StrayProtocol, takeRequestLine(&reader.interface));
}

test "callback ignores a TLS handshake until the real redirect arrives" {
    var fake: Fake = .{
        .stray_requests = &.{"\x16\x03\x01\x02\x00\x01\x00\x01\xfc\x03\x03"},
        .request = "GET /auth/callback?code=code&state=state HTTP/1.1\r\n",
    };
    const callback = try receiveFake(&fake);
    defer {
        std.testing.allocator.free(callback.code);
        std.testing.allocator.free(callback.state);
    }
    try std.testing.expectEqualStrings("code", callback.code);
    try std.testing.expectEqualStrings("state", callback.state);
    try std.testing.expectEqual(@as(usize, 2), fake.accept_count);
    try std.testing.expectEqual(@as(usize, 2), fake.close_count);
    try std.testing.expectEqual(@as(usize, 1), fake.response_count);
}

test "a torn success response does not fail an authorized login" {
    // A replayed paste closes its connection right after the send, so the
    // success-page write can fail. The captured redirect already authorizes
    // the login, and the failure must stay cosmetic.
    var fake: Fake = .{
        .request = "GET /auth/callback?code=code&state=state HTTP/1.1\r\n",
        .respond_fails = true,
    };
    const callback = try receiveFake(&fake);
    defer {
        std.testing.allocator.free(callback.code);
        std.testing.allocator.free(callback.state);
    }
    try std.testing.expectEqualStrings("code", callback.code);
    try std.testing.expectEqualStrings("state", callback.state);
    try std.testing.expectEqual(@as(usize, 1), fake.response_count);
    try std.testing.expectEqual(@as(usize, 1), fake.close_count);
}

test "callback provider error redirects close without success response" {
    // Every code ends this login, registered or not, and an absent state does
    // not change the verdict.
    for ([_][]const u8{
        "GET /callback?error=access_denied&state=anthropic-state HTTP/1.1\r\n",
        "GET /auth/callback?error=access_denied&state=openai-state HTTP/1.1\r\n",
        "GET /callback?error=server_error HTTP/1.1\r\n",
        "GET /callback?error=a_code_no_one_registered&state=state HTTP/1.1\r\n",
    }) |request| {
        var fake: Fake = .{ .request = request };
        try std.testing.expectError(error.AuthorizationFailed, receiveFake(&fake));
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

test "a pasted line must hold a callback outcome and fit the request line" {
    try std.testing.expect(holdsRedirect(
        "https://localhost:1455/auth/callback?code=paste-code&state=paste-state",
    ));
    try std.testing.expect(holdsRedirect("code=paste-code&state=paste-state"));
    // The listener ends the login on the `error` name alone, so a failure line
    // passes with or without its state.
    try std.testing.expect(holdsRedirect(
        "https://localhost:1455/auth/callback?error=access_denied&state=paste-state",
    ));
    try std.testing.expect(holdsRedirect(
        "https://localhost:1455/auth/callback?error=server_error",
    ));
    try std.testing.expect(!holdsRedirect(""));
    try std.testing.expect(!holdsRedirect("https://localhost:1455/auth/callback"));
    // A grant without its state reaches no token exchange, so the paste stops
    // here and asks for the complete URL.
    try std.testing.expect(!holdsRedirect("https://localhost:1455/auth/callback?code=only"));
    try std.testing.expect(!holdsRedirect("https://localhost:1455/auth/callback?state=only"));
    try std.testing.expect(!holdsRedirect("code=a&state=b with a space"));
    try std.testing.expect(!holdsRedirect("code=a&state=b\x1b"));
    // One byte past the limit cannot fit the wire byte limit with its frame.
    var oversized: [paste_bytes_max + 1]u8 = @splat('x');
    @memcpy(oversized[0.."code=x&state=".len], "code=x&state=");
    try std.testing.expect(!holdsRedirect(&oversized));
}

test "a maximal paste frames a request line at the wire byte limit" {
    // The two limits meet here. The longest accepted paste must produce the
    // longest request line the listener can read, so an edit of the frame
    // constant cannot silently reject a maximal paste.
    var line: [paste_bytes_max]u8 = @splat('x');
    const prefix = "/callback?code=code&state=state&padding=";
    @memcpy(line[0..prefix.len], prefix);
    try std.testing.expect(holdsRedirect(&line));

    var request: [request_bytes_max]u8 = undefined;
    const framed = try std.fmt.bufPrint(&request, "GET {s} HTTP/1.1\r\n", .{&line});
    try std.testing.expectEqual(request.len, framed.len);

    var fake: Fake = .{ .request = framed };
    const callback = try receiveFake(&fake);
    defer {
        std.testing.allocator.free(callback.code);
        std.testing.allocator.free(callback.state);
    }
    try std.testing.expectEqualStrings("code", callback.code);
    try std.testing.expectEqualStrings("state", callback.state);
    try std.testing.expectEqual(request.len, fake.request_byte_count);
}

/// The deadline of a socket test below. It bounds a stalled accept, and every
/// loopback accept of a test lands far inside it.
const socket_test_timeout_ms = 5 * std.time.ms_per_s;

test "a replayed paste line completes the redirect wait" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var future = try io.concurrent(
        receiveBounded,
        .{ std.testing.allocator, io, &server, socket_test_timeout_ms },
    );
    errdefer if (future.cancel(io)) |canceled| {
        std.testing.allocator.free(canceled.code);
        std.testing.allocator.free(canceled.state);
    } else |_| {};
    try replay(
        io,
        server.socket.address.getPort(),
        "https://localhost:1455/auth/callback?code=paste-code&state=paste-state",
    );
    const redirect = try future.await(io);
    defer {
        std.testing.allocator.free(redirect.code);
        std.testing.allocator.free(redirect.state);
    }
    try std.testing.expectEqualStrings("paste-code", redirect.code);
    try std.testing.expectEqualStrings("paste-state", redirect.state);
}

test "a replayed denial line ends the redirect wait with the listener's verdict" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var future = try io.concurrent(
        receiveBounded,
        .{ std.testing.allocator, io, &server, socket_test_timeout_ms },
    );
    errdefer if (future.cancel(io)) |canceled| {
        std.testing.allocator.free(canceled.code);
        std.testing.allocator.free(canceled.state);
    } else |_| {};
    // A denial line carries no state, so the listener's verdict alone can end
    // this wait.
    try replay(
        io,
        server.socket.address.getPort(),
        "https://localhost:1455/auth/callback?error=access_denied",
    );
    try std.testing.expectError(error.AuthorizationFailed, future.await(io));
}

test "callback cancellation closes acquired connections" {
    var accepting: Fake = .{ .behavior = .canceled_accept };
    try std.testing.expectError(error.Canceled, receiveFake(&accepting));
    try std.testing.expectEqual(@as(usize, 0), accepting.close_count);

    var reading: Fake = .{ .behavior = .canceled_read };
    try std.testing.expectError(error.Canceled, receiveFake(&reading));
    try std.testing.expectEqual(@as(usize, 1), reading.close_count);
}
