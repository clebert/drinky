const std = @import("std");

const core = @import("core");

const Dialect = @import("Dialect.zig");
const json = @import("json.zig");
const testing = @import("testing.zig");
const Transport = @import("Transport.zig");

const Messages = @This();

const endpoint = "https://api.anthropic.com/v1/messages";
const anthropic_version = "2023-06-01";
const streaming_beta = "fine-grained-tool-streaming-2025-05-14";
const subscription_beta = "claude-code-20250219,oauth-2025-04-20";
const user_agent = "claude-cli/2.1.75";
const tokens_max_fallback = 4096;
const system_header = "You are Claude Code, Anthropic's official CLI for Claude.";
const redacted_notice = "[redacted thinking]";

gpa: std.mem.Allocator,
options: Options,
reply: Dialect.Reply,
stop_reason: Terminal,
open_block: ?OpenBlock,
block_text: std.ArrayList(u8),
block_proof: std.ArrayList(u8),
tool_call_id: std.ArrayList(u8),
tool_name: std.ArrayList(u8),

pub const Options = struct {
    account: []const u8,
    identity: Identity,
};

pub const IdentifyOptions = struct {
    identity: Identity,
    token: []const u8,
    streams_tool_input: bool = false,
};

pub const Identity = enum {
    subscription,
    console,
    api_key,

    fn sendsSystemHeader(self: Identity) bool {
        return switch (self) {
            .subscription, .console => true,
            .api_key => false,
        };
    }
};

const Stored = struct {
    thinking: []const u8 = "",
    signature: []const u8 = "",
    redacted: []const u8 = "",
};

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

const Terminal = enum { none, complete, truncated, unsupported };

const CacheControl = struct { type: []const u8 = "ephemeral" };

const AdaptiveThinking = struct {
    type: []const u8 = "adaptive",
    display: []const u8 = "summarized",
};

const OutputConfig = struct { effort: []const u8 };

const ThinkingBlock = struct {
    type: []const u8 = "thinking",
    thinking: []const u8,
    signature: []const u8,
};

const RedactedThinkingBlock = struct {
    type: []const u8 = "redacted_thinking",
    data: []const u8,
};

const TextBlock = struct {
    type: []const u8 = "text",
    text: []const u8,
    cache_control: ?CacheControl = null,
};

const ToolUseBlock = struct {
    type: []const u8 = "tool_use",
    id: []const u8,
    name: []const u8,
    input: json.Raw,
    cache_control: ?CacheControl = null,
};

const ToolResultBlock = struct {
    type: []const u8 = "tool_result",
    tool_use_id: []const u8,
    is_error: bool,
    content: []const u8,
    cache_control: ?CacheControl = null,
};

const Breakpoints = struct {
    current: ?usize = null,
    previous: ?usize = null,

    fn carries(self: *const Breakpoints, index: usize) bool {
        return index == self.current or index == self.previous;
    }
};

const vtable: Dialect.VTable = .{
    .prepare = prepare,
    .failure = failure,
    .quota = quota,
    .reset = reset,
    .decode = decode,
    .finish = finish,
};

pub fn init(gpa: std.mem.Allocator, options: Options) Messages {
    return .{
        .gpa = gpa,
        .options = options,
        .reply = .{},
        .stop_reason = .none,
        .open_block = null,
        .block_text = .empty,
        .block_proof = .empty,
        .tool_call_id = .empty,
        .tool_name = .empty,
    };
}

pub fn deinit(self: *Messages) void {
    self.block_text.deinit(self.gpa);
    self.block_proof.deinit(self.gpa);
    self.tool_call_id.deinit(self.gpa);
    self.tool_name.deinit(self.gpa);
    self.reply.deinit(self.gpa);
}

pub fn dialect(self: *Messages) Dialect {
    return .{ .ptr = self, .vtable = &vtable };
}

fn prepare(
    ptr: *anyopaque,
    arena: std.mem.Allocator,
    request: *const core.Provider.Request,
    maybe_token: ?[]const u8,
) Dialect.Error!Transport.Request {
    const self: *Messages = @ptrCast(@alignCast(ptr));
    const token = maybe_token orelse return error.MissingCredential;
    var prepared: Transport.Request = .{ .url = endpoint, .body = try self.body(arena, request) };
    try identify(arena, &prepared, &.{
        .identity = self.options.identity,
        .token = token,
        .streams_tool_input = true,
    });
    return prepared;
}

pub fn identify(
    arena: std.mem.Allocator,
    request: *Transport.Request,
    options: *const IdentifyOptions,
) error{OutOfMemory}!void {
    var headers: std.ArrayList(std.http.Header) = .empty;
    try headers.appendSlice(arena, request.headers);
    switch (options.identity) {
        .subscription => {
            try headers.appendSlice(arena, &.{
                .{ .name = "anthropic-version", .value = anthropic_version },
                .{ .name = "anthropic-beta", .value = if (options.streams_tool_input)
                    subscription_beta ++ "," ++ streaming_beta
                else
                    subscription_beta },
                .{ .name = "x-app", .value = "cli" },
            });
            request.authorization = try std.fmt.allocPrint(arena, "Bearer {s}", .{options.token});
            request.user_agent = user_agent;
        },
        .console, .api_key => {
            try headers.appendSlice(arena, &.{
                .{ .name = "x-api-key", .value = options.token },
                .{ .name = "anthropic-version", .value = anthropic_version },
            });
            if (options.streams_tool_input)
                try headers.append(arena, .{ .name = "anthropic-beta", .value = streaming_beta });
        },
    }
    request.headers = headers.items;
}

pub fn body(
    self: *const Messages,
    arena: std.mem.Allocator,
    request: *const core.Provider.Request,
) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    self.writeBody(arena, &out.writer, request) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeBody(
    self: *const Messages,
    arena: std.mem.Allocator,
    writer: *std.Io.Writer,
    request: *const core.Provider.Request,
) !void {
    var stringify: std.json.Stringify = .{
        .writer = writer,
        .options = .{ .emit_null_optional_fields = false },
    };
    try stringify.beginObject();
    try stringify.objectField("model");
    try stringify.write(request.model);
    try stringify.objectField("max_tokens");
    try stringify.write(request.tokens_max orelse tokens_max_fallback);
    try stringify.objectField("stream");
    try stringify.write(true);

    if (request.effort) |effort| {
        try stringify.objectField("thinking");
        try stringify.write(AdaptiveThinking{});
        try stringify.objectField("output_config");
        try stringify.write(OutputConfig{ .effort = @tagName(effort) });
    }

    try stringify.objectField("system");
    try stringify.beginArray();
    if (self.options.identity.sendsSystemHeader())
        try stringify.write(TextBlock{ .text = system_header });
    try stringify.write(TextBlock{ .text = request.system, .cache_control = .{} });
    try stringify.endArray();

    if (request.tools.len > 0) {
        try stringify.objectField("tools");
        try stringify.beginArray();
        for (request.tools, 0..) |*tool, index| {
            try writeTool(&stringify, tool, index == request.tools.len - 1);
        }
        try stringify.endArray();
    }

    const emit_thinking = request.effort != null;
    const blocks = try arena.alloc(?Stored, request.items.len);
    for (request.items, blocks) |*item, *block| {
        block.* = try self.storedBlock(arena, item, emit_thinking);
    }

    try stringify.objectField("messages");
    try stringify.beginArray();
    const breakpoints = historyBreakpoints(request.items, blocks);
    var open_role: ?core.Conversation.Role = null;
    for (request.items, blocks, 0..) |*item, *maybe_stored, index| {
        if (item.* == .reasoning and maybe_stored.* == null) continue;
        const role = itemRole(item);
        if (open_role == null or open_role.? != role) {
            if (open_role != null) try endMessage(&stringify);
            try stringify.beginObject();
            try stringify.objectField("role");
            try stringify.write(@tagName(role));
            try stringify.objectField("content");
            try stringify.beginArray();
            open_role = role;
        }
        try writeItem(&stringify, item, maybe_stored, breakpoints.carries(index));
    }
    if (open_role != null) try endMessage(&stringify);
    try stringify.endArray();
    try stringify.endObject();
}

