//! The Messages API transport: sends a serialized request and exposes the
//! response as a pull stream of decoded SSE events on the shared `sse` engine.
//! Knows nothing about conversation state or tools — it turns bytes into
//! `Event`s; the request identity forks by `Identity`.

const std = @import("std");

const json = @import("../json.zig");
const llm = @import("../llm.zig");
const net = @import("../net.zig");
const sse = @import("../sse.zig");

const Transport = @This();

const messages_url = "https://api.anthropic.com/v1/messages";
const anthropic_version = "2023-06-01";
const beta = "claude-code-20250219,oauth-2025-04-20";
const user_agent = "claude-cli/2.1.75";

/// How a request authenticates and identifies itself: subscription OAuth sends
/// a `Bearer` access token plus the Claude Code identity headers
/// (`anthropic-beta`, the `claude-cli` user agent, `x-app`); the API key sends
/// only `x-api-key`.
pub const Identity = union(enum) {
    subscription: []const u8,
    api_key: []const u8,
};

gpa: std.mem.Allocator,
io: std.Io,
timeouts: net.Timeouts,
identity: Identity,

/// A single Messages request in flight on the shared SSE engine, which supplies
/// the reading half; this struct keeps the Messages frame vocabulary (`decode`)
/// and its state. Pin it: the HTTP response borrows the request and the SSE
/// reader borrows this struct's buffers.
pub const Stream = struct {
    gpa: std.mem.Allocator,
    /// Set last by a full connect; `sse.Engine.open`'s timeout path frees only
    /// an established stream.
    established: bool,
    client: std.http.Client,
    request: std.http.Client.Request,
    response: std.http.Client.Response,
    body: *std.Io.Reader,
    io: std.Io,
    idle_ms: u64,
    budget: net.Budget,
    status: std.http.Status,
    error_length: usize,
    retry_after_ms: ?u64,
    /// Backs the event handed to the caller; freed by the next read.
    parsed: ?std.json.Parsed(std.json.Value),
    /// A `message_delta` carrying a stop reason arrived; only then may the
    /// following `message_stop` close the reply.
    terminal: bool,
    usage: llm.Usage,
    decompress: std.http.Decompress,
    decompress_buffer: []u8,
    error_buffer: [512]u8,
    redirect_buffer: [4096]u8,
    transfer_buffer: [16384]u8,

    const engine = sse.Engine(Stream);
    pub const deinit = engine.deinit;
    pub const ok = engine.ok;
    pub const errorText = engine.errorText;
    pub const retryable = engine.retryable;
    pub const retryAfterMs = engine.retryAfterMs;
    /// Usage accumulated so far. Anthropic splits it across the stream (prompt
    /// and cache counts in `message_start`, output in `message_delta`), so this
    /// grows as those frames arrive and is complete by the final `message_stop`.
    pub const usageSoFar = engine.usageSoFar;
    pub const next = engine.next;

    /// Drop the parses backing the previous event; the engine calls this
    /// before each read and on deinit.
    pub fn reset(self: *Stream) void {
        if (self.parsed) |parsed| parsed.deinit();
        self.parsed = null;
    }

    /// Decode one Messages `data:` payload; a keepalive `ping` is filler.
    pub fn decode(self: *Stream, payload: []const u8) !sse.Decoded {
        // A malformed payload is filler, not progress; a truncated tail then
        // surfaces as an incomplete reply at end of stream, which is retried.
        const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, payload, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .ignored,
        };
        const object = json.object(parsed.value) orelse {
            parsed.deinit();
            return .ignored;
        };
        const kind = json.string(object.get("type")) orelse {
            parsed.deinit();
            return .ignored;
        };

        if (std.mem.eql(u8, kind, "ping")) {
            parsed.deinit();
            return .ignored;
        }
        if (std.mem.eql(u8, kind, "error")) {
            engine.recordError(self, errorMessage(object) orelse kind);
            parsed.deinit();
            return error.ApiError;
        }

        if (std.mem.eql(u8, kind, "message_delta")) {
            if (json.object(object.get("usage"))) |usage| mergeUsage(&self.usage, usage);
            self.terminal = messageDeltaStopReason(object) != null;
            parsed.deinit();
            return .progress;
        }
        if (std.mem.eql(u8, kind, "message_stop")) {
            parsed.deinit();
            if (!self.terminal) return error.IncompleteReply;
            return .{ .event = .{ .stop = .{ .usage = self.usage } } };
        }
        // Only recognized content past the terminal delta breaks the reply;
        // an unrecognized frame there is still ignored filler.
        const content = std.mem.eql(u8, kind, "message_start") or
            std.mem.startsWith(u8, kind, "content_block_");
        if (content and self.terminal) {
            self.terminal = false;
            parsed.deinit();
            return error.IncompleteReply;
        }
        if (std.mem.eql(u8, kind, "message_start")) {
            if (json.object(object.get("message"))) |message| {
                if (json.object(message.get("usage"))) |usage| mergeUsage(&self.usage, usage);
            }
            parsed.deinit();
            return .progress;
        }

        if (classify(object, kind)) |event| {
            self.parsed = parsed;
            return .{ .event = event };
        }
        // A recognized `content_block_*` frame with no event is still progress;
        // any other `type` is filler. Read `kind` (which borrows `parsed`)
        // before freeing it.
        const recognized = std.mem.startsWith(u8, kind, "content_block_");
        parsed.deinit();
        return if (recognized) .progress else .ignored;
    }
};

