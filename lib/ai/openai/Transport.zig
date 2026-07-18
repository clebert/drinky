//! The Responses API transport: sends a serialized request to a configured
//! endpoint with the right auth identity, and exposes the response as a pull
//! stream of decoded SSE `response.*` events on the shared `sse` engine.
//! Shared by the API-key and ChatGPT-subscription providers, which differ only
//! in `endpoint` and whether `account_id` is set. Knows nothing about
//! conversation state or tools.

const std = @import("std");

const llm = @import("../llm.zig");
const net = @import("../net.zig");
const sse = @import("../sse.zig");

const Transport = @This();

/// Header value identifying this client on the ChatGPT-subscription backend.
const originator = "pith";

gpa: std.mem.Allocator,
io: std.Io,
timeouts: net.Timeouts,
/// Full request URL: `https://api.openai.com/v1/responses` for API-key mode, the
/// Codex backend for subscription mode.
endpoint: []const u8,
/// ChatGPT account id sent as `chatgpt-account-id`; empty in API-key mode, where
/// no account or originator header is sent.
account_id: []const u8,

/// A single Responses request in flight on the shared SSE engine, which
/// supplies the reading half; this struct keeps the Responses frame vocabulary
/// (`decode`). Responses sends no keepalive pings; only `response.*` frames are
/// progress. Pin it: the HTTP response borrows the request and the SSE reader
/// borrows this struct's buffers.
pub const Stream = struct {
    gpa: std.mem.Allocator,
    /// Whether `connect` ran to completion, so this stream owns resources
    /// `deinit` must free. Set last by a successful connect; the timeout error
    /// path reads it.
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
    usage: llm.Usage,
    decompress: std.http.Decompress,
    decompress_buffer: []u8,
    /// Backing store for the request's runtime headers; the request keeps a slice
    /// of it, so it must outlive the send phase (hence a stream field, not a
    /// `connect` local).
    header_buffer: [3]std.http.Header,
    error_buffer: [512]u8,
    redirect_buffer: [4096]u8,
    transfer_buffer: [16384]u8,

    const engine = sse.Engine(Stream);
    pub const deinit = engine.deinit;
    pub const ok = engine.ok;
    pub const errorText = engine.errorText;
    pub const retryable = engine.retryable;
    pub const retryAfterMs = engine.retryAfterMs;
    /// Usage accumulated so far. Responses may deliver full counts on a
    /// terminal response event, so this is zero until then or when omitted.
    pub const usageSoFar = engine.usageSoFar;
    pub const next = engine.next;

    /// Drop the parse backing the previous event; the engine calls this before
    /// each read and on deinit.
    pub fn reset(self: *Stream) void {
        if (self.parsed) |parsed| parsed.deinit();
        self.parsed = null;
    }

    /// Decode one Responses `data:` payload.
    pub fn decode(self: *Stream, json: []const u8) !sse.Decoded {
        // Some deployments close the stream with a Chat-Completions-style
        // sentinel. It ends the byte stream; the Agent separately requires a
        // preceding Responses terminal event before committing the reply.
        if (std.mem.eql(u8, json, "[DONE]")) return .done;
        const parsed = try std.json.parseFromSlice(std.json.Value, self.gpa, json, .{});
        const object = asObject(parsed.value) orelse {
            parsed.deinit();
            return .ignored;
        };
        const kind = asString(object.get("type")) orelse {
            parsed.deinit();
            return .ignored;
        };

        if (std.mem.eql(u8, kind, "error") or std.mem.eql(u8, kind, "response.failed")) {
            engine.recordError(self, errorMessage(object) orelse kind);
            parsed.deinit();
            return error.ApiError;
        }

        const event = classify(object, kind) orelse {
            // A recognized `response.*` frame that surfaces no event is progress;
            // any other `type` is filler that must not hold the idle window open.
            // Read `kind` (which borrows `parsed`) before freeing it.
            const recognized = std.mem.startsWith(u8, kind, "response.");
            parsed.deinit();
            return if (recognized) .progress else .ignored;
        };
        switch (event) {
            // Usage rides on the completed response; fold it in and hand back the
            // running total with the stop event.
            .stop => |stop| {
                if (completedUsage(object)) |usage| mergeUsage(&self.usage, usage);
                self.parsed = parsed;
                return .{ .event = .{ .stop = .{ .reason = stop.reason, .usage = self.usage } } };
            },
            else => {
                self.parsed = parsed;
                return .{ .event = event };
            },
        }
    }
};