fn storedBlock(
    self: *const Messages,
    arena: std.mem.Allocator,
    item: *const core.Conversation.Item,
    emit_thinking: bool,
) error{OutOfMemory}!?Stored {
    const proof = switch (item.*) {
        .reasoning => |*proof| proof,
        .message, .tool_call, .tool_result => return null,
    };
    if (!emit_thinking) return null;
    const account = self.options.account;
    const stored = (try Dialect.decodeProof(Stored, arena, account, proof)) orelse return null;
    if (stored.signature.len == 0 and stored.redacted.len == 0) return null;
    return stored;
}

fn writeTool(stringify: *std.json.Stringify, tool: *const core.Tool, cache: bool) !void {
    try stringify.beginObject();
    try stringify.objectField("name");
    try stringify.write(tool.name);
    try stringify.objectField("description");
    try stringify.write(tool.description);
    try stringify.objectField("input_schema");
    try json.writeParametersSchema(stringify, tool.parameters);
    if (cache) {
        try stringify.objectField("cache_control");
        try stringify.write(CacheControl{});
    }
    try stringify.endObject();
}

fn historyBreakpoints(items: []const core.Conversation.Item, blocks: []const ?Stored) Breakpoints {
    var breakpoints: Breakpoints = .{};
    var open_role: ?core.Conversation.Role = null;
    for (items, blocks, 0..) |*item, maybe_stored, index| {
        if (item.* == .reasoning and maybe_stored == null) continue;
        const role = itemRole(item);
        if (open_role == .user and role == .assistant) breakpoints.previous = breakpoints.current;
        open_role = role;
        breakpoints.current = index;
    }
    return breakpoints;
}

fn itemRole(item: *const core.Conversation.Item) core.Conversation.Role {
    return switch (item.*) {
        .message => |message| message.role,
        .reasoning, .tool_call => .assistant,
        .tool_result => .user,
    };
}

fn endMessage(stringify: *std.json.Stringify) !void {
    try stringify.endArray();
    try stringify.endObject();
}

fn writeItem(
    stringify: *std.json.Stringify,
    item: *const core.Conversation.Item,
    maybe_stored: *const ?Stored,
    cache: bool,
) !void {
    const control: ?CacheControl = if (cache) .{} else null;
    switch (item.*) {
        .message => |message| try stringify.write(TextBlock{
            .text = message.text,
            .cache_control = control,
        }),
        .reasoning => {
            const stored = &maybe_stored.*.?;
            if (stored.redacted.len != 0) {
                try stringify.write(RedactedThinkingBlock{ .data = stored.redacted });
            } else {
                try stringify.write(ThinkingBlock{
                    .thinking = stored.thinking,
                    .signature = stored.signature,
                });
            }
        },
        .tool_call => |*call| try stringify.write(ToolUseBlock{
            .id = call.id,
            .name = call.name,
            .input = .{ .bytes = call.argumentsJson() },
            .cache_control = control,
        }),
        .tool_result => |result| try stringify.write(ToolResultBlock{
            .tool_use_id = result.call_id,
            .is_error = result.output.hasFailure(),
            .content = result.output.content,
            .cache_control = control,
        }),
    }
}

fn failure(
    ptr: *anyopaque,
    arena: std.mem.Allocator,
    failed: *const Dialect.Failed,
) error{OutOfMemory}!core.Provider.Failure {
    _ = ptr;
    var parsed: Dialect.Failed.Parsed = .{};
    if (try json.parseObject(arena, failed.body)) |object| {
        parsed = .{ .reason = errorReason(object), .detail = errorMessage(object) };
    }
    return failed.failure(arena, &parsed);
}

fn quota(
    ptr: *anyopaque,
    headers: []const std.http.Header,
    now_seconds: i64,
) ?core.Provider.Quota {
    _ = ptr;
    return parseQuota(headers, now_seconds);
}

fn reset(ptr: *anyopaque) void {
    const self: *Messages = @ptrCast(@alignCast(ptr));
    self.reply.reset();
    self.stop_reason = .none;
    self.open_block = null;
    self.block_text.clearRetainingCapacity();
    self.block_proof.clearRetainingCapacity();
    self.tool_call_id.clearRetainingCapacity();
    self.tool_name.clearRetainingCapacity();
}

fn finish(
    ptr: *anyopaque,
    arena: std.mem.Allocator,
    events: *Dialect.Events,
) error{OutOfMemory}!void {
    _ = ptr;
    _ = arena;
    _ = events;
}

fn decode(
    ptr: *anyopaque,
    arena: std.mem.Allocator,
    payload: []const u8,
    events: *Dialect.Events,
) error{OutOfMemory}!Dialect.Decoded {
    const self: *Messages = @ptrCast(@alignCast(ptr));
    const object = (try json.parseObject(arena, payload)) orelse return .ignored;
    const kind = json.string(object.getPtr("type")) orelse return .ignored;

    if (std.mem.eql(u8, kind, "ping")) return .ignored;
    if (std.mem.eql(u8, kind, "error")) {
        try events.append(arena, .{ .failed = .{
            .reason = errorReason(object) orelse .invalid_request,
            .message = errorMessage(object) orelse "",
        } });
        return .progress;
    }
    if (std.mem.eql(u8, kind, "message_delta")) {
        if (json.object(object.getPtr("usage"))) |usage| {
            mergeUsage(&self.reply.usage, usage);
            try events.append(arena, .{ .usage = self.reply.usage });
        }
        if (messageDeltaStopReason(object)) |reason| self.stop_reason = foldStop(reason);
        return .progress;
    }
    if (std.mem.eql(u8, kind, "message_stop")) {
        if (self.open_block != null) self.reply.reject(.invalid);
        try self.stop(arena, events);
        return .progress;
    }

    const content = std.mem.eql(u8, kind, "message_start") or
        std.mem.startsWith(u8, kind, "content_block_");
    if (content and self.stop_reason != .none) {
        self.reply.reject(.invalid);
        return .progress;
    }
    if (std.mem.eql(u8, kind, "message_start")) {
        if (json.object(object.getPtr("message"))) |message| {
            if (json.object(message.getPtr("usage"))) |usage| {
                mergeUsage(&self.reply.usage, usage);
                try events.append(arena, .{ .usage = self.reply.usage });
            }
            if (json.string(message.getPtr("model"))) |model_name| {
                try self.reply.serve(self.gpa, model_name);
            }
        }
        return .progress;
    }
    if (std.mem.eql(u8, kind, "content_block_start")) {
        try self.startBlock(arena, object, events);
        return .progress;
    }
    if (std.mem.eql(u8, kind, "content_block_delta")) {
        try self.appendBlockDelta(arena, object, events);
        return .progress;
    }
    if (std.mem.eql(u8, kind, "content_block_stop")) {
        try self.stopBlock(arena, object, events);
        return .progress;
    }
    return if (std.mem.startsWith(u8, kind, "content_block_")) .progress else .ignored;
}

fn stop(
    self: *Messages,
    arena: std.mem.Allocator,
    events: *Dialect.Events,
) error{OutOfMemory}!void {
    const reason: core.Provider.Stop.Reason = switch (self.stop_reason) {
        .none => reason: {
            self.reply.reject(.invalid);
            break :reason .complete;
        },
        .unsupported => reason: {
            self.reply.reject(.unsupported);
            break :reason .complete;
        },
        .complete => .complete,
        .truncated => .truncated,
    };
    try self.reply.end(arena, events, reason);
}

