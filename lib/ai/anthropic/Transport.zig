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

gpa: std.mem.Allocator,
io: std.Io,
timeouts: net.Timeouts,
identity: Identity,

/// How a request authenticates and identifies itself: subscription OAuth sends
/// a `Bearer` access token plus the Claude Code identity headers
/// (`anthropic-beta`, the `claude-cli` user agent, `x-app`); the API key sends
/// only `x-api-key`.
pub const Identity = union(enum) {
    subscription: []const u8,
    api_key: []const u8,
};

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
    /// Scratch for one decoded frame. Events may borrow it until the next read.
    frame_arena: std.heap.ArenaAllocator,
    /// The terminal outcome latched from the last non-null `message_delta` stop
    /// reason; applied at `message_stop`. `none` until a stop reason
    /// arrives, so a `message_stop` without one is an incomplete reply.
    stop_reason: Terminal,
    /// Malformed content observed after a terminal reason. Latched while the
    /// bounded stream drains so message_stop can carry final usage and reject.
    terminal_rejection: ?llm.Event.Stop.Rejection,
    /// The one native content block currently open. Its retained buffers survive
    /// frame resets and are emitted only when the matching block closes.
    open_block: ?OpenBlock,
    block_text: std.ArrayList(u8),
    block_proof: std.ArrayList(u8),
    tool_call_id: std.ArrayList(u8),
    tool_name: std.ArrayList(u8),
    usage: llm.Usage,
    decompress: std.http.Decompress,
    decompress_buffer: []u8,
    /// Backs the request's runtime headers, which must outlive the send phase
    /// (hence a stream field, not a `connect` local).
    header_buffer: [3]std.http.Header,
    error_buffer: [512]u8,
    redirect_buffer: [4096]u8,
    transfer_buffer: [16384]u8,

    const OpenBlock = union(enum) {
        text: u64,
        thinking: u64,
        redacted: u64,
        tool: u64,
        unsupported: u64,

        fn index(self: OpenBlock) u64 {
            return switch (self) {
                inline else => |block_index| block_index,
            };
        }
    };
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

    /// Anthropic surfaces no subscription allowance, so the seam reports none.
    pub fn quotaSoFar(_: *const Stream) ?llm.Quota {
        return null;
    }

    pub fn deinitDecode(self: *Stream) void {
        self.frame_arena.deinit();
        self.block_text.deinit(self.gpa);
        self.block_proof.deinit(self.gpa);
        self.tool_call_id.deinit(self.gpa);
        self.tool_name.deinit(self.gpa);
    }

    /// Latch a rejection, `unsupported` winning over `invalid` however they
    /// interleave: resampling cannot turn an outcome this design cannot retain
    /// into one it can, so spending the retry budget on it only delays the same
    /// failure.
    fn markRejection(self: *Stream, rejection: llm.Event.Stop.Rejection) void {
        if (self.terminal_rejection == null or rejection == .unsupported)
            self.terminal_rejection = rejection;
    }

    fn invalid(self: *Stream) sse.Decoded {
        self.markRejection(.invalid);
        return .progress;
    }

    fn startBlock(self: *Stream, object: *const std.json.ObjectMap) !sse.Decoded {
        const block = json.object(object.get("content_block")) orelse return self.invalid();
        const kind = json.string(block.get("type")) orelse return self.invalid();
        if (self.open_block != null) return self.invalid();
        const index = contentBlockIndex(object) orelse return self.invalid();

        self.block_text.clearRetainingCapacity();
        self.block_proof.clearRetainingCapacity();
        self.tool_call_id.clearRetainingCapacity();
        self.tool_name.clearRetainingCapacity();
        if (std.mem.eql(u8, kind, "text")) {
            self.open_block = .{ .text = index };
        } else if (std.mem.eql(u8, kind, "thinking")) {
            self.open_block = .{ .thinking = index };
        } else if (std.mem.eql(u8, kind, "redacted_thinking")) {
            const data = json.string(block.get("data")) orelse return self.invalid();
            if (data.len == 0) return self.invalid();
            try self.block_proof.appendSlice(self.gpa, data);
            self.open_block = .{ .redacted = index };
        } else if (std.mem.eql(u8, kind, "tool_use")) {
            const call_id = json.string(block.get("id")) orelse return self.invalid();
            const name = json.string(block.get("name")) orelse return self.invalid();
            if (call_id.len == 0) return self.invalid();
            try self.tool_call_id.appendSlice(self.gpa, call_id);
            try self.tool_name.appendSlice(self.gpa, name);
            self.open_block = .{ .tool = index };
        } else {
            self.markRejection(.unsupported);
            self.open_block = .{ .unsupported = index };
        }
        return .progress;
    }

    fn appendBlockDelta(self: *Stream, object: *const std.json.ObjectMap) !sse.Decoded {
        const open_block = self.open_block orelse return self.invalid();
        if (contentBlockIndex(object) != open_block.index()) return self.invalid();
        const delta = json.object(object.get("delta")) orelse return self.invalid();
        const kind = json.string(delta.get("type")) orelse return self.invalid();
        return switch (open_block) {
            .text => if (std.mem.eql(u8, kind, "text_delta")) text: {
                const text = json.string(delta.get("text")) orelse return self.invalid();
                try self.block_text.appendSlice(self.gpa, text);
                break :text .{ .event = .{ .text = text } };
            } else self.invalid(),
            .thinking => if (std.mem.eql(u8, kind, "thinking_delta")) thinking: {
                if (self.block_proof.items.len != 0) return self.invalid();
                const text = json.string(delta.get("thinking")) orelse return self.invalid();
                try self.block_text.appendSlice(self.gpa, text);
                break :thinking .{ .event = .{ .thinking = text } };
            } else if (std.mem.eql(u8, kind, "signature_delta")) signature: {
                const proof = json.string(delta.get("signature")) orelse return self.invalid();
                try self.block_proof.appendSlice(self.gpa, proof);
                break :signature .progress;
            } else self.invalid(),
            .redacted => self.invalid(),
            .tool => if (std.mem.eql(u8, kind, "input_json_delta")) arguments: {
                const chunk = json.string(delta.get("partial_json")) orelse
                    return self.invalid();
                try self.block_text.appendSlice(self.gpa, chunk);
                break :arguments .progress;
            } else self.invalid(),
            .unsupported => .progress,
        };
    }

    fn stopBlock(self: *Stream, object: *const std.json.ObjectMap) sse.Decoded {
        // A stop that closes nothing means the block sequence is malformed, so it
        // latches like every other correlation failure rather than passing for
        // harmless filler.
        const open_block = self.open_block orelse return self.invalid();
        if (contentBlockIndex(object) != open_block.index()) return self.invalid();
        self.open_block = null;
        return switch (open_block) {
            .text => if (self.block_text.items.len == 0)
                .progress
            else
                .{ .event = .{ .item = .{ .message = self.block_text.items } } },
            .thinking => if (self.block_proof.items.len == 0)
                self.invalid()
            else
                .{ .event = .{ .item = .{ .reasoning = .{ .signature = .{
                    .text = self.block_text.items,
                    .signature = self.block_proof.items,
                } } } } },
            .redacted => .{ .event = .{ .item = .{
                .reasoning = .{ .redacted = self.block_proof.items },
            } } },
            .tool => .{ .event = .{ .item = .{ .tool_call = .{
                .call_id = self.tool_call_id.items,
                .name = self.tool_name.items,
                .arguments_json = self.block_text.items,
            } } } },
            .unsupported => .progress,
        };
    }

    /// Decode one Messages `data:` payload; a keepalive `ping` is filler.
    pub fn decode(self: *Stream, payload: []const u8) !sse.Decoded {
        // A malformed payload is filler, not progress; a truncated tail then
        // surfaces as an incomplete reply at end of stream, which is retried.
        const value = std.json.parseFromSliceLeaky(
            std.json.Value,
            self.frame_arena.allocator(),
            payload,
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .ignored,
        };
        const object = json.object(value) orelse return .ignored;
        const kind = json.string(object.get("type")) orelse return .ignored;

        if (std.mem.eql(u8, kind, "ping")) return .ignored;
        if (std.mem.eql(u8, kind, "error")) {
            engine.recordError(self, errorMessage(object) orelse kind);
            return error.ApiError;
        }
        if (std.mem.eql(u8, kind, "message_delta")) {
            if (json.object(object.get("usage"))) |usage| mergeUsage(&self.usage, usage);
            if (messageDeltaStopReason(object)) |reason| self.stop_reason = foldStop(reason);
            return .progress;
        }
        if (std.mem.eql(u8, kind, "message_stop")) {
            if (self.open_block != null) self.markRejection(.invalid);
            return switch (self.stop_reason) {
                .none => .{ .event = .{ .stop = .{
                    .usage = self.usage,
                    .rejection = .invalid,
                } } },
                .unsupported => .{ .event = .{ .stop = .{
                    .usage = self.usage,
                    .rejection = .unsupported,
                } } },
                .complete => .{ .event = .{ .stop = .{
                    .usage = self.usage,
                    .status = .complete,
                    .rejection = self.terminal_rejection,
                } } },
                .truncated => .{ .event = .{ .stop = .{
                    .usage = self.usage,
                    .status = .truncated,
                    .rejection = self.terminal_rejection,
                } } },
            };
        }

        const content = std.mem.eql(u8, kind, "message_start") or
            std.mem.startsWith(u8, kind, "content_block_");
        if (content and self.stop_reason != .none) return self.invalid();
        if (std.mem.eql(u8, kind, "message_start")) {
            if (json.object(object.get("message"))) |message| {
                if (json.object(message.get("usage"))) |usage| mergeUsage(&self.usage, usage);
            }
            return .progress;
        }
        if (std.mem.eql(u8, kind, "content_block_start"))
            return self.startBlock(&object);
        if (std.mem.eql(u8, kind, "content_block_delta"))
            return self.appendBlockDelta(&object);
        if (std.mem.eql(u8, kind, "content_block_stop"))
            return self.stopBlock(&object);
        return if (std.mem.startsWith(u8, kind, "content_block_")) .progress else .ignored;
    }
};

