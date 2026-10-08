const std = @import("std");

const core = @import("core");

const callback_timeout_ms = 5 * std.time.ms_per_min;
const request_line_timeout_ms = std.time.ms_per_s;
const request_bytes_max = 8 * 1024;
const request_frame_bytes = "GET ".len + " HTTP/1.1\r\n".len;
const response_page = "Drinky received the authorization. Close this tab.";

pub const paste_bytes_max = request_bytes_max - request_frame_bytes;

pub const path_bytes_max = 64;

pub const Redirect = struct {
    code: []const u8,
    state: ?[]const u8 = null,

    pub fn deinit(self: *const Redirect, gpa: std.mem.Allocator) void {
        gpa.free(self.code);
        if (self.state) |state| gpa.free(state);
    }
};

pub const Binding = enum {
    state,
    path,
};

pub const Expected = union(Binding) {
    state: []const u8,
    path: []const u8,
};

pub const Loopback = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const ReceiveError = std.Io.net.Server.AcceptError || error{
        Canceled,
        OutOfMemory,
        AuthorizationFailed,
        CallbackTimeout,
        CallbackTimeoutUnavailable,
        CallbackRequestTooLarge,
    };

    pub const ReplayError = std.Io.net.IpAddress.ConnectError || std.Io.Writer.Error;

    pub const VTable = struct {
        listen: *const fn (ptr: *anyopaque, port: u16) std.Io.net.IpAddress.ListenError!void,
        receive: *const fn (
            ptr: *anyopaque,
            gpa: std.mem.Allocator,
            expected: *const Expected,
        ) ReceiveError!Redirect,
        close: *const fn (ptr: *anyopaque) void,
        replay: *const fn (ptr: *anyopaque, port: u16, line: []const u8) ReplayError!void,
    };

    pub fn listen(self: Loopback, port: u16) std.Io.net.IpAddress.ListenError!void {
        return self.vtable.listen(self.ptr, port);
    }

    pub fn receive(
        self: Loopback,
        gpa: std.mem.Allocator,
        expected: *const Expected,
    ) ReceiveError!Redirect {
        return self.vtable.receive(self.ptr, gpa, expected);
    }

    pub fn close(self: Loopback) void {
        self.vtable.close(self.ptr);
    }

    pub fn replay(self: Loopback, port: u16, line: []const u8) ReplayError!void {
        return self.vtable.replay(self.ptr, port, line);
    }
};

pub const Socket = struct {
    io: std.Io,
    server: ?std.Io.net.Server = null,
    stream: ?std.Io.net.Stream = null,

    const loopback_vtable: Loopback.VTable = .{
        .listen = listenOn,
        .receive = receiveOn,
        .close = closeOn,
        .replay = replayTo,
    };

    const connections_vtable: Connections.VTable = .{
        .accept = accept,
        .readRequestLine = readRequestLine,
        .respondAuthorized = respondAuthorized,
        .hangUp = hangUp,
    };

    pub fn loopback(self: *Socket) Loopback {
        return .{ .ptr = self, .vtable = &loopback_vtable };
    }

    fn of(ptr: *anyopaque) *Socket {
        return @ptrCast(@alignCast(ptr));
    }

    fn listenOn(ptr: *anyopaque, port: u16) std.Io.net.IpAddress.ListenError!void {
        const self = of(ptr);
        std.debug.assert(self.server == null);
        var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        self.server = try address.listen(self.io, .{ .reuse_address = true });
    }

    fn receiveOn(
        ptr: *anyopaque,
        gpa: std.mem.Allocator,
        expected: *const Expected,
    ) Loopback.ReceiveError!Redirect {
        const self = of(ptr);
        std.debug.assert(self.server != null);
        const connections: Connections = .{ .ptr = self, .vtable = &connections_vtable };
        return awaitRedirect(gpa, self.io, connections, expected);
    }

    fn closeOn(ptr: *anyopaque) void {
        const self = of(ptr);
        if (self.server) |*server| server.deinit(self.io);
        self.server = null;
    }

    fn replayTo(ptr: *anyopaque, port: u16, line: []const u8) Loopback.ReplayError!void {
        const self = of(ptr);
        var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        const stream = try address.connect(self.io, .{ .mode = .stream, .protocol = .tcp });
        defer stream.close(self.io);
        var write_buffer: [512]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);
        try writer.interface.print("GET {s} HTTP/1.1\r\n\r\n", .{line});
        try writer.interface.flush();
    }

    fn accept(ptr: *anyopaque) std.Io.net.Server.AcceptError!void {
        const self = of(ptr);
        self.stream = try self.server.?.accept(self.io);
    }

    fn readRequestLine(
        ptr: *anyopaque,
        buffer: *[request_bytes_max]u8,
    ) Connections.ReadError![]const u8 {
        const self = of(ptr);
        var reader = self.stream.?.reader(self.io, buffer);
        return takeRequestLine(&reader.interface);
    }

    fn respondAuthorized(ptr: *anyopaque) std.Io.Writer.Error!void {
        const self = of(ptr);
        var write_buffer: [512]u8 = undefined;
        var writer = self.stream.?.writer(self.io, &write_buffer);
        try writer.interface.print(
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\n" ++
                "Content-Length: {d}\r\nConnection: close\r\n\r\n{s}",
            .{ response_page.len, response_page },
        );
        try writer.interface.flush();
    }

    fn hangUp(ptr: *anyopaque) void {
        const self = of(ptr);
        self.stream.?.close(self.io);
        self.stream = null;
    }
};

