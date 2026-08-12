//! The Responses API transport. It sends a serialized request to a configured
//! endpoint with the correct auth identity. It exposes the response as a pull
//! stream of decoded SSE `response.*` events on the shared `sse` engine.
//! The API-key and ChatGPT-subscription providers share it and differ only
//! in `endpoint` and whether `account_id` is set. It knows nothing about
//! conversation state or tools.

const std = @import("std");

const json = @import("../json.zig");
const llm = @import("../llm.zig");
const net = @import("../net.zig");
const sse = @import("../sse.zig");

const Transport = @This();

/// The header value that identifies this client on the ChatGPT-subscription backend.
const originator = "pith";

gpa: std.mem.Allocator,
io: std.Io,
timeouts: net.Timeouts,
/// The full request URL: `https://api.openai.com/v1/responses` for API-key
/// mode, the Codex backend for subscription mode.
endpoint: []const u8,
/// The ChatGPT account id, sent as `chatgpt-account-id`. It is empty in
/// API-key mode, which sends no account or originator header.
account_id: []const u8,

/// A single Responses request in flight on the shared SSE engine. The engine
/// supplies the reading half. This struct keeps the Responses frame vocabulary
/// (`decode`). Responses sends no keepalive pings, so only `response.*` frames
/// are progress. Pin it: the HTTP response borrows the request and the SSE
/// reader borrows this struct's buffers.
pub const Stream = struct {
    gpa: std.mem.Allocator,
    /// Set last by a full connect. The timeout path of `sse.Engine.open` frees
    /// only an established stream.
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
    /// Scratch for one decoded frame. Events can borrow it until the next read.
    frame_arena: std.heap.ArenaAllocator,
    /// A wire outcome already known to make this reply unretainable. It stays
    /// latched until the terminal response supplies usage. Unsupported overrides
    /// invalid.
    terminal_rejection: ?llm.Event.Stop.Rejection,
    /// An incomplete message item is retainable only if the response itself
    /// terminates as incomplete.
    incomplete_message: bool,
    /// Where the streamed reasoning display stands (see `sse.Reasoning`).
    reasoning: sse.Reasoning,
    /// The `summary_index` of the reasoning part now streaming. An index that
    /// differs from it ends the part before it, so a stream that sends no
    /// `reasoning_summary_part.added` frame still separates its parts.
    summary_index: i64,
    /// Completed native item ids already emitted. `output_item.done` is
    /// independently authoritative, but duplicate done frames must not duplicate
    /// neutral history.
    completed_item_ids: std.StringHashMapUnmanaged(void),
    usage: llm.Usage,
    /// The subscription allowance from the response head, or null when the
    /// backend sent no quota headers (API-key mode, or none present).
    quota: ?llm.Quota,
    decompress: std.http.Decompress,
    decompress_buffer: []u8,
    /// This buffer backs the request's runtime headers, which must outlive the
    /// send phase (so it is a stream field, not a `connect` local).
    header_buffer: [3]std.http.Header,
    error_buffer: [512]u8,
    redirect_buffer: [4096]u8,
    transfer_buffer: [16384]u8,

    const ItemStatus = enum { completed, incomplete };
    const OutputItem = union(enum) {
        other,
        progress,
        invalid,
        unsupported,
        event: llm.Event,
    };
    const engine = sse.Engine(Stream);
    pub const deinit = engine.deinit;
    pub const ok = engine.ok;
    pub const errorText = engine.errorText;
    pub const retryable = engine.retryable;
    pub const retryAfterMs = engine.retryAfterMs;
    /// The usage accumulated so far. Responses can deliver full counts on a
    /// terminal response event, so this is zero until then or when omitted.
    pub const usageSoFar = engine.usageSoFar;
    pub const next = engine.next;

    pub fn deinitDecode(self: *Stream) void {
        self.frame_arena.deinit();
        var ids = self.completed_item_ids.keyIterator();
        while (ids.next()) |id| self.gpa.free(id.*);
        self.completed_item_ids.deinit(self.gpa);
    }

    /// Capture the subscription allowance from the response head. The engine
    /// calls this while the head is still valid. Null on any backend that omits
    /// the Codex quota headers.
    pub fn captureHead(self: *Stream, head: *const std.http.Client.Response.Head) void {
        self.quota = parseQuota(head);
    }

    /// The subscription allowance captured from the response head (see
    /// `captureHead`), or null on an API-key stream or a head that sent none.
    pub fn quotaSoFar(self: *const Stream) ?llm.Quota {
        return self.quota;
    }

    /// Latch a rejection. `unsupported` wins over `invalid` however they
    /// interleave: resampling cannot turn an outcome this design cannot retain
    /// into one it can, so the retry budget spent on it only delays the same
    /// failure.
    fn markRejection(self: *Stream, rejection: llm.Event.Stop.Rejection) void {
        if (self.terminal_rejection == null or rejection == .unsupported)
            self.terminal_rejection = rejection;
    }

    fn itemStatus(item: *const std.json.ObjectMap) ?ItemStatus {
        const status_value = item.get("status") orelse return .completed;
        const status = json.string(status_value) orelse return null;
        if (std.mem.eql(u8, status, "completed")) return .completed;
        if (std.mem.eql(u8, status, "incomplete")) return .incomplete;
        return null;
    }

    fn recordCompletedItem(self: *Stream, id: []const u8) !bool {
        if (id.len == 0) return false;
        const result = try self.completed_item_ids.getOrPut(self.gpa, id);
        if (result.found_existing) return false;
        errdefer _ = self.completed_item_ids.remove(id);
        result.key_ptr.* = try self.gpa.dupe(u8, id);
        return true;
    }

    /// Latch any rejection a terminal snapshot item's own shape reveals. The done
    /// frame alone supplies payloads, so nothing here is retained. A snapshot
    /// that disagrees with it only rejects the reply.
    fn markTerminalItemRejection(self: *Stream, item: *const std.json.ObjectMap) void {
        const kind = json.string(item.get("type")) orelse return self.markRejection(.invalid);
        if (std.mem.eql(u8, kind, "reasoning") or
            std.mem.eql(u8, kind, "function_call")) return;
        if (!std.mem.eql(u8, kind, "message")) return self.markRejection(.unsupported);
        const content = json.array(item.get("content")) orelse
            return self.markRejection(.invalid);
        for (content.items) |value| {
            const part = json.object(value) orelse return self.markRejection(.invalid);
            const part_kind = json.string(part.get("type")) orelse
                return self.markRejection(.invalid);
            if (!std.mem.eql(u8, part_kind, "output_text"))
                return self.markRejection(.unsupported);
        }
    }

    /// When a terminal response includes its output snapshot, use it only to
    /// prove the independently authoritative done-item set is complete. Payloads
    /// still come exclusively from `output_item.done`.
    fn reconcileTerminalOutput(
        self: *Stream,
        response: *const std.json.ObjectMap,
    ) !void {
        const output_value = response.get("output") orelse return;
        const output = json.array(output_value) orelse {
            self.markRejection(.invalid);
            return;
        };
        // The Codex subscription backend closes with an empty output snapshot
        // under store:false and does not echo the streamed items. Done frames
        // are independently authoritative, so an empty snapshot is no
        // disagreement. Only a populated snapshot is worth a cross-check.
        if (output.items.len == 0) return;
        var terminal_ids: std.StringHashMapUnmanaged(void) = .empty;
        for (output.items) |value| {
            const item = json.object(value) orelse {
                self.markRejection(.invalid);
                continue;
            };
            self.markTerminalItemRejection(&item);
            const id = json.string(item.get("id")) orelse {
                self.markRejection(.invalid);
                continue;
            };
            const result = try terminal_ids.getOrPut(self.frame_arena.allocator(), id);
            if (result.found_existing) {
                self.markRejection(.invalid);
                continue;
            }
            if (!self.completed_item_ids.contains(id)) self.markRejection(.invalid);
        }
        if (terminal_ids.count() != self.completed_item_ids.count())
            self.markRejection(.invalid);
    }

    fn joinedSummary(self: *Stream, item: *const std.json.ObjectMap) !?[]const u8 {
        const summary = json.array(item.get("summary")) orelse return null;
        var text: std.ArrayList(u8) = .empty;
        for (summary.items, 0..) |value, index| {
            const part = json.object(value) orelse return null;
            const kind = json.string(part.get("type")) orelse return null;
            if (!std.mem.eql(u8, kind, "summary_text")) return null;
            const part_text = json.string(part.get("text")) orelse return null;
            if (index != 0) try text.appendSlice(self.frame_arena.allocator(), "\n\n");
            try text.appendSlice(self.frame_arena.allocator(), part_text);
        }
        return text.items;
    }

    fn outputItem(self: *Stream, object: *const std.json.ObjectMap, kind: []const u8) !OutputItem {
        if (!std.mem.eql(u8, kind, "response.output_item.done")) return .other;
        const item = json.object(object.get("item")) orelse return .invalid;
        const item_kind = json.string(item.get("type")) orelse return .invalid;
        const id = json.string(item.get("id")) orelse return .invalid;
        const status = itemStatus(&item) orelse return .invalid;
        if (!try self.recordCompletedItem(id)) return .invalid;

        if (std.mem.eql(u8, item_kind, "message")) {
            if (item.get("role")) |role_value| {
                const role = json.string(role_value) orelse return .invalid;
                if (!std.mem.eql(u8, role, "assistant")) return .invalid;
            }
            const content = json.array(item.get("content")) orelse return .invalid;
            var text: std.ArrayList(u8) = .empty;
            for (content.items) |value| {
                const part = json.object(value) orelse return .invalid;
                const part_kind = json.string(part.get("type")) orelse return .invalid;
                if (!std.mem.eql(u8, part_kind, "output_text")) return .unsupported;
                const part_text = json.string(part.get("text")) orelse return .invalid;
                try text.appendSlice(self.frame_arena.allocator(), part_text);
            }
            if (text.items.len == 0) return .invalid;
            if (status == .incomplete) self.incomplete_message = true;
            return .{ .event = .{ .item = .{ .message = text.items } } };
        }
        if (std.mem.eql(u8, item_kind, "reasoning")) {
            // The display of this item ends here, whatever the item retains.
            // The next reasoning text comes from a new item and needs a seam.
            // A new item restarts `summary_index`, so the index alone cannot
            // mark that seam.
            self.reasoning.end();
            if (status != .completed) return .invalid;
            const encrypted_content = json.string(item.get("encrypted_content")) orelse
                return .invalid;
            if (id.len == 0 or encrypted_content.len == 0) return .invalid;
            const text = try self.joinedSummary(&item) orelse return .invalid;
            return .{ .event = .{ .item = .{ .reasoning = .{ .encrypted = .{
                .text = text,
                .id = id,
                .encrypted_content = encrypted_content,
            } } } } };
        }
        if (std.mem.eql(u8, item_kind, "function_call")) {
            if (status != .completed) return .invalid;
            const call_id = json.string(item.get("call_id")) orelse return .invalid;
            const name = json.string(item.get("name")) orelse return .invalid;
            const arguments = json.string(item.get("arguments")) orelse return .invalid;
            if (call_id.len == 0) return .invalid;
            return .{ .event = .{ .item = .{ .tool_call = .{
                .call_id = call_id,
                .name = name,
                .arguments_json = arguments,
            } } } };
        }
        return .unsupported;
    }

    /// One display frame of the reasoning part `index`, either the part itself
    /// or one of its text deltas. An index that differs from the open one ends
    /// the part before it. A part frame carries no text of its own in practice,
    /// so the seam then waits for the deltas that follow it.
    fn summaryPart(self: *Stream, index: i64, text: []const u8) !sse.Decoded {
        if (index != self.summary_index) self.reasoning.end();
        self.summary_index = index;
        return self.reasoning.display(self.frame_arena.allocator(), text);
    }

    /// The `summary_index` of one reasoning frame, or null when the frame holds
    /// no valid index.
    fn summaryIndex(object: *const std.json.ObjectMap) ?i64 {
        const index = json.integer(object.get("summary_index")) orelse return null;
        return if (index < 0) null else index;
    }

    /// A summary part of the open reasoning item.
    fn reasoningPartAdded(self: *Stream, object: *const std.json.ObjectMap) !sse.Decoded {
        const index = summaryIndex(object) orelse return .progress;
        const part = json.object(object.get("part")) orelse return .progress;
        const kind = json.string(part.get("type")) orelse return .progress;
        if (!std.mem.eql(u8, kind, "summary_text")) return .progress;
        const text = json.string(part.get("text")) orelse return .progress;
        return self.summaryPart(index, text);
    }

    /// Decode one Responses `data:` payload.
    pub fn decode(self: *Stream, payload: []const u8) !sse.Decoded {
        // Some deployments close the stream with a Chat-Completions-style
        // sentinel. The Agent still requires a preceding terminal event.
        if (std.mem.eql(u8, payload, "[DONE]")) return .done;
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

        if (std.mem.eql(u8, kind, "error") or std.mem.eql(u8, kind, "response.failed")) {
            engine.recordError(
                self,
                errorMessage(object) orelse kind,
                errorRetryable(&object),
            );
            return error.ApiError;
        }
        if (std.mem.eql(u8, kind, "response.refusal.delta") or
            std.mem.eql(u8, kind, "response.refusal.done"))
        {
            self.markRejection(.unsupported);
            return .progress;
        }
        if (std.mem.eql(u8, kind, "response.output_text.delta")) {
            const delta = json.string(object.get("delta")) orelse return .progress;
            // The answer ends the reasoning display, and a delta with no bytes
            // displays nothing (see `sse.Reasoning`).
            if (!self.reasoning.answer(delta)) return .progress;
            return .{ .event = .{ .text = delta } };
        }
        if (std.mem.eql(u8, kind, "response.reasoning_summary_text.delta")) {
            const delta = json.string(object.get("delta")) orelse return .progress;
            // A frame with no index of its own continues the open part.
            return self.summaryPart(summaryIndex(&object) orelse self.summary_index, delta);
        }
        if (std.mem.eql(u8, kind, "response.reasoning_summary_part.added"))
            return self.reasoningPartAdded(&object);
        if (std.mem.eql(u8, kind, "response.reasoning_summary_text.done") or
            std.mem.eql(u8, kind, "response.reasoning_summary_part.done") or
            std.mem.eql(u8, kind, "response.function_call_arguments.delta") or
            std.mem.eql(u8, kind, "response.function_call_arguments.done"))
        {
            return .progress;
        }

        switch (try self.outputItem(&object, kind)) {
            .other => {},
            .progress => return .progress,
            .invalid => {
                self.markRejection(.invalid);
                return .progress;
            },
            .unsupported => {
                self.markRejection(.unsupported);
                return .progress;
            },
            .event => |event| return .{ .event = event },
        }

        const status: ?llm.Event.Status = if (std.mem.eql(u8, kind, "response.completed"))
            .complete
        else if (std.mem.eql(u8, kind, "response.incomplete"))
            .truncated
        else
            null;
        if (status) |terminal_status| {
            if (json.object(object.get("response"))) |response| {
                try self.reconcileTerminalOutput(&response);
            } else {
                self.markRejection(.invalid);
            }
            if (terminal_status == .complete and self.incomplete_message)
                self.markRejection(.invalid);
            if (completedUsage(object)) |usage| mergeUsage(&self.usage, usage);
            return .{ .event = .{ .stop = .{
                .usage = self.usage,
                .status = terminal_status,
                .rejection = self.terminal_rejection,
            } } };
        }
        return if (std.mem.startsWith(u8, kind, "response.")) .progress else .ignored;
    }
};

