const std = @import("std");

const net = @import("net.zig");

const callback_timeout_ms = 5 * std.time.ms_per_min;
const request_line_timeout_ms = std.time.ms_per_s;
const request_bytes_max = 8 * 1024;
const request_frame_bytes = "GET ".len + " HTTP/1.1\r\n".len;
const response_page = "Drinky received authorization. Close this tab.";

pub const paste_bytes_max = request_bytes_max - request_frame_bytes;

pub const Redirect = struct {
    code: []const u8,
    state: ?[]const u8 = null,
};

pub const Binding = enum {
    state,
    path,
};

pub fn bindingOf(comptime oauth: type) Binding {
    return if (@hasDecl(oauth, "callback_path_len")) .path else .state;
}

pub fn receive(
    gpa: std.mem.Allocator,
    io: std.Io,
    server: *std.Io.net.Server,
    path: ?[]const u8,
) !Redirect {
    return receiveBounded(gpa, io, server, .{
        .timeout_ms = callback_timeout_ms,
        .request_line_timeout_ms = request_line_timeout_ms,
    }, path);
}

const Wait = struct {
    timeout_ms: u64,
    request_line_timeout_ms: u64,
};

fn receiveBounded(
    gpa: std.mem.Allocator,
    io: std.Io,
    server: *std.Io.net.Server,
    wait: Wait,
    path: ?[]const u8,
) !Redirect {
    var source: ServerSource = .{ .io = io, .server = server };
    var bound: TimeoutBound = .{
        .io = io,
        .timeout_ms = wait.timeout_ms,
        .request_line_timeout_ms = wait.request_line_timeout_ms,
    };
    return receiveWith(gpa, &bound, &source, path);
}

pub fn holdsStateRedirect(line: []const u8) bool {
    if (!fitsRequestLine(line)) return false;
    if (std.mem.indexOf(u8, line, "error=") != null) return true;
    return std.mem.indexOf(u8, line, "code=") != null and
        std.mem.indexOf(u8, line, "state=") != null;
}

pub const PasteOptions = struct {
    line: []const u8,
    path: []const u8,
};

pub fn holdsPathRedirect(options: *const PasteOptions) bool {
    if (!fitsRequestLine(options.line)) return false;
    if (std.mem.indexOf(u8, options.line, "error=") == null and
        std.mem.indexOf(u8, options.line, "code=") == null) return false;
    const found = targetPath(options.line) orelse return false;
    return std.mem.eql(u8, found, options.path);
}

fn fitsRequestLine(line: []const u8) bool {
    if (line.len == 0 or line.len > paste_bytes_max) return false;
    for (line) |byte| if (byte <= ' ' or byte == 0x7f) return false;
    return true;
}

pub fn replay(io: std.Io, port: u16, line: []const u8) !void {
    var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    const stream = try address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);
    var write_buffer: [512]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.print("GET {s} HTTP/1.1\r\n\r\n", .{line});
    try writer.interface.flush();
}

fn receiveWith(
    gpa: std.mem.Allocator,
    bound: anytype,
    source: anytype,
    path: ?[]const u8,
) !Redirect {
    var request_buffer: [request_bytes_max]u8 = undefined;
    var output: Output = .{};
    errdefer output.deinit(gpa);

    bound.call(
        Wire(@TypeOf(source), @TypeOf(bound)).receive,
        .{ gpa, source, bound, path, &request_buffer, &output },
    ) catch |err| switch (err) {
        error.Timeout => return error.CallbackTimeout,
        error.ConcurrencyUnavailable => return error.CallbackTimeoutUnavailable,
        error.StreamTooLong => return error.CallbackRequestTooLarge,
        else => return err,
    };
    return .{ .code = output.code.?, .state = output.state };
}

const Output = struct {
    code: ?[]const u8 = null,
    state: ?[]const u8 = null,

    fn deinit(self: *Output, gpa: std.mem.Allocator) void {
        if (self.code) |code| gpa.free(code);
        if (self.state) |state| gpa.free(state);
    }
};