/// Open a streaming Responses request bounded by the connect timeout; on any
/// failure `out` is torn down, so a caller that sees an error owns nothing
/// (see `sse.Engine.open`).
pub fn send(self: *Transport, out: *Stream, body: []const u8, access_token: []const u8) !void {
    return sse.Engine(Stream).open(out, self.io, self.timeouts, connect, .{ self, out, body, access_token });
}

fn connect(self: *Transport, out: *Stream, body: []const u8, access_token: []const u8) anyerror!void {
    // Credentials become header values; reject ones that would split the head.
    if (!validHeaderValue(access_token) or
        (self.account_id.len != 0 and !validHeaderValue(self.account_id)))
    {
        return error.BadCredentials;
    }
    const engine = sse.Engine(Stream);
    engine.begin(out, self.gpa, self.io);
    errdefer out.client.deinit();

    const authorization = try std.fmt.allocPrint(self.gpa, "Bearer {s}", .{access_token});
    defer self.gpa.free(authorization);

    // Subscription mode adds the account and originator identity; API-key mode
    // sends neither. `accept` requests the event stream in both.
    var extra_len: usize = 0;
    out.header_buffer[extra_len] = .{ .name = "accept", .value = "text/event-stream" };
    extra_len += 1;
    if (self.account_id.len != 0) {
        out.header_buffer[extra_len] = .{ .name = "chatgpt-account-id", .value = self.account_id };
        extra_len += 1;
        out.header_buffer[extra_len] = .{ .name = "originator", .value = originator };
        extra_len += 1;
    }

    const uri = try std.Uri.parse(self.endpoint);
    out.request = try out.client.request(.POST, uri, .{
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = authorization },
            .user_agent = .{ .override = originator },
            // Read the event stream uncompressed so event delivery stays
            // independent of any decompressor's own buffering.
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = out.header_buffer[0..extra_len],
    });
    errdefer out.request.deinit();

    try engine.finish(out, body);
}

fn validHeaderValue(value: []const u8) bool {
    return value.len != 0 and std.mem.indexOfAny(u8, value, "\r\n") == null;
}

/// Map one Responses SSE frame to a neutral event, or null for a frame the
/// caller need not see (created/in_progress markers, non-reasoning item
/// boundaries, argument-less item bookkeeping).
fn classify(object: std.json.ObjectMap, kind: []const u8) ?llm.Event {
    if (std.mem.eql(u8, kind, "response.output_text.delta"))
        return .{ .text = asString(object.get("delta")) orelse return null };
    if (std.mem.eql(u8, kind, "response.reasoning_summary_text.delta"))
        return .{ .thinking = .{
            .id = asString(object.get("item_id")) orelse "",
            .text = asString(object.get("delta")) orelse return null,
        } };
    if (std.mem.eql(u8, kind, "response.function_call_arguments.delta"))
        return .{ .input_json = asString(object.get("delta")) orelse return null };
    if (std.mem.eql(u8, kind, "response.output_item.added")) {
        const item = asObject(object.get("item")) orelse return null;
        // Only a function call opens a tool use here; its arguments stream as
        // `function_call_arguments.delta`. Message and reasoning items yield no
        // start event (their content arrives as deltas / on done).
        if (!std.mem.eql(u8, asString(item.get("type")) orelse return null, "function_call")) return null;
        return .{ .tool_use = .{
            .call_id = asString(item.get("call_id")) orelse return null,
            .name = asString(item.get("name")) orelse return null,
        } };
    }
    if (std.mem.eql(u8, kind, "response.output_item.done")) {
        const item = asObject(object.get("item")) orelse return null;
        // The reasoning item's encrypted token arrives complete here, closing the
        // reasoning run; other items' content already streamed as deltas.
        if (!std.mem.eql(u8, asString(item.get("type")) orelse return null, "reasoning")) return null;
        return .{ .thinking_blob = .{
            .id = asString(item.get("id")) orelse "",
            .blob = asString(item.get("encrypted_content")) orelse return null,
        } };
    }
    // Both terminal frames carry a response object; `completed` is a clean
    // finish, `incomplete` a truncation (output cap or content filter). Neither
    // is an error — the reply so far still stands — so both close the stream
    // with a stop event. Status and usage are optional within the response.
    if (std.mem.eql(u8, kind, "response.completed") or
        std.mem.eql(u8, kind, "response.incomplete"))
    {
        const response = asObject(object.get("response")) orelse return null;
        return .{ .stop = .{
            .reason = asString(response.get("status")),
            .usage = .{},
        } };
    }
    return null;
}

