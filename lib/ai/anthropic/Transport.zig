//! The Messages API transport: sends a serialized request with the OAuth
//! identity headers and exposes the response as a pull stream of decoded SSE
//! events. Knows nothing about conversation state or tools — it turns bytes
//! into `Event`s.

const std = @import("std");

const llm = @import("../llm.zig");
const net = @import("../net.zig");

const Transport = @This();

const messages_url = "https://api.anthropic.com/v1/messages";
const beta = "claude-code-20250219,oauth-2025-04-20";

/// Statuses worth retrying: rate limiting, request timeout, and the transient
/// server faults (including Anthropic's 529 "overloaded").
const retryable_statuses = [_]std.http.Status{ .request_timeout, .too_many_requests, .internal_server_error, .bad_gateway, .service_unavailable, .gateway_timeout, @enumFromInt(529) };

gpa: std.mem.Allocator,
io: std.Io,
timeouts: net.Timeouts,

/// The outcome of decoding one SSE `data:` line. A ping is called out from the
/// other frames so the idle window can discount it: only a `ping` fails to count
/// as progress, so a stream that sends nothing else still trips the timeout.
const Decoded = union(enum) {
    /// An event to hand back to the caller.
    event: llm.Event,
    /// A recognized frame with no event for the caller (usage, block
    /// boundaries) — real progress against the idle window.
    progress,
    /// A keepalive ping: ignored, and deliberately not counted as progress.
    ping,
};

/// A single Messages request in flight. Pin it: the HTTP response borrows the
/// request and the SSE reader borrows this struct's buffers.
pub const Stream = struct {
    gpa: std.mem.Allocator,
    /// Whether `connect` ran to completion, so `out` owns resources `deinit` must
    /// free. Set last by a successful connect; the timeout error path reads it to
    /// tell a fully-built stream from a cancelled or partial one.
    established: bool,
    client: std.http.Client,
    request: std.http.Client.Request,
    response: std.http.Client.Response,
    body: *std.Io.Reader,
    io: std.Io,
    idle_ms: u64,
    status: std.http.Status,
    error_length: usize,
    retry_after_ms: ?u64,
    parsed: ?std.json.Parsed(std.json.Value),
    usage: llm.Usage,
    decompress: std.http.Decompress,
    decompress_buffer: []u8,
    error_buffer: [512]u8,
    redirect_buffer: [4096]u8,
    transfer_buffer: [16384]u8,

    pub fn deinit(self: *Stream) void {
        if (self.decompress_buffer.len != 0) self.gpa.free(self.decompress_buffer);
        if (self.parsed) |parsed| parsed.deinit();
        self.request.deinit();
        self.client.deinit();
    }

    /// Whether the request head reported success. A false result means the
    /// stream carries an error body, not events; read it with `errorText`.
    pub fn ok(self: *const Stream) bool {
        return self.status == .ok;
    }

    /// Error body text when the request failed; empty otherwise.
    pub fn errorText(self: *const Stream) []const u8 {
        return self.error_buffer[0..self.error_length];
    }

    /// Whether a failed head carries a status worth retrying.
    pub fn retryable(self: *const Stream) bool {
        for (retryable_statuses) |status| {
            if (self.status == status) return true;
        }
        return false;
    }

    /// The `retry-after` the head asked for, in milliseconds, or null.
    pub fn retryAfterMs(self: *const Stream) ?u64 {
        return self.retry_after_ms;
    }

    /// Next decoded event, or null at end of stream.
    pub fn next(self: *Stream) !?llm.Event {
        if (self.parsed) |parsed| {
            parsed.deinit();
            self.parsed = null;
        }
        // One idle window spans the read of each event. Anthropic sends keepalive
        // `ping` events between real ones, so a stalled stream can keep sending
        // bytes without progress; a shared `Deadline` (rather than a fresh
        // per-read timeout) lets pings draw the window down while every other
        // frame restarts it, so only a genuine stall surfaces `error.Timeout`.
        var deadline = net.Deadline.start(self.io, self.idle_ms);
        while (true) {
            const line = (try self.takeLine(deadline)) orelse return null;
            const trimmed = std.mem.trimEnd(u8, line, "\r");
            if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
            const payload = std.mem.trimStart(u8, trimmed["data:".len..], " ");
            switch (try self.decode(payload)) {
                .event => |event| return event,
                .progress => deadline = net.Deadline.start(self.io, self.idle_ms),
                // A ping never restarts the window, so a stream that only pings
                // trips the timeout even when its bytes arrive buffered and no
                // read ever blocks on `deadline.call`.
                .ping => if (deadline.expired(self.io)) return error.Timeout,
            }
        }
    }

    /// The next SSE line. A line already buffered is returned without a timed
    /// read; a read that must wait on the socket is bounded by the time left in
    /// the idle window, so a stream that stalls — silent, or sending only
    /// keepalive pings — surfaces `error.Timeout` for the retry path.
    fn takeLine(self: *Stream, deadline: net.Deadline) !?[]const u8 {
        if (std.mem.indexOfScalar(u8, self.body.buffered(), '\n') != null) return self.readLine();
        return deadline.call(self.io, readLine, .{self});
    }

    /// Take one delimited line, mapping a canceled read to `error.Canceled`. A
    /// cancel during the read surfaces as ReadFailed; the real cause lives on the
    /// connection. Treat a canceled read as a clean abort (a turn cancel, or the
    /// idle timer reaping this task) and leave every other failure on the
    /// network-error path.
    fn readLine(self: *Stream) anyerror!?[]const u8 {
        return self.body.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => {
                if (self.request.connection.?.getReadError()) |read_error| {
                    if (read_error == error.Canceled) return error.Canceled;
                }
                return err;
            },
            else => return err,
        };
    }

    fn decode(self: *Stream, json: []const u8) !Decoded {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.gpa, json, .{});
        const object = asObject(parsed.value) orelse {
            parsed.deinit();
            return .progress;
        };
        const kind = asString(object.get("type")) orelse {
            parsed.deinit();
            return .progress;
        };

        if (std.mem.eql(u8, kind, "ping")) {
            parsed.deinit();
            return .ping;
        }
        if (std.mem.eql(u8, kind, "error")) {
            self.recordError(errorMessage(object) orelse kind);
            parsed.deinit();
            return error.ApiError;
        }

        // Usage arrives split across the stream: the prompt and cache counts in
        // `message_start`, the final output count in `message_delta`. Fold both
        // into the running total and hand it back on the stop event.
        if (std.mem.eql(u8, kind, "message_start")) {
            if (asObject(object.get("message"))) |message| {
                if (asObject(message.get("usage"))) |usage| mergeUsage(&self.usage, usage);
            }
            parsed.deinit();
            return .progress;
        }

        const event = classify(object, kind) orelse {
            parsed.deinit();
            return .progress;
        };
        switch (event) {
            .stop => |stop| {
                if (asObject(object.get("usage"))) |usage| mergeUsage(&self.usage, usage);
                self.parsed = parsed;
                return .{ .event = .{ .stop = .{ .reason = stop.reason, .usage = self.usage } } };
            },
            else => {
                self.parsed = parsed;
                return .{ .event = event };
            },
        }
    }

    fn recordError(self: *Stream, message: []const u8) void {
        self.error_length = @min(message.len, self.error_buffer.len);
        @memcpy(self.error_buffer[0..self.error_length], message[0..self.error_length]);
    }
};

