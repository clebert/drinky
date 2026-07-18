//! The Responses API transport: sends a serialized request to a configured
//! endpoint with the right auth identity, and exposes the response as a pull
//! stream of decoded SSE `response.*` events. Shared by the API-key and
//! ChatGPT-subscription providers, which differ only in `endpoint` and whether
//! `account_id` is set. Knows nothing about conversation state or tools.

const std = @import("std");

const llm = @import("../llm.zig");
const net = @import("../net.zig");

const Transport = @This();

/// Header value identifying this client on the ChatGPT-subscription backend.
const originator = "pith";

/// Statuses worth retrying: rate limiting, request timeout, and the transient
/// server faults.
const retryable_statuses = [_]std.http.Status{ .request_timeout, .too_many_requests, .internal_server_error, .bad_gateway, .service_unavailable, .gateway_timeout };

gpa: std.mem.Allocator,
io: std.Io,
timeouts: net.Timeouts,
/// Full request URL: `https://api.openai.com/v1/responses` for API-key mode, the
/// Codex backend for subscription mode.
endpoint: []const u8,
/// ChatGPT account id sent as `chatgpt-account-id`; empty in API-key mode, where
/// no account or originator header is sent.
account_id: []const u8,

/// The outcome of decoding one SSE `data:` line: an event for the caller, a
/// recognized `response.*` frame that carries none (usage, block boundaries) but
/// is real progress against the idle window, or an unrecognized frame that is
/// ignored and never counts as progress. Responses sends no keepalive pings.
const Decoded = union(enum) {
    event: llm.Event,
    progress,
    /// An unrecognized frame (not an object, no `type`, or a `type` outside the
    /// `response.*` namespace): ignored, and never counted as progress, so filler
    /// cannot hold the idle window open.
    ignored,
};

