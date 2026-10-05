const std = @import("std");

const core = @import("core");

const Credential = @import("Credential.zig");
const Dialect = @import("Dialect.zig");
const Gemini = @import("Gemini.zig");
const Http = @import("Http.zig");
const Messages = @import("Messages.zig");
const Responses = @import("Responses.zig");
const Sse = @import("Sse.zig");
const testing = @import("testing.zig");
const Transport = @import("Transport.zig");

const Provider = @This();

const error_body_bytes_max = 4096;

gpa: std.mem.Allocator,
io: std.Io,
dialect: Dialect,
transport: Transport,
credential: Credential,
timeouts: Transport.Timeouts,
bytes_max: usize,
arena: std.heap.ArenaAllocator,
frame_arena: std.heap.ArenaAllocator,
events: Dialect.Events,
event_index: usize,
sse: ?Sse,
transport_open: bool,
ended: bool,

const Options = struct {
    dialect: Dialect,
    transport: Transport,
    credential: Credential,
    timeouts: Transport.Timeouts = .{},
    bytes_max: usize = Sse.bytes_max_default,
};

const Attempt = union(enum) {
    streaming,
    failed,
    unauthorized: Dialect.Failed,
};

const vtable: core.Provider.VTable = .{ .open = open, .next = next, .close = close };

pub fn init(gpa: std.mem.Allocator, io: std.Io, options: *const Options) Provider {
    return .{
        .gpa = gpa,
        .io = io,
        .dialect = options.dialect,
        .transport = options.transport,
        .credential = options.credential,
        .timeouts = options.timeouts,
        .bytes_max = options.bytes_max,
        .arena = .init(gpa),
        .frame_arena = .init(gpa),
        .events = .empty,
        .event_index = 0,
        .sse = null,
        .transport_open = false,
        .ended = false,
    };
}

pub fn deinit(self: *Provider) void {
    self.release();
    self.arena.deinit();
    self.frame_arena.deinit();
}

pub fn provider(self: *Provider) core.Provider {
    return .{ .ptr = self, .vtable = &vtable };
}

fn open(ptr: *anyopaque, request: *const core.Provider.Request) core.Provider.Error!void {
    const self: *Provider = @ptrCast(@alignCast(ptr));
    self.release();
    const arena = self.arena.allocator();
    switch (try self.attempt(request)) {
        .streaming, .failed => return,
        .unauthorized => |failed| {
            const renewed = self.credential.renew() catch |err| return self.credentialFailed(err);
            if (!renewed) return self.fail(try self.dialect.failure(arena, &failed));
            switch (try self.attempt(request)) {
                .streaming, .failed => return,
                .unauthorized => |again| return self.fail(try self.dialect.failure(arena, &again)),
            }
        },
    }
}

fn next(ptr: *anyopaque) core.Provider.Error!?core.Provider.Event {
    const self: *Provider = @ptrCast(@alignCast(ptr));
    if (self.take()) |event| return event;
    if (self.ended) return null;
    const sse = &(self.sse orelse return null);
    const frames_max = sse.budget.remaining() + 1;
    for (0..frames_max) |_| {
        self.clearFrame();
        const maybe_payload = sse.next() catch |err| return switch (err) {
            error.Canceled => error.Canceled,
            error.OutOfMemory => error.OutOfMemory,
            error.TooLarge => self.endTooLarge(),
            error.Timeout,
            error.ConcurrencyUnavailable,
            error.Incomplete,
            error.ReadFailed,
            => self.end(.{
                .reason = .network,
                .message = try std.fmt.allocPrint(
                    self.frame_arena.allocator(),
                    "The stream failed because of error {s}.",
                    .{@errorName(err)},
                ),
            }),
        };
        const arena = self.frame_arena.allocator();
        const payload = maybe_payload orelse {
            try self.dialect.finish(arena, &self.events);
            self.ended = true;
            return self.take();
        };
        const decoded = try self.dialect.decode(arena, payload, &self.events);
        if (decoded == .progress) sse.renewIdleWindow();
        if (decoded == .done) self.ended = true;
        if (self.take()) |event| return event;
        if (self.ended) return null;
    }
    return self.endTooLarge();
}

fn close(ptr: *anyopaque) void {
    const self: *Provider = @ptrCast(@alignCast(ptr));
    self.release();
}