/// Open a streaming Messages request, filling `out` in place. The connect,
/// send, and receive-head phase is bounded by the connect timeout; on expiry (or
/// any failure) `out` is torn down and `error.Timeout` surfaces, so a caller that
/// sees an error never owns `out`.
pub fn send(self: *Transport, out: *Stream, body: []const u8, access_token: []const u8) !void {
    out.io = self.io;
    out.idle_ms = self.timeouts.idle_ms;
    out.established = false;
    net.withTimeout(self.io, self.timeouts.connect_ms, connect, .{ self, out, body, access_token }) catch |err| {
        // The timeout races `connect`, so a connect that finished right at the
        // deadline can still surface as `error.Timeout`. `established` (set last
        // by a full connect) marks that fully-built stream — free it here — apart
        // from a cancelled or partial connect, whose own errdefers already ran.
        if (out.established) out.deinit();
        return err;
    };
}

fn connect(self: *Transport, out: *Stream, body: []const u8, access_token: []const u8) anyerror!void {
    out.gpa = self.gpa;
    out.client = .{ .allocator = self.gpa, .io = self.io };
    errdefer out.client.deinit();
    out.parsed = null;
    out.error_length = 0;
    out.retry_after_ms = null;
    out.usage = .{};

    const authorization = try std.fmt.allocPrint(self.gpa, "Bearer {s}", .{access_token});
    defer self.gpa.free(authorization);

    const uri = try std.Uri.parse(messages_url);
    out.request = try out.client.request(.POST, uri, .{
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = authorization },
            .user_agent = .{ .override = "claude-cli/2.1.75" },
            // Read the event stream uncompressed. SSE is consumed one line at
            // a time as chunks arrive, so a verbatim body keeps event delivery
            // independent of any decompressor's own buffering.
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = &.{
            .{ .name = "anthropic-version", .value = "2023-06-01" },
            .{ .name = "anthropic-beta", .value = beta },
            .{ .name = "x-app", .value = "cli" },
        },
    });
    errdefer out.request.deinit();

    // A cancel during the calls below lands before Agent.run arms its
    // `defer stream.deinit()`, so teardown falls to the errdefers above (client
    // and request); that unwinds cleanly. This corner is untested.
    out.request.transfer_encoding = .{ .content_length = body.len };
    var writer = try out.request.sendBodyUnflushed(&.{});
    try writer.writer.writeAll(body);
    try writer.end();
    try out.request.connection.?.flush();

    out.response = try out.request.receiveHead(&out.redirect_buffer);
    out.status = out.response.head.status;
    out.decompress_buffer = try decompressBuffer(self.gpa, out.response.head.content_encoding);
    out.body = out.response.readerDecompressing(&out.transfer_buffer, &out.decompress, out.decompress_buffer);
    if (out.status != .ok) {
        const read = out.body.readSliceShort(&out.error_buffer) catch 0;
        out.error_length = read;
        out.retry_after_ms = retryAfter(out.response.head);
    }
    out.established = true;
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

