const std = @import("std");

const core = @import("core");

const Transport = @import("Transport.zig");

const Http = @This();

gpa: std.mem.Allocator,
io: std.Io,
established: bool,
client: std.http.Client,
request: std.http.Client.Request,
response: std.http.Client.Response,
body: *std.Io.Reader,
header_arena: std.heap.ArenaAllocator,
headers: std.ArrayList(std.http.Header),
transfer_buffer: [16384]u8,

pub const FetchError = Transport.Error || std.Io.Reader.LimitedAllocError;

pub const Response = struct {
    status: std.http.Status,
    body: []u8,
};

const vtable: Transport.VTable = .{ .open = open, .close = close };

const identity_alone = accepted: {
    var encodings: @TypeOf(std.http.Client.Request.default_accept_encoding) = @splat(false);
    encodings[@backingInt(std.http.ContentEncoding.identity)] = true;
    break :accepted encodings;
};

pub fn init(gpa: std.mem.Allocator, io: std.Io) Http {
    return .{
        .gpa = gpa,
        .io = io,
        .established = false,
        .client = undefined,
        .request = undefined,
        .response = undefined,
        .body = undefined,
        .header_arena = .init(gpa),
        .headers = .empty,
        .transfer_buffer = undefined,
    };
}

pub fn deinit(self: *Http) void {
    if (self.established) self.teardown();
    self.header_arena.deinit();
}

pub fn transport(self: *Http) Transport {
    return .{ .ptr = self, .vtable = &vtable };
}

pub fn fetch(
    gpa: std.mem.Allocator,
    io: std.Io,
    maybe_transport: ?Transport,
    request: *const Transport.Request,
    bytes_max: usize,
) FetchError!Response {
    var http: Http = .init(gpa, io);
    defer http.deinit();
    const chosen = maybe_transport orelse http.transport();
    const reply = try chosen.open(request);
    defer chosen.close();
    const body = try reply.body.allocRemaining(gpa, .limited(bytes_max));
    return .{ .status = reply.status, .body = body };
}

fn open(ptr: *anyopaque, request: *const Transport.Request) Transport.Error!Transport.Reply {
    const self: *Http = @ptrCast(@alignCast(ptr));
    if (self.established) self.teardown();
    core.timeout.run(self.io, request.timeout_ms, connect, .{ self, request }, null) catch |err| {
        if (self.established) self.teardown();
        return err;
    };
    return .{
        .status = self.response.head.status,
        .headers = self.headers.items,
        .body = self.body,
    };
}

fn close(ptr: *anyopaque) void {
    const self: *Http = @ptrCast(@alignCast(ptr));
    if (self.established) self.teardown();
}