fn Wire(comptime Source: type, comptime Bound: type) type {
    return struct {
        fn receive(
            gpa: std.mem.Allocator,
            source: Source,
            bound: Bound,
            path: ?[]const u8,
            request_buffer: *[request_bytes_max]u8,
            output: *Output,
        ) !void {
            while (true) {
                var connection = try source.accept();
                defer connection.close();

                const request_line = bound.readRequestLine(
                    @TypeOf(connection).readRequestLine,
                    .{ &connection, request_buffer },
                ) catch |err| switch (err) {
                    error.EndOfStream,
                    error.ReadFailed,
                    error.StrayProtocol,
                    error.RequestLineTimeout,
                    => continue,
                    else => return err,
                };
                if (path) |wanted| {
                    const found = requestPath(request_line) orelse continue;
                    if (!std.mem.eql(u8, found, wanted)) continue;
                }
                output.code = queryParameter(gpa, request_line, "code=") catch |err|
                    switch (err) {
                        error.MissingCallbackParam => if (std.mem.indexOf(
                            u8,
                            request_line,
                            "error=",
                        ) == null) continue else return error.AuthorizationFailed,
                        else => return err,
                    };
                output.state = queryParameter(gpa, request_line, "state=") catch |err|
                    switch (err) {
                        error.MissingCallbackParam => null,
                        else => return err,
                    };
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
    if (!std.ascii.isUpper(try reader.peekByte())) return error.StrayProtocol;
    const request_line = try reader.takeDelimiterInclusive('\n');
    return request_line[0 .. request_line.len - 1];
}

fn requestPath(request_line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, request_line, "GET ")) return null;
    const rest = request_line["GET ".len..];
    const end = std.mem.findAny(u8, rest, " \r") orelse rest.len;
    return targetPath(rest[0..end]);
}

fn targetPath(target: []const u8) ?[]const u8 {
    if (target.len == 0) return null;
    const after_host = if (std.mem.indexOf(u8, target, "://")) |scheme| body: {
        const host = target[scheme + 3 ..];
        const path_start = std.mem.indexOfScalar(u8, host, '/') orelse return "/";
        break :body host[path_start..];
    } else target;
    if (after_host[0] != '/') return null;
    const query = std.mem.indexOfScalar(u8, after_host, '?') orelse after_host.len;
    return after_host[0..query];
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
    request_line_timeout_ms: u64,

    fn call(
        self: *const TimeoutBound,
        comptime function: anytype,
        args: std.meta.ArgsTuple(@TypeOf(function)),
    ) anyerror!void {
        return try net.race(self.io, self.timeout_ms, function, args);
    }

    fn readRequestLine(
        self: *const TimeoutBound,
        comptime function: anytype,
        args: std.meta.ArgsTuple(@TypeOf(function)),
    ) anyerror![]const u8 {
        const bounded: anyerror![]const u8 = net.race(
            self.io,
            self.request_line_timeout_ms,
            function,
            args,
        ) catch |err| switch (err) {
            error.ConcurrencyUnavailable => return error.ConcurrencyUnavailable,
        };
        return bounded catch |err| switch (err) {
            error.Timeout => error.RequestLineTimeout,
            else => err,
        };
    }
};

const Fake = struct {
    behavior: Behavior = .request,
    request: []const u8 = "",
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

        fn readRequestLine(
            self: Bound,
            comptime function: anytype,
            args: std.meta.ArgsTuple(@TypeOf(function)),
        ) anyerror![]const u8 {
            _ = self;
            return @call(.auto, function, args);
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
    return receiveFakePath(fake, null);
}

fn receiveFakePath(fake: *Fake, path: ?[]const u8) !Redirect {
    var bound: Fake.Bound = .{ .fake = fake };
    return receiveWith(
        std.testing.allocator,
        &bound,
        Fake.Source{ .fake = fake },
        path,
    );
}

fn stalledWork(io: std.Io) anyerror!void {
    try io.sleep(.fromSeconds(60), .awake);
}

test "callback refuses to run without deadline concurrency" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var bound: TimeoutBound = .{
        .io = io,
        .timeout_ms = 1,
        .request_line_timeout_ms = request_line_timeout_ms,
    };
    var fake: Fake = .{
        .request = "GET /callback?code=code&state=state HTTP/1.1\r\n",
    };

    try std.testing.expectError(
        error.CallbackTimeoutUnavailable,
        receiveWith(
            std.testing.allocator,
            &bound,
            Fake.Source{ .fake = &fake },
            null,
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
    var bound: TimeoutBound = .{
        .io = io,
        .timeout_ms = callback_timeout_ms,
        .request_line_timeout_ms = request_line_timeout_ms,
    };
    var fake: Fake = .{
        .request = "GET /callback?code=code&state=state HTTP/1.1\r\n",
    };

    try std.testing.expectError(
        error.CallbackTimeoutUnavailable,
        receiveWith(
            std.testing.allocator,
            &bound,
            Fake.Source{ .fake = &fake },
            null,
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
    var bound: TimeoutBound = .{
        .io = io,
        .timeout_ms = 1,
        .request_line_timeout_ms = request_line_timeout_ms,
    };
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
        if (callback.state) |state| std.testing.allocator.free(state);
    }
    try std.testing.expectEqualStrings("code", callback.code);
    try std.testing.expectEqualStrings("state", callback.state.?);
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
            if (callback.state) |state| std.testing.allocator.free(state);
        }
        try std.testing.expect(std.mem.endsWith(u8, callback.code, "code"));
        try std.testing.expect(std.mem.endsWith(u8, callback.state.?, "state"));
        try std.testing.expectEqual(@as(usize, 1), fake.close_count);
        try std.testing.expectEqual(@as(usize, 1), fake.response_count);
    }
}

test "callback ignores stray connections until the real redirect arrives" {
    var fake: Fake = .{
        .stray_requests = &.{
            "GET /callback?code=code&state=state HTTP/1.1\r",
            "GET /favicon.ico HTTP/1.1\r\n",
        },
        .request = "GET /callback?code=code&state=state HTTP/1.1\r\n",
    };
    const callback = try receiveFake(&fake);
    defer {
        std.testing.allocator.free(callback.code);
        if (callback.state) |state| std.testing.allocator.free(state);
    }
    try std.testing.expectEqualStrings("code", callback.code);
    try std.testing.expectEqualStrings("state", callback.state.?);
    try std.testing.expectEqual(@as(usize, 3), fake.accept_count);
    try std.testing.expectEqual(@as(usize, 3), fake.close_count);
    try std.testing.expectEqual(@as(usize, 1), fake.response_count);
}

test "callback classifies a TLS handshake from its first byte" {
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
        if (callback.state) |state| std.testing.allocator.free(state);
    }
    try std.testing.expectEqualStrings("code", callback.code);
    try std.testing.expectEqualStrings("state", callback.state.?);
    try std.testing.expectEqual(@as(usize, 2), fake.accept_count);
    try std.testing.expectEqual(@as(usize, 2), fake.close_count);
    try std.testing.expectEqual(@as(usize, 1), fake.response_count);
}

test "a torn success response does not fail an authorized login" {
    var fake: Fake = .{
        .request = "GET /auth/callback?code=code&state=state HTTP/1.1\r\n",
        .respond_fails = true,
    };
    const callback = try receiveFake(&fake);
    defer {
        std.testing.allocator.free(callback.code);
        if (callback.state) |state| std.testing.allocator.free(state);
    }
    try std.testing.expectEqualStrings("code", callback.code);
    try std.testing.expectEqualStrings("state", callback.state.?);
    try std.testing.expectEqual(@as(usize, 1), fake.response_count);
    try std.testing.expectEqual(@as(usize, 1), fake.close_count);
}

test "callback provider error redirects close without success response" {
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

test "a grant without state still completes the redirect" {
    var fake: Fake = .{ .request = "GET /callback?code=code HTTP/1.1\r\n" };
    const callback = try receiveFake(&fake);
    defer {
        std.testing.allocator.free(callback.code);
        if (callback.state) |state| std.testing.allocator.free(state);
    }
    try std.testing.expectEqualStrings("code", callback.code);
    try std.testing.expect(callback.state == null);
    try std.testing.expectEqual(@as(usize, 1), fake.close_count);
    try std.testing.expectEqual(@as(usize, 1), fake.response_count);
}

test "a random callback path binds the redirect" {
    var fake: Fake = .{
        .stray_requests = &.{"GET /other?code=wrong HTTP/1.1\r\n"},
        .request = "GET /deadbeef?code=code HTTP/1.1\r\n",
    };
    const callback = try receiveFakePath(&fake, "/deadbeef");
    defer {
        std.testing.allocator.free(callback.code);
        if (callback.state) |state| std.testing.allocator.free(state);
    }
    try std.testing.expectEqualStrings("code", callback.code);
    try std.testing.expectEqual(@as(usize, 2), fake.accept_count);
    try std.testing.expectEqual(@as(usize, 1), fake.response_count);
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

test bindingOf {
    const path_flow = struct {
        pub const callback_port = 53694;
        pub const callback_path_len = 33;
    };
    const state_flow = struct {
        pub const callback_port = 1455;
    };
    try std.testing.expectEqual(Binding.path, bindingOf(path_flow));
    try std.testing.expectEqual(Binding.state, bindingOf(state_flow));
}

test "a pasted line of another callback path cannot complete a sign-in" {
    try std.testing.expect(!holdsPathRedirect(&.{
        .line = "http://localhost:53694/other?code=only",
        .path = "/deadbeef",
    }));
    try std.testing.expect(!holdsPathRedirect(&.{
        .line = "http://localhost:53694/other?error=access_denied",
        .path = "/deadbeef",
    }));
    try std.testing.expect(holdsPathRedirect(&.{
        .line = "http://localhost:53694/deadbeef?code=only",
        .path = "/deadbeef",
    }));
    try std.testing.expect(holdsPathRedirect(&.{ .line = "/deadbeef?code=only", .path = "/deadbeef" }));
    try std.testing.expect(holdsPathRedirect(&.{
        .line = "/deadbeef?error=access_denied",
        .path = "/deadbeef",
    }));
}

test "a pasted state line must hold a callback outcome and fit the request line" {
    try std.testing.expect(holdsStateRedirect(
        "https://localhost:1455/auth/callback?code=paste-code&state=paste-state",
    ));
    try std.testing.expect(holdsStateRedirect("code=paste-code&state=paste-state"));
    try std.testing.expect(holdsStateRedirect(
        "https://localhost:1455/auth/callback?error=access_denied&state=paste-state",
    ));
    try std.testing.expect(holdsStateRedirect(
        "https://localhost:1455/auth/callback?error=server_error",
    ));
    try std.testing.expect(!holdsStateRedirect(""));
    try std.testing.expect(!holdsStateRedirect("https://localhost:1455/auth/callback"));
    try std.testing.expect(!holdsStateRedirect("code=a&state=b with a space"));
    try std.testing.expect(!holdsStateRedirect("code=a&state=b\x1b"));
    try std.testing.expect(!holdsStateRedirect(
        "https://localhost:1455/auth/callback?code=only",
    ));
    try std.testing.expect(!holdsStateRedirect(
        "https://localhost:1455/auth/callback?state=only",
    ));
    var oversized: [paste_bytes_max + 1]u8 = @splat('x');
    @memcpy(oversized[0.."code=x&state=".len], "code=x&state=");
    try std.testing.expect(!holdsStateRedirect(&oversized));
}

test "a pasted path line must name the callback path and an outcome" {
    try std.testing.expect(!holdsPathRedirect(&.{ .line = "code=only", .path = "/deadbeef" }));
    try std.testing.expect(!holdsPathRedirect(&.{ .line = "code=a&state=b", .path = "/deadbeef" }));
    try std.testing.expect(!holdsPathRedirect(&.{ .line = "", .path = "/deadbeef" }));
    try std.testing.expect(!holdsPathRedirect(&.{ .line = "/deadbeef", .path = "/deadbeef" }));
    try std.testing.expect(!holdsPathRedirect(&.{
        .line = "http://localhost:53694",
        .path = "/deadbeef",
    }));
    try std.testing.expect(!holdsPathRedirect(&.{
        .line = "/deadbeef?code=a with a space",
        .path = "/deadbeef",
    }));
    try std.testing.expect(!holdsPathRedirect(&.{ .line = "/deadbeef?code=a\x1b", .path = "/deadbeef" }));
    var oversized: [paste_bytes_max + 1]u8 = @splat('x');
    @memcpy(oversized[0.."/deadbeef?code=".len], "/deadbeef?code=");
    try std.testing.expect(!holdsPathRedirect(&.{ .line = &oversized, .path = "/deadbeef" }));
}

test "a maximal paste frames a request line at the wire byte limit" {
    var line: [paste_bytes_max]u8 = @splat('x');
    const prefix = "/callback?code=code&state=state&padding=";
    @memcpy(line[0..prefix.len], prefix);
    try std.testing.expect(holdsStateRedirect(&line));

    var request: [request_bytes_max]u8 = undefined;
    const framed = try std.fmt.bufPrint(&request, "GET {s} HTTP/1.1\r\n", .{&line});
    try std.testing.expectEqual(request.len, framed.len);

    var fake: Fake = .{ .request = framed };
    const callback = try receiveFake(&fake);
    defer {
        std.testing.allocator.free(callback.code);
        if (callback.state) |state| std.testing.allocator.free(state);
    }
    try std.testing.expectEqualStrings("code", callback.code);
    try std.testing.expectEqualStrings("state", callback.state.?);
    try std.testing.expectEqual(request.len, fake.request_byte_count);
}

const socket_test_timeout_ms = 5 * std.time.ms_per_s;

const socket_test_wait: Wait = .{
    .timeout_ms = socket_test_timeout_ms,
    .request_line_timeout_ms = request_line_timeout_ms,
};

test "a replayed paste line completes the redirect wait" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var future = try io.concurrent(
        receiveBounded,
        .{ std.testing.allocator, io, &server, socket_test_wait, null },
    );
    errdefer if (future.cancel(io)) |canceled| {
        std.testing.allocator.free(canceled.code);
        if (canceled.state) |state| std.testing.allocator.free(state);
    } else |_| {};
    try replay(
        io,
        server.socket.address.getPort(),
        "https://localhost:1455/auth/callback?code=paste-code&state=paste-state",
    );
    const redirect = try future.await(io);
    defer {
        std.testing.allocator.free(redirect.code);
        if (redirect.state) |state| std.testing.allocator.free(state);
    }
    try std.testing.expectEqualStrings("paste-code", redirect.code);
    try std.testing.expectEqualStrings("paste-state", redirect.state.?);
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
        .{ std.testing.allocator, io, &server, socket_test_wait, null },
    );
    errdefer if (future.cancel(io)) |canceled| {
        std.testing.allocator.free(canceled.code);
        if (canceled.state) |state| std.testing.allocator.free(state);
    } else |_| {};
    try replay(
        io,
        server.socket.address.getPort(),
        "https://localhost:1455/auth/callback?error=access_denied",
    );
    try std.testing.expectError(error.AuthorizationFailed, future.await(io));
}

test "a silent connection cannot blind the listener to a replayed paste" {
    const wait: Wait = .{
        .timeout_ms = socket_test_timeout_ms,
        .request_line_timeout_ms = 50,
    };

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var future = try io.concurrent(
        receiveBounded,
        .{ std.testing.allocator, io, &server, wait, null },
    );
    errdefer if (future.cancel(io)) |canceled| {
        std.testing.allocator.free(canceled.code);
        if (canceled.state) |state| std.testing.allocator.free(state);
    } else |_| {};

    var silent_address: std.Io.net.IpAddress = .{
        .ip4 = .loopback(server.socket.address.getPort()),
    };
    const silent = try silent_address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer silent.close(io);

    try replay(
        io,
        server.socket.address.getPort(),
        "http://localhost:53694/deadbeef?code=paste-code",
    );
    const redirect = try future.await(io);
    defer std.testing.allocator.free(redirect.code);
    try std.testing.expectEqualStrings("paste-code", redirect.code);
}

test "callback cancellation closes acquired connections" {
    var accepting: Fake = .{ .behavior = .canceled_accept };
    try std.testing.expectError(error.Canceled, receiveFake(&accepting));
    try std.testing.expectEqual(@as(usize, 0), accepting.close_count);

    var reading: Fake = .{ .behavior = .canceled_read };
    try std.testing.expectError(error.Canceled, receiveFake(&reading));
    try std.testing.expectEqual(@as(usize, 1), reading.close_count);
}