/// A decompression window sized for `encoding`, or an empty slice when the body
/// is not compressed. Caller frees a non-empty result.
fn decompressBuffer(gpa: std.mem.Allocator, encoding: std.http.ContentEncoding) ![]u8 {
    return switch (encoding) {
        .identity => &.{},
        .gzip, .deflate => gpa.alloc(u8, std.compress.flate.max_window_len),
        .zstd => gpa.alloc(u8, std.compress.zstd.default_window_len),
        .compress => error.UnsupportedContentEncoding,
    };
}

fn classify(object: std.json.ObjectMap, kind: []const u8) ?llm.Event {
    if (std.mem.eql(u8, kind, "content_block_delta")) {
        const delta = asObject(object.get("delta")) orelse return null;
        const delta_kind = asString(delta.get("type")) orelse return null;
        if (std.mem.eql(u8, delta_kind, "text_delta"))
            return .{ .text = asString(delta.get("text")) orelse return null };
        if (std.mem.eql(u8, delta_kind, "input_json_delta"))
            return .{ .input_json = asString(delta.get("partial_json")) orelse return null };
        if (std.mem.eql(u8, delta_kind, "thinking_delta"))
            return .{ .thinking = asString(delta.get("thinking")) orelse return null };
        if (std.mem.eql(u8, delta_kind, "signature_delta"))
            return .{ .thinking_signature = asString(delta.get("signature")) orelse return null };
        return null;
    }
    if (std.mem.eql(u8, kind, "content_block_start")) {
        const block = asObject(object.get("content_block")) orelse return null;
        const block_kind = asString(block.get("type")) orelse return null;
        if (std.mem.eql(u8, block_kind, "redacted_thinking"))
            return .{ .thinking_redacted = asString(block.get("data")) orelse return null };
        // A `thinking` start carries only empty seeds — its content arrives as
        // deltas — so it, like any other non-tool block, yields no start event.
        if (!std.mem.eql(u8, block_kind, "tool_use")) return null;
        return .{ .tool_use = .{
            .id = asString(block.get("id")) orelse return null,
            .name = asString(block.get("name")) orelse return null,
        } };
    }
    if (std.mem.eql(u8, kind, "message_delta")) {
        const delta = asObject(object.get("delta")) orelse return null;
        return .{ .stop = .{ .reason = asString(delta.get("stop_reason")), .usage = .{} } };
    }
    return null;
}

fn errorMessage(object: std.json.ObjectMap) ?[]const u8 {
    const detail = asObject(object.get("error")) orelse return null;
    return asString(detail.get("message"));
}

fn asObject(value: ?std.json.Value) ?std.json.ObjectMap {
    const found = value orelse return null;
    return switch (found) {
        .object => |object| object,
        else => null,
    };
}

fn asString(value: ?std.json.Value) ?[]const u8 {
    const found = value orelse return null;
    return switch (found) {
        .string => |string| string,
        else => null,
    };
}

fn asU64(value: ?std.json.Value) ?u64 {
    const found = value orelse return null;
    return switch (found) {
        .integer => |integer| if (integer < 0) 0 else @intCast(integer),
        else => null,
    };
}

/// Overwrite each field present in `object`. Anthropic reports usage as
/// cumulative message totals, so last-writer-per-field is the running total.
fn mergeUsage(usage: *llm.Usage, object: std.json.ObjectMap) void {
    if (asU64(object.get("input_tokens"))) |value| usage.input = value;
    if (asU64(object.get("output_tokens"))) |value| usage.output = value;
    if (asU64(object.get("cache_read_input_tokens"))) |value| usage.cache_read = value;
    if (asU64(object.get("cache_creation_input_tokens"))) |value| usage.cache_write = value;
}