fn startBlock(
    self: *Messages,
    arena: std.mem.Allocator,
    object: *const std.json.ObjectMap,
    events: *Dialect.Events,
) !void {
    const reply = &self.reply;
    const block = json.object(object.getPtr("content_block")) orelse return reply.reject(.invalid);
    const kind = json.string(block.getPtr("type")) orelse return reply.reject(.invalid);
    if (self.open_block != null) return reply.reject(.invalid);
    const index = json.unsigned(object.getPtr("index")) orelse return reply.reject(.invalid);

    self.block_text.clearRetainingCapacity();
    self.block_proof.clearRetainingCapacity();
    self.tool_call_id.clearRetainingCapacity();
    self.tool_name.clearRetainingCapacity();
    if (std.mem.eql(u8, kind, "text")) {
        self.open_block = .{ .text = index };
    } else if (std.mem.eql(u8, kind, "thinking")) {
        self.open_block = .{ .thinking = index };
        try events.append(arena, .reasoning_started);
    } else if (std.mem.eql(u8, kind, "redacted_thinking")) {
        const data = json.string(block.getPtr("data")) orelse return reply.reject(.invalid);
        if (data.len == 0) return reply.reject(.invalid);
        try self.block_proof.appendSlice(self.gpa, data);
        self.open_block = .{ .redacted = index };
        try events.append(arena, .reasoning_started);
        try events.append(arena, .{ .reasoning = redacted_notice });
    } else if (std.mem.eql(u8, kind, "tool_use")) {
        const call_id = json.string(block.getPtr("id")) orelse return reply.reject(.invalid);
        const name = json.string(block.getPtr("name")) orelse return reply.reject(.invalid);
        if (call_id.len == 0) return reply.reject(.invalid);
        try self.tool_call_id.appendSlice(self.gpa, call_id);
        try self.tool_name.appendSlice(self.gpa, name);
        self.open_block = .{ .tool = index };
        try events.append(arena, .{ .tool_call_started = self.tool_name.items });
    } else {
        reply.reject(.unsupported);
        self.open_block = .{ .unsupported = index };
    }
}

fn appendBlockDelta(
    self: *Messages,
    arena: std.mem.Allocator,
    object: *const std.json.ObjectMap,
    events: *Dialect.Events,
) !void {
    const reply = &self.reply;
    const open_block = self.open_block orelse return reply.reject(.invalid);
    const index = json.unsigned(object.getPtr("index")) orelse return reply.reject(.invalid);
    if (index != open_block.index()) return reply.reject(.uncorrelated);
    const delta = json.object(object.getPtr("delta")) orelse return reply.reject(.invalid);
    const kind = json.string(delta.getPtr("type")) orelse return reply.reject(.invalid);
    switch (open_block) {
        .text => {
            if (!std.mem.eql(u8, kind, "text_delta")) return reply.reject(.invalid);
            const text = json.string(delta.getPtr("text")) orelse return reply.reject(.invalid);
            try self.block_text.appendSlice(self.gpa, text);
            if (text.len != 0) try events.append(arena, .{ .text = text });
        },
        .thinking => {
            if (std.mem.eql(u8, kind, "thinking_delta")) {
                if (self.block_proof.items.len != 0) return reply.reject(.invalid);
                const text = json.string(delta.getPtr("thinking")) orelse
                    return reply.reject(.invalid);
                try self.block_text.appendSlice(self.gpa, text);
                if (text.len != 0) try events.append(arena, .{ .reasoning = text });
            } else if (std.mem.eql(u8, kind, "signature_delta")) {
                const proof = json.string(delta.getPtr("signature")) orelse
                    return reply.reject(.invalid);
                try self.block_proof.appendSlice(self.gpa, proof);
            } else {
                return reply.reject(.invalid);
            }
        },
        .redacted => return reply.reject(.invalid),
        .tool => {
            if (!std.mem.eql(u8, kind, "input_json_delta")) return reply.reject(.invalid);
            const chunk = json.string(delta.getPtr("partial_json")) orelse
                return reply.reject(.invalid);
            try self.block_text.appendSlice(self.gpa, chunk);
            try events.append(arena, .{ .tool_call_arguments = chunk });
        },
        .unsupported => {},
    }
}

fn stopBlock(
    self: *Messages,
    arena: std.mem.Allocator,
    object: *const std.json.ObjectMap,
    events: *Dialect.Events,
) !void {
    const reply = &self.reply;
    const open_block = self.open_block orelse return reply.reject(.invalid);
    const index = json.unsigned(object.getPtr("index")) orelse return reply.reject(.invalid);
    if (index != open_block.index()) return reply.reject(.uncorrelated);
    self.open_block = null;
    switch (open_block) {
        .text => if (self.block_text.items.len != 0) {
            try events.append(arena, .{ .output = .{ .message = self.block_text.items } });
        },
        .thinking => {
            if (self.block_proof.items.len == 0) return reply.reject(.invalid);
            try self.appendProof(arena, events, &.{
                .thinking = self.block_text.items,
                .signature = self.block_proof.items,
            });
        },
        .redacted => try self.appendProof(arena, events, &.{ .redacted = self.block_proof.items }),
        .tool => try events.append(arena, .{ .output = .{ .tool_call = .{
            .id = self.tool_call_id.items,
            .name = self.tool_name.items,
            .arguments = self.block_text.items,
        } } }),
        .unsupported => {},
    }
}

fn appendProof(
    self: *const Messages,
    arena: std.mem.Allocator,
    events: *Dialect.Events,
    stored: *const Stored,
) error{OutOfMemory}!void {
    const proof = try Dialect.encodeProof(Stored, arena, self.options.account, stored);
    try events.append(arena, .{ .output = .{ .reasoning = proof } });
}

fn foldStop(reason: []const u8) Terminal {
    if (std.mem.eql(u8, reason, "end_turn") or
        std.mem.eql(u8, reason, "tool_use") or
        std.mem.eql(u8, reason, "stop_sequence")) return .complete;
    if (std.mem.eql(u8, reason, "max_tokens") or
        std.mem.eql(u8, reason, "model_context_window_exceeded")) return .truncated;
    return .unsupported;
}

fn messageDeltaStopReason(object: *const std.json.ObjectMap) ?[]const u8 {
    const delta = json.object(object.getPtr("delta")) orelse return null;
    return json.string(delta.getPtr("stop_reason"));
}

fn errorMessage(object: *const std.json.ObjectMap) ?[]const u8 {
    const detail = json.object(object.getPtr("error")) orelse return null;
    return json.string(detail.getPtr("message"));
}

fn errorReason(object: *const std.json.ObjectMap) ?core.Provider.Failure.Reason {
    const detail = json.object(object.getPtr("error")) orelse return null;
    const kind = json.string(detail.getPtr("type")) orelse return null;
    if (std.mem.eql(u8, kind, "overloaded_error")) return .overloaded;
    if (std.mem.eql(u8, kind, "api_error")) return .overloaded;
    if (std.mem.eql(u8, kind, "rate_limit_error")) return .rate_limited;
    if (std.mem.eql(u8, kind, "authentication_error")) return .unauthorized;
    return null;
}

fn mergeUsage(usage: *core.Provider.Usage, object: *const std.json.ObjectMap) void {
    if (json.unsigned(object.getPtr("input_tokens"))) |value| usage.input = value;
    if (json.unsigned(object.getPtr("output_tokens"))) |value| usage.output = value;
    if (json.unsigned(object.getPtr("cache_read_input_tokens"))) |value| usage.cache_read = value;
    if (json.unsigned(object.getPtr("cache_creation_input_tokens"))) |value|
        usage.cache_write = value;
}

const quota_windows = [_]struct { name: []const u8, minutes: u32 }{
    .{ .name = "5h", .minutes = 300 },
    .{ .name = "7d", .minutes = 10080 },
};

