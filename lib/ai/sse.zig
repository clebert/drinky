const std = @import("std");

const llm = @import("llm.zig");
const net = @import("net.zig");

pub const Decoded = union(enum) {
    event: llm.Event,
    progress,
    ignored,
    done,
};

pub const blank_line = "\n\n";

pub const Reasoning = enum {
    none,
    open,
    closed,

    pub fn takeSeam(self: *Reasoning) bool {
        const pending = self.* == .closed;
        self.* = .open;
        return pending;
    }

    pub fn display(self: *Reasoning, arena: std.mem.Allocator, text: []const u8) !Decoded {
        if (text.len == 0) return .progress;
        if (!self.takeSeam()) return .{ .event = .{ .thinking = text } };
        return .{ .event = .{
            .thinking = try std.mem.concat(arena, u8, &.{ blank_line, text }),
        } };
    }

    pub fn answer(self: *Reasoning, text: []const u8) bool {
        if (text.len == 0) return false;
        self.* = .none;
        return true;
    }

    pub fn end(self: *Reasoning) void {
        if (self.* == .open) self.* = .closed;
    }
};

pub fn Engine(comptime S: type) type {
    return struct {
        pub fn deinit(stream: *S) void {
            stream.deinitDecode();
            if (stream.decompress_buffer.len != 0) stream.gpa.free(stream.decompress_buffer);
            stream.request.deinit();
            stream.deinitHeaders();
            stream.client.deinit();
        }

        pub fn ok(stream: *const S) bool {
            return stream.status == .ok;
        }

        pub fn errorText(stream: *const S) []const u8 {
            return stream.error_buffer[0..stream.error_length];
        }

        pub fn unauthorized(stream: *const S) bool {
            return stream.status == .unauthorized;
        }

        pub fn retryable(stream: *const S) bool {
            if (stream.error_retryable) return true;
            if (stream.status == .request_timeout or stream.status == .too_many_requests)
                return true;
            return @divFloor(@intFromEnum(stream.status), 100) == 5;
        }

        pub fn retryAfterMs(stream: *const S) ?u64 {
            return stream.retry_after_ms;
        }

        pub fn usageSoFar(stream: *const S) llm.Usage {
            return stream.usage;
        }

        pub fn open(
            stream: *S,
            io: std.Io,
            timeouts: net.Timeouts,
            comptime connectFn: anytype,
            args: std.meta.ArgsTuple(@TypeOf(connectFn)),
        ) !void {
            stream.io = io;
            stream.idle_ms = timeouts.idle_ms;
            stream.budget = .{ .max = net.stream_response_bytes_max };
            stream.established = false;
            net.withTimeout(io, timeouts.connect_ms, connectFn, args) catch |err| {
                if (stream.established) deinit(stream);
                return err;
            };
        }

        pub fn begin(stream: *S, gpa: std.mem.Allocator, io: std.Io) void {
            stream.gpa = gpa;
            stream.client = .{ .allocator = gpa, .io = io };
            stream.frame_arena = .init(gpa);
            stream.usage = .{};
            stream.error_length = 0;
            stream.error_retryable = false;
            stream.retry_after_ms = null;
            stream.beginDecode();
        }

        pub fn finish(stream: *S, body: []const u8) !void {
            stream.request.transfer_encoding = .{ .content_length = body.len };
            var writer = try stream.request.sendBodyUnflushed(&.{});
            try writer.writer.writeAll(body);
            try writer.end();
            try stream.request.connection.?.flush();

            stream.response = try stream.request.receiveHead(&stream.redirect_buffer);
            stream.status = stream.response.head.status;
            stream.retry_after_ms = retryAfter(stream.response.head);
            if (@hasDecl(S, "captureHead")) stream.captureHead(&stream.response.head);
            stream.decompress_buffer = try net.decompressBuffer(
                stream.gpa,
                stream.response.head.content_encoding,
            );
            stream.body = stream.response.readerDecompressing(
                &stream.transfer_buffer,
                &stream.decompress,
                stream.decompress_buffer,
            );
            if (stream.status != .ok) {
                stream.error_length = stream.body.readSliceShort(&stream.error_buffer) catch 0;
                refineError(stream);
            }
            stream.established = true;
        }

        fn refineError(stream: *S) void {
            const raw = stream.error_buffer[0..stream.error_length];
            const detail = detail: {
                const described = stream.describeError(raw) catch break :detail raw;
                const message = described orelse break :detail raw;
                break :detail if (message.len == 0) raw else message;
            };
            const phrase = stream.status.phrase() orelse "";
            const text = std.fmt.allocPrint(stream.frame_arena.allocator(), "{d}{s}{s}{s}{s}", .{
                @intFromEnum(stream.status),
                if (phrase.len == 0) "" else " ",
                phrase,
                if (detail.len == 0) "" else ": ",
                detail,
            }) catch return;
            stream.error_length = utf8Length(text, stream.error_buffer.len);
            @memcpy(stream.error_buffer[0..stream.error_length], text[0..stream.error_length]);
        }

        pub fn next(stream: *S) !?llm.Event {
            var line_buffer: std.Io.Writer.Allocating = .init(stream.gpa);
            defer line_buffer.deinit();
            var deadline = net.Deadline.start(stream.io, stream.idle_ms);
            while (true) {
                _ = stream.frame_arena.reset(.retain_capacity);
                const line = (try takeLine(stream, deadline, &line_buffer)) orelse return null;
                try stream.budget.take(line.len + 1);
                const trimmed = std.mem.trimEnd(u8, line, "\r");
                if (!std.mem.startsWith(u8, trimmed, "data:")) {
                    if (deadline.expired(stream.io)) return error.Timeout;
                    continue;
                }
                const payload = std.mem.trimStart(u8, trimmed["data:".len..], " ");
                switch (try stream.decode(payload)) {
                    .event => |event| return event,
                    .progress => deadline = net.Deadline.start(stream.io, stream.idle_ms),
                    .ignored => if (deadline.expired(stream.io)) return error.Timeout,
                    .done => return null,
                }
            }
        }

        fn takeLine(
            stream: *S,
            deadline: net.Deadline,
            buffer: *std.Io.Writer.Allocating,
        ) !?[]const u8 {
            if (std.mem.indexOfScalar(u8, stream.body.buffered(), '\n') != null)
                return readLine(stream, buffer);
            return deadline.call(stream.io, readLine, .{ stream, buffer });
        }

        fn readLine(stream: *S, buffer: *std.Io.Writer.Allocating) anyerror!?[]const u8 {
            buffer.clearRetainingCapacity();
            const cap: std.Io.Limit = .limited(stream.budget.remaining());
            _ = stream.body.streamDelimiterLimit(&buffer.writer, '\n', cap) catch |err|
                switch (err) {
                    error.StreamTooLong => return error.StreamResponseTooLarge,
                    error.WriteFailed => return error.OutOfMemory,
                    error.ReadFailed => return readFailed(stream),
                };
            const pending = stream.body.peekByte() catch |err| switch (err) {
                error.EndOfStream => return if (buffer.written().len == 0)
                    null
                else
                    error.IncompleteReply,
                error.ReadFailed => return readFailed(stream),
            };
            std.debug.assert(pending == '\n');
            stream.body.toss(1);
            return buffer.written();
        }

        fn readFailed(stream: *S) anyerror {
            const connection = stream.request.connection orelse return error.ReadFailed;
            const read_error = connection.stream_reader.err orelse return error.ReadFailed;
            if (read_error == error.Canceled) return error.Canceled;
            return error.ReadFailed;
        }

        pub fn recordError(stream: *S, message: []const u8, error_retryable: bool) void {
            stream.error_length = utf8Length(message, stream.error_buffer.len);
            stream.error_retryable = error_retryable;
            @memcpy(stream.error_buffer[0..stream.error_length], message[0..stream.error_length]);
        }
    };
}

