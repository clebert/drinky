//! The provider-shared SSE pull-stream engine: the Deadline+Budget-bounded
//! line reader (recognized frames restart the idle window, filler draws it
//! down), retry classification, and the connect tail. `Engine` generates the
//! methods over a provider's own stream struct. The frame vocabulary
//! (`decode`), request building, and identity stay provider-side.

const std = @import("std");

const llm = @import("llm.zig");
const net = @import("net.zig");

/// The outcome of decoding one SSE `data:` line. Only a recognized frame
/// (`event`/`progress`) restarts the idle window. Filler (`ignored`) draws it
/// down, so a stream of only filler still trips the timeout.
pub const Decoded = union(enum) {
    /// An event to hand back to the caller.
    event: llm.Event,
    /// A recognized frame with no event for the caller (usage, block boundaries).
    progress,
    /// Filler: a keepalive ping, or a frame the protocol does not define.
    ignored,
    /// A sentinel that ends the byte stream (OpenAI's `[DONE]`).
    done,
};

/// The seam that separates the display text of two reasoning runs (see
/// `Reasoning`).
pub const blank_line = "\n\n";

/// Where one stream's reasoning display stands, which decides the blank line
/// between two reasoning runs. It implements the `llm.Event.thinking` contract
/// for every transport, so the transports cannot drift apart.
///
/// `open` means the display shows the text of the current reasoning run.
/// `closed` means that run ended, so a seam is pending and the next reasoning
/// text takes a blank line in front of it. `none` means the display shows
/// something else, so the next reasoning text starts a block of its own.
///
/// Only a run with bytes moves the state. An empty frame displays nothing, so
/// it keeps a pending seam for the run that follows it.
pub const Reasoning = enum {
    none,
    open,
    closed,

    /// Take the pending seam and open a run. A false result means no seam is
    /// pending. Use this only for a run whose display text another module
    /// writes, because the seam then needs an event of its own.
    pub fn takeSeam(self: *Reasoning) bool {
        const pending = self.* == .closed;
        self.* = .open;
        return pending;
    }

    /// One run of reasoning display text, with the blank line that a pending
    /// seam adds in front of it. Without that line the text of two runs joins
    /// into one line, and the markdown markers at the seam merge into a literal
    /// `****`. A run with no bytes displays nothing and holds the seam.
    pub fn display(self: *Reasoning, arena: std.mem.Allocator, text: []const u8) !Decoded {
        if (text.len == 0) return .progress;
        if (!self.takeSeam()) return .{ .event = .{ .thinking = text } };
        return .{ .event = .{
            .thinking = try std.mem.concat(arena, u8, &.{ blank_line, text }),
        } };
    }

    /// The answer display ends every reasoning run, so the next reasoning text
    /// starts a block of its own. Answer text with no bytes displays nothing and
    /// holds a pending seam. Returns whether the text displays.
    pub fn answer(self: *Reasoning, text: []const u8) bool {
        if (text.len == 0) return false;
        self.* = .none;
        return true;
    }

    /// End the open run, so its seam waits for the next reasoning text. A run
    /// that displayed nothing keeps the state it had.
    pub fn end(self: *Reasoning) void {
        if (self.* == .open) self.* = .closed;
    }
};