const Connections = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        accept: *const fn (ptr: *anyopaque) std.Io.net.Server.AcceptError!void,
        readRequestLine: *const fn (
            ptr: *anyopaque,
            buffer: *[request_bytes_max]u8,
        ) ReadError![]const u8,
        respondAuthorized: *const fn (ptr: *anyopaque) std.Io.Writer.Error!void,
        hangUp: *const fn (ptr: *anyopaque) void,
    };

    const ReadError = std.Io.Reader.DelimiterError || error{ StrayProtocol, Canceled };

    fn accept(self: Connections) std.Io.net.Server.AcceptError!void {
        return self.vtable.accept(self.ptr);
    }

    fn readRequestLine(self: Connections, buffer: *[request_bytes_max]u8) ReadError![]const u8 {
        return self.vtable.readRequestLine(self.ptr, buffer);
    }

    fn respondAuthorized(self: Connections) std.Io.Writer.Error!void {
        return self.vtable.respondAuthorized(self.ptr);
    }

    fn hangUp(self: Connections) void {
        self.vtable.hangUp(self.ptr);
    }
};

const PasteOptions = struct {
    line: []const u8,
    path: []const u8,
};

const Query = struct {
    request_line: []const u8,
    needle: []const u8,
};

pub fn holdsStateRedirect(line: []const u8) bool {
    if (!fitsRequestLine(line)) return false;
    if (std.mem.find(u8, line, "error=") != null) return true;
    return std.mem.find(u8, line, "code=") != null and
        std.mem.find(u8, line, "state=") != null;
}

pub fn holdsPathRedirect(options: *const PasteOptions) bool {
    if (!fitsRequestLine(options.line)) return false;
    if (std.mem.find(u8, options.line, "error=") == null and
        std.mem.find(u8, options.line, "code=") == null) return false;
    const found = targetPath(options.line) orelse return false;
    return std.mem.eql(u8, found, options.path);
}

fn fitsRequestLine(line: []const u8) bool {
    if (line.len == 0 or line.len > paste_bytes_max) return false;
    for (line) |byte| if (byte <= ' ' or byte == 0x7f) return false;
    return true;
}

fn awaitRedirect(
    gpa: std.mem.Allocator,
    io: std.Io,
    connections: Connections,
    expected: *const Expected,
) Loopback.ReceiveError!Redirect {
    return core.timeout.run(
        io,
        callback_timeout_ms,
        acceptRedirect,
        .{ gpa, io, connections, expected },
        releaseRedirect,
    ) catch |err| switch (err) {
        error.Timeout => return error.CallbackTimeout,
        error.ConcurrencyUnavailable => return error.CallbackTimeoutUnavailable,
        error.StreamTooLong => return error.CallbackRequestTooLarge,
        else => |other| return other,
    };
}