fn utf8Length(text: []const u8, length_max: usize) usize {
    if (text.len <= length_max) return text.len;
    var length = length_max;
    for (0..3) |_| {
        if (length == 0 or text[length] & 0xc0 != 0x80) return length;
        length -= 1;
    }
    return length_max;
}

fn retryAfter(head: std.http.Client.Response.Head) ?u64 {
    var headers = head.iterateHeaders();
    while (headers.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "retry-after")) continue;
        const seconds = std.fmt.parseInt(u64, std.mem.trim(u8, header.value, " \t"), 10) catch
            return null;
        return seconds *| 1000;
    }
    return null;
}

pub const TickingIo = struct {
    backend: std.Io,
    vtable: std.Io.VTable,
    tick_ns: i96,
    step_ns: i96,

    pub fn init(backend: std.Io, step_ns: i96) TickingIo {
        var vtable = backend.vtable.*;
        vtable.now = now;
        return .{ .backend = backend, .vtable = vtable, .tick_ns = 0, .step_ns = step_ns };
    }

    pub fn io(self: *TickingIo) std.Io {
        return .{ .userdata = self, .vtable = &self.vtable };
    }

    fn now(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
        _ = clock;
        const self: *TickingIo = @ptrCast(@alignCast(userdata));
        const current = self.tick_ns;
        self.tick_ns += self.step_ns;
        return .{ .nanoseconds = current };
    }
};

