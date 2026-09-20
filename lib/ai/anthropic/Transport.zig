const std = @import("std");

const json = @import("../json.zig");
const llm = @import("../llm.zig");
const net = @import("../net.zig");
const sse = @import("../sse.zig");

const Transport = @This();

const messages_url = "https://api.anthropic.com/v1/messages";
const anthropic_version = "2023-06-01";
const streaming_beta = "fine-grained-tool-streaming-2025-05-14";
const beta = "claude-code-20250219,oauth-2025-04-20," ++ streaming_beta;
const user_agent = "claude-cli/2.1.75";

gpa: std.mem.Allocator,
io: std.Io,
timeouts: net.Timeouts,
identity: Identity,
endpoint: []const u8 = messages_url,

pub const Identity = union(enum) {
    subscription: []const u8,
    api_key: []const u8,
};

pub const Stream = struct {
    gpa: std.mem.Allocator,
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
    error_retryable: bool,
    retry_after_ms: ?u64,
    frame_arena: std.heap.ArenaAllocator,
    stop_reason: Terminal,
    terminal_rejection: ?llm.Event.Stop.Rejection,
    open_block: ?OpenBlock,
    reasoning: sse.Reasoning,
    block_text: std.ArrayList(u8),
    block_proof: std.ArrayList(u8),
    tool_call_id: std.ArrayList(u8),
    tool_name: std.ArrayList(u8),
    served_model: std.ArrayList(u8),
    usage: llm.Usage,
    quota: ?llm.Quota,
    decompress: std.http.Decompress,
    decompress_buffer: []u8,
    header_buffer: [3]std.http.Header,
    authorization: []u8,
    error_buffer: [net.error_body_bytes_max]u8,
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
    pub const unauthorized = engine.unauthorized;
    pub const retryable = engine.retryable;
    pub const retryAfterMs = engine.retryAfterMs;
    pub const usageSoFar = engine.usageSoFar;
    pub const next = engine.next;

    pub fn captureHead(self: *Stream, head: *const std.http.Client.Response.Head) void {
        const now_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        self.quota = parseQuota(head, @divFloor(now_ms, std.time.ms_per_s));
    }

    pub fn quotaSoFar(self: *const Stream) ?llm.Quota {
        return self.quota;
    }

    pub fn describeError(self: *Stream, body: []const u8) !?[]const u8 {
        const object = (try json.parseObject(self.frame_arena.allocator(), body)) orelse
            return null;
        return errorMessage(object);
    }

    pub fn beginDecode(self: *Stream) void {
        self.stop_reason = .none;
        self.terminal_rejection = null;
        self.open_block = null;
        self.reasoning = .none;
        self.block_text = .empty;
        self.block_proof = .empty;
        self.tool_call_id = .empty;
        self.tool_name = .empty;
        self.served_model = .empty;
        self.quota = null;
        self.authorization = &.{};
    }

    pub fn deinitDecode(self: *Stream) void {
        self.frame_arena.deinit();
        self.block_text.deinit(self.gpa);
        self.block_proof.deinit(self.gpa);
        self.tool_call_id.deinit(self.gpa);
        self.tool_name.deinit(self.gpa);
        self.served_model.deinit(self.gpa);
    }

    pub fn deinitHeaders(self: *Stream) void {
        self.gpa.free(self.authorization);
    }

    fn markRejection(self: *Stream, rejection: llm.Event.Stop.Rejection) void {
        const latched = self.terminal_rejection orelse {
            self.terminal_rejection = rejection;
            return;
        };
        if (rejection.outranks(latched)) self.terminal_rejection = rejection;
    }

    fn invalid(self: *Stream) sse.Decoded {
        self.markRejection(.invalid);
        return .progress;
    }

    fn uncorrelated(self: *Stream) sse.Decoded {
        self.markRejection(.uncorrelated);
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
            if (self.reasoning.takeSeam())
                return .{ .event = .{ .thinking = sse.blank_line } };
        } else if (std.mem.eql(u8, kind, "tool_use")) {
            const call_id = json.string(block.get("id")) orelse return self.invalid();
            const name = json.string(block.get("name")) orelse return self.invalid();
            if (call_id.len == 0) return self.invalid();
            try self.tool_call_id.appendSlice(self.gpa, call_id);
            try self.tool_name.appendSlice(self.gpa, name);
            self.open_block = .{ .tool = index };
            return .{ .event = .{ .tool_name = self.tool_name.items } };
        } else {
            self.markRejection(.unsupported);
            self.open_block = .{ .unsupported = index };
        }
        return .progress;
    }

    fn appendBlockDelta(self: *Stream, object: *const std.json.ObjectMap) !sse.Decoded {
        const open_block = self.open_block orelse return self.invalid();
        const index = contentBlockIndex(object) orelse return self.invalid();
        if (index != open_block.index()) return self.uncorrelated();
        const delta = json.object(object.get("delta")) orelse return self.invalid();
        const kind = json.string(delta.get("type")) orelse return self.invalid();
        return switch (open_block) {
            .text => if (std.mem.eql(u8, kind, "text_delta")) text: {
                const text = json.string(delta.get("text")) orelse return self.invalid();
                try self.block_text.appendSlice(self.gpa, text);
                if (!self.reasoning.answer(text)) break :text .progress;
                break :text .{ .event = .{ .text = text } };
            } else self.invalid(),
            .thinking => if (std.mem.eql(u8, kind, "thinking_delta")) thinking: {
                if (self.block_proof.items.len != 0) return self.invalid();
                const text = json.string(delta.get("thinking")) orelse return self.invalid();
                try self.block_text.appendSlice(self.gpa, text);
                break :thinking try self.reasoning.display(self.frame_arena.allocator(), text);
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
                break :arguments .{ .event = .{ .tool_arguments = chunk } };
            } else self.invalid(),
            .unsupported => .progress,
        };
    }

    fn stopBlock(self: *Stream, object: *const std.json.ObjectMap) sse.Decoded {
        const open_block = self.open_block orelse return self.invalid();
        const index = contentBlockIndex(object) orelse return self.invalid();
        if (index != open_block.index()) return self.uncorrelated();
        self.open_block = null;
        switch (open_block) {
            .thinking, .redacted => self.reasoning.end(),
            else => {},
        }
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

    pub fn decode(self: *Stream, payload: []const u8) !sse.Decoded {
        const object = (try json.parseObject(self.frame_arena.allocator(), payload)) orelse
            return .ignored;
        const kind = json.string(object.get("type")) orelse return .ignored;

        if (std.mem.eql(u8, kind, "ping")) return .ignored;
        if (std.mem.eql(u8, kind, "error")) {
            engine.recordError(
                self,
                errorMessage(object) orelse kind,
                errorRetryable(&object),
            );
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
                    .model = self.served_model.items,
                } } },
                .unsupported => .{ .event = .{ .stop = .{
                    .usage = self.usage,
                    .rejection = .unsupported,
                    .model = self.served_model.items,
                } } },
                .complete => .{ .event = .{ .stop = .{
                    .usage = self.usage,
                    .status = .complete,
                    .rejection = self.terminal_rejection,
                    .model = self.served_model.items,
                } } },
                .truncated => .{ .event = .{ .stop = .{
                    .usage = self.usage,
                    .status = .truncated,
                    .rejection = self.terminal_rejection,
                    .model = self.served_model.items,
                } } },
            };
        }

        const content = std.mem.eql(u8, kind, "message_start") or
            std.mem.startsWith(u8, kind, "content_block_");
        if (content and self.stop_reason != .none) return self.invalid();
        if (std.mem.eql(u8, kind, "message_start")) {
            if (json.object(object.get("message"))) |message| {
                if (json.object(message.get("usage"))) |usage| mergeUsage(&self.usage, usage);
                if (json.string(message.get("model"))) |model_name| {
                    self.served_model.clearRetainingCapacity();
                    try self.served_model.appendSlice(self.gpa, model_name);
                }
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

const Terminal = enum { none, complete, truncated, unsupported };

fn foldStop(reason: []const u8) Terminal {
    if (std.mem.eql(u8, reason, "end_turn") or
        std.mem.eql(u8, reason, "tool_use") or
        std.mem.eql(u8, reason, "stop_sequence")) return .complete;
    if (std.mem.eql(u8, reason, "max_tokens") or
        std.mem.eql(u8, reason, "model_context_window_exceeded")) return .truncated;
    return .unsupported;
}

pub fn send(self: *Transport, out: *Stream, body: []const u8) !void {
    return sse.Engine(Stream).open(out, self.io, self.timeouts, connect, .{ self, out, body });
}

fn connect(self: *Transport, out: *Stream, body: []const u8) anyerror!void {
    const credential = switch (self.identity) {
        .subscription => |token| token,
        .api_key => |key| key,
    };
    if (!net.validHeaderValue(credential)) return error.BadCredentials;
    const engine = sse.Engine(Stream);
    engine.begin(out, self.gpa, self.io);
    errdefer out.client.deinit();
    errdefer out.frame_arena.deinit();

    out.authorization = switch (self.identity) {
        .subscription => |token| try std.fmt.allocPrint(self.gpa, "Bearer {s}", .{token}),
        .api_key => &.{},
    };
    errdefer self.gpa.free(out.authorization);

    const uri = try std.Uri.parse(self.endpoint);
    out.request = try out.client.request(
        .POST,
        uri,
        requestOptions(self.identity, out.authorization, &out.header_buffer),
    );
    errdefer out.request.deinit();

    try engine.finish(out, body);
}

fn requestOptions(
    identity: Identity,
    authorization: []const u8,
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
                    .authorization = .{ .override = authorization },
                    .user_agent = .{ .override = user_agent },
                    .accept_encoding = .{ .override = "identity" },
                },
                .extra_headers = extra,
            };
        },
        .api_key => |key| {
            extra[0] = .{ .name = "x-api-key", .value = key };
            extra[1] = .{ .name = "anthropic-version", .value = anthropic_version };
            extra[2] = .{ .name = "anthropic-beta", .value = streaming_beta };
            return .{
                .headers = .{
                    .content_type = .{ .override = "application/json" },
                    .accept_encoding = .{ .override = "identity" },
                },
                .extra_headers = extra,
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

fn errorRetryable(object: *const std.json.ObjectMap) bool {
    const detail = json.object(object.get("error")) orelse return false;
    const kind = json.string(detail.get("type")) orelse return false;
    return std.mem.eql(u8, kind, "overloaded_error") or
        std.mem.eql(u8, kind, "rate_limit_error") or
        std.mem.eql(u8, kind, "api_error");
}

fn mergeUsage(usage: *llm.Usage, object: std.json.ObjectMap) void {
    if (json.unsigned(object.get("input_tokens"))) |value| usage.input = value;
    if (json.unsigned(object.get("output_tokens"))) |value| usage.output = value;
    if (json.unsigned(object.get("cache_read_input_tokens"))) |value| usage.cache_read = value;
    if (json.unsigned(object.get("cache_creation_input_tokens"))) |value| usage.cache_write = value;
}

const quota_windows = [_]struct { name: []const u8, minutes: u32 }{
    .{ .name = "5h", .minutes = 300 },
    .{ .name = "7d", .minutes = 10080 },
};

fn parseQuota(head: *const std.http.Client.Response.Head, now_seconds: i64) ?llm.Quota {
    var used: [quota_windows.len]?f64 = @splat(null);
    var reset_seconds: [quota_windows.len]?u64 = @splat(null);
    var headers = head.iterateHeaders();
    while (headers.next()) |header| {
        const value = std.mem.trim(u8, header.value, " \t");
        inline for (quota_windows, 0..) |window, index| {
            const prefix = "anthropic-ratelimit-unified-" ++ window.name;
            if (std.ascii.eqlIgnoreCase(header.name, prefix ++ "-utilization")) {
                used[index] = parseUtilization(value);
            } else if (std.ascii.eqlIgnoreCase(header.name, prefix ++ "-reset")) {
                reset_seconds[index] = parseResetSeconds(value, now_seconds);
            }
        }
    }
    var parsed: [quota_windows.len]?llm.Quota.Window = @splat(null);
    var found = false;
    for (quota_windows, 0..) |window, index| {
        const share = used[index] orelse continue;
        parsed[index] = .{
            .used_percent = share,
            .window_minutes = window.minutes,
            .reset_seconds = reset_seconds[index],
        };
        found = true;
    }
    if (!found) return null;
    return .{ .primary = parsed[0], .secondary = parsed[1] };
}

fn parseUtilization(value: []const u8) ?f64 {
    const fraction = std.fmt.parseFloat(f64, value) catch return null;
    if (!std.math.isFinite(fraction) or fraction < 0) return null;
    return @min(100.0, fraction * 100.0);
}

fn parseResetSeconds(value: []const u8, now_seconds: i64) ?u64 {
    const epoch = std.fmt.parseInt(i64, value, 10) catch return null;
    if (epoch <= now_seconds) return null;
    return @intCast(epoch - now_seconds);
}

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
    sse.Engine(Stream).begin(&stream, gpa, io);
    stream.io = io;
    stream.idle_ms = idle_ms;
    stream.budget = .{ .max = budget_max };
    stream.body = body;
    stream.status = .ok;
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

test parseQuota {
    const captured = "HTTP/1.1 200 OK\r\n" ++
        "anthropic-ratelimit-unified-status: allowed\r\n" ++
        "anthropic-ratelimit-unified-5h-status: allowed\r\n" ++
        "anthropic-ratelimit-unified-5h-reset: 1787598000\r\n" ++
        "anthropic-ratelimit-unified-5h-utilization: 0.06\r\n" ++
        "anthropic-ratelimit-unified-overage-utilization: 0.5\r\n" ++
        "anthropic-ratelimit-unified-overage-reset: 1788220800\r\n" ++
        "content-length:0\r\n\r\n";
    const captured_head = try std.http.Client.Response.Head.parse(captured);
    const quota = parseQuota(&captured_head, 1_787_589_400).?;
    try std.testing.expectApproxEqAbs(
        @as(f64, 6),
        quota.primary.?.used_percent,
        1e-9,
    );
    try std.testing.expectEqual(@as(?u32, 300), quota.primary.?.window_minutes);
    try std.testing.expectEqual(@as(?u64, 8600), quota.primary.?.reset_seconds);
    try std.testing.expect(quota.secondary == null);

    const both = "HTTP/1.1 200 OK\r\n" ++
        "anthropic-ratelimit-unified-5h-utilization: 0.042\r\n" ++
        "anthropic-ratelimit-unified-5h-reset: 1787598000\r\n" ++
        "anthropic-ratelimit-unified-7d-utilization: 0.3\r\n" ++
        "anthropic-ratelimit-unified-7d-reset: 1788220800\r\n" ++
        "content-length:0\r\n\r\n";
    const both_head = try std.http.Client.Response.Head.parse(both);
    const windows = parseQuota(&both_head, 1_787_589_400).?;
    try std.testing.expectApproxEqAbs(@as(f64, 4.2), windows.primary.?.used_percent, 1e-9);
    try std.testing.expectEqual(@as(?u32, 10080), windows.secondary.?.window_minutes);
    try std.testing.expectEqual(@as(?u64, 631_400), windows.secondary.?.reset_seconds);

    const stale_head = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 200 OK\r\n" ++
            "anthropic-ratelimit-unified-5h-utilization: 0.9\r\n" ++
            "anthropic-ratelimit-unified-5h-reset: 1787000000\r\n" ++
            "content-length:0\r\n\r\n",
    );
    const stale = parseQuota(&stale_head, 1_787_589_400).?;
    try std.testing.expectApproxEqAbs(@as(f64, 90), stale.primary.?.used_percent, 1e-9);
    try std.testing.expect(stale.primary.?.reset_seconds == null);

    const none_head = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 200 OK\r\ncontent-length:0\r\n\r\n",
    );
    try std.testing.expect(parseQuota(&none_head, 1_787_589_400) == null);
}