fn connect(self: *Http, request: *const Transport.Request) Transport.Error!void {
    self.client = .{ .allocator = self.gpa, .io = self.io };
    errdefer self.client.deinit();

    const uri = try std.Uri.parse(request.url);
    const has_body = request.method.requestHasBody();
    const maybe_content_type = if (has_body) request.content_type else null;
    self.request = try self.client.request(request.method, uri, .{
        .headers = .{
            .content_type = if (maybe_content_type) |content_type|
                .{ .override = content_type }
            else
                .omit,
            .authorization = if (request.authorization) |value| .{ .override = value } else .omit,
            .user_agent = if (request.user_agent) |value| .{ .override = value } else .default,
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = request.headers,
        .redirect_behavior = .not_allowed,
    });
    errdefer self.request.deinit();
    self.request.accept_encoding = identity_alone;

    if (has_body) {
        self.request.transfer_encoding = .{ .content_length = request.body.len };
        var writer = try self.request.sendBodyUnflushed(&.{});
        try writer.writer.writeAll(request.body);
        try writer.end();
        try self.request.connection.?.flush();
    } else {
        try self.request.sendBodiless();
    }

    self.response = try self.request.receiveHead(&.{});
    try self.captureHeaders();
    self.body = self.response.reader(&self.transfer_buffer);
    self.established = true;
}

fn captureHeaders(self: *Http) error{OutOfMemory}!void {
    _ = self.header_arena.reset(.retain_capacity);
    const arena = self.header_arena.allocator();
    self.headers = .empty;
    var headers = self.response.head.iterateHeaders();
    while (headers.next()) |header| {
        try self.headers.append(arena, .{
            .name = try arena.dupe(u8, header.name),
            .value = try arena.dupe(u8, header.value),
        });
    }
}

fn teardown(self: *Http) void {
    self.established = false;
    self.request.deinit();
    self.client.deinit();
}

test "open sends the body with the named headers and hands back the reply" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var loopback: Loopback = undefined;
    try loopback.init(gpa, io, "HTTP/1.1 429 Too Many Requests\r\ncontent-type: text/plain\r\n" ++
        "retry-after: 3\r\ncontent-length: 4\r\nconnection: close\r\n\r\nslow");
    defer loopback.deinit();

    var http: Http = .init(gpa, io);
    defer http.deinit();
    const reply = try http.transport().open(&.{
        .url = loopback.url,
        .authorization = "Bearer secret-token",
        .user_agent = "drinky",
        .headers = &.{.{ .name = "chatgpt-account-id", .value = "acct-1" }},
        .body = "{\"model\":\"m\"}",
    });
    try loopback.join();

    try std.testing.expectEqual(std.http.Status.too_many_requests, reply.status);
    try std.testing.expectEqualStrings("text/plain", reply.header("Content-Type").?);
    try std.testing.expectEqual(@as(?u64, 3000), reply.retryAfterMs());
    var buffer: [16]u8 = undefined;
    const length = try reply.body.readSliceShort(&buffer);
    try std.testing.expectEqualStrings("slow", buffer[0..length]);

    const head = loopback.served.head.items;
    try std.testing.expect(std.mem.startsWith(u8, head, "POST /v1/responses HTTP/1.1\n"));
    try std.testing.expect(
        std.mem.find(u8, head, "authorization: Bearer secret-token\n") != null,
    );
    try std.testing.expect(std.mem.find(u8, head, "user-agent: drinky\n") != null);
    try std.testing.expect(std.mem.find(u8, head, "chatgpt-account-id: acct-1\n") != null);
    try std.testing.expect(std.mem.find(u8, head, "content-type: application/json\n") != null);
    try std.testing.expect(std.mem.find(u8, head, "accept-encoding: identity\n") != null);
    try std.testing.expectEqualStrings("{\"model\":\"m\"}", loopback.served.body.items);
    http.transport().close();
}

const ServeError = std.Io.net.Server.AcceptError || std.Io.Reader.DelimiterError ||
    std.Io.Writer.Error || std.mem.Allocator.Error || std.fmt.ParseIntError;

const Served = struct {
    head: std.ArrayList(u8) = .empty,
    body: std.ArrayList(u8) = .empty,

    fn deinit(self: *Served, gpa: std.mem.Allocator) void {
        self.head.deinit(gpa);
        self.body.deinit(gpa);
    }
};

fn serveOnce(
    gpa: std.mem.Allocator,
    io: std.Io,
    server: *std.Io.net.Server,
    reply: []const u8,
    served: *Served,
) ServeError!void {
    var connection = try server.accept(io);
    defer connection.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = connection.reader(io, &read_buffer);
    var content_length: usize = 0;
    for (0..64) |_| {
        const raw = try reader.interface.takeDelimiterInclusive('\n');
        const line = std.mem.trimEnd(u8, raw, "\r\n");
        try served.head.appendSlice(gpa, line);
        try served.head.append(gpa, '\n');
        if (line.len == 0) break;
        const label = "content-length:";
        if (std.ascii.startsWithIgnoreCase(line, label)) {
            const value = std.mem.trim(u8, line[label.len..], " \t");
            content_length = try std.fmt.parseInt(usize, value, 10);
        }
    }
    const body = try reader.interface.take(content_length);
    try served.body.appendSlice(gpa, body);

    var write_buffer: [1024]u8 = undefined;
    var writer = connection.writer(io, &write_buffer);
    try writer.interface.writeAll(reply);
    try writer.interface.flush();
}

const Loopback = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    server: std.Io.net.Server,
    url: []u8,
    served: Served,
    future: ?std.Io.Future(ServeError!void),

    fn init(self: *Loopback, gpa: std.mem.Allocator, io: std.Io, reply: []const u8) !void {
        self.gpa = gpa;
        self.io = io;
        var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        self.server = try address.listen(io, .{});
        self.url = try gpa.print("http://127.0.0.1:{d}/v1/responses", .{
            self.server.socket.address.getPort(),
        });
        self.served = .{};
        self.future = try io.concurrent(serveOnce, .{ gpa, io, &self.server, reply, &self.served });
    }

    fn deinit(self: *Loopback) void {
        if (self.future) |*future| _ = future.cancel(self.io) catch {};
        self.served.deinit(self.gpa);
        self.gpa.free(self.url);
        self.server.deinit(self.io);
    }

    fn join(self: *Loopback) !void {
        const future = &(self.future orelse return);
        defer self.future = null;
        try future.await(self.io);
    }
};