test classify {
    const json =
        \\{"type":"content_block_delta","delta":{"type":"text_delta","text":"hello"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const event = classify(parsed.value.object, "content_block_delta").?;
    try std.testing.expectEqualStrings("hello", event.text);

    const start =
        \\{"type":"content_block_start","content_block":{"type":"tool_use","id":"t1","name":"read"}}
    ;
    const parsed_start = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, start, .{});
    defer parsed_start.deinit();
    const start_event = classify(parsed_start.value.object, "content_block_start").?;
    try std.testing.expectEqualStrings("read", start_event.tool_use.name);

    const thinking =
        \\{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hmm"}}
    ;
    const parsed_thinking = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, thinking, .{});
    defer parsed_thinking.deinit();
    try std.testing.expectEqualStrings("hmm", classify(parsed_thinking.value.object, "content_block_delta").?.thinking);

    const signature =
        \\{"type":"content_block_delta","delta":{"type":"signature_delta","signature":"sig"}}
    ;
    const parsed_signature = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, signature, .{});
    defer parsed_signature.deinit();
    try std.testing.expectEqualStrings("sig", classify(parsed_signature.value.object, "content_block_delta").?.thinking_signature);

    const redacted =
        \\{"type":"content_block_start","content_block":{"type":"redacted_thinking","data":"enc"}}
    ;
    const parsed_redacted = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, redacted, .{});
    defer parsed_redacted.deinit();
    try std.testing.expectEqualStrings("enc", classify(parsed_redacted.value.object, "content_block_start").?.thinking_redacted);
}

test "next walks SSE data lines and ends at stream end" {
    const body =
        "event: message_start\r\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"usage\":" ++
        "{\"input_tokens\":10,\"cache_read_input_tokens\":90,\"cache_creation_input_tokens\":5,\"output_tokens\":1}}}\r\n" ++
        "\r\n" ++
        "event: ping\r\n" ++
        "data: {\"type\":\"ping\"}\r\n" ++
        "\r\n" ++
        "event: content_block_delta\r\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}\r\n" ++
        "\r\n" ++
        "event: message_delta\r\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":42}}\r\n" ++
        "\r\n";
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var stream: Stream = undefined;
    stream.gpa = std.testing.allocator;
    stream.io = threaded.io();
    stream.idle_ms = 60_000;
    stream.body = &reader;
    stream.parsed = null;
    stream.usage = .{};
    defer if (stream.parsed) |parsed| parsed.deinit();

    const text = (try stream.next()).?;
    try std.testing.expectEqualStrings("Hi", text.text);
    const stop = (try stream.next()).?;
    try std.testing.expectEqualStrings("end_turn", stop.stop.reason.?);
    try std.testing.expectEqual(@as(u64, 10), stop.stop.usage.input);
    try std.testing.expectEqual(@as(u64, 42), stop.stop.usage.output);
    try std.testing.expectEqual(@as(u64, 90), stop.stop.usage.cache_read);
    try std.testing.expectEqual(@as(u64, 5), stop.stop.usage.cache_write);
    try std.testing.expectEqual(@as(?llm.Event, null), try stream.next());
}

test "decode separates pings from progress and events" {
    var stream: Stream = undefined;
    stream.gpa = std.testing.allocator;
    stream.parsed = null;
    stream.usage = .{};
    defer if (stream.parsed) |parsed| parsed.deinit();

    try std.testing.expectEqual(@as(Decoded, .ping), try stream.decode(
        \\{"type":"ping"}
    ));
    try std.testing.expectEqual(@as(Decoded, .progress), try stream.decode(
        \\{"type":"message_start","message":{"usage":{"input_tokens":3}}}
    ));
    try std.testing.expectEqual(@as(u64, 3), stream.usage.input);
    const delta = try stream.decode(
        \\{"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}
    );
    try std.testing.expectEqualStrings("hi", delta.event.text);
}

test retryAfter {
    const with = "HTTP/1.1 429 Too Many Requests\r\nretry-after: 7\r\ncontent-length:0\r\n\r\n";
    const head = try std.http.Client.Response.Head.parse(with);
    try std.testing.expectEqual(@as(?u64, 7000), retryAfter(head));

    const without = "HTTP/1.1 503 Service Unavailable\r\ncontent-length:0\r\n\r\n";
    try std.testing.expectEqual(@as(?u64, null), retryAfter(try std.http.Client.Response.Head.parse(without)));
}

test "retryable classifies the head status" {
    var stream: Stream = undefined;
    stream.status = .too_many_requests;
    try std.testing.expect(stream.retryable());
    stream.status = @enumFromInt(529);
    try std.testing.expect(stream.retryable());
    stream.status = .ok;
    try std.testing.expect(!stream.retryable());
    stream.status = .bad_request;
    try std.testing.expect(!stream.retryable());
}