fn attempt(self: *Provider, request: *const core.Provider.Request) core.Provider.Error!Attempt {
    const arena = self.arena.allocator();
    const maybe_token = self.credential.token(arena) catch |err| {
        try self.credentialFailed(err);
        return .failed;
    };
    const token = maybe_token orelse {
        try self.fail(.{ .reason = .unauthorized, .message = "The account has no credential." });
        return .failed;
    };
    if (!Transport.validHeaderValue(token)) {
        try self.fail(.{
            .reason = .unauthorized,
            .message = "The credential cannot be a header value.",
        });
        return .failed;
    }
    var prepared = self.dialect.prepare(arena, request, token) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OrphanToolResult => {
            try self.fail(.{
                .reason = .invalid_request,
                .message = "The conversation holds a tool result without its call.",
            });
            return .failed;
        },
    };
    prepared.timeout_ms = self.timeouts.connect_ms;
    const reply = self.transport.open(&prepared) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try self.fail(.{ .reason = .network, .message = try std.fmt.allocPrint(
                arena,
                "The connection failed because of error {s}.",
                .{@errorName(err)},
            ) });
            return .failed;
        },
    };
    self.transport_open = true;
    if (self.dialect.quota(reply.headers, self.nowSeconds())) |quota| {
        try self.push(.{ .quota = quota });
    }
    if (reply.status == .ok) {
        self.dialect.reset();
        self.sse = .init(self.gpa, self.io, reply.body, .{
            .idle_ms = self.timeouts.idle_ms,
            .bytes_max = self.bytes_max,
        });
        return .streaming;
    }
    const failed: Dialect.Failed = .{
        .status = reply.status,
        .retry_after_ms = reply.retryAfterMs(),
        .body = try self.errorBody(reply.body),
    };
    self.closeTransport();
    if (reply.status == .unauthorized) return .{ .unauthorized = failed };
    try self.fail(try self.dialect.failure(arena, &failed));
    return .failed;
}

fn credentialFailed(self: *Provider, err: Credential.Error) core.Provider.Error!void {
    switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        error.Rejected => try self.fail(.{
            .reason = .unauthorized,
            .message = "The server rejected the credential.",
        }),
        error.Network => try self.fail(.{
            .reason = .network,
            .message = "The credential refresh did not reach the server.",
        }),
    }
}

fn errorBody(self: *Provider, reader: *std.Io.Reader) core.Provider.Error![]const u8 {
    var buffer: [error_body_bytes_max]u8 = undefined;
    const length = core.timeout.run(
        self.io,
        self.timeouts.connect_ms,
        readShort,
        .{ reader, &buffer },
        null,
    ) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.ReadFailed, error.Timeout, error.ConcurrencyUnavailable => 0,
    };
    return self.arena.allocator().dupe(u8, validPrefix(buffer[0..length]));
}

fn readShort(reader: *std.Io.Reader, buffer: []u8) std.Io.Reader.ShortError!usize {
    return reader.readSliceShort(buffer);
}

fn validPrefix(bytes: []const u8) []const u8 {
    var length = bytes.len;
    for (0..4) |_| {
        if (std.unicode.utf8ValidateSlice(bytes[0..length])) return bytes[0..length];
        if (length == 0) break;
        length -= 1;
    }
    return bytes;
}

fn nowSeconds(self: *const Provider) i64 {
    return @divFloor(std.Io.Timestamp.now(self.io, .real).toMilliseconds(), std.time.ms_per_s);
}

fn fail(self: *Provider, failure: core.Provider.Failure) error{OutOfMemory}!void {
    try self.push(.{ .failed = failure });
}

fn end(self: *Provider, failure: core.Provider.Failure) error{OutOfMemory}!?core.Provider.Event {
    self.ended = true;
    try self.fail(failure);
    return self.take();
}

fn endTooLarge(self: *Provider) error{OutOfMemory}!?core.Provider.Event {
    return self.end(.{ .reason = .unsupported_reply, .message = try std.fmt.allocPrint(
        self.frame_arena.allocator(),
        "The reply exceeded {d} MiB.",
        .{self.bytes_max >> 20},
    ) });
}

fn push(self: *Provider, event: core.Provider.Event) error{OutOfMemory}!void {
    try self.events.append(self.frame_arena.allocator(), event);
}

fn take(self: *Provider) ?core.Provider.Event {
    if (self.event_index >= self.events.items.len) return null;
    defer self.event_index += 1;
    return self.events.items[self.event_index];
}