/// One request's confusable string pair, named so body and token cannot swap.
pub const Payload = struct { body: []const u8, access_token: []const u8 };

/// Open a streaming Responses request bounded by the connect timeout. On any
/// failure this call tears down `out`, so a caller that sees an error owns
/// nothing (see `sse.Engine.open`).
pub fn send(self: *Transport, out: *Stream, payload: Payload) !void {
    return sse.Engine(Stream).open(out, self.io, self.timeouts, connect, .{ self, out, payload });
}

fn connect(self: *Transport, out: *Stream, payload: Payload) anyerror!void {
    // Credentials become header values. Reject values that can split the head.
    if (!net.validHeaderValue(payload.access_token) or
        (self.account_id.len != 0 and !net.validHeaderValue(self.account_id)))
    {
        return error.BadCredentials;
    }
    const engine = sse.Engine(Stream);
    engine.begin(out, self.gpa, self.io);
    errdefer out.client.deinit();
    errdefer out.frame_arena.deinit();
    out.terminal_rejection = null;
    out.incomplete_message = false;
    out.reasoning = .none;
    out.summary_index = 0;
    out.completed_item_ids = .empty;
    out.quota = null;

    const authorization = try std.fmt.allocPrint(self.gpa, "Bearer {s}", .{payload.access_token});
    defer self.gpa.free(authorization);

    // Duped at connect scope like the Bearer value above, so no header borrows
    // Auth-owned storage for the stream's lifetime. A token refresh could free
    // that storage out from under a live stream.
    const maybe_account_id: ?[]u8 = if (self.account_id.len != 0)
        try self.gpa.dupe(u8, self.account_id)
    else
        null;
    defer if (maybe_account_id) |account_id| self.gpa.free(account_id);

    // Subscription mode adds the account and originator identity. API-key mode
    // sends neither. `accept` requests the event stream in both.
    var extra_len: usize = 0;
    out.header_buffer[extra_len] = .{ .name = "accept", .value = "text/event-stream" };
    extra_len += 1;
    if (maybe_account_id) |account_id| {
        out.header_buffer[extra_len] = .{ .name = "chatgpt-account-id", .value = account_id };
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

    try engine.finish(out, payload.body);
}

/// The optional `usage` object nested under a terminal frame's response.
fn completedUsage(object: std.json.ObjectMap) ?std.json.ObjectMap {
    const response = json.object(object.get("response")) orelse return null;
    return json.object(response.get("usage"));
}

fn errorMessage(object: std.json.ObjectMap) ?[]const u8 {
    if (json.string(object.get("message"))) |message| return message;
    if (json.object(object.get("error"))) |detail| {
        if (json.string(detail.get("message"))) |message| return message;
    }
    if (json.object(object.get("response"))) |response| {
        if (json.object(response.get("error"))) |detail| return json.string(detail.get("message"));
    }
    return null;
}

fn errorRetryable(object: *const std.json.ObjectMap) bool {
    const code = errorCode(object) orelse return false;
    return std.mem.eql(u8, code, "server_error") or
        std.mem.eql(u8, code, "rate_limit_exceeded");
}

fn errorCode(object: *const std.json.ObjectMap) ?[]const u8 {
    if (json.string(object.get("code"))) |code| return code;
    if (json.object(object.get("error"))) |detail| {
        if (json.string(detail.get("code"))) |code| return code;
    }
    if (json.object(object.get("response"))) |response| {
        if (json.object(response.get("error"))) |detail| return json.string(detail.get("code"));
    }
    return null;
}

/// Fold a `response.usage` object into the running total. `input_tokens`
/// partitions into three disjoint buckets: cache reads, cache writes, and the
/// uncached remainder. Each bucket has its own rate (the gpt-5.6 family bills
/// cache writes at a premium). `output_tokens` already counts reasoning tokens.
fn mergeUsage(usage: *llm.Usage, object: std.json.ObjectMap) void {
    const total_input = json.unsigned(object.get("input_tokens")) orelse 0;
    var cached: u64 = 0;
    var written: u64 = 0;
    if (json.object(object.get("input_tokens_details"))) |details| {
        cached = json.unsigned(details.get("cached_tokens")) orelse 0;
        written = json.unsigned(details.get("cache_write_tokens")) orelse 0;
    }
    usage.cache_read = cached;
    usage.cache_write = written;
    usage.input = total_input -| cached -| written;
    if (json.unsigned(object.get("output_tokens"))) |value| usage.output = value;
}

/// Parse the Codex subscription allowance from the response head. A window is
/// present only when its `used-percent` header is. Its `window-minutes` can be
/// absent. Null when the head has no quota headers at all: an API-key
/// response, or a backend that sends none.
fn parseQuota(head: *const std.http.Client.Response.Head) ?llm.Quota {
    var primary_used: ?f64 = null;
    var primary_minutes: ?u32 = null;
    var secondary_used: ?f64 = null;
    var secondary_minutes: ?u32 = null;
    var headers = head.iterateHeaders();
    while (headers.next()) |header| {
        const value = std.mem.trim(u8, header.value, " \t");
        if (std.ascii.eqlIgnoreCase(header.name, "x-codex-primary-used-percent")) {
            primary_used = parseQuotaPercent(value);
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-codex-primary-window-minutes")) {
            primary_minutes = std.fmt.parseInt(u32, value, 10) catch null;
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-codex-secondary-used-percent")) {
            secondary_used = parseQuotaPercent(value);
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-codex-secondary-window-minutes")) {
            secondary_minutes = std.fmt.parseInt(u32, value, 10) catch null;
        }
    }
    const primary: ?llm.Quota.Window = if (primary_used) |used|
        .{ .used_percent = used, .window_minutes = primary_minutes }
    else
        null;
    const secondary: ?llm.Quota.Window = if (secondary_used) |used|
        .{ .used_percent = used, .window_minutes = secondary_minutes }
    else
        null;
    if (primary == null and secondary == null) return null;
    return .{ .primary = primary, .secondary = secondary };
}

/// Decode a percentage only inside its finite semantic range. `parseFloat`
/// accepts NaN and infinities, which must not turn malformed provider data into
/// a plausible remaining-allowance gauge.
fn parseQuotaPercent(value: []const u8) ?f64 {
    const percent = std.fmt.parseFloat(f64, value) catch return null;
    if (!std.math.isFinite(percent) or percent < 0 or percent > 100) return null;
    return percent;
}

/// A stream over `body` for the tests: test allocator, fresh decode state, and
/// the given window and budget. The connection fields stay undefined. Pair with
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
    stream.status = .ok;
    stream.error_length = 0;
    stream.error_retryable = false;
    stream.frame_arena = .init(gpa);
    stream.terminal_rejection = null;
    stream.incomplete_message = false;
    stream.reasoning = .none;
    stream.summary_index = 0;
    stream.completed_item_ids = .empty;
    stream.usage = .{};
    stream.quota = null;
    return stream;
}