fn parseQuota(headers: []const std.http.Header, now_seconds: i64) ?core.Provider.Quota {
    var used: [quota_windows.len]?f64 = @splat(null);
    var reset_seconds: [quota_windows.len]?u64 = @splat(null);
    for (headers) |header| {
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
    var parsed: [quota_windows.len]?core.Provider.Quota.Window = @splat(null);
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
    return core.Provider.Quota.Window.usedPercent(fraction * 100.0);
}

fn parseResetSeconds(value: []const u8, now_seconds: i64) ?u64 {
    const epoch = std.fmt.parseInt(i64, value, 10) catch return null;
    if (epoch <= now_seconds) return null;
    return @intCast(epoch - now_seconds);
}

test "a request without a stated output limit sends the fallback cap" {
    var unstated = testRequest(&.{}, null);
    unstated.tokens_max = null;
    const parsed = try Rig.body(test_options, &unstated);
    defer parsed.deinit();
    try std.testing.expectEqual(
        @as(i64, tokens_max_fallback),
        parsed.value.object.get("max_tokens").?.integer,
    );
}

const test_options: Options = .{ .account = "anthropic-plan", .identity = .subscription };

fn testRequest(
    items: []const core.Conversation.Item,
    effort: ?core.Provider.Effort,
) core.Provider.Request {
    return .{
        .model = "claude-opus-4-8",
        .tokens_max = 8192,
        .system = "be terse",
        .items = items,
        .tools = &.{},
        .effort = effort,
        .cache_key = "",
    };
}

const proof_weigh: core.Conversation.Item = .{ .reasoning = .{
    .account = "anthropic-plan",
    .payload = "{\"thinking\":\"weigh it\",\"signature\":\"sig\"}",
} };

const proof_redacted: core.Conversation.Item = .{ .reasoning = .{
    .account = "anthropic-plan",
    .payload = "{\"redacted\":\"secret\"}",
} };

const Rig = testing.DialectRig(Messages);

test "the body names the model, the cap, the system header, the tools, and the messages" {
    const items = [_]core.Conversation.Item{
        .{ .message = .{ .role = .user, .text = "hi \"there\"" } },
    };
    var named = testRequest(&items, null);
    named.model = "claude-sonnet-4-6";
    named.tokens_max = 1024;
    named.tools = &testing.tools;
    const parsed = try Rig.body(test_options, &named);
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("claude-sonnet-4-6", root.get("model").?.string);
    try std.testing.expectEqual(@as(i64, 1024), root.get("max_tokens").?.integer);
    try std.testing.expectEqual(true, root.get("stream").?.bool);
    try std.testing.expect(root.get("thinking") == null);
    try std.testing.expect(root.get("output_config") == null);
    const system = root.get("system").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), system.len);
    try std.testing.expectEqualStrings(system_header, system[0].object.get("text").?.string);
    try std.testing.expect(system[0].object.get("cache_control") == null);
    try std.testing.expectEqualStrings("be terse", system[1].object.get("text").?.string);
    try std.testing.expectEqualStrings(
        "ephemeral",
        system[1].object.get("cache_control").?.object.get("type").?.string,
    );
    try std.testing.expectEqualStrings(
        "hi \"there\"",
        root.get("messages").?.array.items[0].object
            .get("content").?.array.items[0].object.get("text").?.string,
    );
    const tool = root.get("tools").?.array.items[0].object;
    const input_schema = tool.get("input_schema").?.object;
    try std.testing.expectEqualStrings("object", input_schema.get("type").?.string);
    try std.testing.expectEqualStrings(
        "string",
        input_schema.get("properties").?.object.get("path").?.object.get("type").?.string,
    );
    try std.testing.expectEqualStrings(
        "path",
        input_schema.get("required").?.array.items[0].string,
    );
    try std.testing.expect(tool.get("cache_control") != null);
}

test "tool call arguments pass through raw, and failed results group in one user envelope" {
    var failed: core.Tool.Output = .{ .content = "ok" };
    failed.conditions.insert(.path_missing);
    const items = [_]core.Conversation.Item{
        .{ .tool_call = .{ .id = "t1", .name = "read", .arguments = "{\"path\":\"a.zig\"}" } },
        .{ .tool_call = .{ .id = "t2", .name = "list", .arguments = "" } },
        .{ .tool_result = .{ .call_id = "t1", .output = failed } },
        .{ .tool_result = .{ .call_id = "t2", .output = .{ .content = "fine" } } },
        .{ .message = .{ .role = .user, .text = "next" } },
    };
    const parsed = try Rig.body(test_options, &testRequest(&items, null));
    defer parsed.deinit();
    const messages = parsed.value.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    const calls = messages[0].object.get("content").?.array.items;
    try std.testing.expectEqualStrings("tool_use", calls[0].object.get("type").?.string);
    try std.testing.expectEqualStrings(
        "a.zig",
        calls[0].object.get("input").?.object.get("path").?.string,
    );
    try std.testing.expectEqual(@as(usize, 0), calls[1].object.get("input").?.object.count());
    const results = messages[1].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("tool_result", results[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("t1", results[0].object.get("tool_use_id").?.string);
    try std.testing.expectEqual(true, results[0].object.get("is_error").?.bool);
    try std.testing.expectEqualStrings("ok", results[0].object.get("content").?.string);
    try std.testing.expectEqual(false, results[1].object.get("is_error").?.bool);
    try std.testing.expectEqualStrings("text", results[2].object.get("type").?.string);
    try std.testing.expectEqualStrings("next", results[2].object.get("text").?.string);
}

test "cache_control marks the last tool, the previous user block, and the last block" {
    const tools = [_]core.Tool{
        .{ .name = "read", .description = "d", .parameters = &.{} },
        .{ .name = "grep", .description = "d", .parameters = &.{} },
    };
    const items = [_]core.Conversation.Item{
        .{ .message = .{ .role = .user, .text = "hello" } },
        .{ .message = .{ .role = .assistant, .text = "a" } },
        .{ .message = .{ .role = .assistant, .text = "b" } },
    };
    var with_tools = testRequest(&items, null);
    with_tools.tools = &tools;
    const parsed = try Rig.body(test_options, &with_tools);
    defer parsed.deinit();
    const root = parsed.value.object;
    const tool_items = root.get("tools").?.array.items;
    try std.testing.expect(tool_items[0].object.get("cache_control") == null);
    try std.testing.expect(tool_items[1].object.get("cache_control") != null);
    const envelopes = root.get("messages").?.array.items;
    const first_blocks = envelopes[0].object.get("content").?.array.items;
    try std.testing.expect(first_blocks[0].object.get("cache_control") != null);
    const last_blocks = envelopes[1].object.get("content").?.array.items;
    try std.testing.expect(last_blocks[0].object.get("cache_control") == null);
    try std.testing.expect(last_blocks[1].object.get("cache_control") != null);
}

test "cache_control also marks the last block of the previous user envelope" {
    const items = [_]core.Conversation.Item{
        .{ .message = .{ .role = .user, .text = "hello" } },
        .{ .tool_call = .{ .id = "t1", .name = "read", .arguments = "{}" } },
        .{ .tool_result = .{ .call_id = "t1", .output = .{ .content = "c" } } },
        .{ .message = .{ .role = .user, .text = "resume" } },
        .{ .message = .{ .role = .assistant, .text = "a" } },
        .{ .message = .{ .role = .user, .text = "next" } },
    };
    const parsed = try Rig.body(test_options, &testRequest(&items, null));
    defer parsed.deinit();
    const envelopes = parsed.value.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 5), envelopes.len);
    const marked = [_]bool{ false, false, false, true, false, true };
    var block_index: usize = 0;
    for (envelopes) |envelope| {
        for (envelope.object.get("content").?.array.items) |block| {
            try std.testing.expect(block_index < marked.len);
            const carries = block.object.get("cache_control") != null;
            try std.testing.expectEqual(marked[block_index], carries);
            block_index += 1;
        }
    }
    try std.testing.expectEqual(marked.len, block_index);
}