fn clearFrame(self: *Provider) void {
    _ = self.frame_arena.reset(.retain_capacity);
    self.events = .empty;
    self.event_index = 0;
}

fn closeTransport(self: *Provider) void {
    if (self.transport_open) self.transport.close();
    self.transport_open = false;
}

fn release(self: *Provider) void {
    if (self.sse) |*sse| sse.deinit();
    self.sse = null;
    self.closeTransport();
    _ = self.arena.reset(.retain_capacity);
    self.clearFrame();
    self.ended = false;
}

test "a cut body keeps its valid UTF-8 prefix" {
    try std.testing.expectEqualStrings("abc", validPrefix("abc"));
    try std.testing.expectEqualStrings("a", validPrefix("a\xe2\x82"));
    try std.testing.expectEqualStrings("a€", validPrefix("a€"));
    try std.testing.expectEqualStrings("\x80\x80\x80\x80\x80", validPrefix("\x80\x80\x80\x80\x80"));
}

const complete_body =
    "event: response.reasoning_summary_text.delta\n" ++
    "data: {\"type\":\"response.reasoning_summary_text.delta\"," ++
    "\"item_id\":\"rs_1\",\"summary_index\":0,\"delta\":\"weigh\"}\n" ++
    "\n" ++
    "data: {\"type\":\"response.output_item.done\",\"item\":" ++
    "{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[{\"type\":\"summary_text\"," ++
    "\"text\":\"weigh\"}],\"encrypted_content\":\"enc\"}}\n" ++
    "\n" ++
    "data: {\"type\":\"response.output_item.added\",\"item\":" ++
    "{\"id\":\"fc_1\",\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"read\"}}\n" ++
    "\n" ++
    "data: {\"type\":\"response.function_call_arguments.delta\"," ++
    "\"item_id\":\"fc_1\",\"delta\":\"{}\"}\n" ++
    "\n" ++
    "data: {\"type\":\"response.output_item.done\",\"item\":{" ++
    "\"id\":\"fc_1\",\"type\":\"function_call\",\"status\":\"completed\"," ++
    "\"call_id\":\"call_1\",\"name\":\"read\",\"arguments\":\"{}\"}}\n" ++
    "\n" ++
    "data: {\"type\":\"response.output_text.delta\"," ++
    "\"item_id\":\"msg_1\",\"delta\":\"done\"}\n" ++
    "\n" ++
    "data: {\"type\":\"response.output_item.done\",\"item\":{" ++
    "\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\"," ++
    "\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}}\n" ++
    "\n" ++
    "data: {\"type\":\"response.completed\"," ++
    "\"response\":{\"status\":\"completed\",\"usage\":" ++
    "{\"input_tokens\":100,\"input_tokens_details\":{\"cached_tokens\":90}," ++
    "\"output_tokens\":42," ++
    "\"output_tokens_details\":{\"reasoning_tokens\":20}}}}\n" ++
    "\n" ++
    "data: [DONE]\n\n" ++
    "data: not decoded\n";

const complete_trace =
    \\reasoning_started
    \\reasoning:weigh
    \\proof:openai-api-key:{"id":"rs_1","text":"weigh","encrypted_content":"enc","raw_text":""}
    \\tool_call_started:read
    \\tool_call_arguments:{}
    \\tool_call:call_1|read|{}
    \\text:done
    \\message:done
    \\usage:10/42/90/0
    \\stopped:complete|
    \\
;

const Rig = struct {
    responses: Responses,
    transport: testing.FakeTransport,
    credential: testing.FakeCredential,
    provider: Provider,

    const Setup = struct {
        replies: []const testing.FakeTransport.Reply,
        tokens: []const ?[]const u8 = &.{"token"},
        timeouts: Transport.Timeouts = .{},
        bytes_max: usize = Sse.bytes_max_default,
    };

    fn init(self: *Rig, io: std.Io, setup: *const Setup) void {
        const gpa = std.testing.allocator;
        self.responses = .init(gpa, .{
            .account = "openai-api-key",
            .endpoint = "https://api.openai.com/v1/responses",
        });
        self.transport = .{ .gpa = gpa, .replies = setup.replies };
        self.credential = .{ .tokens = setup.tokens };
        self.provider = .init(gpa, io, &.{
            .dialect = self.responses.dialect(),
            .transport = self.transport.transport(),
            .credential = self.credential.credential(),
            .timeouts = setup.timeouts,
            .bytes_max = setup.bytes_max,
        });
    }

    fn deinit(self: *Rig) void {
        self.provider.deinit();
        self.transport.deinit();
        self.responses.deinit();
    }

    fn expectTrace(self: *Rig, expected: []const u8) !void {
        const actual = try testing.trace(
            std.testing.allocator,
            self.provider.provider(),
            &testing.empty_request,
        );
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
        try std.testing.expectEqual(@as(usize, 0), self.transport.open_count);
    }
};