test parseQuota {
    const both = "HTTP/1.1 200 OK\r\n" ++
        "x-codex-primary-used-percent: 11.5\r\n" ++
        "x-codex-primary-window-minutes: 300\r\n" ++
        "x-codex-secondary-used-percent: 74\r\n" ++
        "x-codex-secondary-window-minutes: 10080\r\n" ++
        "content-length:0\r\n\r\n";
    const both_head = try std.http.Client.Response.Head.parse(both);
    const quota = parseQuota(&both_head).?;
    try std.testing.expectEqual(@as(f64, 11.5), quota.primary.?.used_percent);
    try std.testing.expectEqual(@as(?u32, 300), quota.primary.?.window_minutes);
    try std.testing.expectEqual(@as(f64, 74), quota.secondary.?.used_percent);
    try std.testing.expectEqual(@as(?u32, 10080), quota.secondary.?.window_minutes);

    // A $20 plan reports only the weekly window: the other slot stays null.
    const weekly = "HTTP/1.1 200 OK\r\n" ++
        "x-codex-secondary-used-percent: 74\r\n" ++
        "x-codex-secondary-window-minutes: 10080\r\n" ++
        "content-length:0\r\n\r\n";
    const weekly_head = try std.http.Client.Response.Head.parse(weekly);
    const weekly_quota = parseQuota(&weekly_head).?;
    try std.testing.expect(weekly_quota.primary == null);
    try std.testing.expectEqual(@as(f64, 74), weekly_quota.secondary.?.used_percent);

    // A used-percent with no window-minutes is retained but cannot be labeled.
    const no_minutes = "HTTP/1.1 200 OK\r\n" ++
        "x-codex-primary-used-percent: 5\r\n" ++
        "content-length:0\r\n\r\n";
    const no_minutes_head = try std.http.Client.Response.Head.parse(no_minutes);
    const partial = parseQuota(&no_minutes_head).?;
    try std.testing.expectEqual(@as(f64, 5), partial.primary.?.used_percent);
    try std.testing.expectEqual(@as(?u32, null), partial.primary.?.window_minutes);

    // No quota headers: null, so a non-subscription response shows nothing.
    const none_head = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 200 OK\r\ncontent-length:0\r\n\r\n",
    );
    try std.testing.expect(parseQuota(&none_head) == null);
}