/// The terminal outcome a `stop_reason` folds to. `end_turn`, `tool_use`, and
/// `stop_sequence` are complete; output-token and context-window exhaustion are
/// truncated. `pause_turn`, `refusal`, and any unrecognized reason are unsupported
/// terminal outcomes this design cannot retain, so they reject the reply.
const Terminal = enum { none, complete, truncated, unsupported };

fn foldStop(reason: []const u8) Terminal {
    if (std.mem.eql(u8, reason, "end_turn") or
        std.mem.eql(u8, reason, "tool_use") or
        std.mem.eql(u8, reason, "stop_sequence")) return .complete;
    if (std.mem.eql(u8, reason, "max_tokens") or
        std.mem.eql(u8, reason, "model_context_window_exceeded")) return .truncated;
    return .unsupported;
}

/// Open a streaming Messages request bounded by the connect timeout; on any
/// failure `out` is torn down, so a caller that sees an error owns nothing
/// (see `sse.Engine.open`).
pub fn send(self: *Transport, out: *Stream, body: []const u8) !void {
    return sse.Engine(Stream).open(out, self.io, self.timeouts, connect, .{ self, out, body });
}

fn connect(self: *Transport, out: *Stream, body: []const u8) anyerror!void {
    // Credentials become header values; reject ones that would split the head.
    const credential = switch (self.identity) {
        .subscription => |token| token,
        .api_key => |key| key,
    };
    if (!net.validHeaderValue(credential)) return error.BadCredentials;
    const engine = sse.Engine(Stream);
    engine.begin(out, self.gpa, self.io);
    errdefer out.client.deinit();
    errdefer out.frame_arena.deinit();
    out.stop_reason = .none;
    out.terminal_rejection = null;
    out.open_block = null;
    out.block_text = .empty;
    out.block_proof = .empty;
    out.tool_call_id = .empty;
    out.tool_name = .empty;

    // The Bearer header must outlive the send below, so allocate it at connect
    // scope; the API-key path needs none.
    const maybe_authorization: ?[]u8 = switch (self.identity) {
        .subscription => |token| try std.fmt.allocPrint(self.gpa, "Bearer {s}", .{token}),
        .api_key => null,
    };
    defer if (maybe_authorization) |authorization| self.gpa.free(authorization);

    const uri = try std.Uri.parse(messages_url);
    out.request = try out.client.request(
        .POST,
        uri,
        requestOptions(self.identity, maybe_authorization, &out.header_buffer),
    );
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

fn contentBlockIndex(object: *const std.json.ObjectMap) ?u64 {
    const index = json.integer(object.get("index")) orelse return null;
    if (index < 0) return null;
    return @intCast(index);
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
/// `defer stream.deinitDecode()` to free whatever decoding retains.
fn testStream(io: std.Io, body: *std.Io.Reader, idle_ms: u64, budget_max: usize) Stream {
    return testStreamWithAllocator(std.testing.allocator, io, body, idle_ms, budget_max);
}

fn testStreamWithAllocator(
    gpa: std.mem.Allocator,
    io: std.Io,
    body: *std.Io.Reader,
    idle_ms: u64,
    budget_max: usize,
) Stream {
    var stream: Stream = undefined;
    stream.gpa = gpa;
    stream.io = io;
    stream.idle_ms = idle_ms;
    stream.budget = .{ .max = budget_max };
    stream.body = body;
    stream.frame_arena = .init(gpa);
    stream.stop_reason = .none;
    stream.terminal_rejection = null;
    stream.open_block = null;
    stream.block_text = .empty;
    stream.block_proof = .empty;
    stream.tool_call_id = .empty;
    stream.tool_name = .empty;
    stream.usage = .{};
    return stream;
}

fn decodeTestFrame(stream: *Stream, payload: []const u8) !void {
    _ = stream.frame_arena.reset(.retain_capacity);
    _ = try stream.decode(payload);
}

fn decodeBlocksUnderOom(gpa: std.mem.Allocator) !void {
    var stream = testStreamWithAllocator(gpa, undefined, undefined, 0, 0);
    defer stream.deinitDecode();

    try decodeTestFrame(&stream,
        \\{"type":"content_block_start","index":0,"content_block":{"type":"text"}}
    );
    try decodeTestFrame(&stream,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello"}}
    );
    try decodeTestFrame(&stream,
        \\{"type":"content_block_stop","index":0}
    );
    try decodeTestFrame(&stream,
        \\{"type":"content_block_start","index":1,"content_block":{"type":"thinking"}}
    );
    try decodeTestFrame(&stream,
        \\{"type":"content_block_delta","index":1,"delta":{"type":"thinking_delta","thinking":"hmm"}}
    );
    try decodeTestFrame(&stream,
        \\{"type":"content_block_delta","index":1,"delta":{"type":"signature_delta","signature":"sig"}}
    );
    try decodeTestFrame(&stream,
        \\{"type":"content_block_stop","index":1}
    );
    try decodeTestFrame(&stream,
        \\{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"tool_1","name":"read"}}
    );
    try decodeTestFrame(&stream,
        \\{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{}"}}
    );
    try decodeTestFrame(&stream,
        \\{"type":"content_block_stop","index":2}
    );
}

test "completed block decoding frees state at every allocation-failure point" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        decodeBlocksUnderOom,
        .{},
    );
}