test retryAfter {
    const with = "HTTP/1.1 429 Too Many Requests\r\nretry-after: 7\r\ncontent-length:0\r\n\r\n";
    const head = try std.http.Client.Response.Head.parse(with);
    try std.testing.expectEqual(@as(?u64, 7000), retryAfter(head));

    const without = "HTTP/1.1 503 Service Unavailable\r\ncontent-length:0\r\n\r\n";
    try std.testing.expectEqual(
        @as(?u64, null),
        retryAfter(try std.http.Client.Response.Head.parse(without)),
    );

    const dated = "HTTP/1.1 503 Service Unavailable\r\n" ++
        "retry-after: Wed, 21 Oct 2015 07:28:00 GMT\r\ncontent-length:0\r\n\r\n";
    try std.testing.expectEqual(
        @as(?u64, null),
        retryAfter(try std.http.Client.Response.Head.parse(dated)),
    );

    const huge = "HTTP/1.1 429 Too Many Requests\r\n" ++
        "retry-after: 99999999999999999\r\ncontent-length:0\r\n\r\n";
    try std.testing.expectEqual(
        @as(?u64, std.math.maxInt(u64)),
        retryAfter(try std.http.Client.Response.Head.parse(huge)),
    );
}

test "a body read failure without a connection error stays a read failure" {
    const Stub = struct {
        request: struct { connection: ?*std.http.Client.Connection },
    };
    const engine = Engine(Stub);
    var connection: std.http.Client.Connection = undefined;
    connection.protocol = .plain;
    connection.stream_reader.err = null;
    var stream: Stub = .{ .request = .{ .connection = &connection } };

    try std.testing.expectEqual(error.ReadFailed, engine.readFailed(&stream));
}

test "refineError reports the status with the message of a captured error body" {
    const Described = struct {
        frame_arena: std.heap.ArenaAllocator,
        status: std.http.Status,
        error_length: usize,
        error_buffer: [64]u8,

        pub fn describeError(_: *@This(), body: []const u8) !?[]const u8 {
            const start = std.mem.indexOfScalar(u8, body, '=') orelse return null;
            return body[start + 1 ..];
        }
    };
    const engine = Engine(Described);
    var stream: Described = .{
        .frame_arena = .init(std.testing.allocator),
        .status = .too_many_requests,
        .error_length = 0,
        .error_buffer = undefined,
    };
    defer stream.frame_arena.deinit();

    const body = "code=too slow";
    @memcpy(stream.error_buffer[0..body.len], body);
    stream.error_length = body.len;
    engine.refineError(&stream);
    try std.testing.expectEqualStrings(
        "429 Too Many Requests: too slow",
        engine.errorText(&stream),
    );

    const raw = "not json";
    @memcpy(stream.error_buffer[0..raw.len], raw);
    stream.error_length = raw.len;
    engine.refineError(&stream);
    try std.testing.expectEqualStrings(
        "429 Too Many Requests: not json",
        engine.errorText(&stream),
    );
    stream.error_length = 0;
    engine.refineError(&stream);
    try std.testing.expectEqualStrings("429 Too Many Requests", engine.errorText(&stream));
}