test "quota percentages reject non-finite and out-of-range values" {
    try std.testing.expectEqual(@as(?f64, 0), parseQuotaPercent("0"));
    try std.testing.expectEqual(@as(?f64, 100), parseQuotaPercent("100"));
    try std.testing.expect(parseQuotaPercent("nan") == null);
    try std.testing.expect(parseQuotaPercent("inf") == null);
    try std.testing.expect(parseQuotaPercent("-inf") == null);
    try std.testing.expect(parseQuotaPercent("-0.1") == null);
    try std.testing.expect(parseQuotaPercent("100.1") == null);
    try std.testing.expect(parseQuotaPercent("not-a-number") == null);
}

test "an empty terminal output snapshot does not reject the streamed reply" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();
    // The message arrives as its own authoritative done frame.
    const message = try stream.decode(
        \\{"type":"response.output_item.done","item":{"id":"msg_1","type":"message","status":"completed","content":[{"type":"output_text","text":"Hello!"}],"role":"assistant"}}
    );
    try std.testing.expectEqualStrings("Hello!", message.event.item.message);
    _ = stream.frame_arena.reset(.retain_capacity);
    // The Codex subscription backend closes with an empty output snapshot under
    // store:false. The reply still stands and is not rejected as invalid.
    const stop = try stream.decode(
        \\{"type":"response.completed","response":{"status":"completed","output":[],"usage":{"input_tokens":5,"output_tokens":2}}}
    );
    try std.testing.expectEqual(llm.Event.Status.complete, stop.event.stop.status);
    try std.testing.expect(stop.event.stop.rejection == null);
}

test "display deltas and completed messages stay separate" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();
    const display = try stream.decode(
        \\{"type":"response.output_text.delta","item_id":"msg_1","delta":"hello"}
    );
    try std.testing.expectEqualStrings("hello", display.event.text);
    _ = stream.frame_arena.reset(.retain_capacity);
    const complete = try stream.decode(
        \\{"type":"response.output_item.done","item":{"type":"message","id":"msg_1","role":"assistant","status":"completed","content":[{"type":"output_text","text":"hello"}]}}
    );
    try std.testing.expectEqualStrings("hello", complete.event.item.message);
}

test "one native message canonically joins its output text parts" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();

    const complete = try stream.decode(
        \\{"type":"response.output_item.done","item":{"type":"message","id":"msg_1","role":"assistant","status":"completed","content":[{"type":"output_text","text":"hello "},{"type":"output_text","text":"world"}]}}
    );
    try std.testing.expectEqualStrings("hello world", complete.event.item.message);
}