test "a named effort writes adaptive thinking and keeps the replay, no effort drops both" {
    const items = [_]core.Conversation.Item{
        .{ .message = .{ .role = .user, .text = "hi" } },
        proof_weigh,
        .{ .message = .{ .role = .assistant, .text = "answer" } },
    };
    const named = try Rig.body(test_options, &testRequest(&items, .low));
    defer named.deinit();
    const root = named.value.object;
    const thinking = root.get("thinking").?.object;
    try std.testing.expectEqualStrings("adaptive", thinking.get("type").?.string);
    try std.testing.expectEqualStrings("summarized", thinking.get("display").?.string);
    try std.testing.expectEqualStrings(
        "low",
        root.get("output_config").?.object.get("effort").?.string,
    );
    const assistant = root.get("messages").?.array.items[1].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), assistant.len);
    try std.testing.expectEqualStrings("thinking", assistant[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("weigh it", assistant[0].object.get("thinking").?.string);
    try std.testing.expectEqualStrings("sig", assistant[0].object.get("signature").?.string);

    const omitted = try Rig.body(test_options, &testRequest(&items, null));
    defer omitted.deinit();
    try std.testing.expect(omitted.value.object.get("thinking") == null);
    try std.testing.expect(omitted.value.object.get("output_config") == null);
    const plain = omitted.value.object.get("messages").?.array.items[1].object
        .get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), plain.len);
    try std.testing.expectEqualStrings("text", plain[0].object.get("type").?.string);
}

const golden_items = [_]core.Conversation.Item{
    .{ .message = .{ .role = .user, .text = "first" } },
    .{ .message = .{ .role = .user, .text = "second" } },
    proof_weigh,
    proof_redacted,
    .{ .tool_call = .{ .id = "t1", .name = "read", .arguments = "{\"path\":\"a.zig\"}" } },
    .{ .message = .{ .role = .assistant, .text = "checking" } },
    .{ .tool_result = .{ .call_id = "t1", .output = .{ .content = "contents" } } },
    .{ .reasoning = .{
        .account = "anthropic-plan",
        .payload = "{\"thinking\":\"more\",\"signature\":\"sig2\"}",
    } },
    .{ .tool_call = .{ .id = "t2", .name = "write", .arguments = "{\"path\":\"b\"}" } },
    .{ .tool_result = .{ .call_id = "t2", .output = .{
        .content = "done",
        .conditions = .initOne(.failed),
    } } },
    .{ .message = .{ .role = .assistant, .text = "all set" } },
};

const golden_on = testing.oneLine(
    \\{"model":"claude-opus-4-8","max_tokens":8192,"stream":true,"thinking":{"type":"adaptive",
    \\"display":"summarized"},"output_config":{"effort":"xhigh"},"system":[{"type":"text",
    \\"text":"You are Claude Code, Anthropic's official CLI for Claude."},{"type":"text",
    \\"text":"be terse","cache_control":{"type":"ephemeral"}}],"messages":[{"role":"user",
    \\"content":[{"type":"text","text":"first"},{"type":"text","text":"second"}]},
    \\{"role":"assistant","content":[{"type":"thinking","thinking":"weigh it",
    \\"signature":"sig"},{"type":"redacted_thinking","data":"secret"},{"type":"tool_use",
    \\"id":"t1","name":"read","input":{"path":"a.zig"}},{"type":"text","text":"checking"}]},
    \\{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":false,
    \\"content":"contents"}]},{"role":"assistant","content":[{"type":"thinking",
    \\"thinking":"more","signature":"sig2"},{"type":"tool_use","id":"t2","name":"write",
    \\"input":{"path":"b"}}]},{"role":"user","content":[{"type":"tool_result",
    \\"tool_use_id":"t2","is_error":true,"content":"done",
    \\"cache_control":{"type":"ephemeral"}}]},{"role":"assistant","content":[{"type":"text",
    \\"text":"all set","cache_control":{"type":"ephemeral"}}]}]}
);

const golden_none = testing.oneLine(
    \\{"model":"claude-opus-4-8","max_tokens":8192,"stream":true,"system":[{"type":"text",
    \\"text":"You are Claude Code, Anthropic's official CLI for Claude."},{"type":"text",
    \\"text":"be terse","cache_control":{"type":"ephemeral"}}],"messages":[{"role":"user",
    \\"content":[{"type":"text","text":"first"},{"type":"text","text":"second"}]},
    \\{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"read",
    \\"input":{"path":"a.zig"}},{"type":"text","text":"checking"}]},{"role":"user",
    \\"content":[{"type":"tool_result","tool_use_id":"t1","is_error":false,
    \\"content":"contents"}]},{"role":"assistant","content":[{"type":"tool_use","id":"t2",
    \\"name":"write","input":{"path":"b"}}]},{"role":"user","content":[{"type":"tool_result",
    \\"tool_use_id":"t2","is_error":true,"content":"done",
    \\"cache_control":{"type":"ephemeral"}}]},{"role":"assistant","content":[{"type":"text",
    \\"text":"all set","cache_control":{"type":"ephemeral"}}]}]}
);

test "the golden bytes keep the cached prefix stable with and without thinking" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const messages: Messages = .init(std.testing.allocator, test_options);
    const on = try messages.body(arena.allocator(), &testRequest(&golden_items, .xhigh));
    try std.testing.expectEqualStrings(golden_on, on);
    const none = try messages.body(arena.allocator(), &testRequest(&golden_items, null));
    try std.testing.expectEqualStrings(golden_none, none);
}

const golden_api = testing.oneLine(
    \\{"model":"claude-opus-4-8","max_tokens":8192,"stream":true,"thinking":{"type":"adaptive",
    \\"display":"summarized"},"output_config":{"effort":"xhigh"},"system":[{"type":"text",
    \\"text":"be terse","cache_control":{"type":"ephemeral"}}],"messages":[{"role":"user",
    \\"content":[{"type":"text","text":"first","cache_control":{"type":"ephemeral"}}]},
    \\{"role":"assistant","content":[{"type":"thinking","thinking":"weigh it",
    \\"signature":"sig"},{"type":"tool_use","id":"t1","name":"read","input":{"path":"a.zig"}},
    \\{"type":"text","text":"all set","cache_control":{"type":"ephemeral"}}]}]}
);

test "the api-key identity omits the system header and keeps every other block" {
    const items = [_]core.Conversation.Item{
        .{ .message = .{ .role = .user, .text = "first" } },
        .{ .reasoning = .{
            .account = "anthropic-api-key",
            .payload = "{\"thinking\":\"weigh it\",\"signature\":\"sig\"}",
        } },
        .{ .tool_call = .{ .id = "t1", .name = "read", .arguments = "{\"path\":\"a.zig\"}" } },
        .{ .message = .{ .role = .assistant, .text = "all set" } },
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const messages: Messages = .init(std.testing.allocator, .{
        .account = "anthropic-api-key",
        .identity = .api_key,
    });
    const bytes = try messages.body(arena.allocator(), &testRequest(&items, .xhigh));
    try std.testing.expectEqualStrings(golden_api, bytes);
}

test "the console identity sends the system header and replays its own reasoning" {
    const items = [_]core.Conversation.Item{
        .{ .message = .{ .role = .user, .text = "first" } },
        .{ .reasoning = .{
            .account = "anthropic-api",
            .payload = "{\"thinking\":\"weigh it\",\"signature\":\"sig\"}",
        } },
        .{ .message = .{ .role = .assistant, .text = "all set" } },
    };
    const parsed = try Rig.body(
        .{ .account = "anthropic-api", .identity = .console },
        &testRequest(&items, .xhigh),
    );
    defer parsed.deinit();
    const root = parsed.value.object;
    const system = root.get("system").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), system.len);
    try std.testing.expectEqualStrings(system_header, system[0].object.get("text").?.string);
    const assistant = root.get("messages").?.array.items[1].object.get("content").?.array.items;
    try std.testing.expectEqualStrings("thinking", assistant[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("weigh it", assistant[0].object.get("thinking").?.string);
}

test "a reasoning run of another account writes no block and opens no empty envelope" {
    const items = [_]core.Conversation.Item{
        .{ .message = .{ .role = .user, .text = "hi" } },
        proof_weigh,
        .{ .reasoning = .{ .account = "anthropic-api-key", .payload = "not json" } },
        .{ .reasoning = .{
            .account = "anthropic-api-key",
            .payload = "{\"thinking\":\"no proof\"}",
        } },
        .{ .message = .{ .role = .user, .text = "again" } },
    };
    const parsed = try Rig.body(
        .{ .account = "anthropic-api-key", .identity = .api_key },
        &testRequest(&items, .xhigh),
    );
    defer parsed.deinit();
    const messages = parsed.value.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("user", messages[0].object.get("role").?.string);
    const content = messages[0].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), content.len);
    try std.testing.expectEqualStrings("hi", content[0].object.get("text").?.string);
    try std.testing.expectEqualStrings("again", content[1].object.get("text").?.string);
    try std.testing.expect(content[1].object.get("cache_control") != null);
}