test parseResetSeconds {
    const now: i64 = 1_787_589_400;
    try std.testing.expectEqual(@as(?u64, 8600), parseResetSeconds("1787598000", now));
    try std.testing.expect(parseResetSeconds("1787000000", now) == null);
    try std.testing.expect(parseResetSeconds("2026-08-24T19:00:00Z", now) == null);
    try std.testing.expect(parseResetSeconds("soon", now) == null);
    try std.testing.expect(parseResetSeconds("", now) == null);
}

test parseUtilization {
    try std.testing.expectEqual(@as(?f64, 0), parseUtilization("0.0"));
    try std.testing.expectEqual(@as(?f64, 100), parseUtilization("1"));
    try std.testing.expectEqual(@as(?f64, 100), parseUtilization("1.4"));
    try std.testing.expect(parseUtilization("-0.1") == null);
    try std.testing.expect(parseUtilization("nan") == null);
    try std.testing.expect(parseUtilization("inf") == null);
    try std.testing.expect(parseUtilization("half") == null);
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

    try std.testing.expectEqualStrings("\n\n", (try stream.decode(
        \\{"type":"content_block_start","index":1,"content_block":{"type":"redacted_thinking","data":"enc"}}
    )).event.thinking);
    const redacted = try stream.decode(
        \\{"type":"content_block_stop","index":1}
    );
    try std.testing.expectEqualStrings("enc", redacted.event.item.reasoning.redacted);
}