test "refineError clamps a composed text longer than the error buffer" {
    const Long = struct {
        frame_arena: std.heap.ArenaAllocator,
        status: std.http.Status,
        error_length: usize,
        error_buffer: [24]u8,

        pub fn describeError(self: *@This(), _: []const u8) !?[]const u8 {
            return try self.frame_arena.allocator().dupe(u8, "abcdef€ and more");
        }
    };
    var long: Long = .{
        .frame_arena = .init(std.testing.allocator),
        .status = .bad_request,
        .error_length = 0,
        .error_buffer = undefined,
    };
    defer long.frame_arena.deinit();
    Engine(Long).refineError(&long);
    try std.testing.expectEqualStrings("400 Bad Request: abcdef", Engine(Long).errorText(&long));
}

test "refineError keeps the captured body when the hook or the format fails" {
    const Failing = struct {
        frame_arena: std.heap.ArenaAllocator,
        status: std.http.Status,
        error_length: usize,
        error_buffer: [64]u8,

        pub fn describeError(_: *@This(), _: []const u8) !?[]const u8 {
            return error.OutOfMemory;
        }
    };
    const engine = Engine(Failing);
    const body = "raw body";
    var stream: Failing = .{
        .frame_arena = .init(std.testing.allocator),
        .status = .internal_server_error,
        .error_length = body.len,
        .error_buffer = undefined,
    };
    @memcpy(stream.error_buffer[0..body.len], body);

    engine.refineError(&stream);
    try std.testing.expectEqualStrings(
        "500 Internal Server Error: raw body",
        engine.errorText(&stream),
    );
    stream.frame_arena.deinit();

    @memcpy(stream.error_buffer[0..body.len], body);
    stream.error_length = body.len;
    stream.frame_arena = .init(std.testing.failing_allocator);
    defer stream.frame_arena.deinit();
    engine.refineError(&stream);
    try std.testing.expectEqualStrings(body, engine.errorText(&stream));
}

test utf8Length {
    try std.testing.expectEqual(@as(usize, 3), utf8Length("abc", 8));
    try std.testing.expectEqual(@as(usize, 2), utf8Length("abc", 2));

    try std.testing.expectEqual(@as(usize, 1), utf8Length("a€b", 2));
    try std.testing.expectEqual(@as(usize, 1), utf8Length("a€b", 3));
    try std.testing.expectEqual(@as(usize, 4), utf8Length("a€b", 4));

    try std.testing.expectEqual(@as(usize, 4), utf8Length("\x80\x80\x80\x80\x80", 4));
}

test "retryable classifies streamed errors and head statuses" {
    const Stub = struct {
        status: std.http.Status,
        error_retryable: bool = false,
    };
    const engine = Engine(Stub);
    var stream: Stub = .{ .status = .request_timeout };
    try std.testing.expect(engine.retryable(&stream));
    stream.status = .too_many_requests;
    try std.testing.expect(engine.retryable(&stream));
    stream.status = @enumFromInt(529);
    try std.testing.expect(engine.retryable(&stream));
    stream.status = .not_implemented;
    try std.testing.expect(engine.retryable(&stream));
    stream.status = .ok;
    try std.testing.expect(!engine.retryable(&stream));
    stream.status = .bad_request;
    try std.testing.expect(!engine.retryable(&stream));
    stream.error_retryable = true;
    try std.testing.expect(engine.retryable(&stream));
    stream.error_retryable = false;
    stream.status = @enumFromInt(999);
    try std.testing.expect(!engine.retryable(&stream));
    try std.testing.expectEqual(std.http.Status.Class.server_error, stream.status.class());
}