/// The optional `usage` object nested under a terminal frame's response.
fn completedUsage(object: std.json.ObjectMap) ?std.json.ObjectMap {
    const response = asObject(object.get("response")) orelse return null;
    return asObject(response.get("usage"));
}

fn errorMessage(object: std.json.ObjectMap) ?[]const u8 {
    if (asString(object.get("message"))) |message| return message;
    if (asObject(object.get("error"))) |detail| {
        if (asString(detail.get("message"))) |message| return message;
    }
    if (asObject(object.get("response"))) |response| {
        if (asObject(response.get("error"))) |detail| return asString(detail.get("message"));
    }
    return null;
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

/// Fold a `response.usage` object into the running total. `input_tokens` is the
/// whole prompt, partitioned into three disjoint buckets: cache reads, cache
/// writes, and the uncached remainder. The gpt-5.6 family bills a cache write at
/// a premium over uncached input (unlike earlier models, where writes were
/// free), so each bucket is tracked separately and priced at its own rate.
/// `output_tokens` already counts reasoning tokens (billed as output).
fn mergeUsage(usage: *llm.Usage, object: std.json.ObjectMap) void {
    const total_input = asU64(object.get("input_tokens")) orelse 0;
    var cached: u64 = 0;
    var written: u64 = 0;
    if (asObject(object.get("input_tokens_details"))) |details| {
        cached = asU64(details.get("cached_tokens")) orelse 0;
        written = asU64(details.get("cache_write_tokens")) orelse 0;
    }
    usage.cache_read = cached;
    usage.cache_write = written;
    usage.input = total_input -| cached -| written;
    if (asU64(object.get("output_tokens"))) |value| usage.output = value;
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
    stream.usage = .{};
    return stream;
}

test classify {
    const text =
        \\{"type":"response.output_text.delta","item_id":"msg_1","delta":"hello"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("hello", classify(parsed.value.object, "response.output_text.delta").?.text);

    const summary =
        \\{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","delta":"hmm"}
    ;
    const parsed_summary = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, summary, .{});
    defer parsed_summary.deinit();
    const thinking = classify(parsed_summary.value.object, "response.reasoning_summary_text.delta").?.thinking;
    try std.testing.expectEqualStrings("rs_1", thinking.id);
    try std.testing.expectEqualStrings("hmm", thinking.text);

    const added =
        \\{"type":"response.output_item.added","item":{"type":"function_call","call_id":"call_1","name":"read"}}
    ;
    const parsed_added = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, added, .{});
    defer parsed_added.deinit();
    const use = classify(parsed_added.value.object, "response.output_item.added").?.tool_use;
    try std.testing.expectEqualStrings("call_1", use.call_id);
    try std.testing.expectEqualStrings("read", use.name);

    const done =
        \\{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","encrypted_content":"enc"}}
    ;
    const parsed_done = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, done, .{});
    defer parsed_done.deinit();
    const blob = classify(parsed_done.value.object, "response.output_item.done").?.thinking_blob;
    try std.testing.expectEqualStrings("rs_1", blob.id);
    try std.testing.expectEqualStrings("enc", blob.blob);

    // A non-reasoning item done carries no event.
    const message_done =
        \\{"type":"response.output_item.done","item":{"type":"message","id":"msg_1"}}
    ;
    const parsed_message_done = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, message_done, .{});
    defer parsed_message_done.deinit();
    try std.testing.expectEqual(@as(?llm.Event, null), classify(parsed_message_done.value.object, "response.output_item.done"));
}