fn acceptRedirect(
    gpa: std.mem.Allocator,
    io: std.Io,
    connections: Connections,
    expected: *const Expected,
) !Redirect {
    var request_buffer: [request_bytes_max]u8 = undefined;
    while (true) {
        try connections.accept();
        defer connections.hangUp();

        const request_line = core.timeout.run(
            io,
            request_line_timeout_ms,
            Connections.readRequestLine,
            .{ connections, &request_buffer },
            null,
        ) catch |err| switch (err) {
            error.EndOfStream, error.ReadFailed, error.StrayProtocol, error.Timeout => continue,
            else => |other| return other,
        };
        const redirect = try redirectOf(gpa, request_line, expected) orelse continue;
        connections.respondAuthorized() catch {};
        return redirect;
    }
}

fn releaseRedirect(
    redirect: *const Redirect,
    args: *const std.meta.ArgsTuple(@TypeOf(acceptRedirect)),
) void {
    redirect.deinit(args[0]);
}

pub fn redirectOf(
    gpa: std.mem.Allocator,
    request_line: []const u8,
    expected: *const Expected,
) error{ OutOfMemory, AuthorizationFailed }!?Redirect {
    switch (expected.*) {
        .path => |wanted| {
            const found = requestPath(request_line) orelse return null;
            if (!std.mem.eql(u8, found, wanted)) return null;
        },
        .state => {},
    }
    const code = queryParameter(gpa, &.{
        .request_line = request_line,
        .needle = "code=",
    }) catch |err| switch (err) {
        error.MissingCallbackParam => {
            if (std.mem.find(u8, request_line, "error=") == null) return null;
            if (!endsSignIn(request_line, expected)) return null;
            return error.AuthorizationFailed;
        },
        error.OutOfMemory => |known| return known,
    };
    errdefer gpa.free(code);
    const state = queryParameter(gpa, &.{
        .request_line = request_line,
        .needle = "state=",
    }) catch |err| switch (err) {
        error.MissingCallbackParam => null,
        error.OutOfMemory => |known| return known,
    };
    return .{ .code = code, .state = state };
}

fn takeRequestLine(reader: *std.Io.Reader) Connections.ReadError![]const u8 {
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
    const after_host = if (std.mem.find(u8, target, "://")) |scheme| body: {
        const host = target[scheme + 3 ..];
        const path_start = std.mem.findScalar(u8, host, '/') orelse return "/";
        break :body host[path_start..];
    } else target;
    if (after_host[0] != '/') return null;
    const query = std.mem.findScalar(u8, after_host, '?') orelse after_host.len;
    return after_host[0..query];
}

fn endsSignIn(request_line: []const u8, expected: *const Expected) bool {
    return switch (expected.*) {
        .path => true,
        .state => |wanted| std.mem.eql(
            u8,
            queryValue(&.{ .request_line = request_line, .needle = "state=" }) orelse "",
            wanted,
        ),
    };
}

fn queryParameter(
    gpa: std.mem.Allocator,
    query: *const Query,
) error{ OutOfMemory, MissingCallbackParam }![]const u8 {
    const value = queryValue(query) orelse return error.MissingCallbackParam;
    return gpa.dupe(u8, value);
}

fn queryValue(query: *const Query) ?[]const u8 {
    const at = std.mem.find(u8, query.request_line, query.needle) orelse return null;
    const rest = query.request_line[at + query.needle.len ..];
    const end = std.mem.findAny(u8, rest, "& \r") orelse rest.len;
    return rest[0..end];
}

test "callback classifies a TLS handshake from its first byte" {
    var buffer: [request_bytes_max]u8 = undefined;
    var reader = std.testing.Reader.init(&buffer, &.{
        .{ .buffer = "\x16\x03\x01\x02\x00\x01\x00\x01\xfc\x03\x03" },
    });
    try std.testing.expectError(error.StrayProtocol, takeRequestLine(&reader.interface));
}

