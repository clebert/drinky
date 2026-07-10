//! The Messages API transport: sends a serialized request with the OAuth
//! identity headers and exposes the response as a pull stream of decoded SSE
//! events. Knows nothing about conversation state or tools — it turns bytes
//! into `Event`s.

const std = @import("std");

const llm = @import("../llm.zig");

const Transport = @This();

const messages_url = "https://api.anthropic.com/v1/messages";
const beta = "claude-code-20250219,oauth-2025-04-20";

gpa: std.mem.Allocator,
io: std.Io,

/// A single Messages request in flight. Pin it: the HTTP response borrows the
/// request and the SSE reader borrows this struct's buffers.
pub const Stream = struct {
    gpa: std.mem.Allocator,
    client: std.http.Client,
    request: std.http.Client.Request,
    response: std.http.Client.Response,
    body: *std.Io.Reader,
    status: std.http.Status,
    error_length: usize,
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

    /// Next decoded event, or null at end of stream.
    pub fn next(self: *Stream) !?llm.Event {
        if (self.parsed) |parsed| {
            parsed.deinit();
            self.parsed = null;
        }
        while (true) {
            const line = (try self.body.takeDelimiter('\n')) orelse return null;
            const trimmed = std.mem.trimEnd(u8, line, "\r");
            if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
            const payload = std.mem.trimStart(u8, trimmed["data:".len..], " ");
            if (try self.decode(payload)) |event| return event;
        }
    }

    fn decode(self: *Stream, json: []const u8) !?llm.Event {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.gpa, json, .{});
        const object = asObject(parsed.value) orelse {
            parsed.deinit();
            return null;
        };
        const kind = asString(object.get("type")) orelse {
            parsed.deinit();
            return null;
        };

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
            return null;
        }

        const event = classify(object, kind) orelse {
            parsed.deinit();
            return null;
        };
        switch (event) {
            .stop => |stop| {
                if (asObject(object.get("usage"))) |usage| mergeUsage(&self.usage, usage);
                self.parsed = parsed;
                return .{ .stop = .{ .reason = stop.reason, .usage = self.usage } };
            },
            else => {
                self.parsed = parsed;
                return event;
            },
        }
    }

    fn recordError(self: *Stream, message: []const u8) void {
        self.error_length = @min(message.len, self.error_buffer.len);
        @memcpy(self.error_buffer[0..self.error_length], message[0..self.error_length]);
    }
};

/// Open a streaming Messages request, filling `out` in place.
pub fn send(self: *Transport, out: *Stream, body: []const u8, access_token: []const u8) !void {
    out.gpa = self.gpa;
    out.client = .{ .allocator = self.gpa, .io = self.io };
    errdefer out.client.deinit();
    out.parsed = null;
    out.error_length = 0;
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
    }
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
        return null;
    }
    if (std.mem.eql(u8, kind, "content_block_start")) {
        const block = asObject(object.get("content_block")) orelse return null;
        if (!std.mem.eql(u8, asString(block.get("type")) orelse return null, "tool_use")) return null;
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
}

test "next walks SSE data lines and ends at stream end" {
    const body =
        "event: message_start\r\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"usage\":" ++
        "{\"input_tokens\":10,\"cache_read_input_tokens\":90,\"cache_creation_input_tokens\":5,\"output_tokens\":1}}}\r\n" ++
        "\r\n" ++
        "event: content_block_delta\r\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}\r\n" ++
        "\r\n" ++
        "event: message_delta\r\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":42}}\r\n" ++
        "\r\n";
    var reader: std.Io.Reader = .fixed(body);
    var stream: Stream = undefined;
    stream.gpa = std.testing.allocator;
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