fn expectLine(request: []const u8, line: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, request, line) != null);
}

test "a complete stream yields its events through the seam and ends at the sentinel" {
    var rig: Rig = undefined;
    rig.init(std.testing.io, &.{
        .replies = &.{.{ .body = complete_body }},
        .tokens = &.{"secret-token"},
    });
    defer rig.deinit();
    try rig.expectTrace(complete_trace);
    try std.testing.expectEqual(@as(usize, 1), rig.transport.requests.items.len);
    const request = rig.transport.requests.items[0];
    try expectLine(request, "POST https://api.openai.com/v1/responses\n");
    try expectLine(request, "authorization: Bearer secret-token\n");
    try expectLine(request, "user-agent: drinky\n");
    try expectLine(request, "accept: text/event-stream\n");
    try expectLine(request, "\n\n{\"model\":\"model-a\"");
}

test "a rejected credential renews once and the repeat carries the fresh token" {
    var rig: Rig = undefined;
    rig.init(std.testing.io, &.{
        .replies = &.{
            .{ .status = .unauthorized, .body = "{\"error\":{\"message\":\"expired\"}}" },
            .{ .body = complete_body },
        },
        .tokens = &.{ "stale", "fresh" },
    });
    defer rig.deinit();
    try rig.expectTrace(complete_trace);
    try std.testing.expectEqual(@as(usize, 1), rig.credential.renewals);
    try std.testing.expectEqual(@as(usize, 2), rig.transport.requests.items.len);
    try expectLine(rig.transport.requests.items[0], "authorization: Bearer stale\n");
    try expectLine(rig.transport.requests.items[1], "authorization: Bearer fresh\n");
}

test "a rejected credential renews at most once and then fails as unauthorized" {
    var rig: Rig = undefined;
    rig.init(std.testing.io, &.{
        .replies = &.{
            .{ .status = .unauthorized, .body = "{\"error\":{\"message\":\"expired\"}}" },
        },
        .tokens = &.{"stale"},
    });
    defer rig.deinit();
    try rig.expectTrace("failed:unauthorized|-|401 Unauthorized: expired\n");
    try std.testing.expectEqual(@as(usize, 1), rig.credential.renewals);
    try std.testing.expectEqual(@as(usize, 1), rig.transport.requests.items.len);

    var twice: Rig = undefined;
    twice.init(std.testing.io, &.{
        .replies = &.{
            .{ .status = .unauthorized, .body = "{\"error\":{\"message\":\"expired\"}}" },
            .{ .status = .unauthorized, .body = "{\"error\":{\"message\":\"still expired\"}}" },
            .{ .body = complete_body },
        },
        .tokens = &.{ "stale", "fresh", "fresher" },
    });
    defer twice.deinit();
    try twice.expectTrace("failed:unauthorized|-|401 Unauthorized: still expired\n");
    try std.testing.expectEqual(@as(usize, 1), twice.credential.renewals);
    try std.testing.expectEqual(@as(usize, 2), twice.transport.requests.items.len);
}

test "a renewal that fails after a 401 reports the failure of the credential" {
    const cases = [_]struct { failure: Credential.Error, trace: []const u8 }{
        .{
            .failure = error.Rejected,
            .trace = "failed:unauthorized|-|The server rejected the credential.\n",
        },
        .{
            .failure = error.Network,
            .trace = "failed:network|-|The credential refresh did not reach the server.\n",
        },
    };
    for (cases) |case| {
        var rig: Rig = undefined;
        rig.init(std.testing.io, &.{
            .replies = &.{
                .{ .status = .unauthorized, .body = "{\"error\":{\"message\":\"expired\"}}" },
            },
            .tokens = &.{ "stale", "fresh" },
        });
        defer rig.deinit();
        rig.credential.renew_fail = case.failure;
        try rig.expectTrace(case.trace);
        try std.testing.expectEqual(@as(usize, 1), rig.credential.renewals);
        try std.testing.expectEqual(@as(usize, 1), rig.transport.requests.items.len);
    }

    var canceled: Rig = undefined;
    canceled.init(std.testing.io, &.{
        .replies = &.{
            .{ .status = .unauthorized, .body = "{\"error\":{\"message\":\"expired\"}}" },
        },
        .tokens = &.{ "stale", "fresh" },
    });
    defer canceled.deinit();
    canceled.credential.renew_fail = error.Canceled;
    try std.testing.expectError(
        error.Canceled,
        testing.trace(std.testing.allocator, canceled.provider.provider(), &testing.empty_request),
    );
}