test "a new thinking block separates its display from the block before it" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();

    try decodeTestFrame(&stream,
        \\{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}
    );
    _ = stream.frame_arena.reset(.retain_capacity);
    try std.testing.expectEqualStrings("**a**", (try stream.decode(
        \\{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"**a**"}}
    )).event.thinking);
    try decodeTestFrame(&stream,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}
    );
    try decodeTestFrame(&stream,
        \\{"type":"content_block_stop","index":0}
    );
    try decodeTestFrame(&stream,
        \\{"type":"content_block_start","index":1,"content_block":{"type":"thinking"}}
    );
    _ = stream.frame_arena.reset(.retain_capacity);
    try std.testing.expectEqualStrings("\n\n**b**", (try stream.decode(
        \\{"type":"content_block_delta","index":1,"delta":{"type":"thinking_delta","thinking":"**b**"}}
    )).event.thinking);
}

test "an empty thinking delta displays nothing and holds the pending seam" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();

    try decodeTestFrame(&stream,
        \\{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}
    );
    try decodeTestFrame(&stream,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"**a**"}}
    );
    try decodeTestFrame(&stream,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}
    );
    try decodeTestFrame(&stream,
        \\{"type":"content_block_stop","index":0}
    );
    try decodeTestFrame(&stream,
        \\{"type":"content_block_start","index":1,"content_block":{"type":"thinking"}}
    );
    _ = stream.frame_arena.reset(.retain_capacity);
    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"content_block_delta","index":1,"delta":{"type":"thinking_delta","thinking":""}}
    ));
    _ = stream.frame_arena.reset(.retain_capacity);
    try std.testing.expectEqualStrings("\n\n**b**", (try stream.decode(
        \\{"type":"content_block_delta","index":1,"delta":{"type":"thinking_delta","thinking":"**b**"}}
    )).event.thinking);
}