/// A single Responses request in flight. Pin it: the HTTP response borrows the
/// request and the SSE reader borrows this struct's buffers.
pub const Stream = struct {
    gpa: std.mem.Allocator,
    /// Whether `connect` ran to completion, so `out` owns resources `deinit` must
    /// free. Set last by a successful connect; the timeout error path reads it.
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

    /// Usage accumulated so far. Responses may deliver full counts on a
    /// terminal response event, so this is zero until then or when omitted.
    pub fn usageSoFar(self: *const Stream) llm.Usage {
        return self.usage;
    }

    /// Next decoded event, or null at end of stream.
    pub fn next(self: *Stream) !?llm.Event {
        if (self.parsed) |parsed| {
            parsed.deinit();
            self.parsed = null;
        }
        // One growable buffer holds the current line, reused across the filler
        // lines this call skips and freed when it returns; the event handed back
        // borrows `self.parsed`, not this buffer.
        var line_buffer: std.Io.Writer.Allocating = .init(self.gpa);
        defer line_buffer.deinit();
        // One idle window spans the read of each event. A recognized frame is
        // progress and restarts the window; filler the protocol does not define
        // does not, so only a genuine stall surfaces `error.Timeout`.
        var deadline = net.Deadline.start(self.io, self.idle_ms);
        while (true) {
            const line = (try self.takeLine(deadline, &line_buffer)) orelse return null;
            // Charge every line against the whole-stream budget, so a peer that
            // makes frequent valid progress (each frame restarting the idle
            // window) still hits an aggregate ceiling. Counting here, after a
            // clean read, also bounds an eventless-`.progress` flood that never
            // returns an event to the caller.
            try self.budget.take(line.len + 1);
            const trimmed = std.mem.trimEnd(u8, line, "\r");
            if (!std.mem.startsWith(u8, trimmed, "data:")) {
                // A non-`data:` line (comment, `event:` field, blank) is not
                // progress; check the window so buffered filler that never blocks
                // a read cannot spin here forever.
                if (deadline.expired(self.io)) return error.Timeout;
                continue;
            }
            const payload = std.mem.trimStart(u8, trimmed["data:".len..], " ");
            // Some deployments close the stream with a Chat-Completions-style
            // sentinel. It ends the byte stream; the Agent separately requires
            // a preceding Responses terminal event before committing the reply.
            if (std.mem.eql(u8, payload, "[DONE]")) return null;
            switch (try self.decode(payload)) {
                .event => |event| return event,
                .progress => deadline = net.Deadline.start(self.io, self.idle_ms),
                // An unrecognized frame never restarts the window, so a stream of
                // only filler trips the timeout even when its bytes arrive
                // buffered and no read ever blocks on `deadline.call`.
                .ignored => if (deadline.expired(self.io)) return error.Timeout,
            }
        }
    }

    /// The next SSE line. A line already buffered is returned without a timed
    /// read; a read that must wait is bounded by the time left in the idle
    /// window, so a stalled stream surfaces `error.Timeout` for the retry path.
    fn takeLine(self: *Stream, deadline: net.Deadline, buffer: *std.Io.Writer.Allocating) !?[]const u8 {
        if (std.mem.indexOfScalar(u8, self.body.buffered(), '\n') != null) return self.readLine(buffer);
        return deadline.call(self.io, readLine, .{ self, buffer });
    }

    /// Take one delimited line into the reused line buffer, mapping a canceled
    /// read to `error.Canceled` (a turn cancel or the idle timer reaping this
    /// task) and leaving every other failure on the network-error path. The line
    /// streams into a growable buffer bounded by what the whole-stream budget may
    /// still deliver, so a single frame larger than that is rejected before it is
    /// fully buffered rather than after. One `data:` line is one event — no
    /// multi-line frame is assembled — so this bounds the assembled frame too.
    fn readLine(self: *Stream, buffer: *std.Io.Writer.Allocating) anyerror!?[]const u8 {
        buffer.clearRetainingCapacity();
        const cap: std.Io.Limit = .limited(self.budget.remaining());
        _ = self.body.streamDelimiterLimit(&buffer.writer, '\n', cap) catch |err| switch (err) {
            error.StreamTooLong => return error.StreamResponseTooLarge,
            error.WriteFailed => return error.OutOfMemory,
            error.ReadFailed => return self.readFailed(),
        };
        // The delimiter, if any, is left buffered: a '\n' closes this line; end
        // of stream with nothing buffered ends the reply, and a final line with
        // no trailing newline is returned once before that.
        const pending = self.body.peekByte() catch |err| switch (err) {
            error.EndOfStream => return if (buffer.written().len == 0) null else buffer.written(),
            error.ReadFailed => return self.readFailed(),
        };
        std.debug.assert(pending == '\n');
        self.body.toss(1);
        return buffer.written();
    }

    /// Refine a reader `ReadFailed` into `error.Canceled` when the connection
    /// recorded a canceled read, else leave it as `error.ReadFailed` for the
    /// network-error path.
    fn readFailed(self: *Stream) anyerror {
        if (self.request.connection.?.getReadError()) |read_error| {
            if (read_error == error.Canceled) return error.Canceled;
        }
        return error.ReadFailed;
    }

    fn decode(self: *Stream, json: []const u8) !Decoded {
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
            self.recordError(errorMessage(object) orelse kind);
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

    fn recordError(self: *Stream, message: []const u8) void {
        self.error_length = @min(message.len, self.error_buffer.len);
        @memcpy(self.error_buffer[0..self.error_length], message[0..self.error_length]);
    }
};

/// Open a streaming Responses request, filling `out` in place. The connect,
/// send, and receive-head phase is bounded by the connect timeout; on expiry (or
/// any failure) `out` is torn down and `error.Timeout` surfaces, so a caller that
/// sees an error never owns `out`.
pub fn send(self: *Transport, out: *Stream, body: []const u8, access_token: []const u8) !void {
    out.io = self.io;
    out.idle_ms = self.timeouts.idle_ms;
    out.budget = .{ .max = net.stream_response_bytes_max };
    out.established = false;
    net.withTimeout(self.io, self.timeouts.connect_ms, connect, .{ self, out, body, access_token }) catch |err| {
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
    var stream: Stream = undefined;
    stream.gpa = std.testing.allocator;
    stream.io = threaded.io();
    stream.idle_ms = 60_000;
    stream.budget = .{ .max = net.stream_response_bytes_max };
    stream.body = &reader;
    stream.parsed = null;
    stream.usage = .{};
    defer if (stream.parsed) |parsed| parsed.deinit();

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
    var stream: Stream = undefined;
    stream.gpa = std.testing.allocator;
    stream.parsed = null;
    stream.usage = .{};
    defer if (stream.parsed) |parsed| parsed.deinit();

    try std.testing.expectEqual(@as(Decoded, .progress), try stream.decode(
        \\{"type":"response.completed"}
    ));
    const decoded = try stream.decode(
        \\{"type":"response.incomplete","response":{}}
    );
    try std.testing.expectEqual(@as(?[]const u8, null), decoded.event.stop.reason);
    try std.testing.expectEqual(@as(llm.Usage, .{}), decoded.event.stop.usage);
}

test "decode maps response.incomplete to a stop carrying its usage" {
    var stream: Stream = undefined;
    stream.gpa = std.testing.allocator;
    stream.parsed = null;
    stream.usage = .{};
    defer if (stream.parsed) |parsed| parsed.deinit();

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
    var stream: Stream = undefined;
    stream.gpa = std.testing.allocator;
    stream.parsed = null;
    stream.usage = .{};
    defer if (stream.parsed) |parsed| parsed.deinit();

    try std.testing.expectError(error.ApiError, stream.decode(
        \\{"type":"error","message":"rate limit"}
    ));
    try std.testing.expectEqualStrings("rate limit", stream.errorText());

    try std.testing.expectError(error.ApiError, stream.decode(
        \\{"type":"response.failed","response":{"error":{"message":"bad request"}}}
    ));
    try std.testing.expectEqualStrings("bad request", stream.errorText());
}

/// A logical clock over a real backend: `now` returns the current tick and then
/// advances by a fixed step, so a bounded run of non-progress reads drives the
/// idle window to expiry deterministically without real time passing. Only `now`
/// is overridden, so the callers must never reach another vtable entry with this
/// wrapper's userdata: the tests feed a fully buffered `.fixed` reader whose
/// lines are always available, so `takeLine` returns them directly and never
/// reaches `deadline.call` (the sole path to a backend-owned timed operation).
const TickingIo = struct {
    backend: std.Io,
    vtable: std.Io.VTable,
    tick_ns: i96,
    step_ns: i96,

    fn init(backend: std.Io, step_ns: i96) TickingIo {
        var vtable = backend.vtable.*;
        vtable.now = now;
        return .{ .backend = backend, .vtable = vtable, .tick_ns = 0, .step_ns = step_ns };
    }

    fn io(self: *TickingIo) std.Io {
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

test "decode ignores unrecognized frames instead of counting them as progress" {
    var stream: Stream = undefined;
    stream.gpa = std.testing.allocator;
    stream.parsed = null;
    stream.usage = .{};
    defer if (stream.parsed) |parsed| parsed.deinit();

    // A type outside the `response.*` namespace, a payload with no type, and a
    // non-object payload are all filler the protocol does not define: ignored,
    // never progress.
    try std.testing.expectEqual(@as(Decoded, .ignored), try stream.decode(
        \\{"type":"surprise.new.event"}
    ));
    try std.testing.expectEqual(@as(Decoded, .ignored), try stream.decode(
        \\{"note":"no type here"}
    ));
    try std.testing.expectEqual(@as(Decoded, .ignored), try stream.decode(
        \\42
    ));
    // A recognized structural `response.*` frame that carries no event is still
    // progress.
    try std.testing.expectEqual(@as(Decoded, .progress), try stream.decode(
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
    var clock: TickingIo = .init(threaded.io(), 40 * std.time.ns_per_ms);
    var reader: std.Io.Reader = .fixed(body);
    var stream: Stream = undefined;
    stream.gpa = std.testing.allocator;
    stream.io = clock.io();
    stream.idle_ms = 100;
    stream.budget = .{ .max = net.stream_response_bytes_max };
    stream.body = &reader;
    stream.parsed = null;
    stream.usage = .{};
    defer if (stream.parsed) |parsed| parsed.deinit();

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
    var stream: Stream = undefined;
    stream.gpa = std.testing.allocator;
    stream.io = threaded.io();
    stream.idle_ms = 60_000;
    stream.budget = .{ .max = frame.len * 2 };
    stream.body = &reader;
    stream.parsed = null;
    stream.usage = .{};
    defer if (stream.parsed) |parsed| parsed.deinit();

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
    var stream: Stream = undefined;
    stream.gpa = std.testing.allocator;
    stream.io = threaded.io();
    stream.idle_ms = 60_000;
    stream.budget = .{ .max = frame.len * 3 };
    stream.body = &reader;
    stream.parsed = null;
    stream.usage = .{};
    defer if (stream.parsed) |parsed| parsed.deinit();

    // A single `next` never returns an event (every frame is `.progress`); it
    // consumes lines until the running total passes the ceiling.
    try std.testing.expectError(error.StreamResponseTooLarge, stream.next());
}

/// A `std.Io.Reader` with a small buffer that serves an in-memory source in
/// chunks, standing in for a bounded-buffer network reader: production reads
/// through a 16 KiB `transfer_buffer`, so a line longer than the buffer must be
/// streamed into the growable line buffer rather than held whole. `stream`
/// writes at most `chunk` bytes per call, so one line spans several fills.
const ChunkedReader = struct {
    source: []const u8,
    pos: usize,
    chunk: usize,
    interface: std.Io.Reader,

    fn init(source: []const u8, buffer: []u8, chunk: usize) ChunkedReader {
        return .{
            .source = source,
            .pos = 0,
            .chunk = chunk,
            .interface = .{ .vtable = &vtable, .buffer = buffer, .seek = 0, .end = 0 },
        };
    }

    const vtable: std.Io.Reader.VTable = .{ .stream = stream };

    fn stream(
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *ChunkedReader = @alignCast(@fieldParentPtr("interface", reader));
        if (self.pos >= self.source.len) return error.EndOfStream;
        const rest = self.source[self.pos..];
        const take = @min(@min(self.chunk, rest.len), @intFromEnum(limit));
        const written = try writer.write(rest[0..take]);
        self.pos += written;
        return written;
    }
};

test "next reads a data frame larger than the reader buffer" {
    // A reasoning item's `encrypted_content` far exceeds the reader buffer — the
    // real oversized-frame case for this provider. The line streams into the
    // growable line buffer instead of having to fit the reader buffer, so it
    // decodes intact rather than failing `StreamTooLong`.
    const blob = "A" ** 4000;
    const body = "data: {\"type\":\"response.output_item.done\",\"item\":" ++
        "{\"type\":\"reasoning\",\"id\":\"rs_1\",\"encrypted_content\":\"" ++ blob ++ "\"}}\n";
    var buffer: [256]u8 = undefined;
    var chunked: ChunkedReader = .init(body, &buffer, 64);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var stream: Stream = undefined;
    stream.gpa = std.testing.allocator;
    stream.io = threaded.io();
    stream.idle_ms = 60_000;
    stream.budget = .{ .max = net.stream_response_bytes_max };
    stream.body = &chunked.interface;
    stream.parsed = null;
    stream.usage = .{};
    defer if (stream.parsed) |parsed| parsed.deinit();

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
    var stream: Stream = undefined;
    stream.gpa = std.testing.allocator;
    stream.io = threaded.io();
    stream.idle_ms = 60_000;
    stream.budget = .{ .max = 32 };
    stream.body = &reader;
    stream.parsed = null;
    stream.usage = .{};
    defer if (stream.parsed) |parsed| parsed.deinit();

    try std.testing.expectError(error.StreamResponseTooLarge, stream.next());
}

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
    var stream: Stream = undefined;
    stream.status = .too_many_requests;
    try std.testing.expect(stream.retryable());
    stream.status = .service_unavailable;
    try std.testing.expect(stream.retryable());
    stream.status = .ok;
    try std.testing.expect(!stream.retryable());
    stream.status = .bad_request;
    try std.testing.expect(!stream.retryable());
}