/// The engine methods over a provider stream struct `S`. `S` declares the
/// connection fields these methods use (`gpa`, `established`, `client`,
/// `request`, `response`, `body`, `io`, `idle_ms`, `budget`, `status`,
/// `error_length`, `error_retryable`, `retry_after_ms`, `frame_arena`, `usage`,
/// `decompress`, `decompress_buffer`, `error_buffer`, `redirect_buffer`,
/// `transfer_buffer`)
/// plus `deinitDecode()` for stream-lifetime decode state,
/// `decode(payload) !Decoded`, and `describeError(body) !?[]const u8` to read
/// the message out of a failed head's error body (see `refineError`). The
/// engine calls an optional `captureHead(*const Head)` hook while the response
/// head is still valid, for provider-specific header capture. The engine resets
/// `frame_arena` before each SSE frame, so returned events can borrow a parse
/// until the next read.
pub fn Engine(comptime S: type) type {
    return struct {
        pub fn deinit(stream: *S) void {
            stream.deinitDecode();
            if (stream.decompress_buffer.len != 0) stream.gpa.free(stream.decompress_buffer);
            stream.request.deinit();
            stream.client.deinit();
        }

        /// Whether the request head reported success. A false result means the
        /// stream carries an error body, not events. Read it with `errorText`.
        pub fn ok(stream: *const S) bool {
            return stream.status == .ok;
        }

        /// The error body text when the request failed, or empty otherwise.
        pub fn errorText(stream: *const S) []const u8 {
            return stream.error_buffer[0..stream.error_length];
        }

        /// Whether the head reported that the provider rejected the credential.
        /// A token that another Pith instance rotated away reads like this, and
        /// so does a revoked one.
        pub fn unauthorized(stream: *const S) bool {
            return stream.status == .unauthorized;
        }

        /// Whether the current API failure is worth a retry: a streamed error
        /// marked transient by its provider, or a failed head that carries
        /// request timeout, rate limiting, or any 5xx server fault.
        pub fn retryable(stream: *const S) bool {
            if (stream.error_retryable) return true;
            if (stream.status == .request_timeout or stream.status == .too_many_requests)
                return true;
            return @divFloor(@intFromEnum(stream.status), 100) == 5;
        }

        /// The `retry-after` the head asked for, in milliseconds, or null.
        pub fn retryAfterMs(stream: *const S) ?u64 {
            return stream.retry_after_ms;
        }

        /// Usage accumulated so far, complete by the provider's terminal event.
        pub fn usageSoFar(stream: *const S) llm.Usage {
            return stream.usage;
        }

        /// Run `connectFn(args)` — the provider's request builder, which must
        /// end with `finish` — bounded by the connect timeout. The call fills
        /// the stream in place. On expiry (or any failure) the engine tears
        /// down the stream and the error surfaces, so a caller that sees one
        /// owns nothing.
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
                // The timeout races connect, so a connect that finished right
                // at the deadline can still surface as `error.Timeout`.
                // `established` (set last by a full connect) marks that
                // fully-built stream apart from a canceled or partial connect,
                // whose own errdefers already ran. Free only the established
                // stream here.
                if (stream.established) deinit(stream);
                return err;
            };
        }

        /// The first half of a provider `connect`: the client and fresh shared
        /// state. The provider adds its own decode state and owns the
        /// errdefers between this and `finish`.
        pub fn begin(stream: *S, gpa: std.mem.Allocator, io: std.Io) void {
            stream.gpa = gpa;
            stream.client = .{ .allocator = gpa, .io = io };
            stream.frame_arena = .init(gpa);
            stream.usage = .{};
            stream.error_length = 0;
            stream.error_retryable = false;
            stream.retry_after_ms = null;
        }

        /// The shared tail of a provider `connect`: send `body` over the built
        /// request, receive the head, wire the (possibly decompressing) body
        /// reader, and capture a failed head's error body. It sets
        /// `established` last, which marks the stream fully built.
        pub fn finish(stream: *S, body: []const u8) !void {
            stream.request.transfer_encoding = .{ .content_length = body.len };
            var writer = try stream.request.sendBodyUnflushed(&.{});
            try writer.writer.writeAll(body);
            try writer.end();
            try stream.request.connection.?.flush();

            stream.response = try stream.request.receiveHead(&stream.redirect_buffer);
            stream.status = stream.response.head.status;
            // Read the head's headers now: the body reader's creation invalidates them.
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

        /// Compose the reported text of a failed head: the response status, then
        /// the message the provider `describeError` hook reads out of the
        /// captured error body. A failed head never reaches `decode`, so without
        /// this step `errorText` reports raw wire JSON and names no status. The
        /// raw body stays as the detail when the hook finds no message, and an
        /// empty body reports the status alone.
        fn refineError(stream: *S) void {
            const raw = stream.error_buffer[0..stream.error_length];
            const detail = detail: {
                const described = stream.describeError(raw) catch break :detail raw;
                const message = described orelse break :detail raw;
                break :detail if (message.len == 0) raw else message;
            };
            const phrase = stream.status.phrase() orelse "";
            // The detail can borrow the raw bytes, so compose out of place. The
            // formatted text is a new allocation and cannot overlap them. A
            // failed format leaves the captured body as it is.
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

        /// The next decoded event, or null at end of stream. One shared
        /// `Deadline` spans the read of each event, so filler draws the window
        /// down while every recognized frame restarts it. Only a genuine stall
        /// surfaces `error.Timeout`.
        pub fn next(stream: *S) !?llm.Event {
            // Reused across skipped filler lines. The event handed back borrows
            // the frame arena, not this buffer.
            var line_buffer: std.Io.Writer.Allocating = .init(stream.gpa);
            defer line_buffer.deinit();
            var deadline = net.Deadline.start(stream.io, stream.idle_ms);
            while (true) {
                // Drop the previous returned event or skipped frame before the
                // next read. Reset inside the loop so a progress flood cannot
                // retain every parse consumed by one `next` call.
                _ = stream.frame_arena.reset(.retain_capacity);
                const line = (try takeLine(stream, deadline, &line_buffer)) orelse return null;
                // Charge every line against the whole-stream budget: a peer that
                // makes frequent valid progress still hits an aggregate ceiling,
                // including an eventless-`.progress` flood that never returns.
                try stream.budget.take(line.len + 1);
                const trimmed = std.mem.trimEnd(u8, line, "\r");
                if (!std.mem.startsWith(u8, trimmed, "data:")) {
                    // Not progress. Check the window explicitly so buffered
                    // filler that never blocks a read cannot spin here forever.
                    if (deadline.expired(stream.io)) return error.Timeout;
                    continue;
                }
                const payload = std.mem.trimStart(u8, trimmed["data:".len..], " ");
                switch (try stream.decode(payload)) {
                    .event => |event| return event,
                    .progress => deadline = net.Deadline.start(stream.io, stream.idle_ms),
                    // Same buffered-filler guard as the non-`data:` arm above.
                    .ignored => if (deadline.expired(stream.io)) return error.Timeout,
                    .done => return null,
                }
            }
        }

        /// The next SSE line. An already buffered line returns directly.
        /// Otherwise the time left in the idle window bounds the read.
        fn takeLine(
            stream: *S,
            deadline: net.Deadline,
            buffer: *std.Io.Writer.Allocating,
        ) !?[]const u8 {
            if (std.mem.indexOfScalar(u8, stream.body.buffered(), '\n') != null)
                return readLine(stream, buffer);
            return deadline.call(stream.io, readLine, .{ stream, buffer });
        }

        /// Take one delimited line into the reused line buffer and map a
        /// canceled read to `error.Canceled` (a turn cancel, or the idle timer
        /// that reaps this task). The line grows bounded by what the budget can
        /// still deliver, so the read rejects an oversized frame before it is
        /// fully buffered. One `data:` line is one event — no multi-line frame
        /// is assembled — so this bounds the assembled frame too.
        fn readLine(stream: *S, buffer: *std.Io.Writer.Allocating) anyerror!?[]const u8 {
            buffer.clearRetainingCapacity();
            // A spent budget fails the read as `StreamResponseTooLarge` before
            // it can reach end of stream — the right verdict at the ceiling.
            const cap: std.Io.Limit = .limited(stream.budget.remaining());
            _ = stream.body.streamDelimiterLimit(&buffer.writer, '\n', cap) catch |err|
                switch (err) {
                    error.StreamTooLong => return error.StreamResponseTooLarge,
                    error.WriteFailed => return error.OutOfMemory,
                    error.ReadFailed => return readFailed(stream),
                };
            // The delimiter, if any, stays buffered: a '\n' closes this line.
            // End of stream with nothing buffered ends the reply. A non-empty
            // final line with no newline is a truncated frame — retryable,
            // never decoded.
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

        /// Refine a reader `ReadFailed` into `error.Canceled` when the socket
        /// recorded a canceled read. An HTTP body error can leave both
        /// connection error slots null, so do not call `Connection.getReadError`.
        fn readFailed(stream: *S) anyerror {
            const connection = stream.request.connection orelse return error.ReadFailed;
            const read_error = connection.stream_reader.err orelse return error.ReadFailed;
            if (read_error == error.Canceled) return error.Canceled;
            return error.ReadFailed;
        }

        /// Record a streamed error frame for `errorText` and retry
        /// classification. The provider's `decode` calls this.
        pub fn recordError(stream: *S, message: []const u8, error_retryable: bool) void {
            stream.error_length = utf8Length(message, stream.error_buffer.len);
            stream.error_retryable = error_retryable;
            @memcpy(stream.error_buffer[0..stream.error_length], message[0..stream.error_length]);
        }
    };
}

/// The length to cut `text` to, so that it fits `length_max` and splits no
/// UTF-8 sequence. The step back over the continuation bytes at the cut is
/// bounded by the three bytes a four-byte sequence can hold. A cut inside
/// invalid bytes keeps the plain length.
fn utf8Length(text: []const u8, length_max: usize) usize {
    if (text.len <= length_max) return text.len;
    var length = length_max;
    for (0..3) |_| {
        if (length == 0 or text[length] & 0xc0 != 0x80) return length;
        length -= 1;
    }
    return length_max;
}

/// Parse the `retry-after` header (whole seconds) into milliseconds. Null when
/// absent or an HTTP-date the backoff falls back on.
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

/// A logical clock over a real backend for the idle-window tests: `now`
/// returns the current tick and advances by a fixed step. This drives the
/// window to expiry while no real time passes. The clock overrides only `now`,
/// so callers must never reach another vtable entry with this userdata. The
/// tests feed fully buffered `.fixed` readers, so `takeLine` never reaches
/// `deadline.call` (the sole path to a backend-owned timed operation).
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

    // An HTTP-date form is unsupported and falls back to the computed backoff.
    const dated = "HTTP/1.1 503 Service Unavailable\r\n" ++
        "retry-after: Wed, 21 Oct 2015 07:28:00 GMT\r\ncontent-length:0\r\n\r\n";
    try std.testing.expectEqual(
        @as(?u64, null),
        retryAfter(try std.http.Client.Response.Head.parse(dated)),
    );

    // A huge value saturates and does not wrap, so the backoff cap still bounds it.
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

        // This message borrows the raw bytes it replaces, which the hook
        // contract allows. Both real providers return frame-arena memory
        // instead, because a `std.json.Value` parse copies every string.
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

    // An unrecognized body stays the detail. An empty body reports the status
    // alone, which a raw report of no bytes never names.
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
    // The cut falls inside the three bytes of "€", so it steps back to the
    // start of that sequence.
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

    // A hook that fails keeps the captured body as the detail under the status.
    engine.refineError(&stream);
    try std.testing.expectEqualStrings(
        "500 Internal Server Error: raw body",
        engine.errorText(&stream),
    );
    stream.frame_arena.deinit();

    // A format that cannot allocate leaves the captured body exactly as it is.
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

    // "€" spans three bytes, so every cut inside it steps back to its start.
    try std.testing.expectEqual(@as(usize, 1), utf8Length("a€b", 2));
    try std.testing.expectEqual(@as(usize, 1), utf8Length("a€b", 3));
    try std.testing.expectEqual(@as(usize, 4), utf8Length("a€b", 4));

    // Continuation bytes without a start byte keep the plain length.
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
    // Any 5xx is retryable, not just the enumerated transient ones —
    // Anthropic's 529 included.
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
    // Only a literal 5xx counts: `Status.class` maps every out-of-range status
    // to `server_error`, which must not make a nonsense status retryable.
    stream.status = @enumFromInt(999);
    try std.testing.expect(!engine.retryable(&stream));
    try std.testing.expectEqual(std.http.Status.Class.server_error, stream.status.class());
}