test "a reply over the byte cap fails as an unsupported reply and names the cap" {
    const gpa = std.testing.allocator;
    const line = ":" ++ "x" ** 1022 ++ "\n";
    const body = try gpa.alloc(u8, line.len * (@divFloor(1 << 20, line.len) + 1));
    defer gpa.free(body);
    for (0..@divExact(body.len, line.len)) |index| {
        @memcpy(body[index * line.len ..][0..line.len], line);
    }
    const replies = [_]testing.FakeTransport.Reply{.{ .body = body }};
    var rig: Rig = undefined;
    rig.init(std.testing.io, &.{ .replies = &replies, .bytes_max = 1 << 20 });
    defer rig.deinit();
    try rig.expectTrace("failed:unsupported_reply|-|The reply exceeded 1 MiB.\n");
}

test "a failed head reports the quota it carries, then the failure with its hint" {
    var rig: Rig = undefined;
    rig.init(std.testing.io, &.{
        .replies = &.{.{
            .status = .too_many_requests,
            .headers = &.{
                .{ .name = "retry-after", .value = "3" },
                .{ .name = "x-codex-primary-used-percent", .value = "100" },
                .{ .name = "x-codex-primary-window-minutes", .value = "300" },
            },
            .body = "{\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow down\"}}",
        }},
    });
    defer rig.deinit();
    try rig.expectTrace(
        \\quota:100/300m|-
        \\failed:rate_limited|3000|429 Too Many Requests: slow down
        \\
    );
    try std.testing.expectEqual(@as(usize, 0), rig.credential.renewals);
}

test "a failed body is read up to the cap and cut at a UTF-8 boundary" {
    const body = ("x" ** (error_body_bytes_max - 1)) ++ "€" ++ ("y" ** 100);
    var rig: Rig = undefined;
    rig.init(std.testing.io, &.{
        .replies = &.{.{ .status = .internal_server_error, .body = body }},
    });
    defer rig.deinit();
    try rig.expectTrace("failed:overloaded|-|500 Internal Server Error: " ++
        ("x" ** (error_body_bytes_max - 1)) ++ "\n");
}

test "a transport that cannot connect fails as a network failure with the error name" {
    var rig: Rig = undefined;
    rig.init(std.testing.io, &.{ .replies = &.{.{ .fail = error.ConnectionRefused }} });
    defer rig.deinit();
    try rig.expectTrace(
        "failed:network|-|The connection failed because of error ConnectionRefused.\n",
    );
}

test "a cancel in the credential or in the transport ends the request as Canceled" {
    const gpa = std.testing.allocator;
    var credential_rig: Rig = undefined;
    credential_rig.init(std.testing.io, &.{ .replies = &.{.{ .body = complete_body }} });
    credential_rig.credential.token_fail = error.Canceled;
    defer credential_rig.deinit();
    try std.testing.expectError(
        error.Canceled,
        testing.trace(gpa, credential_rig.provider.provider(), &testing.empty_request),
    );
    try std.testing.expectEqual(@as(usize, 0), credential_rig.transport.requests.items.len);

    var transport_rig: Rig = undefined;
    transport_rig.init(std.testing.io, &.{ .replies = &.{.{ .fail = error.Canceled }} });
    defer transport_rig.deinit();
    try std.testing.expectError(
        error.Canceled,
        testing.trace(gpa, transport_rig.provider.provider(), &testing.empty_request),
    );
    try std.testing.expectEqual(@as(usize, 0), transport_rig.transport.open_count);
}