test "reasoning blocks emit display deltas and one complete proof" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();

    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}
    ));
    const thinking = try stream.decode(
        \\{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}
    );
    try std.testing.expectEqualStrings("hmm", thinking.event.thinking);
    _ = stream.frame_arena.reset(.retain_capacity);
    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"si"}}
    ));
    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"g"}}
    ));
    const complete = try stream.decode(
        \\{"type":"content_block_stop","index":0}
    );
    try std.testing.expectEqualStrings("hmm", complete.event.item.reasoning.signature.text);
    try std.testing.expectEqualStrings("sig", complete.event.item.reasoning.signature.signature);

    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"content_block_start","index":1,"content_block":{"type":"redacted_thinking","data":"enc"}}
    ));
    const redacted = try stream.decode(
        \\{"type":"content_block_stop","index":1}
    );
    try std.testing.expectEqualStrings("enc", redacted.event.item.reasoning.redacted);
}

test "invalid reasoning blocks latch through terminal usage" {
    const Case = struct { frames: []const []const u8 };
    const missing_signature = [_][]const u8{
        \\{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}
        ,
        \\{"type":"content_block_stop","index":0}
        ,
    };
    const mismatched_index = [_][]const u8{
        \\{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}
        ,
        \\{"type":"content_block_delta","index":1,"delta":{"type":"signature_delta","signature":"sig"}}
        ,
    };
    const empty_redacted = [_][]const u8{
        \\{"type":"content_block_start","index":0,"content_block":{"type":"redacted_thinking","data":""}}
    };
    const unclosed_redacted = [_][]const u8{
        \\{"type":"content_block_start","index":0,"content_block":{"type":"redacted_thinking","data":"enc"}}
    };
    const mismatched_redacted_close = [_][]const u8{
        \\{"type":"content_block_start","index":0,"content_block":{"type":"redacted_thinking","data":"enc"}}
        ,
        \\{"type":"content_block_stop","index":1}
        ,
    };
    const interleaved_text = [_][]const u8{
        \\{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}
        ,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"wrong"}}
        ,
    };
    const cases = [_]Case{
        .{ .frames = &missing_signature },
        .{ .frames = &mismatched_index },
        .{ .frames = &empty_redacted },
        .{ .frames = &unclosed_redacted },
        .{ .frames = &mismatched_redacted_close },
        .{ .frames = &interleaved_text },
    };

    for (cases) |case| {
        var stream = testStream(undefined, undefined, 0, 0);
        defer stream.deinitDecode();
        for (case.frames) |frame| _ = try stream.decode(frame);
        _ = try stream.decode(
            \\{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}
        );
        const terminal = try stream.decode(
            \\{"type":"message_stop"}
        );
        try std.testing.expectEqual(
            llm.Event.Stop.Rejection.invalid,
            terminal.event.stop.rejection.?,
        );
        try std.testing.expectEqual(@as(u64, 5), terminal.event.stop.usage.output);
    }
}