test "next walks response.* SSE lines and maps usage on completion" {
    const body =
        "event: response.reasoning_summary_text.delta\n" ++
        "data: {\"type\":\"response.reasoning_summary_text.delta\",\"item_id\":\"rs_1\",\"delta\":\"weigh\"}\n" ++
        "\n" ++
        "event: response.output_item.done\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\",\"encrypted_content\":\"enc\"}}\n" ++
        "\n" ++
        "event: response.output_item.added\n" ++
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"read\"}}\n" ++
        "\n" ++
        "event: response.function_call_arguments.delta\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"fc_1\",\"delta\":\"{}\"}\n" ++
        "\n" ++
        "event: response.output_text.delta\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"delta\":\"done\"}\n" ++
        "\n" ++
        "event: response.completed\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":" ++
        "{\"input_tokens\":100,\"input_tokens_details\":{\"cached_tokens\":90},\"output_tokens\":42," ++
        "\"output_tokens_details\":{\"reasoning_tokens\":20}}}}\n" ++
        "\n";
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var stream = testStream(threaded.io(), &reader, 60_000, net.stream_response_bytes_max);
    defer stream.reset();

    const thinking = (try stream.next()).?;
    try std.testing.expectEqualStrings("weigh", thinking.thinking.text);
    const blob = (try stream.next()).?;
    try std.testing.expectEqualStrings("enc", blob.thinking_blob.blob);
    const use = (try stream.next()).?;
    try std.testing.expectEqualStrings("read", use.tool_use.name);
    const args = (try stream.next()).?;
    try std.testing.expectEqualStrings("{}", args.input_json);
    const text = (try stream.next()).?;
    try std.testing.expectEqualStrings("done", text.text);
    const stop = (try stream.next()).?;
    try std.testing.expectEqualStrings("completed", stop.stop.reason.?);
    // input = input_tokens - cached; cache_read = cached; output as-is; no write.
    try std.testing.expectEqual(@as(u64, 10), stop.stop.usage.input);
    try std.testing.expectEqual(@as(u64, 90), stop.stop.usage.cache_read);
    try std.testing.expectEqual(@as(u64, 42), stop.stop.usage.output);
    try std.testing.expectEqual(@as(u64, 0), stop.stop.usage.cache_write);
    try std.testing.expectEqual(@as(?llm.Event, null), try stream.next());
}

test "terminal events require a response object" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.reset();

    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"response.completed"}
    ));
    const decoded = try stream.decode(
        \\{"type":"response.incomplete","response":{}}
    );
    try std.testing.expectEqual(@as(?[]const u8, null), decoded.event.stop.reason);
    try std.testing.expectEqual(@as(llm.Usage, .{}), decoded.event.stop.usage);
}

test "decode maps response.incomplete to a stop carrying its usage" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.reset();

    // A truncated turn is not an error: it stops with the reason and the usage
    // the response reports, so cost accounting stays correct.
    // The three input buckets are disjoint and sum to input_tokens: uncached =
    // 50 - cached 10 - written 5 = 35, each priced at its own rate downstream.
    const decoded = try stream.decode(
        \\{"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":50,"input_tokens_details":{"cached_tokens":10,"cache_write_tokens":5},"output_tokens":128000}}}
    );
    try std.testing.expectEqualStrings("incomplete", decoded.event.stop.reason.?);
    try std.testing.expectEqual(@as(u64, 35), decoded.event.stop.usage.input);
    try std.testing.expectEqual(@as(u64, 10), decoded.event.stop.usage.cache_read);
    try std.testing.expectEqual(@as(u64, 5), decoded.event.stop.usage.cache_write);
    try std.testing.expectEqual(@as(u64, 128000), decoded.event.stop.usage.output);
}

test "decode surfaces a streamed error frame" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.reset();

    try std.testing.expectError(error.ApiError, stream.decode(
        \\{"type":"error","message":"rate limit"}
    ));
    try std.testing.expectEqualStrings("rate limit", stream.errorText());

    try std.testing.expectError(error.ApiError, stream.decode(
        \\{"type":"response.failed","response":{"error":{"message":"bad request"}}}
    ));
    try std.testing.expectEqualStrings("bad request", stream.errorText());
}