/// Open a streaming Messages request bounded by the connect timeout; on any
/// failure `out` is torn down, so a caller that sees an error owns nothing
/// (see `sse.Engine.open`).
pub fn send(self: *Transport, out: *Stream, body: []const u8) !void {
    return sse.Engine(Stream).open(out, self.io, self.timeouts, connect, .{ self, out, body });
}

fn connect(self: *Transport, out: *Stream, body: []const u8) anyerror!void {
    const engine = sse.Engine(Stream);
    engine.begin(out, self.gpa, self.io);
    errdefer out.client.deinit();
    out.terminal = false;

    // The Bearer header must outlive the send below, so allocate it at connect
    // scope; the API-key path needs none.
    const authorization: ?[]u8 = switch (self.identity) {
        .subscription => |token| try std.fmt.allocPrint(self.gpa, "Bearer {s}", .{token}),
        .api_key => null,
    };
    defer if (authorization) |value| self.gpa.free(value);

    const uri = try std.Uri.parse(messages_url);
    var extra: [3]std.http.Header = undefined;
    out.request = try out.client.request(.POST, uri, requestOptions(self.identity, authorization, &extra));
    errdefer out.request.deinit();

    // A cancel during `finish` lands before Agent.run arms its deinit, so
    // teardown falls to the errdefers above. This corner is untested.
    try engine.finish(out, body);
}

/// The built request's `Identity` fork. Both paths request an unencoded
/// response, keeping event delivery independent of any decompressor's own
/// buffering. `extra` backs the returned options and must outlive the send.
fn requestOptions(
    identity: Identity,
    authorization: ?[]const u8,
    extra: *[3]std.http.Header,
) std.http.Client.RequestOptions {
    switch (identity) {
        .subscription => {
            extra.* = .{
                .{ .name = "anthropic-version", .value = anthropic_version },
                .{ .name = "anthropic-beta", .value = beta },
                .{ .name = "x-app", .value = "cli" },
            };
            return .{
                .headers = .{
                    .content_type = .{ .override = "application/json" },
                    .authorization = .{ .override = authorization.? },
                    .user_agent = .{ .override = user_agent },
                    .accept_encoding = .{ .override = "identity" },
                },
                .extra_headers = extra,
            };
        },
        .api_key => |key| {
            extra[0] = .{ .name = "x-api-key", .value = key };
            extra[1] = .{ .name = "anthropic-version", .value = anthropic_version };
            return .{
                .headers = .{
                    .content_type = .{ .override = "application/json" },
                    .accept_encoding = .{ .override = "identity" },
                },
                .extra_headers = extra[0..2],
            };
        },
    }
}