test "negative block indexes never correlate with block zero" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();
    _ = try stream.decode(
        \\{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"read"}}
    );
    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"content_block_delta","index":-1,"delta":{"type":"input_json_delta","partial_json":"{}"}}
    ));
    try std.testing.expectEqual(
        llm.Event.Stop.Rejection.invalid,
        stream.terminal_rejection.?,
    );
}

test "next walks SSE data lines and ends at stream end" {
    const body =
        "event: message_start\r\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"usage\":" ++
        "{\"input_tokens\":10,\"cache_read_input_tokens\":90," ++
        "\"cache_creation_input_tokens\":5,\"output_tokens\":1}}}\r\n" ++
        "\r\n" ++
        "event: ping\r\n" ++
        "data: {\"type\":\"ping\"}\r\n" ++
        "\r\n" ++
        "event: content_block_start\r\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0," ++
        "\"content_block\":{\"type\":\"text\"}}\r\n" ++
        "\r\n" ++
        "event: content_block_delta\r\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0," ++
        "\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}\r\n" ++
        "\r\n" ++
        "event: content_block_stop\r\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\r\n" ++
        "\r\n" ++
        "event: message_delta\r\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}," ++
        "\"usage\":{\"output_tokens\":42}}\r\n" ++
        "\r\n" ++
        "event: message_stop\r\n" ++
        "data: {\"type\":\"message_stop\"}\r\n" ++
        "\r\n";
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var stream = testStream(threaded.io(), &reader, 60_000, net.stream_response_bytes_max);
    defer stream.deinitDecode();

    try std.testing.expectEqualStrings("Hi", (try stream.next()).?.text);
    try std.testing.expectEqualStrings("Hi", (try stream.next()).?.item.message);
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
    defer stream.deinitDecode();

    try std.testing.expectEqual(@as(sse.Decoded, .ignored), try stream.decode(
        \\{"type":"ping"}
    ));
    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"message_start","message":{"usage":{"input_tokens":3}}}
    ));
    try std.testing.expectEqual(@as(u64, 3), stream.usage.input);
    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"content_block_start","index":0,"content_block":{"type":"text"}}
    ));
    const delta = try stream.decode(
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}
    );
    try std.testing.expectEqualStrings("hi", delta.event.text);
}