test "answer text ends the thinking display and an empty delta holds the seam" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();

    try decodeTestFrame(&stream,
        \\{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}
    );
    try decodeTestFrame(&stream,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"a"}}
    );
    try decodeTestFrame(&stream,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}
    );
    try decodeTestFrame(&stream,
        \\{"type":"content_block_stop","index":0}
    );
    try decodeTestFrame(&stream,
        \\{"type":"content_block_start","index":1,"content_block":{"type":"text"}}
    );
    _ = stream.frame_arena.reset(.retain_capacity);
    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":""}}
    ));
    try decodeTestFrame(&stream,
        \\{"type":"content_block_stop","index":1}
    );
    try decodeTestFrame(&stream,
        \\{"type":"content_block_start","index":2,"content_block":{"type":"thinking"}}
    );
    _ = stream.frame_arena.reset(.retain_capacity);
    try std.testing.expectEqualStrings("\n\nb", (try stream.decode(
        \\{"type":"content_block_delta","index":2,"delta":{"type":"thinking_delta","thinking":"b"}}
    )).event.thinking);
    try decodeTestFrame(&stream,
        \\{"type":"content_block_delta","index":2,"delta":{"type":"signature_delta","signature":"sig"}}
    );
    try decodeTestFrame(&stream,
        \\{"type":"content_block_stop","index":2}
    );
    try decodeTestFrame(&stream,
        \\{"type":"content_block_start","index":3,"content_block":{"type":"text"}}
    );
    try decodeTestFrame(&stream,
        \\{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"answer"}}
    );
    try decodeTestFrame(&stream,
        \\{"type":"content_block_stop","index":3}
    );
    try decodeTestFrame(&stream,
        \\{"type":"content_block_start","index":4,"content_block":{"type":"thinking"}}
    );
    _ = stream.frame_arena.reset(.retain_capacity);
    try std.testing.expectEqualStrings("c", (try stream.decode(
        \\{"type":"content_block_delta","index":4,"delta":{"type":"thinking_delta","thinking":"c"}}
    )).event.thinking);
}