test "decode ignores unrecognized frames instead of counting them as progress" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.reset();

    // A type outside the `response.*` namespace, a payload with no type, and a
    // non-object payload are all filler the protocol does not define: ignored,
    // never progress.
    try std.testing.expectEqual(@as(sse.Decoded, .ignored), try stream.decode(
        \\{"type":"surprise.new.event"}
    ));
    try std.testing.expectEqual(@as(sse.Decoded, .ignored), try stream.decode(
        \\{"note":"no type here"}
    ));
    try std.testing.expectEqual(@as(sse.Decoded, .ignored), try stream.decode(
        \\42
    ));
    // A recognized structural `response.*` frame that carries no event is still
    // progress.
    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"response.in_progress","response":{}}
    ));
}

test "next times out on buffered filler that makes no progress" {
    // A comment line and unrecognized `data:` frames carry no protocol progress,
    // so a stream of only filler must trip the idle window even though every line
    // is buffered and no read ever blocks on the deadline.
    const body =
        ": keepalive comment\n" ++
        "data: {\"type\":\"surprise.new.event\"}\n" ++
        "data: {\"type\":\"surprise.new.event\"}\n" ++
        "data: {\"type\":\"surprise.new.event\"}\n" ++
        "data: {\"type\":\"surprise.new.event\"}\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"m1\",\"delta\":\"late\"}\n";
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var clock: sse.TickingIo = .init(threaded.io(), 40 * std.time.ns_per_ms);
    var reader: std.Io.Reader = .fixed(body);
    var stream = testStream(clock.io(), &reader, 100, net.stream_response_bytes_max);
    defer stream.reset();

    // The window is 100 ms and the logical clock advances 40 ms per reading, so it
    // closes after a few filler lines — before the trailing real event or EOF.
    try std.testing.expectError(error.Timeout, stream.next());
}

test "next stops a stream once its aggregate byte budget is spent" {
    // Each frame is a valid text delta — real progress that restarts the idle
    // window — so only the aggregate byte budget, not the idle deadline, ends the
    // flood. The budget spans two frames, so it trips on their sum rather than any
    // single line, whose own read is separately bounded.
    const frame =
        "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"m1\",\"delta\":\"chunk\"}\n";
    const body = frame ** 5;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var stream = testStream(threaded.io(), &reader, 60_000, frame.len * 2);
    defer stream.reset();

    // Each read charges the line plus its newline. Two frames land inside the
    // budget; the third carries the running total past it, before EOF.
    try std.testing.expectEqualStrings("chunk", (try stream.next()).?.text);
    try std.testing.expectEqualStrings("chunk", (try stream.next()).?.text);
    try std.testing.expectError(error.StreamResponseTooLarge, stream.next());
}

test "next bounds a flood of eventless progress frames" {
    // A `response.in_progress` is recognized progress with no event, so it loops
    // inside `next`, restarting the idle window and never returning to the
    // caller. The aggregate budget must still stop the flood — which an
    // Agent-level counter, fed only returned events, could not.
    const frame = "data: {\"type\":\"response.in_progress\"}\n";
    const body = frame ** 100;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var stream = testStream(threaded.io(), &reader, 60_000, frame.len * 3);
    defer stream.reset();

    // A single `next` never returns an event (every frame is `.progress`); it
    // consumes lines until the running total passes the ceiling.
    try std.testing.expectError(error.StreamResponseTooLarge, stream.next());
}

test "next reads a data frame larger than the reader buffer" {
    // A reasoning item's `encrypted_content` far exceeds the reader buffer — the
    // real oversized-frame case for this provider. Production reads through a
    // 16 KiB `transfer_buffer`, so a longer line must stream into the growable
    // line buffer rather than fit the reader buffer; the chunked test reader
    // serves at most 64 bytes per fill, so one line spans several fills and
    // decodes intact rather than failing `StreamTooLong`.
    const blob = "A" ** 4000;
    const body = "data: {\"type\":\"response.output_item.done\",\"item\":" ++
        "{\"type\":\"reasoning\",\"id\":\"rs_1\",\"encrypted_content\":\"" ++ blob ++ "\"}}\n";
    var buffer: [256]u8 = undefined;
    var chunked: std.testing.Reader = .init(&buffer, &.{.{ .buffer = body }});
    chunked.artificial_limit = .limited(64);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var stream = testStream(threaded.io(), &chunked.interface, 60_000, net.stream_response_bytes_max);
    defer stream.reset();

    const event = (try stream.next()).?;
    try std.testing.expectEqualStrings("rs_1", event.thinking_blob.id);
    try std.testing.expectEqualStrings(blob, event.thinking_blob.blob);
    try std.testing.expect((try stream.next()) == null);
}