test "message_stop carries usage when its reason or tail is invalid" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();

    const missing = try stream.decode(
        \\{"type":"message_stop"}
    );
    try std.testing.expectEqual(
        llm.Event.Stop.Rejection.invalid,
        missing.event.stop.rejection.?,
    );
    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"message_delta","delta":{"stop_reason":null},"usage":{"output_tokens":1}}
    ));
    const missing_after_usage = try stream.decode(
        \\{"type":"message_stop"}
    );
    try std.testing.expectEqual(
        llm.Event.Stop.Rejection.invalid,
        missing_after_usage.event.stop.rejection.?,
    );
    try std.testing.expectEqual(@as(u64, 1), missing_after_usage.event.stop.usage.output);

    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}
    ));
    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"content_block_delta","delta":{"type":"text_delta","text":"late"}}
    ));
    try std.testing.expect(stream.stop_reason == .complete);
    const malformed_tail = try stream.decode(
        \\{"type":"message_stop"}
    );
    try std.testing.expectEqual(
        llm.Event.Stop.Rejection.invalid,
        malformed_tail.event.stop.rejection.?,
    );
    try std.testing.expectEqual(@as(u64, 2), malformed_tail.event.stop.usage.output);
}

test "stop_reason folds to a terminal status; the last non-null delta wins" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();

    // max_tokens truncates; the reply so far still stands.
    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{}}
    ));
    // A later delta that omits the reason updates usage without erasing it.
    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"message_delta","delta":{},"usage":{"output_tokens":1}}
    ));
    try std.testing.expectEqual(
        llm.Event.Status.truncated,
        (try stream.decode(
            \\{"type":"message_stop"}
        )).event.stop.status,
    );

    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"message_delta","delta":{"stop_reason":"model_context_window_exceeded"},"usage":{}}
    ));
    try std.testing.expectEqual(
        llm.Event.Status.truncated,
        (try stream.decode(
            \\{"type":"message_stop"}
        )).event.stop.status,
    );

    // end_turn, tool_use, and stop_sequence complete; a later delta overrides.
    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{}}
    ));
    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{}}
    ));
    try std.testing.expectEqual(
        llm.Event.Status.complete,
        (try stream.decode(
            \\{"type":"message_stop"}
        )).event.stop.status,
    );
}