fn classify(object: std.json.ObjectMap, kind: []const u8) ?llm.Event {
    if (std.mem.eql(u8, kind, "content_block_delta")) {
        const delta = json.object(object.get("delta")) orelse return null;
        const delta_kind = json.string(delta.get("type")) orelse return null;
        if (std.mem.eql(u8, delta_kind, "text_delta"))
            return .{ .text = json.string(delta.get("text")) orelse return null };
        if (std.mem.eql(u8, delta_kind, "input_json_delta"))
            return .{ .input_json = json.string(delta.get("partial_json")) orelse return null };
        if (std.mem.eql(u8, delta_kind, "thinking_delta"))
            return .{ .thinking = .{ .text = json.string(delta.get("thinking")) orelse return null } };
        if (std.mem.eql(u8, delta_kind, "signature_delta"))
            return .{ .thinking_blob = .{ .blob = json.string(delta.get("signature")) orelse return null } };
        return null;
    }
    if (std.mem.eql(u8, kind, "content_block_start")) {
        const block = json.object(object.get("content_block")) orelse return null;
        const block_kind = json.string(block.get("type")) orelse return null;
        if (std.mem.eql(u8, block_kind, "redacted_thinking"))
            return .{ .thinking_redacted = .{ .blob = json.string(block.get("data")) orelse return null } };
        // A `thinking` start carries only empty seeds — its content arrives as
        // deltas — so it, like any other non-tool block, yields no start event.
        if (!std.mem.eql(u8, block_kind, "tool_use")) return null;
        return .{ .tool_use = .{
            .call_id = json.string(block.get("id")) orelse return null,
            .name = json.string(block.get("name")) orelse return null,
        } };
    }
    return null;
}

fn messageDeltaStopReason(object: std.json.ObjectMap) ?[]const u8 {
    const delta = json.object(object.get("delta")) orelse return null;
    return json.string(delta.get("stop_reason"));
}

fn errorMessage(object: std.json.ObjectMap) ?[]const u8 {
    const detail = json.object(object.get("error")) orelse return null;
    return json.string(detail.get("message"));
}

/// Overwrite each field present in `object`. Anthropic reports usage as
/// cumulative message totals, so last-writer-per-field is the running total.
fn mergeUsage(usage: *llm.Usage, object: std.json.ObjectMap) void {
    if (json.unsigned(object.get("input_tokens"))) |value| usage.input = value;
    if (json.unsigned(object.get("output_tokens"))) |value| usage.output = value;
    if (json.unsigned(object.get("cache_read_input_tokens"))) |value| usage.cache_read = value;
    if (json.unsigned(object.get("cache_creation_input_tokens"))) |value| usage.cache_write = value;
}

/// A stream over `body` for the tests: test allocator, fresh decode state, and
/// the given window and budget; the connection fields stay undefined. Pair with
/// `defer stream.reset()` to free whatever decoding retains.
fn testStream(io: std.Io, body: *std.Io.Reader, idle_ms: u64, budget_max: usize) Stream {
    var stream: Stream = undefined;
    stream.gpa = std.testing.allocator;
    stream.io = io;
    stream.idle_ms = idle_ms;
    stream.budget = .{ .max = budget_max };
    stream.body = body;
    stream.parsed = null;
    stream.terminal = false;
    stream.usage = .{};
    return stream;
}