test "prepare forks the headers by identity and every identity streams tool input" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const empty = testRequest(&.{}, null);

    var subscription: Messages = .init(std.testing.allocator, test_options);
    const plan = try subscription.dialect().prepare(arena.allocator(), &empty, "tok");
    try std.testing.expectEqualStrings(endpoint, plan.url);
    try std.testing.expectEqualStrings("Bearer tok", plan.authorization.?);
    try std.testing.expectEqualStrings(user_agent, plan.user_agent.?);
    try std.testing.expectEqual(@as(usize, 3), plan.headers.len);
    try std.testing.expectEqualStrings("anthropic-version", plan.headers[0].name);
    try std.testing.expectEqualStrings(anthropic_version, plan.headers[0].value);
    try std.testing.expectEqualStrings("anthropic-beta", plan.headers[1].name);
    try std.testing.expectEqualStrings(
        subscription_beta ++ "," ++ streaming_beta,
        plan.headers[1].value,
    );
    try std.testing.expectEqualStrings("x-app", plan.headers[2].name);
    try std.testing.expectEqualStrings("cli", plan.headers[2].value);

    var keyed: Messages = .init(std.testing.allocator, .{
        .account = "anthropic-api-key",
        .identity = .api_key,
    });
    const key = try keyed.dialect().prepare(arena.allocator(), &empty, "sk-key");
    try std.testing.expectEqualStrings(endpoint, key.url);
    try std.testing.expectEqual(@as(?[]const u8, null), key.authorization);
    try std.testing.expectEqual(@as(?[]const u8, null), key.user_agent);
    try std.testing.expectEqual(@as(usize, 3), key.headers.len);
    try std.testing.expectEqualStrings("x-api-key", key.headers[0].name);
    try std.testing.expectEqualStrings("sk-key", key.headers[0].value);
    try std.testing.expectEqualStrings("anthropic-version", key.headers[1].name);
    try std.testing.expectEqualStrings("anthropic-beta", key.headers[2].name);
    try std.testing.expectEqualStrings(streaming_beta, key.headers[2].value);

    try std.testing.expectError(
        error.MissingCredential,
        keyed.dialect().prepare(arena.allocator(), &empty, null),
    );
}

test "a thinking block streams its deltas and closes as one signed proof" {
    var rig: Rig = undefined;
    rig.init(test_options);
    defer rig.deinit();
    try rig.frames.feed(&.{
        \\{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}
        ,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta",
        \\"thinking":"hmm"}}
        ,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}
        ,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta",
        \\"signature":"si"}}
        ,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta",
        \\"signature":"g"}}
        ,
        \\{"type":"content_block_stop","index":0}
        ,
        \\{"type":"content_block_start","index":1,"content_block":{"type":"redacted_thinking",
        \\"data":"enc"}}
        ,
        \\{"type":"content_block_stop","index":1}
        ,
        \\{"type":"content_block_start","index":2,"content_block":{"type":"thinking"}}
        ,
        \\{"type":"content_block_delta","index":2,"delta":{"type":"signature_delta",
        \\"signature":"only"}}
        ,
        \\{"type":"content_block_stop","index":2}
        ,
    });
    try rig.frames.expect(
        \\reasoning_started
        \\reasoning:hmm
        \\proof:anthropic-plan:{"thinking":"hmm","signature":"sig","redacted":""}
        \\reasoning_started
        \\reasoning:[redacted thinking]
        \\proof:anthropic-plan:{"thinking":"","signature":"","redacted":"enc"}
        \\reasoning_started
        \\proof:anthropic-plan:{"thinking":"","signature":"only","redacted":""}
        \\
    );
}

test "a rejected block latches through the terminal usage" {
    const Case = struct { frames: []const []const u8, expected: []const u8 };
    const invalid_reply = "usage:0/5/0/0\nfailed:invalid_reply|-|\n";
    const uncorrelated_reply = "usage:0/5/0/0\nfailed:unsupported_reply|-|" ++
        "The stream named a block other than the open one.\n";
    const cases = [_]Case{
        .{ .frames = &.{
            \\{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}
            ,
            \\{"type":"content_block_stop","index":0}
            ,
        }, .expected = "reasoning_started\n" ++ invalid_reply },
        .{ .frames = &.{
            \\{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}
            ,
            \\{"type":"content_block_delta","index":1,"delta":{"type":"signature_delta",
            \\"signature":"sig"}}
            ,
        }, .expected = "reasoning_started\n" ++ uncorrelated_reply },
        .{ .frames = &.{
            \\{"type":"content_block_start","index":0,"content_block":{"type":"redacted_thinking",
            \\"data":""}}
        }, .expected = invalid_reply },
        .{ .frames = &.{
            \\{"type":"content_block_start","index":0,"content_block":{"type":"redacted_thinking",
            \\"data":"enc"}}
        }, .expected = "reasoning_started\nreasoning:[redacted thinking]\n" ++ invalid_reply },
        .{ .frames = &.{
            \\{"type":"content_block_start","index":0,"content_block":{"type":"redacted_thinking",
            \\"data":"enc"}}
            ,
            \\{"type":"content_block_stop","index":1}
            ,
        }, .expected = "reasoning_started\nreasoning:[redacted thinking]\n" ++ uncorrelated_reply },
        .{ .frames = &.{
            \\{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}
            ,
            \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"wrong"}}
            ,
        }, .expected = "reasoning_started\n" ++ invalid_reply },
        .{ .frames = &.{
            \\{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1",
            \\"name":"read"}}
            ,
            \\{"type":"content_block_delta","index":-1,"delta":{"type":"input_json_delta",
            \\"partial_json":"{}"}}
            ,
        }, .expected = "tool_call_started:read\n" ++ invalid_reply },
    };
    for (cases) |case| {
        var rig: Rig = undefined;
        rig.init(test_options);
        defer rig.deinit();
        try rig.frames.feed(case.frames);
        try rig.frames.feed(&.{
            \\{"type":"message_delta","delta":{"stop_reason":"end_turn"},
            \\"usage":{"output_tokens":5}}
            ,
            \\{"type":"message_stop"}
            ,
        });
        try rig.frames.expect(case.expected);
    }
}

test "a stream splits its usage across the start and the delta and ends at message_stop" {
    var rig: Rig = undefined;
    rig.init(test_options);
    defer rig.deinit();
    try std.testing.expectEqual(Dialect.Decoded.progress, try rig.frames.decode(
        \\{"type":"message_start","message":{"model":"claude-opus-5","usage":{"input_tokens":10,
        \\"cache_read_input_tokens":90,"cache_creation_input_tokens":5,"output_tokens":1}}}
    ));
    try std.testing.expectEqual(Dialect.Decoded.ignored, try rig.frames.decode(
        \\{"type":"ping"}
    ));
    try rig.frames.feed(&.{
        \\{"type":"content_block_start","index":0,"content_block":{"type":"text"}}
        ,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":""}}
        ,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}
        ,
        \\{"type":"content_block_stop","index":0}
        ,
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":42}}
        ,
        \\{"type":"message_stop"}
        ,
    });
    try rig.frames.expect(
        \\usage:10/1/90/5
        \\text:Hi
        \\message:Hi
        \\usage:10/42/90/5
        \\stopped:complete|claude-opus-5
        \\
    );
}