test "a rejected reasoning block latches through terminal usage" {
    const Case = struct {
        frames: []const []const u8,
        rejection: llm.Event.Stop.Rejection = .invalid,
    };
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
        .{ .frames = &mismatched_index, .rejection = .uncorrelated },
        .{ .frames = &empty_redacted },
        .{ .frames = &unclosed_redacted },
        .{ .frames = &mismatched_redacted_close, .rejection = .uncorrelated },
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
        try std.testing.expectEqual(case.rejection, terminal.event.stop.rejection.?);
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

test "message_stop names the model that served the reply" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();

    try decodeTestFrame(&stream,
        \\{"type":"message_start","message":{"model":"claude-opus-5","usage":{"input_tokens":3}}}
    );
    try decodeTestFrame(&stream,
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}
    );
    _ = stream.frame_arena.reset(.retain_capacity);
    const stop = try stream.decode(
        \\{"type":"message_stop"}
    );
    try std.testing.expectEqualStrings("claude-opus-5", stop.event.stop.model);

    var headless = testStream(undefined, undefined, 0, 0);
    defer headless.deinitDecode();
    const unnamed_stop = try headless.decode(
        \\{"type":"message_stop"}
    );
    try std.testing.expectEqualStrings("", unnamed_stop.event.stop.model);
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

    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{}}
    ));
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

    const opened = try stream.decode(
        \\{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t1","name":"read"}}
    );
    try std.testing.expectEqualStrings("read", opened.event.tool_name);
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

    try std.testing.expectEqualStrings("read", (try stream.next()).?.tool_name);
    try std.testing.expectEqualStrings("{", (try stream.next()).?.tool_arguments);
    try std.testing.expectEqualStrings("}", (try stream.next()).?.tool_arguments);
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
    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"content_block_start","index":0,"content_block":{"type":"text"}}
    ));
    try std.testing.expect(stream.terminal_rejection == null);
}