test "pause_turn, refusal, and unknown stop reasons carry usage as unsupported" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();

    for ([_][]const u8{ "pause_turn", "refusal", "surprise_reason" }) |reason| {
        const delta = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"{s}\"}}," ++
                "\"usage\":{{\"output_tokens\":7}}}}",
            .{reason},
        );
        defer std.testing.allocator.free(delta);
        try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(delta));
        const stop = try stream.decode(
            \\{"type":"message_stop"}
        );
        try std.testing.expectEqual(
            llm.Event.Stop.Rejection.unsupported,
            stop.event.stop.rejection.?,
        );
        try std.testing.expectEqual(@as(u64, 7), stop.event.stop.usage.output);
    }
}

test "unsupported content blocks latch through terminal usage" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();

    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"tool_1"}}
    ));
    try std.testing.expect(stream.open_block.? == .unsupported);
    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"content_block_delta","index":0,"delta":{"type":"server_tool_delta"}}
    ));
    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"content_block_stop","index":0}
    ));
    try std.testing.expect(stream.open_block == null);
    _ = try stream.decode(
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":6}}
    );
    const stop = try stream.decode(
        \\{"type":"message_stop"}
    );
    try std.testing.expectEqual(llm.Event.Stop.Rejection.unsupported, stop.event.stop.rejection.?);
    try std.testing.expectEqual(@as(u64, 6), stop.event.stop.usage.output);
}

test "a tool block emits one completed item when it closes" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();

    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"content_block_start","index":0,"content_block":{"type":"text"}}
    ));
    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"content_block_stop","index":0}
    ));

    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t1","name":"read"}}
    ));
    const complete = try stream.decode(
        \\{"type":"content_block_stop","index":1}
    );
    try std.testing.expectEqualStrings("t1", complete.event.item.tool_call.call_id);
    try std.testing.expectEqualStrings("read", complete.event.item.tool_call.name);
    try std.testing.expectEqualStrings("", complete.event.item.tool_call.arguments_json);
}

test "correlation state survives per-frame resets across a multi-delta tool call" {
    const body =
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":" ++
        "{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"read\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":" ++
        "{\"type\":\"input_json_delta\",\"partial_json\":\"{\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":" ++
        "{\"type\":\"input_json_delta\",\"partial_json\":\"}\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}," ++
        "\"usage\":{\"output_tokens\":3}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var stream = testStream(threaded.io(), &reader, 60_000, net.stream_response_bytes_max);
    defer stream.deinitDecode();

    const item = (try stream.next()).?.item.tool_call;
    try std.testing.expectEqualStrings("t1", item.call_id);
    try std.testing.expectEqualStrings("read", item.name);
    try std.testing.expectEqualStrings("{}", item.arguments_json);
    try std.testing.expectEqual(llm.Event.Status.complete, (try stream.next()).?.stop.status);
    try std.testing.expect((try stream.next()) == null);
}

test "an unrecognized frame after the terminal delta stays ignored" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();

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
    defer stream.deinitDecode();

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
        \\{"type":"content_block_start","index":0,"content_block":{"type":"text"}}
    ));
    try std.testing.expect(stream.terminal_rejection == null);
}