test "incomplete messages survive only an incomplete terminal response" {
    var truncated = testStream(undefined, undefined, 0, 0);
    defer truncated.deinitDecode();

    const message = try truncated.decode(
        \\{"type":"response.output_item.done","item":{"type":"message","id":"msg_1","role":"assistant","status":"incomplete","content":[{"type":"output_text","text":"partial"}]}}
    );
    try std.testing.expectEqualStrings("partial", message.event.item.message);
    _ = truncated.frame_arena.reset(.retain_capacity);
    const incomplete = try truncated.decode(
        \\{"type":"response.incomplete","response":{"status":"incomplete"}}
    );
    try std.testing.expectEqual(llm.Event.Status.truncated, incomplete.event.stop.status);
    try std.testing.expect(incomplete.event.stop.rejection == null);

    var completed = testStream(undefined, undefined, 0, 0);
    defer completed.deinitDecode();
    _ = try completed.decode(
        \\{"type":"response.output_item.done","item":{"type":"message","id":"msg_2","role":"assistant","status":"incomplete","content":[{"type":"output_text","text":"partial"}]}}
    );
    _ = completed.frame_arena.reset(.retain_capacity);
    const invalid = try completed.decode(
        \\{"type":"response.completed","response":{"status":"completed"}}
    );
    try std.testing.expectEqual(llm.Event.Stop.Rejection.invalid, invalid.event.stop.rejection.?);
}

test "done items are authoritative without added lifecycle state" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();

    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"provisional"}}
    ));
    _ = stream.frame_arena.reset(.retain_capacity);
    const complete = try stream.decode(
        \\{"type":"response.output_item.done","output_index":1,"item":{"type":"message","id":"authoritative","role":"assistant","status":"completed","content":[{"type":"output_text","text":"done"}]}}
    );
    try std.testing.expectEqualStrings("done", complete.event.item.message);
}

test "duplicate completed item ids latch invalid" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();

    _ = try stream.decode(
        \\{"type":"response.output_item.done","item":{"type":"message","id":"msg_1","role":"assistant","content":[{"type":"output_text","text":"once"}]}}
    );
    _ = stream.frame_arena.reset(.retain_capacity);
    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"response.output_item.done","item":{"type":"message","id":"msg_1","role":"assistant","content":[{"type":"output_text","text":"twice"}]}}
    ));
    _ = stream.frame_arena.reset(.retain_capacity);
    const stop = try stream.decode(
        \\{"type":"response.completed","response":{"status":"completed"}}
    );
    try std.testing.expectEqual(llm.Event.Stop.Rejection.invalid, stop.event.stop.rejection.?);
}

test "unsupported completed items reject the whole response" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();

    _ = try stream.decode(
        \\{"type":"response.output_item.done","item":{"type":"message","id":"msg_1","role":"assistant","content":[{"type":"output_text","text":"recognized"}]}}
    );
    _ = stream.frame_arena.reset(.retain_capacity);
    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"response.output_item.done","item":{"type":"web_search_call","id":"search_1","status":"completed"}}
    ));
    _ = stream.frame_arena.reset(.retain_capacity);
    const stop = try stream.decode(
        \\{"type":"response.completed","response":{"status":"completed","usage":{"output_tokens":4}}}
    );
    try std.testing.expectEqual(llm.Event.Stop.Rejection.unsupported, stop.event.stop.rejection.?);
    try std.testing.expectEqual(@as(u64, 4), stop.event.stop.usage.output);
}

test "terminal output validates the complete done-item set" {
    var missing = testStream(undefined, undefined, 0, 0);
    defer missing.deinitDecode();

    _ = try missing.decode(
        \\{"type":"response.output_item.done","item":{"type":"message","id":"msg_1","role":"assistant","content":[{"type":"output_text","text":"one"}]}}
    );
    _ = missing.frame_arena.reset(.retain_capacity);
    const incomplete_set = try missing.decode(
        \\{"type":"response.completed","response":{"status":"completed","output":[{"type":"message","id":"msg_1","role":"assistant","content":[{"type":"output_text","text":"one"}]},{"type":"message","id":"msg_2","role":"assistant","content":[{"type":"output_text","text":"two"}]}]}}
    );
    try std.testing.expectEqual(
        llm.Event.Stop.Rejection.invalid,
        incomplete_set.event.stop.rejection.?,
    );

    var unsupported = testStream(undefined, undefined, 0, 0);
    defer unsupported.deinitDecode();
    const unsupported_output = try unsupported.decode(
        \\{"type":"response.completed","response":{"status":"completed","output":[{"type":"web_search_call","id":"search_1","status":"completed"}]}}
    );
    try std.testing.expectEqual(
        llm.Event.Stop.Rejection.unsupported,
        unsupported_output.event.stop.rejection.?,
    );
}

test "reasoning deltas are display-only and done items are authoritative" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();

    try std.testing.expectEqualStrings("a", (try stream.decode(
        \\{"type":"response.reasoning_summary_text.delta","item_id":"display_only","summary_index":0,"delta":"a"}
    )).event.thinking);
    _ = stream.frame_arena.reset(.retain_capacity);
    // A part frame with no text displays nothing. Its seam waits for the delta.
    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"response.reasoning_summary_part.added","item_id":"display_only","summary_index":1,"part":{"type":"summary_text","text":""}}
    ));
    _ = stream.frame_arena.reset(.retain_capacity);
    try std.testing.expectEqualStrings("\n\nb", (try stream.decode(
        \\{"type":"response.reasoning_summary_text.delta","item_id":"display_only","summary_index":1,"delta":"b"}
    )).event.thinking);
    _ = stream.frame_arena.reset(.retain_capacity);
    const reasoning = (try stream.decode(
        \\{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","status":"completed","summary":[{"type":"summary_text","text":"final a"},{"type":"summary_text","text":"final b"}],"encrypted_content":"enc"}}
    )).event.item.reasoning.encrypted;
    try std.testing.expectEqualStrings("final a\n\nfinal b", reasoning.text);
    try std.testing.expectEqualStrings("rs_1", reasoning.id);
    try std.testing.expectEqualStrings("enc", reasoning.encrypted_content);
}

test "a new reasoning item separates its display from the item before it" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();

    try std.testing.expectEqualStrings("**a**", (try stream.decode(
        \\{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","summary_index":0,"delta":"**a**"}
    )).event.thinking);
    _ = stream.frame_arena.reset(.retain_capacity);
    _ = try stream.decode(
        \\{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","status":"completed","summary":[{"type":"summary_text","text":"**a**"}],"encrypted_content":"enc"}}
    );
    _ = stream.frame_arena.reset(.retain_capacity);
    // The next item restarts `summary_index` at zero, and its empty first part
    // displays nothing. The delta that follows it carries the seam.
    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"response.reasoning_summary_part.added","item_id":"rs_2","summary_index":0,"part":{"type":"summary_text","text":""}}
    ));
    _ = stream.frame_arena.reset(.retain_capacity);
    try std.testing.expectEqualStrings("\n\n**b**", (try stream.decode(
        \\{"type":"response.reasoning_summary_text.delta","item_id":"rs_2","summary_index":0,"delta":"**b**"}
    )).event.thinking);
}