test "a request without a credential omits the Authorization header" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var loopback: Loopback = undefined;
    try loopback.init(gpa, io, "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n" ++
        "content-length: 14\r\nconnection: close\r\n\r\ndata: [DONE]\n\n");
    defer loopback.deinit();

    var http: Http = .init(gpa, io);
    defer http.deinit();
    const reply = try http.transport().open(&.{ .url = loopback.url, .body = "{}" });
    try loopback.join();

    try std.testing.expectEqual(std.http.Status.ok, reply.status);
    const head = loopback.served.head.items;
    try std.testing.expect(std.mem.find(u8, head, "authorization:") == null);
    try std.testing.expect(std.mem.find(u8, head, "user-agent: zig/") != null);
    var buffer: [32]u8 = undefined;
    const length = try reply.body.readSliceShort(&buffer);
    try std.testing.expectEqualStrings("data: [DONE]\n\n", buffer[0..length]);
}

test "a request without a body names its method and sends no content type" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var loopback: Loopback = undefined;
    try loopback.init(gpa, io, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n" ++
        "connection: close\r\n\r\n{}");
    defer loopback.deinit();

    const response = try fetch(gpa, io, null, &.{ .method = .GET, .url = loopback.url }, 64);
    defer gpa.free(response.body);
    try loopback.join();

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    try std.testing.expectEqualStrings("{}", response.body);
    const head = loopback.served.head.items;
    try std.testing.expect(std.mem.startsWith(u8, head, "GET /v1/responses HTTP/1.1\n"));
    try std.testing.expect(std.mem.find(u8, head, "content-type:") == null);
    try std.testing.expectEqualStrings("", loopback.served.body.items);
}

test "a request that times out before the response head leaves the transport ready" {
    const gpa = std.testing.allocator;
    var clock: core.testing.ClockIo = undefined;
    clock.init(gpa);
    defer clock.deinit();
    const io = clock.io();
    var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const url = try gpa.print("http://127.0.0.1:{d}/v1/responses", .{
        server.socket.address.getPort(),
    });
    defer gpa.free(url);

    var http: Http = .init(gpa, io);
    defer http.deinit();
    try std.testing.expectError(error.Timeout, http.transport().open(&.{
        .url = url,
        .body = "{}",
        .timeout_ms = 50,
    }));
    try std.testing.expectEqualSlices(u64, &.{50}, clock.slept());

    var loopback: Loopback = undefined;
    try loopback.init(gpa, io, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n" ++
        "connection: close\r\n\r\n");
    defer loopback.deinit();
    const reply = try http.transport().open(&.{ .url = loopback.url, .body = "{}" });
    try loopback.join();
    try std.testing.expectEqual(std.http.Status.ok, reply.status);
    http.transport().close();
}

test "a connect that fails at its first allocation fails as out of memory" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const url = try gpa.print("http://127.0.0.1:{d}/v1/messages", .{
        server.socket.address.getPort(),
    });
    defer gpa.free(url);

    var failing: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = 0 });
    var http: Http = .init(failing.allocator(), io);
    defer http.deinit();
    try std.testing.expectError(error.OutOfMemory, http.transport().open(&.{
        .url = url,
        .body = "{}",
    }));
}

test "open refuses a compressed reply, because the request accepts identity alone" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var loopback: Loopback = undefined;
    try loopback.init(gpa, io, "HTTP/1.1 200 OK\r\ncontent-encoding: gzip\r\n" ++
        "content-length: 0\r\nconnection: close\r\n\r\n");
    defer loopback.deinit();

    var http: Http = .init(gpa, io);
    defer http.deinit();
    try std.testing.expectError(
        error.HttpContentEncodingUnsupported,
        http.transport().open(&.{ .url = loopback.url, .body = "{}" }),
    );
    try loopback.join();
}

test "open refuses an endpoint that is no URL" {
    var http: Http = .init(std.testing.allocator, std.testing.io);
    defer http.deinit();
    try std.testing.expectError(error.InvalidFormat, http.transport().open(&.{
        .url = "not a url",
        .body = "{}",
    }));
}