const Fake = struct {
    io: std.Io = std.testing.io,
    requests: []const []const u8 = &.{},
    read_stalls: bool = false,
    respond_fails: bool = false,
    request: []const u8 = "",
    accept_count: usize = 0,
    close_count: usize = 0,
    response_count: usize = 0,
    request_byte_count: usize = 0,
    accept_canceled: bool = false,
    read_canceled: bool = false,

    const vtable: Connections.VTable = .{
        .accept = accept,
        .readRequestLine = readRequestLine,
        .respondAuthorized = respondAuthorized,
        .hangUp = hangUp,
    };

    fn connections(self: *Fake) Connections {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn of(ptr: *anyopaque) *Fake {
        return @ptrCast(@alignCast(ptr));
    }

    fn accept(ptr: *anyopaque) std.Io.net.Server.AcceptError!void {
        const self = of(ptr);
        if (self.requests.len == 0) return waitForCancel(self.io, &self.accept_canceled);
        self.request = self.requests[0];
        self.requests = self.requests[1..];
        self.accept_count += 1;
    }

    fn readRequestLine(
        ptr: *anyopaque,
        buffer: *[request_bytes_max]u8,
    ) Connections.ReadError![]const u8 {
        const self = of(ptr);
        if (self.read_stalls) return waitForCancel(self.io, &self.read_canceled);
        var reader = std.testing.Reader.init(buffer, &.{.{ .buffer = self.request }});
        const request_line = try takeRequestLine(&reader.interface);
        self.request_byte_count = request_line.len + 1;
        return request_line;
    }

    fn respondAuthorized(ptr: *anyopaque) std.Io.Writer.Error!void {
        const self = of(ptr);
        self.response_count += 1;
        if (self.respond_fails) return error.WriteFailed;
    }

    fn hangUp(ptr: *anyopaque) void {
        of(ptr).close_count += 1;
    }
};

const FiringIo = struct {
    threaded: std.Io.Threaded,
    vtable: std.Io.VTable,
    window_ms: i64,
    spent: std.atomic.Value(bool),
    fired: std.Io.Event,

    fn init(self: *FiringIo, window_ms: i64) void {
        self.threaded = .init(std.testing.allocator, .{});
        self.vtable = self.threaded.io().vtable.*;
        self.vtable.sleep = sleep;
        self.window_ms = window_ms;
        self.spent = .init(false);
        self.fired = .unset;
    }

    fn deinit(self: *FiringIo) void {
        self.threaded.deinit();
    }

    fn io(self: *FiringIo) std.Io {
        return .{ .userdata = &self.threaded, .vtable = &self.vtable };
    }

    fn sleep(userdata: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        const threaded: *std.Io.Threaded = @ptrCast(@alignCast(userdata));
        const self: *FiringIo = @fieldParentPtr("threaded", threaded);
        const backend = threaded.io();
        const fires = switch (timeout) {
            .duration => |duration| duration.raw.toMilliseconds() == self.window_ms,
            .none, .deadline => false,
        };
        if (fires and !self.spent.swap(true, .acq_rel)) {
            self.fired.set(backend);
            return backend.checkCancel();
        }
        var never: std.Io.Event = .unset;
        try never.wait(backend);
        unreachable;
    }
};

fn waitForCancel(io: std.Io, canceled: *bool) error{Canceled} {
    var never: std.Io.Event = .unset;
    never.wait(io) catch |err| {
        canceled.* = true;
        return err;
    };
    unreachable;
}

fn receiveFake(fake: *Fake) !Redirect {
    return receiveFakeExpecting(fake, &.{ .state = "state" });
}

fn receiveFakeExpecting(fake: *Fake, expected: *const Expected) !Redirect {
    return awaitRedirect(std.testing.allocator, fake.io, fake.connections(), expected);
}

test "callback refuses to run without deadline concurrency" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var fake: Fake = .{
        .io = threaded.io(),
        .requests = &.{"GET /callback?code=code&state=state HTTP/1.1\r\n"},
    };
    try std.testing.expectError(error.CallbackTimeoutUnavailable, receiveFake(&fake));
    try std.testing.expectEqual(@as(usize, 0), fake.accept_count);
}