test classify {
    const payload =
        \\{"type":"content_block_delta","delta":{"type":"text_delta","text":"hello"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
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
    try std.testing.expectEqualStrings("hmm", classify(parsed_thinking.value.object, "content_block_delta").?.thinking.text);

    const signature =
        \\{"type":"content_block_delta","delta":{"type":"signature_delta","signature":"sig"}}
    ;
    const parsed_signature = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, signature, .{});
    defer parsed_signature.deinit();
    try std.testing.expectEqualStrings("sig", classify(parsed_signature.value.object, "content_block_delta").?.thinking_blob.blob);

    const redacted =
        \\{"type":"content_block_start","content_block":{"type":"redacted_thinking","data":"enc"}}
    ;
    const parsed_redacted = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, redacted, .{});
    defer parsed_redacted.deinit();
    try std.testing.expectEqualStrings("enc", classify(parsed_redacted.value.object, "content_block_start").?.thinking_redacted.blob);
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
        "\r\n" ++
        "event: message_stop\r\n" ++
        "data: {\"type\":\"message_stop\"}\r\n" ++
        "\r\n";
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var stream = testStream(threaded.io(), &reader, 60_000, net.stream_response_bytes_max);
    defer stream.reset();

    const text = (try stream.next()).?;
    try std.testing.expectEqualStrings("Hi", text.text);
    const stop = (try stream.next()).?;
    try std.testing.expectEqual(@as(u64, 10), stop.stop.usage.input);
    try std.testing.expectEqual(@as(u64, 42), stop.stop.usage.output);
    try std.testing.expectEqual(@as(u64, 90), stop.stop.usage.cache_read);
    try std.testing.expectEqual(@as(u64, 5), stop.stop.usage.cache_write);
    try std.testing.expectEqual(@as(u64, 10), stream.usageSoFar().input);
    try std.testing.expectEqual(@as(u64, 42), stream.usageSoFar().output);
    try std.testing.expectEqual(@as(?llm.Event, null), try stream.next());
}

test "decode separates pings from progress and events" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.reset();

    try std.testing.expectEqual(@as(sse.Decoded, .ignored), try stream.decode(
        \\{"type":"ping"}
    ));
    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"message_start","message":{"usage":{"input_tokens":3}}}
    ));
    try std.testing.expectEqual(@as(u64, 3), stream.usage.input);
    const delta = try stream.decode(
        \\{"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}
    );
    try std.testing.expectEqualStrings("hi", delta.event.text);
}

test "message_stop requires a final delta with a stop reason" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.reset();

    try std.testing.expectError(error.IncompleteReply, stream.decode(
        \\{"type":"message_stop"}
    ));
    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"message_delta","delta":{"stop_reason":null},"usage":{"output_tokens":1}}
    ));
    try std.testing.expectError(error.IncompleteReply, stream.decode(
        \\{"type":"message_stop"}
    ));

    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}
    ));
    try std.testing.expectError(error.IncompleteReply, stream.decode(
        \\{"type":"content_block_delta","delta":{"type":"text_delta","text":"late"}}
    ));
    try std.testing.expect(!stream.terminal);

    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}
    ));
    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":4}}
    ));
    const stop = try stream.decode(
        \\{"type":"message_stop"}
    );
    try std.testing.expectEqual(@as(u64, 4), stop.event.stop.usage.output);
}

test "an unrecognized frame after the terminal delta stays ignored" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.reset();

    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}
    ));
    // Filler here must not turn a complete reply into an incomplete one.
    try std.testing.expectEqual(@as(sse.Decoded, .ignored), try stream.decode(
        \\{"type":"surprise_new_event"}
    ));
    const stop = try stream.decode(
        \\{"type":"message_stop"}
    );
    try std.testing.expect(stop.event == .stop);
}

test "decode ignores unrecognized frames instead of counting them as progress" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.reset();

    try std.testing.expectEqual(@as(sse.Decoded, .ignored), try stream.decode(
        \\{"type":"surprise_new_event"}
    ));
    try std.testing.expectEqual(@as(sse.Decoded, .ignored), try stream.decode(
        \\{"note":"no type here"}
    ));
    try std.testing.expectEqual(@as(sse.Decoded, .ignored), try stream.decode(
        \\42
    ));
    // A recognized block boundary that carries no event is still progress.
    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"content_block_stop","index":0}
    ));
}

test "decode ignores a malformed data line instead of failing the turn" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.reset();

    try std.testing.expectEqual(@as(sse.Decoded, .ignored), try stream.decode(
        \\{"type":"content_block_delta","del
    ));
    try std.testing.expectEqual(@as(sse.Decoded, .ignored), try stream.decode(
        \\not json at all
    ));
}