test "filler that makes no progress trips the idle window as a network failure" {
    const body = "data: {\"type\":\"surprise.new.event\"}\n" ** 8;
    var clock: core.testing.StepClock = undefined;
    clock.init(std.testing.allocator, 30);
    defer clock.deinit();
    var rig: Rig = undefined;
    rig.init(clock.io(), &.{ .replies = &.{.{ .body = body }}, .timeouts = .{ .idle_ms = 100 } });
    defer rig.deinit();
    try rig.expectTrace("failed:network|-|The stream failed because of error Timeout.\n");
}

test "a stream that ends without a stop yields what it decoded and then nothing" {
    var rig: Rig = undefined;
    rig.init(std.testing.io, &.{
        .replies = &.{.{
            .body = "data: {\"type\":\"response.output_text.delta\"," ++
                "\"item_id\":\"m1\",\"delta\":\"hi\"}\n",
        }},
    });
    defer rig.deinit();
    try rig.expectTrace("text:hi\n");
}

test "a body cut inside a line fails as a network failure" {
    var rig: Rig = undefined;
    rig.init(std.testing.io, &.{ .replies = &.{.{ .body = "data: {\"type\":\"response.out" }} });
    defer rig.deinit();
    try rig.expectTrace("failed:network|-|The stream failed because of error Incomplete.\n");
}

test "a read whose task cannot start fails the stream with the name of that failure" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .nothing });
    defer threaded.deinit();
    var rig: Rig = undefined;
    rig.init(threaded.io(), &.{ .replies = &.{.{ .body = "data: {\"type\":\"response.out" }} });
    defer rig.deinit();
    try rig.expectTrace(
        "failed:network|-|The stream failed because of error ConcurrencyUnavailable.\n",
    );
}

test "a credential that cannot be a header value or that fails never reaches the wire" {
    var split: Rig = undefined;
    split.init(std.testing.io, &.{
        .replies = &.{.{ .body = complete_body }},
        .tokens = &.{"token\r\nleaked: value"},
    });
    defer split.deinit();
    try split.expectTrace("failed:unauthorized|-|The credential cannot be a header value.\n");
    try std.testing.expectEqual(@as(usize, 0), split.transport.requests.items.len);

    var rejected: Rig = undefined;
    rejected.init(std.testing.io, &.{ .replies = &.{.{ .body = complete_body }} });
    rejected.credential.token_fail = error.Rejected;
    defer rejected.deinit();
    try rejected.expectTrace("failed:unauthorized|-|The server rejected the credential.\n");
    try std.testing.expectEqual(@as(usize, 0), rejected.transport.requests.items.len);

    var offline: Rig = undefined;
    offline.init(std.testing.io, &.{ .replies = &.{.{ .body = complete_body }} });
    offline.credential.token_fail = error.Network;
    defer offline.deinit();
    try offline.expectTrace("failed:network|-|The credential refresh did not reach the server.\n");
    try std.testing.expectEqual(@as(usize, 0), offline.transport.requests.items.len);
}

test "a provider serves one request after another" {
    var rig: Rig = undefined;
    rig.init(std.testing.io, &.{
        .replies = &.{
            .{ .body = complete_body },
            .{ .status = .internal_server_error, .body = "" },
            .{ .body = complete_body },
        },
    });
    defer rig.deinit();
    try rig.expectTrace(complete_trace);
    try rig.expectTrace("failed:overloaded|-|500 Internal Server Error\n");
    try rig.expectTrace(complete_trace);
    try std.testing.expectEqual(@as(usize, 3), rig.transport.requests.items.len);
}

test "an account without a token fails before it opens the transport" {
    var rig: Rig = undefined;
    rig.init(std.testing.io, &.{ .replies = &.{.{ .body = complete_body }}, .tokens = &.{null} });
    defer rig.deinit();
    try rig.expectTrace("failed:unauthorized|-|The account has no credential.\n");
    try std.testing.expectEqual(@as(usize, 0), rig.transport.requests.items.len);
}