test "message_stop without a reason or after a malformed tail carries usage and rejects" {
    var missing: Rig = undefined;
    missing.init(test_options);
    defer missing.deinit();
    try missing.frames.feed(&.{
        \\{"type":"message_stop"}
    });
    try missing.frames.expect("failed:invalid_reply|-|\n");

    var late: Rig = undefined;
    late.init(test_options);
    defer late.deinit();
    try late.frames.feed(&.{
        \\{"type":"message_delta","delta":{"stop_reason":null},"usage":{"output_tokens":1}}
        ,
        \\{"type":"message_stop"}
        ,
    });
    try late.frames.expect(
        \\usage:0/1/0/0
        \\failed:invalid_reply|-|
        \\
    );

    var tail: Rig = undefined;
    tail.init(test_options);
    defer tail.deinit();
    try tail.frames.feed(&.{
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}
        ,
        \\{"type":"content_block_delta","delta":{"type":"text_delta","text":"late"}}
        ,
        \\{"type":"surprise_new_event"}
        ,
        \\{"type":"message_stop"}
        ,
    });
    try tail.frames.expect(
        \\usage:0/2/0/0
        \\failed:invalid_reply|-|
        \\
    );
}

test "an unrecognized frame after the terminal delta stays filler" {
    var rig: Rig = undefined;
    rig.init(test_options);
    defer rig.deinit();
    try rig.frames.feed(&.{
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}
    });
    try std.testing.expectEqual(Dialect.Decoded.ignored, try rig.frames.decode(
        \\{"type":"surprise_new_event"}
    ));
    try rig.frames.feed(&.{
        \\{"type":"message_stop"}
    });
    try rig.frames.expect(
        \\usage:0/1/0/0
        \\stopped:complete|
        \\
    );
}

test "stop_reason folds to a terminal status and the last non-null delta wins" {
    const Case = struct { reasons: []const []const u8, expected: []const u8 };
    const unsupported = "failed:unsupported_reply|-|" ++
        "The reply holds content that Drinky cannot keep.\n";
    const cases = [_]Case{
        .{ .reasons = &.{"max_tokens"}, .expected = "stopped:truncated|\n" },
        .{ .reasons = &.{"model_context_window_exceeded"}, .expected = "stopped:truncated|\n" },
        .{ .reasons = &.{ "max_tokens", "end_turn" }, .expected = "stopped:complete|\n" },
        .{ .reasons = &.{"tool_use"}, .expected = "stopped:complete|\n" },
        .{ .reasons = &.{"stop_sequence"}, .expected = "stopped:complete|\n" },
        .{ .reasons = &.{"pause_turn"}, .expected = unsupported },
        .{ .reasons = &.{"refusal"}, .expected = unsupported },
        .{ .reasons = &.{"surprise_reason"}, .expected = unsupported },
    };
    for (cases) |case| {
        var rig: Rig = undefined;
        rig.init(test_options);
        defer rig.deinit();
        for (case.reasons) |reason| {
            const delta = try std.fmt.allocPrint(
                std.testing.allocator,
                "{{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"{s}\"}}," ++
                    "\"usage\":{{}}}}",
                .{reason},
            );
            defer std.testing.allocator.free(delta);
            try rig.frames.feed(&.{delta});
            try rig.frames.expect("usage:0/0/0/0\n");
        }
        try rig.frames.feed(&.{
            \\{"type":"message_delta","delta":{},"usage":{"output_tokens":7}}
            ,
            \\{"type":"message_stop"}
            ,
        });
        const expected = try std.mem.concat(std.testing.allocator, u8, &.{
            "usage:0/7/0/0\n",
            case.expected,
        });
        defer std.testing.allocator.free(expected);
        try rig.frames.expect(expected);
    }
}

test "an unsupported content block and a stop that closes nothing latch through the usage" {
    var unsupported: Rig = undefined;
    unsupported.init(test_options);
    defer unsupported.deinit();
    try unsupported.frames.feed(&.{
        \\{"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use",
        \\"id":"tool_1"}}
        ,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"server_tool_delta"}}
        ,
        \\{"type":"content_block_stop","index":0}
        ,
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":6}}
        ,
        \\{"type":"message_stop"}
        ,
    });
    try unsupported.frames.expect(
        \\usage:0/6/0/0
        \\failed:unsupported_reply|-|The reply holds content that Drinky cannot keep.
        \\
    );

    var orphan: Rig = undefined;
    orphan.init(test_options);
    defer orphan.deinit();
    try orphan.frames.feed(&.{
        \\{"type":"content_block_stop","index":0}
        ,
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}
        ,
        \\{"type":"message_stop"}
        ,
    });
    try orphan.frames.expect(
        \\usage:0/3/0/0
        \\failed:invalid_reply|-|
        \\
    );
}

test "a tool block names its call, streams its input, and closes as one call" {
    var rig: Rig = undefined;
    rig.init(test_options);
    defer rig.deinit();
    try rig.frames.feed(&.{
        \\{"type":"content_block_start","index":0,"content_block":{"type":"text"}}
        ,
        \\{"type":"content_block_stop","index":0}
        ,
        \\{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t1",
        \\"name":"read"}}
        ,
        \\{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta",
        \\"partial_json":"{"}}
        ,
        \\{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta",
        \\"partial_json":"}"}}
        ,
        \\{"type":"content_block_stop","index":1}
        ,
        \\{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"t2",
        \\"name":"grep"}}
        ,
        \\{"type":"content_block_stop","index":2}
        ,
        \\{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":3}}
        ,
        \\{"type":"message_stop"}
        ,
    });
    try rig.frames.expect(
        \\tool_call_started:read
        \\tool_call_arguments:{
        \\tool_call_arguments:}
        \\tool_call:t1|read|{}
        \\tool_call_started:grep
        \\tool_call:t2|grep|
        \\usage:0/3/0/0
        \\stopped:complete|
        \\
    );
}

test "thinking, answer text, and a second thinking block each start their own block" {
    var rig: Rig = undefined;
    rig.init(test_options);
    defer rig.deinit();
    try rig.frames.feed(&.{
        \\{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}
        ,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta",
        \\"thinking":"**a**"}}
        ,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta",
        \\"signature":"sig"}}
        ,
        \\{"type":"content_block_stop","index":0}
        ,
        \\{"type":"content_block_start","index":1,"content_block":{"type":"text"}}
        ,
        \\{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"answer"}}
        ,
        \\{"type":"content_block_stop","index":1}
        ,
        \\{"type":"content_block_start","index":2,"content_block":{"type":"thinking"}}
        ,
        \\{"type":"content_block_delta","index":2,"delta":{"type":"thinking_delta",
        \\"thinking":"**b**"}}
        ,
        \\{"type":"content_block_delta","index":2,"delta":{"type":"signature_delta",
        \\"signature":"sig"}}
        ,
        \\{"type":"content_block_stop","index":2}
        ,
    });
    try rig.frames.expect(
        \\reasoning_started
        \\reasoning:**a**
        \\proof:anthropic-plan:{"thinking":"**a**","signature":"sig","redacted":""}
        \\text:answer
        \\message:answer
        \\reasoning_started
        \\reasoning:**b**
        \\proof:anthropic-plan:{"thinking":"**b**","signature":"sig","redacted":""}
        \\
    );
}

test "malformed and unknown frames are filler that keeps the reply, a block boundary is progress" {
    var rig: Rig = undefined;
    rig.init(test_options);
    defer rig.deinit();
    try std.testing.expectEqual(Dialect.Decoded.ignored, try rig.frames.decode(
        \\{"type":"content_block_delta","del
    ));
    try std.testing.expectEqual(Dialect.Decoded.ignored, try rig.frames.decode("not json at all"));
    try std.testing.expectEqual(Dialect.Decoded.ignored, try rig.frames.decode(
        \\{"type":"surprise_new_event"}
    ));
    try std.testing.expectEqual(Dialect.Decoded.ignored, try rig.frames.decode(
        \\{"note":"no type here"}
    ));
    try std.testing.expectEqual(Dialect.Decoded.ignored, try rig.frames.decode("42"));
    try std.testing.expectEqual(Dialect.Decoded.progress, try rig.frames.decode(
        \\{"type":"content_block_start","index":0,"content_block":{"type":"text"}}
    ));
    try std.testing.expectEqual(Dialect.Decoded.progress, try rig.frames.decode(
        \\{"type":"content_block_stop","index":0}
    ));
    try rig.frames.expect("");
    try rig.frames.feed(&.{
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}
        ,
        \\{"type":"message_stop"}
        ,
    });
    try rig.frames.expect(
        \\usage:0/1/0/0
        \\stopped:complete|
        \\
    );
}