test "decode surfaces a streamed error frame" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.reset();

    try std.testing.expectError(error.ApiError, stream.decode(
        \\{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}
    ));
    try std.testing.expectEqualStrings("Overloaded", stream.errorText());

    // A frame without a message falls back to reporting its kind.
    try std.testing.expectError(error.ApiError, stream.decode(
        \\{"type":"error","error":{}}
    ));
    try std.testing.expectEqualStrings("error", stream.errorText());

    // A message longer than the error buffer is truncated, never out of bounds.
    const long = "x" ** 600;
    try std.testing.expectError(error.ApiError, stream.decode(
        "{\"type\":\"error\",\"error\":{\"message\":\"" ++ long ++ "\"}}",
    ));
    try std.testing.expectEqualStrings(long[0..stream.error_buffer.len], stream.errorText());
}

test "next times out on buffered filler that makes no progress" {
    // Only filler: the idle window must trip even though every line is
    // buffered and no read ever blocks on the deadline.
    const body =
        ": keepalive comment\n" ++
        "data: {\"type\":\"surprise_new_event\"}\n" ++
        "data: {\"type\":\"surprise_new_event\"}\n" ++
        "data: {\"type\":\"surprise_new_event\"}\n" ++
        "data: {\"type\":\"surprise_new_event\"}\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"late\"}}\n";
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var clock: sse.TickingIo = .init(threaded.io(), 40 * std.time.ns_per_ms);
    var reader: std.Io.Reader = .fixed(body);
    var stream = testStream(clock.io(), &reader, 100, net.stream_response_bytes_max);
    defer stream.reset();

    // The 100 ms window loses 40 ms per reading, so it closes after a few
    // filler lines — before the trailing real event or EOF.
    try std.testing.expectError(error.Timeout, stream.next());
}

test "next stops a stream once its aggregate byte budget is spent" {
    // Each frame is real progress that restarts the idle window, so only the
    // aggregate byte budget ends the flood. It spans two frames, tripping on
    // their sum rather than any single line.
    const frame =
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"chunk\"}}\n";
    const body = frame ** 5;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var stream = testStream(threaded.io(), &reader, 60_000, frame.len * 2);
    defer stream.reset();

    try std.testing.expectEqualStrings("chunk", (try stream.next()).?.text);
    try std.testing.expectEqualStrings("chunk", (try stream.next()).?.text);
    try std.testing.expectError(error.StreamResponseTooLarge, stream.next());
}

test "next bounds a flood of eventless progress frames" {
    // Every frame is `.progress`, so `next` loops without returning an event;
    // the aggregate budget must still stop the flood — which an Agent-level
    // counter, fed only returned events, could not.
    const frame = "data: {\"type\":\"content_block_stop\",\"index\":0}\n";
    const body = frame ** 100;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var stream = testStream(threaded.io(), &reader, 60_000, frame.len * 3);
    defer stream.reset();

    try std.testing.expectError(error.StreamResponseTooLarge, stream.next());
}

test "next reads a data frame larger than the reader buffer" {
    // Production reads through a 16 KiB `transfer_buffer`, so a longer line
    // must stream into the growable line buffer; the chunked reader serves at
    // most 64 bytes per fill, so one line spans several fills.
    const text = "A" ** 4000;
    const body = "data: {\"type\":\"content_block_delta\",\"delta\":" ++
        "{\"type\":\"text_delta\",\"text\":\"" ++ text ++ "\"}}\n";
    var buffer: [256]u8 = undefined;
    var chunked: std.testing.Reader = .init(&buffer, &.{.{ .buffer = body }});
    chunked.artificial_limit = .limited(64);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var stream = testStream(threaded.io(), &chunked.interface, 60_000, net.stream_response_bytes_max);
    defer stream.reset();

    try std.testing.expectEqualStrings(text, (try stream.next()).?.text);
    try std.testing.expect((try stream.next()) == null);
}