test "a block stop that closes nothing is invalid, not silent filler" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();

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
    try std.testing.expect(stream.retryable());

    try std.testing.expectError(error.ApiError, stream.decode(
        \\{"type":"error","error":{"type":"rate_limit_error","message":"Rate limited"}}
    ));
    try std.testing.expect(stream.retryable());
    try std.testing.expectError(error.ApiError, stream.decode(
        \\{"type":"error","error":{"type":"api_error","message":"Server error"}}
    ));
    try std.testing.expect(stream.retryable());

    try std.testing.expectError(error.ApiError, stream.decode(
        \\{"type":"error","error":{}}
    ));
    try std.testing.expectEqualStrings("error", stream.errorText());
    try std.testing.expect(!stream.retryable());

    const long = "x" ** (stream.error_buffer.len + 1);
    try std.testing.expectError(error.ApiError, stream.decode(
        "{\"type\":\"error\",\"error\":{\"message\":\"" ++ long ++ "\"}}",
    ));
    try std.testing.expectEqualStrings(long[0..stream.error_buffer.len], stream.errorText());
}

test "describeError reduces a failed head's error body to its message" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();

    try std.testing.expectEqualStrings("invalid x-api-key", (try stream.describeError(
        \\{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}
    )).?);

    try std.testing.expectEqual(@as(?[]const u8, null), try stream.describeError(
        \\{"type":"error","error":{"message":"cut off
    ));
    try std.testing.expectEqual(@as(?[]const u8, null), try stream.describeError(
        \\{"type":"error","error":{}}
    ));
}

test "next times out on buffered filler that makes no progress" {
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

    try std.testing.expectError(error.Timeout, stream.next());
}

test "next stops a stream once its aggregate byte budget is spent" {
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

test "connect rejects credentials that split the request head" {
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

    const keyed = requestOptions(.{ .api_key = "sk-key" }, "", &extra);
    try std.testing.expect(keyed.headers.authorization == .default);
    try std.testing.expect(keyed.headers.user_agent == .default);
    try std.testing.expectEqualStrings("identity", keyed.headers.accept_encoding.override);
    try std.testing.expectEqual(@as(usize, 3), keyed.extra_headers.len);
    try std.testing.expectEqualStrings("x-api-key", keyed.extra_headers[0].name);
    try std.testing.expectEqualStrings("sk-key", keyed.extra_headers[0].value);
    try std.testing.expectEqualStrings("anthropic-version", keyed.extra_headers[1].name);
    try std.testing.expectEqualStrings("anthropic-beta", keyed.extra_headers[2].name);
    try std.testing.expectEqualStrings(streaming_beta, keyed.extra_headers[2].value);
}

test "every identity asks for streamed tool input" {
    var extra: [3]std.http.Header = undefined;
    const subscription = requestOptions(.{ .subscription = "tok" }, "Bearer tok", &extra);
    try std.testing.expect(std.mem.indexOf(
        u8,
        subscription.extra_headers[1].value,
        streaming_beta,
    ) != null);

    const keyed = requestOptions(.{ .api_key = "sk-key" }, "", &extra);
    try std.testing.expect(std.mem.indexOf(
        u8,
        keyed.extra_headers[2].value,
        streaming_beta,
    ) != null);
}

fn serveOneResponse(io: std.Io, server: *std.Io.net.Server) !void {
    const body = "data: {\"type\":\"ping\"}\n\n";
    var connection = try server.accept(io);
    defer connection.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = connection.reader(io, &read_buffer);
    var content_length: usize = 0;
    var lines_left: usize = 64;
    while (lines_left > 0) : (lines_left -= 1) {
        const raw = try reader.interface.takeDelimiterInclusive('\n');
        const line = std.mem.trimEnd(u8, raw, "\r\n");
        if (line.len == 0) break;
        const label = "content-length:";
        if (std.ascii.startsWithIgnoreCase(line, label)) {
            const value = std.mem.trim(u8, line[label.len..], " \t");
            content_length = try std.fmt.parseInt(usize, value, 10);
        }
    }
    try reader.interface.discardAll(content_length);

    var write_buffer: [512]u8 = undefined;
    var writer = connection.writer(io, &write_buffer);
    try writer.interface.print(
        "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n" ++
            "content-length: {d}\r\nconnection: close\r\n\r\n{s}",
        .{ body.len, body },
    );
    try writer.interface.flush();
}

test "the stream owns the request Authorization value for its whole lifetime" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const endpoint = try std.fmt.allocPrint(
        gpa,
        "http://127.0.0.1:{d}/v1/messages",
        .{server.socket.address.getPort()},
    );
    defer gpa.free(endpoint);

    var serve = try io.concurrent(serveOneResponse, .{ io, &server });
    var reaped = false;
    defer if (!reaped) {
        _ = serve.cancel(io) catch {};
    };

    var transport: Transport = .{
        .gpa = gpa,
        .io = io,
        .timeouts = .{},
        .identity = .{ .subscription = "secret-token" },
        .endpoint = endpoint,
    };
    var stream: Stream = undefined;
    try transport.send(&stream, "{}");
    defer stream.deinit();
    reaped = true;
    try serve.await(io);

    try std.testing.expectEqualStrings(
        "Bearer secret-token",
        stream.request.headers.authorization.override,
    );
    try std.testing.expect((try stream.next()) == null);
}
