//! The provider-shared SSE pull-stream engine: the Deadline+Budget-bounded
//! line reader (recognized frames restart the idle window, filler draws it
//! down), retry classification, and the connect tail. `Engine` generates the
//! methods over a provider's own stream struct; the frame vocabulary
//! (`decode`), request building, and identity stay provider-side.

const std = @import("std");

const llm = @import("llm.zig");
const net = @import("net.zig");

/// The outcome of decoding one SSE `data:` line. Only a recognized frame
/// (`event`/`progress`) restarts the idle window; filler (`ignored`) draws it
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

/// The engine methods over a provider stream struct `S`, which declares the
/// connection fields these methods use (`gpa`, `established`, `client`,
/// `request`, `response`, `body`, `io`, `idle_ms`, `budget`, `status`,
/// `error_length`, `retry_after_ms`, `frame_arena`, `usage`, `decompress`,
/// `decompress_buffer`, `error_buffer`, `redirect_buffer`, `transfer_buffer`)
/// plus `deinitDecode()` for stream-lifetime decode state and
/// `decode(payload) !Decoded`. The engine resets `frame_arena` before each SSE
/// frame, so returned events may borrow a parse until the next read.
pub fn Engine(comptime S: type) type {
    return struct {
        pub fn deinit(stream: *S) void {
            stream.deinitDecode();
            if (stream.decompress_buffer.len != 0) stream.gpa.free(stream.decompress_buffer);
            stream.request.deinit();
            stream.client.deinit();
        }

        /// Whether the request head reported success. A false result means the
        /// stream carries an error body, not events; read it with `errorText`.
        pub fn ok(stream: *const S) bool {
            return stream.status == .ok;
        }

        /// Error body text when the request failed; empty otherwise.
        pub fn errorText(stream: *const S) []const u8 {
            return stream.error_buffer[0..stream.error_length];
        }

        /// Whether a failed head carries a status worth retrying: request
        /// timeout, rate limiting, or any 5xx server fault (Anthropic's 529
        /// included).
        pub fn retryable(stream: *const S) bool {
            if (stream.status == .request_timeout or stream.status == .too_many_requests)
                return true;
            return @divFloor(@intFromEnum(stream.status), 100) == 5;
        }

        /// The `retry-after` the head asked for, in milliseconds, or null.
        pub fn retryAfterMs(stream: *const S) ?u64 {
            return stream.retry_after_ms;
        }

        /// Usage accumulated so far; complete by the provider's terminal event.
        pub fn usageSoFar(stream: *const S) llm.Usage {
            return stream.usage;
        }

        /// Run `connectFn(args)` — the provider's request builder, which must
        /// end with `finish` — bounded by the connect timeout, filling the
        /// stream in place. On expiry (or any failure) the stream is torn down
        /// and the error surfaces, so a caller that sees one owns nothing.
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
                // fully-built stream — free it here — apart from a cancelled or
                // partial connect, whose own errdefers already ran.
                if (stream.established) deinit(stream);
                return err;
            };
        }

        /// First half of a provider `connect`: the client and fresh shared
        /// state; the provider adds its own decode state and owns the
        /// errdefers between this and `finish`.
        pub fn begin(stream: *S, gpa: std.mem.Allocator, io: std.Io) void {
            stream.gpa = gpa;
            stream.client = .{ .allocator = gpa, .io = io };
            stream.frame_arena = .init(gpa);
            stream.usage = .{};
            stream.error_length = 0;
            stream.retry_after_ms = null;
        }

        /// The shared tail of a provider `connect`: send `body` over the built
        /// request, receive the head, wire the (possibly decompressing) body
        /// reader, and capture a failed head's error body. Sets `established`
        /// last, marking the stream fully built.
        pub fn finish(stream: *S, body: []const u8) !void {
            stream.request.transfer_encoding = .{ .content_length = body.len };
            var writer = try stream.request.sendBodyUnflushed(&.{});
            try writer.writer.writeAll(body);
            try writer.end();
            try stream.request.connection.?.flush();

            stream.response = try stream.request.receiveHead(&stream.redirect_buffer);
            stream.status = stream.response.head.status;
            // Read the head's headers now: creating the body reader invalidates them.
            stream.retry_after_ms = retryAfter(stream.response.head);
            stream.decompress_buffer = try net.decompressBuffer(
                stream.gpa,
                stream.response.head.content_encoding,
            );
            stream.body = stream.response.readerDecompressing(
                &stream.transfer_buffer,
                &stream.decompress,
                stream.decompress_buffer,
            );
            if (stream.status != .ok)
                stream.error_length = stream.body.readSliceShort(&stream.error_buffer) catch 0;
            stream.established = true;
        }

        /// Next decoded event, or null at end of stream. One shared `Deadline`
        /// spans the read of each event, so filler draws the window down while
        /// every recognized frame restarts it — only a genuine stall surfaces
        /// `error.Timeout`.
        pub fn next(stream: *S) !?llm.Event {
            // Reused across skipped filler lines; the event handed back borrows
            // the frame arena, not this buffer.
            var line_buffer: std.Io.Writer.Allocating = .init(stream.gpa);
            defer line_buffer.deinit();
            var deadline = net.Deadline.start(stream.io, stream.idle_ms);
            while (true) {
                // Drop the previous returned event or skipped frame before
                // reading another. Reset inside the loop so a progress flood
                // cannot retain every parse consumed by one `next` call.
                _ = stream.frame_arena.reset(.retain_capacity);
                const line = (try takeLine(stream, deadline, &line_buffer)) orelse return null;
                // Charge every line against the whole-stream budget: a peer that
                // makes frequent valid progress still hits an aggregate ceiling,
                // including an eventless-`.progress` flood that never returns.
                try stream.budget.take(line.len + 1);
                const trimmed = std.mem.trimEnd(u8, line, "\r");
                if (!std.mem.startsWith(u8, trimmed, "data:")) {
                    // Not progress; check the window explicitly so buffered
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

        /// The next SSE line: returned directly when already buffered, else
        /// read bounded by the time left in the idle window.
        fn takeLine(
            stream: *S,
            deadline: net.Deadline,
            buffer: *std.Io.Writer.Allocating,
        ) !?[]const u8 {
            if (std.mem.indexOfScalar(u8, stream.body.buffered(), '\n') != null)
                return readLine(stream, buffer);
            return deadline.call(stream.io, readLine, .{ stream, buffer });
        }

        /// Take one delimited line into the reused line buffer, mapping a
        /// canceled read to `error.Canceled` (a turn cancel, or the idle timer
        /// reaping this task). The line grows bounded by what the budget may
        /// still deliver, so an oversized frame is rejected before it is fully
        /// buffered; one `data:` line is one event — no multi-line frame is
        /// assembled — so this bounds the assembled frame too.
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
            // The delimiter, if any, is left buffered: a '\n' closes this line;
            // end of stream with nothing buffered ends the reply, and a
            // non-empty final line with no newline is a truncated frame —
            // retryable, never decoded.
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

        /// Refine a reader `ReadFailed` into `error.Canceled` when the
        /// connection recorded a canceled read, else leave it as
        /// `error.ReadFailed` for the network-error path.
        fn readFailed(stream: *S) anyerror {
            if (stream.request.connection.?.getReadError()) |read_error| {
                if (read_error == error.Canceled) return error.Canceled;
            }
            return error.ReadFailed;
        }

        /// Record a streamed error frame's message for `errorText`; called by
        /// the provider's `decode`.
        pub fn recordError(stream: *S, message: []const u8) void {
            stream.error_length = @min(message.len, stream.error_buffer.len);
            @memcpy(stream.error_buffer[0..stream.error_length], message[0..stream.error_length]);
        }
    };
}

/// Parse the `retry-after` header (whole seconds) into milliseconds; null when
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
/// returns the current tick and advances by a fixed step, driving the window
/// to expiry without real time passing. Only `now` is overridden, so callers
/// must never reach another vtable entry with this userdata — the tests feed
/// fully buffered `.fixed` readers, so `takeLine` never reaches
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

    // A huge value saturates rather than wrapping, so the backoff cap still bounds it.
    const huge = "HTTP/1.1 429 Too Many Requests\r\n" ++
        "retry-after: 99999999999999999\r\ncontent-length:0\r\n\r\n";
    try std.testing.expectEqual(
        @as(?u64, std.math.maxInt(u64)),
        retryAfter(try std.http.Client.Response.Head.parse(huge)),
    );
}

test "retryable classifies the head status" {
    const Stub = struct { status: std.http.Status };
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
    // Only a literal 5xx counts: `Status.class` maps every out-of-range status
    // to `server_error`, which must not make a nonsense status retryable.
    stream.status = @enumFromInt(999);
    try std.testing.expect(!engine.retryable(&stream));
    try std.testing.expectEqual(std.http.Status.Class.server_error, stream.status.class());
}