test "next rejects a single frame larger than the stream budget" {
    // One frame exceeds the whole budget, so its own read trips the ceiling
    // before the frame is buffered — the per-frame bound.
    const body = "data: {\"type\":\"content_block_delta\",\"delta\":" ++
        "{\"type\":\"text_delta\",\"text\":\"chunk\"}}\n";
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var stream = testStream(threaded.io(), &reader, 60_000, 32);
    defer stream.reset();

    try std.testing.expectError(error.StreamResponseTooLarge, stream.next());
}

test "next surfaces a stream truncated mid data-line as a retryable premature end" {
    // A truncated final line must never be decoded as a frame.
    const body = "data: {\"type\":\"content_block";
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var stream = testStream(threaded.io(), &reader, 60_000, net.stream_response_bytes_max);
    defer stream.reset();

    try std.testing.expectError(error.IncompleteReply, stream.next());
}

fn failedRead(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
    _ = reader;
    _ = writer;
    _ = limit;
    return error.ReadFailed;
}

test "a canceled read surfaces as a clean abort, not a network error" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var buffer: [16]u8 = undefined;
    var reader: std.Io.Reader = .{
        .vtable = &.{ .stream = failedRead },
        .buffer = &buffer,
        .seek = 0,
        .end = 0,
    };
    // The connection's recorded read error decides: cancel refines to a clean
    // abort, anything else stays on the network-error path.
    var connection: std.http.Client.Connection = undefined;
    connection.protocol = .plain;
    connection.stream_reader.err = error.Canceled;
    var stream = testStream(threaded.io(), &reader, 60_000, net.stream_response_bytes_max);
    stream.request.connection = &connection;

    try std.testing.expectError(error.Canceled, stream.next());
    connection.stream_reader.err = error.ConnectionResetByPeer;
    try std.testing.expectError(error.ReadFailed, stream.next());
}

test "send leaves the caller owning nothing when connect fails partway" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    // Connect's first allocation fails after the client is set up: the error
    // surfaces with `established` still false, so `send` frees nothing the
    // connect errdefers already unwound.
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    var transport: Transport = .{
        .gpa = failing.allocator(),
        .io = threaded.io(),
        .timeouts = .{},
        .identity = .{ .subscription = "token" },
    };
    var stream: Stream = undefined;
    try std.testing.expectError(error.OutOfMemory, transport.send(&stream, "{}"));
    try std.testing.expect(!stream.established);
}

test "requestOptions forks the identity headers by account" {
    var extra: [3]std.http.Header = undefined;
    const subscription = requestOptions(.{ .subscription = "tok" }, "Bearer tok", &extra);
    try std.testing.expectEqualStrings("Bearer tok", subscription.headers.authorization.override);
    try std.testing.expectEqualStrings(user_agent, subscription.headers.user_agent.override);
    try std.testing.expectEqualStrings("identity", subscription.headers.accept_encoding.override);
    try std.testing.expectEqual(@as(usize, 3), subscription.extra_headers.len);
    try std.testing.expectEqualStrings("anthropic-beta", subscription.extra_headers[1].name);
    try std.testing.expectEqualStrings(beta, subscription.extra_headers[1].value);
    try std.testing.expectEqualStrings("x-app", subscription.extra_headers[2].name);

    const keyed = requestOptions(.{ .api_key = "sk-key" }, null, &extra);
    try std.testing.expect(keyed.headers.authorization == .default);
    try std.testing.expect(keyed.headers.user_agent == .default);
    try std.testing.expectEqualStrings("identity", keyed.headers.accept_encoding.override);
    try std.testing.expectEqual(@as(usize, 2), keyed.extra_headers.len);
    try std.testing.expectEqualStrings("x-api-key", keyed.extra_headers[0].name);
    try std.testing.expectEqualStrings("sk-key", keyed.extra_headers[0].value);
    try std.testing.expectEqualStrings("anthropic-version", keyed.extra_headers[1].name);
}