test "a block stop that closes nothing is invalid, not silent filler" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();

    // No block is open, so this stop cannot be part of a well-formed response;
    // latching keeps it from quietly dropping content the peer thought it sent.
    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"content_block_stop","index":0}
    ));
    try std.testing.expectEqual(llm.Event.Stop.Rejection.invalid, stream.terminal_rejection.?);
    _ = try stream.decode(
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}
    );
    const stop = try stream.decode(
        \\{"type":"message_stop"}
    );
    try std.testing.expectEqual(llm.Event.Stop.Rejection.invalid, stop.event.stop.rejection.?);
    try std.testing.expectEqual(@as(u64, 3), stop.event.stop.usage.output);
}

test "decode ignores a malformed data line instead of failing the turn" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();

    try std.testing.expectEqual(@as(sse.Decoded, .ignored), try stream.decode(
        \\{"type":"content_block_delta","del
    ));
    try std.testing.expectEqual(@as(sse.Decoded, .ignored), try stream.decode(
        \\not json at all
    ));
}

test "decode surfaces a streamed error frame" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();

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
        "data: {\"type\":\"content_block_delta\"," ++
        "\"delta\":{\"type\":\"text_delta\",\"text\":\"late\"}}\n";
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var clock: sse.TickingIo = .init(threaded.io(), 40 * std.time.ns_per_ms);
    var reader: std.Io.Reader = .fixed(body);
    var stream = testStream(clock.io(), &reader, 100, net.stream_response_bytes_max);
    defer stream.deinitDecode();

    // The 100 ms window loses 40 ms per reading, so it closes after a few
    // filler lines — before the trailing real event or EOF.
    try std.testing.expectError(error.Timeout, stream.next());
}

test "next stops a stream once its aggregate byte budget is spent" {
    // Each frame is real progress that restarts the idle window, so only the
    // aggregate byte budget ends the flood. It spans two frames, tripping on
    // their sum rather than any single line.
    const frame =
        "data: {\"type\":\"content_block_delta\",\"index\":0," ++
        "\"delta\":{\"type\":\"text_delta\",\"text\":\"chunk\"}}\n";
    const body = frame ** 5;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var stream = testStream(threaded.io(), &reader, 60_000, frame.len * 2);
    defer stream.deinitDecode();
    stream.open_block = .{ .text = 0 };

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
    defer stream.deinitDecode();

    try std.testing.expectError(error.StreamResponseTooLarge, stream.next());
}

test "next reads a data frame larger than the reader buffer" {
    // Production reads through a 16 KiB `transfer_buffer`, so a longer line
    // must stream into the growable line buffer; the chunked reader serves at
    // most 64 bytes per fill, so one line spans several fills.
    const text = "A" ** 4000;
    const body = "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":" ++
        "{\"type\":\"text_delta\",\"text\":\"" ++ text ++ "\"}}\n";
    var buffer: [256]u8 = undefined;
    var chunked: std.testing.Reader = .init(&buffer, &.{.{ .buffer = body }});
    chunked.artificial_limit = .limited(64);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var stream =
        testStream(threaded.io(), &chunked.interface, 60_000, net.stream_response_bytes_max);
    defer stream.deinitDecode();
    stream.open_block = .{ .text = 0 };

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
    defer stream.deinitDecode();

    try std.testing.expectError(error.StreamResponseTooLarge, stream.next());
}

test "next surfaces a stream truncated mid data-line as a retryable premature end" {
    // A truncated final line must never be decoded as a frame.
    const body = "data: {\"type\":\"content_block";
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var stream = testStream(threaded.io(), &reader, 60_000, net.stream_response_bytes_max);
    defer stream.deinitDecode();

    try std.testing.expectError(error.IncompleteReply, stream.next());
}

fn failedRead(
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    limit: std.Io.Limit,
) std.Io.Reader.StreamError!usize {
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

test "connect rejects credentials that would split the request head" {
    var transport: Transport = .{
        .gpa = std.testing.allocator,
        .io = undefined,
        .timeouts = .{},
        .identity = .{ .subscription = "token\r\nleaked: value" },
    };
    var stream: Stream = undefined;
    try std.testing.expectError(error.BadCredentials, connect(&transport, &stream, "{}"));
    transport.identity = .{ .api_key = "key\ninjected: value" };
    try std.testing.expectError(error.BadCredentials, connect(&transport, &stream, "{}"));
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
