//! The provider-shared SSE pull-stream engine: the Deadline+Budget-bounded
//! line reader, the `data:`-prefix frame filter whose filler draws the idle
//! window down, retryable-status classification, the `retry-after` parse, and
//! the connect tail every provider request shares. `Engine` generates the
//! methods over a provider's own stream struct — its frame vocabulary
//! (`decode`), request building, and identity stay provider-side, and
//! `provider.zig` unions the stream types.

const std = @import("std");

const llm = @import("llm.zig");
const net = @import("net.zig");

/// The outcome of decoding one SSE `data:` line. Only a recognized frame is
/// progress against the idle window, so a stream of only filler still trips
/// the timeout.
pub const Decoded = union(enum) {
    /// An event to hand back to the caller.
    event: llm.Event,
    /// A recognized frame with no event for the caller (usage, block
    /// boundaries) — real progress against the idle window.
    progress,
    /// Filler (a keepalive ping, or a frame the protocol does not define):
    /// ignored, and never counted as progress, so filler cannot hold the idle
    /// window open.
    ignored,
    /// A sentinel that ends the byte stream (OpenAI's `[DONE]`).
    done,
};

/// The engine methods over a provider stream struct `S`, which declares the
/// connection fields these methods use (`gpa`, `established`, `client`,
/// `request`, `response`, `body`, `io`, `idle_ms`, `budget`, `status`,
/// `error_length`, `retry_after_ms`, `parsed`, `usage`, `decompress`,
/// `decompress_buffer`, `error_buffer`, `redirect_buffer`, `transfer_buffer`)
/// plus `reset()` freeing its retained parses and `decode(payload) !Decoded`.
pub fn Engine(comptime S: type) type {
    return struct {
        pub fn deinit(stream: *S) void {
            stream.reset();
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
            if (stream.status == .request_timeout or stream.status == .too_many_requests) return true;
            return @intFromEnum(stream.status) / 100 == 5;
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
            stream.parsed = null;
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
            stream.decompress_buffer = try net.decompressBuffer(stream.gpa, stream.response.head.content_encoding);
            stream.body = stream.response.readerDecompressing(&stream.transfer_buffer, &stream.decompress, stream.decompress_buffer);
            if (stream.status != .ok)
                stream.error_length = stream.body.readSliceShort(&stream.error_buffer) catch 0;
            stream.established = true;
        }

        /// Next decoded event, or null at end of stream.
        pub fn next(stream: *S) !?llm.Event {
            // Drop the parses backing the previous event before reading on.
            stream.reset();
            // One growable buffer holds the current line, reused across the
            // filler lines this call skips and freed when it returns; the event
            // handed back borrows `parsed`, not this buffer.
            var line_buffer: std.Io.Writer.Allocating = .init(stream.gpa);
            defer line_buffer.deinit();
            // One idle window spans the read of each event. A shared `Deadline`
            // (rather than a fresh per-read timeout) lets keepalive pings and
            // other filler draw the window down while every recognized frame
            // restarts it, so only a genuine stall surfaces `error.Timeout`.
            var deadline = net.Deadline.start(stream.io, stream.idle_ms);
            while (true) {
                const line = (try takeLine(stream, deadline, &line_buffer)) orelse return null;
                // Charge every line against the whole-stream budget, so a peer
                // that makes frequent valid progress (each frame restarting the
                // idle window) still hits an aggregate ceiling. Counting here,
                // after a clean read, also bounds an eventless-`.progress`
                // flood that never returns an event to the caller.
                try stream.budget.take(line.len + 1);
                const trimmed = std.mem.trimEnd(u8, line, "\r");
                if (!std.mem.startsWith(u8, trimmed, "data:")) {
                    // A non-`data:` line (comment, `event:` field, blank) is
                    // not progress; check the window so buffered filler that
                    // never blocks a read cannot spin here forever.
                    if (deadline.expired(stream.io)) return error.Timeout;
                    continue;
                }
                const payload = std.mem.trimStart(u8, trimmed["data:".len..], " ");
                switch (try stream.decode(payload)) {
                    .event => |event| return event,
                    .progress => deadline = net.Deadline.start(stream.io, stream.idle_ms),
                    // Filler never restarts the window, so a stream of only
                    // filler trips the timeout even when its bytes arrive
                    // buffered and no read ever blocks on `deadline.call`.
                    .ignored => if (deadline.expired(stream.io)) return error.Timeout,
                    .done => return null,
                }
            }
        }

        /// The next SSE line. A line already buffered is returned without a
        /// timed read; a read that must wait on the socket is bounded by the
        /// time left in the idle window, so a stalled stream surfaces
        /// `error.Timeout` for the retry path.
        fn takeLine(stream: *S, deadline: net.Deadline, buffer: *std.Io.Writer.Allocating) !?[]const u8 {
            if (std.mem.indexOfScalar(u8, stream.body.buffered(), '\n') != null) return readLine(stream, buffer);
            return deadline.call(stream.io, readLine, .{ stream, buffer });
        }

        /// Take one delimited line into the reused line buffer, mapping a
        /// canceled read to `error.Canceled` (a turn cancel, or the idle timer
        /// reaping this task) and leaving every other failure on the
        /// network-error path. The line streams into a growable buffer bounded
        /// by what the whole-stream budget may still deliver, so a single frame
        /// larger than that is rejected before it is fully buffered rather than
        /// after. One `data:` line is one event — no multi-line frame is
        /// assembled — so this bounds the assembled frame too.
        fn readLine(stream: *S, buffer: *std.Io.Writer.Allocating) anyerror!?[]const u8 {
            buffer.clearRetainingCapacity();
            // A spent budget makes the read below fail `StreamResponseTooLarge`
            // before it can reach end of stream — the right verdict at the ceiling.
            const cap: std.Io.Limit = .limited(stream.budget.remaining());
            _ = stream.body.streamDelimiterLimit(&buffer.writer, '\n', cap) catch |err| switch (err) {
                error.StreamTooLong => return error.StreamResponseTooLarge,
                error.WriteFailed => return error.OutOfMemory,
                error.ReadFailed => return readFailed(stream),
            };
            // The delimiter, if any, is left buffered: a '\n' closes this line;
            // end of stream with nothing buffered ends the reply, and a
            // non-empty final line with no newline is a truncated frame —
            // retryable, never decoded.
            const pending = stream.body.peekByte() catch |err| switch (err) {
                error.EndOfStream => return if (buffer.written().len == 0) null else error.IncompleteReply,
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
        const seconds = std.fmt.parseInt(u64, std.mem.trim(u8, header.value, " \t"), 10) catch return null;
        return seconds *| 1000;
    }
    return null;
}

/// A logical clock over a real backend, for the transports' idle-window tests:
/// `now` returns the current tick and then advances by a fixed step, so a
/// bounded run of non-progress reads drives the idle window to expiry
/// deterministically without real time passing. Only `now` is overridden, so
/// the callers must never reach another vtable entry with this wrapper's
/// userdata: the tests feed a fully buffered `.fixed` reader whose lines are
/// always available, so `takeLine` returns them directly and never reaches
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
    try std.testing.expectEqual(@as(?u64, null), retryAfter(try std.http.Client.Response.Head.parse(without)));

    // An HTTP-date form is unsupported and falls back to the computed backoff.
    const dated = "HTTP/1.1 503 Service Unavailable\r\nretry-after: Wed, 21 Oct 2015 07:28:00 GMT\r\ncontent-length:0\r\n\r\n";
    try std.testing.expectEqual(@as(?u64, null), retryAfter(try std.http.Client.Response.Head.parse(dated)));

    // A huge value saturates rather than wrapping, so the backoff cap still bounds it.
    const huge = "HTTP/1.1 429 Too Many Requests\r\nretry-after: 99999999999999999\r\ncontent-length:0\r\n\r\n";
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), retryAfter(try std.http.Client.Response.Head.parse(huge)));
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