test "callback work does not start unless its deadline timer is reserved" {
    var threaded: std.Io.Threaded = .init(
        std.testing.allocator,
        .{ .concurrent_limit = .limited(1) },
    );
    defer threaded.deinit();
    var fake: Fake = .{
        .io = threaded.io(),
        .requests = &.{"GET /callback?code=code&state=state HTTP/1.1\r\n"},
    };
    try std.testing.expectError(error.CallbackTimeoutUnavailable, receiveFake(&fake));
    try std.testing.expectEqual(@as(usize, 0), fake.accept_count);
}

test "callback accept has an aggregate deadline" {
    var clock: FiringIo = undefined;
    clock.init(callback_timeout_ms);
    defer clock.deinit();
    var fake: Fake = .{ .io = clock.io() };
    try std.testing.expectError(error.CallbackTimeout, receiveFake(&fake));
    try std.testing.expect(fake.accept_canceled);
    try std.testing.expectEqual(@as(usize, 0), fake.accept_count);
    try std.testing.expectEqual(@as(usize, 0), fake.close_count);
}

test "a stalled request line cannot extend the aggregate deadline" {
    var clock: FiringIo = undefined;
    clock.init(callback_timeout_ms);
    defer clock.deinit();
    var fake: Fake = .{
        .io = clock.io(),
        .requests = &.{"GET /callback?code=code&state=state HTTP/1.1\r\n"},
        .read_stalls = true,
    };
    try std.testing.expectError(error.CallbackTimeout, receiveFake(&fake));
    try std.testing.expect(fake.read_canceled);
    try std.testing.expectEqual(@as(usize, 1), fake.accept_count);
    try std.testing.expectEqual(@as(usize, 1), fake.close_count);
    try std.testing.expectEqual(@as(usize, 0), fake.response_count);
}

test "callback request has an explicit wire byte limit" {
    var request: [request_bytes_max + 1]u8 = @splat('x');
    const prefix = "GET /callback?padding=";
    @memcpy(request[0..prefix.len], prefix);
    request[request.len - 1] = '\n';
    var fake: Fake = .{ .requests = &.{&request} };
    try std.testing.expectError(error.CallbackRequestTooLarge, receiveFake(&fake));
    try std.testing.expectEqual(@as(usize, 1), fake.close_count);
    try std.testing.expectEqual(@as(usize, 0), fake.response_count);
}

test "callback accepts a request at the wire byte limit" {
    var request: [request_bytes_max]u8 = @splat('x');
    const prefix = "GET /callback?code=code&state=state&padding=";
    @memcpy(request[0..prefix.len], prefix);
    request[request.len - 1] = '\n';

    var fake: Fake = .{ .requests = &.{&request} };
    const callback = try receiveFake(&fake);
    defer callback.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("code", callback.code);
    try std.testing.expectEqualStrings("state", callback.state.?);
    try std.testing.expectEqual(request.len, fake.request_byte_count);
}

test "callback accepts normal requests for both provider paths" {
    for ([_][]const u8{
        "GET /callback?code=anthropic-code&state=anthropic-state HTTP/1.1\r\n",
        "GET /auth/callback?code=openai-code&state=openai-state HTTP/1.1\r\n",
    }) |request| {
        var fake: Fake = .{ .requests = &.{request} };
        const callback = try receiveFake(&fake);
        defer callback.deinit(std.testing.allocator);
        try std.testing.expect(std.mem.endsWith(u8, callback.code, "code"));
        try std.testing.expect(std.mem.endsWith(u8, callback.state.?, "state"));
        try std.testing.expectEqual(@as(usize, 1), fake.close_count);
        try std.testing.expectEqual(@as(usize, 1), fake.response_count);
    }
}