test "a rising summary index separates two parts without a part frame" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();

    try std.testing.expectEqualStrings("**a**", (try stream.decode(
        \\{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","summary_index":0,"delta":"**a**"}
    )).event.thinking);
    _ = stream.frame_arena.reset(.retain_capacity);
    // A deployment can send no part frame at all. The rising index is then the
    // only seam between the two parts.
    try std.testing.expectEqualStrings("\n\n**b**", (try stream.decode(
        \\{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","summary_index":1,"delta":"**b**"}
    )).event.thinking);
    _ = stream.frame_arena.reset(.retain_capacity);
    // A frame of the same part takes no seam.
    try std.testing.expectEqualStrings("c", (try stream.decode(
        \\{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","summary_index":1,"delta":"c"}
    )).event.thinking);
}

test "answer text ends the reasoning display and drops the pending seam" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();

    _ = try stream.decode(
        \\{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","summary_index":0,"delta":"a"}
    );
    _ = stream.frame_arena.reset(.retain_capacity);
    _ = try stream.decode(
        \\{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","status":"completed","summary":[{"type":"summary_text","text":"a"}],"encrypted_content":"enc"}}
    );
    _ = stream.frame_arena.reset(.retain_capacity);
    try std.testing.expectEqualStrings("answer", (try stream.decode(
        \\{"type":"response.output_text.delta","item_id":"msg_1","delta":"answer"}
    )).event.text);
    _ = stream.frame_arena.reset(.retain_capacity);
    // The reasoning that follows the answer opens a block of its own, so it
    // starts on its own text.
    try std.testing.expectEqualStrings("b", (try stream.decode(
        \\{"type":"response.reasoning_summary_text.delta","item_id":"rs_2","summary_index":0,"delta":"b"}
    )).event.thinking);
}

test "an empty delta displays nothing and holds the pending seam" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();

    _ = try stream.decode(
        \\{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","summary_index":0,"delta":"**a**"}
    );
    _ = stream.frame_arena.reset(.retain_capacity);
    _ = try stream.decode(
        \\{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","status":"completed","summary":[{"type":"summary_text","text":"**a**"}],"encrypted_content":"enc"}}
    );
    _ = stream.frame_arena.reset(.retain_capacity);
    // An empty answer delta displays nothing, so it must not end the reasoning
    // display and drop the seam the next item needs.
    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"response.output_text.delta","item_id":"msg_1","delta":""}
    ));
    _ = stream.frame_arena.reset(.retain_capacity);
    // An empty reasoning delta displays nothing either. A blank line on its own
    // would add empty rows to the block.
    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"response.reasoning_summary_text.delta","item_id":"rs_2","summary_index":0,"delta":""}
    ));
    _ = stream.frame_arena.reset(.retain_capacity);
    try std.testing.expectEqualStrings("\n\n**b**", (try stream.decode(
        \\{"type":"response.reasoning_summary_text.delta","item_id":"rs_2","summary_index":0,"delta":"**b**"}
    )).event.thinking);
}

test "invalid completed reasoning items latch through terminal usage" {
    const invalid = [_][]const u8{
        \\{"type":"response.output_item.done","item":{"type":"reasoning","summary":[],"encrypted_content":"enc"}}
        ,
        \\{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","summary":[]}}
        ,
        \\{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","status":"incomplete","summary":[],"encrypted_content":"enc"}}
        ,
        \\{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","summary":[{"type":"other","text":"hmm"}],"encrypted_content":"enc"}}
        ,
    };
    for (invalid) |payload| {
        var stream = testStream(undefined, undefined, 0, 0);
        defer stream.deinitDecode();
        try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(payload));
        _ = stream.frame_arena.reset(.retain_capacity);
        const terminal = try stream.decode(
            \\{"type":"response.completed","response":{"usage":{"input_tokens":7,"output_tokens":3}}}
        );
        try std.testing.expectEqual(
            llm.Event.Stop.Rejection.invalid,
            terminal.event.stop.rejection.?,
        );
        try std.testing.expectEqual(@as(u64, 7), terminal.event.stop.usage.input);
        try std.testing.expectEqual(@as(u64, 3), terminal.event.stop.usage.output);
    }
}

fn decodeReasoningUnderOom(gpa: std.mem.Allocator) !void {
    var stream = testStreamWithAllocator(gpa, undefined, undefined, 0, 0);
    defer stream.deinitDecode();
    _ = try stream.decode(
        \\{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","summary":[{"type":"summary_text","text":"hmm"}],"encrypted_content":"enc"}}
    );
}

fn reconcileTerminalOutputUnderOom(gpa: std.mem.Allocator) !void {
    var stream = testStreamWithAllocator(gpa, undefined, undefined, 0, 0);
    defer stream.deinitDecode();
    _ = try stream.decode(
        \\{"type":"response.output_item.done","item":{"type":"message","id":"msg_1","content":[{"type":"output_text","text":"one"}]}}
    );
    _ = stream.frame_arena.reset(.retain_capacity);
    _ = try stream.decode(
        \\{"type":"response.output_item.done","item":{"type":"message","id":"msg_2","content":[{"type":"output_text","text":"two"}]}}
    );
    _ = stream.frame_arena.reset(.retain_capacity);
    _ = try stream.decode(
        \\{"type":"response.completed","response":{"output":[{"type":"message","id":"msg_1","content":[{"type":"output_text","text":"one"}]},{"type":"message","id":"msg_2","content":[{"type":"output_text","text":"two"}]}]}}
    );
}

test "completed item decoding frees state at every allocation-failure point" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        decodeReasoningUnderOom,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        reconcileTerminalOutputUnderOom,
        .{},
    );
}

test "refusal events latch until terminal usage" {
    const body =
        "data: {\"type\":\"response.refusal.delta\",\"delta\":\"cannot help\"}\n\n" ++
        "data: {\"type\":\"response.refusal.done\",\"refusal\":\"cannot help\"}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"," ++
        "\"usage\":{\"input_tokens\":9,\"output_tokens\":4}}}\n\n";
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var stream = testStream(threaded.io(), &reader, 60_000, net.stream_response_bytes_max);
    defer stream.deinitDecode();

    const stop = (try stream.next()).?.stop;
    try std.testing.expectEqual(llm.Event.Stop.Rejection.unsupported, stop.rejection.?);
    try std.testing.expectEqual(@as(u64, 9), stop.usage.input);
    try std.testing.expectEqual(@as(u64, 4), stop.usage.output);
}

test "invalid function call done latches until terminal usage" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();

    const invalid = [_][]const u8{
        \\{"type":"response.output_item.done","item":{"type":"function_call","id":"fc_1","status":"incomplete","call_id":"call_1","name":"read","arguments":"{}"}}
        ,
        \\{"type":"response.output_item.done","item":{"type":"function_call","id":"fc_2","status":"completed","call_id":"call_1","name":"read"}}
        ,
        \\{"type":"response.output_item.done","item":{"type":"function_call","id":"fc_3","status":"completed","call_id":"","name":"read","arguments":"{}"}}
        ,
        \\{"type":"response.output_item.done","item":{"type":"function_call","id":"fc_4","status":"completed","call_id":"call_1","arguments":"{}"}}
        ,
    };
    for (invalid) |payload| {
        try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(payload));
    }
    const terminal = try stream.decode(
        \\{"type":"response.incomplete","response":{"status":"incomplete","usage":{"input_tokens":8,"output_tokens":2}}}
    );
    try std.testing.expectEqual(
        llm.Event.Stop.Rejection.invalid,
        terminal.event.stop.rejection.?,
    );
    try std.testing.expectEqual(@as(u64, 8), terminal.event.stop.usage.input);
    try std.testing.expectEqual(@as(u64, 2), terminal.event.stop.usage.output);
}