test "a request the dialect cannot build fails before it opens the transport" {
    const gpa = std.testing.allocator;
    var transport: testing.FakeTransport = .{ .gpa = gpa };
    defer transport.deinit();

    var gemini: Gemini = .init(gpa, .{
        .account = "google-cloud-key",
        .project = "p",
        .location = .global,
    });
    defer gemini.deinit();
    var credential: testing.FakeCredential = .{ .tokens = &.{"token"} };
    var orphan_provider: Provider = .init(gpa, std.testing.io, &.{
        .dialect = gemini.dialect(),
        .transport = transport.transport(),
        .credential = credential.credential(),
    });
    defer orphan_provider.deinit();
    var orphan_request = testing.empty_request;
    orphan_request.items = &.{
        .{ .tool_result = .{ .call_id = "call_9", .output = .{ .content = "x" } } },
    };
    const orphan = try testing.trace(gpa, orphan_provider.provider(), &orphan_request);
    defer gpa.free(orphan);
    try std.testing.expectEqualStrings(
        "failed:invalid_request|-|The conversation holds a tool result without its call.\n",
        orphan,
    );
    try std.testing.expectEqual(@as(usize, 0), transport.requests.items.len);
}

const Hold = enum { head, stream };

fn holdReply(
    io: std.Io,
    server: *std.Io.net.Server,
    hold: Hold,
    reached: *std.Io.Queue(u8),
) (std.Io.net.Server.AcceptError || std.Io.Reader.DelimiterError || std.Io.Writer.Error ||
    std.Io.QueueClosedError)!void {
    var connection = try server.accept(io);
    defer connection.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = connection.reader(io, &read_buffer);
    for (0..64) |_| {
        const raw = try reader.interface.takeDelimiterInclusive('\n');
        if (std.mem.trimEnd(u8, raw, "\r\n").len == 0) break;
    }
    if (hold == .stream) {
        var write_buffer: [256]u8 = undefined;
        var writer = connection.writer(io, &write_buffer);
        try writer.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n" ++
            "content-length: 4096\r\n\r\ndata: {\"type\":\"response.in_progress\"}\n");
        try writer.interface.flush();
    }
    try reached.putOne(io, 1);
    var never: std.Io.Event = .unset;
    try never.wait(io);
    unreachable;
}

const OpenedTransport = struct {
    io: std.Io,
    inner: Transport,
    opened: std.Io.Event = .unset,

    const opened_vtable: Transport.VTable = .{ .open = openInner, .close = closeInner };

    fn transport(self: *OpenedTransport) Transport {
        return .{ .ptr = self, .vtable = &opened_vtable };
    }

    fn openInner(
        ptr: *anyopaque,
        request: *const Transport.Request,
    ) Transport.Error!Transport.Reply {
        const self: *OpenedTransport = @ptrCast(@alignCast(ptr));
        const reply = try self.inner.open(request);
        self.opened.set(self.io);
        return reply;
    }

    fn closeInner(ptr: *anyopaque) void {
        const self: *OpenedTransport = @ptrCast(@alignCast(ptr));
        self.inner.close();
    }
};

fn drainStream(gpa: std.mem.Allocator, provider_under_test: core.Provider) testing.TraceError!void {
    const actual = try testing.trace(gpa, provider_under_test, &testing.empty_request);
    gpa.free(actual);
}

fn expectCanceledRead(hold: Hold, timeouts: Transport.Timeouts) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const endpoint = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v1/responses", .{
        server.socket.address.getPort(),
    });
    defer gpa.free(endpoint);

    var reached_buffer: [1]u8 = undefined;
    var reached: std.Io.Queue(u8) = .init(&reached_buffer);
    var serve = try io.concurrent(holdReply, .{ io, &server, hold, &reached });
    var reaped = false;
    defer if (!reaped) {
        _ = serve.cancel(io) catch {};
    };

    var responses: Responses = .init(gpa, .{ .account = "openai-api-key", .endpoint = endpoint });
    defer responses.deinit();
    var http: Http = .init(gpa, io);
    defer http.deinit();
    var opened: OpenedTransport = .{ .io = io, .inner = http.transport() };
    var credential: testing.FakeCredential = .{ .tokens = &.{"token"} };
    var provider_under_test: Provider = .init(gpa, io, &.{
        .dialect = responses.dialect(),
        .transport = opened.transport(),
        .credential = credential.credential(),
        .timeouts = timeouts,
    });
    defer provider_under_test.deinit();

    var reading = try io.concurrent(drainStream, .{ gpa, provider_under_test.provider() });
    _ = try reached.getOne(io);
    if (hold == .stream) try opened.opened.wait(io);
    try std.testing.expectError(error.Canceled, reading.cancel(io));
    reaped = true;
    try std.testing.expectError(error.Canceled, serve.cancel(io));
}