test "callback ignores stray connections until the real redirect arrives" {
    var fake: Fake = .{ .requests = &.{
        "GET /callback?code=code&state=state HTTP/1.1\r",
        "GET /favicon.ico HTTP/1.1\r\n",
        "GET /callback?code=code&state=state HTTP/1.1\r\n",
    } };
    const callback = try receiveFake(&fake);
    defer callback.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("code", callback.code);
    try std.testing.expectEqualStrings("state", callback.state.?);
    try std.testing.expectEqual(@as(usize, 3), fake.accept_count);
    try std.testing.expectEqual(@as(usize, 3), fake.close_count);
    try std.testing.expectEqual(@as(usize, 1), fake.response_count);
}

test "callback ignores a TLS handshake until the real redirect arrives" {
    var fake: Fake = .{ .requests = &.{
        "\x16\x03\x01\x02\x00\x01\x00\x01\xfc\x03\x03",
        "GET /auth/callback?code=code&state=state HTTP/1.1\r\n",
    } };
    const callback = try receiveFake(&fake);
    defer callback.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("code", callback.code);
    try std.testing.expectEqualStrings("state", callback.state.?);
    try std.testing.expectEqual(@as(usize, 2), fake.accept_count);
    try std.testing.expectEqual(@as(usize, 2), fake.close_count);
    try std.testing.expectEqual(@as(usize, 1), fake.response_count);
}

test "a torn success response does not fail an authorized login" {
    var fake: Fake = .{
        .requests = &.{"GET /auth/callback?code=code&state=state HTTP/1.1\r\n"},
        .respond_fails = true,
    };
    const callback = try receiveFake(&fake);
    defer callback.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("code", callback.code);
    try std.testing.expectEqualStrings("state", callback.state.?);
    try std.testing.expectEqual(@as(usize, 1), fake.response_count);
    try std.testing.expectEqual(@as(usize, 1), fake.close_count);
}

test "callback provider error redirects close without success response" {
    for ([_][]const u8{
        "GET /callback?error=access_denied&state=state HTTP/1.1\r\n",
        "GET /auth/callback?state=state&error=access_denied HTTP/1.1\r\n",
        "GET /callback?error=a_code_no_one_registered&state=state HTTP/1.1\r\n",
    }) |request| {
        var fake: Fake = .{ .requests = &.{request} };
        try std.testing.expectError(error.AuthorizationFailed, receiveFake(&fake));
        try std.testing.expectEqual(@as(usize, 1), fake.close_count);
        try std.testing.expectEqual(@as(usize, 0), fake.response_count);
    }
}

test "an error redirect of another sign-in cannot end the wait" {
    var fake: Fake = .{ .requests = &.{
        "GET /callback?error=access_denied&state=another HTTP/1.1\r\n",
        "GET /callback?error=server_error HTTP/1.1\r\n",
        "GET /callback?code=code&state=state HTTP/1.1\r\n",
    } };
    const callback = try receiveFake(&fake);
    defer callback.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("code", callback.code);
    try std.testing.expectEqual(@as(usize, 3), fake.accept_count);
    try std.testing.expectEqual(@as(usize, 1), fake.response_count);
}

test "a grant without state still completes the redirect" {
    var fake: Fake = .{ .requests = &.{"GET /callback?code=code HTTP/1.1\r\n"} };
    const callback = try receiveFake(&fake);
    defer callback.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("code", callback.code);
    try std.testing.expect(callback.state == null);
    try std.testing.expectEqual(@as(usize, 1), fake.close_count);
    try std.testing.expectEqual(@as(usize, 1), fake.response_count);
}

test "a random callback path binds the redirect" {
    var fake: Fake = .{ .requests = &.{
        "GET /other?code=wrong HTTP/1.1\r\n",
        "GET /deadbeef?code=code HTTP/1.1\r\n",
    } };
    const callback = try receiveFakeExpecting(&fake, &.{ .path = "/deadbeef" });
    defer callback.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("code", callback.code);
    try std.testing.expectEqual(@as(usize, 2), fake.accept_count);
    try std.testing.expectEqual(@as(usize, 1), fake.response_count);
}