test "next walks response.* SSE lines and maps usage on completion" {
    const body =
        "event: response.reasoning_summary_text.delta\n" ++
        "data: {\"type\":\"response.reasoning_summary_text.delta\"," ++
        "\"item_id\":\"rs_1\",\"summary_index\":0,\"delta\":\"weigh\"}\n" ++
        "\n" ++
        "event: response.output_item.done\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":" ++
        "{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"weigh\"}],\"encrypted_content\":\"enc\"}}\n" ++
        "\n" ++
        "event: response.output_item.added\n" ++
        "data: {\"type\":\"response.output_item.added\",\"item\":" ++
        "{\"id\":\"fc_1\",\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"read\"}}\n" ++
        "\n" ++
        "event: response.function_call_arguments.delta\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\"," ++
        "\"item_id\":\"fc_1\",\"delta\":\"{}\"}\n" ++
        "\n" ++
        "event: response.output_item.done\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{" ++
        "\"id\":\"fc_1\",\"type\":\"function_call\",\"status\":\"completed\"," ++
        "\"call_id\":\"call_1\",\"name\":\"read\",\"arguments\":\"{}\"}}\n" ++
        "\n" ++
        "event: response.output_text.delta\n" ++
        "data: {\"type\":\"response.output_text.delta\"," ++
        "\"item_id\":\"msg_1\",\"delta\":\"done\"}\n" ++
        "\n" ++
        "event: response.output_item.done\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{" ++
        "\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\"," ++
        "\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}}\n" ++
        "\n" ++
        "event: response.completed\n" ++
        "data: {\"type\":\"response.completed\"," ++
        "\"response\":{\"status\":\"completed\",\"usage\":" ++
        "{\"input_tokens\":100,\"input_tokens_details\":{\"cached_tokens\":90}," ++
        "\"output_tokens\":42," ++
        "\"output_tokens_details\":{\"reasoning_tokens\":20}}}}\n" ++
        "\n";
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var stream = testStream(threaded.io(), &reader, 60_000, net.stream_response_bytes_max);
    defer stream.deinitDecode();

    const thinking = (try stream.next()).?;
    try std.testing.expectEqualStrings("weigh", thinking.thinking);
    const reasoning = (try stream.next()).?.item.reasoning.encrypted;
    try std.testing.expectEqualStrings("weigh", reasoning.text);
    try std.testing.expectEqualStrings("enc", reasoning.encrypted_content);
    const call = (try stream.next()).?.item.tool_call;
    try std.testing.expectEqualStrings("read", call.name);
    try std.testing.expectEqualStrings("call_1", call.call_id);
    try std.testing.expectEqualStrings("{}", call.arguments_json);
    try std.testing.expectEqualStrings("done", (try stream.next()).?.text);
    try std.testing.expectEqualStrings("done", (try stream.next()).?.item.message);
    const stop = (try stream.next()).?;
    try std.testing.expectEqual(@as(u64, 10), stop.stop.usage.input);
    try std.testing.expectEqual(@as(u64, 90), stop.stop.usage.cache_read);
    try std.testing.expectEqual(@as(u64, 42), stop.stop.usage.output);
    try std.testing.expectEqual(@as(u64, 0), stop.stop.usage.cache_write);
    try std.testing.expectEqual(@as(?llm.Event, null), try stream.next());
}

test "a streamed function call emits only its authoritative done item" {
    const body =
        "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":" ++
        "{\"id\":\"fc_1\",\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"read\"}}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"fc_1\",\"delta\":\"{}\"}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.done\",\"item_id\":\"fc_1\",\"arguments\":\"{}\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" ++
        "{\"id\":\"fc_1\",\"type\":\"function_call\",\"call_id\":\"call_1\"," ++
        "\"name\":\"read\",\"arguments\":\"{}\"}}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n";
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var stream = testStream(threaded.io(), &reader, 60_000, net.stream_response_bytes_max);
    defer stream.deinitDecode();

    const call = (try stream.next()).?.item.tool_call;
    try std.testing.expectEqualStrings("call_1", call.call_id);
    try std.testing.expectEqualStrings("read", call.name);
    try std.testing.expectEqualStrings("{}", call.arguments_json);
    try std.testing.expectEqual(llm.Event.Status.complete, (try stream.next()).?.stop.status);
    try std.testing.expect((try stream.next()) == null);
}

test "terminal events require a response object" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();

    const malformed = try stream.decode(
        \\{"type":"response.completed"}
    );
    try std.testing.expectEqual(
        llm.Event.Stop.Rejection.invalid,
        malformed.event.stop.rejection.?,
    );
    const decoded = try stream.decode(
        \\{"type":"response.incomplete","response":{}}
    );
    try std.testing.expectEqual(@as(llm.Usage, .{}), decoded.event.stop.usage);
    try std.testing.expectEqual(llm.Event.Status.truncated, decoded.event.stop.status);
}

test "decode maps response.incomplete to a stop carrying its usage" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();

    // A truncated turn is not an error: it stops with the usage the response
    // reports (uncached = 50 - cached 10 - written 5), so accounting stays correct.
    const decoded = try stream.decode(
        \\{"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":50,"input_tokens_details":{"cached_tokens":10,"cache_write_tokens":5},"output_tokens":128000}}}
    );
    try std.testing.expectEqual(@as(u64, 35), decoded.event.stop.usage.input);
    try std.testing.expectEqual(@as(u64, 10), decoded.event.stop.usage.cache_read);
    try std.testing.expectEqual(@as(u64, 5), decoded.event.stop.usage.cache_write);
    try std.testing.expectEqual(@as(u64, 128000), decoded.event.stop.usage.output);
}