test "a streamed error frame fails with its reason and message" {
    const long = "x" ** 5000;
    const cases = [_]struct { payload: []const u8, expected: []const u8 }{
        .{
            .payload =
            \\{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}
            ,
            .expected = "failed:overloaded|-|Overloaded\n",
        },
        .{
            .payload =
            \\{"type":"error","error":{"type":"rate_limit_error","message":"Rate limited"}}
            ,
            .expected = "failed:rate_limited|-|Rate limited\n",
        },
        .{
            .payload =
            \\{"type":"error","error":{"type":"api_error","message":"Server error"}}
            ,
            .expected = "failed:overloaded|-|Server error\n",
        },
        .{
            .payload =
            \\{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}
            ,
            .expected = "failed:unauthorized|-|invalid x-api-key\n",
        },
        .{
            .payload =
            \\{"type":"error","error":{}}
            ,
            .expected = "failed:invalid_request|-|\n",
        },
        .{
            .payload = "{\"type\":\"error\",\"error\":{\"message\":\"" ++ long ++ "\"}}",
            .expected = "failed:invalid_request|-|" ++ long ++ "\n",
        },
    };
    for (cases) |case| {
        var rig: Rig = undefined;
        rig.init(test_options);
        defer rig.deinit();
        try rig.frames.feed(&.{case.payload});
        try rig.frames.expect(case.expected);
    }
}

test "a failed head reports its status with the message of its body" {
    try Rig.expectFailure(test_options, &.{
        .status = .unauthorized,
        .retry_after_ms = null,
        .body =
        \\{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}
        ,
    }, "failed:unauthorized|-|401 Unauthorized: invalid x-api-key");
    try Rig.expectFailure(test_options, &.{
        .status = @enumFromInt(529),
        .retry_after_ms = null,
        .body =
        \\{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}
        ,
    }, "failed:overloaded|-|529: Overloaded");
    try Rig.expectFailure(test_options, &.{
        .status = .too_many_requests,
        .retry_after_ms = 7000,
        .body =
        \\{"type":"error","error":{"type":"rate_limit_error","message":"slow"}}
        ,
    }, "failed:rate_limited|7000|429 Too Many Requests: slow");
    try Rig.expectFailure(test_options, &.{
        .status = .bad_request,
        .retry_after_ms = null,
        .body =
        \\{"type":"error","error":{"message":"cut off
        ,
    }, "failed:invalid_request|-|400 Bad Request: " ++
        "{\"type\":\"error\",\"error\":{\"message\":\"cut off");
    try Rig.expectFailure(test_options, &.{
        .status = .forbidden,
        .retry_after_ms = null,
        .body =
        \\{"type":"error","error":{}}
        ,
    }, "failed:invalid_request|-|403 Forbidden: {\"type\":\"error\",\"error\":{}}");
    try Rig.expectFailure(test_options, &.{
        .status = .internal_server_error,
        .retry_after_ms = null,
        .body = "",
    }, "failed:overloaded|-|500 Internal Server Error");
}

test "the head quota reads the unified windows against a given time" {
    const now: i64 = 1_787_589_400;
    const captured = [_]std.http.Header{
        .{ .name = "anthropic-ratelimit-unified-status", .value = "allowed" },
        .{ .name = "anthropic-ratelimit-unified-5h-status", .value = "allowed" },
        .{ .name = "anthropic-ratelimit-unified-5h-reset", .value = "1787598000" },
        .{ .name = "anthropic-ratelimit-unified-5h-utilization", .value = "0.06" },
        .{ .name = "anthropic-ratelimit-unified-overage-utilization", .value = "0.5" },
        .{ .name = "anthropic-ratelimit-unified-overage-reset", .value = "1788220800" },
    };
    const quota_5h = parseQuota(&captured, now).?;
    try std.testing.expectApproxEqAbs(@as(f64, 6), quota_5h.primary.?.used_percent, 1e-9);
    try std.testing.expectEqual(@as(?u32, 300), quota_5h.primary.?.window_minutes);
    try std.testing.expectEqual(@as(?u64, 8600), quota_5h.primary.?.reset_seconds);
    try std.testing.expect(quota_5h.secondary == null);

    const both = [_]std.http.Header{
        .{ .name = "Anthropic-Ratelimit-Unified-5h-Utilization", .value = "0.042" },
        .{ .name = "anthropic-ratelimit-unified-5h-reset", .value = "1787598000" },
        .{ .name = "anthropic-ratelimit-unified-7d-utilization", .value = "0.3" },
        .{ .name = "anthropic-ratelimit-unified-7d-reset", .value = "1788220800" },
    };
    const windows = parseQuota(&both, now).?;
    try std.testing.expectApproxEqAbs(@as(f64, 4.2), windows.primary.?.used_percent, 1e-9);
    try std.testing.expectEqual(@as(?u32, 10080), windows.secondary.?.window_minutes);
    try std.testing.expectEqual(@as(?u64, 631_400), windows.secondary.?.reset_seconds);

    const stale = parseQuota(&.{
        .{ .name = "anthropic-ratelimit-unified-5h-utilization", .value = "0.9" },
        .{ .name = "anthropic-ratelimit-unified-5h-reset", .value = "1787000000" },
    }, now).?;
    try std.testing.expectApproxEqAbs(@as(f64, 90), stale.primary.?.used_percent, 1e-9);
    try std.testing.expect(stale.primary.?.reset_seconds == null);

    try std.testing.expect(parseQuota(&.{}, now) == null);

    try std.testing.expectEqual(@as(?u64, 8600), parseResetSeconds("1787598000", now));
    try std.testing.expect(parseResetSeconds("2026-08-24T19:00:00Z", now) == null);
    try std.testing.expect(parseResetSeconds("soon", now) == null);
    try std.testing.expectEqual(@as(?f64, 0), parseUtilization("0.0"));
    try std.testing.expectEqual(@as(?f64, 100), parseUtilization("1"));
    try std.testing.expectEqual(@as(?f64, 100), parseUtilization("1.4"));
    try std.testing.expect(parseUtilization("-0.1") == null);
    try std.testing.expect(parseUtilization("nan") == null);
    try std.testing.expect(parseUtilization("inf") == null);
    try std.testing.expect(parseUtilization("half") == null);
}

test "decoding frees its state at every allocation-failure point" {
    try Rig.checkDecodeAllocationFailures(test_options, &.{
        \\{"type":"message_start","message":{"model":"claude-opus-5","usage":{"input_tokens":3}}}
        ,
        \\{"type":"content_block_start","index":0,"content_block":{"type":"text"}}
        ,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello"}}
        ,
        \\{"type":"content_block_stop","index":0}
        ,
        \\{"type":"content_block_start","index":1,"content_block":{"type":"thinking"}}
        ,
        \\{"type":"content_block_delta","index":1,"delta":{"type":"thinking_delta",
        \\"thinking":"hmm"}}
        ,
        \\{"type":"content_block_delta","index":1,"delta":{"type":"signature_delta",
        \\"signature":"sig"}}
        ,
        \\{"type":"content_block_stop","index":1}
        ,
        \\{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"tool_1",
        \\"name":"read"}}
        ,
        \\{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta",
        \\"partial_json":"{}"}}
        ,
        \\{"type":"content_block_stop","index":2}
        ,
        \\{"type":"content_block_start","index":3,"content_block":{"type":"redacted_thinking",
        \\"data":"enc"}}
        ,
        \\{"type":"content_block_stop","index":3}
        ,
    });
}