test "next rejects a single frame larger than the stream budget" {
    // The budget is smaller than one frame, so the line's own read trips the
    // ceiling before the frame is buffered — the per-frame bound, distinct from
    // the cumulative flood the budget also stops.
    const body = "data: {\"type\":\"response.output_text.delta\"," ++
        "\"item_id\":\"msg_1\",\"delta\":\"chunk\"}\n";
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var stream = testStream(threaded.io(), &reader, 60_000, 32);
    defer stream.reset();

    try std.testing.expectError(error.StreamResponseTooLarge, stream.next());
}

test "next ends the byte stream at a [DONE] sentinel" {
    // The sentinel only ends the byte stream: whatever trails it is never
    // decoded, so a deployment closing with [DONE] cannot fail the turn.
    const body =
        "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"m1\",\"delta\":\"hi\"}\n" ++
        "data: [DONE]\n" ++
        "data: not json\n";
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var stream = testStream(threaded.io(), &reader, 60_000, net.stream_response_bytes_max);
    defer stream.reset();

    try std.testing.expectEqualStrings("hi", (try stream.next()).?.text);
    try std.testing.expectEqual(@as(?llm.Event, null), try stream.next());
}

fn failRead(_: *std.Io.Reader, _: *std.Io.Writer, _: std.Io.Limit) std.Io.Reader.StreamError!usize {
    return error.ReadFailed;
}

test "next refines a canceled connection read into a clean abort" {
    // The reply reader fails at the wire; the connection's recorded read error
    // decides whether that is a user cancel or a genuine network fault.
    var buffer: [16]u8 = undefined;
    var reader: std.Io.Reader = .{
        .vtable = &.{ .stream = failRead },
        .buffer = &buffer,
        .seek = 0,
        .end = 0,
    };
    var connection: std.http.Client.Connection = undefined;
    connection.protocol = .plain;
    connection.stream_reader.err = error.Canceled;
    var stream = testStream(undefined, &reader, 0, net.stream_response_bytes_max);
    stream.request.connection = &connection;

    try std.testing.expectError(error.Canceled, stream.next());
    connection.stream_reader.err = error.ConnectionResetByPeer;
    try std.testing.expectError(error.ReadFailed, stream.next());
}

test "send tears down a request that times out awaiting the response head" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // The listener accepts the connection but never answers, so the connect
    // phase stalls in its head read until the timer wins the race. The testing
    // allocator proves the reaped request leaked nothing.
    var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const endpoint = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://127.0.0.1:{d}/v1/responses",
        .{server.socket.address.getPort()},
    );
    defer std.testing.allocator.free(endpoint);
    var transport: Transport = .{
        .gpa = std.testing.allocator,
        .io = io,
        .timeouts = .{ .connect_ms = 50 },
        .endpoint = endpoint,
        .account_id = "",
    };
    var stream: Stream = undefined;
    try std.testing.expectError(error.Timeout, transport.send(&stream, "{}", "token"));
}

test "next surfaces a stream truncated mid data-line as a retryable premature end" {
    // The final chunk ends inside a `data:` frame; the truncated JSON must take
    // the retryable premature-stream-end path, not a fatal parse error.
    const body = "data: {\"type\":\"response.out";
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var stream = testStream(threaded.io(), &reader, 60_000, net.stream_response_bytes_max);
    defer stream.reset();

    try std.testing.expectError(error.IncompleteReply, stream.next());
}

test "connect rejects credentials that would split the request head" {
    var transport: Transport = .{
        .gpa = std.testing.allocator,
        .io = undefined,
        .timeouts = .{},
        .endpoint = "https://example.com/v1/responses",
        .account_id = "",
    };
    var stream: Stream = undefined;
    try std.testing.expectError(error.BadCredentials, connect(&transport, &stream, "{}", "token\r\nleaked: value"));
    transport.account_id = "account\ninjected: value";
    try std.testing.expectError(error.BadCredentials, connect(&transport, &stream, "{}", "token"));
}