test "decode surfaces a streamed error frame" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();

    try std.testing.expectError(error.ApiError, stream.decode(
        \\{"type":"error","message":"rate limit"}
    ));
    try std.testing.expectEqualStrings("rate limit", stream.errorText());
    try std.testing.expect(!stream.retryable());

    try std.testing.expectError(error.ApiError, stream.decode(
        \\{"type":"error","code":"server_error","message":"server failed"}
    ));
    try std.testing.expect(stream.retryable());

    try std.testing.expectError(error.ApiError, stream.decode(
        "{\"type\":\"response.failed\",\"response\":{\"error\":" ++
            "{\"code\":\"rate_limit_exceeded\",\"message\":\"rate limited\"}}}",
    ));
    try std.testing.expectEqualStrings("rate limited", stream.errorText());
    try std.testing.expect(stream.retryable());

    try std.testing.expectError(error.ApiError, stream.decode(
        "{\"type\":\"response.failed\",\"response\":{\"error\":" ++
            "{\"code\":\"invalid_prompt\",\"message\":\"bad request\"}}}",
    ));
    try std.testing.expectEqualStrings("bad request", stream.errorText());
    try std.testing.expect(!stream.retryable());
}

test "decode ignores a malformed data line instead of failing the turn" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();

    try std.testing.expectEqual(@as(sse.Decoded, .ignored), try stream.decode(
        \\{"type":"response.output_text.del
    ));
    try std.testing.expectEqual(@as(sse.Decoded, .ignored), try stream.decode(
        \\not json at all
    ));
}

test "decode ignores unrecognized frames instead of counting them as progress" {
    var stream = testStream(undefined, undefined, 0, 0);
    defer stream.deinitDecode();

    try std.testing.expectEqual(@as(sse.Decoded, .ignored), try stream.decode(
        \\{"type":"surprise.new.event"}
    ));
    try std.testing.expectEqual(@as(sse.Decoded, .ignored), try stream.decode(
        \\{"note":"no type here"}
    ));
    try std.testing.expectEqual(@as(sse.Decoded, .ignored), try stream.decode(
        \\42
    ));
    // A recognized structural `response.*` frame with no event is still progress.
    try std.testing.expectEqual(@as(sse.Decoded, .progress), try stream.decode(
        \\{"type":"response.in_progress","response":{}}
    ));
}

test "next times out on buffered filler that makes no progress" {
    // Only filler: the idle window must trip even though every line is
    // buffered and no read ever blocks on the deadline.
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
    defer stream.deinitDecode();

    // The 100 ms window loses 40 ms per reading, so it closes after a few
    // filler lines — before the trailing real event or EOF.
    try std.testing.expectError(error.Timeout, stream.next());
}

test "next stops a stream once its aggregate byte budget is spent" {
    // Each frame is real progress that restarts the idle window, so only the
    // aggregate byte budget ends the flood. It spans two frames and trips on
    // their sum rather than any single line.
    const frame =
        "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"m1\",\"delta\":\"chunk\"}\n";
    const body = frame ** 5;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var stream = testStream(threaded.io(), &reader, 60_000, frame.len * 2);
    defer stream.deinitDecode();

    try std.testing.expectEqualStrings("chunk", (try stream.next()).?.text);
    try std.testing.expectEqualStrings("chunk", (try stream.next()).?.text);
    try std.testing.expectError(error.StreamResponseTooLarge, stream.next());
}

test "next bounds a flood of eventless progress frames" {
    // Every frame is `.progress`, so `next` loops and returns no event. The
    // aggregate budget must still stop the flood. An Agent-level counter, fed
    // only returned events, could not.
    const frame = "data: {\"type\":\"response.in_progress\"}\n";
    const body = frame ** 100;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var stream = testStream(threaded.io(), &reader, 60_000, frame.len * 3);
    defer stream.deinitDecode();

    try std.testing.expectError(error.StreamResponseTooLarge, stream.next());
}

test "next reads a data frame larger than the reader buffer" {
    // A reasoning item's `encrypted_content` — this provider's real oversized
    // frame — exceeds the 16 KiB production `transfer_buffer`, so the line must
    // stream into the growable line buffer. The chunked reader serves at most
    // 64 bytes per fill, so one line spans several fills.
    const blob = "A" ** 4000;
    const body = "data: {\"type\":\"response.output_item.done\",\"item\":" ++
        "{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[],\"encrypted_content\":\"" ++ blob ++ "\"}}\n";
    var buffer: [256]u8 = undefined;
    var chunked: std.testing.Reader = .init(&buffer, &.{.{ .buffer = body }});
    chunked.artificial_limit = .limited(64);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var stream =
        testStream(threaded.io(), &chunked.interface, 60_000, net.stream_response_bytes_max);
    defer stream.deinitDecode();

    const reasoning = (try stream.next()).?.item.reasoning.encrypted;
    try std.testing.expectEqualStrings("rs_1", reasoning.id);
    try std.testing.expectEqualStrings(blob, reasoning.encrypted_content);
    try std.testing.expect((try stream.next()) == null);
}

test "next rejects a single frame larger than the stream budget" {
    // One frame exceeds the whole budget, so its own read trips the ceiling
    // before the frame is buffered — the per-frame bound.
    const body = "data: {\"type\":\"response.output_text.delta\"," ++
        "\"item_id\":\"msg_1\",\"delta\":\"chunk\"}\n";
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var stream = testStream(threaded.io(), &reader, 60_000, 32);
    defer stream.deinitDecode();

    try std.testing.expectError(error.StreamResponseTooLarge, stream.next());
}

test "next ends the byte stream at a [DONE] sentinel" {
    // The stream never decodes whatever trails the sentinel, so a deployment
    // that closes with [DONE] cannot fail the turn.
    const body =
        "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"m1\",\"delta\":\"hi\"}\n" ++
        "data: [DONE]\n" ++
        "data: not json\n";
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var stream = testStream(threaded.io(), &reader, 60_000, net.stream_response_bytes_max);
    defer stream.deinitDecode();

    try std.testing.expectEqualStrings("hi", (try stream.next()).?.text);
    try std.testing.expectEqual(@as(?llm.Event, null), try stream.next());
}

fn failRead(_: *std.Io.Reader, _: *std.Io.Writer, _: std.Io.Limit) std.Io.Reader.StreamError!usize {
    return error.ReadFailed;
}

test "next refines a canceled connection read into a clean abort" {
    // The reply reader fails at the wire. The connection's recorded read error
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
    try std.testing.expectError(
        error.Timeout,
        transport.send(&stream, .{ .body = "{}", .access_token = "token" }),
    );
}

test "next surfaces a stream truncated mid data-line as a retryable premature end" {
    // The stream must never decode a truncated final line as a frame.
    const body = "data: {\"type\":\"response.out";
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader: std.Io.Reader = .fixed(body);
    var stream = testStream(threaded.io(), &reader, 60_000, net.stream_response_bytes_max);
    defer stream.deinitDecode();

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
    try std.testing.expectError(
        error.BadCredentials,
        connect(&transport, &stream, .{ .body = "{}", .access_token = "token\r\nleaked: value" }),
    );
    transport.account_id = "account\ninjected: value";
    try std.testing.expectError(
        error.BadCredentials,
        connect(&transport, &stream, .{ .body = "{}", .access_token = "token" }),
    );
}