test "a cancel during a blocked read ends the request as Canceled, also with a zero window" {
    try expectCanceledRead(.stream, .{});
    try expectCanceledRead(.stream, .{ .idle_ms = 0 });
    try expectCanceledRead(.head, .{});
    try expectCanceledRead(.head, .{ .connect_ms = 0 });
}

fn sessionOwns(reason: core.Provider.Failure.Reason) bool {
    return switch (reason) {
        .empty_reply, .too_many_tool_calls, .out_of_memory => true,
        .unauthorized,
        .rate_limited,
        .quota_exhausted,
        .overloaded,
        .invalid_request,
        .context_overflow,
        .network,
        .invalid_reply,
        .unsupported_reply,
        => false,
    };
}

const failed_statuses = [_]std.http.Status{
    .bad_request,
    .unauthorized,
    .payment_required,
    .forbidden,
    .request_timeout,
    .too_many_requests,
    .internal_server_error,
    @enumFromInt(529),
    @enumFromInt(999),
};

const failed_bodies = [_][]const u8{
    "",
    "not json",
    "{\"error\":{\"type\":\"usage_limit_reached\",\"resets_in_seconds\":60}}",
    "{\"error\":{\"code\":\"server_error\"}}",
    "{\"error\":{\"code\":\"rate_limit_exceeded\"}}",
    "{\"error\":{\"code\":\"insufficient_quota\"}}",
    "{\"error\":{\"code\":\"context_length_exceeded\"}}",
    "{\"error\":{\"code\":\"unknown\",\"message\":\"m\"}}",
    "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\"}}",
    "{\"type\":\"error\",\"error\":{\"type\":\"api_error\"}}",
    "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\"}}",
    "{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\"}}",
    "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\"}}",
    "{\"error\":{\"code\":429,\"message\":\"m\"}}",
    "{\"error\":{\"code\":503}}",
    "{\"error\":{\"code\":0}}",
};

const failed_frames = failed_bodies ++ [_][]const u8{
    "{\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"server_error\"}}}",
    "{\"type\":\"response.refusal.delta\",\"delta\":\"no\"}",
    "{\"type\":\"response.output_item.done\",\"item\":{\"type\":\"image\",\"id\":\"i\"}}",
    "{\"type\":\"response.completed\"}",
    "{\"type\":\"response.incomplete\",\"response\":{}}",
    "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"refusal\"}}",
    "{\"type\":\"message_stop\"}",
    "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"image\"}}",
    "{\"type\":\"content_block_delta\",\"index\":3,\"delta\":{\"type\":\"text_delta\"}}",
    "{\"promptFeedback\":{\"blockReason\":\"SAFETY\"}}",
    "{\"candidates\":[{\"finishReason\":\"MALFORMED_FUNCTION_CALL\"}]}",
    "{\"candidates\":[{\"finishReason\":\"RECITATION\"}]}",
    "{\"candidates\":[\"not an object\"]}",
    "[DONE]",
};

test "no dialect reports a reason that only the session produces" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var responses: Responses = .init(gpa, .{ .account = "openai-api-key", .endpoint = "e" });
    defer responses.deinit();
    var messages: Messages = .init(gpa, .{ .account = "anthropic-api-key", .identity = .api_key });
    defer messages.deinit();
    var gemini: Gemini = .init(gpa, .{
        .account = "google-cloud-key",
        .project = "p",
        .location = .global,
    });
    defer gemini.deinit();

    for ([_]Dialect{ responses.dialect(), messages.dialect(), gemini.dialect() }) |dialect| {
        var failures: usize = 0;
        for (failed_statuses) |status| {
            for (failed_bodies) |body| {
                _ = arena.reset(.retain_capacity);
                const failed: Dialect.Failed = .{
                    .status = status,
                    .retry_after_ms = null,
                    .body = body,
                };
                const failure = try dialect.failure(arena.allocator(), &failed);
                try std.testing.expect(!sessionOwns(failure.reason));
            }
        }
        for (failed_frames) |payload| {
            _ = arena.reset(.retain_capacity);
            dialect.reset();
            var events: Dialect.Events = .empty;
            _ = try dialect.decode(arena.allocator(), payload, &events);
            try dialect.finish(arena.allocator(), &events);
            for (events.items) |event| switch (event) {
                .failed => |failure| {
                    failures += 1;
                    try std.testing.expect(!sessionOwns(failure.reason));
                },
                else => {},
            };
        }
        try std.testing.expect(failures >= 5);
    }
}