test "callback cancellation closes acquired connections" {
    var accepting: Fake = .{};
    var accept_future = try accepting.io.concurrent(receiveFake, .{&accepting});
    try std.testing.expectError(error.Canceled, accept_future.cancel(accepting.io));
    try std.testing.expect(accepting.accept_canceled);
    try std.testing.expectEqual(@as(usize, 0), accepting.close_count);

    var reading: Fake = .{
        .requests = &.{"GET /callback?code=code&state=state HTTP/1.1\r\n"},
        .read_stalls = true,
    };
    var read_future = try reading.io.concurrent(receiveFake, .{&reading});
    try std.testing.expectError(error.Canceled, read_future.cancel(reading.io));
    try std.testing.expect(reading.read_canceled);
    try std.testing.expectEqual(@as(usize, 1), reading.close_count);
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
    try std.testing.expect(
        holdsPathRedirect(&.{ .line = "/deadbeef?code=only", .path = "/deadbeef" }),
    );
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
    try std.testing.expect(
        !holdsPathRedirect(&.{ .line = "/deadbeef?code=a\x1b", .path = "/deadbeef" }),
    );
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
    const framed = try std.mem.print(&request, "GET {s} HTTP/1.1\r\n", .{&line});
    try std.testing.expectEqual(request.len, framed.len);

    var fake: Fake = .{ .requests = &.{framed} };
    const callback = try receiveFake(&fake);
    defer callback.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("code", callback.code);
    try std.testing.expectEqualStrings("state", callback.state.?);
    try std.testing.expectEqual(request.len, fake.request_byte_count);
}

test "a replayed paste line completes the redirect wait" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var socket: Socket = .{ .io = io };
    const loopback = socket.loopback();
    try loopback.listen(0);
    defer loopback.close();
    const port = socket.server.?.socket.address.getPort();
    const expected: Expected = .{ .state = "paste-state" };
    var future = try io.concurrent(Loopback.receive, .{ loopback, gpa, &expected });
    errdefer if (future.cancel(io)) |redirect| redirect.deinit(gpa) else |_| {};

    try loopback.replay(
        port,
        "https://localhost:1455/auth/callback?code=paste-code&state=paste-state",
    );
    const redirect = try future.await(io);
    defer redirect.deinit(gpa);
    try std.testing.expectEqualStrings("paste-code", redirect.code);
    try std.testing.expectEqualStrings("paste-state", redirect.state.?);
}

test "a replayed denial line ends the redirect wait with the listener's verdict" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var socket: Socket = .{ .io = io };
    const loopback = socket.loopback();
    try loopback.listen(0);
    defer loopback.close();
    const port = socket.server.?.socket.address.getPort();
    const expected: Expected = .{ .state = "paste-state" };
    var future = try io.concurrent(Loopback.receive, .{ loopback, gpa, &expected });
    errdefer if (future.cancel(io)) |redirect| redirect.deinit(gpa) else |_| {};

    try loopback.replay(
        port,
        "https://localhost:1455/auth/callback?error=access_denied&state=paste-state",
    );
    try std.testing.expectError(error.AuthorizationFailed, future.await(io));
}

test "a silent connection cannot blind the listener to a replayed paste" {
    const gpa = std.testing.allocator;
    var clock: FiringIo = undefined;
    clock.init(request_line_timeout_ms);
    defer clock.deinit();
    const io = clock.io();
    var socket: Socket = .{ .io = io };
    const loopback = socket.loopback();
    try loopback.listen(0);
    defer loopback.close();
    const port = socket.server.?.socket.address.getPort();
    const expected: Expected = .{ .path = "/deadbeef" };
    var future = try io.concurrent(Loopback.receive, .{ loopback, gpa, &expected });
    errdefer if (future.cancel(io)) |redirect| redirect.deinit(gpa) else |_| {};

    var silent_address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    const silent = try silent_address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer silent.close(io);
    try clock.fired.wait(io);

    try loopback.replay(port, "http://localhost:53694/deadbeef?code=paste-code");
    const redirect = try future.await(io);
    defer redirect.deinit(gpa);
    try std.testing.expectEqualStrings("paste-code", redirect.code);
}
